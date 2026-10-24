import Foundation

/// One recorded point of a walk: where, and how high when the reading had a height.
public nonisolated struct RoutePoint: Equatable, Sendable {
    /// Where.
    public var point: GeoPoint
    /// Metres above sea level, or nil when the reading had none.
    public var altitude: Double?

    /// A point at `point`, `altitude` metres up (nil: unknown).
    public init(_ point: GeoPoint, altitude: Double? = nil) {
        self.point = point
        self.altitude = altitude
    }
}

/// The compact form a walk's line is stored in, shaped like the watch build's planned `RouteCodec`
/// (`~/.claude/plans/delightful-coalescing-wombat.md`, route history) so the later move to its
/// `DeviceRouteStore` is a straight copy:
///
/// 1. **Thinned** with Ramer–Douglas–Peucker at ``tolerance`` metres (2.5 m): a straight stretch keeps
///    its two ends, a bend keeps its shape.
/// 2. **Quantised** to 1e-5° (about 1.1 m) and altitude to 0.5 m.
/// 3. **Delta-coded**, each value a zigzag varint, after a version byte and a flags byte.
///
/// Bounded (Power of 10): at most ``maxPoints`` points in and out; the thinning is iterative (an explicit
/// stack), never recursive.
public nonisolated enum WorldRouteCodec {
    /// The format's version byte.
    static let version: UInt8 = 1
    /// The thinning tolerance, in metres.
    public static let tolerance = 2.5
    /// The most points a stored line keeps.
    public static let maxPoints = 50_000
    /// Degrees per stored step.
    static let degreeStep = 1e-5
    /// Metres per stored altitude step.
    static let altitudeStep = 0.5

    /// The bytes for `points` (invalid points dropped, then thinned and quantised).
    public static func encode(_ points: [RoutePoint]) -> Data {
        let kept = thinned(Array(points.lazy.filter { $0.point.isValid }.prefix(maxPoints)))
        let hasAltitude = !kept.isEmpty && kept.allSatisfy { $0.altitude?.isFinite == true }
        var data = Data([version, hasAltitude ? 1 : 0])
        var last = (lat: Int64(0), lon: Int64(0), alt: Int64(0))
        for point in kept {
            let now = quantised(point)
            appendZigzag(now.lat - last.lat, to: &data)
            appendZigzag(now.lon - last.lon, to: &data)
            if hasAltitude { appendZigzag(now.alt - last.alt, to: &data) }
            last = now
        }
        return data
    }

    /// The points in `data`, or nil when the bytes are not this format or hold too many.
    public static func decode(_ data: Data) -> [RoutePoint]? {
        guard data.count >= 2, data[data.startIndex] == version, data[data.startIndex + 1] <= 1 else { return nil }
        let hasAltitude = data[data.startIndex + 1] == 1
        var reader = VarintReader(data.dropFirst(2))
        var points: [RoutePoint] = []
        var last = (lat: Int64(0), lon: Int64(0), alt: Int64(0))
        while !reader.isAtEnd {
            guard points.count < maxPoints, let dLat = reader.next(), let dLon = reader.next() else { return nil }
            last.lat &+= dLat
            last.lon &+= dLon
            if hasAltitude {
                guard let dAlt = reader.next() else { return nil }
                last.alt &+= dAlt
            }
            let point = GeoPoint(Double(last.lat) * degreeStep, Double(last.lon) * degreeStep)
            guard point.isValid else { return nil }
            points.append(RoutePoint(point, altitude: hasAltitude ? Double(last.alt) * altitudeStep : nil))
        }
        return points
    }

    /// The line's length in metres.
    public static func length(of points: [RoutePoint]) -> Double {
        Polyline(points.map(\.point)).length
    }

    /// Ramer–Douglas–Peucker with an explicit stack (bounded by the point count).
    static func thinned(_ points: [RoutePoint]) -> [RoutePoint] {
        guard points.count > 2 else { return points }
        var keep = Array(repeating: false, count: points.count)
        keep[0] = true
        keep[points.count - 1] = true
        var stack = [(0, points.count - 1)]
        var steps = 0
        // Each kept point pushes two segments, so every segment is visited within 2n pops.
        while let segment = stack.popLast(), steps < 2 * points.count {
            steps += 1
            let (start, end) = segment
            guard end > start + 1 else { continue }
            var farthest = start, distance = 0.0
            for index in (start + 1)..<end {
                let gap = offset(of: points[index].point, from: points[start].point, to: points[end].point)
                if gap > distance { distance = gap; farthest = index }
            }
            guard distance > tolerance else { continue }
            keep[farthest] = true
            stack.append((start, farthest))
            stack.append((farthest, end))
        }
        return points.indices.filter { keep[$0] }.map { points[$0] }
    }

    /// How far `point` lies from the segment `a`–`b`, in metres (flat-earth, local).
    static func offset(of point: GeoPoint, from a: GeoPoint, to b: GeoPoint) -> Double {
        let p = point.metres(from: a), e = b.metres(from: a)
        let lengthSquared = e.east * e.east + e.north * e.north
        guard lengthSquared > 0 else { return (p.east * p.east + p.north * p.north).squareRoot() }
        let t = min(1, max(0, (p.east * e.east + p.north * e.north) / lengthSquared))
        let dx = p.east - t * e.east, dy = p.north - t * e.north
        return (dx * dx + dy * dy).squareRoot()
    }

    /// The point in stored steps.
    private static func quantised(_ point: RoutePoint) -> (lat: Int64, lon: Int64, alt: Int64) {
        let altitude = point.altitude.map { min(max($0, -1_000), 10_000) } ?? 0
        return (Int64((point.point.latitude / degreeStep).rounded()), Int64((point.point.longitude / degreeStep).rounded()),
                Int64((altitude / altitudeStep).rounded()))
    }

    /// Appends `value` as a zigzag varint.
    private static func appendZigzag(_ value: Int64, to data: inout Data) {
        var bits = UInt64(bitPattern: (value << 1) ^ (value >> 63))
        for _ in 0..<10 {
            let low = UInt8(bits & 0x7F)
            bits >>= 7
            data.append(bits == 0 ? low : low | 0x80)
            if bits == 0 { break }
        }
    }
}

/// Reads zigzag varints from bytes, refusing a number longer than ten bytes or cut off at the end.
nonisolated struct VarintReader {
    private let bytes: Data
    private var index: Data.Index

    init(_ bytes: Data) {
        self.bytes = bytes
        index = bytes.startIndex
    }

    /// Whether every byte has been read.
    var isAtEnd: Bool { index >= bytes.endIndex }

    /// The next value, or nil when the bytes run out mid-number or a number is too long.
    mutating func next() -> Int64? {
        var value: UInt64 = 0
        for shift in stride(from: UInt64(0), to: 70, by: 7) {
            guard index < bytes.endIndex else { return nil }
            let byte = bytes[index]
            index = bytes.index(after: index)
            value |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                let signed = Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1)
                return signed
            }
        }
        return nil
    }
}
