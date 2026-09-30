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

/// Encodes and decodes recipes for sharing — the proximity-mesh wire payload, and the reader for
/// the paste text older builds shared.
///
/// The single place that knows the `fernlet.recipe` v1 format. Ingredients are resolved against the
/// passed `foodItems` and carried as (name, quantity, unit, scaled macros) — recipient devices don't
/// share the sender's catalog ids, so the payload is self-contained. Steps and a multipart recipe's
/// parts ride optional keys (version stays 1; old peers ignore them and read the flattened recipe —
/// see `RecipeComponentWire.swift`). The proximity recipe-share flow sends
/// ``proximityPayload(for:foodItems:)`` over the mesh.
///
/// **The paste format is read, no longer written (2026-09-30).** Until then the share sheet's text
/// was a readable header followed by a ``legacyPayloadMarker`` line and the payload's single-line
/// JSON, which Mail, Notes and every chat app showed verbatim. The share sheet now sends
/// ``RecipeShareText``'s readable text, and Fernlet-to-Fernlet travels as a Messages card or over the
/// nearby radio. ``decodePayload(from:)`` is unchanged, so `FernletStore.importRecipe(from:)` still
/// imports text an older build shared, and the bare JSON the Shortcuts file import hands it.
struct RecipeShareCodec {
    /// The line an older build's share text put before the payload JSON. A frozen MATCHING token:
    /// ``decodePayload(from:)`` looks for it in pasted text, so it stays English forever, whatever
    /// language the text around it was written in.
    static let legacyPayloadMarker = "Fernlet recipe data:"

    /// The self-contained `SharedRecipePayload` for a structured recipe: each ingredient resolved
    /// against `foodItems` and flattened to name + quantity + scaled macros (ingredients whose food
    /// item can't be resolved are dropped), with ordered steps riding along, and — for a multipart
    /// recipe — the `components` partition over both. Both paste-text and mesh readers ignore an
    /// unknown key, so this is the form they get (the hash-covered exchange packet does not).
    static func payload(for recipe: RecipeDefinition, foodItems: [FoodItem]) -> SharedRecipePayload {
        ExchangeRecipePayloadBuilder.componentPayload(for: recipe, foodItems: foodItems)
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

    /// Decodes a pasted share back into a payload: accepts either the bare JSON or an older build's
    /// full share text (the first `{`-line after the ``legacyPayloadMarker`` line), then validates the
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
        } else if let markerRange = text.range(of: legacyPayloadMarker) {
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
