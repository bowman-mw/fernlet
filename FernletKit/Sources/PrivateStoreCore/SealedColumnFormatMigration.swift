// SealedColumnFormatMigration.swift
// PrivateStoreCore
//
// Phase 2.6 of Docs/Plan-Crypto-Standardization-2026-08-27.md — the scan → convert → latch
// format migrator for the `ColumnCrypto` sealed corpora: the four sealed CoreData entities'
// seven ciphertext columns in `PrivatePersistenceController`'s local-only store. Converts
// legacy (unprefixed, no-AAD) AND v2 (binding-only AAD) blobs to v3 (purpose + binding AAD)
// so Phase 3 can delete the legacy read branches of `ColumnCrypto`'s dispatch.
//
// The scan IS the census's classification (`SealedColumnFormatCensus.classify(value:readFrom:)`
// judges every read; `verifyTable(matches:)` guards scope; the paging, autoreleasepool, refault
// and row-budget discipline are the census's, so counter and converter cannot disagree), and the
// open IS the shipping reader's dispatch (`ColumnCrypto.openReportingRung`, which `openBlob`
// delegates to — one implementation, now with a rung receipt). The re-seal goes through
// `ColumnCrypto.sealPlaintextV3Strict`, the strict sibling of the shipping writer's own private
// v3 body — same purpose, same AAD shape, same HKDF; it REFUSES when no install binding exists
// instead of falling open to legacy, because a converter that fell open would re-mint the exact
// format this pass exists to retire. Zero new purposes, zero new AAD shapes, zero new
// derivations, zero new dependency edges.
//
// The content key arrives by INJECTION (`keySource`, re-vended per page) because this module
// cannot import `FernletLock` (FernletLock → PrivateStoreCore is the existing edge); the app
// target wires the vend to `FernletLockService.contentKey(for: .privateHub)`, the shipped
// decrypt seam that answers nil the moment the hub re-locks — so the sweep stops fail-closed
// at the next page boundary with no second lock-state protocol and no key custody of its own.

import CoreData
import CryptoKit
import FernletCrypto
import FernletFoundation
import Foundation

// MARK: - Latch

/// The persisted "this device's sealed-column corpora are proven v3" completion latch
/// (crypto-standardization Phase 2.6).
///
/// ATTESTS — exactly one sentence, scoped to the pass's own fetch snapshot (never to
/// latch-write time): *on this device, a bounded keyed pass completed in which every
/// sealed-column row in that pass's fetch snapshot was classified and every one opened under V3
/// with purpose+binding AAD (or held no bytes); rows created, restored, or imported after that
/// snapshot carry no claim.* It never attests "no legacy exists now": the shipping writer's
/// fail-open can mint a new unprefixed row post-latch (Phase 3 closes that), a restore or
/// device transfer can import rows, and a row landing in the fetch-to-latch gap is caught by
/// the NEXT trigger's keyless revalidation census, not by this latch's claim.
///
/// DOES NOT ATTEST the Phase-3 gate — that gate is the census reading zero on a real upgraded
/// device PLUS a fresh clean keyed pass as the second witness, run at gate time, never quoted
/// from memory. The latch's only jobs are to stop re-funding whole-corpus passes and to drive
/// the in-hub status row off. A set latch is not even believed across launches: the first
/// funded trigger per process re-checks it with one keyless census
/// (``SealedColumnFormatMigrator/revalidate(controller:latch:)``) and resets it when
/// marker-visible legacy, v2, indeterminates, or truncation appear.
///
/// Cleared FIRST by the delete-all funnel's `sealedStoreRebuildHook` closure and beside
/// `FernletLockService`'s destructive reset's `purgeEncryptedEntities()` — both destroy the
/// latch's entire subject and tolerate partial failure, so a kept latch could stand over rows a
/// failed purge left behind. Wipe wall: `Docs/PrivacyWipeCoverage.md` +
/// `PersistedSurfaceWipeBoundaryTests`, same commit as this key.
///
/// Device-local (`UserDefaults`, never synced): the claim is about THIS device's bytes.
/// Concurrency: `nonisolated` value type over `UserDefaults` (itself thread-safe), as the
/// `FormatMigrationLatching` family expects.
public nonisolated struct SealedColumnMigrationLatch: FormatMigrationLatching {
    /// The `UserDefaults` key holding the latch. A `static let` literal so the wipe wall's
    /// discovery scan finds it (the `PendingNarrativeBufferMigrationLatch` shape, byte for byte).
    public static let defaultsKey = "com.fernlet.private-store.sealedColumnMigrationComplete"

    private let defaults: UserDefaults

    /// Creates a latch over `defaults`; tests inject an isolated suite so they never touch the
    /// device's real completion state.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a full clean pass has proven the corpora v3. Absent (never set) reads as false —
    /// the fail-closed direction.
    public var isComplete: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Records completion. Called ONLY from `AsyncFormatMigrator.run(maxPasses:)` after a clean
    /// pass; never from a UI path, and never speculatively.
    public func markComplete() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Clears the latch, forcing a re-scan on the next funded trigger. For tests, for the
    /// delete-all funnel's `sealedStoreRebuildHook` closure and `FernletLockService`'s
    /// destructive reset (both destroy the latch's subject), and for the launch revalidation
    /// when the keyless census contradicts the recorded proof.
    public func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

// MARK: - Tally vocabulary

/// One censused column's Phase 2.6 pass tally — every classified value lands in exactly one of
/// the outcome buckets below (`restoredOldBlob`/`restoreFailed` ride beside `readBackFailed` as
/// its restore sub-outcomes, never alone).
///
/// The vocabulary deliberately separates *proven-V3-by-open* (``openedV3``) from
/// "marker-says-V3" (which this type never counts — that is the census's keyless reading): the
/// three `converted*` buckets plus `openedV3` are keyed facts, the second witness Phase 3 needs
/// to resolve the census's 1-in-256 collided marker sliver.
public nonisolated struct SealedColumnMigrationTally: Sendable, Equatable {
    /// Proven V3 by open (purpose + binding AAD authenticated). The only bucket a clean claim
    /// counts, and the keyed resolution of the census's `v3Marked` upper bound.
    public var openedV3: Int
    /// Opened by the 0x02 branch, re-sealed V3, saved, and read back verified.
    public var convertedFromV2: Int
    /// No marker, legacy open, re-sealed V3, saved, and read back verified.
    public var convertedFromLegacyUnprefixed: Int
    /// Marker byte present but the LEGACY open succeeded — the collided sliver, resolved by
    /// open. Kept separate from the unprefixed count so a pass report states how much of the
    /// census's marked upper bound was actually collided legacy.
    public var convertedFromLegacyCollided: Int
    /// The column holds no bytes (`nil` or zero-length) — nothing to migrate, never blocking.
    public var skippedEmpty: Int
    /// The value could not be trusted to mean anything: an unfulfillable fault, a non-`Data`
    /// value, or a row deleted in the read-back window (F10d — a deliberate deletion is never
    /// restored). Blocks the latch; "I could not look" must never read as clean.
    public var indeterminate: Int
    /// `DeviceBindingID.ReadError` on an open — the retryable keychain outage, distinct from an
    /// authentication failure so a transient outage never reads as corrupted data.
    public var bindingReadError: Int
    /// Opens under no rung, first byte unprefixed. Blocks the latch (the census counts it
    /// legacy; a latch over it would contradict the gate).
    public var unopenableUnprefixed: Int
    /// Opens under no rung, first byte 0x02/0x03 — the named residue class whose reader outcome
    /// does not change when Phase 3 deletes the legacy branch (every path already throws for
    /// it). Split from ``unopenableUnprefixed`` so the gate can read the right bucket.
    public var unopenableMarked: Int
    /// A concurrent legitimate write won — the page save hit `NSMergeConflict`, or the read-back
    /// found a superseding blob that opens (the editor's V3-born save stands, never overwritten).
    /// The row is *unproven, not healed*: an untouched column can still hold legacy bytes, so
    /// this blocks the latch and a later pass supplies the proof.
    public var skippedConcurrentlyModified: Int
    /// The strict seal or the in-memory verify failed, or the page save failed for a
    /// non-conflict reason and rolled the pending conversions back. Row untouched.
    public var convertFailures: Int
    /// The verified read-back failed for an environment-level reason: bytes equal but unopenable
    /// (F10a, key/binding broke between seal and read-back) or bytes differ and open under no
    /// rung (F10b, store corruption). Always paired with ``restoredOldBlob`` or
    /// ``restoreFailed``.
    public var readBackFailed: Int
    /// The compare-guarded compensating restore put the held old bytes back (and the pass then
    /// aborted).
    public var restoredOldBlob: Int
    /// The compensating restore's save failed after its one bounded retry — the honest forfeit,
    /// recorded by the loud `sealedColumn.readBackFailedRestoreFailed` audit line.
    public var restoreFailed: Int

    /// Memberwise with zero defaults, public for test expectations (the 2.4 shape).
    public init(
        openedV3: Int = 0,
        convertedFromV2: Int = 0,
        convertedFromLegacyUnprefixed: Int = 0,
        convertedFromLegacyCollided: Int = 0,
        skippedEmpty: Int = 0,
        indeterminate: Int = 0,
        bindingReadError: Int = 0,
        unopenableUnprefixed: Int = 0,
        unopenableMarked: Int = 0,
        skippedConcurrentlyModified: Int = 0,
        convertFailures: Int = 0,
        readBackFailed: Int = 0,
        restoredOldBlob: Int = 0,
        restoreFailed: Int = 0
    ) {
        self.openedV3 = openedV3
        self.convertedFromV2 = convertedFromV2
        self.convertedFromLegacyUnprefixed = convertedFromLegacyUnprefixed
        self.convertedFromLegacyCollided = convertedFromLegacyCollided
        self.skippedEmpty = skippedEmpty
        self.indeterminate = indeterminate
        self.bindingReadError = bindingReadError
        self.unopenableUnprefixed = unopenableUnprefixed
        self.unopenableMarked = unopenableMarked
        self.skippedConcurrentlyModified = skippedConcurrentlyModified
        self.convertFailures = convertFailures
        self.readBackFailed = readBackFailed
        self.restoredOldBlob = restoredOldBlob
        self.restoreFailed = restoreFailed
    }

    /// Rows this column converted to proven V3 (all three source generations folded).
    public var converted: Int {
        convertedFromV2 + convertedFromLegacyUnprefixed + convertedFromLegacyCollided
    }

    /// Everything that blocks the latch on this column: unopenable, unclassifiable,
    /// conflict-skipped, failed, or read-back-failed values.
    public var blocking: Int {
        indeterminate + bindingReadError + unopenableUnprefixed + unopenableMarked
            + skippedConcurrentlyModified + convertFailures + readBackFailed
    }

    /// Bucket-wise sum, used to fold per-column tallies into pass totals.
    public static func + (lhs: SealedColumnMigrationTally, rhs: SealedColumnMigrationTally) -> SealedColumnMigrationTally {
        SealedColumnMigrationTally(
            openedV3: lhs.openedV3 + rhs.openedV3,
            convertedFromV2: lhs.convertedFromV2 + rhs.convertedFromV2,
            convertedFromLegacyUnprefixed: lhs.convertedFromLegacyUnprefixed + rhs.convertedFromLegacyUnprefixed,
            convertedFromLegacyCollided: lhs.convertedFromLegacyCollided + rhs.convertedFromLegacyCollided,
            skippedEmpty: lhs.skippedEmpty + rhs.skippedEmpty,
            indeterminate: lhs.indeterminate + rhs.indeterminate,
            bindingReadError: lhs.bindingReadError + rhs.bindingReadError,
            unopenableUnprefixed: lhs.unopenableUnprefixed + rhs.unopenableUnprefixed,
            unopenableMarked: lhs.unopenableMarked + rhs.unopenableMarked,
            skippedConcurrentlyModified: lhs.skippedConcurrentlyModified + rhs.skippedConcurrentlyModified,
            convertFailures: lhs.convertFailures + rhs.convertFailures,
            readBackFailed: lhs.readBackFailed + rhs.readBackFailed,
            restoredOldBlob: lhs.restoredOldBlob + rhs.restoredOldBlob,
            restoreFailed: lhs.restoreFailed + rhs.restoreFailed
        )
    }
}

/// Why a row was never attempted by a pass — the fail-closed accounting for rows the sweep
/// stopped short of, so "not looked at" can never silently read as "looked at and clean".
public nonisolated enum SealedColumnNotAttemptedReason: String, Sendable, Hashable, CaseIterable {
    /// The per-page key vend answered nil (re-lock / scope revocation / duress): the pass
    /// stopped cleanly at the page boundary. The designed retry is the next unlock.
    case keyRevoked
    /// The pass's row budget was exhausted before these rows; the pass is `truncated`.
    case rowBudget
    /// `DeviceBindingID.current()` was nil at preflight — the pass never started (F14).
    case noBinding
    /// The pass aborted (F6/F9/F10a/F10b/F11/F15/F16) before reaching these rows.
    case aborted
}

/// One Phase 2.6 pass's full tally — per-column buckets plus the pass scalars — and, through
/// ``isClean`` / ``madeForwardProgress``, the two verdicts the shared
/// `AsyncFormatMigrator.run(maxPasses:)` loop reads.
public nonisolated struct SealedColumnMigrationResult: Sendable, Equatable, FormatMigrationPassResult {
    /// Per-column tallies, keyed by the census's own ``SealedColumnIdentifier`` vocabulary.
    public var columns: [SealedColumnIdentifier: SealedColumnMigrationTally]
    /// Rows the pass stopped short of, by reason (rows, not column values).
    public var notAttempted: [SealedColumnNotAttemptedReason: Int]
    /// Rows whose columns were classified (one classification per ciphertext column).
    public var rowsScanned: Int
    /// Rows the store held across all censused entities at scan time.
    public var rowsAvailable: Int
    /// The row budget stopped the scan before every row was classified. Blocks the latch —
    /// a truncated pass counted a subset (census rule).
    public var truncated: Bool
    /// `DeviceBindingID.current()` was nil at preflight; nothing was attempted (F14).
    public var abortedNoBinding: Bool
    /// The pass aborted (store unavailable/torn, save failure, environment break, corruption).
    /// Load-bearing for ``madeForwardProgress``: an aborted pass is never re-funded by `run()`.
    public var aborted: Bool

    /// Memberwise with zero defaults, public for test expectations (the 2.4 shape).
    public init(
        columns: [SealedColumnIdentifier: SealedColumnMigrationTally] = [:],
        notAttempted: [SealedColumnNotAttemptedReason: Int] = [:],
        rowsScanned: Int = 0,
        rowsAvailable: Int = 0,
        truncated: Bool = false,
        abortedNoBinding: Bool = false,
        aborted: Bool = false
    ) {
        self.columns = columns
        self.notAttempted = notAttempted
        self.rowsScanned = rowsScanned
        self.rowsAvailable = rowsAvailable
        self.truncated = truncated
        self.abortedNoBinding = abortedNoBinding
        self.aborted = aborted
    }

    /// Every column's tally folded together.
    public var total: SealedColumnMigrationTally {
        columns.values.reduce(SealedColumnMigrationTally(), +)
    }

    /// Column values converted to proven V3 by this pass (all generations, all columns).
    public var convertedTotal: Int { total.converted }

    /// Rows the pass never attempted, all reasons folded.
    public var notAttemptedTotal: Int { notAttempted.values.reduce(0, +) }

    /// Whether this pass PROVES the corpora are fully migrated: every classified value was
    /// `openedV3` or `skippedEmpty`, and the pass saw everything (nothing converted, nothing
    /// failed, nothing skipped, nothing unattempted, no truncation, no abort). The only state
    /// that may set the latch.
    public var isClean: Bool {
        let folded = total
        return folded.converted == 0 && folded.blocking == 0
            && notAttemptedTotal == 0
            && !truncated && !abortedNoBinding && !aborted
    }

    /// Whether the shared run loop may fund a confirming pass. The `!aborted` clause is
    /// load-bearing: a pass that converted pages and then aborted must NOT re-enter the very
    /// environment the abort just declared untrustworthy — any abort stops the whole `run()`,
    /// and the next unlock re-funds against a possibly-recovered environment. F12's clean stop
    /// (key revoked) deliberately keeps its progress flag: a convert-then-relock pass funds a
    /// second pass that vends nil immediately and stops — one cheap extra call, by design.
    public var madeForwardProgress: Bool {
        convertedTotal > 0 && !aborted
    }

    /// Whether the pass's ONLY stop reason was the key vend answering nil — no real failure,
    /// no truncation, no abort (§8 pin 3: the D3 row records `.idle`, never `.blocked`, for
    /// this stop; the audit line remains the nothing-silent record).
    public var stoppedOnlyByKeyRevocation: Bool {
        let revoked = notAttempted[.keyRevoked] ?? 0
        return revoked > 0
            && notAttemptedTotal == revoked
            && total.blocking == 0
            && !truncated && !abortedNoBinding && !aborted
    }
}

/// What the migrator reports mid-run through its observation seam — the D3 status capsule's
/// feed. `pageCommitted` fires after a page save commits conversions (cumulative verified
/// count for the current pass); `passEnded` fires exactly once per `performPass()`.
public nonisolated enum SealedColumnMigrationProgressEvent: Sendable, Equatable {
    /// A page's save committed; `convertedSoFar` is the pass's cumulative verified conversions.
    case pageCommitted(convertedSoFar: Int)
    /// A pass finished with this result (every path, preflight aborts included).
    case passEnded(SealedColumnMigrationResult)
}

// MARK: - Migrator

/// The Phase 2.6 `AsyncFormatMigrator` conformer: bounded, idempotent, fail-closed sweeps of
/// the four sealed entities' seven ciphertext columns, converting legacy and v2 blobs to v3.
///
/// Paging is the census's verbatim (page ``defaultPageSize``, refault-per-row inside a per-page
/// `autoreleasepool`, row budget ``defaultRowBudget`` — the same constants, imported not
/// re-spelled). Unit of work is one row; unit of durability is one page (one `saveSealed()`),
/// so a mid-pass stop loses at most one unsaved page of *work*, never data. The key is
/// re-vended per page and never retained (revocation granularity: one page — the vended
/// `SymmetricKey` is a page-local value copy that dies at page end). The migrator's background
/// context keeps CoreData's default `NSErrorMergePolicy` — THE compare-before-write guard on
/// this substrate: a concurrent repository edit wins, the page rolls back, and the rows tally
/// `skippedConcurrentlyModified` (unproven, not healed).
///
/// Every saved page is read back verified, and a failed read-back is DISCRIMINATED before any
/// restore is considered: a deleted row is indeterminate (never restored — F16's purged rows
/// included, so the held bytes can never resurrect a wipe); a superseding blob that opens is a
/// concurrent legitimate write (kept, never overwritten); only bytes-equal-but-unopenable
/// (environment break) and bytes-differ-and-open-nowhere (corruption) fund the compare-guarded
/// compensating restore, after which the pass — and the whole `run()` — aborts.
///
/// Not `Sendable` (it holds the non-Sendable `PrivatePersistenceController`): build it INSIDE
/// the detached task that runs it, the 2.3 shape — only the `@Sendable` key source and Sendable
/// configuration cross the isolation boundary.
public nonisolated struct SealedColumnFormatMigrator: AsyncFormatMigrator {
    /// The completion latch the shared `AsyncFormatMigrator.run(maxPasses:)` loop sets after a
    /// clean pass (a protocol requirement, which is why it is not `private`).
    public let latch: SealedColumnMigrationLatch
    /// R2: the named maximum number of sweep passes the shared loop funds — one to convert, one
    /// to confirm the corpora are now clean (the family canon).
    nonisolated public static let maxMigrationPasses = 2
    /// Rows faulted in per page — the census's constant, imported not re-spelled, so the memory
    /// bound (peak residency = one page of externalized blobs) cannot drift from the counter's.
    public static let defaultPageSize = SealedColumnFormatCensus.defaultPageSize
    /// Hard ceiling on rows visited per pass — the census's cap, imported not re-spelled, so
    /// migrator and census bound identically. Exhausting it truncates loudly, never silently.
    public static let defaultRowBudget = SealedColumnFormatCensus.defaultRowCap
    /// R2: the compensating restore's save is attempted at most this many times (the one
    /// bounded retry the F11 row funds — the dominant transient causes, a momentarily busy
    /// sqlite or a FileProtection class-key eviction, are exactly what one retry covers).
    static let restoreSaveAttempts = 2

    /// Entity → the SAME four purposes the repositories construct `ColumnCrypto` with. A drift
    /// guard beside `verifyTable`: the keys must equal the censused entity set exactly, or the
    /// pass aborts indeterminate rather than silently narrowing scope.
    static let columnPurposes: [String: CryptographicPurpose] = [
        "MenstrualNarrative": FernletCryptoPurpose.KeyDerivation.menstrualNarrativeLegacyV1,
        "JournalNarrative": FernletCryptoPurpose.KeyDerivation.journalNarrativeLegacyV1,
        "IntimacyLog": FernletCryptoPurpose.KeyDerivation.intimacyLogLegacyV1,
        "WorryNarrative": FernletCryptoPurpose.KeyDerivation.worryNarrativeLegacyV1
    ]

    /// The sealed stack to migrate. Injectable so tests pass isolated controllers; production
    /// passes the shared one via ``standard(keySource:defaults:)``.
    private let controller: PrivatePersistenceController
    /// The per-page content-key vend — the app target wires it to the lock service's
    /// `.privateHub` decrypt seam. `nil` means "stop cleanly at this page boundary".
    private let keySource: @Sendable () async -> SymmetricKey?
    /// Rows per page (peak-residency knob; also the SQLite write-lock hold bound — see §7 of
    /// the phase design for why this must not be raised casually).
    private let pageSize: Int
    /// Hard ceiling on rows visited per pass.
    private let rowBudget: Int

    /// D3 observation seam: page commits and pass results, for the app target's status capsule
    /// and for tests counting passes. `nil` costs nothing.
    public var progressObserver: (@Sendable (SealedColumnMigrationProgressEvent) -> Void)?

    /// Test seam, internal: runs after a page's rows are processed and staged but BEFORE the
    /// page save — how the conflict pins land a concurrent edit inside the optimistic-locking
    /// window (a post-save edit refreshes the shared row cache, so only a write landing between
    /// a row's fault and the page save can produce `NSMergeConflict`). `nil` in production.
    var prePageSaveHookForTesting: (@Sendable (NSManagedObjectContext) -> Void)?

    /// Test seam, internal: runs between a page's save and its verified read-back; `nil` in
    /// production. (How the read-back family constructs corruption, environment break,
    /// concurrent supersession, mid-window deletion, and F16's mid-page purge+rebuild.)
    var postSavePreReadBackHookForTesting: (@Sendable (NSManagedObjectContext) -> Void)?

    /// Test seam, internal: replaces the compensating restore's save when set, so the F11 pin
    /// can fail it deterministically and count the bounded attempts. `nil` in production
    /// (the restore saves through `saveSealed()`).
    var restoreSaveOverrideForTesting: (@Sendable (NSManagedObjectContext) throws -> Void)?

    /// Creates a migrator over one sealed stack.
    ///
    /// - Parameters:
    ///   - controller: The sealed stack to migrate.
    ///   - keySource: The per-page content-key vend; `nil` stops the pass cleanly.
    ///   - latch: The completion latch `run(maxPasses:)` sets.
    ///   - pageSize: Rows per page; defaults to the census's ``defaultPageSize``.
    ///   - rowBudget: Hard row ceiling per pass; defaults to the census's ``defaultRowBudget``.
    public init(
        controller: PrivatePersistenceController,
        keySource: @escaping @Sendable () async -> SymmetricKey?,
        latch: SealedColumnMigrationLatch,
        pageSize: Int = defaultPageSize,
        rowBudget: Int = defaultRowBudget
    ) {
        self.controller = controller
        self.keySource = keySource
        self.latch = latch
        self.pageSize = pageSize
        self.rowBudget = rowBudget
    }

    /// The production migrator: the shared on-device controller, latch on `defaults`
    /// (injectable — the 2.1 P10 lesson, taken at design time).
    public static func standard(
        keySource: @escaping @Sendable () async -> SymmetricKey?,
        defaults: UserDefaults = .standard
    ) -> SealedColumnFormatMigrator {
        SealedColumnFormatMigrator(controller: .shared, keySource: keySource, latch: latch(defaults: defaults))
    }

    /// The completion latch over `defaults` — the same one ``standard(keySource:defaults:)``
    /// uses, exposed so the delete-all funnel's hook closure and `FernletLockService`'s
    /// destructive reset can reach the latch without building a migrator.
    public static func latch(defaults: UserDefaults = .standard) -> SealedColumnMigrationLatch {
        SealedColumnMigrationLatch(defaults: defaults)
    }

    // MARK: - Launch revalidation (§9)

    /// What one keyless recheck of a SET latch concluded. Three-state so a census throw is
    /// neither confirmation nor a reset.
    public enum RevalidationOutcome: Sendable, Equatable {
        /// The keyless census contradicts nothing: the latch survives, and the caller's
        /// once-per-process revalidation slot is consumed.
        case confirmed
        /// The latch was cleared — marker-visible legacy/v2, indeterminates, truncation, or a
        /// `tableDoesNotMatchModel` drift (the latch's subject definition moved under it).
        /// The caller re-funds a pass.
        case reset
        /// The census threw for a reason that is neither confirmation nor contradiction (store
        /// unavailable, dirty context, invalid bounds): the latch is kept UNCONFIRMED, the
        /// once-per-process slot is NOT consumed (the next funded trigger retries), no pass
        /// runs, and one audit line records it. "I could not look" must never confirm a latch,
        /// and a transient store teardown must never burn one.
        case unavailable
    }

    /// The §9 launch revalidation: a set latch is not believed — it is re-checked with one
    /// keyless, marker-only census (crypto-free but NOT wall-clock cheap: a full-corpus disk
    /// sweep, which is why the caller runs this INSIDE the detached utility task, before the
    /// first key vend, never on the unlock frame).
    ///
    /// The reset predicate is the *marker-visible projection* of the latch predicate — a named
    /// deviation from 2.2's "reset predicate equals latch predicate", forced by the surface:
    /// the latch predicate includes keyed facts (proven-by-open) a keyless recheck cannot see.
    /// The gap that leaves is precisely the collided sliver, resolved only by Phase 3's fresh
    /// keyed pass.
    public static func revalidate(
        controller: PrivatePersistenceController,
        latch: SealedColumnMigrationLatch
    ) -> RevalidationOutcome {
        revalidate(latch: latch) { try SealedColumnFormatCensus.run(controller: controller) }
    }

    /// The revalidation policy over an injected census run — internal so the
    /// `tableDoesNotMatchModel` branch (unconstructible against the real model) is testable.
    static func revalidate(
        latch: SealedColumnMigrationLatch,
        census: () throws -> SealedColumnFormatCensusResult
    ) -> RevalidationOutcome {
        do {
            let reading = try census()
            let contradicted = reading.definitelyLegacy > 0
                || reading.total.v2Marked > 0
                || reading.total.indeterminate > 0
                || reading.truncated
            guard contradicted else { return .confirmed }
            latch.reset()
            FernletAuditLog.log("sealedColumn.latchRevalidationReset", context: [
                "definitelyLegacy": "\(reading.definitelyLegacy)",
                "v2Marked": "\(reading.total.v2Marked)",
                "indeterminate": "\(reading.total.indeterminate)",
                "truncated": "\(reading.truncated)"
            ])
            return .reset
        } catch SealedColumnFormatCensus.Failure.tableDoesNotMatchModel {
            // The latch's subject definition drifted under it — the same reason the pass's own
            // preflight aborts on this check. Reset rather than stand over an unknown scope.
            latch.reset()
            FernletAuditLog.log("sealedColumn.latchRevalidationReset", context: ["reason": "tableDrift"])
            return .reset
        } catch {
            FernletAuditLog.log("sealedColumn.latchRevalidationUnavailable", context: ["error": "\(error)"])
            return .unavailable
        }
    }

    // MARK: - The pass

    /// Sweeps the corpora once: preflight → per-entity, per-page classify/convert/save/prune/
    /// verified-read-back → tally. Never sets the latch — `run(maxPasses:)` owns that decision.
    ///
    /// - Returns: the pass tally, which carries the pass's failure information. R7: not
    ///   `@discardableResult`.
    public func performPass() async -> SealedColumnMigrationResult {
        var result = SealedColumnMigrationResult()
        guard let storeIdentity = preflight(into: &result) else {
            return finishPass(result)
        }
        let context = controller.container.newBackgroundContext()
        context.automaticallyMergesChangesFromParent = false
        guard let counts = countRows(in: context) else {
            result.aborted = true
            return finishPass(result)
        }
        result.rowsAvailable = counts.values.reduce(0, +)
        guard DeviceBindingID.current() != nil else {
            // F14: cannot mint a V3-bound blob. Never convert to "what the writer would write
            // today" — re-sealing legacy→legacy would churn bytes for zero standardization gain.
            result.abortedNoBinding = true
            result.notAttempted[.noBinding] = result.rowsAvailable
            return finishPass(result)
        }
        await sweep(context: context, counts: counts, storeIdentity: storeIdentity, into: &result)
        // The census's double guard, extended with the store's identity: a store torn off — or
        // torn off AND healed by a rebuild — under the pass invalidates everything after the
        // tear (F15/F16). Aborting is what proves the held ledger can never replay into a
        // rebuilt store.
        if !result.aborted, !result.abortedNoBinding,
           currentStoreIdentity() != storeIdentity {
            result.aborted = true
        }
        return finishPass(result)
    }

    /// The store-loaded + table + purpose-map preflight (F15 + the drift guards). Returns the
    /// attached store's identity for the mid-pass tear detector, or nil after marking `result`
    /// aborted.
    private func preflight(into result: inout SealedColumnMigrationResult) -> ObjectIdentifier? {
        guard controller.isStoreLoaded, let identity = currentStoreIdentity() else {
            result.aborted = true
            return nil
        }
        do {
            try SealedColumnFormatCensus.verifyTable(matches: controller.container.managedObjectModel)
        } catch {
            result.aborted = true
            return nil
        }
        let censused = Set(SealedColumnFormatCensus.censusedEntities.map(\.entityName))
        guard Set(Self.columnPurposes.keys) == censused else {
            // The migrator's own purpose-map drift guard: a mismatch aborts indeterminate,
            // never silently narrows scope.
            result.aborted = true
            return nil
        }
        return identity
    }

    /// The identity of the attached sealed store, or nil when none is attached. A
    /// `rebuildStore()` swaps the `NSPersistentStore` instance, so identity inequality detects
    /// both a tear-off and a tear-off-then-heal (F16).
    private func currentStoreIdentity() -> ObjectIdentifier? {
        controller.container.persistentStoreCoordinator.persistentStores.first.map(ObjectIdentifier.init)
    }

    /// Counts every censused entity's rows (keyless), or nil when a count itself fails.
    private func countRows(in context: NSManagedObjectContext) -> [String: Int]? {
        context.performAndWait {
            var counts: [String: Int] = [:]
            for entity in SealedColumnFormatCensus.censusedEntities {  // R2: the static table.
                let request = NSFetchRequest<NSManagedObject>(entityName: entity.entityName)
                guard let count = try? context.count(for: request) else { return nil }
                counts[entity.entityName] = max(count, 0)
            }
            return counts
        }
    }

    /// Walks the censused entities under the row budget, vending the key per page. Mutates
    /// `result` with every page's tallies and the stop accounting.
    private func sweep(
        context: NSManagedObjectContext,
        counts: [String: Int],
        storeIdentity: ObjectIdentifier,
        into result: inout SealedColumnMigrationResult
    ) async {
        var convertedSoFar = 0
        for entity in SealedColumnFormatCensus.censusedEntities {  // R2: the static table.
            let available = counts[entity.entityName] ?? 0
            guard available > 0 else { continue }
            let budget = max(rowBudget - result.rowsScanned, 0)
            let limit = min(available, budget)
            if limit < available {
                result.truncated = true
                result.notAttempted[.rowBudget, default: 0] += available - limit
            }
            guard limit > 0 else { continue }
            guard let purpose = Self.columnPurposes[entity.entityName] else {
                result.aborted = true
                return
            }
            let crypto = ColumnCrypto(purpose: purpose)
            guard let ids = fetchRowIDs(entity: entity, limit: limit, in: context) else {
                result.aborted = true
                return
            }
            let stopped = await sweepEntityPages(
                ids: ids, entity: entity, crypto: crypto, context: context,
                storeIdentity: storeIdentity, convertedSoFar: &convertedSoFar, into: &result
            )
            if stopped { return }
        }
    }

    /// One entity's page loop. Returns `true` when the whole pass must stop (key revoked,
    /// abort, or store torn), after recording the remaining-row accounting.
    private func sweepEntityPages(
        ids: [NSManagedObjectID],
        entity: SealedEntityColumns,
        crypto: ColumnCrypto,
        context: NSManagedObjectContext,
        storeIdentity: ObjectIdentifier,
        convertedSoFar: inout Int,
        into result: inout SealedColumnMigrationResult
    ) async -> Bool {
        let pageCount = (ids.count + pageSize - 1) / pageSize
        for page in 0..<pageCount {  // R2: bound computed from the fetched id count.
            let start = page * pageSize
            let end = min(start + pageSize, ids.count)
            guard start < end else { break }
            // The vend is the authoritative stop signal; cancellation is boundary hygiene.
            guard !Task.isCancelled, let pageKey = await keySource() else {
                result.notAttempted[.keyRevoked, default: 0] += Self.remainingRows(in: result)
                return true
            }
            guard currentStoreIdentity() == storeIdentity else {
                // F16: the store was torn off (or torn and rebuilt) between pages. The pending
                // ledger died with its page closure; nothing can replay into the rebuilt store.
                result.aborted = true
                result.notAttempted[.aborted, default: 0] += Self.remainingRows(in: result)
                return true
            }
            let outcome = runPage(ids: Array(ids[start..<end]), entity: entity, crypto: crypto, pageKey: pageKey, context: context)
            fold(outcome, into: &result)
            result.rowsScanned += end - start
            convertedSoFar += outcome.verifiedConversions
            if outcome.committedConversions > 0 {
                progressObserver?(.pageCommitted(convertedSoFar: convertedSoFar))
            }
            if outcome.abort {
                result.aborted = true
                result.notAttempted[.aborted, default: 0] += Self.remainingRows(in: result)
                return true
            }
        }
        return false
    }

    /// Rows the stopped pass never reached AND has not already accounted for — the rowBudget
    /// entries recorded at entity starts also describe unscanned rows, so subtracting the
    /// existing notAttempted total is what keeps a budget-then-stop pass from counting the same
    /// row twice.
    private static func remainingRows(in result: SealedColumnMigrationResult) -> Int {
        max(result.rowsAvailable - result.rowsScanned - result.notAttemptedTotal, 0)
    }

    /// Folds one page's tallies into the pass result.
    private func fold(_ outcome: SealedColumnPageOutcome, into result: inout SealedColumnMigrationResult) {
        for (column, tally) in outcome.tallies {  // R2: bounded by the entity's column list.
            result.columns[column] = (result.columns[column] ?? SealedColumnMigrationTally()) + tally
        }
    }

    /// Fetches up to `limit` row IDs of one entity — the Sendable row handles the page loop
    /// carries across its per-page `await` boundaries (the census materializes rows directly
    /// because its whole scan runs inside one `performAndWait`; a pass that must suspend
    /// between pages cannot, so it pages by `NSManagedObjectID` and materializes inside each
    /// page's closure — same page size, same refault discipline, same no-sort honesty).
    private func fetchRowIDs(
        entity: SealedEntityColumns,
        limit: Int,
        in context: NSManagedObjectContext
    ) -> [NSManagedObjectID]? {
        context.performAndWait {
            let request = NSFetchRequest<NSManagedObjectID>(entityName: entity.entityName)
            request.resultType = .managedObjectIDResultType
            request.fetchLimit = limit
            return try? context.fetch(request)
        }
    }

    /// One page, entirely inside one `performAndWait` + `autoreleasepool`: materialize →
    /// classify/convert → (pre-save hook) → save → (post-save hook) → prune → verified
    /// read-back (with the discriminated restore) → refault. Static so the context closure
    /// captures only Sendable values, never the non-Sendable migrator itself.
    private func runPage(
        ids: [NSManagedObjectID],
        entity: SealedEntityColumns,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        context: NSManagedObjectContext
    ) -> SealedColumnPageOutcome {
        let preSaveHook = prePageSaveHookForTesting
        let postSaveHook = postSavePreReadBackHookForTesting
        let restoreOverride = restoreSaveOverrideForTesting
        return context.performAndWait {
            autoreleasepool {
                SealedColumnPageWorker.run(
                    ids: ids, entity: entity, crypto: crypto, pageKey: pageKey, context: context,
                    preSaveHook: preSaveHook, postSaveHook: postSaveHook,
                    restoreSaveOverride: restoreOverride
                )
            }
        }
    }

    /// Emits the pass audit lines and the `passEnded` observation, then returns the result.
    private func finishPass(_ result: SealedColumnMigrationResult) -> SealedColumnMigrationResult {
        FernletAuditLog.log("sealedColumn.formatMigrationPass", context: Self.auditContext(for: result))
        if result.aborted || result.abortedNoBinding {
            FernletAuditLog.log("sealedColumn.formatMigrationAborted", context: [
                "noBinding": "\(result.abortedNoBinding)"
            ])
        }
        progressObserver?(.passEnded(result))
        return result
    }

    /// The one-line-per-pass audit context: bucket totals and bounds only — entity/column names
    /// and counts, never ids-with-content, never plaintext.
    private static func auditContext(for result: SealedColumnMigrationResult) -> [String: String] {
        let folded = result.total
        var context: [String: String] = [
            "rowsScanned": "\(result.rowsScanned)",
            "rowsAvailable": "\(result.rowsAvailable)",
            "openedV3": "\(folded.openedV3)",
            "convertedV2": "\(folded.convertedFromV2)",
            "convertedLegacy": "\(folded.convertedFromLegacyUnprefixed)",
            "convertedCollided": "\(folded.convertedFromLegacyCollided)",
            "skippedEmpty": "\(folded.skippedEmpty)",
            "indeterminate": "\(folded.indeterminate)",
            "bindingReadError": "\(folded.bindingReadError)",
            "unopenableUnprefixed": "\(folded.unopenableUnprefixed)",
            "unopenableMarked": "\(folded.unopenableMarked)",
            "conflictSkipped": "\(folded.skippedConcurrentlyModified)",
            "convertFailures": "\(folded.convertFailures)",
            "readBackFailed": "\(folded.readBackFailed)",
            "notAttempted": "\(result.notAttemptedTotal)",
            "truncated": "\(result.truncated)",
            "aborted": "\(result.aborted)"
        ]
        let blocked = result.columns.filter { $0.value.blocking > 0 }.keys.sorted()
        if !blocked.isEmpty {
            context["blockedColumns"] = blocked.map(\.description).joined(separator: ",")
        }
        return context
    }
}

// MARK: - Page worker

/// What one page's work produced. `Sendable` value, returned out of the page's context closure.
nonisolated struct SealedColumnPageOutcome: Sendable {
    /// Per-column tallies for this page.
    var tallies: [SealedColumnIdentifier: SealedColumnMigrationTally] = [:]
    /// Conversions this page's save committed (before read-back judgment) — the progress feed.
    var committedConversions: Int = 0
    /// Conversions this page's read-back verified (the `converted*` buckets' page total).
    var verifiedConversions: Int = 0
    /// The pass must abort (F6/F9/F10a/F10b/F11).
    var abort: Bool = false

    /// Records one outcome for `column`.
    mutating func tally(_ column: SealedColumnIdentifier, _ mutate: (inout SealedColumnMigrationTally) -> Void) {
        var tally = tallies[column] ?? SealedColumnMigrationTally()
        mutate(&tally)
        tallies[column] = tally
    }
}

/// The per-page convert engine — a caseless namespace of static steps so the page's
/// `performAndWait` closure captures only Sendable inputs. Everything here runs synchronously
/// on the migration context's queue, inside one page's `autoreleasepool`.
nonisolated enum SealedColumnPageWorker {
    /// One staged conversion: the held old bytes (the restore ledger — the 2.5 held-bytes
    /// pattern), the proven-in-memory new blob, and the rung that opened the original.
    struct LedgerEntry {
        let row: NSManagedObject
        let column: SealedColumnIdentifier
        let oldBlob: Data
        let newBlob: Data
        let originRung: ColumnCrypto.SealedColumnOpenRung
    }

    /// The whole page: process → save → hooks → prune → read-back → refault.
    static func run(
        ids: [NSManagedObjectID],
        entity: SealedEntityColumns,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        context: NSManagedObjectContext,
        preSaveHook: ((NSManagedObjectContext) -> Void)?,
        postSaveHook: ((NSManagedObjectContext) -> Void)?,
        restoreSaveOverride: ((NSManagedObjectContext) throws -> Void)?
    ) -> SealedColumnPageOutcome {
        var outcome = SealedColumnPageOutcome()
        let rows = ids.map(context.object(with:))
        var ledger: [LedgerEntry] = []
        for row in rows {  // R2: bounded by the page.
            processRow(row, entity: entity, crypto: crypto, pageKey: pageKey, ledger: &ledger, outcome: &outcome)
            if outcome.abort { break }
        }
        if outcome.abort {
            // F6: rollback discards the page's staged conversions; they did not stick, so they
            // tally with the failing column (the F9 rule applied to the sibling abort).
            context.rollback()
            for entry in ledger { outcome.tally(entry.column) { $0.convertFailures += 1 } }
        } else if !ledger.isEmpty {
            preSaveHook?(context)
            savePage(ledger: ledger, context: context, outcome: &outcome)
            if outcome.committedConversions > 0 {
                postSaveHook?(context)
                PrivatePersistentHistoryPruner.pruneBestEffort(context: context, site: "SealedColumnFormatMigrator.page")
                readBack(ledger: ledger, crypto: crypto, pageKey: pageKey, context: context,
                         restoreSaveOverride: restoreSaveOverride, outcome: &outcome)
            }
        }
        for row in rows { context.refresh(row, mergeChanges: false) }  // R2: page-bounded refault.
        return outcome
    }

    /// Classifies and (when legacy/v2) stages one row's ciphertext columns.
    private static func processRow(
        _ row: NSManagedObject,
        entity: SealedEntityColumns,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        ledger: inout [LedgerEntry],
        outcome: inout SealedColumnPageOutcome
    ) {
        for attributeName in entity.ciphertextAttributeNames {  // R2: the static per-entity list.
            let column = SealedColumnIdentifier(entityName: entity.entityName, attributeName: attributeName)
            processColumn(row: row, column: column, crypto: crypto, pageKey: pageKey, ledger: &ledger, outcome: &outcome)
            if outcome.abort { return }
        }
    }

    /// One column value: census-classify, open via the shipping reader's dispatch, convert
    /// through the strict v3 seal with the in-memory round-trip verify (the 2.2 recipe).
    /// `updatedAt` is deliberately never touched — a re-seal is not an edit.
    private static func processColumn(
        row: NSManagedObject,
        column: SealedColumnIdentifier,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        ledger: inout [LedgerEntry],
        outcome: inout SealedColumnPageOutcome
    ) {
        let value = row.value(forKey: column.attributeName)
        switch SealedColumnFormatCensus.classify(value: value, readFrom: row) {
        case .indeterminate:
            outcome.tally(column) { $0.indeterminate += 1 }  // F1
        case .classified(.empty):
            outcome.tally(column) { $0.skippedEmpty += 1 }   // F2
        case .classified(let format):
            guard let data = value as? Data else {
                outcome.tally(column) { $0.indeterminate += 1 }
                return
            }
            do {
                let opened = try crypto.openReportingRung(data, contentKey: pageKey)
                switch opened.rung {
                case .v3:
                    outcome.tally(column) { $0.openedV3 += 1 }
                case .v2, .legacy:
                    stageConversion(row: row, column: column, oldBlob: data, plaintext: opened.plaintext,
                                    rung: opened.rung, crypto: crypto, pageKey: pageKey,
                                    ledger: &ledger, outcome: &outcome)
                }
            } catch is DeviceBindingID.ReadError {
                outcome.tally(column) { $0.bindingReadError += 1 }  // F5: retryable, never "corrupt".
            } catch {
                // F3/F4: opens under no rung — split by marker so the gate reads the right bucket.
                if format.isMarkerAmbiguous {
                    outcome.tally(column) { $0.unopenableMarked += 1 }
                } else {
                    outcome.tally(column) { $0.unopenableUnprefixed += 1 }
                }
            }
        }
    }

    /// Seals one opened legacy/v2 value strictly to v3, verifies the new blob in memory
    /// (byte-identical plaintext, `.v3` rung), and stages it in the page's restore ledger.
    private static func stageConversion(
        row: NSManagedObject,
        column: SealedColumnIdentifier,
        oldBlob: Data,
        plaintext: Data,
        rung: ColumnCrypto.SealedColumnOpenRung,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        ledger: inout [LedgerEntry],
        outcome: inout SealedColumnPageOutcome
    ) {
        let newBlob: Data
        do {
            newBlob = try crypto.sealPlaintextV3Strict(plaintext, contentKey: pageKey)
        } catch is ColumnCrypto.SealedColumnStrictSealError {
            // F6: the binding vanished mid-pass — abort; never fall open to a legacy write.
            outcome.tally(column) { $0.convertFailures += 1 }
            outcome.abort = true
            return
        } catch {
            outcome.tally(column) { $0.convertFailures += 1 }  // Row-local CryptoKit hiccup.
            return
        }
        // Step d, the in-memory verify: the write must replace a proven-openable blob with a
        // proven-openable blob, under the exact key/purpose/binding the read-back will use.
        guard let verified = try? crypto.openReportingRung(newBlob, contentKey: pageKey),
              verified.rung == .v3, verified.plaintext == plaintext else {
            outcome.tally(column) { $0.convertFailures += 1 }  // F7
            return
        }
        ledger.append(LedgerEntry(row: row, column: column, oldBlob: oldBlob, newBlob: newBlob, originRung: rung))
        row.setValue(newBlob, forKey: column.attributeName)
    }

    /// Saves the page under the default `NSErrorMergePolicy` — THE compare-before-write guard:
    /// a conflicting concurrent edit rolls the page back (F8, continue); any other save failure
    /// rolls back and aborts (F9 — a store that will not save will not save the next page).
    private static func savePage(
        ledger: [LedgerEntry],
        context: NSManagedObjectContext,
        outcome: inout SealedColumnPageOutcome
    ) {
        do {
            try context.saveSealed()
            outcome.committedConversions = ledger.count
        } catch {
            context.rollback()
            let nsError = error as NSError
            let isConflict = nsError.domain == NSCocoaErrorDomain && nsError.code == NSManagedObjectMergeError
            for entry in ledger {  // R2: page-bounded.
                if isConflict {
                    outcome.tally(entry.column) { $0.skippedConcurrentlyModified += 1 }
                } else {
                    outcome.tally(entry.column) { $0.convertFailures += 1 }
                }
            }
            if !isConflict { outcome.abort = true }
        }
    }

    /// The verified read-back (design step 5): refresh-to-fault, re-read, and DISCRIMINATE —
    /// deleted ⇒ indeterminate (never restored); superseded-and-opens ⇒ concurrent legitimate
    /// write (kept, never restored); bytes-equal-unopenable ⇒ F10a restore+abort; bytes-differ-
    /// open-nowhere ⇒ F10b compare-guarded restore+abort. The refresh has just synchronized the
    /// row snapshot to whatever committed last, so an undiscriminated restore would PASS
    /// optimistic locking and silently clobber a fresher user edit — the exact hazard the
    /// merge-policy choice exists to prevent.
    private static func readBack(
        ledger: [LedgerEntry],
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        context: NSManagedObjectContext,
        restoreSaveOverride: ((NSManagedObjectContext) throws -> Void)?,
        outcome: inout SealedColumnPageOutcome
    ) {
        for entry in ledger {  // R2: page-bounded.
            context.refresh(entry.row, mergeChanges: false)
            let value = entry.row.value(forKey: entry.column.attributeName)
            switch SealedColumnFormatCensus.classify(value: value, readFrom: entry.row) {
            case .indeterminate:
                // F10d: deleted mid-window — a deliberate deletion (delete-all's purge included)
                // is never restored; the held bytes cannot resurrect wiped rows.
                outcome.tally(entry.column) { $0.indeterminate += 1 }
            case .classified(.empty):
                // A concurrent legitimate write cleared the column (the repositories nil an
                // emptied optional column). The editor's committed state wins; never restored.
                outcome.tally(entry.column) { $0.skippedConcurrentlyModified += 1 }
            case .classified:
                guard let found = value as? Data else {
                    outcome.tally(entry.column) { $0.indeterminate += 1 }
                    continue
                }
                judgeReadBackBytes(found, entry: entry, crypto: crypto, pageKey: pageKey,
                                   context: context, restoreSaveOverride: restoreSaveOverride, outcome: &outcome)
            }
            if outcome.abort { return }
        }
    }

    /// Steps 5b/5c: judge the found bytes against the ledger entry, funding a restore only for
    /// the two unopenable outcomes.
    private static func judgeReadBackBytes(
        _ found: Data,
        entry: LedgerEntry,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        context: NSManagedObjectContext,
        restoreSaveOverride: ((NSManagedObjectContext) throws -> Void)?,
        outcome: inout SealedColumnPageOutcome
    ) {
        do {
            let opened = try crypto.openReportingRung(found, contentKey: pageKey)
            if found == entry.newBlob, opened.rung == .v3 {
                // The clean read-back: byte-equality AND a v3 open. Only now does it count.
                outcome.tally(entry.column) { mutable in
                    switch entry.originRung {
                    case .v2: mutable.convertedFromV2 += 1
                    case .legacy(markerCollision: .some): mutable.convertedFromLegacyCollided += 1
                    case .legacy(markerCollision: .none): mutable.convertedFromLegacyUnprefixed += 1
                    case .v3: mutable.openedV3 += 1  // Unreachable: v3 rows never enter the ledger.
                    }
                }
                outcome.verifiedConversions += 1
            } else {
                // F10s: a concurrent legitimate write superseded the migrator's blob (the
                // editor's save is V3-born and wins). Kept, never restored, unproven-not-healed.
                outcome.tally(entry.column) { $0.skippedConcurrentlyModified += 1 }
            }
        } catch is DeviceBindingID.ReadError {
            // The retryable keychain outage, not an authentication verdict: no restore (the
            // committed bytes may be fine), no abort — the bucket blocks the latch and the next
            // pass retries.
            outcome.tally(entry.column) { $0.bindingReadError += 1 }
        } catch {
            // F10a (bytes equal, unopenable: environment break) or F10b (bytes differ, open
            // under no rung: corruption) — the only two outcomes the held old bytes fund.
            restore(entry: entry, observedUnopenable: found, crypto: crypto, pageKey: pageKey,
                    context: context, restoreSaveOverride: restoreSaveOverride, outcome: &outcome)
        }
    }

    /// The compare-guarded compensating restore (design step 6), then abort. A write landing in
    /// the guard's gap wins and the row reclassifies as the superseded case.
    private static func restore(
        entry: LedgerEntry,
        observedUnopenable: Data,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        context: NSManagedObjectContext,
        restoreSaveOverride: ((NSManagedObjectContext) throws -> Void)?,
        outcome: inout SealedColumnPageOutcome
    ) {
        // The compare guard: re-read immediately before writing; proceed only if the column
        // still holds the unopenable bytes just observed.
        let recheck = entry.row.value(forKey: entry.column.attributeName) as? Data
        guard !entry.row.isDeleted, entry.row.managedObjectContext != nil else {
            outcome.tally(entry.column) { $0.indeterminate += 1 }
            return
        }
        guard recheck == observedUnopenable else {
            outcome.tally(entry.column) { $0.skippedConcurrentlyModified += 1 }
            return
        }
        entry.row.setValue(entry.oldBlob, forKey: entry.column.attributeName)
        var attemptsMade = 0
        var saveError: (any Error)?
        while attemptsMade < SealedColumnFormatMigrator.restoreSaveAttempts {  // R2: the named bound.
            attemptsMade += 1
            do {
                if let restoreSaveOverride {
                    try restoreSaveOverride(context)
                } else {
                    try context.saveSealed()
                }
                saveError = nil
                break
            } catch {
                saveError = error
                let nsError = error as NSError
                if nsError.domain == NSCocoaErrorDomain && nsError.code == NSManagedObjectMergeError {
                    // A write landed in the gap and won: rollback, reclassify as superseded.
                    context.rollback()
                    outcome.tally(entry.column) { $0.skippedConcurrentlyModified += 1 }
                    return
                }
            }
        }
        if saveError != nil {
            // F11: the invariant is honestly forfeited for this row, bounded to the
            // store-failure case, and recorded loudly. Never silent.
            context.rollback()
            outcome.tally(entry.column) { $0.readBackFailed += 1; $0.restoreFailed += 1 }
            outcome.abort = true
            FernletAuditLog.log("sealedColumn.readBackFailedRestoreFailed", context: [
                "entity": entry.column.entityName, "column": entry.column.attributeName
            ])
            return
        }
        finishRestore(entry: entry, crypto: crypto, pageKey: pageKey, context: context, outcome: &outcome)
    }

    /// Verifies the committed restore (byte-equality is the proof; the original-rung open is
    /// best-effort evidence — a genuinely broken environment cannot re-open a v2 blob, and the
    /// restore's promise is that the old bytes are back), records it, and aborts the pass.
    private static func finishRestore(
        entry: LedgerEntry,
        crypto: ColumnCrypto,
        pageKey: SymmetricKey,
        context: NSManagedObjectContext,
        outcome: inout SealedColumnPageOutcome
    ) {
        context.refresh(entry.row, mergeChanges: false)
        let restored = entry.row.value(forKey: entry.column.attributeName) as? Data
        let bytesBack = restored == entry.oldBlob
        let reopened = (try? crypto.openReportingRung(entry.oldBlob, contentKey: pageKey))?.rung == entry.originRung
        outcome.tally(entry.column) { $0.readBackFailed += 1; $0.restoredOldBlob += 1 }
        outcome.abort = true
        FernletAuditLog.log("sealedColumn.readBackFailedRestored", context: [
            "entity": entry.column.entityName,
            "column": entry.column.attributeName,
            "restoredVerified": "\(bytesBack)",
            "reopensUnderOriginalRung": "\(reopened)"
        ])
    }
}
