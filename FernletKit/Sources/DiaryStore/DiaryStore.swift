import Foundation
import Observation
import FernletFoundation
import FernletDomainModel
import FernletScoring
import FernletPersistence
import FoodCatalog
import StoreCore

/// The portable diary slice carved out of the app's `FernletStore`. Owns the pure diary state
/// (the synced/snapshot value types) and the pure diary methods (scoring, meal/recipe/workout/
/// journal-field/settings/personal-care/load). Holds NO app-only collaborators — those live in
/// the app-side `FernletStore` facade, which owns a `DiaryStore` and forwards to it.
///
/// Injected closures decouple it from the facade so it depends on no app/sealed module:
/// - `scheduleSnapshotSave` replaces every former `snapshotSaveCoordinator.schedule()` call.
/// - `periodAdjustment` replaces the former `periodAdjustment(for:)` body that read the
///   facade-only `PeriodContextBridge`; the facade supplies a closure that applies the opt-in
///   gate. Default `{ _ in .none }` makes scoring byte-identical to period-unaware.
/// - `stressModifier` and `sealedJournalIDs` follow the same pattern (see their hook
///   properties), and ``isAdultVerified`` is the fail-closed intimacy gate the facade sets
///   separately.
///
/// Construction is two-phase because the facade can only build its real closures after this
/// store exists: `init` takes placeholders, then
/// ``rewireHooks(scheduleSnapshotSave:periodAdjustment:stressModifier:sealedJournalIDs:)``
/// swaps in the live ones (an assert makes a forgotten rewire trip loudly in debug).
///
/// Collaborators: reads and writes day rows, tier-two memories, and the full day history
/// through the injected `FernletRepository` (Core Data + iCloud or local JSON, per the user's
/// storage preference); keeps the injected `FoodCatalog`'s user-item index in sync with
/// ``foodItems``; builds saved-recipe meals via `SavedRecipeService`; and resolves
/// recipe-editor ingredients through `CustomIngredientUpsert`.
///
/// Invariants:
/// - Every mutation ends in a `scheduleSnapshotSave()` (directly or via the
///   `batchSnapshotPersistence` wrapper); actual persistence stays with the facade's debounced
///   coordinator, so this store never writes the snapshot itself.
/// - "Today" lives in memory (``day``, keyed by ``todayKey``); every other date round-trips
///   through the repository via ``mutateDay(date:_:)``, and every past-day write is stripped
///   through `SanitizedDay` so sealed journal text and hidden cycle/intimate health context
///   can never reach the (potentially iCloud-synced) blob.
/// - ``foodItems`` never contains USDA catalog rows (filtered at init and on snapshot apply);
///   the bundled catalog is served read-only by `FoodCatalog`.
/// - ``isAdultVerified`` defaults to refusal, so a store built before the facade wires it
///   keeps intimate logging locked rather than open.
///
/// Concurrency: `@MainActor` + `@Observable` (the whole `DiaryStore` target compiles with
/// `defaultIsolation(MainActor.self)`). Observation tracking lives on this class — the facade
/// marks its own forwarding property `@ObservationIgnored` so views observe changes here.
///
/// Failure modes: empty date keys, mutating before `rewireHooks()`, and a failed past-day save
/// all trip `assert`s; in release those guards compile out, so a mis-wired store degrades to
/// dropped saves rather than crashing.
@MainActor
@Observable
public final class DiaryStore {
    /// The mutable in-memory record for "today" (the day keyed by ``todayKey``). Every other
    /// date round-trips through the repository via ``mutateDay(date:_:)``.
    public var day: FernletDay
    /// The synced settings aggregate (goal, visibility gates, workout profile, dismissals, …).
    /// Mutate through the setter methods so every change schedules a snapshot save.
    public var settings: FernletSettings
    /// Rolling newest-first window of recently logged meals (capped at 50 by
    /// ``appendMeal(_:date:)``) that powers quick re-logging.
    public var recentMeals: [Meal]
    /// Journal entries carried over from earlier days. The facade owns sealing/unsealing of
    /// their text; this store only holds the rows.
    public var previousJournals: [JournalEntry]
    /// Long-lived companion memory notes, edited via ``updateMemory(_:category:text:)`` and
    /// ``deleteMemory(_:)``.
    public var memories: [MemoryNote]
    /// The user's fitness goals (capped at 12 by ``replaceGoals(_:)``).
    public var goals: [FitnessGoal]
    /// Workshop content (texture entries) behind the companion-personalization surface.
    public var workshop: WorkshopData
    /// User-created/imported food items — never USDA catalog rows, which are filtered out at
    /// init and on snapshot apply (the catalog serves them read-only). The `didSet` mirrors the
    /// list into ``foodCatalog`` so search sees user items immediately.
    public var foodItems: [FoodItem] {
        didSet { foodCatalog.setUserItems(foodItems) }
    }
    /// The subset of ``foodItems`` that arrived through the web-nutrition import path
    /// (tagged `web-import`).
    public var webImportedFoodItems: [FoodItem] {
        foodItems.filter { $0.tags.contains("web-import") }
    }
    /// Whether the web nutrition lookup may run: requires the explicit settings opt-in AND
    /// AI not being switched off.
    public var allowsWebNutritionLookup: Bool {
        settings.webNutritionLookupEnabled && settings.aiStatus != .off
    }
    /// The user's recipe book, newest-first; mutated only through the add/update/insert/delete
    /// recipe methods.
    public var recipes: [RecipeDefinition]
    /// The persisted per-day score history; ``dailyHealthScore(for:day:)`` prefers a stored
    /// row over recomputing.
    public var dailyScores: [DailyHealthScore]
    /// The companion's current transient thought-bubble text. In-memory only — set without a
    /// save and cleared on relaunch.
    public var companionThought: String?

    /// The store's notion of "today". Pinned at construction, but ADVANCEABLE via `advanceCurrentDay`
    /// so a process that stays resident across local midnight can roll over in place instead of filing
    /// new logs under the launch day. `private(set)` keeps every external reader read-only (the mutation
    /// only happens through the guarded rollover seam); still `@ObservationIgnored` because the rollover
    /// reassigns `day` (which IS observed) in the same breath, so dependent views re-render off that.
    @ObservationIgnored public private(set) var todayKey: String
    /// The persistence backend (Core Data + iCloud or local JSON, per the user's storage
    /// preference). Past-day rows, tier-two memories, and the full day history live here.
    @ObservationIgnored public let repository: FernletRepository
    /// The bundled USDA + user-item food search service, kept in sync with ``foodItems``
    /// via that property's `didSet`.
    @ObservationIgnored public let foodCatalog: FoodCatalog
    /// Facade-supplied debounced snapshot-save closure (the former
    /// `snapshotSaveCoordinator.schedule()`). An init placeholder until `rewireHooks` runs.
    @ObservationIgnored private var scheduleSnapshotSaveHook: () -> Void
    /// Facade-supplied, pre-gated period scoring adjustment for a day key (the facade applies
    /// the period-aware-scoring opt-in). Returns `.none` until `rewireHooks` runs.
    @ObservationIgnored private var periodAdjustmentHook: (String) -> PeriodScoringAdjustment
    /// Facade-supplied, pre-gated stress scoring modifier for a day (the stress twin of
    /// `periodAdjustmentHook`). The facade applies the `stressAwarenessEnabled` opt-in and the
    /// today-only gate; the default `{ _ in 0 }` keeps scoring byte-identical to stress-unaware.
    @ObservationIgnored private var stressModifierHook: (String) -> Double = { _ in 0 }
    /// Facade-supplied set of journal-entry ids whose plaintext is sealed in the encrypted narrative
    /// store. Read by `mutatePastDay` to strip sealed text before a past-day write reaches the
    /// (potentially iCloud-synced) repository — the past-day analogue of `FernletSnapshot.forStorage`.
    /// Defaults to empty for the brief init→rewireHooks window (no past-day writes happen there).
    @ObservationIgnored private var sealedJournalIDsHook: () -> Set<UUID> = { [] }
    /// Set true by `rewireHooks` once the facade wires the real persistence/period/sealed closures over
    /// the `{ }`/`.none` init placeholders. `scheduleSnapshotSave()` asserts on it so a future
    /// constructor that copies the build-then-rewire pattern but forgets to rewire trips loudly in
    /// debug/test instead of silently dropping every save.
    @ObservationIgnored private var hooksRewired = false

    /// Invokes the facade-supplied snapshot-save hook. Replaces every former
    /// `snapshotSaveCoordinator.schedule()` call in the carved methods.
    func scheduleSnapshotSave() {
        assert(hooksRewired, "DiaryStore mutated before rewireHooks() — the persistence hook is still the init placeholder, so this save would be silently dropped. Call rewireHooks() right after construction.")
        scheduleSnapshotSaveHook()
    }

    /// Invokes the facade-supplied period-adjustment gate. Replaces the former inline
    /// `periodAdjustment(for:)` body that read the facade-only `PeriodContextBridge`.
    func periodAdjustment(_ dayKey: String) -> PeriodScoringAdjustment { periodAdjustmentHook(dayKey) }

    /// Invokes the facade-supplied stress-modifier gate (0 unless the opt-in is on and the
    /// facade has a stress context attached).
    func stressModifier(_ dayKey: String) -> Double { stressModifierHook(dayKey) }

    /// Re-points the injected hooks at the facade after the facade has constructed `self`.
    /// Needed because the closures must capture the facade weakly, but the facade can only build
    /// them after the DiaryStore (which it stores in a `let`) exists — avoiding an init-order cycle.
    public func rewireHooks(
        scheduleSnapshotSave: @escaping () -> Void,
        periodAdjustment: @escaping (String) -> PeriodScoringAdjustment,
        stressModifier: @escaping (String) -> Double = { _ in 0 },
        sealedJournalIDs: @escaping () -> Set<UUID>
    ) {
        self.scheduleSnapshotSaveHook = scheduleSnapshotSave
        self.periodAdjustmentHook = periodAdjustment
        self.stressModifierHook = stressModifier
        self.sealedJournalIDsHook = sealedJournalIDs
        self.hooksRewired = true
    }

    /// Builds the diary slice from a loaded snapshot.
    ///
    /// USDA-sourced rows are filtered out of `snapshot.foodItems` (the bundled catalog serves
    /// them read-only) and the surviving user items are pushed into `foodCatalog` for search.
    /// When the facade can only build its real closures after this store exists, pass
    /// placeholders and call
    /// ``rewireHooks(scheduleSnapshotSave:periodAdjustment:stressModifier:sealedJournalIDs:)``
    /// immediately afterward.
    ///
    /// - Parameters:
    ///   - snapshot: The loaded aggregate whose diary fields seed the store.
    ///   - todayKey: The local day key to treat as "today" (advanced later only via
    ///     ``advanceCurrentDay(to:)``).
    ///   - repository: The persistence backend for past-day rows and tier-two memories.
    ///   - foodCatalog: The food search service kept in sync with ``foodItems``.
    ///   - scheduleSnapshotSave: Debounced-save hook (normally the facade's snapshot coordinator).
    ///   - periodAdjustment: Pre-gated period scoring modifier for a day key; the `.none`
    ///     default keeps scoring byte-identical to period-unaware.
    public init(
        snapshot: FernletSnapshot,
        todayKey: String,
        repository: FernletRepository,
        foodCatalog: FoodCatalog,
        scheduleSnapshotSave: @escaping () -> Void,
        periodAdjustment: @escaping (String) -> PeriodScoringAdjustment = { _ in .none }
    ) {
        self.todayKey = todayKey
        self.repository = repository
        self.foodCatalog = foodCatalog
        self.scheduleSnapshotSaveHook = scheduleSnapshotSave
        self.periodAdjustmentHook = periodAdjustment
        self.day = snapshot.day
        self.settings = snapshot.settings
        self.recentMeals = snapshot.recentMeals
        self.previousJournals = snapshot.previousJournals
        self.memories = snapshot.memories
        self.goals = snapshot.goals
        self.workshop = snapshot.workshop
        self.foodItems = snapshot.foodItems.filter { $0.source != .usda }
        self.recipes = snapshot.recipes
        self.dailyScores = Self.boundedDailyScores(snapshot.dailyScores)
        self.companionThought = nil
        foodCatalog.setUserItems(foodItems)
    }

    // MARK: - Scoring
    //
    // NOTE (deviation): the live `score` getter + `companionState` STAY IN THE FACADE. They read
    // `derivedSignals`, which is owned by the facade-side (snapshot-wired) `DerivedSignalsService`;
    // moving them here would require a cached seam that risks observation staleness. The pure
    // per-day scoring (`scoreBreakdown`/`score(for:)`/`dailyHealthScore`) — which does NOT touch
    // derived signals — lives here. The facade's `score`/`companionState` read `diary` props +
    // facade `derivedSignals`, preserving identical behavior.

    /// Today's protein/carbs/fat, summed over ``day``'s meals.
    public var macroTotals: MacroTotals {
        day.meals.reduce(into: MacroTotals()) { partial, meal in
            partial.protein += meal.macros.protein
            partial.carbs += meal.macros.carbs
            partial.fat += meal.macros.fat
        }
    }

    /// Today's micronutrients, summed over ``day``'s meal snapshots.
    public var micronutrientTotals: Micronutrients {
        day.meals.reduce(into: Micronutrients()) { partial, meal in
            partial.add(meal.micronutrientSnapshot)
        }
    }

    /// The daily nutrition targets derived from the current profile/settings via
    /// `NutritionTargetCalculator`.
    public var nutritionTargets: NutritionTargets {
        NutritionTargetCalculator.targets(for: settings)
    }

    /// Computes the full per-component score breakdown for a day — the pure seam over
    /// `FernletScoring.computeBreakdown`, fed with the day's logs, the settings-derived goal
    /// weights, and the pre-gated period/stress modifiers from the facade hooks.
    public func scoreBreakdown(for targetDay: FernletDay) -> ScoreBreakdown {
        let body = targetDay.healthContext?.body
        let activity = targetDay.healthContext?.activity
        return FernletScoring.computeBreakdown(
            journalTag: targetDay.journals.last?.tag,
            mealCount: targetDay.meals.count,
            workoutCount: targetDay.workouts.count,
            sleepQuality: targetDay.sleep?.quality,
            bottleCount: targetDay.bottleCount,
            hydrationTarget: settings.hydrationTarget,
            hygiene: targetDay.hygiene,
            hygieneTaskCount: personalCareTasks.count,
            completedPersonalCareTaskCount: personalCareProgress(for: targetDay).completed,
            weights: GoalWeights.forGoal(settings.selectedGoal),
            isSick: isSick(on: targetDay.date),
            micronutrientDataCoverageRatio: FernletScoring.micronutrientDataCoverageRatio(for: targetDay.meals),
            sleepHours: body?.sleepHours,
            sleepStages: body?.sleepStages,
            activitySteps: activity?.steps,
            activeEnergyKilocalories: activity?.activeEnergyKilocalories,
            exerciseMinutes: activity?.exerciseMinutes,
            periodAdjustment: periodAdjustment(targetDay.date),
            stressModifier: stressModifier(targetDay.date)
        )
    }

    /// The overall wellbeing score for a day (the `overall` component of
    /// ``scoreBreakdown(for:)``).
    public func score(for targetDay: FernletDay) -> Double {
        scoreBreakdown(for: targetDay).overall
    }

    /// The `DailyHealthScore` for `dateKey`: the stored row from ``dailyScores`` when one is
    /// cached, else a freshly computed one (score, companion state, weights, period-phase
    /// label, health context) that is NOT stored — callers decide whether it enters the history.
    public func dailyHealthScore(for dateKey: String, day targetDay: FernletDay) -> DailyHealthScore {
        assert(!dateKey.isEmpty, "date key required")
        if let stored = dailyScores.first(where: { $0.dateKey == dateKey }) {
            return stored
        }
        let sick = isSick(on: targetDay.date)
        let breakdown = scoreBreakdown(for: targetDay)
        return DailyHealthScore(
            dateKey: dateKey,
            score: breakdown.overall,
            companionState: FernletScoring.state(for: breakdown.overall, isSick: sick),
            daySummaryText: nil,
            computedAt: Date(),
            componentScores: breakdown.components,
            weightVector: breakdown.appliedWeights,
            sicknessOverride: sick,
            periodPhase: periodAdjustment(targetDay.date).phase.persistedLabel,
            healthActivityContext: targetDay.healthContext?.activity,
            healthBodyContext: targetDay.healthContext?.body
        )
    }

    // MARK: - Personal care

    /// The personal-care task list from settings, normalized via `PersonalCareTask.normalized`.
    public var personalCareTasks: [PersonalCareTask] {
        PersonalCareTask.normalized(settings.personalCareTasks)
    }

    /// Completed/total personal-care task counts for `targetDay` (today when nil).
    public func personalCareProgress(for targetDay: FernletDay? = nil) -> (completed: Int, total: Int) {
        let activeDay = targetDay ?? day
        let tasks = personalCareTasks
        let completed = tasks.filter { isPersonalCareTaskCompleted($0, in: activeDay) }.count
        return (completed, tasks.count)
    }

    /// Whether `task` is done in `targetDay` (today when nil): checked off by id, or — for
    /// default tasks — present in the day's legacy `hygiene` set.
    public func isPersonalCareTaskCompleted(_ task: PersonalCareTask, in targetDay: FernletDay? = nil) -> Bool {
        let activeDay = targetDay ?? day
        if activeDay.completedPersonalCareTaskIDs.contains(task.id) { return true }
        if let item = task.defaultHygieneItem {
            return activeDay.hygiene.contains(item)
        }
        return false
    }

    // MARK: - Day summary / companion thought

    /// Caches a generated day summary (trimmed, capped at 300 characters) on the day's score
    /// row, minting the row first if the day has no stored score yet. Empty text is ignored.
    public func storeDaySummary(_ text: String, for dateKey: String) {
        assert(!dateKey.isEmpty, "date key required")
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        guard !trimmed.isEmpty else { return }
        batchSnapshotPersistence {
            if let index = dailyScores.firstIndex(where: { $0.dateKey == dateKey }) {
                dailyScores[index].daySummaryText = trimmed
            } else {
                let targetDay = loadDay(for: dateKey)
                var healthScore = dailyHealthScore(for: dateKey, day: targetDay)
                healthScore.daySummaryText = trimmed
                dailyScores.append(healthScore)
                dailyScores = Self.boundedDailyScores(dailyScores)   // R3: bounded growth
            }
        }
    }

    /// Clears the cached day summary for `dateKey` so it regenerates after the day's content
    /// changes (called by every meal/workout append and removal).
    public func invalidateDaySummary(for dateKey: String) {
        assert(!dateKey.isEmpty, "date key required")
        guard let index = dailyScores.firstIndex(where: { $0.dateKey == dateKey }) else { return }
        dailyScores[index].daySummaryText = nil
        scheduleSnapshotSave()
    }

    /// Sets the transient companion thought (trimmed; empty text ignored). Never persisted.
    public func storeCompanionThought(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionThought = trimmed
    }

    /// Human-readable description of where diary data is stored, from the active repository.
    public var storageLocation: String {
        repository.storageDescription()
    }

    /// Fail-closed adult gate, injected because the determination behind it is a device-local Apple
    /// Account signal that deliberately never rides the synced settings blob (see `AgeAssuranceRecord`).
    /// Same contract as `IntimacyLogStore.isVisible`: the default REFUSES, so a store built before the
    /// facade wires it is locked rather than open.
    ///
    /// This used to read `settings.userProfile.age >= 18`, which was self-attested and defaulted to 30 —
    /// a minor unlocked intimacy tracking by leaving the onboarding stepper alone. That profile age still
    /// exists and still feeds the nutrition targets; it just no longer gates anything.
    @ObservationIgnored public var isAdultVerified: () -> Bool = { false }

    /// Whether intimate-activity logging is available — a direct read of the fail-closed
    /// ``isAdultVerified`` gate.
    public var isIntimateLoggingAllowed: Bool {
        isAdultVerified()
    }

    // MARK: - Settings toggles

    /// Persists the goal chosen from the Settings/onboarding preset cards. Mirrors the other setters:
    /// set the keypath then schedule the debounced snapshot save — a bare `settings.selectedGoal =`
    /// binding mutated memory but never scheduled a save, so the choice reverted on the next launch.
    public func setSelectedGoal(_ goal: GoalType) {
        settings.selectedGoal = goal
        scheduleSnapshotSave()
    }

    /// Persists the "hide cycle predictions" display toggle.
    public func setHidePredictions(_ hidePredictions: Bool) {
        settings.hidePredictions = hidePredictions
        scheduleSnapshotSave()
    }

    /// Persists the "hide fertile window" display toggle.
    public func setHideFertileWindow(_ hideFertileWindow: Bool) {
        settings.hideFertileWindow = hideFertileWindow
        scheduleSnapshotSave()
    }

    /// Persists the opt-in that lets period context adjust daily scoring.
    public func setPeriodAwareScoringEnabled(_ enabled: Bool) {
        settings.periodAwareScoringEnabled = enabled
        scheduleSnapshotSave()
    }

    /// Sets the hard cycle-visibility gate. Always writes an explicit value: once the user has made a
    /// choice it must outrank `sex`, including when they choose the same value `sex` would have
    /// derived (otherwise a later HealthKit sex auto-import would silently overturn them).
    public func setPeriodTrackingVisible(_ visible: Bool) {
        settings.periodTrackingVisible = visible
        // An explicit choice IS a real visibility determination — stamp the migration marker (minted
        // only at real determinations, see its declaration) so the saved blob is one other devices
        // may trust rather than treat as undetermined.
        settings.didMigratePeriodVisibility = true
        // The caller is responsible for scrubbing resident cycle state — see
        // `FernletStore.setPeriodTrackingVisible`. This layer cannot reach the period store.
        scheduleSnapshotSave()
    }

    /// Sets the hard intimacy-visibility gate. Like ``setPeriodTrackingVisible(_:)``, an
    /// explicit user choice must outrank derivation, so it stamps the migration marker.
    public func setIntimacyTrackingVisible(_ visible: Bool) {
        settings.intimacyTrackingVisible = visible
        // Same contract as `setPeriodTrackingVisible`: an explicit choice stamps the marker.
        settings.didMigratePeriodVisibility = true
        scheduleSnapshotSave()
    }

    /// Nils the health-context dimensions the user has hidden. Necessary because
    /// `HealthDailyContext.merge` coalesces with `other.x ?? x`: simply not fetching a dimension
    /// FREEZES its last value rather than clearing it, so a day that recorded cycle data before the
    /// user hid the feature would keep serving it indefinitely.
    public func scrubHiddenHealthContext(periodVisible: Bool, intimacyVisible: Bool) {
        guard var context = day.healthContext else { return }
        var changed = false
        if !periodVisible, context.cycle != nil {
            context.cycle = nil
            changed = true
        }
        if !intimacyVisible, context.intimate != nil {
            context.intimate = nil
            changed = true
        }
        guard changed else { return }
        day.healthContext = context
        scheduleSnapshotSave()
    }

    /// Persists the opt-in that lets stress context adjust daily scoring.
    public func setStressAwarenessEnabled(_ enabled: Bool) {
        settings.stressAwarenessEnabled = enabled
        scheduleSnapshotSave()
    }

    /// Records that the one-time period-context primer was shown (saves only on the first call).
    public func markPeriodContextPrimerSeen() {
        guard !settings.periodContextPrimerSeen else { return }
        settings.periodContextPrimerSeen = true
        scheduleSnapshotSave()
    }

    /// Persists the companion's chosen appearance.
    public func setCompanionAppearance(_ appearance: CompanionAppearance) {
        settings.companionAppearance = appearance
        scheduleSnapshotSave()
    }

    /// Persists the companion's name.
    public func setCompanionName(_ name: String) {
        settings.companionName = name
        scheduleSnapshotSave()
    }

    // MARK: - Custom items: equip state + designer identity
    // The items themselves live in `CustomItemService` (their own per-row store). Only the equipped-slot
    // map and the device's anonymous designer id are settings-sized render/identity state kept here.

    /// Equips `id` in `slot` (replacing whatever was there).
    public func equipCustomItem(id: UUID, slot: ItemSlot) {
        settings.equippedItemIDsBySlot[slot.rawValue] = id
        scheduleSnapshotSave()
    }

    /// Removes whatever is equipped in `slot`.
    public func unequipSlot(_ slot: ItemSlot) {
        settings.equippedItemIDsBySlot.removeValue(forKey: slot.rawValue)
        scheduleSnapshotSave()
    }

    /// Clears `itemID` from every slot it was equipped in (called after the item is deleted from its store).
    public func clearEquipReferences(forItemID itemID: UUID) {
        let before = settings.equippedItemIDsBySlot
        settings.equippedItemIDsBySlot = before.filter { $0.value != itemID }
        if settings.equippedItemIDsBySlot.count != before.count {
            scheduleSnapshotSave()
        }
    }

    /// This device's anonymous, stable designer id. Pure read — safe to call during SwiftUI rendering.
    /// `ensureLocalDesignerID()` is invoked once at store construction so the stored value is non-nil by
    /// the time any view reads it; the `??` is only a defensive fallback and never mutates state.
    public var localDesignerID: UUID {
        settings.localDesignerID ?? ensureLocalDesignerID()
    }

    /// Generates and persists the device's designer id if it doesn't exist yet, and records it in the
    /// `ownedDesignerIDs` set that `isSelfDesigned` consults. Call once at store startup — NOT from a view
    /// body — so the lazy mint never runs mid-render.
    @discardableResult
    public func ensureLocalDesignerID() -> UUID {
        let id = settings.localDesignerID ?? UUID()
        var changed = false
        if settings.localDesignerID == nil {
            settings.localDesignerID = id
            changed = true
        }
        if settings.ownedDesignerIDs.insert(id).inserted {
            changed = true
        }
        if changed { scheduleSnapshotSave() }
        return id
    }

    /// Records the display name learned for a designer id (from an in-person connection). Empty names clear.
    public func setKnownDesignerName(id: UUID, name: String) {
        // Sanitize the (untrusted, peer-supplied) name before it enters the synced settings blob: drop
        // control / zero-width / bidi-override scalars, collapse whitespace, and cap length — the same wire
        // boundary the item name goes through. Without this a hostile peer could poison the id→name map with
        // a multi-kilobyte or control-character string that then syncs across the user's own devices.
        let sanitized = ItemNameModeration.sanitizedName(name)
        let key = id.uuidString
        if sanitized.isEmpty {
            settings.knownDesignerNames.removeValue(forKey: key)
        } else {
            // Bound the map's CARDINALITY, not just each name's length. This map is fed by browsing (no
            // purchase required), so a hostile peer cycling disconnect/reconnect with a fresh random
            // designerID each time would otherwise add one permanent entry per cycle, growing the synced
            // settings blob without bound toward CloudKit's ~1 MB per-record limit (after which snapshot
            // saves start failing). Cap at 256 — far more than any realistic number of real friends — and
            // when a NEW id would exceed it, evict one existing entry so the map stays bounded. Updating an
            // EXISTING id's name never grows the map, so it never evicts. `SettingsModel` carries no recency
            // for these entries (plain [String: String]), so eviction is deterministic-but-arbitrary: drop
            // the lexicographically-smallest key. That is stable (never process-order-dependent), never
            // throws, and stays Codable/merge-safe (still a plain dictionary).
            let isNew = settings.knownDesignerNames[key] == nil
            if isNew, settings.knownDesignerNames.count >= Self.maxKnownDesignerNames,
               let evictKey = settings.knownDesignerNames.keys.min() {
                settings.knownDesignerNames.removeValue(forKey: evictKey)
            }
            settings.knownDesignerNames[key] = sanitized
        }
        scheduleSnapshotSave()
    }

    /// Upper bound on learned peer designer names kept in the synced settings blob. 256 is far above any
    /// realistic friend count while keeping the id→name map a tiny fraction of CloudKit's ~1 MB record
    /// budget, so a hostile peer cannot grow the synced aggregate without bound. See `setKnownDesignerName`.
    public static let maxKnownDesignerNames = 256

    /// Upper bound on the per-day score rows kept in ``dailyScores`` (R3: bounded growth).
    ///
    /// Every row carries a component-score dictionary, a weight vector and the day's activity/body
    /// context, and the whole array rides the SINGLE aggregate blob record — the same ~1 MB CloudKit
    /// per-record wall ``maxKnownDesignerNames`` exists to stay under. Matched to the rolling window
    /// the derived tables use (`FernletLimits.derivedLogWindowDays`), restated here because
    /// `DiaryStore` deliberately does not depend on `LocalPersistence`.
    public static let maxDailyScoreDays = 370

    /// Newest-first trim of a day-score history to ``maxDailyScoreDays`` — applied wherever the
    /// array is installed (launch, sync apply) or appended to, so no path can reinstate an
    /// unbounded array.
    static func boundedDailyScores(_ scores: [DailyHealthScore]) -> [DailyHealthScore] {
        guard scores.count > maxDailyScoreDays else { return scores }
        return Array(scores.sorted { $0.dateKey > $1.dateKey }.prefix(maxDailyScoreDays))
    }

    /// Upper bound on the day keys retained by the per-day settings maps (`sickDays`,
    /// `intentDismissedDays`), which live in the synced settings blob and are only ever read for
    /// recent days. Same window as ``maxDailyScoreDays``.
    static let maxTrackedDayKeys = 370

    /// Upper bound on distinct exercise NAMES tracked in `settings.workoutProgression`. Names are
    /// free text from the workout editor, so the map's cardinality is user-input driven; without a
    /// cap a name typed once is retained forever in the synced settings blob.
    public static let maxTrackedExerciseNames = 512

    /// Records the calendar day the user last changed their shop's listed set (drives the gentle
    /// once-per-day re-publish note). Stored in the synced settings blob, so it's shared across the user's
    /// own devices.
    public func setShopLastPublishedDay(_ dayKey: String) {
        settings.shopLastPublishedDayKey = dayKey
        scheduleSnapshotSave()
    }

    /// Day keys that carry any logged content — the active days that the coin ledger credits. Computed
    /// over the full day history (`loadDays()`), so it is the reconcile input, not a per-render read.
    public func activeDayKeys() -> Set<String> {
        Set(loadDays().compactMap { $0.value.hasLoggedContent ? $0.key : nil })
    }

    /// Persists the (trimmed) display name advertised to nearby peers on the proximity mesh.
    public func setProximityDisplayName(_ name: String) {
        settings.proximityDisplayName = name.trimmingCharacters(in: .whitespaces)
        scheduleSnapshotSave()
    }

    /// Persists the developer toggle that reveals the proximity debug tools.
    public func setShowProximityDebugTools(_ value: Bool) {
        settings.showProximityDebugTools = value
        scheduleSnapshotSave()
    }

    /// Persists the home-screen widget arrangement, normalized via `HomeWidget.normalized`.
    public func setHomeWidgets(_ widgets: [HomeWidget]) {
        settings.homeWidgets = HomeWidget.normalized(widgets)
        scheduleSnapshotSave()
    }

    /// Persists the quick-log shortcut list, normalized via `FernletShortcut.normalizedQuickLog`.
    public func setQuickLogItems(_ items: [FernletShortcut]) {
        settings.quickLogItems = FernletShortcut.normalizedQuickLog(items)
        scheduleSnapshotSave()
    }

    // MARK: - Meals (pure)

    /// Pure meal append: mutates the day, invalidates the cached day summary, and tracks the recent
    /// meals window. The facade's public `addMeal`/`commitResolution`/`logSavedRecipe`/web-import
    /// log call this AFTER any coordinator enrichment.
    public func appendMeal(_ meal: Meal, date: String) {
        assert(!date.isEmpty, "meal date required")
        batchSnapshotPersistence {
            mutateDay(date: date) { $0.meals.append(meal) }
            invalidateDaySummary(for: date)
            recentMeals.insert(meal, at: 0)
            recentMeals = Array(recentMeals.prefix(50))
        }
    }

    /// Duplicates a past meal onto today (fresh identity via `copyForToday`) and returns the copy.
    @discardableResult public func copyMeal(_ meal: Meal) -> Meal {
        let copiedMeal = meal.copyForToday()
        batchSnapshotPersistence {
            day.meals.append(copiedMeal)
        }
        return copiedMeal
    }

    // NOTE (deviation): `updateMealCorrection`, `logRecipe`, `macroTotals(for:)`,
    // `micronutrientTotals(for:)`, and the `correctedNutrition`/`applyMealCorrection` helpers STAY
    // IN THE FACADE. They use `MealBuilder`, which is still an APP-TARGET type
    // (`Fernlet/MealBuilder.swift`), not the portable FoodCatalog module — the classification's
    // "MealBuilder | FoodCatalog | YES" row was incorrect (its carve to FoodCatalog is future work,
    // per the AIProviders Package.swift note). `appendMeal` is the diary's pure write seam the
    // facade calls after building the MealBuilder-derived meal.

    /// Links a stored meal photo to today's meal with `mealID` (no-op if the meal is gone).
    /// Only the photo id rides the synced blob — the bytes stay in the sealed media store.
    public func attachMealPhoto(mealID: UUID, photoID: UUID) {
        batchSnapshotPersistence {
            if let index = day.meals.firstIndex(where: { $0.id == mealID }) {
                day.meals[index].photoID = photoID
            }
        }
    }

    /// Logs a saved recipe as a meal (built by `SavedRecipeService.makeMeal`) on `date`
    /// (today when nil) and returns it.
    @discardableResult public func logSavedRecipe(_ recipe: RecipeDefinition, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "saved recipe meal date required")
        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: mealType)
        appendMeal(meal, date: targetDate)
        return meal
    }

    /// Logs a previously web-imported product as a one-serving meal with truthful
    /// web-import provenance.
    @discardableResult public func logWebImportedFoodProduct(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        logFoodItemMeal(
            foodItem, mealType: mealType, date: date,
            confidence: "Saved product", note: "Logged from saved product.", source: MealLogSource.webImport
        )
    }

    /// Logs a product resolved from a barcode scan (user-item pairing or a barcode-carrying catalog)
    /// as a single meal. `servings` scales the known per-serving macros/micros and is persisted as a
    /// single editable component (see `logFoodItemMeal`) so the count can be corrected later.
    @discardableResult public func logBarcodeScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil, servings: Double = 1) -> Meal {
        logFoodItemMeal(
            foodItem, mealType: mealType, date: date,
            confidence: "Scanned product", note: "Logged from a barcode scan.", source: MealLogSource.barcodeScan,
            servings: servings
        )
    }

    /// Logs a product whose macros came from a scanned nutrition label (the photo-capture label path)
    /// as a single meal — truthful label-scan provenance. `servings` scales the per-serving macros/micros
    /// and is persisted as a single editable component so the count can be corrected later.
    @discardableResult public func logLabelScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil, servings: Double = 1) -> Meal {
        logFoodItemMeal(
            foodItem, mealType: mealType, date: date,
            confidence: "Scanned label", note: "Logged from a nutrition label scan.", source: MealLogSource.labelScan,
            servings: servings
        )
    }

    /// Logs the curated good-source food behind the F2 micronutrient nudge as a single serving.
    /// Grounds the meal in the pinned catalog `FoodItem` (real macros + the actual micronutrient
    /// profile that carries the nudged nutrient) — the same known-food shape as the barcode/label
    /// paths — instead of re-parsing the display name as free text, which would fabricate macros and
    /// bind an arbitrary branded row that often carries none of the nudged nutrient.
    @discardableResult public func logNutrientSuggestionFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        logFoodItemMeal(
            foodItem, mealType: mealType, date: date,
            confidence: "Suggested food", note: "Added from a gentle nutrient nudge.", source: MealLogSource.manual
        )
    }

    /// A logged meal always represents food that was actually eaten, so zero (or negative) is never
    /// a meaningful amount. Non-positive counts fall back to ONE serving — the same default the log
    /// methods already declare — rather than to an epsilon: `Macros` fields are `Int`, so a 0.01
    /// floor would still round every macro to zero and leave the row "contributing nothing", which
    /// is half the defect. Clamped rather than refused, so a bad count still yields a usable,
    /// correctable row. Positive fractional counts pass through exactly.
    static func normalizedServings(_ servings: Double) -> Double {
        servings > 0 ? servings : 1
    }

    /// Shared "one serving of this known food" meal construction for the product-shaped log paths.
    ///
    /// `servings` is `nil` for the saved-product / nutrient-nudge paths — those keep the original
    /// one-serving, no-component shape exactly. The scan paths pass an explicit count (default 1):
    /// the per-serving macros/micros are scaled by it AND persisted as a single `.serving` component,
    /// so the meal opens the component editor and the count stays correctable via MealCorrectionSheet.
    /// The component's macros/micros are the already-scaled totals (the convention every consumer of
    /// `MealComponentSnapshot` relies on — `MealBuilder.totals` sums them directly).
    private func logFoodItemMeal(_ foodItem: FoodItem, mealType: MealType?, date: String?, confidence: String, note: String, source: String, servings: Double? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "food product meal date required")
        let loggedMacros: Macros
        let loggedMicros: Micronutrients
        let components: [MealComponentSnapshot]
        if let servings {
            // Non-positive counts are normalized, not merely floored at zero: `max(servings, 0)`
            // let a 0 through, which writes a meal row contributing nothing and showing
            // "0 servings" in the correction sheet. The one current UI path is protected only
            // because its save bar disables at <= 0, so the invariant belongs here, where the data
            // is written (review finding, 2026-07-27).
            let count = Self.normalizedServings(servings)
            loggedMacros = foodItem.macros.scaled(by: count)
            loggedMicros = foodItem.micronutrients.scaled(by: count)
            components = [
                MealComponentSnapshot(
                    foodItemId: foodItem.id,
                    name: foodItem.name,
                    quantity: count,
                    unit: RecipeUnit.serving.rawValue,
                    macros: loggedMacros,
                    micronutrients: loggedMicros
                )
            ]
        } else {
            loggedMacros = foodItem.macros
            loggedMicros = foodItem.micronutrients
            components = []
        }
        let meal = Meal(
            name: foodItem.name,
            mealType: mealType ?? MealParser.classifyMealType(foodItem.name),
            macros: loggedMacros,
            micronutrientSnapshot: loggedMicros,
            componentSnapshots: components,
            mealSource: .manual,
            // Quality tracks the food's inherent per-serving protein, not how much was logged.
            quality: foodItem.macros.protein >= Macros.goodProteinThreshold ? .good : .ok,
            confidence: confidence,
            note: note,
            source: source
        )
        appendMeal(meal, date: targetDate)
        return meal
    }

    // MARK: - Workouts (pure)

    /// Pure workout append: mutates the day + invalidates the cached day summary. The facade's
    /// public `addWorkout` calls this THEN runs the HealthKit save side-effect. WorkoutSyncContext
    /// `upsertWorkout` (facade) routes here directly to avoid re-triggering the HK save for
    /// HealthKit-imported workouts.
    public func appendWorkout(_ workout: Workout, date: String) {
        assert(!date.isEmpty, "workout date required")
        batchSnapshotPersistence {
            mutateDay(date: date) { $0.workouts.append(workout) }
            invalidateDaySummary(for: date)
        }
    }

    /// Pure workout removal by id: mirrors `appendWorkout` (mutate the day + invalidate the cached
    /// summary). The facade's `removeWorkout` runs the guided/planned/progression reversal around this.
    /// Returns whether a row was actually removed.
    // R7 exception: App/Fernlet/FernletStore.swift:2489 and :5316 still call this for effect; the
    // attribute can only be removed together with those out-of-slice call sites.
    @discardableResult
    public func removeWorkout(id: UUID, date: String) -> Bool {
        assert(!date.isEmpty, "workout date required")
        var removed = false
        batchSnapshotPersistence {
            mutateDay(date: date) { day in
                let before = day.workouts.count
                day.workouts.removeAll { $0.id == id }
                removed = day.workouts.count != before
            }
            if removed { invalidateDaySummary(for: date) }
        }
        return removed
    }

    /// Pure workout replace-by-id (edit). Mirrors `appendWorkout`; invalidates the cached summary.
    /// Returns whether a matching row was found and replaced. Provenance is the caller's responsibility
    /// — the facade re-asserts the fields the edit UI can't reach before calling here.
    public func updateWorkout(_ workout: Workout, date: String) -> Bool {
        assert(!date.isEmpty, "workout date required")
        var replaced = false
        batchSnapshotPersistence {
            mutateDay(date: date) { day in
                if let index = day.workouts.firstIndex(where: { $0.id == workout.id }) {
                    day.workouts[index] = workout
                    replaced = true
                }
            }
            if replaced { invalidateDaySummary(for: date) }
        }
        return replaced
    }

    /// Upserts a planned workout on `date` (replace-by-id), keeping the day's plan ordered by
    /// creation time.
    public func planWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        assert(!date.isEmpty, "planned workout date required")
        mutateDay(date: date) { day in
            day.plannedWorkouts.removeAll { $0.id == plannedWorkout.id }
            day.plannedWorkouts.append(plannedWorkout)
            day.plannedWorkouts.sort { $0.createdAt < $1.createdAt }
        }
    }

    /// The split to pre-select when planning on `date`: the same day's latest planned split if
    /// one exists, else the most recent earlier day's.
    public func copiedForwardWorkoutSplit(before date: String) -> WorkoutSplit? {
        assert(!date.isEmpty, "planned workout date required")
        let days = loadDays()
        if let sameDaySplit = days[date]?.plannedWorkouts.last?.split {
            return sameDaySplit
        }
        return days
            .filter { $0.key < date }
            .sorted { $0.key > $1.key }
            .compactMap { $0.value.plannedWorkouts.last?.split }
            .first
    }

    /// The first planned workout exactly seven days before `date`, if any — the copy-forward
    /// source for weekly repeats.
    public func previousWeekPlannedWorkout(for date: String) -> PlannedWorkout? {
        assert(!date.isEmpty, "planned workout date required")
        guard let targetDate = FernletDate.date(fromDayKey: date),
              let previousWeekDate = Calendar.current.date(byAdding: .day, value: -7, to: targetDate) else {
            return nil
        }
        let previousWeekKey = FernletDate.dayKey(for: previousWeekDate)
        return loadDay(for: previousWeekKey).plannedWorkouts.first
    }

    /// Removes a planned workout from `date`'s plan (no-op if absent).
    public func deletePlannedWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        assert(!date.isEmpty, "planned workout date required")
        mutateDay(date: date) { day in
            day.plannedWorkouts.removeAll { $0.id == plannedWorkout.id }
        }
    }

    /// Removes a planned workout after it has been completed. The facade's
    /// `completePlannedWorkout` runs the HK-side `addWorkout` then calls this to clear the plan.
    /// Identical to `deletePlannedWorkout` (the distinction is intent, not behaviour) — delegate.
    public func removePlannedWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        deletePlannedWorkout(plannedWorkout, date: date)
    }

    // MARK: - Planned recipes (F3 weekly shopping-list planner)

    /// Assigns a recipe to a day in the shopping-list planner. Idempotent (a recipe already planned on
    /// the day is not duplicated). Mirrors `planWorkout`'s per-day-row mutation exactly — the field
    /// rides `DayRecord.payloadData` via Codable, so no schema change and per-row sync for free.
    public func planRecipe(_ recipeID: UUID, date: String) {
        assert(!date.isEmpty, "planned recipe date required")
        mutateDay(date: date) { day in
            guard !day.plannedRecipeIDs.contains(recipeID) else { return }
            day.plannedRecipeIDs.append(recipeID)
        }
    }

    /// Removes a recipe from a day's plan. A no-op if it was not planned there.
    public func unplanRecipe(_ recipeID: UUID, date: String) {
        assert(!date.isEmpty, "planned recipe date required")
        mutateDay(date: date) { day in
            day.plannedRecipeIDs.removeAll { $0 == recipeID }
        }
    }

    /// Persists the whole workout profile aggregate.
    public func setWorkoutProfile(_ profile: WorkoutProfile) {
        batchSnapshotPersistence { settings.workoutProfile = profile }
    }

    /// Adds or replaces a workout location by id, optionally making it the active one.
    public func upsertWorkoutLocation(_ location: WorkoutLocation, makeActive: Bool = false) {
        batchSnapshotPersistence {
            if let index = settings.workoutLocations.firstIndex(where: { $0.id == location.id }) {
                settings.workoutLocations[index] = location
            } else {
                settings.workoutLocations.append(location)
            }
            if makeActive { settings.activeWorkoutLocationID = location.id }
        }
    }

    /// Deletes a workout location. The list never goes empty (falls back to `.fullGym`) and
    /// the active id is repointed if it was the one deleted.
    public func deleteWorkoutLocation(_ id: UUID) {
        batchSnapshotPersistence {
            settings.workoutLocations.removeAll { $0.id == id }
            if settings.workoutLocations.isEmpty { settings.workoutLocations = [.fullGym] }
            if settings.activeWorkoutLocationID == id {
                settings.activeWorkoutLocationID = settings.workoutLocations.first?.id
            }
        }
    }

    /// Persists which workout location is currently active.
    public func setActiveWorkoutLocation(_ id: UUID) {
        batchSnapshotPersistence { settings.activeWorkoutLocationID = id }
    }

    /// Replaces the whole location list (empty input falls back to `.fullGym`), keeping
    /// `activeID` only if it survives the replacement.
    public func setWorkoutLocations(_ locations: [WorkoutLocation], activeID: UUID?) {
        batchSnapshotPersistence {
            let normalized = locations.isEmpty ? [WorkoutLocation.fullGym] : locations
            settings.workoutLocations = normalized
            if let activeID, normalized.contains(where: { $0.id == activeID }) {
                settings.activeWorkoutLocationID = activeID
            } else {
                settings.activeWorkoutLocationID = normalized.first?.id
            }
        }
    }

    /// Persists the selected workout split id (nil clears the selection).
    public func setSelectedSplit(_ id: String?) {
        batchSnapshotPersistence { settings.workoutProfile.selectedSplitID = id }
    }

    /// Bumps the per-exercise progression counter once per distinct non-empty name — the
    /// input to progression suggestions. ``decrementCompletedExercises(_:)`` is the exact reverse.
    public func recordCompletedExercises(_ names: [String]) {
        let deduped = Array(Set(names)).filter { $0.isEmpty == false }
        guard deduped.isEmpty == false else { return }
        batchSnapshotPersistence {
            for name in deduped {
                // R3: bumping an EXISTING key never grows the map, so only a new name can evict.
                if settings.workoutProgression[name] == nil {
                    evictLowestProgressionIfFull()
                }
                settings.workoutProgression[name, default: 0] += 1
            }
        }
    }

    /// Keeps `settings.workoutProgression` at or below ``maxTrackedExerciseNames`` by dropping the
    /// lowest-count name (ties broken by the lexicographically smallest key, so the eviction is
    /// deterministic across devices) and recording it.
    private func evictLowestProgressionIfFull() {
        guard settings.workoutProgression.count >= Self.maxTrackedExerciseNames else { return }
        guard let victim = settings.workoutProgression
            .sorted(by: { ($0.value, $0.key) < ($1.value, $1.key) })
            .first else { return }
        settings.workoutProgression.removeValue(forKey: victim.key)
        FernletAuditLog.log("workoutProgression.evicted", context: [
            "cap": "\(Self.maxTrackedExerciseNames)",
            "count": "\(victim.value)"
        ])
    }

    /// Exact reverse of `recordCompletedExercises`: decrement each name's progression by one, floored at
    /// zero (a hit-zero entry is dropped so the map doesn't accrue dead keys). Deduped the same way as
    /// the record path, so one call undoes exactly one `recordCompletedExercises` call. Used when a
    /// guided workout is removed and its exact catalog exercise names are still recoverable.
    public func decrementCompletedExercises(_ names: [String]) {
        let deduped = Array(Set(names)).filter { $0.isEmpty == false }
        guard deduped.isEmpty == false else { return }
        batchSnapshotPersistence {
            for name in deduped {
                guard let current = settings.workoutProgression[name] else { continue }
                let next = current - 1
                if next <= 0 { settings.workoutProgression[name] = nil }
                else { settings.workoutProgression[name] = next }
            }
        }
    }

    // MARK: - Sleep / hydration / hygiene / care

    /// Records today's sleep log (delegates to the explicit-date overload).
    public func setSleep(hours: Double?, quality: SleepQuality, note: String) {
        // Delegate to the explicit-date overload (the single owner of SleepLog construction/trim).
        // mutateDay(date: todayKey) takes the today-key branch — `day.sleep = …; scheduleSnapshotSave()`
        // — which is operation-for-operation identical to the old inline body. (A `date: String = todayKey`
        // default is impossible: Swift default-arg expressions can't reference `self`.)
        setSleep(hours: hours, quality: quality, note: note, date: todayKey)
    }

    /// Increments today's water bottle count (capped at 30).
    public func addBottle() {
        day.bottleCount = min(day.bottleCount + 1, 30)
        scheduleSnapshotSave()
    }

    /// Decrements today's water bottle count (floored at 0).
    public func removeBottle() {
        day.bottleCount = max(day.bottleCount - 1, 0)
        scheduleSnapshotSave()
    }

    /// Toggles the personal-care task backing a legacy hygiene item (no-op when no task maps to it).
    public func toggleHygiene(_ item: HygieneItem) {
        guard let task = personalCareTasks.first(where: { $0.defaultHygieneItem == item }) else { return }
        togglePersonalCareTask(task)
    }

    /// Flips a personal-care task's completion state for today.
    public func togglePersonalCareTask(_ task: PersonalCareTask) {
        setPersonalCareTask(task, completed: !isPersonalCareTaskCompleted(task))
    }

    /// Sets a task's completion for today, mirroring default tasks into the legacy `hygiene`
    /// set in both directions.
    public func setPersonalCareTask(_ task: PersonalCareTask, completed: Bool) {
        batchSnapshotPersistence {
            if completed {
                day.completedPersonalCareTaskIDs.insert(task.id)
                if let item = task.defaultHygieneItem { day.hygiene.insert(item) }
            } else {
                day.completedPersonalCareTaskIDs.remove(task.id)
                if let item = task.defaultHygieneItem { day.hygiene.remove(item) }
            }
        }
    }

    /// Appends a custom personal-care task (trimmed; empty labels ignored) and re-normalizes
    /// the list.
    public func addPersonalCareTask(label: String, group: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        batchSnapshotPersistence {
            var tasks = personalCareTasks
            tasks.append(PersonalCareTask.custom(label: trimmed, group: group))
            settings.personalCareTasks = PersonalCareTask.normalized(tasks)
        }
    }

    /// Deletes a personal-care task and scrubs its completion (and mirrored hygiene item)
    /// from today.
    public func removePersonalCareTask(_ task: PersonalCareTask) {
        batchSnapshotPersistence {
            settings.personalCareTasks = PersonalCareTask.normalized(personalCareTasks.filter { $0.id != task.id })
            day.completedPersonalCareTaskIDs.remove(task.id)
            if let item = task.defaultHygieneItem { day.hygiene.remove(item) }
        }
    }

    /// Records the sleep log for an explicit date — the single owner of `SleepLog`
    /// construction and note trimming.
    public func setSleep(hours: Double?, quality: SleepQuality, note: String, date: String) {
        assert(!date.isEmpty, "sleep date required")
        mutateDay(date: date) {
            $0.sleep = SleepLog(hours: hours, quality: quality, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    /// Sets an explicit date's bottle count, clamped to 0…30 (the calendar back-edit path).
    public func setBottleCount(_ count: Int, date: String) {
        assert(!date.isEmpty, "water date required")
        let clamped = min(max(count, 0), 30)
        mutateDay(date: date) { $0.bottleCount = clamped }
    }

    /// Back-edit path that replaces a date's hygiene set by mapping items to task ids
    /// (see ``setPersonalCareTaskIDs(_:date:)``).
    public func setHygiene(_ hygiene: Set<HygieneItem>, date: String) {
        let ids = Set(hygiene.map(\.rawValue))
        setPersonalCareTaskIDs(ids, date: date)
    }

    /// Replaces a date's completed-task ids wholesale, deriving the legacy `hygiene` set from
    /// whichever ids are default items.
    public func setPersonalCareTaskIDs(_ ids: Set<String>, date: String) {
        assert(!date.isEmpty, "personal care date required")
        let defaultItems = Set(ids.compactMap(HygieneItem.init(rawValue:)))
        mutateDay(date: date) {
            $0.completedPersonalCareTaskIDs = ids
            $0.hygiene = defaultItems
        }
    }

    /// Replaces the goal list (capped at 12) and persists.
    public func replaceGoals(_ newGoals: [FitnessGoal]) {
        goals = Array(newGoals.prefix(12))
        scheduleSnapshotSave()
    }

    // MARK: - Sickness / dismissals

    /// Whether the user marked `dateKey` as a sick day (softens scoring and the companion state).
    public func isSick(on dateKey: String) -> Bool {
        settings.sickDays[dateKey] ?? false
    }

    /// Marks or unmarks a sick day; unmarking removes the key so the synced map stays sparse.
    /// Writing also prunes keys older than the retention window (R3: the map lives in the synced
    /// settings blob and only recent days are ever read).
    public func setSick(_ value: Bool, on dateKey: String) {
        if value {
            settings.sickDays[dateKey] = true
        } else {
            settings.sickDays.removeValue(forKey: dateKey)
        }
        settings.sickDays = Self.pruningDayKeyed(settings.sickDays, cutoff: dayKeyRetentionCutoff())
        scheduleSnapshotSave()
    }

    /// Whether today's intent prompt has been dismissed.
    public var isTodayIntentDismissed: Bool {
        settings.intentDismissedDays[todayKey] ?? false
    }

    /// Dismisses today's intent prompt for the rest of the day, pruning day keys outside the
    /// retention window so the synced map cannot grow one permanent key per day (R3).
    public func dismissTodayIntent() {
        settings.intentDismissedDays[todayKey] = true
        settings.intentDismissedDays = Self.pruningDayKeyed(settings.intentDismissedDays,
                                                            cutoff: dayKeyRetentionCutoff())
        scheduleSnapshotSave()
    }

    /// The oldest day key the per-day settings maps retain — `todayKey` minus
    /// ``maxTrackedDayKeys`` days. Day keys are zero-padded `yyyy-MM-dd`, so string comparison is
    /// chronological (the same property the rest of the persistence layer relies on).
    private func dayKeyRetentionCutoff() -> String {
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -Self.maxTrackedDayKeys,
                                               to: FernletDate.date(fromDayKey: todayKey) ?? Date())
        return FernletDate.dayKey(for: cutoffDate ?? Date())
    }

    /// Drops entries whose day key is older than `cutoff` from a day-keyed settings map.
    static func pruningDayKeyed<Value>(_ map: [String: Value], cutoff: String) -> [String: Value] {
        map.filter { $0.key >= cutoff }
    }

    /// Whether the micronutrient nudge bubble for `key` may show (true when never dismissed
    /// or once its suppression window has lapsed).
    public func isNutrientBubbleActive(for key: String) -> Bool {
        guard let until = settings.nutrientBubbleDismissedUntil[key] else { return true }
        return Date() >= until
    }

    /// Suppresses the nudge bubble for `key` for 14 days.
    public func dismissNutrientBubble(_ key: String) {
        settings.nutrientBubbleDismissedUntil[key] = Date().addingTimeInterval(14 * 86_400)
        scheduleSnapshotSave()
    }

    // MARK: - Gentle offers

    /// Key into the persisted `nutrientBubbleDismissedUntil` map for the ambient gentle-offer card.
    /// A new key in the existing synced `[String: Date]` map is decode-safe on old builds.
    public static let gentleOfferDismissalKey = "gentleOffer"

    /// Whether today's single ambient gentle offer may still be shown (max one per day).
    public func isGentleOfferAvailable(now: Date = Date()) -> Bool {
        guard let until = settings.nutrientBubbleDismissedUntil[Self.gentleOfferDismissalKey] else { return true }
        return now >= until
    }

    /// Suppresses the ambient gentle-offer card until the start of the next local day. Both
    /// dismissing and accepting an offer consume it — one invitation per day, never nagging.
    public func dismissGentleOfferForToday(now: Date = Date()) {
        settings.nutrientBubbleDismissedUntil[Self.gentleOfferDismissalKey] = Self.gentleOfferSuppressionEnd(now: now)
        scheduleSnapshotSave()
    }

    /// Start of the next local day — the moment a fresh gentle offer becomes possible again.
    public static func gentleOfferSuppressionEnd(now: Date = Date()) -> Date {
        let startOfDay = Calendar.current.startOfDay(for: now)
        return Calendar.current.date(byAdding: .day, value: 1, to: startOfDay) ?? now.addingTimeInterval(86_400)
    }

    // MARK: - Onboarding

    /// Commits the onboarding results in one batch (profile, preferences, goal, calorie
    /// display) and marks onboarding done — also stamping the period-visibility migration
    /// marker, since onboarding just made a real visibility determination.
    public func completeOnboarding(profile: UserNutritionProfile, preferences: UserNutritionPreferences, goal: GoalType) {
        batchSnapshotPersistence {
            settings.userProfile = profile
            settings.nutritionPreferences = preferences
            settings.selectedGoal = goal
            settings.showCalories = true
            settings.hasCompletedOnboarding = true
            // Onboarding just captured `sex`/age on an up-to-date build, so "derive from `sex`" is now
            // a REAL visibility determination — stamp the marker (minted only at real determinations).
            // Without this, the user's own saved blob (marker false + onboarding true) would look
            // pre-gate on the next launch and the one-time pin would wrongly fire for every new user.
            settings.didMigratePeriodVisibility = true
        }
    }

    // MARK: - Recipes & ingredients (pure)

    /// Creates a manual recipe from editor inputs: resolves or mints custom-ingredient
    /// `FoodItem`s via `CustomIngredientUpsert`, sanitizes the steps, and inserts the recipe
    /// at the top of the book.
    /// - Returns: The newly created recipe.
    @discardableResult public func addRecipe(name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput], steps: [RecipeStep]? = nil) -> RecipeDefinition {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmedName.isEmpty, "recipe name required")
        let now = Date()
        return batchSnapshotPersistence {
            let selectionCatalog = foodCatalog.items(ids: inputIngredients.compactMap(\.selectedFoodItemId))
            let recipeIngredients = CustomIngredientUpsert.recipeIngredients(
                from: inputIngredients,
                selectionCatalog: selectionCatalog,
                in: &foodItems,
                verifiedAt: now
            )
            let recipe = RecipeDefinition(
                name: trimmedName,
                servings: max(servings, 1),
                ingredients: recipeIngredients,
                notes: notes.trimmingCharacters(in: .whitespacesAndNewlines),
                source: "manual",
                createdAt: now,
                updatedAt: now,
                steps: RecipeStepSanitizer.sanitized(steps)
            )
            recipes.insert(recipe, at: 0)
            return recipe
        }
    }

    /// Rewrites an existing recipe in place from editor inputs, with the same ingredient
    /// resolution and step sanitizing as ``addRecipe(name:servings:notes:ingredients:steps:)``.
    /// A no-op when the recipe id is no longer in the book.
    ///
    /// - Important: `steps` is REQUIRED (no default): it is written unconditionally below, so a
    ///   defaulted-nil would silently erase a recipe's stored steps for any caller that forgot
    ///   to pass them. Callers must always pass the editor's current step list (nil/[] only
    ///   when the user genuinely cleared them).
    public func updateRecipe(_ recipe: RecipeDefinition, name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput], steps: [RecipeStep]?) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmedName.isEmpty, "recipe name required")
        guard let index = recipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        batchSnapshotPersistence {
            let selectionCatalog = foodCatalog.items(ids: inputIngredients.compactMap(\.selectedFoodItemId))
            let recipeIngredients = CustomIngredientUpsert.recipeIngredients(
                from: inputIngredients,
                selectionCatalog: selectionCatalog,
                in: &foodItems,
                verifiedAt: Date()
            )
            assert(!recipeIngredients.isEmpty, "recipe ingredients required")
            recipes[index].name = trimmedName
            recipes[index].servings = max(servings, 1)
            recipes[index].ingredients = recipeIngredients
            recipes[index].notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            recipes[index].steps = RecipeStepSanitizer.sanitized(steps)
            recipes[index].updatedAt = Date()
        }
    }

    /// Inserts an ALREADY-BUILT recipe (structured ingredients already bound to catalog `foodItemId`s)
    /// at the top of the book, persisting through the snapshot path — the store seam for an F4
    /// substitution FORK, whose ingredients are assembled by `RecipeSubstitution.fork` rather than from
    /// `ManualRecipeIngredientInput`. Unlike `addRecipe` it mints no `FoodItem`s: a fork references
    /// existing catalog foods (the substitute is a resolved candidate), so nothing new enters `foodItems`.
    public func insertRecipe(_ recipe: RecipeDefinition) {
        batchSnapshotPersistence {
            // Id-guard: a double-tapped "Save as new recipe" fires the same fork (fixed `id`) twice; without
            // this the second insert would mint a duplicate-identity row into the synced blob (undefined
            // `ForEach` behavior + delete-by-id ambiguity). First save wins; the retry is a no-op.
            guard !recipes.contains(where: { $0.id == recipe.id }) else { return }
            recipes.insert(recipe, at: 0)
        }
    }

    /// Resolves (or mints) a custom-ingredient `FoodItem` from an editor row without attaching
    /// it to any recipe. Returns nil for a blank name.
    @discardableResult public func saveCustomIngredient(_ ingredient: ManualRecipeIngredientInput) -> FoodItem? {
        guard !ingredient.trimmedName.isEmpty else { return nil }
        return batchSnapshotPersistence {
            CustomIngredientUpsert.resolve(
                ingredient: ingredient,
                in: &foodItems,
                verifiedAt: Date()
            )
        }
    }

    /// A previously web-imported product matching `query` (by stored query tag or normalized
    /// name), so a repeat lookup needs no new import.
    public func cachedWebImportedFoodProduct(for query: String) -> FoodItem? {
        let normalizedQuery = FoodItemSearch.normalized(query)
        guard !normalizedQuery.isEmpty else { return nil }
        let queryTag = "web-query:\(normalizedQuery)"
        return webImportedFoodItems.first { foodItem in
            foodItem.tags.contains(queryTag)
                || FoodItemSearch.normalized(foodItem.name) == normalizedQuery
        }
    }

    /// Removes a recipe from the book by id and persists.
    public func deleteRecipe(_ recipe: RecipeDefinition) {
        recipes.removeAll { $0.id == recipe.id }
        scheduleSnapshotSave()
    }

    // NOTE: `macroTotals(for:)` / `micronutrientTotals(for:)` stay in the facade — MealBuilder
    // (their engine) is still an app-target type. See the deviation note above.

    // MARK: - Workshop & memories (pure)

    /// Prepends a workshop texture entry (free-text observation plus tags).
    public func addTexture(_ body: String, tags: Set<TextureTag>) {
        batchSnapshotPersistence {
            workshop.textureEntries.insert(TextureEntry(body: body, tags: tags), at: 0)
        }
    }

    /// Deletes a companion memory note by id.
    public func deleteMemory(_ memory: MemoryNote) {
        batchSnapshotPersistence {
            memories.removeAll { $0.id == memory.id }
        }
    }

    /// Edits a memory note's category and text (trimmed, text capped at 240 characters; empty
    /// text is ignored, an empty category falls back to "note").
    public func updateMemory(_ memory: MemoryNote, category: String, text: String) {
        guard let index = memories.firstIndex(where: { $0.id == memory.id }) else { return }
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCategory = category.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedText.isEmpty == false else { return }
        batchSnapshotPersistence {
            memories[index].category = trimmedCategory.isEmpty ? "note" : trimmedCategory
            memories[index].text = String(trimmedText.prefix(240))
        }
    }

    // MARK: - Tier-two memories (repository-backed)

    /// The repository-backed tier-two (long-horizon) memory records — read live from the
    /// repository, never cached on the store.
    public var tierTwoMemories: [TierTwoMemoryRecord] {
        repository.loadTierTwoMemories()
    }

    /// Replaces the tier-two memory records wholesale in the repository. A failed write (the
    /// sealed-backup restore path is the caller that matters) is audit-logged rather than dropped.
    public func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) {
        if !repository.replaceTierTwoMemories(records) {
            FernletAuditLog.log("diary.tierTwoRestore.failed", context: ["count": "\(records.count)"])
        }
    }

    /// Every persisted day keyed by date, straight from the repository WITHOUT overlaying the
    /// in-memory today. Prefer ``loadDays()`` unless the raw persisted view is the point.
    public func loadAllDaysFromRepository() -> [String: FernletDay] {
        repository.loadAllDays()
    }

    // MARK: - Past-date access (repository-backed)

    /// Every day keyed by date, with the in-memory ``day`` overlaid on ``todayKey`` — the
    /// consistent full-history read.
    public func loadDays() -> [String: FernletDay] {
        var days = repository.loadAllDays()
        days[todayKey] = day
        return days
    }

    /// The day for `dateKey`: the live in-memory ``day`` when it is today, else the
    /// repository's persisted row.
    public func loadDay(for dateKey: String) -> FernletDay {
        if dateKey == todayKey { return day }
        return repository.loadDay(for: dateKey, todayKey: todayKey)
    }

    // MARK: - Day rollover

    /// Advances the store's notion of "today" to `newKey` and swaps the in-memory `day` to that day's
    /// persisted content (an existing row — e.g. the widget or another device already wrote one — else a
    /// fresh empty `FernletDay(date: newKey)`). The store is built once at launch with `todayKey` pinned,
    /// so without this a process that stays resident across local midnight keeps filing "today" under the
    /// launch day.
    ///
    /// The caller MUST persist the outgoing in-memory state first — the app-side facade flushes its
    /// pending snapshot save so the outgoing `day` (plus `recentMeals`, etc.) is written under the OLD key
    /// before it advances. This method performs NO save itself; it only re-keys + reloads. No-op (returns
    /// false) when already on `newKey`.
    @discardableResult
    public func advanceCurrentDay(to newKey: String) -> Bool {
        assert(!newKey.isEmpty, "day key required")
        guard newKey != todayKey else { return false }
        // Load the new day's persisted content keyed as its own today (a brand-new day resolves to an
        // empty FernletDay). Read it BEFORE re-keying so `day.date` stays consistent with `todayKey`.
        let freshDay = repository.loadDay(for: newKey, todayKey: newKey)
        todayKey = newKey
        day = freshDay
        return true
    }

    // MARK: - WorkoutSync (pure)

    /// Whether any day in history contains a workout with this Fernlet id — the dedup guard
    /// for HealthKit reconciliation.
    public func workoutExists(id: UUID) -> Bool {
        loadDays().values.contains { day in
            day.workouts.contains { $0.id == id }
        }
    }

    /// Whether any day in history contains a workout stamped with this Apple Health UUID, so
    /// an already-linked sample is never imported twice.
    public func workoutExists(healthKitUUID: UUID) -> Bool {
        loadDays().values.contains { day in
            day.workouts.contains { $0.healthKitUUID == healthKitUUID }
        }
    }

    /// Stamps a workout row with its Apple Health UUID. Both callers stamp a Fernlet-*authored* sample —
    /// `WorkoutHealthKitSync.saveIfAuthorized` after our own save, and `reconcileWorkouts` when our own
    /// sample returns through the observer carrying our `fernlet.workoutID` — so this also marks the row
    /// `healthKitAuthored`, the provenance that lets the store allow remove/edit (and manage the Health
    /// copy) while still refusing true imports. A safe no-op when the workout isn't found (e.g. it was
    /// removed while its save was in flight).
    public func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) {
        batchSnapshotPersistence {
            if date == todayKey {
                if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                    day.workouts[index].healthKitUUID = hkUUID
                    day.workouts[index].healthKitAuthored = true
                    return
                }
            } else {
                let targetDay = repository.loadDay(for: date, todayKey: todayKey)
                if targetDay.workouts.contains(where: { $0.id == workoutID }) {
                    let stamped = mutatePastDay(date) { day in
                        if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                            day.workouts[index].healthKitUUID = hkUUID
                            day.workouts[index].healthKitAuthored = true
                        }
                    }
                    if !stamped {
                        FernletAuditLog.log("diary.workoutHealthKitUUID.saveFailed", context: ["date": date])
                    }
                    return
                }
            }

            if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                day.workouts[index].healthKitUUID = hkUUID
                day.workouts[index].healthKitAuthored = true
                return
            }

            for (dateKey, pastDay) in repository.loadAllDays() where dateKey != todayKey {
                guard pastDay.workouts.contains(where: { $0.id == workoutID && $0.healthKitUUID == nil }) else { continue }
                let stamped = mutatePastDay(dateKey) { targetDay in
                    if let index = targetDay.workouts.firstIndex(where: { $0.id == workoutID && $0.healthKitUUID == nil }) {
                        targetDay.workouts[index].healthKitUUID = hkUUID
                        targetDay.workouts[index].healthKitAuthored = true
                    }
                }
                if !stamped {
                    FernletAuditLog.log("diary.workoutHealthKitUUID.saveFailed", context: ["date": dateKey])
                }
                return
            }
        }
    }

    // MARK: - Day mutation workhorse

    /// Mutates the day for the given date key — the single write seam every per-day content
    /// mutation funnels through. Today mutates the in-memory ``day`` and schedules a snapshot
    /// save; past dates round-trip through the repository (with the sealed-field strip — see
    /// `mutatePastDay`).
    /// - Returns: Whether the write succeeded (always true for today).
    // R7 exception: App/Fernlet/FernletStore.swift discards this at five call sites (2078, 2266,
    // 3035, 3068, 3082, 5276, 5451); the attribute can only be removed with those out-of-slice sites.
    @discardableResult
    public func mutateDay(date: String, _ change: (inout FernletDay) -> Void) -> Bool {
        // Guard, not assert: in Release an empty key would flow into `updateDay(…, for: "")` and
        // write a CloudKit-synced `DayRecord` row keyed by the empty string. Every public per-day
        // mutator funnels through here, so this one guard covers them all.
        guard !date.isEmpty else {
            assertionFailure("date key required")
            FernletAuditLog.log("diary.mutateDay.rejected", context: ["reason": "emptyDateKey"])
            return false
        }
        if date == todayKey {
            change(&day)
            scheduleSnapshotSave()
            return true
        }
        return mutatePastDay(date, change)
    }

    /// Loads, mutates, and re-saves a past day's repository row. Every past-day write passes
    /// through `SanitizedDay` first, so sealed journal text and hidden cycle/intimate context
    /// can never leak into the (potentially iCloud-synced) blob — see the inline note.
    private func mutatePastDay(_ dateKey: String, _ mutate: (inout FernletDay) -> Void) -> Bool {
        guard !dateKey.isEmpty else {
            assertionFailure("date key required")
            FernletAuditLog.log("diary.mutatePastDay.rejected", context: ["reason": "emptyDateKey"])
            return false
        }
        var targetDay = repository.loadDay(for: dateKey, todayKey: todayKey)
        mutate(&targetDay)
        // S3 privacy wall: a past-day write goes straight to the repository with NO forStorage pass.
        // SanitizedDay applies the same strip as the snapshot path — sealed journal text PLUS sensitive
        // health fields (cycle/intimate) — so a past-day mutation can never leak them into the
        // (iCloud-synced) blob, and updateDay structurally requires the sanitized type. This covers EVERY
        // past-day mutation (journal add/edit and any unrelated edit to a day that holds a sealed journal)
        // and self-heals legacy plaintext as past days are touched. Past-day reads re-hydrate via
        // loadDayWithDecryptedJournals; unsealed entries (ids absent from the set) keep their text,
        // matching forStorage's behaviour and the no-data-loss path for failed seals.
        let saved = repository.updateDay(
            SanitizedDay.sanitizing(targetDay, sealedJournalIDs: sealedJournalIDsHook()),
            for: dateKey, todayKey: todayKey
        )
        if !saved {
            // An assert alone compiles out of Release, which left a failed past-day write (read-only
            // recovery, a Core Data fault, a rolled-back context) completely silent: the UI showed the
            // edit, nothing was persisted, and no record existed to explain the lost entry later.
            FernletAuditLog.log("diary.pastDaySave.failed", context: ["date": dateKey])
            assertionFailure("past-date save failed for \(dateKey)")
        }
        return saved
    }

    // MARK: - Snapshot / reset helpers

    /// Runs `updates`, then schedules a single snapshot save — the standard wrapper for
    /// multi-field mutations so intent stays "one logical change, one save".
    @discardableResult
    func batchSnapshotPersistence<T>(_ updates: () throws -> T) rethrows -> T {
        let result = try updates()
        scheduleSnapshotSave()
        return result
    }

    /// Resets the diary slice to defaults. The facade orchestrates the full reset (also resetting
    /// its app-only state + collaborators) and wraps this in its own `batchSnapshotPersistence`.
    public func resetDiary() {
        day = FernletDay(date: todayKey)
        settings = FernletSettings()
        recentMeals = []
        previousJournals = []
        memories = []
        goals = []
        workshop = WorkshopData()
        foodItems = []
        recipes = []
        dailyScores = []
        // Re-mint the device designer id: `resetDiary()` nulled it via the fresh `FernletSettings()`, and the
        // `localDesignerID` getter would otherwise lazily mint it (mutating observed state) the next time a
        // view body reads it — a "modifying state during view update" hazard.
        ensureLocalDesignerID()
    }

    /// Applies the diary slice of a snapshot. The facade's `apply(_:)` calls this then applies its
    /// app-only collaborators (retry queue, trust vault, journal sealing, derived signals).
    public func applyDiarySlice(_ snapshot: FernletSnapshot) {
        let existingOwnedDesignerIDs = settings.ownedDesignerIDs
        day = snapshot.day
        settings = snapshot.settings
        // UNION the owned-designer-id set rather than letting the last-writer-wins synced blob overwrite it:
        // the set is monotonic, so union-on-apply gives every device the full history of the user's ids
        // without clobbering — the fix for own-device items reading as "a friend's" after a sync.
        settings.ownedDesignerIDs.formUnion(existingOwnedDesignerIDs)
        recentMeals = snapshot.recentMeals
        previousJournals = snapshot.previousJournals
        memories = snapshot.memories
        goals = snapshot.goals
        workshop = snapshot.workshop
        foodItems = snapshot.foodItems.filter { $0.source != .usda }
        recipes = snapshot.recipes
        // R3: a synced blob must not be able to reinstate an unbounded score history.
        dailyScores = Self.boundedDailyScores(snapshot.dailyScores)
        // Also add this device's id + guarantee localDesignerID is non-nil, so the getter never lazily mints
        // (mutating observed state) mid-render.
        ensureLocalDesignerID()
    }

    // MARK: - Launch no-ops

    /// Deliberate no-op kept for the existing launch/UI call sites (forwarded by the facade).
    /// The deferred seeding this once gated is gone — see ``loadBundledFoodItemsForLaunch()``.
    public func markLaunchScreenDismissed() {}

    /// Deliberate no-op: the bundled food catalog is now a read-only SQLite store opened
    /// lazily by `FoodCatalog`, so there is no heavyweight seed to await at launch. Kept so
    /// the launch flow's call sites keep a stable seam.
    public func loadBundledFoodItemsForLaunch() async {}

    /// Deliberate no-op — same story as ``loadBundledFoodItemsForLaunch()``: bundled foods
    /// are never seeded into ``foodItems`` anymore.
    public func ensureBundledFoodItemsSeeded() {}
}
