import Foundation

/// The shared shape of every at-rest cryptographic format migration: **scan → convert → latch**,
/// in bounded, resumable, idempotent passes (crypto-standardization plan Phase 1).
///
/// `OwnPhotoKeyMigrator` is the shipping model this protocol was lifted from, and its contract is
/// the contract every conformer inherits:
/// - **Bounded passes.** ``run(maxPasses:)`` funds at most ``maxMigrationPasses`` sweeps — one to
///   convert, one to confirm the corpus is now clean — so a migration can never spin on a corpus
///   it cannot finish (the jetsam failure bounded passes exist to prevent).
/// - **Resumable.** A crash or an early stop leaves the latch closed and the next launch re-scans;
///   nothing about a pass is remembered except the one-way completion latch.
/// - **Idempotent.** ``performPass()`` over an already-converted corpus is a read-only sweep that
///   converts nothing, which is exactly what lets a confirming pass double as the proof.
/// - **Fail-closed.** The latch is set ONLY by a pass whose result ``FormatMigrationPassResult/isClean``
///   — one that converted nothing, failed nothing, and could classify everything. "I could not
///   look" must never latch, because every latch in this family gates an irreversible step
///   (dropping a legacy reader, binding a key) whose cost falls on bytes the pass never saw.
/// - **Never delete before verified read-back.** A conformer's convert step replaces a blob only
///   after the converted form has been written and read back successfully; the source bytes are
///   never deleted first. (The protocol cannot enforce this mechanically — it is the conformer's
///   contract, pinned by each conformer's own tests.)
///
/// **Why this lives in `FernletCrypto`.** A format migrator exists only where a cryptographic
/// format does, and every Class-A surface module that will conform in Phase 2 —
/// `PrivateMediaStore`, `PrivateStoreCore`, `FernletLock`, `ProximityKit`, and the app target —
/// already depends on this zero-dependency Layer-0 target for its sealing primitives, so no
/// conformer needs a new edge. The other reachable Layer-0 home, `FernletFoundation`, was
/// deliberately rejected: `CloudKitSync` (a walled consumer) imports it, and migration machinery
/// that exists to touch sealed corpora must stay unnameable by walled code — `FernletCrypto` is on
/// the protected side of the S3 wall by construction.
///
/// Concurrency: `nonisolated` (overriding this module's MainActor default isolation) — migrations
/// run inside off-main launch tasks, and conformers are nonisolated value types confined to
/// whatever isolation domain built them.
public nonisolated protocol FormatMigrator {
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

    /// Sweeps the corpus once, converting every legacy-format blob it can and tallying what it
    /// found. Never sets the latch — ``run(maxPasses:)`` owns that decision — so tests can drive
    /// passes directly and assert idempotence. (Power-of-10 R7: conformers should not mark this
    /// `@discardableResult`; the tally carries the pass's failure information.)
    func performPass() -> PassResult
}

/// The two verdicts the shared ``FormatMigrator/run(maxPasses:)`` loop reads off a conformer's
/// pass tally. Conformers carry their full diagnostic breakdown alongside; only these two drive
/// the latch-and-retry decision.
public nonisolated protocol FormatMigrationPassResult {
    /// Whether this pass PROVES the corpus is fully migrated: it converted nothing (so nothing was
    /// left in the legacy format when it started), failed nothing, and could classify everything.
    /// This is the only state that may set the latch, and "could classify everything" is the
    /// load-bearing half — an unreadable blob has no answer to "is this still legacy?", so it must
    /// block, never pass silently.
    var isClean: Bool { get }
    /// Whether this pass converted at least one blob. A pass that is not clean and made no forward
    /// progress would repeat identically, so the loop stops (leaving the latch closed) rather than
    /// spin on a permanently unconvertible blob.
    var madeForwardProgress: Bool { get }
}

/// The persisted "this corpus is fully migrated" completion latch a ``FormatMigrator`` sets.
///
/// **One-way and fail-closed by contract**: absent reads as incomplete, ``markComplete()`` is
/// called only by ``FormatMigrator/run(maxPasses:)`` after a clean pass, and ``reset()`` exists
/// only for tests and for steps that genuinely invalidate the proof (e.g. restoring blobs sealed
/// elsewhere). Conformers back it with device-local storage that never syncs — the property it
/// records is about THIS device's bytes. A conformer that introduces a new `UserDefaults` key for
/// its latch owes `Docs/PrivacyWipeCoverage.md` a disposition row in the same commit (the
/// persisted-surface wipe wall).
public nonisolated protocol FormatMigrationLatching {
    /// Whether a full clean pass has proven the corpus fully migrated. Absent (never set) reads as
    /// false — the fail-closed direction.
    var isComplete: Bool { get }
    /// Records completion. Called ONLY from ``FormatMigrator/run(maxPasses:)`` after a clean pass;
    /// never from a UI path, and never speculatively.
    func markComplete()
    /// Clears the latch, forcing a re-scan on the next run.
    func reset()
}

extension FormatMigrator {
    /// Whether the migration has already been proven complete (the latch state).
    public nonisolated var isComplete: Bool { latch.isComplete }

    /// Runs passes until one comes back clean, then sets the latch.
    ///
    /// A pass that converted blobs is by definition not proof — it FOUND legacy blobs — so a
    /// second pass runs to confirm the corpus is now clean; that is what `maxPasses` funds. Stops
    /// early (leaving the latch closed) when a pass makes no forward progress, so a permanently
    /// unconvertible blob cannot spin.
    ///
    /// - Returns: the latch state afterwards — true only when completion is now proven. R7:
    ///   deliberately not `@discardableResult` — this Bool gates an irreversible step downstream
    ///   (a legacy-reader delete, a key binding), so ignoring it is never safe.
    public nonisolated func run(maxPasses: Int = Self.maxMigrationPasses) -> Bool {
        if latch.isComplete { return true }
        // R2: the named bound. `passesLeft` is decremented as the first statement of every
        // iteration, and two early returns (a clean pass, or a pass with no forward progress) exit
        // sooner.
        var passesLeft = max(1, maxPasses)
        while passesLeft > 0 {
            passesLeft -= 1
            let result = performPass()
            if result.isClean {
                latch.markComplete()
                return true
            }
            // No forward progress: another identical pass would change nothing. Leave the latch
            // closed and retry at the next launch, when whatever blocked this pass (a locked
            // keychain, a full disk) may have recovered.
            if !result.madeForwardProgress { return false }
        }
        return false
    }
}
