import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Recipes as building blocks, step 4: a sub-recipe's steps in the recipe that uses it and in cooking
/// mode (design §5), "Already made? Skip", and a sub-recipe's empty lines counted in "Totals are low".
@MainActor
struct RecipeBuildingBlocksStepsTests {
    nonisolated private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    nonisolated private static func recipe(_ name: String, servings: Int = 4, lines: [RecipeIngredient] = [],
                                           steps: [String] = []) -> RecipeDefinition {
        RecipeDefinition(name: name, servings: servings, ingredients: lines, source: "manual",
                         createdAt: now, updatedAt: now, steps: steps.isEmpty ? nil : steps.map { RecipeStep(text: $0) })
    }

    @Test func subRecipeStepsComeFirstDeepestFirstAndNamed() {
        let caramel = Self.recipe("Caramel", steps: ["Melt sugar"])
        let frosting = Self.recipe("Frosting", lines: [RecipeFood.line(using: caramel, servings: 1)], steps: ["Whip"])
        let cake = Self.recipe("Cake", lines: [RecipeFood.line(using: frosting, servings: 2)], steps: ["Bake", "Frost"])
        let all = [cake, frosting, caramel]
        let graph = RecipeNestingGraph(recipes: all)
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

        let sections = cake.stepSections(graph: graph, recipesByID: byID) { name, used, of in "\(name) \(used)/\(of)" }
        #expect(sections.map(\.name) == ["Caramel", "Frosting 2.0/4", "Cake"])
        #expect(sections.map { $0.steps.map(\.text) } == [["Melt sugar"], ["Whip"], ["Bake", "Frost"]])

        let walk = cake.cookingSteps(graph: graph, recipesByID: byID)
        #expect(walk.map(\.step.text) == ["Melt sugar", "Whip", "Bake", "Frost"])
        #expect(walk.map(\.partName) == ["Caramel", "Frosting", "Cake", "Cake"])
    }

    @Test func aRecipeWithNoSubRecipeStepsWalksExactlyAsBefore() {
        let salt = Self.recipe("Salt mix")   // a sub-recipe with no steps adds no section
        let soup = Self.recipe("Soup", lines: [RecipeFood.line(using: salt, servings: 1)], steps: ["Simmer"])
        let graph = RecipeNestingGraph(recipes: [soup, salt])
        let byID = [soup.id: soup, salt.id: salt]
        #expect(soup.cookingSteps(graph: graph, recipesByID: byID) == soup.cookingSteps)
        #expect(soup.stepSections(graph: graph, recipesByID: byID) == soup.resolvedComponents)
    }

    @Test func skipPartJumpsToTheNextPartOnlyFromAPartsFirstStep() {
        var run = CookingRunState(recipeID: UUID(), recipeName: "Pasta", startedDayKey: "2026-11-15", steps: [
            .init(text: "Blend", partName: "Sauce"), .init(text: "Strain", partName: "Sauce"),
            .init(text: "Boil", partName: "Pasta"), .init(text: "Toss", partName: "Pasta"),
        ])
        #expect(run.canSkipPart)
        run.skipPart()
        #expect(run.stepIndex == 2)
        #expect(!run.canSkipPart)   // the last part is the recipe itself
        run.goBack()
        #expect(!run.canSkipPart)   // the middle of a part
        run.skipPart()
        #expect(run.stepIndex == 1)

        var plain = CookingRunState(recipeID: UUID(), recipeName: "Toast", startedDayKey: "2026-11-15",
                                    steps: [.init(text: "Toast"), .init(text: "Butter")])
        #expect(!plain.canSkipPart)
        plain.skipPart()
        #expect(plain.stepIndex == 0)
    }

    @Test func theStoreWalksSubRecipesAndCountsTheirEmptyLines() throws {
        let store = makeTestStore()
        let sauce = store.addRecipe(name: "Dragonfruit sauce", servings: 2,
                                    ingredients: [ManualRecipeIngredientInput(name: "Dragonfruit", quantity: 200, unit: "g",
                                                                              protein: 2, carbs: 40, fat: 0),
                                                  ManualRecipeIngredientInput(name: "Mystery spice", quantity: 1, unit: "g")],
                                    steps: [RecipeStep(text: "Blend")])
        let pasta = store.addRecipe(name: "Pasta", servings: 1,
                                    ingredients: [ManualRecipeIngredientInput(name: sauce.name, selectedFoodItemId: sauce.id,
                                                                              quantity: 1, unit: "serving")],
                                    steps: [RecipeStep(text: "Toss")])
        #expect(store.cookingSteps(for: pasta).map(\.step.text) == ["Blend", "Toss"])
        #expect(store.stepSections(for: pasta).count == 2)
        #expect(store.linesWithoutNutrition(in: sauce) == 1)
        #expect(store.linesWithoutNutrition(in: pasta) == 1)
        let run = try #require(store.startCookingRun(pasta))
        #expect(run.steps.first?.partName?.hasPrefix("Dragonfruit sauce") == true)
        store.endCookingRun()
    }
}
