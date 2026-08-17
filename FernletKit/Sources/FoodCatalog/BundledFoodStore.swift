import Foundation
import SQLite3
import FernletFoundation
import FernletDomainModel

// MARK: - Shared C helpers

/// SQLite asks, via this sentinel destructor, that it copy bound text immediately so the Swift
/// String backing the bind can be transient. Used by both the generator and the read path.
///
/// R7: the bind status is checked rather than implicitly discarded. A failed bind leaves the
/// parameter unset and the query then matches nothing — indistinguishable, without this line, from
/// "no such food".
public nonisolated func sqliteBindText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
    let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    let status: Int32
    if let value {
        status = sqlite3_bind_text(stmt, index, value, -1, transient)
    } else {
        status = sqlite3_bind_null(stmt, index)
    }
    guard status != SQLITE_OK else { return }
    FernletAuditLog.log("foodCatalog.bind.failed", context: ["index": "\(index)", "status": "\(status)"])
}

/// Reads a TEXT column as a Swift `String`, or nil for SQL NULL. The companion read helper to
/// ``sqliteBindText(_:_:_:)``, likewise shared by the generator and the read path.
public nonisolated func sqliteColumnText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
    guard let cString = sqlite3_column_text(stmt, index) else { return nil }
    return String(cString: cString)
}

// MARK: - Schema

/// Single source of truth for the `FoodCatalog.sqlite` shape — table/index/FTS DDL, the SELECT
/// column lists, the schema version, and the candidate fetch cap.
///
/// Shared by the generator (`FoodCatalogDatabaseBuilder`, app target — build/test time only) and the
/// read path (``SQLiteBundledFoodSource``). The generator's INSERT column list and the reader's
/// SELECT column list must both agree with these names; ``selectColumns``, the reader's `hydrate`,
/// and the generator's insert routine change in lockstep.
public nonisolated enum FoodCatalogSchema {
    /// v2 adds the nullable `gtin_upc` barcode column (+ index). The SHIPPED FoodCatalog.sqlite is
    /// still v1 content (the compact source JSON carries no UPC data yet), so the read path
    /// feature-detects the column at open (`SQLiteBundledFoodSource.hasBarcodeColumn`) and must keep
    /// tolerating v1 files. Regenerating the bundled database from raw USDA branded data is a
    /// separate decision — do not assume bundled barcode coverage.
    public static let userVersion: Int32 = 2
    public static let resourceName = "FoodCatalog"
    public static let resourceExtension = "sqlite"

    /// Caps how many FTS candidates are hydrated for a single query before the in-memory scorer ranks
    /// them. Broad single 3-char prefixes actually match ~7k–8.2k rows (not "a few hundred"), so this
    /// sits just above the broadest realistic single-token set — realistic queries truncate nothing.
    /// Beyond that (e.g. a 2-char token), the `ORDER BY` in `candidates` guarantees the truncation
    /// still keeps the highest-priority (`survey`/`foundation`, then `srLegacy`) rows the scorer wants,
    /// so ranking parity with the old all-items scorer is preserved for the rows that matter.
    public static let candidateFetchLimit = 10000

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

/// The read-only bundled food set (the ~13k USDA/curated foods) behind ``FoodCatalog``.
///
/// Backed by ``SQLiteBundledFoodSource`` in production (both the base catalog and the attachable
/// branded/ODR catalog) and by ``InMemoryBundledFoodSource`` in tests. Conformers return candidate
/// rows for a query plus point lookups; ranking is left to `FoodItemSearch` via ``FoodCatalog``.
/// Conformers must be `Sendable` and safe to query from any actor — ``FoodCatalog`` calls them off
/// the main actor on the AI meal-resolution path.
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

/// Opens the bundled `FoodCatalog.sqlite` read-only and answers candidate/point queries.
///
/// The production ``BundledFoodSource``. One instance serves the base catalog (the `Bundle.module`
/// resource); a second, tuned via `skipPriorityOrder`/`candidateCap`, serves the attachable branded
/// On-Demand-Resource catalog. Candidate retrieval runs an FTS5 prefix-AND match that mirrors
/// `FoodItemSearch`'s hard gate, de-biased by a data-type priority `ORDER BY` so the fetch cap never
/// silently drops the top-priority rows; hydration decodes the JSON-blob columns
/// (micronutrients/tags/portions) back into `FoodItem`s. The v2 `gtin_upc` barcode column is
/// feature-detected once at open, so the same read path serves both the shipped v1 file and a
/// future v2 regeneration. All access is serialized on a private queue so the single connection is
/// safe to share across actors (`@unchecked Sendable`); open failures return nil from init, and any
/// query failure degrades to an empty result rather than throwing.
public nonisolated final class SQLiteBundledFoodSource: BundledFoodSource, @unchecked Sendable {
    private let db: OpaquePointer?
    private let queue = DispatchQueue(label: "com.fernlet.foodcatalog.sqlite")
    public let count: Int
    /// Whether the opened file carries the v2 `gtin_upc` column. Feature-detected once at open
    /// (PRAGMA table_info) so the same read path serves both the shipped v1 database and a future
    /// v2 regeneration — v1 statements never reference the missing column.
    let hasBarcodeColumn: Bool
    /// When true, `candidates(forQuery:)` omits the data-type priority `ORDER BY`. Set for the
    /// attachable branded/ODR database, which is 100% one `data_type` — the sort would be a wasted
    /// O(matchset) pass over an identical key. The base catalog keeps it (see `candidates`).
    private let skipPriorityOrder: Bool
    /// Row cap applied to `candidates(forQuery:)`. Defaults to `candidateFetchLimit` (the base
    /// catalog's tuned cap); the branded source can pass a smaller cap.
    private let candidateCap: Int

    /// Locates `FoodCatalog.sqlite` in `bundle` (defaults to this module's resource bundle). Returns
    /// nil when the resource is absent so callers can fall back to a user-items-only catalog rather
    /// than crashing. `nil` resolves to `.module`; `.module` is synthesized as internal, so it cannot
    /// appear as a default-argument value in this public initializer.
    public convenience init?(
        bundle: Bundle? = nil,
        skipPriorityOrder: Bool = false,
        candidateCap: Int = FoodCatalogSchema.candidateFetchLimit
    ) {
        let bundle = bundle ?? .module
        guard let url = bundle.url(forResource: FoodCatalogSchema.resourceName, withExtension: FoodCatalogSchema.resourceExtension) else {
            return nil
        }
        self.init(url: url, skipPriorityOrder: skipPriorityOrder, candidateCap: candidateCap)
    }

    /// Opens the database file at `url` read-only; returns nil when it cannot be opened.
    ///
    /// - Parameters:
    ///   - url: The SQLite catalog file to open read-only.
    ///   - skipPriorityOrder: Pass true for a single-`data_type` file (the branded/ODR catalog) to
    ///     skip the wasted priority sort in `candidates(forQuery:)`.
    ///   - candidateCap: Row cap for `candidates(forQuery:)`; defaults to the base catalog's tuned
    ///     `FoodCatalogSchema.candidateFetchLimit`.
    public init?(
        url: URL,
        skipPriorityOrder: Bool = false,
        candidateCap: Int = FoodCatalogSchema.candidateFetchLimit
    ) {
        // R5: a non-positive cap is not a cap — SQLite reads `LIMIT -1` as NO limit, the exact
        // opposite of what the parameter means.
        guard candidateCap > 0 else { return nil }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        self.db = handle
        self.count = Self.scalarCount(handle)
        self.hasBarcodeColumn = Self.columnExists(handle, table: "food", column: "gtin_upc")
        self.skipPriorityOrder = skipPriorityOrder
        self.candidateCap = candidateCap
    }

    /// The select list matching this file's schema — v1 files must never see `gtin_upc`.
    private var selectColumns: String {
        hasBarcodeColumn ? FoodCatalogSchema.selectColumnsWithBarcode : FoodCatalogSchema.selectColumns
    }

    deinit { sqlite3_close(db) }

    /// All rows whose indexed name/category/tags pass the FTS5 prefix-AND gate for `query`, hydrated
    /// up to the candidate cap in data-type-priority order (see the in-body comments for the
    /// de-bias rationale).
    public func candidates(forQuery query: String) -> [FoodItem] {
        let tokens = FoodItemSearch.searchTokens(in: query)
        guard !tokens.isEmpty else { return [] }
        // Prefix-AND across all FTS columns mirrors the scorer's hard gate exactly. Each token expands
        // to its singular/plural match variants (`FoodItemSearch.matchVariants`) so the FTS surfaces
        // the same rows the scorer will accept — a plural query reaches the singular canonical food.
        // The variants are OR'd (a token passes on any form) and the tokens AND'd, matching the gate's
        // "every query token must match" semantics. FTS5 requires an explicit `AND` between grouped
        // terms. Tokens/variants are normalized to letters/digits, so none collide with FTS syntax.
        let match = tokens
            .map { token -> String in
                let terms = FoodItemSearch.matchVariants(for: token).map { "\($0)*" }
                return terms.count == 1 ? terms[0] : "(" + terms.joined(separator: " OR ") + ")"
            }
            .joined(separator: " AND ")
        // Canonical FTS5 form: match against the virtual table directly (its rowid is the food_id),
        // then resolve the rows. More portable than a JOIN+MATCH across SQLite versions.
        // ORDER BY de-biases the LIMIT truncation: without it SQLite returns the lowest food_ids, and
        // the top-priority `survey`/`foundation` foods carry the HIGHEST ids, so 100% of them were
        // silently dropped for broad prefixes ("chi"/"che"/"cho") that overflow the cap. The CASE
        // mirrors `FoodItemSearch.dataTypePriority(_, brandQuery: false)` — truncation only bites broad
        // *generic* prefixes (brand queries match too few rows to overflow), so the non-brand ordering
        // is the correct de-bias; the scorer still applies the final, brand-aware ranking.
        //
        // `skipPriorityOrder` OMITS that ORDER BY: the branded/ODR database is 100% one `data_type`,
        // so the CASE key is identical for every matched row and the sort is a wasted O(matchset)
        // pass — dropping it takes a broad-prefix branded query from ~29ms to ~5ms. The scorer still
        // applies the final, brand-aware ranking over the hydrated candidates.
        let priorityOrder = skipPriorityOrder ? "" :
            "ORDER BY CASE data_type WHEN 'foundation' THEN 5 WHEN 'survey' THEN 4 WHEN 'srLegacy' THEN 3 WHEN 'branded' THEN 2 WHEN 'restaurant' THEN 1 ELSE 0 END DESC, food_id ASC "
        let sql = """
        SELECT \(selectColumns) FROM food \
        WHERE food_id IN (SELECT rowid FROM food_fts WHERE food_fts MATCH ?) \
        \(priorityOrder)LIMIT \(candidateCap);
        """
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, match) }
    }

    /// Point lookup by the food's stable UUID (stored as its string form in the indexed `id` column).
    public func item(id: UUID) -> FoodItem? {
        let sql = "SELECT \(selectColumns) FROM food WHERE id = ? LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, id.uuidString) }.first
    }

    /// The largest number of ids one `IN (...)` query may carry.
    ///
    /// R5: SQLite's `SQLITE_MAX_VARIABLE_NUMBER` caps bound parameters; past it the prepare fails
    /// and `fetchRows` returns `[]`, so every ingredient of a large recipe set would resolve to
    /// nothing. 500 is comfortably inside SQLite's default (999) on every platform Fernlet ships to.
    static let maxIDsPerQuery = 500

    /// Batch point lookup — a single `IN` query per ``maxIDsPerQuery`` chunk; rows come back in
    /// SQLite's own order, not the caller's `ids` order.
    public func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        var results: [FoodItem] = []
        var remaining = ids[...]
        while !remaining.isEmpty {
            let chunk = Array(remaining.prefix(Self.maxIDsPerQuery))
            remaining = remaining.dropFirst(chunk.count)
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            let sql = "SELECT \(selectColumns) FROM food WHERE id IN (\(placeholders));"
            results += fetchRows(sql) { stmt in
                for (offset, id) in chunk.enumerated() {
                    sqliteBindText(stmt, Int32(offset + 1), id.uuidString)
                }
            }
        }
        return results
    }

    /// The alphabetically first row whose `normalized_name` equals `normalizedName` (deterministic
    /// tie-break), or nil.
    public func exactMatch(normalizedName: String) -> FoodItem? {
        let sql = "SELECT \(selectColumns) FROM food WHERE normalized_name = ? ORDER BY name LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, normalizedName) }.first
    }

    /// Point lookup by normalized GTIN; always nil on a v1 file, which has no `gtin_upc` column.
    public func item(barcode: String) -> FoodItem? {
        // v1 files (the shipped database) have no gtin_upc column — never reference it there.
        guard hasBarcodeColumn else { return nil }
        let sql = "SELECT \(selectColumns) FROM food WHERE gtin_upc = ? ORDER BY name LIMIT 1;"
        return fetchRows(sql) { stmt in sqliteBindText(stmt, 1, barcode) }.first
    }

    // MARK: Query execution

    /// Prepares, binds, steps, and hydrates `sql` on the serial queue. Any SQLite failure
    /// (prepare error, missing db) yields an empty array — the read path never throws.
    private func fetchRows(_ sql: String, bind: (OpaquePointer?) -> Void) -> [FoodItem] {
        queue.sync {
            guard let db else { return [] }
            var stmt: OpaquePointer?
            // R7: a prepare failure (schema mismatch, too many bound variables) turns every lookup
            // into "no results"; the recovery is unchanged — an empty array — but it is now named.
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                let message = sqlite3_errmsg(db).map { String(cString: $0) } ?? "unknown"
                FernletAuditLog.log("foodCatalog.prepare.failed", context: ["error": message])
                return []
            }
            defer { sqlite3_finalize(stmt) }
            bind(stmt)
            var results: [FoodItem] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let item = Self.hydrate(stmt, includesBarcode: hasBarcodeColumn) { results.append(item) }
            }
            return results
        }
    }

    /// The `food` table's total row count, read once at open to seed `count`.
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

/// A trivial bundled source backed by an in-memory array — the test double for
/// ``SQLiteBundledFoodSource``.
///
/// Used by tests (and as ``FoodCatalog/bundled(bundle:)``'s empty fallback when the SQLite resource
/// is missing) so they don't need the generated database. `candidates(forQuery:)` returns
/// everything; ``FoodCatalog``'s scorer applies the real gate and ranking, so results match the
/// SQLite path for the same item set.
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
