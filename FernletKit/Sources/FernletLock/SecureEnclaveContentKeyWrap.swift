// SecureEnclaveContentKeyWrap.swift
// Fernlet
//
// Secure-Enclave wrap of the lock content key (Docs/Verifiability.md §4, §6.1).
// HARD device-binding: on hardware with an enclave this wrap becomes the AUTHORITATIVE — and
// only — recoverable copy of the content key once `FernletLockService` has proven a full
// unwrap round-trip and deleted the scrypt-wrapped item, so the sealed corpus plus a full
// keychain dump is useless off-device even with the passcode. Where no enclave exists the
// scrypt item is never deleted and this file is inert.

import CryptoKit
import Foundation
import Security

/// ECIES wrap/unwrap of the lock content key under a non-exportable Secure Enclave P-256 key.
///
/// Driven entirely by `FernletLockService`, which maintains the wrap (creating it with a full
/// round-trip check) on every successful configure and on every LEGACY unlock; a hard-bound
/// unlock only unwraps, because the stored blob is already the authoritative copy. The wrap's
/// standing depends on the service's two custody states — this type is deliberately unaware of
/// which one is in force:
/// - **LEGACY** (scrypt item present, or no enclave at all): additive. Every operation fails soft
///   to `nil`, and behavior degrades to exactly the pre-existing scrypt path — nothing here may
///   block an unlock.
/// - **HARD-BOUND** (scrypt item deleted after this wrap proved a round-trip): authoritative.
///   Deleting the scrypt item is the service's decision, made only against a freshly re-read blob
///   that this type demonstrably opens.
///
/// A recovery failure is NOT one outcome. ``unwrap(_:service:)`` collapses every failure into
/// `nil` and is the right primitive for the fail-soft maintenance paths, but the hard-bound
/// recovery path must distinguish "the enclave key is genuinely gone" (terminal: the corpus is
/// unopenable) from "the keychain would not answer right now" (retryable: the device is locked,
/// protected data is unavailable). ``unwrapResult(_:service:)`` is that classifier, and
/// `FernletLockService.secureEnclaveBoundContentKey()` is its only caller — telling a user to run
/// a destructive reset because of a transient `errSecInteractionNotAllowed` would be the exact
/// inverse of the nothing-silent principle.
///
/// Nothing here ever deletes lock state; ``deleteKey(service:)`` destroys only the enclave key
/// itself, and only from `FernletLockService.reset()`.
///
/// The SE private key is a `kSecClassKey` item (token `kSecAttrTokenIDSecureEnclave`,
/// `WhenUnlockedThisDeviceOnly` + `.privateKeyUsage`, permanent, tagged per keychain-service so
/// test instances stay isolated). The key material never exists outside the enclave; only
/// `SecKeyCreateDecryptedData` against the enclave can recover a wrapped blob.
///
/// `nonisolated`: pure Security-framework calls with no shared state (this module defaults to
/// MainActor isolation; the lock service calls these from the main actor, but nothing requires it).
nonisolated enum SecureEnclaveContentKeyWrap {
    /// Whether this device (or simulator host) exposes a Secure Enclave at all.
    static var isAvailable: Bool { SecureEnclave.isAvailable }

    /// The ECIES algorithm used for both wrap and unwrap (Apple's recommended variant for
    /// Secure-Enclave EC keys: X9.63 KDF over SHA-256, AES-GCM payload).
    static let algorithm: SecKeyAlgorithm = .eciesEncryptionCofactorVariableIVX963SHA256AESGCM

    /// The per-service application tag the SE key is stored under, so the production lock
    /// service and every test's isolated service each get their own enclave key.
    static func keyTag(forService service: String) -> Data {
        Data("com.fernlet.lock.seKey.\(service)".utf8)
    }

    /// Wraps `contentKey` under the (existing or newly created) SE key and **verifies a full
    /// unwrap round-trip** before returning the blob — a wrap that cannot be proven openable is
    /// discarded rather than stored.
    ///
    /// - Returns: The ECIES ciphertext to persist, or `nil` when the enclave is unavailable or
    ///   any step fails (create, copy public key, encrypt, or the verification decrypt).
    static func wrapVerified(_ contentKey: Data, service: String) -> Data? {
        guard isAvailable, let privateKey = loadOrCreateKey(service: service),
              let publicKey = SecKeyCopyPublicKey(privateKey),
              SecKeyIsAlgorithmSupported(publicKey, .encrypt, algorithm) else { return nil }
        // No CFError out-parameter: nothing here reads it, and an unread Create-rule error is a
        // leak. The nil return is the whole classification this path needs (R9).
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, algorithm, contentKey as CFData, nil) as Data? else {
            return nil
        }
        // Keep-old-until-verified: only hand back a blob the enclave demonstrably opens to the
        // exact input. If verification fails, the caller keeps relying on the scrypt path — and,
        // crucially, never reaches the point where it would delete that path.
        guard let roundTripped = unwrap(wrapped, service: service), roundTripped == contentKey else { return nil }
        return wrapped
    }

    /// Opens an ECIES-wrapped content-key blob against this service's SE key.
    ///
    /// Fail-soft by design: every failure mode collapses to `nil`, which is what the additive
    /// maintenance paths want (a wrap that will not open is repaired, never trusted). The
    /// hard-bound recovery path must NOT use this — it cannot tell a destroyed enclave key from a
    /// keychain that is merely unreadable right now; use ``unwrapResult(_:service:)`` there.
    ///
    /// - Returns: The recovered content-key bytes, or `nil` when the enclave/key is unavailable
    ///   or the blob does not authenticate (tampered, or wrapped under a different SE key —
    ///   e.g. after an Erase All Content and Settings destroyed the original).
    static func unwrap(_ blob: Data, service: String) -> Data? {
        guard case .recovered(let data) = unwrapResult(blob, service: service) else { return nil }
        return data
    }

    /// The classified outcome of a hard-bound unwrap: which of the four states the enclave is in,
    /// rather than the single `nil` ``unwrap(_:service:)`` collapses them to.
    ///
    /// Only ``keyAbsent`` and ``blobRejected`` are terminal (the content key really is gone);
    /// ``unavailable(_:)`` is a transient the caller must offer to retry rather than answer with
    /// a destructive reset.
    enum UnwrapOutcome: Equatable {
        /// The blob opened; carries the recovered content-key bytes.
        case recovered(Data)
        /// The enclave key does not exist (`errSecItemNotFound`) — destroyed by an Erase All
        /// Content and Settings, a Secure-Enclave reset, or a restore onto other hardware.
        case keyAbsent
        /// The keychain refused to answer (`errSecInteractionNotAllowed`, `errSecNotAvailable`,
        /// any other status), or no enclave exists at all. The key's fate is UNKNOWN.
        case unavailable(OSStatus)
        /// The key is present and readable, but it will not open this blob: the blob is tampered
        /// with, or it was wrapped under a different (since-replaced) enclave key.
        case blobRejected
    }

    /// Opens `blob` and classifies the failure, distinguishing a genuinely destroyed enclave key
    /// from a keychain that could not be read at this instant.
    static func unwrapResult(_ blob: Data, service: String) -> UnwrapOutcome {
        guard isAvailable else { return .unavailable(errSecNotAvailable) }
        let privateKey: SecKey
        switch loadKeyResult(service: service) {
        case .loaded(let key):
            privateKey = key
        case .absent:
            return .keyAbsent
        case .unreadable(let status):
            return .unavailable(status)
        }
        guard SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else {
            return .unavailable(errSecUnimplemented)
        }
        // The ONE site in this file where the Create-rule CFError is load-bearing: without it every
        // decrypt failure reads as TERMINAL, and `FernletLockService.secureEnclaveBoundContentKey()`
        // turns terminal into the destructive-reset copy. The enclave key is
        // `WhenUnlockedThisDeviceOnly` and an unlock straddles a several-hundred-ms scrypt derive,
        // so "the keychain would not answer right now" is a reachable, retryable state.
        var error: Unmanaged<CFError>?
        guard let data = SecKeyCreateDecryptedData(privateKey, algorithm, blob as CFData, &error) as Data? else {
            // Consumed exactly once (balancing the Create rule's +1 retain), never stored, never
            // escaped — the invariant the R9 allowlist entry for this file names.
            if let cfError = error?.takeRetainedValue() {
                let code = OSStatus(truncatingIfNeeded: CFErrorGetCode(cfError))
                if transientDecryptStatuses.contains(code) { return .unavailable(code) }
            }
            return .blobRejected
        }
        return .recovered(data)
    }

    /// The `SecKeyCreateDecryptedData` failure statuses that mean "the keychain/enclave would not
    /// answer right now", never "this key will not open this blob" — the transient half of
    /// ``UnwrapOutcome``.
    private static let transientDecryptStatuses: Set<OSStatus> = [
        errSecInteractionNotAllowed,
        errSecNotAvailable,
        errSecAuthFailed,
        errSecUserCanceled
    ]

    /// Deletes this service's SE key. Called from `FernletLockService.reset()` — the wrapped
    /// blob is a generic password swept by the service-wide delete, but the `kSecClassKey`
    /// enclave key lives outside that sweep and must be removed explicitly.
    ///
    /// - Returns: The raw `SecItemDelete` status. This deletion is what the "crypto-erased" claim
    ///   of `reset()` and the duress wipe rests on, so the status is RETURNED rather than dropped:
    ///   anything other than `errSecSuccess`/`errSecItemNotFound` means the enclave key may still
    ///   be alive, and the caller (which owns the audit log) records it.
    static func deleteKey(service: String) -> OSStatus {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag(forService: service),
            kSecUseDataProtectionKeychain as String: true
        ]
        return SecItemDelete(query as CFDictionary)
    }

    /// Loads this service's persisted SE key reference, or `nil` when none exists **or the read
    /// failed** — the collapse ``loadKeyResult(service:)`` avoids.
    static func loadKey(service: String) -> SecKey? {
        guard case .loaded(let key) = loadKeyResult(service: service) else { return nil }
        return key
    }

    /// The three-way result of reading the enclave key, mirroring `KeychainItem.ReadResult` for
    /// the `kSecClassKey` row that lives outside the generic-password helpers.
    enum KeyLoadOutcome {
        /// The key exists and was returned.
        case loaded(SecKey)
        /// No such key (`errSecItemNotFound`) — it was destroyed, or never created.
        case absent
        /// The read failed for any other reason; the key's existence is unknown.
        case unreadable(OSStatus)
    }

    /// Loads this service's persisted SE key reference, propagating the failing `OSStatus` so a
    /// caller can tell `errSecItemNotFound` (the key is gone) from every other status (the
    /// keychain would not answer). A success that hands back a non-`SecKey` is reported as
    /// unreadable (`errSecInternalError`) rather than as an absence.
    static func loadKeyResult(service: String) -> KeyLoadOutcome {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag(forService: service),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .absent }
        guard status == errSecSuccess else { return .unreadable(status) }
        // The CFGetTypeID compare IS the assertion (a pattern cast to a CoreFoundation type is
        // unchecked at runtime, and `as?` would only earn an "always succeeds" warning); folding
        // the cast into the same guard keeps the check and drops the trap (R5).
        guard let result, CFGetTypeID(result) == SecKeyGetTypeID(), case let key as SecKey = result else {
            return .unreadable(errSecInternalError)
        }
        return .loaded(key)
    }

    /// Loads the SE key, creating (permanent, enclave-resident, `.privateKeyUsage`-gated,
    /// `WhenUnlockedThisDeviceOnly`) on first use. `nil` when the enclave is unavailable or
    /// creation fails — callers fall back to scrypt-only behavior.
    private static func loadOrCreateKey(service: String) -> SecKey? {
        if let existing = loadKey(service: service) { return existing }
        // No CFError out-parameter (R9): the guard on the nil return IS the recovery, and this file
        // has no logger that could consume the error anyway.
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            nil
        ) else { return nil }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrTokenID as String: kSecAttrTokenIDSecureEnclave,
            kSecUseDataProtectionKeychain as String: true,
            kSecPrivateKeyAttrs as String: [
                kSecAttrIsPermanent as String: true,
                kSecAttrApplicationTag as String: keyTag(forService: service),
                kSecAttrAccessControl as String: access
            ]
        ]
        // Same as above: callers treat nil as "no enclave key — stay legacy", so the error has no
        // consumer and passing it would only leak it (R9).
        return SecKeyCreateRandomKey(attributes as CFDictionary, nil)
    }
}
