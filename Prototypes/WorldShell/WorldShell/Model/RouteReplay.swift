import Foundation

/// A recorded route being replayed: a walk together, the saved hike, or a car or bike loop.
///
/// The shell has no GPS. Movement is these recorded coordinates played back faster than life
/// (about 12× for walks), so a kilometre takes a minute on the sofa. Distances shown are the
/// route's real ones.
nonisolated struct RouteReplay: Sendable {
    /// What kind of movement is being replayed.
    enum Kind: Sendable {
        case walk, hike, car, bike
    }

    let kind: Kind
    let route: Polyline
    /// Real metres covered so far (car and bike keep going round their loop).
    var travelled = 0.0
    /// Fog cells this replay has lifted that weren't lifted before.
    var freshCells = 0

    /// Replay speed in metres per second of screen time.
    var speed: Double {
        switch kind {
        case .walk, .hike: 17
        case .bike: 38
        case .car: 70
        }
    }

    /// How far around each point the fog lifts (the mockup's radii): a car lifts only a thin line.
    var liftRadius: Double {
        switch kind {
        case .walk, .hike: 56
        case .bike: 36
        case .car: 22
        }
    }

    /// Car and bike loops go round until the ride state changes; walks end at the route's end.
    var loops: Bool { kind == .car || kind == .bike }

    /// Whether a walk or hike has reached the end of its route.
    var isFinished: Bool { !loops && travelled >= route.length }

    /// Where the companion is now.
    var position: GeoPoint {
        let length = route.length
        guard length > 0 else { return route.point(at: 0) }
        return route.point(at: loops ? travelled.truncatingRemainder(dividingBy: length) : min(travelled, length))
    }

    /// The dotted line drawn behind a walk so far (car and bike draw none).
    var trace: [GeoPoint] {
        switch kind {
        case .walk, .hike: route.prefix(to: travelled)
        case .car, .bike: []
        }
    }

    /// Kilometres covered, for the walk bar and toasts.
    var kilometres: String { String(format: "%.1f", travelled / 1_000) }
}

extension Polyline {
    /// A closed loop restarted at the vertex nearest `point`, so a ride starts where you are.
    nonisolated func loopStarting(near point: GeoPoint) -> Polyline {
        guard points.count > 2,
              let nearest = points.indices.min(by: { points[$0].distance(to: point) < points[$1].distance(to: point) })
        else { return self }
        let open = Array(points.dropLast())
        let index = min(nearest, open.count - 1)
        let rotated = Array(open[index...]) + Array(open[..<index])
        return Polyline(rotated + [rotated[0]])
    }
}
