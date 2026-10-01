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
        let v2Chunk = try PeriodBackupDevice.v2Chunk([logged])

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
        let chunk = try PeriodBackupDevice.v2Chunk([PeriodBackupDevice.record(day: 1)], total: 1)
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


    // MARK: - Period backup on the v2 engine: the export (design 2026-09-30 §4.2 X; period I16, I29, I30)

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
        #expect(phone.host.v2Status[.periodData] == .waitingForRestore(nil))

        phone.host.sealedBackupBookkeeping.markRestoreResolved(.periodData)
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(!cloud.sealedRecords.isEmpty, "control: once resolved, the same call exports")
        #expect(phone.host.reuploadDeferrals[.periodData] == false, "and the owed upload is discharged")
        #expect(phone.host.v2Status[.periodData] == .upToDate)
    }

    /// G: no Private tab key, no export (and no network): a deferral, nothing written.
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

    /// E3 (R2-F12, BV5): the prepare decrypts EVERY record before the first write. One record this key
    /// cannot open pauses the whole export — named for Privacy & Data — and nothing reaches iCloud,
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
        #expect(SealedBackupGenerationStore(defaults: phone.generationDefaults).lastSeen(for: .periodData) == 0,
                "no generation is burned by an export that never committed (BV8)")
    }

    /// E3, the undecided half: a record whose install-binding read did not answer fails the export
    /// (retried, backed off) and writes nothing; it is never called unopenable, and the switch stays on.
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
        #expect(phone.host.v2Status[.periodData] == .failed)
        #expect(phone.host.reuploadDeferrals[.periodData] == true)
    }

    /// The chunks are built from the snapshot: a 600-record history goes up as three chunks — the
    /// head under the bare name, the two suffix chunks under names scoped to their set (§5.2) — whose
    /// head carries this install's writer, and another iPhone restores every record.
    @MainActor
    @Test func theV2ExportWritesTheWholeSnapshotAndAnotherIPhoneRestoresIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        let history = (0..<600).map { PeriodBackupDevice.record(day: $0) }
        try first.seed(history)

        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecords.count == 3)
        let names = Set(cloud.sealedRecords.map(\.recordID.recordName))
        #expect(names.contains("sealed-backup.periodData"))
        #expect(names.filter { $0.hasPrefix("sealed-backup.periodData.chunk.") }.allSatisfy { $0.split(separator: ".").count == 5 },
                "every suffix chunk is scoped to its set: chunk.<i>.<set>")
        let head = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(head.writer == first.writer)
        #expect(first.acceptedStamp == head, "the set it wrote is the set it accepts")
        #expect(first.backgroundTasks.begun == 1 && first.backgroundTasks.open.isEmpty,
                "the commit ran inside one background-task assertion, ended on return (R2-F6)")

        let second = PeriodBackupDevice(cloud: cloud, writer: "second")
        #expect(await second.coordinator.restorePeriodBackup() == .restored(600))
        let restored = try second.records.allRecords(contentKey: second.key).records
        #expect(restored.sorted { $0.id.uuidString < $1.id.uuidString } == history.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    /// Period I29 / BV9: the owed upload clears only when no cycle record changed while the export
    /// ran. A record logged mid-upload is not in the set, so the upload stays owed — and the next
    /// export carries it, after which the cloud holds exactly what the store holds.
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

    /// The mutation hook (R2-F3) and R10: a restore marks the upload owed — through the merge's own
    /// write and the restore's bookkeeping — so the next pass publishes the merged history.
    @MainActor
    @Test func aRestoreThatChangedRecordsMarksTheUploadOwed() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let first = PeriodBackupDevice(cloud: cloud, writer: "first", resolved: true)
        try first.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let second = PeriodBackupDevice(cloud: cloud, writer: "second")
        #expect(await second.coordinator.restorePeriodBackup() == .restored(1))
        #expect(second.host.sealedBackupMutationEpoch(.periodData) >= 1)
        #expect(second.host.reuploadDeferrals[.periodData] == true)
    }

    /// Period I30 / BV4: an export never replaces a set this install does not own or accept. The second
    /// iPhone's export is held and named — nothing written — until the user chooses "Replace it with
    /// this iPhone's history"; that set is minted ABOVE the first iPhone's, so the first iPhone's own
    /// restore of it is not mistaken for a rollback. The first iPhone is then held in turn.
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
        #expect(second.host.sealedBackupBookkeeping.observedHead(.periodData, installTag: second.writer) == firstHead,
                "the foreign head is persisted, so Privacy & Data names it after a relaunch (R2-F13b)")
        #expect(second.host.reuploadDeferrals[.periodData] == true)

        await second.coordinator.replacePeriodBackupWithThisIPhone(firstHead)
        let secondHead = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(secondHead.writer == second.writer)
        #expect(secondHead.generation > firstHead.generation, "minted above the set it replaced")
        #expect(second.host.periodExportState == .clear)
        #expect(second.host.sealedBackupBookkeeping.observedHead(.periodData, installTag: second.writer) == nil)

        #expect(await first.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(first.host.periodExportState == .heldByAnotherDevice(secondHead), "the compare-and-swap cuts both ways")
        await first.coordinator.restorePeriodBackupHere(secondHead)
        #expect(first.host.recordedOutcomes[.periodData] == .restored(1), "not .rolledBack: the floor kept it above")
        #expect(try first.records.recordCount() == 2)
    }

    /// The replace accepts exactly the set the user was shown: if the other iPhone wrote a newer set
    /// since, the export is held again rather than replacing a set nobody saw.
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

    /// Design §4.8 item 7 / §5.5 (R1-BR-9), replacing period §9.10's seed rule: a v1 set names no
    /// writer, so its authorship comes from its AAD-BOUND signing key — device-only, never in a device
    /// backup — never from a generation coincidence. Two iPhones that each backed up once both wrote
    /// generation 1; the one whose key did not seal the set is held, and the one whose key did writes
    /// over its own set with no question asked.
    @MainActor
    @Test func aV1SetIsOwnedOnlyByTheIPhoneWhoseSigningKeySealedIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = PeriodBackupDevice(cloud: cloud, writer: "a", resolved: true)
        let phoneB = PeriodBackupDevice(cloud: cloud, writer: "b", resolved: true)
        try await phoneB.writeV1Set([MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-01", note: "B's")])
        let aNote = MenstrualNarrative(hkExternalUUID: UUID().uuidString, dateKey: "2026-05-02", note: "A's")
        try await phoneA.writeV1Set([aNote])
        let v1Head = SealedBackupHeadStamp(writer: SealedBackupHeadStamp.v1Writer, generation: 1)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == v1Head, "both iPhones wrote generation 1; A wrote last")
        let aSet = cloud.sealedRecordIdentities

        try phoneB.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(cloud.sealedRecordIdentities == aSet, "B never writes over A's v1 backup on a generation coincidence")
        #expect(phoneB.host.periodExportState == .heldByAnotherDevice(v1Head))

        try phoneA.seed([PeriodBackupDevice.record(day: 2)])
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phoneA.host.periodExportState == .clear, "A's own signing key sealed it: A's own set")
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.writer == phoneA.writer)

        await phoneB.coordinator.restorePeriodBackupHere(try #require(try await PeriodBackupDevice.cloudHead(cloud)))
        #expect(phoneB.host.recordedOutcomes[.periodData] == .restored(1), "B merges A's set on its explicit choice")
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.writer == phoneB.writer, "the export follows the explicit restore")
    }

    /// Review U5-backup-v2-C-U5-2, kept: generation counters are per device and "Delete everything"
    /// zeroes the deleting iPhone's, so the other iPhone's set can be numbered BELOW this iPhone's
    /// rollback floor. "Restore it here" of exactly the set it was shown still merges it, and the
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
        let bHead = PeriodBackupDevice.stamp("b", 1)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == bHead)

        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phoneA.host.periodExportState == .heldByAnotherDevice(bHead))
        await phoneA.coordinator.restorePeriodBackupHere(bHead)
        #expect(phoneA.host.recordedOutcomes[.periodData] == .restored(1), "not .rolledBack: the user chose this set")
        #expect(try phoneA.records.recordCount() == 2)
        let after = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(after.writer == phoneA.writer && after.generation == 4, "the export follows, above both iPhones' numbers")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try phoneA.records.allIDs()))
    }

    /// R6 / R1-BR-4: a "Restore it here" whose set was replaced since merges nothing and returns to the
    /// held state, naming the NEW set with both choices; this install's resolved restore is never
    /// reopened.
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
        let bHead = PeriodBackupDevice.stamp("b", 1)

        await phoneA.coordinator.restorePeriodBackupHere(PeriodBackupDevice.stamp("someone-else", 1))
        #expect(phoneA.host.recordedOutcomes[.periodData] == nil, "a set the user never saw is not restored, nor failed")
        #expect(phoneA.host.periodExportState == .heldByAnotherDevice(bHead), "the set in iCloud is named instead")
        #expect(try phoneA.records.recordCount() == 1, "and nothing merged")
        #expect(phoneA.host.sealedBackupBookkeeping.isRestoreResolved(.periodData), "the resolved restore was never reopened")

        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phoneA.host.periodExportState == .heldByAnotherDevice(bHead), "the set is named again, Replace still offered")
    }

    /// Design §5.5 (R1-BR-13): E2 is writer-first. A head this install wrote whose save landed while
    /// the client saw a failure (so no bookkeeping recorded it) is its own — never "saved from another
    /// iPhone" — and the next export writes above it. The rollback floor was never raised by the
    /// uncommitted write (§5.4).
    @MainActor
    @Test func aHeadThisInstallWroteIsItsOwnEvenWhenItsCommitWasNeverRecorded() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let flaky = LandedButFailedCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: flaky)
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData), "a failed commit keeps the switch on")
        let written = try #require(try await PeriodBackupDevice.cloudHead(cloud))
        #expect(written.writer == phone.writer && phone.acceptedStamp == nil, "head up, never recorded")
        #expect(phone.host.v2Status[.periodData] == .failed)
        #expect(SealedBackupGenerationStore(defaults: phone.generationDefaults).lastSeen(for: .periodData) == 0)

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(phone.host.periodExportState == .clear, "its own set is not another iPhone's")
        #expect(try await PeriodBackupDevice.cloudHead(cloud)?.generation == written.generation + 1)
        #expect(phone.acceptedStamp?.generation == written.generation + 1)
    }

    /// Design §5.2 (R2-F6, BV6): the Private tab closing mid-upload stops nothing — the set was sealed
    /// before its first save and the commit decrypts nothing, so it lands whole over the previous
    /// two-chunk set (whose chunks the prune then removes), and a new iPhone restores it.
    @MainActor
    @Test func anExportFinishesItsSealedSetWhenPrivateClosesMidUpload() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == PeriodBackupDevice.stamp("phone", 1))
        #expect(cloud.sealedRecords.count == 2, "the prior set has two chunks")

        try phone.seed((300..<320).map { PeriodBackupDevice.record(day: $0) })
        interrupting.onFirstSave = {
            phone.host.sealedBackupContentKey = nil   // the tab closed: the key provider answers nil
        }
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))

        let head = PeriodBackupDevice.stamp("phone", 2)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == head, "the new set's head landed")
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud).count == 320, "one whole set, every chunk at generation 2")
        #expect(cloud.sealedRecords.count == 2, "the prune removed the older set's suffix chunk")
        #expect(phone.acceptedStamp == head)
        #expect(phone.host.reuploadDeferrals[.periodData] == false, "nothing owed: the set is complete")
        let newPhone = PeriodBackupDevice(cloud: cloud, writer: "new")
        #expect(await newPhone.coordinator.restorePeriodBackup() == .restored(320), "and it restores")
    }

    /// BV15 / §4.7: "Delete everything" moves the work epoch in its first leg. An export already
    /// uploading stops before its next save — so never the head, which goes last, and the previous
    /// head (none here) is untouched — and records no bookkeeping. The upload is never claimed done.
    @MainActor
    @Test func aWipeThatBeginsMidUploadStopsTheSetBeforeItsHead() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.seed((0..<300).map { PeriodBackupDevice.record(day: $0) })
        interrupting.onFirstSave = { phone.host.sealedBackupWorkEpoch += 1 }

        #expect(await !phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == nil, "the wipe's set delete is never raced by a fresh head")
        #expect(cloud.sealedRecords.count == 1, "only the suffix chunk already in flight — an orphan, under its own set's name")
        #expect(phone.acceptedStamp == nil)
        #expect(phone.host.reuploadDeferrals[.periodData] != false, "a stopped pass never claims the upload done")
    }

    /// The other half: a wipe that begins while the head itself is uploading cannot stop that save,
    /// but no bookkeeping — the accepted head, the rollback floor — is written after it.
    @MainActor
    @Test func aWipeThatBeginsWhileTheHeadUploadsRecordsNoAcceptedHead() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        interrupting.onFirstSave = { phone.host.sealedBackupWorkEpoch += 1 }

        #expect(await !phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudHead(cloud) != nil, "the one save in flight landed")
        #expect(phone.acceptedStamp == nil, "but nothing recorded it")
        #expect(SealedBackupGenerationStore(defaults: phone.generationDefaults).lastSeen(for: .periodData) == 0)
        #expect(phone.host.reuploadDeferrals[.periodData] != false)
    }

    /// BV6 / R2-F15: ONE serial worker. A second export asked for while the first is uploading waits —
    /// it starts nothing (no fetch, no prepare, no save) until the first has finished — and then runs
    /// its own pass; the cloud ends with one whole set.
    @MainActor
    @Test func onlyOnePeriodPassRunsAtATime() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let holding = HoldingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: holding)
        try phone.seed([PeriodBackupDevice.record(day: 1)])

        let first = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData) }
        #expect(await yieldUntil { holding.isHoldingSave }, "the first export is uploading")
        try phone.seed([PeriodBackupDevice.record(day: 2)])
        let second = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData) }
        for _ in 0..<200 { await Task.yield() }
        #expect(holding.savedCount == 0, "nothing else ran while the first pass held its save")
        #expect(phone.backgroundTasks.begun == 1, "the second pass has not reached a commit")

        holding.releaseHeldSave()
        #expect(await first.value)
        #expect(await second.value)
        #expect(try await PeriodBackupDevice.cloudHead(cloud) == PeriodBackupDevice.stamp("phone", 2))
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(try phone.records.allIDs()))
        #expect(phone.host.reuploadDeferrals[.periodData] == false)
    }

    /// X7 (BV5): every chunk is decrypted and sealed BEFORE the first save. A record deleted while the
    /// commit uploads is still in the set it sealed (the set is ciphertext by then), and the deletion
    /// keeps the upload owed for the next export.
    @MainActor
    @Test func everyChunkIsSealedBeforeTheFirstSave() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        let history = (0..<600).map { PeriodBackupDevice.record(day: $0) }
        try phone.seed(history)
        let doomed = try #require(history.first?.id)
        interrupting.onFirstSave = {
            do {
                #expect(try phone.records.delete(ids: [doomed]) == 1)
            } catch {
                Issue.record("the mid-upload delete failed: \(error)")
            }
        }

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        #expect(try await PeriodBackupDevice.cloudRecordIDs(cloud) == Set(history.map(\.id)), "the set sealed before the delete")
        #expect(phone.host.reuploadDeferrals[.periodData] == true, "the delete is owed to the next export")
    }

    /// Design §5.6 (R2-F1): a head no escrow key on this iPhone opens is named — "Start a new backup"
    /// is the only way over it — and nothing is written before the user chooses. The explicit start
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
        #expect(phone.host.periodExportState == .sealedWithAnotherKey)
        #expect(phone.host.v2Status[.periodData] == .headSealedWithOtherKey)
        #expect(cloud.sealedRecordIdentities == sealedSet, "nothing is written over it before the user chooses")
        #expect(phone.host.recordedOutcomes[.periodData] == nil, "named by its own line, not as a failed restore")

        await phone.coordinator.startNewPeriodBackup()
        let head = try #require(try await PeriodBackupDevice.cloudHead(cloud), "this iPhone's key opens the new set")
        #expect(head.writer == phone.writer)
        #expect(phone.host.periodExportState == .clear)
    }

    /// The writer tag: deterministic per install binding, distinct across installs, 32 hex
    /// characters, and absent (the export fails transiently) when the binding is unavailable.
    @MainActor
    @Test func theWriterTagNamesTheInstall() {
        let installA = Data(repeating: 0xA1, count: 16)
        let installB = Data(repeating: 0xB2, count: 16)
        #expect(SealedBackupWriterTag.tag(forBinding: installA) == SealedBackupWriterTag.tag(forBinding: installA))
        #expect(SealedBackupWriterTag.tag(forBinding: installA) != SealedBackupWriterTag.tag(forBinding: installB))
        #expect(SealedBackupSetTag.isValid(SealedBackupWriterTag.tag(forBinding: installA)))
        DeviceBindingID.$testOverride.withValue(.identifier(installA)) {
            #expect(SealedBackupWriterTag.current() == SealedBackupWriterTag.tag(forBinding: installA))
        }
        DeviceBindingID.$testOverride.withValue(.unavailable) {
            #expect(SealedBackupWriterTag.current() == nil)
        }
        let minted = SealedBackupSetTag.mint()
        #expect(SealedBackupSetTag.isValid(minted) && minted != SealedBackupSetTag.mint(), "a fresh random set tag per pass")
    }

    /// Design §9 (R2-F11): "Delete everything"'s generation reset clears the rollback marks but KEEPS
    /// the v2 accepted head — a set surviving a failed delete is then this install's own to the next
    /// export, which overwrites it and finishes the wipe, instead of being offered back as another
    /// iPhone's.
    @MainActor
    @Test func theWipesGenerationResetKeepsTheAcceptedHead() {
        let defaults = isolatedDefaults()
        var store = SealedBackupGenerationStore(defaults: defaults)
        #expect(store.mintNext(for: .periodData) == 1)
        let bookkeeping = SealedBackupBookkeeping(defaults: defaults, legacyLatch: { _ in false })
        let accepted = SealedBackupAcceptedHead(stamp: PeriodBackupDevice.stamp("phone", 3), saltPrefix: "00112233")
        bookkeeping.recordAcceptedHead(accepted, .periodData, installTag: PeriodBackupDevice.tag("phone"))

        store.reset()

        #expect(store.lastSeen(for: .periodData) == 0)
        #expect(bookkeeping.acceptedHead(.periodData, installTag: PeriodBackupDevice.tag("phone")) == accepted)
    }
}

/// A chunk that fails to seal.
struct SealFailure: Error {}
