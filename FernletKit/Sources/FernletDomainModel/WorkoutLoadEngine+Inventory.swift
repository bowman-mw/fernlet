// WorkoutLoadEngine+Inventory.swift
// FernletDomainModel
//
// The load engine on real equipment (2026-10-20, idea 10 of the comparison report).
//
// - Snapping. When the location has weights set (``WorkoutWeightInventory``), the last weight is placed
//   on the nearest load the location has, every move lands on a load it has (the heavier or lighter
//   one closest to the usual step), and the prescribed range is drawn from those loads.
// - The light-load guard. The usual step is 5 lb (2 kg on dumbbells) with "always at least one step",
//   so a 15 lb dumbbell press went to 20 lb — 33 % in one session. Whenever the next load is more than
//   ``WorkoutLoadEngine/lightLoadGuardRatio`` heavier, or there is nothing heavier at all, the lift
//   takes the engine's existing Equipment path instead: one more rep at a time up to
//   ``WorkoutLoadEngine/equipmentExtraReps`` past the range, then one more set, and only then the jump
//   (never, when nothing heavier exists). The guard holds with or without weights set; without them
//   the next load is the usual step.

import Foundation

/// Why a lift adds reps — then a set — before it adds weight.
public nonisolated enum LoadCap: Equatable, Sendable {
    /// The next load up is more than ``WorkoutLoadEngine/lightLoadGuardRatio`` heavier than `from`.
    /// `owned` is true when `to` is the location's next weight, false when it is the usual step.
    case bigStep(from: Double, to: Double, owned: Bool)
    /// Nothing heavier exists at this location; `top` is the heaviest it has.
    case heaviest(top: Double)
}

extension WorkoutLoadEngine {

    /// The light-load guard: one step may raise a load by at most this fraction before reps come first.
    /// 15 → 20 lb is 33 % (reps first), 45 → 50 lb is 11 % (reps first), 50 → 55 lb is exactly 10 %
    /// and 100 → 105 lb is 5 % (both move). "About 10 %": a step a person can usually take for the
    /// same reps, where a bigger one usually costs several reps or a set.
    public static let lightLoadGuardRatio = 0.10

    /// `weight` placed on the location's loads — the nearest it has, a tie going lighter — or
    /// unchanged with no ladder.
    static func placed(_ weight: Double, on ladder: LoadLadder?) -> Double {
        ladder?.nearest(to: weight) ?? weight
    }

    /// `weight` moved one decision's worth. With a ladder the move lands on a load the location has:
    /// the heavier (or lighter) one nearest the usual step's result, a tie going lighter; with none
    /// that way, the nearest load. Without a ladder it is the usual step
    /// (``moved(_:by:step:lowerBody:)``).
    static func movedOnto(_ weight: Double, by move: WeightMove, step: Double, lowerBody: Bool, ladder: LoadLadder?) -> Double {
        let stepped = moved(weight, by: move, step: step, lowerBody: lowerBody)
        guard let ladder else { return stepped }
        switch move {
        case .hold:
            return ladder.nearest(to: weight)
        case .up:
            return ladder.closest(to: stepped, among: ladder.heavier(than: weight)) ?? ladder.nearest(to: weight)
        case .down:
            return ladder.closest(to: stepped, among: ladder.lighter(than: weight)) ?? ladder.nearest(to: weight)
        }
    }

    /// Why a lift at `weight` can't simply move up: nothing heavier exists, or the next load is more
    /// than ``lightLoadGuardRatio`` heavier. Nil when the next step is a normal one.
    public static func loadCap(from weight: Double, step: Double, lowerBody: Bool, ladder: LoadLadder?) -> LoadCap? {
        guard weight > 0, weight.isFinite, step > 0 else { return nil }
        let next = movedOnto(weight, by: .up, step: step, lowerBody: lowerBody, ladder: ladder)
        if let ladder, next <= weight + weightTolerance {
            return .heaviest(top: ladder.heaviest)
        }
        guard (next - weight) / weight > lightLoadGuardRatio + 1e-9 else { return nil }
        return .bigStep(from: weight, to: next, owned: ladder != nil)
    }

    /// The range on the location's loads: the suggestion placed on the nearest load, then — like the
    /// usual range — at least one load either side, widened to the loads at ±10 % (low confidence) or
    /// ±5 % (medium); at high confidence the suggestion and the next load up. The runner's step is
    /// the loads' common step where they have a useful one (``LoadLadder/runnerStep(default:)``).
    static func rangeOnLoads(
        _ ladder: LoadLadder, suggested: Double, confidence: EstimateConfidence, step: Double, unit: LoadUnit
    ) -> WeightPrescription {
        let center = ladder.nearest(to: suggested)
        let below = ladder.lighter(than: center).last
        let above = ladder.heavier(than: center).first
        let runnerStep = ladder.runnerStep(default: step)
        guard confidence != .high else {
            return WeightPrescription(low: center, high: above ?? center, suggested: center,
                                      step: runnerStep, unit: unit, confidence: confidence)
        }
        let half = confidence == .medium ? mediumConfidenceHalfWidth : lowConfidenceHalfWidth
        let floorLoad = ladder.loads.last { $0 <= center * (1 - half) + weightTolerance }
        let ceilingLoad = ladder.loads.first { $0 >= center * (1 + half) - weightTolerance }
        let low = [below, floorLoad].compactMap { $0 }.min() ?? center
        let high = [above, ceilingLoad].compactMap { $0 }.max() ?? center
        return WeightPrescription(low: low, high: high, suggested: center, step: runnerStep,
                                  unit: unit, confidence: confidence)
    }

    /// A completed session at or past the top of the range while the next load waits: one more rep
    /// up to ``equipmentExtraReps`` past the range, then one more set; after a second session at
    /// that ceiling the lift takes the jump — unless nothing heavier exists, when it stays there.
    static func cappedOutcome(
        target: Int, scheme: RepScheme, cap: LoadCap, anchor: LiftExposure, history: [LiftExposure]
    ) -> Outcome {
        let ceiling = scheme.high + equipmentExtraReps
        if target < ceiling {
            return Outcome(reps: target + 1, setsDelta: 0, change: .repsFirst, move: .hold, cap: cap)
        }
        if case .bigStep = cap, previousSessionReached(ceiling, before: anchor, in: history) {
            return Outcome(reps: scheme.low, setsDelta: 0, change: scheme.isRange ? .backToBottom : .addWeight, move: .up)
        }
        return Outcome(reps: ceiling, setsDelta: 1, change: .setFirst, move: .hold, cap: cap)
    }

    /// Whether the regular session before `anchor` was also completed at `ceiling` reps at the same
    /// weight — the extra set has been done, so the jump comes next. Counted by sessions rather than
    /// sets, so a time budget trimming the extra set can't hold the lift there forever.
    static func previousSessionReached(_ ceiling: Int, before anchor: LiftExposure, in history: [LiftExposure]) -> Bool {
        let regular = history.filter { !$0.easierSession && $0.calibration == nil }
        guard regular.count >= 2, let previous = regular.dropLast().last else { return false }
        guard let weight = previous.weight, let anchorWeight = anchor.weight else { return false }
        let unit = anchor.unit ?? previous.unit ?? .lb
        let same = abs(unit.converted(weight, from: previous.unit ?? unit) - anchorWeight) <= weightTolerance
        return same && previous.completed && previous.targetReps >= ceiling
    }
}
