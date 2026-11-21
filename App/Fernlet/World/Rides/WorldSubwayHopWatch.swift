import Foundation
import WorldMapStore

/// A ride with no GPS that looks like a subway hop: where and when the good readings stopped and came back.
nonisolated struct WorldSubwayHopCandidate: Equatable, Sendable {
    /// The last good reading before the gap.
    let from: GeoPoint
    let left: Date
    /// The first good reading after it.
    let to: GeoPoint
    let arrived: Date

    /// How long the good readings were gone, in seconds.
    var seconds: TimeInterval { arrived.timeIntervalSince(left) }
    /// How far apart the two readings are, in metres (a straight line: the tunnel's way is unknown).
    var metres: Double { from.distance(to: to) }
}

/// Finds subway hops (owner 2026-11-21, "build subway hops now"; decided 2026-11-15 as a dotted in/out hop). Plain
/// values, in memory only; ``WorldLocationSource`` owns one and asks Motion's history about each candidate.
///
/// Underground there is no GPS, so nothing is traced. A hop is told afterwards from three things, none of them GPS:
///
/// - **A gap in good readings** (precise, within ``goodAccuracy``) of ``minGap`` to ``maxGap``. Rough readings do
///   arrive underground where a metro has mobile coverage (the owner's ride of 2026-11-20 got four), so only good
///   ones count, either side.
/// - **The readings either side** at least ``minMetres`` apart, and not further than ``maxSpeed`` could carry
///   anyone in the gap.
/// - **Motion's history for the gap** saying automotive (how CoreMotion reads a train) for at least
///   ``minRideTime`` and ``minShare`` of the gap, at an average of ``minSpeed`` to ``maxSpeed`` over that time
///   (``isHop(_:automotive:)``). The speed is measured over the automotive time, not the whole gap: the walk down
///   to the platform and the wait are in the gap too.
///
/// Never while a drive or a bike ride is on (their readings flow, and they are kept as their own trips), nor when
/// a known car was connected at either end. **It is an inference**: a car or bus ride that Fernlet could not trace
/// reads the same, so a hop is kept unconfirmed and its sheet says "possible".
nonisolated struct WorldSubwayHopWatch: Equatable, Sendable {
    /// The worst accuracy a reading may have to end or start a gap, in metres.
    static let goodAccuracy = WorldRideWatch.goodAccuracy
    /// The shortest and longest gap in good readings that can be a hop, in seconds.
    static let minGap: TimeInterval = 3 * 60
    static let maxGap: TimeInterval = 2 * 60 * 60
    /// The least distance between the readings either side, in metres.
    static let minMetres = 500.0
    /// The slowest and fastest average speed of a ride, in metres a second (15 and 80 km/h).
    static let minSpeed = 15.0 / 3.6
    static let maxSpeed = 80.0 / 3.6
    /// The least time Motion must say automotive in the gap, in seconds, and the least share of the gap.
    static let minRideTime: TimeInterval = 2 * 60
    static let minShare = 0.5
    /// The most motion samples one gap reads (a bound).
    static let maxSamples = 2_000

    /// The last good reading, and whether a known car was connected then.
    private(set) var last: WorldFix?

    /// Whether a reading can end or start a gap.
    static func isGood(_ fix: WorldFix) -> Bool {
        fix.isPrecise && fix.accuracy.isFinite && fix.accuracy >= 0 && fix.accuracy <= goodAccuracy
    }

    /// Takes a reading (stamped: it says whether a car is connected and whether it is inside an airport); a
    /// candidate when it is the first good one after a gap that could be a hop. `moving` is whether a drive or a
    /// bike ride is on. A reading older than the last good one is passed by.
    mutating func observe(_ fix: WorldFix, moving: Bool) -> WorldSubwayHopCandidate? {
        guard Self.isGood(fix) else { return nil }
        guard let before = last else {
            last = fix
            return nil
        }
        guard fix.at >= before.at else { return nil }
        last = fix
        guard !moving, !fix.carLinked, !before.carLinked, !fix.atAirport, !before.atAirport else { return nil }
        let candidate = WorldSubwayHopCandidate(from: before.point, left: before.at, to: fix.point, arrived: fix.at)
        return Self.couldBeHop(candidate) ? candidate : nil
    }

    /// Whether the gap and the distance alone allow a hop, before Motion is asked.
    static func couldBeHop(_ candidate: WorldSubwayHopCandidate) -> Bool {
        let seconds = candidate.seconds, metres = candidate.metres
        guard seconds >= minGap, seconds <= maxGap, metres >= minMetres else { return false }
        return metres / seconds <= maxSpeed
    }

    /// How long Motion's confident samples say automotive between `start` and `end`, in seconds. Each sample holds
    /// until the next; before the first nothing is known, so nothing counts.
    static func automotiveSeconds(in samples: [WorldMotionSample], from start: Date, to end: Date) -> TimeInterval {
        var total: TimeInterval = 0
        var since: Date?
        // Bounded: at most maxSamples samples.
        for sample in samples.prefix(maxSamples) where sample.isConfident && sample.at <= end {
            let at = max(sample.at, start)
            if sample.kind == .automotive {
                since = since ?? at
            } else if let began = since {
                total += max(0, at.timeIntervalSince(began))
                since = nil
            }
        }
        if let began = since { total += max(0, end.timeIntervalSince(began)) }
        return total
    }

    /// Whether a candidate whose gap held `automotive` seconds of Motion's automotive is a hop.
    static func isHop(_ candidate: WorldSubwayHopCandidate, automotive: TimeInterval) -> Bool {
        guard couldBeHop(candidate), automotive >= minRideTime, automotive >= candidate.seconds * minShare else {
            return false
        }
        let speed = candidate.metres / automotive
        return speed >= minSpeed && speed <= maxSpeed
    }

    /// Forgets the last good reading (the delete funnel, or background mapping going off).
    mutating func reset() {
        last = nil
    }
}
