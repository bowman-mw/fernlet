import Foundation
import FernletFoundation
import Security
import Testing
import FernletDomainModel
import HealthKitGateway
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
            sealedBackupJournalEnabled: true,
            sealedBackupIntimacyEnabled: true,
            sealedBackupPeriodReuploadDeferred: true,
            sealedBackupJournalReuploadDeferred: true,
            sealedBackupIntimacyReuploadDeferred: true,
            backupExclusionChoiceMade: true,
            lastModifiedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(StoragePreferences.self, from: data)

        #expect(decoded == original)
    }

    /// A keychain blob written before `cloudCopyKept` existed (i.e. the key is absent) must still decode,
    /// defaulting the new flag to false and PRESERVING the user's other choices. Synthesized `Codable`
    /// throws on a missing non-optional key, which `loadPreferences` maps to fresh defaults — silently
    /// wiping the user's iCloud / sealed-backup settings on upgrade. The custom tolerant decoder prevents it.
    @Test func decodingLegacyBlobWithoutCloudCopyKeptPreservesOtherFields() throws {
        let legacyJSON = """
        {
            "iCloudSyncEnabled": true,
            "localBackupExcludedFromiOSBackup": false,
            "healthKitMasterEnabled": true,
            "healthKitCapabilityEnabled": {},
            "sealedBackupSensitiveNotesEnabled": true,
            "sealedBackupPeriodEnabled": true,
            "lastModifiedAt": 700000000
        }
        """
        let decoded = try JSONDecoder().decode(StoragePreferences.self, from: Data(legacyJSON.utf8))

        #expect(decoded.iCloudSyncEnabled == true)
        #expect(decoded.sealedBackupSensitiveNotesEnabled == true)
        #expect(decoded.sealedBackupPeriodEnabled == true)
        #expect(decoded.cloudCopyKept == false)
        // Same tolerance for the (newer still) period re-upload deferral: absent key → default false,
        // everything else preserved.
        #expect(decoded.sealedBackupPeriodReuploadDeferred == false)
        // Same again for the two per-payload deferrals added alongside the Phase-3 payloads.
        #expect(decoded.sealedBackupJournalReuploadDeferred == false)
        #expect(decoded.sealedBackupIntimacyReuploadDeferred == false)
        // …and for the Phase-3 journal/intimacy backup flags. A non-tolerant decode of these would
        // throw on EVERY existing user's blob, resetting their iCloud and backup choices on upgrade —
        // and a reset `sealedBackup*` flag makes "delete everything" skip a backup it should erase.
        #expect(decoded.sealedBackupJournalEnabled == false)
        #expect(decoded.sealedBackupIntimacyEnabled == false)
        // The user's real, still-enabled backups keep `hasSealedBackup` true, so the delete dialog
        // still promises (and performs) the iCloud removal.
        #expect(decoded.hasSealedBackup)
        // And for the Phase-6 `backupExclusionChoiceMade` tri-state: absent key → false ("never
        // decided"), so the launch gate may run for this user — never true, which would silently
        // mark the question settled.
        #expect(decoded.backupExclusionChoiceMade == false)
    }

    /// The Phase-6 no-silent-flip pin. Flipping the sealed store to default-excluded must ride the
    /// launch gate's fresh-install path — NEVER the tolerant decode: a pre-Phase-6 blob (no
    /// `backupExclusionChoiceMade` key) must decode with its stored
    /// `localBackupExcludedFromiOSBackup` value byte-for-byte unchanged, in BOTH directions. An
    /// absent-key default of `true` on either field would silently flip every existing included
    /// user to excluded — a surprise loss of their sealed-store device-backup recovery.
    @Test func decodingLegacyBlobNeverFlipsTheStoredBackupExclusionValue() throws {
        // An existing user who deliberately stayed included (or was never asked): stays included.
        let includedJSON = """
        {
            "iCloudSyncEnabled": false,
            "localBackupExcludedFromiOSBackup": false,
            "lastModifiedAt": 700000000
        }
        """
        let included = try JSONDecoder().decode(StoragePreferences.self, from: Data(includedJSON.utf8))
        #expect(included.localBackupExcludedFromiOSBackup == false)
        #expect(included.backupExclusionChoiceMade == false)

        // An existing user who opted into exclusion via the toggle: stays excluded, and the gate
        // still sees "no recorded choice" so it can record one without prompting.
        let excludedJSON = """
        {
            "localBackupExcludedFromiOSBackup": true,
            "lastModifiedAt": 700000000
        }
        """
        let excluded = try JSONDecoder().decode(StoragePreferences.self, from: Data(excludedJSON.utf8))
        #expect(excluded.localBackupExcludedFromiOSBackup == true)
        #expect(excluded.backupExclusionChoiceMade == false)

        // A blob with BOTH keys (written by this build) round-trips both values exactly.
        let decidedJSON = """
        {
            "localBackupExcludedFromiOSBackup": false,
            "backupExclusionChoiceMade": true,
            "lastModifiedAt": 700000000
        }
        """
        let decided = try JSONDecoder().decode(StoragePreferences.self, from: Data(decidedJSON.utf8))
        #expect(decided.localBackupExcludedFromiOSBackup == false)
        #expect(decided.backupExclusionChoiceMade == true)
    }

    /// `hasSealedBackup` is what the delete dialog reads to decide whether it may truthfully claim to
    /// remove an iCloud copy, and what gates the wipe's per-payload delete loop. A payload missing from
    /// that expression is a backup "delete everything" would silently leave behind — so each flag is
    /// asserted to be individually sufficient.
    @Test func everySealedBackupFlagIndependentlyMakesHasSealedBackupTrue() {
        #expect(StoragePreferences().hasSealedBackup == false)

        let flags: [(String, (inout StoragePreferences) -> Void)] = [
            ("sensitiveNotes", { $0.sealedBackupSensitiveNotesEnabled = true }),
            ("periodData", { $0.sealedBackupPeriodEnabled = true }),
            ("journalNarratives", { $0.sealedBackupJournalEnabled = true }),
            ("intimacyLogs", { $0.sealedBackupIntimacyEnabled = true })
        ]
        for (name, enable) in flags {
            var preferences = StoragePreferences()
            enable(&preferences)
            #expect(preferences.hasSealedBackup, "\(name) is not OR'd into hasSealedBackup")
            #expect(preferences.hasAnyCloudCopy, "\(name) is not reflected in hasAnyCloudCopy")
        }
    }

    /// "Delete everything" carries the sealed-backup ENABLE flags across its preference reset when a
    /// backup delete failed — they are how a retry (or a later wipe) finds the surviving CKRecords.
    /// Copying them one-by-one at the call site is what dropped the journal and intimacy flags when
    /// Phase 3 added them, so the copy lives here, next to `hasSealedBackup`, and this test pins that
    /// EVERY payload flag survives — including any added later.
    @Test func copySealedBackupFlagsCarriesEveryPayloadFlag() {
        var source = StoragePreferences()
        source.sealedBackupSensitiveNotesEnabled = true
        source.sealedBackupPeriodEnabled = true
        source.sealedBackupJournalEnabled = true
        source.sealedBackupIntimacyEnabled = true

        var reset = StoragePreferences(iCloudSyncEnabled: true)
        reset.copySealedBackupFlags(from: source)

        #expect(reset.sealedBackupSensitiveNotesEnabled)
        #expect(reset.sealedBackupPeriodEnabled)
        #expect(reset.sealedBackupJournalEnabled)
        #expect(reset.sealedBackupIntimacyEnabled)
        #expect(reset.hasSealedBackup, "a flag left behind is a backup the wipe can never find again")
        // Only the backup flags travel — the reset's job is to return everything else to first launch.
        #expect(reset.healthKitMasterEnabled == false)
        #expect(reset.iCloudSyncEnabled, "the caller's own iCloud choice is untouched")

        // A successful delete copies nothing, so the flags clear and `hasSealedBackup` reads false.
        let cleared = StoragePreferences(iCloudSyncEnabled: true)
        #expect(cleared.hasSealedBackup == false)
    }

    @Test func defaultValuesMatchStorageSpec() {
        let preferences = StoragePreferences()

        #expect(preferences.iCloudSyncEnabled == false)
        // The TYPE default stays NOT-excluded forever: the tolerant decode and every load-failure
        // fallback resolve to this value, so `true` here would silently flip existing users. The
        // Phase-6 fresh-install excluded default is applied by `BackupExclusionLaunchGate` (which
        // also sets `backupExclusionChoiceMade`), never by this initializer.
        #expect(preferences.localBackupExcludedFromiOSBackup == false)
        // "Never decided" is the default — the launch gate's permission to run.
        #expect(preferences.backupExclusionChoiceMade == false)
        #expect(preferences.healthKitMasterEnabled == false)
        #expect(preferences.healthKitCapabilityEnabled == StoragePreferences.defaultHealthKitCapabilityEnabled)
        #expect(preferences.sealedBackupSensitiveNotesEnabled == false)
        #expect(preferences.sealedBackupPeriodEnabled == false)
        #expect(preferences.sealedBackupJournalEnabled == false)
        #expect(preferences.sealedBackupIntimacyEnabled == false)
        #expect(preferences.sealedBackupPeriodReuploadDeferred == false)
        #expect(preferences.sealedBackupJournalReuploadDeferred == false)
        #expect(preferences.sealedBackupIntimacyReuploadDeferred == false)
        #expect(preferences.hasSealedBackup == false)
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
        #expect(reloadedStore.preferences.localBackupExcludedFromiOSBackup == false)
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
