import Foundation
import Observation

/// The user's storage and privacy choices: iCloud sync, backup exclusion, HealthKit capability
/// toggles, and the sealed-backup flags.
///
/// This value is the single record of where the user's data is allowed to live. It is persisted
/// as JSON in the keychain (never in the synced blob) by ``StoragePreferencesStore``, and
/// consulted by repository selection (Core Data + iCloud vs. local JSON), the HealthKit gateway,
/// the sealed-backup coordinator, and the "delete everything" flow — the derived flags
/// ``hasAnyCloudCopy`` / ``hasICloudDayCopy`` / ``hasSealedBackup`` decide what the destructive
/// dialogs may truthfully claim to remove.
///
/// - Important: Decoding is deliberately tolerant — the custom ``init(from:)`` falls back to each
///   field's default when its key is absent. A synthesized decode would throw on the first key an
///   app update adds, and `StoragePreferencesStore.loadPreferences` maps a throw to fresh
///   defaults, silently resetting every stored choice (and making "delete everything" skip a
///   sealed backup it should erase). New fields must always decode `IfPresent` with a default.
public nonisolated struct StoragePreferences: Codable, Equatable, Sendable {
    /// Whether the day blob syncs to the user's private CloudKit zone (the Core Data + iCloud
    /// repository is selected when true).
    public var iCloudSyncEnabled: Bool
    /// Whether the local store files are excluded from iOS device backups. Defaults to false so
    /// the sealed store — which has no cloud recovery — stays recoverable via encrypted backups.
    public var localBackupExcludedFromiOSBackup: Bool
    /// The master HealthKit switch; when false, every capability is off regardless of the
    /// per-capability map.
    public var healthKitMasterEnabled: Bool
    /// Per-capability HealthKit toggles, keyed by `HealthCapability` raw values (defined in
    /// HealthKitGateway, above this layer — hence the string keys).
    public var healthKitCapabilityEnabled: [String: Bool]
    /// Whether the sealed (encrypted) backup of sensitive notes (journal/worry narratives) is
    /// uploaded to iCloud.
    public var sealedBackupSensitiveNotesEnabled: Bool
    /// Whether the sealed (encrypted) backup of period/intimacy data is uploaded to iCloud.
    public var sealedBackupPeriodEnabled: Bool
    /// Whether the sealed (encrypted) backup of JOURNAL narratives is uploaded to iCloud.
    ///
    /// Its own toggle rather than a rider on ``sealedBackupSensitiveNotesEnabled``: that payload is the
    /// Tier-2 behavioral memories, which are derived summaries, while this is the user's own journal
    /// text — a different consent question, and the per-type opt-in is the promise the Privacy & Data
    /// screen makes.
    public var sealedBackupJournalEnabled: Bool
    /// Whether the sealed (encrypted) backup of INTIMACY logs is uploaded to iCloud.
    ///
    /// Separate from ``sealedBackupPeriodEnabled`` for the same reason the surfaces are separately
    /// hideable: someone may want their cycle history recoverable and their intimacy notes not.
    public var sealedBackupIntimacyEnabled: Bool
    /// Set when the sealed PERIOD backup still needs re-uploading under a newly-adopted escrow key —
    /// the escrow adopt (or a re-seal) ran while period tracking was hidden, so the cloud chunk is
    /// still sealed to the replaced key. Persisted (not session-only) so the promised remedy —
    /// "un-hide period tracking, then this device will re-upload it" — survives a relaunch. Cleared
    /// when a period re-seal actually succeeds, when the backup is turned off/deleted, and by
    /// "delete everything".
    public var sealedBackupPeriodReuploadDeferred: Bool
    /// Set when the user chose "Stop syncing, keep cloud data": sync is off, but a full copy of the day
    /// blob is deliberately left in the user's private CloudKit zone. Nothing else records that choice,
    /// so without this flag `hasAnyCloudCopy` reads false for exactly that user — the delete dialog then
    /// omits the iCloud sentence and the wipe reports COMPLETE while the server copy survives. Cleared
    /// once that copy is actually deleted (the delete-cloud-data flow, or "delete everything").
    public var cloudCopyKept: Bool
    /// Timestamp of the last mutation, stamped by ``StoragePreferencesStore/update(_:)``.
    public var lastModifiedAt: Date

    /// Creates preferences; every parameter defaults to its first-launch value (sync off,
    /// HealthKit off, no sealed backups, local data included in device backups).
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
        sealedBackupJournalEnabled: Bool = false,
        sealedBackupIntimacyEnabled: Bool = false,
        sealedBackupPeriodReuploadDeferred: Bool = false,
        cloudCopyKept: Bool = false,
        lastModifiedAt: Date = Date()
    ) {
        self.iCloudSyncEnabled = iCloudSyncEnabled
        self.localBackupExcludedFromiOSBackup = localBackupExcludedFromiOSBackup
        self.healthKitMasterEnabled = healthKitMasterEnabled
        self.healthKitCapabilityEnabled = healthKitCapabilityEnabled
        self.sealedBackupSensitiveNotesEnabled = sealedBackupSensitiveNotesEnabled
        self.sealedBackupPeriodEnabled = sealedBackupPeriodEnabled
        self.sealedBackupJournalEnabled = sealedBackupJournalEnabled
        self.sealedBackupIntimacyEnabled = sealedBackupIntimacyEnabled
        self.sealedBackupPeriodReuploadDeferred = sealedBackupPeriodReuploadDeferred
        self.cloudCopyKept = cloudCopyKept
        self.lastModifiedAt = lastModifiedAt
    }

    /// Tolerant decode: every field falls back to its default when absent.
    ///
    /// Synthesized `Codable` would
    /// THROW on a missing non-optional key, and `StoragePreferencesStore.loadPreferences` maps a throw to
    /// fresh defaults — so adding `cloudCopyKept` (or any field) would silently RESET an existing user's
    /// stored iCloud / HealthKit / sealed-backup choices on upgrade, since their keychain blob predates the
    /// key. A reset `sealedBackup*` flag would even make "delete everything" skip a backup it should erase.
    /// Decoding each key `IfPresent` keeps old blobs readable and new keys additive.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        iCloudSyncEnabled = try container.decodeIfPresent(Bool.self, forKey: .iCloudSyncEnabled) ?? false
        localBackupExcludedFromiOSBackup = try container.decodeIfPresent(Bool.self, forKey: .localBackupExcludedFromiOSBackup) ?? false
        healthKitMasterEnabled = try container.decodeIfPresent(Bool.self, forKey: .healthKitMasterEnabled) ?? false
        healthKitCapabilityEnabled = try container.decodeIfPresent([String: Bool].self, forKey: .healthKitCapabilityEnabled)
            ?? StoragePreferences.defaultHealthKitCapabilityEnabled
        sealedBackupSensitiveNotesEnabled = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupSensitiveNotesEnabled) ?? false
        sealedBackupPeriodEnabled = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupPeriodEnabled) ?? false
        sealedBackupJournalEnabled = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupJournalEnabled) ?? false
        sealedBackupIntimacyEnabled = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupIntimacyEnabled) ?? false
        sealedBackupPeriodReuploadDeferred = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupPeriodReuploadDeferred) ?? false
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
    ///
    /// - Important: EVERY sealed-backup payload flag must be OR'd in here. This is what the delete
    ///   dialog reads to decide whether it may truthfully claim to remove an iCloud copy; a payload
    ///   missing from this expression is a backup "delete everything" would leave behind.
    public var hasSealedBackup: Bool {
        sealedBackupSensitiveNotesEnabled
            || sealedBackupPeriodEnabled
            || sealedBackupJournalEnabled
            || sealedBackupIntimacyEnabled
    }

    /// Default per-capability map: every HealthKit capability disabled.
    ///
    /// - Important: The capability *raw values* below must mirror `HealthCapability`'s
    ///   cases (defined in HealthKitGateway's HealthKitService, which sits ABOVE this
    ///   Layer-0 module and therefore cannot be referenced here). This keeps the
    ///   default byte-identical to the previous
    ///   `Dictionary(HealthCapability.allCases.map { ($0.rawValue, false) })`.
    ///   If a `HealthCapability` case is added/removed, update this list to match.
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

/// The observable owner of the persisted ``StoragePreferences``, backed by the keychain.
///
/// The app's single writer for storage choices: settings and onboarding surfaces mutate through
/// ``update(_:)``, which stamps `lastModifiedAt` and persists the JSON-encoded value to the
/// keychain slot named by ``keychainService``. Storing in the keychain — device-protected and
/// outside the synced blob — keeps the record of the user's privacy choices from traveling
/// through the very channels it governs.
///
/// `@MainActor` `@Observable`: SwiftUI settings views observe ``preferences`` directly.
/// Long-lived non-main consumers (`CloudKitDataService`'s sync-enabled closure,
/// `HealthKitService`) must not trust a stale in-memory copy; they re-read the live value via the
/// `nonisolated` ``currentPreferences(service:)``, a pure keychain read + JSON decode. Any load
/// failure (missing or undecodable blob) yields fresh defaults — see the tolerant-decode note on
/// ``StoragePreferences/init(from:)`` for why that fallback makes additive fields mandatory.
/// ``resetToDefaults()`` deletes the keychain row outright rather than writing defaults, so
/// "delete everything" leaves no `lastModifiedAt` trace of use.
@MainActor
@Observable
public final class StoragePreferencesStore {
    /// The current preferences value; mutate only through ``update(_:)`` so persistence and the
    /// `lastModifiedAt` stamp stay in step.
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

    /// Creates a store reading its initial value from `keychainService`; `now` is injectable so
    /// tests can pin the `lastModifiedAt` stamp.
    public init(
        keychainService: String = KeychainItem.storagePreferencesService,
        now: @escaping () -> Date = Date.init
    ) {
        self.keychainService = keychainService
        self.now = now
        preferences = Self.loadPreferences(service: keychainService)
    }

    /// Applies `mutation` to a copy of the current preferences, stamps `lastModifiedAt`, then
    /// publishes and persists the result to the keychain in one step.
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

    /// Reads the live persisted preferences straight from the keychain, bypassing any in-memory
    /// copy; returns fresh defaults when nothing is stored (or the blob fails to decode).
    ///
    /// `nonisolated`: pure keychain read + JSON decode with no actor-isolated state, so it is safe
    /// to call from any executor (e.g. the non-MainActor CloudKitDataService sync-enabled closure).
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
