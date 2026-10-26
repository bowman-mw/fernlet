import Foundation
import MapKit
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// Issue desk W-15: the map's callbacks never write SwiftUI state while SwiftUI updates the map view. A report
/// MapKit raises inside `makeUIView` / `updateUIView` waits for the next main-queue turn (coalesced, skipped
/// when unchanged); outside it, reports go through at once. A panel closing while the map follows asks for no
/// move at all.
@MainActor
struct WorldMapReportGateTests {
    private static let here = GeoPoint(45.5205, -122.6255)

    /// The main queue's next turn, stepped by hand.
    @MainActor
    private final class NextTurn {
        var queued: [@MainActor () -> Void] = []

        func run() {
            let work = queued
            queued = []
            for item in work { item() }
        }
    }

    private static func viewport(_ x: Double) -> MapViewport {
        MapViewport(minX: x, minY: 0.3, width: 0.001, height: 0.002)
    }

    /// Inside the update every report is held: the latest viewport, the latest tile report and the camera
    /// write arrive once on the next turn. An unchanged viewport is skipped then; outside the update each
    /// report is delivered at once, and outdates one still held.
    @Test func reportsDuringTheUpdateWaitForTheNextTurn() {
        let turn = NextTurn()
        let gate = WorldMapReportGate(later: { turn.queued.append($0) })
        var viewports: [MapViewport] = []
        var tiles: [String] = []
        var cameraWrites = 0
        gate.updating {
            gate.report(Self.viewport(0.1)) { viewports.append($0) }
            gate.report(Self.viewport(0.2)) { viewports.append($0) }
            gate.send(.tiles) { tiles.append("loading") }
            gate.send(.tiles) { tiles.append("loaded") }
            gate.send(.camera) { cameraWrites += 1 }
        }
        #expect(viewports.isEmpty && tiles.isEmpty && cameraWrites == 0, "nothing written during the update")
        #expect(turn.queued.count == 1, "one delivery queued")
        turn.run()
        #expect(viewports == [Self.viewport(0.2)] && tiles == ["loaded"] && cameraWrites == 1)

        gate.updating { gate.report(Self.viewport(0.2)) { viewports.append($0) } }
        turn.run()
        #expect(viewports.count == 1, "an unchanged viewport is skipped")

        gate.report(Self.viewport(0.3)) { viewports.append($0) }
        #expect(viewports.last == Self.viewport(0.3) && turn.queued.isEmpty, "outside the update, at once")

        gate.updating { gate.report(Self.viewport(0.4)) { viewports.append($0) } }
        gate.report(Self.viewport(0.5)) { viewports.append($0) }
        turn.run()
        #expect(viewports.suffix(2) == [Self.viewport(0.3), Self.viewport(0.5)], "the held one was outdated")
    }

    /// (a) A move to where the camera already looks is no request: within half a metre, at the same height,
    /// only `follows` changes. A real move, or a move after a change of height, bumps the revision.
    @Test func aMoveThatGoesNowhereIsNoRequest() {
        var camera = WorldCamera(center: Self.here, distance: 1_200, follows: false)
        camera.move(to: Self.here)
        #expect(camera.revision == 0 && camera.follows)
        camera.move(to: Self.here.offset(east: 0.3, north: 0))
        #expect(camera.revision == 0 && camera.center == Self.here)
        camera.move(to: Self.here.offset(east: 5, north: 0))
        #expect(camera.revision == 1)
        camera.distance = 900
        camera.move(to: camera.center)
        #expect(camera.revision == 2, "a new height is a request")
    }

    /// Closing a panel while the map follows makes no synchronous viewport write (W-15's path): the follow
    /// asks for the camera already shown, so there is no revision to apply; (b) even a bumped revision for
    /// the camera MapKit already shows moves nothing; and whatever MapKit reports inside the update reaches
    /// the stack only on the next turn.
    @Test func closingAPanelWhileFollowingWritesNoViewportDuringTheUpdate() {
        let fix = Self.here
        var camera = WorldCamera(center: WorldMapHome.lookAt(fix, distance: 1_200), distance: 1_200)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.layoutMargins = AppleMapGeometry.margins(bottomInset: WorldMapHome.creditInset)
        map.setCamera(AppleMapGeometry.mapCamera(for: camera), animated: false)
        map.layoutIfNeeded()
        let applied = camera.revision

        camera.move(to: WorldMapHome.lookAt(fix, distance: camera.distance))
        #expect(camera.revision == applied, "the panel's follow asks for no move")
        let bumped = WorldCamera(center: camera.center, distance: camera.distance, revision: applied + 1)
        #expect(AppleMapGeometry.cameraMove(for: bumped, applied: applied, showing: map.camera) == nil,
                "MapKit already shows it")
        let elsewhere = WorldCamera(center: fix.offset(east: 200, north: 0), distance: 1_200, revision: applied + 1)
        #expect(AppleMapGeometry.cameraMove(for: elsewhere, applied: applied, showing: map.camera) != nil)

        let turn = NextTurn()
        let gate = WorldMapReportGate(later: { turn.queued.append($0) })
        var writes = 0
        gate.updating {
            if let move = AppleMapGeometry.cameraMove(for: bumped, applied: applied, showing: map.camera) {
                map.setCamera(move, animated: true)
            }
            // MapKit finishing a no-op move at once reports from inside the update.
            gate.report(AppleMapGeometry.viewport(of: map)) { _ in writes += 1 }
        }
        #expect(writes == 0, "no viewport write during the update")
        turn.run()
        #expect(writes == 1, "delivered once, after it")
    }
}
