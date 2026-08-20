//
//  DerivedSignalFactory.swift
//  Fernlet
//
//  Computes the rolling derived-signal window from stored day pairs.
//

import Foundation
import FernletDomainModel
import FernletScoring

/// The deterministic engine that computes the rolling derived-signal window — mood, energy,
/// eating pattern, training progression, intensity readiness, and micronutrient gaps — from
/// stored day pairs.
///
/// A stateless namespace enum: every signal is a pure heuristic over logged behavior (journal
/// tags, sleep, meals, workouts) plus optional HealthKit HR/HRV recovery context, so results are
/// reproducible with no AI involvement. `DerivedSignalsRebuilder` (in `StoreCore`) is the sole
/// production caller; it feeds a bounded oldest-first window of at most
/// ``FernletLimits/signalWindowDays`` days. Each run yields exactly seven ``DerivedSignalRecord``
/// values whose `signalName` and `value` strings are both stable English tokens: `signalName`
/// (`"moodTrend"`, `"energyTrend"`, …) is how the app finds a signal, and `value` is the short
/// lowercase phrase (`"needs gentleness"`, `"ready for hard"`, `"2 possible gaps"`) the AI-context
/// layer forwards verbatim and the app's gates compare against — see the freeze note below before
/// editing either. The records are recomputed on demand and held in store state, never persisted
/// in the ``LocalFernletDatabase`` blob.
/// Nonisolated and Sendable-safe by virtue of having no state.
///
/// ## `DerivedSignalRecord.value` is a FROZEN ENGLISH TOKEN — do not localize, do not reword
///
/// Every `value` string this file emits — `"insufficient data"`, `"needs gentleness"`,
/// `"improving"` / `"declining"` / `"steady"`, `"low"` / `"rising"` / `"dipping"`, `"light"` /
/// `"protein-forward"` / `"inconsistent"` / `"consistent"`, `"ready for light"` /
/// `"ready for moderate"` / `"ready for hard"`, `"building"` / `"deloading"`, and the counted
/// `"N possible gap(s)"` / `"N covered"` forms — reads like a phrase written for a person, and it
/// is not. It is a logic token. Six gates in the app target compare these literals by exact string
/// equality, and every one of them is a behavior switch, not a label:
///
/// * `LaunchPreparationService.foundationModelsThought` filters on `value != "insufficient data"`
///   and returns `nil` when nothing survives — this decides whether the AI runs AT ALL.
/// * `GentleOffers` gates the entire gentle-offer feature on `moodTrendValue == "needs gentleness"`.
///   That comparison is the feature's sole trigger; there is no second path in.
/// * `AmbientCards` reads the same `moodTrend` value for its care-card trigger.
/// * `FernletStore` maps `"ready for hard"` to the `.hard` intensity recommendation.
/// * `HomeView` and `LaunchPreparationService` each pick their ambient line by matching
///   `"low"` / `"needs gentleness"` / `"ready for hard"`.
///
/// So `String(localized:)` here, or an innocent copy edit ("needs gentleness" → "be gentle"), does
/// not change a label: it turns six features off in six different places, with no compiler error,
/// no test failure that names the cause, and no runtime log. The user simply stops being offered
/// gentleness and the companion stops thinking.
///
/// The display layer belongs in the app, NOT here: the app target owns the mapping from these
/// tokens to the localized sentence a person reads (another agent is adding it alongside
/// `HomeView`'s existing `signalName`→title switch, which is already exactly this shape — a stable
/// token in, a human string out). Adding a signal means adding a token here and a case there; it
/// never means translating a token in place.
///
/// One token deserves singling out because it will tempt a localization pass hardest: the
/// micronutrient value is built as `"\(gapCount) possible gap\(gapCount == 1 ? "" : "s")"`, which
/// hard-codes English pluralization. That is correct FOR A TOKEN — the count has to be recoverable
/// and the string has to be identical on every device. The plural rules that actually matter (and
/// there are more than two of them in several target languages) belong to the app's display layer,
/// which should re-derive the count from the structured `nutrientGaps` the record already carries
/// (`nutrientGaps.filter { $0.status == .gap }.count` — the array holds covered nutrients too, so a
/// bare `.count` is the wrong number) and format it with a real plural-aware localized string,
/// rather than parsing digits back out of the token.
public enum DerivedSignalFactory {
    /// Computes the full set of seven signal records from an oldest-first day window.
    ///
    /// - Parameters:
    ///   - days: `(dateKey, day)` pairs, oldest-first, at most ``FernletLimits/signalWindowDays``
    ///     entries (asserted in debug).
    ///   - todayKey: The current day key; required non-empty, used only for the debug assertion.
    /// - Returns: The seven records (mood, energy, eating, progression, readiness, and the 7- and
    ///   14-day micronutrient windows), or an empty array when the window has no days at all.
    ///   Sparse data never fails — signals degrade to an "insufficient data" value instead.
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

    /// Builds the `moodTrend` signal from daily journal-tag averages; a recent low day forces
    /// "needs gentleness" before any trend comparison.
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

    /// Builds the `energyTrend` signal from the blended sleep/mood/training-load daily energy
    /// score; a low 3-day recent average reports "low" before any trend comparison.
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

    /// Builds the `eatingPattern` signal — light / protein-forward / inconsistent / consistent —
    /// from meal counts, recent skipped days, and per-day protein totals.
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

    /// Builds the `intensityReadiness` signal — the light/moderate/hard training recommendation —
    /// from the last 3 days' load, energy, fueling, and (when wearable data exists) HR/HRV recovery.
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

    /// Builds the `progressionTrend` signal — building / deloading / steady — by comparing total
    /// training load between the older and newer halves of the window.
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

    /// Builds a `micronutrientGaps{7,14}Day` signal by delegating gap analysis to
    /// `MicronutrientGapAnalyzer` (in `FernletScoring`); the structured gaps ride along in
    /// ``DerivedSignalRecord/nutrientGaps``.
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

    /// One averaged 0–1 mood score per day that has journal entries (days without journals are
    /// omitted, not zeroed).
    private static func dailyMoodScores(from days: [(String, FernletDay)]) -> [Double] {
        days.compactMap { _, day in
            let scores = day.journals.prefix(FernletLimits.maxJournalsPerDay).map { $0.tag.moodScore }
            guard scores.isEmpty == false else { return nil }
            return average(scores)
        }
    }

    /// One blended 0–1 energy score per day from whichever components exist: sleep score, mood
    /// average, and an inverse training-load penalty. Days with none of the three are omitted.
    private static func dailyEnergyScores(from days: [(String, FernletDay)]) -> [Double] {
        days.compactMap { _, day in
            var components: [Double] = []
            if let sleep = day.sleep {
                components.append(sleepEnergyScore(sleep, healthSleepHours: day.healthContext?.body?.sleepHours))
            }
            let journalScores = day.journals.prefix(FernletLimits.maxJournalsPerDay).map { $0.tag.moodScore }
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

    /// Shared half-window trend comparison: older half vs newer half, with a ±0.12 dead band
    /// mapped to the caller-supplied rising/falling/steady phrases.
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

    /// 0–1 sleep-energy score: 60% hours (normalized against 8h) + 40% subjective quality,
    /// falling back to quality alone when no duration is known.
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

    /// Sums a day's training load in intensity- and RPE-weighted minutes (capped at
    /// ``FernletLimits/maxWorkoutsPerDay`` workouts; a missing duration counts as 30 minutes).
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

    /// Arithmetic mean, with an empty input defined as 0 rather than a trap.
    private static func average(_ values: [Double]) -> Double {
        guard values.isEmpty == false else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
