import Foundation
import WorldMapStore

/// The worn footpaths' working memory (Docs/World-Frequent-Paths-Exploration-2026-11-15.md §8, option A): each cell's
/// tally from the saved walk, run and ride lines (``WornFootpaths``' rules, replayed oldest first), and, for each cell
/// walked often enough to show, the stretch of the newest line through it, which the map draws. Held in memory only and
/// derived again from the sealed route files after a relaunch, so every delete of a line or of the map history removes
/// it too.
///
/// Lines are added one at a time, oldest first (``takesInOrder(_:)``): a new walk folds in without re-reading the
/// rest. A line that goes away, or one older than the newest already folded, starts the index again.
nonisolated struct WornFootpathIndex: Sendable {
    /// The most cells whose stretch is kept (the fog's own cap).
    static let maxCells = 250_000
    /// The most points one cell's stretch keeps (a cell is 35 m across; lines are thinned at 2.5 m).
    static let maxFragmentPoints = 8

    /// One cell's stretch of one line: where the line runs inside the cell, as Mercator offsets from the cell's
    /// centre (x, y interleaved, `Float` to keep a full history to a few MB), and which line and which of its cells
    /// it came from, so neighbouring stretches of one line join into one stroke.
    struct Fragment: Sendable, Equatable {
        /// The line's place in the order lines were added.
        let order: Int32
        /// The stretch's place along its line (one step per cell the line enters).
        let seq: Int32
        /// The points, as offsets from the cell's centre: x0, y0, x1, y1, …
        let offsets: [Float]
    }

    /// Each walked cell's tally.
    private(set) var tallies: [HexCell: WornTally] = [:]
    /// The stretch of the newest line through each cell that reached level 1.
    private(set) var fragments: [HexCell: Fragment] = [:]
    /// The lines folded in so far, by workout, with their day.
    private(set) var days: [UUID: UInt16] = [:]
    /// The latest day folded in.
    private(set) var latestDay: UInt16 = 0
    /// The next line's order.
    private var nextOrder: Int32 = 0

    /// Whether a line from `day` can be folded in now without replaying the others (it is no older than the newest).
    func takesInOrder(_ day: UInt16) -> Bool {
        days.isEmpty || day >= latestDay
    }

    /// Folds in workout `id`'s `line`, walked on `day` (a line already folded, or past ``WornFootpaths/maxRoutes``,
    /// does nothing). An empty line is recorded with nothing drawn (a file that could not be opened).
    mutating func add(_ id: UUID, day: UInt16, line: [GeoPoint]) {
        guard days[id] == nil, days.count < WornFootpaths.maxRoutes else { return }
        days[id] = day
        latestDay = max(latestDay, day)
        let order = nextOrder
        nextOrder &+= 1
        guard line.count >= 2 else { return }
        // Bounded: the line's cells (WornFootpaths.cells caps the points and the samples per segment).
        for cell in WornFootpaths.cells(along: line) {
            if var tally = tallies[cell] {
                tally.pass(on: day, thresholds: .footpath)
                tallies[cell] = tally
            } else {
                tallies[cell] = .first(on: day)
            }
        }
        addFragments(line, order: order)
    }

    /// Cuts `line` into one stretch per cell it enters (a cell entered again later in the same line keeps its first
    /// stretch) and keeps each over the older line's stretch, for the cells that reached level 1. Bounded: at most
    /// ``WornFootpaths/maxPointsPerRoute`` points, each segment cut into at most 256 steps of
    /// ``WornFootpaths/sampleStep`` metres.
    private mutating func addFragments(_ line: [GeoPoint], order: Int32) {
        guard let first = line.first else { return }
        var entered = Set<HexCell>()
        var cell: HexCell?
        var points: [(x: Double, y: Double)] = []
        var seq: Int32 = 0
        var from = WebMercator.unit(first)
        var fromGeo = first
        for point in line.prefix(WornFootpaths.maxPointsPerRoute).dropFirst() {
            let to = WebMercator.unit(point)
            let steps = min(256, max(1, Int((fromGeo.distance(to: point) / WornFootpaths.sampleStep).rounded(.up))))
            var a = from
            for step in 1...steps {
                let t = Double(step) / Double(steps)
                let b = (x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t)
                let here = MercatorHexGrid.cell(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
                if here != cell {
                    if let done = cell { keep(points, in: done, order: order, seq: seq) }
                    seq &+= 1
                    cell = here
                    points = entered.insert(here).inserted ? [a] : []
                }
                if !points.isEmpty { points.append(b) }
                a = b
            }
            from = to
            fromGeo = point
        }
        if let done = cell { keep(points, in: done, order: order, seq: seq) }
    }

    /// Keeps `points` as `cell`'s stretch when the cell has reached level 1 and there is room. Over
    /// ``maxFragmentPoints`` the middle is thinned evenly, keeping both ends.
    private mutating func keep(_ points: [(x: Double, y: Double)], in cell: HexCell, order: Int32, seq: Int32) {
        guard points.count >= 2, let tally = tallies[cell],
              WornThresholds.footpath.level(forCount: tally.count) != nil,
              fragments[cell] != nil || fragments.count < Self.maxCells else { return }
        let centre = MercatorHexGrid.centre(of: cell)
        let kept = Self.thinned(points, to: Self.maxFragmentPoints)
        var offsets: [Float] = []
        offsets.reserveCapacity(kept.count * 2)
        for point in kept {
            offsets.append(Float(point.x - centre.x))
            offsets.append(Float(point.y - centre.y))
        }
        fragments[cell] = Fragment(order: order, seq: seq, offsets: offsets)
    }

    /// `points` thinned evenly to at most `limit` (both ends kept). Bounded: `limit` picks.
    static func thinned(_ points: [(x: Double, y: Double)], to limit: Int) -> [(x: Double, y: Double)] {
        guard points.count > limit, limit >= 2 else { return points }
        let last = points.count - 1
        return (0..<limit).map { points[$0 * last / (limit - 1)] }
    }

    /// `fragment`'s points in `cell`, back in Mercator units.
    static func points(of fragment: Fragment, in cell: HexCell) -> [(x: Double, y: Double)] {
        let centre = MercatorHexGrid.centre(of: cell)
        return stride(from: 0, to: fragment.offsets.count - 1, by: 2).map { index in
            (centre.x + Double(fragment.offsets[index]), centre.y + Double(fragment.offsets[index + 1]))
        }
    }
}

/// The one ``WornFootpathIndex`` a ``WornWaysModel`` grows, held by reference so a batch folded in off the main actor
/// mutates it in place instead of copying a full history. Only one task touches it at a time: the model runs its
/// updates one after another and reads it only between them.
nonisolated final class WornFootpathIndexBox: @unchecked Sendable {
    /// The index.
    var index = WornFootpathIndex()
}
