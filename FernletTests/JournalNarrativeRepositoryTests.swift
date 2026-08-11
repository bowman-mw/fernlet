import CoreData
import CryptoKit
import Testing
@testable import FernletCrypto
import FernletDomainModel
import PrivateMemoryStore
import FernletFoundation
import PrivateStoreCore
@testable import Fernlet

@Suite(.serialized)
struct JournalNarrativeRepositoryTests {

    /// An isolated repository AND an isolated latch suite: `hasEverStoredNarrative` lives in
    /// `UserDefaults.standard`, which is process-global under the test runner, so a shared suite would
    /// let one test's insert mark every later test's device as "already diverged".
    private func makeRepository(defaults: UserDefaults? = nil) -> JournalNarrativeRepository {
        JournalNarrativeRepository(
            context: PrivatePersistenceController(inMemory: true).container.viewContext,
            defaults: defaults ?? isolatedLatchDefaults()
        )
    }

    private func isolatedLatchDefaults() -> UserDefaults {
        UserDefaults(suiteName: "fernlet.tests.journalLatch.\(UUID().uuidString)") ?? .standard
    }

    private func makeKey() -> SymmetricKey {
        SymmetricKey(size: .bits256)
    }

    // MARK: - Round-trip

    @Test func insertAndFetchDecryptsCorrectly() throws {
        let repo = makeRepository()
        let key = makeKey()
        let narrative = JournalNarrative(
            id: UUID(),
            dayKey: "2026-05-28",
            tag: .good,
            entryDate: Date(),
            text: "A meaningful day.",
            emotions: ["grateful", "calm"],
            createdAt: Date(),
            updatedAt: Date()
        )

        try repo.insert(narrative, contentKey: key)
        let fetched = try repo.narratives(forDayKey: "2026-05-28", contentKey: key)

        #expect(fetched.count == 1)
        let result = try #require(fetched.first)
        #expect(result.id == narrative.id)
        #expect(result.text == narrative.text)
        #expect(result.emotions == narrative.emotions)
        #expect(result.tag == narrative.tag)
    }

    @Test func updateReplacesTextAndEmotions() throws {
        let repo = makeRepository()
        let key = makeKey()
        let id = UUID()
        let original = JournalNarrative(
            id: id, dayKey: "2026-05-28", tag: .quiet, entryDate: Date(),
            text: "Original text.", emotions: ["tired"],
            createdAt: Date(), updatedAt: Date()
        )
        try repo.insert(original, contentKey: key)

        var updated = original
        updated.text = "Updated text."
        updated.emotions = ["refreshed"]
        try repo.update(updated, contentKey: key)

        let fetched = try repo.narratives(forDayKey: "2026-05-28", contentKey: key)
        #expect(fetched.first?.text == "Updated text.")
        #expect(fetched.first?.emotions == ["refreshed"])
    }

    @Test func deleteRemovesEntry() throws {
        let repo = makeRepository()
        let key = makeKey()
        let id = UUID()
        let narrative = JournalNarrative(
            id: id, dayKey: "2026-05-28", tag: .good, entryDate: Date(),
            text: "Will be deleted.", emotions: [],
            createdAt: Date(), updatedAt: Date()
        )
        try repo.insert(narrative, contentKey: key)
        try repo.delete(id: id)

        let fetched = try repo.narratives(forDayKey: "2026-05-28", contentKey: key)
        #expect(fetched.isEmpty)
    }

    @Test func fetchByMultipleDayKeysReturnsBoth() throws {
        let repo = makeRepository()
        let key = makeKey()
        let a = JournalNarrative(
            id: UUID(), dayKey: "2026-05-27", tag: .good, entryDate: Date(),
            text: "Day A.", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        let b = JournalNarrative(
            id: UUID(), dayKey: "2026-05-28", tag: .neutral, entryDate: Date(),
            text: "Day B.", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        try repo.insert(a, contentKey: key)
        try repo.insert(b, contentKey: key)

        let fetched = try repo.narratives(forDayKeys: ["2026-05-27", "2026-05-28"], contentKey: key)
        #expect(fetched.count == 2)
    }

    // MARK: - Security

    @Test func wrongKeySkipsUndecryptableRows() throws {
        let repo = makeRepository()
        let key = makeKey()
        let wrongKey = makeKey()
        let narrative = JournalNarrative(
            id: UUID(), dayKey: "2026-05-28", tag: .hard, entryDate: Date(),
            text: "Secret.", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        try repo.insert(narrative, contentKey: key)

        // A row that cannot be decrypted is skipped, not rethrown. The fetch must not
        // surface the wrong-key contents and must not blow up the whole fetch.
        let fetched = try repo.narratives(forDayKey: "2026-05-28", contentKey: wrongKey)
        #expect(fetched.isEmpty)
    }

    /// Regression for prior finding #122: a single undecryptable row must not wipe every
    /// valid journal narrative for the day. Previously `try decrypt` inside compactMap
    /// rethrew, and callers' `try?` turned that into an empty result, silently hiding
    /// good entries alongside the corrupt one.
    @Test func corruptRowDoesNotWipeValidRows() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let repo = JournalNarrativeRepository(context: context)
        let key = makeKey()

        let good = JournalNarrative(
            id: UUID(), dayKey: "2026-05-28", tag: .good, entryDate: Date(),
            text: "Valid entry.", emotions: ["calm"], createdAt: Date(), updatedAt: Date()
        )
        let bad = JournalNarrative(
            id: UUID(), dayKey: "2026-05-28", tag: .hard, entryDate: Date(),
            text: "Corrupt entry.", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        try repo.insert(good, contentKey: key)
        try repo.insert(bad, contentKey: key)

        // Corrupt the bad row's ciphertext directly so its decrypt throws.
        let request = NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative")
        request.predicate = NSPredicate(format: "id == %@", bad.id as CVarArg)
        let object = try #require(try context.fetch(request).first)
        object.setValue(Data([0x00, 0x01, 0x02, 0x03]), forKey: "textCiphertext")
        try context.save()

        let fetched = try repo.narratives(forDayKey: "2026-05-28", contentKey: key)
        #expect(fetched.count == 1)
        #expect(fetched.first?.id == good.id)
        #expect(fetched.first?.text == "Valid entry.")
    }

    @Test func insertWithNilKeyThrowsLocked() throws {
        let repo = makeRepository()
        let narrative = JournalNarrative(
            id: UUID(), dayKey: "2026-05-28", tag: .good, entryDate: Date(),
            text: "Locked.", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        #expect(throws: FernletLockError.self) {
            try repo.insert(narrative, contentKey: nil)
        }
    }

    @Test func journalColumnKeyDiffersFromMenstrualNarrativeKey() {
        let contentKey = SymmetricKey(size: .bits256)
        // Journal uses "journal-narrative" HKDF label; MenstrualNarrative uses "menstrual-narrative".
        // Derived through the PRODUCTION helper (not a local HKDF copy) so this stays a statement
        // about what the app actually does if the derivation ever changes.
        let journalKey = ColumnCrypto.deriveColumnKey(
            contentKey: contentKey, info: "journal-narrative", outputByteCount: 32
        )
        let menstrualKey = ColumnCrypto.deriveColumnKey(
            contentKey: contentKey, info: "menstrual-narrative", outputByteCount: 32
        )
        #expect(journalKey != menstrualKey)
    }

    // MARK: - Sealed-backup surface (P3): count, paged total order, atomic insert, divergence latch

    private func narrative(
        _ text: String,
        dayKey: String = "2026-05-28",
        entryDate: Date,
        id: UUID = UUID()
    ) -> JournalNarrative {
        JournalNarrative(
            id: id, dayKey: dayKey, tag: .good, entryDate: entryDate,
            text: text, emotions: [], createdAt: entryDate, updatedAt: entryDate
        )
    }

    /// The export sizes its chunks from this, so it must work with NO content key — counting rows must
    /// never require decrypting them.
    @Test func narrativeCountDoesNotNeedTheContentKey() throws {
        let repo = makeRepository()
        let key = makeKey()
        #expect(try repo.narrativeCount() == 0)
        for index in 0..<3 {
            try repo.insert(narrative("entry \(index)", entryDate: Date(timeIntervalSince1970: Double(index))), contentKey: key)
        }
        // No key passed anywhere in this call — and it still answers.
        #expect(try repo.narrativeCount() == 3)
    }

    /// The paged reader must be a TOTAL order: every row appears exactly once across successive pages,
    /// with no overlap and no skip. The adversarial case is a tie on the primary sort key, which is why
    /// the unique `id` is the tiebreaker — here every row shares one `entryDate`.
    @Test func pagedReaderIsATotalOrderEvenWhenEveryEntryDateTies() throws {
        let repo = makeRepository()
        let key = makeKey()
        let tie = Date(timeIntervalSince1970: 1_780_000_000)
        var expected: Set<String> = []
        for index in 0..<10 {
            let text = "tied \(index)"
            expected.insert(text)
            try repo.insert(narrative(text, entryDate: tie), contentKey: key)
        }

        var seen: [String] = []
        var offset = 0
        while true {
            let page = try repo.narratives(offset: offset, limit: 3, contentKey: key)
            if page.isEmpty { break }
            seen.append(contentsOf: page.map(\.text))
            offset += 3
        }
        #expect(seen.count == 10, "paged reader overlapped or skipped rows: \(seen.sorted())")
        #expect(Set(seen) == expected)
    }

    /// Ascending by `entryDate` — the export's stable order, independent of insertion order.
    @Test func pagedReaderSortsAscendingByEntryDate() throws {
        let repo = makeRepository()
        let key = makeKey()
        try repo.insert(narrative("third", entryDate: Date(timeIntervalSince1970: 300)), contentKey: key)
        try repo.insert(narrative("first", entryDate: Date(timeIntervalSince1970: 100)), contentKey: key)
        try repo.insert(narrative("second", entryDate: Date(timeIntervalSince1970: 200)), contentKey: key)

        let page = try repo.narratives(offset: 0, limit: 10, contentKey: key)
        #expect(page.map(\.text) == ["first", "second", "third"])
    }

    @Test func pagedReaderReturnsNothingWithoutAKey() throws {
        let repo = makeRepository()
        try repo.insert(narrative("sealed", entryDate: Date()), contentKey: makeKey())
        #expect(try repo.narratives(offset: 0, limit: 10, contentKey: nil).isEmpty)
    }

    @Test func insertAtomicallyWritesTheWholeBatch() throws {
        let repo = makeRepository()
        let key = makeKey()
        try repo.insertAtomically([
            narrative("a", entryDate: Date(timeIntervalSince1970: 10)),
            narrative("b", entryDate: Date(timeIntervalSince1970: 20))
        ], contentKey: key)
        #expect(try repo.narrativeCount() == 2)
        #expect(try repo.narratives(offset: 0, limit: 10, contentKey: key).map(\.text) == ["a", "b"])
    }

    /// Fail-closed: without a content key the batch is refused before a single row is written, and the
    /// divergence latch stays UNSET (a failed write is not evidence this device ever held data).
    @Test func insertAtomicallyWithNilKeyWritesNothingAndThrowsLocked() throws {
        let repo = makeRepository()
        #expect(throws: FernletLockError.self) {
            try repo.insertAtomically([narrative("never", entryDate: Date())], contentKey: nil)
        }
        #expect(try repo.narrativeCount() == 0)
        #expect(repo.hasEverStoredNarrative == false, "a failed batch must not latch divergence")
    }

    /// A mid-batch save failure rolls the WHOLE transaction back. Induced by a duplicate `id` inside
    /// one batch against a store that already holds that row: the second insert of the same identity
    /// is fine for Core Data, so the real lever is a save-time failure — modelled here by feeding the
    /// batch through a context whose store has been torn down.
    @Test func insertAtomicallyRollsBackWhenTheSaveFails() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let context = controller.container.viewContext
        let repo = JournalNarrativeRepository(context: context, defaults: isolatedLatchDefaults())
        let key = makeKey()
        try repo.insert(narrative("pre-existing", entryDate: Date(timeIntervalSince1970: 1)), contentKey: key)

        // Remove the persistent store out from under the context: the batch's inserts then fail at
        // save time, after several objects are already registered in the context.
        for store in controller.container.persistentStoreCoordinator.persistentStores {
            try controller.container.persistentStoreCoordinator.remove(store)
        }
        #expect(throws: (any Error).self) {
            try repo.insertAtomically([
                narrative("batch-1", entryDate: Date(timeIntervalSince1970: 2)),
                narrative("batch-2", entryDate: Date(timeIntervalSince1970: 3))
            ], contentKey: key)
        }
        // The rollback left no batch objects behind in the context.
        #expect(context.insertedObjects.isEmpty, "a failed atomic insert left objects in the context")
    }

    // MARK: - One-way divergence latch

    @Test func latchIsUnsetOnAFreshStoreAndSetByAnInsert() throws {
        let repo = makeRepository()
        #expect(repo.hasEverStoredNarrative == false)
        try repo.insert(narrative("first", entryDate: Date()), contentKey: makeKey())
        #expect(repo.hasEverStoredNarrative)
    }

    @Test func latchIsSetByInsertAtomically() throws {
        let repo = makeRepository()
        try repo.insertAtomically([narrative("restored", entryDate: Date())], contentKey: makeKey())
        #expect(repo.hasEverStoredNarrative, "a restore that populates the store must latch too")
    }

    /// The latch is ONE-WAY and survives emptying the store — that is the whole point. Without it an
    /// empty-because-deleted store is indistinguishable from a fresh install, and the stale cloud copy
    /// resurrects entries the user deliberately removed.
    @Test func latchSurvivesDeleteAndDeleteAll() throws {
        let repo = makeRepository()
        let key = makeKey()
        let entry = narrative("delete me", entryDate: Date())
        try repo.insert(entry, contentKey: key)
        try repo.delete(id: entry.id)
        #expect(try repo.narrativeCount() == 0)
        #expect(repo.hasEverStoredNarrative)

        try repo.insert(narrative("and again", entryDate: Date()), contentKey: key)
        try repo.deleteAll()
        #expect(try repo.narrativeCount() == 0)
        #expect(repo.hasEverStoredNarrative, "delete-all must leave the latch set — the wipe must stick")
    }

    /// The upgrade configuration: rows written before the latch shipped, read through defaults that
    /// never latched. Without the count backfill an upgrading install reads as "never populated" and
    /// the whole scheme no-ops for exactly the users with history to protect.
    @Test func latchBackfillsFromRowsWrittenBeforeItShipped() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let preLatch = JournalNarrativeRepository(context: context, defaults: isolatedLatchDefaults())
        try preLatch.insert(narrative("pre-upgrade", entryDate: Date()), contentKey: makeKey())

        let upgraded = JournalNarrativeRepository(context: context, defaults: isolatedLatchDefaults())
        #expect(upgraded.hasEverStoredNarrative, "the latch did not backfill from existing rows")
    }

    /// The one the backfill alone cannot catch: the upgrading user DELETES their pre-latch history
    /// first, so nothing ever read the latch while rows existed. The delete itself has to latch.
    @Test func deleteLatchesEvenForPreLatchRows() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let preLatch = JournalNarrativeRepository(context: context, defaults: isolatedLatchDefaults())
        let entry = narrative("pre-upgrade, then deleted", entryDate: Date())
        try preLatch.insert(entry, contentKey: makeKey())

        let upgraded = JournalNarrativeRepository(context: context, defaults: isolatedLatchDefaults())
        try upgraded.delete(id: entry.id)
        #expect(try upgraded.narrativeCount() == 0)
        #expect(upgraded.hasEverStoredNarrative, "the delete did not latch the diverged marker")
    }

    @Test func updateLatchesEvenWhenTheOriginalInsertPredatesTheLatch() throws {
        let context = PrivatePersistenceController(inMemory: true).container.viewContext
        let key = makeKey()
        let preLatch = JournalNarrativeRepository(context: context, defaults: isolatedLatchDefaults())
        let entry = narrative("pre-upgrade", entryDate: Date())
        try preLatch.insert(entry, contentKey: key)

        let upgraded = JournalNarrativeRepository(context: context, defaults: isolatedLatchDefaults())
        var edited = entry
        edited.text = "edited after the upgrade"
        try upgraded.update(edited, contentKey: key)
        #expect(upgraded.hasEverStoredNarrative)
    }

    /// Isolation: two repositories on DIFFERENT defaults suites must not see each other's latch, or the
    /// test-suite-wide bleed this injection exists to prevent comes straight back.
    @Test func latchIsIsolatedPerInjectedDefaultsSuite() throws {
        let latched = makeRepository()
        try latched.insert(narrative("latched", entryDate: Date()), contentKey: makeKey())
        #expect(latched.hasEverStoredNarrative)

        let separate = makeRepository()   // its own store AND its own suite
        #expect(separate.hasEverStoredNarrative == false)
    }

    /// A delete that matches NOTHING must not latch: it is not evidence this device ever held data.
    @Test func deletingAMissingRowDoesNotLatch() throws {
        let repo = makeRepository()
        try repo.delete(id: UUID())
        #expect(repo.hasEverStoredNarrative == false)
    }
}
