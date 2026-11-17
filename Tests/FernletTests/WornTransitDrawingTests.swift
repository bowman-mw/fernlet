import FernletDomainModel
import Foundation
import SwiftUI
import Testing
import WorldMapStore
@testable import Fernlet

/// Railways and ferry wakes, the drawing lane (Docs/World-Transit-Paths-Exploration-2026-11-15.md §2, §3): the pieces
/// each level draws from given tallies of kind `.rail` and `.ferry`, Your world's long runs only, the map widget
/// carrying them with a stamp that moves when they change, and the "Show worn paths" switch hiding them.
@MainActor
struct WornTransitDrawingTests {
    nonisolated private static let here = GeoPoint(45.5205, -122.6255)
    nonisolated private static let today: UInt16 = 2_000

    /// The counter of `kind` along `line` at `count` trips, the last `daysAgo` days ago.
    nonisolated static func ways(_ kind: WornWayKind, _ line: [GeoPoint], count: UInt16, daysAgo: UInt16 = 0) -> [WornWayKey: WornTally] {
        var ways: [WornWayKey: WornTally] = [:]
        for cell in WornFootpaths.cells(along: line) {
            ways[WornWayKey(cell: cell, kind: kind)] = WornTally(count: count, lastDay: today - daysAgo)
        }
        return ways
    }

    /// The drawing of `ways` on ``today``.
    nonisolated static func drawing(_ ways: [WornWayKey: WornTally]) -> WornWaysDrawing {
        WornWaysBuilder.make(index: WornFootpathIndex(), ways: ways, today: today, trails: [], trailStamp: 0, generation: 1)
    }

    nonisolated static func line(from start: GeoPoint = here, east metres: Double, north: Double = 0) -> [GeoPoint] {
        WornPathsDrawingTests.line(from: start, east: metres, north: north)
    }

    // MARK: Pieces by level

    /// A railway and a ferry crossing each show from the third trip, rise at 10 and 30, fade to abandoned and stay,
    /// drawn hex centre to hex centre in their own lists, never as roads.
    @Test(arguments: [WornWayKind.rail, .ferry])
    func transitDrawsItsLevelFromTheTallies(kind: WornWayKind) throws {
        let ride = Self.line(east: 400)
        let pieces = { (drawing: WornWaysDrawing) in kind == .rail ? drawing.rails : drawing.ferries }
        #expect(pieces(Self.drawing(Self.ways(kind, ride, count: 2))).isEmpty, "two rides: nothing")
        for (count, level) in [(UInt16(3), WornLevel.one), (10, .two), (30, .three)] {
            let drawing = Self.drawing(Self.ways(kind, ride, count: count))
            #expect(!pieces(drawing).isEmpty)
            #expect(pieces(drawing).allSatisfy { $0.level == level }, "\(count) rides")
            #expect(drawing.roads.isEmpty && drawing.footpaths.isEmpty, "never drawn as a road or a path")
            #expect(!drawing.isEmpty)
        }
        let abandoned = pieces(Self.drawing(Self.ways(kind, ride, count: 3, daysAgo: 95)))
        #expect(!abandoned.isEmpty && abandoned.allSatisfy { $0.level == .abandoned }, "faded: abandoned, kept")
        let piece = try #require(pieces(Self.drawing(Self.ways(kind, ride, count: 30))).first)
        let centres = Set(WornFootpaths.cells(along: ride).map { MercatorHexGrid.centre(of: $0) }.map { "\($0.x),\($0.y)" })
        #expect(zip(piece.line.xs, piece.line.ys).allSatisfy { centres.contains("\($0),\($1)") }, "every point a cell's centre")
        let drawing = Self.drawing(Self.ways(kind, ride, count: 10))
        let byLevel = kind == .rail ? drawing.railsByLevel : drawing.ferriesByLevel
        #expect(byLevel[WornLevel.two.rawValue].count == pieces(drawing).count)
    }

    /// A road, a railway and a wake on the same cells are three ways: each draws, and each moves the hash.
    @Test func kindsOnOneCellAreSeparateWays() {
        let line = Self.line(east: 300)
        let road = Self.ways(.road, line, count: 10), rail = Self.ways(.rail, line, count: 10), ferry = Self.ways(.ferry, line, count: 10)
        let all = Self.drawing(road.merging(rail) { $1 }.merging(ferry) { $1 })
        #expect(!all.roads.isEmpty && !all.rails.isEmpty && !all.ferries.isEmpty)
        #expect(Self.drawing(road).contentHash != all.contentHash)
        #expect(Self.drawing(road.merging(rail) { $1 }).contentHash != all.contentHash)
        let again = WornWaysBuilder.make(index: WornFootpathIndex(), ways: road.merging(ferry) { $1 }.merging(rail) { $1 },
                                         today: Self.today, trails: [], trailStamp: 0, generation: 5)
        #expect(again.contentHash == all.contentHash, "the same ways worked out again hash the same")
    }

    // MARK: Your world

    /// Your world draws railways and ferry crossings at level 1 or more in runs of 2 km or longer only, each kind
    /// on its own.
    @Test(arguments: [WornWayKind.rail, .ferry])
    func yourWorldDrawsLongRunsOnly(kind: WornWayKind) {
        let long = Self.ways(kind, Self.line(east: 2_600), count: 5)
        let short = Self.ways(kind, Self.line(from: Self.here.offset(east: 0, north: 2_000), east: 900), count: 40)
        let faded = Self.ways(kind, Self.line(from: Self.here.offset(east: 0, north: -2_000), east: 2_600), count: 5, daysAgo: 70)
        let ways = long.merging(short) { $1 }.merging(faded) { $1 }
        let drawing = WornWaysBuilder.yourWorldWays(ways, kind: kind, today: Self.today, generation: 1)
        #expect(drawing.roadCount == 1, "only the long, current run")
        let north = WebMercator.unit(Self.here.offset(east: 0, north: 500)).y, south = WebMercator.unit(Self.here.offset(east: 0, north: -500)).y
        #expect(!drawing.pieces.isEmpty && drawing.pieces.allSatisfy { $0.minY > north && $0.maxY < south })
        #expect(WornWaysBuilder.yourWorldWays(short, kind: kind, today: Self.today, generation: 1).pieces.isEmpty)
        #expect(WornWaysBuilder.yourWorldRoads(ways, today: Self.today, generation: 1).pieces.isEmpty, "not a road")
        let other: WornWayKind = kind == .rail ? .ferry : .rail
        #expect(WornWaysBuilder.yourWorldWays(ways, kind: other, today: Self.today, generation: 1).pieces.isEmpty)
    }

    // MARK: The widget

    /// The widget's picture carries the railways and wakes in its viewport, tagged by kind, and its stamp moves when
    /// one is added or changes level.
    @Test func theWidgetCarriesRailsAndWakes() {
        let store = makeTestStore()
        let viewport = MapViewport.around(Self.here, heightMetres: 420, size: WorldWidgetMap.pictureSize)
        let rail = Self.ways(.rail, Self.line(east: 150), count: 12)
        let ferry = Self.ways(.ferry, Self.line(from: Self.here.offset(east: 0, north: -80), east: 150), count: 4)
        let worn = Self.drawing(rail.merging(ferry) { $1 })
        let content = store.worldWidgetMapContent(in: viewport, worn: worn)
        #expect(content.worn.contains { $0.kind == .rail && $0.level == .two })
        #expect(content.worn.contains { $0.kind == .ferry && $0.level == .one })
        #expect(!content.worn.contains { $0.isRoad })
        #expect(content.worn.first?.kind == .rail, "most worn first")
        let railOnly = store.worldWidgetMapStamp(worn: Self.drawing(rail))
        let both = store.worldWidgetMapStamp(worn: worn)
        #expect(railOnly != both && both != store.worldWidgetMapStamp(), "a wake added moves the stamp")
        let busier = Self.drawing(rail.merging(Self.ways(.ferry, Self.line(from: Self.here.offset(east: 0, north: -80), east: 150), count: 10)) { $1 })
        #expect(store.worldWidgetMapStamp(worn: busier) != both, "a wake one level up moves it")
    }

    // MARK: The switch

    /// With "Show worn paths" off, the request carries no counter and the model draws no railway or wake; Your world's
    /// counter is empty too.
    @Test func theSwitchHidesRailsAndWakes() async throws {
        let defaults = try #require(UserDefaults(suiteName: "WornTransitDrawingTests.\(UUID().uuidString)"))
        WorldMapPreferences.setShowWornPaths(false, in: defaults)
        let store = makeTestStore()
        let request = store.wornWaysRequest(trails: [], trailStamp: 0, defaults: defaults)
        #expect(!request.shows && request.roads.isEmpty)
        #expect(store.wornYourWorldTallies(defaults: defaults).isEmpty)
        // Even handed a counter, a request that doesn't show draws nothing.
        var hidden = request
        hidden.roads = Self.ways(.rail, Self.line(east: 300), count: 30).merging(Self.ways(.ferry, Self.line(east: 300, north: 200), count: 30)) { $1 }
        let model = WornWaysModel()
        model.update(hidden, store: store)
        for _ in 0..<200 where model.drawing.generation == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(model.drawing.generation > 0)
        #expect(model.drawing.rails.isEmpty && model.drawing.ferries.isEmpty && model.drawing.isEmpty)
        // On, the same counter draws.
        hidden.shows = true
        let generation = model.drawing.generation
        model.update(hidden, store: store)
        for _ in 0..<200 where model.drawing.generation == generation { try await Task.sleep(for: .milliseconds(10)) }
        #expect(!model.drawing.rails.isEmpty && !model.drawing.ferries.isEmpty)
    }

    // MARK: Painting

    /// Every level of railway and wake paints, plain and under Increase Contrast, light and dark, at Home's unit and
    /// zoomed out (a smoke test: the strokes run without trapping).
    @Test func everyLevelPaints() {
        let ways = Self.ways(.rail, Self.line(east: 300), count: 30).merging(Self.ways(.ferry, Self.line(east: 300, north: 120), count: 3)) { $1 }
        let drawing = Self.drawing(ways)
        let size = CGSize(width: 390, height: 600)
        let viewport = MapViewport.around(Self.here, heightMetres: 900, size: size)
        for dark in [false, true] {
            for highContrast in [false, true] {
                let renderer = ImageRenderer(content: Canvas { context, canvasSize in
                    WornWaysPainter.draw(drawing, in: &context, size: canvasSize, viewport: viewport, dark: dark, highContrast: highContrast)
                    var path = Path()
                    path.move(to: CGPoint(x: 10, y: 10))
                    path.addLine(to: CGPoint(x: 200, y: 40))
                    for level in WornLevel.allCases {
                        WornWaysPainter.strokeRail(path, level: level, unit: 2, reduced: level == .one, dark: dark,
                                                   highContrast: highContrast, in: &context)
                        WornWaysPainter.strokeWake(path, level: level, unit: 2, reduced: level == .two, dark: dark,
                                                   highContrast: highContrast, in: &context)
                    }
                }.frame(width: size.width, height: size.height))
                #expect(renderer.uiImage != nil)
            }
        }
    }
}
