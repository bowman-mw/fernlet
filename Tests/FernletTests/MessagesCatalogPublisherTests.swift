import FernletDomainModel
import FernletExchange
import Foundation
import Testing
@testable import Fernlet

/// Pins how the app's Messages catalog publisher treats a library it cannot share whole.
///
/// The catalog is the Messages extension's ENTIRE view of the user's recipes and plans, and it is
/// only rewritten by a successful publish. Until 2026-09-23 one item the exchange rules refuse made
/// the whole publish throw, so the extension kept offering a stale catalog — recipes since deleted
/// included — or, on a fresh install, none at all, with nothing but an audit-log line to say why.
/// The realistic trigger is a web-imported recipe: the importers accept up to 100 servings
/// (`FernletStore.RecipeImportLimits`), the exchange packet at most 24.
@MainActor
struct MessagesCatalogPublisherTests {

    /// A recipe the exchange validator refuses is left out; every shareable one still publishes.
    @Test func oneUnshareableRecipeDoesNotEmptyTheCatalog() throws {
        let store = makeTestStore()
        store.recipes = [
            Self.recipe(named: "Party cookies", servings: 36),
            Self.recipe(named: "Weeknight soup", servings: 4)
        ]
        let directory = Self.uniqueCatalogDirectory()

        #expect(FernletMessagesCatalogPublisher(directory: directory).publish(from: store),
                "one oversized recipe aborted the whole publish")
        let catalog = try #require(try FernletMessagesCatalogFileStore(directory: directory).read())
        #expect(catalog.recipes.map(\.card.title) == ["Weeknight soup"])
    }

    /// A planned workout whose card the exchange refuses (a name past the 120-character card
    /// title bound) is left out; the day's other plan still publishes.
    @Test func oneUnshareablePlannedWorkoutDoesNotEmptyTheCatalog() throws {
        let store = makeTestStore()
        store.planWorkout(Self.workout(named: String(repeating: "Long ", count: 30)), date: store.todayKey)
        store.planWorkout(Self.workout(named: "Upper body"), date: store.todayKey)
        let directory = Self.uniqueCatalogDirectory()

        #expect(FernletMessagesCatalogPublisher(directory: directory).publish(from: store),
                "one unshareable plan aborted the whole publish")
        let catalog = try #require(try FernletMessagesCatalogFileStore(directory: directory).read())
        #expect(catalog.workouts.map(\.card.title) == ["Upper body"])
    }

    private static func uniqueCatalogDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("messages-catalog-publisher-\(UUID().uuidString)", isDirectory: true)
    }

    private static func recipe(named name: String, servings: Int) -> RecipeDefinition {
        RecipeDefinition(name: name, servings: servings, ingredients: [], source: "test",
                         createdAt: .now, updatedAt: .now)
    }

    private static func workout(named name: String) -> PlannedWorkout {
        PlannedWorkout(name: name, split: .upper, source: .user, notes: "", duration: 45)
    }
}
