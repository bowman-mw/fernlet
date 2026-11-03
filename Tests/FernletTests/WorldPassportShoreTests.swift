import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The passport's land rules with the shore mask (`WorldAtlasShore.swift`, Docs/World-Atlas-Pack.md), over small worlds
/// that fix each edge of the rule.
@MainActor
struct WorldPassportShoreRuleTests {
    /// The tile every small world's island sits in: all land, with water all round it.
    private nonisolated static let tileLat = 10, tileLon = 20
    /// A fix on the island, 557 m south of its tile's north edge, so real water is near.
    private static let fix = GeoPoint(10.995, 20.5)
    /// How far a country's outline starts north of the fix, for a distance in km.
    private static func outlineSouth(km: Double) -> Double { fix.latitude + km * 1_000 / GeoPoint.metresPerDegree }

    /// A country whose outline runs from `km` north of the fix, one degree tall.
    private static func country(_ code: String, sovereign: String? = nil, km: Double) -> WorldAtlasTestPackBuilder.Country {
        let south = outlineSouth(km: km)
        return outline(code, 20, south, 21, south + 1, sovereign: sovereign)
    }

    /// A rectangular country, its own sovereign unless told otherwise.
    private static func outline(_ code: String, _ west: Double, _ south: Double, _ east: Double, _ north: Double,
                                sovereign: String? = nil) -> WorldAtlasTestPackBuilder.Country {
        typealias Feature = WorldAtlasTestPackBuilder.Feature
        return .init(code: code, sovereign: sovereign ?? code,
                     feature: Feature(bbox: (west, south, east, north), rings: [Feature.box(west, south, east, north)]))
    }

    /// A small atlas holding `countries`, all water otherwise.
    private static func atlas(_ countries: [WorldAtlasTestPackBuilder.Country]) throws -> WorldAtlas {
        var world = WorldAtlasTestPackBuilder(rows: 36)
        world.countries = countries
        return try WorldAtlas(data: world.build())
    }

    /// A mask where each listed degree tile is all land.
    private static func mask(land: [(Int, Int)] = [(tileLat, tileLon)]) throws -> WorldShoreMask {
        var pack = WorldShoreTestPackBuilder()
        for (lat, lon) in land { pack.setAllLand(lat: lat, lon: lon) }
        return try WorldShoreMask(data: pack.build())
    }

    /// The nearest outline names the country within the reach, and past it the fix keeps today's answer.
    @Test func aCountryNeedsItsOutlineWithinTheReach() throws {
        let mask = try Self.mask()
        let near = try Self.atlas([Self.country("AA", km: 2.9)]).visit(at: Self.fix, shore: mask)
        #expect(near.countryCode == "AA" && near.sovereignCode == "AA")
        let far = try Self.atlas([Self.country("AA", km: 3.1)]).visit(at: Self.fix, shore: mask)
        #expect(far.countryCode == nil && far.sovereignCode == nil, "past 3 km")
    }

    /// Another sovereign state within 6 km refuses the country, and a territory of the same sovereign does not.
    @Test func aRivalRefusesTheCountry() throws {
        let mask = try Self.mask()
        let rival = try Self.atlas([Self.country("AA", km: 1), Self.country("BB", km: 5.9)])
        #expect(rival.visit(at: Self.fix, shore: mask).countryCode == nil, "another state within 6 km")
        let distant = try Self.atlas([Self.country("AA", km: 1), Self.country("BB", km: 6.1)])
        #expect(distant.visit(at: Self.fix, shore: mask).countryCode == "AA", "another state past 6 km")
        let territory = try Self.atlas([Self.country("AA", km: 1), Self.country("BB", sovereign: "AA", km: 5.9)])
        #expect(territory.visit(at: Self.fix, shore: mask).countryCode == "AA", "its own territory is no rival")
    }

    /// With no water within 3 km the gap is not a coast's, so land no one holds stays no one's.
    @Test func aGapMustBeNearRealWater() throws {
        let inland = GeoPoint(10.5, 20.5)
        let south = inland.latitude + 1_000 / GeoPoint.metresPerDegree
        let atlas = try Self.atlas([Self.outline("AA", 20, south, 21, south + 1)])
        #expect(try atlas.visit(at: inland, shore: Self.mask()).countryCode == nil, "tile centre, 55 km from any water")
        let wholeBlock = try Self.mask(land: [(9, 19), (9, 20), (9, 21), (10, 19), (10, 20), (10, 21), (11, 19), (11, 20), (11, 21)])
        #expect(try Self.atlas([Self.country("AA", km: 1)]).visit(at: Self.fix, shore: wholeBlock).countryCode == nil,
                "the same fix, with land on every side")
    }

    /// The outlines answer first, and a country they name is not looked past, even an excluded one.
    @Test func outlinesAnswerFirstAndExclusionsHold() throws {
        let mask = try Self.mask()
        let holds = try Self.atlas([Self.outline("CC", 20, 10.9, 21, 11.2),
                                    Self.country("AA", km: 1)])
        #expect(holds.visit(at: Self.fix, shore: mask).countryCode == "CC", "the fix is inside CC's outline")
        let excludedAcross = try Self.atlas([Self.country("KP", km: 1)])
        #expect(excludedAcross.visit(at: Self.fix, shore: mask).countryCode == nil, "the nearest is excluded")
        let excludedSovereign = try Self.atlas([Self.country("XX", sovereign: "KP", km: 1)])
        #expect(excludedSovereign.visit(at: Self.fix, shore: mask).countryCode == nil, "its sovereign is excluded")
        let inside = try Self.atlas([Self.outline("KP", 20, 10.9, 21, 11.2),
                                     Self.country("AA", km: 1)])
        #expect(inside.visit(at: Self.fix, shore: mask).countryCode == nil, "inside an excluded outline, no fallback")
    }

    /// The reach crosses the antimeridian both ways.
    @Test func theReachCrossesTheAntimeridian() throws {
        let east = GeoPoint(10.5, 179.995)
        let mask = try Self.mask(land: [(10, 179)])
        let atlas = try Self.atlas([Self.outline("AA", -179.99, 10, -179, 11)])
        #expect(atlas.visit(at: east, shore: mask).countryCode == "AA")
        let west = GeoPoint(10.5, -179.995)
        let otherSide = try Self.atlas([Self.outline("BB", 179, 10, 179.99, 11)])
        #expect(try otherSide.visit(at: west, shore: Self.mask(land: [(10, -180)])).countryCode == "BB")
    }

    /// Terrain follows the mask both ways, and ocean, sea and city stay the atlas's.
    @Test func terrainFollowsTheMaskAndTheRestStays() throws {
        let atlas = try WorldAtlas(data: WorldAtlasTestPackBuilder.standardWorld().build())
        let land = GeoPoint(5, 5), water = GeoPoint(25, 8)
        #expect(atlas.visit(at: land).terrain == .tropicalForest && atlas.visit(at: water).terrain == .water)
        let visitOnWater = atlas.visit(at: land, shore: try Self.mask(land: []))
        #expect(visitOnWater.terrain == .water, "the mask's water")
        #expect(visitOnWater.continent == atlas.visit(at: land).continent, "nothing else is taken away")
        let island = try Self.mask(land: [(25, 8)])
        let visitOnLand = atlas.visit(at: water, shore: island)
        #expect(visitOnLand.terrain == .desert, "the mask's land, with its climate")
        var expected = atlas.visit(at: water)
        expected.terrain = .desert
        expected.continent = visitOnLand.continent
        #expect(visitOnLand == expected, "only terrain and continent change here")
    }

    /// The continent comes from the nearest `CONT` cell, ring by ring, and past the reach it stays none.
    @Test func theContinentIsTheNearestCell() throws {
        var world = WorldAtlasTestPackBuilder(rows: 1_800)
        world.set(lat: 40.05, lon: 20.05, state: 0, ocean: 1)
        world.set(lat: 40.45, lon: 20.05, state: 1, continent: 4)
        let atlas = try WorldAtlas(data: world.build())
        #expect(atlas.nearbyContinent(at: GeoPoint(40.45, 20.05)) == .europe, "under the point")
        #expect(atlas.nearbyContinent(at: GeoPoint(40.05, 20.05)) == .europe, "four cells south")
        #expect(atlas.nearbyContinent(at: GeoPoint(39.85, 20.05)) == nil, "six cells south is past the reach")
        #expect(atlas.nearbyContinent(at: GeoPoint(.nan, 0)) == nil)
        let mask = try Self.mask(land: [(40, 20), (39, 20)])
        #expect(atlas.visit(at: GeoPoint(40.05, 20.05)).continent == nil, "open water, so none today")
        #expect(atlas.visit(at: GeoPoint(40.05, 20.05), shore: mask).continent == .europe)
        #expect(atlas.visit(at: GeoPoint(39.85, 20.05), shore: mask).continent == nil)
        let seaOnly = try Self.mask(land: [])
        #expect(atlas.visit(at: GeoPoint(40.05, 20.05), shore: seaOnly).continent == nil, "a boat earns no continent")
    }

    /// With no mask the rules are the atlas's own, bit for bit; an invalid point is too, mask or no mask.
    @Test func noMaskIsTodaysAnswer() throws {
        let atlas = try WorldAtlas(data: WorldAtlasTestPackBuilder.standardWorld().build())
        let places = [GeoPoint(5, 5), GeoPoint(5, 15), GeoPoint(25, 8), GeoPoint(-70, 40), GeoPoint(10.1, 100.1), GeoPoint(-30, 30)]
        for place in places { #expect(atlas.visit(at: place, shore: nil) == atlas.visit(at: place)) }
        let invalid = GeoPoint(.nan, 0)
        #expect(atlas.visit(at: invalid, shore: try Self.mask()) == atlas.visit(at: invalid))
    }

    /// The landmark wrapper hands the mask on and still fills its landmarks; a resolver with no use for it ignores it.
    @Test func theResolversPassTheMaskOn() throws {
        let atlas = try Self.atlas([Self.country("AA", km: 1)]), mask = try Self.mask()
        let list = try WorldLandmarks(landmarks: [
            AtlasLandmark(token: "testPark", englishName: "Test Park", spanishName: "Parque de prueba", cityToken: "Q1",
                          point: Self.fix, findRadiusMetres: 100, tier: .generic(.park))
        ])
        let joined = AtlasWithLandmarks(atlas: atlas, landmarks: list)
        let visit = joined.visit(at: Self.fix, shore: mask)
        #expect(visit.countryCode == "AA" && visit.landmarks == ["testPark"])
        #expect(joined.visit(at: Self.fix).countryCode == nil && joined.visit(at: Self.fix).landmarks == ["testPark"])
        let fake = WorldPassportTests.atlas
        #expect(fake.visit(at: WorldPassportTests.portlandPoint, shore: mask) == fake.visit(at: WorldPassportTests.portlandPoint))
    }

    // MARK: Through the keeper, over a saved passport

    private static let t0 = Date(timeIntervalSince1970: 1_792_800_000)

    /// A passport earned before the rules keeps every entry and date, and the next fix adds to it.
    @Test func nothingEarnedIsLost() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let atlas = try Self.atlas([Self.country("AA", km: 1)]), mask = try Self.mask()
        let before = WorldAtlasKeeper(vault: vault, openAtlas: { atlas })
        before.load()
        before.observe(point: Self.fix, at: Self.t0)
        #expect(before.book.firstVisit(.terrain, token: "water") == Self.t0, "earned standing on the island, as water")
        #expect(before.book.visits(of: .country).isEmpty)

        let later = Self.t0.addingTimeInterval(86_400)
        let after = WorldAtlasKeeper(vault: vault, openAtlas: { atlas }, openShore: { .opened(mask) })
        after.load()
        after.observe(point: Self.fix, at: later)
        #expect(after.book.firstVisit(.terrain, token: "water") == Self.t0, "kept, with its date")
        #expect(after.book.firstVisit(.country, token: "AA") == later, "the next fix earns the country")
        #expect(after.book.firstVisit(.terrain, token: AtlasTerrain.grassland.rawValue) == later, "and the land's class")
    }

    /// A fix on the shore counts as being in that country, so the trip clock moves and a return a few days on is the
    /// same trip; a fix on real water beside it does not.
    @Test func aShoreFixMovesTheTripClock() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let atlas = try Self.atlas([Self.country("AA", km: 1)]), mask = try Self.mask()
        let inside = GeoPoint(11.5, 20.5)
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { atlas }, openShore: { .opened(mask) })
        keeper.load()
        keeper.observe(point: inside, at: Self.t0)
        keeper.observe(point: GeoPoint(11.01, 20.5), at: Self.t0.addingTimeInterval(5 * 86_400))
        keeper.observe(point: Self.fix, at: Self.t0.addingTimeInterval(6 * 86_400))
        #expect(keeper.book.lastSeen(inCountry: "AA") == Self.t0.addingTimeInterval(6 * 86_400))
        keeper.observe(point: inside, at: Self.t0.addingTimeInterval(10 * 86_400))
        #expect(keeper.book.trips(inCountry: "AA").count == 1, "4 days since the shore fix: the same trip")
    }

    /// A decoy reads nothing, mask or no mask.
    @Test func aDecoyKeepsNothing() throws {
        let vault = WorldMapVault.ephemeral()
        defer { _ = vault.clearAll() }
        let atlas = try Self.atlas([Self.country("AA", km: 1)]), mask = try Self.mask()
        let keeper = WorldAtlasKeeper(vault: vault, openAtlas: { atlas }, openShore: { .opened(mask) })
        keeper.load()
        keeper.setDecoy(true)
        keeper.observe(point: Self.fix, at: Self.t0)
        #expect(keeper.book.isEmpty)
    }
}

/// The rules over the shipped packs, on real places (Docs/World-Atlas-Pack.md, "With the shore mask"). A place that
/// disagrees here is a passport stamp being wrong for good, so investigate it before changing an expectation.
struct WorldPassportShoreShippedTests {
    /// The bundled atlas and mask, opened once for the suite.
    private static let packs: (atlas: WorldAtlas, shore: WorldShoreMask)? = {
        guard let atlasURL = Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"),
              let shoreURL = Bundle.main.url(forResource: "WorldShore", withExtension: "pack"),
              let atlasData = try? Data(contentsOf: atlasURL, options: .mappedIfSafe),
              let shoreData = try? Data(contentsOf: shoreURL, options: .mappedIfSafe),
              let atlas = try? WorldAtlas(data: atlasData), let shore = try? WorldShoreMask(data: shoreData) else { return nil }
        return (atlas, shore)
    }()

    /// The four places the rules were chosen on.
    @Test func theFourPlacesReadAsChosen() throws {
        let (atlas, shore) = try #require(Self.packs)
        let santaRosa = GeoPoint(30.334, -87.13)
        #expect(!atlas.isLand(at: santaRosa) && shore.isLand(at: santaRosa), "the atlas's water, the map's island")
        #expect(atlas.visit(at: santaRosa).countryCode == nil, "today's rule")
        let island = atlas.visit(at: santaRosa, shore: shore)
        #expect(island.countryCode == "US" && island.continent == .northAmerica && island.terrain == .temperateForest)
        #expect(island.sea?.names.english == "Gulf of Mexico" && island.city == nil)

        let mercer = atlas.visit(at: GeoPoint(47.57, -122.225), shore: shore)
        #expect(mercer.countryCode == "US" && mercer.continent == .northAmerica && mercer.terrain == .temperateForest)
        #expect(mercer.city?.names.english == "Seattle" && mercer.sea == nil && mercer.ocean == nil)

        let vaxholm = atlas.visit(at: GeoPoint(59.402, 18.352), shore: shore)
        #expect(vaxholm.countryCode == "SE" && vaxholm.continent == .europe && vaxholm.terrain == .temperateForest)
        #expect(vaxholm.sea?.names.english == "Baltic Sea")

        let sandhamn = atlas.visit(at: GeoPoint(59.288, 18.916), shore: shore)
        #expect(sandhamn.countryCode == nil, "Sweden's outline is 5,982 m off: past the reach, as today")
        #expect(sandhamn.continent == .europe && sandhamn.terrain == .temperateForest)

        let ouchy = atlas.visit(at: GeoPoint(46.5065, 6.627), shore: shore)
        #expect(ouchy.countryCode == "CH" && ouchy.continent == .europe && ouchy.terrain == .temperateForest)
        #expect(ouchy.city?.names.english == "Lausanne" && ouchy.sea == nil && ouchy.ocean == nil)
    }

    /// Water stays water, and a boat earns no country from the shore beside it.
    @Test func boatsStayOnWater() throws {
        let (atlas, shore) = try #require(Self.packs)
        let gulf = atlas.visit(at: GeoPoint(30.329, -87.13), shore: shore)
        #expect(gulf.countryCode == nil && gulf.continent == nil && gulf.terrain == .water)
        #expect(gulf.sea?.names.english == "Gulf of Mexico")
        let sound = atlas.visit(at: GeoPoint(30.35, -87.1), shore: shore)
        #expect(sound.countryCode == "US" && sound.terrain == .water, "inside the outline, the country stays")
        let geneva = atlas.visit(at: GeoPoint(46.46, 6.62), shore: shore)
        #expect(geneva.countryCode == "CH" && geneva.continent == .europe && geneva.terrain == .water)
    }

    /// The places a nearest-country rule would stamp wrongly for good: each stays as it is today.
    @Test func noWrongCountryIsStamped() throws {
        let (atlas, shore) = try #require(Self.packs)
        let places: [(name: String, point: GeoPoint)] = [
            ("Kastellorizo, Greek, 4.9 km from Turkey", GeoPoint(36.1420, 29.5780)),
            ("Stuart Island, American, 6 km from Canada", GeoPoint(48.68, -123.2)),
            ("Pulau Tekong, Singaporean, 4.2 km from Malaysia", GeoPoint(1.41, 104.05)),
            ("Martín García, Argentine, 5.2 km from Uruguay", GeoPoint(-34.18, -58.25)),
            ("Matsu, Taiwanese, 18 km from China", GeoPoint(26.16, 119.94)),
            ("Bir Tawil, no one's, on Sudan's line", GeoPoint(21.938, 33.263)),
            ("Kashmir's unassigned strip", GeoPoint(35.413, 77.588)),
            ("Itu Aba, disputed", GeoPoint(10.377, 114.365)),
        ]
        for place in places {
            #expect(atlas.country(at: place.point) == nil, "\(place.name): no outline holds it")
            #expect(atlas.visit(at: place.point, shore: shore).countryCode == nil, "\(place.name)")
        }
        let northKorea = GeoPoint(39.004, 125.212)
        #expect(atlas.visit(at: northKorea, shore: shore).countryCode == nil, "the nearest is North Korea, excluded")
        #expect(atlas.visit(at: northKorea, shore: shore).continent == .asia, "its continent still counts")
    }

    /// Real islands and reclaimed land the outlines miss, each given its own country.
    @Test func gapIslandsEarnTheirCountry() throws {
        let (atlas, shore) = try #require(Self.packs)
        let places: [(code: String, point: GeoPoint)] = [
            ("US", GeoPoint(26.1, -97.165)), ("AE", GeoPoint(25.112, 55.138)), ("HK", GeoPoint(22.309, 113.918)),
            ("HK", GeoPoint(22.21, 114.03)), ("FI", GeoPoint(60.146, 24.988)), ("AX", GeoPoint(59.93, 20.91)),
        ]
        for place in places {
            #expect(atlas.country(at: place.point) == nil, "\(place.code): no outline holds it")
            #expect(atlas.visit(at: place.point, shore: shore).countryCode == place.code)
        }
    }
}
