import Foundation
import FernletDomainModel

/// The two crossings between the domain's load plan and the guided run's app-group state.
///
/// At start, a lift's ``LoadGuidance`` becomes the run's ``GuidedWorkoutRunState/Tracking`` (the
/// suggestion preselected, so finishing untouched needs no extra tap). At finish, each tracked lift
/// becomes an ``ExerciseResult`` and its logged line ("Bench press - 3 x 8 @ 105 lb", with
/// "(did 8, 8, 6)" when edited), and the session's text is rebuilt around those lines. A lift the
/// runner skipped past is logged as skipped and never becomes a result, so a short-on-time skip is not
/// read as a miss. The run state cannot import the domain, so tokens cross as raw strings here.
enum GuidedRunLoadLog {

    /// The run's tracking record for a planned step, or nil when the planner attached no guidance.
    ///
    /// The target follows the step's reps when they parse, so a sets/reps edit in the editor sheet
    /// carries through.
    static func tracking(for exercise: PrescribedExercise) -> GuidedWorkoutRunState.Tracking? {
        guard let guidance = exercise.guidance, exercise.holdSeconds == nil else { return nil }
        let step = guidance.prescription?.step
            ?? guidance.equipment.flatMap { WorkoutLoadEngine.step(for: $0, unit: guidance.unit) }
        let isCalibration = guidance.calibration != nil
        return GuidedWorkoutRunState.Tracking(
            targetReps: Int(exercise.reps) ?? guidance.targetReps,
            rangeLow: isCalibration ? nil : guidance.prescription?.low,
            rangeHigh: isCalibration ? nil : guidance.prescription?.high,
            suggested: guidance.prescription?.suggested,
            step: step,
            unitRaw: step == nil ? nil : guidance.unit.rawValue,
            equipmentRaw: guidance.equipment?.rawValue,
            confidenceRaw: (guidance.prescription?.confidence ?? .none).rawValue,
            askReasonOnOverride: guidance.askReasonOnOverride,
            calibrationRaw: guidance.calibration?.rawValue,
            easierSession: guidance.easierSession,
            compoundsBefore: guidance.compoundsBefore,
            selected: guidance.prescription?.suggested
        )
    }

    /// Whether a planned step shows last time's numbers: a counted catalog lift, the same steps the
    /// runner's "Last time" pill appears on (never a hold, a stretch or a cardio line).
    static func showsLastTime(_ exercise: PrescribedExercise) -> Bool {
        exercise.fromCatalog && exercise.sets >= 1 && exercise.holdSeconds == nil
    }

    /// Last time's numbers for every logged lift, keyed by normalized name, from one history rollup
    /// (`FernletStore.exerciseHistoryEntries()`, most recently trained first — the first entry of a
    /// name wins). Bounded by the entries passed in.
    static func lastTimes(
        from entries: [TrainerExportBundle.ExerciseHistoryEntry]
    ) -> [String: GuidedWorkoutRunState.LastTime] {
        var byName: [String: GuidedWorkoutRunState.LastTime] = [:]
        for entry in entries {
            let key = WorkoutExerciseCatalog.normalizedName(entry.name)
            guard byName[key] == nil, let last = lastTime(from: entry) else { continue }
            byName[key] = last
        }
        return byName
    }

    /// One entry's last-time numbers — sets and reps, a weight, or both — or nil with neither. The
    /// unit crosses as the `LoadUnit` token the line parser wrote ("lb" / "kg"), or nil.
    static func lastTime(from entry: TrainerExportBundle.ExerciseHistoryEntry) -> GuidedWorkoutRunState.LastTime? {
        let sets = entry.lastSets.flatMap { $0 > 0 ? $0 : nil }
        let reps = entry.lastReps.flatMap { $0.isEmpty ? nil : $0 }
        let weight = entry.lastWeight.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        guard (sets != nil && reps != nil) || weight != nil else { return nil }
        return GuidedWorkoutRunState.LastTime(
            sets: sets, reps: reps, weight: weight,
            unitRaw: entry.weightUnit.flatMap(LoadUnit.init(rawValue:))?.rawValue
        )
    }

    /// One tracked lift's result, or nil for an untracked step or one the runner skipped.
    static func result(for exercise: GuidedWorkoutRunState.Exercise) -> ExerciseResult? {
        guard let tracking = exercise.tracking, tracking.skipped != true, exercise.fromCatalog else { return nil }
        return ExerciseResult(
            name: exercise.name, prescribedSets: max(1, exercise.sets), targetReps: tracking.targetReps,
            rangeLow: tracking.rangeLow, rangeHigh: tracking.rangeHigh,
            suggestedWeight: tracking.suggested, selectedWeight: tracking.selected,
            unit: tracking.unitRaw.flatMap(LoadUnit.init(rawValue:)),
            equipment: tracking.equipmentRaw.flatMap(Equipment.init(rawValue:)),
            actualReps: tracking.actualReps,
            effort: tracking.effortRaw.flatMap(ExerciseEffort.init(rawValue:)),
            overrideReason: tracking.overrideReasonRaw.flatMap(OverrideReason.init(rawValue:)),
            confidence: tracking.confidenceRaw.flatMap(EstimateConfidence.init(rawValue:)),
            calibration: tracking.calibrationRaw.flatMap(CalibrationStep.init(rawValue:)),
            easierSession: tracking.easierSession ? true : nil,
            compoundsBefore: tracking.compoundsBefore
        )
    }

    /// The finished run's log: its text with each tracked lift's own line, and the results — or
    /// nil when no step was tracked (a run from before load tracking keeps its plan text).
    static func log(for state: GuidedWorkoutRunState) -> (text: String, results: [ExerciseResult])? {
        guard state.exercises.contains(where: { $0.tracking != nil }) else { return nil }
        var lines: [UUID: String] = [:]
        var results: [ExerciseResult] = []
        for exercise in state.exercises {
            if let result = result(for: exercise) {
                results.append(result)
                lines[exercise.id] = result.loggedLine
            } else if exercise.tracking?.skipped == true {
                lines[exercise.id] = "\(exercise.name) - skipped"
            } else if let written = exercise.writtenLine {
                // A planned workout's untracked line logs as its plan wrote it, cue and all.
                lines[exercise.id] = written
            }
        }
        let steps = state.exercises.map { prescribed($0) }
        return (WorkoutSessionBlocks.planText(for: steps, loggedLines: lines), results)
    }

    /// A run step back as a domain step, for the plan-text layout (warm-up and cool-down summaries, and
    /// a cardio line's segments folded back into the line they came from).
    static func prescribed(_ exercise: GuidedWorkoutRunState.Exercise) -> PrescribedExercise {
        PrescribedExercise(
            id: exercise.id, name: exercise.name, sets: exercise.sets, reps: exercise.reps,
            role: role(fromRaw: exercise.roleRaw), fromCatalog: exercise.fromCatalog,
            block: SessionBlock(rawValue: exercise.block) ?? .lifting, holdSeconds: exercise.holdSeconds,
            side: exercise.sideRaw.flatMap(ExerciseSide.init(rawValue:)),
            segment: GuidedRunTimedLog.cardioSegment(of: exercise)
        )
    }

    /// The run's role token back as the domain role.
    static func role(fromRaw raw: String) -> SlotRole {
        switch raw {
        case "main": .main
        case "core": .core
        default: .accessory
        }
    }
}
