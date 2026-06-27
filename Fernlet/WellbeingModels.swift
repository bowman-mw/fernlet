// WellbeingModels.swift
// Split out of Models.swift (SPM carve-up §5c). Day, health-context, journal, sleep, hygiene, goals, and daily-score models.

import Foundation

struct FernletDay: Codable {
    var date: String
    var meals: [Meal]
    var workouts: [Workout]
    var plannedWorkouts: [PlannedWorkout]
    var journals: [JournalEntry]
    var sleep: SleepLog?
    var bottleCount: Int
    var hygiene: Set<HygieneItem>
    var completedPersonalCareTaskIDs: Set<String>
    var healthContext: HealthDailyContext?

    init(
        date: String,
        meals: [Meal] = [],
        workouts: [Workout] = [],
        plannedWorkouts: [PlannedWorkout] = [],
        journals: [JournalEntry] = [],
        sleep: SleepLog? = nil,
        bottleCount: Int = 0,
        hygiene: Set<HygieneItem> = [],
        completedPersonalCareTaskIDs: Set<String>? = nil,
        healthContext: HealthDailyContext? = nil
    ) {
        self.date = date
        self.meals = meals
        self.workouts = workouts
        self.plannedWorkouts = plannedWorkouts
        self.journals = journals
        self.sleep = sleep
        self.bottleCount = bottleCount
        self.hygiene = hygiene
        self.completedPersonalCareTaskIDs = completedPersonalCareTaskIDs ?? Set(hygiene.map(\.rawValue))
        self.healthContext = healthContext
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        date = try container.decode(String.self, forKey: .date)
        meals = try container.decodeIfPresent([Meal].self, forKey: .meals) ?? []
        workouts = try container.decodeIfPresent([Workout].self, forKey: .workouts) ?? []
        plannedWorkouts = try container.decodeIfPresent([PlannedWorkout].self, forKey: .plannedWorkouts) ?? []
        journals = try container.decodeIfPresent([JournalEntry].self, forKey: .journals) ?? []
        sleep = try container.decodeIfPresent(SleepLog.self, forKey: .sleep)
        bottleCount = try container.decodeIfPresent(Int.self, forKey: .bottleCount) ?? 0
        hygiene = try container.decodeIfPresent(Set<HygieneItem>.self, forKey: .hygiene) ?? []
        completedPersonalCareTaskIDs = try container.decodeIfPresent(Set<String>.self, forKey: .completedPersonalCareTaskIDs) ?? Set(hygiene.map(\.rawValue))
        healthContext = try container.decodeIfPresent(HealthDailyContext.self, forKey: .healthContext)
    }
}

struct HealthDailyContext: Codable, Equatable {
    var syncedAt = Date()
    var activity: HealthActivitySummary?
    var body: HealthBodyContext?
    var cycle: HealthCycleContext?
    var mindfulness: HealthMindfulnessContext?
    var intimate: HealthIntimateContext?

    mutating func merge(_ other: HealthDailyContext) {
        syncedAt = other.syncedAt
        activity = other.activity ?? activity
        body = other.body ?? body
        cycle = other.cycle ?? cycle
        mindfulness = other.mindfulness ?? mindfulness
        intimate = other.intimate ?? intimate
    }
}

struct HealthActivitySummary: Codable, Equatable {
    var steps: Int?
    var activeEnergyKilocalories: Double?
    var exerciseMinutes: Double?
}

struct HealthBodyContext: Codable, Equatable {
    var sleepHours: Double?
    var restingHeartRateBPM: Double?
    var heartRateVariabilityMS: Double?
    /// Per-stage sleep breakdown from HealthKit (`HKCategoryValueSleepAnalysis`), when a wearable
    /// supplies it. Optional: many users only have an `inBed`/`asleepUnspecified` total.
    var sleepStages: SleepStagesData?
}

/// Sleep-stage durations (minutes) for a single night, derived from HealthKit sleep-analysis
/// samples. All fields optional — stage data is only available from devices that classify sleep
/// (e.g. Apple Watch). `totalAsleepMinutes` is the merged asleep total used to derive stage ratios.
struct SleepStagesData: Codable, Equatable {
    var deepMinutes: Double?
    var coreMinutes: Double?
    var remMinutes: Double?
    var awakeMinutes: Double?
    var totalAsleepMinutes: Double?

    /// True when at least one classified asleep stage (deep/core/REM) is present — i.e. the data
    /// is richer than a bare asleep total and worth feeding into the sleep-quality refinement.
    var hasStageBreakdown: Bool {
        (deepMinutes ?? 0) > 0 || (coreMinutes ?? 0) > 0 || (remMinutes ?? 0) > 0
    }
}

struct HealthCycleContext: Codable, Equatable {
    var menstrualFlowEventCount: Int?
    var latestCycleEventAt: Date?
}

struct HealthMindfulnessContext: Codable, Equatable {
    var mindfulSessionMinutes: Double?
}

struct HealthIntimateContext: Codable, Equatable {
    var eventCount: Int?
}

struct DailyHealthScore: Identifiable, Codable, Equatable {
    var id = UUID()
    var dateKey: String
    var score: Double
    var companionState: CompanionState
    var daySummaryText: String?
    var computedAt: Date
    /// Per-component sub-scores (journal/meal/workout/sleep/hydration/hygiene) that produced `score`.
    var componentScores: [String: Double]?
    /// The exact (sickness-adjusted) weight vector applied for this day.
    var weightVector: ScoringWeights?
    /// Whether the day was scored with the sickness override active.
    var sicknessOverride: Bool?
    /// Optional menstrual-cycle phase label for this day (populated once the period bridge lands).
    var periodPhase: String?
    /// The HealthKit activity context (steps/active-energy/exercise-minutes) that fed scoring this
    /// day, retained for audit/inspection. Nil when HealthKit was unavailable or disabled.
    var healthActivityContext: HealthActivitySummary?
    /// The HealthKit body context (sleep hours/stages, resting HR, HRV) that fed scoring this day,
    /// retained for audit/inspection. Nil when HealthKit was unavailable or disabled.
    var healthBodyContext: HealthBodyContext?

    init(id: UUID = UUID(), dateKey: String, score: Double, companionState: CompanionState, daySummaryText: String? = nil, computedAt: Date, componentScores: [String: Double]? = nil, weightVector: ScoringWeights? = nil, sicknessOverride: Bool? = nil, periodPhase: String? = nil, healthActivityContext: HealthActivitySummary? = nil, healthBodyContext: HealthBodyContext? = nil) {
        self.id = id; self.dateKey = dateKey; self.score = score; self.companionState = companionState; self.daySummaryText = daySummaryText; self.computedAt = computedAt
        self.componentScores = componentScores; self.weightVector = weightVector; self.sicknessOverride = sicknessOverride; self.periodPhase = periodPhase
        self.healthActivityContext = healthActivityContext; self.healthBodyContext = healthBodyContext
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        dateKey = try c.decode(String.self, forKey: .dateKey)
        score = try c.decode(Double.self, forKey: .score)
        companionState = try c.decode(CompanionState.self, forKey: .companionState)
        daySummaryText = try c.decodeIfPresent(String.self, forKey: .daySummaryText)
        computedAt = try c.decodeIfPresent(Date.self, forKey: .computedAt) ?? Date()
        componentScores = try c.decodeIfPresent([String: Double].self, forKey: .componentScores)
        weightVector = try c.decodeIfPresent(ScoringWeights.self, forKey: .weightVector)
        sicknessOverride = try c.decodeIfPresent(Bool.self, forKey: .sicknessOverride)
        periodPhase = try c.decodeIfPresent(String.self, forKey: .periodPhase)
        healthActivityContext = try c.decodeIfPresent(HealthActivitySummary.self, forKey: .healthActivityContext)
        healthBodyContext = try c.decodeIfPresent(HealthBodyContext.self, forKey: .healthBodyContext)
    }
}

struct JournalEntry: Identifiable, Codable, Equatable {
    var id = UUID()
    var text: String
    var tag: FeelingTag
    var date = Date()
    var emotions: [String] = []

    init(id: UUID = UUID(), text: String, tag: FeelingTag, date: Date = Date(), emotions: [String] = []) {
        self.id = id; self.text = text; self.tag = tag; self.date = date; self.emotions = emotions
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        tag = try c.decode(FeelingTag.self, forKey: .tag)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        emotions = try c.decodeIfPresent([String].self, forKey: .emotions) ?? []
    }
}

enum FeelingTag: String, Codable, CaseIterable, Identifiable {
    case bright, good, neutral, quiet, tired, hard

    var id: String { rawValue }

    var label: String { rawValue.capitalized }
}

struct SleepLog: Codable, Equatable {
    var hours: Double?
    var quality: SleepQuality
    var note: String
    var loggedAt = Date()

    init(hours: Double? = nil, quality: SleepQuality, note: String, loggedAt: Date = Date()) {
        self.hours = hours; self.quality = quality; self.note = note; self.loggedAt = loggedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = try c.decodeIfPresent(Double.self, forKey: .hours)
        quality = try c.decode(SleepQuality.self, forKey: .quality)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        loggedAt = try c.decodeIfPresent(Date.self, forKey: .loggedAt) ?? Date()
    }
}

enum SleepQuality: String, Codable, CaseIterable, Identifiable {
    case poor, ok, good, great

    var id: String { rawValue }
    var label: String { rawValue.capitalized }

    var description: String {
        switch self {
        case .poor: "rough, broken, unrested"
        case .ok: "enough, not great"
        case .good: "solid, mostly through"
        case .great: "restorative, woke easy"
        }
    }
}

enum HygieneItem: String, Codable, CaseIterable, Identifiable {
    case teethAM, teethPM, floss, shower, deodorant, skincareAM, skincarePM, sunscreen

    var id: String { rawValue }

    var label: String {
        switch self {
        case .teethAM: "Brush teeth AM"
        case .teethPM: "Brush teeth PM"
        case .floss: "Floss"
        case .shower: "Shower"
        case .deodorant: "Deodorant"
        case .skincareAM: "Skincare AM"
        case .skincarePM: "Skincare PM"
        case .sunscreen: "Sunscreen"
        }
    }

    var systemImage: String {
        switch self {
        case .teethAM, .teethPM: "mouth"
        case .floss: "checkmark.seal"
        case .shower: "shower"
        case .deodorant: "sparkle"
        case .skincareAM: "sun.max"
        case .skincarePM: "moon"
        case .sunscreen: "drop"
        }
    }

    var group: String {
        switch self {
        case .teethAM, .skincareAM, .sunscreen: "Morning"
        case .teethPM, .floss, .skincarePM: "Evening"
        case .shower, .deodorant: "Anytime"
        }
    }
}

struct PersonalCareTask: Identifiable, Codable, Equatable {
    var id: String
    var label: String
    var systemImage: String
    var group: String
    var defaultHygieneRawValue: String?

    static let groups = ["Morning", "Anytime", "Evening"]

    static var defaultTasks: [PersonalCareTask] {
        HygieneItem.allCases.map { item in
            PersonalCareTask(
                id: item.rawValue,
                label: item.label,
                systemImage: item.systemImage,
                group: item.group,
                defaultHygieneRawValue: item.rawValue
            )
        }
    }

    var defaultHygieneItem: HygieneItem? {
        guard let defaultHygieneRawValue else { return nil }
        return HygieneItem(rawValue: defaultHygieneRawValue)
    }

    static func custom(label: String, group: String) -> PersonalCareTask {
        PersonalCareTask(
            id: "custom-\(UUID().uuidString)",
            label: label,
            systemImage: "checkmark.circle",
            group: groups.contains(group) ? group : "Anytime",
            defaultHygieneRawValue: nil
        )
    }

    static func normalized(_ tasks: [PersonalCareTask]) -> [PersonalCareTask] {
        var seen: Set<String> = []
        let cleaned = tasks.compactMap { task -> PersonalCareTask? in
            let trimmedLabel = task.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !task.id.isEmpty, !trimmedLabel.isEmpty, !seen.contains(task.id) else { return nil }
            seen.insert(task.id)
            var normalizedTask = task
            normalizedTask.label = trimmedLabel
            normalizedTask.systemImage = task.systemImage.isEmpty ? "checkmark.circle" : task.systemImage
            normalizedTask.group = groups.contains(task.group) ? task.group : "Anytime"
            return normalizedTask
        }
        return cleaned.isEmpty ? defaultTasks : cleaned
    }
}

struct MemoryNote: Identifiable, Codable, Equatable {
    var id = UUID()
    var category: String
    var text: String
    var sourceDate = Date()

    init(id: UUID = UUID(), category: String, text: String, sourceDate: Date = Date()) {
        self.id = id; self.category = category; self.text = text; self.sourceDate = sourceDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try c.decode(String.self, forKey: .category)
        text = try c.decode(String.self, forKey: .text)
        sourceDate = try c.decodeIfPresent(Date.self, forKey: .sourceDate) ?? Date()
    }

    static func fromJournal(text: String, tag: FeelingTag) -> MemoryNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        let prefix = String(trimmed.prefix(120))
        // Spec §8: a diagnostic-language post-classifier runs on every proposed memory
        // before storage; any match is silently rejected so clinical language never lands.
        guard !MemoryAgent.containsDiagnosticLanguage(prefix) else { return nil }
        return MemoryNote(category: tag.rawValue, text: prefix)
    }
}

struct FitnessGoal: Identifiable, Codable, Equatable {
    var id = UUID()
    var type: GoalType
    var goal: String
    var timeframe: String
    var metric: String
    var milestones: [String] = []
    var weeklyStructure: String?

    init(id: UUID = UUID(), type: GoalType, goal: String, timeframe: String, metric: String, milestones: [String] = [], weeklyStructure: String? = nil) {
        self.id = id; self.type = type; self.goal = goal; self.timeframe = timeframe; self.metric = metric; self.milestones = milestones; self.weeklyStructure = weeklyStructure
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        type = try c.decode(GoalType.self, forKey: .type)
        goal = try c.decode(String.self, forKey: .goal)
        timeframe = try c.decodeIfPresent(String.self, forKey: .timeframe) ?? ""
        metric = try c.decodeIfPresent(String.self, forKey: .metric) ?? ""
        milestones = try c.decodeIfPresent([String].self, forKey: .milestones) ?? []
        weeklyStructure = try c.decodeIfPresent(String.self, forKey: .weeklyStructure)
    }
}

enum GoalType: String, Codable, CaseIterable, Identifiable {
    case wellness
    case strength
    case weightManagement
    case mentalHealth
    case recovery
    case exploring
    case sportsPrep

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .wellness: "Wellness"
        case .strength: "Strength"
        case .weightManagement: "Weight Management"
        case .mentalHealth: "Mental Health"
        case .recovery: "Recovery"
        case .exploring: "Exploring"
        case .sportsPrep: "Sports Prep"
        }
    }

    var tagline: String {
        switch self {
        case .wellness: "Balanced daily care."
        case .strength: "Fuel, train, and recover."
        case .weightManagement: "Steady habits without pressure."
        case .mentalHealth: "Mood and steadiness first."
        case .recovery: "Rest, hydration, and gentle care."
        case .exploring: "Learn what feels useful."
        case .sportsPrep: "Train for your sport."
        }
    }

    /// Goals whose programming is built around structured training (drives stricter workout
    /// consistency / progression vs. the gentler wellness-oriented goals).
    var isTrainingFocused: Bool {
        switch self {
        case .strength, .sportsPrep, .weightManagement: true
        case .wellness, .mentalHealth, .recovery, .exploring: false
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case Self.wellness.rawValue, "Wellness", "Short-term":
            self = .wellness
        case Self.strength.rawValue, "Strength", "Long-term":
            self = .strength
        case Self.weightManagement.rawValue, "Weight Management":
            self = .weightManagement
        case Self.mentalHealth.rawValue, "Mental Health":
            self = .mentalHealth
        case Self.recovery.rawValue, "Recovery":
            self = .recovery
        case Self.exploring.rawValue, "Exploring":
            self = .exploring
        case Self.sportsPrep.rawValue, "Sports Prep", "Sport", "Sports":
            self = .sportsPrep
        default:
            self = .wellness
        }
    }
}
