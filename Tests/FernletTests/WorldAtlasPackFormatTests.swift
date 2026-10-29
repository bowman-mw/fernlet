import Foundation
import Testing
import WorldMapStore

/// The World atlas pack's format (Docs/World-Atlas-Pack.md): what a reader accepts and everything it refuses,
/// with small packs written by ``WorldAtlasTestPackBuilder``.
@MainActor
struct WorldAtlasPackFormatTests {
    /// The refusal a pack's bytes raise, or nil when they open.
    private func refusal(_ data: Data) -> WorldAtlasPackError? {
        do {
            _ = try WorldAtlas(data: data)
            return nil
        } catch let error as WorldAtlasPackError {
            return error
        } catch {
            Issue.record("unexpected error \(error)")
            return nil
        }
    }

    /// A well-formed pack opens, every section inflated to its stated length, and META is read.
    @Test func aWellFormedPackOpens() throws {
        let data = try WorldAtlasTestPackBuilder.standardWorld().build()
        let pack = try WorldAtlasPack(data: data)
        #expect(Set(pack.sections.keys) == Set(WorldAtlasPack.requiredTags + ["META"]))
        let atlas = try WorldAtlas(pack: pack)
        #expect(atlas.metaJSON == #"{"generator":"tests"}"#)
        #expect(atlas.countries.count == 3 && atlas.urbanAreas.count == 1 && atlas.cities.count == 4)
    }

    /// The grid size comes from the LAND header: an 18-row and a 36-row pack both open, each its own size.
    @Test func theGridSizeComesFromTheLandHeader() throws {
        let small = try WorldAtlas(data: try WorldAtlasTestPackBuilder.standardWorld(rows: 18).build())
        let finer = try WorldAtlas(data: try WorldAtlasTestPackBuilder.standardWorld(rows: 36).build())
        #expect(small.grid.rows == 18 && small.grid.cols == 36 && small.grid.step == 10)
        #expect(finer.grid.rows == 36 && finer.grid.cols == 72 && finer.grid.step == 5)
        #expect(small.isLand(at: GeoPoint(5, 5)) && finer.isLand(at: GeoPoint(5, 5)))
    }

    /// A wrong magic or version is refused.
    @Test func aWrongMagicOrVersionIsRefused() throws {
        let sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections, magic: "FWA2")) == .badMagic)
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections, version: 2)) == .badVersion)
        #expect(refusal(Data("FWA".utf8)) == .badTable)
        #expect(refusal(Data()) == .badTable)
    }

    /// A file cut short leaves its last section past the end; a table cut short is refused too.
    @Test func aTruncatedSectionIsRefused() throws {
        let data = try WorldAtlasTestPackBuilder.standardWorld().build()
        #expect(refusal(data.prefix(data.count - 3)) == .sectionOutOfBounds("META"))
        #expect(refusal(data.prefix(20)) == .badTable)
    }

    /// A rawLength one more or one less than the body inflates to is refused, as is a zero or oversized one.
    @Test func aWrongRawLengthIsRefused() throws {
        let sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections, rawLengthDelta: ["CLIM": 1])) == .wrongRawLength("CLIM"))
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections, rawLengthDelta: ["CITY": -1])) == .wrongRawLength("CITY"))
        let landLength = sections[0].raw.count
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections, rawLengthDelta: ["LAND": -landLength])) == .sectionTooLarge("LAND"))
        let huge = WorldAtlasPack.maxRawSectionBytes
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections, rawLengthDelta: ["SEAS": huge])) == .sectionTooLarge("SEAS"))
    }

    /// A missing required section and a duplicated tag are refused; META may be left out.
    @Test func aMissingOrDuplicatedSectionIsRefused() throws {
        var world = WorldAtlasTestPackBuilder.standardWorld()
        let sections = world.rawSections()
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections.filter { $0.tag != "CITY" })) == .missingSection("CITY"))
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections + [sections[1]])) == .duplicateSection("CLIM"))
        world.meta = nil
        #expect(refusal(try world.build()) == nil)
    }

    /// A file over 6 MiB is refused before anything is read.
    @Test func anOversizedFileIsRefused() {
        #expect(refusal(Data(count: WorldAtlasPack.maxPackBytes + 1)) == .tooLarge)
    }

    /// A body that ends mid-field, trailing bytes, and codes the format does not allow are refused.
    @Test func malformedBodiesAreRefused() throws {
        var sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        let city = sections.firstIndex { $0.tag == "CITY" } ?? 0
        sections[city].raw = Data([1, 0, 0, 0, 2])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .truncated("CITY"))

        sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        sections[city].raw.append(0)
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("CITY", "trailingBytes"))

        var world = WorldAtlasTestPackBuilder.standardWorld()
        world.land[0] = 3
        #expect(refusal(try world.build()) == .malformed("LAND", "state"))

        world = WorldAtlasTestPackBuilder.standardWorld()
        world.ocean[0] = 7
        #expect(refusal(try world.build()) == .malformed("OCEA", "code"), "only one sea, so 7 names nothing")

        world = WorldAtlasTestPackBuilder.standardWorld()
        world.climate[0] = 31
        #expect(refusal(try world.build()) == .malformed("CLIM", "code"))

        world = WorldAtlasTestPackBuilder.standardWorld()
        world.cities[0].polygon = 5
        #expect(refusal(try world.build()) == .malformed("CITY", "pointOrPolygon"))
    }

    /// A ring with fewer than three points, or a point off the globe, is refused.
    @Test func malformedRingsAreRefused() throws {
        var world = WorldAtlasTestPackBuilder.standardWorld()
        world.urban[0].rings = [[(100, 10), (101, 11)]]
        #expect(refusal(try world.build()) == .malformed("URBN", "pointCount"))

        world = WorldAtlasTestPackBuilder.standardWorld()
        world.countries[0].feature.rings = [[(20, -40), (40, -40), (40, -95)]]
        #expect(refusal(try world.build()) == .malformed("CTRY", "point"))
    }

    /// The SEAS table parses: token, parent ocean (display only) and names, a blank translation left blank.
    @Test func theSeasTableParses() throws {
        let atlas = try WorldAtlas(data: try WorldAtlasTestPackBuilder.standardWorld().build())
        #expect(atlas.seas.count == 1)
        let sea = try #require(atlas.seas.first)
        #expect(sea.token == "Q1247" && sea.parentOcean == .atlantic)
        #expect(sea.names == AtlasCityNames(english: "Caribbean Sea", spanish: "Mar Caribe"))
    }

    /// The countries and cities parse with their codes, flags and names.
    @Test func countriesAndCitiesParse() throws {
        let atlas = try WorldAtlas(data: try WorldAtlasTestPackBuilder.standardWorld().build())
        #expect(atlas.countries.map(\.code) == ["AA", "BB", "DD"])
        #expect(atlas.countries[1].sovereignCode == "CC" && !atlas.countries[1].isOneOf195)
        #expect(atlas.countries[0].isOneOf195 && atlas.countries[0].continent == .africa)
        let little = try #require(atlas.cities.first { $0.token == "ne:3" })
        #expect(little.size == .town && little.countryCode == "EE" && little.names.english == "Little Town")
        #expect(abs(little.point.latitude - 15) < 1e-9 && abs(little.point.longitude - 120) < 1e-9)
    }

    /// The SHA-256 helper is lowercase hex of the bytes.
    @Test func sha256HexIsLowercaseHex() {
        #expect(WorldAtlasPack.sha256Hex(Data("abc".utf8))
                == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }
}

/// The shipped `WorldAtlas.pack`: inside the 6 MiB cap and the very file `WorldAtlasPack.expectedSHA256` pins.
@MainActor
struct WorldAtlasPackTests {
    /// The bundled pack's size and checksum.
    @Test(.disabled("pack not generated yet; the lane enables it with the pinned hash"))
    func theShippedPackIsCappedAndPinned() throws {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        let data = try Data(contentsOf: url)
        #expect(data.count <= WorldAtlasPack.maxPackBytes)
        #expect(WorldAtlasPack.sha256Hex(data) == WorldAtlasPack.expectedSHA256)
        _ = try WorldAtlas(data: data)
    }
}
