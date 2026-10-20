import Foundation
import FernletDomainModel
import FernletFoundation

/// Gathers what the 48-hour same-muscle guard reads (``WorkoutRecoveryGuard/RecentTraining``) from
/// the day history: the primary muscles that got hard working sets on the past days inside the
/// window, and the workout names of the most recent of those days.
///
/// Two sources, like ``WorkoutLoadContextBuilder``:
/// - a guided row's structured ``ExerciseResult``s — the lifts the runner tracked, never the warm-up,
///   activation or cool-down; a calibration's light ramp sets don't count;
/// - every other row's lines, read by ``ExerciseLineParser`` ("Squat 5x5 @225lb"): a line with sets
///   and reps of a strength lift the catalog knows. A guided row without results (an older log, "Mark
///   done") is read this way too — it records a session that was done, and for fatigue that is
///   enough; the light activation lines it carries only reach the core, which today's lifting never
///   trains.
///
/// Holds, stretches, jumps and unknown names never count (``WorkoutRecoveryGuard/hardMuscles(ofLift:)``).
/// Today's own rows are left out, so logging today's session never moves today's plan. Pure over its
/// inputs.
enum WorkoutRecentTrainingBuilder {
    static func build(days: [String: FernletDay], todayKey: String) -> WorkoutRecoveryGuard.RecentTraining {
        guard let today = FernletDate.date(fromDayKey: todayKey) else { return .empty }
        var hard: Set<MuscleGroup> = []
        var latestNames: [String] = []
        for daysAgo in 1...WorkoutRecoveryGuard.lookbackDays where WorkoutRecoveryGuard.countsTowardWindow(daysAgo: daysAgo) {
            guard let date = Calendar.current.date(byAdding: .day, value: -daysAgo, to: today),
                  let record = days[FernletDate.dayKey(for: date)], !record.workouts.isEmpty else { continue }
            if latestNames.isEmpty { latestNames = record.workouts.map(\.name) }
            for workout in record.workouts { hard.formUnion(hardMuscles(in: workout)) }
        }
        return WorkoutRecoveryGuard.RecentTraining(hardMuscles: hard, latestSessionNames: latestNames)
    }

    /// The primary muscles one logged workout worked hard.
    static func hardMuscles(in workout: Workout) -> Set<MuscleGroup> {
        if let results = workout.exerciseResults {
            return results.reduce(into: Set<MuscleGroup>()) { muscles, result in
                guard result.calibration != .ramp, result.repsPerSet.contains(where: { $0 > 0 }) else { return }
                muscles.formUnion(WorkoutRecoveryGuard.hardMuscles(ofLift: result.name))
            }
        }
        return workout.exerciseLines.reduce(into: Set<MuscleGroup>()) { muscles, line in
            guard let parsed = ExerciseLineParser.parse(line), (parsed.sets ?? 0) > 0,
                  parsed.reps?.hasSuffix(" s") != true else { return }
            muscles.formUnion(WorkoutRecoveryGuard.hardMuscles(ofLift: parsed.name))
        }
    }
}
