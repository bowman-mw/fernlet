import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

struct FoodCatalogTests {
    // MARK: - Sample data

    private static func sampleItem(
        name: String,
        category: String = "Test",
        protein: Int = 0,
        carbs: Int = 0,
        fat: Int = 0,
        source: FoodItemSource = .usda,
        dataType: FoodDataType = .foundation,
        tags: [String] = [],
        micronutrients: Micronutrients = Micronutrients(),
        portions: [FoodPortion] = []
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: protein, carbs: carbs, fat: fat),
            micronutrients: micronutrients,
            category: category,
            source: source,
            dataType: dataType,
            tags: tags,
            portions: portions
        )
    }

    // Stored (not computed) so the items — and their random UUIDs — stay stable within a test:
    // building the DB from these and then looking one up by `.id` must hit the same instance.
    private let sampleItems: [FoodItem] = [
        Self.sampleItem(name: "Chicken breast, roasted", category: "Poultry", protein: 31, fat: 4,
                   tags: ["chicken", "poultry"], micronutrients: Micronutrients(iron: 1.1, potassium: 256)),
        Self.sampleItem(name: "Chicken thigh, grilled", category: "Poultry", protein: 26, fat: 11, tags: ["chicken"]),
        Self.sampleItem(name: "Egg, whole, raw", category: "Dairy and Egg Products", protein: 13, fat: 11, tags: ["egg"]),
        Self.sampleItem(name: "Egg white, raw", category: "Dairy and Egg Products", protein: 11, tags: ["egg"]),
        Self.sampleItem(name: "Rice, brown, cooked", category: "Cereal Grains", carbs: 23, tags: ["rice", "grain"]),
        Self.sampleItem(name: "Rolled oats", category: "Cereal Grains", carbs: 27,
                   tags: ["breakfast", "oats"], portions: [FoodPortion(amount: 1, unit: "cup", gramWeight: 81, description: "1 cup")])
    ]

    private func buildSQLiteSource(_ items: [FoodItem]) throws -> SQLiteBundledFoodSource {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        try FoodCatalogDatabaseBuilder.build(items: items, to: url)
        return try #require(SQLiteBundledFoodSource(url: url))
    }

    // MARK: - Round-trip / hydration

    @Test func sqliteRoundTripsAllItemsAndFields() throws {
        let items = sampleItems
        let source = try buildSQLiteSource(items)
        #expect(source.count == items.count)

        let egg = sampleItems[2]
        let hydrated = try #require(source.item(id: egg.id))
        #expect(hydrated.name == egg.name)
        #expect(hydrated.macros == egg.macros)
        #expect(hydrated.category == egg.category)
        #expect(hydrated.dataType == egg.dataType)
        #expect(hydrated.tags == egg.tags)

        let oats = sampleItems[5]
        let hydratedOats = try #require(source.item(id: oats.id))
        #expect(hydratedOats.portions == oats.portions)

        let chicken = sampleItems[0]
        let hydratedChicken = try #require(source.item(id: chicken.id))
        #expect(hydratedChicken.micronutrients == chicken.micronutrients)
    }

    @Test func itemsByIDsResolvesSubset() throws {
        let items = sampleItems
        let source = try buildSQLiteSource(items)
        let wanted = [items[0].id, items[4].id]
        let resolved = source.items(ids: wanted)
        #expect(Set(resolved.map(\.id)) == Set(wanted))
    }

    @Test func exactMatchIsCaseAndPunctuationInsensitive() throws {
        let source = try buildSQLiteSource(sampleItems)
        let match = source.exactMatch(normalizedName: FoodItemSearch.normalized("chicken breast roasted"))
        #expect(match?.name == "Chicken breast, roasted")
    }

    // MARK: - Search parity with the in-memory scorer

    /// The whole point of the migration: an FTS5 candidate prefilter + the existing scorer must rank
    /// identically to scoring the full in-memory array, because the FTS gate equals the scorer gate.
    @Test func sqliteSearchMatchesInMemoryScorer() throws {
        let items = sampleItems
        let catalog = FoodCatalog(source: try buildSQLiteSource(items))

        for query in ["chicken", "egg", "brown rice", "breast", "roasted chicken", "oats"] {
            let viaCatalog = catalog.results(for: query, limit: 6).map(\.id)
            let inMemory = FoodItemSearch.results(for: query, in: FoodItemSearch.Index(foodItems: items), limit: 6).map(\.id)
            #expect(viaCatalog == inMemory, "ranking diverged for query \(query)")
        }
    }

    /// FTS indexes name + category + tags, so a query that only hits a tag still surfaces the item —
    /// matching the scorer's searchable text.
    @Test func searchMatchesViaTagOnly() throws {
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let results = catalog.results(for: "breakfast", limit: 6)
        #expect(results.contains { $0.name == "Rolled oats" })
    }

    @Test func formSpecificityBiasSurvivesSQLitePath() throws {
        // "egg" should prefer whole egg over "egg white" — the scorer's form bias still applies
        // because ranking happens in Swift over the hydrated candidates.
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let top = try #require(catalog.results(for: "egg", limit: 2).first)
        #expect(top.name == "Egg, whole, raw")
    }

    // MARK: - User-item merging

    @Test func searchMergesUserAndBundledItems() throws {
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let custom = Self.sampleItem(name: "House protein blend", source: .manual, dataType: .branded, tags: ["protein"])
        catalog.setUserItems([custom])

        let results = catalog.results(for: "house protein", limit: 6)
        #expect(results.contains { $0.id == custom.id })
    }

    @Test func exactNameMatchPrefersManualUserItem() throws {
        // A manual user entry with the same name as a bundled food wins (source priority manual > usda).
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let manual = Self.sampleItem(name: "Chicken breast, roasted", protein: 99, source: .manual)
        catalog.setUserItems([manual])
        let match = catalog.exactNameMatch(forNormalized: FoodItemSearch.normalized("Chicken breast, roasted"))
        #expect(match?.id == manual.id)
    }

    @Test func itemResolvesUserThenBundled() throws {
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let custom = Self.sampleItem(name: "Custom thing", source: .manual)
        catalog.setUserItems([custom])
        #expect(catalog.item(id: custom.id)?.id == custom.id)
        #expect(catalog.item(id: sampleItems[0].id)?.name == "Chicken breast, roasted")
    }

    @Test func candidatesAreBuiltFromCatalog() throws {
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let candidates = catalog.candidates(for: "chicken and rice", limit: 18)
        #expect(candidates.contains { $0.foodItem.name.contains("Chicken") })
        #expect(candidates.contains { $0.foodItem.name.contains("Rice") })
    }

    @Test func emptySourceFallsBackToUserItemsOnly() throws {
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource())
        let custom = Self.sampleItem(name: "Homemade granola", source: .manual, tags: ["granola"])
        catalog.setUserItems([custom])
        #expect(catalog.results(for: "granola", limit: 6).contains { $0.id == custom.id })
        #expect(catalog.bundledCount == 0)
    }

    // MARK: - Branded (ODR) secondary source

    @Test func attachingBrandedSourceMakesItsItemsSearchableAndDetachRemovesThem() throws {
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        #expect(!catalog.hasBrandedSource)

        let brandedOnly = Self.sampleItem(name: "Galaxy Granola Bar", dataType: .branded, tags: ["granola", "bar"])
        catalog.attachBrandedSource(InMemoryBundledFoodSource([brandedOnly]))
        #expect(catalog.hasBrandedSource)
        #expect(catalog.bundledCount == sampleItems.count + 1)
        #expect(catalog.results(for: "galaxy granola", limit: 6).contains { $0.id == brandedOnly.id })
        // The base catalog keeps answering while branded is attached.
        #expect(catalog.results(for: "chicken", limit: 6).contains { $0.name.contains("Chicken") })

        catalog.detachBrandedSource()
        #expect(!catalog.hasBrandedSource)
        #expect(catalog.bundledCount == sampleItems.count)
        #expect(!catalog.results(for: "galaxy granola", limit: 6).contains { $0.id == brandedOnly.id })
        // Base survives the detach.
        #expect(catalog.results(for: "chicken", limit: 6).contains { $0.name.contains("Chicken") })
    }

    @Test func baseAndBrandedItemsBothSurfaceWhenBrandedAttached() throws {
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let brandedChicken = Self.sampleItem(name: "Brand X Chicken Nuggets", dataType: .branded, tags: ["chicken"])
        catalog.attachBrandedSource(InMemoryBundledFoodSource([brandedChicken]))

        let ids = catalog.results(for: "chicken", limit: 10).map(\.id)
        #expect(ids.contains(sampleItems[0].id))   // base "Chicken breast, roasted"
        #expect(ids.contains(brandedChicken.id))    // branded nuggets
    }

    @Test func barcodeResolvesFromBrandedSourceAndUserItemsStillWin() throws {
        let catalog = FoodCatalog(source: try buildSQLiteSource(sampleItems))
        let gtin = try #require(FoodBarcode.normalized("0123456789012"))
        var brandedProduct = Self.sampleItem(name: "Zesty Cola 500ml", dataType: .branded)
        brandedProduct.barcode = gtin
        catalog.attachBrandedSource(InMemoryBundledFoodSource([brandedProduct]))

        // Only the branded source carries this GTIN — the lookup resolves to it.
        #expect(catalog.item(forBarcode: "0123456789012")?.id == brandedProduct.id)

        // A user item paired to the same GTIN wins over branded.
        var userProduct = Self.sampleItem(name: "My Cola", source: .manual)
        userProduct.barcode = gtin
        catalog.setUserItems([userProduct])
        #expect(catalog.item(forBarcode: "0123456789012")?.id == userProduct.id)
    }
}

// MARK: - Database generation (gated)

/// Regenerates the shipped `FoodCatalog.sqlite` from the repo's `FoodDataSource/*.json` using the
/// real `FoodItem` pipeline. Skipped in normal runs; enable explicitly to rebuild the resource
/// (suite-level `-only-testing` is used because the swift-testing method selector needs a `()`):
///
///   TEST_RUNNER_REGEN_FOOD_CATALOG_DB=1 xcodebuild test-without-building \
///     -scheme Fernlet -destination 'platform=iOS Simulator,name=iPhone 17' \
///     -only-testing:FernletTests/FoodCatalogGenerationTests
///
/// Rebuild afterwards so the FoodCatalog package target bundles the refreshed resource.
struct FoodCatalogGenerationTests {
    @Test func regenerateFoodCatalogDatabase() throws {
        // Xcode forwards `TEST_RUNNER_`-prefixed vars to the simulator test process (usually with the
        // prefix stripped) — accept either form so the documented command works regardless.
        let env = ProcessInfo.processInfo.environment
        guard env["REGEN_FOOD_CATALOG_DB"] != nil || env["TEST_RUNNER_REGEN_FOOD_CATALOG_DB"] != nil else { return }

        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FernletTests/
            .deletingLastPathComponent()   // repo root
        let jsonDirectory = repoRoot.appendingPathComponent("FoodDataSource")
        let outputURL = repoRoot.appendingPathComponent("FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite")

        let items = FoodDataCatalog.sourceJSONFoodItems(directory: jsonDirectory)
        #expect(items.count > 10_000, "expected the full USDA subset; got \(items.count) — is FoodDataSource present?")
        #expect(items.contains { $0.name == "Chicken breast, roasted" })

        try FoodCatalogDatabaseBuilder.build(items: items, to: outputURL)

        let source = try #require(SQLiteBundledFoodSource(url: outputURL))
        #expect(source.count == items.count)
        print("✅ Generated FoodCatalog.sqlite with \(source.count) foods at \(outputURL.path)")
    }
}
