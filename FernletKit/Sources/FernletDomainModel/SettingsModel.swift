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
    /// One-time marker for the period-visibility gate: `true` means "a build really DETERMINED the
    /// visibility state this blob carries". It is minted only at a real determination — the one-time
    /// pin/derivation in `reconcilingSensitiveVisibility`, onboarding completion (which just captured
    /// `sex`, making derive-from-`sex` a current choice), or an explicit Settings toggle — and NEVER as
    /// a passive default: the memberwise default is `false`, so the synthesized missing-record database
    /// a fresh install starts from (while it waits for its first CloudKit pull) cannot masquerade as an
    /// already-migrated blob, mark the device "resolved" with pristine values, or write a blob other
    /// devices would trust. A settings blob that predates the gate also decodes this as `false` (key
    /// absent) — the signal that pins `periodTrackingVisible = true` once so an existing cycle-tracking
    /// user doesn't silently lose the feature to `sex`'s `.male` default. Unlike the widget markers, the
    /// pin is NOT applied in `init(from:)`: a pre-gate peer that re-encodes the synced blob DROPS this key,
    /// which would make the pin re-fire and re-open a deliberately hidden surface. The pin/derivation runs
    /// in `reconcilingSensitiveVisibility`, gated on a device-local marker a pre-gate peer can never
    /// rewrite; this field's decoded value is that reconciliation's determined-vs-undetermined discriminator.
    public var didMigratePeriodVisibility: Bool = false
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
    /// Opt-IN away delivery for hearts (bitchat adoptions Increment 3): when a kept friend isn't
    /// nearby, a heart is sealed end-to-end and left in a CloudKit public-database dead-drop only
    /// that friend can find (rotating pairwise day tags; one-time prekeys when available),
    /// delivered when their Fernlet next checks. Default OFF — this is the only proximity feature
    /// that touches the network, so it gets its own consent, independent of the iCloud *sync*
    /// storage preference.
    public var heartsAwayDelivery: Bool = false
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

    /// Every top-level settings key this build does NOT know, captured verbatim on decode and written
    /// back verbatim on encode. The GENERIC, systemic counterpart to the per-field `unknown…Token`
    /// side channels above (and the TODO that used to sit in `init(from:)`): when a device on an OLDER
    /// app version decodes a synced blob a NEWER version wrote, `Codable` would silently DROP every key
    /// it lacks, and this device's next save would STRIP those keys from the synced blob — losing the
    /// newer device's settings. That key-drop is exactly what once re-fired the period-visibility
    /// migration. Parking round-trips a newer build's settings losslessly instead.
    ///
    /// Contract:
    /// - Only keys with NO `CodingKeys` case land here. A key this build knows is decoded normally and
    ///   is NEVER parked (`init(from:)` excludes every known key), so when a parked key later becomes
    ///   known the current version's value always wins and a parked entry can never shadow it on encode.
    /// - Semantically INVISIBLE: default empty, excluded from every user-facing behaviour (scoring, UI,
    ///   the sensitive-surface gate). It carries no meaning to this build — only a future build's bytes.
    /// - Written back at the TOP LEVEL by key (`encode(to:)`), NOT inside a nested container: a nested
    ///   wrapper key would itself be an unknown key that an EVEN-OLDER build would drop.
    /// - NOT a `CodingKeys` case, so it is never emitted under its own key and never mistaken for a
    ///   known key when the parking set is computed.
    public var parkedUnknownKeys: [String: JSONValue] = [:]

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
        // Decode the visibility gate RAW and deterministically — the one-time pin migration does NOT
        // fire here. Absent `didMigratePeriodVisibility` ⇒ `false`, preserved as the discriminator the
        // device-local reconciliation reads: a build that really determined the visibility state encodes
        // it `true`, so `false`-on-decode means "no determination is represented here" — a pre-gate
        // blob, a pre-gate peer's key-dropping re-encode, or an up-to-date device that has not
        // determined anything yet. Pure decode stays side-effect-free (no keychain/UserDefaults read),
        // so it can't depend on device-local state.
        //
        // Why the pin moved OUT of `init(from:)`: on a mixed-version multi-device sync, a SECOND device on
        // a pre-gate build decodes the synced settings and re-encodes with only the keys it knows —
        // DROPPING `periodTrackingVisible`/`didMigratePeriodVisibility`/`intimacyTrackingVisible`. If the pin
        // ran here, the up-to-date device re-decoding that blob would see the migration key absent and
        // RE-FIRE the pin (nil ⇒ visible-true) — silently re-opening a surface the user deliberately hid,
        // and intimacy would default back to visible. `FernletSettings.reconcilingSensitiveVisibility`
        // applies the pin/derivation gated on a DEVICE-LOCAL marker a pre-gate peer can never rewrite, so a
        // resolved device re-asserts its own values (fail-closed) instead of re-pinning. See
        // `FernletStore.reconcileSensitiveSurfaceVisibility`.
        //
        // GENERIC unknown-top-level-KEY parking is now implemented (see `parkedUnknownKeys` and the
        // capture block at the end of this initializer): a pre-gate build no longer silently drops every
        // key it doesn't know on re-encode. The device-local guard still closes the privacy-critical
        // visibility case specifically (the markers below are KNOWN keys, decoded here and therefore
        // never parkable); generic parking is the systemic backstop for every OTHER future key.
        periodTrackingVisible = try container.decodeIfPresent(Bool.self, forKey: .periodTrackingVisible)
        didMigratePeriodVisibility = try container.decodeIfPresent(Bool.self, forKey: .didMigratePeriodVisibility) ?? false
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
        heartsAwayDelivery = try container.decodeIfPresent(Bool.self, forKey: .heartsAwayDelivery) ?? false
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

        // Generic unknown-key parking (see `parkedUnknownKeys`): capture every remaining top-level key
        // this build doesn't know, with its raw JSON value, so a re-encode here round-trips a newer
        // build's settings losslessly instead of dropping them. `knownKeys` is every `CodingKeys` case,
        // all decoded above, so a key this build owns is EXCLUDED here and can never be parked — the
        // current version always wins for its own keys. That specifically covers the privacy-critical
        // `didMigratePeriodVisibility` / `periodTrackingVisible` / `intimacyTrackingVisible` markers, so
        // parking can never let a stale copy of them shadow the live gate. This capture is deliberately
        // UNCAPPED (unlike the bounded enum-token channels): a newer build may legitimately add many keys
        // over versions, and dropping any of them would reintroduce the very loss this fixes; the blob's
        // overall size is already bounded by the sync layer.
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        let dynamicContainer = try decoder.container(keyedBy: DynamicCodingKey.self)
        var parked: [String: JSONValue] = [:]
        for key in dynamicContainer.allKeys where !knownKeys.contains(key.stringValue) {
            parked[key.stringValue] = try dynamicContainer.decode(JSONValue.self, forKey: key)
        }
        parkedUnknownKeys = parked
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        // Every STORED property that participates in the synced wire format. `parkedUnknownKeys` is
        // deliberately absent: it is written back at the top level by key (`encode(to:)`), never under a
        // key of its own, and its absence here is also what lets it be excluded from the parked set.
        case bottleOz, hydrationTarget, showDeveloperNotes, connectionInspectorMode,
             unknownConnectionInspectorModeToken, companionAppearance, equippedItemIDsBySlot,
             localDesignerID, ownedDesignerIDs, knownDesignerNames, selectedGoal,
             unknownSelectedGoalToken, sickDays, intentDismissedDays, nutrientBubbleDismissedUntil,
             aiStatus, unknownAIStatusToken, webNutritionLookupEnabled, weatherPromptsEnabled,
             showCalories, hasCompletedOnboarding, periodTrackingVisible, didMigratePeriodVisibility,
             intimacyTrackingVisible, hidePredictions, hideFertileWindow, periodAwareScoringEnabled,
             periodContextPrimerSeen, stressAwarenessEnabled, userProfile, nutritionPreferences,
             calorieTargetOverride, proteinTargetOverride, fatTargetOverride, quickLogItems,
             unknownQuickLogTokens, homeWidgets, unknownHomeWidgetTokens,
             didMigrateMilestonesFirstAidWidgets, didMigrateMealPhotosWidget, personalCareTasks,
             proximityDisplayName, showProximityDebugTools, allowNearbyRecipeShares,
             allowNearbyClothingShares, allowNearbyHearts, heartsAwayDelivery, allowNearbyPresence, allowNearbyFriendState,
             hasPromptedForPresence, shopLastPublishedDayKey, companionName, workoutProfile,
             workoutLocations, activeWorkoutLocationID, workoutProgression
    }

    /// Custom encode (required so `parkedUnknownKeys` can be re-emitted at the top level). It writes the
    /// SAME shape the compiler used to synthesize — non-optionals via `encode`, optionals via
    /// `encodeIfPresent` (so a nil side channel stays absent, matching the legacy blob shape the previous
    /// build decodes) — then writes every parked key back verbatim.
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bottleOz, forKey: .bottleOz)
        try container.encode(hydrationTarget, forKey: .hydrationTarget)
        try container.encode(showDeveloperNotes, forKey: .showDeveloperNotes)
        try container.encode(connectionInspectorMode, forKey: .connectionInspectorMode)
        try container.encodeIfPresent(unknownConnectionInspectorModeToken, forKey: .unknownConnectionInspectorModeToken)
        try container.encode(companionAppearance, forKey: .companionAppearance)
        try container.encode(equippedItemIDsBySlot, forKey: .equippedItemIDsBySlot)
        try container.encodeIfPresent(localDesignerID, forKey: .localDesignerID)
        try container.encode(ownedDesignerIDs, forKey: .ownedDesignerIDs)
        try container.encode(knownDesignerNames, forKey: .knownDesignerNames)
        try container.encode(selectedGoal, forKey: .selectedGoal)
        try container.encodeIfPresent(unknownSelectedGoalToken, forKey: .unknownSelectedGoalToken)
        try container.encode(sickDays, forKey: .sickDays)
        try container.encode(intentDismissedDays, forKey: .intentDismissedDays)
        try container.encode(nutrientBubbleDismissedUntil, forKey: .nutrientBubbleDismissedUntil)
        try container.encode(aiStatus, forKey: .aiStatus)
        try container.encodeIfPresent(unknownAIStatusToken, forKey: .unknownAIStatusToken)
        try container.encode(webNutritionLookupEnabled, forKey: .webNutritionLookupEnabled)
        try container.encode(weatherPromptsEnabled, forKey: .weatherPromptsEnabled)
        try container.encode(showCalories, forKey: .showCalories)
        try container.encode(hasCompletedOnboarding, forKey: .hasCompletedOnboarding)
        try container.encodeIfPresent(periodTrackingVisible, forKey: .periodTrackingVisible)
        try container.encode(didMigratePeriodVisibility, forKey: .didMigratePeriodVisibility)
        try container.encode(intimacyTrackingVisible, forKey: .intimacyTrackingVisible)
        try container.encode(hidePredictions, forKey: .hidePredictions)
        try container.encode(hideFertileWindow, forKey: .hideFertileWindow)
        try container.encode(periodAwareScoringEnabled, forKey: .periodAwareScoringEnabled)
        try container.encode(periodContextPrimerSeen, forKey: .periodContextPrimerSeen)
        try container.encode(stressAwarenessEnabled, forKey: .stressAwarenessEnabled)
        try container.encode(userProfile, forKey: .userProfile)
        try container.encode(nutritionPreferences, forKey: .nutritionPreferences)
        try container.encodeIfPresent(calorieTargetOverride, forKey: .calorieTargetOverride)
        try container.encodeIfPresent(proteinTargetOverride, forKey: .proteinTargetOverride)
        try container.encodeIfPresent(fatTargetOverride, forKey: .fatTargetOverride)
        try container.encode(quickLogItems, forKey: .quickLogItems)
        try container.encode(unknownQuickLogTokens, forKey: .unknownQuickLogTokens)
        try container.encode(homeWidgets, forKey: .homeWidgets)
        try container.encode(unknownHomeWidgetTokens, forKey: .unknownHomeWidgetTokens)
        try container.encode(didMigrateMilestonesFirstAidWidgets, forKey: .didMigrateMilestonesFirstAidWidgets)
        try container.encode(didMigrateMealPhotosWidget, forKey: .didMigrateMealPhotosWidget)
        try container.encode(personalCareTasks, forKey: .personalCareTasks)
        try container.encode(proximityDisplayName, forKey: .proximityDisplayName)
        try container.encode(showProximityDebugTools, forKey: .showProximityDebugTools)
        try container.encode(allowNearbyRecipeShares, forKey: .allowNearbyRecipeShares)
        try container.encode(allowNearbyClothingShares, forKey: .allowNearbyClothingShares)
        try container.encode(allowNearbyHearts, forKey: .allowNearbyHearts)
        try container.encode(heartsAwayDelivery, forKey: .heartsAwayDelivery)
        try container.encode(allowNearbyPresence, forKey: .allowNearbyPresence)
        try container.encode(allowNearbyFriendState, forKey: .allowNearbyFriendState)
        try container.encode(hasPromptedForPresence, forKey: .hasPromptedForPresence)
        try container.encodeIfPresent(shopLastPublishedDayKey, forKey: .shopLastPublishedDayKey)
        try container.encode(companionName, forKey: .companionName)
        try container.encode(workoutProfile, forKey: .workoutProfile)
        try container.encode(workoutLocations, forKey: .workoutLocations)
        try container.encodeIfPresent(activeWorkoutLocationID, forKey: .activeWorkoutLocationID)
        try container.encode(workoutProgression, forKey: .workoutProgression)

        // Re-emit every parked key at the TOP LEVEL (never nested). A parked key can never collide with
        // a known key — decode excludes known keys from `parkedUnknownKeys` — but the `knownKeys` guard
        // makes current-version-wins precedence explicit and defensive. When nothing is parked (every
        // legacy blob) no second container is opened, so the encoded shape gains no parking artifact.
        guard !parkedUnknownKeys.isEmpty else { return }
        let knownKeys = Set(CodingKeys.allCases.map(\.stringValue))
        var dynamicContainer = encoder.container(keyedBy: DynamicCodingKey.self)
        for (key, value) in parkedUnknownKeys where !knownKeys.contains(key) {
            try dynamicContainer.encode(value, forKey: DynamicCodingKey(stringValue: key))
        }
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

/// Device-local record of how THIS device resolved its sensitive-surface (period + intimacy) visibility.
/// Lives in a device-local sidecar (never the synced blob — see `FernletStore`), precisely so a
/// mixed-version peer on a pre-gate build can never rewrite or drop it. `resolved == false` is a
/// genuinely fresh device that has never made a determination; a resolved device carries the last
/// explicit/derived values so it can re-assert them when a peer drops the visibility keys.
public nonisolated struct SensitiveVisibilityResolution: Equatable, Sendable {
    public var resolved: Bool
    /// The last resolved explicit `periodTrackingVisible` override (`nil` == "derive from `sex`").
    public var periodTrackingVisible: Bool?
    public var intimacyTrackingVisible: Bool

    public init(resolved: Bool = false, periodTrackingVisible: Bool? = nil, intimacyTrackingVisible: Bool = true) {
        self.resolved = resolved
        self.periodTrackingVisible = periodTrackingVisible
        self.intimacyTrackingVisible = intimacyTrackingVisible
    }
}

public extension FernletSettings {
    /// Applies the one-time period-visibility pin/derivation AND the mixed-version fail-closed guard,
    /// gated on a DEVICE-LOCAL resolution marker instead of the synced `didMigratePeriodVisibility` alone.
    /// Returns the reconciled settings, the resolution to persist device-locally, and whether the settings
    /// themselves changed (so the caller can schedule a snapshot save). Pure — no I/O.
    ///
    /// A resolution is only ever minted from EVIDENCE of a real determination, never from a pristine
    /// default state. A fresh install's synthesized missing-record database is indistinguishable from a
    /// carefully-defaulted real blob at the value level, and marking it "resolved" would poison the
    /// sidecar: when the real account blob finally syncs in, a pre-gate blob would be met with a
    /// re-assert of pristine values instead of the migration pin — an existing cycle-tracking user
    /// restoring a new phone would silently lose the feature to `sex`'s `.male` default, the exact
    /// failure the pin exists to prevent. Evidence is the marker itself (`didMigratePeriodVisibility ==
    /// true` is only ever written at a real determination — see its declaration) or the pin actually
    /// firing below; explicit local choices mint the resolution at their own seam
    /// (`FernletStore.recordSensitiveVisibilityResolution`).
    ///
    /// - Marker present: a build really determined this state. Trust/adopt its values (a real
    ///   cross-device hide/show reaching a resolved device, or a restored post-gate blob resolving a
    ///   fresh one) and refresh the device-local record.
    /// - Fresh device + marker absent + real prior usage (`hasCompletedOnboarding`): a pre-gate user's
    ///   blob — run the one-time migration: pin an existing cycle user visible so `sex`'s `.male`
    ///   default can't silently hide the feature.
    /// - Fresh device + marker absent + no prior usage: an undetermined blank slate (the synthesized
    ///   default database, or a first launch that hasn't finished onboarding). Change nothing and stay
    ///   genuinely unresolved, so a later sync-in still gets the branch it deserves.
    /// - Resolved device + marker ABSENT: a pre-gate peer re-encoded the synced blob and dropped the
    ///   visibility keys. Re-assert this device's resolved values (fail-closed) — do NOT let the pin
    ///   re-fire to visible / intimacy default back to visible. The marker is stamped back (and a save
    ///   requested) ONLY when the re-asserted values really deviate from the pristine defaults:
    ///   re-encoding a reconstruction of `(nil, visible)` under a `true` marker would launder the
    ///   key-dropped blob into one an up-to-date HIDDEN peer trusts into re-opening, while writing it
    ///   adds no information any decoder wouldn't reconstruct from the absent keys anyway.
    ///
    /// Residual (documented honestly): a genuinely FRESH device receiving a key-dropped blob cannot
    /// distinguish it from a genuine pre-gate account (the blob carries no provenance and the device has
    /// no sidecar), so the pin fires visible and its marker-stamped save can propagate visible to
    /// devices that had resolved hidden — unchanged from the original pin design. Two narrow cases on
    /// fresh devices: a pre-gate user who never finished onboarding gets no pin (harmless — nothing was
    /// trackable before onboarding), and completing onboarding BEFORE the first account pull writes a
    /// marker-true derive/visible blob that resolved-hidden peers trust (last-writer-wins settings; far
    /// narrower than the automatic first-save race this design closes). The previously documented
    /// residual — a fresh install pulling a pre-gate blob re-asserting pristine values instead of
    /// pinning — is FIXED by staying unresolved on the blank slate.
    func reconcilingSensitiveVisibility(
        deviceLocal: SensitiveVisibilityResolution
    ) -> (settings: FernletSettings, resolution: SensitiveVisibilityResolution, settingsChanged: Bool) {
        var reconciled = self
        var settingsChanged = false
        var resolution = deviceLocal

        if reconciled.didMigratePeriodVisibility {
            // A real determination (the marker is never a passive default) — trust/adopt its values.
            resolution = SensitiveVisibilityResolution(
                resolved: true,
                periodTrackingVisible: reconciled.periodTrackingVisible,
                intimacyTrackingVisible: reconciled.intimacyTrackingVisible
            )
        } else if !deviceLocal.resolved {
            if reconciled.hasCompletedOnboarding {
                // A real user's blob with no determination ⇒ pre-gate (or a pre-gate re-encode): the
                // one-time pin. An explicit value, if one somehow survived, outranks the pin.
                if reconciled.periodTrackingVisible == nil { reconciled.periodTrackingVisible = true }
                reconciled.didMigratePeriodVisibility = true
                settingsChanged = true
                resolution = SensitiveVisibilityResolution(
                    resolved: true,
                    periodTrackingVisible: reconciled.periodTrackingVisible,
                    intimacyTrackingVisible: reconciled.intimacyTrackingVisible
                )
            }
            // else: blank slate — nothing was ever determined; stay genuinely unresolved.
        } else {
            // Mixed-version key-drop on a resolved device: re-assert this device's values fail-closed.
            reconciled.periodTrackingVisible = deviceLocal.periodTrackingVisible
            reconciled.intimacyTrackingVisible = deviceLocal.intimacyTrackingVisible
            let reassertsPristineDefaults = deviceLocal.periodTrackingVisible == nil
                && deviceLocal.intimacyTrackingVisible
            if !reassertsPristineDefaults {
                // A real deviation is worth re-writing under the marker so it propagates (and so a
                // hidden choice repairs the synced blob). A pristine reconstruction is NOT stamped —
                // see the laundering note above.
                reconciled.didMigratePeriodVisibility = true
                settingsChanged = true
            }
            resolution = SensitiveVisibilityResolution(
                resolved: true,
                periodTrackingVisible: reconciled.periodTrackingVisible,
                intimacyTrackingVisible: reconciled.intimacyTrackingVisible
            )
        }
        return (reconciled, resolution, settingsChanged)
    }
}

public nonisolated enum AIStatus: String, Codable, Sendable, CaseIterable, Identifiable {
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

/// A minimal, lossless representation of an arbitrary JSON value — the raw material `FernletSettings`
/// parks for the top-level keys it doesn't yet understand (`parkedUnknownKeys`). It invents no
/// semantics and round-trips through `Codable` verbatim. Integers are held exactly as `Int64` (not
/// coerced through `Double`, which silently corrupts values above 2^53 and re-emits large ids in
/// e-notation that a strict `Int64` decode on a newer build then throws on); non-integral and
/// out-of-`Int64`-range numbers stay `Double`. Kept in this file alongside the only thing that uses
/// it. Mirrors the spirit of `EnumDecodeCompat`: preserve what you can't interpret, re-emit it
/// untouched, never fabricate meaning for it.
public nonisolated enum JSONValue: Codable, Hashable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case null
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            // Bool BEFORE the number kinds: a JSON bool must not be swallowed as a number (and a JSON
            // number throws when decoded as Bool, so this order is unambiguous for the stdlib JSON coder).
            self = .bool(value)
        } else if let value = try? container.decode(Int64.self) {
            // Int64 BEFORE Double: an integral value within Int64 range is parked exactly, so a 64-bit
            // id/timestamp above 2^53 round-trips without the precision loss (and without the e-notation
            // re-emit) a Double detour would introduce. Fractional or out-of-range numbers throw the
            // Int64 decode and fall through to Double below.
            self = .integer(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSONValue].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Unsupported JSON value while parking an unknown settings key")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

/// A `CodingKey` that admits any string key — lets `FernletSettings` enumerate the whole top-level
/// container (to find keys with no `CodingKeys` case) and write parked keys back by name. `init(stringValue:)`
/// is non-failable (it satisfies the failable protocol requirement) so the encode site needs no unwrap.
private nonisolated struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
    init(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
}
