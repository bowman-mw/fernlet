import FernletFoundation
import Foundation

/// A kept trip without its line: what the fog keeper holds in memory for a forever history (owner 2026-11-15), with
/// the piece of ``WornTripStore`` its line lives in.
public nonisolated struct WornTripSummary: Sendable, Equatable, Identifiable {
    /// The trip's id.
    public let id: UUID
    /// What it counts as.
    public var kind: WornWayKind
    /// Whether the person said so.
    public var confirmed: Bool
    /// Whether the guess was unsure when it was made (Home may ask about it, at most once a day).
    public let unsure: Bool
    /// Whether the person said it was a train (``WornTrip/markedTrain``).
    public var markedTrain: Bool
    /// The ``WornDay`` it counts on.
    public let day: UInt16
    /// When it started and ended.
    public let start: Date
    public let end: Date
    /// The piece its record is in.
    public let chunk: Int

    /// A summary.
    public init(id: UUID, kind: WornWayKind, confirmed: Bool, unsure: Bool, markedTrain: Bool = false, day: UInt16, start: Date,
                end: Date, chunk: Int) {
        self.id = id
        self.kind = kind
        self.confirmed = confirmed
        self.unsure = unsure
        self.markedTrain = markedTrain
        self.day = day
        self.start = start
        self.end = end
        self.chunk = chunk
    }
}

/// The binary format of a piece of ``WornTripStore``: a version byte, the trip count as a little-endian `UInt32`, then
/// one record a trip:
///
/// - id (16 bytes), kind `UInt8`, flags `UInt8` (bit 0 confirmed, bit 1 unsure, and from version 2 bit 2 marked Train
///   by the person, F13 3B), day `UInt16`, start and end as whole seconds since 1970 (`Int64` each), the point count
///   `UInt16` and the line's byte count `UInt32`;
/// - the line: each point's latitude and longitude in 1/100,000 of a degree (about 1.1 m), the first as is and each
///   next as the change from the one before, zigzag-encoded LEB128 varints. A 25 m-thinned commute takes about two
///   bytes a point, a few KB a ride.
///
/// Every number is little-endian. Encoding always writes version 2; decoding reads version 1 (flags bits 0–1 only) and
/// version 2 (bits 0–2), and rejects any other version, a flag bit its version doesn't know, a size that doesn't match,
/// an unknown kind, more points than ``WornTrip/maxLinePoints``, a coordinate off the globe and more trips than the
/// limit.
public nonisolated enum WornTripCodec {
    /// The version byte written.
    static let version: UInt8 = 2
    /// The first version, still read (no Train mark).
    static let versionOne: UInt8 = 1
    /// The flag bits each version knows.
    static func knownFlags(version: UInt8) -> UInt8 { version == versionOne ? 3 : 7 }
    /// Bytes before the first record.
    static let headerSize = 5
    /// Bytes in a record before its line.
    static let recordHeaderSize = 16 + 1 + 1 + 2 + 8 + 8 + 2 + 4
    /// Units of a degree a coordinate is kept in.
    static let unitsPerDegree = 100_000.0

    /// The bytes for `trips` (each with whether its guess was unsure), in the order given.
    public static func encode(_ trips: [(trip: WornTrip, unsure: Bool)]) -> Data {
        var data = Data([version])
        appendInt(UInt32(clamping: trips.count), to: &data)
        // Bounded: the caller's piece holds at most WornTripStore.tripsPerChunk trips.
        for (trip, unsure) in trips {
            let line = encodeLine(trip.line)
            data.append(contentsOf: uuidBytes(trip.id))
            data.append(trip.kind.rawValue)
            data.append((trip.confirmed ? 1 : 0) | (unsure ? 2 : 0) | (trip.markedTrain ? 4 : 0))
            appendInt(trip.day, to: &data)
            appendInt(Int64(trip.start.timeIntervalSince1970.rounded()), to: &data)
            appendInt(Int64(trip.end.timeIntervalSince1970.rounded()), to: &data)
            appendInt(UInt16(clamping: trip.line.count), to: &data)
            appendInt(UInt32(clamping: line.count), to: &data)
            data.append(line)
        }
        return data
    }

    /// The trips in `data`, or nil when the bytes are not this format or hold more than `limit` trips.
    public static func decode(_ data: Data, limit: Int) -> [(trip: WornTrip, unsure: Bool)]? {
        let bytes = [UInt8](data)
        guard let count = count(bytes, limit: limit) else { return nil }
        let known = knownFlags(version: bytes[0])
        var trips: [(trip: WornTrip, unsure: Bool)] = []
        trips.reserveCapacity(count)
        var offset = headerSize
        // Bounded: count ≤ limit, checked above.
        for _ in 0..<count {
            guard let header = recordHeader(bytes, at: offset, knownFlags: known) else { return nil }
            let lineEnd = offset + recordHeaderSize + header.lineBytes
            guard let line = decodeLine(bytes[(offset + recordHeaderSize)..<lineEnd], points: header.points) else { return nil }
            trips.append((WornTrip(id: header.id, kind: header.kind, confirmed: header.confirmed, markedTrain: header.markedTrain,
                                   day: header.day, start: header.start, end: header.end, line: line), header.unsure))
            offset = lineEnd
        }
        return offset == bytes.count ? trips : nil
    }

    /// The trips in `data` without their lines (each lies in `chunk`), or nil when the bytes are not this format. The
    /// lines are skipped, not decoded, so reading a forever history stays cheap.
    public static func decodeSummaries(_ data: Data, chunk: Int, limit: Int) -> [WornTripSummary]? {
        let bytes = [UInt8](data)
        guard let count = count(bytes, limit: limit) else { return nil }
        let known = knownFlags(version: bytes[0])
        var summaries: [WornTripSummary] = []
        summaries.reserveCapacity(count)
        var offset = headerSize
        // Bounded: count ≤ limit, checked above.
        for _ in 0..<count {
            guard let header = recordHeader(bytes, at: offset, knownFlags: known) else { return nil }
            summaries.append(WornTripSummary(id: header.id, kind: header.kind, confirmed: header.confirmed, unsure: header.unsure,
                                             markedTrain: header.markedTrain, day: header.day, start: header.start,
                                             end: header.end, chunk: chunk))
            offset += recordHeaderSize + header.lineBytes
        }
        return offset == bytes.count ? summaries : nil
    }

    /// `line` (at most ``WornTrip/maxLinePoints``) on the format's 1/100,000-degree steps, exactly as decoding returns it,
    /// so the cells counted for a trip are the cells its kept line passes when it is read back.
    public static func quantized(_ line: [GeoPoint]) -> [GeoPoint] {
        line.prefix(WornTrip.maxLinePoints).map {
            GeoPoint(Double(Int64(($0.latitude * unitsPerDegree).rounded())) / unitsPerDegree,
                     Double(Int64(($0.longitude * unitsPerDegree).rounded())) / unitsPerDegree)
        }
    }

    /// The line's bytes: zigzag varint deltas in ``unitsPerDegree``.
    static func encodeLine(_ line: [GeoPoint]) -> Data {
        var data = Data()
        data.reserveCapacity(line.count * 4)
        var previous = (lat: Int64(0), lon: Int64(0))
        // Bounded: at most WornTrip.maxLinePoints points (the trip's own cap).
        for point in line.prefix(WornTrip.maxLinePoints) {
            let lat = Int64((point.latitude * unitsPerDegree).rounded())
            let lon = Int64((point.longitude * unitsPerDegree).rounded())
            appendVarint(zigzag(lat - previous.lat), to: &data)
            appendVarint(zigzag(lon - previous.lon), to: &data)
            previous = (lat, lon)
        }
        return data
    }

    /// The `points` points in `bytes`, or nil when they don't decode to exactly that many valid points.
    static func decodeLine(_ bytes: ArraySlice<UInt8>, points: Int) -> [GeoPoint]? {
        var line: [GeoPoint] = []
        line.reserveCapacity(points)
        var index = bytes.startIndex
        var lat: Int64 = 0, lon: Int64 = 0
        // Bounded: points ≤ WornTrip.maxLinePoints, checked by the caller.
        for _ in 0..<points {
            guard let dLat = readVarint(bytes, at: &index), let dLon = readVarint(bytes, at: &index) else { return nil }
            lat += unzigzag(dLat)
            lon += unzigzag(dLon)
            let point = GeoPoint(Double(lat) / unitsPerDegree, Double(lon) / unitsPerDegree)
            guard abs(point.latitude) <= 90, abs(point.longitude) <= 180 else { return nil }
            line.append(point)
        }
        return index == bytes.endIndex ? line : nil
    }

    /// One record's fixed part.
    private struct RecordHeader {
        let id: UUID
        let kind: WornWayKind
        let confirmed: Bool
        let unsure: Bool
        let markedTrain: Bool
        let day: UInt16
        let start: Date
        let end: Date
        let points: Int
        let lineBytes: Int
    }

    /// The record header at `offset`, when it is whole, its kind and flags (`knownFlags`) known and its line fits in
    /// `bytes`.
    private static func recordHeader(_ bytes: [UInt8], at offset: Int, knownFlags: UInt8) -> RecordHeader? {
        guard offset + recordHeaderSize <= bytes.count else { return nil }
        let id = uuid(bytes, at: offset)
        guard let kind = WornWayKind(rawValue: bytes[offset + 16]) else { return nil }
        let flags = bytes[offset + 17]
        guard flags & ~knownFlags == 0 else { return nil }
        let points = Int(readInt(bytes, at: offset + 36, size: 2))
        let lineBytes = Int(readInt(bytes, at: offset + 38, size: 4))
        guard points <= WornTrip.maxLinePoints, lineBytes <= bytes.count - offset - recordHeaderSize else { return nil }
        return RecordHeader(id: id, kind: kind, confirmed: flags & 1 != 0, unsure: flags & 2 != 0, markedTrain: flags & 4 != 0,
                            day: UInt16(readInt(bytes, at: offset + 18, size: 2)),
                            start: Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: readInt(bytes, at: offset + 20, size: 8)))),
                            end: Date(timeIntervalSince1970: TimeInterval(Int64(bitPattern: readInt(bytes, at: offset + 28, size: 8)))),
                            points: points, lineBytes: lineBytes)
    }

    /// `id`'s 16 bytes.
    static func uuidBytes(_ id: UUID) -> [UInt8] {
        let u = id.uuid
        return [u.0, u.1, u.2, u.3, u.4, u.5, u.6, u.7, u.8, u.9, u.10, u.11, u.12, u.13, u.14, u.15]
    }

    /// The id in the 16 bytes at `offset` (the caller checks they are there).
    static func uuid(_ bytes: [UInt8], at offset: Int) -> UUID {
        let b = Array(bytes[offset..<(offset + 16)])
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    /// The trip count the header states, when the version is one this reads and it is within `limit`.
    private static func count(_ bytes: [UInt8], limit: Int) -> Int? {
        guard bytes.count >= headerSize, bytes[0] == version || bytes[0] == versionOne, limit >= 0 else { return nil }
        let count = Int(readInt(bytes, at: 1, size: 4))
        return count <= limit ? count : nil
    }

    /// The little-endian unsigned number of `size` bytes at `start`.
    private static func readInt(_ bytes: [UInt8], at start: Int, size: Int) -> UInt64 {
        var value: UInt64 = 0
        // Bounded: at most 8 bytes.
        for shift in 0..<size { value |= UInt64(bytes[start + shift]) << (8 * UInt64(shift)) }
        return value
    }

    /// Appends `value` little-endian.
    private static func appendInt<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        // Bounded: at most 8 bytes.
        for index in 0..<(Value.bitWidth / 8) { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }

    /// `value` folded so small negatives are small too.
    private static func zigzag(_ value: Int64) -> UInt64 { UInt64(bitPattern: (value << 1) ^ (value >> 63)) }

    /// The inverse of ``zigzag(_:)``.
    private static func unzigzag(_ value: UInt64) -> Int64 { Int64(bitPattern: value >> 1) ^ -Int64(bitPattern: value & 1) }

    /// Appends `value` as an LEB128 varint.
    private static func appendVarint(_ value: UInt64, to data: inout Data) {
        var rest = value
        // Bounded: at most 10 bytes for 64 bits.
        for _ in 0..<10 {
            if rest < 0x80 {
                data.append(UInt8(rest))
                return
            }
            data.append(UInt8(rest & 0x7F) | 0x80)
            rest >>= 7
        }
    }

    /// The varint at `index`, moving past it; nil when cut off or longer than 10 bytes.
    private static func readVarint(_ bytes: ArraySlice<UInt8>, at index: inout Int) -> UInt64? {
        var value: UInt64 = 0
        // Bounded: at most 10 bytes for 64 bits.
        for shift in 0..<10 {
            guard index < bytes.endIndex else { return nil }
            let byte = bytes[index]
            index += 1
            value |= UInt64(byte & 0x7F) << (7 * UInt64(shift))
            if byte < 0x80 { return value }
        }
        return nil
    }
}

/// A ride's readings and whether the ride watch ever called it a drive (F13 2B, owner 2026-11-19): a ride seen only off
/// a drive (readings faster than a car while Motion said walking or cycling) keeps only its ferry and rail stretches.
public nonisolated struct WornRideCheckpoint: Sendable, Equatable {
    /// The readings, oldest first.
    public let samples: [WornRideSample]
    /// Whether any of them came while the ride watch said driving.
    public let sawDrive: Bool

    /// A ride.
    public init(samples: [WornRideSample], sawDrive: Bool) {
        self.samples = samples
        self.sawDrive = sawDrive
    }
}

/// The ride in progress's bytes (``WorldMapVault/File/wornTripRide``): a version byte (2), a flags byte (bit 0: the
/// ride watch called it a drive), the sample count as a little-endian `UInt32`, then 29 bytes a sample: latitude,
/// longitude and time (`Double` bit patterns), speed (`Float` bits, NaN for none) and the car (0 unknown, 1 no, 2 yes).
/// Version 1 (no flags byte) still reads, as a ride that saw a drive.
public nonisolated enum WornRideCheckpointCodec {
    /// The version byte written.
    static let version: UInt8 = 2
    /// The first version, still read.
    static let versionOne: UInt8 = 1
    /// Bytes in one sample.
    static let sampleSize = 29

    /// The bytes for `ride`.
    public static func encode(_ ride: WornRideCheckpoint) -> Data {
        var data = Data([version, ride.sawDrive ? 1 : 0])
        data.reserveCapacity(6 + ride.samples.count * sampleSize)
        append(UInt32(clamping: ride.samples.count), to: &data)
        // Bounded: the keeper holds at most WornRideClassifier.maxSamples.
        for sample in ride.samples {
            append(sample.point.latitude.bitPattern, to: &data)
            append(sample.point.longitude.bitPattern, to: &data)
            append(sample.at.timeIntervalSince1970.bitPattern, to: &data)
            append(Float(sample.speed ?? .nan).bitPattern, to: &data)
            data.append(sample.inCar.map { $0 ? 2 : 1 } ?? 0)
        }
        return data
    }

    /// The ride in `data`, or nil when the bytes are not this format or hold more than `limit` samples.
    public static func decode(_ data: Data, limit: Int) -> WornRideCheckpoint? {
        let bytes = [UInt8](data)
        guard let first = bytes.first, first == version || first == versionOne else { return nil }
        let header = first == version ? 6 : 5
        guard bytes.count >= header else { return nil }
        let flags: UInt8 = first == version ? bytes[1] : 1
        guard flags & ~1 == 0 else { return nil }
        let count = Int(read(bytes, at: header - 4, size: 4))
        guard count <= limit, bytes.count == header + count * sampleSize else { return nil }
        var samples: [WornRideSample] = []
        samples.reserveCapacity(count)
        // Bounded: count ≤ limit.
        for index in 0..<count {
            guard let sample = sample(bytes, at: header + index * sampleSize) else { return nil }
            samples.append(sample)
        }
        return WornRideCheckpoint(samples: samples, sawDrive: flags & 1 != 0)
    }

    /// The sample at `start` (the caller checks its bytes are there), or nil when it is off the globe or its car byte
    /// is unknown.
    private static func sample(_ bytes: [UInt8], at start: Int) -> WornRideSample? {
        let point = GeoPoint(Double(bitPattern: read(bytes, at: start, size: 8)), Double(bitPattern: read(bytes, at: start + 8, size: 8)))
        let at = Date(timeIntervalSince1970: Double(bitPattern: read(bytes, at: start + 16, size: 8)))
        let speed = Float(bitPattern: UInt32(read(bytes, at: start + 24, size: 4)))
        let car = bytes[start + 28]
        guard point.isValid, car <= 2 else { return nil }
        return WornRideSample(point: point, at: at, speed: speed.isNaN ? nil : Double(speed), inCar: car == 0 ? nil : car == 2)
    }

    /// The little-endian unsigned number of `size` bytes at `start`.
    static func read(_ bytes: [UInt8], at start: Int, size: Int) -> UInt64 {
        var value: UInt64 = 0
        // Bounded: at most 8 bytes.
        for shift in 0..<size { value |= UInt64(bytes[start + shift]) << (8 * UInt64(shift)) }
        return value
    }

    /// Appends `value` little-endian.
    static func append<Value: FixedWidthInteger>(_ value: Value, to data: inout Data) {
        // Bounded: at most 8 bytes.
        for index in 0..<(Value.bitWidth / 8) { data.append(UInt8(truncatingIfNeeded: value >> (8 * index))) }
    }
}

/// The finished rides waiting to be sorted (``WorldMapVault/File/wornTripQueue``, F13 4B, owner 2026-11-19): a ride that
/// ends before the ground under it is known (a locked launch, or a background launch before the packs open) waits
/// here instead of being kept as a road. A version byte (1), the ride count as a little-endian `UInt16`, then each ride
/// as its byte count (`UInt32`) and its ``WornRideCheckpointCodec`` bytes.
public nonisolated enum WornRideQueueCodec {
    /// The format's version byte.
    static let version: UInt8 = 1
    /// The most rides the queue holds (a bound; a ride is a few KB, at most about 230 KB).
    public static let maxRides = 24
    /// The most bytes the queue's rides take together, under the vault's 8 MB file cap.
    public static let maxBytes = 6 * 1_024 * 1_024

    /// The bytes for `rides` (at most ``maxRides``).
    public static func encode(_ rides: [WornRideCheckpoint]) -> Data {
        let kept = Array(rides.prefix(maxRides))
        var data = Data([version])
        WornRideCheckpointCodec.append(UInt16(kept.count), to: &data)
        // Bounded: at most maxRides.
        for ride in kept {
            let bytes = WornRideCheckpointCodec.encode(ride)
            WornRideCheckpointCodec.append(UInt32(clamping: bytes.count), to: &data)
            data.append(bytes)
        }
        return data
    }

    /// The rides in `data` (each at most `limit` samples), or nil when the bytes are not this format.
    public static func decode(_ data: Data, limit: Int) -> [WornRideCheckpoint]? {
        let bytes = [UInt8](data)
        guard bytes.count >= 3, bytes[0] == version else { return nil }
        let count = Int(WornRideCheckpointCodec.read(bytes, at: 1, size: 2))
        guard count <= maxRides else { return nil }
        var rides: [WornRideCheckpoint] = []
        var offset = 3
        // Bounded: count ≤ maxRides.
        for _ in 0..<count {
            guard offset + 4 <= bytes.count else { return nil }
            let size = Int(WornRideCheckpointCodec.read(bytes, at: offset, size: 4))
            guard size <= bytes.count - offset - 4,
                  let ride = WornRideCheckpointCodec.decode(Data(bytes[(offset + 4)..<(offset + 4 + size)]), limit: limit) else { return nil }
            rides.append(ride)
            offset += 4 + size
        }
        return offset == bytes.count ? rides : nil
    }
}

/// The kept trips (ferry and train build, owner 2026-11-15, C2's note "Add a per trip record"): every drive-speed
/// ride's kind, day, start and end and thinned line, so one ride can be changed or forgotten. Kept forever: a trip goes
/// only when forgotten (``delete(_:)``) or when the map is cleared.
///
/// - **In pieces.** Trips live in files of up to ``tripsPerChunk`` (`worn-trips-<piece>.bin`,
///   ``WorldMapVault/File/wornTrips(chunk:)``), so a forever history never makes one large file and an append rewrites
///   one piece. Memory holds only ``summaries`` (no lines); a line is read from its piece when asked for.
/// - **Writable locked.** Every file is under the vault's buffer key (until-first-unlock), since background drives end
///   with the phone in a pocket.
/// - **Which trips pass a cell** (``trips(through:)``): a small index from cell to the pieces holding a trip through
///   it, built from the pieces the first time it is asked for and kept up to date by appends (a deleted trip's stale
///   entries are filtered out when read).
/// - **Home's question** (owner's C1, at most once a day): the day it last asked and the ride it asked about are kept
///   in `worn-trip-meta.bin` (``recordAsked(day:trip:)``), not in `UserDefaults`.
///
/// Bounded (Power of 10): at most ``maxTrips`` trips. Past that, new trips are refused and counted in
/// ``refusedCount``, never evicted: the owner asked for no time-based removal, so this is a safety cap only (a daily
/// commute both ways for over a century). Sealed in the ``WorldMapVault``: device-only, excluded from backup, never
/// synced, exported, given to the AI or sent to friends, and removed with the vault's folder by
/// ``WorldMapVault/clearAll()``.
@MainActor
public final class WornTripStore {
    /// The most trips kept (a safety cap; no time limit).
    public static let maxTrips = 100_000
    /// Trips in one piece.
    public static let tripsPerChunk = 200
    /// The most pieces (``maxTrips`` ÷ ``tripsPerChunk``).
    public static let maxChunks = maxTrips / tripsPerChunk

    /// Every kept trip without its line, newest start first.
    public private(set) var summaries: [WornTripSummary] = []
    /// Whether ``load()`` has read the store this session.
    public private(set) var isLoaded = false
    /// Trips refused at the cap (an audit count; never shown).
    public private(set) var refusedCount = 0
    /// The ``WornDay`` Home last asked about a ride, and which ride.
    public private(set) var lastAskedDay: UInt16?
    public private(set) var askedTripID: UUID?
    /// The cap this store refuses at (``maxTrips``; tests pass a small one).
    public let limit: Int
    private var chunkCounts: [Int: Int] = [:]
    private var cellChunks: [HexCell: Set<Int>]?
    private let vault: WorldMapVault

    /// A store over `vault`, refusing past `limit` trips (at most ``maxTrips``). Call ``load()`` before using it.
    public init(vault: WorldMapVault, limit: Int = WornTripStore.maxTrips) {
        self.vault = vault
        self.limit = max(0, min(limit, Self.maxTrips))
    }

    /// Reads every piece's summaries and the question's state. A piece that can't be opened is removed (its trips are
    /// lost, the rest kept). Throws only when the buffer key can't be read (before the first unlock since boot).
    public func load() throws {
        let names = try vault.fileNames(withPrefix: WorldMapVault.File.wornTripsPrefix, limit: Self.maxChunks + 1)
        var loaded: [WornTripSummary] = []
        var counts: [Int: Int] = [:]
        // Bounded: at most maxChunks + 1 names.
        for name in names {
            guard let chunk = Self.chunkNumber(name), chunk < Self.maxChunks else { continue }
            let file = WorldMapVault.File.wornTrips(chunk: chunk)
            do {
                guard let data = try vault.read(file) else { continue }
                guard let summaries = WornTripCodec.decodeSummaries(data, chunk: chunk, limit: Self.tripsPerChunk) else {
                    throw WorldMapVault.VaultError.unopenable
                }
                loaded.append(contentsOf: summaries)
                counts[chunk] = summaries.count
            } catch WorldMapVault.VaultError.keyUnavailable {
                throw WorldMapVault.VaultError.keyUnavailable
            } catch {
                vault.remove(file)
                FernletAuditLog.log("worldMap.trips.pieceDropped")
            }
        }
        try loadMeta()
        summaries = loaded.sorted { $0.start > $1.start }
        chunkCounts = counts
        cellChunks = nil
        isLoaded = true
    }

    /// Keeps `trip` (its guess `unsure` or not); false when refused at ``maxTrips`` or before ``load()``. Writes its
    /// piece at once.
    @discardableResult
    public func append(_ trip: WornTrip, unsure: Bool) throws -> Bool {
        guard isLoaded else { return false }
        guard summaries.count < limit, let chunk = chunkWithRoom() else {
            refusedCount += 1
            return false
        }
        var trips = try readChunk(chunk)
        trips.append((trip, unsure))
        try vault.write(WornTripCodec.encode(trips), to: .wornTrips(chunk: chunk))
        chunkCounts[chunk] = trips.count
        let summary = WornTripSummary(id: trip.id, kind: trip.kind, confirmed: trip.confirmed, unsure: unsure,
                                      markedTrain: trip.markedTrain, day: trip.day, start: trip.start, end: trip.end, chunk: chunk)
        summaries.insert(summary, at: summaries.firstIndex { $0.start <= trip.start } ?? summaries.count)
        if cellChunks != nil {
            // Bounded: the cells of one line.
            for cell in WornFootpaths.cells(along: trip.line) { cellChunks?[cell, default: []].insert(chunk) }
        }
        return true
    }

    /// Trip `id` with its line, or nil when it isn't kept.
    public func trip(_ id: UUID) throws -> WornTrip? {
        guard let summary = summaries.first(where: { $0.id == id }) else { return nil }
        return try readChunk(summary.chunk).first { $0.trip.id == id }?.trip
    }

    /// The kept trips whose line passes through `cell` (``WornFootpaths/cells(along:)``), newest first.
    public func trips(through cell: HexCell) throws -> [WornTrip] {
        let index = try cellIndex()
        var found: [WornTrip] = []
        // Bounded: at most maxChunks pieces, each at most tripsPerChunk trips.
        for chunk in (index[cell] ?? []).sorted() {
            for (trip, _) in try readChunk(chunk) where WornFootpaths.cells(along: trip.line).contains(cell) {
                found.append(trip)
            }
        }
        return found.sorted { $0.start > $1.start }
    }

    /// Sets trip `id`'s kind, whether it is confirmed and whether the person said it was a train; whether it was kept.
    @discardableResult
    public func update(_ id: UUID, kind: WornWayKind, confirmed: Bool, markedTrain: Bool = false) throws -> Bool {
        guard let position = summaries.firstIndex(where: { $0.id == id }) else { return false }
        let chunk = summaries[position].chunk
        var trips = try readChunk(chunk)
        guard let inChunk = trips.firstIndex(where: { $0.trip.id == id }) else { return false }
        trips[inChunk].trip.kind = kind
        trips[inChunk].trip.confirmed = confirmed
        trips[inChunk].trip.markedTrain = markedTrain
        try vault.write(WornTripCodec.encode(trips), to: .wornTrips(chunk: chunk))
        summaries[position].kind = kind
        summaries[position].confirmed = confirmed
        summaries[position].markedTrain = markedTrain
        return true
    }

    /// The newest `limit` rail trips the person marked Train, with their lines (each piece read once): the rides
    /// learned rail comes from (F13 3B).
    public func markedTrainTrips(limit: Int) throws -> [WornTrip] {
        let wanted = summaries.filter { $0.markedTrain && $0.kind == .rail }.prefix(max(0, limit))
        let ids = Set(wanted.map(\.id))
        var found: [WornTrip] = []
        // Bounded: at most `limit` trips, in at most maxChunks pieces.
        for chunk in Set(wanted.map(\.chunk)).sorted() {
            found += try readChunk(chunk).map(\.trip).filter { ids.contains($0.id) }
        }
        return found.sorted { $0.start > $1.start }
    }

    /// Deletes trip `id` (forgotten by the person); whether it was kept. An emptied piece's file goes.
    @discardableResult
    public func delete(_ id: UUID) throws -> Bool {
        guard let position = summaries.firstIndex(where: { $0.id == id }) else { return false }
        let chunk = summaries[position].chunk
        let trips = try readChunk(chunk).filter { $0.trip.id != id }
        if trips.isEmpty {
            vault.remove(.wornTrips(chunk: chunk))
        } else {
            try vault.write(WornTripCodec.encode(trips), to: .wornTrips(chunk: chunk))
        }
        chunkCounts[chunk] = trips.count
        summaries.remove(at: position)
        if askedTripID == id { try recordAsked(day: lastAskedDay, trip: nil) }
        return true
    }

    /// Keeps the day Home asked about a ride and which ride (nil: none waiting).
    public func recordAsked(day: UInt16?, trip: UUID?) throws {
        var data = Data([1])
        let stored = day ?? UInt16.max
        data.append(UInt8(truncatingIfNeeded: stored))
        data.append(UInt8(truncatingIfNeeded: stored >> 8))
        data.append(contentsOf: WornTripCodec.uuidBytes(trip ?? Self.noTrip))
        try vault.write(data, to: .wornTripsMeta)
        lastAskedDay = day
        askedTripID = trip
    }

    /// Forgets everything in memory (the vault's ``WorldMapVault/clearAll()`` removes the files).
    public func forget() {
        summaries = []
        chunkCounts = [:]
        cellChunks = nil
        lastAskedDay = nil
        askedTripID = nil
        refusedCount = 0
    }

    // MARK: Pieces

    /// The all-zero id the meta file stores for "no ride".
    private static let noTrip = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// The piece number in a piece's file name, or nil for another file.
    static func chunkNumber(_ name: String) -> Int? {
        guard name.hasPrefix(WorldMapVault.File.wornTripsPrefix), name.hasSuffix(".bin") else { return nil }
        let digits = name.dropFirst(WorldMapVault.File.wornTripsPrefix.count).dropLast(4)
        guard digits.count == 4, digits.allSatisfy(\.isNumber) else { return nil }
        return Int(digits)
    }

    /// The lowest piece with room (pieces emptied by deletes fill again first).
    private func chunkWithRoom() -> Int? {
        (0..<Self.maxChunks).first { (chunkCounts[$0] ?? 0) < Self.tripsPerChunk }
    }

    /// Piece `chunk`'s trips (none when it has no file).
    private func readChunk(_ chunk: Int) throws -> [(trip: WornTrip, unsure: Bool)] {
        guard let data = try vault.read(.wornTrips(chunk: chunk)) else { return [] }
        guard let trips = WornTripCodec.decode(data, limit: Self.tripsPerChunk) else { throw WorldMapVault.VaultError.unopenable }
        return trips
    }

    /// The cell index, built from every piece the first time.
    private func cellIndex() throws -> [HexCell: Set<Int>] {
        if let cellChunks { return cellChunks }
        var index: [HexCell: Set<Int>] = [:]
        // Bounded: at most maxChunks pieces.
        for chunk in chunkCounts.keys.sorted() where (chunkCounts[chunk] ?? 0) > 0 {
            for (trip, _) in try readChunk(chunk) {
                for cell in WornFootpaths.cells(along: trip.line) { index[cell, default: []].insert(chunk) }
            }
        }
        cellChunks = index
        return index
    }

    /// Reads the question's state (none when the file is missing or can't be opened).
    private func loadMeta() throws {
        lastAskedDay = nil
        askedTripID = nil
        let data: Data?
        do {
            data = try vault.read(.wornTripsMeta)
        } catch WorldMapVault.VaultError.keyUnavailable {
            throw WorldMapVault.VaultError.keyUnavailable
        } catch {
            vault.remove(.wornTripsMeta)
            return
        }
        guard let data, data.count == 19, data.first == 1 else { return }
        let bytes = [UInt8](data)
        let day = UInt16(bytes[1]) | UInt16(bytes[2]) << 8
        lastAskedDay = day == UInt16.max ? nil : day
        let id = WornTripCodec.uuid(bytes, at: 3)
        askedTripID = id == Self.noTrip ? nil : id
    }
}
