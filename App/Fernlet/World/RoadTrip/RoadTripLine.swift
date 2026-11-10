import Foundation
import WorldMapStore

/// One point of a road trip's line: where and when (`rt-photos`: a trip photo's place comes from the line at its
/// capture time, so unlike a walk's `RoutePoint` every point carries its time).
nonisolated struct RoadTripPoint: Equatable, Sendable {
    /// Where.
    let point: GeoPoint
    /// When the reading was taken.
    let at: Date
}

/// The rules and bounds of a road trip's timed line (World-RoadTrip-Spec §3, "No line today"), recorded by the iPhone
/// that maps from the readings the fog keeper accepts (precise, within 65 m).
///
/// - **Thinned:** a reading is kept only ``minSpacing`` or more from the last kept point, and never older than it
///   (``keeps(_:after:)``), so a parked car or a slow jam adds nothing.
/// - **In pieces:** the line is sealed ``chunkSize`` points to a file, so appending rewrites one small piece, never the
///   whole trip; at most ``maxChunks`` pieces, so at most ``maxPoints`` points (about 2,500 km at the spacing). Past it
///   a point is refused and counted, never an eviction.
/// - **Compact:** each piece is ``RoadTripLineCodec``'s varint form.
nonisolated enum RoadTripLine {
    /// The least distance between two kept points, in metres.
    static let minSpacing = 25.0
    /// The most points one piece holds.
    static let chunkSize = 500
    /// The most pieces one trip's line has.
    static let maxChunks = 200
    /// The most points one trip's line has.
    static let maxPoints = chunkSize * maxChunks

    /// Whether `candidate` is kept after `last` (the line's last kept point; nil for the first): a valid point,
    /// no older than `last`, and at least ``minSpacing`` from it.
    static func keeps(_ candidate: RoadTripPoint, after last: RoadTripPoint?) -> Bool {
        guard RoadTripLineCodec.quantised(candidate) != nil else { return false }
        guard let last else { return true }
        guard candidate.at >= last.at else { return false }
        return candidate.point.distance(to: last.point) >= minSpacing
    }

    /// The length of `points` in metres, starting from `from` (the point before them, if any).
    static func length(of points: [RoadTripPoint], from: RoadTripPoint?) -> Double {
        var metres = 0.0
        var previous = from
        for point in points.prefix(maxPoints) {
            if let previous { metres += previous.point.distance(to: point.point) }
            previous = point
        }
        return metres
    }
}

/// The compact form one piece of a road trip's line is sealed in: a version byte, the count, then each point as
/// zigzag varint deltas of latitude and longitude in 1e-5° (about 1.1 m) and of the time in whole seconds.
///
/// Bounded (Power of 10): at most ``RoadTripLine/chunkSize`` points in and out, each varint at most ten bytes. A
/// piece that breaks any rule (a bad version, a count past the bound, a point off the globe, time running backwards,
/// bytes left over) is refused whole, as nil.
nonisolated enum RoadTripLineCodec {
    /// The format's version byte.
    static let version: UInt8 = 1
    /// Degrees are stored in units of this.
    static let degreeScale = 100_000.0
    /// The most bytes one varint may take.
    static let maxVarintBytes = 10

    /// The latest time a point may carry (the year 9999; a bound that keeps every conversion exact).
    static let maxSeconds = 253_402_300_799.0

    /// `points` (at most ``RoadTripLine/chunkSize`` of them; one off the globe or out of time is left out) in the
    /// compact form.
    static func encode(_ points: [RoadTripPoint]) -> Data {
        let kept = points.prefix(RoadTripLine.chunkSize).compactMap(quantised)
        var data = Data([version])
        appendVarint(UInt64(kept.count), to: &data)
        var previous = (lat: Int64(0), lon: Int64(0), time: Int64(0))
        for point in kept {
            appendVarint(zigzag(point.lat &- previous.lat), to: &data)
            appendVarint(zigzag(point.lon &- previous.lon), to: &data)
            appendVarint(zigzag(point.time &- previous.time), to: &data)
            previous = point
        }
        return data
    }

    /// `point` in stored units, or nil when it is off the globe or its time is outside 1970 to ``maxSeconds``.
    static func quantised(_ point: RoadTripPoint) -> (lat: Int64, lon: Int64, time: Int64)? {
        let seconds = point.at.timeIntervalSince1970
        guard point.point.isValid, seconds.isFinite, seconds >= 0, seconds <= maxSeconds else { return nil }
        return (Int64((point.point.latitude * degreeScale).rounded()), Int64((point.point.longitude * degreeScale).rounded()),
                Int64(seconds.rounded(.down)))
    }

    /// The points in `data`, or nil when it isn't a valid piece.
    static func decode(_ data: Data) -> [RoadTripPoint]? {
        let bytes = [UInt8](data)
        guard bytes.first == version else { return nil }
        var offset = 1
        guard let count = readVarint(bytes, at: &offset), count <= UInt64(RoadTripLine.chunkSize) else { return nil }
        var points: [RoadTripPoint] = []
        points.reserveCapacity(Int(count))
        var previous = (lat: Int64(0), lon: Int64(0), time: Int64(0))
        for _ in 0..<Int(count) {
            guard let dLat = readVarint(bytes, at: &offset), let dLon = readVarint(bytes, at: &offset),
                  let dTime = readVarint(bytes, at: &offset) else { return nil }
            let lat = previous.lat &+ unzigzag(dLat), lon = previous.lon &+ unzigzag(dLon)
            let time = previous.time &+ unzigzag(dTime)
            guard time >= 0, Double(time) <= maxSeconds, points.isEmpty || time >= previous.time else { return nil }
            let point = GeoPoint(Double(lat) / degreeScale, Double(lon) / degreeScale)
            guard point.isValid else { return nil }
            points.append(RoadTripPoint(point: point, at: Date(timeIntervalSince1970: TimeInterval(time))))
            previous = (lat, lon, time)
        }
        guard offset == bytes.count else { return nil }
        return points
    }

    /// `value` as a zigzag-coded unsigned number (small magnitudes stay small).
    static func zigzag(_ value: Int64) -> UInt64 {
        UInt64(bitPattern: (value << 1) ^ (value >> 63))
    }

    /// The signed number a zigzag-coded `value` stands for.
    static func unzigzag(_ value: UInt64) -> Int64 {
        Int64(bitPattern: (value >> 1) ^ (0 &- (value & 1)))
    }

    /// Appends `value` as a little-endian base-128 varint.
    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var rest = value
        for _ in 0..<maxVarintBytes {
            guard rest >= 0x80 else {
                data.append(UInt8(rest))
                return
            }
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
    }

    /// Reads one varint at `offset`, moving it past; nil when the bytes end or the varint runs past ten bytes.
    private static func readVarint(_ bytes: [UInt8], at offset: inout Int) -> UInt64? {
        var value: UInt64 = 0
        for step in 0..<maxVarintBytes {
            guard offset < bytes.count else { return nil }
            let byte = bytes[offset]
            offset += 1
            value |= UInt64(byte & 0x7F) << UInt64(7 * step)
            if byte < 0x80 { return value }
        }
        return nil
    }
}
