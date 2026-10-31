import Foundation

/// A polygon's edges bucketed by latitude band, built once when the polygon is decoded, so the point test
/// walks only the edges whose latitude span reaches the point's band instead of every ring point.
///
/// The even-odd rule toggles on an edge only when the point's latitude `y` lies in `[low, high)` of the
/// edge's two latitudes, so an edge that never reaches `y`'s band cannot toggle; every edge that could is
/// listed in each band its span touches, once. ``AtlasPolygon/contains(_:)`` applies the very same test to
/// those edges, in a different order, and toggling commutes, so its answer is the whole walk's, bit for bit
/// (`WorldAtlasEdgeBandsTests` compares the two over the shipped pack).
///
/// Bounded: at most ``maxBands`` bands; building is one pass over the edges to count and one to fill, and
/// the entries are capped at ``maxEntriesPerEdge`` an edge (past that the index keeps a single band, which
/// is the whole walk).
nonisolated struct AtlasEdgeBands: Hashable, Sendable {
    /// The most bands one polygon gets (Russia, the largest outline, has about 63,000 points).
    static let maxBands = 4_096
    /// About how many points each band is given: a polygon of `n` points gets `n / 8` bands.
    static let pointsPerBand = 8
    /// The most entries the index may hold for each edge, on average, before it falls back to one band.
    static let maxEntriesPerEdge = 16
    /// Set on an entry that names a ring's closing edge (its last point back to its first) by ring number.
    static let closingFlag: UInt32 = 0x8000_0000

    /// The south edge of band 0, in 1e-5 degrees.
    let south: Double
    /// Each band's height, in 1e-5 degrees.
    let height: Double
    /// How many bands.
    let count: Int
    /// Where each band's entries start in ``entries`` (`count + 1` values, the last the total).
    let starts: [Int32]
    /// Each band's edges, band after band: an edge's current point index (its previous point the one before
    /// it), or ``closingFlag`` and a ring number for that ring's closing edge.
    let entries: [UInt32]

    /// The index of the rings `ringEnds` closes off in `lats`, over the box from `south` to `north`.
    init(lats: [Int32], ringEnds: [Int], south: Int32, north: Int32) {
        let wanted = min(max(lats.count / Self.pointsPerBand, 1), Self.maxBands)
        let edges = Self.edgeCount(lats: lats, ringEnds: ringEnds)
        let made = Self.build(lats: lats, ringEnds: ringEnds, south: south, north: north, bands: wanted,
                              cap: edges * Self.maxEntriesPerEdge)
        // A pathological outline (very long edges in a many-banded box) keeps one band: the whole walk.
        let index = made ?? Self.build(lats: lats, ringEnds: ringEnds, south: south, north: north, bands: 1,
                                       cap: edges)
        self = index ?? AtlasEdgeBands(south: Double(south), height: 1, count: 1, starts: [0, 0], entries: [])
    }

    /// An index with every field given.
    private init(south: Double, height: Double, count: Int, starts: [Int32], entries: [UInt32]) {
        self.south = south
        self.height = height
        self.count = count
        self.starts = starts
        self.entries = entries
    }

    /// The band latitude `y` (1e-5 degrees) falls in, clamped to the index. Monotonic in `y`, which is what
    /// makes listing an edge in the bands from its low end's to its high end's enough.
    func band(of y: Double) -> Int {
        Self.band(of: y, south: south, height: height, count: count)
    }

    /// The edges of band `band` to test, as a range of ``entries``; empty for a band out of range.
    func slots(of band: Int) -> Range<Int> {
        guard band >= 0, band + 1 < starts.count else { return 0..<0 }
        let low = Int(starts[band]), high = Int(starts[band + 1])
        return low <= high && high <= entries.count ? low..<high : 0..<0
    }

    // MARK: Building

    /// The band of `y` for an index of `count` bands of `height` from `south`.
    private static func band(of y: Double, south: Double, height: Double, count: Int) -> Int {
        let position = ((y - south) / height).rounded(.down)
        guard position.isFinite, position > 0 else { return 0 }
        return position >= Double(count - 1) ? count - 1 : Int(position)
    }

    /// How many edges the point test walks: one per point of every ring of three points or more.
    private static func edgeCount(lats: [Int32], ringEnds: [Int]) -> Int {
        var total = 0, start = 0
        // Bounded: one step per ring (capped at decode).
        for end in ringEnds {
            if end - start >= 3 { total += end - start }
            start = end
        }
        return total
    }

    /// The index with `bands` bands, or nil when it would hold more than `cap` entries (or an outline too big
    /// for an entry to name its points, which leaves ``init(lats:ringEnds:south:north:)`` an empty index).
    private static func build(lats: [Int32], ringEnds: [Int], south: Int32, north: Int32, bands: Int,
                              cap: Int) -> AtlasEdgeBands? {
        // An entry holds a point index or a ring number below the flag bit (a 7 MiB pack holds far fewer).
        guard bands >= 1, lats.count < Int(closingFlag), ringEnds.count < Int(closingFlag) else { return nil }
        let height = max(Double(north) - Double(south), 1) / Double(bands)
        let bandOf = { (y: Int32) in band(of: Double(y), south: Double(south), height: height, count: bands) }
        var tally = [Int](repeating: 0, count: bands + 1), total = 0
        forEachEdge(lats: lats, ringEnds: ringEnds) { low, high, _ in
            let first = bandOf(low), last = bandOf(high)
            tally[first] += 1
            tally[last + 1] -= 1
            total += last - first + 1
        }
        guard total <= cap, total < Int(Int32.max) else { return nil }
        var starts = [Int32](repeating: 0, count: bands + 1), running = 0, open = 0
        // Bounded: one step per band (at most maxBands).
        for slot in 0..<bands {
            starts[slot] = Int32(running)
            open += tally[slot]
            running += open
        }
        starts[bands] = Int32(running)
        var cursor = starts.map(Int.init), entries = [UInt32](repeating: 0, count: running)
        forEachEdge(lats: lats, ringEnds: ringEnds) { low, high, entry in
            // Bounded: the edge's bands, at most `bands`; all of them together at most `cap`.
            for slot in bandOf(low)...bandOf(high) {
                entries[cursor[slot]] = entry
                cursor[slot] += 1
            }
        }
        return AtlasEdgeBands(south: Double(south), height: height, count: bands, starts: starts, entries: entries)
    }

    /// Calls `body` with each walked edge's lower and higher latitude and its entry, ring by ring, skipping
    /// rings of under three points as the point test does.
    private static func forEachEdge(lats: [Int32], ringEnds: [Int],
                                    _ body: (_ low: Int32, _ high: Int32, _ entry: UInt32) -> Void) {
        var start = 0
        // Bounded: every ring once, every point once (rings and points capped at decode).
        for (ring, end) in ringEnds.enumerated() {
            guard end - start >= 3, end <= lats.count else { start = end; continue }
            var previous = end - 1
            for current in start..<end {
                let entry = current == start ? closingFlag | UInt32(ring) : UInt32(current)
                body(min(lats[current], lats[previous]), max(lats[current], lats[previous]), entry)
                previous = current
            }
            start = end
        }
    }
}
