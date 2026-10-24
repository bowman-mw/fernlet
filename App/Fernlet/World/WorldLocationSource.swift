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
/// - **While Using:** updates run only while the map is on screen and the app is active
///   (``startForeground()`` / ``stopForeground()``), every 10 m of movement.
/// - **Always, low power (opt-in, off by default):** iOS's visit and significant-change updates
///   (``setLowPowerAlways(_:)``), which need no `location` background mode and use little battery.
/// - **Asking:** ``requestWhileUsing()`` and ``requestAlways()`` are called only from the approved
///   permission screens (step 5c); nothing here asks on its own.
/// - **A walk** (``startWalk()`` / ``stopWalk()``, plan step 5b): updates keep running while a walk the
///   person started records, even when the map leaves the screen. With approximate location it asks for
///   precise location for this walk only (temporary full accuracy), and it holds a background activity
///   session so a walk with the phone in a pocket keeps its line. Both need their Info.plist half (the
///   temporary-accuracy purpose and the `location` background mode), which arrive with the approved
///   permission strings (step 5c); until then each is skipped, never crashed into.
///
/// Every reading goes to ``onFix`` as a ``WorldFix``; what to do with it (lift the fog or not) is the
/// fog keeper's call. Delegate callbacks arrive off the main actor and hop to it with the values they
/// carry, as `WeatherKitService` does.
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

    /// Whether a walk is recording (updates keep running off the map).
    private(set) var isWalking = false

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
        apply(status: manager.authorizationStatus, accuracy: manager.accuracyAuthorization)
    }

    /// Asks for While Using (the approved permission screen's button).
    func requestWhileUsing() {
        guard permission == .notAsked else { return }
        manager.requestWhenInUseAuthorization()
    }

    /// Asks to upgrade to Always (Settings → Home map's opt-in, after its explainer).
    func requestAlways() {
        guard permission == .whileUsing else { return }
        manager.requestAlwaysAuthorization()
    }

    /// Starts updates while the map shows; a no-op without permission or when already running.
    func startForeground() {
        guard permission == .whileUsing || permission == .always, !isUpdating else { return }
        isUpdating = true
        manager.startUpdatingLocation()
    }

    /// Stops the map's updates (the map left the screen, or the app went to the background); a walk
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

    /// Records the permission and accuracy CoreLocation reports.
    private func apply(status: CLAuthorizationStatus, accuracy: CLAccuracyAuthorization) {
        permission = Self.permission(for: status)
        isPrecise = accuracy == .fullAccuracy
        guard permission != .always else { return }
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
        guard let last = locations.last else { return }
        let precise = manager.accuracyAuthorization == .fullAccuracy
        let fix = WorldFix(point: GeoPoint(last.coordinate.latitude, last.coordinate.longitude),
                           accuracy: last.horizontalAccuracy, at: last.timestamp, isPrecise: precise)
        Task { @MainActor in self.deliver(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didVisit visit: CLVisit) {
        let precise = manager.accuracyAuthorization == .fullAccuracy
        let fix = WorldFix(point: GeoPoint(visit.coordinate.latitude, visit.coordinate.longitude),
                           accuracy: visit.horizontalAccuracy, at: visit.arrivalDate, isPrecise: precise)
        Task { @MainActor in self.deliver(fix) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Nothing to undo: a failed reading is no reading. The map keeps the last one it had.
        FernletAuditLog.log("worldMap.location.failed")
    }
}
