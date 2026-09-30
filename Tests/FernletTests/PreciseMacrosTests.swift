import Foundation
import Testing
import FernletDomainModel

/// The decimal-grams side channel (2026-09-29). The load-bearing property is the first one: for a
/// whole-gram food the precise path produces EXACTLY the numbers the legacy `Macros.scaled(by:)` did,
/// so no existing total, golden or wire byte moves.
struct PreciseMacrosTests {

    @Test func scalingAWholeGramFoodMatchesTheLegacyRuleEverywhere() {
        let foods = [Macros(protein: 0, carbs: 0, fat: 0), Macros(protein: 1, carbs: 2, fat: 3),
                     Macros(protein: 13, carbs: 67, fat: 7), Macros(protein: 31, carbs: 0, fat: 4),
                     Macros(protein: 250, carbs: 300, fat: 200), Macros(protein: 5, carbs: 5, fat: 5)]
        let scales: [Double] = [0, 1, 1.0 / 3.0, 0.5, 1.5, 2.5, 0.37, 7.25, 150.0 / 100.0, 1_000,
                                -1, -0.5, .nan, .infinity, -.infinity, .greatestFiniteMagnitude]
        for food in foods {
            for scale in scales {
                #expect(PreciseMacros(food).scaled(by: scale).rounded == food.scaled(by: scale),
                        "\(food) × \(scale)")
                let item = foodItem(macros: food)
                #expect(item.scaledMacros(by: scale) == food.scaled(by: scale), "\(food) × \(scale)")
            }
        }
    }

    @Test func aDecimalIngredientRoundsOnceFromItsExactValue() {
        let precise = PreciseMacros(protein: 3.4, carbs: 0, fat: 0.5)
        #expect(precise.rounded == Macros(protein: 3, carbs: 0, fat: 1))   // half away from zero
        #expect(precise.scaled(by: 3).rounded == Macros(protein: 10, carbs: 0, fat: 2))   // not 9 and 3
        #expect(PreciseMacros(protein: 2.5, carbs: 0, fat: 0).rounded.protein == 3)
    }

    @Test func theInitializerSanitizesWhatJSONCouldNotEncode() throws {
        let hostile = PreciseMacros(protein: .nan, carbs: -.infinity, fat: -3)
        #expect(hostile == PreciseMacros(protein: 0, carbs: 0, fat: 0))
        #expect(PreciseMacros(protein: -0.0, carbs: 0, fat: 0).protein.sign == .plus)
        #expect(PreciseMacros(protein: .infinity, carbs: 1, fat: 1).protein == 0)
        // Encodable without throwing: the snapshot save never dies on one field.
        #expect(throws: Never.self) { try JSONEncoder().encode(hostile) }
    }

    @Test func fractionalPartAndValidity() throws {
        #expect(PreciseMacros(protein: 3.4, carbs: 0, fat: 0).hasFractionalPart)
        #expect(!PreciseMacros(protein: 3, carbs: 12, fat: 0).hasFractionalPart)
        #expect(PreciseMacros(protein: 3, carbs: 0, fat: 0).isValid)
        #expect(!PreciseMacros(protein: PreciseMacros.maxGrams + 1, carbs: 0, fat: 0).isValid)
        // The decode is RAW: a negative value survives it, and `isValid` is what refuses it.
        let decoded = try JSONDecoder().decode(PreciseMacros.self,
                                               from: Data(#"{"protein":-2.5,"carbs":1,"fat":0}"#.utf8))
        #expect(decoded.protein == -2.5)
        #expect(!decoded.isValid)
    }

    @Test func aFoodItemKeepsOnlyAFractionalValueThatAgreesWithItsWholeGrams() {
        let decimal = foodItem(macros: Macros(protein: 0, carbs: 0, fat: 0),
                               precise: PreciseMacros(protein: 3.4, carbs: 0, fat: 0.5))
        #expect(decimal.macros == Macros(protein: 3, carbs: 0, fat: 1))   // derived from the fraction
        #expect(decimal.preciseMacros == PreciseMacros(protein: 3.4, carbs: 0, fat: 0.5))
        #expect(decimal.exactMacros.protein == 3.4)
        #expect(decimal.hasFractionalMacros)
        #expect(decimal.scaledMacros(by: 3) == Macros(protein: 10, carbs: 0, fat: 2))

        let whole = foodItem(macros: Macros(protein: 3, carbs: 0, fat: 0), precise: PreciseMacros(protein: 3, carbs: 0, fat: 0))
        #expect(whole.preciseMacros == nil)
        #expect(!whole.hasFractionalMacros)

        var edited = decimal
        edited.macros = Macros(protein: 9, carbs: 0, fat: 1)   // a stale side channel is never trusted
        #expect(edited.exactMacros == PreciseMacros(Macros(protein: 9, carbs: 0, fat: 1)))
        #expect(!edited.hasFractionalMacros)
    }

    @Test func theServingConversionRoundsOnceFromTheExactGrams() throws {
        let food = foodItem(macros: Macros(protein: 0, carbs: 0, fat: 0),
                            precise: PreciseMacros(protein: 3.4, carbs: 1.2, fat: 0.3))
        let ingredient = RecipeIngredient(foodItemId: food.id, quantity: 3, unit: RecipeUnit.serving.rawValue)
        let conversion = try #require(ingredient.servingConversion(using: food))
        let exact = conversion.scaledPreciseMacros(for: food)
        #expect(abs(exact.protein - 10.2) < 1e-9)
        #expect(conversion.scaledMacros(for: food) == Macros(protein: 10, carbs: 4, fat: 1))
        #expect(exact.rounded == conversion.scaledMacros(for: food))
    }

    // MARK: - Tenths of a gram: the row and the total agree (fix round 1, 2026-09-30)

    @Test func theTenthARowShowsAndTheWholeGramItCountsAgree() throws {
        // Typed as 4.1 g protein per 100 g and used at 60 g: exactly 2.46 g, which the row shows as
        // "2.5". The total must count 3 (2.5 rounded), never the 2 a raw 2.46 would round to.
        let food = FoodItem(name: "House granola", servingSize: 100, servingUnit: RecipeUnit.gram.rawValue,
                            macros: Macros(protein: 0, carbs: 0, fat: 0), micronutrients: Micronutrients(),
                            category: "custom ingredient", source: .manual, tags: [],
                            preciseMacros: PreciseMacros(protein: 4.1, carbs: 0.9, fat: 0.4))
        #expect(food.scaledPreciseMacros(by: 0.6) == PreciseMacros(protein: 2.5, carbs: 0.5, fat: 0.2))
        #expect(food.scaledMacros(by: 0.6) == Macros(protein: 3, carbs: 1, fat: 0))
        #expect(MacroGramEntry.display(food.scaledPreciseMacros(by: 0.6).protein,
                                       locale: Locale(identifier: "en_US")) == "2.5")

        let row = ManualRecipeIngredientInput(name: food.name, selectedFoodItemId: food.id, quantity: 60,
                                              unit: RecipeUnit.gram.rawValue)
        let shown = try #require(row.resolvedPreciseMacros(foodItems: [food]))
        #expect(shown.protein == 2.5)
        #expect(row.resolvedMacros(foodItems: [food]) == Macros(protein: 3, carbs: 1, fat: 0))
        #expect(shown.rounded == row.resolvedMacros(foodItems: [food]))
    }

    @Test func everyScaledDecimalCountsTheRoundingOfTheTenthItShows() {
        let foods = [PreciseMacros(protein: 3.4, carbs: 0.5, fat: 0.2), PreciseMacros(protein: 4.1, carbs: 12.7, fat: 0.4),
                     PreciseMacros(protein: 0.3, carbs: 24.5, fat: 9.9), PreciseMacros(protein: 250.5, carbs: 0.1, fat: 0)]
        let scales: [Double] = [0, 0.1, 1.0 / 3.0, 0.45, 0.6, 1, 1.5, 2.5, 3, 7.25, 12.5, 100]
        for precise in foods {
            let food = foodItem(macros: Macros(protein: 0, carbs: 0, fat: 0), precise: precise)
            for scale in scales {
                let shown = food.scaledPreciseMacros(by: scale)
                #expect(shown == shown.roundedToTenths, "\(precise) × \(scale)")
                #expect(shown.rounded == food.scaledMacros(by: scale), "\(precise) × \(scale)")
                let rawProtein = precise.protein * scale
                let tenthShown = MacroGramEntry.quantized(rawProtein)
                #expect(food.scaledMacros(by: scale).protein == Macros.clampedInt(tenthShown), "\(precise) × \(scale)")
            }
        }
    }

    @Test func aFoodItemStoresItsFractionAtTenths() {
        // 2.46 is stored as the 2.5 a field would show, so its whole grams are 3.
        let rounded = foodItem(macros: Macros(protein: 0, carbs: 0, fat: 0), precise: PreciseMacros(protein: 2.46, carbs: 0, fat: 0))
        #expect(rounded.preciseMacros == PreciseMacros(protein: 2.5, carbs: 0, fat: 0))
        #expect(rounded.macros == Macros(protein: 3, carbs: 0, fat: 0))
        #expect(rounded.scaledMacros(by: 1) == rounded.macros)
        // 2.04 has no fraction at tenths: dropped, and the given whole grams stand.
        let whole = foodItem(macros: Macros(protein: 2, carbs: 0, fat: 0), precise: PreciseMacros(protein: 2.04, carbs: 0, fat: 0))
        #expect(whole.preciseMacros == nil)
        #expect(whole.macros == Macros(protein: 2, carbs: 0, fat: 0))
        // Rounding to tenths is idempotent and never leaves a value invalid.
        let tenths = PreciseMacros(protein: 3.45, carbs: 9_999.96, fat: 0.04).roundedToTenths
        #expect(tenths == PreciseMacros(protein: 3.5, carbs: 10_000, fat: 0))
        #expect(tenths.roundedToTenths == tenths)
        #expect(tenths.isValid)
    }

    private func foodItem(macros: Macros, precise: PreciseMacros? = nil) -> FoodItem {
        FoodItem(name: "House granola", servingSize: 1, servingUnit: RecipeUnit.serving.rawValue,
                 macros: macros, micronutrients: Micronutrients(), category: "custom ingredient",
                 source: .manual, tags: [], preciseMacros: precise)
    }
}
