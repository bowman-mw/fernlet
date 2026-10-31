import CoreGraphics
import Foundation
import SwiftUI
import Testing
import WorldMapStore
@testable import Fernlet

/// The world map's cached drawing (round 7 performance): built for a camera a margin larger than the screen,
/// moved with the finger while it covers the screen, and asked for again only when the view drifts, the level,
/// the data or the colours change.
@MainActor
struct WorldViewMapDrawingTests {
    private static let phone = CGSize(width: 402, height: 874)
    private static let portland = GeoPoint(45.5152, -122.6784)

    private static func facts(_ level: AtlasZoomLevel, found: Set<HexCell> = []) -> WorldViewMapFacts {
        WorldViewMapFacts(level: level, raster: nil, atlas: nil, found: found, places: [:], roads: .none, lands: [:])
    }

    /// The grown camera shows the same place at the same spot, `margin` points further in, and its centre is
    /// not clamped again (World's pole rule would move it).
    @Test func overscanKeepsTheCentre() {
        let camera = WorldViewCamera(level: .world, centre: Self.portland, size: Self.phone)
        let grown = camera.overscanned(by: WorldViewMapDrawing.margin)
        #expect(grown.x == camera.x && grown.y == camera.y && grown.level == camera.level)
        let here = camera.screenPoint(of: Self.portland), there = grown.screenPoint(of: Self.portland)
        #expect(abs(there.x - here.x - WorldViewMapDrawing.margin) < 1e-9)
        #expect(abs(there.y - here.y - WorldViewMapDrawing.margin) < 1e-9)
        #expect(camera.overscanned(by: .nan) == camera)
    }

    /// A pan smaller than the drift keeps the drawing, moved by exactly the pan; a longer pan, a level step, new
    /// data or night colours ask for a fresh one.
    @Test func panningMovesTheDrawingUntilItDrifts() {
        let camera = WorldViewCamera(level: .state, centre: Self.portland, size: Self.phone)
        let key = WorldViewMapDrawing.key(for: camera, generation: 3, dark: false)
        var facts = Self.facts(.state)
        let drawing = WorldViewMapDrawing.build(key, facts: &facts)
        #expect(!drawing.isStale(for: key))
        var panned = camera
        panned.pan(by: CGSize(width: 40, height: -25))
        #expect(!drawing.isStale(for: WorldViewMapDrawing.key(for: panned, generation: 3, dark: false)))
        let placed = drawing.placement(on: panned)
        #expect(abs(placed.centre.x - (Self.phone.width / 2 + 40)) < 1e-6)
        #expect(abs(placed.centre.y - (Self.phone.height / 2 - 25)) < 1e-6)
        #expect(placed.scale == 1)
        var far = camera
        far.pan(by: CGSize(width: WorldViewMapDrawing.refreshDrift + 1, height: 0))
        #expect(drawing.isStale(for: WorldViewMapDrawing.key(for: far, generation: 3, dark: false)))
        var stepped = camera
        stepped.setLevel(.city)
        #expect(drawing.isStale(for: WorldViewMapDrawing.key(for: stepped, generation: 3, dark: false)))
        #expect(drawing.isStale(for: WorldViewMapDrawing.key(for: camera, generation: 4, dark: false)))
        #expect(drawing.isStale(for: WorldViewMapDrawing.key(for: camera, generation: 3, dark: true)))
    }

    /// The drift is measured the short way round: a camera across the antimeridian from the drawing is near it.
    @Test func driftWrapsRoundTheWorld() {
        let camera = WorldViewCamera(level: .country, centre: GeoPoint(-17, 179.99), size: Self.phone)
        let key = WorldViewMapDrawing.key(for: camera, generation: 0, dark: false)
        var facts = Self.facts(.country)
        let drawing = WorldViewMapDrawing.build(key, facts: &facts)
        let across = WorldViewCamera(level: .country, centre: GeoPoint(-17, -179.99), size: Self.phone)
        #expect(!drawing.isStale(for: WorldViewMapDrawing.key(for: across, generation: 0, dark: false)))
        #expect(abs(drawing.placement(on: across).centre.x - Self.phone.width / 2) < WorldViewMapDrawing.refreshDrift)
    }

    /// The hexes go in one path per colour, the found ones last; an uncovered hex adds the found colour and the
    /// roads' clip; the drawing covers the screen and the margin round it.
    @Test func buildGroupsTheHexesByColour() {
        let camera = WorldViewCamera(level: .state, centre: Self.portland, size: Self.phone)
        let key = WorldViewMapDrawing.key(for: camera, generation: 0, dark: false)
        var fogged = Self.facts(.state)
        let sea = WorldViewMapDrawing.build(key, facts: &fogged)
        #expect(sea.hexes.count == 1 && sea.uncovered.isEmpty && sea.roads.isEmpty)
        let centre = AtlasZoomLevel.state.hexGrid.cell(x: camera.x, y: camera.y)
        var opened = Self.facts(.state, found: [centre])
        let found = WorldViewMapDrawing.build(key, facts: &opened)
        #expect(found.hexes.map(\.found) == [false, true], "the found hexes' edges on top")
        #expect(!found.uncovered.isEmpty)
        let bounds = sea.hexes[0].path.boundingRect, size = key.camera.size
        #expect(bounds.minX <= 0 && bounds.minY <= 0 && bounds.maxX >= size.width && bounds.maxY >= size.height)
        #expect(opened.lands.count >= 1, "State's land is looked up per hex and handed back")
    }
}
