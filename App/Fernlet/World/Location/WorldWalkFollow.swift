import Foundation
import WorldMapStore

/// The rules for following a walk in the background (owner 2026-11-21, pick A of the city-walk investigation: a
/// pocketed walk nobody started cleared only spots, because a listen ran two minutes and the next fence was twice
/// as wide). Plain values, in memory only; ``WorldLocationSource`` owns one and does what it says.
///
/// - **Seeing a walk (during a listen):** good readings (precise, within ``goodAccuracy``) at walking pace, each
///   within ``maxGap`` of the last, spanning ``seeTime`` and carrying the person ``seeDistance`` beyond both
///   readings' accuracy (GPS drift round one spot goes nowhere). Where Motion is read it must say walking or
///   running; a run may go faster than a walk, but never at a car's speed. A reading faster than that starts the run
///   over, so a car or a bike is left to car and bike detection.
/// - **Following it:** the source keeps continuous background updates at its walk pace. Each good reading that
///   moved beyond both readings' accuracy from the last one that did is "moving".
/// - **Still (the follow ends):** nothing moving for ``stillTime``, or, where Motion is read, Motion saying
///   stationary for that long. A follow never lasts longer than ``maxTime`` (a bound: indoor drift could
///   otherwise look like moving for ever where Motion is not read); the next fence starts another.
nonisolated struct WorldWalkFollow: Equatable, Sendable {
    /// The worst accuracy a reading may have to count, in metres (car and bike detection's and the fog's limit).
    static let goodAccuracy = WorldRideWatch.goodAccuracy
    /// How long readings at walking pace must span before a listen has seen a walk.
    static let seeTime: TimeInterval = 45
    /// How far they must carry the person beyond both readings' accuracy, in metres.
    static let seeDistance = 30.0
    /// The slowest average pace that is a walk, in metres a second (slower is waiting about).
    static let minPace = WorldRideWatch.footSpeed
    /// The fastest pace that is a walk, in metres a second.
    static let walkPace = WorldRideWatch.walkingSpeed
    /// The fastest pace that is a run, while Motion says running: below a car's speed.
    static let runPace = WorldRideWatch.carSpeed
    /// The longest gap between two readings of one run of walking, in seconds.
    static let maxGap: TimeInterval = 60
    /// How long with nothing moving (or Motion stationary) ends a follow.
    static let stillTime: TimeInterval = 3 * 60
    /// The longest one follow lasts (a bound).
    static let maxTime: TimeInterval = 6 * 60 * 60

    /// A good reading kept to measure from: where, how sure, when.
    nonisolated struct Anchor: Equatable, Sendable {
        let point: GeoPoint
        let accuracy: Double
        let at: Date
    }

    /// The first and the latest reading of the current run at walking pace, while a listen looks for a walk.
    private(set) var runFrom: Anchor?
    private(set) var runTo: Anchor?
    /// When the follow started; nil while none runs.
    private(set) var startedAt: Date?
    /// The last reading that moved, while a walk is followed.
    private(set) var moved: Anchor?

    /// Whether a walk is being followed.
    var isFollowing: Bool { startedAt != nil }

    /// Whether a reading counts at all.
    static func isGood(_ fix: WorldFix) -> Bool {
        fix.isPrecise && fix.accuracy.isFinite && fix.accuracy >= 0 && fix.accuracy <= goodAccuracy
    }

    /// Whether Motion, where it is read, allows a walk: walking or running. Not read, the pace decides alone.
    static func allows(motionRead: Bool, motion: WorldMotionKind?) -> Bool {
        guard motionRead else { return true }
        return motion == .walking || motion == .running
    }

    /// The fastest pace still a walk or a run under `motion`.
    static func ceiling(motion: WorldMotionKind?) -> Double {
        motion == .running ? runPace : walkPace
    }

    /// Takes a reading during a listen: it joins the run at walking pace, or starts it over (too fast, too long
    /// after the last, or older than it). Other readings are passed by.
    mutating func see(_ fix: WorldFix, motion: WorldMotionKind? = nil) {
        guard Self.isGood(fix) else { return }
        let here = Anchor(point: fix.point, accuracy: fix.accuracy, at: fix.at)
        guard let last = runTo, runFrom != nil else {
            startRun(at: here, speed: fix.speed, motion: motion)
            return
        }
        let seconds = fix.at.timeIntervalSince(last.at)
        let speed = fix.speed ?? (seconds > 0 ? last.point.distance(to: fix.point) / seconds : 0)
        guard seconds >= 0, seconds <= Self.maxGap, speed <= Self.ceiling(motion: motion) else {
            startRun(at: here, speed: fix.speed, motion: motion)
            return
        }
        runTo = here
    }

    /// Starts the run at `here`, unless the reading's own speed says it is no walk (then there is no run).
    private mutating func startRun(at here: Anchor, speed: Double?, motion: WorldMotionKind?) {
        let walking = (speed ?? 0) <= Self.ceiling(motion: motion)
        runFrom = walking ? here : nil
        runTo = walking ? here : nil
    }

    /// Whether the listen has seen steady walking: the run spans ``seeTime``, went ``seeDistance`` beyond both
    /// readings' accuracy at a walk's (or, Motion saying so, a run's) average pace, and Motion allows it.
    func seesWalk(motionRead: Bool, motion: WorldMotionKind?) -> Bool {
        guard Self.allows(motionRead: motionRead, motion: motion), let runFrom, let runTo else { return false }
        let seconds = runTo.at.timeIntervalSince(runFrom.at)
        guard seconds >= Self.seeTime else { return false }
        let metres = runFrom.point.distance(to: runTo.point)
        guard metres - runFrom.accuracy - runTo.accuracy >= Self.seeDistance else { return false }
        let pace = metres / seconds
        return pace >= Self.minPace && pace <= Self.ceiling(motion: motion)
    }

    /// The follow starts at `date`, moving from the run's latest reading; the run is forgotten.
    mutating func start(at date: Date) {
        startedAt = date
        moved = runTo.map { Anchor(point: $0.point, accuracy: $0.accuracy, at: date) }
        runFrom = nil
        runTo = nil
    }

    /// Takes a reading while the walk is followed: one beyond both readings' accuracy from the last that moved is
    /// moving.
    mutating func follow(_ fix: WorldFix) {
        guard isFollowing, Self.isGood(fix) else { return }
        guard let last = moved else {
            moved = Anchor(point: fix.point, accuracy: fix.accuracy, at: fix.at)
            return
        }
        guard fix.at >= last.at, last.point.distance(to: fix.point) > last.accuracy + fix.accuracy else { return }
        moved = Anchor(point: fix.point, accuracy: fix.accuracy, at: fix.at)
    }

    /// Whether the person has been still long enough at `now` to end the follow: nothing moving for ``stillTime``
    /// (since the start, before the first), or Motion (`motion` since `motionSince`, nil where not read) saying
    /// stationary that long, or the follow reaching ``maxTime``.
    func isOver(at now: Date, motion: WorldMotionKind? = nil, motionSince: Date? = nil) -> Bool {
        guard let startedAt else { return false }
        if now.timeIntervalSince(startedAt) >= Self.maxTime { return true }
        if now.timeIntervalSince(moved?.at ?? startedAt) >= Self.stillTime { return true }
        guard motion == .stationary, let motionSince else { return false }
        return now.timeIntervalSince(max(motionSince, startedAt)) >= Self.stillTime
    }

    /// Forgets everything (the follow ended, or a listen ended without one).
    mutating func reset() {
        self = WorldWalkFollow()
    }
}
