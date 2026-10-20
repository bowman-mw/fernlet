// WorkoutWarmUpSets.swift
// FernletDomainModel
//
// Warm-up ramp sets before a heavy main lift (2026-10-20, idea 12 of the comparison report). Hevy
// sells a percentage warm-up calculator; Fernlet already had one in all but name — the monthly
// calibration's ramp (``WorkoutCalibration``) — and already kept ramp sets out of every estimate. So the
// session's first heavy main lift — a compound main lift on a barbell or dumbbells — with a suggested
// working weight gets two or three lighter sets first, each its own single-set step tagged as a
// calibration ramp: the runner walks them as "Warm-up set 1 of 3", the log writes them "(ramp-up)", and
// the load engine, the plateau check and the weekly hard-set count all skip that tag.
//
// The owner's picks (round 2, R1): only the FIRST heavy main lift ramps — when it can't (no weight yet,
// or the calibration already ramps into it) no later lift takes its place; a barbell ramp starts on the
// empty bar × 8, then about 60 % × 5 and 80 % × 3 on loadable plates; a dumbbell ramp is about 40 % × 8,
// 60 % × 5 and 80 % × 3 on the dumbbells the location owns (else 5 lb or 2 kg steps). Off for beginners
// unless they turn it on, and off on a light day. A tight time budget cuts the ramp to its one set
// nearest 60 % (``WorkoutSessionBudget``), never to zero. Pure and deterministic, like the rest of the
// load pass.

import Foundation

/// One warm-up set before a lift's working sets: its share of the working weight, its reps, and the
/// loadable weight that share rounds to.
public nonisolated struct WarmUpSet: Equatable, Sendable {
    /// The share of the working weight this set aims at (0.4 = 40 %; the empty bar's own share).
    public var fraction: Double
    public var reps: Int
    /// The weight, on the equipment's loadable steps (plates for a barbell).
    public var weight: Double

    public init(fraction: Double, reps: Int, weight: Double) {
        self.fraction = fraction
        self.reps = reps
        self.weight = weight
    }
}

/// The rules for warm-up ramp sets: whether a lift gets them, which sets, and the steps they become.
public nonisolated enum WorkoutWarmUpSets {

    // MARK: Numbers

    /// The dumbbell ramp, as shares of the working weight and reps: about 40 % × 8, 60 % × 5, 80 % × 3.
    static let dumbbellRamp: [(fraction: Double, reps: Int)] = [(0.4, 8), (0.6, 5), (0.8, 3)]
    /// The barbell ramp after the empty bar: about 60 % × 5, then 80 % × 3.
    static let barbellRamp: [(fraction: Double, reps: Int)] = [(0.6, 5), (0.8, 3)]
    /// Reps on the empty bar, the barbell ramp's first set.
    public static let emptyBarReps = 8
    /// The share of the working weight a budget-trimmed ramp keeps its one set nearest to.
    public static let keptShare = 0.6
    /// A lift off the barbell needs at least this many distinct warm-up weights to get any — a 10 lb
    /// dumbbell press has nothing lighter worth ramping through. A barbell always has its empty bar.
    public static let minimumSetsOffBarbell = 2
    /// Movement patterns heavy enough to ramp into: the big compound lifts.
    static let compoundPatterns: Set<MovementPattern> = [.squat, .hinge, .lunge, .push, .pull]
    /// The gear a ramp is worth building on (owner's pick R1, 2026-10-20): the barbell and dumbbells.
    /// A machine, cable or kettlebell lift starts at its working weight.
    public static let rampEquipment: Set<Equipment> = [.barbell, .dumbbell]

    // MARK: The setting

    /// The default for "Warm-up sets before heavy lifts": on for intermediate and advanced lifters, off
    /// for beginners, whose working weights are still light and whose sessions stay short.
    public static func isOnByDefault(for experience: ExperienceLevel) -> Bool {
        experience != .beginner
    }

    /// Whether warm-up sets are on: the lifter's own choice when they made one
    /// (`FernletSettings.workoutWarmUpSets`), else the default for their level.
    public static func isEnabled(preference: Bool?, experience: ExperienceLevel) -> Bool {
        preference ?? isOnByDefault(for: experience)
    }

    // MARK: Which lifts

    /// Whether a planned lift is a heavy main lift — the kind a ramp is for: a main lift in the lifting
    /// block, rep-counted, a compound `pattern`, on a barbell or dumbbells (``rampEquipment``). Only the
    /// session's first one is considered (``firstHeavyMainLift(in:patterns:)``).
    public static func isHeavyMainLift(_ exercise: PrescribedExercise, pattern: MovementPattern) -> Bool {
        guard exercise.role == .main, exercise.block == .lifting, exercise.holdSeconds == nil,
              compoundPatterns.contains(pattern), let equipment = exercise.guidance?.equipment else { return false }
        return rampEquipment.contains(equipment)
    }

    /// Whether a planned lift gets warm-up sets: a heavy main lift (``isHeavyMainLift(_:pattern:)``)
    /// with a suggested working weight — and not already a calibration step.
    public static func qualifies(_ exercise: PrescribedExercise, pattern: MovementPattern) -> Bool {
        guard isHeavyMainLift(exercise, pattern: pattern), let guidance = exercise.guidance,
              guidance.calibration == nil, let equipment = guidance.equipment,
              let prescription = guidance.prescription, prescription.suggested > 0 else { return false }
        return WorkoutLoadEngine.step(for: equipment, unit: prescription.unit) != nil
    }

    /// The index of the session's first heavy main lift in `steps`, or nil when it has none. `patterns`
    /// runs parallel to `steps`: each step's movement pattern, nil for one it cannot tell. The ramp goes
    /// to this lift or to none — a first heavy lift that does not qualify hands its ramp to no later lift.
    public static func firstHeavyMainLift(in steps: [PrescribedExercise], patterns: [MovementPattern?]) -> Int? {
        for index in steps.indices where index < patterns.count {
            guard let pattern = patterns[index], isHeavyMainLift(steps[index], pattern: pattern) else { continue }
            return index
        }
        return nil
    }

    // MARK: Which sets

    /// The warm-up sets before a `working` weight on `equipment`, lightest first; none off a barbell or
    /// dumbbells (``rampEquipment``).
    ///
    /// A barbell ramp is the empty bar × ``emptyBarReps``, then about 60 % × 5 and 80 % × 3 on loads the
    /// plates make (`plates`, the standard set when nil). A dumbbell ramp is about 40 % × 8, 60 % × 5
    /// and 80 % × 3, each snapped to the nearest dumbbell owned, else to the equipment's step (never
    /// under one step). `ladder` is the location's own loads for the gear when it has them set — on a
    /// barbell its bar and plate totals stand in for `plates`. A set at or over the working weight is
    /// dropped, and so is one that lands on the set before it (the lighter set, with more reps, is
    /// kept). A dumbbell ramp of fewer than ``minimumSetsOffBarbell`` sets means none.
    public static func sets(
        working: Double, equipment: Equipment, unit: LoadUnit, plates: BarbellPlateSet? = nil,
        ladder: LoadLadder? = nil
    ) -> [WarmUpSet] {
        guard working.isFinite, working > 0, working <= ExerciseResult.maxWeight, rampEquipment.contains(equipment),
              let step = WorkoutLoadEngine.step(for: equipment, unit: unit) else { return [] }
        guard equipment == .barbell else { return dumbbellSets(working: working, step: step, ladder: ladder) }
        return barbellSets(working: working, plates: plates ?? .standard(unit), ladder: ladder)
    }

    /// The barbell ramp: the empty bar, then the 60 % and 80 % sets on loadable weights, each strictly
    /// over the set before it (so over the bar) and under the working weight.
    static func barbellSets(working: Double, plates: BarbellPlateSet, ladder: LoadLadder?) -> [WarmUpSet] {
        let tolerance = WorkoutLoadEngine.weightTolerance
        let bar = ladder?.lightest ?? plates.bar
        guard bar > 0, bar < working - tolerance else { return [] }
        var result = [WarmUpSet(fraction: bar / working, reps: emptyBarReps, weight: bar)]
        for entry in barbellRamp {
            let target = working * entry.fraction
            let weight = ladder?.nearest(to: target) ?? PlateCalculator.closestLoadable(target, on: plates)
            guard weight < working - tolerance, let last = result.last,
                  weight > last.weight + tolerance else { continue }
            result.append(WarmUpSet(fraction: entry.fraction, reps: entry.reps, weight: weight))
        }
        return result
    }

    /// The dumbbell ramp: about 40, 60 and 80 % on the dumbbells owned (`ladder`), else on `step`;
    /// none when fewer than ``minimumSetsOffBarbell`` distinct weights under the working one are left.
    static func dumbbellSets(working: Double, step: Double, ladder: LoadLadder?) -> [WarmUpSet] {
        let tolerance = WorkoutLoadEngine.weightTolerance
        var result: [WarmUpSet] = []
        for entry in dumbbellRamp {
            let target = working * entry.fraction
            let weight = ladder?.nearest(to: target) ?? max(step, WorkoutLoadEngine.rounded(target, toStep: step))
            guard weight < working - tolerance else { continue }
            if let last = result.last, weight <= last.weight + tolerance { continue }
            result.append(WarmUpSet(fraction: entry.fraction, reps: entry.reps, weight: weight))
        }
        return result.count >= minimumSetsOffBarbell ? result : []
    }

    // MARK: The steps

    /// The single-set steps that run before `exercise`, one per warm-up set: the lift's own name, role
    /// and gear, a fixed weight, and the calibration's `.ramp` tag (so the log, the estimate and the
    /// plateau check treat them as the ramp they are), marked as warm-up sets for the time budget.
    public static func steps(before exercise: PrescribedExercise, sets: [WarmUpSet]) -> [PrescribedExercise] {
        guard let guidance = exercise.guidance, let prescription = guidance.prescription else { return [] }
        return sets.map { set in
            let weight = WeightPrescription(
                low: set.weight, high: set.weight, suggested: set.weight, step: prescription.step,
                unit: prescription.unit, confidence: prescription.confidence
            )
            return PrescribedExercise(
                name: exercise.name, sets: 1, reps: "\(set.reps)", role: exercise.role,
                fromCatalog: exercise.fromCatalog, block: exercise.block,
                guidance: LoadGuidance(
                    targetReps: set.reps, prescription: weight, equipment: guidance.equipment,
                    unit: prescription.unit, calibration: .ramp, compoundsBefore: guidance.compoundsBefore,
                    warmUp: true, loads: guidance.loads
                )
            )
        }
    }

    /// The warm-up sets for `exercise` as steps, or none when it does not qualify. `ladder` is the
    /// location's loads for the lift's gear, when it has them set.
    public static func steps(
        for exercise: PrescribedExercise, pattern: MovementPattern, ladder: LoadLadder? = nil
    ) -> [PrescribedExercise] {
        guard qualifies(exercise, pattern: pattern), let prescription = exercise.guidance?.prescription,
              let equipment = exercise.guidance?.equipment else { return [] }
        let warmUps = sets(working: prescription.suggested, equipment: equipment, unit: prescription.unit,
                           ladder: ladder)
        return steps(before: exercise, sets: warmUps)
    }

    /// The warm-up set a tight time budget keeps of a ramp (``WorkoutSessionBudget``): the one whose
    /// weight is nearest ``keptShare`` of `working` (a tie goes to the earlier, lighter set). Nil only
    /// for no sets.
    public static func keptOnTrim(_ warmUps: [PrescribedExercise], working: Double) -> PrescribedExercise? {
        var best: PrescribedExercise?
        var bestGap = Double.infinity
        for step in warmUps {
            let gap = abs((step.guidance?.prescription?.suggested ?? 0) - working * keptShare)
            guard gap < bestGap - 1e-9 else { continue }
            best = step
            bestGap = gap
        }
        return best
    }

    // MARK: Seams

    /// A warm-up set this pass added — a `.ramp` step marked as a warm-up, never a calibration's ramp
    /// (which the test set after it needs).
    public static func isWarmUpSet(_ step: PrescribedExercise) -> Bool {
        step.guidance?.warmUp == true && step.guidance?.calibration == .ramp
    }

    /// `steps` without their warm-up sets — the plan editor's view of the lifting block, and where a
    /// re-plan (``WorkoutAdjustedLoad``) starts before it ramps again.
    public static func removingWarmUpSets(from steps: [PrescribedExercise]) -> [PrescribedExercise] {
        steps.filter { !isWarmUpSet($0) }
    }

    /// The warm-up sets of `original` put back in front of their lifts in `rows` — what the plan
    /// editor saves after editing the lifting block without them. A lift moved keeps its warm-ups in
    /// front of it; a lift removed takes its warm-ups with it; a lift added gets none.
    public static func reattach(_ rows: [PrescribedExercise], from original: [PrescribedExercise]) -> [PrescribedExercise] {
        var byLift: [String: [PrescribedExercise]] = [:]
        for step in original where isWarmUpSet(step) {
            byLift[WorkoutExerciseCatalog.normalizedName(step.name), default: []].append(step)
        }
        var result: [PrescribedExercise] = []
        for row in rows where !isWarmUpSet(row) {
            let key = WorkoutExerciseCatalog.normalizedName(row.name)
            result += byLift[key] ?? []
            byLift[key] = nil
            result.append(row)
        }
        return result
    }

    /// The tag a ramp-up line carries in the logged text — "Back squat - 1 x 8 @ 95 lb (ramp-up)" —
    /// spelled once, where `ExerciseResult.loggedLine` writes it. A FROZEN log token, never localized.
    public static var rampLineTag: String { "(\(ExerciseResult.calibrationTag(.ramp)))" }

    /// Whether a logged line is a ramp-up set (a warm-up set or a calibration's ramp), which no rollup
    /// of working sets reads.
    public static func isRampLine(_ line: String) -> Bool {
        line.contains(rampLineTag)
    }
}
