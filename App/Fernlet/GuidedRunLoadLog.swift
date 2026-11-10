import Foundation
import FernletDomainModel

/// The two crossings between the domain's load plan and the guided run's app-group state.
///
/// At start, a lift's ``LoadGuidance`` becomes the run's ``GuidedWorkoutRunState/Tracking`` (the
/// suggestion preselected, so finishing untouched needs no extra tap). At finish, each tracked lift
/// becomes an ``ExerciseResult`` and its logged line ("Bench press - 3 x 8 @ 105 lb", with
/// "(did 8, 8, 6)" when edited), and the session's text is rebuilt around those lines. Each set is
/// logged at the weight it was done at (s4): a weight changed mid-lift reads "(did 8 @ 100, 8 @ 100,
/// 8 @ 110)", and the reps editor's own per-set weights win over the taps' record. A lift the
/// runner skipped past is logged as skipped and never becomes a result, so a short-on-time skip is not
/// read as a miss; a warm-up set it skipped leaves no trace. A warm-up set crosses as a calibration
/// ramp, so it logs "(ramp-up)" and no estimate reads it. The run state cannot import the domain, so
/// tokens cross as raw strings here.
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
        var tracking = GuidedWorkoutRunState.Tracking(
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
            selected: guidance.prescription?.suggested,
            loads: step == nil ? nil : guidance.loads.map { Array($0.prefix(GuidedWorkoutRunState.Tracking.maxLoads)) }
        )
        tracking.usual = guidance.usual.map { usualSets($0) }
        return tracking
    }

    /// A strength check's fallback — the lift's usual working sets (w4) — as the run carries it.
    static func usualSets(_ usual: LoadGuidance.UsualSets) -> GuidedWorkoutRunState.Tracking.UsualSets {
        GuidedWorkoutRunState.Tracking.UsualSets(
            sets: usual.sets, reps: usual.reps, rangeLow: usual.prescription?.low, rangeHigh: usual.prescription?.high,
            suggested: usual.prescription?.suggested, confidenceRaw: usual.prescription?.confidence.rawValue,
            restSeconds: usual.restSeconds
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

    /// One tracked lift's result, or nil for an untracked step or one the runner skipped. `unfueled`
    /// is the run's answer to the Ready screen's food question (G12).
    static func result(for exercise: GuidedWorkoutRunState.Exercise, unfueled: Bool = false) -> ExerciseResult? {
        guard let tracking = exercise.tracking, tracking.skipped != true, exercise.fromCatalog else { return nil }
        let result = ExerciseResult(
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
            compoundsBefore: tracking.compoundsBefore,
            unfueled: unfueled
        )
        return withDoneWeights(withEditedWeights(result, tracking: tracking), tracking: tracking)
    }

    /// `result` with each set at the weight it was done at (s4): the weight on the bar when its Done
    /// was tapped (``GuidedWorkoutRunState/Tracking/doneWeights``), so a weight changed mid-lift is
    /// logged set by set ("(did 8 @ 100, 8 @ 100, 8 @ 110)") and never rewrites the finished sets. As
    /// after an edit, the working weight is the one most sets were done at (w2) and a lighter set keeps the session from
    /// counting as completed, so a dropped set repeats the load. Unchanged when the reps editor listed
    /// the weights itself (the edit wins), when no set recorded one (an older run), and when every set
    /// was done at the selected weight — which stays byte-identical to the log before.
    static func withDoneWeights(_ result: ExerciseResult, tracking: GuidedWorkoutRunState.Tracking) -> ExerciseResult {
        guard tracking.actualWeights == nil, tracking.doneWeights?.isEmpty == false else { return result }
        let reps = result.repsPerSet
        guard let weights = tracking.setWeights(count: reps.count), weights.count == reps.count else { return result }
        let allAtSelected = tracking.selected.map { selected in
            weights.allSatisfy { abs($0 - selected) <= WorkoutLoadEngine.weightTolerance }
        } ?? false
        guard !allAtSelected else { return result }
        var recorded = result
        recorded.record(zip(reps, weights).map { LoggedSet(reps: $0.0, weight: $0.1) },
                        unit: tracking.unitRaw.flatMap(LoadUnit.init(rawValue:)))
        return recorded
    }

    /// `result` with the reps editor's per-set weights recorded (`b3-edit-reps` draft 2): a set at
    /// another weight, or a drop set, logs set by set ("(did 8 @ 35, 8 @ 25)"), and the working weight
    /// is the one most sets were done at (w2). Unchanged when the editor kept every set at the selected weight.
    static func withEditedWeights(_ result: ExerciseResult, tracking: GuidedWorkoutRunState.Tracking) -> ExerciseResult {
        guard let weights = tracking.actualWeights, !weights.isEmpty else { return result }
        let reps = tracking.actualReps ?? Array(repeating: tracking.targetReps, count: weights.count)
        guard reps.count == weights.count else { return result }
        var recorded = result
        recorded.record(zip(reps, weights).map { LoggedSet(reps: $0.0, weight: $0.1) },
                        unit: tracking.unitRaw.flatMap(LoadUnit.init(rawValue:)))
        return recorded
    }

    /// The finished run's log: its text with each tracked lift's own line, and the results — or
    /// nil when no step was tracked (a run from before load tracking keeps its plan text). A ramp-up
    /// set that was skipped ("Skip warm-up sets") leaves no line at all: the lift was not skipped,
    /// only its warm-up. A strength check put off with "Not now" (w4) leaves one "skipped" line, however
    /// many max attempts it held — and none at all when the lift's usual working sets took its place
    /// (``replacedByUsualSets(at:in:)``): the lift was trained, and its own line says so.
    static func log(for state: GuidedWorkoutRunState) -> (text: String, results: [ExerciseResult])? {
        guard state.exercises.contains(where: { $0.tracking != nil }) else { return nil }
        let kept = state.exercises.enumerated().filter { index, exercise in
            !(exercise.isRampSet && exercise.tracking?.skipped == true)
                && !repeatsSkippedAttempt(at: index, in: state.exercises)
                && !replacedByUsualSets(at: index, in: state.exercises)
        }.map(\.element)
        var lines: [UUID: String] = [:]
        var results: [ExerciseResult] = []
        for exercise in kept {
            if let result = result(for: exercise, unfueled: state.unfueled == true) {
                results.append(result)
                lines[exercise.id] = result.loggedLine
            } else if exercise.tracking?.skipped == true {
                lines[exercise.id] = "\(exercise.name) - skipped"
            } else if let written = exercise.writtenLine {
                // A planned workout's untracked line logs as its plan wrote it, cue and all.
                lines[exercise.id] = written
            }
        }
        let steps = kept.map { prescribed($0) }
        return (WorkoutSessionBlocks.planText(for: steps, loggedLines: lines), results)
    }

    /// Whether the step at `index` is a skipped max attempt straight after another skipped attempt of
    /// the same lift — which the log folds into the one "skipped" line before it.
    static func repeatsSkippedAttempt(at index: Int, in exercises: [GuidedWorkoutRunState.Exercise]) -> Bool {
        guard index > 0, exercises.indices.contains(index) else { return false }
        let attempt = GuidedWorkoutRunState.CalibrationToken.attempt
        let step = exercises[index]
        let before = exercises[index - 1]
        return step.tracking?.skipped == true && step.tracking?.calibrationRaw == attempt
            && before.tracking?.skipped == true && before.tracking?.calibrationRaw == attempt
            && before.name == step.name
    }

    /// Whether the step at `index` is a skipped test set or max attempt whose lift fell back to its
    /// usual working sets ("Not now", w4): a later step of the same lift that is no part of a check.
    /// Bounded by the run's steps.
    static func replacedByUsualSets(at index: Int, in exercises: [GuidedWorkoutRunState.Exercise]) -> Bool {
        guard exercises.indices.contains(index) else { return false }
        let step = exercises[index]
        guard step.tracking?.skipped == true, step.tracking?.calibrationRaw != nil else { return false }
        return exercises.suffix(from: index + 1).contains {
            $0.name == step.name && $0.tracking != nil && $0.tracking?.calibrationRaw == nil
        }
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
