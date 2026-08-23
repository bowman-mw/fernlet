import XCTest
import LocalPersistence
import FernletDomainModel
import PrivateMemoryStore
@testable import FernletPersistence
import FoodCatalog
import PrivateStoreCore
import CloudKitSync
@testable import Fernlet

// Test-only sanitized wrappers. `forTestingSanitized` wraps WITHOUT stripping (for repository
// serialization-fidelity tests and setup of pre-strip fixtures); use `SanitizedSnapshot.sanitizing(...)`
// / `SanitizedDay.sanitizing(...)` directly when a test wants to exercise the real privacy strip.
extension FernletSnapshot {
    var forTestingSanitized: SanitizedSnapshot { SanitizedSnapshot.uncheckedSanitizedForTesting(self) }
}

extension FernletDay {
    var forTestingSanitized: SanitizedDay { SanitizedDay.uncheckedSanitizedForTesting(self) }
}

// Test-only convenience overloads so the many existing tests that persist a raw snapshot/day keep
// compiling unchanged. They wrap WITHOUT stripping (`forTestingSanitized`), preserving prior test
// semantics. These live in the test target ONLY — production code in other modules still sees just the
// `SanitizedSnapshot`/`SanitizedDay` boundary, so the privacy guard is unaffected. A test that wants to
// exercise the real strip calls `SanitizedSnapshot.sanitizing(...)` explicitly.
extension FernletRepository {
    @discardableResult func saveSnapshot(_ snapshot: FernletSnapshot) -> Bool {
        saveSnapshot(snapshot.forTestingSanitized)
    }

    @discardableResult func updateDay(_ day: FernletDay, for dateKey: String, todayKey: String) -> Bool {
        updateDay(day.forTestingSanitized, for: dateKey, todayKey: todayKey)
    }
}

/// A fresh, unshared own-photo root for one test store.
///
/// EVERY `FernletStore` built in the test process needs its own: the three own-photo corpora (meal,
/// recipe, progress) live under this directory, and `resetAll` / `deleteAllData` / the duress wipe
/// call `deleteAll()` on all three. XCTest and Swift Testing suites run in parallel in a single
/// process, so a store left on the shared container root has its photos deleted out from under it
/// the moment ANY concurrently-running test wipes — which is exactly how
/// `RecipeReimportTests.failedReimportLeavesTheRecipeUntouched` failed under the full suite while
/// passing in isolation.
///
/// Not created on disk here: the photo stores create their own directories on first write, and an
/// unwritten test store should leave nothing behind.
func uniquePhotoDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fernlet.tests.photos.\(UUID().uuidString)", isDirectory: true)
}

/// A fresh, never-shared root for ONE test store's proximity sidecars — the friend photo-wall cache
/// and its preferences, the heart ledger, and the three sealed heart-drop sidecars. The production
/// root (`Application Support/Fernlet`) is process-wide, so without this a manager built in one
/// suite reads and overwrites the album of every concurrently-live one (the wall's index is re-saved
/// whole on every `deletePhoto` / `deleteAllSessionPhotos`), and any wiping test deletes the queued
/// hearts and received-heart ledger of every other live store.
///
/// The heart-drop sidecars need `uniqueHeartDropKeychainService()` as well — this root alone leaves
/// their seal key shared. The heart LEDGER is unsealed, so for it this root is the whole fix.
/// See `ProximityHost.proximitySupportDirectory` and `HeartDropStorageScope`.
func uniqueProximityDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fernlet.tests.proximity.\(UUID().uuidString)", isDirectory: true)
}

/// A fresh, never-shared keychain service for ONE test store's heart-drop material — the prekey
/// private halves and the key that seals its outbox / peer-bundle / dedup sidecars.
///
/// The other half of `uniqueProximityDirectory()` for the heart-drop stores, and it is not optional:
/// `FernletStore.deleteAllData` calls `heartDropService.wipeForDeleteAll()`, which deletes the WHOLE
/// keychain service. A store given its own directory but the production service would still have its
/// sealed sidecars orphaned by any concurrently-running wipe — the outbox then quarantines the file
/// it can no longer open and latches `dataLossOccurred`, which is worse than losing it. See
/// `HeartDropStorageScope`.
///
/// Shaped `com.fernlet.heartdrop.test.<uuid>` to match the suite-fixture convention
/// `PrivacyWipeCoverageTests.keychainServiceLiterals` skips (`.test.`), so per-test services never
/// read as new undocumented app services.
func uniqueHeartDropKeychainService() -> String {
    "com.fernlet.heartdrop.test.\(UUID().uuidString)"
}

/// A fresh, never-shared storage scope for ONE test `FernletLockService`'s pending-narrative
/// buffer — the directory holding its sealed `pending-narratives.bin` AND the keychain service
/// holding the key that seals it, as the single value `PendingNarrativeStorageScope` makes them.
///
/// EVERY lock service built in the test process needs its own: `reset()` purges the buffer file
/// (and `purgePendingNarratives()` is the delete-all hook's whole body), so on the process-wide
/// `.production` scope any resetting test destroys the buffered locked-state cycle notes of every
/// concurrently-running one. Both halves ride together because the buffer is sealed: a private
/// directory with the shared key service would still lose its key to whatever sweeps that service,
/// leaving the isolated file as ciphertext nothing can open — every `append`/`drainAll` then
/// throws until a purge, which is strictly worse than losing the file outright.
///
/// The service is shaped `com.fernlet.narrative-buffer.test.<uuid>` to match the suite-fixture
/// convention `PrivacyWipeCoverageTests.keychainServiceLiterals` skips (`.test.`). The directory is
/// not created on disk here: the buffer creates it on first write, and an unwritten buffer should
/// leave nothing behind.
///
/// Pass the SAME scope to two services when a test deliberately simulates a relaunch over the same
/// buffered notes — the shared buffer is that test's fixture, and it needs the same file AND the
/// same key or the "relaunch" finds a file it cannot open.
func uniqueNarrativeBufferScope() -> PendingNarrativeStorageScope {
    PendingNarrativeStorageScope(
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet.tests.narrativeBuffer.\(UUID().uuidString)", isDirectory: true),
        keychainService: "com.fernlet.narrative-buffer.test.\(UUID().uuidString)"
    )
}

/// A fresh, never-shared app-group root for ONE test store — the guided-run and cooking-run state
/// files, the inbound widget-action queue, and the widget snapshot, which are all co-tenants of the
/// real `<group.MBO.Fernlet>/FernletWidgets/` directory.
///
/// `resetAll` clears both run files and `deleteAllData` clears the queue, so on the production
/// container any wiping test destroyed them for every concurrently-live store. That one was LIVE,
/// not theoretical: `GuidedWorkoutRunStoreTests` drives the guided file through `makeTestStore()`
/// while `DeleteAllDataTests` writes and wipes it.
///
/// Pass the SAME directory to two stores when a test deliberately simulates a relaunch over the same
/// in-flight run — that is what `GuidedWorkoutRunStoreTests` and `CookingRunStoreTests` do.
func uniqueAppGroupDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fernlet.tests.appgroup.\(UUID().uuidString)", isDirectory: true)
}

/// A fresh throwaway defaults suite for ONE test store's device-local AI-call counter.
///
/// The counter's identity is a UserDefaults SUITE, not a path, and `deleteAllData` resets it — so on
/// `.standard` one store's wipe zeroes every other live store's quota. A unique KEY on `.standard`
/// would work too but would litter the app's real domain permanently, and `PrivacyWipeCoverageTests`
/// has no discovery wall for defaults keys, so that litter would be invisible.
func uniqueAIQuotaDefaults() -> UserDefaults {
    UserDefaults(suiteName: "fernlet.tests.aiQuota.\(UUID().uuidString)") ?? .standard
}

/// A fresh throwaway defaults suite for ONE test store's device-local sensitive-surface sidecar — the
/// period/intimacy visibility RESOLUTION *and* the age determination, which `FernletStore` deliberately
/// keeps in the same suite (see `FernletStore.ageAssurance`).
///
/// The identity is a UserDefaults SUITE rather than a path, and this one is written on EVERY store
/// init (`reconcileSensitiveSurfaceVisibility` stores the resolution) and cleared by `resetAll` — the
/// commonest wipe in the suite by a wide margin. On `.standard` that means one store's reset returns
/// every concurrently-live store to "never resolved" and drops its age verdict, so the next read
/// re-derives visibility from `sex` and both gates fail closed mid-test.
///
/// A throwaway suite rather than unique KEYS on `.standard`, for the reason `uniqueAIQuotaDefaults()`
/// gives: keys would litter the app's real domain permanently and invisibly. Nothing removes the suite
/// afterwards either, but a suite that was never registered leaves no file on disk unless written, and
/// the tests that DO want a named suite (`AgeAssuranceStoreTests`) already tear their own down.
///
/// Pass the SAME suite to two stores when a test deliberately simulates a relaunch on the same device —
/// that is what `SensitiveSurfaceGateTests.mixedVersionKeyDropDoesNotReopenHiddenSurfaces` does, and
/// the sidecar surviving into the second store is the entire point of that test.
func uniqueSensitiveVisibilityDefaults() -> UserDefaults {
    UserDefaults(suiteName: "fernlet.tests.sensitiveVisibility.\(UUID().uuidString)") ?? .standard
}

/// A fresh, never-shared queue file for ONE test store's share-extension recipe inbox.
///
/// A FILE, not a directory: the queue owns exactly one, and it lives in a different app-group
/// subdirectory (`SharedRecipeImports/`) from the `FernletWidgets/` root `uniqueAppGroupDirectory()`
/// covers, so the two seams are genuinely separate rather than redundant.
///
/// `deleteAllData` calls `sharedRecipeImportQueue.clear()`, so on the production path one store's wipe
/// empties the inbox of every concurrently-live store. That one is latent rather than live — nothing
/// reads the production queue today, because the two suites that exercise the drain
/// (`RecipeSourceURLTests`, `DeleteAllDataTests`) hand-inject a queue over their store's. Those
/// injections are the tell: writing the test the OBVIOUS way, by reaching for
/// `store.sharedRecipeImportQueue`, is exactly what joins the race.
func uniqueSharedRecipeImportQueueURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("fernlet.tests.recipeInbox.\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("PendingRecipeURLs.json")
}

/// Creates a FernletStore backed by an in-memory Core Data stack.
/// All data is discarded when the store is deallocated.
///
/// `bundledFoodItems` seeds an in-memory food catalog (the SQLite-backed bundle is not loaded in
/// tests), so tests stay deterministic — pass the specific USDA items a test needs. A test that must
/// exercise the SHIPPED catalog (the dish-template bind audit replays the real 118,317 rows) passes
/// `foodCatalog: FoodCatalog.bundled()` instead; it is opt-in precisely because it is not
/// deterministic in the same way. The two are mutually exclusive — an explicit `foodCatalog` REPLACES
/// the seeded items rather than adding to them, so passing both traps rather than silently dropping
/// the seed.
///
/// `photoDocumentsDirectory` defaults to a fresh `uniquePhotoDirectory()`; pass an explicit one only
/// to give two stores a SHARED photo corpus (e.g. simulating a relaunch over the same photos). The
/// same holds for `proximitySupportDirectory` + `heartDropKeychainService`, which have to be passed
/// TOGETHER to share heart state — the sidecars are sealed, so a second store needs the same file
/// root AND the same key to read what the first one wrote.
@MainActor
func makeTestStore(
    date: Date = .now,
    bundledFoodItems: [FoodItem] = [],
    foodCatalog: FoodCatalog? = nil,
    appGroupDirectory: URL = uniqueAppGroupDirectory(),
    photoDocumentsDirectory: URL = uniquePhotoDirectory(),
    proximitySupportDirectory: URL = uniqueProximityDirectory(),
    heartDropKeychainService: String = uniqueHeartDropKeychainService(),
    aiQuotaDefaults: UserDefaults = uniqueAIQuotaDefaults(),
    sensitiveVisibilityDefaults: UserDefaults = uniqueSensitiveVisibilityDefaults(),
    sharedRecipeImportQueueFileURL: URL = uniqueSharedRecipeImportQueueURL()
) -> FernletStore {
    makeTestStoreWithRepositories(
        date: date,
        bundledFoodItems: bundledFoodItems,
        foodCatalog: foodCatalog,
        appGroupDirectory: appGroupDirectory,
        photoDocumentsDirectory: photoDocumentsDirectory,
        proximitySupportDirectory: proximitySupportDirectory,
        heartDropKeychainService: heartDropKeychainService,
        aiQuotaDefaults: aiQuotaDefaults,
        sensitiveVisibilityDefaults: sensitiveVisibilityDefaults,
        sharedRecipeImportQueueFileURL: sharedRecipeImportQueueFileURL
    ).store
}

/// Like `makeTestStore`, but also returns the backing days repository and the in-memory journal
/// narrative repository so a test can seed/inspect the persisted blob and the sealed store directly
/// (e.g. the WI-1 historical-scrub migration test, which must seed a pre-fix leaked past-day blob).
///
/// `wrapNarrativeStore` lets a test interpose a decorator (e.g. one that simulates a transient seal
/// failure) between the store and the real in-memory narrative repository. The returned `narratives` is
/// always the *underlying* real repository, so reads through it reflect what the wrapped store wrote.
@MainActor
func makeTestStoreWithRepositories(
    date: Date = .now,
    bundledFoodItems: [FoodItem] = [],
    foodCatalog: FoodCatalog? = nil,
    appGroupDirectory: URL = uniqueAppGroupDirectory(),
    photoDocumentsDirectory: URL = uniquePhotoDirectory(),
    proximitySupportDirectory: URL = uniqueProximityDirectory(),
    heartDropKeychainService: String = uniqueHeartDropKeychainService(),
    aiQuotaDefaults: UserDefaults = uniqueAIQuotaDefaults(),
    sensitiveVisibilityDefaults: UserDefaults = uniqueSensitiveVisibilityDefaults(),
    sharedRecipeImportQueueFileURL: URL = uniqueSharedRecipeImportQueueURL(),
    wrapNarrativeStore: (JournalNarrativeRepository) -> any JournalNarrativeStoring = { $0 }
) -> (store: FernletStore, repository: CoreDataFernletRepository, narratives: JournalNarrativeRepository) {
    precondition(
        foodCatalog == nil || bundledFoodItems.isEmpty,
        "pass bundledFoodItems OR an explicit foodCatalog — an explicit catalog replaces the seeded items"
    )
    let controller = PersistenceController(inMemory: true)
    // Use a non-existent temp path so the legacy migration returns an empty database.
    let legacyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
    let repository = CoreDataFernletRepository(
        controller: controller,
        legacyRepository: LocalFernletRepository(fileURL: legacyURL)
    )
    // Pass a SavedRecipeRepository backed by the same in-memory controller so
    // tests never touch PersistenceController.shared (a real SQLite store).
    let savedRecipeRepository = SavedRecipeRepository(
        controller: controller,
        legacyRepository: LegacySavedRecipeJSONRepository(fileURL: legacyURL)
    )
    // Use an in-memory JournalNarrativeRepository so tests never touch
    // PrivatePersistenceController.shared (a real on-device store). Its "ever stored" divergence latch
    // gets a THROWAWAY defaults suite for the same reason the store is in-memory: the latch lives in
    // `.standard`, which is process-global under the test runner, so any test that writes a journal
    // entry would otherwise mark every later test's device as "already diverged" and silently invert
    // the sealed-backup restore assertions.
    let journalNarrativeRepository = JournalNarrativeRepository(
        controller: PrivatePersistenceController(inMemory: true),
        defaults: UserDefaults(suiteName: "fernlet.tests.journalLatch.\(UUID().uuidString)") ?? .standard
    )
    let store = FernletStore(
        date: date,
        repository: repository,
        savedRecipeRepository: savedRecipeRepository,
        // Back custom items + the coin ledger with the same in-memory controller so these tests never fall
        // back to CustomItemRepository()/CoinLedgerRepository() on PersistenceController.shared (a real
        // SQLite store) — that shared coupling makes tests non-hermetic and flaky under parallel runs.
        customItemRepository: CustomItemRepository(controller: controller),
        coinLedgerRepository: CoinLedgerRepository(controller: controller),
        milestoneLedgerRepository: MilestoneLedgerRepository(controller: controller),
        journalNarrativeRepository: wrapNarrativeStore(journalNarrativeRepository),
        foodCatalog: foodCatalog ?? FoodCatalog(source: InMemoryBundledFoodSource(bundledFoodItems)),
        // The period/intimacy visibility resolution AND the age verdict share one defaults SUITE, and
        // `resetAll` clears both — see `uniqueSensitiveVisibilityDefaults()`.
        sensitiveVisibilityDefaults: sensitiveVisibilityDefaults,
        // Guided/cooking run state, the widget queue and the widget snapshot — see
        // `uniqueAppGroupDirectory()`.
        appGroupDirectory: appGroupDirectory,
        // The share-extension recipe inbox, a FILE in a different app-group subdirectory — see
        // `uniqueSharedRecipeImportQueueURL()`.
        sharedRecipeImportQueueFileURL: sharedRecipeImportQueueFileURL,
        // Own-photo corpora in a per-store temp root — see `uniquePhotoDirectory()`.
        photoDocumentsDirectory: photoDocumentsDirectory,
        // Friend photo wall + the heart ledger and heart-drop sidecars likewise — see
        // `uniqueProximityDirectory()`.
        proximitySupportDirectory: proximitySupportDirectory,
        // The heart-drop sidecars' OTHER half: they are sealed, and the wipe deletes keys by
        // service — see `uniqueHeartDropKeychainService()`.
        heartDropKeychainService: heartDropKeychainService,
        // The AI-call counter's identity is a defaults SUITE — see `uniqueAIQuotaDefaults()`.
        aiQuotaDefaults: aiQuotaDefaults
    )
    return (store, repository, journalNarrativeRepository)
}

/// Builds a fresh FernletStore (new in-memory coordinator → empty `sealedJournalIDs`) over an
/// EXISTING days repository + sealed narrative store, simulating a brand-new app session that
/// reads/writes the same persisted blob and sealed store. Used to reproduce the "entry sealed in a
/// prior session, then edited after it aged out of the in-memory sealed-id set" path (F1 regression).
///
/// The photo corpus is NOT shared by default — pass the first store's `photoDocumentsDirectory` when
/// a test needs its photos to survive into the simulated relaunch. Nor is the heart state: pass the
/// first store's `proximitySupportDirectory` AND `heartDropKeychainService` (both, or the relaunch
/// finds a sealed sidecar it has no key for) when the hearts have to survive too. Nor is the
/// device-local sensitive-surface sidecar: pass the first store's `sensitiveVisibilityDefaults` when
/// the relaunch has to remember a hidden period/intimacy surface or an age verdict — neither of those
/// ever rides the synced blob, so the repository this helper shares cannot carry them across.
@MainActor
func makeStoreSharingStores(
    date: Date = .now,
    repository: CoreDataFernletRepository,
    narratives: JournalNarrativeRepository,
    photoDocumentsDirectory: URL = uniquePhotoDirectory(),
    proximitySupportDirectory: URL = uniqueProximityDirectory(),
    heartDropKeychainService: String = uniqueHeartDropKeychainService(),
    appGroupDirectory: URL = uniqueAppGroupDirectory(),
    aiQuotaDefaults: UserDefaults = uniqueAIQuotaDefaults(),
    sensitiveVisibilityDefaults: UserDefaults = uniqueSensitiveVisibilityDefaults(),
    sharedRecipeImportQueueFileURL: URL = uniqueSharedRecipeImportQueueURL()
) -> FernletStore {
    let legacyURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("json")
    // Throwaway saved-recipe + coin-ledger stores (both irrelevant to the journal-sealing path) backed
    // by an in-memory controller so these tests never touch the shared on-device stores.
    let throwawayController = PersistenceController(inMemory: true)
    let savedRecipeRepository = SavedRecipeRepository(
        controller: throwawayController,
        legacyRepository: LegacySavedRecipeJSONRepository(fileURL: legacyURL)
    )
    return FernletStore(
        date: date,
        repository: repository,
        savedRecipeRepository: savedRecipeRepository,
        customItemRepository: CustomItemRepository(controller: throwawayController),
        coinLedgerRepository: CoinLedgerRepository(controller: throwawayController),
        milestoneLedgerRepository: MilestoneLedgerRepository(controller: throwawayController),
        journalNarrativeRepository: narratives,
        foodCatalog: FoodCatalog(source: InMemoryBundledFoodSource([])),
        sensitiveVisibilityDefaults: sensitiveVisibilityDefaults,
        appGroupDirectory: appGroupDirectory,
        sharedRecipeImportQueueFileURL: sharedRecipeImportQueueFileURL,
        photoDocumentsDirectory: photoDocumentsDirectory,
        proximitySupportDirectory: proximitySupportDirectory,
        heartDropKeychainService: heartDropKeychainService,
        aiQuotaDefaults: aiQuotaDefaults
    )
}

/// Creates a FernletStore pre-populated with N meals, a journal entry,
/// sleep data, and 3 water bottles.
@MainActor
func makePopulatedTestStore() -> FernletStore {
    let store = makeTestStore()
    store.addMeal(from: "chicken breast 6oz", type: .lunch)
    store.addMeal(from: "protein shake", type: .snack)
    store.addJournal(text: "Felt good today", tag: .good)
    store.setSleep(hours: 7.5, quality: .good, note: "Slept well")
    store.day.bottleCount = 3
    return store
}

extension FernletDay {
    /// A minimal day for testing with a known date key.
    static func stub(dateKey: String = "2026-05-19") -> FernletDay {
        FernletDay(date: dateKey)
    }
}
