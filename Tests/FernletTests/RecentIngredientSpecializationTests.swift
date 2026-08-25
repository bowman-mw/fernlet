// RecentIngredientSpecializationTests.swift
// FernletTests

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import AIProviders
@testable import Fernlet

/// Item 9d: a recent food may specialize one complete machine-extracted ingredient phrase, but only
/// after the cold resolver has admitted it. These fixtures intentionally use the deterministic tier:
/// it is the only resolver stage with a whole `MealItemSplitter` phrase rather than arbitrary search
/// fragments.
@MainActor
@Suite
struct RecentIngredientSpecializationTests {
    static func food(
        _ name: String,
        id: UUID = UUID(),
        source: FoodItemSource = .usda,
        macros: Macros = Macros(protein: 3, carbs: 40, fat: 1)
    ) -> FoodItem {
        FoodItem(
            id: id, name: name, servingSize: 60, servingUnit: RecipeUnit.gram.rawValue,
            macros: macros, micronutrients: Micronutrients(), category: "Fixtures", source: source,
            dataType: .foundation, tags: []
        )
    }

    static func candidates(_ foods: [FoodItem]) -> [FoodSelectionCandidate] {
        foods.enumerated().map { FoodSelectionCandidate(id: $0.offset + 1, foodItem: $0.element) }
    }

    static func selectedIngredient(
        _ description: String,
        candidates: [FoodSelectionCandidate],
        personalization: FoodIngredientPersonalization = .empty
    ) -> FoodSelectionIngredient? {
        FoundationFoodSelectionModel.deterministicPlan(
            description: description, candidates: candidates, fallbackType: .lunch, personalization: personalization
        )?.items.first?.ingredients.first
    }

    @Test func labelledLeadBankSeparatesClearHistoryFromAmbiguity() {
        let basmati = Self.food("Basmati Rice"), jasmine = Self.food("Jasmine Rice")
        let candidates = [basmati, jasmine]
        let labelledCases: [(weights: [UUID: Int], expected: UUID?)] = [
            ([basmati.id: 693], basmati.id),             // one current log versus cold
            ([basmati.id: 693, jasmine.id: 660], nil),   // one-day recency difference: ambiguous
            ([basmati.id: 1_099, jasmine.id: 693], basmati.id) // repeated current choice: clear
        ]
        for labelledCase in labelledCases {
            let selected = FoodSearchHistory(weights: labelledCase.weights).preferredRecentIngredientID(
                forCompletePhrase: "rice", among: candidates
            )
            #expect(selected == labelledCase.expected)
        }
        #expect(FoodSearchHistory.minimumIngredientSpecializationLead == 250)
    }

    @Test func clearBasmatiHistorySpecializesGenericRiceWithoutInjection() {
        let generic = Self.food("Rice"), basmati = Self.food("Basmati Rice")
        let candidates = Self.candidates([generic, basmati])
        let history = FoodSearchHistory(weights: [basmati.id: 693])
        let personalization = FoodIngredientPersonalization(corrections: [:], history: history)
        let cold = Self.selectedIngredient("rice", candidates: candidates)
        let warm = Self.selectedIngredient("rice", candidates: candidates, personalization: personalization)
        #expect(cold?.candidateId == 1)
        #expect(warm?.candidateId == 2)
        #expect(personalization.preferredFoodID(forCompletePhrase: "rice", among: [generic]) == nil,
                "history must not inject a food absent from the admitted candidate window")
    }

    @Test func explicitWordingAndSavedCorrectionOutrankRecentSpecialization() {
        let generic = Self.food("Rice"), brown = Self.food("Brown Rice"), basmati = Self.food("Basmati Rice")
        let history = FoodSearchHistory(weights: [basmati.id: 693])
        let corrected = FoodIngredientPersonalization(corrections: ["rice": generic.id], history: history)
        #expect(corrected.preferredFoodID(forCompletePhrase: "rice", among: [generic, basmati]) == generic.id)

        let staleCorrection = FoodIngredientPersonalization(corrections: ["brown rice": basmati.id], history: history)
        let selection = Self.selectedIngredient(
            "brown rice", candidates: Self.candidates([brown, basmati]), personalization: staleCorrection
        )
        #expect(selection?.candidateId == 1, "current explicit wording must veto an incompatible correction/history")
    }

    @Test func completePhrasePreventsDishAndFragmentContamination() {
        let basmati = Self.food("Basmati Rice")
        let cases = [
            ("rice pudding", Self.food("Rice Pudding")),
            ("rice noodles", Self.food("Rice Noodles")),
            ("chicken rice bowl", Self.food("Chicken Rice Bowl"))
        ]
        let personalization = FoodIngredientPersonalization(
            corrections: [:], history: FoodSearchHistory(weights: [basmati.id: 693])
        )
        for (phrase, matchingFood) in cases {
            let selected = Self.selectedIngredient(
                phrase, candidates: Self.candidates([matchingFood, basmati]), personalization: personalization
            )
            #expect(selected?.candidateId == 1, "\(phrase) must not inherit the `rice` specialization")
        }
    }

    @Test func ambiguousAndWipedHistoryStayColdWhileManualIDsParticipate() {
        let generic = Self.food("Rice"), basmati = Self.food("Basmati Rice"), jasmine = Self.food("Jasmine Rice")
        let ambiguous = FoodIngredientPersonalization(
            corrections: [:], history: FoodSearchHistory(weights: [basmati.id: 693, jasmine.id: 693])
        )
        let candidates = Self.candidates([generic, basmati, jasmine])
        #expect(Self.selectedIngredient("rice", candidates: candidates, personalization: ambiguous)?.candidateId == 1)

        let manualID = UUID()
        let manual = Self.food("Basmati Rice", id: manualID, source: .manual)
        let used = FoodIngredientPersonalization(
            corrections: [:], history: FoodSearchHistory(weights: [manualID: 693])
        )
        #expect(used.preferredFoodID(forCompletePhrase: "rice", among: [generic, manual]) == manualID)
        let wiped = FoodIngredientPersonalization(corrections: [:], history: .empty)
        #expect(wiped.preferredFoodID(forCompletePhrase: "rice", among: [generic, manual]) == nil)
    }

    @Test func specializationLeavesTheChosenFoodsServingConversionAndNutritionUntouched() {
        let generic = Self.food("Rice", macros: Macros(protein: 2, carbs: 30, fat: 0))
        let basmati = Self.food("Basmati Rice", macros: Macros(protein: 4, carbs: 45, fat: 1))
        let candidates = Self.candidates([generic, basmati])
        let personalization = FoodIngredientPersonalization(
            corrections: [:], history: FoodSearchHistory(weights: [basmati.id: 693])
        )
        guard let ingredient = Self.selectedIngredient("rice", candidates: candidates, personalization: personalization) else {
            Issue.record("the admitted specialization did not produce an ingredient")
            return
        }
        let meal = MealBuilder.mealFromIngredients(
            itemName: "rice", resolvedIngredients: [(ingredient, basmati)], mealType: .lunch
        )
        #expect(ingredient.candidateId == 2)
        #expect(meal?.componentSnapshots.first?.quantity == basmati.servingSize)
        #expect(meal?.componentSnapshots.first?.unit == RecipeUnit.gram.rawValue)
        #expect(meal?.macros == basmati.macros)
    }

    /// Task 9's predeclared personalized panel: history may select an admitted whole-phrase row, but
    /// its cold score alone still decides review. A tied history remains cold, and a weak row stays
    /// weak even when it is the user's most recent matching food.
    @Test func personalizationCannotMintConfidenceOrResolveAnAmbiguousTie() {
        let generic = Self.food("Rice"), basmati = Self.food("Basmati Rice"), jasmine = Self.food("Jasmine Rice")
        let candidates = Self.candidates([generic, basmati, jasmine])
        let clear = FoodIngredientPersonalization(
            corrections: [:], history: FoodSearchHistory(weights: [basmati.id: 693])
        )
        let clearPlan = FoundationFoodSelectionModel.deterministicPlan(
            description: "rice", candidates: candidates, fallbackType: .lunch, personalization: clear
        )
        guard let clearPlan else {
            Issue.record("personalized whole-phrase plan must resolve")
            return
        }
        #expect(clearPlan.items.first?.ingredients.first?.candidateId == 2)
        #expect(MealResolutionService.bindConfidence(for: clearPlan, candidates: candidates) == .low)

        let tied = FoodIngredientPersonalization(
            corrections: [:], history: FoodSearchHistory(weights: [basmati.id: 693, jasmine.id: 693])
        )
        #expect(Self.selectedIngredient("rice", candidates: candidates, personalization: tied)?.candidateId == 1)

        let weak = Self.food("Shredded blend of cheddar and cheese")
        let weakCandidates = Self.candidates([weak])
        let weakPlan = FoundationFoodSelectionModel.deterministicPlan(
            description: "cheese cheddar", candidates: weakCandidates, fallbackType: .lunch,
            personalization: FoodIngredientPersonalization(
                corrections: [:], history: FoodSearchHistory(weights: [weak.id: 693])
            )
        )
        let score = FoodItemSearch.scoredResults(
            for: "cheese cheddar", in: FoodItemSearch.Index(foodItems: [weak]), limit: 1
        ).first?.score ?? 0
        guard let weakPlan else {
            Issue.record("weak personalized whole-phrase plan must resolve")
            return
        }
        #expect(score < FoodItemSearch.confidentBindScore)
        #expect(MealResolutionService.bindConfidence(for: weakPlan, candidates: weakCandidates) == .low)
    }
}
