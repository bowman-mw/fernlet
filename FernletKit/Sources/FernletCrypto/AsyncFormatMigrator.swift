import Foundation

/// The async sibling of ``FormatMigrator`` — same contract (scan → convert → latch; bounded,
/// resumable, idempotent, fail-closed; never delete before verified read-back), same shared
/// ``FormatMigrationPassResult`` / ``FormatMigrationLatching`` vocabulary, for the one surface
/// class the sync protocol cannot express: a pass that is itself `async` (crypto-standardization
/// Phase 2.1 — the sealed-photo-backup reconcile is async and main-actor over CloudKit, and
/// bridging it into a synchronous `performPass()` would mean parking a thread on main-actor
/// work, the starvation family bounded passes exist to avoid).
///
/// ``run(maxPasses:)`` mirrors `FormatMigrator.run(maxPasses:)` line-for-line plus `await`; a
/// change to either loop's policy (latch only on a clean pass, stop on no forward progress,
/// short-circuit on a set latch) must land in both, and `AsyncFormatMigratorTests` pins this
/// loop's copy against a scripted conformer. (A shared pure "step" function was considered and
/// rejected: it would edit `FormatMigrator.swift` to deduplicate a three-branch decision.)
///
/// Concurrency: `nonisolated` (overriding this module's MainActor default isolation).
/// `performPass()` is a nonisolated **async** requirement, so a `@MainActor`-isolated method is a
/// legal witness (the thunk hops); `latch` is synchronous, so conformers expose it as
/// `nonisolated let` of a nonisolated latch value type.
public nonisolated protocol AsyncFormatMigrator {
    /// The conformer's pass tally. Carries the conformer's full diagnostic breakdown; the shared
    /// ``run(maxPasses:)`` loop reads only the two verdicts ``FormatMigrationPassResult`` names.
    associatedtype PassResult: FormatMigrationPassResult
    /// The conformer's persisted completion latch.
    associatedtype Latch: FormatMigrationLatching

    /// The one-way completion latch ``run(maxPasses:)`` sets after a proven-clean pass.
    var latch: Latch { get }

    /// The named maximum number of sweep passes ``run(maxPasses:)`` funds by default (Power-of-10
    /// R2: every loop carries a named bound). Two is the canonical value: one pass to convert, one
    /// to confirm the corpus is now clean.
    static var maxMigrationPasses: Int { get }

    /// Sweeps the corpus once (asynchronously), converting what it can and tallying what it
    /// found. Never sets the latch — ``run(maxPasses:)`` owns that decision — so tests can drive
    /// passes directly and assert idempotence. (Power-of-10 R7: conformers should not mark this
    /// `@discardableResult`; the tally carries the pass's failure information.)
    func performPass() async -> PassResult
}

extension AsyncFormatMigrator {
    /// Whether the migration has already been proven complete (the latch state).
    public nonisolated var isComplete: Bool { latch.isComplete }

    /// Runs passes until one comes back clean, then sets the latch.
    ///
    /// Same policy, bound and early exits as `FormatMigrator.run(maxPasses:)` — a pass that
    /// converted blobs is by definition not proof (it FOUND legacy blobs), so a second pass runs
    /// to confirm the corpus is now clean; that is what `maxPasses` funds. Stops early (leaving
    /// the latch closed) when a pass makes no forward progress, so a permanently unconvertible
    /// blob cannot spin.
    ///
    /// - Returns: the latch state afterwards — true only when completion is now proven. R7:
    ///   deliberately not `@discardableResult` — the sync loop's Bool gates an irreversible step
    ///   downstream, and this loop's callers report it to the user, so ignoring it is never safe.
    public nonisolated func run(maxPasses: Int = Self.maxMigrationPasses) async -> Bool {
        if latch.isComplete { return true }
        // R2: the named bound. `passesLeft` is decremented as the first statement of every
        // iteration, and two early returns (a clean pass, or a pass with no forward progress) exit
        // sooner.
        var passesLeft = max(1, maxPasses)
        while passesLeft > 0 {
            passesLeft -= 1
            let result = await performPass()
            if result.isClean {
                latch.markComplete()
                return true
            }
            // No forward progress: another identical pass would change nothing. Leave the latch
            // closed and retry at the next user-initiated pass, when whatever blocked this pass
            // (a transport failure, a foreign device's unhealed entries) may have recovered.
            if !result.madeForwardProgress { return false }
        }
        return false
    }
}
