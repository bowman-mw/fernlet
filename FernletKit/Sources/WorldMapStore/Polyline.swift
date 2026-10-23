import Foundation

/// A line on the ground as an ordered list of ``GeoPoint``s, with its running length precomputed, so
/// "the point 640 m along" and "a sample every 10 m" never walk the whole line twice.
///
/// Used to lift the fog along a walk and to draw trails. Bounded: a line keeps at most
/// ``maxPoints`` points (a recorder thins before it gets here), and ``samples(every:)`` returns at
/// most ``maxSamples``.
public nonisolated struct Polyline: Sendable {
    /// The most points a line keeps; extra points are dropped from the end.
    public static let maxPoints = 50_000
    /// The most samples ``samples(every:)`` returns.
    public static let maxSamples = 4_000

    /// The line's points, in order.
    public let points: [GeoPoint]
    /// `cumulative[i]` is the distance in metres from the first point to `points[i]`.
    public let cumulative: [Double]

    /// A line through `points` (invalid points are skipped).
    public init(_ points: [GeoPoint]) {
        let kept = Array(points.lazy.filter(\.isValid).prefix(Self.maxPoints))
        var running: [Double] = []
        running.reserveCapacity(kept.count)
        var total = 0.0
        for (index, point) in kept.enumerated() {
            if index > 0 { total += kept[index - 1].distance(to: point) }
            running.append(total)
        }
        self.points = kept
        cumulative = running
    }

    /// The line's whole length in metres.
    public var length: Double { cumulative.last ?? 0 }

    /// The point `metres` along the line, clamped to its ends; nil for an empty line.
    public func point(at metres: Double) -> GeoPoint? {
        guard let first = points.first, let last = points.last else { return nil }
        guard metres > 0 else { return first }
        guard metres < length else { return last }
        let upper = cumulative.firstIndex { $0 >= metres } ?? (points.count - 1)
        let lower = max(0, upper - 1)
        let span = cumulative[upper] - cumulative[lower]
        let fraction = span > 0 ? (metres - cumulative[lower]) / span : 0
        return points[lower].lerp(to: points[upper], fraction)
    }

    /// Points every `spacing` metres along the line, ends included (at most ``maxSamples``).
    public func samples(every spacing: Double) -> [GeoPoint] {
        guard spacing > 0, spacing.isFinite, length > 0 else { return Array(points.prefix(1)) }
        // Clamp in Double before converting, so a tiny spacing can never overflow `Int`; the 1e-6
        // keeps a length a hair over a whole number of spacings from gaining a needless segment.
        let segments = max(1, Int(min((length / spacing - 1e-6).rounded(.up), Double(Self.maxSamples - 1))))
        let step = length / Double(segments)
        return (0...segments).compactMap { point(at: Double($0) * step) }
    }
}
