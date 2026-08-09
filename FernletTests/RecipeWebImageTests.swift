import Foundation
import Testing
import UIKit
import FernletDomainModel
import ProximityKit
@testable import Fernlet

/// Feature coverage for "the page's picture becomes a recipe's default photo" (owner decision
/// 2026-08-09, reversing the 2026-07-16 "no external image fetch" tester decision): the additive
/// `RecipeWebImport` image fields decode tolerantly, the store's one-attempt gate (including the
/// photo-deletion stamp) holds, mesh-received recipes are neutralized so they can never web-fetch,
/// and the proximity wire payload stays decodable in both old→new and new→old directions.
struct RecipeWebImageTests {

    // MARK: - Domain decode tolerance

    /// A payload blob written before the image fields existed must decode unchanged (missing key →
    /// nil, never a failure).
    @Test func legacyWebImportJSONDecodesWithoutImageFields() throws {
        let json = #"{"sourceURLString":"https://example.com/r","ingredientLines":["1 cup oats"]}"#
        let decoded = try JSONDecoder().decode(RecipeWebImport.self, from: Data(json.utf8))
        #expect(decoded.sourceURLString == "https://example.com/r")
        #expect(decoded.imageURLString == nil)
        #expect(decoded.webImageFetchAttempted == nil)
    }

    @Test func webImportImageFieldsRoundTrip() throws {
        let webImport = RecipeWebImport(
            sourceURLString: "https://example.com/r",
            ingredientLines: ["1 cup oats"],
            imageURLString: "https://cdn.example.com/hero.jpg",
            webImageFetchAttempted: true
        )
        let data = try JSONEncoder().encode(webImport)
        let decoded = try JSONDecoder().decode(RecipeWebImport.self, from: data)
        #expect(decoded.imageURLString == "https://cdn.example.com/hero.jpg")
        #expect(decoded.webImageFetchAttempted == true)
    }

    // MARK: - Attempted-flag gating (store)

    @MainActor
    private func makeSavedWebRecipe(imageURLString: String?, attempted: Bool?) -> RecipeDefinition {
        let now = Date()
        return RecipeDefinition(
            name: "Web Oats",
            servings: 2,
            ingredients: [],
            source: MealLogSource.webImport,
            createdAt: now,
            updatedAt: now,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/recipes/oats",
                ingredientLines: ["1 cup oats"],
                imageURLString: imageURLString,
                webImageFetchAttempted: attempted
            )
        )
    }

    /// An already-attempted recipe never re-fetches — the gate must short-circuit before any
    /// network work (the URL here would fail the guard loudly if it were ever consulted).
    @MainActor
    @Test func fetchSkipsWhenAlreadyAttempted() async {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: "https://example.com/hero.jpg", attempted: true)
        store.addSavedRecipe(recipe)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        // Still stamped, still photo-less.
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageFetchAttempted == true)
        #expect(store.recipePhotoData(for: recipe.id) == nil)
    }

    /// Recipes with no image URL (including every recipe imported before the feature) are no-ops.
    @MainActor
    @Test func fetchSkipsWhenNoImageURL() async {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: nil, attempted: nil)
        store.addSavedRecipe(recipe)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        // No attempt was made, so the flag stays unset — nothing to gate yet.
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageFetchAttempted == nil)
    }

    /// One attempt total: a FAILED download (here: guard-refused http URL, so no network happens)
    /// still persists the attempted flag via the saved-recipe update path — no automatic retry.
    @MainActor
    @Test func failedAttemptIsPersistedSoItNeverRetries() async {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: "http://127.0.0.1/hero.jpg", attempted: nil)
        store.addSavedRecipe(recipe)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageFetchAttempted == true)
        // And the now-stamped row short-circuits a second call.
        let stamped = store.savedRecipes.first { $0.id == recipe.id }!
        #expect(await store.fetchRecipeWebImageIfNeeded(for: stamped) == nil)
    }

    /// Deleting the recipe photo is the user's stated intent: the web image must never resurrect,
    /// so the deletion path stamps the attempted flag too.
    @MainActor
    @Test func deletingPhotoStampsAttemptedFlag() {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: "https://example.com/hero.jpg", attempted: nil)
        store.addSavedRecipe(recipe)
        store.deleteRecipePhoto(for: recipe.id)
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageFetchAttempted == true)
    }

    // MARK: - Mesh receive (no web fetch, sealed local photo)

    private func tinyJPEGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let image = renderer.image { context in
            UIColor.systemRed.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func savedSharePayload(imageJPEGData: Data?) -> ProximityRecipeSharePayload {
        ProximityRecipeSharePayload(
            recipe: ProximitySharedRecipe(
                kind: .saved,
                saved: SharedSavedRecipePayload(
                    name: "Shared Oats",
                    sourceURLString: "https://example.com/recipes/oats",
                    ingredients: ["1 cup oats"],
                    summary: "Cook the oats.",
                    servings: 2,
                    protein: 10,
                    carbs: 30,
                    fat: 5,
                    micronutrients: Micronutrients()
                )
            ),
            imageJPEGData: imageJPEGData
        )
    }

    /// A mesh-received saved recipe is neutralized on arrival: no image URL, fetch pre-stamped as
    /// attempted, and the sender's downscaled picture sealed into THIS device's own photo store —
    /// the receiver performs no web fetch, ever.
    @MainActor
    @Test func receivedSavedRecipeStoresImageAndNeverWebFetches() async throws {
        let store = makeTestStore()
        _ = try store.importProximityRecipeShare(savedSharePayload(imageJPEGData: tinyJPEGData()))

        let imported = try #require(store.savedRecipes.first { $0.name == "Shared Oats" })
        #expect(imported.webImport?.webImageFetchAttempted == true)
        #expect(imported.webImport?.imageURLString == nil)
        #expect(store.recipePhotoData(for: imported.id) != nil)
        // And the lazy path stays inert for it.
        #expect(await store.fetchRecipeWebImageIfNeeded(for: imported) == nil)

        // Cleanup: deleting the recipe removes its sealed photo file from the shared container.
        store.deleteSavedRecipe(imported)
    }

    /// An oversized image payload from a hostile peer is dropped BEFORE decoding, but the recipe
    /// itself still imports.
    @MainActor
    @Test func oversizedMeshImageIsDroppedRecipeStillImports() throws {
        let store = makeTestStore()
        let oversize = Data(count: ProximityRecipeSharePayload.maxImageBytes + 1)
        _ = try store.importProximityRecipeShare(savedSharePayload(imageJPEGData: oversize))

        let imported = try #require(store.savedRecipes.first { $0.name == "Shared Oats" })
        #expect(store.recipePhotoData(for: imported.id) == nil)
        #expect(imported.webImport?.webImageFetchAttempted == true)
        store.deleteSavedRecipe(imported)
    }

    // MARK: - Wire compatibility (optional key, version stays 1)

    /// The pre-image wire shape, hand-mirrored: what an older peer's synthesized `Codable` sees.
    private struct LegacyProximityRecipeSharePayload: Codable {
        var format: String
        var version: Int
        var id: UUID
        var sentAt: Date
        var recipe: ProximitySharedRecipe
    }

    /// Old sender → new receiver: a payload encoded WITHOUT the image key decodes with `nil`.
    @Test func oldPayloadWithoutImageKeyDecodesOnNewReceiver() throws {
        let legacy = LegacyProximityRecipeSharePayload(
            format: "fernlet.proximity.recipe",
            version: 1,
            id: UUID(),
            sentAt: Date(),
            recipe: savedSharePayload(imageJPEGData: nil).recipe
        )
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.imageJPEGData == nil)
        #expect(decoded.recipe.saved?.name == "Shared Oats")
    }

    /// New sender → old receiver: a payload carrying the image still decodes on the pre-image
    /// shape (the unknown key is ignored), with `version` still 1 so no old-peer version gate trips.
    @Test func newPayloadWithImageDecodesOnOldReceiverShape() throws {
        let payload = savedSharePayload(imageJPEGData: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(LegacyProximityRecipeSharePayload.self, from: data)
        #expect(decoded.version == 1)
        #expect(decoded.format == "fernlet.proximity.recipe")
        #expect(decoded.recipe.saved?.name == "Shared Oats")
    }

    /// The "Include notes" strip must not touch the picture — withheld notes and a shared picture
    /// are independent decisions.
    @Test func omittingShareNotesKeepsTheImage() {
        let image = Data([0xFF, 0xD8, 0xFF, 0xE0])
        let payload = savedSharePayload(imageJPEGData: image)
        #expect(payload.omittingShareNotes().imageJPEGData == image)
    }

    // MARK: - Sender-side downscale

    /// The wire JPEG helper honors the byte cap and rejects non-image bytes.
    @MainActor
    @Test func wireImageJPEGFitsTheCapAndRejectsGarbage() {
        let jpeg = tinyJPEGData()
        let wire = RecipeShareCodec.wireImageJPEG(fromPhotoData: jpeg)
        #expect(wire != nil)
        #expect((wire?.count ?? .max) <= ProximityRecipeSharePayload.maxImageBytes)
        #expect(RecipeShareCodec.wireImageJPEG(fromPhotoData: Data([0x00, 0x01, 0x02])) == nil)
    }
}
