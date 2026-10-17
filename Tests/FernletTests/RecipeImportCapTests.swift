import Foundation
import Testing
import FernletDomainModel
import FernletSocial
import FernletExchange
import AIProviders
@testable import Fernlet

/// The ingredient cap every recipe door holds (bug-confirmation 2026-10-15, food-ai §1).
///
/// The editor, the wire decoders, the exchange validator and the web importer allowed 100 ingredients
/// while `FernletStore.RecipeImportLimits.maxIngredients` was a second constant, 60: a recipe of 61 to
/// 100 ingredients could be built and sent but was refused by every import that runs
/// `FernletStore.importRecipe(from:id:)` (paste, a nearby `.local` share, a Messages card, a Shortcuts
/// file), and a nearby `.saved` share silently kept its first 60 lines. Each cell runs at 61, the first
/// count the old cap refused, and at 100, the cap itself; one more is still refused.
@MainActor
struct RecipeImportCapTests {
    /// The counts the old import cap refused: its first over-cap count and the shared cap itself.
    nonisolated static let countsTheOldCapRefused = [61, 100]

    /// Every door names the same number, 100.
    @Test func everyRecipeDoorHoldsTheSameIngredientCap() {
        #expect(SharedRecipeLimits.maxIngredients == 100)
        #expect(FernletStore.RecipeImportLimits.maxIngredients == SharedRecipeLimits.maxIngredients)
        #expect(RecipeLimits.maxIngredients == SharedRecipeLimits.maxIngredients)
        #expect(RecipeWebImporter.maxImportedIngredients == SharedRecipeLimits.maxIngredients)
    }

    /// Editor → exchange → import, the Messages card's and the Shortcuts file's path
    /// (`ExchangeIntentService.importRecipe` hands `packet.recipe` to `importRecipe(from:id:)` as JSON).
    @Test(arguments: countsTheOldCapRefused)
    func anEditorRecipeAtTheCapImportsWholeThroughTheExchange(ingredientCount: Int) throws {
        let fixture = Self.editorRecipe(ingredientCount: ingredientCount)
        let packet = try RecipeExchangePacket(recipe: fixture.recipe, foodItems: fixture.foodItems, includesNotes: false)
        #expect(packet.recipe.ingredients.count == ingredientCount)
        let text = try #require(String(data: try JSONEncoder().encode(packet.recipe), encoding: .utf8))

        let imported = try makeTestStore().importRecipe(from: text, id: packet.originContentID)

        #expect(imported.ingredients.count == ingredientCount)
    }

    /// A nearby `.local` share, which re-encodes its payload into the same `importRecipe(from:)`.
    @Test(arguments: countsTheOldCapRefused)
    func aNearbyLocalShareAtTheCapImportsWhole(ingredientCount: Int) throws {
        let fixture = Self.editorRecipe(ingredientCount: ingredientCount)
        let store = makeTestStore()
        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)

        #expect(try store.importProximityRecipeShare(payload) == .imported(name: "Big Pot"))

        #expect(store.recipes.first?.ingredients.count == ingredientCount)
    }

    /// A nearby `.saved` (web-import) share keeps every line it carries.
    @Test(arguments: countsTheOldCapRefused)
    func aNearbySavedShareAtTheCapKeepsEveryLine(lineCount: Int) throws {
        let store = makeTestStore()
        let payload = RecipeShareCodec.proximityPayload(for: Self.savedRecipe(lineCount: lineCount), foodItems: [])

        #expect(try store.importProximityRecipeShare(payload) == .imported(name: "Long Stew"))

        let lines = try #require(store.savedRecipes.first?.webImport?.ingredientLines)
        #expect(lines.count == lineCount)
        #expect(lines.last == "Line \(lineCount - 1)")
    }

    /// The cap still holds: one ingredient more is refused, and the store gains nothing.
    @Test func oneIngredientOverTheCapIsStillRefused() {
        let fixture = Self.editorRecipe(ingredientCount: SharedRecipeLimits.maxIngredients + 1)
        let store = makeTestStore()
        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)

        #expect(throws: RecipeImportError.invalidPayload) { try store.importProximityRecipeShare(payload) }
        #expect(store.recipes.isEmpty)
    }

    // MARK: - Fixtures

    private static let fixedDate = Date(timeIntervalSince1970: 1_779_664_800)

    /// An editor-shaped recipe of `ingredientCount` distinct catalog foods, 100 g each.
    private static func editorRecipe(ingredientCount: Int) -> (recipe: RecipeDefinition, foodItems: [FoodItem]) {
        let foods = (0..<ingredientCount).map { index in
            FoodItem(
                name: "Ingredient \(index)",
                servingSize: 100,
                servingUnit: RecipeUnit.gram.rawValue,
                macros: Macros(protein: 1, carbs: 2, fat: 1),
                micronutrients: Micronutrients(),
                category: "test",
                source: .manual,
                tags: []
            )
        }
        let recipe = RecipeDefinition(
            name: "Big Pot",
            servings: 4,
            ingredients: foods.map { RecipeIngredient(foodItemId: $0.id, quantity: 100, unit: RecipeUnit.gram.rawValue) },
            notes: "",
            source: "manual",
            createdAt: fixedDate,
            updatedAt: fixedDate
        )
        return (recipe, foods)
    }

    /// A web-imported recipe carrying `lineCount` ingredient lines.
    private static func savedRecipe(lineCount: Int) -> RecipeDefinition {
        RecipeDefinition(
            name: "Long Stew",
            servings: 6,
            ingredients: [],
            notes: "",
            source: MealLogSource.webImport,
            createdAt: fixedDate,
            updatedAt: fixedDate,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/long-stew",
                ingredientLines: (0..<lineCount).map { "Line \($0)" },
                macros: Macros(protein: 30, carbs: 40, fat: 10),
                micronutrients: Micronutrients()
            )
        )
    }
}
