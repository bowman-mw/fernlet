import Foundation
import Observation
import Security

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
    ///
    /// - Important: The TYPE default (and the absent-key decode default) must stay `false` forever:
    ///   `StoragePreferencesStore.loadPreferences` maps any decode fallback to this default, so a
    ///   `true` here would silently flip every EXISTING user to excluded — a surprise loss of their
    ///   sealed-store recovery. The security-hardening Phase-6 default flip for FRESH installs rides
    ///   the app's launch gate (`BackupExclusionLaunchGate`) plus ``backupExclusionChoiceMade``,
    ///   never this default.
    public var localBackupExcludedFromiOSBackup: Bool
    /// Whether ``localBackupExcludedFromiOSBackup`` has actually been DECIDED — by the user (the
    /// Privacy & Data toggle or the one-time launch prompt) or by the fresh-install default path.
    ///
    /// The tri-state that fixes "a stored default and a chosen false are indistinguishable": with
    /// only the bool, an existing user who deliberately stays included looks identical to one who
    /// was never asked, so no default flip could ever be applied safely. `false` means "never
    /// decided" (the app's launch gate may run); `true` means the question is settled and the
    /// launch gate must never prompt again. Additive and tolerantly decoded (`?? false`) like every
    /// other field, so pre-Phase-6 blobs decode with their exclusion value byte-for-byte unchanged.
    public var backupExclusionChoiceMade: Bool
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
    /// Whether the user's OWN photos (meal, recipe and gym-progress pictures plus the sealed
    /// progress index) are backed up to iCloud through the per-photo escrow route
    /// (security-hardening Phase 5, step 5b).
    ///
    /// ONE flag for all three corpora on purpose: they are internal record namespaces, not three
    /// consent questions — "back up my photos" is a single decision the user makes about their own
    /// pictures. Off by default like every other sealed-backup flag, and the enable dialog carries
    /// the honest size disclosure (own corpora have no count cap, so a heavy user's backup can reach
    /// hundreds of megabytes of their iCloud quota).
    public var sealedBackupOwnPhotosEnabled: Bool
    /// Set when the sealed PERIOD backup still needs re-uploading under a newly-adopted escrow key —
    /// the escrow adopt (or a re-seal) ran while period tracking was hidden, so the cloud chunk is
    /// still sealed to the replaced key. Persisted (not session-only) so the promised remedy —
    /// "un-hide period tracking, then this device will re-upload it" — survives a relaunch. Cleared
    /// when a period re-seal actually succeeds, when the backup is turned off/deleted, and by
    /// "delete everything".
    public var sealedBackupPeriodReuploadDeferred: Bool
    /// Set when the sealed JOURNAL backup still owes an upload: the user turned it on from Settings
    /// while the Private tab held no unlock (so the content key that pages the narratives was nil), an
    /// escrow adopt could not re-seal it, or the local store was still empty because this device has
    /// not restored yet. Same contract as ``sealedBackupPeriodReuploadDeferred`` — persisted so the
    /// obligation survives a relaunch, cleared only by a re-seal that actually reached the cloud, by
    /// turning the backup off, and by "delete everything".
    public var sealedBackupJournalReuploadDeferred: Bool
    /// Set when the sealed INTIMACY backup still owes an upload, for the same three reasons as
    /// ``sealedBackupJournalReuploadDeferred`` plus one more: intimacy tracking was hidden, so the
    /// reconcile could not page the (gated) log store. Un-hiding discharges it.
    public var sealedBackupIntimacyReuploadDeferred: Bool
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
        sealedBackupOwnPhotosEnabled: Bool = false,
        sealedBackupPeriodReuploadDeferred: Bool = false,
        sealedBackupJournalReuploadDeferred: Bool = false,
        sealedBackupIntimacyReuploadDeferred: Bool = false,
        cloudCopyKept: Bool = false,
        // Default false = "never decided", NOT "keep included": the launch gate reads false as
        // permission to run (fresh installs adopt excluded; existing installs get the one-time
        // prompt). A true default would mark every fresh install as already-decided and the gate
        // would never set the excluded default it exists to set.
        backupExclusionChoiceMade: Bool = false,
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
        self.sealedBackupOwnPhotosEnabled = sealedBackupOwnPhotosEnabled
        self.sealedBackupPeriodReuploadDeferred = sealedBackupPeriodReuploadDeferred
        self.sealedBackupJournalReuploadDeferred = sealedBackupJournalReuploadDeferred
        self.sealedBackupIntimacyReuploadDeferred = sealedBackupIntimacyReuploadDeferred
        self.cloudCopyKept = cloudCopyKept
        self.backupExclusionChoiceMade = backupExclusionChoiceMade
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
        sealedBackupOwnPhotosEnabled = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupOwnPhotosEnabled) ?? false
        sealedBackupPeriodReuploadDeferred = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupPeriodReuploadDeferred) ?? false
        sealedBackupJournalReuploadDeferred = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupJournalReuploadDeferred) ?? false
        sealedBackupIntimacyReuploadDeferred = try container.decodeIfPresent(Bool.self, forKey: .sealedBackupIntimacyReuploadDeferred) ?? false
        cloudCopyKept = try container.decodeIfPresent(Bool.self, forKey: .cloudCopyKept) ?? false
        // Phase-6 pin: the DEFAULT FLIP MUST NOT RIDE THIS DECODE. Both this `?? false` and the
        // `localBackupExcludedFromiOSBackup` decode above stay false-for-absent forever, so an
        // existing user's blob decodes with their exclusion value unchanged; only the launch gate —
        // fresh-install detection or an explicit prompt answer — may set either field.
        backupExclusionChoiceMade = try container.decodeIfPresent(Bool.self, forKey: .backupExclusionChoiceMade) ?? false
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
    /// - Important: EVERY sealed-backup flag must be OR'd in here — the four chunked payload types
    ///   AND the own-photo escrow route, which is its own record namespace rather than a
    ///   `SealedBackupPayloadType` case. This is what the delete dialog reads to decide whether it
    ///   may truthfully claim to remove an iCloud copy; a flag missing from this expression is a
    ///   backup "delete everything" would leave behind.
    public var hasSealedBackup: Bool {
        sealedBackupSensitiveNotesEnabled
            || sealedBackupPeriodEnabled
            || sealedBackupJournalEnabled
            || sealedBackupIntimacyEnabled
            || sealedBackupOwnPhotosEnabled
    }

    /// Copies every sealed-backup ENABLE flag from `other`, leaving everything else untouched.
    ///
    /// Exists so "delete everything" can carry the flags across its preference reset when a backup
    /// delete FAILED — they are how a retry (or the next wipe) finds the surviving CKRecords again, and
    /// clearing them would make a transient network failure permanent by making `hasSealedBackup` read
    /// false. Deliberately assigned HERE, adjacent to `hasSealedBackup`, so the two enumerations of the
    /// payload flags sit together: a new payload that is added to one and forgotten in the other is the
    /// exact regression this method exists to prevent (the journal/intimacy flags were dropped from the
    /// open-coded copy in `ContentView` when Phase 3 added them).
    ///
    /// The re-upload DEFERRAL flags are deliberately not copied: a wipe deletes the backup those
    /// obligations point at, and the local data behind them, so the promised re-upload can never happen.
    public mutating func copySealedBackupFlags(from other: StoragePreferences) {
        sealedBackupSensitiveNotesEnabled = other.sealedBackupSensitiveNotesEnabled
        sealedBackupPeriodEnabled = other.sealedBackupPeriodEnabled
        sealedBackupJournalEnabled = other.sealedBackupJournalEnabled
        sealedBackupIntimacyEnabled = other.sealedBackupIntimacyEnabled
        sealedBackupOwnPhotosEnabled = other.sealedBackupOwnPhotosEnabled
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

/// Four-way state of the persisted ``StoragePreferences`` keychain blob, as distinguished by
/// ``StoragePreferencesStore/persistedBlobState(service:)``.
///
/// Exists for callers that must NOT collapse "no blob" and "the keychain could not be read" into
/// one answer the way the tolerant ``StoragePreferencesStore/currentPreferences(service:)`` does.
/// The blob is stored `AfterFirstUnlockThisDeviceOnly`, so a process launched before first device
/// unlock (iOS prewarming after a reboot, a background relaunch) reads `errSecInteractionNotAllowed`
/// — a transient failure that must never be treated as "never stored". The Phase-6
/// backup-exclusion launch gate classifies over this state: it defers on ``unreadable`` and treats
/// a present-but-corrupt blob (``undecodable``) as prior-use evidence with default values.
public nonisolated enum StoragePreferencesBlobState: Sendable {
    /// A blob exists and decoded; carries the decoded live value.
    case decoded(StoragePreferences)
    /// No keychain row exists — genuinely never stored (fresh install, or reset by
    /// "delete everything"). Safe to treat as first-launch defaults.
    case absent
    /// A row exists but its JSON no longer decodes. Readers should treat the VALUES as fresh
    /// defaults (matching `loadPreferences`' fallback), but the row's presence still evidences
    /// that this install stored preferences before.
    case undecodable
    /// The keychain read itself failed (any non-`errSecItemNotFound` status — most notably
    /// `errSecInteractionNotAllowed` before first unlock). The blob's existence is UNKNOWN:
    /// callers must not classify, prompt, or write over it — fail closed and retry later.
    case unreadable
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
/// That tolerance also applies to the ONE-SHOT `init` load: a process launched before first
/// device unlock (prewarming) holds fresh defaults for its whole lifetime unless something calls
/// ``refreshFromPersistedBlob()`` — launch-time writers must do so (after checking
/// ``persistedBlobState(service:)``) or their `update` persists the defaults over the real blob.
/// ``resetToDefaults()`` deletes the keychain row outright rather than writing defaults, so
/// "delete everything" leaves no `lastModifiedAt` trace of use.
@MainActor
@Observable
public final class StoragePreferencesStore {
    /// The current preferences value; mutate only through ``update(_:)`` so persistence and the
    /// `lastModifiedAt` stamp stay in step.
    public private(set) var preferences: StoragePreferences

    /// The `OSStatus` of the most recent keychain write or reset that did NOT succeed, else `nil`.
    ///
    /// ``preferences`` is published before it is persisted, so without this a failed write (most
    /// often `errSecInteractionNotAllowed`, before the device's first unlock) would leave Settings
    /// showing a privacy choice that never reached the keychain. Observed by settings surfaces that
    /// need to tell the user the choice did not stick; cleared by the next successful write.
    public private(set) var lastPersistError: OSStatus?

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
    ///
    /// R7: the delete's `OSStatus` is checked, not dropped — a failed `SecItemDelete` leaves the row
    /// (with its `lastModifiedAt` trace of use) behind while the wipe reports complete, so it lands
    /// in the audit log and in ``lastPersistError``.
    public func resetToDefaults() {
        let status = KeychainItem.deleteReportingStatus(for: .storagePreferences, service: keychainService)
        if status == errSecSuccess {
            lastPersistError = nil
        } else {
            FernletAuditLog.log("storagePreferences.resetFailed", context: ["status": "\(status)"])
            lastPersistError = status
        }
        preferences = StoragePreferences()
    }

    /// Persists `preferences` to the keychain, recording any failure in ``lastPersistError``.
    ///
    /// R7: neither the encode error nor the keychain `OSStatus` is swallowed. The in-memory value is
    /// already published when this runs, so a silent write failure (`errSecInteractionNotAllowed`
    /// before first unlock, `errSecNotAvailable`) would leave Settings showing a privacy choice that
    /// was never stored — and the sealed-backup flags decide what "delete everything" erases.
    private func persist(_ preferences: StoragePreferences) {
        do {
            let data = try encoder.encode(preferences)
            let status = KeychainItem.store(data, for: .storagePreferences, service: keychainService)
            guard status == errSecSuccess else {
                FernletAuditLog.log("storagePreferences.persistFailed", context: ["status": "\(status)"])
                lastPersistError = status
                return
            }
            lastPersistError = nil
        } catch {
            FernletAuditLog.log("storagePreferences.encodeFailed", context: ["error": String(describing: error)])
            lastPersistError = errSecParam
        }
    }

    /// Replaces the in-memory ``preferences`` with the live persisted value — a re-read, never a
    /// write (nothing is persisted and `lastModifiedAt` is not stamped).
    ///
    /// Exists because the in-memory copy is loaded exactly once, in `init`, at process launch: a
    /// process launched before first device unlock (iOS prewarming, a background relaunch) cannot
    /// read the `AfterFirstUnlockThisDeviceOnly` blob then, so its copy is fresh defaults for the
    /// rest of the process — and any later ``update(_:)`` would persist those defaults over the
    /// user's real choices. Launch-time consumers that WRITE through this store (the Phase-6
    /// `BackupExclusionLaunchGate`) call this first so their mutation lands on the live values.
    ///
    /// - Important: Call only when the keychain is known readable (check
    ///   ``persistedBlobState(service:)`` first): the underlying load still collapses a read
    ///   failure to defaults, so refreshing blind would replace a good in-memory copy with them.
    public func refreshFromPersistedBlob() {
        preferences = Self.loadPreferences(service: keychainService)
    }

    /// Reads the live persisted preferences straight from the keychain, bypassing any in-memory
    /// copy; returns fresh defaults when nothing is stored (or the blob fails to decode).
    ///
    /// `nonisolated`: pure keychain read + JSON decode with no actor-isolated state, so it is safe
    /// to call from any executor (e.g. the non-MainActor CloudKitDataService sync-enabled closure).
    nonisolated public static func currentPreferences(service: String = KeychainItem.storagePreferencesService) -> StoragePreferences {
        loadPreferences(service: service)
    }

    /// Reads the live persisted blob distinguishing all four outcomes — decoded / absent /
    /// undecodable / unreadable — via `KeychainItem.loadDistinguishingAbsence`, unlike
    /// ``currentPreferences(service:)``, which tolerantly collapses every failure to fresh
    /// defaults. See ``StoragePreferencesBlobState`` for what each case licenses a caller to do;
    /// built for the Phase-6 backup-exclusion launch gate, whose one-time prompt (and prompted
    /// write) must fail closed rather than run over a pre-first-unlock read failure.
    ///
    /// `nonisolated`: pure keychain read + JSON decode, callable from any executor.
    nonisolated public static func persistedBlobState(service: String = KeychainItem.storagePreferencesService) -> StoragePreferencesBlobState {
        switch KeychainItem.loadDistinguishingAbsence(
            account: KeychainItem.Account.storagePreferences.rawValue,
            service: service
        ) {
        case .found(let data):
            guard let decoded = try? JSONDecoder().decode(StoragePreferences.self, from: data) else {
                return .undecodable
            }
            return .decoded(decoded)
        case .absent:
            return .absent
        case .unreadable:
            return .unreadable
        }
    }

    nonisolated private static func loadPreferences(service: String) -> StoragePreferences {
        guard let data = KeychainItem.load(for: .storagePreferences, service: service),
              let decoded = try? JSONDecoder().decode(StoragePreferences.self, from: data) else {
            return StoragePreferences()
        }
        return decoded
    }
}
