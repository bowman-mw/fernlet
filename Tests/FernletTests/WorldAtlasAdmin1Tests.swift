import CoreGraphics
import Foundation
import Testing
import WorldMapStore

/// The pack's `ADM1` states and provinces and their plate groups (Docs/World-Atlas-Pack.md): what the reader
/// accepts and refuses, and the admin-1 lookups behind the world view's lines and plate, on small packs
/// written by ``WorldAtlasTestPackBuilder``.
@MainActor
struct WorldAtlasAdmin1Tests {
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

    /// The standard world's atlas.
    private func standardAtlas() throws -> WorldAtlas {
        try WorldAtlas(data: try WorldAtlasTestPackBuilder.standardWorld().build())
    }

    /// ADM1 parses: the plate groups, then tokens, countries, names (a blank Spanish name left blank), groups
    /// and outlines, in table order.
    @Test func theAdmin1TableParses() throws {
        let atlas = try standardAtlas()
        #expect(atlas.admin1s.map(\.token) == ["ne:9", "AA-01", "AA-02", "ne:7"])
        let south = AtlasAdmin1Group(token: "ne:region:AA:south", countryCode: "AA",
                                     names: AtlasCityNames(english: "South Region", spanish: "Región Sur"))
        #expect(atlas.admin1Groups == [south])
        let west = try #require(atlas.admin1(token: "AA-01"))
        #expect(west.countryCode == "AA" && west.group == south)
        #expect(west.names == AtlasCityNames(english: "West Province", spanish: "Provincia Oeste"))
        #expect(atlas.admin1(token: "AA-02")?.names.spanish == "" && atlas.admin1(token: "AA-02")?.group == south)
        let bee = try #require(atlas.admin1(token: "ne:7"))
        #expect(bee.group == AtlasAdmin1Group(token: "ne:7", countryCode: "BB", names: bee.names), "its own group")
        #expect(atlas.admin1(token: "US-OR") == nil)
        #expect(atlas.admin1s(ofCountry: "AA").map(\.token) == ["AA-01", "AA-02"])
        #expect(atlas.admin1s(ofCountry: "BB").map(\.token) == ["ne:9", "ne:7"])
        #expect(atlas.admin1s(ofCountry: "ZZ").isEmpty)
        #expect(west.polygon.ringCount == 1)
        let ring = west.polygon.ring(0)
        #expect(ring.count == 4 && abs(ring[1].longitude - 30) < 1e-9 && abs(ring[1].latitude + 40) < 1e-9)
        #expect(west.polygon.ring(1).isEmpty && west.polygon.ring(-1).isEmpty)
    }

    /// ADM1 is required: a pack without it is refused.
    @Test func aPackWithoutAdmin1IsRefused() throws {
        let sections = WorldAtlasTestPackBuilder.standardWorld().rawSections().filter { $0.tag != "ADM1" }
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .missingSection("ADM1"))
    }

    /// A malformed token, a repeated token, a country CTRY lacks, an empty English name, a group past the
    /// table or in another country, a bad group token, and a bad outline are refused, each naming its field.
    @Test func malformedAdmin1EntriesAreRefused() throws {
        let cases: [(String, (inout WorldAtlasTestPackBuilder) -> Void, WorldAtlasPackError)] = [
            ("lower-case code", { $0.admin1s[1].token = "aa-01" }, .malformed("ADM1", "token")),
            ("Natural Earth stand-in", { $0.admin1s[1].token = "AA-X01~" }, .malformed("ADM1", "token")),
            ("ne: without digits", { $0.admin1s[0].token = "ne:" }, .malformed("ADM1", "token")),
            ("empty token", { $0.admin1s[0].token = "" }, .malformed("ADM1", "token")),
            ("repeated token", { $0.admin1s[2].token = "AA-01" }, .malformed("ADM1", "token")),
            ("unknown country", { $0.admin1s[1].country = "ZZ" }, .malformed("ADM1", "country")),
            ("empty name", { $0.admin1s[1].name = "" }, .malformed("ADM1", "name")),
            ("group past the table", { $0.admin1s[1].group = 1 }, .malformed("ADM1", "group")),
            ("group in another country", { $0.admin1s[3].group = 0 }, .malformed("ADM1", "group")),
            ("bad group token", { $0.admin1Groups[0].token = "ne:region:AA:South" }, .malformed("ADM1", "groupToken")),
            ("repeated group token", { $0.admin1Groups.append($0.admin1Groups[0]) }, .malformed("ADM1", "groupToken")),
            ("group in an unknown country", { $0.admin1Groups[0].country = "ZZ" }, .malformed("ADM1", "country")),
            ("unnamed group", { $0.admin1Groups[0].name = "" }, .malformed("ADM1", "name")),
            ("two-point ring", { $0.admin1s[1].feature.rings = [[(20, -40), (30, -40)]] }, .malformed("ADM1", "pointCount")),
            ("point off the globe", { $0.admin1s[1].feature.rings = [[(20, -40), (30, -40), (30, -95)]] }, .malformed("ADM1", "point")),
            ("bad box", { $0.admin1s[1].feature.bbox = (30, -40, 20, -20) }, .malformed("ADM1", "bbox")),
        ]
        for (label, change, expected) in cases {
            var world = WorldAtlasTestPackBuilder.standardWorld()
            change(&world)
            #expect(refusal(try world.build()) == expected, "\(label)")
        }
    }

    /// Counts over the caps, a body cut short and trailing bytes are refused; empty tables open.
    @Test func aBadAdmin1BodyIsRefused() throws {
        var sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        let adm1 = try #require(sections.firstIndex { $0.tag == "ADM1" })
        sections[adm1].raw = Data([0x01, 0x04])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ADM1", "groupCount"))
        sections[adm1].raw = Data([0, 0, 0xFF, 0xFF])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ADM1", "count"))
        sections[adm1].raw = Data([0, 0, 1, 0, 5])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .truncated("ADM1"))
        sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        sections[adm1].raw.append(0)
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ADM1", "trailingBytes"))
        sections[adm1].raw = Data([0, 0, 0, 0])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == nil, "empty tables open")
    }

    /// The token shapes the reader accepts, for entries and for plate groups.
    @Test func tokenShapes() {
        for good in ["US-OR", "AU-NSW", "FR-75", "GB-WSM", "ne:1159313269", "ne:1"] {
            #expect(AtlasAdmin1.isValidToken(good), "\(good)")
        }
        for bad in ["US-", "US-ORE1", "us-or", "U-OR", "USOR", "ne:", "ne:12a", "ne:1234567890123", "-99-X1~", "Q90"] {
            #expect(!AtlasAdmin1.isValidToken(bad), "\(bad)")
        }
        for good in ["GB-ENG", "FR-IDF", "IT-62", "ES-MD", "IE-L", "ne:region:FR:cote-d-or", "ne:region:AA:south"] {
            #expect(AtlasAdmin1Group.isValidToken(good), "\(good)")
        }
        for bad in ["ne:region:fr:x", "ne:region:FR:", "ne:region:FR:Upper", "ne:region:FRA:x", "ne:region:FR-x", "England",
                    "ne:region:FR:" + String(repeating: "a", count: 41)] {
            #expect(!AtlasAdmin1Group.isValidToken(bad), "\(bad)")
        }
    }

    /// A fix tests only its own country's entries when the country under it is known, so BB's stray ring
    /// over AA's west half never names a fix in AA; where no country is known (AA's hole) every entry counts.
    @Test func aFixReadsItsOwnCountrysStates() throws {
        let atlas = try standardAtlas()
        #expect(atlas.admin1(at: GeoPoint(-22, 22))?.token == "AA-01")
        #expect(atlas.admin1(at: GeoPoint(-38, 38))?.token == "AA-02")
        #expect(atlas.admin1(at: GeoPoint(-22, 22), inCountry: "BB")?.token == "ne:9")
        #expect(atlas.country(at: GeoPoint(-30, 27)) == nil)
        #expect(atlas.admin1(at: GeoPoint(-30, 27))?.token == "ne:9")
        #expect(atlas.admin1(at: GeoPoint(-35, 52))?.token == "ne:7")
        #expect(atlas.admin1(at: GeoPoint(-35, 57)) == nil, "BB's east half has no state")
        #expect(atlas.admin1(at: GeoPoint(5, -30)) == nil, "at sea")
        #expect(atlas.admin1(at: GeoPoint(.nan, 0)) == nil)
        #expect(atlas.admin1Group(at: GeoPoint(-38, 38))?.token == "ne:region:AA:south")
        #expect(atlas.admin1Group(at: GeoPoint(-35, 52))?.token == "ne:7")
    }

    /// The plate's place is the plate group and its country, just the country where no state holds the fix,
    /// nothing at sea.
    @Test func thePlatesPlaceIsTheGroup() throws {
        let atlas = try standardAtlas()
        let west = try #require(atlas.placeName(at: GeoPoint(-22, 22)))
        #expect(west.countryCode == "AA" && west.regionToken == "ne:region:AA:south")
        #expect(west.regionNames == AtlasCityNames(english: "South Region", spanish: "Región Sur"))
        #expect(atlas.placeName(at: GeoPoint(-38, 38)) == west, "AA-02 is in the same group")
        #expect(atlas.placeName(at: GeoPoint(-35, 52))?.regionToken == "ne:7")
        #expect(atlas.placeName(at: GeoPoint(-35, 57)) == AtlasPlaceName(countryCode: "BB"))
        #expect(atlas.placeName(at: GeoPoint(5, -30)) == nil)
    }

    /// Hex edges carry a country line between countries, a state line between plate groups of one country,
    /// and nothing inside a group, at sea or beside a side with no state; levels draw them in steps.
    @Test func hexEdgesCarryLinesBetweenGroups() throws {
        let atlas = try standardAtlas()
        let west = atlas.placeName(at: GeoPoint(-22, 22)), east = atlas.placeName(at: GeoPoint(-38, 38))
        let bee = atlas.placeName(at: GeoPoint(-35, 52)), bare = atlas.placeName(at: GeoPoint(-35, 57))
        #expect(WorldAtlas.border(between: west, and: east) == .none, "one group")
        #expect(WorldAtlas.border(between: west, and: bee) == .country)
        #expect(WorldAtlas.border(between: bee, and: bare) == .none, "no state on one side")
        #expect(WorldAtlas.border(between: west, and: nil) == .none, "the sea")
        let other = AtlasPlaceName(countryCode: "AA", regionToken: "AA-09", regionNames: AtlasCityNames(english: "North"))
        #expect(WorldAtlas.border(between: west, and: other) == .region)
        let levels = AtlasZoomLevel.allCases
        #expect(levels.map { $0.draws(.region) } == [false, false, true, true])
        #expect(levels.map { $0.draws(.country) } == [false, true, true, true])
        #expect(levels.allSatisfy { !$0.draws(.none) })
        let grid = AtlasZoomLevel.city.hexGrid
        let hex = grid.cell(containing: GeoPoint(-22, 22))
        #expect(atlas.placeName(of: hex, in: grid) == atlas.placeName(at: grid.centreGeo(of: hex)))
        #expect(grid.neighbours(of: hex).count == 6 && Set(grid.neighbours(of: hex)).count == 6)
    }

    /// The line accessors return the outlines whose boxes touch a viewport, across the antimeridian too.
    @Test func theLineAccessorsFollowTheViewport() throws {
        let atlas = try standardAtlas()
        let size = CGSize(width: 400, height: 800)
        let overAA = MapViewport.around(GeoPoint(-30, 25), heightMetres: 600_000, size: size)
        #expect(Set(atlas.admin1s(overlapping: overAA).map(\.token)) == ["ne:9", "AA-01"])
        #expect(Set(atlas.countries(overlapping: overAA).map(\.code)) == ["AA"])
        let overBB = MapViewport.around(GeoPoint(-35, 55), heightMetres: 2_000_000, size: size)
        #expect(Set(atlas.admin1s(overlapping: overBB).map(\.token)) == ["ne:7"])
        let wrapped = MapViewport(minX: 1.0 + (25.0 + 180) / 360, minY: 0.55, width: 0.02, height: 0.04)
        #expect(atlas.admin1s(overlapping: wrapped).contains { $0.token == "AA-01" }, "a turn east of AA")
        #expect(atlas.admin1s(overlapping: MapViewport(minX: 0, minY: 0, width: 0, height: 1)).isEmpty)
    }
}

/// The shipped pack's states, provinces and plate groups (spot checks, 2026-10-29).
@MainActor
struct WorldAtlasShippedAdmin1Tests {
    /// Real places name their plate group (the first-level region where Natural Earth's admin-1 is
    /// second-level) and its country.
    @Test func realPlacesNameTheirRegion() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let places: [(name: String, point: GeoPoint, token: String, english: String, country: String)] = [
            ("Portland", GeoPoint(45.5205, -122.6255), "US-OR", "Oregon", "US"),
            ("Seattle", GeoPoint(47.6062, -122.3321), "US-WA", "Washington", "US"),
            ("Toronto", GeoPoint(43.6532, -79.3832), "CA-ON", "Ontario", "CA"),
            ("Sydney", GeoPoint(-33.8688, 151.2093), "AU-NSW", "New South Wales", "AU"),
            ("Honolulu", GeoPoint(21.307, -157.858), "US-HI", "Hawaii", "US"),
            ("London (Westminster)", GeoPoint(51.5074, -0.1278), "GB-ENG", "England", "GB"),
            ("Edinburgh", GeoPoint(55.9533, -3.1883), "GB-SCT", "Scotland", "GB"),
            ("Paris (the département)", GeoPoint(48.8566, 2.3522), "FR-IDF", "Île-de-France", "FR"),
            ("Rome", GeoPoint(41.9028, 12.4964), "IT-62", "Lazio", "IT"),
            ("Madrid", GeoPoint(40.4168, -3.7038), "ES-MD", "Madrid", "ES"),
            ("Dublin", GeoPoint(53.3498, -6.2603), "IE-L", "Leinster", "IE"),
            ("Cork", GeoPoint(51.8985, -8.4756), "IE-M", "Munster", "IE"),
            ("Brussels", GeoPoint(50.8467, 4.3525), "BE-BRU", "Brussels", "BE"),
            ("Manila", GeoPoint(14.5995, 120.9842), "PH-00", "Metro Manila", "PH"),
        ]
        for place in places {
            let found = atlas.placeName(at: place.point)
            #expect(found?.regionToken == place.token, "\(place.name)")
            #expect(found?.regionNames?.english == place.english, "\(place.name)")
            #expect(found?.countryCode == place.country, "\(place.name)")
        }
        #expect(atlas.placeName(at: GeoPoint(45.5205, -122.6255))?.regionNames?.spanish == "Oregón")
        #expect(atlas.placeName(at: GeoPoint(40.4168, -3.7038))?.regionNames?.spanish == "", "Madrid: stored empty")
        #expect(atlas.placeName(at: GeoPoint(51.5074, -0.1278))?.regionNames?.spanish == "Inglaterra")
        #expect(atlas.placeName(at: GeoPoint(0, -150)) == nil, "mid-Pacific")
        #expect(atlas.admin1(at: GeoPoint(30, -40)) == nil, "mid-Atlantic")
        // The entries keep their own names; only the plate groups them.
        #expect(atlas.admin1(at: GeoPoint(48.8566, 2.3522))?.token == "FR-75")
        #expect(atlas.admin1(at: GeoPoint(-31.55, 159.08))?.names.english == "Lord Howe Island")
    }

    /// Region names are the everyday English and Spanish ones (owner, 2026-10-29): "Madrid · Spain", "Bavaria ·
    /// Germany", never the official long forms. Natural Earth's own long forms lose their designation where an
    /// everyday name exists, and keep it where the rest would be an adjective, a common word or another place.
    @Test func regionNamesAreEveryday() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let places: [(name: String, point: GeoPoint, english: String, spanish: String)] = [
            ("London", GeoPoint(51.5074, -0.1278), "England", "Inglaterra"),
            ("Madrid", GeoPoint(40.4168, -3.7038), "Madrid", "Madrid"),
            ("Munich", GeoPoint(48.1351, 11.5820), "Bavaria", "Baviera"),
            ("Barcelona", GeoPoint(41.3874, 2.1686), "Catalonia", "Cataluña"),
            ("Paris", GeoPoint(48.8566, 2.3522), "Île-de-France", "Isla de Francia"),
            ("Manila", GeoPoint(14.5995, 120.9842), "Metro Manila", "Gran Manila"),
            ("Edinburgh", GeoPoint(55.9533, -3.1883), "Scotland", "Escocia"),
            ("Brussels", GeoPoint(50.8467, 4.3525), "Brussels", "Bruselas"),
            // Owner, 2026-10-30: "Go with Valencia and Kyiv city. That is the more american version of the 2".
            ("Valencia", GeoPoint(39.4699, -0.3763), "Valencia", "Valencia"),
            ("Kyiv", GeoPoint(50.4501, 30.5234), "Kyiv City", "Ciudad de Kiev"),
            ("Bila Tserkva", GeoPoint(49.7968, 30.1311), "Kyiv Oblast", "Óblast de Kiev"),
            ("Kyoto", GeoPoint(35.0116, 135.7681), "Kyoto", "Kioto"),
            ("Sapporo", GeoPoint(43.0618, 141.3545), "Hokkaido", "Hokkaido"),
        ]
        for place in places {
            let names = try #require(atlas.placeName(at: place.point)?.regionNames, "\(place.name)")
            #expect(names.english == place.english, "\(place.name)")
            #expect((names.spanish.isEmpty ? names.english : names.spanish) == place.spanish, "\(place.name)")
        }
        let entries: [(token: String, english: String)] = [
            ("ES-M", "Madrid"), ("DE-HB", "Bremen"), ("AE-DU", "Dubai"), ("JP-26", "Kyoto"), ("JP-27", "Osaka"), ("JP-28", "Hyogo"), ("RU-TA", "Tatarstan"),
            ("RU-KDA", "Krasnodar"), ("NG-KN", "Kano"), ("UA-43", "Crimea"), ("PG-NSB", "Bougainville"),
            ("MX-MEX", "State of Mexico"), ("NG-NI", "Niger State"), ("PL-SL", "Silesian Voivodeship"),
            ("ZA-FS", "Free State"), ("RU-PRI", "Primorsky Krai"),
        ]
        for entry in entries {
            #expect(atlas.admin1(token: entry.token)?.names.english == entry.english, "\(entry.token)")
        }
        #expect(atlas.admin1(token: "RU-KDA")?.names.spanish == "", "Krai de Krasnodar: stored empty")
        #expect(atlas.admin1(token: "MX-MEX")?.names.spanish == "Estado de México")
        let groups = Dictionary(atlas.admin1Groups.map { ($0.token, $0.names.english) }, uniquingKeysWith: { a, _ in a })
        #expect(groups["ES-MC"] == "Murcia" && groups["PH-15"] == "Cordillera" && groups["PH-13"] == "Caraga")
        #expect(groups["PH-14"] == "Bangsamoro" && groups["PH-03"] == "Central Luzon" && groups["BF-09"] == "Hauts-Bassins")
        #expect(groups["BF-03"] == "Centre")
    }

    /// Lines on hex edges: none between two London boroughs, a state line between England and Scotland and
    /// between Oregon and Washington, a country line between Detroit and Windsor.
    @Test func realLinesFollowTheGroups() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let place = { (lat: Double, lon: Double) in atlas.placeName(at: GeoPoint(lat, lon)) }
        #expect(WorldAtlas.border(between: place(51.5074, -0.1278), and: place(51.5390, -0.1426)) == .none,
                "Westminster and Camden")
        #expect(WorldAtlas.border(between: place(51.5074, -0.1278), and: place(55.9533, -3.1883)) == .region)
        #expect(WorldAtlas.border(between: place(45.5205, -122.6255), and: place(45.6387, -122.6615)) == .region,
                "Portland and Vancouver, Washington")
        #expect(WorldAtlas.border(between: place(42.3314, -83.0458), and: place(42.3149, -83.0364)) == .country,
                "Detroit and Windsor")
    }

    /// Every admin-1 entry belongs to a country the pack has, its token is unique, and its group is in its
    /// own country.
    @Test func everyEntryBelongsToACountry() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        #expect(atlas.admin1s.count > 4_000)
        #expect(atlas.admin1s.allSatisfy { atlas.country(code: $0.countryCode) != nil })
        #expect(atlas.admin1s.allSatisfy { $0.group.countryCode == $0.countryCode })
        #expect(Set(atlas.admin1s.map(\.token)).count == atlas.admin1s.count)
        #expect(atlas.admin1s(ofCountry: "US").count >= 50)
        #expect(Set(atlas.admin1s(ofCountry: "GB").map(\.group.token)) == ["GB-ENG", "GB-NIR", "GB-SCT", "GB-WLS"])
        #expect(Set(atlas.admin1s(ofCountry: "IE").map(\.group.token)) == ["IE-C", "IE-L", "IE-M", "IE-U"])
    }

    /// The zoom control's words: the level alone at World; the country alone at Country; the plate group and
    /// the country from State in.
    @Test func theZoomControlsWords() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let portland = GeoPoint(45.5205, -122.6255)
        #expect(atlas.zoomDescription(level: .world, centre: portland).place == nil)
        #expect(atlas.zoomDescription(level: .country, centre: portland).place == AtlasPlaceName(countryCode: "US"))
        let city = atlas.zoomDescription(level: .city, centre: portland)
        #expect(city.level == .city && city.place?.regionNames?.english == "Oregon" && city.place?.countryCode == "US")
        #expect(atlas.zoomDescription(level: .state, centre: portland).place?.regionToken == "US-OR")
        let london = GeoPoint(51.5074, -0.1278)
        #expect(atlas.zoomDescription(level: .state, centre: london).place?.regionNames?.english == "England")
        #expect(atlas.zoomDescription(level: .country, centre: london).place == AtlasPlaceName(countryCode: "GB"))
        #expect(atlas.zoomDescription(level: .country, centre: GeoPoint(0, -150)).place == nil, "at sea")
    }

    /// The bundled pack's bytes.
    private static func shippedPack() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        return try Data(contentsOf: url)
    }
}
