import XCTest
import LocalPersistence
import FernletDomainModel
import PrivateMemoryStore
import FernletPersistence
import FoodCatalog
import PrivateStoreCore
import CloudKitSync
@testable import Fernlet

/// Creates a FernletStore backed by an in-memory Core Data stack.
/// All data is discarded when the store is deallocated.
///
/// `bundledFoodItems` seeds an in-memory food catalog (the SQLite-backed bundle is not loaded in
/// tests), so tests stay deterministic — pass the specific USDA items a test needs.
@MainActor
func makeTestStore(date: Date = .now, bundledFoodItems: [FoodItem] = []) -> FernletStore {
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
    // PrivatePersistenceController.shared (a real on-device store).
    let journalNarrativeRepository = JournalNarrativeRepository(
        controller: PrivatePersistenceController(inMemory: true)
    )
    return FernletStore(
        date: date,
        repository: repository,
        savedRecipeRepository: savedRecipeRepository,
        journalNarrativeRepository: journalNarrativeRepository,
        foodCatalog: FoodCatalog(source: InMemoryBundledFoodSource(bundledFoodItems))
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
