// HealthAvailabilityMessageTests.swift
// FernletTests
//
// Round 2026-08-20 Part 1.2: Settings → Health rendered "Health data is not available on this
// device." whenever `snapshot.isAvailable` was false — but that Bool folds the master integration
// toggle (default OFF, living on the Privacy & Data screen) into device capability, so every fresh
// install was told its hardware can't do Health, with no way out, on the gateway to a headline
// feature. This suite pins the fix's seam, `HealthKitAuthorizationViewModel.availabilityState`:
// device-unavailable keeps the device message, device-available-with-the-toggle-off reads as
// `integrationOff` (the state the settings screen routes to Privacy & Data), a live integration
// reads as `available`, and flipping the toggle on actually lands after `refresh()`.
//
// Ledger seams are isolated per test out of the same caution as the requested-capabilities suite:
// `disableIntegration()` clears the production ledger row, so nothing here may touch that slot.

import Foundation
import FernletDomainModel
import HealthKit
import HealthKitGateway
import Testing

@MainActor
struct HealthAvailabilityMessageTests {

    /// Hardware without a Health store is the only state that may claim the device can't — and it
    /// keeps the original message, regardless of what the master toggle says.
    @Test func deviceWithoutAHealthStoreKeepsTheDeviceMessage() throws {
        let viewModel = try makeViewModel(deviceHasHealthStore: false, integrationEnabled: false)

        #expect(viewModel.availabilityState == .deviceUnavailable)
        #expect(viewModel.statusMessage == "Health data is not available on this device.")

        // The toggle cannot resurrect a Health store that does not exist.
        let toggledOn = try makeViewModel(deviceHasHealthStore: false, integrationEnabled: true)
        #expect(toggledOn.availabilityState == .deviceUnavailable)
    }

    /// The defect itself: a capable device with the master toggle off — every fresh install — must
    /// read as `integrationOff` (which the settings screen presents with the switched-off message
    /// and the Privacy & Data route), and must not claim device incapability anywhere.
    @Test func freshInstallReadsAsIntegrationOffNotDeviceIncapable() throws {
        let viewModel = try makeViewModel(deviceHasHealthStore: true, integrationEnabled: false)

        #expect(viewModel.availabilityState == .integrationOff)
        #expect(
            viewModel.statusMessage.isEmpty,
            "a phone that can do Health was told it can't — the wrong-cause message is back"
        )
    }

    /// A live integration presents the capability rows: neither unavailability state, no message.
    @Test func enabledIntegrationPresentsNeitherUnavailabilityMessage() throws {
        let viewModel = try makeViewModel(deviceHasHealthStore: true, integrationEnabled: true)

        #expect(viewModel.availabilityState == .available)
        #expect(viewModel.statusMessage.isEmpty)
    }

    /// The way out the integration-off card offers must land: after the master toggle flips on
    /// (on the Privacy & Data screen), `refresh()` — run on every settings appearance — moves the
    /// triage to `available` without a new view model.
    @Test func flippingTheMasterToggleOnIsVisibleAfterRefresh() throws {
        let service = AvailabilityStubService(deviceHasHealthStore: true, integrationEnabled: false)
        let viewModel = try makeViewModel(service: service)
        #expect(viewModel.availabilityState == .integrationOff, "precondition: the toggle is not off")

        service.integrationEnabled = true
        viewModel.refresh()

        #expect(viewModel.availabilityState == .available)
    }

    // MARK: - Fixtures

    /// Builds a view model over a fresh ``AvailabilityStubService`` in the given state.
    private func makeViewModel(deviceHasHealthStore: Bool, integrationEnabled: Bool) throws -> HealthKitAuthorizationViewModel {
        try makeViewModel(service: AvailabilityStubService(
            deviceHasHealthStore: deviceHasHealthStore,
            integrationEnabled: integrationEnabled
        ))
    }

    /// Builds a view model over `service` with per-call ledger isolation, so no test here can read
    /// or clobber the production requested-capabilities row.
    private func makeViewModel(service: AvailabilityStubService) throws -> HealthKitAuthorizationViewModel {
        let token = UUID().uuidString
        let defaults = try #require(
            UserDefaults(suiteName: "fernlet.tests.healthAvailability.\(token)"),
            "the system refused a throwaway defaults suite"
        )
        return HealthKitAuthorizationViewModel(
            service: service,
            ledgerKeychainService: "com.fernlet.healthkit-anchors.test.availability.\(token)",
            ledgerDefaults: defaults
        )
    }
}

/// A `HealthKitServicing` whose two availability facts are set per test: the device fact
/// (`isHealthDataAvailable()`) and the master toggle, folded into the snapshot exactly as the
/// production service folds them (`isAvailable` = device AND toggle). Everything else no-ops.
@MainActor
private final class AvailabilityStubService: HealthKitServicing {
    /// Whether this pretend hardware has a Health store at all.
    var deviceHasHealthStore: Bool
    /// The pretend master integration toggle; mutable so a test can flip it mid-flight.
    var integrationEnabled: Bool

    init(deviceHasHealthStore: Bool, integrationEnabled: Bool) {
        self.deviceHasHealthStore = deviceHasHealthStore
        self.integrationEnabled = integrationEnabled
    }

    func isHealthDataAvailable() -> Bool { deviceHasHealthStore }
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot {
        AuthorizationSnapshot(isAvailable: deviceHasHealthStore && integrationEnabled, writeStatuses: [:])
    }
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome {
        AuthorizationOutcome(writeStatuses: [:])
    }
    func startObserving(_ type: HKSampleType, handler: @escaping (HKAnchoredObjectQuery, [HKSample], [HKDeletedObject]) -> Void) async throws { }
    func startObservingWorkouts(handler: @escaping ([HKWorkout], [UUID]) -> Void) async throws { }
    func stopObservingWorkouts() { }
    func recentWorkouts(since anchorDate: Date) async throws -> [HKWorkout] { [] }
    func backfillWorkoutsFromHealth(referenceDate: Date) async throws -> [HKWorkout] { [] }
    func save(_ samples: [HKObject]) async throws { }
    func delete(_ samples: [HKSample]) async throws { }
    func deleteWorkout(fernletWorkoutID: UUID) async throws -> Bool { false }
    func statistics(for type: HKQuantityType, options: HKStatisticsOptions, interval: DateComponents, anchor: Date) async throws -> [HKStatistics] { [] }
    func requestBodyProfileAuthorization() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func loadBodyProfile() async throws -> HealthBodyProfile { HealthBodyProfile() }
    func saveBodyProfileMeasurements(_ profile: UserNutritionProfile) async throws { }
    func saveWorkout(_ workout: Workout) async throws -> UUID { UUID() }
    func loadLastNightSleepHours(referenceDate: Date) async throws -> Double? { nil }
    func loadDailyHealthContext(referenceDate: Date, capabilities: Set<HealthCapability>?) async throws -> HealthDailyContext { HealthDailyContext() }
    func disableIntegration() async throws { }
    func enableIntegration() async throws { }
    func openHealthPrivacySettings() async { }
}
