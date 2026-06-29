import Foundation
import Observation

public nonisolated struct StoragePreferences: Codable, Equatable, Sendable {
    public var iCloudSyncEnabled: Bool
    public var localBackupExcludedFromiOSBackup: Bool
    public var healthKitMasterEnabled: Bool
    public var healthKitCapabilityEnabled: [String: Bool]
    public var sealedBackupSensitiveNotesEnabled: Bool
    public var sealedBackupPeriodEnabled: Bool
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
        lastModifiedAt: Date = Date()
    ) {
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.localBackupExcludedFromiOSBackup = localBackupExcludedFromiOSBackup
        self.healthKitMasterEnabled = healthKitMasterEnabled
        self.healthKitCapabilityEnabled = healthKitCapabilityEnabled
        self.sealedBackupSensitiveNotesEnabled = sealedBackupSensitiveNotesEnabled
        self.sealedBackupPeriodEnabled = sealedBackupPeriodEnabled
        self.lastModifiedAt = lastModifiedAt
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
