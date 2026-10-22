// DiagnosticLanguage.swift
// SPM carve-up: pure diagnostic-language post-classifier (spec §8).
//
// Lives in the domain layer so domain value types (e.g. `JournalMemorySummaryPolicy`, which
// screens an AI journal summary before it may become Core Memory text) can screen proposed
// memories WITHOUT depending on the app-layer `MemoryAgent`.
// `MemoryAgent` (app target) forwards to this classifier for its public API.

import Foundation

/// Best-effort keyword screen for clinical/diagnostic language in text bound for AI prompts or
/// stored memories (spec §8).
///
/// Lives in the domain layer so value types (``JournalMemorySummaryPolicy``, the gate an AI journal
/// summary passes before it may become a ``MemoryNote``'s text) can screen proposed memories without
/// depending on the app-layer `MemoryAgent`, which forwards its public API here.
/// See `contains(_:)` for why this is defense-in-depth, never a hard privacy boundary.
public nonisolated enum DiagnosticLanguage {

    /// Lowercase substrings that indicate clinical or diagnostic language.
    /// Text containing any of these is treated as diagnostic and excluded from
    /// AI prompts / silently rejected at memory-storage time.
    ///
    /// Covers every term of spec §8's `DIAGNOSTIC_PATTERNS` ("depressed, anxious, ADHD, bipolar,
    /// traumatized, burned out, codependent, avoidant, OCD, PTSD, insomnia, panic disorder, eating
    /// disorder, manic, dissociation, narcissism") as a stem — "traumatized" through "trauma", both
    /// disorders through "disorder" — except "manic", which is in ``wholeWordPatterns`` because as a
    /// substring it is inside ordinary words ("manicure", "Germanic"). Each of the spec's other stems
    /// appears in no ordinary word outside its own family (unlike the cycle-privacy entries "period"
    /// and "cycle", which over-match on purpose); "burned out" and "burnt out" are listed in their
    /// normalized, separator-free form.
    nonisolated public static let patterns: [String] = [
        "disorder", "syndrome", "diagnos", "depression", "anxiety",
        "bipolar", "adhd", "autism", "ocd", "ptsd", "trauma",
        "schizophrenia", "psychosis", "medication", "prescription",
        "therapy", "psychiatric", "clinical",
        "period", "cycle", "pregnan", "miscarriage",
        "intimacy", "libido",
        "suicid", "self-harm",
        "depress", "anxious", "burnedout", "burntout", "codependen", "avoidant",
        "insomnia", "dissociat", "narcissis"
    ]

    /// Lowercase words matched only as a whole word — a run of letters and digits bounded by
    /// anything else — because as substrings they sit inside ordinary words ("manic" in "manicure",
    /// "Germanic", and across a dropped space in "woman icon"). The trade is deliberate: a whole
    /// word is not caught when spelled with separators inside it, which ``patterns`` would catch.
    nonisolated public static let wholeWordPatterns: Set<String> = ["manic"]

    /// ``patterns`` plus every ``LanguagePack``'s clinical stems, pre-normalized once (they are
    /// compile-time constants), so `contains` only has to normalize the varying input text per call —
    /// not every pattern.
    ///
    /// Every language's terms apply to every text, whatever the interface language (localization plan
    /// §5.4): the privacy policy says clinical language is filtered, and a person can journal in
    /// Spanish in an English app. `patterns` itself stays the English list.
    private nonisolated static let normalizedPatterns: [String] =
        (patterns + LanguagePack.all.flatMap(\.clinicalStems)).map(normalize)

    /// ``wholeWordPatterns`` plus every ``LanguagePack``'s clinical whole words ("toc", "tdah",
    /// "regla"), as one set.
    private nonisolated static let allWholeWordPatterns: Set<String> =
        wholeWordPatterns.union(LanguagePack.all.flatMap(\.clinicalWholeWords))

    /// Returns `true` if the supplied text contains clinical/diagnostic language.
    ///
    /// IMPORTANT — this is **best-effort defense-in-depth, not a guarantee.** A keyword screen can
    /// always be evaded (synonyms, novel phrasing, a language without a ``LanguagePack``) and intentionally
    /// over-matches (e.g. "period of time", "bicycle") because a silent over-reject is fail-safe for a
    /// privacy gate. The load-bearing guarantees elsewhere are: on-device inference (Apple Foundation
    /// Models — a bypass never causes network egress), the typed `AIContextPayload` allowlist (only the
    /// declared fields can reach a prompt), and the `S3BoundaryTests` grep-wall. Do not treat this
    /// classifier as a hard boundary.
    ///
    /// Matching normalizes BOTH the input and each pattern down to lowercase, diacritic-folded
    /// alphanumerics before the substring test ("depresión" reads "depresion"), so trivial separator-injection evasions ("d e p r e s s i o n", "self.harm",
    /// "self_harm", "selfharm", "p.t.s.d", "bi-polar") are still caught. Normalization can only widen
    /// coverage; it never lets a previously-caught term slip through. (It can occasionally manufacture a
    /// false positive when stripping spaces fuses short tokens — e.g. "taco cdr" → contains "ocd" — which
    /// for a silent-reject gate is acceptable.) ``wholeWordPatterns`` are then matched against the
    /// text's words instead, because a substring match would reject ordinary words.
    public static func contains(_ text: String) -> Bool {
        let normalizedText = normalize(text)
        if normalizedPatterns.contains(where: { normalizedText.contains($0) }) { return true }
        return containsWholeWord(text)
    }

    /// Whether any whole-word pattern (``wholeWordPatterns`` and every pack's) is one of `text`'s
    /// words (folded, split on every character that is not a letter or digit).
    private static func containsWholeWord(_ text: String) -> Bool {
        let words = folded(text).split { !($0.isLetter || $0.isNumber) }
        return words.contains { allWholeWordPatterns.contains(String($0)) }
    }

    /// Folded (lowercase, diacritics dropped, the locale-independent rules) and stripped of every
    /// non-alphanumeric character (whitespace, punctuation, separators). The diacritic fold is what
    /// lets an unaccented stem catch an accented word; like every other step it only widens coverage.
    private static func normalize(_ value: String) -> String {
        String(folded(value).unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    /// Lowercase and diacritic-folded with `locale: nil`, so the screen reads the same on every device.
    private static func folded(_ value: String) -> String {
        value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil).lowercased()
    }
}
