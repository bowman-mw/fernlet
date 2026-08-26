import ProximityKit
import Foundation
import FernletDomainModel
import FernletExchange
import FernletFoundation
#if canImport(UIKit)
import UIKit
import PrivateMediaStore
#endif

/// The named size bounds a recipe must satisfy wherever one ENTERS the app (Power-of-10 R3/R5):
/// the manual editor's "Add ingredient" / "Add step" buttons and the pasted-share decoder.
///
/// One set of constants for every entry path, so a recipe typed by hand and a recipe pasted from a
/// share can never disagree about how large a recipe is allowed to get. The decoder rejects any
/// payload that breaks one of these; the editor disables the button that would break it.
enum RecipeLimits {
    /// Largest pasted share text accepted, in UTF-8 bytes — the paste path's frame bound (the mesh
    /// path is bounded by `SealedPayloadFraming` instead).
    static let maxShareTextUTF8Bytes = 64 * 1024
    /// Largest ingredient count in one recipe (each imported ingredient persists one `FoodItem`).
    static let maxIngredients = 100
    /// Largest cooking-step count in one recipe.
    static let maxSteps = 60
    /// Largest recipe name, in characters.
    static let maxNameLength = 200
    /// Largest recipe notes blob, in characters.
    static let maxNotesLength = 4_000
    /// Largest single step's text, in characters.
    static let maxStepTextLength = 2_000
    /// Largest per-ingredient quantity (any unit).
    static let maxQuantity: Double = 10_000
    /// Largest per-step timer window, in seconds — matches `StepTimerControl`'s 1...240 minute stepper.
    static let maxStepDurationSeconds = 240 * 60
    /// Largest serving count — matches the recipe editor's `Stepper(in: 1...24)`.
    static let maxServings = 24
}

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
        ExchangeRecipePayloadBuilder.payload(for: recipe, foodItems: foodItems)
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
    /// `fernlet.recipe` v1 format, the ``RecipeLimits`` size bounds, and the payload's values.
    ///
    /// This is the app's one *external* recipe boundary (pasteboard / share sheet text), so it caps
    /// growth and validates every value at entry (Power-of-10 R3/R5): the importer downstream
    /// persists one `FoodItem` per ingredient, so an unbounded payload is unbounded storage.
    /// - Throws: `RecipeImportError.missingPayload` / `.invalidPayload` / `.unsupportedFormat`.
    static func decodePayload(from text: String) throws -> SharedRecipePayload {
        // R3: cap the input where it enters — an oversize paste is rejected BEFORE `JSONDecoder` (or
        // any string scanning) runs, so a hostile clipboard cannot make the parser do unbounded work.
        // Logged with both numbers: the user-facing error is the generic "couldn't read that", and
        // without this line "too big" is indistinguishable from "malformed".
        let pastedByteCount = text.utf8.count
        guard pastedByteCount <= RecipeLimits.maxShareTextUTF8Bytes else {
            FernletAuditLog.log("recipeShare.decodeRejected", context: [
                "reason": "oversizePaste",
                "bytes": String(pastedByteCount),
                "max": String(RecipeLimits.maxShareTextUTF8Bytes)
            ])
            throw RecipeImportError.invalidPayload
        }
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
        try validate(payload)
        return payload
    }

    /// Maps the shared portable validator's failures onto this older app-facing error vocabulary.
    /// The actual bounds live with the packet builder so Files, Shortcuts, and Messages agree.
    private static func validate(_ payload: SharedRecipePayload) throws {
        do {
            try ExchangeRecipePayloadValidator.validate(payload)
        } catch ExchangePacketError.unsupportedFormat {
            throw RecipeImportError.unsupportedFormat
        } catch {
            throw RecipeImportError.invalidPayload
        }
    }

    private static func sharedRecipeJSON(for payload: SharedRecipePayload) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(payload)
            return String(data: data, encoding: .utf8)
        } catch {
            // The only realistic failure is a non-finite quantity, which the editor and the decoder
            // both rule out. Name it rather than dropping it: the share text still goes out (readable
            // but not importable), so the sender sees a share and the log says why it lost its payload.
            FernletAuditLog.log(
                "recipe.share.payloadEncode.failed",
                context: ["error": error.localizedDescription, "recipe": payload.name]
            )
            return nil
        }
    }

    #if canImport(UIKit)
    /// Re-encodes decrypted recipe-photo bytes into a wire-ready JPEG at most `maxBytes`
    /// (`ProximityRecipeSharePayload.maxImageBytes` by default), stepping dimension and quality
    /// down until it fits; `nil` when the bytes aren't an image or nothing fits (the share then
    /// simply goes out without a picture). Lives in the APP target on purpose: the sealed photo
    /// store is `PrivateMediaStore`, which `ProximityKit` must never import (S3 wall) — the store
    /// decrypts, this downscales, and only the bounded JPEG reaches the wire payload.
    static func wireImageJPEG(fromPhotoData data: Data, maxBytes: Int = ProximityRecipeSharePayload.maxImageBytes) -> Data? {
        // Validate at entry: a zero/negative budget or empty bytes can never produce a fitting JPEG,
        // so say so up front instead of walking the whole 4x2 encode ladder to return nil anyway.
        guard maxBytes > 0, !data.isEmpty else { return nil }
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
