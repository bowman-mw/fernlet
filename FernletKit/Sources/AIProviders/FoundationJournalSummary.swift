import Foundation
import AIContext
import FernletDomainModel

#if canImport(FoundationModels)
import FoundationModels
#endif

/// On-device AI stage for the journal → Core Memory summary (owner decision 2026-09-23: a journal
/// entry is summarized into Core Memory, never copied).
///
/// The model contributes one thing: a short note, in its own words, of what an entry was about. It
/// receives the entry and nothing else — a `JournalSummaryPayload` built by the app store from the
/// plaintext it already holds at append time; no Tier-2 memory, no health data, no other entry, and
/// no handle to the sealed journal store (this module cannot name one). CODE then decides whether
/// the reply may be stored: `JournalMemorySummaryPolicy` rejects a reply that is empty, runs past its
/// bound, uses diagnostic language, or reproduces the entry (verbatim, a prefix, or an excerpt). A
/// rejected reply is dropped, never repaired, and the caller's emotion-only memory stands.
///
/// Routing goes through the shipped `FernletAIGate` at the payload's pinned tier and invocation
/// class — `light` (never leaves the device) and ambient (falls back in the sleepy band) — so the
/// gate caps by device capability, applies the daily budget, and charges exactly one call. A `nil`
/// gate result (off / resting / sleepy / incapable) returns `nil` without touching the model.
///
/// Every model call is recorded in `AIAuditLog` (payload kind + the field NAME `entryText`, never
/// the entry or the reply): a reply the policy rejects is recorded as `.fellBack`, not `.succeeded`,
/// and session errors are audited and then rethrown. There is deliberately NO retry: a retry record
/// would have to hold the entry's text, and the AI retry queue rides the synced blob. MainActor by
/// the module's default isolation.
public enum FoundationJournalSummaryModel {

    /// Summarizes one journal entry for Core Memory. Returns the ACCEPTED summary — already through
    /// `JournalMemorySummaryPolicy` — or `nil` when AI did not run or its reply was rejected; the
    /// caller then keeps the emotion-only memory it already stored. Session errors are audited and
    /// rethrown.
    public static func summarize(_ payload: JournalSummaryPayload, gate: FernletAIGate) async throws -> String? {
        guard !payload.entryText.isEmpty else { return nil }
        #if canImport(FoundationModels)
        if #available(iOS 26.0, *) {
            guard let destination = gate.dispatch(
                tier: JournalSummaryPayload.capabilityTier,
                userInvoked: JournalSummaryPayload.isUserInvoked
            ) else { return nil }
            return try await respond(to: payload, destination: destination)
        }
        #endif
        return nil
    }

    /// The session instructions: paraphrase, stay brief, never quote, never label.
    private static let instructions = """
    You write one short line for a private memory list in a gentle wellness app called Fernlet.
    Given a journal entry, say in your own new words what the entry was about, in under 15 words.
    Never quote the entry and never reuse its phrases; paraphrase instead.
    Never name or suggest a diagnosis, a condition, a disorder, a medication, or therapy.
    No advice, no judgment, no questions. Write a short note, not a full paragraph.
    """

    /// The prompt: the entry is the LAST block, so a line break inside it cannot forge a section
    /// that follows.
    private static func prompt(for payload: JournalSummaryPayload) -> String {
        """
        Journal entry:
        \(payload.entryText)
        """
    }

    /// Records one outcome in the device-local audit log — the payload kind and field NAMES only.
    private static func audit(
        _ payload: JournalSummaryPayload,
        destination: AIDestination,
        outcome: AIAuditOutcome
    ) async {
        await AIAuditLog.shared.record(
            payloadKind: payload.payloadKind,
            destination: destination,
            modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
            includedFields: payload.includedFieldNames,
            outcome: outcome
        )
    }

    #if canImport(FoundationModels)
    /// One guided-generation call on a fresh session, then the acceptance policy against the entry.
    @available(iOS 26.0, *)
    private static func respond(
        to payload: JournalSummaryPayload,
        destination: AIDestination
    ) async throws -> String? {
        let session = LanguageModelSession(instructions: instructions)
        do {
            let response = try await session.respond(
                to: prompt(for: payload),
                generating: FoundationJournalSummary.self
            )
            let accepted = JournalMemorySummaryPolicy.accepted(response.content.summary, entryText: payload.entryText)
            await audit(payload, destination: destination, outcome: accepted == nil ? .fellBack : .succeeded)
            return accepted
        } catch {
            await audit(payload, destination: destination, outcome: AIAuditOutcome.fromModelError(error))
            throw error
        }
    }
    #endif
}

#if canImport(FoundationModels)
/// The `@Generable` response schema for the journal summary: one short line.
///
/// Guided generation guarantees the shape only. Whether the line may be stored is decided in code by
/// `JournalMemorySummaryPolicy` — the model's word is never final.
@available(iOS 26.0, *)
@Generable
private struct FoundationJournalSummary {
    @Guide(description: "One short note, under 15 words, saying in new words what the entry was about")
    var summary: String
}
#endif
