import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
struct CustomIngredientUpsertTests {
    @Test func resolveInsertsNewManualFoodItem() {
        let verifiedAt = Date(timeIntervalSince1970: 1_779_664_800)
        var foodItems: [FoodItem] = []
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = " House tofu crumble "
        ingredient.quantity = 125
        ingredient.unit = RecipeUnit.gram.rawValue
        ingredient.protein = 18
        ingredient.carbs = 6
        ingredient.fat = 9

        let foodItem = CustomIngredientUpsert.resolve(
            ingredient: ingredient,
            in: &foodItems,
            verifiedAt: verifiedAt
        )

        #expect(foodItems == [foodItem])
        #expect(foodItem.name == "House tofu crumble")
        #expect(foodItem.brandSource == "Custom ingredient")
        #expect(foodItem.servingSize == 125)
        #expect(foodItem.servingUnit == RecipeUnit.gram.rawValue)
        #expect(foodItem.macros == Macros(protein: 18, carbs: 6, fat: 9))
        #expect(foodItem.source == .manual)
        #expect(foodItem.lastVerified == verifiedAt)
        #expect(foodItem.tags == ["recipe", "custom"])
    }

    @Test func resolveUpdatesExistingManualItemByNormalizedName() {
        let existingID = UUID()
        let oldVerifiedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let newVerifiedAt = Date(timeIntervalSince1970: 1_779_664_800)
        var foodItems = [
            foodItem(
                id: existingID,
                name: "House Tofu Crumble",
                source: .manual,
                macros: Macros(protein: 10, carbs: 4, fat: 3),
                lastVerified: oldVerifiedAt
            )
        ]
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = " house tofu crumble "
        ingredient.quantity = 80
        ingredient.unit = RecipeUnit.gram.rawValue
        ingredient.protein = 22
        ingredient.carbs = 8
        ingredient.fat = 10

        let foodItem = CustomIngredientUpsert.resolve(
            ingredient: ingredient,
            in: &foodItems,
            verifiedAt: newVerifiedAt
        )

        #expect(foodItems.count == 1)
        #expect(foodItem.id == existingID)
        #expect(foodItems.first?.id == existingID)
        #expect(foodItems.first?.macros == Macros(protein: 22, carbs: 8, fat: 10))
        #expect(foodItems.first?.lastVerified == newVerifiedAt)
    }

    @Test func resolveDoesNotOverwriteNonManualNameMatch() {
        let usdaID = UUID()
        var foodItems = [
            foodItem(
                id: usdaID,
                name: "House tofu crumble",
                source: .usda,
                macros: Macros(protein: 1, carbs: 2, fat: 3)
            )
        ]
        var ingredient = ManualRecipeIngredientInput()
        ingredient.name = "house tofu crumble"
        ingredient.protein = 18

        let foodItem = CustomIngredientUpsert.resolve(
            ingredient: ingredient,
            in: &foodItems,
            verifiedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )

        #expect(foodItems.count == 2)
        #expect(foodItems.first?.id == usdaID)
        #expect(foodItems.first?.source == .usda)
        #expect(foodItem.id != usdaID)
        #expect(foodItem.source == .manual)
    }

    @Test func recipeIngredientsKeepsSelectedUSDAItemFromSelectionCatalog() {
        var selected = foodItem(
            name: "Chicken breast",
            source: .usda,
            macros: Macros(protein: 31, carbs: 0, fat: 4)
        )
        selected.id = UUID()
        var foodItems: [FoodItem] = []
        var selectedInput = ManualRecipeIngredientInput()
        selectedInput.name = "Chicken breast"
        selectedInput.selectedFoodItemId = selected.id
        selectedInput.quantity = 150
        selectedInput.unit = RecipeUnit.gram.rawValue

        let recipeIngredients = CustomIngredientUpsert.recipeIngredients(
            from: [selectedInput],
            selectionCatalog: [selected],
            in: &foodItems,
            verifiedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )

        #expect(recipeIngredients.count == 1)
        #expect(recipeIngredients[0].foodItemId == selected.id)
        #expect(recipeIngredients[0].quantity == 150)
        #expect(foodItems.isEmpty)
    }

    @Test func recipeIngredientsFiltersEmptyNames() {
        var selected = foodItem(
            name: "Greek yogurt",
            source: .usda,
            macros: Macros(protein: 18, carbs: 6, fat: 0)
        )
        selected.id = UUID()
        var foodItems = [selected]
        var empty = ManualRecipeIngredientInput()
        empty.name = "   "
        var selectedInput = ManualRecipeIngredientInput()
        selectedInput.name = "Greek yogurt"
        selectedInput.selectedFoodItemId = selected.id
        selectedInput.quantity = 170
        selectedInput.unit = RecipeUnit.gram.rawValue
        var customInput = ManualRecipeIngredientInput()
        customInput.name = "House granola"
        customInput.quantity = 40
        customInput.unit = RecipeUnit.gram.rawValue
        customInput.carbs = 24

        let recipeIngredients = CustomIngredientUpsert.recipeIngredients(
            from: [empty, selectedInput, customInput],
            in: &foodItems,
            verifiedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )

        #expect(recipeIngredients.count == 2)
        #expect(recipeIngredients.first?.foodItemId == selected.id)
        #expect(recipeIngredients.first?.quantity == 170)
        #expect(foodItems.count == 2)
        #expect(foodItems.last?.name == "House granola")
        #expect(recipeIngredients.last?.foodItemId == foodItems.last?.id)
    }

    // MARK: - Decimal grams (2026-09-29)

    @Test func resolveKeepsTypedDecimalGramsBesideTheirRounding() throws {
        var foodItems: [FoodItem] = []
        let foodItem = CustomIngredientUpsert.resolve(
            ingredient: decimalInput(protein: 3.4, carbs: 0, fat: 0.5),
            in: &foodItems,
            verifiedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )

        #expect(foodItem.macros == Macros(protein: 3, carbs: 0, fat: 1))
        #expect(foodItem.preciseMacros == PreciseMacros(protein: 3.4, carbs: 0, fat: 0.5))
        #expect(foodItem.exactMacros.protein == 3.4)
        let json = String(decoding: try JSONEncoder().encode(foodItem), as: UTF8.self)
        #expect(json.contains("\"preciseMacros\""))
        #expect(try JSONDecoder().decode(FoodItem.self, from: Data(json.utf8)) == foodItem)
    }

    @Test func wholeGramsAddNoKeyAndResavingWholeGramsClearsTheFraction() throws {
        var foodItems: [FoodItem] = []
        let verifiedAt = Date(timeIntervalSince1970: 1_779_664_800)
        let whole = CustomIngredientUpsert.resolve(
            ingredient: decimalInput(protein: 3, carbs: 12, fat: 0), in: &foodItems, verifiedAt: verifiedAt)
        #expect(whole.preciseMacros == nil)
        #expect(!String(decoding: try JSONEncoder().encode(whole), as: UTF8.self).contains("preciseMacros"))

        let decimal = CustomIngredientUpsert.resolve(
            ingredient: decimalInput(protein: 3.4, carbs: 12, fat: 0), in: &foodItems, verifiedAt: verifiedAt)
        #expect(decimal.id == whole.id)
        #expect(foodItems.first?.exactMacros.protein == 3.4)

        let resaved = CustomIngredientUpsert.resolve(
            ingredient: decimalInput(protein: 4, carbs: 12, fat: 0), in: &foodItems, verifiedAt: verifiedAt)
        #expect(resaved.id == whole.id)
        #expect(foodItems.count == 1)
        #expect(foodItems.first?.preciseMacros == nil)
        #expect(foodItems.first?.macros == Macros(protein: 4, carbs: 12, fat: 0))
    }

    @Test func aSmallDecimalIsNotAnAllZeroEntry() {
        let report = CustomIngredientUpsert.plausibility(of: decimalInput(protein: 0, carbs: 0, fat: 0.4))
        #expect(!report.contradictions.contains(.allReportedValuesZero))
        #expect(!report.advisories.contains(.allReportedValuesZero))
        let untouched = CustomIngredientUpsert.plausibility(of: decimalInput(protein: 0, carbs: 0, fat: 0))
        #expect((untouched.contradictions + untouched.advisories).contains(.allReportedValuesZero))
        #expect(CatalogCustomFoodSaveGate.decision(for: decimalInput(protein: 3.4, carbs: 20.5, fat: 1.2)) == .save)
    }

    private func decimalInput(protein: Double, carbs: Double, fat: Double) -> ManualRecipeIngredientInput {
        ManualRecipeIngredientInput(name: "House granola", quantity: 40, unit: RecipeUnit.gram.rawValue,
                                    protein: protein, carbs: carbs, fat: fat)
    }

    private func foodItem(
        id: UUID = UUID(),
        name: String,
        source: FoodItemSource,
        macros: Macros,
        lastVerified: Date? = nil
    ) -> FoodItem {
        FoodItem(
            id: id,
            name: name,
            brandSource: nil,
            servingSize: 1,
            servingUnit: RecipeUnit.serving.rawValue,
            macros: macros,
            micronutrients: Micronutrients(),
            category: "test",
            source: source,
            lastVerified: lastVerified,
            tags: []
        )
    }
}
