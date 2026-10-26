import Foundation
import WorldMapStore

/// Whether the person has stopped somewhere, from the map's readings alone (W-13, issue desk 2026-10-26),
/// so a place is looked up where they stay, not along the road on the way. In memory only.
///
/// The person has stopped once they have stayed within ``stayRadius`` of one spot for ``stayTime``, or
/// moved slower than walking (``slowSpeed``) for ``slowTime``. A reading farther than ``stayRadius`` from
/// the spot starts a new one there; a reading at walking speed or faster ends a slow spell.
nonisolated struct WorldStopWatch: Equatable, Sendable {
    /// How near the spot the person must stay, in metres.
    static let stayRadius = 50.0
    /// How long they must stay there ("a few minutes").
    static let stayTime: TimeInterval = 3 * 60
    /// Slower than this is below walking speed, in metres a second.
    static let slowSpeed = 1.0
    /// How long below walking speed counts as a stop.
    static let slowTime: TimeInterval = 60
    /// The longest gap between two readings whose pace still counts.
    static let maxGap: TimeInterval = 5 * 60

    /// Where the person has been staying, and since when.
    private(set) var spot: GeoPoint?
    private(set) var since: Date?
    /// The last reading, for the speed between readings.
    private var last: GeoPoint?
    private var lastAt: Date?
    /// Since when every reading has been slower than walking.
    private var slowSince: Date?

    /// Takes a reading at `point` at `date`; whether the person has stopped.
    mutating func observe(_ point: GeoPoint, at date: Date) -> Bool {
        let leftSpot = spot.map { $0.distance(to: point) > Self.stayRadius } ?? true
        if leftSpot {
            spot = point
            since = date
        }
        observeSpeed(point, at: date)
        last = point
        lastAt = date
        return isStopped(at: date)
    }

    /// Whether, as of `date`, the person has stayed long enough or been slow long enough.
    func isStopped(at date: Date) -> Bool {
        if let since, date.timeIntervalSince(since) >= Self.stayTime { return true }
        if let slowSince, date.timeIntervalSince(slowSince) >= Self.slowTime { return true }
        return false
    }

    /// How long from `date` until staying at the spot counts as a stop, if the person stays put; nil
    /// once it does (or with no spot yet).
    func timeToStop(at date: Date) -> TimeInterval? {
        guard let since else { return nil }
        let left = Self.stayTime - date.timeIntervalSince(since)
        return left > 0 ? left : nil
    }

    /// Starts or ends a slow spell from the speed since the last reading. Readings far apart in time (the
    /// app was closed) say nothing about the pace between them, so they start no spell.
    private mutating func observeSpeed(_ point: GeoPoint, at date: Date) {
        guard let last, let lastAt else { return }
        let seconds = date.timeIntervalSince(lastAt)
        guard seconds > 0 else { return }
        guard seconds <= Self.maxGap else {
            slowSince = nil
            return
        }
        if last.distance(to: point) / seconds < Self.slowSpeed {
            if slowSince == nil { slowSince = lastAt }
        } else {
            slowSince = nil
        }
    }
}
