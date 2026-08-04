import Foundation
import Observation
import FernletPersistence
import FernletDomainModel
import FernletScoring

/// Owns saved recipes in memory and persists them to their own per-row store. Mirrors ``CustomItemService``:
/// mutations are queued per-row and flushed via an APPEND/UPSERT-ONLY repository, so flushing a stale set
/// can't delete rows synced in from another device.
///
/// Collaborators: the injected `SavedRecipeRepositoring` store (concretely CloudKitSync's
/// `SavedRecipeRepository` — this protocol inversion is what keeps StoreCore free of any CloudKitSync
/// dependency) and `FernletStore`, which owns the instance, routes web imports, mesh recipe shares, and
/// manual saves through ``add(_:)``, and calls ``reloadFromStore()`` on remote CloudKit changes. Beyond
/// storage, the type also hosts two pure recipe conveniences: ``shareText(for:)`` (the share-sheet body)
/// and ``makeMeal(from:mealType:)`` (recipe → loggable meal).
///
/// Invariants: the pending queues are the sole un-persisted copy of a mutation — ``flushPendingSave()``
/// clears each queue only after its confirmed write, and ``reloadFromStore()`` re-applies still-pending
/// mutations after a failed flush, so a just-saved recipe is never silently lost. `@MainActor` and
/// `@Observable`.
@MainActor
@Observable
public final class SavedRecipeService {
    /// The in-memory recipe list, newest-first for new saves, union-merged (deduplicated by id) on load.
    public private(set) var savedRecipes: [RecipeDefinition] = []

    @ObservationIgnored private let repository: any SavedRecipeRepositoring
    @ObservationIgnored private var pendingUpserts: [UUID: RecipeDefinition] = [:]
    @ObservationIgnored private var pendingDeletes: Set<UUID> = []
    @ObservationIgnored private var saveScheduled = false

    /// Creates the service over its per-row store; `initialRecipes` seeds the list before the first load.
    public init(repository: any SavedRecipeRepositoring, initialRecipes: [RecipeDefinition] = []) {
        self.repository = repository
        self.savedRecipes = Self.deduplicatedByID(initialRecipes)
    }

    /// Async variant of ``loadSync()`` for the off-main initial load.
    public func loadAsync() async {
        savedRecipes = Self.deduplicatedByID(await repository.loadAsync())
    }

    /// Replaces the in-memory list with the store's rows, union-merged by id.
    public func loadSync() {
        savedRecipes = Self.deduplicatedByID(repository.load())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up recipe rows that synced in from
    /// another device. Call when a remote CloudKit change lands.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
        // If the flush FAILED, its mutations survive only in the pending queues (the write rolled back), and
        // `loadSync()` just replaced `savedRecipes` with store contents that LACK them — dropping a just-saved
        // recipe from the list. Re-apply the still-pending mutations on top of the freshly loaded set (pending
        // upserts win by id via the same dedup used everywhere; pending deletes are removed), keeping the
        // queues intact so the next scheduled save retries. On a SUCCESSFUL flush both queues are empty, so
        // this is a no-op and `loadSync()` stays authoritative.
        guard !pendingUpserts.isEmpty || !pendingDeletes.isEmpty else { return }
        let merged = Self.deduplicatedByID(Array(pendingUpserts.values) + savedRecipes)
        savedRecipes = merged.filter { !pendingDeletes.contains($0.id) }
    }

    /// Inserts a recipe at the top of the list, routing to ``update(_:)`` when its id already exists.
    /// A web-imported recipe replaces any prior recipe from the same source URL — the superseded rows
    /// are explicitly enqueue-deleted so the append-only store drops them too.
    public func add(_ recipe: RecipeDefinition) {
        // Id-guard: re-adding an already-present recipe (e.g. a double-tapped save routing the same fixed-id
        // fork through here) must not create a duplicate-identity row in this append-only store — route it
        // to the by-id update instead. `add` remains insert-at-top for genuinely new ids.
        if savedRecipes.contains(where: { $0.id == recipe.id }) {
            update(recipe)
            return
        }
        if let sourceURLString = recipe.webImport?.sourceURLString, !sourceURLString.isEmpty {
            // Replacing a same-source recipe means its old row must be explicitly deleted from the
            // append-only store (a full-replace save used to drop it implicitly).
            let supersededIDs = savedRecipes
                .filter { $0.webImport?.sourceURLString == sourceURLString && $0.id != recipe.id }
                .map { $0.id }
            savedRecipes.removeAll { $0.webImport?.sourceURLString == sourceURLString }
            for id in supersededIDs { enqueueDelete(id) }
        }
        savedRecipes.insert(recipe, at: 0)
        enqueueUpsert(recipe)
    }

    /// Replaces the stored recipe with the same id in place; unknown ids are ignored.
    public func update(_ recipe: RecipeDefinition) {
        guard let index = savedRecipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        savedRecipes[index] = recipe
        enqueueUpsert(recipe)
    }

    /// Removes the recipe from the list and enqueues its per-row delete.
    public func delete(_ recipe: RecipeDefinition) {
        savedRecipes.removeAll { $0.id == recipe.id }
        enqueueDelete(recipe.id)
    }

    /// Returns whether the persisted rows were actually deleted. Threaded back so "delete everything" can
    /// report a failed per-row CloudKit delete (recipes left on disk to re-sync) instead of the funnel
    /// discarding it and claiming a complete wipe.
    @discardableResult
    public func reset() -> Bool {
        savedRecipes = []
        pendingUpserts = [:]
        pendingDeletes = []
        saveScheduled = false
        return repository.deleteAll()
    }

    /// Writes any pending upserts/deletes to the store now; a failed write keeps that queue for retry.
    public func flushPendingSave() {
        // Flush whenever mutations are pending, NOT only when a debounced save is scheduled: a prior
        // scheduled flush that failed its write leaves `saveScheduled` false while the pending queues still
        // hold the only un-persisted copy, so gating on `saveScheduled` made the background retry a no-op and
        // silently lost a saved recipe. The pending queues are the real "nothing to do" check.
        saveScheduled = false
        guard !pendingUpserts.isEmpty || !pendingDeletes.isEmpty else { return }
        let upserts = Array(pendingUpserts.values)
        let deletes = Array(pendingDeletes)
        // Clear each pending queue only AFTER its confirmed write — the queues are the sole un-persisted
        // copy of these mutations, so dropping them on a failed write would silently lose a saved recipe. On
        // failure, keep them; the next mutation (or the background flush) retries, and `reloadFromStore`
        // re-applies them so the in-memory list still reflects the pending mutations. A failed write is an
        // expected, handled runtime condition (Core Data / CloudKit hiccup), NOT a precondition violation — so
        // it must not trap; the retry path above is exactly what makes it recoverable.
        let upsertOK = upserts.isEmpty || repository.upsert(upserts)
        let deleteOK = deletes.isEmpty || repository.delete(ids: deletes)
        if upsertOK { pendingUpserts = [:] }
        if deleteOK { pendingDeletes = [] }
    }

    /// Renders the plain-text share-sheet body for a recipe: name, per-serving macros, notes,
    /// ingredient lines, and the source URL when the recipe was web-imported.
    public func shareText(for recipe: RecipeDefinition) -> String {
        let webImport = recipe.webImport
        let macros = webImport?.macros ?? Macros(protein: 0, carbs: 0, fat: 0)
        var lines: [String] = [recipe.name, ""]
        if macros.protein > 0 || macros.carbs > 0 || macros.fat > 0 {
            let servingNote = recipe.servings > 1 ? " (per serving, \(recipe.servings) servings)" : ""
            lines += ["Macros\(servingNote): P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g", ""]
        }
        if !recipe.notes.isEmpty {
            lines += [recipe.notes, ""]
        }
        lines += ["Ingredients:"]
        lines += (webImport?.ingredientLines ?? []).map { "- \($0)" }
        if let sourceURL = webImport?.sourceURL {
            lines += ["", "Source: \(sourceURL.absoluteString)"]
        }
        return lines.joined(separator: "\n")
    }

    /// Builds a loggable `Meal` from a saved recipe, snapshotting its macros/micronutrients and
    /// classifying the meal type from the recipe name when the caller passes none.
    public static func makeMeal(from recipe: RecipeDefinition, mealType: MealType?) -> Meal {
        let macros = recipe.webImport?.macros ?? Macros(protein: 0, carbs: 0, fat: 0)
        let hasMacros = macros.protein > 0 || macros.carbs > 0 || macros.fat > 0
        return Meal(
            name: recipe.name,
            mealType: mealType ?? MealParser.classifyMealType(recipe.name),
            macros: macros,
            macroSnapshot: macros,
            micronutrientSnapshot: recipe.webImport?.micronutrients ?? Micronutrients(),
            mealSource: .recipe,
            isAIFallback: false,
            quality: macros.protein >= Macros.goodProteinThreshold ? .good : .ok,
            confidence: hasMacros ? "Recipe" : "Recipe (no macros)",
            note: hasMacros ? "Logged from URL recipe." : "Logged from URL recipe. Macros not available.",
            source: MealLogSource.webImport
        )
    }

    // MARK: - Internals

    /// Queues an upsert (cancelling any pending delete of the same id) and schedules a flush.
    private func enqueueUpsert(_ recipe: RecipeDefinition) {
        pendingUpserts[recipe.id] = recipe
        pendingDeletes.remove(recipe.id)
        scheduleSave()
    }

    /// Queues a delete (cancelling any pending upsert of the same id) and schedules a flush.
    private func enqueueDelete(_ id: UUID) {
        pendingDeletes.insert(id)
        pendingUpserts[id] = nil
        scheduleSave()
    }

    /// Collapses rows that share an id, keeping the first seen — the application-level union-merge
    /// for the per-row store. Mirrors `CoinEconomy.deduplicatedByID`.
    private static func deduplicatedByID(_ recipes: [RecipeDefinition]) -> [RecipeDefinition] {
        var seen = Set<UUID>()
        var unique: [RecipeDefinition] = []
        unique.reserveCapacity(recipes.count)
        for recipe in recipes where seen.insert(recipe.id).inserted { unique.append(recipe) }
        return unique
    }

    /// Coalesces mutations into one debounced main-actor flush per burst.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            await Task.yield()
            await MainActor.run {
                guard let self else { return }
                self.flushPendingSave()
            }
        }
    }
}
