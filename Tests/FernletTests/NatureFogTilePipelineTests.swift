import CoreGraphics
import QuartzCore
import Testing
import WorldMapStore
@testable import Fernlet

/// The fog's tiles drawn off the main thread (owner's go 2026-10-29, map-perf P1): the screen never waits on
/// a tile, a ring of tiles round the screen is drawn ahead (further the way the map moves), the cache keeps
/// what's nearest the middle, a tile drawn from a clearing that changed meanwhile is thrown away, fog coming
/// back blanks the tiles it reaches at once, and a zoom step keeps the old scale's tiles until the new ones are in.
@MainActor
struct NatureFogTilePipelineTests {
    static let full = NatureFogScale(radius: 19, reduced: false)
    static let light = NatureFogPalette(dark: false, highContrast: false)
    static let size = CGSize(width: 402, height: 874)
    static let park = GeoPoint(45.5205, -122.6255)

    private func scene(heightMetres: Double = 1_700 * 0.57) -> NatureFogScene {
        let viewport = MapViewport.around(Self.park, heightMetres: heightMetres, size: Self.size)
        return NatureFogScene(viewport: viewport, clearing: NatureFogClearing(lifted: Set(MercatorHexGrid.cells(around: Self.park, within: 60))),
                              palette: Self.light, motion: NatureFogMotion(reduceMotion: true))
    }

    @Test func theRingPutsTheScreenFirstAndReachesAheadOfAMovingMap() {
        let low = NatureTileKey(x: 0, y: 0), high = NatureTileKey(x: 2, y: 3), centre = CGPoint(x: 1.5, y: 2)
        let still = NatureFogRing.keys(low: low, high: high, centre: centre, motion: .zero, limit: 100)
        #expect(still.count == 5 * 6, "the screen's 3 × 4 and a ring one tile wide")
        #expect(still.prefix(12).allSatisfy { (0...2).contains($0.x) && (0...3).contains($0.y) }, "the screen's tiles come first")
        #expect(still.first.map { NatureFogRing.distance($0, centre) } ?? 9 <= 0.75, "nearest the middle first")
        let east = NatureFogRing.keys(low: low, high: high, centre: centre, motion: CGVector(dx: 0.5, dy: 0), limit: 100)
        #expect(east.count == 7 * 6)
        #expect(east.contains(NatureTileKey(x: 5, y: 2)) && !east.contains(NatureTileKey(x: -2, y: 2)), "reaching ahead, not behind")
        #expect(east[12].x >= 3, "the first ring tile is the one ahead")
        #expect(NatureFogRing.keys(low: low, high: high, centre: centre, motion: .zero, limit: 10).count == 10)
        #expect(NatureFogRing.direction(0.01) == 0 && NatureFogRing.direction(-0.3) == -1 && NatureFogRing.direction(.nan) == 0)
    }

    @Test func theScreenNeverWaitsOnATileAndTheRingIsDrawnAhead() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        #expect(view.shownTileCount > 0)
        #expect(view.waitingTileCount == view.shownTileCount, "nothing was drawn on the main thread: the fog's colour stands in")
        await view.finishDrawing()
        #expect(view.waitingTileCount == 0, "every tile on screen arrived")
        #expect(view.cachedTileCount > view.shownTileCount, "and the ring round the screen is ready too")
        #expect(view.cachedTileCount <= NatureFogTileBook.cacheLimit)
    }

    @Test func aTileDrawnFromAnOutdatedClearingIsThrownAwayAndDrawnAgain() async {
        let book = NatureFogTileBook(scale: Self.full, palette: Self.light, clearing: NatureFogClearing(), pixelScale: 1)
        var arrivals: [NatureTileKey] = []
        book.onReady = { arrivals.append($0.key) }
        let home = NatureTileKey(x: 7_000, y: 9_000)
        let area = NatureFogTileBook.area(of: home).insetBy(dx: -80, dy: -80)
        let grower = NatureFogGrower(scale: Self.full, clearing: NatureFogClearing(), atlas: NatureFogAtlas(palette: Self.light))
        let everything = Set(grower.cells(in: area))
        #expect(!everything.isEmpty && everything.count <= NatureFogTileBook.resetThreshold)
        book.want([home])
        #expect(book.isDrawing && book.cached(home) == nil)
        let change = book.change(to: NatureFogClearing(lifted: everything))
        #expect(!change.reset && change.dirty.contains(home), "the tile on its way counts as reached")
        await book.finishDrawing()
        #expect(arrivals == [home], "the outdated picture never reached the screen")
        #expect(book.cached(home).map { $0.ground == nil } == true, "the kept tile is the cleared one")
    }

    @Test func theCacheKeepsTheTilesNearestTheMiddleOfTheScreen() async {
        let book = NatureFogTileBook(scale: Self.full, palette: Self.light, clearing: NatureFogClearing(), pixelScale: 1)
        let row = (0..<(NatureFogTileBook.cacheLimit + 8)).map { NatureTileKey(x: $0, y: 0) }
        for key in row { _ = await book.tile(key) }
        let far = NatureTileKey(x: row.count - 1, y: 0)
        book.evict(around: CGPoint(x: 0.5, y: 0.5), keeping: [far])
        #expect(book.cachedKeys.count == NatureFogTileBook.cacheLimit)
        #expect(book.cachedKeys.contains(NatureTileKey(x: 0, y: 0)), "the middle's tile stays")
        #expect(book.cachedKeys.contains(far), "a kept tile is never evicted")
        #expect(!book.cachedKeys.contains(NatureTileKey(x: row.count - 2, y: 0)), "the farthest spare one goes")
    }

    @Test func fogComingBackBlanksTheReachedTilesAtOnce() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        let history = Set(MercatorHexGrid.cells(around: Self.park, within: 60))
        func scene(_ lifted: Set<HexCell>) -> NatureFogScene {
            NatureFogScene(viewport: MapViewport.around(Self.park, heightMetres: 1_700 * 0.57, size: Self.size),
                           clearing: NatureFogClearing(lifted: lifted), palette: Self.light, motion: NatureFogMotion(reduceMotion: true))
        }
        view.show(scene(history))
        await view.finishDrawing()
        #expect(view.waitingTileCount == 0)
        #expect(history.count <= NatureFogTileBook.resetThreshold, "a small change, not a reset")
        view.show(scene([]))
        #expect(view.waitingTileCount > 0, "a decoy's empty map never shows the history while its tiles redraw")
        await view.finishDrawing()
        #expect(view.waitingTileCount == 0)
    }

    @Test func aZoomStepKeepsTheOldTilesUntilTheNewOnesAreIn() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        let before = view.shownTileCount
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.5))
        #expect(view.outgoingTileCount == before, "the old scale's tiles stay on screen")
        #expect(view.waitingTileCount > 0)
        await view.finishDrawing()
        #expect(view.waitingTileCount == 0 && view.outgoingTileCount == 0, "they go once the new scale's are in")
    }
}
