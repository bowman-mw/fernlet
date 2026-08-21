import Foundation
import Testing
import FernletDomainModel
import CloudKitSync
@testable import Fernlet

/// Round 2026-08-20 Parts 4.1e + 4.2: three device-local surfaces the "Delete everything" funnel
/// previously never reached — the pre-Core-Data `SavedRecipes.json` file, the Log-activity Recent
/// chips (`fernlet.recentActivityTypes`), and the workout tombstone ring
/// (`fernlet.workout.tombstones`). Each test drives the owning type's clear API directly through
/// its injectable seam (file URL / suite-named defaults); the funnel's wiring is enforced
/// separately by `PrivacyWipeCoverageTests`. Suite-named defaults are used because parallel suites
/// share `.standard`, and each suite is removed again so no state leaks between runs.
struct DeviceLocalStoreClearTests {

    // MARK: - Legacy SavedRecipes.json (Part 4.1e)

    /// `deleteFile()` removes a real on-disk legacy file, after which `load()` finds nothing —
    /// the plaintext names/ingredients/notes/source URLs are gone, not just orphaned.
    @Test func legacySavedRecipesDeleteFileRemovesTheFile() throws {
        let url = Self.temporaryJSONURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = LegacySavedRecipeJSONRepository(fileURL: url)
        let recipe = RecipeDefinition(
            name: "Wipe Bowl",
            servings: 2,
            ingredients: [],
            notes: "Cook and combine.",
            source: MealLogSource.webImport,
            createdAt: Date(),
            updatedAt: Date(),
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/wipe-bowl",
                ingredientLines: ["1 cup rice", "200g chicken"]
            )
        )
        #expect(repository.save([recipe]))
        #expect(FileManager.default.fileExists(atPath: url.path))

        #expect(repository.deleteFile())

        #expect(!FileManager.default.fileExists(atPath: url.path))
        #expect(repository.load().isEmpty)
    }

    /// A missing file counts as success — the wipe must not report an incomplete store for an
    /// install that never had (or already lost) the legacy file.
    @Test func legacySavedRecipesDeleteFileTreatsMissingFileAsSuccess() {
        let repository = LegacySavedRecipeJSONRepository(fileURL: Self.temporaryJSONURL())
        #expect(repository.deleteFile())
    }

    // MARK: - Recent activity chips (Part 4.2)

    /// `clearAll` removes the persisted chip list outright, so a wiped phone's Log-activity sheet
    /// shows no previous owner's recent picks.
    @Test func recentActivityTypeClearAllRemovesTheStoredKey() throws {
        let suiteName = "DeviceLocalStoreClearTests-recent-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set("running,walking,yoga", forKey: RecentActivityTypeMemory.defaultsKey)

        RecentActivityTypeMemory.clearAll(defaults: defaults)

        #expect(defaults.object(forKey: RecentActivityTypeMemory.defaultsKey) == nil)
    }

    /// The constant is a frozen persisted token: `ActivityPickerSection`'s `@AppStorage` reads the
    /// same symbol, so this pin is what keeps a rename from silently stranding every device's
    /// existing chips while the wipe clears a key nobody writes.
    @Test func recentActivityTypesKeyStaysFrozen() {
        #expect(RecentActivityTypeMemory.defaultsKey == "fernlet.recentActivityTypes")
    }

    // MARK: - Workout tombstone ring (Part 4.2)

    /// `clearAll` empties the ring and removes the key itself — after a wipe a surviving tombstone
    /// whose Health delete never confirmed would make the workout observer delete a still-existing
    /// app-authored Health sample on the next re-enable, against an explicit "keep my Health
    /// samples" answer.
    @Test func workoutTombstoneClearAllEmptiesTheRingAndRemovesTheKey() throws {
        let suiteName = "DeviceLocalStoreClearTests-tombstones-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let key = "fernlet.workout.tombstones"
        let store = WorkoutTombstoneStore(defaults: defaults, key: key)
        let unconfirmed = UUID()
        let recent = UUID()
        store.insert(unconfirmed)
        store.insert(recent)
        #expect(store.contains(unconfirmed))
        #expect(store.contains(recent))

        store.clearAll()

        #expect(!store.contains(unconfirmed))
        #expect(!store.contains(recent))
        #expect(
            defaults.object(forKey: key) == nil,
            "the key must be removed outright, not left as an empty array — a wiped device should carry no trace of the ring"
        )
    }

    /// The ring stays usable after a clear — the next locally removed workout tombstones normally.
    @Test func workoutTombstoneStoreAcceptsInsertsAfterClearAll() throws {
        let suiteName = "DeviceLocalStoreClearTests-tombstones-reuse-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = WorkoutTombstoneStore(defaults: defaults, key: "fernlet.workout.tombstones")
        store.insert(UUID())
        store.clearAll()

        let postWipe = UUID()
        store.insert(postWipe)

        #expect(store.contains(postWipe))
    }

    // MARK: - Fixtures

    private static func temporaryJSONURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("DeviceLocalStoreClearTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("SavedRecipes.json")
    }
}
