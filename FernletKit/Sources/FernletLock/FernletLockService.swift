// FernletLockService.swift
// Fernlet
//
// Scrypt KDF via krzyzanowskim/CryptoSwift (https://github.com/krzyzanowskim/CryptoSwift).
// Memory-hard KDF, no PBKDF2 fallback.

import Foundation
import FernletCrypto
import FernletFoundation
import CryptoKit
import Security
import LocalAuthentication
import Combine
import OSLog
import CryptoSwift
import Observation
import Synchronization
import FernletDomainModel
import PrivateStoreCore
import PrivateHealthStore

// MARK: - Public types

/// The app-facing contract for Fernlet's app lock: credential lifecycle, lock/unlock
/// transitions, biometric enablement, and access to the unlocked content key.
///
/// ``FernletLockService`` is the production conformer; test doubles conform in
/// `FernletTests`. The app creates one instance at launch and injects it into the SwiftUI
/// environment, where the `FernletLockUI` gate/setup/unlock views drive it. The protocol
/// refines `PeriodLockContext` (owned by `PrivateHealthStore`) so the sealed period store
/// can buffer narratives while locked without ever naming this module — a deliberately
/// one-directional edge. `@MainActor`: every requirement is UI-adjacent state.
@MainActor
public protocol FernletLockServicing: PeriodLockContext {
    /// The current lock state; drives the gate UI.
    var state: FernletLockState { get }
    /// Combine mirror of ``state`` for subscribers outside the Observation system.
    var statePublisher: AnyPublisher<FernletLockState, Never> { get }
    /// True once failed attempts have exhausted the cooldown ladder; only a destructive
    /// ``reset()`` clears it.
    var requiresReset: Bool { get }
    /// Whether the user has enabled Face ID / Touch ID unlock.
    var biometricEnabled: Bool { get }
    /// The biometry usable on this device right now (`.none` when unavailable).
    var biometricType: LABiometryType { get }
    /// The kind of credential currently configured, or `nil` before setup.
    var credentialKind: FernletLockCredentialKind? { get }
    /// Failed passcode attempts recorded since the last success or cooldown escalation.
    var currentAttemptCount: Int { get }

    /// First-time setup: derives the verifier, mints and wraps the content key, establishes and
    /// verifies the Secure-Enclave wrap — and on enclave hardware deletes the scrypt-wrapped item,
    /// so the install is born HARD-BOUND — then unlocks `grantingScope`, that surface only.
    func configure(credential: FernletLockCredential, grantingScope: FernletLockScope) async throws
    /// Re-keys the credential in place, preserving the content key (no sealed-data loss).
    func changeCredential(current: String, new: FernletLockCredential) async throws
    /// Verifies the passcode, unwraps the content key, and unlocks FOR ONE SURFACE (`scope`).
    func unlock(passcode: String, for scope: FernletLockScope) async throws -> UnlockResult
    /// Recovers the content key from the biometric-gated keychain item and unlocks `scope` only.
    func unlockWithBiometrics(for scope: FernletLockScope) async throws -> UnlockResult
    /// Engages the lock and scrubs the in-memory content key.
    func lock(reason: FernletLockReason)
    /// Revokes an unlock belonging to any surface OTHER than `scope`, so an arriving gated screen
    /// authenticates on its own instead of inheriting someone else's session.
    func revokeUnlockOutside(_ scope: FernletLockScope)
    /// Destroys all lock keychain state AND purges the sealed narrative entities.
    func reset() throws
    /// Enables or disables biometric unlock; enabling requires the current passcode.
    func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws
    /// The unwrapped content key, released only to `.privateHub` while that scope holds the
    /// unlock; `nil` for every other scope and whenever locked.
    func contentKey(for scope: FernletLockScope) -> SymmetricKey?
}

extension FernletLockServicing {
    /// Satisfies the narrow `PeriodLockContext.isLockConfigured` seam without each conformer
    /// reimplementing it: a lock is "configured" once it leaves the `.notConfigured` state.
    public var isLockConfigured: Bool { state != .notConfigured }

    /// The one surface an in-force unlock covers, or nil when locked / not configured.
    public var unlockedScope: FernletLockScope? { state.unlockedScope }

    /// The only "am I revealed?" question a gated surface may ask. Deliberately NOT
    /// `if case .unlocked = state`: an unlock belongs to exactly one surface, so every other
    /// surface must read as locked while that one holds it.
    public func isUnlocked(for scope: FernletLockScope) -> Bool { state.isUnlocked(for: scope) }
}

/// The lockable surfaces, each of which owns its own unlock session.
///
/// An unlock is granted to ONE scope at a time. Before this existed the lock was global: unlocking
/// the progress-photo strip (or the App-lock settings page) left the Private Hub open too, so a user
/// who unlocked one screen, wandered elsewhere in the app, and then opened another locked screen was
/// let straight in — the re-lock only fired on a `.onDisappear` that a covering sheet, a full-screen
/// capture cover or a scene transition could legitimately suppress. Scoping makes the leak
/// structurally impossible: crossing to a different locked surface revokes the unlock (scrubbing the
/// content key) rather than inheriting it.
public enum FernletLockScope: String, CaseIterable, Sendable, Equatable {
    /// The Private tab — journal, period, intimacy, Worry Box. The ONLY scope entitled to the
    /// lock's content key (`contentKey(for:)`), because it is the only one whose data is sealed
    /// under it: progress photos have their own `PrivateMediaKeyStore` key, and App-lock settings
    /// re-derive from the entered passcode.
    case privateHub
    /// The gym progress-photo strip under Move, plus its full-screen photo detail.
    case progressPhotos
    /// Settings → App lock (change passcode, biometrics, reset).
    case appLockSettings
}

/// The three-way lock lifecycle state published by ``FernletLockService``.
///
/// `.locked` carries an optional brute-force cooldown deadline so the unlock UI can show
/// a countdown; a `nil` deadline means locked but immediately attemptable. Observed by
/// the `FernletLockUI` gate and the app's scene-phase re-lock handling.
public enum FernletLockState: Equatable {
    /// No credential has ever been configured (or the lock was reset).
    case notConfigured
    /// Locked; `cooldownDeadline` is non-nil while a failed-attempt cooldown is active.
    case locked(cooldownDeadline: Date?)
    /// Unlocked FOR ONE SURFACE. The scope rides in the state (rather than sitting beside it) so it
    /// can never drift out of step with the unlock, and so `.task(id: lockService.state)` re-runs
    /// when the owning surface changes. The content key is available via
    /// ``FernletLockServicing/contentKey(for:)`` — and only to `.privateHub`.
    case unlocked(scope: FernletLockScope)

    /// The surface an in-force unlock belongs to, or `nil` when locked / not configured.
    public var unlockedScope: FernletLockScope? {
        if case .unlocked(let scope) = self { return scope }
        return nil
    }

    /// Whether the unlock in force is *this* surface's — never merely "some unlock exists".
    public func isUnlocked(for scope: FernletLockScope) -> Bool { unlockedScope == scope }
}

/// The shape of the configured credential, persisted (as its raw string) in the keychain.
///
/// Lets the unlock UI render the right entry surface — a 4- or 6-digit pad versus a
/// password field — without ever touching the secret itself.
public enum FernletLockCredentialKind: String, Codable {
    case pin4, pin6, alphanumeric
}

/// A user-entered lock credential paired with its kind, plus its format validation.
///
/// Passed into ``FernletLockServicing/configure(credential:)`` and
/// ``FernletLockServicing/changeCredential(current:new:)``. Holds the secret only
/// transiently in memory — the service persists a salted scrypt-digest verifier,
/// never the credential itself.
public enum FernletLockCredential {
    case pin4(String)
    case pin6(String)
    case alphanumeric(String)

    /// The ``FernletLockCredentialKind`` matching this case.
    public var kind: FernletLockCredentialKind {
        switch self {
        case .pin4: .pin4
        case .pin6: .pin6
        case .alphanumeric: .alphanumeric
        }
    }

    /// The underlying secret string (PIN digits or password).
    public var rawValue: String {
        switch self {
        case .pin4(let value), .pin6(let value), .alphanumeric(let value): value
        }
    }

    /// Builds a credential of `kind` around an already-entered secret.
    ///
    /// The lock renders exactly ONE entry surface — the pad or field matching the *configured*
    /// ``FernletLockCredentialKind`` — so any secret the user must be able to type there has to
    /// share that kind. The duress PIN is the case in point: a 6-digit duress PIN on a `pin4`
    /// install could never be submitted, because the 4-digit pad auto-submits at four taps. This
    /// initializer is how a caller holding only a kind and a string reaches the enum; it does not
    /// validate — call ``validate()``.
    public init(kind: FernletLockCredentialKind, rawValue: String) {
        switch kind {
        case .pin4: self = .pin4(rawValue)
        case .pin6: self = .pin6(rawValue)
        case .alphanumeric: self = .alphanumeric(rawValue)
        }
    }

    /// Enforces the format rules — exactly 4 or 6 digits for PINs, 8–64 characters for
    /// passwords — throwing `FernletLockError.invalidCredential` otherwise.
    public func validate() throws {
        switch self {
        case .pin4(let value):
            guard value.count == 4, value.allSatisfy(\.isNumber) else {
                throw FernletLockError.invalidCredential("PIN must be exactly 4 digits")
            }
        case .pin6(let value):
            guard value.count == 6, value.allSatisfy(\.isNumber) else {
                throw FernletLockError.invalidCredential("PIN must be exactly 6 digits")
            }
        case .alphanumeric(let value):
            guard value.count >= 8, value.count <= 64 else {
                throw FernletLockError.invalidCredential("Password must be 8-64 characters")
            }
        }
    }
}

/// Why the lock is being engaged; recorded in the audit log, never persisted.
///
/// Callers pass the trigger (sensitive view disappearing, scene backgrounding, device
/// protected-data loss, a manual tap, or attempt exhaustion) to
/// ``FernletLockServicing/lock(reason:)`` so audit entries distinguish routine re-locks
/// from failure-driven ones.
public enum FernletLockReason {
    case viewDisappeared, background, protectedDataUnavailable, manual, failedAttempts
    /// A different locked surface came forward while this unlock was in force. The appearing
    /// surface revokes rather than inherits, so this is the load-bearing re-lock — it fires even
    /// when the departing surface's `onDisappear` never did.
    case scopeChanged

    /// The stable string written to `FernletAuditLog` for this reason.
    var auditLabel: String {
        switch self {
        case .viewDisappeared: "viewDisappeared"
        case .background: "background"
        case .protectedDataUnavailable: "protectedDataUnavailable"
        case .manual: "manual"
        case .failedAttempts: "failedAttempts"
        case .scopeChanged: "scopeChanged"
        }
    }
}

/// How an unlock succeeded — by passcode entry or by biometrics.
///
/// Carried inside ``UnlockResult`` so callers can adapt follow-up behavior (and the
/// audit trail) to the method that was used.
public enum UnlockMethod {
    case passcode, biometric
}

/// The successful outcome of an unlock attempt.
///
/// Returned by ``FernletLockServicing/unlock(passcode:for:)`` and
/// ``FernletLockServicing/unlockWithBiometrics(for:)``; currently records only the
/// ``UnlockMethod`` that succeeded.
public struct UnlockResult {
    /// The method that performed this unlock.
    public let method: UnlockMethod

    /// Creates a result for the given unlock method.
    public init(method: UnlockMethod) {
        self.method = method
    }
}

/// What entering the duress PIN does — exactly one response per configured duress PIN.
///
/// Fernlet stores ONE duress PIN with ONE chosen mode rather than several PINs each mapped to a
/// mode: every configured duress PIN costs one extra scrypt derivation on every unlock, so N PINs
/// would multiply unlock latency by N for a capability nobody asked for.
///
/// Persisted as a single raw byte in ``LockKeychainKey/duressMode``, so the raw values are part of
/// the on-device format and must never be renumbered. A missing or unrecognised byte reads as
/// ``decoy``: fail-closed in BOTH directions — a corrupt row can never escalate into a wipe, and
/// can never fall through into the real unlock either.
///
/// Every mode ends in the same visible outcome (the empty decoy hub) by design. That is the whole
/// point: an observer standing over the user's shoulder must not be able to tell a decoy from a
/// wipe from a recovery-lock, nor any of them from a benign unlock.
public enum DuressMode: UInt8, CaseIterable, Sendable, Equatable {
    /// Non-destructive and fully reversible. The unlock succeeds KEYLESS — no content key is ever
    /// installed — so every sealed surface renders empty, and the real data is untouched and
    /// returns the moment the real passcode is entered.
    case decoy = 0
    /// Destructive: crypto-erase every local key sub-second, re-mint a throwaway lock under the
    /// duress PIN (so the decoy survives a re-lock), present the decoy, then hand the durable purge
    /// of the sealed rows and cloud copies to `FernletLockService.duressPurgeHook`.
    ///
    /// - Warning: Irreversible. The Secure-Enclave key, the biometric bypass and the content key are
    ///   destroyed outright, so every sealed byte on the device — and every copy of it in a backup
    ///   or a dead-drop — becomes permanently unopenable. Off-device ciphertext still EXISTS until
    ///   the background purge or its own age-out reaches it; what the erase guarantees is that no
    ///   one can read it.
    case silentWipe = 1
    /// Destroy the LOCAL unlock keys while keeping the sealed ciphertext plus a recovery blob
    /// sealed to an enrolled custodian device, then present the decoy. The coerced user then
    /// truthfully cannot open the data; recovery is an in-person ceremony with the custodian.
    ///
    /// What survives is the whole mode: `.recoveryBlob` and the custodian's two public keys, the
    /// sealed corpus, the ProximityKit identity keys the return ceremony authenticates with, and
    /// the journal / Worry Box device fallback keys (which no recovery blob could give back). What
    /// does NOT happen is equally deliberate: no throwaway lock is re-minted — the point is that no
    /// local unlock survives — and ``FernletLockService/duressPurgeHook`` never fires, because the
    /// corpus is being kept for the custodian, not deleted.
    ///
    /// - Note: Selectable only once a custodian is enrolled
    ///   (``FernletLockService/hasRecoveryCustodian``), and it fails closed at trigger time too: if
    ///   the recovery material has vanished by then, the non-destructive ``decoy`` is presented
    ///   instead of an unrecoverable destruction the user never chose.
    /// - Warning: If the custodian device is lost, wiped, or has its identity keys rotated, the
    ///   sealed corpus is permanently unopenable. Possession of the custodian device (plus its own
    ///   unlock) IS full recovery capability — a custodian is a second key holder, not an escrow.
    case recoveryLock = 2
}

// MARK: - Cryptographic primitives

/// The lock's raw cryptographic primitives: scrypt passcode derivation, content-key
/// generation and ChaChaPoly wrapping, and the verifier digest.
///
/// A caseless namespace of `nonisolated` statics — pure functions with no state. The
/// scheme: a passcode plus a random salt run through the memory-hard scrypt KDF
/// (CryptoSwift; N=65536, r=8, p=1) to produce the content-key *wrapping* key; that key
/// seals a random 256-bit content key via ChaChaPoly; and only `SHA256(wrappingKey)` is
/// ever persisted, as the verifier (see ``verifierDigest(of:)``). scrypt runs inside
/// `Task.detached` so the main actor never blocks on the memory-hard derivation.
///
/// Narrowed from `public` to module-internal (WI-7, Docs/Security-Hardening-Plan-2026-06-27.md): these
/// key-wrapping/derivation primitives have no callers outside the FernletLock module (only its own
/// provider/service and the crypto unit tests, which `@testable import FernletLock`). Least privilege
/// keeps the lock's raw crypto off the package's public API surface.
enum FernletLockCrypto {
    nonisolated static let scryptN: Int = 65536
    nonisolated static let scryptR: Int = 8
    nonisolated static let scryptP: Int = 1
    nonisolated static let keyLength: Int = 32
    nonisolated static let saltLength: Int = 16
    nonisolated static let aeadNonceLength: Int = 12
    nonisolated static let aeadTagLength: Int = 16
    /// The four-byte cleartext marker every V2 wrap carries at offset 0 — stamped by
    /// ``wrapContentKey(_:using:)`` and matched by ``unwrapContentKey(_:using:)``.
    ///
    /// Module-internal rather than `private` so ``LockWrapFormatCensus`` classifies a stored wrap
    /// against the SAME bytes the writer stamps. A census carrying its own copy of the marker would
    /// keep reporting "no legacy wraps" on the day the marker changed — and that report is what
    /// gates deleting the legacy reader (Docs/Plan-Crypto-Standardization-2026-08-27.md, Phase 0/3).
    nonisolated static let wrappedContentKeyFormatV2 = Data("FLW2".utf8)
    private nonisolated static let verifierFormatV2 = Data("FLV2".utf8)

    /// Derives the 32-byte scrypt key for a passcode and salt, off the main actor.
    ///
    /// - Parameters:
    ///   - passcode: The user's secret.
    ///   - salt: The per-credential random salt.
    ///   - n: The scrypt cost parameter — pass the *stored* N when verifying an existing
    ///     credential so pre-upgrade installs keep matching.
    /// - Returns: The derived key, which doubles as the content-key wrapping key and must
    ///   never be persisted (persist ``verifierDigest(of:)`` instead).
    nonisolated static func deriveVerifier(passcode: String, salt: Data, n: Int = scryptN) async throws -> Data {
        let password = Array(passcode.utf8)
        let saltBytes = Array(salt)
        let dkLen = keyLength
        let N = n
        let r = scryptR
        let p = scryptP
        return try await Task.detached(priority: .userInitiated) {
            let bytes = try Scrypt(
                password: password,
                salt: saltBytes,
                dkLen: dkLen,
                N: N,
                r: r,
                p: p
            ).calculate()
            return Data(bytes)
        }.value
    }

    /// Produces `saltLength` bytes from `SecRandomCopyBytes`; throws on RNG failure.
    nonisolated static func generateSalt() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: saltLength)
        guard SecRandomCopyBytes(kSecRandomDefault, saltLength, &bytes) == errSecSuccess else {
            throw FernletLockError.internalError("salt generation failed")
        }
        return Data(bytes)
    }

    /// Mints a fresh random 256-bit content key — the root secret all sealed-column
    /// keys are derived from; throws on RNG failure rather than ever returning weak bytes.
    ///
    /// Produced by `SecRandomCopyBytes` exactly like ``generateSalt()``, so no
    /// `withUnsafeBytes` round-trip through `SymmetricKey` is needed to get the bytes out (R9).
    nonisolated static func generateContentKey() throws -> Data {
        var bytes = [UInt8](repeating: 0, count: keyLength)
        guard SecRandomCopyBytes(kSecRandomDefault, keyLength, &bytes) == errSecSuccess else {
            throw FernletLockError.internalError("content key generation failed")
        }
        return Data(bytes)
    }

    /// Seals the content key with ChaChaPoly under the scrypt-derived wrapping key,
    /// returning the combined (nonce + ciphertext + tag) blob stored in the keychain.
    nonisolated static func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data {
        let wrappingKey = SymmetricKey(data: wrappingKeyData)
        let combined = try ChaChaPoly.seal(
            contentKey,
            using: wrappingKey,
            authenticating: FernletCryptoPurpose.AEAD.lockContentKeyWrapV2.data
        ).combined
        return wrappedContentKeyFormatV2 + combined
    }

    /// Opens a ChaChaPoly-wrapped content key; throws on tampering or a wrong wrapping key.
    nonisolated static func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data {
        let wrappingKey = SymmetricKey(data: wrappingKeyData)
        if wrappedContentKey.starts(with: wrappedContentKeyFormatV2) {
            let sealedBox = try ChaChaPoly.SealedBox(
                combined: wrappedContentKey.dropFirst(wrappedContentKeyFormatV2.count)
            )
            return try ChaChaPoly.open(
                sealedBox,
                using: wrappingKey,
                authenticating: FernletCryptoPurpose.AEAD.lockContentKeyWrapV2.data
            )
        }
        let sealedBox = try ChaChaPoly.SealedBox(combined: wrappedContentKey)
        return try ChaChaPoly.open(sealedBox, using: wrappingKey) // cryptographic-domain: legacy-read
    }

    /// The at-rest passcode verifier is the SHA-256 digest of the scrypt-derived key — NOT the derived
    /// key itself. Persisting only the digest keeps the content-key *wrapping* key out of the keychain:
    /// a keychain compromise then yields only `salt + SHA256(derivedKey) + wrappedContentKey`, so an
    /// attacker must still brute-force the passcode through scrypt to re-derive the wrapping key and
    /// unwrap the content key. The raw derived key remains the wrapping key, used in memory only and
    /// never written to disk. (Security hardening — see the verifier/wrapping-key split.)
    nonisolated static func verifierDigest(of derivedKey: Data) -> Data {
        verifierFormatV2 + Data(SHA256.hash(
            data: FernletCryptoPurpose.Hash.lockVerifierV2.data + derivedKey
        ))
    }

    /// The digest form used before purpose separation. It is read only by the migration gate.
    nonisolated static func legacyVerifierDigest(of derivedKey: Data) -> Data {
        Data(SHA256.hash(data: derivedKey))
    }
}

/// Injection seam over `FernletLockCrypto` so tests can substitute deterministic
/// salts, keys, and derivations.
///
/// `SystemFernletLockCryptoProvider` is the production conformer; unit tests inject
/// fakes through ``FernletLockService``'s initializer. `@MainActor` class-bound to
/// match the service that owns it — the memory-hard scrypt derivation still hops
/// off-main inside the implementation.
@MainActor
public protocol FernletLockCryptoProviding: AnyObject {
    /// Produces a fresh random salt for credential (re)configuration.
    func generateSalt() throws -> Data
    /// Derives the scrypt wrapping key for `passcode` and `salt` with cost parameter `n`.
    func deriveVerifier(passcode: String, salt: Data, n: Int) async throws -> Data
    /// Mints a fresh random 256-bit content key; throws on RNG failure.
    func generateContentKey() throws -> Data
    /// Seals the content key under the derived wrapping key.
    func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data
    /// Opens a wrapped content key; throws if the wrapping key is wrong or the blob is tampered.
    func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data
}

/// The production ``FernletLockCryptoProviding`` conformer.
///
/// A stateless pass-through to the `FernletLockCrypto` statics; ``FernletLockService``
/// creates one by default when no provider is injected.
final class SystemFernletLockCryptoProvider: FernletLockCryptoProviding {
    func generateSalt() throws -> Data {
        try FernletLockCrypto.generateSalt()
    }

    func deriveVerifier(passcode: String, salt: Data, n: Int) async throws -> Data {
        try await FernletLockCrypto.deriveVerifier(passcode: passcode, salt: salt, n: n)
    }

    func generateContentKey() throws -> Data {
        try FernletLockCrypto.generateContentKey()
    }

    func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data {
        try FernletLockCrypto.wrapContentKey(contentKey, using: wrappingKeyData)
    }

    func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data {
        try FernletLockCrypto.unwrapContentKey(wrappedContentKey, using: wrappingKeyData)
    }
}

/// The escalating brute-force cooldown ladder: level 1 → 60s, 2 → 15min, 3 → 1h, 4 → 4h.
/// Every 4th failed passcode attempt advances one level; failing again past level 4 flips
/// `requiresReset` instead of starting another cooldown.
private func cooldownDuration(for level: Int) -> TimeInterval {
    switch level {
    case 1: 60
    case 2: 900
    case 3: 3600
    case 4: 14400
    default: 60
    }
}

/// The keychain account names for every persisted piece of lock state.
///
/// All items live under one keychain service (`KeychainItem.productionService` by
/// default; tests inject isolated services) as ThisDeviceOnly, never-synchronized
/// generic passwords — nothing here ever reaches iCloud Keychain. The `CaseIterable`
/// conformance enumerates the complete on-device footprint for wipe and test-cleanup
/// code.
public enum LockKeychainKey: String {
    /// Random scrypt salt for the configured credential.
    case salt = "com.fernlet.lock.salt"
    /// SHA-256 digest of the scrypt-derived wrapping key (legacy installs: the raw key).
    case verifier = "com.fernlet.lock.verifier"
    /// The configured ``FernletLockCredentialKind`` raw value, UTF-8 encoded.
    case kind = "com.fernlet.lock.kind"
    /// The ChaChaPoly-sealed content key — the LEGACY wrap, and the discriminator of the lock's
    /// key-custody state machine: **present** means legacy (scrypt authoritative), **absent**
    /// means HARD-BOUND to the Secure Enclave (``seWrappedContentKey`` authoritative). It is
    /// deleted only after a freshly re-read Secure-Enclave wrap has been proven to unwrap to the
    /// exact same key (keep-old-until-verified), and is never written again once gone.
    case wrappedContentKey = "com.fernlet.lock.wrappedContentKey"
    /// STAGING slot for the one-time legacy→`FLW2` re-wrap of ``wrappedContentKey``
    /// (crypto-standardization Phase 2.5, `LockWrapFormatMigrator`).
    ///
    /// Holds the freshly written `FLW2` wrap ONLY between the migration pass's stage step and its
    /// verified post-promote delete — the new wrap is proven to persist and unwrap on this device
    /// here, while the legacy wrap still stands untouched, before the single transactional
    /// `SecItemUpdate` promote ever touches the live row. **No reader ever consults it**: custody
    /// stays discriminated by ``wrappedContentKey`` alone, so this row can never resurrect a
    /// scrypt custody state. Because an orphan is a scrypt-openable copy of the content key, its
    /// lifetime is bounded by the custody-independent sweep in `unlock(passcode:for:)` — every
    /// successful passcode verification deletes it, under EVERY custody state — and it is
    /// destroyed by `destroyLocalUnlockKeys` (both duress responses) like the live wrap it stages
    /// for. Written only through the service's `keychainStore` seam, so it inherits the same
    /// `WhenUnlockedThisDeviceOnly`, never-synchronized class as the live row (pinned by
    /// `KeyCustodyBoundaryTests`).
    case wrappedContentKeyRewrapStaging = "com.fernlet.lock.wrappedContentKey.rewrapStaging"
    /// The content key ECIES-wrapped under the non-exportable Secure Enclave key
    /// (`SecureEnclaveContentKeyWrap`). Additive while ``wrappedContentKey`` still exists;
    /// **authoritative — the only recoverable copy — once it does not**. Absent on SE-less
    /// devices, where the lock stays in the legacy state forever.
    case seWrappedContentKey = "com.fernlet.lock.seWrappedContentKey"
    /// The raw content key behind a `.biometryCurrentSet` access control (Face ID/Touch ID path).
    case biometricBypass = "com.fernlet.lock.biometricBypass"
    /// Presence flag: biometric unlock is enabled.
    case biometricEnabledFlag = "com.fernlet.lock.biometricEnabled"
    /// Wall-clock cooldown deadline (seconds since reference date, as little-endian `Double` bytes).
    case cooldownDeadline = "com.fernlet.lock.cooldownDeadline"
    /// System-uptime anchor captured when the cooldown started (anti clock-rollback).
    case cooldownMonotonicAnchor = "com.fernlet.lock.cooldownMonotonicAnchor"
    /// The active cooldown's duration in seconds (as little-endian `Double` bytes).
    case cooldownDurationSeconds = "com.fernlet.lock.cooldownDurationSeconds"
    /// Failed attempts since the last success or cooldown escalation (single byte).
    case attemptCount = "com.fernlet.lock.attemptCount"
    /// Current escalation level on the cooldown ladder (single byte).
    case cooldownLevel = "com.fernlet.lock.cooldownLevel"
    /// Presence flag: escalation exhausted; only a destructive reset unlocks again.
    case requiresReset = "com.fernlet.lock.requiresReset"
    /// The scrypt N the stored verifier was derived with (little-endian `Int32` bytes).
    case scryptN = "com.fernlet.lock.scryptN"
    /// Presence flag: an EXISTING install just migrated to the hard Secure-Enclave binding and
    /// has not yet been told. Never set by `configure()` — a fresh setup already acknowledged the
    /// disclosure sheet; this exists because a migrating install never sees that sheet again and
    /// would otherwise acquire a strictly larger loss mode with no signal at all.
    case hardBindingNoticePending = "com.fernlet.lock.hardBindingNoticePending"
    /// The duress PIN's OWN scrypt salt — deliberately NOT the primary ``salt``.
    ///
    /// Two reasons it is separate. (1) It survives a re-key: ``FernletLockService/changeCredential(current:new:)``
    /// rewrites the primary salt and verifier, and the app never holds the duress plaintext at that
    /// moment, so a duress verifier derived under the shared salt would be silently stranded by any
    /// passcode change. (2) Cryptographic independence, for one extra derivation that is already
    /// off-main.
    ///
    /// **Present unconditionally, even with no duress PIN configured.** Unlock derives against this
    /// row every time (a random dummy compared against a never-matching verifier when unconfigured),
    /// so unlock latency cannot be timed to reveal whether a duress PIN exists. Its presence
    /// therefore says NOTHING about configuration — that question is ``duressVerifier``'s.
    ///
    /// Latency is a constant TWO derivations in every direction, which takes a second mechanism: a
    /// duress match returns before the real verifier is ever derived, so
    /// ``FernletLockService/handleDuress(_:passcode:scope:)`` spends one discarded derivation to pay
    /// the difference. Without it a decoy came back in roughly half the time of a benign unlock —
    /// visible to the naked eye on a phone the observer has watched unlock before.
    case duressSalt = "com.fernlet.lock.duressSalt"
    /// `SHA256(scrypt(duressPIN, duressSalt))`, written only while a duress PIN is configured, and
    /// therefore the discriminator ``FernletLockService/hasDuressConfigured`` reads. Like
    /// ``verifier``, only the digest is persisted — never the derived key itself.
    case duressVerifier = "com.fernlet.lock.duressVerifier"
    /// The configured ``DuressMode`` as a single raw byte.
    case duressMode = "com.fernlet.lock.duressMode"
    /// The ``FernletLockCredentialKind`` the configured duress PIN was entered as, UTF-8 encoded.
    ///
    /// Written beside ``duressVerifier`` because the lock renders exactly ONE entry surface, with a
    /// hard-capped length: a 4-digit duress PIN cannot be typed on a 6-digit pad. Without this row
    /// a credential-KIND change would strand a duress verifier that
    /// ``FernletLockService/hasDuressConfigured`` still reports as armed — a coercion-time safety
    /// feature silently inert exactly when it is needed. ``FernletLockService/changeCredential(current:new:)``
    /// reads it and refuses a kind change that would make the configured duress PIN unenterable.
    case duressKind = "com.fernlet.lock.duressKind"
    /// The content key sealed to an enrolled custodian device's key-agreement public key, for the
    /// ``DuressMode/recoveryLock`` response. Safe to keep locally — and safe to SURVIVE the key
    /// destruction that response performs — because opening it requires the custodian device's
    /// private key, which never exists on this device.
    case recoveryBlob = "com.fernlet.lock.recoveryBlob"
    /// The enrolled custodian device's Ed25519 signing public key, captured by the in-person QR
    /// mutual-auth ceremony.
    case custodianSigningPublicKey = "com.fernlet.lock.custodianSigningPublicKey"
    /// The enrolled custodian device's X25519 key-agreement public key — the key ``recoveryBlob``
    /// is sealed to.
    case custodianKeyAgreementPublicKey = "com.fernlet.lock.custodianKeyAgreementPublicKey"
    /// THIS device's OWN X25519 key-agreement public key as it stood when the custodian was
    /// enrolled — the sender key ``recoveryBlob`` is cryptographically bound to.
    ///
    /// The app-side sealing mixes the sender's long-term key-agreement public key into both the
    /// HKDF `sharedInfo` and the AEAD's additional data, and the custodian opens the blob with the
    /// LIVE, ceremony-proven sender key. So the blob is openable only while this device's proximity
    /// identity is unchanged — and an ordinary "Delete everything" regenerates it (the delete funnel
    /// wipes the identity keychain while deliberately KEEPING the lock's). Recording the
    /// enrollment-time key is what makes that rotation locally detectable, so
    /// ``FernletLockService/invalidateRecoveryCustodianForRotatedIdentity()`` can retire a blob no
    /// device on earth can open instead of leaving ``DuressMode/recoveryLock`` armed over it.
    case recoveryOwnerKeyAgreementPublicKey = "com.fernlet.lock.recoveryOwnerKAPublicKey"
    /// Presence flag: the surviving ``recoveryBlob`` seals a SUPERSEDED content key.
    ///
    /// Set by the one mint that deliberately keeps recovery material while minting a FRESH content
    /// key — a recovery-locked device whose user taps "set up app lock" before reaching their
    /// custodian. The blob still opens the corpus from before that lock (which is why it is kept),
    /// but it cannot open a byte written under the new one, so ``DuressMode/recoveryLock`` may not
    /// be re-armed over it: firing it would destroy the live key and the ceremony would hand back
    /// the superseded one.
    case recoveryBlobSuperseded = "com.fernlet.lock.recoveryBlobSuperseded"
}

/// Injection seam for "now", letting tests drive cooldown-deadline arithmetic
/// deterministically.
///
/// `SystemFernletDateProvider` (wall-clock `Date()`) is the default;
/// ``FernletLockService`` consults it for every deadline computation.
@MainActor
public protocol FernletDateProviding: AnyObject {
    /// The current wall-clock time.
    var now: Date { get }
}

/// The production ``FernletDateProviding`` conformer: plain `Date()`.
///
/// Used when no date provider is injected into ``FernletLockService``.
final class SystemFernletDateProvider: FernletDateProviding {
    var now: Date { Date() }
}

/// Injection seam for the monotonic system-uptime clock that makes brute-force
/// cooldowns resistant to wall-clock tampering.
///
/// `SystemFernletUptimeProvider` (`ProcessInfo.systemUptime`) is the default. Uptime
/// resets on reboot, which ``FernletLockService`` detects and treats as a fallback to
/// wall-clock-only cooldown accounting.
@MainActor
public protocol FernletUptimeProviding: AnyObject {
    /// Seconds since boot — monotonic, unaffected by wall-clock changes.
    var systemUptime: TimeInterval { get }
}

/// The production ``FernletUptimeProviding`` conformer: `ProcessInfo.processInfo.systemUptime`.
///
/// Used when no uptime provider is injected into ``FernletLockService``.
final class SystemFernletUptimeProvider: FernletUptimeProviding {
    var systemUptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
}

extension KeychainItem {
    /// Stores a lock item as a ThisDeviceOnly generic password under `key`'s account name.
    ///
    /// - Returns: The raw `OSStatus`; ``FernletLockService`` both checks it AND reads the
    ///   value back (`storeVerified`) before trusting the write. Not discardable (R7): every lock
    ///   row is key material whose loss is invisible until the next unlock.
    static func store(_ data: Data, for key: LockKeychainKey, service: String) -> OSStatus {
        store(
            data,
            account: key.rawValue,
            service: service,
            // WhenUnlockedThisDeviceOnly: items survive device passcode removal instead of being
            // silently deleted, preventing unexpected notConfigured state and content key loss.
            accessibility: kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        )
    }

    /// Loads the lock item for `key`, or `nil` when absent.
    public static func load(for key: LockKeychainKey, service: String) -> Data? {
        load(account: key.rawValue, service: service)
    }

    /// Deletes the lock item for `key` (a missing item is not an error).
    public static func delete(for key: LockKeychainKey, service: String) {
        delete(account: key.rawValue, service: service)
    }

    /// Builds a `WhenPasscodeSetThisDeviceOnly` access control carrying `flag` (the
    /// biometric gate); throws when the `SecAccessControl` cannot be created. `nonisolated`
    /// because ``loadBiometricBypassSync(prompt:service:)`` calls it off the main thread; it is
    /// a pure Security-framework call with no state of its own.
    nonisolated static func accessControl(for flag: SecAccessControlCreateFlags) throws -> SecAccessControl {
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
            flag,
            &cfError
        ) else {
            throw cfError?.takeRetainedValue() as Error? ?? FernletLockError.internalError("access control creation failed")
        }
        return access
    }

    /// Replaces the biometric-bypass item: deletes any existing copy, then stores `data`
    /// (the raw content key) behind a fresh `.biometryCurrentSet` access control, so the
    /// item is invalidated whenever biometric enrollment changes.
    static func storeBiometricBypass(_ data: Data, service: String) throws {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: LockKeychainKey.biometricBypass.rawValue,
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let access = try accessControl(for: .biometryCurrentSet)
        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: LockKeychainKey.biometricBypass.rawValue,
            kSecAttrAccessControl as String: access,
            kSecAttrSynchronizable as String: false,
            kSecUseDataProtectionKeychain as String: true,
            kSecValueData as String: data
        ]
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw FernletLockError.keychainFailure(operation: "store biometric bypass", status: status)
        }
    }

    /// The visible upper bound on the LocalAuthentication wait in
    /// ``loadBiometricBypassSync(prompt:service:)`` — longer than any system biometric prompt
    /// lives, so a real user is never cut off, while the blocked thread (and the continuation it
    /// owns) can never be pinned forever if the reply block is not invoked (R2).
    nonisolated private static let biometricPromptTimeout: DispatchTimeInterval = .seconds(120)

    /// Synchronously authenticates with biometrics and reads the bypass item.
    ///
    /// Blocks the calling thread on the LocalAuthentication evaluation (semaphore), so it
    /// must run off the main thread — ``FernletLockService/unlockWithBiometrics(for:)`` calls
    /// it from a global queue, which is why it (and the ``accessControl(for:)`` it uses) is
    /// `nonisolated` rather than taking this module's MainActor default. The pre-evaluated
    /// `LAContext` is handed to `SecItemCopyMatching`, so the user sees a single system prompt.
    /// The evaluation reply lands in a `Mutex` (the reply block is `@Sendable`) and is read back
    /// only after the semaphore confirms it was written.
    /// - Returns: The stored content-key bytes.
    nonisolated static func loadBiometricBypassSync(prompt: String, service: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = prompt

        let access = try accessControl(for: .biometryCurrentSet)
        let authGroup = DispatchSemaphore(value: 0)
        let authReply = Mutex<(succeeded: Bool, error: (any Error)?)>((succeeded: false, error: nil))
        context.evaluateAccessControl(access, operation: .useItem, localizedReason: prompt) { success, error in
            authReply.withLock { $0 = (succeeded: success, error: error) }
            authGroup.signal()
        }
        guard authGroup.wait(timeout: .now() + Self.biometricPromptTimeout) == .success else {
            throw FernletLockError.biometricFailed
        }

        let (didAuthenticate, authenticationError) = authReply.withLock { $0 }
        guard didAuthenticate else {
            throw authenticationError ?? FernletLockError.biometricFailed
        }

        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: LockKeychainKey.biometricBypass.rawValue,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecReturnData as String: true,
            kSecUseDataProtectionKeychain as String: true,
            kSecUseAuthenticationContext as String: context
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // The status is a fact, not just a Bool: a keychain that would not ANSWER after a
        // SUCCESSFUL biometric evaluation (errSecInteractionNotAllowed / errSecNotAvailable) is
        // not "Face ID didn't recognize you", and telling the user it is sends them to retry the
        // one thing that already worked.
        guard status == errSecSuccess else {
            throw status == errSecItemNotFound
                ? FernletLockError.biometricFailed
                : FernletLockError.keychainFailure(operation: "read biometric bypass", status: status)
        }
        guard let data = result as? Data else {
            throw FernletLockError.biometricFailed
        }
        return data
    }
}

/// Constant-time comparison for verifier checks — XOR-accumulates every byte so timing
/// does not leak the position of the first mismatch. (The early return on a length
/// mismatch is fine: verifier lengths are fixed and public.)
private func constantTimeEqual(_ a: Data, _ b: Data) -> Bool {
    guard a.count == b.count else { return false }
    var result: UInt8 = 0
    for (x, y) in zip(a, b) {
        result |= x ^ y
    }
    return result == 0
}

/// The app lock: owns the credential lifecycle, the sealed-content key, brute-force
/// cooldowns, biometric unlock, and the locked-while-buffered narrative seam.
///
/// One instance is created at app launch (`FernletApp`) and injected into the SwiftUI
/// environment; the `FernletLockUI` gate, setup, and unlock views drive it, and sealed
/// feature code (period tracker, worry box, journal) fetches the content key from it per
/// operation. It is the production ``FernletLockServicing`` conformer and — through that
/// protocol — the `PeriodLockContext` the sealed `PrivateHealthStore` uses to buffer
/// narratives while the lock is engaged.
///
/// **Key scheme.** ``configure(credential:)`` derives a scrypt wrapping key from the
/// passcode (+ random salt), mints a random 256-bit content key, and persists only: the
/// salt, `SHA256(wrappingKey)` as the verifier, the ChaChaPoly-wrapped content key, the
/// credential kind, and the scrypt N. The wrapping key itself is never persisted; the
/// unwrapped content key lives only in memory while `.unlocked` and is scrubbed by
/// ``lock(reason:)``. Sealed stores derive per-column keys from the content key
/// (`ColumnCrypto` in `FernletCrypto`).
///
/// **Keychain.** Everything lives under ``LockKeychainKey`` accounts in one service,
/// ThisDeviceOnly and never synchronized; every write is status-checked AND read back
/// (`storeVerified`) so a silently failing keychain cannot masquerade as configured
/// state. The biometric path keeps the raw content key in a separate
/// `.biometryCurrentSet`-gated item that iOS invalidates when enrollment changes.
///
/// **Key custody is a two-state machine, discriminated by the presence of the
/// scrypt-wrapped item** (`LockKeychainKey.wrappedContentKey`):
/// - **LEGACY** — the scrypt item is present and authoritative. The Secure-Enclave wrap is
///   additive and is preferred at unlock only when it provably equals the scrypt-unwrapped key.
///   This is the permanent state on hardware without a Secure Enclave.
/// - **HARD-BOUND** — the scrypt item is ABSENT and `seWrappedContentKey` is the only
///   recoverable copy. The salt + verifier still gate entry (the passcode is checked exactly as
///   before), but recovery is `SecureEnclaveContentKeyWrap.unwrap`, so the sealed corpus plus a
///   full keychain dump is useless off-device *even with the passcode*.
///
/// The transition is **keep-old-until-verified**: after a successful configure or unlock the
/// service re-reads the stored enclave wrap, unwraps it, and deletes the scrypt item only when
/// those bytes constant-time-equal the authoritative key. Every failure path — no enclave, no
/// blob, a failed unwrap, a keychain error — keeps the scrypt item and today's behavior. Once
/// hard-bound, an enclave key destroyed out from under the app (Erase All Content and Settings,
/// a Secure-Enclave reset, a restore onto other hardware) makes the sealed corpus unopenable:
/// that surfaces as the explicit `FernletLockError.contentKeyUnrecoverable`, never a silent
/// wrong key. Three properties keep that error honest rather than merely dramatic: a keychain
/// that would not ANSWER is a different, retryable error
/// (`.contentKeyTemporarilyUnavailable(status:)`); the two scopes that never receive the content
/// key still unlock on the verifier match, so Settings → App lock (and its reset) stays reachable;
/// and while a `.biometryCurrentSet` bypass copy survives, the biometric path can re-establish the
/// wrap from it instead of destroying anything.
///
/// **Duress (P7).** One optional duress PIN, with one chosen ``DuressMode``, sits in front of every
/// credential entry point. It has its OWN salt and verifier (``LockKeychainKey/duressSalt`` /
/// ``LockKeychainKey/duressVerifier``) so a passcode change cannot strand it, and the derivation
/// against that salt runs UNCONDITIONALLY — dummy salt, never-matching verifier when unconfigured —
/// so unlock latency is a constant two derivations and cannot be timed to reveal whether a duress
/// PIN exists. The compare runs before the `requiresReset`/cooldown guards and before the attempt
/// counter, so a duress PIN still works during a lockout (exactly when coercion is likeliest) and
/// leaves no residue distinguishing it from a benign unlock; ``changeCredential(current:new:)`` and
/// ``setBiometricEnabled(_:passcode:)`` consult it first too, so a coerced PIN can never re-key the
/// real lock or write the real content key into the biometric bypass. A match opens the KEYLESS
/// decoy — no content key is installed, so every sealed surface renders empty — sets
/// ``isDuressSessionActive``, and returns the same `UnlockResult` and audit line as a real unlock.
/// The flag survives ``lock(reason:)`` on purpose and clears only on an act that proves the real
/// credential, which is what keeps the biometric side door shut for the whole duress session.
///
/// ``DuressMode/silentWipe`` adds a destructive step in front of that decoy: every local key,
/// the Secure-Enclave key included, is deleted synchronously (sub-second crypto-erase), a
/// throwaway empty lock is re-minted under the duress PIN so the decoy survives a re-lock, and
/// ``duressPurgeHook`` then runs the durable cleanup through the app's delete funnel. This is the
/// ONE seam that destroys `com.fernlet.lock` — the ordinary "delete everything" funnel keeps it,
/// and cannot reach here (see `Docs/PrivacyWipeCoverage.md`).
///
/// ``DuressMode/recoveryLock`` destroys the same local unlock keys but KEEPS what the corpus can be
/// recovered from: the recovery blob sealed to an enrolled custodian device
/// (``enrollRecoveryCustodian(passcode:signingPublicKey:keyAgreementPublicKey:ownKeyAgreementPublicKey:sealingContentKeyTo:)``),
/// the custodian's public keys, the ciphertext itself, and the device fallback keys. No throwaway
/// lock is minted and no purge fires. The way back is an in-person QR + sealed-mesh ceremony driven
/// by the app-side `DuressRecoveryCoordinator` — this module gains no ProximityKit edge and there is
/// no cloud recovery route — ending at
/// ``reestablishLocalUnlock(contentKey:credential:grantingScope:)``, which refuses any key that is
/// not the one the blob seals.
///
/// **Brute force.** Every 4th failed passcode attempt escalates a cooldown
/// (60s → 15min → 1h → 4h), tracked against BOTH the wall clock and monotonic uptime so
/// clock rollback cannot shorten it; exhausting the ladder sets ``requiresReset``, after
/// which only the destructive ``reset()`` — which also purges the sealed narrative
/// entities via `PrivatePersistenceController` — recovers the app.
///
/// **Concurrency.** `@MainActor` + `@Observable`; the memory-hard scrypt derivation hops
/// off-main inside the crypto provider, and the blocking biometric keychain read runs on
/// a global queue. All dependencies (date, uptime, crypto, keychain closures, biometric
/// loader, persistence controller) are injectable for tests. Failures surface as
/// `FernletLockError`; every state transition is recorded via `FernletAuditLog`.
@MainActor
@Observable
public final class FernletLockService: @MainActor FernletLockServicing {
    /// Backing subject for ``statePublisher``; fed by ``state``'s `didSet`.
    @ObservationIgnored
    private let stateSubject = PassthroughSubject<FernletLockState, Never>()

    /// The current lock state; every mutation is re-published through ``statePublisher``.
    public private(set) var state: FernletLockState = .notConfigured {
        didSet { stateSubject.send(state) }
    }
    /// Whether this lock session's single automatic biometric prompt has been consumed
    /// (see ``consumeAutoBiometricPromptOpportunity()``); re-armed on every unlock.
    private(set) var hasAutoPromptedBiometricForCurrentLockSession = false
    /// True while ``unlockWithBiometrics(for:)`` is in flight, so observers (the lock gate's
    /// scene-phase re-lock handling) can tell the system Face ID sheet apart from a real
    /// backgrounding.
    public private(set) var isPerformingBiometricUnlock = false
    /// True once a passcode entry has succeeded in THIS process: set at the end of a successful
    /// ``unlock(passcode:for:)`` and by ``configure(credential:grantingScope:)`` (initial setup
    /// counts as the process's passcode success), cleared only by ``reset()``. Deliberately NOT
    /// set by ``unlockWithBiometrics(for:)`` — a biometric success must never satisfy the
    /// passcode-first requirement it is gated on.
    ///
    /// Never persisted: the app creates one service per process, so the flag inherently resets
    /// on relaunch/termination, giving biometric unlock an iOS-style
    /// "first unlock after reboot requires the passcode" rule (see
    /// ``isBiometricUnlockAvailable`` and the fail-closed guard in
    /// ``unlockWithBiometrics(for:)``). Observable (not `@ObservationIgnored`) so the lock UI
    /// re-evaluates its biometric offer when the flag flips.
    public private(set) var passcodeUnlockedThisProcess = false
    /// True once a correct passcode has been ENTERED in this process — set at the verifier match,
    /// **before** key recovery is attempted, and by ``configure(credential:grantingScope:)``;
    /// cleared only by ``reset()``.
    ///
    /// Deliberately distinct from ``passcodeUnlockedThisProcess``, which records a fully
    /// successful unlock. The difference is the whole point in the hard-bound state: when the
    /// enclave key is gone, every passcode unlock throws before the unlock tail, so the narrower
    /// flag can never become true — and gating biometrics on it alone would strand the
    /// `.biometricBypass` copy of the content key, the one surviving copy that can repair the
    /// wrap (see ``unlockWithBiometrics(for:)``). PIN-before-biometrics is preserved exactly: this
    /// flag is set ONLY by a correct passcode entry (never by a biometric success, never by a
    /// wrong attempt), so biometrics still cannot be the first factor after launch.
    ///
    /// Never persisted (one service per process). Observable so the lock UI re-evaluates its
    /// biometric offer the moment a verifier match lands.
    public private(set) var passcodeVerifiedThisProcess = false
    /// True while a DURESS session is in force — the lock is presenting the empty decoy instead of
    /// the user's real data, because the duress PIN was entered.
    ///
    /// A duress unlock is deliberately indistinguishable from a benign one *to an observer*: same
    /// state transition, same audit label, same cleared attempt state, same `UnlockResult`. This
    /// flag is the app's only internal signal that it happened, and it is what the app-side
    /// sensitive-visibility gates mirror (a later P7 stage) so the decoy lives in the SERVICE
    /// rather than in a per-view `if`.
    ///
    /// **Lifetime is load-bearing.** Cleared ONLY by an act that PROVES the real credential — a
    /// real-passcode unlock success, ``configure(credential:grantingScope:)``, ``reset()``,
    /// ``configureDuress(pin:mode:)``,
    /// ``enrollRecoveryCustodian(passcode:signingPublicKey:keyAgreementPublicKey:ownKeyAgreementPublicKey:sealingContentKeyTo:)``
    /// or ``reestablishLocalUnlock(contentKey:credential:grantingScope:)`` — and **never** by
    /// ``lock(reason:)``.
    /// In the non-destructive decoy the `.biometricBypass` row still holds the REAL content key, so
    /// a decoy session that ended at the next re-lock would re-open the biometric side door; the
    /// suppression has to outlive the lock and end only when the real PIN is entered. Both
    /// ``isBiometricUnlockAvailable`` (the UI policy) and the fail-closed guard at the top of
    /// ``unlockWithBiometrics(for:)`` (the guarantee) consult it.
    ///
    /// Never persisted — one service per process, so it dies with the process exactly like
    /// ``passcodeUnlockedThisProcess``. Observable so the store gates and the lock UI re-evaluate
    /// the moment it flips.
    public private(set) var isDuressSessionActive = false

    /// The durable-purge seam fired — once, fire-and-forget — after a ``DuressMode/silentWipe``
    /// has crypto-erased the local keys.
    ///
    /// **Not the erase.** The wipe's guarantee is the synchronous key destruction that runs before
    /// this is called: by the time the hook fires, every key that could open a sealed byte on this
    /// device is already gone, so the sealed corpus is meaningless whether or not the hook ever
    /// completes. What the hook buys is *tidiness* — the sealed CoreData rows, the day blob and the
    /// cloud copies going away for real — which is why it is best-effort and why nothing waits on
    /// it. It is wired app-side to `FernletStore.deleteAllData`, the one audited deletion funnel, so
    /// the wipe reuses that path rather than growing a second one.
    ///
    /// **`FernletLock` cannot call the funnel itself** — `FernletStore` lives in the app target,
    /// above this module — so the seam is an injected closure, set once during the app's launch
    /// wiring. An unwired hook degrades to "crypto-erased but the ciphertext rows are still on
    /// disk", never to a failed wipe.
    ///
    /// Only the duress wipe reaches this. The ordinary delete funnel runs in the opposite direction
    /// (the app calls the store, which never calls back into the lock), so `deleteAllData` cannot
    /// trigger a key destruction by any route — the destructive seam stays duress-only.
    ///
    /// `@MainActor`-isolated because the store it drives is, and `@ObservationIgnored` because it is
    /// launch-time wiring no view observes.
    ///
    /// R6: readable (the wiring tests assert it is installed) but writable only through
    /// ``installDuressPurgeHook(_:)``, which is **set-once** — the most destructive seam in the app
    /// must not be silently replaceable by whoever holds the service last.
    @ObservationIgnored public private(set) var duressPurgeHook: (@MainActor () -> Void)?

    /// Installs the durable-purge seam. Called exactly once, from the app's launch wiring.
    ///
    /// Set-once by design: a second install is REFUSED and recorded, never allowed to overwrite the
    /// first. Swapping this closure mid-session would redirect (or defuse) the wipe that follows a
    /// duress unlock, and a silent overwrite is precisely the failure nobody would see until the
    /// wipe was needed. Re-wiring after a legitimate teardown means building a new service.
    ///
    /// - Parameter hook: The durable-purge errand, run on the main actor after the decoy is on screen.
    public func installDuressPurgeHook(_ hook: @escaping @MainActor () -> Void) {
        guard duressPurgeHook == nil else {
            FernletAuditLog.log("lock.duressPurgeHook.reinstallRefused")
            return
        }
        duressPurgeHook = hook
    }

    /// Combine mirror of ``state`` for subscribers outside the Observation system.
    public var statePublisher: AnyPublisher<FernletLockState, Never> { stateSubject.eraseToAnyPublisher() }

    /// The keychain service namespace all ``LockKeychainKey`` items live under
    /// (`KeychainItem.productionService` by default; tests inject isolated services).
    public let keychainService: String
    /// The keychain services holding the OTHER keys that seal rows in the same private store —
    /// today the journal and Worry Box device fallback keys under `KeychainItem.journalService`.
    /// ``reset()`` sweeps each of them, which is what makes its "crypto-erased" claim true for all
    /// four sealed entities and not just the two that are always sealed under the content key.
    /// Injected (like ``keychainService``) so a test's `reset()` cannot destroy the real device
    /// keys of the simulator or the developer's machine.
    public let sealedContentKeyServices: [String]
    /// The keychain services holding the PRIVATE MEDIA keys — the own-photo (progress photos) and
    /// friend-wall content keys, which seal body photos under a key of their own that the app lock
    /// never touches.
    ///
    /// Swept ONLY by the ``DuressMode/silentWipe``, and for exactly the reason that mode exists:
    /// its guarantee is that after a sub-second key destruction no sealed byte on this device can
    /// be opened. Progress photos are sealed bytes on this device. Leaving their key alive left the
    /// wipe's claim false until the asynchronous delete funnel caught up — and false forever if the
    /// process was killed first.
    ///
    /// Deliberately NOT swept by ``reset()``: resetting the app lock is not a delete, and the photo
    /// corpus is not the lock's to erase. Injected (like ``keychainService``) so a test's duress
    /// wipe cannot destroy the simulator's or the developer's real media keys.
    public let mediaKeychainServices: [String]
    @ObservationIgnored private let dateProvider: FernletDateProviding
    @ObservationIgnored private let uptimeProvider: FernletUptimeProviding
    @ObservationIgnored private let cryptoProvider: FernletLockCryptoProviding
    /// Test seam replacing the LocalAuthentication + keychain biometric read
    /// (`(prompt, service) -> contentKeyData`); `nil` in production.
    @ObservationIgnored private let biometricBypassLoader: ((String, String) throws -> Data)?
    /// Test seam pinning ``biometricType`` to a deterministic value so the
    /// ``isBiometricUnlockAvailable`` policy is testable on biometry-less CI hosts;
    /// `nil` in production, where the live `LAContext` probe is used. Init-injection
    /// only (like `biometricBypassLoader`) — deliberately not on `FernletLockServicing`.
    @ObservationIgnored private let biometricTypeOverride: (() -> LABiometryType)?
    @ObservationIgnored private let keychainStore: (Data, LockKeychainKey, String) -> OSStatus
    @ObservationIgnored private let keychainLoad: (LockKeychainKey, String) -> Data?
    /// The absence-distinguishing read used by the custody discriminator (and only by it).
    /// Separate from ``keychainLoad`` because custody may never be inferred from a nil that also
    /// means "the read failed"; injectable so a test can force `.unreadable` and prove the service
    /// refuses to guess.
    @ObservationIgnored private let keychainLoadDistinguishing: (LockKeychainKey, String) -> KeychainItem.ReadResult
    /// The update-only keychain write the Phase 2.5 wrap re-wrap's PROMOTE goes through — one
    /// `SecItemUpdate` transaction, so the live row can never be left absent or half-written the
    /// way ``keychainStore``'s delete-then-add can. Injectable so a test can fail exactly the
    /// promote; the production default is `KeychainItem.updateReportingStatus`, whose
    /// `errSecItemNotFound` is returned un-normalized (the migrator must refuse to create).
    @ObservationIgnored private let keychainUpdate: (Data, LockKeychainKey, String) -> OSStatus
    /// The status-reporting keychain delete the same migration's staging-row cleanup goes
    /// through. Injectable so a test can force the S8 delete to fail and prove the orphan is
    /// still bounded (§Q2a); the production default is `KeychainItem.deleteReportingStatus`.
    /// The custody-independent unlock-tail sweep deliberately does NOT use this seam — it is a
    /// plain audited `KeychainItem.delete`, exercised through the real keychain.
    @ObservationIgnored private let keychainDelete: (LockKeychainKey, String) -> OSStatus
    /// The sealed CoreData stack whose encrypted entities ``reset()`` purges.
    @ObservationIgnored private let privatePersistenceController: PrivatePersistenceController
    /// The unwrapped content key; non-nil only while `.unlocked`, scrubbed on lock/reset.
    @ObservationIgnored private var _contentKey: SymmetricKey?
    /// The storage identity — buffer-file directory AND buffer-key keychain service, as one
    /// value — of the pending-narrative buffer this service owns. Injected (like
    /// ``keychainService``) so a test's `reset()`/`purgePendingNarratives()` cannot destroy the
    /// process-wide buffer that every concurrently-running suite shares; `.production` in the app.
    /// Public so a test simulating a relaunch can hand a second service the first one's scope —
    /// the shared buffer IS that test's fixture, and it needs the same file and the same key.
    public let narrativeBufferScope: PendingNarrativeStorageScope
    /// The sealed pending-narrative buffer exposed through the `PeriodLockContext` seam, built on
    /// ``narrativeBufferScope``.
    @ObservationIgnored private let buffer: PendingNarrativeBuffer

    /// Creates the service, wiring production defaults for any dependency not injected,
    /// and derives the initial state from the keychain: `.notConfigured` when no salt
    /// exists, otherwise `.locked` with any still-active cooldown deadline.
    public init(
        keychainService: String = KeychainItem.productionService,
        sealedContentKeyServices: [String] = [KeychainItem.journalService],
        mediaKeychainServices: [String] = [FernletLockService.privateMediaKeychainService],
        narrativeBufferScope: PendingNarrativeStorageScope = .production,
        dateProvider: FernletDateProviding? = nil,
        uptimeProvider: FernletUptimeProviding? = nil,
        cryptoProvider: FernletLockCryptoProviding? = nil,
        biometricBypassLoader: ((String, String) throws -> Data)? = nil,
        biometricTypeOverride: (() -> LABiometryType)? = nil,
        keychainStore: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        keychainLoad: ((LockKeychainKey, String) -> Data?)? = nil,
        keychainLoadDistinguishing: ((LockKeychainKey, String) -> KeychainItem.ReadResult)? = nil,
        keychainUpdate: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        keychainDelete: ((LockKeychainKey, String) -> OSStatus)? = nil,
        privatePersistenceController: PrivatePersistenceController? = nil
    ) {
        self.keychainService = keychainService
        self.sealedContentKeyServices = sealedContentKeyServices
        self.mediaKeychainServices = mediaKeychainServices
        self.narrativeBufferScope = narrativeBufferScope
        self.buffer = PendingNarrativeBuffer(scope: narrativeBufferScope)
        self.dateProvider = dateProvider ?? SystemFernletDateProvider()
        self.uptimeProvider = uptimeProvider ?? SystemFernletUptimeProvider()
        self.cryptoProvider = cryptoProvider ?? SystemFernletLockCryptoProvider()
        self.biometricBypassLoader = biometricBypassLoader
        self.biometricTypeOverride = biometricTypeOverride
        self.keychainStore = keychainStore ?? { data, key, service in
            KeychainItem.store(data, for: key, service: service)
        }
        self.keychainLoad = keychainLoad ?? { key, service in
            KeychainItem.load(for: key, service: service)
        }
        self.keychainLoadDistinguishing = keychainLoadDistinguishing ?? { key, service in
            KeychainItem.loadDistinguishingAbsence(account: key.rawValue, service: service)
        }
        self.keychainUpdate = keychainUpdate ?? { data, key, service in
            KeychainItem.updateReportingStatus(data, account: key.rawValue, service: service)
        }
        self.keychainDelete = keychainDelete ?? { key, service in
            KeychainItem.deleteReportingStatus(account: key.rawValue, service: service)
        }
        self.privatePersistenceController = privatePersistenceController ?? .shared

        state = Self.initialState(
            saltRow: self.keychainLoadDistinguishing(.salt, keychainService),
            cooldownDeadline: activeCooldownDeadline()
        )
    }

    /// Derives the launch-time state from the salt row, refusing to collapse "the read failed"
    /// into "no lock exists".
    ///
    /// Every lock row is `WhenUnlockedThisDeviceOnly`, and the app can be launched into the
    /// background while the device is still locked (remote notifications, HealthKit background
    /// delivery) — where the read answers `errSecInteractionNotAllowed`. Reading that as absence
    /// would boot a CONFIGURED install into `.notConfigured` for the whole process: the gate would
    /// paint "Set up app lock" over sealed content, and a setup accepted there would mint over a
    /// live lock. So an unreadable row fails CLOSED to `.locked`; a genuinely unconfigured device
    /// then answers `.notConfigured` honestly at the first unlock attempt.
    private static func initialState(
        saltRow: KeychainItem.ReadResult,
        cooldownDeadline: Date?
    ) -> FernletLockState {
        switch saltRow {
        case .absent:
            return .notConfigured
        case .found:
            return .locked(cooldownDeadline: cooldownDeadline)
        case .unreadable(let status):
            FernletAuditLog.log("lock.initialStateUnreadable", context: ["status": "\(status)"])
            return .locked(cooldownDeadline: nil)
        }
    }

    /// Re-derives ``state`` from the keychain, for the launch that could not read it.
    ///
    /// The companion to ``initialState(saltRow:cooldownDeadline:)``'s fail-closed branch: once
    /// protected data becomes available (`protectedDataDidBecomeAvailableNotification`, or the
    /// scene turning `.active`), a process that booted blind can learn that the device really is
    /// unconfigured instead of showing a lock screen for a lock that does not exist. A no-op while
    /// unlocked — an in-force unlock session is in-memory truth the keychain cannot contradict.
    public func refreshStateFromKeychain() {
        if case .unlocked = state { return }
        state = Self.initialState(
            saltRow: keychainLoadDistinguishing(.salt, keychainService),
            cooldownDeadline: activeCooldownDeadline()
        )
    }

    /// True when the cooldown ladder has been exhausted (presence-flagged in the
    /// keychain); all unlocks are refused until ``reset()``.
    public var requiresReset: Bool {
        keychainLoad(.requiresReset, keychainService) != nil
    }

    /// Whether the biometric-unlock flag is present in the keychain.
    public var biometricEnabled: Bool {
        keychainLoad(.biometricEnabledFlag, keychainService) != nil
    }

    /// The device's usable biometry right now (`.none` when unavailable or not permitted).
    /// Tests may pin the value via the init-only `biometricTypeOverride` seam; production
    /// always asks the live `LAContext`.
    public var biometricType: LABiometryType {
        if let biometricTypeOverride {
            return biometricTypeOverride()
        }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        return context.biometryType
    }

    /// The single "may biometrics be OFFERED?" policy: the user has enabled them, the device
    /// can evaluate them right now, AND a passcode success (unlock or initial setup) has
    /// already happened in this process (``passcodeUnlockedThisProcess``).
    ///
    /// Both `FernletLockView` sites — the manual biometric button and the `onAppear`
    /// auto-prompt — reference this property rather than restating the conjunction, so the
    /// rule lives in exactly one place; do not inline the rule at call sites.
    ///
    /// The `!isDuressSessionActive` conjunct is the duress phase's contribution (P7). Without it a
    /// user who unlocked normally earlier in the process, locked, and then unlocked under duress
    /// would still be OFFERED Face ID — and the `.biometricBypass` row holds the REAL content key
    /// in the non-destructive decoy, so accepting that offer would hand the coercer everything the
    /// decoy exists to hide. The offer is suppressed for as long as the duress session lasts, which
    /// is until the real passcode is entered (``isDuressSessionActive`` survives ``lock(reason:)``).
    ///
    /// The passcode conjunct is the DISJUNCTION of "a full unlock succeeded"
    /// (``passcodeUnlockedThisProcess``) and "a correct passcode was entered"
    /// (``passcodeVerifiedThisProcess``). Both are set only by a correct passcode entry, so the
    /// PIN-before-biometrics guarantee is identical; the second one is what keeps the biometric
    /// repair path reachable when a hard-bound unlock fails at key recovery *after* the passcode
    /// proved correct.
    public var isBiometricUnlockAvailable: Bool {
        biometricEnabled && biometricType != .none
            && (passcodeUnlockedThisProcess || passcodeVerifiedThisProcess)
            && !isDuressSessionActive
    }

    /// Whether this device can hard-bind the content key to a Secure Enclave — i.e. whether a
    /// passcode set up here will be born HARD-BOUND (and so die with the device's enclave key).
    ///
    /// Exposed for the setup disclosure in `FernletLockUI`, which must name the second loss mode
    /// only where it applies: SE-less hardware stays LEGACY permanently and its scrypt-wrapped key
    /// really does restore from an encrypted backup, so the older "if you forget your passcode"
    /// copy remains exactly true there. `SecureEnclaveContentKeyWrap` itself stays
    /// module-internal — this hands out a Bool about the hardware, never the wrap.
    public static var isSecureEnclaveBindingAvailable: Bool {
        SecureEnclaveContentKeyWrap.isAvailable
    }

    /// Whether an EXISTING install has just been migrated to the hard Secure-Enclave binding and
    /// still owes the user the disclosure for it.
    ///
    /// The migration changes the recovery properties of a lock the user consented to under an
    /// older build — from "you lose the notes if you forget the passcode" to "…and also if this
    /// iPhone is erased, has its Secure Enclave reset, or is restored onto other hardware." A
    /// fresh setup acknowledges that in the disclosure sheet; a migrating install would never see
    /// a sheet again, so the gate shows a one-shot notice keyed off this flag and clears it via
    /// ``acknowledgeHardBindingNotice()``. Presence-flagged in the keychain (survives relaunch, so
    /// a kill before acknowledgement does not swallow the disclosure) and swept by ``reset()``.
    public var hardBindingNoticePending: Bool {
        keychainLoad(.hardBindingNoticePending, keychainService) != nil
    }

    /// Clears ``hardBindingNoticePending`` once the user has been shown the migration disclosure.
    public func acknowledgeHardBindingNotice() {
        KeychainItem.delete(for: .hardBindingNoticePending, service: keychainService)
    }

    /// Whether a `.biometryCurrentSet`-gated copy of the content key exists in the keychain.
    ///
    /// Read by the unlock UI to choose its copy in the hard-bound unrecoverable state: while this
    /// is true a working second copy of the key survives outside the enclave, so the honest first
    /// offer is "unlock with Face ID to repair this device's key", not a destructive reset. Never
    /// a reveal seam — it answers a Bool about a row's existence, never hands back the row.
    public var hasBiometricRecoveryCopy: Bool {
        KeychainItem.load(for: .biometricBypass, service: keychainService) != nil
    }

    /// The configured credential kind read from the keychain, or `nil` before setup.
    public var credentialKind: FernletLockCredentialKind? {
        guard let data = keychainLoad(.kind, keychainService),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return FernletLockCredentialKind(rawValue: string)
    }

    /// Failed passcode attempts persisted since the last success or cooldown escalation.
    public var currentAttemptCount: Int {
        guard let data = keychainLoad(.attemptCount, keychainService),
              let byte = data.first else { return 0 }
        return Int(byte)
    }

    /// Claims the single automatic biometric prompt allowed per lock session.
    ///
    /// - Returns: `true` exactly once per lock session (the unlock view uses this to
    ///   auto-present Face ID); `false` until the next unlock re-arms the opportunity.
    public func consumeAutoBiometricPromptOpportunity() -> Bool {
        guard !hasAutoPromptedBiometricForCurrentLockSession else { return false }
        hasAutoPromptedBiometricForCurrentLockSession = true
        return true
    }

    /// First-time setup: validates the credential, derives the wrapping key, mints and
    /// wraps a fresh content key, persists the lock records, clears any stale
    /// biometric/cooldown state, establishes the Secure-Enclave wrap, and transitions to
    /// `.unlocked(scope: grantingScope)`.
    ///
    /// **Born hard-bound where an enclave exists:** the scrypt wrap is written first (so a key
    /// always exists), the enclave wrap is established and round-trip-verified, and only then —
    /// via the same keep-old-until-verified guard the migration uses — is the scrypt item
    /// deleted. On SE-less hardware the guard declines and the install stays legacy, byte for
    /// byte as before.
    ///
    /// `grantingScope` is the surface the user was standing on when they created the passcode — they
    /// are authenticated at that instant, so that one surface opens. It does NOT open the others:
    /// setting a lock up from Settings → App lock leaves the Private Hub locked, as it should.
    public func configure(credential: FernletLockCredential, grantingScope: FernletLockScope) async throws {
        try credential.validate()
        // FIRST-TIME setup validates its precondition, not just its argument (R5): `mintLockRecords`
        // delete-then-adds salt/verifier/wrappedContentKey and sweeps the enclave wrap, so running it
        // over an EXISTING lock destroys the only copies of the live content key and the sealed
        // corpus becomes permanently unopenable. `.unreadable` is refused for the same reason — a
        // mint may not proceed on a read that could not answer. Legitimate re-setup still passes:
        // `reset()` and the recovery-lock destruction both delete the salt row, and the wipe re-mint
        // and the recovery re-establish call `mintLockRecords` directly rather than through here.
        guard case .absent = keychainLoadDistinguishing(.salt, keychainService) else {
            FernletAuditLog.log("lock.configureRefused.existingOrUnreadable")
            throw FernletLockError.keychainFailure(
                operation: "configure over an existing lock",
                status: errSecDuplicateItem
            )
        }
        let contentKeyData = try await mintLockRecords(for: credential)

        retainContentKey(contentKeyData, for: grantingScope)
        state = .unlocked(scope: grantingScope)
        hasAutoPromptedBiometricForCurrentLockSession = false
        // Initial setup counts as this process's passcode success (PIN-before-biometrics, P0b).
        passcodeUnlockedThisProcess = true
        passcodeVerifiedThisProcess = true
        // One of the places a duress session may end (P7): configuring a lock is a real-PIN act by
        // definition — the user just chose the credential — and the rows any prior duress PIN lived
        // in were deleted by the mint above.
        isDuressSessionActive = false
        // Scope-independent: the SE wrap protects the key at rest, not the session, so it is
        // established for the freshly minted key whichever surface the setup happened on.
        maintainSecureEnclaveWrap(contentKeyData: contentKeyData)
        // …and where the enclave proved itself, this install is born hard-bound: the scrypt item
        // written moments ago is deleted, so the key just minted exists only inside the enclave.
        hardBindToSecureEnclaveIfVerified(contentKeyData: contentKeyData, migratingExistingInstall: false)
        FernletAuditLog.log("lock.configured", context: [
            "kind": credential.kind.rawValue,
            "scope": grantingScope.rawValue
        ])
    }

    /// Mints a fresh content key and writes the COMPLETE set of lock records for `credential`,
    /// leaving the service's in-memory state (key residency, `state`, the process flags, the audit
    /// line) entirely to the caller.
    ///
    /// Extracted from ``configure(credential:grantingScope:)`` because the P7 duress wipe re-mints a
    /// throwaway lock and the two record sets MUST be byte-shaped identically. A throwaway lock
    /// missing a row a real setup writes — `.scryptN`, say — is a forensic tell: it is exactly the
    /// kind of difference someone comparing a coerced device against a normal one would find. One
    /// body, so they cannot drift.
    ///
    /// Deliberately does NOT validate the credential: ``configure(credential:grantingScope:)`` does
    /// that before calling, and the duress path must never refuse — a re-mint that threw on a format
    /// rule would leave a wiped device with no lock at all, i.e. a "set up app lock" screen, the
    /// loudest tell there is.
    ///
    /// - Parameters:
    ///   - credential: The credential the new records gate on.
    ///   - suppliedContentKey: The key the records must wrap, or nil to mint a fresh one. Non-nil
    ///     only for ``reestablishLocalUnlock(contentKey:credential:grantingScope:)``, which rebuilds
    ///     the passcode gate around the key a custodian handed back — the sealed corpus is already
    ///     encrypted under it, so minting a fresh one there would lose everything.
    ///   - preservingRecoveryMaterial: Keeps `.recoveryBlob` + the custodian keys through the mint.
    ///     True only for the recovery re-establish, where the blob still seals the very key being
    ///     installed and the custodian therefore stays valid. (A device merely *awaiting* recovery
    ///     is protected without the flag — see ``isAwaitingCustodianRecovery``.)
    /// - Returns: The content-key bytes the records wrap (never persisted in the clear; the caller
    ///   decides whether to retain them).
    private func mintLockRecords(
        for credential: FernletLockCredential,
        contentKey suppliedContentKey: Data? = nil,
        preservingRecoveryMaterial: Bool = false
    ) async throws -> Data {
        // The recovery-sweep decision below turns on three presence reads, and on a recovery-locked
        // device the blob is the ONLY route back to the corpus. A transient read failure must never
        // read as "no custodian" and take the delete branch, so an undeterminable read refuses the
        // whole mint BEFORE a single row is written — the same rule `changeCredential` applies to an
        // undeterminable custody read (R5).
        if !preservingRecoveryMaterial {
            try refuseIfRecoveryMaterialUnreadable()
        }
        let saltData = try cryptoProvider.generateSalt()
        let derivedKey = try await cryptoProvider.deriveVerifier(passcode: credential.rawValue, salt: saltData, n: FernletLockCrypto.scryptN)
        let contentKeyData = try suppliedContentKey ?? cryptoProvider.generateContentKey()
        let wrappedContentKey = try cryptoProvider.wrapContentKey(contentKeyData, using: derivedKey)

        // A fresh content key has been minted: every surviving copy of the OLD one must go BEFORE
        // the new records are written, not after. Ordering is load-bearing — a throw (or an app
        // kill) between the first write and a trailing delete would otherwise leave a stale
        // biometric bypass holding the previous content key paired with the new credential, i.e.
        // a Face ID unlock that installs the wrong key. Deleting first can only ever cost a
        // re-enrollment, never mis-pair a key.
        KeychainItem.delete(for: .seWrappedContentKey, service: keychainService)
        KeychainItem.delete(for: .biometricBypass, service: keychainService)
        KeychainItem.delete(for: .biometricEnabledFlag, service: keychainService)
        // …and the same reasoning covers the duress rows. A duress PIN bound to a SUPERSEDED lock
        // must never survive into a new one (it would open a decoy for a passcode this user never
        // chose). Deleted BEFORE the new records are written, for the same ordering reason as the
        // copies above.
        for key in [LockKeychainKey.duressSalt, .duressVerifier, .duressMode, .duressKind] {
            KeychainItem.delete(for: key, service: keychainService)
        }
        // The recovery material is the ONE exception, and it is a data-loss exception. A fresh
        // content key normally makes the blob (and the custodian enrolled against it) meaningless,
        // so it goes with the rest — EXCEPT while this device is awaiting a custodian recovery, or
        // while the caller is the recovery itself. A recovery-locked device is `.notConfigured` and
        // therefore shows "set up app lock"; a user who taps that before reaching their custodian
        // would otherwise destroy the only route back to their corpus, silently and permanently.
        if preservingRecoveryMaterial {
            // The recovery itself: the key being installed IS the key the blob seals (checked
            // against the stored digest before we got here), so the enrollment is current again.
            KeychainItem.delete(for: .recoveryBlobSuperseded, service: keychainService)
        } else if isAwaitingCustodianRecovery {
            // The kept-but-stale case. The blob survives so the route back to the PRE-lock corpus
            // survives — but a fresh content key was just minted, so it cannot open a byte written
            // from here on. Marked, because `hasRecoveryCustodian` reads row presence and would
            // otherwise let `DuressMode.recoveryLock` be re-armed over a blob that hands back the
            // superseded key: the response would destroy the live key and the ceremony would report
            // success while orphaning everything written under this lock.
            try storeVerified(Data([1]), for: .recoveryBlobSuperseded)
        } else {
            for key in [
                LockKeychainKey.recoveryBlob,
                .custodianSigningPublicKey,
                .custodianKeyAgreementPublicKey,
                .recoveryOwnerKeyAgreementPublicKey,
                .recoveryBlobSuperseded
            ] {
                KeychainItem.delete(for: key, service: keychainService)
            }
        }

        try storeVerified(saltData, for: .salt)
        // Store the DIGEST of the derived key, not the derived key itself — the derived key is the
        // content-key wrapping key (used just above) and must never be persisted. See verifierDigest.
        try storeVerified(FernletLockCrypto.verifierDigest(of: derivedKey), for: .verifier)
        try storeVerified(Data(credential.kind.rawValue.utf8), for: .kind)
        try storeVerified(wrappedContentKey, for: .wrappedContentKey)
        try storeVerified(LockRecordCodec.encode(Int32(FernletLockCrypto.scryptN)), for: .scryptN)
        KeychainItem.delete(for: .cooldownDeadline, service: keychainService)
        KeychainItem.delete(for: .cooldownMonotonicAnchor, service: keychainService)
        KeychainItem.delete(for: .cooldownDurationSeconds, service: keychainService)
        KeychainItem.delete(for: .attemptCount, service: keychainService)
        KeychainItem.delete(for: .cooldownLevel, service: keychainService)
        KeychainItem.delete(for: .requiresReset, service: keychainService)
        return contentKeyData
    }

    /// Throws when ANY of the three recovery-material rows cannot be read, so no caller can infer
    /// "no custodian is enrolled" from a keychain that merely would not answer.
    ///
    /// `hasRecoveryCustodian` — and therefore `isAwaitingCustodianRecovery` — is three collapsing
    /// presence reads, and the branch it gates deletes the recovery blob. This is the guard that
    /// keeps a transient keychain failure from becoming silent, permanent loss of the only route
    /// back to a recovery-locked corpus.
    private func refuseIfRecoveryMaterialUnreadable() throws {
        for key in [
            LockKeychainKey.recoveryBlob,
            .custodianSigningPublicKey,
            .custodianKeyAgreementPublicKey
        ] {
            guard case .unreadable(let status) = keychainLoadDistinguishing(key, keychainService) else { continue }
            FernletAuditLog.log("lock.recoveryMaterialUnreadable", context: ["row": key.rawValue])
            throw FernletLockError.keychainFailure(operation: "read recovery material", status: status)
        }
    }

    /// Re-keys the lock under a new credential while preserving the content key.
    ///
    /// Verifies `current` (accepting the legacy raw-key verifier), recovers the content
    /// key, re-derives the credential records under a fresh salt, and rewrites the verifier
    /// in digest form. Refreshes the biometric-bypass item when biometrics are enabled.
    /// Because the content key is unchanged, sealed data never needs re-encryption.
    ///
    /// Both custody states are handled. LEGACY re-wraps the content key under the new derived
    /// key and rewrites ``LockKeychainKey/wrappedContentKey`` exactly as before. HARD-BOUND
    /// recovers the key from the Secure Enclave and **never rewrites that item** — a re-key
    /// changes only the passcode gate, and the enclave wrap is indifferent to it, so
    /// resurrecting a scrypt-wrapped copy would silently undo the hard binding.
    ///
    /// **Duress-aware in three directions (P7).** `current` is compared against the duress verifier
    /// FIRST, so a coerced re-key silently becomes a decoy instead of re-keying the real lock;
    /// `new` is rejected if it equals the duress PIN, which would otherwise strand the real content
    /// key behind a passcode that always takes the duress branch; and a change of credential KIND is
    /// rejected while a duress PIN of an incompatible kind is configured, because the surviving
    /// verifier would be unreachable at the new entry surface while the UI kept reporting it armed.
    ///
    /// The credential rows are written **all-or-nothing**: a failure anywhere in the write block
    /// rolls salt, verifier, kind, scrypt N and the wrapped content key back to their prior values
    /// (see `rollBackCredentialRecords`), because a new verifier over a stale wrap is a lock that
    /// takes the new passcode and can never open the content key again. An undeterminable custody
    /// read throws before any write at all.
    public func changeCredential(current: String, new: FernletLockCredential) async throws {
        try new.validate()
        guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
              let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService) else {
            throw FernletLockError.notConfigured
        }
        // DURESS FIRST — before the custody read, before the real verifier is even derived, and
        // therefore before any credential row can be touched. Forgetting this check here is one of
        // the two ways a coerced user's duress PIN could act on the REAL content key: "change your
        // passcode" is a plausible demand, and honoring it would re-key the real lock to a passcode
        // the coercer chose. A match returns the decoy instead, having rewritten nothing.
        if let mode = await duressMode(for: current) {
            await performDuressResponse(mode, passcode: current, scope: state.unlockedScope ?? .appLockSettings)
            return
        }
        let custody = contentKeyCustody()

        let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: current, salt: saltData, n: storedScryptN())
        // Accept either the current digest verifier or a legacy raw-key verifier; re-keying below
        // rewrites it in the new digest format regardless, so no separate migration step is needed.
        if case .none = verifierMatch(computedVerifier: computedVerifier, storedVerifier: storedVerifier) {
            throw FernletLockError.invalidPasscode
        }
        try await rejectDuressConflicts(with: new)

        let contentKeyData: Data
        switch custody {
        case .legacyScryptWrapped(let wrappedData):
            contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
        case .hardBoundToSecureEnclave:
            contentKeyData = try secureEnclaveBoundContentKey()
        case .undeterminable(let status):
            throw FernletLockError.keychainFailure(operation: "read wrappedContentKey", status: status)
        }
        let newSalt = try cryptoProvider.generateSalt()
        let newDerivedKey = try await cryptoProvider.deriveVerifier(passcode: new.rawValue, salt: newSalt, n: FernletLockCrypto.scryptN)

        try rewriteCredentialRecordsAtomically(
            newSalt: newSalt,
            newDerivedKey: newDerivedKey,
            newKind: new.kind,
            custody: custody,
            contentKeyData: contentKeyData,
            priorSalt: saltData,
            priorVerifier: storedVerifier
        )

        if KeychainItem.load(for: .biometricEnabledFlag, service: keychainService) != nil {
            try KeychainItem.storeBiometricBypass(contentKeyData, service: keychainService)
        }
        // Re-keying re-wraps the SAME content key, so refresh the in-memory copy — but only for the
        // scope entitled to it. Changing the passcode from Settings → App lock must not leave the
        // Private Hub's content key resident under a session that can never legitimately read it.
        if state.isUnlocked(for: .privateHub) {
            _contentKey = SymmetricKey(data: contentKeyData)
        } else {
            scrubContentKey()
        }
        // The content key is unchanged by a re-key, so the SE wrap normally still verifies;
        // this call is a self-heal in case it was missing or stale.
        maintainSecureEnclaveWrap(contentKeyData: contentKeyData)

        FernletAuditLog.log("lock.kindChanged", context: ["newKind": new.kind.rawValue])
    }

    /// The two ways a re-key could silently disarm the duress PIN, refused (P7).
    ///
    /// (1) The NEW credential may not BE the duress PIN. Without this a re-key could silently
    /// promote the duress PIN to the real passcode, after which every unlock takes the duress
    /// branch first and the real content key is unreachable forever — data loss dressed as a
    /// passcode change. Called only AFTER the current passcode has matched, so the "that code is
    /// special" signal is given exclusively to someone who has just proved they hold the real one.
    ///
    /// (2) The new credential's KIND may not make the surviving duress PIN unenterable. The
    /// own-salt design carries the duress rows through a re-key untouched, which is right for a
    /// same-kind change and silently fatal across a kind change: the lock renders one entry
    /// surface, the PIN pads are hard-capped at 4 or 6 digits and auto-submit at exactly that
    /// length, so a 4-digit duress code cannot be typed at a pin6 lock. The rows would survive,
    /// `hasDuressConfigured` would keep reporting an armed response, and under coercion the user
    /// would type a code that lands on the real-verifier path as a failed attempt. Refusing is the
    /// only fail-safe answer: the app cannot re-derive the verifier (it never holds the duress
    /// plaintext here), and silently deleting the duress PIN would disarm a safety feature without
    /// saying so.
    private func rejectDuressConflicts(with new: FernletLockCredential) async throws {
        if await duressMode(for: new.rawValue) != nil {
            throw FernletLockError.invalidCredential(Self.duressPINMatchesPasscodeMessage)
        }
        if hasDuressConfigured,
           let duressKind = storedDuressKind(),
           !Self.duressPINRemainsTypeable(duressKind: duressKind, under: new.kind) {
            throw FernletLockError.invalidCredential(Self.duressPINWouldBeUnenterableMessage)
        }
    }

    /// Writes the five credential rows of a re-key ALL-OR-NOTHING, restoring the prior values on
    /// any failure.
    ///
    /// A throw partway (any `storeVerified` can fail on a hosed keychain) would otherwise leave a
    /// verifier derived from the NEW passcode sitting over a wrap only the SUPERSEDED derived key
    /// opens — a lock that accepts the new passcode and can never recover the content key again.
    /// So the prior records are captured first and put back by `rollBackCredentialRecords` before
    /// the error is rethrown. The wrapped content key is rewritten only in the LEGACY custody
    /// state; hard-bound installs must never resurrect a scrypt-wrapped copy.
    private func rewriteCredentialRecordsAtomically(
        newSalt: Data,
        newDerivedKey: Data,
        newKind: FernletLockCredentialKind,
        custody: ContentKeyCustody,
        contentKeyData: Data,
        priorSalt: Data,
        priorVerifier: Data
    ) throws {
        let priorKind = KeychainItem.load(for: .kind, service: keychainService)
        let priorScryptN = KeychainItem.load(for: .scryptN, service: keychainService)
        let priorWrappedContentKey = KeychainItem.load(for: .wrappedContentKey, service: keychainService)
        do {
            try storeVerified(newSalt, for: .salt)
            try storeVerified(FernletLockCrypto.verifierDigest(of: newDerivedKey), for: .verifier)
            try storeVerified(Data(newKind.rawValue.utf8), for: .kind)
            if case .legacyScryptWrapped = custody {
                try storeVerified(try cryptoProvider.wrapContentKey(contentKeyData, using: newDerivedKey), for: .wrappedContentKey)
            }
            try storeVerified(LockRecordCodec.encode(Int32(FernletLockCrypto.scryptN)), for: .scryptN)
        } catch {
            rollBackCredentialRecords(
                salt: priorSalt,
                verifier: priorVerifier,
                kind: priorKind,
                scryptN: priorScryptN,
                wrappedContentKey: priorWrappedContentKey
            )
            throw error
        }
    }

    /// Attempts a passcode unlock.
    ///
    /// Refuses when a reset is required or a cooldown is active. On a wrong passcode it
    /// records the failed attempt (possibly escalating a cooldown) and throws
    /// `FernletLockError.invalidPasscode`; on success it migrates a legacy verifier if
    /// needed, clears attempt state, installs the content key, and unlocks.
    ///
    /// **Duress runs first (P7).** Before the reset/cooldown guards and before the real verifier is
    /// consulted, the entry is compared against the duress verifier; a match dispatches
    /// ``DuressMode`` and returns a benign-looking ``UnlockResult`` that opens the KEYLESS decoy.
    /// The comparison happens on EVERY unlock whether or not a duress PIN is configured, so unlock
    /// latency is constant and cannot be timed to answer "is there a duress PIN?"
    ///
    /// **Key custody.** The verifier check is identical in both states — it is what gates the
    /// attempt counter, and it runs before either recovery path. Recovery then splits: LEGACY
    /// unwraps the scrypt item, prefers a provably equal Secure-Enclave copy, and finally
    /// attempts the keep-old-until-verified hard-bind (this is where an upgrading install flips,
    /// on its first unlock under this build). HARD-BOUND recovers the key from the enclave
    /// alone — there is no scrypt item left to compare against, so the equality gate is not
    /// consulted; if the enclave cannot open its wrap, the unlock fails with
    /// `FernletLockError.contentKeyUnrecoverable` (terminal) or
    /// `.contentKeyTemporarilyUnavailable(status:)` (the keychain would not answer) rather than
    /// installing a wrong key, and the attempt state is left untouched (the passcode was right;
    /// nothing about it should be penalized or forgiven).
    ///
    /// **The terminal failure is tolerated for the two scopes that never receive the key.** A dead
    /// enclave key seals the sealed corpus, and `.privateHub` says so; it must not also seal the
    /// progress-photo wall (a different, intact key) or Settings → App lock (which hosts the only
    /// reachable reset). Those two unlock on the verifier match alone, holding no key — which is
    /// all they ever held.
    ///
    /// Unlocks FOR ONE SURFACE. `scope` is the caller's own surface — never a default, so a new
    /// gated screen cannot inherit someone else's unlock by forgetting to say who it is. The
    /// content key is only *retained* for `.privateHub` (see ``retainContentKey(_:for:)``); every
    /// other scope recovers it purely as the act of verifying the passcode and then drops it.
    /// - Returns: An ``UnlockResult`` with method `.passcode`.
    public func unlock(passcode: String, for scope: FernletLockScope) async throws -> UnlockResult {
        guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
              let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService) else {
            throw FernletLockError.notConfigured
        }
        // DURESS FIRST (P7): the duress compare runs after the records load but BEFORE the
        // requiresReset and cooldown guards, and returns without ever reaching
        // `recordFailedAttempt`. Both halves of that placement are deliberate.
        //
        // *Before the guards*, because lockout is exactly when coercion is likeliest — a duress PIN
        // that goes inert after four wrong attempts is a duress PIN that fails at the only moment
        // it was built for. This is not a brute-force oracle on the real passcode: the derivation
        // here is compared ONLY against the duress verifier, and a non-match falls straight through
        // into the untouched guards below.
        //
        // *Before the attempt counter*, because a duress entry must leave no forensic residue that
        // tells it apart from a benign unlock — see `enterDecoySession`, which clears attempt state
        // exactly as a successful unlock does and logs the same audit label.
        if let mode = await duressMode(for: passcode) {
            guard let result = await handleDuress(mode, passcode: passcode, scope: scope) else {
                // `.appLockSettings` was asked for, and a duress PIN may never open it (see
                // `handleDuress`). The response has already run; refuse the unlock itself with the
                // ordinary wrong-passcode error, which `handleDuress` has already made audit- and
                // counter-identical to a mistype.
                throw FernletLockError.invalidPasscode
            }
            return result
        }
        guard !requiresReset else { throw FernletLockError.resetRequired }
        if let deadline = activeCooldownDeadline() {
            state = .locked(cooldownDeadline: deadline)
            throw FernletLockError.cooldownActive(deadline: deadline)
        }
        let custody = contentKeyCustody()

        let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
        let match = verifierMatch(computedVerifier: computedVerifier, storedVerifier: storedVerifier)
        if case .none = match {
            try recordFailedAttempt()
            FernletAuditLog.log("lock.failedAttempt", context: ["cooldownLevel": "\(loadCooldownLevel())"])
            throw FernletLockError.invalidPasscode
        }
        // A correct passcode HAS been entered in this process, whatever key recovery does next.
        // Recorded here (not in the unlock tail) so a hard-bound recovery failure cannot strand
        // the biometric repair path; PIN-before-biometrics is untouched because only a verifier
        // match reaches this line.
        passcodeVerifiedThisProcess = true
        // Custody-independent staging sweep (crypto-standardization Phase 2.5, §Q2a): a re-wrap
        // staging orphan is a scrypt-openable copy of the content key; its lifetime is bounded by
        // the next successful passcode verification under EVERY custody state — legacy,
        // hard-bound, even undeterminable — never by the legacy arm, which the hard-bind flip may
        // retire in the very unlock that orphaned it. `errSecItemNotFound` is the silent benign
        // case; a real failure is audited inside `delete` (R7).
        KeychainItem.delete(for: .wrappedContentKeyRewrapStaging, service: keychainService)

        let contentKeyData: Data?
        switch custody {
        case .legacyScryptWrapped(let wrappedData):
            let scryptUnwrapped = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
            // Phase 2.5: standardize the row's wrap format at the ONE moment the wrapping key and
            // the provably recoverable content key are both in hand — after the successful scrypt
            // unwrap, before the SE flip below, so the convert runs on SE hardware too and the row
            // is standardized closest to its proof. Never throws, never gates the unlock.
            runLockWrapFormatMigration(contentKey: scryptUnwrapped, wrappingKey: computedVerifier)
            // Prefer the Secure-Enclave wrap when it exists AND provably matches the
            // scrypt-unwrapped key (the authoritative source while the legacy item is kept);
            // otherwise repair it.
            contentKeyData = secureEnclavePreferredContentKey(scryptUnwrapped: scryptUnwrapped)
            // The migration flip: with a freshly re-read enclave wrap proven to open to exactly
            // this key, the scrypt item goes and this install becomes hard-bound. Compares
            // against the scrypt-unwrapped bytes deliberately — the authoritative source, not
            // the copy the enclave just handed back. Deliberately BEFORE the scope is consulted,
            // so a non-hub unlock migrates too (the wrap is at-rest state, not session state).
            hardBindToSecureEnclaveIfVerified(contentKeyData: scryptUnwrapped, migratingExistingInstall: true)
        case .hardBoundToSecureEnclave:
            do {
                contentKeyData = try secureEnclaveBoundContentKey()
            } catch FernletLockError.contentKeyUnrecoverable where scope != .privateHub {
                // Entitlement, not convenience. `FernletLockScope` says `.privateHub` is the only
                // scope entitled to the content key, and `retainContentKey` scrubs it for the
                // other two anyway: progress photos seal under `PrivateMediaKeyStore`'s own
                // (intact) key and App-lock settings re-derive from the entered passcode. A dead
                // enclave key must not seal off a healthy photo wall — nor Settings → App lock,
                // which hosts the only reachable reset(). `.privateHub` still throws: the sealed
                // corpus really is gone, and saying so is the honest terminal state.
                FernletAuditLog.log("lock.contentKeyUnrecoverable.toleratedForScope", context: [
                    "scope": scope.rawValue
                ])
                contentKeyData = nil
            }
        case .undeterminable(let status):
            // The custody read failed; guessing would either install a stale enclave key over a
            // live legacy install or advise a destructive reset on a transient. Neither.
            throw FernletLockError.keychainFailure(operation: "read wrappedContentKey", status: status)
        }
        // First successful unlock under a build that splits the verifier from the wrapping key:
        // rewrite the raw-key verifier to its digest in place (best-effort, legacy match only).
        migrateLegacyVerifierIfNeeded(match, computedVerifier: computedVerifier)
        clearAttemptState()
        retainContentKey(contentKeyData, for: scope)
        state = .unlocked(scope: scope)
        hasAutoPromptedBiometricForCurrentLockSession = false
        // The process's passcode-first requirement is satisfied only HERE, at the end of a
        // fully successful passcode unlock — never on the biometric path (PIN-before-biometrics).
        passcodeUnlockedThisProcess = true
        // A REAL passcode has opened the lock, so any decoy session in force ends here. This is the
        // primary clear site; the others are the remaining proven-real-credential acts (configure,
        // reset, configureDuress, enrollRecoveryCustodian, reestablishLocalUnlock). Notably lock()
        // is NOT one of them, so a decoy survives re-locking and keeps biometrics suppressed until
        // this line runs.
        isDuressSessionActive = false
        FernletAuditLog.log("lock.released", context: ["method": "passcode", "scope": scope.rawValue])
        return UnlockResult(method: .passcode)
    }

    /// Attempts a biometric unlock by reading the `.biometryCurrentSet`-gated bypass item.
    ///
    /// **PIN-before-biometrics (fail-closed).** Refused with
    /// `FernletLockError.biometricNotAvailable` until ``passcodeUnlockedThisProcess`` is true —
    /// i.e. until one passcode success (``unlock(passcode:for:)`` or initial
    /// ``configure(credential:grantingScope:)``) has happened in the current app process, like
    /// iOS's first unlock after reboot. This guard is the load-bearing enforcement; the
    /// `FernletLockView` button/auto-prompt conditions on ``isBiometricUnlockAvailable`` are
    /// defense-in-depth. Throwing `.biometricNotAvailable` makes the unlock view fall back
    /// silently to passcode entry. A biometric success does NOT set the flag.
    ///
    /// The blocking LocalAuthentication + keychain read runs on a global user-initiated
    /// queue (or through the injected `biometricBypassLoader` in tests). Does not touch
    /// the passcode attempt counter — biometric lockout is the OS's job. Throws
    /// `FernletLockError.biometricNotAvailable`/`.biometricFailed` (or the underlying
    /// LocalAuthentication error).
    ///
    /// Biometric counterpart of ``unlock(passcode:for:)`` — same one-surface grant, same
    /// `.privateHub`-only key retention.
    /// - Returns: An ``UnlockResult`` with method `.biometric`.
    ///
    /// **The enclave outranks the bypass.** Once hard-bound, an openable enclave wrap is the
    /// authority on what the content key IS; the bypass row is only a convenience copy. So in
    /// that state the bytes this path recovered are checked against the enclave's before anything
    /// is installed, and a contradicted bypass is deleted rather than honored — a stale bypass
    /// must never seat a wrong key for the session. When the enclave has no openable blob at all
    /// (its key was rotated or destroyed), the bypass IS the surviving copy and
    /// `maintainSecureEnclaveWrap` re-establishes the wrap from it: that is the repair the
    /// unrecoverable state points the user at.
    public func unlockWithBiometrics(for scope: FernletLockScope) async throws -> UnlockResult {
        guard !requiresReset else { throw FernletLockError.resetRequired }
        // PIN-before-biometrics (P0b): fail closed at the service, before any keychain or
        // LocalAuthentication work. The UI gates are advisory; this guard is the guarantee.
        // Either flag satisfies it because BOTH are set only by a correct passcode entry in this
        // process — the wider one keeps this path (the surviving key copy, and the wrap repair it
        // performs) reachable when a hard-bound unlock fails at key recovery after the passcode
        // proved correct. A wrong attempt sets neither, so biometrics are still never the first
        // factor after launch.
        guard passcodeUnlockedThisProcess || passcodeVerifiedThisProcess else {
            throw FernletLockError.biometricNotAvailable
        }
        // Duress suppression, at the same fail-closed seam and for the same reason (P7). The UI
        // policy `isBiometricUnlockAvailable` also carries this conjunct, but the guarantee has to
        // live HERE: in the non-destructive decoy the `.biometricBypass` row still holds the REAL
        // content key, and the process flags above may well already be true (a normal unlock
        // earlier in the same launch sets them and only reset() clears them), so without this line
        // a coercer could walk straight around the decoy with Face ID. Same error as every other
        // refusal on this path, so the unlock view falls back to passcode entry silently rather
        // than surfacing anything a duress session could be read from.
        guard !isDuressSessionActive else {
            throw FernletLockError.biometricNotAvailable
        }
        isPerformingBiometricUnlock = true
        defer { isPerformingBiometricUnlock = false }

        var contentKeyData: Data
        if let biometricBypassLoader {
            contentKeyData = try biometricBypassLoader("Unlock Fernlet", keychainService)
        } else {
            let context = LAContext()
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
                throw FernletLockError.biometricNotAvailable
            }

            let service = keychainService
            contentKeyData = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        let data = try KeychainItem.loadBiometricBypassSync(prompt: "Unlock Fernlet", service: service)
                        continuation.resume(returning: data)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }

        // Shape check before the bytes are seated (R5): `SymmetricKey(data:)` accepts ANY length, so
        // a truncated or corrupt bypass row would install a wrong-length key and every sealed read
        // would fail with an opaque authentication error instead of a named cause. The row is
        // dropped so the next unlock re-enrolls it. `reestablishLocalUnlock` already applies exactly
        // this guard to the key a custodian hands back.
        guard contentKeyData.count == FernletLockCrypto.keyLength else {
            KeychainItem.delete(for: .biometricBypass, service: keychainService)
            FernletAuditLog.log("lock.biometricBypassMalformed", context: ["bytes": "\(contentKeyData.count)"])
            throw FernletLockError.biometricFailed
        }

        // Accepted residual (document & accept, not a regression): a biometric-only legacy install
        // (upgraded from a pre-split build, enrolled biometrics, never enters a passcode) keeps
        // .verifier = the RAW scrypt derived key (= the content-key wrapping key). This path recovers
        // the content key directly from the biometric-bypass blob and never derives a scrypt key, so it
        // cannot compute SHA256(derivedKey) to migrate the verifier to its digest the way unlock()/
        // changeCredential() do. We accept this because: the attack presupposes device compromise +
        // keychain extraction; the bypass blob already holds the content key under a stricter
        // (.biometryCurrentSet) ACL, so the un-migrated raw verifier is only a second, less-gated path
        // to the same key; and everything here is ThisDeviceOnly (no off-device/iCloud exposure). The
        // first subsequent passcode unlock (unlock/changeCredential) migrates the verifier to its digest.

        // Hard-bound: the enclave is the authority, so a bypass it contradicts is stale — install
        // the enclave's bytes and drop the row rather than seat a key the at-rest wrap disagrees
        // with. A recovery FAILURE here is not fatal: it means the enclave has nothing openable,
        // which is exactly the state this path exists to repair below.
        if case .hardBoundToSecureEnclave = contentKeyCustody(),
           let enclaveKey = try? secureEnclaveBoundContentKey(),
           !constantTimeEqual(enclaveKey, contentKeyData) {
            FernletAuditLog.log("lock.biometricBypassContradictedByEnclave")
            KeychainItem.delete(for: .biometricBypass, service: keychainService)
            contentKeyData = enclaveKey
        }
        retainContentKey(contentKeyData, for: scope)
        state = .unlocked(scope: scope)
        hasAutoPromptedBiometricForCurrentLockSession = false
        // Scope-independent, like configure(): the at-rest SE wrap is maintained on every
        // successful unlock even when this scope does not keep the key resident.
        maintainSecureEnclaveWrap(contentKeyData: contentKeyData)
        FernletAuditLog.log("lock.released", context: ["method": "biometric", "scope": scope.rawValue])
        return UnlockResult(method: .biometric)
    }

    /// Engages the lock (no-op unless `.unlocked`), scrubbing the in-memory content key
    /// and re-surfacing any still-active cooldown deadline.
    public func lock(reason: FernletLockReason) {
        guard case .unlocked = state else { return }
        scrubContentKey()
        state = .locked(cooldownDeadline: activeCooldownDeadline())
        FernletAuditLog.log("lock.engaged", context: ["reason": reason.auditLabel])
    }

    /// Called by a gated surface as it comes forward: if the unlock in force belongs to a DIFFERENT
    /// surface, revoke it (scrubbing the content key) so the arriving screen must authenticate on
    /// its own. A no-op when locked, not configured, or already unlocked for `scope`.
    ///
    /// This is the appear-side half of the guarantee, and it is the half that actually closes the
    /// hole: the departure-side `lock(reason: .viewDisappeared)` is legitimately suppressed by
    /// covering sheets, the camera's full-screen cover and scene transitions, so a surface must not
    /// depend on the surface it replaced having locked itself.
    public func revokeUnlockOutside(_ scope: FernletLockScope) {
        guard let current = state.unlockedScope, current != scope else { return }
        lock(reason: .scopeChanged)
    }

    /// The destructive escape hatch: deletes every lock keychain item (including the
    /// Secure-Enclave key and its wrap), purges the pending-narrative buffer AND the sealed
    /// encrypted CoreData entities, rebuilds the sealed store file, scrubs the content key, and
    /// returns to `.notConfigured` — which by construction is no scope's unlock.
    ///
    /// This is Fernlet's one FULLY honest erase, and the seam the Phase-7 duress WIPE reuses:
    /// EVERY key that seals a byte in the private store is destroyed, which makes every surviving
    /// byte of ciphertext instantly meaningless, AND the store file is destroyed and re-created,
    /// which removes the logical `-wal`/freelist residue the row purge leaves behind. "Every key"
    /// is three sweeps, and it takes all three to earn the claim:
    /// - `KeychainItem.deleteAll(service:)` over ``keychainService`` — every generic password under
    ///   the lock service, the wrapped content key among them;
    /// - `SecureEnclaveContentKeyWrap.deleteKey` — the SE wrap, a `kSecClassKey` item outside that
    ///   generic-password sweep;
    /// - `KeychainItem.deleteAll(service:)` over each of ``sealedContentKeyServices`` — the journal
    ///   and Worry Box **device fallback keys**, which seal those two entities' rows whenever no
    ///   content key exists (`JournalSealingCoordinator`, `WorryBoxService`). Without this sweep
    ///   "crypto-erased" would be false for exactly the rows written while the lock was closed.
    ///
    /// The "delete everything" funnel gets only the file half — the app-lock keychain is a
    /// documented survivor there — so its honest claim is weaker (see
    /// `PrivatePersistenceController.rebuildStore()`). One asymmetry stays flagged rather than
    /// fixed here: the locked-note buffer key (`com.fernlet.narrative-buffer`) is not swept, and
    /// removing it is a tracked owner call.
    ///
    /// Ordering: rows first, then the rebuild, so a rebuild failure still leaves the rows deleted.
    /// A rebuild failure is rethrown, but only AFTER the in-memory state has been returned to
    /// `.notConfigured` — the keychain rows are already gone by then, so bailing early would leave
    /// the service claiming an unlock it can no longer honor.
    ///
    /// - Important: Sealed content is unrecoverable afterward — the content key is gone.
    public func reset() throws {
        KeychainItem.deleteAll(service: keychainService)
        // The Secure Enclave key is a kSecClassKey item outside the generic-password sweep above.
        // Its delete status is the evidence behind this method's "crypto-erased" claim, so it is
        // checked and — when the key still loads afterwards — reported, rather than assumed (R7).
        let enclaveDeleteStatus = SecureEnclaveContentKeyWrap.deleteKey(service: keychainService)
        if enclaveDeleteStatus != errSecSuccess, enclaveDeleteStatus != errSecItemNotFound {
            FernletAuditLog.log("lock.reset.enclaveKeyDeleteFailed", context: ["status": "\(enclaveDeleteStatus)"])
        }
        if case .loaded = SecureEnclaveContentKeyWrap.loadKeyResult(service: keychainService) {
            FernletAuditLog.log("lock.reset.enclaveKeySurvived")
        }
        // The journal / Worry Box device fallback keys seal rows in the store this method is about
        // to purge whenever no content key exists, so leaving them alive would leave the residue
        // this method claims to have crypto-erased openable. Destroyed BEFORE the purge/rebuild, so
        // the claim holds even if a later step throws; they regenerate lazily on next use (the same
        // reasoning `FernletStore.deleteAllData` applies when it deletes the same two keys).
        for service in sealedContentKeyServices {
            KeychainItem.deleteAll(service: service)
        }
        try buffer.purge()
        try privatePersistenceController.purgeEncryptedEntities()
        // Keyless by invariant (no contentKey, no decrypt): the rebuild must stay usable from every
        // locked deletion path, and this one has just destroyed the key anyway.
        var rebuildError: (any Error)?
        do {
            try privatePersistenceController.rebuildStore()
        } catch {
            rebuildError = error
        }
        scrubContentKey()
        state = .notConfigured
        hasAutoPromptedBiometricForCurrentLockSession = false
        isPerformingBiometricUnlock = false
        // Back to a fresh notConfigured process state: the next passcode success (a new
        // configure) must re-earn the biometric offer (PIN-before-biometrics).
        passcodeUnlockedThisProcess = false
        passcodeVerifiedThisProcess = false
        // The duress rows went with the sweep above, so no duress PIN survives to defend against —
        // the most final of the flag's clear sites.
        isDuressSessionActive = false
        FernletAuditLog.log("lock.reset")
        // Nothing-silent: the rows are gone, but the file they lived in could not be rebuilt, so
        // the caller must be able to say so rather than promise a clean store.
        if let rebuildError { throw rebuildError }
    }

    /// Enables or disables biometric unlock.
    ///
    /// Enabling verifies the passcode, then stores the raw content key behind a
    /// `.biometryCurrentSet` access control and sets the enabled flag; disabling deletes
    /// both items. Also opportunistically migrates a legacy verifier (see `unlock`).
    ///
    /// Recovers the content key through whichever custody state is in force (scrypt unwrap when
    /// legacy, the Secure-Enclave wrap once hard-bound). **Documented residual:** the bypass item
    /// holds the RAW content key behind a data-protection ACL rather than inside the enclave, so
    /// while biometrics are enabled the hard-bound guarantee is weakened to that ACL's strength
    /// (`WhenPasscodeSetThisDeviceOnly` + `.biometryCurrentSet`, still device-bound and destroyed
    /// by ``reset()``) — see `Docs/Verifiability.md` §5.
    ///
    /// **Duress-aware (P7):** the passcode is compared against the duress verifier FIRST, so a
    /// coerced "turn on Face ID" enables nothing and presents the decoy instead.
    public func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws {
        if enabled {
            guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
                  let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService) else {
                throw FernletLockError.notConfigured
            }
            // DURESS FIRST (P7) — the second of the two ways a duress PIN could otherwise reach the
            // REAL content key. Enabling biometrics writes the raw content key into the
            // `.biometryCurrentSet` bypass row, i.e. a permanent, PIN-free door around the decoy
            // for whoever holds the coerced device's face. A match presents the decoy and enables
            // NOTHING. Only the enabling branch needs the check: disabling consults no passcode
            // and only ever deletes.
            if let mode = await duressMode(for: passcode) {
                await performDuressResponse(mode, passcode: passcode, scope: state.unlockedScope ?? .appLockSettings)
                return
            }
            let custody = contentKeyCustody()

            let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
            let match = verifierMatch(computedVerifier: computedVerifier, storedVerifier: storedVerifier)
            if case .none = match {
                throw FernletLockError.invalidPasscode
            }

            let contentKeyData: Data
            switch custody {
            case .legacyScryptWrapped(let wrappedData):
                contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
            case .hardBoundToSecureEnclave:
                contentKeyData = try secureEnclaveBoundContentKey()
            case .undeterminable(let status):
                throw FernletLockError.keychainFailure(operation: "read wrappedContentKey", status: status)
            }
            // Opportunistically migrate a legacy raw-key verifier to its digest (see unlock()).
            migrateLegacyVerifierIfNeeded(match, computedVerifier: computedVerifier)
            try KeychainItem.storeBiometricBypass(contentKeyData, service: keychainService)
            try storeVerified(Data([1]), for: .biometricEnabledFlag)
        } else {
            KeychainItem.delete(for: .biometricBypass, service: keychainService)
            KeychainItem.delete(for: .biometricEnabledFlag, service: keychainService)
        }
    }

    // MARK: - Duress PIN (P7)

    /// The rejection copy shown when a duress PIN is the same secret as the real passcode (in
    /// either direction: choosing it as the duress PIN, or re-keying the real passcode to it).
    /// A constant so the two rejection sites and their tests cannot drift apart.
    static let duressPINMatchesPasscodeMessage = "Your duress code must be different from your passcode."

    /// The rejection copy shown when ``DuressMode/recoveryLock`` is chosen with no enrolled
    /// custodian device — a response that would otherwise destroy the local keys with nothing on
    /// the other side able to give them back.
    static let duressRecoveryCustodianRequiredMessage =
        "Set up a recovery device before choosing this response."

    /// The rejection copy shown when a recovery device is un-enrolled while ``DuressMode/recoveryLock``
    /// is still the armed duress response — removing it would leave a response that destroys the
    /// local keys with nothing left to give them back.
    static let recoveryCustodianInUseMessage =
        "Change your duress response before removing your recovery device."

    /// The rejection copy shown when an enrollment is offered public keys that are not the exact
    /// Curve25519 raw length the ceremony produces.
    static let recoveryCustodianInvalidKeyMessage =
        "That recovery device's code wasn't valid. Scan it again."

    /// The rejection copy shown when ``reestablishLocalUnlock(contentKey:credential:grantingScope:)``
    /// is handed a key that is NOT the key the recovery blob seals. Installing it would re-lock the
    /// device around bytes that open nothing, permanently — so it is refused instead.
    static let recoveryKeyMismatchMessage =
        "That key doesn't match this phone's sealed data, so it wasn't installed."

    /// The rejection copy shown when a recovery is attempted on a device that never enrolled a
    /// custodian (or whose recovery material is gone).
    static let recoveryNotAvailableMessage =
        "This phone has no recovery device set up."

    /// Raw Curve25519 public-key length, the only shape an enrolled custodian's keys may have.
    ///
    /// Mirrors `ProximityKit.ProximityVerifySignature.publicKeyByteCount` **by value rather than by
    /// import**: the ceremony that produces these keys lives app-side precisely so this module gains
    /// no ProximityKit edge (§11 "Seam placement / wall"), so the constant is restated here and the
    /// app-side coordinator's tests pin that the two agree.
    static let recoveryCustodianPublicKeyByteCount = 32

    /// The keychain service holding the private-media content keys (own photos + friend wall).
    ///
    /// Mirrors `PrivateMediaStore.PrivateMediaKeyStore.service` **by value rather than by import**:
    /// this module has no `PrivateMediaStore` edge and gains none for a wipe sweep. The app-target
    /// test suite pins that the two strings agree, exactly as it does for
    /// ``recoveryCustodianPublicKeyByteCount``.
    public static let privateMediaKeychainService = "com.fernlet.private-media"

    /// The rejection copy shown when a duress-sensitive action is attempted while a duress session
    /// is in force. Deliberately generic: it names no duress feature, because the one place it can
    /// surface is a screen a coercer is holding.
    static let duressSessionRefusalMessage =
        "Enter your passcode again to change this."

    /// The rejection copy shown when a credential-KIND change would leave the configured duress PIN
    /// unenterable on the new entry surface.
    static let duressPINWouldBeUnenterableMessage =
        "Your duress code can't be typed on that kind of lock. Remove or change your duress code first."

    /// The rejection copy shown when ``DuressMode/recoveryLock`` is armed over a recovery blob that
    /// seals a SUPERSEDED content key (see ``LockKeychainKey/recoveryBlobSuperseded``).
    static let recoveryCustodianSupersededMessage =
        "Your recovery device holds the key from before this app lock. Set it up again before choosing this."

    /// Whether a duress PIN is configured.
    ///
    /// Reads the presence of ``LockKeychainKey/duressVerifier`` — deliberately NOT of
    /// ``LockKeychainKey/duressSalt``, which exists unconditionally so the derivation shape (and
    /// therefore the unlock latency) never depends on the answer to this question.
    public var hasDuressConfigured: Bool {
        keychainLoad(.duressVerifier, keychainService) != nil
    }

    /// The response the configured duress PIN triggers, or `nil` when no duress PIN is configured.
    ///
    /// Exists for the settings screen, which has to show the user which response is armed and
    /// pre-select it when they change it — "you have a duress code" without "and this is what it
    /// does" is exactly the kind of half-state that gets a destructive response armed by accident.
    ///
    /// Gated on ``hasDuressConfigured`` rather than reading the mode row alone, so a stale byte left
    /// by a partially-removed configuration can never be read as an armed response. It discloses
    /// nothing a keychain reader could not already see, and only a caller that already holds the
    /// real credential ever reaches it (see ``configureDuress(pin:mode:)`` on why that gate is by
    /// construction).
    public var configuredDuressMode: DuressMode? {
        guard hasDuressConfigured else { return nil }
        return storedDuressMode() ?? .decoy
    }

    /// Whether a recovery custodian — the user's own second device — is enrolled: BOTH of its public
    /// keys AND the sealed recovery blob are present.
    ///
    /// Deliberately reads all THREE rows rather than the two public keys. The question this property
    /// actually answers, everywhere it is asked, is "may this device destroy its local unlock keys
    /// and still get them back?" — and the answer is no without the blob, which is the only thing
    /// the custodian can turn back into a content key. Two public keys with no blob is a half-written
    /// enrollment, and treating it as an enrolled custodian would let ``DuressMode/recoveryLock`` be
    /// armed over an unrecoverable device.
    ///
    /// The enrollment ceremony (in-person QR mutual auth) lives in the app-side
    /// `DuressRecoveryCoordinator` so `FernletLock` gains no ProximityKit edge; the persistence half
    /// is ``enrollRecoveryCustodian(passcode:signingPublicKey:keyAgreementPublicKey:ownKeyAgreementPublicKey:sealingContentKeyTo:)``,
    /// which writes the blob LAST for exactly this reason.
    public var hasRecoveryCustodian: Bool {
        custodianRecoveryBlob != nil
            && keychainLoad(.custodianSigningPublicKey, keychainService) != nil
            && keychainLoad(.custodianKeyAgreementPublicKey, keychainService) != nil
    }

    /// Whether the enrolled custodian's blob seals a content key this device NO LONGER USES.
    ///
    /// True in exactly one state: a recovery-locked device whose user set up a new app lock before
    /// reaching their custodian. ``mintLockRecords(for:contentKey:preservingRecoveryMaterial:)``
    /// keeps the blob there on purpose — it is the only route back to everything written before the
    /// recovery-lock fired — and marks it, because it seals the OLD key while the lock now holds a
    /// new one.
    ///
    /// Deliberately NOT folded into ``hasRecoveryCustodian``. That property gates the "Recover this
    /// phone" route, which must stay reachable in precisely this state; this one gates *arming*
    /// ``DuressMode/recoveryLock`` again, which must not be. Re-enrolling the custodian re-seals to
    /// the live key and clears it, as does completing the recovery.
    public var hasSupersededRecoveryBlob: Bool {
        hasRecoveryCustodian && keychainLoad(.recoveryBlobSuperseded, keychainService) != nil
    }

    /// THIS device's key-agreement public key as recorded when the custodian was enrolled, or `nil`
    /// when no enrollment (or no such record) exists.
    ///
    /// Read by the app-side coordinator, which is the only side that can see the LIVE proximity
    /// identity, so it can spot a rotation and call
    /// ``invalidateRecoveryCustodianForRotatedIdentity()``. See
    /// ``LockKeychainKey/recoveryOwnerKeyAgreementPublicKey`` for why the blob depends on it.
    public var enrolledRecoveryOwnerKeyAgreementPublicKey: Data? {
        keychainLoad(.recoveryOwnerKeyAgreementPublicKey, keychainService)
    }

    /// Retires the recovery enrollment because this device's proximity identity has rotated, which
    /// makes the sealed blob permanently unopenable by anyone.
    ///
    /// **Why this exists.** The blob is sealed with this device's long-term key-agreement key mixed
    /// into the key derivation and the AEAD's additional data, and the custodian opens it with the
    /// live, ceremony-proven sender key. Rotate the identity and no device on earth can open the
    /// blob again — and an ordinary "Delete everything" does exactly that, while deliberately
    /// keeping the app lock, the content key and these rows. ``hasRecoveryCustodian`` proves three
    /// rows exist, not that they can still be turned back into a key, so without this the device
    /// would keep ``DuressMode/recoveryLock`` armed over a dead blob: firing it would destroy every
    /// local unlock key and the ceremony would fail with "this phone can't open that request",
    /// leaving the corpus unrecoverable forever. That is the unannounced permanent lock-out the
    /// mode's fail-closed guard exists to prevent.
    ///
    /// **Refuses nothing and asks for nothing.** Unlike ``removeRecoveryCustodian()`` it does NOT
    /// stop at an armed `.recoveryLock`: a dead blob is strictly worse than no blob, and the whole
    /// point is to make the response degrade to the non-destructive decoy. When `.recoveryLock` was
    /// the armed response it is rewritten to ``DuressMode/decoy``, so the persisted byte matches the
    /// behaviour the fail-closed guard would produce anyway and the settings screen stops promising
    /// a recovery it can no longer perform.
    ///
    /// Silent (no audit event) for the same reason the rest of the duress API is, and idempotent.
    ///
    /// - Returns: `true` when an enrollment was actually retired.
    public func invalidateRecoveryCustodianForRotatedIdentity() -> Bool {
        guard hasRecoveryCustodian else { return false }
        if hasDuressConfigured, storedDuressMode() == .recoveryLock {
            do {
                try storeVerified(Data([DuressMode.decoy.rawValue]), for: .duressMode)
            } catch {
                // Recovery, not a swallow: a mode byte that cannot be downgraded is DELETED, because
                // a missing row reads as `.decoy` everywhere (`storedDuressMode() ?? .decoy`) — the
                // same fail-closed state the write was reaching for. Deliberately no audit line, per
                // the duress-silence invariant this whole API observes.
                KeychainItem.delete(for: .duressMode, service: keychainService)
            }
        }
        for key in [
            LockKeychainKey.recoveryBlob,
            .custodianSigningPublicKey,
            .custodianKeyAgreementPublicKey,
            .recoveryOwnerKeyAgreementPublicKey,
            .recoveryBlobSuperseded
        ] {
            KeychainItem.delete(for: key, service: keychainService)
        }
        return true
    }

    /// Whether this device is sitting in the post-``DuressMode/recoveryLock`` state: recovery
    /// material intact, no local unlock left at all.
    ///
    /// Read by the app-side recovery flow to know a ceremony is owed, and — more importantly —
    /// by ``mintLockRecords(for:contentKey:preservingRecoveryMaterial:)``, which normally sweeps the
    /// recovery rows when a fresh content key is minted. In THIS state that sweep would be silent,
    /// permanent data loss: the blob is the only route back to the sealed corpus, and "set up app
    /// lock" is exactly what a recovery-locked device offers, so a user who taps it before reaching
    /// their custodian would destroy the route while trying to get on with their day.
    public var isAwaitingCustodianRecovery: Bool {
        hasRecoveryCustodian && keychainLoad(.verifier, keychainService) == nil
    }

    /// The enrolled custodian device's Ed25519 signing public key, or nil when none is enrolled.
    ///
    /// The recovery ceremony compares the peer it proved against this: a valid QR + challenge round
    /// with SOME device is not recovery, it is recovery **with the enrolled custodian**, and the
    /// difference is what stops a stranger's phone from handing back bytes that would be installed
    /// as the content key.
    public var enrolledCustodianSigningPublicKey: Data? {
        keychainLoad(.custodianSigningPublicKey, keychainService)
    }

    /// The enrolled custodian device's X25519 key-agreement public key — the key
    /// ``custodianRecoveryBlob`` is sealed to, and the only key that can open it.
    public var enrolledCustodianKeyAgreementPublicKey: Data? {
        keychainLoad(.custodianKeyAgreementPublicKey, keychainService)
    }

    /// The sealed recovery blob to hand the custodian, or nil when none is enrolled.
    ///
    /// The stored row is `digest ‖ sealed` (see
    /// ``enrollRecoveryCustodian(passcode:signingPublicKey:keyAgreementPublicKey:ownKeyAgreementPublicKey:sealingContentKeyTo:)``);
    /// only the sealed half leaves this device. The digest half never does — it is this device's own
    /// check value for what comes back, and sending it would hand a would-be custodian a target to
    /// grind against rather than a key to open.
    public var custodianRecoveryBlob: Data? {
        guard let row = keychainLoad(.recoveryBlob, keychainService),
              row.count > SHA256.byteCount else { return nil }
        return Data(row.dropFirst(SHA256.byteCount))
    }

    /// This device's check value for the content key the recovery blob seals: the first
    /// `SHA256.byteCount` bytes of the `.recoveryBlob` row.
    ///
    /// Domain-separated (see ``recoveryContentKeyDigest(of:)``) and never sent anywhere. It exists
    /// so ``reestablishLocalUnlock(contentKey:credential:grantingScope:)`` can REFUSE a key that is
    /// not the one this device's corpus is sealed under — turning "the ceremony returned the wrong
    /// bytes" from permanent silent data loss into a named error.
    private func storedRecoveryContentKeyDigest() -> Data? {
        guard let row = keychainLoad(.recoveryBlob, keychainService),
              row.count > SHA256.byteCount else { return nil }
        return Data(row.prefix(SHA256.byteCount))
    }

    /// The recovery blob's content-key check value: `SHA256("fernlet.lock.recovery.contentkey.v1" ‖ key)`.
    ///
    /// Domain-separated from ``FernletLockCrypto/verifierDigest(of:)`` on purpose — the two digests
    /// live in the same keychain namespace and are both SHA-256 over key material, and a value that
    /// could be moved from one row to the other is a value that could be used to install the wrong
    /// key. Safe to persist: SHA-256 of a uniformly random 256-bit key is neither invertible nor
    /// grindable.
    private nonisolated static func recoveryContentKeyDigest(of contentKey: Data) -> Data {
        Data(SHA256.hash(data: FernletCryptoPurpose.Hash.recoveryContentKeyV1.data + contentKey))
    }

    /// Configures — or replaces — the single duress PIN and the one response it triggers.
    ///
    /// **Real-PIN-gated by construction, not by a re-prompt.** The only entry point is Settings →
    /// App lock, a `.appLockSettings` surface the user must already have unlocked with the REAL
    /// passcode: biometrics can never be the first factor after launch (PIN-before-biometrics), they
    /// are suppressed outright during a duress session, and — the load-bearing half —
    /// ``handleDuress(_:passcode:scope:)`` refuses to grant `.appLockSettings` to a duress PIN at
    /// all. Reaching this call therefore already proves the real credential, which is why it takes
    /// no `current` passcode of its own. The `isDuressSessionActive` guard below is the belt to that
    /// braces: if a decoy session ever did reach this screen, changing the duress code from inside
    /// one must not be a way to disarm it.
    ///
    /// **Emits no audit event, deliberately.** `FernletAuditLog` event names reach the unified log
    /// with `.auto` privacy, so a `lock.duressConfigured` line would survive in a sysdiagnose and
    /// tell anyone who pulled one that this device HAS a duress PIN — the single fact the whole
    /// feature depends on hiding. Configuration is a calm, user-initiated, UI-visible act; the
    /// audit trail buys nothing here and costs the property that matters. ``removeDuress()`` is
    /// silent for the same reason.
    ///
    /// - Parameters:
    ///   - pin: The duress secret, validated against ``credentialKind`` because the lock renders
    ///     exactly one entry surface and a PIN that cannot be typed there is not a duress PIN.
    ///   - mode: The response a duress entry triggers.
    /// - Throws: `FernletLockError.notConfigured` when no lock exists;
    ///   `FernletLockError.invalidCredential` when a duress session is in force, when the PIN does
    ///   not fit the configured credential's format, when it EQUALS the real passcode (which would
    ///   make every unlock a duress unlock and strand the real content key), or when
    ///   ``DuressMode/recoveryLock`` is chosen with no enrolled custodian or over a superseded
    ///   recovery blob; `FernletLockError.keychainFailure` when a row cannot be written.
    public func configureDuress(pin: String, mode: DuressMode) async throws {
        try refuseDuringDuressSession()
        guard let saltData = keychainLoad(.salt, keychainService),
              let storedVerifier = keychainLoad(.verifier, keychainService),
              let kind = credentialKind else {
            throw FernletLockError.notConfigured
        }
        try FernletLockCredential(kind: kind, rawValue: pin).validate()
        guard mode != .recoveryLock || hasRecoveryCustodian else {
            throw FernletLockError.invalidCredential(Self.duressRecoveryCustodianRequiredMessage)
        }
        // A custodian is enrolled, but against a content key this device no longer uses (it minted a
        // fresh one when the user set up a lock after a recovery-lock fired). Arming the response
        // over that blob is the trap `hasRecoveryCustodian` alone cannot see: firing it would
        // destroy the LIVE key and the ceremony would hand back the superseded one, silently losing
        // everything written since. Re-enrolling re-seals to the live key and clears this.
        guard mode != .recoveryLock || !hasSupersededRecoveryBlob else {
            throw FernletLockError.invalidCredential(Self.recoveryCustodianSupersededMessage)
        }
        // A duress PIN equal to the real passcode is a data-loss trap rather than a nuisance: the
        // duress compare runs FIRST in unlock(), so the real content key would become permanently
        // unreachable the moment this was accepted. Checked through the same verifierMatch the real
        // unlock path uses, so a legacy raw-key verifier is caught too.
        let derivedUnderPrimarySalt = try await cryptoProvider.deriveVerifier(
            passcode: pin,
            salt: saltData,
            n: storedScryptN()
        )
        switch verifierMatch(computedVerifier: derivedUnderPrimarySalt, storedVerifier: storedVerifier) {
        case .none:
            break  // Distinct from the real passcode — proceed.
        case .current, .legacy:
            throw FernletLockError.invalidCredential(Self.duressPINMatchesPasscodeMessage)
        }

        // Own salt, and a FIXED cost parameter. `storedScryptN()` is deliberately not used: it is
        // rewritten by changeCredential, which would strand a duress verifier derived under the old
        // value on the very next passcode change — the same stranding the own-salt decision exists
        // to avoid.
        let duressSalt = try cryptoProvider.generateSalt()
        let duressDerived = try await cryptoProvider.deriveVerifier(
            passcode: pin,
            salt: duressSalt,
            n: FernletLockCrypto.scryptN
        )
        // Write order is disarm → salt → mode → VERIFIER LAST, because the verifier is the
        // discriminator `hasDuressConfigured` reads. Replacing an existing duress PIN otherwise has
        // a window where the old verifier sits over the new salt: a duress PIN that silently no
        // longer works while the UI still reports one is configured. Disarming first makes every
        // intermediate state legible — "no duress PIN" until the last write lands, at which point
        // its salt and mode are already in place.
        KeychainItem.delete(for: .duressVerifier, service: keychainService)
        try storeVerified(duressSalt, for: .duressSalt)
        try storeVerified(Data([mode.rawValue]), for: .duressMode)
        // The kind the PIN was entered as, so a later credential-KIND change can refuse rather than
        // strand a duress PIN that can no longer be typed (see `LockKeychainKey.duressKind`).
        try storeVerified(Data(kind.rawValue.utf8), for: .duressKind)
        try storeVerified(FernletLockCrypto.verifierDigest(of: duressDerived), for: .duressVerifier)
    }

    /// Removes the configured duress PIN, its mode and its kind.
    ///
    /// The salt row goes too; the next unlock re-mints a dummy in its place, restoring the
    /// unconditional-derivation shape. Silent for the same reason ``configureDuress(pin:mode:)``
    /// is. Idempotent — deleting a missing keychain item is not an error.
    ///
    /// **Refuses during a duress session**, like every other duress mutator: "delete the duress
    /// code" is the first thing a coercer who worked out that one exists would reach for, and the
    /// real user can always clear it by entering their real passcode first.
    ///
    /// - Throws: `FernletLockError.invalidCredential` while a duress session is in force.
    public func removeDuress() throws {
        try refuseDuringDuressSession()
        for key in [LockKeychainKey.duressVerifier, .duressMode, .duressKind, .duressSalt] {
            KeychainItem.delete(for: key, service: keychainService)
        }
    }

    /// Throws when a duress session is in force.
    ///
    /// The single choke point for "this is a real-credential act and a decoy session may not perform
    /// it". Applied to every duress/recovery mutator, so the refusal cannot be forgotten on one of
    /// them the way a per-call-site `if` would be. Fail-closed and stateless: the flag is
    /// in-memory-only, set by ``enterDecoySession(scope:)`` / ``enterLockedDecoySession()`` and
    /// cleared only by a REAL passcode success, ``configure(credential:grantingScope:)``,
    /// ``reestablishLocalUnlock(contentKey:credential:grantingScope:)`` or ``reset()``.
    private func refuseDuringDuressSession() throws {
        guard !isDuressSessionActive else {
            throw FernletLockError.invalidCredential(Self.duressSessionRefusalMessage)
        }
    }

    /// The ``FernletLockCredentialKind`` the configured duress PIN was entered as, or `nil` when the
    /// row is absent (no duress PIN, or one written before this row existed).
    private func storedDuressKind() -> FernletLockCredentialKind? {
        guard let data = keychainLoad(.duressKind, keychainService),
              let raw = String(data: data, encoding: .utf8) else { return nil }
        return FernletLockCredentialKind(rawValue: raw)
    }

    /// Whether a duress PIN entered under `duressKind` could still be TYPED at a lock rendering
    /// `newKind`'s entry surface.
    ///
    /// The PIN pads are hard-capped and auto-submit at their exact length (4 or 6), so a PIN of the
    /// other length can never be submitted; the alphanumeric surface is a free-text field with an
    /// explicit submit, so anything remains typeable there. That asymmetry is the whole rule.
    private nonisolated static func duressPINRemainsTypeable(
        duressKind: FernletLockCredentialKind,
        under newKind: FernletLockCredentialKind
    ) -> Bool {
        newKind == .alphanumeric || newKind == duressKind
    }

    /// The duress response `passcode` triggers, or `nil` when it is not the duress PIN.
    ///
    /// **Runs unconditionally, in a constant shape.** Every caller reaches this on every attempt,
    /// configured or not: the salt row is minted on demand, the scrypt derivation always happens at
    /// the fixed ``FernletLockCrypto/scryptN``, and the constant-time compare always runs — against
    /// a freshly generated never-matching value when there is no stored verifier. So an unlock costs
    /// exactly two derivations whether or not a duress PIN exists, and the timing side channel that
    /// would otherwise answer "does this device have a duress PIN?" does not exist.
    ///
    /// Fails CLOSED in the only direction that matters: a derivation failure, an unreadable row, or
    /// a corrupt mode byte yields "not duress" or the non-destructive ``DuressMode/decoy``, never a
    /// spurious wipe — and never leaks into the real unlock path, which re-derives independently.
    private func duressMode(for passcode: String) async -> DuressMode? {
        let salt = duressSaltEnsuringPresence()
        guard let derived = try? await cryptoProvider.deriveVerifier(
            passcode: passcode,
            salt: salt,
            n: FernletLockCrypto.scryptN
        ) else { return nil }
        let storedVerifier = keychainLoad(.duressVerifier, keychainService) ?? neverMatchingVerifier()
        guard constantTimeEqual(FernletLockCrypto.verifierDigest(of: derived), storedVerifier) else { return nil }
        // The verifier matched, so this IS the duress PIN; an unreadable or unrecognised mode byte
        // must not turn that into a normal unlock. Fall back to the non-destructive decoy.
        return storedDuressMode() ?? .decoy
    }

    /// The duress salt, minting and persisting a random dummy only when the row is AUTHORITATIVELY
    /// absent.
    ///
    /// The row is present whether or not a duress PIN is configured — that is what makes the
    /// derivation in ``duressMode(for:)`` unconditional. A dummy carries no secret and no PIN is
    /// bound to it, so persisting it is best-effort: a write that fails costs a re-mint on the next
    /// unlock, never correctness.
    ///
    /// **Mint only on `.absent` (R5).** With the collapsing read, one transient failure to read an
    /// EXISTING duress salt, followed by a successful delete-then-add here, replaces the salt the
    /// configured duress verifier was derived under — permanently disarming the duress PIN while
    /// `hasDuressConfigured` (which reads the untouched verifier row) still reports it armed. On an
    /// unreadable row nothing is written: the derivation still runs against a fixed dummy, so
    /// latency is unchanged, and with the verifier row equally unreadable the compare simply misses
    /// — fail-closed "not duress" for that one attempt.
    private func duressSaltEnsuringPresence() -> Data {
        switch keychainLoadDistinguishing(.duressSalt, keychainService) {
        case .found(let existing):
            return existing
        case .unreadable:
            return Data(repeating: 0, count: FernletLockCrypto.saltLength)
        case .absent:
            break
        }
        guard let minted = try? cryptoProvider.generateSalt() else {
            // Pathological RNG failure. Derive against a fixed dummy anyway — the invariant is that
            // a derivation ALWAYS happens, and with no verifier row this can only ever miss.
            return Data(repeating: 0, count: FernletLockCrypto.saltLength)
        }
        do {
            try storeVerified(minted, for: .duressSalt)
        } catch {
            // Named, not swallowed: the dummy just minted is unpersisted, the next unlock re-mints,
            // and no PIN is bound to it, so there is nothing to recover. Deliberately no audit line
            // — an event on this path fires only around duress entries (duress-silence invariant).
        }
        return minted
    }

    /// A random digest-sized value standing in for the stored duress verifier when none exists, so
    /// the constant-time compare still runs instead of being skipped. Never persisted, regenerated
    /// per call, and — being random — never matched by a real derivation.
    private func neverMatchingVerifier() -> Data {
        var bytes = [UInt8](repeating: 0, count: SHA256.byteCount)
        // A failed RNG leaves the buffer zeroed, which no SHA-256 digest of a real derivation will
        // equal either; the compare still runs and still misses, which is the fail-closed outcome.
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes)
    }

    /// The persisted ``DuressMode``, or `nil` when the row is absent or holds an unrecognised byte.
    private func storedDuressMode() -> DuressMode? {
        guard let data = keychainLoad(.duressMode, keychainService),
              let byte = data.first else { return nil }
        return DuressMode(rawValue: byte)
    }

    /// Performs the configured duress response and returns the benign-looking unlock result, or
    /// `nil` when the surface asked for is one a duress PIN may never open.
    ///
    /// Every mode converges on the same DECOY presentation. That is the design, not a shortcut: the
    /// silent wipe has nothing left to show once it has crypto-erased itself, and the recovery-lock
    /// deliberately does NOT announce that a recovery-lock happened (a "needs recovery on your other
    /// device" screen would tell the coercer both that they were defeated and where to look next).
    ///
    /// **`.appLockSettings` is never granted, and that is a security boundary, not a nicety.**
    /// Settings → App lock is where the duress code itself is managed. A decoy session holding that
    /// scope would let whoever is standing over the phone read "Duress code set" plus the armed
    /// response — the single fact the whole feature exists to hide — and then change or remove it,
    /// enrol a recovery custodian of their choosing, or reset the lock outright. The screen's own
    /// "real-PIN-gated by construction" premise is only TRUE if a duress PIN cannot satisfy that
    /// gate, so this is where that premise is made true. The response still runs (a coerced user who
    /// typed their duress code at any prompt must get the response they armed); the unlock is then
    /// refused, and the caller raises the ordinary wrong-passcode error.
    ///
    /// **Latency is equalised.** A benign unlock costs two derivations — the unconditional duress
    /// compare plus the real verifier. A duress match returns before the real derivation, so the
    /// decoy and recovery-lock paths would otherwise come back in roughly half the time, an
    /// eyeball-visible difference to anyone who has watched this phone unlock normally. Both spend a
    /// second, discarded derivation to close it. ``DuressMode/silentWipe`` does not: its re-mint
    /// already performs one.
    ///
    /// - Parameters:
    ///   - mode: The configured response.
    ///   - passcode: The secret the user just entered — i.e. the duress PIN itself, which
    ///     ``DuressMode/silentWipe`` needs in order to re-mint the throwaway lock under it. Passed
    ///     rather than re-read because it exists nowhere else: only the digest is persisted.
    ///   - scope: The surface the entry was made on; the decoy opens exactly that one, unless it is
    ///     `.appLockSettings`.
    /// - Returns: The benign-looking ``UnlockResult``, or `nil` when `scope` is `.appLockSettings`,
    ///   in which case the service is left LOCKED with the duress session in force.
    ///
    /// **No `@discardableResult`** (R7): `nil` here means "the unlock was REFUSED", and a caller
    /// that drops it would report success for an unlock the service withheld. The three
    /// settings-side entry points, which have no unlock to grant in the first place, call the void
    /// ``performDuressResponse(_:passcode:scope:)`` instead — so no refusal signal exists there to
    /// be discarded.
    private func handleDuress(_ mode: DuressMode, passcode: String, scope: FernletLockScope) async -> UnlockResult? {
        await performDuressResponse(mode, passcode: passcode, scope: scope)
        guard scope != .appLockSettings else { return nil }
        return UnlockResult(method: .passcode)
    }

    /// Runs the configured duress response and enters whichever session `scope` allows, WITHOUT
    /// producing an unlock result.
    ///
    /// The shape the three settings-side entry points (change passcode, enable biometrics, enrol a
    /// recovery custodian) need: a coerced user who typed their duress code at any prompt gets the
    /// response they armed, and the operation they were being coerced into performs nothing. They
    /// return to the caller as an ordinary success, which is the point — the screen must not
    /// announce that anything special happened.
    private func performDuressResponse(_ mode: DuressMode, passcode: String, scope: FernletLockScope) async {
        switch mode {
        case .decoy:
            await spendBalancingDerivation(for: passcode)
        case .silentWipe:
            await performSilentWipeKeyDestruction(duressPIN: passcode)
        case .recoveryLock:
            await spendBalancingDerivation(for: passcode)
            performRecoveryLockKeyDestruction()
        }
        if scope == .appLockSettings {
            enterLockedDecoySession()
        } else {
            enterDecoySession(scope: scope)
        }
        // After the decoy is on screen, never before: the purge is a background errand and the user
        // in front of the coercer must see an ordinary unlock, not a pause.
        if case .silentWipe = mode { duressPurgeHook?() }
    }

    /// Spends one throwaway scrypt derivation so a duress unlock costs the same two derivations a
    /// benign one does.
    ///
    /// Derived against the PRIMARY salt at ``storedScryptN()`` — i.e. byte-for-byte the work the
    /// real verifier path would have done — rather than a cheaper stand-in, so the equality holds on
    /// legacy installs whose stored N is lower than the current one. The result is discarded and
    /// never compared: this is a clock, not a check.
    private func spendBalancingDerivation(for passcode: String) async {
        guard let saltData = keychainLoad(.salt, keychainService) else { return }
        do {
            _ = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
        } catch {
            // The balancing derivation failed (a bad stored N, a KDF/RNG fault), so latency
            // equalisation is lost for this ONE attempt. Nothing to recover — and deliberately no
            // audit line: an event emitted only on duress entries is exactly the tell this feature
            // must not leave. The `_ =` is legitimate here; the derived key is a clock, not a check.
        }
    }

    /// ``DuressMode/recoveryLock``: destroy every LOCAL way into the content key while keeping
    /// everything the in-person custodian ceremony needs, then present the decoy.
    ///
    /// The difference from ``performSilentWipeKeyDestruction(duressPIN:)`` is the whole mode, and it is four
    /// deliberate omissions:
    ///
    /// - **The recovery material survives.** `.recoveryBlob` plus the custodian's two public keys
    ///   stay, which is what makes this recoverable at all. So does the sealed ciphertext corpus
    ///   (nothing here touches the store) and the ProximityKit identity keys under
    ///   `com.fernlet.identity` — a different keychain service this module never sweeps, and the
    ///   keys the return ceremony authenticates with.
    /// - **The journal / Worry Box device fallback keys survive.** The wipe destroys them because
    ///   "crypto-erased" would otherwise be false for the two entities that are sealed under those
    ///   keys whenever the lock is closed. Here the promise is the opposite one — *recoverable* —
    ///   and nothing in the recovery blob can give those keys back, so destroying them would be
    ///   unrecoverable loss on the one mode built to avoid it. The rows they seal were never
    ///   protected by the app lock in the first place (they are written while it is closed, by
    ///   design), so this leaves the residual an ordinary locked device already carries rather than
    ///   creating a new one — and it takes forensic extraction to reach, not tapping around a decoy.
    /// - **No re-mint.** The point of the mode is that NO local unlock survives: the coerced user
    ///   can then say truthfully that they cannot open the data, and mean it.
    /// - **No purge hook.** The corpus is being kept, not deleted; firing the delete funnel here
    ///   would destroy exactly what the custodian is holding the key for.
    ///
    /// Fails CLOSED on missing recovery material, and on material that is present but **cannot be
    /// turned back into this device's live content key**. `configureDuress(pin:mode:)` refuses this
    /// mode without an enrolled custodian, but the rows could still be gone by the time the PIN is
    /// entered (a keychain that lost them, a partially-swept install), and the blob could have been
    /// superseded by a lock minted after a recovery-lock fired
    /// (``LockKeychainKey/recoveryBlobSuperseded``). Destroying the local keys in either state would
    /// be an unannounced permanent wipe the user never chose — the one outcome this mode exists to
    /// avoid — so nothing is destroyed and the non-destructive decoy is presented instead,
    /// indistinguishably.
    ///
    /// The third way the blob can stop being openable — this device's own proximity identity
    /// rotating, which "Delete everything" does — is caught earlier and at its source, by
    /// ``invalidateRecoveryCustodianForRotatedIdentity()``, which retires the material so
    /// ``hasRecoveryCustodian`` goes false and this guard fires.
    private func performRecoveryLockKeyDestruction() {
        guard hasRecoveryCustodian, !hasSupersededRecoveryBlob else { return }
        destroyLocalUnlockKeys(
            alsoDestroyingRecoveryMaterial: false,
            alsoDestroyingDeviceFallbackKeys: false
        )
    }

    /// ``DuressMode/silentWipe``: crypto-erase this device, put a convincing empty lock in the
    /// wiped one's place, present the decoy, and hand the durable cleanup to the delete funnel.
    ///
    /// The order of the four steps is the whole design:
    ///
    /// 1. **Destroy, synchronously.** `destroyLocalUnlockKeys` deletes every key that can open a
    ///    sealed byte — including the Secure-Enclave key, which nothing else but ``reset()`` ever
    ///    touches. This is pure keychain deletion, so it completes in milliseconds and it is what
    ///    the sub-second claim rests on: from here the sealed corpus (on disk, in an iCloud backup,
    ///    in a dead-drop) is ciphertext nobody can open, whether or not anything below succeeds.
    /// 2. **Re-mint.** A fresh salt/verifier/content key under the SAME PIN the user just entered,
    ///    through the SAME `mintLockRecords` a real setup uses. Without this the wiped device shows
    ///    "set up app lock" the moment it re-locks — a tell that says both "there was a duress PIN"
    ///    and "it fired". With it, the coercer's PIN keeps opening an app that is simply empty.
    ///    Failure here is survivable and deliberately swallowed: a device with no lock is worse copy
    ///    than a device with one, but neither un-erases anything.
    /// 3. **Present the decoy.** Same keyless session, same audit line, same cleared attempt state
    ///    as every other duress mode — the wipe must not be distinguishable from the decoy either.
    /// 4. **Fire the purge hook**, last and fire-and-forget, for the sealed rows and cloud copies.
    ///
    /// **This inverts the lock-survives-wipe rule, on this seam only.** `deleteAllData` deliberately
    /// keeps `com.fernlet.lock` (documented in `Docs/PrivacyWipeCoverage.md`); the duress wipe
    /// destroys it. The inversion is safe precisely because the direction of the call is
    /// one-way — the funnel never calls back into the lock, so no non-duress path can reach this.
    ///
    /// - Note: The re-minted lock makes the duress PIN the REAL passcode of the now-empty app, and
    ///   no duress PIN survives until the user sets a new one. That is the accepted trade (§11): the
    ///   alternative leaves a "set up app lock" CTA where a lock used to be.
    ///
    /// Steps 3 and 4 (present the decoy, fire the purge hook) belong to ``handleDuress(_:passcode:scope:)``,
    /// which owns the presentation decision for every mode — including the refusal to present one at
    /// all on `.appLockSettings`.
    private func performSilentWipeKeyDestruction(duressPIN: String) async {
        destroyLocalUnlockKeys(
            alsoDestroyingRecoveryMaterial: true,
            alsoDestroyingDeviceFallbackKeys: true
        )
        await mintThrowawayLock(under: duressPIN)
    }

    /// Deletes every keychain item that can lead to the content key, plus the Secure-Enclave key
    /// itself, and drops the in-memory copy.
    ///
    /// The list is exhaustive by intent, not by convenience — each row is a way in:
    /// `.salt`/`.verifier` (the passcode gate), `.wrappedContentKey` (the scrypt-wrapped key),
    /// `.seWrappedContentKey` + the SE key (the hard-bound copy), `.biometricBypass` (the RAW key
    /// behind Face ID — the copy most easily forgotten and the one a coercer can use without any
    /// PIN at all), `.biometricEnabledFlag`, the duress rows themselves, and the journal / Worry Box
    /// **device fallback keys** under ``sealedContentKeyServices``.
    ///
    /// - Parameters:
    ///   - alsoDestroyingRecoveryMaterial: Whether to destroy `.recoveryBlob` and the enrolled
    ///     custodian's public keys too. `true` for the WIPE, where the recovery blob is a sealing of
    ///     the very content key being erased and leaving it would make "crypto-erased" false — the
    ///     custodian device could still open it. `false` for ``DuressMode/recoveryLock``, whose
    ///     entire purpose is that this material survives.
    ///   - alsoDestroyingDeviceFallbackKeys: Whether to sweep ``sealedContentKeyServices`` AND
    ///     ``mediaKeychainServices``. `true` for the WIPE, where the journal/Worry Box fallback keys
    ///     open two of the four sealed entities and the media keys open the progress-photo (body
    ///     photo) corpus — leaving either alive would make the sub-second crypto-erase claim false
    ///     until the asynchronous delete funnel caught up, and false forever if the process were
    ///     killed first. `false` for ``DuressMode/recoveryLock``: nothing in the recovery blob can
    ///     give those keys back, so destroying them there would be unrecoverable loss on the one
    ///     mode that promises recovery (see ``performRecoveryLockKeyDestruction()``).
    private func destroyLocalUnlockKeys(
        alsoDestroyingRecoveryMaterial: Bool,
        alsoDestroyingDeviceFallbackKeys: Bool
    ) {
        var keys: [LockKeychainKey] = [
            .salt,
            .verifier,
            .duressSalt,
            .duressVerifier,
            .duressMode,
            .duressKind,
            .wrappedContentKey,
            // The re-wrap staging row is a scrypt-openable copy of the content key whenever it
            // exists (Phase 2.5); a key destruction that left it behind would not be one.
            .wrappedContentKeyRewrapStaging,
            .seWrappedContentKey,
            .biometricBypass,
            .biometricEnabledFlag
        ]
        if alsoDestroyingRecoveryMaterial {
            keys += [
                .recoveryBlob,
                .custodianSigningPublicKey,
                .custodianKeyAgreementPublicKey,
                .recoveryOwnerKeyAgreementPublicKey,
                .recoveryBlobSuperseded
            ]
        }
        for key in keys {
            KeychainItem.delete(for: key, service: keychainService)
        }
        // A `kSecClassKey` item, outside the generic-password rows above — the same explicit sweep
        // `reset()` needs, and the difference between "the wrap blob is gone" and "the key that
        // opens it is gone". The status is retried ONCE on failure and never audit-logged: this
        // path runs under duress, where a log line is itself the tell (R7 — the recovery is the
        // retry, not a report).
        let enclaveDeleteStatus = SecureEnclaveContentKeyWrap.deleteKey(service: keychainService)
        if enclaveDeleteStatus != errSecSuccess, enclaveDeleteStatus != errSecItemNotFound {
            _ = SecureEnclaveContentKeyWrap.deleteKey(service: keychainService)
        }
        // The third sweep, for the same reason `reset()` documents: journal and Worry Box rows are
        // sealed under DEVICE FALLBACK keys — not the content key — whenever they are written while
        // the lock is closed. Destroying the content key alone would leave exactly those rows
        // openable, so "crypto-erased" would be false for two of the four sealed entities. The
        // delete funnel this wipe hands off to deletes the same two keys, but asynchronously; the
        // sub-second claim needs them gone HERE. They regenerate lazily on next use.
        //
        // Deliberately skipped by the recovery-lock: those keys are not in the recovery blob, so
        // destroying them there would be loss no ceremony can undo.
        if alsoDestroyingDeviceFallbackKeys {
            for service in sealedContentKeyServices {
                KeychainItem.deleteAll(service: service)
            }
            // …and the FOURTH sweep, for the same reason. Progress photos are body photos sealed
            // under `PrivateMediaStore`'s OWN key — a key the app lock never holds and the delete
            // funnel deliberately KEEPS. "Every key that can open a sealed byte here" was false
            // while it survived: the sealed photo files plus a live key is an openable corpus, and
            // the funnel that deletes the files runs asynchronously (and not at all if the process
            // dies first). Deleting the key is what makes the sub-second claim true for them too.
            // Deliberately NOT swept by `reset()` — resetting the app lock is not a delete, and the
            // photo corpus is not the lock's to erase.
            for service in mediaKeychainServices {
                KeychainItem.deleteAll(service: service)
            }
        }
        scrubContentKey()
    }

    /// Puts an empty, fully-formed lock in the wiped one's place, keyed to the duress PIN.
    ///
    /// Goes through ``mintLockRecords(for:)`` — the same body a real setup uses — so the throwaway
    /// carries the identical record set, and then establishes the same Secure-Enclave hard binding,
    /// so a wiped device's custody state matches a freshly configured one instead of standing out as
    /// the only install in the world with no enclave wrap.
    ///
    /// **The enclave work is open-coded rather than delegated to `maintainSecureEnclaveWrap` /
    /// `hardBindToSecureEnclaveIfVerified`, and that is the point of this function existing.** Those
    /// two emit `lock.seWrapEstablished` and `lock.hardBoundToSecureEnclave` — audit event NAMES
    /// reach the unified log with `.auto` privacy and survive a sysdiagnose. A hard-bound install's
    /// benign unlock emits neither, so emitting them in the same instant as a `lock.released` would
    /// be a legible signature reading "a lock was minted from scratch during that unlock" — i.e. the
    /// duress wipe fired. The wipe must leave the audit trail of an ordinary unlock and nothing
    /// else, so this path performs the same two steps silently. The one invariant that matters is
    /// preserved verbatim: the scrypt item is deleted ONLY against a blob the enclave demonstrably
    /// opens back to the exact key bytes (`wrapVerified` proves the round trip, and the equality
    /// re-check below is the same keep-old-until-verified guard).
    ///
    /// Best-effort by design: every failure is swallowed. The erase already happened, and a re-mint
    /// that threw would only add a "set up app lock" screen to a device that is already safe.
    ///
    /// - Parameter pin: The duress PIN, now the real (and only) passcode of the empty app.
    private func mintThrowawayLock(under pin: String) async {
        let credential = FernletLockCredential(kind: credentialKind ?? inferredCredentialKind(for: pin), rawValue: pin)
        guard let contentKeyData = try? await mintLockRecords(for: credential) else { return }
        // The throwaway key is deliberately NOT retained: the decoy that follows is keyless (see
        // `enterDecoySession`), and a resident key would be a second thing to get wrong.
        guard SecureEnclaveContentKeyWrap.isAvailable,
              let blob = SecureEnclaveContentKeyWrap.wrapVerified(contentKeyData, service: keychainService),
              (try? storeVerified(blob, for: .seWrappedContentKey)) != nil,
              let roundTripped = SecureEnclaveContentKeyWrap.unwrap(blob, service: keychainService),
              constantTimeEqual(roundTripped, contentKeyData) else { return }
        KeychainItem.delete(for: .wrappedContentKey, service: keychainService)
    }

    /// The credential kind a raw secret would be entered as, used ONLY as the fallback when the
    /// `.kind` row cannot be read during a wipe re-mint.
    ///
    /// The stored kind is authoritative wherever it exists — it decides which pad the lock renders,
    /// so guessing a different one would change the unlock screen, which is itself a tell. This
    /// exists so a missing row degrades to a plausible lock rather than to no lock.
    private func inferredCredentialKind(for secret: String) -> FernletLockCredentialKind {
        guard secret.allSatisfy(\.isNumber) else { return .alphanumeric }
        switch secret.count {
        case 4: return .pin4
        case 6: return .pin6
        default: return .alphanumeric
        }
    }

    /// Opens the KEYLESS decoy session for `scope`; the caller returns the same ``UnlockResult`` a
    /// benign passcode unlock returns.
    ///
    /// Four properties make this indistinguishable from a real unlock, and all four are load-bearing:
    /// - **No content key.** `retainContentKey` is deliberately not called, so `_contentKey` stays
    ///   nil and ``contentKey(for:)`` returns nil even for `.privateHub`. Sealed journal/worry
    ///   activation therefore lands in its deactivated branch and the sealed surfaces render empty —
    ///   the decoy is an absence of a key, never a decoy key (no dummy key may ever exist).
    /// - **No attempt residue.** ``clearAttemptState()`` runs exactly as it does on a successful
    ///   unlock, so no lingering counter, cooldown record or `requiresReset` flag can tell the two
    ///   apart afterwards.
    /// - **The same audit line.** `lock.released` with `method=passcode` and the scope — byte for
    ///   byte what a benign passcode unlock emits.
    /// - **Neither passcode flag.** ``passcodeUnlockedThisProcess`` and
    ///   ``passcodeVerifiedThisProcess`` stay untouched, because a duress entry must not satisfy the
    ///   PIN-before-biometrics requirement that guards the real content key's bypass copy.
    ///
    /// Nothing here persists and nothing here deletes: the decoy is entirely in-memory flags plus
    /// the existing scrub path, so it is fully reversible by entering the real passcode. (A bug that
    /// persisted the forced-hidden visibility would turn a reversible decoy into silent data hiding
    /// — gate on this flag, never on a settings setter.)
    private func enterDecoySession(scope: FernletLockScope) {
        clearAttemptState()
        scrubContentKey()
        isDuressSessionActive = true
        state = .unlocked(scope: scope)
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.released", context: ["method": "passcode", "scope": scope.rawValue])
    }

    /// Opens the duress session WITHOUT granting a scope, for the one surface a duress PIN may never
    /// open: Settings → App lock (see ``handleDuress(_:passcode:scope:)``).
    ///
    /// The protective half of the decoy still applies in full — the flag is set, so the sensitive
    /// surfaces stay shut, biometrics stay suppressed, and the duress-management API refuses — but
    /// no surface is revealed and any unlock the caller was standing on is revoked, because the
    /// three non-`unlock` entry points (change passcode, enable biometrics, enrol a custodian) are
    /// reached from INSIDE an already-unlocked App-lock settings page. Leaving that page revealed
    /// would hand the coercer the exact screen this refusal exists to withhold.
    ///
    /// **Presents as an ordinary mistype**, deliberately: `clearAttemptState()` runs first (so no
    /// counter, cooldown or `requiresReset` residue can tell a duress entry from a benign one), and
    /// the audit line is the same `lock.failedAttempt` a wrong passcode emits, carrying the
    /// cooldown level as it stood BEFORE the clear — which is what a benign miss would have printed.
    /// The caller then throws `invalidPasscode`.
    private func enterLockedDecoySession() {
        let priorCooldownLevel = loadCooldownLevel()
        clearAttemptState()
        scrubContentKey()
        isDuressSessionActive = true
        state = .locked(cooldownDeadline: nil)
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.failedAttempt", context: ["cooldownLevel": "\(priorCooldownLevel)"])
    }

    // MARK: - Recovery custodian (P7)

    /// Enrolls the user's own second device as the recovery custodian for
    /// ``DuressMode/recoveryLock``: seals the content key to that device and persists the sealing
    /// plus the two public keys the return ceremony authenticates against.
    ///
    /// **The content key is released into a closure, never returned.** `FernletLock` cannot seal —
    /// the X25519/HKDF/ChaChaPoly sealing and the QR ceremony that produced `keyAgreementPublicKey`
    /// live in ProximityKit, and this module deliberately has no edge to it (§11 "Seam placement /
    /// wall"). So the app-side `DuressRecoveryCoordinator` passes its `IdentityService.seal(_:to:
    /// format:)` in as `seal`, this method hands it the key bytes for the duration of that one call,
    /// and the sealing it returns is persisted here. The alternative shape — hand the app the
    /// content key and let it call back with a finished blob — would have needed a second reveal
    /// seam beside ``contentKey(for:)`` (which yields nil for `.appLockSettings`, the scope
    /// enrollment actually runs under) and a window in which the app holds a blob it must remember
    /// to store. This deviates from the plan's `enrollRecoveryCustodian(sealedBlob:signingPub:kaPub:)`
    /// signature for exactly that reason.
    ///
    /// **Real-passcode gated, and duress-aware.** The passcode is compared against the duress
    /// verifier FIRST — this is the THIRD credential entry point, and the most dangerous one to
    /// forget: enrolling under a coerced PIN would seal the REAL content key to a device the coercer
    /// chose, i.e. hand them an exfiltration route with the user's own hands. A match enrolls
    /// nothing and presents the decoy. (The UI reaches this from Settings → App lock, which the user
    /// already unlocked with the real passcode; the explicit re-entry here is what actually recovers
    /// the key, since `.appLockSettings` deliberately keeps none resident.)
    ///
    /// **Emits no audit event**, for the same reason ``configureDuress(pin:mode:)`` does not: an
    /// event name reaches the unified log with `.auto` privacy and survives a sysdiagnose, and
    /// "this device enrolled a recovery custodian" is a near-synonym for "this device has a duress
    /// PIN" — the single fact the feature depends on hiding.
    ///
    /// The row order is disarm → keys → **blob LAST**, because ``hasRecoveryCustodian`` reads all
    /// three: every intermediate state therefore reads as "no custodian", never as an enrolled
    /// custodian whose blob is missing — which is the state that would let ``DuressMode/recoveryLock``
    /// be armed over an unrecoverable device.
    ///
    /// - Parameters:
    ///   - passcode: The REAL passcode. Verified through the same `verifierMatch` the unlock path
    ///     uses (so a legacy raw-key verifier is accepted and migrated).
    ///   - signingPublicKey: The custodian's Ed25519 public key, ceremony-proven by the caller.
    ///   - keyAgreementPublicKey: The custodian's X25519 public key — what the blob is sealed to.
    ///   - ownKeyAgreementPublicKey: THIS device's own X25519 public key, i.e. the sender key the
    ///     sealing binds to. Recorded so a later rotation of this device's proximity identity (which
    ///     "Delete everything" performs) can be DETECTED and the dead enrollment retired — see
    ///     ``invalidateRecoveryCustodianForRotatedIdentity()``.
    ///   - seal: Seals the content-key bytes to `keyAgreementPublicKey`. Called exactly once, with
    ///     the key alive only for the duration of the call.
    /// - Throws: `FernletLockError.notConfigured`, `.invalidPasscode`, `.invalidCredential` for a
    ///   malformed public key or while a duress session is in force, `.keychainFailure` for an
    ///   unwritable row, the custody errors from a hard-bound recovery, or whatever `seal` throws.
    public func enrollRecoveryCustodian(
        passcode: String,
        signingPublicKey: Data,
        keyAgreementPublicKey: Data,
        ownKeyAgreementPublicKey: Data,
        sealingContentKeyTo seal: (Data) throws -> Data
    ) async throws {
        try refuseDuringDuressSession()
        guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
              let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService) else {
            throw FernletLockError.notConfigured
        }
        // DURESS FIRST (P7) — before the custody read and before the real verifier is derived, so a
        // coerced enrollment touches nothing. See the doc comment: this is the one entry point where
        // honoring a duress PIN would EXPORT the content key rather than merely reveal it locally.
        if let mode = await duressMode(for: passcode) {
            await performDuressResponse(mode, passcode: passcode, scope: state.unlockedScope ?? .appLockSettings)
            return
        }
        guard signingPublicKey.count == Self.recoveryCustodianPublicKeyByteCount,
              keyAgreementPublicKey.count == Self.recoveryCustodianPublicKeyByteCount,
              ownKeyAgreementPublicKey.count == Self.recoveryCustodianPublicKeyByteCount else {
            throw FernletLockError.invalidCredential(Self.recoveryCustodianInvalidKeyMessage)
        }
        let custody = contentKeyCustody()
        let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
        let match = verifierMatch(computedVerifier: computedVerifier, storedVerifier: storedVerifier)
        if case .none = match { throw FernletLockError.invalidPasscode }

        let contentKeyData: Data
        switch custody {
        case .legacyScryptWrapped(let wrappedData):
            contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
        case .hardBoundToSecureEnclave:
            contentKeyData = try secureEnclaveBoundContentKey()
        case .undeterminable(let status):
            throw FernletLockError.keychainFailure(operation: "read wrappedContentKey", status: status)
        }
        migrateLegacyVerifierIfNeeded(match, computedVerifier: computedVerifier)

        let sealed = try seal(contentKeyData)
        guard !sealed.isEmpty else {
            throw FernletLockError.internalError("recovery blob sealing produced no bytes")
        }
        KeychainItem.delete(for: .recoveryBlob, service: keychainService)
        // A fresh sealing of the LIVE content key by the LIVE identity: whatever was superseded or
        // stale before, this enrollment is current.
        KeychainItem.delete(for: .recoveryBlobSuperseded, service: keychainService)
        try storeVerified(signingPublicKey, for: .custodianSigningPublicKey)
        try storeVerified(keyAgreementPublicKey, for: .custodianKeyAgreementPublicKey)
        try storeVerified(ownKeyAgreementPublicKey, for: .recoveryOwnerKeyAgreementPublicKey)
        try storeVerified(Self.recoveryContentKeyDigest(of: contentKeyData) + sealed, for: .recoveryBlob)
    }

    /// Un-enrolls the recovery custodian, deleting the blob and both public keys.
    ///
    /// Refuses while ``DuressMode/recoveryLock`` is the armed duress response, because that pairing
    /// is a trap rather than a configuration: the response destroys every local unlock key and the
    /// custodian is the only thing that gives them back. (``performRecoveryLockKeyDestruction()`` also fails
    /// closed if the rows vanish some other way, but a refusal the user can read is better than a
    /// silent downgrade of the response they chose.) Change or remove the duress response first.
    ///
    /// Silent and idempotent, for the same reasons ``removeDuress()`` is.
    ///
    /// Refuses during a duress session too, like every other duress/recovery mutator.
    ///
    /// - Throws: `FernletLockError.invalidCredential(recoveryCustodianInUseMessage)`, or
    ///   `.invalidCredential(duressSessionRefusalMessage)` while a duress session is in force.
    public func removeRecoveryCustodian() throws {
        try refuseDuringDuressSession()
        if hasDuressConfigured, storedDuressMode() == .recoveryLock {
            throw FernletLockError.invalidCredential(Self.recoveryCustodianInUseMessage)
        }
        for key in [
            LockKeychainKey.recoveryBlob,
            .custodianSigningPublicKey,
            .custodianKeyAgreementPublicKey,
            .recoveryOwnerKeyAgreementPublicKey,
            .recoveryBlobSuperseded
        ] {
            KeychainItem.delete(for: key, service: keychainService)
        }
    }

    /// Rebuilds a local unlock around a content key a custodian handed back, under a NEW credential.
    ///
    /// The tail of the in-person recovery ceremony. The app-side coordinator has proved the peer is
    /// the enrolled custodian, sent it ``custodianRecoveryBlob``, and opened its sealed reply; this
    /// turns those key bytes back into a working lock — fresh salt and verifier, the recovered key
    /// wrapped under the new credential, a fresh Secure-Enclave binding, and no biometric bypass
    /// until the user re-enables one.
    ///
    /// **A wrong key is REFUSED, not installed.** The recovered bytes are checked against this
    /// device's own digest of the key the blob seals (``storedRecoveryContentKeyDigest()``). Without
    /// that check a custodian that returned the wrong bytes — a bug, a stale blob, a second corpus —
    /// would silently re-lock the device around a key that opens nothing, and the corpus would be
    /// gone with no error ever raised. This is the one place that can still tell.
    ///
    /// **Audit-identical to a fresh setup.** It emits `lock.configured` with the same fields, and
    /// the enclave helpers emit exactly what a first-time setup emits — so a sysdiagnose pulled later
    /// cannot be read as "a recovery happened here", which would disclose that a duress PIN existed.
    ///
    /// The recovery material is deliberately KEPT: this installs the very key the blob seals, so the
    /// enrolled custodian remains correct and the user stays protected without re-running the QR
    /// ceremony. The duress rows do not come back — the response was spent, and a new one must be
    /// chosen deliberately.
    ///
    /// - Parameters:
    ///   - contentKey: The recovered content-key bytes.
    ///   - credential: The NEW credential to gate the rebuilt lock on.
    ///   - grantingScope: The surface the recovery ran on, unlocked on success exactly as
    ///     ``configure(credential:grantingScope:)`` unlocks the surface a lock was created from.
    /// - Throws: `FernletLockError.invalidCredential` when the credential fails validation, when no
    ///   recovery material is present, or when the key does not match this device's check value;
    ///   `.keychainFailure` when a record cannot be written.
    public func reestablishLocalUnlock(
        contentKey: Data,
        credential: FernletLockCredential,
        grantingScope: FernletLockScope
    ) async throws {
        try credential.validate()
        guard let expectedDigest = storedRecoveryContentKeyDigest() else {
            throw FernletLockError.invalidCredential(Self.recoveryNotAvailableMessage)
        }
        guard contentKey.count == FernletLockCrypto.keyLength,
              constantTimeEqual(Self.recoveryContentKeyDigest(of: contentKey), expectedDigest) else {
            throw FernletLockError.invalidCredential(Self.recoveryKeyMismatchMessage)
        }
        let installed = try await mintLockRecords(
            for: credential,
            contentKey: contentKey,
            preservingRecoveryMaterial: true
        )
        retainContentKey(installed, for: grantingScope)
        state = .unlocked(scope: grantingScope)
        hasAutoPromptedBiometricForCurrentLockSession = false
        // The user just chose this credential in front of a ceremony they physically ran, which is
        // exactly what initial setup proves — so the same PIN-before-biometrics flags are satisfied,
        // and the decoy session the recovery-lock opened ends here.
        passcodeUnlockedThisProcess = true
        passcodeVerifiedThisProcess = true
        isDuressSessionActive = false
        maintainSecureEnclaveWrap(contentKeyData: installed)
        hardBindToSecureEnclaveIfVerified(contentKeyData: installed, migratingExistingInstall: false)
        FernletAuditLog.log("lock.configured", context: [
            "kind": credential.kind.rawValue,
            "scope": grantingScope.rawValue
        ])
    }

    /// The sealed-content key, released ONLY to the scope that owns it and only while that scope
    /// holds the unlock. This is the decrypt seam, not a UI check: an unlock taken out on the
    /// progress-photo strip or the App-lock settings page yields `nil` here, so journal / period /
    /// intimacy / Worry Box plaintext is never even derived on those screens. Progress photos are
    /// sealed under `PrivateMediaKeyStore`'s own key and App-lock settings re-derive from the
    /// entered passcode, so neither has any business with this one.
    public func contentKey(for scope: FernletLockScope) -> SymmetricKey? {
        guard scope == .privateHub, state.isUnlocked(for: scope) else { return nil }
        return _contentKey
    }

    /// Whether the content key is resident in memory AT ALL, bypassing the scope guard in
    /// `contentKey(for:)`. Exists purely so tests can tell "scrubbed" from "merely withheld" —
    /// asserting through `contentKey(for:)` cannot, because its guard returns nil for a foreign
    /// scope no matter what `_contentKey` holds. Never a reveal seam: it exposes a Bool, not a key.
    public var hasResidentContentKey: Bool { _contentKey != nil }

    /// `PeriodLockContext`: appends a sealed pending narrative while the lock is engaged.
    public func bufferPendingNarrative(_ payload: PendingNarrativePayload) throws {
        try buffer.append(payload)
    }

    /// `PeriodLockContext`: drains and returns all buffered narratives (called after unlock).
    public func drainPendingNarratives() throws -> [PendingNarrativePayload] {
        try buffer.drainAll()
    }

    /// `PeriodLockContext`: discards all buffered narratives without processing them.
    public func purgePendingNarratives() throws {
        try buffer.purge()
    }

    /// Drops the in-memory content key reference.
    private func scrubContentKey() {
        _contentKey = nil
    }

    /// Least privilege for the in-memory key: only a `.privateHub` session keeps it resident at all.
    /// A progress-photo or App-lock-settings unlock recovers the content key as a side effect of
    /// verifying the passcode (unwrapping it IS the verification) and then drops it — those screens
    /// have no sealed content to read, so the key should not outlive the check. `contentKey(for:)`
    /// still gates every read; this makes that gate belt-and-braces rather than the only barrier.
    ///
    /// Independent of the at-rest Secure-Enclave wrap below: `maintainSecureEnclaveWrap` is called
    /// on every configure and on every LEGACY unlock regardless of scope, because the wrap
    /// protects the key at rest, not the session (a hard-bound unlock only unwraps — see
    /// `secureEnclaveBoundContentKey()`).
    private func retainContentKey(_ contentKeyData: Data?, for scope: FernletLockScope) {
        guard scope == .privateHub, let contentKeyData else {
            // nil arrives only from the tolerated hard-bound recovery failure on a non-hub scope,
            // where the key is not the caller's to hold anyway. Scrub — never fabricate
            // placeholder bytes; no dummy key may ever exist.
            scrubContentKey()
            return
        }
        _contentKey = SymmetricKey(data: contentKeyData)
    }

    // MARK: - Content-key custody: LEGACY (scrypt authoritative) ⇄ HARD-BOUND (Secure Enclave)

    /// Which custody state the lock's content key is in, discriminated by the presence of the
    /// scrypt-wrapped keychain item — the single source of truth for that question.
    ///
    /// `.legacyScryptWrapped` carries the blob so callers never re-read (and never race) the
    /// item between deciding and unwrapping. `.hardBoundToSecureEnclave` carries nothing: the
    /// enclave wrap is read at the moment of use, because a hard-bound recovery has exactly one
    /// place it can fail and that failure must be explicit. `.undeterminable` exists because the
    /// third outcome is real: a keychain read can FAIL, and a failure is not an absence.
    private enum ContentKeyCustody {
        /// The scrypt-wrapped item exists and is authoritative (pre-migration, or SE-less
        /// hardware where it stays authoritative forever).
        case legacyScryptWrapped(Data)
        /// The scrypt item is gone; `seWrappedContentKey` is the only recoverable copy.
        case hardBoundToSecureEnclave
        /// The custody question could not be answered: the keychain read failed, or the scrypt
        /// item is absent on hardware with NO enclave (which is a fault, not a custody state —
        /// nothing could ever have hard-bound there). Callers must refuse to act, never guess.
        case undeterminable(OSStatus)
    }

    /// Reads the current custody state straight from the keychain (never cached — the state
    /// flips mid-session, on the very unlock that migrates it).
    ///
    /// Fails CLOSED and identifies hard-binding POSITIVELY. `KeychainItem.load` returns nil both
    /// for a genuinely absent item and for a failed `SecItemCopyMatching`, so inferring custody
    /// from it would read a transient read failure as "the scrypt item was deleted after proof" —
    /// which would take the enclave branch on a legacy install (installing a stale key with no
    /// equality gate) and make `changeCredential` skip rewriting the scrypt wrap while rewriting
    /// the verifier over it. `loadDistinguishingAbsence` keeps the three outcomes apart, and an
    /// absence on enclave-less hardware is reported as undeterminable rather than as a hard-bound
    /// state that could never have been reached there.
    private func contentKeyCustody() -> ContentKeyCustody {
        switch keychainLoadDistinguishing(.wrappedContentKey, keychainService) {
        case .found(let wrapped):
            return .legacyScryptWrapped(wrapped)
        case .unreadable(let status):
            FernletAuditLog.log("lock.custodyUnreadable", context: ["status": "\(status)"])
            return .undeterminable(status)
        case .absent:
            guard SecureEnclaveContentKeyWrap.isAvailable else {
                FernletAuditLog.log("lock.custodyUnreadable", context: ["status": "noEnclave"])
                return .undeterminable(errSecItemNotFound)
            }
            return .hardBoundToSecureEnclave
        }
    }

    /// Recovers the content key in the HARD-BOUND state: the stored enclave wrap, opened by the
    /// non-exportable Secure-Enclave key, with no scrypt copy to fall back on or compare against.
    ///
    /// Two failures live here and they must never be confused. **Terminal** means the enclave key
    /// is provably gone (the key row reports `errSecItemNotFound`, or it is readable and still
    /// refuses the blob, or the blob itself is absent) — the corpus is unopenable and the app says
    /// so. **Transient** means the keychain would not answer right now
    /// (`errSecInteractionNotAllowed` while the device is locked, `errSecNotAvailable` before
    /// first unlock, protected data unavailable): the key may be perfectly intact, and the honest
    /// answer is "try again", not the destructive-reset copy. The unlock flow straddles a
    /// several-hundred-millisecond scrypt derive during which the device can auto-lock, so the
    /// transient case is a real, reachable state — collapsing it into the terminal one would tell
    /// a user with an intact key to destroy it.
    ///
    /// - Throws: `FernletLockError.contentKeyUnrecoverable` for the terminal states;
    ///   `FernletLockError.contentKeyTemporarilyUnavailable(status:)` for the transient ones.
    private func secureEnclaveBoundContentKey() throws -> Data {
        guard SecureEnclaveContentKeyWrap.isAvailable else {
            // Hard-bound state on hardware that reports no enclave: the wrap cannot be opened, but
            // nothing proves the key is destroyed either (a simulator/OS transition can report
            // this). Retryable, never a reset prompt.
            throw unrecoverableOrTransient(.unavailable(errSecNotAvailable), blobPresent: false)
        }
        let blob: Data
        switch keychainLoadDistinguishing(.seWrappedContentKey, keychainService) {
        case .found(let data):
            blob = data
        case .absent:
            // No wrap and no way to make one: the authoritative copy is gone.
            throw unrecoverableOrTransient(.keyAbsent, blobPresent: false)
        case .unreadable(let status):
            throw unrecoverableOrTransient(.unavailable(status), blobPresent: false)
        }
        switch SecureEnclaveContentKeyWrap.unwrapResult(blob, service: keychainService) {
        case .recovered(let contentKeyData):
            return contentKeyData
        case .keyAbsent:
            throw unrecoverableOrTransient(.keyAbsent, blobPresent: true)
        case .blobRejected:
            throw unrecoverableOrTransient(.blobRejected, blobPresent: true)
        case .unavailable(let status):
            throw unrecoverableOrTransient(.unavailable(status), blobPresent: true)
        }
    }

    /// Classifies a hard-bound recovery failure into the terminal or the retryable error, and
    /// audit-logs the outcome WITH its status so a field report can tell the two apart.
    private func unrecoverableOrTransient(
        _ outcome: SecureEnclaveContentKeyWrap.UnwrapOutcome,
        blobPresent: Bool
    ) -> FernletLockError {
        let error: FernletLockError
        let classification: String
        switch outcome {
        case .recovered:
            // Not a failure; kept exhaustive rather than defaulted so a new outcome must be
            // classified here deliberately.
            return .internalError("recovered outcome routed through the failure classifier")
        case .keyAbsent:
            error = .contentKeyUnrecoverable
            classification = "terminal.keyAbsent"
        case .blobRejected:
            error = .contentKeyUnrecoverable
            classification = "terminal.blobRejected"
        case .unavailable(let status):
            error = .contentKeyTemporarilyUnavailable(status: status)
            classification = "transient.\(status)"
        }
        FernletAuditLog.log("lock.contentKeyRecoveryFailed", context: [
            "classification": classification,
            "enclaveAvailable": "\(SecureEnclaveContentKeyWrap.isAvailable)",
            "wrapPresent": "\(blobPresent)",
            "biometricCopy": "\(hasBiometricRecoveryCopy)"
        ])
        return error
    }

    /// The keep-old-until-verified migration flip: deletes the scrypt-wrapped item once — and
    /// only once — a **freshly re-read** enclave wrap has been proven to unwrap to exactly
    /// `contentKeyData`, leaving the install hard-bound.
    ///
    /// Deliberately re-reads the keychain rather than trusting the blob
    /// `maintainSecureEnclaveWrap` just wrote: the property that justifies deleting the only
    /// other copy is "what is persisted right now opens to this key", and only a read of what is
    /// persisted right now can establish it. Every other outcome — no enclave, no blob, a failed
    /// unwrap, mismatched bytes — returns having changed nothing, so the scrypt item survives and
    /// the flip is retried on the next unlock. Nothing here ever deletes on an error path.
    ///
    /// - Parameter contentKeyData: The authoritative content key (the scrypt-unwrapped bytes at
    ///   unlock, the freshly minted key at configure).
    /// - Parameter migratingExistingInstall: True on the unlock path, where the flip changes the
    ///   recovery properties of a lock the user set up under an older build and never re-consented
    ///   to. That case arms ``hardBindingNoticePending`` so the app can say so once; `configure()`
    ///   passes false because its setup disclosure already covered it.
    private func hardBindToSecureEnclaveIfVerified(contentKeyData: Data, migratingExistingInstall: Bool) {
        guard SecureEnclaveContentKeyWrap.isAvailable else { return }
        // Nothing to delete: already hard-bound (or never written).
        guard KeychainItem.load(for: .wrappedContentKey, service: keychainService) != nil else { return }
        guard let blob = KeychainItem.load(for: .seWrappedContentKey, service: keychainService),
              let seUnwrapped = SecureEnclaveContentKeyWrap.unwrap(blob, service: keychainService),
              constantTimeEqual(seUnwrapped, contentKeyData) else { return }
        KeychainItem.delete(for: .wrappedContentKey, service: keychainService)
        if migratingExistingInstall {
            // Best-effort: a flag that cannot be written costs a disclosure, never data — but the
            // status is CHECKED rather than dropped, because a silently missing disclosure is the
            // one outcome nobody would ever find out about (R7).
            let status = KeychainItem.store(Data([1]), for: .hardBindingNoticePending, service: keychainService)
            if status != errSecSuccess {
                FernletAuditLog.log("lock.hardBindingNotice.flagWriteFailed", context: ["status": "\(status)"])
            }
        }
        FernletAuditLog.log("lock.hardBoundToSecureEnclave", context: [
            "migration": "\(migratingExistingInstall)"
        ])
    }

    /// The content key a LEGACY passcode unlock installs, preferring the Secure-Enclave wrap when
    /// it exists AND its unwrap equals the (verifier-authenticated) scrypt-unwrapped key.
    ///
    /// Only reachable while the scrypt-wrapped item is retained, so the two sources can only
    /// diverge via a stale SE wrap and equality is the correctness gate: on a match the SE bytes
    /// are installed (exercising the enclave path end-to-end); on a miss — missing blob, SE
    /// unavailable, enclave key destroyed by a device erase, or a stale wrap — the scrypt result
    /// is used unchanged and the wrap is repaired best-effort. The hard-bound state has no
    /// counterpart to this gate by construction: with the scrypt item gone there is nothing to
    /// compare against, and `secureEnclaveBoundContentKey()` is authoritative on its own.
    private func secureEnclavePreferredContentKey(scryptUnwrapped: Data) -> Data {
        guard SecureEnclaveContentKeyWrap.isAvailable else { return scryptUnwrapped }
        if let blob = keychainLoad(.seWrappedContentKey, keychainService),
           let seUnwrapped = SecureEnclaveContentKeyWrap.unwrap(blob, service: keychainService),
           constantTimeEqual(seUnwrapped, scryptUnwrapped) {
            return seUnwrapped
        }
        maintainSecureEnclaveWrap(contentKeyData: scryptUnwrapped)
        return scryptUnwrapped
    }

    /// Ensures a healthy Secure-Enclave wrap of `contentKeyData` exists: verifies any stored
    /// blob unwraps to exactly this key, otherwise re-wraps (round-trip-verified inside
    /// `SecureEnclaveContentKeyWrap.wrapVerified`) and stores the new blob.
    ///
    /// Strictly best-effort: every failure path leaves the current custody state untouched. The
    /// one deletion in the whole scheme lives in `hardBindToSecureEnclaveIfVerified(contentKeyData:migratingExistingInstall:)`,
    /// behind its own re-read proof.
    ///
    /// **An openable HARD-BOUND blob is never overwritten.** `storeVerified` is delete-then-add,
    /// so re-wrapping in that state would destroy the only recoverable copy of the key — and one
    /// caller (`unlockWithBiometrics`) passes bytes nothing has authenticated: they come straight
    /// out of the `.biometricBypass` row, never compared against the verifier, the scrypt item or
    /// the enclave. In LEGACY that write is harmless (the scrypt item is still authoritative and
    /// the equality gate repairs the wrap on the next passcode unlock); in HARD-BOUND it would be
    /// deletion by another name. So divergence from an openable hard-bound blob is a fact to
    /// SURFACE, not to repair. The genuine hard-bound heal — no openable blob at all — still runs,
    /// which is what lets the biometric path re-establish a wrap after an enclave key rotation.
    private func maintainSecureEnclaveWrap(contentKeyData: Data) {
        guard SecureEnclaveContentKeyWrap.isAvailable else { return }
        // CLASSIFY before healing (R5). Both halves of the old read collapsed failure into absence —
        // `keychainLoad` returns nil for an unreadable row, and `unwrap` returns nil for a transient
        // decrypt failure exactly as for a destroyed key — so a momentary keychain/enclave outage
        // skipped the divergence check entirely and went on to delete-then-add over the ONE
        // recoverable copy of the key in the hard-bound state. Neither transient may heal.
        switch keychainLoadDistinguishing(.seWrappedContentKey, keychainService) {
        case .unreadable(let status):
            FernletAuditLog.log("lock.seWrapMaintenanceSkipped.unreadable", context: ["status": "\(status)"])
            return
        case .found(let blob):
            switch SecureEnclaveContentKeyWrap.unwrapResult(blob, service: keychainService) {
            case .recovered(let existing):
                if constantTimeEqual(existing, contentKeyData) { return }
                guard case .legacyScryptWrapped = contentKeyCustody() else {
                    FernletAuditLog.log("lock.seWrapDivergence")
                    return
                }
            case .unavailable(let status):
                FernletAuditLog.log("lock.seWrapMaintenanceSkipped.transient", context: ["status": "\(status)"])
                return
            case .keyAbsent, .blobRejected:
                break  // the genuine heal: no openable blob at all
            }
        case .absent:
            break  // nothing stored yet — establish the wrap
        }
        guard let blob = SecureEnclaveContentKeyWrap.wrapVerified(contentKeyData, service: keychainService) else { return }
        do {
            try storeVerified(blob, for: .seWrappedContentKey)
            FernletAuditLog.log("lock.seWrapEstablished")
        } catch {
            // Best-effort: an unstorable wrap changes nothing; the next unlock retries. Loud when
            // it matters, though — in the hard-bound state this leaves the install with NO wrap
            // row, which is the one condition worth finding in a log rather than inferring.
            if case .hardBoundToSecureEnclave = contentKeyCustody() {
                FernletAuditLog.log("lock.seWrapMissingAfterFailedStore")
            }
        }
    }

    // MARK: - Phase 2.5: legacy wrap → FLW2 re-wrap (crypto-standardization)

    /// Runs the Phase 2.5 legacy→`FLW2` wrap re-wrap at its SOLE production seam: the
    /// `.legacyScryptWrapped` arm of a passcode unlock, immediately after the successful scrypt
    /// unwrap proved the content key recoverable and before the Secure-Enclave flip.
    ///
    /// Never throws, never gates the unlock: a failed re-wrap leaves the legacy wrap in place and
    /// the user in — the unlock tail is byte-identical on every migration outcome, and the pass
    /// retries at the next passcode unlock (resumable by re-derivation, not by memory). The
    /// migrator is credential-gated BY CONSTRUCTION (its init requires the recovered content key
    /// and the just-derived wrapping key), so no launch task or credential-free caller can ever
    /// exist. The staging-row orphan cleanup does NOT live here: this helper runs only in the
    /// legacy arm, which the hard-bind flip can retire in the very unlock that orphaned the row —
    /// the custody-independent sweep in `unlock(passcode:for:)` owns that bound (§Q2a).
    ///
    /// R7: `run()`'s Bool is read and audited (`lock.wrapFormatMigrationIncomplete`), never
    /// dropped.
    private func runLockWrapFormatMigration(contentKey: Data, wrappingKey: Data) {
        let migrator = LockWrapFormatMigrator(
            keychainService: keychainService,
            contentKey: contentKey,
            wrappingKey: wrappingKey,
            wrap: { [cryptoProvider] in try cryptoProvider.wrapContentKey($0, using: $1) },
            unwrap: { [cryptoProvider] in try cryptoProvider.unwrapContentKey($0, using: $1) },
            loadRow: keychainLoadDistinguishing,
            storeRow: keychainStore,
            updateRow: keychainUpdate,
            deleteRow: keychainDelete,
            // The latch reads through the SAME injected seam as S0 and custody — one keychain
            // view per pass, in tests and production alike (never a defaulted real read here).
            latch: LockWrapRowLatch(keychainService: keychainService, loadingRow: keychainLoadDistinguishing)
        )
        if !migrator.run() {
            FernletAuditLog.log("lock.wrapFormatMigrationIncomplete")
        }
    }

    /// Which verifier format a re-derived key matched: the digest form (`.current`), the
    /// pre-split raw-key form (`.legacy`), or neither (`.none`).
    ///
    /// Produced by `verifierMatch(computedVerifier:storedVerifier:)`; `.legacy`
    /// additionally signals that an in-place digest migration should run.
    private enum VerifierMatch { case current, legacy, none }

    /// Compares a freshly re-derived scrypt key against the stored verifier, accepting BOTH formats:
    /// `.current` — the stored value is `SHA256(derivedKey)` (the verifier/wrapping-key split); and
    /// `.legacy` — the stored value is the raw derived key itself (written by builds before the split),
    /// which signals the caller to migrate the verifier to the digest form in place. Both comparisons
    /// are constant-time, and the legacy check is a strict fallback so a correct passcode is never
    /// rejected during the one-time migration window.
    private func verifierMatch(computedVerifier: Data, storedVerifier: Data) -> VerifierMatch {
        if constantTimeEqual(FernletLockCrypto.verifierDigest(of: computedVerifier), storedVerifier) { return .current }
        if constantTimeEqual(FernletLockCrypto.legacyVerifierDigest(of: computedVerifier), storedVerifier) {
            return .legacy
        }
        if constantTimeEqual(computedVerifier, storedVerifier) { return .legacy }
        return .none
    }

    /// When `match == .legacy`, opportunistically migrate a legacy raw-key verifier to its digest form
    /// in place. Called from unlock() and setBiometricEnabled() after the content key has been
    /// recovered. No-op for `.current`/`.none`.
    ///
    /// **"Best-effort" is only true with the put-back.** `storeVerified` is delete-then-add over THE
    /// passcode gate: a delete that lands followed by an add (or read-back) that does not leaves NO
    /// verifier row, after which every `unlock()`/`changeCredential()` throws `.notConfigured` while
    /// the state stays `.locked`, and `isAwaitingCustodianRecovery` can misread the device as
    /// recovery-locked. So a failure restores the legacy verifier — the same discipline
    /// `rollBackCredentialRecords` applies to a re-key — and the audit line reports which of the two
    /// outcomes actually happened instead of always claiming success.
    private func migrateLegacyVerifierIfNeeded(_ match: VerifierMatch, computedVerifier: Data) {
        guard case .legacy = match else { return }
        do {
            try storeVerified(FernletLockCrypto.verifierDigest(of: computedVerifier), for: .verifier)
            FernletAuditLog.log("lock.verifierMigratedToDigest")
        } catch {
            let restored = keychainStore(computedVerifier, .verifier, keychainService) == errSecSuccess
                && keychainLoad(.verifier, keychainService) == computedVerifier
            FernletAuditLog.log("lock.verifierMigrationFailed", context: ["legacyRestored": "\(restored)"])
        }
    }

    /// Writes a keychain item and verifies it by status check AND read-back, throwing
    /// `FernletLockError.keychainFailure` if either fails — a failed write must never
    /// masquerade as configured state.
    private func storeVerified(_ data: Data, for key: LockKeychainKey) throws {
        try verifyStatus(keychainStore(data, key, keychainService), operation: "store \(key.rawValue)")
        guard keychainLoad(key, keychainService) == data else {
            throw FernletLockError.keychainFailure(operation: "read back \(key.rawValue)", status: errSecItemNotFound)
        }
    }

    /// Puts the pre-re-key credential records back after a partially applied
    /// ``changeCredential(current:new:)``, restoring the "salt + verifier and the wrapped content
    /// key move together" invariant.
    ///
    /// Best-effort and non-throwing by design: it runs on an error path where the keychain is
    /// already misbehaving, and a throw here would replace a recoverable half-write with a
    /// swallowed one. A row whose prior value was absent is deleted rather than left holding the
    /// new value — that is what "restore" means for the hard-bound state, where
    /// `wrappedContentKey` legitimately does not exist. Loud rather than silent: the outcome is
    /// audit-logged either way.
    private func rollBackCredentialRecords(
        salt: Data,
        verifier: Data,
        kind: Data?,
        scryptN: Data?,
        wrappedContentKey: Data?
    ) {
        var restored = true
        func put(_ data: Data?, _ key: LockKeychainKey) {
            guard let data else {
                KeychainItem.delete(for: key, service: keychainService)
                return
            }
            if keychainStore(data, key, keychainService) != errSecSuccess { restored = false }
        }
        put(salt, .salt)
        put(verifier, .verifier)
        put(kind, .kind)
        put(scryptN, .scryptN)
        put(wrappedContentKey, .wrappedContentKey)
        FernletAuditLog.log("lock.changeCredential.rolledBack", context: ["complete": "\(restored)"])
    }

    /// Throws `FernletLockError.keychainFailure` for any status other than `errSecSuccess`.
    private func verifyStatus(_ status: OSStatus, operation: String) throws {
        guard status == errSecSuccess else {
            throw FernletLockError.keychainFailure(operation: operation, status: status)
        }
    }

    /// Computes the cooldown deadline still in force, or `nil` when none.
    ///
    /// Takes the MAXIMUM of the wall-clock remainder and the monotonic-uptime remainder,
    /// so setting the device clock forward cannot shorten a cooldown; a detected clock
    /// regression is audit-logged. After a reboot (or with no anchor recorded) only the
    /// wall clock applies.
    private func activeCooldownDeadline() -> Date? {
        guard let data = keychainLoad(.cooldownDeadline, keychainService),
              let timeInterval = data.toDouble else { return nil }
        let wallClockDeadline = Date(timeIntervalSinceReferenceDate: timeInterval)
        let wallClockRemaining = wallClockDeadline.timeIntervalSince(dateProvider.now)

        let effectiveRemaining: TimeInterval
        switch monotonicRemainingCooldownSeconds() {
        case .available(let monotonicRemaining):
            effectiveRemaining = max(wallClockRemaining, monotonicRemaining)
            if wallClockRemaining <= 0, monotonicRemaining > 0 {
                FernletAuditLog.log(
                    "lock.cooldownClockRegression",
                    context: ["monotonicRemainingSeconds": "\(Int(monotonicRemaining))"]
                )
            }
        case .rebootDetected:
            effectiveRemaining = wallClockRemaining
            FernletAuditLog.log("lock.cooldownMonotonicResetByReboot")
        case .notRecorded:
            effectiveRemaining = wallClockRemaining
        }

        guard effectiveRemaining > 0 else { return nil }
        return dateProvider.now.addingTimeInterval(effectiveRemaining)
    }

    /// The result of consulting the monotonic-uptime cooldown record: a usable remaining
    /// duration, a reboot (uptime fell below the anchor), or no record at all.
    ///
    /// Distinguishing reboot from "not recorded" lets `activeCooldownDeadline()` fall
    /// back to wall-clock accounting with an audit trail.
    private enum MonotonicCheckOutcome {
        case available(remainingSeconds: TimeInterval)
        case rebootDetected
        case notRecorded
    }

    /// Reads the uptime anchor and duration records and returns the monotonic view of
    /// the cooldown; a current uptime more than a second below the anchor means the
    /// device rebooted.
    private func monotonicRemainingCooldownSeconds() -> MonotonicCheckOutcome {
        guard let anchorData = keychainLoad(.cooldownMonotonicAnchor, keychainService),
              let anchor = anchorData.toDouble,
              let durationData = keychainLoad(.cooldownDurationSeconds, keychainService),
              let duration = durationData.toDouble else {
            return .notRecorded
        }

        let nowUptime = uptimeProvider.systemUptime
        if nowUptime + 1.0 < anchor {
            return .rebootDetected
        }

        let elapsed = nowUptime - anchor
        return .available(remainingSeconds: max(duration - elapsed, 0))
    }

    /// The persisted cooldown-ladder level (0 when none is recorded).
    private func loadCooldownLevel() -> Int {
        guard let data = keychainLoad(.cooldownLevel, keychainService),
              let byte = data.first else { return 0 }
        return Int(byte)
    }

    /// Failed passcode attempts allowed per batch before the cooldown ladder escalates.
    public static let attemptsPerCooldownBatch = 4

    /// Number of levels in the cooldown ladder (60s → 15min → 1h → 4h); failing a batch
    /// at the final level flips `requiresReset` instead of starting another cooldown.
    /// Semantically distinct from ``attemptsPerCooldownBatch`` — the two policy knobs
    /// merely happen to share the value 4.
    private static let cooldownLadderDepth = 4

    /// Registers one failed passcode attempt and applies the escalation policy: every
    /// ``attemptsPerCooldownBatch``th failure advances the cooldown ladder (persisting
    /// deadline, uptime anchor, and duration); failing a batch at the final ladder level
    /// (`cooldownLadderDepth`) flips `requiresReset` instead of starting another cooldown.
    private func recordFailedAttempt() throws {
        let newAttemptCount = currentAttemptCount + 1
        let currentLevel = loadCooldownLevel()

        if newAttemptCount >= Self.attemptsPerCooldownBatch {
            if currentLevel >= Self.cooldownLadderDepth {
                try storeVerified(Data([1]), for: .requiresReset)
                try storeAttemptCount(0)
                state = .locked(cooldownDeadline: nil)
                FernletAuditLog.log("lock.cooldownStarted", context: ["level": "reset-required"])
            } else {
                let newLevel = currentLevel + 1
                let duration = cooldownDuration(for: newLevel)
                let deadline = dateProvider.now.addingTimeInterval(duration)
                try storeVerified(Data([UInt8(newLevel)]), for: .cooldownLevel)

                try storeVerified(LockRecordCodec.encode(deadline.timeIntervalSinceReferenceDate), for: .cooldownDeadline)
                try storeVerified(LockRecordCodec.encode(uptimeProvider.systemUptime), for: .cooldownMonotonicAnchor)
                try storeVerified(LockRecordCodec.encode(duration), for: .cooldownDurationSeconds)

                try storeAttemptCount(0)
                state = .locked(cooldownDeadline: deadline)
                FernletAuditLog.log("lock.cooldownStarted", context: [
                    "level": "\(newLevel)",
                    "durationSeconds": "\(Int(duration))"
                ])
            }
        } else {
            try storeAttemptCount(newAttemptCount)
            state = .locked(cooldownDeadline: activeCooldownDeadline())
        }
    }

    /// Persists the attempt count as a single clamped byte.
    private func storeAttemptCount(_ count: Int) throws {
        try storeVerified(Data([UInt8(min(count, 255))]), for: .attemptCount)
    }

    /// The scrypt N every pre-NEW-3 install used, and the fail-closed fallback for a missing or
    /// out-of-range ``LockKeychainKey/scryptN`` row.
    private static let legacyScryptN: Int32 = 32768

    /// The scrypt N recorded at configure time; pre-NEW-3 installs stored none and
    /// always used 32768, so that is the fallback.
    ///
    /// **Validated, because a persisted row is external input (R5).** The value goes straight into
    /// the memory-hard KDF, which allocates 128·r·N bytes: a corrupt or tampered row (N = 2²⁴ → 16 GB,
    /// or a non-power-of-two, which CryptoSwift rejects outright) would turn every unlock into a
    /// memory-exhaustion crash or a permanent throw. An out-of-range N reads as the pre-NEW-3
    /// default — exactly what a missing row does — so the passcode simply fails to verify.
    private func storedScryptN() -> Int {
        guard let data = keychainLoad(.scryptN, keychainService),
              let stored = LockRecordCodec.decodeInt32(data) else {
            return Int(Self.legacyScryptN)  // pre-NEW-3 installs stored no N; 32768 was the only value used
        }
        guard stored >= Self.legacyScryptN,
              stored <= Int32(FernletLockCrypto.scryptN),
              stored.nonzeroBitCount == 1 else {
            FernletAuditLog.log("lock.scryptNInvalid", context: ["stored": "\(stored)"])
            return Int(Self.legacyScryptN)
        }
        return Int(stored)
    }

    /// Wipes all attempt/cooldown/reset records after a successful passcode unlock.
    private func clearAttemptState() {
        KeychainItem.delete(for: .attemptCount, service: keychainService)
        KeychainItem.delete(for: .cooldownDeadline, service: keychainService)
        KeychainItem.delete(for: .cooldownMonotonicAnchor, service: keychainService)
        KeychainItem.delete(for: .cooldownDurationSeconds, service: keychainService)
        KeychainItem.delete(for: .cooldownLevel, service: keychainService)
        KeychainItem.delete(for: .requiresReset, service: keychainService)
    }
}

extension LockKeychainKey: CaseIterable {
    /// Every lock keychain account, in declaration order — the complete on-device
    /// footprint for wipe and test-cleanup tooling. Keep in sync when adding a key.
    public static var allCases: [LockKeychainKey] {
        [
            .salt,
            .verifier,
            .kind,
            .wrappedContentKey,
            .wrappedContentKeyRewrapStaging,
            .seWrappedContentKey,
            .biometricBypass,
            .biometricEnabledFlag,
            .cooldownDeadline,
            .cooldownMonotonicAnchor,
            .cooldownDurationSeconds,
            .attemptCount,
            .cooldownLevel,
            .requiresReset,
            .scryptN,
            .hardBindingNoticePending,
            .duressSalt,
            .duressVerifier,
            .duressMode,
            .duressKind,
            .recoveryBlob,
            .custodianSigningPublicKey,
            .custodianKeyAgreementPublicKey,
            .recoveryOwnerKeyAgreementPublicKey,
            .recoveryBlobSuperseded
        ]
    }
}

/// Little-endian byte codecs for the fixed-width numbers persisted in lock keychain rows.
///
/// Explicit shifts in both directions, instead of `Data(bytes:count:)` on an `inout` scalar and
/// `withUnsafeBytes { $0.load(as:) }` — raw-buffer reinterpretation is exactly what R9 bans, and a
/// `load(as:)` of attacker-influenceable bytes is also unaligned-load UB waiting to happen. Byte
/// for byte compatible with the rows already on disk: every Apple target is little-endian, so what
/// the previous native-endian writes produced is what ``encode(_:)`` produces and ``decodeInt32(_:)`` /
/// ``decodeFiniteDouble(_:)`` read.
private enum LockRecordCodec {
    /// The four little-endian bytes of `value` (the `.scryptN` row).
    static func encode(_ value: Int32) -> Data {
        encode(UInt32(bitPattern: value), byteCount: MemoryLayout<Int32>.size)
    }

    /// The eight little-endian bytes of `value`'s IEEE-754 bit pattern (the cooldown rows).
    static func encode(_ value: Double) -> Data {
        encode(value.bitPattern, byteCount: MemoryLayout<Double>.size)
    }

    /// Decodes exactly four little-endian bytes as an `Int32`; `nil` on any other length.
    static func decodeInt32(_ data: Data) -> Int32? {
        guard data.count == MemoryLayout<Int32>.size else { return nil }
        return Int32(bitPattern: UInt32(truncatingIfNeeded: littleEndianValue(data)))
    }

    /// Decodes exactly eight little-endian bytes as a **finite** `Double`; `nil` on any other
    /// length and on a NaN/±infinity bit pattern.
    ///
    /// The finiteness guard is a validation, not a nicety: a NaN cooldown deadline propagates into
    /// `max()` and `> 0` comparisons that are false for NaN, which would silently dissolve an
    /// active brute-force cooldown — a corrupt row failing OPEN. `nil` means "no record", which
    /// the cooldown readers already handle.
    static func decodeFiniteDouble(_ data: Data) -> Double? {
        guard data.count == MemoryLayout<Double>.size else { return nil }
        let value = Double(bitPattern: littleEndianValue(data))
        guard value.isFinite else { return nil }
        return value
    }

    /// Little-endian bytes of an unsigned integer, least-significant byte first.
    private static func encode<T: FixedWidthInteger & UnsignedInteger>(_ value: T, byteCount: Int) -> Data {
        Data((0..<byteCount).map { UInt8(truncatingIfNeeded: value >> (8 * $0)) })
    }

    /// Reassembles up to eight little-endian bytes into a `UInt64`.
    private static func littleEndianValue(_ data: Data) -> UInt64 {
        data.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }
}

private extension Data {
    /// Decodes exactly 8 little-endian bytes as a finite `Double` (the encoding used for the
    /// cooldown deadline/anchor/duration records); `nil` on any other length or a non-finite
    /// bit pattern — see ``LockRecordCodec/decodeFiniteDouble(_:)``.
    var toDouble: Double? {
        LockRecordCodec.decodeFiniteDouble(self)
    }
}
