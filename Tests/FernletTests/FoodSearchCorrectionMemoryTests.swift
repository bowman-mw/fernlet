// FoodSearchCorrectionMemoryTests.swift
// FernletTests
//
// Research §26 fix 1.10 (§30 row 8) — the local correction memory: the search a person corrects once
// answers with their own choice thereafter, on this device only.
//
// THREE SUITES, AND WHY THEY ARE SEPARATE.
//
//   • `FoodSearchCorrectionMemoryTests` — the persisted sidecar as a value: normalization, the
//     one-answer-per-query rule, the R3 cap, the wipe, and a corrupt read.
//   • `FoodSearchCorrectionCatalogTests` — **the warmed-state bank**, deliberately a SEPARATE bank
//     from `FoodSearchCorpusTests`. Correction memory is per-user state, and the 57-query corpus
//     measures the COLD pipeline; mixing warmed rows into it would make the instrument depend on
//     which corrections a test happened to plant. So the corpus stays cold (a freshly built
//     `FoodCatalog` carries no aliases at all — `aFreshCatalogIsColdSoTheCorpusStaysDeterministic`
//     pins exactly that) and every warmed measurement lives here, each row carrying BOTH the cold
//     pin it starts from and the warm pin the correction produces. A row that moves cold is a corpus
//     regression; a row that stops moving warm is a fix-1.10 regression.
//   • `FoodSearchCorrectionWipeTests` — the discriminating wipe test the persisted-surface wall
//     requires, plus the resurrection audit (a source scan over every writer).
//
//   • `FoodSearchCorrectionResolverFirewallTests` — added by the 2026-08-23 review (findings M4/M5):
//     what actually stops a promoted correction from BINDING and from auto-committing, pinned at the
//     three seams that carry it rather than at the one that merely abstains.
//
// VERIFY-BATCH NOTE, in the house pattern of `PrivacyWipeCoverageTests`: this file declares FOUR
// top-level suites and `-only-testing:` matches suite identifiers EXACTLY, so a run scoped to one of
// them silently skips the others. Name all four.

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
import AIProviders
@testable import Fernlet

// MARK: - The persisted sidecar

/// The device-local correction sidecar as a value: what it stores, what it refuses, and how it is
/// bounded.
///
/// Every test injects its own `UserDefaults` suite — the sidecar's identity is a suite, and
/// `.standard` is process-global under the test runner, so sharing it would make these tests read
/// each other's corrections (the `test-store per-instance sidecars` lesson).
@Suite
struct FoodSearchCorrectionMemoryTests {

    /// A throwaway defaults suite for one test, removed when the test ends.
    private static func makeDefaults() -> (defaults: UserDefaults, name: String) {
        let name = "fernlet.tests.foodCorrections.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name) ?? .standard, name)
    }

    @Test func correctionNormalizesTheQueryAndRejectsTextTooShortToSearch() {
        let id = UUID()
        #expect(FoodSearchCorrection(searchText: "  Mozzarella   CHEESE! ", foodItemID: id)?.query == "mozzarella cheese",
                "the key must be the same fold FoodCatalog.results keys on, or the alias never fires")
        // The searcher itself returns nothing below `minimumQueryLength`; an alias must not become a
        // back door that makes two characters resolve to a food.
        #expect(FoodSearchCorrection(searchText: "ab", foodItemID: id) == nil)
        #expect(FoodSearchCorrection(searchText: "   ", foodItemID: id) == nil)
        #expect(FoodSearchCorrection(searchText: "!!", foodItemID: id) == nil)
    }

    @Test func rememberedCorrectionsRoundTripAsAliases() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let pizza = UUID()
        let cheese = UUID()
        FoodSearchCorrectionMemory.remember(
            [FoodSearchCorrection(searchText: "costco cheese pizza slice", foodItemID: pizza),
             FoodSearchCorrection(searchText: "Mozzarella cheese", foodItemID: cheese)].compactMap { $0 },
            defaults: defaults
        )
        let aliases = FoodSearchCorrectionMemory.aliases(defaults: defaults)
        #expect(aliases["costco cheese pizza slice"] == pizza)
        #expect(aliases["mozzarella cheese"] == cheese)
        #expect(aliases.count == 2)
    }

    @Test func reCorrectingAQueryKeepsOnlyTheNewestAnswer() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let first = UUID()
        let second = UUID()
        FoodSearchCorrectionMemory.remember([FoodSearchCorrection(searchText: "greek yogurt", foodItemID: first)].compactMap { $0 }, defaults: defaults)
        FoodSearchCorrectionMemory.remember([FoodSearchCorrection(searchText: "greek yogurt", foodItemID: second)].compactMap { $0 }, defaults: defaults)
        let aliases = FoodSearchCorrectionMemory.aliases(defaults: defaults)
        #expect(aliases.count == 1, "a re-correction must REPLACE the earlier answer, not accumulate beside it")
        #expect(aliases["greek yogurt"] == second, "the newest correction is the one the user just made")
    }

    /// R3: the memory is bounded at the point of insertion, oldest-out — and re-correcting an old
    /// query REFRESHES it, so a query someone keeps fixing is never the one evicted.
    @Test func theMemoryIsCappedAndEvictsOldestFirst() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let cap = FoodSearchCorrectionMemory.maxRememberedCorrections
        for index in 0..<cap {
            FoodSearchCorrectionMemory.remember(
                [FoodSearchCorrection(searchText: "query number \(index)", foodItemID: UUID())].compactMap { $0 },
                defaults: defaults
            )
        }
        #expect(FoodSearchCorrectionMemory.aliases(defaults: defaults).count == cap)

        // Refresh the oldest, then overflow by one: the refreshed entry survives and the SECOND
        // oldest goes.
        let refreshed = UUID()
        FoodSearchCorrectionMemory.remember([FoodSearchCorrection(searchText: "query number 0", foodItemID: refreshed)].compactMap { $0 }, defaults: defaults)
        FoodSearchCorrectionMemory.remember([FoodSearchCorrection(searchText: "one more query", foodItemID: UUID())].compactMap { $0 }, defaults: defaults)
        let aliases = FoodSearchCorrectionMemory.aliases(defaults: defaults)
        #expect(aliases.count == cap, "the memory grew past its documented cap")
        #expect(aliases["query number 0"] == refreshed)
        #expect(aliases["query number 1"] == nil, "eviction is not oldest-first")
        #expect(aliases["one more query"] != nil)
    }

    @Test func clearAllRemovesEveryCorrection() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        FoodSearchCorrectionMemory.remember([FoodSearchCorrection(searchText: "black coffee", foodItemID: UUID())].compactMap { $0 }, defaults: defaults)
        #expect(!FoodSearchCorrectionMemory.aliases(defaults: defaults).isEmpty)
        FoodSearchCorrectionMemory.clearAll(defaults: defaults)
        #expect(FoodSearchCorrectionMemory.aliases(defaults: defaults).isEmpty)
        #expect(defaults.object(forKey: FoodSearchCorrectionMemory.defaultsKey) == nil,
                "the key itself must go, not just its contents — a surviving key is a surviving surface")
    }

    /// A corrupt or foreign value under the key reads as "nothing corrected yet" rather than
    /// throwing: this memory is an optimization, never a source of truth.
    @Test func malformedStoredDataReadsAsEmpty() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("not json", forKey: FoodSearchCorrectionMemory.defaultsKey)
        #expect(FoodSearchCorrectionMemory.aliases(defaults: defaults).isEmpty)
        defaults.set(Data("{".utf8), forKey: FoodSearchCorrectionMemory.defaultsKey)
        #expect(FoodSearchCorrectionMemory.aliases(defaults: defaults).isEmpty)
        // …and a later legitimate write still lands on top of the garbage.
        let id = UUID()
        FoodSearchCorrectionMemory.remember([FoodSearchCorrection(searchText: "brown rice", foodItemID: id)].compactMap { $0 }, defaults: defaults)
        #expect(FoodSearchCorrectionMemory.aliases(defaults: defaults)["brown rice"] == id)
    }

    /// R3 on the read side: an over-long stored list (hand-edited, or written by a build with a
    /// larger cap) is truncated to the newest `maxRememberedCorrections` rather than reinstating an
    /// unbounded map into the catalog.
    @Test func anOverlongStoredListIsTruncatedOnRead() throws {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        let cap = FoodSearchCorrectionMemory.maxRememberedCorrections
        let oversized = (0..<(cap + 25)).compactMap { FoodSearchCorrection(searchText: "planted query \($0)", foodItemID: UUID()) }
        defaults.set(try JSONEncoder().encode(oversized), forKey: FoodSearchCorrectionMemory.defaultsKey)
        let aliases = FoodSearchCorrectionMemory.aliases(defaults: defaults)
        #expect(aliases.count == cap)
        #expect(aliases["planted query 0"] == nil, "the OLDEST entries are the ones dropped")
        #expect(aliases["planted query \(cap + 24)"] != nil)
    }

    @Test func rememberingNothingWritesNothing() {
        let (defaults, name) = Self.makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }
        FoodSearchCorrectionMemory.remember([], defaults: defaults)
        #expect(defaults.object(forKey: FoodSearchCorrectionMemory.defaultsKey) == nil)
    }
}

// MARK: - The warmed-state bank

/// One warmed measurement: a query, the row today's COLD pipeline puts first, and the row the user's
/// own one-tap correction puts first instead.
///
/// `coldTopName` is `nil` exactly when the query returns nothing at all today — three of the four
/// queries §34 still counts as zero-result are brand-index or typo failures that no ranking change
/// can reach, which is precisely what makes them the honest demonstration of this fix.
struct FoodSearchCorrectionCase: Sendable {
    /// The query. A **frozen English matching input** (localization wall) — it is folded by
    /// `FoodItemSearch.normalized` and matched against an FTS index baked in English.
    let query: String
    /// The catalog row ranked first today, or nil for a zero-result query.
    let coldTopName: String?
    /// The row the user picks in "Adjust meal" — and, after one correction, the row this query
    /// returns first. Resolved by exact normalized name against the shipped catalog.
    let correctedTopName: String
    /// Why this row is in the bank.
    let note: String

    init(_ query: String, cold coldTopName: String?, corrected correctedTopName: String, _ note: String) {
        self.query = query
        self.coldTopName = coldTopName
        self.correctedTopName = correctedTopName
        self.note = note
    }
}

/// The warmed-state bank for fix 1.10, replayed through the REAL shipped catalog.
///
/// Deliberately not part of `FoodSearchCorpusTests`: see this file's header. Nothing here plants a
/// correction into a catalog any other suite can see — each test builds its own `FoodCatalog` and
/// publishes aliases into that instance only.
@Suite
struct FoodSearchCorrectionCatalogTests {

    /// Row count of the shipped catalog, mirrored from `FoodSearchCorpusTests` so every test here
    /// guards on it and none can pass vacuously against `FoodCatalog.bundled()`'s empty fallback.
    static let shippedRowCount = 118_317

    /// The bank. Cold pins are the corpus's own (`FoodSearchCorpusTests.corpus` /
    /// `namedRankingPins`) — if one of these disagrees, the corpus moved and this bank is measuring
    /// a tree that no longer exists.
    static let bank: [FoodSearchCorrectionCase] = [
        FoodSearchCorrectionCase(
            "mozzarella cheese", cold: "DENNY'S, mozzarella cheese sticks", corrected: "Mozzarella Cheese",
            "§31's promise for this query is explicitly NOT delivered by fix 1.7a (the branded row scoring 1870 sits behind two data-type tiers). One correction delivers it, which is the whole claim of fix 1.10"
        ),
        FoodSearchCorrectionCase(
            "costco cheese pizza slice", cold: nil, corrected: "Sliced Pizza, Cheese",
            "the query the research opens with. It returns NOTHING today because `costco` lives in the unindexed `brand_source` column (→ fix 2.3), and §31's '+1.10' row is exactly this: correct it once and it is self-healing"
        ),
        FoodSearchCorrectionCase(
            "chiken breast", cold: "Chicken breast, stewed, skin eaten", corrected: "Chicken, breast, boneless, skinless, raw",
            "the corpus's typo query. It used to return NOTHING; since ab6e573's bounded leave-one-out fallback it returns a row on the surviving `breast` token — a wrong one, because there is still no edit-distance anywhere in the pipeline (§30 row 16) and `chiken` matches nothing. The claim is unchanged and now sharper: the typo reaches an answer the user did not mean, and one correction is also a typo memory, at no extra cost"
        )
    ]

    /// A catalog over the shipped rows, with `aliases` published into it (empty = the cold path).
    private static func catalog(aliases: [String: UUID] = [:]) throws -> FoodCatalog {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == shippedRowCount, "shipped catalog must be loaded — this suite must never pass vacuously")
        catalog.setSearchAliases(aliases)
        return catalog
    }

    /// The food a user would pick, resolved by exact normalized name.
    private static func correctedItem(_ name: String, in catalog: FoodCatalog) throws -> FoodItem {
        try #require(catalog.exactNameMatch(forNormalized: FoodItemSearch.normalized(name)),
                     "the bank names a row the shipped catalog does not have: \(name)")
    }

    /// The bank: every row's COLD top-1 is what the corpus pins, and every row's WARM top-1 is the
    /// user's own correction.
    @Test func warmedBankReplaysToThePinnedCorrections() throws {
        let cold = try Self.catalog()
        for bankCase in Self.bank {
            let corrected = try Self.correctedItem(bankCase.correctedTopName, in: cold)
            let coldTop = cold.results(for: bankCase.query, limit: 6, context: .userTyped).first?.name
            #expect(coldTop == bankCase.coldTopName, "the COLD answer moved for \"\(bankCase.query)\" — that is a corpus regression, not a fix-1.10 one")

            let warm = try Self.catalog(aliases: [FoodItemSearch.normalized(bankCase.query): corrected.id])
            let warmTop = warm.results(for: bankCase.query, limit: 6, context: .userTyped).first
            #expect(warmTop?.id == corrected.id, "one correction did not self-heal \"\(bankCase.query)\" — \(bankCase.note)")
            #expect(warmTop?.name == bankCase.correctedTopName)
        }
    }

    /// The corpus's determinism guarantee, asserted here rather than assumed: a catalog nobody has
    /// hydrated carries no corrections, so every cold measurement in `FoodSearchCorpusTests` is
    /// independent of whatever this device has learned.
    @Test func aFreshCatalogIsColdSoTheCorpusStaysDeterministic() throws {
        let first = try Self.catalog(aliases: ["mozzarella cheese": Self.correctedItem("Mozzarella Cheese", in: try Self.catalog()).id])
        #expect(first.results(for: "mozzarella cheese", limit: 1, context: .userTyped).first?.name == "Mozzarella Cheese")
        // A SECOND, independently built catalog — the shape every corpus test uses — is unaffected.
        let fresh = FoodCatalog.bundled()
        try #require(fresh.bundledCount == Self.shippedRowCount)
        #expect(fresh.results(for: "mozzarella cheese", limit: 1, context: .userTyped).first?.name == "DENNY'S, mozzarella cheese sticks",
                "a correction planted in one catalog leaked into another — the corpus is no longer deterministic")
    }

    /// A promotion re-ranks; it never lengthens the list, never duplicates the promoted row, and
    /// leaves the relative order of everything else alone.
    @Test func correctionReRanksWithoutLengtheningOrDuplicating() throws {
        let cold = try Self.catalog()
        let corrected = try Self.correctedItem("Mozzarella Cheese", in: cold)
        let coldRows = cold.results(for: "mozzarella cheese", limit: 6, context: .userTyped)
        let warm = try Self.catalog(aliases: ["mozzarella cheese": corrected.id])
        let warmRows = warm.results(for: "mozzarella cheese", limit: 6, context: .userTyped)

        #expect(warmRows.count == coldRows.count, "the promotion grew the result list past the caller's limit")
        #expect(warmRows.filter { $0.id == corrected.id }.count == 1, "the promoted row is also present further down — a caller would render it twice")
        let tail = warmRows.dropFirst().map(\.id)
        let expectedTail = coldRows.filter { $0.id != corrected.id }.prefix(tail.count).map(\.id)
        #expect(Array(tail) == Array(expectedTail), "the promotion reordered the rows below it")

        // A limit of 1 still returns exactly one row — the caller's contract, and the one
        // `MealResolutionService.fallbackMicronutrients` relies on.
        #expect(warm.results(for: "mozzarella cheese", limit: 1, context: .userTyped).count == 1)
    }

    /// The correction reaches the RESOLVER's candidate pool too, because `candidates(for:)` draws it
    /// from `results(for:)` — this is the compounding half of the fix ("improves the more the app is
    /// used"), and the surface `FoodSearchCorpusTests.resolverBank` pins cold.
    @Test func correctionReachesTheResolverCandidatePool() throws {
        let cold = try Self.catalog()
        #expect(cold.candidates(for: "mozzarella cheese", limit: 18).first?.foodItem.name == "DENNY'S, mozzarella cheese sticks",
                "the cold resolver pool moved — re-measure FoodSearchCorpusTests.resolverBank first")
        let corrected = try Self.correctedItem("Mozzarella Cheese", in: cold)
        let warm = try Self.catalog(aliases: ["mozzarella cheese": corrected.id])
        let pool = warm.candidates(for: "mozzarella cheese", limit: 18)
        #expect(pool.first?.foodItem.id == corrected.id, "the resolver pool ignored the user's own correction")
    }

    /// The deliberate asymmetry: `FoodCatalog.scoredResults` does not promote corrections, so the
    /// one caller that reads it (`DishTemplateLexicon`'s per-component bind) is unaffected.
    ///
    /// **Scope, corrected by the 2026-08-23 review (finding M4): this is an abstention, not THE
    /// firewall.** The plan and AI tiers reach their scores through `FoundationFoodSelectionModel`,
    /// which builds its own index and calls `FoodItemSearch.scoredResults(for:in:)` — never this
    /// method — so a green assertion here says nothing about whether a correction can bind. What
    /// actually protects binds is pinned in `FoodSearchCorrectionResolverFirewallTests`.
    @Test func correctionDoesNotReachTheCatalogScoredSurface() throws {
        let cold = try Self.catalog()
        let corrected = try Self.correctedItem("Mozzarella Cheese", in: cold)
        let warm = try Self.catalog(aliases: ["mozzarella cheese": corrected.id])
        let coldScored = cold.scoredResults(for: "mozzarella cheese", limit: 6)
        let warmScored = warm.scoredResults(for: "mozzarella cheese", limit: 6)
        #expect(warmScored.map(\.item.id) == coldScored.map(\.item.id))
        #expect(warmScored.map(\.score) == coldScored.map(\.score))
        #expect(warmScored.first?.item.id != corrected.id)
    }

    /// Three ways an alias is inert, all silent by design.
    @Test func inertAliasesChangeNothing() throws {
        let cold = try Self.catalog()
        let corrected = try Self.correctedItem("Mozzarella Cheese", in: cold)
        let coldRows = cold.results(for: "mozzarella cheese", limit: 6, context: .userTyped).map(\.id)

        // 1. An alias for a DIFFERENT query.
        let elsewhere = try Self.catalog(aliases: ["black coffee": corrected.id])
        #expect(elsewhere.results(for: "mozzarella cheese", limit: 6, context: .userTyped).map(\.id) == coldRows)

        // 2. An alias whose food no longer resolves (a purged branded ODR row, a deleted user item).
        let dangling = try Self.catalog(aliases: ["mozzarella cheese": UUID()])
        #expect(dangling.results(for: "mozzarella cheese", limit: 6, context: .userTyped).map(\.id) == coldRows,
                "a dangling correction must fall through to the normal ranking, not blank the results")

        // 3. A key below `minimumQueryLength`, which the searcher itself refuses to answer. The
        // memory cannot mint one (`FoodSearchCorrection` rejects it), so this pins the catalog's own
        // floor against a hand-written or migrated map.
        let tooShort = try Self.catalog(aliases: ["ab": corrected.id])
        #expect(tooShort.results(for: "ab", limit: 6, context: .userTyped).isEmpty,
                "a two-character alias resolved to a food, which the search floor forbids")
    }
}

// MARK: - The wipe + the resurrection audit

/// The persisted-surface wall's behavioral half for fix 1.10: "Delete everything" really removes the
/// correction memory — from the defaults sidecar AND from the live catalog — and nothing writes it
/// back afterwards.
///
/// Own suite for the same reason as `PrivacyWipeAttemptMemoryRemovalTests`: it drives a real
/// `FernletStore` through the real `deleteAllData` funnel. What isolates it is its injected
/// `UserDefaults` suite, not scheduling.
@MainActor
@Suite(.serialized)
struct FoodSearchCorrectionWipeTests {

    /// A food nothing else in the catalog resembles, so a hit can only come from the correction.
    private static func plantedFood() -> FoodItem {
        FoodItem(
            name: "Zzyzx Testbench Loaf",
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 5, carbs: 5, fat: 5),
            micronutrients: Micronutrients(),
            category: "test",
            source: .usda,
            dataType: .foundation,
            tags: []
        )
    }

    @Test func deleteAllClearsTheFoodSearchCorrectionMemory() async {
        let food = Self.plantedFood()
        // INIT parameter, never a post-hoc assignment: `FernletStore` reads this suite during init
        // (`finishCommonWiring` publishes the alias map), so a store built on `.standard` and
        // re-pointed afterwards has already read the shared suite — the hazard review finding H2
        // named.
        let suiteName = "fernlet.tests.foodCorrections.wipe.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeTestStore(bundledFoodItems: [food], foodSearchCorrectionDefaults: defaults)

        // A query whose tokens appear in no catalog name, so cold search cannot answer it.
        let query = "quaffle brunch nonsense"
        #expect(store.foodCatalog.results(for: query, limit: 3, context: .userTyped).isEmpty, "precondition: the query must be unanswerable cold")
        store.rememberFoodSearchCorrections([FoodSearchCorrection(searchText: query, foodItemID: food.id)].compactMap { $0 })
        #expect(store.foodCatalog.results(for: query, limit: 3, context: .userTyped).first?.id == food.id, "precondition: the correction was not learned")

        _ = await store.deleteAllData(includingHealthKitSamples: false)

        #expect(FoodSearchCorrectionMemory.aliases(defaults: defaults).isEmpty,
                "delete everything left the correction memory on disk — the searches this person corrected outlived the wipe")
        #expect(defaults.object(forKey: FoodSearchCorrectionMemory.defaultsKey) == nil)
        #expect(store.foodCatalog.results(for: query, limit: 3, context: .userTyped).isEmpty,
                "the wipe cleared the sidecar but left the catalog's live copy answering — 'deleted but still there' until relaunch")
    }

    /// The resurrection audit, behavioral half: after the wipe, the paths that PUBLISH corrections
    /// re-read an empty store, and a fresh store over the same defaults suite (a relaunch) learns
    /// nothing back.
    @Test func nothingResurrectsCorrectionsAfterAWipe() async {
        let food = Self.plantedFood()
        let suiteName = "fernlet.tests.foodCorrections.resurrect.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeTestStore(bundledFoodItems: [food], foodSearchCorrectionDefaults: defaults)
        let query = "quaffle brunch nonsense"
        store.rememberFoodSearchCorrections([FoodSearchCorrection(searchText: query, foodItemID: food.id)].compactMap { $0 })

        _ = await store.deleteAllData(includingHealthKitSamples: false)

        // The publish path (launch, and after every write) must not re-mint what the wipe removed.
        store.publishFoodSearchCorrectionAliases()
        #expect(store.foodCatalog.results(for: query, limit: 3, context: .userTyped).isEmpty)
        // An empty save is a no-op rather than a re-write.
        store.rememberFoodSearchCorrections([])
        #expect(defaults.object(forKey: FoodSearchCorrectionMemory.defaultsKey) == nil)

        // A relaunch over the same device sidecar: a second store hydrating from the same suite —
        // through the INIT, which is where the real launch reads it.
        let relaunched = makeTestStore(bundledFoodItems: [food], foodSearchCorrectionDefaults: defaults)
        #expect(relaunched.foodCatalog.results(for: query, limit: 3, context: .userTyped).isEmpty,
                "a relaunched store re-learned a correction the wipe deleted")
    }

    /// A test store built WITHOUT an injected suite must not read the process-global `.standard`
    /// one — review finding H2, which was live: a correction planted in `.standard` changed an
    /// uninjected store's top-1, and persisted in the simulator container between runs.
    ///
    /// The helper now hands every store its own suite through the INIT, which is the only place that
    /// closes it: `finishCommonWiring` publishes the alias map during construction, so an
    /// after-the-fact assignment lands too late.
    @Test func anUninjectedTestStoreDoesNotInheritTheProcessGlobalSuite() {
        let food = Self.plantedFood()
        let query = "quaffle brunch nonsense"
        // Plant into `.standard` exactly as the reviewer did, and clean up afterwards.
        let standard = UserDefaults.standard
        let planted = FoodSearchCorrection(searchText: query, foodItemID: food.id)
        FoodSearchCorrectionMemory.remember([planted].compactMap { $0 }, defaults: standard)
        defer { FoodSearchCorrectionMemory.clearAll(defaults: standard) }
        #expect(FoodSearchCorrectionMemory.aliases(defaults: standard)[query] == food.id,
                "precondition: the reviewer's plant did not land")

        let store = makeTestStore(bundledFoodItems: [food])
        #expect(store.foodSearchCorrectionCount == 0,
                "an uninjected test store read the shared `.standard` suite — one test's correction is now every test's")
        #expect(store.foodCatalog.results(for: query, limit: 3, context: .userTyped).isEmpty,
                "a correction planted in `.standard` changed an uninjected store's search results")
    }

    /// The behavioural half of "a cancelled sheet teaches the app nothing" (review finding H1).
    ///
    /// Recording picks into the sheet's draft — what the Replace path does — writes NOTHING. Only the
    /// store call the Save bar makes writes. A cancelled sheet is exactly the first half of this test:
    /// picks recorded, `rememberFoodSearchCorrections` never called, storage untouched.
    @Test func correctionsRecordedIntoADraftAreNotWrittenUntilSave() {
        let food = Self.plantedFood()
        let suiteName = "fernlet.tests.foodCorrections.draft.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeTestStore(bundledFoodItems: [food], foodSearchCorrectionDefaults: defaults)

        var draft = FoodSearchCorrectionDraft()
        draft.record(searchText: "quaffle brunch nonsense", prefilledWith: "Wrong Match", foodItemID: food.id)
        draft.record(searchText: "second corrected search", prefilledWith: "Wrong Match", foodItemID: food.id)
        #expect(draft.corrections.count == 2, "precondition: the draft did not record the picks")
        #expect(defaults.object(forKey: FoodSearchCorrectionMemory.defaultsKey) == nil,
                "recording a pick wrote to storage — a CANCELLED correction would now teach the app")
        #expect(store.foodCatalog.results(for: "quaffle brunch nonsense", limit: 3, context: .userTyped).isEmpty)

        // Save — the one call the sheet's Save bar makes.
        store.rememberFoodSearchCorrections(draft.corrections)
        #expect(store.foodSearchCorrectionCount == 2)
        #expect(store.foodCatalog.results(for: "quaffle brunch nonsense", limit: 3, context: .userTyped).first?.id == food.id)
    }

    /// Review finding M6: a pick made without editing the PREFILL is not a search the user typed.
    @Test func aPickOnTheUneditedPrefillIsNotRecorded() {
        let id = UUID()
        var draft = FoodSearchCorrectionDraft()
        draft.record(searchText: "DENNY'S, mozzarella cheese sticks", prefilledWith: "DENNY'S, mozzarella cheese sticks", foodItemID: id)
        #expect(draft.corrections.isEmpty, "one tap on the prefilled suggestion minted a key nobody will ever type")
        // Normalization, not bytes: retyping the same words with different case/spacing is still the
        // prefill, and still not a search.
        draft.record(searchText: "  mozzarella   CHEESE sticks ", prefilledWith: "Mozzarella Cheese Sticks", foodItemID: id)
        #expect(draft.corrections.isEmpty)
        // Honest limit of that rule, measured: `FoodItemSearch.normalized` maps an apostrophe to a
        // SPACE ("DENNY'S" → "denny s"), so retyping a possessive prefill without the apostrophe is a
        // different key and DOES record. Harmless — it is a string the user actually typed — and
        // widening `normalized` to fix it is forbidden (it is load-bearing for the count math in
        // fixes 1.5-1.8).
        draft.record(searchText: "dennys mozzarella cheese sticks", prefilledWith: "DENNY'S, mozzarella cheese sticks", foodItemID: id)
        #expect(draft.corrections.map(\.query) == ["dennys mozzarella cheese sticks"])
        draft = FoodSearchCorrectionDraft()
        // An actual edit records.
        draft.record(searchText: "mozzarella cheese", prefilledWith: "DENNY'S, mozzarella cheese sticks", foodItemID: id)
        #expect(draft.corrections.map(\.query) == ["mozzarella cheese"])
    }

    /// The draft's own R3 bound and last-pick-wins rule (moved out of the view so it is testable).
    @Test func theDraftIsBoundedAndKeepsTheLastPickPerQuery() {
        let first = UUID()
        let second = UUID()
        var draft = FoodSearchCorrectionDraft()
        draft.record(searchText: "greek yogurt", prefilledWith: "", foodItemID: first)
        draft.record(searchText: "greek yogurt", prefilledWith: "", foodItemID: second)
        #expect(draft.corrections.count == 1)
        #expect(draft.corrections.first?.foodItemID == second)

        for index in 0..<(FoodSearchCorrectionDraft.maxPendingCorrections + 5) {
            draft.record(searchText: "draft query \(index)", prefilledWith: "", foodItemID: UUID())
        }
        #expect(draft.corrections.count == FoodSearchCorrectionDraft.maxPendingCorrections)
        #expect(draft.corrections.contains { $0.query == "greek yogurt" } == false, "eviction is not oldest-first")
    }

    /// Review finding M7: the correction memory has a user-facing "forget" that clears it and NOTHING
    /// else, so an invisible, permanent, individually-unremovable surface has an escape hatch short of
    /// "delete everything".
    @Test func forgettingCorrectionsClearsThemAndNothingElse() {
        let food = Self.plantedFood()
        let suiteName = "fernlet.tests.foodCorrections.forget.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = makeTestStore(bundledFoodItems: [food], foodSearchCorrectionDefaults: defaults)
        store.addMeal(from: "Kept meal", type: .lunch)
        let mealsBefore = store.day.meals.count
        store.rememberFoodSearchCorrections(
            [FoodSearchCorrection(searchText: "quaffle brunch nonsense", foodItemID: food.id)].compactMap { $0 }
        )
        #expect(store.foodSearchCorrectionCount == 1)

        let forgotten = store.forgetAllFoodSearchCorrections()

        #expect(forgotten == 1, "the row reports what it forgot; a wrong count is a claim the user cannot check")
        #expect(store.foodSearchCorrectionCount == 0)
        #expect(store.foodCatalog.results(for: "quaffle brunch nonsense", limit: 3, context: .userTyped).isEmpty,
                "forgetting cleared the sidecar but left the catalog answering")
        #expect(store.day.meals.count == mealsBefore,
                "\"forget corrected searches\" destroyed something other than the corrections")
    }

    /// The resurrection audit, structural half — the repo has four documented cases of a writer that
    /// re-created wiped data, and the cheapest guard is knowing exactly who can write this surface.
    ///
    /// **Rebuilt after review finding H1 defeated the first version.** That one compared `range(of:)`
    /// FILE POSITIONS, which say nothing about control flow: the reviewer moved the write from the
    /// Save bar into the Replace PICK closure — the exact bug the assertion message describes — and it
    /// stayed green. This one extracts the Save closure's BODY by brace counting and asks whether the
    /// write is inside it, and it sweeps ALL of `App/` rather than the two files it expected to find
    /// writers in.
    @Test func theOnlyWriterIsTheCorrectionSheetSave() throws {
        let root = RepoRoot.url
        let foodView = try String(contentsOf: root.appendingPathComponent("App/Fernlet/FoodView.swift"), encoding: .utf8)

        // 1. The write is INSIDE the Save bar's closure body — not merely after its first character.
        let saveBody = try Self.closureBody(after: "SheetSaveBar(label: \"Save\"", in: foodView)
        #expect(saveBody.contains("store.rememberFoodSearchCorrections("),
                "the correction write is no longer inside the sheet's Save closure — a cancelled or pick-time write would now teach the app")

        // 1a. THREE STRUCTURAL BACKSTOPS on the extraction itself (review DEFEAT-E). A brace counter
        // that over-runs its closure swallows the rest of the view and re-admits every write it was
        // meant to exclude, so the assertion above is only worth what these three are: the extracted
        // text must look like the Save closure and nothing bigger.
        #expect(saveBody.contains("dismiss()"),
                "the extracted body has no dismiss() — this is not the Save closure, so assertion 1 is measuring the wrong text")
        // STRUCTURAL, not a name list (review evasion e2): the first version enumerated
        // `.onDisappear` / `.task(` / `.onChange(`, so relocating the write into
        // `.fernletDraftGuard`'s trailing closure — the DISCARD handler, which contains its own
        // `dismiss()` — sailed past both this check and the dismiss() backstop. A view-modifier chain
        // cannot appear inside a Button action closure, so ANY line that begins with `.` after its
        // leading whitespace proves the extraction escaped the closure — whatever the modifier is
        // called, including ones not written yet.
        let modifierLines = saveBody
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix(".") }
        #expect(modifierLines.isEmpty,
                "the extraction ran past the Save closure into a view-modifier chain \(modifierLines.prefix(3)) — a write in one of those fires on CANCEL and would read as 'inside Save'")
        // A LITERAL cap, not a fraction of the file: the Save bar sits a few hundred lines from EOF of
        // a ~4,300-line file, so `count < fileLength / 4` could never fire on an over-run that swallows
        // only the tail — which is exactly the over-run DEFEAT-E produced.
        #expect(saveBody.count < 2_000,
                "the extracted Save closure is \(saveBody.count) characters — the brace counting is not bounding")

        // 2. …and nowhere else in the file, so it cannot ALSO fire from a pick.
        #expect(foodView.components(separatedBy: "rememberFoodSearchCorrections(").count - 1 == 1,
                "the correction memory gained another UI writer; check it cannot fire from a CANCELLED sheet")

        // 3. Whole-`App/` sweep (review finding M3): any OTHER file calling either writer is a
        // surface no wipe leg and no review has looked at. The two known files are allowlisted by
        // name and pinned by count above.
        let allowedWriters: Set<String> = ["FoodView.swift", "FernletStore.swift"]
        let appFiles = try Self.swiftFiles(under: root.appendingPathComponent("App"))
        #expect(appFiles.count > 50, "the App scan found \(appFiles.count) files — it would pass by looking at almost nothing")
        let strayWriters = appFiles.filter { url in
            guard !allowedWriters.contains(url.lastPathComponent),
                  let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            // Comment-stripped: a doc comment that NAMES the writer (FoodSearchCorrectionMemory's own
            // header points at it) is prose, not a call site.
            let code = Self.strippingLineComments(text)
            return code.contains("rememberFoodSearchCorrections(") || code.contains("FoodSearchCorrectionMemory.remember(")
        }
        #expect(strayWriters.isEmpty, "a new writer of the correction memory: \(strayWriters.map(\.lastPathComponent))")

        // 4. Inside `FernletStore` there is exactly one call into the memory's writer.
        let store = try String(contentsOf: root.appendingPathComponent("App/Fernlet/FernletStore.swift"), encoding: .utf8)
        #expect(store.components(separatedBy: "FoodSearchCorrectionMemory.remember(").count - 1 == 1,
                "a second call site can write corrections — every writer must be audited against the wipe")

        // 5. Nothing below the app layer may CALL it: the memory is app-target bookkeeping, and a
        // FernletKit writer would be one no wipe leg knows about. Member access (`…Memory.`) rather
        // than the bare name, so the FoodCatalog doc comment that names the type in prose — the
        // pointer that tells a reader where the durable copy lives — is not an offender.
        let kitFiles = try Self.swiftFiles(under: root.appendingPathComponent("FernletKit/Sources"))
        #expect(!kitFiles.isEmpty, "the FernletKit scan found no sources — it would pass by looking at nothing")
        let offenders = kitFiles.filter { url in
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
            return text.contains("FoodSearchCorrectionMemory.")
        }
        #expect(offenders.isEmpty, "FernletKit calls into the correction memory: \(offenders.map(\.lastPathComponent))")
    }

    /// `source` with `//` line comments removed, preserving the line count.
    static func strippingLineComments(_ source: String) -> String {
        source
            .components(separatedBy: "\n")
            .map { line -> String in
                guard let commentStart = line.range(of: "//") else { return line }
                return String(line[..<commentStart.lowerBound])
            }
            .joined(separator: "\n")
    }

    /// Every shipping `.swift` file under `directory`.
    private static func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        guard let files = enumerator?.compactMap({ $0 as? URL }).filter({ $0.pathExtension == "swift" }) else {
            throw CorrectionScanError.unreadableDirectory(directory.lastPathComponent)
        }
        return files
    }

    /// The body of the trailing closure opened after `marker`, by brace counting from its `{` to the
    /// matching `}` — CONTROL FLOW, not file position, which is the whole point of review finding H1.
    ///
    /// Line comments are stripped first (a `{` in prose would unbalance the count) and the search is
    /// anchored on a unique marker, so a moved or duplicated Save bar throws rather than binding to the
    /// wrong closure.
    ///
    /// **String-literal aware, after review DEFEAT-E.** The first counter counted every brace it saw,
    /// including braces inside STRING LITERALS: planting
    /// `FernletAuditLog.log("…", context: ["shape": "{{"])` inside the Save closure pushed the depth
    /// two levels past the truth, the extraction ran through the closure's `}` and the enclosing
    /// `VStack`'s, and a write moved into `.onDisappear` — which fires on CANCEL — still read as
    /// "inside Save". So the walk tracks quoting: a `"` opens a literal, a backslash escapes the next
    /// character, and `"""` opens/closes a multi-line literal.
    ///
    /// **Interpolation segments are deliberately counted AS STRING TEXT** (a `\(…)` run is consumed by
    /// the escape rule and stays inside the literal). Braces there are therefore ignored in PAIRS, so
    /// the depth stays balanced; the alternative — re-entering code mode inside interpolation — needs a
    /// nesting stack for a shape that does not occur in this file, and would add a second way to
    /// desync. The residual case a quoting model cannot handle (a nested `"` inside an interpolated
    /// expression) is caught by the three structural backstops at the call site, not by this walk.
    private static func closureBody(after marker: String, in source: String) throws -> String {
        let stripped = strippingLineComments(source)
        let occurrences = stripped.components(separatedBy: marker).count - 1
        guard occurrences == 1, let markerRange = stripped.range(of: marker) else {
            throw CorrectionScanError.ambiguousMarker(marker, occurrences)
        }
        return try scanClosure(Array(stripped[markerRange.upperBound...]), marker: marker)
    }

    /// The brace walk itself: returns the text between the first `{` in `characters` and its matching
    /// `}`, skipping braces inside string literals.
    private static func scanClosure(_ characters: [Character], marker: String) throws -> String {
        var depth = 0
        var body: [Character] = []
        var quoting = QuoteState.code
        var index = 0
        // R2: bounded by the character count handed in.
        while index < characters.count {
            let character = characters[index]
            let step = advance(quoting: &quoting, characters: characters, index: index)
            if quoting == .code, step == 1 {
                if character == "{" {
                    depth += 1
                    if depth == 1 { index += 1; continue }
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 { return String(body) }
                }
            }
            if depth > 0 { body.append(contentsOf: characters[index..<min(index + step, characters.count)]) }
            index += step
        }
        throw CorrectionScanError.unterminatedClosure(marker)
    }

    /// Updates `quoting` for the character at `index` and reports how many characters it consumed
    /// (2 for an escape pair, 3 for a `"""` delimiter, 1 otherwise).
    private static func advance(quoting: inout QuoteState, characters: [Character], index: Int) -> Int {
        let character = characters[index]
        let isTripleQuote = character == "\"" && index + 2 < characters.count
            && characters[index + 1] == "\"" && characters[index + 2] == "\""
        switch quoting {
        case .code:
            if isTripleQuote { quoting = .multiline; return 3 }
            if character == "\"" { quoting = .single }
            return 1
        case .single:
            if character == "\\" { return 2 }
            if character == "\"" { quoting = .code }
            return 1
        case .multiline:
            if isTripleQuote { quoting = .code; return 3 }
            if character == "\\" { return 2 }
            return 1
        }
    }

    /// Where the scan currently is with respect to string literals.
    private enum QuoteState {
        /// Ordinary Swift code — braces count here, and only here.
        case code
        /// Inside a `"…"` literal.
        case single
        /// Inside a `"""…"""` literal.
        case multiline
    }

    /// Why a source scan could not run — always a loud stop, never a quiet pass.
    enum CorrectionScanError: Error {
        /// The anchor appears zero times, or more than once, so the extraction would bind to the
        /// wrong closure.
        case ambiguousMarker(String, Int)
        /// The closure opened but never closed — the stripper or the source shape changed.
        case unterminatedClosure(String)
        /// A scan root could not be enumerated.
        case unreadableDirectory(String)
    }
}

// MARK: - The resolver firewall (review finding M4/M5)

/// What actually stops a correction from binding — and from auto-committing.
///
/// The 2026-08-23 review showed the first version pinned the wrong mechanism. The real firewall has
/// three parts, and each is pinned here against the SHIPPED catalog with a deliberately absurd
/// correction (the reviewer's own probe: `chiken breast` → *Mozzarella Cheese*, a row that carries
/// none of the query's tokens):
///
///   1. `FoundationFoodSelectionModel.deterministicIngredients` re-derives every bind from an
///      alias-free index, so the promoted row is never bound by the deterministic tier;
///   2. `MealResolutionService.bindConfidence` re-scores the whole item name through fix 1.8's
///      `carries` floor, so even a bound promotion could not claim `.high`;
///   3. `MealResolutionService.retrievalGatedConfidence` caps the AI-selection tier, which has
///      neither of the above — it stamped `.high` on whatever the model picked from the pool.
///
/// `@MainActor` because both resolver seams are: `FoundationFoodSelectionModel.deterministicPlan`
/// and `MealResolutionService`'s statics run on the main actor in production too.
@MainActor
@Suite
struct FoodSearchCorrectionResolverFirewallTests {

    private static let absurdQuery = "chiken breast"
    private static let absurdCorrection = "Mozzarella Cheese"

    private static func shippedCatalog(aliases: [String: UUID] = [:]) throws -> FoodCatalog {
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount == FoodSearchCorrectionCatalogTests.shippedRowCount,
                     "shipped catalog must be loaded — this suite must never pass vacuously")
        catalog.setSearchAliases(aliases)
        return catalog
    }

    /// The correction really does reach the resolver's POOL (that is the feature) — and is still
    /// never bound, and never confident.
    @Test func aPromotedCorrectionEntersThePoolButNeverBindsConfidently() throws {
        let cold = try Self.shippedCatalog()
        let promoted = try #require(cold.exactNameMatch(forNormalized: FoodItemSearch.normalized(Self.absurdCorrection)))
        let warm = try Self.shippedCatalog(aliases: [Self.absurdQuery: promoted.id])

        let pool = warm.candidates(for: Self.absurdQuery, limit: 18)
        #expect(pool.contains { $0.foodItem.id == promoted.id },
                "precondition: the correction never reached the resolver pool, so this suite proves nothing")

        let plan = try #require(FoundationFoodSelectionModel.deterministicPlan(
            description: Self.absurdQuery, candidates: pool, fallbackType: nil
        ))
        let boundIDs = plan.ingredients.compactMap { ingredient in
            pool.first { $0.id == ingredient.candidateId }?.foodItem.id
        }
        #expect(!boundIDs.contains(promoted.id),
                "the deterministic tier bound a correction that carries none of the typed tokens — the alias-free re-filter in deterministicIngredients is gone")
        #expect(MealResolutionService.bindConfidence(for: plan, candidates: pool) != .high
                    || !boundIDs.contains(promoted.id),
                "a promoted correction bound AND claimed high confidence")
    }

    /// The AI-selection tier's gate, exercised directly because the model itself is unavailable in
    /// the simulator: a hand-built plan that binds the promoted row — exactly what the model would
    /// return when it picks candidate #1 — is capped at `.low`, so it opens the review sheet instead
    /// of auto-committing.
    @Test func theAITierCapsAPlanThatBindsAPromotedCorrection() throws {
        let cold = try Self.shippedCatalog()
        let promoted = try #require(cold.exactNameMatch(forNormalized: FoodItemSearch.normalized(Self.absurdCorrection)))
        let warm = try Self.shippedCatalog(aliases: [Self.absurdQuery: promoted.id])
        let pool = warm.candidates(for: Self.absurdQuery, limit: 18)
        let promotedCandidate = try #require(pool.first { $0.foodItem.id == promoted.id })

        let plan = FoodSelectionPlan(
            mealName: Self.absurdQuery,
            mealType: .lunch,
            items: [FoodSelectionMealItem(
                name: Self.absurdQuery,
                ingredients: [FoodSelectionIngredient(
                    candidateId: promotedCandidate.id,
                    foodName: promotedCandidate.foodItem.name,
                    quantity: 1,
                    unit: RecipeUnit.serving.rawValue
                )]
            )]
        )
        #expect(MealResolutionService.retrievalGatedConfidence(.high, for: plan, candidates: pool) == .low,
                "the AI tier would auto-commit a correction the retrieval floors reject — needsReview is `== .low`, so anything else still commits silently")
    }

    /// …and the gate is a no-op on an honest pick, so it cannot be blamed for sending ordinary AI
    /// resolutions to review. The row here reached the pool through retrieval.
    @Test func theAITierGateLeavesARetrievedPickAlone() throws {
        let catalog = try Self.shippedCatalog()
        let pool = catalog.candidates(for: "grilled chicken", limit: 18)
        let retrieved = try #require(pool.first)
        let plan = FoodSelectionPlan(
            mealName: "grilled chicken",
            mealType: .lunch,
            items: [FoodSelectionMealItem(
                name: "grilled chicken",
                ingredients: [FoodSelectionIngredient(
                    candidateId: retrieved.id,
                    foodName: retrieved.foodItem.name,
                    quantity: 1,
                    unit: RecipeUnit.serving.rawValue
                )]
            )]
        )
        #expect(MealResolutionService.retrievalGatedConfidence(.high, for: plan, candidates: pool) == .high,
                "the correction gate demoted a pick that retrieval found on its own — every AI resolution would now pause at review")
    }

    /// The no-op case that matters most, and the one the single-item test above does NOT cover: a
    /// MULTI-ITEM plan, where the pool was assembled for the whole description and each pick is bound
    /// to one split item.
    ///
    /// This is where the gate's asymmetry lives (review finding M5's correction to my own doc): pool
    /// admission scores sub-phrases of the DESCRIPTION, the gate scores sub-phrases of the ITEM NAME,
    /// so the claim is not "a no-op on uncorrected devices" but **a no-op for any ingredient that
    /// clears the retrieval floor against the item it is bound to**. The plan built here is the
    /// deterministic tier's OWN — every bind already cleared that floor by construction — so the gate
    /// must leave it alone. A failure here means ordinary multi-item AI resolutions started pausing at
    /// review, which is the collateral this fix promised not to cause.
    @Test func theAITierGateLeavesAnHonestMultiItemPlanAlone() throws {
        let catalog = try Self.shippedCatalog()
        for description in ["burger and fries", "eggs and toast", "chicken rice and broccoli"] {
            let pool = catalog.candidates(for: description, limit: 18)
            let plan = try #require(FoundationFoodSelectionModel.deterministicPlan(
                description: description, candidates: pool, fallbackType: nil
            ))
            try #require(plan.items.count > 1, "\"\(description)\" no longer splits into several items — pick another multi-item description")
            try #require(plan.ingredients.isEmpty == false, "\"\(description)\" bound nothing, so this proves no no-op")
            #expect(MealResolutionService.retrievalGatedConfidence(.high, for: plan, candidates: pool) == .high,
                    "the gate demoted an honest multi-item plan for \"\(description)\" — every bind in it cleared the retrieval floor against its own item")
        }
    }
}
