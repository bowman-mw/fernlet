import Foundation
import os
import CoreLocation
#if canImport(WeatherKit)
import WeatherKit
import FernletDomainModel
#endif

/// Minimal walk-friendliness snapshot for the gentle short-walk offer: whether conditions are
/// pleasant (clear-ish and mild) and whether it is currently daytime. Deliberately tiny — no raw
/// condition, temperature, or location ever leaves the service.
///
/// Produced by ``WeatherKitService/currentComfort()`` (and the pure
/// ``WeatherKitService/comfort(condition:temperatureCelsius:isDaylight:)`` classifier that tests
/// pin); consumed by the app's gentle-offer surfaces (`AmbientCards`).
public struct WeatherComfort: Equatable, Sendable {
    public let isPleasant: Bool
    public let isDaytime: Bool

    public init(isPleasant: Bool, isDaytime: Bool) {
        self.isPleasant = isPleasant
        self.isDaytime = isDaytime
    }
}

/// Coarse sky bucket for the Home ambience accents behind the companion. Deliberately
/// tiny — the ambience layer only needs "what kind of sky", never a raw condition,
/// temperature, or location.
///
/// Mapped from WeatherKit's `WeatherCondition` by the pure, test-pinned
/// ``WeatherKitService/ambientSky(for:)``; carried to the app's `CompanionAmbienceLayer`
/// inside a ``WeatherAmbient``.
public enum AmbientSky: String, Equatable, Sendable {
    case clear
    case clouds
    case rain
    case snow
}

/// Minimal structured ambience snapshot (sky bucket + day/night) for the Home
/// environment layer. `nil` from ``WeatherKitService/currentAmbient()`` means "weather
/// unknown" — the layer then falls back to its time-of-day tint alone.
///
/// Pairs an ``AmbientSky`` with a daylight flag and nothing else, keeping the ambience
/// surface as privacy-lean as ``WeatherComfort``.
public struct WeatherAmbient: Equatable, Sendable {
    public let sky: AmbientSky
    public let isDaytime: Bool

    public init(sky: AmbientSky, isDaytime: Bool) {
        self.sky = sky
        self.isDaytime = isDaytime
    }
}

/// Optional, opt-in weather-aware prompts and ambience (spec §12). Requests *coarse* location only
/// when the user enables the feature, fetches current conditions via WeatherKit, and degrades
/// gracefully — returning `nil` on any missing permission, missing entitlement, or network error —
/// so nothing ever blocks or nags.
///
/// A `@MainActor` singleton (``shared``) serving three read surfaces off ONE cached conditions
/// snapshot: ``moodRecoveryPrompt()`` (a gentle line when the sky is gloomy), ``currentComfort()``
/// (the short-walk offer's ``WeatherComfort``), and ``currentAmbient()`` (the Home layer's
/// ``WeatherAmbient``). Callers — the app's `HomeView`, `AmbientCards`,
/// `CompanionAmbienceLayer`, and `SettingsSheet` — gate on `settings.weatherPromptsEnabled` and
/// must treat `nil` as "feature simply absent".
///
/// Concurrency invariants: the snapshot is cached for ``cacheInterval`` (30 min), and BOTH the
/// location fix and the WeatherKit fetch coalesce concurrent callers onto a single in-flight
/// `Task` (`locationRequest` / `conditionsRequest`) — only that task ever installs
/// `locationContinuation`, so a cold-launch burst of `.task`s cannot overwrite and leak another
/// caller's continuation. `CLLocationManagerDelegate` callbacks arrive `nonisolated` and hop to
/// the main actor before touching state. Everything is #if-gated so the type still compiles where
/// WeatherKit is unavailable; every failure path resolves to `nil`, never a thrown error.
@MainActor
public final class WeatherKitService: NSObject, CLLocationManagerDelegate {
    /// The app-wide instance — a singleton so all surfaces share one conditions cache and one
    /// in-flight location request.
    public static let shared = WeatherKitService()

    /// How long one fetched current-weather snapshot is reused before re-querying WeatherKit.
    /// Shared by `moodRecoveryPrompt` and `currentComfort` so a Home appearance costs at most one
    /// location + weather fetch per half hour (previously every appearance refetched).
    public static let cacheInterval: TimeInterval = 30 * 60

    /// This module's unified-log sink. `AppServices` deliberately declares no `FernletFoundation`
    /// edge (see `Package.swift`), so `os.Logger` — not `FernletAuditLog` — is the audit surface here.
    private static let logger = Logger(subsystem: "com.fernlet", category: "weather")

    private let locationManager = CLLocationManager()
    private var authContinuation: CheckedContinuation<Bool, Never>?
    private var locationContinuation: CheckedContinuation<CLLocation?, Never>?

    /// The single in-flight authorization request, shared by all concurrent callers.
    ///
    /// Without it a second caller arriving while the status is still `.notDetermined` overwrites
    /// `authContinuation` and the first is never resumed (SWIFT TASK CONTINUATION MISUSE → a stuck
    /// weather surface). Only the task stored here ever installs the continuation — the same
    /// coalescing `locationRequest` already applies to the location fix.
    private var authRequest: Task<Bool, Never>?

    /// The single in-flight location request, shared by all concurrent callers so a cold-launch
    /// burst of Home/ambient `.task`s issues one `requestLocation()` and awaits one continuation.
    /// Without this, a second caller would overwrite `locationContinuation` and leak the first
    /// (SWIFT TASK CONTINUATION MISUSE → a stuck weather surface).
    private var locationRequest: Task<CLLocation?, Never>?

    #if canImport(WeatherKit)
    /// The cached current-conditions snapshot (only the three fields Fernlet ever reads).
    ///
    /// `fetchedAt` drives the ``cacheInterval`` freshness check in `currentConditions()`; one
    /// snapshot feeds all three public read surfaces.
    private struct ConditionsSnapshot {
        let condition: WeatherCondition
        let temperatureCelsius: Double
        let isDaylight: Bool
        let fetchedAt: Date
    }

    private var cachedConditions: ConditionsSnapshot?

    /// The single in-flight conditions fetch, shared by concurrent callers on a cache miss so
    /// `moodRecoveryPrompt`/`currentComfort`/`currentAmbient` firing together cost one WeatherKit
    /// fetch, not one each.
    private var conditionsRequest: Task<ConditionsSnapshot?, Never>?
    #endif

    override init() {
        super.init()
        locationManager.delegate = self
        locationManager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    /// Whether when-in-use (or always) location authorization is currently granted.
    var isAuthorized: Bool {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        default: return false
        }
    }

    /// Requests when-in-use authorization. Returns whether it ended up granted.
    ///
    /// Concurrent callers on `.notDetermined` coalesce onto one in-flight ``authRequest``, so a
    /// cold-launch burst issues one system prompt and no caller's continuation is overwritten and
    /// leaked.
    public func requestAuthorization() async -> Bool {
        switch locationManager.authorizationStatus {
        case .authorizedWhenInUse, .authorizedAlways: return true
        case .denied, .restricted: return false
        case .notDetermined:
            if let authRequest { return await authRequest.value }
            let request = Task<Bool, Never> { [weak self] in
                guard let self else { return false }
                defer { self.authRequest = nil }
                return await withCheckedContinuation { continuation in
                    self.authContinuation = continuation
                    self.locationManager.requestWhenInUseAuthorization()
                }
            }
            authRequest = request
            return await request.value
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

    /// Structured sky/daylight snapshot for the Home ambience layer, or `nil` whenever
    /// weather is unavailable (no authorization, no entitlement — WeatherKit needs it at
    /// runtime — or a network error). Callers gate on `settings.weatherPromptsEnabled`
    /// and must treat `nil` as "time-of-day tint only"; this never blocks rendering.
    /// Served from the same shared ≤30-min conditions cache as `moodRecoveryPrompt` and
    /// `currentComfort` — one location + weather fetch covers all three surfaces.
    public func currentAmbient() async -> WeatherAmbient? {
        #if canImport(WeatherKit)
        guard let conditions = await currentConditions() else { return nil }
        return WeatherAmbient(
            sky: Self.ambientSky(for: conditions.condition),
            isDaytime: conditions.isDaylight
        )
        #else
        return nil
        #endif
    }

    #if canImport(WeatherKit)
    /// Pure condition → sky-bucket mapping, split out so tests can pin it. Buckets are
    /// intentionally coarse: rain-family, snow-family, cloud/fog-family, everything
    /// else (incl. wind/heat/cold on an open sky) reads as clear.
    public static func ambientSky(for condition: WeatherCondition) -> AmbientSky {
        switch condition {
        case .rain, .heavyRain, .drizzle, .sunShowers, .thunderstorms, .strongStorms,
             .isolatedThunderstorms, .scatteredThunderstorms, .freezingRain,
             .freezingDrizzle, .hail, .hurricane, .tropicalStorm:
            return .rain
        case .snow, .heavySnow, .blizzard, .flurries, .sleet, .wintryMix,
             .blowingSnow, .sunFlurries:
            return .snow
        case .cloudy, .mostlyCloudy, .partlyCloudy, .foggy, .haze, .smoky:
            return .clouds
        default:
            return .clear
        }
    }

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
    /// Concurrent callers on a cache miss coalesce onto one in-flight `conditionsRequest` so the
    /// three weather surfaces appearing together share a single location + WeatherKit fetch.
    private func currentConditions() async -> ConditionsSnapshot? {
        if let cachedConditions, Date().timeIntervalSince(cachedConditions.fetchedAt) < Self.cacheInterval {
            return cachedConditions
        }
        if let conditionsRequest { return await conditionsRequest.value }
        let request = Task<ConditionsSnapshot?, Never> { [weak self] in
            guard let self else { return nil }
            defer { self.conditionsRequest = nil }
            guard self.isAuthorized, let location = await self.currentLocation() else { return nil }
            do {
                let current = try await WeatherService.shared.weather(for: location).currentWeather
                let snapshot = ConditionsSnapshot(
                    condition: current.condition,
                    temperatureCelsius: current.temperature.converted(to: .celsius).value,
                    isDaylight: current.isDaylight,
                    fetchedAt: Date()
                )
                self.cachedConditions = snapshot
                return snapshot
            } catch {
                // Recovery: `nil` = "weather surface simply absent", which every caller handles.
                // Logged so a missing WeatherKit entitlement or a persistent service failure is
                // distinguishable from "the user never granted location".
                Self.logger.notice("weather.fetchFailed (surface hidden): \(error.localizedDescription, privacy: .public)")
                return nil
            }
        }
        conditionsRequest = request
        return await request.value
    }
    #endif

    private func currentLocation() async -> CLLocation? {
        // Fast path: a fresh fix is already on hand — no continuation, no request.
        if let cached = locationManager.location { return cached }
        guard isAuthorized else { return nil }
        // Coalesce a concurrent burst onto one request: only this Task ever installs
        // `locationContinuation`, so no caller can overwrite (and leak) another's.
        if let locationRequest { return await locationRequest.value }
        let request = Task<CLLocation?, Never> { [weak self] in
            guard let self else { return nil }
            defer { self.locationRequest = nil }
            return await withCheckedContinuation { continuation in
                self.locationContinuation = continuation
                self.locationManager.requestLocation()
            }
        }
        locationRequest = request
        return await request.value
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
            // Recovery: resume with no fix — the weather surfaces treat nil as "absent". Logged so a
            // persistent CoreLocation failure is not indistinguishable from "no permission".
            Self.logger.notice("weather.locationFailed (surface hidden): \(error.localizedDescription, privacy: .public)")
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
