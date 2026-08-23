// FoodSearchCorpusTests.swift
// FernletTests
//
// Tier 0 of Docs/Food-Search-And-Community-Database-Research-2026-08-22.md — the instrument the rest
// of the food-search fix list is gated on (§25 "instrument first", §30 row 1).
//
// WHAT THIS SUITE IS. It replays a 57-query corpus through the REAL shipped pipeline —
// `FoodCatalog.bundled()` over the shipped `FoodCatalog.sqlite`, i.e. the FTS5 prefix-AND gate in
// `BundledFoodStore.candidates` feeding `FoodItemSearch`'s scorer and comparator — and pins today's
// answer for every query: which return zero rows, what the top-1 row is, and what it scored. Nothing
// is re-implemented here; every number came out of the shipping code.
//
// TWO SURFACES, NOT ONE. The typeahead and the meal resolver do NOT share a ranking. Search goes
// through `FoodCatalog.results`/`scoredResults`; `MealResolutionService` and the quick-log path go
// through `FoodCatalog.candidates(for:limit:)`, which layers `FoodSelectionCandidateBuilder`'s
// phrase splitting and `PreparedDishHeuristic.demotingDishes` on top. They disagree loudly — the
// resolver finds rows for five queries where search returns nothing at all, and picks a DIFFERENT
// food for six more. `resolverCandidateSurfaceIsUnchanged()` is the second bank, so a fix that moves
// what the resolver picks cannot slip past a green corpus.
//
// WHY IT IS GREEN WHILE 70% OF THE CORPUS IS WRONG. The baseline is a photograph, not a
// specification. Today's failures are ENCODED as the current-state expectation, with a verdict
// recorded alongside in `FoodSearchCorpusVerdict`. A fix is then a deliberate, reviewable edit: flip
// `verdict` and `expectedTopName` for the rows it is meant to move, and leave the rest alone. A row
// that moves WITHOUT such an edit is exactly the regression this suite exists to catch.
//
// WHY THAT MATTERS MORE THAN USUAL HERE. §29 (the coupled-fix hazard) shows the three
// highest-leverage fixes regress each other: naive stopword stripping (1.6) ALONE turns
// `cheese pizza slice` from a defensible branded row into a 1,655 kcal calzone, because dropping the
// token lets the survey tier back through a comparator that sorts data type above score. 1.6, 1.7a
// and 1.8 have to be measured as ONE unit — against this corpus, not against intuition.
//
// ── HOW THE CORPUS WAS BUILT, AND WHAT ITS NUMBERS DO AND DO NOT MEAN ───────────────────────────
//
// §34 (Appendix A) enumerates ONLY its 26 failing queries by name — 11 zero-result and 15
// wrong-top-1. The 31 "defensible" queries it counts are described but NEVER LISTED, so they cannot
// be reproduced. This corpus therefore has two halves that must be read differently:
//
//   • `reportNamedZeroResultQueries` (11) and `reportNamedWrongTopOneQueries` (15) are the research's
//     own named lists, verbatim. They reproduce EXACTLY. §8's 11 and 15 stay pinned as what they
//     are: the research's findings about the queries it chose to name.
//
//   • `preRegisteredQueries` (31) replaces §34's unlisted 31. They were chosen by QUERY SHAPE —
//     declared in `FoodSearchCorpusShape` and fixed BEFORE the outcome was consulted — not by
//     outcome. This matters because the first version of this file picked its 31 by keeping only
//     queries whose live top-1 looked right, which mechanically reproduced §34's 11/15/31 split
//     instead of measuring anything. Five of the 31 (`chicken burrito bowl`, `grilled salmon fillet`,
//     `whole wheat toast`, `chobani greek yogurt`, `quest protein bar`) had never been run at all
//     when they were written down; the rest were selected for shape coverage with known failures
//     deliberately RETAINED rather than filtered out.
//
// THE MEASURED BASELINE — 2026-08-22, tree at b259f3d — is `measuredBaseline` below:
// **13 zero-result, 27 wrong-top-1, 17 defensible of 57.** 40 of 57 fail outright (70%); of the 44
// queries that return anything, 27 (61%) return the wrong food. That is materially worse than §8's
// ~46%, and the difference is selection, not disagreement: §8's 46% describes §8's corpus.
//
// This corpus is NOT a random sample of user input and its rate is NOT an unbiased population
// estimate. It is a fixed, shape-balanced panel whose only job is to move when the pipeline moves.
// The counts are asserted as MEASURED FACTS derived from the arrays — there is no free-standing
// literal to drift.
//
// MEASURED, NOT COPIED. Every value here was re-measured against the shipped catalog. All 11
// zero-result queries, all 15 wrong-top-1 rows, all 22 MATCH expressions in §8's FTS table (§8's
// prose calls it "sixteen"; the table has 21 rows plus its own `dominos*` correction) and every score
// quoted in §9 reproduced exactly. Three of §8's row names are longer than the prose renders them,
// and two orderings in §9(b) did not reproduce — documented at the pins that carry them.
//
// TIE-BREAKS ARE LOCALE-SENSITIVE IN PRINCIPLE. The comparator's last key is
// `name.localizedStandardCompare`, so equal-scoring rows within one tier are ordered by the process
// locale. Verified stable, not assumed: all 14 tests are green under Turkish — the classic dotless-ı
// hazard — because every tie pinned here is broken on plain ASCII letters. Reproduce by appending
// `-testLanguage tr -testRegion TR` to the `test-without-building` command. Pins that depend on a
// tie say so in their note.
//
// SCOPE NOTES (deliberate, not oversights). The catalog is queried with NO user items —
// `setUserItems` is never called — because `sourcePriority` puts any matching manual item above every
// catalog row, so a user-item fixture would mask the catalog ranking this suite exists to measure.
// The suite opens the shipped database roughly thirty times per run (~11 s wall clock), which is
// cheap enough not to warrant a shared fixture that would break parallel-suite isolation.
//
// Read-only and self-contained: opens the shipped catalog read-only, writes nothing, and shares no
// mutable fixture with any other suite.

import Foundation
import SQLite3
import Testing
import FernletDomainModel
import FoodCatalog

/// The research's verdict on what a corpus query does **today**.
///
/// Recorded per query so a later fix flips a row's verdict explicitly instead of silently
/// re-baselining: the population of each case is asserted, so "fixed three, broke three" cannot pass.
enum FoodSearchCorpusVerdict: String, Sendable {
    /// The FTS prefix-AND gate matches nothing, so the search surface shows an empty list.
    case zeroResults
    /// Rows come back, but the top-1 is not the food a person typing this meant.
    case wrongTopOne
    /// The top-1 is a defensible answer — the regression floor a fix must not disturb.
    case defensible
}

/// Why a query is in the corpus — the selection criterion, recorded so the corpus cannot quietly
/// become outcome-selected again.
///
/// The two `reportNamed…` cases are the research's own named lists, kept verbatim. The five shape
/// cases are the pre-registered replacement for §34's never-enumerated 31: each was fixed before its
/// outcome was consulted, and known failures were retained rather than filtered out.
enum FoodSearchCorpusShape: String, Sendable {
    /// One of §34's 11 named zero-result queries.
    case reportNamedZeroResult
    /// One of §8's 15 named wrong-top-1 queries.
    case reportNamedWrongTopOne
    /// A bare whole food, one token: `banana`, `salmon`, `chickpeas`.
    case singleTokenWholeFood
    /// A qualifier plus a generic food, two tokens: `white rice`, `whole milk`, `olive oil`.
    case modifierPlusFood
    /// A composed or restaurant dish: `grilled cheese`, `chicken burrito bowl`.
    case preparedDish
    /// A food named with its preparation: `hard boiled egg`, `grilled chicken`.
    case preparationQualified
    /// A brand or product name: `string cheese`, `chobani greek yogurt`, `quest protein bar`.
    case brandedProduct
}

/// One replayable query in the food-search corpus, with today's behaviour pinned.
///
/// `expectedTopName` is `nil` exactly when the query returns no rows, which is why name and score are
/// optional rather than modelling "empty" as an empty string: an accidental empty-string expectation
/// would pass against a real row whose name happened to be empty.
struct FoodSearchCorpusCase: Sendable, Equatable {
    /// The query text. A **frozen English matching input**: it is folded by `FoodItemSearch.normalized`
    /// and matched against an FTS index baked in English. Never localize it (localization wall).
    let query: String
    /// Why this query is in the corpus — the selection criterion, fixed before the outcome was known.
    let shape: FoodSearchCorpusShape
    /// What the query does today.
    let verdict: FoodSearchCorpusVerdict
    /// The name of the row ranked first today, or `nil` when the query returns nothing.
    let expectedTopName: String?
    /// That row's `FoodItemSearch` score today, or `nil` when the query returns nothing.
    let expectedTopScore: Int?

    /// Builds one corpus row. `topName`/`topScore` are omitted only for a zero-result query.
    init(
        _ query: String,
        _ shape: FoodSearchCorpusShape,
        _ verdict: FoodSearchCorpusVerdict,
        _ topName: String? = nil,
        _ topScore: Int? = nil
    ) {
        self.query = query
        self.shape = shape
        self.verdict = verdict
        self.expectedTopName = topName
        self.expectedTopScore = topScore
    }
}

/// One pinned row of a ranked result list.
///
/// Carries the data type as well as the score because §9's whole point is that the comparator sorts
/// data type ABOVE score — a pin that omitted the tier could not show the inversion.
struct FoodSearchRankedRow: Sendable, Equatable {
    /// The row's catalog name.
    let name: String
    /// Its `FoodItemSearch` score.
    let score: Int
    /// Its `FoodDataType` raw value — a frozen persisted token, never localized.
    let dataType: String

    /// Builds one pinned ranked row.
    init(_ name: String, _ score: Int, _ dataType: String) {
        self.name = name
        self.score = score
        self.dataType = dataType
    }
}

/// The pinned top-6 for one query the research names outside the corpus, plus why it is pinned.
///
/// This table is the single source of truth for §9's row-level claims: the interpretive tests below
/// assert MECHANISMS against live data and no longer restate any of these names or scores.
struct FoodSearchRankedPin: Sendable {
    /// The query, a frozen English matching input.
    let query: String
    /// Why this query earns a row-level pin.
    let note: String
    /// The top-6 rows in rank order.
    let rows: [FoodSearchRankedRow]

    /// Builds one named ranking pin.
    init(_ query: String, _ note: String, _ rows: [FoodSearchRankedRow]) {
        self.query = query
        self.note = note
        self.rows = rows
    }
}

/// One pinned measurement of the RESOLVER surface — `FoodCatalog.candidates(for:limit:)`.
///
/// Separate from `FoodSearchCorpusCase` because the two surfaces genuinely disagree: the resolver
/// splits the description into phrases and then reorders with `PreparedDishHeuristic`, so it can
/// return rows where search returns none, and can pick a different food where search returns plenty.
struct FoodResolverCase: Sendable {
    /// The description a caller resolves, a frozen English matching input.
    let query: String
    /// How many candidates the resolver pool holds today.
    let expectedCount: Int
    /// The name of the candidate ranked first today, or `nil` when the pool is empty.
    let expectedTopName: String?

    /// Builds one resolver-surface pin.
    init(_ query: String, _ expectedCount: Int, _ expectedTopName: String?) {
        self.query = query
        self.expectedCount = expectedCount
        self.expectedTopName = expectedTopName
    }
}

/// A read-only raw-SQLite probe over the SHIPPED `FoodCatalog.sqlite`.
///
/// The catalog's public Swift surface answers searches and point lookups but exposes no per-source
/// row counts and no FTS row counts, and §25/§27 require both: the file carries no vintage table, so
/// its composition is the only available proxy for "which USDA release is in the box". Opens the
/// repo's own copy of the resource read-only and never writes. Binding reuses the FoodCatalog
/// module's ``sqliteBindText(_:_:_:)`` rather than repeating its allowlisted `unsafeBitCast`.
final class FoodCatalogFileProbe {
    private let db: OpaquePointer?

    /// Opens `url` read-only; returns nil when the file is missing or unreadable.
    init?(url: URL) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle)
            return nil
        }
        self.db = handle
    }

    deinit { sqlite3_close(db) }

    /// The shipped catalog inside the repo working tree — the same bytes the `FoodCatalog` SPM target
    /// bundles as a resource, which ``FoodSearchCorpusTests/shippedCatalogCompositionIsUnchanged()``
    /// confirms by cross-checking the row count against the loaded bundle.
    static let shippedCatalogURL = RepoRoot.url
        .appendingPathComponent("FernletKit/Sources/FoodCatalog/Resources/FoodCatalog.sqlite")

    /// Runs a single-column, single-row integer query. Returns nil on any SQLite failure rather than
    /// a zero, so a broken query cannot masquerade as a genuine count of zero.
    func scalar(_ sql: String) -> Int? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }

    /// How many rows the FTS5 index matches for a raw MATCH expression (§8's retrieval-layer table).
    func ftsMatchCount(_ expression: String) -> Int? {
        var stmt: OpaquePointer?
        let sql = "SELECT COUNT(*) FROM food_fts WHERE food_fts MATCH ?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqliteBindText(stmt, 1, expression)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return Int(sqlite3_column_int64(stmt, 0))
    }
}

/// The Tier 0 corpus instrument: 57 queries replayed through the shipped search pipeline and a
/// second bank replayed through the resolver pipeline, plus the composition assertions that catch a
/// catalog regeneration.
///
/// See the file header for how the corpus was built and what its numbers mean. Re-measure before
/// editing it: `TEST_RUNNER_FOOD_CORPUS_DUMP=1` makes
/// ``dumpEmitsOneParseableRowPerCorpusQuery()`` print every pin in paste-ready literal form,
/// partitioned by measured verdict.
struct FoodSearchCorpusTests {
    /// Row count of the shipped catalog. Every test guards on it so none can pass vacuously against
    /// `FoodCatalog.bundled()`'s empty fallback (§25 names that failure mode in the two existing
    /// shipped-catalog tests, which silently `return` when the database is absent).
    static let shippedRowCount = 118_317

    // MARK: - The 57-query corpus

    /// The corpus: the research's 26 named failures plus the 31 pre-registered shape-balanced queries.
    static let corpus: [FoodSearchCorpusCase] =
        reportNamedZeroResultQueries + reportNamedWrongTopOneQueries + preRegisteredQueries

    /// **The measured baseline, 2026-08-22, tree at b259f3d.** Derived counts are asserted against
    /// this, and this is the only place the headline numbers appear. Flipping a verdict means
    /// updating exactly one tuple here plus that row.
    static let measuredBaseline = (zeroResults: 13, wrongTopOne: 27, defensible: 17)

    /// §34's 11 named zero-result queries, verbatim. Seven are natural-phrasing failures (there is no
    /// stopword list on the search path, so `of` is a hard AND term), three are brand-index failures
    /// (`brand_source` is in neither the FTS table nor `Index.searchable`), one is a typo (no
    /// edit-distance fallback anywhere in the pipeline).
    static let reportNamedZeroResultQueries: [FoodSearchCorpusCase] = [
        FoodSearchCorpusCase("bowl of oatmeal", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("two scrambled eggs", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("glass of milk", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("handful of almonds", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("piece of chicken", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("bowl of cereal", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("plate of pasta", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("costco cheese pizza slice", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("kirkland protein bar", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("whole foods rotisserie chicken", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("chiken breast", .reportNamedZeroResult, .zeroResults)
    ]

    /// §8's 15 named wrong-top-1 queries. `expectedTopName` is the WRONG row the pipeline returns
    /// today — several names are longer than §8's prose renderings, which abbreviate; the strings here
    /// are the catalog's, character for character (the Texas Toast row really is stored truncated at
    /// 120 characters).
    static let reportNamedWrongTopOneQueries: [FoodSearchCorpusCase] = [
        FoodSearchCorpusCase("apple", .reportNamedWrongTopOne, .wrongTopOne, "Apple salad with dressing", 808),
        FoodSearchCorpusCase("brown rice", .reportNamedWrongTopOne, .wrongTopOne, "Snacks, brown rice chips", 369),
        FoodSearchCorpusCase("cheddar cheese", .reportNamedWrongTopOne, .wrongTopOne,
                             "Sausage, pork and beef, with cheddar cheese, smoked", 366),
        FoodSearchCorpusCase("cheese pizza", .reportNamedWrongTopOne, .wrongTopOne, "Calzone, with cheese, meatless", 58),
        FoodSearchCorpusCase("beef tacos", .reportNamedWrongTopOne, .wrongTopOne, "Burrito, beef, cheese", 59),
        FoodSearchCorpusCase("pho", .reportNamedWrongTopOne, .wrongTopOne,
                             "Gelatin desserts, dry mix, reduced calorie, with aspartame, added phosphorus, potassium, sodium, vitamin C", 238),
        FoodSearchCorpusCase("mac and cheese", .reportNamedWrongTopOne, .wrongTopOne, "Macaroni or pasta salad with cheese", 58),
        FoodSearchCorpusCase("chicken noodle soup", .reportNamedWrongTopOne, .wrongTopOne, "Ramen bowl with chicken", 60),
        FoodSearchCorpusCase("low fat greek yogurt", .reportNamedWrongTopOne, .wrongTopOne, "Low-Fat Greek Yogurt, Guacamole", 989),
        FoodSearchCorpusCase("chick fil a sandwich", .reportNamedWrongTopOne, .wrongTopOne,
                             "Banquet Breakfast Chicken Sandwich, 3.36 Oz", 58),
        FoodSearchCorpusCase("chipotle chicken bowl", .reportNamedWrongTopOne, .wrongTopOne, "Lean Chipotle Chicken Bowl, Spicy", 429),
        FoodSearchCorpusCase("slice of toast", .reportNamedWrongTopOne, .wrongTopOne,
                             "5 Cheese Authentic Hearth Baked Texas Toast Thick Sliced Bread With Garlic Spread Topped With A Blend Of Mozzarella, Rom", 107),
        FoodSearchCorpusCase("cup of coffee", .reportNamedWrongTopOne, .wrongTopOne,
                             "My Grandma'S Of New England, Cape Cod Cranberry Coffee Cake", 115),
        FoodSearchCorpusCase("tomatoes", .reportNamedWrongTopOne, .wrongTopOne, "Pork with chili and tomatoes", 308),
        FoodSearchCorpusCase("potatoes", .reportNamedWrongTopOne, .wrongTopOne, "Beef stew with potatoes, Puerto Rican style", 306)
    ]

    /// The 31 pre-registered queries — chosen by shape, then measured. Verdicts are whatever the
    /// pipeline actually does, including the eleven that turned out to fail.
    ///
    /// Two findings worth reading off this table directly. `broccoli` returns *Broccoli slaw salad*
    /// (survey, **809**) while *Broccoli, raw* scores **810** and ranks BELOW it — the score is higher
    /// and loses anyway, because data type is the higher sort key (§7). And `chickpeas` returns the
    /// **dry** row (21/60/6 → 378 kcal/100 g) rather than *…mature seeds, cooked, boiled, without
    /// salt* (9/27/3 → 171 kcal/100 g): logging 100 g of chickpeas overstates by **2.2×**, which is a
    /// worse outcome than a visibly absurd hit because the name looks right.
    static let preRegisteredQueries: [FoodSearchCorpusCase] = [
        // Shape A — single-token whole food (10). `oatmeal` and `almonds` are the bare forms of two
        // §26-1.6 predictions (`bowl of oatmeal`, `handful of almonds`), included for that mechanism.
        FoodSearchCorpusCase("banana", .singleTokenWholeFood, .defensible, "Bananas, raw", 750),
        FoodSearchCorpusCase("salmon", .singleTokenWholeFood, .wrongTopOne, "Salmon nuggets, breaded, frozen, heated", 807),
        FoodSearchCorpusCase("broccoli", .singleTokenWholeFood, .wrongTopOne, "Broccoli slaw salad", 809),
        FoodSearchCorpusCase("avocado", .singleTokenWholeFood, .wrongTopOne, "Sushi roll, avocado", 309),
        FoodSearchCorpusCase("spinach", .singleTokenWholeFood, .defensible, "Spinach, baby", 810),
        FoodSearchCorpusCase("spaghetti", .singleTokenWholeFood, .wrongTopOne, "Spaghetti squash, cooked", 809),
        FoodSearchCorpusCase("quinoa", .singleTokenWholeFood, .defensible, "Quinoa, cooked", 810),
        FoodSearchCorpusCase("chickpeas", .singleTokenWholeFood, .wrongTopOne, "Chickpeas, (garbanzo beans, bengal gram), dry", 807),
        FoodSearchCorpusCase("oatmeal", .singleTokenWholeFood, .defensible, "Oatmeal, NFS", 810),
        FoodSearchCorpusCase("almonds", .singleTokenWholeFood, .defensible, "Nuts, almonds", 310),

        // Shape B — modifier + generic food (8).
        FoodSearchCorpusCase("white rice", .modifierPlusFood, .wrongTopOne,
                             "Crackers, gluten-free, multigrain and vegetable, made with corn starch and white rice flour", 231),
        FoodSearchCorpusCase("whole milk", .modifierPlusFood, .wrongTopOne, "Cheese, ricotta, whole milk", 369),
        FoodSearchCorpusCase("peanut butter", .modifierPlusFood, .wrongTopOne, "Peanut butter and jelly sandwich, NFS", 868),
        FoodSearchCorpusCase("sweet potato", .modifierPlusFood, .wrongTopOne, "Sweet potato leaves, raw", 869),
        FoodSearchCorpusCase("olive oil", .modifierPlusFood, .wrongTopOne, "Mayonnaise, reduced fat, with olive oil", 367),
        FoodSearchCorpusCase("greek yogurt", .modifierPlusFood, .defensible, "Yogurt, Greek, plain, lowfat", 119),
        FoodSearchCorpusCase("cottage cheese", .modifierPlusFood, .defensible, "Cottage cheese, full fat, large or small curd", 867),
        FoodSearchCorpusCase("orange juice", .modifierPlusFood, .defensible, "Orange juice, canned, unsweetened", 868),

        // Shape C — prepared / composite dish (7). `grilled salmon fillet` was pre-registered blind and
        // turned out to be a THIRTEENTH zero-result query, one §34 never named.
        FoodSearchCorpusCase("grilled cheese", .preparedDish, .defensible, "Grilled cheese sandwich, NFS", 1019),
        FoodSearchCorpusCase("caesar salad", .preparedDish, .defensible, "Caesar salad, with romaine, no dressing", 867),
        FoodSearchCorpusCase("pepperoni pizza", .preparedDish, .defensible, "Pizza with pepperoni, from frozen, medium crust", 117),
        FoodSearchCorpusCase("turkey sandwich", .preparedDish, .defensible, "Turkey sandwich or sub, restaurant", 868),
        FoodSearchCorpusCase("chicken burrito bowl", .preparedDish, .defensible, "Burrito bowl, chicken", 180),
        FoodSearchCorpusCase("grilled salmon fillet", .preparedDish, .zeroResults),
        FoodSearchCorpusCase("whole wheat toast", .preparedDish, .defensible, "Bread, whole-wheat, commercially prepared, toasted", 117),

        // Shape D — preparation-qualified (3).
        FoodSearchCorpusCase("hard boiled egg", .preparationQualified, .defensible, "Egg, whole, cooked, hard-boiled", 179),
        FoodSearchCorpusCase("scrambled eggs", .preparationQualified, .defensible, "Egg omelet or scrambled egg, made with butter", 57),
        FoodSearchCorpusCase("grilled chicken", .preparationQualified, .wrongTopOne,
                             "McDONALD'S, Bacon Ranch Salad with Grilled Chicken", 516),

        // Shape E — branded / product name (3). `chobani greek yogurt` returns an APRICOT row while
        // plain Chobani rows exist at 3 g carbs — a silent flavour substitution, so: wrong.
        // `quest protein bar` is a FOURTEENTH zero-result query, the brand-index failure again.
        FoodSearchCorpusCase("string cheese", .brandedProduct, .defensible, "String Cheese", 1870),
        FoodSearchCorpusCase("chobani greek yogurt", .brandedProduct, .wrongTopOne, "Yogurt, Greek, 2% fat, apricot, CHOBANI", 179),
        FoodSearchCorpusCase("quest protein bar", .brandedProduct, .zeroResults)
    ]

    // MARK: - The corpus replay

    /// Replays all 57 queries through `FoodCatalog.bundled()` and pins the top-1 name AND score.
    ///
    /// The score is pinned as well as the name because §29's coupling shows up as a score change
    /// before it shows up as a reordering: a fix that moves `Calzone, with cheese, meatless` from 58
    /// to something else has changed the comparator even on queries whose visible answer is unmoved.
    @Test func corpusReplaysToThePinnedBaseline() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded — this suite must never pass vacuously")
        for corpusCase in Self.corpus {
            let ranked = catalog.scoredResults(for: corpusCase.query, limit: 1)
            // Scalars are extracted before the expectation so a failure prints the query and the
            // offending value, not a multi-kilobyte FoodItem dump.
            let actualName = ranked.first?.item.name
            let actualScore = ranked.first?.score
            let rowCount = ranked.count
            guard let expectedName = corpusCase.expectedTopName else {
                #expect(rowCount == 0, "\"\(corpusCase.query)\" is pinned zero-result but returned \(rowCount) row(s), top: \(actualName ?? "")")
                continue
            }
            #expect(actualName == expectedName, "top-1 moved for \"\(corpusCase.query)\"")
            #expect(actualScore == corpusCase.expectedTopScore, "score moved for \"\(corpusCase.query)\"")
        }
    }

    /// Asserts the baseline as a MEASURED fact rather than an inherited one.
    ///
    /// Every count is derived from the arrays — there is no free-standing literal to drift — and the
    /// machine-decidable half is checked live: the set of queries that actually return nothing must
    /// be exactly the set marked `.zeroResults`. "Wrong top-1" is a judgement about the food a person
    /// meant, so it is pinned as a recorded verdict, not inferred.
    @Test func corpusBaselineCountsAreMeasuredNotInherited() throws {
        let counts = Self.verdictCounts(in: Self.corpus)
        #expect(Self.corpus.count == 57, "the corpus size is held at 57 for continuity with §34")
        #expect(counts.zeroResults == Self.measuredBaseline.zeroResults)
        #expect(counts.wrongTopOne == Self.measuredBaseline.wrongTopOne)
        #expect(counts.defensible == Self.measuredBaseline.defensible)
        #expect(counts.zeroResults + counts.wrongTopOne + counts.defensible == Self.corpus.count)

        // The research's own named lists stay intact at the sizes §8 reports.
        #expect(Self.reportNamedZeroResultQueries.count == 11)
        #expect(Self.reportNamedWrongTopOneQueries.count == 15)
        #expect(Self.reportNamedZeroResultQueries.allSatisfy { $0.verdict == .zeroResults })
        #expect(Self.reportNamedWrongTopOneQueries.allSatisfy { $0.verdict == .wrongTopOne })
        #expect(Self.preRegisteredQueries.count == Self.corpus.count - 26)

        // Uniqueness on BOTH the raw text and the folded form the pipeline actually keys on: two rows
        // differing only in case or punctuation would be one measurement pinned twice.
        #expect(Set(Self.corpus.map(\.query)).count == Self.corpus.count, "corpus queries must be unique")
        #expect(Set(Self.corpus.map { FoodItemSearch.normalized($0.query) }).count == Self.corpus.count,
                "corpus queries must be unique after normalization")

        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        let empties = Self.corpus.filter { catalog.results(for: $0.query, limit: 1).isEmpty }
        #expect(empties.count == counts.zeroResults, "measured zero-result count: \(empties.count)")
        #expect(Set(empties.map(\.query)) == Set(Self.corpus.filter { $0.verdict == .zeroResults }.map(\.query)))
    }

    // MARK: - §9's named measurements

    /// The row-level pins for the queries the research names outside the corpus — one table, covered
    /// by the dump, so the interpretive tests below never restate a name or a score.
    ///
    /// `pizza dough crust` is the literal search string at `DishTemplates.json:291` that fix 1.3 will
    /// change; pinning today's answer is what proves 1.3 moved the template and not the scorer.
    /// `black coffee` is §10's single measured top-1 change out of 30 queries when the 364,457-row
    /// branded ODR catalog is attached, so this pins the base-only answer.
    static let namedRankingPins: [FoodSearchRankedPin] = [
        FoodSearchRankedPin("protein bar", "§9(a) exact-name branded rows lose to a generic srLegacy row", [
            FoodSearchRankedRow("Formulated Bar, SOUTH BEACH protein bar", 367, "srLegacy"),
            FoodSearchRankedRow("Formulated bar, MARS SNACKFOOD US, SNICKERS MARATHON Protein Performance Bar, Caramel Nut Rush", 110, "srLegacy"),
            FoodSearchRankedRow("Protein Bar", 1870, "branded"),
            FoodSearchRankedRow("Protein Bar", 1870, "branded"),
            FoodSearchRankedRow("Protein Bar, Almond Honey", 869, "branded"),
            FoodSearchRankedRow("Protein Bar, Blueberry", 869, "branded")
        ]),
        FoodSearchRankedPin("cheerios", "§9(a) again: srLegacy 306 outranks four branded rows at 808-810", [
            FoodSearchRankedRow("Cereals ready-to-eat, GENERAL MILLS, CHEERIOS", 306, "srLegacy"),
            FoodSearchRankedRow("Cheerios Cereal", 810, "branded"),
            FoodSearchRankedRow("Cheerios Cereal", 810, "branded"),
            FoodSearchRankedRow("Cheerios Cereal", 810, "branded"),
            FoodSearchRankedRow("Cheerios Cereal Bowlpak", 809, "branded"),
            FoodSearchRankedRow("Cheerios Breakfast Cereal Cup", 808, "branded")
        ]),
        FoodSearchRankedPin("chili", "§9(b) baseline: all survey. Ranks 2-3 tie at 809 and are ordered by name", [
            FoodSearchRankedRow("Chili, NFS", 810, "survey"),
            FoodSearchRankedRow("Chili hot dog, no bun", 809, "survey"),
            FoodSearchRankedRow("Chili with chicken", 809, "survey"),
            FoodSearchRankedRow("Chili hot dog sandwich, on wheat bun", 807, "survey"),
            FoodSearchRankedRow("Chili with meat, from restaurant", 807, "survey"),
            FoodSearchRankedRow("Chili hot dog sandwich, on wheat bread", 806, "survey")
        ]),
        FoodSearchRankedPin("chilis", "§9(b) flipped: one trailing `s` makes it a brand query. Ranks 2-6 all tie at 0", [
            FoodSearchRankedRow("5 Chilis Salsa", 309, "branded"),
            FoodSearchRankedRow("Beans & Franks", 0, "branded"),
            FoodSearchRankedRow("Beans & Franks", 0, "branded"),
            FoodSearchRankedRow("Beans & Wieners", 0, "branded"),
            FoodSearchRankedRow("Beef Chili", 0, "branded"),
            FoodSearchRankedRow("Beef Goulash", 0, "branded")
        ]),
        FoodSearchRankedPin("cheese pizza", "§9(c) three negative rows outrank an srLegacy row scoring 368", [
            FoodSearchRankedRow("Calzone, with cheese, meatless", 58, "survey"),
            FoodSearchRankedRow("Calzone, with meat and cheese", 58, "survey"),
            FoodSearchRankedRow("White pizza, cheese, thick crust", -12, "survey"),
            FoodSearchRankedRow("White pizza, cheese, thin crust", -12, "survey"),
            FoodSearchRankedRow("White pizza, cheese, with meat, thick crust", -13, "survey"),
            FoodSearchRankedRow("Annie's Three Cheese Pizza Poppers", 368, "srLegacy")
        ]),
        FoodSearchRankedPin("cheese pizza slice", "§29's baseline — the row naive stopwording (1.6) would destroy", [
            FoodSearchRankedRow("Sliced Pizza, Cheese", 120, "branded"),
            FoodSearchRankedRow("Pizza, Sliced Tomato & 5 Cheese", 119, "branded"),
            FoodSearchRankedRow("Bellissimo Margherita Mozzarella Cheese, Sauce, Tomatoes, Sliced Mozzarella Cheese, Fontina Cheese, Roasted Garlic And B", 48, "branded"),
            FoodSearchRankedRow("Bold & Spicy Quarter Cut And Thin Sliced Uncured Pepperoni, Diced Pepperoni, Gooey Mozzarella Cheese, And Savory Tomato ", 48, "branded"),
            FoodSearchRankedRow("7 Cheese Blend Of Seven Cheeses Including Provolone, Shredded Mozzarella, Fresh Sliced Mozzarella, Fontina, White Chedda", -82, "branded"),
            FoodSearchRankedRow("Bessie's Revenge Wisconsin Whole Milk Fresh Mozzarella Slices, Shredded Mozzarella Cheese, Parmesan, Romano & White Ched", -82, "branded")
        ]),
        FoodSearchRankedPin("mozzarella cheese", "§26 fix 1.2's headline: the bind that produced the wrong meal, at 58", [
            FoodSearchRankedRow("Mozzarella sticks, breaded, baked, or fried", 58, "survey"),
            FoodSearchRankedRow("DENNY'S, mozzarella cheese sticks", 369, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, nonfat", 120, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, low sodium", 119, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, part skim milk", 119, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, whole milk", 119, "srLegacy")
        ]),
        FoodSearchRankedPin("pizza dough crust", "§26 fix 1.3: the DishTemplates.json:291 search string, unchanged by any ranking variant", [
            FoodSearchRankedRow("Pillsbury Pizza Dough Thin Crust", 179, "branded"),
            FoodSearchRankedRow("Pillsbury Pizza Dough Thin Crust", 179, "branded"),
            FoodSearchRankedRow("Gluten Free Dough, Thin Crust Pizza", 178, "branded"),
            FoodSearchRankedRow("Gluten Free Pizza Crust Dough Mix", 178, "branded"),
            FoodSearchRankedRow("Pillsbury Premade Refrigerated Classic Pizza Crust Canned Dough", 175, "branded"),
            FoodSearchRankedRow("Bonici Readi Rise Frozen Pizza Crust Dough Self Rising 7 In 36/6 Oz", 174, "branded")
        ]),
        FoodSearchRankedPin("black coffee", "§10's one top-1 that the branded ODR changes — this is the base-only answer", [
            FoodSearchRankedRow("Califia, Cold Brew All Black Coffee", 368, "branded"),
            FoodSearchRankedRow("Califia, Cold Brew All Black Coffee", 368, "branded"),
            FoodSearchRankedRow("100% Pure Soluble Black Coffee Sachets", 367, "branded"),
            FoodSearchRankedRow("100% PURE SOLUBLE BLACK COFFEE SACHETS", 367, "branded"),
            FoodSearchRankedRow("Black Organic Smooth Black Coffee, Black", 367, "branded"),
            FoodSearchRankedRow("Califia, Cold Brew Black Coffee, Black Mocha", 367, "branded")
        ])
    ]

    /// Replays every named pin and asserts the top-6 rows exactly.
    @Test func namedRankingPinsAreUnchanged() throws {
        for pin in Self.namedRankingPins {
            let live = try Self.rankedRows(for: pin.query)
            #expect(live.count == pin.rows.count, "result count changed for \"\(pin.query)\"")
            for (rank, expected) in pin.rows.enumerated() where rank < live.count {
                #expect(live[rank] == expected, "rank \(rank + 1) moved for \"\(pin.query)\" (\(pin.note))")
            }
        }
    }

    /// §9(a) as a MECHANISM, computed live: rank 1 is a lower-scoring row from a higher data-type
    /// tier, and a strictly higher-scoring row sits below it. No names or scores are restated —
    /// ``namedRankingPins`` owns those.
    @Test func exactNameMatchesLoseToGenericRows() throws {
        for query in ["protein bar", "cheerios"] {
            let live = try Self.rankedRows(for: query)
            let top = try #require(live.first, "\"\(query)\" must return rows")
            let better = live.dropFirst().filter { $0.score > top.score }
            #expect(!better.isEmpty, "\"\(query)\": expected a strictly higher-scoring row ranked below rank 1")
            #expect(better.allSatisfy { $0.dataType != top.dataType },
                    "\"\(query)\": the inversion is data-type-driven, so the better rows must sit in a lower tier")
        }
    }

    /// §9(b) as a mechanism: a single trailing `s` moves the query into the brand lexicon, which flips
    /// the whole result set from one data-type tier to another and collapses the scores.
    ///
    /// Two details of §9's prose did not reproduce and ``namedRankingPins`` carries the measurement
    /// instead: `chili`'s rank 2 is *Chili hot dog, no bun*, not *Chili with chicken* (both 809, and
    /// the tie is broken by name); and `chilis` is followed by FIVE zero-scoring rows, not three.
    @Test func trailingSFlipsTheQueryIntoRestaurantMode() throws {
        #expect(FoodBrandLexicon.queryContainsBrandToken("chilis"))
        #expect(!FoodBrandLexicon.queryContainsBrandToken("chili"))
        // The converse §9(b) failure: the apostrophe form never reaches the lexicon entry at all.
        #expect(!FoodBrandLexicon.queryContainsBrandToken("mcdonald's fries"))

        let chili = try Self.rankedRows(for: "chili")
        let chilis = try Self.rankedRows(for: "chilis")
        let chiliTiers = Set(chili.map(\.dataType))
        let chilisTiers = Set(chilis.map(\.dataType))
        #expect(chiliTiers.count == 1 && chilisTiers.count == 1, "each result set should sit in one tier")
        #expect(chiliTiers != chilisTiers, "the trailing `s` must flip the tier")
        let chiliTop = try #require(chili.first?.score)
        let chilisTop = try #require(chilis.first?.score)
        #expect(chilisTop < chiliTop, "the brand flip also collapses the top score")
        #expect(chilis.dropFirst().contains { $0.score == 0 }, "rows scoring 0 are presented with no distinction")
    }

    /// §9(c) as a mechanism: there is no score floor on the search path, so negatively-scoring rows
    /// are presented in the top-6 and a strictly better row can rank below them. `minimumBindScore = 1`
    /// is a no-op (any single name-token hit scores +60) and guards only the bind paths, never search.
    /// This is fix 1.8's instrument.
    @Test func negativeScoringRowsAreShownInTheTopSix() throws {
        #expect(FoodItemSearch.minimumBindScore == 1)
        #expect(FoodItemSearch.confidentBindScore == 250)
        #expect(FoodItemSearch.minimumQueryLength == 3)

        let pizza = try Self.rankedRows(for: "cheese pizza")
        let negatives = pizza.filter { $0.score < 0 }
        #expect(!negatives.isEmpty, "`cheese pizza` should still present negative-scoring rows")
        let lastNegativeRank = try #require(pizza.lastIndex(where: { $0.score < 0 }))
        #expect(pizza.dropFirst(lastNegativeRank + 1).contains { $0.score > 0 },
                "a positively-scoring row should still rank below the negative ones")

        // §29's baseline: with "slice" present only one tier survives the AND gate, so the top-1 is
        // defensible today. Stopwords (1.6) landing ALONE is what turns this into the calzone.
        let slice = try Self.rankedRows(for: "cheese pizza slice")
        #expect(Set(slice.map(\.dataType)).count == 1)
        #expect(slice.contains { $0.score < 0 }, "`cheese pizza slice` still shows negative rows in its top-6")
    }

    /// §26 fix 1.2's headline number: the pizza template's `mozzarella cheese` component binds far
    /// below `confidentBindScore` while an exact-name `Mozzarella Cheese` row sits in the same file.
    @Test func mozzarellaBindScoresFarBelowTheConfidenceFloor() throws {
        let ranked = try Self.rankedRows(for: "mozzarella cheese")
        let topScore = try #require(ranked.first?.score)
        #expect(topScore < FoodItemSearch.confidentBindScore, "the bind that produced the wrong meal is not 'confident'")
        #expect(topScore >= FoodItemSearch.minimumBindScore, "…yet it clears the floor that is supposed to reject it")
        #expect(ranked.dropFirst().contains { $0.score > FoodItemSearch.confidentBindScore },
                "a confident-scoring row exists — it just ranks below")

        // The right answer is present and reachable by exact name — §9's counterfactual target.
        let source = try #require(SQLiteBundledFoodSource(), "shipped catalog must open")
        try #require(source.count == Self.shippedRowCount)
        #expect(source.exactMatch(normalizedName: "mozzarella cheese")?.name == "Mozzarella Cheese")
        #expect(source.exactMatch(normalizedName: "cheese pizza")?.name == "Cheese Pizza")
    }

    // MARK: - The resolver surface

    /// The RESOLVER bank: `FoodCatalog.candidates(for:limit:)`, the pool `MealResolutionService` and
    /// the quick-log path actually draw from. **This is a different ranking from search**, and pinning
    /// it is the point: `FoodSelectionCandidateBuilder.searchPhrases` splits the description into
    /// phrases (so stopwords never block it the way they block the search gate) and
    /// `PreparedDishHeuristic.demotingDishes` then REORDERS the pool, which `results(for:)` never does.
    ///
    /// The disagreements this pins are substantial, and every one is a place a "green corpus" would
    /// have hidden a resolver regression:
    /// * five queries return NOTHING from search but a full pool here — `bowl of oatmeal`,
    ///   `two scrambled eggs`, `chiken breast`, `costco cheese pizza slice`, `quest protein bar` —
    ///   and for `two scrambled eggs` and `grilled salmon fillet` the resolver's answer is the RIGHT
    ///   food while search shows an empty list;
    /// * `peanut butter` resolves to *Egg omelet or scrambled egg, made with butter*, because the
    ///   phrase splitter searches `butter` on its own and the dish demotion then promotes it;
    /// * `chicken burrito bowl` resolves to *Ramen bowl, NFS* though search finds *Burrito bowl,
    ///   chicken*;
    /// * `bowl of oatmeal` resolves to a branded sugary breakfast bowl.
    static let resolverBank: [FoodResolverCase] = [
        FoodResolverCase("protein bar", 12, "Formulated Bar, SOUTH BEACH protein bar"),
        FoodResolverCase("cheerios", 4, "Cereals ready-to-eat, GENERAL MILLS, CHEERIOS"),
        FoodResolverCase("chili", 4, "Chili, NFS"),
        FoodResolverCase("chilis", 4, "5 Chilis Salsa"),
        FoodResolverCase("cheese pizza", 12, "Calzone, with cheese, meatless"),
        FoodResolverCase("cheese pizza slice", 18, "Sliced Pizza, Cheese"),
        FoodResolverCase("mozzarella cheese", 9, "Mozzarella sticks, breaded, baked, or fried"),
        FoodResolverCase("pizza dough crust", 18, "Pillsbury Pizza Dough Thin Crust"),
        FoodResolverCase("black coffee", 12, "Califia, Cold Brew All Black Coffee"),
        FoodResolverCase("costco cheese pizza slice", 18, "Sliced Pizza, Cheese"),
        FoodResolverCase("bowl of oatmeal", 9,
                         "Organic Apples & Blueberries Oatmeal + Sprouted Quinoa Super Morning Bowl, Organic Apples & Blueberries"),
        FoodResolverCase("two scrambled eggs", 13, "Egg omelet or scrambled egg, made with butter"),
        FoodResolverCase("chiken breast", 6, "Chicken breast, stewed, skin eaten"),
        FoodResolverCase("apple", 4, "Apple salad with dressing"),
        FoodResolverCase("brown rice", 11, "Snacks, brown rice chips"),
        FoodResolverCase("mac and cheese", 10, "Macaroni or pasta salad with cheese"),
        FoodResolverCase("chicken noodle soup", 18, "Ramen bowl with chicken"),
        FoodResolverCase("beef tacos", 11, "Burrito, beef, cheese"),
        FoodResolverCase("low fat greek yogurt", 18, "Yogurt, Greek, 2% fat, apricot, CHOBANI"),
        FoodResolverCase("chipotle chicken bowl", 18, "Lean Chipotle Chicken Bowl, Spicy"),
        FoodResolverCase("slice of toast", 12, "Thick Slice Swirl French Toast Bread, French Toast"),
        FoodResolverCase("tomatoes", 4, "Pork with chili and tomatoes"),
        FoodResolverCase("white rice", 12,
                         "Crackers, gluten-free, multigrain and vegetable, made with corn starch and white rice flour"),
        FoodResolverCase("peanut butter", 5, "Egg omelet or scrambled egg, made with butter"),
        FoodResolverCase("grilled chicken", 12, "McDONALD'S, Bacon Ranch Salad with Grilled Chicken"),
        FoodResolverCase("chicken burrito bowl", 16, "Ramen bowl, NFS"),
        FoodResolverCase("grilled salmon fillet", 18, "Grilled Salmon"),
        FoodResolverCase("whole wheat toast", 18, "Bread, whole-wheat, commercially prepared, toasted"),
        FoodResolverCase("quest protein bar", 14, "Formulated Bar, SOUTH BEACH protein bar"),
        FoodResolverCase("chickpeas", 4, "Chickpeas, (garbanzo beans, bengal gram), dry")
    ]

    /// Pins the resolver pool's size and top candidate for every bank entry.
    @Test func resolverCandidateSurfaceIsUnchanged() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        for resolverCase in Self.resolverBank {
            let pool = catalog.candidates(for: resolverCase.query, limit: 18)
            let actualCount = pool.count
            let actualTop = pool.first?.foodItem.name
            #expect(actualCount == resolverCase.expectedCount, "resolver pool size moved for \"\(resolverCase.query)\"")
            #expect(actualTop == resolverCase.expectedTopName, "resolver top candidate moved for \"\(resolverCase.query)\"")
        }
    }

    /// The two surfaces genuinely disagree today, and that disagreement is itself pinned: if a fix
    /// silently unified them this test goes red and someone has to decide whether that was intended.
    @Test func searchAndResolverSurfacesStillDisagree() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        let searchIsEmptyButResolverIsNot = ["bowl of oatmeal", "two scrambled eggs", "chiken breast",
                                            "costco cheese pizza slice", "quest protein bar", "grilled salmon fillet"]
        for query in searchIsEmptyButResolverIsNot {
            let searchCount = catalog.results(for: query, limit: 6).count
            let resolverCount = catalog.candidates(for: query, limit: 18).count
            #expect(searchCount == 0, "\"\(query)\" should still return nothing from search")
            #expect(resolverCount > 0, "\"\(query)\" should still return a resolver pool")
        }
        for query in ["peanut butter", "chicken burrito bowl", "slice of toast", "low fat greek yogurt"] {
            let searchTop = catalog.results(for: query, limit: 1).first?.name
            let resolverTop = catalog.candidates(for: query, limit: 18).first?.foodItem.name
            #expect(searchTop != resolverTop, "\"\(query)\": the two surfaces should still pick different foods")
        }
    }

    // MARK: - Catalog composition (the vintage proxy)

    /// Per-source composition of the shipped catalog (§35 Appendix B).
    ///
    /// **This is a proxy, and deliberately labelled one.** `FoodCatalog.sqlite` carries NO vintage
    /// metadata: no release-date column, no per-source provenance table, nothing but
    /// `PRAGMA user_version`. §27 asks for "a recorded source vintage per row" precisely because it
    /// does not exist yet. Until it does, the strongest real signal that a regeneration (item 13 —
    /// FNDDS 2021-2023 + the Ingredients workbook + `brand_source` in FTS) has changed what is in the
    /// box is the composition itself: the row counts per `data_type`, the 100%-`usda` source, the
    /// barcode and portion coverage, and the schema version. Any of those moving means the file was
    /// rebuilt, and this suite's whole baseline must be re-measured before it can be trusted again.
    static let compositionExpectations: [(sql: String, expected: Int)] = [
        ("SELECT COUNT(*) FROM food", 118_317),
        ("SELECT COUNT(*) FROM food WHERE data_type = 'branded'", 109_163),
        ("SELECT COUNT(*) FROM food WHERE data_type = 'srLegacy'", 8_888),
        ("SELECT COUNT(*) FROM food WHERE data_type = 'survey'", 202),
        ("SELECT COUNT(*) FROM food WHERE data_type = 'restaurant'", 64),
        ("SELECT COUNT(*) FROM food WHERE data_type = 'foundation'", 0),
        ("SELECT COUNT(*) FROM food WHERE source = 'usda'", 118_317),
        ("SELECT COUNT(*) FROM food WHERE gtin_upc IS NOT NULL AND gtin_upc <> ''", 50_000),
        ("SELECT COUNT(*) FROM food WHERE serving_description IS NOT NULL AND serving_description <> ''", 0),
        ("SELECT COUNT(*) FROM food WHERE portions IS NOT NULL AND portions NOT IN ('', '[]')", 7_985),
        ("SELECT COUNT(DISTINCT brand_source) FROM food WHERE data_type = 'branded' AND brand_source IS NOT NULL AND brand_source <> ''", 14_392),
        ("SELECT COUNT(DISTINCT category) FROM food", 331),
        ("PRAGMA user_version", 2)
    ]

    /// Pins the shipped catalog's composition, and ties the repo file to the bundled resource so a
    /// stale bundled copy cannot let the corpus be measured against a different database.
    @Test func shippedCatalogCompositionIsUnchanged() throws {
        let probe = try #require(FoodCatalogFileProbe(url: FoodCatalogFileProbe.shippedCatalogURL),
                                 "shipped FoodCatalog.sqlite must be readable at \(FoodCatalogFileProbe.shippedCatalogURL.path)")
        for expectation in Self.compositionExpectations {
            #expect(probe.scalar(expectation.sql) == expectation.expected, "composition changed: \(expectation.sql)")
        }
        // `foundation` is the top non-brand tier and has zero rows — the tier is unreachable (§7).
        // Same file, both paths: the repo copy and the resource the FoodCatalog target bundles.
        let bundled = try #require(SQLiteBundledFoodSource(), "the FoodCatalog resource bundle must carry the database")
        #expect(bundled.count == probe.scalar("SELECT COUNT(*) FROM food"))
        #expect(FoodCatalog.bundled().bundledCount == Self.shippedRowCount)
    }

    /// §8's retrieval-layer table: 22 raw FTS5 MATCH expressions and their row counts.
    ///
    /// Sits one layer below the corpus — it pins what the *index* can reach, independent of ranking,
    /// which is what fixes 1.6 (stopwords, which rewrites the MATCH expression) and 2.3 (indexing
    /// `brand_source` as a fourth FTS column) actually move. All 22 reproduced §8 exactly, including
    /// its own correction that `dominos*` matches nothing while `domino*` matches 13.
    static let ftsRowCounts: [(match: String, expected: Int)] = [
        ("cheese* AND pizza*", 533),
        ("cheese* AND pizza* AND slice*", 6),
        ("costco* AND cheese* AND pizza* AND slice*", 0),
        ("costco*", 0),
        ("bowl* AND of* AND oatmeal*", 0),
        ("oatmeal*", 690),
        ("of*", 1_551),
        ("(tomatoes* OR tomatoe*)", 951),
        ("tomato*", 2_143),
        ("(potatoes* OR potatoe*)", 1_211),
        ("potato*", 3_090),
        ("chiken*", 2),
        ("chicken*", 5_270),
        ("yoghurt*", 17),
        ("yogurt*", 3_876),
        ("che*", 13_958),
        ("pizza*", 2_686),
        ("(chilis* OR chili*)", 1_335),
        ("subway*", 11),
        ("kfc*", 22),
        ("domino*", 13),
        ("dominos*", 0)
    ]

    /// Pins the FTS gate's reach for §8's 22 expressions.
    @Test func ftsGateRowCountsAreUnchanged() throws {
        let probe = try #require(FoodCatalogFileProbe(url: FoodCatalogFileProbe.shippedCatalogURL))
        try #require(probe.scalar("SELECT COUNT(*) FROM food") == Self.shippedRowCount)
        for expectation in Self.ftsRowCounts {
            #expect(probe.ftsMatchCount(expectation.match) == expectation.expected, "FTS reach changed: \(expectation.match)")
        }
    }

    /// The brand-index failure of §8, pinned from both sides: the retailer rows are IN the file and
    /// are NOT reachable, because `brand_source` is indexed nowhere. Fix 2.3's instrument — when it
    /// lands, the zero-result queries flip and these counts become searchable hits.
    @Test func brandSourceRowsExistButAreUnsearchable() throws {
        let probe = try #require(FoodCatalogFileProbe(url: FoodCatalogFileProbe.shippedCatalogURL))
        #expect(probe.scalar("SELECT COUNT(*) FROM food WHERE brand_source LIKE '%costco%'") == 31)
        #expect(probe.scalar("SELECT COUNT(*) FROM food WHERE brand_source LIKE '%whole foods%'") == 679)
        #expect(probe.scalar("SELECT COUNT(*) FROM food WHERE brand_source LIKE '%kirkland%'") == 2)
        #expect(probe.ftsMatchCount("costco*") == 0)
        // Nuance §8's prose flattens: `kirkland*` DOES reach two rows — both carry "Kirkland
        // Signature" in the NAME, which is indexed. The query still returns nothing because the gate
        // ANDs every token and neither row is a protein bar; one of them is in fact a Costco row
        // whose only "Costco" is in the unindexed `brand_source`.
        #expect(probe.ftsMatchCount("kirkland*") == 2)
        #expect(probe.ftsMatchCount("kirkland* AND protein* AND bar*") == 0)

        // Without this guard all three assertions below would pass against the empty-catalog fallback.
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount, "shipped catalog must be loaded")
        #expect(catalog.results(for: "costco cheese pizza slice", limit: 6).isEmpty)
        #expect(catalog.results(for: "kirkland protein bar", limit: 6).isEmpty)
        #expect(catalog.results(for: "whole foods rotisserie chicken", limit: 6).isEmpty)
    }

    /// The candidate set the SHIPPED source hands the scorer, per query — the pipeline's own half of
    /// §8's table (`SQLiteBundledFoodSource.candidates`, capped at `candidateFetchLimit`). Pinned
    /// separately from the raw FTS counts so a change to the MATCH-expression builder, the cap, or
    /// the de-bias `ORDER BY` is attributable to the query side rather than to the file.
    static let sourceCandidateSetSizes: [(query: String, expected: Int)] = [
        ("cheese pizza", 533),
        ("cheese pizza slice", 6),
        ("costco cheese pizza slice", 0),
        ("bowl of oatmeal", 0),
        ("oatmeal", 690),
        ("chiken breast", 0),
        ("chicken breast", 931),
        ("mozzarella cheese", 429),
        ("tomatoes", 951),
        ("potatoes", 1_211),
        ("apple", 3_803),
        ("protein bar", 336),
        ("string cheese", 49)
    ]

    /// Pins the shipped source's candidate-set sizes.
    @Test func sourceCandidateSetSizesAreUnchanged() throws {
        let source = try #require(SQLiteBundledFoodSource(), "shipped catalog must open")
        try #require(source.count == Self.shippedRowCount)
        #expect(FoodCatalogSchema.candidateFetchLimit == 10_000)
        for expectation in Self.sourceCandidateSetSizes {
            #expect(source.candidates(forQuery: expectation.query).count == expectation.expected,
                    "candidate set changed for \"\(expectation.query)\"")
        }
    }

    // MARK: - Re-measurement

    /// Asserts the re-baselining dump is complete and round-trips, and prints it on request.
    ///
    /// The dump is the single paste that re-baselines this file after a deliberate fix: it emits one
    /// literal per corpus row, PARTITIONED by measured verdict into the three blocks the corpus is
    /// written in, with the derived counts as a comment, followed by the named ranking pins and the
    /// resolver bank in the same literal form. The assertions here make it a real test rather than a
    /// print statement: every corpus row must produce exactly one line, and every line must parse
    /// back to the row it came from — which also proves no pinned name contains a quote that would
    /// silently corrupt the paste.
    ///
    /// Print it with `TEST_RUNNER_FOOD_CORPUS_DUMP=1` (Xcode forwards the prefix; `FOOD_CORPUS_DUMP`
    /// also works):
    ///
    ///     TEST_RUNNER_FOOD_CORPUS_DUMP=1 xcodebuild test-without-building … \
    ///       -only-testing:FernletTests/FoodSearchCorpusTests
    @Test func dumpEmitsOneParseableRowPerCorpusQuery() throws {
        let lines = Self.corpus.map(Self.literal(for:))
        #expect(lines.count == Self.corpus.count, "the dump must emit exactly one line per corpus query")
        for (index, line) in lines.enumerated() {
            let parsed = Self.parse(line)
            #expect(parsed == Self.corpus[index], "line \(index + 1) did not round-trip: \(line)")
        }
        #expect(Self.corpus.allSatisfy { !$0.query.contains("\"") && !($0.expectedTopName ?? "").contains("\"") },
                "a quote in a pinned string would corrupt the paste-back format")
        Self.printDumpIfRequested(lines)
    }

    // MARK: - Helpers

    /// Verdict populations of a corpus slice, derived rather than restated.
    private static func verdictCounts(in cases: [FoodSearchCorpusCase]) -> (zeroResults: Int, wrongTopOne: Int, defensible: Int) {
        (
            zeroResults: cases.filter { $0.verdict == .zeroResults }.count,
            wrongTopOne: cases.filter { $0.verdict == .wrongTopOne }.count,
            defensible: cases.filter { $0.verdict == .defensible }.count
        )
    }

    /// The Swift literal for one corpus row — the exact text the corpus arrays above are written in.
    private static func literal(for corpusCase: FoodSearchCorpusCase) -> String {
        let head = "FoodSearchCorpusCase(\"\(corpusCase.query)\", .\(corpusCase.shape.rawValue), .\(corpusCase.verdict.rawValue)"
        guard let name = corpusCase.expectedTopName, let score = corpusCase.expectedTopScore else {
            return head + "),"
        }
        return head + ", \"\(name)\", \(score)),"
    }

    /// Parses a literal produced by ``literal(for:)`` back into a case. Splitting on the quote
    /// character is sound precisely because ``dumpEmitsOneParseableRowPerCorpusQuery()`` asserts no
    /// pinned string contains one.
    private static func parse(_ line: String) -> FoodSearchCorpusCase? {
        let parts = line.components(separatedBy: "\"")
        guard parts.count == 3 || parts.count == 5 else { return nil }
        let tokens = parts[2]
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " .)")) }
            .filter { !$0.isEmpty }
        guard tokens.count >= 2,
              let shape = FoodSearchCorpusShape(rawValue: tokens[0]),
              let verdict = FoodSearchCorpusVerdict(rawValue: tokens[1]) else { return nil }
        guard parts.count == 5 else { return FoodSearchCorpusCase(parts[1], shape, verdict) }
        let digits = parts[4].filter { $0.isNumber || $0 == "-" }
        guard let score = Int(digits) else { return nil }
        return FoodSearchCorpusCase(parts[1], shape, verdict, parts[3], score)
    }

    /// Prints the paste-ready re-baselining block when the environment asks for it.
    private static func printDumpIfRequested(_ lines: [String]) {
        let env = ProcessInfo.processInfo.environment
        guard env["FOOD_CORPUS_DUMP"] != nil || env["TEST_RUNNER_FOOD_CORPUS_DUMP"] != nil else { return }
        let counts = verdictCounts(in: corpus)
        print("// measuredBaseline = (zeroResults: \(counts.zeroResults), wrongTopOne: \(counts.wrongTopOne), defensible: \(counts.defensible))")
        for verdict in [FoodSearchCorpusVerdict.zeroResults, .wrongTopOne, .defensible] {
            print("// ── \(verdict.rawValue) ───────────────────────────────────────────────")
            for (index, line) in lines.enumerated() where corpus[index].verdict == verdict {
                print(line)
            }
        }
        print("// ── namedRankingPins ─────────────────────────────────────────────")
        for pin in namedRankingPins {
            print("FoodSearchRankedPin(\"\(pin.query)\", \"\(pin.note)\", [")
            for row in pin.rows { print("    FoodSearchRankedRow(\"\(row.name)\", \(row.score), \"\(row.dataType)\"),") }
            print("]),")
        }
        print("// ── resolverBank ─────────────────────────────────────────────────")
        for entry in resolverBank {
            let name = entry.expectedTopName.map { "\"\($0)\"" } ?? "nil"
            print("FoodResolverCase(\"\(entry.query)\", \(entry.expectedCount), \(name)),")
        }
    }

    /// The top-6 ranked rows for `query` through the shipped pipeline, flattened for pinning.
    private static func rankedRows(for query: String) throws -> [FoodSearchRankedRow] {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == shippedRowCount, "shipped catalog must be loaded")
        return catalog.scoredResults(for: query, limit: 6)
            .map { FoodSearchRankedRow($0.item.name, $0.score, $0.item.dataType.rawValue) }
    }
}
