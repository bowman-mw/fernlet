import CloudKit
import LocalPersistence
import FernletFoundation
import Foundation
import FernletDomainModel

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

    public var hasData: Bool {
        mealLogCount > 0 || journalEntryCount > 0 || workoutCount > 0 ||
        hygieneLogCount > 0 || hydrationLogCount > 0 || sleepRecordCount > 0 ||
        customItemCount > 0 || coinLedgerCount > 0 || dayRecordCount > 0
    }

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

    public static let empty = ExistingDataSummary(
        mealLogCount: 0,
        journalEntryCount: 0,
        workoutCount: 0,
        hygieneLogCount: 0,
        hydrationLogCount: 0,
        sleepRecordCount: 0
    )
}

public struct DeletionConfirmation {
    public var userTypedConfirmation: String
    public var biometricVerifiedAt: Date?

    public init(userTypedConfirmation: String = "", biometricVerifiedAt: Date? = nil) {
        self.userTypedConfirmation = userTypedConfirmation
        self.biometricVerifiedAt = biometricVerifiedAt
    }
}

public struct DeletionResult: Equatable {
    public var deletedRecordCount: Int
    public var mayAffectOtherDevices: Bool

    public init(deletedRecordCount: Int, mayAffectOtherDevices: Bool) {
        self.deletedRecordCount = deletedRecordCount
        self.mayAffectOtherDevices = mayAffectOtherDevices
    }
}

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

public protocol CloudKitAccountStatusProviding {
    func accountStatus() async throws -> CKAccountStatus
}

public protocol CloudKitRecordDatabase {
    func recordZoneIDs() async throws -> [CKRecordZone.ID]
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID]
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord]
    func saveRecords(_ records: [CKRecord]) async throws
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws
}

public final class CloudKitDataService {
    nonisolated public static let containerIdentifier = "iCloud.MBO.Fernlet"
    nonisolated public static let appZoneID = CKRecordZone.default().zoneID
    private static let aggregateDatabaseRecordTypes = ["CD_FernletDatabaseRecord", "FernletDatabaseRecord"]
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
        self.decoder = Self.makeDecoder()
    }

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
        self.decoder = Self.makeDecoder()
    }

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

    public func saveSealedBackup(_ record: SealedBackupRecord) async throws {
        try await ensureSignedIn()
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("fernlet-sealed-backup")
        defer { try? FileManager.default.removeItem(at: fileURL) }
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
        cloudRecord["encryptedBlob"] = CKAsset(fileURL: fileURL)
        try await database.saveRecords([cloudRecord])
        FernletAuditLog.log("cloudkit.sealedBackup.saved", context: [
            "payloadType": record.payloadType.rawValue,
            "chunkIndex": String(record.chunkIndex),
            "chunkCount": String(record.chunkCount)
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
    /// inconsistent (a missing chunk, or a chunk left over from a differently-sized prior backup), so
    /// the caller restores all-or-nothing rather than reassembling a corrupt history.
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
        let sameGeneration = records.allSatisfy { $0.chunkCount == head.chunkCount }
        guard isContiguous, sameGeneration else { throw SealedBackupError.malformedRecord }
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
        return SealedBackupRecord(
            payloadType: payloadType,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: keyAgreementPublicKey,
            nonce: nonce,
            ciphertext: ciphertext,
            tag: tag,
            updatedAt: updatedAt,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
    }

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
            }
        }
        return recordIDs
    }

    private func summaryFromAggregateRecord(_ record: CKRecord) -> ExistingDataSummary {
        guard let payload = Self.aggregatePayloadData(from: record),
              let localDatabase = try? decoder.decode(LocalFernletDatabase.self, from: payload) else {
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
        let dayValues = Array(localDatabase.days.values)
        return ExistingDataSummary(
            mealLogCount: localDatabase.mealLogs.isEmpty ? dayValues.reduce(0) { $0 + $1.meals.count } : localDatabase.mealLogs.count,
            journalEntryCount: localDatabase.journalLogs.isEmpty ? dayValues.reduce(0) { $0 + $1.journals.count } : localDatabase.journalLogs.count,
            workoutCount: localDatabase.workoutLogs.isEmpty ? dayValues.reduce(0) { $0 + $1.workouts.count } : localDatabase.workoutLogs.count,
            hygieneLogCount: dayValues.reduce(0) { $0 + $1.hygiene.count },
            hydrationLogCount: dayValues.reduce(0) { $0 + ($1.bottleCount > 0 ? 1 : 0) },
            sleepRecordCount: localDatabase.dailyLogs.isEmpty ? dayValues.reduce(0) { $0 + ($1.sleep == nil ? 0 : 1) } : localDatabase.dailyLogs.reduce(0) { $0 + ($1.sleepHours == nil ? 0 : 1) }
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

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
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

    private func recordIDs(from operation: CKQueryOperation) async throws -> [CKRecord.ID] {
        try await withCheckedThrowingContinuation { continuation in
            var recordIDs: [CKRecord.ID] = []
            operation.recordMatchedBlock = { recordID, result in
                if case .success = result {
                    recordIDs.append(recordID)
                }
            }
            operation.queryResultBlock = { [weak self] result in
                switch result {
                case .success(let cursor):
                    guard let cursor, let self else {
                        continuation.resume(returning: recordIDs)
                        return
                    }
                    Task {
                        do {
                            recordIDs.append(contentsOf: try await self.recordIDs(from: CKQueryOperation(cursor: cursor)))
                            continuation.resume(returning: recordIDs)
                        } catch {
                            continuation.resume(throwing: error)
                        }
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }
            database.add(operation)
        }
    }
}
