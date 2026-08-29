// LockWrapFormatMigration.swift
// Fernlet
//
// Phase 2.5 of Docs/Plan-Crypto-Standardization-2026-08-27.md — the scan → convert → latch format
// migrator for the app lock's scrypt-wrapped content key (`LockKeychainKey.wrappedContentKey`),
// the LOCKOUT SURFACE: this one keychain row is the single object between the user and every
// sealed corpus. The governing invariant every step below is subordinated to:
//
//   At every instant — including mid-crash at any step — the live row holds a wrap that the next
//   passcode unlock can open. The row is never absent, never empty, and never holds bytes that
//   were not first proven (in memory, and for the promote, proven through a keychain round trip)
//   to unwrap byte-identically to the live content key.
//
// The convert is stage-and-prove on a sibling row (`wrappedContentKeyRewrapStaging`), then a
// single transactional `SecItemUpdate` promote — never a delete-then-add of the live row, whose
// two-transaction shape has a real row-absent crash window (see `KeychainItem.store`). The sole
// wrap writer is the shipping `wrapContentKey` behind the provider seam: zero new purposes, zero
// new derivations, zero new ChaChaPoly call shapes. Classification is single-sourced in
// `LockWrapFormatCensus.classify`, over the migrator's injected read, so migrator and census can
// never disagree — and the fail-closed read stays forceable by tests (the census file's own
// "a fail-closed read is only as trustworthy as the test that forces it to fail" rationale).

import Foundation
import FernletCrypto
import FernletFoundation
import Security

// MARK: - Latch

/// The Phase 2.5 completion latch — DERIVED, not stored: **the row is the latch** (the recorded
/// family deviation for this surface).
///
/// `isComplete` re-reads the live row and classifies its marker through the shared census
/// classifier, so the latch predicate and the reset predicate are the same marker read —
/// observation beats memory, taken to its limit. A persisted bit would buy nothing here (the scan
/// it would short-circuit is ONE `SecItemCopyMatching`, the same cost as reading the bit) and
/// could only ever desync from the row (a same-device restore or a `rollBackCredentialRecords`
/// put-back can legitimately re-introduce a legacy wrap, which this latch observes automatically
/// on the next read). No `UserDefaults` key ⇒ no wipe-wall disposition rows owed.
///
/// ``markComplete()`` and ``reset()`` are documented no-ops: the pass itself already wrote the
/// record — the `FLW2` marker on the row — and there is nothing else to set or clear.
///
/// `nonisolated` (overriding this module's MainActor default): a pure keychain read with no
/// shared state, as the `FormatMigrationLatching` family expects. The held closure values are
/// nonisolated Security calls (the census's own `loadingRow` idiom).
public nonisolated struct LockWrapRowLatch: FormatMigrationLatching {
    /// The keychain service the latch's one row lives under.
    let keychainService: String
    /// The row read the latch derives from — the SAME `(LockKeychainKey, String)` seam shape the
    /// service and migrator use, so the service can hand its own injected
    /// `keychainLoadDistinguishing` straight in and latch, S0, and custody observe ONE keychain
    /// in tests and production alike. `nil` means the real
    /// `KeychainItem.loadDistinguishingAbsence`.
    let loadingRow: ((LockKeychainKey, String) -> KeychainItem.ReadResult)?

    /// Creates a latch over `keychainService`; `loadingRow` injects the row read (nil = the real
    /// keychain read).
    public init(
        keychainService: String,
        loadingRow: ((LockKeychainKey, String) -> KeychainItem.ReadResult)? = nil
    ) {
        self.keychainService = keychainService
        self.loadingRow = loadingRow
    }

    /// Whether the row proves there is nothing left to convert, derived from the row's own marker
    /// through the shared census classifier: `v2Marked` and `absent` are complete (converted, or
    /// nothing to convert — all three absent readings are honestly "no legacy wrap here");
    /// `legacyUnprefixed`, `malformedEmpty` and `unreadable` are incomplete — "could not look"
    /// never reads as "clean" (the fail-closed direction).
    public var isComplete: Bool {
        let read = loadingRow ?? { key, service in
            KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: service)
        }
        switch LockWrapFormatCensus.classify(read(.wrappedContentKey, keychainService)) {
        case .absent, .v2Marked:
            return true
        case .legacyUnprefixed, .malformedEmpty, .unreadable:
            return false
        }
    }

    /// Deliberate no-op: the pass itself already wrote the record — the `FLW2` marker on the
    /// row. There is nothing else to set.
    public func markComplete() {}

    /// Deliberate no-op: nothing is stored to clear; the next read re-derives the truth from
    /// the row.
    public func reset() {}
}

// MARK: - Pass result

/// One Phase 2.5 migration pass's tally over the single-row corpus — and, through ``isClean``,
/// the sole authority on whether the shared `run(maxPasses:)` loop may report completion.
///
/// The corpus is exactly one keychain row, so every bucket is 0 or 1 and exactly one non-zero
/// bucket describes the pass. `nonisolated` `Sendable` value type, as the
/// `FormatMigrationPassResult` family expects.
public nonisolated struct LockWrapMigrationResult: Sendable, Equatable, FormatMigrationPassResult {
    /// Rows the pass found and looked at: 1 when the slot held bytes (or refused to answer),
    /// 0 when the slot was positively absent — there was no row to examine.
    public let examined: Int
    /// The row is already `FLW2`-marked — nothing to do.
    public let alreadyCurrent: Int
    /// Legacy → `FLW2` by THIS pass: staged, round-trip proven, promoted in one transaction, and
    /// read back from the live row.
    public let converted: Int
    /// The row is absent (no lock configured, hard-bound to the Secure Enclave, or a missing
    /// wrap) — an earned not-applicable, never a failure.
    public let notApplicable: Int
    /// Any S1–S7 failure: the legacy wrap is left standing and the next passcode unlock retries.
    public let failed: Int
    /// `malformedEmpty` or `unreadable` — blocking and unconvertible: "could not look" must
    /// never read as clean.
    public let indeterminate: Int

    /// Whether this pass PROVES the corpus is fully migrated: nothing converted, nothing failed,
    /// everything classifiable. The only state that may report completion.
    public var isClean: Bool { converted == 0 && failed == 0 && indeterminate == 0 }

    /// Whether this pass converted the row — the forward-progress verdict the shared run loop
    /// uses to decide between "confirm with another pass" and "stop, retry next unlock".
    public var madeForwardProgress: Bool { converted > 0 }

    /// Creates a result. Public (with zero defaults) so tests can build expectations; production
    /// values come from ``LockWrapFormatMigrator/performPass()``.
    public init(
        examined: Int = 0,
        alreadyCurrent: Int = 0,
        converted: Int = 0,
        notApplicable: Int = 0,
        failed: Int = 0,
        indeterminate: Int = 0
    ) {
        self.examined = examined
        self.alreadyCurrent = alreadyCurrent
        self.converted = converted
        self.notApplicable = notApplicable
        self.failed = failed
        self.indeterminate = indeterminate
    }
}

// MARK: - Migrator

/// The Phase 2.5 `FormatMigrator` conformer: converts the lock's legacy bare-box content-key wrap
/// to `FLW2` via stage-and-prove on a sibling keychain row plus a single transactional
/// `SecItemUpdate` promote.
///
/// **Credential-gated BY CONSTRUCTION.** There is no initializer without the just-recovered
/// content key and the just-derived wrapping key, so no launch task, census caller, or future
/// refactor can ever run a convert at a moment the key is not in hand. The sole production call
/// site is the `.legacyScryptWrapped` arm of `FernletLockService.unlock(passcode:for:)` — hence
/// this phase's recorded family deviation: **no launch pass exists** (the launch-time observation
/// role is already filled by the Phase-0 census row in Settings → Debug).
///
/// **Wrap-key identity by construction.** The convert's one writer is the provider's
/// `wrapContentKey` — the same shipping `FLW2` writer `mintLockRecords` and
/// `rewriteCredentialRecordsAtomically` call — reached through injected closures, so the migrator
/// binds the registered `lockContentKeyWrapV2` purpose without ever naming a purpose, performs
/// zero derivations of its own, and adds zero ChaChaPoly call shapes.
///
/// **Recipe invariant (load-bearing, do not weaken):** every failure handler in S0–S8 is
/// NON-MUTATING with respect to the LIVE row — the sole write any failure path ever performs
/// against `.wrappedContentKey` is S7's restore of the held old wrap, and staging-row deletes are
/// the only other failure-side writes anywhere. No retry, fallback, or future edit may add a
/// live-row write to a failure path: this property is what makes a failed operation and a process
/// death after the preceding operation land in the same keychain end-state, and it is what the
/// crash-window tests lean on. Every keychain touch in the pass — S0's classify read included —
/// flows through the injected seams, never a direct `KeychainItem` or census-public call, so the
/// scripted-failure tests can reach every step.
///
/// Concurrency: `@MainActor` with an ISOLATED conformance (`: @MainActor FormatMigrator`) — the
/// 2.4 pending-narrative-buffer precedent verbatim (that migrator is gone — Phase 3 deleted the
/// legacy reader it healed for — but the isolation shape it established stands). The migrator is
/// built and run
/// inside the service's MainActor unlock tail and holds the service's injected (non-Sendable)
/// closures; every pass step is synchronous, so the whole pass runs without suspension points.
@MainActor
public struct LockWrapFormatMigrator: @MainActor FormatMigrator {
    /// The derived row-latch (a protocol requirement, which is why it is not `private`). The
    /// latch TYPE is the family's nonisolated value type; this stored property is main-actor
    /// isolated (an isolated witness, legal under the isolated conformance — the 2.4 shape).
    public let latch: LockWrapRowLatch

    /// R2: the named maximum number of sweep passes the shared `run(maxPasses:)` funds — one to
    /// convert the one row, one to confirm by marker classification. `nonisolated` so the
    /// protocol extension's default argument reads it.
    nonisolated public static let maxMigrationPasses = 2

    private let keychainService: String
    /// The authoritative, just-unwrapped content key the pass proves every candidate against.
    private let contentKey: Data
    /// The scrypt-derived wrapping key (`computedVerifier`, derived at `storedScryptN()`) — the
    /// exact bytes the next unlock's read will re-derive. Held, never persisted.
    private let wrappingKey: Data
    // @MainActor closure types, deliberately: `FernletLockCryptoProviding` is a @MainActor
    // protocol, so the service's closures capturing `cryptoProvider` are MainActor-isolated and
    // do NOT convert to a nonisolated function type. Legal here because the migrator is itself
    // @MainActor and `performPass()` is explicitly @MainActor — the 2.2/2.4 lesson
    // (signature-level isolation deviations) applied at design time.
    private let wrap: @MainActor (Data, Data) throws -> Data
    private let unwrap: @MainActor (Data, Data) throws -> Data
    private let loadRow: (LockKeychainKey, String) -> KeychainItem.ReadResult
    private let storeRow: (Data, LockKeychainKey, String) -> OSStatus
    private let updateRow: (Data, LockKeychainKey, String) -> OSStatus
    private let deleteRow: (LockKeychainKey, String) -> OSStatus

    /// Creates a migrator for one pass over one keychain service's wrap row.
    ///
    /// Credential-gated BY CONSTRUCTION: there is no init without the recovered content key and
    /// the just-derived wrapping key, so no launch task can ever run a convert.
    ///
    /// - Parameters:
    ///   - keychainService: The keychain service the wrap row lives under.
    ///   - contentKey: The authoritative, just-unwrapped content key.
    ///   - wrappingKey: The scrypt-derived wrapping key the unlock just derived
    ///     (`computedVerifier` at `storedScryptN()`).
    ///   - wrap: The shipping `FLW2` writer behind the provider seam
    ///     (`cryptoProvider.wrapContentKey`).
    ///   - unwrap: The shipping reader behind the provider seam
    ///     (`cryptoProvider.unwrapContentKey`).
    ///   - loadRow: The absence-distinguishing row read (the service's
    ///     `keychainLoadDistinguishing`).
    ///   - storeRow: The status-reporting row store (the service's `keychainStore`;
    ///     delete-then-add is fine for the STAGING row, which is nobody's read dependency).
    ///   - updateRow: The update-only, single-transaction row write the promote uses (the
    ///     service's `keychainUpdate`, default `KeychainItem.updateReportingStatus`).
    ///   - deleteRow: The status-reporting row delete the staging cleanup uses (the service's
    ///     `keychainDelete`, default `KeychainItem.deleteReportingStatus`).
    ///   - latch: The derived row-latch, reading through the SAME seam as `loadRow`.
    public init(
        keychainService: String,
        contentKey: Data,
        wrappingKey: Data,
        wrap: @escaping @MainActor (Data, Data) throws -> Data,
        unwrap: @escaping @MainActor (Data, Data) throws -> Data,
        loadRow: @escaping (LockKeychainKey, String) -> KeychainItem.ReadResult,
        storeRow: @escaping (Data, LockKeychainKey, String) -> OSStatus,
        updateRow: @escaping (Data, LockKeychainKey, String) -> OSStatus,
        deleteRow: @escaping (LockKeychainKey, String) -> OSStatus,
        latch: LockWrapRowLatch
    ) {
        self.keychainService = keychainService
        self.contentKey = contentKey
        self.wrappingKey = wrappingKey
        self.wrap = wrap
        self.unwrap = unwrap
        self.loadRow = loadRow
        self.storeRow = storeRow
        self.updateRow = updateRow
        self.deleteRow = deleteRow
        self.latch = latch
    }

    // MARK: The pass (the §Q2 recipe, S0–S9)

    /// Classify → stage → prove → promote → read back → tally. Never throws (every failure is a
    /// tally bucket) and never sets the latch — `run(maxPasses:)` owns that decision — so tests
    /// can drive passes directly and assert idempotence.
    ///
    /// The `@MainActor` is explicit, not left to the struct annotation, because the witnessed
    /// requirement lives on a `nonisolated protocol` and witness inference would otherwise flip
    /// this member nonisolated (the 2.4 lesson, applied unchanged).
    ///
    /// - Returns: the pass tally, which carries the pass's failure information. R7: not
    ///   `@discardableResult`.
    @MainActor public func performPass() -> LockWrapMigrationResult {
        // S0, first half — pass-local staging hygiene: best-effort delete of any orphan staging
        // row. Failure is tolerated HERE only: the custody-independent unlock-tail sweep (§Q2a)
        // and S8's verified delete own the loud paths, so a status is deliberately not acted on.
        _ = deleteRow(.wrappedContentKeyRewrapStaging, keychainService)

        // S0, second half — classify the live row: the census's internal pure classifier over
        // the migrator's INJECTED read. NEVER the public `inspect(service:)`, which hard-binds
        // the real keychain loader and would make this fail-closed scan untestable.
        let liveRow = loadRow(.wrappedContentKey, keychainService)
        switch LockWrapFormatCensus.classify(liveRow) {
        case .absent:
            // No lock, hard-bound, or a missing wrap — all honestly "no legacy wrap here", and
            // there was no row to examine. A clean, earned no-op.
            return LockWrapMigrationResult(examined: 0, notApplicable: 1)
        case .v2Marked:
            return LockWrapMigrationResult(examined: 1, alreadyCurrent: 1)
        case .malformedEmpty:
            // Unreachable from the production seam (unlock would have thrown at the unwrap
            // before the tail ever ran) — kept for direct-call honesty. Blocking, untouched.
            FernletAuditLog.log("lock.wrapRewrapBlocked", context: ["state": "malformedEmpty"])
            return LockWrapMigrationResult(examined: 1, indeterminate: 1)
        case .unreadable(let status):
            FernletAuditLog.log("lock.wrapRewrapBlocked", context: [
                "state": "unreadable", "status": "\(status)"
            ])
            return LockWrapMigrationResult(examined: 1, indeterminate: 1)
        case .legacyUnprefixed:
            guard case .found(let oldWrap) = liveRow else {
                // Structurally unreachable — `classify` answers `.legacyUnprefixed` only for a
                // `.found` row — but spelled out rather than force-unwrapped (house rule), and
                // fail-closed as indeterminate if it ever were reached.
                return LockWrapMigrationResult(examined: 1, indeterminate: 1)
            }
            return convert(oldWrap: oldWrap)
        }
    }

    // MARK: Convert (S1–S9)

    /// Converts the one legacy row: existing `FLW2` writer → in-memory verify → stage → fresh
    /// staged read-back + unwrap while the legacy wrap still stands → one-transaction promote →
    /// live read-back → restore on mismatch → verified staging delete. Every failure path leaves
    /// the LIVE row holding a wrap the next passcode unlock opens (the recipe invariant).
    @MainActor private func convert(oldWrap: Data) -> LockWrapMigrationResult {
        let failedResult = LockWrapMigrationResult(examined: 1, failed: 1)

        // S1 precondition — the recipe invariant made LOCAL: the legacy bytes this pass is about
        // to supersede must themselves unwrap, under THIS pass's wrapping key, to THIS pass's
        // content key, before a single byte is written anywhere. The production call site proves
        // this by construction (the unlock just performed exactly this unwrap to get here), but a
        // direct caller gets the same guarantee as an executable precondition instead of a
        // whole-codebase writer-census argument. One ChaChaPoly open; any failure leaves the live
        // row untouched.
        guard let oldWrapOpened = try? unwrap(oldWrap, wrappingKey),
              oldWrapOpened == contentKey else {
            return failedResult
        }

        // S1 — the shipping FLW2 writer, verbatim: same wrapping key, zero extra derivations,
        // same registered AAD (stamped inside the writer, never named here).
        let newWrap: Data
        do {
            newWrap = try wrap(contentKey, wrappingKey)
        } catch {
            return failedResult
        }
        // A writer that does not stamp must never be staged: the marker is what the census, the
        // reader, and this migrator all discriminate on.
        guard newWrap.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2) else {
            return failedResult
        }

        // S2 — in-memory verify, byte-identically. Plain `Data` equality, deliberately:
        // constant time is not load-bearing here — both operands are values this pass itself
        // just recovered in this frame, not attacker-timed secrets against stored state.
        guard let inMemoryUnwrapped = try? unwrap(newWrap, wrappingKey),
              inMemoryUnwrapped == contentKey else {
            return failedResult
        }

        // S3 — stage on the sibling row (delete-then-add is fine here: the staging row is
        // nobody's read dependency), status-checked.
        guard storeRow(newWrap, .wrappedContentKeyRewrapStaging, keychainService) == errSecSuccess else {
            deleteStagingRowVerified()
            return failedResult
        }

        // S4 — read the staged row back FRESH and prove the persisted bytes unwrap
        // byte-identically, while the legacy wrap still stands untouched. This is the plan's
        // "read back and verified to unwrap byte-identically", and it proves this exact byte
        // string survives a keychain persistence round trip on this device.
        guard case .found(let stagedBytes) = loadRow(.wrappedContentKeyRewrapStaging, keychainService),
              stagedBytes == newWrap,
              let stagedUnwrapped = try? unwrap(stagedBytes, wrappingKey),
              stagedUnwrapped == contentKey else {
            deleteStagingRowVerified()
            return failedResult
        }

        // S5 — PROMOTE: one `SecItemUpdate` transaction atomically transitions the live row
        // oldWrap → newWrap. `errSecItemNotFound` means the row vanished (impossible
        // synchronously on the MainActor with no suspension points since S0's read; defensive):
        // NEVER fall back to an add — the migrator must never mint custody state. Any failing
        // status leaves the prior value in place (SecItemUpdate semantics), so the live row is
        // still legacy and still opens.
        guard updateRow(newWrap, .wrappedContentKey, keychainService) == errSecSuccess else {
            deleteStagingRowVerified()
            return failedResult
        }

        // S6 — live read-back: what is persisted right now must be the promoted bytes and must
        // unwrap to the identical content key.
        let promoteVerified: Bool
        if case .found(let liveBytes) = loadRow(.wrappedContentKey, keychainService),
           liveBytes == newWrap,
           let liveUnwrapped = try? unwrap(liveBytes, wrappingKey),
           liveUnwrapped == contentKey {
            promoteVerified = true
        } else {
            promoteVerified = false
        }
        guard promoteVerified else {
            // S7 — restore the held old bytes (the ONE live-row write any failure path performs)
            // and say loudly which of the two outcomes actually happened.
            restoreOldWrap(oldWrap)
            deleteStagingRowVerified()
            return failedResult
        }

        // S8 — delete staging, verified with one retry; a stranded orphan is audited loudly
        // (it is a scrypt-openable copy of the content key) and its lifetime is bounded by the
        // custody-independent unlock-tail sweep (§Q2a).
        deleteStagingRowVerified()

        // S9 — done.
        FernletAuditLog.log("lock.wrapRewrittenFLW2")
        return LockWrapMigrationResult(examined: 1, converted: 1)
    }

    /// S7: puts the held legacy bytes back on the live row via the same single-transaction
    /// update, re-reads, and audits whether the restore verified — never silent either way. If
    /// the restore itself fails, the row holds the bytes S5's transaction persisted, whose byte
    /// string S4 proved opens on this keychain (the design's named accepted residual covers the
    /// divergent securityd-integrity case).
    @MainActor private func restoreOldWrap(_ oldWrap: Data) {
        let restoreStatus = updateRow(oldWrap, .wrappedContentKey, keychainService)
        var verified = false
        if restoreStatus == errSecSuccess,
           case .found(let restoredBytes) = loadRow(.wrappedContentKey, keychainService),
           restoredBytes == oldWrap {
            verified = true
        }
        FernletAuditLog.log("lock.wrapRewrapRestoredLegacy", context: ["verified": "\(verified)"])
    }

    /// S8 (and every failure path's staging cleanup): deletes the staging row, verified — on a
    /// non-success status, ONE immediate retry (R2: the bound is this single named retry); if
    /// still failing, audits `lock.wrapRewrapStagingOrphaned` loudly, because the orphan is a
    /// scrypt-openable copy of the content key. The orphan's lifetime is then bounded by the
    /// custody-independent unlock-tail sweep (§Q2a), which runs on every successful passcode
    /// verification under EVERY custody state; `reset()` and the duress responses sweep it too.
    @MainActor private func deleteStagingRowVerified() {
        let firstStatus = deleteRow(.wrappedContentKeyRewrapStaging, keychainService)
        guard firstStatus != errSecSuccess else { return }
        let retryStatus = deleteRow(.wrappedContentKeyRewrapStaging, keychainService)
        guard retryStatus != errSecSuccess else { return }
        FernletAuditLog.log("lock.wrapRewrapStagingOrphaned", context: ["status": "\(retryStatus)"])
    }
}
