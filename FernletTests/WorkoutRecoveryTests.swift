import Foundation
import Testing
import FernletDomainModel
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

    @Test func updateWorkoutPreservesGuidedFlag() {
        let store = makeTestStore()
        var workout = Workout(
            name: "Guided", type: .fullBody, exercises: "circuit", rpe: nil, notes: "",
            duration: 20, loggedFromGuidedSession: true, intensity: .moderate
        )
        store.addWorkout(workout, date: store.todayKey)

        workout.name = "Guided (edited)"
        workout.loggedFromGuidedSession = nil   // dropped by the edit path
        #expect(store.updateWorkout(workout, date: store.todayKey))
        #expect(store.day.workouts[0].name == "Guided (edited)")
        #expect(store.day.workouts[0].loggedFromGuidedSession == true)   // re-asserted
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
}
