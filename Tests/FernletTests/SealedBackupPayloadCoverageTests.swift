//
//  SealedBackupPayloadCoverageTests.swift
//  FernletTests
//
//  Security-hardening Phase 3: journal narratives and intimacy logs as first-class sealed-backup
//  payloads, since units B2 and B3 of the journal and intimacy Sealed backup v2 design (2026-09-30)
//  on the v2 engine. These drive `SealedBackupCoordinator` directly through a fake `SealedBackupContext`,
//  so the restore semantics (the id-keyed merge, the locked-key deferral, the owner hold over every
//  restore and export) are exercised against ISOLATED sealed stores — no shared on-device store, no
//  `UserDefaults.standard` latch bleed. The journal's own v2 end-to-end cases live in
//  SealedBackupJournalV2Tests.
//
//  The FernletStore-level halves (journal skeleton reconstruction, the wiring of the store's own
//  wrappers) live in SealedBackupRestoreTests, which needs a real store to observe.
//

import ProximityKit
import CloudKit
import CoreData
import CryptoKit
import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import PrivateHealthStore
import PrivateMemoryStore
import PrivateStoreCore
@testable import Fernlet

/// A minimal `SealedBackupContext` so the coordinator can be tested without a `FernletStore`.
///
/// Everything it exposes is a plain settable property or a recorded call — the point is that these
/// tests state exactly which host inputs a decision depends on (the content key, the two visibility
/// gates) instead of inferring them from a 5,000-line store.
@MainActor
final class FakeSealedBackupHost: SealedBackupContext {
    var sealedBackupContentKey: SymmetricKey?
    /// The REAL owner hold (period-data design §5.3) on an isolated suite, so the per-payload
    /// bookkeeping these tests drive through the coordinator is production's own. Off unless a test
    /// sets it.
    let restoreHold = SealedBackupRestoreHold(
        defaults: UserDefaults(suiteName: "fernlet.tests.fakeHold.\(UUID().uuidString)") ?? .standard
    )
    /// The app-lock-reset hold. Setting it true is a reset with every payload backup on (so every
    /// pre-reset copy is kept); false drops the whole hold — the bit AND its per-payload record, which
    /// only a test may do (the owner's release, `releaseSealedBackupRestoreHold()`, keeps the record).
    var sealedBackupRestoreAwaitsOwner: Bool {
        get { restoreHold.isHeld }
        set {
            guard newValue else {
                restoreHold.defaults.removeObject(forKey: SealedBackupRestoreHold.defaultsKey)
                restoreHold.defaults.removeObject(forKey: SealedBackupRestoreHold.preResetCopiesKey)
                return
            }
            restoreHold.hold(keepingCopiesFrom: StoragePreferences(
                sealedBackupPeriodEnabled: true, sealedBackupJournalEnabled: true, sealedBackupIntimacyEnabled: true
            ))
        }
    }
    var isPeriodTrackingVisible = true
    var isIntimacyTrackingVisible = true
    /// The Sealed backup v2 bookkeeping (design 2026-09-30 §4.3) on an isolated suite. The period
    /// marker's one-time seed answers ``periodRestoreSeed``, the intimate-log marker's
    /// ``intimacyRestoreSeed`` and the journal marker's ``journalRestoreSeed`` (false: a fresh install).
    lazy var sealedBackupBookkeeping = SealedBackupBookkeeping(
        defaults: UserDefaults(suiteName: "fernlet.tests.fakeBookkeeping.\(UUID().uuidString)") ?? .standard,
        legacyLatch: { [unowned self] payload in
            switch payload {
            case .periodData: return self.periodRestoreSeed
            case .intimacyLogs: return self.intimacyRestoreSeed
            case .journalNarratives: return self.journalRestoreSeed
            case .sensitiveNotes: return false
            }
        }
    )
    /// What the period restore marker's one-time seed reads (the legacy cycle latch).
    var periodRestoreSeed = false
    /// What the intimate-log restore marker's one-time seed reads (the legacy intimacy latch).
    var intimacyRestoreSeed = false
    /// What the journal restore marker's one-time seed reads (the legacy journal latch).
    var journalRestoreSeed = false
    /// Sealed-store mutations seen through the hook, per payload (the host's mutation epochs).
    private(set) var mutationEpochs: [SealedBackupPayloadType: Int] = [:]
    /// The v2 engine's statuses, as recorded on the host.
    private(set) var v2Status: [SealedBackupPayloadType: SealedBackupV2Status] = [:]
    /// The Sealed backup work epoch — a test moves it to play "Delete everything"'s first leg or the
    /// app-lock reset funnel.
    var sealedBackupWorkEpoch = 0
    /// Whether "Delete everything" is running.
    var deleteAllInProgress = false
    /// Whether a duress session is active.
    var duressSessionActive = false
    /// Whether an escrow-key conflict awaits the user.
    var sealedBackupEscrowConflict = false
    /// The in-memory storage preferences (a coordinator built with its own provider ignores them).
    var sealedBackupPreferences = StoragePreferences()
    var previousJournals: [JournalEntry] = []
    var memories: [MemoryNote] = []
    var recentMeals: [Meal] = []
    var days: [String: FernletDay] = [:]

    /// Skeletons handed to ``reinstateJournalEntries(from:)``, in call order — the journal
    /// self-sufficiency hook's observable effect at this seam.
    private(set) var reinstatedJournalSkeletons: [[JournalNarrativeSkeleton]] = []
    /// Whether ``reinstateJournalEntries(from:)`` reports a failed day write (nothing written).
    var failsSkeletonWrites = false
    /// Journal entry ids referenced beyond the days and `previousJournals` (an in-memory today).
    var extraReferencedJournalIDs: Set<UUID> = []
    /// Whether the day store's read is NOT complete (read-only recovery, a failed fetch, a day that
    /// would not decode) — the referenced ids are then unknown.
    var dayStoreReadIncomplete = false
    /// Mirrors `FernletStore.sealedBackupJournalReferencedIDs`: every day's journals, `previousJournals`
    /// and the extra ids — nil while ``dayStoreReadIncomplete``.
    var sealedBackupJournalReferencedIDs: Set<UUID>? {
        guard !dayStoreReadIncomplete else { return nil }
        var ids = extraReferencedJournalIDs.union(previousJournals.map(\.id))
        for day in days.values { ids.formUnion(day.journals.map(\.id)) }
        return ids
    }
    private(set) var recordedOutcomes: [SealedBackupPayloadType: SealedBackupRestoreOutcome] = [:]
    /// Per-payload re-upload deferrals, as the coordinator recorded them.
    private(set) var reuploadDeferrals: [SealedBackupPayloadType: Bool] = [:]
    /// Retired payloads whose surviving iCloud copy the retirement sweep reported DELETED, in call
    /// order — the signal production turns into clearing the persisted marker.
    private(set) var retiredBackupsDeleted: [SealedBackupPayloadType] = []

    func loadAllDaysFromRepository() -> [String: FernletDay] { days }
    func sealedBackupKeepsPreResetCopy(of payloadType: SealedBackupPayloadType) -> Bool {
        restoreHold.keepsPreResetCopy(of: payloadType)
    }
    func recordSealedBackupCloudCopyDeleted(_ payloadType: SealedBackupPayloadType) {
        restoreHold.forgetPreResetCopy(of: payloadType)
    }
    func recordSealedBackupPreResetCopySettled(_ payloadType: SealedBackupPayloadType) {
        restoreHold.forgetPreResetCopy(of: payloadType)
    }
    func releaseSealedBackupRestoreHold() {
        restoreHold.release()
    }
    /// Mirrors `FernletStore.markSealedBackupDirty`: moves the epoch and, unless a wipe is running,
    /// owes the upload — whether or not the backup is on.
    func markSealedBackupDirty(_ payload: SealedBackupPayloadType) {
        mutationEpochs[payload, default: 0] += 1
        guard !deleteAllInProgress else { return }
        reuploadDeferrals[payload] = true
    }
    func sealedBackupMutationEpoch(_ payload: SealedBackupPayloadType) -> Int {
        mutationEpochs[payload, default: 0]
    }
    func isSealedBackupReuploadOwed(_ payload: SealedBackupPayloadType) -> Bool {
        reuploadDeferrals[payload] == true
    }
    func recordSealedBackupV2Status(_ status: SealedBackupV2Status?, payloadType: SealedBackupPayloadType) {
        v2Status[payloadType] = status
    }
    /// The engine whose period state this host reflects (the refused set a rolled-back restore names).
    weak var periodEngine: SealedBackupV2Engine?
    /// The period backup's Privacy & Data state, derived by the same mapping
    /// `FernletStore.periodBackupExportState` uses.
    var periodExportState: PeriodBackupExportState {
        PeriodBackupExportState.derive(
            status: v2Status[.periodData],
            rolledBackStamp: periodEngine?.rolledBackStamps[.periodData],
            observed: { nil }
        )
    }
    func recordSealedBackupReuploadDeferred(_ deferred: Bool, payloadType: SealedBackupPayloadType) {
        reuploadDeferrals[payloadType] = deferred
    }
    func recordSealedBackupRestoreOutcome(_ outcome: SealedBackupRestoreOutcome, payloadType: SealedBackupPayloadType) {
        recordedOutcomes[payloadType] = outcome
    }
    func recordSealedBackupEscrowConflict(_ inConflict: Bool) {}
    func recordRetiredSealedBackupDeleted(_ payloadType: SealedBackupPayloadType) {
        retiredBackupsDeleted.append(payloadType)
    }

    /// Mirrors `FernletStore.reinstateJournalEntries(from:)`'s load-bearing SIDE EFFECT: it writes day
    /// rows, only for ids a day lacks — or, with ``failsSkeletonWrites``, writes nothing and reports
    /// the failure.
    func reinstateJournalEntries(from skeletons: [JournalNarrativeSkeleton]) -> Bool {
        reinstatedJournalSkeletons.append(skeletons)
        guard !failsSkeletonWrites else { return false }
        for (dayKey, rows) in Dictionary(grouping: skeletons, by: \.dayKey) {
            var day = days[dayKey] ?? FernletDay(date: dayKey)
            var known = Set(day.journals.map(\.id))
            for row in rows where !known.contains(row.id) {
                day.journals.append(
                    JournalEntry(id: row.id, text: "", tag: row.tag, date: row.entryDate, emotions: [])
                )
                known.insert(row.id)
            }
            days[dayKey] = day
        }
        return true
    }
}

@MainActor
@Suite(.serialized)
struct SealedBackupPayloadCoverageTests {

    // MARK: - Fixtures

    private func isolatedDefaults(_ label: String) -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.\(label).\(UUID().uuidString)") ?? .standard
    }

    private func makeJournalRepository() -> JournalNarrativeRepository {
        JournalNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: isolatedDefaults("journalLatch")
        )
    }

    /// An isolated intimacy funnel. Tests always go through `IntimacyLogStore`, never the raw
    /// repository, because that is the wiring production is grep-walled into — and the coordinator
    /// re-wires the injected store's `isVisible` from the host, so visibility is driven by flipping
    /// `host.isIntimacyTrackingVisible`, never by handing in an ungated store.
    private func makeIntimacyStore() -> IntimacyLogStore {
        IntimacyLogStore(
            repository: IntimacyLogRepository(
                context: PrivatePersistenceController(inMemory: true).container.viewContext,
                defaults: isolatedDefaults("intimacyLatch")
            )
        )
    }

    /// Seeds a log through a temporarily-visible copy of the funnel — the store's default gate is
    /// fail-closed, so a raw `insert` would throw.
    private func seed(_ log: IntimacyLog, into store: IntimacyLogStore, key: SymmetricKey?) throws {
        let previous = store.isVisible
        store.attachVisibilityGate { true }
        defer { store.attachVisibilityGate(previous) }
        try store.insert(log, contentKey: key)
    }

    private func makeHost(key: SymmetricKey? = SymmetricKey(size: .bits256)) -> FakeSealedBackupHost {
        let host = FakeSealedBackupHost()
        host.sealedBackupContentKey = key
        return host
    }

    private func journalNarrative(_ text: String, dayKey: String = "2026-06-01", at seconds: TimeInterval) -> JournalNarrative {
        let date = Date(timeIntervalSince1970: seconds)
        return JournalNarrative(
            id: UUID(), dayKey: dayKey, tag: .good, entryDate: date,
            text: text, emotions: ["calm"], createdAt: date, updatedAt: date
        )
    }

    private func intimacyLog(_ note: String, at seconds: TimeInterval) -> IntimacyLog {
        IntimacyLog(eventDate: Date(timeIntervalSince1970: seconds), note: note)
    }

    private func encode<T: Encodable>(_ value: T) throws -> Data { try JSONEncoder().encode(value) }

    /// A coordinator wired to a THROWAWAY identity keychain and an in-memory CloudKit database, so the
    /// export/restore halves — the ones that decide what actually reaches (and comes back from) iCloud —
    /// can be driven end to end. Everything else about it is the production object.
    private func makeCloudCoordinator(
        host: FakeSealedBackupHost,
        cloud: FakeSealedBackupCloud,
        preferences: StoragePreferences? = nil,
        intimacyStore: IntimacyLogStore? = nil,
        journalRepository: JournalNarrativeRepository? = nil
    ) -> SealedBackupCoordinator {
        let keychainService = cloud.keychainService
        let generationDefaults = cloud.generationDefaults
        let database = cloud.database
        return SealedBackupCoordinator(
            host: host,
            identityFactory: { IdentityService(keychainService: keychainService) },
            serviceFactory: { identity in
                SealedBackupService(
                    cloudDataService: CloudKitDataService(
                        accountProvider: AlwaysAvailableAccountProvider(),
                        database: database,
                        zoneID: CKRecordZone.ID(zoneName: "test-zone", ownerName: CKCurrentUserDefaultName),
                        isCloudKitSyncEnabled: { false }
                    ),
                    identityService: identity,
                    generationStore: SealedBackupGenerationStore(defaults: generationDefaults)
                )
            },
            preferencesProvider: preferences.map { chosen in { chosen } },
            periodRecordStore: PeriodBackupDevice.makeRecordStore(),
            intimacyLogStore: intimacyStore,
            journalRepository: journalRepository ?? makeJournalRepository(),
            journalDeviceKeyService: "com.fernlet.p3-coverage.journalDevice.\(UUID().uuidString)",
            writerTagProvider: { PeriodBackupDevice.tag("coverage") },
            backgroundTasks: RecordingBackgroundTasks()
        )
    }

    /// Seals `narrative` into `repository` under `key` (the host's by default) and gives it a day
    /// skeleton on the host, as `JournalSealingCoordinator` and the diary do — a journal entry the
    /// backup snapshot counts (an orphan row is never exported, design 2026-09-30 §7.1).
    private func seedJournal(
        _ narrative: JournalNarrative,
        into repository: JournalNarrativeRepository,
        host: FakeSealedBackupHost,
        key: SymmetricKey? = nil
    ) throws {
        try repository.insert(narrative, contentKey: key ?? host.sealedBackupContentKey)
        var day = host.days[narrative.dayKey] ?? FernletDay(date: narrative.dayKey)
        day.journals.append(JournalEntry(id: narrative.id, text: "", tag: narrative.tag, date: narrative.entryDate, emotions: []))
        host.days[narrative.dayKey] = day
    }

    /// iCloud sync and the journal backup on.
    private static let journalOn = StoragePreferences(iCloudSyncEnabled: true, sealedBackupJournalEnabled: true)

    private func makeCloud() throws -> FakeSealedBackupCloud {
        let cloud = FakeSealedBackupCloud(
            keychainService: "com.fernlet.p3-coverage.\(UUID().uuidString)",
            generationDefaults: isolatedDefaults("sealedGeneration")
        )
        // The seal path provisions the escrow key lazily (WS-1); do it up front so both the export and
        // the restore in a single test run under the same key.
        let identity = IdentityService(keychainService: cloud.keychainService)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return cloud
    }

    // MARK: - Export path: E1 instead of the empty-store-clobber guard (design 2026-09-30, §4.2, §7)

    /// Rewritten for unit B3 (was `journalEnableFromAnEmptyStoreDefersInsteadOfClobberingTheCloudBackup`):
    /// a populated cloud backup meets an EMPTY store this install has not restored into yet. E1 holds
    /// the export — nothing is written over the backup — and the enable still reports success with the
    /// upload owed; the owed restore then merges the backup in, and only then does the export publish
    /// the union. After resolution an empty store is real: deleting every entry reaches the backup.
    @Test func journalEnableWaitsForTheRestoreAndAnEmptyStoreAfterResolutionIsReal() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        // A device that HAS the history uploads it.
        let oldHost = makeHost()
        let history = makeJournalRepository()
        let old = makeCloudCoordinator(host: oldHost, cloud: cloud, preferences: Self.journalOn, journalRepository: history)
        oldHost.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        let entry = journalNarrative("real history", at: 10)
        try seedJournal(entry, into: history, host: oldHost)
        #expect(await old.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let uploaded = cloud.sealedRecordIdentities
        #expect(!uploaded.isEmpty, "a populated store must actually upload")

        // A new install (same account key, empty store, restore unresolved) turns it on.
        let host = makeHost()
        host.sealedBackupContentKey = oldHost.sealedBackupContentKey
        let empty = makeJournalRepository()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: empty)
        #expect(await coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives),
                "an enable that cannot export yet keeps the switch on")
        #expect(cloud.sealedRecordIdentities == uploaded, "E1: the empty store wrote nothing over the backup")
        #expect(host.v2Status[.journalNarratives] == .waitingForRestore(nil))
        #expect(host.reuploadDeferrals[.journalNarratives] == true, "the upload stays owed")

        // The owed restore merges the backup in; the follow-through export publishes it.
        await coordinator.settleV2Backup(.journalNarratives)
        #expect(Set(try empty.allIDs()) == [entry.id])
        #expect(host.sealedBackupBookkeeping.isRestoreResolved(.journalNarratives))

        // Resolved: deleting the entry (its skeleton goes) is a real, exportable empty journal.
        host.days = [:]
        try empty.delete(id: entry.id)
        host.markSealedBackupDirty(.journalNarratives)
        coordinator.engine.hubSessionEnded()
        await coordinator.settleV2Backup(.journalNarratives)
        #expect(host.v2Status[.journalNarratives] == .upToDate)
        #expect(host.reuploadDeferrals[.journalNarratives] == false, "the delete reached the backup")
    }

    /// Rewritten for unit B3 (was `journalEnableRefusesWhenTheExportKeyCannotOpenTheStoredRows`): an
    /// entry that opens under NO key this iPhone holds pauses the export before its first save — never
    /// exported as emptiness over a good backup — while an entry under the journal DEVICE key (written
    /// from Home, not folded yet) is backed up as it is (design 2026-09-30, §7.2, BV5).
    @Test func journalRowsNoKeyOpensPauseTheExportBeforeAnySave() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let journal = makeJournalRepository()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: journal)
        host.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("readable", at: 10), into: journal, host: host)
        let lost = journalNarrative("sealed under a key that is gone", at: 20)
        try seedJournal(lost, into: journal, host: host, key: SymmetricKey(size: .bits256))

        #expect(await coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        #expect(cloud.sealedRecords.isEmpty, "nothing is written while an entry cannot open")
        #expect(host.v2Status[.journalNarratives] == .paused(unopenableIDs: [lost.id]))
        #expect(host.reuploadDeferrals[.journalNarratives] == true)
    }

    // MARK: - The restore is a merge (design 2026-09-30, §7.3)

    /// Rewritten for unit B3 (was `targetedJournalRestoreRecoversOnADeviceThatIsNoLongerFresh`): the
    /// journal restore is an id-keyed MERGE with no freshness or empty-store gate — on a device already
    /// in use (days synced down, entries of its own), the backup's entries are added beside them.
    @Test func theJournalMergeRestoreRunsOnADeviceAlreadyInUse() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let sourceHost = makeHost()
        let source = makeJournalRepository()
        let old = makeCloudCoordinator(host: sourceHost, cloud: cloud, preferences: Self.journalOn, journalRepository: source)
        sourceHost.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("only in the cloud", at: 10), into: source, host: sourceHost)
        #expect(await old.setSealedBackupEnabled(true, payloadType: .journalNarratives))

        let host = makeHost()
        host.sealedBackupContentKey = sourceHost.sealedBackupContentKey
        host.days["2026-06-03"] = FernletDay(date: "2026-06-03", bottleCount: 3)
        let target = makeJournalRepository()
        try seedJournal(journalNarrative("written here", dayKey: "2026-06-02", at: 20), into: target, host: host)
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: target)

        #expect(await coordinator.restoreJournalBackup() == .restored(1))
        let texts = try target.narratives(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey).map(\.text)
        #expect(Set(texts) == ["only in the cloud", "written here"])
        #expect(host.days["2026-06-01"]?.journals.count == 1, "the restored entry has its day skeleton")
    }

    /// Design 2026-09-30 §4.6, R1-BR-15 (was `anAppLockResetHoldsAmbientRestoresForTheOwner`): after an
    /// app-lock reset NO restore runs — ambient, Retry or "Restore it here" — until the device owner's
    /// own "Restore", which releases the hold; only then does the merge land.
    @Test func anAppLockResetHoldsEveryJournalRestoreUntilTheOwnersRelease() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let sourceHost = makeHost()
        let source = makeJournalRepository()
        let old = makeCloudCoordinator(host: sourceHost, cloud: cloud, preferences: Self.journalOn, journalRepository: source)
        sourceHost.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("only in the cloud", at: 10), into: source, host: sourceHost)
        #expect(await old.setSealedBackupEnabled(true, payloadType: .journalNarratives))

        let host = makeHost()
        host.sealedBackupContentKey = sourceHost.sealedBackupContentKey
        host.sealedBackupRestoreAwaitsOwner = true
        let target = makeJournalRepository()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: target)

        #expect(await coordinator.restoreJournalBackup() == .deferredTransient)
        #expect(await coordinator.restoreJournalBackup(initiatedByUser: true) == .deferredTransient,
                "Retry is ambient: it never skips the owner hold")
        #expect(try target.narrativeCount() == 0, "a held restore writes nothing")
        #expect(host.recordedOutcomes[.journalNarratives] == nil, "nor does it raise a banner")

        await coordinator.releaseRestoreHoldForOwner()
        #expect(try target.narrativeCount() == 1, "the owner's release merges the backup in")
        #expect(!host.sealedBackupKeepsPreResetCopy(of: .journalNarratives), "the restore landed: the copy is settled")
    }

    /// Review C-U2-R1 on the v2 engine: holding the RESTORES after an app-lock reset is not enough — an
    /// export would REPLACE the owner's pre-reset history with whatever was written since. While the
    /// hold keeps the journal's copy, every export stops at X2 (`.heldForOwner`); the control half
    /// proves it was the hold that held it.
    @Test func anAppLockResetHoldsEveryJournalExportSoThePreResetCloudCopyStays() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let historyHost = makeHost()
        let history = makeJournalRepository()
        let before = makeCloudCoordinator(host: historyHost, cloud: cloud, preferences: Self.journalOn, journalRepository: history)
        historyHost.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("before the reset", at: 10), into: history, host: historyHost)
        #expect(await before.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let preReset = cloud.sealedRecordIdentities

        // After the reset: a fresh key, a store holding only what was written since, the hold.
        let host = makeHost()
        host.restoreHold.hold(keepingCopiesFrom: Self.journalOn)
        host.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        let since = makeJournalRepository()
        try seedJournal(journalNarrative("after the reset", at: 30), into: since, host: host)
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: since)
        host.markSealedBackupDirty(.journalNarratives)

        await coordinator.retryDeferredReuploadIfNeeded(payloadType: .journalNarratives)
        #expect(cloud.sealedRecordIdentities == preReset, "a held export writes nothing over the pre-reset copy")
        #expect(host.v2Status[.journalNarratives] == .heldForOwner)

        host.restoreHold.forgetPreResetCopy(of: .journalNarratives)
        coordinator.engine.hubSessionEnded()
        await coordinator.retryDeferredReuploadIfNeeded(payloadType: .journalNarratives)
        #expect(host.v2Status[.journalNarratives] != .heldForOwner, "control: without the kept copy it is not held")
    }

    /// Review C-U2-R1, the escrow adopt (design 2026-09-30 §4.5): it switches keys and marks every
    /// enabled backup's upload owed — and writes nothing itself, so nothing is re-sealed over a
    /// pre-reset copy the hold keeps (the export's X2 holds it at the next visit).
    @Test func anEscrowAdoptDuringTheOwnerHoldAdoptsTheKeyButWritesNothing() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let preferences = StoragePreferences(iCloudSyncEnabled: true, sealedBackupJournalEnabled: true, sealedBackupIntimacyEnabled: true)
        let journal = makeJournalRepository()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: preferences, journalRepository: journal)
        host.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("before the reset", at: 10), into: journal, host: host)
        #expect(await coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let preReset = cloud.sealedRecordIdentities
        let otherDevice = try seedSyncedEscrowKey(into: cloud.keychainService)
        defer { KeychainItem.deleteAll(service: otherDevice) }

        host.sealedBackupRestoreAwaitsOwner = true
        #expect(await coordinator.adoptSyncedEscrowAndReupload(), "the other device's key is still adopted")
        #expect(cloud.sealedRecordIdentities == preReset, "nothing is re-sealed over the pre-reset copy")
        #expect(host.reuploadDeferrals[.journalNarratives] == true, "the journal upload is owed")
        #expect(host.reuploadDeferrals[.intimacyLogs] == true,
                "the intimate-log backup (v2) is marked owed; its export's own hold keeps the copy")
        #expect(host.reuploadDeferrals[.periodData] == nil, "a payload that is off owes nothing")
    }

    /// Review N-1, the finding's own scenario: after an app-lock reset the user turns the journal
    /// backup OFF (which deletes the pre-reset copy from iCloud) and back on. From then on there is
    /// nothing pre-reset to keep, so the hold must not keep their new entries out of the backup
    /// forever. The control half first proves the hold was holding it.
    @Test func aBackupDeletedSinceTheResetUploadsAgainBecauseNothingIsLeftToKeep() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let journal = makeJournalRepository()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: journal)
        host.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("before the reset", at: 10), into: journal, host: host)
        #expect(await coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let preReset = cloud.sealedRecordIdentities

        // The reset, with the journal backup on: its pre-reset copy is kept.
        host.restoreHold.hold(keepingCopiesFrom: Self.journalOn)
        try seedJournal(journalNarrative("after the reset", at: 30), into: journal, host: host)
        host.markSealedBackupDirty(.journalNarratives)
        coordinator.engine.hubSessionEnded()
        await coordinator.retryDeferredReuploadIfNeeded(payloadType: .journalNarratives)
        #expect(cloud.sealedRecordIdentities == preReset, "control: while the copy is there, the upload is held")

        // Off (the copy is deleted), then on again from Settings with Private closed.
        #expect(await coordinator.setSealedBackupEnabled(false, payloadType: .journalNarratives))
        #expect(cloud.sealedRecords.isEmpty, "turning it off deleted the pre-reset copy")
        #expect(!host.sealedBackupKeepsPreResetCopy(of: .journalNarratives), "nothing pre-reset is left to keep")
        let key = host.sealedBackupContentKey
        host.sealedBackupContentKey = nil
        #expect(await coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        #expect(host.reuploadDeferrals[.journalNarratives] == true, "Private is closed: the upload is owed")

        // The next Private settle uploads it.
        host.sealedBackupContentKey = key
        coordinator.engine.hubSessionEnded()
        await coordinator.settleV2Backup(.journalNarratives)
        #expect(!cloud.sealedRecords.isEmpty, "the user's new entries reach the backup")
        #expect(host.reuploadDeferrals[.journalNarratives] == false, "and the owed upload is discharged")
        #expect(host.sealedBackupRestoreAwaitsOwner, "the ambient-restore half of the hold is untouched")
    }

    /// Review N-1: a backup that was OFF at the reset had no pre-reset copy, so it uploads as usual —
    /// and after the escrow adopt it is re-sealed under the adopted key at the next Private visit —
    /// while a payload whose copy is kept stays held beside it. (Both are on the v2 engine: the hold is
    /// the export's X2, the adopt marks the upload owed.)
    @Test func aBackupThatWasOffAtTheResetIsNeverHeld() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        host.restoreHold.hold(keepingCopiesFrom: StoragePreferences(sealedBackupJournalEnabled: true))
        let preferences = StoragePreferences(
            iCloudSyncEnabled: true, sealedBackupJournalEnabled: true, sealedBackupIntimacyEnabled: true,
            sealedBackupJournalReuploadDeferred: true, sealedBackupIntimacyReuploadDeferred: true
        )
        let intimacySince = makeIntimacyStore()
        let journalSince = makeJournalRepository()
        let coordinator = makeCloudCoordinator(
            host: host, cloud: cloud, preferences: preferences, intimacyStore: intimacySince, journalRepository: journalSince
        )
        host.sealedBackupBookkeeping.markRestoreResolved(.intimacyLogs)
        host.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("after the reset", at: 30), into: journalSince, host: host)
        try intimacySince.insert(intimacyLog("after the reset", at: 30), contentKey: host.sealedBackupContentKey)
        host.markSealedBackupDirty(.journalNarratives)

        await coordinator.retryDeferredReuploadIfNeeded(payloadType: .journalNarratives)
        await coordinator.retryDeferredReuploadIfNeeded(payloadType: .intimacyLogs)
        #expect(names(in: cloud, for: .journalNarratives).isEmpty, "the kept journal copy is not replaced")
        #expect(!names(in: cloud, for: .intimacyLogs).isEmpty, "intimacy was off at the reset: it uploads")

        let otherDevice = try seedSyncedEscrowKey(into: cloud.keychainService)
        defer { KeychainItem.deleteAll(service: otherDevice) }
        let intimacyBefore = cloud.sealedRecordIdentities
        #expect(await coordinator.adoptSyncedEscrowAndReupload())
        #expect(names(in: cloud, for: .journalNarratives).isEmpty, "the adopt re-seals nothing over the kept copy")
        #expect(host.reuploadDeferrals[.journalNarratives] == true)
        #expect(host.reuploadDeferrals[.intimacyLogs] == true, "the adopt marks the unheld v2 payload owed")
        coordinator.engine.hubSessionEnded()
        await coordinator.settleV2Backup(.intimacyLogs)
        await coordinator.settleV2Backup(.journalNarratives)
        #expect(cloud.sealedRecordIdentities != intimacyBefore, "the next Private visit re-seals it under the adopted key")
        #expect(host.reuploadDeferrals[.intimacyLogs] == false)
        #expect(names(in: cloud, for: .journalNarratives).isEmpty, "and the kept journal copy is still not replaced")
    }

    /// Review N-1: only a delete that LANDED ends the hold's claim. A failed one may have left the
    /// pre-reset copy in iCloud, so it stays kept and its uploads stay held.
    @Test func aFailedDeleteKeepsThePreResetCopyHeld() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let host = makeHost()
        let journal = makeJournalRepository()
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: journal)
        host.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("before the reset", at: 10), into: journal, host: host)
        #expect(await coordinator.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let preReset = cloud.sealedRecordIdentities
        host.restoreHold.hold(keepingCopiesFrom: Self.journalOn)

        cloud.database.failsDeletes = true
        #expect(await !coordinator.setSealedBackupEnabled(false, payloadType: .journalNarratives), "the delete failed")
        #expect(host.sealedBackupKeepsPreResetCopy(of: .journalNarratives), "the copy may still be there: still kept")
        try seedJournal(journalNarrative("after the reset", at: 30), into: journal, host: host)
        host.markSealedBackupDirty(.journalNarratives)
        coordinator.engine.hubSessionEnded()
        await coordinator.retryDeferredReuploadIfNeeded(payloadType: .journalNarratives)
        #expect(cloud.sealedRecordIdentities == preReset, "and nothing is uploaded over it")
    }

    /// The persisted bookkeeping itself (review N-1): a reset keeps exactly the payloads whose switch
    /// was on; a landed delete forgets one; a hold without its record keeps every payload (fail
    /// closed); nothing is written while no hold is set; the retired payload is never kept.
    @Test func theOwnerHoldKeepsOnlyTheCopiesThatCanStillBeThere() {
        let defaults = isolatedDefaults("ownerHold")
        let hold = SealedBackupRestoreHold(defaults: defaults)
        hold.forgetPreResetCopy(of: .journalNarratives)
        #expect(defaults.object(forKey: SealedBackupRestoreHold.preResetCopiesKey) == nil, "no hold, nothing written")
        #expect(hold.payloadsKeepingPreResetCopy.isEmpty)

        hold.hold(keepingCopiesFrom: StoragePreferences(sealedBackupJournalEnabled: true, sealedBackupIntimacyEnabled: true))
        #expect(hold.isHeld)
        #expect(hold.payloadsKeepingPreResetCopy == [.journalNarratives, .intimacyLogs], "period was off at the reset")
        hold.forgetPreResetCopy(of: .journalNarratives)
        #expect(hold.payloadsKeepingPreResetCopy == [.intimacyLogs])
        #expect(hold.isHeld, "forgetting a copy never lifts the ambient-restore hold")

        defaults.removeObject(forKey: SealedBackupRestoreHold.preResetCopiesKey)
        #expect(hold.payloadsKeepingPreResetCopy == Set(SealedBackupRestoreHold.reuploadablePayloads), "no record: fail closed")
        hold.forgetPreResetCopy(of: .periodData)
        #expect(hold.payloadsKeepingPreResetCopy == [.journalNarratives, .intimacyLogs])
        #expect(!hold.keepsPreResetCopy(of: .sensitiveNotes), "the retired payload is never re-uploaded")
    }

    /// The owner's release (design unit 5, §5.3, Q14): the AMBIENT-restore bit goes, the per-payload
    /// record stays — written out in full when the hold had none (fail closed) — and each payload
    /// leaves it only when its own copy is settled; the record is removed once it empties. A release
    /// while not held writes nothing.
    @Test func theOwnersReleaseKeepsEachCopyUntilItsRestoreLands() {
        let defaults = isolatedDefaults("ownerRelease")
        let hold = SealedBackupRestoreHold(defaults: defaults)
        hold.release()
        #expect(defaults.object(forKey: SealedBackupRestoreHold.preResetCopiesKey) == nil, "no hold, nothing written")

        hold.hold(keepingCopiesFrom: StoragePreferences(sealedBackupPeriodEnabled: true, sealedBackupJournalEnabled: true))
        hold.release()
        #expect(!hold.isHeld, "ambient restores may run again")
        #expect(hold.payloadsKeepingPreResetCopy == [.periodData, .journalNarratives], "each copy is still kept from a re-upload")
        hold.forgetPreResetCopy(of: .periodData)
        #expect(hold.payloadsKeepingPreResetCopy == [.journalNarratives])
        hold.forgetPreResetCopy(of: .journalNarratives)
        #expect(defaults.object(forKey: SealedBackupRestoreHold.preResetCopiesKey) == nil, "an empty record is removed")

        hold.hold(keepingCopiesFrom: StoragePreferences())
        defaults.removeObject(forKey: SealedBackupRestoreHold.preResetCopiesKey)
        hold.release()
        #expect(hold.payloadsKeepingPreResetCopy == Set(SealedBackupRestoreHold.reuploadablePayloads),
                "a hold released without its record keeps every copy: fail closed")
    }

    /// The owner's release end to end for the journal (design 2026-09-30, §4.6, §7.3; replaces the v1
    /// `afterTheOwnersReleaseAJournalCopyIsRestoredBeforeItIsReplaced` and
    /// `aReleasedCopyThatCannotRestoreIsNamedAndReplacedOnlyByChoice`): the hold holds every restore and
    /// export; the owner's release reopens the restore, which MERGES the pre-reset copy into a store
    /// that already holds post-reset entries (no empty-store refusal any more, so nothing is ever named
    /// "can't be restored"), settles the copy, and the follow-through export publishes the union.
    @Test func afterTheOwnersReleaseTheJournalCopyIsMergedBeforeAnythingReplacesIt() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let historyHost = makeHost()
        let history = makeJournalRepository()
        let before = makeCloudCoordinator(host: historyHost, cloud: cloud, preferences: Self.journalOn, journalRepository: history)
        historyHost.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        let old = journalNarrative("before the reset", at: 10)
        try seedJournal(old, into: history, host: historyHost)
        #expect(await before.setSealedBackupEnabled(true, payloadType: .journalNarratives))
        let preReset = cloud.sealedRecordIdentities

        let host = makeHost()
        host.sealedBackupContentKey = historyHost.sealedBackupContentKey
        host.restoreHold.hold(keepingCopiesFrom: Self.journalOn)
        host.sealedBackupBookkeeping.reopenRestore(.journalNarratives)
        let written = makeJournalRepository()
        let since = journalNarrative("after the reset", dayKey: "2026-06-02", at: 30)
        try seedJournal(since, into: written, host: host)
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: written)
        host.markSealedBackupDirty(.journalNarratives)

        await coordinator.settleV2Backup(.journalNarratives)
        #expect(cloud.sealedRecordIdentities == preReset, "held: nothing replaces the copy before its restore")
        #expect(Set(try written.allIDs()) == [since.id], "and nothing is restored before the owner asks")

        await coordinator.releaseRestoreHoldForOwner()
        #expect(Set(try written.allIDs()) == [old.id, since.id], "the pre-reset copy merged into the post-reset store")
        #expect(!host.sealedBackupKeepsPreResetCopy(of: .journalNarratives), "the restore landed: the copy is settled")
        #expect(cloud.sealedRecordIdentities != preReset, "and the union backs up")
        #expect(host.reuploadDeferrals[.journalNarratives] == false)
    }

    /// Design 2026-09-30 §4.5 / §5.5 (R2-F1), replacing review U5-backup-v2-L-U5-R1's explicit replace:
    /// the escrow adopt marks every enabled v2 payload's upload owed and writes nothing itself. The next
    /// settle meets the period set this iPhone sealed under the key the adopt replaced; whether or not
    /// it still opens here, it carries THIS install's signing key, so E2 calls it this iPhone's own and
    /// the export re-seals the history under the adopted key — no question asked, nothing stranded.
    @Test func afterAnEscrowAdoptThePeriodSetIsReSealedUnderTheAdoptedKeyAsThisIPhonesOwn() async throws {
        let cloud = try PeriodBackupDevice.makeCloud()
        defer { cloud.tearDown() }
        let phone = PeriodBackupDevice(cloud: cloud, writer: "phone", resolved: true)
        try phone.seed([PeriodBackupDevice.record(day: 1)])
        #expect(await phone.coordinator.setSealedBackupEnabled(true, payloadType: .periodData))
        let beforeAdopt = cloud.sealedRecordIdentities
        let otherDevice = try seedSyncedEscrowKey(into: phone.keychainService)
        defer { KeychainItem.deleteAll(service: otherDevice) }

        #expect(await phone.coordinator.adoptSyncedEscrowAndReupload())
        #expect(cloud.sealedRecordIdentities == beforeAdopt, "the adopt itself writes nothing")
        #expect(phone.host.reuploadDeferrals[.periodData] == true, "it marks the upload owed")

        phone.engine.hubSessionEnded()   // the adopt is in Settings: the next Private visit settles
        await phone.coordinator.settlePeriodBackup()
        #expect(phone.host.periodExportState == .clear, "its own set, never named as another key's")
        #expect(cloud.sealedRecordIdentities != beforeAdopt, "re-sealed")
        #expect(try await PeriodBackupDevice.cloudHead(cloud, keychainService: otherDevice)?.writer == phone.writer,
                "under the adopted key: the other device's key opens it")
        #expect(phone.host.reuploadDeferrals[.periodData] == false)
    }

    /// Review N-1: Privacy & Data's "your app lock was reset" line speaks only for a backup that is on
    /// AND whose pre-reset copy the hold keeps; any other backup's own line shows instead.
    @Test func theOwnerHoldLineSpeaksOnlyForAKeptCopy() {
        let journalOn = StoragePreferences(sealedBackupJournalEnabled: true)
        #expect(PrivacyDataSettingsView.showsOwnerHoldLine(kept: [.journalNarratives], preferences: journalOn))
        #expect(!PrivacyDataSettingsView.showsOwnerHoldLine(kept: [], preferences: journalOn),
                "a journal backup deleted since the reset has nothing kept")
        #expect(!PrivacyDataSettingsView.showsOwnerHoldLine(
            kept: [.journalNarratives], preferences: StoragePreferences(sealedBackupIntimacyEnabled: true)),
                "the only backup on was off at the reset")
    }

    /// The sealed-backup record names in `cloud` for one payload (its frozen raw value is in the name).
    private func names(in cloud: FakeSealedBackupCloud, for payload: SealedBackupPayloadType) -> [String] {
        cloud.sealedRecords.map(\.recordID.recordName).filter { $0.contains(payload.rawValue) }
    }

    /// Plants another device's escrow key as an iCloud-Keychain (synchronizable) row in `service`, the
    /// state `reconcileBackupEscrowKey` reports as a conflict and the adopt resolves. Returns the other
    /// device's own keychain service, for cleanup.
    private func seedSyncedEscrowKey(into service: String) throws -> String {
        let otherService = "com.fernlet.p3-coverage.other.\(UUID().uuidString)"
        let other = IdentityService(keychainService: otherService)
        try other.ensureProvisioned()
        let publicKey = other.provisionBackupEscrowKeyForSealing()
        let account = IdentityService.escrowKeychainAccount(forPublicKey: publicKey)
        let keyData = try #require(KeychainItem.load(account: account, service: otherService))
        #expect(KeychainItem.store(keyData, account: account, service: service,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)
        return otherService
    }

    /// Rewritten for unit B3 (was `targetedRestoresRefuseAnEmptyButDivergedStore`): the one-way
    /// divergence latch no longer gates a restore — it SEEDS the journal restore marker once (BV14). An
    /// install that wrote and deleted its entries (count 0, latch set) seeds the marker RESOLVED, so no
    /// ambient restore ever merges the stale cloud copy back over the user's deletes.
    @Test func aDivergedJournalStoreSeedsItsMarkerResolvedAndNeverMergesTheStaleCopy() async throws {
        let cloud = try makeCloud()
        defer { cloud.tearDown() }
        let sourceHost = makeHost()
        let source = makeJournalRepository()
        let old = makeCloudCoordinator(host: sourceHost, cloud: cloud, preferences: Self.journalOn, journalRepository: source)
        sourceHost.sealedBackupBookkeeping.markRestoreResolved(.journalNarratives)
        try seedJournal(journalNarrative("deleted on this device", at: 10), into: source, host: sourceHost)
        #expect(await old.setSealedBackupEnabled(true, payloadType: .journalNarratives))

        let host = makeHost()
        host.sealedBackupContentKey = sourceHost.sealedBackupContentKey
        let diverged = makeJournalRepository()
        let entry = journalNarrative("written then deleted", at: 20)
        try diverged.insert(entry, contentKey: host.sealedBackupContentKey)
        try diverged.delete(id: entry.id)
        host.journalRestoreSeed = diverged.hasEverStoredNarrative
        #expect(host.sealedBackupBookkeeping.seedRestoreMarkerIfAbsent(.journalNarratives))
        let coordinator = makeCloudCoordinator(host: host, cloud: cloud, preferences: Self.journalOn, journalRepository: diverged)

        #expect(await coordinator.restoreJournalBackup() == .skippedStoreNotEmpty, "a resolved install never restores ambiently")
        #expect(try diverged.narrativeCount() == 0)
    }

    // MARK: - Pass-level freshness (one arm must not sabotage the next)

    /// The journal restore WRITES DAY ROWS (`reinstateJournalEntries` rebuilds the skeletons the UI
    /// renders), and a day carrying journals satisfies `hasLoggedContent` — the hazard that once turned
    /// the intimacy arm after it into a silent, terminal `.skippedStoreNotEmpty`. Since unit B2 the
    /// intimate-log restore is a v2 MERGE with no freshness gate at all, so the journal's writeback can
    /// no longer touch it: the same restore lands with no pinned verdict.
    @Test func journalDaySkeletonWritebackNoLongerGatesTheIntimacyMerge() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let journal = makeJournalRepository()
        let intimacy = makeIntimacyStore()
        #expect(host.days.isEmpty, "the pass starts on a genuinely fresh device")

        // Arm 1: journal, on a device that really is fresh.
        #expect(try coordinator.applyRestoredPayload(
            try encode([journalNarrative("restored", at: 100)]),
            payloadType: .journalNarratives,
            journalRepository: journal
        ) == 1)
        #expect(host.days.isEmpty == false, "the journal arm writes day skeletons — that is the hazard")

        // The intimacy merge has no freshness gate: the arm-1 writeback changes nothing for it.
        #expect(try coordinator.applyRestoredPayload(
            try encode([intimacyLog("restored", at: 100)]),
            payloadType: .intimacyLogs,
            intimacyStore: intimacy
        ) == 1)
        #expect(try intimacy.backupLogCount() == 1)
    }

    /// Design 2026-09-30 §7.3 (was `pinnedFreshnessStillHonorsThePerPayloadStoreChecks` and
    /// `journalRestoreRefusesAPopulatedStore`): the journal restore is an id-keyed MERGE, never
    /// empty-store-only — an entry already here stays exactly as it is, and the backup's entry is added
    /// beside it with its day skeleton.
    @Test func journalRestoreMergesIntoAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let journal = makeJournalRepository()
        try journal.insert(journalNarrative("written here", at: 10), contentKey: host.sealedBackupContentKey)

        #expect(try coordinator.applyRestoredPayload(
            try encode([journalNarrative("from the backup", at: 100)]),
            payloadType: .journalNarratives,
            journalRepository: journal
        ) == 1, "one entry added")
        let texts = try journal.narratives(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey).map(\.text)
        #expect(texts == ["written here", "from the backup"])
        #expect(host.reinstatedJournalSkeletons.first?.count == 1, "the added entry's skeleton is rebuilt")
    }

    // MARK: - Journal: restore into an empty store

    @Test func journalRestoreWritesNarrativesIntoAnEmptyStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let narratives = [
            journalNarrative("Slept badly, wrote it down.", at: 100),
            journalNarrative("Better today.", dayKey: "2026-06-02", at: 200)
        ]

        let count = try coordinator.applyRestoredPayload(
            try encode(narratives),
            payloadType: .journalNarratives,
            journalRepository: repository
        )
        #expect(count == 2)

        let readBack = try repository.narratives(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey)
        #expect(readBack.map(\.text) == ["Slept badly, wrote it down.", "Better today."])
        #expect(readBack.first?.emotions == ["calm"])
        #expect(readBack.map(\.updatedAt) == narratives.map(\.updatedAt), "a restored entry keeps its own stamps")
        // Self-sufficiency: the skeletons hook fired with exactly what was written.
        #expect(host.reinstatedJournalSkeletons.count == 1)
        #expect(Set(host.reinstatedJournalSkeletons.first?.map(\.id) ?? []) == Set(narratives.map(\.id)))
    }

    /// Locked at the write point → `.locked`, which the restore classifier maps to the RETRYABLE
    /// `.deferredLocked`; unlocking and retrying is the self-heal, and it must actually work.
    @Test func journalRestoreDefersWhileLockedThenSelfHealsAfterUnlock() throws {
        let host = makeHost(key: nil)   // locked: no content key
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let payload = try encode([journalNarrative("Waiting for the unlock.", at: 100)])

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.locked) {
            try coordinator.applyRestoredPayload(payload, payloadType: .journalNarratives, journalRepository: repository)
        }
        #expect(try repository.narrativeCount() == 0)
        #expect(repository.hasEverStoredNarrative == false, "a deferred restore must not latch divergence")
        #expect(SealedBackupRestoreOutcome.deferredLocked.isRetryable)

        // The user unlocks; the same payload now lands.
        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        let count = try coordinator.applyRestoredPayload(payload, payloadType: .journalNarratives, journalRepository: repository)
        #expect(count == 1)
        #expect(try repository.narrativeCount() == 1)
    }

    /// Design 2026-09-30 §7.6: a duress session shuts the journal's decrypt seam — the merge throws
    /// (retryable) and writes nothing, and the same call lands once the session is over.
    @Test func journalRestoreIsRefusedDuringADuressSession() throws {
        let host = makeHost()
        host.duressSessionActive = true
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let payload = try encode([journalNarrative("from the backup", at: 100)])

        #expect(throws: JournalBackupSeamClosedError.self) {
            try coordinator.applyRestoredPayload(payload, payloadType: .journalNarratives, journalRepository: repository)
        }
        #expect(try repository.narrativeCount() == 0)
        #expect(host.reinstatedJournalSkeletons.isEmpty, "no skeleton written in duress")

        host.duressSessionActive = false
        #expect(try coordinator.applyRestoredPayload(payload, payloadType: .journalNarratives, journalRepository: repository) == 1)
    }


    // MARK: - Intimacy: the v2 merge through the gated funnel (unit B2)

    @Test func intimacyRestoreWritesLogsIntoAnEmptyStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let logs = [intimacyLog("first", at: 100), intimacyLog("second", at: 200)]

        let count = try coordinator.applyRestoredPayload(
            try encode(logs),
            payloadType: .intimacyLogs,
            intimacyStore: store
        )
        #expect(count == 2)
        let readBack = try store.backupChunk(ids: try store.allIDs(), contentKey: host.sealedBackupContentKey)
        #expect(readBack.records.map(\.note) == ["first", "second"])
        #expect(host.reinstatedJournalSkeletons.isEmpty, "intimacy restore must not touch journal skeletons")
    }

    /// Design 2026-09-30 §8.2 (was `intimacyRestoreRefusesAPopulatedStore`): the restore is an id-keyed
    /// MERGE, never empty-store-only — a log already here stays exactly as it is, and the backup's log
    /// is added beside it.
    @Test func intimacyRestoreMergesIntoAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("logged locally", at: 50), into: store, key: host.sealedBackupContentKey)

        #expect(try coordinator.applyRestoredPayload(
            try encode([intimacyLog("from the backup", at: 100)]),
            payloadType: .intimacyLogs,
            intimacyStore: store
        ) == 1, "one log added")
        let notes = try store.backupChunk(ids: try store.allIDs(), contentKey: host.sealedBackupContentKey).records.map(\.note)
        #expect(notes == ["logged locally", "from the backup"])
    }

    @Test func intimacyRestoreDefersWhileLockedThenSelfHealsAfterUnlock() throws {
        let host = makeHost(key: nil)
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let payload = try encode([intimacyLog("waiting for the unlock", at: 100)])

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.locked) {
            try coordinator.applyRestoredPayload(
                payload, payloadType: .intimacyLogs,
                intimacyStore: store
            )
        }
        #expect(try store.backupLogCount() == 0)
        #expect(store.hasEverStoredLog == false)

        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        #expect(try coordinator.applyRestoredPayload(
            payload, payloadType: .intimacyLogs,
            intimacyStore: store
        ) == 1)
    }

    /// Hidden at restore → DEFERRED, then restores on un-hide. The write is a decrypt seam, so the
    /// gated funnel refuses it while hidden (a retryable failure, not a silent write behind the gate),
    /// and the identical call succeeds once the surface is visible again. The coordinator re-wires the
    /// injected store's gate from the host, which is why flipping the host is all this test does.
    @Test func intimacyRestoreIsRefusedWhileHiddenAndSucceedsAfterUnhiding() throws {
        let host = makeHost()
        host.isIntimacyTrackingVisible = false
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let payload = try encode([intimacyLog("from the backup", at: 100)])

        #expect(throws: IntimacyTrackingHiddenError.self) {
            try coordinator.applyRestoredPayload(
                payload, payloadType: .intimacyLogs,
                intimacyStore: store
            )
        }
        #expect(try store.backupLogCount() == 0)

        host.isIntimacyTrackingVisible = true
        #expect(try coordinator.applyRestoredPayload(
            payload, payloadType: .intimacyLogs,
            intimacyStore: store
        ) == 1)
    }

    /// Hidden is refused at the decrypt seam — never answered as "nothing here", and never a merge
    /// behind the gate: the store's rows stay, still counted (keyless) and still latched.
    @Test func aHiddenIntimacyStoreIsNeverMergedIntoAndNeverReadsAsEmpty() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("hidden but present", at: 50), into: store, key: host.sealedBackupContentKey)

        host.isIntimacyTrackingVisible = false
        #expect(throws: IntimacyTrackingHiddenError.self) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("from the backup", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: store
            )
        }
        #expect(try store.backupLogCount() == 1, "a hidden store must not count as empty")
        #expect(store.hasEverStoredLog, "a hidden store must not read as never-populated")
    }

    // MARK: - Chunked round trip (what the CloudKit path hands back)

    /// Restore receives an ARRAY of decrypted chunks, not one blob. Both new payloads must reassemble
    /// across chunk boundaries in a single all-or-nothing transaction.
    @Test func journalRestoreReassemblesMultipleChunks() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let chunks = [
            try encode([journalNarrative("chunk 0 a", at: 10), journalNarrative("chunk 0 b", at: 20)]),
            try encode([journalNarrative("chunk 1 a", at: 30)])
        ]
        let count = try coordinator.applyRestoredChunks(chunks, payloadType: .journalNarratives, journalRepository: repository)
        #expect(count == 3)
        #expect(try repository.narrativeCount() == 3)
    }

    @Test func intimacyRestoreReassemblesMultipleChunks() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let chunks = [
            try encode([intimacyLog("chunk 0 a", at: 10), intimacyLog("chunk 0 b", at: 20)]),
            try encode([intimacyLog("chunk 1 a", at: 30)])
        ]
        let count = try coordinator.applyRestoredChunks(chunks, payloadType: .intimacyLogs, intimacyStore: store)
        #expect(count == 3)
        #expect(try store.backupLogCount() == 3)
    }
}

/// The in-memory stand-in for the user's private CloudKit database plus the throwaway keychain the
/// sealed records are sealed under, so an EXPORT can be asserted on: what reached iCloud, and whether a
/// later call left it alone. Real `SealedBackupService` + real crypto sit on top — only the transport
/// and the keychain slot are substituted.
@MainActor
final class FakeSealedBackupCloud {
    let keychainService: String
    let generationDefaults: UserDefaults
    let database = InMemoryCloudKitRecordDatabase()
    /// Per-iPhone keychains a test created over this cloud (each holds a copy of the escrow key, as
    /// iCloud Keychain would sync it, and its own device-only signing key); torn down with it.
    var phoneKeychainServices: [String] = []

    init(keychainService: String, generationDefaults: UserDefaults) {
        self.keychainService = keychainService
        self.generationDefaults = generationDefaults
    }

    /// The sealed-backup records currently "in iCloud", in save order.
    var sealedRecords: [CKRecord] { database.recordsByType["SealedBackupRecord"] ?? [] }

    /// Object identities of those records — an untouched chunk set keeps the SAME objects, so this is
    /// how a test asserts that a refused export wrote nothing rather than rewriting identical bytes.
    var sealedRecordIdentities: [ObjectIdentifier] { sealedRecords.map(ObjectIdentifier.init) }

    func tearDown() {
        KeychainItem.deleteAll(service: keychainService)
        for service in phoneKeychainServices { KeychainItem.deleteAll(service: service) }
    }
}

/// Minimal `CloudKitRecordDatabase` over a dictionary. Copies the sealed blob asset out of the
/// caller's temporary file the way CloudKit's own upload does, so a record stays readable after the
/// writer's scratch file goes away.
final class InMemoryCloudKitRecordDatabase: CloudKitRecordDatabase {
    var recordsByType: [String: [CKRecord]] = [:]
    /// When true every delete throws, as CloudKit does offline — a test's "the delete failed" case.
    var failsDeletes = false

    private var allRecords: [CKRecord] { recordsByType.values.flatMap { $0 } }

    func recordZoneIDs() async throws -> [CKRecordZone.ID] {
        var seen = Set<String>()
        return allRecords.compactMap { record in
            let zoneID = record.recordID.zoneID
            return seen.insert("\(zoneID.ownerName):\(zoneID.zoneName)").inserted ? zoneID : nil
        }
    }

    func recordIDs(matching recordType: String, in zoneID: CKRecordZone.ID) async throws -> [CKRecord.ID] {
        recordsByType[recordType, default: []].filter { $0.recordID.zoneID == zoneID }.map(\.recordID)
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
        if failsDeletes { throw CKError(.networkUnavailable) }
        let deleted = Set(recordIDs.map(\.recordName))
        for recordType in recordsByType.keys {
            recordsByType[recordType] = recordsByType[recordType, default: []]
                .filter { !deleted.contains($0.recordID.recordName) }
        }
    }
}

/// An iCloud account that is always signed in — these tests are about backup policy, not the sign-in
/// gate, which `CloudKitDataServiceTests` covers.
struct AlwaysAvailableAccountProvider: CloudKitAccountStatusProviding {
    func accountStatus() async throws -> CKAccountStatus { .available }
}
