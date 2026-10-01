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
        await first.coordinator.restorePeriodBackupHere(secondHead)
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

    /// A v1 set names no writer, so it is never assumed to be this iPhone's (review
    /// U5-backup-v2-C-U5-4): the design's one-time seed took a v1 set at this device's own high-water
    /// generation for its own last write, but counters are per device and small, so two iPhones that
    /// each backed up once both wrote generation 1 — and the second iPhone silently replaced the
    /// first one's backup. Every v1 set is now held until the user chooses; "Restore it here" then
    /// merges it and the export follows over it.
    @MainActor
    @Test func aV1SetIsNeverAssumedToBeThisIPhones() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true)
        let phoneB = PeriodBackupDevice(cloud: cloud, writer: "b", resolved: true)
        try await phoneB.writeV1Set([MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-01", note: "B's")])
        let aNote = MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-02", note: "A's")
        try await phoneA.writeV1Set([aNote])
        let v1Head = PeriodBackupHead(writer: PeriodBackupHead.v1Writer, generation: 1)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == v1Head, "both iPhones wrote generation 1; A wrote last")
        let aSet = cloud.sealedRecordIdentities

        try phoneB.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecordIdentities == aSet, "B never writes over A's v1 backup on a generation coincidence")
        #expect(phoneB.host.periodExportState == .heldByAnotherDevice(v1Head))

        try phoneA.seed([PeriodBackupDevice.record(day: 2)])
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phoneA.host.periodExportState == .heldByAnotherDevice(v1Head), "nor A over its own: it cannot know")

        await phoneA.coordinator.restorePeriodBackupHere(v1Head)
        #expect(phoneA.host.recordedOutcomes[.periodData] == .restored(1))
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.writer == "a", "the export follows the explicit restore")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud).contains(CycleLegacyIdentity.recordID(forLegacyExternalID: aNote.hkExternalUUID)), "with the v1 entries merged in")
    }

    /// Review U5-backup-v2-C-U5-2: generation counters are per device and "Delete everything" zeroes
    /// the deleting iPhone's, so the other iPhone's set can be numbered BELOW this iPhone's
    /// high-water mark. "Restore it here" of exactly the set it was shown still merges it — it was a
    /// terminal `.rolledBack` that also stranded every later export behind restore-first — and the
    /// export then writes above both.
    @MainActor
    @Test func restoreItHereMergesASetNumberedBelowThisIPhonesMark() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true)
        try phoneA.seed([PeriodBackupDevice.record(day: 1)])
        for _ in 0..<3 { #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData)) }
        #expect(SealedBackupGenerationStore(defaults: phoneA.generationDefaults).lastSeen(for: .periodData) == 3)

        // Phone B ran "Delete everything" (its cloud set gone, its marks zeroed), then backed up again.
        cloud.database.recordsByType["SealedBackupRecord"] = []
        let phoneB = PeriodBackupDevice(cloud: cloud, writer: "b", resolved: true)
        try phoneB.seed([PeriodBackupDevice.record(day: 5)])
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let bHead = PeriodBackupHead(writer: "b", generation: 1)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == bHead)

        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phoneA.host.periodExportState == .heldByAnotherDevice(bHead))
        await phoneA.coordinator.restorePeriodBackupHere(bHead)
        #expect(phoneA.host.recordedOutcomes[.periodData] == .restored(1), "not .rolledBack: the user chose this set")
        #expect(try phoneA.records.recordCount() == 2)
        let after = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(after.writer == "a" && after.generation == 4, "the export follows, above both iPhones' numbers")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try phoneA.records.allIDs()))
    }

    /// Review U5-backup-v2-C-U5-2, the other half: an explicit restore that cannot land never strands
    /// the export. The below-the-mark exception is for exactly the set the user chose — another set
    /// at that number is still a rollback — and since "Restore it here" no longer reopens this
    /// install's resolved restore, the next export names the set again with both choices.
    @MainActor
    @Test func anExplicitRestoreThatCannotLandLeavesTheReplaceReachable() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true)
        try phoneA.seed([PeriodBackupDevice.record(day: 1)])
        for _ in 0..<3 { #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData)) }
        cloud.database.recordsByType["SealedBackupRecord"] = []
        let phoneB = PeriodBackupDevice(cloud: cloud, writer: "b", resolved: true)
        try phoneB.seed([PeriodBackupDevice.record(day: 5)])
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let bHead = PeriodBackupHead(writer: "b", generation: 1)

        await phoneA.coordinator.restorePeriodBackupHere(PeriodBackupHead(writer: "someone-else", generation: 1))
        #expect(phoneA.host.recordedOutcomes[.periodData] == .rolledBack, "a different set at the chosen number is refused")
        #expect(try phoneA.records.recordCount() == 1, "and nothing merged")
        #expect(phoneA.host.periodBackupLedger.isRestoreResolved, "the resolved restore was never reopened")

        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phoneA.host.periodExportState == .heldByAnotherDevice(bHead), "the set is named again, Replace still offered")
    }

    /// Review U5-backup-v2-L-U5-R3: the export writes the head, then prunes stale chunks — a network
    /// enumeration. When the prune fails (or the app is suspended) after the head landed, the accepted
    /// head was never recorded, and the next export used to name this iPhone's own set "saved from
    /// another iPhone". A set under this install's writer tag at a generation this device minted is
    /// its own; one ABOVE its high-water mark (an iPhone put back from an older device backup of
    /// itself) is still held.
    @MainActor
    @Test func anExportWhosePruneFailedStillOwnsItsSet() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let flaky = PruneFailingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: flaky)
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        #expect(await !phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData), "the prune failed")
        let written = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(written.writer == "phone" && phone.host.periodBackupLedger.acceptedHead == nil, "head up, never recorded")

        flaky.failsPrunes = false
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.periodExportState == .clear, "its own set is not another iPhone's")
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.generation == written.generation + 1)

        let restoredFromAnOlderBackup = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try restoredFromAnOlderBackup.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await restoredFromAnOlderBackup.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        guard case .heldByAnotherDevice = restoredFromAnOlderBackup.host.periodExportState else {
            Issue.record("a newer set under this tag was written over")
            return
        }
    }

    /// Review U5-backup-v2 N-1: the Private tab closing mid-upload — its key gone, its section settle
    /// cancelled — must not stop a set part-way. Chunks live at fixed, account-wide record names, so a
    /// set stopped after its suffix chunks left the OLD head over NEW suffix chunks: a mixed-generation
    /// set every restore refused until this iPhone exported again (lost with the phone; stranded
    /// behind an app-lock reset's hold). The export now decrypts and seals every chunk before its first
    /// upload, so the closed tab has nothing left to decrypt or stop: the new set lands whole over the
    /// old two-chunk one, and a new iPhone restores it.
    @MainActor
    @Test func anExportFinishesItsSealedSetWhenPrivateClosesMidUpload() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == PeriodBackupHead(writer: "phone", generation: 1))
        #expect(cloud.sealedRecords.count == 2, "the prior set has two chunks")

        try phone.seed((300..<320).map { PeriodBackupDevice.record(day: $0) })
        let export = PeriodExportTaskBox()
        interrupting.onFirstSave = {
            phone.host.sealedBackupContentKey = nil   // the tab closed: the key provider answers nil
            export.task?.cancel()                     // and ContentView cancels the section settle
        }
        export.task = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData) }
        #expect(await export.task?.value == true)

        let head = PeriodBackupHead(writer: "phone", generation: 2)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == head, "the new set's head landed")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud).count == 320, "one whole set, every chunk at generation 2")
        #expect(phone.host.periodBackupLedger.acceptedHead == head)
        #expect(phone.host.reuploadDeferrals[.periodData] == false, "nothing owed: the set is complete")
        let newPhone = PeriodBackupDevice(cloud: cloud, writer: "new")
        #expect(await newPhone.coordinator.restorePeriodBackup() == .restored(320), "and it restores")
    }

    /// Review U5-backup-v2-C-U5-3 / L-U5-R4, kept through N-1: "Delete everything" moves the store's
    /// wipe count in its first leg. An export already uploading its sealed set stops at its next save
    /// — so never the head, which goes last — writes no accepted head (the wipe clears it with the
    /// rollback marks) and records no deferral (the wipe owns those). The wipe count alone stops it:
    /// the task's cancellation no longer can, since the tab closing cancels the same settle.
    @MainActor
    @Test func aWipeThatBeginsMidUploadStopsTheSetBeforeItsHead() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })
        interrupting.onFirstSave = { phone.host.sealedBackupWipeCount += 1 }

        #expect(await !phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == nil, "the wipe's set delete is never raced by a fresh head")
        #expect(cloud.sealedRecords.count == 1, "only the suffix chunk already in flight")
        #expect(phone.host.periodBackupLedger.acceptedHead == nil)
        #expect(phone.host.reuploadDeferrals[.periodData] == nil, "no deferral written behind the wipe")
    }

    /// The other half: a wipe that begins while the head itself is uploading cannot stop that save,
    /// but the accepted head the wipe cleared is never written back after it.
    @MainActor
    @Test func aWipeThatBeginsWhileTheHeadUploadsRecordsNoAcceptedHead() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        interrupting.onFirstSave = { phone.host.sealedBackupWipeCount += 1 }

        #expect(await !phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud) != nil, "the one save in flight landed")
        #expect(phone.host.periodBackupLedger.acceptedHead == nil, "but nothing recorded it")
        #expect(phone.host.reuploadDeferrals[.periodData] == nil)
    }

    /// Review U5-backup-v2 N-1: a sealed set now outlives the tab closing, so reopening it (or an
    /// un-hide settle) can ask for a second export while the first is uploading. Two at once could
    /// interleave their chunk writes — the older head landing last over the newer set — so the second
    /// defers, minting nothing, and the first's set carries everything.
    @MainActor
    @Test func onlyOnePeriodExportUploadsAtATime() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let holding = HoldingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: holding)
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        let first = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData) }
        for _ in 0..<1_000 where !holding.isHoldingSave { await Task.yield() }
        #expect(holding.isHoldingSave, "the first export is uploading")
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData), "the second defers")
        #expect(phone.host.reuploadDeferrals[.periodData] == true)
        #expect(SealedBackupGenerationStore(defaults: phone.generationDefaults).lastSeen(for: .periodData) == 1,
                "the second minted nothing")

        holding.releaseHeldSave()
        #expect(await first.value)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == PeriodBackupHead(writer: "phone", generation: 1))
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try phone.records.allIDs()))
        #expect(phone.host.reuploadDeferrals[.periodData] == false, "the first export's set carries everything")
    }

    /// Review U5-backup-v2 N-1, the mechanism: the period write seals every chunk before its first
    /// upload, still writes the head last, mints above the floor — and a chunk that fails to seal
    /// writes nothing and burns no generation.
    @MainActor
    @Test func theSealedUpFrontWriteSealsTheWholeSetBeforeItsFirstUpload() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let defaults = isolatedDefaults()
        let service = try PeriodBackupDevice.service(cloud, generationDefaults: defaults)
        var events: [String] = []

        let generation = try await service.reconcileChunkedSealedUpFront(
            payloadType: .periodData,
            chunkCount: 3,
            generationFloor: 4,
            chunk: { index in
                events.append("seal \(index)")
                return Data("chunk \(index)".utf8)
            },
            beforeEachUpload: { events.append("upload") }
        )
        #expect(generation == 5)
        #expect(events == ["seal 0", "seal 1", "seal 2", "upload", "upload", "upload"])
        #expect(cloud.sealedRecords.compactMap { $0["chunkIndex"] as? Int } == [2, 1, 0], "head last")
        let written = cloud.sealedRecordIdentities

        await #expect(throws: SealFailure.self) {
            try await service.reconcileChunkedSealedUpFront(
                payloadType: .periodData,
                chunkCount: 2,
                generationFloor: 0,
                chunk: { index in
                    guard index == 0 else { throw SealFailure() }
                    return Data()
                },
                beforeEachUpload: {}
            )
        }
        #expect(cloud.sealedRecordIdentities == written, "nothing uploaded")
        #expect(SealedBackupGenerationStore(defaults: defaults).lastSeen(for: .periodData) == 5, "no generation burned")
    }

    /// Review U5-backup-v2-L-U5-R1: a set sealed to an escrow key this iPhone does not hold — after
    /// an escrow adopt, the set this iPhone sealed under the key the adopt deleted — could never pass
    /// the compare-and-swap (it does not open), so the period backup was never re-sealed and nothing
    /// said why. It is now named, nothing is written over it, and the user's explicit "Replace"
    /// re-seals the history under this iPhone's key.
    @MainActor
    @Test func aSetSealedToAnotherKeyIsNamedAndReplacedOnlyByChoice() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let otherKeychain = "com.fernlet.period-v2.otherkey.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: otherKeychain) }
        let other = IdentityService(keychainService: otherKeychain)
        try other.ensureProvisioned()
        other.provisionBackupEscrowKeyForSealing()
        let sealer = PeriodBackupDevice(cloud: cloud, writer: "sealer", resolved: true, keychainService: otherKeychain)
        try sealer.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await sealer.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let sealedSet = cloud.sealedRecordIdentities

        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 2)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let unreadable = PeriodBackupHead(writer: PeriodBackupHead.unreadableWriter, generation: 1)
        #expect(phone.host.periodExportState == .sealedWithAnotherKey(unreadable))
        #expect(cloud.sealedRecordIdentities == sealedSet, "nothing is written over it before the user chooses")
        #expect(phone.host.recordedOutcomes[.periodData] == nil, "named by its own line, not as a failed restore")

        await phone.coordinator.replacePeriodBackupWithThisIPhone(unreadable)
        let head = try #require(try await PeriodBackupDevice.cloudHead(cloud), "this iPhone's key opens the new set")
        #expect(head.writer == "phone")
        #expect(phone.host.periodExportState == .clear)
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
    private let preferencesBox: PeriodBackupPreferencesBox

    /// The storage preferences the coordinator reads — settable mid-test (iCloud sync turned back on).
    var preferences: StoragePreferences {
        get { preferencesBox.value }
        set { preferencesBox.value = newValue }
    }

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
        let preferencesBox = PeriodBackupPreferencesBox(preferences)
        self.preferencesBox = preferencesBox
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
            preferencesProvider: { preferencesBox.value },
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

    /// A sealing service over `cloud` (its escrow key) with the rollback mark in `generationDefaults`.
    static func service(_ cloud: FakeSealedBackupCloud, generationDefaults: UserDefaults) throws -> SealedBackupService {
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return SealedBackupService(
            cloudDataService: cloudDataService(cloud.database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
        )
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

/// A chunk that fails to seal.
struct SealFailure: Error {}

/// Holds an export task so the transport's hook can cancel it mid-upload (the Private tab closing).
@MainActor
final class PeriodExportTaskBox {
    /// The export.
    var task: Task<Bool, Never>?
}

/// The storage preferences one ``PeriodBackupDevice``'s coordinator reads, boxed so a test can change
/// them between calls.
final class PeriodBackupPreferencesBox {
    /// The preferences.
    var value: StoragePreferences

    /// Boxes `value`.
    init(_ value: StoragePreferences) { self.value = value }
}

/// A transport whose stale-chunk prune fails once — its first record enumeration after a set's head
/// was saved throws, as CloudKit does when the network drops between the head upload and the prune.
final class PruneFailingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    /// Whether the next prune fails; armed by every head save while ``failsPrunes`` is on.
    private var failsNextEnumeration = false
    /// Whether a head save arms the failure.
    var failsPrunes = true

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        if failsNextEnumeration {
            failsNextEnumeration = false
            throw CKError(.networkUnavailable)
        }
        return try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        try await base.saveRecords(records)
        if failsPrunes, records.contains(where: { !$0.recordID.recordName.contains(".chunk.") }) {
            failsNextEnumeration = true
        }
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }
}

/// A transport that holds its first save until the test releases it — an upload still in flight.
final class HoldingCloudKitRecordDatabase: CloudKitRecordDatabase {
    private let base: InMemoryCloudKitRecordDatabase
    private var holdsNextSave = true
    private var heldSave: CheckedContinuation<Void, Never>?
    /// Whether a save is waiting for ``releaseHeldSave()``.
    var isHoldingSave: Bool { heldSave != nil }

    init(_ base: InMemoryCloudKitRecordDatabase) { self.base = base }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] { try await base.recordZoneIDs() }
    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        try await base.recordIDs(matching: recordType, in: zoneID)
    }
    func records(for recordIDs: [CKRecord.ID]) async throws -> [CKRecord] { try await base.records(for: recordIDs) }
    func saveRecords(_ records: [CKRecord]) async throws {
        if holdsNextSave {
            holdsNextSave = false
            await withCheckedContinuation { heldSave = $0 }
        }
        try await base.saveRecords(records)
    }
    func deleteRecords(with recordIDs: [CKRecord.ID]) async throws { try await base.deleteRecords(with: recordIDs) }

    /// Lets the held save land.
    func releaseHeldSave() {
        heldSave?.resume()
        heldSave = nil
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
