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

    private func foodItem(macros: Macros, precise: PreciseMacros? = nil) -> FoodItem {
        FoodItem(name: "House granola", servingSize: 1, servingUnit: RecipeUnit.serving.rawValue,
                 macros: macros, micronutrients: Micronutrients(), category: "custom ingredient",
                 source: .manual, tags: [], preciseMacros: precise)
    }
}
