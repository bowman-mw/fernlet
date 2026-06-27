import CloudKit
import CoreData
import CryptoKit
import Foundation
import Testing
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct CloudKitDataServiceTests {
    @Test func detectionReturnsCorrectCounts() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        database.recordsByType["CD_FernletDatabaseRecord"] = [aggregateRecord(zoneID: zoneID)]
        database.recordsByType["MealLogRecord"] = [record(type: "MealLogRecord", name: "meal-direct", zoneID: zoneID)]
        database.recordsByType["JournalLogRecord"] = [
            record(type: "JournalLogRecord", name: "journal-direct-1", zoneID: zoneID),
            record(type: "JournalLogRecord", name: "journal-direct-2", zoneID: zoneID)
        ]
        let service = makeService(database: database, zoneID: zoneID)

        let summary = try #require(try await service.detectExistingData())

        #expect(summary.mealLogCount == 2)
        #expect(summary.journalEntryCount == 3)
        #expect(summary.workoutCount == 1)
        #expect(summary.hygieneLogCount == 2)
        #expect(summary.hydrationLogCount == 1)
        #expect(summary.sleepRecordCount == 1)
        #expect(audit.contains("cloudkit.detect.attempt"))
        #expect(audit.contains("cloudkit.detect.completed"))
    }

    @Test func detectionReturnsNilWhenNoCloudDataExists() async throws {
        let database = MockCloudKitRecordDatabase()
        let service = makeService(database: database)

        let summary = try await service.detectExistingData()

        #expect(summary == nil)
    }

    /// Regression for prior finding #4: a full health database exceeds CloudKit's ~1 MB
    /// inline field limit, so NSPersistentCloudKitContainer stores the mirrored
    /// `CD_payloadData` as a CKAsset rather than inline Data. Detection must read the asset,
    /// otherwise it reports "no cloud data" while the cloud is full of the user's data.
    @Test func detectionReadsAssetBackedCDPayload() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        database.recordsByType["CD_FernletDatabaseRecord"] = [aggregateRecord(zoneID: zoneID, asAsset: true)]
        let service = makeService(database: database, zoneID: zoneID)

        let summary = try #require(try await service.detectExistingData())

        #expect(summary.mealLogCount == 1)
        #expect(summary.workoutCount == 1)
        #expect(summary.journalEntryCount == 1)
        #expect(summary.hasData)
    }

    @Test func deletionRemovesAllRecordsAndReportsSyncImpact() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        database.recordsByType["CD_FernletDatabaseRecord"] = [aggregateRecord(zoneID: zoneID)]
        database.recordsByType["SealedBackupRecord"] = [record(type: "SealedBackupRecord", name: "sealed-1", zoneID: zoneID)]
        database.recordsByType["SleepRecord"] = [record(type: "SleepRecord", name: "sleep-1", zoneID: zoneID)]
        let service = makeService(database: database, zoneID: zoneID, syncEnabled: true)

        let result = try await service.deleteAllCloudKitData(
            confirmation: DeletionConfirmation(userTypedConfirmation: "DELETE")
        )

        #expect(result.deletedRecordCount == 3)
        #expect(result.mayAffectOtherDevices)
        #expect(database.allRecords.isEmpty)
        #expect(audit.contains("cloudkit.delete.attempt"))
        #expect(audit.contains("cloudkit.delete.completed"))
    }

    @Test func deletionAllowsRecentBiometricConfirmation() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        database.recordsByType["SealedBackupRecord"] = [record(type: "SealedBackupRecord", name: "sealed-1", zoneID: zoneID)]
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let service = makeService(database: database, zoneID: zoneID, now: { now })

        let result = try await service.deleteAllCloudKitData(
            confirmation: DeletionConfirmation(biometricVerifiedAt: now.addingTimeInterval(-30))
        )

        #expect(result.deletedRecordCount == 1)
    }

    @Test func deletionWithoutConfirmationThrows() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let database = MockCloudKitRecordDatabase()
        let service = makeService(database: database)

        await #expect(throws: CloudKitDataServiceError.confirmationRequired) {
            _ = try await service.deleteAllCloudKitData(confirmation: DeletionConfirmation())
        }
        #expect(audit.contains("cloudkit.delete.attempt"))
        #expect(audit.contains("cloudkit.delete.failed"))
    }

    @Test func sealedBackupAssetRoundTripsAndDeletesByPayloadType() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        let backup = SealedBackupRecord(
            payloadType: .sensitiveNotes,
            signingPublicKey: Data("signing".utf8),
            keyAgreementPublicKey: Data("agreement".utf8),
            nonce: Data(repeating: 1, count: 12),
            ciphertext: Data("encrypted".utf8),
            tag: Data(repeating: 2, count: 16),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        try await service.saveSealedBackup(backup)
        #expect(try await service.sealedBackup(payloadType: .sensitiveNotes) == backup)

        try await service.deleteSealedBackup(payloadType: .sensitiveNotes)
        #expect(try await service.sealedBackup(payloadType: .sensitiveNotes) == nil)
    }

    // MARK: - Chunked sealed backup

    @Test func sealedBackupChunkSetFetchesInOrder() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        for index in 0..<3 {
            try await service.saveSealedBackup(sealedBackupChunk(index, of: 3))
        }

        let fetched = try await service.sealedBackupChunks(payloadType: .periodData)
        #expect(fetched.map(\.chunkIndex) == [0, 1, 2])
        #expect(fetched.allSatisfy { $0.chunkCount == 3 })
        // The head keeps the un-suffixed name so single-record payloads are unaffected.
        let names = Set((database.recordsByType["SealedBackupRecord"] ?? []).map(\.recordID.recordName))
        #expect(names == [
            "sealed-backup.periodData",
            "sealed-backup.periodData.chunk.1",
            "sealed-backup.periodData.chunk.2"
        ])
    }

    @Test func sealedBackupChunkSetFailsClosedOnMissingChunk() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        // Head announces 3 chunks but only the head and chunk 1 ever land.
        try await service.saveSealedBackup(sealedBackupChunk(0, of: 3))
        try await service.saveSealedBackup(sealedBackupChunk(1, of: 3))

        await #expect(throws: SealedBackupError.malformedRecord) {
            _ = try await service.sealedBackupChunks(payloadType: .periodData)
        }
    }

    @Test func deleteSealedBackupRemovesEveryChunk() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        for index in 0..<3 {
            try await service.saveSealedBackup(sealedBackupChunk(index, of: 3))
        }

        try await service.deleteSealedBackup(payloadType: .periodData)
        #expect(try await service.sealedBackupChunks(payloadType: .periodData).isEmpty)
        #expect((database.recordsByType["SealedBackupRecord"] ?? []).isEmpty)
    }

    @Test func deleteSealedBackupChunksPrunesOnlyHigherIndices() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        for index in 0..<4 {
            try await service.saveSealedBackup(sealedBackupChunk(index, of: 4))
        }

        // Simulate a backup shrinking to two chunks: everything at index >= 2 is stale.
        try await service.deleteSealedBackupChunks(payloadType: .periodData, withIndexAtLeast: 2)

        let names = Set((database.recordsByType["SealedBackupRecord"] ?? []).map(\.recordID.recordName))
        #expect(names == ["sealed-backup.periodData", "sealed-backup.periodData.chunk.1"])
    }

    /// End-to-end: page a real (in-memory) narrative history, seal it into multiple chunks through the
    /// crypto + CloudKit layers, then restore and reassemble it — proving the chunked export round-trips
    /// without ever materializing the whole history. Uses the CloudKit mock so it needs no iCloud, but a
    /// real device identity so the AES-GCM seal/open is exercised for real.
    @Test func periodBackupSealsInChunksAndRestoresFullHistory() async throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()

        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let cloud = makeService(database: database, zoneID: zoneID)
        let service = SealedBackupService(cloudDataService: cloud, identityService: identity)

        let key = SymmetricKey(size: .bits256)
        let repo = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext
        )
        let total = 5
        for index in 0..<total {
            let dateKey = String(format: "2026-03-%02d", index + 1)
            try repo.insert(
                MenstrualNarrative(hkExternalUUID: "uuid-\(index)", dateKey: dateKey, note: "note \(index)"),
                contentKey: key
            )
        }

        // Force several chunks (mirrors SealedBackupCoordinator.reconcilePeriodBackup with a tiny page).
        let pageSize = 2
        let chunkCount = (total + pageSize - 1) / pageSize
        #expect(chunkCount > 1)
        try await service.reconcileChunked(payloadType: .periodData, chunkCount: chunkCount) { index in
            try JSONEncoder().encode(repo.narratives(offset: index * pageSize, limit: pageSize, contentKey: key))
        }

        #expect(database.recordsByType["SealedBackupRecord"]?.count == chunkCount)

        let chunks = try #require(try await service.restoreChunks(payloadType: .periodData))
        #expect(chunks.count == chunkCount)
        let restored = try chunks.flatMap { try JSONDecoder().decode([MenstrualNarrative].self, from: $0) }
        #expect(restored.count == total)
        #expect(Set(restored.map(\.hkExternalUUID)) == Set((0..<total).map { "uuid-\($0)" }))

        try await cloud.deleteSealedBackup(payloadType: .periodData)
        #expect(try await service.restoreChunks(payloadType: .periodData) == nil)
    }

    private func sealedBackupChunk(_ index: Int, of count: Int) -> SealedBackupRecord {
        SealedBackupRecord(
            payloadType: .periodData,
            signingPublicKey: Data("signing".utf8),
            keyAgreementPublicKey: Data("agreement".utf8),
            nonce: Data(repeating: 1, count: 12),
            ciphertext: Data("chunk-\(index)".utf8),
            tag: Data(repeating: 2, count: 16),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            chunkIndex: index,
            chunkCount: count
        )
    }

    @Test func notSignedInStateThrowsRightErrorForBothMethods() async throws {
        let detectService = makeService(accountStatus: .noAccount, database: MockCloudKitRecordDatabase())
        await #expect(throws: CloudKitDataServiceError.notSignedIn) {
            _ = try await detectService.detectExistingData()
        }

        let deleteService = makeService(accountStatus: .noAccount, database: MockCloudKitRecordDatabase())
        await #expect(throws: CloudKitDataServiceError.notSignedIn) {
            _ = try await deleteService.deleteAllCloudKitData(
                confirmation: DeletionConfirmation(userTypedConfirmation: "DELETE")
            )
        }
    }

    @Test func auditLogEntriesAreCreatedForDetectionFailure() async throws {
        let audit = AuditCapture()
        audit.install()
        defer { audit.uninstall() }
        let service = makeService(accountStatus: .restricted, database: MockCloudKitRecordDatabase())

        await #expect(throws: CloudKitDataServiceError.notSignedIn) {
            _ = try await service.detectExistingData()
        }

        #expect(audit.contains("cloudkit.detect.attempt"))
        #expect(audit.contains("cloudkit.detect.failed"))
    }

    private func makeService(
        accountStatus: CKAccountStatus = .available,
        database: MockCloudKitRecordDatabase,
        zoneID: CKRecordZone.ID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName),
        syncEnabled: Bool = false,
        now: @escaping () -> Date = Date.init
    ) -> CloudKitDataService {
        CloudKitDataService(
            accountProvider: MockCloudKitAccountProvider(status: accountStatus),
            database: database,
            zoneID: zoneID,
            isCloudKitSyncEnabled: { syncEnabled },
            now: now
        )
    }

    private func aggregateRecord(zoneID: CKRecordZone.ID, asAsset: Bool = false) -> CKRecord {
        var localDatabase = LocalFernletDatabase()
        localDatabase.days = [
            "2026-05-22": FernletDay(
                date: "2026-05-22",
                meals: [sampleMeal()],
                workouts: [sampleWorkout()],
                journals: [JournalEntry(text: "Good day", tag: .good)],
                sleep: SleepLog(hours: 7.5, quality: .good, note: "solid"),
                bottleCount: 3,
                hygiene: [.teethAM, .floss]
            )
        ]
        localDatabase.rebuildDerivedTables(todayKey: "2026-05-22")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(localDatabase)
        // NSPersistentCloudKitContainer mirrors the attribute under the "CD_" prefix, and
        // promotes large blobs to a CKAsset. Model both forms so detection is exercised the
        // way the real cloud stores it.
        let cloudRecord = record(type: "CD_FernletDatabaseRecord", name: "primary", zoneID: zoneID)
        if asAsset {
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("aggregate-\(UUID().uuidString).bin")
            try! data.write(to: url)
            cloudRecord["CD_payloadData"] = CKAsset(fileURL: url)
        } else {
            cloudRecord["CD_payloadData"] = data as CKRecordValue
        }
        return cloudRecord
    }

    private func sampleMeal() -> Meal {
        Meal(
            name: "Eggs",
            mealType: .breakfast,
            macros: Macros(protein: 18, carbs: 2, fat: 12),
            quality: .good,
            confidence: "test",
            note: "",
            source: MealLogSource.manual
        )
    }

    private func sampleWorkout() -> Workout {
        Workout(
            name: "Walk",
            type: .cardio,
            exercises: "walk",
            rpe: nil,
            notes: "",
            duration: 20,
            intensity: .light
        )
    }

    private func record(type: String, name: String, zoneID: CKRecordZone.ID) -> CKRecord {
        CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }
}

private final class MockCloudKitAccountProvider: CloudKitAccountStatusProviding {
    let status: CKAccountStatus

    init(status: CKAccountStatus) {
        self.status = status
    }

    func accountStatus() async throws -> CKAccountStatus {
        status
    }
}

private final class MockCloudKitRecordDatabase: CloudKitRecordDatabase {
    var recordsByType: [String: [CKRecord]] = [:]

    var allRecords: [CKRecord] {
        recordsByType.values.flatMap { $0 }
    }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] {
        var seen = Set<String>()
        return allRecords.compactMap { record in
            let zoneID = record.recordID.zoneID
            let key = "\(zoneID.ownerName):\(zoneID.zoneName)"
            return seen.insert(key).inserted ? zoneID : nil
        }
    }

    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        recordsByType[recordType, default: []]
            .filter { $0.recordID.zoneID == zoneID }
            .map(\.recordID)
    }

    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] {
        let requested = Set(recordIDs.map(\.recordName))
        return allRecords.filter { requested.contains($0.recordID.recordName) }
    }

    func saveRecords(_ records: [CKRecord]) async throws {
        for record in records {
            if let asset = record["encryptedBlob"] as? CKAsset, let sourceURL = asset.fileURL {
                let stableURL = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString)
                    .appendingPathExtension("fernlet-sealed-backup-test")
                try FileManager.default.copyItem(at: sourceURL, to: stableURL)
                record["encryptedBlob"] = CKAsset(fileURL: stableURL)
            }
            var existing = recordsByType[record.recordType, default: []]
            existing.removeAll { $0.recordID == record.recordID }
            existing.append(record)
            recordsByType[record.recordType] = existing
        }
    }

    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws {
        let deletedNames = Set(recordIDs.map(\.recordName))
        for recordType in recordsByType.keys {
            recordsByType[recordType] = recordsByType[recordType, default: []]
                .filter { !deletedNames.contains($0.recordID.recordName) }
        }
    }
}

private final class AuditCapture {
    private(set) var events: [(event: String, context: [String: String])] = []

    func install() {
        FernletAuditLog.captureHandler = { [weak self] event, context in
            self?.events.append((event, context))
        }
    }

    func uninstall() {
        FernletAuditLog.captureHandler = nil
    }

    func contains(_ event: String) -> Bool {
        events.contains { $0.event == event }
    }
}
