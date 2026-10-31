import CoreGraphics
import FernletDomainModel
import Foundation
import WorldMapStore

/// A route as one unordered pair of IATA codes (World-Airports-Spec §8, "A route flown both ways is one arc"):
/// PDX→MEX and MEX→PDX are the same route. The codes are frozen tokens, never shown translated.
nonisolated struct WorldFlightRoute: Hashable, Sendable {
    /// The code that sorts first.
    let first: String
    /// The code that sorts second.
    let second: String

    /// The route between `a` and `b`, in either order.
    init(_ a: String, _ b: String) {
        if a <= b {
            first = a
            second = b
        } else {
            first = b
            second = a
        }
    }

    /// A stable ID, "MEX-PDX" (also the arc's accessibility identifier suffix).
    var id: String { first + "-" + second }
}

/// One dotted arc on Your world (spec §8, screen 22): a route, the way it was first flown, how many flights
/// it carries and whether all of them were imported, its great-circle length, and its points in Web Mercator
/// units (each `x` in `0..<1`, so the camera draws every point at its copy nearest the view's centre).
nonisolated struct WorldFlightArc: Identifiable, Sendable {
    /// The unordered route.
    let route: WorldFlightRoute
    /// The departure code of the route's earliest flight (the card reads from here).
    let from: String
    /// The arrival code of the route's earliest flight.
    let to: String
    /// The city (or, for an airport with no name in the pack, the code) at `from`, in the app's language.
    let fromName: String
    /// The city (or code) at `to`.
    let toName: String
    /// Flights on the route, both ways.
    let flights: Int
    /// Whether every flight on it was imported (none seen by Fernlet itself).
    let allImported: Bool
    /// The great-circle length, in kilometres.
    let kilometres: Double
    /// The great circle's points in Mercator units, `from` to `to` (at most ``WorldFlightArcs/pointsPerArc``).
    let path: [CGPoint]

    var id: String { route.id }

    /// The arc's middle point in Mercator units (where its VoiceOver button sits).
    var middle: CGPoint { path.isEmpty ? .zero : path[path.count / 2] }
}

/// An airport mark on Your world: a found airport (stamped, drawn as a labelled dot) or one only flown through
/// (an arc's end that was never found, drawn as a 9-pt ring, spec §8).
nonisolated struct WorldFlightAirportMark: Identifiable, Sendable {
    /// The IATA code (or the pack's ident), shown as it is.
    let code: String
    /// The city's name in the app's language, or the code when the pack has none.
    let name: String
    /// Where it is, in Mercator units (`x` in `0..<1`).
    let mercator: CGPoint

    var id: String { code }
}

/// Everything Your world draws for flights: the arcs, the rings for airports only flown through, the found
/// airports' dots, and the plate's counts. Empty in a decoy (its book has no flights and no airports).
nonisolated struct WorldFlightMap: Sendable {
    /// The arcs, one per route, the most-flown first.
    var arcs: [WorldFlightArc]
    /// Airports only flown through.
    var rings: [WorldFlightAirportMark]
    /// Airports the person found (stamped).
    var found: [WorldFlightAirportMark]
    /// How many airports the passport keeps (the plate's count).
    var airportCount: Int
    /// How many flights the passport keeps (the plate's count).
    var flightCount: Int

    /// No flights and no airports.
    static let none = WorldFlightMap(arcs: [], rings: [], found: [], airportCount: 0, flightCount: 0)
}

/// The pure half of Your world's flight arcs (spec §8): grouping flights into routes, the great circle between
/// two airports, splitting a projected arc where it wraps round the world, the arc under a tap, and the card's
/// distance. No SwiftUI and no store, so the tests drive it with made-up airports.
nonisolated enum WorldFlightArcs {
    /// The most routes drawn (a heavy flyer's 20,000 flights rarely make more than a few hundred).
    static let maxRoutes = 2_000
    /// Points on each arc's great circle, ends included.
    static let pointsPerArc = 64
    /// The most found airports or rings drawn.
    static let maxMarks = 2_000
    /// The Earth's mean radius, in kilometres (the mockup's `km`).
    static let earthRadiusKilometres = 6_371.0

    /// One route's tally while grouping.
    struct Tally: Equatable, Sendable {
        /// The earliest flight's departure code.
        let from: String
        /// The earliest flight's arrival code.
        let to: String
        /// Flights on the route.
        var flights: Int
        /// Whether every flight so far was imported.
        var allImported: Bool
    }

    /// The routes of `flights` (earliest first, as the book keeps them), in the order first flown, at most
    /// ``maxRoutes``; a flight on a route past the cap is not counted. Bounded: the book's
    /// ``PassportBook/maxFlights``.
    static func routes(_ flights: [PassportFlight]) -> [(route: WorldFlightRoute, tally: Tally)] {
        var order: [WorldFlightRoute] = []
        var tallies: [WorldFlightRoute: Tally] = [:]
        // Bounded: the flights given (the book holds at most PassportBook.maxFlights).
        for flight in flights.prefix(PassportBook.maxFlights) {
            let route = WorldFlightRoute(flight.from, flight.to)
            let imported = !flight.sources.contains(.fernlet)
            if var tally = tallies[route] {
                tally.flights += 1
                tally.allImported = tally.allImported && imported
                tallies[route] = tally
            } else if order.count < maxRoutes {
                order.append(route)
                tallies[route] = Tally(from: flight.from, to: flight.to, flights: 1, allImported: imported)
            }
        }
        return order.compactMap { route in tallies[route].map { (route: route, tally: $0) } }
    }

    // MARK: The sphere

    /// A point as a unit vector (x towards 0°N 0°E, z towards the North Pole).
    private static func vector(_ point: GeoPoint) -> (x: Double, y: Double, z: Double) {
        let lat = point.latitude * .pi / 180, lon = point.longitude * .pi / 180
        return (cos(lat) * cos(lon), cos(lat) * sin(lon), sin(lat))
    }

    /// The angle between `a` and `b` seen from the Earth's centre, in radians.
    private static func centralAngle(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        let p = vector(a), q = vector(b)
        return acos(min(max(p.x * q.x + p.y * q.y + p.z * q.z, -1), 1))
    }

    /// The great-circle distance from `a` to `b`, in kilometres.
    static func kilometres(_ a: GeoPoint, _ b: GeoPoint) -> Double {
        centralAngle(a, b) * earthRadiusKilometres
    }

    /// `count` points (at least 2) along the great circle from `a` to `b`, ends included (the mockup's `gc`);
    /// just the two ends when they are the same place or exactly opposite (no one great circle). Bounded:
    /// `count` is clamped to ``pointsPerArc``.
    static func greatCircle(from a: GeoPoint, to b: GeoPoint, count: Int = pointsPerArc) -> [GeoPoint] {
        let n = min(max(count, 2), pointsPerArc) - 1
        let p = vector(a), q = vector(b), omega = centralAngle(a, b), s = sin(omega)
        guard s > 1e-9 else { return [a, b] }
        // Bounded: at most pointsPerArc points.
        return (0...n).map { i in
            let t = Double(i) / Double(n)
            let s1 = sin((1 - t) * omega) / s, s2 = sin(t * omega) / s
            let x = s1 * p.x + s2 * q.x, y = s1 * p.y + s2 * q.y, z = s1 * p.z + s2 * q.z
            return GeoPoint(asin(min(max(z, -1), 1)) * 180 / .pi, atan2(y, x) * 180 / .pi)
        }
    }

    /// The great circle from `a` to `b` in Mercator units, each `x` wrapped into `0..<1`.
    static func mercatorPath(from a: GeoPoint, to b: GeoPoint) -> [CGPoint] {
        // Bounded: pointsPerArc points.
        greatCircle(from: a, to: b).map { point in
            let unit = WebMercator.unit(point)
            return CGPoint(x: WorldViewCamera.wrap(unit.x), y: unit.y)
        }
    }

    // MARK: On screen

    /// A projected arc cut into pieces wherever one step jumps more than half the world's width (`worldWidth`
    /// points) sideways: the arc crossed the seam opposite the view's centre and its next point is drawn on the
    /// far copy (the mockup's `jump`). Bounded: the points given.
    static func pieces(_ points: [CGPoint], worldWidth: Double) -> [[CGPoint]] {
        guard worldWidth > 0, worldWidth.isFinite else { return [] }
        var pieces: [[CGPoint]] = []
        var current: [CGPoint] = []
        // Bounded: the points given (pointsPerArc for an arc).
        for point in points {
            if let last = current.last, abs(Double(point.x - last.x)) > worldWidth / 2 {
                if current.count > 1 { pieces.append(current) }
                current = []
            }
            current.append(point)
        }
        if current.count > 1 { pieces.append(current) }
        return pieces
    }

    /// The distance from `point` to the segment `a`–`b`.
    static func distance(from point: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> Double {
        let dx = Double(b.x - a.x), dy = Double(b.y - a.y), length = dx * dx + dy * dy
        let px = Double(point.x - a.x), py = Double(point.y - a.y)
        let t = length > 0 ? min(max((px * dx + py * dy) / length, 0), 1) : 0
        let ex = px - t * dx, ey = py - t * dy
        return (ex * ex + ey * ey).squareRoot()
    }

    /// The ID of the drawn arc nearest `point` within `reach` points, or nil. Bounded: the arcs given, each
    /// with at most ``pointsPerArc`` points.
    static func arc(at point: CGPoint, among drawn: [(id: String, pieces: [[CGPoint]])], reach: Double) -> String? {
        var best: (id: String, distance: Double)?
        // Bounded: the arcs drawn (maxRoutes), their pieces' points (pointsPerArc each).
        for arc in drawn {
            for piece in arc.pieces {
                for (a, b) in zip(piece, piece.dropFirst()) {
                    let d = distance(from: point, toSegment: a, b)
                    if d <= reach, d < (best?.distance ?? .infinity) { best = (arc.id, d) }
                }
            }
        }
        return best?.id
    }

    /// Each arc's pieces on screen for `camera`: its points at their copies nearest the centre, cut where a step
    /// jumps half the world, keeping the pieces whose box meets the screen grown by `margin` points. Bounded: the arcs given
    /// (``WorldFlightArcs/maxRoutes``), ``WorldFlightArcs/pointsPerArc`` points each.
    static func projected(_ arcs: [WorldFlightArc], camera: WorldViewCamera,
                          margin: Double) -> [(id: String, pieces: [[CGPoint]])] {
        let screen = CGRect(origin: .zero, size: camera.size).insetBy(dx: -margin, dy: -margin)
        // Bounded: the arcs given.
        return arcs.compactMap { arc in
            let points = arc.path.map { camera.screenPoint(x: Double($0.x), y: Double($0.y)) }
            let pieces = WorldFlightArcs.pieces(points, worldWidth: camera.scale).filter { piece in
                bounds(of: piece).intersects(screen)
            }
            return pieces.isEmpty ? nil : (id: arc.id, pieces: pieces)
        }
    }

    /// The box round `points`.
    private static func bounds(of points: [CGPoint]) -> CGRect {
        let xs = points.map(\.x), ys = points.map(\.y)
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max() else { return .null }
        return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
    }

    // MARK: Words

    /// `kilometres` rounded to the nearest 10 with its thousands grouped: "3,620" in English, "3.620" in
    /// Spanish (spec §12: Spanish groups with "." even at four digits, so not the system's style). Bounded: an
    /// `Int`'s digits.
    static func groupedKilometres(_ kilometres: Double, spanish: Bool) -> String {
        guard kilometres.isFinite, kilometres >= 0 else { return "0" }
        let rounded = Int((min(kilometres, 1e9) / 10).rounded()) * 10
        let digits = Array(String(rounded))
        var out = ""
        // Bounded: the digits of an Int under 1e9 (ten at most).
        for (index, digit) in digits.enumerated() {
            if index > 0, (digits.count - index) % 3 == 0 { out.append(spanish ? "." : ",") }
            out.append(digit)
        }
        return out
    }
}

nonisolated extension WorldFlightMap {
    /// One airport as the map needs it: where it is and its city's name (or its code).
    struct Airport: Sendable {
        /// Where it is.
        let point: GeoPoint
        /// Its city in the app's language, or the code when the pack names none.
        let name: String
    }

    /// The map for `book`: an arc for every route whose two airports `lookup` places, the most-flown first; a
    /// ring at every arc end that isn't among `found` (the found airports, by code); and the passport's counts.
    /// Bounded: ``WorldFlightArcs/maxRoutes`` routes, ``WorldFlightArcs/maxMarks`` marks of each kind.
    static func make(book: PassportBook, found: [(code: String, airport: Airport)],
                     lookup: (String) -> Airport?) -> WorldFlightMap {
        let foundMarks = found.prefix(WorldFlightArcs.maxMarks).map { mark($0.code, $0.airport) }
        let foundCodes = Set(foundMarks.map(\.code))
        var known: [String: Airport?] = [:]
        func place(_ code: String) -> Airport? {
            if let cached = known[code] { return cached }
            let looked = lookup(code)
            known[code] = looked
            return looked
        }
        var arcs: [WorldFlightArc] = []
        var ringCodes: [String] = []
        // Bounded: at most WorldFlightArcs.maxRoutes routes.
        for (route, tally) in WorldFlightArcs.routes(book.flights) {
            guard let from = place(tally.from), let to = place(tally.to) else { continue }
            arcs.append(WorldFlightArc(route: route, from: tally.from, to: tally.to, fromName: from.name,
                                       toName: to.name, flights: tally.flights, allImported: tally.allImported,
                                       kilometres: WorldFlightArcs.kilometres(from.point, to.point),
                                       path: WorldFlightArcs.mercatorPath(from: from.point, to: to.point)))
            ringCodes.append(contentsOf: [tally.from, tally.to].filter { !foundCodes.contains($0) })
        }
        arcs.sort { ($0.flights, $1.id) > ($1.flights, $0.id) }
        var seen = Set<String>()
        // Bounded: two codes per arc drawn, at most maxMarks kept.
        let rings = ringCodes.filter { seen.insert($0).inserted }.prefix(WorldFlightArcs.maxMarks)
            .compactMap { code in place(code).map { mark(code, $0) } }
        return WorldFlightMap(arcs: arcs, rings: Array(rings), found: foundMarks,
                              airportCount: book.count(of: .airport), flightCount: book.flights.count)
    }

    /// The person's map from the bundled pack: the found airports (the book's airport tokens the pack knows) and
    /// the arcs between the IATA points the pack lists, named in the app's language. No pack: the counts alone.
    static func live(book: PassportBook, airports: WorldAirports?) -> WorldFlightMap {
        guard let airports else {
            return WorldFlightMap(arcs: [], rings: [], found: [], airportCount: book.count(of: .airport),
                                  flightCount: book.flights.count)
        }
        let spanish = WorldViewNames.language == .spanish
        // Bounded: the book's airports, at most maxMarks.
        let found = book.visits(of: .airport).keys.sorted().prefix(WorldFlightArcs.maxMarks).compactMap { token in
            airports.airport(token: token).map { (code: $0.code, airport: Airport(point: $0.point, name: $0.city(spanish: spanish))) }
        }
        return make(book: book, found: found) { code in
            airports.point(iata: code).map { Airport(point: $0.point, name: airports.airport(code: code)?.city(spanish: spanish) ?? code) }
        }
    }

    /// A mark for `code` at `airport`.
    private static func mark(_ code: String, _ airport: Airport) -> WorldFlightAirportMark {
        let unit = WebMercator.unit(airport.point)
        return WorldFlightAirportMark(code: code, name: airport.name,
                                      mercator: CGPoint(x: WorldViewCamera.wrap(unit.x), y: unit.y))
    }
}
