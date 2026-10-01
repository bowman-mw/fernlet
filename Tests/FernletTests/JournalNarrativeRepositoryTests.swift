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

    // MARK: - Sealed-backup surface (P3): count, paged total order, divergence latch

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

    // MARK: - One-way divergence latch

    @Test func latchIsUnsetOnAFreshStoreAndSetByAnInsert() throws {
        let repo = makeRepository()
        #expect(repo.hasEverStoredNarrative == false)
        try repo.insert(narrative("first", entryDate: Date()), contentKey: makeKey())
        #expect(repo.hasEverStoredNarrative)
    }

    @Test func latchIsSetByARestoreMerge() throws {
        let repo = makeRepository()
        _ = try repo.upsertMerged([narrative("restored", entryDate: Date())], hubKey: makeKey(), deviceKey: .absent)
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

    // MARK: - The whole-table fold (period-data design 2026-09-30, §9.17)

    /// EVERY device-key row is re-sealed under the hub key — however old, across more than one
    /// page — and rows already under the hub key are left alone. The fold this replaced re-keyed
    /// only today and the in-memory recent days, so an older entry written from Home while Private
    /// was closed stayed under the device key and never showed in the hub.
    @Test func reencryptAllFoldsEveryDeviceKeyRowAcrossPages() throws {
        let repo = makeRepository()
        let deviceKey = makeKey()
        let hubKey = makeKey()
        let old = Date(timeIntervalSince1970: 1_600_000_000)
        for index in 0..<230 {
            try repo.insert(narrative("home \(index)", dayKey: "2020-09-\(index % 28 + 1)", entryDate: old.addingTimeInterval(Double(index))), contentKey: deviceKey)
        }
        try repo.insert(narrative("already in the hub", entryDate: Date()), contentKey: hubKey)

        #expect(try repo.reencryptAll(from: deviceKey, to: hubKey) == 0)

        let underHub = try repo.openability(under: hubKey)
        #expect(underHub.openableIDs.count == 231, "every row opens under the hub key after one fold")
        #expect(underHub.deadIDs.isEmpty)
        #expect(try repo.openability(under: deviceKey).openableIDs.isEmpty, "nothing is left under the device key")
        #expect(try repo.reencryptAll(from: deviceKey, to: hubKey) == 0, "a second fold is a no-op")
        let page = try repo.narratives(offset: 0, limit: 1, contentKey: hubKey)
        #expect(page.first?.text == "home 0", "text survives the re-seal")
    }

    /// A row sealed under a key that is gone is neither folded nor deleted: the fold is a
    /// classification, never a loss.
    @Test func reencryptAllLeavesRowsUnderAnotherKeyUntouched() throws {
        let repo = makeRepository()
        let deviceKey = makeKey()
        let lostKey = makeKey()
        try repo.insert(narrative("sealed elsewhere", entryDate: Date()), contentKey: lostKey)

        #expect(try repo.reencryptAll(from: deviceKey, to: makeKey()) == 0)
        #expect(try repo.narrativeCount() == 1)
        #expect(try repo.openability(under: lostKey).openableIDs.count == 1)
    }

    // MARK: - The unopenable-entries check (period-data design 2026-09-30, §4.9)

    /// Openable, dead and (when the install binding cannot be read) undecided — never "dead" on a
    /// read that did not answer; with no key at all every row is dead.
    ///
    /// `@MainActor` so the view context's `performAndWait` runs inline in THIS task: the binding
    /// override is task-local, and a hop to the main queue from another thread would not see it.
    @MainActor
    @Test func openabilitySortsRowsIntoOpenableDeadAndUndecided() throws {
        let repo = makeRepository()
        let deviceKey = makeKey()
        let live = narrative("live", entryDate: Date())
        let dead = narrative("dead", entryDate: Date().addingTimeInterval(1))
        try repo.insert(live, contentKey: deviceKey)
        try repo.insert(dead, contentKey: makeKey())

        let classified = try repo.openability(under: deviceKey)
        #expect(classified.openableIDs == [live.id])
        #expect(classified.deadIDs == [dead.id])
        #expect(classified.transientCount == 0)

        let undecided = try DeviceBindingID.$testOverride.withValue(.readError) {
            try repo.openability(under: deviceKey)
        }
        #expect(undecided.transientCount == 2, "a binding read that did not answer decides nothing")
        #expect(undecided.deadIDs.isEmpty)

        #expect(Set(try repo.openability(under: nil).deadIDs) == [live.id, dead.id])
    }

    /// The card's removal is keyless and exact: only the named ids go, and a removal latches (it is a
    /// deletion like any other) until the latch is explicitly cleared.
    @Test func deleteByIDsRemovesExactlyThoseRowsAndLatchClearingIsExplicit() throws {
        let repo = makeRepository()
        let keep = narrative("keep", entryDate: Date())
        let drop = narrative("drop", entryDate: Date().addingTimeInterval(1))
        let key = makeKey()
        try repo.insert(keep, contentKey: key)
        try repo.insert(drop, contentKey: key)

        try repo.delete(ids: [drop.id])

        #expect(try repo.openability(under: key).openableIDs == [keep.id])
        #expect(repo.hasEverStoredNarrative)
        try repo.delete(ids: [keep.id])
        #expect(repo.hasEverStoredNarrative, "a removal is a deletion: it latches")
        repo.clearDivergenceLatch()
        #expect(!repo.hasEverStoredNarrative, "cleared once the key the rows spoke for is gone")
    }
    // MARK: - Sealed backup v2 (journal and intimacy design 2026-09-30, §7.2, §7.3; BV11, BV22)

    /// §7.2: the backup's classified read opens each entry under the hub key, else the device key; an
    /// entry neither opens is dead; one that opens with an unknown feeling tag needs a newer build
    /// (never dead); an install-binding read that did not answer, or an unreadable device key over an
    /// entry the hub key cannot open, decides nothing; a missing id was deleted since the snapshot.
    @MainActor
    @Test func theBackupReadClassifiesUnderTheHubThenTheDeviceKey() throws {
        let controller = PrivatePersistenceController(inMemory: true)
        let repo = JournalNarrativeRepository(context: controller.container.viewContext, defaults: isolatedLatchDefaults())
        let hub = makeKey()
        let device = makeKey()
        let underHub = narrative("hub", entryDate: Date(timeIntervalSince1970: 1))
        let underDevice = narrative("device", entryDate: Date(timeIntervalSince1970: 2))
        let dead = narrative("dead", entryDate: Date(timeIntervalSince1970: 3))
        let future = narrative("future tag", entryDate: Date(timeIntervalSince1970: 4))
        try repo.insert(underHub, contentKey: hub)
        try repo.insert(underDevice, contentKey: device)
        try repo.insert(dead, contentKey: makeKey())
        try repo.insert(future, contentKey: hub)
        let row = try #require(try controller.container.viewContext.fetch(NSFetchRequest<NSManagedObject>(entityName: "JournalNarrative"))
            .first { $0.value(forKey: "id") as? UUID == future.id })
        row.setValue("a-tag-from-the-future", forKey: "tag")
        try controller.container.viewContext.save()
        let ids = [underHub.id, underDevice.id, dead.id, future.id, UUID()]

        let page = try repo.backupRecords(ids: ids, hubKey: hub, deviceKey: .present(device))
        #expect(page.records.map(\.text) == ["hub", "device"])
        #expect(page.deadIDs == [dead.id])
        #expect(page.needsNewerBuildIDs == [future.id], "an unknown tag is never dead")
        #expect(page.transientCount == 0)

        let noDeviceKey = try repo.backupRecords(ids: ids, hubKey: hub, deviceKey: .absent)
        #expect(noDeviceKey.deadIDs == [underDevice.id, dead.id], "no device key: the device row is dead")
        let unreadable = try repo.backupRecords(ids: ids, hubKey: hub, deviceKey: .unreadable)
        #expect(unreadable.deadIDs.isEmpty, "an unreadable keychain decides nothing")
        #expect(unreadable.transientCount == 2)
        let binding = try DeviceBindingID.$testOverride.withValue(.readError) {
            try repo.backupRecords(ids: [underHub.id], hubKey: hub, deviceKey: .absent)
        }
        #expect(binding.transientCount == 1 && binding.records.isEmpty)
        #expect(throws: FernletLockError.self) { try repo.backupRecords(ids: ids, hubKey: nil, deviceKey: .absent) }
    }

    /// The snapshot and the skeleton read are keyless: every id in the store's total order, distinct,
    /// and the plaintext half of each entry (never its text).
    @Test func allIDsAndSkeletonsAreKeyless() throws {
        let repo = makeRepository()
        let key = makeKey()
        let second = narrative("second", dayKey: "2026-05-29", entryDate: Date(timeIntervalSince1970: 200))
        let first = narrative("first", entryDate: Date(timeIntervalSince1970: 100))
        try repo.insert(second, contentKey: key)
        try repo.insert(first, contentKey: makeKey())
        #expect(try repo.allIDs() == [first.id, second.id])
        let skeletons = try repo.skeletons(ids: [second.id, first.id, UUID()])
        #expect(skeletons == [
            JournalNarrativeSkeleton(id: second.id, dayKey: "2026-05-29", tag: .good, entryDate: second.entryDate),
            JournalNarrativeSkeleton(id: first.id, dayKey: "2026-05-28", tag: .good, entryDate: first.entryDate)
        ])
        #expect(repo.isStoreHealthy)
    }

    /// BV11 (§7.3): absent entries are inserted WITH their own stamps; an entry that opens (under the
    /// hub OR the device key) is never modified; a different text keeps the local entry and adds the
    /// backup's as a NEW entry; a dead row is replaced; nothing is ever deleted; the result names every
    /// entry that carries a backup entry's content.
    @Test func theMergeInsertsKeepsForksAndReplacesButNeverDeletes() throws {
        let repo = makeRepository()
        let hub = makeKey()
        let device = makeKey()
        let stamp = Date(timeIntervalSince1970: 1_000)
        var absent = narrative("only in the backup", entryDate: Date(timeIntervalSince1970: 10))
        absent.createdAt = stamp
        absent.updatedAt = stamp
        let same = narrative("same words", entryDate: Date(timeIntervalSince1970: 20))
        let localDiffers = narrative("this iPhone's words", entryDate: Date(timeIntervalSince1970: 30))
        var incomingDiffers = localDiffers
        incomingDiffers.text = "the backup's words"
        let deadLocal = narrative("unreadable here", entryDate: Date(timeIntervalSince1970: 40))
        var deadIncoming = deadLocal
        deadIncoming.text = "readable copy"
        let untouched = narrative("not in the backup", entryDate: Date(timeIntervalSince1970: 50))
        try repo.insert(same, contentKey: device)
        try repo.insert(localDiffers, contentKey: hub)
        try repo.insert(deadLocal, contentKey: makeKey())
        try repo.insert(untouched, contentKey: hub)

        let result = try repo.upsertMerged([absent, same, incomingDiffers, deadIncoming], hubKey: hub, deviceKey: .present(device))
        #expect(result.inserted == 1 && result.unchanged == 1 && result.forked == 1 && result.replaced == 1)
        let all = try repo.backupRecords(ids: try repo.allIDs(), hubKey: hub, deviceKey: .present(device))
        #expect(all.deadIDs.isEmpty)
        let texts = all.records.map(\.text)
        #expect(Set(texts) == ["only in the backup", "same words", "this iPhone's words", "the backup's words",
                               "readable copy", "not in the backup"])
        #expect(texts.count == 6, "nothing deleted, one fork added")
        #expect(all.records.first { $0.id == absent.id }?.updatedAt == stamp, "the backup's own stamps are kept")
        #expect(all.records.first { $0.id == localDiffers.id }?.text == "this iPhone's words", "the local entry is kept")
        let fork = try #require(all.records.first { $0.text == "the backup's words" })
        #expect(fork.id != localDiffers.id && fork.dayKey == localDiffers.dayKey)
        #expect(Set(result.followUpIDs) == [absent.id, same.id, fork.id, deadLocal.id])
    }

    /// Idempotent (§7.3): a second merge of the same set changes nothing — a fork's equal content is
    /// found on its day — yet names the same entries, so a retry rebuilds any missing skeleton.
    @Test func aSecondMergeOfTheSameSetChangesNothing() throws {
        let repo = makeRepository()
        let hub = makeKey()
        let local = narrative("mine", entryDate: Date(timeIntervalSince1970: 10))
        var theirs = local
        theirs.text = "theirs"
        let added = narrative("added", entryDate: Date(timeIntervalSince1970: 20))
        try repo.insert(local, contentKey: hub)

        let first = try repo.upsertMerged([theirs, added], hubKey: hub, deviceKey: .absent)
        #expect(first.changedCount == 2)
        let second = try repo.upsertMerged([theirs, added], hubKey: hub, deviceKey: .absent)
        #expect(second.changedAnything == false)
        #expect(Set(second.followUpIDs) == Set(first.followUpIDs))
        #expect(try repo.narrativeCount() == 3)
    }

    /// The merge throws — and saves NOTHING — on an entry it cannot decide (the install binding did not
    /// answer, or the device key could not be read) or one whose tag this build cannot read, and
    /// refuses without the hub key.
    @MainActor
    @Test func theMergeDefersOnUndecidedOrNewerEntriesAndWritesNothing() throws {
        let repo = makeRepository()
        let hub = makeKey()
        let device = makeKey()
        let underDevice = narrative("under the device key", entryDate: Date(timeIntervalSince1970: 10))
        try repo.insert(underDevice, contentKey: device)
        var incoming = underDevice
        incoming.text = "different"
        let absent = narrative("absent", entryDate: Date(timeIntervalSince1970: 20))

        #expect(throws: JournalNarrativeRepositoryError.undecidedRows(count: 1)) {
            try repo.upsertMerged([absent, incoming], hubKey: hub, deviceKey: .unreadable)
        }
        #expect(try repo.allIDs() == [underDevice.id], "nothing saved: the insert before the throw rolled back")
        #expect(throws: FernletLockError.self) { try repo.upsertMerged([absent], hubKey: nil, deviceKey: .absent) }
        #expect(throws: JournalNarrativeRepositoryError.undecidedRows(count: 1)) {
            try DeviceBindingID.$testOverride.withValue(.readError) {
                try repo.upsertMerged([incoming], hubKey: hub, deviceKey: .present(device))
            }
        }
        #expect(try repo.allIDs() == [underDevice.id])
    }

    /// Review B3 fix round 1 (R3 / D-B3-4): one entry changed on both iPhones, then "Restore it here"
    /// on each in turn — the Q9 back-and-forth — settles at exactly TWO entries on each iPhone: both
    /// versions, neither doubled. The fork phone A adds for B's words keeps the stamps of B's entry, so
    /// when it comes back to B as an absent id it is recognised as B's own entry (the same words, the
    /// same creation stamp), not inserted beside it. Further rounds change nothing.
    @Test func restoreItHereOnBothIPhonesSettlesAtTwoEntriesEach() throws {
        let phoneA = makeRepository()
        let phoneB = makeRepository()
        let keyA = makeKey()
        let keyB = makeKey()
        // The same id on both (the same-id typing path with sync on): each iPhone's own words and stamps.
        let id = UUID()
        try phoneA.insert(narrative("A's words", entryDate: Date(timeIntervalSince1970: 100), id: id), contentKey: keyA)
        try phoneB.insert(narrative("B's words", entryDate: Date(timeIntervalSince1970: 200), id: id), contentKey: keyB)
        func backup(_ repo: JournalNarrativeRepository, _ key: SymmetricKey) throws -> [JournalNarrative] {
            try repo.backupRecords(ids: try repo.allIDs(), hubKey: key, deviceKey: .absent).records
        }
        func texts(_ repo: JournalNarrativeRepository, _ key: SymmetricKey) throws -> [String] {
            try backup(repo, key).map(\.text).sorted()
        }

        _ = try phoneA.upsertMerged(try backup(phoneB, keyB), hubKey: keyA, deviceKey: .absent)
        #expect(try texts(phoneA, keyA) == ["A's words", "B's words"], "A keeps its own and adds B's")
        let atB = try phoneB.upsertMerged(try backup(phoneA, keyA), hubKey: keyB, deviceKey: .absent)
        #expect(try texts(phoneB, keyB) == ["A's words", "B's words"], "B's own entry is not doubled")
        #expect(atB.inserted == 0 && atB.forked == 1 && atB.unchanged == 1)
        #expect(atB.followUpIDs.contains(id), "B's own entry stands for the copy that came back")

        for _ in 0..<2 {
            let again = try phoneA.upsertMerged(try backup(phoneB, keyB), hubKey: keyA, deviceKey: .absent)
            #expect(!again.changedAnything)
            #expect(!(try phoneB.upsertMerged(try backup(phoneA, keyA), hubKey: keyB, deviceKey: .absent)).changedAnything)
        }
        #expect(try phoneA.narrativeCount() == 2 && phoneB.narrativeCount() == 2)
    }

    /// The copy rule never swallows a real entry: an absent backup entry with the same words as a local
    /// one on its day, but written at another moment (another creation stamp), is a different entry and
    /// is inserted. One with the same words AND stamp — what the other iPhone kept of this iPhone's
    /// entry after deleting its own version of the pair — stands as that entry and adds nothing.
    @Test func anAbsentEntryWithTheSameWordsWrittenAtAnotherMomentIsKept() throws {
        let repo = makeRepository()
        let hub = makeKey()
        let local = narrative("Feeling tired", entryDate: Date(timeIntervalSince1970: 100))
        try repo.insert(local, contentKey: hub)
        let laterSameWords = narrative("Feeling tired", entryDate: Date(timeIntervalSince1970: 900))
        var copyOfLocal = local
        copyOfLocal.id = UUID()

        let result = try repo.upsertMerged([laterSameWords, copyOfLocal], hubKey: hub, deviceKey: .absent)
        #expect(result.inserted == 1 && result.unchanged == 1)
        #expect(Set(try repo.allIDs()) == [local.id, laterSameWords.id], "the later entry kept, the copy recognised")
        #expect(Set(result.followUpIDs) == [local.id, laterSameWords.id])
    }
}
