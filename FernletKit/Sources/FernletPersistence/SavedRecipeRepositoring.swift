import Foundation
import FernletDomainModel

/// The persistence contract for saved recipes, kept in its own per-row store. APPEND/UPSERT-ONLY, mirroring
/// ``CustomItemRepositoring`` / ``CoinLedgerRepositoring``: ``upsert(_:)`` touches only the rows it is given
/// and ``delete(ids:)`` removes only the listed ids, so one device can't clobber rows synced in from another.
/// (Replaces the earlier full-replace `save(_:)`.)
///
/// The Core Data + iCloud conformer is `SavedRecipeRepository` (in `CloudKitSync`). `SavedRecipeService`
/// (in `StoreCore`) was inverted onto this protocol precisely so `StoreCore` needs no `CloudKitSync`
/// dependency — this seam is what keeps the service portable across backing stores. `@MainActor`.
@MainActor
public protocol SavedRecipeRepositoring {
    /// Loads every persisted saved recipe synchronously.
    func load() -> [RecipeDefinition]
    /// Awaitable variant of ``load()`` for callers off the blocking startup path.
    func loadAsync() async -> [RecipeDefinition]
    /// Inserts or replaces (by `id`) each recipe. Rows not in `recipes` are left untouched — never deleted.
    func upsert(_ recipes: [RecipeDefinition]) -> Bool
    /// Removes only the rows whose ids are listed; other rows are left untouched.
    func delete(ids: [UUID]) -> Bool
    /// Removes every row (used only by a full account reset).
    func deleteAll() -> Bool
}
