import Foundation
import Testing
import UIKit
import FernletDomainModel
import AIProviders
// @testable for the internal `save`, which seeds the share-extension inbox the way the extension does.
@testable import AppServices
@testable import Fernlet

/// Table coverage for ``RecipeSourceURLMatcher`` — the one normalization rule behind the
/// zero-network duplicate skip, the supersede-on-re-import match, and the superseded-photo
/// cleanup (owner decision 2026-08-09): scheme+host case-insensitive, fragment stripped,
/// query KEPT (query strings genuinely distinguish recipes on some sites), path verbatim.
struct RecipeSourceURLMatcherTests {

    /// Scheme and host case never distinguishes two URLs (RFC 3986); everything else is preserved.
    @Test func schemeAndHostAreCaseInsensitive() {
        #expect(RecipeSourceURLMatcher.urlsMatch(
            "HTTPS://Example.COM/Recipes/oats",
            "https://example.com/Recipes/oats"
        ))
    }

    /// Paths are case-sensitive on most hosts — the matcher must not over-normalize them.
    @Test func pathCaseIsSignificant() {
        #expect(!RecipeSourceURLMatcher.urlsMatch(
            "https://example.com/Recipes/oats",
            "https://example.com/recipes/oats"
        ))
    }

    /// Fragments are client-side and never reach the server — they cannot name a different recipe.
    @Test func fragmentIsIgnored() {
        #expect(RecipeSourceURLMatcher.urlsMatch(
            "https://example.com/recipes/oats#comments",
            "https://example.com/recipes/oats"
        ))
    }

    /// Query strings DO distinguish recipes (`?id=1` vs `?id=2`), so they are kept significant.
    @Test func queryIsSignificant() {
        #expect(!RecipeSourceURLMatcher.urlsMatch(
            "https://example.com/recipe?id=1",
            "https://example.com/recipe?id=2"
        ))
        #expect(RecipeSourceURLMatcher.urlsMatch(
            "https://example.com/recipe?id=1",
            "HTTPS://EXAMPLE.com/recipe?id=1#reviews"
        ))
    }

    /// Different hosts, schemes, ports, and paths never match — the matcher only erases cosmetics.
    @Test func genuineDifferencesStayDistinct() {
        #expect(!RecipeSourceURLMatcher.urlsMatch("https://example.com/r", "https://example.org/r"))
        #expect(!RecipeSourceURLMatcher.urlsMatch("http://example.com/r", "https://example.com/r"))
        #expect(!RecipeSourceURLMatcher.urlsMatch("https://example.com:8443/r", "https://example.com/r"))
        #expect(!RecipeSourceURLMatcher.urlsMatch("https://example.com/r", "https://example.com/r/"))
    }

    /// Empty strings never match anything — two "no source" recipes are not the same recipe.
    @Test func emptyNeverMatches() {
        #expect(!RecipeSourceURLMatcher.urlsMatch("", ""))
        #expect(!RecipeSourceURLMatcher.urlsMatch("   ", "https://example.com/r"))
        #expect(RecipeSourceURLMatcher.normalizedKey("") == nil)
        #expect(RecipeSourceURLMatcher.normalizedKey("  \n ") == nil)
    }

    /// Strings that are not absolute scheme://host URLs (garbage, or scheme-less relative
    /// references — which modern Foundation's lenient parser still "parses") get no normalized key
    /// and fall back to exact (trimmed) equality: identical strings still match themselves (so
    /// re-importing an identical stored string supersedes), lookalikes never do.
    @Test func nonAbsoluteURLsFallBackToExactEquality() {
        let garbage = "not a url at all %%"
        #expect(RecipeSourceURLMatcher.normalizedKey(garbage) == nil)
        #expect(RecipeSourceURLMatcher.urlsMatch(garbage, garbage))
        #expect(!RecipeSourceURLMatcher.urlsMatch(garbage, "not a url at all %"))
        // Scheme-less: parses as a relative reference, but is not an absolute web URL — no key,
        // so fragment stripping must NOT apply to it.
        #expect(RecipeSourceURLMatcher.normalizedKey("example.com/recipe") == nil)
        #expect(!RecipeSourceURLMatcher.urlsMatch("example.com/recipe#a", "example.com/recipe"))
    }

    /// The key itself: lowercased scheme+host, fragment gone, query/path intact, whitespace trimmed.
    @Test func normalizedKeyShape() {
        #expect(
            RecipeSourceURLMatcher.normalizedKey(" HTTPS://Example.COM/Recipe?id=1#top ")
                == "https://example.com/Recipe?id=1"
        )
    }
}

/// Store-level coverage for the zero-network duplicate skip and the explicit "Re-import from
/// source" (owner decision 2026-08-09): repeat imports of an already-saved URL never fetch, the
/// share-extension drain drops matching queue rows as success, and a re-import replaces the
/// definition while preserving the sealed photo, the user's notes, and the synced web-image
/// suppression — merging over the LIVE row (mid-flight edits survive), reporting a deleted row as
/// `nil` rather than success, re-arming the device-local image attempt, and leaving the recipe
/// untouched when the fetch fails.
@MainActor
struct RecipeReimportTests {

    private func makeSavedWebRecipe(
        id: UUID = UUID(),
        url: String,
        name: String = "Web Oats",
        notes: String = "Import summary",
        suppressed: Bool? = nil
    ) -> RecipeDefinition {
        let savedAt = Date(timeIntervalSince1970: 1_779_664_800)
        return RecipeDefinition(
            id: id,
            name: name,
            servings: 2,
            ingredients: [],
            notes: notes,
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: url,
                ingredientLines: ["1 cup oats"],
                macros: Macros(protein: 10, carbs: 30, fat: 5),
                webImageSuppressed: suppressed
            )
        )
    }

    private func tinyJPEGData() -> Data {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let image = renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        return image.jpegData(compressionQuality: 0.8)!
    }

    private func scratchQueueURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("recipe-skip-\(name)-\(UUID().uuidString)")
            .appendingPathExtension("json")
    }

    // MARK: - Foreground duplicate lookup (zero network on hit)

    /// The lookup the paste-a-URL path gates on: cosmetic URL variants hit the saved recipe, a
    /// different query string does not. A hit means the foreground path returns before
    /// `RecipeWebImporter` is ever called.
    @Test func savedRecipeLookupMatchesNormalizedVariantsOnly() {
        let store = makeTestStore()
        let recipe = makeSavedWebRecipe(url: "https://example.com/recipes/oats?id=2")
        store.addSavedRecipe(recipe)

        let variant = URL(string: "HTTPS://EXAMPLE.COM/recipes/oats?id=2#reviews")!
        #expect(store.savedRecipe(matchingSourceURL: variant)?.id == recipe.id)

        let differentQuery = URL(string: "https://example.com/recipes/oats?id=3")!
        #expect(store.savedRecipe(matchingSourceURL: differentQuery) == nil)
    }

    // MARK: - Drain skip (queue row dropped as success, no fetch)

    /// A queued URL matching a saved recipe is removed as SUCCESS: no fetch, no attempt
    /// bookkeeping. The loopback host proves no network happened — if the drain had fetched, the
    /// importer's SSRF guard would have thrown and `markAttempt` would have kept the row with
    /// `attemptCount == 1`.
    @Test func drainDropsQueueRowMatchingASavedRecipeWithoutFetching() async {
        let store = makeTestStore()
        store.addSavedRecipe(makeSavedWebRecipe(url: "https://127.0.0.1/recipes/oats?id=2"))

        let queue = SharedRecipeImportQueue(fileURL: scratchQueueURL("match"))
        queue.save([SharedRecipeImportRecord(url: URL(string: "HTTPS://127.0.0.1/recipes/oats?id=2#comments")!)])
        store.sharedRecipeImportQueue = queue

        await store.processSharedRecipeImportQueue()

        #expect(queue.records().isEmpty, "a matching row must be dropped as success, not retried")
        #expect(store.savedRecipes.count == 1, "the existing recipe must be kept, not superseded")
        queue.clear()
    }

    /// The negative half: a queued URL differing in QUERY is not a duplicate, so the drain still
    /// attempts it (here: the SSRF guard refuses the loopback host without touching the network,
    /// so the row survives with one failed attempt — proving no false skip).
    @Test func drainStillAttemptsAQueueRowWithADifferentQuery() async {
        let store = makeTestStore()
        store.addSavedRecipe(makeSavedWebRecipe(url: "https://127.0.0.1/recipes/oats?id=2"))

        let queue = SharedRecipeImportQueue(fileURL: scratchQueueURL("nomatch"))
        queue.save([SharedRecipeImportRecord(url: URL(string: "https://127.0.0.1/recipes/oats?id=3")!)])
        store.sharedRecipeImportQueue = queue

        await store.processSharedRecipeImportQueue()

        let records = queue.records()
        #expect(records.count == 1)
        #expect(records.first?.attemptCount == 1, "a non-duplicate row must still be attempted")
        queue.clear()
    }

    // MARK: - Re-import from source (replace definition, preserve photo + notes)

    /// The replace-and-preserve contract: same id (so the sealed photo — keyed by id — survives
    /// with no migration), user notes and suppression carried, everything content-like
    /// refreshed from the new import.
    @Test func reimportReplacesDefinitionButPreservesPhotoNotesAndSuppression() throws {
        let store = makeTestStore()
        let original = makeSavedWebRecipe(
            url: "https://example.com/recipes/oats",
            notes: "my own tweaks: use maple syrup",
            suppressed: true
        )
        store.addSavedRecipe(original)
        #expect(store.saveRecipePhoto(data: tinyJPEGData(), for: original.id))
        let photoBefore = try #require(store.recipePhotoData(for: original.id))

        let fresh = ImportedRecipe(
            sourceURL: URL(string: "https://example.com/recipes/oats")!,
            name: "Web Oats v2",
            ingredients: ["2 cups oats", "1 tbsp honey"],
            summary: "A refreshed summary that must NOT overwrite the user's notes.",
            servings: 3,
            protein: 12,
            carbs: 40,
            fat: 6,
            steps: [RecipeStep(text: "Boil the oats.")],
            imageURL: URL(string: "https://cdn.example.com/new-hero.jpg")
        )
        let refreshed = try #require(store.applyReimportedRecipe(fresh, to: original))

        // Same identity, so the sealed photo is still reachable and untouched.
        #expect(refreshed.id == original.id)
        #expect(store.recipePhotoData(for: original.id) == photoBefore)
        // User-owned state preserved.
        #expect(refreshed.notes == "my own tweaks: use maple syrup")
        #expect(refreshed.createdAt == original.createdAt)
        #expect(refreshed.webImport?.webImageSuppressed == true)
        // Content refreshed.
        #expect(refreshed.name == "Web Oats v2")
        #expect(refreshed.servings == 3)
        #expect(refreshed.webImport?.ingredientLines == ["2 cups oats", "1 tbsp honey"])
        #expect(refreshed.webImport?.macros == Macros(protein: 12, carbs: 40, fat: 6))
        #expect(refreshed.webImport?.imageURLString == "https://cdn.example.com/new-hero.jpg")
        #expect(refreshed.steps?.first?.text == "Boil the oats.")
        // And the store row is the refreshed one — replaced, not duplicated.
        #expect(store.savedRecipes.count == 1)
        #expect(store.savedRecipes.first?.name == "Web Oats v2")

        store.deleteSavedRecipe(refreshed) // removes the sealed photo file from the shared container
    }

    /// The merge reads the CURRENT row, not the caller's snapshot: notes edited (or suppression
    /// stamped) while the re-import fetch was in flight survive the refresh instead of being
    /// silently reverted to the pre-edit copy.
    @Test func reimportMergesOverTheLiveRowNotTheCallersSnapshot() throws {
        let store = makeTestStore()
        let original = makeSavedWebRecipe(url: "https://example.com/recipes/oats", notes: "before")
        store.addSavedRecipe(original)
        // The detail view captured `original` at tap time; while the fetch runs, the user edits
        // notes (live row updated) and the image fetch suppresses the web picture.
        store.updateSavedRecipeNotes("edited DURING the re-import fetch", forRecipeID: original.id)
        store.deleteRecipePhoto(for: original.id)

        let fresh = ImportedRecipe(
            sourceURL: URL(string: "https://example.com/recipes/oats")!,
            name: "Web Oats v2",
            ingredients: ["2 cups oats"],
            summary: "Refreshed.",
            servings: 2,
            protein: 12,
            carbs: 40,
            fat: 6
        )
        let refreshed = try #require(store.applyReimportedRecipe(fresh, to: original))

        #expect(refreshed.notes == "edited DURING the re-import fetch",
                "the stale tap-time snapshot must not revert mid-flight edits")
        #expect(refreshed.webImport?.webImageSuppressed == true,
                "a suppression stamped mid-flight must survive the merge")
        #expect(store.savedRecipes.first { $0.id == original.id }?.notes == "edited DURING the re-import fetch")
        store.deleteSavedRecipe(refreshed)
    }

    /// A recipe deleted while the re-import fetch was in flight: nothing is persisted and the
    /// caller gets `nil` — never a false "Refreshed" success over a silent no-op.
    @Test func reimportOfADeletedRecipeReportsNilAndPersistsNothing() {
        let store = makeTestStore()
        let original = makeSavedWebRecipe(url: "https://example.com/recipes/oats")
        store.addSavedRecipe(original)
        store.deleteSavedRecipe(original)

        let fresh = ImportedRecipe(
            sourceURL: URL(string: "https://example.com/recipes/oats")!,
            name: "Web Oats v2",
            ingredients: ["2 cups oats"],
            summary: "Refreshed.",
            servings: 2,
            protein: 12,
            carbs: 40,
            fat: 6
        )
        #expect(store.applyReimportedRecipe(fresh, to: original) == nil)
        #expect(store.savedRecipes.isEmpty, "the deleted row must not resurrect")
    }

    /// The explicit re-import re-arms THIS device's one automatic web-image attempt (a transiently
    /// failed download becomes recoverable through the documented refresh affordance), while a
    /// synced suppression still wins at fetch time.
    @Test func reimportRearmsTheDeviceLocalImageAttempt() throws {
        let store = makeTestStore()
        let suiteName = "fernlet-tests-rearm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        store.webImageAttemptDefaults = defaults

        let original = makeSavedWebRecipe(url: "https://example.com/recipes/oats")
        store.addSavedRecipe(original)
        RecipeWebImageAttemptMemory.recordAttempt(original.id, defaults: defaults)

        let fresh = ImportedRecipe(
            sourceURL: URL(string: "https://example.com/recipes/oats")!,
            name: "Web Oats v2",
            ingredients: ["2 cups oats"],
            summary: "Refreshed.",
            servings: 2,
            protein: 12,
            carbs: 40,
            fat: 6
        )
        let refreshed = try #require(store.applyReimportedRecipe(fresh, to: original))
        #expect(!RecipeWebImageAttemptMemory.hasAttempted(original.id, defaults: defaults),
                "the refresh must re-arm the device's one automatic attempt")
        store.deleteSavedRecipe(refreshed)
    }

    /// A failed re-import mutates NOTHING: the loopback source URL is refused by the importer's
    /// SSRF guard (no network), and the recipe, its notes, and its photo are exactly as before.
    @Test func failedReimportLeavesTheRecipeUntouched() async throws {
        let store = makeTestStore()
        let original = makeSavedWebRecipe(url: "https://127.0.0.1/recipes/oats", notes: "keep me")
        store.addSavedRecipe(original)
        #expect(store.saveRecipePhoto(data: tinyJPEGData(), for: original.id))
        let photoBefore = try #require(store.recipePhotoData(for: original.id))

        await #expect(throws: RecipeWebImportError.self) {
            _ = try await store.reimportSavedRecipeFromSource(original)
        }

        let unchanged = try #require(store.savedRecipes.first { $0.id == original.id })
        #expect(unchanged == original)
        #expect(store.recipePhotoData(for: original.id) == photoBefore)

        store.deleteSavedRecipe(original)
    }

    // MARK: - Normalized supersede keeps photo cleanup in sync

    /// A NEW-id import whose URL differs only cosmetically still supersedes the old row (service
    /// match) AND deletes the old row's sealed photo (store cleanup) — the two matches must agree
    /// or every re-import under a variant URL strands a photo.
    @Test func normalizedSupersedeReplacesRowAndCleansUpItsPhoto() {
        let store = makeTestStore()
        let old = makeSavedWebRecipe(url: "https://example.com/recipes/oats", name: "Old")
        store.addSavedRecipe(old)
        #expect(store.saveRecipePhoto(data: tinyJPEGData(), for: old.id))

        let replacement = makeSavedWebRecipe(url: "HTTPS://Example.com/recipes/oats#print", name: "New")
        store.addSavedRecipe(replacement)

        #expect(store.savedRecipes.map(\.id) == [replacement.id])
        #expect(store.recipePhotoData(for: old.id) == nil, "the superseded row's photo must not be stranded")

        store.deleteSavedRecipe(replacement)
    }
}
