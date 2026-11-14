// BundledFoodLayersTests.swift
// FernletTests
//
// The generic-food layers that ship beside FoodCatalog.sqlite (owner decisions of 2026-11-13):
// FNDDS 2021-2023's survey foods the base lacks (FoodCatalogSurvey.sqlite) and Canada's Canadian
// Nutrient File 2026 (FoodCatalogCNF.sqlite), unioned in by `FoodCatalog.bundled()`. These pin that
// both load, that no layer id is a base id (so no row shows twice and a saved line resolves one food),
// that a CNF row carries its own provenance and licence line, and that plain generic queries still
// lead with the rows they led with before the layers.

import Foundation
import SQLite3
import Testing
import FernletDomainModel
import FoodCatalog

extension FoodCatalog {
    /// The catalog the search probes and corpus suites replay: `bundled()`, or — when the runner
    /// environment carries `FERNLET_LAYERS_OFF` (`TEST_RUNNER_FERNLET_LAYERS_OFF=1`) — the base and its
    /// supplement alone, the catalog as it was before the generic layers, so one build measures both.
    static func probeBundled() -> FoodCatalog {
        let env = ProcessInfo.processInfo.environment
        let layersOff = env["FERNLET_LAYERS_OFF"] != nil || env["TEST_RUNNER_FERNLET_LAYERS_OFF"] != nil
        return FoodCatalog.bundled(includesLayers: !layersOff)
    }

    /// Whether ``probeBundled()`` is serving the base alone.
    static var probeLayersOff: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["FERNLET_LAYERS_OFF"] != nil || env["TEST_RUNNER_FERNLET_LAYERS_OFF"] != nil
    }
}

struct BundledFoodLayersTests {
    /// Rows `Scripts/food-catalog/generic_layers.py` wrote (FoodDataSource/FoodCatalogLayerManifest.json).
    static let surveyRowCount = 5_219
    static let canadianNutrientFileRowCount = 2_339

    /// "Cheese souffle", CNF food code 2: a Canadian recipe compilation (source code 20).
    static let cheeseSouffleID = UUID(uuidString: "00000000-0000-5000-8002-000000000002")
    /// FNDDS "Banana, raw", FDC 2709224 — the FDC id rule the base uses.
    static let fnddsBananaID = UUID(uuidString: "00000000-0000-5000-8000-000002709224")

    /// The ids in one bundled SQLite resource, read off disk.
    static func ids(inResource name: String) throws -> [String] {
        let url = RepoRoot.url.appendingPathComponent("FernletKit/Sources/FoodCatalog/Resources/\(name).sqlite")
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            throw CocoaError(.fileReadCorruptFile)
        }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT id FROM food;", -1, &stmt, nil) == SQLITE_OK else { throw CocoaError(.fileReadUnknown) }
        defer { sqlite3_finalize(stmt) }
        var ids: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW, ids.count < 50_000 {
            if let text = sqlite3_column_text(stmt, 0) { ids.append(String(cString: text)) }
        }
        return ids
    }

    @Test func bothLayersLoadAndCountInTheCatalog() throws {
        let layers = BundledFoodLayers.sources()
        #expect(layers.map(\.count) == [Self.surveyRowCount, Self.canadianNutrientFileRowCount])
        let catalog = FoodCatalog.bundled()
        let base = FoodCatalog.bundled(includesLayers: false)
        try #require(base.bundledCount == FoodSearchCorpusTests.baseLoadedRowCount, "the base catalog must be bundled")
        #expect(catalog.bundledCount == base.bundledCount + Self.surveyRowCount + Self.canadianNutrientFileRowCount)
    }

    @Test func noLayerIdIsABaseIdOrTheOtherLayers() throws {
        let survey = try Self.ids(inResource: BundledFoodLayers.surveyResourceName)
        let cnf = try Self.ids(inResource: BundledFoodLayers.canadianNutrientFileResourceName)
        #expect(survey.count == Self.surveyRowCount && cnf.count == Self.canadianNutrientFileRowCount)
        #expect(Set(survey).count == survey.count && Set(cnf).count == cnf.count)
        #expect(Set(survey).isDisjoint(with: cnf))
        #expect(survey.allSatisfy { $0.hasPrefix("00000000-0000-5000-8000-") }, "FNDDS rows keep the base's FDC id rule")
        #expect(cnf.allSatisfy { $0.hasPrefix("00000000-0000-5000-8002-") }, "CNF rows have their own namespace")
        let base = try #require(SQLiteBundledFoodSource())
        let all = (survey + cnf).compactMap(UUID.init(uuidString:))
        #expect(all.count == survey.count + cnf.count)
        #expect(base.items(ids: all).isEmpty, "a layer row the base already serves would show twice")
    }

    @Test func aCanadianNutrientFileRowCarriesItsOwnSourceAndLicenceLine() throws {
        let catalog = FoodCatalog.bundled()
        let id = try #require(Self.cheeseSouffleID)
        let souffle = try #require(catalog.item(id: id))
        #expect(souffle.name == "Cheese souffle")
        #expect(souffle.source == .canadianNutrientFile)
        #expect(souffle.dataType == .supplementalReference, "a layer row ranks in the layers' own tier")
        #expect(souffle.source.attributionLine == FoodItemSource.canadianNutrientFileAttribution)
        #expect(FoodItemSource.canadianNutrientFileAttribution
                == "Contains information licensed under the Open Government Licence – Canada.")
        #expect(souffle.dataSourceLabel == "Health Canada")
        #expect(souffle.source.isBundledReference)
        #expect(souffle.portions.contains { $0.unit == "ml" && $0.amount == 250 }, "CNF measures become portions")
        #expect(catalog.results(for: "cheese souffle", limit: 10, context: .userTyped).contains { $0.id == id })
    }

    @Test func anFNDDSLayerRowResolvesByTheBaseIdRule() throws {
        let catalog = FoodCatalog.bundled()
        let bananaID = try #require(Self.fnddsBananaID)
        let banana = try #require(catalog.item(id: bananaID))
        #expect(banana.name == "Banana, raw" && banana.dataType == .supplementalReference && banana.source == .usda)
        #expect(banana.portions.first { $0.unit == "banana" }?.gramWeight == 126)
        #expect(banana.dataSourceLabel == "USDA")
    }

    /// The token is frozen English, and a build that predates it reads a CNF food as the person's own
    /// with the token parked — never as USDA — and writes it back unchanged.
    @Test func theCNFTokenIsFrozenAndDecodesTolerantly() throws {
        #expect(FoodItemSource.canadianNutrientFile.rawValue == "canadianNutrientFile")
        let item = FoodItem(name: "Bannock", servingSize: 100, servingUnit: "g", macros: Macros(protein: 7, carbs: 50, fat: 9),
                            micronutrients: Micronutrients(), category: "Baked Products",
                            source: FoodItemSource.canadianNutrientFile, tags: [])
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(FoodItem.self, from: data)
        #expect(decoded.source == FoodItemSource.canadianNutrientFile)
        let object = try JSONSerialization.jsonObject(with: data)
        var json = try #require(object as? [String: Any])
        json["source"] = "aSourceFromTheFuture"
        let future = try JSONDecoder().decode(FoodItem.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(future.source == FoodItemSource.manual && future.unknownSourceToken == "aSourceFromTheFuture")
    }

    /// Plain generic queries keep the generic top row they had before the layers, on the quick-log /
    /// Food-tab order and on the recipe editor's identity order, and that row is not a layer row.
    @Test(arguments: ["banana", "chocolate chips", "egg", "salt", "olive oil", "cheddar cheese", "milk"])
    func plainGenericQueriesKeepTheirTopRow(query: String) throws {
        let catalog = FoodCatalog.bundled()
        let base = FoodCatalog.bundled(includesLayers: false)
        try #require(catalog.bundledCount > base.bundledCount, "the layers must be bundled")
        for ranking in [FoodSearchRanking.standard, .ingredientIdentity] {
            let before = base.results(for: query, limit: 6, context: .userTyped, ranking: ranking).first
            let after = catalog.results(for: query, limit: 6, context: .userTyped, ranking: ranking).first
            #expect(after?.id == before?.id, "\(query): \(before?.name ?? "none") became \(after?.name ?? "none")")
            #expect(after?.dataType != .supplementalReference)
        }
    }
}
