//
//  SealedBackupJournalV2Tests.swift
//  FernletTests
//
//  The journal Sealed backup on the v2 engine (journal and intimacy Sealed backup v2 design
//  2026-09-30, §7, unit B3), driven end to end through the coordinator over the in-memory cloud — one
//  `JournalBackupDevice` per iPhone — plus the FernletStore wiring (the sealing coordinator's hook,
//  duress, the Privacy & Data row). Each test names the invariant (BVn) it pins. The repository's merge
//  and classified read (BV11) are in JournalNarrativeRepositoryTests; the wipe and reset bookkeeping in
//  DeleteAllDataTests; the marker's one-time seed in SealedBackupRestoreTests.
//

import ProximityKit
import CloudKit
import CloudKitSync
import CoreData
import CryptoKit
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import Foundation
import LocalPersistence
import PrivateMemoryStore
import PrivateStoreCore
import Testing
@testable import Fernlet

/// One iPhone for the journal v2 tests: its own sealed journal store (in memory, with an isolated
/// latch), a throwaway keychain for its journal DEVICE key, host bookkeeping, rollback generation
/// store, writer tag and device-only signing key — over a cloud and an escrow key it shares with the
/// other iPhones of a test.
@MainActor
final class JournalBackupDevice {
    let host: FakeSealedBackupHost
    /// This iPhone's sealed store (its controller, so a test can reach a row's plaintext columns).
    let controller: PrivatePersistenceController
    /// This iPhone's sealed journal repository.
    let journal: JournalNarrativeRepository
    /// The keychain service of this iPhone's journal device key.
    let deviceKeyService: String
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
        host.sealedBackupBookkeeping.acceptedHead(.journalNarratives, installTag: writer)?.stamp
    }

    /// The Privacy & Data row, by the mapping `FernletStore.journalBackupRowState` uses.
    var rowState: SealedBackupV2RowState {
        SealedBackupV2RowState.derive(
            status: host.v2Status[.journalNarratives],
            intentPending: engine.intents[.journalNarratives] != nil,
            rolledBackStamp: engine.rolledBackStamps[.journalNarratives],
            persisted: SealedBackupV2RowState.Persisted(
                syncAndBackupOn: preferences.iCloudSyncEnabled && preferences.sealedBackupJournalEnabled,
                keptForOwner: host.restoreHold.keepsPreResetCopy(of: .journalNarratives),
                restoreResolved: host.sealedBackupBookkeeping.restoreResolvedIsSet(.journalNarratives),
                observed: host.sealedBackupBookkeeping.observedHead(.journalNarratives, installTag: writer),
                dirty: host.isSealedBackupReuploadOwed(.journalNarratives)
            )
        )
    }

    /// Creates an iPhone with iCloud sync and the journal backup on.
    init(
        cloud: FakeSealedBackupCloud,
        writer name: String,
        resolved: Bool = false,
        database: (any CloudKitRecordDatabase)? = nil,
        preferences: StoragePreferences = JournalBackupDevice.backupOn,
        clock: (() -> Date)? = nil
    ) {
        self.cloud = cloud
        let host = FakeSealedBackupHost()
        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        self.host = host
        let controller = PrivatePersistenceController(inMemory: true)
        self.controller = controller
        let journal = JournalNarrativeRepository(
            controller: controller,
            defaults: UserDefaults(suiteName: "fernlet.tests.journalV2Latch.\(UUID().uuidString)") ?? .standard
        )
        self.journal = journal
        let deviceKeyService = "com.fernlet.journal-v2.device.\(UUID().uuidString)"
        self.deviceKeyService = deviceKeyService
        let generationDefaults = UserDefaults(suiteName: "fernlet.tests.journalGeneration.\(UUID().uuidString)") ?? .standard
        self.generationDefaults = generationDefaults
        let service = PeriodBackupDevice.phoneKeychain(sharing: cloud)
        keychainService = service
        cloud.phoneKeychainServices.append(deviceKeyService)
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
            journalRepository: journal,
            journalDeviceKeyService: deviceKeyService,
            writerTagProvider: { writer },
            clock: clock,
            backgroundTasks: RecordingBackgroundTasks()
        )
        if resolved { host.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives) }
    }

    /// Writes `entry` the way the journal does — sealed under `key` (the hub key by default), a day
    /// skeleton on the host, and the upload owed (`JournalSealingCoordinator`'s hook).
    func write(_ entry: JournalNarrative, key: SymmetricKey? = nil) throws {
        try journal.insert(entry, contentKey: key ?? self.key)
        var day = host.days[entry.dayKey] ?? FernletDay(date: entry.dayKey)
        if !day.journals.contains(where: { $0.id == entry.id }) {
            day.journals.append(JournalEntry(id: entry.id, text: "", tag: entry.tag, date: entry.entryDate, emotions: []))
        }
        host.days[entry.dayKey] = day
        host.markSealedBackupDirty(.journalNarratives)
    }

    /// Mints this iPhone's journal DEVICE key (what `JournalSealingCoordinator` seals with while the
    /// Private tab is closed) and returns it.
    @discardableResult
    func provisionDeviceKey(_ key: SymmetricKey = SymmetricKey(size: .bits256)) -> SymmetricKey {
        #expect(KeychainItem.store(key.rawBytes, for: .deviceJournalKey, service: deviceKeyService) == errSecSuccess)
        return key
    }

    /// The ids in this iPhone's store.
    var storedIDs: Set<UUID> { Set((try? journal.allIDs()) ?? []) }

    /// Every entry in this iPhone's store, opened under the hub key or the device key.
    func entries() throws -> [JournalNarrative] {
        let deviceKey = SealedDeviceKeyRead.read(.deviceJournalKey, service: deviceKeyService).journalBackupDeviceKey
        return try journal.backupRecords(ids: try journal.allIDs(), hubKey: key, deviceKey: deviceKey).records
    }

    /// Writes a v1 journal set (a bare `[JournalNarrative]` array) the way an earlier build did — under
    /// this iPhone's identity (its signing key) and generation store.
    func writeV1Set(_ written: [JournalNarrative]) async throws {
        let identity = IdentityService(keychainService: keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        let service = SealedBackupService(
            cloudDataService: PeriodBackupDevice.cloudDataService(cloud.database),
            identityService: identity,
            generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
        )
        let chunk = try JSONEncoder().encode(written)
        try await service.reconcileChunked(payloadType: .journalNarratives, chunkCount: 1) { _ in chunk }
    }

    /// iCloud sync on, the journal backup on, its upload owed.
    nonisolated static let backupOn = StoragePreferences(
        iCloudSyncEnabled: true, sealedBackupJournalEnabled: true, sealedBackupJournalReuploadDeferred: true
    )

    /// An entry on day `day` of a fixed calendar.
    static func entry(_ text: String, day: Int, id: UUID = UUID(), emotions: [String] = []) -> JournalNarrative {
        let date = Date(timeIntervalSinceReferenceDate: 790_000_000 + Double(day) * 86_400)
        return JournalNarrative(
            id: id, dayKey: FernletDate.dayKey(for: date), tag: .good, entryDate: date,
            text: text, emotions: emotions, createdAt: date, updatedAt: date
        )
    }

    /// The head of the journal set in `cloud`, read the way E2 reads it.
    static func cloudHead(_ cloud: FakeSealedBackupCloud) async throws -> SealedBackupHeadStamp? {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let record = try await reader.fetchHeadRecord(payloadType: .journalNarratives) else { return nil }
        let plaintext = try reader.open(record)
        guard !SealedBackupV2Format.isV1(plaintext) else {
            return SealedBackupHeadStamp(writer: SealedBackupHeadStamp.v1Writer, generation: record.generation)
        }
        return SealedBackupHeadStamp(writer: try SealedBackupV2Format.header(of: plaintext).writer, generation: record.generation)
    }

    /// Every entry in the journal set the head in `cloud` names.
    static func cloudEntries(_ cloud: FakeSealedBackupCloud) async throws -> [JournalNarrative] {
        let reader = try PeriodBackupDevice.reader(cloud)
        guard let head = try await reader.fetchHeadRecord(payloadType: .journalNarratives) else { return [] }
        let plaintext = try reader.open(head)
        if SealedBackupV2Format.isV1(plaintext) {
            let chunks = try await reader.restoreChunks(payloadType: .journalNarratives) ?? []
            return try chunks.flatMap { try JSONDecoder().decode([JournalNarrative].self, from: $0) }
        }
        let set = try SealedBackupV2Format.header(of: plaintext).set
        let suffix = try await reader.fetchSuffixRecords(payloadType: .journalNarratives, chunkCount: head.chunkCount, setTag: set)
        let plaintexts = [plaintext] + (try suffix.map { try reader.open($0) })
        return try plaintexts.flatMap { try JSONDecoder().decode(SealedBackupV2Envelope<JournalNarrative>.self, from: $0).records }
    }

    /// The journal record names in `cloud`.
    static func journalNames(_ cloud: FakeSealedBackupCloud) -> [String] {
        cloud.sealedRecords.map(\.recordID.recordName).filter { $0.contains(SealedBackupPayloadType.journalNarratives.rawValue) }
    }
}

@Suite(.serialized)
struct SealedBackupJournalV2Tests {

    // MARK: - Both keys, the referenced snapshot (§7.1, §7.2, BV5, BV26)

    /// §7.2 / R1-BR-16: an entry written from Home — sealed under the journal DEVICE key while the
    /// Private tab was closed, never folded — is backed up as it is at the next hub settle, on any
    /// section: the fold is no backup precondition.
    @MainActor
    @Test func aHomeEntryUnderTheDeviceKeyExportsAtTheNextVisitWithoutTheFold() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let deviceKey = phone.provisionDeviceKey()
        let fromHome = JournalBackupDevice.entry("written from Home", day: 1)
        let fromHub = JournalBackupDevice.entry("written in Private", day: 2)
        try phone.write(fromHome, key: deviceKey)
        try phone.write(fromHub)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.v2Status[.journalNarratives] == .upToDate)
        let backedUp = try await JournalBackupDevice.cloudEntries(cloud)
        #expect(Set(backedUp.map(\.text)) == ["written from Home", "written in Private"])
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == phone.writer)
        #expect(phone.host.reuploadDeferrals[.journalNarratives] == false)
    }

    /// BV5 / R1-BR-8: an edit made from Home while an export is in flight (it re-seals the entry under
    /// the device key with a fresh stamp) does not abort it — the read is total under both keys — and
    /// the set carries the edited text.
    @MainActor
    @Test func aHomeEditDuringAnExportDoesNotAbortIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let suspending = SuspendingFetchCloudKitRecordDatabase(cloud.database)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: suspending)
        let deviceKey = phone.provisionDeviceKey()
        let entry = JournalBackupDevice.entry("first words", day: 1)
        try phone.write(entry)

        let pass = Task { await phone.coordinator.settleV2Backup(.journalNarratives) }
        #expect(await yieldUntil { suspending.isHoldingFetch }, "the export is reading the head (E2)")
        var edited = entry
        edited.text = "edited from Home"
        try phone.write(edited, key: deviceKey)
        suspending.releaseHeldFetch()
        await pass.value

        #expect(phone.host.v2Status[.journalNarratives] == .upToDate, "the edit did not abort the export")
        #expect(try await JournalBackupDevice.cloudEntries(cloud).map(\.text) == ["edited from Home"])
    }

    /// BV26 / R1-BR-6: an ORPHAN sealed row — no day skeleton references it (a delete whose row delete
    /// failed, an entry the other iPhone deleted with sync on) — is never exported, so it can never
    /// come back through a restore.
    @MainActor
    @Test func anOrphanRowIsNeverExported() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let kept = JournalBackupDevice.entry("on its day", day: 1)
        try phone.write(kept)
        let orphan = JournalBackupDevice.entry("its skeleton is gone", day: 2)
        try phone.journal.insert(orphan, contentKey: phone.key)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(try await JournalBackupDevice.cloudEntries(cloud).map(\.id) == [kept.id])
        #expect(phone.storedIDs == [kept.id, orphan.id], "the orphan stays on the device, encrypted")
    }

    // MARK: - Pause, Remove, needs a newer build (BV5, BV22, R2-F12)

    /// BV22 / R2-F12: entries no key opens pause the backup with nothing written. "Remove them"
    /// re-classifies exactly the shown ids under EVERY key this iPhone holds at the next pass — one
    /// that the device key now opens is kept — deletes only those still dead, and the export follows.
    @MainActor
    @Test func deadEntriesPauseAndRemoveThemReclassifiesUnderEveryKey() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let good = JournalBackupDevice.entry("opens", day: 1)
        let laterKey = SymmetricKey(size: .bits256)
        let comesBack = JournalBackupDevice.entry("under a device key not here yet", day: 2)
        let dead = JournalBackupDevice.entry("under a key that is gone", day: 3)
        try phone.write(good)
        try phone.write(comesBack, key: laterKey)
        try phone.write(dead, key: SymmetricKey(size: .bits256))

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        #expect(phone.rowState == .paused([comesBack.id, dead.id]))
        #expect(JournalBackupDevice.journalNames(cloud).isEmpty, "paused: nothing written")

        phone.provisionDeviceKey(laterKey)
        await phone.coordinator.removeUnopenableEntries(.journalNarratives, ids: [comesBack.id, dead.id])
        #expect(phone.storedIDs == [good.id, comesBack.id], "only the entry that is still dead went")
        #expect(Set(try await JournalBackupDevice.cloudEntries(cloud).map(\.id)) == [good.id, comesBack.id])
        #expect(phone.rowState == .none)
    }

    /// §7.2 / R2-F12: an entry that opens but carries a feeling tag this build does not know needs a
    /// newer Fernlet — never dead, never removed, never exported as a gap: the export stops with
    /// nothing written.
    @MainActor
    @Test func anUnknownFeelingTagNeedsANewerFernletNeverDead() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let future = JournalBackupDevice.entry("written by a newer Fernlet", day: 1)
        try phone.write(future)
        let context = phone.controller.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
        let row = try #require(try context.fetch(request).first)
        row.setValue("a-tag-from-the-future", forKey: "tag")
        try context.save()

        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        #expect(phone.rowState == .needsNewerFernlet)
        #expect(JournalBackupDevice.journalNames(cloud).isEmpty)
        await phone.coordinator.removeUnopenableEntries(.journalNarratives, ids: [future.id])
        #expect(phone.storedIDs == [future.id], "an entry a newer build can read is never removed")
    }

    // MARK: - The merge restore (§7.3, BV11, BV13, BV25)

    /// BV11 end to end, the erase-and-restore case the v1 empty-store gate failed: entries that survived
    /// under the DEVICE key no longer block the restore. The same entry with the same words is left as
    /// it is; one whose words differ keeps this iPhone's text AND gets the backup's as its own entry;
    /// one only in the backup is added. The follow-through export then publishes the union.
    @MainActor
    @Test func theMergeKeepsSurvivingDeviceKeyEntriesAndForksADifferentText() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        let same = JournalBackupDevice.entry("unchanged", day: 1)
        let changed = JournalBackupDevice.entry("the backup's words", day: 2)
        let onlyThere = JournalBackupDevice.entry("only in the backup", day: 3)
        for entry in [same, changed, onlyThere] { try old.write(entry) }
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))

        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        let deviceKey = phone.provisionDeviceKey()
        try phone.write(same, key: deviceKey)
        var local = changed
        local.text = "this iPhone's words"
        try phone.write(local, key: deviceKey)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(2), "one added, one forked")
        let texts = try phone.entries().map(\.text)
        #expect(Set(texts) == ["unchanged", "this iPhone's words", "the backup's words", "only in the backup"])
        #expect(texts.count == 4, "nothing overwritten, nothing deleted")
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.journalNarratives))
        #expect(Set(try await JournalBackupDevice.cloudEntries(cloud).map(\.text)) == Set(texts), "BV10: the union")
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == phone.writer)
    }

    /// A v1 journal set (a bare array an earlier build wrote) merges into a populated store — the old
    /// empty-store gate is gone — and the follow-through export publishes the union as this iPhone's v2
    /// set in the same pass.
    @MainActor
    @Test func aV1JournalSetMergesIntoAPopulatedStore() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        let fromBackup = [JournalBackupDevice.entry("a", day: 1), JournalBackupDevice.entry("b", day: 2)]
        try await old.writeV1Set(fromBackup)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone")
        let local = JournalBackupDevice.entry("already here", day: 3)
        try phone.write(local)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .restored(2))
        #expect(phone.storedIDs == Set(fromBackup.map(\.id) + [local.id]))
        #expect(Set(phone.host.days.values.flatMap(\.journals).map(\.id)) == phone.storedIDs, "every entry has its skeleton")
        #expect(Set(try await JournalBackupDevice.cloudEntries(cloud).map(\.id)) == phone.storedIDs)
    }

    /// BV25 / R1-BR-6: a skeleton write that fails leaves the restore UNRESOLVED (the merged rows
    /// stay, E1 holds the export); the next session's merge is idempotent — it changes nothing — and
    /// re-adds the missing skeletons, which resolves it.
    @MainActor
    @Test func aFailedSkeletonWriteLeavesTheRestoreUnresolvedAndTheNextVisitRebuildsIt() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let old = JournalBackupDevice(cloud: cloud, writer: "old", resolved: true)
        let entry = JournalBackupDevice.entry("needs its skeleton", day: 1)
        try old.write(entry)
        #expect(await old.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let backedUp = cloud.sealedRecordIdentities

        let clock = ManualClock()
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", clock: { clock.now })
        phone.host.failsSkeletonWrites = true
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.storedIDs == [entry.id], "the merged row stays")
        #expect(phone.host.days.isEmpty, "no skeleton was written")
        #expect(!phone.host.sealedBackupBookkeeping.isRestoreResolved(.journalNarratives))
        #expect(cloud.sealedRecordIdentities == backedUp, "E1: nothing exported while unresolved")

        phone.host.failsSkeletonWrites = false
        phone.engine.hubSessionEnded()
        clock.advance(SealedBackupV2Engine.failureBackoff + 1)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.days.values.flatMap(\.journals).map(\.id) == [entry.id], "the skeleton was rebuilt")
        #expect(phone.host.sealedBackupBookkeeping.isRestoreResolved(.journalNarratives))
        #expect(phone.storedIDs == [entry.id], "the second merge was a no-op")
    }

    // MARK: - Two iPhones (Q9, BV4)

    /// Q-B1 for the journal: the second iPhone is held and names the set; "Restore it here" merges
    /// exactly that set (an entry changed on both keeps both versions) and takes the slot with the
    /// union; the first iPhone is then held in turn, and its "Replace" writes its own journal over
    /// exactly the set it was shown.
    @MainActor
    @Test func twoIPhonesAreHeldAndChooseRestoreItHereOrReplace() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phoneA = JournalBackupDevice(cloud: cloud, writer: "a", resolved: true)
        let shared = JournalBackupDevice.entry("A's words", day: 1)
        try phoneA.write(shared)
        #expect(await phoneA.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let aHead = try #require(try await JournalBackupDevice.cloudHead(cloud))

        let phoneB = JournalBackupDevice(cloud: cloud, writer: "b", resolved: true)
        var bVersion = shared
        bVersion.text = "B's words"
        try phoneB.write(bVersion)
        let aSet = cloud.sealedRecordIdentities
        #expect(await phoneB.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        #expect(cloud.sealedRecordIdentities == aSet, "BV4: another iPhone's head is never replaced unasked")
        #expect(phoneB.rowState == .heldByAnotherDevice(aHead))

        await phoneB.coordinator.restoreBackupHere(.journalNarratives, aHead)
        #expect(Set(try phoneB.entries().map(\.text)) == ["A's words", "B's words"], "both versions kept")
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == phoneB.writer, "B took the slot")
        #expect(phoneB.rowState == .none)

        phoneA.engine.hubSessionEnded()
        try phoneA.write(JournalBackupDevice.entry("A again", day: 2))
        await phoneA.coordinator.settleV2Backup(.journalNarratives)
        guard case .heldByAnotherDevice(let bHead) = phoneA.rowState else {
            Issue.record("A was not held after B took the slot")
            return
        }
        await phoneA.coordinator.replaceBackupWithThisIPhone(.journalNarratives, bHead)
        #expect(try await JournalBackupDevice.cloudHead(cloud)?.writer == phoneA.writer)
        #expect(Set(try await JournalBackupDevice.cloudEntries(cloud).map(\.text)) == ["A's words", "A again"])
    }

    // MARK: - Dirty (BV9), duress (BV18), the mid-export stop (§4.7)

    /// BV9: a journal change while the export is uploading moves the mutation epoch, so the owed
    /// upload is NOT cleared by that commit; the next visit exports the change.
    @MainActor
    @Test func aJournalChangeDuringTheExportKeepsTheUploadOwed() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let interrupting = InterruptingCloudKitRecordDatabase(cloud.database)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: interrupting)
        try phone.write(JournalBackupDevice.entry("first", day: 1))
        let late = JournalBackupDevice.entry("written while it uploads", day: 2)
        interrupting.onFirstSave = {
            do { try phone.write(late) } catch { Issue.record("the mid-upload write failed: \(error)") }
        }

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.reuploadDeferrals[.journalNarratives] == true, "the change during the upload is still owed")
        #expect(try await JournalBackupDevice.cloudEntries(cloud).map(\.text) == ["first"])

        phone.engine.hubSessionEnded()
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(Set(try await JournalBackupDevice.cloudEntries(cloud).map(\.text)) == ["first", "written while it uploads"])
        #expect(phone.host.reuploadDeferrals[.journalNarratives] == false)
    }

    /// BV18 / §7.6: a duress session that begins while a journal restore is suspended in its CloudKit
    /// fetch stops it before any decrypt or write — nothing opened, merged, skeletoned or saved.
    @MainActor
    @Test func aDuressSessionStopsASuspendedJournalRestore() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let source = JournalBackupDevice(cloud: cloud, writer: "source", resolved: true)
        try source.write(JournalBackupDevice.entry("in the cloud", day: 1))
        #expect(await source.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let suspending = SuspendingFetchCloudKitRecordDatabase(cloud.database)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", database: suspending)

        let pass = Task { await phone.coordinator.settleV2Backup(.journalNarratives) }
        #expect(await yieldUntil { suspending.isHoldingFetch })
        phone.host.duressSessionActive = true
        suspending.releaseHeldFetch()
        await pass.value

        #expect(phone.engine.decryptCount == 0)
        #expect(phone.storedIDs.isEmpty)
        #expect(phone.host.reinstatedJournalSkeletons.isEmpty)
        #expect(suspending.savedNames.isEmpty)
        #expect(phone.host.v2Status[.journalNarratives] == nil, "duress drops the status: nothing is named")
    }

    /// The open finding on 8f808232, for the journal: turning the backup off while an export is
    /// mid-upload stops the engine first, so no chunk or head lands after the delete.
    @MainActor
    @Test func turningTheJournalBackupOffMidExportWritesNoSetAfterTheDelete() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let holding = HoldingCloudKitRecordDatabase(cloud.database)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true, database: holding)
        for day in 0..<300 { try phone.write(JournalBackupDevice.entry("entry \(day)", day: day)) }

        let export = Task { await phone.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives) }
        #expect(await yieldUntil { holding.isHoldingSave })
        let turnOff = Task {
            await phone.coordinator.setSealedBackupEnabled(false, payloadType: .journalNarratives, deletingAnySlot: false)
        }
        #expect(await yieldUntil { phone.engine.disabling.contains(.journalNarratives) })
        holding.releaseHeldSave()
        #expect(await turnOff.value)
        #expect(await !export.value)
        #expect(cloud.sealedRecords.isEmpty, "no chunk or head was written after the delete")
    }

    // MARK: - Review B3 fix round 1

    /// R1 / D-B3-1, at the engine: while the day store cannot say its read is complete, the referenced
    /// ids are unknown and the snapshot fails — the export ends `.failed` with NOTHING written (the full
    /// backup in iCloud stays exactly as it was) and the upload still owed; once the day store reads
    /// whole again, the next visit exports every entry.
    @MainActor
    @Test func anIncompleteDayStoreReadExportsNothingOverTheFullBackup() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let clock = ManualClock()
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true, clock: { clock.now })
        try phone.write(JournalBackupDevice.entry("first", day: 1))
        try phone.write(JournalBackupDevice.entry("second", day: 2))
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let fullSet = cloud.sealedRecordIdentities

        phone.host.dayStoreReadIncomplete = true
        try phone.write(JournalBackupDevice.entry("third", day: 3))
        phone.engine.hubSessionEnded()
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.v2Status[.journalNarratives] == .failed)
        #expect(cloud.sealedRecordIdentities == fullSet, "the full backup was not replaced by a truncated set")
        #expect(phone.host.reuploadDeferrals[.journalNarratives] == true, "the upload is still owed")

        phone.host.dayStoreReadIncomplete = false
        phone.engine.hubSessionEnded()
        clock.advance(SealedBackupV2Engine.failureBackoff + 1)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(Set(try await JournalBackupDevice.cloudEntries(cloud).map(\.text)) == ["first", "second", "third"])
    }

    /// R1 / D-B3-1, in the store over its REAL day repository: a day row this build cannot decode (here
    /// planted; in life another iPhone's newer build with sync on, or a corrupt row) makes the
    /// referenced journal ids unknown — never the ids of the days that did decode, which would drop
    /// every entry on the unread day from the backup — while the plain read the screens use still
    /// serves the days it can. Once the row reads again, so do the ids.
    @MainActor
    @Test func theStoresReferencedJournalIDsFailClosedOnADayRowThatWillNotDecode() throws {
        let (store, repository, _) = makeTestStoreWithRepositories()
        let readable = Self.skeleton(dayKey: "2026-03-01")
        let unreadable = Self.skeleton(dayKey: "2026-03-02")
        #expect(store.reinstateJournalEntries(from: [readable, unreadable]))
        #expect(store.sealedBackupJournalReferencedIDs?.isSuperset(of: [readable.id, unreadable.id]) == true)

        let context = repository.persistenceController.container.viewContext
        let request = NSFetchRequest<NSManagedObject>(entityName: "DayRecord")
        request.predicate = NSPredicate(format: "dateKey == %@", unreadable.dayKey)
        let row = try #require(try context.fetch(request).first)
        let payload = row.value(forKey: "payloadData") as? Data
        row.setValue(Data("{\"a newer shape\":true}".utf8), forKey: "payloadData")
        try context.save()
        repository.invalidateCache()
        #expect(store.sealedBackupJournalReferencedIDs == nil, "unknown, never the ids of the days that decoded")
        #expect(store.loadAllDaysFromRepository()[readable.dayKey] != nil, "the screens' read still serves what decodes")

        row.setValue(payload, forKey: "payloadData")
        try context.save()
        #expect(store.sealedBackupJournalReferencedIDs?.isSuperset(of: [readable.id, unreadable.id]) == true,
                "the incomplete memo is read again, not served")
    }

    /// R1 / D-B3-1: read-only recovery (the blob's fetch failed) is not a complete history in the Core
    /// Data repository, nor is an unreadable file in the local one — both answer nil from
    /// `loadAllDaysIfComplete()` where `loadAllDays()` answers an empty or legacy history.
    @MainActor
    @Test func readOnlyRecoveryIsNeverACompleteDayHistory() throws {
        let (store, repository, _) = makeTestStoreWithRepositories()
        #expect(store.reinstateJournalEntries(from: [Self.skeleton(dayKey: "2026-03-01")]))
        #expect(repository.loadAllDaysIfComplete()?.isEmpty == false)
        repository.invalidateCache()
        repository.forceNextFetchFailureForTesting()
        #expect(repository.loadAllDaysIfComplete() == nil)
        #expect(repository.isInReadOnlyRecovery)

        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("fernlet.tests.unreadableDays.\(UUID().uuidString)").appendingPathExtension("json")
        try Data("not the database".utf8).write(to: fileURL)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let local = LocalFernletRepository(
            fileURL: fileURL, backupExclusionPreference: { false },
            legacyDefaults: UserDefaults(suiteName: "fernlet.tests.unreadableDaysLegacy.\(UUID().uuidString)") ?? .standard
        )
        #expect(local.loadAllDaysIfComplete() == nil, "a file that will not decode is not an empty history")
    }

    /// R2 / D-B3-3: the merge names every entry carrying a backup entry's content — unchanged ones too —
    /// but the skeleton follow-up writes only a day that LACKS one: an idempotent re-merge rewrites no
    /// day row (none re-stamped, none re-uploaded with sync on), and one missing skeleton writes its own
    /// day alone.
    @MainActor
    @Test func anIdempotentReMergeWritesNoDayRow() throws {
        let (store, repository, _) = makeTestStoreWithRepositories()
        let skeletons = ["2026-03-01", "2026-03-02", "2026-03-03"].map { Self.skeleton(dayKey: $0) }
        #expect(store.reinstateJournalEntries(from: skeletons))
        let stamps = try Self.dayRowStamps(repository)
        #expect(Set(stamps.keys) == ["2026-03-01", "2026-03-02", "2026-03-03"])

        #expect(store.reinstateJournalEntries(from: skeletons), "the idempotent re-merge's follow-up")
        #expect(try Self.dayRowStamps(repository) == stamps, "no day row was rewritten")

        let missing = Self.skeleton(dayKey: "2026-03-02")
        #expect(store.reinstateJournalEntries(from: skeletons + [missing]))
        let after = try Self.dayRowStamps(repository)
        #expect(after["2026-03-01"] == stamps["2026-03-01"] && after["2026-03-03"] == stamps["2026-03-03"])
        #expect(after["2026-03-02"] != stamps["2026-03-02"], "only the day that lacked a skeleton was written")
        #expect(store.loadDay(for: "2026-03-02").journals.map(\.id).contains(missing.id))
    }

    /// D-B3-5: a set that authenticates but carries a feeling tag only a newer Fernlet knows NEEDS A
    /// NEWER FERNLET — never a transient failure retried at every visit behind a row that promises the
    /// entries "will be added the next time you open Private". Nothing is merged, the restore stays
    /// unresolved (E1 still holds this iPhone's exports), and the set is not downloaded and decrypted
    /// again in this process.
    @MainActor
    @Test func aSetWithAFeelingTagOnlyANewerFernletKnowsNeedsANewerFernlet() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        try await Self.writeSetANewerFernletWrote(cloud)
        let newerSet = cloud.sealedRecordIdentities
        let clock = ManualClock()
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", clock: { clock.now })
        let local = JournalBackupDevice.entry("written here", day: 2)
        try phone.write(local)

        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.host.recordedOutcomes[.journalNarratives] == .needsNewerFernlet)
        #expect(phone.rowState == .needsNewerFernlet, "no promise this build can never keep")
        #expect(phone.storedIDs == [local.id], "nothing merged")
        #expect(!phone.host.sealedBackupBookkeeping.restoreResolvedIsSet(.journalNarratives))
        #expect(cloud.sealedRecordIdentities == newerSet, "nothing written over the newer set")

        let decrypted = phone.engine.decryptCount
        phone.engine.hubSessionEnded()
        clock.advance(SealedBackupV2Engine.failureBackoff + 1)
        await phone.coordinator.settleV2Backup(.journalNarratives)
        #expect(phone.engine.decryptCount == decrypted, "not downloaded and decrypted again in this process")
        #expect(phone.rowState == .needsNewerFernlet)
    }

    /// D-B3-5, the explicit path: "Restore it here" of a set only a newer Fernlet reads consumes the
    /// choice and says so — not "Open Private to finish." forever, and not the held row with no reason.
    @MainActor
    @Test func restoreItHereOfASetOnlyANewerFernletReadsSaysSo() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let stamp = try await Self.writeSetANewerFernletWrote(cloud)
        let phone = JournalBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        let local = JournalBackupDevice.entry("written here", day: 2)
        try phone.write(local)
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        #expect(phone.rowState == .heldByAnotherDevice(stamp))

        await phone.coordinator.restoreBackupHere(.journalNarratives, stamp)
        #expect(phone.engine.intents[.journalNarratives] == nil, "the choice was consumed")
        #expect(phone.rowState == .needsNewerFernlet)
        #expect(phone.storedIDs == [local.id])
    }

    // MARK: - The FernletStore wiring (§4.4, §7.6)

    /// BV9 at the store: every journal write the sealing coordinator makes — the seal, the re-seal and
    /// the delete — moves the journal mutation epoch and owes the upload, with no keychain read; the
    /// device-key fold at the next Private open changes ciphertext only and marks nothing.
    @MainActor
    @Test func everyJournalSealingWriteMarksTheUploadOwedAndTheFoldDoesNot() throws {
        let (store, _, _) = makeTestStoreWithRepositories()
        let pastKey = "2026-03-01"
        store.deactivateSealedJournals()
        let epoch0 = store.sealedBackupMutationEpoch(.journalNarratives)
        store.addJournal(text: "written from Home", tag: .good, date: pastKey)
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == epoch0 + 1, "the seal (device key) marks")
        #expect(store.sealedBackupJournalReuploadDeferred)

        store.recordSealedBackupReuploadDeferred(false, payloadType: .journalNarratives)
        let key = SymmetricKey(size: .bits256)
        store.openHubForTesting(contentKey: key)
        let epoch1 = store.sealedBackupMutationEpoch(.journalNarratives)
        #expect(epoch1 == epoch0 + 1, "the fold under the hub key marks nothing")
        #expect(!store.sealedBackupJournalReuploadDeferred)

        let entry = try #require(store.loadDayWithDecryptedJournals(for: pastKey).journals.first)
        store.updateJournal(entry, text: "edited", tag: .good, date: pastKey)
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == epoch1 + 1, "the re-seal marks")
        let edited = try #require(store.loadDayWithDecryptedJournals(for: pastKey).journals.first)
        store.deleteJournal(edited, date: pastKey)
        #expect(store.sealedBackupMutationEpoch(.journalNarratives) == epoch1 + 2, "the delete marks")
        #expect(store.sealedBackupJournalReuploadDeferred)
    }

    /// §7.6 / BV18: during a duress session Privacy & Data shows no journal backup row of any kind —
    /// held, paused, waiting or catch-up — and the journal's seam is shut for the engine.
    @MainActor
    @Test func aDuressSessionShowsNoJournalBackupRow() {
        let store = makeTestStore()
        store.sealedBackupRestoreHold = SealedBackupRestoreHold(
            defaults: UserDefaults(suiteName: "fernlet.tests.journalRowHold.\(UUID().uuidString)") ?? .standard
        )
        store.sealedBackupBookkeeping = SealedBackupBookkeeping(
            defaults: UserDefaults(suiteName: "fernlet.tests.journalRowDuress.\(UUID().uuidString)") ?? .standard,
            legacyLatch: { _ in false }
        )
        store.sealedBackupPreferencesProvider = { JournalBackupDevice.backupOn }
        #expect(store.journalBackupRowState == .waitingForRestore, "unresolved: the waiting row")
        store.duressSessionActive = true
        #expect(store.journalBackupRowState == .none)
        store.duressSessionActive = false
        store.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        store.recordSealedBackupReuploadDeferred(true, payloadType: .journalNarratives)
        #expect(store.journalBackupRowState == .catchUp)
    }

    // MARK: - Helpers

    /// A past-day skeleton on `dayKey` with a fresh id.
    static func skeleton(dayKey: String) -> JournalNarrativeSkeleton {
        JournalNarrativeSkeleton(id: UUID(), dayKey: dayKey, tag: .good, entryDate: Date(timeIntervalSince1970: 1_772_000_000))
    }

    /// Every PAST day row's `updatedAt`, by its day — what a rewrite re-stamps (today's row is the
    /// snapshot save's, written on its own schedule).
    @MainActor
    static func dayRowStamps(_ repository: CoreDataFernletRepository) throws -> [String: Date] {
        let context = repository.persistenceController.container.viewContext
        let today = FernletDate.dayKey(for: .now)
        var stamps: [String: Date] = [:]
        for row in try context.fetch(NSFetchRequest<NSManagedObject>(entityName: "DayRecord")) {
            guard let key = row.value(forKey: "dateKey") as? String, key != today,
                  let stamp = row.value(forKey: "updatedAt") as? Date else { continue }
            stamps[key] = stamp
        }
        return stamps
    }

    /// Writes a one-chunk v2 journal set into `cloud`, as another install, whose one entry carries a
    /// feeling tag this build does not know — what a newer Fernlet writes. Returns its stamp.
    @MainActor
    @discardableResult
    static func writeSetANewerFernletWrote(_ cloud: FakeSealedBackupCloud) async throws -> SealedBackupHeadStamp {
        let writer = try PeriodBackupDevice.reader(cloud)
        let tag = PeriodBackupDevice.tag("newer")
        let envelope = SealedBackupV2Envelope(writer: tag, set: tag, total: 1, records: [JournalBackupDevice.entry("from a newer Fernlet", day: 1)])
        let json = String(decoding: try SealedBackupV2Format.encode(envelope), as: UTF8.self)
        #expect(json.contains(#""tag":"good""#))
        let plaintext = Data(json.replacingOccurrences(of: #""tag":"good""#, with: #""tag":"radiant""#).utf8)
        let head = try writer.sealChunk(plaintext, payloadType: .journalNarratives, chunkIndex: 0, chunkCount: 1,
                                        generation: 3, keySalt: SealedBackupService.mintKeySalt())
        try await writer.save(head, setTag: tag)
        return SealedBackupHeadStamp(writer: tag, generation: 3)
    }
}
