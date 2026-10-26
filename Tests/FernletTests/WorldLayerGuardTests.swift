import CoreGraphics
import FernletFoundation
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Issue desk W-20 ("Ignoring bogus layer size (13114805, 4378554)"): no map layer is handed a frame that is
/// not finite or absurdly large, a stretch outside 0.25…4, or a viewport out of proportion with its view.
/// A refused frame is dropped (the layer keeps its last good one) and writes one audit line naming the call
/// site only; the fog's pieces are culled to their tile.
@MainActor
struct WorldLayerGuardTests {
    private static let phone = CGSize(width: 402, height: 874)

    @Test func aNormalFramePasses() {
        #expect(WorldLayerGuard.accepts(CGRect(x: -40, y: 300, width: 256 * 1.19, height: 256 * 1.19), in: Self.phone))
        #expect(WorldLayerGuard.accepts(CGRect(x: 0, y: 0, width: 402, height: 874), in: Self.phone))
        #expect(WorldLayerGuard.accepts(stretchX: 0.84, stretchY: 1.19))
    }

    @Test func aNonFiniteOrHugeFrameIsRejected() {
        #expect(!WorldLayerGuard.accepts(CGRect(x: CGFloat.nan, y: 0, width: 256, height: 256), in: Self.phone))
        #expect(!WorldLayerGuard.accepts(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 256), in: Self.phone))
        #expect(!WorldLayerGuard.accepts(CGRect(x: 0, y: 0, width: 13_114_805, height: 4_378_554), in: Self.phone),
                "the phone's bogus size")
        #expect(!WorldLayerGuard.accepts(CGRect(x: 13_114_805, y: 4_378_554, width: 256, height: 256), in: Self.phone),
                "a tile placed in global points, not screen points")
        #expect(!WorldLayerGuard.accepts(CGRect(x: 0, y: 0, width: 256, height: 256), in: .zero), "no view yet")
        #expect(!WorldLayerGuard.accepts(stretchX: 1, stretchY: 5))
        #expect(!WorldLayerGuard.accepts(stretchX: 0.2, stretchY: 1))
        #expect(!WorldLayerGuard.accepts(stretchX: .nan, stretchY: 1))
    }

    @Test func aViewportPassesOnlyInProportionWithItsView() {
        let sound = MapViewport.around(GeoPoint(45.5205, -122.6255), heightMetres: 1_000, size: Self.phone)
        #expect(WorldLayerGuard.accepts(sound, in: Self.phone))
        let squashed = MapViewport(minX: sound.minX, minY: sound.minY, width: sound.width, height: sound.height / 50)
        #expect(!WorldLayerGuard.accepts(squashed, in: Self.phone))
    }

    @Test func aRejectionLogsOnceWithTheSiteOnlyUntilAFramePasses() {
        var lines: [(event: String, context: [String: String])] = []
        let rejections = WorldLayerRejections { event, context in lines.append((event, context)) }
        #expect(!rejections.note(false, at: .fogTile))
        #expect(!rejections.note(false, at: .fogTile))
        #expect(lines.count == 1, "a bad gesture logs one line, not one per frame")
        #expect(lines.first?.event == "worldMap.layer.sizeRejected")
        #expect(lines.first?.context == ["site": "natureFog.tile"], "the call site only, never a coordinate")
        #expect(rejections.note(true, at: .fogTile))
        rejections.note(false, at: .fogTile)
        rejections.note(false, at: .mapViewport)
        #expect(lines.map { $0.context["site"] } == ["natureFog.tile", "natureFog.tile", "appleMap.viewport"])
    }

    @Test func cullingKeepsOnlyThePiecesThatReachTheTile() {
        let key = NatureTileKey(x: 200_000, y: 90_000)
        let origin = NatureFogTileBook.area(of: key).origin
        func piece(_ x: Double, _ y: Double, _ side: Double = 12) -> NaturePiece {
            NaturePiece(sprite: .boulder, frame: CGRect(x: origin.x + x, y: origin.y + y, width: side, height: side),
                        sortY: 0, sortX: 0, swayGroup: nil)
        }
        let pieces = [piece(20, 30), piece(250, 250), piece(-10, 100), piece(300, 40), piece(40, -600),
                      NaturePiece(sprite: .boulder, frame: CGRect(x: CGFloat.nan, y: 0, width: 12, height: 12), sortY: 0, sortX: 0, swayGroup: nil),
                      NaturePiece(sprite: .boulder, frame: CGRect(x: 13_114_805, y: 4_378_554, width: 12, height: 12), sortY: 0, sortX: 0, swayGroup: nil)]
        let culled = NatureFogTileBook.visible(pieces, in: key)
        #expect(culled.kept.map { $0.frame.origin } == [CGPoint(x: 20, y: 30), CGPoint(x: 250, y: 250), CGPoint(x: -10, y: 100)],
                "inside or overlapping the edge stays, tile-local")
        #expect(culled.rejected == 2, "the non-finite and the global-points piece are refused, not drawn")
    }

    @Test func aSkewedViewportKeepsTheFogsLastGoodFrameAndLogsTheSite() {
        let capture = LayerAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let view = NatureFogMapView(frame: CGRect(origin: .zero, size: Self.phone))
        let middle = GeoPoint(45.5205, -122.6255)
        let sound = MapViewport.around(middle, heightMetres: 1_700 * 0.57, size: Self.phone)
        let clearing = NatureFogClearing(lifted: Set(MercatorHexGrid.cells(around: middle, within: 60)))
        func scene(_ viewport: MapViewport) -> NatureFogScene {
            NatureFogScene(viewport: viewport, clearing: clearing, palette: NatureFogPalette(dark: false, highContrast: false),
                           motion: NatureFogMotion(reduceMotion: true))
        }
        view.show(scene(sound))
        let shown = view.shownTileCount
        #expect(shown > 0)
        view.show(scene(MapViewport(minX: sound.minX, minY: sound.minY, width: sound.width, height: sound.height / 50)))
        #expect(view.shownTileCount == shown, "the skewed frame is dropped; the tiles stay where they were")
        #expect(capture.sites.contains("natureFog.stretch"))
        view.show(scene(sound))
        #expect(view.shownTileCount == shown)
    }
}

/// A local `FernletAuditLog` sink for the layer guard's line. The registry is process-wide and other suites
/// log into it at the same time, so the test only asks whether the site was named.
private final class LayerAuditCapture {
    private let lock = NSLock()
    private var named: [String] = []
    private var token: UUID?

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self, event == WorldLayerGuard.event, let site = context["site"] else { return }
            self.lock.lock()
            self.named.append(site)
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    var sites: [String] {
        lock.lock()
        defer { lock.unlock() }
        return named
    }
}
