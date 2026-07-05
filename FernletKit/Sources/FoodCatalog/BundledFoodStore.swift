import Foundation
import SQLite3
import FernletDomainModel

// MARK: - Shared C helpers

/// SQLite asks, via this sentinel destructor, that it copy bound text immediately so the Swift
/// String backing the bind can be transient. Used by both the generator and the read path.
public nonisolated func sqliteBindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    if let value {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

public nonisolated func sqliteColumnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

// MARK: - Schema

/// Single source of truth for the `FoodCatalog.sqlite` shape, shared by the generator
/// (`FoodCatalogDatabaseBuilder`) and the read path (`SQLiteBundledFoodSource`). The generator's
/// INSERT column list and the reader's SELECT column list must both agree with these names.
public nonisolated enum FoodCatalogSchema {
    /// v2 adds the nullable `gtin_upc` barcode column (+ index). The SHIPPED FoodCatalog.sqlite is
    /// still v1 content (the compact source JSON carries no UPC data yet), so the read path
    /// feature-detects the column at open (`SQLiteBundledFoodSource.hasBarcodeColumn`) and must keep
    /// tolerating v1 files. Regenerating the bundled database from raw USDA branded data is a
    /// separate decision — do not assume bundled barcode coverage.
    public static let userVersion: Int32 = 2
    public static let resourceName = "FoodCatalog"
    public static let resourceExtension = "sqlite"

    /// Caps how many FTS candidates are hydrated for a single query before the in-memory scorer
    /// ranks them. Far above any realistic gate-passing set (the broadest single tokens match a few
    /// hundred rows), so ranking parity with the old all-items scorer is preserved in practice.
    public static let candidateFetchLimit = 6000

    /// Columns selected (in this order) when hydrating a `FoodItem` from a v1 file. Index positions
    /// are mirrored in `SQLiteBundledFoodSource.hydrate` — this list, `hydrate`, and
    /// `FoodCatalogDatabaseBuilder.insertRows` must change in lockstep.
    public static let selectColumns = """
    id, name, brand_source, serving_size, serving_unit, protein, carbs, fat, category, source, \
    data_type, serving_description, verification_policy_days, is_flagged, micronutrients, tags, portions
    """

    /// v2 select list: v1 columns + trailing `gtin_upc` (index 17 in `hydrate`). Used only when the
    /// opened file actually has the column, so v1 files keep preparing statements successfully.
    public static let selectColumnsWithBarcode = selectColumns + ", gtin_upc"

    public static let createFoodTableSQL = """
    CREATE TABLE food (
        food_id INTEGER PRIMARY KEY,
        id TEXT NOT NULL,
        name TEXT NOT NULL,
        normalized_name TEXT NOT NULL,
        brand_source TEXT,
        serving_size REAL NOT NULL,
        serving_unit TEXT NOT NULL,
        protein INTEGER NOT NULL,
        carbs INTEGER NOT NULL,
        fat INTEGER NOT NULL,
        category TEXT NOT NULL,
        source TEXT NOT NULL,
        data_type TEXT NOT NULL,
        serving_description TEXT,
        verification_policy_days INTEGER NOT NULL,
        is_flagged INTEGER NOT NULL,
        micronutrients TEXT,
        tags TEXT,
        portions TEXT,
        gtin_upc TEXT
    );
    """

    public static let createIndexesSQL = """
    CREATE INDEX idx_food_id ON food(id);
    CREATE INDEX idx_food_normalized_name ON food(normalized_name);
    CREATE INDEX idx_food_gtin_upc ON food(gtin_upc);
    """

    // Mirrors the normalization the scorer applies, so the FTS gate matches the scorer gate.
    // Contentless (`content=''`, `columnsize=0`): candidates() only reads matching rowids back
    // (= food_id) and never the indexed text, so storing a copy of it would just bloat the file.
    public static let createFTSSQL = """
    CREATE VIRTUAL TABLE food_fts USING fts5(name, category, tags, content='', columnsize=0, tokenize='unicode61');
    """
}

// MARK: - Source abstraction

/// The read-only bundled food set (the ~13k USDA/curated foods). Backed by SQLite in production and
/// by an in-memory array in tests. Returns candidate rows for a query plus point lookups; ranking is
/// left to `FoodItemSearch` via `FoodCatalog`.
public nonisolated protocol BundledFoodSource: Sendable {
    /// All rows whose name/category/tags satisfy the search gate for `query` (every query token must
    /// match an indexed token by equality or prefix). May return more than the caller needs — the
    /// scorer trims and ranks.
    func candidates(forQuery query: String) -> [FoodItem]
    func item(id: UUID) -> FoodItem?
    func items(ids: [UUID]) -> [FoodItem]
    func exactMatch(normalizedName: String) -> FoodItem?
    /// Point lookup by NORMALIZED GTIN (see `FoodBarcode.normalized`). Returns nil when the backing
    /// file predates the v2 `gtin_upc` column (the shipped v1 database) or carries no barcode data.
    func item(barcode: String) -> FoodItem?
    var count: Int { get }
}

// MARK: - SQLite-backed source

/// Opens the bundled `FoodCatalog.sqlite` read-only and answers candidate/point queries. All access
/// is serialized on a private queue so the single connection is safe to share across actors.
public nonisolated final class SQLiteBundledFoodSource: BundledFoodSource, @unchecked Sendable {
    private let db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.fernlet.foodcatalog.sqlite")
    public let count: Int
    /// Whether the opened file carries the v2 `gtin_upc` column. Feature-detected once at open
    /// (PRAGMA table_info) so the same read path serves both the shipped v1 database and a future
    /// v2 regeneration — v1 statements never reference the missing column.
    let hasBarcodeColumn: Bool

    /// Locates `FoodCatalog.sqlite` in `bundle` (defaults to this module's resource bundle). Returns
    /// nil when the resource is absent so callers can fall back to a user-items-only catalog rather
    /// than crashing. `nil` resolves to `.module`; `.module` is synthesized as internal, so it cannot
    /// appear as a default-argument value in this public initializer.
    public convenience init?(bundle: Bundle? = nil) {
        let bundle = bundle ?? .module
        guard let url = bundle.url(forResource: FoodCatalogSchema.resourceName, withExtension: FoodCatalogSchema.resourceExtension) else {
            return nil
        }
        self.init(url: url)
    }

    public init?(url: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        self.db = handle
        self.count = Self.scalarCount(handle)
        self.hasBarcodeColumn = Self.columnExists(handle, table: "food", column: "gtin_upc")
    }

    /// The select list matching this file's schema — v1 files must never see `gtin_upc`.
    private var selectColumns: String {
        hasBarcodeColumn ? FoodCatalogSchema.selectColumnsWithBarcode : FoodCatalogSchema.selectColumns
    }

    deinit { sqlite3_close(db) }

    public func candidates(forQuery query: String) -> [FoodItem] {
        let tokens = FoodItemSearch.searchTokens(in: query)
        guard !tokens.isEmpty else { return [] }
        // Prefix-AND across all FTS columns mirrors the scorer's hard gate exactly. Tokens are
        // already normalized to letters/digits, so none collide with FTS operator syntax.
        let match = tokens.map { "\($0)*" }.joined(separator: " ")
        // Canonical FTS5 form: match against the virtual table directly (its rowid is the food_id),
        // then resolve the rows. More portable than a JOIN+MATCH across SQLite versions.
        let sql = """
        SELECT \(selectColumns) FROM food \
        WHERE food_id IN (SELECT rowid FROM food_fts WHERE food_fts MATCH ?) \
        LIMIT \(FoodCatalogSchema.candidateFetchLimit);
        """
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, match) }
    }

    public func item(id: UUID) -> FoodItem? {
        let sql = "SELECT \(selectColumns) FROM food WHERE id = ? LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, id.uuidString) }.first
    }

    public func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let sql = "SELECT \(selectColumns) FROM food WHERE id IN (\(placeholders));"
        return fetchRows(sql) { stmt in
            for (offset, id) in ids.enumerated() {
                sqliteBindText(stmt, Int32(offset + 1), id.uuidString)
            }
        }
    }

    public func exactMatch(normalizedName: String) -> FoodItem? {
        let sql = "SELECT \(selectColumns) FROM food WHERE normalized_name = ? ORDER BY name LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, normalizedName) }.first
    }

    public func item(barcode: String) -> FoodItem? {
        // v1 files (the shipped database) have no gtin_upc column — never reference it there.
        guard hasBarcodeColumn else { return nil }
        let sql = "SELECT \(selectColumns) FROM food WHERE gtin_upc = ? ORDER BY name LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, barcode) }.first
    }

    // MARK: Query execution

    private func fetchRows(_ sql: String, bind: (OpaquePointer?) -> Void) -> [FoodItem] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            var results: [FoodItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = Self.hydrate(stmt, includesBarcode: hasBarcodeColumn) { results.append(item) }
            }
            return results
        }
    }

    private static func scalarCount(_ db: OpaquePointer?) -> Int {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM food;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int64(stmt, 0)) : 0
    }

    /// One-time open-time feature detection so v1 files never see queries against v2-only columns.
    private static func columnExists(_ db: OpaquePointer?, table: String, column: String) -> Bool {
        var stmt: OpaquePointer?
        // PRAGMA statements cannot bind parameters; `table` is a compile-time constant here.
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if sqliteColumnText(stmt, 1) == column { return true }
        }
        return false
    }

    /// Builds a `FoodItem` from a result row. Column order must match `FoodCatalogSchema.selectColumns`
    /// (+ trailing `gtin_upc` at index 17 when `includesBarcode`).
    private static func hydrate(_ stmt: OpaquePointer?, includesBarcode: Bool) -> FoodItem? {
        guard let idString = sqliteColumnText(stmt, 0), let id = UUID(uuidString: idString) else { return nil }
        let decoder = JSONDecoder()
        func decodeJSON<T: Decodable>(_ type: T.Type, _ index: Int32) -> T? {
            guard let text = sqliteColumnText(stmt, index), let data = text.data(using: .utf8) else { return nil }
            return try? decoder.decode(type, from: data)
        }

        let source = sqliteColumnText(stmt, 9).flatMap(FoodItemSource.init(rawValue:)) ?? .usda
        let dataType = sqliteColumnText(stmt, 10).flatMap(FoodDataType.init(rawValue:)) ?? .srLegacy
        return FoodItem(
            id: id,
            name: sqliteColumnText(stmt, 1) ?? "",
            brandSource: sqliteColumnText(stmt, 2),
            servingSize: max(sqlite3_column_double(stmt, 3), 0.01),
            servingUnit: sqliteColumnText(stmt, 4) ?? RecipeUnit.gram.rawValue,
            macros: Macros(
                protein: Int(sqlite3_column_int(stmt, 5)),
                carbs: Int(sqlite3_column_int(stmt, 6)),
                fat: Int(sqlite3_column_int(stmt, 7))
            ),
            micronutrients: decodeJSON(Micronutrients.self, 14) ?? Micronutrients(),
            category: sqliteColumnText(stmt, 8) ?? "USDA",
            source: source,
            dataType: dataType,
            servingDescription: sqliteColumnText(stmt, 11),
            verificationPolicyDays: Int(sqlite3_column_int(stmt, 12)),
            isFlagged: sqlite3_column_int(stmt, 13) != 0,
            tags: decodeJSON([String].self, 15) ?? [],
            portions: decodeJSON([FoodPortion].self, 16) ?? [],
            barcode: includesBarcode ? sqliteColumnText(stmt, 17) : nil
        )
    }
}

// MARK: - In-memory source (tests)

/// A trivial bundled source backed by an in-memory array — used by tests so they don't need the
/// generated database. `candidates(forQuery:)` returns everything; `FoodCatalog`'s scorer applies the
/// real gate and ranking, so results match the SQLite path for the same item set.
public nonisolated struct InMemoryBundledFoodSource: BundledFoodSource, @unchecked Sendable {
    public let items: [FoodItem]

    public init(_ items: [FoodItem] = []) { self.items = items }

    public func candidates(forQuery query: String) -> [FoodItem] { items }

    public func item(id: UUID) -> FoodItem? { items.first { $0.id == id } }

    public func items(ids: [UUID]) -> [FoodItem] {
        let wanted = Set(ids)
        return items.filter { wanted.contains($0.id) }
    }

    public func exactMatch(normalizedName: String) -> FoodItem? {
        items
            .filter { FoodItemSearch.normalized($0.name) == normalizedName }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .first
    }

    public func item(barcode: String) -> FoodItem? {
        items.first { FoodBarcode.normalized($0.barcode) == barcode }
    }

    public var count: Int { items.count }
}
