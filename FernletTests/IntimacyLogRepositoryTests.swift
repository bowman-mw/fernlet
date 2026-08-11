//
//  IntimacyLogRepositoryTests.swift
//  FernletTests
//
//  The sealed-backup surface added to `IntimacyLogRepository` in security-hardening Phase 3:
//  a keyless row count, a paged reader in a TOTAL order, an all-or-nothing restore insert, and the
//  one-way "this device has diverged" latch that stops a stale cloud backup from resurrecting logs
//  the user deliberately deleted. The pre-existing seal/open behaviour is covered by
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

    // MARK: - Atomic restore insert

    @Test func insertAtomicallyWritesTheWholeBatch() throws {
        let repo = makeRepository()
        let key = makeKey()
        try repo.insertAtomically([log("a", at: 10), log("b", at: 20)], contentKey: key)
        #expect(try repo.logCount() == 2)
        #expect(try repo.logs(offset: 0, limit: 10, contentKey: key).map(\.note) == ["a", "b"])
    }

    /// Fail-closed: without a content key the batch is refused before a single row is written, and the
    /// divergence latch stays UNSET (a failed write is not evidence this device ever held data).
    @Test func insertAtomicallyWithNilKeyWritesNothingAndThrowsLocked() throws {
        let repo = makeRepository()
        #expect(throws: FernletLockError.self) {
            try repo.insertAtomically([log("never", at: 1)], contentKey: nil)
        }
        #expect(try repo.logCount() == 0)
        #expect(repo.hasEverStoredLog == false)
    }

    /// All-or-nothing: a save-time failure part-way through the batch rolls the WHOLE transaction back.
    /// A partially-populated store would trip the restore's no-clobber gate on the next launch and
    /// silently drop the un-inserted sealed records forever.
    @Test func insertAtomicallyRollsBackWhenTheSaveFails() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let repo = IntimacyLogRepository(context: context, defaults: isolatedLatchDefaults())
        try repo.insert(log("pre-existing", at: 1), contentKey: makeKey())

        for store in controller.container.persistentStoreCoordinator.persistentStores {
            try controller.container.persistentStoreCoordinator.remove(store)
        }
        #expect(throws: (any Error).self) {
            try repo.insertAtomically([log("batch-1", at: 2), log("batch-2", at: 3)], contentKey: makeKey())
        }
        #expect(context.insertedObjects.isEmpty, "a failed atomic insert left objects in the context")
    }

    // MARK: - One-way divergence latch

    @Test func latchIsUnsetOnAFreshStoreAndSetByAnInsert() throws {
        let repo = makeRepository()
        #expect(repo.hasEverStoredLog == false)
        try repo.insert(log("first", at: 1), contentKey: makeKey())
        #expect(repo.hasEverStoredLog)
    }

    @Test func latchIsSetByInsertAtomically() throws {
        let repo = makeRepository()
        try repo.insertAtomically([log("restored", at: 1)], contentKey: makeKey())
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
