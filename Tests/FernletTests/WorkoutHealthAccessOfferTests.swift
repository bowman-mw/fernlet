import Foundation
import HealthKit
import Testing
import FernletFoundation
import FernletDomainModel
import HealthKitGateway
@testable import Fernlet

/// The first-workout Health offer: onboarding promises "Asked the first time you log a workout…",
/// and until 2026-09-23 nothing asked (tracker 09-14 §3.1; owner: "Those gaps should be addressed").
///
/// Driven end to end through `FernletStore.addWorkout` / `startGuidedRun` over the REAL
/// `HealthKitService` and a recording store seam — the authorization seam is
/// `HealthKitStoreControlling.requestAuthorization`, which is where a presented system sheet would
/// be. Pins the rules the offer owns: it asks once; never again after a decline; never a user who
/// switched Health off in Settings; never when HealthKit would show nothing (no silent re-enable);
/// and it never blocks or loses the workout, which reaches Health only if the user allowed it.
@MainActor
struct WorkoutHealthAccessOfferTests {

    // MARK: - The promise

    /// The first workout the user logs asks — once — for workout access, turns Fernlet's Health and
    /// workout sharing on, records the ask, and the workout reaches Health after the grant. The
    /// second log asks nothing and is simply written.
    @Test func theFirstWorkoutLogAsksOnceAndTheSecondDoesNot() async throws {
        try #require(HKHealthStore.isHealthDataAvailable(), "no Health store on this host — the suite would prove nothing")
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingAuthorized)
        defer { fixture.cleanup() }

        fixture.store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle { fixture.store.day.workouts.first?.healthKitUUID != nil }

        #expect(fixture.controller.authorizationRequests.count == 1, "the first workout log asks")
        #expect(fixture.controller.authorizationRequests.first?.contains(HKObjectType.workoutType().identifier) == true)
        #expect(fixture.preferences.preferences.healthKitMasterEnabled)
        #expect(fixture.preferences.preferences.healthKitCapabilityEnabled[HealthCapability.workoutLogging.rawValue] == true)
        #expect(fixture.ledgerHasWorkouts)
        #expect(fixture.controller.savedWorkoutCount == 1, "the workout that triggered the ask reaches Health once allowed")

        var second = WriteGateHarness.sampleWorkout
        second.name = "Evening walk"
        fixture.store.addWorkout(second)
        await Self.settle { fixture.store.day.workouts.allSatisfy { $0.healthKitUUID != nil } }

        #expect(fixture.controller.authorizationRequests.count == 1, "the second log never asks again")
        #expect(fixture.controller.savedWorkoutCount == 2)
    }

    /// A decline leaves every switch where it was (off), writes nothing, keeps the workout, and is
    /// never followed by a second ask.
    @Test func aDeclineStaysOffWritesNothingAndIsNeverReasked() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingDenied)
        defer { fixture.cleanup() }

        fixture.store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle { fixture.controller.authorizationRequests.count == 1 && !fixture.preferences.preferences.healthKitMasterEnabled }
        fixture.store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle()

        #expect(fixture.controller.authorizationRequests.count == 1, "asked once — never again after a decline")
        #expect(fixture.preferences.preferences.healthKitMasterEnabled == false)
        #expect(fixture.preferences.preferences.healthKitCapabilityEnabled[HealthCapability.workoutLogging.rawValue] == false)
        #expect(fixture.controller.savedWorkoutCount == 0, "a declined ask writes nothing to Health")
        #expect(fixture.store.day.workouts.count == 2, "the workouts themselves are logged regardless")
    }

    /// A user who turned Fernlet's Health off in Settings is never asked — even though turning it
    /// off cleared the capability ledger, which is why the offer keeps its own fact.
    @Test func aUserWhoTurnedHealthOffInSettingsIsNeverAsked() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingAuthorized)
        defer { fixture.cleanup() }

        fixture.store.recordWorkoutHealthOfferResolvedBySettings()
        fixture.store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle()

        #expect(fixture.controller.authorizationRequests.isEmpty)
        #expect(fixture.controller.requestStatusQueries == 0)
        #expect(fixture.preferences.preferences.healthKitMasterEnabled == false)
        #expect(fixture.controller.savedWorkoutCount == 0)
    }

    /// When HealthKit would show no sheet (every workout type was already decided — say, before a
    /// "delete everything"), "asking" would silently switch sharing back on. The offer leaves it off.
    @Test func anAnswerHealthKitAlreadyHasIsNeverTurnedIntoASilentReenable() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingAuthorized, requestStatus: .unnecessary)
        defer { fixture.cleanup() }
        fixture.controller.grantAllShareTypes()

        fixture.store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle()

        #expect(fixture.controller.requestStatusQueries == 1)
        #expect(fixture.controller.authorizationRequests.isEmpty)
        #expect(fixture.preferences.preferences.healthKitMasterEnabled == false)
        #expect(fixture.controller.savedWorkoutCount == 0)
    }

    /// Fernlet already asked about workouts (Settings' card, an older build) — the ledger says so,
    /// and the first log asks nothing.
    @Test func workoutsAlreadyAskedAboutAreNotAskedAgain() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: true, promptAnswer: .sharingAuthorized)
        defer { fixture.cleanup() }
        HealthCapabilityRequestLedger.record(.workoutLogging, keychainService: fixture.harness.serviceID, legacyDefaults: fixture.harness.ledgerDefaults)

        fixture.store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle()

        #expect(fixture.controller.authorizationRequests.isEmpty)
        #expect(fixture.preferences.preferences.healthKitCapabilityEnabled[HealthCapability.workoutLogging.rawValue] == false)
    }

    // MARK: - Every entry point, and a batch

    /// Starting a guided workout (which also starts its Live Activity) is a first workout too.
    @Test func startingAGuidedWorkoutAsks() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingAuthorized)
        defer { fixture.cleanup() }
        let exercises = [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)]
        let session = WorkoutProgram.SessionSuggestion(
            title: "Push", timeLabel: "", kind: .strength, exercises: exercises,
            suggestion: WorkoutSuggestion(name: "Push", exercises: exercises.map(\.line).joined(separator: "\n"), notes: "")
        )

        #expect(fixture.store.startGuidedRun(session))
        await Self.settle { fixture.controller.authorizationRequests.count == 1 }

        #expect(fixture.controller.authorizationRequests.count == 1)
        #expect(fixture.store.day.workouts.isEmpty, "starting logs nothing — the ask comes at the start, the save at the finish")
        fixture.store.abandonGuidedRun()
    }

    /// Completing a planned workout is a first workout log.
    @Test func completingAPlannedWorkoutAsks() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingAuthorized)
        defer { fixture.cleanup() }
        let planned = PlannedWorkout(name: "Leg day", split: .lower, source: .user, exercises: "Squat 3x5", notes: "", duration: 40)
        fixture.store.planWorkout(planned, date: fixture.store.todayKey)

        fixture.store.completePlannedWorkout(planned, date: fixture.store.todayKey)
        await Self.settle { fixture.store.day.workouts.first?.healthKitUUID != nil }

        #expect(fixture.controller.authorizationRequests.count == 1)
        #expect(fixture.controller.savedWorkoutCount == 1)
    }

    /// "Log the rest" logs several workouts in one turn: one ask, and once allowed EVERY one of them
    /// reaches Health — the later saves wait for the ask instead of racing past its closed gate.
    @Test func aBatchLoggedWhileTheSheetIsUpAllReachHealthOnceAllowed() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingAuthorized)
        defer { fixture.cleanup() }

        for name in ["Push", "Pull", "Legs"] {
            var workout = WriteGateHarness.sampleWorkout
            workout.name = name
            fixture.store.addWorkout(workout)
        }
        await Self.settle { fixture.store.day.workouts.allSatisfy { $0.healthKitUUID != nil } }

        #expect(fixture.controller.authorizationRequests.count == 1)
        #expect(fixture.controller.savedWorkoutCount == 3)
    }

    // MARK: - The fact's lifecycle

    /// "Delete everything" returns the install to a fresh start: the fact goes with the wipe (the
    /// persisted-surface wall pins the call; this pins that it works).
    @Test func deleteEverythingClearsTheFact() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let fixture = OfferFixture(masterEnabled: false, promptAnswer: .sharingDenied)
        defer { fixture.cleanup() }
        fixture.store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle { fixture.controller.authorizationRequests.count == 1 }
        #expect(fixture.visibilityDefaults.bool(forKey: WorkoutHealthAccessOffer.resolvedKey))

        _ = fixture.store.resetAll()

        #expect(fixture.visibilityDefaults.object(forKey: WorkoutHealthAccessOffer.resolvedKey) == nil)
    }

    /// A store nobody wired an offer into (headless, previews, every other suite) never prompts.
    @Test func anUnwiredStoreNeverAsks() async throws {
        try #require(HKHealthStore.isHealthDataAvailable())
        let harness = WriteGateHarness(masterEnabled: false, enabledCapabilities: [])
        defer { harness.cleanup() }
        harness.controller.requestStatus = .shouldRequest
        let store = makeTestStore(healthKitService: harness.service)

        store.addWorkout(WriteGateHarness.sampleWorkout)
        await Self.settle()

        #expect(harness.controller.authorizationRequests.isEmpty)
        #expect(harness.controller.requestStatusQueries == 0)
    }

    // MARK: - Helpers

    /// Lets the store's detached tasks run; stops early once `until` holds.
    private static func settle(until: @MainActor () -> Bool = { false }) async {
        for _ in 0..<40 {
            if until() { return }
            await Task.yield()
            do {
                try await Task.sleep(for: .milliseconds(10))
            } catch {
                return
            }
        }
    }
}

/// A test store wired with a first-workout offer over a real `HealthKitService` and a recording
/// store seam, every piece of state on its own slot: preferences + ledger keychain rows, the ledger's
/// defaults suite, and the store's sensitive-surface suite that holds the offer's fact.
@MainActor
private final class OfferFixture {
    let harness: WriteGateHarness
    let visibilityDefaults: UserDefaults
    let store: FernletStore

    var controller: WriteRecordingStoreController { harness.controller }
    var preferences: StoragePreferencesStore { harness.preferences }

    /// Whether the capability ledger records the workout ask.
    var ledgerHasWorkouts: Bool {
        HealthCapabilityRequestLedger.requestedCapabilities(
            keychainService: harness.serviceID,
            legacyDefaults: harness.ledgerDefaults
        ).contains(.workoutLogging)
    }

    init(masterEnabled: Bool, promptAnswer: HKAuthorizationStatus, requestStatus: HKAuthorizationRequestStatus = .shouldRequest) {
        harness = WriteGateHarness(masterEnabled: masterEnabled, enabledCapabilities: [])
        harness.controller.promptAnswer = promptAnswer
        harness.controller.requestStatus = requestStatus
        visibilityDefaults = uniqueSensitiveVisibilityDefaults()
        store = makeTestStore(sensitiveVisibilityDefaults: visibilityDefaults, healthKitService: harness.service)
        store.workoutHealthAccessOffer = WorkoutHealthAccessOffer(
            service: harness.service,
            preferencesStore: harness.preferences,
            ledgerKeychainService: harness.serviceID,
            ledgerDefaults: harness.ledgerDefaults,
            markerDefaults: visibilityDefaults,
            presentationDelay: .zero
        )
    }

    func cleanup() {
        harness.cleanup()
    }
}
