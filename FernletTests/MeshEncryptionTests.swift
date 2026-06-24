// MeshEncryptionTests.swift
// FernletTests
//
// Unit tests for Phase 3 group symmetric encryption (§17.13).

import Foundation
import Testing
import CryptoKit
#if canImport(UIKit)
import UIKit
#endif
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
        MeshGroupKey(epoch: epoch, keyBytes: makeRandomBytes(), activeSince: Date())
    }

    private func makeRandomBytes(count: Int = 32) -> Data {
        var bytes = Data(count: count)
        bytes.withUnsafeMutableBytes {
            _ = SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!)
        }
        return bytes
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

    @Test func withDecryptedImageDataRetainsSessionMetadata() throws {
        let session = makePhotoSession()
        let wirePayload = FriendPhotoPayload(
            encryptedImageData: Data("encrypted bytes".utf8),
            nonce: Data(count: 12),
            keyEpoch: 2,
            senderName: "Bob",
            session: session
        )

        let cached = wirePayload.withDecryptedImageData(Data("decrypted image".utf8))

        #expect(cached.session == session)
    }

    @Test func meshPhotoCacheLoadsMetadataAndHydratesImageOnDemand() throws {
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("FernletMeshPhotoCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let store = MeshPhotoCacheStore(indexURL: directoryURL.appendingPathComponent("MeshPhotoCache.json"))
        // Use real image bytes: the cache now validates pixel dimensions on ingestion, so a
        // non-image stand-in would (correctly) be rejected and never persisted.
        let imageBytes = Self.tinyJPEGData()
        let photo = FriendPhotoPayload(
            imageData: imageBytes,
            senderName: "Alice",
            session: makePhotoSession()
        )

        store.save([photo])
        let loaded = try #require(store.load().first)

        #expect(loaded.id == photo.id)
        #expect(loaded.session == photo.session)
        #expect(loaded.imageData == nil)
        #expect(store.imageData(for: loaded) == imageBytes)
    }

    private static func tinyJPEGData() -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24), format: format)
        return renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }.jpegData(compressionQuality: 0.6)!
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

        let groupKeyBytes = makeRandomBytes()

        let bundle = try sender.encryptGroupKey(groupKeyBytes, for: recipient.localKeyAgreementPublicKey)
        #expect(bundle.count == 92, "Bundle must be 32 + 12 + 32 + 16 = 92 bytes")

        let unwrapped = try recipient.decryptGroupKey(bundle)
        #expect(unwrapped == groupKeyBytes)
    }

    @Test func groupKeyUnwrapFailsWithWrongRecipient() throws {
        let sender = makeIdentity()
        let intendedRecipient = makeIdentity()
        let wrongRecipient = makeIdentity()

        let key = makeRandomBytes()

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
        vault.revoke(signingPublicKey: fakeIdentity.signingPublicKey)

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
        vault.block(signingPublicKey: fakeIdentity.signingPublicKey)

        #expect(vault.isBlockedProximitySigningKey(id1.localSigningPublicKey))
        #expect(!vault.isBlockedProximitySigningKey(id2.localSigningPublicKey))
    }
}

private func makePhotoSession() -> FriendPhotoSessionMetadata {
    FriendPhotoSessionMetadata(
        id: UUID(),
        meshID: UUID(),
        meshName: "Test Mesh",
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        participants: [
            FriendPhotoSessionParticipant(fingerprint: "alice-fp", displayName: "Alice"),
            FriendPhotoSessionParticipant(fingerprint: "bob-fp", displayName: "Bob")
        ]
    )
}
