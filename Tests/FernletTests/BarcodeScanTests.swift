import Foundation
import SQLite3
import Testing
import AppServices
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// Batch E barcode support: GTIN normalization, the v2 `gtin_upc` schema (builder round-trip),
/// tolerance of the shipped v1 database (no barcode column), the user-item-first resolution
/// cascade, and the "barcode remembered on user-item creation" pairing flow.
struct BarcodeScanTests {
    // MARK: - Fixtures

    private static func sampleItem(
        name: String,
        protein: Int = 5,
        source: FoodItemSource = .usda,
        barcode: String? = nil
    ) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: protein, carbs: 10, fat: 2),
            micronutrients: Micronutrients(),
            category: "Test",
            source: source,
            tags: ["test"],
            barcode: barcode
        )
    }

    private func buildSQLiteSource(_ items: [FoodItem]) throws -> (source: SQLiteBundledFoodSource, url: URL) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).sqlite")
        try FoodCatalogDatabaseBuilder.build(items: items, to: url)
        return (try #require(SQLiteBundledFoodSource(url: url)), url)
    }

    private func execute(_ sql: String, at url: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }

    private func userVersion(at url: URL) throws -> Int32 {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        try #require(sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        try #require(sqlite3_step(stmt) == SQLITE_ROW)
        return sqlite3_column_int(stmt, 0)
    }

    /// Reshapes a freshly-built v2 file into an authentic v1 file — the shape of the SHIPPED
    /// FoodCatalog.sqlite (no `gtin_upc` column, user_version 1).
    private func downgradeToV1(_ url: URL) throws {
        try execute("DROP INDEX idx_food_gtin_upc;", at: url)
        try execute("ALTER TABLE food DROP COLUMN gtin_upc;", at: url)
        try execute("PRAGMA user_version = 1;", at: url)
    }

    // MARK: - Normalization

    @Test func normalizedFoldsGTINRenderings() {
        // The same product as UPC-A (12), EAN-13 (leading zero), and GTIN-14 all normalize equal.
        let upcA = FoodBarcode.normalized("012345678905")
        let ean13 = FoodBarcode.normalized("0012345678905")
        let gtin14 = FoodBarcode.normalized("00012345678905")
        #expect(upcA == "00012345678905")
        #expect(upcA == ean13)
        #expect(upcA == gtin14)

        // EAN-8 pads too; formatting characters are stripped first.
        #expect(FoodBarcode.normalized("9638-5074") == "00000096385074")
        #expect(FoodBarcode.normalized("0 12345 67890 5") == "00012345678905")

        // Junk lengths and nil are rejected.
        #expect(FoodBarcode.normalized("1234") == nil)
        #expect(FoodBarcode.normalized("123456789012345") == nil)
        #expect(FoodBarcode.normalized("") == nil)
        #expect(FoodBarcode.normalized(nil) == nil)
    }

    // MARK: - Schema v2 builder round-trip

    @Test func builderWritesV2AndBarcodeRoundTrips() throws {
        let cereal = Self.sampleItem(name: "Crunchy oat cereal", barcode: "012345678905")
        let plain = Self.sampleItem(name: "Plain rice")
        let (source, url) = try buildSQLiteSource([cereal, plain])

        #expect(try userVersion(at: url) == FoodCatalogSchema.userVersion)
        #expect(FoodCatalogSchema.userVersion == 2)

        // Point lookup by normalized GTIN hits, and hydration carries the barcode field back.
        let normalized = try #require(FoodBarcode.normalized("012345678905"))
        let byBarcode = try #require(source.item(barcode: normalized))
        #expect(byBarcode.id == cereal.id)

        let hydrated = try #require(source.item(id: cereal.id))
        #expect(hydrated.barcode == normalized)
        #expect(try #require(source.item(id: plain.id)).barcode == nil)

        #expect(source.item(barcode: "00000000000000") == nil)
    }

    // MARK: - v1 file tolerance (the shipped database's shape)

    @Test func v1FileWithoutBarcodeColumnStillReads() throws {
        let cereal = Self.sampleItem(name: "Crunchy oat cereal", barcode: "012345678905")
        let (_, url) = try buildSQLiteSource([cereal])
        try downgradeToV1(url)

        let source = try #require(SQLiteBundledFoodSource(url: url))
        #expect(source.count == 1)

        // Every read path still works against the barcode-less schema...
        let hydrated = try #require(source.item(id: cereal.id))
        #expect(hydrated.name == cereal.name)
        #expect(hydrated.macros == cereal.macros)
        #expect(hydrated.barcode == nil)
        #expect(source.candidates(forQuery: "cereal").contains { $0.id == cereal.id })
        #expect(source.exactMatch(normalizedName: FoodItemSearch.normalized("Crunchy oat cereal"))?.id == cereal.id)

        // ...and barcode lookup degrades to nil instead of failing statement preparation.
        #expect(source.item(barcode: "00012345678905") == nil)
    }

    @Test func shippedBundledCatalogToleratesBarcodeLookups() throws {
        // The real bundled resource is still v1 content — it must keep answering searches and
        // return nil (not fail) for barcode lookups.
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 0, "bundled FoodCatalog.sqlite missing from the test host")
        #expect(catalog.results(for: "chicken", limit: 3, context: .userTyped).isEmpty == false)
        #expect(catalog.item(forBarcode: "0012345678905") == nil)
    }

    // MARK: - Resolution cascade

    @Test func itemForBarcodeChecksUserItemsBeforeBundled() throws {
        let bundled = Self.sampleItem(name: "Bundled bar", protein: 5, barcode: "012345678905")
        let (source, _) = try buildSQLiteSource([bundled])
        let catalog = FoodCatalog(source: source)

        // Bundled hit when no user pairing exists — any scanner rendering of the code resolves.
        #expect(catalog.item(forBarcode: "012345678905")?.id == bundled.id)
        #expect(catalog.item(forBarcode: "0012345678905")?.id == bundled.id)

        // A user item paired to the same code wins (their macros beat catalog data).
        let userItem = Self.sampleItem(name: "My bar", protein: 20, source: .manual, barcode: "0012345678905")
        catalog.setUserItems([userItem])
        #expect(catalog.item(forBarcode: "012345678905")?.id == userItem.id)

        // Unknown codes and junk fall through to nil.
        #expect(catalog.item(forBarcode: "96385074") == nil)
        #expect(catalog.item(forBarcode: "not a barcode") == nil)
    }

    @Test func userItemBarcodeResolvesAgainstV1BundledSource() throws {
        // The shipped-file scenario: bundled catalog has no barcode column, but a user item created
        // via the pairing flow still resolves — the next scan is instant.
        let (_, url) = try buildSQLiteSource([Self.sampleItem(name: "Filler food")])
        try downgradeToV1(url)
        let catalog = FoodCatalog(source: try #require(SQLiteBundledFoodSource(url: url)))

        let paired = Self.sampleItem(name: "Paired granola", source: .manual, barcode: "012345678905")
        catalog.setUserItems([paired])
        #expect(catalog.item(forBarcode: "0012345678905")?.id == paired.id)
    }

    // MARK: - Barcode remembered on user-item creation

    @Test func customIngredientUpsertRemembersBarcode() {
        var foodItems: [FoodItem] = []
        let input = ManualRecipeIngredientInput(
            name: "Oat granola bar",
            quantity: 1,
            unit: RecipeUnit.serving.rawValue,
            protein: 6, carbs: 20, fat: 8,
            barcode: "012345678905"
        )
        let created = CustomIngredientUpsert.resolve(ingredient: input, in: &foodItems, verifiedAt: Date())
        #expect(created.barcode == "00012345678905")
        #expect(created.source == .manual)
        #expect(foodItems.count == 1)

        // Re-saving the same food WITHOUT a scan keeps the remembered barcode.
        var resave = input
        resave.barcode = nil
        resave.protein = 7
        let updated = CustomIngredientUpsert.resolve(ingredient: resave, in: &foodItems, verifiedAt: Date())
        #expect(updated.id == created.id)
        #expect(updated.barcode == "00012345678905")
        #expect(foodItems.count == 1)
    }

    @Test func rememberedItemResolvesOnNextScan() {
        // End-to-end pairing promise: create-with-barcode → the catalog resolves the next scan.
        var foodItems: [FoodItem] = []
        let input = ManualRecipeIngredientInput(name: "Paired snack", barcode: "96385074")
        let created = CustomIngredientUpsert.resolve(ingredient: input, in: &foodItems, verifiedAt: Date())

        let catalog = FoodCatalog(source: InMemoryBundledFoodSource())
        catalog.setUserItems(foodItems)
        #expect(catalog.item(forBarcode: "9638 5074")?.id == created.id)
    }

    // MARK: - FoodItem codec tolerance

    @Test func foodItemDecodeToleratesMissingBarcode() throws {
        let legacyJSON = """
        {"name": "Old snack", "servingSize": 30, "servingUnit": "g",
         "macros": {"protein": 3, "carbs": 12, "fat": 5},
         "category": "snack", "source": "manual", "tags": []}
        """
        let decoded = try JSONDecoder().decode(FoodItem.self, from: Data(legacyJSON.utf8))
        #expect(decoded.barcode == nil)
    }

    @Test func foodItemBarcodeSurvivesCodecRoundTrip() throws {
        let item = Self.sampleItem(name: "Round trip bar", source: .manual, barcode: "00012345678905")
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(FoodItem.self, from: data)
        #expect(decoded == item)
        #expect(decoded.barcode == "00012345678905")
    }

    // MARK: - The not-found screen's completeness line (fix 1.14)

    @Test func theNoScanNudgeNamesTheFieldsAboutToBeStoredAsZero() throws {
        // Regression guard for `scanResult?.plausibilityReport() ?? .clean`. `.clean` names no
        // missing fields, so with nothing scanned the "Still missing: …" line disappeared from the
        // empty-macro nudge — and no-scan is the DOMINANT trigger of that nudge, because this screen
        // has no manual macro entry at all. Neither branch raises an arithmetic finding, so the
        // regression is invisible from the outside; only this assertion catches it.
        let message = try #require(BarcodeNotFoundView.missingMacrosMessage(forScan: nil))
        #expect(message.contains(NutrientField.servingSize.displayName))
        #expect(message.contains(NutrientField.protein.displayName))
        #expect(message.contains(NutrientField.carbs.displayName))
        #expect(message.contains(NutrientField.fat.displayName))
        // Calories are deliberately dropped: this screen deals in grams and shows no calorie box.
        #expect(!message.contains(NutrientField.calories.displayName))
        // And the no-scan report stays a COMPLETENESS problem — no finding fires, so substituting an
        // empty result cannot spuriously raise the contradiction dialog.
        let report = BarcodeNotFoundView.plausibility(ofScan: nil)
        #expect(report.findings.isEmpty)
        #expect(report.missingFields == NutritionPlausibility.coreFields)
    }

    @Test func aCompleteScanLeavesNothingForTheCompletenessLineToSay() {
        var scan = NutritionLabelResult()
        scan.servingSize = "1 bar (55g)"
        scan.calories = 244
        scan.protein = 4
        scan.carbs = 30
        scan.fat = 12
        #expect(BarcodeNotFoundView.missingMacrosMessage(forScan: scan) == nil)
        // A partial scan names exactly the gap, not the whole panel.
        scan.carbs = nil
        let partial = BarcodeNotFoundView.missingMacrosMessage(forScan: scan)
        #expect(partial?.contains(NutrientField.carbs.displayName) == true)
        #expect(partial?.contains(NutrientField.protein.displayName) == false)
    }
}
