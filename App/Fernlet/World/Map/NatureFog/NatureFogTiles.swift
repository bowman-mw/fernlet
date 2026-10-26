import CoreGraphics
import UIKit
import WorldMapStore

/// One 256-pt map tile at a ``NatureFogScale``: column `x`, row `y` in global points ÷ 256.
nonisolated struct NatureTileKey: Hashable {
    let x: Int
    let y: Int
}

/// A rendered tile: its ground picture, the pieces drawn over it as sprites (none in reduced detail, where they
/// are baked into the picture), and the trees that stand on it.
struct NatureFogTile {
    let key: NatureTileKey
    /// Ground and water (and, in reduced detail, the trees), drawn back to front.
    let ground: CGImage?
    /// The growing pieces in depth order, frames in global points.
    let pieces: [NaturePiece]
    let trees: [NatureStandingTree]
}

/// What a change of clearing did to the cached tiles.
struct NatureFogChange {
    /// The change was too big to animate (the first load, a decoy session): every tile was dropped.
    var reset = false
    /// The cached tiles a newly cleared or fogged hex reaches; they were dropped and redraw.
    var dirty: Set<NatureTileKey> = []
    /// Cells uncovered by the change (for the blades that scatter).
    var cleared: [HexCell] = []
}

/// The fog's cached map tiles at one scale and palette (spec "Performance", `nf-tiles`): ground and pieces
/// are drawn back to front into 256-pt tiles, and a tile is redrawn only when a hex in its reach clears.
///
/// A cleared hex can change everything within about 6 R of it: its neighbours become plain edges, a pond's
/// shore moves, and a tree whose wild ring it was in lifts whole — so ``keys(touching:scale:)`` dirties every
/// tile within 6 R.
final class NatureFogTileBook {
    /// A tile's side, in points.
    static let tileSize = 256.0
    /// A change of more cells than this redraws everything without animating.
    static let resetThreshold = 600
    /// The most tiles kept.
    static let cacheLimit = 40

    let scale: NatureFogScale
    let palette: NatureFogPalette
    let atlas: NatureFogAtlas
    private(set) var clearing: NatureFogClearing
    private var grower: NatureFogGrower
    private var tiles: [NatureTileKey: NatureFogTile] = [:]
    private let pixelScale: CGFloat

    /// A book drawing `clearing` at `scale` in `palette`, its pictures at `pixelScale` pixels a point.
    init(scale: NatureFogScale, palette: NatureFogPalette, clearing: NatureFogClearing, pixelScale: CGFloat) {
        self.scale = scale
        self.palette = palette
        self.clearing = clearing
        self.pixelScale = max(1, min(pixelScale, 3))
        atlas = NatureFogAtlas(palette: palette)
        grower = NatureFogGrower(scale: scale, clearing: clearing, atlas: atlas)
    }

    /// The tiles held now.
    var cachedKeys: Set<NatureTileKey> { Set(tiles.keys) }

    /// A tile's area in global points.
    static func area(of key: NatureTileKey) -> CGRect {
        CGRect(x: Double(key.x) * tileSize, y: Double(key.y) * tileSize, width: tileSize, height: tileSize)
    }

    /// The tile containing global point `point`.
    static func key(at point: CGPoint) -> NatureTileKey {
        NatureTileKey(x: Int((point.x / tileSize).rounded(.down)), y: Int((point.y / tileSize).rounded(.down)))
    }

    /// Every tile within 6 R of any of `cells` at `scale` (what clearing them can change).
    static func keys(touching cells: [HexCell], scale: NatureFogScale) -> Set<NatureTileKey> {
        let reach = 6 * scale.radius
        var keys = Set<NatureTileKey>()
        for cell in cells.prefix(resetThreshold) {
            let centre = scale.centre(of: cell)
            let low = key(at: CGPoint(x: centre.x - reach, y: centre.y - reach))
            let high = key(at: CGPoint(x: centre.x + reach, y: centre.y + reach))
            guard high.x - low.x < 64, high.y - low.y < 64 else { continue }
            for x in low.x...high.x {
                for y in low.y...high.y { keys.insert(NatureTileKey(x: x, y: y)) }
            }
        }
        return keys
    }

    /// The tile at `key`, drawn now if it isn't cached.
    func tile(_ key: NatureTileKey) -> NatureFogTile {
        if let cached = tiles[key] { return cached }
        let drawn = render(key)
        tiles[key] = drawn
        return drawn
    }

    /// Moves the book to `next`, dropping the tiles the change reaches.
    func change(to next: NatureFogClearing) -> NatureFogChange {
        guard next != clearing else { return NatureFogChange() }
        let changed = Array(clearing.lifted.symmetricDifference(next.lifted).union(clearing.uncovered.symmetricDifference(next.uncovered)))
        clearing = next
        grower = NatureFogGrower(scale: scale, clearing: next, atlas: atlas)
        guard changed.count <= Self.resetThreshold else {
            tiles.removeAll()
            return NatureFogChange(reset: true)
        }
        let dirty = Self.keys(touching: changed, scale: scale).intersection(tiles.keys)
        for key in dirty { tiles[key] = nil }
        return NatureFogChange(dirty: dirty, cleared: changed.filter(next.isClear))
    }

    /// How far past a tile's edge a piece may start and still be kept (W-20), in points.
    static let cullMargin = 4.0

    /// `pieces` of the tile at `key` with their frames made tile-local, keeping only the ones that reach the
    /// tile (within ``cullMargin``), so no sprite is ever sized or placed from global points (W-20).
    /// `rejected` counts the pieces whose frame failed ``WorldLayerGuard`` (not finite, or absurdly large or
    /// far); a sound piece that only lies off the tile is culled without counting.
    static func visible(_ pieces: [NaturePiece], in key: NatureTileKey) -> (kept: [(piece: NaturePiece, frame: CGRect)], rejected: Int) {
        let origin = area(of: key).origin, side = CGSize(width: tileSize, height: tileSize)
        let reach = CGRect(origin: .zero, size: side).insetBy(dx: -cullMargin, dy: -cullMargin)
        var kept: [(piece: NaturePiece, frame: CGRect)] = []
        var rejected = 0
        for piece in pieces {
            let local = piece.frame.offsetBy(dx: -origin.x, dy: -origin.y)
            guard WorldLayerGuard.accepts(local, in: side) else {
                rejected += 1
                continue
            }
            if local.intersects(reach) { kept.append((piece, local)) }
        }
        return (kept, rejected)
    }

    /// Forgets the tiles farthest from `keep` once more than ``cacheLimit`` are held.
    func evict(keeping keep: Set<NatureTileKey>) {
        guard tiles.count > Self.cacheLimit, let anchor = keep.first else { return }
        let spare = tiles.keys.filter { !keep.contains($0) }
            .sorted { abs($0.x - anchor.x) + abs($0.y - anchor.y) > abs($1.x - anchor.x) + abs($1.y - anchor.y) }
        for key in spare.prefix(tiles.count - Self.cacheLimit) { tiles[key] = nil }
    }

    /// Draws one tile: ground and water into a picture, and in reduced detail the trees too.
    private func render(_ key: NatureTileKey) -> NatureFogTile {
        let area = Self.area(of: key)
        let layout = grower.layout(in: area)
        let format = UIGraphicsImageRendererFormat()
        format.scale = pixelScale
        format.opaque = false
        let picture = UIGraphicsImageRenderer(size: area.size, format: format).image { drawing in
            NatureFogDrawer.drawGround(layout, scale: scale, palette: palette, in: drawing.cgContext, origin: area.origin)
            if scale.reduced { NatureFogDrawer.drawPieces(layout, atlas: atlas, in: drawing.cgContext, origin: area.origin) }
        }
        return NatureFogTile(key: key, ground: layout.hexes.isEmpty ? nil : picture.cgImage,
                             pieces: scale.reduced ? [] : layout.pieces, trees: layout.trees)
    }
}
