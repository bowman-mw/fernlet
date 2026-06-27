//
//  FoodSearchLabelAndFallbackTests.swift
//  FernletTests
//
//  Covers the Item 3 (Remaining-work doc) food slices implemented in this pass: per-row data-source
//  labels for ingredient search, and catalog-grounded micronutrient fallback so manually parsed
//  meals no longer log an empty micronutrient snapshot.
//

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

struct FoodSearchLabelAndFallbackTests {

    // MARK: - Data-source labels

    @Test func dataSourceLabelReflectsProvenance() {
        #expect(makeFood(source: .manual).dataSourceLabel == "Your foods")
        #expect(makeFood(source: .aiResolved).dataSourceLabel == "AI estimate")
        #expect(makeFood(source: .usda, dataType: .foundation).dataSourceLabel == "USDA")
        #expect(makeFood(source: .usda, dataType: .srLegacy).dataSourceLabel == "USDA")
        #expect(makeFood(source: .usda, dataType: .branded, brandSource: "Chobani").dataSourceLabel == "Chobani")
        #expect(makeFood(source: .usda, dataType: .branded, brandSource: nil).dataSourceLabel == "Branded")
        #expect(makeFood(source: .usda, dataType: .restaurant, brandSource: nil).dataSourceLabel == "Restaurant")
    }

    // MARK: - Fallback micronutrients

    @MainActor
    @Test func manuallyParsedMealBorrowsMicronutrientsFromCatalog() {
        let chicken = makeFood(
            name: "Chicken breast",
            source: .usda,
            dataType: .foundation,
            micronutrients: Micronutrients(vitaminB6: 0.9, niacin: 13, iron: 1.1, phosphorus: 210, potassium: 256)
        )
        let store = makeTestStore(bundledFoodItems: [chicken])

        let meal = store.addMeal(from: "chicken breast", type: MealType.lunch)
        #expect(meal.micronutrientSnapshot.hasAnyValue)
        #expect(store.day.meals.last?.micronutrientSnapshot.hasAnyValue == true)
    }

    @MainActor
    @Test func manuallyParsedMealWithoutCatalogMatchLeavesMicrosEmpty() {
        let store = makeTestStore() // empty in-memory catalog
        let meal = store.addMeal(from: "qwxz mystery dish", type: MealType.lunch)
        #expect(meal.micronutrientSnapshot.hasAnyValue == false)
    }

    @MainActor
    @Test func fallbackMicronutrientsHelperReturnsEmptyWhenUnmatched() {
        let store = makeTestStore()
        #expect(store.fallbackMicronutrients(for: "qwxz mystery dish").hasAnyValue == false)
    }

    // MARK: - Helpers

    private func makeFood(
        name: String = "Test food",
        source: FoodItemSource,
        dataType: FoodDataType = .srLegacy,
        brandSource: String? = nil,
        micronutrients: Micronutrients = Micronutrients()
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: brandSource,
            servingSize: 100,
            servingUnit: "g",
            macros: Macros(protein: 20, carbs: 0, fat: 3),
            micronutrients: micronutrients,
            category: "Protein",
            source: source,
            dataType: dataType,
            tags: []
        )
    }
}
