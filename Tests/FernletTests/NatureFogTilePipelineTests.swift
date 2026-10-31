import CoreGraphics
import Foundation
import QuartzCore
import Testing
import WorldMapStore
@testable import Fernlet

/// The fog's tiles drawn off the main thread (owner's go 2026-10-29, map-perf P1): the screen never waits on
/// a tile, a ring of tiles round the screen is drawn ahead (further the way the map moves), the cache keeps
/// what's nearest the middle, a tile drawn from a clearing that changed meanwhile is thrown away, fog coming
/// back blanks the tiles it reaches at once, a zoom step keeps the old scale's tiles until the new ones are in,
/// zooming back finds the scale it left still drawn (P2), and a glide draws its end first (P3).
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

    @Test func zoomingBackFindsTheScaleItLeftStillDrawn() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        let first = view.tileScaleRadius
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.5))
        view.settle(now: CACurrentMediaTime() + 60)
        await view.finishDrawing()
        #expect(first.map { view.spareScales[$0] != nil } == true, "the scale it left is kept")
        #expect(view.spareTileCounts.count <= NatureFogMapView.spareBookLimit
                && view.spareTileCounts.allSatisfy { $0 <= NatureFogTileBook.cacheLimit + NatureFogTileBook.painterCount })
        view.show(scene())
        view.settle(now: CACurrentMediaTime() + 60)
        #expect(view.waitingTileCount == 0, "every tile on screen is there at once")
        #expect(view.outgoingTileCount == 0, "so nothing needs holding over")
    }

    /// Perf review 2026-10-31: the map going behind a panel, sheet or tab gives back every tile only a zoom or a
    /// pan would use — the spare scales, the outgoing tiles and the ring — and keeps what the screen shows.
    @Test func goingBehindGivesBackEverythingOffTheScreen() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.5))
        view.settle(now: CACurrentMediaTime() + 60)
        await view.finishDrawing()
        #expect(!view.spareTileCounts.isEmpty, "the zoom left a spare scale")
        #expect(view.cachedTileCount > view.shownTileCount, "and the ring round the screen is drawn")
        let shown = view.shownTileCount
        var behind = scene(heightMetres: 1_700 * 0.57 / 1.5)
        behind.isFrontmost = false
        view.show(behind)
        #expect(view.spareTileCounts.isEmpty && view.outgoingTileCount == 0)
        #expect(view.cachedTileCount <= view.shownTileCount && view.shownTileCount == shown,
                "only the screen's tiles stay, so nothing flashes")
        var moved = scene(heightMetres: 1_700 * 0.57 / 1.5 * 1.01)
        moved.isFrontmost = false
        view.show(moved)
        await view.finishDrawing()
        #expect(view.cachedTileCount <= view.shownTileCount + NatureFogTileBook.painterCount,
                "a reading moving the hidden map draws the screen, never the ring back")
    }

    @Test func aGlideDrawsItsEndFirst() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        let away = Self.park.offset(east: 15_000, north: 0)
        func scene(at point: GeoPoint, camera: GeoPoint, revision: Int) -> NatureFogScene {
            NatureFogScene(viewport: MapViewport.around(point, heightMetres: 1_700 * PlainBaseMap.heightPerDistance, size: Self.size),
                           clearing: NatureFogClearing(lifted: Set(MercatorHexGrid.cells(around: Self.park, within: 60))),
                           palette: Self.light, motion: NatureFogMotion(reduceMotion: true),
                           camera: WorldCamera(center: camera, distance: 1_700, revision: revision))
        }
        view.show(scene(at: Self.park, camera: Self.park, revision: 1))
        await view.finishDrawing()
        view.show(scene(at: Self.park, camera: away, revision: 2))
        await view.finishDrawing()
        view.show(scene(at: away, camera: away, revision: 2))
        #expect(view.shownTileCount > 0)
        #expect(view.waitingTileCount == 0, "Back to Sprout's end was drawn before the map got there")
    }

    @Test func followingAndPanningAreNoGlide() {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        let height = 1_700 * PlainBaseMap.heightPerDistance
        func scene(at point: GeoPoint, camera: GeoPoint, revision: Int) -> NatureFogScene {
            NatureFogScene(viewport: MapViewport.around(point, heightMetres: height, size: Self.size), clearing: NatureFogClearing(),
                           palette: Self.light, motion: NatureFogMotion(reduceMotion: true),
                           camera: WorldCamera(center: camera, distance: 1_700, revision: revision))
        }
        view.show(scene(at: Self.park, camera: Self.park, revision: 1))
        #expect(!view.isGliding)
        let step = Self.park.offset(east: 30, north: 0)
        view.show(scene(at: Self.park, camera: step, revision: 2))
        #expect(!view.isGliding, "following moves the camera a little at a time")
        let away = Self.park.offset(east: 3_000, north: 0)
        view.show(scene(at: Self.park, camera: away, revision: 3))
        #expect(view.isGliding, "Back to Sprout from three kilometres off glides")
        view.show(scene(at: Self.park.offset(east: -2_000, north: 0), camera: away, revision: 3))
        #expect(!view.isGliding, "the person took the map the other way: the glide is over")
    }

    /// The owner's pinch on the phone (2026-10-30): in from today's zoom to the nearest and back out to the
    /// farthest, a frame at a time, the painters getting only a moment between frames.
    @Test func aPinchNeverShowsBareMapWhereTheFogBelongs() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        view.settle(now: CACurrentMediaTime() + 60)
        let today = 1_700 * 0.57, nearest = 300 * 0.57, farthest = 7_000 * 0.57
        let inward = (0...45).map { today * pow(nearest / today, Double($0) / 45) }
        let outward = (0...90).map { nearest * pow(farthest / nearest, Double($0) / 90) }
        var bare = 0.0, placeholder = 0.0
        for (frame, height) in (inward + outward).enumerated() {
            view.show(scene(heightMetres: height))
            bare = max(bare, view.bareScreenShare)
            placeholder = max(placeholder, view.placeholderScreenShare)
            if frame % 3 == 0 { await Task.yield() }
        }
        #expect(bare == 0, "bare map showed on \(Int(bare * 100)) % of the screen mid-pinch (fog colour peaked at \(Int(placeholder * 100)) %)")
        // Settles first, so the scale is final: under load the real settle can otherwise land mid-wait and
        // snap a stepped scale to the ideal one.
        view.settle(now: CACurrentMediaTime() + 60)
        await view.finishDrawing()
        #expect(view.bareScreenShare == 0 && view.waitingTileCount == 0)
    }

    @Test func newGroundShowsWildFogWhileItsTilesDraw() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        let far = MapViewport.around(Self.park.offset(east: 20_000, north: 0), heightMetres: 1_700 * 0.57, size: Self.size)
        view.show(NatureFogScene(viewport: far, clearing: scene().clearing, palette: Self.light, motion: NatureFogMotion(reduceMotion: true)))
        #expect(view.waitingTileCount > 0)
        #expect(view.texturedPlaceholderCount == view.waitingTileCount, "the ground a fling reaches looks like fog, not a flat band")
        await view.finishDrawing()
        #expect(view.waitingTileCount == 0 && view.bareScreenShare == 0)
    }

    @Test func aZoomOutHoldsTheDrawnRingOverItsEdges() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        view.settle(now: CACurrentMediaTime() + 60)
        let before = view.shownTileCount
        view.show(scene(heightMetres: 1_700 * 0.57 * 2.2))
        #expect(view.outgoingTileCount > before, "the ring round the old screen comes along, covering the new edges")
    }

    @Test func aStillMapDrawsTheScalesEitherSideAhead() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        view.settle(now: CACurrentMediaTime() + 60)
        await view.finishDrawingNeighbours()
        let here = view.tileScaleRadius ?? 0
        let up = here * 2.0.squareRoot(), down = here / 2.0.squareRoot()
        #expect(view.spareScales.keys.contains { abs($0 - up) < 0.001 } && view.spareScales.keys.contains { abs($0 - down) < 0.001 },
                "a half octave up and down are drawn")
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.8))
        #expect(view.tileScaleRadius.map { abs($0 - up) < 0.001 } == true, "the pinch steps to the scale drawn ahead")
        #expect(view.waitingTileCount == 0, "so every tile on screen is there at once")
    }

    @Test func aWaitingTileOverUncoveredGroundShowsTheMapNotFog() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        let home = NatureFogClearing(uncovered: Set(MercatorHexGrid.disc(around: Self.park, radius: 1_000)))
        func scene(east: Double) -> NatureFogScene {
            NatureFogScene(viewport: MapViewport.around(Self.park.offset(east: east, north: 0), heightMetres: 1_700 * 0.57, size: Self.size),
                           clearing: home, palette: Self.light, motion: NatureFogMotion(reduceMotion: true))
        }
        // A band of home circles wide enough that the tiles past the drawn ring still lie on uncovered ground.
        let band = NatureFogClearing(uncovered: Set([0.0, 800, 1_600].flatMap {
            MercatorHexGrid.disc(around: Self.park.offset(east: $0, north: 0), radius: 1_000)
        }))
        func banded(east: Double) -> NatureFogScene {
            NatureFogScene(viewport: MapViewport.around(Self.park.offset(east: east, north: 0), heightMetres: 1_700 * 0.57, size: Self.size),
                           clearing: band, palette: Self.light, motion: NatureFogMotion(reduceMotion: true))
        }
        view.show(banded(east: 0))
        await view.finishDrawing()
        view.show(banded(east: 650))
        #expect(view.waitingTileCount > 0)
        #expect(view.mapShowingPlaceholderCount == view.waitingTileCount,
                "on the person's own ground a tile still drawing shows the map, never wild fog")
        await view.finishDrawing()
        #expect(view.waitingTileCount == 0)
        let edge = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        edge.show(scene(east: 1_000))
        #expect(edge.maskedPlaceholderCount > 0, "a tile across the circle's edge shows fog only on its fogged hexes")
        await edge.finishDrawing()
        #expect(edge.waitingTileCount == 0 && edge.maskedPlaceholderCount == 0)
    }

    @Test func aPinchHoldsItsScaleUntilTheMapSettles() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        view.settle(now: CACurrentMediaTime() + 60)
        let today = view.tileScaleRadius
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.2))
        #expect(view.tileScaleRadius == today && view.outgoingTileCount == 0, "mid-pinch the tiles stretch rather than start again")
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.4))
        #expect(view.tileScaleRadius == today, "still within the hold")
        let fits = NatureFogScale.tiles(forScreenRadius: MercatorHexGrid.radius * scene(heightMetres: 1_700 * 0.57 / 1.4).viewport.pointsPerUnit(in: Self.size))?.radius
        #expect(fits != today)
        view.settle(now: CACurrentMediaTime() + 60)
        #expect(view.tileScaleRadius == fits, "once the map sits still the fog takes the scale that fits")
        view.show(scene(heightMetres: 1_700 * 0.57 / 3.2))
        #expect(view.tileScaleRadius != fits, "past the hold the fog switches scale even mid-pinch")
        let ideal = NatureFogScale.tiles(forScreenRadius: MercatorHexGrid.radius * scene(heightMetres: 1_700 * 0.57 / 3.2).viewport.pointsPerUnit(in: Self.size))?.radius
        #expect(view.tileScaleRadius.flatMap { held in ideal.map { held < $0 } } == true,
                "it steps a half octave at a time, to a scale the still map drew ahead, not straight to the ideal")
    }

    @Test func aZoomStepKeepsTheOldTilesUntilTheNewOnesAreIn() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        let before = view.shownTileCount
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.5))
        view.settle(now: CACurrentMediaTime() + 60)
        #expect(view.outgoingTileCount >= before, "the old scale's tiles stay on screen, its drawn ring with them")
        #expect(view.waitingTileCount > 0)
        await view.finishDrawing()
        #expect(view.waitingTileCount == 0 && view.outgoingTileCount == 0, "they go once the new scale's are in")
    }

    @Test func fogComingBackMidZoomDropsTheOldTilesAtOnce() async {
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.size))
        view.show(scene())
        await view.finishDrawing()
        view.show(scene(heightMetres: 1_700 * 0.57 / 1.5))
        view.settle(now: CACurrentMediaTime() + 60)
        #expect(view.outgoingTileCount > 0)
        let zoomed = MapViewport.around(Self.park, heightMetres: 1_700 * 0.57 / 1.5, size: Self.size)
        view.show(NatureFogScene(viewport: zoomed, clearing: NatureFogClearing(), palette: Self.light,
                                 motion: NatureFogMotion(reduceMotion: true)))
        #expect(view.outgoingTileCount == 0, "a decoy's map never shows the history through the old scale's tiles")
    }
}
