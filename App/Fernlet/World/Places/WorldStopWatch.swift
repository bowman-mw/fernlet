import Foundation
import WorldMapStore

/// Whether the person has stopped somewhere, from the map's readings alone (W-13, made stricter by W-14,
/// issue desk 2026-10-26), so a place is looked up where they stay, not along the road on the way. In memory only.
///
/// - **Staying:** within ``stayRadius`` of one spot for ``stayTime``. A reading farther than that from the
///   spot starts a new one there.
/// - **Slow:** at least ``slowReadings`` readings in a row, each slower than walking (``slowSpeed``), spanning
///   ``slowTime``, straight after walking-pace movement (no faster than ``walkingSpeed``). A gap between two
///   readings alone never makes a slow spell: the map hears nothing while a car waits at a red light, so
///   the reading as it pulls away looks slow over the gap.
/// - **After a drive** (a reading faster than ``carSpeed`` within ``carWindow`` before the dwell began, or
///   during it): only a real dwell counts, within ``dwellRadius`` for ``dwellTime``, confirmed by a reading
///   still inside it or by the keeper's recheck with no newer reading. This holds until car detection exists.
/// - A reading whose own speed is above walking pace never decides (a car pulling away), and after a drive
///   the stop is at the dwell's spot, not at the moving reading (``stopPoint``).
///
/// A reading's speed is CoreLocation's own when it gave one, otherwise the pace from the reading before
/// (unknown across a gap longer than ``maxGap``, when the app was closed).
nonisolated struct WorldStopWatch: Equatable, Sendable {
    /// How near the spot the person must stay, in metres.
    static let stayRadius = 50.0
    /// How long they must stay there ("a few minutes").
    static let stayTime: TimeInterval = 3 * 60
    /// Slower than this is below walking speed, in metres a second.
    static let slowSpeed = 1.0
    /// How long the slow readings must span to count as a stop.
    static let slowTime: TimeInterval = 60
    /// How many readings in a row a slow spell takes.
    static let slowReadings = 3
    /// The fastest walking pace, in metres a second: a reading faster than this never decides.
    static let walkingSpeed = 2.5
    /// Faster than this is a car's speed, in metres a second.
    static let carSpeed = 7.0
    /// How long before a dwell a car's speed still makes it a stop after a drive.
    static let carWindow: TimeInterval = 3 * 60
    /// How near the dwell's spot the person must stay after a drive, in metres.
    static let dwellRadius = 30.0
    /// How long they must stay there after a drive.
    static let dwellTime: TimeInterval = 5 * 60
    /// The longest gap between two readings whose pace still counts.
    static let maxGap: TimeInterval = 5 * 60

    /// Where the person has been staying, and since when.
    private(set) var spot: GeoPoint?
    private(set) var since: Date?
    /// Where the person has stayed within ``dwellRadius``, and since when (the rule after a drive).
    private(set) var dwell: GeoPoint?
    private(set) var dwellSince: Date?
    /// The last reading, for the pace between readings.
    private var last: GeoPoint?
    private var lastAt: Date?
    /// The last reading's speed; nil when unknown.
    private var lastSpeed: Double?
    /// The run of readings slower than walking: how many (counted up to ``slowReadings``), since when, and
    /// whether walking-pace movement led into it.
    private var slowCount = 0
    private var slowSince: Date?
    private var walkedIn = false
    /// When a reading was last faster than ``carSpeed``.
    private var fastAt: Date?

    /// Takes a reading at `point` at `date`, with CoreLocation's own `speed` when it gave one; whether the
    /// person has stopped.
    mutating func observe(_ point: GeoPoint, speed own: Double? = nil, at date: Date) -> Bool {
        if spot.map({ $0.distance(to: point) > Self.stayRadius }) ?? true {
            spot = point
            since = date
        }
        if dwell.map({ $0.distance(to: point) > Self.dwellRadius }) ?? true {
            dwell = point
            dwellSince = date
        }
        observeSpeed(own ?? pace(to: point, at: date), at: date)
        last = point
        lastAt = date
        if let own, own > Self.walkingSpeed { return false }
        return isStopped(at: date)
    }

    /// Whether, as of `date`, the person has stayed long enough or been slow long enough. The keeper's
    /// recheck asks this with no newer reading.
    func isStopped(at date: Date) -> Bool {
        if isAfterDrive {
            guard let dwellSince else { return false }
            return date.timeIntervalSince(dwellSince) >= Self.dwellTime
        }
        if let since, date.timeIntervalSince(since) >= Self.stayTime { return true }
        return isSlowSpell
    }

    /// Where the stop is decided: the dwell's spot after a drive, otherwise the last reading.
    var stopPoint: GeoPoint? { isAfterDrive ? dwell : last }

    /// How long from `date` until staying at the spot counts as a stop, if the person stays put; nil
    /// once it does (or with no spot yet).
    func timeToStop(at date: Date) -> TimeInterval? {
        let afterDrive = isAfterDrive
        guard let start = afterDrive ? dwellSince : since else { return nil }
        let left = (afterDrive ? Self.dwellTime : Self.stayTime) - date.timeIntervalSince(start)
        return left > 0 ? left : nil
    }

    /// When the person began staying where the stop is decided: the dwell's start after a drive, otherwise
    /// the spot's (round 7, `ref-tag-how`: "Remember this place" shows once they have stayed over 2 minutes).
    var stayStart: Date? { isAfterDrive ? dwellSince : since }

    /// Starts the spot (and the dwell) at `point` from `date`: a low-power visit from iOS, with background
    /// mapping on, says the person arrived there then (round 7, `ref-tag-how`), so a reading there once
    /// Fernlet opens counts the stay from the arrival. A reading farther away starts a new spot as usual.
    mutating func seed(_ point: GeoPoint, since date: Date) {
        guard point.isValid else { return }
        spot = point
        since = date
        dwell = point
        dwellSince = date
    }

    /// Whether a reading at a car's speed came within ``carWindow`` before the dwell began, or during it.
    private var isAfterDrive: Bool {
        guard let fastAt, let dwellSince else { return false }
        return fastAt >= dwellSince.addingTimeInterval(-Self.carWindow)
    }

    /// Whether the slow run has enough readings, spans long enough and followed walking-pace movement.
    private var isSlowSpell: Bool {
        guard slowCount >= Self.slowReadings, walkedIn, let slowSince, let lastAt else { return false }
        return lastAt.timeIntervalSince(slowSince) >= Self.slowTime
    }

    /// The pace from the last reading to `point` at `date`, in metres a second; nil with no last reading or
    /// across a gap too long to say anything about the pace between.
    private func pace(to point: GeoPoint, at date: Date) -> Double? {
        guard let last, let lastAt else { return nil }
        let seconds = date.timeIntervalSince(lastAt)
        guard seconds > 0, seconds <= Self.maxGap else { return nil }
        return last.distance(to: point) / seconds
    }

    /// Notes a car's speed, and starts, extends or ends the slow run, from one reading's speed.
    private mutating func observeSpeed(_ speed: Double?, at date: Date) {
        if let speed, speed > Self.carSpeed { fastAt = date }
        if let speed, speed < Self.slowSpeed {
            if slowCount == 0 {
                slowSince = date
                walkedIn = lastSpeed.map { $0 >= Self.slowSpeed && $0 <= Self.walkingSpeed } ?? false
            }
            slowCount = min(slowCount + 1, Self.slowReadings)
        } else {
            slowCount = 0
            slowSince = nil
            walkedIn = false
        }
        lastSpeed = speed
    }
}
