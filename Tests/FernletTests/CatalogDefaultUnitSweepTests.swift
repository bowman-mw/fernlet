// CatalogDefaultUnitSweepTests.swift
// FernletTests
//
// F10 of Docs/Ingredient-Search-Deep-Research-2026-09-29.md, second instrument: does every bundled
// row's TAP DEFAULT convert? Tapping a row in the recipe ingredient editor (and a bare-count quick
// log) binds `preferredRecipeUnit` × `defaultRecipeQuantity(for:)`; when that amount does not resolve
// to nutrition the editor shows "This amount needs an exact serving basis or one source-backed
// portion." and Save is disabled — the row "fails on tap" (report §3.4).
//
// The report measured 16,310 such rows (13.8%) with three independent replicas. This suite sweeps
// EVERY row the shipped catalog can hand the editor — through `FoodCatalog.items(ids:)`, so any
// load-time shim applies exactly as it does in the app — and pins the failures by tap-default unit
// token. Like the corpus suites it is a photograph: a unit fix (F1, F2, F4a) lowers a count on
// purpose and edits the pin in the same commit; a count that moves without one is a regression.
//
// BOUNDED. The id read is capped at `sweepCap` rows and hydration runs in fixed-size chunks, so
// the sweep's cost is linear in the catalog and cannot run away; it prints its wall-clock time.

import Foundation
import SQLite3
import Testing
import FernletDomainModel
import FoodCatalog

/// Sweeps the whole bundled catalog for rows whose tap-default recipe amount does not convert.
struct CatalogDefaultUnitSweepTests {
    /// Rows whose tap default fails, keyed `"<readable|unreadable> → <tap-default unit token>"` —
    /// the report's two mechanisms (§3.4). UNREADABLE: the serving unit is a raw FDC code the
    /// converter cannot read (GRM 12,376, MLT 2,193, IU 193, GM 31, MC 2, survey units 48 = 14,843),
    /// refused before any unit is tried; most default to "1 serving", the "oil" names to "1 cup" and
    /// the "flour" names to grams. READABLE: a "cup" default the converter cannot honour (437 rows
    /// with two or more volume portions, the rest from the no-portion "oil" branch).
    static let measuredFailures: [String: Int] = [
        "unreadable → serving": 14_480,
        "unreadable → cup": 183,
        "unreadable → g": 180,
        "readable → cup": 1_467
    ]

    /// The report's headline, derived from the pin above.
    static let measuredFailureTotal = 16_310

    /// Upper bound on the rows one sweep reads — comfortably above the catalog, so a catalog that
    /// grew past it fails the row-count check instead of being silently truncated.
    static let sweepCap = 200_000

    /// Rows hydrated per `items(ids:)` call.
    static let chunkSize = 2_000

    @Test func everyBundledRowsTapDefaultConvertsOrIsPinned() throws {
        let started = Date()
        let ids = try Self.catalogIDs()
        try #require(ids.count == FoodSearchCorpusTests.shippedRowCount,
                     "the sweep must read the whole shipped catalog")
        let catalog = FoodCatalog.bundled()
        var failures: [String: Int] = [:]
        var swept = 0
        for start in stride(from: 0, to: ids.count, by: Self.chunkSize) {
            let chunk = Array(ids[start..<min(start + Self.chunkSize, ids.count)])
            for item in catalog.items(ids: chunk) {
                swept += 1
                let unit = item.preferredRecipeUnit
                let quantity = item.defaultRecipeQuantity(for: unit)
                let converts = RecipeIngredient(foodItemId: item.id, quantity: quantity, unit: unit.rawValue)
                    .servingConversion(using: item) != nil
                guard !converts else { continue }
                let readable = RecipeUnit.normalized(item.servingUnit) == nil ? "unreadable" : "readable"
                failures["\(readable) → \(unit.rawValue)", default: 0] += 1
            }
        }
        print("CatalogDefaultUnitSweep: swept \(swept) rows in \(Int(Date().timeIntervalSince(started) * 1_000)) ms")
        #expect(swept == ids.count, "every id must hydrate through the catalog")
        #expect(failures == Self.measuredFailures, "fail-on-tap rows moved: \(failures.sorted { $0.key < $1.key })")
        #expect(Self.measuredFailures.values.reduce(0, +) == Self.measuredFailureTotal)
    }

    /// Every row id in the shipped file, in `food_id` order, read raw and capped at `sweepCap`.
    static func catalogIDs() throws -> [UUID] {
        var handle: OpaquePointer?
        let url = FoodCatalogFileProbe.shippedCatalogURL
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            throw SweepError.unreadable(url.path)
        }
        defer { sqlite3_close(handle) }
        var stmt: OpaquePointer?
        let sql = "SELECT id FROM food ORDER BY food_id LIMIT \(sweepCap);"
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK else { throw SweepError.unreadable(sql) }
        defer { sqlite3_finalize(stmt) }
        var ids: [UUID] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let text = sqliteColumnText(stmt, 0), let id = UUID(uuidString: text) { ids.append(id) }
        }
        return ids
    }

    /// Why the sweep could not read the shipped file.
    enum SweepError: Error {
        /// The file or statement named could not be opened or prepared.
        case unreadable(String)
    }
}
