import CoreGraphics
import Foundation
import WorldMapStore

/// What Home draws of the bundled airports for one viewport (World-Airports-Spec §2.3, §3, §5): which airports
/// stand near the view, when a found airport's dotted fence shows, which way its runway runs for the take-offs, and
/// whether the view is at street zooms (the planes). Pure and bounded; ``WorldAirportMemo`` keeps the answers.
nonisolated enum WorldAirportSelection {
    /// The most airports drawn at once (the nearest kept).
    static let maxAirports = 12
    /// How far an airport's grounds can reach from its point, in metres: its fence or planes may be on screen while
    /// its tower is just off it (the largest outlines run about 5 km from the reference point).
    static let groundsReachMetres = 5_000.0
    /// How far past the screen's edge the tower is still drawn, in points (it is 57 pt tall with its plate).
    static let edgeMargin: CGFloat = 80
    /// The share of the screen's width or height an airport's outline must span for its fence to show (§2.3:
    /// "only at the zooms where the airport fills more than about a third of the screen").
    static let fenceShare: CGFloat = 1.0 / 3.0
    /// The runway an airport with no ring is given for its take-offs, in metres (its 1.5 km circle's width).
    static let circleRunwayMetres = 1_500.0

    /// How far from the viewport's centre to look for airports, in metres: half the screen's diagonal plus
    /// ``edgeMargin``, plus ``groundsReachMetres``, at most `WorldLandmarks.maxSearchMetres`.
    static func searchMetres(_ viewport: MapViewport, size: CGSize) -> Double {
        let perMetre = viewport.pointsPerMetre(at: viewport.center.latitude, in: size)
        guard perMetre > 0, perMetre.isFinite else { return 0 }
        let points = Double(hypot(size.width, size.height) / 2 + edgeMargin)
        return min(points / perMetre + groundsReachMetres, WorldLandmarks.maxSearchMetres)
    }

    /// The airports within `metres` of `centre`, nearest first (ties by token), at most ``maxAirports``. Bounded:
    /// one pass over at most `WorldAirports.maxAirports`, a latitude check before any distance.
    static func near(_ airports: [WorldAirport], centre: GeoPoint, withinMetres metres: Double) -> [WorldAirport] {
        guard centre.isValid, metres > 0 else { return [] }
        let latitudeReach = metres / GeoPoint.metresPerDegree
        var near: [(airport: WorldAirport, metres: Double)] = []
        // Bounded: the pack's airports, at most `WorldAirports.maxAirports`.
        for airport in airports.prefix(WorldAirports.maxAirports)
        where abs(airport.point.latitude - centre.latitude) <= latitudeReach {
            let distance = centre.distance(to: airport.point)
            if distance <= metres { near.append((airport, distance)) }
        }
        let ordered = near.sorted { ($0.metres, $0.airport.token) < ($1.metres, $1.airport.token) }
        return ordered.prefix(maxAirports).map(\.airport)
    }

    /// Whether the view is at street zooms, where the planes park and take off (under the city markers' step).
    @MainActor
    static func isStreetZoom(_ viewport: MapViewport) -> Bool {
        viewport.isUsable && !WorldExploreSelection.isZoomedOut(viewport)
    }

    /// Our own approved outline of `airport` (the only grounds Home draws as a fence, §2.3), or nil.
    static func fenceOutline(of airport: WorldAirport) -> [GeoPoint]? {
        guard case .outline(let ring) = airport.grounds, ring.count >= 3 else { return nil }
        return ring
    }

    /// Whether a fence whose points span `bounds` on a screen of `size` shows: the outline spans more than
    /// ``fenceShare`` of the screen's width or height.
    static func fenceShows(bounds: CGRect, screen size: CGSize) -> Bool {
        guard size.width > 0, size.height > 0, !bounds.isNull, bounds.width.isFinite, bounds.height.isFinite else { return false }
        return bounds.width / size.width > fenceShare || bounds.height / size.height > fenceShare
    }

    /// The bounding box of `points`; `.null` for none.
    static func bounds(of points: [CGPoint]) -> CGRect {
        guard let first = points.first else { return .null }
        var box = CGRect(origin: first, size: .zero)
        // Bounded: the ring's points, at most `WorldAirports.maxRingPoints`.
        for point in points.prefix(WorldAirports.maxRingPoints) { box = box.union(CGRect(origin: point, size: .zero)) }
        return box
    }

    /// Which way `airport`'s runway runs, as its two ends: the two farthest-apart points of its ring (our outline or
    /// its widened runways), else a ``circleRunwayMetres`` runway running east–west through its point. Bounded: at
    /// most `WorldAirports.maxRingPoints` squared pairs.
    static func runwayAxis(of airport: WorldAirport) -> (GeoPoint, GeoPoint) {
        let half = circleRunwayMetres / 2
        let fallback = (airport.point.offset(east: -half, north: 0), airport.point.offset(east: half, north: 0))
        let ring: [GeoPoint]
        switch airport.grounds {
        case .circle: return fallback
        case .runways(let points), .outline(let points): ring = Array(points.prefix(WorldAirports.maxRingPoints))
        }
        guard ring.count >= 2 else { return fallback }
        var best = (ring[0], ring[1]), longest = -1.0
        // Bounded: each pair of the ring's points once, at most 64 × 63 / 2.
        for i in 0..<ring.count {
            for j in (i + 1)..<ring.count {
                let metres = ring[i].distance(to: ring[j])
                if metres > longest { (best, longest) = ((ring[i], ring[j]), metres) }
            }
        }
        return best
    }
}

/// When the planes take off (World-Airports-Spec §5: "about every two minutes while Fernlet is open, a plane takes
/// off along the runway"): each airport keeps its own two-minute beat, offset by its token so two airports on screen
/// don't roll together, and a take-off rolls for ``rollDuration`` along the middle of its runway, speeding up, then
/// lifts: it grows a little and fades as it climbs away. Pure.
nonisolated enum WorldAirportPlaneSchedule {
    /// Time between take-offs at one airport.
    static let period: TimeInterval = 120
    /// How long one take-off is on screen.
    static let rollDuration: TimeInterval = 9
    /// Where on the runway the roll starts and where the plane is gone, as shares of its length.
    static let rollSpan: ClosedRange<Double> = 0.15...0.9
    /// When the wheels leave the ground, as a share of the roll: the plane grows and fades from here.
    static let liftOff = 0.6

    /// The airport's own offset into the beat: its token's characters summed, modulo ``period``.
    static func offset(for token: String) -> TimeInterval {
        // Bounded: a token's characters (an IATA code or an ident, a handful).
        let sum = token.unicodeScalars.prefix(16).reduce(0) { $0 + Int($1.value) }
        return TimeInterval(sum % Int(period))
    }

    /// The first take-off at `token`'s airport at or after `now`.
    static func nextTakeOff(after now: Date, token: String) -> Date {
        let shifted = now.timeIntervalSince1970 - offset(for: token)
        let beats = (shifted / period).rounded(.up)
        return Date(timeIntervalSince1970: beats * period + offset(for: token))
    }

    /// How far through a take-off `token`'s airport is at `date` (0 at the start of the roll, under 1 at its end),
    /// or nil between take-offs.
    static func progress(at date: Date, token: String) -> Double? {
        let shifted = date.timeIntervalSince1970 - offset(for: token)
        let intoBeat = shifted - (shifted / period).rounded(.down) * period
        return intoBeat < rollDuration ? intoBeat / rollDuration : nil
    }

    /// How far along the roll the plane is at `progress` (it speeds up: the square), from the start of
    /// ``rollSpan`` to its end.
    static func runwayShare(_ progress: Double) -> Double {
        let p = min(max(progress, 0), 1)
        return rollSpan.lowerBound + (rollSpan.upperBound - rollSpan.lowerBound) * p * p
    }

    /// The plane's size at `progress`: 1 on the ground, growing to 1.5 as it climbs.
    static func liftScale(_ progress: Double) -> CGFloat {
        let climb = max(0, min(1, (progress - liftOff) / (1 - liftOff)))
        return CGFloat(1 + climb * 0.5)
    }

    /// The plane's opacity at `progress`: whole until 85 % of the roll, then gone by its end.
    static func liftOpacity(_ progress: Double) -> Double {
        max(0, min(1, (1 - progress) / 0.15))
    }
}

/// Home's airports for the viewport, kept while the map stays near (``WorldAirportSelection``'s answers): the
/// airports near the view, worked out again only when the view moves more than about a tenth of its reach, and
/// each airport's runway, once. Main actor, held by the layer for the session; public data only.
@MainActor
final class WorldAirportMemo {
    private var centre: GeoPoint?
    private var reach = 0.0
    private var nearby: [WorldAirport] = []
    private var axes: [String: (GeoPoint, GeoPoint)] = [:]
    /// The most runways kept.
    static let maxAxes = 64

    /// The airports near `viewport`, from `pack`, nearest first.
    func airports(in pack: WorldAirports, near viewport: MapViewport, size: CGSize) -> [WorldAirport] {
        guard viewport.isUsable else { return [] }
        let metres = WorldAirportSelection.searchMetres(viewport, size: size)
        let here = viewport.center
        if let centre, here.distance(to: centre) <= reach * 0.1, abs(metres - reach) <= reach * 0.25 { return nearby }
        centre = here
        reach = metres
        nearby = WorldAirportSelection.near(pack.airports, centre: here, withinMetres: metres)
        return nearby
    }

    /// `airport`'s runway ends (worked out once).
    func runway(of airport: WorldAirport) -> (GeoPoint, GeoPoint) {
        if let kept = axes[airport.token] { return kept }
        let axis = WorldAirportSelection.runwayAxis(of: airport)
        if axes.count >= Self.maxAxes { axes.removeAll() }
        axes[airport.token] = axis
        return axis
    }
}
