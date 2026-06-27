import Foundation
import FernletFoundation
import FernletDomainModel

public enum FernletVoice: CaseIterable, Sendable {
    case mealAnalysisFailed
    case workoutSuggestionUnavailable
    case journalAnalysisQueued
    case retryAvailable
    case aiUnavailable

    public static func message(for voice: FernletVoice) -> String {
        switch voice {
        case .mealAnalysisFailed:
            "I saved this with a local estimate. We can give it another look later."
        case .workoutSuggestionUnavailable:
            "I made a simple local option for today. Keep it gentle and useful."
        case .journalAnalysisQueued:
            "Your journal is saved. I will look for patterns when the helper is awake again."
        case .retryAvailable:
            "A few saved notes can be revisited when you are ready."
        case .aiUnavailable:
            "The quiet helper is off right now, so Fernlet will use local fallbacks."
        }
    }
}

extension ScoringWeights {
    /// Gentle period-phase leniency: on a personally-harder phase, shift a *small* slice (30%) of the
    /// workout demand toward restorative sleep/hydration, so a lower-movement day during a hard phase is
    /// not penalised as sharply. Much milder than `adjustedForSickness` (which zeroes workout entirely).
    /// `.none` is the identity, preserving byte-for-byte the period-unaware weight vector. Total stays 1.
    ///
    /// Lives here (app layer) rather than on the carved-down `ScoringWeights` value type because it
    /// depends on `PeriodSignalStrength`, which sits above the domain layer (period-module egress).
    public func adjustedForPeriod(_ leniency: PeriodSignalStrength) -> ScoringWeights {
        guard leniency == .suggested else { return self }
        var adjusted = self
        let shifted = workoutWeight * 0.3
        adjusted.workoutWeight -= shifted
        adjusted.sleepWeight += shifted * 0.6
        adjusted.hydrationWeight += shifted * 0.4
        return adjusted
    }
}

public enum GoalWeights {
    public static func forGoal(_ goal: GoalType) -> ScoringWeights {
        let weights: ScoringWeights
        switch goal {
        case .wellness:
            weights = ScoringWeights(journalWeight: 0.18, mealWeight: 0.22, workoutWeight: 0.18, sleepWeight: 0.22, hydrationWeight: 0.12, hygieneWeight: 0.08)
        case .strength:
            weights = ScoringWeights(journalWeight: 0.10, mealWeight: 0.28, workoutWeight: 0.28, sleepWeight: 0.18, hydrationWeight: 0.12, hygieneWeight: 0.04)
        case .weightManagement:
            weights = ScoringWeights(journalWeight: 0.12, mealWeight: 0.30, workoutWeight: 0.22, sleepWeight: 0.18, hydrationWeight: 0.14, hygieneWeight: 0.04)
        case .mentalHealth:
            weights = ScoringWeights(journalWeight: 0.30, mealWeight: 0.18, workoutWeight: 0.16, sleepWeight: 0.22, hydrationWeight: 0.10, hygieneWeight: 0.04)
        case .recovery:
            weights = ScoringWeights(journalWeight: 0.18, mealWeight: 0.20, workoutWeight: 0.08, sleepWeight: 0.32, hydrationWeight: 0.16, hygieneWeight: 0.06)
        case .exploring:
            weights = ScoringWeights(journalWeight: 0.18, mealWeight: 0.22, workoutWeight: 0.18, sleepWeight: 0.22, hydrationWeight: 0.12, hygieneWeight: 0.08)
        case .sportsPrep:
            weights = ScoringWeights(journalWeight: 0.10, mealWeight: 0.26, workoutWeight: 0.30, sleepWeight: 0.18, hydrationWeight: 0.12, hygieneWeight: 0.04)
        }
        assert(abs(weights.total - 1.0) < 0.000_001, "scoring weights must sum to 1")
        return weights
    }
}

/// The overall score plus the per-component sub-scores and the exact (sickness-adjusted)
/// weight vector that produced it. Persisted into `DailyHealthScore` for later inspection.
public struct ScoreBreakdown: Equatable {
    public var overall: Double
    public var components: [String: Double]
    public var appliedWeights: ScoringWeights

    public init(overall: Double, components: [String: Double], appliedWeights: ScoringWeights) {
        self.overall = overall
        self.components = components
        self.appliedWeights = appliedWeights
    }
}

public enum FernletScoring {
    public static func tagScore(_ tag: FeelingTag?) -> Double {
        switch tag {
        case .bright: 1
        case .good: 0.85
        case .neutral: 0.6
        case .quiet: 0.55
        case .tired: 0.4
        case .hard: 0.3
        case nil: 0.55
        }
    }

    /// Maps a self-reported sleep quality to a 0–1 score, optionally refined with HealthKit
    /// signals. With only `quality` supplied the result is identical to the original enum mapping
    /// (so existing callers and snapshots are unaffected). When `sleepHours` is present the score
    /// blends the subjective quality with an objective duration factor; when stage data is present
    /// a small bonus/penalty is applied for deep/REM proportions.
    public static func sleepScore(_ quality: SleepQuality?, sleepHours: Double? = nil, stages: SleepStagesData? = nil) -> Double {
        let base: Double
        switch quality {
        case .great: base = 1
        case .good: base = 0.8
        case .ok: base = 0.6
        case .poor: base = 0.35
        case nil: base = 0.6
        }
        guard sleepHours != nil || (stages?.hasStageBreakdown ?? false) else { return base }

        var score = base
        if let sleepHours {
            // 70% subjective quality, 30% objective duration — keeps the user's felt experience
            // primary while letting an unusually short/long night move the needle.
            score = base * 0.7 + sleepDurationFactor(sleepHours) * 0.3
        }
        if let bonus = sleepStageQualityBonus(stages) {
            score += bonus
        }
        return min(max(score, 0), 1)
    }

    /// Objective duration quality, 0–1. 7–9 h is ideal; short sleep is penalised more steeply than
    /// long sleep.
    public static func sleepDurationFactor(_ hours: Double) -> Double {
        if hours >= 7 && hours <= 9 { return 1 }
        if hours >= 6 && hours < 7 { return 0.85 }
        if hours >= 5 && hours < 6 { return 0.65 }
        if hours < 5 { return max(0.3, hours / 5 * 0.45) }
        if hours > 9 && hours <= 10 { return 0.9 }
        return 0.75 // > 10 h
    }

    /// Small ±bonus from sleep-stage proportions. Returns nil when there is no usable stage
    /// breakdown. Healthy adult reference: deep ≈ 13–23 %, REM ≈ 20–25 % of total asleep time.
    public static func sleepStageQualityBonus(_ stages: SleepStagesData?) -> Double? {
        guard let stages, stages.hasStageBreakdown,
              let total = stages.totalAsleepMinutes, total > 0 else { return nil }
        let deepPct = (stages.deepMinutes ?? 0) / total
        let remPct = (stages.remMinutes ?? 0) / total
        var bonus = 0.0
        if deepPct >= 0.13 { bonus += 0.03 } else if deepPct < 0.08 { bonus -= 0.03 }
        if remPct >= 0.20 { bonus += 0.03 } else if remPct < 0.13 { bonus -= 0.03 }
        return bonus
    }

    /// Exercise/movement quality, 0–1. With no HealthKit activity supplied this reproduces the
    /// original `workoutCount > 0 ? 0.9 : 0.45` behaviour exactly. When activity is present, a
    /// genuinely active day lifts the score — most notably so that days with real movement but no
    /// manually-logged workout are no longer flattened to 0.45.
    public static func exerciseIntensityScore(
        workoutCount: Int,
        steps: Int? = nil,
        activeEnergyKilocalories: Double? = nil,
        exerciseMinutes: Double? = nil
    ) -> Double {
        let base = workoutCount > 0 ? 0.9 : 0.45
        guard steps != nil || activeEnergyKilocalories != nil || exerciseMinutes != nil else { return base }

        let steps = steps ?? 0
        let energy = activeEnergyKilocalories ?? 0
        let exercise = exerciseMinutes ?? 0
        let bonus: Double
        if steps >= 10_000 || energy >= 500 || exercise >= 30 {
            bonus = workoutCount > 0 ? 0.1 : 0.25
        } else if steps >= 6_000 || energy >= 250 || exercise >= 15 {
            bonus = workoutCount > 0 ? 0.05 : 0.15
        } else {
            bonus = 0
        }
        return min(max(base + bonus, 0), 1)
    }

    /// Autonomic recovery readiness, 0–1, synthesised from resting HR + HRV and sleep. Returns nil
    /// when neither HR nor HRV is available (so callers can cleanly fall back to behaviour-only
    /// signals). Higher HRV and lower resting HR indicate better recovery.
    public static func recoveryReadinessScore(
        restingHeartRateBPM: Double?,
        heartRateVariabilityMS: Double?,
        sleepQuality: SleepQuality?,
        sleepHours: Double?
    ) -> Double? {
        guard restingHeartRateBPM != nil || heartRateVariabilityMS != nil else { return nil }
        var components: [Double] = []
        if let hrv = heartRateVariabilityMS {
            // ~10 ms → 0, ~80 ms → 1 (clamped). SDNN overnight is a coarse recovery proxy.
            components.append(min(max((hrv - 10) / 70, 0), 1))
        }
        if let rhr = restingHeartRateBPM {
            // ~45 bpm → 1, ~95 bpm → 0 (clamped).
            components.append(min(max(1 - (rhr - 45) / 50, 0), 1))
        }
        components.append(sleepScore(sleepQuality, sleepHours: sleepHours))
        guard components.isEmpty == false else { return nil }
        return components.reduce(0, +) / Double(components.count)
    }

    public static func hygieneScore(_ checked: Set<HygieneItem>) -> Double {
        hygieneScore(completedCount: checked.count, taskCount: HygieneItem.allCases.count)
    }

    public static func hygieneScore(completedCount: Int, taskCount: Int) -> Double {
        guard taskCount > 0 else { return 0 }
        return min(Double(completedCount) / Double(taskCount), 1)
    }

    public static func compute(
        journalTag: FeelingTag?,
        mealCount: Int,
        workoutCount: Int,
        sleepQuality: SleepQuality?,
        bottleCount: Int,
        hydrationTarget: Int,
        hygiene: Set<HygieneItem>,
        hygieneTaskCount: Int = HygieneItem.allCases.count,
        completedPersonalCareTaskCount: Int? = nil,
        weights: ScoringWeights,
        isSick: Bool = false,
        nutrientGaps: [NutrientGap] = [],
        micronutrientDataCoverageRatio: Double = 0,
        sleepHours: Double? = nil,
        sleepStages: SleepStagesData? = nil,
        activitySteps: Int? = nil,
        activeEnergyKilocalories: Double? = nil,
        exerciseMinutes: Double? = nil,
        periodAdjustment: PeriodScoringAdjustment = .none
    ) -> Double {
        computeBreakdown(
            journalTag: journalTag,
            mealCount: mealCount,
            workoutCount: workoutCount,
            sleepQuality: sleepQuality,
            bottleCount: bottleCount,
            hydrationTarget: hydrationTarget,
            hygiene: hygiene,
            hygieneTaskCount: hygieneTaskCount,
            completedPersonalCareTaskCount: completedPersonalCareTaskCount,
            weights: weights,
            isSick: isSick,
            nutrientGaps: nutrientGaps,
            micronutrientDataCoverageRatio: micronutrientDataCoverageRatio,
            sleepHours: sleepHours,
            sleepStages: sleepStages,
            activitySteps: activitySteps,
            activeEnergyKilocalories: activeEnergyKilocalories,
            exerciseMinutes: exerciseMinutes,
            periodAdjustment: periodAdjustment
        ).overall
    }

    /// Computes the overall score along with the per-component sub-scores and the applied
    /// (sickness-adjusted) weight vector. `compute` returns only `.overall`; callers that need
    /// to persist the breakdown (`DailyHealthScore`) use this directly.
    public static func computeBreakdown(
        journalTag: FeelingTag?,
        mealCount: Int,
        workoutCount: Int,
        sleepQuality: SleepQuality?,
        bottleCount: Int,
        hydrationTarget: Int,
        hygiene: Set<HygieneItem>,
        hygieneTaskCount: Int = HygieneItem.allCases.count,
        completedPersonalCareTaskCount: Int? = nil,
        weights: ScoringWeights,
        isSick: Bool = false,
        nutrientGaps: [NutrientGap] = [],
        micronutrientDataCoverageRatio: Double = 0,
        sleepHours: Double? = nil,
        sleepStages: SleepStagesData? = nil,
        activitySteps: Int? = nil,
        activeEnergyKilocalories: Double? = nil,
        exerciseMinutes: Double? = nil,
        periodAdjustment: PeriodScoringAdjustment = .none
    ) -> ScoreBreakdown {
        let baseMealScore = min(mealCount >= 3 ? 0.9 : mealCount >= 2 ? 0.75 : Double(mealCount) * 0.4, 1)
        let micronutrientModifier = micronutrientDataCoverageRatio >= 0.5 ? micronutrientModifier(from: nutrientGaps) : 0
        let mealScore = min(max(baseMealScore + micronutrientModifier, 0), 1)
        let workoutScore = exerciseIntensityScore(
            workoutCount: workoutCount,
            steps: activitySteps,
            activeEnergyKilocalories: activeEnergyKilocalories,
            exerciseMinutes: exerciseMinutes
        )
        // Hydration target: the sickness multiplier (×1.2) and the period relief (×0.85, a *softer*
        // expectation on a personally-harder phase) compose. With `.none` relief the target is
        // byte-identical to the period-unaware result.
        let sicknessTarget = isSick ? Int(ceil(Double(hydrationTarget) * 1.2)) : hydrationTarget
        let reliefTarget = periodAdjustment.hydrationRelief == .suggested
            ? Int((Double(sicknessTarget) * 0.85).rounded())
            : sicknessTarget
        let target = max(reliefTarget, 1)
        let hydrationScore = min(Double(bottleCount) / Double(target), 1)
        let adjustedWeights = weights.adjustedForSickness(isSick).adjustedForPeriod(periodAdjustment.leniency)
        let careCompletedCount = completedPersonalCareTaskCount ?? hygiene.count
        let careScore = hygieneScore(completedCount: careCompletedCount, taskCount: hygieneTaskCount)
        let journalScore = tagScore(journalTag)
        let sleepScoreValue = sleepScore(sleepQuality, sleepHours: sleepHours, stages: sleepStages)
        let overall = min(
            journalScore * adjustedWeights.journalWeight +
            mealScore * adjustedWeights.mealWeight +
            workoutScore * adjustedWeights.workoutWeight +
            sleepScoreValue * adjustedWeights.sleepWeight +
            hydrationScore * adjustedWeights.hydrationWeight +
            careScore * adjustedWeights.hygieneWeight,
            1
        )
        return ScoreBreakdown(
            overall: overall,
            components: [
                "journal": journalScore,
                "meal": mealScore,
                "workout": workoutScore,
                "sleep": sleepScoreValue,
                "hydration": hydrationScore,
                "hygiene": careScore
            ],
            appliedWeights: adjustedWeights
        )
    }

    /// The derived signals carry both a 7-day and a 14-day micronutrient record, each holding
    /// the full nutrient set. Flattening them would let `micronutrientModifier` count a single
    /// nutrient gap (or coverage) twice. Collapse to one entry per nutrient with a status-aware
    /// tie-break: a `.gap` in any window must survive (the modifier penalises persistent gaps,
    /// so a recent 7-day gap must not be masked by a 14-day `.covered`), and within the same
    /// status the longer window wins — both keep `windowDays >= 7` so the filter still matches.
    public static func dedupedNutrientGaps(from gaps: [NutrientGap]) -> [NutrientGap] {
        var byKey: [String: NutrientGap] = [:]
        for gap in gaps {
            guard let existing = byKey[gap.nutrientKey] else {
                byKey[gap.nutrientKey] = gap
                continue
            }
            if preferNutrientGap(gap, over: existing) {
                byKey[gap.nutrientKey] = gap
            }
        }
        return Array(byKey.values)
    }

    private static func preferNutrientGap(_ candidate: NutrientGap, over existing: NutrientGap) -> Bool {
        if candidate.status == .gap && existing.status != .gap { return true }
        if candidate.status != .gap && existing.status == .gap { return false }
        return candidate.windowDays > existing.windowDays
    }

    public static func micronutrientDataCoverageRatio(for meals: [Meal]) -> Double {
        MicronutrientGapAnalyzer.micronutrientDataCoverageRatio(for: meals)
    }

    public static func micronutrientModifier(from nutrientGaps: [NutrientGap]) -> Double {
        let reliableSignals = nutrientGaps.filter { $0.dataCoverageRatio >= 0.5 }
        guard reliableSignals.isEmpty == false else { return 0 }
        let persistentGaps = reliableSignals.filter { $0.status == .gap && $0.windowDays >= 7 }
        if persistentGaps.isEmpty == false {
            return max(Double(persistentGaps.count) * -0.015, -0.05)
        }
        let covered = reliableSignals.filter { $0.status == .covered && $0.coverageRatio >= 0.5 }
        return min(Double(covered.count) * 0.01, 0.03)
    }

    public static func state(for score: Double, isSick: Bool = false) -> CompanionState {
        if isSick { return .sick }
        if score >= 0.75 { return .thriving }
        if score >= 0.50 { return .okay }
        if score >= 0.25 { return .tired }
        return .resting
    }
}

public enum MealParser {
    public static func parse(_ description: String, fallbackType: MealType? = nil) -> Meal {
        let type = fallbackType ?? classifyMealType(description)
        let macros = estimateMacros(description, type: type)
        return Meal(
            name: mealName(from: description),
            mealType: type,
            macros: macros,
            quality: macros.protein >= 25 ? .good : .ok,
            confidence: "Estimated",
            note: "Estimated locally from the description. Add API lookup later for branded meals.",
            source: MealLogSource.manual
        )
    }

    public static func classifyMealType(_ description: String, hour: Int = Calendar.current.component(.hour, from: .now)) -> MealType {
        let lower = description.lowercased()
        if lower.contains("breakfast") || lower.contains("oatmeal") || lower.contains("pancake") || lower.contains("waffle") { return .breakfast }
        if lower.contains("lunch") || lower.contains("sandwich") { return .lunch }
        if lower.contains("dinner") || lower.contains("supper") { return .dinner }
        if lower.contains("pre-workout") || lower.contains("before gym") || lower.contains("before lift") { return .preWorkout }
        if lower.contains("post-workout") || lower.contains("after gym") || lower.contains("after lift") { return .postWorkout }
        if lower.contains("snack") || lower.contains("handful") { return .snack }
        if hour < 10 { return .breakfast }
        if hour < 14 { return .lunch }
        if hour < 17 { return .snack }
        return .dinner
    }

    public static func mealName(from description: String) -> String {
        let words = description
            .replacingOccurrences(of: "from", with: " ")
            .split(separator: " ")
            .prefix(5)
            .map(String.init)
        let name = words.joined(separator: " ").trimmingCharacters(in: .punctuationCharacters)
        return name.isEmpty ? "Meal" : name.capitalized
    }

    private static func estimateMacros(_ description: String, type: MealType) -> Macros {
        let lower = description.lowercased()
        var protein = 18
        var carbs = 35
        var fat = 14

        if lower.contains("chicken") || lower.contains("turkey") || lower.contains("protein") || lower.contains("steak") || lower.contains("fish") {
            protein += 20
            fat += 4
        }
        if lower.contains("egg") || lower.contains("yogurt") || lower.contains("tofu") {
            protein += 12
            fat += 6
        }
        if lower.contains("rice") || lower.contains("pasta") || lower.contains("bread") || lower.contains("toast") || lower.contains("oat") || lower.contains("tortilla") {
            carbs += 35
        }
        if lower.contains("salad") || lower.contains("vegetable") || lower.contains("greens") {
            carbs = max(18, carbs - 12)
            fat = max(8, fat - 4)
        }
        if lower.contains("fried") || lower.contains("burger") || lower.contains("pizza") || lower.contains("taco") || lower.contains("cheese") {
            fat += 16
            carbs += 18
        }
        if type == .snack {
            protein = max(8, protein - 8)
            carbs = max(12, carbs - 12)
            fat = max(6, fat - 6)
        }

        return Macros(protein: min(protein, 90), carbs: min(carbs, 160), fat: min(fat, 80))
    }
}

public enum WorkoutPlanner {
    public static func suggestion(energy: WorkoutIntensity, goal: String, context: String, goals: [FitnessGoal]) -> Workout {
        let alignedGoal = goals.first?.goal ?? goal
        let duration = energy == .light ? 25 : energy == .moderate ? 40 : 55
        let exercises: String
        switch energy {
        case .light:
            exercises = "Easy walk - 20 min\nMobility flow - 5 min\nBreathing reset - 2 min"
        case .moderate:
            exercises = "Goblet squat - 3 x 8\nDB row - 3 x 10\nIncline push-up - 3 x 8\nWalk - 10 min"
        case .hard:
            exercises = "Squat or leg press - 4 x 6\nBench or push-up - 4 x 8\nRow - 4 x 10\nCarry - 4 rounds"
        }
        let note = context.isEmpty ? "Built around \(alignedGoal.lowercased())." : "Built around \(alignedGoal.lowercased()) with: \(context)."
        return Workout(name: "Suggested \(energy.rawValue.capitalized)", type: .mixed, exercises: exercises, rpe: nil, notes: note, duration: duration, intensity: energy)
    }

    public static func defaultGoals(level: String, interests: String, constraints: String) -> [FitnessGoal] {
        let focus = interests.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "general strength" : interests
        let limits = constraints.trimmingCharacters(in: .whitespacesAndNewlines)
        let weekly = limits.isEmpty ? "Three flexible sessions with one easier day between harder efforts." : "Three flexible sessions shaped around: \(limits)."
        return [
            FitnessGoal(type: .strength, goal: "Complete 3 \(focus) sessions in a week", timeframe: "1 week", metric: "sessions completed", weeklyStructure: weekly),
            FitnessGoal(type: .wellness, goal: "Keep most sessions at a sustainable effort", timeframe: "4 weeks", metric: "RPE mostly 6-8", weeklyStructure: weekly),
            FitnessGoal(type: .exploring, goal: "Build a repeatable \(focus) rhythm", timeframe: "3 months", metric: "10 consistent weeks", milestones: ["week 4 check-in", "week 8 adjust"], weeklyStructure: weekly)
        ]
    }
}

public struct WorkoutSuggestionLibrary {
    public static func suggestions(for goal: GoalType, intensity: WorkoutIntensity) -> [WorkoutSuggestion] {
        let base = templates[goal] ?? templates[.wellness] ?? []
        let matching = base.filter { $0.intensity == intensity }.map(\.suggestion)
        if matching.isEmpty {
            return base.map(\.suggestion)
        }
        return matching
    }

    // Read-only constant lookup table; its element type (`WorkoutSuggestion` from FernletDomainModel) is
    // not `Sendable`, so under the target's nonisolated default this immutable static needs the unsafe
    // opt-out. It is never mutated, so the opt-out is sound.
    nonisolated(unsafe) private static let templates: [GoalType: [(intensity: WorkoutIntensity, suggestion: WorkoutSuggestion)]] = [
        .wellness: [
            (.light, WorkoutSuggestion(name: "Steady Care Walk", exercises: "Easy walk - 20 min\nGentle stretch - 5 min", notes: "A simple local fallback for a balanced day.")),
            (.moderate, WorkoutSuggestion(name: "Balanced Strength Circuit", exercises: "Goblet squat - 3 x 8\nDB row - 3 x 10\nIncline push-up - 3 x 8", notes: "Enough movement to feel grounded."))
        ],
        .strength: [
            (.moderate, WorkoutSuggestion(name: "Strength Base", exercises: "Squat or leg press - 4 x 6\nBench or push-up - 4 x 8\nRow - 4 x 10", notes: "A repeatable strength template.")),
            (.hard, WorkoutSuggestion(name: "Hard Strength Day", exercises: "Main lift - 5 x 5\nAccessory pull - 4 x 8\nCarry - 4 rounds", notes: "Use only if energy is genuinely there."))
        ],
        .weightManagement: [
            (.light, WorkoutSuggestion(name: "Low Friction Walk", exercises: "Brisk walk - 25 min\nMobility - 5 min", notes: "Steady movement without optimization pressure.")),
            (.moderate, WorkoutSuggestion(name: "Move And Strength", exercises: "Step-up - 3 x 10\nDB row - 3 x 10\nWalk - 12 min", notes: "A practical mixed session."))
        ],
        .mentalHealth: [
            (.light, WorkoutSuggestion(name: "Mood Reset", exercises: "Outdoor walk - 15 min\nBreathing reset - 3 min\nNeck and shoulders - 5 min", notes: "Start easy and let it count.")),
            (.moderate, WorkoutSuggestion(name: "Steady Mind Circuit", exercises: "Bike or walk - 10 min\nBodyweight circuit - 3 rounds\nCooldown - 5 min", notes: "Predictable movement, low decision load."))
        ],
        .recovery: [
            (.light, WorkoutSuggestion(name: "Recovery Flow", exercises: "Gentle mobility - 12 min\nEasy walk - 10 min\nBreathing - 3 min", notes: "Recovery still counts as care.")),
            (.moderate, WorkoutSuggestion(name: "Soft Rebuild", exercises: "Light row - 3 x 12\nGlute bridge - 3 x 10\nWalk - 10 min", notes: "Keep the ceiling low today."))
        ],
        .exploring: [
            (.light, WorkoutSuggestion(name: "Try Something Small", exercises: "Walk a new route - 15 min\nPick one mobility drill - 5 min", notes: "Gather information, not perfection.")),
            (.hard, WorkoutSuggestion(name: "Curious Challenge", exercises: "Choose one main lift - 4 x 6\nChoose one carry - 4 rounds\nCooldown - 5 min", notes: "A contained experiment for a high-energy day."))
        ]
    ]
}

// MARK: - Screens
