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
// THE ORIGINAL BASELINE — 2026-08-22, tree at b259f3d — was
// **13 zero-result, 27 wrong-top-1, 17 defensible of 57**: 40 of 57 failing outright (70%), and of
// the 44 queries that returned anything, 27 (61%) returning the wrong food. That was materially
// worse than §8's ~46%, and the difference is selection, not disagreement: §8's 46% describes §8's
// corpus.
//
// THE CURRENT BASELINE — measured on the tree AFTER §26 fixes 1.6 + 1.7a + 1.8 landed as §29's one
// coupled unit, and after the adversarial review of that increment — is `measuredBaseline` below.
// Re-measure with the live dump before trusting any number here; the dump is the only thing that can
// re-baseline a behaviour change, and a GREEN run of this suite is not evidence the pins were
// re-measured, only that nothing moved since they were written.
//
// The fixes are recorded where they bite: `FoodItemSearch.searchTokens` (1.6, with the
// leading/trailing POSITION rules that keep §29's hazard from firing, and `stripsStopwords` which
// confines them to the typed-query surface), `PreparedDishHeuristic.demotingDishes(scored:forQuery:)`
// (1.7a, with the score guard that stopped it regressing `grilled cheese`), and the two-part floor —
// `FoodItemSearch.nameCarriesQuery` (name-substring carriage — NOT category, which was tried and
// measured wrong) beside `minimumBindScore` (§26's score
// floor). See `bothHalvesOfTheFloorAreLoadBearing` for why neither half alone is correct.
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

    /// **The measured baseline** for the current tree (see the file header). Derived counts are
    /// asserted against this, and this is the only place the headline numbers appear. Flipping a
    /// verdict means updating exactly one tuple here plus that row.
    static let measuredBaseline = (zeroResults: 6, wrongTopOne: 24, defensible: 27)

    /// §34's 11 named zero-result queries, verbatim. Seven are natural-phrasing failures (there is no
    /// stopword list on the search path, so `of` is a hard AND term), three are brand-index failures
    /// (`brand_source` is in neither the FTS table nor `Index.searchable`), one is a typo (no
    /// edit-distance fallback anywhere in the pipeline).
    /// **Seven of the eleven no longer return zero** as of fixes 1.6/1.7a/1.8 — all seven of §26's
    /// predicted stopword recoveries. Four remain, and the split is exactly the causal one §8 drew:
    /// every recovered query was a natural-phrasing failure, and every survivor is a brand-index
    /// failure (`costco`/`kirkland`/`whole foods` live in the unindexed `brand_source`, → fix 2.3) or
    /// the typo (`chiken`, → an edit-distance fallback, §30 row 16). The later typed-only partial
    /// fallback may offer a discovery row for two of these, but leaves this strict scorer baseline
    /// and every automatic consumer unchanged.
    static let reportNamedZeroResultQueries: [FoodSearchCorpusCase] = [
        FoodSearchCorpusCase("bowl of oatmeal", .reportNamedZeroResult, .defensible, "Oatmeal, NFS", 810),
        FoodSearchCorpusCase("two scrambled eggs", .reportNamedZeroResult, .defensible,
                             "Egg omelet or scrambled egg, NS as to fat", 58),
        FoodSearchCorpusCase("glass of milk", .reportNamedZeroResult, .wrongTopOne, "Milk and cereal bar", 809),
        FoodSearchCorpusCase("handful of almonds", .reportNamedZeroResult, .defensible, "Nuts, almonds", 310),
        FoodSearchCorpusCase("piece of chicken", .reportNamedZeroResult, .wrongTopOne, "Chicken curry with rice", 808),
        FoodSearchCorpusCase("bowl of cereal", .reportNamedZeroResult, .wrongTopOne,
                             "Cereals ready-to-eat, UNCLE SAM CEREAL", 807),
        FoodSearchCorpusCase("plate of pasta", .reportNamedZeroResult, .defensible, "Pasta, cooked", 810),
        FoodSearchCorpusCase("costco cheese pizza slice", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("kirkland protein bar", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("whole foods rotisserie chicken", .reportNamedZeroResult, .zeroResults),
        FoodSearchCorpusCase("chiken breast", .reportNamedZeroResult, .zeroResults)
    ]

    /// §8's 15 named wrong-top-1 queries. `expectedTopName` is the WRONG row the pipeline returns
    /// today — several names are longer than §8's prose renderings, which abbreviate; the strings here
    /// are the catalog's, character for character (the Texas Toast row really is stored truncated at
    /// 120 characters).
    ///
    /// **Two of the fifteen are now right**, both from the name floor (fix 1.8) rather than from any
    /// reordering: *Ramen bowl with chicken* carries neither "noodle" nor "soup" in its name and
    /// *Banquet Breakfast Chicken Sandwich* carries no "fil", so both were reaching the top on a
    /// category/tag hit, and removing them exposed the row that was there all along —
    /// `CAMPBELL'S, Chicken Noodle Soup, condensed` and `CHICK-FIL-A, chicken sandwich`.
    /// Four more moved without becoming right, and are judged at their rows below.
    static let reportNamedWrongTopOneQueries: [FoodSearchCorpusCase] = [
        FoodSearchCorpusCase("apple", .reportNamedWrongTopOne, .wrongTopOne, "Apple & Cheese Tray", 809),
        FoodSearchCorpusCase("brown rice", .reportNamedWrongTopOne, .wrongTopOne, "Snacks, brown rice chips", 369),
        FoodSearchCorpusCase("cheddar cheese", .reportNamedWrongTopOne, .wrongTopOne,
                             "Sausage, pork and beef, with cheddar cheese, smoked", 366),
        // The calzone is gone (its name carries no "pizza"), and what it was hiding is a genuine
        // cheese pizza — but a WHITE one, which is a different dish from what "cheese pizza" means,
        // and it wins on a score of −12 that is itself a `formSpecificityBias` false positive: "white"
        // is in `formQualifierTokens` for egg whites, and costs this row 130 points. Still wrong.
        FoodSearchCorpusCase("cheese pizza", .reportNamedWrongTopOne, .wrongTopOne, "Annie's Three Cheese Pizza Poppers", 368),
        FoodSearchCorpusCase("beef tacos", .reportNamedWrongTopOne, .wrongTopOne, "TACO BELL, BURRITO SUPREME with beef", 57),
        FoodSearchCorpusCase("pho", .reportNamedWrongTopOne, .wrongTopOne,
                             "Gelatin desserts, dry mix, reduced calorie, with aspartame, added phosphorus, potassium, sodium, vitamin C", 238),
        FoodSearchCorpusCase("mac and cheese", .reportNamedWrongTopOne, .wrongTopOne, "Babyfood, macaroni and cheese, toddler", 58),
        FoodSearchCorpusCase("chicken noodle soup", .reportNamedWrongTopOne, .defensible,
                             "CAMPBELL'S, Chicken Noodle Soup, condensed", 428),
        FoodSearchCorpusCase("low fat greek yogurt", .reportNamedWrongTopOne, .wrongTopOne, "Low-Fat Greek Yogurt, Guacamole", 989),
        FoodSearchCorpusCase("chick fil a sandwich", .reportNamedWrongTopOne, .defensible,
                             "CHICK-FIL-A, chicken sandwich", 179),
        FoodSearchCorpusCase("chipotle chicken bowl", .reportNamedWrongTopOne, .wrongTopOne, "Lean Chipotle Chicken Bowl, Spicy", 429),
        FoodSearchCorpusCase("slice of toast", .reportNamedWrongTopOne, .wrongTopOne, "French toast sticks", 309),
        FoodSearchCorpusCase("cup of coffee", .reportNamedWrongTopOne, .wrongTopOne, "SILK Coffee, soymilk", 309),
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
    ///
    /// **Both survive fixes 1.6/1.7a/1.8 untouched, and both are the same defect: data type sorts
    /// above score.** Neither row is a prepared dish, so 1.7a's demotion does not see them; both carry
    /// the query in their name, so 1.8's floor does not either. They move only under fix 1.7 option
    /// (b) — score-first — which is not authorized here. Read them as the standing measurement of what
    /// option (a) cannot reach.
    static let preRegisteredQueries: [FoodSearchCorpusCase] = [
        // Shape A — single-token whole food (10). `oatmeal` and `almonds` are the bare forms of two
        // §26-1.6 predictions (`bowl of oatmeal`, `handful of almonds`), included for that mechanism.
        FoodSearchCorpusCase("banana", .singleTokenWholeFood, .defensible, "Bananas, raw", 750),
        FoodSearchCorpusCase("salmon", .singleTokenWholeFood, .wrongTopOne, "Salmon, sockeye, canned, total can contents", 806),
        FoodSearchCorpusCase("broccoli", .singleTokenWholeFood, .defensible, "Broccoli, raw", 810),
        FoodSearchCorpusCase("avocado", .singleTokenWholeFood, .defensible, "Avocado, Hass, peeled, raw", 808),
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
        FoodSearchCorpusCase("peanut butter", .modifierPlusFood, .defensible, "Peanut butter, creamy", 870),
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
        FoodSearchCorpusCase("grilled chicken", .preparationQualified, .defensible,
                             "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled", 263),

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

        // The research's own named lists stay intact at the sizes §8 reports. Membership is by SHAPE
        // — the criterion that put each query in the corpus — not by verdict: the verdicts are what a
        // fix is allowed to move, and fixes 1.6/1.7a/1.8 moved seven of the eleven and two of the
        // fifteen. Asserting `allSatisfy { verdict == .zeroResults }` here would have made a list
        // named after a 2026-08-22 finding permanently unfixable.
        #expect(Self.reportNamedZeroResultQueries.count == 11)
        #expect(Self.reportNamedWrongTopOneQueries.count == 15)
        #expect(Self.reportNamedZeroResultQueries.allSatisfy { $0.shape == .reportNamedZeroResult })
        #expect(Self.reportNamedWrongTopOneQueries.allSatisfy { $0.shape == .reportNamedWrongTopOne })
        #expect(Self.reportNamedZeroResultQueries.filter { $0.verdict == .zeroResults }.count == 4,
                "4 of §34's 11 still return nothing — the three brand-index failures plus the typo")
        #expect(Self.reportNamedWrongTopOneQueries.filter { $0.verdict == .defensible }.count == 2,
                "2 of §8's 15 are now right: chicken noodle soup and chick fil a sandwich")
        #expect(Self.preRegisteredQueries.count == Self.corpus.count - 26)

        // Uniqueness on BOTH the raw text and the folded form the pipeline actually keys on: two rows
        // differing only in case or punctuation would be one measurement pinned twice.
        #expect(Set(Self.corpus.map(\.query)).count == Self.corpus.count, "corpus queries must be unique")
        #expect(Set(Self.corpus.map { FoodItemSearch.normalized($0.query) }).count == Self.corpus.count,
                "corpus queries must be unique after normalization")

        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        // The corpus's zero-result verdict pins the normal prefix-AND gate and its confidence-safe
        // scorer. A typed discovery fallback is intentionally outside that baseline.
        let empties = Self.corpus.filter { catalog.scoredResults(for: $0.query, limit: 1).isEmpty }
        #expect(empties.count == counts.zeroResults, "measured zero-result count: \(empties.count)")
        #expect(Set(empties.map(\.query)) == Set(Self.corpus.filter { $0.verdict == .zeroResults }.map(\.query)))

        let partialQueries = [
            "chiken breast", "grilled salmon fillet", "kirkland protein bar", "quest protein bar"
        ]
        let partialHits = partialQueries.filter {
            catalog.results(for: $0, limit: 6, context: .userTyped).isEmpty == false
        }
        #expect(partialHits == partialQueries, "typed partial-match population moved: \(partialHits)")
    }

    // MARK: - §9's named measurements

    /// The row-level pins for the queries the research names outside the corpus — one table, covered
    /// by the dump, so the interpretive tests below never restate a name or a score.
    ///
    /// `pizza dough crust` WAS the literal search string `DishTemplates.json`'s pizza template used
    /// before fix 1.3 repaired it (now `pizza dough`, per the template's `components`); this string no
    /// longer appears anywhere in the JSON. Pinning its unchanged score here proves fix 1.3 lives
    /// entirely in the JSON data, not in the scorer or the catalog — the orphaned string still ranks
    /// exactly as it always did, because nothing about ranking moved.
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
        FoodSearchRankedPin("chili", "§9(b) baseline, post-1.7a AND post-negation: `Chili hot dog, no bun` is back at rank 2 — the carrier token `bun` appears in its name only to be DENIED, and `isPreparedDish` now reads the negation. The two chili-dog SANDWICH rows (real carriers) stay demoted, as does `Cheese dip with chili pepper`", [
            FoodSearchRankedRow("Chili, NFS", 810, "survey"),
            FoodSearchRankedRow("Chili hot dog, no bun", 809, "survey"),
            FoodSearchRankedRow("Chili with chicken", 809, "survey"),
            FoodSearchRankedRow("Chili with meat, from restaurant", 807, "survey"),
            FoodSearchRankedRow("Pork with chili and tomatoes", 308, "survey"),
            FoodSearchRankedRow("Potato, french fries, with chili", 307, "survey")
        ]),
        FoodSearchRankedPin("chilis", "§9(b) flipped: one trailing `s` still makes it a brand query, and ONE row survives both floors. The five that used to fill ranks 2-6 (Beans & Franks, Beans & Wieners, Beef Goulash) are gone on carriage; the rows actually NAMED Chili carry the query but score 0 — the +60 coverage bonus needs `chilis` to EQUAL a name token and the token is `chili` — so the SCORE floor takes them too. A one-row page is the honest answer to a query the brand lexicon misread", [
            FoodSearchRankedRow("5 Chilis Salsa", 309, "branded")
        ]),
        FoodSearchRankedPin("cheese pizza", "§9(c) CLOSED, and it took both floors. Carriage removed both calzones (neither name carries `pizza`); the score floor then removed the three White pizza rows, whose −12/−13 was `formSpecificityBias` reading `white` as an egg-white qualifier. What was hidden behind five wrong rows is a page of real chain cheese pizzas. Rank 1 is still not right — a pizza-flavoured SNACK wins a name tie-break against PIZZA HUT at the same 368 — but nothing negative-scoring is presented any more", [
            FoodSearchRankedRow("Annie's Three Cheese Pizza Poppers", 368, "srLegacy"),
            FoodSearchRankedRow("PIZZA HUT 12\" Cheese Pizza, Pan Crust", 368, "srLegacy"),
            FoodSearchRankedRow("PIZZA HUT 14\" Cheese Pizza, Pan Crust", 368, "srLegacy"),
            FoodSearchRankedRow("DOMINO'S 14\" Cheese Pizza, Crunchy Thin Crust", 367, "srLegacy"),
            FoodSearchRankedRow("LITTLE CAESARS 14\" Cheese Pizza, Thin Crust", 367, "srLegacy"),
            FoodSearchRankedRow("PAPA JOHN'S 14\" Cheese Pizza, Original Crust", 367, "srLegacy")
        ]),
        FoodSearchRankedPin("cheese pizza slice", "§29's ACCEPTANCE CASE. The defensible branded row is still rank 1 — leading-position stopwording never strips a trailing `slice`, so the survey tier never re-enters and the calzone never appears. Fix 1.8 then removed four of the six rows, including both at −82: none of their names carries `pizza`", [
            FoodSearchRankedRow("Sliced Pizza, Cheese", 120, "branded"),
            FoodSearchRankedRow("Pizza, Sliced Tomato & 5 Cheese", 119, "branded")
        ]),
        FoodSearchRankedPin("mozzarella cheese", "§31's promise for this query is NOT delivered by option (a) — see `mozzarellaIsStillNotTheCheeseRow`. The survey `Mozzarella sticks` row is gone (its name carries no `cheese`), but what surfaces is another fried-stick row, and the branded `Mozzarella Cheese` row that scores 1870 is still unreachable behind two whole data-type tiers", [
            FoodSearchRankedRow("DENNY'S, mozzarella cheese sticks", 369, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, nonfat", 120, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, low sodium", 119, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, part skim milk", 119, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, whole milk", 119, "srLegacy"),
            FoodSearchRankedRow("Cheese, mozzarella, low moisture, part-skim", 118, "srLegacy")
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
        // §9(b)'s "rows scoring 0 are presented with no distinction" is CLOSED by fix 1.8's score
        // floor: the brand flip still collapses the scores, but a collapsed score no longer buys a
        // place on the page.
        #expect(chilis.allSatisfy { $0.score >= FoodItemSearch.minimumBindScore })
        #expect(chilis.count == 1, "one row clears both floors")
    }

    /// §9(c) as a mechanism, AFTER fix 1.8 — and the reason the fix is a name floor, not a score floor.
    ///
    /// The rule now enforced is ``FoodItemSearch/nameCarriesQuery(_:query:)``: a row that reached the
    /// gate through its category/tags alone is not presented. Both of §9(c)'s named victims go — the
    /// two `cheese pizza slice` rows at **−82** and, at `chilis`, the five rows scoring **0**.
    ///
    /// **What a literal score floor would have cost, asserted here so the substitution is not taken on
    /// trust.** The +60 coverage bonus requires a query token to EQUAL a name token (§8), so a match
    /// reached through the singular/plural stem earns nothing and the length penalty carries it
    /// negative — rows literally NAMED "Chili" score 0 for `chilis`, and *Egg, whole, raw, fresh*
    /// scores −1 for `eggs`. A floor at `minimumBindScore` deletes all of them. The name test keeps
    /// every one and still removes everything §9(c) complains about.
    @Test func bothHalvesOfTheFloorAreLoadBearing() throws {
        #expect(FoodItemSearch.minimumBindScore == 1)
        #expect(FoodItemSearch.confidentBindScore == 250)
        #expect(FoodItemSearch.minimumQueryLength == 3)

        // The floor stated as an invariant over the whole corpus rather than as a row list: every
        // presented row carries the query in its NAME **and** scores at or above the floor.
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        for corpusCase in Self.corpus {
            for row in catalog.scoredResults(for: corpusCase.query, limit: 6) {
                #expect(FoodItemSearch.nameCarriesQuery(row.item.name, query: corpusCase.query),
                        "\"\(corpusCase.query)\" presented \"\(row.item.name)\", whose name does not carry it")
                #expect(row.score >= FoodItemSearch.minimumBindScore,
                        "\"\(corpusCase.query)\" presented \"\(row.item.name)\" at \(row.score)")
            }
        }

        // HALF ONE, the score floor, is what kills §9(b)'s junk: rows NAMED Chili carry the query
        // perfectly well and are refused purely on score.
        #expect(FoodItemSearch.nameCarriesQuery("Beef Chili", query: "chilis"),
                "carriage alone would keep a 0-scoring row §9(b) complains about")
        #expect(try Self.rankedRows(for: "chilis").allSatisfy { $0.score >= FoodItemSearch.minimumBindScore })

        // HALF TWO, name carriage, is what kills the rows a score floor cannot see: these reached the
        // top-6 through category/tags and score well enough to clear any floor.
        #expect(!FoodItemSearch.nameCarriesQuery("Ramen bowl with chicken", query: "chicken noodle soup"),
                "a row scoring 60 that carries neither `noodle` nor `soup` — no score floor removes it")
        #expect(!FoodItemSearch.nameCarriesQuery("Banquet Breakfast Chicken Sandwich, 3.36 Oz", query: "chick fil a sandwich"))
        #expect(!FoodItemSearch.nameCarriesQuery("Rolled oats", query: "breakfast"))

        // Carriage accepts a SUBSTRING, not only a token prefix — the alignment with the scorer's own
        // +250 bonus, and what keeps the canonical FNDDS burger rows that a token-only rule deleted.
        #expect(FoodItemSearch.nameCarriesQuery("Hamburger, NFS", query: "burger"))
        #expect(FoodItemSearch.nameCarriesQuery("Cheeseburger, NFS", query: "burger"))
        let burgers = try Self.rankedRows(for: "burger").map(\.name)
        #expect(burgers.contains("Hamburger, NFS") && burgers.contains("Cheeseburger, NFS"),
                "the canonical generic burgers are in the top-6: \(burgers)")

        // §29's acceptance case: `cheese pizza slice` must not become the calzone, its two −82 rows
        // must be gone, and it must still sit in ONE data-type tier (the property §29 turns on — with
        // "slice" present only branded rows survive the AND gate, so the survey tier cannot re-enter).
        let slice = try Self.rankedRows(for: "cheese pizza slice")
        #expect(slice.first?.name == "Sliced Pizza, Cheese")
        #expect(slice.allSatisfy { !$0.name.contains("Calzone") })
        #expect(Set(slice.map(\.dataType)).count == 1, "§29's mechanism: one tier survives the gate")
    }

    /// The adversarial review's battery, pinned as top-1 answers.
    ///
    /// These are the queries the review used to refute three of this increment's claims, and each one
    /// is here because it moved something a 57-query corpus could not see. They are asserted as
    /// top-1 name only — the full top-6 for the two that carry a ranking argument lives in
    /// ``namedRankingPins`` — so this table stays readable as a list of ANSWERS.
    static let reviewBattery: [(query: String, top: String)] = [
        // F3: canonical FNDDS rows a token-prefix-only carriage floor deleted. `Hamburger, NFS` does
        // not START with "burger"; carriage accepts the substring, which is what the scorer's own
        // +250 bonus has always done.
        ("burger", "Hamburger (Burger King)"),
        // F1: the row the score floor was supposed to cost and instead reveals. A synthetic 4-row
        // fixture said a score floor would delete the canonical egg; against 118,317 real rows it
        // surfaces it.
        ("eggs", "Eggs, Grade A, Large, egg whole"),
        // F4(a): `bun` inside "no bun" is a denial, not an assembly. This row is the LEAST assembled
        // hot dog in the catalog and the plain substring test ranked it as the most.
        ("hot dog", "Chili hot dog, no bun"),
        // F4(b): the widened carrier list. `broccoli`, `salmon` and `grilled chicken` led with a
        // slaw-salad / nuggets / McDonald's-salad row and now lead with the food.
        ("broccoli", "Broccoli, raw"),
        ("salmon", "Salmon, sockeye, canned, total can contents"),
        ("grilled chicken", "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled"),
        // NOT FIXED, and pinned as not fixed. The carrier list now recognises both rows, but the
        // demotion guard refuses to sink a dish beneath a WORSE-scoring ingredient and these two
        // dishes lead by 1 point (810 vs 809) and 55 (805 vs 750). A tolerance margin closes both and
        // costs `grilled cheese` — measured, and written up at `PreparedDishHeuristic`'s guard.
        ("beef", "Beef salad"),
        ("onion", "Onion rings, breaded, par fried, frozen, unprepared"),
        // F4(b)'s counterweight: the margin must not demote a dish the query NAMED. `nuggets` is a
        // carrier now, and this row still wins because it beats every ingredient by far more than the
        // margin; `caesar salad` and `chicken noodle soup` never demote at all (head noun is a dish word).
        ("chicken nuggets", "Chicken nuggets, NFS"),
        ("caesar salad", "Caesar salad, with romaine, no dressing"),
        ("chicken noodle soup", "CAMPBELL'S, Chicken Noodle Soup, condensed"),
        // UNMOVED, and pinned so it is not mistaken for something this increment fixed: two survey
        // HAMBURGER rows outrank every real ham despite scoring 60 points lower, because data type
        // sorts above score. "hamburger" is not a carrier and never was. Option (b) territory.
        ("ham", "Hamburger, NFS")
    ]

    /// Replays the review battery.
    @Test func reviewBatteryTopAnswersAreUnchanged() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        for entry in Self.reviewBattery {
            let top = catalog.results(for: entry.query, limit: 1, context: .userTyped).first?.name
            #expect(top == entry.top, "top-1 moved for \"\(entry.query)\"")
        }
    }

    /// **An owner calibration question, measured and pinned rather than shipped quietly.**
    ///
    /// `confidentBindScore = 250` was calibrated against a search path with NO floor, where the top-1
    /// was routinely a low-scoring row. Fix 1.8 removes exactly those rows, so top-1 scores rise by
    /// construction and more binds present as CONFIDENT — the inversion this suite already pins for
    /// one orphaned string at ``mozzarellaIsStillNotTheCheeseRow``, here counted as a population.
    ///
    /// Across the 57-query corpus, top-1 scores at or above `confidentBindScore` went from **28 to
    /// 38**. Ten queries crossed: four that already returned rows (`cheese pizza` 58→368,
    /// `chicken noodle soup` 60→428, `slice of toast` 107→309, `cup of coffee` 115→309) and six that
    /// returned nothing at all before, so they had no bind to be confident about.
    ///
    /// **Six of the ten now present a WRONG top-1 at confident scores** — `cheese pizza`,
    /// `slice of toast`, `cup of coffee`, `glass of milk`, `piece of chicken`, `bowl of cereal`.
    /// That is the calibration question: a floor that removes bad rows also removes the low score
    /// that used to FLAG the survivor as weak. It is a threshold decision, not a bug, so it is
    /// reported rather than silently retuned.
    @Test func confidentBindPopulationIsPinnedForCalibration() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        let confident = Self.corpus.filter { corpusCase in
            (catalog.scoredResults(for: corpusCase.query, limit: 1).first?.score ?? 0) >= FoodItemSearch.confidentBindScore
        }
        #expect(confident.count == 38, "confident top-1s: \(confident.count) of 57")
        let confidentlyWrong = confident.filter { $0.verdict == .wrongTopOne }
        #expect(confidentlyWrong.count == 19, "confident AND wrong: \(confidentlyWrong.map(\.query))")
    }

    /// The three stopword sets are **frozen English matching inputs** and this is their freeze pin.
    ///
    /// The localization wall's own machinery cannot see them: it parses enum `rawValue`s, and these
    /// are bare `Set<String>` literals. They are compared against `normalized()` output, which folds
    /// an index baked in English at build time, so translating or reordering one silently changes
    /// which rows every query can reach. Pinned as sorted contents, so an addition is a deliberate
    /// edit here rather than a quiet retrieval change.
    @Test func stopwordSetsAreFrozen() {
        #expect(FoodItemSearch.functionStopWordsForTesting.sorted() ==
                ["an", "and", "for", "my", "of", "plus", "the", "then", "with"])
        #expect(FoodItemSearch.quantityStopWordsForTesting.sorted() ==
                ["bowl", "bowls", "cup", "cups", "dozen", "five", "four", "glass", "glasses", "half",
                 "handful", "handfuls", "piece", "pieces", "plate", "plates", "serving", "servings",
                 "six", "slice", "slices", "three", "two"])
        #expect(FoodItemSearch.occasionStopWordsForTesting.sorted() ==
                ["breakfast", "dinner", "lunch", "meal", "post", "pre", "snack", "workout"])
    }

    /// §26 fix 1.2's headline number: the RAW `mozzarella cheese` query — the pizza template's search
    /// string BEFORE fix 1.3 repaired it — binds far below `confidentBindScore` while an exact-name
    /// `Mozzarella Cheese` row sits in the same file. Fix 1.3 moved the template off this string (its
    /// cheese component now searches `low moisture part skim mozzarella cheese` and binds confidently,
    /// per `DishTemplateBindAuditTests`); this test is kept as a scorer-invariance pin on the ORPHANED
    /// string, not a claim about today's template.
    @Test func mozzarellaIsStillNotTheCheeseRow() throws {
        let ranked = try Self.rankedRows(for: "mozzarella cheese")
        let top = try #require(ranked.first)
        #expect(top.name.contains("sticks"), "§31's promise is not delivered: the top-1 is still a fried-stick row")
        #expect(ranked.dropFirst().allSatisfy { $0.name.hasPrefix("Cheese, mozzarella") },
                "every row BELOW it is a real mozzarella cheese — the ordering is the whole defect")

        // The right answer is present and reachable by exact name — §9's counterfactual target — and
        // is still two whole data-type tiers below anything that survives the gate here. It scores
        // 1870; nothing on this page scores over 400. Only option (b) moves it.
        let source = try #require(SQLiteBundledFoodSource(), "shipped catalog must open")
        try #require(source.count == Self.shippedRowCount)
        #expect(source.exactMatch(normalizedName: "mozzarella cheese")?.name == "Mozzarella Cheese")
        #expect(source.exactMatch(normalizedName: "cheese pizza")?.name == "Cheese Pizza")
        #expect(ranked.allSatisfy { $0.dataType != "branded" }, "the branded exact-name row cannot reach the page")

        // AND THE COST OF THE FLOOR, NAMED. Removing the sub-floor survey row that used to hold rank 1
        // (score 58) promoted a HIGHER-scoring but equally wrong row, so this query now clears
        // `confidentBindScore` — a bind on it would present as confident and be wrong, where before it
        // would have been flagged weak. The string is orphaned (fix 1.3 moved the pizza template off
        // it), so nothing ships through this path today; it is pinned because the mechanism is general.
        #expect(top.score > FoodItemSearch.confidentBindScore,
                "the floor raises top-1 scores, and confidence rides on the top-1 score")
    }

    // MARK: - The three coupled fixes, as mechanisms

    /// Fix 1.6's POSITION rules, which are what stop §29's hazard from ever firing.
    ///
    /// §29's demonstration is that stripping "slice" out of `cheese pizza slice` lets the survey tier
    /// back through a comparator that sorts data type above score, and the top-1 becomes a 1,655 kcal
    /// calzone. The rule here is that a quantity word is only ever stripped from the LEADING run,
    /// because that is the only position where it quantifies rather than names: "slice of toast" is a
    /// slice OF something, "cheese pizza slice" is the name of a thing. The mirror rule protects
    /// "breakfast burrito" and "dinner rolls" from an occasion strip.
    ///
    /// `searchTokens` is asserted rather than a result list because BOTH the FTS MATCH expression and
    /// the scorer's gate are built from it — the invariant is that they cannot drift apart.
    @Test func stopwordsAreStrippedByPositionNotByMembership() {
        #expect(FoodItemSearch.searchTokens(in: "bowl of oatmeal") == ["oatmeal"])
        #expect(FoodItemSearch.searchTokens(in: "two scrambled eggs") == ["scrambled", "eggs"])
        #expect(FoodItemSearch.searchTokens(in: "slice of toast") == ["toast"])
        #expect(FoodItemSearch.searchTokens(in: "mac and cheese") == ["mac", "cheese"])

        // Trailing quantity words are part of the dish's name and are KEPT — §29's whole point.
        #expect(FoodItemSearch.searchTokens(in: "cheese pizza slice") == ["cheese", "pizza", "slice"])
        #expect(FoodItemSearch.searchTokens(in: "chicken burrito bowl") == ["chicken", "burrito", "bowl"])

        // Leading occasion words are part of the food's name and are KEPT; trailing ones qualify it.
        #expect(FoodItemSearch.searchTokens(in: "breakfast burrito") == ["breakfast", "burrito"])
        #expect(FoodItemSearch.searchTokens(in: "dinner rolls") == ["dinner", "rolls"])
        #expect(FoodItemSearch.searchTokens(in: "pizza for dinner") == ["pizza"])

        // Never strip to nothing: a query made only of stopwords searches for what was typed.
        #expect(FoodItemSearch.searchTokens(in: "a bowl") == ["bowl"])
        #expect(FoodItemSearch.searchTokens(in: "pre workout") == ["pre", "workout"])
    }

    /// Fix 1.7a's score guard, which is the difference between the fix and two regressions.
    ///
    /// `PreparedDishHeuristic` decides intent from the query's HEAD NOUN, which cannot tell an idiom
    /// from an ingredient: `grilled cheese` reads as "cheese" and `chicken burrito bowl` reads as
    /// "bowl", so an unguarded demotion sinks *Grilled cheese sandwich, NFS* (carrier "sandwich") and
    /// *Burrito bowl, chicken* (carrier "burrito") — both correct, both pinned `.defensible`. The
    /// guard is that a dish may only sink beneath ingredients that match AT LEAST AS WELL, which the
    /// two rescued rows clear by a wide margin and the two demoted rows do not.
    @Test func dishDemotionNeverSinksABetterMatch() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)

        // Rescued: the query reads as an ingredient, the top row IS a dish, and it stays anyway.
        for (query, name) in [("grilled cheese", "Grilled cheese sandwich, NFS"),
                              ("chicken burrito bowl", "Burrito bowl, chicken")] {
            #expect(!PreparedDishHeuristic.queryWantsDish(query), "\"\(query)\" reads as an ingredient query")
            let top = try #require(catalog.results(for: query, limit: 1, context: .userTyped).first)
            #expect(top.name == name)
            #expect(PreparedDishHeuristic.isPreparedDish(top), "…and it is a prepared dish, kept only by the score guard")
        }

        // Demoted: the dish scored no better than the ingredients under it, so it sank.
        for (query, sunk) in [("peanut butter", "Peanut butter and jelly sandwich"), ("avocado", "Sushi roll")] {
            let top6 = catalog.results(for: query, limit: 6, context: .userTyped)
            #expect(!(top6.first.map(PreparedDishHeuristic.isPreparedDish) ?? true), "\"\(query)\" now leads with an ingredient")
            #expect(top6.first?.name.contains(sunk) == false)
        }

        // The guard as a unit, with no catalog: a dish scoring above every ingredient stays at rank 1.
        let dish = Self.stubFood(name: "Grilled cheese sandwich")
        let ingredient = Self.stubFood(name: "Cheese, cheddar")
        let strong = [(foodItem: dish, score: 1_000), (foodItem: ingredient, score: 100)]
        let weak = [(foodItem: dish, score: 100), (foodItem: ingredient, score: 1_000)]
        #expect(PreparedDishHeuristic.demotingDishes(scored: strong, forQuery: "grilled cheese").first?.foodItem.name == dish.name)
        #expect(PreparedDishHeuristic.demotingDishes(scored: weak, forQuery: "grilled cheese").first?.foodItem.name == ingredient.name)
    }

    /// A minimal `FoodItem` for the unit-level demotion assertions above; only the name is read.
    private static func stubFood(name: String) -> FoodItem {
        FoodItem(
            name: name, servingSize: 100, servingUnit: "g",
            macros: Macros(protein: 10, carbs: 10, fat: 10), micronutrients: Micronutrients(),
            category: "Test", source: .usda, dataType: .srLegacy, tags: []
        )
    }

    // MARK: - The resolver surface

    /// The RESOLVER bank: `FoodCatalog.candidates(for:limit:)`, the pool `MealResolutionService` and
    /// the quick-log path actually draw from. **This is a different ranking from search**, and pinning
    /// it is the point: `FoodSelectionCandidateBuilder.searchPhrases` splits the description into
    /// phrases (so stopwords never block it the way they block the search gate) and
    /// `PreparedDishHeuristic.demotingDishes` then REORDERS the pool, which `results(for:)` never does.
    ///
    /// The disagreements this pins are substantial, and every one is a place a "green corpus" would
    /// have hidden a resolver regression. Fixes 1.6/1.7a/1.8 moved nine of the thirty entries, all
    /// through `results(for:)`, which `candidates` calls per phrase:
    /// * `bowl of oatmeal` resolved to a branded sugary breakfast bowl and now resolves to
    ///   *Oatmeal, NFS* — the pool shrank from 9 to 8 and got the right answer;
    /// * `peanut butter` resolved to *Egg omelet or scrambled egg, made with butter* (the phrase
    ///   splitter searches `butter` alone and the dish demotion then promoted it) and now resolves to
    ///   *Peanut butter, creamy*;
    /// * `chicken noodle soup` and `beef tacos` moved onto rows that carry the query in their names;
    /// * `chilis`' pool fell from 4 to 1 as the tag-only rows left;
    /// * `chicken burrito bowl` still resolves to *Ramen bowl, NFS* though search finds *Burrito
    ///   bowl, chicken* — one of the two ranking divergences that remain;
    /// * four queries still return NOTHING from search but a full pool here — `chiken breast`,
    ///   `costco cheese pizza slice`, `quest protein bar`, `grilled salmon fillet` — and for
    ///   `grilled salmon fillet` the resolver's answer is the RIGHT food while search shows an empty
    ///   list. That gap is retrieval, and nothing in this increment could close it.
    static let resolverBank: [FoodResolverCase] = [
        FoodResolverCase("protein bar", 12, "Formulated Bar, SOUTH BEACH protein bar"),
        FoodResolverCase("cheerios", 4, "Cereals ready-to-eat, GENERAL MILLS, CHEERIOS"),
        FoodResolverCase("chili", 4, "Chili, NFS"),
        FoodResolverCase("chilis", 1, "5 Chilis Salsa"),
        FoodResolverCase("cheese pizza", 12, "Annie's Three Cheese Pizza Poppers"),
        FoodResolverCase("cheese pizza slice", 18, "Sliced Pizza, Cheese"),
        FoodResolverCase("mozzarella cheese", 10, "DENNY'S, mozzarella cheese sticks"),
        FoodResolverCase("pizza dough crust", 18, "Pillsbury Pizza Dough Thin Crust"),
        FoodResolverCase("black coffee", 12, "Califia, Cold Brew All Black Coffee"),
        FoodResolverCase("costco cheese pizza slice", 18, "Sliced Pizza, Cheese"),
        // Back to the branded breakfast bowl, and deliberately: fix 1.6's position strip no longer
        // applies to `searchPhrases`' SUB-phrases (see F2 above), so this pool is exactly what it was
        // before the increment. The SEARCH surface still answers `Oatmeal, NFS`.
        FoodResolverCase("bowl of oatmeal", 9,
                         "Organic Apples & Blueberries Oatmeal + Sprouted Quinoa Super Morning Bowl, Organic Apples & Blueberries"),
        FoodResolverCase("two scrambled eggs", 12, "Egg omelet or scrambled egg, made with butter"),
        FoodResolverCase("chiken breast", 6, "Chicken breast, stewed, skin eaten"),
        FoodResolverCase("apple", 4, "Apple & Cheese Tray"),
        FoodResolverCase("brown rice", 11, "Snacks, brown rice chips"),
        FoodResolverCase("mac and cheese", 10, "CRACKER BARREL, macaroni n' cheese"),
        FoodResolverCase("chicken noodle soup", 18, "CAMPBELL'S, Chicken Noodle Soup, condensed"),
        FoodResolverCase("beef tacos", 12, "TACO BELL, BURRITO SUPREME with beef"),
        FoodResolverCase("low fat greek yogurt", 18, "Yogurt, Greek, 2% fat, apricot, CHOBANI"),
        FoodResolverCase("chipotle chicken bowl", 18, "Lean Chipotle Chicken Bowl, Spicy"),
        FoodResolverCase("slice of toast", 12, "Thick Slice Swirl French Toast Bread, French Toast"),
        FoodResolverCase("tomatoes", 4, "Pork with chili and tomatoes"),
        FoodResolverCase("white rice", 12,
                         "Crackers, gluten-free, multigrain and vegetable, made with corn starch and white rice flour"),
        FoodResolverCase("peanut butter", 9, "Peanut butter, creamy"),
        FoodResolverCase("grilled chicken", 12, "Chicken, broiler or fryers, breast, skinless, boneless, meat only, cooked, grilled"),
        FoodResolverCase("chicken burrito bowl", 18, "Ramen bowl, NFS"),
        FoodResolverCase("grilled salmon fillet", 18, "Grilled Salmon"),
        FoodResolverCase("whole wheat toast", 18, "Bread, whole-wheat, commercially prepared, toasted"),
        FoodResolverCase("quest protein bar", 14, "Formulated Bar, SOUTH BEACH protein bar"),
        FoodResolverCase("chickpeas", 4, "Chickpeas, (garbanzo beans, bengal gram), dry"),
        // Added 2026-08-23 by the adversarial review of fix 1.6: `searchPhrases` sub-slices BEFORE
        // the scorer sees a phrase, so a position-based stopword strip applied to a SUB-PHRASE
        // deletes the discriminating token rather than leading noise ("slices pizza" → "pizza").
        // These two pools lost every sliced-pizza row and collapsed to bare `chicken` respectively.
        // The corpus proper cannot see this surface — it never calls `candidates` — so the guard
        // lives here.
        FoodResolverCase("two slices of pizza", 17, "Amnon's Pizza, Large Pizza Slices"),
        FoodResolverCase("piece of chicken", 12, "Tyson Pride Uncooked 8 Piece Chicken Cuts")
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

    /// The two surfaces still disagree, on a MEASURED and shrinking list.
    ///
    /// The two surfaces are RANKED alike now (both apply the floor and the demotion) and RETRIEVE
    /// differently on purpose, so what is pinned here is the shape of the remaining disagreement, not
    /// a shrinking number. `stillDiverging` is computed over all 57 corpus queries — the earlier
    /// count of 10 was over the resolver bank only, so the two are not comparable and this one is
    /// stated as what it is.
    ///
    /// `costco cheese pizza slice` remains empty on both the normal AND scorer and the typed
    /// fallback (four meaningful tokens exceed the fallback's three-token cap), while the resolver's
    /// phrase splitter reaches rows. The rest pick different foods because
    /// `searchPhrases` searches sub-phrases a single AND gate never forms — which is the resolver's
    /// entire purpose, and why fix 1.6 is confined to the typed-query surface.
    @Test func searchAndResolverSurfacesStillDisagree() throws {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        let searchIsEmptyButResolverIsNot = ["costco cheese pizza slice"]
        for query in searchIsEmptyButResolverIsNot {
            let searchCount = catalog.results(for: query, limit: 6, context: .userTyped).count
            let resolverCount = catalog.candidates(for: query, limit: 18).count
            #expect(searchCount == 0, "\"\(query)\" should still return nothing from search")
            #expect(resolverCount > 0, "\"\(query)\" should still return a resolver pool")
        }
        for query in ["chicken burrito bowl", "low fat greek yogurt"] {
            let searchTop = catalog.results(for: query, limit: 1, context: .userTyped).first?.name
            let resolverTop = catalog.candidates(for: query, limit: 18).first?.foodItem.name
            #expect(searchTop != resolverTop, "\"\(query)\": the two surfaces should still pick different foods")
        }
        // The one that CLOSED, asserted as closed so a regression cannot quietly reopen it. Three
        // others closed and then deliberately REOPENED: `bowl of oatmeal`, `two scrambled eggs` and
        // `slice of toast` agreed only while fix 1.6's position strip was (wrongly) also applied to
        // `searchPhrases`' sub-phrases. Confining it to the typed-query surface put the resolver's
        // sub-phrase behaviour back exactly where it was, and these three back to disagreeing — the
        // right trade, since the alternative cost `two slices of pizza` every sliced-pizza row in its
        // pool. The SEARCH surface still answers all three correctly.
        for query in ["peanut butter"] {
            let searchTop = catalog.results(for: query, limit: 1, context: .userTyped).first?.name
            let resolverTop = catalog.candidates(for: query, limit: 18).first?.foodItem.name
            #expect(searchTop != nil, "\"\(query)\" no longer returns nothing from search")
            #expect(searchTop == resolverTop, "\"\(query)\": the two surfaces now agree")
        }
        // Not a count of the literal above (that would assert nothing): the corpus queries whose two
        // surfaces still disagree, computed live.
        let stillDiverging = Self.corpus.filter { corpusCase in
            let searchTop = catalog.results(for: corpusCase.query, limit: 1, context: .userTyped).first?.name
            let resolverTop = catalog.candidates(for: corpusCase.query, limit: 18).first?.foodItem.name
            return searchTop != resolverTop
        }
        #expect(stillDiverging.count == 14, "divergences: \(stillDiverging.map(\.query))")
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
    /// are NOT reachable through the strict scorer, because `brand_source` is indexed nowhere. The
    /// typed partial fallback may offer a related discovery row, but cannot create a scored result or
    /// an automatic bind. Fix 2.3's instrument — when it lands, these strict misses flip.
    @Test func brandSourceRowsRemainUnsearchableByStrictGate() throws {
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
        #expect(catalog.scoredResults(for: "costco cheese pizza slice").isEmpty)
        #expect(catalog.scoredResults(for: "kirkland protein bar").isEmpty)
        #expect(catalog.scoredResults(for: "whole foods rotisserie chicken").isEmpty)
    }

    /// The candidate set the SHIPPED source hands the scorer, per query — the pipeline's own half of
    /// §8's table (`SQLiteBundledFoodSource.candidates`, capped at `candidateFetchLimit`). Pinned
    /// separately from the raw FTS counts so a change to the MATCH-expression builder, the cap, or
    /// the de-bias `ORDER BY` is attributable to the query side rather than to the file.
    static let sourceCandidateSetSizes: [(query: String, expected: Int)] = [
        ("cheese pizza", 533),
        ("cheese pizza slice", 6),
        ("costco cheese pizza slice", 0),
        ("bowl of oatmeal", 690),
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

    /// **Retrieval and scoring must gate on the SAME token set** — the invariant `searchTokens`
    /// claims, asserted rather than assumed.
    ///
    /// `stripsStopwords` existed on the scorer before it existed on the source, so every
    /// `stripsStopwords: false` caller (the whole resolver path, via `searchPhrases`' sub-phrases)
    /// retrieved with quantity words STRIPPED and then scored with them KEPT. The delta is not
    /// marginal: `piece chicken` fetched the **5,270** rows matching `chicken*` where the scorer
    /// wanted the **12** matching `piece* AND chicken*`, and `slice cheese` fetched **8,982** against
    /// a wanted **182**.
    ///
    /// **Why over-fetching is not harmless: the cap.** `FoodCatalog.candidateFetchLimit` is 10,000 on
    /// the base catalog, so there the excess is merely wasted hydration. The branded On-Demand
    /// Resource is the real exposure — `BrandedCatalogResourceLoader` attaches ~364,457 rows with
    /// `candidateCap = 600` AND `skipPriorityOrder: true`, which omits the `ORDER BY` entirely and
    /// truncates in rowid order. An 8,982-row fetch capped at 600 keeps whichever rows happen to
    /// carry a low `food_id`; the rows matching BOTH typed words survive only by accident, while the
    /// 182-row AND set fits inside 600 with room to spare. Fix 2.3 (indexing `brand_source`) pushes
    /// thousands more branded rows through the same gate and widens the gap.
    ///
    /// The ODR file is absent from test runs, so this pins the base catalog as the proxy and records
    /// the ODR arithmetic above; the mechanism — which token set builds the MATCH expression — is
    /// identical on both sources.
    @Test func retrievalAndScoringGateOnTheSameTokens() throws {
        let source = try #require(SQLiteBundledFoodSource(), "shipped catalog must open")
        try #require(source.count == Self.shippedRowCount)

        // The token sets themselves, at the seam both sides read.
        #expect(FoodItemSearch.searchTokens(in: "piece chicken") == ["chicken"])
        #expect(FoodItemSearch.searchTokens(in: "piece chicken", stripsStopwords: false) == ["piece", "chicken"])

        // And the row sets they produce. The stripped fetch is 439× the unstripped one.
        let stripped = source.candidates(forQuery: "piece chicken", stripsStopwords: true).count
        let unstripped = source.candidates(forQuery: "piece chicken", stripsStopwords: false).count
        #expect(stripped == 5_270, "chicken* alone")
        #expect(unstripped == 12, "piece* AND chicken* — what a `stripsStopwords: false` scorer gates on")

        // The ODR-shaped case, on the base catalog: 8,982 overflows a 600-row cap 15× over, 182 does not.
        #expect(source.candidates(forQuery: "slice cheese", stripsStopwords: true).count == 8_982)
        #expect(source.candidates(forQuery: "slice cheese", stripsStopwords: false).count == 182)

        // The resolver path really does take the unstripped branch end to end: every row it returns
        // for a quantity-led sub-phrase carries BOTH words, which the stripped gate could not promise.
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == Self.shippedRowCount)
        let phrases = FoodSelectionCandidateBuilder.searchPhrases(from: "two slices of pizza")
        #expect(phrases.contains("slices pizza"), "the quantity word survives into the sub-phrases")
        for candidate in catalog.candidates(for: "two slices of pizza", limit: 18) {
            #expect(phrases.contains { FoodItemSearch.nameCarriesQuery(candidate.foodItem.name, query: $0, stripsStopwords: false) },
                    "\(candidate.foodItem.name) reached the pool through no sub-phrase at all")
        }
    }

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
        Self.printLiveMeasurementIfRequested()
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
        guard dumpRequested else { return }
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

    // MARK: - Live re-measurement

    /// Prints what the pipeline does NOW for every pinned surface, flagging each row that moved.
    ///
    /// ``printDumpIfRequested(_:)`` reprints what is PINNED, which is all a reader needs while the
    /// pins are still true — but it cannot re-baseline a deliberate behaviour change, because the
    /// values it prints are precisely the ones the change just invalidated. This block re-runs all 57
    /// corpus queries, all ``namedRankingPins`` and the whole ``resolverBank`` against the shipped
    /// catalog and prints them in the same paste-ready literal form, preceded by an explicit
    /// WAS → NOW flip list.
    ///
    /// **It prints; it never asserts.** Verdicts are human judgements ("is this the food a person
    /// typing this meant?") and cannot be measured, so a row whose emptiness class changed is emitted
    /// with a `JUDGE` marker and the conservative `.wrongTopOne` placeholder rather than a guess that
    /// would quietly launder a regression into a green baseline. Added by the 1.6/1.7a/1.8 round —
    /// §29's coupled unit, the first change that actually moves these numbers.
    private static func printLiveMeasurementIfRequested() {
        guard dumpRequested else { return }
        let catalog = FoodCatalog.bundled()
        guard catalog.bundledCount == shippedRowCount else {
            print("// LIVE DUMP SKIPPED — the shipped catalog is not loaded, so nothing measured here is real")
            return
        }
        print("// ══ LIVE MEASUREMENT ═══════════════════════════════════════════")
        printLiveCorpus(catalog)
        printLiveRankingPins(catalog)
        printLiveResolverBank(catalog)
        printLiveCandidateSetSizes()
    }

    /// Swift-literal escaping for a measured catalog name.
    ///
    /// Pinned names are asserted quote-free by ``dumpEmitsOneParseableRowPerCorpusQuery()``, but a
    /// MEASURED one need not be: the catalog really does contain rows like `PIZZA HUT 14" Cheese
    /// Pizza, Pan Crust`, and printing one raw emits a literal that does not compile.
    private static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    /// Whether the environment asked for a dump. Xcode forwards the `TEST_RUNNER_` prefix.
    private static var dumpRequested: Bool {
        let env = ProcessInfo.processInfo.environment
        return env["FOOD_CORPUS_DUMP"] != nil || env["TEST_RUNNER_FOOD_CORPUS_DUMP"] != nil
    }

    /// Re-measures all 57 corpus queries: the flip list, then the corpus arrays as they should now read.
    private static func printLiveCorpus(_ catalog: FoodCatalog) {
        let measured = corpus.map { pinned -> (pinned: FoodSearchCorpusCase, live: FoodSearchCorpusCase, judge: Bool) in
            let ranked = catalog.scoredResults(for: pinned.query, limit: 1)
            let judge = ranked.isEmpty != (pinned.expectedTopName == nil)
            let verdict: FoodSearchCorpusVerdict = ranked.isEmpty ? .zeroResults : (judge ? .wrongTopOne : pinned.verdict)
            let live = FoodSearchCorpusCase(pinned.query, pinned.shape, verdict,
                                            ranked.first?.item.name, ranked.first.map(\.score))
            return (pinned, live, judge)
        }
        print("// ── FLIPS (measured ≠ pinned) ──────────────────────────────────")
        for row in measured where row.live.expectedTopName != row.pinned.expectedTopName
            || row.live.expectedTopScore != row.pinned.expectedTopScore {
            print("// \"\(row.pinned.query)\": WAS \(describe(row.pinned)) → NOW \(describe(row.live))\(row.judge ? "   ← JUDGE" : "")")
        }
        // A row whose emptiness class changed cannot be verdicted from its top-1 alone — the question
        // is whether the food a person meant is anywhere in what they would actually see.
        print("// ── JUDGE rows, top-6 ─────────────────────────────────────────")
        for row in measured where row.judge {
            print("// \"\(row.pinned.query)\":")
            for ranked in catalog.scoredResults(for: row.pinned.query, limit: 6) {
                print("//     \(escaped(ranked.item.name)) — \(ranked.score) \(ranked.item.dataType.rawValue)")
            }
        }
        let counts = verdictCounts(in: measured.map(\.live))
        print("// measuredBaseline = (zeroResults: \(counts.zeroResults), wrongTopOne: \(counts.wrongTopOne), defensible: \(counts.defensible))")
        print("//   — wrongTopOne/defensible carry the PINNED verdict forward; every JUDGE row above needs a human verdict")
        for verdict in [FoodSearchCorpusVerdict.zeroResults, .wrongTopOne, .defensible] {
            print("// ── \(verdict.rawValue) ───────────────────────────────────────────────")
            for row in measured where row.live.verdict == verdict {
                print(liveLiteral(for: row.live) + (row.judge ? "   // ← JUDGE" : ""))
            }
        }
    }

    /// "name (score)" or "∅" for a measured/pinned top-1.
    private static func describe(_ corpusCase: FoodSearchCorpusCase) -> String {
        guard let name = corpusCase.expectedTopName else { return "∅" }
        return "\"\(escaped(name))\" (\(corpusCase.expectedTopScore ?? 0))"
    }

    /// Re-measures every named ranking pin's top-6.
    private static func printLiveRankingPins(_ catalog: FoodCatalog) {
        print("// ── namedRankingPins ─────────────────────────────────────────────")
        for pin in namedRankingPins {
            let live = catalog.scoredResults(for: pin.query, limit: 6)
                .map { FoodSearchRankedRow($0.item.name, $0.score, $0.item.dataType.rawValue) }
            print("FoodSearchRankedPin(\"\(pin.query)\", \"\(escaped(pin.note))\", [\(live == pin.rows ? "" : "   // ← MOVED")")
            for row in live { print("    FoodSearchRankedRow(\"\(escaped(row.name))\", \(row.score), \"\(row.dataType)\"),") }
            print("]),")
        }
    }

    /// The literal for a MEASURED corpus row — ``literal(for:)`` with the catalog name escaped.
    private static func liveLiteral(for corpusCase: FoodSearchCorpusCase) -> String {
        let head = "FoodSearchCorpusCase(\"\(corpusCase.query)\", .\(corpusCase.shape.rawValue), .\(corpusCase.verdict.rawValue)"
        guard let name = corpusCase.expectedTopName, let score = corpusCase.expectedTopScore else {
            return head + "),"
        }
        return head + ", \"\(escaped(name))\", \(score)),"
    }

    /// Re-measures the shipped source's candidate-set sizes — the retrieval half, which fix 1.6 moves
    /// (a stripped stopword is a term the FTS MATCH expression never emits).
    private static func printLiveCandidateSetSizes() {
        // The adversarial review's battery, measured live so its cases can be judged and pinned.
        print("// ── review battery, top-6 ─────────────────────────────────────")
        let catalog = FoodCatalog.bundled()
        for query in ["burger", "ham", "hot dog", "eggs", "cheese pizza", "cheese", "beef", "onion",
                      "bacon", "turkey", "chicken nuggets", "caesar salad", "chicken noodle soup", "apple"] {
            print("// \"\(query)\":")
            for ranked in catalog.scoredResults(for: query, limit: 6) {
                print("//     \(escaped(ranked.item.name)) — \(ranked.score) \(ranked.item.dataType.rawValue)")
            }
        }
        print("// ── review battery, resolver pools ────────────────────────────")
        for query in ["two slices of pizza", "piece of chicken", "cheese pizza slice"] {
            let pool = catalog.candidates(for: query, limit: 18)
            print("// \"\(query)\": \(pool.count) — \(pool.prefix(4).map { escaped($0.foodItem.name) }.joined(separator: " | "))")
        }
        print("// ── sourceCandidateSetSizes ──────────────────────────────────────")
        guard let source = SQLiteBundledFoodSource(), source.count == shippedRowCount else {
            print("// SKIPPED — shipped catalog did not open")
            return
        }
        for expectation in sourceCandidateSetSizes {
            let live = source.candidates(forQuery: expectation.query).count
            print("(\"\(expectation.query)\", \(live)),\(live == expectation.expected ? "" : "   // ← MOVED")")
        }
    }

    /// Re-measures every resolver-bank entry's pool size and top candidate.
    private static func printLiveResolverBank(_ catalog: FoodCatalog) {
        print("// ── resolverBank ─────────────────────────────────────────────────")
        for entry in resolverBank {
            let pool = catalog.candidates(for: entry.query, limit: 18)
            let top = pool.first?.foodItem.name
            let moved = pool.count != entry.expectedCount || top != entry.expectedTopName
            let name = top.map { "\"\(escaped($0))\"" } ?? "nil"
            print("FoodResolverCase(\"\(entry.query)\", \(pool.count), \(name)),\(moved ? "   // ← MOVED" : "")")
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
