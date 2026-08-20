import Foundation
import Testing
import FernletDomainModel
import FernletScoring
import FernletPersistence
import CloudKitSync
import StoreCore
@testable import Fernlet

@MainActor
struct SavedRecipeServiceTests {
    @Test func addInsertsAtFrontAndDeduplicatesBySourceURLString() {
        let service = makeService()
        let first = makeRecipe(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, url: "https://example.com/recipe", name: "First")
        let replacement = makeRecipe(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, url: "https://example.com/recipe", name: "Replacement")
        let other = makeRecipe(id: UUID(uuidString: "00000000-0000-0000-0000-000000000003")!, url: "https://example.com/other", name: "Other")

        service.add(first)
        service.add(other)
        service.add(replacement)

        #expect(service.savedRecipes == [replacement, other])
    }

    @Test func updateReplacesMatchingRecipeAndNoOpsWhenMissing() {
        let existing = makeRecipe(name: "Existing")
        let updated = makeRecipe(id: existing.id, name: "Updated")
        let missing = makeRecipe(name: "Missing")
        let service = makeService(initialRecipes: [existing])

        service.update(missing)
        #expect(service.savedRecipes == [existing])

        service.update(updated)
        #expect(service.savedRecipes == [updated])
    }

    @Test func deleteRemovesByID() {
        let first = makeRecipe(name: "First")
        let second = makeRecipe(name: "Second")
        let service = makeService(initialRecipes: [first, second])

        service.delete(first)

        #expect(service.savedRecipes == [second])
    }

    @Test func makeMealWithMacrosUsesRecipeConfidenceAndLoggedNote() {
        let recipe = makeRecipe(name: "Protein Pasta", protein: 32, carbs: 40, fat: 12)

        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: .dinner)

        #expect(meal.confidence == MealConfidence.recipe.token)
        #expect(meal.note == "Logged from URL recipe.")
        #expect(meal.mealType == .dinner)
        #expect(meal.quality == .good)
    }

    @Test func makeMealWithZeroMacrosUsesNoMacrosConfidenceAndNote() {
        let recipe = makeRecipe(name: "Mystery Soup", protein: 0, carbs: 0, fat: 0)

        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: .lunch)

        #expect(meal.confidence == MealConfidence.recipeNoMacros.token)
        #expect(meal.note.contains("Macros not available."))
        #expect(meal.mealType == .lunch)
    }

    @Test func makeMealWithNilMealTypeFallsBackToClassification() {
        let recipe = makeRecipe(name: "Breakfast oats", protein: 8, carbs: 32, fat: 6)

        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: nil)

        #expect(meal.mealType == MealParser.classifyMealType(recipe.name))
    }

    @Test func persistenceRoundTripReloadsSavedRecipes() async {
        let controller = PersistenceController(inMemory: true)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let repository = SavedRecipeRepository(
            controller: controller,
            legacyRepository: LegacySavedRecipeJSONRepository(fileURL: legacyURL)
        )
        let recipe = makeRecipe(name: "Persisted", protein: 10, carbs: 20, fat: 5)
        let savingService = SavedRecipeService(repository: repository)

        savingService.add(recipe)
        savingService.flushPendingSave()

        let reloadedService = SavedRecipeService(repository: repository)
        await reloadedService.loadAsync()

        #expect(reloadedService.savedRecipes == [recipe])
    }

    @Test func reloadRetainsPendingRecipeWhenFlushFailsThenPersistsOnceOnRecovery() {
        // A saved recipe whose flush WRITE fails must not vanish from the in-memory list when
        // `reloadFromStore()` re-reads the (empty) store, and must persist exactly once — no duplicate — once
        // the store recovers and a later flush succeeds. Mirrors the CustomItemService reload regression.
        let repo = StubSavedRecipeRepository()
        let service = SavedRecipeService(repository: repo)
        let recipe = makeRecipe(name: "Pending")

        repo.failWrites = true
        service.add(recipe)
        service.reloadFromStore() // flush fails, then loadSync() reads the empty store

        // Still present in memory even though the store has nothing.
        #expect(service.savedRecipes == [recipe])
        #expect(repo.store.isEmpty)

        // Store recovers; the retained pending upsert flushes and persists exactly once.
        repo.failWrites = false
        service.flushPendingSave()
        #expect(repo.store == [recipe])

        // A subsequent reload is a no-op (queues empty) and does not duplicate the row.
        service.reloadFromStore()
        #expect(service.savedRecipes == [recipe])
    }

    private func makeService(initialRecipes: [RecipeDefinition] = []) -> SavedRecipeService {
        let controller = PersistenceController(inMemory: true)
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        return SavedRecipeService(
            repository: SavedRecipeRepository(
                controller: controller,
                legacyRepository: LegacySavedRecipeJSONRepository(fileURL: legacyURL)
            ),
            initialRecipes: initialRecipes
        )
    }

    private func makeRecipe(
        id: UUID = UUID(),
        url: String = "https://example.com/recipe-\(UUID().uuidString)",
        name: String = "Recipe",
        protein: Int = 12,
        carbs: Int = 24,
        fat: Int = 8
    ) -> RecipeDefinition {
        let savedAt = Date(timeIntervalSince1970: 1_779_664_800)
        return RecipeDefinition(
            id: id,
            name: name,
            servings: 2,
            ingredients: [],
            notes: "Summary",
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: url,
                ingredientLines: ["One", "Two"],
                macros: Macros(protein: protein, carbs: carbs, fat: fat),
                micronutrients: Micronutrients()
            )
        )
    }
}

/// An in-memory, append/upsert-only saved-recipe repo. `failWrites` simulates a Core Data write error (the
/// context rolls back → nothing persisted) so tests can exercise the failed-flush retry path.
@MainActor
private final class StubSavedRecipeRepository: SavedRecipeRepositoring {
    private(set) var byID: [UUID: RecipeDefinition] = [:]
    var failWrites = false
    var store: [RecipeDefinition] { Array(byID.values) }
    func load() -> [RecipeDefinition] { store }
    func loadAsync() async -> [RecipeDefinition] { store }
    @discardableResult func upsert(_ recipes: [RecipeDefinition]) -> Bool {
        if failWrites { return false } // rolled back — nothing persisted
        for recipe in recipes { byID[recipe.id] = recipe }
        return true
    }
    @discardableResult func delete(ids: [UUID]) -> Bool {
        if failWrites { return false }
        for id in ids { byID[id] = nil }
        return true
    }
    @discardableResult func deleteAll() -> Bool { byID.removeAll(); return true }
}
