import Foundation
import FernletFoundation
import Security
import Testing
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct StoragePreferencesTests {
    @Test func roundTripEncodeDecodePreservesAllFields() throws {
        let original = StoragePreferences(
            iCloudSyncEnabled: true,
            localBackupExcludedFromiOSBackup: false,
            healthKitMasterEnabled: true,
            healthKitCapabilityEnabled: [
                HealthCapability.bodyProfile.rawValue: true,
                HealthCapability.cycleTracking.rawValue: false,
                HealthCapability.bodyContext.rawValue: true,
                HealthCapability.activityContext.rawValue: false,
                HealthCapability.mindfulness.rawValue: true,
                HealthCapability.intimateLogging.rawValue: false
            ],
            sealedBackupSensitiveNotesEnabled: true,
            sealedBackupPeriodEnabled: true,
            lastModifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoragePreferences.self, from: data)

        #expect(decoded == original)
    }

    @Test func defaultValuesMatchStorageSpec() {
        let preferences = StoragePreferences()

        #expect(preferences.iCloudSyncEnabled == false)
        #expect(preferences.localBackupExcludedFromiOSBackup == true)
        #expect(preferences.healthKitMasterEnabled == false)
        #expect(preferences.healthKitCapabilityEnabled == StoragePreferences.defaultHealthKitCapabilityEnabled)
        #expect(preferences.sealedBackupSensitiveNotesEnabled == false)
        #expect(preferences.sealedBackupPeriodEnabled == false)
        #expect(preferences.healthKitCapabilityEnabled.values.allSatisfy { $0 == false })
    }

    @Test func twoStoresReadingSameKeychainReturnIdenticalValues() {
        let service = testServiceID()
        defer { KeychainItem.delete(for: .storagePreferences, service: service) }

        let modifiedAt = Date(timeIntervalSince1970: 1_800_000_001)
        let firstStore = StoragePreferencesStore(keychainService: service, now: { modifiedAt })
        firstStore.update { preferences in
            preferences.iCloudSyncEnabled = true
            preferences.healthKitMasterEnabled = true
            preferences.healthKitCapabilityEnabled[HealthCapability.mindfulness.rawValue] = true
            preferences.sealedBackupSensitiveNotesEnabled = true
        }

        let secondStore = StoragePreferencesStore(keychainService: service)

        #expect(secondStore.preferences == firstStore.preferences)
    }

    @Test func updatingBumpsLastModifiedAtAndPersistsImmediately() {
        let service = testServiceID()
        defer { KeychainItem.delete(for: .storagePreferences, service: service) }
        var dates = [
            Date(timeIntervalSince1970: 1_800_000_010),
            Date(timeIntervalSince1970: 1_800_000_020)
        ]
        let store = StoragePreferencesStore(keychainService: service) { dates.removeFirst() }
        let initialModifiedAt = store.preferences.lastModifiedAt

        store.update { preferences in
            preferences.localBackupExcludedFromiOSBackup = false
        }

        #expect(store.preferences.lastModifiedAt > initialModifiedAt)
        #expect(store.preferences.lastModifiedAt == Date(timeIntervalSince1970: 1_800_000_010))

        let reloadedStore = StoragePreferencesStore(keychainService: service)
        #expect(reloadedStore.preferences == store.preferences)
    }

    @Test func deleteKeychainItemThenLoadReturnsDefaultsWithoutCrashing() {
        let service = testServiceID()
        defer { KeychainItem.delete(for: .storagePreferences, service: service) }
        let store = StoragePreferencesStore(keychainService: service)
        store.update { preferences in
            preferences.iCloudSyncEnabled = true
        }

        KeychainItem.delete(for: .storagePreferences, service: service)
        let reloadedStore = StoragePreferencesStore(keychainService: service)

        #expect(reloadedStore.preferences.iCloudSyncEnabled == false)
        #expect(reloadedStore.preferences.localBackupExcludedFromiOSBackup == true)
        #expect(reloadedStore.preferences.healthKitCapabilityEnabled == StoragePreferences.defaultHealthKitCapabilityEnabled)
    }

    @Test func keychainItemUsesAfterFirstUnlockDeviceOnlyAndDoesNotSynchronize() throws {
        let service = testServiceID()
        defer { KeychainItem.delete(for: .storagePreferences, service: service) }
        let store = StoragePreferencesStore(keychainService: service)

        store.update { preferences in
            preferences.sealedBackupPeriodEnabled = true
        }

        let attributes = try #require(keychainAttributes(account: KeychainItem.Account.storagePreferences.rawValue, service: service))
        #expect(attributes[kSecAttrAccessible as String] as? String == kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
        #expect((attributes[kSecAttrSynchronizable as String] as? Bool) != true)
    }

    private func testServiceID() -> String {
        "com.fernlet.storage-preferences.tests.\(UUID().uuidString)"
    }

    private func keychainAttributes(account: String, service: String) -> [String: Any]? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnAttributes as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? [String: Any]
    }
}
