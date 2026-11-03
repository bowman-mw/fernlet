import SwiftUI
import WorldMapStore

/// When a plane flies over and along which line (owner 2026-11-02: "within a mile or two of an airport, you should
/// occasionally see an airplane fly"). Each airport keeps its own three-minute beat, and a plane crosses the screen
/// in line with the airport's runway, as one on its approach would. Pure.
nonisolated enum WorldAirportFlyOverSchedule {
    /// How close to an airport the person must be, in metres: two miles.
    static let reachMetres = 3_200.0
    /// How far from the person to look for airports, in metres: ``reachMetres`` past the farthest reference point.
    static let searchMetres = reachMetres + WorldAirportSelection.groundsReachMetres
    /// Time between planes at one airport.
    static let period: TimeInterval = 180
    /// How long one plane takes to cross the screen.
    static let crossing: TimeInterval = 14
    /// How far past the screen's corners a plane starts and ends, in points.
    static let edgeMargin: CGFloat = 48
    /// How far off the screen's middle each beat's line runs, as shares of the screen's shorter side.
    static let laneShares: [CGFloat] = [-0.25, 0.1, -0.08, 0.22]

    /// Whether `person` is within ``reachMetres`` of `airport`: its point, its grounds, or either end of a runway
    /// (a reference point can be kilometres from the field's edge).
    static func isNear(_ airport: WorldAirport, to person: GeoPoint) -> Bool {
        guard airport.point.distance(to: person) > reachMetres, !airport.contains(person) else { return true }
        // Bounded: at most WorldAirports.maxRunways.
        return airport.runways.prefix(WorldAirports.maxRunways).contains {
            $0.start.distance(to: person) <= reachMetres || $0.end.distance(to: person) <= reachMetres
        }
    }

    /// The first plane over `token`'s airport at or after `now`.
    static func next(after now: Date, token: String) -> Date {
        let offset = offset(for: token)
        return Date(timeIntervalSince1970: ((now.timeIntervalSince1970 - offset) / period).rounded(.up) * period + offset)
    }

    /// Which beat `date`, one of ``next(after:token:)``'s answers, is.
    static func beat(at date: Date, token: String) -> Int {
        Int(max(0, ((date.timeIntervalSince1970 - offset(for: token)) / period).rounded()))
    }

    /// Where a beat's plane starts and ends on a screen of `size`: parallel to `runway`, in one lane of
    /// ``laneShares``, flying the other way on odd beats. Nil for an empty screen or a runway with no length.
    static func path(along runway: (GeoPoint, GeoPoint), beat: Int, size: CGSize) -> (start: CGPoint, end: CGPoint)? {
        let east = (runway.1.longitude - runway.0.longitude) * cos(runway.0.latitude * .pi / 180)
        let north = runway.1.latitude - runway.0.latitude
        let length = (east * east + north * north).squareRoot()
        guard size.width > 0, size.height > 0, length > 0 else { return nil }
        let turn: CGFloat = beat % 2 == 0 ? 1 : -1
        let dx = CGFloat(east / length) * turn, dy = CGFloat(-north / length) * turn
        let lane = laneShares[beat % laneShares.count] * min(size.width, size.height)
        let middle = CGPoint(x: size.width / 2 - dy * lane, y: size.height / 2 + dx * lane)
        let reach = hypot(size.width, size.height) / 2 + edgeMargin
        return (CGPoint(x: middle.x - dx * reach, y: middle.y - dy * reach),
                CGPoint(x: middle.x + dx * reach, y: middle.y + dy * reach))
    }

    /// ``path(along:beat:size:)`` as places on the map under `viewport`, where the plane stays through a pan or a pinch.
    static func mapPath(along runway: (GeoPoint, GeoPoint), beat: Int, viewport: MapViewport, size: CGSize) -> (start: GeoPoint, end: GeoPoint)? {
        guard viewport.isUsable, let path = path(along: runway, beat: beat, size: size) else { return nil }
        return (viewport.geo(at: path.start, in: size), viewport.geo(at: path.end, in: size))
    }

    /// The airport's offset into the beat, a minute off its runway planes' so the two rarely overlap.
    private static func offset(for token: String) -> TimeInterval {
        (WorldAirportPlaneSchedule.offset(for: token) + 60).truncatingRemainder(dividingBy: period)
    }
}

/// The airport the person is near, looked for again only once they've moved ``moveBeforeLooking``. Main actor, held
/// by the layer; it reads the latest reading and the bundled list, and keeps nothing past the session.
@MainActor
final class WorldAirportFlyOverMemo {
    /// How far the person moves, in metres, before the nearby airports are looked at again.
    static let moveBeforeLooking = 200.0
    private var lookedFrom: GeoPoint?
    private var found: WorldAirport?

    /// The nearest airport `person` is within reach of, from `pack`, or nil.
    func airport(near person: GeoPoint, in pack: WorldAirports) -> WorldAirport? {
        if let lookedFrom, person.distance(to: lookedFrom) < Self.moveBeforeLooking { return found }
        lookedFrom = person
        found = WorldAirportSelection.near(pack.airports, centre: person, withinMetres: WorldAirportFlyOverSchedule.searchMetres)
            .first { WorldAirportFlyOverSchedule.isNear($0, to: person) }
        return found
    }
}

/// A plane now and then crossing the map near an airport (``WorldAirportFlyOverSchedule``): the jet with its shadow
/// far below, flying between two places on the map, so a pan or a pinch mid-crossing moves it with everything else
/// (owner 2026-11-02). None with Reduce Motion. Decoration, hidden from VoiceOver and touches.
///
/// **Cheap:** between planes one sleeping task waits for the next, and a crossing is one SwiftUI animation.
struct WorldAirportFlyOver: View {
    let token: String
    /// The airport's runway, whose line the plane follows.
    let runway: (GeoPoint, GeoPoint)
    let viewport: MapViewport
    let size: CGSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Where the plane under way flies between, as places on the map.
    @State private var path: (start: GeoPoint, end: GeoPoint)?
    @State private var progress = 0.0

    /// The most planes one visit plays (a full day near one airport); a bound for the waiting loop.
    static let maxCrossings = 480

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !reduceMotion, let path {
                WorldSpriteView(sprite: WorldAirportSprites.rollingJet(tail: 0), scale: 3)
                    .shadow(color: .black.opacity(0.22), radius: 0, x: 10, y: 16)
                    .modifier(WorldFlyOverMotion(progress: progress, start: viewport.screenPoint(for: path.start, in: size),
                                                 end: viewport.screenPoint(for: path.end, in: size)))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: "\(token)\(reduceMotion)") { await fly() }
    }

    /// Waits for each plane on the airport's beat and flies it, until the airport is left behind (the task is
    /// cancelled) or Reduce Motion is on.
    private func fly() async {
        path = nil
        guard !reduceMotion else { return }
        // Bounded: at most `maxCrossings` planes; the task ends sooner when the person moves away.
        for _ in 0..<Self.maxCrossings {
            let next = WorldAirportFlyOverSchedule.next(after: Date(), token: token)
            let beat = WorldAirportFlyOverSchedule.beat(at: next, token: token)
            do {
                try await Task.sleep(for: .seconds(max(0, next.timeIntervalSinceNow)))
                progress = 0
                path = WorldAirportFlyOverSchedule.mapPath(along: runway, beat: beat, viewport: viewport, size: size)
                try await Task.sleep(for: .milliseconds(50))
                withAnimation(.linear(duration: WorldAirportFlyOverSchedule.crossing)) { progress = 1 }
                try await Task.sleep(for: .seconds(WorldAirportFlyOverSchedule.crossing + 0.2))
            } catch {
                path = nil
                return
            }
            path = nil
        }
    }
}

/// Moves the flying plane along its line as `progress` animates from 0 to 1, nose first.
struct WorldFlyOverMotion: ViewModifier, Animatable {
    var progress: Double
    let start: CGPoint
    let end: CGPoint

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .rotationEffect(.radians(atan2(Double(end.y - start.y), Double(end.x - start.x))))
            .position(x: start.x + (end.x - start.x) * progress, y: start.y + (end.y - start.y) * progress)
    }
}
