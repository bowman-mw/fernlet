//
//  SealedBackupIntimacyV2Tests.swift
//  FernletTests
//
//  The intimate-log Sealed backup on the v2 engine (journal and intimacy Sealed backup v2 design
//  2026-09-30, §8, unit B2), driven end to end through the coordinator over the in-memory cloud — one
//  `IntimacyBackupDevice` per iPhone — plus the FernletStore wiring (the one funnel, its mutation hook,
//  the one-time marker seed, the Privacy & Data row). Each test names the invariant (BVn) it pins.
//  The repository's merge rules (BV12) are in IntimacyLogRepositoryTests; the store's gated seams in
//  SensitiveSurfaceGateTests; the wipe and reset bookkeeping in DeleteAllDataTests.
//

import ProximityKit
import CloudKit
import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import PrivateHealthStore
import PrivateStoreCore
import Testing
@testable import Fernlet

/// One iPhone for the intimate-log v2 tests: its own sealed intimacy funnel (attached to its
/// coordinator, so its gate is the host's visibility and its hook the host's dirty mark), host
/// bookkeeping, rollback generation store, writer tag and device-only signing key — over a cloud and
/// an escrow key it shares with the other iPhones of a test.
@MainActor
final class IntimacyBackupDevice {
    let host: FakeSealedBackupHost
    /// This iPhone's one intimacy funnel.
    let logs: IntimacyLogStore
    let generationDefaults: UserDefaults
    let coordinator: SealedBackupCoordinator
    /// This install's writer tag.
    let writer: String
    /// This iPhone's keychain: the shared escrow key and its own signing key.
    let keychainService: String
    private let cloud: FakeSealedBackupCloud
    private let preferencesBox: PeriodBackupPreferencesBox

    /// The storage preferences the coordinator reads — settable mid-test.
    var preferences: StoragePreferences {
        get { preferencesBox.value }
        set { preferencesBox.value = newValue }
    }

    /// The Private tab's key on this iPhone.
    var key: SymmetricKey { host.sealedBackupContentKey ?? SymmetricKey(size: .bits256) }

    /// The v2 engine.
    var engine: SealedBackupV2Engine { coordinator.engine }

    /// The set this install has accepted (install-bound), if any.
    var acceptedStamp: SealedBackupHeadStamp? {
        host.sealedBackupBookkeeping.acceptedHead(.intimacyLogs, installTag: writer)?.stamp
    }

    /// The Privacy & Data row, by the mapping `FernletStore.intimacyBackupRowState` uses.
    var rowState: SealedBackupV2RowState {
        SealedBackupV2RowState.derive(
            status: host.v2Status[.intimacyLogs],
            intentPending: engine.intents[.intimacyLogs] != nil,
            rolledBackStamp: engine.rolledBackStamps[.intimacyLogs],
            persisted: SealedBackupV2RowState.Persisted(
                syncAndBackupOn: preferences.iCloudSyncEnabled && preferences.sealedBackupIntimacyEnabled,
                keptForOwner: host.restoreHold.keepsPreResetCopy(of: .intimacyLogs),
                restoreResolved: host.sealedBackupBookkeeping.restoreResolvedIsSet(.intimacyLogs),
                observed: host.sealedBackupBookkeeping.observedHead(.intimacyLogs, installTag: writer),
                dirty: host.isSealedBackupReuploadOwed(.intimacyLogs)
            )
        )
    }

    /// Creates an iPhone with iCloud sync and the intimate-log backup on.
    init(
        cloud: FakeSealedBackupCloud,
        writer name: String,
        resolved: Bool = false,
        database: (any CloudKitRecordDatabase)? = nil,
        preferences: StoragePreferences = IntimacyBackupDevice.backupOn
    ) {
        self.cloud = cloud
        let host = FakeSealedBackupHost()
        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        self.host = host
        logs = IntimacyLogStore(repository: IntimacyLogRepository(
            controller: PrivatePersistenceController(inMemory: true),
            defaults: UserDefaults(suiteName: "fernlet.tests.intimacyV2Latch.\(UUID().uuidString)") ?? .standard
        ))
        let generationDefaults = UserDefaults(suiteName: "fernlet.tests.intimacyGeneration.\(UUID().uuidString)") ?? .standard
        self.generationDefaults = generationDefaults
        let service = PeriodBackupDevice.phoneKeychain(sharing: cloud)
        keychainService = service
        let writer = PeriodBackupDevice.tag(name)
        self.writer = writer
        let transport = database ?? cloud.database
        let box = PeriodBackupPreferencesBox(preferences)
        preferencesBox = box
        coordinator = SealedBackupCoordinator(
            host: host,
            identityFactory: { IdentityService(keychainService: service) },
            serviceFactory: { identity in
                SealedBackupService(
                    cloudDataService: PeriodBackupDevice.cloudDataService(transport),
                    identityService: identity,
                    generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
                )
            },
            preferencesProvider: { box.value },
            periodRecordStore: PeriodBackupDevice.makeRecordStore(),
            intimacyLogStore: logs,
            writerTagProvider: { writer },
            backgroundTasks: RecordingBackgroundTasks()
        )
        if resolved { host.sealedBackupBookkeeping.markRestoreResolved(.intimacyLogs) }
    }

    /// Seals `seeded` into this iPhone's funnel (its gate is the host's visibility, open by default).
    func seed(_ seeded: [IntimacyLog], key: SymmetricKey? = nil) throws {
        for log in seeded { try logs.insert(log, contentKey: key ?? self.key) }
    }

    /// The ids in this iPhone's store.
    var storedIDs: Set<UUID> { Set((try? logs.allIDs()) ?? []) }

    /// Writes a v1 intimacy set (a bare `[IntimacyLog]` array) the way an earlier build did — under
    /// this iPhone's identity (its signing key) and generation store.
    func writeV1Set(_ written: [IntimacyLog]) async throws {
        let identity = IdentityService(keychainService: keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        let service = SealedBackupService(
            cloudDataService: PeriodBackupDevice.cloudDataService(cloud.database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
        )
        let chunk = try JSONEncoder().encode(written)
        try await service.reconcileChunked(payloadType: .intimacyLogs, chunkCount: 1) { _ in chunk }
    }

    /// iCloud sync on, the intimate-log backup on, its upload owed.
    nonisolated static let backupOn = StoragePreferences(
        iCloudSyncEnabled: true, sealedBackupIntimacyEnabled: true, sealedBackupIntimacyReuploadDeferred: true
    )

    /// A log on day `day` of a fixed calendar.
    static func log(_ note: String, day: Int, link: String? = nil) -> IntimacyLog {
        let date = Date(timeIntervalSinceReferenceDate: 790_000_000 + Double(day) * 86_400)
        return IntimacyLog(eventDate: date, note: note, healthKitExternalUUID: link, createdAt: date, updatedAt: date)
    }

    /// The head of the intimacy set in `cloud`, read the way E2 reads it.
    static func cloudHead(_ cloud: FakeSealedBackupCloud) async throws -> SealedBackupHeadStamp? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let record = try await reader.fetchHeadRecord(payloadType: .intimacyLogs) else { return nil }
        let plaintext = try reader.open(record)
        guard !SealedBackupV2Format.isV1(plaintext) else {
            return SealedBackupHeadStamp(writer: SealedBackupHeadStamp.v1Writer, generation: record.generation)
        }
        return SealedBackupHeadStamp(writer: try SealedBackupV2Format.header(of: plaintext).writer, generation: record.generation)
    }

    /// Every log in the intimacy set the head in `cloud` names.
    static func cloudLogs(_ cloud: FakeSealedBackupCloud) async throws -> [IntimacyLog] {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .intimacyLogs) else { return [] }
        let plaintext = try reader.open(head)
        if SealedBackupV2Format.isV1(plaintext) {
            let chunks = try await reader.restoreChunks(payloadType: .intimacyLogs) ?? []
            return try chunks.flatMap { try JSONDecoder().decode([IntimacyLog].self, from: $0) }
        }
        let set = try SealedBackupV2Format.header(of: plaintext).set
        let suffix = try await reader.fetchSuffixRecords(payloadType: .intimacyLogs, chunkCount: head.chunkCount, setTag: set)
        let plaintexts = [plaintext] + (try suffix.map { try reader.open($0) })
        return try plaintexts.flatMap { try JSONDecoder().decode(SealedBackupV2Envelope<IntimacyLog>.self, from: $0).records }
    }

    /// The intimacy record names in `cloud`.
    static func intimacyNames(_ cloud: FakeSealedBackupCloud) -> [String] {
        cloud.sealedRecords.map(\.recordID.recordName).filter { $0.contains(SealedBackupPayloadType.intimacyLogs.rawValue) }
    }
}

@Suite(.serialized)
struct SealedBackupIntimacyV2Tests {

    // MARK: - Restore: a merge, never empty-store-only (G3, BV13)

    /// A v1 intimacy set (a bare array an earlier build wrote) restores into a POPULATED store as an
    /// id-keyed merge — the old empty-store gate is gone — and the follow-through export publishes
    /// the union as this iPhone's v2 set in the same pass.
    @MainActor
    @Test func aV1SetMergesIntoAPopulatedStoreAndTheUnionBecomesThisIPhonesSet() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = IntimacyBackupDevice(cloud: cloud, writer: "old", resolved: true)
        let fromBackup = [IntimacyBackupDevice.log("a", day: 1), IntimacyBackupDevice.log("b", day: 2)]
        try await old.writeV1Set(fromBackup)
        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone")
        let local = IntimacyBackupDevice.log("already here", day: 3)
        try phone.seed([local])

        await phone.coordinator.settleV2Backup(.intimacyLogs)

        #expect(phone.host.recordedOutcomes[.intimacyLogs] == .restored(2))
        #expect(phone.storedIDs == Set(fromBackup.map(\.id) + [local.id]), "merged, the local log kept")
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.intimacyLogs))
        #expect(try await IntimacyBackupDevice.cloudHead(cloud)?.writer == phone.writer)
        #expect(Set(try await IntimacyBackupDevice.cloudLogs(cloud).map(\.id)) == phone.storedIDs, "BV10: the union")
        #expect(phone.host.reuploadDeferrals[.intimacyLogs] == false)
    }

    /// §5.5 (R1-BR-9): a v1 set's authorship is its AAD-bound, device-only signing key. The iPhone
    /// whose key did not seal it is held; the one whose key did writes over its own set unasked.
    @MainActor
    @Test func aV1SetIsOwnedOnlyByTheIPhoneWhoseSigningKeySealedIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = IntimacyBackupDevice(cloud: cloud, writer: "a", resolved: true)
        let phoneB = IntimacyBackupDevice(cloud: cloud, writer: "b", resolved: true)
        try await phoneB.writeV1Set([IntimacyBackupDevice.log("B's", day: 1)])
        try await phoneA.writeV1Set([IntimacyBackupDevice.log("A's", day: 2)])
        let v1Head = SealedBackupHeadStamp(writer: SealedBackupHeadStamp.v1Writer, generation: 1)
        let aSet = cloud.sealedRecordIdentities

        try phoneB.seed([IntimacyBackupDevice.log("B now", day: 3)])
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        #expect(cloud.sealedRecordIdentities == aSet, "B never writes over A's v1 backup")
        #expect(phoneB.rowState == .heldByAnotherDevice(v1Head))

        try phoneA.seed([IntimacyBackupDevice.log("A now", day: 4)])
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        #expect(phoneA.rowState == .none, "A's own signing key sealed it: A's own set")
        #expect(try await IntimacyBackupDevice.cloudHead(cloud)?.writer == phoneA.writer)
    }

    // MARK: - Two iPhones: held, Restore it here, Replace (Q9, BV4)

    /// Q-B1 default: one iPhone per slot. The second iPhone is held and names the set; "Restore it
    /// here" merges exactly that set and takes the slot with the union; the first iPhone is then held
    /// in turn, and its "Replace" writes its own logs over exactly the set it was shown.
    @MainActor
    @Test func twoIPhonesAreHeldAndChooseRestoreItHereOrReplace() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = IntimacyBackupDevice(cloud: cloud, writer: "a", resolved: true)
        let aLog = IntimacyBackupDevice.log("A's", day: 1)
        try phoneA.seed([aLog])
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let aHead = try #require(try await IntimacyBackupDevice.cloudHead(cloud))

        let phoneB = IntimacyBackupDevice(cloud: cloud, writer: "b", resolved: true)
        let bLog = IntimacyBackupDevice.log("B's", day: 2)
        try phoneB.seed([bLog])
        let aSet = cloud.sealedRecordIdentities
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        #expect(cloud.sealedRecordIdentities == aSet, "BV4: another iPhone's head is never replaced unasked")
        #expect(phoneB.rowState == .heldByAnotherDevice(aHead))
        #expect(phoneB.host.sealedBackupBookkeeping.observedHead(.intimacyLogs, installTag: phoneB.writer) == aHead,
                "persisted, so Privacy & Data names it after a relaunch")

        await phoneB.coordinator.restoreBackupHere(.intimacyLogs, aHead)
        #expect(phoneB.host.recordedOutcomes[.intimacyLogs] == .restored(1))
        #expect(phoneB.storedIDs == [aLog.id, bLog.id])
        let bHead = try #require(try await IntimacyBackupDevice.cloudHead(cloud))
        #expect(bHead.writer == phoneB.writer, "the export follows the explicit restore: B holds the slot")
        #expect(Set(try await IntimacyBackupDevice.cloudLogs(cloud).map(\.id)) == [aLog.id, bLog.id])

        phoneA.engine.hubSessionEnded()
        try phoneA.seed([IntimacyBackupDevice.log("A again", day: 3)])
        await phoneA.coordinator.settleV2Backup(.intimacyLogs)
        #expect(phoneA.rowState == .heldByAnotherDevice(bHead))
        await phoneA.coordinator.replaceBackupWithThisIPhone(.intimacyLogs, bHead)
        #expect(try await IntimacyBackupDevice.cloudHead(cloud)?.writer == phoneA.writer)
        #expect(Set(try await IntimacyBackupDevice.cloudLogs(cloud).map(\.id)) == phoneA.storedIDs,
                "Replace backs up this iPhone's logs over exactly the set it was shown")
    }

    /// §8.2 through the engine: the merge KEEPS a local log that opens (its note), fills its missing
    /// Health link from the backup, and replaces a local row that can never open.
    @MainActor
    @Test func theRestoreMergeKeepsLocalLogsFillsTheirLinkAndReplacesDeadOnes() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = IntimacyBackupDevice(cloud: cloud, writer: "a", resolved: true)
        let shared = IntimacyBackupDevice.log("A's note", day: 1, link: "hk-a")
        let deadHere = IntimacyBackupDevice.log("A's other", day: 2)
        try phoneA.seed([shared, deadHere])
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))

        let phoneB = IntimacyBackupDevice(cloud: cloud, writer: "b")
        var mine = shared
        mine.note = "B's note"
        mine.healthKitExternalUUID = nil
        try phoneB.seed([mine])
        try phoneB.seed([deadHere], key: SymmetricKey(size: .bits256))

        await phoneB.coordinator.settleV2Backup(.intimacyLogs)
        #expect(phoneB.host.recordedOutcomes[.intimacyLogs] == .restored(2), "one link filled, one dead row replaced")
        let stored = try phoneB.logs.backupChunk(ids: [shared.id, deadHere.id], contentKey: phoneB.key)
        #expect(stored.records.map(\.note) == ["B's note", "A's other"], "the local note always wins")
        #expect(stored.records.first?.healthKitExternalUUID == "hk-a", "the missing link is filled")
        #expect(stored.deadIDs.isEmpty)
    }

    // MARK: - Dirty marking: the one funnel and its hook (BV9, §4.4)

    /// Every write through the app's ONE intimacy funnel — insert, a Health link recorded, a restore
    /// merge, a batch delete, delete-all — moves the host's mutation epoch and owes the upload, without
    /// a preferences read; a delete that removed nothing moves nothing.
    @MainActor
    @Test func everyWriteThroughTheFunnelMarksTheUploadOwed() throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone")
        phone.host.recordSealedBackupReuploadDeferred(false, payloadType: .intimacyLogs)
        let log = IntimacyBackupDevice.log("one", day: 1)
        try phone.seed([log])
        #expect(phone.host.sealedBackupMutationEpoch(.intimacyLogs) == 1)
        #expect(phone.host.isSealedBackupReuploadOwed(.intimacyLogs))
        try phone.logs.markSavedToHealthKit(id: log.id, externalUUID: UUID())
        _ = try phone.logs.restoreMerging([IntimacyBackupDevice.log("two", day: 2)], contentKey: phone.key)
        #expect(try phone.logs.delete(ids: [UUID()]) == 0)
        #expect(phone.host.sealedBackupMutationEpoch(.intimacyLogs) == 3, "a delete that removed nothing moves nothing")
        #expect(try phone.logs.delete(ids: [log.id]) == 1)
        try phone.logs.deleteAll()
        try phone.logs.deleteAll()
        #expect(phone.host.sealedBackupMutationEpoch(.intimacyLogs) == 5, "the empty store's delete-all moved nothing")
        #expect(phone.host.sealedBackupMutationEpoch(.periodData) == 0, "one epoch per payload")
    }

    /// §9: the app-lock reset purges the sealed rows through the keyless controller purge
    /// (`PrivatePersistenceController.purgeEncryptedEntities`), never through a store instance, so no
    /// mutation hook fires — the reset leaves the owed upload as the funnel left it (held for the owner).
    @MainActor
    @Test func theResetPurgeFiresNoIntimacyMutationHook() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let funnel = IntimacyLogStore(repository: IntimacyLogRepository(
            controller: controller,
            defaults: UserDefaults(suiteName: "fernlet.tests.resetPurgeHook.\(UUID().uuidString)") ?? .standard
        ))
        let host = FakeSealedBackupHost()
        let coordinator = SealedBackupCoordinator(host: host, periodRecordStore: PeriodBackupDevice.makeRecordStore(), intimacyLogStore: funnel)
        try funnel.insert(IntimacyBackupDevice.log("before the reset", day: 1), contentKey: SymmetricKey(size: .bits256))
        #expect(host.sealedBackupMutationEpoch(.intimacyLogs) == 1)

        try controller.purgeEncryptedEntities()

        #expect(try funnel.backupLogCount() == 0, "the purge removed the row")
        #expect(host.sealedBackupMutationEpoch(.intimacyLogs) == 1, "and fired no hook")
        _ = coordinator
    }

    /// The FernletStore half: the funnel handed over at launch wiring carries the store's hook, so a
    /// log saved from the sheet (the same instance) owes the upload — and the one-time seed of the
    /// intimate-log marker waits for that funnel (BV14): seeded from ITS latch once attached, and the
    /// enabled backup owes one complete export in the same step; never seeded again.
    @MainActor
    @Test func theAttachedFunnelCarriesTheStoresHookAndSeedsTheMarkerOnce() throws {
        let store = makeTestStore()
        let defaults = UserDefaults(suiteName: "fernlet.tests.intimacySeed.\(UUID().uuidString)") ?? .standard
        store.sealedBackupBookkeeping = SealedBackupBookkeeping(
            defaults: defaults,
            legacyLatch: { [unowned store] payload in store.sealedBackupLegacyLatch(payload) }
        )
        store.sealedBackupPreferencesProvider = { IntimacyBackupDevice.backupOn }
        store.recordSealedBackupReuploadDeferred(false, payloadType: .intimacyLogs)
        store.seedSealedBackupBookkeepingOnce()
        #expect(defaults.object(forKey: SealedBackupBookkeeping.intimacyRestoreResolvedKey) == nil,
                "no funnel attached: nothing is seeded")

        let funnel = IntimacyLogStore(repository: IntimacyLogRepository(
            controller: PrivatePersistenceController(inMemory: true),
            defaults: UserDefaults(suiteName: "fernlet.tests.intimacySeedLatch.\(UUID().uuidString)") ?? .standard
        ))
        let seeder = funnel
        seeder.attachVisibilityGate { true }
        try seeder.insert(IntimacyBackupDevice.log("before the update", day: 1), contentKey: SymmetricKey(size: .bits256))
        store.attachIntimacyLogStore(funnel)
        store.seedSealedBackupBookkeepingOnce()
        #expect(store.sealedBackupBookkeeping.restoreResolvedIsSet(.intimacyLogs), "seeded from the funnel's latch")
        #expect(store.sealedBackupIntimacyReuploadDeferred, "an enabled backup owes one complete v2 export")
        #expect(!store.sealedBackupBookkeeping.seedRestoreMarkerIfAbsent(.intimacyLogs), "seeded once")

        store.recordSealedBackupReuploadDeferred(false, payloadType: .intimacyLogs)
        let epoch = store.sealedBackupMutationEpoch(.intimacyLogs)
        funnel.attachVisibilityGate { true }
        try funnel.insert(IntimacyBackupDevice.log("saved from the sheet", day: 2), contentKey: SymmetricKey(size: .bits256))
        #expect(store.sealedBackupMutationEpoch(.intimacyLogs) == epoch + 1)
        #expect(store.sealedBackupIntimacyReuploadDeferred, "the sheet's write owes the upload")
    }

    // MARK: - Hidden, under 16, duress (BV3, BV17, BV18)

    /// BV3/BV17: a restore suspended in its CloudKit fetch while intimacy is hidden (or the age gate
    /// closes) resumes into a failed gate — nothing decrypted, merged or written, no status, the marker
    /// still unresolved, the cloud copy untouched; the same pass runs once the surface is open again.
    @MainActor
    @Test func aRestoreSuspendedWhileIntimacyHidesDecryptsAndWritesNothing() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let source = IntimacyBackupDevice(cloud: cloud, writer: "source", resolved: true)
        try source.seed([IntimacyBackupDevice.log("in the cloud", day: 1)])
        #expect(await source.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let backedUp = cloud.sealedRecordIdentities
        let suspending = SuspendingFetchCloudKitRecordDatabase(cloud.database)
        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone", database: suspending)

        let pass = Task { await phone.coordinator.settleV2Backup(.intimacyLogs) }
        #expect(await yieldUntil { suspending.isHoldingFetch })
        phone.host.isIntimacyTrackingVisible = false
        suspending.releaseHeldFetch()
        await pass.value

        #expect(phone.engine.decryptCount == 0, "nothing was decrypted behind the closed gate")
        #expect(phone.storedIDs.isEmpty)
        #expect(phone.host.v2Status[.intimacyLogs] == nil, "a hidden surface drops its status")
        #expect(!phone.host.sealedBackupBookkeeping.restoreResolvedIsSet(.intimacyLogs))
        #expect(cloud.sealedRecordIdentities == backedUp)
        #expect(phone.rowState == .waitingForRestore, "(the row a VISIBLE surface would show)")

        phone.host.isIntimacyTrackingVisible = true
        phone.engine.hubSessionEnded()
        await phone.coordinator.settleV2Backup(.intimacyLogs)
        #expect(phone.storedIDs.count == 1, "un-hidden, the restore merges at the next visit")
    }

    /// BV18: a duress session starting while a restore is suspended stops it the same way.
    @MainActor
    @Test func aDuressSessionStopsASuspendedIntimacyRestore() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let source = IntimacyBackupDevice(cloud: cloud, writer: "source", resolved: true)
        try source.seed([IntimacyBackupDevice.log("in the cloud", day: 1)])
        #expect(await source.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let suspending = SuspendingFetchCloudKitRecordDatabase(cloud.database)
        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone", database: suspending)

        let pass = Task { await phone.coordinator.settleV2Backup(.intimacyLogs) }
        #expect(await yieldUntil { suspending.isHoldingFetch })
        phone.host.duressSessionActive = true
        suspending.releaseHeldFetch()
        await pass.value

        #expect(phone.engine.decryptCount == 0)
        #expect(phone.storedIDs.isEmpty)
        #expect(suspending.savedNames.isEmpty)
    }

    /// BV17: while hidden nothing is fetched, probed, prepared or written, and NOTHING the user owns
    /// moves — the switch, the cloud copy, the marker, the accepted head, the observation and the owed
    /// upload stay exactly as they were (hiding never deletes); un-hiding then exports what was owed.
    @MainActor
    @Test func aHiddenSurfaceLeavesEverythingAsItWasAndUnhidingExportsWhatWasOwed() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let counting = CountingCloudKitRecordDatabase(cloud.database)
        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: counting)
        try phone.seed([IntimacyBackupDevice.log("one", day: 1)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let accepted = phone.acceptedStamp
        let backedUp = cloud.sealedRecordIdentities
        try phone.seed([IntimacyBackupDevice.log("two", day: 2)])
        let callsBefore = counting.calls

        phone.host.isIntimacyTrackingVisible = false
        phone.engine.hubSessionEnded()
        await phone.coordinator.settleV2Backup(.intimacyLogs)
        #expect(counting.calls == callsBefore, "no head fetch, probe, prepare or save while hidden")
        #expect(cloud.sealedRecordIdentities == backedUp)
        #expect(phone.preferences.sealedBackupIntimacyEnabled, "the switch is untouched")
        #expect(phone.acceptedStamp == accepted)
        #expect(phone.host.sealedBackupBookkeeping.restoreResolvedIsSet(.intimacyLogs))
        #expect(phone.host.isSealedBackupReuploadOwed(.intimacyLogs), "still owed")
        #expect(phone.host.v2Status[.intimacyLogs] == nil)

        phone.host.isIntimacyTrackingVisible = true
        phone.engine.request([.intimacyLogs], trigger: .unhide)
        #expect(await yieldUntil { phone.host.v2Status[.intimacyLogs] == .upToDate })
        #expect(try await IntimacyBackupDevice.cloudLogs(cloud).count == 2, "the un-hide settle exported the owed log")
    }

    /// BV19: the intimate-log backup never reads or writes HealthKit — the backup carries the sealed
    /// log (its date, note and Health link) and a restore is not a user save. Pinned at the source: no
    /// file on the backup path can even name a HealthKit service.
    @Test func theIntimacyBackupPathNeverReachesHealthKit() throws {
        let files = [
            "App/Fernlet/IntimacyBackupAdapter.swift", "App/Fernlet/SealedBackupV2Engine.swift",
            "App/Fernlet/SealedBackupV2Engine+Restore.swift", "App/Fernlet/SealedBackupV2Engine+Export.swift",
            "App/Fernlet/SealedBackupV2Engine+Commit.swift", "App/Fernlet/SealedBackupV2Adapter.swift",
            "FernletKit/Sources/PrivateHealthStore/IntimacyLogStore.swift",
            "FernletKit/Sources/PrivateHealthStore/IntimacyLogRepository.swift"
        ]
        for file in files {
            let source = try String(contentsOf: RepoRoot.url(file), encoding: .utf8)
            for banned in ["import HealthKit", "HKHealthStore", "HealthKitServicing", "HealthKitService("] {
                #expect(!source.contains(banned), "\(file) names \(banned)")
            }
        }
    }

    // MARK: - E1, the owner hold, a diverged install (BV13, BV16)

    /// E1 with an EMPTY store (was `reuploadIsRefusedFromAnEmptyIntimacyStore…`): before this install
    /// has pulled its backup an empty store never exports over the cloud copy; once the restore
    /// resolved, empty is real — deleting every log here reaches the backup at the next visit.
    @MainActor
    @Test func anEmptyStoreExportsOnlyOnceItsRestoreHasResolved() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let source = IntimacyBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try source.seed([IntimacyBackupDevice.log("history", day: 1)])
        #expect(await source.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let history = cloud.sealedRecordIdentities

        let fresh = IntimacyBackupDevice(cloud: cloud, writer: "phone-new")
        #expect(await fresh.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        #expect(cloud.sealedRecordIdentities == history, "E1: an unresolved empty store writes nothing")
        #expect(fresh.rowState == .waitingForRestore)

        await fresh.coordinator.settleV2Backup(.intimacyLogs)
        #expect(fresh.storedIDs.count == 1, "restored")
        try fresh.logs.deleteAll()
        fresh.engine.hubSessionEnded()
        await fresh.coordinator.settleV2Backup(.intimacyLogs)
        #expect(try await IntimacyBackupDevice.cloudLogs(cloud).isEmpty, "after resolution, empty is real")
        #expect(try await IntimacyBackupDevice.cloudHead(cloud)?.writer == fresh.writer)
    }

    /// The one-time seed reads the legacy latch: an install that already held — or deleted — logs
    /// seeds its marker RESOLVED, so no restore ever merges the stale cloud copy back in behind the
    /// user's deletes; the other iPhone's set is named instead, and only an explicit choice moves it.
    @MainActor
    @Test func aDivergedInstallSeedsItsMarkerResolvedAndNeverMergesTheStaleCopy() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let other = IntimacyBackupDevice(cloud: cloud, writer: "other", resolved: true)
        try other.seed([IntimacyBackupDevice.log("deleted here", day: 1)])
        #expect(await other.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))

        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone")
        phone.host.intimacyRestoreSeed = true
        #expect(phone.host.sealedBackupBookkeeping.seedRestoreMarkerIfAbsent(.intimacyLogs))
        await phone.coordinator.settleV2Backup(.intimacyLogs)
        #expect(phone.host.recordedOutcomes[.intimacyLogs] == nil, "no restore ran")
        #expect(phone.storedIDs.isEmpty, "nothing was merged back")
        guard case .heldByAnotherDevice = phone.rowState else {
            Issue.record("the other iPhone's set was not named")
            return
        }
    }

    /// BV16 / Q-B2: after an app-lock reset no restore of any trigger runs and no export writes over
    /// the pre-reset copy — Retry and "Restore it here" included — until the owner's checked
    /// "Restore", which releases the hold on the tap and merges the copy back before backing up.
    @MainActor
    @Test func theOwnerHoldStopsEveryTriggerUntilTheOwnersRestore() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let before = IntimacyBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let history = IntimacyBackupDevice.log("before the reset", day: 1)
        try before.seed([history])
        #expect(await before.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let preReset = cloud.sealedRecordIdentities
        let head = try #require(try await IntimacyBackupDevice.cloudHead(cloud))

        let after = IntimacyBackupDevice(cloud: cloud, writer: "phone")
        after.host.restoreHold.hold(keepingCopiesFrom: IntimacyBackupDevice.backupOn)
        try after.seed([IntimacyBackupDevice.log("after the reset", day: 2)])
        await after.coordinator.settleV2Backup(.intimacyLogs)
        _ = await after.coordinator.restoreIntimacyBackup(initiatedByUser: true)
        await after.coordinator.restoreBackupHere(.intimacyLogs, head)
        await after.coordinator.retryDeferredReuploadIfNeeded(payloadType: .intimacyLogs)
        #expect(cloud.sealedRecordIdentities == preReset, "nothing replaced the pre-reset copy")
        #expect(after.storedIDs.count == 1, "nothing was restored either")
        #expect(after.rowState == .none, "the shared owner line speaks for it")

        // (Privacy & Data offers no "Restore it here" while the hold keeps the copy; the one recorded
        // above through the engine's API is dropped like the reset drops every pending choice.)
        after.engine.dropPendingChoices()
        await after.coordinator.releaseRestoreHoldForOwner()
        #expect(after.storedIDs.contains(history.id), "the owner's restore merged the history back")
        #expect(Set(try await IntimacyBackupDevice.cloudLogs(cloud).map(\.id)) == after.storedIDs,
                "then the union is backed up, never the post-reset store alone")
    }

    // MARK: - Turning off, Remove them, the mid-export stop (BV27, BV22, §4.7)

    /// BV27 / R2-F3: turning the switch off on a slot observed as another iPhone's keeps that backup;
    /// on this iPhone's own slot it deletes it; "Delete everything" deletes whoever wrote it.
    @MainActor
    @Test func turningOffKeepsAnotherIPhonesSlotAndDeletesItsOwn() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = IntimacyBackupDevice(cloud: cloud, writer: "a", resolved: true)
        try phoneA.seed([IntimacyBackupDevice.log("A's", day: 1)])
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let phoneB = IntimacyBackupDevice(cloud: cloud, writer: "b", resolved: true)
        try phoneB.seed([IntimacyBackupDevice.log("B's", day: 2)])
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        let aSet = cloud.sealedRecordIdentities

        #expect(await phoneB.coordinator.setSealedBackupEnabled(false, payloadType: .intimacyLogs, deletingAnySlot: false))
        #expect(cloud.sealedRecordIdentities == aSet, "B's switch keeps A's backup")
        #expect(await phoneA.coordinator.setSealedBackupEnabled(false, payloadType: .intimacyLogs, deletingAnySlot: false))
        #expect(IntimacyBackupDevice.intimacyNames(cloud).isEmpty, "A's own switch deletes A's backup, every chunk")

        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        #expect(await phoneB.coordinator.setSealedBackupEnabled(false, payloadType: .intimacyLogs))
        #expect(IntimacyBackupDevice.intimacyNames(cloud).isEmpty, "delete-all's reach: any slot")
    }

    /// BV22 / R2-F12: logs this iPhone can never open pause the backup with nothing written; "Remove
    /// them" re-checks exactly the shown ids at the next pass, deletes only those still dead, and the
    /// export follows.
    @MainActor
    @Test func unopenableLogsPauseTheBackupAndRemoveThemDeletesOnlyThoseStillDead() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let good = IntimacyBackupDevice.log("opens", day: 1)
        let dead = IntimacyBackupDevice.log("sealed under a lost key", day: 2)
        try phone.seed([good])
        try phone.seed([dead], key: SymmetricKey(size: .bits256))

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs))
        #expect(phone.rowState == .paused([dead.id]))
        #expect(IntimacyBackupDevice.intimacyNames(cloud).isEmpty, "paused: nothing written")

        await phone.coordinator.removeUnopenableEntries(.intimacyLogs, ids: [dead.id, good.id])
        #expect(phone.storedIDs == [good.id], "only the shown id that is still dead went")
        #expect(Set(try await IntimacyBackupDevice.cloudLogs(cloud).map(\.id)) == [good.id])
        #expect(phone.rowState == .none)
    }

    /// The open finding on 8f808232, for the intimate logs: turning the backup off while an export is
    /// mid-upload stops the engine first, so no chunk or head lands after the delete.
    @MainActor
    @Test func turningTheIntimacyBackupOffMidExportWritesNoSetAfterTheDelete() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let holding = HoldingCloudKitRecordDatabase(cloud.database)
        let phone = IntimacyBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: holding)
        try phone.seed((0..<300).map { IntimacyBackupDevice.log("log \($0)", day: $0) })

        let export = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .intimacyLogs) }
        #expect(await yieldUntil { holding.isHoldingSave })
        let turnOff = Task {
            await phone.coordinator.setSealedBackupEnabled(false, payloadType: .intimacyLogs, deletingAnySlot: false)
        }
        #expect(await yieldUntil { phone.engine.disabling.contains(.intimacyLogs) })
        holding.releaseHeldSave()
        #expect(await turnOff.value)
        #expect(await !export.value)
        #expect(cloud.sealedRecords.isEmpty, "no chunk or head was written after the delete")
    }

    // MARK: - The Privacy & Data row (§10.1, BV17)

    /// The one status-to-row mapping: every engine status names its row; after a relaunch the
    /// persisted state speaks in order (an unresolved restore, another iPhone's set, an owed upload);
    /// sync or the backup off, and the owner hold, show nothing here; a pending choice says to finish.
    @MainActor
    @Test func theRowStateMapsEveryStatusAndThePersistedStateInOrder() {
        let stamp = SealedBackupHeadStamp(writer: "w", generation: 2)
        let on = SealedBackupV2RowState.Persisted(syncAndBackupOn: true, keptForOwner: false, restoreResolved: true, observed: nil, dirty: false)
        func row(_ status: SealedBackupV2Status?, _ persisted: SealedBackupV2RowState.Persisted = on,
                 pending: Bool = false, rolledBack: SealedBackupHeadStamp? = nil) -> SealedBackupV2RowState {
            SealedBackupV2RowState.derive(status: status, intentPending: pending, rolledBackStamp: rolledBack, persisted: persisted)
        }
        #expect(row(.upToDate) == .none)
        #expect(row(.heldByAnotherDevice(stamp)) == .heldByAnotherDevice(stamp))
        #expect(row(.waitingForRestore(.deferredKeyNotSynced)) == .waitingForKey(restoring: true))
        #expect(row(.waitingForBackupKey) == .waitingForKey(restoring: false))
        #expect(row(.waitingForRestore(.rolledBack), rolledBack: stamp) == .olderThanSeen(stamp))
        #expect(row(.waitingForRestore(.notRecognized)) == .damaged)
        #expect(row(.waitingForRestore(.deferredTransient)) == .waitingForRestore)
        #expect(row(.headSealedWithOtherKey) == .sealedWithOtherKey)
        #expect(row(.headDamaged) == .damaged)
        #expect(row(.needsNewerFernlet) == .needsNewerFernlet)
        #expect(row(.paused(unopenableIDs: [])) == .paused([]))
        #expect(row(.tooLarge) == .tooLarge)
        #expect(row(.failed) == .failed)
        #expect(row(.heldForOwner) == .none)
        #expect(row(.heldByAnotherDevice(stamp), pending: true) == .finishing)

        var relaunched = on
        relaunched.restoreResolved = false
        relaunched.observed = stamp
        relaunched.dirty = true
        #expect(row(nil, relaunched) == .waitingForRestore, "an unresolved restore speaks first")
        relaunched.restoreResolved = true
        #expect(row(nil, relaunched) == .heldByAnotherDevice(stamp), "then the observation")
        relaunched.observed = nil
        #expect(row(nil, relaunched) == .catchUp, "then the owed upload")
        #expect(row(.upToDate, relaunched) == .catchUp, "a change since the export is caught up next visit")
        relaunched.keptForOwner = true
        #expect(row(.heldByAnotherDevice(stamp), relaunched) == .none, "the shared owner line speaks")
        #expect(row(.failed, SealedBackupV2RowState.Persisted(syncAndBackupOn: false, keptForOwner: false,
                                                               restoreResolved: true, observed: nil, dirty: true)) == .none,
                "sync or the backup off: the switches speak for themselves")
    }
}

