import CoreGraphics
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Your world's flight arcs (World-Airports-Spec §8, screen 22): a route flown both ways is one arc, "imported"
/// only when no flight on it was Fernlet's own, the great circle and its length, the cut where an arc wraps
/// round the world, the arc under a tap, the card's grouped distance, and the rings for airports only flown
/// through. Made-up flights between example airports only (never anyone's real flights).
struct WorldFlightArcsTests {
    private static let portland = GeoPoint(45.589, -122.597)
    private static let mexicoCity = GeoPoint(19.436, -99.072)
    private static let tokyo = GeoPoint(35.552, 139.780)
    private static let honolulu = GeoPoint(21.319, -157.922)
    private static let day = Date(timeIntervalSince1970: 1_700_000_000)

    private static func flight(_ from: String, _ to: String, days: Double, _ sources: PassportFlight.Sources) throws -> PassportFlight {
        try #require(PassportFlight(from: from, to: to, departure: day.addingTimeInterval(days * 86_400), sources: sources))
    }

    private static let airports: [String: WorldFlightMap.Airport] = [
        "PDX": .init(point: portland, name: "Portland"), "MEX": .init(point: mexicoCity, name: "Mexico City"),
        "HND": .init(point: tokyo, name: "Tokyo"), "HNL": .init(point: honolulu, name: "HNL")
    ]

    // MARK: Routes

    /// PDX→MEX and MEX→PDX are one route, read the way it was first flown; it is imported only when every
    /// flight on it was.
    @Test func aRouteFlownBothWaysIsOneArc() throws {
        let flights = [try Self.flight("PDX", "MEX", days: 0, .flighty), try Self.flight("MEX", "PDX", days: 5, .fernlet),
                       try Self.flight("PDX", "HNL", days: 9, .calendar)]
        let routes = WorldFlightArcs.routes(flights)
        #expect(routes.count == 2)
        #expect(routes[0].route == WorldFlightRoute("MEX", "PDX"))
        #expect(routes[0].tally == WorldFlightArcs.Tally(from: "PDX", to: "MEX", flights: 2, allImported: false))
        #expect(routes[1].tally.allImported)
        #expect(WorldFlightRoute("PDX", "MEX").id == "MEX-PDX")
    }

    /// The map draws an arc only between airports it can place, the most-flown first; an end that isn't a found
    /// airport gets a ring, once; the plate counts every flight.
    @Test func theMapRingsOnlyAirportsFlownThrough() throws {
        var book = PassportBook()
        book.addFlights([try Self.flight("PDX", "HNL", days: 0, .flighty), try Self.flight("PDX", "MEX", days: 1, .fernlet),
                         try Self.flight("MEX", "PDX", days: 4, .fernlet), try Self.flight("PDX", "XYZ", days: 6, .flighty)])
        let found = [(code: "PDX", airport: try #require(Self.airports["PDX"]))]
        let map = WorldFlightMap.make(book: book, found: found) { Self.airports[$0] }
        #expect(map.arcs.map(\.id) == ["MEX-PDX", "HNL-PDX"])
        #expect(map.arcs[0].fromName == "Portland" && map.arcs[0].toName == "Mexico City")
        #expect(map.rings.map(\.code) == ["HNL", "MEX"])
        #expect(map.found.map(\.code) == ["PDX"])
        #expect(map.flightCount == 4)
    }

    /// A decoy's book is empty, so its map draws nothing.
    @Test func anEmptyBookDrawsNothing() {
        let map = WorldFlightMap.make(book: PassportBook(), found: []) { Self.airports[$0] }
        #expect(map.arcs.isEmpty && map.rings.isEmpty && map.flightCount == 0)
    }

    // MARK: The sphere

    /// The great circle runs end to end in pointsPerArc points; a quarter of the equator is a quarter of the
    /// Earth's circumference, and its middle stays on the equator.
    @Test func greatCircleAlongTheEquator() throws {
        let a = GeoPoint(0, 0), b = GeoPoint(0, 90)
        let points = WorldFlightArcs.greatCircle(from: a, to: b)
        #expect(points.count == WorldFlightArcs.pointsPerArc)
        let first = try #require(points.first), last = try #require(points.last)
        #expect(abs(first.longitude) < 1e-9 && abs(last.longitude - 90) < 1e-9)
        #expect(points.allSatisfy { abs($0.latitude) < 1e-9 })
        #expect(abs(WorldFlightArcs.kilometres(a, b) - .pi / 2 * WorldFlightArcs.earthRadiusKilometres) < 1e-6)
        #expect(WorldFlightArcs.greatCircle(from: a, to: a).count == 2)
    }

    /// Portland to Mexico City is about 3,620 km, bowing north of the straight line between them.
    @Test func portlandToMexicoCity() {
        let km = WorldFlightArcs.kilometres(Self.portland, Self.mexicoCity)
        #expect(km > 3_580 && km < 3_660)
        #expect(WorldFlightCopy.distance(km).hasSuffix("km"))
        let middle = WorldFlightArcs.greatCircle(from: Self.portland, to: Self.mexicoCity)[WorldFlightArcs.pointsPerArc / 2]
        #expect(middle.latitude > (Self.portland.latitude + Self.mexicoCity.latitude) / 2)
    }

    // MARK: On screen

    /// Seen from Greenwich, an arc over the Pacific crosses the seam opposite the centre and is cut in two;
    /// seen from the Pacific it is whole.
    @Test func anArcIsCutWhereItWrapsRoundTheWorld() {
        let path = WorldFlightArcs.mercatorPath(from: Self.tokyo, to: Self.honolulu)
        let size = CGSize(width: 402, height: 874)
        let pieces = { (centre: GeoPoint) -> Int in
            let camera = WorldViewCamera(level: .world, centre: centre, size: size)
            let points = path.map { camera.screenPoint(x: Double($0.x), y: Double($0.y)) }
            return WorldFlightArcs.pieces(points, worldWidth: camera.scale).count
        }
        #expect(pieces(GeoPoint(20, 0)) == 2)
        #expect(pieces(GeoPoint(25, -170)) == 1)
    }

    /// A jump of more than half the world starts a new piece; a lone point is dropped.
    @Test func piecesSplitOnlyOnAJump() {
        let points = [CGPoint(x: 0, y: 0), CGPoint(x: 10, y: 0), CGPoint(x: 900, y: 0), CGPoint(x: 910, y: 0),
                      CGPoint(x: 0, y: 5)]
        let pieces = WorldFlightArcs.pieces(points, worldWidth: 1_000)
        #expect(pieces.map(\.count) == [2, 2])
        #expect(WorldFlightArcs.pieces(points, worldWidth: 0).isEmpty)
    }

    /// A tap picks the nearest arc within reach, and nothing farther.
    @Test func aTapPicksTheNearestArc() {
        let drawn: [(id: String, pieces: [[CGPoint]])] = [
            ("A", [[CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0)]]), ("B", [[CGPoint(x: 0, y: 10), CGPoint(x: 100, y: 10)]])
        ]
        #expect(WorldFlightArcs.arc(at: CGPoint(x: 50, y: 3), among: drawn, reach: 16) == "A")
        #expect(WorldFlightArcs.arc(at: CGPoint(x: 50, y: 8), among: drawn, reach: 16) == "B")
        #expect(WorldFlightArcs.arc(at: CGPoint(x: 50, y: 60), among: drawn, reach: 16) == nil)
        let past = WorldFlightArcs.distance(from: CGPoint(x: 130, y: 40), toSegment: CGPoint(x: 0, y: 0), CGPoint(x: 100, y: 0))
        #expect(abs(past - 50) < 1e-9)
    }

    // MARK: Words

    /// Distances round to 10 km and group by thousands, "," in English and "." in Spanish (even at four digits).
    @Test func distancesRoundAndGroup() {
        #expect(WorldFlightArcs.groupedKilometres(3_617.4, spanish: false) == "3,620")
        #expect(WorldFlightArcs.groupedKilometres(3_617.4, spanish: true) == "3.620")
        #expect(WorldFlightArcs.groupedKilometres(162_398, spanish: false) == "162,400")
        #expect(WorldFlightArcs.groupedKilometres(1_234_567, spanish: true) == "1.234.570")
        #expect(WorldFlightArcs.groupedKilometres(878, spanish: false) == "880")
        #expect(WorldFlightArcs.groupedKilometres(-5, spanish: false) == "0")
    }
}
