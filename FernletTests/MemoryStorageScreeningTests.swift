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

    // MARK: - Tier-1 (journal-derived) memory rejection at creation

    @Test func fromJournalRejectsDiagnosticLanguage() {
        let note = MemoryNote.fromJournal(
            text: "I think I have anxiety and should probably start therapy soon",
            tag: .hard
        )
        #expect(note == nil)
    }

    @Test func fromJournalAllowsCleanReflection() {
        let note = MemoryNote.fromJournal(
            text: "Felt really proud finishing the long walk by the river today",
            tag: .bright
        )
        #expect(note != nil)
        #expect(note?.category == FeelingTag.bright.rawValue)
    }
}
