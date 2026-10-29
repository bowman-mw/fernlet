import Foundation
import WorldMapStore

/// Whether the person is driving, cycling or on foot, from the map's readings and, when allowed, the
/// motion coprocessor's activity (round 7, car and bike detection; `b1-home-car`, `b1-home-bike`). Plain
/// values, in memory only: the motion samples it is shown are never kept.
///
/// - **Driving, by speed first:** two readings faster than ``carSpeed`` within ``pairTime``, or one faster
///   than ``highwaySpeed``. With Motion, a confident automotive sample starts a drive too; while Motion says
///   cycling, speed alone never starts one (a fast downhill on a bike is no drive).
/// - **A drive survives red lights and traffic:** a quiet minute or two, or slow readings, never end it. It
///   ends on foot (a confident walking or running sample after it started, or walking-pace readings spanning
///   ``footTime`` after the last fast one while Motion says nothing of a car), or parked (``parkTime`` with
///   nothing faster than walking pace and, with Motion, no automotive activity in that time; ``tick(at:)``
///   ends it when the readings stop).
/// - **Cycling** only with Motion ("Log my bike rides" on and allowed): a confident cycling sample starts a
///   ride; it ends at the moment something else began once that has held ``rideGap`` (a red light is
///   shorter), or at once when the coprocessor says car. A ride of at least ``minRideTime`` whose distance
///   is unknown or at least ``minRideMetres`` ends as ``WorldRideEvent/rideEnded(_:)``, its distance from
///   the precise readings taken during it.
/// - **The ride's line** (Refinements group 19, `ref-ride-line`): the same good readings that measure the
///   distance draw it, one kept per ``lineStep`` moved (``ridePoints`` while the ride is on; the finished
///   ride carries them). Like the odometer it reaches back ``markLookBack`` while not cycling, because a
///   ride's start sample arrives late; bounded at ``maxLinePoints``.
///
/// A reading's speed is CoreLocation's own when it gave one, otherwise the pace from the last good reading
/// (unknown across a gap longer than ``maxGap``). Low-confidence samples decide nothing. Samples arrive
/// after the readings they cover (the keeper asks for them every half minute), so a sample from before the
/// last drive or ride ended starts nothing.
nonisolated struct WorldRideWatch: Equatable, Sendable {
    /// Faster than this is a car's speed, in metres a second (W-14's).
    static let carSpeed = WorldStopWatch.carSpeed
    /// One reading faster than this starts a drive on its own (about 43 km/h), in metres a second.
    static let highwaySpeed = 12.0
    /// Two readings at a car's speed within this start a drive.
    static let pairTime: TimeInterval = 60
    /// The fastest walking pace, in metres a second (W-14's).
    static let walkingSpeed = WorldStopWatch.walkingSpeed
    /// The slowest walking pace: slower is standing still, which neither ends nor holds a drive.
    static let footSpeed = 0.5
    /// How long walking-pace readings after the last fast one must span to end a drive on foot.
    static let footTime: TimeInterval = 60
    /// How long with nothing faster than walking (and, with Motion, no automotive activity) ends a drive.
    static let parkTime: TimeInterval = 5 * 60
    /// How long something other than cycling must hold to end a ride (a stop at a light is shorter).
    static let rideGap: TimeInterval = 3 * 60
    /// The shortest ride that logs.
    static let minRideTime: TimeInterval = 5 * 60
    /// The shortest distance a ride must cover to log, when its distance is known, in metres.
    static let minRideMetres = 500.0
    /// The worst accuracy a reading may have to count toward a pace or a ride's distance, in metres.
    static let goodAccuracy = 65.0
    /// The longest gap between two readings whose pace or distance still counts (W-14's).
    static let maxGap = WorldStopWatch.maxGap
    /// The odometer keeps a mark at most this often.
    static let markSpacing: TimeInterval = 10
    /// The most odometer marks kept (eleven hours of riding at ``markSpacing``).
    static let maxMarks = 4_000
    /// How far back the odometer is kept while not cycling (a ride's start sample arrives late).
    static let markLookBack: TimeInterval = 10 * 60
    /// The most samples one call takes (a bound; a day of activity is far fewer).
    static let maxSamples = 2_000
    /// The least distance between two kept points of a ride's line, in metres (the saved line's codec then
    /// thins it at 2.5 m, as a walk's).
    static let lineStep = 5.0
    /// The most points a ride's line keeps (the saved line's own cap).
    static let maxLinePoints = WorldRouteCodec.maxPoints

    /// The ride's odometer at one moment: how far the good readings had covered by `at`.
    nonisolated struct Mark: Equatable, Sendable {
        let at: Date
        let metres: Double
    }

    /// One kept point of the line, with when it was read (a ride takes the points from its start on).
    nonisolated struct LinePoint: Equatable, Sendable {
        let at: Date
        let point: GeoPoint
    }

    /// How the person is moving now.
    private(set) var mode: WorldRideMode = .onFoot
    /// Whether motion samples are being shown (Log my bike rides on and Motion allowed); without them the
    /// watch decides by speed alone and never sees a bike. Turning it off forgets the motion and ends a ride
    /// unlogged.
    var usesMotion = false {
        didSet { if !usesMotion { forgetMotion() } }
    }

    /// Whether the person is driving now.
    var isDriving: Bool {
        if case .driving = mode { return true }
        return false
    }

    /// Whether the person is cycling now.
    var isCycling: Bool {
        if case .cycling = mode { return true }
        return false
    }

    /// The ride's line so far while cycling (`ref-ride-line`), oldest first; empty on foot or driving.
    var ridePoints: [RoutePoint] {
        guard case .cycling(let since) = mode else { return [] }
        return linePoints(from: since, to: nil)
    }

    // Readings.
    private var lastAt: Date?
    private var goodPoint: GeoPoint?
    private var goodAt: Date?
    /// The last reading at a car's speed while on foot (half of a pair).
    private var fastAt: Date?
    /// While driving: the last reading faster than walking (or the drive's start).
    private var movingAt: Date?
    /// While driving: the first and latest walking-pace readings since ``movingAt``.
    private var footSince: Date?
    private var footAt: Date?
    /// When the last drive or ride ended; an older sample starts nothing.
    private var endedAt: Date?

    // Motion.
    private var motionKind: WorldMotionKind?
    private var motionSince: Date?
    private var automotiveUntil: Date?
    private var sampleAt: Date?

    // The odometer.
    private var odometer = 0.0
    private var marks: [Mark] = []
    // The line.
    private var line: [LinePoint] = []

    /// Takes a location reading; what changed. A reading older than the last one is passed by.
    mutating func observe(_ fix: WorldFix) -> [WorldRideEvent] {
        guard fix.point.isValid, lastAt.map({ fix.at >= $0 }) ?? true else { return [] }
        let speed = fix.speed ?? pace(to: fix)
        noteDistance(fix)
        lastAt = fix.at
        var events: [WorldRideEvent] = []
        switch mode {
        case .onFoot: events += startBySpeed(speed, at: fix.at)
        case .driving: events += followDrive(speed, at: fix.at)
        case .cycling: break
        }
        return events + settle(at: fix.at)
    }

    /// Takes motion samples (oldest first); what changed. Ignored without Motion.
    mutating func observe(_ samples: [WorldMotionSample]) -> [WorldRideEvent] {
        guard usesMotion else { return [] }
        var events: [WorldRideEvent] = []
        for sample in samples.prefix(Self.maxSamples) where sample.isConfident {
            guard sampleAt.map({ sample.at > $0 }) ?? true else { continue }
            sampleAt = sample.at
            events += settle(at: sample.at)
            events += take(sample)
        }
        return events
    }

    /// Ends a drive or ride that has gone quiet, as of `date`; what changed.
    mutating func tick(at date: Date) -> [WorldRideEvent] {
        settle(at: date)
    }

    /// The bike rides in a stretch of motion history (the app was closed through them), oldest first: rides
    /// that had ended by `end`, with no distance (no readings were taken).
    static func rides(in samples: [WorldMotionSample], until end: Date) -> [WorldBikeRide] {
        replay(samples, until: end).events.compactMap(\.bikeRide)
    }

    /// When a ride still going at `end` began in a stretch of motion history (cycling, or stopped for less
    /// than ``rideGap``); nil when none is.
    static func openRideStart(in samples: [WorldMotionSample], until end: Date) -> Date? {
        guard case .cycling(let since) = replay(samples, until: end).mode else { return nil }
        return since
    }

    /// A fresh watch with Motion shown a stretch of history up to `end`: where it ends up, and what changed.
    private static func replay(_ samples: [WorldMotionSample], until end: Date) -> (mode: WorldRideMode, events: [WorldRideEvent]) {
        var watch = WorldRideWatch()
        watch.usesMotion = true
        let events = watch.observe(samples) + watch.tick(at: end)
        return (watch.mode, events)
    }

    // MARK: Driving

    /// Starts a drive from a reading's speed: one past ``highwaySpeed`` or the second at a car's speed
    /// within ``pairTime``. Never while Motion says cycling.
    private mutating func startBySpeed(_ speed: Double?, at date: Date) -> [WorldRideEvent] {
        guard let speed, speed > Self.carSpeed, motionKind != .cycling else { return [] }
        if speed > Self.highwaySpeed { return startDrive(at: date) }
        if let fastAt, date.timeIntervalSince(fastAt) <= Self.pairTime { return startDrive(at: fastAt) }
        fastAt = date
        return []
    }

    /// Follows a drive's readings: faster than walking holds it; walking pace long enough ends it on foot,
    /// unless Motion said car meanwhile (stop-and-go traffic).
    private mutating func followDrive(_ speed: Double?, at date: Date) -> [WorldRideEvent] {
        guard let speed else { return [] }
        if speed > Self.walkingSpeed {
            movingAt = date
            footSince = nil
            footAt = nil
            return []
        }
        guard speed >= Self.footSpeed else { return [] }
        footSince = footSince ?? date
        footAt = date
        guard let footSince, date.timeIntervalSince(footSince) >= Self.footTime,
              !(usesMotion && automotive(since: footSince)) else { return [] }
        return endDrive(at: date)
    }

    private mutating func startDrive(at date: Date) -> [WorldRideEvent] {
        mode = .driving(since: date)
        movingAt = date
        footSince = nil
        footAt = nil
        fastAt = nil
        return [.driveStarted(date)]
    }

    private mutating func endDrive(at date: Date) -> [WorldRideEvent] {
        guard isDriving else { return [] }
        mode = .onFoot
        endedAt = date
        movingAt = nil
        footSince = nil
        footAt = nil
        fastAt = nil
        return [.driveEnded(date)]
    }

    /// Whether, as of `date`, the car has been parked long enough: nothing faster than walking for
    /// ``parkTime`` and, with Motion, no automotive activity in that time.
    private func isParked(at date: Date) -> Bool {
        guard let movingAt, date.timeIntervalSince(movingAt) >= Self.parkTime else { return false }
        return !(usesMotion && automotive(since: date.addingTimeInterval(-Self.parkTime)))
    }

    /// Whether Motion's automotive activity held at any moment since `start`.
    private func automotive(since start: Date) -> Bool {
        if motionKind == .automotive { return true }
        guard let automotiveUntil else { return false }
        return automotiveUntil > start
    }

    // MARK: Cycling and motion

    /// Ends a parked drive, or a ride something else has replaced for ``rideGap``, as of `date`.
    private mutating func settle(at date: Date) -> [WorldRideEvent] {
        switch mode {
        case .onFoot:
            return []
        case .driving:
            return isParked(at: date) ? endDrive(at: date) : []
        case .cycling(let since):
            guard motionKind != .cycling, let motionSince, date.timeIntervalSince(motionSince) >= Self.rideGap else {
                return []
            }
            return endRide(started: since, ended: motionSince)
        }
    }

    /// Takes one confident sample: the activity in effect from its moment, and what it starts or ends.
    private mutating func take(_ sample: WorldMotionSample) -> [WorldRideEvent] {
        let at = sample.at
        if sample.kind != motionKind {
            if motionKind == .automotive { automotiveUntil = at }
            motionKind = sample.kind
            motionSince = at
        }
        let fresh = endedAt.map { at > $0 } ?? true
        switch (sample.kind, mode) {
        case (.automotive, .cycling(let since)):
            return endRide(started: since, ended: at) + startDrive(at: at)
        case (.automotive, .onFoot) where fresh:
            return startDrive(at: at)
        case (.cycling, .driving):
            return endDrive(at: at) + startRide(at: at)
        case (.cycling, .onFoot) where fresh:
            return startRide(at: at)
        case (.walking, .driving(let since)), (.running, .driving(let since)):
            return at > since ? endDrive(at: at) : []
        default:
            return []
        }
    }

    private mutating func startRide(at date: Date) -> [WorldRideEvent] {
        mode = .cycling(since: date)
        fastAt = nil
        return [.rideStarted(date)]
    }

    /// Ends the ride; it logs when it is long enough and, when its distance is known, far enough.
    private mutating func endRide(started: Date, ended: Date) -> [WorldRideEvent] {
        guard isCycling else { return [] }
        mode = .onFoot
        endedAt = ended
        let ride = WorldBikeRide(started: started, ended: ended, metres: metres(from: started, to: ended),
                                 points: linePoints(from: started, to: ended))
        guard ended.timeIntervalSince(started) >= Self.minRideTime else { return [] }
        guard (ride.metres ?? Self.minRideMetres) >= Self.minRideMetres else { return [] }
        return [.rideEnded(ride)]
    }

    /// Forgets the motion (Motion turned off): a ride ends unlogged; a drive goes on by speed.
    private mutating func forgetMotion() {
        motionKind = nil
        motionSince = nil
        automotiveUntil = nil
        sampleAt = nil
        guard isCycling else { return }
        mode = .onFoot
        endedAt = lastAt
    }

    // MARK: Pace and distance

    /// Whether a reading is good enough for a pace or a distance.
    private static func isGood(_ fix: WorldFix) -> Bool {
        fix.isPrecise && fix.accuracy <= goodAccuracy
    }

    /// The pace from the last good reading to `fix`, in metres a second; nil when either is not good, or
    /// across a gap too long to say.
    private func pace(to fix: WorldFix) -> Double? {
        guard Self.isGood(fix), let goodPoint, let goodAt else { return nil }
        let seconds = fix.at.timeIntervalSince(goodAt)
        guard seconds > 0, seconds <= Self.maxGap else { return nil }
        return goodPoint.distance(to: fix.point) / seconds
    }

    /// Adds a good reading's step to the odometer and marks it, dropping marks no ride can need.
    private mutating func noteDistance(_ fix: WorldFix) {
        guard Self.isGood(fix) else { return }
        if let goodPoint, let goodAt, fix.at.timeIntervalSince(goodAt) <= Self.maxGap {
            odometer += goodPoint.distance(to: fix.point)
        }
        goodPoint = fix.point
        goodAt = fix.at
        let mark = Mark(at: fix.at, metres: odometer)
        let count = marks.count
        if count >= 2, marks[count - 1].at.timeIntervalSince(marks[count - 2].at) < Self.markSpacing {
            marks[count - 1] = mark
        } else {
            marks.append(mark)
        }
        if !isCycling {
            let cutoff = fix.at.addingTimeInterval(-Self.markLookBack)
            marks.removeAll { $0.at < cutoff }
        }
        if marks.count > Self.maxMarks { marks.removeFirst(marks.count - Self.maxMarks) }
        noteLine(fix)
    }

    /// Keeps a good reading on the line when it is at least ``lineStep`` from the last kept point, dropping
    /// points no ride can need (older than ``markLookBack`` while not cycling, or past ``maxLinePoints``).
    private mutating func noteLine(_ fix: WorldFix) {
        guard line.last.map({ $0.point.distance(to: fix.point) >= Self.lineStep }) ?? true else { return }
        line.append(LinePoint(at: fix.at, point: fix.point))
        if !isCycling {
            let cutoff = fix.at.addingTimeInterval(-Self.markLookBack)
            line.removeAll { $0.at < cutoff }
        }
        if line.count > Self.maxLinePoints { line.removeFirst(line.count - Self.maxLinePoints) }
    }

    /// The line's points read from `start` on (through `end` when given), oldest first.
    private func linePoints(from start: Date, to end: Date?) -> [RoutePoint] {
        let last = end ?? .distantFuture
        return line.filter { $0.at >= start && $0.at <= last }.map { RoutePoint($0.point) }
    }

    /// The distance the good readings covered from `start` to `end`; nil with fewer than two of them.
    private func metres(from start: Date, to end: Date) -> Double? {
        let inside = marks.filter { $0.at >= start && $0.at <= end }
        guard inside.count >= 2, let first = inside.first, let last = inside.last else { return nil }
        return last.metres - first.metres
    }
}
