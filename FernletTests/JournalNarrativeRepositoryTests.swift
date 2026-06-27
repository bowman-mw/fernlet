import CoreData
import CryptoKit
import Testing
import FernletDomainModel
import FernletFoundation
import PrivateStoreCore
@testable import Fernlet

@Suite(.serialized)
struct JournalNarrativeRepositoryTests {

    private func makeRepository() -> JournalNarrativeRepository {
        JournalNarrativeRepository(context: PrivatePersistenceController(inMemory: true).container.viewContext)
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
        let journalKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: contentKey, info: Data("journal-narrative".utf8), outputByteCount: 32
        )
        let menstrualKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: contentKey, info: Data("menstrual-narrative".utf8), outputByteCount: 32
        )
        #expect(journalKey != menstrualKey)
    }
}
