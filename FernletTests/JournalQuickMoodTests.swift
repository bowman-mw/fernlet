import CryptoKit
import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletScoring
import PrivateMemoryStore
@testable import FernletPersistence
@testable import Fernlet

/// Batch C: one-tap mood check-ins — tag-only journal entries (empty text + FeelingTag) — plus the
/// static journal-prompt library. Pins: the tag-only entry flows through the "last entry's tag"
/// consumers unchanged; empty text is never sealed (and stays unambiguous vs stripped sealed
/// entries); repeated taps update in place only when identifiable; a later real journal simply
/// appends and wins (same-day semantics); a mood entry gaining text through an edit gets sealed;
/// and the prompt rotation is a pure, deterministic function of the dateKey.
@MainActor
struct JournalQuickMoodTests {

    private let testDate = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func quickMoodCreatesTagOnlyEntryThatScoringReads() throws {
        let store = makeTestStore(date: testDate)
        store.logQuickMood(.bright)

        #expect(store.day.journals.count == 1)
        let entry = try #require(store.day.journals.first)
        #expect(entry.text.isEmpty)
        #expect(entry.tag == .bright)
        // The exact read every mood consumer performs (score, calendar tint, ambient thought).
        #expect(store.day.journals.last?.tag == .bright)
        // No tier-1 memory is minted from an empty check-in.
        #expect(store.memories.isEmpty)
        // The scored journal component reflects the tag (a bright check-in scores above neutral-less).
        #expect(store.scoreBreakdown(for: store.day).components["journal"] ?? 0 > 0)
    }

    @Test func quickMoodUpdatesInPlaceWhenTagOnlyEntryIsIdentifiable() {
        let store = makeTestStore(date: testDate)
        store.activateNoLockJournals()   // journal key active → tag-only entries are identifiable
        store.logQuickMood(.good)
        store.logQuickMood(.tired)       // changed my mind — same entry, new tag

        #expect(store.day.journals.count == 1)
        #expect(store.day.journals.last?.tag == .tired)
        #expect(store.previousJournals.first?.tag == .tired)
    }

    @Test func quickMoodAppendsWhenSealedStateIsAmbiguous() {
        // No activation (inactive/locked): an empty-text entry could be a stripped sealed entry,
        // so the check-in must append rather than risk retagging a real journal.
        let store = makeTestStore(date: testDate)
        store.logQuickMood(.good)
        store.logQuickMood(.tired)
        #expect(store.day.journals.count == 2)
        #expect(store.day.journals.last?.tag == .tired)
    }

    @Test func realJournalAfterQuickMoodAppendsAndWins() {
        let store = makeTestStore(date: testDate)
        store.activateNoLockJournals()
        store.logQuickMood(.quiet)
        store.addJournal(text: "wrote a real entry about the day", tag: .good)

        // Same-day merge = the existing entry-list semantics: both entries live on the day and the
        // LAST entry's tag is the day's mood everywhere (score, tint, ambient thought).
        #expect(store.day.journals.count == 2)
        #expect(store.day.journals.last?.tag == .good)
        // The mood check-in itself was not disturbed.
        #expect(store.day.journals.first?.text.isEmpty == true)
        #expect(store.day.journals.first?.tag == .quiet)
    }

    @Test func tagOnlyEntryIsNeverSealedAndGainsSealingWithFirstText() throws {
        let recorder = RecordingNarrativeStore()
        let (store, repository, _) = makeTestStoreWithRepositories(date: testDate) { real in
            recorder.wrapped = real
            return recorder
        }
        store.activateNoLockJournals()
        store.logQuickMood(.neutral)

        // Empty text is deliberately not sealed: no narrative row, not in the sealed-id set.
        #expect(recorder.insertedIDs.isEmpty)
        store.flushPendingSnapshotSave()
        let persisted = repository.loadSnapshot(todayKey: store.todayKey)
        let persistedEntry = try #require(persisted.day.journals.first)
        #expect(persistedEntry.text.isEmpty)
        #expect(persistedEntry.tag == .neutral)

        // The check-in later gains real text through the normal edit flow: it must be sealed fresh
        // (and stripped from the synced blob) exactly like any other journal entry.
        let entry = try #require(store.day.journals.first)
        store.updateJournal(entry, text: "actually, here is what happened", tag: .neutral, date: store.todayKey)
        #expect(recorder.insertedIDs == [entry.id])
        #expect(store.day.journals.first?.text == "actually, here is what happened")
        store.flushPendingSnapshotSave()
        let resealed = repository.loadSnapshot(todayKey: store.todayKey)
        #expect(resealed.day.journals.first?.text.isEmpty == true)   // stripped from the blob
    }

    @Test func calendarTintReadsTagOnlyEntries() throws {
        var day = FernletDay(date: "2026-05-14")
        day.journals = [JournalEntry(text: "", tag: .quiet)]
        let model = JournalMonthModel(
            date: Date(timeIntervalSince1970: 1_778_000_000),  // within 2026-05
            allDays: ["2026-05-14": day],
            todayKey: "2026-06-03"
        )
        let cell = try #require(model.cells.first { $0.dateKey == "2026-05-14" })
        #expect(cell.tag == .quiet)
        #expect(cell.hasData)
    }

    // MARK: - Prompt library

    @Test func promptRotationIsDeterministicPerDayKey() {
        #expect(JournalPromptLibrary.prompts.count >= 40)
        #expect(JournalPromptLibrary.prompts.allSatisfy { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
        // Same day → same prompt, every time (and on every device — pure function of the dateKey).
        #expect(JournalPromptLibrary.prompt(for: "2026-07-05") == JournalPromptLibrary.prompt(for: "2026-07-05"))
        #expect(JournalPromptLibrary.stableSeed("2026-07-05") == JournalPromptLibrary.stableSeed("2026-07-05"))
        // The rotation actually rotates: a month of days reaches a healthy variety of prompts.
        let july = (1...31).map { JournalPromptLibrary.prompt(for: String(format: "2026-07-%02d", $0)) }
        #expect(Set(july).count > 5)
    }
}

/// Interposes on the sealed narrative store to observe which entry ids get sealed (plaintext is
/// visible here because the decorator sits above the encryption boundary — test-only).
private final class RecordingNarrativeStore: JournalNarrativeStoring {
    var wrapped: JournalNarrativeRepository!
    private(set) var insertedIDs: [UUID] = []

    func insert(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        insertedIDs.append(narrative.id)
        try wrapped.insert(narrative, contentKey: contentKey)
    }
    func update(_ narrative: JournalNarrative, contentKey: SymmetricKey?) throws {
        try wrapped.update(narrative, contentKey: contentKey)
    }
    func delete(id: UUID) throws {
        try wrapped.delete(id: id)
    }
    func narratives(forDayKey dayKey: String, contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        try wrapped.narratives(forDayKey: dayKey, contentKey: contentKey)
    }
    func narratives(forDayKeys dayKeys: [String], contentKey: SymmetricKey?) throws -> [JournalNarrative] {
        try wrapped.narratives(forDayKeys: dayKeys, contentKey: contentKey)
    }
}
