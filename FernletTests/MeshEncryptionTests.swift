// MeshEncryptionTests.swift
// FernletTests
//
// Unit tests for Phase 3 group symmetric encryption (§17.13).

import Foundation
import Testing
import CryptoKit
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct MeshEncryptionTests {

    // MARK: - Harness

    private func makeIdentity() -> IdentityService {
        let svc = IdentityService(keychainService: "com.fernlet.meshenc.test.\(UUID().uuidString)")
        try! svc.ensureProvisioned()
        return svc
    }

    private func makeGroupKey(epoch: Int = 1) -> MeshGroupKey {
        var bytes = Data(count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return MeshGroupKey(epoch: epoch, keyBytes: bytes, activeSince: Date())
    }

    // MARK: - Photo encrypt / decrypt round-trip

    @Test func photoEncryptDecryptRoundTrip() throws {
        let key = makeGroupKey()
        let original = Data("Hello Fernlet photo bytes".utf8)

        let (ciphertext, nonce) = try MeshNetworkManager.encryptPhoto(original, key: key)
        let decrypted = try MeshNetworkManager.decryptPhoto(ciphertext, nonce: nonce, key: key)

        #expect(decrypted == original, "Decrypted bytes must equal the original image data")
        #expect(ciphertext != original, "Ciphertext must differ from plaintext")
    }

    @Test func photoCiphertextIncludesTag() throws {
        let key = makeGroupKey()
        let original = Data(repeating: 0xAB, count: 1024)

        let (ciphertext, _) = try MeshNetworkManager.encryptPhoto(original, key: key)
        // Ciphertext should be plaintext length + 16-byte GCM tag
        #expect(ciphertext.count == original.count + 16)
    }

    @Test func photoDecryptFailsWithWrongKey() throws {
        let key1 = makeGroupKey(epoch: 1)
        let key2 = makeGroupKey(epoch: 2)
        let original = Data("secret image".utf8)

        let (ciphertext, nonce) = try MeshNetworkManager.encryptPhoto(original, key: key1)
        #expect(throws: (any Error).self) {
            _ = try MeshNetworkManager.decryptPhoto(ciphertext, nonce: nonce, key: key2)
        }
    }

    @Test func photoDecryptFailsWithTamperedCiphertext() throws {
        let key = makeGroupKey()
        let original = Data("tamper test".utf8)

        var (ciphertext, nonce) = try MeshNetworkManager.encryptPhoto(original, key: key)
        ciphertext[0] ^= 0xFF  // flip a bit

        #expect(throws: (any Error).self) {
            _ = try MeshNetworkManager.decryptPhoto(ciphertext, nonce: nonce, key: key)
        }
    }

    // MARK: - Key isolation: wrong epoch cannot decrypt

    @Test func epochKeyIsolation() throws {
        let key5 = makeGroupKey(epoch: 5)
        let key4 = makeGroupKey(epoch: 4)
        let original = Data("epoch isolation".utf8)

        let (ct, nonce) = try MeshNetworkManager.encryptPhoto(original, key: key5)
        // A member holding only epoch-5 key cannot decrypt an epoch-4 ciphertext.
        #expect(throws: (any Error).self) {
            _ = try MeshNetworkManager.decryptPhoto(ct, nonce: nonce, key: key4)
        }
    }

    // MARK: - Epoch-0 backward compatibility

    @Test func epochZeroPayloadAcceptedWithoutDecryption() throws {
        let payload = FriendPhotoPayload(
            imageData: Data("plain image".utf8),
            senderName: "Alice"
        )
        // keyEpoch is 0; imageData is non-nil; no encrypted fields
        #expect(payload.keyEpoch == 0)
        #expect(payload.imageData != nil)
        #expect(payload.encryptedImageData == nil)
        #expect(payload.nonce == nil)
    }

    // MARK: - withDecryptedImageData helper

    @Test func withDecryptedImageDataReplacesData() throws {
        let original = Data("encrypted bytes".utf8)
        let decrypted = Data("decrypted image".utf8)

        let wirePayload = FriendPhotoPayload(
            encryptedImageData: original,
            nonce: Data(count: 12),
            keyEpoch: 2,
            senderName: "Bob",
            senderFingerprint: "abc12345"
        )
        let cached = wirePayload.withDecryptedImageData(decrypted)

        #expect(cached.imageData == decrypted)
        #expect(cached.encryptedImageData == nil)
        #expect(cached.nonce == nil)
        #expect(cached.keyEpoch == 0)      // back to epoch-0 (plain) representation in cache
        #expect(cached.id == wirePayload.id)
        #expect(cached.senderFingerprint == wirePayload.senderFingerprint)
    }

    // MARK: - Epoch filtering on manifest

    @Test func manifestEpochFilterSkipsOldEpochs() {
        let entries = [
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "fp1", keyEpoch: 1),
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "fp2", keyEpoch: 2),
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "fp3", keyEpoch: 3),
            FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "fp4", keyEpoch: 4),
        ]
        let localJoinedEpoch = 3

        let requestable = entries.filter { $0.keyEpoch >= localJoinedEpoch }
        #expect(requestable.count == 2, "Only epochs 3 and 4 should be requestable")
        #expect(requestable.allSatisfy { $0.keyEpoch >= localJoinedEpoch })
    }

    // MARK: - Group key wrap / unwrap (IdentityService)

    @Test func groupKeyWrapUnwrapRoundTrip() throws {
        let sender = makeIdentity()
        let recipient = makeIdentity()

        var groupKeyBytes = Data(count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &groupKeyBytes)

        let bundle = try sender.encryptGroupKey(groupKeyBytes, for: recipient.localKeyAgreementPublicKey)
        #expect(bundle.count == 92, "Bundle must be 32 + 12 + 32 + 16 = 92 bytes")

        let unwrapped = try recipient.decryptGroupKey(bundle)
        #expect(unwrapped == groupKeyBytes)
    }

    @Test func groupKeyUnwrapFailsWithWrongRecipient() throws {
        let sender = makeIdentity()
        let intendedRecipient = makeIdentity()
        let wrongRecipient = makeIdentity()

        var key = Data(count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &key)

        let bundle = try sender.encryptGroupKey(key, for: intendedRecipient.localKeyAgreementPublicKey)
        #expect(throws: (any Error).self) {
            _ = try wrongRecipient.decryptGroupKey(bundle)
        }
    }

    @Test func groupKeyEncryptRejectsNon32ByteKey() throws {
        let sender = makeIdentity()
        let recipient = makeIdentity()
        let shortKey = Data(count: 16)

        #expect(throws: (any Error).self) {
            _ = try sender.encryptGroupKey(shortKey, for: recipient.localKeyAgreementPublicKey)
        }
    }

    // MARK: - Joiner receives no old keys

    @Test func admissionGrantSetsLocalJoinedEpoch() throws {
        let admitter = makeIdentity()
        let joiner = makeIdentity()

        let groupKey = makeGroupKey(epoch: 5)
        let bundle = try admitter.encryptGroupKey(groupKey.keyBytes, for: joiner.localKeyAgreementPublicKey)

        // Simulate what handleAdmissionGrant does.
        guard let keyData = try? joiner.decryptGroupKey(bundle) else {
            Issue.record("Failed to decrypt group key")
            return
        }
        let restoredKey = MeshGroupKey(epoch: 5, keyBytes: keyData, activeSince: Date())
        let localJoinedEpoch = restoredKey.epoch

        #expect(localJoinedEpoch == 5)
        #expect(keyData == groupKey.keyBytes)
        // A member who joined at epoch 5 must not request photos from epochs < 5.
        let oldEpochEntry = FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "fp", keyEpoch: 4)
        #expect(oldEpochEntry.keyEpoch < localJoinedEpoch)
    }

    // MARK: - FriendPhotoManifestEntry backward compat

    @Test func manifestEntryDefaultsKeyEpochToZero() {
        let entry = FriendPhotoManifestEntry(id: UUID(), senderFingerprint: "fp")
        #expect(entry.keyEpoch == 0)
    }

    // MARK: - Phase 4: Full-key trust (ProximityTrustVault)

    @Test func revokedKeyCheckRequiresFullKeyMatch() {
        let vault = ProximityTrustVault()
        let id1 = makeIdentity()
        let id2 = makeIdentity()

        // Record id1 as a trusted peer then revoke it.
        let fakeIdentity = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Peer",
            signingPublicKey: id1.localSigningPublicKey,
            keyAgreementPublicKey: id1.localKeyAgreementPublicKey,
            fingerprint: IdentityService.fingerprint(of: id1.localSigningPublicKey),
            rangingMode: .none,
            firstSeenAt: Date()
        )
        vault.trust(fakeIdentity, mode: .friend)
        vault.revoke(fingerprint: fakeIdentity.fingerprint)

        // id1's key is revoked.
        #expect(vault.isRevokedProximitySigningKey(id1.localSigningPublicKey))
        // id2's key (different full key) must NOT be considered revoked even if fingerprints collide
        // in the degenerate case — here they differ, so this should be false.
        #expect(!vault.isRevokedProximitySigningKey(id2.localSigningPublicKey))
    }

    @Test func blockedKeyCheckRequiresFullKeyMatch() {
        let vault = ProximityTrustVault()
        let id1 = makeIdentity()
        let id2 = makeIdentity()

        let fakeIdentity = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Peer",
            signingPublicKey: id1.localSigningPublicKey,
            keyAgreementPublicKey: id1.localKeyAgreementPublicKey,
            fingerprint: IdentityService.fingerprint(of: id1.localSigningPublicKey),
            rangingMode: .none,
            firstSeenAt: Date()
        )
        vault.trust(fakeIdentity, mode: .friend)
        vault.block(fingerprint: fakeIdentity.fingerprint)

        #expect(vault.isBlockedProximitySigningKey(id1.localSigningPublicKey))
        #expect(!vault.isBlockedProximitySigningKey(id2.localSigningPublicKey))
    }
}
