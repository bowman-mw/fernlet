// WellbeingModels.swift
// Split out of Models.swift (SPM carve-up §5c). Day, health-context, journal, sleep, hygiene, goals, and daily-score models.

import Foundation

public nonisolated struct FernletDay: Codable {
    public var date: String
    public var meals: [Meal]
    public var workouts: [Workout]
    public var plannedWorkouts: [PlannedWorkout]
    public var journals: [JournalEntry]
    public var sleep: SleepLog?
    public var bottleCount: Int
    public var hygiene: Set<HygieneItem>
    public var completedPersonalCareTaskIDs: Set<String>
    public var healthContext: HealthDailyContext?

    public init(
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

    public init(from decoder: Decoder) throws {
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

public nonisolated struct HealthDailyContext: Codable, Equatable {

    public init(syncedAt: Date = Date(), activity: HealthActivitySummary? = nil, body: HealthBodyContext? = nil, cycle: HealthCycleContext? = nil, mindfulness: HealthMindfulnessContext? = nil, intimate: HealthIntimateContext? = nil) {
        self.syncedAt = syncedAt
        self.activity = activity
        self.body = body
        self.cycle = cycle
        self.mindfulness = mindfulness
        self.intimate = intimate
    }
    public var syncedAt = Date()
    public var activity: HealthActivitySummary?
    public var body: HealthBodyContext?
    public var cycle: HealthCycleContext?
    public var mindfulness: HealthMindfulnessContext?
    public var intimate: HealthIntimateContext?

    public mutating func merge(_ other: HealthDailyContext) {
        syncedAt = other.syncedAt
        activity = other.activity ?? activity
        body = other.body ?? body
        cycle = other.cycle ?? cycle
        mindfulness = other.mindfulness ?? mindfulness
        intimate = other.intimate ?? intimate
    }
}

public nonisolated struct HealthActivitySummary: Codable, Equatable {

    public init(steps: Int? = nil, activeEnergyKilocalories: Double? = nil, exerciseMinutes: Double? = nil) {
        self.steps = steps
        self.activeEnergyKilocalories = activeEnergyKilocalories
        self.exerciseMinutes = exerciseMinutes
    }
    public var steps: Int?
    public var activeEnergyKilocalories: Double?
    public var exerciseMinutes: Double?
}

public nonisolated struct HealthBodyContext: Codable, Equatable {

    public init(sleepHours: Double? = nil, restingHeartRateBPM: Double? = nil, heartRateVariabilityMS: Double? = nil, sleepStages: SleepStagesData? = nil) {
        self.sleepHours = sleepHours
        self.restingHeartRateBPM = restingHeartRateBPM
        self.heartRateVariabilityMS = heartRateVariabilityMS
        self.sleepStages = sleepStages
    }
    public var sleepHours: Double?
    public var restingHeartRateBPM: Double?
    public var heartRateVariabilityMS: Double?
    /// Per-stage sleep breakdown from HealthKit (`HKCategoryValueSleepAnalysis`), when a wearable
    /// supplies it. Optional: many users only have an `inBed`/`asleepUnspecified` total.
    public var sleepStages: SleepStagesData?
}

/// Sleep-stage durations (minutes) for a single night, derived from HealthKit sleep-analysis
/// samples. All fields optional — stage data is only available from devices that classify sleep
/// (e.g. Apple Watch). `totalAsleepMinutes` is the merged asleep total used to derive stage ratios.
public nonisolated struct SleepStagesData: Codable, Equatable {

    public init(deepMinutes: Double? = nil, coreMinutes: Double? = nil, remMinutes: Double? = nil, awakeMinutes: Double? = nil, totalAsleepMinutes: Double? = nil) {
        self.deepMinutes = deepMinutes
        self.coreMinutes = coreMinutes
        self.remMinutes = remMinutes
        self.awakeMinutes = awakeMinutes
        self.totalAsleepMinutes = totalAsleepMinutes
    }
    public var deepMinutes: Double?
    public var coreMinutes: Double?
    public var remMinutes: Double?
    public var awakeMinutes: Double?
    public var totalAsleepMinutes: Double?

    /// True when at least one classified asleep stage (deep/core/REM) is present — i.e. the data
    /// is richer than a bare asleep total and worth feeding into the sleep-quality refinement.
    public var hasStageBreakdown: Bool {
        (deepMinutes ?? 0) > 0 || (coreMinutes ?? 0) > 0 || (remMinutes ?? 0) > 0
    }
}

public nonisolated struct HealthCycleContext: Codable, Equatable {

    public init(menstrualFlowEventCount: Int? = nil, latestCycleEventAt: Date? = nil) {
        self.menstrualFlowEventCount = menstrualFlowEventCount
        self.latestCycleEventAt = latestCycleEventAt
    }
    public var menstrualFlowEventCount: Int?
    public var latestCycleEventAt: Date?
}

public nonisolated struct HealthMindfulnessContext: Codable, Equatable {

    public init(mindfulSessionMinutes: Double? = nil) {
        self.mindfulSessionMinutes = mindfulSessionMinutes
    }
    public var mindfulSessionMinutes: Double?
}

public nonisolated struct HealthIntimateContext: Codable, Equatable {

    public init(eventCount: Int? = nil) {
        self.eventCount = eventCount
    }
    public var eventCount: Int?
}

public nonisolated struct DailyHealthScore: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var dateKey: String
    public var score: Double
    public var companionState: CompanionState
    public var daySummaryText: String?
    public var computedAt: Date
    /// Per-component sub-scores (journal/meal/workout/sleep/hydration/hygiene) that produced `score`.
    public var componentScores: [String: Double]?
    /// The exact (sickness-adjusted) weight vector applied for this day.
    public var weightVector: ScoringWeights?
    /// Whether the day was scored with the sickness override active.
    public var sicknessOverride: Bool?
    /// Optional menstrual-cycle phase label for this day (populated once the period bridge lands).
    public var periodPhase: String?
    /// The HealthKit activity context (steps/active-energy/exercise-minutes) that fed scoring this
    /// day, retained for audit/inspection. Nil when HealthKit was unavailable or disabled.
    public var healthActivityContext: HealthActivitySummary?
    /// The HealthKit body context (sleep hours/stages, resting HR, HRV) that fed scoring this day,
    /// retained for audit/inspection. Nil when HealthKit was unavailable or disabled.
    public var healthBodyContext: HealthBodyContext?

    public init(id: UUID = UUID(), dateKey: String, score: Double, companionState: CompanionState, daySummaryText: String? = nil, computedAt: Date, componentScores: [String: Double]? = nil, weightVector: ScoringWeights? = nil, sicknessOverride: Bool? = nil, periodPhase: String? = nil, healthActivityContext: HealthActivitySummary? = nil, healthBodyContext: HealthBodyContext? = nil) {
        self.id = id; self.dateKey = dateKey; self.score = score; self.companionState = companionState; self.daySummaryText = daySummaryText; self.computedAt = computedAt
        self.componentScores = componentScores; self.weightVector = weightVector; self.sicknessOverride = sicknessOverride; self.periodPhase = periodPhase
        self.healthActivityContext = healthActivityContext; self.healthBodyContext = healthBodyContext
    }

    public init(from decoder: Decoder) throws {
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

public nonisolated struct JournalEntry: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var text: String
    public var tag: FeelingTag
    public var date = Date()
    public var emotions: [String] = []

    public init(id: UUID = UUID(), text: String, tag: FeelingTag, date: Date = Date(), emotions: [String] = []) {
        self.id = id; self.text = text; self.tag = tag; self.date = date; self.emotions = emotions
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        text = try c.decode(String.self, forKey: .text)
        tag = try c.decode(FeelingTag.self, forKey: .tag)
        date = try c.decodeIfPresent(Date.self, forKey: .date) ?? Date()
        emotions = try c.decodeIfPresent([String].self, forKey: .emotions) ?? []
    }

    /// Returns a copy with `text` + `emotions` cleared when this entry's `id` is in `sealedIDs`
    /// (its plaintext lives in the encrypted narrative store); otherwise returns `self` unchanged.
    ///
    /// The single definition of "strip a sealed journal entry before it is persisted to the
    /// (potentially iCloud-synced) blob" — shared by `FernletSnapshot.forStorage` (the today/snapshot
    /// path) and `DiaryStore.mutatePastDay` (the past-day write path) so sealed journal text can never
    /// reach the synced store regardless of which save path runs (the S3 privacy wall).
    public func strippedIfSealed(in sealedIDs: Set<UUID>) -> JournalEntry {
        guard sealedIDs.contains(id) else { return self }
        return JournalEntry(id: id, text: "", tag: tag, date: date, emotions: [])
    }
}

public nonisolated enum FeelingTag: String, Codable, CaseIterable, Identifiable {
    case bright, good, neutral, quiet, tired, hard

    public var id: String { rawValue }

    public var label: String { rawValue.capitalized }
}

public nonisolated struct SleepLog: Codable, Equatable {
    public var hours: Double?
    public var quality: SleepQuality
    public var note: String
    public var loggedAt = Date()

    public init(hours: Double? = nil, quality: SleepQuality, note: String, loggedAt: Date = Date()) {
        self.hours = hours; self.quality = quality; self.note = note; self.loggedAt = loggedAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hours = try c.decodeIfPresent(Double.self, forKey: .hours)
        quality = try c.decode(SleepQuality.self, forKey: .quality)
        note = try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        loggedAt = try c.decodeIfPresent(Date.self, forKey: .loggedAt) ?? Date()
    }
}

public nonisolated enum SleepQuality: String, Codable, CaseIterable, Identifiable {
    case poor, ok, good, great

    public var id: String { rawValue }
    public var label: String { rawValue.capitalized }

    public var description: String {
        switch self {
        case .poor: "rough, broken, unrested"
        case .ok: "enough, not great"
        case .good: "solid, mostly through"
        case .great: "restorative, woke easy"
        }
    }
}

public nonisolated enum HygieneItem: String, Codable, CaseIterable, Identifiable {
    case teethAM, teethPM, floss, shower, deodorant, skincareAM, skincarePM, sunscreen

    public var id: String { rawValue }

    public var label: String {
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

    public var systemImage: String {
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

    public var group: String {
        switch self {
        case .teethAM, .skincareAM, .sunscreen: "Morning"
        case .teethPM, .floss, .skincarePM: "Evening"
        case .shower, .deodorant: "Anytime"
        }
    }
}

public nonisolated struct PersonalCareTask: Identifiable, Codable, Equatable {

    public init(id: String, label: String, systemImage: String, group: String, defaultHygieneRawValue: String? = nil) {
        self.id = id
        self.label = label
        self.systemImage = systemImage
        self.group = group
        self.defaultHygieneRawValue = defaultHygieneRawValue
    }
    public var id: String
    public var label: String
    public var systemImage: String
    public var group: String
    public var defaultHygieneRawValue: String?

    nonisolated public static let groups = ["Morning", "Anytime", "Evening"]

    nonisolated public static var defaultTasks: [PersonalCareTask] {
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

    public var defaultHygieneItem: HygieneItem? {
        guard let defaultHygieneRawValue else { return nil }
        return HygieneItem(rawValue: defaultHygieneRawValue)
    }

    public static func custom(label: String, group: String) -> PersonalCareTask {
        PersonalCareTask(
            id: "custom-\(UUID().uuidString)",
            label: label,
            systemImage: "checkmark.circle",
            group: groups.contains(group) ? group : "Anytime",
            defaultHygieneRawValue: nil
        )
    }

    public static func normalized(_ tasks: [PersonalCareTask]) -> [PersonalCareTask] {
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

public nonisolated struct MemoryNote: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var category: String
    public var text: String
    public var sourceDate = Date()

    public init(id: UUID = UUID(), category: String, text: String, sourceDate: Date = Date()) {
        self.id = id; self.category = category; self.text = text; self.sourceDate = sourceDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        category = try c.decode(String.self, forKey: .category)
        text = try c.decode(String.self, forKey: .text)
        sourceDate = try c.decodeIfPresent(Date.self, forKey: .sourceDate) ?? Date()
    }

    public static func fromJournal(text: String, tag: FeelingTag) -> MemoryNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return nil }
        let prefix = String(trimmed.prefix(120))
        // Spec §8: a diagnostic-language post-classifier runs on every proposed memory
        // before storage; any match is silently rejected so clinical language never lands.
        guard !DiagnosticLanguage.contains(prefix) else { return nil }
        return MemoryNote(category: tag.rawValue, text: prefix)
    }
}

public nonisolated struct FitnessGoal: Identifiable, Codable, Equatable {
    public var id = UUID()
    public var type: GoalType
    public var goal: String
    public var timeframe: String
    public var metric: String
    public var milestones: [String] = []
    public var weeklyStructure: String?

    public init(id: UUID = UUID(), type: GoalType, goal: String, timeframe: String, metric: String, milestones: [String] = [], weeklyStructure: String? = nil) {
        self.id = id; self.type = type; self.goal = goal; self.timeframe = timeframe; self.metric = metric; self.milestones = milestones; self.weeklyStructure = weeklyStructure
    }

    public init(from decoder: Decoder) throws {
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

public nonisolated enum GoalType: String, Codable, CaseIterable, Identifiable {
    case wellness
    case strength
    case weightManagement
    case mentalHealth
    case recovery
    case exploring
    case sportsPrep

    public var id: String { rawValue }

    public var displayName: String {
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

    public var tagline: String {
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
    public var isTrainingFocused: Bool {
        switch self {
        case .strength, .sportsPrep, .weightManagement: true
        case .wellness, .mentalHealth, .recovery, .exploring: false
        }
    }

    public init(from decoder: Decoder) throws {
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
