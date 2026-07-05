import Foundation
import SQLite3
import FernletDomainModel
import FoodCatalog

/// Build-time generator that converts the source USDA `FoodItem`s into the read-only
/// `FoodCatalog.sqlite` resource the app ships. It is *not* invoked at runtime — the app only ever
/// reads the generated database via `SQLiteBundledFoodSource`. Regenerate with the gated
/// `FoodCatalogGenerationTests` test (see that file for the one-command recipe).
///
/// The rows are produced from the exact same `FoodItem` pipeline the JSON decoder uses
/// (`FoodDataCatalog.sourceJSONFoodItems`), so the SQLite contents stay faithful to the legacy
/// in-memory path — including branded-label scaling, USDA portions, and the canonical chicken alias.
enum FoodCatalogDatabaseBuilder {
    enum BuildError: Error, CustomStringConvertible {
        case open(String)
        case exec(String)
        case prepare(String)
        case step(String)

        var description: String {
            switch self {
            case .open(let m): "open failed: \(m)"
            case .exec(let m): "exec failed: \(m)"
            case .prepare(let m): "prepare failed: \(m)"
            case .step(let m): "step failed: \(m)"
            }
        }
    }

    /// Writes a fresh database at `url` (overwriting any existing file) containing one `food` row per
    /// item plus an FTS5 index over the normalized name/category/tags used by the search gate.
    static func build(items: [FoodItem], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        // A stale -wal/-shm pair from a previous crash would otherwise corrupt the fresh file.
        try? FileManager.default.removeItem(at: url.appendingPathExtension("wal"))
        try? FileManager.default.removeItem(at: url.appendingPathExtension("shm"))

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "unknown"
            sqlite3_close(db)
            throw BuildError.open(message)
        }
        defer { sqlite3_close(db) }

        try exec(db, "PRAGMA page_size = 4096;")
        try exec(db, "PRAGMA journal_mode = DELETE;")
        try exec(db, "PRAGMA user_version = \(FoodCatalogSchema.userVersion);")
        try exec(db, FoodCatalogSchema.createFoodTableSQL)
        try exec(db, FoodCatalogSchema.createIndexesSQL)
        try exec(db, FoodCatalogSchema.createFTSSQL)

        try exec(db, "BEGIN TRANSACTION;")
        do {
            try insertRows(db, items: items)
            try exec(db, "COMMIT;")
        } catch {
            try? exec(db, "ROLLBACK;")
            throw error
        }
        try exec(db, "INSERT INTO food_fts(food_fts) VALUES('optimize');")
        try exec(db, "VACUUM;")
    }

    private static func insertRows(_ db: OpaquePointer, items: [FoodItem]) throws {
        let encoder = JSONEncoder()
        // Sort keys so regenerating the database produces a byte-stable, diff-friendly file.
        encoder.outputFormatting = [.sortedKeys]

        let foodSQL = """
        INSERT INTO food (food_id, id, name, normalized_name, brand_source, serving_size, serving_unit, \
        protein, carbs, fat, category, source, data_type, serving_description, verification_policy_days, \
        is_flagged, micronutrients, tags, portions, gtin_upc) \
        VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18, ?19, ?20);
        """
        let ftsSQL = "INSERT INTO food_fts (rowid, name, category, tags) VALUES (?1, ?2, ?3, ?4);"

        let foodStmt = try prepare(db, foodSQL)
        defer { sqlite3_finalize(foodStmt) }
        let ftsStmt = try prepare(db, ftsSQL)
        defer { sqlite3_finalize(ftsStmt) }

        for (offset, item) in items.enumerated() {
            let rowID = Int64(offset + 1)
            let normalizedName = FoodItemSearch.normalized(item.name)
            let normalizedCategory = FoodItemSearch.normalized(item.category)
            let normalizedTags = item.tags.map { FoodItemSearch.normalized($0) }.joined(separator: " ")
            let micros = (try? encoder.encode(item.micronutrients)).flatMap { String(data: $0, encoding: .utf8) }
            let tags = (try? encoder.encode(item.tags)).flatMap { String(data: $0, encoding: .utf8) }
            let portions = (try? encoder.encode(item.portions)).flatMap { String(data: $0, encoding: .utf8) }

            sqlite3_reset(foodStmt)
            sqlite3_clear_bindings(foodStmt)
            sqlite3_bind_int64(foodStmt, 1, rowID)
            sqliteBindText(foodStmt, 2, item.id.uuidString)
            sqliteBindText(foodStmt, 3, item.name)
            sqliteBindText(foodStmt, 4, normalizedName)
            sqliteBindText(foodStmt, 5, item.brandSource)
            sqlite3_bind_double(foodStmt, 6, item.servingSize)
            sqliteBindText(foodStmt, 7, item.servingUnit)
            sqlite3_bind_int(foodStmt, 8, Int32(item.macros.protein))
            sqlite3_bind_int(foodStmt, 9, Int32(item.macros.carbs))
            sqlite3_bind_int(foodStmt, 10, Int32(item.macros.fat))
            sqliteBindText(foodStmt, 11, item.category)
            sqliteBindText(foodStmt, 12, item.source.rawValue)
            sqliteBindText(foodStmt, 13, item.dataType.rawValue)
            sqliteBindText(foodStmt, 14, item.servingDescription)
            sqlite3_bind_int(foodStmt, 15, Int32(item.verificationPolicyDays))
            sqlite3_bind_int(foodStmt, 16, item.isFlagged ? 1 : 0)
            sqliteBindText(foodStmt, 17, micros)
            sqliteBindText(foodStmt, 18, tags)
            sqliteBindText(foodStmt, 19, portions)
            // v2: normalized GTIN, NULL for the (current) barcode-less USDA source data.
            sqliteBindText(foodStmt, 20, FoodBarcode.normalized(item.barcode))
            try step(db, foodStmt)

            sqlite3_reset(ftsStmt)
            sqlite3_clear_bindings(ftsStmt)
            sqlite3_bind_int64(ftsStmt, 1, rowID)
            sqliteBindText(ftsStmt, 2, normalizedName)
            sqliteBindText(ftsStmt, 3, normalizedCategory)
            sqliteBindText(ftsStmt, 4, normalizedTags)
            try step(db, ftsStmt)
        }
    }

    // MARK: - C helpers

    private static func exec(_ db: OpaquePointer, _ sql: String) throws {
        var errmsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errmsg) == SQLITE_OK else {
            let message = errmsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errmsg)
            throw BuildError.exec("\(message) — \(sql.prefix(80))")
        }
    }

    private static func prepare(_ db: OpaquePointer, _ sql: String) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw BuildError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        return stmt
    }

    private static func step(_ db: OpaquePointer, _ stmt: OpaquePointer?) throws {
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw BuildError.step(String(cString: sqlite3_errmsg(db)))
        }
    }
}
