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
/// round-trip check) on every successful configure and unlock. The wrap's standing depends on the
/// service's two custody states — this type is deliberately unaware of which one is in force:
/// - **LEGACY** (scrypt item present, or no enclave at all): additive. Every operation fails soft
///   to `nil`, and behavior degrades to exactly the pre-existing scrypt path — nothing here may
///   block an unlock.
/// - **HARD-BOUND** (scrypt item deleted after this wrap proved a round-trip): authoritative.
///   ``unwrap(_:service:)`` returning `nil` then means the content key is gone for good, which
///   the service surfaces as `FernletLockError.contentKeyUnrecoverable` rather than as a
///   fallback. Deleting the scrypt item is the service's decision, made only against a freshly
///   re-read blob that this type demonstrably opens.
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
        var error: Unmanaged<CFError>?
        guard let wrapped = SecKeyCreateEncryptedData(publicKey, algorithm, contentKey as CFData, &error) as Data? else {
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
    /// - Returns: The recovered content-key bytes, or `nil` when the enclave/key is unavailable
    ///   or the blob does not authenticate (tampered, or wrapped under a different SE key —
    ///   e.g. after an Erase All Content and Settings destroyed the original).
    static func unwrap(_ blob: Data, service: String) -> Data? {
        guard let privateKey = loadKey(service: service),
              SecKeyIsAlgorithmSupported(privateKey, .decrypt, algorithm) else { return nil }
        var error: Unmanaged<CFError>?
        return SecKeyCreateDecryptedData(privateKey, algorithm, blob as CFData, &error) as Data?
    }

    /// Deletes this service's SE key. Called from `FernletLockService.reset()` — the wrapped
    /// blob is a generic password swept by the service-wide delete, but the `kSecClassKey`
    /// enclave key lives outside that sweep and must be removed explicitly.
    static func deleteKey(service: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag(forService: service),
            kSecUseDataProtectionKeychain as String: true
        ]
        SecItemDelete(query as CFDictionary)
    }

    /// Loads this service's persisted SE key reference, or `nil` when none exists.
    static func loadKey(service: String) -> SecKey? {
        var result: AnyObject?
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: keyTag(forService: service),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
            kSecUseDataProtectionKeychain as String: true
        ]
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let result, CFGetTypeID(result) == SecKeyGetTypeID() else { return nil }
        // Type-checked via CFGetTypeID above; `as?` cannot dynamically verify CF types.
        return (result as! SecKey)
    }

    /// Loads the SE key, creating (permanent, enclave-resident, `.privateKeyUsage`-gated,
    /// `WhenUnlockedThisDeviceOnly`) on first use. `nil` when the enclave is unavailable or
    /// creation fails — callers fall back to scrypt-only behavior.
    private static func loadOrCreateKey(service: String) -> SecKey? {
        if let existing = loadKey(service: service) { return existing }
        var accessError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            kCFAllocatorDefault,
            kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
            .privateKeyUsage,
            &accessError
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
        var createError: Unmanaged<CFError>?
        return SecKeyCreateRandomKey(attributes as CFDictionary, &createError)
    }
}
