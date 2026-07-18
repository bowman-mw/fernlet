// SettingsModel.swift
// Split out of Models.swift (SPM carve-up §5c). App settings serialization aggregate.

import Foundation

public nonisolated struct FernletSettings: Codable {
    public var bottleOz: Int = 24
    public var hydrationTarget: Int = 4
    public var showDeveloperNotes = false
    public var connectionInspectorMode: ConnectionInspectorMode = .live {
        didSet { unknownConnectionInspectorModeToken = nil }
    }
    /// Raw `connectionInspectorMode` token from a NEWER build, parked instead of thrown on (which
    /// would latch this device into decode-failure recovery) and re-encoded so a save here can't
    /// strip it from the synced blob. A build that knows it re-adopts it on decode; an explicit
    /// local mode change clears it (`didSet`) so the last editor wins. Same contract for every
    /// `unknown…Token` scalar side channel below and across the domain models (`EnumDecodeCompat`).
    public var unknownConnectionInspectorModeToken: String? = nil
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
    public var selectedGoal: GoalType = .wellness {
        didSet { unknownSelectedGoalToken = nil }
    }
    /// Unknown `selectedGoal` token from a newer build; contract of `unknownConnectionInspectorModeToken`.
    public var unknownSelectedGoalToken: String? = nil
    /// Per-day sickness flags keyed by `yyyy-MM-dd`. Keyed by date so past-day scoring uses the
    /// flag that was set for *that* day, and "today" naturally resets when the date rolls over.
    public var sickDays: [String: Bool] = [:]
    /// Per-day dismissal of the "Today's intent" home prompt, keyed by `yyyy-MM-dd`.
    public var intentDismissedDays: [String: Bool] = [:]
    /// Per-nutrient cooldown end dates for the preventive-care micronutrient nudge (2-week suppress).
    public var nutrientBubbleDismissedUntil: [String: Date] = [:]
    public var aiStatus: AIStatus = .off {
        didSet { unknownAIStatusToken = nil }
    }
    /// Unknown `aiStatus` token from a newer build; contract of `unknownConnectionInspectorModeToken`.
    public var unknownAIStatusToken: String? = nil
    public var webNutritionLookupEnabled: Bool = false
    /// Opt-in: weather-aware gentle recovery prompts (requests coarse location only when enabled).
    public var weatherPromptsEnabled: Bool = false
    public var showCalories: Bool = false
    public var hasCompletedOnboarding: Bool = false
    /// Whether the cycle surfaces are visible at all. `nil` means "not chosen" and derives from
    /// `userProfile.sex` (see `isPeriodTrackingVisible`); a non-nil value is an explicit Settings
    /// override that outranks `sex`. Hiding is a HARD gate, not cosmetic: while hidden Fernlet
    /// performs no cycle decrypt and no cycle HealthKit read (see `PeriodTrackerStore.isVisible` and
    /// `allowedHealthCapabilities`). Contrast `hidePredictions`/`hideFertileWindow`, which are
    /// cosmetic sub-options that still read the data. Hidden NEVER deletes — the sealed rows survive
    /// and re-appear if un-hidden.
    public var periodTrackingVisible: Bool? = nil
    /// One-time marker for the period-visibility gate, mirroring `didMigrateMilestonesFirstAidWidgets`.
    /// Fresh installs start `true` (nothing to migrate — they derive from `sex`). A settings blob that
    /// predates the gate decodes this as `false` (key absent), which pins `periodTrackingVisible = true`
    /// once so an existing cycle-tracking user doesn't silently lose the feature to `sex`'s `.male`
    /// default, then flips to `true` so it never runs again.
    public var didMigratePeriodVisibility: Bool = true
    /// Whether intimate-activity logging is visible. Default ON so this preserves today's behavior
    /// exactly, and so the flag only deviates from its default in the benign direction (turned OFF) —
    /// a default-OFF flag reading `true` would positively signal "this user tracks intimacy" to
    /// anyone reading the synced blob. Still subordinate to the 18+ age check
    /// (`isIntimateLoggingAllowed`), which is a separate concern: age says "may not", this says
    /// "does not want to". Hiding is a hard gate on the same terms as `periodTrackingVisible`.
    public var intimacyTrackingVisible: Bool = true
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
    /// User-set macro *target* overrides. `nil` means "derive from goal, profile, activity and eating
    /// pattern" (the default and today's only behavior); a non-nil value pins that one target and the
    /// rest of the plan re-solves around it. Only calories, protein and fat are pinnable — carbs is
    /// always the residual (`NutritionTargetCalculator`), so pinning any of these three rebalances carbs
    /// for free and the four numbers agree with the calorie total in the normal case (see the carbs floor
    /// in `NutritionTargetCalculator` for the high-protein/fat exception). These are last-writer-
    /// wins scalars in the synced settings blob, exactly like `showCalories`.
    public var calorieTargetOverride: Int? = nil
    public var proteinTargetOverride: Int? = nil
    public var fatTargetOverride: Int? = nil

    /// True when the user has pinned any macro target — the point past which a goal's nutrition summary
    /// no longer fully describes the plan in effect (the override wins). Computed, not stored.
    public var hasAnyNutritionOverride: Bool {
        calorieTargetOverride != nil || proteinTargetOverride != nil || fatTargetOverride != nil
    }
    public var quickLogItems: [FernletShortcut] = FernletShortcut.defaultQuickLog
    /// Raw `quickLogItems` tokens this build's `FernletShortcut` doesn't know — shortcuts added by a
    /// NEWER build on another device. Parked here (and re-encoded) instead of thrown on, so a newer
    /// device's settings can't latch this one into decode-failure recovery, and instead of dropped,
    /// so a save on this device can't strip them from the synced blob. A build that knows a parked
    /// token re-adopts it into the typed array on decode (see `splitRawTokens`).
    public var unknownQuickLogTokens: [String] = []
    public var homeWidgets: [HomeWidget] = HomeWidget.defaultWidgets
    /// Unknown `homeWidgets` tokens from newer builds; same contract as `unknownQuickLogTokens`.
    public var unknownHomeWidgetTokens: [String] = []
    /// One-time migration marker for the Milestones/First-aid home widgets. Milestones and First aid used
    /// to be fixed, always-visible home elements; they became configurable `HomeWidget`s. Fresh installs
    /// start `true` (they already get both via `defaultWidgets`). Legacy settings decode this as `false`
    /// (the key is absent), which triggers a one-time append of `.milestones`/`.firstAid` in `init(from:)`
    /// so existing users don't silently lose them, then flips to `true` so it runs at most once.
    public var didMigrateMilestonesFirstAidWidgets: Bool = true
    /// One-time marker for the "Recent bites" meal-photo home widget (#11), mirroring
    /// `didMigrateMilestonesFirstAidWidgets`. Fresh installs start `true` (they already get it via
    /// `defaultWidgets`); a settings blob written before the widget existed decodes this as `false` and
    /// triggers a one-time append of `.mealPhotos` so an existing user sees it, then flips to `true`.
    public var didMigrateMealPhotosWidget: Bool = true
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
    /// Opt-IN presence layer (mesh redesign Phase 4a): while on — and only with the app open,
    /// unlocked, and on a main tab — Fernlet broadcasts rotating pairwise tags that ONLY a kept
    /// friend can recognize (never a name or a stable identifier), so kept friends see each other
    /// nearby. Default OFF (privacy-first); a one-time enable prompt is offered at the first kept
    /// friend. Turning it off stops the presence radio immediately.
    public var allowNearbyPresence: Bool = false
    /// Opt-IN (Phase 4): share a fuzzy wellbeing vibe (thriving/okay/struggling) + your avatar with
    /// kept friends when you meet in person — never a number, goal, or cycle. Default OFF; separate
    /// from hearts/presence.
    public var allowNearbyFriendState: Bool = false
    /// One-time marker for the "Turn on Nearby Friends?" prompt offered when the user keeps their
    /// FIRST friend. Once true the prompt never fires again (regardless of the answer).
    public var hasPromptedForPresence: Bool = false
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
        // Scalar enum fields decode tolerantly (freeze-on-unknown + parked-token side channel):
        // `decodeIfPresent(EnumType.self) ?? default` only defaults on an ABSENT key — a present
        // raw value from a newer build throws and cascades into decode-failure recovery. See
        // EnumDecodeCompat for the full contract.
        let inspectorSplit = try container.decodeTolerantEnum(
            ConnectionInspectorMode.self, forKey: .connectionInspectorMode,
            parkedTokenKey: .unknownConnectionInspectorModeToken, default: .live)
        connectionInspectorMode = inspectorSplit.value
        unknownConnectionInspectorModeToken = inspectorSplit.parkedToken
        companionAppearance = try container.decodeIfPresent(CompanionAppearance.self, forKey: .companionAppearance) ?? .standard
        equippedItemIDsBySlot = try container.decodeIfPresent([String: UUID].self, forKey: .equippedItemIDsBySlot) ?? [:]
        localDesignerID = try container.decodeIfPresent(UUID.self, forKey: .localDesignerID)
        ownedDesignerIDs = try container.decodeIfPresent(Set<UUID>.self, forKey: .ownedDesignerIDs) ?? []
        knownDesignerNames = try container.decodeIfPresent([String: String].self, forKey: .knownDesignerNames) ?? [:]
        // `GoalType.init(persistedToken:)` also maps the legacy aliases ("Wellness", "Short-term",
        // …) that GoalType's own lenient Decodable init has always accepted.
        let goalSplit = try container.decodeTolerantEnum(
            GoalType.self, forKey: .selectedGoal,
            parkedTokenKey: .unknownSelectedGoalToken, default: .wellness,
            resolve: GoalType.init(persistedToken:))
        selectedGoal = goalSplit.value
        unknownSelectedGoalToken = goalSplit.parkedToken
        sickDays = try container.decodeIfPresent([String: Bool].self, forKey: .sickDays) ?? [:]
        intentDismissedDays = try container.decodeIfPresent([String: Bool].self, forKey: .intentDismissedDays) ?? [:]
        nutrientBubbleDismissedUntil = try container.decodeIfPresent([String: Date].self, forKey: .nutrientBubbleDismissedUntil) ?? [:]
        let aiStatusSplit = try container.decodeTolerantEnum(
            AIStatus.self, forKey: .aiStatus,
            parkedTokenKey: .unknownAIStatusToken, default: .off)
        aiStatus = aiStatusSplit.value
        unknownAIStatusToken = aiStatusSplit.parkedToken
        webNutritionLookupEnabled = try container.decodeIfPresent(Bool.self, forKey: .webNutritionLookupEnabled) ?? false
        weatherPromptsEnabled = try container.decodeIfPresent(Bool.self, forKey: .weatherPromptsEnabled) ?? false
        showCalories = try container.decodeIfPresent(Bool.self, forKey: .showCalories) ?? false
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        // Absent key ⇒ nil ⇒ derive from `sex`. That is right for a fresh install but WRONG for an
        // existing user: `sex` defaults to `.male`, so someone who has been tracking cycles without
        // ever setting it would silently lose the feature (and their data would go dark behind the
        // gate) on upgrade. Pin those users to visible once, and let them opt out in Settings.
        //
        // The marker MUST be a dedicated one-time flag. `hasCompletedOnboarding` looks like it would
        // work but is not a proxy for "existing user" — it turns true for new users too, so gating on
        // it would pin every new user to visible on their second launch and the `sex` derivation would
        // never run at all.
        periodTrackingVisible = try container.decodeIfPresent(Bool.self, forKey: .periodTrackingVisible)
        didMigratePeriodVisibility = try container.decodeIfPresent(Bool.self, forKey: .didMigratePeriodVisibility) ?? false
        if !didMigratePeriodVisibility {
            if periodTrackingVisible == nil { periodTrackingVisible = true }
            didMigratePeriodVisibility = true
        }
        intimacyTrackingVisible = try container.decodeIfPresent(Bool.self, forKey: .intimacyTrackingVisible) ?? true
        hidePredictions = try container.decodeIfPresent(Bool.self, forKey: .hidePredictions) ?? false
        hideFertileWindow = try container.decodeIfPresent(Bool.self, forKey: .hideFertileWindow) ?? false
        periodAwareScoringEnabled = try container.decodeIfPresent(Bool.self, forKey: .periodAwareScoringEnabled) ?? false
        periodContextPrimerSeen = try container.decodeIfPresent(Bool.self, forKey: .periodContextPrimerSeen) ?? false
        stressAwarenessEnabled = try container.decodeIfPresent(Bool.self, forKey: .stressAwarenessEnabled) ?? false
        userProfile = try container.decodeIfPresent(UserNutritionProfile.self, forKey: .userProfile) ?? UserNutritionProfile()
        nutritionPreferences = try container.decodeIfPresent(UserNutritionPreferences.self, forKey: .nutritionPreferences) ?? UserNutritionPreferences()
        // Absent key ⇒ nil ⇒ derive (correct for every settings blob written before overrides existed).
        calorieTargetOverride = try container.decodeIfPresent(Int.self, forKey: .calorieTargetOverride)
        proteinTargetOverride = try container.decodeIfPresent(Int.self, forKey: .proteinTargetOverride)
        fatTargetOverride = try container.decodeIfPresent(Int.self, forKey: .fatTargetOverride)
        // These enum arrays sync across devices, so decode them tolerantly: a strict `[FernletShortcut]`/
        // `[HomeWidget]` decode throws on the first raw value only a NEWER build knows, and that error
        // cascades into decode-failure recovery (empty read-only database) on this device. Known tokens
        // become the typed arrays; unknown ones are parked in the side channels, and previously parked
        // tokens this build now knows are re-adopted (appended — their original positions are gone).
        let quickLogTokens = try container.decodeIfPresent([String].self, forKey: .quickLogItems)
            ?? FernletShortcut.defaultQuickLog.map(\.rawValue)
        let parkedQuickLogTokens = try container.decodeIfPresent([String].self, forKey: .unknownQuickLogTokens) ?? []
        let quickLogSplit = Self.splitRawTokens(quickLogTokens + parkedQuickLogTokens, as: FernletShortcut.self)
        unknownQuickLogTokens = quickLogSplit.unknown
        // Only pad to six slots when nothing is parked: display pads transiently anyway
        // (`visibleQuickLog`), and persisting the pad would let auto-filled defaults permanently claim
        // the slots the parked (newer-build) shortcuts occupy once a newer device re-adopts them.
        quickLogItems = quickLogSplit.unknown.isEmpty
            ? FernletShortcut.normalizedQuickLog(quickLogSplit.known)
            : Array(quickLogSplit.known.prefix(6))
        let homeWidgetTokens = try container.decodeIfPresent([String].self, forKey: .homeWidgets)
            ?? HomeWidget.defaultWidgets.map(\.rawValue)
        let parkedHomeWidgetTokens = try container.decodeIfPresent([String].self, forKey: .unknownHomeWidgetTokens) ?? []
        let homeWidgetSplit = Self.splitRawTokens(homeWidgetTokens + parkedHomeWidgetTokens, as: HomeWidget.self)
        unknownHomeWidgetTokens = homeWidgetSplit.unknown
        var decodedHomeWidgets = homeWidgetSplit.known
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
        // One-time migration for the "Recent bites" meal-photo widget (#11): a separate marker, because
        // the Milestones/First-aid marker above has already flipped true for existing users, so it can't
        // carry a later widget. Append once if absent so an existing user sees it.
        didMigrateMealPhotosWidget = try container.decodeIfPresent(Bool.self, forKey: .didMigrateMealPhotosWidget) ?? false
        if !didMigrateMealPhotosWidget {
            // Only append to a real widget list. An EMPTY decoded list (e.g. every token unknown, from a
            // newer build) falls back to `defaultWidgets` in `normalized` below — which already includes
            // `.mealPhotos` — so appending here would suppress that fallback and strand the user with ONLY
            // this widget instead of the full default set.
            if !decodedHomeWidgets.isEmpty && !decodedHomeWidgets.contains(.mealPhotos) {
                decodedHomeWidgets.append(.mealPhotos)
            }
            didMigrateMealPhotosWidget = true
        }
        homeWidgets = HomeWidget.normalized(decodedHomeWidgets)
        let decodedCareTasks = try container.decodeIfPresent([PersonalCareTask].self, forKey: .personalCareTasks) ?? PersonalCareTask.defaultTasks
        personalCareTasks = PersonalCareTask.normalized(decodedCareTasks)
        proximityDisplayName = try container.decodeIfPresent(String.self, forKey: .proximityDisplayName) ?? ""
        showProximityDebugTools = try container.decodeIfPresent(Bool.self, forKey: .showProximityDebugTools) ?? false
        allowNearbyRecipeShares = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyRecipeShares) ?? true
        allowNearbyClothingShares = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyClothingShares) ?? true
        allowNearbyHearts = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyHearts) ?? false
        allowNearbyPresence = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyPresence) ?? false
        allowNearbyFriendState = try container.decodeIfPresent(Bool.self, forKey: .allowNearbyFriendState) ?? false
        hasPromptedForPresence = try container.decodeIfPresent(Bool.self, forKey: .hasPromptedForPresence) ?? false
        shopLastPublishedDayKey = try container.decodeIfPresent(String.self, forKey: .shopLastPublishedDayKey)
        companionName = try container.decodeIfPresent(String.self, forKey: .companionName) ?? ""
        workoutProfile = try container.decodeIfPresent(WorkoutProfile.self, forKey: .workoutProfile) ?? WorkoutProfile()
        let decodedLocations = try container.decodeIfPresent([WorkoutLocation].self, forKey: .workoutLocations) ?? [WorkoutLocation.fullGym]
        workoutLocations = decodedLocations.isEmpty ? [WorkoutLocation.fullGym] : decodedLocations
        activeWorkoutLocationID = try container.decodeIfPresent(UUID.self, forKey: .activeWorkoutLocationID)
        workoutProgression = try container.decodeIfPresent([String: Int].self, forKey: .workoutProgression) ?? [:]
    }

    /// The split logic (and its defensive bounds) moved to `EnumDecodeCompat.splitRawTokens` when
    /// the tolerant-decode pattern was generalized to the rest of the domain models; kept here as a
    /// private shim so `init(from:)` reads unchanged.
    private static func splitRawTokens<Case: RawRepresentable>(
        _ tokens: [String],
        as type: Case.Type
    ) -> (known: [Case], unknown: [String]) where Case.RawValue == String {
        EnumDecodeCompat.splitRawTokens(tokens, as: type)
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
