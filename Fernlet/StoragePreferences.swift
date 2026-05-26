import Foundation
import Observation

struct StoragePreferences: Codable, Equatable {
    var iCloudSyncEnabled: Bool
    var localBackupExcludedFromiOSBackup: Bool
    var healthKitMasterEnabled: Bool
    var healthKitCapabilityEnabled: [String: Bool]
    var sealedBackupSensitiveNotesEnabled: Bool
    var sealedBackupPeriodEnabled: Bool
    var lastModifiedAt: Date

    init(
        iCloudSyncEnabled: Bool = false,
        localBackupExcludedFromiOSBackup: Bool = true,
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

    static var defaultHealthKitCapabilityEnabled: [String: Bool] {
        Dictionary(uniqueKeysWithValues: HealthCapability.allCases.map { ($0.rawValue, false) })
    }
}

@MainActor
@Observable
final class StoragePreferencesStore {
    private(set) var preferences: StoragePreferences

    @ObservationIgnored
    private let keychainService: String
    @ObservationIgnored
    private let now: () -> Date
    @ObservationIgnored
    private let encoder = JSONEncoder()
    @ObservationIgnored
    private let decoder = JSONDecoder()

    init(
        keychainService: String = KeychainItem.storagePreferencesService,
        now: @escaping () -> Date = Date.init
    ) {
        self.keychainService = keychainService
        self.now = now
        preferences = Self.loadPreferences(service: keychainService)
    }

    func update(_ mutation: (inout StoragePreferences) -> Void) {
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

    private static func loadPreferences(service: String) -> StoragePreferences {
        guard let data = KeychainItem.load(for: .storagePreferences, service: service),
              let decoded = try? JSONDecoder().decode(StoragePreferences.self, from: data) else {
            return StoragePreferences()
        }
        return decoded
    }
}
