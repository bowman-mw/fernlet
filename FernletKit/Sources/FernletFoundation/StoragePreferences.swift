import Foundation
import Observation

public nonisolated struct StoragePreferences: Codable, Equatable, Sendable {
    public var iCloudSyncEnabled: Bool
    public var localBackupExcludedFromiOSBackup: Bool
    public var healthKitMasterEnabled: Bool
    public var healthKitCapabilityEnabled: [String: Bool]
    public var sealedBackupSensitiveNotesEnabled: Bool
    public var sealedBackupPeriodEnabled: Bool
    /// Set when the user chose "Stop syncing, keep cloud data": sync is off, but a full copy of the day
    /// blob is deliberately left in the user's private CloudKit zone. Nothing else records that choice,
    /// so without this flag `hasAnyCloudCopy` reads false for exactly that user — the delete dialog then
    /// omits the iCloud sentence and the wipe reports COMPLETE while the server copy survives. Cleared
    /// once that copy is actually deleted (the delete-cloud-data flow, or "delete everything").
    public var cloudCopyKept: Bool
    public var lastModifiedAt: Date

    public init(
        iCloudSyncEnabled: Bool = false,
        // Default NOT excluded: local data — especially the sealed store, which has NO cloud recovery —
        // stays recoverable via same-device encrypted backups. A privacy-conscious user can still opt
        // into exclusion via the storage settings toggle.
        localBackupExcludedFromiOSBackup: Bool = false,
        healthKitMasterEnabled: Bool = false,
        healthKitCapabilityEnabled: [String: Bool] = StoragePreferences.defaultHealthKitCapabilityEnabled,
        sealedBackupSensitiveNotesEnabled: Bool = false,
        sealedBackupPeriodEnabled: Bool = false,
        cloudCopyKept: Bool = false,
        lastModifiedAt: Date = Date()
    ) {
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.localBackupExcludedFromiOSBackup = localBackupExcludedFromiOSBackup
        self.healthKitMasterEnabled = healthKitMasterEnabled
        self.healthKitCapabilityEnabled = healthKitCapabilityEnabled
        self.sealedBackupSensitiveNotesEnabled = sealedBackupSensitiveNotesEnabled
        self.sealedBackupPeriodEnabled = sealedBackupPeriodEnabled
        self.cloudCopyKept = cloudCopyKept
        self.lastModifiedAt = lastModifiedAt
    }

    // Tolerant decode: every field falls back to its default when absent. Synthesized `Codable` would
    // THROW on a missing non-optional key, and `StoragePreferencesStore.loadPreferences` maps a throw to
    // fresh defaults — so adding `cloudCopyKept` (or any field) would silently RESET an existing user's
    // stored iCloud / HealthKit / sealed-backup choices on upgrade, since their keychain blob predates the
    // key. A reset `sealedBackup*` flag would even make "delete everything" skip a backup it should erase.
    // Decoding each key `IfPresent` keeps old blobs readable and new keys additive.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? false
        localBackupExcludedFromiOSBackup = try container.decodeIfPresent(Bool.self, forKey: .localBackupExcludedFromiOSBackup) ?? false
        healthKitMasterEnabled = try container.decodeIfPresent(Bool.self, forKey: .healthKitMasterEnabled) ?? false
        healthKitCapabilityEnabled = try container.decodeIfPresent([String: Bool].self, forKey: .healthKitCapabilityEnabled)
            ?? StoragePreferences.defaultHealthKitCapabilityEnabled
        sealedBackupSensitiveNotesEnabled = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupSensitiveNotesEnabled) ?? false
        sealedBackupPeriodEnabled = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupPeriodEnabled) ?? false
        cloudCopyKept = try container.decodeIfPresent(Bool.self, forKey: .cloudCopyKept) ?? false
        lastModifiedAt = try container.decodeIfPresent(Date.self, forKey: .lastModifiedAt) ?? Date()
    }

    /// Whether anything of the user's may be sitting in iCloud — a live sync, a kept copy, or a sealed
    /// backup.
    ///
    /// Deliberately NOT just `iCloudSyncEnabled`: "Stop syncing, keep cloud data" turns sync off while
    /// leaving the server copy in place (recorded by `cloudCopyKept`), so sync-off does not mean
    /// cloud-empty. Used to decide whether the delete dialog may claim it removes the iCloud copy — a
    /// claim that must not be made to someone who has never had one.
    public var hasAnyCloudCopy: Bool {
        hasICloudDayCopy || hasSealedBackup
    }

    /// The day-blob copy in iCloud — a live sync copy, or one kept behind after sync was turned off.
    /// Distinct from `hasSealedBackup` so the delete dialog can claim each independently (a user may have
    /// one without the other, and a single sentence claiming both would be false in one direction).
    public var hasICloudDayCopy: Bool {
        iCloudSyncEnabled || cloudCopyKept
    }

    /// Whether a sealed (encrypted) backup of the sensitive stores may be sitting in iCloud.
    public var hasSealedBackup: Bool {
        sealedBackupSensitiveNotesEnabled || sealedBackupPeriodEnabled
    }

    // Default per-capability map: every HealthKit capability disabled.
    //
    // NOTE: the capability *raw values* below must mirror `HealthCapability`'s
    // cases (defined in the app's HealthKitService, which sits ABOVE this
    // Layer-0 module and therefore cannot be referenced here). This keeps the
    // default byte-identical to the previous
    // `Dictionary(HealthCapability.allCases.map { ($0.rawValue, false) })`.
    // If a `HealthCapability` case is added/removed, update this list to match.
    public static var defaultHealthKitCapabilityEnabled: [String: Bool] {
        [
            "bodyProfile": false,
            "cycleTracking": false,
            "bodyContext": false,
            "workoutLogging": false,
            "activityContext": false,
            "mindfulness": false,
            "intimateLogging": false
        ]
    }
}

@MainActor
@Observable
public final class StoragePreferencesStore {
    public private(set) var preferences: StoragePreferences

    /// The keychain service slot this store reads/writes. Exposed so long-lived
    /// consumers (e.g. HealthKitService) can re-read the live value via
    /// `currentPreferences(service:)` instead of trusting a stale in-memory copy.
    @ObservationIgnored
    public let keychainService: String
    @ObservationIgnored
    private let now: () -> Date
    @ObservationIgnored
    private let encoder = JSONEncoder()
    @ObservationIgnored
    private let decoder = JSONDecoder()

    public init(
        keychainService: String = KeychainItem.storagePreferencesService,
        now: @escaping () -> Date = Date.init
    ) {
        self.keychainService = keychainService
        self.now = now
        preferences = Self.loadPreferences(service: keychainService)
    }

    public func update(_ mutation: (inout StoragePreferences) -> Void) {
        var updated = preferences
        mutation(&updated)
        updated.lastModifiedAt = now()
        preferences = updated
        persist(updated)
    }

    /// Returns storage preferences to their first-launch defaults and removes the persisted keychain
    /// item, so "delete everything" leaves no record of the user's iCloud/backup choices.
    ///
    /// Deletes the keychain row rather than writing defaults over it: a written default is still a
    /// stored value with a `lastModifiedAt`, which is itself a trace of use.
    public func resetToDefaults() {
        KeychainItem.delete(for: .storagePreferences, service: keychainService)
        preferences = StoragePreferences()
    }

    private func persist(_ preferences: StoragePreferences) {
        guard let data = try? encoder.encode(preferences) else { return }
        KeychainItem.store(data, for: .storagePreferences, service: keychainService)
    }

    // nonisolated: pure keychain read + JSON decode with no actor-isolated state, so it is safe
    // to call from any executor (e.g. the non-MainActor CloudKitDataService sync-enabled closure).
    nonisolated public static func currentPreferences(service: String = KeychainItem.storagePreferencesService) -> StoragePreferences {
        loadPreferences(service: service)
    }

    nonisolated private static func loadPreferences(service: String) -> StoragePreferences {
        guard let data = KeychainItem.load(for: .storagePreferences, service: service),
              let decoded = try? JSONDecoder().decode(StoragePreferences.self, from: data) else {
            return StoragePreferences()
        }
        return decoded
    }
}
