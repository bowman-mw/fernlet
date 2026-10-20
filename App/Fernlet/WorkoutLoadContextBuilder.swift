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
/// a fixed "4 x 5" plan look like a stall every week.
///
/// Every session carries its G10 flag (``WorkoutSessionFlag``): the night before it — the day's own
/// sleep log, else Health's figure for the night — against 6 h and against the person's median of
/// the 14 nights before, the night before that for the firmer flag, and a workout logged as light.
/// Protein over the last two weeks is context for the trend story; the newest calibration test dates
/// the next one; the warm-up-sets setting and the lifter's level say whether heavy lifts get warm-up
/// sets. Pure over its inputs.
enum WorkoutLoadContextBuilder {
    /// How far back sessions are read (the plateau's lookback).
    static let lookbackDays = WorkoutPlateau.lookbackDays
    /// The protein context's window.
    static let recoveryDays = 14
    /// Plausible logged sleep, in hours; anything outside is ignored.
    static let sleepHoursRange = 0.5...16.0

    /// The context for today. `body` is the body profile in effect on this device (the typed one with
    /// this device's Health import laid over it, `effectiveUserProfile`); nil reads the synced one.
    static func build(
        days: [String: FernletDay], today: FernletDay, todayKey: String, settings: FernletSettings,
        body: UserNutritionProfile? = nil, locale: Locale = .current
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
        let sessions = exposures(window, nights: sleepByDay(merged))
        return WorkoutLoadContext(
            exposures: sessions.byLift, today: todayDate, defaultUnit: unit,
            recovery: recovery(window, todayDate: todayDate, settings: settings),
            calibration: CalibrationSettings(hasCoach: settings.coachExchangeEnabled, lastCalibration: sessions.lastCalibration),
            warmUpSets: WorkoutWarmUpSets.isEnabled(
                preference: settings.workoutWarmUpSets, experience: settings.workoutProfile.experience
            ),
            traits: traits(body ?? settings.userProfile)
        )
    }

    /// The person's traits for the expected curve, read on this device only: age, sex and body weight.
    static func traits(_ body: UserNutritionProfile) -> LifterTraits {
        LifterTraits(sex: body.sex, ageYears: body.age, bodyWeightKg: body.weightKilograms)
    }

    /// Pounds where the locale measures in US customary units, kilograms elsewhere.
    static func defaultUnit(for locale: Locale) -> LoadUnit {
        locale.measurementSystem == .us ? .lb : .kg
    }

    /// Every lift's sessions in `days` (oldest first), each with its sleep or readiness flag, and the
    /// date of the newest calibration test. `nights` is ``sleepByDay(_:)`` over the whole history, so
    /// a session near the window's start still has its 14 nights before it.
    static func exposures(
        _ days: [(FernletDay, Date)], nights: [String: Double] = [:]
    ) -> (byLift: [String: [LiftExposure]], lastCalibration: Date?) {
        var byLift: [String: [LiftExposure]] = [:]
        var lastCalibration: Date?
        for (day, date) in days {
            let sleep = sleepFlag(on: date, nights: nights)
            var handLogged: [String: LiftExposure] = [:]
            for workout in day.workouts {
                let flag = WorkoutSessionFlag.make(sleep: sleep, lightDay: workout.intensity == .light)
                let results = workout.exerciseResults ?? []
                // A ramp set is never evidence (the engine, the trend and the weekly count all skip
                // it), so it never takes one of a lift's capped places either.
                for result in results where result.calibration != .ramp {
                    byLift[WorkoutExerciseCatalog.normalizedName(result.name), default: []]
                        .append(LiftExposure(date: date, result: result, flag: flag))
                    if result.calibration == .test || result.calibration == .attempt { lastCalibration = date }
                }
                // A guided row's other lines are its plan, never performance. A hand-logged row's
                // lines are what was lifted, except a lift its own structured record (entered set by
                // set, or corrected in the Edit sheet) already covers.
                guard workout.loggedFromGuidedSession != true else { continue }
                let covered = Set(results.map { WorkoutExerciseCatalog.normalizedName($0.name) })
                foldHandLogged(workout.exerciseLines, date: date, excluding: covered, flag: flag, into: &handLogged)
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
        _ lines: [String], date: Date, excluding covered: Set<String> = [], flag: WorkoutSessionFlag? = nil,
        into sessions: inout [String: LiftExposure]
    ) {
        for line in lines {
            guard let logged = handLoggedExposure(line, date: date, flag: flag), !covered.contains(logged.key) else {
                continue
            }
            if let existing = sessions[logged.key], (existing.weight ?? 0) >= (logged.exposure.weight ?? 0) { continue }
            sessions[logged.key] = logged.exposure
        }
    }

    /// One hand-logged line as a completed session keyed by its lift, or nil for a hold, a rep
    /// range, a ramp-up set copied from a guided log ("… (ramp-up)", which is never a working set), or
    /// a line with no sets×reps.
    static func handLoggedExposure(
        _ line: String, date: Date, flag: WorkoutSessionFlag? = nil
    ) -> (key: String, exposure: LiftExposure)? {
        guard !WorkoutWarmUpSets.isRampLine(line),
              let parsed = ExerciseLineParser.parse(line), let reps = parsed.repsCount, reps > 0,
              let sets = parsed.sets, sets > 0 else { return nil }
        let key = WorkoutExerciseCatalog.normalizedName(parsed.name)
        guard !key.isEmpty else { return nil }
        let exposure = LiftExposure(
            date: date, weight: parsed.weight, unit: parsed.weightUnit.flatMap(LoadUnit.init(rawValue:)),
            targetReps: reps, repsPerSet: Array(repeating: reps, count: min(sets, ExerciseResult.maxSets)),
            flag: flag
        )
        return (key, exposure)
    }

    /// Each day's sleep in hours, keyed by day key: the person's own log first, then Health's figure
    /// for the night. A value outside ``sleepHoursRange`` is left out, never read as short.
    static func sleepByDay(_ days: [String: FernletDay]) -> [String: Double] {
        var nights: [String: Double] = [:]
        for day in days.values {
            guard let hours = day.sleep?.hours ?? day.healthContext?.body?.sleepHours,
                  sleepHoursRange.contains(hours) else { continue }
            nights[day.date] = hours
        }
        return nights
    }

    /// The G10 sleep flag for a session on `date` (``WorkoutSessionFlags/sleepFlag(lastNight:previousNight:earlierNights:)``):
    /// last night is the day's own sleep, the night before is the previous day's, and the median comes
    /// from the 14 nights before last night. A night with nothing logged is absent, never short.
    static func sleepFlag(on date: Date, nights: [String: Double]) -> SleepFlag? {
        guard !nights.isEmpty else { return nil }
        let calendar = Calendar.current
        func night(_ back: Int) -> Double? {
            calendar.date(byAdding: .day, value: -back, to: date).flatMap { nights[FernletDate.dayKey(for: $0)] }
        }
        let earlier = (1...WorkoutSessionFlags.medianWindowDays).reversed().compactMap(night)
        return WorkoutSessionFlags.sleepFlag(lastNight: night(0), previousNight: night(1), earlierNights: earlier)
    }

    /// Protein over the context's window, today excluded (it isn't over). Sleep is no longer averaged:
    /// it flags single sessions instead (``sleepFlag(on:nights:)``).
    static func recovery(_ days: [(FernletDay, Date)], todayDate: Date, settings: FernletSettings) -> RecoverySummary {
        let recent = days.filter { pair in
            let age = Calendar.current.dateComponents([.day], from: pair.1, to: todayDate).day ?? Int.max
            return age >= 0 && age < recoveryDays
        }
        let target = Double(NutritionTargetCalculator.targets(for: settings).protein)
        let proteinDays = recent.filter { $0.1 < todayDate && !$0.0.meals.isEmpty }
            .map { pair in Double(pair.0.meals.reduce(0) { $0 + $1.macroSnapshot.protein }) }
        return RecoverySummary(
            averageProteinRatio: proteinDays.isEmpty || target <= 0
                ? nil : proteinDays.reduce(0, +) / Double(proteinDays.count) / target,
            proteinDays: target > 0 ? proteinDays.count : 0
        )
    }
}
