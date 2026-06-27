//
//  DerivedSignalFactory.swift
//  Fernlet
//
//  Computes the rolling derived-signal window from stored day pairs.
//

import Foundation
import FernletDomainModel
import FernletScoring

public enum DerivedSignalFactory {
    public static func makeSignals(from days: [(String, FernletDay)], todayKey: String) -> [DerivedSignalRecord] {
        assert(!todayKey.isEmpty, "today key required")
        assert(days.count <= FernletLimits.signalWindowDays, "too many signal days")
        guard let first = days.first?.0, let last = days.last?.0 else { return [] }
        return [
            moodTrend(from: days, start: first, end: last),
            energyTrend(from: days, start: first, end: last),
            eatingPattern(from: days, start: first, end: last),
            progressionTrend(from: days, start: first, end: last),
            intensityReadiness(from: days, start: first, end: last),
            micronutrientTrend(from: days, start: first, end: last, windowDays: 7),
            micronutrientTrend(from: days, start: first, end: last, windowDays: 14)
        ]
    }

    private static func moodTrend(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(!start.isEmpty, "start required")
        assert(!end.isEmpty, "end required")
        let scores = dailyMoodScores(from: days)
        let value: String
        if scores.count < 2 {
            value = "insufficient data"
        } else if scores.suffix(3).contains(where: { $0 <= 0.4 }) {
            value = "needs gentleness"
        } else {
            value = trendValue(scores: scores, rising: "improving", falling: "declining", steady: "steady")
        }
        return DerivedSignalRecord(signalName: "moodTrend", value: value, windowStart: start, windowEnd: end, sourceFields: ["journals.tag"])
    }

    private static func energyTrend(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        assert(!end.isEmpty, "end required")
        let scores = dailyEnergyScores(from: days)
        let recentAverage = average(Array(scores.suffix(min(3, scores.count))))
        let value: String
        if scores.count < 2 {
            value = "insufficient data"
        } else if recentAverage < 0.48 {
            value = "low"
        } else {
            value = trendValue(scores: scores, rising: "rising", falling: "dipping", steady: "steady")
        }
        return DerivedSignalRecord(signalName: "energyTrend", value: value, windowStart: start, windowEnd: end, sourceFields: ["sleep.hours", "sleep.quality", "journals.tag", "workouts.intensity"])
    }

    private static func eatingPattern(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        assert(!start.isEmpty, "start required")
        let loggedDays = days.filter { $0.1.meals.isEmpty == false }
        let value: String
        if loggedDays.count < 2 {
            value = "insufficient data"
        } else {
            let mealCounts = loggedDays.map { min($0.1.meals.count, FernletLimits.maxMealsPerDay) }
            let averageMeals = average(mealCounts.map(Double.init))
            let skippedRecentDays = days.suffix(min(3, days.count)).filter { $0.1.meals.isEmpty }.count
            let proteinDays = loggedDays.filter { MacroTotals(meals: $0.1.meals).protein >= 70 }.count
            if skippedRecentDays >= 2 || averageMeals < 1.5 {
                value = "light"
            } else if proteinDays >= max(2, Int(ceil(Double(loggedDays.count) * 0.6))) {
                value = "protein-forward"
            } else if (mealCounts.max() ?? 0) - (mealCounts.min() ?? 0) >= 3 {
                value = "inconsistent"
            } else {
                value = "consistent"
            }
        }
        return DerivedSignalRecord(signalName: "eatingPattern", value: value, windowStart: start, windowEnd: end, sourceFields: ["meals.count", "meals.macros", "meals.calorieSnapshot"])
    }

    private static func intensityReadiness(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        assert(!end.isEmpty, "end required")
        let recentDays = Array(days.suffix(min(3, days.count)))
        let recentLoad = recentDays.map { dailyTrainingLoad($0.1) }.reduce(0, +)
        let recentEnergy = average(dailyEnergyScores(from: recentDays))
        let recentMeals = recentDays.reduce(0) { $0 + min($1.1.meals.count, FernletLimits.maxMealsPerDay) }
        let recentHardCount = recentDays.reduce(0) { count, day in
            count + day.1.workouts.prefix(FernletLimits.maxWorkoutsPerDay).filter { $0.intensity == .hard }.count
        }
        // Autonomic recovery from HealthKit HR/HRV, averaged across the days that supplied it.
        // Optional — many days won't have wearable data, in which case readiness stays
        // behaviour-only (identical to the pre-HealthKit result).
        let recoveryScores: [Double] = recentDays.compactMap { _, day in
            guard let body = day.healthContext?.body else { return nil }
            return FernletScoring.recoveryReadinessScore(
                restingHeartRateBPM: body.restingHeartRateBPM,
                heartRateVariabilityMS: body.heartRateVariabilityMS,
                sleepQuality: day.sleep?.quality,
                sleepHours: body.sleepHours ?? day.sleep?.hours
            )
        }
        let recovery: Double? = recoveryScores.isEmpty ? nil : average(recoveryScores)
        let value: String
        if recentDays.isEmpty || (recentLoad == 0 && recentEnergy == 0 && recentMeals == 0) {
            value = "insufficient data"
        } else if recentEnergy < 0.45 || recentHardCount >= 2 || recentLoad >= 260 || (recovery ?? 1) < 0.4 {
            // Poor autonomic recovery (low HRV / elevated resting HR) caps the recommendation at light.
            value = "ready for light"
        } else if recentEnergy >= 0.72 && recentHardCount == 0 && recentMeals >= recentDays.count * 2 && (recovery ?? 1) >= 0.6 {
            value = "ready for hard"
        } else {
            value = "ready for moderate"
        }
        return DerivedSignalRecord(signalName: "intensityReadiness", value: value, windowStart: start, windowEnd: end, sourceFields: ["workouts.intensity", "workouts.duration", "workouts.rpe", "sleep", "journals.tag", "meals.count", "body.restingHeartRate", "body.heartRateVariability"])
    }

    private static func progressionTrend(from days: [(String, FernletDay)], start: String, end: String) -> DerivedSignalRecord {
        assert(days.count <= FernletLimits.signalWindowDays, "too many days")
        let midpoint = days.count / 2
        let older = days.prefix(midpoint)
        let newer = days.suffix(days.count - midpoint)
        let olderLoad = older.map { dailyTrainingLoad($0.1) }.reduce(0, +)
        let newerLoad = newer.map { dailyTrainingLoad($0.1) }.reduce(0, +)
        let workoutDays = days.filter { $0.1.workouts.isEmpty == false }.count
        let value: String
        if workoutDays < 2 {
            value = "insufficient data"
        } else if Double(newerLoad) >= Double(max(olderLoad, 1)) * 1.20 {
            value = "building"
        } else if Double(newerLoad) <= Double(max(olderLoad, 1)) * 0.70 {
            value = "deloading"
        } else {
            value = "steady"
        }
        return DerivedSignalRecord(signalName: "progressionTrend", value: value, windowStart: start, windowEnd: end, sourceFields: ["workouts.duration", "workouts.intensity", "workouts.rpe"])
    }

    private static func micronutrientTrend(from days: [(String, FernletDay)], start: String, end: String, windowDays: Int) -> DerivedSignalRecord {
        assert(windowDays == 7 || windowDays == 14, "unsupported nutrient window")
        let gaps = MicronutrientGapAnalyzer.gaps(from: days, windowDays: windowDays)
        let gapCount = gaps.filter { $0.status == .gap }.count
        let coveredCount = gaps.filter { $0.status == .covered }.count
        let value: String
        if gapCount > 0 {
            value = "\(gapCount) possible gap\(gapCount == 1 ? "" : "s")"
        } else if coveredCount > 0 {
            value = "\(coveredCount) covered"
        } else {
            value = "insufficient data"
        }
        return DerivedSignalRecord(
            signalName: "micronutrientGaps\(windowDays)Day",
            value: value,
            windowStart: start,
            windowEnd: end,
            sourceFields: ["meals.micronutrientSnapshot"],
            nutrientGaps: gaps
        )
    }

    private static func dailyMoodScores(from days: [(String, FernletDay)]) -> [Double] {
        days.compactMap { _, day in
            let scores = day.journals.prefix(FernletLimits.maxJournalsPerDay).map { moodScore($0.tag) }
            guard scores.isEmpty == false else { return nil }
            return average(scores)
        }
    }

    private static func dailyEnergyScores(from days: [(String, FernletDay)]) -> [Double] {
        days.compactMap { _, day in
            var components: [Double] = []
            if let sleep = day.sleep {
                components.append(sleepEnergyScore(sleep, healthSleepHours: day.healthContext?.body?.sleepHours))
            }
            let journalScores = day.journals.prefix(FernletLimits.maxJournalsPerDay).map { moodScore($0.tag) }
            if journalScores.isEmpty == false {
                components.append(average(journalScores))
            }
            let workoutLoad = dailyTrainingLoad(day)
            if workoutLoad > 0 {
                components.append(max(0.25, 1 - Double(workoutLoad) / 260))
            }
            guard components.isEmpty == false else { return nil }
            return average(components)
        }
    }

    private static func trendValue(scores: [Double], rising: String, falling: String, steady: String) -> String {
        let midpoint = scores.count / 2
        let older = Array(scores.prefix(midpoint))
        let newer = Array(scores.suffix(scores.count - midpoint))
        guard older.isEmpty == false, newer.isEmpty == false else { return steady }
        let delta = average(newer) - average(older)
        if delta >= 0.12 { return rising }
        if delta <= -0.12 { return falling }
        return steady
    }

    private static func moodScore(_ tag: FeelingTag) -> Double {
        switch tag {
        case .bright: 1
        case .good: 0.85
        case .neutral: 0.65
        case .quiet: 0.55
        case .tired: 0.35
        case .hard: 0.2
        }
    }

    private static func sleepEnergyScore(_ sleep: SleepLog, healthSleepHours: Double? = nil) -> Double {
        let qualityScore: Double
        switch sleep.quality {
        case .great: qualityScore = 1
        case .good: qualityScore = 0.82
        case .ok: qualityScore = 0.6
        case .poor: qualityScore = 0.3
        }
        // HealthKit is the source of truth for sleep duration; prefer it over the manual estimate.
        guard let hours = healthSleepHours ?? sleep.hours else { return qualityScore }
        let hourScore = min(max(hours / 8, 0), 1)
        return hourScore * 0.6 + qualityScore * 0.4
    }

    private static func dailyTrainingLoad(_ day: FernletDay) -> Int {
        day.workouts.prefix(FernletLimits.maxWorkoutsPerDay).reduce(0) { total, workout in
            let minutes = max(workout.duration ?? 30, 0)
            let intensityMultiplier: Double
            switch workout.intensity {
            case .light: intensityMultiplier = 0.75
            case .moderate: intensityMultiplier = 1
            case .hard: intensityMultiplier = 1.35
            }
            let rpeMultiplier = workout.rpe.map { min(max($0, 1), 10) / 7 } ?? 1
            return total + Int((Double(minutes) * intensityMultiplier * rpeMultiplier).rounded())
        }
    }

    private static func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
