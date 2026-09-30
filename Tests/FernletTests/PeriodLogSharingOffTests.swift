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
    /// Health", which implied the entry was kept somewhere else. A fresh log's sentence and an
    /// edit's differ: only a fresh log can be saved without its Health details.
    @Test func aClosedSwitchGetsThePeriodSentence() {
        let refusal = HealthKitServiceError.sharingTurnedOff
        let logSentence = LogPeriodSheet.refusalSentence(for: refusal, isEdit: false)
        let editSentence = LogPeriodSheet.refusalSentence(for: refusal, isEdit: true)

        #expect(logSentence != refusal.localizedDescription)
        #expect(editSentence != refusal.localizedDescription)
        #expect(logSentence != editSentence)
        #expect(logSentence.contains("Nothing was saved"))
        #expect(logSentence.contains("notes and symptoms"))
        #expect(editSentence.contains("Nothing was changed"))
    }

    /// Apple Health's own refusal (Fernlet's switches on, cycle data denied in the Health app) gets
    /// its own sentence pointing at the Health app rather than Fernlet's Settings.
    @Test func healthsOwnRefusalGetsTheHealthAppSentence() {
        let denied = LogPeriodSheet.refusalSentence(for: HKError(.errorAuthorizationDenied), isEdit: false)
        let undetermined = LogPeriodSheet.refusalSentence(for: HKError(.errorAuthorizationNotDetermined), isEdit: true)

        #expect(denied == undetermined)
        #expect(denied.contains("Health app"))
        #expect(denied != LogPeriodSheet.refusalSentence(for: HealthKitServiceError.sharingTurnedOff, isEdit: false))
    }

    /// Anything else keeps its own description: the mapping only rewrites what it can explain.
    @Test func anyOtherErrorKeepsItsOwnDescription() {
        let unavailable = HealthKitServiceError.healthDataUnavailable
        #expect(LogPeriodSheet.refusalSentence(for: unavailable, isEdit: false) == unavailable.localizedDescription)
        let other = HKError(.errorDatabaseInaccessible)
        #expect(LogPeriodSheet.refusalSentence(for: other, isEdit: false) == other.localizedDescription)
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
