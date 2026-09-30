// IngredientSearchReplayProbeTests.swift
// FernletTests
//
// A MEASURING probe, not a pin. It replays a recipe-ingredient corpus through the exact call the
// recipe ingredient editor makes and writes what came back — it asserts nothing about today's
// answers, so a fix round can re-run it before and after a change and diff the two outputs.
//
// THE CALL IT REPLICATES. `RecipeIngredientEditor.refreshTypeahead()` (App/Fernlet/FoodView.swift)
// hands the trimmed field text to `CatalogTypeahead.matches(for:catalog:)`, which (after a 220 ms
// debounce) runs `catalog.results(for: trimmed, context: .userTyped)` — the default `limit: 6` and
// `stripsStopwords: true` — and the editor renders every returned row, unfiltered, in a VStack.
// So the user's whole list is at most SIX rows. The probe records that exact list (`visible`) and,
// separately, the same call at `limit: 10` (`top10`) so a fix round can see what sits just below the
// fold. Both calls share the demotion window (`FoodItemSearch.demotionWindow` = 60 > 10), so the
// first six of `top10` are the six the user sees; the probe records whether that held.
//
// COLD CATALOG. The catalog is `FoodCatalog.bundled()` with no user items, no correction aliases and
// no history — what a fresh install sees. A real device adds those three personal tiers on top.
//
// OPT-IN ONLY. Nothing runs unless the runner environment carries `FERNLET_REPLAY` (pass
// `TEST_RUNNER_FERNLET_REPLAY=1` to xcodebuild; Xcode strips the prefix). Output goes to the
// directory named by `FERNLET_REPLAY_OUT` (`TEST_RUNNER_FERNLET_REPLAY_OUT=/abs/dir`); when that is
// absent or unwritable, the JSON is printed between `===REPLAY-JSON-BEGIN <label>===` and
// `===REPLAY-JSON-END===` lines instead. The branded On-Demand-Resource catalog is attached for a
// second pass when `FERNLET_REPLAY_BRANDED` names its absolute path, or when
// `ODRAssets/FoodCatalogBranded.sqlite` exists under the repo root; otherwise only the base pass runs.
//
//     TEST_RUNNER_FERNLET_REPLAY=1 TEST_RUNNER_FERNLET_REPLAY_OUT=/abs/out \
//       TEST_RUNNER_FERNLET_REPLAY_BRANDED=/abs/FoodCatalogBranded.sqlite \
//       xcodebuild test-without-building … -only-testing:FernletTests/IngredientSearchReplayProbeTests

import Foundation
import Testing
import FernletDomainModel
import FoodCatalog

/// One catalog row as the recipe ingredient editor would present and bind it.
///
/// `defaultUnit`/`defaultQuantity` are what `RecipeIngredientEditor.select` writes on a tap, and
/// `resolves` says which recipe amounts the row can turn into nutrition (a `false` there is the
/// editor's "This amount needs an exact serving basis or one source-backed portion." state).
struct IngredientReplayRow: Codable, Equatable {
    /// 1-based position in the list.
    let rank: Int
    /// Display name.
    let name: String
    /// Frozen `FoodDataType` token.
    let dataType: String
    /// Frozen `FoodItemSource` token.
    let source: String
    /// Brand owner, when the row carries one.
    let brand: String?
    /// Catalog category.
    let category: String
    /// `FoodItemSearch` score, when `scoredResults` returned the same row (nil on the partial path).
    let score: Int?
    /// Reference serving size and unit.
    let servingSize: Double
    /// Reference serving unit.
    let servingUnit: String
    /// Whether `PreparedDishHeuristic` classes this row as an assembled dish.
    let isPreparedDish: Bool
    /// Every portion as `unit|description|grams → recipeUnit` (recipeUnit `-` when unrecognised).
    let portions: [String]
    /// What a tap binds: `preferredRecipeUnit` and `defaultRecipeQuantity(for:)`.
    let defaultUnit: String
    /// See ``defaultUnit``.
    let defaultQuantity: Double
    /// Whether the tap-default amount resolves to nutrition.
    let defaultResolves: Bool
    /// Probe amount → whether it resolves (`1 each`, `1 cup`, `1 tbsp`, `100 g`, …).
    let resolves: [String: Bool]
}

/// One query's measured answer.
struct IngredientReplayQuery: Codable, Equatable {
    /// Corpus category (BAKING, PRODUCE, PANTRY, PREFIX).
    let category: String
    /// The typed text.
    let query: String
    /// The editor's own list: `results(for:context: .userTyped)` at the default limit.
    let visible: [String]
    /// The same call at `limit: 10`, fully described.
    let top10: [IngredientReplayRow]
    /// Whether `top10`'s first rows equal `visible` (the demotion-window invariant).
    let visibleIsPrefixOfTop10: Bool
    /// The same call at `limit: 60` (the demotion window, so the ordering is unchanged), as
    /// `name␟dataType␟score` (score `-` on the partial path) — enough to say how far below the fold
    /// a better row sits, and what it scored against the rows above it.
    let deep: [String]
    /// Wall-clock milliseconds for the `limit: 10` call.
    let milliseconds: Int
}

/// One full pass over the corpus against one catalog configuration.
struct IngredientReplayRun: Codable, Equatable {
    /// `base` or `base+branded`.
    let label: String
    /// `FoodCatalog.bundledCount` at run time.
    let bundledCount: Int
    /// Every query, in corpus order.
    let queries: [IngredientReplayQuery]
}

/// The opt-in replay probe. See the file header for the exact call it mirrors and how to run it.
struct IngredientSearchReplayProbeTests {
    /// The amounts every row is probed with, as (label, quantity, unit token).
    static let probeAmounts: [(label: String, quantity: Double, unit: String)] = [
        ("1 each", 1, RecipeUnit.each.rawValue),
        ("1 piece", 1, RecipeUnit.piece.rawValue),
        ("1 cup", 1, RecipeUnit.cup.rawValue),
        ("1 tbsp", 1, RecipeUnit.tablespoon.rawValue),
        ("1 tsp", 1, RecipeUnit.teaspoon.rawValue),
        ("100 g", 100, RecipeUnit.gram.rawValue),
        ("1 oz", 1, RecipeUnit.ounce.rawValue),
        ("1 serving", 1, RecipeUnit.serving.rawValue)
    ]

    @Test func replayRecipeIngredientCorpus() throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FERNLET_REPLAY"] != nil || env["TEST_RUNNER_FERNLET_REPLAY"] != nil else { return }
        let catalog = FoodCatalog.bundled()
        try #require(catalog.bundledCount > 100_000, "the shipped catalog must be loaded")
        let outDirectory = env["FERNLET_REPLAY_OUT"] ?? env["TEST_RUNNER_FERNLET_REPLAY_OUT"]
        Self.emit(Self.run(label: "base", catalog: catalog), to: outDirectory)
        guard let brandedURL = Self.brandedURL(env) else {
            print("IngredientSearchReplayProbe: branded ODR catalog not found — base pass only")
            return
        }
        // The loader's production configuration (BrandedCatalogResourceLoader.attach).
        let branded = try #require(
            SQLiteBundledFoodSource(url: brandedURL, skipPriorityOrder: true, candidateCap: 600),
            "the branded catalog must open"
        )
        catalog.attachBrandedSource(branded)
        Self.emit(Self.run(label: "base+branded", catalog: catalog), to: outDirectory)
        catalog.detachBrandedSource()
    }

    // MARK: - Measurement

    private static func run(label: String, catalog: FoodCatalog) -> IngredientReplayRun {
        let queries = IngredientReplayCorpus.all.map { entry in
            measure(entry.query, category: entry.category, catalog: catalog)
        }
        return IngredientReplayRun(label: label, bundledCount: catalog.bundledCount, queries: queries)
    }

    private static func measure(_ query: String, category: String, catalog: FoodCatalog) -> IngredientReplayQuery {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        // The editor's exact call (CatalogTypeahead.matches): default limit, typed context.
        let visible = catalog.results(for: trimmed, context: .userTyped)
        let started = Date()
        let top = catalog.results(for: trimmed, limit: 10, context: .userTyped)
        let elapsed = Int(Date().timeIntervalSince(started) * 1_000)
        // Cold `scoredResults` ranks exactly like the typed call on a catalog with no history or
        // aliases; it returns nothing on the partial (leave-one-out) path, so those rows get no score.
        let scores = Dictionary(
            catalog.scoredResults(for: trimmed, limit: FoodItemSearchWindow.deep).map { ($0.item.id, $0.score) },
            uniquingKeysWith: { first, _ in first }
        )
        let rows = top.enumerated().map { offset, item in
            row(item, rank: offset + 1, score: scores[item.id])
        }
        let deep = catalog.results(for: trimmed, limit: FoodItemSearchWindow.deep, context: .userTyped)
        return IngredientReplayQuery(
            category: category, query: query, visible: visible.map(\.name), top10: rows,
            visibleIsPrefixOfTop10: Array(top.prefix(visible.count)).map(\.id) == visible.map(\.id),
            deep: deep.map { item in
                let score = scores[item.id].map(String.init) ?? "-"
                return "\(item.name)\u{241F}\(item.dataType.rawValue)\u{241F}\(score)"
            },
            milliseconds: elapsed
        )
    }

    private static func row(_ item: FoodItem, rank: Int, score: Int?) -> IngredientReplayRow {
        let unit = item.preferredRecipeUnit
        let quantity = item.defaultRecipeQuantity(for: unit)
        var resolves: [String: Bool] = [:]
        for amount in probeAmounts {
            resolves[amount.label] = converts(item, quantity: amount.quantity, unit: amount.unit)
        }
        return IngredientReplayRow(
            rank: rank, name: item.name, dataType: item.dataType.rawValue, source: item.source.rawValue,
            brand: item.brandSource, category: item.category, score: score,
            servingSize: item.servingSize, servingUnit: item.servingUnit,
            isPreparedDish: PreparedDishHeuristic.isPreparedDish(item),
            portions: item.portions.map(describe),
            defaultUnit: unit.rawValue, defaultQuantity: quantity,
            defaultResolves: converts(item, quantity: quantity, unit: unit.rawValue),
            resolves: resolves
        )
    }

    /// The editor's `resolvedMacros` test: does this amount become nutrition for this row?
    private static func converts(_ item: FoodItem, quantity: Double, unit: String) -> Bool {
        RecipeIngredient(foodItemId: item.id, quantity: quantity, unit: unit)
            .servingConversion(using: item) != nil
    }

    private static func describe(_ portion: FoodPortion) -> String {
        let mapped = portion.recipeUnit?.rawValue ?? "-"
        let grams = String(format: "%g", portion.gramWeight)
        let amount = String(format: "%g", portion.amount)
        return "\(amount) \(portion.unit)|\(portion.description ?? "")|\(grams)g → \(mapped)"
    }

    // MARK: - Output

    private static func brandedURL(_ env: [String: String]) -> URL? {
        let named = env["FERNLET_REPLAY_BRANDED"] ?? env["TEST_RUNNER_FERNLET_REPLAY_BRANDED"]
        let candidate = named.map { URL(fileURLWithPath: $0) }
            ?? RepoRoot.url("ODRAssets/FoodCatalogBranded.sqlite")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    private static func emit(_ run: IngredientReplayRun, to directory: String?) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do {
            data = try encoder.encode(run)
        } catch {
            print("IngredientSearchReplayProbe: could not encode the \(run.label) run: \(error)")
            return
        }
        let fileName = "replay-\(run.label.replacingOccurrences(of: "+", with: "-")).json"
        if let directory {
            let url = URL(fileURLWithPath: directory).appendingPathComponent(fileName)
            do {
                try data.write(to: url, options: .atomic)
                print("IngredientSearchReplayProbe: wrote \(url.path)")
                return
            } catch {
                print("IngredientSearchReplayProbe: write failed (\(error)); printing instead")
            }
        }
        print("===REPLAY-JSON-BEGIN \(run.label)===")
        print(String(decoding: data, as: UTF8.self))
        print("===REPLAY-JSON-END===")
    }
}

/// How deep the probe looks: `FoodItemSearch.demotionWindow` (60, internal to its module), so a
/// `limit` of this size reorders nothing that the editor's `limit: 6` call would not.
enum FoodItemSearchWindow {
    static let deep = 60
}

/// The recipe-ingredient corpus: common baking, produce and pantry ingredients, plus the mid-word
/// prefixes a person passes through while typing. Chosen by what recipes call for, not by outcome.
enum IngredientReplayCorpus {
    /// One corpus query and the category it was drawn from.
    struct Entry {
        /// BAKING, PRODUCE, PANTRY or PREFIX.
        let category: String
        /// The typed text.
        let query: String
    }

    static let baking = [
        "all-purpose flour", "flour", "bread flour", "whole wheat flour", "sugar", "granulated sugar",
        "brown sugar", "powdered sugar", "baking soda", "baking powder", "vanilla extract",
        "cocoa powder", "chocolate chips", "chocolate chip", "semisweet chocolate chips",
        "semi sweet chocolate chips", "dark chocolate chips", "milk chocolate chips",
        "white chocolate chips", "butter", "unsalted butter", "eggs", "egg", "egg whites", "yeast",
        "cornstarch", "honey", "maple syrup", "molasses", "oats", "rolled oats", "walnuts", "pecans",
        "almonds", "raisins", "shredded coconut", "sprinkles", "cream cheese", "heavy cream",
        "sour cream", "buttermilk", "milk", "whole milk", "almond milk", "oat milk",
        "sweetened condensed milk", "graham crackers", "marshmallows", "peanut butter", "almond flour",
        "coconut oil", "vegetable oil", "canola oil", "olive oil", "extra virgin olive oil"
    ]

    static let produce = [
        "banana", "bananas", "apple", "apples", "lemon", "lemon juice", "lime", "orange",
        "strawberries", "blueberries", "raspberries", "avocado", "tomato", "tomatoes",
        "cherry tomatoes", "onion", "red onion", "yellow onion", "garlic", "garlic clove", "ginger",
        "carrot", "carrots", "celery", "potato", "sweet potato", "spinach", "kale", "lettuce",
        "cucumber", "bell pepper", "red bell pepper", "jalapeno", "broccoli", "cauliflower",
        "zucchini", "mushrooms", "corn", "peas", "green beans", "cilantro", "parsley", "basil",
        "green onions", "scallions"
    ]

    static let pantry = [
        "chicken breast", "chicken thighs", "ground beef", "ground turkey", "bacon", "salmon", "shrimp",
        "tofu", "black beans", "chickpeas", "lentils", "rice", "white rice", "brown rice", "pasta",
        "spaghetti", "quinoa", "bread", "tortillas", "cheddar cheese", "mozzarella", "parmesan", "feta",
        "greek yogurt", "yogurt", "soy sauce", "salt", "black pepper", "cinnamon", "cumin", "paprika",
        "chili powder", "oregano", "garlic powder", "onion powder", "red pepper flakes", "vinegar",
        "apple cider vinegar", "balsamic vinegar", "dijon mustard", "ketchup", "mayonnaise",
        "chicken broth", "tomato paste", "canned tomatoes", "coconut milk", "water"
    ]

    static let prefixes = [
        "choc", "chocolate", "chocolate c", "chocolate ch", "chocolate chi", "chocolate chip", "ban",
        "bana", "banan", "brown s", "baking s", "chicken b", "peanut b"
    ]

    static var all: [Entry] {
        baking.map { Entry(category: "BAKING", query: $0) }
            + produce.map { Entry(category: "PRODUCE", query: $0) }
            + pantry.map { Entry(category: "PANTRY", query: $0) }
            + prefixes.map { Entry(category: "PREFIX", query: $0) }
    }
}
