import ProximityKit
import Foundation
import FernletDomainModel

/// Encodes and decodes recipes for sharing — the human-readable share text with its embedded
/// machine-readable JSON payload, and the proximity-mesh wire payload.
///
/// The single place that knows the `fernlet.recipe` v1 format. Ingredients are resolved against the
/// passed `foodItems` and carried as (name, quantity, unit, scaled macros) — recipient devices don't
/// share the sender's catalog ids, so the payload is self-contained. Steps ride an optional key
/// (version stays 1; old peers ignore it). `FernletStore.importRecipe(from:)` decodes pasted share
/// text through ``decodePayload(from:)``, and the proximity recipe-share flow sends
/// ``proximityPayload(for:foodItems:)`` over the mesh.
struct RecipeShareCodec {
    /// The full text a user shares: readable name/servings/ingredients/notes followed by a
    /// "Fernlet recipe data:" line carrying the single-line JSON payload the importer parses back.
    static func shareText(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> String {
        let payload = payload(for: recipe, foodItems: foodItems)
        var lines: [String] = [
            payload.name,
            "Servings: \(payload.servings)",
            "",
            "Ingredients:"
        ]
        lines += payload.ingredients.map { ingredient in
            "- \(String(format: "%g", ingredient.quantity)) \(ingredient.unit) \(ingredient.name) (P\(ingredient.protein) C\(ingredient.carbs) F\(ingredient.fat))"
        }
        if !payload.notes.isEmpty {
            lines += ["", "Notes:", payload.notes]
        }
        if let json = sharedRecipeJSON(for: payload) {
            lines += ["", "Fernlet recipe data:", json]
        }
        return lines.joined(separator: "\n")
    }

    /// The self-contained `SharedRecipePayload` for a structured recipe: each ingredient resolved
    /// against `foodItems` and flattened to name + quantity + scaled macros (ingredients whose food
    /// item can't be resolved are dropped), with ordered steps riding along.
    static func payload(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> SharedRecipePayload {
        SharedRecipePayload(
            name: recipe.name,
            servings: recipe.servings,
            notes: recipe.notes,
            ingredients: recipe.ingredients.compactMap { ingredient in
                guard let foodItem = foodItems.first(where: { $0.id == ingredient.foodItemId }) else { return nil }
                let macros = ingredient.scaledMacros(using: foodItem)
                return SharedRecipeIngredient(
                    name: foodItem.name,
                    quantity: ingredient.quantity,
                    unit: ingredient.unit,
                    protein: macros.protein,
                    carbs: macros.carbs,
                    fat: macros.fat
                )
            },
            // F5: carry ordered steps on the wire (optional key, version stays 1 — old peers ignore it).
            steps: recipe.steps
        )
    }

    /// Builds the over-the-wire proximity payload for any recipe. Web-imported recipes (those with a
    /// `webImport`) are sent as the `.saved` kind — preserving free-text ingredients + precomputed
    /// nutrition + source URL, and keeping wire compatibility with peers running older builds.
    /// User-built recipes are sent as the `.local` kind, resolved against `foodItems`.
    static func proximityPayload(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> ProximityRecipeSharePayload {
        if let webImport = recipe.webImport {
            return ProximityRecipeSharePayload(
                recipe: ProximitySharedRecipe(
                    kind: .saved,
                    local: nil,
                    saved: SharedSavedRecipePayload(
                        name: recipe.name,
                        sourceURLString: webImport.sourceURLString,
                        ingredients: webImport.ingredientLines,
                        summary: recipe.notes,
                        servings: recipe.servings,
                        protein: webImport.macros.protein,
                        carbs: webImport.macros.carbs,
                        fat: webImport.macros.fat,
                        micronutrients: webImport.micronutrients,
                        steps: recipe.steps
                    )
                )
            )
        }
        return ProximityRecipeSharePayload(
            recipe: ProximitySharedRecipe(
                kind: .local,
                local: payload(for: recipe, foodItems: foodItems),
                saved: nil
            )
        )
    }

    /// Decodes a pasted share back into a payload: accepts either the bare JSON or the full share
    /// text (the first `{`-line after the "Fernlet recipe data:" marker), then validates the
    /// `fernlet.recipe` v1 format.
    /// - Throws: `RecipeImportError.missingPayload` / `.invalidPayload` / `.unsupportedFormat`.
    static func decodePayload(from text: String) throws -> SharedRecipePayload {
        let trimmedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let jsonText: String
        if trimmedText.hasPrefix("{") {
            jsonText = trimmedText
        } else if let markerRange = text.range(of: "Fernlet recipe data:") {
            let payloadText = text[markerRange.upperBound...]
            guard let firstJSONLine = payloadText
                .split(whereSeparator: \.isNewline)
                .map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) })
                .first(where: { $0.hasPrefix("{") }) else {
                throw RecipeImportError.missingPayload
            }
            jsonText = firstJSONLine
        } else {
            throw RecipeImportError.missingPayload
        }

        guard let data = jsonText.data(using: .utf8),
              let payload = try? JSONDecoder().decode(SharedRecipePayload.self, from: data) else {
            throw RecipeImportError.invalidPayload
        }
        guard payload.format == "fernlet.recipe", payload.version == 1 else {
            throw RecipeImportError.unsupportedFormat
        }
        return payload
    }

    private static func sharedRecipeJSON(for payload: SharedRecipePayload) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
