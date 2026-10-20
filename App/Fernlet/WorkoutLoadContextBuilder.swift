import Foundation
import FernletDomainModel
import FernletFoundation

/// Builds the planner's ``WorkoutLoadContext`` from the day history.
///
/// Each lift's sessions come from two sources, oldest first:
/// - a row's structured ``ExerciseResult``s (the runner's record of what was prescribed, the weight
///   picked, and the reps done; a lift entered set by set in the Log sheet; a set corrected later in
///   the Edit sheet) — first-class;
/// - a hand-logged row's other lines, read by ``ExerciseLineParser`` ("Squat 5x5 @225lb") — what the
///   person wrote is what they did, so it counts as completed. Several lines of one lift on one day
///   keep the heaviest, and a lift the row's own structured record covers is read from the record.
///
/// A guided row WITHOUT results is skipped: it records the plan that was suggested, not what was
/// lifted (every guided log before load tracking, and the "Mark done" path), so reading it would make
/// a fixed "4 x 5" plan look like a stall every week. Sleep and protein over the last two weeks feed
/// the plateau's rest check; the newest calibration test dates the next one. Pure over its inputs.
enum WorkoutLoadContextBuilder {
    /// How far back sessions are read (the plateau's lookback).
    static let lookbackDays = WorkoutPlateau.lookbackDays
    /// The rest check's window.
    static let recoveryDays = 14
    /// Plausible logged sleep, in hours; anything outside is ignored.
    static let sleepHoursRange = 0.5...16.0

    static func build(
        days: [String: FernletDay], today: FernletDay, todayKey: String, settings: FernletSettings,
        locale: Locale = .current
    ) -> WorkoutLoadContext {
        let unit = defaultUnit(for: locale)
        guard let todayDate = FernletDate.date(fromDayKey: todayKey) else {
            return WorkoutLoadContext(exposures: [:], today: Date(), defaultUnit: unit)
        }
        var merged = days
        merged[todayKey] = today
        let window = merged.values
            .compactMap { day in FernletDate.date(fromDayKey: day.date).map { (day, $0) } }
            .filter { pair in
                let age = Calendar.current.dateComponents([.day], from: pair.1, to: todayDate).day ?? Int.max
                return age >= 0 && age <= lookbackDays
            }
            .sorted { $0.1 < $1.1 }
        let sessions = exposures(window)
        return WorkoutLoadContext(
            exposures: sessions.byLift, today: todayDate, defaultUnit: unit,
            recovery: recovery(window, todayDate: todayDate, settings: settings),
            calibration: CalibrationSettings(hasCoach: settings.coachExchangeEnabled, lastCalibration: sessions.lastCalibration)
        )
    }

    /// Pounds where the locale measures in US customary units, kilograms elsewhere.
    static func defaultUnit(for locale: Locale) -> LoadUnit {
        locale.measurementSystem == .us ? .lb : .kg
    }

    /// Every lift's sessions in `days` (oldest first), and the date of the newest calibration test.
    static func exposures(_ days: [(FernletDay, Date)]) -> (byLift: [String: [LiftExposure]], lastCalibration: Date?) {
        var byLift: [String: [LiftExposure]] = [:]
        var lastCalibration: Date?
        for (day, date) in days {
            var handLogged: [String: LiftExposure] = [:]
            for workout in day.workouts {
                let results = workout.exerciseResults ?? []
                for result in results {
                    byLift[WorkoutExerciseCatalog.normalizedName(result.name), default: []]
                        .append(LiftExposure(date: date, result: result))
                    if result.calibration == .test || result.calibration == .attempt { lastCalibration = date }
                }
                // A guided row's other lines are its plan, never performance. A hand-logged row's
                // lines are what was lifted, except a lift its own structured record (entered set by
                // set, or corrected in the Edit sheet) already covers.
                guard workout.loggedFromGuidedSession != true else { continue }
                let covered = Set(results.map { WorkoutExerciseCatalog.normalizedName($0.name) })
                foldHandLogged(workout.exerciseLines, date: date, excluding: covered, into: &handLogged)
            }
            for key in handLogged.keys.sorted() {
                guard let exposure = handLogged[key] else { continue }
                byLift[key, default: []].append(exposure)
            }
        }
        for key in byLift.keys {
            byLift[key] = byLift[key].map { Array($0.suffix(WorkoutLoadEngine.maxExposuresPerLift)) }
        }
        return (byLift, lastCalibration)
    }

    /// Folds one hand-logged row's lines into the day's per-lift sessions, keeping the heaviest. Lifts
    /// in `covered` (normalized names the row's structured results already record) are skipped.
    static func foldHandLogged(
        _ lines: [String], date: Date, excluding covered: Set<String> = [], into sessions: inout [String: LiftExposure]
    ) {
        for line in lines {
            guard let logged = handLoggedExposure(line, date: date), !covered.contains(logged.key) else { continue }
            if let existing = sessions[logged.key], (existing.weight ?? 0) >= (logged.exposure.weight ?? 0) { continue }
            sessions[logged.key] = logged.exposure
        }
    }

    /// One hand-logged line as a completed session keyed by its lift, or nil for a hold, a rep
    /// range, or a line with no sets×reps.
    static func handLoggedExposure(_ line: String, date: Date) -> (key: String, exposure: LiftExposure)? {
        guard let parsed = ExerciseLineParser.parse(line), let reps = parsed.repsCount, reps > 0,
              let sets = parsed.sets, sets > 0 else { return nil }
        let key = WorkoutExerciseCatalog.normalizedName(parsed.name)
        guard !key.isEmpty else { return nil }
        let exposure = LiftExposure(
            date: date, weight: parsed.weight, unit: parsed.weightUnit.flatMap(LoadUnit.init(rawValue:)),
            targetReps: reps, repsPerSet: Array(repeating: reps, count: min(sets, ExerciseResult.maxSets))
        )
        return (key, exposure)
    }

    /// Sleep (last night included) and protein (today excluded — it isn't over) over the rest check's
    /// window. Sleep prefers the person's own log, then Health's figure for the night.
    static func recovery(_ days: [(FernletDay, Date)], todayDate: Date, settings: FernletSettings) -> RecoverySummary {
        let recent = days.filter { pair in
            let age = Calendar.current.dateComponents([.day], from: pair.1, to: todayDate).day ?? Int.max
            return age >= 0 && age < recoveryDays
        }
        let nights = recent.compactMap { pair in pair.0.sleep?.hours ?? pair.0.healthContext?.body?.sleepHours }
            .filter { sleepHoursRange.contains($0) }
        let target = Double(NutritionTargetCalculator.targets(for: settings).protein)
        let proteinDays = recent.filter { $0.1 < todayDate && !$0.0.meals.isEmpty }
            .map { pair in Double(pair.0.meals.reduce(0) { $0 + $1.macroSnapshot.protein }) }
        return RecoverySummary(
            averageSleepHours: nights.isEmpty ? nil : nights.reduce(0, +) / Double(nights.count),
            sleepNights: nights.count,
            averageProteinRatio: proteinDays.isEmpty || target <= 0
                ? nil : proteinDays.reduce(0, +) / Double(proteinDays.count) / target,
            proteinDays: target > 0 ? proteinDays.count : 0
        )
    }
}
