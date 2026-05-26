import Foundation
import Testing
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
