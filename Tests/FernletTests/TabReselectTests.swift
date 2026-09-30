import Foundation
import Testing
@testable import Fernlet

/// Decision logic behind "re-tap the active tab": pop to the tab's main page when something is
/// pushed, scroll to the top when nothing is (``TabReselectAction``), and the Food path's pruning
/// of a recipe detail whose recipe is gone (``FoodRoute/pruned(_:manualIDs:savedIDs:)``).
///
/// The navigation itself — that clearing a path really unwinds the pages pushed above it — is
/// proved on screen by `TabReselectUITests`; these pin the pure halves it rests on.
@Suite struct TabReselectTests {

    // MARK: - TabReselectAction

    @Test func reselectAtTheRootScrollsToTop() {
        #expect(TabReselectAction.forReselect(isAtRoot: true) == .scrollToTop)
    }

    @Test func reselectWithAPagePushedPopsToRoot() {
        #expect(TabReselectAction.forReselect(isAtRoot: false) == .popToRoot)
    }

    // MARK: - FoodRoute.pruned

    private let manual = UUID()
    private let saved = UUID()

    @Test func recipeBookIsAlwaysLive() {
        #expect(FoodRoute.pruned([.recipeBook], manualIDs: [], savedIDs: []) == [.recipeBook])
        #expect(FoodRoute.pruned([.recipeBook], manualIDs: [manual], savedIDs: [saved]) == [.recipeBook])
    }

    @Test func liveRecipeDetailsAreKept() {
        let path: [FoodRoute] = [
            .recipeDetail(id: manual, isSaved: false),
            .recipeDetail(id: saved, isSaved: true),
        ]
        #expect(FoodRoute.pruned(path, manualIDs: [manual], savedIDs: [saved]) == path)
    }

    @Test func deletedRecipeDetailIsCut() {
        let path: [FoodRoute] = [.recipeDetail(id: manual, isSaved: false)]
        #expect(FoodRoute.pruned(path, manualIDs: [], savedIDs: []).isEmpty)
    }

    /// The two store halves are separate namespaces: an id that exists only in the OTHER half does
    /// not keep a route alive, in either direction.
    @Test func storeHalvesNeverCrossMatch() {
        let manualRoute: [FoodRoute] = [.recipeDetail(id: manual, isSaved: false)]
        #expect(FoodRoute.pruned(manualRoute, manualIDs: [], savedIDs: [manual]).isEmpty)
        let savedRoute: [FoodRoute] = [.recipeDetail(id: saved, isSaved: true)]
        #expect(FoodRoute.pruned(savedRoute, manualIDs: [saved], savedIDs: []).isEmpty)
    }

    /// Everything from the first dead page up goes — a live page pushed above a dead one would be
    /// standing on nothing.
    @Test func everythingFromTheFirstDeadRouteUpIsDropped() {
        let path: [FoodRoute] = [
            .recipeBook,
            .recipeDetail(id: manual, isSaved: false),
            .recipeDetail(id: saved, isSaved: true),
        ]
        #expect(FoodRoute.pruned(path, manualIDs: [], savedIDs: [saved]) == [.recipeBook])
    }

    @Test func emptyPathStaysEmpty() {
        #expect(FoodRoute.pruned([], manualIDs: [], savedIDs: []).isEmpty)
    }
}
