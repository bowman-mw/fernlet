import Foundation
import FernletFoundation
import FernletDomainModel

/// The handful of USDA rows that ship BESIDE `FoodCatalog.sqlite` because the build that produced the
/// committed binary dropped them — read from `Resources/FoodCatalogSupplement.json`.
///
/// Docs/Ingredient-Search-Deep-Research-2026-09-29.md §6.2 / §8 F6: that build dropped every SR Legacy
/// food whose protein, carbohydrate and fat are all zero — exactly 32 foods, which is why "salt",
/// "baking soda" and "water" found nothing. The catalog binary is never regenerated for a data fix,
/// so `Scripts/food-catalog/sr_zero_energy_supplement.py` restores them BY RULE from USDA's SR Legacy
/// file (CC0) into this small JSON in the compact source schema, and ``items(bundle:)`` decodes it
/// through ``FoodDataCatalog/foodItems(from:)`` — the same record decoder every other SR row went
/// through, so ids (`00000000-0000-5000-8000-<fdcId>`), provenance and data type match the catalog's.
/// Only the 26 with zero ENERGY are restored: the six distilled spirits carry 231–295 kcal per 100 g
/// from alcohol, which Fernlet's `Macros` cannot express, so a 0/0/0 row would claim vodka is free.
///
/// Bounded: a file with more than ``maximumRows`` rows is refused, not truncated.
public nonisolated enum BundledFoodSupplement {
    /// The resource's base name in this module's bundle.
    public static let resourceName = "FoodCatalogSupplement"
    /// The most rows the supplement may carry. The shipped file has 26; anything near this bound is a
    /// different kind of data and belongs in the catalog build, not beside it.
    public static let maximumRows = 256

    /// The supplement's rows, or none when the resource is absent, unreadable or over the bound (each
    /// case logged). `nil` resolves to `.module`, which cannot be a default argument in public API.
    public static func items(bundle: Bundle? = nil) -> [FoodItem] {
        let bundle = bundle ?? .module
        guard let url = bundle.url(forResource: resourceName, withExtension: "json") else {
            FernletAuditLog.log("foodCatalog.supplement.missing")
            return []
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            FernletAuditLog.log("foodCatalog.supplement.unreadable", context: ["error": "\(error)"])
            return []
        }
        let items = FoodDataCatalog.foodItems(from: data)
        guard items.count <= maximumRows else {
            FernletAuditLog.log("foodCatalog.supplement.oversized", context: ["rows": "\(items.count)"])
            return []
        }
        return items
    }
}

/// The base SQLite catalog plus its ``BundledFoodSupplement`` rows, served as ONE bundled source.
///
/// ``FoodCatalog/bundled(bundle:)`` wraps the base catalog in this, so a supplement row is searched,
/// point-looked-up and batch-resolved exactly like a row of the file (a saved recipe line on
/// "Salt, table" resolves by id like any other). `count` is honest: file rows plus supplement rows.
///
/// Retrieval mirrors the FTS gate: a supplement row is a candidate when every search token (in any of
/// its `FoodItemSearch.matchVariants`) prefixes a word of its name, category or tags — the columns
/// the FTS index covers — so the scorer then applies the same floors it applies to file rows, and a
/// word the catalog has never seen still finds nothing (`FoodCatalog.mayRelaxOneToken` depends on
/// that). A supplement row whose id the file already serves is dropped at init, so the supplement
/// retires itself row by row if a regenerated catalog ever restores the food.
///
/// Thread-safety: immutable after init; `primary` is itself `Sendable`.
public nonisolated final class SupplementedBundledFoodSource: BundledFoodSource, @unchecked Sendable {
    private let primary: BundledFoodSource
    private let supplement: [(item: FoodItem, words: Set<String>)]

    /// Wraps `primary`, adding every `supplement` row `primary` does not already serve (at most
    /// ``BundledFoodSupplement/maximumRows`` are considered).
    public init(primary: BundledFoodSource, supplement: [FoodItem]) {
        self.primary = primary
        self.supplement = supplement.prefix(BundledFoodSupplement.maximumRows)
            .filter { primary.item(id: $0.id) == nil }
            .map { item in
                let text = ([item.name, item.category] + item.tags).joined(separator: " ")
                return (item, Set(FoodItemSearch.normalized(text).split(separator: " ").map(String.init)))
            }
    }

    /// File rows plus supplement rows.
    public var count: Int { primary.count + supplement.count }

    public func candidates(forQuery query: String, stripsStopwords: Bool) -> [FoodItem] {
        primary.candidates(forQuery: query, stripsStopwords: stripsStopwords)
            + supplementMatches(query, stripsStopwords: stripsStopwords)
    }

    /// The bounded (partial-fallback / existence-check) form: supplement matches first, so a staple
    /// the file lacks is never truncated away behind file rows, then capped at `limit`.
    public func candidates(forQuery query: String, stripsStopwords: Bool, limit: Int) -> [FoodItem] {
        guard limit > 0 else { return [] }
        let matches = supplementMatches(query, stripsStopwords: stripsStopwords)
        let base = primary.candidates(forQuery: query, stripsStopwords: stripsStopwords, limit: limit)
        return Array((matches + base).prefix(limit))
    }

    public func item(id: UUID) -> FoodItem? {
        primary.item(id: id) ?? supplement.first { $0.item.id == id }?.item
    }

    public func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        let found = primary.items(ids: ids)
        let foundIDs = Set(found.map(\.id))
        let wanted = Set(ids)
        return found + supplement.map(\.item).filter { wanted.contains($0.id) && !foundIDs.contains($0.id) }
    }

    public func exactMatch(normalizedName: String) -> FoodItem? {
        if let match = primary.exactMatch(normalizedName: normalizedName) { return match }
        return supplement.map(\.item)
            .filter { FoodItemSearch.normalized($0.name) == normalizedName }
            .min { $0.name < $1.name }
    }

    public func item(barcode: String) -> FoodItem? {
        primary.item(barcode: barcode)
    }

    /// Supplement rows passing the FTS-equivalent prefix-AND gate for `query`.
    private func supplementMatches(_ query: String, stripsStopwords: Bool) -> [FoodItem] {
        let tokens = FoodItemSearch.searchTokens(in: query, stripsStopwords: stripsStopwords)
        guard !tokens.isEmpty, !supplement.isEmpty else { return [] }
        let variants = tokens.map(FoodItemSearch.matchVariants(for:))
        return supplement.filter { entry in
            variants.allSatisfy { forms in
                forms.contains { form in entry.words.contains { $0.hasPrefix(form) } }
            }
        }.map(\.item)
    }
}
