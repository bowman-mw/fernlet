import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

struct RecipeShareCodecTests {
    @MainActor
    @Test func payloadRoundTripsThroughJSON() throws {
        let fixture = makeRecipeFixture()
        let payload = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        let decoded = try RecipeShareCodec.decodePayload(from: json)

        #expect(decoded == payload)
    }

    @MainActor
    @Test func shareTextRoundTripsWithPreamble() throws {
        let fixture = makeRecipeFixture()
        let payload = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)
        let shareText = RecipeShareCodec.shareText(for: fixture.recipe, foodItems: fixture.foodItems)
        let text = "Try this after training.\n\n\(shareText)\n\nSent from Fernlet."

        let decoded = try RecipeShareCodec.decodePayload(from: text)

        #expect(decoded == payload)
    }

    @Test func decodeRejectsTextWithoutPayloadMarker() {
        #expect(throws: RecipeImportError.missingPayload) {
            try RecipeShareCodec.decodePayload(from: "Recipe: oats, yogurt, berries")
        }
    }

    @Test func decodeRejectsInvalidJSONAfterMarker() {
        #expect(throws: RecipeImportError.invalidPayload) {
            try RecipeShareCodec.decodePayload(from: "Fernlet recipe data:\n{not valid json}")
        }
    }

    @MainActor
    @Test func decodeRejectsUnsupportedFormatVersion() throws {
        let fixture = makeRecipeFixture()
        var payload = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)
        payload.version = 2
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(throws: RecipeImportError.unsupportedFormat) {
            try RecipeShareCodec.decodePayload(from: json)
        }
    }

    @MainActor
    @Test func proximityPayloadForLocalRecipePreservesSharePayload() throws {
        let fixture = makeRecipeFixture()
        let expected = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)

        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)
        let decoded = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: JSONEncoder().encode(payload))

        #expect(decoded.format == "fernlet.proximity.recipe")
        #expect(decoded.version == 1)
        #expect(decoded.recipe.kind == .local)
        #expect(decoded.recipe.local == expected)
        #expect(decoded.recipe.saved == nil)
    }

    @MainActor
    @Test func proximityPayloadForSavedRecipePreservesSavedRecipeFields() throws {
        let recipe = makeSavedRecipe()
        let webImport = try #require(recipe.webImport)

        let payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])
        let decoded = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: JSONEncoder().encode(payload))
        let saved = try #require(decoded.recipe.saved)

        #expect(decoded.recipe.kind == .saved)
        #expect(decoded.recipe.local == nil)
        #expect(saved.name == recipe.name)
        #expect(saved.sourceURLString == webImport.sourceURLString)
        #expect(saved.ingredients == webImport.ingredientLines)
        #expect(saved.summary == recipe.notes)
        #expect(saved.servings == recipe.servings)
        #expect(saved.protein == webImport.macros.protein)
        #expect(saved.carbs == webImport.macros.carbs)
        #expect(saved.fat == webImport.macros.fat)
    }

    @MainActor
    @Test func omittingShareNotesRemovesLocalRecipeNotesOnly() throws {
        let fixture = makeRecipeFixture()
        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)

        let stripped = payload.omittingShareNotes()

        #expect(payload.hasShareNotes)
        #expect(stripped.recipe.local?.notes == "")
        #expect(stripped.recipe.local?.name == payload.recipe.local?.name)
        #expect(stripped.recipe.local?.ingredients == payload.recipe.local?.ingredients)
    }

    @MainActor
    @Test func omittingShareNotesRemovesSavedRecipeSummaryOnly() {
        let payload = RecipeShareCodec.proximityPayload(for: makeSavedRecipe(), foodItems: [])

        let stripped = payload.omittingShareNotes()

        #expect(payload.hasShareNotes)
        #expect(stripped.recipe.saved?.summary == "")
        #expect(stripped.recipe.saved?.name == payload.recipe.saved?.name)
        #expect(stripped.recipe.saved?.ingredients == payload.recipe.saved?.ingredients)
    }

    @MainActor
    @Test func importProximityLocalRecipeCreatesRecipeAndIngredients() throws {
        let fixture = makeRecipeFixture()
        let store = makeTestStore()
        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)

        let importedName = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.recipes.first)

        #expect(importedName == "Training Bowl")
        #expect(imported.name == "Training Bowl")
        #expect(imported.servings == 2)
        #expect(imported.ingredients.count == 3)
        #expect(store.foodItems.filter { $0.tags.contains("imported") }.count == 3)
    }

    @MainActor
    @Test func importProximitySavedRecipeAddsSavedRecipe() throws {
        let store = makeTestStore()
        let recipe = makeSavedRecipe()
        let webImport = try #require(recipe.webImport)
        let payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])

        let importedName = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.savedRecipes.first)
        let importedWebImport = try #require(imported.webImport)

        #expect(importedName == recipe.name)
        #expect(imported.name == recipe.name)
        #expect(importedWebImport.sourceURLString == webImport.sourceURLString)
        #expect(importedWebImport.ingredientLines == webImport.ingredientLines)
        #expect(imported.notes == recipe.notes)
        #expect(imported.servings == recipe.servings)
        #expect(importedWebImport.macros == webImport.macros)
        #expect(imported.isWebImport)
    }

    @MainActor
    @Test func importProximityRecipeRejectsUnsupportedVersion() {
        let store = makeTestStore()
        var payload = RecipeShareCodec.proximityPayload(for: makeSavedRecipe(), foodItems: [])
        payload.version = 2

        #expect(throws: RecipeImportError.unsupportedFormat) {
            try store.importProximityRecipeShare(payload)
        }
    }

    private func makeRecipeFixture() -> (recipe: RecipeDefinition, foodItems: [FoodItem]) {
        let oats = foodItem(
            name: "Rolled oats",
            servingSize: 40,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 5, carbs: 27, fat: 3)
        )
        let yogurt = foodItem(
            name: "Greek yogurt",
            servingSize: 170,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 18, carbs: 6, fat: 0)
        )
        let berries = foodItem(
            name: "Blueberries",
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 1, carbs: 14, fat: 0)
        )
        let recipe = RecipeDefinition(
            name: "Training Bowl",
            servings: 2,
            ingredients: [
                RecipeIngredient(foodItemId: oats.id, quantity: 80, unit: RecipeUnit.gram.rawValue),
                RecipeIngredient(foodItemId: yogurt.id, quantity: 340, unit: RecipeUnit.gram.rawValue),
                RecipeIngredient(foodItemId: berries.id, quantity: 150, unit: RecipeUnit.gram.rawValue)
            ],
            notes: "Chill before serving.",
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
        return (recipe, [oats, yogurt, berries])
    }

    private func makeSavedRecipe() -> RecipeDefinition {
        let savedAt = Date(timeIntervalSince1970: 1_779_664_800)
        return RecipeDefinition(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000777")!,
            name: "Saved Training Bowl",
            servings: 3,
            ingredients: [],
            notes: "A saved web recipe summary.",
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/saved-training-bowl",
                ingredientLines: ["Oats", "Greek yogurt", "Blueberries"],
                macros: Macros(protein: 24, carbs: 42, fat: 6),
                micronutrients: Micronutrients()
            )
        )
    }

    private func foodItem(name: String, servingSize: Double, servingUnit: String, macros: Macros) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: servingSize,
            servingUnit: servingUnit,
            macros: macros,
            micronutrients: Micronutrients(),
            category: "test",
            source: .manual,
            tags: ["recipe"]
        )
    }
}
