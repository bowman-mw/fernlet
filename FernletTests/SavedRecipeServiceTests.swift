import Foundation
import Testing
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

        #expect(meal.confidence == "Recipe")
        #expect(meal.note == "Logged from URL recipe.")
        #expect(meal.mealType == .dinner)
        #expect(meal.quality == .good)
    }

    @Test func makeMealWithZeroMacrosUsesNoMacrosConfidenceAndNote() {
        let recipe = makeRecipe(name: "Mystery Soup", protein: 0, carbs: 0, fat: 0)

        let meal = SavedRecipeService.makeMeal(from: recipe, mealType: .lunch)

        #expect(meal.confidence == "Recipe (no macros)")
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

    private func makeService(initialRecipes: [SavedRecipe] = []) -> SavedRecipeService {
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
    ) -> SavedRecipe {
        SavedRecipe(
            id: id,
            sourceURL: URL(string: url)!,
            name: name,
            ingredients: ["One", "Two"],
            summary: "Summary",
            servings: 2,
            protein: protein,
            carbs: carbs,
            fat: fat,
            savedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
    }
}
