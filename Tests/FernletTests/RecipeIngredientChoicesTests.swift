import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Recipes as building blocks, step 3: which saved recipes the editor offers as an ingredient, the
/// amount units a recipe line is typed in, and the recipe's own "Makes" amount.
@MainActor
struct RecipeIngredientChoicesTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated private static func recipe(_ name: String, servings: Int = 4, lines: [RecipeIngredient] = [],
                                           makes: RecipeYield? = nil) -> RecipeDefinition {
        RecipeDefinition(name: name, servings: servings, ingredients: lines, source: "manual",
                         createdAt: now, updatedAt: now, makes: makes)
    }

    @Test func searchMatchesEveryWordExactNameFirstAtMostThree() {
        let recipes = ["Tahini dressing", "Lemon tahini sauce", "Dressing, tahini", "Tahini", "Tahini cookies"].map { Self.recipe($0) }
        let found = RecipeIngredientChoices.matches(for: "tahini", in: recipes)
        #expect(found.map(\.name) == ["Tahini", "Tahini dressing", "Tahini cookies"])
        #expect(RecipeIngredientChoices.matches(for: "tah dres", in: recipes).map(\.name) == ["Tahini dressing", "Dressing, tahini"])
        #expect(RecipeIngredientChoices.matches(for: "  ", in: recipes).isEmpty)
    }

    @Test func choicesLeaveOutLoopsAndChainsTooDeep() {
        let caramel = Self.recipe("Caramel")
        let frosting = Self.recipe("Frosting", lines: [RecipeFood.line(using: caramel, servings: 1)])
        let cake = Self.recipe("Cake", lines: [RecipeFood.line(using: frosting, servings: 1)])
        let sauce = Self.recipe("Sauce")
        let all = [caramel, frosting, cake, sauce]
        let graph = RecipeNestingGraph(recipes: all)

        let forCaramel = RecipeIngredientChoices.usable(from: all.filter { $0.id != caramel.id }, editing: caramel.id, graph: graph)
        #expect(forCaramel.isEmpty)   // the frosting and cake use it; the sauce would make four levels
        let forSauce = RecipeIngredientChoices.usable(from: all.filter { $0.id != sauce.id }, editing: sauce.id, graph: graph)
        #expect(forSauce.map(\.name) == ["Caramel", "Frosting"])
        let forNew = RecipeIngredientChoices.usable(from: all, editing: nil, graph: graph)
        #expect(forNew.map(\.name) == ["Caramel", "Frosting", "Sauce"])
    }

    @Test func amountUnitsConvertToServings() {
        let sauce = Self.recipe("Sauce", servings: 4, makes: RecipeYield(quantity: 2, unit: "cup"))
        let choices = RecipeAmountUnit.choices(for: sauce)
        #expect(choices.count == 3)
        #expect(RecipeAmountUnit.batches.servingsPerUnit(of: sauce) == 4)
        #expect(choices[2].servingsPerUnit(of: sauce) == 2)            // one cup is two servings
        #expect(choices[2].amount(forServings: 1, of: sauce) == 0.5)   // one serving is half a cup
        #expect(RecipeAmountUnit.choices(for: Self.recipe("Plain")).count == 2)
    }

    @Test func makesDecodesTolerantlyAndIsOmittedWhenAbsent() throws {
        let plain = Self.recipe("Plain")
        #expect(!String(decoding: try JSONEncoder().encode(plain), as: UTF8.self).contains("makes"))
        let sauce = Self.recipe("Sauce", makes: RecipeYield(quantity: 2, unit: "cup"))
        let round = try JSONDecoder().decode(RecipeDefinition.self, from: JSONEncoder().encode(sauce))
        #expect(round.makes == RecipeYield(quantity: 2, unit: "cup"))

        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(plain)) as? [String: Any])
        json["makes"] = ["quantity": -1, "unit": "cup"]
        let negative = try JSONDecoder().decode(RecipeDefinition.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(negative.makes == nil)
        json["makes"] = ["quantity": 2, "unit": "each"]
        #expect(try JSONDecoder().decode(RecipeDefinition.self, from: JSONSerialization.data(withJSONObject: json)).makes == nil)
        json["makes"] = "two cups"
        #expect(try JSONDecoder().decode(RecipeDefinition.self, from: JSONSerialization.data(withJSONObject: json)).makes == nil)
    }

    @Test func theStoreOffersRecipesAndPreparesAPickedOnesFood() throws {
        let store = makeTestStore()
        let sauce = store.addRecipe(name: "Tahini dressing", servings: 2,
                                    ingredients: [ManualRecipeIngredientInput(name: "Tahini", quantity: 30, unit: "g",
                                                                              protein: 5, carbs: 3, fat: 16)])
        let bowl = store.addRecipe(name: "Grain bowl", servings: 1,
                                   ingredients: [ManualRecipeIngredientInput(name: "Rice", quantity: 150, unit: "g",
                                                                             protein: 4, carbs: 40, fat: 1)])
        #expect(store.recipeIngredientChoices(editing: bowl.id).map(\.id) == [sauce.id])
        #expect(!store.foodItems.contains { $0.id == sauce.id })
        let food = try #require(store.prepareRecipeFood(for: sauce))
        #expect(food.isRecipeFood)
        // Left unused, the next sync removes it.
        store.syncRecipeFoods()
        #expect(!store.foodItems.contains { $0.id == sauce.id })

        store.setRecipeMakes(RecipeYield(quantity: 1, unit: "cup"), forRecipeID: sauce.id)
        #expect(store.recipes.first { $0.id == sauce.id }?.makes == RecipeYield(quantity: 1, unit: "cup"))
        store.setRecipeMakes(RecipeYield(quantity: 0, unit: "cup"), forRecipeID: sauce.id)
        #expect(store.recipes.first { $0.id == sauce.id }?.makes == nil)
    }
}
