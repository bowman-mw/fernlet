import AIContext
import AIProviders

/// The seam between `FernletStore`'s journal-append path and the on-device journal summary stage
/// (owner decision 2026-09-23: a journal entry is summarized into Core Memory, never copied).
///
/// The store mints an emotion-only memory first and then asks a summarizer for a summary to upgrade
/// it with; this protocol is what it asks. Production is ``OnDeviceJournalMemorySummarizer``. A test
/// double stands in because the Foundation model never runs in the simulator — and a faithful double
/// resolves the same `FernletAIGate` at the payload's pinned tier and invocation class, so the gate's
/// fallbacks (off, resting, sleepy, an incapable device) are exercised for real.
///
/// A conformer's reply is a CANDIDATE only: the store re-applies `JournalMemorySummaryPolicy` before
/// anything is written, so a summarizer that skipped the policy still cannot land a copy of the entry.
@MainActor
protocol JournalMemorySummarizing {
    /// Returns a summary of `payload`'s entry, or `nil` when AI did not run, failed, or produced
    /// nothing usable. `gate` is the store's gate as of the append — the conformer dispatches through
    /// it, so the one-call charge and every fallback happen at the real decision point.
    func summarize(_ payload: JournalSummaryPayload, gate: FernletAIGate) async -> String?
}

/// The production ``JournalMemorySummarizing``: `AIProviders`' walled on-device stage,
/// `FoundationJournalSummaryModel`.
///
/// A stateless value. It exists so `FernletStore` can hold the summarizer behind a protocol a test
/// can replace, while the stage itself stays in the walled module that cannot name a sealed store.
struct OnDeviceJournalMemorySummarizer: JournalMemorySummarizing {
    func summarize(_ payload: JournalSummaryPayload, gate: FernletAIGate) async -> String? {
        do {
            return try await FoundationJournalSummaryModel.summarize(payload, gate: gate)
        } catch {
            // Benign by design, and already recorded: the stage wrote this failure's outcome class to
            // the AI audit log before rethrowing. The recovery is the emotion-only memory the store
            // stored before asking — it simply keeps its emotion. No retry (see the stage's doc).
            return nil
        }
    }
}
