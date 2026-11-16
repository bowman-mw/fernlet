import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// Recipes as building blocks, step 1 (Docs/Recipes-As-Building-Blocks-Design-2026-11-15.md): the
/// recipe food that stands in for a recipe used as an ingredient, and the bounded "uses" graph.
@MainActor
struct RecipeBuildingBlocksTests {

    // MARK: - Fixtures

    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated private static func food(_ name: String, grams: Double, protein: Int, carbs: Int, fat: Int) -> FoodItem {
        FoodItem(name: name, servingSize: grams, servingUnit: "g",
                 macros: Macros(protein: protein, carbs: carbs, fat: fat),
                 micronutrients: Micronutrients(), category: "custom ingredient", source: .manual, tags: [])
    }

    nonisolated private static func recipe(_ name: String, servings: Int, lines: [RecipeIngredient], id: UUID = UUID()) -> RecipeDefinition {
        RecipeDefinition(id: id, name: name, servings: servings, ingredients: lines,
                         source: "manual", createdAt: now, updatedAt: now)
    }

    nonisolated private static func grams(_ food: FoodItem, _ amount: Double) -> RecipeIngredient {
        RecipeIngredient(foodItemId: food.id, quantity: amount, unit: "g")
    }

    // MARK: - The recipe food

    @Test func theRecipeFoodIsTheRecipesWholeBatchUnderTheRecipesOwnID() throws {
        let oil = Self.food("Olive oil", grams: 100, protein: 0, carbs: 0, fat: 100)
        let lemon = Self.food("Lemon juice", grams: 100, protein: 0, carbs: 7, fat: 0)
        let dressing = Self.recipe("Lemon dressing", servings: 4, lines: [Self.grams(oil, 60), Self.grams(lemon, 30)])

        let made = try #require(RecipeFood.make(for: dressing, foodItems: [oil, lemon]))
        #expect(made.id == dressing.id)
        #expect(made.isRecipeFood)
        #expect(made.name == "Lemon dressing")
        #expect(made.category == FoodItem.recipeFoodCategory)
        #expect(made.servingSize == 4)
        #expect(made.servingUnit == "serving")
        let whole = MealBuilder.macroTotals(for: dressing, foodItems: [oil, lemon])
        #expect(made.macros == Macros(protein: whole.protein, carbs: whole.carbs, fat: whole.fat))
    }

    @Test func usingEveryServingOfASubRecipeTotalsExactlyWhatItsRowsDid() throws {
        let oil = Self.food("Olive oil", grams: 100, protein: 0, carbs: 0, fat: 100)
        let lemon = Self.food("Lemon juice", grams: 100, protein: 1, carbs: 7, fat: 0)
        let greens = Self.food("Greens", grams: 100, protein: 3, carbs: 4, fat: 1)
        let dressing = Self.recipe("Lemon dressing", servings: 3, lines: [Self.grams(oil, 47), Self.grams(lemon, 23)])
        let dressingFood = try #require(RecipeFood.make(for: dressing, foodItems: [oil, lemon]))

        let inline = Self.recipe("Salad", servings: 3,
                                 lines: [Self.grams(oil, 47), Self.grams(lemon, 23), Self.grams(greens, 210)])
        let nested = Self.recipe("Salad", servings: 3,
                                 lines: [RecipeFood.line(using: dressing, servings: 3), Self.grams(greens, 210)])
        let foods = [oil, lemon, greens, dressingFood]
        #expect(MealBuilder.macroTotals(for: nested, foodItems: foods)
                == MealBuilder.macroTotals(for: inline, foodItems: foods))
    }

    @Test func partOfASubRecipeScalesItsBatchByServings() throws {
        let sugar = Self.food("Sugar", grams: 100, protein: 0, carbs: 100, fat: 0)
        let sauce = Self.recipe("Sauce", servings: 4, lines: [Self.grams(sugar, 80)])
        let sauceFood = try #require(RecipeFood.make(for: sauce, foodItems: [sugar]))
        let pasta = Self.recipe("Pasta", servings: 1, lines: [RecipeFood.line(using: sauce, servings: 1)])
        #expect(MealBuilder.macroTotals(for: pasta, foodItems: [sauceFood]).carbs == 20)
    }

    @Test func aLineToARecipeIsAPlainFoodLineEveryBuildReads() throws {
        let sauce = Self.recipe("Sauce", servings: 2, lines: [])
        let line = RecipeFood.line(using: sauce, servings: 1.5)
        #expect(line.foodItemId == sauce.id)
        #expect(line.unit == "serving")
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any]
        #expect(Set(json?.keys.map { $0 } ?? []) == ["id", "foodItemId", "quantity", "unit"])
    }

    @Test func aRecipeWhoseLinesDoNotResolveMakesNoRecipeFood() {
        let missing = RecipeIngredient(foodItemId: UUID(), quantity: 10, unit: "g")
        #expect(RecipeFood.make(for: Self.recipe("Ghost", servings: 1, lines: [missing]), foodItems: []) == nil)
        #expect(RecipeFood.make(for: Self.recipe("Empty", servings: 1, lines: []), foodItems: []) == nil)
    }

    @Test func aWebImportedRecipeFoodIsItsPerServingNutritionTimesItsServings() throws {
        var imported = Self.recipe("Web soup", servings: 4, lines: [])
        imported.webImport = RecipeWebImport(sourceURLString: "https://example.com/soup", ingredientLines: ["water"],
                                             macros: Macros(protein: 5, carbs: 10, fat: 2), micronutrients: Micronutrients())
        let made = try #require(RecipeFood.make(for: imported, foodItems: []))
        #expect(made.macros == Macros(protein: 20, carbs: 40, fat: 8))
    }

    @Test func aRecipeFoodRoundTripsItsSourceToken() throws {
        let sugar = Self.food("Sugar", grams: 100, protein: 0, carbs: 100, fat: 0)
        let made = try #require(RecipeFood.make(for: Self.recipe("Syrup", servings: 1, lines: [Self.grams(sugar, 10)]),
                                                foodItems: [sugar]))
        let data = try JSONEncoder().encode(made)
        #expect(String(decoding: data, as: UTF8.self).contains("\"recipe\""))
        #expect(try JSONDecoder().decode(FoodItem.self, from: data).source == .recipe)
    }

    @Test func aRecipeFoodIsNeverCountedAsALineWithoutNutrition() throws {
        let water = Self.food("Water", grams: 100, protein: 0, carbs: 0, fat: 0)
        let blank = Self.recipe("Blank", servings: 1, lines: [Self.grams(water, 100)])
        let blankFood = try #require(RecipeFood.make(for: blank, foodItems: [water]))
        let parent = Self.recipe("Parent", servings: 1, lines: [RecipeFood.line(using: blank, servings: 1)])
        #expect(RecipeNutritionGaps.linesWithoutNutrition(in: parent, foodItems: [blankFood]) == 0)
        #expect(RecipeNutritionGaps.linesWithoutNutrition(in: blank, foodItems: [water]) == 1)
    }

    // MARK: - The "uses" graph

    /// cake → frosting → caramel, plus a lone sauce.
    private struct Chain {
        let caramel = RecipeBuildingBlocksTests.recipe("Caramel", servings: 1, lines: [])
        let frosting: RecipeDefinition
        let cake: RecipeDefinition
        let sauce = RecipeBuildingBlocksTests.recipe("Sauce", servings: 1, lines: [])
        init() {
            frosting = RecipeBuildingBlocksTests.recipe("Frosting", servings: 1,
                                                        lines: [RecipeFood.line(using: caramel, servings: 1)])
            cake = RecipeBuildingBlocksTests.recipe("Cake", servings: 1,
                                                    lines: [RecipeFood.line(using: frosting, servings: 1)])
        }
        var all: [RecipeDefinition] { [caramel, frosting, cake, sauce] }
        var graph: RecipeNestingGraph { RecipeNestingGraph(recipes: all) }
    }

    @Test func heightsAndLevelsCountTheChain() {
        let chain = Chain()
        #expect(chain.graph.height(of: chain.cake.id) == 3)
        #expect(chain.graph.height(of: chain.caramel.id) == 1)
        #expect(chain.graph.levelsAbove(chain.caramel.id) == 2)
        #expect(chain.graph.levelsAbove(chain.cake.id) == 0)
        #expect(chain.graph.isUsed(chain.frosting.id))
        #expect(!chain.graph.isUsed(chain.cake.id))
    }

    @Test func aRecipeCannotUseItselfOrAnythingThatUsesIt() {
        let chain = Chain()
        #expect(chain.graph.refusal(adding: chain.cake.id, to: chain.cake.id) == .loop)
        #expect(chain.graph.refusal(adding: chain.cake.id, to: chain.caramel.id) == .loop)
        #expect(chain.graph.refusal(adding: chain.frosting.id, to: chain.caramel.id) == .loop)
    }

    @Test func aChainMayNotPassThreeLevels() {
        let chain = Chain()
        // The sauce under the caramel would make cake → frosting → caramel → sauce.
        #expect(chain.graph.refusal(adding: chain.sauce.id, to: chain.caramel.id) == .tooDeep)
        // The cake under the sauce would make sauce → cake → frosting → caramel.
        #expect(chain.graph.refusal(adding: chain.cake.id, to: chain.sauce.id) == .tooDeep)
        // The sauce beside the caramel, or the frosting under the sauce, fit in three.
        #expect(chain.graph.refusal(adding: chain.sauce.id, to: chain.frosting.id) == nil)
        #expect(chain.graph.refusal(adding: chain.frosting.id, to: chain.sauce.id) == nil)
    }

    @Test func refreshOrderPutsEachRecipeAfterEverythingBetweenItAndTheChange() {
        // Diamond: the bowl uses the dressing and the sauce; the sauce uses the dressing.
        let dressing = Self.recipe("Dressing", servings: 1, lines: [])
        let sauce = Self.recipe("Sauce", servings: 1, lines: [RecipeFood.line(using: dressing, servings: 1)])
        let bowl = Self.recipe("Bowl", servings: 1, lines: [RecipeFood.line(using: dressing, servings: 1),
                                                            RecipeFood.line(using: sauce, servings: 1)])
        let graph = RecipeNestingGraph(recipes: [bowl, sauce, dressing])
        #expect(graph.refreshOrder(after: dressing.id) == [sauce.id, bowl.id])
        #expect(graph.refreshOrder(after: bowl.id).isEmpty)
    }

    @Test func makingOrderIsDeepestFirstThenLineOrderEachOnce() {
        let caramel = Self.recipe("Caramel", servings: 1, lines: [])
        let frosting = Self.recipe("Frosting", servings: 1, lines: [RecipeFood.line(using: caramel, servings: 1)])
        let syrup = Self.recipe("Syrup", servings: 1, lines: [])
        let cake = Self.recipe("Cake", servings: 1, lines: [RecipeFood.line(using: frosting, servings: 1),
                                                            RecipeFood.line(using: caramel, servings: 1),
                                                            RecipeFood.line(using: syrup, servings: 1)])
        let graph = RecipeNestingGraph(recipes: [cake, frosting, caramel, syrup])
        #expect(graph.makingOrder(below: cake.id) == [caramel.id, frosting.id, syrup.id])
        #expect(graph.makingOrder(below: caramel.id).isEmpty)
    }

    @Test func aCycleThatArrivesAnywayEndsEveryWalk() {
        // Two devices each added the other recipe while offline.
        let firstID = UUID(), secondID = UUID()
        let first = Self.recipe("First", servings: 1, lines: [RecipeIngredient(foodItemId: secondID, quantity: 1, unit: "serving")], id: firstID)
        let second = Self.recipe("Second", servings: 1, lines: [RecipeIngredient(foodItemId: firstID, quantity: 1, unit: "serving")], id: secondID)
        let graph = RecipeNestingGraph(recipes: [first, second])
        #expect(graph.makingOrder(below: firstID) == [secondID])
        #expect(graph.height(of: firstID) == RecipeNestingLimits.maxDepth + 1)
        #expect(graph.refreshOrder(after: firstID) == [secondID])
        #expect(graph.refusal(adding: firstID, to: secondID) == .loop)
    }

    @Test func subRecipeGapsNameTheSubRecipesWithEmptyLines() throws {
        let water = Self.food("Mystery", grams: 100, protein: 0, carbs: 0, fat: 0)
        let sugar = Self.food("Sugar", grams: 100, protein: 0, carbs: 100, fat: 0)
        let sauce = Self.recipe("Dragonfruit sauce", servings: 1, lines: [Self.grams(water, 50), Self.grams(sugar, 10)])
        let pasta = Self.recipe("Pasta", servings: 2, lines: [RecipeFood.line(using: sauce, servings: 1)])
        let graph = RecipeNestingGraph(recipes: [pasta, sauce])
        let gaps = RecipeNutritionGaps.subRecipeGaps(in: pasta, graph: graph,
                                                     recipesByID: [sauce.id: sauce, pasta.id: pasta],
                                                     foodItems: [water, sugar])
        #expect(gaps.map(\.recipe.id) == [sauce.id])
        #expect(gaps.map(\.lines) == [1])
    }

    // MARK: - Keeping recipe foods in step (RecipeFoodSync)

    @Test func syncMakesFoodsOnlyForUsedRecipesAndRemovesUnusedOnes() throws {
        let sugar = Self.food("Sugar", grams: 100, protein: 0, carbs: 100, fat: 0)
        let sauce = Self.recipe("Sauce", servings: 2, lines: [Self.grams(sugar, 40)])
        let lone = Self.recipe("Lone", servings: 1, lines: [Self.grams(sugar, 10)])
        let pasta = Self.recipe("Pasta", servings: 1, lines: [RecipeFood.line(using: sauce, servings: 1)])

        let synced = RecipeFoodSync.synced(foodItems: [sugar], recipes: [pasta, sauce, lone])
        #expect(synced.filter(\.isRecipeFood).map(\.id) == [sauce.id])
        let unused = RecipeFoodSync.synced(foodItems: synced, recipes: [sauce, lone])
        #expect(unused.filter(\.isRecipeFood).isEmpty)
        #expect(RecipeFoodSync.synced(foodItems: unused, recipes: [sauce, lone]) == unused)
    }

    @Test func syncRebuildsDeepestFirstSoAParentReadsFreshNumbers() throws {
        let sugar = Self.food("Sugar", grams: 100, protein: 0, carbs: 100, fat: 0)
        let caramel = Self.recipe("Caramel", servings: 1, lines: [Self.grams(sugar, 50)])
        let frosting = Self.recipe("Frosting", servings: 1, lines: [RecipeFood.line(using: caramel, servings: 1)])
        let cake = Self.recipe("Cake", servings: 1, lines: [RecipeFood.line(using: frosting, servings: 1)])
        let first = RecipeFoodSync.synced(foodItems: [sugar], recipes: [cake, frosting, caramel])
        #expect(first.first { $0.id == frosting.id }?.macros.carbs == 50)

        var richer = caramel
        richer.ingredients = [Self.grams(sugar, 80)]
        let second = RecipeFoodSync.synced(foodItems: first, recipes: [cake, frosting, richer])
        #expect(second.first { $0.id == caramel.id }?.macros.carbs == 80)
        #expect(second.first { $0.id == frosting.id }?.macros.carbs == 80)
    }

    @Test func aDeletedRecipeStillUsedBecomesAFixedFood() throws {
        let sugar = Self.food("Sugar", grams: 100, protein: 0, carbs: 100, fat: 0)
        let sauce = Self.recipe("Sauce", servings: 2, lines: [Self.grams(sugar, 40)])
        let pasta = Self.recipe("Pasta", servings: 1, lines: [RecipeFood.line(using: sauce, servings: 2)])
        let made = RecipeFoodSync.synced(foodItems: [sugar], recipes: [pasta, sauce])
        let before = MealBuilder.macroTotals(for: pasta, foodItems: made)

        let after = RecipeFoodSync.synced(foodItems: made, recipes: [pasta])
        let fixed = try #require(after.first { $0.id == sauce.id })
        #expect(fixed.source == .manual)
        #expect(!fixed.isCustomIngredientWithoutNutrition)
        #expect(MealBuilder.macroTotals(for: pasta, foodItems: after) == before)
    }

    @Test func deletingARecipeCopiesItsStepsAndItsSubRecipesStepsIntoTheParent() {
        let caramel = RecipeDefinition(name: "Caramel", servings: 1, ingredients: [], source: "manual",
                                       createdAt: Self.now, updatedAt: Self.now, steps: [RecipeStep(text: "Melt sugar")])
        let frosting = RecipeDefinition(name: "Frosting", servings: 1, ingredients: [RecipeFood.line(using: caramel, servings: 1)],
                                        source: "manual", createdAt: Self.now, updatedAt: Self.now,
                                        steps: [RecipeStep(text: "Whip", durationSeconds: 60)])
        let cake = RecipeDefinition(name: "Cake", servings: 1, ingredients: [RecipeFood.line(using: frosting, servings: 1)],
                                    source: "manual", createdAt: Self.now, updatedAt: Self.now, steps: [RecipeStep(text: "Bake")])
        let updated = RecipeFoodSync.parent(cake, afterDeleting: frosting, allRecipes: [cake, frosting, caramel],
                                            maxSteps: SharedRecipeLimits.maxSteps)
        #expect(updated.steps?.map(\.text) == ["Caramel: Melt sugar", "Frosting: Whip", "Bake"])
        #expect(updated.steps?[1].durationSeconds == 60)
        #expect(updated.ingredients == cake.ingredients)
    }

    // MARK: - The store

    @Test func theStoreBindsAPickedRecipeKeepsItLiveAndFreezesItOnDelete() throws {
        let store = makeTestStore()
        let sauce = store.addRecipe(name: "Dragonfruit sauce", servings: 2,
                                    ingredients: [ManualRecipeIngredientInput(name: "Dragonfruit", quantity: 200, unit: "g",
                                                                              protein: 2, carbs: 40, fat: 0)],
                                    steps: [RecipeStep(text: "Blend")])
        let pasta = store.addRecipe(name: "Pasta", servings: 1,
                                    ingredients: [ManualRecipeIngredientInput(name: sauce.name, selectedFoodItemId: sauce.id,
                                                                              quantity: 1, unit: "serving")],
                                    steps: [RecipeStep(text: "Toss")])
        #expect(pasta.ingredients.map(\.foodItemId) == [sauce.id])
        #expect(store.foodItems.first { $0.id == sauce.id }?.isRecipeFood == true)
        #expect(!store.foodItems.contains { $0.name == sauce.name && !$0.isRecipeFood })
        #expect(store.macroTotals(for: pasta).carbs == 20)
        #expect(store.recipesUsing(sauce).map(\.id) == [pasta.id])

        store.updateRecipe(sauce, name: sauce.name, servings: 2,
                           ingredients: [ManualRecipeIngredientInput(name: "Dragonfruit", quantity: 400, unit: "g",
                                                                     protein: 4, carbs: 80, fat: 0)],
                           steps: sauce.steps)
        let livePasta = try #require(store.recipes.first { $0.id == pasta.id })
        #expect(store.macroTotals(for: livePasta).carbs == 40)

        let liveSauce = try #require(store.recipes.first { $0.id == sauce.id })
        store.deleteRecipe(liveSauce)
        let kept = try #require(store.recipes.first { $0.id == pasta.id })
        #expect(kept.steps?.map(\.text) == ["Dragonfruit sauce: Blend", "Toss"])
        #expect(store.foodItems.first { $0.id == sauce.id }?.source == .manual)
        #expect(store.macroTotals(for: kept).carbs == 40)
    }

    @Test func recipeFoodsStayOutOfFoodSearchButResolveByID() throws {
        let store = makeTestStore()
        let sauce = store.addRecipe(name: "Zanzibar glaze", servings: 1,
                                    ingredients: [ManualRecipeIngredientInput(name: "Honey", quantity: 20, unit: "g",
                                                                              protein: 0, carbs: 16, fat: 0)])
        _ = store.addRecipe(name: "Ham", servings: 4,
                            ingredients: [ManualRecipeIngredientInput(name: sauce.name, selectedFoodItemId: sauce.id,
                                                                      quantity: 1, unit: "serving")])
        let hits = store.foodCatalog.results(for: "zanzibar glaze", context: .userTyped, ranking: .standard)
        #expect(!hits.contains { $0.id == sauce.id })
        #expect(store.foodCatalog.items(ids: [sauce.id]).first?.isRecipeFood == true)
    }
}

