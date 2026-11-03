import Foundation

/// Why a shore pack was refused (Docs/World-Shore-Pack.md, "`table`"). Tokens for logs and tests, never display text.
public nonisolated enum WorldShoreMaskError: Error, Equatable, Sendable {
    /// The file is bigger than ``WorldShoreMask/maxPackBytes``.
    case tooLarge
    /// The header is cut off, or its sections run past the end of the file.
    case badHeader
    /// The first four bytes are not "FWS1".
    case badMagic
    /// The version is not ``WorldShoreMask/version``.
    case badVersion
    /// `coastLevel` is not ``WorldShoreMask/coastLevel``.
    case badCoastLevel
    /// The table is not raw DEFLATE, or inflates to any length but its `tableRaw`.
    case badTable
    /// A `coastKind` other than 0, 1 or 2.
    case badKind
    /// A `waterCode` other than 0, 1 or 2.
    case badCode
    /// `tableRaw` is not 129,600 + 4 × the stored tiles.
    case badTableLength
    /// A stored tile's length is zero, or the lengths do not exactly fill the file.
    case badLengths
    /// The overview is not raw DEFLATE, or inflates to any length but 259,200.
    case badOverview
}

/// A shore pack's fixed parts, read and checked: everything ``WorldShoreMask`` keeps in memory apart from its tiles.
nonisolated struct WorldShoreIndex: Sendable {
    /// Bytes in the fixed header.
    static let headerBytes = 24

    /// Each tile's coast kind: 0 all water, 1 all land, 2 stored.
    let coastKinds: [UInt8]
    /// Each tile's water code: 0 none, 1 stored at level 32, 2 stored at level 64.
    let waterCodes: [UInt8]
    /// Where each stored tile starts, counted from ``bodiesStart`` (coast tiles first, then water), and at the end
    /// the bodies' whole length.
    let bodyOffsets: [UInt32]
    /// How many stored tiles come before each row of 360 tiles: coast tiles.
    let coastRowStarts: [Int32]
    /// The same for water tiles, counted past the coast tiles (an index into ``bodyOffsets``).
    let waterRowStarts: [Int32]
    /// The half-degree land shares, 0–255.
    let overview: [UInt8]
    /// Where the bodies start, from the start of the file.
    let bodiesStart: Int
    /// Where `META` lies, from the start of the file.
    let metaRange: Range<Int>

    /// The fixed parts of the pack in `data`, or why it is refused. Bounded: two inflations, each into a buffer of
    /// its stated length under a fixed cap, and passes over the two 64,800-byte tables and the lengths they imply.
    init(data: Data) throws {
        guard data.count <= WorldShoreMask.maxPackBytes else { throw WorldShoreMaskError.tooLarge }
        guard data.count >= Self.headerBytes else { throw WorldShoreMaskError.badHeader }
        let header = [UInt8](data.prefix(Self.headerBytes))
        guard Array(header[0..<4]) == WorldShoreMask.magic else { throw WorldShoreMaskError.badMagic }
        guard Self.u16(header, at: 4) == WorldShoreMask.version else { throw WorldShoreMaskError.badVersion }
        guard Int(Self.u16(header, at: 6)) == WorldShoreMask.coastLevel else { throw WorldShoreMaskError.badCoastLevel }
        let tableStored = Self.u32(header, at: 8), tableRaw = Self.u32(header, at: 12)
        let overStored = Self.u32(header, at: 16), metaLength = Self.u32(header, at: 20)
        let overStart = Self.headerBytes + tableStored, metaStart = overStart + overStored
        bodiesStart = metaStart + metaLength
        guard bodiesStart <= data.count else { throw WorldShoreMaskError.badHeader }
        metaRange = metaStart..<bodiesStart
        let tiles = WorldShoreMask.tileCount
        // At most every tile stored in both layers: nothing larger is worth inflating.
        guard tableRaw >= 2 * tiles, tableRaw <= 2 * tiles + 8 * tiles else { throw WorldShoreMaskError.badTableLength }
        let tableBytes = Self.slice(data, Self.headerBytes..<overStart)
        guard let table = WorldAtlasInflate.inflate(tableBytes, rawLength: tableRaw) else { throw WorldShoreMaskError.badTable }
        coastKinds = Array(table[0..<tiles])
        waterCodes = Array(table[tiles..<(2 * tiles)])
        guard coastKinds.allSatisfy({ $0 <= 2 }) else { throw WorldShoreMaskError.badKind }
        guard waterCodes.allSatisfy({ $0 <= 2 }) else { throw WorldShoreMaskError.badCode }
        let coastStored = coastKinds.reduce(0) { $0 + ($1 == 2 ? 1 : 0) }
        let waterStored = waterCodes.reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        guard tableRaw == 2 * tiles + 4 * (coastStored + waterStored) else { throw WorldShoreMaskError.badTableLength }
        bodyOffsets = try Self.offsets(table, stored: coastStored + waterStored, filling: data.count - bodiesStart)
        coastRowStarts = Self.rowStarts(coastKinds, first: 0) { $0 == 2 }
        waterRowStarts = Self.rowStarts(waterCodes, first: coastStored) { $0 != 0 }
        let overBytes = Self.slice(data, overStart..<metaStart)
        guard let shares = WorldAtlasInflate.inflate(overBytes, rawLength: WorldShoreMask.overviewBytes) else {
            throw WorldShoreMaskError.badOverview
        }
        overview = shares
    }

    /// The bytes of `range`, counted from the start of the file (`data` may be a slice).
    static func slice(_ data: Data, _ range: Range<Int>) -> Data {
        data[(data.startIndex + range.lowerBound)..<(data.startIndex + range.upperBound)]
    }

    /// The running offsets of the `stored` lengths at the table's end. Bounded: `stored`, which `tableRaw` capped.
    private static func offsets(_ table: [UInt8], stored: Int, filling bodies: Int) throws -> [UInt32] {
        var offsets = [UInt32](repeating: 0, count: stored + 1)
        var total = 0
        for slot in 0..<stored {
            let length = u32(table, at: 2 * WorldShoreMask.tileCount + 4 * slot)
            total += length
            guard length > 0, total <= bodies else { throw WorldShoreMaskError.badLengths }
            offsets[slot + 1] = UInt32(total)
        }
        guard total == bodies else { throw WorldShoreMaskError.badLengths }
        return offsets
    }

    /// How many tiles `isStored` holds before each row, plus `first`. Bounded: one pass over a table.
    private static func rowStarts(_ table: [UInt8], first: Int, isStored: (UInt8) -> Bool) -> [Int32] {
        var starts = [Int32](repeating: 0, count: WorldShoreMask.tileRows)
        var count = first
        for row in 0..<WorldShoreMask.tileRows {
            starts[row] = Int32(count)
            let start = row * WorldShoreMask.tileColumns
            count += table[start..<(start + WorldShoreMask.tileColumns)].reduce(0) { $0 + (isStored($1) ? 1 : 0) }
        }
        return starts
    }

    /// The little-endian u16 at `at`; the caller has checked the bytes are there.
    private static func u16(_ bytes: [UInt8], at: Int) -> UInt16 {
        UInt16(bytes[at]) | UInt16(bytes[at + 1]) << 8
    }

    /// The little-endian u32 at `at` as an Int; the caller has checked the bytes are there.
    private static func u32(_ bytes: [UInt8], at: Int) -> Int {
        Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
    }
}

/// One decoded tile: immutable, shared by every reader of the cache.
nonisolated final class WorldShoreTile: Sendable {
    /// Bytes of the leading per-cell states.
    static let stateBytes = 100

    /// Masks a side of the tile's cells hold: 128 for coast, 32 or 64 for water.
    let level: Int
    /// The states, then the mixed cells' masks.
    private let bytes: [UInt8]
    /// Each cell's place among the mixed cells (meaningful only where its state is 2).
    private let mixedOrdinals: [UInt8]

    /// What memory the tile holds, for the cache's budget.
    var byteCount: Int { bytes.count + mixedOrdinals.count }

    /// The most bytes a tile of `level` can decode to: every cell mixed.
    static func decodedLimit(level: Int) -> Int {
        stateBytes + stateBytes * (level * level / 8)
    }

    /// A tile of `decoded` bytes at `level`, or nil when a state is unknown or its masks are not exactly as many as
    /// the states say. Bounded: 100 cells.
    init?(decoded: [UInt8], level: Int) {
        guard level > 0, decoded.count >= Self.stateBytes else { return nil }
        var ordinals = [UInt8](repeating: 0, count: Self.stateBytes)
        var mixed = 0
        for cell in 0..<Self.stateBytes {
            guard decoded[cell] <= 2 else { return nil }
            ordinals[cell] = UInt8(mixed)
            if decoded[cell] == 2 { mixed += 1 }
        }
        guard decoded.count == Self.stateBytes + mixed * (level * level / 8) else { return nil }
        self.level = level
        bytes = decoded
        mixedOrdinals = ordinals
    }

    /// The bit under a spot `north` and `east` of the tile's north-west corner, in degrees (0...1).
    func isSet(north: Double, east: Double) -> Bool {
        let side = WorldShoreMask.cellsPerTileSide * level
        let row = min(Int(north * Double(side)), side - 1), col = min(Int(east * Double(side)), side - 1)
        let cell = (row / level) * WorldShoreMask.cellsPerTileSide + col / level
        switch bytes[cell] {
        case 0: return false
        case 1: return true
        default:
            let bit = (row % level) * level + col % level
            let at = Self.stateBytes + Int(mixedOrdinals[cell]) * (level * level / 8) + bit >> 3
            return (bytes[at] >> UInt8(bit & 7)) & 1 == 1
        }
    }
}

/// The decoded tiles held at once: at most ``WorldShoreMask/maxCachedTiles`` and ``WorldShoreMask/maxCachedBytes``,
/// the longest unread going first. A tile that would not decode is kept as nil, so it is not decoded again.
nonisolated struct WorldShoreTileCache {
    /// One held tile.
    private struct Entry {
        let tile: WorldShoreTile?
        var lastUse: UInt64
    }

    private var entries: [Int: Entry] = [:]
    private var clock: UInt64 = 0
    private var heldBytes = 0

    /// How many tiles are held.
    var count: Int { entries.count }
    /// How many bytes they hold.
    var byteCount: Int { heldBytes }

    /// The tile under `key` marked as just read: `.some(nil)` for one known bad, nil when not held.
    mutating func read(_ key: Int) -> WorldShoreTile?? {
        guard let entry = entries[key] else { return nil }
        clock &+= 1
        entries[key]?.lastUse = clock
        return .some(entry.tile)
    }

    /// Holds `tile` under `key`, letting the longest unread go until it fits. Bounded: each pass of at most
    /// ``WorldShoreMask/maxCachedTiles`` entries lets one go, and at most that many can go.
    mutating func keep(_ tile: WorldShoreTile?, under key: Int) {
        if let old = entries.removeValue(forKey: key) { heldBytes -= old.tile?.byteCount ?? 0 }
        let incoming = tile?.byteCount ?? 0
        for _ in 0..<WorldShoreMask.maxCachedTiles {
            guard entries.count >= WorldShoreMask.maxCachedTiles || heldBytes + incoming > WorldShoreMask.maxCachedBytes,
                  let oldest = entries.min(by: { $0.value.lastUse < $1.value.lastUse }) else { break }
            entries.removeValue(forKey: oldest.key)
            heldBytes -= oldest.value.tile?.byteCount ?? 0
        }
        clock &+= 1
        entries[key] = Entry(tile: tile, lastUse: clock)
        heldBytes += incoming
    }

    /// Lets every tile go.
    mutating func removeAll() {
        entries = [:]
        heldBytes = 0
    }
}
