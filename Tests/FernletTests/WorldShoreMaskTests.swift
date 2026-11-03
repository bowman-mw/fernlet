import Foundation
import Synchronization
import Testing
import WorldMapStore
@testable import Fernlet

/// The shore pack's reader (Docs/World-Shore-Pack.md): what it accepts and everything it refuses, with small packs written
/// by ``WorldShoreTestPackBuilder``, and how it answers.
struct WorldShoreMaskFormatTests {
    /// The refusal a pack's bytes raise, or nil when they open.
    private func refusal(_ data: Data) -> WorldShoreMaskError? {
        do {
            _ = try WorldShoreMask(data: data)
            return nil
        } catch let error as WorldShoreMaskError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// A pack with one stored coast tile and one stored water tile.
    private func storedPack() throws -> WorldShoreTestPackBuilder {
        var pack = WorldShoreTestPackBuilder()
        try pack.setCoast(lat: 10, lon: 20, raw: WorldShoreTestPackBuilder.tileBytes(level: 128, fill: 1))
        try pack.setWater(lat: 10, lon: 21, code: 1, raw: WorldShoreTestPackBuilder.tileBytes(level: 32, fill: 1))
        return pack
    }

    /// A well-formed pack opens, its META readable; all-water, all-land and stored tiles answer, tile 0 being the
    /// north-west corner and a tile running from its floor latitude up to the next.
    @Test func aWellFormedPackOpens() throws {
        var pack = try storedPack()
        pack.setAllLand(lat: 89, lon: -180)
        pack.setAllLand(lat: 40, lon: 5)
        let mask = try WorldShoreMask(data: pack.build())
        #expect(mask.metaJSON == #"{"licence":"ODbL-1.0"}"#)
        #expect(mask.isLand(at: GeoPoint(89.5, -179.5)), "tile 0, the north-west corner")
        #expect(mask.isLand(at: GeoPoint(40.0, 5.0)) && mask.isLand(at: GeoPoint(40.999, 5.999)))
        #expect(!mask.isLand(at: GeoPoint(39.999, 5.5)) && !mask.isLand(at: GeoPoint(41.0, 5.5)))
        #expect(!mask.isLand(at: GeoPoint(40.5, 4.999)) && !mask.isLand(at: GeoPoint(40.5, 6.0)))
        #expect(mask.isLand(at: GeoPoint(10.5, 20.5)), "the stored coast tile")
    }

    /// A pack over the cap, wrong magic, version or level, and a file too short for its header are refused.
    @Test func theHeaderIsChecked() throws {
        let pack = try storedPack()
        #expect(refusal(Data(count: WorldShoreMask.maxPackBytes + 1)) == .tooLarge)
        #expect(refusal(Data()) == .badHeader && refusal(Data("FWS1".utf8)) == .badHeader)
        var lies = WorldShoreTestPackBuilder.Lies()
        lies.magic = "FWS2"
        #expect(refusal(try pack.build(lies: lies)) == .badMagic)
        lies = .init()
        lies.version = 2
        #expect(refusal(try pack.build(lies: lies)) == .badVersion)
        lies = .init()
        lies.coastLevel = 64
        #expect(refusal(try pack.build(lies: lies)) == .badCoastLevel)
        let whole = try pack.build()
        #expect(refusal(whole.prefix(30)) == .badHeader, "sections past the end")
    }

    /// An unknown kind or code is refused; so is a table that is not DEFLATE or disagrees with its `tableRaw`.
    @Test func theTableIsChecked() throws {
        var pack = WorldShoreTestPackBuilder()
        pack.coastKinds[7] = 3
        #expect(refusal(try pack.build()) == .badKind)
        pack = WorldShoreTestPackBuilder()
        pack.waterCodes[7] = 3
        #expect(refusal(try pack.build()) == .badCode)
        let stored = try storedPack()
        var lies = WorldShoreTestPackBuilder.Lies()
        lies.tableGarbage = true
        #expect(refusal(try stored.build(lies: lies)) == .badTable)
        lies = .init()
        lies.tableRawDelta = 4
        #expect(refusal(try stored.build(lies: lies)) == .badTable, "the stream inflates to another length")
        lies = .init()
        lies.tableRawDelta = -100
        #expect(refusal(try stored.build(lies: lies)) == .badTableLength)
        lies = .init()
        lies.tableRawDelta = 700_000
        #expect(refusal(try stored.build(lies: lies)) == .badTableLength, "nothing that large is inflated")
    }

    /// `tableRaw` must be 129,600 + 4n: a table naming lengths for tiles no kind or code stores is refused.
    @Test func tableRawMustMatchTheStoredTiles() throws {
        var lies = WorldShoreTestPackBuilder.Lies()
        lies.extraLengths = 1
        #expect(refusal(try storedPack().build(lies: lies)) == .badTableLength)
    }

    /// The lengths must exactly fill the file: a byte over or under is refused, as is a zero length.
    @Test func theLengthsFillTheFile() throws {
        let pack = try storedPack()
        var lies = WorldShoreTestPackBuilder.Lies()
        lies.trailingBytes = 1
        #expect(refusal(try pack.build(lies: lies)) == .badLengths)
        let whole = try pack.build()
        #expect(refusal(whole.prefix(whole.count - 1)) == .badLengths)
        var empty = pack
        empty.coastBodies[WorldShoreTestPackBuilder.tile(lat: 10, lon: 20)] = Data()
        #expect(refusal(try empty.build()) == .badLengths)
    }

    /// An overview that is not DEFLATE or is not exactly 259,200 bytes is refused.
    @Test func theOverviewIsChecked() throws {
        let pack = try storedPack()
        var lies = WorldShoreTestPackBuilder.Lies()
        lies.overviewGarbage = true
        #expect(refusal(try pack.build(lies: lies)) == .badOverview)
        lies = .init()
        lies.overviewBytes = 1_000
        #expect(refusal(try pack.build(lies: lies)) == .badOverview)
    }

    /// A pack handed as a slice of a larger buffer reads the same (mapped `Data` need not start at index 0).
    @Test func aSliceOfALargerBufferReadsTheSame() throws {
        var pack = WorldShoreTestPackBuilder()
        try pack.setCoast(lat: 10, lon: 20, raw: WorldShoreTestPackBuilder.tileBytes(level: 128, fill: 1))
        let whole = Data(repeating: 9, count: 5) + (try pack.build())
        let mask = try WorldShoreMask(data: whole.dropFirst(5))
        #expect(mask.isLand(at: GeoPoint(10.5, 20.5)))
    }
}

/// How the reader answers, from small packs.
struct WorldShoreMaskLookupTests {
    /// Bit order: state by cell row by row from the north-west, `bit = sy * level + sx`, least significant first, and a
    /// mixed cell's mask found among the cell's mixed fellows.
    @Test func theBitOrderIsTheDocs() throws {
        var pack = WorldShoreTestPackBuilder()
        // Cell 23 (row 2, col 3) has one bit; cell 87 (row 8, col 7) comes second among the mixed cells.
        try pack.setCoast(lat: 10, lon: 20, raw: WorldShoreTestPackBuilder.tileBytes(
            level: 128, states: [23: 2, 87: 2, 5: 1]) { cell, sx, sy in
                (cell == 23 && sx == 9 && sy == 5) || (cell == 87 && sx == 100 && sy == 127)
            })
        let mask = try WorldShoreMask(data: pack.build())
        /// The point inside sub-cell (`sx`, `sy`) of cell (`row`, `col`) of the tile.
        func spot(_ row: Int, _ col: Int, _ sx: Int, _ sy: Int) -> GeoPoint {
            GeoPoint(11 - (Double(row) * 1280.0 / 10 + Double(sy) + 0.5) / 1280, 20 + (Double(col) * 1280.0 / 10 + Double(sx) + 0.5) / 1280)
        }
        #expect(mask.isLand(at: spot(2, 3, 9, 5)))
        #expect(!mask.isLand(at: spot(2, 3, 10, 5)) && !mask.isLand(at: spot(2, 3, 8, 5)))
        #expect(!mask.isLand(at: spot(2, 3, 9, 6)) && !mask.isLand(at: spot(2, 3, 9, 4)))
        #expect(mask.isLand(at: spot(8, 7, 100, 127)), "the second mixed cell's mask")
        #expect(!mask.isLand(at: spot(8, 7, 9, 5)))
        #expect(mask.isLand(at: spot(0, 5, 3, 3)), "an all-land cell (state 1) has no mask")
        #expect(!mask.isLand(at: spot(0, 6, 3, 3)), "and a state-0 cell is water")
    }

    /// The rule: land where the coast says land and the water does not say water, at the water's own level.
    @Test func waterCutsLandAtItsOwnLevel() throws {
        var pack = WorldShoreTestPackBuilder()
        pack.setAllLand(lat: 10, lon: 20)
        pack.setAllLand(lat: 10, lon: 21)
        try pack.setWater(lat: 10, lon: 20, code: 1, raw: WorldShoreTestPackBuilder.tileBytes(
            level: 32, states: [0: 2]) { _, sx, sy in sx == 0 && sy == 0 })
        try pack.setWater(lat: 10, lon: 21, code: 2, raw: WorldShoreTestPackBuilder.tileBytes(
            level: 64, states: [0: 2]) { _, sx, sy in sx == 63 && sy == 63 })
        let mask = try WorldShoreMask(data: pack.build())
        let step32 = 0.1 / 32, step64 = 0.1 / 64
        #expect(!mask.isLand(at: GeoPoint(11 - step32 / 2, 20 + step32 / 2)), "level 32's first bit is water")
        #expect(mask.isLand(at: GeoPoint(11 - step32 * 1.5, 20 + step32 / 2)))
        #expect(!mask.isLand(at: GeoPoint(11 - 0.1 + step64 / 2, 21 + 0.1 - step64 / 2)), "level 64's last bit of the cell")
        #expect(mask.isLand(at: GeoPoint(11 - 0.1 + step64 * 1.5, 21 + 0.1 - step64 / 2)))
        #expect(mask.isLand(at: GeoPoint(10.5, 20.5)))
    }

    /// Longitude ±180 and latitude ±90 read the edge tiles; an invalid point is water with no share.
    @Test func theEdgesOfTheWorldAreHandled() throws {
        var pack = WorldShoreTestPackBuilder()
        pack.setAllLand(lat: 89, lon: 0)
        pack.setAllLand(lat: -90, lon: 0)
        pack.setAllLand(lat: 0, lon: -180)
        pack.setAllLand(lat: 5, lon: 179)
        pack.overview[0] = 255
        let mask = try WorldShoreMask(data: pack.build())
        #expect(mask.isLand(at: GeoPoint(90, 0.5)), "the top tile holds latitude 90")
        #expect(mask.isLand(at: GeoPoint(-90, 0.5)), "the bottom tile holds latitude -90")
        #expect(mask.isLand(at: GeoPoint(0.5, 180)) && mask.isLand(at: GeoPoint(0.5, -180)), "180 is -180")
        #expect(mask.isLand(at: GeoPoint(5.5, 179.9999)), "the last column")
        for bad in [GeoPoint(.nan, 0), GeoPoint(0, .infinity), GeoPoint(90.01, 0), GeoPoint(0, 181)] {
            #expect(!mask.isLand(at: bad) && mask.landShare(at: bad) == 0)
        }
        #expect(mask.landShare(at: GeoPoint(90, -180)) == 1, "the overview's corners clamp")
        #expect(mask.landShare(at: GeoPoint(-90, 180)) == 0)
    }

    /// The overview answers from its half-degree cell without opening a tile.
    @Test func theOverviewOpensNoTile() throws {
        var pack = WorldShoreTestPackBuilder()
        try pack.setCoast(lat: 10, lon: 20, raw: WorldShoreTestPackBuilder.tileBytes(level: 128, fill: 1))
        // The half-degree cell at 10.75°N, 20.25°E: row (90 - 11) × 2 = 158, column 200 × 2 = 400.
        pack.overview[158 * 720 + 400] = 51
        let mask = try WorldShoreMask(data: pack.build())
        #expect(abs(mask.landShare(at: GeoPoint(10.75, 20.25)) - 0.2) < 1e-9)
        #expect(mask.landShare(at: GeoPoint(10.25, 20.25)) == 0, "the next row down")
        #expect(mask.landShare(at: GeoPoint(10.75, 20.75)) == 0, "the next column along")
        #expect(mask.cachedTiles.count == 0)
        #expect(mask.isLand(at: GeoPoint(10.75, 20.25)))
        #expect(mask.cachedTiles.count == 1)
        mask.forgetTiles()
        #expect(mask.cachedTiles.count == 0 && mask.cachedTiles.bytes == 0)
    }

    /// A tile whose stream fails, or whose states and masks disagree, or which holds an unknown state, never traps: a
    /// bad coast tile answers from the overview, a bad water tile as no water, and it is not decoded again.
    @Test func aBadTileIsAnsweredFromWhatIsKnown() throws {
        var pack = WorldShoreTestPackBuilder()
        let notXZ = WorldShoreTestPackBuilder.tile(lat: 1, lon: 1), short = WorldShoreTestPackBuilder.tile(lat: 2, lon: 2)
        let unknown = WorldShoreTestPackBuilder.tile(lat: 3, lon: 3)
        for index in [notXZ, short, unknown] { pack.coastKinds[index] = 2 }
        pack.coastBodies[notXZ] = Data("not an xz stream".utf8)
        pack.coastBodies[short] = try WorldShoreTestPackBuilder.xz(Data(repeating: 2, count: 100))
        pack.coastBodies[unknown] = try WorldShoreTestPackBuilder.xz(Data(repeating: 9, count: 100))
        pack.setAllLand(lat: 4, lon: 4)
        pack.waterCodes[WorldShoreTestPackBuilder.tile(lat: 4, lon: 4)] = 2
        pack.waterBodies[WorldShoreTestPackBuilder.tile(lat: 4, lon: 4)] = Data("nor is this".utf8)
        // The half-degree cell at 1.75°N, 1.25°E says land; the rest of the world says water.
        pack.overview[(90 - 2) * 2 * 720 + (180 + 1) * 2] = 200
        let mask = try WorldShoreMask(data: pack.build())
        #expect(mask.isLand(at: GeoPoint(1.75, 1.25)), "from the overview: a share of 200/255")
        #expect(!mask.isLand(at: GeoPoint(1.25, 1.25)), "from the overview: a share of 0")
        #expect(!mask.isLand(at: GeoPoint(2.5, 2.5)) && !mask.isLand(at: GeoPoint(3.5, 3.5)))
        #expect(mask.isLand(at: GeoPoint(4.5, 4.5)), "a bad water tile is no water")
        #expect(mask.cachedTiles.count == 4 && mask.cachedTiles.bytes == 0, "kept as bad, holding nothing")
    }

    /// A stream that expands past a tile's largest possible size is refused rather than allocated.
    @Test func aBombIsRefused() throws {
        var pack = WorldShoreTestPackBuilder()
        pack.overview[(90 - 2) * 2 * 720 + (180 + 1) * 2] = 255
        try pack.setCoast(lat: 1, lon: 1, raw: Data(count: 300_000))
        let mask = try WorldShoreMask(data: pack.build())
        #expect(mask.isLand(at: GeoPoint(1.75, 1.25)), "answered from the overview")
        #expect(mask.cachedTiles.bytes == 0)
    }

    /// The cache keeps to its bound and readers on many tasks agree with one reader alone.
    @Test func readersOnManyTasksAgreeAndTheCacheStaysBounded() async throws {
        var pack = WorldShoreTestPackBuilder()
        // One mixed cell in each tile, its west half land.
        let raw = WorldShoreTestPackBuilder.tileBytes(level: 128, states: [0: 2]) { _, sx, _ in sx < 64 }
        // More tiles than the cache holds, so a scan keeps evicting.
        let tiles = WorldShoreMask.maxCachedTiles + 44
        for tile in 0..<tiles {
            try pack.setCoast(lat: 10 + tile / 100, lon: tile % 100, raw: raw)
        }
        let mask = try WorldShoreMask(data: pack.build())
        var points: [GeoPoint] = []
        for tile in 0..<tiles {
            let latitude = Double(10 + tile / 100) + 0.95, longitude = Double(tile % 100)
            points.append(GeoPoint(latitude, longitude + 0.01))
            points.append(GeoPoint(latitude, longitude + 0.09))
        }
        let scan = points
        let results = await withTaskGroup(of: Int.self, returning: [Int].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    var land = 0
                    for point in scan where mask.isLand(at: point) { land += 1 }
                    return land
                }
            }
            var all: [Int] = []
            for await count in group { all.append(count) }
            return all
        }
        #expect(results.allSatisfy { $0 == tiles }, "each tile's west half is land: \(results)")
        #expect(mask.cachedTiles.count <= WorldShoreMask.maxCachedTiles)
        #expect(mask.cachedTiles.bytes <= WorldShoreMask.maxCachedBytes)
    }
}

/// The shipped `WorldShore.pack`: inside its cap, the very file the checksum pins, and right about real places. Anything
/// that disagrees here is the map being wrong, so investigate it before changing an expectation.
struct WorldShoreShippedPackTests {
    /// The bundled pack's bytes, mapped.
    private static func shippedPack() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WorldShore", withExtension: "pack"))
        return try Data(contentsOf: url, options: .mappedIfSafe)
    }

    /// The bundled pack's size, checksum and licence.
    @Test func theShippedPackIsThePinnedOne() throws {
        let data = try Self.shippedPack()
        #expect(data.count <= WorldShoreMask.maxPackBytes)
        #expect(WorldAtlasPack.sha256Hex(data) == WorldShoreMask.expectedSHA256)
        let mask = try WorldShoreMask(data: data)
        let meta = mask.metaJSON ?? ""
        #expect(meta.contains("Open Database License 1.0") && meta.contains("OpenStreetMap contributors"),
                "the licence and credit travel with the data (ODbL 4.2)")
    }

    /// The pack is gitignored and fetched by hash (Docs/World-Shore-Pack.md), so the script's pin and the reader's must
    /// agree, or a fresh clone would fetch a pack the checksum above refuses.
    @Test func theFetchScriptPinsTheSamePack() throws {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: repository.appendingPathComponent("Scripts/fetch-world-shore.sh"), encoding: .utf8)
        #expect(script.contains("SHA256=\"\(WorldShoreMask.expectedSHA256)\""))
    }

    /// A place to check.
    private struct Place {
        let name: String
        let point: GeoPoint

        init(_ name: String, _ latitude: Double, _ longitude: Double) {
            self.name = name
            point = GeoPoint(latitude, longitude)
        }
    }

    /// Land the owner named.
    @Test func landIsLand() throws {
        let mask = try WorldShoreMask(data: Self.shippedPack())
        let places: [Place] = [
            Place("Santa Rosa Island", 30.334, -87.13), Place("Mercer Island", 47.57, -122.225),
            Place("Lausanne centre", 46.52, 6.633), Place("Portland downtown", 45.52, -122.68),
            Place("Chicago Loop", 41.88, -87.63), Place("Central Park lawn", 40.78, -73.965),
            Place("Kansas", 38.5, -98.5), Place("Lake Eyre, seasonal water left out", -28.4, 137.3)
        ]
        for place in places {
            #expect(mask.isLand(at: place.point), "\(place.name) should be land")
        }
    }

    /// Water the owner named.
    @Test func waterIsWater() throws {
        let mask = try WorldShoreMask(data: Self.shippedPack())
        let places: [Place] = [
            Place("Pensacola Bay", 30.38, -87.2), Place("Lake Washington", 47.62, -122.26),
            Place("Lake Sammamish", 47.59, -122.09), Place("Green Lake", 47.68, -122.34),
            Place("Lake Geneva", 46.50, 6.63), Place("Willamette", 45.515, -122.669),
            Place("Amazon at Manaus", -3.15, -59.95), Place("Lake Michigan", 44.0, -87.0),
            Place("Dead Sea", 31.5, 35.48), Place("Central Park Reservoir", 40.7855, -73.9625),
            Place("mid-Pacific", 10.0, -150.0)
        ]
        for place in places {
            #expect(!mask.isLand(at: place.point), "\(place.name) should be water")
        }
    }

    /// The overview answers the far levels: Kansas and the mid-Pacific plainly, and Lake Superior's middle as water.
    @Test func theOverviewAnswersFromAfar() throws {
        let mask = try WorldShoreMask(data: Self.shippedPack())
        #expect(mask.landShare(at: GeoPoint(38.5, -98.5)) > 0.9)
        #expect(mask.landShare(at: GeoPoint(10, -150)) == 0)
        #expect(mask.landShare(at: GeoPoint(47.5, -87.5)) < 0.1)
    }

    /// Every stored tile decodes through Apple's decoder (the pack's 256 KiB dictionary, `CHECK_NONE`) to exactly the
    /// length its states say, read straight off the file so nothing in the reader can hide a bad one.
    @Test func everyStoredTileDecodes() throws {
        let data = try Self.shippedPack()
        func u32(_ at: Int) -> Int {
            (0..<4).reduce(0) { $0 | Int(data[data.startIndex + at + $1]) << (8 * $1) }
        }
        let tableStored = u32(8), overStored = u32(16), metaLength = u32(20)
        let tableData = data.subdata(in: 24..<(24 + tableStored))
        let table = [UInt8](try (tableData as NSData).decompressed(using: .zlib) as Data)
        let tiles = WorldShoreTestPackBuilder.tiles
        var offset = 24 + tableStored + overStored + metaLength
        var levels: [Int] = table[0..<tiles].filter { $0 == 2 }.map { _ in 128 }
        levels += table[tiles..<(2 * tiles)].filter { $0 != 0 }.map { $0 == 1 ? 32 : 64 }
        #expect(table.count == 2 * tiles + 4 * levels.count)
        var bad = 0
        for (slot, level) in levels.enumerated() {
            let at = 2 * tiles + 4 * slot
            let length = (0..<4).reduce(0) { $0 | Int(table[at + $1]) << (8 * $1) }
            let raw = try autoreleasepool {
                [UInt8](try (data.subdata(in: offset..<(offset + length)) as NSData).decompressed(using: .lzma) as Data)
            }
            offset += length
            let mixed = raw.prefix(100).filter { $0 == 2 }.count
            if raw.count != 100 + mixed * (level * level / 8) { bad += 1 }
        }
        #expect(bad == 0)
        #expect(offset == data.count)
    }

    /// Every coast tile decodes through the reader itself (`compression_decode_buffer`): a bad one would hold no bytes.
    @Test func everyCoastTileDecodesThroughTheReader() throws {
        let data = try Self.shippedPack()
        let mask = try WorldShoreMask(data: data)
        let tableStored = (0..<4).reduce(0) { $0 | Int(data[data.startIndex + 8 + $1]) << (8 * $1) }
        let table = [UInt8](try (data.subdata(in: 24..<(24 + tableStored)) as NSData).decompressed(using: .zlib) as Data)
        var bad = 0, checked = 0
        for index in 0..<WorldShoreTestPackBuilder.tiles where table[index] == 2 {
            let lat = 89 - index / 360, lon = index % 360 - 180
            mask.forgetTiles()
            _ = mask.isLand(at: GeoPoint(Double(lat) + 0.5, Double(lon) + 0.5))
            checked += 1
            if mask.cachedTiles.bytes == 0 { bad += 1 }
        }
        #expect(bad == 0 && checked > 1_000, "\(bad) of \(checked) coast tiles would not decode")
    }

    /// A lookup through the reader decodes a real tile from the bundle, and holds it.
    @Test func aTileDecodesFromTheBundle() throws {
        let mask = try WorldShoreMask(data: Self.shippedPack())
        #expect(mask.cachedTiles.count == 0, "opening reads no tile")
        #expect(mask.isLand(at: GeoPoint(30.334, -87.13)))
        #expect(mask.cachedTiles.count >= 1 && mask.cachedTiles.bytes > 0)
    }
}

/// What the fog and Your world do with the mask, over a small atlas.
@MainActor
struct WorldShoreDrawingTests {
    /// A small atlas: land at (5, 5) with climate code 1, water with no climate at (5, 15); a coast cell of desert at
    /// (25, 5) whose east half is water.
    private static func atlas() throws -> WorldAtlas {
        try WorldAtlas(data: WorldAtlasTestPackBuilder.standardWorld().build())
    }

    /// A mask where each listed degree tile is all land.
    private static func mask(land: [(Int, Int)]) throws -> WorldShoreMask {
        var pack = WorldShoreTestPackBuilder()
        for (lat, lon) in land { pack.setAllLand(lat: lat, lon: lon) }
        return try WorldShoreMask(data: pack.build())
    }

    /// The hex a fog cell's centre near `point` draws.
    private static func fogCell(_ point: GeoPoint) -> (cell: HexCell, centre: GeoPoint) {
        let cell = MercatorHexGrid.cell(containing: point)
        return (cell, MercatorHexGrid.centreGeo(of: cell))
    }

    /// The mask says water where the atlas says land: the hex is water. The mask says land where the atlas says water:
    /// land, its climate from the nearest atlas cell that has one. With no mask, the atlas as ever.
    @Test func theFogReadsLandFromTheMask() throws {
        let atlas = try Self.atlas()
        let landHex = Self.fogCell(GeoPoint(5, 5)), waterHex = Self.fogCell(GeoPoint(25, 8))
        let plain = NatureFogTerrain(atlas: atlas)
        #expect(!plain.classify(landHex.cell, urban: { _ in false }).set.isWater)
        #expect(plain.classify(waterHex.cell, urban: { _ in false }).set.isWater)
        let lat = Int(waterHex.centre.latitude.rounded(.down)), lon = Int(waterHex.centre.longitude.rounded(.down))
        let terrain = NatureFogTerrain(atlas: atlas, shore: try Self.mask(land: [(lat, lon)]))
        #expect(terrain.classify(landHex.cell, urban: { _ in false }).set.isWater, "the mask's water wins")
        #expect(!terrain.classify(waterHex.cell, urban: { _ in false }).set.isWater, "the mask's island is land")
    }

    /// The climate search: the code under the point first, then the nearest ring, and 0 past the reach; the passport's
    /// `terrain(at:)` is untouched.
    @Test func theClimateSearchIsNearAndBounded() throws {
        var world = WorldAtlasTestPackBuilder.standardWorld(rows: 36)
        world.set(lat: -52.5, lon: -122.5, state: 1, climate: 4, continent: 1)
        let atlas = try WorldAtlas(data: world.build())
        let classifier = AtlasTerrainClassifier(atlas: atlas)
        #expect(classifier.nearbyClimateCode(at: GeoPoint(-52.5, -122.5)) == 4, "under the point")
        #expect(classifier.nearbyClimateCode(at: GeoPoint(-52.5, -112.5)) == 4, "two cells east")
        #expect(classifier.nearbyClimateCode(at: GeoPoint(-42.5, -132.5)) == 4, "two rings out, on the ring's corner")
        #expect(classifier.nearbyClimateCode(at: GeoPoint(-52.5, -92.5)) == 0, "six cells east is past the reach")
        #expect(classifier.landTerrain(at: GeoPoint(-52.5, -112.5)) == .desert)
        #expect(classifier.terrain(at: GeoPoint(-52.5, -112.5)) == .water, "the passport's terrain stays the atlas's")
        #expect(classifier.nearbyClimateCode(at: GeoPoint(.nan, 0)) == 0)
        let bare = try WorldAtlas(data: WorldAtlasTestPackBuilder(rows: 36).build())
        #expect(AtlasTerrainClassifier(atlas: bare).nearbyClimateCode(at: GeoPoint(2.5, 2.5)) == 0)
        #expect(AtlasTerrainClassifier(atlas: bare).landTerrain(at: GeoPoint(2.5, 2.5)) == .grassland, "the fallback")
    }

    /// A mask's arrival is a new snapshot, so the tiles redraw; the same mask is the same snapshot.
    @Test func aNewMaskIsANewSnapshot() throws {
        let atlas = try Self.atlas(), mask = try Self.mask(land: []), other = try Self.mask(land: [])
        let date = Date(timeIntervalSince1970: 0)
        let plain = NatureFogTerrain(atlas: atlas, date: date)
        #expect(plain != NatureFogTerrain(atlas: atlas, shore: mask, date: date))
        #expect(NatureFogTerrain(atlas: atlas, shore: mask, date: date) == NatureFogTerrain(atlas: atlas, shore: mask, date: date))
        #expect(NatureFogTerrain(atlas: atlas, shore: mask, date: date) != NatureFogTerrain(atlas: atlas, shore: other, date: date))
        #expect(NatureFogTerrain.home(atlas, shore: mask)?.shore === mask)
    }

    /// A tile's placeholder reads the overview, opening no tile on the main actor.
    @Test func thePlaceholderOpensNoTile() throws {
        var pack = WorldShoreTestPackBuilder()
        try pack.setCoast(lat: 5, lon: 5, raw: WorldShoreTestPackBuilder.tileBytes(level: 128, fill: 1))
        pack.overview[(90 - 6) * 2 * 720 + (180 + 5) * 2] = 255
        let mask = try WorldShoreMask(data: pack.build())
        let terrain = NatureFogTerrain(atlas: try Self.atlas(), shore: mask)
        #expect(!terrain.placeholderIsWater(at: GeoPoint(5.75, 5.25)))
        #expect(terrain.placeholderIsWater(at: GeoPoint(5.25, 5.25)))
        #expect(mask.cachedTiles.count == 0)
    }

    /// World and Country's raster reads the overview's share for the hexes, and keeps the atlas's land for the lines.
    @Test func theRasterDrawsTheShareAndLinesKeepTheAtlas() throws {
        var pack = WorldShoreTestPackBuilder()
        let row = (90 - 6) * 2, col = (180 + 5) * 2
        pack.overview[row * 720 + col] = 127
        pack.overview[row * 720 + col + 1] = 128
        let mask = try WorldShoreMask(data: pack.build())
        let atlas = try Self.atlas()
        let raster = WorldViewLandRaster(atlas: atlas, shore: mask)
        #expect(!raster.isLand(at: GeoPoint(5.75, 5.25)), "127/255 is under half")
        #expect(raster.isLand(at: GeoPoint(5.75, 5.75)), "128/255 is half or more")
        #expect(raster.atlasIsLand(at: GeoPoint(5.75, 5.25)) == atlas.isLand(at: GeoPoint(5.75, 5.25)))
        #expect(!raster.isLand(at: GeoPoint(4.25, 4.25)) && raster.atlasIsLand(at: GeoPoint(4.25, 4.25)), "lines keep the atlas")
        #expect(mask.cachedTiles.count == 0, "no tile opened")
        let plain = WorldViewLandRaster(atlas: atlas)
        #expect(plain.isLand(at: GeoPoint(4.25, 4.25)) == plain.atlasIsLand(at: GeoPoint(4.25, 4.25)))
    }

    /// A hex is land when at least half its samples are: four of seven land is land, three of seven water.
    @Test func aHexIsLandWhenHalfItsSamplesAre() throws {
        let mask = try Self.mask(land: [(5, 5)])
        let unit = WebMercator.unit(GeoPoint(5.5, 5.5))
        let inside = (x: 0.0, y: 0.0), outside = (x: 2.0 / 360, y: 0.0)
        #expect(WorldViewMapFacts.shoreLand(mask, samples: [inside, inside, inside, inside, outside, outside, outside], x: unit.x, y: unit.y))
        #expect(!WorldViewMapFacts.shoreLand(mask, samples: [inside, inside, inside, outside, outside, outside, outside], x: unit.x, y: unit.y))
        #expect(WorldViewMapFacts.shoreSamples(in: AtlasZoomLevel.state.hexGrid).count == 7)
    }

    /// From State in the hexes draw the mask and the lines' land stays the atlas's; a hex's answer is kept; without a
    /// mask both read the atlas.
    @Test func factsDrawTheMaskAndLinesKeepTheAtlas() throws {
        let atlas = try Self.atlas()
        let grid = AtlasZoomLevel.state.hexGrid
        let cell = grid.cell(containing: GeoPoint(5.5, 5.5)), centre = grid.centre(of: cell)
        var withMask = WorldViewMapFacts(detail: AtlasZoomLevel.state.detail, raster: nil, atlas: atlas, found: [], places: [:],
                                         roads: .none, lands: [:], shore: try Self.mask(land: []))
        let drawn = withMask.isLand(cell, x: centre.x, y: centre.y)
        #expect(!drawn, "the mask's water")
        #expect(withMask.holdsPlace(x: centre.x, y: centre.y), "the atlas's land, for the lines")
        #expect(withMask.lands[cell] == false, "kept per hex")
        var without = WorldViewMapFacts(detail: AtlasZoomLevel.state.detail, raster: nil, atlas: atlas, found: [], places: [:],
                                        roads: .none, lands: [:])
        let atlasDrawn = without.isLand(cell, x: centre.x, y: centre.y)
        #expect(atlasDrawn && without.holdsPlace(x: centre.x, y: centre.y))
    }

    /// The credit's switch follows the mask.
    @Test func theModelSaysWhenItDrawsOpenStreetMapData() throws {
        let empty = WorldViewModel()
        #expect(!empty.drawsOpenStreetMapData)
        var content = WorldViewContent.empty
        content.shore = try Self.mask(land: [])
        let model = WorldViewModel()
        model.load(content)
        #expect(model.drawsOpenStreetMapData)
    }

    /// The keeper opens the mask with the atlas, off the main actor, so Home's first snapshot has it; a failed or
    /// missing pack answers nil, and the map falls back.
    @Test func theKeeperOpensTheMaskWithTheAtlas() async throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let atlas = try Self.atlas(), mask = try Self.mask(land: [])
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { atlas }, openAtlasOffMain: { atlas },
                                      openShore: { .opened(mask) })
        keeper.beginOpening()
        #expect(keeper.isOpeningAtlas && keeper.openedShore == nil, "nothing is answered while it opens")
        for _ in 0..<5_000 where keeper.isOpeningAtlas {
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(keeper.openedShore === mask && keeper.openedAtlas != nil, "they arrive together")

        let plain = WorldAtlasKeeper(vault: vault, openAtlas: { atlas })
        #expect(plain.openedShore == nil, "no opener, no mask")
        let unreadable = WorldAtlasKeeper(vault: vault, openAtlas: { atlas }, openShore: { .unreadable })
        #expect(unreadable.openedShore == nil && unreadable.openedAtlas != nil, "the atlas carries on")
        let opens = WorldShoreOpenCount()
        let counted = WorldAtlasKeeper(vault: vault, openAtlas: { atlas }, openShore: {
            opens.count.withLock { $0 += 1 }
            return .missing
        })
        #expect(counted.openedShore == nil && counted.openedShore == nil)
        #expect(opens.count.withLock { $0 } == 1, "tried once a session")
    }

    /// A bundle with no pack opens nothing and says so.
    @Test func aBundleWithNoPackIsMissing() {
        guard case .missing = WorldAtlasKeeper.bundledShore(in: Bundle(for: WorldShoreBundleProbe.self))() else {
            Issue.record("expected .missing")
            return
        }
    }

    /// The real pack opens through the keeper's opener.
    @Test func theBundledPackOpensThroughTheKeepersOpener() {
        guard case .opened = WorldAtlasKeeper.bundledShore()() else {
            Issue.record("expected the shipped pack to open")
            return
        }
    }
}

/// How many times a test's shore opener ran.
private final class WorldShoreOpenCount: Sendable {
    let count = Mutex(0)
}

/// A class in the test bundle, to ask for that bundle.
private final class WorldShoreBundleProbe {}
