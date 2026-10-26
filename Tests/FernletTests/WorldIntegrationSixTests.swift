import FernletDomainModel
import FernletFoundation
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// World build round 6's integration seams (2026-10-25): the two store lines the lanes left to the
/// integrator, held end to end — the widget wears the Creation Studio pieces the map wears, and the
/// app-lock reset takes the homes and hotel at once, as its screens say ("This also deletes the places
/// you've been.").
@MainActor
struct WorldIntegrationSixTests {
    /// The published widget snapshot carries the worn pieces (lane companion's need 1), and none in a decoy.
    @Test func theWidgetSnapshotWearsTheStudioPieces() {
        let store = makeTestStore()
        let piece = WorldCompanionWardrobeTests.item(.hat, cols: 18, rows: 11) { _, y in y == 10 ? 0 : -1 }
        store.saveCustomItem(piece)
        store.equipCustomItem(id: piece.id, slot: .hat)
        #expect(store.currentWidgetSnapshot().companionLook?.items?.count == 1)
        #expect(store.currentWidgetSnapshot().companionLook == store.widgetCompanionLook)
        store.duressSessionActive = true
        #expect(store.currentWidgetSnapshot().companionLook?.items == nil)
        store.duressSessionActive = false
    }

    /// The app-lock reset funnel deletes the homes and hotel on the spot (lane places' need 2): nothing is
    /// read back after it, and the map draws no house.
    @Test func theAppLockResetTakesTheHomesAtOnce() {
        let store = makeTestStore()
        let home = HomePlace(kind: .home, label: "Home", point: GeoPoint(45.5205, -122.6255))
        #expect(store.saveWorldHome(home))
        #expect(store.worldPlaces.homes.homes.count == 1)
        store.handleAppLockResetCompleted(preferences: StoragePreferences(), clearBookkeeping: {})
        #expect(store.worldPlaces.homes.homes.isEmpty)
        store.reloadWorldHomes()
        #expect(store.worldHomes.homes.isEmpty, "the device side was deleted, not only forgotten in memory")
    }
}
