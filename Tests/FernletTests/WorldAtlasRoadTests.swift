import CoreGraphics
import Foundation
import Testing
import WorldMapStore

/// The pack's `ROAD` major roads (Docs/World-Atlas-Pack.md; owner 2026-10-30 "Sure" to the road source): what the
/// reader accepts and refuses, and the crossing rule ("a road counts as discovered when the route has crossed
/// it"), on small packs written by ``WorldAtlasTestPackBuilder`` and on the shipped pack.
@MainActor
struct WorldAtlasRoadTests {
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

    /// ROAD parses: tokens from the numbers, kinds, lines and boxes, in number order.
    @Test func theRoadTableParses() throws {
        let atlas = try standardAtlas()
        #expect(atlas.roads.map(\.token) == ["ne:road:4", "ne:road:9"])
        let highway = try #require(atlas.road(token: "ne:road:4"))
        #expect(highway.kind == .highway && highway.lineCount == 1)
        let line = highway.line(0)
        #expect(line.count == 2 && abs(line[1].latitude - 10.3) < 1e-9 && abs(line[1].longitude - 100.2) < 1e-9)
        let main = try #require(atlas.road(token: "ne:road:9"))
        #expect(main.kind == .mainRoad && main.lineCount == 2 && main.line(2).isEmpty)
        #expect(main.minLon == 10_000_000 && main.maxLon == 10_060_000 && main.maxLat == 1_030_000)
        #expect(atlas.road(token: "ne:road:5") == nil)
        #expect(AtlasRoad.isValidToken("ne:road:4") && !AtlasRoad.isValidToken("ne:road:") && !AtlasRoad.isValidToken("road:4"))
    }

    /// A route segment that crosses a road finds it, once; one beside it, along no road, or touching only
    /// at its end decides by whether it meets the line; a long gap or a bad point finds nothing.
    @Test func aRouteThatCrossesARoadFindsIt() throws {
        let atlas = try standardAtlas()
        let across = atlas.roadsCrossed(from: GeoPoint(10.1, 100.19), to: GeoPoint(10.1, 100.21))
        #expect(across.map(\.token) == ["ne:road:4"], "east across the highway")
        #expect(atlas.roadsCrossed(from: GeoPoint(10.1, 100.21), to: GeoPoint(10.1, 100.19)).map(\.token) == ["ne:road:4"],
                "the way back too")
        #expect(atlas.roadsCrossed(from: GeoPoint(10.1, 100.22), to: GeoPoint(10.1, 100.24)).isEmpty, "beside it")
        #expect(atlas.roadsCrossed(from: GeoPoint(10.05, 100.15), to: GeoPoint(10.15, 100.15)).isEmpty, "parallel to it")
        #expect(atlas.roadsCrossed(from: GeoPoint(10.24, 100.19), to: GeoPoint(10.26, 100.21)).map(\.token)
                == ["ne:road:4", "ne:road:9"], "through the junction: both, each once")
        #expect(atlas.roadsCrossed(from: GeoPoint(10.1, 100.18), to: GeoPoint(10.1, 100.2)).map(\.token) == ["ne:road:4"],
                "a fix on the line counts")
        #expect(atlas.roadsCrossed(from: GeoPoint(10.27, 100.53), to: GeoPoint(10.29, 100.53)).map(\.token) == ["ne:road:9"],
                "the road's second line")
        #expect(atlas.roadsCrossed(from: GeoPoint(10.1, 100.15), to: GeoPoint(10.1, 100.25)).isEmpty,
                "11 km between fixes is a gap, not a crossing")
        #expect(WorldAtlas.maxCrossingSegmentMetres == 5_000)
        #expect(atlas.roadsCrossed(from: GeoPoint(.nan, 100.19), to: GeoPoint(10.1, 100.21)).isEmpty)
        let size = CGSize(width: 400, height: 800)
        let overMetro = MapViewport.around(GeoPoint(10.1, 100.2), heightMetres: 20_000, size: size)
        #expect(atlas.roads(overlapping: overMetro).map(\.token) == ["ne:road:4"], "the screen draws what it shows")
        let overBoth = MapViewport.around(GeoPoint(10.25, 100.3), heightMetres: 100_000, size: size)
        #expect(atlas.roads(overlapping: overBoth).map(\.token) == ["ne:road:4", "ne:road:9"])
    }

    /// ROAD is required, and a bad kind, a number out of order, a road with no line, a one-point line, a point
    /// off the globe, a count the bytes can't hold and trailing bytes are refused, each naming its field.
    @Test func badRoadsAreRefused() throws {
        let missing = WorldAtlasTestPackBuilder.standardWorld().rawSections().filter { $0.tag != "ROAD" }
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(missing)) == .missingSection("ROAD"))
        let cases: [(String, (inout WorldAtlasTestPackBuilder) -> Void, WorldAtlasPackError)] = [
            ("unknown kind", { $0.roads[0].kind = 3 }, .malformed("ROAD", "kind")),
            ("numbers out of order", { $0.roads[1].number = 2 }, .malformed("ROAD", "number")),
            ("repeated number", { $0.roads[1].number = 4 }, .malformed("ROAD", "number")),
            ("no line", { $0.roads[0].lines = [] }, .malformed("ROAD", "lineCount")),
            ("one-point line", { $0.roads[0].lines = [[(100.2, 10.0)]] }, .malformed("ROAD", "pointCount")),
            ("point off the globe", { $0.roads[0].lines = [[(100.2, 10.0), (100.2, 95)]] }, .malformed("ROAD", "point")),
        ]
        for (label, change, expected) in cases {
            var world = WorldAtlasTestPackBuilder.standardWorld()
            change(&world)
            #expect(refusal(try world.build()) == expected, "\(label)")
        }
        var sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        let road = try #require(sections.firstIndex { $0.tag == "ROAD" })
        sections[road].raw = Data([0xFF, 0xFF, 0xFF, 0xFF])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ROAD", "count"))
        sections[road].raw = Data([1, 0, 0, 0, 4, 0, 0, 0, 1, 1, 0, 0xFF, 0xFF])
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ROAD", "pointCount"))
        sections = WorldAtlasTestPackBuilder.standardWorld().rawSections()
        sections[road].raw.append(0)
        #expect(refusal(try WorldAtlasTestPackBuilder.assemble(sections)) == .malformed("ROAD", "trailingBytes"))
        sections[road].raw = Data([0, 0, 0, 0])
        #expect(try WorldAtlas(data: WorldAtlasTestPackBuilder.assemble(sections)).roads.isEmpty, "no roads opens")
    }
}
