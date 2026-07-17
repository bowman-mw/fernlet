import Foundation
import FernletFoundation
import HealthKit
import Security
import Testing
import FernletDomainModel
import HealthKitGateway
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct HealthKitDisableTests {
    @Test func disableCancelsObserversAndDisablesBackgroundDelivery() async throws {
        let harness = HealthKitDisableHarness()
        defer { harness.cleanup() }
        let type = try HealthKitService.quantityType(.stepCount)
        try await harness.service.startObserving(type) { _, _, _ in }

        try await harness.service.disableIntegration()

        #expect(harness.controller.executedQueries.count == 1)
        #expect(harness.controller.stoppedQueries.count == 1)
        #expect(harness.controller.disabledBackgroundDeliveryIdentifiers.contains(type.identifier))
        #expect(harness.preferences.preferences.healthKitMasterEnabled == false)
    }

    @Test func disableDoesNotDeleteHealthKitSamples() async throws {
        let harness = HealthKitDisableHarness()
        defer { harness.cleanup() }
        let type = try HealthKitService.quantityType(.stepCount)
        try await harness.service.startObserving(type) { _, _, _ in }

        try await harness.service.disableIntegration()

        #expect(harness.controller.deleteCallCount == 0)
    }

    @Test func disableClearsHealthKitAnchorsFromKeychain() async throws {
        let harness = HealthKitDisableHarness()
        defer { harness.cleanup() }
        let stepType = try HealthKitService.quantityType(.stepCount)
        let sleepType = try HealthKitService.categoryType(.sleepAnalysis)
        HealthKitAnchorKeychain.store(Data("step-anchor".utf8), identifier: stepType.identifier)
        HealthKitAnchorKeychain.store(Data("sleep-anchor".utf8), identifier: sleepType.identifier)
        #expect(keychainData(account: HealthKitAnchorKeychain.account(for: stepType.identifier)) != nil)
        #expect(keychainData(account: HealthKitAnchorKeychain.account(for: sleepType.identifier)) != nil)

        try await harness.service.startObserving(stepType) { _, _, _ in }
        try await harness.service.disableIntegration()

        #expect(keychainData(account: HealthKitAnchorKeychain.account(for: stepType.identifier)) == nil)
        #expect(keychainData(account: HealthKitAnchorKeychain.account(for: sleepType.identifier)) == nil)
    }

    @Test func currentAuthorizationSnapshotIsUnavailableWhenUserRevoked() {
        let harness = HealthKitDisableHarness(masterEnabled: false)
        defer { harness.cleanup() }

        let snapshot = harness.service.currentAuthorizationSnapshot()

        #expect(snapshot.isAvailable == false)
    }

    /// Regression for prior finding #20: the master toggle is flipped on a *different*
    /// StoragePreferencesStore instance (the Privacy screen's). A long-lived
    /// HealthKitService must observe that change live, not from a cached copy, so it
    /// stops reporting available the moment the user disables HealthKit — no relaunch.
    @Test func integrationStateReflectsExternalToggleWithoutRelaunch() {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let serviceID = "com.fernlet.healthkit-livetoggle.tests.\(UUID().uuidString)"
        defer { KeychainItem.delete(for: .storagePreferences, service: serviceID) }

        let prefsA = StoragePreferencesStore(keychainService: serviceID)
        prefsA.update { $0.healthKitMasterEnabled = true }
        let service = HealthKitService(
            storeController: MockHealthKitStoreController(),
            cacheCleaner: MockHealthKitCacheCleaner(),
            preferencesStore: prefsA
        )
        #expect(service.currentAuthorizationSnapshot().isAvailable)

        // A separate store (same keychain slot) disables HealthKit, as the Privacy screen does.
        let prefsB = StoragePreferencesStore(keychainService: serviceID)
        prefsB.update { $0.healthKitMasterEnabled = false }

        // The original long-lived service must now report unavailable without re-instantiation.
        #expect(service.currentAuthorizationSnapshot().isAvailable == false)
    }

    @Test func workoutLoggingCapabilityHasNonEmptySummaryAndTitle() {
        #expect(!HealthCapability.workoutLogging.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(!HealthCapability.workoutLogging.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func workoutLoggingWriteTypeIdentifiersListIncludesActiveEnergy() {
        let identifiers = HealthAuthorizationPresentation.writeTypeIdentifiers(for: .workoutLogging)

        #expect(identifiers.contains(HKQuantityTypeIdentifier.activeEnergyBurned.rawValue))
    }

    @Test func reEnableRestoresObservation() async throws {
        let harness = HealthKitDisableHarness()
        defer { harness.cleanup() }
        let type = try HealthKitService.quantityType(.stepCount)
        try await harness.service.startObserving(type) { _, _, _ in }
        try await harness.service.disableIntegration()

        try await harness.service.enableIntegration()

        #expect(harness.preferences.preferences.healthKitMasterEnabled)
        #expect(harness.controller.executedQueries.count == 2)
    }

    @Test func auditLogCapturesDisableAndEnableEvents() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let harness = HealthKitDisableHarness()
        defer { harness.cleanup() }

        try await harness.service.disableIntegration()
        try await harness.service.enableIntegration()

        #expect(audit.contains("healthkit.disable.attempt"))
        #expect(audit.contains("healthkit.disable.completed"))
        #expect(audit.contains("healthkit.enable.attempt"))
        #expect(audit.contains("healthkit.enable.completed"))
    }

    @Test func disableClearsCachedHealthContext() async throws {
        let cleaner = MockHealthKitCacheCleaner()
        let harness = HealthKitDisableHarness(cacheCleaner: cleaner)
        defer { harness.cleanup() }

        try await harness.service.disableIntegration()

        #expect(cleaner.clearCallCount == 1)
    }

    /// WI-2 (Docs/Security-Hardening-Plan-2026-06-27.md): a `HealthKitService` built before the app
    /// installs a concrete cache clearer (a `#Preview`, the share extension, a future early-launch path)
    /// must FAIL CLOSED on `disableIntegration()` — throw + audit-log — instead of silently no-op'ing the
    /// purge (the old `NoopHealthKitCacheClearer` default) and flipping the master switch off while
    /// leaving opted-out clinical data behind. Nothing must be torn down when the clearer is absent.
    @Test func disableFailsClosedWhenNoCacheClearerInstalled() async throws {
        // NOTE: this mutates the process-wide `HealthKitService.defaultCacheClearer` for the test (restored
        // via defer). `disableIntegration()` re-reads that static, so the nil window spans the awaits below.
        // `.serialized` only orders THIS suite's own tests, so the safety invariant is process-wide: no
        // OTHER suite may construct a *bare* real HealthKitService (one with no injected `cacheCleaner:`,
        // which would fall back to this static) and call disableIntegration() while this runs. Audited at
        // the time of writing — every other disableIntegration call site uses a mock/fake service or injects
        // an explicit cacheCleaner, so none reads this static. A future bare-service disable test MUST be
        // serialized against this one (or inject its own clearer) to avoid a cross-suite flake.
        let previousDefault = HealthKitService.defaultCacheClearer
        HealthKitService.defaultCacheClearer = nil
        defer { HealthKitService.defaultCacheClearer = previousDefault }

        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }

        let controller = MockHealthKitStoreController()
        let serviceID = "com.fernlet.healthkit-failclosed.tests.\(UUID().uuidString)"
        defer { KeychainItem.delete(for: .storagePreferences, service: serviceID) }
        let preferences = StoragePreferencesStore(keychainService: serviceID)
        preferences.update { $0.healthKitMasterEnabled = true }

        let service = HealthKitService(
            storeController: controller,
            cacheCleaner: nil,           // no clearer installed (and the static default is nil too)
            preferencesStore: preferences
        )
        let type = try HealthKitService.quantityType(.stepCount)
        try await service.startObserving(type) { _, _, _ in }

        do {
            try await service.disableIntegration()
            Issue.record("disableIntegration must throw when no cache clearer is installed")
        } catch HealthKitServiceError.cacheClearerUnavailable {
            // expected — fail closed
        } catch {
            Issue.record("unexpected error from disableIntegration: \(error)")
        }

        // Fail-closed: the opt-out did NOT half-apply — no teardown, master switch still ON.
        #expect(controller.stoppedQueries.isEmpty)
        #expect(controller.disabledBackgroundDeliveryIdentifiers.isEmpty)
        #expect(preferences.preferences.healthKitMasterEnabled == true)
        #expect(audit.contains("healthkit.disable.attempt"))
        #expect(audit.contains("healthkit.disable.failed"))

        // Cleanup any anchor the observation may have stored.
        HealthKitAnchorKeychain.delete(identifier: type.identifier)
    }

    private func keychainData(account: String) -> Data? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: HealthKitAnchorKeychain.service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }
}

@MainActor
private final class HealthKitDisableHarness {
    let controller = MockHealthKitStoreController()
    let preferences: StoragePreferencesStore
    let service: HealthKitService
    private let preferenceServiceID: String

    init(masterEnabled: Bool = true, cacheCleaner: HealthKitCacheClearing = MockHealthKitCacheCleaner()) {
        preferenceServiceID = "com.fernlet.healthkit-disable.tests.\(UUID().uuidString)"
        preferences = StoragePreferencesStore(keychainService: preferenceServiceID)
        preferences.update { storagePreferences in
            storagePreferences.healthKitMasterEnabled = masterEnabled
        }
        service = HealthKitService(
            storeController: controller,
            cacheCleaner: cacheCleaner,
            preferencesStore: preferences
        )
    }

    func cleanup() {
        KeychainItem.delete(for: .storagePreferences, service: preferenceServiceID)
        HealthKitAnchorKeychain.delete(identifier: HKQuantityTypeIdentifier.stepCount.rawValue)
        HealthKitAnchorKeychain.delete(identifier: HKCategoryTypeIdentifier.sleepAnalysis.rawValue)
    }
}

private final class MockHealthKitStoreController: HealthKitStoreControlling {
    private(set) var executedQueries: [HKQuery] = []
    private(set) var stoppedQueries: [HKQuery] = []
    private(set) var disabledBackgroundDeliveryIdentifiers: [String] = []
    private(set) var deleteCallCount = 0
    var authorizationStatuses: [String: HKAuthorizationStatus] = [:]

    func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws { }

    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
        authorizationStatuses[type.identifier] ?? .notDetermined
    }

    func execute(_ query: HKQuery) {
        executedQueries.append(query)
    }

    func stop(_ query: HKQuery) {
        stoppedQueries.append(query)
    }

    func save(_ samples: [HKObject]) async throws { }

    func delete(_ samples: [HKSample]) async throws {
        deleteCallCount += 1
    }

    /// Records which types a bulk delete touched, so `deleteAllAuthoredSamples` can be asserted on.
    var deletedObjectTypeIdentifiers: [String] = []

    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        deletedObjectTypeIdentifiers.append(type.identifier)
    }

    func disableBackgroundDelivery(for type: HKObjectType) async throws {
        disabledBackgroundDeliveryIdentifiers.append(type.identifier)
    }
}

private final class MockHealthKitCacheCleaner: HealthKitCacheClearing {
    private(set) var clearCallCount = 0

    func clearHealthKitCachedValues() throws {
        clearCallCount += 1
    }
}

private final class AuditCapture {
    private let lock = NSLock()
    private var storedEvents: [(event: String, context: [String: String])] = []
    private var token: UUID?

    var events: [(event: String, context: [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append((event, context))
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    func contains(_ event: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.contains { $0.event == event }
    }
}
