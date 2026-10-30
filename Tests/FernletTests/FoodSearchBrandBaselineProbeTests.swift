// FoodSearchBrandBaselineProbeTests.swift
// FernletTests
//
// Food search Phase 0 (Docs/Food-Search-Implementation-Plan-2026-10-27.md): the reproducible quality and
// performance baseline for BRAND and product search. A MEASURING probe, not a pin — it asserts nothing
// about today's answers, so later phases re-run it and diff. Only the panel's own shape is checked on
// every run (`FoodSearchBrandPanelTests`).
//
// WHAT IT REPLAYS. Every entry of `Tests/FoodSearchBaseline/brand-panel.json` through the quick-log /
// meal-composer call, `catalog.results(for:context: .userTyped)` (standard order, six rows), against
// the shipped base catalog and, when the branded On-Demand-Resource file is available, base + branded
// with the loader's production configuration (`BrandedCatalogResourceLoader`: cap 600, no priority
// sort). Each configuration runs twice: COLD (no history, no corrections, no user items) and WARM
// (a deterministic history; see `warmHistory`).
//
// WHAT IT RECORDS, per query: the candidate pool by route (base, branded) with its size and whether the
// row cap truncated it; the same gate with a 50,000-row cap, so truncation loss is separable from gate
// loss; stage times (retrieval, index build, scoring) and the settled end-to-end call; the six shown
// rows with their ids, brand, data type, origin route and match evidence (name carries every query
// token, brand agrees with the label, row is acceptable); the first acceptable rank within 60; and the
// panel metrics — pool recall, top-1, top-six, zero results, brand mismatch, distinct brands in the six.
// The summary splits by configuration × profile × tuning/held-out × intent.
//
// LABELS ARE EQUIVALENCE GROUPS, not one row: see the panel's `matching` field. They are drafts until
// the owner reviews them (`reviewStatus`). `Scripts/food-search-baseline/audit.py` evaluates the same
// predicates straight against both SQLite files, so "the product is not in the data" is told apart from
// "retrieval dropped it" and "ranking buried it".
//
// OPT-IN ONLY, and local: nothing runs unless the runner environment carries `FERNLET_BRAND_BASELINE`.
// Output goes to `FERNLET_REPLAY_OUT` (a directory) as `brand-baseline-<config>.json` plus
// `brand-baseline-summary.json`, or is printed between `===BRAND-BASELINE-JSON-BEGIN <name>===` markers.
// Queries are panel text, never user data; nothing is logged elsewhere.
//
//     TEST_RUNNER_FERNLET_BRAND_BASELINE=1 TEST_RUNNER_FERNLET_REPLAY_OUT=/abs/out \
//       TEST_RUNNER_FERNLET_REPLAY_BRANDED=/abs/FoodCatalogBranded.sqlite \
//       xcodebuild test-without-building … -only-testing:FernletTests/FoodSearchBrandBaselineProbeTests
//
// A missing branded file is REPORTED (`brandedAvailable: false` in the summary), never counted as
// branded coverage.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

// MARK: - Panel

/// The labeled brand/product search panel (`Tests/FoodSearchBaseline/brand-panel.json`).
struct BrandSearchPanel: Codable {
    /// Schema version of the panel file.
    let version: Int
    /// Whether the labels have been reviewed, and by whom.
    let reviewStatus: String
    /// The matching rules, stated once for readers of the file.
    let matching: String
    /// Every labeled query.
    let entries: [BrandSearchPanelEntry]

    /// The panel as committed.
    static func load() throws -> BrandSearchPanel {
        let data = try Data(contentsOf: RepoRoot.url("Tests/FoodSearchBaseline/brand-panel.json"))
        return try JSONDecoder().decode(BrandSearchPanel.self, from: data)
    }
}

/// One labeled query.
struct BrandSearchPanelEntry: Codable {
    /// Stable identifier.
    let id: String
    /// The typed text.
    let query: String
    /// `tuning` or `heldout`.
    let split: String
    /// `brand`, `brandOnly`, `restaurant`, `ambiguous` or `generic`.
    let intent: String
    /// Panel category (brand+product, punctuation, typo, …).
    let category: String
    /// The acceptable equivalence group; nil only with `expectNoAcceptable`.
    let accept: BrandSearchPredicate?
    /// True when the honest answer is that no matching product exists.
    let expectNoAcceptable: Bool?
    /// Labeling notes.
    let notes: String?

    /// Intents whose six should agree with a requested brand.
    var isBrandIntent: Bool { ["brand", "brandOnly", "restaurant"].contains(intent) && accept?.brand != nil }
}

/// An acceptable-row predicate. Every present field must hold.
struct BrandSearchPredicate: Codable {
    /// Brand aliases matched as whole-word runs in the brand field or the name.
    let brand: [String]?
    /// Terms that must each prefix a name word (a spaced term must appear as a phrase).
    let nameAll: [String]?
    /// Terms of which at least one must match the name.
    let nameAny: [String]?
    /// Terms none of which may match the name.
    let nameNone: [String]?
    /// Allowed `FoodDataType` tokens.
    let dataTypes: [String]?

    /// Whether `item` belongs to the acceptable group.
    func accepts(_ item: FoodItem) -> Bool {
        let name = BrandSearchText.canonical(item.name)
        if brand != nil, !brandAgrees(item) { return false }
        if let nameAll, !nameAll.allSatisfy({ BrandSearchText.matches($0, in: name) }) { return false }
        if let nameAny, !nameAny.contains(where: { BrandSearchText.matches($0, in: name) }) { return false }
        if let nameNone, nameNone.contains(where: { BrandSearchText.matches($0, in: name) }) { return false }
        if let dataTypes, !dataTypes.contains(item.dataType.rawValue) { return false }
        return true
    }

    /// Whether the row's brand field or name carries one of the brand aliases.
    func brandAgrees(_ item: FoodItem) -> Bool {
        guard let brand else { return true }
        let fields = [item.brandSource ?? "", item.name].map(BrandSearchText.canonical)
        return brand.contains { alias in
            let wanted = BrandSearchText.canonical(alias)
            return fields.contains { BrandSearchText.containsRun(wanted, in: $0) }
        }
    }
}

/// The panel's text canonicalisation, shared with `Scripts/food-search-baseline/audit.py`.
enum BrandSearchText {
    /// Lowercased, diacritics folded, apostrophes dropped, every other non-alphanumeric run a space.
    static func canonical(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "\u{2019}", with: "")
        let spaced = folded.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? String($0) : " " }.joined()
        return spaced.split(separator: " ").joined(separator: " ")
    }

    /// Whole-word run containment.
    static func containsRun(_ run: String, in text: String) -> Bool {
        guard !run.isEmpty else { return false }
        return (" " + text + " ").contains(" " + run + " ")
    }

    /// A spaced term matches as a phrase prefix; a single word prefixes any word.
    static func matches(_ term: String, in canonicalName: String) -> Bool {
        let wanted = canonical(term)
        if wanted.contains(" ") { return (" " + canonicalName).contains(" " + wanted) }
        return canonicalName.split(separator: " ").contains { $0.hasPrefix(wanted) }
    }
}

// MARK: - Measurement records

/// One row of the six.
struct BrandBaselineRow: Codable {
    /// 1-based rank.
    let rank: Int
    /// Stable food id.
    let id: String
    /// Display name.
    let name: String
    /// Brand field as stored (owner, usually).
    let brand: String?
    /// Frozen `FoodDataType` token.
    let dataType: String
    /// Which retrieval route supplied the row: `base`, `branded`, or `other`.
    let route: String
    /// Whether the name alone carries every query token (the scorer's floor).
    let nameCarriesQuery: Bool
    /// Whether the row agrees with the labeled brand (true when the label names none).
    let brandAgrees: Bool
    /// Whether the row is in the acceptable group.
    let acceptable: Bool
}

/// One query under one configuration and profile.
struct BrandBaselineQuery: Codable {
    let id: String
    let query: String
    let split: String
    let intent: String
    let category: String
    /// Whether the entry has an acceptable group (false for `expectNoAcceptable`).
    let labeled: Bool
    /// Base-route candidates at the production cap, and whether the cap was hit.
    let basePool: Int
    let baseTruncated: Bool
    /// Branded-route candidates at the production cap (600), and whether the cap was hit.
    let brandedPool: Int
    let brandedTruncated: Bool
    /// The same gate at a 50,000-row cap (`-1` when that cap was hit too).
    let baseGateUncapped: Int
    let brandedGateUncapped: Int
    /// Acceptable rows in the capped pool, and in the 50,000-capped gate.
    let acceptableInPool: Int
    let acceptableInGate: Int
    /// Stage timings in milliseconds: both routes' retrieval, the index build, the scorer.
    let retrievalMs: Double
    let indexMs: Double
    let scoringMs: Double
    /// The settled end-to-end call: the first run and the faster of two repeats.
    let totalFirstMs: Double
    let totalRepeatMs: Double
    /// The six shown.
    let shown: [BrandBaselineRow]
    /// First acceptable rank within the 60-row window, nil when none.
    let firstAcceptableRank: Int?
    let top1Correct: Bool
    let top6Success: Bool
    let zeroResult: Bool
    /// Rows of the six that disagree with the labeled brand (brand intents only).
    let brandMismatchesInTop6: Int
    /// Distinct non-empty brand fields in the six.
    let distinctBrandsInTop6: Int
    /// Whether the history row (warm profile) is in the six, and at rank 1.
    let historyRowShown: Bool?
    let historyRowFirst: Bool?
}

/// One full pass.
struct BrandBaselineRun: Codable {
    /// `base` or `base+branded`.
    let configuration: String
    /// `cold` or `warm`.
    let profile: String
    let bundledCount: Int
    let queries: [BrandBaselineQuery]
}

/// The aggregate the report quotes.
struct BrandBaselineSummaryRow: Codable {
    let configuration: String
    let profile: String
    let split: String
    let intentGroup: String
    let queries: Int
    let labeled: Int
    let poolRecall: Double
    let gateRecall: Double
    let top1: Double
    let top6: Double
    let zeroResultRate: Double
    let brandMismatchRate: Double
    let truncatedQueries: Int
    let totalP50Ms: Double
    let totalP95Ms: Double
    let totalMaxMs: Double
}

/// The whole summary file.
struct BrandBaselineSummary: Codable {
    let panelVersion: Int
    let panelReviewStatus: String
    let brandedAvailable: Bool
    let runAt: String
    let rows: [BrandBaselineSummaryRow]
}

// MARK: - Panel shape (runs on every test pass)

/// Pins the panel file's SHAPE, never search answers: it decodes, ids are unique, every entry is
/// either labeled or explicitly expects no acceptable row, and both splits cover brand and generic
/// intents, so a held-out set always exists to check tuning against.
struct FoodSearchBrandPanelTests {
    @Test func panelIsWellFormed() throws {
        let panel = try BrandSearchPanel.load()
        let ids = panel.entries.map(\.id)
        #expect(Set(ids).count == ids.count, "panel ids must be unique")
        for entry in panel.entries {
            #expect(["tuning", "heldout"].contains(entry.split), "\(entry.id): unknown split")
            #expect(["brand", "brandOnly", "restaurant", "ambiguous", "generic"].contains(entry.intent), "\(entry.id): unknown intent")
            #expect((entry.accept != nil) != (entry.expectNoAcceptable == true), "\(entry.id): label XOR expectNoAcceptable")
        }
        for split in ["tuning", "heldout"] {
            let inSplit = panel.entries.filter { $0.split == split }
            #expect(inSplit.contains { $0.isBrandIntent }, "\(split) needs brand queries")
            #expect(inSplit.contains { $0.intent == "generic" }, "\(split) needs generic controls")
        }
    }

    @Test func canonicalTextMatchesTheAuditScript() {
        #expect(BrandSearchText.canonical("McDonald’s") == "mcdonalds")
        #expect(BrandSearchText.canonical("Häagen-Dazs") == "haagen dazs")
        #expect(BrandSearchText.canonical("Chick-fil-A, Sandwich") == "chick fil a sandwich")
        #expect(BrandSearchText.containsRun("kind", in: "kind inc"))
        #expect(!BrandSearchText.containsRun("kind", in: "kinder inc"))
        #expect(BrandSearchText.matches("bar", in: "nuts spices bars"))
        #expect(BrandSearchText.matches("ice cream", in: "vanilla ice cream bars"))
    }
}

// MARK: - Probe

/// The opt-in baseline probe. See the file header.
struct FoodSearchBrandBaselineProbeTests {
    /// The branded loader's production cap (`BrandedCatalogResourceLoader.candidateCap`).
    static let brandedCap = 600
    /// The "uncapped" gate's bound — large enough for every panel query, still bounded.
    static let gateCap = 50_000

    /// The sources one configuration searches, opened the way production opens them, plus wide-cap
    /// twins for the gate counts.
    struct Sources {
        let base: SQLiteBundledFoodSource
        let baseWide: SQLiteBundledFoodSource
        let branded: SQLiteBundledFoodSource?
        let brandedWide: SQLiteBundledFoodSource?
    }

    @Test func replayBrandPanel() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FERNLET_BRAND_BASELINE"] != nil || env["TEST_RUNNER_FERNLET_BRAND_BASELINE"] != nil else { return }
        let panel = try BrandSearchPanel.load()
        let out = env["FERNLET_REPLAY_OUT"] ?? env["TEST_RUNNER_FERNLET_REPLAY_OUT"]
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        let base = try #require(SQLiteBundledFoodSource())
        let baseWide = try #require(SQLiteBundledFoodSource(candidateCap: Self.gateCap))
        var runs = try passes(panel, catalog: catalog, sources: Sources(base: base, baseWide: baseWide, branded: nil, brandedWide: nil))
        let brandedURL = Self.brandedURL(env)
        if let brandedURL {
            let branded = try #require(SQLiteBundledFoodSource(url: brandedURL, skipPriorityOrder: true, candidateCap: Self.brandedCap))
            let wide = try #require(SQLiteBundledFoodSource(url: brandedURL, skipPriorityOrder: true, candidateCap: Self.gateCap))
            catalog.attachBrandedSource(branded)
            runs += try passes(panel, catalog: catalog, sources: Sources(base: base, baseWide: baseWide, branded: branded, brandedWide: wide))
            catalog.detachBrandedSource()
        } else {
            print("FoodSearchBrandBaseline: branded ODR catalog not found — base pass only (branded coverage NOT measured)")
        }
        for run in runs {
            Self.emit(run, name: "brand-baseline-\(run.configuration.replacingOccurrences(of: "+", with: "-"))-\(run.profile)", to: out)
        }
        let summary = BrandBaselineSummary(
            panelVersion: panel.version, panelReviewStatus: panel.reviewStatus,
            brandedAvailable: brandedURL != nil, runAt: ISO8601DateFormatter().string(from: Date()),
            rows: runs.flatMap(Self.summarize)
        )
        Self.emit(summary, name: "brand-baseline-summary", to: out)
        Self.printTable(summary)
    }

    /// The cold pass, then the warm pass built from the cold pass's answers.
    private func passes(_ panel: BrandSearchPanel, catalog: FoodCatalog, sources: Sources) throws -> [BrandBaselineRun] {
        let label = sources.branded == nil ? "base" : "base+branded"
        catalog.setSearchHistory(.empty)
        let cold = panel.entries.map { measure($0, catalog: catalog, sources: sources, historyRow: nil) }
        let now = Date()
        let picks = Self.warmHistory(panel, catalog: catalog)
        let weight = FoodSearchHistory.scaledWeight(count: 3, lastLoggedAt: now.addingTimeInterval(-3 * 86_400), now: now)
        catalog.setSearchHistory(FoodSearchHistory(weights: Dictionary(picks.values.map { ($0, weight) }, uniquingKeysWith: { first, _ in first })))
        let warm = panel.entries.map { measure($0, catalog: catalog, sources: sources, historyRow: picks[$0.id]) }
        catalog.setSearchHistory(.empty)
        return [
            BrandBaselineRun(configuration: label, profile: "cold", bundledCount: catalog.bundledCount, queries: cold),
            BrandBaselineRun(configuration: label, profile: "warm", bundledCount: catalog.bundledCount, queries: warm)
        ]
    }

    /// The WARM person, deterministic: for a brand query they once logged the first row of the cold
    /// 60-row window that DISAGREES with the requested brand (the conflicting-history case the plan
    /// names); for any other labeled query, the first acceptable row (consistent history). Unlabeled
    /// entries contribute nothing. Measures whether history can promote a conflicting brand.
    static func warmHistory(_ panel: BrandSearchPanel, catalog: FoodCatalog) -> [String: UUID] {
        var picks: [String: UUID] = [:]
        for entry in panel.entries {
            guard let accept = entry.accept else { continue }
            let window = catalog.results(for: entry.query, limit: FoodItemSearchWindow.deep, context: .userTyped)
            let pick = entry.isBrandIntent
                ? window.first { !accept.brandAgrees($0) }
                : window.first { accept.accepts($0) }
            picks[entry.id] = pick?.id
        }
        return picks
    }

    private func measure(_ entry: BrandSearchPanelEntry, catalog: FoodCatalog, sources: Sources, historyRow: UUID?) -> BrandBaselineQuery {
        let clock = ContinuousClock()
        var shown: [FoodItem] = []
        let first = clock.measure { shown = catalog.results(for: entry.query, context: .userTyped) }
        let repeatMs = (0..<2).map { _ in Self.ms(clock.measure { _ = catalog.results(for: entry.query, context: .userTyped) }) }.min() ?? 0
        var base: [FoodItem] = []
        var branded: [FoodItem] = []
        let retrieval = clock.measure {
            base = sources.base.candidates(forQuery: entry.query, stripsStopwords: true)
            branded = sources.branded?.candidates(forQuery: entry.query, stripsStopwords: true) ?? []
        }
        let pool = base + branded
        var index = FoodItemSearch.Index.empty
        let indexing = clock.measure { index = FoodItemSearch.Index(foodItems: pool) }
        let scoring = clock.measure { _ = FoodItemSearch.results(for: entry.query, in: index, limit: FoodItemSearchWindow.deep) }
        let baseGate = sources.baseWide.candidates(forQuery: entry.query, stripsStopwords: true)
        let brandedGate = sources.brandedWide?.candidates(forQuery: entry.query, stripsStopwords: true) ?? []
        let gate = baseGate + brandedGate
        let window = catalog.results(for: entry.query, limit: FoodItemSearchWindow.deep, context: .userTyped)
        let baseIDs = Set(base.map(\.id))
        let brandedIDs = Set(branded.map(\.id))
        let rows = shown.enumerated().map { offset, item in
            Self.row(item, rank: offset + 1, entry: entry, route: baseIDs.contains(item.id) ? "base" : brandedIDs.contains(item.id) ? "branded" : "other")
        }
        let accepts: (FoodItem) -> Bool = { entry.accept?.accepts($0) ?? false }
        return BrandBaselineQuery(
            id: entry.id, query: entry.query, split: entry.split, intent: entry.intent, category: entry.category,
            labeled: entry.accept != nil,
            basePool: base.count, baseTruncated: base.count >= FoodCatalogSchema.candidateFetchLimit,
            brandedPool: branded.count, brandedTruncated: sources.branded != nil && branded.count >= Self.brandedCap,
            baseGateUncapped: baseGate.count >= Self.gateCap ? -1 : baseGate.count,
            brandedGateUncapped: brandedGate.count >= Self.gateCap ? -1 : brandedGate.count,
            acceptableInPool: pool.filter(accepts).count, acceptableInGate: gate.filter(accepts).count,
            retrievalMs: Self.ms(retrieval), indexMs: Self.ms(indexing), scoringMs: Self.ms(scoring),
            totalFirstMs: Self.ms(first), totalRepeatMs: repeatMs,
            shown: rows,
            firstAcceptableRank: window.firstIndex(where: accepts).map { $0 + 1 },
            top1Correct: shown.first.map(accepts) ?? false,
            top6Success: shown.contains(where: accepts),
            zeroResult: shown.isEmpty,
            brandMismatchesInTop6: entry.isBrandIntent ? rows.filter { !$0.brandAgrees }.count : 0,
            distinctBrandsInTop6: Set(shown.compactMap { $0.brandSource.map(BrandSearchText.canonical) }.filter { !$0.isEmpty }).count,
            historyRowShown: historyRow.map { id in shown.contains { $0.id == id } },
            historyRowFirst: historyRow.map { id in shown.first?.id == id }
        )
    }

    private static func row(_ item: FoodItem, rank: Int, entry: BrandSearchPanelEntry, route: String) -> BrandBaselineRow {
        BrandBaselineRow(
            rank: rank, id: item.id.uuidString, name: item.name, brand: item.brandSource,
            dataType: item.dataType.rawValue, route: route,
            nameCarriesQuery: FoodItemSearch.nameCarriesQuery(item.name, query: entry.query),
            brandAgrees: entry.accept?.brandAgrees(item) ?? true,
            acceptable: entry.accept?.accepts(item) ?? false
        )
    }

    private static func ms(_ duration: Duration) -> Double {
        let parts = duration.components
        return (Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1e15).rounded(toPlaces: 2)
    }

    // MARK: Summary

    private static func summarize(_ run: BrandBaselineRun) -> [BrandBaselineSummaryRow] {
        var rows: [BrandBaselineSummaryRow] = []
        for split in ["tuning", "heldout", "all"] {
            for group in ["brand", "generic", "all"] {
                let queries = run.queries.filter { query in
                    (split == "all" || query.split == split) && (group == "all" || intentGroup(query.intent) == group)
                }
                guard !queries.isEmpty else { continue }
                rows.append(summaryRow(run, split: split, group: group, queries: queries))
            }
        }
        return rows
    }

    /// Brand-like intents are scored together; ambiguous queries count with generic.
    private static func intentGroup(_ intent: String) -> String {
        ["brand", "brandOnly", "restaurant"].contains(intent) ? "brand" : "generic"
    }

    private static func summaryRow(_ run: BrandBaselineRun, split: String, group: String, queries: [BrandBaselineQuery]) -> BrandBaselineSummaryRow {
        let labeled = queries.filter(\.labeled)
        let rate: ([BrandBaselineQuery], (BrandBaselineQuery) -> Bool) -> Double = { set, test in
            set.isEmpty ? 0 : (Double(set.filter(test).count) / Double(set.count)).rounded(toPlaces: 3)
        }
        let shownCount = queries.reduce(0) { $0 + $1.shown.count }
        let mismatches = queries.reduce(0) { $0 + $1.brandMismatchesInTop6 }
        let totals = queries.map(\.totalRepeatMs).sorted()
        return BrandBaselineSummaryRow(
            configuration: run.configuration, profile: run.profile, split: split, intentGroup: group,
            queries: queries.count, labeled: labeled.count,
            poolRecall: rate(labeled) { $0.acceptableInPool > 0 },
            gateRecall: rate(labeled) { $0.acceptableInGate > 0 },
            top1: rate(labeled) { $0.top1Correct },
            top6: rate(labeled) { $0.top6Success },
            zeroResultRate: rate(queries) { $0.zeroResult },
            brandMismatchRate: shownCount == 0 ? 0 : (Double(mismatches) / Double(shownCount)).rounded(toPlaces: 3),
            truncatedQueries: queries.filter { $0.baseTruncated || $0.brandedTruncated }.count,
            totalP50Ms: percentile(totals, 0.5), totalP95Ms: percentile(totals, 0.95), totalMaxMs: totals.last ?? 0
        )
    }

    /// Nearest-rank percentile of an ascending list.
    private static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((fraction * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    // MARK: Output

    private static func brandedURL(_ env: [String: String]) -> URL? {
        let named = env["FERNLET_REPLAY_BRANDED"] ?? env["TEST_RUNNER_FERNLET_REPLAY_BRANDED"]
        let candidate = named.map { URL(fileURLWithPath: $0) } ?? RepoRoot.url("ODRAssets/FoodCatalogBranded.sqlite")
        return BrandedODRCatalogTests.usableBrandedDatabase(at: candidate)
    }

    private static func emit<T: Encodable>(_ value: T, name: String, to directory: String?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            print("FoodSearchBrandBaseline: could not encode \(name)")
            return
        }
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(name + ".json")
            do {
                try data.write(to: url, options: .atomic)
                print("FoodSearchBrandBaseline: wrote \(url.path)")
                return
            } catch {
                print("FoodSearchBrandBaseline: write failed (\(error)); printing instead")
            }
        }
        print("===BRAND-BASELINE-JSON-BEGIN \(name)===")
        print(String(decoding: data, as: UTF8.self))
        print("===BRAND-BASELINE-JSON-END===")
    }

    private static func printTable(_ summary: BrandBaselineSummary) {
        print("FoodSearchBrandBaseline summary (branded available: \(summary.brandedAvailable))")
        for row in summary.rows where row.split != "all" || row.intentGroup == "all" {
            print("  \(row.configuration) \(row.profile) \(row.split) \(row.intentGroup): n=\(row.queries) labeled=\(row.labeled) "
                + "pool=\(row.poolRecall) gate=\(row.gateRecall) top1=\(row.top1) top6=\(row.top6) "
                + "zero=\(row.zeroResultRate) mismatch=\(row.brandMismatchRate) trunc=\(row.truncatedQueries) "
                + "p50=\(row.totalP50Ms)ms p95=\(row.totalP95Ms)ms")
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (self * scale).rounded() / scale
    }
}
