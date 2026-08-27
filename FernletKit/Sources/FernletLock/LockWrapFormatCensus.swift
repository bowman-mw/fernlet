// LockWrapFormatCensus.swift
// Fernlet
//
// Phase 0 of Docs/Plan-Crypto-Standardization-2026-08-27.md — the read-only format census for the
// app lock's wrapped content key. Classification is a marker-byte prefix check and nothing else:
// this file never opens a blob, never derives a passcode, never writes or deletes a keychain row,
// and never constructs a `FernletLockService`. "Format census itself decrypts to count" is a named
// risk in that plan (§6); the mitigation is to count by MARKER BYTES only, which is what lives here.

import Foundation
import FernletFoundation
import Security

/// What the census found in the ONE keychain row it inspects — the lock's scrypt-wrapped content
/// key (`LockKeychainKey.wrappedContentKey`, account `com.fernlet.lock.wrappedContentKey`).
///
/// The census answers exactly one question — *what format is the stored wrap in?* — and answers it
/// without opening the blob. Four of the five cases are observations about the row itself; the
/// fifth (``unreadable(_:)``) is the census admitting it does not know, which is the entire reason
/// this type is an enum rather than a count.
///
/// ### `absent` is meaningful, and it means more than one thing
/// An absent row is a finding in its own right, and the lock reads it three different ways (see
/// `FernletLockService.contentKeyCustody()`): **no lock is configured**; the install is
/// **hard-bound to the Secure Enclave** — the scrypt wrap was deleted after a freshly re-read
/// enclave wrap proved it unwraps to the identical key, so the enclave copy is now the only
/// recoverable one; or, on hardware with NO enclave, a configured lock whose wrap has gone missing,
/// which is a fault rather than a custody state. All three are honestly "zero legacy wraps here",
/// which is the only question this census answers. None of them is inferable from the row's absence
/// alone, and the census deliberately does not guess: a caller that needs custody must ask the
/// service, which owns that state machine.
public nonisolated enum LockWrapFormatState: Sendable, Equatable {
    /// The keychain positively reported no row at the census account (`errSecItemNotFound`).
    case absent
    /// The row exists and starts with the four-byte `FLW2` marker `FernletLockCrypto.wrapContentKey`
    /// stamps on every wrap it writes. Post-domain-separation; nothing to migrate.
    case v2Marked
    /// The row exists and does NOT start with the marker: a pre-`FLW2` bare ChaChaPoly combined box
    /// (nonce ‖ ciphertext ‖ tag), sealed with no additional authenticated data. This is the number
    /// Phase 3 must observe at zero before the legacy reader in
    /// `FernletLockCrypto.unwrapContentKey` may be deleted.
    case legacyUnprefixed
    /// The row exists and is EMPTY — zero bytes, which is neither a valid `FLW2` wrap nor a
    /// plausible legacy box (the smallest possible ChaChaPoly combined box is 28 bytes, and one
    /// sealing a 32-byte content key is 60). Bucketed on its own rather than folded into
    /// ``legacyUnprefixed`` because the two demand opposite responses: a legacy row is a migration
    /// candidate a re-wrap can fix, while an empty row is a corrupt slot no migrator can convert
    /// and no reader can open. Folding it into ``v2Marked`` would be worse still — it would report
    /// a broken lock as already standardized. Unreachable through Fernlet's own writers:
    /// `KeychainItem.store` refuses an empty payload with `errSecParam` (R5), so an empty row can
    /// only arrive from outside the house seam or from a corrupted keychain.
    case malformedEmpty
    /// The keychain call failed, carrying its `OSStatus`. The row's existence — and therefore its
    /// format — is UNKNOWN. Never collapse this into ``absent``; see ``LockWrapFormatCensus`` for
    /// what that collapse would cost.
    case unreadable(OSStatus)
}

/// One census result: the slot inspected, and what was found in it.
///
/// Carries the service and account it looked at so a diagnostic surface (the plan's DEBUG
/// Connection Inspector row) can show WHICH slot produced the number — a census reported without
/// its slot is unfalsifiable, and the production slot is only one of many during testing.
public nonisolated struct LockWrapFormatCensusReport: Sendable, Equatable {
    /// The keychain service the row was looked for under (`com.fernlet.lock` in production).
    public let keychainService: String
    /// The keychain account inspected — always ``LockWrapFormatCensus/account``, recorded so the
    /// report is self-describing.
    public let account: String
    /// What was found.
    public let state: LockWrapFormatState

    /// Memberwise init, public so a caller outside the module (a diagnostic view's preview, a
    /// future roll-up that aggregates one report per Class-A surface) can build an expected value.
    public init(keychainService: String, account: String, state: LockWrapFormatState) {
        self.keychainService = keychainService
        self.account = account
        self.state = state
    }

    /// The plan's deliverable — "a number per surface" — for this surface, or `nil` when the census
    /// could not produce one.
    ///
    /// This surface holds at most ONE wrap per lock instance, so the honest number is 0 or 1.
    /// `nil` is the third answer the plan's exit criterion depends on ("**If any count cannot be
    /// produced, stop**"): ``LockWrapFormatState/unreadable(_:)`` obviously cannot be counted, and
    /// neither can ``LockWrapFormatState/malformedEmpty`` — a slot holding bytes no first-party
    /// writer produces is not evidence that no legacy wrap exists, it is evidence that something
    /// went wrong. Reporting either as `0` would hand Phase 3 a green light it did not earn.
    public var legacyWrapCount: Int? {
        switch state {
        case .legacyUnprefixed:
            return 1
        case .absent, .v2Marked:
            return 0
        case .malformedEmpty, .unreadable:
            return nil
        }
    }

    /// Whether the census failed to produce a count — the fail-loud signal a caller must surface
    /// rather than round down to zero.
    public var isIndeterminate: Bool { legacyWrapCount == nil }
}

/// Read-only format census for the app lock's scrypt-wrapped content key.
///
/// Standalone by construction: it takes a keychain service string, reads one generic-password row,
/// and classifies its first four bytes. It never constructs a ``FernletLockService`` (whose init
/// derives lock state, builds the sealed pending-narrative buffer, and touches the private
/// persistence controller — side effects a census has no business causing), never unwraps, and
/// never needs a passcode, a scrypt derivation, or the Secure Enclave.
///
/// ### The one row it counts, and the three it must never touch
/// Four keychain rows under `com.fernlet.lock` can hold content-key material, under three
/// different schemes. Only the first is this census's business; naming the other three here is the
/// point, because conflating them is the easy mistake to make later:
/// - `LockKeychainKey.wrappedContentKey` — **the census target.** ChaChaPoly under the
///   scrypt-derived wrapping key, `FLW2`-marked since domain separation, unmarked before it.
/// - `LockKeychainKey.seWrappedContentKey` — ECIES under the non-exportable Secure Enclave key
///   (`SecureEnclaveContentKeyWrap`). It carries **no marker of any kind**, so the prefix check
///   here would classify every enclave wrap as `legacyUnprefixed` and invent legacy rows that do
///   not exist. Its format story is the enclave's, not this plan's.
/// - `LockKeychainKey.biometricBypass` — the RAW content key behind a `.biometryCurrentSet` access
///   control. There is no wrap format to census, and reading it would raise a Face ID / Touch ID
///   prompt: a census that makes the phone ask the user to authenticate is not a census.
/// - `LockKeychainKey.recoveryBlob` — a digest followed by an opaque custodian-sealed payload. Its
///   leading bytes are a SHA-256 digest, which is exactly the kind of high-entropy prefix a
///   marker check must not be pointed at.
///
/// ### Device lock: `unreadable` is not `absent`, and the difference is the whole point
/// The target row is stored `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`, so while the DEVICE is
/// locked the keychain refuses it with `errSecInteractionNotAllowed` — a real, reachable state for
/// anything that can run in the background. (The APP lock is irrelevant here: the keychain has
/// never heard of `FernletLockState`.) Every read therefore goes through the three-way seam
/// `KeychainItem.loadDistinguishingAbsence`, not the `nil`-collapsing `KeychainItem.load`.
///
/// The stakes are not stylistic. Collapsing "could not read" into "not there" would let this census
/// report **"no legacy wrap"** while a legacy wrap sits in the keychain — and the census is what
/// gates Phase 3, which DELETES the legacy reader. The wrap would then be permanently unopenable
/// and every sealed corpus on that device with it: total lockout, produced by a diagnostic that was
/// only ever supposed to count.
///
/// ### The 2⁻³² caveat
/// A legacy wrap is a bare combined box whose first bytes are a random 96-bit nonce, so it begins
/// with `FLW2` with probability 2⁻³² and is then counted as ``LockWrapFormatState/v2Marked``. This
/// is documented rather than engineered around, for two reasons: the only way to do better is to
/// attempt a decryption, which this census must never do; and the production reader
/// (`FernletLockCrypto.unwrapContentKey`) makes the identical prefix test, so such a blob is
/// already unopenable in the shipping app — the census cannot be more accurate than the format is.
/// One wrap exists per lock instance, so the expected number of affected installs is nil.
///
/// ### Why a census is needed at all
/// A legacy row does not heal itself. Unlocking an install unwraps it in place and rewrites
/// nothing; the row is only replaced (in `FLW2` form) by `configure()` or `changeCredential`, only
/// deleted by the Secure-Enclave hard-binding or a reset, and a rolled-back re-key deliberately
/// restores the PRIOR bytes — legacy ones included. On enclave-less hardware whose owner never
/// changes their passcode, a legacy wrap can therefore live indefinitely.
///
/// `nonisolated`: pure Security-framework reads and byte comparisons with no shared state, callable
/// from any executor (this module defaults to MainActor isolation).
public nonisolated enum LockWrapFormatCensus {
    /// The single keychain account this census inspects, taken from the lock's own key enum rather
    /// than re-spelled, so a renamed account cannot leave the census silently counting a dead slot.
    nonisolated public static let account = LockKeychainKey.wrappedContentKey.rawValue

    /// Inspects the wrapped-content-key row under `service` and reports its format.
    ///
    /// Performs exactly one `SecItemCopyMatching` and no other keychain call — no write, no delete,
    /// no `SecItemAdd` on a missing row. Safe to call against the live production slot.
    ///
    /// - Parameter service: The keychain service to inspect; defaults to the production lock slot.
    ///   Injectable so a test (or a future multi-slot diagnostic) can census an isolated slot
    ///   without going near the real one.
    /// - Returns: The report; ``LockWrapFormatCensusReport/legacyWrapCount`` is the plan's number,
    ///   and `nil` there means the count could not be produced.
    public static func inspect(service: String = KeychainItem.productionService) -> LockWrapFormatCensusReport {
        inspect(service: service, loadingRow: { rowAccount, rowService in
            // `.any` synchronizable scope, matching `FernletLockService`'s own custody read exactly:
            // the census must see the same row the service would act on, and lock rows are written
            // non-synchronizable, so the broad scope cannot pull in a second variant.
            KeychainItem.loadDistinguishingAbsence(account: rowAccount, service: rowService)
        })
    }

    /// ``inspect(service:)`` over an injected row loader — the seam that makes the `unreadable`
    /// branch testable.
    ///
    /// It exists because the statuses that matter most cannot be provoked against a simulator
    /// keychain: `errSecInteractionNotAllowed` needs a locked device and `errSecNotAvailable` needs
    /// a pre-first-unlock boot. The idiom mirrors `FernletLockService`'s own
    /// `keychainLoadDistinguishing` injection, for the same reason — a fail-closed read is only as
    /// trustworthy as the test that forces it to fail.
    ///
    /// - Parameter loadingRow: `(account, service) -> ReadResult`, called at most once.
    static func inspect(
        service: String,
        loadingRow load: (String, String) -> KeychainItem.ReadResult
    ) -> LockWrapFormatCensusReport {
        // R5: an unnamed slot is a caller bug, and nothing was ever filed under one — but report it
        // as indeterminate rather than as a clean absence, so a bad argument can never be read as
        // proof that no legacy wrap exists. (`KeychainItem` makes the same call for the same reason.)
        guard !service.isEmpty else {
            return LockWrapFormatCensusReport(
                keychainService: service,
                account: account,
                state: .unreadable(errSecParam)
            )
        }
        return LockWrapFormatCensusReport(
            keychainService: service,
            account: account,
            state: classify(load(account, service))
        )
    }

    /// Classifies one three-way keychain read into a ``LockWrapFormatState`` — the pure
    /// bytes-to-format mapping, split out so it is reachable without a keychain at all.
    ///
    /// Prefix check only: the marker is compared against `FernletLockCrypto`'s single copy of it,
    /// the one `wrapContentKey` stamps and `unwrapContentKey` matches. No length validation beyond
    /// the empty case — a short-but-non-empty row stays ``LockWrapFormatState/legacyUnprefixed``
    /// because only an unwrap could tell a truncated legacy box from an intact one, and unwrapping
    /// is precisely what this census does not do.
    static func classify(_ row: KeychainItem.ReadResult) -> LockWrapFormatState {
        switch row {
        case .absent:
            return .absent
        case .unreadable(let status):
            return .unreadable(status)
        case .found(let bytes):
            // Load-bearing order: the empty case is checked FIRST, because `Data().starts(with:)`
            // against a non-empty prefix is false and an empty row would otherwise be filed as a
            // legacy wrap a migrator would try — and fail — to re-wrap.
            guard !bytes.isEmpty else { return .malformedEmpty }
            return bytes.starts(with: FernletLockCrypto.wrappedContentKeyFormatV2) ? .v2Marked : .legacyUnprefixed
        }
    }
}
