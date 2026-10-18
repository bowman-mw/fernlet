//
//  MealDataAttributionTests.swift
//  FernletTests
//
//  Tracker §2.6 (2026-10-18): a food that came from a barcode lookup on Open Food Facts carries
//  "Data from Open Food Facts (ODbL)" wherever it appears — the lookup and saved-food screens did
//  since 2026-09-24, and now the meal rows, the day detail and the data export do too. The bundled
//  USDA catalog is public domain (CC0: attribution requested, not required), so it adds no line.
//

import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Pins the meal-level licence attribution: which foods produce it, that the store resolves it for
/// a meal logged from a barcode, that the export carries it, and that the two screens draw it.
@MainActor
@Suite
struct MealDataAttributionTests {

    // MARK: - Fixtures

    private static func food(_ name: String, source: FoodItemSource) -> FoodItem {
        FoodItem(name: name, brandSource: "Clif", servingSize: 68, servingUnit: "g",
                 macros: Macros(protein: 10, carbs: 43, fat: 6), micronutrients: Micronutrients(),
                 category: "packaged product", source: source, dataType: .branded,
                 servingDescription: "1 bar", lastVerified: Date(timeIntervalSince1970: 1_790_000_000),
                 tags: [], barcode: source == .openFoodFacts ? "722252100900" : nil)
    }

    private static func meal(componentFoodIDs: [UUID?]) -> Meal {
        let components = componentFoodIDs.map { id in
            MealComponentSnapshot(foodItemId: id, name: "Bar", quantity: 1, unit: "serving",
                                  macros: Macros(protein: 10, carbs: 43, fat: 6), micronutrients: Micronutrients())
        }
        return Meal(name: "Snack", mealType: .snack, macros: Macros(protein: 10, carbs: 43, fat: 6),
                    componentSnapshots: components, quality: .ok, confidence: "Manual", note: "", source: "Manual")
    }

    // MARK: - Which foods carry a line

    /// An Open Food Facts component gives the ODbL line, once however many components share it; the
    /// sources with no obligation, an unresolvable food and a component with no food give none.
    @Test func onlyAnAttributedSourceGivesALineAndEachLineAppearsOnce() {
        let off = Self.food("Clif", source: .openFoodFacts)
        let others = [Self.food("USDA", source: .usda), Self.food("Mine", source: .manual),
                      Self.food("AI", source: .aiResolved)]
        let sources = Dictionary(uniqueKeysWithValues: ([off] + others).map { ($0.id, $0.source) })

        let attributed = Self.meal(componentFoodIDs: [others[0].id, off.id, off.id])
        #expect(attributed.attributionLines { sources[$0] } == [FoodItemSource.openFoodFactsAttribution])

        let unattributed = Self.meal(componentFoodIDs: others.map(\.id) + [UUID(), nil])
        #expect(unattributed.attributionLines { sources[$0] }.isEmpty)
    }

    // MARK: - The store

    /// A meal logged from a scanned Open Food Facts product resolves to the line through the store;
    /// a meal logged from the user's own food does not.
    @Test func aMealLoggedFromAScannedOpenFoodFactsProductCarriesTheLine() {
        let store = makeTestStore()
        let off = Self.food("Clif", source: .openFoodFacts)
        let mine = Self.food("Granola", source: .manual)
        store.foodItems = [off, mine]

        let scanned = store.logBarcodeScannedFoodItem(off, mealType: .snack, servings: 1)
        let typed = store.logBarcodeScannedFoodItem(mine, mealType: .snack, servings: 1)
        #expect(store.dataAttribution(for: scanned) == FoodItemSource.openFoodFactsAttribution)
        #expect(store.dataAttribution(for: typed) == nil)
    }

    // MARK: - The export

    /// The export carries the line on the meal it belongs to, and omits the field on every other.
    @Test func theExportCarriesTheLineOnTheAttributedMealOnly() throws {
        let store = makeTestStore()
        let off = Self.food("Clif", source: .openFoodFacts)
        let mine = Self.food("Granola", source: .manual)
        store.foodItems = [off, mine]
        let scanned = store.logBarcodeScannedFoodItem(off, mealType: .snack, servings: 1)
        let typed = store.logBarcodeScannedFoodItem(mine, mealType: .snack, servings: 1)

        let meals = try #require(store.buildDataExport().days.first { $0.day == store.todayKey }?.meals)
        let byName = Dictionary(meals.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byName[scanned.name]?.attribution == FoodItemSource.openFoodFactsAttribution)
        #expect(byName[typed.name] != nil)
        #expect(byName[typed.name]?.attribution == nil)
    }

    // MARK: - The two screens

    /// The Food tab's meal rows and the past day's detail both draw the store's line. A source pin:
    /// SwiftUI bodies are not otherwise inspectable here, and dropping either argument compiles clean.
    @Test func theMealRowAndTheDayDetailDrawTheStoresLine() throws {
        let food = try RepoRoot.source("App/Fernlet/FoodView.swift")
        #expect(food.contains("dataAttribution: store.dataAttribution(for: meal)"),
                "FoodView's MealRow no longer receives the meal's licence attribution")
        #expect(food.contains("Text(verbatim: dataAttribution)"), "MealRow no longer draws its attribution")
        let journal = try RepoRoot.source("App/Fernlet/JournalView.swift")
        #expect(journal.contains("if let attribution = store.dataAttribution(for: meal)"),
                "the day detail's meal list no longer draws the meal's licence attribution")
    }
}
