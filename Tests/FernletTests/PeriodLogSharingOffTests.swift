import CoreData
import CryptoKit
import Foundation
import HealthKit
import Testing
import FernletFoundation
import FernletCrypto
import FernletUI
import HealthKitGateway
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

/// Owner report 2026-09-29: "When you click save for period tracking, but you're not sharing to
/// HealthKit, it doesn't work." The owner's answer, 2026-09-30: Option B — every period log is saved
/// in Fernlet's own encrypted store whatever the Health switches say, and Apple Health becomes an
/// optional mirror (period-data design 2026-09-30, §6.3, invariants I1–I3).
///
/// This suite pins that contract through the REAL `HealthKitService` over `WriteGateHarness`'s
/// recording store seam — so "nothing reached Health" is what reached the store, not what a fake said
/// — plus the sheet's own sentences. `PeriodLogHealthSharingOffUITests` is the on-screen half.
@MainActor
struct PeriodLogSharingOffTests {

    // MARK: - What the store does with sharing off (I1, I2)

    /// I2: a log with EVERY field set saves with either switch off — sealed in Fernlet, every field
    /// kept — and nothing reaches Apple Health (I1). It used to be refused whole, note included.
    @Test(arguments: HealthKitWriteGateTests.ClosedSwitch.allCases)
    func aFullLogSavesWithAClosedSwitchAndNothingReachesHealth(closed: HealthKitWriteGateTests.ClosedSwitch) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(
            masterEnabled: closed != .master,
            enabledCapabilities: closed == .capability ? [] : [.cycleTracking]
        )
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let (store, records) = Self.visibleStore(over: harness)

        let outcome = try await store.logEvent(PeriodTrackerTests.fullEvent(), unlockedContentKey: Self.contentKey)

        #expect(outcome == PeriodLogOutcome(storage: .sealed, healthCopy: .notShared))
        #expect(harness.controller.writeCount == 0, "nothing may reach Health with a switch off")
        let stored = try #require(try records.allRecords(contentKey: Self.contentKey).records.first)
        #expect(stored.clinical?.flowLevel == .medium && stored.narrative?.note == "cramps after lunch")
    }

    /// I2: with NO passcode and the Private tab closed, the same full log is held for the next open —
    /// never refused, never dropped — and nothing reaches Health.
    @Test func withNoPasscodeAFullLogIsHeldNotRefused() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [])
        defer { harness.cleanup() }
        let (store, records) = Self.visibleStore(over: harness)
        let lock = RecordingBufferNoPasscode()
        store.attachLockService(lock)

        let outcome = try await store.logEvent(PeriodTrackerTests.fullEvent(), unlockedContentKey: nil)

        #expect(outcome == PeriodLogOutcome(storage: .pendingUntilPrivateOpens, healthCopy: .notShared))
        #expect(lock.buffered.count == 1)
        #expect(harness.controller.writeCount == 0)
        #expect(try records.recordCount() == 0, "no key was live, so nothing is sealed yet")
    }

    /// With sharing ON and Apple Health's grant, the mirror IS written — after the seal.
    @Test func withSharingOnTheMirrorIsWritten() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [.cycleTracking])
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let (store, records) = Self.visibleStore(over: harness)

        let outcome = try await store.logEvent(UserLoggedCycleEvent(flowLevel: .light), unlockedContentKey: Self.contentKey)

        #expect(outcome == PeriodLogOutcome(storage: .sealed, healthCopy: .written))
        #expect(harness.controller.writeCount == 1)
        #expect(try records.recordCount() == 1)
    }

    /// Apple Health's own refusal (Fernlet's switches on, a type denied in the Health app) no longer
    /// costs the entry: it is kept in Fernlet and the outcome names the refusal.
    @Test func healthsOwnRefusalKeepsTheEntryAndSaysSo() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [.cycleTracking])
        defer { harness.cleanup() }
        harness.controller.statuses[HKCategoryTypeIdentifier.menstrualFlow.rawValue] = .sharingAuthorized
        harness.controller.statuses[HKQuantityTypeIdentifier.basalBodyTemperature.rawValue] = .sharingDenied
        let (store, records) = Self.visibleStore(over: harness)

        let outcome = try await store.logEvent(
            UserLoggedCycleEvent(flowLevel: .heavy, basalBodyTemperature: 36.6, temperatureUnit: .celsius),
            unlockedContentKey: Self.contentKey
        )

        #expect(outcome == PeriodLogOutcome(storage: .sealed, healthCopy: .failed(.healthDenied)))
        #expect(harness.controller.writeCount == 0)
        #expect(try records.recordCount() == 1)
    }

    // MARK: - Reading back what saved without Health

    /// HealthKit refusing a read Fernlet never asked for is "nothing readable", not a failure; every
    /// other error still fails the load.
    @Test func onlyAnUnrequestedReadCountsAsNothingReadable() {
        #expect(HealthKitService.isUnrequestedReadError(HKError(.errorAuthorizationNotDetermined)))
        #expect(!HealthKitService.isUnrequestedReadError(HKError(.errorAuthorizationDenied)))
        #expect(!HealthKitService.isUnrequestedReadError(HKError(.errorDatabaseInaccessible)))
        #expect(!HealthKitService.isUnrequestedReadError(HealthKitServiceError.healthDataUnavailable))
        #expect(!HealthKitService.isUnrequestedReadError(CancellationError()))
    }

    /// End to end over the REAL Health store: a FLOW log with sharing off is on the page after the next
    /// load — from Fernlet's own record, with no Health read at all (the cycle capability is off).
    @Test func aFlowLogWithSharingOffIsOnThePageAfterTheNextLoad() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let slot = "com.fernlet.period-notes-read.tests.\(UUID().uuidString)"
        let suiteName = "com.fernlet.period-notes-read.defaults.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer {
            KeychainItem.delete(for: .storagePreferences, service: slot)
            _ = HealthCapabilityRequestLedger.clear(keychainService: slot, legacyDefaults: defaults)
            defaults.removePersistentDomain(forName: suiteName)
        }
        let service = HealthKitService(
            preferencesStore: StoragePreferencesStore(keychainService: slot),
            capabilityLedgerKeychainService: slot,
            capabilityLedgerDefaults: defaults
        )
        let controller = PrivatePersistenceController(inMemory: true)
        let store = PeriodTrackerStore(
            healthService: service,
            narrativeRepository: MenstrualNarrativeRepository(controller: controller, defaults: defaults),
            recordStore: CycleRecordStore(controller: controller)
        )
        store.attachVisibilityGate { true }

        let outcome = try await store.logEvent(UserLoggedCycleEvent(flowLevel: .medium, note: "read back"), unlockedContentKey: Self.contentKey)
        #expect(outcome.storage == .sealed)
        await store.loadEntries(unlockedContentKey: Self.contentKey)

        let today = store.entries.first { $0.dateKey == FernletDate.dayKey(for: Date()) }
        #expect(today?.flowLevel == .medium, "the sealed entry must be on the page")
        #expect(today?.notes == ["read back"])
    }

    // MARK: - The rule the sheet reads

    /// The pure rule the log sheet evaluates over the observable preferences is the gate's rule:
    /// same answer as the live gate for every switch combination, and never "on" without Health.
    @Test func theSheetsSharingRuleIsTheGatesRule() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        for master in [false, true] {
            for capabilityOn in [false, true] {
                let harness = WriteGateHarness(
                    masterEnabled: master,
                    enabledCapabilities: capabilityOn ? [.cycleTracking] : []
                )
                let preferences = harness.preferences.preferences
                let sheetRule = HealthKitService.isWriteSharingEnabled(for: .cycleTracking, in: preferences)

                #expect(sheetRule == harness.service.isWriteSharingEnabled(for: .cycleTracking), "master \(master), cycle \(capabilityOn)")
                #expect(sheetRule == (master && capabilityOn), "master \(master), cycle \(capabilityOn)")
                #expect(!HealthKitService.isWriteSharingEnabled(for: .cycleTracking, in: preferences, healthDataAvailable: false))
                harness.cleanup()
            }
        }
    }

    // MARK: - What the sheet says (§10.4)

    /// A clean save says nothing (the sheet dismisses); a held one says when it will appear, in the
    /// tab's own word for each passcode mode.
    @Test func aCleanSaveSaysNothingAndAHeldOneSaysWhenItAppears() {
        #expect(LogPeriodSheet.outcomeSentence(.init(storage: .sealed, healthCopy: .notShared), isEdit: false, hasPasscode: false) == nil)
        #expect(LogPeriodSheet.outcomeSentence(.init(storage: .sealed, healthCopy: .written), isEdit: true, hasPasscode: true) == nil)

        let open = LogPeriodSheet.outcomeSentence(.init(storage: .pendingUntilPrivateOpens, healthCopy: .notShared), isEdit: false, hasPasscode: false)
        let unlock = LogPeriodSheet.outcomeSentence(.init(storage: .pendingUntilPrivateOpens, healthCopy: .written), isEdit: false, hasPasscode: true)
        #expect(open?.text.contains("next time you open Private") == true)
        #expect(unlock?.text.contains("next time you unlock Private") == true)
        #expect(open?.kind == .success)
    }

    /// The Health half failing is said — kept in Fernlet, no copy in Health, and why — and a removed
    /// stale copy (Q1) is said only as its own outcome.
    @Test func aHealthCopyFailureAndARemovedStaleCopyAreSaid() {
        let failedLog = LogPeriodSheet.outcomeSentence(.init(storage: .sealed, healthCopy: .failed(.healthDenied)), isEdit: false, hasPasscode: false)
        #expect(failedLog?.text.contains("Saved in Fernlet") == true)
        #expect(failedLog?.text.contains("didn't get a copy") == true)
        #expect(failedLog?.text.contains("Health app") == true)
        let failedEdit = LogPeriodSheet.outcomeSentence(.init(storage: .sealed, healthCopy: .failed(.other)), isEdit: true, hasPasscode: false)
        #expect(failedEdit?.text.contains("couldn't be updated") == true)
        let removed = LogPeriodSheet.outcomeSentence(.init(storage: .sealed, healthCopy: .removedStaleCopy), isEdit: true, hasPasscode: false)
        #expect(removed?.text == LogPeriodSheet.removedStaleCopySentence)
        #expect(removed?.kind == .status)
    }

    /// Every error the save can throw gets the sheet's own sentence; none says notes need a lock, and
    /// none says an entry was half-saved — the record is kept FIRST, so a throw kept nothing.
    @Test func everySaveErrorGetsItsOwnSentence() {
        let sentences = [
            LogPeriodSheet.errorSentence(for: PeriodTrackingHiddenError()),
            LogPeriodSheet.errorSentence(for: PendingNarrativeBufferError.full),
            LogPeriodSheet.errorSentence(for: PendingNarrativeBufferError.bufferUnopenable),
            LogPeriodSheet.errorSentence(for: PendingNarrativeBufferError.keyUnreadable(status: -25_308)),
            LogPeriodSheet.errorSentence(for: ColumnCrypto.SealedColumnStrictSealError.bindingUnavailable),
            LogPeriodSheet.errorSentence(for: CycleRecordRepositoryError.storeFull(limit: 20_000)),
            LogPeriodSheet.errorSentence(for: FernletLockError.locked)
        ]
        #expect(Set(sentences).count == sentences.count - 1, "the two encryption refusals share one sentence")
        for sentence in sentences {
            #expect(!sentence.contains("app lock"))
            #expect(!sentence.contains("already saved"), "nothing is half-saved any more: \(sentence)")
        }
        let other = HKError(.errorDatabaseInaccessible)
        #expect(LogPeriodSheet.errorSentence(for: other) == other.localizedDescription)
    }

    /// "First day of cycle" marks where a period starts, so it still needs a flow level beside it.
    @Test func theFirstDayFlagNeedsAFlowLevel() {
        #expect(LogPeriodSheet.cycleStartProblem(isCycleStart: true, flowLevel: nil) != nil)
        #expect(LogPeriodSheet.cycleStartProblem(isCycleStart: true, flowLevel: .light) == nil)
        #expect(LogPeriodSheet.cycleStartProblem(isCycleStart: false, flowLevel: nil) == nil)
    }

    /// Pins why: a first-day-only record has no sample to carry the flag in Apple Health.
    @Test func aFirstDayOnlyRecordBuildsNoSample() throws {
        let samples = try HealthKitService.periodSamples(for: CycleRecord(event: UserLoggedCycleEvent(isCycleStart: true)))
        #expect(samples.isEmpty)
    }

    /// The edit sheet seeds a temperature in the picker's unit from the unit it was entered in.
    @Test func anEditSeedsTheTemperatureInThePickersUnit() {
        #expect(LogPeriodSheet.temperatureText(value: 36.6, enteredIn: .celsius, shownIn: .celsius) == "36.60")
        #expect(LogPeriodSheet.temperatureText(value: 36.6, enteredIn: .celsius, shownIn: .fahrenheit) == "97.88")
        #expect(LogPeriodSheet.temperatureText(value: 97.88, enteredIn: .fahrenheit, shownIn: .celsius) == "36.60")
    }

    // MARK: - Helpers

    private static let contentKey = SymmetricKey(data: Data(repeating: 9, count: 32))

    /// A store over the harness's REAL gateway and one in-memory sealed stack, opted in to visibility
    /// (the store fails closed), plus a visible funnel on the same stack for reading back.
    private static func visibleStore(over harness: WriteGateHarness) -> (PeriodTrackerStore, CycleRecordStore) {
        let controller = PrivatePersistenceController(inMemory: true)
        let store = PeriodTrackerStore(
            healthService: harness.service,
            narrativeRepository: MenstrualNarrativeRepository(controller: controller),
            recordStore: CycleRecordStore(controller: controller)
        )
        store.attachVisibilityGate { true }
        let records = CycleRecordStore(controller: controller)
        records.attachVisibilityGate { true }
        return (store, records)
    }
}

/// A lock seam for an install with no passcode whose Private tab is closed: it records what the
/// store buffers (the seam no longer asks whether a passcode exists — nothing is dropped).
@MainActor
private final class RecordingBufferNoPasscode: PeriodLockContext {
    private(set) var buffered: [PendingNarrativePayload] = []
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws { buffered.append(payload) }
    func drainPendingNarratives() throws -> [PendingNarrativePayload] { buffered }
    func purgePendingNarratives() throws { buffered = [] }
}
