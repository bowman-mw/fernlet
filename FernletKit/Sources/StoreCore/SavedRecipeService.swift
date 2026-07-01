import Foundation
import Observation
import FernletPersistence
import FernletDomainModel
import FernletScoring

/// Owns saved recipes in memory and persists them to their own per-row store. Mirrors `CustomItemService`:
/// mutations are queued per-row and flushed via an APPEND/UPSERT-ONLY repository, so flushing a stale set
/// can't delete rows synced in from another device.
@MainActor
@Observable
public final class SavedRecipeService {
    public private(set) var savedRecipes: [RecipeDefinition] = []

    @ObservationIgnored private let repository: any SavedRecipeRepositoring
    @ObservationIgnored private var pendingUpserts: [UUID: RecipeDefinition] = [:]
    @ObservationIgnored private var pendingDeletes: Set<UUID> = []
    @ObservationIgnored private var saveScheduled = false

    public init(repository: any SavedRecipeRepositoring, initialRecipes: [RecipeDefinition] = []) {
        self.repository = repository
        self.savedRecipes = Self.deduplicatedByID(initialRecipes)
    }

    public func loadAsync() async {
        savedRecipes = Self.deduplicatedByID(await repository.loadAsync())
    }

    public func loadSync() {
        savedRecipes = Self.deduplicatedByID(repository.load())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up recipe rows that synced in from
    /// another device. Call when a remote CloudKit change lands.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
    }

    public func add(_ recipe: RecipeDefinition) {
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

    public func update(_ recipe: RecipeDefinition) {
        guard let index = savedRecipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        savedRecipes[index] = recipe
        enqueueUpsert(recipe)
    }

    public func delete(_ recipe: RecipeDefinition) {
        savedRecipes.removeAll { $0.id == recipe.id }
        enqueueDelete(recipe.id)
    }

    public func reset() {
        savedRecipes = []
        pendingUpserts = [:]
        pendingDeletes = []
        saveScheduled = false
        repository.deleteAll()
    }

    public func flushPendingSave() {
        // Flush whenever mutations are pending, NOT only when a debounced save is scheduled: a prior
        // scheduled flush that failed its write leaves `saveScheduled` false while the pending queues still
        // hold the only un-persisted copy, so gating on `saveScheduled` made the background retry a no-op and
        // silently lost a saved recipe. The pending queues are the real "nothing to do" check.
        saveScheduled = false
        guard !pendingUpserts.isEmpty || !pendingDeletes.isEmpty else { return }
        let upserts = Array(pendingUpserts.values)
        let deletes = Array(pendingDeletes)
        let upsertOK = upserts.isEmpty || repository.upsert(upserts)
        let deleteOK = deletes.isEmpty || repository.delete(ids: deletes)
        assert(upsertOK && deleteOK, "saved recipes should save")
        if upsertOK { pendingUpserts = [:] }
        if deleteOK { pendingDeletes = [] }
    }

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

    private func enqueueUpsert(_ recipe: RecipeDefinition) {
        pendingUpserts[recipe.id] = recipe
        pendingDeletes.remove(recipe.id)
        scheduleSave()
    }

    private func enqueueDelete(_ id: UUID) {
        pendingDeletes.insert(id)
        pendingUpserts[id] = nil
        scheduleSave()
    }

    private static func deduplicatedByID(_ recipes: [RecipeDefinition]) -> [RecipeDefinition] {
        var seen = Set<UUID>()
        var unique: [RecipeDefinition] = []
        unique.reserveCapacity(recipes.count)
        for recipe in recipes where seen.insert(recipe.id).inserted { unique.append(recipe) }
        return unique
    }

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
