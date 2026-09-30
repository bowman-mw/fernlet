// QuickLogSweepProbeTests.swift
// FernletTests
//
// A MEASURING probe, not a pin — the quick-log sibling of `IngredientSearchReplayProbeTests`. It
// sends every query the food-search instruments already carry (the 57-query food-search corpus, the
// resolver bank, and the 160-query ingredient corpus) through `FernletStore.resolveMeals(from:)` —
// what the quick-log Save button calls — on a cold store with AI off, so the deterministic tiers
// answer, and writes what each query would log: the confidence, whether it would open the review
// sheet, and every bound component with its amount and macros. It asserts nothing about today's
// answers, so a fix round can run it before and after a catalog change and diff the two outputs.
//
// Why it exists: the ingredient-search round's F6 retype (misfiled packaged products typed back to
// `branded`) moved the resolver pool for "apple", and the typed-search replay could not see what
// that did to a quick log (fix round 1, finding u1-L-R1). A catalog-data change can move the
// quick-log surface through a path the typeahead never takes — the resolver splits phrases,
// demotes dishes and binds one row per item — so it is measured here directly.
//
// OPT-IN ONLY. Nothing runs unless the runner environment carries `FERNLET_QUICKLOG_SWEEP` (pass
// `TEST_RUNNER_FERNLET_QUICKLOG_SWEEP=1` to xcodebuild; Xcode strips the prefix). Output goes to the
// directory named by `FERNLET_QUICKLOG_OUT` as `quicklog-sweep.json`; when that is absent or
// unwritable, the JSON is printed between `===QUICKLOG-JSON-BEGIN===` and `===QUICKLOG-JSON-END===`.
//
//     TEST_RUNNER_FERNLET_QUICKLOG_SWEEP=1 TEST_RUNNER_FERNLET_QUICKLOG_OUT=/abs/out \
//       xcodebuild test-without-building … -only-testing:FernletTests/QuickLogSweepProbeTests

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// One bound component of a quick-log answer, as the diary would store it.
struct QuickLogSweepComponent: Codable, Equatable {
    /// The bound catalog row's name.
    let name: String
    /// The amount logged, in `unit`.
    let quantity: Double
    /// The frozen `RecipeUnit` token logged.
    let unit: String
    /// Protein grams for that amount.
    let protein: Int
    /// Carbohydrate grams for that amount.
    let carbs: Int
    /// Fat grams for that amount.
    let fat: Int
    /// The persisted bind score, when the tier recorded one.
    let bindScore: Int?
}

/// What one quick-log description resolves to.
struct QuickLogSweepEntry: Codable, Equatable {
    /// The typed description.
    let query: String
    /// The `MealResolutionConfidence` raw value (`high`, `medium`, `low`).
    let confidence: String
    /// Whether the keyword fallback (fabricated macros) answered.
    let isFallback: Bool
    /// Whether the "Check this meal" review sheet would open instead of an auto-commit.
    let needsReview: Bool
    /// Typed items nothing bound.
    let unmatched: [String]
    /// The first meal's calories.
    let calories: Int
    /// The first meal's components.
    let components: [QuickLogSweepComponent]
}

/// Opt-in sweep of the quick-log resolver over the food-search instruments' queries. See the header.
@Suite(.serialized)
struct QuickLogSweepProbeTests {
    /// Every query the three food-search instruments carry, first occurrence kept, in declaration order.
    static var queries: [String] {
        let all = FoodSearchCorpusTests.corpus.map(\.query)
            + FoodSearchCorpusTests.resolverBank.map(\.query)
            + IngredientSearchCorpusTests.judges.map(\.query)
        var seen: Set<String> = []
        // R2: bounded by the three fixed corpora.
        return all.filter { seen.insert($0).inserted }
    }

    @MainActor
    @Test func sweepQuickLogResolver() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FERNLET_QUICKLOG_SWEEP"] != nil || env["TEST_RUNNER_FERNLET_QUICKLOG_SWEEP"] != nil else { return }
        let store = makeTestStore(foodCatalog: FoodCatalog.bundled())
        try #require(store.settings.aiStatus == AIStatus.off, "the deterministic tiers must be the rungs measured")
        try #require(store.foodCatalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        var entries: [QuickLogSweepEntry] = []
        // R2: bounded by the fixed query list.
        for query in Self.queries {
            entries.append(Self.entry(query, await store.resolveMeals(from: query)))
        }
        Self.emit(entries, to: env["FERNLET_QUICKLOG_OUT"] ?? env["TEST_RUNNER_FERNLET_QUICKLOG_OUT"])
        // Not a pin — a refusal of a degenerate run. The first run of this probe, launched straight
        // after an install, logged "vnode unlinked while in use" from libsqlite3 and answered 197 of
        // 206 queries from the keyword fallback: the catalog file had been replaced under the open
        // handle, and every FTS query came back empty. A healthy tree binds a catalog row for
        // roughly nine in ten. Re-run, never diff, an output this fails on.
        let bound = entries.filter { !$0.isFallback }.count
        #expect(bound * 2 > entries.count, "only \(bound) of \(entries.count) queries bound a catalog row — the catalog did not answer")
    }

    private static func entry(_ query: String, _ resolution: MealResolution) -> QuickLogSweepEntry {
        let meal = resolution.meals.first
        let components = (meal?.componentSnapshots ?? []).map { component in
            QuickLogSweepComponent(
                name: component.name, quantity: component.quantity, unit: component.unit,
                protein: component.macros.protein, carbs: component.macros.carbs, fat: component.macros.fat,
                bindScore: component.bindScore
            )
        }
        return QuickLogSweepEntry(
            query: query, confidence: resolution.confidence.rawValue, isFallback: resolution.isFallback,
            needsReview: resolution.needsReview, unmatched: resolution.unmatchedItems,
            calories: meal?.macros.calories ?? 0, components: components
        )
    }

    private static func emit(_ entries: [QuickLogSweepEntry], to directory: String?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(entries)
        } catch {
            print("QuickLogSweepProbe: could not encode the sweep: \(error)")
            return
        }
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent("quicklog-sweep.json")
            do {
                try data.write(to: url, options: .atomic)
                print("QuickLogSweepProbe: wrote \(url.path) (\(entries.count) queries)")
                return
            } catch {
                print("QuickLogSweepProbe: write failed (\(error)); printing instead")
            }
        }
        print("===QUICKLOG-JSON-BEGIN===")
        print(String(decoding: data, as: UTF8.self))
        print("===QUICKLOG-JSON-END===")
    }
}
