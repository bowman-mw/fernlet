import Foundation
import Testing
import WorldMapStore

/// Lakes are water (owner, 2026-10-30: "water in the fog only where real water is"): Natural Earth's lakes are cut
/// out of `LAND`, so the terrain reads water there, but they keep `OCEA` 0 (no passport ocean or sea) and their
/// continent; an island in a lake stays land.
@MainActor
struct WorldAtlasLakeTests {
    /// Water no ocean or sea names keeps the continent its `CONT` cell holds (a lake); water an ocean names does not.
    @Test func aLakeKeepsItsContinentAndTheSeaDoesNot() throws {
        var world = WorldAtlasTestPackBuilder.standardWorld()
        world.set(lat: 5, lon: -5, state: 0, continent: 1)
        world.set(lat: 5, lon: 15, state: 0, ocean: 2, continent: 1)
        let atlas = try WorldAtlas(data: try world.build())
        #expect(atlas.continent(at: GeoPoint(5, -5)) == .africa, "a lake: water with no ocean, its continent kept")
        #expect(atlas.continent(at: GeoPoint(5, 15)) == nil, "the Atlantic: no continent")
        #expect(atlas.visit(at: GeoPoint(5, -5)).ocean == nil && atlas.visit(at: GeoPoint(5, -5)).sea == nil)
    }

    /// The shipped pack: Lake Geneva, Lake Superior and Titicaca are water with their continent and country and no
    /// ocean or sea; Isle Royale and Manitoulin stay land; the Caspian still counts no continent; Portland is land.
    @Test func theShippedPackKnowsLakes() throws {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        let atlas = try WorldAtlas(data: Data(contentsOf: url))
        let lakes: [(String, GeoPoint, AtlasContinent)] = [
            ("Lake Geneva", GeoPoint(46.45, 6.55), .europe), ("Lake Superior", GeoPoint(47.7, -87.5), .northAmerica),
            ("Lake Titicaca", GeoPoint(-15.8, -69.4), .southAmerica), ("Lake Victoria", GeoPoint(-1.0, 33.0), .africa),
        ]
        for (name, point, continent) in lakes {
            let visit = atlas.visit(at: point)
            #expect(visit.terrain == .water && atlas.isWater(at: point), "\(name) is water")
            #expect(visit.continent == continent && visit.countryCode != nil, "\(name) keeps its continent and country")
            #expect(visit.ocean == nil && visit.sea == nil, "\(name) is no ocean or sea")
        }
        #expect(!atlas.isWater(at: GeoPoint(48.0, -88.9)), "Isle Royale, in Lake Superior, is land")
        #expect(!atlas.isWater(at: GeoPoint(45.8, -82.0)), "Manitoulin, in Lake Huron, is land")
        #expect(atlas.visit(at: GeoPoint(42.0, 50.0)).continent == nil, "the Caspian counts no continent")
        #expect(atlas.visit(at: GeoPoint(45.5205, -122.6255)).terrain == .temperateForest, "Portland is land")
    }
}
