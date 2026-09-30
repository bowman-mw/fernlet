import Foundation
import Testing
@testable import Fernlet

/// Decision logic behind "re-tap the active tab": pop to the tab's main page when something is
/// pushed, ask first when a pushed page holds unsaved input, scroll to the top when nothing is
/// pushed (``TabReselectAction``); the draft registry those asks read (``TabDraftRegistry``); the
/// Food path's pruning of a recipe detail whose recipe is gone
/// (``FoodRoute/pruned(_:manualIDs:savedIDs:)``); and the Friends path closing the friend shop with
/// its window (``FriendsRoute``).
///
/// The navigation itself — that clearing a path really unwinds the pages pushed above it, and that
/// a typed recipe raises the discard alert — is proved on screen by `TabReselectUITests`; these pin
/// the pure halves it rests on.
@Suite struct TabReselectTests {

    // MARK: - TabReselectAction

    @Test func reselectAtTheRootScrollsToTop() {
        #expect(TabReselectAction.forReselect(isAtRoot: true, hasUnsavedDraft: false) == .scrollToTop)
    }

    @Test func reselectWithAPagePushedPopsToRoot() {
        #expect(TabReselectAction.forReselect(isAtRoot: false, hasUnsavedDraft: false) == .popToRoot)
    }

    /// A pushed editor with typed input: the tap asks, it never pops straight past the draft.
    @Test func reselectOverAnUnsavedDraftAsksFirst() {
        #expect(TabReselectAction.forReselect(isAtRoot: false, hasUnsavedDraft: true) == .confirmDiscardThenPop)
    }

    /// At the main page a scroll loses nothing, so a stale draft flag cannot turn it into a prompt.
    @Test func reselectAtTheRootScrollsEvenWithADraftReported() {
        #expect(TabReselectAction.forReselect(isAtRoot: true, hasUnsavedDraft: true) == .scrollToTop)
    }

    // MARK: - TabDraftRegistry

    @MainActor @Test func emptyRegistryHasNoDraft() {
        #expect(TabDraftRegistry().hasUnsavedDraft == false)
    }

    @MainActor @Test func registryFollowsAnEnrolledLeaseFlag() {
        let registry = TabDraftRegistry()
        let lease = TabDraftLease()
        registry.enroll(lease)
        #expect(registry.hasUnsavedDraft == false)
        lease.isDirty = true
        #expect(registry.hasUnsavedDraft)
        lease.isDirty = false
        #expect(registry.hasUnsavedDraft == false)
    }

    /// Any one dirty page is enough — the recipe editor stays counted under the scanner pushed over it.
    @MainActor @Test func anyDirtyLeaseMakesTheStackDirty() {
        let registry = TabDraftRegistry()
        let editor = TabDraftLease()
        let scanner = TabDraftLease()
        registry.enroll(editor)
        registry.enroll(scanner)
        editor.isDirty = true
        #expect(registry.hasUnsavedDraft)
    }

    /// The registry holds leases weakly: a page that left the stack took its lease — and its draft
    /// claim — with it.
    @MainActor @Test func aReleasedLeaseNoLongerCounts() {
        let registry = TabDraftRegistry()
        var lease: TabDraftLease? = TabDraftLease()
        if let lease {
            lease.isDirty = true
            registry.enroll(lease)
        }
        #expect(registry.hasUnsavedDraft)
        lease = nil
        #expect(registry.hasUnsavedDraft == false)
    }

    @MainActor @Test func releaseAllForgetsEveryLease() {
        let registry = TabDraftRegistry()
        let lease = TabDraftLease()
        lease.isDirty = true
        registry.enroll(lease)
        registry.releaseAll()
        #expect(registry.hasUnsavedDraft == false)
    }

    /// Re-enrolling the same lease (a page reappearing after the page above it pops) is harmless,
    /// and the slot count stays bounded however many pages come and go.
    @MainActor @Test func enrollIsIdempotentAndBounded() {
        let registry = TabDraftRegistry()
        let kept = TabDraftLease()
        registry.enroll(kept)
        registry.enroll(kept)
        let extras = (0..<(TabDraftRegistry.maxLeases * 2)).map { _ in TabDraftLease() }
        extras.forEach { registry.enroll($0) }
        extras.last?.isDirty = true
        #expect(registry.hasUnsavedDraft, "the newest lease must survive the cap")
    }

    // MARK: - FriendsRoute shop window

    @Test func openShopClosesWhenItsWindowExpires() {
        let expiry = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(FriendsRoute.shopClosesAt(sharingEnabled: true, windowExpiresAt: expiry) == expiry)
    }

    @Test func shopWithNoWindowClosesAtOnce() {
        #expect(FriendsRoute.shopClosesAt(sharingEnabled: true, windowExpiresAt: nil) == .distantPast)
    }

    @Test func shopClosesAtOnceWhenSharingIsOff() {
        let expiry = Date(timeIntervalSinceReferenceDate: 1_000_000)
        #expect(FriendsRoute.shopClosesAt(sharingEnabled: false, windowExpiresAt: expiry) == .distantPast)
    }

    @Test func closingTheShopTakesOnlyTheShopAndAbove() {
        #expect(FriendsRoute.closingShop([.friendShop]).isEmpty)
        #expect(FriendsRoute.closingShop([.friendList, .friendShop]) == [.friendList])
        #expect(FriendsRoute.closingShop([.activities, .friendList]) == [.activities, .friendList])
        #expect(FriendsRoute.closingShop([]).isEmpty)
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
