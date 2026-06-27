// SettingsModel.swift
// Split out of Models.swift (SPM carve-up §5c). App settings serialization aggregate.

import Foundation

struct FernletSettings: Codable {
    var bottleOz: Int = 24
    var hydrationTarget: Int = 4
    var showDeveloperNotes = false
    var connectionInspectorMode: ConnectionInspectorMode = .live
    var companionAppearance: CompanionAppearance = .standard
    var selectedGoal: GoalType = .wellness
    /// Per-day sickness flags keyed by `yyyy-MM-dd`. Keyed by date so past-day scoring uses the
    /// flag that was set for *that* day, and "today" naturally resets when the date rolls over.
    var sickDays: [String: Bool] = [:]
    /// Per-day dismissal of the "Today's intent" home prompt, keyed by `yyyy-MM-dd`.
    var intentDismissedDays: [String: Bool] = [:]
    /// Per-nutrient cooldown end dates for the preventive-care micronutrient nudge (2-week suppress).
    var nutrientBubbleDismissedUntil: [String: Date] = [:]
    var aiStatus: AIStatus = .off
    var webNutritionLookupEnabled: Bool = false
    /// Opt-in: weather-aware gentle recovery prompts (requests coarse location only when enabled).
    var weatherPromptsEnabled: Bool = false
    var showCalories: Bool = false
    var hasCompletedOnboarding: Bool = false
    var hidePredictions: Bool = false
    var hideFertileWindow: Bool = false
    /// Opt-in: let medium/high-confidence cycle-phase trends gently soften scoring (default off; only takes
    /// effect once 3+ cycles are logged). See `PeriodContextBridge` / `adjustedForPeriod`.
    var periodAwareScoringEnabled: Bool = false
    /// Whether the one-time period-context primer (explaining cycle awareness + the opt-in) has been shown.
    var periodContextPrimerSeen: Bool = false
    var userProfile: UserNutritionProfile = UserNutritionProfile()
    var nutritionPreferences: UserNutritionPreferences = UserNutritionPreferences()
    var quickLogItems: [FernletShortcut] = FernletShortcut.defaultQuickLog
    var homeWidgets: [HomeWidget] = HomeWidget.defaultWidgets
    var personalCareTasks: [PersonalCareTask] = PersonalCareTask.defaultTasks
    var proximityDisplayName: String = ""
    var showProximityDebugTools: Bool = false
    var allowNearbyRecipeShares: Bool = true
    var companionName: String = ""
    var workoutProfile: WorkoutProfile = WorkoutProfile()
    var workoutLocations: [WorkoutLocation] = [WorkoutLocation.fullGym]
    var activeWorkoutLocationID: UUID? = nil
    /// Times each catalog exercise has been completed from a suggested session — drives week-to-week
    /// progression (reps/sets climb as the exercise is repeated).
    var workoutProgression: [String: Int] = [:]

    /// The location whose equipment drives workout suggestions. Falls back to the first location
    /// (or a full gym) so this is always non-nil.
    var activeWorkoutLocation: WorkoutLocation {
        workoutLocations.first(where: { $0.id == activeWorkoutLocationID })
            ?? workoutLocations.first
            ?? .fullGym
    }

    nonisolated init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bottleOz = try container.decodeIfPresent(Int.self, forKey: .bottleOz) ?? 24
        hydrationTarget = try container.decodeIfPresent(Int.self, forKey: .hydrationTarget) ?? 4
        showDeveloperNotes = try container.decodeIfPresent(Bool.self, forKey: .showDeveloperNotes) ?? false
        connectionInspectorMode = try container.decodeIfPresent(ConnectionInspectorMode.self, forKey: .connectionInspectorMode) ?? .live
        companionAppearance = try container.decodeIfPresent(CompanionAppearance.self, forKey: .companionAppearance) ?? .standard
        selectedGoal = try container.decodeIfPresent(GoalType.self, forKey: .selectedGoal) ?? .wellness
        sickDays = try container.decodeIfPresent([String: Bool].self, forKey: .sickDays) ?? [:]
        intentDismissedDays = try container.decodeIfPresent([String: Bool].self, forKey: .intentDismissedDays) ?? [:]
        nutrientBubbleDismissedUntil = try container.decodeIfPresent([String: Date].self, forKey: .nutrientBubbleDismissedUntil) ?? [:]
        aiStatus = try container.decodeIfPresent(AIStatus.self, forKey: .aiStatus) ?? .off
        webNutritionLookupEnabled = try container.decodeIfPresent(Bool.self, forKey: .webNutritionLookupEnabled) ?? false
        weatherPromptsEnabled = try container.decodeIfPresent(Bool.self, forKey: .weatherPromptsEnabled) ?? false
        showCalories = try container.decodeIfPresent(Bool.self, forKey: .showCalories) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        hidePredictions = try container.decodeIfPresent(Bool.self, forKey: .hidePredictions) ?? false
        hideFertileWindow = try container.decodeIfPresent(Bool.self, forKey: .hideFertileWindow) ?? false
        periodAwareScoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .periodAwareScoringEnabled) ?? false
        periodContextPrimerSeen = try container.decodeIfPresent(Bool.self, forKey: .periodContextPrimerSeen) ?? false
        userProfile = try container.decodeIfPresent(UserNutritionProfile.self, forKey: .userProfile) ?? UserNutritionProfile()
        nutritionPreferences = try container.decodeIfPresent(UserNutritionPreferences.self, forKey: .nutritionPreferences) ?? UserNutritionPreferences()
        let decodedQuickLogItems = try container.decodeIfPresent([FernletShortcut].self, forKey: .quickLogItems) ?? FernletShortcut.defaultQuickLog
        quickLogItems = FernletShortcut.normalizedQuickLog(decodedQuickLogItems)
        let decodedHomeWidgets = try container.decodeIfPresent([HomeWidget].self, forKey: .homeWidgets) ?? HomeWidget.defaultWidgets
        homeWidgets = HomeWidget.normalized(decodedHomeWidgets)
        let decodedCareTasks = try container.decodeIfPresent([PersonalCareTask].self, forKey: .personalCareTasks) ?? PersonalCareTask.defaultTasks
        personalCareTasks = PersonalCareTask.normalized(decodedCareTasks)
        proximityDisplayName = try container.decodeIfPresent(String.self, forKey: .proximityDisplayName) ?? ""
        showProximityDebugTools = try container.decodeIfPresent(Bool.self, forKey: .showProximityDebugTools) ?? false
        allowNearbyRecipeShares = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyRecipeShares) ?? true
        companionName = try container.decodeIfPresent(String.self, forKey: .companionName) ?? ""
        workoutProfile = try container.decodeIfPresent(WorkoutProfile.self, forKey: .workoutProfile) ?? WorkoutProfile()
        let decodedLocations = try container.decodeIfPresent([WorkoutLocation].self, forKey: .workoutLocations) ?? [WorkoutLocation.fullGym]
        workoutLocations = decodedLocations.isEmpty ? [WorkoutLocation.fullGym] : decodedLocations
        activeWorkoutLocationID = try container.decodeIfPresent(UUID.self, forKey: .activeWorkoutLocationID)
        workoutProgression = try container.decodeIfPresent([String: Int].self, forKey: .workoutProgression) ?? [:]
    }
}

enum AIStatus: String, Codable, CaseIterable, Identifiable {
    case ready
    case sleepy
    case resting
    case off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ready: "Ready"
        case .sleepy: "Sleepy"
        case .resting: "Resting"
        case .off: "Off"
        }
    }
}
