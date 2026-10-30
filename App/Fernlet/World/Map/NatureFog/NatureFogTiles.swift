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
nonisolated struct NatureFogTile {
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
    /// Whether the change fogged any cell again (a decoy session, Delete map history): the reached tiles stop
    /// showing their old picture at once rather than when the new one arrives, so no history lingers.
    var covers = false
}

/// The fog's map tiles at one scale and palette (spec "Performance", `nf-tiles`): ground and pieces are drawn
/// back to front into 256-pt tiles, and a tile is redrawn only when a hex in its reach clears.
///
/// **Off the main thread** (owner's go 2026-10-29, map-perf P1). The view says which tiles it wants, nearest
/// first (``want(_:)``: the screen, then ``NatureFogRing``'s ring round it); the book hands at most
/// ``painterCount`` of them at a time to its ``NatureFogTilePainter``s and calls ``onReady`` with each one
/// as it arrives. Nothing here ever draws on the main thread, so a tile not yet ready is the view's to cover
/// with the fog's colour. A tile drawn from a clearing that has since changed under it is thrown away and
/// asked for again; a reset drops everything held or on its way.
///
/// **Bounded** (Power of 10): at most ``cacheLimit`` tiles kept (the farthest from the middle of the screen go
/// first), ``cacheLimit`` wanted, ``painterCount`` drawing.
///
/// A cleared hex can change everything within about 6 R of it: its neighbours become plain edges, the sea's
/// sand line moves, and a tree whose wild ring it was in lifts whole — so ``keys(touching:scale:)`` dirties every
/// tile within 6 R.
///
/// With a ``NatureFogTerrain`` snapshot each grower gets its own ``NatureTerrainMemo``, so a hex's land is read
/// from the atlas once per grower however many tiles it draws (World-Exploration-Spec §1); with none, every tile
/// is today's nature fog.
final class NatureFogTileBook {
    /// A tile's side, in points.
    nonisolated static let tileSize = 256.0
    /// A change of more cells than this redraws everything without animating.
    static let resetThreshold = 600
    /// The most tiles kept, and wanted: the screen and its ring.
    static let cacheLimit = 72
    /// How many tiles draw at once, one painter each.
    static let painterCount = 2

    let scale: NatureFogScale
    let palette: NatureFogPalette
    /// The sprites the view's layers show (the painters keep their own).
    let atlas: NatureFogAtlas
    /// The land under the fog; nil for today's nature fog.
    let terrain: NatureFogTerrain?
    private(set) var clearing: NatureFogClearing
    /// Moves with every change of clearing.
    private(set) var generation = 0
    /// Called on the main thread with each tile as it arrives.
    var onReady: ((NatureFogTile) -> Void)?
    private var tiles: [NatureTileKey: NatureFogTile] = [:]
    private var wanted: [NatureTileKey] = []
    private var drawing: [NatureTileKey: Task<Void, Never>] = [:]
    /// Tiles on their way that a change has since reached: thrown away when they arrive.
    private var outdated: Set<NatureTileKey> = []
    private let painters: [NatureFogTilePainter]
    private var nextPainter = 0
    private let pixelScale: CGFloat

    /// A book drawing `clearing` at `scale` in `palette` over `terrain`'s land, its pictures at `pixelScale`
    /// pixels a point.
    init(scale: NatureFogScale, palette: NatureFogPalette, clearing: NatureFogClearing, pixelScale: CGFloat,
         terrain: NatureFogTerrain? = nil) {
        self.scale = scale
        self.palette = palette
        self.clearing = clearing
        self.terrain = terrain
        self.pixelScale = max(1, min(pixelScale, 3))
        atlas = NatureFogAtlas(palette: palette)
        painters = (0..<Self.painterCount).map { _ in NatureFogTilePainter(palette: palette) }
        let first = painters[0], wild = NatureFogTileOrder(key: NatureTileKey(x: 0, y: 0), scale: scale, palette: palette,
                                                          clearing: NatureFogClearing(), generation: -1, pixelScale: self.pixelScale)
        placeholderDrawing = Task { [weak self] in
            let tile = await first.paint(wild)
            self?.placeholder = tile.ground
        }
    }

    /// The tiles still drawing, and the placeholder, end with the book (the memory wall's ML1).
    isolated deinit {
        placeholderDrawing?.cancel()
        for task in drawing.values { task.cancel() }
    }

    /// Wild fog at this scale and palette, drawn once from an empty clearing (so it shows no history): what a
    /// tile shows until its own picture arrives, so a fling or a zoom out shows fog, not a flat band (the
    /// owner's zoom artifact, 2026-10-30). Nil until it's drawn.
    private(set) var placeholder: CGImage?
    private var placeholderDrawing: Task<Void, Never>?

    /// Borrows `image` (the last scale's wild fog, same palette) until this book's own is drawn.
    func borrowPlaceholder(_ image: CGImage?) {
        if placeholder == nil { placeholder = image }
    }

    /// The tiles held now.
    var cachedKeys: Set<NatureTileKey> { Set(tiles.keys) }

    /// Whether a tile is drawing.
    var isDrawing: Bool { !drawing.isEmpty }

    /// Whether every wanted tile is ready and none is on its way (between two arrivals ``isDrawing`` can read
    /// false while wanted tiles still wait for a painter).
    var isCaughtUp: Bool { drawing.isEmpty && !wanted.contains { tiles[$0] == nil } }

    /// A tile's area in global points.
    nonisolated static func area(of key: NatureTileKey) -> CGRect {
        CGRect(x: Double(key.x) * tileSize, y: Double(key.y) * tileSize, width: tileSize, height: tileSize)
    }

    /// The tile containing global point `point`.
    nonisolated static func key(at point: CGPoint) -> NatureTileKey {
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

    /// The tile at `key` if it's ready.
    func cached(_ key: NatureTileKey) -> NatureFogTile? {
        tiles[key]
    }

    /// Wants `keys`, most wanted first (at most ``cacheLimit``), in place of what was wanted before, and starts
    /// drawing the first ones not ready.
    func want(_ keys: [NatureTileKey]) {
        wanted = Array(keys.prefix(Self.cacheLimit))
        pump()
    }

    /// The tile at `key`, waiting for it to draw if it isn't ready (tests). It's kept only if the clearing
    /// didn't change meanwhile; the view never uses this, it asks with ``want(_:)``.
    func tile(_ key: NatureTileKey) async -> NatureFogTile {
        if let ready = tiles[key] { return ready }
        let asked = generation
        let drawn = await painters[0].paint(order(key))
        if generation == asked { tiles[key] = drawn }
        return drawn
    }

    /// Waits until nothing is drawing (bounded: at most twice ``cacheLimit`` tiles awaited).
    func finishDrawing() async {
        await placeholderDrawing?.value
        for _ in 0..<(Self.cacheLimit * 2) {
            guard let next = drawing.values.first else { return }
            await next.value
        }
    }

    /// Moves the book to `next`, dropping the tiles the change reaches (ready or on their way).
    func change(to next: NatureFogClearing) -> NatureFogChange {
        guard next != clearing else { return NatureFogChange() }
        let changed = Array(clearing.lifted.symmetricDifference(next.lifted).union(clearing.uncovered.symmetricDifference(next.uncovered)))
        let covers = changed.contains { !next.isClear($0) }
        clearing = next
        generation &+= 1
        guard changed.count <= Self.resetThreshold else {
            tiles.removeAll()
            outdated = Set(drawing.keys)
            pump()
            return NatureFogChange(reset: true, covers: covers)
        }
        let reached = Self.keys(touching: changed, scale: scale)
        let dirty = reached.intersection(tiles.keys)
        for key in dirty { tiles[key] = nil }
        outdated.formUnion(reached.intersection(drawing.keys))
        pump()
        return NatureFogChange(dirty: dirty.union(reached.intersection(drawing.keys)), cleared: changed.filter(next.isClear),
                               covers: covers)
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

    /// Forgets the tiles farthest from `centre` (tile units: the middle of the screen) once more than `limit`
    /// (at most ``cacheLimit``) are held, never one in `keep`.
    func evict(around centre: CGPoint, keeping keep: Set<NatureTileKey>, limit: Int = cacheLimit) {
        let limit = max(0, min(limit, Self.cacheLimit))
        guard tiles.count > limit else { return }
        let spare = tiles.keys.filter { !keep.contains($0) }
            .sorted { NatureFogRing.distance($0, centre) > NatureFogRing.distance($1, centre) }
        for key in spare.prefix(tiles.count - limit) { tiles[key] = nil }
    }

    /// Starts drawing the most wanted tiles that are neither ready nor on their way, up to ``painterCount``.
    private func pump() {
        for key in wanted where drawing.count < Self.painterCount && tiles[key] == nil && drawing[key] == nil {
            let painter = painters[nextPainter]
            nextPainter = (nextPainter + 1) % painters.count
            let order = order(key)
            drawing[key] = Task { [weak self] in
                let tile = await painter.paint(order)
                self?.arrived(tile)
            }
        }
    }

    /// Keeps a tile that came back (unless a change reached it on the way) and draws the next.
    private func arrived(_ tile: NatureFogTile) {
        drawing[tile.key] = nil
        if outdated.remove(tile.key) == nil {
            tiles[tile.key] = tile
            onReady?(tile)
        }
        pump()
    }

    private func order(_ key: NatureTileKey) -> NatureFogTileOrder {
        NatureFogTileOrder(key: key, scale: scale, palette: palette, clearing: clearing, generation: generation,
                           pixelScale: pixelScale, terrain: terrain)
    }
}
