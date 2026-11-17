import Foundation
import WorldMapStore

/// One stretch of a worn footpath or a frequent road at one level, in Mercator units with its box (a
/// ``WorldRoadPiece``, so ``WorldRoadPainter`` culls and clips it; its road kind means nothing here).
nonisolated struct WornPiece: Sendable {
    /// How worn.
    let level: WornLevel
    /// The points and their box.
    let line: WorldRoadPiece

    /// A piece through `points` at `level`.
    init(level: WornLevel, points: [(x: Double, y: Double)]) {
        let xs = points.map(\.x), ys = points.map(\.y)
        self.level = level
        line = WorldRoadPiece(kind: .highway, xs: xs, ys: ys, minX: xs.min() ?? 0, minY: ys.min() ?? 0,
                              maxX: xs.max() ?? 0, maxY: ys.max() ?? 0)
    }
}

/// What the map draws of the worn paths and frequent roads (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §3,
/// §8): the footpaths along the person's own lines, each stretch at its cell's level; the roads hex centre to hex
/// centre between neighbouring frequent road cells; and Home's saved trails with the stretches over worn footpaths
/// taken out, so the map shows one line, not two. Compares by ``generation`` alone, so a view that holds it redraws
/// only when it was worked out again. Nothing here is stored.
nonisolated struct WornWaysDrawing: Equatable, Sendable {
    /// The most points one piece holds (pieces of one line share their end points).
    static let maxPiecePoints = 48
    /// The most pieces of each kind kept.
    static let maxPieces = 30_000

    /// Moves each time the drawing is worked out again.
    let generation: Int
    /// The worn footpaths.
    let footpaths: [WornPiece]
    /// The frequent roads.
    let roads: [WornPiece]
    /// The saved trails with the stretches over footpaths at level 1 or more taken out.
    let trails: [[GeoPoint]]
    /// Which of Home's trail readings ``trails`` was cut from (Home's own count), so a stale cut is never drawn.
    let trailStamp: Int
    /// A hash of what is drawn (each drawn cell and its level), the same however it was worked out: the map
    /// widget's stamp moves with it.
    let contentHash: Int

    /// The footpaths' and the roads' lines by level (``WornLevel/rawValue``), so a frame strokes each level once.
    let footpathsByLevel: [[WorldRoadPiece]]
    let roadsByLevel: [[WorldRoadPiece]]

    /// A drawing of these pieces and cut trails.
    init(generation: Int, footpaths: [WornPiece], roads: [WornPiece], trails: [[GeoPoint]], trailStamp: Int, contentHash: Int) {
        self.generation = generation
        self.footpaths = footpaths
        self.roads = roads
        self.trails = trails
        self.trailStamp = trailStamp
        self.contentHash = contentHash
        footpathsByLevel = Self.byLevel(footpaths)
        roadsByLevel = Self.byLevel(roads)
    }

    /// Nothing worn, nothing cut.
    static let none = WornWaysDrawing(generation: 0, footpaths: [], roads: [], trails: [], trailStamp: -1, contentHash: 0)

    /// `pieces`' lines by level. Bounded: the pieces.
    private static func byLevel(_ pieces: [WornPiece]) -> [[WorldRoadPiece]] {
        var buckets = Array(repeating: [WorldRoadPiece](), count: WornLevel.allCases.count)
        for piece in pieces { buckets[piece.level.rawValue].append(piece.line) }
        return buckets
    }

    /// Whether nothing worn draws.
    var isEmpty: Bool { footpaths.isEmpty && roads.isEmpty }

    static func == (lhs: WornWaysDrawing, rhs: WornWaysDrawing) -> Bool { lhs.generation == rhs.generation }

    /// The trails Home draws for its `trails` read under `stamp`: these, cut, when they were cut from that reading,
    /// else `trails` as they are.
    func trails(for trails: [[GeoPoint]], stamp: Int) -> [[GeoPoint]] {
        stamp == trailStamp ? self.trails : trails
    }
}

/// Works out a ``WornWaysDrawing`` (off the main actor; pure, so the rules are tested directly).
nonisolated enum WornWaysBuilder {
    /// The drawing of `index`'s footpaths and `ways`' roads on `today`, with `trails` cut where they run on a worn
    /// footpath.
    static func make(index: WornFootpathIndex, ways: [WornWayKey: WornTally], today: UInt16, trails: [[GeoPoint]],
                     trailStamp: Int, generation: Int) -> WornWaysDrawing {
        let paths = footpathLevels(index.tallies, today: today), roads = roadLevels(ways, today: today)
        let worn = Set(paths.compactMap { $0.value >= .one ? $0.key : nil })
        return WornWaysDrawing(generation: generation, footpaths: footpathPieces(index, levels: paths),
                               roads: roadPieces(roads), trails: split(trails, over: worn), trailStamp: trailStamp,
                               contentHash: hash(paths, salt: 1) &+ hash(roads, salt: 2))
    }

    /// The footpath level on `today` of each cell that reached level 1. Bounded: the tallies.
    static func footpathLevels(_ tallies: [HexCell: WornTally], today: UInt16) -> [HexCell: WornLevel] {
        tallies.compactMapValues { $0.level(today: today, thresholds: .footpath) }
    }

    /// The road level on `today` of each road cell that reached level 1. Bounded: at most ``WornWayRuns/maxCells``.
    static func roadLevels(_ ways: [WornWayKey: WornTally], today: UInt16) -> [HexCell: WornLevel] {
        var levels: [HexCell: WornLevel] = [:]
        for (key, tally) in ways where key.kind == .road && levels.count < WornWayRuns.maxCells {
            if let level = tally.level(today: today, thresholds: .forKind(key.kind)) { levels[key.cell] = level }
        }
        return levels
    }

    /// An order-free hash of `levels`, so two equal maps hash the same however they were filled.
    static func hash(_ levels: [HexCell: WornLevel], salt: Int) -> Int {
        var total = salt
        for (cell, level) in levels {
            var hasher = Hasher()
            hasher.combine(cell)
            hasher.combine(level)
            total = total &+ hasher.finalize()
        }
        return total
    }

    // MARK: Footpaths

    /// The footpath pieces: each drawn cell's stretch at its cell's level, neighbouring stretches of one line at one
    /// level joined into one stroke. Bounded: the kept stretches (``WornFootpathIndex/maxCells``) and ``WornWaysDrawing/maxPieces``.
    static func footpathPieces(_ index: WornFootpathIndex, levels: [HexCell: WornLevel]) -> [WornPiece] {
        let drawn = index.fragments.compactMap { cell, fragment in levels[cell].map { (cell, fragment, $0) } }
            .sorted { ($0.1.order, $0.1.seq) < ($1.1.order, $1.1.seq) }
        var pieces: [WornPiece] = []
        var run: [(x: Double, y: Double)] = []
        var last: (order: Int32, seq: Int32, level: WornLevel)?
        for (cell, fragment, level) in drawn where pieces.count < WornWaysDrawing.maxPieces {
            let points = WornFootpathIndex.points(of: fragment, in: cell)
            if let last, last.order == fragment.order, last.seq &+ 1 == fragment.seq, last.level == level {
                run += points.dropFirst()
            } else {
                if let last { pieces += chunks(run, level: last.level) }
                run = points
            }
            last = (fragment.order, fragment.seq, level)
        }
        if let last { pieces += chunks(run, level: last.level) }
        return Array(pieces.prefix(WornWaysDrawing.maxPieces))
    }

    /// `points` cut into pieces of at most ``WornWaysDrawing/maxPiecePoints`` that share their ends. Bounded: the points.
    static func chunks(_ points: [(x: Double, y: Double)], level: WornLevel) -> [WornPiece] {
        guard points.count >= 2 else { return [] }
        let step = WornWaysDrawing.maxPiecePoints - 1
        return stride(from: 0, to: points.count - 1, by: step).map { start in
            WornPiece(level: level, points: Array(points[start...min(start + step, points.count - 1)]))
        }
    }

    // MARK: Roads

    /// The road pieces: hex centre to hex centre between neighbouring frequent cells, each joint at the lower of its
    /// two cells' levels, joined into lines per level. Bounded: ``WornWaysDrawing/maxPieces``.
    static func roadPieces(_ levels: [HexCell: WornLevel]) -> [WornPiece] {
        var pieces: [WornPiece] = []
        for line in roadLines(levels) where pieces.count < WornWaysDrawing.maxPieces {
            pieces += chunks(line.cells.map { MercatorHexGrid.centre(of: $0) }, level: line.level)
        }
        return Array(pieces.prefix(WornWaysDrawing.maxPieces))
    }

    /// One joined road line: its cells in order, at one level.
    struct RoadLine: Equatable {
        let level: WornLevel
        let cells: [HexCell]
    }

    /// An edge between two neighbouring cells, smaller cell first.
    struct Edge: Hashable {
        let a: HexCell, b: HexCell
        init(_ one: HexCell, _ two: HexCell) { (a, b) = one < two ? (one, two) : (two, one) }
    }

    /// The frequent road cells joined into lines. A drive wears a band one or two cells wide whose cells all touch
    /// (triangles everywhere), so joining every pair of neighbours would draw a braid: the road is the band's spine
    /// instead (``spine(_:)``), each joint at the lower of its two cells' levels, joined into lines while the next
    /// joint carries on at the same level. A cell with no frequent neighbour draws nothing. Bounded: each joint is
    /// walked once, the cells looked at are at most ``WornWayRuns/maxCells``.
    static func roadLines(_ levels: [HexCell: WornLevel]) -> [RoadLine] {
        let joints = spine(levels)
        var next: [HexCell: [HexCell]] = [:]
        for joint in joints {
            next[joint.a, default: []].append(joint.b)
            next[joint.b, default: []].append(joint.a)
        }
        var used = Set<Edge>()
        var lines: [RoadLine] = []
        // Ends first, so a line starts where its road does.
        let starts = next.keys.sorted { (next[$0]?.count ?? 0, $0) < (next[$1]?.count ?? 0, $1) }
        for cell in starts {
            for other in next[cell] ?? [] {
                guard let mine = levels[cell], let theirs = levels[other], used.insert(Edge(cell, other)).inserted else { continue }
                let level = min(mine, theirs)
                let forward = extend(from: other, level: level, levels: levels, next: next, used: &used)
                let backward = extend(from: cell, level: level, levels: levels, next: next, used: &used)
                lines.append(RoadLine(level: level, cells: backward.reversed() + [cell, other] + forward))
            }
        }
        return lines
    }

    /// The cells a line at `level` runs on past `cell`, each over an unwalked joint whose cells' lower level is
    /// `level`. Bounded: at most ``WornWayRuns/maxCells`` steps (each walks a new joint).
    private static func extend(from cell: HexCell, level: WornLevel, levels: [HexCell: WornLevel], next: [HexCell: [HexCell]],
                               used: inout Set<Edge>) -> [HexCell] {
        var cells: [HexCell] = []
        var tip = cell
        for _ in 0..<WornWayRuns.maxCells {
            guard let tipLevel = levels[tip],
                  let step = next[tip]?.first(where: { candidate in
                      guard let theirs = levels[candidate] else { return false }
                      return min(tipLevel, theirs) == level && !used.contains(Edge(tip, candidate))
                  }) else { break }
            used.insert(Edge(tip, step))
            cells.append(step)
            tip = step
        }
        return cells
    }

    /// The joints of the cells' spine: a spanning forest grown depth first from each band's end, preferring to carry
    /// straight on, with every one-cell stub off a through cell pruned (a real road's end, a leaf whose cell carries
    /// on in one direction only, stays). Bounded: each cell is visited once and pushes at most its six neighbours, at
    /// most ``WornWayRuns/maxCells`` cells.
    static func spine(_ levels: [HexCell: WornLevel]) -> [Edge] {
        let cells = levels.keys.sorted().prefix(WornWayRuns.maxCells)
        var degree: [HexCell: Int] = [:]
        for cell in cells { degree[cell] = MercatorHexGrid.neighbours(of: cell).filter { levels[$0] != nil }.count }
        var visited = Set<HexCell>()
        var tree: [Edge] = []
        for seed in cells.sorted(by: { (degree[$0] ?? 0, $0) < (degree[$1] ?? 0, $1) }) where !visited.contains(seed) {
            var stack: [(cell: HexCell, from: HexCell?, direction: Int)] = [(seed, nil, 0)]
            for _ in 0..<(6 * cells.count + 1) {
                guard let top = stack.popLast() else { break }
                guard visited.insert(top.cell).inserted else { continue }
                if let from = top.from { tree.append(Edge(from, top.cell)) }
                let around = MercatorHexGrid.neighbours(of: top.cell)
                // Pushed most-turning first, so the straightest is popped next.
                for direction in (0..<6).sorted(by: { turn($0, top.direction) > turn($1, top.direction) })
                where levels[around[direction]] != nil && !visited.contains(around[direction]) {
                    stack.append((around[direction], top.cell, direction))
                }
            }
        }
        return pruned(tree)
    }

    /// How far direction `a` turns from `b` round the hex's six (0 straight on, 3 back).
    private static func turn(_ a: Int, _ b: Int) -> Int {
        let step = abs(a - b) % 6
        return min(step, 6 - step)
    }

    /// `tree` without its one-cell stubs: a leaf whose only neighbour has three joints or more. Bounded: the joints.
    private static func pruned(_ tree: [Edge]) -> [Edge] {
        var count: [HexCell: Int] = [:]
        for edge in tree {
            count[edge.a, default: 0] += 1
            count[edge.b, default: 0] += 1
        }
        return tree.filter { edge in
            let stubA = count[edge.a] == 1 && (count[edge.b] ?? 0) >= 3
            let stubB = count[edge.b] == 1 && (count[edge.a] ?? 0) >= 3
            return !(stubA || stubB)
        }
    }

    // MARK: Trails

    /// `trails` with every stretch over a cell of `worn` taken out, split into the runs left (two points or more).
    /// Bounded: at most ``WornFootpaths/maxPointsPerRoute`` points a trail, each segment cut into at most 256 steps.
    static func split(_ trails: [[GeoPoint]], over worn: Set<HexCell>) -> [[GeoPoint]] {
        guard !worn.isEmpty else { return trails }
        var runs: [[GeoPoint]] = []
        for trail in trails {
            var run: [GeoPoint] = []
            var from = trail.first
            for point in trail.prefix(WornFootpaths.maxPointsPerRoute).dropFirst() {
                guard let start = from else { break }
                let steps = min(256, max(1, Int((start.distance(to: point) / WornFootpaths.sampleStep).rounded(.up))))
                var a = start
                for step in 1...steps {
                    let b = start.lerp(to: point, Double(step) / Double(steps))
                    if worn.contains(MercatorHexGrid.cell(containing: a.lerp(to: b, 0.5))) {
                        if run.count >= 2 { runs.append(run) }
                        run = []
                    } else {
                        if run.isEmpty { run = [a] }
                        run.append(b)
                    }
                    a = b
                }
                from = point
            }
            if run.count >= 2 { runs.append(run) }
        }
        return runs
    }

    // MARK: Your world

    /// The passport's Your world roads (owner's call 4): the runs of road cells at level 1 or more on `today` at least
    /// ``WornWayRuns/minimumRunMetres`` long, joined into lines, as crossed-road pieces in Mercator units.
    static func yourWorldRoads(_ ways: [WornWayKey: WornTally], today: UInt16, generation: Int) -> WorldRoadDrawing {
        let frequent = roadLevels(ways, today: today).filter { $0.value >= .one }
        let runs = WornWayRuns.longRuns(Set(frequent.keys))
        guard !runs.isEmpty else { return WorldRoadDrawing(generation: generation, pieces: [], roadCount: 0) }
        var kept: [HexCell: WornLevel] = [:]
        for run in runs { for cell in run { kept[cell] = .one } }
        let pieces = roadPieces(kept).map(\.line)
        return WorldRoadDrawing(generation: generation, pieces: pieces, roadCount: runs.count)
    }
}
