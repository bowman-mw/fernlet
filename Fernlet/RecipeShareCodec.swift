import ProximityKit
import Foundation
import FernletDomainModel
#if canImport(UIKit)
import UIKit
import PrivateMediaStore
#endif

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

    #if canImport(UIKit)
    /// Re-encodes decrypted recipe-photo bytes into a wire-ready JPEG at most `maxBytes`
    /// (`ProximityRecipeSharePayload.maxImageBytes` by default), stepping dimension and quality
    /// down until it fits; `nil` when the bytes aren't an image or nothing fits (the share then
    /// simply goes out without a picture). Lives in the APP target on purpose: the sealed photo
    /// store is `PrivateMediaStore`, which `ProximityKit` must never import (S3 wall) — the store
    /// decrypts, this downscales, and only the bounded JPEG reaches the wire payload.
    static func wireImageJPEG(fromPhotoData data: Data, maxBytes: Int = ProximityRecipeSharePayload.maxImageBytes) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        // Stored recipe photos are already normalized to <=1600 px JPEG, so the first rung almost
        // always fits; the ladder exists for pathological (dense, noisy) images.
        for dimension: CGFloat in [1024, 768, 512, 384] {
            let scaled = image.resizedForFriendSharing(maxDimension: dimension)
            for quality: CGFloat in [0.7, 0.5] {
                if let jpeg = scaled.jpegData(compressionQuality: quality), jpeg.count <= maxBytes {
                    return jpeg
                }
            }
        }
        return nil
    }
    #endif
}
