import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
#endif

/// Optional, opt-in weather-aware mood-recovery prompts (spec §12). Requests *coarse* location only
/// when the user enables the feature, fetches current conditions via WeatherKit, and degrades
/// gracefully — returning `nil` on any missing permission, missing entitlement, or network error —
/// so nothing ever blocks or nags.
@MainActor
final class WeatherKitService: NSObject, CLLocationManagerDelegate {
    static let shared = WeatherKitService()

    private let locationManager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    var isAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// Requests when-in-use authorization. Returns whether it ended up granted.
    func requestAuthorization() async -> Bool {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .denied, .restricted: return false
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                authContinuation = continuation
                locationManager.requestWhenInUseAuthorization()
            }
        @unknown default:
            return false
        }
    }

    /// A gentle recovery prompt when conditions are heavy/gloomy, or `nil` when unavailable or fine.
    func moodRecoveryPrompt() async -> String? {
        #if canImport(WeatherKit)
        guard isAuthorized, let location = await currentLocation() else { return nil }
        do {
            let weather = try await WeatherService.shared.weather(for: location)
            guard Self.gloomyConditions.contains(weather.currentWeather.condition) else { return nil }
            return "The weather outside is heavy today. Be a little gentler with yourself — a small, warm thing still counts."
        } catch {
            return nil
        }
        #else
        return nil
        #endif
    }

    private func currentLocation() async -> CLLocation? {
        if let cached = locationManager.location { return cached }
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            guard let continuation = authContinuation else { return }
            switch status {
            case .notDetermined:
                return // wait for a terminal decision
            case .authorizedWhenInUse, .authorizedAlways:
                authContinuation = nil
                continuation.resume(returning: true)
            default:
                authContinuation = nil
                continuation.resume(returning: false)
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let continuation = locationContinuation else { return }
            locationContinuation = nil
            continuation.resume(returning: locations.last)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in
            guard let continuation = locationContinuation else { return }
            locationContinuation = nil
            continuation.resume(returning: nil)
        }
    }

    #if canImport(WeatherKit)
    private static let gloomyConditions: Set<WeatherCondition> = [
        .rain, .heavyRain, .drizzle, .sunShowers, .thunderstorms, .strongStorms,
        .sleet, .snow, .heavySnow, .blizzard, .wintryMix, .foggy, .cloudy
    ]
    #endif
}
