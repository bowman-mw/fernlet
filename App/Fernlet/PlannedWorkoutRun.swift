//
//  PlannedWorkoutRun.swift
//  Fernlet
//
//  Comparison report idea 17 (2026-10-20): run coach-imported and user-planned workouts in the guided
//  runner. Until now only the app's own generated sessions could be guided; a workout planned ahead in
//  the plan sheet, or put on the calendar by a coach's plan, could only be ticked off ("log it").
//
//  A planned row for today now offers "Start". Its lines become the runner's steps as written — sets ×
//  reps, timed holds, timed cardio and mobility lines, and a plain "mark done" step for anything else
//  (`WorkoutPlanRun` in FernletDomainModel decides; this file reads the lines with the app's own
//  `ExerciseLineParser`). Nothing is filtered or dropped and no warm-up or cool-down is added. A weight
//  the line names is preselected as written; a catalog lift whose line names none gets the load
//  engine's suggestion. Finishing logs what was done, with structured results, as any guided run does,
//  and completes the planned row exactly as "log it" does — the logged row carries the plan's id, so
//  removing it puts the plan back.
//

import Foundation
import DiaryStore
import FernletDomainModel
import FernletFoundation

/// The app's half of running a planned workout in the guided runner: reading its lines, the session
/// the runner walks, and the workout a finished run logs.
enum PlannedWorkoutRun {

    /// Whether `planned` can be run in the guided runner: it has at least one line, and no more than
    /// ``WorkoutPlanRun/maximumLines`` — a longer plan stays one tap to log, so no line is ever left out
    /// of a run.
    static func canGuide(_ planned: PlannedWorkout) -> Bool {
        let count = planned.exerciseLines.count
        return count > 0 && count <= WorkoutPlanRun.maximumLines
    }

    // MARK: Reading a line

    /// A sets × reps line whose "reps" carry a distance, time or energy unit ("Row - 3 x 500 m"): the line
    /// parser would read the 500 as reps, so such a line is left as written, a step marked done.
    private static let measuredReps =
        #/\d\s*[xX×]\s*\d{1,3}(?:\s*-\s*\d{1,3})?\s*(?:m|km|mi|miles?|yds?|yards?|ft|feet|meters?|metres?|cal|kcal|calories|min|mins|minutes?|hrs?|hours?)\b/#
            .ignoresCase()

    /// A single timed hold with no sets: "Plank - 45 s", "Side plank: 30 sec".
    private static let singleHold = #/^(.+?)\s*(?:[-–—:]\s*|\s)(\d{1,3})\s*(?:s|sec|secs|seconds)\s*$/#.ignoresCase()

    /// One line read into the pieces ``WorkoutPlanRun`` builds a step from, or nil for a line that is
    /// not sets × reps or a timed hold (it becomes a step marked done, showing the line).
    ///
    /// The app's ``ExerciseLineParser`` reads sets × reps and the weight ("Bench press - 3 x 8 @ 135 lb");
    /// a hold reads as "30 s" there and keeps its seconds here ("Plank - 3 x 30 s"; a range such as
    /// "30-45 s" holds its lower end, the line itself still shown).
    static func parsedLine(_ text: String) -> WorkoutPlanRun.ParsedLine? {
        guard text.firstMatch(of: measuredReps) == nil else { return nil }
        if let parsed = ExerciseLineParser.parse(text), let sets = parsed.sets, sets >= 1, let reps = parsed.reps {
            let hold = reps.hasSuffix(" s") ? Int(reps.prefix(while: \.isNumber)) : nil
            return WorkoutPlanRun.ParsedLine(
                name: parsed.name, sets: sets, reps: reps, holdSeconds: hold,
                weight: parsed.weight, unit: parsed.weightUnit.flatMap(LoadUnit.init(rawValue:))
            )
        }
        guard let match = text.firstMatch(of: singleHold), let seconds = Int(match.output.2), seconds > 0 else {
            return nil
        }
        let name = String(match.output.1).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        return WorkoutPlanRun.ParsedLine(
            name: name, sets: 1, reps: PrescribedExercise.holdText(seconds: seconds), holdSeconds: seconds
        )
    }

    // MARK: The session

    /// The run's steps for `planned`, one per line in the plan's own order — empty when it cannot be
    /// guided (``canGuide(_:)``).
    static func steps(for planned: PlannedWorkout, location: WorkoutLocation, load: WorkoutLoadContext) -> [WorkoutPlanRun.Step] {
        guard canGuide(planned) else { return [] }
        return planned.exerciseLines.map { line in
            WorkoutPlanRun.step(for: line, parsed: parsedLine(line), location: location, load: load)
        }
    }

    /// SEAM — a warm-up and cool-down around a planned workout.
    ///
    /// A coach's plan runs as written, and so does the person's own: nothing is added before or after its
    /// lines unless the person's Warm-up setting asks for it. That setting (the planner lane's idea 5:
    /// warm-up Full / Short / Off, and its Cool-down switch) is not on this branch, so today this adds
    /// nothing. When it merges, return its blocks here — the warm-up (`WorkoutSessionBlocks.warmUp`) when
    /// the setting is Full or Short, the cool-down (`WorkoutSessionBlocks.coolDown`, for `planned`'s
    /// muscles) when its switch is on, both from the equipment- and injury-filtered catalog — and the
    /// session below wraps the plan's own steps in them.
    static func addedBlocks(
        for planned: PlannedWorkout, settings: FernletSettings
    ) -> (warmUp: [PrescribedExercise], coolDown: [PrescribedExercise]) {
        ([], [])
    }

    /// The session the runner walks for `planned`: its steps (wrapped in any ``addedBlocks(for:settings:)``)
    /// under the plan's displayed name, with the plan's text and notes as the session's own.
    static func session(
        for planned: PlannedWorkout, steps: [WorkoutPlanRun.Step],
        blocks: (warmUp: [PrescribedExercise], coolDown: [PrescribedExercise]) = ([], [])
    ) -> WorkoutProgram.SessionSuggestion {
        let name = planned.displayedName
        return WorkoutProgram.SessionSuggestion(
            title: name, timeLabel: "", kind: sessionKind(for: planned),
            exercises: blocks.warmUp + steps.map(\.exercise) + blocks.coolDown,
            suggestion: WorkoutSuggestion(name: name, exercises: planned.exercises, notes: planned.notes)
        )
    }

    /// The kind of session a plan is, for the runner's timed logging: a recovery plan is a stretch
    /// session, a cardio plan (or any activity) a cardio one, everything else lifting.
    static func sessionKind(for planned: PlannedWorkout) -> SessionKind {
        switch planned.split {
        case .recovery: return .mobility
        case .cardio: return .cardio
        case .fullBody: return .fullBody
        default: return planned.mode == .activity ? .cardio : .strength
        }
    }

    // MARK: The log

    /// The workout a finished run of `planned` logs: the row "log it" would write
    /// (``PlannedWorkout/completedWorkout`` — the plan's name, split, muscles, targets and id, and the
    /// "Completed from coach plan." note that lets a removal put the plan back as a coach's), with what
    /// the run actually did in place of the plan: each tracked lift's line and its structured result,
    /// timed cardio and stretching's minutes actually held, tagged as a guided log. A run that crossed
    /// local midnight files under the plan's day at noon, as every guided log does.
    ///
    /// MERGE NOTE (2026-10-20): the History lane's idea 14 logs a guided run's wall-clock length from the
    /// run's own start and finish in `finishGuidedRunLogging`. A planned run logs here instead, so give
    /// it the same length at merge (ahead of the plan's own `duration`, after the held minutes).
    static func loggedWorkout(for planned: PlannedWorkout, run state: GuidedWorkoutRunState, todayKey: String) -> Workout {
        var workout = planned.completedWorkout
        workout.loggedFromGuidedSession = true
        if let log = GuidedRunLoadLog.log(for: state) {
            workout.exercises = log.text
            workout.exerciseResults = log.results.isEmpty ? nil : log.results
        }
        if let held = GuidedRunTimedLog.heldMinutes(for: state) { workout.duration = held }
        if workout.mode == .activity, workout.activityType == nil {
            workout.activityType = GuidedRunTimedLog.activityType(for: state)
        }
        let dayKey = state.committedDayKey
        if dayKey != todayKey, let date = FernletDate.date(fromDayKey: dayKey),
           let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: date) {
            workout.completedAt = noon
            workout.loggedAt = noon
        }
        return workout
    }
}

/// A planned workout's run as the store holds it between the row's Start and the runner's own Start:
/// the row it completes, the day it files under, and what the runner shows that the session's steps
/// cannot carry — every line as written, and which weights came written in them.
///
/// One at a time (``FernletStore/pendingPlannedRun``), matched by the session it was minted with. From
/// the runner's Start on, the run state itself carries the row's id and the lines, so a finish after a
/// relaunch still completes the row.
struct PlannedRunLink: Equatable {
    /// The session the runner was opened with.
    let sessionID: UUID
    /// The planned row a natural finish completes.
    let plannedWorkoutID: UUID
    /// The plan's day — the run files under it, as a guided run files under its committed day.
    let dayKey: String
    /// Every step's line exactly as written, by step id — what the Ready screen lists.
    let lines: [UUID: String]
    /// The lines that say more than their step shows (a cue, another spelling), by step id — shown
    /// under the exercise's name during the run.
    let writtenLines: [UUID: String]
    /// Steps whose weight the line named: preselected as written, with no range around it.
    let writtenWeightIDs: Set<UUID>

    /// The link for a session built from `steps`.
    init(sessionID: UUID, plannedWorkoutID: UUID, dayKey: String, steps: [WorkoutPlanRun.Step]) {
        assert(!dayKey.isEmpty, "a planned run files under its plan's day")
        self.sessionID = sessionID
        self.plannedWorkoutID = plannedWorkoutID
        self.dayKey = dayKey
        var lines: [UUID: String] = [:]
        var written: [UUID: String] = [:]
        var weights: Set<UUID> = []
        for step in steps {
            lines[step.exercise.id] = step.line
            if let line = step.writtenLine { written[step.exercise.id] = line }
            if step.weightAsWritten { weights.insert(step.exercise.id) }
        }
        self.lines = lines
        self.writtenLines = written
        self.writtenWeightIDs = weights
    }

    /// The intensity the run logs at — moderate, as "log it" logs a planned row.
    var intensity: WorkoutIntensity { .moderate }

    /// Hangs each step's written line on the run's steps, and turns a written weight into a weight as
    /// written: preselected (the guidance already suggests it), with no range — so leaving it is never
    /// read as an override of Fernlet's range, and the picker says it is the plan's.
    func annotate(_ exercises: inout [GuidedWorkoutRunState.Exercise]) {
        for index in exercises.indices {
            let id = exercises[index].id
            exercises[index].writtenLine = writtenLines[id]
            guard writtenWeightIDs.contains(id), var tracking = exercises[index].tracking else { continue }
            tracking.rangeLow = nil
            tracking.rangeHigh = nil
            tracking.asWritten = true
            exercises[index].tracking = tracking
        }
    }
}

// MARK: - Store seam

extension FernletStore {

    /// The session the runner opens for `planned`'s Start, or nil when it cannot be guided — a row not
    /// on today, or one with no lines or too many.
    ///
    /// When this plan's run is already under way, the session that resumes it; otherwise a fresh
    /// session built from the plan's lines (with the load engine reading the lifts' history), and the
    /// ``PlannedRunLink`` the runner's Start picks up.
    func guidedSession(forPlanned planned: PlannedWorkout, date: String) -> WorkoutProgram.SessionSuggestion? {
        guard date == todayKey, PlannedWorkoutRun.canGuide(planned) else { return nil }
        if let run = guidedRunState, !run.isDone, run.plannedWorkoutID == planned.id {
            return guidedSessionForResume()
        }
        let load = WorkoutLoadContextBuilder.build(days: loadDays(), today: day, todayKey: todayKey, settings: settings,
                                                   body: effectiveUserProfile)
        let steps = PlannedWorkoutRun.steps(for: planned, location: settings.activeWorkoutLocation, load: load)
        guard !steps.isEmpty else { return nil }
        let session = PlannedWorkoutRun.session(
            for: planned, steps: steps, blocks: PlannedWorkoutRun.addedBlocks(for: planned, settings: settings)
        )
        pendingPlannedRun = PlannedRunLink(sessionID: session.id, plannedWorkoutID: planned.id, dayKey: date, steps: steps)
        return session
    }

    /// The planned workout `session` was built for, until its run starts; nil for every other session.
    func plannedRunLink(for session: WorkoutProgram.SessionSuggestion) -> PlannedRunLink? {
        guard let link = pendingPlannedRun, link.sessionID == session.id else { return nil }
        return link
    }

    /// Whether `session` runs a planned workout — about to start, or already under way.
    func isPlannedRun(_ session: WorkoutProgram.SessionSuggestion) -> Bool {
        if plannedRunLink(for: session) != nil { return true }
        guard let run = guidedRunState, run.sessionID == session.id else { return false }
        return run.plannedWorkoutID != nil
    }

    /// Logs a finished planned run and completes its planned row, as "log it" does: the logged workout
    /// (``PlannedWorkoutRun/loggedWorkout(for:run:todayKey:)``) goes on the plan's day and the planned
    /// row comes off it. Returns false — leaving the run to log as an ordinary guided run — when the run
    /// is not a plan's, or the planned row is gone (removed during the run). A row already completed
    /// (ticked off during the run, or a finish seen twice) logs nothing more.
    ///
    /// The lifts are not counted toward the generated plan's rep ladder (`recordCompletedExercises`),
    /// just as "log it" does not count them, so removing the row undoes everything it did; the load
    /// engine still reads their structured results.
    func logPlannedRun(_ state: GuidedWorkoutRunState) -> Bool {
        guard let plannedID = state.plannedWorkoutID else { return false }
        let dayKey = state.committedDayKey
        let record = loadDay(for: dayKey)
        if record.workouts.contains(where: { $0.plannedWorkoutID == plannedID }) {
            markGuidedSessionCompleted(state.sessionID)
            return true
        }
        guard let planned = record.plannedWorkouts.first(where: { $0.id == plannedID }) else {
            FernletAuditLog.log("workout.plannedRun.planGone", context: ["date": dayKey])
            return false
        }
        addWorkout(PlannedWorkoutRun.loggedWorkout(for: planned, run: state, todayKey: todayKey), date: dayKey)
        diary.removePlannedWorkout(planned, date: dayKey)
        markGuidedSessionCompleted(state.sessionID)
        if pendingPlannedRun?.sessionID == state.sessionID { pendingPlannedRun = nil }
        return true
    }
}
