// HealthKitRequestedCapabilitiesClearTests.swift
// FernletTests
//
// Round 2026-08-20 Part 4.1a: `fernlet.healthkit.requested-capabilities` — the record of which
// Health prompts Fernlet has ever shown, including `intimateLogging` and `cycleTracking` — was a
// plaintext UserDefaults array that nothing cleared. A wiped phone still said the user had enabled
// intimate logging, and so did a phone whose owner had turned Health off. This suite pins the four
// properties that fix costs: the clear removes it, `disableIntegration()` performs that clear, the
// persisted ledger (not a live instance) answers the has-ever-written question 4.1c asks, and a
// prompt recorded AFTER a clear does not resurrect the pre-clear set.
//
// Every test runs against its OWN keychain service and its OWN defaults suite. That is not
// tidiness: `disableIntegration()` now clears the production ledger row, so a fixture written to
// the real slot would be deleted mid-test by any other suite's disable — the shared-process hazard
// this repo has been burned by before.

import Foundation
import FernletFoundation
import HealthKit
import HealthKitGateway
import Testing
import FernletDomainModel

@MainActor
@Suite(.serialized)
struct HealthKitRequestedCapabilitiesClearTests {

    // MARK: - The clear

    /// The defect itself: before this round no clear existed anywhere in the tree.
    @Test func clearRemovesThePersistedLedger() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        HealthCapabilityRequestLedger.record(.intimateLogging, keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)
        #expect(fixture.recordedCapabilities().contains(.intimateLogging), "precondition: the prompt was not recorded")

        let cleared = HealthCapabilityRequestLedger.clear(keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)

        #expect(cleared, "the clear reported failure — the wipe must surface that, not claim success")
        #expect(fixture.recordedCapabilities().isEmpty, "a wiped phone still holds the record that intimate logging was enabled")
    }

    /// "Turn Health off" must not leave the record either — the second half of the finding.
    @Test func disableIntegrationClearsTheLedger() async throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        HealthCapabilityRequestLedger.record(.cycleTracking, keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)
        HealthCapabilityRequestLedger.record(.intimateLogging, keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)
        #expect(fixture.recordedCapabilities().count == 2, "precondition: the prompts were not recorded")

        try await fixture.makeService(masterEnabled: true, controller: RecordingHealthKitStoreController()).disableIntegration()

        #expect(fixture.recordedCapabilities().isEmpty, "disableIntegration() left the requested-capabilities ledger behind")
    }

    /// The ledger must never be reachable through `defaults read`, and must never ride an unencrypted
    /// device backup — which is what putting it in `UserDefaults` at all did.
    @Test func recordingWritesNothingToUserDefaults() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }

        HealthCapabilityRequestLedger.record(.intimateLogging, keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)

        #expect(
            fixture.defaults.object(forKey: HealthCapabilityRequestLedger.storageKey) == nil,
            "the ledger is back in plaintext UserDefaults — readable with `defaults read` and carried into unencrypted backups"
        )
        #expect(fixture.recordedCapabilities() == [.intimateLogging])
    }

    /// Installs that predate the move still carry the plaintext key. Reading the ledger has to drain
    /// AND remove it, or the fix reaches only fresh installs — and the residue is the whole finding.
    @Test func legacyPlaintextLedgerIsDrainedIntoTheKeychainAndRemoved() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        fixture.defaults.set(
            [HealthCapability.intimateLogging.rawValue, HealthCapability.activityContext.rawValue],
            forKey: HealthCapabilityRequestLedger.storageKey
        )

        let carried = HealthCapabilityRequestLedger.requestedCapabilities(keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)

        #expect(carried == [.intimateLogging, .activityContext], "the migration dropped previously-recorded prompts")
        #expect(
            fixture.defaults.object(forKey: HealthCapabilityRequestLedger.storageKey) == nil,
            "the legacy plaintext key survived the migration that was supposed to remove it"
        )
        // And the clear still reaches an install that never got as far as a read.
        fixture.defaults.set([HealthCapability.cycleTracking.rawValue], forKey: HealthCapabilityRequestLedger.storageKey)
        #expect(HealthCapabilityRequestLedger.clear(keychainService: fixture.keychainService, legacyDefaults: fixture.defaults))
        #expect(fixture.defaults.object(forKey: HealthCapabilityRequestLedger.storageKey) == nil)
    }

    // MARK: - The stale-cache case

    /// The regression that a "delete the defaults key" fix would have shipped: several view models
    /// coexist, so one of them is alive across the wipe. When it records its next prompt it must write
    /// only that prompt — a cached set would re-persist the whole pre-wipe ledger and the record of
    /// intimate logging would come back on its own.
    @Test func recordingAfterAClearDoesNotResurrectTheOldLedger() async throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let liveViewModel = fixture.makeAuthorizationViewModel()
        await liveViewModel.request(.intimateLogging)
        await liveViewModel.request(.cycleTracking)
        #expect(liveViewModel.hasRequested(.intimateLogging), "precondition: the view model did not record the prompt")

        // The wipe funnel clears the ledger without knowing this view model exists.
        #expect(HealthCapabilityRequestLedger.clear(keychainService: fixture.keychainService, legacyDefaults: fixture.defaults))
        #expect(!liveViewModel.hasRequested(.intimateLogging), "the live view model still reports the cleared prompt — it is caching the ledger")

        // The same still-alive view model prompts again.
        await liveViewModel.request(.mindfulness)

        #expect(
            fixture.recordedCapabilities() == [.mindfulness],
            "a post-wipe prompt re-persisted the pre-wipe ledger: the record of intimate logging resurrected itself"
        )
    }

    // MARK: - Has-ever-written (round Part 4.1c)

    /// 4.1c needs the answer with the master toggle off and with no service instance alive, which is
    /// exactly why it comes off the persisted row rather than any object's state.
    @Test func hasEverRequestedWritableCapabilityReadsThePersistedLedger() async throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        #expect(!HealthCapabilityRequestLedger.hasEverRequestedWritableCapability(keychainService: fixture.keychainService, legacyDefaults: fixture.defaults))

        await fixture.makeAuthorizationViewModel().request(.intimateLogging)

        // No instance in scope: the static reads the row, as the wipe flow will.
        #expect(
            HealthCapabilityRequestLedger.hasEverRequestedWritableCapability(keychainService: fixture.keychainService, legacyDefaults: fixture.defaults),
            "the wipe would never offer Health deletion to a user Fernlet has written sexual-activity samples for"
        )
        // A second, independently constructed view model sees the same persisted answer.
        #expect(fixture.makeAuthorizationViewModel().hasRequested(.intimateLogging))
    }

    /// A read-only capability is not a reason to offer Health deletion — Fernlet wrote nothing.
    @Test func readOnlyCapabilitiesAreNotEverWritten() throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }

        HealthCapabilityRequestLedger.record(.activityContext, keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)
        HealthCapabilityRequestLedger.record(.bodyContext, keychainService: fixture.keychainService, legacyDefaults: fixture.defaults)

        #expect(!HealthCapabilityRequestLedger.hasEverRequestedWritableCapability(keychainService: fixture.keychainService, legacyDefaults: fixture.defaults))
    }

    /// The classification the answer above is built on, pinned per case. `allCases.count` is asserted
    /// too so a new capability cannot slip in unclassified.
    @Test func writeCapableCapabilitiesAreExactlyTheOnesWithShareTypes() {
        #expect(HealthCapability.allCases.count == 7, "a capability was added or removed — classify it here")
        for capability in [HealthCapability.bodyProfile, .cycleTracking, .workoutLogging, .mindfulness, .intimateLogging] {
            #expect(HealthKitService.writesSamplesToHealth(capability), "\(capability.rawValue) writes samples Fernlet must offer to delete")
        }
        for capability in [HealthCapability.bodyContext, .activityContext] {
            #expect(!HealthKitService.writesSamplesToHealth(capability), "\(capability.rawValue) is read-only — claiming it writes would over-offer")
        }
    }

    // MARK: - The delete path 4.1c depends on

    /// 4.1c will offer Health deletion to users whose master toggle is OFF, so the sweep must not be
    /// gated on it. Verified here rather than assumed: `deleteAllAuthoredSamples` has no
    /// `isIntegrationEnabled` guard and neither does anything it calls.
    @Test func deleteAllAuthoredSamplesRunsWithTheMasterToggleOff() async throws {
        let fixture = try LedgerFixture()
        defer { fixture.cleanup() }
        let controller = RecordingHealthKitStoreController()
        let service = fixture.makeService(masterEnabled: false, controller: controller)
        #expect(service.currentAuthorizationSnapshot().isAvailable == false, "precondition: the master toggle is not off")

        let outcome = await service.deleteAllAuthoredSamples()

        #expect(outcome == .complete)
        #expect(
            !controller.deletedObjectTypeIdentifiers.isEmpty,
            "the sweep short-circuited with the master toggle off — the most privacy-conscious user would get the least deletion"
        )
    }
}

// MARK: - Fixtures

/// Per-test storage for the ledger: its own keychain slot and its own throwaway defaults suite.
///
/// Both halves are required for isolation. `disableIntegration()` clears the ledger row, so any test
/// (in this suite or another) that ran against the production slot would delete a concurrent test's
/// fixture; and the legacy-migration path writes to `UserDefaults`, which is process-global.
@MainActor
private struct LedgerFixture {
    let keychainService: String
    let suiteName: String
    let defaults: UserDefaults
    private let preferencesService: String

    init() throws {
        let token = UUID().uuidString
        keychainService = "com.fernlet.healthkit-anchors.test.\(token)"
        preferencesService = "com.fernlet.storage-preferences.test.\(token)"
        suiteName = "fernlet.tests.healthkitLedger.\(token)"
        guard let defaults = UserDefaults(suiteName: suiteName) else { throw FixtureError.defaultsSuiteUnavailable }
        self.defaults = defaults
    }

    /// The ledger as persisted — read back through the public API so the test exercises the same path
    /// production does.
    func recordedCapabilities() -> Set<HealthCapability> {
        HealthCapabilityRequestLedger.requestedCapabilities(keychainService: keychainService, legacyDefaults: defaults)
    }

    /// `controller` is passed explicitly rather than defaulted: a `@MainActor` type can never be a
    /// default-argument value.
    func makeService(masterEnabled: Bool, controller: RecordingHealthKitStoreController) -> HealthKitService {
        let preferences = StoragePreferencesStore(keychainService: preferencesService)
        preferences.update { $0.healthKitMasterEnabled = masterEnabled }
        return HealthKitService(
            storeController: controller,
            cacheCleaner: NoopCacheCleaner(),
            preferencesStore: preferences,
            capabilityLedgerKeychainService: keychainService,
            capabilityLedgerDefaults: defaults
        )
    }

    func makeAuthorizationViewModel() -> HealthKitAuthorizationViewModel {
        HealthKitAuthorizationViewModel(
            service: StubAuthorizationService(),
            ledgerKeychainService: keychainService,
            ledgerDefaults: defaults
        )
    }

    func cleanup() {
        KeychainItem.deleteAll(service: keychainService)
        KeychainItem.deleteAll(service: preferencesService)
        defaults.removePersistentDomain(forName: suiteName)
    }

    /// The one way building a fixture can fail: a defaults suite name the system refuses.
    enum FixtureError: Error {
        case defaultsSuiteUnavailable
    }
}

/// Records which types a bulk delete touched, so the master-toggle-off sweep can be asserted on.
@MainActor
private final class RecordingHealthKitStoreController: HealthKitStoreControlling {
    private(set) var deletedObjectTypeIdentifiers: [String] = []

    func requestAuthorization(toShare shareTypes: Set<HKSampleType>, read readTypes: Set<HKObjectType>) async throws { }
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus { .notDetermined }
    func execute(_ query: HKQuery) { }
    func stop(_ query: HKQuery) { }
    func save(_ samples: [HKObject]) async throws { }
    func delete(_ samples: [HKSample]) async throws { }
    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        deletedObjectTypeIdentifiers.append(type.identifier)
    }
    func disableBackgroundDelivery(for type: HKObjectType) async throws { }
}

/// `disableIntegration()` is fail-closed without a clearer; these tests care about the ledger leg,
/// not the cache purge.
private final class NoopCacheCleaner: HealthKitCacheClearing {
    func clearHealthKitCachedValues() throws { }
}

/// A `HealthKitServicing` that always grants, so `HealthKitAuthorizationViewModel.request(_:)`
/// reaches its `markRequested` leg — the ledger write these tests are about.
@MainActor
private final class StubAuthorizationService: HealthKitServicing {
    func isHealthDataAvailable() -> Bool { true }
    func requestAuthorization(for capability: HealthCapability) async throws -> AuthorizationOutcome {
        AuthorizationOutcome(writeStatuses: [:])
    }
    func currentAuthorizationSnapshot() -> AuthorizationSnapshot {
        AuthorizationSnapshot(isAvailable: true, writeStatuses: [:])
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
