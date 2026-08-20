import Foundation
import FernletDomainModel

/// Routes Tier-2 memory access for AI prompts — the memory gatekeeper.
///
/// Applies three layers before any `TierTwoMemoryRecord` text reaches a prompt:
/// 1. Destination allowlist — only `companion-thought` payloads receive behavioral context
///    (everything else gets an empty string; fail-closed).
/// 2. Recency filter — records older than `recencyDays` are excluded (inactive and low-confidence
///    records are dropped alongside).
/// 3. Diagnostic-language post-classifier — records containing clinical or diagnostic terms are dropped.
///
/// The app builds ``CompanionThoughtPayload/filteredMemorySummary`` exclusively through
/// ``filteredContext(from:destinedFor:recencyDays:maxChars:)``, and the storage side reuses
/// `containsDiagnosticLanguage(_:)` to screen every proposed memory before it is
/// persisted (spec §8). Deliberately placed in `AIContext`, NOT `PrivateMemoryStore`: it is pure,
/// AI-facing control plane that every provider calls, and homing it in a sealed module would have
/// been an `AIProviders` → `Private*` wall violation. A caseless enum of static pure functions — no
/// state, no isolation concerns.
public enum MemoryAgent {

    // MARK: - Destination allowlist

    /// Only these payload kinds may receive TierTwo behavioral context.
    ///
    /// **DO NOT LOCALIZE — frozen English tokens, matched by exact string equality.** These are
    /// `AIContextPayload.payloadKind` values (see `AIContextPayload.swift`), not labels: nothing
    /// ever renders them. `filteredContext` compares the caller's `payloadKind` against this Set
    /// with `contains`, so a translated literal here — or in any `payloadKind` declaration — stops
    /// matching, and the guard falls through to the fail-closed `return ""`.
    ///
    /// That failure is completely silent. It does not throw, it does not log, it does not degrade
    /// the prompt visibly: the companion thought is still generated, just permanently stripped of
    /// every behavioral memory the user's history had earned. The only symptom is a user reporting
    /// that the companion "got worse" after switching languages, with no error anywhere to explain
    /// it. Fail-closed is the right default for a privacy gate; a localized key turns it into an
    /// undetectable one.
    public static let allowedPayloadKinds: Set<String> = ["companion-thought"]

    // MARK: - Public interface

    /// Returns a filtered, character-capped context string suitable for AI prompt injection.
    ///
    /// Returns an empty string if `destinedFor` is not in `allowedPayloadKinds`.
    /// Otherwise applies: recency filter → confidence filter → diagnostic-language filter → char cap.
    public static func filteredContext(
        from memories: [TierTwoMemoryRecord],
        destinedFor payloadKind: String,
        recencyDays: Int = 30,
        maxChars: Int = 400
    ) -> String {
        // Exact string equality against frozen English tokens — see ``allowedPayloadKinds``. This
        // is the fail-closed half of the privacy gate: a mismatch returns "" silently, so a
        // localized `payloadKind` anywhere would strip behavioral memory with no error to trace.
        guard allowedPayloadKinds.contains(payloadKind) else { return "" }

        let cutoff = Calendar.current.date(byAdding: .day, value: -recencyDays, to: Date()) ?? Date()
        // `confidence` is likewise a frozen token ("low"/"medium"/"high"), never display copy: the
        // comparison below is what keeps low-confidence inferences out of the prompt.
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

    /// Returns `true` if the supplied text contains clinical/diagnostic language.
    ///
    /// Used both at read-time (before AI prompt injection) and at storage-time
    /// (every proposed memory is screened before it is persisted — spec §8).
    public static func containsDiagnosticLanguage(_ text: String) -> Bool {
        DiagnosticLanguage.contains(text)
    }

    /// Returns `true` if the record's text or evidence contains clinical/diagnostic language.
    public static func containsDiagnosticLanguage(_ record: TierTwoMemoryRecord) -> Bool {
        containsDiagnosticLanguage(record.text + " " + record.evidence)
    }
}
