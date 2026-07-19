import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Store-level coverage for the guided-run flow that backs the interactive Live Activity: the approval
/// gate (the Move-root card), starting a run (per-exercise rest baked in + mirrored to the app group),
/// the mark-set-done → finish → log path (deduped), and the manual editor's session replacement.
///
/// Serialized: each test stands up a real `FernletStore`, and the guided run mirrors to a process-wide
/// app-group file — running in parallel would race that file. Each test clears it first.
@MainActor
@Suite(.serialized)
struct GuidedWorkoutRunStoreTests {

    private func session(_ name: String, _ exercises: [PrescribedExercise]) -> WorkoutProgram.SessionSuggestion {
        WorkoutProgram.SessionSuggestion(
            title: name, timeLabel: "", kind: .strength, exercises: exercises,
            suggestion: WorkoutSuggestion(name: name, exercises: exercises.map(\.line).joined(separator: "\n"), notes: "")
        )
    }

    /// Commit today's slot then swap in a deterministic single-session plan (the generated one is
    /// weekday/profile dependent). Returns the injected session.
    private func commitPlan(_ store: FernletStore, _ s: WorkoutProgram.SessionSuggestion) {
        let base = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let plan = WorkoutProgram.DayPlan(splitName: "Test", dayTitle: "Day", sessions: [s], droppedSlots: [], locationName: "Test")
        store.replaceGuidedWorkoutPlan(plan, replacing: Set(base.sessions.map(\.id)))
    }

    // MARK: Approval gate

    @Test func planIsNotApprovedUntilApproved() {
        let store = makeTestStore()
        store.clearGuidedRun()
        commitPlan(store, session("Push", [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)]))
        // Committing (Suggest) does not approve — the card stays hidden until the user approves.
        #expect(store.isTodaysGuidedPlanApproved == false)
        store.approveTodaysGuidedPlan()
        #expect(store.isTodaysGuidedPlanApproved == true)
        // Reworking drops approval again.
        store.reworkTodaysGuidedPlan()
        #expect(store.isTodaysGuidedPlanApproved == false)
    }

    // MARK: Start a run

    @Test func startGuidedRunBakesPerExerciseRestAndMirrors() throws {
        let store = makeTestStore()
        store.clearGuidedRun()
        let s = session("Push", [
            PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true),
            PrescribedExercise(name: "Curl", sets: 3, reps: "12", role: .accessory, fromCatalog: true, restSecondsOverride: 42),
        ])
        commitPlan(store, s)
        store.startGuidedRun(s)

        let run = try #require(store.guidedRunState)
        #expect(run.isWorking == true)
        #expect(run.sessionID == s.id)
        #expect(run.exercises.count == 2)
        // No override → research default for a main lift under the (test) goal; override → verbatim.
        #expect((run.exercises.first?.restSeconds ?? 0) > 0)
        #expect(run.exercises.last?.restSeconds == 42)
    }

    // MARK: Mark set done → finish → log (deduped)

    @Test func finishingAGuidedRunLogsOnceAndClears() {
        let store = makeTestStore()
        store.clearGuidedRun()
        // One 1-set exercise so a single "done" finishes the workout.
        let s = session("Quick", [PrescribedExercise(name: "Bench Press", sets: 1, reps: "5", role: .main, fromCatalog: true)])
        commitPlan(store, s)
        store.startGuidedRun(s)

        store.guidedMarkSetDone()   // 1 set, 1 exercise → finish

        #expect(store.guidedRunState?.isFinishedNaturally == true)
        let logged = store.day.workouts.filter { $0.name == "Quick" && $0.loggedFromGuidedSession == true }
        #expect(logged.count == 1)
        #expect(store.guidedCompletedSessionIDs.contains(s.id))
        #expect(store.settings.workoutProgression["Bench Press"] == 1)

        // A reconcile after the finish must not double-log (file was cleared; id is in the completed set).
        store.reconcileGuidedRunFromAppGroup()
        #expect(store.day.workouts.filter { $0.name == "Quick" }.count == 1)

        store.clearGuidedRun()
        #expect(store.guidedRunState == nil)
    }

    // MARK: Editor

    @Test func updateGuidedSessionReplacesExercisesWhileNothingLogged() throws {
        let store = makeTestStore()
        store.clearGuidedRun()
        let s = session("Upper", [
            PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true),
            PrescribedExercise(name: "Row", sets: 3, reps: "8", role: .main, fromCatalog: true),
        ])
        commitPlan(store, s)

        var edited = s
        edited.exercises = [PrescribedExercise(name: "Bench", sets: 4, reps: "5", role: .main, fromCatalog: true, restSecondsOverride: 180)]
        edited.suggestion.exercises = edited.exercises.map(\.line).joined(separator: "\n")
        #expect(store.updateGuidedSession(edited) == true)

        let committed = store.currentGuidedWorkoutPlan?.sessions.first
        #expect(committed?.id == s.id)                        // id preserved → completions stay valid
        #expect(committed?.exercises.count == 1)
        #expect(committed?.exercises.first?.sets == 4)
        #expect(committed?.exercises.first?.restSecondsOverride == 180)

        // The edit flows into the run's rest when started.
        store.startGuidedRun(try! #require(committed))
        #expect(store.guidedRunState?.exercises.first?.restSeconds == 180)
    }

    @Test func updateGuidedSessionRefusedAfterASessionIsLogged() {
        let store = makeTestStore()
        store.clearGuidedRun()
        let s = session("Upper", [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)])
        commitPlan(store, s)
        store.completeGuidedRunnerSession(s)   // now something is logged → plan is pinned

        var edited = s
        edited.exercises = []
        #expect(store.updateGuidedSession(edited) == false)
        #expect(store.currentGuidedWorkoutPlan?.sessions.first?.exercises.isEmpty == false)
    }

    // MARK: Resume after relaunch (the run survives; the in-memory plan does not)

    @Test func aRecentRunIsAdoptedByAFreshStoreAndResumable() {
        let store = makeTestStore()
        store.clearGuidedRun()
        let s = session("Push", [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)])
        commitPlan(store, s)
        store.startGuidedRun(s)
        store.guidedMarkSetDone()   // resting on set 2 — active, freshly touched

        // Simulate a relaunch: a fresh store (no committed plan in memory) reconciles from the group.
        let relaunched = makeTestStore()
        relaunched.reconcileGuidedRunFromAppGroup()
        #expect(relaunched.guidedRunState?.sessionID == s.id)   // adopted, not discarded
        #expect(relaunched.currentGuidedWorkoutPlan == nil)     // plan is session-scoped — gone

        // …and it can be resumed in-app purely from the run state (the Move-root Resume card path).
        let resume = relaunched.guidedSessionForResume()
        #expect(resume?.id == s.id)                              // same id → the sheet's run match holds
        #expect(resume?.exercises.first?.name == "Bench")
        relaunched.clearGuidedRun()
    }
}
