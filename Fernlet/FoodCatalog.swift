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
nonisolated final class FoodCatalog: @unchecked Sendable {
    private let source: BundledFoodSource
    private let lock = NSLock()
    private var _userItems: [FoodItem] = []

    init(source: BundledFoodSource) {
        self.source = source
    }

    /// Convenience for production: opens the bundled `FoodCatalog.sqlite`, falling back to an empty
    /// catalog (user items only) if the resource is missing.
    static func bundled(bundle: Bundle = .main) -> FoodCatalog {
        FoodCatalog(source: SQLiteBundledFoodSource(bundle: bundle) ?? InMemoryBundledFoodSource())
    }

    private var userItems: [FoodItem] {
        lock.lock(); defer { lock.unlock() }
        return _userItems
    }

    /// Keeps the catalog's view of user-added foods in sync with `FernletStore.foodItems`.
    func setUserItems(_ items: [FoodItem]) {
        lock.lock(); _userItems = items; lock.unlock()
    }

    /// Number of bundled foods — used by callers that previously guarded on `!foodItems.isEmpty`.
    var bundledCount: Int { source.count }

    // MARK: - Search

    func results(for query: String, limit: Int = 6) -> [FoodItem] {
        FoodItemSearch.results(for: query, in: index(for: query), limit: limit)
    }

    func scoredResults(for query: String, limit: Int = 6) -> [(item: FoodItem, score: Int)] {
        FoodItemSearch.scoredResults(for: query, in: index(for: query), limit: limit)
    }

    func exactNameMatch(forNormalized normalizedName: String) -> FoodItem? {
        let users = userItems
        // Manual user entries win ties (source priority manual > usda > aiResolved), matching the old
        // in-memory `Index.exactNameMatch`.
        if let manual = users.first(where: { $0.source == .manual && FoodItemSearch.normalized($0.name) == normalizedName }) {
            return manual
        }
        if let bundled = source.exactMatch(normalizedName: normalizedName) { return bundled }
        return users.first(where: { FoodItemSearch.normalized($0.name) == normalizedName })
    }

    /// Builds the candidate pool a meal description should be resolved against, mirroring the legacy
    /// `FoodSelectionCandidateBuilder.candidates(for:foodItems:)` but sourcing matches from SQLite.
    func candidates(for description: String, limit: Int = 18) -> [FoodSelectionCandidate] {
        var selected: [FoodItem] = []
        for phrase in FoodSelectionCandidateBuilder.searchPhrases(from: description) {
            for match in results(for: phrase, limit: 4) where !selected.contains(where: { $0.id == match.id }) {
                selected.append(match)
                if selected.count >= limit { break }
            }
            if selected.count >= limit { break }
        }
        return selected.enumerated().map { FoodSelectionCandidate(id: $0.offset + 1, foodItem: $0.element) }
    }

    private func index(for query: String) -> FoodItemSearch.Index {
        FoodItemSearch.Index(foodItems: source.candidates(forQuery: query) + userItems)
    }

    // MARK: - Resolution

    func item(id: UUID) -> FoodItem? {
        userItems.first(where: { $0.id == id }) ?? source.item(id: id)
    }

    func items(ids: [UUID]) -> [FoodItem] {
        guard !ids.isEmpty else { return [] }
        let wanted = Set(ids)
        let users = userItems.filter { wanted.contains($0.id) }
        let resolvedIDs = Set(users.map(\.id))
        let bundled = source.items(ids: ids.filter { !resolvedIDs.contains($0) })
        return users + bundled
    }

    /// The foods referenced by a single recipe's ingredients — what callers pass to MealBuilder /
    /// RecipeShareCodec instead of the whole catalog.
    func items(forRecipe recipe: RecipeDefinition) -> [FoodItem] {
        items(ids: recipe.ingredients.map(\.foodItemId))
    }

    /// The foods referenced across several recipes (deduplicated) — for the meal-plan builder, which
    /// may match any existing recipe.
    func items(forRecipes recipes: [RecipeDefinition]) -> [FoodItem] {
        items(ids: Array(Set(recipes.flatMap { $0.ingredients.map(\.foodItemId) })))
    }

    /// The (zero or one) food a recipe-editor input is currently bound to — enough to resolve its
    /// locked macros without materializing the full catalog.
    func resolved(for input: ManualRecipeIngredientInput) -> [FoodItem] {
        items(ids: [input.selectedFoodItemId].compactMap { $0 })
    }
}
