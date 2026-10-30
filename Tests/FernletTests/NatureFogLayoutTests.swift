import CoreGraphics
import QuartzCore
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// The nature fog's rules on the map (World-Nature-Fog-Spec): trees stand only while all wild and lift whole,
/// hexes next to the uncovered map are plain, the reduced detail under 13 pt and in the widget's picture,
/// the atlas budget, tiles redrawn only where a hex clears, and Reduce Motion.
@MainActor
struct NatureFogLayoutTests {
    static let full = NatureFogScale(radius: 19, reduced: false)
    static let light = NatureFogPalette(dark: false, highContrast: false)
    /// A patch of real Portland-area cells (the mockup's sample rows), all wild.
    static let patch: [HexCell] = (761_200..<761_240).flatMap { row in (523_400..<523_440).map { NatureFogRules.cell(col: $0, row: row) } }

    private func grower(_ clearing: NatureFogClearing = NatureFogClearing(), scale: NatureFogScale? = nil) -> NatureFogGrower {
        NatureFogGrower(scale: scale ?? Self.full, clearing: clearing, atlas: NatureFogAtlas(palette: Self.light))
    }

    /// The first tree that stands in the all-wild patch.
    private func standingTree(in field: NatureFogGrower) -> NatureTreePlan? {
        Self.patch.lazy.compactMap { field.treePlan($0) }.first { field.stands($0) }
    }

    @Test func aTreeStandsOnlyWhileAllItsHexesAreWildAndLiftsWhole() throws {
        let wild = grower()
        let plan = try #require(standingTree(in: wild))
        let at = NatureFogRules.offset(of: plan.anchor)
        let twoUp = NatureFogRules.cell(col: at.col, row: at.row - 2)
        #expect(!MercatorHexGrid.neighbours(of: plan.anchor).contains(twoUp))
        let cleared = grower(NatureFogClearing(lifted: [twoUp]))
        #expect(cleared.treePlan(plan.anchor) != nil, "the tree's own hex is still deep in the wild")
        #expect(cleared.treePlan(plan.anchor).map(cleared.stands) == false, "clearing a hex under the canopy lifts the whole tree")
        let far = NatureFogRules.cell(col: 523_420, row: 761_100)
        let distant = grower(NatureFogClearing(lifted: [far]))
        #expect(distant.treePlan(plan.anchor).map(distant.stands) == true, "a far-off clearing leaves it standing")
        let area = CGRect(origin: Self.full.centre(of: plan.anchor), size: .zero).insetBy(dx: -128, dy: -128)
        #expect(wild.layout(in: area).trees.contains { $0.anchor == plan.anchor })
        #expect(!cleared.layout(in: area).trees.contains { $0.anchor == plan.anchor })
    }

    @Test func noNewTreeEverAppears() {
        let lifted = Set(Self.patch.enumerated().filter { $0.offset % 37 == 0 }.map(\.element))
        let wild = grower(), walked = grower(NatureFogClearing(lifted: lifted))
        for anchor in Self.patch {
            guard let plan = walked.treePlan(anchor), walked.stands(plan) else { continue }
            #expect(wild.treePlan(anchor).map(wild.stands) == true, "\(anchor) stands only where the wild one did")
        }
    }

    @Test func hexesNextToTheUncoveredMapArePlainAndLightest() {
        let cleared = NatureFogRules.cell(col: 523_420, row: 761_220)
        let field = grower(NatureFogClearing(lifted: [cleared]))
        let centre = Self.full.centre(of: cleared)
        let layout = field.layout(in: CGRect(origin: centre, size: .zero).insetBy(dx: -100, dy: -100))
        #expect(!layout.hexes.contains { $0.centre == centre }, "the cleared hex shows the map")
        for side in MercatorHexGrid.neighbours(of: cleared) {
            let at = Self.full.centre(of: side)
            #expect(field.state(side) == .wild(.edge))
            #expect(layout.hexes.first { $0.centre == at }?.paint == .edge)
            #expect(!layout.pieces.contains { $0.sortX == at.x && ($0.sortY == at.y || $0.sortY == at.y + 0.2) }, "nothing grows on an edge")
            #expect(!layout.specks.contains { hypot($0.rect.midX - at.x, $0.rect.midY - at.y) < Self.full.radius * 0.8 })
        }
    }

    @Test func piecesSortTopToBottomAndSpanningOnesDrawInBothTiles() {
        let field = grower()
        let origin = Self.full.centre(of: NatureFogRules.cell(col: 523_410, row: 761_210))
        let left = CGRect(x: origin.x, y: origin.y, width: 256, height: 256)
        let right = left.offsetBy(dx: 256, dy: 0)
        let a = field.layout(in: left), b = field.layout(in: right)
        let sorted = a.pieces.map { [$0.sortY, $0.sortX] }
        #expect(sorted == sorted.sorted { $0[0] != $1[0] ? $0[0] < $1[0] : $0[1] < $1[1] })
        let seam = a.pieces.filter { $0.frame.maxX > right.minX }
        #expect(!seam.isEmpty)
        for piece in seam {
            #expect(b.pieces.contains { $0.sprite == piece.sprite && $0.frame == piece.frame }, "a piece across the seam draws in both tiles")
        }
        let again = grower().layout(in: left)
        #expect(again.pieces.map(\.frame) == a.pieces.map(\.frame), "the same hexes grow the same pieces")
    }

    @Test func reducedDetailUnder13PointsAndInTheWidgetsPicture() {
        #expect(NatureFogScale.tiles(forScreenRadius: 12.9)?.reduced == true)
        #expect(NatureFogScale.tiles(forScreenRadius: 13)?.reduced == false)
        #expect(NatureFogScale.tiles(forScreenRadius: 19)?.radius == 19)
        #expect(NatureFogScale.tiles(forScreenRadius: 1.5) == nil)
        let far = NatureFogScale(radius: 9.5, reduced: true)
        #expect(far.unit == 1.6)
        let origin = far.centre(of: NatureFogRules.cell(col: 523_400, row: 761_200))
        let layout = grower(scale: far).layout(in: CGRect(x: origin.x, y: origin.y, width: 256, height: 256))
        #expect(layout.specks.isEmpty, "no specks")
        #expect(!layout.pieces.isEmpty && layout.pieces.allSatisfy { piece in
            if case .tree = piece.sprite { return true }
            if case .pine = piece.sprite { return true }
            return false
        }, "no tufts, flowers or boulders; trees are still drawn")
        #expect(layout.waterMarks.allSatisfy { NaturePaint.petals.contains($0.paint) && $0.rect.width == far.unit }, "flowers are single pixels; ponds have no ripples")
        let viewport = MapViewport.around(GeoPoint(45.5205, -122.6255), heightMetres: 382 * 1.1, size: CGSize(width: 364, height: 382))
        let picture = NatureFogPicturePainter(viewport: viewport, clearing: NatureFogClearing(), palette: Self.light)
        let pictureScale = picture.scale(in: CGSize(width: 364, height: 382))
        #expect(pictureScale?.reduced == true && (pictureScale?.radius ?? 0) > 13, "the widget always draws reduced detail")
    }

    @Test func theAtlasIsUnder40KB() {
        let atlas = NatureFogAtlas(palette: Self.light)
        #expect(NatureFogAtlas.fullDetailSet.count == 28)
        #expect(NatureFogAtlas.fullDetailSet.allSatisfy { atlas.sprite($0) != nil })
        #expect(atlas.fullDetailBytes > 10_000 && atlas.fullDetailBytes < 40_960, "atlas \(atlas.fullDetailBytes) bytes")
    }

    @Test func clearingAHexRedrawsOnlyTheTilesItReaches() async {
        let book = NatureFogTileBook(scale: Self.full, palette: Self.light, clearing: NatureFogClearing(), pixelScale: 1)
        let cell = NatureFogRules.cell(col: 523_420, row: 761_220)
        let home = NatureFogTileBook.key(at: Self.full.centre(of: cell))
        let far = NatureTileKey(x: home.x + 4, y: home.y + 1)
        let before = await book.tile(home)
        #expect(before.ground != nil)
        #expect(await book.tile(far).key == far)
        let change = book.change(to: NatureFogClearing(lifted: [cell]))
        #expect(!change.reset && change.dirty.contains(home) && !change.dirty.contains(far))
        #expect(change.cleared == [cell])
        #expect(book.cachedKeys == [far], "only the tile the hex reaches is dropped")
        #expect(NatureFogTileBook.keys(touching: [cell], scale: Self.full).allSatisfy { abs($0.x - home.x) <= 1 && abs($0.y - home.y) <= 1 })
        #expect(book.change(to: NatureFogClearing(lifted: [cell])).dirty.isEmpty, "the same clearing redraws nothing")
    }

    /// A Home-sized map at today's zoom with a cleared disc round the park's middle.
    private func scene(_ lifted: Set<HexCell>, reduceMotion: Bool) -> NatureFogScene {
        let size = CGSize(width: 402, height: 874)
        let viewport = MapViewport.around(GeoPoint(45.5205, -122.6255), heightMetres: 1_700 * 0.57, size: size)
        return NatureFogScene(viewport: viewport, clearing: NatureFogClearing(lifted: lifted), palette: Self.light,
                              motion: NatureFogMotion(reduceMotion: reduceMotion))
    }

    private func clearings() -> (start: Set<HexCell>, next: Set<HexCell>) {
        let middle = GeoPoint(45.5205, -122.6255)
        let start = Set(MercatorHexGrid.cells(around: middle, within: 60))
        let next = start.union(MercatorHexGrid.cells(around: middle.offset(east: 70, north: 0), within: 25))
        return (start, next)
    }

    /// Puts `view` in a window, as on the map: outside one, Core Animation drops its animations once they're
    /// committed, and the view's own settle timer may commit the sway while the test waits for tiles.
    private func hosted(_ view: UIView) -> UIWindow? {
        guard let scene = UIApplication.shared.connectedScenes.lazy.compactMap({ $0 as? UIWindowScene }).first else { return nil }
        let window = UIWindow(windowScene: scene)
        window.frame = view.frame
        window.addSubview(view)
        window.isHidden = false
        return window
    }

    @Test func grassSwaysWhenTheMapIsStillAndBladesScatterAsAHexClears() async throws {
        let view = NatureFogMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let window = try #require(hosted(view))
        defer { window.isHidden = true }
        let (start, next) = clearings()
        view.show(scene(start, reduceMotion: false))
        #expect(!view.isSwaying, "the map just moved: no sway yet")
        await view.finishDrawing()
        #expect(view.shownTileCount > 0 && view.waitingTileCount == 0)
        view.settle(now: CACurrentMediaTime() + 60)
        #expect(view.isSwaying && view.swayingSpriteCount > 0)
        var fading = 0, swaying = 0
        view.onTileArrived = { [unowned view] in
            fading = max(fading, view.fadingTileCount)
            swaying = max(swaying, view.swayingSpriteCount)
        }
        view.show(scene(next, reduceMotion: false))
        #expect(view.scatteringCount > 0, "its blades scatter")
        await view.finishDrawing()
        #expect(fading > 0, "the cleared grass fades as its new picture arrives")
        #expect(swaying > 0, "the map didn't move: the grass keeps swaying")
    }

    @Test func reduceMotionOnlyFades() async {
        let view = NatureFogMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let (start, next) = clearings()
        view.show(scene(start, reduceMotion: true))
        await view.finishDrawing()
        view.settle(now: CACurrentMediaTime() + 60)
        #expect(!view.isSwaying && view.swayingSpriteCount == 0, "no sway")
        var fading = 0
        view.onTileArrived = { [unowned view] in fading = max(fading, view.fadingTileCount) }
        view.show(scene(next, reduceMotion: true))
        await view.finishDrawing()
        #expect(fading > 0, "a clearing hex simply fades out")
        #expect(view.scatteringCount == 0, "no scatter")
    }

    @Test func swayTimingMatchesTheApprovedMotion() {
        let sway = NatureFogMotion.sway(group: 2)
        #expect(sway.duration * 2 == 3.4 && sway.autoreverses && sway.repeatCount == .infinity)
        #expect(sway.toValue as? Double == 1)
        #expect(NatureFogMotion.staggers == [0, 1.1, 2.3] && NatureFogMotion.clearDuration == 0.4)
        #expect(NatureFogMotion.flights.count == 8)
    }
}
