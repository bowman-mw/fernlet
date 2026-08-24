import Foundation
import Testing
import AIProviders
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// End-to-end and population gates for research §26 item 1.12's pre-decomposition probe.
///
/// The measurement population is the owning 57-query search corpus plus its 32-query resolver bank.
/// Search/candidate APIs keep their existing pins; this suite separately pins every query on which
/// the new resolver-only branch fires, so a new short-circuit cannot be silently rebaselined.
@MainActor
struct WholeDescriptionFoodProbeTests {
    private struct Pin: Equatable {
        let query: String
        let name: String
        let score: Int
        let grams: Double
        let unmatched: [String]
    }

    private static let populationPins = [
        Pin(query: "cheese pizza slice", name: "PIZZA HUT 12\" Cheese Pizza, Pan Crust",
            score: 368, grams: 100, unmatched: []),
        Pin(query: "costco cheese pizza slice", name: "PIZZA HUT 12\" Cheese Pizza, Pan Crust",
            score: 368, grams: 100, unmatched: ["costco"]),
        Pin(query: "piece of chicken", name: "Chicken breast, roasted",
            score: 809, grams: 174, unmatched: []),
        Pin(query: "two slices of pizza", name: "PIZZA HUT 12\" Cheese Pizza, Pan Crust",
            score: 807, grams: 200, unmatched: [])
    ]

    @Test func measuredHighFloorAndCompleteFiredPopulationArePinned() throws {
        #expect(FoodItemSearch.confidentBindScore == 250, "the shared floor is explicitly unchanged")
        #expect(WholeDescriptionFoodProbe.acceptanceScore == 368, "narrow probe floor")
        #expect(FoodSearchCorpusTests.corpus.count == 57)
        #expect(FoodSearchCorpusTests.resolverBank.count == 32)
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == FoodSearchCorpusTests.shippedRowCount)

        var queries = FoodSearchCorpusTests.corpus.map(\.query)
        queries.append(contentsOf: FoodSearchCorpusTests.resolverBank.map(\.query))
        let uniqueQueries = Array(Set(queries)).sorted()
        let fired = uniqueQueries.compactMap { query -> Pin? in
            guard let match = WholeDescriptionFoodProbe.match(description: query, catalog: catalog) else {
                return nil
            }
            return Pin(query: query, name: match.item.name, score: match.score,
                       grams: match.grams, unmatched: match.unmatchedItems)
        }
        #expect(fired == Self.populationPins)
    }

    @Test func floorExcludesMeasuredWrongPortionMatches() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == FoodSearchCorpusTests.shippedRowCount)
        let unsafe = [
            try measuredMatch("piece of chicken", floor: 250, catalog: catalog),
            try measuredMatch("slice of toast", floor: 250, catalog: catalog),
            try measuredMatch("cup of coffee", floor: 250, catalog: catalog)
        ]
        #expect(unsafe.map(\.item.name) == [
            "Lasagna with chicken or turkey", "French toast, frozen", "SILK Coffee, soymilk"
        ])
        #expect(unsafe.map(\.score) == [308, 309, 309])
        #expect(unsafe.map(\.grams) == [206, 60, 243])
        #expect(unsafe.allSatisfy { $0.score < WholeDescriptionFoodProbe.acceptanceScore })

        let chicken = try #require(WholeDescriptionFoodProbe.match(
            description: "piece of chicken", catalog: catalog
        ))
        #expect(chicken.item.name == "Chicken breast, roasted")
        #expect(chicken.score == 809)
        #expect(chicken.grams == 174)
        #expect(WholeDescriptionFoodProbe.match(description: "slice of toast", catalog: catalog) == nil,
                "309-point frozen French toast is the corpus's wrong top one")
        #expect(WholeDescriptionFoodProbe.match(description: "cup of coffee", catalog: catalog) == nil,
                "309-point SILK soymilk coffee is the corpus's wrong top one")
        #expect(WholeDescriptionFoodProbe.match(description: "cheese pizza", catalog: catalog) == nil,
                "a typed compatible unit is mandatory")
        #expect(WholeDescriptionFoodProbe.match(description: "101 slices of pizza", catalog: catalog) == nil,
                "quantity growth is bounded")
        let equality = try measuredMatch(
            "cheese pizza slice", floor: WholeDescriptionFoodProbe.acceptanceScore, catalog: catalog
        )
        #expect(equality.score == WholeDescriptionFoodProbe.acceptanceScore)
        #expect(equality.item.name == "PIZZA HUT 12\" Cheese Pizza, Pan Crust")
    }

    @Test func realSliceAndPieceServingBasesNeverTreatGramsAsServings() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == FoodSearchCorpusTests.shippedRowCount)
        let toast = try #require(WholeDescriptionFoodProbe.match(
            description: "french toast slice", catalog: catalog
        ))
        let pizza = try #require(WholeDescriptionFoodProbe.match(
            description: "breakfast pizza piece", catalog: catalog
        ))
        #expect(toast.item.name == "French toast, frozen")
        #expect(toast.grams == 60)
        #expect(toast.ingredientQuantity == 1)
        #expect(toast.ingredientUnit == "slice")
        #expect(pizza.item.name == "Breakfast pizza with egg")
        #expect(pizza.grams == 151)
        #expect(pizza.ingredientQuantity == 1)
        #expect(pizza.ingredientUnit == "piece")
        let toastMeal = try probeMeal(toast, description: "french toast slice")
        let pizzaMeal = try probeMeal(pizza, description: "breakfast pizza piece")

        try assertExactBasisMeal(toastMeal, item: toast.item, quantity: 1, unit: "slice")
        try assertExactBasisMeal(pizzaMeal, item: pizza.item, quantity: 1, unit: "piece")
        #expect(toastMeal.componentSnapshots.first?.quantity != 60, "the 60 g mapping is not 60 servings")
        #expect(pizzaMeal.componentSnapshots.first?.quantity != 151, "the 151 g mapping is not 151 servings")
        #expect(toastMeal.calories == toast.item.calories)
        #expect(pizzaMeal.calories == pizza.item.calories)
    }

    @Test func unsafeDirectRetailerCandidateCannotFallBackToSafeStrippedRow() throws {
        let unsafe = syntheticFood(
            name: "Costco Safe Toast", servingSize: 1, servingUnit: "tray",
            macros: Macros(protein: 4, carbs: 18, fat: 2),
            micros: Micronutrients(fiber: 2),
            portion: FoodPortion(amount: 1, unit: "slice", gramWeight: 60)
        )
        let safe = syntheticFood(
            name: "Safe Toast", servingSize: 100, servingUnit: "g",
            macros: Macros(protein: 7, carbs: 30, fat: 3),
            micros: Micronutrients(fiber: 3),
            portion: FoodPortion(amount: 1, unit: "slice", gramWeight: 60)
        )
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([unsafe, safe]))
        let directRows = catalog.scoredResults(for: "costco safe toast", limit: 2)
        let strippedRows = catalog.scoredResults(for: "safe toast", limit: 2)
        #expect(directRows.first?.item.id == unsafe.id)
        #expect((directRows.first?.score ?? 0) >= WholeDescriptionFoodProbe.acceptanceScore)
        #expect(strippedRows.first?.item.id == safe.id)
        #expect(DishTemplateLexicon.unaccountedBrandChips(
            itemName: "costco safe toast slice", matchedKey: ""
        ) == ["costco"])
        let generic = try #require(WholeDescriptionFoodProbe.match(
            description: "safe toast slice", catalog: catalog
        ))
        #expect(generic.item.id == safe.id, "the stripped query has a safe answer in isolation")
        #expect(generic.ingredientQuantity == 60)
        #expect(generic.ingredientUnit == RecipeUnit.gram.rawValue)
        #expect(WholeDescriptionFoodProbe.match(
            description: "costco safe toast slice", catalog: catalog
        ) == nil, "unsafe direct row must abort instead of masking through retailer stripping")
    }

    @Test func nonUnitPortionAmountsAndFractionalCountsScaleInTrueBasis() throws {
        let slice = syntheticFood(
            name: "Test toast", servingSize: 2, servingUnit: "slices",
            macros: Macros(protein: 8, carbs: 40, fat: 12),
            micros: Micronutrients(fiber: 4, sodium: 200),
            portion: FoodPortion(amount: 2, unit: "slice", gramWeight: 120)
        )
        let piece = syntheticFood(
            name: "Test breakfast pizza", servingSize: 1, servingUnit: "piece",
            macros: Macros(protein: 20, carbs: 10, fat: 8),
            micros: Micronutrients(iron: 2, sodium: 300),
            portion: FoodPortion(amount: 1, unit: "pieces", gramWeight: 151)
        )
        let sliceMeal = try basisMeal(item: slice, unit: "slice", quantity: 1.5, type: .breakfast)
        let pieceMeal = try basisMeal(item: piece, unit: "piece", quantity: 0.5, type: .breakfast)

        #expect(sliceMeal.componentSnapshots.first?.quantity == 1.5)
        #expect(sliceMeal.componentSnapshots.first?.unit == "slices")
        #expect(sliceMeal.macros == Macros(protein: 6, carbs: 30, fat: 9))
        #expect(sliceMeal.micronutrientSnapshot.fiber == 3)
        #expect(sliceMeal.micronutrientSnapshot.sodium == 150)
        #expect(sliceMeal.calories == 225)
        #expect(pieceMeal.componentSnapshots.first?.quantity == 0.5)
        #expect(pieceMeal.componentSnapshots.first?.unit == "piece")
        #expect(pieceMeal.macros == Macros(protein: 10, carbs: 5, fat: 4))
        #expect(pieceMeal.micronutrientSnapshot.iron == 1)
        #expect(pieceMeal.micronutrientSnapshot.sodium == 150)
        #expect(pieceMeal.calories == 96)
    }

    @Test func servingBasisRejectsInvalidNonfiniteUnsupportedAndOverflowInputs() {
        let item = syntheticFood(
            name: "Safe toast", servingSize: 1, servingUnit: "slice",
            macros: Macros(protein: 4, carbs: 18, fat: 2),
            micros: Micronutrients(fiber: 2),
            portion: FoodPortion(amount: 1, unit: "slice", gramWeight: 60)
        )
        let portion = item.portions[0]
        let invalidQuantities: [Double] = [0, -1, .nan, .infinity, -.infinity]
        for quantity in invalidQuantities {
            #expect(WholeDescriptionFoodProbe.servingBasis(
                item: item, portion: portion, quantity: quantity
            ) == nil)
        }
        for invalid in invalidPortions() {
            #expect(WholeDescriptionFoodProbe.servingBasis(
                item: item, portion: invalid, quantity: 1
            ) == nil)
        }
        var invalidItem = item
        invalidItem.servingSize = .greatestFiniteMagnitude
        #expect(WholeDescriptionFoodProbe.servingBasis(
            item: invalidItem, portion: portion, quantity: 1
        ) == nil)
        invalidItem = item
        invalidItem.servingUnit = "tray"
        #expect(WholeDescriptionFoodProbe.servingBasis(
            item: invalidItem, portion: portion, quantity: 1
        ) == nil, "an unsupported non-matching basis fails closed")
        let unsupportedCatalog = FoodCatalog(
            source: InMemoryBundledFoodSource([invalidItem])
        )
        #expect(WholeDescriptionFoodProbe.match(
            description: "safe toast slice", catalog: unsupportedCatalog
        ) == nil, "the whole-description probe must fail closed before later tiers")
        let overflow = FoodPortion(amount: 1, unit: "slice", gramWeight: .greatestFiniteMagnitude)
        #expect(WholeDescriptionFoodProbe.servingBasis(
            item: item, portion: overflow, quantity: 2
        ) == nil)
    }

    @Test func retailerFallbackSurfacesVerbatimChipAndScalesTypedCount() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == FoodSearchCorpusTests.shippedRowCount)
        let branded = try #require(WholeDescriptionFoodProbe.match(
            description: "CostCo cheese pizza slice", catalog: catalog
        ))
        #expect(branded.item.name == "PIZZA HUT 12\" Cheese Pizza, Pan Crust")
        #expect(branded.portion.unit == "slice")
        #expect(branded.grams == 100)
        #expect(branded.unmatchedItems == ["CostCo"], "surface the user's bytes, not lexicon casing")

        let counted = try #require(WholeDescriptionFoodProbe.match(
            description: "two slices of pizza", catalog: catalog
        ))
        #expect(counted.grams == 200)
        #expect(counted.unmatchedItems.isEmpty)

        let fractional = try #require(WholeDescriptionFoodProbe.match(
            description: "1.5 slices of pizza", catalog: catalog
        ))
        #expect(fractional.grams == 150)
        #expect(fractional.ingredientQuantity == 150)
        #expect(fractional.ingredientUnit == RecipeUnit.gram.rawValue)
    }

    @Test func realQuickLogPathShortCircuitsToOnePortionBeforeDecomposition() async throws {
        let store = makeTestStore(foodCatalog: FoodCatalog.bundled())
        try #require(store.settings.aiStatus == AIStatus.off)
        try #require(store.foodCatalog.bundledCount == FoodSearchCorpusTests.shippedRowCount)
        let match = try #require(WholeDescriptionFoodProbe.match(
            description: "costco cheese pizza slice", catalog: store.foodCatalog
        ))

        let resolution = await store.resolveMeals(from: "costco cheese pizza slice", type: .dinner)
        #expect(resolution.meals.count == 1)
        #expect(resolution.createdRecipes.isEmpty)
        #expect(resolution.suggestedRecipe == nil)
        #expect(!resolution.isFallback)
        #expect(resolution.confidence == .low)
        #expect(resolution.unmatchedItems == ["costco"])
        #expect(resolution.needsReview)
        let meal = try #require(resolution.meals.first)
        #expect(meal.name == "Costco Cheese Pizza Slice")
        #expect(meal.mealType == .dinner)
        #expect(meal.mealSource == .manual)
        #expect(meal.source == MealLogSource.manual)
        #expect(meal.quality == .ok)
        #expect(meal.confidence == MealConfidence.roughEstimate.token)
        #expect(meal.note == "Matched locally from food selection: 100 g PIZZA HUT 12\" Cheese Pizza, Pan Crust.")
        #expect(meal.macros == Macros(protein: 12, carbs: 30, fat: 13))
        #expect(meal.macroSnapshot == meal.macros)
        #expect(meal.calorieSnapshot == 285)
        #expect(meal.calories == 285)
        #expect(meal.micronutrientSnapshot == match.item.micronutrients)
        try #require(meal.componentSnapshots.count == 1)
        let component = try #require(meal.componentSnapshots.first)
        #expect(component.foodItemId == match.item.id)
        #expect(component.name == "PIZZA HUT 12\" Cheese Pizza, Pan Crust")
        #expect(component.quantity == 100)
        #expect(component.unit == RecipeUnit.gram.rawValue)
        #expect(component.macros == meal.macros)
        #expect(component.micronutrients == meal.micronutrientSnapshot)

        let unbranded = await store.resolveMeals(from: "cheese pizza slice", type: .lunch)
        #expect(unbranded.confidence == .high)
        #expect(unbranded.unmatchedItems.isEmpty)
        #expect(!unbranded.needsReview)
        #expect(unbranded.meals.first?.componentSnapshots.count == 1)
        #expect(unbranded.meals.first?.confidence == MealConfidence.foodMatch.token)
        #expect(unbranded.meals.first?.source == MealLogSource.manual)
        #expect(unbranded.meals.first?.mealType == .lunch)
    }

    private func measuredMatch(
        _ description: String,
        floor: Int,
        catalog: FoodCatalog
    ) throws -> WholeDescriptionFoodProbe.Match {
        try #require(WholeDescriptionFoodProbe.compatibleMatch(
            description: description, catalog: catalog, minimumScore: floor
        ))
    }

    private func basisMeal(
        item: FoodItem,
        unit: String,
        quantity: Double,
        type: MealType
    ) throws -> Meal {
        let portion = try #require(item.portions.first(where: {
            FoodItemSearch.normalized($0.unit).contains(unit)
        }))
        let match = try #require(WholeDescriptionFoodProbe.safeMatch(
            item: item, score: 800, portion: portion, quantity: quantity
        ))
        let resolution = MealResolutionService.probeResolution(
            match, description: item.name, type: type
        )
        return try #require(resolution.meals.first)
    }

    private func probeMeal(
        _ match: WholeDescriptionFoodProbe.Match,
        description: String
    ) throws -> Meal {
        let resolution = MealResolutionService.probeResolution(
            match, description: description, type: .breakfast
        )
        return try #require(resolution.meals.first)
    }

    private func assertExactBasisMeal(
        _ meal: Meal,
        item: FoodItem,
        quantity: Double,
        unit: String
    ) throws {
        let component = try #require(meal.componentSnapshots.first)
        #expect(component.quantity == quantity)
        #expect(component.unit == unit)
        #expect(component.macros == item.macros.scaled(by: quantity / item.servingSize))
        #expect(component.micronutrients == item.micronutrients.scaled(by: quantity / item.servingSize))
        #expect(meal.macros == component.macros)
        #expect(meal.macroSnapshot == component.macros)
        #expect(meal.micronutrientSnapshot == component.micronutrients)
        #expect(meal.source == MealLogSource.manual)
        #expect(meal.mealSource == .manual)
    }

    private func syntheticFood(
        name: String,
        servingSize: Double,
        servingUnit: String,
        macros: Macros,
        micros: Micronutrients,
        portion: FoodPortion
    ) -> FoodItem {
        FoodItem(
            name: name,
            servingSize: servingSize,
            servingUnit: servingUnit,
            macros: macros,
            micronutrients: micros,
            category: "Test food",
            source: .usda,
            tags: ["test"],
            portions: [portion]
        )
    }

    private func invalidPortions() -> [FoodPortion] {
        [
            FoodPortion(amount: 0, unit: "slice", gramWeight: 60),
            FoodPortion(amount: -1, unit: "slice", gramWeight: 60),
            FoodPortion(amount: .nan, unit: "slice", gramWeight: 60),
            FoodPortion(amount: .infinity, unit: "slice", gramWeight: 60),
            FoodPortion(amount: 1, unit: "slice", gramWeight: 0),
            FoodPortion(amount: 1, unit: "slice", gramWeight: .nan),
            FoodPortion(amount: 1, unit: "slice", gramWeight: .infinity)
        ]
    }
}
