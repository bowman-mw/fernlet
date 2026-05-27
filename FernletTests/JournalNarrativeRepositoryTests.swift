import CoreData
import CryptoKit
import Testing
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

    @Test func wrongKeyThrowsOnDecrypt() throws {
        let repo = makeRepository()
        let key = makeKey()
        let wrongKey = makeKey()
        let narrative = JournalNarrative(
            id: UUID(), dayKey: "2026-05-28", tag: .hard, entryDate: Date(),
            text: "Secret.", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        try repo.insert(narrative, contentKey: key)

        #expect(throws: (any Error).self) {
            try repo.narratives(forDayKey: "2026-05-28", contentKey: wrongKey)
        }
    }

    @Test func insertWithNilKeyThrowsLocked() throws {
        let repo = makeRepository()
        let narrative = JournalNarrative(
            id: UUID(), dayKey: "2026-05-28", tag: .good, entryDate: Date(),
            text: "Locked.", emotions: [], createdAt: Date(), updatedAt: Date()
        )
        #expect(throws: FernletLockError.locked) {
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
