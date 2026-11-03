import Foundation
import WorldMapStore

/// Writes small shore packs in the exact Docs/World-Shore-Pack.md format (little-endian, raw DEFLATE table and overview,
/// xz tiles through Apple's Compression), for the reader's tests. Every tile starts all water with no water layer, and
/// every overview cell at ``defaultShare``.
struct WorldShoreTestPackBuilder {
    /// Tiles in the world.
    static let tiles = 64_800

    /// Each tile's coast kind.
    var coastKinds = [UInt8](repeating: 0, count: tiles)
    /// Each tile's water code.
    var waterCodes = [UInt8](repeating: 0, count: tiles)
    /// The stored coast tiles' xz bodies, by tile index.
    var coastBodies: [Int: Data] = [:]
    /// The stored water tiles' xz bodies, by tile index.
    var waterBodies: [Int: Data] = [:]
    /// The half-degree shares, row by row.
    var overview = [UInt8](repeating: defaultShare, count: 259_200)

    /// What an overview cell holds until set.
    static let defaultShare: UInt8 = 0

    /// The tile index under a point, by the doc's rule.
    static func tile(lat: Int, lon: Int) -> Int {
        (89 - lat) * 360 + (lon + 180)
    }

    /// A tile's decoded bytes at `level`: each cell's state from `states` (default `fill`), and for a mixed cell the
    /// mask `mask(cell, sx, sy)` says.
    static func tileBytes(level: Int, fill: UInt8 = 0, states: [Int: UInt8] = [:],
                          mask: (Int, Int, Int) -> Bool = { _, _, _ in false }) -> Data {
        var bytes = (0..<100).map { states[$0] ?? fill }
        for cell in 0..<100 where bytes[cell] == 2 {
            var bits = [UInt8](repeating: 0, count: level * level / 8)
            for sy in 0..<level {
                for sx in 0..<level where mask(cell, sx, sy) {
                    let bit = sy * level + sx
                    bits[bit >> 3] |= UInt8(1 << (bit & 7))
                }
            }
            bytes += bits
        }
        return Data(bytes)
    }

    /// `raw` as an xz stream.
    static func xz(_ raw: Data) throws -> Data {
        try (raw as NSData).compressed(using: .lzma) as Data
    }

    /// Stores a coast tile at (`lat`, `lon`) holding `raw`.
    mutating func setCoast(lat: Int, lon: Int, raw: Data) throws {
        let index = Self.tile(lat: lat, lon: lon)
        coastKinds[index] = 2
        coastBodies[index] = try Self.xz(raw)
    }

    /// Stores a water tile at (`lat`, `lon`) of `code` holding `raw`.
    mutating func setWater(lat: Int, lon: Int, code: UInt8, raw: Data) throws {
        let index = Self.tile(lat: lat, lon: lon)
        waterCodes[index] = code
        waterBodies[index] = try Self.xz(raw)
    }

    /// Makes the tile at (`lat`, `lon`) all land.
    mutating func setAllLand(lat: Int, lon: Int) {
        coastKinds[Self.tile(lat: lat, lon: lon)] = 1
    }

    /// Fields a test can lie about.
    struct Lies {
        var magic = "FWS1"
        var version: UInt16 = 1
        var coastLevel: UInt16 = 128
        var tableRawDelta = 0
        var extraLengths = 0
        var trailingBytes = 0
        var overviewBytes: Int?
        var overviewGarbage = false
        var tableGarbage = false
    }

    /// The pack file.
    func build(lies: Lies = Lies(), meta: String = #"{"licence":"ODbL-1.0"}"#) throws -> Data {
        let order = coastKinds.indices.filter { coastKinds[$0] == 2 }.compactMap { coastBodies[$0] }
            + waterCodes.indices.filter { waterCodes[$0] != 0 }.compactMap { waterBodies[$0] }
        var rawTable = Data(coastKinds + waterCodes)
        for body in order { rawTable.appendShoreLE(UInt32(body.count)) }
        for _ in 0..<lies.extraLengths { rawTable.appendShoreLE(UInt32(1)) }
        let table = lies.tableGarbage ? Data([1, 2, 3]) : try (rawTable as NSData).compressed(using: .zlib) as Data
        let shares = lies.overviewBytes.map { Data(overview.prefix($0)) } ?? Data(overview)
        let over = lies.overviewGarbage ? Data([1, 2, 3]) : try (shares as NSData).compressed(using: .zlib) as Data
        let metaBytes = Data(meta.utf8)
        var file = Data(lies.magic.utf8)
        file.appendShoreLE(lies.version)
        file.appendShoreLE(lies.coastLevel)
        file.appendShoreLE(UInt32(table.count))
        file.appendShoreLE(UInt32(rawTable.count + lies.tableRawDelta))
        file.appendShoreLE(UInt32(over.count))
        file.appendShoreLE(UInt32(metaBytes.count))
        file += table + over + metaBytes
        for body in order { file += body }
        file += Data(repeating: 0, count: lies.trailingBytes)
        return file
    }
}

fileprivate extension Data {
    /// Appends `value` little-endian.
    mutating func appendShoreLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
