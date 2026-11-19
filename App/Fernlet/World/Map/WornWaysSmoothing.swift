import Foundation
import WorldMapStore

/// How the counted ways (roads, railways and ferry wakes) are drawn smooth and unbroken (owner 2026-11-19: "the worn
/// paths are wavy and have gaps"; picked option A, smooth and pool, from the renders in `WornPathsSmoothingTests`).
/// Counter only, so it works for all history:
///
/// - **The gaps** (``pooledLevels(_:kind:today:)``): a drive's passes split between neighbouring cells, so some cells of
///   a worn road stay under level 1 and the band breaks. A closing of radius two fills those gaps and nothing else.
/// - **The waves** (``smoothedLines(_:weights:)``): the band's spine (``WornWaysBuilder/spine(_:)``)
///   joins hex centres, a staircase on any road off the hex axes. Side branches that only run alongside the spine are
///   pruned, each cell's point is pulled to where its neighbourhood's trips went, and each chain
///   of centres is averaged over about 150 m (never across a street corner), simplified (Douglas–Peucker) and rounded
///   (one Chaikin pass, each corner cut at most 5 m).
///
/// Pure and bounded, so it runs off the main actor in ``WornWaysBuilder``.
nonisolated enum WornWaysSmoothing {
    /// A point in Mercator units.
    typealias Point = (x: Double, y: Double)

    /// The moving average's window, in spine points (cell centres about 30 m apart, so about 150 m).
    static let averageWindow = 5
    /// Douglas–Peucker tolerance for the smoothed spine, in metres.
    static let spineTolerance = 8.0
    /// The most a corner is cut by the Chaikin pass, in metres.
    static let maxCornerCut = 5.0
    /// A chain's corners: where its shape, simplified to this many metres, turns by ``cornerAngle`` degrees or more
    /// between stretches of at least ``cornerLeg`` metres (a street corner, not the hex staircase).
    static let cornerTolerance = 20.0
    static let cornerAngle = 45.0
    static let cornerLeg = 60.0
    /// The longest side branch looked at for pruning, in cells (about 360 m); only branches that run alongside the
    /// rest of the spine are pruned (``prunedSpurs(_:)``).
    static let maxSpurCells = 12

    /// One smoothed line at one level: its points in Mercator units, and which chain of the spine it was cut from
    /// (a chain's lines meet end to end where its level changes).
    struct Line {
        let level: WornLevel
        let points: [Point]
        let chain: Int
    }

    // MARK: Pooling (the gaps)

    /// The pooled levels of `kind` on `today`: the cells that reached level 1, plus every cell with a pass inside a
    /// gap of up to about four cells along a worn band, at the highest level within two cells. The gaps close by a
    /// morphological closing of radius two (grow the worn cells two rings, shrink back two rings), so a cell a few
    /// trips short in the middle of a worn road joins it while the band's sides stay as they were (no fattening).
    /// A drive's passes split between neighbouring cells, so without this the band breaks. Bounded: at most
    /// ``WornWayRuns/maxCells`` worn cells, each growing over its 18 cells within two rings, and each grown cell
    /// checked over its own 18.
    static func pooledLevels(_ ways: [WornWayKey: WornTally], kind: WornWayKind, today: UInt16) -> [HexCell: WornLevel] {
        let levels = WornWaysBuilder.wayLevels(ways, kind: kind, today: today)
        let worn = levels.filter { $0.value >= .one }
        var grown: [HexCell: WornLevel] = [:]
        for (cell, level) in worn {
            for near in ring2(cell) where grown[near].map({ level > $0 }) ?? true { grown[near] = level }
        }
        var pooled = levels
        for (cell, level) in grown where levels[cell] == nil && ways[WornWayKey(cell: cell, kind: kind)] != nil {
            // Shrink back: a gap cell is surrounded by grown cells two rings out; a cell beside the band is not.
            if ring2(cell).allSatisfy({ grown[$0] != nil }) { pooled[cell] = level }
        }
        return pooled
    }

    /// `cell` and the 18 cells within two rings of it.
    private static func ring2(_ cell: HexCell) -> [HexCell] {
        var cells: [HexCell] = []
        for dq in -2...2 {
            for dr in max(-2, -dq - 2)...min(2, -dq + 2) { cells.append(HexCell(q: cell.q + dq, r: cell.r + dr)) }
        }
        return cells
    }

    // MARK: The smoothed spine (the waves)

    /// Each counted cell of `kind` in `ways` weighted by its trips, for ``smoothedLines(_:weights:)``.
    static func weights(_ ways: [WornWayKey: WornTally], kind: WornWayKind) -> [HexCell: Double] {
        var weights: [HexCell: Double] = [:]
        for (key, tally) in ways where key.kind == kind && weights.count < WornWayRuns.maxCells { weights[key.cell] = Double(tally.count) }
        return weights
    }

    /// The pieces for pooled `levels`: ``smoothedLines(_:weights:)`` cut into pieces of at most
    /// ``WornWaysDrawing/maxPiecePoints``. Bounded: at most ``WornWaysDrawing/maxPieces``.
    static func smoothedPieces(_ levels: [HexCell: WornLevel], weights: [HexCell: Double] = [:]) -> [WornPiece] {
        var pieces: [WornPiece] = []
        for line in smoothedLines(levels, weights: weights) where pieces.count < WornWaysDrawing.maxPieces {
            pieces += WornWaysBuilder.chunks(line.points, level: line.level)
        }
        return Array(pieces.prefix(WornWaysDrawing.maxPieces))
    }

    /// The smoothed lines of pooled `levels`: the band's spine without the side branches that run alongside it,
    /// walked into chains of cells; each cell's point is the centroid of the counted cells touching it, weighted by
    /// `weights` (its trips; 1 for a pooled cell missing from them), so the line follows where the trips went across
    /// a band two cells wide, not whichever strand the spine took; each chain is then averaged over
    /// ``averageWindow`` points between its corners (``cornerKeepingAverage(_:)``), cut
    /// where the level changes (each joint at the lower of its two cells' levels), then Douglas–Peucker at
    /// ``spineTolerance`` and one Chaikin pass. A cell with no pooled neighbour draws nothing. Bounded: the spine's
    /// joints (at most ``WornWayRuns/maxCells`` cells).
    static func smoothedLines(_ levels: [HexCell: WornLevel], weights: [HexCell: Double] = [:]) -> [Line] {
        var lines: [Line] = []
        for (index, chain) in chains(prunedSpurs(WornWaysBuilder.spine(levels))).enumerated() {
            let averaged = cornerKeepingAverage(chain.map { centroid(of: $0, levels: levels, weights: weights) })
            for run in levelRuns(chain, levels: levels) {
                let points = Array(averaged[run.range])
                let tolerance = metres(spineTolerance, near: points[0]), cut = metres(maxCornerCut, near: points[0])
                lines.append(Line(level: run.level, points: chaikin(douglasPeucker(points, tolerance: tolerance), maxCut: cut), chain: index))
            }
        }
        return lines
    }

    /// `tree` without its side branches (up to ``maxSpurCells`` cells, from a leaf to a junction) that run alongside
    /// the rest of the spine: every cell of the branch touches a cell of the rest, the junction not counted. That is
    /// the braid a band two cells wide leaves; a side street that leaves the road keeps its cells off the spine, so
    /// it stays however short. A junction that would lose every branch but one keeps its longest, so a road whose
    /// end forks keeps its end. Two rounds, so a branch left behind by the first goes too. Bounded: two rounds over
    /// the joints, each branch at most ``maxSpurCells`` cells with six neighbours each.
    static func prunedSpurs(_ tree: [WornWaysBuilder.Edge]) -> [WornWaysBuilder.Edge] {
        var edges = Set(tree)
        for _ in 0..<2 {
            let next = adjacency(edges)
            var spurs: [HexCell: [(edges: [WornWaysBuilder.Edge], cells: [HexCell])]] = [:]
            for (leaf, around) in next where around.count == 1 {
                var path = [WornWaysBuilder.Edge(leaf, around[0])], cells = [leaf]
                var previous = leaf, tip = around[0]
                while (next[tip]?.count ?? 0) == 2, path.count <= maxSpurCells {
                    guard let step = next[tip]?.first(where: { $0 != previous }) else { break }
                    cells.append(tip)
                    path.append(WornWaysBuilder.Edge(tip, step))
                    (previous, tip) = (tip, step)
                }
                guard (next[tip]?.count ?? 0) >= 3, path.count <= maxSpurCells else { continue }
                let own = Set(cells), junction = tip
                let alongside = cells.allSatisfy { cell in
                    MercatorHexGrid.neighbours(of: cell).contains { $0 != junction && !own.contains($0) && next[$0] != nil }
                }
                if alongside { spurs[junction, default: []].append((path, cells)) }
            }
            var cut = Set<WornWaysBuilder.Edge>()
            for (junction, branches) in spurs {
                var sorted = branches.sorted { $0.edges.count < $1.edges.count }
                if (next[junction]?.count ?? 0) - sorted.count <= 1 { sorted.removeLast() }
                for branch in sorted { cut.formUnion(branch.edges) }
            }
            guard !cut.isEmpty else { break }
            edges.subtract(cut)
        }
        return Array(edges)
    }

    /// The centroid of `cell` and its six neighbours that are counted, each weighted by `weights` (1 for a pooled
    /// cell missing from them, 0 for one neither pooled nor counted).
    static func centroid(of cell: HexCell, levels: [HexCell: WornLevel], weights: [HexCell: Double]) -> Point {
        var x = 0.0, y = 0.0, total = 0.0
        for near in [cell] + MercatorHexGrid.neighbours(of: cell) {
            let weight = weights[near] ?? (levels[near] == nil ? 0 : 1)
            guard weight > 0 else { continue }
            let centre = MercatorHexGrid.centre(of: near)
            x += centre.x * weight
            y += centre.y * weight
            total += weight
        }
        return total > 0 ? (x / total, y / total) : MercatorHexGrid.centre(of: cell)
    }

    /// `centres` averaged over ``averageWindow`` points, but never across a turn: the chain's corners (where its
    /// shape, simplified at ``cornerTolerance``, turns by ``cornerAngle`` or more between stretches of at least
    /// ``cornerLeg``) are kept, and each stretch between them is averaged on its own, so a right-angle street corner
    /// stays at the corner instead of being rounded 50 m inside it. Bounded: the points times the window.
    static func cornerKeepingAverage(_ centres: [Point]) -> [Point] {
        guard let first = centres.first, centres.count > 2 else { return centres }
        let simple = douglasPeuckerIndices(centres, tolerance: metres(cornerTolerance, near: first))
        let leg = metres(cornerLeg, near: first)
        var anchors = [0]
        for (before, (here, after)) in zip(simple, zip(simple.dropFirst(), simple.dropFirst(2))) {
            let a = centres[before], b = centres[here], c = centres[after]
            let inX = b.x - a.x, inY = b.y - a.y, outX = c.x - b.x, outY = c.y - b.y
            let inLength = hypot(inX, inY), outLength = hypot(outX, outY)
            guard inLength >= leg, outLength >= leg else { continue }
            let cosine = (inX * outX + inY * outY) / (inLength * outLength)
            if cosine <= cos(cornerAngle * .pi / 180) { anchors.append(here) }
        }
        anchors.append(centres.count - 1)
        var out: [Point] = [centres[0]]
        for (start, end) in zip(anchors, anchors.dropFirst()) where end > start {
            out += movingAverage(Array(centres[start...end]), window: averageWindow).dropFirst()
        }
        return out
    }

    /// Each cell's neighbours over `edges`.
    private static func adjacency(_ edges: some Sequence<WornWaysBuilder.Edge>) -> [HexCell: [HexCell]] {
        var next: [HexCell: [HexCell]] = [:]
        for edge in edges {
            next[edge.a, default: []].append(edge.b)
            next[edge.b, default: []].append(edge.a)
        }
        return next
    }

    /// `edges` walked into chains of cells from end or junction to end or junction (a loop is walked from any of its
    /// cells). Bounded: each joint is walked once.
    static func chains(_ edges: [WornWaysBuilder.Edge]) -> [[HexCell]] {
        let next = adjacency(edges)
        var used = Set<WornWaysBuilder.Edge>()
        var chains: [[HexCell]] = []
        let starts = next.keys.sorted { (next[$0]?.count == 2 ? 1 : 0, $0) < (next[$1]?.count == 2 ? 1 : 0, $1) }
        for start in starts {
            for first in next[start] ?? [] where !used.contains(WornWaysBuilder.Edge(start, first)) {
                used.insert(WornWaysBuilder.Edge(start, first))
                var chain = [start, first]
                var previous = start, tip = first
                for _ in 0..<edges.count {
                    guard next[tip]?.count == 2, let step = next[tip]?.first(where: { $0 != previous }),
                          used.insert(WornWaysBuilder.Edge(tip, step)).inserted else { break }
                    chain.append(step)
                    (previous, tip) = (tip, step)
                }
                chains.append(chain)
            }
        }
        return chains
    }

    /// The runs of `chain`'s joints at one level (each joint at the lower of its cells' levels), as point ranges that
    /// share their end points.
    static func levelRuns(_ chain: [HexCell], levels: [HexCell: WornLevel]) -> [(level: WornLevel, range: ClosedRange<Int>)] {
        var runs: [(level: WornLevel, range: ClosedRange<Int>)] = []
        var start = 0
        var current: WornLevel?
        for index in 0..<max(0, chain.count - 1) {
            let level = min(levels[chain[index]] ?? .abandoned, levels[chain[index + 1]] ?? .abandoned)
            if let current, current != level {
                runs.append((current, start...index))
                start = index
            }
            current = level
        }
        if let current, chain.count >= 2 { runs.append((current, start...(chain.count - 1))) }
        return runs
    }

    // MARK: Line tools

    /// `metres` on the ground in Mercator units near `point`.
    static func metres(_ metres: Double, near point: Point) -> Double {
        metres * WebMercator.unitsPerMetre(at: WebMercator.geo(x: point.x, y: point.y).latitude)
    }

    /// Each point averaged with up to `window / 2` points either side (fewer near the ends, so the end points stay).
    /// Bounded: the points times the window.
    static func movingAverage(_ points: [Point], window: Int) -> [Point] {
        let half = max(0, window / 2)
        guard points.count > 2, half > 0 else { return points }
        return points.indices.map { index in
            let reach = min(half, index, points.count - 1 - index)
            var x = 0.0, y = 0.0
            for other in (index - reach)...(index + reach) {
                x += points[other].x
                y += points[other].y
            }
            let count = Double(2 * reach + 1)
            return (x / count, y / count)
        }
    }

    /// `points` simplified by Douglas–Peucker to within `tolerance` (Mercator units), end points kept. Bounded: an
    /// explicit stack, each point split at most once.
    static func douglasPeucker(_ points: [Point], tolerance: Double) -> [Point] {
        douglasPeuckerIndices(points, tolerance: tolerance).map { points[$0] }
    }

    /// The indices of the points Douglas–Peucker keeps of `points` at `tolerance`, rising.
    static func douglasPeuckerIndices(_ points: [Point], tolerance: Double) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        while let (first, last) = stack.popLast() {
            guard last > first + 1 else { continue }
            let a = points[first], b = points[last]
            let dx = b.x - a.x, dy = b.y - a.y, length = hypot(dx, dy)
            var worst = 0.0, worstIndex = first
            for index in (first + 1)..<last {
                let p = points[index]
                let distance = length > 0 ? abs(dy * (p.x - a.x) - dx * (p.y - a.y)) / length : hypot(p.x - a.x, p.y - a.y)
                if distance > worst { (worst, worstIndex) = (distance, index) }
            }
            if worst > tolerance {
                keep[worstIndex] = true
                stack.append((first, worstIndex))
                stack.append((worstIndex, last))
            }
        }
        return points.indices.filter { keep[$0] }
    }

    /// One Chaikin corner-cutting pass over the open line `points`, end points kept, so corners round off: each
    /// corner cut a quarter of the way along its segments, at most `maxCut` (Mercator units), so a long straight
    /// meeting a turn keeps its corner where the road turns.
    static func chaikin(_ points: [Point], maxCut: Double = .infinity) -> [Point] {
        guard points.count > 2 else { return points }
        var out: [Point] = [points[0]]
        for index in 0..<(points.count - 1) {
            let a = points[index], b = points[index + 1]
            let length = hypot(b.x - a.x, b.y - a.y)
            let t = length > 0 ? min(0.25, maxCut / length) : 0.25
            if index > 0 { out.append((a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t)) }
            if index < points.count - 2 { out.append((b.x - (b.x - a.x) * t, b.y - (b.y - a.y) * t)) }
        }
        out.append(points[points.count - 1])
        return out
    }
}
