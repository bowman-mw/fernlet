import Foundation
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
import FernletDomainModel
#endif

/// Optional, opt-in weather-aware mood-recovery prompts (spec §12). Requests *coarse* location only
/// when the user enables the feature, fetches current conditions via WeatherKit, and degrades
/// gracefully — returning `nil` on any missing permission, missing entitlement, or network error —
/// so nothing ever blocks or nags.
/// Minimal walk-friendliness snapshot for the gentle short-walk offer: whether conditions are
/// pleasant (clear-ish and mild) and whether it is currently daytime. Deliberately tiny — no raw
/// condition, temperature, or location ever leaves the service.
public struct WeatherComfort: Equatable, Sendable {
    public let isPleasant: Bool
    public let isDaytime: Bool

    public init(isPleasant: Bool, isDaytime: Bool) {
        self.isPleasant = isPleasant
        self.isDaytime = isDaytime
    }
}

@MainActor
public final class WeatherKitService: NSObject, CLLocationManagerDelegate {
    public static let shared = WeatherKitService()

    /// How long one fetched current-weather snapshot is reused before re-querying WeatherKit.
    /// Shared by `moodRecoveryPrompt` and `currentComfort` so a Home appearance costs at most one
    /// location + weather fetch per half hour (previously every appearance refetched).
    public static let cacheInterval: TimeInterval = 30 * 60

    private let locationManager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    #if canImport(WeatherKit)
    /// The cached current-conditions snapshot (only the three fields Fernlet ever reads).
    private struct ConditionsSnapshot {
        let condition: WeatherCondition
        let temperatureCelsius: Double
        let isDaylight: Bool
        let fetchedAt: Date
    }

    private var cachedConditions: ConditionsSnapshot?
    #endif

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
    public func requestAuthorization() async -> Bool {
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
    public func moodRecoveryPrompt() async -> String? {
        #if canImport(WeatherKit)
        guard let conditions = await currentConditions() else { return nil }
        guard Self.gloomyConditions.contains(conditions.condition) else { return nil }
        return "The weather outside is heavy today. Be a little gentler with yourself — a small, warm thing still counts."
        #else
        return nil
        #endif
    }

    /// Whether a short walk would be inviting right now — pleasant conditions + daylight — or `nil`
    /// whenever weather is unavailable (no authorization, no entitlement, network error). Callers
    /// gate on `settings.weatherPromptsEnabled` (same contract as `moodRecoveryPrompt`); a `nil`
    /// simply removes the walk offer, never blocks anything. Served from the shared ≤30-min cache.
    public func currentComfort() async -> WeatherComfort? {
        #if canImport(WeatherKit)
        guard let conditions = await currentConditions() else { return nil }
        return Self.comfort(
            condition: conditions.condition,
            temperatureCelsius: conditions.temperatureCelsius,
            isDaylight: conditions.isDaylight
        )
        #else
        return nil
        #endif
    }

    #if canImport(WeatherKit)
    /// Pure walk-friendliness classification, split out so tests can pin the thresholds.
    /// "Pleasant" = clear-ish sky AND a mild temperature; daytime comes straight from WeatherKit.
    public static func comfort(condition: WeatherCondition, temperatureCelsius: Double, isDaylight: Bool) -> WeatherComfort {
        let mild = temperatureCelsius >= 5 && temperatureCelsius <= 32
        return WeatherComfort(
            isPleasant: pleasantConditions.contains(condition) && mild,
            isDaytime: isDaylight
        )
    }

    /// Fetches (or serves from cache) the tiny current-conditions snapshot both prompt APIs read.
    private func currentConditions() async -> ConditionsSnapshot? {
        if let cachedConditions, Date().timeIntervalSince(cachedConditions.fetchedAt) < Self.cacheInterval {
            return cachedConditions
        }
        guard isAuthorized, let location = await currentLocation() else { return nil }
        do {
            let current = try await WeatherService.shared.weather(for: location).currentWeather
            let snapshot = ConditionsSnapshot(
                condition: current.condition,
                temperatureCelsius: current.temperature.converted(to: .celsius).value,
                isDaylight: current.isDaylight,
                fetchedAt: Date()
            )
            cachedConditions = snapshot
            return snapshot
        } catch {
            return nil
        }
    }
    #endif

    private func currentLocation() async -> CLLocation? {
        if let cached = locationManager.location { return cached }
        guard isAuthorized else { return nil }
        return await withCheckedContinuation { continuation in
            locationContinuation = continuation
            locationManager.requestLocation()
        }
    }

    // MARK: - CLLocationManagerDelegate

    nonisolated public func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
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

    nonisolated public func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        Task { @MainActor in
            guard let continuation = locationContinuation else { return }
            locationContinuation = nil
            continuation.resume(returning: locations.last)
        }
    }

    nonisolated public func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
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

    /// Walk-inviting sky states (clear-ish; intentionally NOT the complement of `gloomyConditions`
    /// — hot/windy/hazy days are neither gloomy nor walk-offer material).
    private static let pleasantConditions: Set<WeatherCondition> = [
        .clear, .mostlyClear, .partlyCloudy
    ]
    #endif
}
