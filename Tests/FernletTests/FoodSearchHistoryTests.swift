// FoodSearchHistoryTests.swift
// FernletTests
//
// Research §26 fix 1.9 (Docs/Food-Search-And-Community-Database-Research-2026-08-22.md, §30 row 9):
// history-first ranking. Four suites, each answering a different question:
//
//   1. `FoodSearchHistoryTests` — the profile itself. §26 prescribes a `log(1 + count)` frequency term
//      and an exponential recency decay at τ ≈ 14–30 days; these pin the curve against the numbers
//      that formula actually produces, and pin the derivation's bounds and its refusals.
//   2. `FoodSearchHistoryRankingTests` — the comparator, over a small deterministic in-memory index.
//      Where the tier sits (above source AND data type), and the two things it must NEVER do: admit a
//      row the floors rejected, or outrank fix 1.7a's dish demotion.
//   3. `FoodSearchHistoryCatalogTests` — the WARMED-STATE BANK, replayed through the REAL shipped
//      118,317-row catalog. Item 8's bank is the pattern: every row pins the COLD top-1 (so a corpus
//      move fails here as a corpus regression, not as a fix-1.9 one) AND the WARM top-1. This is also
//      where the fix's two deliberate boundaries are pinned: the resolver's candidate pool stays cold,
//      and a correction outranks history.
//   4. `FoodSearchHistoryStoreTests` — the store end-to-end: logging a meal warms the live catalog, a
//      wipe cools it in the same process, and the grep-wall that keeps this a DERIVED surface.
//
// WHY A SEPARATE BANK AND NOT NEW CORPUS ROWS. `FoodSearchCorpusTests` measures the COLD pipeline and
// must stay deterministic; history is per-user state. Every catalog built here publishes its profile
// into ITS OWN `FoodCatalog` instance, so nothing here can be seen by another suite — the same
// isolation `FoodSearchCorrectionCatalogTests` documents.
//
// NOTHING HERE IS PERSISTED. Fix 1.9 adds no `UserDefaults` key and no new stored field: the profile
// is derived from `DiaryStore.recentMeals`, which the snapshot already holds. That is why these suites
// need no injected defaults — there is no sidecar to isolate — and why `historyIsDerivedNotStored`
// exists to keep it that way.

import Foundation
import Testing
import DiaryStore
import FernletDomainModel
import FoodCatalog
@testable import AIProviders
@testable import Fernlet

// MARK: - 1. The profile

/// The weighting itself: §26's formula, its bounds, and what it refuses to count.
@Suite
struct FoodSearchHistoryTests {

    /// A meal logged `days` ago whose single component bound to `foodItemID`.
    static func meal(_ foodItemID: UUID?, daysAgo days: Double, now: Date = Date()) -> Meal {
        var meal = Meal(
            name: "Fixture",
            mealType: .lunch,
            macros: Macros(protein: 1, carbs: 1, fat: 1),
            componentSnapshots: [
                MealComponentSnapshot(
                    foodItemId: foodItemID,
                    name: "Fixture component",
                    quantity: 1,
                    unit: RecipeUnit.serving.rawValue,
                    macros: Macros(protein: 1, carbs: 1, fat: 1),
                    micronutrients: Micronutrients()
                )
            ],
            quality: .ok,
            confidence: MealConfidence.logged.token,
            note: "",
            source: MealLogSource.manual
        )
        meal.loggedAt = now.addingTimeInterval(-days * 86_400)
        return meal
    }

    /// §26's formula, pinned at the values it produces. Measured against the shipped implementation on
    /// 2026-08-23; each is also re-derived here from `log`/`exp` so the pin cannot drift into being a
    /// tautology about whatever the code currently does.
    @Test func theWeightCurveIsTheOnePrescribed() {
        let now = Date()
        let cases: [(count: Int, days: Double, expected: Int)] = [
            (1, 0, 693), (1, 7, 497), (3, 0, 1_386), (3, 21, 510), (10, 0, 2_398), (10, 60, 138)
        ]
        for testCase in cases {
            let weight = FoodSearchHistory.scaledWeight(
                count: testCase.count,
                lastLoggedAt: now.addingTimeInterval(-testCase.days * 86_400),
                now: now
            )
            #expect(weight == testCase.expected,
                    "count \(testCase.count) at \(testCase.days)d weighed \(weight), not \(testCase.expected)")
            let derived = FoodSearchHistory.weightScale
                * log(1 + Double(testCase.count))
                * exp(-testCase.days / FoodSearchHistory.recencyDecayDays)
            #expect(abs(Double(weight) - derived) <= 1,
                    "the shipped weight no longer equals log(1+count) · exp(-days/τ) · scale")
        }
        // τ is inside §26's prescribed 14–30 day band, and the decay really is exponential: one τ
        // costs a factor of e.
        #expect((14.0...30.0).contains(FoodSearchHistory.recencyDecayDays))
        let fresh = Double(FoodSearchHistory.scaledWeight(count: 4, lastLoggedAt: now, now: now))
        let oneTau = Double(FoodSearchHistory.scaledWeight(
            count: 4, lastLoggedAt: now.addingTimeInterval(-FoodSearchHistory.recencyDecayDays * 86_400), now: now
        ))
        #expect(abs(fresh / oneTau - M_E) < 0.01, "one τ no longer costs a factor of e")
    }

    /// The floor at 1 is the TIER: however stale, a food the user has eaten still outranks one they
    /// never have. Without it, membership of the history tier would depend on the clock.
    @Test func aStaleFoodKeepsTheTierEvenWhenTheDecayRoundsToZero() {
        let now = Date()
        #expect(FoodSearchHistory.scaledWeight(count: 1, lastLoggedAt: now.addingTimeInterval(-400 * 86_400), now: now) == 1)
        #expect(FoodSearchHistory.scaledWeight(count: 1, lastLoggedAt: .distantPast, now: now) == 1)
        // Never logged is the one weight that is 0 — the thing the tier is measured against.
        #expect(FoodSearchHistory.scaledWeight(count: 0, lastLoggedAt: now, now: now) == 0)
        #expect(FoodSearchHistory.empty.weight(for: UUID()) == 0)
        #expect(FoodSearchHistory.empty.isEmpty)
    }

    /// A clock-skewed or restored-backup meal stamped in the FUTURE must not trap and must not earn
    /// an unbounded weight — the age term is clamped at both ends.
    @Test func aFutureStampedMealIsTreatedAsJustLogged() {
        let now = Date()
        let future = FoodSearchHistory.scaledWeight(count: 2, lastLoggedAt: now.addingTimeInterval(86_400 * 30), now: now)
        #expect(future == FoodSearchHistory.scaledWeight(count: 2, lastLoggedAt: now, now: now))
        #expect(FoodSearchHistory.scaledWeight(count: 2, lastLoggedAt: .distantFuture, now: now) == future)
    }

    /// Frequency orders foods logged equally recently; recency orders foods logged equally often.
    @Test func frequencyAndRecencyBothOrderTheTier() {
        let now = Date()
        let often = UUID(), rarely = UUID(), stale = UUID()
        let meals =
            (0..<5).map { Self.meal(often, daysAgo: Double($0), now: now) }
            + [Self.meal(rarely, daysAgo: 0, now: now)]
            + (0..<5).map { Self.meal(stale, daysAgo: 40 + Double($0), now: now) }
        let history = FoodSearchHistory.from(recentMeals: meals)
        #expect(history.trackedFoodCount == 3)
        #expect(history.weight(for: often, now: now) > history.weight(for: rarely, now: now), "five logs did not outweigh one")
        #expect(history.weight(for: often, now: now) > history.weight(for: stale, now: now), "the same count 40 days ago did not decay below today's")
        #expect(history.weight(for: stale, now: now) > 0, "a decayed food fell out of the tier")
    }

    /// One meal is one eating: a food appearing twice in the same log counts once. And a component
    /// that bound to no catalog food — the keyword-fallback tier's rows — contributes nothing, because
    /// there is no row for it to promote.
    @Test func oneMealCountsAFoodOnceAndUnboundComponentsNotAtAll() {
        let now = Date()
        let food = UUID()
        var doubled = Self.meal(food, daysAgo: 0, now: now)
        doubled.componentSnapshots.append(doubled.componentSnapshots[0])
        let onceWeight = FoodSearchHistory.from(recentMeals: [Self.meal(food, daysAgo: 0, now: now)]).weight(for: food, now: now)
        #expect(FoodSearchHistory.from(recentMeals: [doubled]).weight(for: food, now: now) == onceWeight,
                "the same food twice in one meal counted as two eatings")

        let unbound = FoodSearchHistory.from(recentMeals: [Self.meal(nil, daysAgo: 0, now: now)])
        #expect(unbound.isEmpty, "a component with no foodItemId minted a weight for nothing")
    }

    /// R3 on the READ side: the derivation reads at most its own cap of meals, so a hand-edited or
    /// older-build snapshot cannot hand the ranker an unbounded profile.
    @Test func theDerivationIsBoundedByItsOwnCap() {
        let now = Date()
        let recent = UUID(), beyondTheWindow = UUID()
        let meals =
            (0..<FoodSearchHistory.maximumTrackedMeals).map { _ in Self.meal(recent, daysAgo: 1, now: now) }
            + (0..<20).map { _ in Self.meal(beyondTheWindow, daysAgo: 2, now: now) }
        let history = FoodSearchHistory.from(recentMeals: meals)
        #expect(history.weight(for: recent, now: now) > 0)
        #expect(history.weight(for: beyondTheWindow, now: now) == 0,
                "a meal past the \(FoodSearchHistory.maximumTrackedMeals)-meal window still weighted a food")
        #expect(history.trackedFoodCount == 1)
    }

    /// R2 on the INNER read: an oversized decoded meal cannot make the derivation walk an unbounded
    /// component array or promote a food hidden beyond that boundary.
    @Test func eachMealsComponentReadHasItsOwnCap() {
        let now = Date()
        let inside = UUID(), beyond = UUID()
        var oversized = Self.meal(inside, daysAgo: 0, now: now)
        let component = oversized.componentSnapshots[0]
        oversized.componentSnapshots = Array(
            repeating: component, count: FoodSearchHistory.maximumComponentsPerMeal
        )
        var beyondComponent = component
        beyondComponent.foodItemId = beyond
        oversized.componentSnapshots.append(beyondComponent)

        let history = FoodSearchHistory.from(recentMeals: [oversized])
        #expect(history.weight(for: inside, now: now) > 0)
        #expect(history.weight(for: beyond, now: now) == 0,
                "a component past the explicit per-meal read cap entered history")
        #expect(history.trackedFoodCount == 1)
    }

    /// Derivation retains sufficient statistics, not a weight frozen at publish time. Advancing the
    /// query clock alone changes the ordering once both history rows decay to the tier floor.
    @Test func clockAdvanceRecomputesDecayWithoutAnyMutation() {
        let now = Date()
        let alpha = FoodSearchHistoryRankingTests.food("Granola Alpha Flakes")
        let bravo = FoodSearchHistoryRankingTests.food("Granola Bravo Flakes")
        let meals = [
            Self.meal(alpha.id, daysAgo: 0, now: now),
            Self.meal(bravo.id, daysAgo: 0, now: now),
            Self.meal(bravo.id, daysAgo: 1, now: now)
        ]
        let history = FoodSearchHistory.from(recentMeals: meals)

        let warm = FoodItemSearch.results(
            for: "granola", in: [alpha, bravo], history: history, now: now
        )
        let decayed = FoodItemSearch.results(
            for: "granola", in: [alpha, bravo], history: history,
            now: now.addingTimeInterval(400 * 86_400)
        )
        #expect(warm.first?.id == bravo.id, "frequency did not order the fresh history tier")
        #expect(decayed.first?.id == alpha.id,
                "the unchanged profile kept publish-time weights after the query clock advanced")
    }
}

// MARK: - 2. The comparator

/// Where the tier sits, and the two things it must never do.
///
/// Deterministic in-memory rows rather than the shipped catalog: these are statements about the
/// COMPARATOR, and a fixture of four foods makes each one unambiguous.
@Suite
struct FoodSearchHistoryRankingTests {

    static func food(_ name: String, source: FoodItemSource = .usda, dataType: FoodDataType = .srLegacy) -> FoodItem {
        FoodItem(
            name: name,
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 5, carbs: 10, fat: 2),
            micronutrients: Micronutrients(),
            category: "Fixtures",
            source: source,
            dataType: dataType,
            tags: []
        )
    }

    /// §14's hierarchy: "From History" is tier 1, above Custom and Common. So a BRANDED row the user
    /// has eaten outranks both a manual row and a survey row — the two keys that beat it cold.
    @Test func historyOutranksBothSourceAndDataTypePriority() {
        let branded = Self.food("Granola Bravo Flakes", source: .usda, dataType: .branded)
        let manual = Self.food("Granola Alpha Flakes", source: .manual)
        let survey = Self.food("Granola Charlie Flakes", source: .usda, dataType: .survey)
        let items = [branded, manual, survey]

        let cold = FoodItemSearch.results(for: "granola", in: items, limit: 3)
        #expect(cold.first?.id == manual.id, "precondition: cold ranking must be source-priority-first")

        let warm = FoodItemSearch.results(
            for: "granola", in: items, limit: 3,
            history: FoodSearchHistory(weights: [branded.id: 693])
        )
        #expect(warm.first?.id == branded.id, "the history tier did not outrank sourcePriority")
        // …and the rest of the list keeps its cold order beneath it.
        #expect(warm.dropFirst().map(\.id) == cold.filter { $0.id != branded.id }.map(\.id))
    }

    /// Equal weights — including the 0 vs 0 that every uncorrected comparison is — fall straight
    /// through to the old first key, so an empty profile is a byte-for-byte no-op.
    @Test func anEmptyOrFlatProfileChangesNothing() {
        let items = [Self.food("Granola Alpha Flakes"), Self.food("Granola Bravo Flakes"), Self.food("Granola Charlie Flakes")]
        let cold = FoodItemSearch.results(for: "granola", in: items, limit: 3).map(\.id)
        #expect(FoodItemSearch.results(for: "granola", in: items, limit: 3, history: .empty).map(\.id) == cold)
        let flat = FoodSearchHistory(weights: Dictionary(uniqueKeysWithValues: items.map { ($0.id, 900) }))
        #expect(FoodItemSearch.results(for: "granola", in: items, limit: 3, history: flat).map(\.id) == cold,
                "a profile that weights every row equally must leave the cold ordering alone")
    }

    /// **The load-bearing negative.** A history weight RE-RANKS what retrieval and the floors already
    /// admitted; it can never present a row they refused. Weighting a food that carries none of the
    /// query's tokens changes nothing at all.
    @Test func historyNeverAdmitsARowTheGateOrTheFloorsRejected() {
        let granola = Self.food("Granola Alpha Flakes")
        let unrelated = Self.food("Sardines In Brine")
        let items = [granola, unrelated]
        let warm = FoodItemSearch.results(
            for: "granola", in: items, limit: 6,
            history: FoodSearchHistory(weights: [unrelated.id: 3_000])
        )
        #expect(warm.map(\.id) == [granola.id],
                "a history weight injected a row the match gate rejected — fix 1.9 must re-rank, never inject")
    }

    /// The documented interaction with fix 1.7a, pinned rather than left to be discovered: the dish
    /// demotion runs AFTER the sort, so a history-promoted PREPARED DISH is still sunk beneath the raw
    /// ingredients for a bare-ingredient query.
    ///
    /// Deliberate, and the right way round: 1.7a is §29-coupled and untouchable, and a person who types
    /// "cheese" is asking for cheese even if they often eat a cheese sandwich. The promotion is not
    /// lost — the dish leads the sunk group — so it still outranks every other dish.
    @Test func theDishDemotionStillOutranksTheHistoryTier() {
        let sandwich = Self.food("Cheese sandwich, NFS")
        let otherSandwich = Self.food("Zebra cheese sandwich, NFS")
        let rawCheese = Self.food("Cheese, cheddar")
        let items = [rawCheese, sandwich, otherSandwich]
        #expect(PreparedDishHeuristic.isPreparedDish(sandwich), "precondition: the fixture is not a prepared dish")
        #expect(!PreparedDishHeuristic.isPreparedDish(rawCheese), "precondition: the raw fixture reads as a dish")

        let warm = FoodItemSearch.results(
            for: "cheese", in: items, limit: 6,
            history: FoodSearchHistory(weights: [sandwich.id: 2_000])
        )
        #expect(warm.first?.id == rawCheese.id,
                "a history-promoted prepared dish outranked the raw ingredient — fix 1.7a's demotion is no longer applied after the history sort")
        #expect(warm.dropFirst().first?.id == sandwich.id,
                "the promotion was lost entirely: within the sunk dishes the user's own should still lead")
    }
}

// MARK: - 3. The warmed-state bank, over the shipped catalog

/// One bank row: a query, what it answers COLD, and the food a person who eats it would have logged.
struct FoodSearchHistoryCase: Sendable {
    /// The typed query.
    let query: String
    /// The catalog row ranked first today, with no history — the corpus's own pin.
    let coldTopName: String
    /// The food this user has been logging, resolved by exact normalized name against the shipped
    /// catalog. After one meal it is what the query returns first.
    let loggedName: String
    /// Why this row is in the bank.
    let note: String

    init(_ query: String, cold coldTopName: String, logged loggedName: String, _ note: String) {
        self.query = query
        self.coldTopName = coldTopName
        self.loggedName = loggedName
        self.note = note
    }
}

/// Fix 1.9 replayed through the REAL shipped catalog, plus the fix's two deliberate boundaries.
@Suite
struct FoodSearchHistoryCatalogTests {

    /// Row count of the shipped catalog, mirrored from `FoodSearchCorpusTests` so every test here
    /// guards on it and none can pass vacuously against `FoodCatalog.bundled()`'s empty fallback.
    static let shippedRowCount = 118_317

    /// The bank. Cold pins are the corpus's own — if one disagrees, the corpus moved and this bank is
    /// measuring a tree that no longer exists. The three rows deliberately span the three DISTANCES a
    /// promotion can travel, because they fail differently: within a tier, across one, and from deep
    /// below the fold.
    static let bank: [FoodSearchHistoryCase] = [
        FoodSearchHistoryCase(
            "chicken breast", cold: "Chicken breast, stewed, skin eaten", logged: "Chicken, breast, boneless, skinless, raw",
            "SAME data-type tier, cold rank 2. The corpus's own wrong-top-1: nobody typing this means stewed-with-skin, and the row a person who cooks chicken breast actually logs is one place below it. The cheapest possible win, and it needs no new data"
        ),
        FoodSearchHistoryCase(
            "mozzarella cheese", cold: "DENNY'S, mozzarella cheese sticks", logged: "Mozzarella Cheese",
            "ACROSS tiers, cold rank ~9. §31 says fix 1.7a explicitly does NOT deliver this query (the branded row sits behind two data-type tiers) and §26 gives it to fix 1.10 — one CORRECTION. This is the same repair with no correction and no tap: the user simply ate mozzarella once"
        ),
        FoodSearchHistoryCase(
            "greek yogurt", cold: "Yogurt, Greek, plain, lowfat", logged: "Greek Yogurt, Plain",
            "DEEP — cold rank 39, three tiers and six pages down, i.e. past the `limit: 6` every surface truncates at. §14's own example ('the same yogurt every morning'); a post-hoc reorder of the visible six could never reach it, which is why the tier is in the comparator and not applied afterwards"
        )
    ]

    private static func catalog(history: FoodSearchHistory = .empty, aliases: [String: UUID] = [:]) throws -> FoodCatalog {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == shippedRowCount, "shipped catalog must be loaded — this suite must never pass vacuously")
        catalog.setSearchHistory(history)
        catalog.setSearchAliases(aliases)
        return catalog
    }

    private static func item(_ name: String, in catalog: FoodCatalog) throws -> FoodItem {
        try #require(catalog.exactNameMatch(forNormalized: FoodItemSearch.normalized(name)),
                     "the bank names a row the shipped catalog does not have: \(name)")
    }

    /// The bank: every row's COLD top-1 is what the corpus pins, and every row's WARM top-1 is the
    /// food this user logs — reached from wherever it sat, including below the caller's `limit`.
    @Test func warmedBankReplaysToTheLoggedFood() throws {
        let cold = try Self.catalog()
        for bankCase in Self.bank {
            let logged = try Self.item(bankCase.loggedName, in: cold)
            #expect(cold.results(for: bankCase.query, limit: 6, context: .userTyped).first?.name == bankCase.coldTopName,
                    "the COLD answer moved for \"\(bankCase.query)\" — that is a corpus regression, not a fix-1.9 one")

            let warm = try Self.catalog(history: FoodSearchHistory(weights: [logged.id: 693]))
            let warmTop = warm.results(for: bankCase.query, limit: 6, context: .userTyped).first
            #expect(warmTop?.id == logged.id, "one logged meal did not reach the top of \"\(bankCase.query)\" — \(bankCase.note)")
            #expect(warmTop?.name == bankCase.loggedName)
        }
    }

    /// The claim the bank's third row exists for, asserted directly: the promotion crosses the
    /// `limit: 6` truncation every search surface applies, so it can surface a row the user could not
    /// otherwise have seen without paging.
    @Test func aPromotionReachesBelowTheFold() throws {
        let cold = try Self.catalog()
        let logged = try Self.item("Greek Yogurt, Plain", in: cold)
        let visible = cold.results(for: "greek yogurt", limit: 6, context: .userTyped).map(\.id)
        #expect(!visible.contains(logged.id), "precondition: the row is already visible cold, so this proves no lift")
        let warm = try Self.catalog(history: FoodSearchHistory(weights: [logged.id: 693]))
        #expect(warm.results(for: "greek yogurt", limit: 6, context: .userTyped).first?.id == logged.id)
    }

    /// A re-rank never lengthens the list, never duplicates the promoted row, and leaves the relative
    /// order of everything else alone.
    @Test func historyReRanksWithoutLengtheningOrDuplicating() throws {
        let cold = try Self.catalog()
        let logged = try Self.item("Mozzarella Cheese", in: cold)
        let coldRows = cold.results(for: "mozzarella cheese", limit: 6, context: .userTyped)
        let warm = try Self.catalog(history: FoodSearchHistory(weights: [logged.id: 693]))
        let warmRows = warm.results(for: "mozzarella cheese", limit: 6, context: .userTyped)

        #expect(warmRows.count == coldRows.count, "the promotion changed the list length")
        #expect(warmRows.filter { $0.id == logged.id }.count == 1, "the promoted row appears twice")
        #expect(warm.results(for: "mozzarella cheese", limit: 1, context: .userTyped).count == 1)
    }

    /// **Boundary 1 — the resolver's candidate pool stays COLD.** This is fix 1.9's one deliberate
    /// narrowing of §26's "a tier at the top of the comparator", and the reasons are in
    /// `FoodCatalog.results`' doc. It is asserted with a profile weighting TWENTY foods, because the
    /// density is the whole argument: a correction promotes one row per fired phrase, a history
    /// profile would promote on nearly every phrase in the description.
    @Test func theResolverCandidatePoolStaysCold() throws {
        let cold = try Self.catalog()
        var weights: [UUID: Int] = [:]
        for item in cold.results(for: "cheese", limit: 40, context: .userTyped).prefix(20) { weights[item.id] = 2_000 }
        try #require(weights.count == 20, "the seeding query returned too few rows to make this test dense")
        let warm = try Self.catalog(history: FoodSearchHistory(weights: weights))

        for description in ["cheese pizza slice", "burger and fries", "greek yogurt with berries"] {
            #expect(warm.candidates(for: description, limit: 18).map(\.foodItem.id)
                        == cold.candidates(for: description, limit: 18).map(\.foodItem.id),
                    "history reached the resolver pool for \"\(description)\" — the sub-phrase narrowing in FoodCatalog.results is gone, and every bind-firewall proof now measures a pool this fix moved")
        }
    }

    /// The context is explicit and independent of stopword policy: typed searches stay warm even
    /// when they retain stopwords, while machine searches stay cold even when they strip them.
    @Test func typedVersusMachineContextDoesNotRideOnStopwordStripping() throws {
        let cold = try Self.catalog()
        let logged = try Self.item("Greek Yogurt, Plain", in: cold)
        let warm = try Self.catalog(history: FoodSearchHistory(weights: [logged.id: 3_000]))

        let typed = warm.results(
            for: "greek yogurt", limit: 1, stripsStopwords: false, context: .userTyped
        )
        let machine = warm.results(
            for: "greek yogurt", limit: 1, stripsStopwords: true, context: .machineGenerated
        )
        #expect(typed.first?.id == logged.id, "typed search lost history when stopwords were retained")
        #expect(machine.first?.name == "Yogurt, Greek, plain, lowfat",
                "machine search inherited history merely because it stripped stopwords")
    }

    /// Recipe ingredient names are parser-produced machine queries. A warm profile may change the
    /// interactive result, but must not change the importer's macro estimate.
    @Test func recipeImportEstimationStaysCold() throws {
        var alpha = FoodSearchHistoryRankingTests.food("Flour Alpha")
        var bravo = FoodSearchHistoryRankingTests.food("Flour Bravo")
        alpha.macros = Macros(protein: 1, carbs: 2, fat: 3)
        bravo.macros = Macros(protein: 90, carbs: 80, fat: 70)
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([alpha, bravo]))
        catalog.setSearchHistory(FoodSearchHistory(weights: [bravo.id: 3_000]))
        #expect(catalog.results(for: "flour", limit: 1, context: .userTyped).first?.id == bravo.id,
                "precondition: the warm profile did not discriminate the importer test")

        let estimate = try #require(RecipeWebImporter.estimateMacrosFromIngredients(
            ["1 flour"], servings: 1, catalog: catalog
        ))
        #expect(estimate == (1, 2, 3), "recipe estimation consumed the typed history tier")
    }

    @Test func recipeImportEstimationRejectsMatchedUnsupportedConversion() {
        let ramen = FoodSearchHistoryRankingTests.food("Ramen")
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([ramen]))
        #expect(RecipeWebImporter.estimateMacrosFromIngredients(
            ["1 each ramen"], servings: 1, catalog: catalog
        ) == nil)
    }

    /// **Boundary 2 — `scoredResults` is cold, structurally.** `FoodItemSearch.scoredResults` has no
    /// `history` parameter at all, so this is a regression pin on the seam rather than on a
    /// convention: every confidence gate that reads a score reads the same score it read before.
    @Test func theScoredSurfaceStaysCold() throws {
        let cold = try Self.catalog()
        let logged = try Self.item("Mozzarella Cheese", in: cold)
        let warm = try Self.catalog(history: FoodSearchHistory(weights: [logged.id: 3_000]))
        let coldScored = cold.scoredResults(for: "mozzarella cheese", limit: 6)
        let warmScored = warm.scoredResults(for: "mozzarella cheese", limit: 6)
        #expect(warmScored.map(\.item.id) == coldScored.map(\.item.id))
        #expect(warmScored.map(\.score) == coldScored.map(\.score))
        #expect(warmScored.first?.item.id != logged.id)
    }

    /// **Precedence: a CORRECTION outranks HISTORY.** A correction is an explicit statement made by a
    /// person looking at the wrong answer; history is an inference from behaviour, and an inference
    /// must not overrule a statement. Pinned here rather than left to the order the two happen to be
    /// applied in.
    @Test func aCorrectionOutranksTheHistoryTier() throws {
        let cold = try Self.catalog()
        let rows = cold.results(for: "greek yogurt", limit: 40, context: .userTyped)
        let loggedOften = rows[20]
        let corrected = rows[30]
        let warm = try Self.catalog(
            history: FoodSearchHistory(weights: [loggedOften.id: 3_000]),
            aliases: ["greek yogurt": corrected.id]
        )
        let ranked = warm.results(for: "greek yogurt", limit: 6, context: .userTyped)
        #expect(ranked.first?.id == corrected.id, "history overruled an explicit correction")
        #expect(ranked.dropFirst().first?.id == loggedOften.id,
                "the history tier lost its place beneath the correction — the two signals must compose, not replace each other")
    }

    /// The corpus's determinism guarantee: a catalog nobody has hydrated carries no history, so every
    /// cold measurement in `FoodSearchCorpusTests` is independent of what this device has eaten.
    @Test func aFreshCatalogIsColdSoTheCorpusStaysDeterministic() throws {
        let seeded = try Self.catalog()
        let logged = try Self.item("Greek Yogurt, Plain", in: seeded)
        seeded.setSearchHistory(FoodSearchHistory(weights: [logged.id: 3_000]))
        #expect(seeded.results(for: "greek yogurt", limit: 1, context: .userTyped).first?.id == logged.id)

        let fresh = FoodCatalog.bundled()
        try #require(fresh.bundledCount == Self.shippedRowCount)
        #expect(fresh.results(for: "greek yogurt", limit: 1, context: .userTyped).first?.name == "Yogurt, Greek, plain, lowfat",
                "a history profile planted in one catalog leaked into another — the corpus is no longer deterministic")
    }
}

// MARK: - 4. The store, end to end

/// The live wiring: a logged meal warms the catalog in the same process, a wipe cools it in the same
/// process, and nothing durable was added to make either happen.
@MainActor
@Suite
struct FoodSearchHistoryStoreTests {

    /// Two foods that score IDENTICALLY for "granola" — same length, same tier, same source — so the
    /// cold order is decided by the comparator's last key (the name) and any change to it is the
    /// history tier and nothing else.
    static func granolaPair() -> (alpha: FoodItem, bravo: FoodItem) {
        (FoodSearchHistoryRankingTests.food("Granola Alpha Flakes"),
         FoodSearchHistoryRankingTests.food("Granola Bravo Flakes"))
    }

    static func meal(binding food: FoodItem) -> Meal {
        Meal(
            name: food.name,
            mealType: .breakfast,
            macros: Macros(protein: 5, carbs: 10, fat: 2),
            componentSnapshots: [
                MealComponentSnapshot(
                    foodItemId: food.id,
                    name: food.name,
                    quantity: 1,
                    unit: RecipeUnit.serving.rawValue,
                    macros: Macros(protein: 5, carbs: 10, fat: 2),
                    micronutrients: Micronutrients()
                )
            ],
            quality: .ok,
            confidence: MealConfidence.logged.token,
            note: "",
            source: MealLogSource.manual
        )
    }

    /// The whole feature in one test: log the meal, search again, get your own food first.
    @Test func loggingAMealPromotesItsFoodOnTheNextSearch() {
        let (alpha, bravo) = Self.granolaPair()
        let store = makeTestStore(bundledFoodItems: [alpha, bravo])
        #expect(store.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == alpha.id,
                "precondition: cold, the alphabetical tie-break wins")

        store.diary.appendMeal(Self.meal(binding: bravo), date: store.todayKey)
        #expect(store.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == bravo.id,
                "the meal the user just logged did not warm the live catalog")
    }

    /// Repeat logging is a real log: it enters the newest-first window, adds one use to frequency,
    /// and its fresh timestamp participates in recency ordering on the very next query.
    @Test func repeatLoggingUpdatesFrequencyAndRecencyOrdering() {
        let now = Date()
        let (alpha, bravo) = Self.granolaPair()
        let store = makeTestStore(bundledFoodItems: [alpha, bravo])
        var oldAlpha = Self.meal(binding: alpha)
        oldAlpha.loggedAt = now.addingTimeInterval(-20 * 86_400)
        var recentBravo = Self.meal(binding: bravo)
        recentBravo.loggedAt = now.addingTimeInterval(-2 * 86_400)
        var secondBravo = Self.meal(binding: bravo)
        secondBravo.loggedAt = now.addingTimeInterval(-3 * 86_400)
        store.diary.appendMeal(oldAlpha, date: store.todayKey)
        store.diary.appendMeal(recentBravo, date: store.todayKey)
        store.diary.appendMeal(secondBravo, date: store.todayKey)
        #expect(store.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == bravo.id,
                "precondition: two recent Bravo logs did not lead one stale Alpha log")
        let before = FoodSearchHistory.from(recentMeals: store.diary.recentMeals)
            .weight(for: alpha.id, now: now)

        let copied = store.diary.copyMeal(oldAlpha, mealType: .breakfast)
        let afterNow = Date()
        let after = FoodSearchHistory.from(recentMeals: store.diary.recentMeals)
        let alphaUses = store.diary.recentMeals.filter {
            $0.componentSnapshots.contains { $0.foodItemId == alpha.id }
        }.count
        #expect(store.diary.recentMeals.first?.id == copied.id, "the repeat was not most recent")
        #expect(alphaUses == 2, "the repeat did not add a second Alpha use")
        #expect(after.weight(for: alpha.id, now: afterNow) > before,
                "the repeat did not update the frequency/recency weight")
        #expect(after.weight(for: alpha.id, now: afterNow) > after.weight(for: bravo.id, now: afterNow))
        #expect(store.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == alpha.id,
                "the repeated food did not lead the next typed search")
    }

    /// The concrete FoodView typeahead opts into typed context, so its detached/debounced path sees
    /// the same warm ranking as direct interactive search.
    @Test func foodViewTypeaheadRemainsWarm() async throws {
        let (alpha, bravo) = Self.granolaPair()
        let catalog = FoodCatalog(source: InMemoryBundledFoodSource([alpha, bravo]))
        catalog.setSearchHistory(FoodSearchHistory(weights: [bravo.id: 3_000]))
        let matches = try #require(await CatalogTypeahead.matches(for: "granola", catalog: catalog))
        #expect(matches.first?.id == bravo.id)
    }

    /// The "deleted but still there" hazard fix 1.10 documents, closed for fix 1.9 by the SAME
    /// mechanism that publishes: `resetDiary` empties `recentMeals`, whose `didSet` publishes the
    /// empty profile. Without it the wipe would leave the live catalog ranking the deleted meals'
    /// foods first until the app relaunched.
    @Test func aWipeCoolsTheCatalogInTheSameProcess() {
        let (alpha, bravo) = Self.granolaPair()
        let store = makeTestStore(bundledFoodItems: [alpha, bravo])
        store.diary.appendMeal(Self.meal(binding: bravo), date: store.todayKey)
        #expect(store.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == bravo.id)

        _ = store.resetAll()
        #expect(store.diary.recentMeals.isEmpty)
        // The user items go with the wipe, so re-publish them to isolate what is being measured:
        // whether the HISTORY still promotes, not whether the rows still exist.
        store.foodCatalog.setUserItems([alpha, bravo])
        #expect(store.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == alpha.id,
                "a wipe left the live catalog promoting the deleted meal's food")
    }

    /// A second store over the same repository — the relaunch shape — derives the profile AT INIT, so
    /// the first keystroke of a session is already warm rather than warming only after that session's
    /// first meal write. A `didSet` does not fire for an initializer's own assignment, which is exactly
    /// the hole this covers.
    ///
    /// The two foods are the user's OWN here (`.manual`), because a relaunched store's catalog is
    /// rebuilt from the snapshot: that is what carries them across, and it leaves both rows in the same
    /// source tier so the cold order is still decided by the name.
    @Test func aRelaunchDerivesTheProfileWithoutAnyWrite() {
        let alpha = FoodSearchHistoryRankingTests.food("Granola Alpha Flakes", source: .manual)
        let bravo = FoodSearchHistoryRankingTests.food("Granola Bravo Flakes", source: .manual)
        let bundle = makeTestStoreWithRepositories()
        bundle.store.diary.foodItems = [alpha, bravo]
        #expect(bundle.store.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == alpha.id,
                "precondition: cold, the alphabetical tie-break wins")
        bundle.store.diary.appendMeal(Self.meal(binding: bravo), date: bundle.store.todayKey)
        bundle.store.flushPendingSnapshotSave()

        let relaunched = makeStoreSharingStores(repository: bundle.repository, narratives: bundle.narratives)
        #expect(relaunched.diary.recentMeals.isEmpty == false, "precondition: the meal did not persist, so nothing is being measured")
        #expect(relaunched.foodCatalog.results(for: "granola", limit: 2, context: .userTyped).first?.id == bravo.id,
                "a relaunched store ranked cold until its first meal write — the init-time publish beside setUserItems is missing")
    }

    /// **The bounded topology wall for a fix that deliberately persists NOTHING.**
    ///
    /// §26's Risk column and §30 row 9's gate both assume fix 1.9 adds a stored usage ledger and
    /// therefore a `Docs/PrivacyWipeCoverage.md` disposition row. It does not: the profile is derived
    /// from `DiaryStore.recentMeals`, which the synced snapshot already holds and every wipe already
    /// clears. This scan pins the two derivation sites, the publisher types, and the exact proposed
    /// defaults-key spelling. It does not claim to prove the absence of arbitrarily renamed storage;
    /// behavioral wipe coverage above remains the durable guarantee.
    @Test func historyIsDerivedNotStored() throws {
        let root = RepoRoot.url
        let sources = try Self.swiftFiles(under: root.appendingPathComponent("App"))
            + Self.swiftFiles(under: root.appendingPathComponent("FernletKit/Sources"))
        #expect(sources.count > 50, "the scan found \(sources.count) files — it would pass by looking at almost nothing")

        var derivationSites: [String] = []
        var publishSites: [String] = []
        for url in sources {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let code = FoodSearchCorrectionWipeTests.strippingLineComments(text)
            derivationSites.append(contentsOf: Array(repeating: url.lastPathComponent, count: code.components(separatedBy: "FoodSearchHistory.from(").count - 1))
            publishSites.append(contentsOf: Array(repeating: url.lastPathComponent, count: code.components(separatedBy: "setSearchHistory(").count - 1))
            // Exact-key regression guard; deliberately not represented as a general persistence proof.
            #expect(!code.contains("foodSearchHistory\""), "\(url.lastPathComponent) mints the proposed defaults key for the history profile — a stored profile needs a Docs/PrivacyWipeCoverage.md row, a wipe leg and a resurrection audit")
        }
        // Two derivations, both in DiaryStore: the `didSet` and the init-time publish it cannot fire for.
        #expect(derivationSites == ["DiaryStore.swift", "DiaryStore.swift"],
                "the history profile is derived somewhere new: \(derivationSites). Every derivation is a place the wipe has to reach")
        // Publishers: the same two, plus the catalog's own declaration.
        #expect(Set(publishSites) == ["DiaryStore.swift", "FoodCatalog.swift"],
                "a new publisher of the history profile: \(Set(publishSites))")
    }

    /// Every shipping `.swift` file under `directory`.
    private static func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        guard let files = enumerator?.compactMap({ $0 as? URL }).filter({ $0.pathExtension == "swift" }) else {
            throw FoodSearchHistoryScanError.unreadableDirectory(directory.lastPathComponent)
        }
        return files
    }
}

/// Failure modes of the derived-surface scan above.
enum FoodSearchHistoryScanError: Error {
    /// A scan root could not be enumerated.
    case unreadableDirectory(String)
}
