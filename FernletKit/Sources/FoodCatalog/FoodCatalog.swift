import Foundation
import FernletDomainModel

/// The app's food lookup surface. Replaces the old in-memory `allFoodItems` array: the ~13k bundled
/// USDA/curated foods live in a read-only SQLite store (`BundledFoodSource`) and are queried on
/// demand, while the small mutable set of user-added items is held as a snapshot. Search runs the
/// existing `FoodItemSearch` scorer over (SQLite candidates + user items), preserving all of the
/// preparation / form / data-type ranking; point lookups resolve ingredient IDs straight from SQLite.
///
/// Thread-safe: the SQLite source serializes its own access and the user-items snapshot is guarded by
/// a lock, so the catalog can be queried from any actor (the AI meal-resolution path runs off the
/// main actor).
public nonisolated final class FoodCatalog: @unchecked Sendable {
    private let source: BundledFoodSource
    private let lock = NSLock()
    private var _userItems: [FoodItem] = []
    /// Optional secondary bundled source — the full branded catalog delivered later via On-Demand
    /// Resource and purgeable at runtime. Guarded by the SAME `lock` as `_userItems`; every read
    /// snapshots it into a local `let` so a concurrent `detachBrandedSource()` mid-query is safe.
    private var _brandedSource: BundledFoodSource?

    public init(source: BundledFoodSource) {
        self.source = source
    }

    /// Convenience for production: opens the bundled `FoodCatalog.sqlite`, falling back to an empty
    /// catalog (user items only) if the resource is missing. `bundle` defaults to this module's
    /// resource bundle (`.module`); it is passed as `nil` here because `.module` is synthesized as
    /// internal and cannot appear as a default-argument value in this public API.
    public static func bundled(bundle: Bundle? = nil) -> FoodCatalog {
        FoodCatalog(source: SQLiteBundledFoodSource(bundle: bundle) ?? InMemoryBundledFoodSource())
    }

    private var userItems: [FoodItem] {
        lock.lock(); defer { lock.unlock() }
        return _userItems
    }

    private var brandedSource: BundledFoodSource? {
        lock.lock(); defer { lock.unlock() }
        return _brandedSource
    }

    /// Keeps the catalog's view of user-added foods in sync with `FernletStore.foodItems`.
    public func setUserItems(_ items: [FoodItem]) {
        lock.lock(); _userItems = items; lock.unlock()
    }

    /// Attaches the optional branded catalog (e.g. once the On-Demand Resource has downloaded).
    /// Replaces any previously attached source. Every read unions base + branded + user items.
    public func attachBrandedSource(_ source: BundledFoodSource) {
        lock.lock(); _brandedSource = source; lock.unlock()
    }

    /// Drops the branded catalog (e.g. when the ODR is purged). Reads fall back to base + user items.
    public func detachBrandedSource() {
        lock.lock(); _brandedSource = nil; lock.unlock()
    }

    /// Whether a branded source is currently attached.
    public var hasBrandedSource: Bool {
        lock.lock(); defer { lock.unlock() }
        return _brandedSource != nil
    }

    /// Number of bundled foods — used by callers that previously guarded on `!foodItems.isEmpty`.
    /// Includes the branded source's rows when one is attached.
    public var bundledCount: Int { source.count + (brandedSource?.count ?? 0) }

    // MARK: - Search

    public func results(for query: String, limit: Int = 6) -> [FoodItem] {
        FoodItemSearch.results(for: query, in: index(for: query), limit: limit)
    }

    public func scoredResults(for query: String, limit: Int = 6) -> [(item: FoodItem, score: Int)] {
        FoodItemSearch.scoredResults(for: query, in: index(for: query), limit: limit)
    }

    public func exactNameMatch(forNormalized normalizedName: String) -> FoodItem? {
        let users = userItems
        let branded = brandedSource
        // Manual user entries win ties (source priority manual > usda > aiResolved), matching the old
        // in-memory `Index.exactNameMatch`.
        if let manual = users.first(where: { $0.source == .manual && FoodItemSearch.normalized($0.name) == normalizedName }) {
            return manual
        }
        if let bundled = source.exactMatch(normalizedName: normalizedName) { return bundled }
        if let brandedMatch = branded?.exactMatch(normalizedName: normalizedName) { return brandedMatch }
        return users.first(where: { FoodItemSearch.normalized($0.name) == normalizedName })
    }

    /// Builds the candidate pool a meal description should be resolved against, mirroring the legacy
    /// `FoodSelectionCandidateBuilder.candidates(for:foodItems:)` but sourcing matches from SQLite.
    public func candidates(for description: String, limit: Int = 18) -> [FoodSelectionCandidate] {
        var selected: [FoodItem] = []
        for phrase in FoodSelectionCandidateBuilder.searchPhrases(from: description) {
            for match in results(for: phrase, limit: 4) where !selected.contains(where: { $0.id == match.id }) {
                selected.append(match)
                if selected.count >= limit { break }
            }
            if selected.count >= limit { break }
        }
        // Prefer raw ingredients over assembled/prepared dishes for a bare-ingredient query (mirrors
        // FoodSelectionCandidateBuilder.candidates), so the candidate pool the resolver/AI draws from
        // isn't dominated by FNDDS "sandwich"/"on-bun" composites that outrank raw foods on data-type.
        let ordered = PreparedDishHeuristic.demotingDishes(selected, forQuery: description)
        return ordered.enumerated().map { FoodSelectionCandidate(id: $0.offset + 1, foodItem: $0.element) }
    }

    private func index(for query: String) -> FoodItemSearch.Index {
        let branded = brandedSource
        let candidates = source.candidates(forQuery: query) + (branded?.candidates(forQuery: query) ?? [])
        return FoodItemSearch.Index(foodItems: candidates + userItems)
    }

    // MARK: - Resolution

    public func item(id: UUID) -> FoodItem? {
        let branded = brandedSource
        return userItems.first(where: { $0.id == id }) ?? source.item(id: id) ?? branded?.item(id: id)
    }

    /// Resolves a scanned product barcode: user items first (a product the user already paired via
    /// the label-scan flow — their macros win), then the bundled catalog (only answers when the
    /// backing file is v2 with barcode data; the shipped v1 file returns nil). `raw` may be any
    /// scanner rendering (UPC-A/EAN-13/EAN-8/GTIN-14) — comparison is on the normalized GTIN.
    public func item(forBarcode raw: String) -> FoodItem? {
        guard let normalized = FoodBarcode.normalized(raw) else { return nil }
        let branded = brandedSource
        if let user = userItems.first(where: { FoodBarcode.normalized($0.barcode) == normalized }) {
            return user
        }
        return source.item(barcode: normalized) ?? branded?.item(barcode: normalized)
    }

    public func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        let branded = brandedSource
        let wanted = Set(ids)
        let users = userItems.filter { wanted.contains($0.id) }
        var resolvedIDs = Set(users.map(\.id))
        let bundled = source.items(ids: ids.filter { !resolvedIDs.contains($0) })
        resolvedIDs.formUnion(bundled.map(\.id))
        let brandedItems = branded?.items(ids: ids.filter { !resolvedIDs.contains($0) }) ?? []
        // First source that has an id wins: user items > base > branded (dedupe by id).
        return users + bundled + brandedItems
    }

    /// The foods referenced by a single recipe's ingredients — what callers pass to MealBuilder /
    /// RecipeShareCodec instead of the whole catalog.
    public func items(forRecipe recipe: RecipeDefinition) -> [FoodItem] {
        items(ids: recipe.ingredients.map(\.foodItemId))
    }

    /// The foods referenced across several recipes (deduplicated) — for the meal-plan builder, which
    /// may match any existing recipe.
    public func items(forRecipes recipes: [RecipeDefinition]) -> [FoodItem] {
        items(ids: Array(Set(recipes.flatMap { $0.ingredients.map(\.foodItemId) })))
    }

    /// The (zero or one) food a recipe-editor input is currently bound to — enough to resolve its
    /// locked macros without materializing the full catalog.
    public func resolved(for input: ManualRecipeIngredientInput) -> [FoodItem] {
        items(ids: [input.selectedFoodItemId].compactMap { $0 })
    }
}
