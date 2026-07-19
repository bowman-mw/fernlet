import Foundation
import HealthKit
import Testing
import FernletDomainModel
import HealthKitGateway
import LocalPersistence
@testable import Fernlet

/// Covers the tester-requested recoverability of logged workouts: a one-tap "Complete" is easy to
/// trigger by accident, so every logged (Fernlet-authored) workout must be removable and editable, and
/// removing one must reverse the bookkeeping the completion set up (planned-row restore, guided session
/// + progression). Health-managed rows are refused at the store level, not just hidden in the UI.
///
/// Serialized: each test stands up a real `FernletStore` over an in-memory stack; running them in
/// parallel lets the process-level state (and the store's unowned coordinators) race.
@MainActor
@Suite(.serialized)
struct WorkoutRecoveryTests {

    private func plainWorkout(name: String = "Upper strength") -> Workout {
        Workout(name: name, type: .upper, exercises: "Bench 3x8", rpe: 7, notes: "felt good", duration: 45, intensity: .moderate)
    }

    // MARK: removeWorkout

    @Test func removeWorkoutRemovesTheLoggedRow() {
        let store = makeTestStore()
        let workout = plainWorkout()
        store.addWorkout(workout, date: store.todayKey)
        #expect(store.day.workouts.contains { $0.id == workout.id })

        #expect(store.removeWorkout(id: workout.id, date: store.todayKey))
        #expect(store.day.workouts.isEmpty)
    }

    @Test func removeWorkoutReturnsFalseForUnknownID() {
        let store = makeTestStore()
        #expect(store.removeWorkout(id: UUID(), date: store.todayKey) == false)
    }

    @Test func removeWorkoutRestoresThePlannedRowWithPreservedID() {
        let store = makeTestStore()
        let planned = PlannedWorkout(
            id: UUID(), name: "Leg Day", split: .legs, source: .user,
            exercises: "Squat 3x5", muscleGroups: [.quads], notes: "warm up first", duration: 40
        )
        store.planWorkout(planned, date: store.todayKey)
        store.completePlannedWorkout(planned, date: store.todayKey)
        #expect(store.day.plannedWorkouts.isEmpty)
        #expect(store.day.workouts.count == 1)
        let logged = store.day.workouts[0]
        #expect(logged.plannedWorkoutID == planned.id)

        #expect(store.removeWorkout(id: logged.id, date: store.todayKey))
        #expect(store.day.workouts.isEmpty)
        #expect(store.day.plannedWorkouts.count == 1)

        let restored = store.day.plannedWorkouts[0]
        #expect(restored.id == planned.id)          // preserved so weekly copy-forward identity survives
        #expect(restored.name == "Leg Day")
        #expect(restored.duration == 40)
        #expect(restored.muscleGroups == [.quads])
        // Documented lossy reversal: .legs → workoutType .lower → reconstructed split .lower.
        #expect(restored.split == .lower)
    }

    @Test func removeWorkoutIsIdempotentOnDoubleCall() {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Push", split: .push, source: .user, notes: "", duration: 30)
        store.planWorkout(planned, date: store.todayKey)
        store.completePlannedWorkout(planned, date: store.todayKey)
        let logged = store.day.workouts[0]

        #expect(store.removeWorkout(id: logged.id, date: store.todayKey))
        // Second remove finds no row → no-op, and must NOT restore a second planned copy.
        #expect(store.removeWorkout(id: logged.id, date: store.todayKey) == false)
        #expect(store.day.workouts.isEmpty)
        #expect(store.day.plannedWorkouts.count == 1)
    }

    @Test func removeWorkoutRefusesHealthKitImportedRow() {
        let store = makeTestStore()
        let imported = Workout(
            name: "Morning Run", type: .cardio, exercises: "", rpe: nil, notes: "",
            duration: 30, healthKitUUID: UUID(), intensity: .moderate
        )
        store.addWorkout(imported, date: store.todayKey)
        #expect(store.day.workouts.contains { $0.id == imported.id })

        // API-level guard: refused even though the UI would also hide Remove.
        #expect(store.removeWorkout(id: imported.id, date: store.todayKey) == false)
        #expect(store.day.workouts.contains { $0.id == imported.id })
    }

    // MARK: guided reversal

    private func guidedSession(name: String, exercise: String) -> WorkoutProgram.SessionSuggestion {
        WorkoutProgram.SessionSuggestion(
            title: name,
            timeLabel: "",
            kind: .strength,
            exercises: [PrescribedExercise(name: exercise, sets: 3, reps: "8", role: .main, fromCatalog: true)],
            suggestion: WorkoutSuggestion(name: name, exercises: exercise, notes: "")
        )
    }

    @Test func removeWorkoutClearsGuidedSessionAndCardReResolvesReady() throws {
        let store = makeTestStore()
        // Establish today's committed-plan slot, then swap in a deterministic plan (the generated one is
        // weekday/profile dependent). `replaceGuidedWorkoutPlan` accepts the committed plan's session ids.
        let base = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let session = guidedSession(name: "Push Day", exercise: "Bench Press")
        let plan = WorkoutProgram.DayPlan(
            splitName: "Test", dayTitle: "Push", sessions: [session], droppedSlots: [], locationName: "Test"
        )
        store.replaceGuidedWorkoutPlan(plan, replacing: Set(base.sessions.map(\.id)))
        #expect(store.currentGuidedWorkoutPlan?.sessions.first?.id == session.id)

        store.completeGuidedRunnerSession(session)
        #expect(store.day.workouts.contains { $0.name == "Push Day" && $0.loggedFromGuidedSession == true })
        #expect(store.guidedCompletedSessionIDs.contains(session.id))
        #expect(store.settings.workoutProgression["Bench Press"] == 1)

        let done = GuidedWorkoutCardState.resolve(
            plan: plan, completed: store.guidedCompletedSessionIDs,
            loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
        )
        #expect(done == .allComplete(remainingMovement: false))

        let logged = try #require(store.day.workouts.first { $0.name == "Push Day" })
        #expect(store.removeWorkout(id: logged.id, date: store.todayKey))

        #expect(store.day.workouts.isEmpty)
        #expect(store.guidedCompletedSessionIDs.contains(session.id) == false)
        #expect(store.settings.workoutProgression["Bench Press"] == nil)   // decremented to 0 → dropped

        let ready = GuidedWorkoutCardState.resolve(
            plan: plan, completed: store.guidedCompletedSessionIDs,
            loggedGuidedWorkoutNames: store.loggedGuidedWorkoutNamesToday
        )
        #expect(ready == .ready(sessionID: session.id))
    }

    @Test func removeWorkoutLeavesProgressionUntouchedWhenPlanGone() throws {
        let store = makeTestStore()
        // No committed plan (simulates a relaunch/other-day removal): the exact catalog names can't be
        // recovered, so progression must be left alone rather than guessed at.
        let session = guidedSession(name: "Solo Day", exercise: "Back Squat")
        store.completeGuidedRunnerSession(session)
        #expect(store.currentGuidedWorkoutPlan == nil)
        #expect(store.settings.workoutProgression["Back Squat"] == 1)

        let logged = try #require(store.day.workouts.first { $0.name == "Solo Day" })
        #expect(store.removeWorkout(id: logged.id, date: store.todayKey))
        #expect(store.day.workouts.isEmpty)
        #expect(store.settings.workoutProgression["Back Squat"] == 1)   // untouched
    }

    // MARK: updateWorkout

    @Test func updateWorkoutEditsFieldsAndPreservesPlannedProvenance() {
        let store = makeTestStore()
        let planned = PlannedWorkout(name: "Push", split: .push, source: .user, notes: "", duration: 30)
        store.planWorkout(planned, date: store.todayKey)
        store.completePlannedWorkout(planned, date: store.todayKey)
        var logged = store.day.workouts[0]
        #expect(logged.plannedWorkoutID == planned.id)

        logged.name = "Push (easy)"
        logged.intensity = .light
        logged.duration = 22
        logged.notes = "shoulder felt tight"
        logged.plannedWorkoutID = nil   // an edit path that dropped provenance — the store must re-assert it

        #expect(store.updateWorkout(logged, date: store.todayKey))
        let updated = store.day.workouts[0]
        #expect(updated.name == "Push (easy)")
        #expect(updated.intensity == .light)
        #expect(updated.duration == 22)
        #expect(updated.notes == "shoulder felt tight")
        #expect(updated.plannedWorkoutID == planned.id)   // re-asserted from the stored row
    }

    @Test func updateWorkoutPreservesGuidedFlagAndPinsName() {
        let store = makeTestStore()
        var workout = Workout(
            name: "Guided", type: .fullBody, exercises: "circuit", rpe: nil, notes: "",
            duration: 20, loggedFromGuidedSession: true, intensity: .moderate
        )
        store.addWorkout(workout, date: store.todayKey)

        workout.name = "Guided (edited)"          // a rename must be REFUSED for guided rows...
        workout.intensity = .hard                 // ...while other edits still apply
        workout.loggedFromGuidedSession = nil     // dropped by the edit path
        #expect(store.updateWorkout(workout, date: store.todayKey))
        // The name is the guided card's relaunch reconciliation key — pinned to the stored value so a
        // rename can't un-key it into a double-log.
        #expect(store.day.workouts[0].name == "Guided")
        #expect(store.day.workouts[0].intensity == .hard)                 // other fields still edited
        #expect(store.day.workouts[0].loggedFromGuidedSession == true)    // re-asserted
    }

    @Test func updateWorkoutRefusesHealthKitImportedRow() {
        let store = makeTestStore()
        var imported = Workout(
            name: "Morning Run", type: .cardio, exercises: "", rpe: nil, notes: "",
            duration: 30, healthKitUUID: UUID(), intensity: .moderate
        )
        store.addWorkout(imported, date: store.todayKey)

        imported.name = "Edited Run"
        #expect(store.updateWorkout(imported, date: store.todayKey) == false)
        #expect(store.day.workouts[0].name == "Morning Run")   // unchanged
    }

    // MARK: authored rows (Fernlet owns the Health sample)

    /// Finding A.1: with HK write auth, a Fernlet log is stamped `healthKitAuthored` seconds after
    /// logging. That row IS removable — and removing it also deletes the Fernlet-authored Health sample.
    @Test func removeWorkoutAllowsAuthoredRowAndDeletesHealthCopy() async {
        let service = RecordingWorkoutHealthKitService(authorized: true)
        let store = makeStore(healthKitService: service)
        let workout = plainWorkout()
        store.addWorkout(workout, date: store.todayKey)
        // The HK save Task stamps the row authored a beat after logging.
        await waitFor { store.day.workouts.first?.isHealthAuthored == true }
        #expect(store.day.workouts.first?.isHealthAuthored == true)

        #expect(store.removeWorkout(id: workout.id, date: store.todayKey))   // authored → allowed
        #expect(store.day.workouts.isEmpty)                                   // local intent wins immediately

        await waitFor { service.deletedFernletWorkoutIDs.contains(workout.id) }
        #expect(service.deletedFernletWorkoutIDs == [workout.id])             // Health copy deleted too
    }

    /// Finding A.2: editing an authored row re-syncs its immutable Health sample — delete the old sample,
    /// save a new one (so the Health copy never silently diverges from the edit).
    @Test func updateWorkoutResyncsAuthoredHealthCopy() async {
        let service = RecordingWorkoutHealthKitService(authorized: true)
        let store = makeStore(healthKitService: service)
        let workout = plainWorkout()
        store.addWorkout(workout, date: store.todayKey)
        await waitFor { store.day.workouts.first?.isHealthAuthored == true }
        #expect(service.saveWorkoutCallCount == 1)   // the original log

        var edited = store.day.workouts[0]
        edited.name = "Upper strength (easy)"
        edited.intensity = .light
        #expect(store.updateWorkout(edited, date: store.todayKey))
        #expect(store.day.workouts[0].name == "Upper strength (easy)")   // local edit applied

        // Re-sync: old sample deleted, a fresh one saved, and the row re-stamped authored.
        await waitFor { service.deletedFernletWorkoutIDs.contains(workout.id) && service.saveWorkoutCallCount == 2 }
        #expect(service.deletedFernletWorkoutIDs == [workout.id])
        #expect(service.saveWorkoutCallCount == 2)
        await waitFor { store.day.workouts.first?.isHealthAuthored == true }
        #expect(store.day.workouts.first?.isHealthAuthored == true)   // re-stamped on the new sample
    }

    /// Finding A.3: a Health-app-side deletion (routed through `removeWorkoutByHealthKitUUID`) removes the
    /// local mirror row WITHOUT restoring a planned row or undoing guided/progression bookkeeping — an
    /// external deletion is not an accidental-completion undo.
    @Test func healthSideDeletionRemovesRowWithoutReversingGuidedState() throws {
        let store = makeTestStore()
        let session = guidedSession(name: "Solo Day", exercise: "Back Squat")
        store.completeGuidedRunnerSession(session)
        #expect(store.settings.workoutProgression["Back Squat"] == 1)
        #expect(store.guidedCompletedSessionIDs.contains(session.id))

        // Stamp the logged row as an authored Health sample (as the HK save would), then simulate the user
        // deleting that sample in the Health app.
        let logged = try #require(store.day.workouts.first { $0.name == "Solo Day" })
        let hkUUID = UUID()
        store.setWorkoutHealthKitUUID(workoutID: logged.id, hkUUID: hkUUID, date: store.todayKey)
        #expect(store.day.workouts.first?.isHealthAuthored == true)

        store.removeWorkoutByHealthKitUUID(hkUUID)

        #expect(store.day.workouts.isEmpty)                                  // mirror row removed
        #expect(store.day.plannedWorkouts.isEmpty)                          // NOT restored
        #expect(store.settings.workoutProgression["Back Squat"] == 1)       // progression untouched
        #expect(store.guidedCompletedSessionIDs.contains(session.id))       // completion NOT undone
    }

    // MARK: helpers

    @MainActor
    private func makeStore(healthKitService: any HealthKitServicing) -> FernletStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WorkoutRecoveryTests-\(UUID().uuidString)")
            .appendingPathExtension("json")
        return FernletStore(repository: LocalFernletRepository(fileURL: url), healthKitService: healthKitService)
    }

    private func waitFor(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<50 {
            if condition() { return }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Records the HealthKit calls the store's workout recover/edit path makes, and stamps a logged workout
/// so it becomes `healthKitAuthored` (as the real save does). Authorized by default so `saveWorkout` /
/// `deleteWorkout` actually fire.
@MainActor
private final class RecordingWorkoutHealthKitService: HealthKitServicing {
    private let authorized: Bool
    let saveWorkoutUUID = UUID()
    private(set) var saveWorkoutCallCount = 0
    private(set) var deletedFernletWorkoutIDs: [UUID] = []

    init(authorized: Bool) { self.authorized = authorized }

    func isHealthDataAvailable() -> Bool { true }
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome { AuthorizationOutcome(writeStatuses: [:]) }
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot {
        let statuses = authorized ? [HKObjectType.workoutType().identifier: HKAuthorizationStatus.sharingAuthorized] : [:]
        return AuthorizationSnapshot(isAvailable: true, writeStatuses: statuses)
    }
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws { }
    func startObservingWorkouts(handler: @escaping ([HKWorkout], [UUID]) -> Void) async throws { }
    func stopObservingWorkouts() { }
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] { [] }
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout] { [] }
    func save(_ samples: [HKObject]) async throws { }
    func delete(_ samples: [HKSample]) async throws { }
    func deleteWorkout(fernletWorkoutID: UUID) async throws -> Bool {
        deletedFernletWorkoutIDs.append(fernletWorkoutID)
        return true
    }
    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics] { [] }
    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func loadBodyProfile() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws { }
    func saveWorkout(_ workout: Workout) async throws -> UUID {
        saveWorkoutCallCount += 1
        return saveWorkoutUUID
    }
    func loadLastNightSleepHours(referenceDate: Date) async throws -> Double? { nil }
    func loadDailyHealthContext(referenceDate: Date, capabilities: Set<HealthCapability>?) async throws -> HealthDailyContext { HealthDailyContext() }
    func disableIntegration() async throws { }
    func enableIntegration() async throws { }
    func openHealthPrivacySettings() async { }
}
