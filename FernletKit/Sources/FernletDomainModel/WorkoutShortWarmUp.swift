// WorkoutShortWarmUp.swift
// FernletDomainModel
//
// The short warm-up (2026-10-20, idea 5): about four minutes of the owner's stretch flow, for a
// "Short" warm-up setting or a session that has to fit a time budget. The owner's 23-step flow stays
// exactly as written for "Full"; this only ever selects a subset of it, in its own order — the
// opening forward fold, then the stretches for the areas the day's lifting works (the lower-body steps
// on a leg day, the shoulder and arm stretches on an upper day), then the flow's own order to fill
// the time.

import Foundation

extension WorkoutSessionBlocks {

    /// The short warm-up's hold time, at most: about four minutes, half the owner's flow.
    public static let shortWarmUpSeconds = 240

    /// The short warm-up for a session whose lifting works `worked`.
    ///
    /// A subset of the injury-filtered flow (``warmUp(feasible:)``), never a rearrangement:
    /// 1. each stretch once per side — the flow's returns to the forward fold and the second lunge of
    ///    each round are what make it long;
    /// 2. whole stretches (both sides together) are chosen until ``shortWarmUpSeconds`` of holds: the
    ///    flow's opening stretch always, then a stretch that reaches a worked area nothing chosen
    ///    reaches yet, then the best fit for the worked areas, then the flow's own order;
    /// 3. the chosen steps come back in the flow's order, left side before right as the owner walks it.
    static func shortWarmUp(feasible: [ExerciseTarget], worked: Set<MuscleGroup>) -> [PrescribedExercise] {
        var seen: Set<String> = []
        let once = warmUp(feasible: feasible).filter { seen.insert("\($0.name)|\($0.side?.rawValue ?? "")").inserted }
        guard !once.isEmpty else { return [] }
        let kept = chooseShortWarmUp(warmUpMoves(once, feasible: feasible), worked: StretchArea.areas(of: worked))
        return once.filter { kept.contains($0.name) }
    }

    /// One stretch of the flow with both its sides: its hold time, the areas it reaches, and where
    /// the flow first walks it.
    struct WarmUpMove {
        let name: String
        var seconds: Int
        let primary: Set<StretchArea>
        let secondary: Set<StretchArea>
        let position: Int
    }

    /// The flow's stretches in first-appearance order, each side's hold added to its stretch.
    static func warmUpMoves(_ steps: [PrescribedExercise], feasible: [ExerciseTarget]) -> [WarmUpMove] {
        let byName = Dictionary(feasible.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var moves: [WarmUpMove] = []
        for step in steps {
            let hold = step.holdSeconds ?? 0
            if let index = moves.firstIndex(where: { $0.name == step.name }) {
                moves[index].seconds += hold
                continue
            }
            let target = byName[step.name]
            moves.append(WarmUpMove(
                name: step.name, seconds: hold,
                primary: StretchArea.areas(of: target?.primaryMuscles ?? []),
                secondary: StretchArea.areas(of: target?.secondaryMuscles ?? []),
                position: moves.count
            ))
        }
        return moves
    }

    /// The names of the stretches the short warm-up keeps (see ``shortWarmUp(feasible:worked:)``).
    static func chooseShortWarmUp(_ moves: [WarmUpMove], worked: Set<StretchArea>) -> Set<String> {
        guard let opening = moves.first else { return [] }
        var kept: Set<String> = [opening.name]
        var total = opening.seconds
        var covered = opening.primary.intersection(worked)
        var remaining = Array(moves.dropFirst())
        for _ in 0..<moves.count {
            let fitting = remaining.filter { total + $0.seconds <= shortWarmUpSeconds }
            guard let best = fitting.max(by: {
                warmUpRank($0, worked: worked, covered: covered) < warmUpRank($1, worked: worked, covered: covered)
            }) else { break }
            kept.insert(best.name)
            total += best.seconds
            covered.formUnion(best.primary.intersection(worked))
            remaining.removeAll { $0.name == best.name }
        }
        return kept
    }

    /// How much a stretch is wanted next: worked areas it reaches that nothing chosen reaches yet,
    /// then its fit to the worked areas (a main area counts three, a secondary one), then the earlier
    /// stretch in the flow.
    static func warmUpRank(_ move: WarmUpMove, worked: Set<StretchArea>, covered: Set<StretchArea>) -> (Int, Int, Int) {
        let reached = move.primary.intersection(worked)
        let fit = reached.count * 3 + move.secondary.intersection(worked).count
        return (reached.subtracting(covered).count, fit, -move.position)
    }
}

/// The coarse body areas the short warm-up matches a day's muscles by: a push day's front and side
/// delts and a cross-body stretch's rear delts are all "shoulders", so the shoulder stretch counts on
/// a push day though no muscle tag is shared.
nonisolated enum StretchArea: CaseIterable, Sendable {
    case lowerBody
    case back
    case shoulders
    case arms
    case core

    /// The areas one muscle belongs to (every area for a full-body tag).
    static func areas(ofMuscle muscle: MuscleGroup) -> Set<StretchArea> {
        switch muscle {
        case .quads, .hamstrings, .glutes, .calves, .adductors, .abductors: [.lowerBody]
        case .upperBack, .lats, .lowerBack: [.back]
        case .chest, .frontDelts, .sideDelts, .rearDelts, .traps: [.shoulders]
        case .biceps, .triceps, .forearms: [.arms]
        case .abs, .obliques: [.core]
        case .fullBody: Set(StretchArea.allCases)
        }
    }

    /// The areas a set of muscles reaches.
    static func areas(of muscles: Set<MuscleGroup>) -> Set<StretchArea> {
        muscles.reduce(into: Set<StretchArea>()) { $0.formUnion(areas(ofMuscle: $1)) }
    }
}
