import CoreGraphics
import UIKit
import WorldMapStore

/// Everything one tile is drawn from, as plain values, so a painter can take it off the main thread.
nonisolated struct NatureFogTileOrder: Sendable {
    let key: NatureTileKey
    let scale: NatureFogScale
    let palette: NatureFogPalette
    let clearing: NatureFogClearing
    /// Moves with every change of clearing the book takes; a painter grows from one clearing per generation.
    let generation: Int
    /// Pixels a point in the tile's picture.
    let pixelScale: CGFloat
    /// The land under the fog (World-Exploration-Spec §1), an immutable snapshot of the bundled atlas; nil for
    /// today's nature fog. Its own `generation` moves when the atlas arrives late or the season changes.
    var terrain: NatureFogTerrain? = nil
    /// The fog view's shared answers for ``terrain`` (every scale's painters read one memo); nil and the painter
    /// keeps its own.
    var memo: NatureTerrainMemo? = nil
}

/// What a tile shows, drawn from its order: the seam where the fog's art plugs into the tile pipeline. It runs
/// on a painter, off the main thread, so it reads nothing but its arguments: no main-actor state, no shared
/// mutable caches. Scheduling, caching and placement are the book's and the view's.
nonisolated enum NatureFogTileContent {
    /// Draws one tile: ground and water into a picture, and in reduced detail the trees too.
    static func draw(_ order: NatureFogTileOrder, grower: NatureFogGrower) -> NatureFogTile {
        let area = NatureFogTileBook.area(of: order.key)
        let layout = grower.layout(in: area)
        // A tile of open sea has no land hexes but still draws its water (World-Exploration-Spec §1).
        guard !layout.hexes.isEmpty || !layout.seas.isEmpty else {
            return NatureFogTile(key: order.key, ground: nil, pieces: [], trees: layout.trees)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = order.pixelScale
        format.opaque = false
        let scale = order.scale
        let picture = UIGraphicsImageRenderer(size: area.size, format: format).image { drawing in
            NatureFogDrawer.drawGround(layout, scale: scale, palette: order.palette, in: drawing.cgContext, origin: area.origin)
            if scale.reduced { NatureFogDrawer.drawPieces(layout, atlas: grower.atlas, in: drawing.cgContext, origin: area.origin) }
        }
        return NatureFogTile(key: order.key, ground: picture.cgImage, pieces: scale.reduced ? [] : layout.pieces,
                             trees: layout.trees)
    }
}

/// Draws fog tiles off the main thread (spec "Performance"; owner's go 2026-10-29, map-perf P1), so a fling
/// or a glide never waits on a tile: the view shows the fog's colour until the picture arrives.
///
/// Each painter keeps its own atlas and grower (neither is shared with the main thread or another painter);
/// the grower is grown again when an order brings a new generation, so its memo never mixes two clearings.
/// With terrain, the painter also keeps one ``NatureTerrainMemo`` (each hex's land, read from the atlas once)
/// across clearings — the order's shared one when it carries it for the same snapshot — and starts a new one only
/// when the terrain snapshot itself changes.
/// The cells it reads are the in-memory copy the order carries: nothing is written anywhere.
actor NatureFogTilePainter {
    private let atlas: NatureFogAtlas
    private var grower: NatureFogGrower?
    private var grownFor = -1
    private var memo: NatureTerrainMemo?
    private var memoFor: NatureFogTerrain?

    /// A painter for the tiles of one book (one scale and palette).
    init(palette: NatureFogPalette) {
        atlas = NatureFogAtlas(palette: palette)
    }

    /// The tile `order` asks for.
    func paint(_ order: NatureFogTileOrder) -> NatureFogTile {
        NatureFogTileContent.draw(order, grower: currentGrower(for: order))
    }

    private func currentGrower(for order: NatureFogTileOrder) -> NatureFogGrower {
        if let grower, grownFor == order.generation, memoFor == order.terrain { return grower }
        if memoFor != order.terrain {
            let shared = order.memo.flatMap { $0.terrain == order.terrain ? $0 : nil }
            memo = shared ?? order.terrain.map(NatureTerrainMemo.init(terrain:))
            memoFor = order.terrain
        }
        let grown = NatureFogGrower(scale: order.scale, clearing: order.clearing, atlas: atlas, terrain: memo)
        grower = grown
        grownFor = order.generation
        return grown
    }
}

/// The tiles worth having ready, in the order to draw them (owner 2026-10-29, "like a video game"): the ones on
/// screen nearest the middle first, then a ring one tile wide round them, reaching ``lead`` tiles further on
/// the side the map is moving towards.
nonisolated enum NatureFogRing {
    /// The ring's width beyond the screen, in tiles.
    static let margin = 1
    /// How much further the ring reaches ahead of a moving map, in tiles.
    static let lead = 2
    /// A move of less than this (tiles a frame) counts as still.
    static let stillness = 0.02

    /// The tiles from `low` to `high` (the screen's), then the ring, each nearest-first: the screen's measured
    /// from `centre` (tile units), the ring's from `centre` moved ``lead`` tiles along `motion`. At most `limit`.
    static func keys(low: NatureTileKey, high: NatureTileKey, centre: CGPoint, motion: CGVector, limit: Int) -> [NatureTileKey] {
        guard high.x >= low.x, high.y >= low.y, high.x - low.x < 12, high.y - low.y < 12, limit > 0 else { return [] }
        let ahead = (x: direction(motion.dx), y: direction(motion.dy))
        let outer = (low: NatureTileKey(x: low.x - margin - (ahead.x < 0 ? lead : 0), y: low.y - margin - (ahead.y < 0 ? lead : 0)),
                     high: NatureTileKey(x: high.x + margin + (ahead.x > 0 ? lead : 0), y: high.y + margin + (ahead.y > 0 ? lead : 0)))
        var screen: [NatureTileKey] = [], ring: [NatureTileKey] = []
        for x in outer.low.x...outer.high.x {
            for y in outer.low.y...outer.high.y {
                let key = NatureTileKey(x: x, y: y)
                if (low.x...high.x).contains(x), (low.y...high.y).contains(y) { screen.append(key) } else { ring.append(key) }
            }
        }
        let front = CGPoint(x: centre.x + Double(ahead.x * lead), y: centre.y + Double(ahead.y * lead))
        return Array((sorted(screen, from: centre) + sorted(ring, from: front)).prefix(limit))
    }

    /// −1, 0 or 1: which way `delta` (tiles a frame) moves, still under ``stillness``.
    static func direction(_ delta: Double) -> Int {
        guard delta.isFinite, abs(delta) >= stillness else { return 0 }
        return delta > 0 ? 1 : -1
    }

    /// `keys` nearest to `point` (tile units, measured to each tile's middle) first.
    static func sorted(_ keys: [NatureTileKey], from point: CGPoint) -> [NatureTileKey] {
        keys.sorted { distance($0, point) < distance($1, point) }
    }

    /// How far `key`'s middle is from `point`, in tiles.
    static func distance(_ key: NatureTileKey, _ point: CGPoint) -> Double {
        let dx = Double(key.x) + 0.5 - point.x, dy = Double(key.y) + 0.5 - point.y
        return (dx * dx + dy * dy).squareRoot()
    }
}
