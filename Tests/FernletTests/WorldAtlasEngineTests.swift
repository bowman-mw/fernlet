import Foundation
import Testing
import WorldMapStore

/// The World atlas engines on a small hand-built pack (``WorldAtlasTestPackBuilder/standardWorld(rows:)``):
/// land, water and coast lookups, the visit rules (country, continent and Antarctica, the ocean or sea
/// within 2 km, the city), terrain classes and flora, and the seasons.
@MainActor
struct WorldAtlasEngineTests {
    private static func atlas(rows: Int = 18) throws -> WorldAtlas {
        try WorldAtlas(data: try WorldAtlasTestPackBuilder.standardWorld(rows: rows).build())
    }

    /// Degrees of longitude `metres` make at `latitude`.
    private static func degreesEast(_ metres: Double, at latitude: Double) -> Double {
        metres / GeoPoint(latitude, 0).metresPerDegreeLongitude
    }

    // MARK: Land, water and coast

    /// A land cell is land, a water cell water, and a coast cell answers from its sub-mask.
    @Test func landWaterAndCoastLookups() throws {
        let atlas = try Self.atlas()
        #expect(atlas.isLand(at: GeoPoint(5, 5)))
        #expect(!atlas.isLand(at: GeoPoint(5, 15)) && !atlas.isLand(at: GeoPoint(-30, 30)))
        #expect(atlas.isLand(at: GeoPoint(25, 2)), "the coast cell's west half is land")
        #expect(!atlas.isLand(at: GeoPoint(25, 8)), "and its east half water")
        #expect(!atlas.isLand(at: GeoPoint(.nan, 5)) && !atlas.isLand(at: GeoPoint(95, 5)))
    }

    /// One sub-mask bit (sx 5, sy 3: 23.125–23.75°E, 27.5–28.125°N) is land and its neighbours are not.
    @Test func aSingleSubMaskBitIsLand() throws {
        let atlas = try Self.atlas()
        #expect(atlas.isLand(at: GeoPoint(27.8, 23.4)))
        #expect(!atlas.isLand(at: GeoPoint(27.8, 24.0)), "sx 6")
        #expect(!atlas.isLand(at: GeoPoint(28.3, 23.4)), "sy 2")
        #expect(!atlas.isLand(at: GeoPoint(27.8, 22.9)), "sx 4")
    }

    /// Longitudes wrap on the grid: 365°E is 5°E, and -180 and 180 meet.
    @Test func longitudesWrap() throws {
        let atlas = try Self.atlas()
        #expect(atlas.grid.index(of: GeoPoint(5, 365)) == atlas.grid.index(of: GeoPoint(5, 5)))
        #expect(atlas.grid.index(of: GeoPoint(5, 180)) == atlas.grid.index(of: GeoPoint(5, -180)))
    }

    // MARK: Country and continent

    /// A point in a country's hole is not in it; one between the rings is; a territory names its sovereign.
    @Test func aCountryWithAHole() throws {
        let atlas = try Self.atlas()
        #expect(atlas.country(at: GeoPoint(-22, 22))?.code == "AA")
        #expect(atlas.country(at: GeoPoint(-30, 30)) == nil, "the hole")
        #expect(atlas.country(at: GeoPoint(-38, 38))?.code == "AA")
        let territory = try #require(atlas.country(at: GeoPoint(-35, 55)))
        #expect(territory.code == "BB" && territory.sovereignCode == "CC")
        #expect(atlas.country(at: GeoPoint(-45, 30)) == nil)
    }

    /// The box is checked first: DD's ring covers 70–80°E but its box sits at 0–1°, so nothing finds it there.
    @Test func theBoxPrefilterDecidesFirst() throws {
        let atlas = try Self.atlas()
        let dd = try #require(atlas.countries.first { $0.code == "DD" })
        #expect(!dd.polygon.boxContains(GeoPoint(-35, 75)))
        #expect(!dd.polygon.contains(GeoPoint(-35, 75)) && atlas.country(at: GeoPoint(-35, 75)) == nil)
        #expect(atlas.countries[0].polygon.boxContains(GeoPoint(-30, 30)), "AA's hole is inside its box")
    }

    /// A land fix counts its CONT cell; a fix at sea north of 60°S counts no continent.
    @Test func continentFromTheGrid() throws {
        let atlas = try Self.atlas()
        #expect(atlas.continent(at: GeoPoint(5, 5)) == .africa)
        #expect(atlas.continent(at: GeoPoint(25, 2)) == .africa, "the coast cell's land half")
        #expect(atlas.continent(at: GeoPoint(25, 8)) == nil, "its water half")
        #expect(atlas.continent(at: GeoPoint(5, 15)) == nil)
    }

    /// Any fix south of 60°S counts Antarctica, even at sea; one just north of the line does not.
    @Test func antarcticaCountsSouthOfSixtyEvenAtSea() throws {
        let atlas = try Self.atlas()
        #expect(WorldAtlas.antarcticaLatitude == -60)
        #expect(atlas.continent(at: GeoPoint(-60.1, 100)) == .antarctica)
        #expect(atlas.visit(at: GeoPoint(-60.1, 100)).continent == .antarctica)
        #expect(atlas.continent(at: GeoPoint(-59.9, 100)) == nil)
        #expect(atlas.visit(at: GeoPoint(-59.9, 100)).continent == nil)
    }

    // MARK: Ocean and sea

    /// Water 1,990 m away counts its ocean; 2,010 m away does not (the reach is 2 km, owner 2026-10-29).
    @Test func theOceanReachIsTwoKilometres() throws {
        let atlas = try Self.atlas()
        #expect(WorldAtlas.oceanReachMetres == 2_000)
        let inside = GeoPoint(5, 10 - Self.degreesEast(1_990, at: 5))
        let outside = GeoPoint(5, 10 - Self.degreesEast(2_010, at: 5))
        #expect(atlas.water(near: inside) == .ocean(.atlantic))
        #expect(atlas.water(near: outside) == nil)
        #expect(atlas.visit(at: inside).ocean == .atlantic && atlas.visit(at: inside).sea == nil)
        #expect(atlas.visit(at: outside).ocean == nil)
        #expect(atlas.water(near: GeoPoint(5, 15)) == .ocean(.atlantic), "at sea, distance zero")
    }

    /// Water no ocean names (a lake, the Caspian) never counts, however close.
    @Test func aLakeDoesNotCount() throws {
        let atlas = try Self.atlas()
        let shore = GeoPoint(5, Self.degreesEast(300, at: 5))
        #expect(atlas.water(near: shore) == nil)
        #expect(atlas.water(near: GeoPoint(5, -5)) == nil, "on the lake itself")
    }

    /// A coast cell's water sub-cells are within reach: 1 km from the east half counts, 3 km does not.
    @Test func aCoastCellsWaterHalfIsWithinReach() throws {
        let atlas = try Self.atlas()
        #expect(atlas.water(near: GeoPoint(25, 5 - Self.degreesEast(1_000, at: 25))) == .ocean(.atlantic))
        #expect(atlas.water(near: GeoPoint(25, 5 - Self.degreesEast(3_000, at: 25))) == nil)
    }

    /// A sea cell gives the sea and no ocean (the Caribbean counts the Caribbean Sea, not the Atlantic).
    @Test func aSeaCellGivesTheSeaAndNoOcean() throws {
        let atlas = try Self.atlas()
        let fix = GeoPoint(10 - 1_000 / GeoPoint.metresPerDegree, 5)
        let visit = atlas.visit(at: fix)
        #expect(visit.sea?.token == "Q1247" && visit.sea?.parentOcean == .atlantic)
        #expect(visit.ocean == nil)
        let caribbean = try #require(atlas.seas.first)
        #expect(atlas.water(near: GeoPoint(15, 5)) == .sea(caribbean))
    }

    // MARK: Cities

    /// Inside an urban boundary, the nearest of the cities sharing it.
    @Test func aSharedBoundaryGivesTheNearestCity() throws {
        let atlas = try Self.atlas()
        #expect(atlas.city(at: GeoPoint(10.6, 100.6))?.token == "Q1")
        #expect(atlas.city(at: GeoPoint(11.4, 101.4))?.token == "Q2")
        #expect(atlas.city(at: GeoPoint(11.0, 100.1))?.token == "Q1", "nearer Q1, still inside")
        #expect(atlas.city(at: GeoPoint(12.5, 101.5)) == nil, "outside the boundary, no loose city near")
    }

    /// A city with no boundary is entered within its size's radius: a town 2 km, a city 4 km.
    @Test func aCityWithNoBoundaryUsesItsRadius() throws {
        let atlas = try Self.atlas()
        #expect(WorldAtlas.townRadiusMetres(for: .town) == 2_000 && WorldAtlas.townRadiusMetres(for: .city) == 4_000)
        let metre = 1 / GeoPoint.metresPerDegree
        #expect(atlas.city(at: GeoPoint(15 + 1_500 * metre, 120))?.token == "ne:3")
        #expect(atlas.city(at: GeoPoint(15 + 2_500 * metre, 120)) == nil)
        #expect(atlas.city(at: GeoPoint(15 + 3_000 * metre, 130))?.token == "Q4")
        #expect(atlas.city(at: GeoPoint(15 + 4_500 * metre, 130)) == nil)
    }

    // MARK: The visit

    /// One visit carries every rule's answer.
    @Test func aVisitAppliesEveryRule() throws {
        let atlas = try Self.atlas()
        let beach = atlas.visit(at: GeoPoint(5, 10 - Self.degreesEast(500, at: 5)))
        #expect(beach == AtlasVisit(continent: .africa, ocean: .atlantic, terrain: .tropicalForest))
        let territory = atlas.visit(at: GeoPoint(-35, 55))
        #expect(territory.countryCode == "BB" && territory.sovereignCode == "CC" && territory.terrain == .water)
        #expect(atlas.visit(at: GeoPoint(.nan, 0)) == AtlasVisit(terrain: .water))
        #expect(atlas.visit(at: GeoPoint(10.6, 100.6)).city?.token == "Q1")
    }

    // MARK: Terrain and flora

    /// The Köppen-Geiger mapping, latitude rules included.
    @Test func terrainClassesFromClimate() {
        typealias Classifier = AtlasTerrainClassifier
        #expect(Classifier.terrain(climateCode: 30, latitude: -80) == .ice)
        #expect(Classifier.terrain(climateCode: 29, latitude: 70) == .tundra)
        #expect(Classifier.terrain(climateCode: 29, latitude: 46) == .mountain, "ET in the Alps")
        #expect(Classifier.terrain(climateCode: 1, latitude: 0) == .tropicalForest)
        #expect(Classifier.terrain(climateCode: 2, latitude: 5) == .tropicalForest)
        #expect(Classifier.terrain(climateCode: 3, latitude: -10) == .savanna)
        #expect(Classifier.terrain(climateCode: 4, latitude: 25) == .desert)
        #expect(Classifier.terrain(climateCode: 6, latitude: 15) == .savanna)
        #expect(Classifier.terrain(climateCode: 7, latitude: 45) == .grassland)
        #expect(Classifier.terrain(climateCode: 8, latitude: 38) == .shrubland)
        #expect(Classifier.terrain(climateCode: 15, latitude: 51) == .temperateForest)
        #expect(Classifier.terrain(climateCode: 16, latitude: 62) == .grassland)
        #expect(Classifier.terrain(climateCode: 26, latitude: 45) == .temperateForest)
        #expect(Classifier.terrain(climateCode: 27, latitude: 62) == .borealForest)
        #expect(Classifier.terrain(climateCode: 27, latitude: 35) == .mountain, "subarctic at 35° is altitude")
        #expect(Classifier.terrain(climateCode: 0, latitude: 10) == .grassland)
    }

    /// Terrain from the atlas: water off the land, a class on it, the same through a fog cell.
    @Test func terrainFromTheAtlas() throws {
        let classifier = AtlasTerrainClassifier(atlas: try Self.atlas())
        #expect(classifier.terrain(at: GeoPoint(5, 5)) == .tropicalForest)
        #expect(classifier.terrain(at: GeoPoint(25, 2)) == .desert)
        #expect(classifier.terrain(at: GeoPoint(25, 8)) == .water)
        #expect(classifier.terrain(of: MercatorHexGrid.cell(containing: GeoPoint(5, 5))) == .tropicalForest)
        #expect(classifier.flora(at: GeoPoint(5, 15)).isEmpty, "nothing grows at sea")
    }

    /// Cacti only in the Americas, succulents in the other dry lands, olives round the Mediterranean, at most
    /// three plants.
    @Test func floraRules() {
        typealias Classifier = AtlasTerrainClassifier
        let sonora = Classifier.flora(for: .desert, climateCode: 4, at: GeoPoint(31, -111))
        let sahara = Classifier.flora(for: .desert, climateCode: 4, at: GeoPoint(23, 10))
        #expect(sonora.contains(.cacti) && !sonora.contains(.succulents))
        #expect(sahara.contains(.succulents) && !sahara.contains(.cacti))
        #expect(Classifier.flora(for: .shrubland, climateCode: 8, at: GeoPoint(38, 23)).contains(.olives))
        #expect(!Classifier.flora(for: .shrubland, climateCode: 8, at: GeoPoint(-34, 18.5)).contains(.olives))
        #expect(Classifier.flora(for: .borealForest, climateCode: 27, at: GeoPoint(62, 30)) == [.conifers, .birches, .mossLichen])
        #expect(Classifier.flora(for: .ice, climateCode: 30, at: GeoPoint(-80, 0)) == [.ice])
        #expect(Classifier.flora(for: .tundra, climateCode: 29, at: GeoPoint(65, -18)).contains(.heather))
        #expect(Classifier.flora(for: .tropicalForest, climateCode: 1, at: GeoPoint(-3, -60)).contains(.jungle))
        #expect(AtlasTerrain.allCases.allSatisfy {
            Classifier.flora(for: $0, climateCode: 0, at: GeoPoint(10, 10)).count <= Classifier.maxFlora
        })
    }

    // MARK: Seasons

    /// April is spring in the north and autumn in the south; January winter and summer.
    @Test func seasonsFlipSouthOfTheEquator() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let april = try #require(calendar.date(from: DateComponents(year: 2026, month: 4, day: 15)))
        let january = try #require(calendar.date(from: DateComponents(year: 2026, month: 1, day: 15)))
        #expect(AtlasSeason.season(at: 51.5, on: april, calendar: calendar) == .spring)
        #expect(AtlasSeason.season(at: -33.9, on: april, calendar: calendar) == .autumn)
        #expect(AtlasSeason.season(at: 51.5, on: january, calendar: calendar) == .winter)
        #expect(AtlasSeason.season(at: -33.9, on: january, calendar: calendar) == .summer)
        #expect(AtlasSeason.season(at: 0, on: april, calendar: calendar) == .spring, "the equator counts as north")
    }

    /// The tropics have no four seasons; the tropics' edge and beyond do.
    @Test func theTropicsHaveNoFourSeasons() {
        #expect(!AtlasSeason.hasFourSeasons(latitude: 10))
        #expect(!AtlasSeason.hasFourSeasons(latitude: -23.4))
        #expect(AtlasSeason.hasFourSeasons(latitude: 23.44))
        #expect(AtlasSeason.hasFourSeasons(latitude: -45))
        #expect(!AtlasSeason.hasFourSeasons(latitude: .nan))
    }
}
