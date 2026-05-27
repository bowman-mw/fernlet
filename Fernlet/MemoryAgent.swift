import Foundation

/// Routes Tier-2 memory access for AI prompts.
///
/// Applies three layers before any `TierTwoMemoryRecord` text reaches a prompt:
/// 1. Destination allowlist — only `companion-thought` payloads receive behavioral context.
/// 2. Recency filter — records older than `recencyDays` are excluded.
/// 3. Diagnostic-language post-classifier — records containing clinical or diagnostic terms are dropped.
enum MemoryAgent {

    // MARK: - Diagnostic patterns

    /// Lowercase substrings that indicate clinical or diagnostic language.
    /// Records whose `text` or `evidence` contain any of these are excluded from all AI prompts.
    static let diagnosticPatterns: [String] = [
        "disorder", "syndrome", "diagnos", "depression", "anxiety",
        "bipolar", "adhd", "autism", "ocd", "ptsd", "trauma",
        "schizophrenia", "psychosis", "medication", "prescription",
        "therapy", "psychiatric", "clinical"
    ]

    // MARK: - Destination allowlist

    /// Only these payload kinds may receive TierTwo behavioral context.
    static let allowedPayloadKinds: Set<String> = ["companion-thought"]

    // MARK: - Public interface

    /// Returns a filtered, character-capped context string suitable for AI prompt injection.
    ///
    /// Returns an empty string if `destinedFor` is not in `allowedPayloadKinds`.
    /// Otherwise applies: recency filter → confidence filter → diagnostic-language filter → char cap.
    static func filteredContext(
        from memories: [TierTwoMemoryRecord],
        destinedFor payloadKind: String,
        recencyDays: Int = 30,
        maxChars: Int = 400
    ) -> String {
        guard allowedPayloadKinds.contains(payloadKind) else { return "" }

        let cutoff = Calendar.current.date(byAdding: .day, value: -recencyDays, to: Date()) ?? Date()
        let candidates = memories
            .filter { $0.active && $0.confidence != "low" }
            .filter { $0.extractedDate >= cutoff }
            .filter { !containsDiagnosticLanguage($0) }
            .sorted { $0.extractedDate > $1.extractedDate }

        var parts: [String] = []
        var used = 0
        for record in candidates {
            let line = record.text
            let needed = line.count + (parts.isEmpty ? 0 : 2)
            guard used + needed <= maxChars else { break }
            parts.append(line)
            used += needed
        }
        return parts.joined(separator: "; ")
    }

    // MARK: - Diagnostic classifier

    /// Returns `true` if the record's text or evidence contains clinical/diagnostic language.
    static func containsDiagnosticLanguage(_ record: TierTwoMemoryRecord) -> Bool {
        let combined = (record.text + " " + record.evidence).lowercased()
        return diagnosticPatterns.contains { combined.contains($0) }
    }
}
