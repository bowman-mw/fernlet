import CoreLocation
import FernletFoundation
import Foundation
import WorldMapStore

/// One location reading for the World map, in plain coordinates: no CoreLocation type leaves this file.
nonisolated struct WorldFix: Equatable, Sendable {
    /// Where.
    let point: GeoPoint
    /// The reading's horizontal accuracy, in metres (smaller is better).
    let accuracy: Double
    /// When it was taken.
    let at: Date
    /// Whether the person allowed precise location (with approximate location iOS hands over a point
    /// somewhere in the area).
    let isPrecise: Bool
    /// CoreLocation's own speed for the reading, in metres a second; nil when it gave none (W-14: the stop
    /// watch tells a car pulling away from a red light from a person who stopped).
    var speed: Double? = nil
    /// CoreLocation's course for the reading, in degrees clockwise from true north; nil when it gave none (the
    /// follow glide carries Sprout on along it between a drive's readings, ``WorldFollowGlide``).
    var course: Double? = nil
    /// Whether car detection says the person is in a car (round 7: Motion's automotive activity, read only
    /// while "Log my bike rides" or background mapping is on, and allowed); nil when Motion is off, and the stop watch then keeps its
    /// speed rule (W-14).
    var inCar: Bool? = nil
    /// Whether the reading is inside the grounds of the airport just landed at (the flight gate): the passport
    /// reads nothing from it, so a country and its continent stamp only once the person leaves (World-Airports-Spec
    /// §4.2, the owner's note on 9).
    var atLandedAirport = false
    /// The reading's altitude above sea level and its accuracy, in metres; nil when CoreLocation gave none (the
    /// flight gate tells a climb-out from a train leaving an airport's station by it).
    var altitude: Double? = nil
    var verticalAccuracy: Double? = nil
}

/// A stop iOS noticed in Always mode's low-power visits, in plain values: where, how sure, and when the
/// person arrived (World build step 5c: background visits fill "Where you've been").
nonisolated struct WorldVisit: Equatable, Sendable {
    /// Where.
    let point: GeoPoint
    /// How sure, in metres.
    let accuracy: Double
    /// When the person arrived.
    let arrived: Date
    /// When the person left, once iOS knows (a visit is delivered again on departure); nil until then.
    /// Read only against the person's homes and hotel (round 6, `ref-home-where`: "you left").
    var departed: Date? = nil
}

/// The person's location answer, as the World map reads it.
nonisolated enum WorldLocationPermission: Equatable, Sendable {
    /// Not asked yet.
    case notAsked
    /// Declined, or restricted on this phone.
    case denied
    /// While Using the App (the default the World map asks for).
    case whileUsing
    /// Always: only for the opt-in low-power mode.
    case always
}

/// What the World map's continuous background updates follow, with Always and background mapping on
/// (round 7): a drive's road (`nf-car`), or a bike ride's line (Refinements group 19, `ref-ride-line`).
nonisolated enum WorldTrace: Equatable, Sendable {
    /// A drive car detection found: traced as a lane of fog 25 m either side of the road.
    case drive
    /// A bike ride Motion found: followed closely for its line, lifting the fog like a walk.
    case ride
}

/// The World map's location, following the permission the person gave (design page answer 3; World
/// app plan step 5a). **The only new file in the app that imports CoreLocation**
/// (`MapAndLocationConfinementBoundaryTests`; the other is `WeatherKitService.swift`).
///
/// - **While Using:** updates run only while Fernlet is open, a panel or sheet over the map or not (W-09 (i),
///   owner 2026-10-26), and stop when the app goes to the background (``startForeground()`` /
///   ``stopForeground()``), every 10 m of movement — every 25 m at ten-metre accuracy while the map is behind
///   a panel, sheet or tab and nothing records (``offMapPace``). Every reading iOS delivers is handed on, in order.
/// - **Always, low power (opt-in, off by default):** iOS's visit and significant-change updates
///   (``setLowPowerAlways(_:)``), which need no `location` background mode and use little battery.
/// - **A drive, traced (round 7; owner 2026-10-26: "For the car it should show where you've been while
///   driving even if it's in the background"):** with Always and background mapping on, a drive that car
///   detection finds (``WorldRideKeeper/onDrivingChanged``) switches to continuous updates that keep running
///   in the background (the `location` background mode, automotive navigation), so the map uncovers the road
///   driven as a lane (`nf-car`, 25 m either side). When the drive ends, exactly what ran before comes back: the
///   low-power mode stays, a walk or the map in front keep their updates, and otherwise the updates stop. This
///   widens the `location` background mode's use beyond a walk the person started; the approved privacy sentence
///   says so ("…and, while you're driving or riding, the road you take"). Never without Always and background
///   mapping, and never during a walk (``tracesDrive(permission:backgroundMapping:declaresBackground:walking:)``).
/// - **Fernlet ends a trace, not iOS (owner 2026-11-09: trips dropping in the background, "really long stop
///   lights"):** iOS never pauses a trace's updates (`pausesLocationUpdatesAutomatically` off while one runs),
///   because paused updates never come back on their own and a long light or a jam looked like a parked car.
///   Car detection's own parked rule ends the drive instead. After a drive that ended on foot, which a light can
///   still fake, the updates keep running for ``traceCoolDown``, so a drive picking up again is traced at once
///   (``coolsDown(after:)``); a parked drive goes straight to the leaving fence.
/// - **The leaving fence (same day):** with Always and background mapping on, whenever continuous updates stop
///   (the app goes to the background, a trace, a walk or a listen ends) and with every low-power reading, iOS is
///   asked to watch a circle round the latest reading (``fenceRadius(afterQuietListens:accuracy:)``, region
///   monitoring, which needs no GPS). Leaving it wakes Fernlet, even after iOS closed it, for a listen: continuous
///   updates for ``listenTime`` so car and bike detection can tell a drive or a ride from a walk, much sooner
///   than iOS's significant-change updates (often half a kilometre and minutes later, too far apart for the speed
///   rule). A drive or ride found takes the updates over; a listen that finds none ends and the next fence is
///   wider (up to ``maxFenceRadius``, so a long walk costs a few short listens), until a trace or a visit resets
///   it. A low-power reading faster than walking starts a listen too
///   (``listens(afterLowPowerSpeed:)``). Background mapping off, Always withdrawn or the delete funnel take the
///   fence down (``removeLeavingFence()``).
/// - **Car signals (owner 2026-11-09):** ``cars`` reads the audio route with every reading and on each route change;
///   CarPlay or a car the car book knows connected holds a drive and shortens its start (`WorldRideKeeper.carLinked`),
///   and connecting while the app runs in the background starts a listen. Driving Focus's "Map my drive" filter and the
///   Start a drive / End a drive actions reach ``hintDrive(_:now:)``: a hint shortens the start for ``hintLife`` and
///   listens ``hintListenTime``; its end ends a quiet drive.
/// - **A bike ride, followed closely (Refinements group 19, `ref-ride-line`, owner-approved 2026-10-29):**
///   exactly as a drive is traced, under the same conditions
///   (``followsRide(permission:backgroundMapping:declaresBackground:walking:)``), a ride car and bike
///   detection finds (``WorldRideKeeper/onCyclingChanged``) gets continuous background updates for the
///   `fitness` activity, so its line is drawn without cutting corners; the blue pill shows while it runs. It
///   stops when the ride ends, or at once when background mapping goes off.
/// - **Asking:** ``requestWhileUsing()`` and ``requestAlways()`` are called only from the approved
///   permission screens (step 5c: the map intro's Turn on location, and Settings → Home map's background
///   mapping after its explainer); nothing here asks on its own.
/// - **A walk or run** (``startWalk()`` / ``stopWalk()``, plan step 5b): updates keep running while a walk
///   or run the person started records, even when the map leaves the screen. With approximate location it
///   asks for precise location for this walk only (temporary full accuracy, purpose `WorldWalk`), and it
///   holds a background activity session (the `location` background mode) so a walk with the phone in a
///   pocket keeps its line. Both Info.plist halves ship with the approved strings (step 5c); a build
///   without one skips it, never crashes into it.
/// - **Background mapping on** (``WorldMapPreferences/alwaysLowPower(in:)``) arms the low-power mode as soon
///   as Always is allowed, including when iOS relaunches the app for a visit (the store builds this source at
///   launch when the switch is on, W-09 B1). Allowing Always later, in iOS's Settings, turns the switch on
///   (``turnsOnBackgroundMapping(from:to:)``).
///
/// Every reading goes first to the flight gate (``flights``: nothing flown over goes further), then to car and
/// bike detection (``rides``), then to ``onFix`` as a ``WorldFix``
/// carrying its in-car answer, and every low-power visit to ``onVisit`` as a ``WorldVisit``; what to do with
/// them (lift the fog, note a stop) is the keepers' call. Delegate
/// callbacks arrive off the main actor and hop to it with the values they carry, as `WeatherKitService` does.
@MainActor
@Observable
final class WorldLocationSource: NSObject {
    /// The person's current answer.
    private(set) var permission: WorldLocationPermission = .notAsked
    /// Whether precise location is allowed.
    private(set) var isPrecise = false
    /// The latest reading this session.
    private(set) var latest: WorldFix?
    /// Called with every reading.
    @ObservationIgnored var onFix: ((WorldFix) -> Void)?
    /// Called with every low-power visit (Always mode).
    @ObservationIgnored var onVisit: ((WorldVisit) -> Void)?

    /// Car and bike detection (round 7), fed every reading this source hands on.
    let rides = WorldRideKeeper()
    /// The flight gate (World-Airports-Spec §6.1): weighs every reading first, and none it refuses goes further.
    let flights = WorldFlightKeeper()
    /// The connected car (owner 2026-11-09, car signals): CarPlay or a car the car book knows, read with every reading.
    let cars = WorldCarKeeper()

    /// How long a hint (Driving Focus on, the Start a drive action) primes a drive's start.
    nonisolated static let hintLife: TimeInterval = 30 * 60
    /// How long the listen a hint starts runs: the drive usually starts within a few minutes of the Focus turning on.
    nonisolated static let hintListenTime: TimeInterval = 5 * 60

    /// Whether a walk is recording (updates keep running off the map).
    private(set) var isWalking = false

    /// What continuous background updates follow now, if anything: a drive or a bike ride (round 7).
    private(set) var trace: WorldTrace?

    /// Whether a drive is being traced: continuous updates that keep running in the background (round 7).
    var isTracingDrive: Bool { trace == .drive }

    /// Whether a bike ride is being followed closely, the same way (Refinements group 19, `ref-ride-line`).
    var isFollowingRide: Bool { trace == .ride }

    /// Whether the readings now are the map's own: updates running for the map on screen, not for a walk.
    var isFollowingMap: Bool { isUpdating && !isWalking }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var isUpdating = false
    @ObservationIgnored private var isMonitoringAlways = false
    @ObservationIgnored private var walkSession: CLBackgroundActivitySession?
    /// What the manager was set to before a drive's trace or a ride's follow, put back when it ends.
    @ObservationIgnored private var beforeTrace: (activity: CLActivityType, pauses: Bool)?
    /// Whether Home's map is the front page (``setMapOnScreen(_:)``); behind, readings come at ``offMapPace``.
    @ObservationIgnored private var mapOnScreen = true
    /// Whether car and bike detection says a drive or a ride is under way.
    @ObservationIgnored private var riding = (driving: false, cycling: false)
    /// The trace's cool-down after a drive that ended on foot: when it fires with no drive or ride on, the trace ends.
    @ObservationIgnored private var coolDown: Task<Void, Never>?
    /// The listen after leaving the fence: when it fires with no drive or ride found, the updates stop.
    @ObservationIgnored private var listening: Task<Void, Never>?
    /// Listens in a row that found no drive or ride (each widens the next fence), at most ``maxQuietListens``.
    @ObservationIgnored private var quietListens = 0

    /// Whether a listen is running: continuous updates after the person left the leaving fence.
    var isListening: Bool { listening != nil }

    /// Whether a trace's cool-down is running: a drive ended on foot and the updates still run a while.
    var isCoolingDown: Bool { coolDown != nil }

    /// How long a trace's updates keep running after a drive that ended on foot (owner 2026-11-09).
    nonisolated static let traceCoolDown: TimeInterval = 3 * 60
    /// How long a listen runs after the person leaves the fence: long enough for the speed rule's half minute
    /// at a car's speed, or a motion query, once the car is out of the driveway.
    nonisolated static let listenTime: TimeInterval = 2 * 60
    /// The leaving fence's region identifier (a frozen token: iOS keeps the region under it across launches).
    nonisolated static let fenceIdentifier = "WorldLeaving"
    /// The leaving fence's radius after a trace or a visit, before the reading's accuracy is added, in metres
    /// (about the smallest circle iOS watches well).
    nonisolated static let fenceRadius = 150.0
    /// The widest leaving fence, accuracy included, in metres.
    nonisolated static let maxFenceRadius = 1_000.0
    /// The most quiet listens that widen the fence (150, 300, 600, then 1 000 m).
    nonisolated static let maxQuietListens = 3
    /// The worst accuracy a reading may have to place the fence, in metres.
    nonisolated static let fenceMaxAccuracy = 200.0

    /// How readings come while the map is in front, or a walk, drive or ride records: iOS's best, every 10 m.
    nonisolated static let fullPace = (accuracy: kCLLocationAccuracyBest, distanceFilter: 10.0)
    /// How readings come with the map behind a panel, sheet or tab and nothing recording (owner 2026-10-31,
    /// perf review): every 25 m at iOS's ten-metre accuracy. Unlocking is unchanged: a reading lifts every hex
    /// within ``WorldFogKeeper/liftRadius`` (50 m), so lifts 25 m apart overlap with no gap, and ten-metre
    /// readings sit far inside the fog's and ride detection's 65 m limit. Never iOS's hundred-metre mode,
    /// whose readings often miss that limit and would quietly stop the map uncovering.
    nonisolated static let offMapPace = (accuracy: kCLLocationAccuracyNearestTenMeters, distanceFilter: 25.0)

    /// The Info.plist purpose key the walk's temporary full-accuracy request names (a frozen token).
    static let walkAccuracyPurposeKey = "WorldWalk"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = Self.fullPace.accuracy
        manager.distanceFilter = Self.fullPace.distanceFilter
        apply(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization, observed: false)
        rides.onDrivingChanged = { [weak self] driving in
            self?.riding.driving = driving
            if driving { self?.startTrace(.drive) } else { self?.endTrace(.drive) }
            self?.applyPace()
        }
        rides.onCyclingChanged = { [weak self] cycling in
            self?.riding.cycling = cycling
            if cycling { self?.startTrace(.ride) } else { self?.endTrace(.ride) }
            self?.applyPace()
        }
        rides.carLinked = cars.isLinked
        cars.onLinkChanged = { [weak self] linked in self?.carLinkChanged(linked) }
    }

    /// A car connected or went (CarPlay, or a car the car book knows): car detection hears it, and a car connecting
    /// while the app runs in the background with nothing continuous on starts a listen.
    private func carLinkChanged(_ linked: Bool) {
        rides.carLinked = linked
        if linked { startListening() }
    }

    /// Driving Focus turned on or off, or the Start a drive or End a drive action ran (owner 2026-11-09, car signals).
    /// On primes a drive's start for ``hintLife`` and, with Always and background mapping on, starts a listen of
    /// ``hintListenTime``; off ends a quiet drive.
    func hintDrive(_ on: Bool, now: Date = Date()) {
        guard on else {
            rides.endHint(at: now)
            return
        }
        rides.hint(until: now.addingTimeInterval(Self.hintLife))
        startListening(for: Self.hintListenTime)
    }

    /// The cool-down and the listen end with the source (the memory wall's ML1); both capture it weakly, so this
    /// only stops a sleeping task outliving it.
    isolated deinit {
        coolDown?.cancel()
        listening?.cancel()
    }

    /// Home's map came to the front or went behind a panel, a sheet or another tab.
    func setMapOnScreen(_ onScreen: Bool) {
        guard onScreen != mapOnScreen else { return }
        mapOnScreen = onScreen
        applyPace()
    }

    /// The pace readings come at: ``fullPace`` while the map is in front or a walk, a drive or a ride records
    /// (their lines keep only readings within 25 m), ``offMapPace`` otherwise.
    nonisolated static func pace(mapOnScreen: Bool, recording: Bool) -> (accuracy: CLLocationAccuracy, distanceFilter: CLLocationDistance) {
        mapOnScreen || recording ? fullPace : offMapPace
    }

    /// Sets the manager to ``pace(mapOnScreen:recording:)`` now, touching only what changed.
    private func applyPace() {
        let recording = isWalking || trace != nil || riding.driving || riding.cycling || listening != nil
        let pace = Self.pace(mapOnScreen: mapOnScreen, recording: recording)
        if manager.desiredAccuracy != pace.accuracy { manager.desiredAccuracy = pace.accuracy }
        if manager.distanceFilter != pace.distanceFilter { manager.distanceFilter = pace.distanceFilter }
    }

    /// Whether iOS's location prompt is up: asked for, not answered yet (the companion hint waits for it).
    private(set) var isAsking = false

    /// Asks for While Using (the approved permission screen's button).
    func requestWhileUsing() {
        guard permission == .notAsked else { return }
        isAsking = true
        manager.requestWhenInUseAuthorization()
    }

    /// Asks to upgrade to Always (Settings → Home map's opt-in, after its explainer).
    func requestAlways() {
        guard permission == .whileUsing else { return }
        manager.requestAlwaysAuthorization()
    }

    /// Starts updates while Fernlet is open; a no-op without permission or when already running.
    func startForeground() {
        guard permission == .whileUsing || permission == .always, !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    /// Stops the map's updates (the app went to the background) and arms the leaving fence where the person is;
    /// a walk keeps them running until it ends.
    func stopForeground() {
        guard isUpdating, !isWalking else { return }
        isUpdating = false
        // A drive's trace (or a ride's follow), or a listen, keeps the updates running in the background until it ends.
        guard trace == nil, listening == nil else { return }
        manager.stopUpdatingLocation()
        armFence()
    }

    /// Keeps updates running for a walk the person started, asking for precise location for this walk
    /// when only approximate is allowed, and holding a background session while the app declares one.
    func startWalk() {
        guard permission == .whileUsing || permission == .always, !isWalking else { return }
        // The walk's own mode, untouched by a drive or a ride: a trace or follow running ends first (a reading
        // in a car or on a bike picks it up again once the walk is over).
        stopTrace()
        isWalking = true
        applyPace()
        startForeground()
        if !isPrecise, Self.declares("NSLocationTemporaryUsageDescriptionDictionary") {
            manager.requestTemporaryFullAccuracyAuthorization(withPurposeKey: Self.walkAccuracyPurposeKey)
        }
        if Self.declaresBackgroundLocation {
            walkSession = CLBackgroundActivitySession()
            manager.allowsBackgroundLocationUpdates = true
        }
    }

    /// Ends the walk's hold on updates: the background session goes, and updates stop unless the map
    /// is still on screen (the map restarts them when it next comes to the front).
    func stopWalk() {
        guard isWalking else { return }
        isWalking = false
        applyPace()
        walkSession?.invalidate()
        walkSession = nil
        if Self.declaresBackgroundLocation { manager.allowsBackgroundLocationUpdates = false }
        stopForeground()
    }

    /// Whether the app's Info.plist has `key` (an undeclared feature is skipped, never crashed into).
    nonisolated static func declares(_ key: String) -> Bool {
        Bundle.main.object(forInfoDictionaryKey: key) != nil
    }

    /// Whether the app declares the `location` background mode (setting background updates without it
    /// traps).
    nonisolated static var declaresBackgroundLocation: Bool {
        (Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String])?.contains("location") == true
    }

    /// Turns the low-power Always mode on or off; on needs the Always permission. Off always takes the leaving
    /// fence down, even when the mode wasn't running (iOS keeps a fence across launches).
    func setLowPowerAlways(_ on: Bool) {
        if !on { removeLeavingFence() }
        guard on != isMonitoringAlways else { return }
        guard !on || permission == .always else { return }
        isMonitoringAlways = on
        if on {
            manager.startMonitoringVisits()
            manager.startMonitoringSignificantLocationChanges()
        } else {
            manager.stopMonitoringVisits()
            manager.stopMonitoringSignificantLocationChanges()
            stopTrace()
        }
    }

    /// Whether a drive is traced with continuous background updates: only with Always, background mapping on
    /// and the `location` background mode declared (setting background updates without it traps), and never
    /// while a walk records (its own mode stays exactly as it is).
    nonisolated static func tracesDrive(permission: WorldLocationPermission, backgroundMapping: Bool,
                                        declaresBackground: Bool, walking: Bool) -> Bool {
        permission == .always && backgroundMapping && declaresBackground && !walking
    }

    /// Whether a detected bike ride is followed closely (Refinements group 19, `ref-ride-line`): exactly as a
    /// drive is traced (``tracesDrive(permission:backgroundMapping:declaresBackground:walking:)``), with
    /// Always, background mapping on, the `location` background mode declared, and no walk recording.
    nonisolated static func followsRide(permission: WorldLocationPermission, backgroundMapping: Bool,
                                        declaresBackground: Bool, walking: Bool) -> Bool {
        tracesDrive(permission: permission, backgroundMapping: backgroundMapping, declaresBackground: declaresBackground,
                    walking: walking)
    }

    /// The activity iOS is told the updates are for: automotive navigation for a drive, fitness for a bike ride
    /// (Apple's type for walking, running and cycling, so iOS keeps the readings close to the path). Neither is
    /// paused by iOS: Fernlet's own rules end them.
    nonisolated static func activityType(for trace: WorldTrace) -> CLActivityType {
        switch trace {
        case .drive: .automotiveNavigation
        case .ride: .fitness
        }
    }

    /// Whether a drive that ended this way keeps its trace's updates running for ``traceCoolDown``: only one that
    /// ended on foot, which a long red light can still fake. A parked one goes straight to the leaving fence, one
    /// that became a bike ride hands over, and a flight ends everything.
    nonisolated static func coolsDown(after end: WorldDriveEnd?) -> Bool {
        end == .onFoot
    }

    /// Starts tracing a drive, or following a bike ride, when
    /// ``tracesDrive(permission:backgroundMapping:declaresBackground:walking:)`` allows; when it is already
    /// followed, only the cool-down ends (the drive picked up again). A drive becoming a ride (or back) hands the
    /// updates over, and a listen running ends, since the trace takes its updates over. iOS's blue location pill
    /// shows while either runs (owner 2026-10-29), so the person can see the road or the ride is being noted.
    private func startTrace(_ kind: WorldTrace) {
        guard trace != kind else {
            endCoolDown()
            return
        }
        guard Self.tracesDrive(permission: permission, backgroundMapping: WorldMapPreferences.alwaysLowPower(),
                               declaresBackground: Self.declaresBackgroundLocation, walking: isWalking) else { return }
        endCoolDown()
        endListening()
        quietListens = 0
        if trace != nil { stopTrace(thenFence: false) }
        trace = kind
        applyPace()
        beforeTrace = (manager.activityType, manager.pausesLocationUpdatesAutomatically)
        manager.allowsBackgroundLocationUpdates = true
        manager.activityType = Self.activityType(for: kind)
        manager.pausesLocationUpdatesAutomatically = false
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    /// Car or bike detection says the drive or the ride ended: the trace of that `kind` ends, at once or, after a
    /// drive that ended on foot (``coolsDown(after:)``), once ``traceCoolDown`` passes with no drive or ride on.
    private func endTrace(_ kind: WorldTrace) {
        guard trace == kind else { return }
        guard kind == .drive, Self.coolsDown(after: rides.lastDriveEnd) else {
            stopTrace(kind)
            return
        }
        endCoolDown()
        coolDown = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(WorldLocationSource.traceCoolDown))
            } catch {
                return
            }
            self?.coolDownOver()
        }
    }

    /// The cool-down ran out: the trace ends unless a drive or a ride is on again.
    private func coolDownOver() {
        coolDown = nil
        guard !rides.isDriving, !rides.isCycling else { return }
        stopTrace()
    }

    /// Cancels a running cool-down (the drive picked up again, or the trace ends another way).
    private func endCoolDown() {
        coolDown?.cancel()
        coolDown = nil
    }

    /// Ends a drive's trace or a ride's follow (only that `kind`'s, when given) and puts back exactly what
    /// ran before: the map in front or a walk keep their updates (started again), otherwise the updates stop,
    /// background updates go back off and, `thenFence`, the leaving fence is armed where the trace ended. The
    /// low-power mode is never touched. A no-op when nothing (or another kind) is followed.
    private func stopTrace(_ kind: WorldTrace? = nil, thenFence: Bool = true) {
        guard let trace, kind.map({ $0 == trace }) ?? true else { return }
        self.trace = nil
        endCoolDown()
        applyPace()
        if let beforeTrace {
            manager.activityType = beforeTrace.activity
            manager.pausesLocationUpdatesAutomatically = beforeTrace.pauses
        }
        beforeTrace = nil
        manager.showsBackgroundLocationIndicator = false
        if isUpdating { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
        if walkSession == nil { manager.allowsBackgroundLocationUpdates = false }
        if thenFence, !isUpdating, !isWalking { armFence() }
    }

    // MARK: The leaving fence (owner 2026-11-09)

    /// Whether the leaving fence may be armed: only with Always and background mapping on, where iOS can watch a
    /// region at all.
    nonisolated static func armsFence(permission: WorldLocationPermission, backgroundMapping: Bool,
                                      monitoringAvailable: Bool) -> Bool {
        permission == .always && backgroundMapping && monitoringAvailable
    }

    /// The leaving fence's radius round a reading of `accuracy` after `quiet` listens in a row that found no drive or
    /// ride: ``fenceRadius`` doubled for each (at most ``maxQuietListens``), plus the accuracy, at most
    /// ``maxFenceRadius``. Nil for a reading too rough to place it (worse than ``fenceMaxAccuracy``).
    nonisolated static func fenceRadius(afterQuietListens quiet: Int, accuracy: Double) -> Double? {
        guard accuracy.isFinite, accuracy >= 0, accuracy <= fenceMaxAccuracy else { return nil }
        let doublings = max(0, min(quiet, maxQuietListens))
        return min(maxFenceRadius, fenceRadius * Double(1 << doublings) + accuracy)
    }

    /// Whether a low-power reading (a significant change, with nothing continuous running) starts a listen: only
    /// one whose own speed is faster than walking, so the person is likely in a car or on a bike already.
    nonisolated static func listens(afterLowPowerSpeed speed: Double?) -> Bool {
        guard let speed else { return false }
        return speed > WorldRideWatch.walkingSpeed
    }

    /// Asks iOS to watch a circle round `fix` (the latest reading when nil), replacing the last fence: leaving it
    /// starts a listen. A no-op when ``armsFence(permission:backgroundMapping:monitoringAvailable:)`` refuses or the
    /// reading is too rough.
    private func armFence(at fix: WorldFix? = nil) {
        guard let fix = fix ?? latest,
              Self.armsFence(permission: permission, backgroundMapping: WorldMapPreferences.alwaysLowPower(),
                             monitoringAvailable: CLLocationManager.isMonitoringAvailable(for: CLCircularRegion.self)),
              let radius = Self.fenceRadius(afterQuietListens: quietListens, accuracy: fix.accuracy) else { return }
        let centre = CLLocationCoordinate2D(latitude: fix.point.latitude, longitude: fix.point.longitude)
        let region = CLCircularRegion(center: centre, radius: min(radius, manager.maximumRegionMonitoringDistance),
                                      identifier: Self.fenceIdentifier)
        region.notifyOnEntry = false
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
    }

    /// Takes the leaving fence down and ends a listen (background mapping off, Always withdrawn, the delete funnel).
    func removeLeavingFence() {
        // Bounded: iOS lets an app watch at most twenty regions.
        for region in manager.monitoredRegions where region.identifier == Self.fenceIdentifier {
            manager.stopMonitoring(for: region)
        }
        guard listening != nil else { return }
        endListening()
        applyPace()
        guard trace == nil else { return }
        if walkSession == nil { manager.allowsBackgroundLocationUpdates = false }
        if !isUpdating, !isWalking { manager.stopUpdatingLocation() }
    }

    /// The person left the fence (or a car connected, or a hint came): continuous updates for `duration`
    /// (``listenTime`` by default), unless updates already run (the map in front, a walk, a trace) or a listen is
    /// on, or the fence is no longer allowed.
    fileprivate func startListening(for duration: TimeInterval = WorldLocationSource.listenTime) {
        guard listening == nil, trace == nil, !isUpdating, !isWalking, Self.declaresBackgroundLocation,
              Self.armsFence(permission: permission, backgroundMapping: WorldMapPreferences.alwaysLowPower(),
                             monitoringAvailable: true) else { return }
        manager.allowsBackgroundLocationUpdates = true
        listening = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(duration))
            } catch {
                return
            }
            self?.listenOver()
        }
        applyPace()
        manager.startUpdatingLocation()
    }

    /// A listen ran out with no drive or ride found (a trace ends it first): the updates stop unless the map or a
    /// walk keeps them, and the next, wider fence is armed where the person is now.
    private func listenOver() {
        listening = nil
        quietListens = min(quietListens + 1, Self.maxQuietListens)
        applyPace()
        guard trace == nil else { return }
        if walkSession == nil { manager.allowsBackgroundLocationUpdates = false }
        guard !isUpdating, !isWalking else { return }
        manager.stopUpdatingLocation()
        armFence()
    }

    /// Cancels a running listen, leaving the updates to whoever takes them over.
    private func endListening() {
        listening?.cancel()
        listening = nil
    }

    /// Whether a change of answer CoreLocation reported while running turns background mapping's switch on
    /// (W-09): Always newly allowed, in iOS's upgrade prompt or later in iOS's Settings. The answer read when
    /// the source is built is not a change, so a switch the person turned off stays off.
    nonisolated static func turnsOnBackgroundMapping(from old: WorldLocationPermission, to new: WorldLocationPermission) -> Bool {
        old != .always && new == .always
    }

    /// Records the permission and accuracy CoreLocation reports; `observed` when it is a change reported
    /// while running (not the answer read at start).
    private func apply(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization, observed: Bool = true) {
        let old = permission
        permission = Self.permission(for: status)
        isPrecise = accuracy == .fullAccuracy
        if observed, Self.turnsOnBackgroundMapping(from: old, to: permission) { WorldMapPreferences.setAlwaysLowPower(true) }
        if permission != .notAsked { isAsking = false }
        guard permission != .always else {
            // Background mapping, when the person turned it on, runs as soon as Always is allowed.
            if WorldMapPreferences.alwaysLowPower() { setLowPowerAlways(true) }
            return
        }
        setLowPowerAlways(false)
        stopTrace()
        if permission == .denied || permission == .notAsked {
            stopWalk()
            stopForeground()
        }
    }

    /// Hands a reading on, as plain values: the flight gate weighs it first, and a reading it refuses (in the air,
    /// or maybe climbing out) goes nowhere, not even to ``latest`` (Home keeps the last place on the ground), and
    /// ends any drive or ride once a flight is under way. Then car and bike detection hears it, so the reading
    /// handed to ``onFix`` carries its in-car answer (round 7), and a drive still on picks its trace up again
    /// after iOS paused it. A low-power reading (nothing continuous was running) moves the leaving fence to it,
    /// and starts a listen when it was faster than walking (``listens(afterLowPowerSpeed:)``). Internal so tests
    /// can hand readings in; the delegate is the only caller in the app.
    func deliver(_ fix: WorldFix) {
        guard fix.point.isValid, fix.accuracy.isFinite, fix.accuracy >= 0 else { return }
        guard flights.admits(fix) else {
            if flights.isFlying { rides.takeOff(at: fix.at) }
            return
        }
        let lowPower = !isUpdating && !isWalking && trace == nil && listening == nil
        // The route with every reading: a suspended app hears no route change, and a car may have connected since.
        cars.refresh()
        rides.handle(fix)
        if rides.isDriving { startTrace(.drive) } else if rides.isCycling { startTrace(.ride) }
        var stamped = fix
        stamped.inCar = rides.inCarFlag
        stamped.atLandedAirport = flights.layoverAirport != nil
        latest = stamped
        onFix?(stamped)
        cars.noteReading(stamped, mode: rides.mode)
        guard lowPower, trace == nil else { return }
        armFence(at: stamped)
        if Self.listens(afterLowPowerSpeed: stamped.speed) { startListening() }
    }

    /// iOS paused the updates (the car or the bike has stood still a while): the end hint, so the trace or
    /// the follow stops; a later reading while the drive or ride lasts (a significant move, or the map in
    /// front) follows it again.
    fileprivate func tracePaused() {
        // A pause is often a parked car or a locked bike: the rides keeper decides first, which may end the
        // drive or the ride, and the follow with it.
        rides.tickNow()
        guard trace != nil else { return }
        stopTrace()
    }

    /// Hands a low-power visit on, as plain values (a visit with no known time is dropped, and so is one that
    /// arrived during a flight). A stop iOS noticed narrows the leaving fence again; one it saw the person leave
    /// within ``departureListenWindow`` starts a listen (``listensAfterVisit(departed:now:)``).
    private func deliverVisit(_ visit: WorldVisit) {
        guard visit.point.isValid, visit.accuracy.isFinite, visit.accuracy >= 0,
              visit.arrived != .distantPast, visit.arrived != .distantFuture,
              !flights.isInFlight(visit.arrived) else { return }
        quietListens = 0
        onVisit?(visit)
        if Self.listensAfterVisit(departed: visit.departed, now: Date()) { startListening() }
    }

    /// How recently a visit's departure must have been for it to start a listen (iOS often reports one late).
    nonisolated static let departureListenWindow: TimeInterval = 10 * 60

    /// Whether a visit iOS saw the person leave at `departed` starts a listen at `now`: only a departure within
    /// ``departureListenWindow`` (an older one is a trip already over, or one the fence caught).
    nonisolated static func listensAfterVisit(departed: Date?, now: Date) -> Bool {
        guard let departed, departed <= now else { return false }
        return now.timeIntervalSince(departed) <= departureListenWindow
    }

    /// The World map's reading of a CoreLocation status.
    nonisolated static func permission(for status: CLAuthorizationStatus) -> WorldLocationPermission {
        switch status {
        case .notDetermined: .notAsked
        case .authorizedWhenInUse: .whileUsing
        case .authorizedAlways: .always
        default: .denied
        }
    }
}

extension WorldLocationSource: CLLocationManagerDelegate {
    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus, accuracy = manager.accuracyAuthorization
        Task { @MainActor in self.apply(status: status, accuracy: accuracy) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        // Every reading, oldest first: iOS batches them (a walk in a pocket, a slow wake), and the fog and the
        // walk's line want each one, not only the last (W-09).
        let fixes = Self.fixes(from: locations, precise: manager.accuracyAuthorization == .fullAccuracy)
        guard !fixes.isEmpty else { return }
        Task { @MainActor in
            for fix in fixes { self.deliver(fix) }
        }
    }

    /// The readings iOS delivered, as plain values in the order delivered (at most ``maxBatch``, the newest).
    nonisolated static func fixes(from locations: [CLLocation], precise: Bool) -> [WorldFix] {
        locations.suffix(maxBatch).map { location in
            // A negative speed is CoreLocation's "unknown".
            WorldFix(point: GeoPoint(location.coordinate.latitude, location.coordinate.longitude),
                     accuracy: location.horizontalAccuracy, at: location.timestamp, isPrecise: precise,
                     speed: location.speed >= 0 ? location.speed : nil,
                     course: location.course >= 0 && location.courseAccuracy >= 0 ? location.course : nil,
                     altitude: location.verticalAccuracy >= 0 ? location.altitude : nil,
                     verticalAccuracy: location.verticalAccuracy >= 0 ? location.verticalAccuracy : nil)
        }
    }

    /// The most readings one delivery hands on (a bound on a batch; iOS's are far smaller).
    nonisolated static let maxBatch = 500

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let precise = manager.accuracyAuthorization == .fullAccuracy
        let point = GeoPoint(visit.coordinate.latitude, visit.coordinate.longitude)
        // iOS marks an unknown arrival with the distant past; such a visit is a departure seen alone.
        let arrived = visit.arrivalDate == .distantPast ? visit.departureDate : visit.arrivalDate
        let fix = WorldFix(point: point, accuracy: visit.horizontalAccuracy, at: arrived, isPrecise: precise)
        let departed = visit.departureDate == .distantFuture ? nil : visit.departureDate
        let stop = WorldVisit(point: point, accuracy: visit.horizontalAccuracy, arrived: arrived, departed: departed)
        Task { @MainActor in
            self.deliver(fix)
            self.deliverVisit(stop)
        }
    }

    nonisolated func locationManagerDidPauseLocationUpdates(_ manager: CLLocationManager) {
        Task { @MainActor in self.tracePaused() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        // The person left the leaving fence (iOS relaunches Fernlet for it when it was closed): listen a while.
        guard region.identifier == Self.fenceIdentifier else { return }
        Task { @MainActor in self.startListening() }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?,
                                     withError error: Error) {
        // Nothing to undo: without the fence, iOS's significant changes and visits still wake the map.
        FernletAuditLog.log("worldMap.location.fenceFailed")
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to undo: a failed reading is no reading. The map keeps the last one it had.
        FernletAuditLog.log("worldMap.location.failed")
    }
}
