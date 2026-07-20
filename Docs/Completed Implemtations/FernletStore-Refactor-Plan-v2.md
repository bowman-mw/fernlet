> **CLOSED 2026-07-19 — SHIPPED.** PR 0 (zero `ObservableObject` remain) and Phase 2 (`SavedRecipeService`, `AIRetryQueueService`, `DerivedSignalsService`, `ProximityTrustVault`) are on `main`; the successor workstreams it names (snapshot schema, mesh) also shipped. Live tracker: [RemainingWork-2026-07-19.md](../RemainingWork-2026-07-19.md).

# FernletStore Refactor Plan (v2)

**Status:** PR 0 complete in production code; Phase 1 ready · **Target file:** `Fernlet/Fernlet/FernletStore.swift` · **Supersedes:** v1

---

## 1. Decisions Locked In

These have been confirmed and are not up for re-review:

| Decision | Choice |
|---|---|
| Refactor strategy | **Option C — Hybrid.** Pure logic → stateless services. State slices with clean external surfaces → `@Observable` sub-services forwarded through `FernletStore`. |
| Observation framework | **Migrate everything from `ObservableObject` to `@Observable` first** (PR 0). No `ObservableObject` types left in the codebase after PR 0. Deployment target is iOS 26, so `@Observable` (iOS 17+) is available unconditionally. |
| Migration scope | **All 13 `ObservableObject` classes** including the proximity stack. The mesh refactor will start from an already-migrated baseline. |
| Sub-service exposure to views | **Forwarding through `FernletStore`.** Views continue to read `store.savedRecipes`, `store.retryQueue`, etc. Under `@Observable`, the Observation framework tracks nested reads automatically — no manual `objectWillChange` plumbing needed. |
| Naming convention | **Service suffix for stateful `@Observable` slices** that views see (through forwarding). Pure value-type helpers keep functional names. One named exception: `ProximityTrustVault`. |
| Phase 2 scope | `SavedRecipeService` + `ProximityTrustVault` + `AIRetryQueueService` + `DerivedSignalsService`. The retry queue is in scope because the AI surface will grow; pulling it now sets the foundation. |
| Next workstream after this | `FernletSnapshot` schema refactor (separate plan), then mesh implementation. |

---

## 2. Executive Summary

`FernletStore` will be reshaped in three stages:

**PR 0 — `@Observable` migration.** Complete in production code as of 2026-05-26. Every former `ObservableObject` class has migrated to `@Observable`, former `@Published` state is plain tracked state, and view attributes now use `@State`, `@Bindable`, plain stored properties, or `@Environment` as appropriate. `FernletStore` keeps its required Combine remote-change `.sink` infrastructure.

**Phase 1 — Extract pure logic into services.** Next workstream. Seven helper extractions, each a self-contained PR, no call-site change in any view. Removes ~600 lines from `FernletStore`.

**Phase 2 — Extract four `@Observable` sub-services.** `SavedRecipeService`, `ProximityTrustVault`, `AIRetryQueueService`, `DerivedSignalsService`. Each owns its slice of state. `FernletStore` retains forwarding properties so views are unchanged. Removes another ~280 lines.

After all three, `FernletStore` is ~700 lines and is composed of focused, testable parts. Each AI/intelligence-adjacent piece (the retry queue, derived signals) has its own home to grow into.

---

## 3. Current Responsibility Audit

A literal inventory of what `FernletStore` owns today, grouped by concern. Line numbers approximate.

| # | Concern | State | Methods | LOC | Phase |
|---|---|---|---|---|---|
| 1 | Day & past-day mutation | `day` | `loadDays`, `loadDay`, `mutatePastDay`, `addBottle`, `removeBottle`, `setBottleCount`, `setSleep` x2, `setHygiene`, `setPersonalCareTaskIDs`, `toggleHygiene`, `togglePersonalCareTask`, `setPersonalCareTask`, `addPersonalCareTask`, `removePersonalCareTask`, `personalCareTasks`, `personalCareProgress`, `isPersonalCareTaskCompleted` | ~150 | Stays on store; uses `DayMutator` helper |
| 2 | Meal logging | `recentMeals` | `addMeal` x2, `addResolvedMeal`, `addResolvedMeals`, `appendMeal`, `copyMeal`, `deleteMeal` | ~70 | Stays; uses `MealBuilder` |
| 3 | Meal building (logic) | — | `meals(from:)`, `makeMealFromRecipe`, `meal(from recipe:)`, `meal(from itemName:)`, `mealLogSource`, `createRecipeIfNeeded`, `totals(for:)`, `bestRecipeMatch`, `isRelevant` | ~160 | **Phase 1** → `MealBuilder` |
| 4 | Recipe (RecipeDefinition) CRUD | `recipes` | `addRecipe`, `updateRecipe`, `deleteRecipe`, `logRecipe`, `macroTotals(for:)`, `micronutrientTotals(for:)`, `recipeShareText`, `importRecipe` | ~110 | Stays |
| 5 | Recipe share codec | — | `sharedRecipePayload(for:)`, `sharedRecipeJSON(for:)`, `sharedRecipePayload(from text:)` | ~55 | **Phase 1** → `RecipeShareCodec` |
| 6 | Custom ingredient upsert | — | `makeRecipeIngredients`, `upsertCustomFoodItem`, `saveCustomIngredient` | ~50 | **Phase 1** → `CustomIngredientUpsert` |
| 7 | Saved recipes | `savedRecipes`, `savedRecipeRepository`, `savedRecipeSaveScheduled` | `addSavedRecipe`, `updateSavedRecipe`, `deleteSavedRecipe`, `logSavedRecipe`, `savedRecipeShareText`, `scheduleSavedRecipeSave` | ~85 | **Phase 2** → `SavedRecipeService` |
| 8 | Food items | `foodItems` | (shared) | — | Stays |
| 9 | Bundled food seeding | `bundledFoodSeedingState` | `ensureBundledFoodItemsSeeded`, `queueBundledFoodSeedSaveAfterLaunch`, `flushPendingBundledFoodSeedSaveIfNeeded`, `markLaunchScreenDismissed` | ~55 | **Phase 1** → `BundledFoodSeedingService` |
| 10 | Workouts | — | `addWorkout` x2 | ~25 | Stays |
| 11 | Workout ↔ HealthKit | — | `saveWorkoutToHealthIfAuthorized`, `updateWorkoutHealthKitUUID`, `refreshWorkoutsFromHealth`, `backfillWorkoutsFromHealthIfNeeded`, `isWorkoutLoggingAuthorized`, `reconcileWorkouts`, `workoutExists` x2, `updateWorkoutHealthKitUUIDIfNeeded`, `makeWorkout(from:)`, `parseFernletMetadata` | ~165 | **Phase 1** → `WorkoutHealthKitSync` |
| 12 | Journal | `previousJournals` | `addJournal` x2, `updateJournal`, `deleteJournal` | ~50 | Stays |
| 13 | Memories | `memories` | `deleteMemory`, `updateMemory`, `tierTwoMemories`, `tierTwoContextSummary` | ~35 | Stays |
| 14 | Workshop | `workshop` | `addTexture` | ~10 | Stays |
| 15 | Settings | `settings` | `setHidePredictions`, `setHideFertileWindow`, `setProximityDisplayName`, `setHomeWidgets`, `setQuickLogItems`, `setConnectionInspectorMode`, `completeOnboarding` | ~40 | Stays |
| 16 | Goals | `goals` | `replaceGoals` | ~5 | Stays |
| 17 | Daily health score | `dailyScores` | `score`, `score(for:)`, `dailyHealthScore(for:day:)`, `storeDaySummary`, `invalidateDaySummary` | ~50 | Stays |
| 18 | Derived signals | `derivedSignals` | `rebuildDerivedSignals`, `deferredPostLaunchTasks` | ~20 | **Phase 2** → `DerivedSignalsService` + `DerivedSignalsRebuilder` |
| 19 | AI retry queue | `retryQueue` | `pendingRetryCount`, `queueMealRetry`, `clearRetryItem` | ~15 | **Phase 2** → `AIRetryQueueService` |
| 20 | Companion / photowall | `companionThought`, `photowallSeeds` | `storeCompanionThought` | ~10 | Stays |
| 21 | Proximity trust & audit | `trustedProximityPeers`, `trainerAuditEvents` | `trustProximityPeer`, `revokeTrustedProximityPeer`, `trustedProximityPeer` x2, `isRevokedProximitySigningKey`, `isTrustedProximityPeer`, `recordTrainerAudit`, `recordTrainerAuditWithoutSaving` | ~75 | **Phase 2** → `ProximityTrustVault` |
| 22 | Connection inspector hosting | `showConnectionInspector`, `connectionInspector`, `connectionSessionLogs` | `presentConnectionInspectorIfNeeded`, `replaceConnectionSessionLogs` | ~15 | Stays (already separate object) |
| 23 | Health capabilities & intimacy | — | `isIntimateLoggingAllowed`, `allowedHealthCapabilities`, `visibleHealthCapabilities`, `updateHealthContext`, `setHealthSleepHours` | ~35 | Stays |
| 24 | Lock state mirror | `lockState` | — | ~3 | Stays |
| 25 | Snapshot persistence | — | `scheduleSnapshotSave`, `flushPendingSnapshotSave`, `performSnapshotSave`, `batchSnapshotPersistence`, `subscribeToRemoteChangesIfNeeded`, `scheduleRemoteRepositoryReload`, `reloadFromRepository`, `apply(_:)` | ~110 | **Phase 1** → `SnapshotSaveCoordinator` |
| 26 | Reset & lifecycle | — | `resetAll`, init x2, `load(date:repository:)` | ~85 | Stays |
| 27 | Misc computed | `storageLocation`, `macroTotals`, `micronutrientTotals`, `nutritionTargets`, `companionState`, `score` | — | ~30 | Stays |

### Cross-cutting facts (unchanged from v1)

- One `FernletSnapshot` blob contains all persisted slices. Phase 2 does not split this — slices read out of and write into the same snapshot through `FernletStore`.
- `day: FernletDay` is shared across many slices (meals, workouts, journals, sleep, water, hygiene, healthContext).
- Cross-slice mutations: `addJournal` writes a `MemoryNote`; meal/workout/recipe logging invalidates daily scores; `revoke` writes a trainer audit event; `setPersonalCareTask` toggles both `completedPersonalCareTaskIDs` and `hygiene` for legacy compat.
- External coupling: `ConnectionInspector.attachStore(self)` back-reference; `extension FernletStore: ProximityTrustPolicy`; `Scoring.compute(for: FernletStore)`; `LaunchPreparationService` reads `store` heavily.
- ~20 view files hold a reference to `FernletStore`. After PR 0 the attribute is `@Bindable var store: FernletStore` (when bindings are needed) or just `var store: FernletStore` (read-only).

---

## 4. Target Architecture

```
┌──────────────────────────────────────────────────────────────┐
│                  @Observable FernletStore                     │
│   The single store views observe (read paths auto-tracked     │
│   by the Observation framework — forwarding is free).         │
│                                                                │
│   Owns directly:                                              │
│     day, settings, recentMeals, recipes, previousJournals,    │
│     memories, foodItems, workshop, dailyScores, goals,        │
│     companionThought, photowallSeeds, lockState,              │
│     connectionInspector, connectionSessionLogs,               │
│     showConnectionInspector                                   │
└──────────────────────────────────────────────────────────────┘
   │
   │ composes
   ▼
┌────────────────────────────┐  ┌────────────────────────────────┐
│  Pure logic (structs)       │  │  @Observable sub-services       │
├────────────────────────────┤  ├────────────────────────────────┤
│  MealBuilder                │  │  SavedRecipeService              │
│  RecipeShareCodec           │  │    - savedRecipes                │
│  CustomIngredientUpsert     │  │    - own SavedRecipeRepository   │
│  DerivedSignalsRebuilder    │  │    - own save debouncer          │
│  DayMutator                 │  │                                  │
│                             │  │  ProximityTrustVault             │
├─ Behavior classes ──────────┤  │    - trustedPeers, auditEvents   │
│  WorkoutHealthKitSync       │  │    - conforms to                 │
│  SnapshotSaveCoordinator    │  │      ProximityTrustPolicy        │
│  BundledFoodSeedingService  │  │                                  │
│  (BundledFoodSeedingService │  │  AIRetryQueueService             │
│   uses @Observable for the  │  │    - retryQueue                  │
│   state property, sits      │  │    - room to grow                │
│   between categories)       │  │                                  │
└────────────────────────────┘  │  DerivedSignalsService           │
                                │    - derivedSignals               │
                                │    - wraps Rebuilder              │
                                └────────────────────────────────┘
```

`FernletStore` exposes forwarding properties for the four sub-services so view code does not change. Example:
```swift
// On FernletStore
@ObservationIgnored let savedRecipeService: SavedRecipeService

var savedRecipes: [SavedRecipe] { savedRecipeService.savedRecipes }
func addSavedRecipe(_ r: SavedRecipe) { savedRecipeService.add(r) }
```
The Observation framework tracks the nested read inside the computed property automatically. Views that say `store.savedRecipes` still re-render when the underlying service updates. No `objectWillChange`, no Combine plumbing.

---

## 5. PR 0 — `@Observable` Migration

This is the largest-blast-radius PR in the plan. Every individual change is mechanical, but the migration is all-or-nothing: a partial migration (model classes converted, view attributes left unchanged) is worse than no migration at all, because `@ObservedObject` and `@StateObject` require `ObservableObject` conformance and will produce cascading build errors across every view that references the unconverted class.

> **Lesson recorded (May 2025):** A partial PR 0 was attempted. Thirteen classes were converted to `@Observable` but the ~36 view files were not updated. The result was a complete build failure with errors propagating from every view. Simultaneously, one file (`Persistence.swift`) lost runtime-critical logic (CloudKit error-recovery, iCloud availability pre-check) with no compile error — the only indicator was runtime CloudKit log spam. Recovery required reverting every changed file from an archived copy.

### 5.0 Pre-conditions — do these before writing a single line of PR 0

1. **Ensure the test suite passes.** Run all tests and resolve any existing failures *before* starting PR 0. Broken tests mask PR 0 regressions and make it impossible to verify the migration was behavior-neutral.
2. **Create a git snapshot commit.** `git add -A && git commit -m "snapshot: pre-PR0 baseline"` on a dedicated branch. This is your guaranteed rollback point.
3. **Record a line-count baseline.** For each of the 13 classes in §5.1, note the current file line count. After converting each file, verify the count is within ±5 lines of the pre-change count. A large drop indicates logic was silently deleted.
4. **Do not mix concerns.** PR 0 touches only observation-framework attributes. No logic changes, no restructuring, no renames beyond what the pattern table in §5.2 specifies.

### 5.0.1 Execution order within PR 0

Convert in this order and **build after each file**:

1. Convert one model class (start with `PeriodTrackerStore` — it has few view consumers).
2. Update every view that references it (`@ObservedObject` → plain `var` or `@Bindable`).
3. Verify build is green before moving to the next class.
4. Repeat for remaining 12 classes.

Never leave a class converted while its consuming views are still using `@ObservedObject`. The window of broken state should last only seconds, not a commit.

### 5.1 Type-side changes (13 classes)

For each of these classes, replace `: ObservableObject` with the `@Observable` macro and strip `@Published`:

| File | Class |
|---|---|
| `FernletStore.swift` | `FernletStore` |
| `FernletStoreLoader.swift` | `FernletStoreLoader` |
| `ConnectionInspector.swift` | `ConnectionInspector` |
| `LaunchPreparationService.swift` | `LaunchPreparationService` |
| `PeriodTrackerStore.swift` | `PeriodTrackerStore` |
| `StoragePreferences.swift` | `StoragePreferencesStore` |
| `FernletLockService.swift` | `FernletLockService` |
| `OnboardingCoordinator.swift` | `OnboardingCoordinatorModel` |
| `HealthKitService.swift` | `HealthKitAuthorizationViewModel` |
| `Persistence.swift` | `PersistenceController` |
| `ProximityCoordinator.swift` | `ProximityCoordinator` |
| `FriendPhotoShareView.swift` | `FriendPhotoSharingService` |
| `TrainerProximityService.swift` | `TrainerProximityService` |

Pattern:
```swift
// Before
@MainActor
final class Foo: ObservableObject {
    @Published var bar: Int = 0
    @Published private(set) var baz: String = ""
}

// After
@MainActor
@Observable
final class Foo {
    var bar: Int = 0
    private(set) var baz: String = ""
}
```

**Stored properties to mark `@ObservationIgnored`:** any property where reads should *not* trigger view re-evaluation. Candidates:
- `repository`, `savedRecipeRepository`, `healthKitService` on `FernletStore` (immutable infrastructure refs)
- `snapshotSaveTask`, `remoteReloadTask`, `cancellables`, `savedRecipeSaveScheduled`, `bundledFoodSeedSavePending`, `launchScreenDismissed`, `deferredPostLaunchTasksStarted`, `isReloadingFromRepository` (internal bookkeeping)
- `todayKey` (immutable)
- Static constants (`goodProteinThreshold`) need no annotation; they're not stored on instances.

When in doubt: if a property is `let` or never causes UI re-render when it changes, mark it `@ObservationIgnored`. The compiler will catch missing init defaults; runtime behavior is identical either way, only observation tracking differs.

**Init defaults:** `@Observable` requires every stored property to have either a default value or be set in init. The current code already follows this pattern.

**`Combine` imports:** Remove `import Combine` where it was only there for `@Published`. Keep it where the file uses `AnyCancellable`, `PassthroughSubject`, or `.sink`. After Phase 1 ships, `cancellables` on `FernletStore` is moved to `SnapshotSaveCoordinator`, so `FernletStore.swift` will be able to drop the Combine import then.

### 5.2 View-side changes (~22 files)

Pattern table:

| Old | New | When to use |
|---|---|---|
| `@StateObject private var foo = Foo()` | `@State private var foo = Foo()` | View *owns* the lifecycle. |
| `@ObservedObject var foo: Foo` | `var foo: Foo` | View receives the object, only reads. |
| `@ObservedObject var foo: Foo` (uses `$foo.bar`) | `@Bindable var foo: Foo` | View receives the object and needs bindings. |
| `@EnvironmentObject var foo: Foo` | `@Environment(Foo.self) private var foo` | View pulls from environment. |
| `.environmentObject(foo)` | `.environment(foo)` | Parent injects. |

**`@Bindable` notes.** Required at the *binding* site. If you have `@ObservedObject var store: FernletStore` and use both `store.day.meals` (read) and `$store.settings.userProfile` (binding) in the same view, `@Bindable var store: FernletStore` covers both. Search for `$store.` in the codebase to find all sites that need `@Bindable`.

### 5.3 Test-side changes

`FernletTests`, `FernletPersistenceTests`, `FernletLockTests` etc. construct stores directly. No attribute changes needed in tests — `Foo()` works the same way. Verify no test uses `.objectWillChange.send()` for synchronization; if it does, replace with a direct assertion on the property.

### 5.4 Verification checklist before merging PR 0

**Build integrity**
- [x] Project builds with zero errors.
- [x] No file imports `Combine` purely for `@Published` in production code. `FernletStore` still imports Combine for the preserved remote-change `.sink` subscription.
- [x] No occurrence of `ObservableObject`, `@ObservedObject`, `@StateObject`, `@EnvironmentObject`, `@Published`, `.environmentObject(`, or `objectWillChange` in production code under `Fernlet/Fernlet`.
- [ ] All previews compile.

**Silent regression guard (lesson from May 2025 incident)**
- [ ] For each of the 13 converted files, compare final line count to the pre-PR0 baseline. Any file >5 lines shorter than baseline must be diffed manually before merging.
- [ ] `Persistence.swift`: confirm `cloudKitNoAccountErrorCode` recovery path is present, `StoragePreferencesStore()` is used in `shared` singleton (not `StoragePreferences()`), and `allowsExternalBinaryDataStorage: true` is set on `payloadData`.
- [ ] `FernletStore.swift`: confirm `rebuildDerivedSignals()`, `deferredPostLaunchTasks()`, and all repository reload paths are present.
- [ ] `HealthKitService.swift`: confirm `loadBodyProfile()`, `loadLastNightSleepHours()`, and `loadDailyHealthContext()` all contain real HealthKit queries (not stub returns).

**Test and behavior**
- [x] Non-UI test coverage passed in focused batches: 334 passed, 3 HealthKit environment-dependent skips, 0 failures.
- [ ] Full UI-test suite pass still needs a stable simulator run. The interrupted Gate C run hit an Xcode attach failure; the two surfaced UI assertions passed when rerun individually.
- [ ] Manual smoke: launch app, log a meal, navigate every tab, lock/unlock, open Settings, open Period Tracker — confirm UI updates correctly. Particular attention to bindings in `SettingsSheet` and `ContentView`, the two `FernletStore` binding sites after PR 0.
- [x] No new build warnings were reported by Xcode after PR 0.
- [ ] CloudKit log is clean (no `NSCocoaErrorDomain Code=134400` if signed in; graceful offline-only fallback if not signed in).

### 5.5 Estimated impact

- ~32 files touched.
- Behavior identical.
- ~3 engineer-days including manual smoke testing.

---

## 6. Phase 1 — Stateless Service Extraction

Each item is one PR. They are mutually independent and can be done in parallel.

### 6.1 `MealBuilder`

**New file:** `Fernlet/Fernlet/MealBuilder.swift`

```swift
@MainActor
struct MealBuilder {
    static let goodProteinThreshold = 25

    struct PlanResult {
        let meals: [Meal]
        /// Recipes the builder needed to create. Caller should insert these
        /// into its recipes array before returning.
        let createdRecipes: [RecipeDefinition]
    }

    static func meals(
        from plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate],
        recipes: [RecipeDefinition],
        foodItems: [FoodItem],
        originalDescription: String
    ) -> PlanResult?

    static func mealFromRecipe(
        _ recipe: RecipeDefinition,
        mealType: MealType,
        foodItems: [FoodItem]
    ) -> Meal

    static func mealFromIngredients(
        itemName: String,
        resolvedIngredients: [(FoodSelectionIngredient, FoodItem)],
        mealType: MealType
    ) -> Meal

    // Internal helpers (private static):
    //   - mealLogSource(for:foodItems:)
    //   - createRecipe(for:resolvedIngredients:)
    //   - totals(for:)
    //   - bestRecipeMatch(for:in:)
    //   - isRelevant(foodItem:to:)
}
```

**Moves from `FernletStore`:** `meals(from:candidates:originalDescription:)`, `makeMealFromRecipe`, `meal(from recipe:)`, `meal(from itemName:)`, `mealLogSource(for:)`, `createRecipeIfNeeded`, `totals(for:)`, `bestRecipeMatch`, `isRelevant`.

**Design note.** `createRecipeIfNeeded` currently mutates `recipes` as a side effect; the pure version returns created recipes in `PlanResult.createdRecipes` so the store inserts them. Eliminates a hidden mutation.

**New tests:** `MealBuilderTests` — table-driven scenarios for plan → meals, recipe-match precedence, `isRelevant` heuristics (especially the sandwich → bread/cheese rule).

LOC moved: ~160.

---

### 6.2 `RecipeShareCodec`

**New file:** `Fernlet/Fernlet/RecipeShareCodec.swift`

```swift
struct RecipeShareCodec {
    static func shareText(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> String
    static func payload(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> SharedRecipePayload
    static func decodePayload(from text: String) throws -> SharedRecipePayload
}
```

**Moves:** `recipeShareText(for:)`, `sharedRecipePayload(for:)`, `sharedRecipeJSON(for:)`, `sharedRecipePayload(from text:)`.

**New tests:** round-trip, missing-payload, version-mismatch.

LOC moved: ~70.

---

### 6.3 `CustomIngredientUpsert`

**New file:** `Fernlet/Fernlet/CustomIngredientUpsert.swift`

```swift
struct CustomIngredientUpsert {
    static func resolve(
        ingredient: ManualRecipeIngredientInput,
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> FoodItem

    static func recipeIngredients(
        from inputs: [ManualRecipeIngredientInput],
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> [RecipeIngredient]
}
```

**Moves:** `makeRecipeIngredients`, `upsertCustomFoodItem`. `saveCustomIngredient` on `FernletStore` becomes a 4-line wrapper.

**New tests:** new insert, normalized-name match update, empty-name guard.

LOC moved: ~50.

---

### 6.4 `WorkoutHealthKitSync`

**New file:** `Fernlet/Fernlet/WorkoutHealthKitSync.swift`

```swift
@MainActor
protocol WorkoutSyncContext: AnyObject {
    var todayKey: String { get }
    func workoutExists(id: UUID) -> Bool
    func workoutExists(healthKitUUID: UUID) -> Bool
    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String)
    func upsertWorkout(_ workout: Workout, date: String)
}

@MainActor
final class WorkoutHealthKitSync {
    private weak var context: WorkoutSyncContext?
    private let service: any HealthKitServicing

    init(context: WorkoutSyncContext, service: any HealthKitServicing)

    func saveIfAuthorized(_ workout: Workout, date: String) async
    func refreshFromHealth() async
    func backfillIfNeeded(defaults: UserDefaults) async

    static func makeWorkout(from hk: HKWorkout) -> Workout
    static func parseFernletMetadata(_ metadata: [String: Any]?) -> WorkoutHealthKitMetadata
    static func isWorkoutLoggingAuthorized(_ snapshot: AuthorizationSnapshot) -> Bool
}

struct WorkoutHealthKitMetadata {
    let muscleGroups: Set<MuscleGroup>
    let exercises: String
    let notes: String
    let effort: Int?
    let plannedWorkoutID: UUID?
}
```

`FernletStore` conforms to `WorkoutSyncContext` (the four context methods already exist or are trivial). The three `FernletStore` methods `saveWorkoutToHealthIfAuthorized`, `refreshWorkoutsFromHealth`, `backfillWorkoutsFromHealthIfNeeded` become three-line forwards into the sync object.

**Moves:** `saveWorkoutToHealthIfAuthorized`, `updateWorkoutHealthKitUUID`, `refreshWorkoutsFromHealth`, `backfillWorkoutsFromHealthIfNeeded`, `isWorkoutLoggingAuthorized`, `reconcileWorkouts`, `workoutExists` x2, `updateWorkoutHealthKitUUIDIfNeeded`, static `makeWorkout(from:)`, static `parseFernletMetadata`.

**Tests:** retarget existing `HealthKitWorkoutTests` to call the static helpers on `WorkoutHealthKitSync`. Add a fake `WorkoutSyncContext` for reconcile-path tests.

LOC moved: ~165.

---

### 6.5 `BundledFoodSeedingService`

**New file:** `Fernlet/Fernlet/BundledFoodSeedingService.swift`

```swift
@MainActor
@Observable
final class BundledFoodSeedingService {
    enum State { case notStarted, seeding, done, failed }

    private(set) var state: State = .notStarted

    /// Returns the items that were *added* (not already in `existing`).
    /// Caller merges them into its foodItems array and decides when to save.
    func ensureSeeded(existing existingFoodItems: [FoodItem]) async -> [FoodItem]
}
```

`FernletStore` keeps the launch-screen-pending-save dance (`markLaunchScreenDismissed`, `queueBundledFoodSeedSaveAfterLaunch`, `flushPendingBundledFoodSeedSaveIfNeeded`) because it's tied to the snapshot save scheduler. `FernletStore.bundledFoodSeedingState` becomes a forwarding computed property to keep `HomeView` working unchanged.

LOC moved: ~30.

---

### 6.6 `DerivedSignalsRebuilder`

**New file:** `Fernlet/Fernlet/DerivedSignalsRebuilder.swift`

```swift
struct DerivedSignalsRebuilder {
    static func rebuild(
        allDays: [String: FernletDay],
        todayKey: String,
        windowDays: Int = FernletLimits.signalWindowDays
    ) -> [DerivedSignalRecord]
}
```

Tiny but worth its own file — it has no dependencies on `FernletStore` and is trivially testable. Will be used by `DerivedSignalsService` in Phase 2.

LOC moved: ~10.

---

### 6.7 `SnapshotSaveCoordinator`

**New file:** `Fernlet/Fernlet/SnapshotSaveCoordinator.swift`

```swift
@MainActor
final class SnapshotSaveCoordinator {
    init(
        repository: FernletRepository,
        debounce: Duration = .seconds(1),
        buildSnapshot: @escaping @MainActor () -> FernletSnapshot,
        onAfterSave: @escaping @MainActor () -> Void
    )

    func schedule()
    func flushPending()
    func subscribeRemote(onRemoteChange: @escaping @MainActor () async -> Void)
}
```

**Moves:** `scheduleSnapshotSave`, `flushPendingSnapshotSave`, `performSnapshotSave`, `subscribeToRemoteChangesIfNeeded`, `scheduleRemoteRepositoryReload`. The `snapshotSaveTask`, `remoteReloadTask`, `cancellables`, `isReloadingFromRepository` members move into the coordinator.

`batchSnapshotPersistence`, `apply(_ snapshot:)`, and `reloadFromRepository` stay on `FernletStore` because they fan out across slices.

LOC moved: ~110.

---

### 6.8 `DayMutator` (optional small helper)

**New file or extension:** `Fernlet/Fernlet/DayMutator.swift`

```swift
@MainActor
extension FernletStore {
    /// If targetDate is today, mutates `day`. Otherwise updates the repository.
    /// Schedules a snapshot save in either case.
    func mutateDay(date: String, _ change: (inout FernletDay) -> Void) -> Bool
}
```

`mutatePastDay` is called from 8 sites with similar today/past branching wrappers. This collapses the duplication. Implementation is ~15 lines.

LOC saved through dedup: ~30.

---

### Phase 1 totals

- ~625 lines moved/deduplicated out of `FernletStore`.
- Zero view-file changes.
- 6 new test files.
- ~7 engineer-days total.

---

## 7. Phase 2 — Stateful `@Observable` Sub-Services

These four extracts move state out of `FernletStore` into focused `@Observable` services. `FernletStore` retains forwarding properties so views are unchanged.

### 7.1 `SavedRecipeService`

**New file:** `Fernlet/Fernlet/SavedRecipeService.swift`

```swift
@MainActor
@Observable
final class SavedRecipeService {
    private(set) var savedRecipes: [SavedRecipe] = []

    @ObservationIgnored private let repository: SavedRecipeRepository
    @ObservationIgnored private var saveScheduled = false

    init(repository: SavedRecipeRepository = SavedRecipeRepository())

    func loadAsync() async
    func add(_ recipe: SavedRecipe)
    func update(_ recipe: SavedRecipe)
    func delete(_ recipe: SavedRecipe)
    func reset()
    func shareText(for recipe: SavedRecipe) -> String

    /// Pure Meal construction — does not mutate any day.
    static func makeMeal(from recipe: SavedRecipe, mealType: MealType?) -> Meal

    private func scheduleSave()
}
```

**Forwarding on `FernletStore`:**
```swift
@ObservationIgnored let savedRecipeService: SavedRecipeService

var savedRecipes: [SavedRecipe] { savedRecipeService.savedRecipes }
func addSavedRecipe(_ r: SavedRecipe) { savedRecipeService.add(r) }
func updateSavedRecipe(_ r: SavedRecipe) { savedRecipeService.update(r) }
func deleteSavedRecipe(_ r: SavedRecipe) { savedRecipeService.delete(r) }
func savedRecipeShareText(for r: SavedRecipe) -> String { savedRecipeService.shareText(for: r) }

@discardableResult
func logSavedRecipe(_ recipe: SavedRecipe, mealType: MealType? = nil, date: String? = nil) -> Meal {
    let meal = SavedRecipeService.makeMeal(from: recipe, mealType: mealType)
    appendMeal(meal, date: date ?? todayKey)
    return meal
}
```

**Tests:** `SavedRecipeServiceTests` — add de-dups by source URL, update, delete, share-text formatting, `makeMeal` correctness with and without macros.

LOC moved: ~85.

---

### 7.2 `ProximityTrustVault`

**New file:** `Fernlet/Fernlet/ProximityTrustVault.swift`

```swift
@MainActor
@Observable
final class ProximityTrustVault: ProximityTrustPolicy {
    private(set) var trustedPeers: [ProximityTrustedPeerRecord] = []
    private(set) var auditEvents: [TrainerAuditEvent] = []

    @ObservationIgnored private let onChange: @MainActor () -> Void

    init(
        initialPeers: [ProximityTrustedPeerRecord] = [],
        initialAudit: [TrainerAuditEvent] = [],
        onChange: @escaping @MainActor () -> Void
    )

    // Reads
    func peer(fingerprint: String) -> ProximityTrustedPeerRecord?
    func peer(displayName: String) -> ProximityTrustedPeerRecord?
    func isTrustedProximityPeer(fingerprint: String) -> Bool
    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool

    // Writes
    func trust(_ peer: ProximityCoordinator.PeerIdentity, mode: ProximityCoordinator.Mode)
    func revoke(fingerprint: String)
    func recordTrainerAudit(_ event: TrainerAuditEvent)

    // Snapshot in/out
    func apply(peers: [ProximityTrustedPeerRecord], audit: [TrainerAuditEvent])
}
```

**Forwarding on `FernletStore`:** The existing public methods (`trustProximityPeer`, `revokeTrustedProximityPeer`, `trustedProximityPeer(fingerprint:)`, `trustedProximityPeer(displayName:)`, `recordTrainerAudit`, `isTrustedProximityPeer`, `isRevokedProximitySigningKey`) each become a one-line forward. The `extension FernletStore: ProximityTrustPolicy` is unchanged in interface; its body forwards to the vault.

`onChange` is wired to `FernletStore.scheduleSnapshotSave`.

**Tests:** `ProximityTrustVaultTests` — trust idempotency by fingerprint, revoke writes an audit event, revoked peer detection, audit-event ring buffer cap at 500.

LOC moved: ~85.

---

### 7.3 `AIRetryQueueService`

**New file:** `Fernlet/Fernlet/AIRetryQueueService.swift`

```swift
@MainActor
@Observable
final class AIRetryQueueService {
    private(set) var retryQueue: [AIAnalysisRetryRecord] = []

    @ObservationIgnored private let onChange: @MainActor () -> Void

    init(initial: [AIAnalysisRetryRecord] = [],
         onChange: @escaping @MainActor () -> Void)

    var pendingCount: Int { retryQueue.count }

    func queueMealRetry(_ meal: Meal)
    func clear(id: UUID)
    func apply(_ queue: [AIAnalysisRetryRecord])
    func reset()
}
```

**Future-proofing note.** Per the design directive that AI surface will grow, this service is the home for upcoming retry kinds (workout analysis, recipe parsing, daily summary). Add the new kinds as new methods (`queueWorkoutRetry`, etc.) rather than overloading `queueMealRetry`. Keep the underlying `AIAnalysisRetryRecord.payloadType` string as the dispatch key.

**Forwarding on `FernletStore`:**
```swift
@ObservationIgnored let aiRetryQueueService: AIRetryQueueService

var retryQueue: [AIAnalysisRetryRecord] { aiRetryQueueService.retryQueue }
var pendingRetryCount: Int { aiRetryQueueService.pendingCount }
func queueMealRetry(_ m: Meal) { aiRetryQueueService.queueMealRetry(m) }
func clearRetryItem(_ id: UUID) { aiRetryQueueService.clear(id: id) }
```

**Tests:** queue ordering, clear-by-id, capacity bounds if any are added.

LOC moved: ~20.

---

### 7.4 `DerivedSignalsService`

**New file:** `Fernlet/Fernlet/DerivedSignalsService.swift`

```swift
@MainActor
@Observable
final class DerivedSignalsService {
    private(set) var derivedSignals: [DerivedSignalRecord] = []

    @ObservationIgnored private var deferredStarted = false

    func rebuild(allDays: [String: FernletDay], todayKey: String) {
        derivedSignals = DerivedSignalsRebuilder.rebuild(
            allDays: allDays, todayKey: todayKey
        )
    }

    /// Schedules a low-priority rebuild after launch.
    func scheduleDeferredRebuild(allDays: @escaping @MainActor () -> [String: FernletDay],
                                 todayKey: String)
}
```

`FernletStore` calls `derivedSignalsService.rebuild(...)` from `apply(_:)` and from `performSnapshotSave` (via the `onAfterSave` hook on the coordinator). `deferredPostLaunchTasks` on `FernletStore` becomes a one-line forward.

**Tests:** rebuild correctness against fixture day sets.

LOC moved: ~25.

---

### Phase 2 totals

- ~215 lines moved out of `FernletStore`.
- Zero view-file changes (forwarding properties preserve the surface).
- 4 new test files.
- ~5 engineer-days total.

After Phase 2: `FernletStore` is approximately 700 lines, ~95% mutator orchestration and state declarations.

---

## 8. Cross-Cutting Concerns & How They're Handled

| Concern | Resolution |
|---|---|
| Snapshot save | `SnapshotSaveCoordinator` reads from `FernletStore` properties (which read from sub-services). Single save path. |
| CloudKit remote reload | Coordinator subscribes; `FernletStore.reloadFromRepository` calls `apply(_:)`, which calls `subService.apply(...)` for each Phase 2 service. |
| Cross-slice ops (`addJournal` → memory, `revoke` → audit, `addWorkout` → daily-score invalidation) | Routed through `FernletStore` orchestrator methods. Each sub-service's writes stay internal; cross-slice writes are explicit at the facade. |
| `ConnectionInspector.attachStore(self)` back-reference | Unchanged. The inspector still holds a `weak` ref to `FernletStore` and reads `connectionSessionLogs`. |
| `Scoring.compute(for: FernletStore)` | Unchanged. Optional later cleanup: extract a `DailyScoreContext` value type. |
| `LaunchPreparationService` passing `store` around | Unchanged. The service reads through the same forwarding properties. |
| `FernletStore()` no-arg preview init | Sub-services get default initializers; preview init still works. Verify previews compile. |
| `@MainActor` invariants | Every new type stays `@MainActor`. No actor hops introduced. |
| Reset (`resetAll`) | Calls `subService.reset()` on each Phase 2 service in addition to clearing local state. |
| Observation tracking through forwarding | Verified by `@Observable` semantics — nested property reads inside computed properties are tracked. No manual signaling needed. |

---

## 9. Testing Strategy

### Before PR 0
- Capture baseline: full test suite green, record runtime of `FernletPersistenceTests`.
- Add a snapshot round-trip test if missing: populate every slice with non-empty data, save, reload via `FernletStore.load`, assert equality across slices.

### During PR 0
- After migration, full suite must remain green. No new test files; only adapt tests that reference removed attributes.
- Manual smoke is mandatory: bindings in `SettingsSheet`, `OnboardingView`, and `SharedSheets`; lock/unlock; period tracker; iCloud sync on/off.

### During Phase 1
- Each PR ships with a new test file for the extracted type. Aim for happy path + 2–3 edge cases per public function.
- Full suite remains green after every PR.

### During Phase 2
- Each PR adds a service-specific test file.
- Add a snapshot round-trip test that mutates each Phase 2 service, saves, reloads, and asserts the new state survives.
- Smoke test the iCloud sync path end-to-end on two devices: mutate proximity trust on device A, verify device B picks it up after remote reload.

### What is explicitly out of scope
- `FernletRepository` shape, `FernletSnapshot` schema, Core Data model, CloudKit transport.
- `MenstrualNarrativeRepository`, `PendingNarrativeBuffer`, `PeriodTrackerStore` internals (only the `@Observable` macro changes).
- Lock service crypto.
- View hierarchy.

---

## 10. Sequencing & PR Plan

| # | PR | Effort | Risk |
|---|---|---|---|
| -1 | Baseline snapshot round-trip test | 0.5d | None |
| 0 | `@Observable` migration (all 13 classes + ~22 views) | 3d | Medium (wide blast radius) |
| 1 | Extract `RecipeShareCodec` | 0.5d | Low |
| 2 | Extract `CustomIngredientUpsert` | 0.5d | Low |
| 3 | Extract `DerivedSignalsRebuilder` | 0.25d | None |
| 4 | Extract `MealBuilder` | 1.5d | Medium |
| 5 | Extract `WorkoutHealthKitSync` | 2d | Medium (HK auth path) |
| 6 | Extract `SnapshotSaveCoordinator` | 1.5d | Medium |
| 7 | Extract `BundledFoodSeedingService` | 0.5d | Low |
| 8 | Optional: `DayMutator` extension | 0.5d | Low |
| 9 | Extract `SavedRecipeService` | 1.5d | Medium |
| 10 | Extract `ProximityTrustVault` | 1.5d | Medium |
| 11 | Extract `AIRetryQueueService` | 1d | Low |
| 12 | Extract `DerivedSignalsService` | 1d | Low |
| 13 | Update `FileIndex.md` and any architecture notes | 0.25d | None |

**Total:** ~15 engineer-days. Phase 0 alone is ~3 days; Phase 1 ~7 days; Phase 2 ~5 days.

PRs 1–8 can land in any order. PRs 9–12 should land sequentially because each touches the snapshot persistence path.

---

## 11. Xcode AI Implementation Prompts

The prompts below are designed for use with an AI coding assistant inside Xcode (Claude Code, GitHub Copilot Chat, Cursor, etc.). Each prompt is **self-contained** — it includes the contract, inputs, outputs, constraints, and testing requirements. Copy a prompt verbatim into the assistant when you're ready to do that PR.

**Usage conventions** (apply to every prompt):
- The assistant should *always* list the files it intends to create or modify and ask for confirmation before writing code.
- The assistant must run the test suite after the change and report results.
- The assistant must not modify files outside the listed scope.
- All new types are `@MainActor`. All stateful service types are `@Observable`. No `ObservableObject` is permitted in new files.
- If something in the source files surprises the assistant or contradicts the prompt, it should stop and ask before guessing.

---

### Prompt PR -1 — Baseline snapshot round-trip test

```
You are adding a baseline regression test to the Fernlet iOS project. This test exists
to anchor an upcoming refactor and must pass against the current code unchanged.

GOAL
Add a test that populates every slice of FernletStore with non-empty data, saves the
snapshot through the repository, reloads via FernletStore.load(), and asserts that
every slice survives the round-trip with content equal to what was written.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/LocalFernletRepository.swift
  Fernlet/Fernlet/Models.swift
  Fernlet/Fernlet/SavedRecipe.swift
  Fernlet/Fernlet/CoreDataFernletRepository.swift
Modify or create:
  Fernlet/FernletTests/FernletPersistenceTests.swift (extend existing)
  or
  Fernlet/FernletTests/FernletSnapshotRoundTripTests.swift (new file)

REQUIREMENTS
- Use an in-memory LocalFernletRepository (a file-URL-backed temp file is acceptable).
- Populate at minimum: day (meals, workouts, journals, sleep, water, hygiene,
  completedPersonalCareTaskIDs, healthContext), settings (with non-default
  userProfile), recentMeals (3+), previousJournals (3+), memories (3+), goals (2+),
  workshop.textureEntries (2+), foodItems (3+), recipes (2+), dailyScores (2+),
  retryQueue (2+), connectionSessionLogs (2+), trustedProximityPeers (2+),
  trainerAuditEvents (3+). For savedRecipes: also populate via the SavedRecipeRepository.
- Save through the repository (`saveSnapshot`), then load through the same repository
  for the same todayKey, then assert deep equality of each slice.
- The test must be deterministic (no Date.now in equality-relevant fields unless
  explicitly captured).

CONSTRAINTS
- @MainActor where appropriate.
- Do not modify FernletStore.swift or any production code.
- If the test reveals a real round-trip bug, stop and report it. Do not fix it in
  this PR.

DELIVERABLE
1. Test file with the round-trip test.
2. Test runs green against the current code.
3. Brief summary of what was populated and asserted.
```

---

### Prompt PR 0 — `@Observable` migration

```
You are migrating the Fernlet iOS app from the legacy ObservableObject pattern to the
Swift Observation framework (@Observable). The deployment target is iOS 26, so
@Observable is available unconditionally.

GOAL
Replace ObservableObject and its accompanying property wrappers across the entire
codebase. Behavior must be identical after the migration; only observation mechanics
change.

SCOPE
Migrate every class in this list (paths relative to Fernlet/Fernlet/):
  FernletStore.swift → FernletStore
  FernletStoreLoader.swift → FernletStoreLoader
  ConnectionInspector.swift → ConnectionInspector
  LaunchPreparationService.swift → LaunchPreparationService
  PeriodTrackerStore.swift → PeriodTrackerStore
  StoragePreferences.swift → StoragePreferencesStore
  FernletLockService.swift → FernletLockService
  OnboardingCoordinator.swift → OnboardingCoordinatorModel
  HealthKitService.swift → HealthKitAuthorizationViewModel
  Persistence.swift → PersistenceController
  ProximityCoordinator.swift → ProximityCoordinator
  FriendPhotoShareView.swift → FriendPhotoSharingService
  TrainerProximityService.swift → TrainerProximityService

For each of these classes:
- Replace `: ObservableObject` with the `@Observable` macro placed before the class
  declaration.
- Remove every `@Published` annotation; the property remains unchanged otherwise.
- Mark internal bookkeeping properties (Task handles, scheduled flags, immutable
  infrastructure refs, cached subjects, weak back-refs) with @ObservationIgnored.
  When in doubt: if the property's mutation should not trigger a view re-render,
  mark it @ObservationIgnored.
- Remove `import Combine` ONLY if the file no longer uses any Combine API. Keep it if
  the file uses AnyCancellable, PassthroughSubject, .sink, etc.

For every SwiftUI view in the project (search for any of the wrappers below):
- @StateObject private var foo = Foo()  →  @State private var foo = Foo()
- @ObservedObject var foo: Foo (no $bindings in this view)  →  var foo: Foo
- @ObservedObject var foo: Foo (uses $foo.bar bindings)  →  @Bindable var foo: Foo
- @EnvironmentObject var foo: Foo  →  @Environment(Foo.self) private var foo
- .environmentObject(foo)  →  .environment(foo)

Test files: no attribute changes needed; constructions remain the same.

CONSTRAINTS
- Do not introduce new state, new types, or new behavior. This is a pure migration.
- Do not consolidate properties, rename anything, or refactor logic.
- Every @MainActor annotation stays exactly where it is.
- The PeriodTrackerStore, ProximityCoordinator, FriendPhotoSharingService, and
  TrainerProximityService migrate alongside everything else — do not skip them.

PROCESS
1. List every file you will modify in two groups: (a) class declarations, (b) view
   files. Wait for confirmation before writing code.
2. Migrate class declarations first. After each file, confirm the project compiles.
3. Migrate view files. Pay close attention to bindings: search the codebase for
   `$store.` and similar to find every binding site; those views need @Bindable.
4. Run the full test suite. Report results.
5. Run a final search for: `ObservableObject`, `@ObservedObject`, `@StateObject`,
   `@EnvironmentObject`, `@Published`, `.environmentObject(`. The only matches
   permitted are inside the CryptoSwift dependency and code comments.

DELIVERABLE
1. All listed files migrated.
2. Test suite green.
3. A short report listing: number of @Bindable conversions, number of environment
   conversions, files where Combine was removed.
4. Manual smoke checklist for the human to run before merging: launch, log a meal,
   navigate every tab, lock and unlock, open Settings (which uses $store.settings
   bindings extensively), open the Period Tracker, log a period event, toggle
   iCloud sync. Confirm UI updates correctly throughout.
```

---

### Prompt PR 1 — Extract `RecipeShareCodec`

```
You are extracting recipe-share-text encoding and decoding logic out of FernletStore
into a dedicated value type. This is a pure-logic move; no behavior changes.

GOAL
Create RecipeShareCodec and migrate the four related methods out of FernletStore.

SCOPE
Read-only inputs:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/Models.swift   (defines SharedRecipePayload, RecipeImportError, etc.)
Create:
  Fernlet/Fernlet/RecipeShareCodec.swift
  Fernlet/FernletTests/RecipeShareCodecTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift (remove the moved methods, replace internal
  call sites with calls to the codec)

NEW TYPE CONTRACT
struct RecipeShareCodec {
    static func shareText(for recipe: RecipeDefinition,
                          foodItems: [FoodItem]) -> String
    static func payload(for recipe: RecipeDefinition,
                        foodItems: [FoodItem]) -> SharedRecipePayload
    static func decodePayload(from text: String) throws -> SharedRecipePayload
}

MOVES (from FernletStore.swift)
- recipeShareText(for:)              → RecipeShareCodec.shareText(for:foodItems:)
- sharedRecipePayload(for:)          → RecipeShareCodec.payload(for:foodItems:)
- sharedRecipeJSON(for:)             → internal helper in RecipeShareCodec
- sharedRecipePayload(from text:)    → RecipeShareCodec.decodePayload(from:)

Update FernletStore.recipeShareText(for:) to be a one-line forward into the codec.
Update FernletStore.importRecipe(from:) to call RecipeShareCodec.decodePayload.

TESTS
RecipeShareCodecTests must cover:
- Round-trip: encode a RecipeDefinition with 3+ ingredients, decode the JSON,
  confirm equality of the SharedRecipePayload.
- Round-trip through the human-readable shareText: encode, embed in some
  preamble text, then extract.
- Reject input with no "Fernlet recipe data:" marker → RecipeImportError.missingPayload
- Reject invalid JSON after the marker → RecipeImportError.invalidPayload
- Reject mismatched format/version → RecipeImportError.unsupportedFormat

CONSTRAINTS
- No new behavior. Match the existing methods exactly.
- Do not modify SharedRecipePayload, SharedRecipeIngredient, or RecipeImportError.
- @MainActor not required for RecipeShareCodec; it has no actor-bound dependencies.

PROCESS
1. List the files you will create/modify and confirm.
2. Implement RecipeShareCodec.
3. Migrate FernletStore call sites.
4. Add tests.
5. Run the full suite. Confirm green.
```

---

### Prompt PR 2 — Extract `CustomIngredientUpsert`

```
You are extracting custom-ingredient upsert logic out of FernletStore into a pure
helper. No behavior changes.

GOAL
Create CustomIngredientUpsert and migrate the two related methods.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/Models.swift
Create:
  Fernlet/Fernlet/CustomIngredientUpsert.swift
  Fernlet/FernletTests/CustomIngredientUpsertTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

NEW TYPE CONTRACT
struct CustomIngredientUpsert {
    /// Insert or update a manual ingredient into the foodItems array.
    /// Matches an existing manual entry by normalized-name equality.
    /// Returns the resulting FoodItem.
    static func resolve(
        ingredient: ManualRecipeIngredientInput,
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> FoodItem

    /// Validate and convert a list of manual inputs into RecipeIngredient values.
    /// Assertion: at least one valid input. Side-effect: may mutate foodItems via
    /// `resolve`.
    static func recipeIngredients(
        from inputs: [ManualRecipeIngredientInput],
        in foodItems: inout [FoodItem],
        verifiedAt: Date
    ) -> [RecipeIngredient]
}

MOVES
- upsertCustomFoodItem        → CustomIngredientUpsert.resolve
- makeRecipeIngredients       → CustomIngredientUpsert.recipeIngredients

FernletStore.saveCustomIngredient becomes:
    @discardableResult
    func saveCustomIngredient(_ ingredient: ManualRecipeIngredientInput) -> FoodItem? {
        guard !ingredient.trimmedName.isEmpty else { return nil }
        return batchSnapshotPersistence {
            CustomIngredientUpsert.resolve(
                ingredient: ingredient,
                in: &foodItems,
                verifiedAt: Date()
            )
        }
    }

TESTS
- New insert with empty foodItems.
- Update by normalized-name match (existing manual entry).
- Should not update non-manual entries (USDA source items must not be overwritten).
- recipeIngredients filters out inputs with empty trimmedName.

PROCESS as in PR 1.
```

---

### Prompt PR 3 — Extract `DerivedSignalsRebuilder`

```
You are extracting derived-signal computation into a tiny standalone helper. This is
preparation for PR 12 which will introduce DerivedSignalsService.

GOAL
Create DerivedSignalsRebuilder. Move the inner computation of
FernletStore.rebuildDerivedSignals into a static function.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/LocalFernletRepository.swift  (DerivedSignalFactory, FernletLimits)
  Fernlet/Fernlet/Models.swift                  (DerivedSignalRecord)
Create:
  Fernlet/Fernlet/DerivedSignalsRebuilder.swift
  Fernlet/FernletTests/DerivedSignalsRebuilderTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
struct DerivedSignalsRebuilder {
    static func rebuild(
        allDays: [String: FernletDay],
        todayKey: String,
        windowDays: Int = FernletLimits.signalWindowDays
    ) -> [DerivedSignalRecord]
}

FernletStore.rebuildDerivedSignals becomes:
    private func rebuildDerivedSignals() {
        StartupTiming.timed("FernletStore.rebuildDerivedSignals") {
            derivedSignals = DerivedSignalsRebuilder.rebuild(
                allDays: loadDays(),
                todayKey: todayKey
            )
        }
    }

TESTS
- Empty allDays → empty result.
- Single day → result matches DerivedSignalFactory output for that fixture.
- Window respects windowDays parameter.

PROCESS as in PR 1.
```

---

### Prompt PR 4 — Extract `MealBuilder`

```
You are extracting meal-construction logic out of FernletStore. This is the largest
logic move in Phase 1 (~160 lines).

GOAL
Create MealBuilder and migrate the meal-building helpers. Eliminate the hidden
side-effect mutation of `recipes` inside the current createRecipeIfNeeded path by
returning created recipes from the builder for the caller to insert.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/Models.swift
  Fernlet/Fernlet/FoundationFoodSelection.swift
  Fernlet/Fernlet/Scoring.swift
  Fernlet/Fernlet/FoodDataCatalog.swift   (FoodItemSearch)
Create:
  Fernlet/Fernlet/MealBuilder.swift
  Fernlet/FernletTests/MealBuilderTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
@MainActor
struct MealBuilder {
    static let goodProteinThreshold = 25

    struct PlanResult {
        let meals: [Meal]
        let createdRecipes: [RecipeDefinition]
    }

    static func meals(
        from plan: FoodSelectionPlan,
        candidates: [FoodSelectionCandidate],
        recipes: [RecipeDefinition],
        foodItems: [FoodItem],
        originalDescription: String
    ) -> PlanResult?

    static func mealFromRecipe(
        _ recipe: RecipeDefinition,
        mealType: MealType,
        foodItems: [FoodItem]
    ) -> Meal

    static func mealFromIngredients(
        itemName: String,
        resolvedIngredients: [(FoodSelectionIngredient, FoodItem)],
        mealType: MealType
    ) -> Meal
}

Private static helpers inside MealBuilder:
- mealLogSource(for recipe:foodItems:) -> String
- createRecipe(for itemName:resolvedIngredients:) -> RecipeDefinition
- totals(for resolvedIngredients:) -> (macros: MacroTotals, micronutrients: Micronutrients)
- bestRecipeMatch(for itemName:in recipes:) -> RecipeDefinition?
- isRelevant(foodItem:to itemName:) -> Bool

MOVES (from FernletStore.swift)
- meals(from:candidates:originalDescription:)   → MealBuilder.meals
- makeMealFromRecipe                             → MealBuilder.mealFromRecipe
- meal(from recipe:mealType:)                    → folds into MealBuilder.mealFromRecipe
- meal(from itemName:resolvedIngredients:mealType:) → MealBuilder.mealFromIngredients
- mealLogSource                                  → private to MealBuilder
- createRecipeIfNeeded                           → MealBuilder.createRecipe (no mutation;
                                                   returned via PlanResult.createdRecipes)
- totals(for:)                                   → private to MealBuilder
- bestRecipeMatch                                → private to MealBuilder
- isRelevant                                     → private to MealBuilder

CALL-SITE UPDATE
FernletStore.addResolvedMeals is the main caller. Replace its `meals(from:...)` call
with:
    let result = MealBuilder.meals(
        from: plan,
        candidates: candidates,
        recipes: recipes,
        foodItems: foodItems,
        originalDescription: description
    )
    if let result, !result.meals.isEmpty {
        // Insert any newly-created recipes
        for newRecipe in result.createdRecipes {
            recipes.insert(newRecipe, at: 0)
        }
        result.meals.forEach { appendMeal($0, date: targetDate) }
        return result.meals
    }

TESTS
MealBuilderTests must include:
- Plan with no candidates returns nil.
- Plan with a name matching an existing recipe returns a recipe-typed Meal.
- Plan with a name not matching any recipe, with multiple resolved ingredients,
  produces a Meal and surfaces a created RecipeDefinition in createdRecipes.
- Plan with a single resolved ingredient produces a manual Meal (no recipe created).
- isRelevant rule: itemName "sandwich" with ingredient tokens "bread" or "cheese"
  returns true.
- isRelevant rule: itemName "grilled cheese" with ingredient tokens including
  "bread" or "sourdough" returns true.
- mealLogSource: USDA-source recipe → "usda_recipe"; label-scan ingredient micros
  ≥ 5 fields → "label_scan"; web-import source → "web_import"; otherwise manual.

PROCESS
1. List all files. Confirm.
2. Implement MealBuilder.
3. Migrate FernletStore call sites. Pay special attention to the side-effect
   removal — `createdRecipes` must be inserted by the caller, not the builder.
4. Add tests.
5. Run the full suite, including any existing meal-related tests in FernletTests.
6. Report results.
```

---

### Prompt PR 5 — Extract `WorkoutHealthKitSync`

```
You are extracting all HealthKit workout integration out of FernletStore. This is the
most complex Phase 1 extract (~165 lines) because it touches async authorization
flows and bidirectional sync between Fernlet's local store and HealthKit.

GOAL
Create WorkoutHealthKitSync and the WorkoutSyncContext protocol. Migrate every
HealthKit-touching workout method.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/HealthKitService.swift
  Fernlet/Fernlet/ActivityTypeCatalog.swift
  Fernlet/Fernlet/Models.swift
Create:
  Fernlet/Fernlet/WorkoutHealthKitSync.swift
  Fernlet/FernletTests/WorkoutHealthKitSyncTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/FernletTests/HealthKitWorkoutTests.swift (retarget existing tests)

CONTRACTS
@MainActor
protocol WorkoutSyncContext: AnyObject {
    var todayKey: String { get }
    func workoutExists(id: UUID) -> Bool
    func workoutExists(healthKitUUID: UUID) -> Bool
    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String)
    func upsertWorkout(_ workout: Workout, date: String)
}

@MainActor
final class WorkoutHealthKitSync {
    init(context: WorkoutSyncContext, service: any HealthKitServicing)

    func saveIfAuthorized(_ workout: Workout, date: String) async
    func refreshFromHealth() async
    func backfillIfNeeded(defaults: UserDefaults = .standard) async

    static func makeWorkout(from hk: HKWorkout) -> Workout
    static func parseFernletMetadata(_ metadata: [String: Any]?) -> WorkoutHealthKitMetadata
    static func isWorkoutLoggingAuthorized(_ snapshot: AuthorizationSnapshot) -> Bool
}

struct WorkoutHealthKitMetadata {
    let muscleGroups: Set<MuscleGroup>
    let exercises: String
    let notes: String
    let effort: Int?
    let plannedWorkoutID: UUID?
}

MOVES (from FernletStore)
- saveWorkoutToHealthIfAuthorized           → saveIfAuthorized
- updateWorkoutHealthKitUUID                → calls context.setWorkoutHealthKitUUID
- refreshWorkoutsFromHealth                 → refreshFromHealth
- backfillWorkoutsFromHealthIfNeeded        → backfillIfNeeded
- isWorkoutLoggingAuthorized                → static isWorkoutLoggingAuthorized
- reconcileWorkouts                         → private, called by refreshFromHealth/backfill
- workoutExists(id:)                        → provided by context
- workoutExists(healthKitUUID:)             → provided by context
- updateWorkoutHealthKitUUIDIfNeeded        → private (sync internal)
- static makeWorkout(from:)                 → static makeWorkout
- static parseFernletMetadata               → static parseFernletMetadata

FERNLETSTORE CONFORMANCE
extension FernletStore: WorkoutSyncContext {
    func workoutExists(id: UUID) -> Bool {
        loadDays().values.contains { $0.workouts.contains { $0.id == id } }
    }
    func workoutExists(healthKitUUID: UUID) -> Bool {
        loadDays().values.contains { $0.workouts.contains { $0.healthKitUUID == healthKitUUID } }
    }
    func setWorkoutHealthKitUUID(workoutID: UUID, hkUUID: UUID, date: String) {
        // existing logic from updateWorkoutHealthKitUUID
    }
    func upsertWorkout(_ workout: Workout, date: String) {
        addWorkout(workout, date: date)  // existing method
    }
}

FernletStore.refreshWorkoutsFromHealth becomes:
    func refreshWorkoutsFromHealth() async {
        await workoutHealthKitSync.refreshFromHealth()
    }

(Same pattern for backfillWorkoutsFromHealthIfNeeded and saveWorkoutToHealthIfAuthorized.)

INIT WIRING
FernletStore now holds:
    @ObservationIgnored private(set) lazy var workoutHealthKitSync = WorkoutHealthKitSync(
        context: self,
        service: healthKitService ?? HealthKitService()
    )

TESTS
- Retarget the existing HealthKitWorkoutTests static-helper tests to call
  WorkoutHealthKitSync.makeWorkout and WorkoutHealthKitSync.parseFernletMetadata.
- New tests in WorkoutHealthKitSyncTests using a fake WorkoutSyncContext:
  - Reconcile a new HK workout (not in context) → upsertWorkout called.
  - Reconcile an HK workout matching by fernlet.workoutID metadata → setWorkoutHealthKitUUID called.
  - Reconcile an HK workout already known by HK UUID → no-op.
  - Authorization not granted → saveIfAuthorized is a no-op (no service call).
- isWorkoutLoggingAuthorized: both .workoutType identifier and the capability raw
  value should be checked.

PROCESS
1. List files. Confirm.
2. Implement WorkoutHealthKitSync and the protocol.
3. Make FernletStore conform to WorkoutSyncContext.
4. Migrate FernletStore.addWorkout(_:date:) to call workoutHealthKitSync.saveIfAuthorized
   (after the local insert).
5. Add tests. Retarget existing tests.
6. Run the full suite. Pay attention to HealthKitWorkoutTests passing unchanged
   semantics.
```

---

### Prompt PR 6 — Extract `SnapshotSaveCoordinator`

```
You are extracting snapshot save scheduling and remote-change subscription out of
FernletStore. This affects the persistence lifecycle and must preserve current
behavior exactly.

GOAL
Create SnapshotSaveCoordinator. Move the save-debounce, remote-reload subscription,
and `performSnapshotSave` body. Keep `batchSnapshotPersistence`, `apply(_:)`, and
`reloadFromRepository` on FernletStore because they fan out across slices.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/LocalFernletRepository.swift
  Fernlet/Fernlet/CoreDataFernletRepository.swift
Create:
  Fernlet/Fernlet/SnapshotSaveCoordinator.swift
  Fernlet/FernletTests/SnapshotSaveCoordinatorTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
@MainActor
final class SnapshotSaveCoordinator {
    init(
        repository: FernletRepository,
        debounce: Duration = .seconds(1),
        buildSnapshot: @escaping @MainActor () -> FernletSnapshot,
        onAfterSave: @escaping @MainActor () -> Void
    )

    func schedule()
    func flushPending()

    /// Subscribes to CoreData remote-change notifications if the repository is a
    /// CoreDataFernletRepository. `handler` is called after a debounce; the caller
    /// should reload from the repository.
    func subscribeRemote(remoteReloadDebounce: Duration = .milliseconds(750),
                         handler: @escaping @MainActor () async -> Void)
}

MOVES (from FernletStore)
- scheduleSnapshotSave              → SnapshotSaveCoordinator.schedule
- flushPendingSnapshotSave          → SnapshotSaveCoordinator.flushPending
- performSnapshotSave               → folded into the coordinator
- subscribeToRemoteChangesIfNeeded  → SnapshotSaveCoordinator.subscribeRemote
- scheduleRemoteRepositoryReload    → coordinator-internal
- snapshotSaveTask, remoteReloadTask, cancellables → owned by coordinator

FERNLETSTORE CHANGES
Hold the coordinator:
    @ObservationIgnored private let snapshotSaveCoordinator: SnapshotSaveCoordinator

Init wires it:
    self.snapshotSaveCoordinator = SnapshotSaveCoordinator(
        repository: activeRepository,
        buildSnapshot: { [unowned self] in self.currentSnapshot() },
        onAfterSave: { [weak self] in self?.rebuildDerivedSignals() }
    )
    snapshotSaveCoordinator.subscribeRemote { [weak self] in
        await self?.reloadFromRepository()
    }

Add a small `currentSnapshot()` private method that returns the FernletSnapshot built
from current FernletStore state — the exact body that used to live in
performSnapshotSave.

Update every call site:
    scheduleSnapshotSave()  →  snapshotSaveCoordinator.schedule()
    flushPendingSnapshotSave()  →  snapshotSaveCoordinator.flushPending()

CONSTRAINTS
- Debounce interval (1 second for save, 750ms for remote reload) must match current
  values.
- `isReloadingFromRepository` re-entrancy guard stays on FernletStore — it gates
  reloadFromRepository which is still on the store.
- Combine import: should remain in SnapshotSaveCoordinator (for AnyCancellable);
  remove from FernletStore.swift if no other Combine usage remains.

TESTS
- schedule then flushPending immediately → save fires exactly once.
- schedule twice within debounce window → save fires once with the latest snapshot.
- subscribeRemote: when a fake repository's subject emits, the handler is called
  after the debounce window.

PROCESS
1. List files. Confirm.
2. Implement SnapshotSaveCoordinator.
3. Migrate FernletStore. Verify all call sites updated.
4. Add tests.
5. Run the full suite. Run FernletPersistenceTests with extra attention.
```

---

### Prompt PR 7 — Extract `BundledFoodSeedingService`

```
You are extracting bundled USDA food-item seeding into its own service.

GOAL
Create BundledFoodSeedingService. Move the seeding state machine and bundled-load
Task. Keep the launch-screen-pending-save dance on FernletStore.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/FoodDataCatalog.swift
Create:
  Fernlet/Fernlet/BundledFoodSeedingService.swift
  Fernlet/FernletTests/BundledFoodSeedingServiceTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
@MainActor
@Observable
final class BundledFoodSeedingService {
    enum State { case notStarted, seeding, done, failed }

    private(set) var state: State = .notStarted

    /// Returns the items that were newly added (not present in `existing`).
    /// State transitions: notStarted → seeding → done (or failed).
    /// Calling again after .done is a no-op returning [].
    func ensureSeeded(existing existingFoodItems: [FoodItem]) async -> [FoodItem]
}

FERNLETSTORE CHANGES
The current `bundledFoodSeedingState` published property becomes a forwarding read:
    var bundledFoodSeedingState: BundledFoodSeedingService.State {
        bundledFoodSeedingService.state
    }

Note: keep the enum case names compatible — HomeView reads this. Or rename the
nested type to match FernletStore.SeedingState exactly so HomeView is unchanged.
Choose the option that requires zero changes outside FernletStore.

FernletStore.ensureBundledFoodItemsSeeded becomes:
    func ensureBundledFoodItemsSeeded() {
        guard bundledFoodSeedingService.state == .notStarted else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let newItems = await self.bundledFoodSeedingService.ensureSeeded(
                existing: self.foodItems
            )
            if !newItems.isEmpty {
                self.foodItems.append(contentsOf: newItems)
                self.queueBundledFoodSeedSaveAfterLaunch()
            }
        }
    }

TESTS
- First call: state goes seeding → done, returned items match bundled set minus
  existing.
- Second call after done: returns [], state stays done.
- Empty bundled items: state → done, returns [].

PROCESS as in PR 1.
```

---

### Prompt PR 8 — Optional `DayMutator` extension

```
You are reducing duplication around the today/past-day branching in FernletStore.

GOAL
Add a `mutateDay(date:_:)` extension method on FernletStore that hides the today/past
branching. Migrate every call site of mutatePastDay that does the today/past pattern.

SCOPE
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
extension FernletStore {
    /// Mutates the day for the given dateKey. If the dateKey is todayKey, mutates
    /// `day` and schedules a save. Otherwise round-trips through the repository.
    @discardableResult
    func mutateDay(date: String, _ change: (inout FernletDay) -> Void) -> Bool {
        assert(!date.isEmpty, "date key required")
        if date == todayKey {
            change(&day)
            scheduleSnapshotSave()
            return true
        }
        return mutatePastDay(date, change)
    }
}

CALL-SITE MIGRATIONS
Find every method that follows this pattern:
    if date == todayKey {
        day.foo.append(x)
    } else {
        mutatePastDay(date) { $0.foo.append(x) }
    }
Replace with:
    mutateDay(date: date) { $0.foo.append(x) }

There are approximately 8 call sites: appendMeal, logRecipe, logSavedRecipe, addWorkout,
addJournal(text:tag:date:), updateJournal, deleteJournal, setSleep(...date:),
setBottleCount, setPersonalCareTaskIDs.

CONSTRAINTS
- batchSnapshotPersistence wraps several of these. Make sure the mutateDay call
  still happens inside batchSnapshotPersistence where applicable, so the save
  scheduling is not duplicated.
- mutatePastDay stays available for callers that need its specific return semantics.

TESTS
- Existing tests should pass unchanged.
- Optional: add a smoke test that mutates today and past via mutateDay and asserts
  both paths persist correctly.

PROCESS
1. Identify all call sites. List them.
2. Add the extension.
3. Migrate call sites one block at a time, verifying compilation after each.
4. Run the full suite.
```

---

### Prompt PR 9 — Extract `SavedRecipeService`

```
You are extracting saved-recipe state and behavior out of FernletStore into its own
@Observable service. This is the first Phase 2 extract.

GOAL
Create SavedRecipeService. Move savedRecipes, savedRecipeRepository, and the
save-debounce out of FernletStore. Keep FernletStore's public surface unchanged
via forwarding properties.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/SavedRecipe.swift
  Fernlet/Fernlet/FoodView.swift  (verify surface usage)
Create:
  Fernlet/Fernlet/SavedRecipeService.swift
  Fernlet/FernletTests/SavedRecipeServiceTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
@MainActor
@Observable
final class SavedRecipeService {
    private(set) var savedRecipes: [SavedRecipe] = []

    @ObservationIgnored private let repository: SavedRecipeRepository
    @ObservationIgnored private var saveScheduled = false

    init(repository: SavedRecipeRepository = SavedRecipeRepository())

    func loadAsync() async
    func loadSync()
    func add(_ recipe: SavedRecipe)
    func update(_ recipe: SavedRecipe)
    func delete(_ recipe: SavedRecipe)
    func reset()
    func shareText(for recipe: SavedRecipe) -> String

    /// Pure Meal construction. Does not mutate any day.
    static func makeMeal(from recipe: SavedRecipe, mealType: MealType?) -> Meal

    private func scheduleSave()
}

DEBOUNCE BEHAVIOR
- saveScheduled flag prevents multiple Task launches.
- The save Task awaits one MainActor turn (matches current behavior) and then calls
  repository.save(savedRecipes).

ADD BEHAVIOR
- add(_ recipe:) removes any existing entry with the same sourceURLString, then
  inserts at index 0. (Matches current addSavedRecipe.)

FERNLETSTORE CHANGES
Hold the service:
    @ObservationIgnored let savedRecipeService: SavedRecipeService

Replace the savedRecipes published property with a forwarding read:
    var savedRecipes: [SavedRecipe] { savedRecipeService.savedRecipes }

Forwarding methods:
    func addSavedRecipe(_ r: SavedRecipe) { savedRecipeService.add(r) }
    func updateSavedRecipe(_ r: SavedRecipe) { savedRecipeService.update(r) }
    func deleteSavedRecipe(_ r: SavedRecipe) { savedRecipeService.delete(r) }
    func savedRecipeShareText(for r: SavedRecipe) -> String {
        savedRecipeService.shareText(for: r)
    }

    @discardableResult
    func logSavedRecipe(_ recipe: SavedRecipe, mealType: MealType? = nil,
                        date: String? = nil) -> Meal {
        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: mealType)
        appendMeal(meal, date: date ?? todayKey)
        return meal
    }

Init: construct savedRecipeService alongside repository. Both FernletStore inits
load saved recipes via the service. The async `load(date:repository:statusUpdate:)`
factory calls `await savedRecipeService.loadAsync()`.

Reset: resetAll calls savedRecipeService.reset() instead of clearing savedRecipes
locally.

Remove from FernletStore:
- @Published var savedRecipes
- private let savedRecipeRepository
- private var savedRecipeSaveScheduled
- scheduleSavedRecipeSave (replaced by service-internal)

TESTS
- add: inserts at 0, dedup by sourceURLString.
- update: no-op if id not found; in-place replacement otherwise.
- delete: removes by id.
- makeMeal: with macros (hasMacros=true) → confidence "Recipe", note "Logged from
  URL recipe."
- makeMeal: zero macros → confidence "Recipe (no macros)", note includes "Macros not
  available."
- makeMeal: mealType nil → falls back to MealParser.classifyMealType.
- Persistence round-trip: add, allow save scheduler to run, reload via a new
  service instance, confirm equality.

VERIFY
After this PR, FoodView.swift compiles unchanged. The references like
`store.savedRecipes`, `store.addSavedRecipe`, etc. still work through forwarding.

PROCESS
1. List files. Confirm.
2. Implement SavedRecipeService.
3. Migrate FernletStore. Make sure both inits and reset are updated.
4. Add tests.
5. Run the full suite. Pay extra attention to FernletPersistenceTests if it covers
   saved recipes.
```

---

### Prompt PR 10 — Extract `ProximityTrustVault`

```
You are extracting trusted-peer state and trainer audit logging into a dedicated
@Observable type. FernletStore's conformance to ProximityTrustPolicy stays in place
but forwards into the vault.

GOAL
Create ProximityTrustVault. Move trustedProximityPeers, trainerAuditEvents, and all
related read/write methods. Preserve FernletStore's public surface and its
ProximityTrustPolicy conformance.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/Models.swift
  Fernlet/Fernlet/TrainerAuditLog.swift
  Fernlet/Fernlet/ProximityCoordinator.swift
  Fernlet/Fernlet/IdentityService.swift
  Fernlet/Fernlet/TrainerProximityService.swift  (caller; verify it works unchanged)
  Fernlet/Fernlet/FriendPhotoShareView.swift     (caller; verify it works unchanged)
Create:
  Fernlet/Fernlet/ProximityTrustVault.swift
  Fernlet/FernletTests/ProximityTrustVaultTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
@MainActor
@Observable
final class ProximityTrustVault: ProximityTrustPolicy {
    private(set) var trustedPeers: [ProximityTrustedPeerRecord] = []
    private(set) var auditEvents: [TrainerAuditEvent] = []

    @ObservationIgnored private let onChange: @MainActor () -> Void

    init(
        initialPeers: [ProximityTrustedPeerRecord] = [],
        initialAudit: [TrainerAuditEvent] = [],
        onChange: @escaping @MainActor () -> Void
    )

    // Reads
    func peer(fingerprint: String) -> ProximityTrustedPeerRecord?
    func peer(displayName: String) -> ProximityTrustedPeerRecord?
    func isTrustedProximityPeer(fingerprint: String) -> Bool
    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool

    // Writes — each calls onChange exactly once at the end
    func trust(_ peer: ProximityCoordinator.PeerIdentity,
               mode: ProximityCoordinator.Mode)
    func revoke(fingerprint: String)   // also records a trainerRevoked audit event
    func recordTrainerAudit(_ event: TrainerAuditEvent)

    // Snapshot in/out
    func apply(peers: [ProximityTrustedPeerRecord],
               audit: [TrainerAuditEvent])

    private func recordAuditWithoutSaving(_ event: TrainerAuditEvent)
}

BEHAVIOR
- trust idempotency: existing peer with same fingerprint is updated (displayName,
  keyAgreementPublicKey, mode, lastSeenAt, revokedAt=nil); otherwise append a new
  record.
- revoke: sets revokedAt on the matching record and writes a .trainerRevoked
  TrainerAuditEvent in the same operation.
- auditEvents cap: keep most recent 500.
- peer(displayName:) returns the most recently seen match.

FERNLETSTORE CHANGES
Hold the vault:
    @ObservationIgnored let proximityTrustVault: ProximityTrustVault

Init wires it:
    self.proximityTrustVault = ProximityTrustVault(
        initialPeers: snapshot.trustedProximityPeers,
        initialAudit: snapshot.trainerAuditEvents,
        onChange: { [weak self] in self?.scheduleSnapshotSave() }
    )

Replace the published properties with forwarding reads:
    var trustedProximityPeers: [ProximityTrustedPeerRecord] {
        proximityTrustVault.trustedPeers
    }
    var trainerAuditEvents: [TrainerAuditEvent] {
        proximityTrustVault.auditEvents
    }

Forwarding methods:
    func trustedProximityPeer(fingerprint: String) -> ProximityTrustedPeerRecord? {
        proximityTrustVault.peer(fingerprint: fingerprint)
    }
    func trustedProximityPeer(displayName: String) -> ProximityTrustedPeerRecord? {
        proximityTrustVault.peer(displayName: displayName)
    }
    func trustProximityPeer(_ peer: ProximityCoordinator.PeerIdentity,
                            mode: ProximityCoordinator.Mode) {
        proximityTrustVault.trust(peer, mode: mode)
    }
    func revokeTrustedProximityPeer(fingerprint: String) {
        proximityTrustVault.revoke(fingerprint: fingerprint)
    }
    func recordTrainerAudit(_ event: TrainerAuditEvent) {
        proximityTrustVault.recordTrainerAudit(event)
    }

    // ProximityTrustPolicy conformance forwards too:
    func isTrustedProximityPeer(fingerprint: String) -> Bool {
        proximityTrustVault.isTrustedProximityPeer(fingerprint: fingerprint)
    }
    func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        proximityTrustVault.isRevokedProximitySigningKey(publicKey)
    }

`extension FernletStore: ProximityTrustPolicy {}` stays as-is.

SNAPSHOT WIRING
- FernletStore.apply(_ snapshot:) calls
  proximityTrustVault.apply(peers: snapshot.trustedProximityPeers,
                            audit: snapshot.trainerAuditEvents).
- The performSnapshotSave / currentSnapshot path reads trustedPeers and auditEvents
  from the vault.
- resetAll calls proximityTrustVault.apply(peers: [], audit: []).

REMOVE FROM FERNLETSTORE
- @Published var trustedProximityPeers
- @Published var trainerAuditEvents
- recordTrainerAuditWithoutSaving (now private inside the vault)
- The trust/revoke body methods (now forwards)

TESTS
- trust idempotency by fingerprint: trust the same peer twice with updated
  displayName, assert single record with new name.
- revoke writes a .trainerRevoked audit event; revoke twice in a row writes two
  events.
- isTrustedProximityPeer: true only when revokedAt == nil.
- isRevokedProximitySigningKey: true only when a matching fingerprint record has
  revokedAt != nil.
- auditEvents ring buffer: record 502 events, assert count == 500 and the most
  recent two are present.
- onChange is called exactly once per mutating operation.
- apply replaces both arrays atomically.

PROCESS
1. List files. Confirm.
2. Implement ProximityTrustVault.
3. Migrate FernletStore (init, forwarding properties, snapshot wiring, reset).
4. Verify TrainerProximityService and FriendPhotoShareView still compile unchanged.
5. Add tests.
6. Run the full suite, including any proximity tests.
```

---

### Prompt PR 11 — Extract `AIRetryQueueService`

```
You are extracting the AI retry queue into its own @Observable service. The AI
surface in Fernlet is expected to grow; this service is positioned to absorb
future retry kinds.

GOAL
Create AIRetryQueueService. Move retryQueue and its operations. Preserve
FernletStore's public surface.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/Models.swift
  Fernlet/Fernlet/Scoring.swift
Create:
  Fernlet/Fernlet/AIRetryQueueService.swift
  Fernlet/FernletTests/AIRetryQueueServiceTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
@MainActor
@Observable
final class AIRetryQueueService {
    private(set) var retryQueue: [AIAnalysisRetryRecord] = []

    @ObservationIgnored private let onChange: @MainActor () -> Void

    init(initial: [AIAnalysisRetryRecord] = [],
         onChange: @escaping @MainActor () -> Void)

    var pendingCount: Int { retryQueue.count }

    /// Queue a meal-analysis retry. New retry kinds (workout, recipe, daily-summary)
    /// should be added as new methods, not by overloading this one. The underlying
    /// AIAnalysisRetryRecord.payloadType remains the dispatch key.
    func queueMealRetry(_ meal: Meal)

    func clear(id: UUID)
    func apply(_ queue: [AIAnalysisRetryRecord])
    func reset()
}

FERNLETSTORE CHANGES
Hold the service:
    @ObservationIgnored let aiRetryQueueService: AIRetryQueueService

Init wires it:
    self.aiRetryQueueService = AIRetryQueueService(
        initial: snapshot.retryQueue,
        onChange: { [weak self] in self?.scheduleSnapshotSave() }
    )

Replace the published property:
    var retryQueue: [AIAnalysisRetryRecord] { aiRetryQueueService.retryQueue }
    var pendingRetryCount: Int { aiRetryQueueService.pendingCount }

Forwarding methods:
    func queueMealRetry(_ meal: Meal) { aiRetryQueueService.queueMealRetry(meal) }
    func clearRetryItem(_ id: UUID) { aiRetryQueueService.clear(id: id) }

Snapshot wiring:
    - apply(_ snapshot:) calls aiRetryQueueService.apply(snapshot.retryQueue)
    - currentSnapshot reads aiRetryQueueService.retryQueue
    - resetAll calls aiRetryQueueService.reset()

REMOVE FROM FERNLETSTORE
- @Published var retryQueue
- queueMealRetry body (now a forward)
- clearRetryItem body (now a forward)

TESTS
- queueMealRetry appends a record with payloadType "meal" and sourceId == meal.id.
- clear by id removes the matching record; clear with unknown id is a no-op.
- onChange called exactly once per mutation.
- apply replaces the queue atomically.
- reset clears the queue.

PROCESS as in PR 9.
```

---

### Prompt PR 12 — Extract `DerivedSignalsService`

```
You are extracting the derived-signals state into its own @Observable service that
wraps the pure DerivedSignalsRebuilder (created in PR 3).

GOAL
Create DerivedSignalsService. Move derivedSignals state. Preserve FernletStore's
public surface and timing semantics.

SCOPE
Read-only:
  Fernlet/Fernlet/FernletStore.swift
  Fernlet/Fernlet/DerivedSignalsRebuilder.swift  (from PR 3)
  Fernlet/Fernlet/LocalFernletRepository.swift
Create:
  Fernlet/Fernlet/DerivedSignalsService.swift
  Fernlet/FernletTests/DerivedSignalsServiceTests.swift
Modify:
  Fernlet/Fernlet/FernletStore.swift

CONTRACT
@MainActor
@Observable
final class DerivedSignalsService {
    private(set) var derivedSignals: [DerivedSignalRecord] = []

    @ObservationIgnored private var deferredStarted = false

    func rebuild(allDays: [String: FernletDay], todayKey: String)

    /// Mirrors FernletStore.deferredPostLaunchTasks: schedules a low-priority
    /// rebuild after the first run.
    func scheduleDeferredRebuild(
        allDaysProvider: @escaping @MainActor () -> [String: FernletDay],
        todayKey: String
    )
}

IMPLEMENTATION NOTE
rebuild wraps the Rebuilder:
    func rebuild(allDays: [String: FernletDay], todayKey: String) {
        StartupTiming.timed("FernletStore.rebuildDerivedSignals") {
            derivedSignals = DerivedSignalsRebuilder.rebuild(
                allDays: allDays, todayKey: todayKey
            )
        }
    }

(The StartupTiming label can stay as-is for log-continuity, or change to
"DerivedSignalsService.rebuild" — leave it for now and flag the choice.)

FERNLETSTORE CHANGES
Hold the service:
    @ObservationIgnored let derivedSignalsService = DerivedSignalsService()

Replace the published property:
    var derivedSignals: [DerivedSignalRecord] { derivedSignalsService.derivedSignals }

The internal rebuildDerivedSignals helper becomes:
    private func rebuildDerivedSignals() {
        derivedSignalsService.rebuild(allDays: loadDays(), todayKey: todayKey)
    }

deferredPostLaunchTasks forwards:
    func deferredPostLaunchTasks() {
        derivedSignalsService.scheduleDeferredRebuild(
            allDaysProvider: { [weak self] in self?.loadDays() ?? [:] },
            todayKey: todayKey
        )
    }

REMOVE FROM FERNLETSTORE
- @Published private(set) var derivedSignals
- private var deferredPostLaunchTasksStarted (now lives in the service)

TESTS
- rebuild produces signals identical to a direct DerivedSignalsRebuilder.rebuild call.
- scheduleDeferredRebuild runs exactly once even if called twice.
- The service's derivedSignals property is updated on the main actor.

PROCESS as in PR 9.
```

---

### Prompt PR 13 — Update documentation

```
You are updating Fernlet's documentation to reflect the FernletStore refactor.

GOAL
Update FileIndex.md and add a brief architectural note documenting the
sub-service composition pattern.

SCOPE
Modify:
  Fernlet/Docs/FileIndex.md
Optional create:
  Fernlet/Docs/StoreArchitecture.md  (new — short overview)

FILEINDEX UPDATES
Add new files under appropriate sections:
- Under "Data, Persistence, And State":
    SnapshotSaveCoordinator.swift, DerivedSignalsRebuilder.swift, DayMutator.swift,
    SavedRecipeService.swift, ProximityTrustVault.swift, AIRetryQueueService.swift,
    DerivedSignalsService.swift, BundledFoodSeedingService.swift
- Under "Food, Nutrition, And Recipe Services":
    MealBuilder.swift, RecipeShareCodec.swift, CustomIngredientUpsert.swift
- Under "Health And Launch Services":
    WorkoutHealthKitSync.swift

Update the FernletStore.swift row to reflect its slimmer, coordinator-focused role.

STOREARCHITECTURE.MD (if added)
A 1–2 page note covering:
- Why @Observable is used (replacing ObservableObject).
- The composition pattern: FernletStore as the view-facing observable that composes
  several focused @Observable sub-services.
- The forwarding-property pattern and why no manual signaling is needed under the
  Observation framework.
- Where to add new state: a decision flowchart (is it persistent? does it forward?
  does anything outside the store consume it?).

PROCESS
1. List the changes you intend to make.
2. Apply them.
3. Confirm FileIndex.md still validates as a clean markdown table.
```

---

## 12. Optional Future / Deferred Work

All previously open items are resolved. The items below are intentionally deferred so this refactor stays a low-risk store decomposition instead of becoming a full architecture rewrite.

### 12.1 Additional Store Slices

These are explicitly **not** in this plan. Reconsider them only after the `FernletSnapshot` schema refactor clarifies persistence boundaries:

- **`DailyHealthScoreStore` / `DailyScoreService`** — could own `dailyScores`, `storeDaySummary`, `invalidateDaySummary`, and score cache mutation. Defer because scoring still reads broad store context through `Scoring.compute(for:)`.
- **`MemoryStore` / `MemoryService`** — could own `memories`, Tier 2 summaries, deletion, and update logic. Defer until the Memory Agent and sealed-memory boundary are designed; otherwise the service would likely be reshaped immediately.
- **`RecipeStore`** — could own local `RecipeDefinition` CRUD separate from SwiftData-backed `SavedRecipeService`. Defer until the local recipe builder and URL-imported saved recipe flow are reconciled.
- **`FoodItemStore`** — could own `foodItems`, bundled seeding, custom ingredient upserts, and catalog mutation. Defer until the food catalog cache / per-100 g data refactor lands; the data model is still moving.
- **`JournalService`** — could own `previousJournals` and journal mutation. Defer until journal text/emotion sealing is expanded, because persistence and encryption shape the service boundary.
- **`SettingsService`** — could own user settings, privacy toggles, quick-log items, and connection-inspector mode. Defer until Settings IA settles; today's settings fields are small and view-facing forwarding would add more indirection than value.

### 12.2 Value Context Refactors

- **`DailyScoreContext` for scoring.** Keep `Scoring.compute(for: FernletStore)` unchanged in this plan. A future refactor can introduce a value-type context containing only the fields scoring needs, which would reduce coupling and make score tests easier to set up.
- **`LaunchPreparationContext`.** `LaunchPreparationService` still reads broad store state. After the Memory Agent / AI payload boundary work, consider passing a narrowed launch context instead of the full store.
- **`SnapshotSaveContext`.** `SnapshotSaveCoordinator` can remain a behavior class for now. If snapshot assembly grows, move `currentSnapshot` construction into a small value builder so save coordination does not need to know every persisted field.

### 12.3 Persistence And Repository Boundaries

- **Feature-area repository protocols.** `FernletRepository` remains broad. After the snapshot refactor, split only where a real storage backend or test boundary benefits: recipes, journal, period/private data, proximity trust, and derived records are likely candidates.
- **`FernletSnapshot` schema split.** This plan does not split the snapshot blob. A later schema plan can decide whether settings, food catalog state, private sealed data, and proximity trust should have separate records/stores.
- **Core Data / CloudKit alignment.** Keep repository and CloudKit transport out of this refactor. The right time to revisit them is the storage-schema pass, not while slimming `FernletStore`.

### 12.4 Cleanup Candidates After Refactor

- **Workshop data removal.** Workshop UI is no longer a primary surface, but `WorkshopData` still round-trips through snapshots. If product confirms it is retired, remove the store property and snapshot field in a deliberate compatibility pass.
- **Trainer naming cleanup.** `TrainerAuditEvent` and `TrainerAuditLog.swift` are really proximity trust/audit infrastructure. Rename only after proximity work is stable, because it touches persistence-facing names and many references.
- **File renames for extracted services.** Once the refactor is fully landed, align filenames and docs around actual roles (`FriendPhotoPayloads`, `ProximityTrustLog`, etc.) in a separate no-behavior cleanup.
- **Observation audit.** After all slices are extracted, audit `@ObservationIgnored` usage and remove stale Combine imports. This is mechanical cleanup, not a prerequisite for the refactor.

### 12.5 Test Hardening To Add Later

- Snapshot round-trip tests that assert service-owned slices still persist through `FernletStore.currentSnapshot`.
- Focused mutation tests for forwarded APIs, especially where a forwarding method also triggers save scheduling.
- Regression tests for `Scoring.compute(for:)` before introducing `DailyScoreContext`.
- A small observation smoke test for service forwarding if UI invalidation regressions appear in practice.

---

## 13. What This Plan Does Not Address

- `FernletRepository` protocol, Core Data model, or CloudKit transport — handled by the upcoming FernletSnapshot refactor.
- `FernletSnapshot` shape or schema — same.
- Lock service crypto.
- Period tracker internals (only the `@Observable` macro changes apply to `PeriodTrackerStore`).
- Mesh implementation — your next workstream.
- View hierarchy.
