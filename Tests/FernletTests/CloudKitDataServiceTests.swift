import ProximityKit
import CloudKit
import LocalPersistence
import FernletFoundation
import CoreData
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import PrivateStoreCore
import PrivateHealthStore
import CloudKitSync
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

    /// Stage B: once the per-row split clears the blob's `days`, detection reads the precomputed
    /// dayContentSummary instead of counting days — staying a single blob read rather than scanning
    /// every per-row DayRecord.
    @Test func detectionReadsDayContentSummaryWhenBlobDaysCleared() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        database.recordsByType["CD_FernletDatabaseRecord"] = [stageBSummaryRecord(zoneID: zoneID)]
        let service = makeService(database: database, zoneID: zoneID)

        let summary = try #require(try await service.detectExistingData())

        #expect(summary.mealLogCount == 4)
        #expect(summary.journalEntryCount == 3)
        #expect(summary.workoutCount == 2)
        #expect(summary.hydrationLogCount == 2)
        #expect(summary.sleepRecordCount == 1)
    }

    /// M8 regression: a second device that holds only per-row data the blob summary can't see — custom
    /// clothing items, coin-ledger rows, or day rows older than the summary window — must still be detected,
    /// otherwise the multi-device warning never fires. The pre-fix detector counted only the aggregate
    /// summary plus the retired standalone log types, so a design-only device read as "no cloud data".
    @Test func detectionCountsPerRowStoresTheBlobSummaryMisses() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        // No aggregate blob, no logged-day content — only the per-row stores, as a design-only device.
        database.recordsByType["CD_CustomItemRecord"] = [
            record(type: "CD_CustomItemRecord", name: "item-1", zoneID: zoneID),
            record(type: "CD_CustomItemRecord", name: "item-2", zoneID: zoneID)
        ]
        database.recordsByType["CD_CoinLedgerRecord"] = [record(type: "CD_CoinLedgerRecord", name: "coin-1", zoneID: zoneID)]
        database.recordsByType["CD_DayRecord"] = [record(type: "CD_DayRecord", name: "2024-01-01", zoneID: zoneID)]
        let service = makeService(database: database, zoneID: zoneID)

        let summary = try #require(try await service.detectExistingData())

        #expect(summary.customItemCount == 2)
        #expect(summary.coinLedgerCount == 1)
        #expect(summary.dayRecordCount == 1)
        #expect(summary.hasData)
        #expect(summary.mealLogCount == 0)  // no logged day CONTENT, only per-row stores
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
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            generation: 1
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
        identity.provisionBackupEscrowKeyForSealing()   // WS-1: seal path provisions the escrow key lazily.

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

        // Every new write is record format v2, and the whole generation shares ONE 32-byte salt
        // stamped on every chunk (not just the head, which is written last as the commit marker).
        let written = try await cloud.sealedBackupChunks(payloadType: .periodData)
        #expect(written.count == chunkCount)
        #expect(written.allSatisfy { $0.formatVersion == 2 }, "a new sealed-backup write was not v2")
        #expect(Set(written.map(\.keySalt)).count == 1, "chunks of one generation disagreed on the salt")
        #expect(written[0].keySalt.count == 32)

        let chunks = try #require(try await service.restoreChunks(payloadType: .periodData))
        #expect(chunks.count == chunkCount)
        let restored = try chunks.flatMap { try JSONDecoder().decode([MenstrualNarrative].self, from: $0) }
        #expect(restored.count == total)
        #expect(Set(restored.map(\.hkExternalUUID)) == Set((0..<total).map { "uuid-\($0)" }))

        try await cloud.deleteSealedBackup(payloadType: .periodData)
        #expect(try await service.restoreChunks(payloadType: .periodData) == nil)
    }

    /// The single-record reconcile path (sensitive notes) mints a salt of its own — v2 is not a
    /// chunked-only property, or the smaller payload would keep the static derivation forever.
    @Test func singleRecordReconcileWritesFormatV2AndRestores() async throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()

        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let cloud = makeService(database: database, zoneID: zoneID)
        let service = SealedBackupService(cloudDataService: cloud, identityService: identity)

        let plaintext = Data("one-record payload".utf8)
        try await service.reconcile(plaintext, payloadType: .sensitiveNotes, enabled: true)

        let head = try #require(try await cloud.sealedBackup(payloadType: .sensitiveNotes))
        #expect(head.formatVersion == 2)
        #expect(head.keySalt.count == 32)
        #expect(try await service.restoreChunks(payloadType: .sensitiveNotes) == [plaintext])

        // Two writes must not reuse a salt — that is the whole per-generation bound.
        try await service.reconcile(plaintext, payloadType: .sensitiveNotes, enabled: true)
        let second = try #require(try await cloud.sealedBackup(payloadType: .sensitiveNotes))
        #expect(second.keySalt != head.keySalt, "two generations shared one salt")
        #expect(try await service.restoreChunks(payloadType: .sensitiveNotes) == [plaintext])
    }

    private func sealedBackupChunk(
        _ index: Int,
        of count: Int,
        formatVersion: Int = 1,
        keySalt: Data = Data()
    ) -> SealedBackupRecord {
        SealedBackupRecord(
            payloadType: .periodData,
            signingPublicKey: Data("signing".utf8),
            keyAgreementPublicKey: Data("agreement".utf8),
            nonce: Data(repeating: 1, count: 12),
            ciphertext: Data("chunk-\(index)".utf8),
            tag: Data(repeating: 2, count: 16),
            updatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            chunkIndex: index,
            chunkCount: count,
            generation: 1,
            formatVersion: formatVersion,
            keySalt: keySalt
        )
    }

    // MARK: - Sealed-backup record format v1/v2

    /// A stand-in for a minted per-generation salt: 32 bytes, the only length decode accepts for v2.
    private var testKeySalt: Data { Data(repeating: 0x5A, count: 32) }

    /// The stored `CKRecord` behind a sealed-backup record name, so a test can edit the *wire* shape
    /// (drop a field, truncate the salt) the way a legacy or spliced record would differ.
    private func storedSealedBackup(
        in database: MockCloudKitRecordDatabase,
        named name: String
    ) throws -> CKRecord {
        try #require((database.recordsByType["SealedBackupRecord"] ?? [])
            .first { $0.recordID.recordName == name })
    }

    /// A record written before format v2 existed carries neither field. It must decode as v1 with an
    /// empty salt — anything else strands every backup already in a user's CloudKit database.
    @Test func sealedBackupWithoutFormatFieldsDecodesAsVersionOne() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        try await service.saveSealedBackup(sealedBackupChunk(0, of: 1))

        // Strip the discriminator the way a pre-v2 writer would have left it: absent entirely.
        let stored = try storedSealedBackup(in: database, named: "sealed-backup.periodData")
        stored["formatVersion"] = nil
        #expect(stored["keySalt"] == nil, "an unsalted write must not stamp a keySalt field at all")

        let fetched = try #require(try await service.sealedBackup(payloadType: .periodData))
        #expect(fetched.formatVersion == 1)
        #expect(fetched.keySalt.isEmpty)
    }

    /// A v2 record round-trips both new fields through the CloudKit encode/decode seam.
    @Test func sealedBackupV2RoundTripsFormatVersionAndSalt() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        let record = sealedBackupChunk(0, of: 1, formatVersion: 2, keySalt: testKeySalt)

        try await service.saveSealedBackup(record)
        let fetched = try #require(try await service.sealedBackup(payloadType: .periodData))
        #expect(fetched == record)
        #expect(fetched.formatVersion == 2)
        #expect(fetched.keySalt == testKeySalt)
    }

    /// Fail-closed: from v2 up the salt derives the key, so a missing or wrong-length one is a
    /// malformed record — never a silent fallback to some other derivation.
    @Test func sealedBackupV2WithMissingOrShortSaltFailsClosed() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        try await service.saveSealedBackup(sealedBackupChunk(0, of: 1, formatVersion: 2, keySalt: testKeySalt))
        let stored = try storedSealedBackup(in: database, named: "sealed-backup.periodData")

        stored["keySalt"] = nil
        await #expect(throws: SealedBackupError.malformedRecord) {
            _ = try await service.sealedBackup(payloadType: .periodData)
        }

        stored["keySalt"] = Data(repeating: 0x5A, count: 16) as CKRecordValue
        await #expect(throws: SealedBackupError.malformedRecord) {
            _ = try await service.sealedBackup(payloadType: .periodData)
        }

        // ...and the same record with the full 32 bytes back is fine, so the guard is the length,
        // not some unrelated breakage.
        stored["keySalt"] = testKeySalt as CKRecordValue
        #expect(try await service.sealedBackup(payloadType: .periodData)?.keySalt == testKeySalt)
    }

    /// Disagreeing format metadata inside an otherwise contiguous, same-generation set is NOT fatal at
    /// the transport layer. It is the exact shape a downlevel writer leaves behind when it grows a chunk
    /// set (stale v2 fields on the old indices, none on the new tail), and rejecting before any decrypt
    /// is attempted would brick a set that is entirely, validly sealed. The mismatch still fails closed
    /// one layer down, where AES-GCM — not an unauthenticated CloudKit field — is the judge.
    @Test func sealedBackupChunkSetToleratesMixedFormatMetadata() async throws {
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)

        // Mixed salt: chunk 2 carries a different (still valid, still 32-byte) salt.
        let mixedSaltDB = MockCloudKitRecordDatabase()
        let mixedSaltService = makeService(database: mixedSaltDB, zoneID: zoneID)
        for index in 0..<3 {
            let salt = index == 2 ? Data(repeating: 0x11, count: 32) : testKeySalt
            try await mixedSaltService.saveSealedBackup(
                sealedBackupChunk(index, of: 3, formatVersion: 2, keySalt: salt)
            )
        }
        #expect(try await mixedSaltService.sealedBackupChunks(payloadType: .periodData).count == 3)

        // Mixed format: a v1 chunk inside an otherwise v2 set (the grown-set shape).
        let mixedVersionDB = MockCloudKitRecordDatabase()
        let mixedVersionService = makeService(database: mixedVersionDB, zoneID: zoneID)
        for index in 0..<3 {
            let chunk = index == 1
                ? sealedBackupChunk(index, of: 3)
                : sealedBackupChunk(index, of: 3, formatVersion: 2, keySalt: testKeySalt)
            try await mixedVersionService.saveSealedBackup(chunk)
        }
        #expect(try await mixedVersionService.sealedBackupChunks(payloadType: .periodData).count == 3)

        // Still fatal: a spliced chunk from another generation. That is the anti-splice property the
        // format/salt checks were standing in for, and it is the one the AAD binds.
        let mixedGenerationDB = MockCloudKitRecordDatabase()
        let mixedGenerationService = makeService(database: mixedGenerationDB, zoneID: zoneID)
        for index in 0..<3 {
            try await mixedGenerationService.saveSealedBackup(
                sealedBackupChunk(index, of: 3, formatVersion: 2, keySalt: testKeySalt)
            )
        }
        let spliced = try storedSealedBackup(in: mixedGenerationDB, named: "sealed-backup.periodData.chunk.2")
        spliced["generation"] = Int64(0) as CKRecordValue
        await #expect(throws: SealedBackupError.malformedRecord) {
            _ = try await mixedGenerationService.sealedBackupChunks(payloadType: .periodData)
        }

        // Control: a uniform v2 set reassembles with both fields intact.
        let uniformDB = MockCloudKitRecordDatabase()
        let uniformService = makeService(database: uniformDB, zoneID: zoneID)
        for index in 0..<3 {
            try await uniformService.saveSealedBackup(
                sealedBackupChunk(index, of: 3, formatVersion: 2, keySalt: testKeySalt)
            )
        }
        let fetched = try await uniformService.sealedBackupChunks(payloadType: .periodData)
        #expect(fetched.map(\.chunkIndex) == [0, 1, 2])
        #expect(fetched.allSatisfy { $0.formatVersion == 2 && $0.keySalt == testKeySalt })
    }

    /// A v1 record must not carry a salt into memory even when one is sitting in the CloudKit field —
    /// that is precisely the residue a downlevel writer leaves, and the contract says v1 means no salt.
    @Test func sealedBackupVersionOneIgnoresAStaleServerSideSalt() async throws {
        let database = MockCloudKitRecordDatabase()
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let service = makeService(database: database, zoneID: zoneID)
        try await service.saveSealedBackup(sealedBackupChunk(0, of: 1, formatVersion: 2, keySalt: testKeySalt))

        let stored = try storedSealedBackup(in: database, named: "sealed-backup.periodData")
        stored["formatVersion"] = 1 as CKRecordValue

        let fetched = try #require(try await service.sealedBackup(payloadType: .periodData))
        #expect(fetched.formatVersion == 1)
        #expect(fetched.keySalt.isEmpty, "a v1 record inherited a stale server-side salt")
    }

    /// THE DOWNLEVEL-WRITER REGRESSION. CloudKit's `.allKeys` save is a per-field update, not a record
    /// replace: a build from before v2 existed overwrites the ciphertext of a v2 record while the
    /// server KEEPS that write's `formatVersion = 2` and 32-byte `keySalt`. The result decodes as a
    /// well-formed v2 record whose bytes are actually v1-sealed. Without the v1 retry in
    /// `SealedBackupCrypto.open` that intact backup is unopenable forever.
    @Test func downlevelWriteLeavesStaleV2MetadataAndTheBackupStillOpens() async throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()

        let database = MockCloudKitRecordDatabase()
        database.mergesFieldsLikeCloudKit = true
        let zoneID = CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName)
        let cloud = makeService(database: database, zoneID: zoneID)

        // Generation 1: a v2 write by this build, which stamps both new fields server-side.
        let v2Record = try SealedBackupCrypto.seal(
            Data("the v2 generation".utf8),
            payloadType: .sensitiveNotes,
            identityService: identity,
            generation: 1,
            keySalt: testKeySalt
        )
        try await cloud.saveSealedBackup(v2Record)

        // Generation 2: an OLD build rewrites the same record ID. It knows nothing of the two fields,
        // so it cannot clear them — modelled by saving a record that simply omits both keys.
        let plaintext = Data("rewritten by a pre-v2 build".utf8)
        let v1Record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .sensitiveNotes,
            identityService: identity,
            generation: 2
        )
        #expect(v1Record.formatVersion == 1)
        try await database.saveRecords([downlevelCloudRecord(v1Record, zoneID: zoneID)])

        let fetched = try #require(try await cloud.sealedBackup(payloadType: .sensitiveNotes))
        #expect(fetched.formatVersion == 2, "the stale v2 discriminator should have survived the merge")
        #expect(fetched.keySalt == testKeySalt, "the stale v2 salt should have survived the merge")
        #expect(fetched.generation == 2, "the ciphertext really is the old build's write")
        #expect(try SealedBackupCrypto.open(fetched, identityService: identity) == plaintext)
    }

    /// A `CKRecord` shaped the way a build from before record format v2 wrote one: every pre-v2 field,
    /// and neither `formatVersion` nor `keySalt`. Used to model the merge a downlevel writer causes.
    private func downlevelCloudRecord(_ record: SealedBackupRecord, zoneID: CKRecordZone.ID) throws -> CKRecord {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("fernlet-sealed-backup-test")
        try record.ciphertext.write(to: fileURL, options: .atomic)
        let cloudRecord = CKRecord(
            recordType: "SealedBackupRecord",
            recordID: CKRecord.ID(recordName: "sealed-backup.\(record.payloadType.rawValue)", zoneID: zoneID)
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
        cloudRecord["encryptedBlob"] = CKAsset(fileURL: fileURL)
        return cloudRecord
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

    private func stageBSummaryRecord(zoneID: CKRecordZone.ID) -> CKRecord {
        var localDatabase = LocalFernletDatabase()
        localDatabase.days = [:]  // Stage B: blob days cleared
        localDatabase.daysMigratedToRows = true
        localDatabase.dayContentSummary = DayContentSummary(
            mealCount: 4, journalCount: 3, workoutCount: 2, hygieneCount: 5, hydrationCount: 2, sleepCount: 1
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try! encoder.encode(localDatabase)
        let cloudRecord = record(type: "CD_FernletDatabaseRecord", name: "primary", zoneID: zoneID)
        cloudRecord["CD_payloadData"] = data as CKRecordValue
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

    /// Opt-in production fidelity: real CloudKit saves are a per-FIELD update, so keys the incoming
    /// record never sets are left untouched on the server rather than removed. The default (wholesale
    /// replacement) is what the rest of this suite was written against; turn this on for the tests that
    /// exist specifically to exercise the merge, e.g. a downlevel writer leaving stale format metadata.
    var mergesFieldsLikeCloudKit = false

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
            if mergesFieldsLikeCloudKit,
               let prior = existing.first(where: { $0.recordID == record.recordID }) {
                let incoming = Set(record.allKeys())
                for key in prior.allKeys() where !incoming.contains(key) {
                    record.setObject(prior.object(forKey: key), forKey: key)
                }
            }
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
    private let lock = NSLock()
    private var storedEvents: [(event: String, context: [String: String])] = []
    private var token: UUID?

    var events: [(event: String, context: [String: String])] {
        lock.lock(); defer { lock.unlock() }
        return storedEvents
    }

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append((event, context))
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    func contains(_ event: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.contains { $0.event == event }
    }
}
