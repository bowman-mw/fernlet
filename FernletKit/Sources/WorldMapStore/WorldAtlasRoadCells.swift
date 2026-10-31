import Foundation

// The crossing rule read from the fog history (World-Exploration-Spec §2, `ex-roads`; lane explore-ui's call,
// 2026-10-30): a major road counts as crossed when one of the person's lifted fog cells lies on its line. Nothing
// is stored for it: the answer is derived from the lifted cells each time they change, so it follows every wipe and
// a decoy's own cells by itself, and needs no file, key or backup of its own.

/// Which major roads (``WorldAtlas/roads``) the lifted fog cells lie on: a cell lies on a road when its centre is
/// within one cell radius (``MercatorHexGrid/radius``, centre to corner) of one of the road's segments, measured in
/// Web Mercator, which keeps shapes. A route that goes from one side of a road's line to the other lifts a chain of
/// touching cells, so one of them always lies on the line; the gap-closer fills the single cells a fast walk skips.
///
/// The work goes one one-degree cell of the road index at a time: the lifted cells are grouped by the one-degree
/// cell holding their centre (and its neighbour when the centre sits within a cell radius of the line between
/// them), only one-degree cells that hold road segments are read, and inside each the segments are bucketed on a
/// ``fineSide`` × ``fineSide`` grid so a cell is measured against the few segments near it. Each one-degree cell's
/// answer is kept with a signature of its lifted cells, so the next ``update(cells:atlas:)`` re-reads only the
/// one-degree cells whose lifted cells changed. A value type: the app keeps one, hands a copy and the cells to a
/// background task, and takes the updated copy back.
///
/// Bounded (Power of 10): at most ``maxCells`` lifted cells are read; each segment is listed in at most
/// ``fineSide``² buckets; every other loop runs over the road index's own, decode-capped lists.
public nonisolated struct AtlasRoadCrossings: Sendable {
    /// The most lifted cells one update reads (the fog store's own cap, `FogCellStore.maxCells`).
    public static let maxCells = 250_000
    /// The buckets per side a one-degree cell's segments are sorted into (about 3.5 × 2.4 km each at 45°).
    public static let fineSide = 32

    /// One one-degree cell's answer: a signature of the lifted cells read there, their count, and the roads they
    /// lie on (indices into ``WorldAtlas/roads``, ascending).
    struct Entry: Sendable, Equatable {
        let signature: UInt64
        let count: Int
        let roads: [Int32]
    }

    /// The lifted cells of one one-degree cell, in Mercator, and their signature.
    struct Group {
        var points: [(x: Double, y: Double)] = []
        var signature: UInt64 = 0
    }

    /// Each read one-degree cell's answer, by the road index's key (row × 360 + column).
    private(set) var entries: [Int: Entry] = [:]
    /// The crossed roads, as indices into ``WorldAtlas/roads``, ascending, each once.
    public private(set) var roadIndices: [Int32] = []

    /// No road crossed.
    public init() {}

    /// The roads `cells` lie on in `atlas`, worked out afresh.
    public init(cells: some Sequence<HexCell>, atlas: WorldAtlas) {
        update(cells: cells, atlas: atlas)
    }

    /// How many roads are crossed.
    public var count: Int { roadIndices.count }

    /// Whether no road is crossed.
    public var isEmpty: Bool { roadIndices.isEmpty }

    /// How many one-degree cells were read (the cache's size; tests).
    var readCellCount: Int { entries.count }

    /// The crossed roads themselves, in table order.
    public func roads(in atlas: WorldAtlas) -> [AtlasRoad] {
        roadIndices.compactMap { atlas.roads.indices.contains(Int($0)) ? atlas.roads[Int($0)] : nil }
    }

    /// The crossed roads' frozen tokens.
    public func tokens(in atlas: WorldAtlas) -> Set<String> {
        Set(roads(in: atlas).map(\.token))
    }

    /// Works the crossed roads out for `cells` (the whole lifted history, or a decoy's own cells), re-reading only
    /// the one-degree cells whose lifted cells changed since the last update. An empty sequence empties it.
    public mutating func update(cells: some Sequence<HexCell>, atlas: WorldAtlas) {
        let groups = Self.group(cells, index: atlas.roadGrid)
        var next: [Int: Entry] = [:]
        // Bounded: one entry per one-degree cell holding lifted cells and road segments.
        for (key, group) in groups {
            if let kept = entries[key], kept.signature == group.signature, kept.count == group.points.count {
                next[key] = kept
                continue
            }
            let roads = Self.roadsUnder(group.points, key: key, atlas: atlas)
            next[key] = Entry(signature: group.signature, count: group.points.count, roads: roads)
        }
        entries = next
        roadIndices = Array(Set(next.values.flatMap(\.roads))).sorted()
    }

    // MARK: Grouping

    /// The lifted cells' centres by one-degree cell, keeping only the one-degree cells the road index lists.
    static func group(_ cells: some Sequence<HexCell>, index: AtlasRoadIndex) -> [Int: Group] {
        var groups: [Int: Group] = [:]
        let radius = MercatorHexGrid.radius
        // Bounded: at most maxCells cells, each in at most four one-degree cells.
        for cell in cells.prefix(maxCells) {
            let centre = MercatorHexGrid.centre(of: cell)
            let mix = UInt64(bitPattern: cell.id) &* 0x9E37_79B9_7F4A_7C15
            for key in keys(near: centre, radius: radius) where index.cells[key] != nil {
                groups[key, default: Group()].points.append(centre)
                groups[key, default: Group()].signature ^= mix
            }
        }
        return groups
    }

    /// The one-degree keys within `radius` (Mercator) of the Mercator point `centre`: its own, and the neighbours
    /// across a degree line closer than that. At most four.
    static func keys(near centre: (x: Double, y: Double), radius: Double) -> [Int] {
        let west = WebMercator.geo(x: centre.x - radius, y: centre.y + radius)
        let east = WebMercator.geo(x: centre.x + radius, y: centre.y - radius)
        let columns = Set([AtlasRoadIndex.column(west.longitude), AtlasRoadIndex.column(east.longitude)])
        let rows = Set([AtlasRoadIndex.row(east.latitude), AtlasRoadIndex.row(west.latitude)])
        var keys: [Int] = []
        for row in rows.sorted() {
            for column in columns.sorted() { keys.append(row * 360 + column) }
        }
        return keys
    }

    // MARK: Measuring

    /// A segment of one road in Mercator, with its road's index.
    struct MercatorSegment {
        let road: Int32
        let a: (x: Double, y: Double)
        let b: (x: Double, y: Double)
    }

    /// The roads whose segments in one-degree cell `key` lie within a cell radius of any of `points`, ascending.
    static func roadsUnder(_ points: [(x: Double, y: Double)], key: Int, atlas: WorldAtlas) -> [Int32] {
        guard let listed = atlas.roadGrid.cells[key], !points.isEmpty else { return [] }
        let segments = mercatorSegments(listed, roads: atlas.roads)
        let box = mercatorBox(key: key)
        let radius = MercatorHexGrid.radius
        let buckets = bucket(segments, box: box, radius: radius)
        var found = Set<Int32>()
        // Bounded: the group's points (at most maxCells), each against one bucket's segments.
        for point in points {
            guard let slot = slot(of: point, in: box) else { continue }
            for index in buckets[slot] ?? [] where !found.contains(segments[index].road) {
                let segment = segments[index]
                if distance(point, segment.a, segment.b) <= radius { found.insert(segment.road) }
            }
        }
        return found.sorted()
    }

    /// The index's segments as Mercator lines (a segment whose point is out of its road's range is skipped).
    static func mercatorSegments(_ listed: [AtlasRoadIndex.Segment], roads: [AtlasRoad]) -> [MercatorSegment] {
        let scale = AtlasPolygon.unitsPerDegree
        return listed.compactMap { segment in
            guard roads.indices.contains(Int(segment.road)) else { return nil }
            let road = roads[Int(segment.road)], point = Int(segment.point)
            guard point >= 0, point + 1 < road.lons.count, point + 1 < road.lats.count else { return nil }
            let a = WebMercator.unit(GeoPoint(Double(road.lats[point]) / scale, Double(road.lons[point]) / scale))
            let b = WebMercator.unit(GeoPoint(Double(road.lats[point + 1]) / scale, Double(road.lons[point + 1]) / scale))
            return MercatorSegment(road: segment.road, a: a, b: b)
        }
    }

    /// One-degree cell `key`'s box in Mercator: west, north (smaller y), and its width and height.
    static func mercatorBox(key: Int) -> (x: Double, y: Double, width: Double, height: Double) {
        let row = key / 360, column = key % 360
        let north = WebMercator.unit(GeoPoint(90 - Double(row), -180 + Double(column)))
        let south = WebMercator.unit(GeoPoint(89 - Double(row), -179 + Double(column)))
        return (north.x, north.y, max(south.x - north.x, 1e-12), max(south.y - north.y, 1e-12))
    }

    /// The fine bucket (row × fineSide + column) holding `point`, or nil outside the box.
    static func slot(of point: (x: Double, y: Double), in box: (x: Double, y: Double, width: Double, height: Double)) -> Int? {
        let column = Int(((point.x - box.x) / box.width * Double(fineSide)).rounded(.down))
        let row = Int(((point.y - box.y) / box.height * Double(fineSide)).rounded(.down))
        guard (0..<fineSide).contains(column), (0..<fineSide).contains(row) else { return nil }
        return row * fineSide + column
    }

    /// Each segment listed in every fine bucket its box, grown by `radius`, touches (clamped to the box).
    static func bucket(_ segments: [MercatorSegment], box: (x: Double, y: Double, width: Double, height: Double),
                       radius: Double) -> [Int: [Int]] {
        var buckets: [Int: [Int]] = [:]
        let side = Double(fineSide)
        func clamp(_ value: Double) -> Int { min(max(Int(value.rounded(.down)), 0), fineSide - 1) }
        // Bounded: each segment in at most fineSide² buckets.
        for (index, segment) in segments.enumerated() {
            let west = clamp((min(segment.a.x, segment.b.x) - radius - box.x) / box.width * side)
            let east = clamp((max(segment.a.x, segment.b.x) + radius - box.x) / box.width * side)
            let north = clamp((min(segment.a.y, segment.b.y) - radius - box.y) / box.height * side)
            let south = clamp((max(segment.a.y, segment.b.y) + radius - box.y) / box.height * side)
            for row in north...south {
                for column in west...east { buckets[row * fineSide + column, default: []].append(index) }
            }
        }
        return buckets
    }

    /// The distance from `p` to the segment `a`–`b`, in the same units.
    static func distance(_ p: (x: Double, y: Double), _ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y
        let length = dx * dx + dy * dy
        let t = length > 0 ? min(max(((p.x - a.x) * dx + (p.y - a.y) * dy) / length, 0), 1) : 0
        let ex = p.x - (a.x + t * dx), ey = p.y - (a.y + t * dy)
        return (ex * ex + ey * ey).squareRoot()
    }
}
