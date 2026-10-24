// FoodLogLaneTests.swift
// FernletTests
//
// The World build's Food logging lane (designs b2-food-rest, b3-meal draft 2, b3-meal-macros draft 2):
// the live camera's nutrition-label cue, the one meal-type dropdown's options, and the macro tags'
// arithmetic.

import FernletDomainModel
import Testing
@testable import Fernlet

/// Pure logic behind the Food logging screens in the World look.
struct FoodLogLaneTests {

    // MARK: - The live camera's label cue

    @Test func aLabelHeadlineAloneIsALabel() {
        #expect(FoodLabelCue.looksLikeNutritionLabel(["Nutrition Facts", "8 servings per container"]))
        #expect(FoodLabelCue.looksLikeNutritionLabel(["INFORMACIÓN NUTRICIONAL"]))
    }

    @Test func threeRowWordsMakeALabelWithoutAHeadline() {
        let lines = ["Serving size 1 bar (40g)", "Total Fat 9g", "Protein 4g"]
        #expect(FoodLabelCue.looksLikeNutritionLabel(lines))
    }

    @Test func twoRowWordsOrOrdinaryTextAreNotALabel() {
        #expect(!FoodLabelCue.looksLikeNutritionLabel(["High protein", "Calories burned today"]))
        #expect(!FoodLabelCue.looksLikeNutritionLabel(["Hazelnut oat bar", "Best before 12/27"]))
        #expect(!FoodLabelCue.looksLikeNutritionLabel([]))
    }

    @Test func aRepeatedRowWordCountsOnce() {
        let lines = Array(repeating: "Protein 4g", count: 10)
        #expect(!FoodLabelCue.looksLikeNutritionLabel(lines))
    }

    @Test func onlyTheFirstLinesAreRead() {
        let filler = Array(repeating: "lorem ipsum", count: FoodLabelCue.maxLines)
        #expect(!FoodLabelCue.looksLikeNutritionLabel(filler + ["Nutrition Facts"]))
    }

    // MARK: - The one meal-type dropdown

    @MainActor
    @Test func theDropdownOffersAutoThenEverySlot() {
        let options = FoodMealTypeDropdown.options
        #expect(options.first == .some(nil))
        #expect(Array(options.dropFirst()) == MealType.allCases.map { Optional($0) })
    }

    // MARK: - Macro tags

    @Test func eachTagReadsItsOwnMacro() {
        let macros = Macros(protein: 28, carbs: 34, fat: 9)
        #expect(FoodMacroKind.allCases.map { $0.grams(in: macros) } == [28, 34, 9])
    }

    @Test func tagFillsStayLight() {
        for kind in FoodMacroKind.allCases {
            #expect(kind.tagFillOpacity > 0 && kind.tagFillOpacity <= 0.25)
        }
    }
}
