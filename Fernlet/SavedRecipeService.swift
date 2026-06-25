import Foundation
import Observation

@MainActor
@Observable
final class SavedRecipeService {
    private(set) var savedRecipes: [RecipeDefinition] = []

    @ObservationIgnored private let repository: SavedRecipeRepository
    @ObservationIgnored private var saveScheduled = false

    convenience init() {
        self.init(repository: SavedRecipeRepository())
    }

    init(repository: SavedRecipeRepository, initialRecipes: [RecipeDefinition] = []) {
        self.repository = repository
        self.savedRecipes = initialRecipes
    }

    func loadAsync() async {
        savedRecipes = await repository.loadAsync()
    }

    func loadSync() {
        savedRecipes = repository.load()
    }

    func add(_ recipe: RecipeDefinition) {
        if let sourceURLString = recipe.webImport?.sourceURLString, !sourceURLString.isEmpty {
            savedRecipes.removeAll { $0.webImport?.sourceURLString == sourceURLString }
        }
        savedRecipes.insert(recipe, at: 0)
        scheduleSave()
    }

    func update(_ recipe: RecipeDefinition) {
        guard let index = savedRecipes.firstIndex(where: { $0.id == recipe.id }) else { return }
        savedRecipes[index] = recipe
        scheduleSave()
    }

    func delete(_ recipe: RecipeDefinition) {
        savedRecipes.removeAll { $0.id == recipe.id }
        scheduleSave()
    }

    func reset() {
        savedRecipes = []
        scheduleSave()
    }

    func flushPendingSave() {
        guard saveScheduled else { return }
        saveScheduled = false
        let saved = repository.save(savedRecipes)
        assert(saved, "saved recipes should save")
    }

    func shareText(for recipe: RecipeDefinition) -> String {
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

    static func makeMeal(from recipe: RecipeDefinition, mealType: MealType?) -> Meal {
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
            quality: macros.protein >= 25 ? .good : .ok,
            confidence: hasMacros ? "Recipe" : "Recipe (no macros)",
            note: hasMacros ? "Logged from URL recipe." : "Logged from URL recipe. Macros not available.",
            source: MealLogSource.webImport
        )
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
