import Foundation
import Testing
import CoreData
import FernletDomainModel
import CloudKitSync
@testable import Fernlet

/// Multipart recipes (owner decision 2026-09-24): the model, its one resolution rule, and everything
/// that must keep "respecting parts": nutrition, "cook for N" scaling, grocery aggregation, logging, the
/// substitution fork, and both persistence paths (the synced blob and `SavedRecipeRecord.payloadData`).
/// The canonical fixture is ``RecipeMultipartFixtures``, a salad with a homemade dressing.
@MainActor
struct RecipeMultipartTests {

    // MARK: - The resolution rule

    @Test func aRecipeWithoutPartsResolvesToOneImplicitPart() {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        recipe.components = nil

        let parts = recipe.resolvedComponents
        #expect(parts.count == 1)
        #expect(parts.first?.name == nil)
        #expect(parts.first?.id == recipe.id)
        #expect(parts.first?.ingredients == recipe.ingredients)
        #expect(parts.first?.steps == recipe.steps)
        #expect(recipe.isMultipart == false)
    }

    @Test func theSaladResolvesToItsTwoPartsInMakingOrder() throws {
        let recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe

        let parts = recipe.resolvedComponents
        try #require(parts.count == 2)
        #expect(recipe.isMultipart)
        #expect(parts.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
        #expect(parts.map(\.ingredients.count) == [4, 5])
        #expect(parts[0].steps == RecipeMultipartFixtures.dressingSteps)
        #expect(parts[1].steps == RecipeMultipartFixtures.saladSteps)
    }

    @Test func everyFlatRowLandsInExactlyOnePart() throws {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        let stray = RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "cup")
        recipe.ingredients.append(stray)                                   // claimed by no part
        var parts = try #require(recipe.components)
        parts[1].ingredientIDs.insert(recipe.ingredients[0].id, at: 0)      // claimed twice: first claim wins
        parts[0].ingredientIDs.append(UUID())                               // claims a row that doesn't exist
        recipe.components = parts

        let resolved = recipe.resolvedComponents
        try #require(resolved.count == 2)
        let resolvedIDs = resolved.flatMap(\.ingredients).map(\.id)
        #expect(resolvedIDs.count == recipe.ingredients.count)
        #expect(Set(resolvedIDs) == Set(recipe.ingredients.map(\.id)))
        #expect(resolved[0].ingredients.first?.id == recipe.ingredients[0].id)   // stayed with the dressing
        #expect(resolved[1].ingredients.last?.id == stray.id)                     // unclaimed → the last part
    }

    @Test func emptyPartsDropAndFewerThanTwoCollapseToOnePart() throws {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        var parts = try #require(recipe.components)
        parts.insert(RecipeComponent(name: "Nothing yet"), at: 1)
        recipe.components = parts
        #expect(recipe.resolvedComponents.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])

        recipe.components = [RecipeComponent(name: "Everything", ingredientIDs: recipe.ingredients.map(\.id),
                                             stepIDs: (recipe.steps ?? []).map(\.id)),
                             RecipeComponent(name: "Empty")]
        #expect(recipe.resolvedComponents.count == 1)
        #expect(recipe.resolvedComponents.first?.name == nil)
        #expect(recipe.isMultipart == false)
    }

    @Test func onlyTheFirstTwelvePartsAreHonoured() {
        let ingredients = (0..<13).map { _ in RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "cup") }
        let recipe = RecipeDefinition(
            name: "Thirteen", servings: 1, ingredients: ingredients, source: "manual",
            createdAt: Date(), updatedAt: Date(),
            components: ingredients.enumerated().map { RecipeComponent(name: "P\($0.offset)", ingredientIDs: [$0.element.id]) }
        )

        let resolved = recipe.resolvedComponents
        #expect(resolved.count == RecipeComponentLimits.maxComponents)
        #expect(resolved.last?.ingredients.count == 2)   // the 13th part's row joins the 12th
        #expect(resolved.flatMap(\.ingredients).count == 13)
    }

    @Test func partNamesAreNormalizedEverywhereTheyEnter() {
        #expect(RecipeComponentNaming.normalized("  Dressing  ", position: 0) == "Dressing")
        #expect(RecipeComponentNaming.normalized("Pickled\nonions", position: 0) == "Pickled onions")
        #expect(RecipeComponentNaming.normalized(String(repeating: "x", count: 55), position: 0).count == 40)
        #expect(RecipeComponentNaming.normalized("   ", position: 1) == RecipeComponentNaming.fallbackName(position: 1))
        #expect(RecipeComponentNaming.normalized("👩‍🍳 Chef's sauce", position: 0) == "👩‍🍳 Chef's sauce")
        #expect(RecipeComponentNaming.fallbackName(position: 1).contains("2"))
    }

    @Test func cookingStepsWalkPartByPartCarryingTheirPartName() {
        let recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe

        let walk = recipe.cookingSteps
        #expect(walk.map(\.step) == RecipeMultipartFixtures.dressingSteps + RecipeMultipartFixtures.saladSteps)
        #expect(walk.map(\.partName) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.dressingName,
                                         RecipeMultipartFixtures.saladName, RecipeMultipartFixtures.saladName,
                                         RecipeMultipartFixtures.saladName])

        var onePart = recipe
        onePart.components = nil
        #expect(onePart.cookingSteps.allSatisfy { $0.partName == nil })
        #expect(onePart.cookingSteps.map(\.step) == recipe.steps)
    }

    // MARK: - Persistence: the synced blob (v1 and v2 shapes)

    @Test func aOnePartRecipeEncodesNoComponentsKey() throws {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        recipe.components = nil
        let json = try #require(String(data: iso8601Encoder().encode(recipe), encoding: .utf8))
        #expect(!json.contains("components"))
        #expect(try iso8601Decoder().decode(RecipeDefinition.self, from: Data(json.utf8)) == recipe)
    }

    @Test func aMultipartRecipeRoundTripsThroughTheBlob() throws {
        let recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        let decoded = try iso8601Decoder().decode(RecipeDefinition.self, from: iso8601Encoder().encode(recipe))
        #expect(decoded == recipe)
        #expect(decoded.resolvedComponents.map(\.ingredients.count) == [4, 5])
    }

    @Test func aPartWithMissingFieldsDecodesTolerantly() throws {
        let json = #"{"name":"Dressing"}"#
        let part = try JSONDecoder().decode(RecipeComponent.self, from: Data(json.utf8))
        #expect(part.name == "Dressing")
        #expect(part.ingredientIDs.isEmpty)
        #expect(part.stepIDs.isEmpty)
    }

    /// Mirror of the PRE-multipart `RecipeDefinition`: deliberately has NO `components`. An un-updated
    /// paired device decodes and re-encodes the synced blob through exactly this shape.
    private struct PreMultipartRecipe: Codable {
        var id: UUID
        var name: String
        var servings: Int
        var ingredients: [RecipeIngredient]
        var notes: String
        var source: String
        var createdAt: Date
        var updatedAt: Date
        var steps: [RecipeStep]?
    }

    @Test func anOlderDevicesRewriteDegradesToACorrectOnePartRecipe() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let older = try iso8601Decoder().decode(PreMultipartRecipe.self, from: iso8601Encoder().encode(salad.recipe))
        let stripped = try iso8601Decoder().decode(RecipeDefinition.self, from: iso8601Encoder().encode(older))

        #expect(stripped.components == nil)
        #expect(stripped.ingredients == salad.recipe.ingredients)
        #expect(stripped.steps == salad.recipe.steps)
        #expect(MealBuilder.macroTotals(for: stripped, foodItems: salad.foodItems)
                == MealBuilder.macroTotals(for: salad.recipe, foodItems: salad.foodItems))
    }

    @Test func partsSurviveTheSavedRecipePayloadDataPath() throws {
        let repository = SavedRecipeRepository(
            controller: PersistenceController(inMemory: true),
            legacyRepository: LegacySavedRecipeJSONRepository(fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("multipart-\(UUID().uuidString).json")),
            defaults: try #require(UserDefaults(suiteName: UUID().uuidString))
        )
        let recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe

        #expect(repository.upsert([recipe]))
        let reloaded = try #require(repository.load().first)
        #expect(reloaded.components == recipe.components)
        #expect(reloaded.isMultipart)
    }

    // MARK: - Nutrition, logging, scaling, grocery: every part counts, once

    @Test func nutritionCountsEveryPartExactlyOnce() {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let whole = MealBuilder.macroTotals(for: salad.recipe, foodItems: salad.foodItems)
        #expect(whole == MacroTotals(protein: 12, carbs: 56, fat: 58))

        let perPart = salad.recipe.resolvedComponents.map { part -> MacroTotals in
            var only = salad.recipe
            only.ingredients = part.ingredients
            only.components = nil
            return MealBuilder.macroTotals(for: only, foodItems: salad.foodItems)
        }
        #expect(perPart == [MacroTotals(protein: 0, carbs: 8, fat: 42), MacroTotals(protein: 12, carbs: 48, fat: 16)])
    }

    @Test func loggingAServingTakesAShareOfEveryPart() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let meal = try #require(MealBuilder.mealFromRecipe(salad.recipe, mealType: .lunch, foodItems: salad.foodItems))
        #expect(meal.componentSnapshots.count == 9)   // every row of both parts, each once
        #expect(meal.componentSnapshots.contains { $0.name == "Honey" })
        #expect(meal.componentSnapshots.contains { $0.name == "Bread cubes" })
        // The serving's fat is the dressing's share plus the croutons' share (each component rounds on
        // its own quarter, so the sum is compared rather than 58 / 4).
        #expect(meal.macros.fat == meal.componentSnapshots.reduce(0) { $0 + $1.macros.fat })
        #expect(meal.macros.fat >= 14)
    }

    @Test func scalingScalesEveryPartAndKeepsTheGrouping() throws {
        let recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        let scaled = RecipeScaling.scaledIngredients(recipe, forYield: 8)
        #expect(scaled.map(\.id) == recipe.ingredients.map(\.id))
        #expect(scaled.map(\.quantity) == recipe.ingredients.map { $0.quantity * 2 })

        let shown = RecipePartsLayout.parts(of: recipe, displaying: scaled)
        try #require(shown.count == 2)
        #expect(shown.map(\.ingredients.count) == [4, 5])
        #expect(shown[0].ingredients.first?.quantity == 6)   // 3 tbsp of oil in the dressing, doubled
        #expect(shown[1].ingredients.last?.quantity == 2)    // 1 tbsp for the croutons, doubled
    }

    @Test func groceryListMergesTheOilBothPartsUse() {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let store = makeTestStore(bundledFoodItems: salad.foodItems)

        let list = store.groceryList(for: [.init(recipe: salad.recipe)])
        let oil = list.consolidated.filter { $0.name == "Olive oil" }
        #expect(oil == [GroceryAggregation.Line(name: "Olive oil", quantity: 4, unit: "tbsp")])
        #expect(list.consolidated.count == 8)   // nine rows, one food shared by both parts
        #expect(list.consolidated.contains { $0.name == "Honey" })

        let doubled = store.groceryList(for: [.init(recipe: salad.recipe, yieldOverride: 8)])
        #expect(doubled.consolidated.first { $0.name == "Olive oil" }?.quantity == 8)
    }

    // MARK: - The user's data export says which part each line belongs to

    @Test func theDataExportLabelsEachLineWithItsPart() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let names = Dictionary(uniqueKeysWithValues: salad.foodItems.map { ($0.id, $0.name) })

        let ingredients = try #require(FernletStore.recipeIngredientLines(salad.recipe, nameByFoodID: names))
        #expect(ingredients.first == "Lemon-dijon dressing: Olive oil (3 tbsp)")
        #expect(ingredients.last == "Salad: Olive oil (1 tbsp)")
        let steps = try #require(FernletStore.recipeStepLines(salad.recipe))
        #expect(steps.first == "Lemon-dijon dressing: Whisk the lemon juice, mustard and honey.")
        #expect(steps[2] == "Salad: Toss the bread cubes with the olive oil and toast until golden. (8 min timer)")

        var onePart = salad.recipe
        onePart.components = nil
        #expect(FernletStore.recipeIngredientLines(onePart, nameByFoodID: names)?.first == "Olive oil (3 tbsp)")
        #expect(FernletStore.recipeStepLines(onePart)?.first == "Whisk the lemon juice, mustard and honey.")
    }

    // MARK: - The substitution fork keeps its parts

    @Test func aForkRepointsTheReplacedRowInsideItsPart() throws {
        let salad = RecipeMultipartFixtures.saladWithHomemadeDressing()
        let honey = salad.recipe.ingredients[3]
        let maple = RecipeIngredient(foodItemId: UUID(), quantity: 1, unit: "tsp")

        let fork = try #require(RecipeSubstitution.fork(source: salad.recipe, replacing: honey.id, with: maple))
        let parts = fork.resolvedComponents
        try #require(parts.count == 2 && salad.recipe.resolvedComponents.count == 2)
        #expect(parts.map(\.name) == [RecipeMultipartFixtures.dressingName, RecipeMultipartFixtures.saladName])
        #expect(parts[0].ingredients.map(\.id).contains(maple.id))
        #expect(!parts[0].ingredients.map(\.id).contains(honey.id))
        #expect(parts[1].ingredients == salad.recipe.resolvedComponents[1].ingredients)
    }

    // MARK: - Helpers

    private func iso8601Encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private func iso8601Decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
