//
//  SealedBackupChunkTests.swift
//  FernletTests
//
//  Covers the chunked period-backup hardening: the sealed-backup export no longer materializes the
//  whole menstrual-narrative history in memory. These exercise the pieces that are unit-testable
//  without iCloud — the repository's paged fetch, the chunk-position AEAD binding, and the
//  coordinator's multi-chunk restore writeback. The end-to-end seal -> CloudKit -> restoreChunks
//  round-trip lives in CloudKitDataServiceTests (it reuses the CloudKit mock there).
//

import ProximityKit
import CoreData
import FernletFoundation
import CryptoKit
import Foundation
import Testing
import FernletDomainModel
import PrivateStoreCore
import PrivateHealthStore
import CloudKit
import CloudKitSync
@testable import FernletCrypto
@testable import Fernlet

/// A throwaway `UserDefaults` suite per call, so the device-local `hasEverStoredNarrative` latch cannot
/// leak between tests (same pattern as SealedBackupRestoreTests). In production the latch lives in
/// `.standard`, which is process-global under the test runner AND persists in the simulator across
/// runs — one narrative insert anywhere would otherwise mark every later repository as "already
/// diverged", making the restore no-clobber gate throw `.storeNotEmpty` out of these tests' control.
private func isolatedDefaults() -> UserDefaults {
    UserDefaults(suiteName: "fernlet.tests.narrativeLatch.\(UUID().uuidString)") ?? .standard
}

@Suite(.serialized)
struct SealedBackupChunkTests {

    // MARK: - Repository paging

    @MainActor
    @Test func pagedNarrativesCoverHistoryWithoutOverlapOrGaps() throws {
        let key = SymmetricKey(size: .bits256)
        let repo = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        let total = 7
        for index in 0..<total {
            let dateKey = String(format: "2026-01-%02d", index + 1)
            try repo.insert(
                MenstrualNarrative(hkExternalUUID: "uuid-\(index)", dateKey: dateKey, note: "note \(index)"),
                contentKey: key
            )
        }

        #expect(try repo.narrativeCount() == total)

        // Page through with a limit that doesn't divide the total evenly.
        let pageSize = 3
        var collected: [MenstrualNarrative] = []
        var offset = 0
        while true {
            let page = try repo.narratives(offset: offset, limit: pageSize, contentKey: key)
            if page.isEmpty { break }
            #expect(page.count <= pageSize)
            collected.append(contentsOf: page)
            offset += pageSize
        }

        #expect(collected.count == total)
        // No row appears twice and none is skipped: the union is exactly the full history.
        #expect(Set(collected.map(\.hkExternalUUID)) == Set((0..<total).map { "uuid-\($0)" }))
        // Pages come back in the declared stable order (dateKey ascending).
        #expect(collected.map(\.dateKey) == collected.map(\.dateKey).sorted())
    }

    @MainActor
    @Test func pagedNarrativesAreEmptyForZeroLimitOrLockedKey() throws {
        let key = SymmetricKey(size: .bits256)
        let repo = MenstrualNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults()
        )
        try repo.insert(MenstrualNarrative(hkExternalUUID: "u", dateKey: "2026-01-01"), contentKey: key)

        #expect(try repo.narratives(offset: 0, limit: 0, contentKey: key).isEmpty)
        #expect(try repo.narratives(offset: 0, limit: 10, contentKey: nil).isEmpty)
    }

    // MARK: - Chunk-position authentication

    @MainActor
    @Test func chunkPositionIsAuthenticatedSoCiphertextCannotMove() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()   // WS-1: seal path provisions the escrow key lazily.

        let plaintext = Data("page-zero".utf8)
        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .periodData,
            identityService: identity,
            chunkIndex: 0,
            chunkCount: 3,
            generation: 1
        )

        // Same slot still opens.
        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)

        // Re-labeling the chunk's position (substitution/reorder) breaks the GCM tag.
        var movedIndex = record
        movedIndex.chunkIndex = 1
        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(movedIndex, identityService: identity)
        }

        // A chunk from a differently-sized generation also fails closed.
        var otherGeneration = record
        otherGeneration.chunkCount = 5
        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(otherGeneration, identityService: identity)
        }
    }

    // MARK: - Coordinator multi-chunk restore writeback

    /// The v2 period restore (period-data design 2026-09-30, §9.10) merges every chunk of a set into
    /// the sealed cycle records in one save — both shapes: a v1 chunk's narratives become
    /// narrative-only records under their legacy ids, a v2 chunk's records arrive as they are.
    @MainActor
    @Test func applyRestoredChunksMergesEveryPeriodChunkOfBothShapes() throws {
        let store = makeTestStore()
        store.settings.periodTrackingVisible = true
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let records = PeriodBackupDevice.makeRecordStore()
        let legacyID = UUID()
        let v1Chunk = try JSONEncoder().encode([
            MenstrualNarrative(hkExternalUUID: legacyID.uuidString, dateKey: "2026-06-01", note: "a1")
        ])
        let logged = PeriodBackupDevice.record(day: 2)
        let v2Chunk = try PeriodBackupFormat.encodeChunk(index: 1, records: [logged], writer: "w", total: 2)

        let count = try store.applyRestoredChunks([v1Chunk, v2Chunk], payloadType: .periodData, cycleRecordStore: records)

        #expect(count == 2)
        let restored = try records.allRecords(contentKey: key).records
        #expect(Set(restored.map(\.id)) == [legacyID, logged.id])
        let fromV1 = try #require(restored.first { $0.id == legacyID })
        #expect(fromV1.origin == .restored && fromV1.clinical == nil && fromV1.narrative?.note == "a1",
                "a v1 narrative becomes a narrative-only record, its clinical block UNKNOWN")
        #expect(restored.first { $0.id == logged.id } == logged, "a v2 record arrives exactly as written")
    }

    @MainActor
    @Test func applyRestoredChunksThrowsWhenPeriodKeyLocked() throws {
        let store = makeTestStore() // no hub key wired → no content key
        let records = PeriodBackupDevice.makeRecordStore()
        let chunk = try PeriodBackupFormat.encodeChunk(index: 0, records: [PeriodBackupDevice.record(day: 1)], writer: "w", total: 1)
        #expect(throws: FernletStore.SealedBackupWiringError.locked) {
            try store.applyRestoredChunks([chunk], payloadType: .periodData, cycleRecordStore: records)
        }
        #expect(try records.recordCount() == 0)
    }

    /// The retired sensitive-notes payload (owner decision 2026-09-23 — the Tier-2 memories never
    /// leave the device) is refused at the chunk write point too: however many chunks arrive, none is
    /// decoded and nothing reaches the Tier-2 store.
    @MainActor
    @Test func applyRestoredChunksNeverWritesTheRetiredSensitiveNotes() throws {
        let store = makeTestStore()
        let chunkA = try JSONEncoder().encode([
            TierTwoMemoryRecord(category: "consistency_profile", text: "Steady.", state: "consistent")
        ])
        let chunkB = try JSONEncoder().encode([
            TierTwoMemoryRecord(category: "workout_mood_correlation", text: "Gentle.", state: "neutral")
        ])

        let count = try store.applyRestoredChunks([chunkA, chunkB], payloadType: .sensitiveNotes)
        #expect(count == 0)
        #expect(store.tierTwoMemories.isEmpty)
    }

    // MARK: - Period backup v2: the export guards (period-data design 2026-09-30, §9.10; I16, I29, I30)

    /// E1: a fresh install whose restore has not resolved never exports — it would write over the
    /// cloud copy before pulling it. The switch stays on, the upload stays owed, nothing is written.
    @MainActor
    @Test func theV2ExportWaitsForThisInstallsRestore() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone")
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData), "a deferral keeps the switch on")
        #expect(cloud.sealedRecords.isEmpty, "nothing is written before the restore resolved")
        #expect(phone.host.reuploadDeferrals[.periodData] == true)

        phone.host.periodBackupLedger.markRestoreResolved()
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(!cloud.sealedRecords.isEmpty, "control: once resolved, the same call exports")
        #expect(phone.host.reuploadDeferrals[.periodData] == false, "and the owed upload is discharged")
    }

    /// E4: no Private tab key, no export (and no network): a deferral, nothing written.
    @MainActor
    @Test func theV2ExportNeedsThePrivateTabsKey() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        phone.host.sealedBackupContentKey = nil

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecords.isEmpty)
        #expect(phone.host.reuploadDeferrals[.periodData] == true)
    }

    /// E3 (R2-F12): the pre-pass decrypts EVERY record before the first write. One record this key
    /// cannot open refuses the whole export — named for Privacy & Data — and nothing reaches iCloud,
    /// not even a suffix chunk.
    @MainActor
    @Test func theV2ExportRefusesBeforeTheFirstWriteWhenARecordCannotOpen() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let fine = (0..<300).map { PeriodBackupDevice.record(day: $0) }
        try phone.seed(fine)
        try phone.seed([PeriodBackupDevice.record(day: 400)], key: SymmetricKey(size: .bits256))

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecords.isEmpty, "a 2-chunk set would write its suffix chunk first; nothing is written")
        #expect(phone.host.periodExportState == .unopenableEntries(1))
        #expect(phone.host.reuploadDeferrals[.periodData] == true)
    }

    /// E3, the undecided half: a record whose install-binding read did not answer defers the export
    /// (retryable) and writes nothing; it is never called unopenable.
    @MainActor
    @Test func theV2ExportDefersOnARecordItCouldNotDecide() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        let enabled = await DeviceBindingID.$testOverride.withValue(.readError) {
            await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData)
        }

        #expect(enabled)
        #expect(cloud.sealedRecords.isEmpty)
        #expect(phone.host.periodExportState == .clear, "undecided is never named as unopenable")
        #expect(phone.host.reuploadDeferrals[.periodData] == true)
    }

    /// The chunks are built from the pre-pass's id snapshot: a 600-record history goes up as three
    /// chunks whose head carries this install's writer, and another iPhone restores every record.
    @MainActor
    @Test func theV2ExportWritesTheWholeSnapshotAndAnotherIPhoneRestoresIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        let history = (0..<600).map { PeriodBackupDevice.record(day: $0) }
        try first.seed(history)

        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecords.count == 3)
        let head = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(head.writer == "first")
        #expect(first.host.periodBackupLedger.acceptedHead == head, "the set it wrote is the set it accepts")

        let second = PeriodBackupDevice(cloud: cloud, writer: "second")
        #expect(await second.coordinator.restorePeriodBackup() == .restored(600))
        let restored = try second.records.allRecords(contentKey: second.key).records
        #expect(restored.sorted { $0.id.uuidString < $1.id.uuidString } == history.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    /// I29: the re-upload flag clears only when no cycle record changed while the export ran. A record
    /// logged mid-upload is not in the set, so the upload stays owed — and the next export carries it,
    /// after which the cloud holds exactly what the store holds.
    @MainActor
    @Test func aRecordLoggedDuringTheExportKeepsTheUploadOwedUntilTheNextOne() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        let lateEntry = PeriodBackupDevice.record(day: 2)
        interrupting.onFirstSave = {
            do {
                try phone.records.insert(lateEntry, contentKey: phone.key)
            } catch {
                Issue.record("the mid-export log failed: \(error)")
            }
        }

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.reuploadDeferrals[.periodData] == true, "a mutation landed mid-export: still owed")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) != Set(try phone.records.allIDs()))

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.reuploadDeferrals[.periodData] == false, "a clean export discharges it")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try phone.records.allIDs()),
                "after a mutation and a clean export the cloud holds exactly the local records")
    }

    /// The mutation hook (R2-F3): every change made through the coordinator's own funnel — here the
    /// restore's merge — marks the upload owed, so the next settle re-exports the merged history.
    @MainActor
    @Test func aRestoreThatChangedRecordsMarksTheUploadOwed() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let second = PeriodBackupDevice(cloud: cloud, writer: "second")
        #expect(await second.coordinator.restorePeriodBackup() == .restored(1))
        #expect(second.host.periodBackupMutationCount == 1)
        #expect(second.host.reuploadDeferrals[.periodData] == true)
    }

    /// I30: an export never replaces a set this install has not accepted. The second iPhone's export
    /// is refused and named — nothing written — until the user chooses "Replace it with this iPhone's
    /// history"; that set is then minted ABOVE the first iPhone's, so the first iPhone's own restore of
    /// it is not mistaken for a rollback. The first iPhone is then refused in turn.
    @MainActor
    @Test func anExportNeverReplacesAnotherIPhonesSetExceptThroughTheExplicitReplace() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let firstHead = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(firstHead.generation == 2)
        let firstSet = cloud.sealedRecordIdentities

        let second = PeriodBackupDevice(cloud: cloud, writer: "second", resolved: true)
        try second.seed([PeriodBackupDevice.record(day: 5)])
        #expect(await second.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecordIdentities == firstSet, "the other iPhone's set is left exactly as it was")
        #expect(second.host.periodExportState == .heldByAnotherDevice(firstHead))
        #expect(second.host.reuploadDeferrals[.periodData] == true)

        await second.coordinator.replacePeriodBackupWithThisIPhone(firstHead)
        let secondHead = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(secondHead.writer == "second")
        #expect(secondHead.generation > firstHead.generation, "minted above the set it replaced")
        #expect(second.host.periodExportState == .clear)

        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(first.host.periodExportState == .heldByAnotherDevice(secondHead), "the compare-and-swap cuts both ways")
        await first.coordinator.restorePeriodBackupHere()
        #expect(first.host.recordedOutcomes[.periodData] == .restored(1), "not .rolledBack: the floor kept it above")
        #expect(try first.records.recordCount() == 2)
    }

    /// The replace accepts exactly the set the user was shown: if the other iPhone wrote a newer set
    /// since, the export is refused again rather than replacing a set nobody saw.
    @MainActor
    @Test func theExplicitReplaceIsForTheSetTheUserSawOnly() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let shown = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let newer = cloud.sealedRecordIdentities

        let second = PeriodBackupDevice(cloud: cloud, writer: "second", resolved: true)
        try second.seed([PeriodBackupDevice.record(day: 5)])
        await second.coordinator.replacePeriodBackupWithThisIPhone(shown)

        #expect(cloud.sealedRecordIdentities == newer)
        guard case .heldByAnotherDevice(let head) = second.host.periodExportState else {
            Issue.record("the newer set was not named")
            return
        }
        #expect(head.generation > shown.generation)
    }

    /// The one-time v1 seed: a v1 set at exactly this device's own high-water generation is this
    /// device's last write, so the update's first export replaces it with a v2 set; a v1 set at any
    /// other generation is another iPhone's and is held.
    @MainActor
    @Test func aV1SetIsThisDevicesOwnOnlyAtItsOwnGeneration() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let own = PeriodBackupDevice(cloud: cloud, writer: "own", resolved: true)
        try own.seed([PeriodBackupDevice.record(day: 1)])
        try await own.writeV1Set([MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-01", note: "v1")])
        #expect(await own.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.writer == "own", "its own v1 write was replaced")

        let otherCloud = try PeriodBackupDevice.makeCloud()
        defer { otherCloud.tearDown() }
        let writer = PeriodBackupDevice(cloud: otherCloud, writer: "v1writer", resolved: true)
        try await writer.writeV1Set([MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-01", note: "v1")])
        let reader = PeriodBackupDevice(cloud: otherCloud, writer: "reader", resolved: true)
        try reader.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await reader.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(reader.host.periodExportState == .heldByAnotherDevice(PeriodBackupHead(writer: PeriodBackupHead.v1Writer, generation: 1)))
    }

    /// The writer tag: deterministic per install binding, distinct across installs, 32 hex
    /// characters, and absent (the export defers) when the binding is unavailable.
    @MainActor
    @Test func theWriterTagNamesTheInstall() {
        let installA = Data(repeating: 0xA1, count: 16)
        let installB = Data(repeating: 0xB2, count: 16)
        #expect(PeriodBackupWriterTag.tag(forBinding: installA) == PeriodBackupWriterTag.tag(forBinding: installA))
        #expect(PeriodBackupWriterTag.tag(forBinding: installA) != PeriodBackupWriterTag.tag(forBinding: installB))
        #expect(PeriodBackupWriterTag.tag(forBinding: installA).count == 32)
        #expect(PeriodBackupWriterTag.tag(forBinding: installA).allSatisfy { $0.isHexDigit && !$0.isUppercase })
        DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            #expect(PeriodBackupWriterTag.current() == PeriodBackupWriterTag.tag(forBinding: installA))
        }
        DeviceBindingID.$testOverride.withValue(.unavailable) {
            #expect(PeriodBackupWriterTag.current() == nil)
        }
    }

    /// The generation floor itself: a write is minted strictly above both this device's mark and the
    /// floor, and persisted.
    @MainActor
    @Test func theGenerationFloorMintsAboveTheCloudHead() {
        var store = SealedBackupGenerationStore(defaults: isolatedDefaults())
        #expect(store.mintNext(for: .periodData, above: 7) == 8)
        #expect(store.lastSeen(for: .periodData) == 8)
        #expect(store.mintNext(for: .periodData, above: 3) == 9, "never below this device's own mark")
        let defaults = isolatedDefaults()
        defaults.set("w:3", forKey: SealedBackupGenerationStore.periodAcceptedHeadKey)
        var wiped = SealedBackupGenerationStore(defaults: defaults)
        wiped.reset()
        #expect(defaults.object(forKey: SealedBackupGenerationStore.periodAcceptedHeadKey) == nil,
                "delete-all's reset clears the compare-and-swap record with the marks")
    }
}

// MARK: - Period backup v2 rig

/// One iPhone for the period backup v2 tests (period-data design 2026-09-30, §9.10): its own sealed
/// cycle records, host bookkeeping, rollback generation store and writer tag — over a cloud database
/// and an escrow keychain (iCloud Keychain) it shares with the other iPhones of a test.
@MainActor
final class PeriodBackupDevice {
    let host: FakeSealedBackupHost
    /// This iPhone's sealed store.
    let controller: PrivatePersistenceController
    let records: CycleRecordStore
    let generationDefaults: UserDefaults
    let coordinator: SealedBackupCoordinator
    private let cloud: FakeSealedBackupCloud

    /// The Private tab's key on this iPhone.
    var key: SymmetricKey { host.sealedBackupContentKey ?? SymmetricKey(size: .bits256) }

    /// Creates an iPhone with the period backup on, iCloud sync on and the upload owed.
    ///
    /// - Parameters:
    ///   - cloud: The shared cloud.
    ///   - writer: This install's writer tag.
    ///   - resolved: Whether this install's period restore has already resolved.
    ///   - database: A transport to interpose; the cloud's own by default.
    ///   - keychainService: The identity's keychain (its escrow key); the cloud's by default — an
    ///     account whose iCloud Keychain synced the escrow key.
    ///   - preferences: The storage preferences the coordinator reads.
    init(
        cloud: FakeSealedBackupCloud,
        writer: String,
        resolved: Bool = false,
        database: (any CloudKitRecordDatabase)? = nil,
        keychainService: String? = nil,
        preferences: StoragePreferences = PeriodBackupDevice.backupOn
    ) {
        self.cloud = cloud
        let host = FakeSealedBackupHost()
        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        self.host = host
        let controller = PrivatePersistenceController(inMemory: true)
        self.controller = controller
        let records = CycleRecordStore(controller: controller)
        self.records = records
        let generationDefaults = UserDefaults(suiteName: "fernlet.tests.periodGeneration.\(UUID().uuidString)") ?? .standard
        self.generationDefaults = generationDefaults
        let keychainService = keychainService ?? cloud.keychainService
        let transport = database ?? cloud.database
        coordinator = SealedBackupCoordinator(
            host: host,
            identityFactory: { IdentityService(keychainService: keychainService) },
            serviceFactory: { identity in
                SealedBackupService(
                    cloudDataService: Self.cloudDataService(transport),
                    identityService: identity,
                    generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
                )
            },
            preferencesProvider: { preferences },
            periodRecordStore: records,
            writerTagProvider: { writer }
        )
        if resolved { host.periodBackupLedger.markRestoreResolved() }
    }

    /// Seals `records` straight into this iPhone's store (under `key`, this iPhone's by default).
    func seed(_ seeded: [CycleRecord], key: SymmetricKey? = nil) throws {
        records.attachVisibilityGate { true }
        _ = try records.upsertMerged(seeded, retiringNarrativeIDs: [], contentKey: key ?? self.key)
    }

    /// Writes a v1 period set (bare `[MenstrualNarrative]`) the way an earlier build did, with this
    /// iPhone's generation store.
    func writeV1Set(_ narratives: [MenstrualNarrative]) async throws {
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        let service = SealedBackupService(
            cloudDataService: Self.cloudDataService(cloud.database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
        )
        let chunk = try JSONEncoder().encode(narratives)
        try await service.reconcileChunked(payloadType: .periodData, chunkCount: 1) { _ in chunk }
    }

    /// iCloud sync on, the period backup on, its upload owed.
    nonisolated static let backupOn = StoragePreferences(
        iCloudSyncEnabled: true, sealedBackupPeriodEnabled: true, sealedBackupPeriodReuploadDeferred: true
    )

    /// A fresh in-memory cycle-record funnel.
    static func makeRecordStore() -> CycleRecordStore {
        CycleRecordStore(controller: PrivatePersistenceController(inMemory: true))
    }

    /// A logged record on day `day` of a fixed calendar.
    static func record(day: Int, note: String = "n") -> CycleRecord {
        let base = Date(timeIntervalSinceReferenceDate: 790_000_000)
        return CycleRecord(
            event: UserLoggedCycleEvent(date: base.addingTimeInterval(Double(day) * 86_400), flowLevel: .light, note: note),
            now: base
        )
    }

    /// A cloud with the escrow key provisioned, as on an account whose iCloud Keychain synced it.
    static func makeCloud() throws -> FakeSealedBackupCloud {
        let cloud = FakeSealedBackupCloud(
            keychainService: "com.fernlet.period-v2.\(UUID().uuidString)",
            generationDefaults: UserDefaults(suiteName: "fernlet.tests.periodCloud.\(UUID().uuidString)") ?? .standard
        )
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return cloud
    }

    /// The head of the period set in `cloud`, read the way the export's compare-and-swap reads it.
    static func cloudHead(_ cloud: FakeSealedBackupCloud) async throws -> PeriodBackupHead? {
        guard let head = try await reader(cloud).fetchHead(payloadType: .periodData) else { return nil }
        return try PeriodBackupFormat.head(ofChunk: head.plaintext, generation: head.generation)
    }

    /// Every record id in the period set in `cloud`.
    static func cloudRecordIDs(_ cloud: FakeSealedBackupCloud) async throws -> Set<UUID> {
        let chunks = try await reader(cloud).restoreChunks(payloadType: .periodData) ?? []
        return Set(try chunks.flatMap { try PeriodBackupFormat.records(fromChunk: $0) }.map(\.id))
    }

    /// A read-only service over `cloud` with its own fresh rollback mark.
    private static func reader(_ cloud: FakeSealedBackupCloud) throws -> SealedBackupService {
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        _ = identity.loadBackupEscrowKeyForOpen()
        return SealedBackupService(
            cloudDataService: cloudDataService(cloud.database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(
                defaults: UserDefaults(suiteName: "fernlet.tests.periodReader.\(UUID().uuidString)") ?? .standard
            )
        )
    }

    private static func cloudDataService(_ database: any CloudKitRecordDatabase) -> CloudKitDataService {
        CloudKitDataService(
            accountProvider: AlwaysAvailableAccountProvider(),
            database: database,
            zoneID: CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName),
            isCloudKitSyncEnabled: { false }
        )
    }
}

/// A transport that runs `onFirstSave` (on the main actor) before its first save lands — a record
/// logged while the export is uploading.
final class InterruptingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    /// Runs once, before the first save.
    var onFirstSave: (@MainActor () -> Void)?

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        if let hook = onFirstSave {
            onFirstSave = nil
            hook()
        }
        try await base.saveRecords(records)
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }
}
