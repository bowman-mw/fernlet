import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Store-level coverage for the guided-run flow that backs the interactive Live Activity: the approval
/// gate (the Move-root card), starting a run (per-exercise rest baked in + mirrored to the app group),
/// the mark-set-done → finish → log path (deduped), and the manual editor's session replacement.
///
/// Serialized: each test stands up a real `FernletStore`, which reaches process-global state the
/// app-group seam does not cover — the `Activity<…>` registries behind `GuidedWorkoutActivityBridge`,
/// `WorkoutExerciseCatalog`, and `NotificationCenter.default`. It is NO LONGER about the run file:
/// that used to be one process-wide app-group path, raced by every concurrent `resetAll`, and is now
/// per-test (below). The `store.clearGuidedRun()` calls each test opens with are the scar tissue from
/// that era — kept because they are harmless and one of them is asserted, not because they are needed.
@MainActor
@Suite(.serialized)
struct GuidedWorkoutRunStoreTests {

    /// THIS test's app-group root. Swift Testing builds a fresh suite value per test, so every store a
    /// single test creates shares one directory — which is exactly what the two relaunch tests below
    /// need, since the surviving run file IS their fixture — while no other suite can reach it.
    private let appGroupDirectory = uniqueAppGroupDirectory()

    /// A store on this test's app-group root. Everything else stays defaulted (and therefore isolated).
    private func makeStore() -> FernletStore {
        makeTestStore(appGroupDirectory: appGroupDirectory)
    }

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
        let store = makeStore()
        store.clearGuidedRun()
        commitPlan(store, session("Push", [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)]))
        // Committing (Suggest) does not approve — the card stays hidden until the user approves.
        #expect(store.isTodaysGuidedPlanApproved == false)
        store.approveTodaysGuidedPlan()
        #expect(store.isTodaysGuidedPlanApproved == true)
        // Reworking drops approval again.
        #expect(store.reworkTodaysGuidedPlan() == true)
        #expect(store.isTodaysGuidedPlanApproved == false)
    }

    // MARK: Start a run

    @Test func startGuidedRunBakesPerExerciseRestAndMirrors() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Push", [
            PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true),
            PrescribedExercise(name: "Curl", sets: 3, reps: "12", role: .accessory, fromCatalog: true, restSecondsOverride: 42),
        ])
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)

        let run = try #require(store.guidedRunState)
        #expect(run.isWorking == true)
        #expect(run.sessionID == s.id)
        #expect(run.exercises.count == 2)
        // No override → research default for a main lift under the (test) goal; override → verbatim.
        #expect((run.exercises.first?.restSeconds ?? 0) > 0)
        #expect(run.exercises.last?.restSeconds == 42)
    }

    /// A run started from a planned session counts down from the plan card's estimate to the second
    /// (`WorkoutSessionTime`): a session fitted to 30 minutes says ~30 on the card and in the runner.
    /// Sport conditioning carries a descriptor step, so its named minutes are compared too.
    @Test func aStartedRunCountsDownFromThePlanCardsEstimate() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let goal = store.settings.selectedGoal
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced, goalFit: [goal],
                                  days: [WorkoutSplitDay(title: "Day", sessions: [WorkoutSessions.sportConditioning])])
        let planned = WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
            location: .fullGym, context: "", split: split, rotationIndex: 0,
            options: WorkoutSessionOptions(length: .min30)
        )
        let s = try #require(planned.sessions.first)
        #expect(s.exercises.contains { $0.sets == 0 }, "the conditioning descriptor is in the run")
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        let run = try #require(store.guidedRunState)
        #expect(run.estimatedSecondsRemaining() == WorkoutSessionTime.seconds(of: s.exercises, goal: goal))
    }

    /// The Intervals session's line names no minutes ("8 × 1 min hard / 1 min easy"). The card once
    /// priced it at the five-minute fallback while the runner counted all sixteen parts; the card now
    /// costs its eight rounds, and a run started from it counts down from the same total.
    @Test func aStartedIntervalRunCountsDownFromThePlanCardsEstimate() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let goal = store.settings.selectedGoal
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced, goalFit: [goal],
                                  days: [WorkoutSplitDay(title: "Day", sessions: [WorkoutSessions.intervals])])
        let planned = WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
            location: .fullGym, context: "", split: split, rotationIndex: 0
        )
        let s = try #require(planned.sessions.first)
        let line = "Intervals - 8 × 1 min hard / 1 min easy"
        #expect(s.exercises.contains { $0.name == line && $0.sets == 0 }, "the interval line is in the plan")
        #expect(WorkoutSessionTime.seconds(of: s.exercises, goal: goal) >= 16 * 60, "eight two-minute rounds")
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        let run = try #require(store.guidedRunState)
        #expect(run.exercises.filter { $0.segment != nil }.count == 16, "each round's hard and easy parts")
        #expect(run.estimatedSecondsRemaining() == WorkoutSessionTime.seconds(of: s.exercises, goal: goal))
    }

    /// A planned lifting session — warm-up, activation, lifts, cool-down — starts its run at the plan
    /// card's estimate with its changeovers in it: about a minute before each exercise after the first.
    @Test func aStartedLiftingRunCountsTheChangeoversTheCardCounts() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let goal = store.settings.selectedGoal
        let split = TrainingSplit(id: "probe", name: "Probe", specificity: .balanced, goalFit: [goal],
                                  days: [WorkoutSplitDay(title: "Day", sessions: [WorkoutSessions.upper])])
        let planned = WorkoutProgram.dayPlan(
            goal: goal, intensity: .moderate, profile: WorkoutProfile(experience: .intermediate),
            location: .fullGym, context: "", split: split, rotationIndex: 0
        )
        let s = try #require(planned.sessions.first)
        let changeovers = WorkoutSessionTime.changeovers(in: s.exercises)
        #expect(changeovers >= 2, "the lifts change over")
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        let run = try #require(store.guidedRunState)
        #expect(run.changeoverSecondsAhead() == changeovers * WorkoutSessionTime.changeoverSeconds)
        #expect(run.estimatedSecondsRemaining() == WorkoutSessionTime.seconds(of: s.exercises, goal: goal))
    }

    // MARK: Mark set done → finish → log (deduped)

    @Test func finishingAGuidedRunLogsOnceAndClears() {
        let store = makeStore()
        store.clearGuidedRun()
        // One 1-set exercise so a single "done" finishes the workout.
        let s = session("Quick", [PrescribedExercise(name: "Bench Press", sets: 1, reps: "5", role: .main, fromCatalog: true)])
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)

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

    // MARK: Skip to next exercise (MOVE-26)

    @Test func skipToNextExerciseJumpsPastRemainingSetsWithoutFinishing() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Push", [
            PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true),
            PrescribedExercise(name: "Curl", sets: 2, reps: "12", role: .accessory, fromCatalog: true),
        ])
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        store.guidedMarkSetDone()   // Bench set 1 done → resting, 2 sets remain

        store.guidedSkipToNextExercise()

        let run = try #require(store.guidedRunState)
        #expect(run.isWorking == true)
        #expect(run.exerciseIndex == 1)
        #expect(run.currentSet == 1)
        // Skipping walked through markSetDone/skipRest, so it must NOT have finished (and logged).
        #expect(run.isDone == false)
        #expect(store.day.workouts.filter { $0.name == "Push" }.isEmpty)
    }

    @Test func skipToNextExerciseIsANoOpOnTheLastExercise() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Solo", [PrescribedExercise(name: "Bench", sets: 2, reps: "8", role: .main, fromCatalog: true)])
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)

        store.guidedSkipToNextExercise()

        // Nothing next → guarded no-op: still working the same exercise, nothing logged.
        let run = try #require(store.guidedRunState)
        #expect(run.isWorking == true)
        #expect(run.exerciseIndex == 0)
        #expect(run.currentSet == 1)
        #expect(store.day.workouts.filter { $0.name == "Solo" }.isEmpty)
    }

    // MARK: Editor

    @Test func updateGuidedSessionReplacesExercisesWhileNothingLogged() throws {
        let store = makeStore()
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
        #expect(store.startGuidedRun(try #require(committed)) == true)
        #expect(store.guidedRunState?.exercises.first?.restSeconds == 180)
    }

    @Test func updateGuidedSessionRefusedAfterASessionIsLogged() {
        let store = makeStore()
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
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Push", [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)])
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        store.guidedMarkSetDone()   // resting on set 2 — active, freshly touched

        // Simulate a relaunch: a fresh store (no committed plan in memory) reconciles from the group.
        let relaunched = makeStore()
        relaunched.reconcileGuidedRunFromAppGroup()
        #expect(relaunched.guidedRunState?.sessionID == s.id)   // adopted, not discarded
        #expect(relaunched.currentGuidedWorkoutPlan == nil)     // plan is session-scoped — gone

        // …and it can be resumed in-app purely from the run state (the Move-root Resume card path).
        let resume = relaunched.guidedSessionForResume()
        #expect(resume?.id == s.id)                              // same id → the sheet's run match holds
        #expect(resume?.exercises.first?.name == "Bench")
        relaunched.clearGuidedRun()
    }

    /// The detour past the Resume card: after a relaunch the user opens Suggest instead of resuming,
    /// mints a NEW session, and taps Start. That must not silently discard the run already in progress —
    /// the store refuses until the Ready screen has confirmed the replacement.
    @Test func startingADifferentSessionCannotClobberALiveRunWithoutConfirmation() throws {
        let store = makeStore()
        store.clearGuidedRun()
        let inProgress = session("Legs", [PrescribedExercise(name: "Squat", sets: 3, reps: "5", role: .main, fromCatalog: true)])
        commitPlan(store, inProgress)
        #expect(store.startGuidedRun(inProgress) == true)
        store.guidedMarkSetDone()   // partway in: set 1 done, now resting before set 2
        let progressed = try #require(store.guidedRunState)
        #expect(progressed.currentSet == 2)

        // A fresh session minted after the relaunch — different id, same store.
        let freshlyMinted = session("Push", [PrescribedExercise(name: "Bench", sets: 3, reps: "8", role: .main, fromCatalog: true)])
        #expect(store.activeGuidedRunBlockingStart(of: freshlyMinted)?.sessionID == inProgress.id)
        #expect(store.startGuidedRun(freshlyMinted) == false)

        // The live run is untouched — same session, same cursor…
        #expect(store.guidedRunState?.sessionID == inProgress.id)
        #expect(store.guidedRunState?.currentSet == progressed.currentSet)
        #expect(store.guidedRunState?.isResting == true)
        // …and so is the app-group mirror the Live Activity advances (a fresh store adopts the old run).
        let relaunched = makeStore()
        relaunched.reconcileGuidedRunFromAppGroup()
        #expect(relaunched.guidedRunState?.sessionID == inProgress.id)

        // Resuming the SAME session is never blocked — that path is a resume, not a replacement.
        #expect(store.activeGuidedRunBlockingStart(of: inProgress) == nil)

        // Once the user confirms on the Ready screen, the replacement goes through.
        #expect(store.startGuidedRun(freshlyMinted, replacingActiveRun: true) == true)
        #expect(store.guidedRunState?.sessionID == freshlyMinted.id)
        #expect(store.guidedRunState?.currentSet == 1)
        store.clearGuidedRun()
    }

    // MARK: An intent's "Done set" reaches the open in-app run at once

    /// A Lock Screen or Siri "Done set" runs in the app's process but writes only the app-group file.
    /// It now posts `.guidedWorkoutRunAdvancedByIntent`, and the store (its widget bridge active)
    /// reconciles from the file straight away, so the next in-app tap acts on the intent's set instead
    /// of writing a stale run over it. Before the fix the in-app run stayed on set 1: "Skip rest" did
    /// nothing, the next "Done set" wrote set 2 over the intent's set 2, and one finished set was lost.
    @Test func anIntentDoneSetReachesTheOpenInAppRunAtOnce() async throws {
        let store = makeStore()
        store.clearGuidedRun()
        let s = session("Push", [PrescribedExercise(name: "Bench", sets: 4, reps: "8", role: .main, fromCatalog: true)])
        commitPlan(store, s)
        #expect(store.startGuidedRun(s) == true)
        store.activateWidgetBridge()
        #expect(store.guidedRunState?.currentSet == 1)

        let outcome = await GuidedWorkoutIntentRunner.markSetDone(directory: appGroupDirectory)
        #expect(outcome == .applied(.resting))
        // The observer is on the main queue; give it its turn (bounded, no wall clock).
        for _ in 0..<50 where store.guidedRunState?.phase != .resting {
            await Task.yield()
        }
        #expect(store.guidedRunState?.phase == .resting, "the in-app run never saw the intent's set")
        #expect(store.guidedRunState?.currentSet == 2)

        store.guidedSkipRest()
        store.guidedMarkSetDone()
        let file = try #require(GuidedWorkoutRunStateStore(directory: appGroupDirectory).read())
        #expect(file.currentSet == 3, "an in-app tap wrote a stale run over the intent's set")
        store.clearGuidedRun()
    }
}
