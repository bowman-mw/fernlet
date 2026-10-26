import CoreGraphics
import FernletFoundation
import WorldMapStore

/// The check every frame and stretch Fernlet computes for a map layer passes before Core Animation sees it
/// (issue desk W-20: the phone logged "Ignoring bogus layer size (13114805, 4378554)", a size that fits the
/// nature fog's global points, not screen points).
///
/// A frame passes only when every number in it is finite, neither side is longer than ``viewMultiple``
/// times the view's longer side, and it lies within that much of the view. A tile's stretch passes only
/// within ``stretchRange``. A viewport passes only when its sides are in proportion with the map view's:
/// the map is north-up and flat, and Web Mercator has one scale both ways, so a skewed one is a bad report.
/// A frame that fails is never applied: the layer keeps its last good one until the next valid update.
nonisolated enum WorldLayerGuard {
    /// How many times the view's longer side a layer may span, or lie beyond the view.
    static let viewMultiple = 4.0
    /// How far a tile drawn at one size may be stretched on screen, either way.
    static let stretchRange = 0.25...4.0
    /// The audit line a rejection writes, with the call site only (``WorldLayerSite``).
    static let event = "worldMap.layer.sizeRejected"

    /// Whether `frame` is safe to hand a layer inside a view of `size`.
    static func accepts(_ frame: CGRect, in size: CGSize) -> Bool {
        let numbers = [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height, size.width, size.height]
        guard numbers.allSatisfy(\.isFinite), size.width > 0, size.height > 0,
              frame.size.width >= 0, frame.size.height >= 0 else { return false }
        let limit = viewMultiple * max(size.width, size.height)
        guard frame.size.width <= limit, frame.size.height <= limit else { return false }
        return frame.minX >= -limit && frame.minY >= -limit
            && frame.maxX <= size.width + limit && frame.maxY <= size.height + limit
    }

    /// Whether a tile may be stretched by `x` across and `y` down.
    static func accepts(stretchX x: Double, stretchY y: Double) -> Bool {
        x.isFinite && y.isFinite && stretchRange.contains(x) && stretchRange.contains(y)
    }

    /// Whether a usable `viewport` is in proportion with a map view of `size`.
    static func accepts(_ viewport: MapViewport, in size: CGSize) -> Bool {
        guard viewport.isUsable, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
            return false
        }
        let across = Double(size.width) / viewport.width, down = Double(size.height) / viewport.height
        return accepts(stretchX: 1, stretchY: down / across)
    }
}

/// Where a layer frame was rejected: the only thing the audit line carries, never a coordinate or a size.
nonisolated enum WorldLayerSite: String {
    /// The fog's tiles' stretch for the whole frame (from the viewport and the view's size).
    case fogStretch = "natureFog.stretch"
    /// One fog tile's frame on screen.
    case fogTile = "natureFog.tile"
    /// A growing piece's sprite inside its tile.
    case fogPiece = "natureFog.piece"
    /// The blades and leaves that scatter as a hex clears.
    case fogBlade = "natureFog.blade"
    /// The viewport Apple's map reported.
    case mapViewport = "appleMap.viewport"
}

/// Writes ``WorldLayerGuard/event`` once when a site starts rejecting frames, and again only after one of
/// that site's frames has passed, so a bad gesture logs one line, not one per frame. It remembers at most
/// one flag per ``WorldLayerSite``.
final class WorldLayerRejections {
    private var rejecting: Set<WorldLayerSite> = []
    private let log: (String, [String: String]) -> Void

    /// Rejections written through `log` (by default, the app's audit log).
    init(log: @escaping (String, [String: String]) -> Void = { FernletAuditLog.log($0, context: $1) }) {
        self.log = log
    }

    /// Notes whether `site`'s frame passed, and returns `accepted`.
    @discardableResult
    func note(_ accepted: Bool, at site: WorldLayerSite) -> Bool {
        guard !accepted else {
            rejecting.remove(site)
            return true
        }
        if rejecting.insert(site).inserted { log(WorldLayerGuard.event, ["site": site.rawValue]) }
        return false
    }
}
