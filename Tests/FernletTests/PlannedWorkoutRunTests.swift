// PlannedWorkoutRunTests.swift
// FernletTests
//
// Pins comparison report idea 17 (2026-10-20): a workout planned ahead in the plan sheet, or put on the
// calendar by a coach's plan, runs in the guided runner as written. Covered here: each kind of line
// becoming its step (sets × reps under the catalog's name, timed holds, cardio and mobility lines left
// for the run to time, a "mark done" step for anything else, a coach's own exercise), a weight the line
// names preselected over the load engine's suggestion, the engine filling in only what a line left out,
// starting the run (rest by name, the lines as written, the plan's id), finishing it (structured
// results, the planned row completed as "log it" does, no double log, a removal putting the plan back),
// and the guards (today only, a plan with lines, resume instead of restart). Round 2 adds the plan run
// as its own thing beside the generated plan: matched by its plan's id, never by name (a same-named plan
// neither marks the generated session logged, nor pins the plan, nor undoes its progress on removal),
// and an undo that puts back the plan's own lines (`Workout.plannedExercises`). What no test here can check
// — the Start button's look at AX5 and its Voice Control name on screen — is owed on the simulator.

import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
@testable import Fernlet

/// Serialized: the store tests stand up a real `FernletStore` and start a run, which reaches
/// process-global state (the `Activity<…>` registry behind the Live Activity bridge), as
/// `GuidedWorkoutRunStoreTests`.
@MainActor
@Suite(.serialized) struct PlannedWorkoutRunTests {

    // MARK: Fixtures

    /// "Today" for the line tests' load context.
    private nonisolated static let today = Date(timeIntervalSince1970: 1_790_000_000)

    /// A load context with `history` (normalized lift name → sessions, oldest first).
    private static func load(_ history: [String: [LiftExposure]]) -> WorkoutLoadContext {
        WorkoutLoadContext(exposures: history, today: today, defaultUnit: .lb)
    }

    /// Three completed sessions of `weight` × 8 over the last three weeks.
    private static func history(at weight: Double) -> [LiftExposure] {
        [21, 14, 7].map { daysAgo in
            LiftExposure(
                date: today.addingTimeInterval(Double(-daysAgo) * 86_400), weight: weight, unit: .lb, targetReps: 8,
                repsPerSet: [8, 8, 8], rangeLow: weight - 10, rangeHigh: weight + 10, structured: true
            )
        }
    }

    /// The step a plan line becomes, read the way the app reads it, against the bundled catalog only (a
    /// custom exercise another suite registered can't change the answer).
    private static func step(_ text: String, history: [String: [LiftExposure]]? = nil) -> WorkoutPlanRun.Step {
        WorkoutPlanRun.step(
            for: text, parsed: PlannedWorkoutRun.parsedLine(text), location: .fullGym,
            load: load(history ?? [:]), catalog: WorkoutExerciseCatalog.baseExercises
        )
    }

    private static func plan(_ lines: [String], source: WorkoutPlanSource = .coach, split: WorkoutSplit = .push) -> PlannedWorkout {
        PlannedWorkout(name: "Coach push", split: split, source: source, exercises: lines.joined(separator: "\n"),
                       muscleGroups: [.chest], notes: "Keep two reps in reserve.", duration: 45)
    }

    /// A store with `planned` on today's calendar.
    private static func store(planning planned: PlannedWorkout) -> FernletStore {
        let store = makeTestStore()
        store.planWorkout(planned, date: store.todayKey)
        return store
    }

    /// One earlier guided session of `name` at `weight` × 8, logged `daysAgo` days back.
    private static func logEarlier(_ name: String, weight: Double, daysAgo: Int, in store: FernletStore) {
        let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: .now) ?? .now
        let result = ExerciseResult(
            name: name, prescribedSets: 3, targetReps: 8, rangeLow: weight - 10, rangeHigh: weight + 10,
            suggestedWeight: weight, selectedWeight: weight, unit: .lb, equipment: .barbell
        )
        let workout = Workout(
            name: "Earlier", type: .upper, exercises: result.loggedLine, rpe: nil, notes: "", duration: nil,
            loggedFromGuidedSession: true, intensity: .moderate, exerciseResults: [result]
        )
        store.addWorkout(workout, date: FernletDate.dayKey(for: date))
    }

    /// The weight a step's guidance prescribes (fixed for a written weight, the engine's range otherwise).
    private static func prescription(of step: WorkoutPlanRun.Step) throws -> WeightPrescription {
        let guidance = try #require(step.exercise.guidance)
        return try #require(guidance.prescription)
    }

    /// A run step's load tracking.
    private static func tracking(of exercise: GuidedWorkoutRunState.Exercise?) throws -> GuidedWorkoutRunState.Tracking {
        let step = try #require(exercise)
        return try #require(step.tracking)
    }

    /// Today's logged rows that completed `planned`.
    private static func logs(of planned: PlannedWorkout, in store: FernletStore) -> [Workout] {
        store.day.workouts.filter { $0.plannedWorkoutID == planned.id }
    }

    /// Commits today's generated plan as one deterministic session named `name` (one set of bench, so a
    /// single "done" finishes it), as `GuidedWorkoutRunStoreTests` does. Returns the session.
    private static func commitGenerated(named name: String, in store: FernletStore) -> WorkoutProgram.SessionSuggestion {
        let lift = PrescribedExercise(name: "Bench Press", sets: 1, reps: "5", role: .main, fromCatalog: true)
        let session = WorkoutProgram.SessionSuggestion(
            title: name, timeLabel: "", kind: .strength, exercises: [lift],
            suggestion: WorkoutSuggestion(name: name, exercises: lift.line, notes: "")
        )
        let base = store.commitTodaysGuidedWorkoutPlan(intensity: .moderate)
        let plan = WorkoutProgram.DayPlan(
            splitName: "Test", dayTitle: "Day", sessions: [session], droppedSlots: [], locationName: "Test"
        )
        store.replaceGuidedWorkoutPlan(plan, replacing: Set(base.sessions.map(\.id)))
        return session
    }

    /// Starts `planned`'s run from its row's Start, the way the Move root does.
    private static func startedRun(of planned: PlannedWorkout, in store: FernletStore) throws -> GuidedWorkoutRunState {
        let session = try #require(store.guidedSession(forPlanned: planned, date: store.todayKey))
        #expect(store.startGuidedRun(session))
        return try #require(store.guidedRunState)
    }

    // MARK: Lines become steps

    @Test func setsTimesRepsBecomeCountedSetsUnderTheCatalogsName() throws {
        let step = Self.step("bench press - 3 x 8")
        #expect(step.exercise.name == "Bench press")
        #expect(step.exercise.sets == 3)
        #expect(step.exercise.reps == "8")
        #expect(step.exercise.fromCatalog)
        #expect(step.exercise.holdSeconds == nil)
        #expect(step.writtenLine == nil, "the step reads exactly as the line")
        #expect(step.weightAsWritten == false)
        // A catalog lift with no history still gets guidance, so the runner asks for a weight.
        let guidance = try #require(step.exercise.guidance)
        #expect(guidance.targetReps == 8)
        #expect(guidance.prescription == nil)
        #expect(guidance.equipment == .barbell)
        // Squats and hinges rest like main lifts; core work like core.
        #expect(Self.step("Back squat - 5 x 5").exercise.role == .main)
        #expect(Self.step("Plank - 3 x 30 s").exercise.role == .core)
        // A written range stays the range.
        #expect(Self.step("Dumbbell row - 3 x 8-12").exercise.reps == "8-12")
    }

    @Test func aWeightTheLineNamesIsKeptAsWritten() throws {
        let pounds = Self.step("Bench press - 3 x 8 @ 135 lb")
        #expect(pounds.weightAsWritten)
        #expect(pounds.writtenLine == nil)
        let fixed = try Self.prescription(of: pounds)
        #expect(fixed.suggested == 135)
        #expect(fixed.low == 135)
        #expect(fixed.high == 135)
        #expect(fixed.unit == .lb)
        #expect(fixed.step == 5)

        let kilos = Self.step("Romanian deadlift - 4 x 8 @ 60kg")
        let metric = try Self.prescription(of: kilos)
        #expect(metric.suggested == 60)
        #expect(metric.unit == .kg)
        #expect(metric.step == 2.5)
        #expect(kilos.exercise.sets == 4)
    }

    @Test func holdsBecomeTimedSets() {
        let plank = Self.step("Plank - 3 x 30 s")
        #expect(plank.exercise.name == "Plank")
        #expect(plank.exercise.sets == 3)
        #expect(plank.exercise.holdSeconds == 30)
        #expect(plank.exercise.reps == "30 s")
        #expect(plank.exercise.guidance == nil)
        #expect(plank.writtenLine == nil)

        // A coach's "30s each side" is a 30-second hold, with the line kept on screen.
        let sidePlank = Self.step("Side plank - 3 x 30s each side")
        #expect(sidePlank.exercise.holdSeconds == 30)
        #expect(sidePlank.writtenLine == "Side plank - 3 x 30s each side")

        // A single hold with no sets.
        let single = Self.step("Plank - 45 s")
        #expect(single.exercise.sets == 1)
        #expect(single.exercise.holdSeconds == 45)
        #expect(single.writtenLine == nil)
    }

    @Test func cardioAndMobilityLinesAreLeftForTheRunToTime() {
        let steady = Self.step("Easy cardio - 20 min")
        #expect(steady.exercise.sets == 0)
        #expect(steady.exercise.fromCatalog == false)
        #expect(steady.exercise.name == "Easy cardio - 20 min")
        #expect(WorkoutTimedSessions.isGuidable(steady.exercise))

        // Checked before the line parser, which would read "8 × 1" as eight sets of one rep.
        let intervals = Self.step("Intervals - 8 × 1 min hard / 1 min easy")
        #expect(intervals.exercise.sets == 0)
        #expect(intervals.exercise.name == "Intervals - 8 × 1 min hard / 1 min easy")
        #expect(WorkoutTimedSessions.expand([intervals.exercise], feasible: []).count == 16)

        let flow = Self.step("Mobility flow - 15 min")
        #expect(flow.exercise.sets == 0)
        #expect(WorkoutTimedSessions.isGuidable(flow.exercise))
    }

    @Test func linesTheRunnerCannotCountAreMarkedDoneShowingTheirText() {
        let lines = [
            "Push-up - 3 x AMRAP",
            "Rowing machine - 3 x 500 m",
            "Warm-up stretch flow - 9 min",
            "Stretch it out however feels good",
        ]
        for line in lines {
            let step = Self.step(line)
            #expect(step.exercise.name == line, "\(line) shows its own text")
            #expect(step.exercise.sets == 0, "\(line) is one step, marked done")
            #expect(step.exercise.fromCatalog == false)
            #expect(step.exercise.guidance == nil)
            #expect(WorkoutTimedSessions.isGuidable(step.exercise) == false, "\(line) is not timed")
        }
    }

    @Test func aCoachsOwnExerciseStillCountsItsSets() throws {
        let cued = Self.step("Sandbag shouldering - 3 x 8 (slow down)")
        #expect(cued.exercise.name == "Sandbag shouldering")
        #expect(cued.exercise.sets == 3)
        #expect(cued.exercise.reps == "8")
        #expect(cued.exercise.fromCatalog, "a counted step: set strip, pills and rests")
        #expect(cued.exercise.guidance == nil, "no engine guess for a lift the catalog doesn't know")
        #expect(cued.writtenLine == "Sandbag shouldering - 3 x 8 (slow down)")

        // A weight it names is still preselected, on a barbell's step.
        let weighted = Self.step("Sandbag shouldering - 3 x 8 @ 95 lb")
        #expect(weighted.weightAsWritten)
        let fixed = try Self.prescription(of: weighted)
        #expect(fixed.suggested == 95)
        #expect(fixed.step == 5)
        let guidance = try #require(weighted.exercise.guidance)
        #expect(guidance.equipment == nil)
    }

    // MARK: The load engine fills in only what the line left out

    @Test func theEngineSuggestsAWeightOnlyWhenTheLineNamesNone() throws {
        let history = ["bench press": Self.history(at: 185)]
        let open = Self.step("Bench press - 3 x 8", history: history)
        let suggested = try Self.prescription(of: open).suggested
        #expect(suggested >= 185, "completed sessions at 185 lb move the suggestion up, not down")
        #expect(open.weightAsWritten == false)

        let written = Self.step("Bench press - 3 x 8 @ 135 lb", history: history)
        let fixed = try Self.prescription(of: written)
        #expect(fixed.suggested == 135, "the line's weight wins over the engine's")
        #expect(written.weightAsWritten)

        // The engine never rewrites the sets or reps the line gave.
        let fives = Self.step("Bench press - 5 x 5", history: history)
        #expect(fives.exercise.sets == 5)
        #expect(fives.exercise.reps == "5")
    }

    @Test func theCoachsWeightIsPreselectedOverTheEnginesSuggestionInTheRun() throws {
        let planned = Self.plan(["Bench press - 3 x 8 @ 135 lb", "Barbell row - 3 x 8"])
        let store = Self.store(planning: planned)
        for daysAgo in [9, 6, 3] {
            Self.logEarlier("Bench press", weight: 185, daysAgo: daysAgo, in: store)
            Self.logEarlier("Barbell row", weight: 155, daysAgo: daysAgo, in: store)
        }
        let run = try Self.startedRun(of: planned, in: store)
        #expect(run.plannedWorkoutID == planned.id)
        #expect(run.exercises.count == 2)

        let bench = try Self.tracking(of: run.exercises.first)
        #expect(bench.selected == 135)
        #expect(bench.suggested == 135)
        #expect(bench.rangeLow == nil, "the plan's weight is not one of Fernlet's ranges")
        #expect(bench.rangeHigh == nil)
        #expect(bench.asWritten == true)
        #expect(bench.isLoadable)

        let row = try Self.tracking(of: run.exercises.last)
        let rowSuggestion = try #require(row.suggested)
        #expect(rowSuggestion >= 155, "the row's line named no weight, so the engine suggests one")
        #expect(row.selected == row.suggested)
        #expect(row.asWritten == nil)
        #expect(row.rangeLow != nil)
    }

    // MARK: Starting the run

    @Test func theRunRestsByNameAndCarriesTheLinesAsWritten() throws {
        let planned = Self.plan(["Bench press - 3 x 8 (RPE 7)", "Easy cardio - 20 min", "Foam roll everything"])
        let store = Self.store(planning: planned)
        let session = try #require(store.guidedSession(forPlanned: planned, date: store.todayKey))
        #expect(session.suggestion.name == planned.displayedName)
        #expect(session.exercises.count == 3, "no warm-up or cool-down added to a plan run as written")
        #expect(store.isPlannedRun(session))

        // The Ready screen lists every line as written.
        let link = try #require(store.plannedRunLink(for: session))
        let listed = session.exercises.compactMap { link.lines[$0.id] }
        #expect(listed == ["Bench press - 3 x 8 (RPE 7)", "Easy cardio - 20 min", "Foam roll everything"])

        #expect(store.startGuidedRun(session))
        let run = try #require(store.guidedRunState)
        let bench = try #require(run.exercises.first)
        #expect(bench.name == "Bench press")
        #expect(bench.writtenLine == "Bench press - 3 x 8 (RPE 7)", "the coach's cue stays on screen")
        let rest = WorkoutRestGuidance.restSeconds(forExerciseNamed: "Bench press", role: .accessory, goal: store.settings.selectedGoal)
        #expect(bench.restSeconds == rest)
        // The cardio line runs as its one timed segment; the last line as one step marked done.
        #expect(run.exercises.count == 3)
        let cardio = run.exercises[1]
        #expect(cardio.holdSeconds == 1_200)
        #expect(cardio.segment != nil)
        let done = run.exercises[2]
        #expect(done.name == "Foam roll everything")
        #expect(done.sets == 0)
        #expect(store.isPlannedRun(session), "still a plan's run once under way")
    }

    @Test func startIsOfferedForTodaysPlansWithLinesOnly() throws {
        #expect(PlannedWorkoutRun.canGuide(Self.plan(["Bench press - 3 x 8"])))
        #expect(PlannedWorkoutRun.canGuide(Self.plan([])) == false, "nothing to run")
        let long = Array(repeating: "Push-up - 3 x 10", count: WorkoutPlanRun.maximumLines + 1)
        #expect(PlannedWorkoutRun.canGuide(Self.plan(long)) == false, "logged, not guided, so no line is left out")

        let planned = Self.plan(["Bench press - 3 x 8"])
        let store = Self.store(planning: planned)
        let pastDay = store.guidedSession(forPlanned: planned, date: "2001-01-01")
        let offeredOnAPastDay = pastDay != nil
        #expect(offeredOnAPastDay == false, "today's plans only")

        // A second Start while the plan's run is under way resumes it rather than starting over.
        let run = try Self.startedRun(of: planned, in: store)
        let again = try #require(store.guidedSession(forPlanned: planned, date: store.todayKey))
        #expect(again.id == run.sessionID)
    }

    // MARK: Finishing the run

    @Test func finishingCompletesThePlannedRowAndLogsWhatWasDone() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb", "Sandbag shouldering - 1 x 8 (slow down)", "Foam roll everything"])
        let store = Self.store(planning: planned)
        let run = try Self.startedRun(of: planned, in: store)
        store.guidedMarkSetDone()   // bench, its only set → the squat
        store.guidedMarkSetDone()   // the squat → the line marked done
        store.guidedMarkSetDone()   // the last step → finish
        let finished = try #require(store.guidedRunState)
        #expect(finished.isFinishedNaturally)

        let stillPlanned = store.day.plannedWorkouts.contains { $0.id == planned.id }
        #expect(stillPlanned == false, "the planned row is completed, as \"log it\" does")
        let logged = Self.logs(of: planned, in: store)
        #expect(logged.count == 1)
        let workout = try #require(logged.first)
        #expect(workout.name == planned.name)
        #expect(workout.type == planned.workoutType)
        #expect(workout.muscleGroups == planned.muscleGroups)
        #expect(workout.notes == WorkoutPlanSource.coach.completionNote)
        #expect(workout.duration == 45, "a lifting plan keeps its planned length")
        #expect(workout.intensity == .moderate)
        #expect(workout.loggedFromGuidedSession == true)
        #expect(workout.exercises == "Bench press - 1 x 5 @ 135 lb\nSandbag shouldering - 1 x 8 (slow down)\nFoam roll everything")
        #expect(store.guidedCompletedSessionIDs.contains(run.sessionID))

        // Structured, as a guided run logs: the weight as written, no range.
        let results = try #require(workout.exerciseResults)
        #expect(results.count == 1)
        let bench = try #require(results.first)
        #expect(bench.name == "Bench press")
        #expect(bench.selectedWeight == 135)
        #expect(bench.suggestedWeight == 135)
        #expect(bench.rangeLow == nil)
        #expect(bench.unit == .lb)

        // The generated plan's rep ladder is left alone, as "log it" leaves it.
        #expect(store.settings.workoutProgression["Bench press"] == nil)

        // A reconcile after the finish logs nothing more.
        store.reconcileGuidedRunFromAppGroup()
        let afterReconcile = Self.logs(of: planned, in: store)
        #expect(afterReconcile.count == 1)
    }

    @Test func removingTheLoggedRunPutsTheCoachsPlanBack() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb"])
        let store = Self.store(planning: planned)
        _ = try Self.startedRun(of: planned, in: store)
        store.guidedMarkSetDone()
        let workout = try #require(Self.logs(of: planned, in: store).first)

        #expect(store.removeWorkout(id: workout.id, date: store.todayKey))
        let back = store.day.plannedWorkouts.filter { $0.id == planned.id }
        let restored = try #require(back.first)
        #expect(restored.source == .coach)
    }

    @Test func aRowTickedOffDuringTheRunIsNotLoggedTwice() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb"], source: .user)
        let store = Self.store(planning: planned)
        _ = try Self.startedRun(of: planned, in: store)
        store.completePlannedWorkout(planned, date: store.todayKey)
        store.guidedMarkSetDone()

        let logged = Self.logs(of: planned, in: store)
        #expect(logged.count == 1)
        #expect(store.day.workouts.count == 1)
    }

    @Test func aPlanRemovedDuringTheRunStillLogsTheRun() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb"], source: .user)
        let store = Self.store(planning: planned)
        _ = try Self.startedRun(of: planned, in: store)
        store.deletePlannedWorkout(planned, date: store.todayKey)
        store.guidedMarkSetDone()

        let logged = store.day.workouts.filter { $0.loggedFromGuidedSession == true }
        #expect(logged.count == 1, "the work done is never lost")
        let workout = try #require(logged.first)
        #expect(workout.plannedWorkoutID == nil)
    }

    @Test func aRunThatCrossedMidnightFilesUnderThePlansDayAtNoon() throws {
        let planned = Self.plan(["Stretch it out however feels good"], source: .user, split: .recovery)
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: .now) ?? .now
        let dayKey = FernletDate.dayKey(for: yesterday)
        let state = GuidedWorkoutRunState(
            sessionID: UUID(), committedDayKey: dayKey, intensityRaw: WorkoutIntensity.moderate.rawValue,
            title: planned.displayedName, suggestionExercisesText: planned.exercises, suggestionNotes: planned.notes,
            sessionKindRaw: SessionKind.mobility.rawValue,
            exercises: [GuidedWorkoutRunState.Exercise(name: planned.exercises, sets: 0, reps: "", roleRaw: "accessory",
                                                       fromCatalog: false, restSeconds: 0)]
        )
        let workout = PlannedWorkoutRun.loggedWorkout(for: planned, run: state, todayKey: FernletDate.dayKey(for: .now))
        #expect(workout.exercises == planned.exercises, "nothing tracked: the plan's own text")
        #expect(workout.plannedWorkoutID == planned.id)
        #expect(workout.duration == 45)
        #expect(FernletDate.dayKey(for: workout.completedAt) == dayKey)
        #expect(Calendar.current.component(.hour, from: workout.completedAt) == 12)
    }

    // MARK: A plan's run beside the generated plan

    @Test func aSameNamedPlanNeitherMarksTheGeneratedSessionLoggedNorPinsThePlan() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb"])
        let store = Self.store(planning: planned)
        let generated = Self.commitGenerated(named: planned.name, in: store)
        _ = try Self.startedRun(of: planned, in: store)
        store.guidedMarkSetDone()
        let logged = Self.logs(of: planned, in: store)
        #expect(logged.count == 1)
        let workout = try #require(logged.first)
        #expect(workout.isPlanRun)

        let names = store.loggedGuidedWorkoutNamesToday
        #expect(names.contains(planned.name) == false, "a plan's run is matched by its id, never by name")
        let alreadyLogged = GuidedWorkoutAvailability.isAlreadyLogged(
            generated, completed: store.guidedCompletedSessionIDs, loggedGuidedWorkoutNames: names
        )
        #expect(alreadyLogged == false, "the generated session of the same name is still to do")
        #expect(store.canReworkTodaysGuidedPlan, "nothing of the generated plan was logged")
    }

    @Test func removingAPlansRunLeavesTheGeneratedSessionsProgressAlone() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb"])
        let store = Self.store(planning: planned)
        let generated = Self.commitGenerated(named: planned.name, in: store)
        #expect(store.startGuidedRun(generated))
        store.guidedMarkSetDone()
        #expect(store.guidedCompletedSessionIDs.contains(generated.id))
        let ladder = store.settings.workoutProgression

        _ = try Self.startedRun(of: planned, in: store)
        store.guidedMarkSetDone()
        let workout = try #require(Self.logs(of: planned, in: store).first)
        #expect(store.removeWorkout(id: workout.id, date: store.todayKey))

        #expect(store.guidedCompletedSessionIDs.contains(generated.id), "the generated session stays done")
        #expect(store.settings.workoutProgression == ladder, "its rep ladder is not stepped back")
        #expect(store.canReworkTodaysGuidedPlan == false)
    }

    @Test func undoingAPlansRunPutsBackThePlansOwnLines() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb (pause at the chest)"], source: .user)
        let store = Self.store(planning: planned)
        _ = try Self.startedRun(of: planned, in: store)
        store.guidedMarkSetDone()
        let workout = try #require(Self.logs(of: planned, in: store).first)
        #expect(workout.exercises == "Bench press - 1 x 5 @ 135 lb", "the row records what was done")
        #expect(workout.plannedExercises == planned.exercises)

        // An edit (the sheet cannot reach the plan's lines) keeps them.
        var edited = workout
        edited.notes = "Felt quick."
        edited.plannedExercises = nil
        #expect(store.updateWorkout(edited, date: store.todayKey))

        #expect(store.removeWorkout(id: workout.id, date: store.todayKey))
        let back = store.day.plannedWorkouts.filter { $0.id == planned.id }
        let restored = try #require(back.first)
        #expect(restored.exercises == planned.exercises, "the plan as written, cue and all")
    }

    @Test func aPlanRemovedDuringTheRunLogsAsThatPlansRun() throws {
        let planned = Self.plan(["Bench press - 1 x 5 @ 135 lb"], source: .user)
        let store = Self.store(planning: planned)
        let generated = Self.commitGenerated(named: planned.name, in: store)
        #expect(store.startGuidedRun(generated))
        store.guidedMarkSetDone()
        let ladder = store.settings.workoutProgression

        _ = try Self.startedRun(of: planned, in: store)
        store.deletePlannedWorkout(planned, date: store.todayKey)
        store.guidedMarkSetDone()

        let runs = store.day.workouts.filter { $0.isPlanRun }
        #expect(runs.count == 1, "the generated session's same-named log does not swallow the run")
        let workout = try #require(runs.first)
        #expect(workout.plannedWorkoutID == nil)
        #expect(workout.plannedExercises == planned.exercises)
        #expect(store.settings.workoutProgression == ladder, "a plan's run never climbs the generated ladder")
    }

    @Test func plannedExercisesRoundTripsAndIsAbsentWhenUnset() throws {
        var workout = Workout(
            name: "Coach push", type: .upper, exercises: "Bench press - 1 x 5 @ 135 lb", rpe: nil, notes: "",
            duration: nil, loggedFromGuidedSession: true, intensity: .moderate
        )
        let plain = try JSONEncoder().encode(workout)
        let plainText = String(decoding: plain, as: UTF8.self)
        #expect(plainText.contains("plannedExercises") == false, "an unset field writes no key")
        let fromPlain = try JSONDecoder().decode(Workout.self, from: plain)
        #expect(fromPlain.plannedExercises == nil)
        #expect(fromPlain.isPlanRun == false)

        workout.plannedExercises = "Bench press - 1 x 5 @ 135 lb (pause at the chest)"
        let data = try JSONEncoder().encode(workout)
        let decoded = try JSONDecoder().decode(Workout.self, from: data)
        #expect(decoded.plannedExercises == workout.plannedExercises)
        #expect(decoded.isPlanRun)
    }
}
