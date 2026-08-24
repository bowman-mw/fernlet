import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Regression coverage for item 10's query binding and custom-food save gate.
struct CatalogTypeaheadResultSetTests {
    @Test func recipeIngredientCannotSelectOrSaveAStaleAppleRow() {
        let apple = Self.apple
        var results = settledAppleResults(apple)
        #expect(results.visibleMatches(for: "apple").first?.id == apple.id)

        let editedQuery = "apple zzznotfood"
        var savedFoodID: UUID?
        if let stalePick = results.selectable(apple, for: editedQuery) {
            savedFoodID = stalePick.id
        }
        #expect(results.visibleMatches(for: editedQuery).isEmpty)
        #expect(savedFoodID == nil)
        results.clear()
        #expect(results.visibleMatches(for: editedQuery).isEmpty)
    }

    @Test func mealComposerCannotStageAStaleAppleRow() {
        let apple = Self.apple
        let results = settledAppleResults(apple)
        #expect(results.selectable(apple, for: "apple")?.id == apple.id)

        let editedQuery = "apple zzznotfood"
        let stagedFood = results.selectable(apple, for: editedQuery)
        #expect(results.visibleMatches(for: editedQuery).isEmpty)
        #expect(stagedFood == nil)
    }

    @Test func mealCorrectionCannotPoisonMemoryWithAStaleAppleRow() {
        let apple = Self.apple
        let results = settledAppleResults(apple)
        var correctionDraft = FoodSearchCorrectionDraft()

        let editedQuery = "apple zzznotfood"
        if let stalePick = results.selectable(apple, for: editedQuery) {
            correctionDraft.record(
                searchText: editedQuery,
                prefilledWith: "Wrong match",
                foodItemID: stalePick.id
            )
        }
        #expect(results.visibleMatches(for: editedQuery).isEmpty)
        #expect(correctionDraft.corrections.isEmpty)
    }

    @Test func absurdCustomFoodRoutesToReviewBeforeSaveAnyway() {
        let input = customInput(protein: 300, carbs: 500, fat: 300)
        #expect(input.macros.calories == 5_900)

        guard case .review(let report) = CatalogCustomFoodSaveGate.decision(for: input) else {
            Issue.record("a 5,900 kcal macro tuple bypassed the existing plausibility review")
            return
        }
        #expect(report.needsReview)
        #expect(report.advisories.count == 3)
    }

    @Test func ordinaryCustomFoodIsCleanAndSavesThroughExistingUpsert() {
        let input = customInput(protein: 18, carbs: 24, fat: 9)
        #expect(CatalogCustomFoodSaveGate.decision(for: input) == .save)

        var foodItems: [FoodItem] = []
        let saved = CustomIngredientUpsert.resolve(
            ingredient: input,
            in: &foodItems,
            verifiedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
        #expect(foodItems == [saved])
        #expect(saved.macros == input.macros)
    }

    private func settledAppleResults(_ apple: FoodItem) -> CatalogTypeaheadResultSet {
        var results = CatalogTypeaheadResultSet()
        results.bind([apple], to: "  APPLE ")
        return results
    }

    private func customInput(protein: Int, carbs: Int, fat: Int) -> ManualRecipeIngredientInput {
        ManualRecipeIngredientInput(
            name: "House test food",
            quantity: 1,
            unit: RecipeUnit.serving.rawValue,
            protein: protein,
            carbs: carbs,
            fat: fat
        )
    }

    private static let apple = FoodItem(
        name: "Apple, raw",
        brandSource: nil,
        servingSize: 1,
        servingUnit: RecipeUnit.serving.rawValue,
        macros: Macros(protein: 0, carbs: 25, fat: 0),
        micronutrients: Micronutrients(),
        category: "fruit",
        source: .usda,
        lastVerified: nil,
        tags: ["apple"]
    )
}
