import CloudKit
import Foundation

struct ExistingDataSummary: Equatable {
    var mealLogCount: Int
    var journalEntryCount: Int
    var workoutCount: Int
    var hygieneLogCount: Int
    var hydrationLogCount: Int
    var sleepRecordCount: Int

    var hasData: Bool {
        mealLogCount > 0 || journalEntryCount > 0 || workoutCount > 0 ||
        hygieneLogCount > 0 || hydrationLogCount > 0 || sleepRecordCount > 0
    }

    mutating func merge(_ other: ExistingDataSummary) {
        mealLogCount += other.mealLogCount
        journalEntryCount += other.journalEntryCount
        workoutCount += other.workoutCount
        hygieneLogCount += other.hygieneLogCount
        hydrationLogCount += other.hydrationLogCount
        sleepRecordCount += other.sleepRecordCount
    }

    static let empty = ExistingDataSummary(
        mealLogCount: 0,
        journalEntryCount: 0,
        workoutCount: 0,
        hygieneLogCount: 0,
        hydrationLogCount: 0,
        sleepRecordCount: 0
    )
}

struct DeletionConfirmation {
    var userTypedConfirmation: String
    var biometricVerifiedAt: Date?

    init(userTypedConfirmation: String = "", biometricVerifiedAt: Date? = nil) {
        self.userTypedConfirmation = userTypedConfirmation
        self.biometricVerifiedAt = biometricVerifiedAt
    }
}

struct DeletionResult: Equatable {
    var deletedRecordCount: Int
    var mayAffectOtherDevices: Bool
}

enum CloudKitDataServiceError: Error, LocalizedError, Equatable {
    case notSignedIn
    case confirmationRequired
    case cloudKitOperationFailed(String)

    var errorDescription: String? {
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

protocol CloudKitAccountStatusProviding {
    func accountStatus() async throws -> CKAccountStatus
}

protocol CloudKitRecordDatabase {
    func recordZoneIDs() async throws -> [CKRecordZone.ID]
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID]
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord]
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws
}

final class CloudKitDataService {
    nonisolated private static let containerIdentifier = "iCloud.MBO.Fernlet"
    private static let appZoneID = CKRecordZone.default().zoneID
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
    init(
        container: CKContainer = CKContainer(identifier: CloudKitDataService.containerIdentifier),
        isCloudKitSyncEnabled: (() -> Bool)? = nil,
        now: @escaping () -> Date = Date.init
    ) {
        let storagePreferences = StoragePreferencesStore().preferences
        self.accountProvider = SystemCloudKitAccountProvider(container: container)
        self.database = SystemCloudKitRecordDatabase(database: container.privateCloudDatabase)
        self.zoneIDOverride = nil
        self.isCloudKitSyncEnabled = isCloudKitSyncEnabled ?? { storagePreferences.iCloudSyncEnabled }
        self.now = now
        self.decoder = Self.makeDecoder()
    }

    init(
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

    func detectExistingData() async throws -> ExistingDataSummary? {
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

            FernletAuditLog.log("cloudkit.detect.completed", context: [
                "hasData": summary.hasData ? "true" : "false",
                "mealLogs": "\(summary.mealLogCount)",
                "journalEntries": "\(summary.journalEntryCount)",
                "workouts": "\(summary.workoutCount)",
                "hygieneLogs": "\(summary.hygieneLogCount)",
                "hydrationLogs": "\(summary.hydrationLogCount)",
                "sleepRecords": "\(summary.sleepRecordCount)"
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

    func deleteAllCloudKitData(confirmation: DeletionConfirmation) async throws -> DeletionResult {
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

    private func ensureSignedIn() async throws {
        let status = try await accountProvider.accountStatus()
        guard status == .available else { throw CloudKitDataServiceError.notSignedIn }
    }

    private func validate(_ confirmation: DeletionConfirmation) throws {
        let typed = confirmation.userTypedConfirmation.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty { return }
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
        guard let payload = record["payloadData"] as? Data,
              let localDatabase = try? decoder.decode(LocalFernletDatabase.self, from: payload) else {
            return .empty
        }

        let dayValues = Array(localDatabase.days.values)
        return ExistingDataSummary(
            mealLogCount: localDatabase.mealLogs.isEmpty ? dayValues.reduce(0) { $0 + $1.meals.count } : localDatabase.mealLogs.count,
            journalEntryCount: localDatabase.journalLogs.isEmpty ? dayValues.reduce(0) { $0 + $1.journals.count } : localDatabase.journalLogs.count,
            workoutCount: localDatabase.workoutLogs.isEmpty ? dayValues.reduce(0) { $0 + $1.workouts.count } : localDatabase.workoutLogs.count,
            hygieneLogCount: dayValues.reduce(0) { $0 + $1.hygiene.count },
            hydrationLogCount: dayValues.reduce(0) { $0 + ($1.bottleCount > 0 ? 1 : 0) },
            sleepRecordCount: dayValues.reduce(0) { $0 + ($1.sleep == nil ? 0 : 1) }
        )
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
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let operation = CKModifyRecordsOperation(recordsToSave: nil, recordIDsToDelete: recordIDs)
            operation.savePolicy = .changedKeys
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
