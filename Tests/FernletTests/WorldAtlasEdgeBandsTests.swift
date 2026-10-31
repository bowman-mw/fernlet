import Foundation
import Testing
import WorldMapStore

/// The banded point test and the one-degree candidate cells (`AtlasEdgeBands`, `AtlasBoxIndex`) answer exactly
/// what the whole walk did: ``WorldAtlas/country(at:)``, ``WorldAtlas/admin1(at:)``,
/// ``WorldAtlas/placeName(at:)`` and ``WorldAtlas/isUrban(_:)`` are compared with a reference that tests every
/// box and walks every edge of every ring, in table order, over points near borders, on vertex latitudes, at
/// the antimeridian, in holes and at random, on a hand-built many-point world and on the shipped pack.
@MainActor
struct WorldAtlasEdgeBandsTests {
    // MARK: The worlds

    /// A many-point world on the 18-row grid: a star country with a star hole, an overlapping country listed
    /// second (so "the first in table order" matters), a Fiji-like country of two rings either side of the
    /// antimeridian, two wiggly-edged states splitting the star, and a ring of urban boundaries.
    private static func manyPointWorld() throws -> WorldAtlas {
        var world = WorldAtlasTestPackBuilder(rows: 18)
        let star = Self.star(centre: (20, 10), outer: 15, inner: 8, points: 1_200)
        let hole = Self.star(centre: (20, 10), outer: 4, inner: 2, points: 300)
        world.countries = [
            .init(code: "SS", sovereign: "SS", feature: .init(bbox: Self.box(of: star), rings: [star, hole])),
            .init(code: "OO", sovereign: "OO", feature: .init(bbox: (25, 0, 45, 20), rings: [Self.circle((35, 10), 9, 400)])),
            .init(code: "FF", sovereign: "FF", feature: .init(bbox: (-180, -25, 180, -10), rings: [
                [(176, -20), (180, -21), (180, -15), (177, -12), (178, -17)],
                [(-180, -21), (-176, -19), (-178, -16), (-180, -15)],
            ])),
        ]
        let west = star.filter { $0.0 <= 20 } + [(20, -5), (19.7, 5), (20.3, 15), (20, 25)]
        let east = star.filter { $0.0 >= 20 } + [(20, -5), (19.7, 5), (20.3, 15), (20, 25)]
        world.admin1s = [
            .init(token: "SS-W", country: "SS", name: "West", feature: .init(bbox: Self.box(of: west), rings: [west])),
            .init(token: "SS-E", country: "SS", name: "East", feature: .init(bbox: Self.box(of: east), rings: [east])),
            .init(token: "OO-1", country: "OO", name: "Whole", feature: .init(bbox: (25, 0, 45, 20), rings: [Self.circle((35, 10), 9.5, 90)])),
        ]
        world.urban = (0..<12).map { slot in
            let angle = Double(slot) * .pi / 6, ring = Self.circle((20 + 9 * cos(angle), 10 + 9 * sin(angle)), 1.5, 60)
            return .init(bbox: Self.box(of: ring), rings: [ring])
        }
        return try WorldAtlas(data: try world.build())
    }

    /// The bundled pack.
    private static func shippedAtlas() throws -> WorldAtlas {
        let url = try #require(Bundle.main.url(forResource: "WorldAtlas", withExtension: "pack"))
        return try WorldAtlas(data: try Data(contentsOf: url))
    }

    // MARK: The comparisons

    /// On the many-point world, every lookup matches the whole walk over a fine grid, every vertex latitude
    /// and the antimeridian.
    @Test func theManyPointWorldMatchesTheWholeWalk() throws {
        let atlas = try Self.manyPointWorld()
        let reference = ReferenceAtlas(atlas)
        var points: [GeoPoint] = []
        for row in 0..<150 { for col in 0..<80 { points.append(GeoPoint(-30 + Double(row) * 0.37, -2 + Double(col) * 0.65)) } }
        for row in 0..<80 {
            for lon in [180.0, -180, 179.999_99, -179.999_99, 179.2, -179.2] { points.append(GeoPoint(-25 + Double(row) * 0.2, lon)) }
        }
        points += Self.borderPoints(atlas.countries.map(\.polygon) + atlas.admin1s.map(\.polygon), stride: 7)
        #expect(points.count > 12_000)
        Self.compare(atlas, reference, at: points)
        #expect(atlas.country(at: GeoPoint(10, 20))?.code == nil, "the star's hole")
        #expect(atlas.country(at: GeoPoint(10, 30))?.code == "SS", "the star is first where it and OO overlap")
        #expect(atlas.country(at: GeoPoint(-16, 179.5))?.code == "FF" && atlas.country(at: GeoPoint(-17, -178))?.code == "FF")
    }

    /// On the shipped pack, every lookup matches the whole walk near the borders of the countries whose boxes
    /// span the globe or ring a hole, at the antimeridian, and at random.
    @Test func theShippedPackMatchesTheWholeWalk() throws {
        let atlas = try Self.shippedAtlas()
        let reference = ReferenceAtlas(atlas)
        let picked = ["US", "RU", "FJ", "KI", "NZ", "UM", "CA", "ZA", "LS", "IT", "VA", "SM", "FR", "ES", "AD", "CH",
                      "LI", "AT", "IN", "BD", "CN", "NL", "BE", "GB", "IE", "NO"]
        let outlines = picked.compactMap { atlas.country(code: $0)?.polygon }
            + atlas.admin1s(ofCountry: "US").prefix(6).map(\.polygon) + atlas.admin1s(ofCountry: "GB").prefix(6).map(\.polygon)
        var points = Self.borderPoints(outlines, stride: 3_001)
        for row in 0..<70 {
            for lon in [180.0, -180, 179.999, -179.999, 172.5, -172.5] { points.append(GeoPoint(-60 + Double(row) * 1.9, lon)) }
        }
        var seed: UInt64 = 2026_10_31
        for _ in 0..<500 { points.append(GeoPoint(Self.random(&seed) * 150 - 60, Self.random(&seed) * 360 - 180)) }
        points += [GeoPoint(-29.6, 28.2), GeoPoint(41.9029, 12.4534), GeoPoint(43.94, 12.46), GeoPoint(51.44, 4.93)]
        #expect(points.count > 1_000)
        Self.compare(atlas, reference, at: points)
        #expect(atlas.country(at: GeoPoint(-29.6, 28.2))?.code == "LS", "Lesotho, South Africa's hole")
        #expect(atlas.country(at: GeoPoint(41.9029, 12.4534))?.code == "VA")
    }

    // MARK: Helpers

    /// Expects every lookup at every point to match the reference.
    private static func compare(_ atlas: WorldAtlas, _ reference: ReferenceAtlas, at points: [GeoPoint]) {
        var mismatches: [String] = []
        for point in points where mismatches.count < 10 {
            let country = reference.country(at: point)
            let admin1 = reference.admin1(at: point, inCountry: country)
            let place = admin1.map { AtlasPlaceName(group: $0.group) } ?? country.map { AtlasPlaceName(countryCode: $0) }
            if atlas.country(at: point)?.code != country { mismatches.append("country \(point)") }
            if atlas.admin1(at: point)?.token != admin1?.token { mismatches.append("admin1 \(point)") }
            if atlas.placeName(at: point) != place { mismatches.append("place \(point)") }
            if atlas.isUrban(point) != reference.isUrban(point) { mismatches.append("urban \(point)") }
        }
        #expect(mismatches.isEmpty, "\(mismatches)")
    }

    /// Points on and just beside every `stride`-th vertex of `outlines`: the vertex itself (its latitude is an
    /// edge's end, where a band's half-open rule bites) and nudges of 1e-5°, 0.001° and 0.05° each way.
    private static func borderPoints(_ outlines: [AtlasPolygon], stride: Int) -> [GeoPoint] {
        var points: [GeoPoint] = []
        var seen = 0
        for polygon in outlines {
            for ring in 0..<polygon.ringCount {
                for vertex in polygon.ring(ring) {
                    seen += 1
                    guard seen % stride == 0 else { continue }
                    points.append(vertex)
                    for nudge in [0.000_01, 0.001, 0.05] {
                        points.append(GeoPoint(vertex.latitude, min(vertex.longitude + nudge, 180)))
                        points.append(GeoPoint(vertex.latitude - nudge, max(vertex.longitude - nudge, -180)))
                    }
                }
            }
        }
        return points
    }

    /// A star of `points` points about `centre` (lon, lat), alternating radii `outer` and `inner` degrees.
    private static func star(centre: (Double, Double), outer: Double, inner: Double, points: Int) -> [(Double, Double)] {
        (0..<points).map { slot in
            let angle = Double(slot) / Double(points) * 2 * .pi, radius = slot % 2 == 0 ? outer : inner
            return (centre.0 + radius * cos(angle), centre.1 + radius * sin(angle))
        }
    }

    /// A circle of `points` points about `centre` (lon, lat).
    private static func circle(_ centre: (Double, Double), _ radius: Double, _ points: Int) -> [(Double, Double)] {
        star(centre: centre, outer: radius, inner: radius, points: points)
    }

    /// The box (minLon, minLat, maxLon, maxLat) of `ring`.
    private static func box(of ring: [(Double, Double)]) -> (Double, Double, Double, Double) {
        (ring.map(\.0).min() ?? 0, ring.map(\.1).min() ?? 0, ring.map(\.0).max() ?? 0, ring.map(\.1).max() ?? 0)
    }

    /// A seeded uniform value in 0..<1.
    private static func random(_ seed: inout UInt64) -> Double {
        seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(seed >> 11) / Double(UInt64(1) << 53)
    }
}

/// The lookups as they were before the edge bands and candidate cells: every polygon in table order, its box,
/// then the even-odd rule over every edge of every ring of three points or more, in the pack's units.
private struct ReferenceAtlas {
    /// One polygon's rings in 1e-5 degrees (the decoder's integers, recovered from ``AtlasPolygon/ring(_:)``).
    struct Outline {
        let polygon: AtlasPolygon
        let rings: [[(x: Double, y: Double)]]
    }

    let atlas: WorldAtlas
    let countries: [Outline]
    let admin1s: [Outline]
    let urban: [Outline]

    init(_ atlas: WorldAtlas) {
        self.atlas = atlas
        countries = atlas.countries.map { Self.outline($0.polygon) }
        admin1s = atlas.admin1s.map { Self.outline($0.polygon) }
        urban = atlas.urbanAreas.map(Self.outline)
    }

    /// The country code, as `countries.first { $0.polygon.contains(point) }` found it.
    func country(at point: GeoPoint) -> String? {
        guard point.isValid else { return nil }
        return zip(atlas.countries, countries).first { Self.contains($0.1, point) }?.0.code
    }

    /// The state among the country's own entries, or among every entry when the country is unknown.
    func admin1(at point: GeoPoint, inCountry code: String?) -> AtlasAdmin1? {
        guard point.isValid else { return nil }
        return zip(atlas.admin1s, admin1s).first { entry, outline in
            (code == nil || entry.countryCode == code) && Self.contains(outline, point)
        }?.0
    }

    /// Whether any urban boundary holds `point`.
    func isUrban(_ point: GeoPoint) -> Bool {
        point.isValid && urban.contains { Self.contains($0, point) }
    }

    /// The whole walk.
    static func contains(_ outline: Outline, _ point: GeoPoint) -> Bool {
        guard point.isValid, outline.polygon.boxContains(point) else { return false }
        let x = point.longitude * AtlasPolygon.unitsPerDegree, y = point.latitude * AtlasPolygon.unitsPerDegree
        var inside = false
        for ring in outline.rings where ring.count >= 3 {
            var previous = ring[ring.count - 1]
            for current in ring {
                if (current.y > y) != (previous.y > y),
                   x < (previous.x - current.x) * (y - current.y) / (previous.y - current.y) + current.x {
                    inside.toggle()
                }
                previous = current
            }
        }
        return inside
    }

    /// `polygon`'s rings back in the pack's integer units.
    static func outline(_ polygon: AtlasPolygon) -> Outline {
        let rings = (0..<polygon.ringCount).map { index in
            polygon.ring(index).map { point in
                (x: (point.longitude * AtlasPolygon.unitsPerDegree).rounded(),
                 y: (point.latitude * AtlasPolygon.unitsPerDegree).rounded())
            }
        }
        return Outline(polygon: polygon, rings: rings)
    }
}
