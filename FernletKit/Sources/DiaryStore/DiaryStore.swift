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
/// Two injected closures decouple it from the facade so it depends on no app/sealed module:
/// - `scheduleSnapshotSave` replaces every former `snapshotSaveCoordinator.schedule()` call.
/// - `periodAdjustment` replaces the former `periodAdjustment(for:)` body that read the
///   facade-only `PeriodContextBridge`; the facade supplies a closure that applies the opt-in
///   gate. Default `{ _ in .none }` makes scoring byte-identical to period-unaware.
@MainActor
@Observable
public final class DiaryStore {
    public var day: FernletDay
    public var settings: FernletSettings
    public var recentMeals: [Meal]
    public var previousJournals: [JournalEntry]
    public var memories: [MemoryNote]
    public var goals: [FitnessGoal]
    public var workshop: WorkshopData
    public var foodItems: [FoodItem] {
        didSet { foodCatalog.setUserItems(foodItems) }
    }
    public var webImportedFoodItems: [FoodItem] {
        foodItems.filter { $0.tags.contains("web-import") }
    }
    public var allowsWebNutritionLookup: Bool {
        settings.webNutritionLookupEnabled && settings.aiStatus != .off
    }
    public var recipes: [RecipeDefinition]
    public var dailyScores: [DailyHealthScore]
    public var companionThought: String?

    /// The store's notion of "today". Pinned at construction, but ADVANCEABLE via `advanceCurrentDay`
    /// so a process that stays resident across local midnight can roll over in place instead of filing
    /// new logs under the launch day. `private(set)` keeps every external reader read-only (the mutation
    /// only happens through the guarded rollover seam); still `@ObservationIgnored` because the rollover
    /// reassigns `day` (which IS observed) in the same breath, so dependent views re-render off that.
    @ObservationIgnored public private(set) var todayKey: String
    @ObservationIgnored public let repository: FernletRepository
    @ObservationIgnored public let foodCatalog: FoodCatalog
    @ObservationIgnored private var scheduleSnapshotSaveHook: () -> Void
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
        self.dailyScores = snapshot.dailyScores
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

    public var macroTotals: MacroTotals {
        day.meals.reduce(into: MacroTotals()) { partial, meal in
            partial.protein += meal.macros.protein
            partial.carbs += meal.macros.carbs
            partial.fat += meal.macros.fat
        }
    }

    public var micronutrientTotals: Micronutrients {
        day.meals.reduce(into: Micronutrients()) { partial, meal in
            partial.add(meal.micronutrientSnapshot)
        }
    }

    public var nutritionTargets: NutritionTargets {
        NutritionTargetCalculator.targets(for: settings)
    }

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

    public func score(for targetDay: FernletDay) -> Double {
        scoreBreakdown(for: targetDay).overall
    }

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

    public var personalCareTasks: [PersonalCareTask] {
        PersonalCareTask.normalized(settings.personalCareTasks)
    }

    public func personalCareProgress(for targetDay: FernletDay? = nil) -> (completed: Int, total: Int) {
        let activeDay = targetDay ?? day
        let tasks = personalCareTasks
        let completed = tasks.filter { isPersonalCareTaskCompleted($0, in: activeDay) }.count
        return (completed, tasks.count)
    }

    public func isPersonalCareTaskCompleted(_ task: PersonalCareTask, in targetDay: FernletDay? = nil) -> Bool {
        let activeDay = targetDay ?? day
        if activeDay.completedPersonalCareTaskIDs.contains(task.id) { return true }
        if let item = task.defaultHygieneItem {
            return activeDay.hygiene.contains(item)
        }
        return false
    }

    // MARK: - Day summary / companion thought

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
            }
        }
    }

    public func invalidateDaySummary(for dateKey: String) {
        assert(!dateKey.isEmpty, "date key required")
        guard let index = dailyScores.firstIndex(where: { $0.dateKey == dateKey }) else { return }
        dailyScores[index].daySummaryText = nil
        scheduleSnapshotSave()
    }

    public func storeCompanionThought(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        companionThought = trimmed
    }

    public var storageLocation: String {
        repository.storageDescription()
    }

    public var isIntimateLoggingAllowed: Bool {
        settings.userProfile.age >= 18
    }

    // MARK: - Settings toggles

    /// Persists the goal chosen from the Settings/onboarding preset cards. Mirrors the other setters:
    /// set the keypath then schedule the debounced snapshot save — a bare `settings.selectedGoal =`
    /// binding mutated memory but never scheduled a save, so the choice reverted on the next launch.
    public func setSelectedGoal(_ goal: GoalType) {
        settings.selectedGoal = goal
        scheduleSnapshotSave()
    }

    public func setHidePredictions(_ hidePredictions: Bool) {
        settings.hidePredictions = hidePredictions
        scheduleSnapshotSave()
    }

    public func setHideFertileWindow(_ hideFertileWindow: Bool) {
        settings.hideFertileWindow = hideFertileWindow
        scheduleSnapshotSave()
    }

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

    public func setStressAwarenessEnabled(_ enabled: Bool) {
        settings.stressAwarenessEnabled = enabled
        scheduleSnapshotSave()
    }

    public func markPeriodContextPrimerSeen() {
        guard !settings.periodContextPrimerSeen else { return }
        settings.periodContextPrimerSeen = true
        scheduleSnapshotSave()
    }

    public func setCompanionAppearance(_ appearance: CompanionAppearance) {
        settings.companionAppearance = appearance
        scheduleSnapshotSave()
    }

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

    public func setProximityDisplayName(_ name: String) {
        settings.proximityDisplayName = name.trimmingCharacters(in: .whitespaces)
        scheduleSnapshotSave()
    }

    public func setShowProximityDebugTools(_ value: Bool) {
        settings.showProximityDebugTools = value
        scheduleSnapshotSave()
    }

    public func setHomeWidgets(_ widgets: [HomeWidget]) {
        settings.homeWidgets = HomeWidget.normalized(widgets)
        scheduleSnapshotSave()
    }

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

    public func attachMealPhoto(mealID: UUID, photoID: UUID) {
        batchSnapshotPersistence {
            if let index = day.meals.firstIndex(where: { $0.id == mealID }) {
                day.meals[index].photoID = photoID
            }
        }
    }

    @discardableResult public func logSavedRecipe(_ recipe: RecipeDefinition, mealType: MealType? = nil, date: String? = nil) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "saved recipe meal date required")
        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: mealType)
        appendMeal(meal, date: targetDate)
        return meal
    }

    @discardableResult public func logWebImportedFoodProduct(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        logFoodItemMeal(
            foodItem, mealType: mealType, date: date,
            confidence: "Saved product", note: "Logged from saved product.", source: MealLogSource.webImport
        )
    }

    /// Logs a product resolved from a barcode scan (user-item pairing or a barcode-carrying catalog)
    /// as a single meal. Same shape as the saved-product path — one serving of a known food.
    @discardableResult public func logBarcodeScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        logFoodItemMeal(
            foodItem, mealType: mealType, date: date,
            confidence: "Scanned product", note: "Logged from a barcode scan.", source: MealLogSource.barcodeScan
        )
    }

    /// Logs a product whose macros came from a scanned nutrition label (the photo-capture label path)
    /// as a single meal. Same shape as the barcode/saved-product paths — one serving of a known food —
    /// but with truthful label-scan provenance instead of barcode-scan.
    @discardableResult public func logLabelScannedFoodItem(_ foodItem: FoodItem, mealType: MealType? = nil, date: String? = nil) -> Meal {
        logFoodItemMeal(
            foodItem, mealType: mealType, date: date,
            confidence: "Scanned label", note: "Logged from a nutrition label scan.", source: MealLogSource.labelScan
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

    /// Shared "one serving of this known food" meal construction for the product-shaped log paths.
    private func logFoodItemMeal(_ foodItem: FoodItem, mealType: MealType?, date: String?, confidence: String, note: String, source: String) -> Meal {
        let targetDate = date ?? todayKey
        assert(!targetDate.isEmpty, "food product meal date required")
        let meal = Meal(
            name: foodItem.name,
            mealType: mealType ?? MealParser.classifyMealType(foodItem.name),
            macros: foodItem.macros,
            micronutrientSnapshot: foodItem.micronutrients,
            mealSource: .manual,
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
    @discardableResult
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

    public func planWorkout(_ plannedWorkout: PlannedWorkout, date: String) {
        assert(!date.isEmpty, "planned workout date required")
        mutateDay(date: date) { day in
            day.plannedWorkouts.removeAll { $0.id == plannedWorkout.id }
            day.plannedWorkouts.append(plannedWorkout)
            day.plannedWorkouts.sort { $0.createdAt < $1.createdAt }
        }
    }

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

    public func previousWeekPlannedWorkout(for date: String) -> PlannedWorkout? {
        assert(!date.isEmpty, "planned workout date required")
        guard let targetDate = FernletDate.date(fromDayKey: date),
              let previousWeekDate = Calendar.current.date(byAdding: .day, value: -7, to: targetDate) else {
            return nil
        }
        let previousWeekKey = FernletDate.dayKey(for: previousWeekDate)
        return loadDay(for: previousWeekKey).plannedWorkouts.first
    }

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

    /// The recipe ids planned across a run of day keys, de-duplicated but stable-ordered (first day a
    /// recipe appears wins). Dangling ids (recipe since deleted) are NOT filtered here — the caller
    /// resolves against the recipe stores and drops what no longer exists (§4.3).
    public func plannedRecipeIDs(forDays dayKeys: [String]) -> [UUID] {
        var seen = Set<UUID>()
        var ordered: [UUID] = []
        for key in dayKeys {
            for id in loadDay(for: key).plannedRecipeIDs where seen.insert(id).inserted {
                ordered.append(id)
            }
        }
        return ordered
    }

    public func setWorkoutProfile(_ profile: WorkoutProfile) {
        batchSnapshotPersistence { settings.workoutProfile = profile }
    }

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

    public func deleteWorkoutLocation(_ id: UUID) {
        batchSnapshotPersistence {
            settings.workoutLocations.removeAll { $0.id == id }
            if settings.workoutLocations.isEmpty { settings.workoutLocations = [.fullGym] }
            if settings.activeWorkoutLocationID == id {
                settings.activeWorkoutLocationID = settings.workoutLocations.first?.id
            }
        }
    }

    public func setActiveWorkoutLocation(_ id: UUID) {
        batchSnapshotPersistence { settings.activeWorkoutLocationID = id }
    }

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

    public func setSelectedSplit(_ id: String?) {
        batchSnapshotPersistence { settings.workoutProfile.selectedSplitID = id }
    }

    public func recordCompletedExercises(_ names: [String]) {
        let deduped = Array(Set(names)).filter { $0.isEmpty == false }
        guard deduped.isEmpty == false else { return }
        batchSnapshotPersistence {
            for name in deduped { settings.workoutProgression[name, default: 0] += 1 }
        }
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

    public func setSleep(hours: Double?, quality: SleepQuality, note: String) {
        // Delegate to the explicit-date overload (the single owner of SleepLog construction/trim).
        // mutateDay(date: todayKey) takes the today-key branch — `day.sleep = …; scheduleSnapshotSave()`
        // — which is operation-for-operation identical to the old inline body. (A `date: String = todayKey`
        // default is impossible: Swift default-arg expressions can't reference `self`.)
        setSleep(hours: hours, quality: quality, note: note, date: todayKey)
    }

    public func addBottle() {
        day.bottleCount = min(day.bottleCount + 1, 30)
        scheduleSnapshotSave()
    }

    public func removeBottle() {
        day.bottleCount = max(day.bottleCount - 1, 0)
        scheduleSnapshotSave()
    }

    public func toggleHygiene(_ item: HygieneItem) {
        guard let task = personalCareTasks.first(where: { $0.defaultHygieneItem == item }) else { return }
        togglePersonalCareTask(task)
    }

    public func togglePersonalCareTask(_ task: PersonalCareTask) {
        setPersonalCareTask(task, completed: !isPersonalCareTaskCompleted(task))
    }

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

    public func addPersonalCareTask(label: String, group: String) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        batchSnapshotPersistence {
            var tasks = personalCareTasks
            tasks.append(PersonalCareTask.custom(label: trimmed, group: group))
            settings.personalCareTasks = PersonalCareTask.normalized(tasks)
        }
    }

    public func removePersonalCareTask(_ task: PersonalCareTask) {
        batchSnapshotPersistence {
            settings.personalCareTasks = PersonalCareTask.normalized(personalCareTasks.filter { $0.id != task.id })
            day.completedPersonalCareTaskIDs.remove(task.id)
            if let item = task.defaultHygieneItem { day.hygiene.remove(item) }
        }
    }

    public func setSleep(hours: Double?, quality: SleepQuality, note: String, date: String) {
        assert(!date.isEmpty, "sleep date required")
        mutateDay(date: date) {
            $0.sleep = SleepLog(hours: hours, quality: quality, note: note.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }

    public func setBottleCount(_ count: Int, date: String) {
        assert(!date.isEmpty, "water date required")
        let clamped = min(max(count, 0), 30)
        mutateDay(date: date) { $0.bottleCount = clamped }
    }

    public func setHygiene(_ hygiene: Set<HygieneItem>, date: String) {
        let ids = Set(hygiene.map(\.rawValue))
        setPersonalCareTaskIDs(ids, date: date)
    }

    public func setPersonalCareTaskIDs(_ ids: Set<String>, date: String) {
        assert(!date.isEmpty, "personal care date required")
        let defaultItems = Set(ids.compactMap(HygieneItem.init(rawValue:)))
        mutateDay(date: date) {
            $0.completedPersonalCareTaskIDs = ids
            $0.hygiene = defaultItems
        }
    }

    public func replaceGoals(_ newGoals: [FitnessGoal]) {
        goals = Array(newGoals.prefix(12))
        scheduleSnapshotSave()
    }

    // MARK: - Sickness / dismissals

    public func isSick(on dateKey: String) -> Bool {
        settings.sickDays[dateKey] ?? false
    }

    public func setSick(_ value: Bool, on dateKey: String) {
        if value {
            settings.sickDays[dateKey] = true
        } else {
            settings.sickDays.removeValue(forKey: dateKey)
        }
        scheduleSnapshotSave()
    }

    public var isTodayIntentDismissed: Bool {
        settings.intentDismissedDays[todayKey] ?? false
    }

    public func dismissTodayIntent() {
        settings.intentDismissedDays[todayKey] = true
        scheduleSnapshotSave()
    }

    public func isNutrientBubbleActive(for key: String) -> Bool {
        guard let until = settings.nutrientBubbleDismissedUntil[key] else { return true }
        return Date() >= until
    }

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

    @discardableResult public func addRecipe(name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) -> RecipeDefinition {
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
                updatedAt: now
            )
            recipes.insert(recipe, at: 0)
            return recipe
        }
    }

    public func updateRecipe(_ recipe: RecipeDefinition, name: String, servings: Int, notes: String = "", ingredients inputIngredients: [ManualRecipeIngredientInput]) {
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

    public func cachedWebImportedFoodProduct(for query: String) -> FoodItem? {
        let normalizedQuery = FoodItemSearch.normalized(query)
        guard !normalizedQuery.isEmpty else { return nil }
        let queryTag = "web-query:\(normalizedQuery)"
        return webImportedFoodItems.first { foodItem in
            foodItem.tags.contains(queryTag)
                || FoodItemSearch.normalized(foodItem.name) == normalizedQuery
        }
    }

    public func deleteRecipe(_ recipe: RecipeDefinition) {
        recipes.removeAll { $0.id == recipe.id }
        scheduleSnapshotSave()
    }

    // NOTE: `macroTotals(for:)` / `micronutrientTotals(for:)` stay in the facade — MealBuilder
    // (their engine) is still an app-target type. See the deviation note above.

    // MARK: - Workshop & memories (pure)

    public func addTexture(_ body: String, tags: Set<TextureTag>) {
        batchSnapshotPersistence {
            workshop.textureEntries.insert(TextureEntry(body: body, tags: tags), at: 0)
        }
    }

    public func deleteMemory(_ memory: MemoryNote) {
        batchSnapshotPersistence {
            memories.removeAll { $0.id == memory.id }
        }
    }

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

    public var tierTwoMemories: [TierTwoMemoryRecord] {
        repository.loadTierTwoMemories()
    }

    public func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) {
        repository.replaceTierTwoMemories(records)
    }

    public func loadAllDaysFromRepository() -> [String: FernletDay] {
        repository.loadAllDays()
    }

    // MARK: - Past-date access (repository-backed)

    public func loadDays() -> [String: FernletDay] {
        var days = repository.loadAllDays()
        days[todayKey] = day
        return days
    }

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

    public func workoutExists(id: UUID) -> Bool {
        loadDays().values.contains { day in
            day.workouts.contains { $0.id == id }
        }
    }

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
                    mutatePastDay(date) { day in
                        if let index = day.workouts.firstIndex(where: { $0.id == workoutID }) {
                            day.workouts[index].healthKitUUID = hkUUID
                            day.workouts[index].healthKitAuthored = true
                        }
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
                mutatePastDay(dateKey) { targetDay in
                    if let index = targetDay.workouts.firstIndex(where: { $0.id == workoutID && $0.healthKitUUID == nil }) {
                        targetDay.workouts[index].healthKitUUID = hkUUID
                        targetDay.workouts[index].healthKitAuthored = true
                    }
                }
                return
            }
        }
    }

    // MARK: - Day mutation workhorse

    /// Mutates the day for the given date key. Today mutates the in-memory day;
    /// past dates round-trip through the repository.
    @discardableResult
    public func mutateDay(date: String, _ change: (inout FernletDay) -> Void) -> Bool {
        assert(!date.isEmpty, "date key required")
        if date == todayKey {
            change(&day)
            scheduleSnapshotSave()
            return true
        }
        return mutatePastDay(date, change)
    }

    @discardableResult
    private func mutatePastDay(_ dateKey: String, _ mutate: (inout FernletDay) -> Void) -> Bool {
        assert(!dateKey.isEmpty, "date key required")
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
        assert(saved, "past-date save failed for \(dateKey)")
        return saved
    }

    // MARK: - Snapshot / reset helpers

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
        dailyScores = snapshot.dailyScores
        // Also add this device's id + guarantee localDesignerID is non-nil, so the getter never lazily mints
        // (mutating observed state) mid-render.
        ensureLocalDesignerID()
    }

    // MARK: - Launch no-ops

    public func markLaunchScreenDismissed() {}

    public func loadBundledFoodItemsForLaunch() async {}

    public func ensureBundledFoodItemsSeeded() {}
}
