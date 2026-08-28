//
//  SealedPhotoBackupFormatMigrator.swift
//  Fernlet
//
//  The sealed-photo-backup surface's format migration (crypto-standardization Phase 2.1): the
//  POLICY shell — scan → convert → latch in bounded, resumable, idempotent passes — over the
//  EXISTING full-verification pass. The HEAL itself shipped with Phase 1 and is pinned by
//  `SealedPhotoBackupTests` §8: a full-verification reconcile rewrites a legacy entry with the
//  v2 digest and stamps its `hashVersion`. Nothing here adds a cryptographic call; the migrator
//  owns the loop, the latch, and the verdict vocabulary, and writes only through the existing
//  reconcile.
//

import CloudKitSync
import FernletCrypto
import Foundation

/// The persisted "this device's sealed-photo-backup entries are proven v2" completion latch
/// (crypto-standardization Phase 2.1).
///
/// ATTESTS (precisely): on this device, a full-verification pass completed in which every photo
/// this device holds was read and proven (`unreadable == 0`, `healedEntries == 0` — nothing was
/// left to prove when the pass started), every corpus was EXAMINED (its manifest slot was opened
/// and answered — a manifest, or proof none exists) and committed what it had to commit, and
/// every manifest minimum the pass OBSERVED — opened at restore, opened at reconcile start, or
/// the encoded value of a manifest it committed — was >= 2. Read-back is guaranteed for every
/// HEAL (a pass that healed never latches; the confirming pass re-opens the manifest from
/// CloudKit); a corpus born clean this pass is vouched for by the digests this pass computed,
/// not by read-back. A corpus nothing examined can never latch — absence of evidence blocks.
///
/// DOES NOT ATTEST: fleet convergence (a pre-marker build elsewhere can drop a minimum back to 1
/// after this is set), and it is NOT the Phase-3 gate — that gate reads
/// `minimumEntryHashVersion` from the manifests at gate time, on a real device, never this bit.
/// Unlike the rest of the `FormatMigrationLatching` family this latch gates nothing
/// irreversible; it stops the migration loop re-funding whole-library passes and drives the
/// Privacy & Data nudge off.
///
/// Device-local (`UserDefaults`, never synced). Cleared by
/// `OwnPhotoBackupCoordinator.tearDownForDeleteAll` — the wipe destroys the manifests this bit
/// makes a claim about (the deliberate mirror-image of `OwnPhotoMigrationLatch`'s kept row,
/// whose subject — the re-sealed local files — survives the wipe). Also reset on escrow-key
/// adoption and on any pass that OBSERVES a manifest minimum of 1 (a foreign legacy write). A
/// device-backup restore carries the bit to a new phone; tolerable for a nudge-only latch,
/// because the manifests are shared account state and the foreign-write observation re-grounds
/// it. Wipe wall: `Docs/PrivacyWipeCoverage.md` + `PersistedSurfaceWipeBoundaryTests`, same
/// commit as this key.
nonisolated struct SealedPhotoBackupMigrationLatch: FormatMigrationLatching {
    /// The `UserDefaults` key holding the latch (the `fernlet.sealedPhoto.` family prefix its
    /// three sibling ledgers use). A `static let` so the wipe wall's discovery scan finds it.
    static let defaultsKey = "fernlet.sealedPhoto.hashVersionMigrationComplete"

    private let defaults: UserDefaults

    /// Creates a latch over `defaults`; tests inject an isolated suite so they never touch the
    /// device's real completion state.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a full clean pass has proven this device's entries v2. Absent (never set) reads as
    /// false — the fail-closed direction.
    var isComplete: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Records completion. Called ONLY from `AsyncFormatMigrator.run(maxPasses:)` after a clean
    /// pass; never from a UI path, and never speculatively.
    func markComplete() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Clears the latch, forcing a re-scan at the next user-initiated full pass. For tests and
    /// for the three steps that genuinely invalidate the proof: delete-all teardown, escrow-key
    /// adoption, and an observed foreign legacy manifest write.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// One corpus's format verdict out of a FULL-verification pass — the migrator's per-corpus
/// evidence, built by `OwnPhotoBackupCoordinator.synchronize` from tallies and observations the
/// two legs already hold. Ambient passes build none (they read almost nothing and have no
/// verdict).
nonisolated struct SealedPhotoCorpusFormatVerdict: Sendable, Equatable {
    /// Which own-photo corpus this verdict describes.
    let corpus: SealedPhotoCorpus
    /// The corpus committed what it had to commit (false = a leg threw, the index or the id
    /// enumeration was unreadable, or a blocking restore outcome stopped the corpus — an
    /// indeterminate corpus). Vacuously true only alongside `examined == true`.
    let committed: Bool
    /// This pass opened the corpus's manifest slot — via the restore leg (`service.restore`,
    /// which returns nil for "no manifest exists": the ONLY honest source of that fact) or the
    /// reconcile leg (`openManifest`) — and got an answer. False = no leg reached a manifest
    /// read; absence of evidence, which blocks `isClean` unconditionally. This three-way fact
    /// (not examined / examined-none / examined-with-minima) exists so "never looked" can never
    /// score as "none existed".
    let examined: Bool
    /// Every `minimumEntryHashVersion` this pass observed for this corpus: the manifest opened by
    /// the restore leg, the manifest opened at reconcile start, and the encoded value of the
    /// manifest this pass committed (the outgoing value — "what this pass meant to commit", not a
    /// read-back). Empty + examined = no manifest exists (the vacuous case).
    let observedMinima: [Int]
    /// `SealedPhotoUploadSummary.unreadable` for this corpus.
    let unreadable: Int
    /// Entries committed at hashVersion 2 whose prior recorded version was 1 (both heal shapes:
    /// the re-upload and the matched-unchanged stamp upgrade).
    let healedEntries: Int
}

/// The migrator's pass tally (`FormatMigrationPassResult`). `verdicts == nil` means the pass was
/// a no-op (preference off / DEBUG skip / teardown-epoch guard) — never clean, never progress.
nonisolated struct SealedPhotoBackupMigrationPassResult: FormatMigrationPassResult, Sendable, Equatable {
    /// One verdict per corpus, or nil for a pass that never ran (see the type doc).
    let verdicts: [SealedPhotoCorpusFormatVerdict]?
    /// `OwnPhotoBackupCoordinator.PassResult.uploadFailed` — a pass with a failed upload leg
    /// proved nothing.
    let uploadFailed: Bool
    /// `OwnPhotoBackupCoordinator.PassResult.routeCommitted` — a pass that committed nothing
    /// proved nothing.
    let routeCommitted: Bool

    /// Builds the migration tally off one underlying coordinator pass — pure bookkeeping over
    /// values the pass already carries.
    init(pass: OwnPhotoBackupCoordinator.PassResult) {
        self.init(
            verdicts: pass.corpusVerdicts,
            uploadFailed: pass.uploadFailed,
            routeCommitted: pass.routeCommitted
        )
    }

    /// Memberwise spelling, kept so tests can build expectations directly.
    init(verdicts: [SealedPhotoCorpusFormatVerdict]?, uploadFailed: Bool, routeCommitted: Bool) {
        self.verdicts = verdicts
        self.uploadFailed = uploadFailed
        self.routeCommitted = routeCommitted
    }

    /// Clean = a proven pass: verdicts present; `!uploadFailed && routeCommitted`; and EVERY
    /// corpus satisfies `committed && examined && unreadable == 0 && healedEntries == 0 &&
    /// observedMinima.allSatisfy { $0 >= 2 }`. There is no nil-coalescing and no unexamined
    /// escape: a corpus nothing looked at can never be clean. `healedEntries == 0` keeps the
    /// strict shared semantic ("converted nothing") — a pass that healed anything is never the
    /// pass that latches, so every heal is confirmed by a later pass's genuine read-back.
    var isClean: Bool {
        guard let verdicts, !uploadFailed, routeCommitted else { return false }
        return verdicts.allSatisfy { verdict in
            verdict.committed && verdict.examined
                && verdict.unreadable == 0 && verdict.healedEntries == 0
                && verdict.observedMinima.allSatisfy { $0 >= SealedPhotoManifest.Entry.currentHashVersion }
        }
    }

    /// Progress = at least one entry's recorded version rose 1 → 2 this pass. Deliberately NOT
    /// plain new-photo uploads: backup progress is not format progress, and a pass that uploaded
    /// new photos while a foreign legacy entry stays stuck at 1 must stop, not spin.
    var madeForwardProgress: Bool {
        (verdicts ?? []).contains { $0.healedEntries > 0 }
    }
}

/// The Phase 2.1 policy shell: scan → convert → latch over the EXISTING full-verification pass.
/// Owns no photo, manifest, upload or crypto logic — `performPass()` is the coordinator's
/// `synchronize(fullVerification: true)`, handed in as a closure so the enable flow can bake in
/// `preferenceOverride`. Adds zero cryptographic calls (the standing purpose-statement rule);
/// writes only through the existing reconcile.
///
/// Built per invocation by `OwnPhotoBackupCoordinator.synchronizeFullyVerified` — cheap, like
/// the per-call stores. `@MainActor` because the pass is; conforms to the nonisolated
/// `AsyncFormatMigrator` via an isolated async witness (the thunk hops to the main actor).
@MainActor
final class SealedPhotoBackupFormatMigrator: AsyncFormatMigrator {
    /// The completion latch the shared `AsyncFormatMigrator.run(maxPasses:)` loop sets after a
    /// clean pass (a protocol requirement, which is why it is not `private`). `nonisolated`
    /// because the protocol's `latch` requirement is synchronous.
    nonisolated let latch: SealedPhotoBackupMigrationLatch
    /// R2: the named maximum number of passes the shared loop funds — one to heal, one to
    /// confirm the heal by read-back (the canonical `FormatMigrator` value; an already-clean or
    /// fresh corpus latches in one).
    nonisolated static let maxMigrationPasses = 2

    /// EVERY underlying coordinator pass this run made, in order, so the wrapper can merge them
    /// (`setEnabled` needs "did any pass commit", the store needs the banner facts from the last
    /// pass that did) without widening `run()`'s contract. Empty until `performPass()` has run.
    private(set) var underlyingPasses: [OwnPhotoBackupCoordinator.PassResult] = []

    private let pass: () async -> OwnPhotoBackupCoordinator.PassResult

    /// - Parameters:
    ///   - latch: The completion latch `run(maxPasses:)` sets.
    ///   - pass: Runs ONE full-verification pass and returns its result. Must be the real
    ///     coordinator pass (or a test double); the migrator never synthesizes one.
    init(
        latch: SealedPhotoBackupMigrationLatch,
        pass: @escaping () async -> OwnPhotoBackupCoordinator.PassResult
    ) {
        self.latch = latch
        self.pass = pass
    }

    /// Runs the injected pass once, appends it to ``underlyingPasses``, and maps it to the
    /// migration tally. Never sets the latch — the shared run loop owns that decision.
    func performPass() async -> SealedPhotoBackupMigrationPassResult {
        let result = await pass()
        underlyingPasses.append(result)
        return SealedPhotoBackupMigrationPassResult(pass: result)
    }
}
