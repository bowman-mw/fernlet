import Foundation
import Observation
import SwiftUI
import WorldMapStore

/// A crossed road's line cut into short pieces in normalised Web Mercator, each with its box, so a screen draws
/// only the pieces it shows (World-Exploration-Spec §2, `ex-roads`).
nonisolated struct WorldRoadPiece: Sendable {
    /// Highway or main road.
    let kind: AtlasRoadKind
    /// The points' Mercator `x` and `y`, in order.
    let xs: [Double]
    let ys: [Double]
    /// The piece's Mercator box.
    let minX: Double, minY: Double, maxX: Double, maxY: Double
}

/// What the screens draw of the crossed roads: every crossed road whole, as ``WorldRoadPiece``s. Compares by
/// ``generation`` alone, so a view that holds it redraws only when the crossed set changed.
nonisolated struct WorldRoadDrawing: Equatable, Sendable {
    /// The most points one piece holds (pieces of one line share their end points).
    static let maxPiecePoints = 48
    /// The most pieces kept (a lifetime of crossings is a few hundred roads of a few thousand points).
    static let maxPieces = 40_000

    /// Moves each time the crossed set changes.
    let generation: Int
    /// The pieces.
    let pieces: [WorldRoadPiece]
    /// How many roads are crossed.
    let roadCount: Int

    /// Nothing crossed.
    static let none = WorldRoadDrawing(generation: 0, pieces: [], roadCount: 0)

    static func == (lhs: WorldRoadDrawing, rhs: WorldRoadDrawing) -> Bool { lhs.generation == rhs.generation }

    /// The pieces of `roads`, at most ``maxPieces``. Bounded: each road's lines, each point once (plus a shared
    /// end point per piece).
    static func make(roads: [AtlasRoad], generation: Int) -> WorldRoadDrawing {
        var pieces: [WorldRoadPiece] = []
        // Bounded: the roads' lines, capped at decode, and maxPieces pieces.
        for road in roads {
            for index in 0..<road.lineCount where pieces.count < maxPieces {
                let points = road.line(index).map { WebMercator.unit($0) }
                for start in stride(from: 0, to: points.count - 1, by: maxPiecePoints - 1) where pieces.count < maxPieces {
                    let end = min(start + maxPiecePoints - 1, points.count - 1)
                    pieces.append(piece(Array(points[start...end]), kind: road.kind))
                }
            }
        }
        return WorldRoadDrawing(generation: generation, pieces: pieces, roadCount: roads.count)
    }

    /// One piece of points.
    private static func piece(_ points: [(x: Double, y: Double)], kind: AtlasRoadKind) -> WorldRoadPiece {
        let xs = points.map(\.x), ys = points.map(\.y)
        return WorldRoadPiece(kind: kind, xs: xs, ys: ys, minX: xs.min() ?? 0, minY: ys.min() ?? 0,
                              maxX: xs.max() ?? 0, maxY: ys.max() ?? 0)
    }
}

/// The crossed roads Home keeps, derived from the lifted fog (``AtlasRoadCrossings``): nothing is stored, so a
/// wipe, a decoy's own cells and a fresh history each give their own answer. Work runs off the main actor, one
/// update at a time; a request while one runs waits, only the newest kept.
@MainActor
@Observable
final class WorldCrossedRoadsModel {
    /// What the map draws.
    private(set) var drawing = WorldRoadDrawing.none

    @ObservationIgnored private var crossings = AtlasRoadCrossings()
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var pending: (cells: Set<HexCell>, atlas: WorldAtlas)?
    /// The city the view is in, for the city view's roads over the fog (its own memo, so Home's explore layer
    /// keeps its own answers).
    @ObservationIgnored let cityMemo = WorldExploreMemo()

    /// An update still running ends with the model (the memory wall's ML1).
    isolated deinit {
        task?.cancel()
    }

    /// Works the crossed roads out for `cells` over `atlas` (nil: none crossed).
    func update(cells: Set<HexCell>, atlas: WorldAtlas?) {
        guard let atlas else {
            crossings = AtlasRoadCrossings()
            if drawing.roadCount > 0 { drawing = WorldRoadDrawing(generation: drawing.generation &+ 1, pieces: [], roadCount: 0) }
            return
        }
        guard task == nil else {
            pending = (cells, atlas)
            return
        }
        run(cells: cells, atlas: atlas)
    }

    /// One update off the main actor, then the newest waiting one.
    private func run(cells: Set<HexCell>, atlas: WorldAtlas) {
        let start = crossings, generation = drawing.generation &+ 1
        task = Task { [weak self] in
            let (updated, made) = await Task.detached(priority: .utility) {
                var next = start
                next.update(cells: cells, atlas: atlas)
                let changed = next.roadIndices != start.roadIndices
                return (next, changed ? WorldRoadDrawing.make(roads: next.roads(in: atlas), generation: generation) : nil)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.finish(updated, drawing: made)
        }
    }

    /// Keeps `updated` (and its new drawing, when the crossed set changed) and starts the waiting request, if any.
    private func finish(_ updated: AtlasRoadCrossings, drawing made: WorldRoadDrawing?) {
        crossings = updated
        task = nil
        if let made { drawing = made }
        guard let next = pending else { return }
        pending = nil
        run(cells: next.cells, atlas: next.atlas)
    }
}

/// The approved major-road style (the mockup's `roadPath`): an ink edge 2.5 pt wider than the road, the amber road,
/// and a pale 1-pt centre dash (4 on, 5 off), round ends and joins; the same in light and dark, as drawn. Widths by
/// screen: Home 5 pt, zoomed out a step 4 pt; the world view 2.5 pt at Country, 3 at State and 3.5 at City, a main
/// road half a point thinner there (the closest-zoom drawing). The trail stays green, so a road never looks walked.
nonisolated enum WorldRoadStyle {
    /// The edge (`#4A2E1C`).
    static let ink: UInt32 = 0x4A2E1C
    /// The road (`#E2A33A`).
    static let amber: UInt32 = 0xE2A33A
    /// The centre dash (`#FFE7A8`).
    static let dash: UInt32 = 0xFFE7A8
    /// How much wider the edge is than the road.
    static let edgeExtra: CGFloat = 2.5
    /// The dash's width and pattern.
    static let dashWidth: CGFloat = 1
    static let dashPattern: [CGFloat] = [4, 5]
    /// Home's road at its own zoom, and a step out (`ex-city-view` 5, `ex-zoomed` 4).
    static let homeWidth: CGFloat = 5
    static let homeZoomedOutWidth: CGFloat = 4

    /// Whether the world view draws crossed roads at `level`: from Country in (the mockup draws them at World too,
    /// where a hex is about 225 km and a road would be a stub on one hex).
    static func showsRoads(at level: AtlasZoomLevel) -> Bool { level >= .country }

    /// The world view's road width at `level` for `kind`.
    static func worldWidth(at level: AtlasZoomLevel, kind: AtlasRoadKind) -> CGFloat {
        let base: CGFloat
        switch level {
        case .world, .country: base = 2.5
        case .state: base = 3
        case .city: base = 3.5
        }
        return kind == .mainRoad && level >= .state ? base - 0.5 : base
    }
}

/// Draws ``WorldRoadDrawing`` pieces into a Canvas: the pieces whose box meets the view (grown by a margin), each
/// segment clipped to the W-20 layer guard's reach (``WorldLayerGuard/viewMultiple`` times the view's longer side
/// past each edge), so no point handed to Core Graphics is ever far off screen however long the road.
enum WorldRoadPainter {
    /// How a piece's Mercator points reach the screen: `screen = ((x + shift) - originX) × scale, (y - originY) × scale`.
    struct Projection {
        let originX: Double, originY: Double, scale: Double
        /// A per-piece shift in Mercator `x` (the world view's wrap; 0 on Home).
        var shift: (WorldRoadPiece) -> Double = { _ in 0 }
    }

    /// Strokes the pieces visible in `size` through `projection`, `width(kind)` wide, edge, road, dash.
    static func draw(_ drawing: WorldRoadDrawing, in context: inout GraphicsContext, size: CGSize,
                     projection: Projection, width: (AtlasRoadKind) -> CGFloat) {
        guard projection.scale.isFinite, projection.scale > 0, size.width > 0, size.height > 0 else { return }
        for kind in AtlasRoadKind.allCases {
            let path = self.path(drawing.pieces.filter { $0.kind == kind }, size: size, projection: projection)
            guard !path.isEmpty else { continue }
            let w = width(kind)
            context.stroke(path, with: .color(WorldPalette.rgb(WorldRoadStyle.ink)),
                           style: StrokeStyle(lineWidth: w + WorldRoadStyle.edgeExtra, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(WorldPalette.rgb(WorldRoadStyle.amber)),
                           style: StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round))
            context.stroke(path, with: .color(WorldPalette.rgb(WorldRoadStyle.dash)),
                           style: StrokeStyle(lineWidth: WorldRoadStyle.dashWidth, dash: WorldRoadStyle.dashPattern))
        }
    }

    /// The path of the visible `pieces`, clipped. Bounded: the pieces (at most ``WorldRoadDrawing/maxPieces``),
    /// each at most ``WorldRoadDrawing/maxPiecePoints`` points.
    static func path(_ pieces: [WorldRoadPiece], size: CGSize, projection: Projection) -> Path {
        let limit = WorldLayerGuard.viewMultiple * Double(max(size.width, size.height))
        let reach = CGRect(origin: .zero, size: size).insetBy(dx: -limit, dy: -limit)
        let margin = 40 / projection.scale
        let view = (minX: projection.originX - margin, minY: projection.originY - margin,
                    maxX: projection.originX + Double(size.width) / projection.scale + margin,
                    maxY: projection.originY + Double(size.height) / projection.scale + margin)
        var path = Path()
        for piece in pieces {
            let shift = projection.shift(piece)
            guard piece.maxX + shift >= view.minX, piece.minX + shift <= view.maxX,
                  piece.maxY >= view.minY, piece.minY <= view.maxY else { continue }
            var previous: CGPoint?
            for index in piece.xs.indices where index < piece.ys.count {
                let point = CGPoint(x: (piece.xs[index] + shift - projection.originX) * projection.scale,
                                    y: (piece.ys[index] - projection.originY) * projection.scale)
                defer { previous = point }
                guard let from = previous else { continue }
                guard let clipped = clip(from, point, to: reach) else { continue }
                if path.currentPoint != clipped.0 { path.move(to: clipped.0) }
                path.addLine(to: clipped.1)
            }
        }
        return path
    }

    /// The part of segment `a`–`b` inside `rect` (Liang–Barsky), or nil when none is, or a point is not finite.
    static func clip(_ a: CGPoint, _ b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
        guard a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return nil }
        let dx = b.x - a.x, dy = b.y - a.y
        var t0: CGFloat = 0, t1: CGFloat = 1
        let edges: [(CGFloat, CGFloat)] = [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x), (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)]
        for (p, q) in edges {
            if p == 0 {
                guard q >= 0 else { return nil }
                continue
            }
            let t = q / p
            if p < 0 { t0 = max(t0, t) } else { t1 = min(t1, t) }
            guard t0 <= t1 else { return nil }
        }
        return (CGPoint(x: a.x + t0 * dx, y: a.y + t0 * dy), CGPoint(x: a.x + t1 * dx, y: a.y + t1 * dy))
    }
}
