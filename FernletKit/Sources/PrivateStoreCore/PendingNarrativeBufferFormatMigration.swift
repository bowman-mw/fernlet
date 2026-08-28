// PendingNarrativeBufferFormatMigration.swift
// Fernlet
//
// Phase 2.4 of Docs/Plan-Crypto-Standardization-2026-08-27.md for the `PendingNarrativeBuffer`
// surface: the scan → convert → latch format migrator that drives the census's `legacyCount` to
// zero so Phase 3 can delete the read-only legacy branch in `PendingNarrativeBuffer.loadEntries()`.
//
// The scan IS the census (`PendingNarrativeBufferFormatCensus.take(of:)`) — same code, so the
// buckets can never disagree with the number Phase 3 is gated on. The convert step goes through
// the buffer's own `decodeEntries`/`saveEntries` halves, so the migrator binds the existing
// registered `pendingNarrativeBufferV2` purpose without adding a crypto call shape of its own —
// and it runs on the BUFFER key (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`), gated on
// nothing but "device unlocked once since boot": never behind the Fernlet app lock and never
// behind the period-visibility gate, because the buffer exists to accept writes while both are
// closed, and a migrator gated on either would structurally never run for exactly the users
// still holding legacy bytes.

import Foundation
import FernletCrypto
import FernletFoundation

/// The persisted "the pending-narrative buffer file on this device holds no legacy-format bytes"
/// latch (crypto-standardization Phase 2.4).
///
/// ATTESTS: a pass proved the buffer file was absent, empty, or `FNB2`-marked, or was converted
/// and read back. Because the surface is TRANSIENT — the drain path deletes the file after a
/// successful unlock-and-drain — `absent` is an *earned* zero, not a vacuous one: the census makes
/// the identical call, and the lifecycle can only re-create the file through `saveEntries`, which
/// writes v2 unconditionally. So a device that drains its legacy buffer before the migrator ever
/// runs latches honestly on an absent file, and the latch stays true when a fresh v2 buffer is
/// later born.
///
/// DOES NOT ATTEST the Phase-3 gate — that gate is the census reading zero on a real upgraded
/// device, never this bit; the latch exists only to stop re-funding passes and can never license
/// anything. Deliberately NOT invalidated by `FernletLockService.reset()` or the hide-period
/// purge: both destroy the buffer file, so the latch's statement stays true. Cleared by the
/// delete-all funnel (inside the `pendingNarrativeBufferPurgeHook` closure), because the purge
/// destroys the latch's subject in the same closure and tolerates failure — a kept latch would
/// keep claiming clean over a file the purge failed to remove. Wipe wall:
/// `Docs/PrivacyWipeCoverage.md` + `PersistedSurfaceWipeBoundaryTests`, same commit as this key.
///
/// Honest residual: a device-to-device transfer or other filesystem-level copy can carry a legacy
/// buffer file (backup-excluded since the v1 writer, so backups essentially never did), drop the
/// `ThisDeviceOnly` buffer key, and carry a possibly-true latch in UserDefaults. The transferred
/// file arrives unopenable under any key, so the stale latch changes no outcome: an unlatched
/// migrator would block forever on the same bytes, the drain fails identically forever, the
/// legacy reader still exists until Phase 3, and the census — which never consults this latch —
/// reports `.legacyUnprefixed` and blocks Phase 3 for exactly that device.
///
/// Device-local (`UserDefaults`, never synced): the claim is about THIS device's bytes.
/// Concurrency: `nonisolated` value type over `UserDefaults` (itself thread-safe), as the
/// `FormatMigrationLatching` family expects.
public nonisolated struct PendingNarrativeBufferMigrationLatch: FormatMigrationLatching {
    /// The `UserDefaults` key holding the latch. A `static let` literal so the wipe wall's
    /// discovery scan finds it (the `OwnPhotoMigrationLatch` shape, byte for byte).
    public static let defaultsKey = "com.fernlet.private-store.pendingNarrativeBufferMigrationComplete"

    private let defaults: UserDefaults

    /// Creates a latch over `defaults`; tests inject an isolated suite so they never touch the
    /// device's real completion state.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a full clean pass has proven the buffer file holds no legacy-format bytes.
    /// Absent (never set) reads as false — the fail-closed direction.
    public var isComplete: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Records completion. Called ONLY from `FormatMigrator.run(maxPasses:)` after a clean pass;
    /// never from a UI path, and never speculatively.
    public func markComplete() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Clears the latch, forcing a re-scan on the next run. For tests, and for the delete-all
    /// funnel's `pendingNarrativeBufferPurgeHook` closure, which destroys the latch's subject.
    public func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// One migration pass's tally — and, through ``isClean``, the sole authority on whether the
/// completion latch may be set.
///
/// All buckets are 0-or-1 on this surface (one file per scope), and every existing classified
/// file lands in exactly one outcome bucket beside its ``examined`` tick.
///
/// Conforms to `FormatMigrationPassResult`: ``isClean`` and ``madeForwardProgress`` are the two
/// verdicts the shared `FormatMigrator.run(maxPasses:)` loop reads; the buckets below are this
/// migration's own diagnostic breakdown.
public nonisolated struct PendingNarrativeBufferMigrationResult: Sendable, Equatable,
                                                                 FormatMigrationPassResult {
    /// A file existed and was classified (0 or 1). Diagnostic only — ``isClean`` never reads it;
    /// an absent file (the earned zero) tallies 0 here while still being a clean pass.
    public let examined: Int
    /// Census `.v2Marked`, or the convert's defensive re-check found `FNB2` already there. The
    /// `.empty` reading is deliberately NOT counted here — an empty file is legacy-free by the
    /// reader's own short-circuit, but it is not the migration target, so it ticks only
    /// ``examined``.
    public let alreadyCurrent: Int
    /// Legacy → v2 by THIS pass: re-sealed AND read back verified. Non-zero means the corpus was
    /// not clean when the pass started, so the latch waits for a confirming pass.
    public let converted: Int
    /// The seal threw, or the read-back verify failed. Blocks THIS pass only: a `.readBackFailed`
    /// file was sealed under the pinned key this pass held, so the next launch re-classifies it
    /// `.v2Marked` by marker and latches census-only.
    public let convertFailures: Int
    /// Bytes READ, key IN HAND, and nothing opens or decodes them. BLOCKS the latch — a named
    /// deviation from `OwnPhotoKeyMigrationResult.unopenable`'s non-blocking rule, by that rule's
    /// own test: this surface's read path does NOT resolve such bytes to nil (`loadEntries()`
    /// throws, the drain logs and keeps the file), and the census counts the same bytes as
    /// `.legacyUnprefixed` — a latch over them would report "complete" while the actual Phase-3
    /// gate still reads 1.
    public let unconvertible: Int
    /// Census `.unreadable`, the convert's own raw-read failure, or the buffer key unavailable
    /// through the non-minting load. Blocks the latch — "I could not look" must never read the
    /// same as "I looked and it was clean".
    public let indeterminate: Int

    /// Whether this pass PROVES the surface is fully migrated: it converted nothing, failed
    /// nothing, and could classify everything. The only state that may set the latch.
    public var isClean: Bool {
        converted == 0 && convertFailures == 0 && unconvertible == 0 && indeterminate == 0
    }

    /// Whether this pass converted the file — the forward-progress verdict the shared run loop
    /// uses to decide between "confirm with another pass" and "stop, retry next launch".
    public var madeForwardProgress: Bool { converted > 0 }

    /// Creates a result. Public (with zero defaults) so tests can build expectations; production
    /// values come from ``PendingNarrativeBufferFormatMigrator/performPass()``.
    public init(
        examined: Int = 0,
        alreadyCurrent: Int = 0,
        converted: Int = 0,
        convertFailures: Int = 0,
        unconvertible: Int = 0,
        indeterminate: Int = 0
    ) {
        self.examined = examined
        self.alreadyCurrent = alreadyCurrent
        self.converted = converted
        self.convertFailures = convertFailures
        self.unconvertible = unconvertible
        self.indeterminate = indeterminate
    }
}

/// The Phase 2.4 `FormatMigrator` conformer: converts a pre-`91c3956` bare-box pending-narrative
/// buffer file to `FNB2`+AAD in bounded, resumable, idempotent passes.
///
/// **Scan = the census.** `performPass()` classifies by calling
/// `PendingNarrativeBufferFormatCensus.take(of:)` — the census IS "what `loadEntries()` will
/// decide", byte for byte, so migrator/census disagreement is impossible by construction (the
/// 2⁻³² nonce-spells-`FNB2` collision included: such a file is classified v2 and skipped, exactly
/// as the shipping reader misreads it). **Convert = the buffer's own paths.** A legacy file is
/// opened and re-sealed through `PendingNarrativeBuffer.convertLegacyFileToCurrentFormat()`,
/// which pins one key value end to end and reuses the shipping decode/seal halves — zero new
/// purposes, zero new crypto call sites, zero new `cryptographic-domain` markers.
///
/// **Never deletes, never drains.** The only write on any path is the convert's atomic replace
/// of a file whose plaintext was fully recovered and verified; corrupt bytes are classified
/// `unconvertible`, left byte-identical, and block the latch — consistent with the drain, which
/// throws, audit-logs, and keeps the file. Clean passes never touch the keychain at all: a
/// `.v2Marked` file latches by marker alone.
///
/// Concurrency: `@MainActor` with an ISOLATED conformance (`: @MainActor FormatMigrator`) — the
/// deliberate opposite of `OwnPhotoKeyMigrator`'s detached shape, and compile-enforced rather
/// than asked for in a comment. `PendingNarrativeBuffer` is a non-`Sendable` class with no
/// internal locking whose production sibling instance `FernletLockService` (itself `@MainActor`)
/// drives from the main actor; a detached pass could interleave a convert's load→save with a
/// locked-state `append`'s load→save and lose the appended note. Every pass step is synchronous
/// (no suspension points), so main-actor confinement serializes the two instances for free — and
/// copying the adjacent `Task.detached` migrator call-site shape becomes a compile error, not a
/// latent data loss.
@MainActor
public struct PendingNarrativeBufferFormatMigrator: @MainActor FormatMigrator {
    /// The completion latch the shared `FormatMigrator.run(maxPasses:)` loop sets after a clean
    /// pass (a protocol requirement, which is why it is not `private`). The latch TYPE is a
    /// nonisolated value type as the protocol family expects, but this stored property is
    /// main-actor isolated (an isolated witness, legal under the isolated conformance): Swift 6
    /// allows `nonisolated` on a stored property only for `Sendable` types, and `UserDefaults` —
    /// the latch's one member — is not `Sendable` in this SDK.
    public let latch: PendingNarrativeBufferMigrationLatch

    /// R2: the named maximum number of sweep passes the shared `run(maxPasses:)` funds — one to
    /// convert the one file, one to confirm by census. `nonisolated` so the protocol extension's
    /// default argument reads it. No argument for more exists on a 0-or-1-file corpus.
    nonisolated public static let maxMigrationPasses = 2

    /// The buffer's storage identity — the census's input, carried whole so classification can
    /// never drift onto a file the buffer would not read.
    private let scope: PendingNarrativeStorageScope
    /// The convert seam: a second handle over the same scope as the lock service's production
    /// instance, safe because every call into either is serialized on the main actor.
    private let buffer: PendingNarrativeBuffer

    /// Creates a migrator over one storage scope — the test seam; production callers use
    /// ``standard(defaults:)``.
    public init(scope: PendingNarrativeStorageScope, latch: PendingNarrativeBufferMigrationLatch) {
        self.scope = scope
        self.latch = latch
        self.buffer = PendingNarrativeBuffer(scope: scope)
    }

    /// The production migrator: the `.production` scope, latch on `defaults` (injectable — the
    /// lesson 2.1 recorded as its P10 residual, taken at design time here).
    public static func standard(defaults: UserDefaults = .standard) -> PendingNarrativeBufferFormatMigrator {
        PendingNarrativeBufferFormatMigrator(scope: .production, latch: latch(defaults: defaults))
    }

    /// The completion latch over `defaults` — the same one ``standard(defaults:)`` uses, exposed
    /// so a caller (the delete-all funnel's hook closure) can reach the latch without building a
    /// migrator.
    public static func latch(defaults: UserDefaults = .standard) -> PendingNarrativeBufferMigrationLatch {
        PendingNarrativeBufferMigrationLatch(defaults: defaults)
    }

    // MARK: - The pass

    /// Census take → convert if legacy → tally. Never sets the latch — `run(maxPasses:)` owns
    /// that decision — so tests can drive passes directly and assert idempotence.
    ///
    /// A pass over an `.absent`, `.empty`, or `.v2Marked` file never opens the file body and
    /// never fetches the key: fetching would mint, a keychain WRITE on a read-only pass. That
    /// census-only pass is also — deliberately — what follows a read-back failure: marker
    /// classification IS the census's and `loadEntries()`'s own rule, and openability was
    /// attested by the seal-under-pinned-key the failing pass itself performed.
    ///
    /// - Returns: the pass tally, which carries the pass's failure information. R7: not
    ///   `@discardableResult`.
    ///
    /// The `@MainActor` is explicit, not left to the struct annotation, because the witnessed
    /// requirement lives on a `nonisolated protocol` and witness inference would otherwise flip
    /// this member nonisolated — silently un-serializing the pass from the lock service's buffer
    /// instance, the exact lost-update the isolated conformance exists to forbid.
    @MainActor public func performPass() -> PendingNarrativeBufferMigrationResult {
        let census = PendingNarrativeBufferFormatCensus.take(of: scope)
        let result: PendingNarrativeBufferMigrationResult
        switch census.format {
        case .absent:
            // The earned zero: the drain-and-purge lifecycle legitimately produces it, and the
            // census scores it as real evidence of no legacy bytes.
            result = PendingNarrativeBufferMigrationResult()
        case .empty:
            // Legacy-free by the reader's own `isEmpty` short-circuit; left alone, never deleted.
            result = PendingNarrativeBufferMigrationResult(examined: 1)
        case .v2Marked:
            result = PendingNarrativeBufferMigrationResult(examined: 1, alreadyCurrent: 1)
        case .unreadable:
            result = PendingNarrativeBufferMigrationResult(examined: 1, indeterminate: 1)
        case .legacyUnprefixed:
            result = convertTally()
        }
        logPassOutcome(result)
        return result
    }

    // MARK: - Convert plumbing

    /// Maps the buffer's convert outcome onto the pass tally — the design table's
    /// `.legacyUnprefixed` row: `examined 1` plus exactly one outcome bucket.
    private func convertTally() -> PendingNarrativeBufferMigrationResult {
        switch buffer.convertLegacyFileToCurrentFormat() {
        case .converted:
            return PendingNarrativeBufferMigrationResult(examined: 1, converted: 1)
        case .alreadyCurrent:
            return PendingNarrativeBufferMigrationResult(examined: 1, alreadyCurrent: 1)
        case .unreadable, .keyUnavailable:
            // "Could not look" — a raw-read failure or a nil from the non-minting key load,
            // which cannot distinguish a locked keychain from a lost row. Never "corrupt".
            return PendingNarrativeBufferMigrationResult(examined: 1, indeterminate: 1)
        case .openedUnderNeither:
            return PendingNarrativeBufferMigrationResult(examined: 1, unconvertible: 1)
        case .writeFailed, .readBackFailed:
            return PendingNarrativeBufferMigrationResult(examined: 1, convertFailures: 1)
        }
    }

    /// Names every non-no-op pass outcome in the audit log — the non-silence D3 asks for, carried
    /// by the ledger that already exists rather than by UI: any visible state here would announce
    /// that locked-period logging exists and has content, on a surface the user may have hidden.
    private func logPassOutcome(_ result: PendingNarrativeBufferMigrationResult) {
        if result.converted > 0 {
            FernletAuditLog.log("buffer.formatMigrated")
        }
        if result.convertFailures > 0 {
            FernletAuditLog.log("buffer.formatMigrationBlocked", context: ["bucket": "convertFailures"])
        }
        if result.unconvertible > 0 {
            FernletAuditLog.log("buffer.formatMigrationBlocked", context: ["bucket": "unconvertible"])
        }
        if result.indeterminate > 0 {
            FernletAuditLog.log("buffer.formatMigrationBlocked", context: ["bucket": "indeterminate"])
        }
    }
}
