import Foundation
import Testing
import FernletDomainModel
import AIContext
@testable import Fernlet

/// Spec §8: the diagnostic-language post-classifier must run on every proposed memory
/// *before* storage, not only at AI-prompt read-time. These tests pin the storage-time gate.
@Suite struct MemoryStorageScreeningTests {

    // MARK: - String classifier

    @Test func stringClassifierFlagsDiagnosticText() {
        #expect(MemoryAgent.containsDiagnosticLanguage("I'm dealing with depression lately"))
        #expect(MemoryAgent.containsDiagnosticLanguage("started a new medication"))
        #expect(MemoryAgent.containsDiagnosticLanguage("notes about my cycle"))
    }

    @Test func stringClassifierPassesCleanText() {
        #expect(!MemoryAgent.containsDiagnosticLanguage("had a great workout and felt strong"))
        #expect(!MemoryAgent.containsDiagnosticLanguage("cooked a nice dinner with friends"))
    }

    // MARK: - Normalization defeats trivial separator-injection evasions

    @Test func classifierCatchesSpacingAndPunctuationEvasions() {
        // Intra-word spacing / punctuation that the old plain-substring match let through.
        #expect(DiagnosticLanguage.contains("d e p r e s s i o n"))
        #expect(DiagnosticLanguage.contains("anxie.ty"))
        #expect(DiagnosticLanguage.contains("bi-polar"))
        #expect(DiagnosticLanguage.contains("p.t.s.d"))
        // The self-harm pair is the leakiest term — every separator variant must still match.
        #expect(DiagnosticLanguage.contains("self harm"))
        #expect(DiagnosticLanguage.contains("self-harm"))
        #expect(DiagnosticLanguage.contains("self_harm"))
        #expect(DiagnosticLanguage.contains("self  harm"))
        #expect(DiagnosticLanguage.contains("selfharm"))
    }

    @Test func classifierStillPassesCleanTextUnderNormalization() {
        // Stripping separators must not manufacture a banned token from these clean phrases.
        #expect(!DiagnosticLanguage.contains("Works out 3x per week on average"))
        #expect(!DiagnosticLanguage.contains("Tends to walk daily"))
        #expect(!DiagnosticLanguage.contains("Felt really proud finishing the long walk by the river today"))
    }

    // MARK: - Tier-1 (journal-derived) memory at creation — owner decision 2026-09-23
    //
    // These two pinned the old `MemoryNote.fromJournal`, which stored a 120-character EXCERPT of the
    // entry (rejecting one that held clinical language). A journal entry now mints an EMOTION-ONLY
    // memory — no text to screen at all — and the screen moved to the AI summary that may replace
    // it (`JournalMemorySummaryPolicy`, pinned in JournalMemoryCaptureTests).

    /// The entry that used to be rejected for its clinical language now leaves only its feeling:
    /// nothing of the words is proposed for storage, so there is nothing for the screen to catch.
    @Test func journalMemoryForAnEntryWithClinicalLanguageKeepsOnlyTheFeeling() throws {
        let note = try #require(MemoryNote.emotionOnly(for: JournalEntry(
            text: "I think I have anxiety and should probably start therapy soon",
            tag: .hard
        )))
        #expect(note.text.isEmpty)
        #expect(note.category == FeelingTag.hard.rawValue)
        #expect(!MemoryAgent.containsDiagnosticLanguage(note.text + " " + note.category))
    }

    @Test func journalMemoryForACleanReflectionKeepsOnlyTheFeeling() throws {
        let note = try #require(MemoryNote.emotionOnly(for: JournalEntry(
            text: "Felt really proud finishing the long walk by the river today",
            tag: .bright
        )))
        #expect(note.category == FeelingTag.bright.rawValue)
        #expect(note.text.isEmpty, "Core Memory must never hold the entry's words")
    }

    /// The storage-time screen still runs — on the AI summary, before it may become memory text.
    @Test func aiJournalSummaryWithDiagnosticLanguageIsRejectedBeforeStorage() {
        #expect(JournalMemorySummaryPolicy.accepted(
            "Worried the anxiety is back and thinking about therapy",
            entryText: "A long day at work. I could not settle down all evening."
        ) == nil)
        #expect(JournalMemorySummaryPolicy.accepted(
            "An unsettled evening after a long workday",
            entryText: "A long day at work. I could not settle down all evening."
        ) == "An unsettled evening after a long workday")
    }
}
