import CloudKit
import LocalPersistence
import FernletFoundation
import CoreData
import Foundation
import HealthKit
import Security
import Testing
import FernletDomainModel
import FernletPersistence
import CloudKitSync
import HealthKitGateway
@testable import Fernlet

// MARK: - Suite

@MainActor
@Suite(.serialized)
struct StoragePrivacyIntegrationTests {

    // MARK: - Scenario 1: Fresh install, local-only path

    /// Local-only preferences produce no CloudKit container options and mark
    /// the store URL excluded from iOS/iCloud device backups.
    @Test func localOnlyPath_noCloudKitOptions_storeExcludedFromBackup() throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }

        let controller = PersistenceController(
            preferences: StoragePreferences(
                iCloudSyncEnabled: false,
                localBackupExcludedFromiOSBackup: true
            ),
            storeURL: storeURL
        )

        #expect(controller.activeStoreDescription?.cloudKitContainerOptions == nil)

        let values = try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    @Test func storeLoadFailureSurfacesLaunchErrorWithoutDeletingStorePath() async throws {
        let storeURL = makeTemporaryStoreURL()
        try FileManager.default.createDirectory(at: storeURL, withIntermediateDirectories: true)
        defer { removeTemporaryStore(at: storeURL) }

        let controller = PersistenceController(
            preferences: StoragePreferences(iCloudSyncEnabled: false),
            storeURL: storeURL
        )

        #expect(controller.didFailToLoad == true)
        #expect(FileManager.default.fileExists(atPath: storeURL.path) == true)
        await #expect(throws: PersistenceStoreLoadError.primaryStoreUnavailable) {
            _ = try await FernletStore.load(persistenceController: controller)
        }
    }

    /// Local-only preferences with backup inclusion set to false do NOT exclude
    /// the store from backup.
    @Test func localOnlyPath_backupInclusionEnabled_storeNotExcluded() throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }

        _ = PersistenceController(
            preferences: StoragePreferences(
                iCloudSyncEnabled: false,
                localBackupExcludedFromiOSBackup: false
            ),
            storeURL: storeURL
        )

        let values = try storeURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup != true)
    }

    // MARK: - Scenario 2: Fresh install, iCloud path

    /// iCloud preferences produce non-nil CloudKit container options with the
    /// production container identifier.
    @Test func iCloudPath_cloudKitContainerOptionsPresent() {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }

        let controller = PersistenceController(
            preferences: StoragePreferences(iCloudSyncEnabled: true),
            storeURL: storeURL,
            iCloudAvailable: true
        )

        #expect(controller.activeStoreDescription?.cloudKitContainerOptions != nil)
        #expect(
            controller.activeStoreDescription?.cloudKitContainerOptions?.containerIdentifier
                == "iCloud.MBO.Fernlet"
        )
    }

    // MARK: - Scenario 5: iCloud re-enable emits audit events

    /// Enabling iCloud after it was off triggers persistence.reload.started and
    /// persistence.reload.completed audit events.
    @Test func iCloudReEnable_auditLogContainsReloadEvents() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }

        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }

        let controller = PersistenceController(
            preferences: StoragePreferences(iCloudSyncEnabled: false),
            storeURL: storeURL
        )
        try await controller.reload(with: StoragePreferences(iCloudSyncEnabled: true))

        #expect(audit.contains("persistence.reload.started"))
        #expect(audit.contains("persistence.reload.completed"))
    }

    /// Reload from local to iCloud preserves previously written data.
    @Test func iCloudReEnable_localDataPreservedAfterReload() async throws {
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }

        let controller = PersistenceController(
            preferences: StoragePreferences(iCloudSyncEnabled: false),
            storeURL: storeURL
        )
        let legacyURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        let repo = CoreDataFernletRepository(
            controller: controller,
            legacyRepository: LocalFernletRepository(fileURL: legacyURL)
        )
        let store = FernletStore(date: Date(), repository: repo)
        store.addMeal(from: "avocado toast", type: .breakfast)
        store.flushPendingSnapshotSave()

        try await controller.reload(with: StoragePreferences(iCloudSyncEnabled: true))

        let reloaded = FernletStore(
            date: Date(),
            repository: CoreDataFernletRepository(
                controller: controller,
                legacyRepository: LocalFernletRepository(fileURL: legacyURL)
            )
        )
        #expect(reloaded.day.meals.contains { $0.name.localizedCaseInsensitiveContains("avocado") })
    }

    // MARK: - Scenario 6: HealthKit disable

    /// Disabling HealthKit does not delete existing samples from the store.
    @Test func healthKitDisable_samplesNotDeleted() async throws {
        let harness = HKDisableHarness()
        defer { harness.cleanup() }
        let type = try HealthKitService.quantityType(.stepCount)
        try await harness.service.startObserving(type) { _, _, _ in }

        try await harness.service.disableIntegration()

        #expect(harness.controller.deleteCallCount == 0)
    }

    /// Disabling HealthKit clears stored anchors from Keychain.
    @Test func healthKitDisable_keychainAnchorsCleared() async throws {
        let harness = HKDisableHarness()
        defer { harness.cleanup() }
        let stepType = try HealthKitService.quantityType(.stepCount)
        HealthKitAnchorKeychain.store(Data("anchor".utf8), identifier: stepType.identifier)
        #expect(keychainData(account: HealthKitAnchorKeychain.account(for: stepType.identifier)) != nil)

        try await harness.service.startObserving(stepType) { _, _, _ in }
        try await harness.service.disableIntegration()

        #expect(keychainData(account: HealthKitAnchorKeychain.account(for: stepType.identifier)) == nil)
    }

    /// After disabling, `currentAuthorizationSnapshot().isAvailable` is false.
    @Test func healthKitDisable_snapshotIsUnavailable() async throws {
        let harness = HKDisableHarness()
        defer { harness.cleanup() }

        try await harness.service.disableIntegration()

        #expect(harness.service.currentAuthorizationSnapshot().isAvailable == false)
    }

    /// Disabling HealthKit sets `healthKitMasterEnabled` to false in preferences.
    @Test func healthKitDisable_preferencesMasterFlagCleared() async throws {
        let harness = HKDisableHarness()
        defer { harness.cleanup() }

        try await harness.service.disableIntegration()

        #expect(harness.preferences.preferences.healthKitMasterEnabled == false)
    }

    // MARK: - Scenario 8: Audit log completeness

    /// A scripted journey through storage and HealthKit transitions emits every
    /// required audit event at least once.
    @Test func auditLog_allRequiredEventsEmittedDuringScriptedJourney() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }

        // --- CloudKit detect / delete ---
        let zoneID = CKRecordZone.ID(zoneName: "journey-zone", ownerName: CKCurrentUserDefaultName)
        let database = MockCloudKitDatabase()
        database.recordsByType["CD_FernletDatabaseRecord"] = [
            makeCloudRecord(type: "CD_FernletDatabaseRecord", name: "r1", zoneID: zoneID)
        ]
        let cloudService = CloudKitDataService(
            accountProvider: MockCKAccountProvider(status: .available),
            database: database,
            zoneID: zoneID,
            isCloudKitSyncEnabled: { true }
        )
        _ = try? await cloudService.detectExistingData()
        _ = try? await cloudService.deleteAllCloudKitData(
            confirmation: DeletionConfirmation(userTypedConfirmation: "DELETE")
        )

        // --- Persistence reload ---
        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }
        let controller = PersistenceController(
            preferences: StoragePreferences(iCloudSyncEnabled: false),
            storeURL: storeURL
        )
        try await controller.reload(with: StoragePreferences(iCloudSyncEnabled: true))
        try await controller.reload(with: StoragePreferences(iCloudSyncEnabled: false))

        // --- HealthKit disable / enable ---
        let harness = HKDisableHarness()
        defer { harness.cleanup() }
        try await harness.service.disableIntegration()
        try await harness.service.enableIntegration()

        // Required event assertions
        #expect(audit.contains("cloudkit.detect.attempt"))
        #expect(audit.contains("cloudkit.detect.completed"))
        #expect(audit.contains("cloudkit.delete.attempt"))
        #expect(audit.contains("cloudkit.delete.completed"))
        #expect(audit.contains("persistence.reload.started"))
        #expect(audit.contains("persistence.reload.completed"))
        #expect(audit.contains("healthkit.disable.attempt"))
        #expect(audit.contains("healthkit.disable.completed"))
        #expect(audit.contains("healthkit.enable.attempt"))
        #expect(audit.contains("healthkit.enable.completed"))
    }

    // MARK: - StoragePreferencesStore → PersistenceController wiring

    /// Changing iCloudSyncEnabled in StoragePreferencesStore updates the
    /// cloudKitContainerOptions on the active store description after reload.
    @Test func preferencesStoreWiring_iCloudToggleChangesContainerOptions() async throws {
        let serviceID = "com.fernlet.wiring.tests.\(UUID().uuidString)"
        defer { KeychainItem.delete(for: .storagePreferences, service: serviceID) }

        let prefsStore = StoragePreferencesStore(keychainService: serviceID)
        prefsStore.update { $0.iCloudSyncEnabled = false }

        let storeURL = makeTemporaryStoreURL()
        defer { removeTemporaryStore(at: storeURL) }
        let controller = PersistenceController(
            preferences: prefsStore.preferences,
            storeURL: storeURL,
            iCloudAvailable: true
        )
        #expect(controller.activeStoreDescription?.cloudKitContainerOptions == nil)

        prefsStore.update { $0.iCloudSyncEnabled = true }
        try await controller.reload(with: prefsStore.preferences)

        #expect(controller.activeStoreDescription?.cloudKitContainerOptions != nil)
    }

    // MARK: - Helpers

    private func makeTemporaryStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("sqlite")
    }

    private func removeTemporaryStore(at url: URL) {
        for suffix in ["", "-shm", "-wal"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: url.path + suffix))
        }
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

    private func makeCloudRecord(type: String, name: String, zoneID: CKRecordZone.ID) -> CKRecord {
        CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }
}

// MARK: - HealthKit disable harness

@MainActor
private final class HKDisableHarness {
    let controller = MockHKStoreController()
    let preferences: StoragePreferencesStore
    let service: HealthKitService
    private let serviceID: String

    init() {
        serviceID = "com.fernlet.hk-disable.integration.\(UUID().uuidString)"
        preferences = StoragePreferencesStore(keychainService: serviceID)
        preferences.update { $0.healthKitMasterEnabled = true }
        service = HealthKitService(
            storeController: controller,
            cacheCleaner: NoOpCacheCleaner(),
            preferencesStore: preferences
        )
    }

    func cleanup() {
        KeychainItem.delete(for: .storagePreferences, service: serviceID)
    }
}

// MARK: - Mock HealthKitStoreControlling

private final class MockHKStoreController: HealthKitStoreControlling {
    private(set) var executedQueries: [HKQuery] = []
    private(set) var stoppedQueries: [HKQuery] = []
    private(set) var disabledBackgroundDeliveryIdentifiers: [String] = []
    private(set) var deleteCallCount = 0

    func requestAuthorization(toShare: Set<HKSampleType>, read: Set<HKObjectType>) async throws {}
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus { .notDetermined }
    func execute(_ query: HKQuery) { executedQueries.append(query) }
    func stop(_ query: HKQuery) { stoppedQueries.append(query) }
    func save(_ samples: [HKObject]) async throws {}
    func delete(_ samples: [HKSample]) async throws { deleteCallCount += 1 }
    var deletedObjectTypeIdentifiers: [String] = []
    func deleteObjects(of type: HKObjectType, predicate: NSPredicate) async throws {
        deletedObjectTypeIdentifiers.append(type.identifier)
    }
    func disableBackgroundDelivery(for type: HKObjectType) async throws {
        disabledBackgroundDeliveryIdentifiers.append(type.identifier)
    }
}

// MARK: - Mock CloudKit

private final class MockCKAccountProvider: CloudKitAccountStatusProviding {
    let status: CKAccountStatus
    init(status: CKAccountStatus) { self.status = status }
    func accountStatus() async throws -> CKAccountStatus { status }
}

private final class MockCloudKitDatabase: CloudKitRecordDatabase {
    var recordsByType: [String: [CKRecord]] = [:]

    var allRecords: [CKRecord] { recordsByType.values.flatMap { $0 } }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] {
        var seen = Set<String>()
        return allRecords.compactMap { record in
            let zoneID = record.recordID.zoneID
            let key = "\(zoneID.ownerName):\(zoneID.zoneName)"
            return seen.insert(key).inserted ? zoneID : nil
        }
    }

    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        recordsByType[recordType, default: []]
            .filter { $0.recordID.zoneID == zoneID }
            .map(\.recordID)
    }

    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        let requested = Set(recordIDs.map(\.recordName))
        return allRecords.filter { requested.contains($0.recordID.recordName) }
    }

    func saveRecords(_ records: [CKRecord]) async throws {
        for record in records {
            var existing = recordsByType[record.recordType, default: []]
            existing.removeAll { $0.recordID == record.recordID }
            existing.append(record)
            recordsByType[record.recordType] = existing
        }
    }

    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws {
        let names = Set(recordIDs.map(\.recordName))
        for type in recordsByType.keys {
            recordsByType[type] = recordsByType[type, default: []].filter { !names.contains($0.recordID.recordName) }
        }
    }
}

// MARK: - Audit capture

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

// MARK: - No-op cache cleaner

private struct NoOpCacheCleaner: HealthKitCacheClearing {
    func clearHealthKitCachedValues() throws {}
}
