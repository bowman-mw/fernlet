import Foundation
import Synchronization

/// The bundled shore pack, opened: the fog's and Your world's land and water, far finer than the atlas's `LAND`
/// (Docs/World-Shore-Pack.md). The passport's land rules read it too, and only ever add (`WorldAtlasShore.swift`).
///
/// **Opening** reads the header, the table and the half-degree overview, and refuses (``WorldShoreMaskError``, never a
/// trap) what the doc's list refuses. Hand it mapped bytes: the tiles are read only when a lookup needs one. It
/// checks no checksum at runtime; the tests pin ``expectedSHA256``.
///
/// **Lookups** are safe from any actor, all at once. ``isLand(at:)`` decodes at most two tiles, and only when they
/// are not cached. Decoding runs outside the lock, so two readers missing one tile may both decode it (harmless: the
/// same answer, kept once), and no reader waits on another's decode.
///
/// **Memory.** The fixed parts take about 0.5 MB. The decoded tiles are held to ``maxCachedTiles`` and
/// ``maxCachedBytes``, the longest unread going first. A camera scans hexes row by row, so one row of tiles has to fit or
/// every row would decode them all again: the widest view (an iPad with the drawing's margin at the farthest detail
/// that reads tiles, about 50° of longitude) crosses about 50 tiles a band, twice over where hexes straddle two bands,
/// in two layers; that is 200 entries and, at the worst sizes (205 KB coast, 51 KB water), about 26 MB. Real tiles are
/// far smaller: 256 of them held 4 to 9 MB in the widest views measured on 2026-11-02. ``forgetTiles()`` empties it.
///
/// **A bad tile** (the xz stream fails, the length is wrong, the states and masks disagree) never traps and is not
/// decoded again: a bad coast tile answers from the overview (land at a share of ``landShareThreshold`` or more), a bad
/// water tile as no water. Nothing is logged: it cannot happen in the file the tests pin.
public nonisolated final class WorldShoreMask: Sendable {
    /// The file's first four bytes.
    public static let magic: [UInt8] = Array("FWS1".utf8)
    /// The one format version this reader knows.
    public static let version: UInt16 = 1
    /// The coast's bits a side of a 0.1° cell.
    public static let coastLevel = 128
    /// The whole file's cap: 30 MiB (owner, 2026-11-02). The generator refuses to write more, the tests fail more.
    public static let maxPackBytes = 30 * 1_048_576
    /// The shipped `WorldShore.pack`'s SHA-256, in lowercase hex. Regenerating the pack changes it on purpose, in the
    /// same commit.
    public static let expectedSHA256 = "1b6bbe3954541ab9c3169e02eb5005c4d4ebc18035f65f1ccf0bddb42c0e4a60"
    /// The most decoded tiles held at once (see "Memory" above).
    public static let maxCachedTiles = 256
    /// The most bytes those tiles hold: 32 MiB.
    public static let maxCachedBytes = 32 * 1_048_576
    /// The share of land at which a cell reads as land from afar (and a bad coast tile answers land).
    public static let landShareThreshold = 0.5

    /// Rows of 1° tiles.
    static let tileRows = 180
    /// Columns of 1° tiles.
    static let tileColumns = 360
    /// Tiles in the world.
    static let tileCount = tileRows * tileColumns
    /// Cells on a tile's side.
    static let cellsPerTileSide = 10
    /// The overview's rows of half-degree cells.
    static let overviewRows = 360
    /// The overview's columns of half-degree cells.
    static let overviewColumns = 720
    /// The overview's inflated length.
    static let overviewBytes = overviewRows * overviewColumns

    /// The whole file, mapped; only the tiles asked for are ever touched.
    private let data: Data
    private let index: WorldShoreIndex
    private let cache = Mutex(WorldShoreTileCache())

    /// The mask in `data` (a whole pack file, ideally mapped), or the reason it is refused.
    public init(data: Data) throws {
        index = try WorldShoreIndex(data: data)
        self.data = data
    }

    /// The generator's provenance JSON (`META`: licence, sources, plan), when it is text.
    public var metaJSON: String? {
        String(bytes: WorldShoreIndex.slice(data, index.metaRange), encoding: .utf8)
    }

    /// Whether `point` is land: the coast says land and the water does not say water (false for an invalid point).
    public func isLand(at point: GeoPoint) -> Bool {
        guard point.isValid else { return false }
        let place = Place(point)
        return coastSaysLand(place, at: point) && !waterSaysWater(place)
    }

    /// How much of the half-degree cell under `point` is land, 0...1, water taken out (0 for an invalid point). No
    /// tile is opened.
    public func landShare(at point: GeoPoint) -> Double {
        guard point.isValid else { return 0 }
        let rows = Self.overviewRows, columns = Self.overviewColumns
        let row = min(max(Int(((90 - point.latitude) * 2).rounded(.down)), 0), rows - 1)
        let col = min(max(Int(((AtlasGrid.normalised(point.longitude) + 180) * 2).rounded(.down)), 0), columns - 1)
        return Double(index.overview[row * columns + col]) / 255
    }

    /// Lets every decoded tile go (a screen that read many going away). The next lookups decode what they need.
    public func forgetTiles() {
        cache.withLock { $0.removeAll() }
    }

    /// How many decoded tiles are held, and the bytes they hold (the tests' proof of the bound).
    public var cachedTiles: (count: Int, bytes: Int) {
        cache.withLock { ($0.count, $0.byteCount) }
    }

    // MARK: Layers

    /// Where a point lies among the tiles: its tile and how far inside it, in degrees from the north-west corner.
    private struct Place {
        let tile: Int
        let north: Double
        let east: Double

        /// The place of a valid point: longitude normalised, latitude 90 on the top tile's north edge and -90 on the
        /// bottom tile's south edge.
        init(_ point: GeoPoint) {
            let longitude = AtlasGrid.normalised(point.longitude)
            let row = min(max(89 - Int(point.latitude.rounded(.down)), 0), WorldShoreMask.tileRows - 1)
            let col = min(max(Int(longitude.rounded(.down)) + 180, 0), WorldShoreMask.tileColumns - 1)
            tile = row * WorldShoreMask.tileColumns + col
            north = min(max(Double(90 - row) - point.latitude, 0), 1)
            east = min(max(longitude - Double(col - 180), 0), 1)
        }
    }

    /// The two layers a tile may hold.
    private enum Layer: Int {
        case coast = 0, water = 1
    }

    private func coastSaysLand(_ place: Place, at point: GeoPoint) -> Bool {
        switch index.coastKinds[place.tile] {
        case 0: return false
        case 1: return true
        default:
            guard let tile = tile(place.tile, in: .coast, level: Self.coastLevel) else {
                return landShare(at: point) >= Self.landShareThreshold
            }
            return tile.isSet(north: place.north, east: place.east)
        }
    }

    private func waterSaysWater(_ place: Place) -> Bool {
        let code = index.waterCodes[place.tile]
        guard code != 0, let tile = tile(place.tile, in: .water, level: code == 1 ? 32 : 64) else { return false }
        return tile.isSet(north: place.north, east: place.east)
    }

    // MARK: Tiles

    /// Tile `number` of `layer`, from the cache or decoded now (outside the lock); nil when it won't decode.
    private func tile(_ number: Int, in layer: Layer, level: Int) -> WorldShoreTile? {
        let key = number * 2 + layer.rawValue
        if let known = cache.withLock({ $0.read(key) }) { return known }
        let decoded = decode(number, in: layer, level: level)
        cache.withLock { $0.keep(decoded, under: key) }
        return decoded
    }

    /// Decodes tile `number` of `layer`; nil for any fault in its bytes.
    private func decode(_ number: Int, in layer: Layer, level: Int) -> WorldShoreTile? {
        let slot = storedSlot(of: number, in: layer)
        guard index.bodyOffsets.indices.contains(slot + 1) else { return nil }
        let start = index.bodiesStart + Int(index.bodyOffsets[slot]), end = index.bodiesStart + Int(index.bodyOffsets[slot + 1])
        let stored = [UInt8](WorldShoreIndex.slice(data, start..<end))
        guard let raw = WorldShoreXZ.decode(stored, limit: WorldShoreTile.decodedLimit(level: level)) else { return nil }
        return WorldShoreTile(decoded: raw, level: level)
    }

    /// Where tile `number` of `layer` sits among the stored tiles. Bounded: a row's 360 entries.
    private func storedSlot(of number: Int, in layer: Layer) -> Int {
        let row = number / Self.tileColumns, first = row * Self.tileColumns
        switch layer {
        case .coast:
            return Int(index.coastRowStarts[row]) + index.coastKinds[first..<number].reduce(0) { $0 + ($1 == 2 ? 1 : 0) }
        case .water:
            return Int(index.waterRowStarts[row]) + index.waterCodes[first..<number].reduce(0) { $0 + ($1 != 0 ? 1 : 0) }
        }
    }
}
