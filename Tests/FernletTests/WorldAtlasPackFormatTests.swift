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
        #expect(atlas.countries.count == 3 && atlas.urbanAreas.count == 2 && atlas.cities.count == 5)
        // The CITY polygon field survives for the screens: the boundary holding a city's own point, or none.
        let west = try #require(atlas.city(token: "Q1")), gap = try #require(atlas.city(token: "ne:5"))
        #expect(atlas.urbanArea(of: west) == atlas.urbanAreas.first && atlas.urbanArea(of: gap) == nil)
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
    @Test func theShippedPackIsCappedAndPinned() throws {
        let data = try Self.shippedPack()
        #expect(data.count <= WorldAtlasPack.maxPackBytes)
        #expect(WorldAtlasPack.sha256Hex(data) == WorldAtlasPack.expectedSHA256)
        _ = try WorldAtlas(data: data)
    }

    /// The shipped pack answers real places the way the owner's rules say (spot checks, 2026-10-29).
    @Test func theShippedPackKnowsRealPlaces() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let portland = atlas.visit(at: GeoPoint(45.5205, -122.6255))
        #expect(portland.countryCode == "US" && portland.continent == .northAmerica)
        #expect(portland.city?.names.english == "Portland" && portland.terrain == .temperateForest)
        // The smallest of the 195 keeps its ring.
        #expect(atlas.visit(at: GeoPoint(41.9029, 12.4534)).countryCode == "VA")
        // A sea is its own entry, never its ocean.
        let nice = atlas.visit(at: GeoPoint(43.6950, 7.2650))
        #expect(nice.sea?.names.english == "Mediterranean Sea" && nice.ocean == nil)
        // A territory counts toward its sovereign.
        let sanJuan = atlas.visit(at: GeoPoint(18.466, -66.105))
        #expect(sanJuan.countryCode == "PR" && sanJuan.sovereignCode == "US")
        // Antarctica's lighter rule at sea, and south of 60°S the ocean is the Southern Ocean.
        let drake = atlas.visit(at: GeoPoint(-60.5, -64.0))
        #expect(drake.continent == .antarctica && drake.ocean == .southern)
        // Landmass overrides: Vladivostok is Asia, Honolulu Oceania.
        #expect(atlas.visit(at: GeoPoint(43.12, 131.89)).continent == .asia)
        #expect(atlas.visit(at: GeoPoint(21.307, -157.858)).continent == .oceania)
        #expect(atlas.visit(at: GeoPoint(23.4, 12.0)).terrain == .desert)
        // Big cities whose urban boundaries Natural Earth cuts into fragments that do not follow the city
        // (owner's city rule, 2026-10-29): each fix names its own city, never a neighbour sharing the fragment.
        let places: [(name: String, point: GeoPoint, city: String)] = [
            ("Yankee Stadium, in the fragment holding Stamford's point", GeoPoint(40.8296, -73.9262), "Q60"),
            ("Brooklyn, in a fragment holding no city's point", GeoPoint(40.6782, -73.9442), "Q60"),
            ("CN Tower, which no boundary held a city for", GeoPoint(43.6426, -79.3871), "Q172"),
            ("Stanley Park, which no boundary held a city for", GeoPoint(49.3043, -123.1443), "Q24639"),
            ("Central Copenhagen, which no boundary held a city for", GeoPoint(55.6761, 12.5683), "Q1748"),
            ("Bosphorus Bridge, in the fragment holding İzmit's point", GeoPoint(41.0451, 29.0340), "Q406"),
            ("Shinjuku", GeoPoint(35.6896, 139.6917), "Q1490"),
            ("Versailles, a city of its own", GeoPoint(48.8049, 2.1204), "Q621"),
            ("Oakland, a city of its own", GeoPoint(37.8044, -122.2712), "Q17042"),
        ]
        for place in places {
            #expect(atlas.city(at: place.point)?.token == place.city, "\(place.name)")
        }
        #expect(atlas.city(at: GeoPoint(30.0, -40.0)) == nil, "mid-Atlantic")
        #expect(atlas.city(at: GeoPoint(42.0, -93.5)) == nil, "rural Iowa")
    }

    /// The Mediterranean's nine seas are nine entries (design session, Exploration v6; owner 2026-10-29): a
    /// reading in the Adriatic earns the Adriatic, never the Mediterranean, whose own stamp is its open water.
    @Test func theMediterraneansNineSeasAreTheirOwnEntries() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let seas: [(String, String, GeoPoint)] = [
            ("Mediterranean Sea", "Q4918", GeoPoint(34.0, 20.0)), ("Alboran Sea", "Q199408", GeoPoint(36.0, -3.5)),
            ("Balearic Sea", "Q200712", GeoPoint(40.5, 2.0)), ("Ligurian Sea", "Q42820", GeoPoint(43.9, 8.9)),
            ("Tyrrhenian Sea", "Q38882", GeoPoint(40.0, 12.5)), ("Ionian Sea", "Q37495", GeoPoint(38.0, 18.5)),
            ("Adriatic Sea", "Q13924", GeoPoint(43.0, 15.5)), ("Aegean Sea", "Q34575", GeoPoint(38.5, 25.0)),
            ("Sea of Crete", "Q193149", GeoPoint(35.8, 25.0)),
        ]
        for (name, token, point) in seas {
            #expect(atlas.seas.contains { $0.token == token && $0.names.english == name }, "\(name) is in SEAS")
            let visit = atlas.visit(at: point)
            #expect(visit.sea?.token == token, "\(name)'s water earns \(name)")
            #expect(visit.ocean == nil)
        }
        // A beach counts its own sea: Split is the Adriatic, Mykonos the Aegean.
        #expect(atlas.visit(at: GeoPoint(43.5031, 16.4400)).sea?.token == "Q13924")
        #expect(atlas.visit(at: GeoPoint(37.4467, 25.3289)).sea?.token == "Q34575")
    }

    /// The bundled pack's bytes.
    private static func shippedPack() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        return try Data(contentsOf: url)
    }
}
