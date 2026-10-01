//
//  IntimacyLogRepositoryTests.swift
//  FernletTests
//
//  The sealed-backup surface of `IntimacyLogRepository`: a keyless row count, a paged reader in a
//  TOTAL order, the one-way "this device has diverged" latch (which now seeds the intimate-log
//  restore marker once), and — since the Sealed backup v2 (design 2026-09-30, §8, BV12) — the keyless
//  id snapshot, the classified read by id, the id-keyed restore MERGE and the keyless delete by id. The pre-existing seal/open behaviour is covered by
//  `PrivateHistoryPruningTests` and `SensitiveSurfaceGateTests`.
//

import CoreData
import CryptoKit
import Foundation
import Testing
import FernletFoundation
import PrivateHealthStore
import PrivateStoreCore

@Suite(.serialized)
struct IntimacyLogRepositoryTests {

    /// An isolated repository AND an isolated latch suite: `hasEverStoredLog` lives in
    /// `UserDefaults.standard`, which is process-global under the test runner, so a shared suite would
    /// let one test's insert mark every later test's device as "already diverged".
    private func makeRepository(defaults: UserDefaults? = nil) -> IntimacyLogRepository {
        IntimacyLogRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: defaults ?? isolatedLatchDefaults()
        )
    }

    private func isolatedLatchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.intimacyLatch.\(UUID().uuidString)") ?? .standard
    }

    private func makeKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    private func log(_ note: String, at seconds: TimeInterval, id: UUID = UUID()) -> IntimacyLog {
        IntimacyLog(id: id, eventDate: Date(timeIntervalSince1970: seconds), note: note)
    }

    // MARK: - Count + paged reader

    /// The export sizes its chunks from this, and the restore's no-clobber gate consults it while the
    /// app may be locked — so counting rows must never require decrypting them.
    @Test func logCountDoesNotNeedTheContentKey() throws {
        let repo = makeRepository()
        let key = makeKey()
        #expect(try repo.logCount() == 0)
        for index in 0..<3 {
            try repo.insert(log("note \(index)", at: Double(index)), contentKey: key)
        }
        #expect(try repo.logCount() == 3)
    }

    /// The paged reader must be a TOTAL order: every row exactly once across successive pages, no
    /// overlap and no skip. The adversarial case is a tie on the primary sort key, which is why the
    /// unique `id` is the tiebreaker — here every row shares one `eventDate`.
    @Test func pagedReaderIsATotalOrderEvenWhenEveryEventDateTies() throws {
        let repo = makeRepository()
        let key = makeKey()
        var expected: Set<String> = []
        for index in 0..<10 {
            let note = "tied \(index)"
            expected.insert(note)
            try repo.insert(log(note, at: 1_780_000_000), contentKey: key)
        }

        var seen: [String] = []
        var offset = 0
        while true {
            let page = try repo.logs(offset: offset, limit: 3, contentKey: key)
            if page.isEmpty { break }
            seen.append(contentsOf: page.map(\.note))
            offset += 3
        }
        #expect(seen.count == 10, "paged reader overlapped or skipped rows: \(seen.sorted())")
        #expect(Set(seen) == expected)
    }

    /// Export order is ASCENDING by `eventDate` — deliberately the opposite of the display reader
    /// (`logs(contentKey:)`, newest first), which stays untouched.
    @Test func pagedReaderIsAscendingWhileTheDisplayReaderStaysNewestFirst() throws {
        let repo = makeRepository()
        let key = makeKey()
        try repo.insert(log("older", at: 100), contentKey: key)
        try repo.insert(log("newer", at: 200), contentKey: key)

        #expect(try repo.logs(offset: 0, limit: 10, contentKey: key).map(\.note) == ["older", "newer"])
        #expect(try repo.logs(contentKey: key).map(\.note) == ["newer", "older"])
    }

    @Test func pagedReaderReturnsNothingWithoutAKey() throws {
        let repo = makeRepository()
        try repo.insert(log("sealed", at: 1), contentKey: makeKey())
        #expect(try repo.logs(offset: 0, limit: 10, contentKey: nil).isEmpty)
    }

    // MARK: - Sealed backup v2 surface (design 2026-09-30, §8, BV12)

    /// The export's snapshot is keyless, distinct and in the store's total order (event date, then
    /// id) — and decrypts nothing, so it answers with no key at all.
    @Test func allIDsIsAKeylessSnapshotInTheStoresTotalOrder() throws {
        let repo = makeRepository()
        let key = makeKey()
        let later = log("later", at: 200)
        let earlier = log("earlier", at: 100)
        try repo.insert(later, contentKey: key)
        try repo.insert(earlier, contentKey: key)
        #expect(try repo.allIDs() == [earlier.id, later.id])
    }

    /// The classified read never skips: a row that opens is a record, a row sealed under another key
    /// is dead, an id with no row (deleted since the snapshot) is absent, and nothing is answered
    /// without a key.
    @Test func logsByIDClassifyEveryRowInsteadOfSkippingIt() throws {
        let repo = makeRepository()
        let key = makeKey()
        let opens = log("opens", at: 1)
        let dead = log("other key", at: 2)
        try repo.insert(opens, contentKey: key)
        try repo.insert(dead, contentKey: makeKey())
        let page = try repo.logs(ids: [dead.id, UUID(), opens.id], contentKey: key)
        #expect(page.records.map(\.id) == [opens.id])
        #expect(page.deadIDs == [dead.id])
        #expect(page.needsNewerBuildIDs.isEmpty && page.transientCount == 0)
        #expect(try repo.logs(ids: [opens.id], contentKey: nil) == IntimacyLogPage())
        #expect(throws: IntimacyLogRepositoryError.self) {
            try repo.logs(ids: (0...IntimacyLogRepository.maxPageSize).map { _ in UUID() }, contentKey: key)
        }
    }

    /// BV12: an absent id is inserted with the BACKUP'S own stamps (a restore is not a fresh write) and
    /// its note capped at 1 000 characters before sealing — and the latch is set.
    @Test func upsertMergedInsertsAbsentLogsWithTheirStampsAndACappedNote() throws {
        let repo = makeRepository()
        let key = makeKey()
        let stamp = Date(timeIntervalSince1970: 1_700_000_000)
        let incoming = IntimacyLog(
            id: UUID(), dayKey: "2026-01-02", eventDate: stamp, note: String(repeating: "n", count: 1_500),
            healthKitExternalUUID: "hk-1", createdAt: stamp, updatedAt: stamp.addingTimeInterval(60)
        )
        let result = try repo.upsertMerged([incoming], contentKey: key)
        #expect(result.inserted == 1 && result.changedAnything)
        let stored = try #require(try repo.logs(ids: [incoming.id], contentKey: key).records.first)
        #expect(stored.note.count == IntimacyLogRepository.maxNoteLength)
        #expect(stored.createdAt == incoming.createdAt && stored.updatedAt == incoming.updatedAt)
        #expect(stored.dayKey == "2026-01-02" && stored.healthKitExternalUUID == "hk-1")
        #expect(repo.hasEverStoredLog)
    }

    /// BV12: a stored log that opens is KEPT exactly as it is — a different note under the same id
    /// (corruption or a hostile set; there is no per-log edit) never replaces it — except that a
    /// missing Health link is taken from the backup. A link is never dropped or changed.
    @Test func upsertMergedKeepsLocalLogsAndOnlyFillsAMissingHealthLink() throws {
        let repo = makeRepository()
        let key = makeKey()
        let unlinked = log("mine", at: 1)
        var linked = log("linked", at: 2)
        linked.healthKitExternalUUID = "local-link"
        try repo.insert(unlinked, contentKey: key)
        try repo.insert(linked, contentKey: key)
        var incomingUnlinked = unlinked
        incomingUnlinked.note = "theirs"
        incomingUnlinked.healthKitExternalUUID = "their-link"
        var incomingLinked = linked
        incomingLinked.healthKitExternalUUID = nil

        let result = try repo.upsertMerged([incomingUnlinked, incomingLinked], contentKey: key)
        #expect(result.linked == 1 && result.unchanged == 1 && result.inserted == 0 && result.replaced == 0)
        let stored = try repo.logs(ids: [unlinked.id, linked.id], contentKey: key).records
        #expect(stored.map(\.note) == ["mine", "linked"], "the local note always wins")
        #expect(stored.map(\.healthKitExternalUUID) == ["their-link", "local-link"], "filled, never dropped")
    }

    /// BV12: a stored row that can never open (another key) is replaced by the backup's copy — an
    /// openable copy of a dead row loses nothing — and nothing local is ever deleted: a log the backup
    /// does not carry stays.
    @Test func upsertMergedReplacesDeadRowsAndNeverDeletes() throws {
        let repo = makeRepository()
        let key = makeKey()
        let dead = log("sealed elsewhere", at: 1)
        let onlyHere = log("only here", at: 2)
        try repo.insert(dead, contentKey: makeKey())
        try repo.insert(onlyHere, contentKey: key)
        var incoming = dead
        incoming.note = "from the backup"

        let result = try repo.upsertMerged([incoming], contentKey: key)
        #expect(result.replaced == 1)
        let page = try repo.logs(ids: [dead.id, onlyHere.id], contentKey: key)
        #expect(page.records.map(\.note) == ["from the backup", "only here"])
        #expect(page.deadIDs.isEmpty)
        #expect(try repo.logCount() == 2)
    }

    /// BV12: idempotent (a second merge of the same set changes nothing and reports nothing changed),
    /// and a duplicate id in a hostile set is reduced first — the later `updatedAt` wins.
    @Test func upsertMergedIsIdempotentAndReducesDuplicateIDs() throws {
        let repo = makeRepository()
        let key = makeKey()
        let id = UUID()
        let older = IntimacyLog(id: id, eventDate: Date(timeIntervalSince1970: 10), note: "older",
                                createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 10))
        let newer = IntimacyLog(id: id, eventDate: Date(timeIntervalSince1970: 10), note: "newer",
                                createdAt: Date(timeIntervalSince1970: 10), updatedAt: Date(timeIntervalSince1970: 20))
        #expect(try repo.upsertMerged([older, newer], contentKey: key).inserted == 1)
        #expect(try repo.logs(ids: [id], contentKey: key).records.map(\.note) == ["newer"])
        let again = try repo.upsertMerged([older, newer], contentKey: key)
        #expect(!again.changedAnything && again.unchanged == 1)
        #expect(try repo.logCount() == 1)
    }

    /// BV12: atomic — a merge that fails part-way (here: no store to save into) leaves nothing pending
    /// in the shared context; and without a key nothing is written and the latch stays unset.
    @Test func upsertMergedIsAllOrNothing() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let repo = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        #expect(throws: FernletLockError.self) {
            try repo.upsertMerged([log("never", at: 1)], contentKey: nil)
        }
        #expect(try repo.logCount() == 0 && repo.hasEverStoredLog == false)
        #expect(repo.isStoreHealthy)

        for store in controller.container.persistentStoreCoordinator.persistentStores {
            try controller.container.persistentStoreCoordinator.remove(store)
        }
        #expect(!repo.isStoreHealthy, "a storeless controller reads as unhealthy")
        #expect(throws: (any Error).self) {
            try repo.upsertMerged([log("batch-1", at: 2), log("batch-2", at: 3)], contentKey: makeKey())
        }
        #expect(context.insertedObjects.isEmpty, "a failed merge left objects in the context")
    }

    /// "Remove them": a keyless delete of exactly these ids, latching divergence when rows went.
    @Test func deleteByIDsRemovesOnlyThoseRows() throws {
        let repo = makeRepository()
        let key = makeKey()
        let gone = log("gone", at: 1)
        let kept = log("kept", at: 2)
        try repo.insert(gone, contentKey: key)
        try repo.insert(kept, contentKey: key)
        #expect(try repo.delete(ids: [gone.id, UUID()]) == 1)
        #expect(try repo.allIDs() == [kept.id])
        #expect(try repo.delete(ids: []) == 0)
    }

    // MARK: - One-way divergence latch

    @Test func latchIsUnsetOnAFreshStoreAndSetByAnInsert() throws {
        let repo = makeRepository()
        #expect(repo.hasEverStoredLog == false)
        try repo.insert(log("first", at: 1), contentKey: makeKey())
        #expect(repo.hasEverStoredLog)
    }

    @Test func latchIsSetByARestoreMerge() throws {
        let repo = makeRepository()
        _ = try repo.upsertMerged([log("restored", at: 1)], contentKey: makeKey())
        #expect(repo.hasEverStoredLog, "a restore that populates the store must latch too")
    }

    /// One-way, and survives emptying the store — the whole point. Without it an empty-because-deleted
    /// store is indistinguishable from a fresh install, and the stale cloud copy resurrects logs the
    /// user deliberately removed.
    @Test func latchSurvivesDeleteAndDeleteAll() throws {
        let repo = makeRepository()
        let key = makeKey()
        let entry = log("delete me", at: 1)
        try repo.insert(entry, contentKey: key)
        try repo.delete(id: entry.id)
        #expect(try repo.logCount() == 0)
        #expect(repo.hasEverStoredLog)

        try repo.insert(log("and again", at: 2), contentKey: key)
        try repo.deleteAll()
        #expect(try repo.logCount() == 0)
        #expect(repo.hasEverStoredLog, "delete-all must leave the latch set — the wipe must stick")
    }

    @Test func deletingAMissingRowDoesNotLatch() throws {
        let repo = makeRepository()
        try repo.delete(id: UUID())
        #expect(repo.hasEverStoredLog == false)
    }

    /// The upgrade configuration: rows written before the latch shipped, read through defaults that
    /// never latched. Without the count backfill an upgrading install reads as "never populated".
    @Test func latchBackfillsFromRowsWrittenBeforeItShipped() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let preLatch = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        try preLatch.insert(log("pre-upgrade", at: 1), contentKey: makeKey())

        let upgraded = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        #expect(upgraded.hasEverStoredLog, "the latch did not backfill from existing rows")
    }

    /// The one the backfill alone cannot catch: the upgrading user DELETES their pre-latch history
    /// first, so nothing ever read the latch while rows existed. The delete itself has to latch.
    @Test func deleteLatchesEvenForPreLatchRows() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let preLatch = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        let entry = log("pre-upgrade, then deleted", at: 1)
        try preLatch.insert(entry, contentKey: makeKey())

        let upgraded = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        try upgraded.delete(id: entry.id)
        #expect(try upgraded.logCount() == 0)
        #expect(upgraded.hasEverStoredLog, "the delete did not latch the diverged marker")
    }

    /// `markSavedToHealthKit` is metadata-only, but it PROVES a row existed — so it latches too, the
    /// same reasoning as `MenstrualNarrativeRepository.update`.
    @Test func markSavedToHealthKitLatchesEvenForPreLatchRows() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let preLatch = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        let entry = log("pre-upgrade", at: 1)
        try preLatch.insert(entry, contentKey: makeKey())

        let upgraded = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        try upgraded.markSavedToHealthKit(id: entry.id, externalUUID: UUID())
        #expect(upgraded.hasEverStoredLog)
    }

    /// Isolation: two repositories on DIFFERENT defaults suites must not see each other's latch.
    @Test func latchIsIsolatedPerInjectedDefaultsSuite() throws {
        let latched = makeRepository()
        try latched.insert(log("latched", at: 1), contentKey: makeKey())
        #expect(latched.hasEverStoredLog)

        let separate = makeRepository()
        #expect(separate.hasEverStoredLog == false)
    }
}
