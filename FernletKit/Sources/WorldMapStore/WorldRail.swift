import Foundation

/// The bundled `WorldRail.pack`, opened (Docs/World-Rail-Pack.md: `FWR1`, version 1, the atlas's section layout with
/// its own magic): Natural Earth's rail lines and ferry routes (public domain), thinned at about 110 m, each layer
/// with a one-degree cell index, for the ferry and train paths' classifier (`WornTransitGeography`,
/// Docs/World-Transit-Paths-Exploration-2026-11-15.md §2, §3, §9). Natural Earth's lines can sit a few hundred metres,
/// in places a few kilometres, from the real track, so they raise a guess's confidence and are never drawn.
///
/// ``init(data:)`` refuses, throwing ``WorldAtlasPackError`` and never trapping, a file over ``maxPackBytes``, a bad
/// header or table, a section out of bounds or of the wrong length, a missing required section, and any field the
/// format doesn't allow; ``decode(_:)`` turns any of those into nil. Immutable once opened, so any thread may ask.
public nonisolated struct WorldRail: Sendable {
    /// The file's first four bytes.
    public static let magic: [UInt8] = Array("FWR1".utf8)
    /// The one format version this reader knows.
    public static let version: UInt16 = 1
    /// The whole file's cap (the generator refuses more).
    public static let maxPackBytes = 2_097_152
    /// One section's inflated cap.
    public static let maxRawSectionBytes = 8_388_608
    /// The most sections a table may list.
    public static let maxSections = 8
    /// The most pieces one layer may hold (the shipped rail layer has 36,918).
    public static let maxPieces = 400_000
    /// The most points one layer may hold (the shipped rail layer has 453,168).
    public static let maxPoints = 1_500_000
    /// The most piece listings one layer's index may hold.
    public static let maxCellRefs = 2_000_000
    /// The farthest a query looks, in metres: a larger `within` is read as this.
    public static let maxQueryMetres = 20_000.0
    /// The sections every pack must carry (`META`, the generator's provenance, is optional).
    public static let requiredTags = ["RAIL", "RIDX", "FERY", "FIDX"]
    /// The shipped `WorldRail.pack`'s SHA-256 (generated 2026-11-16 by `Scripts/world-atlas/build_world_rail.py`).
    /// Regenerating the pack changes it on purpose.
    public static let expectedSHA256 = "11513107850a3d201943e2460ba2a535f2bac6a3b18bac9e7d36b5636b0fa7d1"

    private let rail: WorldRailLayer
    private let ferry: WorldRailLayer

    /// Opens `data`, or throws why it's refused.
    public init(data: Data) throws {
        guard data.count <= Self.maxPackBytes else { throw WorldAtlasPackError.tooLarge }
        let sections = try Self.sections(of: [UInt8](data))
        rail = try WorldRailLayer(lines: sections["RAIL"] ?? [], index: sections["RIDX"] ?? [], tags: ("RAIL", "RIDX"))
        ferry = try WorldRailLayer(lines: sections["FERY"] ?? [], index: sections["FIDX"] ?? [], tags: ("FERY", "FIDX"))
    }

    /// The pack in `data`, or nil when it is refused for any reason (fail-safe: no rail and no ferry routes).
    public static func decode(_ data: Data) -> WorldRail? {
        do {
            return try WorldRail(data: data)
        } catch {
            return nil
        }
    }

    /// How many points the rail layer holds.
    public var railPointCount: Int { rail.lons.count }

    /// How many points the ferry layer holds.
    public var ferryPointCount: Int { ferry.lons.count }

    /// Whether a rail line passes within `metres` of `point` (point-to-segment distance, the nearest one-degree cells
    /// only). False for an invalid point or a distance that isn't positive and finite; `metres` is capped at
    /// ``maxQueryMetres``.
    public func isNearRail(_ point: GeoPoint, within metres: Double) -> Bool {
        rail.isNear(point, within: metres)
    }

    /// Whether a bundled ferry route passes within `metres` of `point`, as ``isNearRail(_:within:)``.
    public func isNearFerryRoute(_ point: GeoPoint, within metres: Double) -> Bool {
        ferry.isNear(point, within: metres)
    }

    // MARK: - Reading

    private static func sections(of bytes: [UInt8]) throws -> [String: [UInt8]] {
        guard bytes.count >= 8 else { throw WorldAtlasPackError.badTable }
        guard Array(bytes[0..<4]) == magic else { throw WorldAtlasPackError.badMagic }
        var head = AtlasByteReader(Array(bytes[4..<8]), tag: "HEAD")
        guard try head.u16() == version else { throw WorldAtlasPackError.badVersion }
        let count = Int(try head.u16())
        guard count >= 1, count <= maxSections, bytes.count >= 8 + count * 16 else {
            throw WorldAtlasPackError.badTable
        }
        var sections: [String: [UInt8]] = [:]
        // Bounded: count <= maxSections.
        for slot in 0..<count {
            var row = AtlasByteReader(Array(bytes[(8 + slot * 16)..<(24 + slot * 16)]), tag: "TABL")
            guard let tag = String(bytes: try row.bytes(4), encoding: .ascii), tag.count == 4 else {
                throw WorldAtlasPackError.badTable
            }
            let offset = Int(try row.u32()), stored = Int(try row.u32()), raw = Int(try row.u32())
            guard sections[tag] == nil else { throw WorldAtlasPackError.duplicateSection(tag) }
            guard offset >= 8, stored > 0, offset <= bytes.count, stored <= bytes.count - offset else {
                throw WorldAtlasPackError.sectionOutOfBounds(tag)
            }
            guard raw > 0, raw <= maxRawSectionBytes else { throw WorldAtlasPackError.sectionTooLarge(tag) }
            guard let body = WorldAtlasInflate.inflate(Data(bytes[offset..<(offset + stored)]), rawLength: raw) else {
                throw WorldAtlasPackError.wrongRawLength(tag)
            }
            sections[tag] = body
        }
        for tag in requiredTags where sections[tag] == nil { throw WorldAtlasPackError.missingSection(tag) }
        return sections
    }

    /// The distance in metres from the origin to the segment `a`–`b`, both in local metres (east, north).
    static func metresToSegment(_ a: (x: Double, y: Double), _ b: (x: Double, y: Double)) -> Double {
        let vx = b.x - a.x, vy = b.y - a.y
        let length = vx * vx + vy * vy
        let t = length > 0 ? min(1, max(0, -(a.x * vx + a.y * vy) / length)) : 0
        let x = a.x + t * vx, y = a.y + t * vy
        return (x * x + y * y).squareRoot()
    }
}

/// One layer of the rail pack: its pieces' points (1e-5°) and the one-degree cell index of the pieces whose boxes
/// touch each cell (key row × 360 + column, rows from 90°S and columns from 180°W).
nonisolated struct WorldRailLayer: Sendable {
    let lons: [Int32]
    let lats: [Int32]
    /// Each piece's first point index, then the end (pieceCount + 1 entries).
    let starts: [Int32]
    /// Each piece's box (west, south, east, north, 1e-5°), so a query skips the pieces out of reach unread.
    let boxes: [WorldRailBox]
    let cells: [Int: [Int32]]

    /// `lines`: u32 pieceCount · per piece u16 pointCount (≥ 2) · i32 lon · i32 lat · zigzag deltas.
    /// `index`: u16 cellCount · per cell (keys ascending) u16 key · u32 refCount · zigzag deltas of ascending pieces.
    init(lines: [UInt8], index: [UInt8], tags: (lines: String, index: String)) throws {
        var reader = AtlasByteReader(lines, tag: tags.lines)
        let count = Int(try reader.u32())
        guard count <= WorldRail.maxPieces else { throw WorldAtlasPackError.malformed(tags.lines, "count") }
        var lons: [Int32] = [], lats: [Int32] = [], starts: [Int32] = [0], boxes: [WorldRailBox] = []
        starts.reserveCapacity(count + 1)
        boxes.reserveCapacity(count)
        // Bounded: count <= maxPieces, each at most UInt16.max points, the total capped at maxPoints.
        for _ in 0..<count {
            let points = Int(try reader.u16())
            guard points >= 2, lons.count + points <= WorldRail.maxPoints else {
                throw WorldAtlasPackError.malformed(tags.lines, "points")
            }
            var lon = Int64(try reader.i32()), lat = Int64(try reader.i32())
            var box = WorldRailBox(west: Int32.max, south: Int32.max, east: Int32.min, north: Int32.min)
            for step in 0..<points {
                if step > 0 {
                    lon += try reader.zigzag()
                    lat += try reader.zigzag()
                }
                guard abs(lon) <= 18_000_000, abs(lat) <= 9_000_000 else {
                    throw WorldAtlasPackError.malformed(tags.lines, "point")
                }
                lons.append(Int32(lon))
                lats.append(Int32(lat))
                box.add(lon: Int32(lon), lat: Int32(lat))
            }
            guard box.east - box.west <= 18_000_000 else { throw WorldAtlasPackError.malformed(tags.lines, "piece") }
            starts.append(Int32(lons.count))
            boxes.append(box)
        }
        try reader.expectEnd()
        self.lons = lons
        self.lats = lats
        self.starts = starts
        self.boxes = boxes
        cells = try Self.index(index, pieces: count, tag: tags.index)
    }

    private static func index(_ body: [UInt8], pieces: Int, tag: String) throws -> [Int: [Int32]] {
        var reader = AtlasByteReader(body, tag: tag)
        let count = Int(try reader.u16())
        var cells: [Int: [Int32]] = [:]
        var refs = 0, lastKey = -1
        // Bounded: count <= UInt16.max cells, the listings capped at maxCellRefs.
        for _ in 0..<count {
            let key = Int(try reader.u16()), listed = Int(try reader.u32())
            guard key > lastKey, key < 180 * 360, listed >= 1, refs + listed <= WorldRail.maxCellRefs else {
                throw WorldAtlasPackError.malformed(tag, "cell")
            }
            lastKey = key
            refs += listed
            var numbers: [Int32] = []
            numbers.reserveCapacity(listed)
            var number: Int64 = 0
            for slot in 0..<listed {
                let delta = try reader.zigzag()
                guard delta > 0 || (slot == 0 && delta == 0) else { throw WorldAtlasPackError.malformed(tag, "ref") }
                number += delta
                guard number < Int64(pieces) else { throw WorldAtlasPackError.malformed(tag, "ref") }
                numbers.append(Int32(number))
            }
            cells[key] = numbers
        }
        try reader.expectEnd()
        return cells
    }

    /// The query: the cells the box of `metres` around `point` touches, then each listed piece's segments in a flat
    /// local frame (exact enough within 20 km), stopping at the first within reach.
    func isNear(_ point: GeoPoint, within metres: Double) -> Bool {
        guard point.isValid, metres.isFinite, metres > 0 else { return false }
        let reach = min(metres, WorldRail.maxQueryMetres)
        let cosine = max(0.05, cos(point.latitude * .pi / 180))
        let dLat = reach / GeoPoint.metresPerDegree, dLon = reach / (GeoPoint.metresPerDegree * cosine)
        let southRow = Self.row(point.latitude - dLat), northRow = Self.row(point.latitude + dLat)
        let westColumn = Int((point.longitude - dLon + 180).rounded(.down))
        let eastColumn = Int((point.longitude + dLon + 180).rounded(.down))
        let kx = GeoPoint.metresPerDegree * cosine / 100_000, ky = GeoPoint.metresPerDegree / 100_000
        let originLon = point.longitude * 100_000, originLat = point.latitude * 100_000
        let reachLon = dLon * 100_000, reachLat = dLat * 100_000
        var seen = Set<Int32>()
        // Bounded: reach <= 20 km and cos >= 0.05, so at most 3 rows and 9 columns; each cell's listing was capped
        // at decode, and each piece is read once.
        for row in southRow...northRow {
            for column in westColumn...eastColumn {
                let key = row * 360 + ((column % 360) + 360) % 360
                for piece in cells[key] ?? [] where seen.insert(piece).inserted {
                    guard boxes[Int(piece)].reaches(lon: originLon, lat: originLat, reachLon: reachLon,
                                                    reachLat: reachLat) else { continue }
                    let first = Int(starts[Int(piece)]), end = Int(starts[Int(piece) + 1])
                    var previous = local(first, originLon: originLon, originLat: originLat, kx: kx, ky: ky)
                    for index in (first + 1)..<end {
                        let current = local(index, originLon: originLon, originLat: originLat, kx: kx, ky: ky)
                        if WorldRail.metresToSegment(previous, current) <= reach { return true }
                        previous = current
                    }
                }
            }
        }
        return false
    }

    /// Point `index` in metres east and north of the origin (longitude difference wrapped across 180°).
    private func local(_ index: Int, originLon: Double, originLat: Double, kx: Double, ky: Double) -> (x: Double, y: Double) {
        var dLon = Double(lons[index]) - originLon
        if dLon > 18_000_000 { dLon -= 36_000_000 } else if dLon < -18_000_000 { dLon += 36_000_000 }
        return (dLon * kx, (Double(lats[index]) - originLat) * ky)
    }

    /// The one-degree row of `latitude` (0 at 90°S, 179 at the last degree).
    private static func row(_ latitude: Double) -> Int {
        min(max(Int((latitude + 90).rounded(.down)), 0), 179)
    }
}

/// One piece's box in 1e-5°. Pieces never cross the antimeridian (the generator cuts them there, and the reader refuses
/// a box wider than 180°).
nonisolated struct WorldRailBox: Sendable {
    var west: Int32
    var south: Int32
    var east: Int32
    var north: Int32

    mutating func add(lon: Int32, lat: Int32) {
        west = min(west, lon)
        east = max(east, lon)
        south = min(south, lat)
        north = max(north, lat)
    }

    /// Whether the box, widened by `reachLon` and `reachLat`, holds (`lon`, `lat`), across 180° too.
    func reaches(lon: Double, lat: Double, reachLon: Double, reachLat: Double) -> Bool {
        guard lat >= Double(south) - reachLat, lat <= Double(north) + reachLat else { return false }
        // Bounded: the point as given and shifted one turn either way.
        for shift in [0.0, 36_000_000, -36_000_000] {
            let shifted = lon + shift
            if shifted >= Double(west) - reachLon, shifted <= Double(east) + reachLon { return true }
        }
        return false
    }
}
