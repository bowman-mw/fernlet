import Foundation
import FernletDomainModel
import FernletFoundation

/// One week of training as plain totals: working sets per muscle group, and aerobic minutes.
///
/// "Information, not a streak" (comparison report idea 18): each figure is what the log says for
/// the seven days, with no grade, score, trend, streak or "target met" state anywhere in the type.
/// Built by ``WeeklyTrainingSummaryBuilder``; drawn by ``WeeklyTotalsView``.
struct WeeklyTrainingSummary: Equatable {
    /// One muscle group's working sets for the week.
    struct MuscleSets: Equatable, Identifiable {
        /// The muscle group. Its `displayName` is what screens draw; the raw value is only the id.
        let muscle: MuscleGroup
        /// Whole sets where the muscle is a main mover plus half sets where it assists, so the
        /// value moves in halves (see ``WeeklyTrainingSummaryBuilder/secondaryCredit``).
        let sets: Double

        /// The muscle's frozen token: one row per muscle, so it identifies the row.
        var id: String { muscle.rawValue }
    }

    /// Midnight of the week's first day, which follows the calendar's `firstWeekday`.
    let weekStart: Date
    /// Midnight of the week's last day.
    let weekEnd: Date
    /// The muscles with any credit this week, in ``MuscleGroup``'s declaration order (head to toe).
    /// Never ranked by count: a ranking reads as a leaderboard.
    let muscleSets: [MuscleSets]
    /// Minutes of aerobic workouts in the week (``WeeklyTrainingSummaryBuilder/countsAsAerobic(_:)``).
    let aerobicMinutes: Int
}

/// Builds a ``WeeklyTrainingSummary`` from the day history. Pure over its inputs.
///
/// **Sets** come from the same two sources the load engine reads (``WorkoutLoadContextBuilder``):
/// - a row's structured ``ExerciseResult``s (the guided runner's record, and any other row that
///   carries results), counting each set done with at least one rep;
/// - a hand-logged row's lines, read by ``ExerciseLineParser`` ("Squat 5x5 @225lb"), counting the
///   sets written, rep ranges included.
///
/// A row with results is read from its results only, and a guided row WITHOUT results is skipped,
/// exactly as the load engine does: its text is the plan that was suggested ("Mark done", and every
/// guided log before load tracking), not a record of what was lifted.
///
/// A set counts only for a catalog exercise (bundled or the user's own) that is strength work
/// counted in reps. Warm-up stretches (`.mobility`), balance drills, jumps and throws (`.power`),
/// conditioning moves (`.cardio`), holds (`.seconds`, or a "2 x 30 s" line) and calibration ramp-up
/// sets are left out: none of them is the near-failure work the reference range below describes.
/// A line naming no catalog exercise is skipped, since its muscles are unknown.
///
/// **Credit:** a set counts in full for each primary muscle and as half a set for each secondary
/// one. Counting a muscle's indirect work as half a set is the "fractional" method that Pelland et
/// al. (2024, a meta-regression of weekly volume and hypertrophy, SportRxiv preprint) found fit the
/// growth data better than counting direct sets alone; counting it as a full set would credit a bench
/// press's triceps as much as its chest.
///
/// **The reference range** shown beside the counts, 10 to 20 hard sets per muscle per week, is a
/// commonly cited range for hypertrophy: Schoenfeld, Ogborn & Krieger (2017, J Sports Sci
/// 35(11):1073–1082) found a graded dose-response with 10 or more weekly sets per muscle producing
/// the most growth, and Baz-Valle et al. (2022, J Hum Kinet 81:199–210) concluded 12 to 20 weekly
/// sets per muscle group. It is shown as neutral context, never as a grade or a target.
///
/// **Aerobic minutes** sum `Workout.duration` over the week's aerobic rows, against the WHO 2020
/// guideline (Bull et al., Br J Sports Med 54:1451–1462) and the ACSM position stand (Garber et al.
/// 2011, Med Sci Sports Exerc 43(7):1334–1359): at least 150 minutes of moderate activity a week, or
/// 75 of vigorous. Each minute counts once — vigorous minutes are not doubled — so the figure never
/// overstates; the vigorous half of the guideline is stated in words beside it instead.
///
/// Workouts are never sealed: they ride the synced day record, and nothing here reads a Private store.
enum WeeklyTrainingSummaryBuilder {
    /// A set's credit to each of its exercise's primary muscles.
    static let primaryCredit = 1.0
    /// A set's credit to each secondary muscle (Pelland et al. 2024's fractional count).
    static let secondaryCredit = 0.5
    /// Lower end of the hypertrophy reference range, in hard sets per muscle per week.
    static let referenceSetsLow = 10
    /// Upper end of the hypertrophy reference range.
    static let referenceSetsHigh = 20
    /// The WHO/ACSM weekly floor for moderate aerobic activity, in minutes.
    static let aerobicGuidelineMinutes = 150
    /// The WHO/ACSM weekly floor for vigorous aerobic activity, in minutes.
    static let vigorousGuidelineMinutes = 75
    /// How many weeks before the current one the screen can step back: "the last 4 weeks".
    static let maxWeeksBack = 4
    /// Days in a week.
    static let daysPerWeek = 7
    /// The most minutes one row may add (R3: `duration` arrives from synced storage).
    static let maxMinutesPerWorkout = 24 * 60

    /// The calibration tag a ramp-up line carries in the log text ("Back squat - 1 x 5 @ 95 lb
    /// (ramp-up)"). A FROZEN log token, never localized: it is what `ExerciseResult.loggedLine`
    /// writes for a `.ramp` step (a test pins the two together), and it is how a hand-logged copy of
    /// a calibration session ("Log it again") still shows which sets were the warm-up ramp.
    static let rampTag = "(ramp-up)"

    /// Activities counted as aerobic beyond those whose Fernlet category is cardio. Dance and the
    /// striking arts are moderate to vigorous on the Compendium of Physical Activities (Ainsworth et
    /// al. 2011, at or above the 3-MET "moderate" line), while the mind-body, flexibility, strength,
    /// core, climbing, recovery and "other" types stay out.
    static let extraAerobicActivities: Set<WorkoutActivityType> = [.dance, .socialDance, .kickboxing, .martialArts]

    // MARK: Weeks

    /// The week `weeksBack` weeks before the one holding `today`: its first and last days and its
    /// seven day keys. The week starts on `calendar.firstWeekday`.
    ///
    /// - Returns: nil when `weeksBack` is outside `0...maxWeeksBack`, or the calendar can't place
    ///   the week.
    static func week(containing today: Date, weeksBack: Int, calendar: Calendar)
        -> (start: Date, end: Date, dayKeys: [String])? {
        guard (0...maxWeeksBack).contains(weeksBack),
              let current = calendar.dateInterval(of: .weekOfYear, for: today),
              let start = calendar.date(byAdding: .weekOfYear, value: -weeksBack, to: current.start) else { return nil }
        let dates = (0..<daysPerWeek).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
        guard dates.count == daysPerWeek, let end = dates.last else { return nil }
        return (start, end, dates.map { FernletDate.dayKey(for: $0) })
    }

    // MARK: The summary

    /// The week's totals from `days` (keyed by day key, today included).
    ///
    /// - Parameters:
    ///   - days: The day history, as `FernletStore.loadDays()` returns it.
    ///   - today: Any moment of today; the current week is the one holding it.
    ///   - weeksBack: 0 for the current week, up to ``maxWeeksBack``.
    ///   - calendar: The user's calendar, whose `firstWeekday` starts the week.
    ///   - exercises: The exercises names resolve against; nil means the catalog's
    ///     `allExercises` (bundled plus the user's own).
    /// - Returns: nil when the week can't be placed (see ``week(containing:weeksBack:calendar:)``).
    static func summary(
        days: [String: FernletDay], today: Date, weeksBack: Int, calendar: Calendar,
        exercises: [ExerciseTarget]? = nil
    ) -> WeeklyTrainingSummary? {
        guard let span = week(containing: today, weeksBack: weeksBack, calendar: calendar) else { return nil }
        let index = exerciseIndex(exercises ?? WorkoutExerciseCatalog.allExercises)
        var credit: [MuscleGroup: Double] = [:]
        var minutes = 0
        for key in span.dayKeys {
            for workout in days[key]?.workouts ?? [] {
                creditSets(in: workout, index: index, into: &credit)
                minutes += aerobicMinutes(of: workout)
            }
        }
        let rows = MuscleGroup.allCases.compactMap { muscle -> WeeklyTrainingSummary.MuscleSets? in
            guard let sets = credit[muscle], sets > 0 else { return nil }
            return WeeklyTrainingSummary.MuscleSets(muscle: muscle, sets: sets)
        }
        return WeeklyTrainingSummary(weekStart: span.start, weekEnd: span.end, muscleSets: rows, aerobicMinutes: minutes)
    }

    /// The exercises keyed by ``WorkoutExerciseCatalog/normalizedName(_:)``; the first of two that
    /// share a name wins, as in `allExercises` (a bundled row before a custom one).
    static func exerciseIndex(_ exercises: [ExerciseTarget]) -> [String: ExerciseTarget] {
        var index: [String: ExerciseTarget] = [:]
        for exercise in exercises {
            let key = WorkoutExerciseCatalog.normalizedName(exercise.name)
            guard !key.isEmpty, index[key] == nil else { continue }
            index[key] = exercise
        }
        return index
    }

    // MARK: Sets

    /// Adds one row's working sets to `credit`: its results when it has them, else its lines unless
    /// it is a guided row (whose text is a plan, not a record).
    static func creditSets(in workout: Workout, index: [String: ExerciseTarget], into credit: inout [MuscleGroup: Double]) {
        if let results = workout.exerciseResults {
            for result in results { creditResult(result, index: index, into: &credit) }
        } else if workout.loggedFromGuidedSession != true {
            for line in workout.exerciseLines { creditLine(line, index: index, into: &credit) }
        }
    }

    /// One structured result: every set done with at least one rep, unless it was a ramp-up set.
    static func creditResult(_ result: ExerciseResult, index: [String: ExerciseTarget], into credit: inout [MuscleGroup: Double]) {
        guard result.calibration != .ramp,
              let target = index[WorkoutExerciseCatalog.normalizedName(result.name)],
              countsAsWorkingSets(target) else { return }
        let done = result.repsPerSet.filter { $0 > 0 }.count
        add(sets: Double(done), of: target, to: &credit)
    }

    /// One hand-logged line: the sets written, unless it is a hold or a ramp-up line.
    static func creditLine(_ line: String, index: [String: ExerciseTarget], into credit: inout [MuscleGroup: Double]) {
        guard !line.contains(rampTag),
              let parsed = ExerciseLineParser.parse(line), let sets = parsed.sets, sets > 0,
              !isHold(parsed),
              let target = index[WorkoutExerciseCatalog.normalizedName(parsed.name)],
              countsAsWorkingSets(target) else { return }
        add(sets: Double(min(sets, ExerciseResult.maxSets)), of: target, to: &credit)
    }

    /// A parsed line that counts seconds ("Plank - 2 x 30 s"), which the parser marks with an "s".
    static func isHold(_ parsed: ExerciseLineParser.Parsed) -> Bool {
        parsed.reps?.hasSuffix(" s") == true
    }

    /// Strength work counted in reps — the only kind whose sets are "hard sets".
    static func countsAsWorkingSets(_ target: ExerciseTarget) -> Bool {
        target.modality == .strength && target.measure == .reps
    }

    /// Credits `sets` to the target's primary muscles in full and its secondary muscles as half. A
    /// muscle listed as both counts once, as primary.
    static func add(sets: Double, of target: ExerciseTarget, to credit: inout [MuscleGroup: Double]) {
        guard sets > 0, sets.isFinite else { return }
        for muscle in target.primaryMuscles {
            credit[muscle, default: 0] += sets * primaryCredit
        }
        for muscle in target.secondaryMuscles.subtracting(target.primaryMuscles) {
            credit[muscle, default: 0] += sets * secondaryCredit
        }
    }

    // MARK: Aerobic minutes

    /// Whether a row's minutes count as aerobic.
    ///
    /// A row with an activity type counts when that type's Fernlet category is cardio (running,
    /// walking, cycling, swimming, rowing, HIIT, racquet and team sports …) or it is one of
    /// ``extraAerobicActivities``; Apple Health imports carry their type, so they are read the same
    /// way. A row without one counts when its stored category is cardio — a guided cardio session, or
    /// a hand-logged row the Log sheet filed under Cardio — or a legacy run or hike. Strength
    /// sessions (guided, hand-logged or imported) never count, even when they end with a cardio block:
    /// their minutes are mostly lifting.
    static func countsAsAerobic(_ workout: Workout) -> Bool {
        if let activity = workout.activityType {
            return activity.fernletCategory == .cardio || extraAerobicActivities.contains(activity)
        }
        switch workout.type {
        case .cardio, .run, .hike: return true
        case .upper, .lower, .armsBack, .mixed, .fullBody: return false
        }
    }

    /// A row's aerobic minutes: its logged duration when it counts as aerobic, else 0. A row with no
    /// duration adds nothing rather than a guess.
    static func aerobicMinutes(of workout: Workout) -> Int {
        guard countsAsAerobic(workout), let duration = workout.duration else { return 0 }
        return min(max(duration, 0), maxMinutesPerWorkout)
    }
}
