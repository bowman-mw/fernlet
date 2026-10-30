import Foundation

// The pack's `ROAD` section (Docs/World-Atlas-Pack.md): Natural Earth's major roads, for the approved major-road
// style (World-Exploration-Spec §2, `ex-roads`: "Only motorway, trunk and primary roads"; once the route crosses
// one, the whole road turns amber). The section holds the lines; the rule "a road counts as discovered when the
// route has crossed it" is ``WorldAtlas/roadsCrossed(from:to:)``, which the route's consecutive accepted fixes
// feed.

/// How important a major road is, from Natural Earth's own ranking (its roads carry no OSM classes).
public nonisolated enum AtlasRoadKind: UInt8, CaseIterable, Sendable {
    /// Motorway or trunk: Natural Earth's "Major Highway", "Beltway" and "Bypass", and its expressways.
    case highway = 1
    /// Primary: any other road Natural Earth ranks 5 or more important (`SCALERANK` <= 5).
    case mainRoad = 2
}

/// One major road from the pack's `ROAD` section: a named route's touching pieces ("I-80"), or an unnamed
/// stretch between junctions, as one or more lines. What turns amber "whole" once crossed.
public nonisolated struct AtlasRoad: Hashable, Sendable {
    /// The frozen token: "ne:road:" and the road's number in the pack (its smallest piece's record number in
    /// the pinned Natural Earth roads file).
    public let token: String
    /// Highway or main road.
    public let kind: AtlasRoadKind
    /// West, south, east, north edges in 1e-5 degrees, over every line.
    public let minLon: Int32, minLat: Int32, maxLon: Int32, maxLat: Int32
    /// Every line's longitudes, end to end, in 1e-5 degrees.
    let lons: [Int32]
    /// Every line's latitudes, end to end.
    let lats: [Int32]
    /// Where each line ends in ``lons`` and ``lats``.
    let lineEnds: [Int]

    /// The prefix of every road token.
    public static let tokenPrefix = "ne:road:"

    /// The token of road number `number`.
    public static func token(number: UInt32) -> String {
        tokenPrefix + String(number)
    }

    /// Whether `token` has a road token's shape: "ne:road:" and one to ten digits.
    public static func isValidToken(_ token: String) -> Bool {
        let bytes = Array(token.utf8), prefix = Array(tokenPrefix.utf8)
        guard bytes.count > prefix.count, bytes.count <= prefix.count + 10,
              Array(bytes[0..<prefix.count]) == prefix else { return false }
        return bytes[prefix.count...].allSatisfy { $0 >= 0x30 && $0 <= 0x39 }
    }

    /// How many lines the road has.
    public var lineCount: Int { lineEnds.count }

    /// Line `index`'s points in order, for a screen to draw the road; empty for an index out of range.
    public func line(_ index: Int) -> [GeoPoint] {
        guard lineEnds.indices.contains(index) else { return [] }
        let start = index == 0 ? 0 : lineEnds[index - 1], end = lineEnds[index]
        guard start <= end, end <= lons.count, end <= lats.count else { return [] }
        let scale = AtlasPolygon.unitsPerDegree
        // Bounded: one line, at most WorldAtlasLayers.maxRoadPoints points.
        return (start..<end).map { GeoPoint(Double(lats[$0]) / scale, Double(lons[$0]) / scale) }
    }

    /// A road with every field given (the decoder, and tests).
    init(token: String, kind: AtlasRoadKind, lons: [Int32], lats: [Int32], lineEnds: [Int]) {
        self.token = token
        self.kind = kind
        self.lons = lons
        self.lats = lats
        self.lineEnds = lineEnds
        minLon = lons.min() ?? 0
        maxLon = lons.max() ?? 0
        minLat = lats.min() ?? 0
        maxLat = lats.max() ?? 0
    }
}

extension WorldAtlasLayers {
    /// The most roads (the shipped pack has about 9,000).
    static let maxRoads = 65_536
    /// The most lines one road may have.
    static let maxRoadLines = 8_192
    /// The most points one line may have (a u16 count); a line needs two.
    static let maxRoadPoints = 65_535
    /// The most points in all the roads (the shipped pack has about 60,000).
    static let maxRoadPointsTotal = 1_000_000

    /// `ROAD`: each road's number, kind and lines, in number order. Refuses a count over a cap, a number out of
    /// order or repeated, an unknown kind, a road with no line, a line under two points, and any point off the
    /// globe.
    static func roads(_ bytes: [UInt8]) throws -> [AtlasRoad] {
        var reader = AtlasByteReader(bytes, tag: "ROAD")
        let count = Int(try reader.u32())
        guard count <= maxRoads else { throw WorldAtlasPackError.malformed("ROAD", "count") }
        var roads: [AtlasRoad] = []
        var last: UInt32?, total = 0
        // Bounded: count <= maxRoads.
        for _ in 0..<count {
            let number = try reader.u32()
            guard last.map({ number > $0 }) ?? true else { throw WorldAtlasPackError.malformed("ROAD", "number") }
            last = number
            guard let kind = AtlasRoadKind(rawValue: try reader.u8()) else {
                throw WorldAtlasPackError.malformed("ROAD", "kind")
            }
            let lineCount = Int(try reader.u16())
            guard lineCount >= 1, lineCount <= maxRoadLines else { throw WorldAtlasPackError.malformed("ROAD", "lineCount") }
            var lons: [Int32] = [], lats: [Int32] = [], ends: [Int] = []
            // Bounded: lineCount <= maxRoadLines.
            for _ in 0..<lineCount {
                try readRoadLine(from: &reader, lons: &lons, lats: &lats)
                ends.append(lons.count)
            }
            total += lons.count
            guard total <= maxRoadPointsTotal else { throw WorldAtlasPackError.malformed("ROAD", "pointCount") }
            roads.append(AtlasRoad(token: AtlasRoad.token(number: number), kind: kind, lons: lons, lats: lats,
                                   lineEnds: ends))
        }
        try reader.expectEnd()
        return roads
    }

    /// Reads one line (`u16 pointCount · first point · deltas`) onto the end of `lons` and `lats`.
    private static func readRoadLine(from reader: inout AtlasByteReader, lons: inout [Int32], lats: inout [Int32]) throws {
        let count = Int(try reader.u16())
        // Each delta pair is at least two bytes, so a count the bytes cannot hold is refused before looping.
        guard count >= 2, count <= maxRoadPoints, count - 1 <= reader.remaining / 2 else {
            throw WorldAtlasPackError.malformed("ROAD", "pointCount")
        }
        var lon = Int64(try reader.i32()), lat = Int64(try reader.i32())
        // Bounded: count <= maxRoadPoints.
        for slot in 0..<count {
            if slot > 0 {
                let east = try reader.zigzag(), north = try reader.zigzag()
                guard east.magnitude <= 36_000_000, north.magnitude <= 18_000_000 else {
                    throw WorldAtlasPackError.malformed("ROAD", "delta")
                }
                lon += east
                lat += north
            }
            guard lon.magnitude <= 18_000_000, lat.magnitude <= 9_000_000 else {
                throw WorldAtlasPackError.malformed("ROAD", "point")
            }
            lons.append(Int32(lon))
            lats.append(Int32(lat))
        }
    }
}

/// The roads' segments bucketed by one-degree cell, for the crossing rule: each segment (two consecutive points
/// of one line) is listed in every cell its box touches. Built once with the atlas. Bounded: a segment whose box
/// spans more than ``maxCellsPerSegment`` cells is refused at decode (the shipped pack's longest spans a few).
nonisolated struct AtlasRoadIndex: Sendable {
    /// The most one-degree cells one segment may touch.
    static let maxCellsPerSegment = 1_024

    /// One segment: its road's index into the roads, and its first point's index into that road's points.
    struct Segment: Hashable, Sendable {
        let road: Int32
        let point: Int32
    }

    /// Cell key (row × 360 + column, from 90°N and 180°W) to the segments touching it.
    let cells: [Int: [Segment]]

    /// The index of `roads`, or ``WorldAtlasPackError/malformed(_:_:)`` for a segment too long to index.
    init(roads: [AtlasRoad]) throws {
        var cells: [Int: [Segment]] = [:]
        // Bounded: every road's points, capped at decode (maxRoadPointsTotal), each once.
        for (roadIndex, road) in roads.enumerated() {
            var start = 0
            for end in road.lineEnds {
                for point in start..<max(start, end - 1) {
                    let keys = try Self.keys(lon0: road.lons[point], lat0: road.lats[point],
                                             lon1: road.lons[point + 1], lat1: road.lats[point + 1])
                    for key in keys { cells[key, default: []].append(Segment(road: Int32(roadIndex), point: Int32(point))) }
                }
                start = end
            }
        }
        self.cells = cells
    }

    /// The cells the box of a segment from (`lon0`, `lat0`) to (`lon1`, `lat1`) touches, in 1e-5 degrees.
    static func keys(lon0: Int32, lat0: Int32, lon1: Int32, lat1: Int32) throws -> [Int] {
        let scale = AtlasPolygon.unitsPerDegree
        let west = column(Double(min(lon0, lon1)) / scale), east = column(Double(max(lon0, lon1)) / scale)
        let north = row(Double(max(lat0, lat1)) / scale), south = row(Double(min(lat0, lat1)) / scale)
        guard (east - west + 1) * (south - north + 1) <= maxCellsPerSegment else {
            throw WorldAtlasPackError.malformed("ROAD", "segment")
        }
        var keys: [Int] = []
        for row in north...south {
            for column in west...east { keys.append(row * 360 + column) }
        }
        return keys
    }

    /// The one-degree column of `longitude` (0 at 180°W, 359 at the last degree).
    static func column(_ longitude: Double) -> Int {
        min(max(Int((longitude + 180).rounded(.down)), 0), 359)
    }

    /// The one-degree row of `latitude` (0 at 90°N, 179 at the last degree).
    static func row(_ latitude: Double) -> Int {
        min(max(Int((90 - latitude).rounded(.down)), 0), 179)
    }
}

/// The road lookups: by token (one dictionary read), by viewport (one pass over the table), and the crossing rule
/// (a route segment's few one-degree cells of ``AtlasRoadIndex``).
extension WorldAtlas {
    /// The longest route segment the crossing rule reads, in metres: two consecutive accepted fixes farther apart
    /// are a gap in the route (the phone was off, or a flight), not a road crossed.
    public static let maxCrossingSegmentMetres = 5_000.0

    /// The road whose frozen token is `token`, or nil.
    public func road(token: String) -> AtlasRoad? {
        guard let index = roadIndex[token], roads.indices.contains(index) else { return nil }
        return roads[index]
    }

    /// The roads whose boxes touch `viewport`, for the screen to draw. One pass over the table.
    public func roads(overlapping viewport: MapViewport) -> [AtlasRoad] {
        guard let box = AtlasGeoBox(viewport: viewport) else { return [] }
        return roads.filter { box.overlaps(minLon: $0.minLon, minLat: $0.minLat, maxLon: $0.maxLon, maxLat: $0.maxLat) }
    }

    /// The roads the route segment from `start` to `end` (two consecutive accepted fixes) crosses or touches, in
    /// table order, each once: a road counts as discovered when the route has crossed it (World-Exploration
    /// ideas, idea 2). Nothing for an invalid point, a segment longer than ``maxCrossingSegmentMetres``, or one
    /// that crosses the antimeridian. Natural Earth's lines sit within a few hundred metres of the real road, so a
    /// route that goes from one side of a road to the other crosses its line.
    public func roadsCrossed(from start: GeoPoint, to end: GeoPoint) -> [AtlasRoad] {
        guard start.isValid, end.isValid, abs(end.longitude - start.longitude) < 180,
              Self.separation(start, end) <= Self.maxCrossingSegmentMetres else { return [] }
        let scale = AtlasPolygon.unitsPerDegree
        let a = (x: start.longitude * scale, y: start.latitude * scale), b = (x: end.longitude * scale, y: end.latitude * scale)
        guard let keys = try? AtlasRoadIndex.keys(lon0: Int32(a.x.rounded()), lat0: Int32(a.y.rounded()),
                                                  lon1: Int32(b.x.rounded()), lat1: Int32(b.y.rounded())) else { return [] }
        var found = Set<Int32>()
        // Bounded: a segment of at most 5 km touches at most four one-degree cells.
        for key in keys {
            for segment in roadGrid.cells[key] ?? [] where !found.contains(segment.road) {
                guard roads.indices.contains(Int(segment.road)) else { continue }
                let road = roads[Int(segment.road)], point = Int(segment.point)
                guard point + 1 < road.lons.count else { continue }
                let c = (x: Double(road.lons[point]), y: Double(road.lats[point]))
                let d = (x: Double(road.lons[point + 1]), y: Double(road.lats[point + 1]))
                if Self.segmentsMeet(a, b, c, d) { found.insert(segment.road) }
            }
        }
        return found.sorted().map { roads[Int($0)] }
    }

    /// Whether segment `a`–`b` and segment `c`–`d` share a point (crossing, or touching end to line).
    static func segmentsMeet(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double),
                             _ c: (x: Double, y: Double), _ d: (x: Double, y: Double)) -> Bool {
        func turn(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double), _ r: (x: Double, y: Double)) -> Double {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        func within(_ p: (x: Double, y: Double), _ q: (x: Double, y: Double), _ r: (x: Double, y: Double)) -> Bool {
            min(p.x, q.x) <= r.x && r.x <= max(p.x, q.x) && min(p.y, q.y) <= r.y && r.y <= max(p.y, q.y)
        }
        let d1 = turn(c, d, a), d2 = turn(c, d, b), d3 = turn(a, b, c), d4 = turn(a, b, d)
        if (d1 > 0 && d2 < 0 || d1 < 0 && d2 > 0) && (d3 > 0 && d4 < 0 || d3 < 0 && d4 > 0) { return true }
        if d1 == 0, within(c, d, a) { return true }
        if d2 == 0, within(c, d, b) { return true }
        if d3 == 0, within(a, b, c) { return true }
        if d4 == 0, within(a, b, d) { return true }
        return false
    }
}
