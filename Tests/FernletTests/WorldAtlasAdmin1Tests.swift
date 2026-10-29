import CoreGraphics
import Foundation
import Testing
import WorldMapStore

/// The pack's `ADM1` states and provinces (Docs/World-Atlas-Pack.md): what the reader accepts and refuses, and
/// the admin-1 lookups behind the world view's lines and plate, on small packs written by
/// ``WorldAtlasTestPackBuilder``.
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

    /// ADM1 parses: tokens, countries, names (a blank Spanish name left blank) and outlines, in table order.
    @Test func theAdmin1TableParses() throws {
        let atlas = try standardAtlas()
        #expect(atlas.admin1s.map(\.token) == ["ne:9", "AA-01", "AA-02", "ne:7"])
        let west = try #require(atlas.admin1(token: "AA-01"))
        #expect(west.countryCode == "AA")
        #expect(west.names == AtlasCityNames(english: "West Province", spanish: "Provincia Oeste"))
        #expect(atlas.admin1(token: "AA-02")?.names.spanish == "")
        #expect(atlas.admin1(token: "US-OR") == nil)
        #expect(atlas.admin1s(ofCountry: "AA").map(\.token) == ["AA-01", "AA-02"])
        #expect(atlas.admin1s(ofCountry: "BB").map(\.token) == ["ne:9", "ne:7"])
        #expect(atlas.admin1s(ofCountry: "ZZ").isEmpty)
        // The outline accessor the screen draws the lines from.
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

    /// A malformed token, a repeated token, a country CTRY lacks, an empty English name and a bad outline
    /// are refused, each naming its field.
    @Test func malformedAdmin1EntriesAreRefused() throws {
        let cases: [(String, (inout WorldAtlasTestPackBuilder) -> Void, WorldAtlasPackError)] = [
            ("lower-case code", { $0.admin1s[1].token = "aa-01" }, .malformed("ADM1", "token")),
            ("Natural Earth stand-in", { $0.admin1s[1].token = "AA-X01~" }, .malformed("ADM1", "token")),
            ("ne: without digits", { $0.admin1s[0].token = "ne:" }, .malformed("ADM1", "token")),
            ("empty token", { $0.admin1s[0].token = "" }, .malformed("ADM1", "token")),
            ("repeated token", { $0.admin1s[2].token = "AA-01" }, .malformed("ADM1", "token")),
            ("unknown country", { $0.admin1s[1].country = "ZZ" }, .malformed("ADM1", "country")),
            ("empty name", { $0.admin1s[1].name = "" }, .malformed("ADM1", "name")),
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

    /// A count over the cap, a body cut short and trailing bytes are refused.
    @Test func aBadAdmin1BodyIsRefused() throws {
        var sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        let adm1 = try #require(sections.firstIndex { $0.tag == "ADM1" })
        sections[adm1].raw = Data([0xFF, 0xFF])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ADM1", "count"))
        sections[adm1].raw = Data([1, 0, 5])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .truncated("ADM1"))
        sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        sections[adm1].raw.append(0)
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ADM1", "trailingBytes"))
        sections[adm1].raw = Data([0, 0])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == nil, "an empty table opens")
    }

    /// The token shapes the reader accepts.
    @Test func admin1TokenShapes() {
        for good in ["US-OR", "AU-NSW", "FR-75", "GB-WSM", "ne:1159313269", "ne:1"] {
            #expect(AtlasAdmin1.isValidToken(good), "\(good)")
        }
        for bad in ["US-", "US-ORE1", "us-or", "U-OR", "USOR", "ne:", "ne:12a", "ne:1234567890123", "-99-X1~", "Q90"] {
            #expect(!AtlasAdmin1.isValidToken(bad), "\(bad)")
        }
    }

    /// A fix tests only its own country's entries when the country under it is known, so BB's stray ring
    /// over AA's west half never names a fix in AA; where no country is known (AA's hole) every entry counts.
    @Test func aFixReadsItsOwnCountrysStates() throws {
        let atlas = try standardAtlas()
        #expect(atlas.admin1(at: GeoPoint(-22, 22))?.token == "AA-01")
        #expect(atlas.admin1(at: GeoPoint(-38, 38))?.token == "AA-02")
        #expect(atlas.admin1(at: GeoPoint(-22, 22), inCountry: "BB")?.token == "ne:9")
        // AA's hole has no country, so the first entry holding it, BB's stray ring, answers.
        #expect(atlas.country(at: GeoPoint(-30, 27)) == nil)
        #expect(atlas.admin1(at: GeoPoint(-30, 27))?.token == "ne:9")
        #expect(atlas.admin1(at: GeoPoint(-35, 52))?.token == "ne:7")
        #expect(atlas.admin1(at: GeoPoint(-35, 57)) == nil, "BB's east half has no state")
        #expect(atlas.admin1(at: GeoPoint(5, -30)) == nil, "at sea")
        #expect(atlas.admin1(at: GeoPoint(.nan, 0)) == nil)
    }

    /// The plate's place: the state and its country, just the country where no state holds the fix, nothing
    /// at sea.
    @Test func thePlatesPlace() throws {
        let atlas = try standardAtlas()
        let west = try #require(atlas.placeName(at: GeoPoint(-22, 22)))
        #expect(west.countryCode == "AA" && west.admin1Token == "AA-01")
        #expect(west.admin1Names == AtlasCityNames(english: "West Province", spanish: "Provincia Oeste"))
        #expect(atlas.placeName(at: GeoPoint(-35, 57)) == AtlasPlaceName(countryCode: "BB"))
        #expect(atlas.placeName(at: GeoPoint(5, -30)) == nil)
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

/// The shipped pack's states and provinces (spot checks, 2026-10-29).
@MainActor
struct WorldAtlasShippedAdmin1Tests {
    /// Real places name their state or province and its country.
    @Test func realPlacesNameTheirStateOrProvince() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let places: [(name: String, point: GeoPoint, token: String, english: String, country: String)] = [
            ("Portland", GeoPoint(45.5205, -122.6255), "US-OR", "Oregon", "US"),
            ("Seattle", GeoPoint(47.6062, -122.3321), "US-WA", "Washington", "US"),
            ("Toronto", GeoPoint(43.6532, -79.3832), "CA-ON", "Ontario", "CA"),
            ("Paris (Natural Earth draws France's départements)", GeoPoint(48.8566, 2.3522), "FR-75", "Paris", "FR"),
            ("Sydney", GeoPoint(-33.8688, 151.2093), "AU-NSW", "New South Wales", "AU"),
            ("Honolulu", GeoPoint(21.307, -157.858), "US-HI", "Hawaii", "US"),
        ]
        for place in places {
            let found = atlas.placeName(at: place.point)
            #expect(found?.admin1Token == place.token, "\(place.name)")
            #expect(found?.admin1Names?.english == place.english, "\(place.name)")
            #expect(found?.countryCode == place.country, "\(place.name)")
        }
        #expect(atlas.placeName(at: GeoPoint(45.5205, -122.6255))?.admin1Names?.spanish == "Oregón")
        #expect(atlas.placeName(at: GeoPoint(0, -150)) == nil, "mid-Pacific")
        #expect(atlas.admin1(at: GeoPoint(30, -40)) == nil, "mid-Atlantic")
        // Lord Howe Island shares AU-NSW in the source; New South Wales keeps the code.
        #expect(atlas.admin1(at: GeoPoint(-31.55, 159.08))?.names.english == "Lord Howe Island")
    }

    /// Every admin-1 entry belongs to a country the pack has, and its token is unique.
    @Test func everyEntryBelongsToACountry() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        #expect(atlas.admin1s.count > 4_000)
        #expect(atlas.admin1s.allSatisfy { atlas.country(code: $0.countryCode) != nil })
        #expect(Set(atlas.admin1s.map(\.token)).count == atlas.admin1s.count)
        #expect(atlas.admin1s(ofCountry: "US").count >= 50)
    }

    /// The zoom control's words: the level, and from State in the place at the centre.
    @Test func theZoomControlsWords() throws {
        let atlas = try WorldAtlas(data: Self.shippedPack())
        let portland = GeoPoint(45.5205, -122.6255)
        #expect(atlas.zoomDescription(level: .world, centre: portland).place == nil)
        #expect(atlas.zoomDescription(level: .country, centre: portland).place == nil)
        let city = atlas.zoomDescription(level: .city, centre: portland)
        #expect(city.level == .city && city.place?.admin1Names?.english == "Oregon" && city.place?.countryCode == "US")
        #expect(atlas.zoomDescription(level: .state, centre: portland).place?.admin1Token == "US-OR")
    }

    /// The bundled pack's bytes.
    private static func shippedPack() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        return try Data(contentsOf: url)
    }
}
