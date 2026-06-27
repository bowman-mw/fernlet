import Foundation
import FernletDomainModel

struct RecipeShareCodec {
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
            }
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
                        micronutrients: webImport.micronutrients
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
