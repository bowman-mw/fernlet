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
/// Invariants: the buffer's pending queues are the sole un-persisted copy of a mutation —
/// ``flushPendingSave()`` clears each queue only after its confirmed write, and ``reloadFromStore()``
/// re-applies still-pending mutations after a failed flush, so a just-saved recipe is never silently
/// lost (the shared contract lives on ``DebouncedRowBuffer``). `@MainActor` and `@Observable`.
@MainActor
@Observable
public final class SavedRecipeService {
    /// The in-memory recipe list, newest-first for new saves, union-merged (deduplicated by id) on load.
    public private(set) var savedRecipes: [RecipeDefinition] = []

    @ObservationIgnored private let repository: any SavedRecipeRepositoring
    /// The shared debounced per-row queue — the sole un-persisted copy of local mutations (see
    /// ``DebouncedRowBuffer``). Its write closures capture `repository`, never `self`.
    @ObservationIgnored private let buffer: DebouncedRowBuffer<RecipeDefinition>

    /// Creates the service over its per-row store; `initialRecipes` seeds the list before the first load.
    public init(repository: any SavedRecipeRepositoring, initialRecipes: [RecipeDefinition] = []) {
        self.repository = repository
        self.buffer = DebouncedRowBuffer(
            upsert: { repository.upsert($0) },
            delete: { repository.delete(ids: $0) }
        )
        self.savedRecipes = initialRecipes.deduplicatedByID()
    }

    /// Async variant of ``loadSync()`` for the off-main initial load.
    public func loadAsync() async {
        savedRecipes = await repository.loadAsync().deduplicatedByID()
    }

    /// Replaces the in-memory list with the store's rows, union-merged by id.
    public func loadSync() {
        savedRecipes = repository.load().deduplicatedByID()
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
        guard buffer.hasPending else { return }
        let merged = (Array(buffer.pendingUpserts.values) + savedRecipes).deduplicatedByID()
        savedRecipes = merged.filter { !buffer.pendingDeletes.contains($0.id) }
    }

    /// Inserts a recipe at the top of the list, routing to ``update(_:)`` when its id already exists.
    /// A web-imported recipe replaces any prior recipe from the same source URL (matched under
    /// `RecipeSourceURLMatcher` normalization, the same rule ``recipe(matchingSourceURL:)`` uses) —
    /// the superseded rows are explicitly enqueue-deleted so the append-only store drops them too.
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
            // append-only store (a full-replace save used to drop it implicitly). "Same source" is the
            // normalized match — a re-import whose URL differs only in host case or a fragment still
            // supersedes. FernletStore.addSavedRecipe mirrors this match for the sealed-photo cleanup;
            // the two must stay in agreement or re-imports strand photos.
            let supersededIDs = savedRecipes
                .filter { supersedes($0, sourceURLString: sourceURLString) && $0.id != recipe.id }
                .map { $0.id }
            savedRecipes.removeAll { supersedes($0, sourceURLString: sourceURLString) }
            for id in supersededIDs { buffer.enqueueDelete(id) }
        }
        savedRecipes.insert(recipe, at: 0)
        buffer.enqueueUpsert(recipe)
    }

    /// Whether `candidate` is an existing row that a new import from `sourceURLString` replaces.
    private func supersedes(_ candidate: RecipeDefinition, sourceURLString: String) -> Bool {
        guard let existing = candidate.webImport?.sourceURLString else { return false }
        return RecipeSourceURLMatcher.urlsMatch(existing, sourceURLString)
    }

    /// The saved recipe whose web-import source matches `urlString` under `RecipeSourceURLMatcher`
    /// normalization, or `nil`. This is the zero-network duplicate check: import paths call it BEFORE
    /// fetching, and on a hit they surface the existing recipe instead of touching the network
    /// (owner decision 2026-08-09).
    public func recipe(matchingSourceURL urlString: String) -> RecipeDefinition? {
        savedRecipes.first { candidate in
            guard let source = candidate.webImport?.sourceURLString else { return false }
            return RecipeSourceURLMatcher.urlsMatch(source, urlString)
        }
    }

    /// Replaces the stored recipe with the same id in place; unknown ids are ignored.
    public func update(_ recipe: RecipeDefinition) {
        guard let index = savedRecipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        savedRecipes[index] = recipe
        buffer.enqueueUpsert(recipe)
    }

    /// Removes the recipe from the list and enqueues its per-row delete.
    public func delete(_ recipe: RecipeDefinition) {
        savedRecipes.removeAll { $0.id == recipe.id }
        buffer.enqueueDelete(recipe.id)
    }

    /// Returns whether the persisted rows were actually deleted. Threaded back so "delete everything" can
    /// report a failed per-row CloudKit delete (recipes left on disk to re-sync) instead of the funnel
    /// discarding it and claiming a complete wipe.
    public func reset() -> Bool {
        savedRecipes = []
        buffer.clear()
        return repository.deleteAll()
    }

    /// Writes any pending upserts/deletes to the store now; a failed write keeps that queue for
    /// retry (the full durability contract lives on ``DebouncedRowBuffer/flush()``).
    public func flushPendingSave() {
        buffer.flush()
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
            confidence: hasMacros ? MealConfidence.recipe.token : MealConfidence.recipeNoMacros.token,
            note: hasMacros ? "Logged from URL recipe." : "Logged from URL recipe. Macros not available.",
            source: MealLogSource.webImport
        )
    }
}
