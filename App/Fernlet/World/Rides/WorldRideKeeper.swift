import Foundation

/// Car and bike detection on the phone (round 7; `b1-home-car`, `b1-home-bike`): the ``WorldRideWatch``
/// fed with the map's readings and, while "Log my bike rides" is on and Motion & Fitness is allowed, the
/// motion coprocessor's activity (``WorldMotionReading``). Owned by ``WorldLocationSource`` (`rides`), so
/// it hears every reading the map hears; in memory only.
///
/// - **Home reads** ``isDriving`` (riding along) and ``loggedRide`` (the bike-ride note).
/// - **The location source reads** ``isDriving`` through ``onDrivingChanged`` to trace a drive in the
///   background when background mapping is on.
/// - **The store logs** each finished bike ride through ``onBikeRide`` (`FernletStore+WorldRides`), which
///   also sets ``loggedRide`` for the note.
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

    /// Called when a drive starts (true) or ends (false).
    @ObservationIgnored var onDrivingChanged: ((Bool) -> Void)?
    /// Called with each finished bike ride long enough to log.
    @ObservationIgnored var onBikeRide: ((WorldBikeRide) -> Void)?

    @ObservationIgnored private var watch = WorldRideWatch()
    /// Where motion activity comes from.
    let motion: any WorldMotionReading

    /// A keeper reading `motion` (CoreMotion on the phone; tests pass a scripted stream).
    init(motion: (any WorldMotionReading)? = nil) {
        self.motion = motion ?? WorldMotionSource()
    }

    /// Whether motion samples are read (the store sets it: "Log my bike rides" on and Motion allowed, no
    /// decoy). Off, the keeper decides by speed alone and never sees a bike.
    var usesMotion = false

    /// What the stop watch is told about the car (``WorldFix/inCar``): nil without motion, else whether the
    /// coprocessor says the person is in a car now.
    var inCarFlag: Bool? {
        guard usesMotion else { return nil }
        return isDriving
    }

    /// Takes a location reading from the map's source.
    func handle(_ fix: WorldFix) {
        apply(watch.observe(fix))
    }

    /// Applies what changed: the mode, the drive callback, and finished rides.
    private func apply(_ events: [WorldRideEvent]) {
        for event in events.prefix(Self.maxEvents) {
            switch event {
            case .driveStarted(let at):
                mode = .driving(since: at)
                onDrivingChanged?(true)
            case .driveEnded:
                mode = .onFoot
                onDrivingChanged?(false)
            case .rideStarted(let at):
                mode = .cycling(since: at)
            case .rideEnded(let ride):
                mode = .onFoot
                onBikeRide?(ride)
            }
        }
    }

    /// The most events one step applies (a bound; one step makes at most a few).
    static let maxEvents = 16
}
