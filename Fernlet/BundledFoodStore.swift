import Foundation
import SQLite3
import FernletDomainModel

// MARK: - Shared C helpers

/// SQLite asks, via this sentinel destructor, that it copy bound text immediately so the Swift
/// String backing the bind can be transient. Used by both the generator and the read path.
nonisolated func sqliteBindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    if let value {
        sqlite3_bind_text(stmt, index, value, -1, transient)
    } else {
        sqlite3_bind_null(stmt, index)
    }
}

nonisolated func sqliteColumnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

// MARK: - Schema

/// Single source of truth for the `FoodCatalog.sqlite` shape, shared by the generator
/// (`FoodCatalogDatabaseBuilder`) and the read path (`SQLiteBundledFoodSource`). The generator's
/// INSERT column list and the reader's SELECT column list must both agree with these names.
nonisolated enum FoodCatalogSchema {
    static let userVersion: Int32 = 1
    static let resourceName = "FoodCatalog"
    static let resourceExtension = "sqlite"

    /// Caps how many FTS candidates are hydrated for a single query before the in-memory scorer
    /// ranks them. Far above any realistic gate-passing set (the broadest single tokens match a few
    /// hundred rows), so ranking parity with the old all-items scorer is preserved in practice.
    static let candidateFetchLimit = 6000

    /// Columns selected (in this order) when hydrating a `FoodItem`. Index positions are mirrored in
    /// `SQLiteBundledFoodSource.hydrate`.
    static let selectColumns = """
    id, name, brand_source, serving_size, serving_unit, protein, carbs, fat, category, source, \
    data_type, serving_description, verification_policy_days, is_flagged, micronutrients, tags, portions
    """

    static let createFoodTableSQL = """
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
        portions TEXT
    );
    """

    static let createIndexesSQL = """
    CREATE INDEX idx_food_id ON food(id);
    CREATE INDEX idx_food_normalized_name ON food(normalized_name);
    """

    // Mirrors the normalization the scorer applies, so the FTS gate matches the scorer gate.
    // Contentless (`content=''`, `columnsize=0`): candidates() only reads matching rowids back
    // (= food_id) and never the indexed text, so storing a copy of it would just bloat the file.
    static let createFTSSQL = """
    CREATE VIRTUAL TABLE food_fts USING fts5(name, category, tags, content='', columnsize=0, tokenize='unicode61');
    """
}

// MARK: - Source abstraction

/// The read-only bundled food set (the ~13k USDA/curated foods). Backed by SQLite in production and
/// by an in-memory array in tests. Returns candidate rows for a query plus point lookups; ranking is
/// left to `FoodItemSearch` via `FoodCatalog`.
nonisolated protocol BundledFoodSource: Sendable {
    /// All rows whose name/category/tags satisfy the search gate for `query` (every query token must
    /// match an indexed token by equality or prefix). May return more than the caller needs — the
    /// scorer trims and ranks.
    func candidates(forQuery query: String) -> [FoodItem]
    func item(id: UUID) -> FoodItem?
    func items(ids: [UUID]) -> [FoodItem]
    func exactMatch(normalizedName: String) -> FoodItem?
    var count: Int { get }
}

// MARK: - SQLite-backed source

/// Opens the bundled `FoodCatalog.sqlite` read-only and answers candidate/point queries. All access
/// is serialized on a private queue so the single connection is safe to share across actors.
nonisolated final class SQLiteBundledFoodSource: BundledFoodSource, @unchecked Sendable {
    private let db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.fernlet.foodcatalog.sqlite")
    let count: Int

    /// Locates `FoodCatalog.sqlite` in `bundle`. Returns nil when the resource is absent so callers
    /// can fall back to a user-items-only catalog rather than crashing.
    convenience init?(bundle: Bundle = .main) {
        guard let url = bundle.url(forResource: FoodCatalogSchema.resourceName, withExtension: FoodCatalogSchema.resourceExtension) else {
            return nil
        }
        self.init(url: url)
    }

    init?(url: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        self.db = handle
        self.count = Self.scalarCount(handle)
    }

    deinit { sqlite3_close(db) }

    func candidates(forQuery query: String) -> [FoodItem] {
        let tokens = FoodItemSearch.searchTokens(in: query)
        guard !tokens.isEmpty else { return [] }
        // Prefix-AND across all FTS columns mirrors the scorer's hard gate exactly. Tokens are
        // already normalized to letters/digits, so none collide with FTS operator syntax.
        let match = tokens.map { "\($0)*" }.joined(separator: " ")
        // Canonical FTS5 form: match against the virtual table directly (its rowid is the food_id),
        // then resolve the rows. More portable than a JOIN+MATCH across SQLite versions.
        let sql = """
        SELECT \(FoodCatalogSchema.selectColumns) FROM food \
        WHERE food_id IN (SELECT rowid FROM food_fts WHERE food_fts MATCH ?) \
        LIMIT \(FoodCatalogSchema.candidateFetchLimit);
        """
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, match) }
    }

    func item(id: UUID) -> FoodItem? {
        let sql = "SELECT \(FoodCatalogSchema.selectColumns) FROM food WHERE id = ? LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, id.uuidString) }.first
    }

    func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        let placeholders = Array(repeating: "?", count: ids.count).joined(separator: ", ")
        let sql = "SELECT \(FoodCatalogSchema.selectColumns) FROM food WHERE id IN (\(placeholders));"
        return fetchRows(sql) { stmt in
            for (offset, id) in ids.enumerated() {
                sqliteBindText(stmt, Int32(offset + 1), id.uuidString)
            }
        }
    }

    func exactMatch(normalizedName: String) -> FoodItem? {
        let sql = "SELECT \(FoodCatalogSchema.selectColumns) FROM food WHERE normalized_name = ? ORDER BY name LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, normalizedName) }.first
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
                if let item = Self.hydrate(stmt) { results.append(item) }
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

    /// Builds a `FoodItem` from a result row. Column order must match `FoodCatalogSchema.selectColumns`.
    private static func hydrate(_ stmt: OpaquePointer?) -> FoodItem? {
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
            portions: decodeJSON([FoodPortion].self, 16) ?? []
        )
    }
}

// MARK: - In-memory source (tests)

/// A trivial bundled source backed by an in-memory array — used by tests so they don't need the
/// generated database. `candidates(forQuery:)` returns everything; `FoodCatalog`'s scorer applies the
/// real gate and ranking, so results match the SQLite path for the same item set.
nonisolated struct InMemoryBundledFoodSource: BundledFoodSource {
    let items: [FoodItem]

    init(_ items: [FoodItem] = []) { self.items = items }

    func candidates(forQuery query: String) -> [FoodItem] { items }

    func item(id: UUID) -> FoodItem? { items.first { $0.id == id } }

    func items(ids: [UUID]) -> [FoodItem] {
        let wanted = Set(ids)
        return items.filter { wanted.contains($0.id) }
    }

    func exactMatch(normalizedName: String) -> FoodItem? {
        items
            .filter { FoodItemSearch.normalized($0.name) == normalizedName }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            .first
    }

    var count: Int { items.count }
}
