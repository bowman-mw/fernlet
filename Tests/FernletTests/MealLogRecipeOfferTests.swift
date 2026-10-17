import Foundation
import Testing
import FernletDomainModel
import AIProviders
@testable import Fernlet

/// No recipe reaches the book from a quick log without the person seeing it and keeping it, and a
/// logged meal never claims a recipe nobody saved (bug confirmation 2026-10-15, food-ai §4).
///
/// The plan tiers (`MealBuilder.meals`, behind the AI selection tier and the deterministic re-plan)
/// built a recipe for every item more than one food backed, put it in `MealResolution.createdRecipes`
/// and logged the meal as one serving of it. `commitResolution` mints `createdRecipes`, so an
/// auto-committed log ("chicken caesar salad" at `.high`) added "Chicken Caesar Salad" to the recipe
/// book unseen and the meal row said "From your recipe"; the review sheet never showed it and minted
/// it on confirm anyway; a background retry minted it unattended. The recipe is now an OFFER
/// (`offeredRecipes`), the review shows it with a switch, a commit mints only what the review hands
/// back, and the meal is logged as the matched foods it is.
@MainActor
struct MealLogRecipeOfferTests {
    /// A plan tier's resolution offers the recipe and creates none — so even a high-confidence log
    /// that commits without a review adds nothing to the book.
    @Test func aPlanTiersResolutionOffersItsRecipeAndCreatesNone() throws {
        let fixture = Self.fixture()
        let result = try #require(MealBuilder.meals(
            from: Self.plan(items: [fixture.oatsYogurt]), candidates: fixture.candidates,
            recipes: [], foodItems: fixture.foods
        ))

        let resolution = MealResolutionService.planResolution(result, confidence: .high, unmatchedItems: [])

        #expect(resolution.createdRecipes.isEmpty)
        #expect(resolution.offeredRecipes.map(\.name) == ["Oats Yogurt"])
        #expect(resolution.needsReview == false)
    }

    /// The auto-commit path (`FoodView`'s direct commit and the background retry both call
    /// `commitResolution` on the resolution as it came): the meal is logged, no recipe is minted, and
    /// the row reads the matched foods, not "From your recipe".
    @Test func anAutoCommitLogsTheMatchedFoodsAndMintsNoRecipe() throws {
        let fixture = Self.fixture()
        let result = try #require(MealBuilder.meals(
            from: Self.plan(items: [fixture.oatsYogurt]), candidates: fixture.candidates,
            recipes: [], foodItems: fixture.foods
        ))
        let store = makeTestStore()
        let recipesBefore = store.recipes.map(\.id)

        let committed = store.commitResolution(
            MealResolutionService.planResolution(result, confidence: .high, unmatchedItems: [])
        )

        #expect(store.recipes.map(\.id) == recipesBefore)
        let meal = try #require(committed.first)
        #expect(store.day.meals.contains { $0.id == meal.id })
        #expect(meal.mealSource == .manual)
        #expect(MealConfidence(persistedToken: meal.confidence) == .foodMatch)
        #expect(meal.macros == Macros(protein: 23, carbs: 33, fat: 3))
    }

    /// An offered recipe is not in the book, so it never backs a later item of the same plan: both
    /// items log their own matched foods, and each offers its recipe.
    @Test func anOfferedRecipeNeverBacksALaterItem() throws {
        let fixture = Self.fixture()
        let result = try #require(MealBuilder.meals(
            from: Self.plan(items: [fixture.oatsYogurt, fixture.oatsYogurt]), candidates: fixture.candidates,
            recipes: [], foodItems: fixture.foods
        ))

        #expect(result.meals.count == 2)
        #expect(result.meals.allSatisfy { $0.mealSource == .manual })
        #expect(result.offeredRecipes.count == 2)
    }

    /// The single-meal fold and the plausibility gate carry the offers through to the review.
    @Test func theResolutionTransformsCarryTheOffers() throws {
        let fixture = Self.fixture()
        let result = try #require(MealBuilder.meals(
            from: Self.plan(items: [fixture.oatsYogurt, fixture.berriesGranola]), candidates: fixture.candidates,
            recipes: [], foodItems: fixture.foods
        ))
        let resolution = MealResolutionService.planResolution(result, confidence: .high, unmatchedItems: [])

        let merged = MealResolutionService.mergedIntoSingleMeal(resolution, description: "oats yogurt and berries granola")
        #expect(merged.meals.count == 1)
        #expect(merged.offeredRecipes.map(\.name) == ["Oats Yogurt", "Berries Granola"])
        #expect(merged.createdRecipes.isEmpty)

        var implausible = merged
        try #require(implausible.meals.count == 1)
        implausible.meals[0].macros = Macros(protein: 3_000, carbs: 3_000, fat: 6_000)
        let gated = MealResolutionService.plausibilityGated(implausible)
        #expect(gated.confidence == .low)
        #expect(gated.offeredRecipes.map(\.name) == ["Oats Yogurt", "Berries Granola"])
    }

    /// The review offers every recipe, switched on; the confirm hands back only the ones kept, with the
    /// person's name and yield over the reviewed grams; the commit mints exactly those.
    @Test func theReviewOffersEveryRecipeAndMintsOnlyTheOnesKept() throws {
        let fixture = Self.fixture()
        let result = try #require(MealBuilder.meals(
            from: Self.plan(items: [fixture.oatsYogurt]), candidates: fixture.candidates,
            recipes: [], foodItems: fixture.foods
        ))
        let suggested = RecipeDefinition(
            name: "Suggested Bowl", servings: 4, ingredients: [], source: "meal-log",
            createdAt: Self.fixedDate, updatedAt: Self.fixedDate
        )
        var resolution = MealResolutionService.planResolution(result, confidence: .low, unmatchedItems: [])
        resolution.suggestedRecipe = suggested

        var offers = MealReviewRecipeOffer.offers(for: resolution)
        try #require(offers.map(\.base.name) == ["Suggested Bowl", "Oats Yogurt"])
        #expect(offers.allSatisfy { $0.isSaved })
        offers[0].isSaved = false
        offers[1].name = "  Morning Oats  "
        offers[1].servings = 2
        let reviewed = resolution.meals.flatMap(\.componentSnapshots).map(MealComponentCorrectionInput.init(snapshot:))
        let kept = offers.compactMap { $0.confirmedRecipe(reviewedComponents: reviewed) }

        let recipe = try #require(kept.first)
        #expect(kept.count == 1)
        #expect(recipe.name == "Morning Oats")
        #expect(recipe.servings == 2)
        #expect(recipe.ingredients.map(\.quantity) == [2, 2])

        let store = makeTestStore()
        store.commitResolution(MealResolution(meals: resolution.meals, createdRecipes: kept, confidence: .low, isFallback: false))
        #expect(store.recipes.contains { $0.name == "Morning Oats" })
        #expect(store.recipes.contains { $0.name == "Suggested Bowl" } == false)
    }

    // MARK: - Fixtures

    private static let fixedDate = Date(timeIntervalSince1970: 1_779_664_800)

    /// Four one-serving catalog foods, their candidates, and two plan items that each bind two of them.
    private static func fixture() -> (
        foods: [FoodItem], candidates: [FoodSelectionCandidate],
        oatsYogurt: FoodSelectionMealItem, berriesGranola: FoodSelectionMealItem
    ) {
        let foods = [
            food("Oats", Macros(protein: 5, carbs: 27, fat: 3)),
            food("Greek yogurt", Macros(protein: 18, carbs: 6, fat: 0)),
            food("Berries", Macros(protein: 1, carbs: 14, fat: 0)),
            food("Granola", Macros(protein: 4, carbs: 30, fat: 6))
        ]
        let candidates = foods.enumerated().map { FoodSelectionCandidate(id: $0.offset + 1, foodItem: $0.element) }
        return (
            foods, candidates,
            item("oats yogurt", candidateIDs: [1, 2], foods: foods),
            item("berries granola", candidateIDs: [3, 4], foods: foods)
        )
    }

    private static func food(_ name: String, _ macros: Macros) -> FoodItem {
        FoodItem(
            name: name, servingSize: 1, servingUnit: RecipeUnit.serving.rawValue, macros: macros,
            micronutrients: Micronutrients(), category: "test", source: .manual, tags: []
        )
    }

    private static func item(_ name: String, candidateIDs: [Int], foods: [FoodItem]) -> FoodSelectionMealItem {
        FoodSelectionMealItem(name: name, ingredients: candidateIDs.map { id in
            FoodSelectionIngredient(
                candidateId: id, foodName: foods[id - 1].name, quantity: 1, unit: RecipeUnit.serving.rawValue
            )
        })
    }

    private static func plan(items: [FoodSelectionMealItem]) -> FoodSelectionPlan {
        FoodSelectionPlan(mealName: "Breakfast", mealType: .breakfast, items: items)
    }
}
