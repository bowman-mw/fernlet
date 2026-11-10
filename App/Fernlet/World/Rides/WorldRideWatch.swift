import Foundation
import WorldMapStore

/// Whether the person is driving, cycling or on foot, from the map's readings and, when allowed, the
/// motion coprocessor's activity (round 7, car and bike detection; `b1-home-car`, `b1-home-bike`). Plain
/// values, in memory only: the motion samples it is shown are never kept.
///
/// - **Walking never shows the car** (owner's phone test 2026-10-30: "Walking around triggers the car
///   animation"). Only good readings (precise, within ``goodAccuracy``) have a speed; a pace is measured over
///   at least ``minPaceTime``, and a car's pace counts only the distance beyond both readings' accuracy, so
///   GPS jitter and a jump are no car.
/// - **Driving, by speed:** readings faster than ``carSpeed``, each within ``pairTime`` of the last and none
///   at walking pace between, spanning ``carHold``; one fast reading alone is never a drive. While Motion's
///   latest confident sample says cycling, walking or running, speed alone never starts one (a fast downhill
///   on a bike is no drive, nor a GPS spike on foot).
/// - **Driving, by Motion:** confident (medium or high) automotive activity that has held ``motionHold`` as
///   far as the samples are known, unless a reading since it began was at walking pace (the speed floor).
///   A short automotive flicker between walking samples starts nothing.
/// - **A drive survives red lights and traffic:** a quiet minute or two, or slow readings, never end it. It
///   ends on foot (a confident walking or running sample after it started, or walking-pace readings spanning
///   ``footTime`` after the last fast one that also carried the person ``footDistance`` beyond their accuracy at
///   ``footPace`` or more, while Motion says nothing of a car), or parked (``parkTime`` with nothing faster than walking pace, no
///   reading ``parkRadius`` beyond its accuracy from where the car last moved and, with Motion, no automotive
///   activity in that time; ``tick(at:)`` ends it when the readings stop). Owner 2026-11-09 ("really long stop
///   lights … make it think I'm walking"): creeping up in the queue at a light, and GPS drift while stopped, read
///   at walking pace but go nowhere, and a crawl through a jam moves the car further than a parked one goes.
/// - **A drive that ended on foot resumes quickly:** within ``resumeWindow`` of that end, readings at a car's
///   speed spanning ``resumeHold`` start it again, not the full ``carHold`` (a light that still fooled the foot
///   rule). ``lastDriveEnd`` says why the last drive ended, for the location source's cool-down.
/// - **Cycling** only with Motion ("Log my bike rides" or background mapping on, and allowed): a confident cycling sample starts a
///   ride; it ends at the moment something else began once that has held ``rideGap`` (a red light is
///   shorter), or at once when the coprocessor says car. A ride of at least ``minRideTime`` whose distance
///   is unknown or at least ``minRideMetres`` ends as ``WorldRideEvent/rideEnded(_:)``, its distance from
///   the precise readings taken during it.
/// - **The ride's line** (Refinements group 19, `ref-ride-line`): the good readings that measure the
///   distance draw it when they are within ``lineAccuracy`` (the walk line's 25 m; owner 2026-10-29, the
///   65 m rule is the distance's and the fog's), one kept per ``lineStep`` moved (``ridePoints`` while the ride is on; the finished
///   ride carries them). Like the odometer it reaches back ``markLookBack`` while not cycling, because a
///   ride's start sample arrives late; bounded at ``maxLinePoints``.
///
/// A good reading's speed is CoreLocation's own when it gave one, otherwise the pace from the pace anchor
/// (unknown across a gap longer than ``maxGap``). Low-confidence samples decide nothing. Samples arrive
/// after the readings they cover (the keeper asks for them every half minute), so a sample from before the
/// last drive or ride ended starts nothing.
nonisolated struct WorldRideWatch: Equatable, Sendable {
    /// Faster than this is a car's speed, in metres a second (W-14's).
    static let carSpeed = WorldStopWatch.carSpeed
    /// How long readings at a car's speed must span before speed alone starts a drive (owner 2026-10-30).
    static let carHold: TimeInterval = 30
    /// The longest gap between two readings at a car's speed that keeps them one run.
    static let pairTime: TimeInterval = 60
    /// How long confident automotive activity must hold before it starts a drive (owner 2026-10-30: a
    /// flicker while walking is no drive).
    static let motionHold: TimeInterval = 60
    /// The shortest time a pace is measured over (a second's GPS jitter is no speed).
    static let minPaceTime: TimeInterval = 10
    /// The fastest walking pace, in metres a second (W-14's).
    static let walkingSpeed = WorldStopWatch.walkingSpeed
    /// The slowest walking pace: slower is standing still, which neither ends nor holds a drive.
    static let footSpeed = 0.5
    /// How long walking-pace readings after the last fast one must span to end a drive on foot.
    static let footTime: TimeInterval = 60
    /// How far those readings must carry the person from the first of them, beyond both readings' accuracy, in
    /// metres (owner 2026-11-09): a minute's walk goes about 80 m, creeping up at a light a car length at a time.
    static let footDistance = 50.0
    /// The slowest average pace, beyond the readings' accuracy, those readings must keep over their run, in metres a
    /// second: a queue creeping up to a light for minutes, or GPS drift while stopped, is slower, and the run starts
    /// again from the latest reading, so a long light never adds up to a walk.
    static let footPace = 0.6
    /// How long with nothing faster than walking (and, with Motion, no automotive activity) ends a drive.
    static let parkTime: TimeInterval = 5 * 60
    /// How far beyond both readings' accuracy from where the car last moved a reading must be to count as moving,
    /// in metres: a crawl through a jam at walking pace gets this far within ``parkTime``, a parked car never.
    static let parkRadius = 100.0
    /// How soon after a drive ended on foot a run at a car's speed resumes it after only ``resumeHold``.
    static let resumeWindow: TimeInterval = 5 * 60
    /// How long readings at a car's speed must span to resume a drive that ended on foot within ``resumeWindow``.
    static let resumeHold: TimeInterval = 10
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
    /// The worst accuracy a reading may have to join a ride's line, in metres: the walk line's own
    /// (`WorldWalkRecorder.maxAccuracy`), so a ride's line is as clean as a walk's (owner 2026-10-29).
    static let lineAccuracy = 25.0
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

    /// The good reading a pace is measured from, with its accuracy.
    nonisolated struct PaceAnchor: Equatable, Sendable {
        let at: Date
        let point: GeoPoint
        let accuracy: Double
    }

    /// Why a drive ended, and when.
    nonisolated struct DriveEnded: Equatable, Sendable {
        let end: WorldDriveEnd
        let at: Date
    }

    /// A good reading's speed, in metres a second, and when it was read (the motion start's speed floor).
    nonisolated struct SpeedReading: Equatable, Sendable {
        let at: Date
        let metresPerSecond: Double
    }

    /// How the person is moving now.
    private(set) var mode: WorldRideMode = .onFoot
    /// Whether motion samples are being shown ("Log my bike rides" or background mapping on, and Motion allowed); without them the
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
    private var paceFrom: PaceAnchor?
    /// The latest good reading's speed.
    private var lastSpeed: SpeedReading?
    /// While on foot: the first and latest readings of the current run at a car's speed.
    private var fastSince: Date?
    private var fastAt: Date?
    /// While driving: the last reading faster than walking, or far from the one before (or the drive's start).
    private var movingAt: Date?
    /// While driving: where the car last moved, the good reading ``parkRadius`` is measured from.
    private var movingFrom: PaceAnchor?
    /// While driving: the first and latest walking-pace readings since ``movingAt``, and where the first was.
    private var footSince: Date?
    private var footAt: Date?
    private var footFrom: PaceAnchor?
    /// When the last drive or ride ended; an older sample starts nothing.
    private var endedAt: Date?
    /// Why and when the last drive ended.
    private var lastDrive: DriveEnded?

    /// Why the last drive ended; nil before the first.
    var lastDriveEnd: WorldDriveEnd? { lastDrive?.end }

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
        let speed = Self.isGood(fix) ? (fix.speed ?? pace(to: fix)) : nil
        // How fast the reading surely was: a pace counts only the distance beyond both readings' accuracy.
        let surely = Self.isGood(fix) ? (fix.speed ?? pace(to: fix, beyondAccuracy: true)) : nil
        if let speed { lastSpeed = SpeedReading(at: fix.at, metresPerSecond: speed) }
        notePaceAnchor(fix)
        noteDistance(fix)
        lastAt = fix.at
        var events: [WorldRideEvent] = []
        switch mode {
        case .onFoot: events += startBySpeed(speed, surely: surely, at: fix.at)
        case .driving: events += followDrive(fix, speed: speed)
        case .cycling: break
        }
        return events + settle(at: fix.at)
    }

    /// Takes motion samples (oldest first), the activity known through `end` when given (the query's end);
    /// what changed. Ignored without Motion.
    mutating func observe(_ samples: [WorldMotionSample], through end: Date? = nil) -> [WorldRideEvent] {
        guard usesMotion else { return [] }
        var events: [WorldRideEvent] = []
        for sample in samples.prefix(Self.maxSamples) where sample.isConfident {
            guard sampleAt.map({ sample.at > $0 }) ?? true else { continue }
            sampleAt = sample.at
            events += settle(at: sample.at)
            // The activity before this sample held until it.
            events += startByMotion(knownThrough: sample.at)
            events += take(sample)
        }
        if let end { events += startByMotion(knownThrough: end) }
        return events
    }

    /// Ends a drive or ride that has gone quiet, as of `date`; what changed.
    mutating func tick(at date: Date) -> [WorldRideEvent] {
        settle(at: date)
    }

    /// A flight is under way (the flight gate, World-Airports-Spec §6.1): a drive ends at `date`, a ride ends
    /// unlogged, and the motion so far is forgotten (a plane's activity reads as a car); what changed.
    mutating func takeOff(at date: Date) -> [WorldRideEvent] {
        let events = isDriving ? endDrive(at: date, because: .flight) : []
        if isCycling {
            mode = .onFoot
            endedAt = date
        }
        motionKind = nil
        motionSince = nil
        automotiveUntil = nil
        fastSince = nil
        fastAt = nil
        return events
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

    /// Starts a drive from a reading's speed once readings surely at a car's speed (`surely`), each within
    /// ``pairTime`` of the last, span ``carHold`` (``resumeHold`` just after a drive ended on foot, ``holdNeeded(at:)``);
    /// a reading at walking pace ends the run. Never while Motion says on foot or bike.
    private mutating func startBySpeed(_ speed: Double?, surely: Double?, at date: Date) -> [WorldRideEvent] {
        if let speed, Self.isWalkingPace(speed) {
            fastSince = nil
            fastAt = nil
            return []
        }
        guard let surely, surely > Self.carSpeed, speedMayStartDrive else { return [] }
        guard let fastSince, let fastAt, date.timeIntervalSince(fastAt) <= Self.pairTime else {
            self.fastSince = date
            self.fastAt = date
            return []
        }
        self.fastAt = date
        return date.timeIntervalSince(fastSince) >= holdNeeded(at: fastSince) ? startDrive(at: fastSince) : []
    }

    /// How long a run at a car's speed beginning at `start` must span to start a drive: ``resumeHold`` when the
    /// last drive ended on foot no more than ``resumeWindow`` before it, otherwise ``carHold``.
    private func holdNeeded(at start: Date) -> TimeInterval {
        guard let lastDrive, lastDrive.end == .onFoot, start >= lastDrive.at,
              start.timeIntervalSince(lastDrive.at) <= Self.resumeWindow else { return Self.carHold }
        return Self.resumeHold
    }

    /// Whether speed alone may start a drive: not while Motion's latest confident sample says cycling, walking
    /// or running.
    private var speedMayStartDrive: Bool {
        switch motionKind {
        case .cycling?, .walking?, .running?: false
        default: true
        }
    }

    /// Whether `speed` is a walking pace (between ``footSpeed`` and ``walkingSpeed``).
    private static func isWalkingPace(_ speed: Double) -> Bool {
        speed >= footSpeed && speed <= walkingSpeed
    }

    /// Starts a drive once Motion's automotive activity has held ``motionHold`` as far as the samples are
    /// known (`known`), from its start, unless a good reading since then was at walking pace (the speed floor),
    /// or it began before the last drive or ride ended.
    private mutating func startByMotion(knownThrough known: Date) -> [WorldRideEvent] {
        guard mode == .onFoot, motionKind == .automotive, let motionSince,
              known.timeIntervalSince(motionSince) >= Self.motionHold,
              endedAt.map({ motionSince >= $0 }) ?? true else { return [] }
        if let lastSpeed, lastSpeed.at >= motionSince, Self.isWalkingPace(lastSpeed.metresPerSecond) { return [] }
        return startDrive(at: motionSince)
    }

    /// Follows a drive's good readings (`speed` is nil for any other): faster than walking holds it, and so does
    /// one ``parkRadius`` from where the car last moved (a crawl through a jam); walking pace long and far enough
    /// ends it on foot, unless Motion said car meanwhile (stop-and-go traffic).
    private mutating func followDrive(_ fix: WorldFix, speed: Double?) -> [WorldRideEvent] {
        guard let speed else { return [] }
        if speed > Self.walkingSpeed {
            noteMoving(fix)
            footSince = nil
            footAt = nil
            footFrom = nil
            return []
        }
        if let movingFrom, Self.metres(from: movingFrom, to: fix) > Self.parkRadius { noteMoving(fix) }
        guard speed >= Self.footSpeed else { return [] }
        if footSince == nil {
            footSince = fix.at
            footFrom = Self.anchor(fix)
        }
        footAt = fix.at
        guard let footSince, let footFrom else { return [] }
        let span = fix.at.timeIntervalSince(footSince)
        guard span >= Self.footTime else { return [] }
        let moved = Self.metres(from: footFrom, to: fix)
        guard moved >= Self.footDistance, moved / span >= Self.footPace else {
            // Too slow for a walk (a queue creeping up to a light, GPS drift while stopped): the run starts again here.
            self.footSince = fix.at
            self.footFrom = Self.anchor(fix)
            return []
        }
        guard !(usesMotion && automotive(since: footSince)) else { return [] }
        return endDrive(at: fix.at, because: .onFoot)
    }

    /// The car moved at `fix`: the parked clock starts again there.
    private mutating func noteMoving(_ fix: WorldFix) {
        movingAt = fix.at
        movingFrom = Self.anchor(fix)
    }

    /// `fix` as the point a distance is measured from, with its accuracy.
    private static func anchor(_ fix: WorldFix) -> PaceAnchor {
        PaceAnchor(at: fix.at, point: fix.point, accuracy: fix.accuracy)
    }

    /// How far `fix` surely is from `anchor`: the distance beyond both readings' accuracy, in metres (never below 0).
    private static func metres(from anchor: PaceAnchor, to fix: WorldFix) -> Double {
        max(0, anchor.point.distance(to: fix.point) - anchor.accuracy - fix.accuracy)
    }

    private mutating func startDrive(at date: Date) -> [WorldRideEvent] {
        mode = .driving(since: date)
        movingAt = date
        movingFrom = nil
        footSince = nil
        footAt = nil
        footFrom = nil
        fastSince = nil
        fastAt = nil
        return [.driveStarted(date)]
    }

    private mutating func endDrive(at date: Date, because end: WorldDriveEnd) -> [WorldRideEvent] {
        guard isDriving else { return [] }
        mode = .onFoot
        endedAt = date
        lastDrive = DriveEnded(end: end, at: date)
        movingAt = nil
        movingFrom = nil
        footSince = nil
        footAt = nil
        footFrom = nil
        fastSince = nil
        fastAt = nil
        return [.driveEnded(date)]
    }

    /// Whether, as of `date`, the car has been parked long enough: nothing faster than walking, nor ``parkRadius``
    /// from where it last moved, for ``parkTime`` and, with Motion, no automotive activity in that time.
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
            return isParked(at: date) ? endDrive(at: date, because: .parked) : []
        case .cycling(let since):
            guard motionKind != .cycling, let motionSince, date.timeIntervalSince(motionSince) >= Self.rideGap else {
                return []
            }
            return endRide(started: since, ended: motionSince)
        }
    }

    /// Takes one confident sample: the activity in effect from its moment, and what it starts or ends (an
    /// automotive sample only marks when the car began; ``startByMotion(knownThrough:)`` starts the drive).
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
            // The ride ends at once; the drive waits for ``motionHold`` (``startByMotion(knownThrough:)``).
            return endRide(started: since, ended: at)
        case (.cycling, .driving):
            return endDrive(at: at, because: .cycling) + startRide(at: at)
        case (.cycling, .onFoot) where fresh:
            return startRide(at: at)
        case (.walking, .driving(let since)), (.running, .driving(let since)):
            return at > since ? endDrive(at: at, because: .onFoot) : []
        default:
            return []
        }
    }

    private mutating func startRide(at date: Date) -> [WorldRideEvent] {
        mode = .cycling(since: date)
        fastSince = nil
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

    /// The pace from the pace anchor to `fix`, in metres a second; `beyondAccuracy`, only the distance beyond
    /// both readings' accuracy counts (a jump inside them is no move). Nil when `fix` is not good, sooner than
    /// ``minPaceTime`` after the anchor, or across a gap too long to say.
    private func pace(to fix: WorldFix, beyondAccuracy: Bool = false) -> Double? {
        guard Self.isGood(fix), let paceFrom else { return nil }
        let seconds = fix.at.timeIntervalSince(paceFrom.at)
        guard seconds >= Self.minPaceTime, seconds <= Self.maxGap else { return nil }
        let slack = beyondAccuracy ? paceFrom.accuracy + fix.accuracy : 0
        return max(0, paceFrom.point.distance(to: fix.point) - slack) / seconds
    }

    /// Moves the pace anchor to a good reading at least ``minPaceTime`` after the last one.
    private mutating func notePaceAnchor(_ fix: WorldFix) {
        guard Self.isGood(fix) else { return }
        if let paceFrom, fix.at.timeIntervalSince(paceFrom.at) < Self.minPaceTime { return }
        paceFrom = PaceAnchor(at: fix.at, point: fix.point, accuracy: fix.accuracy)
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

    /// Keeps a good reading within ``lineAccuracy`` on the line when it is at least ``lineStep`` from the last kept point, dropping
    /// points no ride can need (older than ``markLookBack`` while not cycling, or past ``maxLinePoints``).
    private mutating func noteLine(_ fix: WorldFix) {
        guard fix.accuracy <= Self.lineAccuracy,
              line.last.map({ $0.point.distance(to: fix.point) >= Self.lineStep }) ?? true else { return }
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
