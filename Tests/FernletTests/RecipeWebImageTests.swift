import Foundation
import Testing
import UIKit
import FernletDomainModel
import ProximityKit
@testable import Fernlet

/// Feature coverage for "the page's picture becomes a recipe's default photo" (owner decision
/// 2026-08-09, reversing the 2026-07-16 "no external image fetch" tester decision) under the
/// one-attempt-per-device / suppression-syncs split: the additive `RecipeWebImport` image fields
/// decode tolerantly, the store's gates hold (device-local attempt bookkeeping, the synced
/// photo-deletion suppression, cancellation not burning the attempt), mesh-received recipes are
/// neutralized so they can never web-fetch, a mesh share of an already-imported URL keeps the
/// user's copy, and the proximity wire payload stays decodable in both old→new and new→old
/// directions.
struct RecipeWebImageTests {

    // MARK: - Domain decode tolerance

    /// A payload blob written before the image fields existed must decode unchanged (missing key →
    /// nil, never a failure).
    @Test func legacyWebImportJSONDecodesWithoutImageFields() throws {
        let json = #"{"sourceURLString":"https://example.com/r","ingredientLines":["1 cup oats"]}"#
        let decoded = try JSONDecoder().decode(RecipeWebImport.self, from: Data(json.utf8))
        #expect(decoded.sourceURLString == "https://example.com/r")
        #expect(decoded.imageURLString == nil)
        #expect(decoded.webImageSuppressed == nil)
    }

    @Test func webImportImageFieldsRoundTrip() throws {
        let webImport = RecipeWebImport(
            sourceURLString: "https://example.com/r",
            ingredientLines: ["1 cup oats"],
            imageURLString: "https://cdn.example.com/hero.jpg",
            webImageSuppressed: true
        )
        let data = try JSONEncoder().encode(webImport)
        let decoded = try JSONDecoder().decode(RecipeWebImport.self, from: data)
        #expect(decoded.imageURLString == "https://cdn.example.com/hero.jpg")
        #expect(decoded.webImageSuppressed == true)
    }

    // MARK: - Attempted-flag gating (store)

    @MainActor
    private func makeSavedWebRecipe(imageURLString: String?, suppressed: Bool?) -> RecipeDefinition {
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
                webImageSuppressed: suppressed
            )
        )
    }

    /// A throwaway `UserDefaults` suite for the device-local attempt sidecar, so these tests never
    /// touch `.standard`. Callers remove the persistent domain when done.
    private func scratchAttemptDefaults() -> (defaults: UserDefaults, tearDown: () -> Void) {
        let suiteName = "fernlet-tests-webimage-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        return (defaults, { defaults.removePersistentDomain(forName: suiteName) })
    }

    /// A suppressed recipe never fetches — the gate must short-circuit before any network work
    /// (the URL here would fail the guard loudly if it were ever consulted).
    @MainActor
    @Test func fetchSkipsWhenSuppressed() async {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: "https://example.com/hero.jpg", suppressed: true)
        store.addSavedRecipe(recipe)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        // Still suppressed, still photo-less.
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageSuppressed == true)
        #expect(store.recipePhotoData(for: recipe.id) == nil)
    }

    /// Suppression is read from the LIVE row, not just the caller's copy: a stale un-suppressed
    /// snapshot must not dodge a suppression stamped after it was captured.
    @MainActor
    @Test func fetchHonorsSuppressionStampedAfterTheCallerCopiedTheRow() async {
        let store = makeTestStore()
        let staleCopy = makeSavedWebRecipe(imageURLString: "https://example.com/hero.jpg", suppressed: nil)
        store.addSavedRecipe(staleCopy)
        // Suppression lands on the live row (e.g. the user deleted the photo on the detail page).
        store.deleteRecipePhoto(for: staleCopy.id)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: staleCopy) == nil)
        #expect(store.recipePhotoData(for: staleCopy.id) == nil)
    }

    /// Recipes with no image URL (including every recipe imported before the feature) are no-ops.
    @MainActor
    @Test func fetchSkipsWhenNoImageURL() async {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: nil, suppressed: nil)
        store.addSavedRecipe(recipe)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        // No attempt was made and nothing suppressed — nothing to gate yet.
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageSuppressed == nil)
        #expect(!RecipeWebImageAttemptMemory.hasAttempted(recipe.id, defaults: store.webImageAttemptDefaults))
    }

    /// One attempt per DEVICE: a FAILED download (here: guard-refused http URL, so no network
    /// happens) records the attempt in the device-local sidecar — no automatic retry here — while
    /// the synced row stays UN-suppressed, so another device on the same iCloud account still gets
    /// its own single attempt.
    @MainActor
    @Test func failedAttemptIsRecordedDeviceLocallyNotOnTheSyncedRow() async {
        let store = makeTestStore()
        let (defaults, tearDown) = scratchAttemptDefaults()
        defer { tearDown() }
        store.webImageAttemptDefaults = defaults
        let recipe = makeSavedWebRecipe(imageURLString: "http://127.0.0.1/hero.jpg", suppressed: nil)
        store.addSavedRecipe(recipe)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        // Device-local bookkeeping consumed; the synced row carries no suppression.
        #expect(RecipeWebImageAttemptMemory.hasAttempted(recipe.id, defaults: defaults))
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageSuppressed == nil)
        // The recorded attempt short-circuits a second call on this device.
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        // A "second device" (fresh sidecar) is NOT blocked by this device's attempt.
        let (secondDeviceDefaults, tearDownSecond) = scratchAttemptDefaults()
        defer { tearDownSecond() }
        #expect(!RecipeWebImageAttemptMemory.hasAttempted(recipe.id, defaults: secondDeviceDefaults))
    }

    /// Cooperative cancellation — popping the detail mid-download — is the user navigating, not a
    /// failed fetch: the device's one attempt must NOT be burned, so the next open can retry.
    @MainActor
    @Test func cancellationDoesNotBurnTheAttempt() async {
        let store = makeTestStore()
        let (defaults, tearDown) = scratchAttemptDefaults()
        defer { tearDown() }
        store.webImageAttemptDefaults = defaults
        let recipe = makeSavedWebRecipe(imageURLString: "http://127.0.0.1/hero.jpg", suppressed: nil)
        store.addSavedRecipe(recipe)
        // Pre-cancelled task: the (guard-refused, zero-network) download fails inside a cancelled
        // task — exactly what a popped detail view produces.
        let task = Task { @MainActor in
            await store.fetchRecipeWebImageIfNeeded(for: recipe)
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(!RecipeWebImageAttemptMemory.hasAttempted(recipe.id, defaults: defaults),
                "a cancelled fetch must leave the attempt un-spent")
        // An un-cancelled retry then spends it normally.
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        #expect(RecipeWebImageAttemptMemory.hasAttempted(recipe.id, defaults: defaults))
    }

    /// The user already picked their own photo: the fetch path never downloads behind it and
    /// suppresses (synced) so the web image can never resurrect — on any device — if that photo is
    /// later deleted.
    @MainActor
    @Test func existingUserPhotoSuppressesInsteadOfFetching() async {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: "https://example.com/hero.jpg", suppressed: nil)
        store.addSavedRecipe(recipe)
        #expect(store.saveRecipePhoto(data: tinyJPEGData(), for: recipe.id))
        let photoBefore = store.recipePhotoData(for: recipe.id)
        #expect(await store.fetchRecipeWebImageIfNeeded(for: recipe) == nil)
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageSuppressed == true)
        #expect(store.recipePhotoData(for: recipe.id) == photoBefore)
        store.deleteSavedRecipe(store.savedRecipes.first { $0.id == recipe.id }!)
    }

    /// Deleting the recipe photo is the user's stated intent: the web image must never resurrect,
    /// so the deletion path suppresses (synced) rather than just spending this device's attempt.
    @MainActor
    @Test func deletingPhotoSuppressesWebImage() {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: "https://example.com/hero.jpg", suppressed: nil)
        store.addSavedRecipe(recipe)
        store.deleteRecipePhoto(for: recipe.id)
        #expect(store.savedRecipes.first { $0.id == recipe.id }?.webImport?.webImageSuppressed == true)
    }

    /// The notes sheet's Done path merges ONLY the edited notes into the live row: a suppression
    /// (or any other store update) landing while the sheet was up survives Done.
    @MainActor
    @Test func updateSavedRecipeNotesMergesIntoTheLiveRow() {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(imageURLString: "https://example.com/hero.jpg", suppressed: nil)
        store.addSavedRecipe(recipe)
        // The image fetch (or a photo deletion) stamps the live row while the sheet is open...
        store.deleteRecipePhoto(for: recipe.id)
        // ...then Done writes back the notes edited on the PRE-stamp snapshot.
        store.updateSavedRecipeNotes("my tweaks", forRecipeID: recipe.id)
        let current = store.savedRecipes.first { $0.id == recipe.id }
        #expect(current?.notes == "my tweaks")
        #expect(current?.webImport?.webImageSuppressed == true, "Done must not un-stamp the suppression")
        // And for a deleted recipe it's a clean no-op.
        store.deleteSavedRecipe(current!)
        store.updateSavedRecipeNotes("ghost", forRecipeID: recipe.id)
        #expect(store.savedRecipes.first { $0.id == recipe.id } == nil)
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

    /// A mesh-received saved recipe is neutralized on arrival: no image URL, web image
    /// pre-suppressed, and the sender's downscaled picture sealed into THIS device's own photo
    /// store — the receiver performs no web fetch, ever.
    @MainActor
    @Test func receivedSavedRecipeStoresImageAndNeverWebFetches() async throws {
        let store = makeTestStore()
        let outcome = try store.importProximityRecipeShare(savedSharePayload(imageJPEGData: tinyJPEGData()))
        #expect(outcome == .imported(name: "Shared Oats"))

        let imported = try #require(store.savedRecipes.first { $0.name == "Shared Oats" })
        #expect(imported.webImport?.webImageSuppressed == true)
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
        #expect(imported.webImport?.webImageSuppressed == true)
        store.deleteSavedRecipe(imported)
    }

    /// Accepting a mesh share of an already-imported source URL KEEPS the user's existing recipe —
    /// photo, notes, and all (the owner's duplicate decision, same as the paste and drain paths).
    /// Before this rule the mesh path routed through addSavedRecipe's supersede, which permanently
    /// deleted the user's sealed photo and replaced their notes on a single accept tap.
    @MainActor
    @Test func meshShareOfAlreadyImportedURLKeepsTheUsersRecipe() throws {
        let store = makeTestStore()
        // The user's own copy: cosmetically different URL spelling (host case + fragment), edited
        // notes, and their own photo.
        var mine = makeSavedWebRecipe(imageURLString: nil, suppressed: nil)
        mine.notes = "my tweaks: extra cinnamon"
        mine.webImport?.sourceURLString = "HTTPS://Example.com/recipes/oats#print"
        store.addSavedRecipe(mine)
        #expect(store.saveRecipePhoto(data: tinyJPEGData(), for: mine.id))
        let photoBefore = try #require(store.recipePhotoData(for: mine.id))

        // nil fingerprint keeps the test off the real closeness sidecar file; the closeness
        // recording shares the exact code path either way.
        let outcome = try store.importProximityRecipeShare(
            savedSharePayload(imageJPEGData: tinyJPEGData()),
            fromFingerprint: nil
        )

        #expect(outcome == .alreadySaved(name: mine.name))
        #expect(store.savedRecipes.count == 1, "no new row, no supersede")
        let kept = try #require(store.savedRecipes.first { $0.id == mine.id })
        #expect(kept.notes == "my tweaks: extra cinnamon")
        #expect(store.recipePhotoData(for: mine.id) == photoBefore, "the user's sealed photo must survive the accept")
        store.deleteSavedRecipe(kept)
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

    /// The "Include picture" strip is the mirror image: it clears ONLY the image, leaving the
    /// notes (and everything else) untouched.
    @Test func omittingImageKeepsTheNotes() {
        let payload = savedSharePayload(imageJPEGData: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let stripped = payload.omittingImage()
        #expect(stripped.imageJPEGData == nil)
        #expect(stripped.recipe.saved?.summary == "Cook the oats.")
        #expect(stripped.recipe.saved?.name == "Shared Oats")
    }

    /// The receive-side door check: an image above the wire cap — bytes an honest sender never
    /// produces — is dropped before the payload can sit in the pending queue, while a within-cap
    /// image (and the recipe itself) rides through untouched.
    @Test func droppingOversizeImageEnforcesTheWireCapAtTheDoor() {
        let oversize = savedSharePayload(imageJPEGData: Data(count: ProximityRecipeSharePayload.maxImageBytes + 1))
        let dropped = oversize.droppingOversizeImage()
        #expect(dropped.imageJPEGData == nil)
        #expect(dropped.recipe.saved?.name == "Shared Oats")

        let fits = savedSharePayload(imageJPEGData: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        #expect(fits.droppingOversizeImage().imageJPEGData == fits.imageJPEGData)
        #expect(savedSharePayload(imageJPEGData: nil).droppingOversizeImage().imageJPEGData == nil)
    }

    /// M7: the wire cap bounds the total bytes, but the REVIEW SHEET still has to lay the strings
    /// out. The saved variant has no bounded decode of its own (unlike `SharedRecipePayload`), so
    /// its strings and lists are clamped at the door to the same `SharedRecipeLimits` the import
    /// path enforces.
    @Test func clampedForReviewBoundsTheRenderedStringsAndLists() {
        let huge = String(repeating: "x", count: 10_000)
        let payload = ProximityRecipeSharePayload(
            recipe: ProximitySharedRecipe(
                kind: .saved,
                saved: SharedSavedRecipePayload(
                    name: huge,
                    sourceURLString: "https://example.com/recipes/oats",
                    ingredients: Array(repeating: huge, count: 500),
                    summary: huge,
                    servings: 9_999,
                    protein: 10, carbs: 30, fat: 5,
                    micronutrients: Micronutrients(),
                    steps: (0..<500).map { _ in RecipeStep(text: huge) }
                )
            ),
            imageJPEGData: nil
        )

        let clamped = payload.clampedForReview()
        let saved = clamped.recipe.saved
        #expect(saved?.name.count == SharedRecipeLimits.maxNameCharacters)
        #expect(saved?.summary.count == SharedRecipeLimits.maxNotesCharacters)
        #expect(saved?.ingredients.count == SharedRecipeLimits.maxIngredients)
        #expect(saved?.ingredients.allSatisfy { $0.count <= SharedRecipeLimits.maxNameCharacters } == true)
        #expect(saved?.steps?.count == SharedRecipeLimits.maxSteps)
        #expect(saved?.servings == SharedRecipeLimits.maxServings)
    }

    /// The clamp is a no-op on an honest share — over-tightening must fail loudly.
    @Test func clampedForReviewLeavesAnHonestShareUntouched() {
        let payload = savedSharePayload(imageJPEGData: Data([0xFF, 0xD8, 0xFF, 0xE0]))
        let clamped = payload.clampedForReview()
        #expect(clamped.recipe.saved?.name == "Shared Oats")
        #expect(clamped.recipe.saved?.ingredients == ["1 cup oats"])
        #expect(clamped.recipe.saved?.summary == "Cook the oats.")
        #expect(clamped.imageJPEGData == payload.imageJPEGData)
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
