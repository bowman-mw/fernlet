import CoreData
import CryptoKit
import Foundation
import HealthKit
import Testing
import FernletFoundation
import HealthKitGateway
import PrivateHealthStore
import PrivateStoreCore
@testable import Fernlet

/// Owner report 2026-09-29: "When you click save for period tracking, but you're not sharing to
/// HealthKit, it doesn't work."
///
/// Apple Health is the only home for the clinical cycle fields, and the write gate refuses every one
/// of them while Fernlet's master Health switch or its Cycle tracking switch is off — both default
/// off. The refusal is the owner's own rule and stays; what was broken is that the log sheet hid it
/// (a success-green sentence far below the fold, the sheet left looking untouched). This suite pins
/// the contract the sheet now explains, driven through the REAL `HealthKitService` over
/// `WriteGateHarness`'s recording store seam, plus the sheet's own sentences and the sharing rule it
/// reads. `PeriodLogHealthSharingOffUITests` is the on-screen half.
@MainActor
struct PeriodLogSharingOffTests {

    // MARK: - What the store does with sharing off

    /// A log carrying a flow level AND a note is refused WHOLE: nothing reaches Health and no
    /// narrative is sealed. Atomic on purpose — `logEvent` mints a fresh external UUID every call,
    /// so sealing the note now and re-saving after sharing is turned on would leave a second,
    /// orphaned note on the day. The sheet keeps the draft instead, and says so.
    @Test(arguments: HealthKitWriteGateTests.ClosedSwitch.allCases)
    func aFlowLogIsRefusedWholeNoteIncluded(closed: HealthKitWriteGateTests.ClosedSwitch) async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(
            masterEnabled: closed != .master,
            enabledCapabilities: closed == .capability ? [] : [.cycleTracking]
        )
        defer { harness.cleanup() }
        let repository = Self.inMemoryRepository()
        let store = Self.visibleStore(over: harness, repository: repository)
        let event = UserLoggedCycleEvent(flowLevel: .medium, note: "cramps after lunch", symptoms: [.cramps])

        let error = await #expect(throws: HealthKitServiceError.self) {
            _ = try await store.logEvent(event, unlockedContentKey: Self.contentKey)
        }

        #expect(error.map(Self.isSharingTurnedOff) == true, "the refusal must name the closed switch")
        #expect(harness.controller.writeCount == 0, "nothing may reach Health with a switch off")
        #expect(try repository.narrativeCount() == 0, "the note must not be half-saved")
    }

    /// The half that works without Health: a note and symptoms alone need no sharing, seal one row,
    /// and write nothing to Health. The sheet's notice promises exactly this.
    @Test func aNoteAndSymptomsLogSavesWithSharingOff() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [])
        defer { harness.cleanup() }
        let repository = Self.inMemoryRepository()
        let store = Self.visibleStore(over: harness, repository: repository)

        let result = try await store.logEvent(
            UserLoggedCycleEvent(note: "tired today", symptoms: [.fatigue]),
            unlockedContentKey: Self.contentKey
        )

        #expect(result == .saved)
        #expect(harness.controller.writeCount == 0)
        #expect(try repository.narrativeCount() == 1)
    }

    /// Apple Health's own half of an edit's pre-check (2026-09-30). Fernlet's switches are on, and
    /// the user allowed Menstrual Flow in the Health prompt but not Basal Body Temperature. An edit
    /// adding a temperature used to pass the pre-check (switches only), delete the day's sealed note
    /// and own samples, and only then have the re-log refused by HealthKit. It is now refused with
    /// Health's own error BEFORE anything is deleted, so the day survives whole.
    @Test func anEditHealthWouldRefuseDeletesNothing() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [.cycleTracking])
        defer { harness.cleanup() }
        harness.controller.statuses[HKCategoryTypeIdentifier.menstrualFlow.rawValue] = .sharingAuthorized
        harness.controller.statuses[HKQuantityTypeIdentifier.basalBodyTemperature.rawValue] = .sharingDenied
        let repository = Self.inMemoryRepository()
        let store = Self.visibleStore(over: harness, repository: repository)
        let externalUUID = UUID().uuidString
        let narrative = MenstrualNarrative(hkExternalUUID: externalUUID, dateKey: FernletDate.dayKey(for: Date()), note: "must survive")
        try repository.insert(narrative, contentKey: Self.contentKey)
        let entry = CycleDayEntry(date: Date(), dateKey: narrative.dateKey, samples: [], narrative: narrative, phase: .unknown)
        let edit = UserLoggedCycleEvent(flowLevel: .heavy, basalBodyTemperature: 36.6, temperatureUnit: .celsius, note: "must survive")

        let error = await #expect(throws: HKError.self) {
            _ = try await store.editEvent(edit, replacingEntry: entry, unlockedContentKey: Self.contentKey)
        }

        #expect(error?.code == .errorAuthorizationDenied)
        #expect(harness.controller.deleteCallCount == 0)
        #expect(harness.controller.writeCount == 0)
        #expect(try repository.narrative(forHKUUID: externalUUID, contentKey: Self.contentKey)?.note == "must survive")
    }

    /// The pre-check passes once Health has granted every type the edit writes: an edit Health
    /// allows still goes through.
    @Test func anEditHealthAllowsStillSaves() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: true, enabledCapabilities: [.cycleTracking])
        defer { harness.cleanup() }
        harness.controller.grantAllShareTypes()
        let repository = Self.inMemoryRepository()
        let store = Self.visibleStore(over: harness, repository: repository)
        let narrative = MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: FernletDate.dayKey(for: Date()), note: "old")
        try repository.insert(narrative, contentKey: Self.contentKey)
        let entry = CycleDayEntry(date: Date(), dateKey: narrative.dateKey, samples: [], narrative: narrative, phase: .unknown)

        let result = try await store.editEvent(
            UserLoggedCycleEvent(flowLevel: .heavy, basalBodyTemperature: 36.6, temperatureUnit: .celsius, note: "new"),
            replacingEntry: entry,
            unlockedContentKey: Self.contentKey
        )

        #expect(result == .saved)
        #expect(harness.controller.writeCount == 1)
        #expect(try repository.narrativeCount() == 1)
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

    /// End to end over the REAL Health store: a note-and-symptoms entry, which saves without Health,
    /// is on the page after the next load. With cycle sharing off Fernlet never asks for cycle
    /// access, HealthKit fails a query on a type never requested, and the load used to throw and
    /// clear the page, so the sealed entry saved and was never shown. On a simulator where cycle
    /// access WAS requested the read succeeds either way and this still pins the join.
    @Test func aNotesOnlyEntryIsOnThePageAfterTheNextLoad() async throws {
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
        let repository = Self.inMemoryRepository()
        let store = PeriodTrackerStore(healthService: service, narrativeRepository: repository)
        store.attachVisibilityGate { true }
        let note = "read-back \(UUID().uuidString)"

        #expect(try await store.logEvent(UserLoggedCycleEvent(note: note, symptoms: [.fatigue]), unlockedContentKey: Self.contentKey) == .saved)
        await store.loadEntries(unlockedContentKey: Self.contentKey)

        #expect(store.entries.contains { $0.narrative?.note == note }, "the sealed entry must be on the page")
    }

    // MARK: - The rule the sheet reads

    /// The pure rule the log sheets evaluate over the observable preferences is the gate's rule:
    /// same answer as the live gate for every switch combination, and never "on" without Health.
    /// If the two drifted, the notice could promise a save the gate refuses (or hide one it allows).
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

    // MARK: - What the sheet says

    /// A closed switch gets the sheet's own sentence, not the gateway's "…nothing was saved to
    /// Health", which implied the entry was kept somewhere else. A fresh log, a fresh log with no
    /// app lock and an edit each get their own: only a fresh log WITH a lock can be saved without
    /// its Health details, so only that sentence offers the route.
    @Test func aClosedSwitchGetsThePeriodSentence() {
        let refusal = HealthKitServiceError.sharingTurnedOff
        let logSentence = LogPeriodSheet.refusalSentence(for: refusal, isEdit: false, lockConfigured: true)
        let noLockSentence = LogPeriodSheet.refusalSentence(for: refusal, isEdit: false, lockConfigured: false)
        let editSentence = LogPeriodSheet.refusalSentence(for: refusal, isEdit: true, lockConfigured: true)

        #expect(Set([logSentence, noLockSentence, editSentence, refusal.localizedDescription]).count == 4)
        #expect(logSentence.contains("Nothing was saved"))
        #expect(logSentence.contains("notes and symptoms"))
        #expect(noLockSentence.contains("Nothing was saved"))
        #expect(!noLockSentence.contains("clear the flow"), "with no lock, clearing the flow keeps nothing")
        #expect(noLockSentence.contains("app lock"))
        #expect(editSentence.contains("Nothing was changed"))
        #expect(LogPeriodSheet.refusalSentence(for: refusal, isEdit: true, lockConfigured: false) == editSentence)
    }

    /// Apple Health's own refusal (Fernlet's switches on, cycle data denied in the Health app) gets
    /// its own sentence pointing at the Health app rather than Fernlet's Settings. An EDIT's never
    /// says nothing was saved or changed: a refusal from the re-log's save arrives after the day's
    /// own samples and note were deleted, so it says to save again instead.
    @Test func healthsOwnRefusalGetsTheHealthAppSentence() {
        let denied = LogPeriodSheet.refusalSentence(for: HKError(.errorAuthorizationDenied), isEdit: false, lockConfigured: true)
        let undetermined = LogPeriodSheet.refusalSentence(for: HKError(.errorAuthorizationNotDetermined), isEdit: false, lockConfigured: false)
        let editDenied = LogPeriodSheet.refusalSentence(for: HKError(.errorAuthorizationDenied), isEdit: true, lockConfigured: true)

        #expect(denied == undetermined)
        #expect(denied.contains("Health app"))
        #expect(denied != LogPeriodSheet.refusalSentence(for: HealthKitServiceError.sharingTurnedOff, isEdit: false, lockConfigured: true))
        #expect(editDenied != denied)
        #expect(editDenied.contains("Health app"))
        #expect(editDenied.contains("save again"))
        #expect(!editDenied.contains("Nothing was saved"))
        #expect(!editDenied.contains("Nothing was changed"))
    }

    /// Anything else keeps its own description: the mapping only rewrites what it can explain.
    @Test func anyOtherErrorKeepsItsOwnDescription() {
        let unavailable = HealthKitServiceError.healthDataUnavailable
        #expect(LogPeriodSheet.refusalSentence(for: unavailable, isEdit: false, lockConfigured: true) == unavailable.localizedDescription)
        let other = HKError(.errorDatabaseInaccessible)
        #expect(LogPeriodSheet.refusalSentence(for: other, isEdit: true, lockConfigured: false) == other.localizedDescription)
    }

    /// Notes and symptoms with nothing for Health, and no app lock: nothing of that entry can be
    /// kept, so the sheet refuses before the store is called. Every other combination keeps
    /// something and goes on to the store.
    @Test func anEntryNothingOfWhichCanBeKeptIsRefusedUpFront() {
        #expect(LogPeriodSheet.unkeepableEntryProblem(hasNarrative: true, carriesHealthDetails: false, lockConfigured: false) != nil)
        for hasNarrative in [false, true] {
            for carriesHealthDetails in [false, true] {
                for lockConfigured in [false, true] where hasNarrative == false || carriesHealthDetails || lockConfigured {
                    #expect(LogPeriodSheet.unkeepableEntryProblem(
                        hasNarrative: hasNarrative,
                        carriesHealthDetails: carriesHealthDetails,
                        lockConfigured: lockConfigured
                    ) == nil, "narrative \(hasNarrative), health \(carriesHealthDetails), lock \(lockConfigured)")
                }
            }
        }
    }

    /// Why the sheet must refuse that entry itself: with no app lock the store DROPS the note and
    /// symptoms and still reports `.savedWithDroppedNarrative`, a "saved" outcome, while nothing
    /// reached Health and nothing was sealed. The sheet used to announce it as "Health event saved".
    @Test func withNoLockANotesOnlyLogStoresNothingYetReportsSaved() async throws {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [])
        defer { harness.cleanup() }
        let repository = Self.inMemoryRepository()
        let store = Self.visibleStore(over: harness, repository: repository)
        store.attachLockService(NoLockConfigured())

        let result = try await store.logEvent(
            UserLoggedCycleEvent(note: "tired today", symptoms: [.fatigue]),
            unlockedContentKey: nil
        )

        #expect(result == .savedWithDroppedNarrative)
        #expect(harness.controller.writeCount == 0)
        #expect(try repository.narrativeCount() == 0)
        let samples = try HealthKitService.periodSamples(for: UserLoggedCycleEvent(note: "tired today", symptoms: [.fatigue]), externalUUID: UUID())
        #expect(LogPeriodSheet.unkeepableEntryProblem(hasNarrative: true, carriesHealthDetails: !samples.isEmpty, lockConfigured: false) != nil)
    }

    /// "First day of cycle" is stored as metadata on the day's flow sample, so the flag alone wrote
    /// nothing while the sheet dismissed as saved. It is now refused with a sentence unless a flow
    /// level is chosen beside it.
    @Test func theFirstDayFlagNeedsAFlowLevel() {
        #expect(LogPeriodSheet.cycleStartProblem(isCycleStart: true, flowLevel: nil) != nil)
        #expect(LogPeriodSheet.cycleStartProblem(isCycleStart: true, flowLevel: .light) == nil)
        #expect(LogPeriodSheet.cycleStartProblem(isCycleStart: false, flowLevel: nil) == nil)
    }

    /// Pins the reason the flag needs a flow: of every sample a first-day-only event could build,
    /// none exists — the flag has nowhere to live.
    @Test func aFirstDayOnlyEventBuildsNoSample() throws {
        let samples = try HealthKitService.periodSamples(for: UserLoggedCycleEvent(isCycleStart: true), externalUUID: UUID())
        #expect(samples.isEmpty)
    }

    // MARK: - Helpers

    private static let contentKey = SymmetricKey(data: Data(repeating: 9, count: 32))

    private static func inMemoryRepository() -> MenstrualNarrativeRepository {
        MenstrualNarrativeRepository(context: PrivatePersistenceController(inMemory: true).container.viewContext)
    }

    /// A store over the harness's REAL gateway, opted in to visibility (the store fails closed).
    private static func visibleStore(over harness: WriteGateHarness, repository: MenstrualNarrativeRepository) -> PeriodTrackerStore {
        let store = PeriodTrackerStore(healthService: harness.service, narrativeRepository: repository)
        store.attachVisibilityGate { true }
        return store
    }

    private static func isSharingTurnedOff(_ error: HealthKitServiceError) -> Bool {
        if case .sharingTurnedOff = error { return true }
        return false
    }
}

/// A lock seam with no app lock configured: the store drops a narrative rather than buffering it.
@MainActor
private final class NoLockConfigured: PeriodLockContext {
    var isLockConfigured: Bool { false }
    func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws { }
    func drainPendingNarratives() throws -> [PendingNarrativePayload] { [] }
    func purgePendingNarratives() throws { }
}
