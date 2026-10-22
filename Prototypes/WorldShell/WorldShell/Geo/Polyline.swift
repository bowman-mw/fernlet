import Foundation

/// A route as an ordered list of ``GeoPoint``s, with its running length precomputed so a replay
/// can find "the point 640 m along" without walking the whole line each frame.
nonisolated struct Polyline: Sendable {
    let points: [GeoPoint]
    /// `cumulative[i]` is the distance in metres from the first point to `points[i]`.
    let cumulative: [Double]

    init(_ points: [GeoPoint]) {
        self.points = points
        var running: [Double] = []
        running.reserveCapacity(points.count)
        var total = 0.0
        for (index, point) in points.enumerated() {
            if index > 0 { total += points[index - 1].distance(to: point) }
            running.append(total)
        }
        cumulative = running
    }

    /// The route's whole length in metres.
    var length: Double { cumulative.last ?? 0 }

    /// The point `metres` along the route, clamped to its ends.
    func point(at metres: Double) -> GeoPoint {
        guard let first = points.first, let last = points.last else { return GeoPoint(0, 0) }
        guard metres > 0 else { return first }
        guard metres < length else { return last }
        let upper = cumulative.firstIndex { $0 >= metres } ?? (points.count - 1)
        let lower = max(0, upper - 1)
        let span = cumulative[upper] - cumulative[lower]
        let fraction = span > 0 ? (metres - cumulative[lower]) / span : 0
        return points[lower].lerp(to: points[upper], fraction)
    }

    /// The part of the route from its start to `metres` along, ending exactly there.
    func prefix(to metres: Double) -> [GeoPoint] {
        guard metres > 0 else { return Array(points.prefix(1)) }
        let whole = cumulative.firstIndex { $0 > metres } ?? points.count
        return Array(points.prefix(whole)) + [point(at: metres)]
    }

    /// Points every `spacing` metres along the route (bounded at 4,000 samples).
    func samples(every spacing: Double) -> [GeoPoint] {
        guard spacing > 0, length > 0 else { return Array(points.prefix(1)) }
        let count = min(4_000, Int(length / spacing) + 1)
        return (0...count).map { point(at: Double($0) * spacing) }
    }
}
