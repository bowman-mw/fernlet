//
//  SillyStatsTallier.swift
//  Fernlet
//
//  Adds up the diary into the silly stats' lifetime totals: foods by name, lifted weight from the
//  free-text exercise lines, stair minutes and swim/ride/walk distances from typed workouts, sleep
//  and dream-stage minutes, water, and the personal-care checklist.
//

import Foundation
import FernletDomainModel
import FernletFoundation

/// Builds a ``SillyStatsTally`` from the diary's days plus the figures that live elsewhere.
///
/// Pure: the caller loads the days, reads the Health step total and the pat count, and passes them
/// in, so the whole fold is testable without a store. Never reads cycle, intimate or mindfulness
/// context, calories, body weight, or journal text.
enum SillyStatsTallier {
    /// Everything the tally is built from.
    struct Inputs {
        var days: [FernletDay]
        var todayKey: String
        /// The user's bottle size, applied to every logged bottle.
        var bottleOunces: Int
        /// Lifetime steps from Apple Health since the first day, or nil when Health is off.
        var healthSteps: Int?
        /// Lifetime pats on this device.
        var pats: Int
        /// The unit for a lifted weight that names none ("@135"): pounds where the locale is US.
        var unitlessLoadIsPounds: Bool
    }

    static let poundsToKilograms = 0.45359237
    static let milesToKilometers = 1.609344
    static let fluidOunceLiters = 0.0295735
    /// Per-day and per-workout sanity caps, so one corrupt row cannot swamp a lifetime total.
    static let maxBottlesPerDay = 100
    static let maxWorkoutMinutes = 600
    static let maxWorkoutMiles = 500.0

    static func tally(_ inputs: Inputs) -> SillyStatsTally {
        var tally = SillyStatsTally()
        var dishes: [String: SillySignatureDish] = [:]
        var residueSteps = 0
        for day in inputs.days {
            add(day, to: &tally, dishes: &dishes, inputs: inputs)
            residueSteps += max(day.healthContext?.activity?.steps ?? 0, 0)
        }
        tally.steps = max(inputs.healthSteps ?? 0, residueSteps)
        tally.pats = max(inputs.pats, 0)
        tally.signatureDish = signatureDish(in: dishes)
        tally.daysKnown = daysKnown(days: inputs.days, todayKey: inputs.todayKey)
        return tally
    }

    /// The day each stat first had enough behind it to show, replaying the diary day by day — what
    /// dates a stamp the book catches up on (``SillyStampRules``).
    ///
    /// Only the diary is replayed. Apple Health's lifetime step total and the pat count carry no
    /// dates, so a stat that shows only thanks to them is missing from the result (the steps a day
    /// record kept for itself do count, on their day). The companion's age is dated directly — the
    /// third day from the first one with anything logged — because a day with nothing logged has no
    /// record to replay.
    static func firstRevealDays(_ inputs: Inputs, calendar: Calendar = .current) -> [SillyStatKind: String] {
        var tally = SillyStatsTally()
        var dishes: [String: SillySignatureDish] = [:]
        var found: [SillyStatKind: String] = [:]
        let days = inputs.days.filter { $0.date <= inputs.todayKey }.sorted { $0.date < $1.date }
        for day in days where found.count < SillyStatKind.allCases.count {
            add(day, to: &tally, dishes: &dishes, inputs: inputs)
            tally.steps += max(day.healthContext?.activity?.steps ?? 0, 0)
            if found[.signatureDish] == nil { tally.signatureDish = signatureDish(in: dishes) }
            for kind in SillyStatKind.allCases where found[kind] == nil && SillyStatsEngine.isRevealed(kind, in: tally) {
                found[kind] = day.date
            }
        }
        found[.gastrotrichLifetimes] = gastrotrichDay(days: inputs.days, todayKey: inputs.todayKey, calendar: calendar)
        return found
    }

    /// One day's food, workouts, rest and care, folded into `tally`.
    private static func add(
        _ day: FernletDay, to tally: inout SillyStatsTally, dishes: inout [String: SillySignatureDish], inputs: Inputs
    ) {
        addFood(of: day, to: &tally, dishes: &dishes)
        addWorkouts(of: day, to: &tally, unitlessLoadIsPounds: inputs.unitlessLoadIsPounds)
        addRest(of: day, to: &tally)
        addCare(of: day, to: &tally, bottleOunces: inputs.bottleOunces)
    }

    /// The day the companion's age first reached a gastrotrich lifetime, or nil if it has not yet.
    static func gastrotrichDay(days: [FernletDay], todayKey: String, calendar: Calendar = .current) -> String? {
        let lifetime = Int(SillyStatsEngine.Constant.gastrotrichDays.rounded(.up))
        guard lifetime >= 1,
              let firstKey = days.filter(\.hasLoggedContent).map(\.date).min(),
              let first = FernletDate.date(fromDayKey: firstKey),
              let reached = calendar.date(byAdding: .day, value: lifetime - 1, to: calendar.startOfDay(for: first)) else { return nil }
        let key = FernletDate.dayKey(for: reached)
        return key <= todayKey ? key : nil
    }

    // MARK: - Food

    private static func addFood(of day: FernletDay, to tally: inout SillyStatsTally, dishes: inout [String: SillySignatureDish]) {
        for meal in day.meals {
            tally.cookieEquivalents += SillyFoodCounter.cookieEquivalents(in: meal)
            tally.bananas += SillyFoodCounter.items(of: SillyFoodCounter.banana, in: meal)
            tally.eggs += SillyFoodCounter.items(of: SillyFoodCounter.egg, in: meal)
            tally.pizzaSlices += SillyFoodCounter.items(of: SillyFoodCounter.pizzaSlice, in: meal)
            tally.coffeeCups += SillyFoodCounter.items(of: SillyFoodCounter.cupOfCoffeeOrTea, in: meal)
            guard meal.mealSource == .recipe else { continue }
            let key = meal.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty else { continue }
            var dish = dishes[key] ?? SillySignatureDish(name: meal.name.trimmingCharacters(in: .whitespacesAndNewlines), count: 0)
            dish.count += 1
            dishes[key] = dish
        }
    }

    /// The most-logged homemade recipe; ties go to the alphabetically first name so the pick is
    /// stable from one launch to the next.
    static func signatureDish(in dishes: [String: SillySignatureDish]) -> SillySignatureDish? {
        let sorted = dishes.sorted { $0.key < $1.key }.map(\.value)
        var best: SillySignatureDish?
        for dish in sorted where dish.count > (best?.count ?? 0) {
            best = dish
        }
        return best
    }

    // MARK: - Movement

    private static func addWorkouts(of day: FernletDay, to tally: inout SillyStatsTally, unitlessLoadIsPounds: Bool) {
        for workout in day.workouts {
            for line in workout.exerciseLines {
                tally.liftedKilograms += liftedKilograms(line: line, unitlessLoadIsPounds: unitlessLoadIsPounds)
            }
            guard let activity = workout.activityType else { continue }
            let minutes = Double(min(max(workout.duration ?? 0, 0), maxWorkoutMinutes))
            let kilometers = min(max(workout.distanceMiles ?? 0, 0), maxWorkoutMiles) * milesToKilometers
            switch activity {
            case .stairClimbing, .stairs:
                tally.stairMeters += minutes * SillyStatsEngine.Constant.stairMetersPerMinute
            case .swimmingPool, .swimmingOpenWater:
                tally.swimKilometers += kilometers
            case .cycling, .indoorCycling:
                tally.cycleKilometers += kilometers
            case .running, .walking, .hiking:
                tally.workoutFootKilometers += kilometers
            default:
                continue
            }
        }
    }

    /// Weight moved by one exercise line: sets × reps × load, every set at the stated load. A line
    /// without a load (bodyweight, a guided-program line) moved nothing countable.
    static func liftedKilograms(line: String, unitlessLoadIsPounds: Bool) -> Double {
        guard let parsed = ExerciseLineParser.parse(line),
              let weight = parsed.weight, weight.isFinite, weight > 0,
              let sets = parsed.sets, sets > 0,
              let reps = repCount(parsed), reps > 0 else { return 0 }
        let isPounds = parsed.weightUnit.map { $0 == "lb" } ?? unitlessLoadIsPounds
        let kilograms = isPounds ? weight * poundsToKilograms : weight
        return Double(sets * reps) * kilograms
    }

    /// The rep count, reading a range ("8-10") as its first number; nil for "AMRAP" and the like.
    static func repCount(_ parsed: ExerciseLineParser.Parsed) -> Int? {
        if let count = parsed.repsCount { return count }
        guard let reps = parsed.reps else { return nil }
        let first = reps.split(whereSeparator: { !$0.isNumber }).first
        return first.flatMap { Int($0) }
    }

    // MARK: - Sleep and care

    private static func addRest(of day: FernletDay, to tally: inout SillyStatsTally) {
        let hours = day.sleep?.hours ?? day.healthContext?.body?.sleepHours ?? 0
        if hours.isFinite { tally.sleepHours += min(max(hours, 0), 24) }
        let rem = day.healthContext?.body?.sleepStages?.remMinutes ?? 0
        if rem.isFinite { tally.remMinutes += min(max(rem, 0), 24 * 60) }
    }

    private static func addCare(of day: FernletDay, to tally: inout SillyStatsTally, bottleOunces: Int) {
        let bottles = min(max(day.bottleCount, 0), maxBottlesPerDay)
        tally.waterLiters += Double(bottles * max(bottleOunces, 0)) * fluidOunceLiters
        if day.hygiene.contains(.floss) { tally.flossCount += 1 }
        if day.hygiene.contains(.teethAM) { tally.brushCount += 1 }
        if day.hygiene.contains(.teethPM) { tally.brushCount += 1 }
        if day.hygiene.contains(.shower) { tally.showerCount += 1 }
    }

    // MARK: - Days known

    /// Days from the first day anything was logged through `todayKey`, inclusive; 1 before that.
    static func daysKnown(days: [FernletDay], todayKey: String, calendar: Calendar = .current) -> Int {
        let firstKey = days.filter(\.hasLoggedContent).map(\.date).min()
        guard let firstKey, firstKey <= todayKey,
              let first = FernletDate.date(fromDayKey: firstKey),
              let today = FernletDate.date(fromDayKey: todayKey) else { return 1 }
        let span = calendar.dateComponents([.day], from: calendar.startOfDay(for: first), to: calendar.startOfDay(for: today))
        return max((span.day ?? 0) + 1, 1)
    }
}
