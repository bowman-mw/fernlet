import CloudKit
import LocalPersistence
import FernletFoundation
import Foundation
import FernletDomainModel

/// Per-store counts of Fernlet data already present in the user's iCloud private database.
///
/// Produced by ``CloudKitDataService``'s `detectExistingData()` on the rare detection paths
/// (onboarding, the disable-sync flow) and consumed via `hasData` by ``MultiDeviceSyncWarning``
/// to decide whether "another device already wrote cloud data" should be surfaced. Aggregate-blob
/// counts come from the blob's bounded `dayContentSummary`; the per-row stores (custom items,
/// coin ledger, day rows) are counted directly because the blob cannot see them.
public struct ExistingDataSummary: Equatable {
    public var mealLogCount: Int
    public var journalEntryCount: Int
    public var workoutCount: Int
    public var hygieneLogCount: Int
    public var hydrationLogCount: Int
    public var sleepRecordCount: Int
    /// Per-row store record counts. These live in their own CKRecord types (custom clothing items, coin
    /// ledger rows, day rows) and are NOT reflected in the aggregate blob's bounded `dayContentSummary`, so
    /// detection must count them directly — otherwise a second device holding only custom items or coins, or
    /// day data older than the summary's recent window, reads as "no cloud data" and the multi-device
    /// warning never fires.
    public var customItemCount: Int
    public var coinLedgerCount: Int
    public var dayRecordCount: Int

    public init(
        mealLogCount: Int,
        journalEntryCount: Int,
        workoutCount: Int,
        hygieneLogCount: Int,
        hydrationLogCount: Int,
        sleepRecordCount: Int,
        customItemCount: Int = 0,
        coinLedgerCount: Int = 0,
        dayRecordCount: Int = 0
    ) {
        self.mealLogCount = mealLogCount
        self.journalEntryCount = journalEntryCount
        self.workoutCount = workoutCount
        self.hygieneLogCount = hygieneLogCount
        self.hydrationLogCount = hydrationLogCount
        self.sleepRecordCount = sleepRecordCount
        self.customItemCount = customItemCount
        self.coinLedgerCount = coinLedgerCount
        self.dayRecordCount = dayRecordCount
    }

    /// True when any counted store holds at least one record — the signal the multi-device warning keys on.
    public var hasData: Bool {
        mealLogCount > 0 || journalEntryCount > 0 || workoutCount > 0 ||
        hygieneLogCount > 0 || hydrationLogCount > 0 || sleepRecordCount > 0 ||
        customItemCount > 0 || coinLedgerCount > 0 || dayRecordCount > 0
    }

    /// Accumulates another summary's counts into this one (used to fold multiple aggregate records together).
    public mutating func merge(_ other: ExistingDataSummary) {
        mealLogCount += other.mealLogCount
        journalEntryCount += other.journalEntryCount
        workoutCount += other.workoutCount
        hygieneLogCount += other.hygieneLogCount
        hydrationLogCount += other.hydrationLogCount
        sleepRecordCount += other.sleepRecordCount
        customItemCount += other.customItemCount
        coinLedgerCount += other.coinLedgerCount
        dayRecordCount += other.dayRecordCount
    }

    /// A summary with every count at zero — the accumulator seed for detection.
    public static let empty = ExistingDataSummary(
        mealLogCount: 0,
        journalEntryCount: 0,
        workoutCount: 0,
        hygieneLogCount: 0,
        hydrationLogCount: 0,
        sleepRecordCount: 0
    )
}

/// Proof of user intent required before ``CloudKitDataService`` will delete all cloud data.
///
/// The user must either have typed "DELETE" (case-insensitive, whitespace-trimmed) or completed
/// a biometric check within the last 60 seconds of the service's injected clock; anything else
/// makes `deleteAllCloudKitData(confirmation:)` throw
/// ``CloudKitDataServiceError/confirmationRequired``.
public struct DeletionConfirmation {
    public var userTypedConfirmation: String
    public var biometricVerifiedAt: Date?

    public init(userTypedConfirmation: String = "", biometricVerifiedAt: Date? = nil) {
        self.userTypedConfirmation = userTypedConfirmation
        self.biometricVerifiedAt = biometricVerifiedAt
    }
}

/// Outcome of a full CloudKit deletion sweep.
///
/// Returned to the privacy/data settings UI so it can report how many records were removed and
/// warn — when iCloud sync is enabled — that the deletion will propagate to the user's other
/// signed-in devices.
public struct DeletionResult: Equatable {
    public var deletedRecordCount: Int
    public var mayAffectOtherDevices: Bool

    public init(deletedRecordCount: Int, mayAffectOtherDevices: Bool) {
        self.deletedRecordCount = deletedRecordCount
        self.mayAffectOtherDevices = mayAffectOtherDevices
    }
}

/// Failures surfaced by ``CloudKitDataService`` operations, each with a user-facing description.
///
/// `notSignedIn` and `confirmationRequired` are precondition failures the UI can resolve;
/// `cloudKitOperationFailed` wraps any underlying CloudKit error's message so callers present
/// one consistent alert instead of raw `CKError`s.
public enum CloudKitDataServiceError: Error, LocalizedError, Equatable {
    case notSignedIn
    case confirmationRequired
    case cloudKitOperationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn:
            return "Sign in to iCloud to check or delete Fernlet cloud data."
        case .confirmationRequired:
            return "Confirm deletion by typing DELETE or using biometric verification again."
        case .cloudKitOperationFailed(let message):
            return "Fernlet could not finish the iCloud operation: \(message)"
        }
    }
}

/// Seam for querying the iCloud account status.
///
/// `SystemCloudKitAccountProvider` is the production conformer (backed by `CKContainer`);
/// tests inject fakes so the sign-in gate in ``CloudKitDataService`` can be exercised without
/// an iCloud account.
public protocol CloudKitAccountStatusProviding {
    /// The current `CKAccountStatus`; only `.available` lets service operations proceed.
    func accountStatus() async throws -> CKAccountStatus
}

/// Seam over the CloudKit private-database operations ``CloudKitDataService`` needs.
///
/// `SystemCloudKitRecordDatabase` is the production conformer (cursor-following queries,
/// batched deletes against a real `CKDatabase`); tests substitute in-memory fakes so detection,
/// deletion, and sealed-backup logic run without a network or an iCloud account. Methods throw
/// the underlying `CKError` unmapped — the service layers its own error mapping on top.
public protocol CloudKitRecordDatabase {
    /// All record zone IDs present in the database.
    func recordZoneIDs() async throws -> [CKRecordZone.ID]
    /// The IDs of every record of `recordType` in `zoneID` (following pagination to exhaustion).
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID]
    /// Fetches the given records, silently omitting IDs that fail individually.
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord]
    /// Saves the given records with an all-keys save policy.
    func saveRecords(_ records: [CKRecord]) async throws
    /// Deletes the given records (batched to respect CloudKit's per-operation limits).
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws
}

/// Direct-CloudKit service for the operations `NSPersistentCloudKitContainer` can't do: detecting
/// existing cloud data, wiping every Fernlet record from iCloud, and storing sealed backups.
///
/// Three responsibilities, all against the user's private CloudKit database:
/// - **Detection** — `detectExistingData()` counts records of every synced type (the aggregate
///   blob's `dayContentSummary` plus direct counts of the per-row stores) so onboarding and the
///   disable-sync flow can warn when this iCloud account already holds Fernlet data
///   (see ``MultiDeviceSyncWarning``).
/// - **Deletion** — `deleteAllCloudKitData(confirmation:)` is a confirmed, audited sweep over
///   every known record type, including the sealed narrative mirrors, which are named only as
///   string literals so no sealed type is ever imported into this walled module (the S3 wall).
/// - **Sealed backups** — `saveSealedBackup(_:)` and friends read/write the opaque, chunked
///   ``SealedBackupRecord`` ciphertext envelopes; sealing and opening stay app-side with the
///   identity service.
///
/// Collaborators are injected behind ``CloudKitAccountStatusProviding`` and
/// ``CloudKitRecordDatabase`` so every path is testable without CloudKit; the convenience
/// initializer wires the real `CKContainer`-backed conformers. MainActor-isolated by the module
/// default (the `containerIdentifier`/`appZoneID` statics are nonisolated). Every operation logs
/// attempt/completed/failed events to `FernletAuditLog`, and non-service errors are mapped into
/// ``CloudKitDataServiceError/cloudKitOperationFailed(_:)``.
public final class CloudKitDataService {
    /// The app's CloudKit container identifier — the same container ``PersistenceController``
    /// mirrors into and ``HeartDropCloudTransport`` defaults to.
    nonisolated public static let containerIdentifier = "iCloud.MBO.Fernlet"
    /// The default record zone, always scanned alongside every other zone the database reports
    /// (the NSPersistentCloudKitContainer mirror writes into its own zone).
    nonisolated public static let appZoneID = CKRecordZone.default().zoneID
    /// Both spellings of the aggregate blob's record type: the `CD_`-prefixed
    /// NSPersistentCloudKitContainer mirror and the legacy bare name.
    private static let aggregateDatabaseRecordTypes = ["CD_FernletDatabaseRecord", "FernletDatabaseRecord"]
    /// Every record type the full deletion sweep covers — mirrored (`CD_`) and bare spellings,
    /// legacy direct-CloudKit log types, sealed backups, and the sealed narrative mirror named
    /// only as a string literal (S3 wall). Milestone-ledger records are deliberately absent:
    /// milestone rows survive a full data reset by design (see `MilestoneLedgerRepositoring`).
    private static let allRecordTypes = [
        "CD_FernletDatabaseRecord",
        "FernletDatabaseRecord",
        "MealLogRecord",
        "JournalLogRecord",
        "WorkoutLogRecord",
        "HygieneLogRecord",
        "HydrationLogRecord",
        "SleepRecord",
        "SealedBackupRecord",
        // The own-photo escrow route (Phase 5, step 5b). Listed here so "delete my iCloud data"
        // sweeps sealed photo records too — they are the user's own media, not a survivor like the
        // friend wall.
        "SealedPhotoRecord",
        "CD_SavedRecipeRecord",
        "SavedRecipeRecord",
        "CD_CustomItemRecord",
        "CustomItemRecord",
        "CD_CoinLedgerRecord",
        "CoinLedgerRecord",
        "CD_DayRecord",
        "DayRecord",
        "CD_MenstrualNarrative",
        "MenstrualNarrative"
    ]

    private let accountProvider: CloudKitAccountStatusProviding
    private let database: CloudKitRecordDatabase
    private let zoneIDOverride: CKRecordZone.ID?
    private let isCloudKitSyncEnabled: () -> Bool
    private let now: () -> Date
    private let decoder: JSONDecoder

    /// Production initializer: wires the real `CKContainer`-backed account provider and database.
    ///
    /// - Parameters:
    ///   - container: the CloudKit container to operate on (defaults to the app container).
    ///   - isCloudKitSyncEnabled: live sync-preference read used to decide whether a deletion
    ///     may affect other devices; defaults to the nonisolated `StoragePreferencesStore` static.
    ///   - now: clock seam for the biometric-confirmation window (injectable for tests).
    @MainActor
    public init(
        container: CKContainer = CKContainer(identifier: CloudKitDataService.containerIdentifier),
        isCloudKitSyncEnabled: (() -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        self.accountProvider = SystemCloudKitAccountProvider(container: container)
        self.database = SystemCloudKitRecordDatabase(database: container.privateCloudDatabase)
        self.zoneIDOverride = nil
        // Read the live value via the nonisolated static rather than capturing a @MainActor
        // StoragePreferencesStore: this closure is invoked off the main actor (deleteAllCloudKitData),
        // so reading a MainActor-isolated instance property here would be a data race.
        self.isCloudKitSyncEnabled = isCloudKitSyncEnabled ?? { StoragePreferencesStore.currentPreferences().iCloudSyncEnabled }
        self.now = now
        self.decoder = RowPayloadCoders.makeDecoder()
    }

    /// Seam initializer for tests: injects the account provider, database, and a fixed zone.
    public init(
        accountProvider: CloudKitAccountStatusProviding,
        database: CloudKitRecordDatabase,
        zoneID: CKRecordZone.ID = CloudKitDataService.appZoneID,
        isCloudKitSyncEnabled: @escaping () -> Bool,
        now: @escaping () -> Date = Date.init
    ) {
        self.accountProvider = accountProvider
        self.database = database
        self.zoneIDOverride = zoneID
        self.isCloudKitSyncEnabled = isCloudKitSyncEnabled
        self.now = now
        self.decoder = RowPayloadCoders.makeDecoder()
    }

    /// Counts the Fernlet data already in this iCloud account across every zone.
    ///
    /// Reads the aggregate blob's precomputed `dayContentSummary` (falling back to the blob's
    /// legacy `days`/derived tables for un-migrated blobs), then directly counts the per-row
    /// stores the blob can't see. Runs only on the rare onboarding/settings detection paths.
    ///
    /// - Returns: the summary when any data exists, or `nil` when the account is clean.
    /// - Throws: ``CloudKitDataServiceError/notSignedIn`` without an available account, or
    ///   ``CloudKitDataServiceError/cloudKitOperationFailed(_:)`` wrapping any CloudKit error.
    public func detectExistingData() async throws -> ExistingDataSummary? {
        FernletAuditLog.log("cloudkit.detect.attempt")
        do {
            try await ensureSignedIn()
            var summary = ExistingDataSummary.empty

            let zoneIDs = try await appZoneIDs()
            for recordType in Self.aggregateDatabaseRecordTypes {
                let recordIDs = try await recordIDsForExistingType(recordType, in: zoneIDs)
                let records = try await database.records(for: recordIDs)
                for record in records {
                    summary.merge(summaryFromAggregateRecord(record))
                }
            }

            summary.mealLogCount += try await countRecords(type: "MealLogRecord", in: zoneIDs)
            summary.journalEntryCount += try await countRecords(type: "JournalLogRecord", in: zoneIDs)
            summary.workoutCount += try await countRecords(type: "WorkoutLogRecord", in: zoneIDs)
            summary.hygieneLogCount += try await countRecords(type: "HygieneLogRecord", in: zoneIDs)
            summary.hydrationLogCount += try await countRecords(type: "HydrationLogRecord", in: zoneIDs)
            summary.sleepRecordCount += try await countRecords(type: "SleepRecord", in: zoneIDs)

            // Per-row stores the blob summary can't see: custom items and coins can exist with no logged
            // days, and day rows can be older than the summary's bounded window. Count each directly (both
            // the NSPersistentCloudKitContainer `CD_`-mirrored type and the bare spelling) so the warning
            // fires. Runs only on the rare detection path (onboarding / settings), never a hot path.
            //
            // A raw `DayRecord` COUNT is a valid "existing data" signal because the write side no longer
            // creates a row for a content-free day (CoreDataFernletRepository.writeDayRow guards on
            // `hasLoggedContent` and deletes a row whose day becomes empty). So a device that merely launched
            // the app no longer stamps an empty day row that would make every other device read "existing
            // cloud data" — every `DayRecord` here reflects a day the user actually logged something on.
            for type in ["CD_CustomItemRecord", "CustomItemRecord"] {
                summary.customItemCount += try await countRecords(type: type, in: zoneIDs)
            }
            for type in ["CD_CoinLedgerRecord", "CoinLedgerRecord"] {
                summary.coinLedgerCount += try await countRecords(type: type, in: zoneIDs)
            }
            for type in ["CD_DayRecord", "DayRecord"] {
                summary.dayRecordCount += try await countRecords(type: type, in: zoneIDs)
            }

            FernletAuditLog.log("cloudkit.detect.completed", context: [
                "hasData": summary.hasData ? "true" : "false",
                "mealLogs": "\(summary.mealLogCount)",
                "journalEntries": "\(summary.journalEntryCount)",
                "workouts": "\(summary.workoutCount)",
                "hygieneLogs": "\(summary.hygieneLogCount)",
                "hydrationLogs": "\(summary.hydrationLogCount)",
                "sleepRecords": "\(summary.sleepRecordCount)",
                "customItems": "\(summary.customItemCount)",
                "coinLedger": "\(summary.coinLedgerCount)",
                "dayRecords": "\(summary.dayRecordCount)"
            ])
            return summary.hasData ? summary : nil
        } catch let error as CloudKitDataServiceError {
            FernletAuditLog.log("cloudkit.detect.failed", context: ["error": error.auditValue])
            throw error
        } catch {
            let mapped = CloudKitDataServiceError.cloudKitOperationFailed(error.localizedDescription)
            FernletAuditLog.log("cloudkit.detect.failed", context: ["error": mapped.auditValue])
            throw mapped
        }
    }

    /// Deletes every Fernlet record from the private database, across all zones and record types.
    ///
    /// Requires a valid ``DeletionConfirmation`` (typed "DELETE" or a fresh biometric check) and
    /// an available iCloud account. Record IDs are de-duplicated across the `CD_`/bare type
    /// spellings before deletion so a shared record is only counted once.
    ///
    /// - Returns: the count of deleted records and whether other devices may be affected
    ///   (i.e. sync is currently enabled).
    /// - Important: this deletes cloud copies only; local stores are wiped separately by
    ///   ``CoreDataFernletRepository/purgeAllPersistedData()`` and its siblings.
    public func deleteAllCloudKitData(confirmation: DeletionConfirmation) async throws -> DeletionResult {
        FernletAuditLog.log("cloudkit.delete.attempt")
        do {
            try validate(confirmation)
            try await ensureSignedIn()

            let zoneIDs = try await appZoneIDs()
            var recordIDs: [CKRecord.ID] = []
            for recordType in Self.allRecordTypes {
                recordIDs.append(contentsOf: try await recordIDsForExistingType(recordType, in: zoneIDs))
            }
            let uniqueRecordIDs = Array(Dictionary(grouping: recordIDs) { recordID in
                "\(recordID.zoneID.ownerName):\(recordID.zoneID.zoneName):\(recordID.recordName)"
            }.compactMap { $0.value.first })

            if !uniqueRecordIDs.isEmpty {
                try await database.deleteRecords(with: uniqueRecordIDs)
            }

            let result = DeletionResult(
                deletedRecordCount: uniqueRecordIDs.count,
                mayAffectOtherDevices: isCloudKitSyncEnabled()
            )
            FernletAuditLog.log("cloudkit.delete.completed", context: [
                "deletedRecordCount": "\(result.deletedRecordCount)",
                "mayAffectOtherDevices": result.mayAffectOtherDevices ? "true" : "false"
            ])
            return result
        } catch let error as CloudKitDataServiceError {
            FernletAuditLog.log("cloudkit.delete.failed", context: ["error": error.auditValue])
            throw error
        } catch {
            let mapped = CloudKitDataServiceError.cloudKitOperationFailed(error.localizedDescription)
            FernletAuditLog.log("cloudkit.delete.failed", context: ["error": mapped.auditValue])
            throw mapped
        }
    }

    /// Uploads one sealed-backup chunk, writing its ciphertext as a `CKAsset` under the
    /// deterministic record name for its payload type and chunk index. Overwrites any prior
    /// record of the same name (all-keys save).
    public func saveSealedBackup(_ record: SealedBackupRecord) async throws {
        try await ensureSignedIn()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("fernlet-sealed-backup")
        defer {
            // These temp files hold sealed-backup ciphertext; a silent leak into the temporary
            // directory is exactly the best-effort failure worth naming (R7).
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                FernletAuditLog.log("cloudkit.tempCiphertext.cleanupFailed", context: ["stage": "sealedBackup"])
            }
        }
        try record.ciphertext.write(to: fileURL, options: .atomic)

        let cloudRecord = CKRecord(
            recordType: "SealedBackupRecord",
            recordID: sealedBackupRecordID(payloadType: record.payloadType, chunkIndex: record.chunkIndex)
        )
        cloudRecord["payloadType"] = record.payloadType.rawValue as CKRecordValue
        cloudRecord["signingPublicKey"] = record.signingPublicKey as CKRecordValue
        cloudRecord["keyAgreementPublicKey"] = record.keyAgreementPublicKey as CKRecordValue
        cloudRecord["nonce"] = record.nonce as CKRecordValue
        cloudRecord["tag"] = record.tag as CKRecordValue
        cloudRecord["updatedAt"] = record.updatedAt as CKRecordValue
        cloudRecord["chunkIndex"] = record.chunkIndex as CKRecordValue
        cloudRecord["chunkCount"] = record.chunkCount as CKRecordValue
        cloudRecord["generation"] = record.generation as CKRecordValue
        cloudRecord["formatVersion"] = record.formatVersion as CKRecordValue
        // Stamped UNCONDITIONALLY — an empty salt writes an explicit nil, which is not the same thing
        // as omitting the key. CloudKit's `.allKeys` save policy is a per-FIELD update, not a record
        // replace: a key that is absent from the record being saved is left untouched server-side, and
        // assigning nil is the only way to clear one. Omitting it on a v1 write would leave a prior v2
        // generation's 32-byte salt riding on the record and mislabel it. (That protects writes made by
        // THIS build; an older build cannot clear what it does not know about, which is why
        // `SealedBackupCrypto.open` also carries a v1 retry.) `decodeSealedBackup` reads an absent salt
        // as empty, and requires 32 bytes whenever `formatVersion >= 2`.
        cloudRecord["keySalt"] = record.keySalt.isEmpty ? nil : record.keySalt as CKRecordValue
        cloudRecord["encryptedBlob"] = CKAsset(fileURL: fileURL)
        try await database.saveRecords([cloudRecord])
        FernletAuditLog.log("cloudkit.sealedBackup.saved", context: [
            "payloadType": record.payloadType.rawValue,
            "chunkIndex": String(record.chunkIndex),
            "chunkCount": String(record.chunkCount),
            "generation": String(record.generation),
            "formatVersion": String(record.formatVersion)
        ])
    }

    /// Fetches the single head record for a payload (chunk 0). Used for unchunked payloads and as the
    /// entry point for `sealedBackupChunks`.
    public func sealedBackup(payloadType: SealedBackupPayloadType) async throws -> SealedBackupRecord? {
        try await ensureSignedIn()
        let recordID = sealedBackupRecordID(payloadType: payloadType)
        let records: [CKRecord]
        do {
            records = try await database.records(for: [recordID])
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard let record = records.first else { return nil }
        return try decodeSealedBackup(record)
    }

    /// Fetches the full, ordered chunk set for a payload: the head (chunk 0) carries `chunkCount`, then
    /// chunks `1...chunkCount-1` are fetched by their deterministic record IDs. Returns `[]` when no
    /// backup exists. Throws `SealedBackupError.malformedRecord` if the set is incomplete or
    /// inconsistent (a missing chunk, a chunk left over from a differently-sized prior backup, or a
    /// mixed-generation set), so the caller restores all-or-nothing rather than reassembling a corrupt
    /// history. Disagreeing `formatVersion`/`keySalt` values are deliberately *not* fatal here — see
    /// the inline note; AES-GCM in `SealedBackupCrypto.open` is the authority on those.
    public func sealedBackupChunks(payloadType: SealedBackupPayloadType) async throws -> [SealedBackupRecord] {
        guard let head = try await sealedBackup(payloadType: payloadType) else { return [] }
        guard head.chunkCount > 1 else { return [head] }

        let remainingIDs = (1..<head.chunkCount).map {
            sealedBackupRecordID(payloadType: payloadType, chunkIndex: $0)
        }
        let fetched = try await database.records(for: remainingIDs)
        let records = ([head] + (try fetched.map { try decodeSealedBackup($0) }))
            .sorted { $0.chunkIndex < $1.chunkIndex }

        let isContiguous = records.count == head.chunkCount
            && records.enumerated().allSatisfy { $0.offset == $0.element.chunkIndex }
        // Two independent same-generation checks, both required. `chunkCount` catches a set left
        // mixed by a resize (an old larger generation's tail surviving a smaller new write); the
        // `generation` counter catches a same-sized substitution the chunk count cannot see — an
        // attacker splicing chunk 3 of an older backup into the current set. Splicing is exactly
        // what the per-chunk AAD binding cannot stop on its own, because the spliced chunk is
        // itself validly sealed at the same index and count.
        let sameChunkCount = records.allSatisfy { $0.chunkCount == head.chunkCount }
        let sameGeneration = records.allSatisfy { $0.generation == head.generation }
        // NOT gated here: `formatVersion`/`keySalt` agreement across the set. Both are unauthenticated
        // CloudKit fields, and CloudKit merges fields rather than replacing records, so a downlevel
        // writer that grows a set (3 → 4 chunks) leaves stale v2 metadata on indices 0..n-1 and none on
        // the new tail — a set that is entirely, validly v1-sealed but would look "mixed". Rejecting
        // before any decrypt is attempted would brick it. The anti-splice property those two checks
        // were reaching for is already carried by `sameGeneration` plus the per-chunk AAD (a spliced
        // chunk comes from a different generation, and the generation is bound into the AEAD), and a
        // genuinely mismatched salt still fails closed one layer down: `SealedBackupCrypto.open`
        // derives per record and AES-GCM rejects a wrong key. Crypto is the judge, not the metadata.
        guard isContiguous, sameChunkCount, sameGeneration else {
            throw SealedBackupError.malformedRecord
        }
        return records
    }

    /// Deletes a payload's entire backup — head plus every chunk — found by record-name prefix, so a
    /// disable tears down both single-record and multi-record backups.
    public func deleteSealedBackup(payloadType: SealedBackupPayloadType) async throws {
        try await ensureSignedIn()
        try await deleteSealedBackupRecordIDs(payloadType: payloadType, minChunkIndex: 0)
        FernletAuditLog.log("cloudkit.sealedBackup.deleted", context: ["payloadType": payloadType.rawValue])
    }

    /// Prunes only the suffixed chunks at or above `minIndex` (never the head), used after a chunked
    /// upload shrinks to fewer chunks than a prior generation. A no-op when nothing is stale.
    public func deleteSealedBackupChunks(payloadType: SealedBackupPayloadType, withIndexAtLeast minIndex: Int) async throws {
        try await ensureSignedIn()
        try await deleteSealedBackupRecordIDs(payloadType: payloadType, minChunkIndex: max(1, minIndex))
    }

    private func deleteSealedBackupRecordIDs(payloadType: SealedBackupPayloadType, minChunkIndex: Int) async throws {
        let ids = try await sealedBackupRecordIDs(payloadType: payloadType, minChunkIndex: minChunkIndex)
        guard !ids.isEmpty else { return }
        do {
            try await database.deleteRecords(with: ids)
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }

    /// Record IDs belonging to a payload's backup, filtered by chunk index. `minChunkIndex <= 0`
    /// includes the head; `>= 1` returns only suffixed chunks at or above that index. Found by
    /// enumerating `SealedBackupRecord` IDs and matching the deterministic name scheme, since the
    /// chunk count isn't known up front when tearing a backup down.
    private func sealedBackupRecordIDs(payloadType: SealedBackupPayloadType, minChunkIndex: Int) async throws -> [CKRecord.ID] {
        let base = sealedBackupRecordBaseName(payloadType: payloadType)
        let chunkPrefix = "\(base).chunk."
        let zoneIDs = try await appZoneIDs()
        let all = try await recordIDsForExistingType("SealedBackupRecord", in: zoneIDs)
        return all.filter { id in
            let name = id.recordName
            if name == base { return minChunkIndex <= 0 }
            guard name.hasPrefix(chunkPrefix), let index = Int(name.dropFirst(chunkPrefix.count)) else { return false }
            return index >= minChunkIndex
        }
    }

    // MARK: - Own-photo escrow route (Phase 5, step 5b)

    /// Uploads one sealed photo record — a photo body or a corpus manifest — writing its ciphertext
    /// as a `CKAsset` under the deterministic name `sealed-photo.<corpus>.<slot>`. Overwrites any
    /// prior record of the same name (all-keys save).
    ///
    /// The manifest goes through this same path, and therefore the same `CKAsset`, on purpose: a
    /// manifest listing thousands of UUID + hash entries would otherwise hit CloudKit's ~1 MB
    /// inline-field limit exactly when a user has the most to lose.
    public func saveSealedPhoto(_ record: SealedPhotoRecord) async throws {
        try await ensureSignedIn()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("fernlet-sealed-photo")
        defer {
            // Sealed-photo ciphertext — same rule as `saveSealedBackup` (R7): best-effort cleanup
            // still names its failure.
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch {
                FernletAuditLog.log("cloudkit.tempCiphertext.cleanupFailed", context: ["stage": "sealedPhoto"])
            }
        }
        try record.ciphertext.write(to: fileURL, options: .atomic)

        let cloudRecord = CKRecord(
            recordType: "SealedPhotoRecord",
            recordID: sealedPhotoRecordID(corpus: record.corpus, slot: record.slot)
        )
        cloudRecord["corpus"] = record.corpus.rawValue as CKRecordValue
        cloudRecord["slot"] = record.slot.recordNameSuffix as CKRecordValue
        cloudRecord["signingPublicKey"] = record.signingPublicKey as CKRecordValue
        cloudRecord["keyAgreementPublicKey"] = record.keyAgreementPublicKey as CKRecordValue
        cloudRecord["nonce"] = record.nonce as CKRecordValue
        cloudRecord["tag"] = record.tag as CKRecordValue
        cloudRecord["updatedAt"] = record.updatedAt as CKRecordValue
        cloudRecord["generation"] = record.generation as CKRecordValue
        cloudRecord["formatVersion"] = record.formatVersion as CKRecordValue
        cloudRecord["keySalt"] = record.keySalt as CKRecordValue
        cloudRecord["encryptedBlob"] = CKAsset(fileURL: fileURL)
        try await database.saveRecords([cloudRecord])
        FernletAuditLog.log("cloudkit.sealedPhoto.saved", context: [
            "corpus": record.corpus.rawValue,
            "slot": record.slot.recordNameSuffix,
            "generation": String(record.generation)
        ])
    }

    /// Fetches one sealed photo record (a body or the manifest), or nil when it does not exist.
    public func sealedPhoto(corpus: SealedPhotoCorpus, slot: SealedPhotoSlot) async throws -> SealedPhotoRecord? {
        try await ensureSignedIn()
        let recordID = sealedPhotoRecordID(corpus: corpus, slot: slot)
        let records: [CKRecord]
        do {
            records = try await database.records(for: [recordID])
        } catch let error as CKError where error.code == .unknownItem {
            return nil
        }
        guard let record = records.first else { return nil }
        return try decodeSealedPhoto(record)
    }

    /// The photo ids a corpus currently has records for, found by enumerating `SealedPhotoRecord`
    /// IDs and matching the deterministic name scheme (the manifest slot is excluded).
    ///
    /// Used by the upload path to tell "already in the cloud, unchanged" from "listed in a stale
    /// manifest but the body was never written", and by the teardown to find everything to delete.
    public func existingSealedPhotoIDs(corpus: SealedPhotoCorpus) async throws -> Set<UUID> {
        try await ensureSignedIn()
        let ids = try await sealedPhotoRecordIDs(corpus: corpus)
        return Set(ids.compactMap { sealedPhotoSlot(ofRecordNamed: $0.recordName, corpus: corpus)?.photoID })
    }

    /// Deletes one photo's record (best-effort; a missing record is a no-op). The manifest is the
    /// authority on membership, so callers drop the entry from the manifest FIRST — an orphaned
    /// record left by a failed delete is ignored on restore.
    public func deleteSealedPhoto(corpus: SealedPhotoCorpus, id: UUID) async throws {
        try await ensureSignedIn()
        let recordID = sealedPhotoRecordID(corpus: corpus, slot: .photo(id))
        do {
            try await database.deleteRecords(with: [recordID])
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
    }

    /// Tears a whole corpus down — every photo record AND the manifest — found by record-name
    /// prefix, since the id set is not known up front (and must not be trusted to a manifest that
    /// may itself be gone). The delete-all funnel's own-photo escrow leg.
    public func deleteSealedPhotoCorpus(_ corpus: SealedPhotoCorpus) async throws {
        try await ensureSignedIn()
        let ids = try await sealedPhotoRecordIDs(corpus: corpus, includingManifest: true)
        guard !ids.isEmpty else { return }
        do {
            try await database.deleteRecords(with: ids)
        } catch let error as CKError where error.code == .unknownItem {
            return
        }
        FernletAuditLog.log("cloudkit.sealedPhoto.corpusDeleted", context: [
            "corpus": corpus.rawValue,
            "recordCount": String(ids.count)
        ])
    }

    /// Record IDs belonging to a corpus, by the deterministic name scheme. The manifest is included
    /// only when asked for, so the "which bodies exist" query cannot accidentally count it.
    private func sealedPhotoRecordIDs(
        corpus: SealedPhotoCorpus,
        includingManifest: Bool = false
    ) async throws -> [CKRecord.ID] {
        let zoneIDs = try await appZoneIDs()
        let all = try await recordIDsForExistingType("SealedPhotoRecord", in: zoneIDs)
        return all.filter { id in
            guard let slot = sealedPhotoSlot(ofRecordNamed: id.recordName, corpus: corpus) else { return false }
            return slot == .manifest ? includingManifest : true
        }
    }

    private func sealedPhotoRecordBaseName(corpus: SealedPhotoCorpus) -> String {
        "sealed-photo.\(corpus.rawValue)"
    }

    /// Deterministic record name for a slot: `sealed-photo.<corpus>.<uuid|manifest>`.
    private func sealedPhotoRecordID(corpus: SealedPhotoCorpus, slot: SealedPhotoSlot) -> CKRecord.ID {
        let name = "\(sealedPhotoRecordBaseName(corpus: corpus)).\(slot.recordNameSuffix)"
        return CKRecord.ID(recordName: name, zoneID: zoneIDOverride ?? Self.appZoneID)
    }

    /// The slot a record name denotes within `corpus`, or nil when the name belongs to another
    /// corpus or is not a recognizable slot at all (unrecognized names are ignored, never guessed).
    private func sealedPhotoSlot(ofRecordNamed name: String, corpus: SealedPhotoCorpus) -> SealedPhotoSlot? {
        let prefix = "\(sealedPhotoRecordBaseName(corpus: corpus))."
        guard name.hasPrefix(prefix) else { return nil }
        return SealedPhotoSlot(recordNameSuffix: String(name.dropFirst(prefix.count)))
    }

    /// Decodes a `SealedPhotoRecord` CKRecord, failing closed on anything missing or malformed.
    ///
    /// Stricter than `decodeSealedBackup` in one deliberate way: this record type was born at format
    /// 2, so there is no legacy shape to tolerate — an absent or short salt, or a version below 2,
    /// is a malformed record rather than a v1 record. Also cross-checks the stored `corpus`/`slot`
    /// fields against the record's NAME: those fields are what the AAD binds, so a record renamed on the
    /// server must not decode as if it belonged where it now sits.
    private func decodeSealedPhoto(_ record: CKRecord) throws -> SealedPhotoRecord {
        guard let rawCorpus = record["corpus"] as? String,
              let corpus = SealedPhotoCorpus(rawValue: rawCorpus),
              let rawSlot = record["slot"] as? String,
              let slot = SealedPhotoSlot(recordNameSuffix: rawSlot),
              let signingPublicKey = record["signingPublicKey"] as? Data,
              let keyAgreementPublicKey = record["keyAgreementPublicKey"] as? Data,
              let nonce = record["nonce"] as? Data,
              let tag = record["tag"] as? Data,
              let updatedAt = record["updatedAt"] as? Date,
              let generation = record["generation"] as? Int64,
              let asset = record["encryptedBlob"] as? CKAsset,
              let fileURL = asset.fileURL,
              let ciphertext = try? Data(contentsOf: fileURL) else {
            throw SealedBackupError.malformedRecord
        }
        guard sealedPhotoSlot(ofRecordNamed: record.recordID.recordName, corpus: corpus) == slot else {
            throw SealedBackupError.malformedRecord
        }
        let formatVersion = (record["formatVersion"] as? Int) ?? 0
        let keySalt = (record["keySalt"] as? Data) ?? Data()
        guard formatVersion >= 2, keySalt.count == 32 else {
            throw SealedBackupError.malformedRecord
        }
        return SealedPhotoRecord(
            corpus: corpus,
            slot: slot,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: keyAgreementPublicKey,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            updatedAt: updatedAt,
            generation: generation,
            formatVersion: formatVersion,
            keySalt: keySalt
        )
    }

    /// Gate on every operation: throws ``CloudKitDataServiceError/notSignedIn`` unless the
    /// account status is `.available`.
    private func ensureSignedIn() async throws {
        let status = try await accountProvider.accountStatus()
        guard status == .available else { throw CloudKitDataServiceError.notSignedIn }
    }

    private func sealedBackupRecordBaseName(payloadType: SealedBackupPayloadType) -> String {
        "sealed-backup.\(payloadType.rawValue)"
    }

    /// Deterministic record name for a chunk: the bare base for the head (`chunkIndex == 0`) so
    /// single-record payloads keep their original name, and a `.chunk.<index>` suffix otherwise.
    private func sealedBackupRecordID(payloadType: SealedBackupPayloadType, chunkIndex: Int = 0) -> CKRecord.ID {
        let base = sealedBackupRecordBaseName(payloadType: payloadType)
        let name = chunkIndex == 0 ? base : "\(base).chunk.\(chunkIndex)"
        return CKRecord.ID(recordName: name, zoneID: zoneIDOverride ?? Self.appZoneID)
    }

    private func decodeSealedBackup(_ record: CKRecord) throws -> SealedBackupRecord {
        guard let rawPayloadType = record["payloadType"] as? String,
              let payloadType = SealedBackupPayloadType(rawValue: rawPayloadType),
              let signingPublicKey = record["signingPublicKey"] as? Data,
              let keyAgreementPublicKey = record["keyAgreementPublicKey"] as? Data,
              let nonce = record["nonce"] as? Data,
              let tag = record["tag"] as? Data,
              let updatedAt = record["updatedAt"] as? Date,
              let asset = record["encryptedBlob"] as? CKAsset,
              let fileURL = asset.fileURL,
              let ciphertext = try? Data(contentsOf: fileURL) else {
            throw SealedBackupError.malformedRecord
        }
        // Chunk fields are absent on records written before chunking existed; default to a
        // single-record payload (chunk 0 of 1) so those still decode.
        let chunkIndex = (record["chunkIndex"] as? Int) ?? 0
        let chunkCount = (record["chunkCount"] as? Int) ?? 1
        // Bound the two chunk fields HERE, where the untrusted CloudKit values enter (R3/R5): they
        // drive `sealedBackupChunks`' record-ID fan-out, so an out-of-range `chunkCount` would
        // allocate one CKRecord.ID per unit before any crypto runs. The existing all-or-nothing
        // `malformedRecord` policy already covers the rejection.
        guard chunkCount >= 1, chunkCount <= SealedBackupRecord.maxChunkCount,
              chunkIndex >= 0, chunkIndex < chunkCount else {
            throw SealedBackupError.malformedRecord
        }
        // `generation` is REQUIRED and deliberately has no default — unlike the chunk fields above.
        // It is the rollback defense, so a record without one cannot be authenticated against a
        // generation-bound AAD and must fail closed rather than silently decode as generation 0
        // (which would let a pre-fix record be replayed forever). There is no compatibility cost:
        // the field shipped before the app had users, so no record in the wild lacks it. A dev
        // container holding pre-fix records will report `malformedRecord` — delete those records.
        guard let generation = record["generation"] as? Int64 else {
            throw SealedBackupError.malformedRecord
        }
        // Record format (hardening #4). Absent field → version 1: that is exactly what every record
        // written before v2 existed looks like, and v1 must keep opening byte-identically. From v2 up,
        // the salt is load-bearing (it derives the key), so it is REQUIRED and must be exactly 32 bytes
        // — anything else fails closed rather than deriving a wrong-but-plausible key, following the
        // `generation` precedent above.
        // A v1 record has NO salt by definition, so any bytes sitting in that field are ignored rather
        // than carried onto the in-memory record: a downlevel writer cannot clear a field it never
        // sets, so a former-v2 record rewritten by an old build keeps its stale salt server-side.
        // Zeroing here is what stops that stale value from leaking into chunk-set comparisons.
        let formatVersion = (record["formatVersion"] as? Int) ?? 1
        let keySalt = formatVersion >= 2 ? ((record["keySalt"] as? Data) ?? Data()) : Data()
        if formatVersion >= 2 {
            guard keySalt.count == 32 else { throw SealedBackupError.malformedRecord }
        }
        return SealedBackupRecord(
            payloadType: payloadType,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: keyAgreementPublicKey,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            updatedAt: updatedAt,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            generation: generation,
            formatVersion: formatVersion,
            keySalt: keySalt
        )
    }

    /// Enforces the deletion-confirmation rule: typed "DELETE", or a biometric verification no
    /// older than 60 seconds (and not in the future) by the injected clock.
    private func validate(_ confirmation: DeletionConfirmation) throws {
        let typed = confirmation.userTypedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.uppercased() == "DELETE" { return }
        if let verifiedAt = confirmation.biometricVerifiedAt,
           now().timeIntervalSince(verifiedAt) <= 60,
           verifiedAt <= now() {
            return
        }
        throw CloudKitDataServiceError.confirmationRequired
    }

    private func appZoneIDs() async throws -> [CKRecordZone.ID] {
        if let zoneIDOverride { return [zoneIDOverride] }
        return uniqueZoneIDs([Self.appZoneID] + (try await database.recordZoneIDs()))
    }

    private func uniqueZoneIDs(_ zoneIDs: [CKRecordZone.ID]) -> [CKRecordZone.ID] {
        var seen = Set<String>()
        var result: [CKRecordZone.ID] = []
        for zoneID in zoneIDs {
            let key = "\(zoneID.ownerName):\(zoneID.zoneName)"
            if seen.insert(key).inserted {
                result.append(zoneID)
            }
        }
        return result
    }

    private func countRecords(type: String, in zoneIDs: [CKRecordZone.ID]) async throws -> Int {
        try await recordIDsForExistingType(type, in: zoneIDs).count
    }

    private func recordIDsForExistingType(_ recordType: String, in zoneIDs: [CKRecordZone.ID]) async throws -> [CKRecord.ID] {
        var recordIDs: [CKRecord.ID] = []
        for zoneID in zoneIDs {
            do {
                recordIDs.append(contentsOf: try await database.recordIDs(matching: recordType, in: zoneID))
            } catch let error as CKError where error.code == .unknownItem {
                // "This record type was never created in this zone" is a legitimate skip — but the
                // same code is raised when a zone vanishes mid-sweep, which during
                // `deleteAllCloudKitData` means records were NOT enumerated for deletion. Name it.
                FernletAuditLog.log("cloudkit.recordType.absent", context: [
                    "type": recordType,
                    "zone": zoneID.zoneName
                ])
            }
        }
        return recordIDs
    }

    private func summaryFromAggregateRecord(_ record: CKRecord) -> ExistingDataSummary {
        guard let payload = Self.aggregatePayloadData(from: record) else { return .empty }
        let localDatabase: LocalFernletDatabase
        do {
            localDatabase = try decoder.decode(LocalFernletDatabase.self, from: payload)
        } catch {
            // A blob that will not decode is NOT "this account holds no Fernlet data" — that answer
            // drives `MultiDeviceSyncWarning.anotherDeviceHasData`, so silently returning `.empty`
            // produces the DANGEROUS outcome (no warning, devices diverge). Name the failure (R7).
            FernletAuditLog.log("cloudkit.detect.blobDecodeFailed", context: [
                "errorType": "\(type(of: error))"
            ])
            return .empty
        }

        // After the per-row split's Stage B the blob's `days` are cleared and a precomputed
        // dayContentSummary carries the counts, so detection stays a single blob read instead of scanning
        // thousands of per-row DayRecord CKRecords. An older or un-migrated blob still has populated `days`
        // (handled below for backward compat); a genuinely empty blob yields zero counts either way.
        if localDatabase.days.isEmpty {
            let summary = localDatabase.dayContentSummary
            return ExistingDataSummary(
                mealLogCount: summary.mealCount,
                journalEntryCount: summary.journalCount,
                workoutCount: summary.workoutCount,
                hygieneLogCount: summary.hygieneCount,
                hydrationLogCount: summary.hydrationCount,
                sleepRecordCount: summary.sleepCount
            )
        }

        // Backward compat: meals/journals/workouts/sleep fall back to the derived log tables (rebuilt from
        // rows). Hygiene/hydration have no derived table, so they reflect the blob's recent window only.
        // The per-day roll-up is the shared `DayContentSummary(days:)` definition (identical counting rules
        // to what detection used before the blob's days were cleared) so this can't drift from the summary
        // the primary branch consumes.
        let dayValues = Array(localDatabase.days.values)
        let daySummary = DayContentSummary(days: dayValues)
        return ExistingDataSummary(
            mealLogCount: localDatabase.mealLogs.isEmpty ? daySummary.mealCount : localDatabase.mealLogs.count,
            journalEntryCount: localDatabase.journalLogs.isEmpty ? daySummary.journalCount : localDatabase.journalLogs.count,
            workoutCount: localDatabase.workoutLogs.isEmpty ? daySummary.workoutCount : localDatabase.workoutLogs.count,
            hygieneLogCount: daySummary.hygieneCount,
            hydrationLogCount: daySummary.hydrationCount,
            sleepRecordCount: localDatabase.dailyLogs.isEmpty ? daySummary.sleepCount : localDatabase.dailyLogs.reduce(0) { $0 + ($1.sleepHours == nil ? 0 : 1) }
        )
    }

    /// Extracts the aggregate database blob from a CKRecord. NSPersistentCloudKitContainer
    /// mirrors the Core Data `payloadData` attribute under a `CD_` prefix, and stores it as a
    /// CKAsset once it exceeds CloudKit's ~1 MB inline-field limit (which a full health
    /// database routinely does). Reading the bare `payloadData` as inline `Data` therefore
    /// always returned nil, making detection report "no cloud data" even when the cloud was
    /// full of the user's data. Try both key spellings and both storage forms.
    private static func aggregatePayloadData(from record: CKRecord) -> Data? {
        for key in ["CD_payloadData", "payloadData"] {
            guard let value = record[key] else { continue }
            if let data = value as? Data {
                return data
            }
            if let asset = value as? CKAsset,
               let url = asset.fileURL,
               let data = try? Data(contentsOf: url) {
                return data
            }
        }
        return nil
    }
}

private extension CloudKitDataServiceError {
    var auditValue: String {
        switch self {
        case .notSignedIn: "notSignedIn"
        case .confirmationRequired: "confirmationRequired"
        case .cloudKitOperationFailed: "cloudKitOperationFailed"
        }
    }
}

/// Production ``CloudKitAccountStatusProviding``: bridges `CKContainer.accountStatus` into async/await.
///
/// Private to this file; tests never see it — they inject their own conformer instead.
private final class SystemCloudKitAccountProvider: CloudKitAccountStatusProviding {
    private let container: CKContainer

    init(container: CKContainer) {
        self.container = container
    }

    func accountStatus() async throws -> CKAccountStatus {
        try await withCheckedThrowingContinuation { continuation in
            container.accountStatus { status, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: status)
                }
            }
        }
    }
}

/// Production ``CloudKitRecordDatabase`` backed by a real `CKDatabase`.
///
/// Wraps the callback-based CloudKit operations in checked continuations: queries follow
/// pagination cursors recursively until exhausted, saves use an all-keys policy, and deletes run
/// in batches of 400 to stay under CloudKit's per-operation record limit.
private final class SystemCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let database: CKDatabase

    init(database: CKDatabase) {
        self.database = database
    }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] {
        try await withCheckedThrowingContinuation { continuation in
            database.fetchAllRecordZones { zones, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: zones?.map(\.zoneID) ?? [])
                }
            }
        }
    }

    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        let query = CKQuery(recordType: recordType, predicate: NSPredicate(value: true))
        let operation = CKQueryOperation(query: query)
        operation.zoneID = zoneID
        operation.resultsLimit = CKQueryOperation.maximumResults
        return try await recordIDs(from: operation)
    }

    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        guard !recordIDs.isEmpty else { return [] }
        return try await withCheckedThrowingContinuation { continuation in
            let operation = CKFetchRecordsOperation(recordIDs: recordIDs)
            var records: [CKRecord] = []
            operation.perRecordResultBlock = { _, result in
                if case .success(let record) = result {
                    records.append(record)
                }
            }
            operation.fetchRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume(returning: records)
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws {
        guard !recordIDs.isEmpty else { return }
        let batchSize = 400
        for batchStart in stride(from: 0, to: recordIDs.count, by: batchSize) {
            let batch = Array(recordIDs[batchStart..<min(batchStart + batchSize, recordIDs.count)])
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: batch)
                operation.savePolicy = .changedKeys
                operation.modifyRecordsResultBlock = { result in
                    switch result {
                    case .success:
                        continuation.resume()
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
                self.database.add(operation)
            }
        }
    }

    func saveRecords(_ records: [CKRecord]) async throws {
        guard !records.isEmpty else { return }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
            operation.savePolicy = .allKeys
            operation.modifyRecordsResultBlock = { result in
                switch result {
                case .success:
                    continuation.resume()
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }

    /// Named upper bound on cursor follows for one query (R2/R3).
    ///
    /// The cursor chain used to be followed by a self-call from inside the result callback, which had
    /// no page cap at all: a server that keeps returning a non-nil cursor grew both the accumulated
    /// id array and a chain of live suspended continuations without limit. The sibling
    /// `HeartDropCloudTransport.maxPagesPerChunk` bounds exactly this shape; so does this.
    private static let maxQueryPages = 200

    /// Follows the query's cursor chain up to ``maxQueryPages`` pages, accumulating record IDs.
    /// A truncated sweep is LOGGED, never silent — the remaining records stay on the server.
    private func recordIDs(from operation: CKQueryOperation) async throws -> [CKRecord.ID] {
        var all: [CKRecord.ID] = []
        var next: CKQueryOperation? = operation
        var pages = 0
        while let current = next, pages < Self.maxQueryPages {
            let (ids, cursor) = try await page(current)
            all += ids
            pages += 1
            next = cursor.map { CKQueryOperation(cursor: $0) }
        }
        if next != nil {
            FernletAuditLog.log("cloudkit.query.truncated", context: [
                "pages": "\(pages)",
                "records": "\(all.count)"
            ])
        }
        return all
    }

    /// One query page: its matched record IDs plus the server's continuation cursor (nil at the end).
    private func page(_ operation: CKQueryOperation) async throws -> ([CKRecord.ID], CKQueryOperation.Cursor?) {
        try await withCheckedThrowingContinuation { continuation in
            var recordIDs: [CKRecord.ID] = []
            operation.recordMatchedBlock = { recordID, result in
                if case .success = result {
                    recordIDs.append(recordID)
                }
            }
            operation.queryResultBlock = { result in
                switch result {
                case .success(let cursor):
                    continuation.resume(returning: (recordIDs, cursor))
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
}
