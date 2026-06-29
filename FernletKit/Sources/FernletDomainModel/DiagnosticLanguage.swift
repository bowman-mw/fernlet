// DiagnosticLanguage.swift
// SPM carve-up: pure diagnostic-language post-classifier (spec §8).
//
// Lives in the domain layer so domain value types (e.g. `MemoryNote.fromJournal`)
// can screen proposed memories WITHOUT depending on the app-layer `MemoryAgent`.
// `MemoryAgent` (app target) forwards to this classifier for its public API.

import Foundation

public nonisolated enum DiagnosticLanguage {

    /// Lowercase substrings that indicate clinical or diagnostic language.
    /// Text containing any of these is treated as diagnostic and excluded from
    /// AI prompts / silently rejected at memory-storage time.
    nonisolated public static let patterns: [String] = [
        "disorder", "syndrome", "diagnos", "depression", "anxiety",
        "bipolar", "adhd", "autism", "ocd", "ptsd", "trauma",
        "schizophrenia", "psychosis", "medication", "prescription",
        "therapy", "psychiatric", "clinical",
        "period", "cycle", "pregnan", "miscarriage",
        "intimacy", "libido",
        "suicid", "self-harm"
    ]

    /// `patterns` pre-normalized once (they are compile-time constants), so `contains`
    /// only has to normalize the varying input text per call — not every pattern.
    private nonisolated static let normalizedPatterns: [String] = patterns.map(normalize)

    /// Returns `true` if the supplied text contains clinical/diagnostic language.
    ///
    /// IMPORTANT — this is **best-effort defense-in-depth, not a guarantee.** A keyword screen can
    /// always be evaded (synonyms, novel phrasing, foreign-language terms) and intentionally
    /// over-matches (e.g. "period of time", "bicycle") because a silent over-reject is fail-safe for a
    /// privacy gate. The load-bearing guarantees elsewhere are: on-device inference (Apple Foundation
    /// Models — a bypass never causes network egress), the typed `AIContextPayload` allowlist (only the
    /// declared fields can reach a prompt), and the `S3BoundaryTests` grep-wall. Do not treat this
    /// classifier as a hard boundary.
    ///
    /// Matching normalizes BOTH the input and each pattern down to lowercase alphanumerics before the
    /// substring test, so trivial separator-injection evasions ("d e p r e s s i o n", "self.harm",
    /// "self_harm", "selfharm", "p.t.s.d", "bi-polar") are still caught. Normalization can only widen
    /// coverage; it never lets a previously-caught term slip through. (It can occasionally manufacture a
    /// false positive when stripping spaces fuses short tokens — e.g. "taco cdr" → contains "ocd" — which
    /// for a silent-reject gate is acceptable.)
    public static func contains(_ text: String) -> Bool {
        let normalizedText = normalize(text)
        return normalizedPatterns.contains { normalizedText.contains($0) }
    }

    /// Lowercase + drop every non-alphanumeric character (whitespace, punctuation, separators).
    private static func normalize(_ value: String) -> String {
        String(value.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }
}
