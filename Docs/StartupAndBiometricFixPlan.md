# Startup Slowness + Biometric Lock Loop — Implementation Plan

This plan addresses two production issues:

1. **App launch takes 15+ seconds** before any UI appears.
2. **Face ID unlock loops** — the scanner runs but the app makes no progress.

Codex's high‑level diagnosis is correct: both symptoms share a root cause — `FernletStore.init()` does heavy synchronous work on the main actor before SwiftUI can render the first frame. The biometric loop is a downstream consequence (plus a latent bug in `FernletLockView`'s auto‑trigger that should be hardened anyway).

The plan is staged so each step can be verified independently and shipped on its own if needed.

---

## 1. Where time is being spent today

`FernletApp.swift` declares the store as a `@StateObject`:

```swift
@StateObject private var store = FernletStore()
```

SwiftUI evaluates the `@StateObject` autoclosure synchronously the first time `WindowGroup` builds its content. That happens **before the first frame is committed**, so every microsecond inside `FernletStore.init` is dead time on a blank screen.

`FernletStore.init` (FernletStore.swift, ~line 31) does, in order, all on `@MainActor`:

| Step | What it does | Cost |
| --- | --- | --- |
| `CoreDataFernletRepository()` | Subscribes to remote-change publisher; lazy except… | Light, BUT… |
| `…transitively touches PersistenceController.shared` | First access spins up `NSPersistentCloudKitContainer` and calls `loadPersistentStores` synchronously, with `FileProtectionType.complete`, history tracking, and migration checks. | Heavy on cold launch |
| `SavedRecipeRepository()` | Light constructor | Negligible |
| `activeRepository.loadSnapshot(todayKey:)` | CoreData fetch + **full JSON decode of the `payloadData` blob** containing every `FernletDay`, meal, recipe, signal, score, etc. | Heavy and grows with user data |
| `savedRecipeRepository.load()` | CoreData fetch of every `SavedRecipeRecord` + legacy JSON fallback | Medium |
| `seedBundledFoodItems()` | `Bundle.main` read of `USDAFoodItems.json` + decode of entire array into `[FoodItem]` + dedup vs existing + `scheduleSnapshotSave()` | Heavy (bundled file is large) |
| `rebuildDerivedSignals()` | Calls `loadDays()` → `repository.loadAllDays()` which **re‑decodes the entire database again**, then computes signals from the last N days | Heavy (≈double the snapshot work) |

So the user stares at a blank window while the main actor: opens a CloudKit-aware Core Data stack, JSON-decodes the entire database **twice**, JSON-decodes the bundled USDA catalog, merges/dedups food items, and queues a CoreData save.

The biometric loop has its own latent issues in `FernletLockView` (see §6), but the main thread being unresponsive for >10s also reliably stalls system Face ID UI: the keychain query runs on a background queue, but the system prompt's animation and lifecycle callbacks (`scenePhase` transitions, `protectedDataWillBecomeUnavailable`, etc.) are processed on the main actor that is currently busy decoding JSON. The result the user describes — "scanner runs, nothing happens behind it" — is consistent with that picture.

---

## 2. Goals and non‑goals

**Goals**

- LaunchScreen visible **and animating** within ~200ms of cold launch.
- Total time from cold launch → interactive `ContentView` (or onboarding) reduced to <3s on typical hardware, with most of that time being the existing minimum LaunchScreen display window (1.4s in `LaunchPreparationService.prepare`).
- Face ID auto‑prompt fires at most once per lock screen presentation, with errors surfaced to the user and no silent loops.
- No regression in: onboarding gating, lock state restoration on relaunch, CoreData migration from legacy JSON, iCloud sync activation, scenePhase relock behavior.

**Non‑goals**

- Rewriting the Core Data schema or breaking up `LocalFernletDatabase` into per-day rows. (Worth doing later; out of scope here.)
- Changing what the `LaunchPreparationService` does. We keep its current behavior — we just stop forcing a load *before* it gets a chance to run.

---

## 3. Phase 0 — Add timing instrumentation (do first, keep it in)

Before any restructuring, add timings so we can see what each step costs on each device and confirm fixes. Use `os_signpost` so the data shows up in Instruments without log noise in Release builds.

In `FernletStore.swift`, add a small helper and bracket the existing init phases:

```swift
import os.signpost

private let startupLog = OSLog(subsystem: "com.fernlet", category: "startup")

@discardableResult
private func timed<T>(_ label: StaticString, _ work: () throws -> T) rethrows -> T {
    let id = OSSignpostID(log: startupLog)
    os_signpost(.begin, log: startupLog, name: label, signpostID: id)
    defer { os_signpost(.end, log: startupLog, name: label, signpostID: id) }
    let start = CFAbsoluteTimeGetCurrent()
    let result = try work()
    let ms = (CFAbsoluteTimeGetCurrent() - start) * 1000
    #if DEBUG
    print(String(format: "[startup] %@ took %.1f ms", "\(label)", ms))
    #endif
    return result
}
```

Wrap each phase: `FernletStore.init`, `CoreDataFernletRepository.loadSnapshot` (and its internal `loadDatabase` decode), `SavedRecipeRepository.load`, `FoodDataCatalog.bundledFoodItems`, `FernletStore.seedBundledFoodItems`, `FernletStore.rebuildDerivedSignals`, and `PersistenceController.init`'s `loadPersistentStores` callback.

Also add one outer signpost in `FernletApp.init` and end it in `LaunchPreparationService.prepare` when `isDone = true`, so we can see total wall-clock launch time per build.

Why now: phases 1–5 below will move these costs around. Without timings we won't know which one of them is the actual culprit on a given device, and we will not be able to prove the regression budget after the refactor.

---

## 4. Phase 1 — `FernletApp` owns no store at first frame

Goal: render `LaunchScreen` immediately. Build the store after the first frame.

### 4.1 Introduce a loader object

New file `FernletStoreLoader.swift`:

```swift
import SwiftUI

@MainActor
final class FernletStoreLoader: ObservableObject {
    enum Phase {
        case preparing
        case ready(FernletStore)
        case failed(Error)
    }

    @Published private(set) var phase: Phase = .preparing
    @Published private(set) var statusMessage: String = LaunchPreparationService.initialStatusMessage

    private var didStart = false

    func startIfNeeded() async {
        guard !didStart else { return }
        didStart = true
        do {
            let store = try await FernletStore.load { [weak self] message in
                Task { @MainActor in self?.statusMessage = message }
            }
            phase = .ready(store)
        } catch {
            phase = .failed(error)
        }
    }
}
```

The closure parameter lets `FernletStore.load` update the LaunchScreen status text as it progresses (`"Loading your records…"`, `"Catching up…"`, etc.). This is a nicety; it can be stubbed to `{ _ in }` in the first cut.

### 4.2 Rewrite `FernletApp.body`

Replace the current top-level branch with a phase switch driven by the loader. Importantly, **declare no `@StateObject store` here at all** — the store lives inside `FernletStoreLoader.Phase.ready`.

```swift
@main
struct FernletApp: App {
    @StateObject private var lockService = FernletLockService()
    @StateObject private var storagePreferencesStore = StoragePreferencesStore()
    @StateObject private var loader = FernletStoreLoader()
    @AppStorage(OnboardingDefaults.hasCompletedOnboardingKey) private var hasCompletedOnboarding = false
    @State private var didScheduleStartupCloudSync = false
    @Environment(\.scenePhase) private var scenePhase

    init() { /* existing reset-onboarding and UIAppearance code stays */ }

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.parchment.ignoresSafeArea()
                content
            }
            .task { await loader.startIfNeeded() }
            .onChange(of: scenePhase) { /* unchanged */ }
            #if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(
                for: UIApplication.protectedDataWillBecomeUnavailableNotification)
            ) { _ in lockService.lock(reason: .protectedDataUnavailable) }
            #endif
            // existing iCloud reload + activate cloud sync taskmodifiers move
            // INSIDE the .ready branch (so they only run with a real store)
        }
    }

    @ViewBuilder
    private var content: some View {
        switch loader.phase {
        case .preparing:
            LaunchScreen(statusMessage: loader.statusMessage)
                .transition(.opacity)
        case .ready(let store):
            readyContent(store: store)
                .transition(.opacity)
        case .failed(let error):
            LaunchFailureView(error: error) {
                Task { await loader.retry() } // add a retry() on the loader
            }
        }
    }
}
```

### 4.3 Why this alone helps

Even without changing `FernletStore.init` internals yet, this change has a real effect:

- The `@StateObject` autoclosure no longer runs synchronously before the first frame, because the autoclosure is now `FernletStoreLoader()` which is cheap.
- `await loader.startIfNeeded()` runs in a `Task` attached to a `.task` modifier, which fires **after the first frame is presented**.
- The LaunchScreen animations (the `TimelineView` pulse + the dot wave) actually animate now, because the main runloop has time to step them.

### 4.4 What to verify

- Cold launch shows LaunchScreen with smooth pulse/dot animation immediately.
- After loader transitions to `.ready`, the existing `ContentView` / `OnboardingCoordinator` branch behaves exactly as before.
- The `FERNLET_UI_TEST_OPEN_PRIVACY_DATA` test hook still works. That branch doesn't need a store at all — leave it as a fourth case in the switch, gated by env var, that bypasses the loader.

### 4.5 Move the iCloud sync activation task into `readyContent`

`activateCloudSyncAfterStartupIfNeeded` and `reloadPersistenceForPreferenceChange` should only run when there is a store to react to. Move both modifiers (`.onChange(storagePreferencesStore.preferences)`, the cloud sync `.task`) inside `readyContent`, not on the outer ZStack. This keeps them off the launch path and removes the 5-second delayed task from firing while the loader is still working.

---

## 5. Phase 2 — `FernletStore.load()` async factory

Goal: the work that used to be in `FernletStore.init` runs off the main actor wherever possible, and on the main actor in small chunks where it isn't.

### 5.1 Split the work

`FernletStore.init` currently does six things. We want them in three buckets:

| Work | Where to run | When |
| --- | --- | --- |
| `CoreDataFernletRepository` construction (lightweight subscribe) | Main actor | During `load()` |
| `PersistenceController.shared` first access (loadPersistentStores) | **Pre-warm in background** | Kicked off from `FernletStoreLoader.startIfNeeded()` immediately, awaited by `load()` |
| Fetch `payloadData` blob from CoreData | Main actor (it's the viewContext) | During `load()` |
| **JSON-decode `LocalFernletDatabase` from payloadData** | **Background task** | During `load()` |
| `SavedRecipeRepository.load()` | Main actor fetch + background decode of records | During `load()` |
| `FoodDataCatalog.bundledFoodItems()` (USDA JSON decode) | **Background task** | **Deferred (Phase 3)** — not part of `load()` |
| `rebuildDerivedSignals()` | **Background task** | **Deferred (Phase 4)** — not part of `load()` |
| Initial `scheduleSnapshotSave` from seeding | Skipped | See Phase 5 |

### 5.2 The factory

In `FernletStore.swift`:

```swift
extension FernletStore {
    static func load(
        date: Date = .now,
        repository: FernletRepository? = nil,
        statusUpdate: @MainActor @escaping (String) -> Void = { _ in }
    ) async throws -> FernletStore {
        let todayKey = FernletDate.dayKey(for: date)
        assert(!todayKey.isEmpty, "today key required")

        statusUpdate("Opening your records…")
        // Force PersistenceController.shared to initialize off the main runloop
        // (it's still main-actor, but moving it inside an awaited Task lets the
        // first frame paint before we block on loadPersistentStores).
        await Task.yield()

        let activeRepository: FernletRepository = await MainActor.run {
            repository ?? CoreDataFernletRepository()
        }
        let savedRecipeRepository = await MainActor.run { SavedRecipeRepository() }

        statusUpdate("Reading recent days…")
        // Snapshot load. The JSON decode inside loadSnapshot is the hot path —
        // see §5.3 for the split inside CoreDataFernletRepository.
        let snapshot = await activeRepository.loadSnapshotAsync(todayKey: todayKey)
        let savedRecipes = await savedRecipeRepository.loadAsync()

        let store = await MainActor.run {
            FernletStore(
                snapshot: snapshot,
                savedRecipes: savedRecipes,
                todayKey: todayKey,
                repository: activeRepository,
                savedRecipeRepository: savedRecipeRepository
            )
        }
        return store
    }
}
```

A new "consumes a prebuilt snapshot" private initializer replaces today's heavy public `init`:

```swift
@MainActor
private init(
    snapshot: FernletSnapshot,
    savedRecipes: [SavedRecipe],
    todayKey: String,
    repository: FernletRepository,
    savedRecipeRepository: SavedRecipeRepository
) {
    self.todayKey = todayKey
    self.repository = repository
    self.savedRecipeRepository = savedRecipeRepository
    self.day = snapshot.day
    self.settings = snapshot.settings
    self.recentMeals = snapshot.recentMeals
    self.previousJournals = snapshot.previousJournals
    self.memories = snapshot.memories
    self.goals = snapshot.goals
    self.workshop = snapshot.workshop
    self.retryQueue = snapshot.retryQueue
    self.foodItems = snapshot.foodItems
    self.recipes = snapshot.recipes
    self.dailyScores = snapshot.dailyScores
    self.savedRecipes = savedRecipes
    // NB: seedBundledFoodItems() and rebuildDerivedSignals() are NOT called here.
    // They are kicked off by deferredPostLaunchTasks() — see Phase 3 & 4.
    if let coreDataRepo = repository as? CoreDataFernletRepository {
        coreDataRepo.remoteChangeSubject
            .sink { [weak self] in self?.reloadFromRepository() }
            .store(in: &cancellables)
    }
}
```

Keep the existing public `init(date:repository:)` ONLY for SwiftUI previews/tests (mark it `@_spi(Preview)` or guard with `#if DEBUG`). Production launches go through `load()`.

### 5.3 Split `loadDatabase` inside `CoreDataFernletRepository`

The slow part is JSON decoding. The fetch is cheap. Refactor to expose the slow step separately, and add an `async` entry point that hops to a detached task for the decode:

```swift
@MainActor
extension CoreDataFernletRepository {
    func loadSnapshotAsync(todayKey: String) async -> FernletSnapshot {
        if let cached = cachedDatabase {
            return snapshot(from: cached, todayKey: todayKey)
        }

        guard let payload = fetchPayloadData() else {
            // No record — first launch. Migrate from legacy (small file).
            let migrated = migrateDatabase(todayKey: todayKey)
            _ = saveDatabase(migrated)
            return snapshot(from: migrated, todayKey: todayKey)
        }

        // Hop off main for the decode only.
        let database: LocalFernletDatabase
        do {
            database = try await Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                return try decoder.decode(LocalFernletDatabase.self, from: payload)
            }.value
        } catch {
            assertionFailure("Core Data record decode failed: \(error)")
            return snapshot(from: LocalFernletDatabase(), todayKey: todayKey)
        }
        cachedDatabase = database
        return snapshot(from: database, todayKey: todayKey)
    }

    private func fetchPayloadData() -> Data? {
        guard let record = fetchRecord() else { return nil }
        return record.value(forKey: "payloadData") as? Data
    }

    private func snapshot(from database: LocalFernletDatabase, todayKey: String) -> FernletSnapshot {
        let day = database.days[todayKey] ?? FernletDay(date: todayKey)
        return FernletSnapshot(
            todayKey: todayKey, day: day, settings: database.settings,
            recentMeals: database.recentMeals, previousJournals: database.previousJournals,
            memories: database.memories, goals: database.goals, workshop: database.workshop,
            foodItems: database.foodItems, recipes: database.recipes,
            dailyScores: database.dailyScores, retryQueue: database.retryQueue
        )
    }
}
```

The existing synchronous `loadSnapshot(todayKey:)` stays for `mutatePastDay`/`loadDays` paths. Only the cold-launch path uses the async version.

### 5.4 Same treatment for `SavedRecipeRepository.load`

The CoreData fetch itself is fine on main. If a legacy JSON migration is needed, run the legacy decode on a detached task:

```swift
@MainActor
extension SavedRecipeRepository {
    func loadAsync() async -> [SavedRecipe] {
        let context = controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "SavedRecipeRecord")
        request.sortDescriptors = [NSSortDescriptor(key: "savedAt", ascending: false)]
        let records = (try? context.fetch(request)) ?? []
        let recipes = records.compactMap(Self.recipe(from:))
        if !recipes.isEmpty { return recipes }
        // Legacy migration off-main
        let legacy = legacyRepository
        let migrated = await Task.detached(priority: .utility) { legacy.load() }.value
        if !migrated.isEmpty { _ = save(migrated) }
        return migrated
    }
}
```

---

## 6. Phase 3 — Stop seeding bundled foods during init

`seedBundledFoodItems()` is the single biggest avoidable cost at launch. It:

1. Reads `USDAFoodItems.json` from the bundle (large file).
2. Decodes the full array into `[FoodItem]`.
3. Dedups against existing `foodItems`.
4. Mutates `foodItems` and schedules a CoreData save of the entire database.

The user does not need this data until they open `FoodView` (or log a meal). Move the seeding entirely out of the launch path.

### 6.1 Add a deferred catalog loader

New responsibility on `FernletStore`:

```swift
@Published private(set) var bundledFoodSeedingState: SeedingState = .notStarted

enum SeedingState { case notStarted, seeding, done, failed }

func ensureBundledFoodItemsSeeded() {
    guard bundledFoodSeedingState == .notStarted else { return }
    bundledFoodSeedingState = .seeding
    Task.detached(priority: .utility) { [weak self] in
        let bundled = FoodDataCatalog.bundledFoodItems()
        await MainActor.run {
            guard let self else { return }
            let existingIds = Set(self.foodItems.map(\.id))
            let missing = bundled.filter { !existingIds.contains($0.id) }
            if !missing.isEmpty {
                self.foodItems.append(contentsOf: missing)
                self.scheduleSnapshotSave()
            }
            self.bundledFoodSeedingState = .done
        }
    }
}
```

### 6.2 Where to call it

There are three reasonable trigger points; do **(a)** for sure and **(c)** as a belt‑and‑braces follow‑up:

- **(a)** `FoodView.onAppear` and `MealSheet.onAppear` — call `store.ensureBundledFoodItemsSeeded()`. This means the catalog is populated by the time the user actually searches it.
- **(b)** Any code path that does a food search (`FoodItemSearch.results(for:in:)` callers). Probably overkill; skip unless we see misses in testing.
- **(c)** After the LaunchScreen finishes (i.e., once `LaunchPreparationService.isDone == true`), call `ensureBundledFoodItemsSeeded()` from `ContentView.task` with `Task.detached(priority: .background)`. This way the catalog is warm well before the user actually navigates to Food, but it never blocks the first frame.

Do **not** call it from within the store's initializer or `FernletStore.load()`.

### 6.3 Watch out for

- `MealParser` and other code paths may search `foodItems` immediately. Verify those callers handle the case where `foodItems` is empty (they already do — they return a fallback meal).
- `FoodSelectionCandidateBuilder.candidates(for:foodItems:)` returns an empty set when foodItems is empty. The AI fallback path then writes a deterministic meal. That's acceptable for the brief window before the catalog is seeded.

---

## 7. Phase 4 — Defer `rebuildDerivedSignals()`

`rebuildDerivedSignals` is called from `init`, `reloadFromRepository`, and `performSnapshotSave`. Today's launch path triggers it via init.

### 7.1 Move out of init

Remove the call from the private init in §5.2. Replace with a one-shot deferred call:

```swift
func deferredPostLaunchTasks() {
    Task.detached(priority: .utility) { [weak self] in
        guard let self else { return }
        await MainActor.run { self.rebuildDerivedSignals() }
    }
}
```

Call `store.deferredPostLaunchTasks()` from `ContentView.task` immediately after `await launcher.prepare(store: store)` returns, or once `loader.phase == .ready`. The Home view's derived-signal-driven elements (companion thought, signal trends) tolerate an empty array for a few hundred ms.

### 7.2 Make sure `LaunchPreparationService` does not require it

`LaunchPreparationService.deterministicThought(for:)` reads `store.derivedSignals`. With deferred signals, it will see an empty array on cold launch and return the catch-all string `"A few ordinary care notes are here. Keep the day simple."` That is acceptable — and the existing `storeCompanionThought` runs once per launch anyway, so subsequent launches still show signal-driven text once the deferred task runs and re-publishes.

Optional: instead, have `LaunchPreparationService` `await store.rebuildDerivedSignalsIfNeeded()` so the thought is computed against fresh signals. If we do this, make `rebuildDerivedSignals` itself async and do the `loadDays()` decode on a detached task.

I recommend the simpler path for now (deferred + accept the first thought may be generic), and revisit if it visibly regresses the first companion thought.

### 7.3 Don't lose the `performSnapshotSave` call site

`performSnapshotSave` also calls `rebuildDerivedSignals()` at its tail. That stays — it only runs in response to user actions, not at launch.

---

## 8. Phase 5 — Suppress the launch-time `scheduleSnapshotSave`

`seedBundledFoodItems` calls `scheduleSnapshotSave()` after adding bundled items. Even with §6's deferral, the very first run still triggers a full encode + CoreData save shortly after launch.

Two options:

- **Option A:** in `ensureBundledFoodItemsSeeded`, mark the bundled foods as a separate non-persisted layer (don't write them to the snapshot at all; merge them in-memory when constructing `foodItems` views). Cleaner but more invasive.
- **Option B (recommended for this iteration):** keep the save, but **debounce** the very first launch's save until the LaunchScreen is dismissed. Easiest implementation: have `ensureBundledFoodItemsSeeded` capture a `Bool launchScreenDismissed` flag and not call `scheduleSnapshotSave` until that flag is `true`. The flag flips in `ContentView` when `launcher.isDone` transitions to `true`.

Either way, the goal is the same: no CoreData encode/save while the LaunchScreen is on screen.

---

## 9. Phase 6 — Biometric loop fix

Whether or not Phase 1–5 alone resolves the symptom (they probably do), the lock view has latent issues that should be fixed independently. There is no scenario in which the current behavior is correct.

### 9.1 `biometricAutoTriggered` belongs on the service, not the view

Today, in `FernletLockView`:

```swift
@State private var biometricAutoTriggered = false
…
.onAppear {
    if lockService.biometricEnabled && !lockService.requiresReset && !isInputDisabled && !biometricAutoTriggered {
        biometricAutoTriggered = true
        triggerBiometric()
    }
}
```

`@State` is reset every time SwiftUI re-creates the `FernletLockView` struct. The view IS re-created any time `FernletLockGateModifier`'s `if active && isLocked` branch flips back to `true`. So if `lockService.state` cycles `locked → unlocked → locked` for any reason — and there are several ways this can happen (scenePhase background, `handleDisappear` firing after the `suppressRelock` window expires, a remote-change notification triggering `reloadFromRepository` on a different view path, etc.) — the auto-trigger fires *again*.

Fix: move the "has been auto-prompted this lock session" flag to `FernletLockService` so it survives view recreation, and reset it inside `lock(reason:)`:

```swift
// In FernletLockService
@MainActor
@Published private(set) var hasAutoPromptedBiometricForCurrentLockSession = false

func consumeAutoBiometricPromptOpportunity() -> Bool {
    guard !hasAutoPromptedBiometricForCurrentLockSession else { return false }
    hasAutoPromptedBiometricForCurrentLockSession = true
    return true
}

func lock(reason: FernletLockReason) {
    guard case .unlocked = state else { return }
    scrubContentKey()
    state = .locked(cooldownDeadline: activeCooldownDeadline())
    // NOTE: do NOT reset hasAutoPromptedBiometricForCurrentLockSession here.
    // The user just locked — they shouldn't be auto-prompted again immediately.
    FernletAuditLog.log("lock.engaged", context: ["reason": reason.auditLabel])
}
```

Reset the flag only when the user **succeeds** at unlocking, or when the app starts cold:

```swift
// Inside unlock(passcode:) and unlockWithBiometrics() success paths, after state = .unlocked
hasAutoPromptedBiometricForCurrentLockSession = false
```

Then in `FernletLockView.onAppear`:

```swift
.onAppear {
    refreshCooldown()
    if lockService.biometricEnabled,
       !lockService.requiresReset,
       !isInputDisabled,
       lockService.consumeAutoBiometricPromptOpportunity() {
        triggerBiometric()
    }
}
```

This means: the user gets one auto‑prompt per lock session. If it fails, they enter their passcode manually (or tap the biometric button to retry explicitly). No loops are possible.

### 9.2 Surface biometric errors instead of silently swallowing

Today's catch block:

```swift
} catch {
    // Fall through to passcode entry on biometric failure
}
```

Replace with:

```swift
} catch FernletLockError.biometricNotAvailable {
    // Quietly fall back to passcode UI
} catch FernletLockError.biometricFailed {
    errorMessage = "Face ID didn't recognize you. Try your passcode."
} catch FernletLockError.resetRequired {
    errorMessage = "Too many attempts. Reset is required."
} catch {
    errorMessage = error.localizedDescription
}
```

The user reports "nothing happens." Sometimes that's because Face ID actually did fail and we hid it. Visible feedback eliminates that class of confusion.

### 9.3 Use an explicit `LAContext.evaluatePolicy` before the keychain query

`KeychainItem.loadBiometricBypassSync` builds an `LAContext`, sets `localizedReason`, and hands it to `SecItemCopyMatching` via `kSecUseAuthenticationContext`. Recent iOS versions accept that, but the more reliable, broadly-supported pattern is:

```swift
static func loadBiometricBypassSync(prompt: String, service: String) throws -> Data {
    let context = LAContext()
    context.localizedReason = prompt

    // Pre-authenticate so SecItemCopyMatching has a usable LAContext and the
    // user sees one cohesive Face ID prompt with our copy.
    var authError: NSError?
    let group = DispatchSemaphore(value: 0)
    var authSucceeded = false
    var authFailure: Error?
    context.evaluateAccessControl(
        try acFor(.biometryCurrentSet),
        operation: .useItem,
        localizedReason: prompt
    ) { success, error in
        authSucceeded = success
        authFailure = error
        group.signal()
    }
    group.wait()
    guard authSucceeded else {
        throw authFailure ?? FernletLockError.biometricFailed
    }

    // …then do SecItemCopyMatching with the now-authenticated context (no second prompt).
    …
}
```

Notes:

- This must keep running on a background queue (currently dispatched via `DispatchQueue.global(qos: .userInitiated).async` in `unlockWithBiometrics` — keep that).
- `evaluateAccessControl` accepts the same `SecAccessControl` you used to store the item. Extract a helper `acFor(_ flag: SecAccessControlCreateFlags)` from `storeBiometricBypass` so both write and read paths use identical access control.
- After this, `SecItemCopyMatching` finds the authenticated context and returns data without prompting again.

This change is optional if Phase 1 alone resolves the loop, but it's a small, easily reviewable robustness improvement that addresses the "user authed but app didn't react" failure mode cleanly.

### 9.4 Tighten `FernletLockGateModifier`'s relock suppression

Today's logic:

```swift
.onChange(of: scenePhase) { _, newPhase in
    switch newPhase {
    case .inactive: suppressRelock = true
    case .active:
        suppressRelockTask = Task { try? await Task.sleep(for: .milliseconds(600))
                                      suppressRelock = false }
    default: break
    }
}
```

Two issues:

1. The 600ms window is short enough that if SwiftUI's lifecycle settles after that, `handleDisappear` will lock. On a busy main actor (which is exactly our cold-launch case) 600ms is sometimes not enough.
2. Only `viewDisappeared` is suppressed. `FernletApp.scenePhase == .background` still locks. That's intentional, but worth confirming the iOS Face ID prompt doesn't transiently push the app into `.background` on some hardware. Empirically it doesn't, but we should log scenePhase transitions during a Face ID prompt as part of QA so we have a record.

Recommended changes:

- Bump the post-active suppression window to **1500ms**.
- Add an explicit `suppressRelock = true` setter on the gate that the biometric trigger can call **before** invoking the keychain query, with auto-clearing on success and an outer-bound timeout. Pseudocode:

```swift
// Service-level helper used by both the gate and the lock view:
@Published private(set) var isPerformingBiometricUnlock = false

func unlockWithBiometrics() async throws -> UnlockResult {
    isPerformingBiometricUnlock = true
    defer { isPerformingBiometricUnlock = false }
    …existing body…
}

// Gate uses it:
if lockService.isPerformingBiometricUnlock { return /* never lock during prompt */ }
```

Then `handleDisappear` becomes:

```swift
private func handleDisappear() {
    guard active, gateIsActive else { return }
    gateIsActive = false
    guard !suppressRelock else { return }
    guard !lockService.isPerformingBiometricUnlock else { return }
    if case .unlocked = lockService.state {
        lockService.lock(reason: .viewDisappeared)
    }
}
```

This makes the suppression precise and based on real state rather than a hopeful 600ms timer.

### 9.5 Don't auto-trigger biometrics while the gate's content is being torn down

While we're in the gate, also guard against the auto-trigger firing during a parent state change that's about to remove the gate altogether. A simple `guard active else { return }` is already present, but also add:

```swift
.onAppear {
    refreshCooldown()
    // Allow one runloop tick so SwiftUI settles tab/page transitions
    Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(80))
        guard lockService.biometricEnabled,
              !lockService.requiresReset,
              !isInputDisabled,
              lockService.consumeAutoBiometricPromptOpportunity() else { return }
        triggerBiometric()
    }
}
```

The 80ms delay avoids triggering Face ID during the TabView page-swap animation; a noticeable real-world cause of the "scanner came up at a weird moment" report.

---

## 10. File-by-file change list

| File | Change | Phase |
| --- | --- | --- |
| `FernletApp.swift` | Drop `@StateObject private var store`. Add `@StateObject private var loader = FernletStoreLoader()`. Switch top-level branch on `loader.phase`. Move iCloud sync `.task` + `.onChange` inside the `.ready` branch. Keep `FERNLET_UI_TEST_OPEN_PRIVACY_DATA` as a separate env-gated branch that bypasses the loader. | 1 |
| `FernletStoreLoader.swift` *(new)* | New `@MainActor` class managing `Phase` and statusMessage. Calls `FernletStore.load`. | 1 |
| `FernletStore.swift` | Add `static func load(...) async throws -> FernletStore`. Add private `init(snapshot:savedRecipes:…)` consuming a prebuilt snapshot. Keep the existing `init(date:repository:)` for previews/tests only (DEBUG/SPI). Remove `seedBundledFoodItems()` + `rebuildDerivedSignals()` from init. Add `ensureBundledFoodItemsSeeded()` and `deferredPostLaunchTasks()`. Wrap each phase in `timed { … }`. | 1, 2, 3, 4 |
| `CoreDataFernletRepository.swift` | Refactor `loadDatabase` so the JSON decode is callable from an async path. Add `loadSnapshotAsync(todayKey:)`. Add timing signposts. | 0, 2 |
| `SavedRecipe.swift` | Add `loadAsync()` to `SavedRecipeRepository` that does the legacy-JSON fallback off-main. | 2 |
| `FoodDataCatalog.swift` | No source change required, but add a signpost around `bundledData(bundle:)` + `foodItems(from:)` decoding so we can confirm bundle-load timings. | 0 |
| `ContentView.swift` | After `await launcher.prepare(store: store)` returns, call `store.deferredPostLaunchTasks()` and (belt-and-braces) `store.ensureBundledFoodItemsSeeded()`. | 3, 4 |
| `FoodView.swift` | Call `store.ensureBundledFoodItemsSeeded()` in `.onAppear`. | 3 |
| `FernletLockService.swift` | Add `hasAutoPromptedBiometricForCurrentLockSession` + `consumeAutoBiometricPromptOpportunity()`. Reset on successful unlock. Add `isPerformingBiometricUnlock` published flag, set in `unlockWithBiometrics()`. Optionally adopt explicit `evaluateAccessControl` (9.3). | 6 |
| `FernletLockView.swift` | Replace `@State biometricAutoTriggered` with `lockService.consumeAutoBiometricPromptOpportunity()`. Add 80ms settle delay before auto-trigger. Surface biometric errors via `errorMessage`. | 6 |
| `FernletLockGate.swift` | Bump post-active suppress window to 1500ms. Gate `handleDisappear` on `!lockService.isPerformingBiometricUnlock`. | 6 |
| `LaunchPreparationService.swift` | No change required. Document that `store.derivedSignals` may be empty when this runs (it's a no-op in `deterministicThought` already). | (4) |
| `FernletTests` | Add a launch-timing test (XCTest measure block) and a `FernletLockServiceTests` case for auto-prompt-once. | All |
| `FernletUITestsLaunchTests.swift` | Adjust if it asserts on launch screen timing (it likely doesn't). | 1 |

---

## 11. Testing strategy

Before submitting:

1. **Unit-level**
   - `FernletLockServiceTests`: add a test that constructs the service, configures biometrics, calls `consumeAutoBiometricPromptOpportunity()` twice — second call returns false. After `state = .unlocked` and a subsequent `lock(reason:)`, the next consume call returns true again only if the unlock path resets the flag (it does). Verify `lock(reason:)` does NOT reset the flag — so a relock-while-already-locked doesn't grant another auto-prompt.
   - `FernletStoreTests` (new or extended): construct via `FernletStore.load` and assert that `derivedSignals` is empty immediately after, then becomes populated after `deferredPostLaunchTasks()` runs.

2. **Integration (manual on device)**
   - Cold launch on a populated database with iCloud sync OFF. Verify LaunchScreen pulse animates immediately. Capture os_signposts in Instruments.
   - Repeat with iCloud sync ON. Verify same.
   - Set up Face ID. Lock app. Open app. Navigate to Personal tab. Verify exactly one Face ID prompt, with the localizedReason `"Unlock Fernlet"`.
   - Repeat after backgrounding the app. Verify only one auto-prompt.
   - Cancel the Face ID prompt. Verify the lock view shows `"Face ID didn't recognize you. Try your passcode."` and does not re-prompt automatically. Tap the biometric button manually — it re-prompts.
   - Disable biometrics in Settings → AppLock → Use Face ID OFF. Cold-launch. Lock. Navigate to Personal. Verify passcode entry appears with no Face ID prompt.

3. **Regression**
   - Confirm `FERNLET_UI_TEST_OPEN_PRIVACY_DATA` test still opens directly into `PrivacyDataSettingsView`.
   - Confirm `-resetOnboarding` still resets onboarding (init arg parsing is unchanged).
   - Confirm the existing `OnboardingCoordinator` still works after Phase 1 — it lives in the `.ready` branch so it receives a real store.

4. **Performance budget**
   - First frame on screen: ≤ 250 ms from app launch.
   - `FernletStore.load` completes: ≤ 1500 ms on baseline test device with a populated DB.
   - LaunchScreen is up for at least `LaunchPreparationService.minimumSeconds` (1.4s) and at most `load duration + 1.4s + ~250ms`.

---

## 12. Order of operations / shippable increments

Each numbered step is a self-contained PR that should ship green:

1. **PR-1: Timing instrumentation** (Phase 0). No behavior change. Land first. Capture baseline numbers in the PR description.
2. **PR-2: Loader + LaunchScreen-first** (Phase 1). Functional change — store now constructed inside loader, but still synchronously (load() just calls the existing sync init under a Task). At this point LaunchScreen animates and the perceived launch is dramatically better even though the work hasn't actually moved off main yet. Use the timings from PR-1 to confirm.
3. **PR-3: Async snapshot + saved recipes** (Phase 2). The JSON decode moves to a detached task. Real launch time drops.
4. **PR-4: Defer bundled foods + derived signals** (Phases 3 & 4 & 5). Largest cleanup. Verify no regressions in Food search or signal-driven UI.
5. **PR-5: Biometric loop hardening** (Phase 6). Independent of 1–4 — could ship first if the biometric issue is the more urgent of the two.

If we need to triage which to ship first, PR-2 alone resolves the "screen is black for 15s" UX and is the single biggest perceived win.

---

## 13. Risks and watch-items

- **CoreData viewContext on a Task hop:** `CoreDataFernletRepository` is `@MainActor`. The async refactor in §5.3 keeps the fetch on main and only moves the JSON decode off main, which is safe. Don't accidentally call viewContext APIs from the detached task.
- **`Task.detached` cancellation:** none of our detached tasks should be cancellable via parent task cancellation. Use `Task.detached` (not `Task { … }`) when we want to outlive the loader.
- **`OnboardingCoordinator` calling `store.completeOnboarding`:** ensure this still works when the store is delivered inside `.ready`. The coordinator captures `store` by reference, so it does.
- **`PersistenceController.shared` is a `let` static:** the first access still does `loadPersistentStores` synchronously on whatever thread touches it. Make sure `FernletStore.load` is the first touch (inside its detached path), not, e.g., `SavedRecipeRepository` from outside. Adding a signpost to `PersistenceController.init` will surface any accidental early access.
- **`ContentView`'s `@StateObject private var launcher` and `@StateObject private var periodStore`** — both are cheap to construct; verify with signposts after the refactor to be sure nothing else has slipped in.
- **iCloud sync re-activation 5s after launch:** the existing `Task.sleep(for: .seconds(5))` pattern in `activateCloudSyncAfterStartupIfNeeded` should stay — moving it inside the `.ready` branch is enough.
