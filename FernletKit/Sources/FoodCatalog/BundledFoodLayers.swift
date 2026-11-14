import Foundation
import FernletFoundation
import FernletDomainModel

/// The generic-food layers that ship BESIDE `FoodCatalog.sqlite` as their own small SQLite files, in
/// the base's runtime schema (``FoodCatalogSchema``), read by ``SQLiteBundledFoodSource``.
///
/// The owner's 2026-11-13 "compact option": the committed base catalog is never regenerated for a data
/// change and holds only 202 of FNDDS's survey foods, so the rest ship as layers and
/// ``FoodCatalog/bundled(bundle:)`` unions them in through ``LayeredBundledFoodSource``:
///
/// - `FoodCatalogSurvey.sqlite` — FNDDS 2021-2023 (USDA, CC0): the 5,219 survey foods the base lacks,
///   with the base's own FDC-derived ids (`00000000-0000-5000-8000-<fdcId>`), source `usda`, category
///   "Survey (FNDDS) - …", per 100 g with FNDDS's household portions.
/// - `FoodCatalogCNF.sqlite` — Health Canada's Canadian Nutrient File 2026 (Open Government Licence –
///   Canada): the 2,339 foods that are Canadian rather than a copy of USDA data Fernlet already ships,
///   ids `00000000-0000-5000-8002-<Food_Code>`, source ``FoodItemSource/canadianNutrientFile`` (which
///   carries the licence's attribution line).
///
/// Every layer row is typed `FoodDataType.supplementalReference`, the layers' own search tier: below
/// the base's foundation / survey / SR Legacy rows and above branded data for a plain query. Typed as
/// `survey`, the FNDDS rows displaced 238 pinned answers across the corpus suites — SR Legacy
/// ingredients lost to survey dishes ("salt" showed salted nuts) — so the layers fill in where the base
/// has no answer rather than reorder the answers it gives. On the recipe surfaces' identity order a
/// layer row sits below every base and branded row that is the typed ingredient
/// (`FoodItemSearch.ranksAhead`).
///
/// Both are generated, never authored: `Scripts/food-catalog/generic_layers.py` writes them by rule from
/// manifest-pinned inputs (`FoodDataSource/FoodCatalogLayerManifest.json`) and refuses to run if an id
/// repeats or collides with the base. A missing layer is logged and skipped; the catalog then answers
/// from what remains.
public nonisolated enum BundledFoodLayers {
    /// FNDDS 2021-2023's survey foods the base catalog does not ship.
    public static let surveyResourceName = "FoodCatalogSurvey"
    /// The Canadian Nutrient File 2026 foods kept by the generator's rules.
    public static let canadianNutrientFileResourceName = "FoodCatalogCNF"
    /// Every layer, in the order ``LayeredBundledFoodSource`` consults them after the base.
    public static let resourceNames = [surveyResourceName, canadianNutrientFileResourceName]

    /// The layers present in `bundle` (`nil` resolves to `.module`), each opened read-only; an absent or
    /// unreadable layer is logged and left out.
    public static func sources(bundle: Bundle? = nil) -> [BundledFoodSource] {
        resourceNames.compactMap { name -> BundledFoodSource? in
            guard let source = SQLiteBundledFoodSource(bundle: bundle, resourceName: name) else {
                FernletAuditLog.log("foodCatalog.layer.missing", context: ["resource": name])
                return nil
            }
            return source
        }
    }
}

/// Several bundled sources served as ONE: the base catalog (with its supplement) first, then each
/// generic layer (``BundledFoodLayers``).
///
/// Every read is a union in layer order, de-duplicated by id with the earlier layer winning, so a row
/// the base already serves is never shown twice even if a layer were regenerated against an older
/// base. Point lookups (`item(id:)`, `exactMatch`, barcode) answer from the first layer that has the
/// row — the base before any layer, which keeps an exact-name bind on the row it has always bound.
/// Bounded forms fetch at most `limit` rows per layer and keep the first `limit` of the union, base
/// first. `count` is the sum of the layers' counts (their ids are disjoint by construction), and the
/// spelling vocabulary is every layer's words (``FoodSearchVocabulary`` sums a word's counts).
///
/// **Typed searches only.** The layers answer a search only inside a typed search
/// (``TypedSearchScope/isTyped``): candidate fetches, exact-name lookups, brand-field and initialism
/// pools from a machine-generated search (quick-log, the resolver, the recipe importer's bind, the swap
/// sheet's pool) read the base alone. Measured 2026-11-13: with the layers in the machine pools, "cup of
/// coffee" bound CONFIDENTLY to "Coffee creamer, liquid" and "string cheese" / "sprinkles" fell from a
/// confident bind to review. A person choosing from a typed list can weigh a layer row; an automatic
/// bind cannot. Id lookups (`item(id:)`, `items(ids:)`) always answer from every layer, so a logged
/// layer row still resolves.
///
/// Thread-safety: immutable after init; every layer is itself `Sendable`.
public nonisolated final class LayeredBundledFoodSource: BundledFoodSource, @unchecked Sendable {
    /// The most layers one source serves; more are dropped at init (a bound, not a use case).
    public static let maximumLayers = 8

    private let layers: [BundledFoodSource]

    /// Serves `layers` in order, the first being the one whose rows win a shared id.
    public init(layers: [BundledFoodSource]) {
        self.layers = Array(layers.prefix(Self.maximumLayers))
    }

    /// The layers a search may read: every layer inside a typed search, the base alone otherwise
    /// (see the type's "Typed searches only").
    private var searchLayers: ArraySlice<BundledFoodSource> {
        TypedSearchScope.isTyped ? layers[...] : layers.prefix(1)
    }

    /// Every layer's rows.
    public var count: Int { layers.reduce(0) { $0 + $1.count } }

    public func candidates(forQuery query: String, stripsStopwords: Bool) -> [FoodItem] {
        Self.union(searchLayers.map { $0.candidates(forQuery: query, stripsStopwords: stripsStopwords) })
    }

    public func candidates(forQuery query: String, stripsStopwords: Bool, limit: Int) -> [FoodItem] {
        guard limit > 0 else { return [] }
        let lists = searchLayers.map { $0.candidates(forQuery: query, stripsStopwords: stripsStopwords, limit: limit) }
        return Array(Self.union(lists).prefix(limit))
    }

    public func item(id: UUID) -> FoodItem? {
        for layer in layers {
            if let item = layer.item(id: id) { return item }
        }
        return nil
    }

    /// Each layer is asked only for the ids the layers before it did not resolve.
    public func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        var remaining = ids
        var found: [FoodItem] = []
        for layer in layers where !remaining.isEmpty {
            let rows = layer.items(ids: remaining)
            let resolved = Set(rows.map(\.id))
            found += rows
            remaining.removeAll { resolved.contains($0) }
        }
        return found
    }

    public func exactMatch(normalizedName: String) -> FoodItem? {
        for layer in searchLayers {
            if let match = layer.exactMatch(normalizedName: normalizedName) { return match }
        }
        return nil
    }

    public func item(barcode: String) -> FoodItem? {
        for layer in layers {
            if let match = layer.item(barcode: barcode) { return match }
        }
        return nil
    }

    public func brandFieldCandidates(brandWord: String, productQuery: String, stripsStopwords: Bool, limit: Int) -> [FoodItem] {
        guard limit > 0 else { return [] }
        let lists = searchLayers.map {
            $0.brandFieldCandidates(brandWord: brandWord, productQuery: productQuery, stripsStopwords: stripsStopwords, limit: limit)
        }
        return Array(Self.union(lists).prefix(limit))
    }

    /// Every layer's index words, at most `limit` per layer.
    public func searchVocabulary(limit: Int) -> [FoodSearchTerm] {
        guard limit > 0 else { return [] }
        return layers.flatMap { $0.searchVocabulary(limit: limit) }
    }

    public func initialismCandidates(letters: [String], productQuery: String, limit: Int) -> [FoodItem] {
        guard limit > 0 else { return [] }
        let lists = searchLayers.map { $0.initialismCandidates(letters: letters, productQuery: productQuery, limit: limit) }
        return Array(Self.union(lists).prefix(limit))
    }

    /// The lists concatenated in order, each id once (its first occurrence kept).
    private static func union(_ lists: [[FoodItem]]) -> [FoodItem] {
        var seen = Set<UUID>()
        var merged: [FoodItem] = []
        for list in lists {
            for item in list where seen.insert(item.id).inserted {
                merged.append(item)
            }
        }
        return merged
    }
}
