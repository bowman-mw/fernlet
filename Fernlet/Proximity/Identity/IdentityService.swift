// IdentityService.swift
// Fernlet/Proximity
//
// Per-device Ed25519 signing identity + X25519 key-agreement for proximity sessions.
// Keys use AfterFirstUnlockThisDeviceOnly so sessions survive screen-off during workouts.

import Foundation
import CryptoKit
import Security

// MARK: - Keychain key identifiers

private enum IdentityKeychainKey: String {
    case signingPrivateKey          = "signingPrivateKey"
    case keyAgreementPrivateKey     = "keyAgreementPrivateKey"
    case signingPublicKeyCache      = "signingPublicKeyCache"
    case keyAgreementPublicKeyCache = "keyAgreementPublicKeyCache"
}

// MARK: - Errors

enum IdentityError: Error, Equatable {
    case notProvisioned
    case invalidKeyData
    case sealFailed
    case openFailed
}

// MARK: - IdentityService

@MainActor
final class IdentityService {

    let keychainService: String

    private var signingKey: Curve25519.Signing.PrivateKey?
    private var keyAgreementKey: Curve25519.KeyAgreement.PrivateKey?

    init(keychainService: String = "com.fernlet.identity") {
        self.keychainService = keychainService
    }

    // MARK: - Public surface

    var localFingerprint: String {
        guard let key = signingKey else { return "" }
        return Self.fingerprint(of: key.publicKey.rawRepresentation)
    }

    var localSigningPublicKey: Data {
        signingKey?.publicKey.rawRepresentation ?? Data()
    }

    var localKeyAgreementPublicKey: Data {
        keyAgreementKey?.publicKey.rawRepresentation ?? Data()
    }

    func sign(_ data: Data) throws -> Data {
        guard let key = signingKey else { throw IdentityError.notProvisioned }
        return try key.signature(for: data)
    }

    static func verify(_ signature: Data, of data: Data, by publicKeyData: Data) -> Bool {
        guard let publicKey = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKeyData) else { return false }
        return publicKey.isValidSignature(signature, for: data)
    }

    /// X25519 ECDH → HKDF-SHA256 → ChaCha20-Poly1305 seal with forward secrecy.
    /// Wire form: ephemeralPubKey (32 B) || sealedBox.combined (nonce 12 B || ciphertext || tag 16 B).
    func seal(_ plaintext: Data, to peerKeyAgreementPublicKey: Data) throws -> Data {
        guard let senderKey = keyAgreementKey else { throw IdentityError.notProvisioned }
        guard let peerPubKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerKeyAgreementPublicKey) else {
            throw IdentityError.sealFailed
        }

        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: peerPubKey)
        let symKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("fernlet.proximity.v1".utf8),
            sharedInfo: senderKey.publicKey.rawRepresentation + peerKeyAgreementPublicKey,
            outputByteCount: 32
        )

        let sealedBox = try ChaChaPoly.seal(
            plaintext,
            using: symKey,
            authenticating: senderKey.publicKey.rawRepresentation
        )
        return ephemeralKey.publicKey.rawRepresentation + sealedBox.combined
    }

    /// Inverse of seal. `peerKeyAgreementPublicKey` is the sender's long-term X25519 public key.
    func open(_ ciphertext: Data, from peerKeyAgreementPublicKey: Data) throws -> Data {
        guard let recipientKey = keyAgreementKey else { throw IdentityError.notProvisioned }
        // Wire format: eskPub (32 B) || combined (nonce 12 B || ciphertext || tag 16 B)
        guard ciphertext.count >= 32 + 12 + 16 else { throw IdentityError.openFailed }

        let eskPubData = ciphertext.prefix(32)
        let combined = ciphertext.dropFirst(32)

        guard let ephemeralPeerPubKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: eskPubData) else {
            throw IdentityError.openFailed
        }
        let sharedSecret = try recipientKey.sharedSecretFromKeyAgreement(with: ephemeralPeerPubKey)
        let symKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("fernlet.proximity.v1".utf8),
            sharedInfo: peerKeyAgreementPublicKey + recipientKey.publicKey.rawRepresentation,
            outputByteCount: 32
        )

        do {
            let sealedBox = try ChaChaPoly.SealedBox(combined: combined)
            return try ChaChaPoly.open(sealedBox, using: symKey, authenticating: peerKeyAgreementPublicKey)
        } catch {
            throw IdentityError.openFailed
        }
    }

    // MARK: - Group key distribution (Phase 3)

    /// Wraps a 32-byte group key for one recipient using ephemeral X25519 ECDH → HKDF-SHA256 → AES-256-GCM.
    /// Wire form: ephemeralPubKey (32 B) || nonce (12 B) || ciphertext (32 B) || tag (16 B) = 92 B total.
    func encryptGroupKey(_ key: Data, for recipientPublicKey: Data) throws -> Data {
        guard key.count == 32 else { throw IdentityError.sealFailed }
        guard let recipientKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: recipientPublicKey) else {
            throw IdentityError.sealFailed
        }
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let sharedSecret = try ephemeralKey.sharedSecretFromKeyAgreement(with: recipientKey)
        let symKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("fernlet.mesh.groupkey.v1".utf8),
            sharedInfo: ephemeralKey.publicKey.rawRepresentation + recipientPublicKey,
            outputByteCount: 32
        )
        let gcmNonce = AES.GCM.Nonce()
        let sealedBox = try AES.GCM.seal(key, using: symKey, nonce: gcmNonce)

        var bundle = Data()
        bundle.append(ephemeralKey.publicKey.rawRepresentation)          // 32 B
        gcmNonce.withUnsafeBytes { bundle.append(contentsOf: $0) }      // 12 B
        bundle.append(sealedBox.ciphertext)                              // 32 B
        bundle.append(sealedBox.tag)                                     // 16 B
        return bundle
    }

    /// Unwraps a group key bundle produced by `encryptGroupKey`.
    func decryptGroupKey(_ bundle: Data) throws -> Data {
        guard let recipientKey = keyAgreementKey else { throw IdentityError.notProvisioned }
        guard bundle.count == 92 else { throw IdentityError.openFailed }

        let ephPubData     = bundle[bundle.startIndex ..< bundle.startIndex + 32]
        let nonceData      = bundle[bundle.startIndex + 32 ..< bundle.startIndex + 44]
        let ciphertextData = bundle[bundle.startIndex + 44 ..< bundle.startIndex + 76]
        let tagData        = bundle[bundle.startIndex + 76 ..< bundle.startIndex + 92]

        guard let ephemeralPubKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: ephPubData) else {
            throw IdentityError.openFailed
        }
        let sharedSecret = try recipientKey.sharedSecretFromKeyAgreement(with: ephemeralPubKey)
        let recipientPublicKey = recipientKey.publicKey.rawRepresentation
        let symKey = sharedSecret.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("fernlet.mesh.groupkey.v1".utf8),
            sharedInfo: Data(ephPubData) + recipientPublicKey,
            outputByteCount: 32
        )

        do {
            let nonce = try AES.GCM.Nonce(data: nonceData)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ciphertextData, tag: tagData)
            return try AES.GCM.open(sealedBox, using: symKey)
        } catch {
            throw IdentityError.openFailed
        }
    }

    // MARK: - Provisioning

    /// Bootstrap on first launch. Idempotent — returns the existing identity if already provisioned.
    func ensureProvisioned() throws {
        if signingKey != nil && keyAgreementKey != nil { return }

        if let sigData = KeychainItem.load(account: IdentityKeychainKey.signingPrivateKey.rawValue, service: keychainService),
           let kaData = KeychainItem.load(account: IdentityKeychainKey.keyAgreementPrivateKey.rawValue, service: keychainService),
           let loadedSigning = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigData),
           let loadedKA = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: kaData) {
            signingKey = loadedSigning
            keyAgreementKey = loadedKA
            return
        }

        let newSigningKey = Curve25519.Signing.PrivateKey()
        let newKAKey = Curve25519.KeyAgreement.PrivateKey()
        let access = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as CFString

        KeychainItem.store(newSigningKey.rawRepresentation,
                           account: IdentityKeychainKey.signingPrivateKey.rawValue,
                           service: keychainService, accessibility: access)
        KeychainItem.store(newKAKey.rawRepresentation,
                           account: IdentityKeychainKey.keyAgreementPrivateKey.rawValue,
                           service: keychainService, accessibility: access)
        KeychainItem.store(newSigningKey.publicKey.rawRepresentation,
                           account: IdentityKeychainKey.signingPublicKeyCache.rawValue,
                           service: keychainService, accessibility: access)
        KeychainItem.store(newKAKey.publicKey.rawRepresentation,
                           account: IdentityKeychainKey.keyAgreementPublicKeyCache.rawValue,
                           service: keychainService, accessibility: access)

        signingKey = newSigningKey
        keyAgreementKey = newKAKey
    }

    /// Wipes identity. Breaks every existing trust relationship.
    func wipe() throws {
        KeychainItem.deleteAll(service: keychainService)
        signingKey = nil
        keyAgreementKey = nil
    }

    /// 8-char lowercase hex prefix of SHA-256(publicKey). Suitable for user-facing display.
    static func fingerprint(of publicKey: Data) -> String {
        let hash = SHA256.hash(data: publicKey)
        let hex = hash.compactMap { String(format: "%02x", $0) }.joined()
        return String(hex.prefix(8))
    }
}
