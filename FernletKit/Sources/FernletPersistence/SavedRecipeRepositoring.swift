import Foundation
import FernletDomainModel

/// The persistence contract for saved recipes, kept in its own per-row store. APPEND/UPSERT-ONLY, mirroring
/// `CustomItemRepositoring` / `CoinLedgerRepositoring`: `upsert` touches only the rows it is given and
/// `delete` removes only the listed ids, so one device can't clobber rows synced in from another. (Replaces
/// the earlier full-replace `save(_:)`.)
@MainActor
public protocol SavedRecipeRepositoring {
    func load() -> [RecipeDefinition]
    func loadAsync() async -> [RecipeDefinition]
    /// Inserts or replaces (by `id`) each recipe. Rows not in `recipes` are left untouched — never deleted.
    @discardableResult func upsert(_ recipes: [RecipeDefinition]) -> Bool
    /// Removes only the rows whose ids are listed; other rows are left untouched.
    @discardableResult func delete(ids: [UUID]) -> Bool
    /// Removes every row (used only by a full account reset).
    @discardableResult func deleteAll() -> Bool
}
