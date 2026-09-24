// JournalMemoryCapture.swift
// Core Memory's journal capture — owner decision 2026-09-23: "a journal entry should be summarized
// not copied to core memory. If ai is turned off, no journal text should be saved to core memory.
// The 'emotion' can be saved to core memory."
//
// Core Memory rides the aggregate blob, which CloudKit mirrors whenever iCloud sync is on and which
// carries no field encryption. Journal TEXT is sealed out of that blob everywhere else, so a memory
// that quoted the entry was the one road the words still had into iCloud. Two rules close it, and
// both live here, in the domain layer, so every writer (the app store and the walled AI stage alike)
// judges by the same code:
//
//   * ``MemoryNote/emotionOnly(for:)`` — the memory a journal entry mints: its `FeelingTag` TOKEN as
//     the category and no text at all. With AI off, unavailable, over budget, failed or filtered,
//     this is the whole memory.
//   * ``JournalMemorySummaryPolicy`` — the test an on-device AI summary must pass before it may
//     become that memory's text: bounded, free of diagnostic language, and not a copy of the entry
//     (not verbatim, not a prefix, not an excerpt).
//
// Human-readable text for an emotion-only memory is built at DISPLAY time in the app target (the
// localization wall: a token never localizes, and a stored sentence would be frozen in one language).

import Foundation

public extension MemoryNote {
    /// The trimmed length a journal entry needs before it leaves a Core Memory at all — a written
    /// reflection rather than a mood tap (a quick check-in has empty text and never reaches it).
    ///
    /// Carried over unchanged from the excerpt era, so "which entries leave a memory" did not move
    /// when "what the memory holds" did.
    static let journalMemoryMinimumCharacters = 20

    /// The emotion-only Core Memory for `entry`: the entry's ``FeelingTag`` as the frozen `category`
    /// token and an EMPTY `text` — never the entry's words, a prefix of them, or an excerpt.
    ///
    /// Returns `nil` for an entry under ``journalMemoryMinimumCharacters`` (a quick mood check-in, a
    /// one-word note). The entry's text is read for its LENGTH only; nothing of it is stored.
    ///
    /// No diagnostic-language screen runs here because nothing is proposed for storage but the tag
    /// token: the screen belongs to text, and it runs on an AI summary in
    /// ``JournalMemorySummaryPolicy/accepted(_:entryText:)`` before that text may replace the empty one.
    static func emotionOnly(for entry: JournalEntry) -> MemoryNote? {
        let trimmed = entry.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= journalMemoryMinimumCharacters else { return nil }
        return MemoryNote(category: entry.tag.rawValue, text: "", sourceDate: entry.date)
    }

    /// The feeling an emotion-only memory records: its `category` read back as a ``FeelingTag`` —
    /// `nil` once the memory has text of its own (an AI summary, or words the user typed in the
    /// editor), or when the category is not a feeling this build knows.
    ///
    /// The display layer turns this into a sentence at render time; it is never stored as one.
    var emotionOnlyFeeling: FeelingTag? {
        guard text.isEmpty else { return nil }
        return FeelingTag(rawValue: category)
    }
}

/// The acceptance test an AI-written journal summary must pass before it may become the text of a
/// Core Memory (owner decision 2026-09-23: a journal entry is summarized, never copied).
///
/// Applied twice on purpose — by `AIProviders`' on-device summary stage, so the AI audit log records
/// a rejected reply as a fallback rather than a success, and again by the app store at the moment it
/// writes the memory, so a provider that skipped the check (a future rung, a test fake) still cannot
/// land text the policy would refuse. A rejected summary is dropped, never repaired: the memory keeps
/// its emotion only, which is the privacy-safe state.
///
/// A caseless enum of pure, nonisolated functions — no state, safe from any isolation domain.
public nonisolated enum JournalMemorySummaryPolicy {
    /// The longest summary kept, in characters. A reply over it is rejected, not truncated: half a
    /// sentence in the memory list reads as a bug, and the emotion-only memory reads as the app.
    public static let maxCharacters = 140

    /// A summary sharing a run of this many consecutive words with the entry is an EXCERPT with a
    /// few words of its own around it, not a summary.
    public static let excerptWordRun = 5

    /// Returns the summary a memory may store — trimmed, collapsed to one line, and unwrapped from
    /// any quotation marks — or `nil` when the candidate is empty, has no words, runs past
    /// ``maxCharacters``, uses diagnostic language (``DiagnosticLanguage``), or reproduces `entryText`
    /// (see ``reproduces(_:in:)``).
    ///
    /// - Parameters:
    ///   - candidate: The model's raw reply.
    ///   - entryText: The FULL journal entry the reply summarizes — checked in full, not the prompt's
    ///     truncated copy, so a long entry cannot hide a copied tail.
    public static func accepted(_ candidate: String, entryText: String) -> String? {
        let summary = collapsedToOneLine(candidate)
        guard !summary.isEmpty, summary.count <= maxCharacters else { return nil }
        guard !words(in: summary).isEmpty else { return nil }
        guard !DiagnosticLanguage.contains(summary) else { return nil }
        guard !reproduces(entryText, in: summary) else { return nil }
        return summary
    }

    /// Whether `summary` reproduces `entryText` instead of summarizing it.
    ///
    /// Compared over case- and diacritic-folded words with punctuation dropped, so trivial
    /// re-punctuation does not launder a copy. Two shapes count:
    /// 1. the WHOLE summary appears as consecutive words of the entry — the verbatim case, the
    ///    prefix case, and a bare excerpt of any length;
    /// 2. any run of ``excerptWordRun`` consecutive summary words appears in the entry — an excerpt
    ///    padded with words of the summary's own.
    public static func reproduces(_ entryText: String, in summary: String) -> Bool {
        let summaryWords = words(in: summary)
        let entryWords = words(in: entryText)
        guard !summaryWords.isEmpty, !entryWords.isEmpty else { return false }
        // Space-delimited on both ends, so a match is always at word boundaries ("art" never
        // matches inside "start").
        let entryLine = " " + entryWords.joined(separator: " ") + " "
        if entryLine.contains(" " + summaryWords.joined(separator: " ") + " ") { return true }
        guard summaryWords.count > excerptWordRun else { return false }
        // R2: bounded by the summary's word count, itself bounded by `maxCharacters` on the
        // accepted path.
        for start in 0...(summaryWords.count - excerptWordRun) {
            let run = summaryWords[start..<(start + excerptWordRun)].joined(separator: " ")
            if entryLine.contains(" " + run + " ") { return true }
        }
        return false
    }

    /// The comparison form of `text`: case-, diacritic- and width-folded (locale-independent — this
    /// is a matching input, never display), split on everything that is not a letter or a digit.
    static func words(in text: String) -> [String] {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        return folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// `text` on one line: every run of whitespace or line breaks becomes one space, and the ends
    /// lose whitespace and wrapping quotation marks.
    static func collapsedToOneLine(_ text: String) -> String {
        let pieces = text.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        let joined = pieces.joined(separator: " ")
        let wrappers = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"'“”‘’"))
        return joined.trimmingCharacters(in: wrappers)
    }
}
