import SwiftUI

enum FernletVoice: CaseIterable {
    case mealAnalysisFailed
    case workoutSuggestionUnavailable
    case journalAnalysisQueued
    case retryAvailable
    case aiUnavailable

    static func message(for voice: FernletVoice) -> String {
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

struct ScoringWeights: Equatable {
    var journalWeight: Double
    var mealWeight: Double
    var workoutWeight: Double
    var sleepWeight: Double
    var hydrationWeight: Double
    var hygieneWeight: Double

    init(
        journalWeight: Double,
        mealWeight: Double,
        workoutWeight: Double,
        sleepWeight: Double,
        hydrationWeight: Double,
        hygieneWeight: Double
    ) {
        self.journalWeight = journalWeight
        self.mealWeight = mealWeight
        self.workoutWeight = workoutWeight
        self.sleepWeight = sleepWeight
        self.hydrationWeight = hydrationWeight
        self.hygieneWeight = hygieneWeight
        assert(abs(total - 1.0) < 0.000_001, "scoring weights must sum to 1")
    }

    var total: Double {
        journalWeight + mealWeight + workoutWeight + sleepWeight + hydrationWeight + hygieneWeight
    }

    func adjustedForSickness(_ isSick: Bool) -> ScoringWeights {
        guard isSick else { return self }
        var adjusted = self
        let workout = workoutWeight
        adjusted.workoutWeight = 0
        adjusted.sleepWeight += workout * 0.5
        adjusted.hydrationWeight += workout * 0.3
        adjusted.hygieneWeight += workout * 0.2
        return adjusted
    }
}

enum GoalWeights {
    static func forGoal(_ goal: GoalType) -> ScoringWeights {
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

enum FernletScoring {
    static func tagScore(_ tag: FeelingTag?) -> Double {
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

    static func sleepScore(_ quality: SleepQuality?) -> Double {
        switch quality {
        case .great: 1
        case .good: 0.8
        case .ok: 0.6
        case .poor: 0.35
        case nil: 0.6
        }
    }

    static func hygieneScore(_ checked: Set<HygieneItem>) -> Double {
        hygieneScore(completedCount: checked.count, taskCount: HygieneItem.allCases.count)
    }

    static func hygieneScore(completedCount: Int, taskCount: Int) -> Double {
        guard taskCount > 0 else { return 0 }
        return min(Double(completedCount) / Double(taskCount), 1)
    }

    static func compute(
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
        micronutrientDataCoverageRatio: Double = 0
    ) -> Double {
        let baseMealScore = min(mealCount >= 3 ? 0.9 : mealCount >= 2 ? 0.75 : Double(mealCount) * 0.4, 1)
        let micronutrientModifier = micronutrientDataCoverageRatio >= 0.5 ? micronutrientModifier(from: nutrientGaps) : 0
        let mealScore = min(max(baseMealScore + micronutrientModifier, 0), 1)
        let workoutScore = workoutCount > 0 ? 0.9 : 0.45
        let target = max(isSick ? Int(ceil(Double(hydrationTarget) * 1.2)) : hydrationTarget, 1)
        let hydrationScore = min(Double(bottleCount) / Double(target), 1)
        let adjustedWeights = weights.adjustedForSickness(isSick)
        let careCompletedCount = completedPersonalCareTaskCount ?? hygiene.count
        let careScore = hygieneScore(completedCount: careCompletedCount, taskCount: hygieneTaskCount)
        return min(
            tagScore(journalTag) * adjustedWeights.journalWeight +
            mealScore * adjustedWeights.mealWeight +
            workoutScore * adjustedWeights.workoutWeight +
            sleepScore(sleepQuality) * adjustedWeights.sleepWeight +
            hydrationScore * adjustedWeights.hydrationWeight +
            careScore * adjustedWeights.hygieneWeight,
            1
        )
    }

    static func compute(for store: FernletStore) -> Double {
        compute(
            journalTag: store.day.journals.last?.tag,
            mealCount: store.day.meals.count,
            workoutCount: store.day.workouts.count,
            sleepQuality: store.day.sleep?.quality,
            bottleCount: store.day.bottleCount,
            hydrationTarget: store.settings.hydrationTarget,
            hygiene: store.day.hygiene,
            hygieneTaskCount: store.personalCareTasks.count,
            completedPersonalCareTaskCount: store.personalCareProgress().completed,
            weights: GoalWeights.forGoal(store.settings.selectedGoal),
            isSick: store.settings.isSick,
            nutrientGaps: dedupedNutrientGaps(from: store.derivedSignals.flatMap(\.nutrientGaps)),
            micronutrientDataCoverageRatio: micronutrientDataCoverageRatio(for: store.day.meals)
        )
    }

    /// The derived signals carry both a 7-day and a 14-day micronutrient record, each holding
    /// the full nutrient set. Flattening them would let `micronutrientModifier` count a single
    /// nutrient gap (or coverage) twice. Collapse to one entry per nutrient with a status-aware
    /// tie-break: a `.gap` in any window must survive (the modifier penalises persistent gaps,
    /// so a recent 7-day gap must not be masked by a 14-day `.covered`), and within the same
    /// status the longer window wins — both keep `windowDays >= 7` so the filter still matches.
    static func dedupedNutrientGaps(from gaps: [NutrientGap]) -> [NutrientGap] {
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

    static func micronutrientDataCoverageRatio(for meals: [Meal]) -> Double {
        guard meals.isEmpty == false else { return 0 }
        let mealsWithData = meals.filter { $0.micronutrientSnapshot.populatedFieldCount >= 5 }.count
        return Double(mealsWithData) / Double(meals.count)
    }

    static func micronutrientModifier(from nutrientGaps: [NutrientGap]) -> Double {
        let reliableSignals = nutrientGaps.filter { $0.dataCoverageRatio >= 0.5 }
        guard reliableSignals.isEmpty == false else { return 0 }
        let persistentGaps = reliableSignals.filter { $0.status == .gap && $0.windowDays >= 7 }
        if persistentGaps.isEmpty == false {
            return max(Double(persistentGaps.count) * -0.015, -0.05)
        }
        let covered = reliableSignals.filter { $0.status == .covered && $0.coverageRatio >= 0.5 }
        return min(Double(covered.count) * 0.01, 0.03)
    }

    static func state(for score: Double, isSick: Bool = false) -> CompanionState {
        if isSick { return .sick }
        if score >= 0.75 { return .thriving }
        if score >= 0.50 { return .okay }
        if score >= 0.25 { return .tired }
        return .resting
    }
}

enum MealParser {
    static func parse(_ description: String, fallbackType: MealType? = nil) -> Meal {
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

    static func classifyMealType(_ description: String, hour: Int = Calendar.current.component(.hour, from: .now)) -> MealType {
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

    static func mealName(from description: String) -> String {
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

enum WorkoutPlanner {
    static func suggestion(energy: WorkoutIntensity, goal: String, context: String, goals: [FitnessGoal]) -> Workout {
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

    static func defaultGoals(level: String, interests: String, constraints: String) -> [FitnessGoal] {
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

struct WorkoutSuggestion: Identifiable, Equatable {
    var id = UUID()
    var name: String
    var exercises: String
    var notes: String

    func workout(intensity: WorkoutIntensity) -> Workout {
        Workout(
            name: name,
            type: .mixed,
            mode: .strengthTraining,
            exercises: exercises,
            rpe: nil,
            notes: notes,
            duration: nil,
            intensity: intensity
        )
    }
}

struct WorkoutSuggestionLibrary {
    static func suggestions(for goal: GoalType, intensity: WorkoutIntensity) -> [WorkoutSuggestion] {
        let base = templates[goal] ?? templates[.wellness] ?? []
        let matching = base.filter { $0.intensity == intensity }.map(\.suggestion)
        if matching.isEmpty {
            return base.map(\.suggestion)
        }
        return matching
    }

    private static let templates: [GoalType: [(intensity: WorkoutIntensity, suggestion: WorkoutSuggestion)]] = [
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

enum FernletDate {
    private static let dayKeyFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func dayKey(for date: Date) -> String {
        dayKeyFormatter.string(from: date)
    }

    static func date(fromDayKey key: String) -> Date? {
        dayKeyFormatter.date(from: key)
    }

    static func dayKeys(in interval: DateInterval, calendar: Calendar = .current) -> [String] {
        var keys: [String] = []
        var day = calendar.startOfDay(for: interval.start)
        let end = calendar.startOfDay(for: interval.end)
        while day <= end {
            keys.append(dayKey(for: day))
            day = calendar.date(byAdding: .day, value: 1, to: day) ?? day.addingTimeInterval(86_400)
        }
        return keys
    }

    static func niceDate(for date: Date = .now) -> String {
        date.formatted(.dateTime.weekday(.wide).month(.wide).day())
    }

    static func shortDate(for date: Date) -> String {
        date.formatted(.dateTime.month(.abbreviated).day())
    }
}

// MARK: - Screens
