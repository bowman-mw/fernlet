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
| Device-local (never-synced) counters and ledgers | `UserDefaultsAICallQuotaStore`, `FileAIAuditLogStore`, `WorkoutTombstoneStore`, `FileDeviceHealthResidueStore` — the established pattern for state that must stay off the synced blob. **Derived data that must never leave the device** (not even in a device backup): `TierTwoMemoryStore` (LocalPersistence, 2026-09-23 owner decision) — a sidecar beside the local database, backup-excluded after every write, re-derived by the next save if lost. |
| Keeping a value off iCloud while THIS device keeps using it (HealthKit readings, 2026-09-23) | The strip/residue/overlay triple in `FernletPersistence/HealthKitStorageStrip.swift`: `FernletDay.strippingHealthKitValues()` (applied by the one sanitize boundary), `healthKitResidue` (what the strip removes), `overlayingHealthKitResidue(_:)` (puts it back on read), stored through `DeviceHealthResidueStoring`. `DiaryStore` overlays on every read and records a past day's residue in `mutatePastDay`; the facade records today's at the HealthKit ingestion points only (never on a save — see `FernletStore+HealthKitResidue.swift` for why). The same cache holds the HealthKit BODY-PROFILE import (`DeviceHealthBodyProfile`): record it with `FernletStore.recordHealthImportedBodyProfile(_:)`, read the profile through `effectiveUserProfile` / `effectiveSettings` (never `settings.userProfile` for anything computed from the body), and route a profile-screen edit through `applyEditedBodyProfile(_:)`. Do not add a second strip or a second cache. |
| Writing anything INTO Apple Health (2026-09-23) | `HealthKitService.save(_:)` for samples, `HealthKitService.saveWorkout(_:)` for workouts — the only two doors, both behind the private `requireWriteSharing(_:)` gate (master switch AND that kind's own switch; a closed one throws `HealthKitServiceError.sharingTurnedOff`). Callers that would rather skip than catch ask `HealthKitServicing.isWriteSharingEnabled(for:)`. Never call `HKHealthStore` or build an `HKWorkoutBuilder` anywhere else — `HealthKitWriteGateTests` scans the tree for a third door. Deleting Fernlet's OWN samples at the user's request is deliberately NOT gated; an edit (delete-then-write) checks the write half first. |
| Append-only per-row cloud stores | `AppendOnlyRowStore` (CloudKitSync) — the generic engine behind the coin, milestone, and custom-item repositories. |
| Answering a failed store or file operation | `PersistenceFailureAudit.record(_:error:context:)` (FernletFoundation) — NEVER `assertionFailure` in the `catch`. A Core Data fetch/save/delete, a file write/remove, or the payload encode that feeds one can fail environmentally (complete-protection store unreadable while the device is locked, full disk, rolled-back context), so every such site audits the frozen dotted token plus the error's `NSError` domain/code and returns its existing `false`/empty result (P9 item 1, 2026-09-19). One exception to "returns its failure result": a batch row that will not ENCODE is skipped and audited while the batch still reports `true` (`AppendOnlyRowStore.append`, `DayRecordRepository.upsert`, `SavedRecipeRepository.upsert`) — a `false` would retry-loop on the same non-finite value forever, and the saved-recipe site clears `payloadData` so the dropped blob cannot out-vote the fresh legacy columns on the next read. Programmer-error guards (empty day key, unreachable enum case) keep their assert. |
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
| `MemoryNote.emotionOnly(for:)` (`JournalMemoryCapture.swift`) | Mints a journal entry's Core Memory as its `FeelingTag` token with no text (entries under 20 characters mint none). Replaced `fromJournal`, which stored a 120-character excerpt (owner decision 2026-09-23). |
| `JournalMemorySummaryPolicy.accepted(_:entryText:)` (`JournalMemoryCapture.swift`) | Accepts an AI journal summary as memory text only if bounded, free of diagnostic language, and not verbatim / a prefix / an excerpt of the entry. |
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
| `saveSnapshot(_:)` | Applies a snapshot, rebuilds derived tables, atomically writes the JSON database, then refreshes the device-local Tier-2 sidecar from the same day window. |
| `updateDay(_:for:todayKey:)` | Replaces one date's day, rebuilds derived tables, saves without rebuilding the whole store state in memory, then refreshes the Tier-2 sidecar. |
| `databaseFileURL()` | Exposes the JSON file URL for diagnostics or migration code. |
| `storageDescription()` | Returns the visible local storage description. |
| `loadAllDays()` | Decodes the database and returns all stored day aggregates. |
| `loadAllDaysWithUnreadable()` | `loadAllDays()` as a `DayHistoryRead` that does not account for every row while the file is in read-only recovery (unreadable or undecodable) — the read the journal Sealed backup's snapshot uses (B3 fix rounds 1 and 2). The file decodes whole or not at all, so no single day is ever named unreadable. |
| `loadTierTwoMemories()` | Reads tier-two memory records from the device-local `TierTwoMemoryStore` sidecar — never from the database file (2026-09-23). |
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
| `LocalFernletDatabase.rebuildDerivedTables(todayKey:recentDays:)` | Rebuilds the daily, meal, workout, and journal tables, optionally over an injected bounded day window. Tier-two memories are no longer a database slice — the repositories refresh `TierTwoMemoryStore` after a successful save instead. |
| `sortedDayPairs(_:)` | Orders day records oldest-first by date key (module-internal: the local repository reuses one ordering for the derived tables and the Tier-2 refresh). |
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
| `DerivedSignalFactory.makeSignals(from:todayKey:isSickToday:)` | Produces mood, energy, eating, progression, readiness, and micronutrient signals for a recent window. |
| `moodTrend(from:start:end:)` | Classifies mood direction and gentleness need from journal tags. |
| `energyTrend(from:start:end:)` | Classifies energy trend from sleep, mood, and training load. |
| `eatingPattern(from:start:end:)` | Classifies meal consistency, skipped days, and protein-forward patterns. |
| `intensityReadiness(from:start:end:isSickToday:)` | Classifies suggested training intensity from recent load, energy, meals, and hard workouts; a day marked unwell is `needs rest` first (spec §6a). |
| `progressionTrend(from:start:end:)` | Compares older/newer training load to classify building, deloading, or steady patterns. |
| `micronutrientTrend(from:start:end:windowDays:)` | Converts nutrient gap analysis into a derived signal. |
| `dailyMoodScores(from:)` / `dailyEnergyScores(from:)` | Convert day records into trend input scores. |
| `trendValue(scores:rising:falling:steady:)` | Converts score deltas into trend labels. |
| `sleepEnergyScore(_:healthSleepHours:)` / `dailyTrainingLoad(_:)` / `average(_:)` | Shared scoring helpers for derived signal logic. |
| `FeelingTag.moodScore` | The single 0.2–1.0 tag-to-mood-score scale (`FeelingTagMoodScale.swift`), replacing the private `moodScore(_:)` copies this factory and `TierTwoMemoryEngine` each carried. |
| `TierTwoMemoryEngine.updateInferences(existing:from:goals:)` | Updates longer-term behavioral memory records only when state changes. Driven only by `TierTwoMemoryStore.refresh(from:goals:)`. |
| `TierTwoMemoryStore.refresh(from:goals:)` | Runs the engine against the persisted records and rewrites the sidecar only when the result changed; best-effort (audited, retried by the next save), never fails the caller's save. |
| `TierTwoMemoryStore.load()` / `purge()` / `sidecarURL(besideDatabaseAt:)` | Reads the device-local records; deletes the sidecar for "delete everything"; derives the per-database sidecar path (`<stem>-TierTwoMemories.json`). |
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
| `saveSnapshot(_:)` | Applies a snapshot, rebuilds derived tables, saves the database payload to Core Data, then refreshes the device-local Tier-2 sidecar from the same bounded window. |
| `updateDay(_:for:todayKey:)` | Updates one date's day in the payload, rebuilds derived tables, saves, then refreshes the Tier-2 sidecar. |
| `storageDescription()` | Returns the user-facing storage location string. |
| `invalidateCache()` | Clears cached database state and emits a remote-change event. |
| `invalidateCacheIfRecordChanged()` | Checks the Core Data record timestamp and invalidates only when it changed. |
| `loadAllDays()` | Returns all days from the current database payload (the memo, else `readAllDays()`). |
| `loadAllDaysWithUnreadable()` / `readAllDays()` | The day history that says what it could not read (B3 fix rounds 1 and 2): `DayRecordRepository.loadAllWithUnreadable()` names the day of every row whose payload will not decode (`unreadableDayKeys` — the journal snapshot keeps every entry on it instead of stopping over a row nothing heals) and does not account for every row after a failed fetch or with a row that has no date key, nor does read-only recovery; the memo keeps the unreadable days of the read that installed it (`cachedUnreadableDayKeys`, nil when that read did not account for every row, and such a memo is dropped and read again, never served here). `readAllDays()` is the shared uncached read (rows, blob-only overlay, memo install). The protocol defaults (`FernletRepository`, `DayRecordRepositoring`) call every read whole — only stateless doubles may inherit them. |
| `loadTierTwoMemories()` | Returns tier-two memory records from the device-local sidecar it shares with its legacy repository — the mirrored payload has carried none since 2026-09-23. |
| `loadDatabase(todayKey:)` | Uses cache, fetches the primary record, migrates from legacy JSON when absent, and decodes payload data. |
| `saveDatabase(_:)` | Encodes the database into the single primary Core Data record and updates cache metadata. |
| `fetchRecordUpdatedAt()` | Reads the latest primary record timestamp. |
| `fetchRecordResult()` | Fetches the primary `FernletDatabaseRecord` by record ID, distinguishing a found record, no record, and a failed fetch. |
| `persistenceController` | The Core Data stack the repository persists through — for the app-side HealthKit legacy scrub, which must run on the same store (a test store is in memory). |
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
| `init(date:repository:savedRecipeRepository:customItemRepository:coinLedgerRepository:milestoneLedgerRepository:healthKitService:journalNarrativeRepository:foodCatalog:sensitiveVisibilityDefaults:aiAuditLogStore:appGroupDirectory:sharedRecipeImportQueueFileURL:photoDocumentsDirectory:proximitySupportDirectory:heartDropKeychainService:aiQuotaDefaults:)` | Every dependency is defaulted; loads the active repository snapshot, saved recipes, custom items, coin/milestone ledgers, trust vault, retry queue, journal repository, inspector, save hooks, derived signals, and remote reload subscription. **Seven of these are per-instance ISOLATION seams**, each nil/`.standard` meaning the production identity: `appGroupDirectory` (guided + cooking run state, widget queue, widget snapshot), `sharedRecipeImportQueueFileURL` (the share-extension recipe inbox — the app-group container's other tenant, a file rather than a directory), `photoDocumentsDirectory` (own-photo corpora), `proximitySupportDirectory` (the whole proximity sidecar root), `heartDropKeychainService` (the sealed sidecars' key), `aiQuotaDefaults` (the AI-call counter's defaults suite), `sensitiveVisibilityDefaults` (the period/intimacy visibility resolution **and** the age verdict, which share one suite by design — and, since 2026-09-23, the first-workout Health-offer fact). Tests pass their own so a wipe in one store cannot reach another's — seven grep-walls in `Tests/FernletTests/PhotoDirectoryIsolationTests` enforce it. An eighth parameter, `deviceHealthResidueStore` (2026-09-23, this device's HealthKit residue cache), inverts the convention on purpose: nil is a fresh IN-MEMORY cache per store, not production, so it needs no grep-wall; `FernletStore.load` (the launch path) passes `FileDeviceHealthResidueStore.production`, and the test helpers forward it for simulated relaunches (the forwarding wall's `isolationSeams` lists it). |
| `private init(snapshot:todayKey:repository:savedRecipeService:customItemService:coinLedgerService:milestoneLedgerService:healthKitService:foodCatalog:)` | Builds a store from an already loaded snapshot for async startup. |
| `hubContentKeyProvider` / `sealedBackupContentKey` | The sealed backups' key source: `ContentView` wires the provider to `lockService.contentKey(for: .privateHub)`, so every payload reads the Private tab's key in both passcode modes and on every section (it used to be the journal section's key, nil on the Cycle section — review R2-F1, invariant I28). Nil while the tab is closed. |
| `sealedBackupRestoreHold` / `sealedBackupRestoreAwaitsOwner` / `sealedBackupKeepsPreResetCopy(of:)` / `recordSealedBackupCloudCopyDeleted(_:)` / `sealedBackupPayloadsKeptForOwner` | The persisted `fernlet.sealedBackup.restoreAwaitsOwner` bit and its per-payload record `fernlet.sealedBackup.preResetCopies` (`SealedBackupRestoreHold`); while set, every AMBIENT restore (launch pass, Private settle, un-hide) skips — the user's own restore still runs — and every re-upload (`retryDeferredReuploadIfNeeded`, the escrow adopt's re-seal) of a payload whose backup was on at the reset is held with its deferral flag left set, so the pre-reset cloud copy is not replaced by the post-reset store. A disable reconcile that deletes a payload's chunk set (the user's switch, delete-all's leg) drops it from the record, so its new entries upload again (review N-1). Kept by delete-all. `releaseSealedBackupRestoreHold()` / `releaseSealedBackupRestoreHoldForOwner()` — Privacy & Data's owner-checked "Restore" — drop only the ambient bit; `recordSealedBackupPreResetCopySettled(_:)` drops a payload from the record once its restore has landed (`.restored` / `.nothingToRestore`), so a kept copy is pulled back before any re-upload replaces it. |
| `handleAppLockResetCompleted(clearBookkeeping:)` | The app-lock reset funnel (§9.21), fired by `FernletLockService.onResetCompleted`: moves the Sealed backup work epoch FIRST (a suspended v2 pass fails its next gate; a commit already past its first save finishes uploading pre-reset ciphertext with no bookkeeping), holds ambient restores for the owner, clears the three divergence latches and every v2 payload's bookkeeping (`SealedBackupBookkeeping.clearForKeyLoss`: marker REOPENED, accepted and observed heads forgotten; the in-flight generation kept), drops every pending explicit backup choice (`sealedBackupKeyLossForgotPendingChoices()`, also told by the "can't open" check's `clearBackupBookkeeping`) and the v2 statuses, and sets both legacy cycle-import halves done. |
| `sealedBackupBookkeeping` / `seedSealedBackupBookkeepingOnce()` | The Sealed backup v2 bookkeeping (`SealedBackupBookkeeping`, isolated per test store): restore markers, install-bound accepted heads, observed foreign heads, in-flight generations (design 2026-09-30 §4.3; the in-flight generation from the B1 fix round, E2's bound on "own"). The launch wiring seeds every v2 marker ONCE from `sealedBackupMarkerSeed(_:)` — its legacy latch, or UNRESOLVED while the owner hold still keeps that payload's pre-reset copy (B3 fix round 1: an upgrade with a released hold and a refused v1 restore would otherwise seed resolved and strand the copy and every export) — and, while that backup is on, owes one export (R1-BR-11). Unit B2: `attachIntimacyLogStore(_:)` hands the coordinator the app's ONE intimacy funnel (ContentView's, BEFORE the seed), and `sealedBackupLegacyLatch(_:)` seeds the intimate-log marker from that funnel's `hasEverStoredLog` — never seeded while no funnel is attached, so a missing funnel cannot seed "never stored" and let a stale copy merge back. Unit B3: the journal marker seeds from the coordinator's sealed journal repository's `hasEverStoredNarrative` (with its row-count backfill — `FernletStore`'s own repository when it is the concrete one). |
| `markSealedBackupDirty(_:)` / `sealedBackupMutationEpoch(_:)` / `isSealedBackupReuploadOwed(_:)` | Every sealed-store mutation hook (§4.4): moves the payload's in-memory mutation epoch — the ONE "did it move" witness (R2-F8) — and sets the persisted re-upload flag, with no preferences read (R2-F14), never during "Delete everything" (R2-F10), never touching a switch. |
| `sealedBackupPreferencesProvider` / `sealedBackupPreferences` | Where the Sealed backup gates read sync and the backup switches: `ContentView` wires the app's in-memory `StoragePreferencesStore.preferences` (§4.2 G4). |
| `sealedBackupEngine` / `sealedBackupWorkEpoch` / `requestSealedBackupHubSettle()` / `sealedBackupHubSessionEnded()` / `stopSealedBackupsBeforeCloudDelete()` | The v2 engine the store owns through its coordinator; the work epoch `stopWritersForWipe` and the reset funnel move; the once-per-hub-session settle `ContentView` asks for on any Private section and the session end that resets spacing; and the wait Privacy & Data's "Stop syncing and delete iCloud data" runs after sync went off and before its cloud delete (the open finding on 8f808232). Delete-all awaits `engine.quiesceForWipe()` before its cloud leg. |
| `sealedBackupV2Status` / `periodBackupExportState` / `sealedBackupAttentionOutcome(_:)` / `periodBackupSlotIsAnotherIPhones` / `recordSealedBackupV2StatusesCleared()` | The engine's observable per-payload status, and what Privacy & Data derives from it for the period backup: another iPhone's set (else, after a relaunch, the persisted observation), a restore waiting for its key from iCloud Keychain (named as waiting, never as another key's set), a set sealed with another key or damaged, or a restore whose set will not authenticate (each offers Start new, behind its own confirmation), a set the restore refused as older (Restore it here / Replace), entries that cannot open — through `PeriodBackupExportState.derive` — nothing in duress, while hidden or while an explicit choice waits; the existing restore-status sentence for a missing key, a damaged set or one a newer build wrote; and whether turning the switch off would keep another iPhone's slot. Unit B2: `intimacyBackupRowState` (`SealedBackupV2RowState.derive` over the engine status, the pending intent, the refused set and the persisted hold / marker / observation / owed upload — `.none` while intimacy is hidden, under 16 or in duress) and `intimacyBackupSlotIsAnotherIPhones` (the turn-off confirmation that keeps another iPhone's slot); `sealedBackupAttentionOutcome(.intimacyLogs)` is nil (its rows speak). |
| `settleSealedPeriodBackup()` / `restorePeriodBackup()` / `restorePeriodBackupHere(_:)` / `replacePeriodBackupWithThisIPhone(_:)` / `startNewPeriodBackup()` | Thin wrappers over `SealedBackupCoordinator`'s engine façades: a hub-settle pass (restore while unresolved, then export), the restore phase alone, and Privacy & Data's explicit choices — in-memory intents carried out now when the Private tab is open, else at the next hub settle. The un-hide asks the engine for an ambient pass (a no-op while the Private tab is closed). Unit B2: `restoreIntimacyBackup()` (the intimate-log merge restore on its own) and `carryOutIntimacyBackupChoice(_:)` (Privacy & Data's confirmed "Restore it here" / "Restore anyway" / "Replace" / "Start a new backup" / "Remove them", recorded as engine intents through the coordinator's generic v2 façades). The intimacy un-hide is `engine.request([.intimacyLogs], .unhide)` — no task of its own. |
| `privateSectionBackupSettleTask` | The Private tab's settle request — `ContentView`'s 300 ms wait after the hub opens, before it asks the Sealed backup v2 engine for the hub session's pass (since unit B3 every payload is on the engine, so no v1 section settle is left) — held so `stopWritersForWipe` and the tab closing cancel it before it asks (review U5-backup-v2-C-U5-3 / L-U5-R4). Every pass runs on the engine's own held worker, which the wipe quiesces. |
| `releaseSealedBackupRestoreHoldKeepingNothing(preferences:)` | Privacy & Data's owner-hold helper (review U5-backup-v2-C-U5-5): releases a reset hold that keeps no enabled backup's copy, called once the screen's device-owner check passed. (`sealedBackupPayloadsBlockedForOwner` / `replacePreResetSealedBackupWithThisIPhone(_:)` are gone since unit B3: the journal restore is a merge, so no released pre-reset copy is ever "blocked".) |
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
| `setWeightManagementDeficitPercent(_:)` | Stores the Weight Management deficit the user chose on the Nutrition targets card (normalized to 0–20% in 5% steps; the 10% default is stored as `nil`) and schedules persistence (2026-09-24). |
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
| `addWorkout(_:date:)` | Appends a workout, invalidates summaries, persists, and saves to HealthKit when appropriate. For a Fernlet-logged workout it first makes the one first-workout Health ask (`offerWorkoutHealthAccessOnFirstUse()`) and its save awaits that ask, so the workout reaches Health only if the user allowed it — the log itself never waits. |
| `installWorkoutHealthAccessOffer(service:preferencesStore:)` / `offerWorkoutHealthAccessOnFirstUse()` / `recordWorkoutHealthOfferResolvedBySettings()` | The first-workout Health offer (`WorkoutHealthAccessOffer`, 2026-09-23): wired by `ContentView` at launch (not under a test harness); claimed synchronously at the first workout logged (`addWorkout`) or started (`startGuidedRun`), returning the one task every save awaits; and the explicit-off fact Settings records when the user turns Health or workout sharing off. The fact lives in `sensitiveVisibilityDefaults` and `resetAll` clears it (`clearWorkoutHealthOfferResolution`). |
| `refreshWorkoutsFromHealth()` / `backfillWorkoutsFromHealthIfNeeded(defaults:)` | Delegate HealthKit import/backfill to `WorkoutHealthKitSync`. |
| `addJournal(text:tag:)` | Seals a journal entry, appends it today, updates previous journals, and may create an emotion-only memory note (the entry's feeling token, never its words), which an accepted on-device summary may later upgrade (`rememberJournalEntry` → `requestJournalMemorySummary` → `applyJournalMemorySummary`). |
| `setSleep(hours:quality:note:)`, `setHealthSleepHours(_:)`, `updateHealthContext(_:)`, `addBottle()`, `removeBottle()` | Mutate daily sleep, HealthKit context, and hydration with persistence scheduling. `updateHealthContext(_:)` also records today's HealthKit residue in the device-local cache (the synced save strips it); `HealthSyncCoordinator` marks the sleep hours it writes in `HealthDailyContext.healthKitSleepLogHours` so the strip can recognize them after the 18:00 window switch. |
| `captureTodayHealthKitResidue()` / `scrubLegacySyncedHealthKitValuesIfNeeded(captureEnabled:)` (`FernletStore+HealthKitResidue.swift`) | Records today's HealthKit residue in `deviceHealthResidueStore` (called from `updateHealthContext` and the workout-sync `upsertWorkout`/`removeWorkoutByHealthKitUUID` for today); and the once-per-device launch scrub (`LaunchPreparationService.prepare`) that rewrites rows an older build left HealthKit values in, keeping them in the cache only while HealthKit is enabled. |
| `recordHealthImportedBodyProfile(_:)` / `applyEditedBodyProfile(_:)` / `reloadHealthImportedBodyProfile()` / `effectiveUserProfile` / `effectiveSettings` (`FernletStore+HealthBodyProfile.swift`) | The HealthKit body-profile import kept device-local (2026-09-23): the three import sites (launch auto-import, the observed-change refresh, Settings › Health's card) record through the first; the profile screen edits through the second, which writes only the fields the user changed into the synced settings and uncovers them from Health's older reading; the master-off hook calls the third after the opt-out emptied the cache. Everything computed from the body reads the effective pair — `DiaryStore.nutritionTargets` and `isPeriodTrackingVisible` included. |
| `toggleHygiene(_:)`, `togglePersonalCareTask(_:)`, `setPersonalCareTask(_:completed:)` | Route hygiene/personal-care completion through normalized task IDs. |
| `addPersonalCareTask(label:group:)` / `removePersonalCareTask(_:)` | Mutate custom personal-care tasks and clean current-day completion state. |
| `mutatePastDay(_:_:)` | Loads, mutates, and saves a non-today day directly through the repository. |
| `loadDays()` / `loadDay(for:)` | Return all days or one day while overlaying today's in-memory state — and, through `DiaryStore`, this device's HealthKit residue (including days that exist here only because of what HealthKit reported). |
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
| `rebuildDerivedSignals()` | Rebuilds derived signals from all days and today's unwell flag; `setSick(_:on:)` calls it at once for today. |
| `deferredPostLaunchTasks()` | Schedules a one-time deferred derived signal rebuild. |
| `flushPendingSnapshotSave()` | Forces any pending debounced snapshot save to run now. |
| `reloadFromRepository()` | Debounced remote reload handler that async-loads Core Data when available and applies a snapshot. |
| `apply(_:)` | Replaces in-memory store state from a snapshot and reapplies extracted service/vault state. |
| `currentSnapshot()` | Builds the persistable snapshot, stripping sealed journal text before cloud-eligible storage. |
| `FernletSnapshot.forStorage(...)` | The strip itself, in the nonisolated `FernletPersistence` module: returns the `SanitizedSnapshot` with sealed journal text/emotions and every HealthKit-derived value removed (the whole `healthContext`, HealthKit's sleep hours, Apple Health workout imports, the stored scores' HealthKit contexts — HealthKit information is not stored in iCloud, 2026-09-23). Sealing state is passed in as the sealed-ID set. |
| `batchSnapshotPersistence(_:)` | Runs synchronous mutations and schedules one debounced snapshot save. |
| `markLaunchScreenDismissed()` | Placeholder hook for launch UI lifecycle. |
| `ensureBundledFoodItemsSeeded()` | Starts one async bundled food load and stores returned catalog items. |
| `activateSealedJournals(contentKey:)` | Sets the Private tab's content key (opened by passcode OR by the no-passcode tap), folds every device-key entry under it, hydrates text, and seals legacy plaintext. (`activateNoLockJournals()` — the device-key READ mode — was deleted 2026-09-30: with no passcode the tab is closed until the tap.) |
| `deactivateSealedJournals()` | Scrubs sealed journal text/emotions from memory and clears the content key. |
| `deviceJournalKey` | Loads or creates the device-bound fallback journal sealing key through the shared `KeychainItem.loadOrCreateSymmetricKey(for:service:)` (FernletFoundation), which replaced the per-caller copies of that mint-on-first-use idiom. |
| `seal(_:dayKey:)` | Writes journal text/emotions to `JournalNarrativeRepository` and marks the entry sealed. Like `updateSealedNarrative`, `deleteSealed` (success or not), the migration and the past-day scrub (when they inserted), it then calls `JournalSealingContext.sealedJournalStoreDidChange()` → `FernletStore.markSealedBackupDirty(.journalNarratives)` (design 2026-09-30 §4.4, unit B3); the device-key fold does not. |
| `migrateDeviceKeyEntriesToUserKey(userKey:)` | Folds EVERY device-key narrative under the content key through `JournalNarrativeRepository.reencryptAll(from:to:)` (bounded pages); the old window-only fold (today + `previousJournals`) left older Home entries out of the hub. Stays pending on any leftover. |
| `refreshSealedJournals(contentKey:)` | Hydrates empty journal entries from sealed narrative storage. |
| `migrateExistingJournalsToSealedStore(contentKey:)` | One-time migration that seals plaintext journal entries and schedules a stripped snapshot save. |
| `mutateDay(date:_:)` | Mutates today in memory or routes past dates through `mutatePastDay`. |
| `workoutExists(id:)` / `workoutExists(healthKitUUID:)` | Support HealthKit duplicate checks across all days. |
| `setWorkoutHealthKitUUID(workoutID:hkUUID:date:)` | Finds a workout across today/past days and stores its HealthKit UUID. |
| `upsertWorkout(_:date:)` | Workout sync insertion hook; currently delegates to `addWorkout(_:date:)`. |
| `static load(date:repository:statusUpdate:)` | Async startup loader that creates repositories/services, loads snapshot and saved recipes, and returns a ready store. |

The journal-sealing rows above (`activateSealedJournals(contentKey:)` through `migrateExistingJournalsToSealedStore(contentKey:)`, plus `deviceJournalKey` and `seal(_:dayKey:)`) now live on `JournalSealingCoordinator` (`App/Fernlet/JournalSealingCoordinator.swift`), which the store owns and reaches through the `JournalSealingContext` host protocol.

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
| `localDefaults` / `makeLocalDefaults(inMemory:storeURL:)` | The store's device-local, never-synced key/value surface (`StoreLocalDefaults`, 2026-09-24): `UserDefaults.standard` for the default on-disk store, a private per-controller `InMemoryStoreLocalDefaults` for every in-memory or explicit-URL controller. Holds the two ledgers' pending reset boundaries (`CoinLedgerRepository` / `MilestoneLedgerRepository` `pendingResetBoundaries()` + `savePendingResetBoundaries(_:)`, literal keys at their call sites), scoped exactly like the store so a test store never touches production defaults. |
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
| `init(inMemory:storeURL:model:)` | Builds and loads `FernletPrivate` with complete file protection, history tracking, migration, no CloudKit, and merge configuration. The production model (V2) carries the V1 → V2 staged migration on the store description, so a rebuild or reload re-adds under it too; `model:` is the migration tests' seam (a supplied model gets no stage). |
| `makeManagedObjectModel()` | Builds the CURRENT model, V2 = the frozen V1 entities + `CycleRecord` (period-data design 2026-09-30, §5.2), tagged `FernletPrivate.v2`. |
| `makeManagedObjectModelV1()` | The four-entity model every shipped build wrote (`MenstrualNarrative`, `JournalNarrative`, `IntimacyLog`, `WorryNarrative`), FROZEN; its `versionChecksum` is pinned by `PrivateStoreModelMigrationTests` (proven equal to the pre-split model). Never edit it — a new column or entity is a new version. |
| `makeStagedMigrationManager(to:)` | One `NSCustomMigrationStage` from V1 to the given V2 over IN-MEMORY `NSManagedObjectModelReference`s (programmatic models have no `.momd`); no handlers, so a lightweight additive stage. Freezes the source model with a store-less coordinator first (reading an editable model's checksum logs a Core Data error). |
| `makeCycleRecordEntity()` | `CycleRecord`: EXACTLY `id` (indexed), `schemaVersion` (Int16, plaintext format tag) and one `payloadCiphertext` blob (not externalized). No date, day key, timestamp or HealthKit id column; no uniqueness constraint (the property-object-trump merge policy would make a conflict a silent overwrite — uniqueness is the repository's upsert). |
| `sealedEntityNames` / `sealedRowCount()` | The one list of sealed entities (five, with `CycleRecord`) that `purgeEncryptedEntities()` deletes and `sealedRowCount()` counts keylessly — so the app-lock reset purges cycle records and a passcode setup's prior-data check counts them. |
| `makeMenstrualNarrativeEntity()` | Defines encrypted menstrual narrative columns and a date-key index. |
| `makeJournalNarrativeEntity()` | Defines local-only journal metadata plus sealed text/emotion columns and a day-key index. |
| `makeIntimacyLogEntity()` | Defines local-only intimacy metadata plus sealed note columns and a day-key index. |
| `makeWorryNarrativeEntity()` | Defines local-only Worry Box metadata plus sealed text columns. |
| `CoreDataModelBuilding.makeAttribute(_:type:defaultValue:allowsExternalBinaryDataStorage:)` | The same shared attribute factory the synced model builder uses (FernletFoundation); it replaced this file's private copy, so the two builders cannot drift. |
| `purgeEncryptedEntities()` | Destructive lock-reset wipe; deliberately batches all sealed entities under a single save rather than using `PrivateRowPlumbing.deleteRows(...)`, so the wipe stays atomic across entities. |
| `PrivatePersistentHistoryPruner.prune(context:before:)` | Deletes private-store persistent history before a date. |

### `CycleRecord.swift` / `CycleRecordRepository.swift` / `CycleRecordStore.swift` (PrivateHealthStore)

The sealed cycle record (period-data design 2026-09-30, §5–§6). Landed inert in unit 3; since the cutover (unit 4) records are the cycle history's source of truth, read and written through `PeriodTrackerStore` (next section).

| Function Or Type | What It Does |
| --- | --- |
| `CycleRecord` | One cycle entry sealed as ONE blob: `id`, `dayKey`, `loggedAt`, a `clinical` and a `narrative` block (each `nil` = UNKNOWN, present-but-empty = "none"), `origin`, `createdAt`, `updatedAt`. Frozen Codable (explicit keys, `"v": 2`, enums as raw values, dates as seconds since 2001) — the sealed column's plaintext, the buffer's v2 payload and the backup chunk element alike. Tolerant per token; a newer schema throws `CycleRecordDecodingError.unsupportedSchemaVersion` (retryable, never dead). |
| `CycleRecord.init(event:id:origin:now:)` | A logged event → both blocks known, the sheet's caps applied (note ≤ 1000, ≤ 40 scales of ≤ 40-character names, non-finite temperature dropped). |
| `CycleRecord.merged(_:_:)` / `reducedByID(_:)` | The ONE merge rule (§5.1a): each block taken WHOLE by its clock (equal clocks → content tiebreak, so commutative), `loggedAt`/`dayKey` from the clinical-known side, `origin` by `combinedOrigin(_:_:)` (review round 2, N-1: the copy that speaks most for the clinical block — one built from Fernlet's Health samples (`clinicalBlockIsFromFernletHealthSamples`), else a known block over an unknown one, else the first argument's), `createdAt` min, `updatedAt` max; idempotent and associative. Batches are reduced by id before any write. |
| `CycleNarrativeFields.bounded(_:)` | The custom-scale cap every narrative block applies (a logged event, a drained v1 payload, an imported narrative) — the tracker's private copy was removed. |
| `CycleRecordRepository.upsertMerged(_:retiringNarrativeIDs:contentKey:)` | THE write path: per id — absent → insert; openable → merge (re-sealed only when changed; duplicate rows collapse); all rows dead → replace; any row undecided → the whole call throws `undecidedRows`, nothing saved. Deletes the named `MenstrualNarrative` rows in the same save. Checks `maxStoredRecords` (20 000) before any change. |
| `insert(_:contentKey:)` / `update(_:contentKey:now:)` | Insert requires absence and a storable record. Update is an EDIT — replace in place, no merge; keeps the stored `createdAt`, keeps the stored `origin` unless the edit supplies a clinical block the stored copy did not know (then the edit's, via `combinedOrigin`), restamps only the changed block. |
| `records(offset:limit:contentKey:)` / `records(ids:contentKey:)` / `allRecords(contentKey:)` | Keyed reads returning a `CycleRecordPage` (`records` / `deadIDs` / `transientCount`), in store order by id, pages ≤ 500. A decrypted id that differs from the row's id is DEAD (the AAD does not bind the id, R1-F9). `allRecords` walks inside one `performAndWait` and reduces by id. |
| `recordCount()` / `allIDs()` / `delete(ids:)` / `deleteAll()` | Keyless. `allIDs` is the export's id snapshot; `deleteAll` routes through `PrivateRowPlumbing.deleteRows`. |
| `CycleRecordStore` | `@MainActor` gated funnel (mirrors `IntimacyLogStore`): hidden ⇒ the display reads (`allRecords`, `records(ids:)` — the edit's stored-copy read) are empty and every write/upsert/pre-pass/chunk/restore throws `PeriodTrackingHiddenError`; count, ids and deletes ungated. `attachMutationHook` + `mutationCounter` fire only when a call changed something on disk. `backupPrePass(contentKey:)` → `CycleRecordBackupPrePass` (snapshot ids, dead ids, undecided count, counter; not on the v2 engine's path). `withBackupSeam(_:)` runs a period backup chunk's decrypt only while the seam is open, in the same synchronous step as the check; `isStoreHealthy` answers whether the sealed store is attached (an engine gate, R2-F2). Visible but keyless, the whole backup seam (`backupPrePass` / `backupChunk` / `restoreMerging`) throws `FernletLockError.locked`, never an empty page. The app target never constructs a raw `CycleRecordRepository` (grep-walled). |
| `IntimacyLogRepository.allIDs()` / `logs(ids:contentKey:)` → `IntimacyLogPage` / `delete(ids:)` / `isStoreHealthy` | Unit B2 (Sealed backup v2, §8): the keyless id snapshot in the total order (event date, id; at most `maxBackupRecords` + 1), the classified read by id (`records` / `deadIDs` / `needsNewerBuildIDs` — a row missing its day key or event date, never dead / `transientCount` — the install binding did not answer; an id with no row is absent), the keyless delete by id ("Remove them"), and whether the store is attached. |
| `IntimacyLogRepository.upsertMerged(_:contentKey:)` → `IntimacyLogMergeResult` | THE intimate-log restore write (§8.2): the batch reduced by id (later `updatedAt` wins); absent → inserted with its own stamps, note capped at `maxNoteLength`; present and opens → kept, only a missing Health link filled (`linked`); present and dead → replaced; undecided or needs-newer → the whole call throws `IntimacyLogRepositoryError.undecidedRows`. One save, rolled back on any throw; never deletes; idempotent; latch set only when something changed. Replaces `insertAtomically`. |
| `IntimacyLogStore.attachMutationHook(_:)` / `backupChunk(ids:contentKey:)` / `restoreMerging(_:contentKey:)` / `withBackupSeam(_:)` / `allIDs()` / `delete(ids:)` / `isStoreHealthy` | The intimacy funnel's v2 seams (unit B2): the hook runs after every write that changed something (insert, Health link, merge, delete) and marks the upload owed; chunk, merge and the backup-chunk decrypt are GATED (`IntimacyTrackingHiddenError` while hidden / under 16 / in duress, `FernletLockError.locked` without a key — never empty); snapshot, delete and health are ungated. Replaces `backupPage` / `restore`. |
| `IntimacyBackupAdapter` / `SealedBackupCoordinator.attachIntimacyLogStore(_:)` / `restoreV2Backup(_:initiatedByUser:)` / `settleV2Backup(_:)` / `restoreBackupHere(_:_:)` / `replaceBackupWithThisIPhone(_:_:)` / `startNewBackup(_:)` / `removeUnopenableEntries(_:ids:)` | The intimate-log payload on the v2 engine (unit B2): the adapter reads the attached funnel through a provider (none → store unhealthy → every pass stops at G); the coordinator wires the funnel's gate and hook on attach, and its v2 façades are payload-generic (the period names are thin wrappers). The intimacy launch arm, targeted restore, `reconcileIntimacyBackup`, the intimacy arms of `mayReuploadFromLocalStore` / `isEmptyStoreForRestore` and the per-call intimacy store are gone. |
| `JournalNarrativeRepository.allIDs()` / `ids(onDays:)` / `backupRecords(ids:hubKey:deviceKey:)` → `JournalBackupPage` / `skeletons(ids:)` / `isStoreHealthy` / `delete(ids:)` | Unit B3 (Sealed backup v2, §7.1–§7.2): the keyless id snapshot in the total order (entry date, id; at most `maxBackupRecords` + 1), the keyless ids of every entry on the given days (the days whose day row will not decode, which the snapshot keeps — B3 fix round 2; one `dayKey IN` fetch per 500 days), the classified read by id under the hub key then the device key (`JournalBackupDeviceKey`: present / absent / unreadable — read by the app WITHOUT minting) → `records` / `deadIDs` / `needsNewerBuildIDs` (opens, but an unknown feeling tag or a missing day/date — never dead) / `transientCount` (the install binding or the device-key keychain did not answer); nil hub key throws `FernletLockError.locked`, never empty; the keyless `JournalNarrativeSkeleton`s (id, day, tag, date) the restore's day skeletons are rebuilt from; whether the store is attached; the keyless delete by id ("Remove them", ≤ 500 per call). |
| `JournalNarrativeRepository.upsertMerged(_:hubKey:deviceKey:)` → `JournalNarrativeMergeResult` | THE journal restore write (§7.3): the batch reduced by id (later `updatedAt` wins, a tie keeps the first); absent → inserted with its own stamps (`apply` gains an `updatedAt`) — unless an entry on its day already IS it (`JournalMergeDayEntry.isCopy(of:)`: the same words AND creation stamp, the other iPhone's fork of this iPhone's own entry; B3 fix round 1, so "Restore it here" on both iPhones settles at two entries) — the absent entries' days read once before the first insert (`openedEntries(onDays:)`); opens (hub or device key) with the same text and emotions → nothing; opens with DIFFERENT words → the local entry kept and the backup's added as a new entry (fresh id) unless an entry on that day already has those words (the second pass reads only the conflicting days' rows, pending inserts included); every row dead → replaced; undecided or needs-newer → the whole call throws `JournalNarrativeRepositoryError.undecidedRows`. One save, rolled back on any throw; never deletes or modifies an entry that opens; idempotent; `followUpIDs` names every entry that carries a backup entry's content (so a retry rebuilds missing skeletons). Replaces `insertAtomically`. |
| `JournalBackupAdapter` / `SealedDeviceKeyRead` / `SealedBackupCoordinator.restoreJournalBackup(initiatedByUser:)` / `SealedBackupContext.sealedBackupJournalReferences` / `reinstateJournalEntries(from:) -> Bool` / `FernletStore.journalBackupRowState` / `journalBackupSlotIsAnotherIPhones` / `carryOutJournalBackupChoice(_:)` / `carryOutSealedBackupChoice(_:for:)` | The journal payload on the v2 engine (unit B3): the adapter snapshots the sealed ids some day references plus every sealed entry on a day whose stored row will not decode (`SealedBackupJournalReferences.unreadableDayKeys`, read keylessly by `JournalNarrativeRepository.ids(onDays:)` — B3 fix round 2; orphans on a readable day never exported; the references are nil while `FernletRepository.loadAllDaysWithUnreadable()` does not account for every row, and the snapshot then throws `JournalBackupDayStoreUnreadableError` — B3 fix round 1), reads chunks under the hub or device key, merges through `upsertMerged`, rebuilds day skeletons — writing only a day that lacks one, so an idempotent re-merge writes no day row (B3 fix round 1); false keeps the restore unresolved and re-classifies before "Remove them"; its seam is `!duress`. The coordinator takes the store's journal repository (`journalRepository:`, resolved lazily) and the device-key service (`journalDeviceKeyService:`). Privacy & Data's journal row is derived like the intimate-log one and is `.none` during a duress session. The v1 journal machinery (`reconcileJournalBackup`, `mayReuploadFromLocalStore`, `isEmptyStoreForRestore`, the targeted restore, the launch arm, `retryDeferredSealedBackupIfNeeded`) is gone. |

### `PeriodTrackerStore.swift` / `CycleDayEntry.swift` / `CycleLegacyImport.swift` (PrivateHealthStore) — the cutover

The cycle S3 funnel since unit 4 (period-data design 2026-09-30, §6.3–§8). The sealed record is the source of truth in both passcode modes and whatever the Health switches say; Apple Health is an optional mirror behind `PeriodHealthKitServicing`. Every write that follows an await rechecks visibility, the live hub key and `writerEpoch`.

| Function Or Type | What It Does |
| --- | --- |
| `logEvent(_:unlockedContentKey:)` → `PeriodLogOutcome` | G2, then SEAL FIRST (`recordStore.insert` with the key, else a v2 pending-buffer payload — `.pendingUntilPrivateOpens`, either passcode mode), then the mirror only when the record has a clinical field and `isCycleMirrorEnabled()`. A seal/buffer failure throws with no Health call; a mirror failure is `.failed(_)` with the entry kept; "sharing is off" is `.notShared`. |
| `editRecord(_:with:unlockedContentKey:)` | In place under the same id (reads the stored copy through `recordStore.records(ids:)`); an unknown block left empty stays unknown, and an unknown clinical block the edit fills makes the record `logged` (`editedRecord(_:with:now:)`, N-1). Re-mirror (`remirrorEdited(_:replacing:)`): a STORED block that is unknown deletes nothing from Health — its Fernlet samples are its unimported source (C-U4-R1) — and with sharing on a block the edit made known is written beside them; otherwise sharing on → `deleteMirror` then always `writeMirror` (`.written` / `.failed`), sharing off → `deleteMirror`, `.removedStaleCopy` only when it deleted ≥ 1 (Q1). A refused kind counts only through `refusalMayLeaveCopy(of:refused:sharing:)` (R2). |
| `deleteDay(_:)` / `deleteRecord(_:)` → `PeriodDeleteOutcome` | Fernlet's rows FIRST (keyless, ungated, one save; a throw deleted nothing), then each record's `deleteMirror` (every record attempted) and the day's orphan Fernlet copies (`deleteFernletAuthored`); a failed delete, or a refused kind `refusalMayLeaveCopy` counts, is `.stillInHealth(_)`, never a throw (I32). `deleteRecord(_:)` (the emptied edit) takes the record and leaves an UNKNOWN block's Fernlet samples in Health (C-U4-R1); the day's confirmed Delete removes them. |
| `refusalMayLeaveCopy(of:refused:sharing:)` | Review round 1, R2: whether Apple Health refusing to delete some `CycleMirrorSampleKind`s may have left a Fernlet copy — only a kind the record's copy could hold (`CycleMirrorSampleKind.possibleCopyKinds(of:)`), and then always for a block built from Fernlet's Health samples (`CycleRecord.clinicalBlockIsFromFernletHealthSamples`: a known block with origin `importedLegacy` / `adoptedFromHealth`, which the origin rule of `combinedOrigin` keeps true to the block — N-1), otherwise only while cycle sharing is on (HealthKit reports never-granted and revoked access alike). |
| `CycleMirrorDeletion` / `CycleMirrorSampleKind` (`CycleMirrorDeletion.swift`) | What `PeriodHealthKitServicing.deleteMirror(recordID:)` returns: HealthKit's deleted count and the kinds whose share access was denied (reported, not thrown); the in-memory, unfrozen five-kind vocabulary with `kinds(writtenFor:)` (pinned against `HealthKitService.periodSamples(for:)`). |
| `loadEntries(unlockedContentKey:)` | G1 (hidden or keyless scrubs); Health read only while `isCycleHealthReadEnabled()`; post-await recheck; records filtered to the 240-day window; fill-on-read (`fillOnRead`, completes an UNKNOWN clinical block from the record's own Fernlet samples via `upsertMerged`, under the epoch check; the completion is `importedLegacy`, so a restored note-only record it completes counts its Health copy, N-1); dedupe hides a Fernlet sample group only when its record's clinical block is known (I12); entries, phase (`.menstrual` iff actual bleeding) and prediction. |
| `drainPendingBuffer(contentKey:)` | G2 no-op while hidden; v2 payloads decode to records, v1 narratives to narrative-only records under `CycleLegacyIdentity.recordID(forLegacyExternalID:)`; ONE `upsertMerged`, then the purge — a partial drain re-drains without duplicates. |
| `keepHealthOnlyDay(_:contentKey:)` / `deleteHealthOnlyCopies(_:)` | "Keep in Fernlet" (gated: one `adoptedFromHealth` record per copy group under the copy's own id) and "Delete from Apple Health" (ungated) for a day holding only Fernlet's Health copies (§7.3). |
| `runLegacyImportIfNeeded(contentKey:)` / `performLegacyImport` | §8: held in `legacyImportTask`; awaits (determined authorization, the THROWING legacy read) first, then the recheck, then the synchronous narrative classification (`MenstrualNarrativeRepository.classifiedNarratives`) and build, then ONE `upsertMerged` retiring the converted narratives. Narrative half done when only dead rows remain (named in `unopenableLegacyNarrativeIDs`); sample half done after a clean read. Deterministic clocks, so re-running changes nothing (I13). |
| `removeUnopenableLegacyNarratives()` | The Cycle page card's Remove: keyless delete of exactly the named legacy notes (`MenstrualNarrativeRepository.delete(ids:)`). |
| `cancelBackgroundWriters()` | Cancels the held import and moves `writerEpoch` — wired by `ContentView` to `FernletStore.periodWritersStopHook`, run in delete-all's first leg (§8.4). |
| `CycleLegacyImportLedger` | The two frozen markers (`fernlet.cycleRecord.legacyImport.narratives` / `.samples`, value `done`); `markBothHalvesDone()` from delete-all and the app-lock reset funnel. |
| `CycleDayEntry` | A day's `records` (newest first), `fernletHealthSamples` (Fernlet's copies with no authoritative record) and `otherHealthSamples`; accessors take the first record that sets a field, then Health. `isHealthOnlyFernletDay`, `hasNarrative` (the bridge's symptom-load key, I31). |
| `CycleHealthSamples` | The one Health-samples → clinical block / record rule (`clinicalFields(from:)`, `clinicalRecord(id:samples:origin:)` with the samples' own clocks), the record-id resolution of a Fernlet sample (`recordID(of:)`: the marker, else the external UUID, else a start-time-derived id) and grouping. |

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
| `rebuild(allDays:todayKey:isSickToday:)` | Rebuilds observed derived signals through `DerivedSignalsRebuilder`. `isSickToday` is required: it forces readiness to `needs rest` (spec §6a). |
| `scheduleDeferredRebuild(allDaysProvider:isSickTodayProvider:todayKey:)` | Schedules a one-time utility-priority rebuild after launch; both providers are read at fire time. |
| `flushDeferredRebuild()` | Runs the pending deferred rebuild immediately if one exists. |

### `DerivedSignalsRebuilder.swift`

| Function | What It Does |
| --- | --- |
| `rebuild(allDays:todayKey:windowDays:isSickToday:)` | Sorts all days, takes the recent window, and delegates signal creation to `DerivedSignalFactory`, forwarding today's unwell flag. |

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
| `loadSync()` / `loadAsync()` / `reloadFromStore()` | Hydrate the append-only coin ledger from its per-row store (the design that replaced the unsound "derive earned from day history" model — day history shrinks). Since 2026-09-24 every load first retries the append of any reset boundary still pending in the device-local sidecar, then MERGES whatever is still pending into the ledger, so pre-boundary rows stay void across a process death (tracker §3.6). |
| `reconcile(activeDayKeys:)` | Mints any missing earn rows for active days, capped so future-day minting cannot run away. |
| `grantEarns(_:)` / `spend(amount:ref:)` | Append earns; `spend` returns `false` rather than going negative. |
| `reset()` / `flushPendingSave()` | Wipe path and the debounce flush. `reset()` remembers its marker in the device-local sidecar BEFORE `deleteAll()`, then lands it (retiring the sidecar) or leaves it pending for the next load plus the in-process retry. |

### `MilestoneLedgerService.swift`

| Function | What It Does |
| --- | --- |
| `loadSync()` / `loadAsync()` / `reloadFromStore()` | Hydrate the append-only milestone ledger — with the same pending-boundary retry and merge as the coin ledger (2026-09-24). |
| `record(_:)` | Appends milestone rows, idempotently by deterministic id. |
| `reset(deletingRowsWith:)` | Wipe path (added 2026-08-20, reversing the earlier survive-a-reset rule): drops the pending queue, runs the injected row delete (`MilestoneLedgerRepository.deleteAll()`, narrowed by the deletion funnel), then — since 2026-08-21 — appends a `resetBoundary` marker (with the coin service's failed-append retry), so re-synced pre-wipe rows are voided by aggregation; in-memory state afterwards is `[marker]`. Since 2026-09-24 the marker is remembered in the device-local sidecar before the row delete runs, so a failed append survives a process death. `CloudKitDataService.allRecordTypes` sweeps the milestone record types too. |
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
| `PendingResetBoundaries<Entry>` (internal) | The durable half of both ledgers' reset boundary (2026-09-24, tracker §3.6). `remember(_:)` writes the marker to the repository's device-local sidecar before the rows are deleted; `landPending(including:)` appends every pending marker (deduped by id — the engine's intra-batch duplicate limitation) and retires the sidecar once they land, returning what is still pending for the caller to merge. Bounded by `PendingWriteLimits.maxPendingResetBoundaries` (8). |

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
| `PendingNarrativePayload` | Encodes HealthKit external ID, date key, and encrypted narrative field bytes for deferred sealing (v1), or — through `init(cycleRecordID:dayKey:cycleRecordJSON:)` — a whole cycle record's frozen JSON in the optional `cycleRecordJSON` (v2). The new field is optional, so v1 files decode and a v1 payload encodes byte-for-byte as before. |
| `append(_:)` | Loads encrypted buffer entries and appends one — or, at `capacity` (200), THROWS `PendingNarrativeBufferError.full` with nothing written and nothing dropped (it used to evict the oldest past a 50-entry cap with only an audit line). Period-data design 2026-09-30 §6.5, I21. |
| `drainAll()` | Loads all buffered payloads, purges the file, and returns entries for unlocked processing. |
| `purge()` | Deletes the pending buffer file. |
| `holdsUnopenableEntries()` | READ-ONLY: whether the file is non-empty while its key is definitively absent (no mint, migration or decrypt; an unreadable key throws). Feeds the "entries this iPhone can't open" card through `FernletLockService.pendingNarrativesAreUnopenable()`. Period-data design 2026-09-30 §4.9. |
| `loadEntries()` | Opens the ChaChaPoly buffer file with the buffer key and decodes payloads. Requires the `FNB2` marker since crypto-standardization Phase 3: a non-empty file without it is refused by name as `PendingNarrativeBufferError.legacyUnprefixedFormat` (audit-logged, never opened under no domain, and never deleted), and the Phase 2.4 migrator that converted such files went with the reader it converted through. |
| `saveEntries(_:)` | Encodes, encrypts, atomically writes, excludes from backup, and marks complete file protection. |
| `bufferKey()` | Reads the background-accessible buffer key with `KeychainItem.loadDistinguishingAbsence`: found → the key; unreadable → `PendingNarrativeBufferError.keyUnreadable(status:)` (never a mint); absent → the legacy migration, else a fresh key ONLY over an absent or empty file (a non-empty file with no key throws `.bufferUnopenable`). Period-data design 2026-09-30 §6.5. |
| `bufferFileIsAbsentOrEmpty()` | Whether the buffer file holds nothing; an unreadable size answers false (fail closed). |
| `migrateLegacyServicelessKeyIfPresent()` | Production scope only, on a v2 slot that read absent: moves the legacy v1 row into the scoped v2 slot via `KeychainItem.store(...)`. |
| `loadLegacyServicelessKey()` | Raw `SecItemCopyMatching` read of the service-less v1 key — the one keychain call `KeychainItem` cannot express; dies with the v1 migration. |
| `createAndStoreBufferKey()` | Creates a 256-bit buffer key and stores it after-first-unlock-this-device-only through `KeychainItem.store(...)`. |
