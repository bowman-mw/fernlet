import Foundation

/// Car and bike detection on the phone (round 7; `b1-home-car`, `b1-home-bike`): the ``WorldRideWatch``
/// fed with the map's readings and, while "Log my bike rides" is on and Motion & Fitness is allowed, the
/// motion coprocessor's activity (``WorldMotionReading``). Owned by ``WorldLocationSource`` (`rides`), so
/// it hears every reading the map hears; in memory only, nothing on disk.
///
/// - **Home reads** ``isDriving`` (riding along) and ``loggedRide`` (the bike-ride note).
/// - **The location source reads** ``isDriving`` through ``onDrivingChanged`` to trace a drive in the
///   background when background mapping is on.
/// - **The store logs** each finished bike ride through ``onBikeRide`` (`FernletStore+WorldRides`), which
///   also sets ``loggedRide`` for the note.
/// - **Motion is read in order:** while ``usesMotion``, each reading may ask for the samples since the last
///   query ended, at most every ``queryInterval``, one query at a time, never further back than
///   ``maxLookBack``. While a drive or ride is on and the app runs, a bounded loop ticks the watch every
///   ``tickInterval`` so a drive ends when the car is parked and the readings stop.
@MainActor
@Observable
final class WorldRideKeeper {
    /// How the person is moving now.
    private(set) var mode: WorldRideMode = .onFoot
    /// The bike ride just logged, for Home's note; nil once the note has gone.
    var loggedRide: WorldLoggedRide?

    /// Whether the person is driving now (riding along).
    var isDriving: Bool {
        if case .driving = mode { return true }
        return false
    }

    /// Whether the person is on a bike now (a catch-up waits for the live ride).
    var isCycling: Bool {
        if case .cycling = mode { return true }
        return false
    }

    /// Called when a drive starts (true) or ends (false).
    @ObservationIgnored var onDrivingChanged: ((Bool) -> Void)?
    /// Called with each finished bike ride long enough to log.
    @ObservationIgnored var onBikeRide: ((WorldBikeRide) -> Void)?

    @ObservationIgnored private var watch = WorldRideWatch()
    /// Where motion activity comes from (CoreMotion on the phone; a test swaps in a scripted stream with
    /// ``replaceMotion(with:)``).
    @ObservationIgnored private(set) var motion: any WorldMotionReading

    /// The moment the last motion query reached; nil before the first.
    @ObservationIgnored private var queryEnd: Date?
    /// The motion query in flight, if any (tests await it).
    @ObservationIgnored private(set) var motionQuery: Task<Void, Never>?
    /// The tick loop, running while a drive or ride is on.
    @ObservationIgnored private var ticks: Task<Void, Never>?

    /// Motion is asked for at most this often, on readings.
    static let queryInterval: TimeInterval = 30
    /// A query never reaches further back than this (a long night in the background).
    static let maxLookBack: TimeInterval = 6 * 60 * 60
    /// How often the loop ticks while a drive or ride is on.
    static let tickInterval: TimeInterval = 30
    /// The most ticks one loop runs (twelve hours; a bound).
    static let maxTicks = 1_440
    /// The most events one step applies (a bound; one step makes at most a few).
    static let maxEvents = 16

    /// A keeper reading `motion` (CoreMotion on the phone; tests pass a scripted stream).
    init(motion: (any WorldMotionReading)? = nil) {
        self.motion = motion ?? WorldMotionSource()
    }

    /// Whether motion samples are read (the store sets it: "Log my bike rides" on and Motion allowed, no
    /// decoy). Off, the keeper decides by speed alone and never sees a bike; a ride on ends unlogged.
    var usesMotion = false {
        didSet {
            guard usesMotion != oldValue else { return }
            watch.usesMotion = usesMotion
            queryEnd = nil
            apply([])
        }
    }

    /// What the stop watch is told about the car (``WorldFix/inCar``): nil without motion, else whether the
    /// coprocessor says the person is in a car now.
    var inCarFlag: Bool? {
        guard usesMotion else { return nil }
        return isDriving
    }

    /// Swaps where motion comes from (tests' scripted stream); the next query starts afresh.
    func replaceMotion(with motion: any WorldMotionReading) {
        self.motion = motion
        queryEnd = nil
    }

    /// Takes a location reading from the map's source, and asks for the motion since the last query when
    /// it is due.
    func handle(_ fix: WorldFix) {
        apply(watch.observe(fix))
        readMotion(through: fix.at)
    }

    /// Asks for the motion samples from the last query's end to `end`, when Motion is read, no query is in
    /// flight and the last one is at least ``queryInterval`` old.
    private func readMotion(through end: Date) {
        guard usesMotion, motionQuery == nil else { return }
        let start = max(queryEnd ?? end.addingTimeInterval(-Self.queryInterval), end.addingTimeInterval(-Self.maxLookBack))
        guard end.timeIntervalSince(start) >= Self.queryInterval else { return }
        motionQuery = Task { [weak self] in
            guard let samples = await self?.motion.samples(from: start, to: end) else { return }
            self?.took(samples, through: end)
        }
    }

    /// Feeds a query's samples to the watch (dropped when Motion went off meanwhile).
    private func took(_ samples: [WorldMotionSample], through end: Date) {
        motionQuery = nil
        guard usesMotion else { return }
        queryEnd = end
        apply(watch.observe(samples))
        apply(watch.tick(at: end))
    }

    /// Applies what changed: the mode first, then the drive callback and finished rides, then the tick loop.
    private func apply(_ events: [WorldRideEvent]) {
        if mode != watch.mode { mode = watch.mode }
        for event in events.prefix(Self.maxEvents) {
            switch event {
            case .driveStarted:
                onDrivingChanged?(true)
            case .driveEnded:
                onDrivingChanged?(false)
            case .rideStarted:
                break
            case .rideEnded(let ride):
                onBikeRide?(ride)
            }
        }
        followTicks()
    }

    /// Starts the tick loop when a drive or ride begins and stops it when the person is on foot again.
    private func followTicks() {
        guard mode != .onFoot else {
            ticks?.cancel()
            ticks = nil
            return
        }
        guard ticks == nil else { return }
        ticks = Task { [weak self] in
            for _ in 0..<WorldRideKeeper.maxTicks {
                do {
                    try await Task.sleep(for: .seconds(WorldRideKeeper.tickInterval))
                } catch {
                    return
                }
                guard self?.tickNow() == true else { return }
            }
            self?.ticks = nil
        }
    }

    /// One tick of the loop: the motion since the last query, then the watch as of now. Whether the person
    /// is still driving or cycling.
    private func tickNow() -> Bool {
        let now = Date()
        readMotion(through: now)
        apply(watch.tick(at: now))
        return mode != .onFoot
    }
}
