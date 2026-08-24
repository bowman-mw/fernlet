# Store, Repository, And Extracted Service Function Index

This index maps the core store, repository, persistence, and extracted store service functions to their responsibilities. Use it before adding data mutation, save/load, derived signal, retry queue, saved recipe, launch preparation, storage preference, or sealed-buffer behavior so existing lifecycle code is reused instead of duplicated.

**Last refreshed: 2026-08-20.** This pass removed a hotspot row and a whole section for
`BundledFoodSeedingService`, a type that no longer exists in any form; corrected the
`loadPersistentStores` entry, which advertised a corrupt-store recovery capability the app does not
have; re-pointed the `Models.swift` section at the `FernletDomainModel` files it was split into; and
added the localization token/display rule. The 2026-08-09 pass added the AI routing/budget seam
(gate, router, quota, audit log), the `AppendOnlyRowStore` engine and the three ledger services built
on it, `RowPayloadCoders`, and the CloudKit heart-drop transport.


## Duplication Hotspots

| Need | Prefer Reusing |
| --- | --- |
| Mutating app state and scheduling persistence | `FernletStore.batchSnapshotPersistence(...)`, `FernletStore.mutateDay(date:_:)`, `SnapshotSaveCoordinator.schedule()` |
| Loading or saving the whole app snapshot | `FernletRepository.loadSnapshot(todayKey:)`, `saveSnapshot(_:)`, `CoreDataFernletRepository`, `LocalFernletRepository`. 2026-08 consolidation: both backends now assemble snapshots through the shared `FernletSnapshot.assembled(todayKey:day:from:)` (LocalPersistence), and their duplicated JSON encoder/decoder factories were consolidated into `RowPayloadCoders` (FernletFoundation). |
| Routing any AI call | `FernletAIGate.dispatch(tier:userInvoked:)` — never call a model provider directly; the gate is the sole quota-charge point and the sole capability cap. |
| Device-local (never-synced) counters and ledgers | `UserDefaultsAICallQuotaStore`, `FileAIAuditLogStore`, `WorkoutTombstoneStore` — the established pattern for state that must stay off the synced blob. |
| Append-only per-row cloud stores | `AppendOnlyRowStore` (CloudKitSync) — the generic engine behind the coin, milestone, and custom-item repositories. |
| Past-date day edits | `FernletStore.loadDay(for:)`, `loadDays()`, `mutateDay(date:_:)`, `FernletRepository.updateDay(_:for:todayKey:)` |
| Main app Core Data / CloudKit container setup | `PersistenceController.reload(with:)`, `makeContainer(...)`, `configure(...)`. 2026-08 consolidation: the `NSAttributeDescription` factory previously duplicated across the CloudKitSync and PrivateStoreCore model builders now lives in `CoreDataModelBuilding.makeAttribute(...)` (FernletFoundation). |
| Local-only sealed narrative storage | `PrivatePersistenceController`, `JournalNarrativeRepository`, `MenstrualNarrativeRepository`, `PendingNarrativeBuffer`. 2026-08 consolidation: the four duplicated keyless bulk-delete sequences in the narrative/intimacy repositories were consolidated into `PrivateRowPlumbing.deleteRows(...)` (PrivateStoreCore), and `PendingNarrativeBuffer`'s raw SecItem keychain idiom now routes through the shared `KeychainItem` helpers (FernletFoundation). **2026-08-10 (backup coverage):** the sealed-backup surface first built on `MenstrualNarrativeRepository` — keyless row count, paged reader in a total order, all-or-nothing `insertAtomically`, and the injected-`UserDefaults` one-way divergence latch — is now mirrored on `JournalNarrativeRepository` (`narrativeCount` / `narratives(offset:limit:contentKey:)` / `insertAtomically` / `hasEverStoredNarrative`) and `IntimacyLogRepository` (`logCount` / `logs(offset:limit:contentKey:)` / `insertAtomically` / `hasEverStoredLog`). Three near-identical implementations by design (three entities, three column sealers); extend all three together or none. |
| Debounced snapshot saves and remote reloads | `SnapshotSaveCoordinator.schedule()`, `flushPending()`, `subscribeRemote(...)`. 2026-08 consolidation: the separate four-way debounced pending-write idiom in the row/ledger services was consolidated into `StoreCore/PendingWriteBuffer.swift` (`DebouncedRowBuffer` / `DebouncedAppendBuffer`), which now backs `SavedRecipeService`, `CustomItemService`, `CoinLedgerService`, and `MilestoneLedgerService`. |
| AI retry queue lifecycle | `AIRetryQueueService.queueMealRetry(_:)`, `clear(id:)`, `apply(_:)`, `reset()` |
| Derived signal rebuilds | `DerivedSignalsService.rebuild(...)`, `scheduleDeferredRebuild(...)`, `DerivedSignalsRebuilder.rebuild(...)`, `DerivedSignalFactory.makeSignals(...)`. 2026-08 consolidation: the FeelingTag-to-mood-score table previously duplicated in `DerivedSignalFactory` and `TierTwoMemoryEngine` was consolidated into `FeelingTag.moodScore` (LocalPersistence/FeelingTagMoodScale.swift). |
| Saved URL recipe persistence and logging | `SavedRecipeService.add(_:)`, `update(_:)`, `delete(_:)`, `makeMeal(from:mealType:)`. 2026-08 consolidation: the service's debounce/pending-write plumbing now sits on the shared `DebouncedRowBuffer` (StoreCore/PendingWriteBuffer.swift), and the cloned per-row ledger repositories (coin/milestone/custom item) were consolidated onto the generic `AppendOnlyRowStore` engine (CloudKitSync). |
| Bundled catalog loading | `FoodCatalog.bundled(bundle:)` + `FoodCatalog.setUserItems(_:)` (FoodCatalog module), and `attachBrandedSource(_:)` / `detachBrandedSource()` for the On-Demand-Resource branded catalog. There is nothing to *seed*: the ~13k bundled foods are a read-only SQLite store queried on demand, so `DiaryStore.ensureBundledFoodItemsSeeded()` and `loadBundledFoodItemsForLaunch()` are deliberate no-op shims kept only so the launch/UI call sites keep a stable seam. `BundledFoodSeedingService` is GONE — if you are here because an older copy of this index sent you to it, do not recreate it. `FoodDataCatalog` is generation-time only (`foodItems(from:)`, `sourceJSONFoodItems(directory:)`); the app never reads the source JSON at runtime. |
| Launch photowall/day summary/companion thought prep | `LaunchPreparationService.prepare(store:)`, `PhotowallPhotoSelector.selectPhotoIDs(...)` |
| Keychain-backed storage preferences | `StoragePreferencesStore.update(_:)`, `StoragePreferences.defaultHealthKitCapabilityEnabled`. 2026-08 consolidation: the last inline duplicate of the preferences load (in `PersistenceController.shared`) was consolidated onto `StoragePreferencesStore.currentPreferences()`. |
| A user-visible string on a persisted model | FORK IT. See "Tokens vs. display" below — localizing a `rawValue` that a repository writes is silent data loss. |

## Tokens vs. display

Localization Phase 1 (2026-08-19) drew a line through every string in the codebase, and this
subsystem is on the dangerous side of it: **what a repository writes is a token, and tokens are
English forever.** Persist on the token, sign the token, prompt with the token, compare against the
token; render the label. Never the reverse, and never localize a raw value in place — the sealed
columns decode with `compactMap`, so a row whose key no longer matches is not an error, it is a row
that quietly disappears.

The types that were forked, and what to write:

| Type | Persist / compare | Render |
| --- | --- | --- |
| `CareGroup` | `token` (== the frozen `rawValue`) | `label` |
| `MealConfidence` | `token`; `legacyTokens` maps the pre-fork English phrases already sitting in users' blobs back to a case | `label` |
| `MealType` | `rawValue` (FROZEN — persisted on every meal AND the vocabulary the meal-parsing prompt hands the model, round-tripped as `MealType(rawValue:)`) | `displayName` |
| `WorkoutType` | `rawValue` (FROZEN — persisted on workout rows, matched by `WorkoutExerciseCatalog.inferType`, and part of the trainer export; the four legacy spellings stay decodable) | `displayName` |
| `CompanionState` | `rawValue` (FROZEN — persisted on `DailyHealthScore`, byte-mirrored by `WidgetCompanionState` in a SEPARATE PROCESS via the app-group snapshot, and a field of the Coach export schema) | `displayName` |
| `CoachPlanTokens` vocabularies | the token vocabularies, which are also what the export prompt publishes to plan authors | the app's own copy |

`Tests/FernletTests/LocalizationBoundaryTests.swift` is the wall: it pins those raw values case by
case and grep-walls `String(localized:)` inside `FernletKit/Sources` for the `bundle: .module`
argument a package needs (without it the lookup resolves against `Bundle.main`, finds nothing, and
silently returns the English literal). Run `Scripts/sync-string-catalogs.sh` after adding or changing
a user-facing string and commit the catalog diff with the code change.

## Store And Snapshot Contract

### Domain value types — `FernletKit/Sources/FernletDomainModel/` (formerly `Models.swift`)

`Models.swift` no longer exists. The SPM carve-up split it into the nonisolated, portable value
types of `FernletDomainModel`, and the rows below now live in:
`NutritionModels.swift` (meals, macros, micronutrients, food items, recipe ingredients, meal types),
`WorkoutModels.swift` (workouts, workout types, the exercise catalog),
`WellbeingModels.swift` (`FernletDay`, `HealthDailyContext`, hygiene/personal care, `MemoryNote`,
`GoalType`), `SettingsModel.swift` (`FernletSettings`, `UserNutritionProfile`, nutrition targets,
quick-log shortcuts), `NavigationEnums.swift` (`HomeWidget`, shortcut normalization), and
`CompanionModels.swift` (`CompanionState` and friends). Grep the symbol, not the filename — the
split is by concern, not alphabetical.

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
| `Meal.copyForToday(mealType:)` | Copies a meal with a new ID and current logged timestamp for repeat logging, optionally re-slotting it. |
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
| `FernletSnapshot.assembled(todayKey:day:from:)` | Shared read-side slice mapping — builds the snapshot from an already-resolved day plus a `LocalFernletDatabase`'s aggregate slices. Both repositories call it; day resolution stays at the call sites because it differs per backend. The read-side counterpart of `LocalFernletDatabase.apply(_:maxStoredDays:)`. |
| `LocalFernletRepository.init(fileURL:)` | Resolves the JSON database URL and configures coding through `RowPayloadCoders` (pretty-printed). |
| `loadSnapshot(todayKey:)` | Loads the database, selects or creates today's day, and returns `FernletSnapshot.assembled(...)`. |
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
| `RowPayloadCoders.makeEncoder(prettyPrinted:)` / `makeDecoder()` | The shared sorted-keys + ISO-8601 coder config (FernletFoundation) that replaced this file's private `makeEncoder()` / `makeDecoder()`; this repository opts into `prettyPrinted` for its on-disk blob. |
| `LegacyKeys.day(_:)` | Builds the legacy per-day `UserDefaults` key. |
| `LocalFernletDatabase.apply(_:maxStoredDays:)` | Copies snapshot fields into the database, updates `updatedAt`, and trims the blob's own `days` window when a bound is passed (the Core Data path bounds it; the local path passes nil). |
| `LocalFernletDatabase.rebuildDerivedTables(todayKey:recentDays:)` | Rebuilds daily, meal, workout, journal, and tier-two memory tables, optionally over an injected bounded day window. |
| `sortedDayPairs(_:)` | Orders day records oldest-first by date key. |
| `makeDailyLogs(from:)` | Builds daily rollup records from stored days. |
| `makeMealLogs(from:)` | Builds capped meal log records with daily macro totals. |
| `makeWorkoutLogs(from:)` | Builds capped workout log records. |
| `makeJournalLogs(from:)` | Builds capped journal log records. |
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
| `sleepEnergyScore(_:healthSleepHours:)` / `dailyTrainingLoad(_:)` / `average(_:)` | Shared scoring helpers for derived signal logic. |
| `FeelingTag.moodScore` | The single 0.2–1.0 tag-to-mood-score scale (`FeelingTagMoodScale.swift`), replacing the private `moodScore(_:)` copies this factory and `TierTwoMemoryEngine` each carried. |
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
| `fetchRecordResult()` | Fetches the primary `FernletDatabaseRecord` by record ID, distinguishing a found record, no record, and a failed fetch. |
| `migrateDatabase(todayKey:)` | Loads the legacy local database for first Core Data save. |
| `snapshot(from:todayKey:)` | Resolves today's day from its `DayRecord` row (with the pre-migration blob fallback), then maps the blob-held aggregates through the shared `FernletSnapshot.assembled(todayKey:day:from:)`. |
| `decodeDatabaseAsync(from:)` | Decodes the payload off the main synchronous path while keeping signpost timing. |
| `RowPayloadCoders.makeEncoder(prettyPrinted:)` / `makeDecoder()` | The shared sorted-keys + ISO-8601 payload coder config this repository (and every other per-row store) encodes through; it moved from `CloudKitSync` to `FernletFoundation`. |

### `FernletStore.swift`

| Function Or Property | What It Does |
| --- | --- |
| `allFoodItems` | Combines bundled and user food catalogs for searches and meal building. |
| `webImportedFoodItems` | Filters saved food items to web imports. |
| `allowsWebNutritionLookup` | Gates web lookup behind settings and AI availability. |
| `savedRecipes`, `trustedProximityPeers`, `trainerAuditEvents`, `retryQueue`, `derivedSignals` | Expose extracted service/vault state through the store. |
| `init(date:repository:savedRecipeRepository:customItemRepository:coinLedgerRepository:milestoneLedgerRepository:healthKitService:journalNarrativeRepository:foodCatalog:sensitiveVisibilityDefaults:aiAuditLogStore:appGroupDirectory:sharedRecipeImportQueueFileURL:photoDocumentsDirectory:proximitySupportDirectory:heartDropKeychainService:aiQuotaDefaults:)` | Every dependency is defaulted; loads the active repository snapshot, saved recipes, custom items, coin/milestone ledgers, trust vault, retry queue, journal repository, inspector, save hooks, derived signals, and remote reload subscription. **Seven of these are per-instance ISOLATION seams**, each nil/`.standard` meaning the production identity: `appGroupDirectory` (guided + cooking run state, widget queue, widget snapshot), `sharedRecipeImportQueueFileURL` (the share-extension recipe inbox — the app-group container's other tenant, a file rather than a directory), `photoDocumentsDirectory` (own-photo corpora), `proximitySupportDirectory` (the whole proximity sidecar root), `heartDropKeychainService` (the sealed sidecars' key), `aiQuotaDefaults` (the AI-call counter's defaults suite), `sensitiveVisibilityDefaults` (the period/intimacy visibility resolution **and** the age verdict, which share one suite by design). Tests pass their own so a wipe in one store cannot reach another's — seven grep-walls in `Tests/FernletTests/PhotoDirectoryIsolationTests` enforce it. |
| `private init(snapshot:todayKey:repository:savedRecipeService:customItemService:coinLedgerService:milestoneLedgerService:healthKitService:foodCatalog:)` | Builds a store from an already loaded snapshot for async startup. |
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
| `logCatalogFoodItem(_:)`, `logRecipe(_:)`, `logSavedRecipe(_:)`, `logWebImportedFoodProduct(_:)` | Convert an exact catalog pick (as one editable serving), local recipe, saved URL recipe, or imported product into a logged meal. |
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
| `rememberFoodSearchCorrections(_:)` / `publishFoodSearchCorrectionAliases()` | Research §26 fix 1.10's local correction memory: record the search-text → chosen-food pairs a SAVED "Adjust meal" replace produced (`FoodSearchCorrectionMemory`, a device-local `UserDefaults` sidecar, never synced between devices, capped at 200), and republish the alias map into `FoodCatalog.setSearchAliases` — at launch, after every write, and (as an empty map) on the wipe path. `forgetAllFoodSearchCorrections()` is the user-facing clear behind Privacy & data's "Forget corrected searches" row (returns the count it forgot); `foodSearchCorrectionCount` drives that row's text. |
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
| `FernletSnapshot.forStorage(...)` | The strip itself, in the nonisolated `FernletPersistence` module: returns the `SanitizedSnapshot` with sealed journal text/emotions and sensitive health fields removed. Sealing state is passed in as the sealed-ID set. |
| `batchSnapshotPersistence(_:)` | Runs synchronous mutations and schedules one debounced snapshot save. |
| `markLaunchScreenDismissed()` | Placeholder hook for launch UI lifecycle. |
| `ensureBundledFoodItemsSeeded()` | Starts one async bundled food load and stores returned catalog items. |
| `activateNoLockJournals()` | Uses the device journal key to seal legacy plaintext journals and hydrate sealed text. |
| `activateSealedJournals(contentKey:)` | Sets the user content key, migrates device-key entries, hydrates text, and seals legacy plaintext. |
| `deactivateSealedJournals()` | Scrubs sealed journal text/emotions from memory and clears the content key. |
| `deviceJournalKey` | Loads or creates the device-bound fallback journal sealing key through the shared `KeychainItem.loadOrCreateSymmetricKey(for:service:)` (FernletFoundation), which replaced the per-caller copies of that mint-on-first-use idiom. |
| `seal(_:dayKey:)` | Writes journal text/emotions to `JournalNarrativeRepository` and marks the entry sealed. |
| `migrateDeviceKeyEntriesToUserKey(userKey:)` | Re-encrypts device-key narratives under the user content key. |
| `refreshSealedJournals(contentKey:)` | Hydrates empty journal entries from sealed narrative storage. |
| `migrateExistingJournalsToSealedStore(contentKey:)` | One-time migration that seals plaintext journal entries and schedules a stripped snapshot save. |
| `mutateDay(date:_:)` | Mutates today in memory or routes past dates through `mutatePastDay`. |
| `workoutExists(id:)` / `workoutExists(healthKitUUID:)` | Support HealthKit duplicate checks across all days. |
| `setWorkoutHealthKitUUID(workoutID:hkUUID:date:)` | Finds a workout across today/past days and stores its HealthKit UUID. |
| `upsertWorkout(_:date:)` | Workout sync insertion hook; currently delegates to `addWorkout(_:date:)`. |
| `static load(date:repository:statusUpdate:)` | Async startup loader that creates repositories/services, loads snapshot and saved recipes, and returns a ready store. |

The journal-sealing rows above (`activateNoLockJournals()` through `migrateExistingJournalsToSealedStore(contentKey:)`, plus `deviceJournalKey` and `seal(_:dayKey:)`) now live on `JournalSealingCoordinator` (`App/Fernlet/JournalSealingCoordinator.swift`), which the store owns and reaches through the `JournalSealingContext` host protocol.

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
| `PersistenceController.shared` | Creates the app-wide Core Data controller from `StoragePreferencesStore.currentPreferences()` while currently forcing iCloud sync off at startup. |
| `PersistenceController.preview` | Creates an in-memory controller for previews. |
| `init(inMemory:preferences:storeURL:iCloudAvailable:)` | Builds, loads, configures, and observes the main persistent container. |
| `reload(with:)` | Saves/reset old context, removes stores, rebuilds the container for new preferences, loads stores async, and publishes a remote-change notification. |
| `activeStoreDescription` / `activeStoreURL` | Expose the current persistent store metadata. |
| `makeContainer(inMemory:preferences:storeURL:iCloudAvailabilityOverride:)` | Builds the correct persistent container and store description for in-memory, local, or CloudKit-backed modes. |
| `configure(_:inMemory:preferences:storeURL:iCloudAvailabilityOverride:)` | Sets file protection, history tracking, remote-change posting, migration, store URL, backup behavior, and CloudKit options. |
| `loadPersistentStores(for:preferences:inMemory:historyRetention:)` | Loads stores synchronously and RETURNS whether the load failed (latched into `didFailToLoad`). Its only recovery is the CloudKit **no-account** case (`NSCocoaErrorDomain` 134400): it clears `cloudKitContainerOptions` and retries local-only, because the store is healthy and only mirroring is unavailable. Every other error is reported, not repaired. |
| `loadPersistentStoresAsync(for:preferences:inMemory:historyRetention:)` | The `async throws` path used by `reload(with:)`, with the same no-account fallback and the same "no other recovery" rule. |
| `finishSuccessfulLoad(container:preferences:storeDescription:inMemory:historyRetention:)` | The single funnel every successful load goes through (first load, no-account retry, both reload variants): backup exclusion, then the local-only history prune. |
| `localOnlyHistoryRetention` / `pruneUnconsumedHistory(before:in:)` | Persistent history is always ON (remote-change notifications need it), but only a CloudKit mirroring delegate ever CONSUMES and trims it — so on a store loaded without CloudKit options (sync off, the cold-launch default, or no iCloud account) the history tables grew for the life of the install. The prune drops everything older than the 7-day window on a background context; a prune failure is audit-logged, never allowed to fail the load. |
| `didFailToLoad` / `PersistenceStoreLoadError.primaryStoreUnavailable` | The latch and the user-facing error the app-side startup flow throws from it. The copy deliberately stresses that **data was not deleted** and points at the two usual causes (device just restarted and still locked, storage full). |
| `applyBackupExclusionIfNeeded(preferences:storeDescription:inMemory:)` | Excludes the store file from iOS backup when preferences request it, `includeSupportDir: true` so the sibling `.<StoreName>_SUPPORT/` directory CloudKit provisions for mirroring metadata is covered too. |
| `configureViewContext(for:)` | Sets merge policy and automatic parent-change merging. |
| `bindRemoteChanges(to:)` | Bridges Core Data remote-change notifications into `remoteChangePublisher`. |
| `saveAndLockViewContext(_:)` | Saves pending changes and resets the old view context before reload. |
| `removePersistentStores(from:)` | Removes all persistent stores from a coordinator during reload. |
| `makeManagedObjectModel()` | Builds the main cloud-safe model entities in code. |
| `makeFernletDatabaseRecordEntity()` | Defines the single blob record entity for `LocalFernletDatabase` payload data. |
| `makeSavedRecipeRecordEntity()` | Defines saved URL recipe records in the main store. |
| `CoreDataModelBuilding.makeAttribute(_:type:defaultValue:allowsExternalBinaryDataStorage:)` | The shared optional-attribute factory (FernletFoundation) both programmatic model builders now call; it replaced the private `makeAttribute(...)` copy in this file. |
| `makeCustomItemRecordEntity()` / `makeCoinLedgerRecordEntity()` / `makeMilestoneLedgerRecordEntity()` / `makeDayRecordEntity()` | The remaining programmatic entities: custom items, the two append-only ledgers, and the per-row `DayRecord` split. All cloud-safe; no sealed entity is ever modeled here (S3). |
| `initializeCloudKitSchemaIfRequested(inMemory:)` / `performCloudKitSchemaDeploy()` / `cleanUpScratchStore(container:scratchURL:)` | DEBUG-only, launch-argument-gated schema deploy against a throwaway scratch store (see [CloudKit-Schema-Deploy.md](CloudKit-Schema-Deploy.md)). Compiled out of Release entirely. |
| `pruneUnconsumedHistoryForTesting(before:)` | Test seam for the prune above. |

> **Correction (2026-08-20) — the app cannot recover a corrupt store, and has not been able to since
> 2026-06-22.** This section described a `recoverOnFailure:` parameter and claimed the loader "can
> destroy/recreate corrupt stores when recovery is allowed." That was true once: the original loader
> took `recoverOnFailure` and, on a non-no-account error, called
> `destroyPersistentStore(at:ofType:)` and reloaded. **A code review deleted that path in `863be33`**
> — destroying a user's local records to make a load succeed is exactly the silent data loss this app
> refuses — and this index never caught up.
>
> If you planned work on the strength of the old line, none of it is backed by code: there is no
> corruption recovery, no "just let it rebuild" fallback, and no store to assert was destroyed. What
> the loader does is retry local-only on the CloudKit no-account error and otherwise latch
> `didFailToLoad`, which the app surfaces as `PersistenceStoreLoadError.primaryStoreUnavailable` —
> copy that promises the user, in as many words, that their data was not deleted. Advertising a
> recovery capability the app deliberately gave up is the worst kind of index error, because it is
> the kind someone builds on.


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
| `makeWorryNarrativeEntity()` | Defines local-only Worry Box metadata plus sealed text columns. |
| `CoreDataModelBuilding.makeAttribute(_:type:defaultValue:allowsExternalBinaryDataStorage:)` | The same shared attribute factory the synced model builder uses (FernletFoundation); it replaced this file's private copy, so the two builders cannot drift. |
| `purgeEncryptedEntities()` | Destructive lock-reset wipe; deliberately batches all sealed entities under a single save rather than using `PrivateRowPlumbing.deleteRows(...)`, so the wipe stays atomic across entities. |
| `PrivatePersistentHistoryPruner.prune(context:before:)` | Deletes private-store persistent history before a date. |

### `PrivateRowPlumbing.swift`

| Function | What It Does |
| --- | --- |
| `PrivateRowPlumbing.deleteRows(entityName:in:)` | The shared keyless whole-entity fetch → delete → save → history-prune sequence the sealed repositories' `deleteAll()` methods each repeated inline (journal, worry, intimacy, menstrual narratives). Deletes without decrypting, so deletion stays available while the app is locked or the feature is hidden; returns whether any row was deleted and rethrows fetch/save/prune errors. Deliberately takes no predicate/limit: `performAndWait`'s closure is `@Sendable`, and no caller ever filtered. |

### `AppendOnlyRowStore.swift`

The generic per-row Core Data + CloudKit engine behind `CoinLedgerRepository`, `MilestoneLedgerRepository`, and the other append-only stores — the consolidation of what used to be cloned repositories.

| Function | What It Does |
| --- | --- |
| `load()` / `loadAsync()` | Fetch and decode all rows. |
| `append(_:)` | Batch upsert. **Known limitation:** the `existingByID` map is not refreshed mid-batch, so a single call containing two entries with the same id would insert duplicate local rows; current callers never pass intra-batch duplicates. |

### `RowPayloadCoders.swift`

| Function | What It Does |
| --- | --- |
| `RowPayloadCoders.makeEncoder(prettyPrinted:)` / `makeDecoder()` | The single JSON encoder/decoder pair for row payloads, consolidating the duplicated factories the two repository backends each carried. |

### `HeartDropCloudTransport.swift`

The production `HeartDropTransporting` conformer — the app's only CloudKit **public**-database use. It sees rotating day tags and ciphertext, never identities.

| Function | What It Does |
| --- | --- |
| `accountAvailable()` | Gates sync on a usable iCloud account. |
| `upload(tag:payload:)` | Writes one sealed drop, returning the server record name the outbox needs for its own expiry cleanup. |
| `fetch(tags:)` | Fetches a friend's tag window. |
| `chunked(_:)` / `perChunkBudget(chunkCount:)` | Per-chunk anti-starvation budgeting so one friend's tags cannot consume the whole pass. |
| `deleteOwnRecords(recordNames:)` | Expiry sweep of records this device wrote. |

**Owner action:** the `HeartDrop` record type (`tag` queryable, `payload` bytes) must be promoted from the CloudKit Development schema to Production — dev auto-creates it on first save, production will not. See [CloudKit-Schema-Deploy.md](CloudKit-Schema-Deploy.md).

### `StoragePreferences.swift`

| Function Or Type | What It Does |
| --- | --- |
| `StoragePreferences.init(...)` | Captures iCloud, backup, HealthKit, sealed backup, and modification-date preferences. |
| `defaultHealthKitCapabilityEnabled` | Builds default disabled HealthKit capability flags for all capabilities. |
| `StoragePreferencesStore.init(keychainService:now:)` | Loads preferences from keychain or defaults. |
| `update(_:)` | Applies a mutation, updates `lastModifiedAt`, publishes, and persists to keychain. |
| `persist(_:)` | Encodes and stores preferences in keychain. |
| `currentPreferences(service:)` | The `nonisolated` shared read — a pure keychain read plus JSON decode — for callers that need the persisted preferences without holding a store instance (`PersistenceController.shared`, `PrivatePersistenceController`, `CloudKitDataService`, `HealthKitService`). |
| `loadPreferences(service:)` | Reads and decodes keychain preferences with default fallback; the private body behind `currentPreferences(service:)` and the store's own load. |

## AI Routing And Budget Seam

The provider seam every AI call site funnels through (Ladder §3). Lives in `AIContext`; the walled
`AIProviders` module reaches the device-local counter and audit sink only through the protocols
declared here, never by naming the app-target types that implement them.

### `FernletAIGate.swift`

| Function | What It Does |
| --- | --- |
| `dispatch(tier:userInvoked:)` | The single entry point: resolves a route and returns the destination, or `nil` for the deterministic path. **The only place the daily quota is charged** — exactly once per dispatch. |
| `resolveRoute(tier:userInvoked:)` | Same resolution, returning the full `AIRouteResolution` when the caller needs the fallback reason. |

### `FernletModelRouter.swift`

| Function | What It Does |
| --- | --- |
| `resolve(...)` | Picks the cheapest destination meeting the declared tier, capped by device capability and the user's configured ceiling. |
| `stepDown(...)` | Escalation-ladder descent when a rung is unavailable. |
| `finalize(_:tier:)` | Applies the release-build fail-closed pin. **Known inaccuracy:** a light-tier destination leaving the device returns `.deterministicFallback(.deviceIncapable)`, which mislabels a sensitive-work pin as a capability limit (safe direction, wrong reason). |

### `AICallQuota.swift`

| Function | What It Does |
| --- | --- |
| `AICallQuota.dayKey(for:calendar:)` | Day-key rollover, pinned to a Gregorian/`en_US_POSIX` calendar so behavior cannot vary with the user's calendar preference. |
| `effectiveCount(now:calendar:)` / `recordingCall(now:calendar:)` | Read and increment as a pure value; the caller persists device-locally. |
| `derivedStatus(...)` / `effectiveStatus(...)` | The derived `.sleepy` / `.resting` states. **These must never be written back into synced `FernletSettings`**, or one device's usage would throttle another. |
| `AICallQuotaStore` (protocol) | `currentQuota()` / `reset()` — implemented app-side by `UserDefaultsAICallQuotaStore`. |

### `AIAuditLog.swift`

| Function | What It Does |
| --- | --- |
| `record(...)` | Logs one AI call's payload kind, destination, `modelIdentifier`, included field names, and memory char count — metadata only, never content. |
| `updateOutcome(id:to:)` / `AIAuditOutcome.fromModelError(_:)` | Completion-side outcome stamping, including refusals. |
| `configure(sink:)` | Installs the persistence sink; `AIAuditLogPersisting` (`load`/`save`/`clear`) is implemented app-side by `FileAIAuditLogStore`. |
| `clear()` | Wipe path. |

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
| `init(repository:initialRecipes:)` | Wires the saved recipe repository, builds the shared `DebouncedRowBuffer` over its upsert/delete primitives, and de-duplicates any initial state by ID. |
| `loadAsync()` / `loadSync()` | Loads saved URL recipes from the repository, union-merged by ID through `Array.deduplicatedByID()`. |
| `reloadFromStore()` | Flushes first, re-reads the store, then re-applies still-pending buffer mutations so a failed write never drops a recipe from the in-memory list. |
| `add(_:)` | De-duplicates by source URL, inserts newest first, and enqueues the upsert (plus deletes for superseded rows). |
| `update(_:)` | Replaces a saved recipe by ID and enqueues its upsert. |
| `delete(_:)` | Removes a saved recipe by ID and enqueues its delete. |
| `reset()` | Clears saved recipes, clears the buffer so a pending write cannot resurrect them, and returns whether the persisted rows were deleted. |
| `flushPendingSave()` | Delegates to `DebouncedRowBuffer.flush()` — writes pending upserts/deletes now, keeping a failed queue for retry. |
| `shareText(for:)` | Builds user-shareable saved recipe text with macros, summary, ingredients, and source URL. |
| `makeMeal(from:mealType:)` | Converts a saved URL recipe into a `Meal`. |

The debounce/queue mechanics this service used to own now live in `PendingWriteBuffer.swift` (below), shared with `CustomItemService`, `CoinLedgerService`, and `MilestoneLedgerService`.

### `CoinLedgerService.swift`

| Function | What It Does |
| --- | --- |
| `loadSync()` / `loadAsync()` / `reloadFromStore()` | Hydrate the append-only coin ledger from its per-row store (the design that replaced the unsound "derive earned from day history" model — day history shrinks). |
| `reconcile(activeDayKeys:)` | Mints any missing earn rows for active days, capped so future-day minting cannot run away. |
| `grantEarns(_:)` / `spend(amount:ref:)` | Append earns; `spend` returns `false` rather than going negative. |
| `reset()` / `flushPendingSave()` | Wipe path and the debounce flush. |

### `MilestoneLedgerService.swift`

| Function | What It Does |
| --- | --- |
| `loadSync()` / `loadAsync()` / `reloadFromStore()` | Hydrate the append-only milestone ledger. |
| `record(_:)` | Appends milestone rows, idempotently by deterministic id. |
| `reset(deletingRowsWith:)` | Wipe path (added 2026-08-20, reversing the earlier survive-a-reset rule): drops the pending queue, runs the injected row delete (`MilestoneLedgerRepository.deleteAll()`, narrowed by the deletion funnel), then — since 2026-08-21 — appends a `resetBoundary` marker (with the coin service's failed-append retry), so re-synced pre-wipe rows are voided by aggregation; in-memory state afterwards is `[marker]`. `CloudKitDataService.allRecordTypes` sweeps the milestone record types too. |
| `flushPendingSave()` | Debounce flush. |

### `CustomItemService.swift`

| Function | What It Does |
| --- | --- |
| `loadSync()` / `loadAsync()` / `reloadFromStore()` | Hydrate custom clothing items from the per-row store. |
| `upsert(_:)` / `delete(id:)` | Row mutations through the shared `DebouncedRowBuffer`. |
| `setShareable(id:_:)` / `setPrice(id:_:)` | Friend-shop listing controls. |
| `reset()` | Wipe path. |

### `PendingWriteBuffer.swift`

| Function Or Type | What It Does |
| --- | --- |
| `DebouncedRowBuffer<Item>` | The debounced per-row pending-write queue shared by `SavedRecipeService` and `CustomItemService`. Its write closures capture the owning service's repository, never the service. |
| `DebouncedRowBuffer.enqueueUpsert(_:)` / `enqueueDelete(_:)` | Queue a row mutation keyed by ID (each cancels a pending opposite for the same ID) and schedule the debounced flush. |
| `DebouncedRowBuffer.flush()` | Writes pending upserts/deletes now, clearing each queue only after its confirmed write; a failed write keeps that queue for retry and never traps. |
| `DebouncedRowBuffer.pendingUpserts` / `pendingDeletes` / `hasPending` | Read-only queue state for the owner's `reloadFromStore()` re-merge after a failed flush. |
| `DebouncedRowBuffer.clear()` | Drops every queued mutation and any scheduled flush — for the owner's `reset()`, where a pending write must not resurrect deleted rows. |
| `DebouncedAppendBuffer<Entry>` | The append-only variant shared by `CoinLedgerService` and `MilestoneLedgerService`; `enqueue(_:)` deliberately schedules nothing so callers batch N rows and call `scheduleSave()` once per burst. |
| `DebouncedAppendBuffer.flush()` / `pending` / `clear()` | Same durability contract as the row buffer: `pending` is the sole un-persisted copy, cleared only after a confirmed append. |
| `scheduleSave()` | Coalesces mutations into one debounced main-actor flush per burst; the task's weak self-capture keeps "owner gone → flush skipped" semantics. Private on `DebouncedRowBuffer` (the enqueues call it), public on `DebouncedAppendBuffer` (the ledger services call it once per batch). |

### `LaunchPreparationService.swift`

| Function Or Type | What It Does |
| --- | --- |
| `PhotowallPhotoRanking.rankedCandidates(from:context:)` | Strategy protocol for ordering photowall photo candidates. |
| `RandomPhotowallPhotoRanking.rankedCandidates(from:context:)` | Uniform shuffle; the injectable test baseline, and the behavior favorite weighting degrades to when nothing is hearted. |
| `FavoriteWeightedPhotowallPhotoRanking.rankedCandidates(from:context:)` | The production default ranking — hearted photos drawn ~3× as often, via the seedable `WeightedPhotowallOrdering.weightedOrder(ids:favoriteIDs:favoriteWeight:using:)`. |
| `PhotowallPhotoSelector.init(defaults:historyKey:ranking:)` | Wires history persistence and ranking strategy (defaulting to the favorite-weighted ranking). |
| `selectPhotoIDs(from:count:context:)` | De-duplicates photos, prefers IDs not recently selected, stores the new history, and returns selected IDs. |
| `previousPhotoIDs()` | Reads prior photowall photo IDs from `UserDefaults`. |
| `LaunchPreparationService.init(photowallPhotoSelector:)` | Configures launch preparation and photowall selection. |
| `prepare(store:)` | Runs one launch preparation pass: guided-workout and cooking run reconciliation, data-export sweep, photowall seeds, day-summary backfill, companion thought, HealthKit backfill, status timing, and launch completion. |
| `buildPhotowallSeeds(store:)` | Builds four home photowall seeds from memories and selected mesh photos. |
| `backfillDaySummaries(for:)` | Generates missing day summaries for logged past days, newest first, capped per run and gated to once per calendar day. |
| `makeDaySummaryText(for:store:)` | Returns a FoundationModels day summary when available; otherwise nil, leaving the slot intentionally empty (spec) rather than filling deterministic text. |
| `generateCompanionThought(for:)` | Optional async companion thought path using FoundationModels when available. |
| `deterministicThought(for:)` | Selects companion thought text from derived signal values. |
| `isFoundationModelAvailable` | Delegates FoundationModels availability to food-selection availability. |
| `foundationModelsDaySummary(for:gate:)` | Builds and audits a day-summary payload, prompts an on-device model, and returns bounded text. |
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
| `loadBufferKey()` | Reads the buffer key through the shared `KeychainItem.load(account:service:)`, migrating a legacy v1 row into the scoped v2 slot via `KeychainItem.store(...)`. |
| `loadLegacyServicelessKey()` | Raw `SecItemCopyMatching` read of the service-less v1 key — the one keychain call `KeychainItem` cannot express; dies with the v1 migration. |
| `createAndStoreBufferKey()` | Creates a 256-bit buffer key and stores it after-first-unlock-this-device-only through `KeychainItem.store(...)`. |
