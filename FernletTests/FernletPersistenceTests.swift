import CoreData
import LocalPersistence
import FernletFoundation
import Observation
import Testing
import Foundation
import FernletDomainModel
import PrivateMemoryStore
import FernletPersistence
import PrivateStoreCore
import CloudKitSync
@testable import Fernlet

struct FernletPersistenceTests {

    private let testDate = Calendar(identifier: .gregorian)
        .date(from: DateComponents(year: 2026, month: 5, day: 19))!

    @MainActor
    private func makeController() -> PersistenceController {
        PersistenceController(inMemory: true)
    }

    private func makeTemporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func removeTemporaryStore(at url: URL) {
        let fileManager = FileManager.default
        let sidecarExtensions = ["", "-shm", "-wal"]
        for suffix in sidecarExtensions {
            try? fileManager.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private func preferences(iCloudSyncEnabled: Bool, excludesBackup: Bool = false) -> StoragePreferences {
        StoragePreferences(
            iCloudSyncEnabled: iCloudSyncEnabled,
            localBackupExcludedFromiOSBackup: excludesBackup
        )
    }

    @MainActor
    private func makeStore(
        controller: PersistenceController,
        privateController: PrivatePersistenceController? = nil
    ) -> FernletStore {
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let repo = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL)
        )
        let activePrivate = privateController ?? PrivatePersistenceController(inMemory: true)
        let jnr = JournalNarrativeRepository(controller: activePrivate)
        return FernletStore(date: testDate, repository: repo, journalNarrativeRepository: jnr)
    }

    // MARK: - Test 1

    /// Verifies that performSnapshotSave writes to Core Data and a fresh store
    /// reading from the same container sees the persisted meal.
    @MainActor
    @Test func test_snapshotRoundTrip_mealSurvivesReload() async {
        let controller = makeController()
        let store = makeStore(controller: controller)
        store.addMeal(from: "grilled chicken 8oz", type: .lunch)
        store.flushPendingSnapshotSave()

        let reloaded = makeStore(controller: controller)
        #expect(reloaded.day.meals.contains { $0.name.localizedCaseInsensitiveContains("chicken") })
    }

    // MARK: - Test 2

    /// Verifies that meals, journal, sleep, bottleCount, memory, goal, recentMeals,
    /// and recipe all survive a save/reload cycle through Core Data.
    @MainActor
    @Test func test_snapshotRoundTrip_allPropertiesSurvive() async {
        let controller = makeController()
        let store = makeStore(controller: controller)

        store.addMeal(from: "oatmeal and eggs", type: .breakfast)
        // Text ≥ 20 chars so MemoryNote.fromJournal creates a memory entry.
        store.addJournal(text: "Feeling strong and energetic today!", tag: .good)
        store.setSleep(hours: 7.5, quality: .good, note: "Slept well")
        store.day.bottleCount = 5
        store.replaceGoals([
            FitnessGoal(
                type: .strength,
                goal: "Get stronger",
                timeframe: "12 weeks",
                metric: "Squat PR",
                weeklyStructure: nil
            )
        ])
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "Chicken"
        ingredient.protein = 30
        store.addRecipe(name: "Chicken Bowl", servings: 1, ingredients: [ingredient])
        store.flushPendingSnapshotSave()

        let reloaded = makeStore(controller: controller)
        #expect(reloaded.day.meals.count == 1)
        #expect(reloaded.day.journals.count == 1)
        #expect(reloaded.day.sleep?.hours == 7.5)
        #expect(reloaded.day.bottleCount == 5)
        #expect(reloaded.memories.count == 1)
        #expect(reloaded.goals.count == 1)
        #expect(reloaded.goals.first?.type == .strength)
        #expect(reloaded.recentMeals.count == 1)
        #expect(reloaded.recipes.contains { $0.name == "Chicken Bowl" })
    }

    // MARK: - Test 3

    /// Verifies that batchSnapshotPersistence coalesces multiple in-flight
    /// property mutations into exactly one saveSnapshot call.
    @MainActor
    @Test func test_batchPersistence_singleSaveCycle() async {
        let spy = SpyFernletRepository()
        let store = FernletStore(date: testDate, repository: spy)
        await Task.yield()  // drain any save Task from seedBundledFoodItems
        let savesBefore = spy.saveCount

        // addJournal touches day.journals, previousJournals, and memories —
        // all inside one batchSnapshotPersistence call.
        store.addJournal(text: "Testing batch persistence coalescing.", tag: .neutral)
        store.flushPendingSnapshotSave()

        #expect(spy.saveCount == savesBefore + 1)
    }

    // MARK: - Test 4

    /// Verifies that resetAll clears all in-memory collections synchronously.
    @MainActor
    @Test func test_resetAll_clearsEverything() {
        let store = makePopulatedTestStore()
        #expect(store.day.meals.isEmpty == false)

        store.resetAll()

        #expect(store.day.meals.isEmpty)
        #expect(store.day.journals.isEmpty)
        #expect(store.day.bottleCount == 0)
        #expect(store.memories.isEmpty)
        #expect(store.recipes.isEmpty)
        #expect(store.recentMeals.isEmpty)
        #expect(store.dailyScores.isEmpty)
        #expect(store.goals.isEmpty)
    }

    // MARK: - Test 5

    /// Verifies that the empty state written by resetAll is read back correctly
    /// by a fresh store sharing the same Core Data container.
    @MainActor
    @Test func test_resetAll_persistsCleanState() async {
        let controller = makeController()
        let store = makeStore(controller: controller)
        store.addMeal(from: "oatmeal", type: .breakfast)
        store.addJournal(text: "Morning journal entry here.", tag: .neutral)
        store.day.bottleCount = 3
        store.flushPendingSnapshotSave()

        store.resetAll()
        store.flushPendingSnapshotSave()

        let reloaded = makeStore(controller: controller)
        #expect(reloaded.day.meals.isEmpty)
        #expect(reloaded.day.journals.isEmpty)
        #expect(reloaded.day.bottleCount == 0)
        #expect(reloaded.memories.isEmpty)
        #expect(reloaded.goals.isEmpty)
    }

    // MARK: - Test 6

    /// Verifies that the persistent store description follows the injected iCloud preference.
    @MainActor
    @Test func test_persistenceConfiguration_followsICloudPreference() {
        let localURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: localURL) }
        let localController = PersistenceController(
            preferences: preferences(iCloudSyncEnabled: false),
            storeURL: localURL
        )

        let cloudURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: cloudURL) }
        let cloudController = PersistenceController(
            preferences: preferences(iCloudSyncEnabled: true),
            storeURL: cloudURL,
            iCloudAvailable: true
        )

        #expect(localController.activeStoreDescription?.cloudKitContainerOptions == nil)
        #expect(cloudController.activeStoreDescription?.cloudKitContainerOptions?.containerIdentifier == "iCloud.MBO.Fernlet")
    }

    // MARK: - Test 7

    /// Verifies that rebuilding the stack across cloud/local/cloud modes keeps the same local data.
    @MainActor
    @Test func test_reload_cloudLocalCloud_preservesLocalData() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }
        let controller = PersistenceController(
            preferences: preferences(iCloudSyncEnabled: true),
            storeURL: storeURL
        )
        let store = makeStore(controller: controller)
        store.addMeal(from: "salmon rice bowl", type: .dinner)
        store.flushPendingSnapshotSave()

        try await controller.reload(with: preferences(iCloudSyncEnabled: false))
        let localReloaded = makeStore(controller: controller)
        #expect(localReloaded.day.meals.contains { $0.name.localizedCaseInsensitiveContains("salmon") })

        try await controller.reload(with: preferences(iCloudSyncEnabled: true))
        let cloudReloaded = makeStore(controller: controller)
        #expect(cloudReloaded.day.meals.contains { $0.name.localizedCaseInsensitiveContains("salmon") })
    }

    @MainActor
    @Test func test_reloadFailureKeepsOriginalContainerAndStoreUsable() async throws {
        let storeURL = makeTemporaryStoreURL()
        let failingStoreURL = makeTemporaryStoreURL()
        try FileManager.default.createDirectory(at: failingStoreURL, withIntermediateDirectories: true)
        defer {
            removeTemporaryStore(at: storeURL)
            removeTemporaryStore(at: failingStoreURL)
        }

        let controller = PersistenceController(
            preferences: preferences(iCloudSyncEnabled: false),
            storeURL: storeURL
        )
        let originalContainer = controller.container
        let store = makeStore(controller: controller)
        store.addMeal(from: "lentil soup", type: .lunch)
        store.flushPendingSnapshotSave()

        controller.reloadStoreURLOverrideForTesting = failingStoreURL
        var didThrow = false
        do {
            try await controller.reload(with: preferences(iCloudSyncEnabled: false))
        } catch {
            didThrow = true
        }
        controller.reloadStoreURLOverrideForTesting = nil

        #expect(didThrow)
        #expect(controller.container === originalContainer)
        #expect(controller.container.persistentStoreCoordinator.persistentStores.isEmpty == false)

        let reloaded = makeStore(controller: controller)
        #expect(reloaded.day.meals.contains { $0.name.localizedCaseInsensitiveContains("lentil") })

        reloaded.addMeal(from: "apple slices", type: .snack)
        reloaded.flushPendingSnapshotSave()
        let savedAfterFailure = makeStore(controller: controller)
        #expect(savedAfterFailure.day.meals.contains { $0.name.localizedCaseInsensitiveContains("apple") })
    }

    // MARK: - Test 8

    /// Verifies that reload reports true during the swap and false after completion.
    @MainActor
    @Test func test_reload_updatesReloadingState() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }
        let controller = PersistenceController(
            preferences: preferences(iCloudSyncEnabled: false),
            storeURL: storeURL
        )

        #expect(controller.isReloading == false)

        // Observation fires `onChange` synchronously, inline in the property's
        // `willSet`, on whatever actor performs the mutation. `reload` flips
        // `isReloading` only on the main actor, so this callback runs on the main
        // actor too. Because the flag starts `false`, the first tracked change is
        // necessarily the `false -> true` transition at the start of `reload` — the
        // firing itself proves `isReloading` went true, with no dependency on task
        // scheduling or the timing of the store swap.
        let recorder = ReloadingObservationRecorder()
        withObservationTracking {
            _ = controller.isReloading
        } onChange: {
            MainActor.assumeIsolated {
                recorder.recordReloadingBegan()
            }
        }

        try await controller.reload(with: preferences(iCloudSyncEnabled: false))

        #expect(recorder.reloadingBegan)
        #expect(controller.isReloading == false)
    }

    // MARK: - Test 9

    /// Verifies that the persistent store file is excluded from iOS backup when requested.
    @MainActor
    @Test func test_backupExclusionPreference_marksStoreURL() throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }
        _ = PersistenceController(
            preferences: preferences(iCloudSyncEnabled: false, excludesBackup: true),
            storeURL: storeURL
        )

        let values = try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @MainActor
    @Test func test_customRecipeIngredient_savesForFutureReuse() async {
        let controller = makeController()
        let store = makeStore(controller: controller)
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "House tofu crumble"
        ingredient.protein = 18
        ingredient.carbs = 6
        ingredient.fat = 9

        let savedIngredient = store.saveCustomIngredient(ingredient)
        store.flushPendingSnapshotSave()

        let reloaded = makeStore(controller: controller)
        let matchingItems = reloaded.foodItems.filter { FoodItemSearch.normalized($0.name) == "house tofu crumble" }
        #expect(savedIngredient != nil)
        #expect(matchingItems.count == 1)
        #expect(matchingItems.first?.source == .manual)
        #expect(FoodItemSearch.results(for: "house tofu", in: reloaded.foodItems).first?.id == savedIngredient?.id)
    }

    @MainActor
    @Test func test_manualRecipeIngredient_reusesExistingCustomFoodItem() {
        let store = makeStore(controller: makeController())
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "House tofu crumble"
        ingredient.protein = 18

        let savedIngredient = store.saveCustomIngredient(ingredient)
        store.addRecipe(name: "Tofu Bowl", servings: 1, ingredients: [ingredient])

        let matchingItems = store.foodItems.filter { FoodItemSearch.normalized($0.name) == "house tofu crumble" }
        #expect(savedIngredient != nil)
        #expect(matchingItems.count == 1)
        #expect(store.recipes.first?.ingredients.first?.foodItemId == savedIngredient?.id)
    }

    // MARK: - Security: NEW-1

    /// Journal text must never appear in the iCloud-synced blob, even when no lock is configured.
    /// Entries are sealed with a device-managed key; the blob stores only stripped metadata.
    @MainActor
    @Test func test_noLock_journalTextStrippedFromBlob() {
        let controller = makeController()
        let store = makeStore(controller: controller)
        store.addJournal(text: "Sensitive diary content that must not reach iCloud.", tag: .neutral)
        store.flushPendingSnapshotSave()

        // A fresh store loaded from the same blob should never see journal text
        // unless activateNoLockJournals() / activateSealedJournals() is called first.
        let reloaded = makeStore(controller: controller)
        #expect(
            reloaded.day.journals.allSatisfy { $0.text.isEmpty },
            "Journal text must not appear in the iCloud-synced blob when no lock is configured"
        )
        #expect(
            reloaded.previousJournals.allSatisfy { $0.text.isEmpty },
            "Previous journal text must not appear in the iCloud-synced blob when no lock is configured"
        )
    }
}

// MARK: - Observation Helpers

@MainActor
private final class ReloadingObservationRecorder {
    private(set) var reloadingBegan = false

    func recordReloadingBegan() {
        reloadingBegan = true
    }
}

// MARK: - Spy

private final class SpyFernletRepository: FernletRepository, @unchecked Sendable {
    private(set) var saveCount = 0

    func loadSnapshot(todayKey: String) -> FernletSnapshot {
        FernletSnapshot(
            todayKey: todayKey,
            day: FernletDay(date: todayKey),
            settings: FernletSettings(),
            recentMeals: [],
            previousJournals: [],
            memories: [],
            goals: [],
            workshop: WorkshopData()
        )
    }

    @discardableResult func saveSnapshot(_ snapshot: FernletSnapshot) -> Bool {
        saveCount += 1
        return true
    }

    @discardableResult func updateDay(_ day: FernletDay, for dateKey: String, todayKey: String) -> Bool { true }
    func storageDescription() -> String { "spy" }
    func loadAllDays() -> [String: FernletDay] { [:] }
    func loadTierTwoMemories() -> [TierTwoMemoryRecord] { [] }
}
