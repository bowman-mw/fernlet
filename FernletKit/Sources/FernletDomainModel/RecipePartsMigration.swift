import Foundation
import CryptoKit

// Recipes as building blocks, step 5 (design §7, owner pick P07a): today's multipart recipes become
// separate recipes, once, on every device that runs this build.
//
// Every part except the LAST becomes its own saved recipe (the dressing); the last part (the salad,
// where the recipe comes together) stays in the original recipe, which keeps its id, name, photo and
// history, and gets one line per extracted part using ALL of that part's servings. A part's servings are
// the original recipe's servings, so that line converts at a scale of exactly 1 and the recipe's
// numbers are unchanged to the gram.
//
// New ids are DERIVED from (recipe id, part id), so two devices that migrate the same recipe make the
// same recipes and the same lines, and a sync merges them instead of doubling them. A part with no
// ingredients (steps only) is not a recipe of its own: its steps stay in the original recipe, labelled
// with the part's name, so nothing is lost. The migration is idempotent: a recipe with no parts is
// returned unchanged, and a migrated recipe has none.

/// The one-time conversion of multipart recipes into separate recipes.
public nonisolated enum RecipePartsMigration {
    /// `recipes` with every multipart recipe converted, each original keeping its position and the new
    /// part recipes inserted right after it, plus how many recipes were converted. Unchanged (and 0)
    /// when no recipe has parts.
    public static func migrated(_ recipes: [RecipeDefinition]) -> (recipes: [RecipeDefinition], converted: Int) {
        guard recipes.contains(where: { $0.components != nil }) else { return (recipes, 0) }
        let existingIDs = Set(recipes.map(\.id))
        var result: [RecipeDefinition] = []
        var converted = 0
        for recipe in recipes {
            guard recipe.components != nil else {
                result.append(recipe)
                continue
            }
            let split = split(recipe)
            result.append(split.parent)
            // A part recipe another device already made (and synced in) is not made twice.
            result += split.parts.filter { !existingIDs.contains($0.id) }
            converted += 1
        }
        return (result, converted)
    }

    /// One multipart recipe as its parent and the part recipes it now uses. A recipe that does not
    /// resolve to two parts just loses its (empty) partition.
    public static func split(_ recipe: RecipeDefinition) -> (parent: RecipeDefinition, parts: [RecipeDefinition]) {
        var parent = recipe
        parent.components = nil
        let resolved = recipe.resolvedComponents
        guard resolved.count >= RecipeComponentLimits.minComponents, let last = resolved.last else {
            return (parent, [])
        }
        var partRecipes: [RecipeDefinition] = []
        var lines: [RecipeIngredient] = []
        var carriedSteps: [RecipeStep] = []
        for part in resolved.dropLast() {
            let name = part.name ?? RecipeComponentNaming.fallbackName(position: partRecipes.count)
            guard !part.ingredients.isEmpty else {
                carriedSteps += part.steps.map { RecipeFoodSync.copiedStep($0, from: name) }
                continue
            }
            let partID = derivedID(recipe.id, part.id, "recipe")
            let partRecipe = RecipeDefinition(
                id: partID, name: name, servings: max(recipe.servings, 1),
                ingredients: part.ingredients, source: recipe.source,
                createdAt: recipe.createdAt, updatedAt: recipe.updatedAt,
                steps: part.steps.isEmpty ? nil : part.steps
            )
            partRecipes.append(partRecipe)
            lines.append(RecipeFood.line(using: partRecipe, servings: Double(partRecipe.servings),
                                         id: derivedID(recipe.id, part.id, "line")))
        }
        parent.ingredients = lines + last.ingredients
        let steps = carriedSteps + last.steps
        parent.steps = steps.isEmpty ? nil : steps
        return (parent, partRecipes)
    }

    /// A UUID that is the same on every device for the same inputs: the first 16 bytes of SHA-256 over
    /// a fixed label and the inputs, marked as a name-based (version 5 style) UUID.
    static func derivedID(_ recipeID: UUID, _ partID: UUID, _ role: String) -> UUID {
        let text = "fernlet.recipePartsMigration.v1|\(role)|\(recipeID.uuidString)|\(partID.uuidString)"
        var bytes = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
