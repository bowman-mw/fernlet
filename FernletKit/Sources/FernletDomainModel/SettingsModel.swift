// SettingsModel.swift
// Split out of Models.swift (SPM carve-up §5c). App settings serialization aggregate.

import Foundation

public nonisolated struct FernletSettings: Codable {
    public var bottleOz: Int = 24
    public var hydrationTarget: Int = 4
    public var showDeveloperNotes = false
    public var connectionInspectorMode: ConnectionInspectorMode = .live
    public var companionAppearance: CompanionAppearance = .standard
    /// Which owned item is equipped in each slot, keyed by `ItemSlot.rawValue`. A slot absent from the
    /// map (or pointing at a deleted item) renders nothing. The items themselves live in their own
    /// per-row store (`CustomItemService`), not here — only this tiny render-state map stays in settings.
    public var equippedItemIDsBySlot: [String: UUID] = [:]
    /// This device's anonymous, stable designer id, stamped onto every item the user designs. Generated
    /// lazily on first use (see `DiaryStore.localDesignerID`). Not derived from any identity material.
    public var localDesignerID: UUID? = nil
    /// Every designer id this user has used across their OWN devices — this device's `localDesignerID` plus
    /// any seen in a synced settings blob. `isSelfDesigned` checks membership here rather than equality to
    /// the single, last-writer-wins-synced `localDesignerID`, so an item designed on any of the user's
    /// devices stays "self-made". Union-merged on apply (`DiaryStore.applyDiarySlice`) so it only ever grows
    /// and a remote sync can't clobber an id, which is what fixes the cross-device provenance corruption.
    public var ownedDesignerIDs: Set<UUID> = []
    /// Locally-learned `designerID → display name` map, populated when connecting with friends in person
    /// (Increment 3). Lets the closet resolve "designed by <friend>" without the item ever carrying a name.
    public var knownDesignerNames: [String: String] = [:]
    public var selectedGoal: GoalType = .wellness
    /// Per-day sickness flags keyed by `yyyy-MM-dd`. Keyed by date so past-day scoring uses the
    /// flag that was set for *that* day, and "today" naturally resets when the date rolls over.
    public var sickDays: [String: Bool] = [:]
    /// Per-day dismissal of the "Today's intent" home prompt, keyed by `yyyy-MM-dd`.
    public var intentDismissedDays: [String: Bool] = [:]
    /// Per-nutrient cooldown end dates for the preventive-care micronutrient nudge (2-week suppress).
    public var nutrientBubbleDismissedUntil: [String: Date] = [:]
    public var aiStatus: AIStatus = .off
    public var webNutritionLookupEnabled: Bool = false
    /// Opt-in: weather-aware gentle recovery prompts (requests coarse location only when enabled).
    public var weatherPromptsEnabled: Bool = false
    public var showCalories: Bool = false
    public var hasCompletedOnboarding: Bool = false
    public var hidePredictions: Bool = false
    public var hideFertileWindow: Bool = false
    /// Opt-in: let medium/high-confidence cycle-phase trends gently soften scoring (default off; only takes
    /// effect once 3+ cycles are logged). See `PeriodContextBridge` / `adjustedForPeriod`.
    public var periodAwareScoringEnabled: Bool = false
    /// Whether the one-time period-context primer (explaining cycle awareness + the opt-in) has been shown.
    public var periodContextPrimerSeen: Bool = false
    /// Opt-in "Body signals": gently compare HRV/resting-heart-rate with the user's own baseline for a
    /// small wellness reflection + capped score nudge. Default off. Only this flag syncs — the stress
    /// baselines/EWMA state stay in a device-local sidecar (see `StressService`), never in any synced store.
    public var stressAwarenessEnabled: Bool = false
    public var userProfile: UserNutritionProfile = UserNutritionProfile()
    public var nutritionPreferences: UserNutritionPreferences = UserNutritionPreferences()
    public var quickLogItems: [FernletShortcut] = FernletShortcut.defaultQuickLog
    public var homeWidgets: [HomeWidget] = HomeWidget.defaultWidgets
    /// One-time migration marker for the Milestones/First-aid home widgets. Milestones and First aid used
    /// to be fixed, always-visible home elements; they became configurable `HomeWidget`s. Fresh installs
    /// start `true` (they already get both via `defaultWidgets`). Legacy settings decode this as `false`
    /// (the key is absent), which triggers a one-time append of `.milestones`/`.firstAid` in `init(from:)`
    /// so existing users don't silently lose them, then flips to `true` so it runs at most once.
    public var didMigrateMilestonesFirstAidWidgets: Bool = true
    public var personalCareTasks: [PersonalCareTask] = PersonalCareTask.defaultTasks
    public var proximityDisplayName: String = ""
    public var showProximityDebugTools: Bool = false
    public var allowNearbyRecipeShares: Bool = true
    /// Opt-in: broadcast/browse clothing shops with nearby friends in person (Increment 3). Default on.
    public var allowNearbyClothingShares: Bool = true
    /// Opt-IN: send/receive "good vibes" hearts with trusted friends in person. Unlike recipe/clothing
    /// shares (which only invite on an explicit user send), the heart listener AUTO-connects to discover
    /// reachable friends, so a brief signed-identity exchange happens before a non-friend can be
    /// classified + torn down. Defaulting OFF makes the whole feature consent-gated (privacy-first) and
    /// removes that ambient-exchange window entirely; turning it off stops the heart listener immediately.
    public var allowNearbyHearts: Bool = false
    /// `yyyy-MM-dd` of the last day the user changed their shop's listed set. Drives the gentle
    /// once-per-day "you've already updated your shop today" note. Nil until the first listing change.
    public var shopLastPublishedDayKey: String? = nil
    public var companionName: String = ""
    public var workoutProfile: WorkoutProfile = WorkoutProfile()
    public var workoutLocations: [WorkoutLocation] = [WorkoutLocation.fullGym]
    public var activeWorkoutLocationID: UUID? = nil
    /// Times each catalog exercise has been completed from a suggested session — drives week-to-week
    /// progression (reps/sets climb as the exercise is repeated).
    public var workoutProgression: [String: Int] = [:]

    /// The location whose equipment drives workout suggestions. Falls back to the first location
    /// (or a full gym) so this is always non-nil.
    public var activeWorkoutLocation: WorkoutLocation {
        workoutLocations.first(where: { $0.id == activeWorkoutLocationID })
            ?? workoutLocations.first
            ?? .fullGym
    }

    nonisolated public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bottleOz = try container.decodeIfPresent(Int.self, forKey: .bottleOz) ?? 24
        hydrationTarget = try container.decodeIfPresent(Int.self, forKey: .hydrationTarget) ?? 4
        showDeveloperNotes = try container.decodeIfPresent(Bool.self, forKey: .showDeveloperNotes) ?? false
        connectionInspectorMode = try container.decodeIfPresent(ConnectionInspectorMode.self, forKey: .connectionInspectorMode) ?? .live
        companionAppearance = try container.decodeIfPresent(CompanionAppearance.self, forKey: .companionAppearance) ?? .standard
        equippedItemIDsBySlot = try container.decodeIfPresent([String: UUID].self, forKey: .equippedItemIDsBySlot) ?? [:]
        localDesignerID = try container.decodeIfPresent(UUID.self, forKey: .localDesignerID)
        ownedDesignerIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .ownedDesignerIDs) ?? []
        knownDesignerNames = try container.decodeIfPresent([String: String].self, forKey: .knownDesignerNames) ?? [:]
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
        stressAwarenessEnabled = try container.decodeIfPresent(Bool.self, forKey: .stressAwarenessEnabled) ?? false
        userProfile = try container.decodeIfPresent(UserNutritionProfile.self, forKey: .userProfile) ?? UserNutritionProfile()
        nutritionPreferences = try container.decodeIfPresent(UserNutritionPreferences.self, forKey: .nutritionPreferences) ?? UserNutritionPreferences()
        let decodedQuickLogItems = try container.decodeIfPresent([FernletShortcut].self, forKey: .quickLogItems) ?? FernletShortcut.defaultQuickLog
        quickLogItems = FernletShortcut.normalizedQuickLog(decodedQuickLogItems)
        var decodedHomeWidgets = try container.decodeIfPresent([HomeWidget].self, forKey: .homeWidgets) ?? HomeWidget.defaultWidgets
        // One-time migration: Milestones + First aid used to be fixed home elements. If this settings blob
        // predates them becoming widgets (marker absent ⇒ false), append whichever aren't already present so
        // existing users keep them on the home feed. Runs at most once; the marker then persists as true.
        didMigrateMilestonesFirstAidWidgets = try container.decodeIfPresent(Bool.self, forKey: .didMigrateMilestonesFirstAidWidgets) ?? false
        if !didMigrateMilestonesFirstAidWidgets {
            for widget in [HomeWidget.firstAid, .milestones] where !decodedHomeWidgets.contains(widget) {
                decodedHomeWidgets.append(widget)
            }
            didMigrateMilestonesFirstAidWidgets = true
        }
        homeWidgets = HomeWidget.normalized(decodedHomeWidgets)
        let decodedCareTasks = try container.decodeIfPresent([PersonalCareTask].self, forKey: .personalCareTasks) ?? PersonalCareTask.defaultTasks
        personalCareTasks = PersonalCareTask.normalized(decodedCareTasks)
        proximityDisplayName = try container.decodeIfPresent(String.self, forKey: .proximityDisplayName) ?? ""
        showProximityDebugTools = try container.decodeIfPresent(Bool.self, forKey: .showProximityDebugTools) ?? false
        allowNearbyRecipeShares = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyRecipeShares) ?? true
        allowNearbyClothingShares = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyClothingShares) ?? true
        allowNearbyHearts = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyHearts) ?? false
        shopLastPublishedDayKey = try container.decodeIfPresent(String.self, forKey: .shopLastPublishedDayKey)
        companionName = try container.decodeIfPresent(String.self, forKey: .companionName) ?? ""
        workoutProfile = try container.decodeIfPresent(WorkoutProfile.self, forKey: .workoutProfile) ?? WorkoutProfile()
        let decodedLocations = try container.decodeIfPresent([WorkoutLocation].self, forKey: .workoutLocations) ?? [WorkoutLocation.fullGym]
        workoutLocations = decodedLocations.isEmpty ? [WorkoutLocation.fullGym] : decodedLocations
        activeWorkoutLocationID = try container.decodeIfPresent(UUID.self, forKey: .activeWorkoutLocationID)
        workoutProgression = try container.decodeIfPresent([String: Int].self, forKey: .workoutProgression) ?? [:]
    }
}

public nonisolated enum AIStatus: String, Codable, CaseIterable, Identifiable {
    case ready
    case sleepy
    case resting
    case off

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .ready: "Ready"
        case .sleepy: "Sleepy"
        case .resting: "Resting"
        case .off: "Off"
        }
    }
}
