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
    /// Whether car detection says the person is in a car (round 7: Motion's automotive activity, read only
    /// while "Log my bike rides" is on and allowed); nil when Motion is off, and the stop watch then keeps its
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
///   ``stopForeground()``), every 10 m of movement. Every reading iOS delivers is handed on, in order.
/// - **Always, low power (opt-in, off by default):** iOS's visit and significant-change updates
///   (``setLowPowerAlways(_:)``), which need no `location` background mode and use little battery.
/// - **A drive, traced (round 7; owner 2026-10-26: "For the car it should show where you've been while
///   driving even if it's in the background"):** with Always and background mapping on, a drive that car
///   detection finds (``WorldRideKeeper/onDrivingChanged``) switches to continuous updates that keep running
///   in the background (the `location` background mode, automotive navigation, paused by iOS at a long
///   stop), so the map uncovers the road driven as a lane (`nf-car`, 25 m either side). When the drive ends, or iOS pauses
///   the updates, exactly what ran before comes back: the low-power mode stays, a walk or the map in front
///   keep their updates, and otherwise the updates stop. This widens the `location` background mode's use
///   beyond a walk the person started; the approved privacy sentence says so ("…and, while you're driving or
///   riding, the road you take"). Never without Always and background mapping, and never during a walk
///   (``tracesDrive(permission:backgroundMapping:declaresBackground:walking:)``).
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

    /// The Info.plist purpose key the walk's temporary full-accuracy request names (a frozen token).
    static let walkAccuracyPurposeKey = "WorldWalk"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        apply(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization, observed: false)
        rides.onDrivingChanged = { [weak self] driving in
            if driving { self?.startTrace(.drive) } else { self?.stopTrace(.drive) }
        }
        rides.onCyclingChanged = { [weak self] cycling in
            if cycling { self?.startTrace(.ride) } else { self?.stopTrace(.ride) }
        }
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

    /// Stops the map's updates (the app went to the background); a walk
    /// keeps them running until it ends.
    func stopForeground() {
        guard isUpdating, !isWalking else { return }
        isUpdating = false
        // A drive's trace (or a ride's follow) keeps the updates running in the background until it ends.
        if trace == nil { manager.stopUpdatingLocation() }
    }

    /// Keeps updates running for a walk the person started, asking for precise location for this walk
    /// when only approximate is allowed, and holding a background session while the app declares one.
    func startWalk() {
        guard permission == .whileUsing || permission == .always, !isWalking else { return }
        // The walk's own mode, untouched by a drive or a ride: a trace or follow running ends first (a reading
        // in a car or on a bike picks it up again once the walk is over).
        stopTrace()
        isWalking = true
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

    /// Turns the low-power Always mode on or off; on needs the Always permission.
    func setLowPowerAlways(_ on: Bool) {
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

    /// The activity iOS is told the updates are for: automotive navigation for a drive (paused by iOS at a
    /// long stop), fitness for a bike ride (Apple's type for walking, running and cycling, so iOS keeps the
    /// readings close to the path and pauses only once the person stops moving).
    nonisolated static func activityType(for trace: WorldTrace) -> CLActivityType {
        switch trace {
        case .drive: .automotiveNavigation
        case .ride: .fitness
        }
    }

    /// Starts tracing a drive, or following a bike ride, when
    /// ``tracesDrive(permission:backgroundMapping:declaresBackground:walking:)`` allows; a no-op when it is
    /// already followed. A drive becoming a ride (or back) hands the updates over. iOS's blue location pill
    /// shows while either runs (owner 2026-10-29), so the person can see the road or the ride is being noted.
    private func startTrace(_ kind: WorldTrace) {
        guard trace != kind,
              Self.tracesDrive(permission: permission, backgroundMapping: WorldMapPreferences.alwaysLowPower(),
                               declaresBackground: Self.declaresBackgroundLocation, walking: isWalking) else { return }
        if trace != nil { stopTrace() }
        trace = kind
        beforeTrace = (manager.activityType, manager.pausesLocationUpdatesAutomatically)
        manager.allowsBackgroundLocationUpdates = true
        manager.activityType = Self.activityType(for: kind)
        manager.pausesLocationUpdatesAutomatically = true
        manager.showsBackgroundLocationIndicator = true
        manager.startUpdatingLocation()
    }

    /// Ends a drive's trace or a ride's follow (only that `kind`'s, when given) and puts back exactly what
    /// ran before: the map in front or a walk keep their updates (started again, since iOS's pause stops
    /// them too), otherwise the updates stop and background updates go back off. The low-power mode is never
    /// touched. A no-op when nothing (or another kind) is followed.
    private func stopTrace(_ kind: WorldTrace? = nil) {
        guard let trace, kind.map({ $0 == trace }) ?? true else { return }
        self.trace = nil
        if let beforeTrace {
            manager.activityType = beforeTrace.activity
            manager.pausesLocationUpdatesAutomatically = beforeTrace.pauses
        }
        beforeTrace = nil
        manager.showsBackgroundLocationIndicator = false
        if isUpdating { manager.startUpdatingLocation() } else { manager.stopUpdatingLocation() }
        if walkSession == nil { manager.allowsBackgroundLocationUpdates = false }
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
    /// after iOS paused it. Internal so tests can hand readings in; the delegate is the only caller in the app.
    func deliver(_ fix: WorldFix) {
        guard fix.point.isValid, fix.accuracy.isFinite, fix.accuracy >= 0 else { return }
        guard flights.admits(fix) else {
            if flights.isFlying { rides.takeOff(at: fix.at) }
            return
        }
        rides.handle(fix)
        if rides.isDriving { startTrace(.drive) } else if rides.isCycling { startTrace(.ride) }
        var stamped = fix
        stamped.inCar = rides.inCarFlag
        stamped.atLandedAirport = flights.layoverAirport != nil
        latest = stamped
        onFix?(stamped)
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
    /// arrived during a flight).
    private func deliverVisit(_ visit: WorldVisit) {
        guard visit.point.isValid, visit.accuracy.isFinite, visit.accuracy >= 0,
              visit.arrived != .distantPast, visit.arrived != .distantFuture,
              !flights.isInFlight(visit.arrived) else { return }
        onVisit?(visit)
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to undo: a failed reading is no reading. The map keeps the last one it had.
        FernletAuditLog.log("worldMap.location.failed")
    }
}
