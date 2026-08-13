//
//  StressService.swift
//  Fernlet
//
//  App-side owner of the opt-in "Body signals" stress estimate. Pulls day-bucketed
//  HRV/resting-HR/respiration/wrist-temperature history from the HealthKit gateway
//  (foreground only), joins it with diary confounders (workouts, sick days), runs the
//  pure `StressEngine`, and exposes the current gentle `StressAssessment` to Home and
//  (via `StressScoringContextProviding`) to the capped scoring modifier.
//
//  PERSISTENCE (deliberate): the baselines/EWMA state live in a device-local JSON
//  sidecar (`StressLocalState.json` in Application Support) — NEVER in FernletSettings,
//  LocalFernletDatabase, DayRecord rows, dailyScores, or anything CloudKit-synced.
//  Every existing structured store syncs when iCloud is on; a rolling clinical series
//  (HRV/RHR aggregates) must not ride along. Only the boolean opt-in flag syncs.
//

import Foundation
import Observation
import FernletFoundation
import FernletDomainModel
import FernletScoring
import HealthKitGateway

/// The scoring seam `FernletStore` holds — deliberately tiny so the store sees only the
/// abstract assessment (and a scrub hook for reset/opt-out), never baselines or raw series.
///
/// ``StressService`` is the sole production conformer; tests supply fakes. Main-actor isolated to
/// match the store it plugs into.
@MainActor
protocol StressScoringContextProviding: AnyObject {
    var currentStressAssessment: StressAssessment? { get }
    /// Deletes the device-local sidecar and clears the in-memory assessment. Called on
    /// "Reset everything" and when the user opts out, so HealthKit-derived baselines
    /// never outlive the user's consent.
    func scrubStressLocalState()
}

/// App-side owner of the opt-in "Body signals" stress estimate.
///
/// Pulls day-bucketed HRV / resting-HR / respiration / wrist-temperature history from the
/// HealthKit gateway (foreground pull only — no background delivery), joins it with diary
/// confounders (workout days, sick days) read off ``FernletStore``, runs the pure `StressEngine`,
/// and exposes the current gentle `StressAssessment` to Home and — via
/// ``StressScoringContextProviding`` — to the capped scoring modifier.
///
/// Persistence is deliberate: the baselines/EWMA state live in a device-local JSON sidecar
/// (`StressLocalState.json` in Application Support, written atomically with complete file
/// protection) — NEVER in FernletSettings, the day records, `dailyScores`, or anything
/// CloudKit-synced, because every existing structured store syncs when iCloud is on and a rolling
/// clinical series must not ride along. Only the boolean opt-in flag syncs. Consent is honored
/// aggressively: a disabled toggle, a closed HealthKit gate, and a mid-flight revocation all
/// route through ``scrubStressLocalState()``, which deletes the sidecar so HealthKit-derived
/// baselines never outlive the opt-in ("Reset everything" calls it too). Main-actor isolated and
/// `@Observable`; refreshes are debounced to ``refreshInterval`` and guarded against overlap.
@MainActor
@Observable
final class StressService: StressScoringContextProviding {
    /// The current gentle assessment, or nil when opted out, cold-starting (< 7 valid
    /// HRV days), or HealthKit has nothing to offer.
    private(set) var assessment: StressAssessment?
    /// When the last successful refresh ran (drives the ≥30 min debounce).
    private(set) var lastRefreshedAt: Date?

    var currentStressAssessment: StressAssessment? { assessment }

    /// Device-local sidecar payload. `sampleHistory` holds day-grain aggregates only
    /// (never raw HealthKit samples); the EWMA state is implicit — `lastAssessment.smoothedZ`
    /// plus the deterministic recompute over `sampleHistory` reproduce it exactly.
    struct LocalState: Codable {
        var lastAssessment: StressAssessment?
        var sampleHistory: [StressDaySample]
        var computedAt: Date?
    }

    /// Minimum spacing between HealthKit refreshes (launch + scene-active are debounced).
    static let refreshInterval: TimeInterval = 30 * 60
    /// Trailing history window: 60 days (the engine's "ideal" baseline; 30 is its minimum).
    static let historyDays = 60
    static let stateFileName = "StressLocalState.json"

    @ObservationIgnored private weak var store: FernletStore?
    @ObservationIgnored private var fetchMetricDays: ((Int) async throws -> [StressMetricDay])?
    @ObservationIgnored private let stateFileURL: URL
    @ObservationIgnored private var isRefreshing = false

    /// - Parameter stateDirectory: injectable for tests; defaults to Application Support.
    init(stateDirectory: URL? = nil) {
        let directory = stateDirectory
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateFileURL = directory.appendingPathComponent(Self.stateFileName)
        if let data = try? Data(contentsOf: stateFileURL),
           let state = try? JSONDecoder().decode(LocalState.self, from: data) {
            assessment = state.lastAssessment
            lastRefreshedAt = state.computedAt
        }
    }

    /// Wires the diary host and the HealthKit fetch. A closure seam (rather than the
    /// `HealthKitServicing` protocol) keeps `stressMetricDays` off the protocol so the many
    /// existing test fakes stay untouched, and lets tests inject crafted metric days.
    func attach(store: FernletStore, fetchMetricDays: @escaping (Int) async throws -> [StressMetricDay]) {
        self.store = store
        self.fetchMetricDays = fetchMetricDays
    }

    /// Debounced refresh for launch / scene-active. When the opt-in is off this still runs
    /// the (cheap) scrub path immediately rather than waiting out the debounce.
    func refreshIfNeeded(now: Date = .now) async {
        let enabled = store?.settings.stressAwarenessEnabled ?? false
        if enabled, let last = lastRefreshedAt, now.timeIntervalSince(last) < Self.refreshInterval { return }
        await refresh(now: now)
    }

    /// Pulls the trailing metric window, joins diary confounders, runs the engine, and
    /// persists the sidecar. Foreground-pull only by design — no background delivery.
    func refresh(now: Date = .now) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        guard let store, store.settings.stressAwarenessEnabled else {
            scrubStressLocalState()
            return
        }
        guard let fetchMetricDays else { return }

        do {
            let metricDays = try await fetchMetricDays(Self.historyDays)
            // Consent can be revoked mid-flight — the toggle-off and "Reset everything" paths both
            // scrub the sidecar WHILE these HealthKit queries are suspended. Re-check before writing:
            // persisting now would silently re-create the clinical baselines after the user withdrew
            // consent (and un-do part of resetAll). Bail and re-scrub if it's off.
            guard store.settings.stressAwarenessEnabled else {
                scrubStressLocalState()
                return
            }
            let samples = makeSamples(metricDays: metricDays, store: store)
            assessment = StressEngine.assess(samples: samples)
            lastRefreshedAt = now
            persist(LocalState(lastAssessment: assessment, sampleHistory: samples, computedAt: now))
        } catch {
            // `stressMetricDays` throws only for its gates (HealthKit master or the
            // bodyContext capability turned off) — per-metric errors are absorbed as empty
            // days. Treat a gate as revoked consent: scrub the cached clinical derivatives.
            scrubStressLocalState()
        }
    }

    /// Deletes the device-local sidecar and clears the in-memory assessment — the reset/opt-out
    /// hook required by ``StressScoringContextProviding``.
    func scrubStressLocalState() {
        assessment = nil
        lastRefreshedAt = nil
        try? FileManager.default.removeItem(at: stateFileURL)
    }

    /// Joins the HealthKit day aggregates with diary confounders. Wrist-temperature deltas
    /// are taken against the user's own window mean (Apple exposes absolute °C).
    private func makeSamples(metricDays: [StressMetricDay], store: FernletStore) -> [StressDaySample] {
        let days = store.loadDays()
        let validTemps = metricDays.compactMap(\.wristTempC)
        let tempMean = validTemps.isEmpty ? nil : validTemps.reduce(0, +) / Double(validTemps.count)
        return metricDays.map { metric in
            let isToday = metric.dateKey == store.todayKey
            let dayWorkouts = isToday ? store.day.workouts : (days[metric.dateKey]?.workouts ?? [])
            return StressDaySample(
                dateKey: metric.dateKey,
                hrvSDNN: metric.hrvSDNN,
                restingHR: metric.restingHR,
                isWorkoutDay: !dayWorkouts.isEmpty,
                isSickDay: store.isSick(on: metric.dateKey),
                wristTempDeltaC: metric.wristTempC.flatMap { temp in tempMean.map { temp - $0 } },
                respiratoryRate: metric.respiratoryRate
            )
        }
    }

    private func persist(_ state: LocalState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        // Complete file protection: only ever written in the foreground, and the payload is
        // a clinical-adjacent series that should stay sealed while the device is locked.
        try? data.write(to: stateFileURL, options: [.atomic, .completeFileProtection])
    }
}
