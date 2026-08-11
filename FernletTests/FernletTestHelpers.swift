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

/// Creates a FernletStore backed by an in-memory Core Data stack.
/// All data is discarded when the store is deallocated.
///
/// `bundledFoodItems` seeds an in-memory food catalog (the SQLite-backed bundle is not loaded in
/// tests), so tests stay deterministic — pass the specific USDA items a test needs.
@MainActor
func makeTestStore(date: Date = .now, bundledFoodItems: [FoodItem] = [], cookingRunDirectory: URL? = nil) -> FernletStore {
    makeTestStoreWithRepositories(date: date, bundledFoodItems: bundledFoodItems, cookingRunDirectory: cookingRunDirectory).store
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
    cookingRunDirectory: URL? = nil,
    wrapNarrativeStore: (JournalNarrativeRepository) -> any JournalNarrativeStoring = { $0 }
) -> (store: FernletStore, repository: CoreDataFernletRepository, narratives: JournalNarrativeRepository) {
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
        foodCatalog: FoodCatalog(source: InMemoryBundledFoodSource(bundledFoodItems)),
        cookingRunDirectory: cookingRunDirectory
    )
    return (store, repository, journalNarrativeRepository)
}

/// Builds a fresh FernletStore (new in-memory coordinator → empty `sealedJournalIDs`) over an
/// EXISTING days repository + sealed narrative store, simulating a brand-new app session that
/// reads/writes the same persisted blob and sealed store. Used to reproduce the "entry sealed in a
/// prior session, then edited after it aged out of the in-memory sealed-id set" path (F1 regression).
@MainActor
func makeStoreSharingStores(
    date: Date = .now,
    repository: CoreDataFernletRepository,
    narratives: JournalNarrativeRepository
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
        foodCatalog: FoodCatalog(source: InMemoryBundledFoodSource([]))
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
