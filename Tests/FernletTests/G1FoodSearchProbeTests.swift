// G1FoodSearchProbeTests.swift
// FernletTests
//
// Roadmap G1 (food search & catalog) measuring probe: prints the six rows the typed surfaces show for
// the queries the 2026-11-09 review left open (short queries, a lone digit, chain words inside food
// words, "candy corn" duplicates, flavor-last product names on the recipe surface). Asserts nothing.
//
// OPT-IN ONLY: nothing runs unless the runner environment carries `FERNLET_G1_PROBE`. With
// `FERNLET_REPLAY_BRANDED=/abs/FoodCatalogBranded.sqlite` the branded catalog is attached the way the
// app's loader attaches it. Output is printed between `===G1-PROBE===` markers.
//
//     TEST_RUNNER_FERNLET_G1_PROBE=1 TEST_RUNNER_FERNLET_REPLAY_BRANDED=/abs/FoodCatalogBranded.sqlite \
//       xcodebuild test-without-building … -only-testing:FernletTests/G1FoodSearchProbeTests

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

/// The G1 probe: one printed table per configuration (base, base + branded).
struct G1FoodSearchProbeTests {
    /// The probe's queries: the review's open cases.
    static let queries = [
        "eg", "pb", "oj", "v8", "2% milk", "7 up", "7up", "chipotle chicken", "green chilis",
        "candy corn", "lemon", "lime", "apple", "garlic", "strawberry", "cinnamon", "mcdonalds fries"
    ]

    @Test func printsTheOpenCases() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FERNLET_G1_PROBE"] != nil else { return }
        let base = try #require(SQLiteBundledFoodSource())
        let catalog = FoodCatalog(source: base)
        var lines = ["===G1-PROBE=== base"]
        lines += Self.table(catalog)
        if let path = env["FERNLET_REPLAY_BRANDED"], FileManager.default.fileExists(atPath: path) {
            let branded = try #require(SQLiteBundledFoodSource(
                url: URL(fileURLWithPath: path), skipPriorityOrder: true, candidateCap: 600))
            catalog.attachBrandedSource(branded)
            lines.append("===G1-PROBE=== base+branded")
            lines += Self.table(catalog)
        }
        lines.append("===G1-PROBE-END===")
        print(lines.joined(separator: "\n"))
    }

    private static func table(_ catalog: FoodCatalog) -> [String] {
        var lines: [String] = []
        for query in queries {
            for ranking in [FoodSearchRanking.standard, .ingredientIdentity] {
                let rows = catalog.results(for: query, context: .userTyped, ranking: ranking)
                let label = ranking == .standard ? "std" : "id "
                lines.append("[\(label)] \(query) (\(rows.count))")
                lines += rows.map { "    \($0.dataType.rawValue) | \($0.name) | \($0.brandSource ?? "-") | \($0.category)" }
            }
        }
        return lines
    }
}
