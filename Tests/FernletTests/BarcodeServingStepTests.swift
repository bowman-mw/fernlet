import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

/// Feedback #13 "scanned food should keep the serving number": the scan log paths now take a
/// serving count that scales macros + micros and is persisted as a single editable component, plus a
/// device-local per-GTIN last-used memory that prefills the quick serving step.
struct BarcodeServingStepTests {
    // MARK: - Fixtures

    private static func sampleItem(
        name: String = "Hazelnut oat bar",
        macros: Macros = Macros(protein: 5, carbs: 20, fat: 7),
        micronutrients: Micronutrients = Micronutrients(fiber: 3, sugar: 8, sodium: 90),
        barcode: String? = "0012345678905"
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: 40,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: macros,
            micronutrients: micronutrients,
            category: "Snacks",
            source: .usda,
            tags: ["test"],
            barcode: barcode
        )
    }

    // MARK: - Serving scaling (part a / part e)

    @MainActor
    @Test func barcodeScanWithTwoServingsDoublesMacrosAndMicrosAndRecordsComponent() throws {
        let store = makeTestStore()
        let item = Self.sampleItem()

        let meal = store.logBarcodeScannedFoodItem(item, mealType: .snack, servings: 2)

        // Top-level macros/micros are doubled.
        #expect(meal.macros == item.macros.scaled(by: 2))
        #expect(meal.macros.protein == 10)
        #expect(meal.macros.carbs == 40)
        #expect(meal.macros.fat == 14)
        #expect(meal.micronutrientSnapshot.fiber == 6)
        #expect(meal.micronutrientSnapshot.sugar == 16)
        #expect(meal.micronutrientSnapshot.sodium == 180)

        // The serving count is persisted as a single editable component (quantity 2, `serving` unit),
        // whose stored macros are the already-scaled totals MealBuilder.totals sums directly.
        #expect(meal.componentSnapshots.count == 1)
        let component = try #require(meal.componentSnapshots.first)
        #expect(component.quantity == 2)
        #expect(component.unit == RecipeUnit.serving.rawValue)
        #expect(component.foodItemId == item.id)
        #expect(component.macros == item.macros.scaled(by: 2))
        #expect(component.micronutrients.fiber == 6)

        #expect(meal.source == MealLogSource.barcodeScan)
        #expect(store.day.meals.last?.id == meal.id)
    }

    @MainActor
    @Test func barcodeScanWithOneServingMatchesPerServingMacros() throws {
        let store = makeTestStore()
        let item = Self.sampleItem()

        // Default servings == 1: the scaling is a no-op, so macros/micros match the plain product —
        // the "matches previous behavior" contract. The single serving is still recorded as an
        // editable component (quantity 1) so the count can be corrected later.
        let meal = store.logBarcodeScannedFoodItem(item, mealType: .snack)

        #expect(meal.macros == item.macros)
        #expect(meal.micronutrientSnapshot.fiber == 3)
        #expect(meal.micronutrientSnapshot.sodium == 90)
        #expect(meal.componentSnapshots.count == 1)
        #expect(meal.componentSnapshots.first?.quantity == 1)
        #expect(meal.componentSnapshots.first?.macros == item.macros)
    }

    @MainActor
    @Test func labelScanWithFractionalServingsScalesAndKeepsLabelProvenance() throws {
        let store = makeTestStore()
        let item = Self.sampleItem(name: "Scanned yogurt", barcode: nil)

        let meal = store.logLabelScannedFoodItem(item, mealType: .breakfast, servings: 1.5)

        #expect(meal.macros == item.macros.scaled(by: 1.5))
        #expect(meal.macros.protein == 8)   // 5 * 1.5 = 7.5 -> rounds to 8
        #expect(meal.source == MealLogSource.labelScan)
        #expect(meal.componentSnapshots.first?.quantity == 1.5)
        #expect(meal.componentSnapshots.first?.unit == RecipeUnit.serving.rawValue)
    }

    @MainActor
    @Test func webImportPathStaysComponentFree() throws {
        // The `servings`-less paths must be untouched: no component, no scaling. Guards against the
        // shared builder accidentally attaching a serving component to non-scan meals.
        let store = makeTestStore()
        let item = Self.sampleItem(name: "Saved product", barcode: nil)

        let webMeal = store.logWebImportedFoodProduct(item, mealType: .lunch)
        #expect(webMeal.componentSnapshots.isEmpty)
        #expect(webMeal.macros == item.macros)
    }

    @MainActor
    @Test func catalogPickPreservesExactIdentityAsOneEditableServing() throws {
        let store = makeTestStore()
        let item = Self.sampleItem(name: "Sliced Pizza, Cheese", barcode: nil)

        let meal = store.logCatalogFoodItem(item, mealType: .dinner)
        let component = try #require(meal.componentSnapshots.first)

        #expect(meal.name == item.name)
        #expect(meal.mealType == .dinner)
        #expect(meal.macros == item.macros)
        #expect(meal.micronutrientSnapshot == item.micronutrients)
        #expect(meal.confidence == MealConfidence.foodMatch.token)
        #expect(meal.source == MealLogSource.manual)
        #expect(component.foodItemId == item.id)
        #expect(component.quantity == 1)
        #expect(component.unit == RecipeUnit.serving.rawValue)
        #expect(store.day.meals.last?.id == meal.id)
    }

    // MARK: - Per-GTIN last-used memory (part c / part e)

    @Test func servingMemoryRoundTripsAndNormalizesGTIN() throws {
        let suite = "test.barcodeServing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Unknown product → no prefill.
        #expect(BarcodeServingMemory.lastServings(for: "0012345678905", defaults: defaults) == nil)

        BarcodeServingMemory.setLastServings(2.5, for: "012345678905", defaults: defaults)
        // Same product read back by its exact key…
        #expect(BarcodeServingMemory.lastServings(for: "012345678905", defaults: defaults) == 2.5)
        // …and by an equivalent GTIN form (12-digit UPC and 14-digit GTIN normalize to one key).
        #expect(BarcodeServingMemory.lastServings(for: "00012345678905", defaults: defaults) == 2.5)
        // …and by the 13-digit EAN form with the same trailing digits.
        #expect(BarcodeServingMemory.lastServings(for: "0012345678905", defaults: defaults) == 2.5)

        // A later log overwrites the remembered count.
        BarcodeServingMemory.setLastServings(1, for: "00012345678905", defaults: defaults)
        #expect(BarcodeServingMemory.lastServings(for: "012345678905", defaults: defaults) == 1)
    }

    @Test func servingMemoryIgnoresInvalidCodesAndNonPositiveCounts() throws {
        let suite = "test.barcodeServing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Too-short / empty / nil barcodes are unrecognizable — nothing stored, nothing read.
        BarcodeServingMemory.setLastServings(3, for: "123", defaults: defaults)
        #expect(BarcodeServingMemory.lastServings(for: "123", defaults: defaults) == nil)
        BarcodeServingMemory.setLastServings(3, for: "", defaults: defaults)
        #expect(BarcodeServingMemory.lastServings(for: "", defaults: defaults) == nil)
        BarcodeServingMemory.setLastServings(3, for: nil, defaults: defaults)
        #expect(BarcodeServingMemory.lastServings(for: nil, defaults: defaults) == nil)

        // A non-positive count carries no useful prefill and is not stored.
        BarcodeServingMemory.setLastServings(0, for: "0012345678905", defaults: defaults)
        #expect(BarcodeServingMemory.lastServings(for: "0012345678905", defaults: defaults) == nil)
    }

    // MARK: - Delete-all wipe (finding 2)

    @Test func clearAllForgetsEveryRememberedCount() throws {
        let suite = "test.barcodeServing.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        BarcodeServingMemory.setLastServings(2, for: "0012345678905", defaults: defaults)
        BarcodeServingMemory.setLastServings(3, for: "0044000031457", defaults: defaults)
        #expect(BarcodeServingMemory.lastServings(for: "0012345678905", defaults: defaults) == 2)

        BarcodeServingMemory.clearAll(defaults: defaults)

        #expect(BarcodeServingMemory.lastServings(for: "0012345678905", defaults: defaults) == nil)
        #expect(BarcodeServingMemory.lastServings(for: "0044000031457", defaults: defaults) == nil)
        #expect(defaults.dictionary(forKey: BarcodeServingMemory.defaultsKey) == nil)
    }

    @MainActor
    @Test func storeResetAllClearsBarcodeServingMemory() {
        // The per-GTIN memory is a `.standard`-backed device-local sidecar, so a full wipe must clear it
        // like the other device-local ledgers (heart, closeness, moderation…). This drives the real
        // store wipe path (`resetAll`, which `deleteAllData` also calls) to prove the wiring. It touches
        // the shared `.standard` domain, so it cleans up with `defer`; only removals touch that key here,
        // so the post-wipe assertion converges even under parallel suites.
        let key = BarcodeServingMemory.defaultsKey
        defer { UserDefaults.standard.removeObject(forKey: key) }

        BarcodeServingMemory.setLastServings(3, for: "0012345678905")

        let store = makeTestStore()
        _ = store.resetAll()

        #expect(BarcodeServingMemory.lastServings(for: "0012345678905") == nil)
        #expect(UserDefaults.standard.dictionary(forKey: key) == nil)
    }

    // MARK: - Serving floor (review 2026-07-27)

    /// The store used to clamp with `max(servings, 0)`, so a 0 passed straight through and wrote a
    /// meal contributing nothing, with a `.serving` component of quantity 0 in the correction
    /// sheet. The UI's save bar happens to disable at <= 0, but the invariant belongs where the
    /// data is written — the log methods are public API with a defaulted `servings`. Note the
    /// normalization is to ONE serving, not to an epsilon: `Macros` fields are `Int`, so a 0.01
    /// floor would still round every macro to zero and leave the row contributing nothing.
    @MainActor
    @Test func nonPositiveServingsNormalizeToOneServing() throws {
        let store = makeTestStore()
        let item = Self.sampleItem()

        for badCount in [0.0, -3.0] {
            let meal = store.logBarcodeScannedFoodItem(item, mealType: .snack, servings: badCount)
            let component = try #require(meal.componentSnapshots.first)
            #expect(component.quantity == 1, "A logged meal never records a zero serving count")
            #expect(meal.macros == item.macros, "…and never records macros that contribute nothing")
            #expect(meal.macros.protein == 5)
        }

        // The label path shares the same construction, so it inherits the same rule.
        let labelMeal = store.logLabelScannedFoodItem(item, mealType: .snack, servings: 0)
        #expect(try #require(labelMeal.componentSnapshots.first).quantity == 1)

        // A genuine fractional count is untouched — this normalizes bad input, it doesn't round.
        let half = store.logBarcodeScannedFoodItem(item, mealType: .snack, servings: 0.5)
        #expect(try #require(half.componentSnapshots.first).quantity == 0.5)
        #expect(half.macros == item.macros.scaled(by: 0.5))
    }
}
