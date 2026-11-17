import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The bundled rail pack (Docs/World-Rail-Pack.md; ferry and train paths, owner's T1 A and F3): the shipped file is the
/// one `WorldRail.expectedSHA256` pins, its rail lines and ferry routes answer near-queries where Natural Earth draws
/// them and not in open ocean, a damaged file decodes to nil, and a query stays cheap. The places named are public
/// landmarks (stations, ferry routes), none from the owner.
@MainActor
struct WorldRailPackTests {
    /// The shipped pack, opened once for the suite.
    static let rail: WorldRail? = {
        guard let url = Bundle.main.url(forResource: "WorldRail", withExtension: "pack"),
              let data = try? Data(contentsOf: url) else { return nil }
        return WorldRail.decode(data)
    }()

    private func shippedData() throws -> Data {
        let url = try #require(Bundle.main.url(forResource: "WorldRail", withExtension: "pack"))
        return try Data(contentsOf: url)
    }

    /// The shipped pack is the pinned one, under its cap, and decodes with both layers.
    @Test func theShippedPackIsThePinnedOne() throws {
        let data = try shippedData()
        #expect(data.count <= WorldRail.maxPackBytes)
        #expect(WorldAtlasPack.sha256Hex(data) == WorldRail.expectedSHA256)
        let rail = try WorldRail(data: data)
        #expect(rail.railPointCount > 400_000 && rail.railPointCount < 500_000)
        #expect(rail.ferryPointCount > 4_000 && rail.ferryPointCount < 7_000)
    }

    /// Natural Earth's main lines: the line through Northeast Portland (a point 200 m off a vertex of it in the
    /// source), the line by Seattle's King Street Station within 2 km, and Paris's Gare de Lyon approach. Natural
    /// Earth is coarse at 1:10 million: Portland Union Station itself is about 3 km from its nearest line, so it is
    /// near rail at 5 km and not at 1 km.
    @Test func mainLinesAreNearRail() throws {
        let rail = try #require(Self.rail)
        #expect(rail.isNearRail(GeoPoint(45.54478, -122.64), within: 1_000))
        #expect(rail.isNearRail(GeoPoint(45.5289, -122.6767), within: 5_000))
        #expect(!rail.isNearRail(GeoPoint(45.5289, -122.6767), within: 1_000))
        #expect(rail.isNearRail(GeoPoint(47.5983, -122.3297), within: 2_000))
        #expect(rail.isNearRail(GeoPoint(48.85194, 2.35195), within: 500))
    }

    /// Open ocean is near no rail and no ferry route.
    @Test func openOceanIsNearNothing() throws {
        let rail = try #require(Self.rail)
        for point in [GeoPoint(0, -140), GeoPoint(-40, -20), GeoPoint(10, 70)] {
            #expect(!rail.isNearRail(point, within: 5_000))
            #expect(!rail.isNearFerryRoute(point, within: 5_000))
        }
    }

    /// Known ferry routes: Tsawwassen–Swartz Bay (BC Ferries, across Haro Strait's islands) and Dover–Calais. A rail
    /// line is not a ferry route, and a ferry route is not rail.
    @Test func knownFerryRoutesAreNearAFerry() throws {
        let rail = try #require(Self.rail)
        #expect(rail.isNearFerryRoute(GeoPoint(48.8596, -123.3252), within: 500))
        #expect(rail.isNearFerryRoute(GeoPoint(51.05, 1.58), within: 1_000))
        #expect(!rail.isNearRail(GeoPoint(51.05, 1.58), within: 1_000))
        #expect(!rail.isNearFerryRoute(GeoPoint(45.54478, -122.64), within: 1_000))
    }

    /// Bad input answers false, never traps: an invalid point, a distance that isn't positive or finite.
    @Test func badQueriesAnswerFalse() throws {
        let rail = try #require(Self.rail)
        #expect(!rail.isNearRail(GeoPoint(95, 0), within: 1_000))
        #expect(!rail.isNearRail(GeoPoint(45.54478, -122.64), within: 0))
        #expect(!rail.isNearRail(GeoPoint(45.54478, -122.64), within: -.infinity))
        #expect(!rail.isNearRail(GeoPoint(45.54478, -122.64), within: .nan))
        #expect(rail.isNearRail(GeoPoint(45.54478, -122.64), within: .infinity))
        #expect(!rail.isNearRail(GeoPoint(89.9, 179.9), within: 20_000))
    }

    /// A damaged pack decodes to nil: cut short, a wrong magic, a flipped byte inside a section, and too large.
    @Test func aDamagedPackDecodesToNil() throws {
        let data = try shippedData()
        #expect(WorldRail.decode(data.prefix(4_000)) == nil)
        var magic = data
        magic[0] = 0x58
        #expect(WorldRail.decode(magic) == nil)
        var flipped = data
        flipped[200] ^= 0xFF
        #expect(WorldRail.decode(flipped) == nil)
        #expect(WorldRail.decode(Data(count: WorldRail.maxPackBytes + 1)) == nil)
        #expect(WorldRail.decode(Data()) == nil)
    }

    /// A query stays well under a millisecond: 2,000 near-queries at 1 km over the densest cells (Bohemia and Saxony,
    /// about 1,600 points a cell), mostly misses that read every listed segment.
    @Test func aQueryStaysCheap() throws {
        let rail = try #require(Self.rail)
        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for step in 0..<2_000 {
                let point = GeoPoint(50.0 + Double(step % 40) * 0.05, 12.0 + Double(step / 40) * 0.08)
                if rail.isNearRail(point, within: 1_000) { hits += 1 }
            }
        }
        #expect(hits > 0 && hits < 2_000)
        #expect(elapsed / 2_000 < .milliseconds(1), "\(elapsed / 2_000) per query")
    }

    /// The atlas's major-road query finds Interstate 5 by Portland's Marquam Bridge and nothing mid-Pacific, and the
    /// app's geography joins the packs (the atlas's land where there is no shore mask).
    @Test func theGeographyJoinsThePacks() throws {
        let rail = try #require(Self.rail)
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        let atlas = try WorldAtlas(data: Data(contentsOf: url))
        #expect(atlas.isNearMajorRoad(GeoPoint(45.5098, -122.6693), within: 500))
        #expect(!atlas.isNearMajorRoad(GeoPoint(0, -140), within: 5_000))
        #expect(!atlas.isNearMajorRoad(GeoPoint(45.5098, -122.6693), within: 0))
        let geography = WorldTransitGeography(atlas: atlas, shore: nil, rail: rail)
        #expect(geography.isWater(GeoPoint(0, -140)))
        #expect(!geography.isWater(GeoPoint(45.5289, -122.6767)))
        #expect(geography.isNearRail(GeoPoint(45.54478, -122.64), within: 1_000))
        #expect(geography.isNearFerryRoute(GeoPoint(51.05, 1.58), within: 1_000))
        #expect(geography.isNearMajorRoad(GeoPoint(45.5098, -122.6693), within: 500))
    }
}
