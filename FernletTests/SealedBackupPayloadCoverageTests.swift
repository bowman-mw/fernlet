//
//  SealedBackupPayloadCoverageTests.swift
//  FernletTests
//
//  Security-hardening Phase 3: journal narratives and intimacy logs as first-class sealed-backup
//  payloads. These drive `SealedBackupCoordinator` directly through a fake `SealedBackupContext`, so
//  the restore semantics (insert-into-empty, the one-way divergence latch, the locked-key deferral)
//  and the empty-store-clobber guard are exercised against ISOLATED sealed stores — no CloudKit, no
//  shared on-device store, no `UserDefaults.standard` latch bleed.
//
//  The FernletStore-level halves (journal skeleton reconstruction, the wiring of the store's own
//  wrappers) live in SealedBackupRestoreTests, which needs a real store to observe.
//

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
    var tierTwoMemories: [TierTwoMemoryRecord] = []
    var sealedBackupContentKey: SymmetricKey?
    var isPeriodTrackingVisible = true
    var isIntimacyTrackingVisible = true
    var previousJournals: [JournalEntry] = []
    var memories: [MemoryNote] = []
    var recentMeals: [Meal] = []
    var days: [String: FernletDay] = [:]

    /// Narratives handed to ``reinstateJournalEntries(from:)``, in call order — the journal
    /// self-sufficiency hook's observable effect at this seam.
    private(set) var reinstatedJournalNarratives: [[JournalNarrative]] = []
    private(set) var recordedOutcomes: [SealedBackupPayloadType: SealedBackupRestoreOutcome] = [:]

    func replaceTierTwoMemories(_ records: [TierTwoMemoryRecord]) { tierTwoMemories = records }
    func loadAllDaysFromRepository() -> [String: FernletDay] { days }
    func recordSealedBackupPeriodReuploadDeferred(_ deferred: Bool) {}
    func recordSealedBackupRestoreOutcome(_ outcome: SealedBackupRestoreOutcome, payloadType: SealedBackupPayloadType) {
        recordedOutcomes[payloadType] = outcome
    }
    func recordSealedBackupEscrowConflict(_ inConflict: Bool) {}
    func reinstateJournalEntries(from narratives: [JournalNarrative]) {
        reinstatedJournalNarratives.append(narratives)
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
        store.isVisible = { true }
        defer { store.isVisible = previous }
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
            journalRepository: repository,
            scope: .payloadStoreOnly
        )
        #expect(count == 2)

        let readBack = try repository.narratives(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey)
        #expect(readBack.map(\.text) == ["Slept badly, wrote it down.", "Better today."])
        #expect(readBack.first?.emotions == ["calm"])
        // Self-sufficiency: the skeletons hook fired with exactly what was written.
        #expect(host.reinstatedJournalNarratives.count == 1)
        #expect(host.reinstatedJournalNarratives.first?.count == 2)
    }

    /// Insert-into-empty, never overwrite: a store that already holds journal rows is refused outright
    /// rather than merged, so a restore can never clobber or duplicate the user's own text.
    @Test func journalRestoreRefusesAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        try repository.insert(journalNarrative("Written on this device.", at: 50), contentKey: host.sealedBackupContentKey)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([journalNarrative("From the backup.", at: 100)]),
                payloadType: .journalNarratives,
                journalRepository: repository,
                scope: .payloadStoreOnly
            )
        }
        #expect(try repository.narrativeCount() == 1)
        #expect(host.reinstatedJournalNarratives.isEmpty, "a refused restore must not touch the day blob")
    }

    /// The empty-but-DIVERGED store: the user wrote entries and deleted them, so the row count is 0
    /// while the cloud copy is stale-by-construction. Restoring there would resurrect deliberately
    /// deleted journal text — the one-way latch is what carries that missing bit.
    @Test func journalRestoreRefusesAnEmptyButDivergedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let entry = journalNarrative("Written, then deleted.", at: 50)
        try repository.insert(entry, contentKey: host.sealedBackupContentKey)
        try repository.delete(id: entry.id)
        #expect(try repository.narrativeCount() == 0)
        #expect(repository.hasEverStoredNarrative)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([journalNarrative("Resurrected?", at: 100)]),
                payloadType: .journalNarratives,
                journalRepository: repository,
                scope: .payloadStoreOnly
            )
        }
        #expect(try repository.narrativeCount() == 0)
    }

    /// Locked at the write point → `.locked`, which the restore classifier maps to the RETRYABLE
    /// `.deferredLocked`; unlocking and retrying is the self-heal, and it must actually work.
    @Test func journalRestoreDefersWhileLockedThenSelfHealsAfterUnlock() throws {
        let host = makeHost(key: nil)   // locked: no content key
        let coordinator = SealedBackupCoordinator(host: host)
        let repository = makeJournalRepository()
        let payload = try encode([journalNarrative("Waiting for the unlock.", at: 100)])

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.locked) {
            try coordinator.applyRestoredPayload(
                payload, payloadType: .journalNarratives,
                journalRepository: repository, scope: .payloadStoreOnly
            )
        }
        #expect(try repository.narrativeCount() == 0)
        #expect(repository.hasEverStoredNarrative == false, "a deferred restore must not latch divergence")
        #expect(SealedBackupRestoreOutcome.deferredLocked.isRetryable)

        // The user unlocks; the same payload now lands.
        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        let count = try coordinator.applyRestoredPayload(
            payload, payloadType: .journalNarratives,
            journalRepository: repository, scope: .payloadStoreOnly
        )
        #expect(count == 1)
        #expect(try repository.narrativeCount() == 1)
    }


    // MARK: - Intimacy: restore through the gated funnel

    @Test func intimacyRestoreWritesLogsIntoAnEmptyStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let logs = [intimacyLog("first", at: 100), intimacyLog("second", at: 200)]

        let count = try coordinator.applyRestoredPayload(
            try encode(logs),
            payloadType: .intimacyLogs,
            intimacyStore: store,
            scope: .payloadStoreOnly
        )
        #expect(count == 2)
        let readBack = try store.backupPage(offset: 0, limit: 10, contentKey: host.sealedBackupContentKey)
        #expect(readBack.map(\.note) == ["first", "second"])
        #expect(host.reinstatedJournalNarratives.isEmpty, "intimacy restore must not touch journal skeletons")
    }

    @Test func intimacyRestoreRefusesAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("logged locally", at: 50), into: store, key: host.sealedBackupContentKey)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("from the backup", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: store,
                scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 1)
    }

    /// The empty-but-DIVERGED store: logged, then deleted, so the count is 0 while the cloud copy is
    /// stale-by-construction. Restoring there would resurrect deliberately deleted intimate notes.
    @Test func intimacyRestoreRefusesAnEmptyButDivergedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("logged, then deleted", at: 50), into: store, key: host.sealedBackupContentKey)
        // Deleting is ungated (hiding must never block a wipe) and latches divergence.
        try store.deleteAll()
        #expect(try store.backupLogCount() == 0)
        #expect(store.hasEverStoredLog)

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("resurrected?", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: store,
                scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 0)
    }

    @Test func intimacyRestoreDefersWhileLockedThenSelfHealsAfterUnlock() throws {
        let host = makeHost(key: nil)
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        let payload = try encode([intimacyLog("waiting for the unlock", at: 100)])

        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.locked) {
            try coordinator.applyRestoredPayload(
                payload, payloadType: .intimacyLogs,
                intimacyStore: store, scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 0)
        #expect(store.hasEverStoredLog == false)

        host.sealedBackupContentKey = SymmetricKey(size: .bits256)
        #expect(try coordinator.applyRestoredPayload(
            payload, payloadType: .intimacyLogs,
            intimacyStore: store, scope: .payloadStoreOnly
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
                intimacyStore: store, scope: .payloadStoreOnly
            )
        }
        #expect(try store.backupLogCount() == 0)

        host.isIntimacyTrackingVisible = true
        #expect(try coordinator.applyRestoredPayload(
            payload, payloadType: .intimacyLogs,
            intimacyStore: store, scope: .payloadStoreOnly
        ) == 1)
    }

    /// The no-clobber GATE, unlike the write, is deliberately NOT visibility-aware: it counts rows
    /// without decrypting. A hidden store reading as "empty" here would be the hidden-means-empty bug —
    /// the gate would wave a restore through on top of data it could not see.
    @Test func intimacyNoClobberGateNeverReadsAHiddenStoreAsEmpty() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let store = makeIntimacyStore()
        try seed(intimacyLog("hidden but present", at: 50), into: store, key: host.sealedBackupContentKey)

        host.isIntimacyTrackingVisible = false
        // storeNotEmpty, NOT "hidden" — the gate ran first and saw the rows through the closed gate.
        #expect(throws: SealedBackupCoordinator.SealedBackupWiringError.storeNotEmpty) {
            try coordinator.applyRestoredPayload(
                try encode([intimacyLog("from the backup", at: 100)]),
                payloadType: .intimacyLogs,
                intimacyStore: store,
                scope: .payloadStoreOnly
            )
        }
        #expect(coordinator.intimacyLogCount(store: store) == 1, "a hidden store must not count as empty")
        #expect(store.hasEverStoredLog, "a hidden store must not read as never-populated")
    }

    // MARK: - Empty-store clobber guards

    /// `reconcileChunked` writes a head record even for a count of 0, so an export from a store this
    /// device has not restored into yet would REPLACE a good cloud backup with a single empty chunk.
    /// An empty store means "not restored yet", never "nothing to back up".
    @Test func reuploadIsRefusedFromAnEmptyJournalStoreAndAllowedFromAPopulatedOne() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let empty = makeJournalRepository()
        #expect(coordinator.mayReuploadFromLocalStore(.journalNarratives, journalRepository: empty) == false)

        let populated = makeJournalRepository()
        try populated.insert(journalNarrative("real history", at: 10), contentKey: host.sealedBackupContentKey)
        #expect(coordinator.mayReuploadFromLocalStore(.journalNarratives, journalRepository: populated))
    }

    @Test func reuploadIsRefusedFromAnEmptyIntimacyStoreAndAllowedFromAPopulatedOne() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let empty = makeIntimacyStore()
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: empty) == false)

        let populated = makeIntimacyStore()
        try seed(intimacyLog("real history", at: 10), into: populated, key: host.sealedBackupContentKey)
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: populated))
    }

    /// Hidden intimacy also blocks the re-upload, and for a second reason: while hidden the reconcile
    /// is a SILENT no-op, so calling it would log a false "reconciled" while the cloud chunk stayed
    /// sealed to the escrow key that was just replaced.
    @Test func reuploadIsRefusedWhileIntimacyIsHiddenEvenWithAPopulatedStore() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let populated = makeIntimacyStore()
        try seed(intimacyLog("real history", at: 10), into: populated, key: host.sealedBackupContentKey)
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: populated))

        host.isIntimacyTrackingVisible = false
        #expect(coordinator.mayReuploadFromLocalStore(.intimacyLogs, intimacyStore: populated) == false)
    }

    /// The counts the guards read work with no content key in play — the guards run while the app may
    /// be locked, and they fail CLOSED at 0 so "unknown" reads as "do not re-upload".
    @Test func countsReadRowsWithoutAKeyAndStartAtZero() throws {
        let host = makeHost()
        let coordinator = SealedBackupCoordinator(host: host)
        let journal = makeJournalRepository()
        let intimacy = makeIntimacyStore()
        #expect(coordinator.journalNarrativeCount(repository: journal) == 0)
        #expect(coordinator.intimacyLogCount(store: intimacy) == 0)

        try journal.insert(journalNarrative("one", at: 1), contentKey: host.sealedBackupContentKey)
        try seed(intimacyLog("one", at: 1), into: intimacy, key: host.sealedBackupContentKey)
        #expect(coordinator.journalNarrativeCount(repository: journal) == 1)
        #expect(coordinator.intimacyLogCount(store: intimacy) == 1)
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
        let count = try coordinator.applyRestoredChunks(
            chunks, payloadType: .journalNarratives,
            journalRepository: repository, scope: .payloadStoreOnly
        )
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
        let count = try coordinator.applyRestoredChunks(
            chunks, payloadType: .intimacyLogs,
            intimacyStore: store, scope: .payloadStoreOnly
        )
        #expect(count == 3)
        #expect(try store.backupLogCount() == 3)
    }
}
