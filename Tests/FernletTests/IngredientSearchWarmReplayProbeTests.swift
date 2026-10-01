// IngredientSearchWarmReplayProbeTests.swift
// FernletTests
//
// A MEASURING probe, not a pin: the WARM variant of `IngredientSearchReplayProbeTests` (ingredient-search
// round F9b). The cold probe measures a fresh install; this one measures a device that has a meal
// history and has built recipes, and asks what one remembered recipe pick per query does.
//
// THE SIMULATED PERSON, all deterministic:
//   1. HISTORY. They have logged, once, three days ago, the row quick-log's typed search (the standard
//      order) puts first for every third corpus query — 54 queries, 49 distinct foods on the shipped
//      catalog, about what the 50-meal history window holds. Published through
//      `FoodCatalog.setSearchHistory`, as `DiaryStore` does.
//   2. BEFORE. Each of the 160 corpus queries is replayed through the recipe editor's exact call
//      (`results(for:context: .userTyped, ranking: .ingredientIdentity)`, six rows), history on.
//   3. PICK. For each query the person taps the first row of those six that the committed ingredient
//      judge (`IngredientSearchCorpusTests.judges`) accepts as a plain form AND whose nutrition is
//      plausible — the row a person building a recipe wants. `RecipeSearchPick.query` decides whether
//      that tap teaches (a row below the first, a finished last word); each taught pick is remembered
//      through `FoodSearchCorrectionMemory.remember` as its own save, into a private defaults suite, and
//      the memory's recipe picks are published into the catalog, as the store does.
//   4. AFTER. Every query is replayed again. The probe also replays quick-log's six (standard order),
//      the meal resolver's pool (`candidates`, 18) and the swap sheet's pool (`candidates`, 12, identity
//      order) before and after, so a pick leaking outside the recipe surfaces is counted.
//
// OPT-IN, exactly like the cold probe: nothing runs unless the runner environment carries
// `FERNLET_REPLAY`; output goes to `FERNLET_REPLAY_OUT` as `replay-warm-<label>.json` (or is printed
// between `===REPLAY-JSON-BEGIN warm-<label>===` markers); the branded ODR pass runs when
// `FERNLET_REPLAY_BRANDED` names the file or `ODRAssets/FoodCatalogBranded.sqlite` exists.
//
//     TEST_RUNNER_FERNLET_REPLAY=1 TEST_RUNNER_FERNLET_REPLAY_OUT=/abs/out \
//       xcodebuild test-without-building … -only-testing:FernletTests/IngredientSearchWarmReplayProbeTests

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// One query's warm measurement.
struct IngredientWarmReplayQuery: Codable, Equatable {
    /// Corpus category (BAKING, PRODUCE, PANTRY, PREFIX).
    let category: String
    /// The typed text.
    let query: String
    /// The recipe editor's six with history on, before any pick.
    let before: [String]
    /// The row the simulated person taps (first plausible plain row of `before`), or nil.
    let picked: String?
    /// The pick's 1-based rank in `before`.
    let pickedRankBefore: Int?
    /// The key the pick taught, or why it taught nothing: `first-row`, `mid-word`, `no-plain-row`, or
    /// `not-taught` (any other refusal).
    let taught: String
    /// The six after every taught pick is remembered.
    let after: [String]
    /// The picked row's 1-based rank in `after`.
    let pickedRankAfter: Int?
    /// First row the judge accepts by name, before and after (1-based; nil = none of the six).
    let plainRankBefore: Int?
    /// See ``plainRankBefore``.
    let plainRankAfter: Int?
    /// First plain AND plausible row, before and after.
    let plausibleRankBefore: Int?
    /// See ``plausibleRankBefore``.
    let plausibleRankAfter: Int?
    /// Whether the recipe six changed although this query taught nothing (cross-talk).
    let changedWithoutPick: Bool
    /// Whether quick-log's six (standard order, typed) is identical before and after.
    let quickLogUnchanged: Bool
    /// Whether the meal resolver's pool (`candidates`, 18, standard) is identical before and after.
    let resolverPoolUnchanged: Bool
    /// The swap sheet's pool's first row, before and after.
    let swapTopBefore: String?
    /// See ``swapTopBefore``.
    let swapTopAfter: String?
}

/// One warm pass over the corpus against one catalog configuration.
struct IngredientWarmReplayRun: Codable, Equatable {
    /// `base` or `base+branded`.
    let label: String
    /// `FoodCatalog.bundledCount` at run time.
    let bundledCount: Int
    /// Distinct foods in the simulated history.
    let historyFoods: Int
    /// Entries the correction memory holds after every pick (all recipe picks).
    let rememberedPicks: Int
    /// Every query, in corpus order.
    let queries: [IngredientWarmReplayQuery]
}

/// The opt-in warm replay. See the file header for the simulated person.
struct IngredientSearchWarmReplayProbeTests {
    /// Every third corpus query contributes its quick-log first row to the history.
    static let historyStride = 3

    @Test func replayWarmRecipePicks() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FERNLET_REPLAY"] != nil || env["TEST_RUNNER_FERNLET_REPLAY"] != nil else { return }
        let matchers = try IngredientSearchCorpusTests.judges.map(IngredientCorpusMatcher.init)
        try #require(matchers.map(\.judge.query) == IngredientReplayCorpus.all.map(\.query),
                     "the judges no longer mirror the replay corpus")
        let outDirectory = env["FERNLET_REPLAY_OUT"] ?? env["TEST_RUNNER_FERNLET_REPLAY_OUT"]
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        Self.emit(try Self.run(label: "base", catalog: catalog, matchers: matchers), to: outDirectory)
        let named = env["FERNLET_REPLAY_BRANDED"] ?? env["TEST_RUNNER_FERNLET_REPLAY_BRANDED"]
        let brandedURL = named.map { URL(fileURLWithPath: $0) } ?? RepoRoot.url("ODRAssets/FoodCatalogBranded.sqlite")
        guard FileManager.default.fileExists(atPath: brandedURL.path) else { return }
        let branded = try #require(SQLiteBundledFoodSource(url: brandedURL, skipPriorityOrder: true, candidateCap: 600))
        let withBranded = FoodCatalog.bundled()
        withBranded.attachBrandedSource(branded)
        Self.emit(try Self.run(label: "base+branded", catalog: withBranded, matchers: matchers), to: outDirectory)
        withBranded.detachBrandedSource()
    }

    // MARK: - Measurement

    /// The state one query is measured in: the recipe six, quick-log's six, and both pools.
    private struct Snapshot {
        let recipe: [FoodItem]
        let quickLog: [UUID]
        let resolverPool: [UUID]
        let swapTop: String?
    }

    private static func snapshot(_ query: String, catalog: FoodCatalog) -> Snapshot {
        Snapshot(
            recipe: catalog.results(for: query, context: .userTyped, ranking: .ingredientIdentity),
            quickLog: catalog.results(for: query, context: .userTyped).map(\.id),
            resolverPool: catalog.candidates(for: query, limit: 18).map(\.foodItem.id),
            swapTop: catalog.candidates(for: query, limit: 12, ranking: .ingredientIdentity).first?.foodItem.name
        )
    }

    private static func run(label: String, catalog: FoodCatalog, matchers: [IngredientCorpusMatcher]) throws -> IngredientWarmReplayRun {
        let history = Self.history(catalog: catalog)
        catalog.setSearchHistory(history)
        let suiteName = "fernlet.tests.warmReplay.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let before = matchers.map { snapshot($0.judge.query, catalog: catalog) }
        var decisions: [(picked: FoodItem?, taught: String)] = []
        for (matcher, state) in zip(matchers, before) {
            let decision = pick(matcher, in: state.recipe)
            decisions.append(decision)
            // Each taught pick is its own recipe save, in corpus order.
            guard let picked = decision.picked, isKey(decision.taught),
                  let entry = FoodSearchCorrection(searchText: decision.taught, foodItemID: picked.id, origin: .recipePick)
            else { continue }
            FoodSearchCorrectionMemory.remember([entry], defaults: defaults)
        }
        catalog.setRecipeSearchPicks(FoodSearchCorrectionMemory.recipePicks(defaults: defaults))
        let after = matchers.map { snapshot($0.judge.query, catalog: catalog) }
        catalog.setRecipeSearchPicks([:])
        catalog.setSearchHistory(.empty)

        let categories = IngredientReplayCorpus.all.map(\.category)
        let queries = matchers.indices.map { index in
            measure(matchers[index], category: categories[index], before: before[index], after: after[index],
                    decision: decisions[index])
        }
        return IngredientWarmReplayRun(
            label: label, bundledCount: catalog.bundledCount, historyFoods: history.trackedFoodCount,
            rememberedPicks: FoodSearchCorrectionMemory.count(defaults: defaults), queries: queries
        )
    }

    /// Whether `taught` is a key rather than one of the refusal labels.
    private static func isKey(_ taught: String) -> Bool {
        !["first-row", "mid-word", "no-plain-row", "not-taught"].contains(taught)
    }

    /// The simulated history: quick-log's first row for every ``historyStride``th query, logged once,
    /// three days ago.
    private static func history(catalog: FoodCatalog) -> FoodSearchHistory {
        let now = Date()
        let weight = FoodSearchHistory.scaledWeight(count: 1, lastLoggedAt: now.addingTimeInterval(-3 * 86_400), now: now)
        var weights: [UUID: Int] = [:]
        for (index, entry) in IngredientReplayCorpus.all.enumerated() where index % historyStride == 0 {
            if let top = catalog.results(for: entry.query, context: .userTyped).first { weights[top.id] = weight }
        }
        return FoodSearchHistory(weights: weights)
    }

    /// The row the person taps and what the tap teaches (a key, or a refusal label).
    private static func pick(_ matcher: IngredientCorpusMatcher, in six: [FoodItem]) -> (picked: FoodItem?, taught: String) {
        guard let picked = six.first(where: { matcher.accepts($0.name) && IngredientSearchCorpusTests.isPlausible($0) }) else {
            return (nil, "no-plain-row")
        }
        let query = matcher.judge.query
        if six.first?.id == picked.id { return (picked, "first-row") }
        if RecipeSearchPick.endsMidWord(FoodItemSearch.normalized(query), names: six.map(\.name)) { return (picked, "mid-word") }
        guard let key = RecipeSearchPick.query(typed: query, picked: picked, shown: six) else {
            return (picked, "not-taught")
        }
        return (picked, key)
    }

    private static func measure(
        _ matcher: IngredientCorpusMatcher, category: String, before: Snapshot, after: Snapshot,
        decision: (picked: FoodItem?, taught: String)
    ) -> IngredientWarmReplayQuery {
        let judge = matcher.judge
        let plain = { (rows: [FoodItem]) in rows.firstIndex { matcher.accepts($0.name) }.map { $0 + 1 } }
        let plausible = { (rows: [FoodItem]) in
            rows.firstIndex { matcher.accepts($0.name) && IngredientSearchCorpusTests.isPlausible($0) }.map { $0 + 1 }
        }
        let rank = { (rows: [FoodItem]) in decision.picked.flatMap { picked in rows.firstIndex { $0.id == picked.id } }.map { $0 + 1 } }
        return IngredientWarmReplayQuery(
            category: category, query: judge.query,
            before: before.recipe.map(\.name), picked: decision.picked?.name, pickedRankBefore: rank(before.recipe),
            taught: decision.taught, after: after.recipe.map(\.name), pickedRankAfter: rank(after.recipe),
            plainRankBefore: plain(before.recipe), plainRankAfter: plain(after.recipe),
            plausibleRankBefore: plausible(before.recipe), plausibleRankAfter: plausible(after.recipe),
            changedWithoutPick: !isKey(decision.taught) && before.recipe.map(\.id) != after.recipe.map(\.id),
            quickLogUnchanged: before.quickLog == after.quickLog,
            resolverPoolUnchanged: before.resolverPool == after.resolverPool,
            swapTopBefore: before.swapTop, swapTopAfter: after.swapTop
        )
    }

    // MARK: - Output

    private static func emit(_ run: IngredientWarmReplayRun, to directory: String?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(run)
        } catch {
            print("IngredientSearchWarmReplayProbe: could not encode the \(run.label) run: \(error)")
            return
        }
        let fileName = "replay-warm-\(run.label.replacingOccurrences(of: "+", with: "-")).json"
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
            do {
                try data.write(to: url, options: .atomic)
                print("IngredientSearchWarmReplayProbe: wrote \(url.path)")
                return
            } catch {
                print("IngredientSearchWarmReplayProbe: write failed (\(error)); printing instead")
            }
        }
        print("===REPLAY-JSON-BEGIN warm-\(run.label)===")
        print(String(decoding: data, as: UTF8.self))
        print("===REPLAY-JSON-END===")
    }
}
