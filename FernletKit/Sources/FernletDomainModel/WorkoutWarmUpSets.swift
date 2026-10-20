// WorkoutWarmUpSets.swift
// FernletDomainModel
//
// Warm-up ramp sets before a heavy main lift (2026-10-20, idea 12 of the comparison report). Hevy
// sells a percentage warm-up calculator; Fernlet already had one in all but name — the monthly
// calibration's ramp (``WorkoutCalibration``) — and already kept ramp sets out of every estimate. So a
// barbell or other big compound main lift with a suggested working weight gets two or three lighter
// sets first (about 40 % × 8, 60 % × 5, 80 % × 3), each its own single-set step tagged as a calibration
// ramp: the runner walks them as "Warm-up set 1 of 3", the log writes them "(ramp-up)", and the load
// engine, the plateau check and the weekly hard-set count all skip that tag.
//
// Off for beginners unless they turn it on, off on a light day, off for a lift with no weight to build
// up to yet, and never on a lift the calibration already ramps into. A time budget can strip them
// (``removingWarmUpSets(from:)``). Pure and deterministic, like the rest of the load pass.

import Foundation

/// One warm-up set before a lift's working sets: its share of the working weight, its reps, and the
/// loadable weight that share rounds to.
public nonisolated struct WarmUpSet: Equatable, Sendable {
    /// The share of the working weight this set aims at (0.4 = 40 %).
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

    /// The ramp, as shares of the working weight and reps: about 40 % × 8, 60 % × 5, 80 % × 3.
    static let ramp: [(fraction: Double, reps: Int)] = [(0.4, 8), (0.6, 5), (0.8, 3)]
    /// A lift off the barbell needs at least this many distinct warm-up weights to get any — a 10 lb
    /// dumbbell press has nothing lighter worth ramping through. A barbell always has its empty bar.
    public static let minimumSetsOffBarbell = 2
    /// Movement patterns heavy enough to ramp into: the big compound lifts.
    static let compoundPatterns: Set<MovementPattern> = [.squat, .hinge, .lunge, .push, .pull]

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

    /// Whether a planned lift gets warm-up sets: a main lift, rep-counted, a compound `pattern`, loaded
    /// on gear that takes weight, with a suggested working weight — and not already a calibration step.
    public static func qualifies(_ exercise: PrescribedExercise, pattern: MovementPattern) -> Bool {
        guard exercise.role == .main, exercise.block == .lifting, exercise.holdSeconds == nil,
              compoundPatterns.contains(pattern), let guidance = exercise.guidance, guidance.calibration == nil,
              let equipment = guidance.equipment, let prescription = guidance.prescription,
              prescription.suggested > 0 else { return false }
        return WorkoutLoadEngine.step(for: equipment, unit: prescription.unit) != nil
    }

    // MARK: Which sets

    /// The warm-up sets before a `working` weight on `equipment`, lightest first.
    ///
    /// Each share of the ramp rounds to a weight the gear can make — the closest load the plates make
    /// on a barbell (`plates`, the standard set when nil), never under the bar; the equipment's step
    /// elsewhere, never under one step. A set that lands on the working weight or above is dropped, and
    /// so is one that lands on the set before it (the lighter set, with more reps, is kept). Off the
    /// barbell, fewer than ``minimumSetsOffBarbell`` sets means none.
    public static func sets(
        working: Double, equipment: Equipment, unit: LoadUnit, plates: BarbellPlateSet? = nil
    ) -> [WarmUpSet] {
        guard working.isFinite, working > 0, working <= ExerciseResult.maxWeight,
              let step = WorkoutLoadEngine.step(for: equipment, unit: unit) else { return [] }
        let barbell: BarbellPlateSet? = equipment == .barbell ? (plates ?? .standard(unit)) : nil
        var result: [WarmUpSet] = []
        for entry in ramp {
            let weight = loadable(working * entry.fraction, step: step, barbell: barbell)
            guard weight < working - WorkoutLoadEngine.weightTolerance else { continue }
            if let last = result.last, weight <= last.weight + WorkoutLoadEngine.weightTolerance { continue }
            result.append(WarmUpSet(fraction: entry.fraction, reps: entry.reps, weight: weight))
        }
        let minimum = barbell == nil ? minimumSetsOffBarbell : 1
        return result.count >= minimum ? result : []
    }

    /// `value` as a weight the gear can make: the closest barbell load (never under the bar), or the
    /// nearest step (never under one step).
    static func loadable(_ value: Double, step: Double, barbell: BarbellPlateSet?) -> Double {
        guard let barbell else { return max(step, WorkoutLoadEngine.rounded(value, toStep: step)) }
        return max(barbell.bar, PlateCalculator.closestLoadable(value, on: barbell))
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

    /// The warm-up sets for `exercise` as steps, or none when it does not qualify.
    public static func steps(for exercise: PrescribedExercise, pattern: MovementPattern) -> [PrescribedExercise] {
        guard qualifies(exercise, pattern: pattern), let prescription = exercise.guidance?.prescription,
              let equipment = exercise.guidance?.equipment else { return [] }
        let warmUps = sets(working: prescription.suggested, equipment: equipment, unit: prescription.unit)
        return steps(before: exercise, sets: warmUps)
    }

    // MARK: Seams

    /// A warm-up set this pass added — a `.ramp` step marked as a warm-up, never a calibration's ramp
    /// (which the test set after it needs).
    public static func isWarmUpSet(_ step: PrescribedExercise) -> Bool {
        step.guidance?.warmUp == true && step.guidance?.calibration == .ramp
    }

    /// `steps` without their warm-up sets — the time budget's trim (idea 5's `WorkoutSessionBudget`
    /// can call this as a stage of its own) and the plan editor's view of the lifting block.
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
