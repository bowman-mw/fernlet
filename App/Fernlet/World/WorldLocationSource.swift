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

/// The World map's location, following the permission the person gave (design page answer 3; World
/// app plan step 5a). **The only new file in the app that imports CoreLocation**
/// (`MapAndLocationConfinementBoundaryTests`; the other is `WeatherKitService.swift`).
///
/// - **While Using:** updates run only while Fernlet is open, a panel or sheet over the map or not (W-09 (i),
///   owner 2026-10-26), and stop when the app goes to the background (``startForeground()`` /
///   ``stopForeground()``), every 10 m of movement. Every reading iOS delivers is handed on, in order.
/// - **Always, low power (opt-in, off by default):** iOS's visit and significant-change updates
///   (``setLowPowerAlways(_:)``), which need no `location` background mode and use little battery.
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
/// Every reading goes to ``onFix`` as a ``WorldFix``, and every low-power visit to ``onVisit`` as a
/// ``WorldVisit``; what to do with them (lift the fog, note a stop) is the keepers' call. Delegate
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

    /// Whether a walk is recording (updates keep running off the map).
    private(set) var isWalking = false

    /// Whether the readings now are the map's own: updates running for the map on screen, not for a walk.
    var isFollowingMap: Bool { isUpdating && !isWalking }

    @ObservationIgnored private let manager = CLLocationManager()
    @ObservationIgnored private var isUpdating = false
    @ObservationIgnored private var isMonitoringAlways = false
    @ObservationIgnored private var walkSession: CLBackgroundActivitySession?

    /// The Info.plist purpose key the walk's temporary full-accuracy request names (a frozen token).
    static let walkAccuracyPurposeKey = "WorldWalk"

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 10
        apply(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization, observed: false)
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
        manager.stopUpdatingLocation()
    }

    /// Keeps updates running for a walk the person started, asking for precise location for this walk
    /// when only approximate is allowed, and holding a background session while the app declares one.
    func startWalk() {
        guard permission == .whileUsing || permission == .always, !isWalking else { return }
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
        }
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
        if permission == .denied || permission == .notAsked {
            stopWalk()
            stopForeground()
        }
    }

    /// Hands a reading on, as plain values.
    private func deliver(_ fix: WorldFix) {
        guard fix.point.isValid, fix.accuracy.isFinite, fix.accuracy >= 0 else { return }
        latest = fix
        onFix?(fix)
    }

    /// Hands a low-power visit on, as plain values (a visit with no known time is dropped).
    private func deliverVisit(_ visit: WorldVisit) {
        guard visit.point.isValid, visit.accuracy.isFinite, visit.accuracy >= 0,
              visit.arrived != .distantPast, visit.arrived != .distantFuture else { return }
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
            WorldFix(point: GeoPoint(location.coordinate.latitude, location.coordinate.longitude),
                     accuracy: location.horizontalAccuracy, at: location.timestamp, isPrecise: precise)
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

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to undo: a failed reading is no reading. The map keeps the last one it had.
        FernletAuditLog.log("worldMap.location.failed")
    }
}
