import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// Multipart recipes (2026-09-24): the builder, without UI. Covers every rule the editor applies to
/// parts (`RecipePartsDraft`), the stored shape a save produces (`RecipeComponentAssembly` through the
/// store's parts API), the editor re-opening a saved recipe into its parts, and cooking mode walking
/// part by part (the run snapshot and its Live Activity text).
@MainActor
struct RecipeMultipartBuilderTests {

    // MARK: - RecipePartsDraft: splitting, adding, removing, moving

    @Test func splittingMakesTheCurrentRowsThePartThatComesFirst() throws {
        var draft = RecipePartsDraft()
        let rows = [row("Olive oil"), row("Lemon juice")]
        let steps = [RecipeStep(text: "Whisk")]

        let split = draft.split(ingredients: rows, steps: steps)
        let added = try #require(split)
        #expect(draft.isMultipart)
        #expect(draft.parts.count == 2)
        #expect(draft.parts[0].ingredients == rows)
        #expect(draft.parts[0].steps == steps)
        #expect(draft.parts[1].id == added)
        #expect(draft.parts[1].ingredients.count == 1)   // one blank row, ready to type into
        #expect(draft.split(ingredients: rows, steps: steps) == nil)   // already split
    }

    @Test func partsAreCappedAtTwelve() {
        var draft = RecipePartsDraft()
        #expect(draft.addPart() == nil)   // a one-part recipe is split, not "added to"
        _ = draft.split(ingredients: [row("A")], steps: [])
        for _ in 0..<(RecipeComponentLimits.maxComponents - 2) { #expect(draft.addPart() != nil) }
        #expect(draft.parts.count == RecipeComponentLimits.maxComponents)
        #expect(draft.canAddPart == false)
        #expect(draft.addPart() == nil)
    }

    @Test func rowAndStepCapsCountEveryPart() throws {
        var draft = RecipePartsDraft()
        _ = draft.split(ingredients: (0..<(RecipeLimits.maxIngredients - 2)).map { row("R\($0)") },
                        steps: (0..<(RecipeLimits.maxSteps - 1)).map { RecipeStep(text: "S\($0)") })
        let second = try #require(draft.parts.last?.id)
        #expect(draft.ingredientRowCount == RecipeLimits.maxIngredients - 1)
        #expect(draft.addIngredient(to: second) != nil)   // the hundredth row
        #expect(draft.addIngredient(to: second) == nil)   // one past the whole-recipe cap
        #expect(draft.canAddPart == false)

        draft.addStep(to: second)                          // the sixtieth step
        draft.addStep(to: second)                          // refused
        #expect(draft.stepCount == RecipeLimits.maxSteps)
    }

    @Test func removingDownToOnePartHandsTheRowsBack() throws {
        var draft = RecipePartsDraft()
        _ = draft.split(ingredients: [row("Olive oil")], steps: [RecipeStep(text: "Whisk")])
        let added = draft.addPart()
        let third = try #require(added)
        let first = draft.parts[0].id

        #expect(draft.removePart(third) == nil)   // two parts left: still multipart
        #expect(draft.isMultipart)
        let removed = draft.removePart(draft.parts[1].id)
        let survivor = try #require(removed)
        #expect(survivor.id == first)
        #expect(survivor.ingredients.map(\.name) == ["Olive oil"])
        #expect(draft.isMultipart == false)
        #expect(draft.parts.isEmpty)
    }

    @Test func movingAPartChangesMakingOrder() {
        var draft = RecipePartsDraft()
        _ = draft.split(ingredients: [row("Greens")], steps: [])
        draft.parts[0].name = "Salad"
        draft.parts[1].name = "Dressing"
        draft.movePart(draft.parts[1].id, by: -1)
        #expect(draft.parts.map(\.name) == ["Dressing", "Salad"])
        draft.movePart(draft.parts[0].id, by: -1)   // already first: nothing moves
        #expect(draft.parts.map(\.name) == ["Dressing", "Salad"])
    }

    @Test func stepsReorderOnlyWithinTheirPart() throws {
        var draft = RecipePartsDraft()
        _ = draft.split(ingredients: [row("A")], steps: [RecipeStep(text: "one"), RecipeStep(text: "two")])
        let part = draft.parts[0].id
        let second = try #require(draft.parts[0].steps.last?.id)

        draft.moveStep(second, in: part, by: -1)
        #expect(draft.parts[0].steps.map(\.text) == ["two", "one"])
        draft.moveStep(second, in: part, by: -1)   // at the part's top: stays
        #expect(draft.parts[0].steps.map(\.text) == ["two", "one"])
        draft.removeStep(second, from: part)
        #expect(draft.parts[0].steps.map(\.text) == ["one"])
    }

    @Test func aPartsLastRowResetsToBlankAndAScanReplacesALoneBlankRow() throws {
        var draft = RecipePartsDraft()
        _ = draft.split(ingredients: [row("Olive oil")], steps: [])
        let second = try #require(draft.parts.last)

        draft.removeIngredient(second.ingredients[0].id, from: second.id)
        #expect(draft.parts[1].ingredients.count == 1)
        #expect(draft.parts[1].ingredients[0].trimmedName.isEmpty)

        draft.appendIngredient(row("Honey"), to: second.id)
        #expect(draft.parts[1].ingredients.map(\.name) == ["Honey"])
        draft.appendIngredient(row("Mustard"), to: UUID())   // its part was removed mid-scan: lands last
        #expect(draft.parts[1].ingredients.map(\.name) == ["Honey", "Mustard"])
    }

    @Test func onlyAPartWithNothingTypedIsBlank() throws {
        var draft = RecipePartsDraft()
        _ = draft.split(ingredients: [row("Olive oil")], steps: [])
        let second = try #require(draft.parts.last?.id)
        #expect(draft.isBlank(second))
        #expect(!draft.isBlank(draft.parts[0].id))
        draft.parts[1].steps = [RecipeStep(text: "Toss")]
        #expect(!draft.isBlank(second))
    }

    // MARK: - Assembly: the stored shape a save produces

    @Test func assemblyDropsBlankRowsAndEmptyPartsAndNamesTheUnnamed() {
        var foods: [FoodItem] = []
        let parts = [
            RecipeComponentInput(name: "  Dressing ", ingredients: [row("Olive oil"), row("")],
                                 steps: [RecipeStep(text: "Whisk"), RecipeStep(text: "  ")]),
            RecipeComponentInput(name: "Nothing", ingredients: [row("")], steps: []),
            RecipeComponentInput(name: "", ingredients: [row("Romaine lettuce")], steps: [RecipeStep(text: "Toss")])
        ]

        let result = RecipeComponentAssembly.assemble(parts, in: &foods, verifiedAt: Date())
        #expect(result.ingredients.count == 2)
        #expect(result.steps?.map(\.text) == ["Whisk", "Toss"])
        #expect(foods.map(\.name) == ["Olive oil", "Romaine lettuce"])
        let components = result.components ?? []
        #expect(components.map(\.name) == ["Dressing", RecipeComponentNaming.fallbackName(position: 1)])
        #expect(components.map(\.ingredientIDs) == result.ingredients.map { [$0.id] })
        #expect(components.flatMap(\.stepIDs) == (result.steps ?? []).map(\.id))
    }

    @Test func assemblyWithFewerThanTwoNonEmptyPartsStoresAOnePartRecipe() {
        var foods: [FoodItem] = []
        let parts = [RecipeComponentInput(name: "Only", ingredients: [row("Oats")], steps: []),
                     RecipeComponentInput(name: "Blank", ingredients: [row("")], steps: [])]

        let result = RecipeComponentAssembly.assemble(parts, in: &foods, verifiedAt: Date())
        #expect(result.components == nil)
        #expect(result.ingredients.count == 1)
    }

    // MARK: - The store's parts API

    @Test func savingPartsStoresAMultipartRecipeAndReopensIntoItsParts() throws {
        let store = makeTestStore()
        let recipe = store.addRecipe(name: "Garden salad", servings: 4, parts: saladParts())

        #expect(recipe.isMultipart)
        #expect(recipe.resolvedComponents.map(\.name) == ["Lemon-dijon dressing", "Salad"])
        #expect(store.recipes.first?.id == recipe.id)
        let reopened = RecipePartsDraft.parts(for: recipe, foodItems: store.foodCatalog.items(forRecipe: recipe))
        #expect(reopened.map(\.name) == ["Lemon-dijon dressing", "Salad"])
        #expect(reopened.map { $0.ingredients.map(\.name) } == [["Olive oil", "Lemon juice"], ["Romaine lettuce"]])
        #expect(reopened.map { $0.steps.map(\.text) } == [["Whisk"], ["Toss with the dressing"]])
    }

    @Test func updatingWithPartsRewritesThemAndAOnePartSaveClearsThem() throws {
        let store = makeTestStore()
        let recipe = store.addRecipe(name: "Garden salad", servings: 4, parts: saladParts())

        var reordered = saladParts()
        reordered.reverse()
        store.updateRecipe(recipe, name: "Garden salad", servings: 4, parts: reordered)
        let updated = try #require(store.recipes.first { $0.id == recipe.id })
        #expect(updated.resolvedComponents.map(\.name) == ["Salad", "Lemon-dijon dressing"])

        store.updateRecipe(updated, name: "Garden salad", servings: 4,
                           ingredients: [row("Olive oil")], steps: [RecipeStep(text: "Drizzle")])
        let flattened = try #require(store.recipes.first { $0.id == recipe.id })
        #expect(flattened.components == nil)
        #expect(flattened.isMultipart == false)
    }

    // MARK: - Cooking mode walks part by part

    @Test func aCookingRunWalksPartByPartAndNamesThePart() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("MultipartCook-\(UUID().uuidString)")
        let store = makeTestStore(appGroupDirectory: dir)
        defer { store.endCookingRun() }
        let recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe

        let run = try #require(store.startCookingRun(recipe, startDayKey: "2026-09-24"))
        try #require(run.steps.count == 5)
        #expect(run.steps.map(\.text) == (RecipeMultipartFixtures.dressingSteps + RecipeMultipartFixtures.saladSteps).map(\.text))
        #expect(run.steps.map(\.partName) == ["Lemon-dijon dressing", "Lemon-dijon dressing", "Salad", "Salad", "Salad"])
        #expect(run.currentPart?.position == 1)
        #expect(run.currentPart?.count == 2)
        #expect(run.contentState.stepText == "Lemon-dijon dressing · Whisk the lemon juice, mustard and honey.")

        var advanced = run
        advanced.advance()
        advanced.advance()
        #expect(advanced.currentPart?.position == 2)
        #expect(advanced.currentPart?.name == "Salad")
        #expect(advanced.contentState.stepText.hasPrefix("Salad · Toss the bread cubes"))
    }

    @Test func aOnePartRunCarriesNoPartAndItsLiveActivityTextIsUnchanged() throws {
        var recipe = RecipeMultipartFixtures.saladWithHomemadeDressing().recipe
        recipe.components = nil
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("OnePartCook-\(UUID().uuidString)")
        let store = makeTestStore(appGroupDirectory: dir)
        defer { store.endCookingRun() }

        let run = try #require(store.startCookingRun(recipe))
        #expect(run.steps.allSatisfy { $0.partName == nil })
        #expect(run.currentPart == nil)
        #expect(run.contentState.stepText == "Whisk the lemon juice, mustard and honey.")
    }

    @Test func aRunPersistedBeforePartsExistedStillDecodes() throws {
        let json = #"{"text":"Stir","durationSeconds":60}"#
        let step = try JSONDecoder().decode(CookingRunState.Step.self, from: Data(json.utf8))
        #expect(step.partName == nil)
        #expect(step.durationSeconds == 60)
    }

    // MARK: - Helpers

    private func row(_ name: String) -> ManualRecipeIngredientInput {
        ManualRecipeIngredientInput(name: name, quantity: 1, unit: "cup", protein: 1, carbs: 2, fat: 3)
    }

    private func saladParts() -> [RecipeComponentInput] {
        [
            RecipeComponentInput(name: "Lemon-dijon dressing", ingredients: [row("Olive oil"), row("Lemon juice")],
                                 steps: [RecipeStep(text: "Whisk")]),
            RecipeComponentInput(name: "Salad", ingredients: [row("Romaine lettuce")],
                                 steps: [RecipeStep(text: "Toss with the dressing")])
        ]
    }
}
