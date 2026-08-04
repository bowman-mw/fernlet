// FernletLockService.swift
// Fernlet
//
// Scrypt KDF via krzyzanowskim/CryptoSwift (https://github.com/krzyzanowskim/CryptoSwift).
// Memory-hard KDF, no PBKDF2 fallback.

import Foundation
import FernletFoundation
import CryptoKit
import Security
import LocalAuthentication
import Combine
import OSLog
import CryptoSwift
import Observation
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

    /// First-time setup: derives the verifier, mints and wraps the content key, and unlocks.
    func configure(credential: FernletLockCredential) async throws
    /// Re-keys the credential in place, preserving the content key (no sealed-data loss).
    func changeCredential(current: String, new: FernletLockCredential) async throws
    /// Verifies the passcode, unwraps the content key, and unlocks.
    func unlock(passcode: String) async throws -> UnlockResult
    /// Recovers the content key from the biometric-gated keychain item and unlocks.
    func unlockWithBiometrics() async throws -> UnlockResult
    /// Engages the lock and scrubs the in-memory content key.
    func lock(reason: FernletLockReason)
    /// Destroys all lock keychain state AND purges the sealed narrative entities.
    func reset() throws
    /// Enables or disables biometric unlock; enabling requires the current passcode.
    func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws
    /// The unwrapped content key while unlocked, `nil` otherwise.
    func contentKey() -> SymmetricKey?
}

extension FernletLockServicing {
    /// Satisfies the narrow `PeriodLockContext.isLockConfigured` seam without each conformer
    /// reimplementing it: a lock is "configured" once it leaves the `.notConfigured` state.
    public var isLockConfigured: Bool { state != .notConfigured }
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
    /// Unlocked; the content key is available via ``FernletLockServicing/contentKey()``.
    case unlocked
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

    /// The stable string written to `FernletAuditLog` for this reason.
    var auditLabel: String {
        switch self {
        case .viewDisappeared: "viewDisappeared"
        case .background: "background"
        case .protectedDataUnavailable: "protectedDataUnavailable"
        case .manual: "manual"
        case .failedAttempts: "failedAttempts"
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
/// Returned by ``FernletLockServicing/unlock(passcode:)`` and
/// ``FernletLockServicing/unlockWithBiometrics()``; currently records only the
/// ``UnlockMethod`` that succeeded.
public struct UnlockResult {
    /// The method that performed this unlock.
    public let method: UnlockMethod

    /// Creates a result for the given unlock method.
    public init(method: UnlockMethod) {
        self.method = method
    }
}

// MARK: - Cryptographic primitives

/// The lock's raw cryptographic primitives: scrypt passcode derivation, content-key
/// generation and ChaChaPoly wrapping, HKDF column-key derivation, and the verifier digest.
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
    /// keys are derived from.
    nonisolated static func generateContentKey() -> Data {
        let key = SymmetricKey(size: .bits256)
        return key.withUnsafeBytes { Data($0) }
    }

    /// Seals the content key with ChaChaPoly under the scrypt-derived wrapping key,
    /// returning the combined (nonce + ciphertext + tag) blob stored in the keychain.
    nonisolated static func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data {
        let wrappingKey = SymmetricKey(data: wrappingKeyData)
        return try ChaChaPoly.seal(contentKey, using: wrappingKey).combined
    }

    /// Opens a ChaChaPoly-wrapped content key; throws on tampering or a wrong wrapping key.
    nonisolated static func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data {
        let wrappingKey = SymmetricKey(data: wrappingKeyData)
        let sealedBox = try ChaChaPoly.SealedBox(combined: wrappedContentKey)
        return try ChaChaPoly.open(sealedBox, using: wrappingKey)
    }

    /// Derives a purpose-bound subkey from the content key via HKDF-SHA256, with `info`
    /// as the domain-separation label — how sealed stores obtain per-column keys.
    nonisolated static func deriveColumnKey(contentKey: Data, info: String, outputByteCount: Int) -> Data {
        let inputKey = SymmetricKey(data: contentKey)
        let derivedKey = HKDF<SHA256>.deriveKey(
            inputKeyMaterial: inputKey,
            info: Data(info.utf8),
            outputByteCount: outputByteCount
        )
        return derivedKey.withUnsafeBytes { Data($0) }
    }

    /// The at-rest passcode verifier is the SHA-256 digest of the scrypt-derived key — NOT the derived
    /// key itself. Persisting only the digest keeps the content-key *wrapping* key out of the keychain:
    /// a keychain compromise then yields only `salt + SHA256(derivedKey) + wrappedContentKey`, so an
    /// attacker must still brute-force the passcode through scrypt to re-derive the wrapping key and
    /// unwrap the content key. The raw derived key remains the wrapping key, used in memory only and
    /// never written to disk. (Security hardening — see the verifier/wrapping-key split.)
    nonisolated static func verifierDigest(of derivedKey: Data) -> Data {
        Data(SHA256.hash(data: derivedKey))
    }
}

/// Injection seam over ``FernletLockCrypto`` so tests can substitute deterministic
/// salts, keys, and derivations.
///
/// ``SystemFernletLockCryptoProvider`` is the production conformer; unit tests inject
/// fakes through ``FernletLockService``'s initializer. `@MainActor` class-bound to
/// match the service that owns it — the memory-hard scrypt derivation still hops
/// off-main inside the implementation.
@MainActor
public protocol FernletLockCryptoProviding: AnyObject {
    /// Produces a fresh random salt for credential (re)configuration.
    func generateSalt() throws -> Data
    /// Derives the scrypt wrapping key for `passcode` and `salt` with cost parameter `n`.
    func deriveVerifier(passcode: String, salt: Data, n: Int) async throws -> Data
    /// Mints a fresh random 256-bit content key.
    func generateContentKey() -> Data
    /// Seals the content key under the derived wrapping key.
    func wrapContentKey(_ contentKey: Data, using wrappingKeyData: Data) throws -> Data
    /// Opens a wrapped content key; throws if the wrapping key is wrong or the blob is tampered.
    func unwrapContentKey(_ wrappedContentKey: Data, using wrappingKeyData: Data) throws -> Data
}

/// The production ``FernletLockCryptoProviding`` conformer.
///
/// A stateless pass-through to the ``FernletLockCrypto`` statics; ``FernletLockService``
/// creates one by default when no provider is injected.
final class SystemFernletLockCryptoProvider: FernletLockCryptoProviding {
    func generateSalt() throws -> Data {
        try FernletLockCrypto.generateSalt()
    }

    func deriveVerifier(passcode: String, salt: Data, n: Int) async throws -> Data {
        try await FernletLockCrypto.deriveVerifier(passcode: passcode, salt: salt, n: n)
    }

    func generateContentKey() -> Data {
        FernletLockCrypto.generateContentKey()
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
    /// The ChaChaPoly-sealed content key.
    case wrappedContentKey = "com.fernlet.lock.wrappedContentKey"
    /// The raw content key behind a `.biometryCurrentSet` access control (Face ID/Touch ID path).
    case biometricBypass = "com.fernlet.lock.biometricBypass"
    /// Presence flag: biometric unlock is enabled.
    case biometricEnabledFlag = "com.fernlet.lock.biometricEnabled"
    /// Wall-clock cooldown deadline (seconds since reference date, as `Double` bytes).
    case cooldownDeadline = "com.fernlet.lock.cooldownDeadline"
    /// System-uptime anchor captured when the cooldown started (anti clock-rollback).
    case cooldownMonotonicAnchor = "com.fernlet.lock.cooldownMonotonicAnchor"
    /// The active cooldown's duration in seconds (as `Double` bytes).
    case cooldownDurationSeconds = "com.fernlet.lock.cooldownDurationSeconds"
    /// Failed attempts since the last success or cooldown escalation (single byte).
    case attemptCount = "com.fernlet.lock.attemptCount"
    /// Current escalation level on the cooldown ladder (single byte).
    case cooldownLevel = "com.fernlet.lock.cooldownLevel"
    /// Presence flag: escalation exhausted; only a destructive reset unlocks again.
    case requiresReset = "com.fernlet.lock.requiresReset"
    /// The scrypt N the stored verifier was derived with (native-endian `Int32` bytes).
    case scryptN = "com.fernlet.lock.scryptN"
}

/// Injection seam for "now", letting tests drive cooldown-deadline arithmetic
/// deterministically.
///
/// ``SystemFernletDateProvider`` (wall-clock `Date()`) is the default;
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
/// ``SystemFernletUptimeProvider`` (`ProcessInfo.systemUptime`) is the default. Uptime
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
    ///   value back (`storeVerified`) before trusting the write.
    @discardableResult
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
    /// biometric gate); throws when the `SecAccessControl` cannot be created.
    static func accessControl(for flag: SecAccessControlCreateFlags) throws -> SecAccessControl {
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

    /// Synchronously authenticates with biometrics and reads the bypass item.
    ///
    /// Blocks the calling thread on the LocalAuthentication evaluation (semaphore), so it
    /// must run off the main thread — ``FernletLockService/unlockWithBiometrics()`` calls
    /// it from a global queue. The pre-evaluated `LAContext` is handed to
    /// `SecItemCopyMatching`, so the user sees a single system prompt.
    /// - Returns: The stored content-key bytes.
    static func loadBiometricBypassSync(prompt: String, service: String) throws -> Data {
        let context = LAContext()
        context.localizedReason = prompt

        let access = try accessControl(for: .biometryCurrentSet)
        let authGroup = DispatchSemaphore(value: 0)
        let authLock = NSLock()
        var authSucceeded = false
        var authError: Error?
        context.evaluateAccessControl(access, operation: .useItem, localizedReason: prompt) { success, error in
            authLock.lock()
            authSucceeded = success
            authError = error
            authLock.unlock()
            authGroup.signal()
        }
        authGroup.wait()

        authLock.lock()
        let didAuthenticate = authSucceeded
        let authenticationError = authError
        authLock.unlock()
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
        guard status == errSecSuccess, let data = result as? Data else {
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
    /// True while ``unlockWithBiometrics()`` is in flight, so observers (the lock gate's
    /// scene-phase re-lock handling) can tell the system Face ID sheet apart from a real
    /// backgrounding.
    public private(set) var isPerformingBiometricUnlock = false

    /// Combine mirror of ``state`` for subscribers outside the Observation system.
    public var statePublisher: AnyPublisher<FernletLockState, Never> { stateSubject.eraseToAnyPublisher() }

    /// The keychain service namespace all ``LockKeychainKey`` items live under
    /// (`KeychainItem.productionService` by default; tests inject isolated services).
    public let keychainService: String
    @ObservationIgnored private let dateProvider: FernletDateProviding
    @ObservationIgnored private let uptimeProvider: FernletUptimeProviding
    @ObservationIgnored private let cryptoProvider: FernletLockCryptoProviding
    /// Test seam replacing the LocalAuthentication + keychain biometric read
    /// (`(prompt, service) -> contentKeyData`); `nil` in production.
    @ObservationIgnored private let biometricBypassLoader: ((String, String) throws -> Data)?
    @ObservationIgnored private let keychainStore: (Data, LockKeychainKey, String) -> OSStatus
    @ObservationIgnored private let keychainLoad: (LockKeychainKey, String) -> Data?
    /// The sealed CoreData stack whose encrypted entities ``reset()`` purges.
    @ObservationIgnored private let privatePersistenceController: PrivatePersistenceController
    /// The unwrapped content key; non-nil only while `.unlocked`, scrubbed on lock/reset.
    @ObservationIgnored private var _contentKey: SymmetricKey?
    /// The sealed pending-narrative buffer exposed through the `PeriodLockContext` seam.
    @ObservationIgnored private let buffer = PendingNarrativeBuffer()

    /// Creates the service, wiring production defaults for any dependency not injected,
    /// and derives the initial state from the keychain: `.notConfigured` when no salt
    /// exists, otherwise `.locked` with any still-active cooldown deadline.
    public init(
        keychainService: String = KeychainItem.productionService,
        dateProvider: FernletDateProviding? = nil,
        uptimeProvider: FernletUptimeProviding? = nil,
        cryptoProvider: FernletLockCryptoProviding? = nil,
        biometricBypassLoader: ((String, String) throws -> Data)? = nil,
        keychainStore: ((Data, LockKeychainKey, String) -> OSStatus)? = nil,
        keychainLoad: ((LockKeychainKey, String) -> Data?)? = nil,
        privatePersistenceController: PrivatePersistenceController? = nil
    ) {
        self.keychainService = keychainService
        self.dateProvider = dateProvider ?? SystemFernletDateProvider()
        self.uptimeProvider = uptimeProvider ?? SystemFernletUptimeProvider()
        self.cryptoProvider = cryptoProvider ?? SystemFernletLockCryptoProvider()
        self.biometricBypassLoader = biometricBypassLoader
        self.keychainStore = keychainStore ?? { data, key, service in
            KeychainItem.store(data, for: key, service: service)
        }
        self.keychainLoad = keychainLoad ?? { key, service in
            KeychainItem.load(for: key, service: service)
        }
        self.privatePersistenceController = privatePersistenceController ?? .shared

        if self.keychainLoad(.salt, keychainService) == nil {
            state = .notConfigured
        } else {
            state = .locked(cooldownDeadline: activeCooldownDeadline())
        }
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
    public var biometricType: LABiometryType {
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) else {
            return .none
        }
        return context.biometryType
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
    /// biometric/cooldown state, and transitions straight to `.unlocked`.
    public func configure(credential: FernletLockCredential) async throws {
        try credential.validate()

        let saltData = try cryptoProvider.generateSalt()
        let derivedKey = try await cryptoProvider.deriveVerifier(passcode: credential.rawValue, salt: saltData, n: FernletLockCrypto.scryptN)
        let contentKeyData = cryptoProvider.generateContentKey()
        let wrappedContentKey = try cryptoProvider.wrapContentKey(contentKeyData, using: derivedKey)

        try storeVerified(saltData, for: .salt)
        // Store the DIGEST of the derived key, not the derived key itself — the derived key is the
        // content-key wrapping key (used just above) and must never be persisted. See verifierDigest.
        try storeVerified(FernletLockCrypto.verifierDigest(of: derivedKey), for: .verifier)
        try storeVerified(Data(credential.kind.rawValue.utf8), for: .kind)
        try storeVerified(wrappedContentKey, for: .wrappedContentKey)
        var configuredN = Int32(FernletLockCrypto.scryptN)
        try storeVerified(Data(bytes: &configuredN, count: MemoryLayout<Int32>.size), for: .scryptN)
        KeychainItem.delete(for: .biometricBypass, service: keychainService)
        KeychainItem.delete(for: .biometricEnabledFlag, service: keychainService)
        KeychainItem.delete(for: .cooldownDeadline, service: keychainService)
        KeychainItem.delete(for: .cooldownMonotonicAnchor, service: keychainService)
        KeychainItem.delete(for: .cooldownDurationSeconds, service: keychainService)
        KeychainItem.delete(for: .attemptCount, service: keychainService)
        KeychainItem.delete(for: .cooldownLevel, service: keychainService)
        KeychainItem.delete(for: .requiresReset, service: keychainService)

        _contentKey = SymmetricKey(data: contentKeyData)
        state = .unlocked
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.configured", context: ["kind": credential.kind.rawValue])
    }

    /// Re-keys the lock under a new credential while preserving the content key.
    ///
    /// Verifies `current` (accepting the legacy raw-key verifier), unwraps the content
    /// key, re-wraps it under the new credential's derived key with a fresh salt, and
    /// rewrites the verifier in digest form. Refreshes the biometric-bypass item when
    /// biometrics are enabled. Because the content key is unchanged, sealed data never
    /// needs re-encryption.
    public func changeCredential(current: String, new: FernletLockCredential) async throws {
        try new.validate()
        guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
              let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService),
              let wrappedData = KeychainItem.load(for: .wrappedContentKey, service: keychainService) else {
            throw FernletLockError.notConfigured
        }

        let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: current, salt: saltData, n: storedScryptN())
        // Accept either the current digest verifier or a legacy raw-key verifier; re-keying below
        // rewrites it in the new digest format regardless, so no separate migration step is needed.
        if case .none = verifierMatch(computedVerifier: computedVerifier, storedVerifier: storedVerifier) {
            throw FernletLockError.invalidPasscode
        }

        let contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
        let newSalt = try cryptoProvider.generateSalt()
        let newDerivedKey = try await cryptoProvider.deriveVerifier(passcode: new.rawValue, salt: newSalt, n: FernletLockCrypto.scryptN)
        let newWrappedContentKey = try cryptoProvider.wrapContentKey(contentKeyData, using: newDerivedKey)

        try storeVerified(newSalt, for: .salt)
        try storeVerified(FernletLockCrypto.verifierDigest(of: newDerivedKey), for: .verifier)
        try storeVerified(Data(new.kind.rawValue.utf8), for: .kind)
        try storeVerified(newWrappedContentKey, for: .wrappedContentKey)
        var newN = Int32(FernletLockCrypto.scryptN)
        try storeVerified(Data(bytes: &newN, count: MemoryLayout<Int32>.size), for: .scryptN)

        if KeychainItem.load(for: .biometricEnabledFlag, service: keychainService) != nil {
            try KeychainItem.storeBiometricBypass(contentKeyData, service: keychainService)
        }
        if case .unlocked = state {
            _contentKey = SymmetricKey(data: contentKeyData)
        }

        FernletAuditLog.log("lock.kindChanged", context: ["newKind": new.kind.rawValue])
    }

    /// Attempts a passcode unlock.
    ///
    /// Refuses when a reset is required or a cooldown is active. On a wrong passcode it
    /// records the failed attempt (possibly escalating a cooldown) and throws
    /// `FernletLockError.invalidPasscode`; on success it migrates a legacy verifier if
    /// needed, clears attempt state, installs the content key, and unlocks.
    /// - Returns: An ``UnlockResult`` with method `.passcode`.
    public func unlock(passcode: String) async throws -> UnlockResult {
        guard !requiresReset else { throw FernletLockError.resetRequired }
        if let deadline = activeCooldownDeadline() {
            state = .locked(cooldownDeadline: deadline)
            throw FernletLockError.cooldownActive(deadline: deadline)
        }

        guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
              let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService),
              let wrappedData = KeychainItem.load(for: .wrappedContentKey, service: keychainService) else {
            throw FernletLockError.notConfigured
        }

        let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
        let match = verifierMatch(computedVerifier: computedVerifier, storedVerifier: storedVerifier)
        if case .none = match {
            try recordFailedAttempt()
            FernletAuditLog.log("lock.failedAttempt", context: ["cooldownLevel": "\(loadCooldownLevel())"])
            throw FernletLockError.invalidPasscode
        }

        let contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
        // First successful unlock under a build that splits the verifier from the wrapping key:
        // rewrite the raw-key verifier to its digest in place (best-effort, legacy match only).
        migrateLegacyVerifierIfNeeded(match, computedVerifier: computedVerifier)
        clearAttemptState()
        _contentKey = SymmetricKey(data: contentKeyData)
        state = .unlocked
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.released", context: ["method": "passcode"])
        return UnlockResult(method: .passcode)
    }

    /// Attempts a biometric unlock by reading the `.biometryCurrentSet`-gated bypass item.
    ///
    /// The blocking LocalAuthentication + keychain read runs on a global user-initiated
    /// queue (or through the injected `biometricBypassLoader` in tests). Does not touch
    /// the passcode attempt counter — biometric lockout is the OS's job. Throws
    /// `FernletLockError.biometricNotAvailable`/`.biometricFailed` (or the underlying
    /// LocalAuthentication error).
    /// - Returns: An ``UnlockResult`` with method `.biometric`.
    public func unlockWithBiometrics() async throws -> UnlockResult {
        guard !requiresReset else { throw FernletLockError.resetRequired }
        isPerformingBiometricUnlock = true
        defer { isPerformingBiometricUnlock = false }

        let contentKeyData: Data
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
        _contentKey = SymmetricKey(data: contentKeyData)
        state = .unlocked
        hasAutoPromptedBiometricForCurrentLockSession = false
        FernletAuditLog.log("lock.released", context: ["method": "biometric"])
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

    /// The destructive escape hatch: deletes every lock keychain item, purges the
    /// pending-narrative buffer AND the sealed encrypted CoreData entities, scrubs the
    /// content key, and returns to `.notConfigured`.
    ///
    /// - Important: Sealed content is unrecoverable afterward — the content key is gone.
    public func reset() throws {
        KeychainItem.deleteAll(service: keychainService)
        try buffer.purge()
        try privatePersistenceController.purgeEncryptedEntities()
        scrubContentKey()
        state = .notConfigured
        hasAutoPromptedBiometricForCurrentLockSession = false
        isPerformingBiometricUnlock = false
        FernletAuditLog.log("lock.reset")
    }

    /// Enables or disables biometric unlock.
    ///
    /// Enabling verifies the passcode, then stores the raw content key behind a
    /// `.biometryCurrentSet` access control and sets the enabled flag; disabling deletes
    /// both items. Also opportunistically migrates a legacy verifier (see `unlock`).
    public func setBiometricEnabled(_ enabled: Bool, passcode: String) async throws {
        if enabled {
            guard let saltData = KeychainItem.load(for: .salt, service: keychainService),
                  let storedVerifier = KeychainItem.load(for: .verifier, service: keychainService),
                  let wrappedData = KeychainItem.load(for: .wrappedContentKey, service: keychainService) else {
                throw FernletLockError.notConfigured
            }

            let computedVerifier = try await cryptoProvider.deriveVerifier(passcode: passcode, salt: saltData, n: storedScryptN())
            let match = verifierMatch(computedVerifier: computedVerifier, storedVerifier: storedVerifier)
            if case .none = match {
                throw FernletLockError.invalidPasscode
            }

            let contentKeyData = try cryptoProvider.unwrapContentKey(wrappedData, using: computedVerifier)
            // Opportunistically migrate a legacy raw-key verifier to its digest (see unlock()).
            migrateLegacyVerifierIfNeeded(match, computedVerifier: computedVerifier)
            try KeychainItem.storeBiometricBypass(contentKeyData, service: keychainService)
            try storeVerified(Data([1]), for: .biometricEnabledFlag)
        } else {
            KeychainItem.delete(for: .biometricBypass, service: keychainService)
            KeychainItem.delete(for: .biometricEnabledFlag, service: keychainService)
        }
    }

    /// The unwrapped content key while `.unlocked`, else `nil`; sealed repositories pass
    /// it into their per-operation crypto.
    public func contentKey() -> SymmetricKey? {
        _contentKey
    }

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
        if constantTimeEqual(computedVerifier, storedVerifier) { return .legacy }
        return .none
    }

    /// When `match == .legacy`, opportunistically migrate a legacy raw-key verifier to its digest form
    /// in place. Best-effort — a failure here leaves the legacy verifier intact (still valid via the
    /// legacy compare) and retries on the next successful passcode unlock. Called from unlock() and
    /// setBiometricEnabled() after the content key has been recovered. No-op for `.current`/`.none`.
    private func migrateLegacyVerifierIfNeeded(_ match: VerifierMatch, computedVerifier: Data) {
        guard case .legacy = match else { return }
        try? storeVerified(FernletLockCrypto.verifierDigest(of: computedVerifier), for: .verifier)
        FernletAuditLog.log("lock.verifierMigratedToDigest")
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

    /// Registers one failed passcode attempt and applies the escalation policy: every
    /// 4th failure advances the cooldown ladder (persisting deadline, uptime anchor, and
    /// duration); failing a batch at level 4 flips `requiresReset` instead of starting
    /// another cooldown.
    private func recordFailedAttempt() throws {
        let newAttemptCount = currentAttemptCount + 1
        let currentLevel = loadCooldownLevel()

        if newAttemptCount >= 4 {
            if currentLevel >= 4 {
                try storeVerified(Data([1]), for: .requiresReset)
                try storeAttemptCount(0)
                state = .locked(cooldownDeadline: nil)
                FernletAuditLog.log("lock.cooldownStarted", context: ["level": "reset-required"])
            } else {
                let newLevel = currentLevel + 1
                let duration = cooldownDuration(for: newLevel)
                let deadline = dateProvider.now.addingTimeInterval(duration)
                try storeVerified(Data([UInt8(newLevel)]), for: .cooldownLevel)

                var deadlineInterval = deadline.timeIntervalSinceReferenceDate
                try storeVerified(Data(bytes: &deadlineInterval, count: MemoryLayout<Double>.size), for: .cooldownDeadline)

                var anchor = uptimeProvider.systemUptime
                try storeVerified(Data(bytes: &anchor, count: MemoryLayout<Double>.size), for: .cooldownMonotonicAnchor)

                var durationSeconds = duration
                try storeVerified(Data(bytes: &durationSeconds, count: MemoryLayout<Double>.size), for: .cooldownDurationSeconds)

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

    /// The scrypt N recorded at configure time; pre-NEW-3 installs stored none and
    /// always used 32768, so that is the fallback.
    private func storedScryptN() -> Int {
        guard let data = keychainLoad(.scryptN, keychainService),
              data.count == MemoryLayout<Int32>.size else {
            return 32768  // pre-NEW-3 installs stored no N; 32768 was the only value used
        }
        return Int(data.withUnsafeBytes { $0.load(as: Int32.self) })
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
            .biometricBypass,
            .biometricEnabledFlag,
            .cooldownDeadline,
            .cooldownMonotonicAnchor,
            .cooldownDurationSeconds,
            .attemptCount,
            .cooldownLevel,
            .requiresReset,
            .scryptN
        ]
    }
}

private extension Data {
    /// Reinterprets exactly 8 bytes as a native-endian `Double` (the encoding used for
    /// the cooldown deadline/anchor/duration records); `nil` on any other length.
    var toDouble: Double? {
        guard count == MemoryLayout<Double>.size else { return nil }
        return withUnsafeBytes { $0.load(as: Double.self) }
    }
}
