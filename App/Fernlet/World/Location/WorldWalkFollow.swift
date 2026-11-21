import Foundation
import WorldMapStore

/// The rules for following a walk in the background (owner 2026-11-21, pick A of the city-walk investigation: a
/// pocketed walk nobody started cleared only spots, because a listen ran two minutes and the next fence was twice
/// as wide). Plain values, in memory only; ``WorldLocationSource`` owns one and does what it says.
///
/// - **Seeing a walk (during a listen):** good readings (precise, within ``goodAccuracy``) at walking pace, each
///   within ``maxGap`` of the last, spanning ``seeTime`` and carrying the person ``seeDistance`` beyond both
///   readings' accuracy (GPS drift round one spot goes nowhere). While Motion says running, a run may go faster
///   than a walk, but never at a car's speed. A reading at a car's speed, or two in a row faster than a walk, start
///   the run over, so a car or a bike is left to car and bike detection; one stray fast reading is passed by.
/// - **Why some full listens saw no walk (the owner's phone log of 2026-11-20, three of five):** read against the
///   rule, three things could block a real walk, and each is answered here. (1) The distance was measured from the
///   listen's first good reading, which after a wake is the roughest (Wi-Fi, 40 to 65 m), so a walk had to go a
///   hundred metres before it counted; now it is measured from a reading at least twice as sharp when one comes
///   within ``settleTime`` (``measureFrom``). (2) Motion had to say walking or running, and for a phone in a hand
///   it often says nothing or stationary, and its history runs late (both hand-overs in the log came 112 s in, the
///   listen's fourth motion query); now only Motion saying car or bike refuses a walk, and while it does not say
///   walking the readings alone must be surer: ``sureTime`` and ``sureDistance``. (3) One reading faster than a
///   walk started the run over; now it takes two in a row. Which of these it was on the phone the log cannot say,
///   so ``blocker(motionRead:motion:)`` names what stood in the way for the tracker diary.
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
    /// How long the readings must span while Motion is read and does not say walking or running (nothing yet,
    /// unknown or stationary): standing in a shop with GPS drift never gets this far.
    static let sureTime: TimeInterval = 75
    /// How far they must then carry the person beyond both readings' accuracy, in metres.
    static let sureDistance = 60.0
    /// How soon after a run's first reading a much sharper one (half its accuracy or better) takes over as the point
    /// the distance is measured from, in seconds.
    static let settleTime: TimeInterval = 20
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
    /// The reading the run's distance is measured from: its first, or a much sharper one soon after it.
    private(set) var measureFrom: Anchor?
    /// Whether the last reading was faster than a walk and passed by (a second in a row starts the run over).
    private(set) var passedFast = false
    /// How many good readings a listen has shown, and how many too rough or approximate to count (for the diary).
    private(set) var goodSeen = 0
    private(set) var roughSeen = 0
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

    /// Whether Motion, where it is read, refuses a walk outright: only when it says car or bike, which car and bike
    /// detection decide. Not read, or saying anything else, the readings decide.
    static func refuses(motionRead: Bool, motion: WorldMotionKind?) -> Bool {
        motionRead && (motion == .automotive || motion == .cycling)
    }

    /// Whether the readings alone must be surer (``sureTime``, ``sureDistance``): where Motion is read and does not
    /// say walking or running.
    static func needsSurer(motionRead: Bool, motion: WorldMotionKind?) -> Bool {
        motionRead && motion != .walking && motion != .running
    }

    /// The fastest pace still a walk or a run under `motion`.
    static func ceiling(motion: WorldMotionKind?) -> Double {
        motion == .running ? runPace : walkPace
    }

    /// Takes a reading during a listen: it joins the run at walking pace, or starts it over (at a car's speed, the
    /// second in a row faster than a walk, too long after the last, or older than it). One stray reading faster than
    /// a walk is passed by, and so are rough ones.
    mutating func see(_ fix: WorldFix, motion: WorldMotionKind? = nil) {
        guard Self.isGood(fix) else {
            roughSeen += 1
            return
        }
        goodSeen += 1
        let here = Anchor(point: fix.point, accuracy: fix.accuracy, at: fix.at)
        guard let last = runTo, let first = runFrom else {
            startRun(at: here, speed: fix.speed, motion: motion)
            return
        }
        let seconds = fix.at.timeIntervalSince(last.at)
        let speed = fix.speed ?? (seconds > 0 ? last.point.distance(to: fix.point) / seconds : 0)
        guard seconds >= 0, seconds <= Self.maxGap, speed <= Self.runPace else {
            startRun(at: here, speed: fix.speed, motion: motion)
            return
        }
        guard speed <= Self.ceiling(motion: motion) else {
            if passedFast { startRun(at: here, speed: fix.speed, motion: motion) }
            passedFast = true
            return
        }
        passedFast = false
        runTo = here
        // A wake's first reading is its roughest: measure from a much sharper one that comes soon after it.
        if let from = measureFrom, here.accuracy * 2 <= from.accuracy,
           here.at.timeIntervalSince(first.at) <= Self.settleTime {
            measureFrom = here
        }
    }

    /// Starts the run at `here`, unless the reading's own speed says it is no walk (then there is no run).
    private mutating func startRun(at here: Anchor, speed: Double?, motion: WorldMotionKind?) {
        let walking = (speed ?? 0) <= Self.ceiling(motion: motion)
        runFrom = walking ? here : nil
        runTo = walking ? here : nil
        measureFrom = walking ? here : nil
        passedFast = false
    }

    /// What stands between the listen and a walk now; nil when it has seen steady walking. In order: Motion saying
    /// car or bike, no good reading at walking pace, a run shorter than ``seeTime``, not ``seeDistance`` beyond both
    /// readings' accuracy from where it is measured, an average pace that is no walk's, and last, with Motion read
    /// and not saying walking or running, readings that would do with Motion's word but are not sure enough alone.
    func blocker(motionRead: Bool, motion: WorldMotionKind?) -> WorldWalkBlocker? {
        if Self.refuses(motionRead: motionRead, motion: motion) { return .motionSaysRide }
        guard let runFrom, let runTo, let measureFrom else { return .noRun }
        let seconds = runTo.at.timeIntervalSince(runFrom.at)
        guard seconds >= Self.seeTime else { return .tooShort }
        let metres = measureFrom.point.distance(to: runTo.point)
        let beyond = metres - measureFrom.accuracy - runTo.accuracy
        guard beyond >= Self.seeDistance else { return .notFar }
        let leg = runTo.at.timeIntervalSince(measureFrom.at)
        let pace = leg > 0 ? metres / leg : 0
        guard pace >= Self.minPace else { return .tooSlow }
        guard pace <= Self.ceiling(motion: motion) else { return .tooFast }
        guard Self.needsSurer(motionRead: motionRead, motion: motion) else { return nil }
        return seconds >= Self.sureTime && beyond >= Self.sureDistance ? nil : .motionUnsure
    }

    /// Whether the listen has seen steady walking (``blocker(motionRead:motion:)`` finds nothing in the way).
    func seesWalk(motionRead: Bool, motion: WorldMotionKind?) -> Bool {
        blocker(motionRead: motionRead, motion: motion) == nil
    }

    /// The follow starts at `date`, moving from the run's latest reading; the run is forgotten.
    mutating func start(at date: Date) {
        startedAt = date
        moved = runTo.map { Anchor(point: $0.point, accuracy: $0.accuracy, at: date) }
        runFrom = nil
        runTo = nil
        measureFrom = nil
        passedFast = false
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

    /// A listen starts: its readings are counted from here (the run seen with Fernlet open is kept).
    mutating func countFromHere() {
        goodSeen = 0
        roughSeen = 0
    }

    /// Forgets everything (the follow ended, or a listen ended without one).
    mutating func reset() {
        self = WorldWalkFollow()
    }
}

/// What stood between a listen and a walk follow (`WorldWalkFollow.blocker(motionRead:motion:)`): the tracker diary
/// writes it when a listen ends without one. Frozen tokens; never a place.
nonisolated enum WorldWalkBlocker: String, Equatable, Sendable, CaseIterable {
    /// Motion said car or bike.
    case motionSaysRide
    /// No good reading at walking pace (none at all, all too rough, or all too fast).
    case noRun
    /// The readings at walking pace spanned too little time.
    case tooShort
    /// They did not carry the person far enough beyond their accuracy.
    case notFar
    /// Their average pace was slower than a walk.
    case tooSlow
    /// Their average pace was faster than a walk.
    case tooFast
    /// They would have done with Motion saying walking, but Motion did not, and alone they were not sure enough.
    case motionUnsure
}

/// Whether the recent readings show the person moving (the owner's phone log of 2026-11-20: leaving the front
/// stopped everything until a fence exit that mostly never came). Fed every reading; when Fernlet leaves the front
/// the location source asks it, and starts a listen at once only when the answer is yes, so standing still costs
/// nothing. Plain values, in memory only.
///
/// Moving is a good reading ``moveDistance`` or more beyond both readings' accuracy from an earlier good one no
/// more than ``window`` before it: GPS drift round one spot stays inside its accuracy.
nonisolated struct WorldMoveWatch: Equatable, Sendable {
    /// How far beyond both readings' accuracy a reading must be from an earlier one to show movement, in metres.
    static let moveDistance = 20.0
    /// How far back an earlier reading may be, in seconds.
    static let window: TimeInterval = 2 * 60
    /// The least time between two kept readings, in seconds.
    static let spacing: TimeInterval = 10
    /// The most readings kept (the window at this spacing).
    static let maxKept = Int(window / spacing) + 1
    /// How recent the movement must be when asked, in seconds.
    static let freshTime: TimeInterval = 60

    /// The good readings kept to measure from, oldest first.
    private(set) var kept: [WorldWalkFollow.Anchor] = []
    /// When a reading last showed movement.
    private(set) var movedAt: Date?

    /// Takes a reading: a good one that moved notes when, and is kept to measure later ones from.
    mutating func observe(_ fix: WorldFix) {
        guard WorldWalkFollow.isGood(fix) else { return }
        if let newest = kept.last, fix.at < newest.at { kept.removeAll() }
        kept.removeAll { fix.at.timeIntervalSince($0.at) > Self.window }
        let moved = kept.contains { $0.point.distance(to: fix.point) - $0.accuracy - fix.accuracy >= Self.moveDistance }
        if moved { movedAt = fix.at }
        if let newest = kept.last, fix.at.timeIntervalSince(newest.at) < Self.spacing { return }
        kept.append(WorldWalkFollow.Anchor(point: fix.point, accuracy: fix.accuracy, at: fix.at))
        if kept.count > Self.maxKept { kept.removeFirst(kept.count - Self.maxKept) }
    }

    /// Whether the readings showed movement within ``freshTime`` of `now`.
    func isMoving(at now: Date) -> Bool {
        guard let movedAt else { return false }
        let seconds = now.timeIntervalSince(movedAt)
        return seconds >= 0 && seconds <= Self.freshTime
    }
}
