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
        "suicid", "self-harm", "self harm"
    ]

    /// Returns `true` if the supplied text contains clinical/diagnostic language.
    public static func contains(_ text: String) -> Bool {
        let lowered = text.lowercased()
        return patterns.contains { lowered.contains($0) }
    }
}
