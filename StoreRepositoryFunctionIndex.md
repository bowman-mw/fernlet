# Store, Repository, And Extracted Service Function Index

This index maps the core store, repository, persistence, and extracted store service functions to their responsibilities. Use it before adding data mutation, save/load, derived signal, retry queue, saved recipe, launch preparation, storage preference, or sealed-buffer behavior so existing lifecycle code is reused instead of duplicated.

## Duplication Hotspots

| Need | Prefer Reusing |
| --- | --- |
| Mutating app state and scheduling persistence | `FernletStore.batchSnapshotPersistence(...)`, `FernletStore.mutateDay(date:_:)`, `SnapshotSaveCoordinator.schedule()` |
| Loading or saving the whole app snapshot | `FernletRepository.loadSnapshot(todayKey:)`, `saveSnapshot(_:)`, `CoreDataFernletRepository`, `LocalFernletRepository` |
| Past-date day edits | `FernletStore.loadDay(for:)`, `loadDays()`, `mutateDay(date:_:)`, `FernletRepository.updateDay(_:for:todayKey:)` |
| Main app Core Data / CloudKit container setup | `PersistenceController.reload(with:)`, `makeContainer(...)`, `configure(...)` |
| Local-only sealed narrative storage | `PrivatePersistenceController`, `JournalNarrativeRepository`, `MenstrualNarrativeRepository`, `PendingNarrativeBuffer` |
| Debounced snapshot saves and remote reloads | `SnapshotSaveCoordinator.schedule()`, `flushPending()`, `subscribeRemote(...)` |
| AI retry queue lifecycle | `AIRetryQueueService.queueMealRetry(_:)`, `clear(id:)`, `apply(_:)`, `reset()` |
| Derived signal rebuilds | `DerivedSignalsService.rebuild(...)`, `scheduleDeferredRebuild(...)`, `DerivedSignalsRebuilder.rebuild(...)`, `DerivedSignalFactory.makeSignals(...)` |
| Saved URL recipe persistence and logging | `SavedRecipeService.add(_:)`, `update(_:)`, `delete(_:)`, `makeMeal(from:mealType:)` |
| Bundled catalog loading | `BundledFoodSeedingService.load()`, `FernletStore.ensureBundledFoodItemsSeeded()` |
| Launch photowall/day summary/companion thought prep | `LaunchPreparationService.prepare(store:)`, `PhotowallPhotoSelector.selectPhotoIDs(...)` |
| Keychain-backed storage preferences | `StoragePreferencesStore.update(_:)`, `StoragePreferences.defaultHealthKitCapabilityEnabled` |

## Store And Snapshot Contract

### `Models.swift`

| Function Or Type | What It Does |
| --- | --- |
| `FernletDay.init(...)` | Creates the per-day aggregate for meals, workouts, journals, sleep, hydration, hygiene, personal-care IDs, and HealthKit context. |
| `FernletDay.init(from:)` | Decodes older saved days while defaulting missing collections and context fields. |
| `HealthDailyContext.merge(_:)` | Merges newly imported HealthKit sub-contexts without wiping absent existing sections. |
| `FernletSettings.init(from:)` | Decodes app settings with defaults for newer fields such as AI, onboarding, widgets, proximity, and recipe-share flags. |
| `HomeWidget.normalized(_:)` | De-duplicates home widgets, keeps allowed order/count, and supplies defaults when needed. |
| `FernletShortcut.normalizedQuickLog(_:)` | De-duplicates quick log shortcuts and falls back to default quick-log items. |
| `FernletShortcut.visibleQuickLog(_:allowsIntimacy:)` | Filters intimacy shortcut visibility based on age/permission gating. |
| `FernletShortcut.selectableQuickLogItems(allowsIntimacy:)` | Returns shortcut options available for settings customization. |
| `UserNutritionProfile.weightKilograms` / `heightCentimeters` | Converts imperial profile fields for nutrition target math. |
| `Meal.calories` | Returns the current macro-derived calorie total. |
| `Meal.copyForToday()` | Copies a meal with a new ID and current logged timestamp for repeat logging. |
| `Meal.init(from:)` | Decodes meals while preserving compatibility with older macro, source, confidence, component, and photo fields. |
| `Macros.calories` | Computes calories from protein, carbs, and fat. |
| `Micronutrients.totals(for:)` | Aggregates micronutrient snapshots across meals. |
| `Micronutrients.populatedFieldCount` / `completeness` / `hasAnyValue` | Measure micronutrient data coverage. |
| `Micronutrients.scaled(by:)` | Scales all populated micronutrient values by a recipe/portion multiplier. |
| `Micronutrients.add(_:)` | Adds another micronutrient set into the receiver while preserving nil semantics. |
| `MicronutrientGapAnalyzer.gaps(from:windowDays:)` | Computes covered/gap/unknown nutrient statuses over a 7- or 14-day window. |
| `FoodItem.calories` | Returns macro calories for catalog or custom food items. |
| `FoodSelectionPlan.ingredients` | Flattens planned meal items into one ingredient list. |
| `MealItemSplitter.items(from:)` | Splits a free-form meal description into candidate item phrases. |
| `FoodSelectionCandidateBuilder.candidates(for:foodItems:limit:)` | Builds ranked candidate food items from search phrases and catalog matches. |
| `RecipeUnit.normalized(_:)` | Maps free-form unit strings to known recipe units. |
| `RecipeIngredient.scaledMacros(using:)` | Computes ingredient macros using food item serving/gram equivalence. |
| `RecipeIngredient.scaledMicronutrients(using:)` | Computes ingredient micronutrients using the same scaling rules as macros. |
| `ManualRecipeIngredientInput.macros` / `trimmedName` | Exposes cleaned manual ingredient values for recipe creation. |
| `ManualRecipeIngredientInput.resolvedMacros(foodItems:)` | Uses a selected catalog food item when present, otherwise manual macro entry. |
| `ManualRecipeIngredientInput.selectedFoodItem(in:)` | Resolves the selected food item ID against a supplied catalog. |
| `Macros.scaled(by:)` | Scales macro grams for portions and recipe ingredient math. |
| `FoodItem.preferredRecipeUnit` | Chooses the best default recipe unit from serving metadata and portions. |
| `FoodItem.defaultRecipeQuantity(for:)` | Supplies a reasonable starting quantity for a recipe unit. |
| `FoodItem.gramsEquivalent(quantity:unit:)` | Converts a quantity/unit pair to grams when portion data supports it. |
| `FoodPortion.recipeUnit` | Maps food portion text to a `RecipeUnit` when possible. |
| `FoodPortion.grams(for:)` | Converts portion quantity to grams. |
| `NutritionTargets.macroTotals` | Exposes target macros in the same aggregate type used by meals. |
| `NutritionTargetCalculator.targets(for:)` | Computes calorie, protein, carb, fat, fiber, sodium, and saturated-fat targets from settings. |
| `Workout.exerciseLines` | Splits workout exercise text into trimmed lines for display and classification. |
| `Workout.inferredCategory` | Infers workout category from explicit type or exercise text. |
| `Workout.init(from:)` / `encode(to:)` | Preserve compatibility for newer activity, muscle, HealthKit, and planning fields. |
| `WorkoutExerciseCatalog.inferredCategory(for workout:)` | Infers workout category from a `Workout`. |
| `WorkoutExerciseCatalog.inferredCategory(for text:)` | Scores free-form exercise text against known movement categories. |
| `WorkoutExerciseCatalog.targetSummary(for:)` | Produces a muscle/equipment summary for a workout. |
| `WorkoutExerciseCatalog.search(_:)` | Searches bundled exercise targets. |
| `SleepQuality.description` | Returns human-readable sleep-quality copy. |
| `HygieneItem.label` / `systemImage` / `group` | Centralize personal-care display metadata. |
| `PersonalCareTask.defaultTasks` | Defines default hygiene-backed personal-care tasks. |
| `PersonalCareTask.defaultHygieneItem` | Maps a task back to its legacy hygiene item when present. |
| `PersonalCareTask.custom(label:group:)` | Creates a stable-ID custom personal-care task. |
| `PersonalCareTask.normalized(_:)` | De-duplicates tasks and preserves display-safe defaults. |
| `MemoryNote.fromJournal(text:tag:)` | Extracts a bounded memory note from a journal entry when text is present. |
| `GoalType.init(from:)` | Decodes goal types with compatibility for older/raw values. |

### `LocalFernletRepository.swift`

| Function Or Type | What It Does |
| --- | --- |
| `FernletRepository` protocol | Defines the shared load/save/update contract used by local JSON and Core Data repositories. |
| `FernletRepository.loadDay(for:todayKey:)` default | Loads a snapshot for a date key and returns its day aggregate. |
| `FernletSnapshot.init(...)` | Builds the full persisted snapshot contract for current day, settings, history, food, recipes, scores, retry, proximity logs/trust, and audit data. |
| `FernletSnapshot.init(from:)` | Decodes snapshots with defaults for fields added after older saved data. |
| `LocalFernletDatabase.init(from:)` | Decodes the full local database with defaults for older schema fields and derived tables. |
| `LocalFernletRepository.init(fileURL:)` | Resolves the JSON database URL and configures ISO-8601 coding. |
| `loadSnapshot(todayKey:)` | Loads the database, selects or creates today's day, and returns a `FernletSnapshot`. |
| `saveSnapshot(_:)` | Applies a snapshot, rebuilds derived tables, and atomically writes the JSON database. |
| `updateDay(_:for:todayKey:)` | Replaces one date's day, rebuilds derived tables, and saves without rebuilding the whole store state in memory. |
| `databaseFileURL()` | Exposes the JSON file URL for diagnostics or migration code. |
| `storageDescription()` | Returns the visible local storage description. |
| `loadAllDays()` | Decodes the database and returns all stored day aggregates. |
| `loadTierTwoMemories()` | Reads tier-two memory records directly from the database. |
| `loadDatabaseForMigration(todayKey:)` | Exposes private database loading to Core Data migration. |
| `loadDatabase(todayKey:)` | Loads JSON if present, otherwise builds a migrated legacy database. |
| `decodeDatabase(_:todayKey:)` | Decodes JSON into `LocalFernletDatabase`, falling back to legacy migration on failure. |
| `saveDatabase(_:)` | Encodes the database and writes it after ensuring the directory exists. |
| `ensureDirectoryExists()` | Creates the Application Support/Fernlet directory tree. |
| `write(_:)` | Writes protected JSON atomically. |
| `migratedDatabase(todayKey:)` | Creates a database from legacy `UserDefaults` keys. |
| `loadLegacy(_:key:)` | Decodes one legacy `UserDefaults` value. |
| `defaultFileURL()` | Builds the default Application Support JSON path. |
| `makeEncoder()` / `makeDecoder()` | Configure pretty/sorted JSON and ISO-8601 dates. |
| `LegacyKeys.day(_:)` | Builds the legacy per-day `UserDefaults` key. |
| `LocalFernletDatabase.apply(_:)` | Copies snapshot fields into the database and updates `updatedAt`. |
| `LocalFernletDatabase.rebuildDerivedTables(todayKey:)` | Rebuilds daily, meal, workout, journal, derived signal, and tier-two memory tables. |
| `sortedDayPairs(_:)` | Orders day records and enforces max stored days. |
| `makeDailyLogs(from:)` | Builds daily rollup records from stored days. |
| `makeMealLogs(from:)` | Builds capped meal log records with daily macro totals. |
| `makeWorkoutLogs(from:)` | Builds capped workout log records. |
| `makeJournalLogs(from:)` | Builds capped journal log records. |
| `makeDerivedSignals(from:todayKey:)` | Builds recent-window derived signals through `DerivedSignalFactory`. |
| `DailyLogRecord.init(dateKey:day:)` | Converts a day into daily score/audit fields. |
| `DailyLogRecord.init(from:)` | Decodes older daily logs with defaults for optional fields. |
| `MealLogRecord.init(dateKey:meal:totals:)` | Converts a meal into a denormalized log row. |
| `MealLogRecord.init(from:)` | Decodes older meal logs with default source and micronutrient fields. |
| `WorkoutLogRecord.init(dateKey:workout:)` | Converts a workout into a denormalized log row. |
| `JournalLogRecord.init(dateKey:journal:)` | Converts a journal into a capped log row. |
| `MacroTotals.init(meals:)` | Computes macro totals with per-day meal caps. |
| `DerivedSignalFactory.makeSignals(from:todayKey:)` | Produces mood, energy, eating, progression, readiness, and micronutrient signals for a recent window. |
| `moodTrend(from:start:end:)` | Classifies mood direction and gentleness need from journal tags. |
| `energyTrend(from:start:end:)` | Classifies energy trend from sleep, mood, and training load. |
| `eatingPattern(from:start:end:)` | Classifies meal consistency, skipped days, and protein-forward patterns. |
| `intensityReadiness(from:start:end:)` | Classifies suggested training intensity from recent load, energy, meals, and hard workouts. |
| `progressionTrend(from:start:end:)` | Compares older/newer training load to classify building, deloading, or steady patterns. |
| `micronutrientTrend(from:start:end:windowDays:)` | Converts nutrient gap analysis into a derived signal. |
| `dailyMoodScores(from:)` / `dailyEnergyScores(from:)` | Convert day records into trend input scores. |
| `trendValue(scores:rising:falling:steady:)` | Converts score deltas into trend labels. |
| `moodScore(_:)` / `sleepEnergyScore(_:)` / `dailyTrainingLoad(_:)` / `average(_:)` | Shared scoring helpers for derived signal logic. |
| `TierTwoMemoryEngine.updateInferences(existing:from:goals:)` | Updates longer-term behavioral memory records only when state changes. |
| `prune(_:)` | Caps tier-two memories per category and globally, preferring active/recent records. |
| `goalBehaviorGap(window:goals:)` | Infers alignment between stated goals and logged behavior. |
| `consistencyProfile(window:)` | Infers overall logging consistency. |
| `journalAvoidancePattern(window:)` | Detects repeated avoidance language in journal text. |
| `workoutMoodCorrelation(window:)` | Compares mood on workout days versus rest days. |

### `CoreDataFernletRepository.swift`

| Function | What It Does |
| --- | --- |
| `remoteChangePublisher` | Exposes repository-level remote-change notifications after cache invalidation. |
| `init(controller:legacyRepository:)` | Wires the Core Data controller, legacy JSON migrator, coders, and remote-change subscription. |
| `loadSnapshot(todayKey:)` | Synchronously loads the database and maps it into a snapshot. |
| `loadSnapshotAsync(todayKey:)` | Async-loads and decodes the Core Data payload, using cache when possible and migrating legacy data when no record exists. |
| `loadDay(for:todayKey:)` | Loads one day from the cached/persisted database. |
| `saveSnapshot(_:)` | Applies a snapshot, rebuilds derived tables, and saves the database payload to Core Data. |
| `updateDay(_:for:todayKey:)` | Updates one date's day in the payload, rebuilds derived tables, and saves. |
| `storageDescription()` | Returns the user-facing storage location string. |
| `invalidateCache()` | Clears cached database state and emits a remote-change event. |
| `invalidateCacheIfRecordChanged()` | Checks the Core Data record timestamp and invalidates only when it changed. |
| `loadAllDays()` | Returns all days from the current database payload. |
| `loadTierTwoMemories()` | Returns tier-two memory records from the current database payload. |
| `loadDatabase(todayKey:)` | Uses cache, fetches the primary record, migrates from legacy JSON when absent, and decodes payload data. |
| `saveDatabase(_:)` | Encodes the database into the single primary Core Data record and updates cache metadata. |
| `fetchRecordUpdatedAt()` | Reads the latest primary record timestamp. |
| `fetchRecord()` | Fetches the primary `FernletDatabaseRecord` by record ID. |
| `migrateDatabase(todayKey:)` | Loads the legacy local database for first Core Data save. |
| `snapshot(from:todayKey:)` | Converts a database payload into a `FernletSnapshot`. |
| `decodeDatabaseAsync(from:)` | Decodes the payload off the main synchronous path while keeping signpost timing. |
| `makeEncoder()` / `makeDecoder()` | Configure sorted JSON payload coding and ISO-8601 dates. |

### `FernletStore.swift`

| Function Or Property | What It Does |
| --- | --- |
| `allFoodItems` | Combines bundled and user food catalogs for searches and meal building. |
| `webImportedFoodItems` | Filters saved food items to web imports. |
| `allowsWebNutritionLookup` | Gates web lookup behind settings and AI availability. |
| `savedRecipes`, `trustedProximityPeers`, `trainerAuditEvents`, `retryQueue`, `derivedSignals` | Expose extracted service/vault state through the store. |
| `init(date:repository:savedRecipeRepository:healthKitService:journalNarrativeRepository:)` | Loads the active repository snapshot, saved recipes, trust vault, retry queue, journal repository, inspector, save hooks, derived signals, and remote reload subscription. |
| `private init(snapshot:todayKey:repository:savedRecipeService:healthKitService:)` | Builds a store from an already loaded snapshot for async startup. |
| `score` / `companionState` | Compute current day score and companion state from store data. |
| `macroTotals` / `micronutrientTotals` / `nutritionTargets` | Compute nutrition aggregates and targets for current settings/day. |
| `tierTwoMemories` | Loads behavioral memory records from the repository. |
| `personalCareTasks` | Returns normalized settings-backed personal-care tasks. |
| `personalCareProgress(for:)` | Counts completed personal-care tasks for a day. |
| `isPersonalCareTaskCompleted(_:in:)` | Checks completion by task ID or legacy hygiene item. |
| `storeDaySummary(_:for:)` | Stores a bounded daily summary in `dailyScores`, creating a score if needed. |
| `invalidateDaySummary(for:)` | Clears a stored day summary and schedules persistence. |
| `storeCompanionThought(_:)` | Stores a trimmed in-memory companion thought. |
| `storageLocation` | Delegates storage description to the repository. |
| `pendingRetryCount` | Exposes queued AI retry count. |
| `isIntimateLoggingAllowed` | Gates intimate logging by user age. |
| `setHidePredictions(_:)`, `setHideFertileWindow(_:)`, `setConnectionInspectorMode(_:)`, `setProximityDisplayName(_:)`, `setShowProximityDebugTools(_:)`, `setAllowNearbyRecipeShares(_:)` | Mutate related settings and schedule persistence; recipe-share disabling stops the share manager. |
| `replaceConnectionSessionLogs(_:)` | Sorts and caps stored connection logs. |
| Proximity trust wrappers | Delegate peer lookup, trust, revoke, block, unblock, audit, and trust-policy checks to `ProximityTrustVault`; see `ProximityFunctionIndex.md`. |
| `setHomeWidgets(_:)` / `setQuickLogItems(_:)` | Normalize and persist home/quick-log customization. |
| `allowedHealthCapabilities(from:)` / `visibleHealthCapabilities` | Gate HealthKit capabilities by age and lock state. |
| `addMeal(...)` | Parses and logs a manual meal for today or a supplied date. |
| `addResolvedMeal(...)` / `addResolvedMeals(...)` | Resolve a meal through Foundation dish decomposition, candidate AI, deterministic lexicon, deterministic plan, or fallback parser; queues retry on fallback. |
| `appendMeal(_:date:)` | Central meal append path that mutates the right day, invalidates summaries, updates recents, and schedules one save. |
| `copyMeal(_:)` | Copies a meal for today and appends it. |
| `deleteMeal(_:)` | Removes a current-day meal and deletes its photo if present. |
| `updateMealCorrection(...)` | Applies manual nutrition/name/type correction to current day and recent meal copies. |
| `correctedNutrition(macros:componentSnapshots:)` | Uses component totals when component snapshots exist; otherwise keeps manual macros. |
| `applyMealCorrection(...)` | Updates meal nutrition, note, confidence, fallback flag, and quality. |
| `attachMealPhoto(mealID:photoID:)`, `mealPhotoData(for:)`, `saveMealPhoto(_:)` | Bridge meal photo attachment and storage through `MealPhotoStore`. |
| `logRecipe(_:)`, `logSavedRecipe(_:)`, `logWebImportedFoodProduct(_:)` | Convert local recipes, saved URL recipes, or imported products into logged meals. |
| Saved recipe wrappers | Delegate share text, add, update, and delete to `SavedRecipeService`. |
| `addWorkout(_:date:)` | Appends a workout, invalidates summaries, persists, and saves to HealthKit when appropriate. |
| `refreshWorkoutsFromHealth()` / `backfillWorkoutsFromHealthIfNeeded(defaults:)` | Delegate HealthKit import/backfill to `WorkoutHealthKitSync`. |
| `addJournal(text:tag:)` | Seals a journal entry, appends it today, updates previous journals, and may create a memory note. |
| `setSleep(hours:quality:note:)`, `setHealthSleepHours(_:)`, `updateHealthContext(_:)`, `addBottle()`, `removeBottle()` | Mutate daily sleep, HealthKit context, and hydration with persistence scheduling. |
| `toggleHygiene(_:)`, `togglePersonalCareTask(_:)`, `setPersonalCareTask(_:completed:)` | Route hygiene/personal-care completion through normalized task IDs. |
| `addPersonalCareTask(label:group:)` / `removePersonalCareTask(_:)` | Mutate custom personal-care tasks and clean current-day completion state. |
| `mutatePastDay(_:_:)` | Loads, mutates, and saves a non-today day directly through the repository. |
| `loadDays()` / `loadDay(for:)` | Return all days or one day while overlaying today's in-memory state. |
| `score(for:)` / `dailyHealthScore(for:day:)` | Compute scores for arbitrary day records and reuse stored summaries when present. |
| Past-date journal/sleep/hydration/personal-care functions | Add, update, delete, or set values on any date through `mutateDay(date:_:)`. |
| `replaceGoals(_:)` / `completeOnboarding(profile:preferences:goal:)` | Persist goal list replacement and first-run profile/preferences setup. |
| `addRecipe(...)`, `updateRecipe(...)`, `deleteRecipe(_:)` | Create, edit, and remove local recipes while resolving custom ingredients. |
| `saveCustomIngredient(_:)` | Upserts one manual ingredient into the custom food catalog. |
| `cachedWebImportedFoodProduct(for:)` / `saveWebImportedFoodProduct(_:)` | Reuse or upsert imported branded food products by normalized query/name. |
| `macroTotals(for:)` / `micronutrientTotals(for:)` | Compute local recipe nutrition from current food catalog data. |
| `recipeShareText(for:)`, `proximityRecipeSharePayload(for:)` | Build share text or proximity payloads through `RecipeShareCodec`. |
| `importProximityRecipeShare(_:)` / `importRecipe(from:)` | Import local or saved recipes from proximity/share payloads, creating ingredients and saved recipes as needed. |
| `addTexture(_:)`, `deleteMemory(_:)`, `updateMemory(_:category:text:)` | Mutate workshop texture notes and memory records. |
| `queueMealRetry(_:)`, `clearRetryItem(_:)` | Delegate AI retry queue operations. |
| `resetAll()` | Resets store state, saved recipes, retry queue, and proximity trust/audit state. |
| `rebuildDerivedSignals()` | Rebuilds derived signals from all days. |
| `deferredPostLaunchTasks()` | Schedules a one-time deferred derived signal rebuild. |
| `flushPendingSnapshotSave()` | Forces any pending debounced snapshot save to run now. |
| `reloadFromRepository()` | Debounced remote reload handler that async-loads Core Data when available and applies a snapshot. |
| `apply(_:)` | Replaces in-memory store state from a snapshot and reapplies extracted service/vault state. |
| `currentSnapshot()` | Builds the persistable snapshot, stripping sealed journal text before cloud-eligible storage. |
| `strippedForStorage(day:previousJournals:)` | Returns day/journal copies with sealed text and emotions removed. |
| `batchSnapshotPersistence(_:)` | Runs synchronous mutations and schedules one debounced snapshot save. |
| `markLaunchScreenDismissed()` | Placeholder hook for launch UI lifecycle. |
| `ensureBundledFoodItemsSeeded()` | Starts one async bundled food load and stores returned catalog items. |
| `activateNoLockJournals()` | Uses the device journal key to seal legacy plaintext journals and hydrate sealed text. |
| `activateSealedJournals(contentKey:)` | Sets the user content key, migrates device-key entries, hydrates text, and seals legacy plaintext. |
| `deactivateSealedJournals()` | Scrubs sealed journal text/emotions from memory and clears the content key. |
| `deviceJournalKey` | Loads or creates the device-bound fallback journal sealing key. |
| `sealJournalEntry(_:dayKey:)` | Writes journal text/emotions to `JournalNarrativeRepository` and marks the entry sealed. |
| `migrateDeviceKeyEntriesToUserKey(userKey:)` | Re-encrypts device-key narratives under the user content key. |
| `refreshSealedJournals(contentKey:)` | Hydrates empty journal entries from sealed narrative storage. |
| `migrateExistingJournalsToSealedStore(contentKey:)` | One-time migration that seals plaintext journal entries and schedules a stripped snapshot save. |
| `mutateDay(date:_:)` | Mutates today in memory or routes past dates through `mutatePastDay`. |
| `workoutExists(id:)` / `workoutExists(healthKitUUID:)` | Support HealthKit duplicate checks across all days. |
| `setWorkoutHealthKitUUID(workoutID:hkUUID:date:)` | Finds a workout across today/past days and stores its HealthKit UUID. |
| `upsertWorkout(_:date:)` | Workout sync insertion hook; currently delegates to `addWorkout(_:date:)`. |
| `static load(date:repository:statusUpdate:)` | Async startup loader that creates repositories/services, loads snapshot and saved recipes, and returns a ready store. |

### `FernletStoreLoader.swift`

| Function | What It Does |
| --- | --- |
| `startIfNeeded()` | Starts store loading exactly once and updates phase. |
| `retry()` | Resets loader state and attempts startup loading again. |
| `loadStore()` | Calls `FernletStore.load`, forwards status messages, and transitions to ready or failed phase. |

## Persistence Controllers

### `Persistence.swift`

| Function Or Property | What It Does |
| --- | --- |
| `PersistenceController.shared` | Creates the app-wide Core Data controller from keychain storage preferences while currently forcing iCloud sync off at startup. |
| `PersistenceController.preview` | Creates an in-memory controller for previews. |
| `init(inMemory:preferences:storeURL:iCloudAvailable:)` | Builds, loads, configures, and observes the main persistent container. |
| `reload(with:)` | Saves/reset old context, removes stores, rebuilds the container for new preferences, loads stores async, and publishes a remote-change notification. |
| `activeStoreDescription` / `activeStoreURL` | Expose the current persistent store metadata. |
| `makeContainer(inMemory:preferences:storeURL:iCloudAvailabilityOverride:)` | Builds the correct persistent container and store description for in-memory, local, or CloudKit-backed modes. |
| `configure(_:inMemory:preferences:storeURL:iCloudAvailabilityOverride:)` | Sets file protection, history tracking, remote-change posting, migration, store URL, backup behavior, and CloudKit options. |
| `loadPersistentStores(for:preferences:inMemory:recoverOnFailure:)` | Loads stores synchronously, falls back from CloudKit no-account errors, and can destroy/recreate corrupt stores when recovery is allowed. |
| `loadPersistentStoresAsync(for:preferences:inMemory:)` | Async store loading path used by reload, with CloudKit no-account fallback. |
| `applyBackupExclusionIfNeeded(preferences:storeDescription:inMemory:)` | Excludes the store file from iOS backup when preferences request it. |
| `configureViewContext(for:)` | Sets merge policy and automatic parent-change merging. |
| `bindRemoteChanges(to:)` | Bridges Core Data remote-change notifications into `remoteChangePublisher`. |
| `saveAndLockViewContext(_:)` | Saves pending changes and resets the old view context before reload. |
| `removePersistentStores(from:)` | Removes all persistent stores from a coordinator during reload. |
| `makeManagedObjectModel()` | Builds the main cloud-safe model entities in code. |
| `makeFernletDatabaseRecordEntity()` | Defines the single blob record entity for `LocalFernletDatabase` payload data. |
| `makeSavedRecipeRecordEntity()` | Defines saved URL recipe records in the main store. |
| `makeAttribute(...)` | Creates optional Core Data attributes for programmatic models. |

### `CoreDataFernletRepository.swift`

See the repository section above. `CoreDataFernletRepository` owns the single-record app database payload inside the container configured by `PersistenceController`.

### `PrivatePersistenceController.swift`

| Function Or Type | What It Does |
| --- | --- |
| `PrivatePersistenceController.shared` / `preview` | Provide the local-only sealed-data persistent container. |
| `init(inMemory:)` | Builds and loads `FernletPrivate` with complete file protection, history tracking, migration, no CloudKit, and merge configuration. |
| `makeManagedObjectModel()` | Builds the private model for menstrual narratives, journal narratives, and intimacy logs. |
| `makeMenstrualNarrativeEntity()` | Defines encrypted menstrual narrative columns and a date-key index. |
| `makeJournalNarrativeEntity()` | Defines local-only journal metadata plus sealed text/emotion columns and a day-key index. |
| `makeIntimacyLogEntity()` | Defines local-only intimacy metadata plus sealed note columns and a day-key index. |
| `makeAttribute(...)` | Creates optional Core Data attributes for private model entities. |
| `PrivatePersistentHistoryPruner.prune(context:before:)` | Deletes private-store persistent history before a date. |

### `StoragePreferences.swift`

| Function Or Type | What It Does |
| --- | --- |
| `StoragePreferences.init(...)` | Captures iCloud, backup, HealthKit, sealed backup, and modification-date preferences. |
| `defaultHealthKitCapabilityEnabled` | Builds default disabled HealthKit capability flags for all capabilities. |
| `StoragePreferencesStore.init(keychainService:now:)` | Loads preferences from keychain or defaults. |
| `update(_:)` | Applies a mutation, updates `lastModifiedAt`, publishes, and persists to keychain. |
| `persist(_:)` | Encodes and stores preferences in keychain. |
| `loadPreferences(service:)` | Reads and decodes keychain preferences with default fallback. |

## Extracted Store Services

### `SnapshotSaveCoordinator.swift`

| Function | What It Does |
| --- | --- |
| `RemoteChangePublishingRepository.remoteChangePublisher` | Protocol hook for repositories that can publish remote changes. |
| `init(repository:debounce:buildSnapshot:onAfterSave:)` | Captures the repository, debounce interval, snapshot builder, and post-save hook. |
| `schedule()` | Cancels any pending save and schedules a new debounced snapshot save. |
| `flushPending()` | Cancels debounce and immediately saves the current snapshot. |
| `subscribeRemote(remoteReloadDebounce:handler:)` | Subscribes to repository remote changes and schedules debounced reloads. |
| `performSnapshotSave()` | Saves the built snapshot and runs the post-save hook. |
| `scheduleRemoteRepositoryReload(debounce:handler:)` | Debounces remote reload handling. |

### `AIRetryQueueService.swift`

| Function | What It Does |
| --- | --- |
| `init(initial:onChange:)` | Seeds the queue and installs a persistence-change callback. |
| `pendingCount` | Returns queued retry count. |
| `queueMealRetry(_:)` | Appends a meal retry record with the standard failed-analysis message. |
| `clear(id:)` | Removes a retry by ID and triggers `onChange`. |
| `apply(_:)` | Replaces queue state from a snapshot without triggering persistence. |
| `reset()` | Clears the queue. |

### `DerivedSignalsService.swift`

| Function | What It Does |
| --- | --- |
| `rebuild(allDays:todayKey:)` | Rebuilds observed derived signals through `DerivedSignalsRebuilder`. |
| `scheduleDeferredRebuild(allDaysProvider:todayKey:)` | Schedules a one-time utility-priority rebuild after launch. |
| `flushDeferredRebuild()` | Runs the pending deferred rebuild immediately if one exists. |

### `DerivedSignalsRebuilder.swift`

| Function | What It Does |
| --- | --- |
| `rebuild(allDays:todayKey:windowDays:)` | Sorts all days, takes the recent window, and delegates signal creation to `DerivedSignalFactory`. |

### `SavedRecipeService.swift`

| Function | What It Does |
| --- | --- |
| `init()` / `init(repository:initialRecipes:)` | Wires the saved recipe repository and optional initial state. |
| `loadAsync()` / `loadSync()` | Loads saved URL recipes from the repository. |
| `add(_:)` | De-duplicates by source URL, inserts newest first, and schedules a save. |
| `update(_:)` | Replaces a saved recipe by ID and schedules a save. |
| `delete(_:)` | Removes a saved recipe by ID and schedules a save. |
| `reset()` | Clears saved recipes and schedules a save. |
| `flushPendingSave()` | Writes scheduled saved recipe changes immediately. |
| `shareText(for:)` | Builds user-shareable saved recipe text with macros, summary, ingredients, and source URL. |
| `makeMeal(from:mealType:)` | Converts a saved URL recipe into a `Meal`. |
| `scheduleSave()` | Debounces repository writes until the next main-actor turn. |

### `BundledFoodSeedingService.swift`

| Function | What It Does |
| --- | --- |
| `init(loadBundledItems:)` | Stores an async loader, defaulting to a utility-priority bundled catalog load. |
| `load()` | Runs once from `.notStarted`, publishes seeding/done state, and returns bundled food items. |

### `LaunchPreparationService.swift`

| Function Or Type | What It Does |
| --- | --- |
| `PhotowallPhotoRanking.rankedCandidates(from:context:)` | Strategy protocol for ordering photowall photo candidates. |
| `RandomPhotowallPhotoRanking.rankedCandidates(from:context:)` | Default shuffled photo ranking. |
| `PhotowallPhotoSelector.init(defaults:historyKey:ranking:)` | Wires history persistence and ranking strategy. |
| `selectPhotoIDs(from:count:context:)` | De-duplicates photos, prefers IDs not recently selected, stores the new history, and returns selected IDs. |
| `previousPhotoIDs()` | Reads prior photowall photo IDs from `UserDefaults`. |
| `LaunchPreparationService.init(photowallPhotoSelector:)` | Configures launch preparation and photowall selection. |
| `prepare(store:)` | Runs one launch preparation pass: photowall seeds, yesterday summary, companion thought, HealthKit backfill, status timing, and launch completion. |
| `buildPhotowallSeeds(store:)` | Builds four home photowall seeds from memories and selected mesh photos. |
| `generateDaySummary(for:)` | Optional async day-summary path that avoids replacing an existing summary. |
| `makeDaySummaryText(for:store:)` | Uses FoundationModels when available, otherwise deterministic summary text. |
| `deterministicDaySummary(for:)` | Builds a compact summary from meals, workouts, sleep, hydration, and journal tag. |
| `deterministicDaySummaryForYesterday(store:)` | Builds yesterday's deterministic summary when there is log data and no existing summary. |
| `generateCompanionThought(for:)` | Optional async companion thought path using FoundationModels when available. |
| `deterministicThought(for:)` | Selects companion thought text from derived signal values. |
| `isFoundationModelAvailable` | Delegates FoundationModels availability to food-selection availability. |
| `yesterdayKey()` | Computes yesterday's Fernlet date key. |
| `foundationModelsDaySummary(for:)` | Builds and audits a day-summary payload, prompts an on-device model, and returns bounded text. |
| `foundationModelsThought(for:)` | Builds and audits signal/memory context, prompts an on-device model, and returns a short observation. |

### `PendingNarrativeBuffer.swift`

| Function Or Type | What It Does |
| --- | --- |
| `PendingNarrativePayload` | Encodes HealthKit external ID, date key, and encrypted narrative field bytes for deferred sealing. |
| `append(_:)` | Loads encrypted buffer entries, appends one, evicts oldest entries past the cap, audits eviction, and saves. |
| `drainAll()` | Loads all buffered payloads, purges the file, and returns entries for unlocked processing. |
| `purge()` | Deletes the pending buffer file. |
| `loadEntries()` | Opens the ChaChaPoly buffer file with the buffer key and decodes payloads. |
| `saveEntries(_:)` | Encodes, encrypts, atomically writes, excludes from backup, and marks complete file protection. |
| `bufferKey()` | Loads or creates the background-accessible buffer key. |
| `loadBufferKey()` | Reads the buffer key from the data-protection keychain. |
| `createAndStoreBufferKey()` | Creates a 256-bit buffer key and stores it as after-first-unlock-this-device-only. |
