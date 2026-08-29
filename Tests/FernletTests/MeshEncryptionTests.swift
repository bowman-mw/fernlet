// MeshEncryptionTests.swift
// FernletTests
//
// Unit tests for Phase 3 group symmetric encryption (§17.13).

@testable import ProximityKit
import Foundation
import Testing
import CryptoKit
import MultipeerConnectivity
import FernletCrypto
import FernletFoundation
#if canImport(UIKit)
import UIKit
import FernletDomainModel
import PrivateMediaStore
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
        // `FMGP2` (5) + plaintext length + 16-byte GCM tag. The marker selects the typed AEAD
        // purpose rather than overloading the unauthenticated nonce field beside it.
        #expect(ciphertext.count == 5 + original.count + 16)
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
        // Flip a bit INSIDE the sealed body, past the 5-byte `FMGP2` marker. Flipping byte 0
        // corrupts the marker instead, which is now refused as a retired wire format before the
        // AEAD is consulted at all — this test is about the tag, so it has to reach the tag.
        ciphertext[ciphertext.startIndex + 5] ^= 0xFF

        // The AEAD tag itself rejects this, so the error is CryptoKit's, not ours.
        #expect(throws: (any Error).self) {
            _ = try MeshNetworkManager.decryptPhoto(ciphertext, nonce: nonce, key: key)
        }
    }

    // MARK: - Phase 4: the retired (pre-marker) wire formats are refused BY NAME

    /// The pre-`FMGP2` photo was opened with no AAD at all until the crypto standardization round's
    /// Phase 4 deleted that reader. A peer still sending it must fail explicably — the mesh drops
    /// photos silently, so an unnameable failure here is indistinguishable from a corrupt image.
    @Test func photoDecryptRefusesUnmarkedLegacyBytesByName() throws {
        let key = makeGroupKey()
        let (ciphertext, nonce) = try MeshNetworkManager.encryptPhoto(Data("legacy".utf8), key: key)
        let unmarked = Data(ciphertext.dropFirst(5))   // strip `FMGP2`: the pre-marker layout

        #expect(throws: MeshEncryptionError.legacyWireFormat) {
            _ = try MeshNetworkManager.decryptPhoto(unmarked, nonce: nonce, key: key)
        }
    }

    /// The 92-byte group-key wrap is the ONE thing that separates an older peer's bundle from
    /// garbage, so the length stays recognised even though the open path is gone: a refusal that
    /// cannot classify cannot explain itself.
    @Test func groupKeyUnwrapRefusesLegacy92ByteBundleByName() throws {
        let sender = makeIdentity()
        let recipient = makeIdentity()

        let bundle = try sender.encryptGroupKey(makeRandomBytes(), for: recipient.localKeyAgreementPublicKey)
        let legacy = Data(bundle.dropFirst(4))         // strip `FGK2`: the pre-marker 92-byte layout
        #expect(legacy.count == 92)

        #expect(throws: IdentityError.legacyWireFormat) {
            _ = try recipient.decryptGroupKey(legacy)
        }
        // A length that is neither 96-with-marker nor the legacy 92 is malformed, not old.
        #expect(throws: IdentityError.openFailed) {
            _ = try recipient.decryptGroupKey(Data(bundle.dropFirst(5)))
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
        let store = PrivateMediaStore(
            indexURL: directoryURL.appendingPathComponent("MeshPhotoCache.json"),
            keyProvider: InMemoryPrivateMediaKeyProvider()
        )
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
        #expect(bundle.count == 96, "Bundle must be `FGK2` (4) + 32 + 12 + 32 + 16 = 96 bytes")

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

    // MARK: - Phase 4: the `FMGM2` metadata refusal

    /// The audit event that is written for a metadata wrapper refused at the marker guard, and
    /// deliberately NOT written for one the AEAD rejected. A frozen English token, not display text.
    private static let droppedLegacyMetadata = "mesh.encryptedMetadata.droppedLegacyWireFormat"

    /// The fourth Phase-4 wire refusal, and the only one with no reachable caller: `decryptPayload`
    /// is `private`, so its three siblings above can be asserted by throwing `MeshEncryptionError`
    /// while this one can only be read through what `handleEncryptedMetadata` records. That is not a
    /// weaker test — the guard's whole functional value IS the nameable audit line (unmarked bytes
    /// would fail the AEAD and be dropped either way), so this asserts the thing that would actually
    /// be lost, and it covers the named catch as well as the guard.
    ///
    /// Both wrappers carry the SAME sealed bytes under the SAME group key. One has a byte flipped
    /// inside the sealed body — past `FMGM2`, so it reaches the AEAD and dies on the tag, which is
    /// the near-miss this suite has been bitten by before (see `photoDecryptFailsWithTamperedCiphertext`).
    /// The other has the 5-byte marker stripped, which is exactly the pre-Phase-4 layout. Exactly
    /// one named drop may come out: zero if the marker guard were dropped (the unmarked bytes would
    /// then die in the AEAD like any other undecryptable wrapper) or if the named catch were folded
    /// back into the silent one, and two if the named catch ever widened to cover every failure.
    @Test func encryptedMetadataRefusesUnmarkedLegacyBytesWithItsOwnAuditLine() async throws {
        let store = makeTestStore()
        defer { withExtendedLifetime(store) {} }   // `MeshNetworkManager.store` is `unowned`
        let manager = MeshNetworkManager(store: store)
        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(coordinator: coordinator,
                                  peer: meshPeer(name: "Member"),
                                  fingerprint: "fp-member")
        let keyBytes = makeRandomBytes()
        try joinMesh(manager, on: coordinator, admitter: makeIdentity(), keyBytes: keyBytes, epoch: 5)
        let groupKey = try #require(manager.currentGroupKey)
        #expect(groupKey.epoch == 5 && groupKey.keyBytes == keyBytes,
                "precondition: the join flow installed the key both wrappers below are sealed under")

        let capture = MeshMetadataAuditCapture()
        capture.install()
        defer { capture.uninstall() }

        // A genuine inner payload, so the marked wrapper is well-formed in every respect except the
        // one byte flipped below — and long enough that stripping the marker still clears
        // `decryptPayload`'s length guard, leaving the marker as the only thing that can refuse it.
        let inner = try JSONEncoder().encode(
            EncryptedMetadataInner(payloadType: PayloadType.friendPhotoManifest.rawValue, payload: Data()))
        let (marked, nonce) = try sealMetadata(inner, keyBytes: keyBytes)
        var tampered = marked
        tampered[tampered.startIndex + 5] ^= 0xFF   // past `FMGM2`: these bytes reach the tag
        try deliverMetadata(tampered, nonce: nonce, epoch: 5, to: manager, on: coordinator)
        try deliverMetadata(Data(marked.dropFirst(5)), nonce: nonce, epoch: 5,
                            to: manager, on: coordinator)

        await waitUntil { capture.count(Self.droppedLegacyMetadata) > 0 }
        // The two handlers run as separate tasks; let the queue drain before counting so a stray
        // second event cannot slip in after the assertion.
        for _ in 0..<20 { await Task.yield() }
        #expect(capture.count(Self.droppedLegacyMetadata) == 1,
                "Only the unmarked wrapper is a retired wire format — a tampered marked one is not")
    }

    // MARK: - Encrypted-metadata fixtures

    /// Builds current (`FMGM2`-marked) metadata bytes by hand, because `encryptPayload` is `private`.
    /// The spelling must track `MeshNetworkManager.encryptPayload`: marker, then AES-256-GCM under
    /// the group key with the typed metadata AEAD purpose, ciphertext followed by tag, nonce carried
    /// beside it. If it drifts the marked wrapper stops reaching the AEAD and the control goes
    /// vacuous — which is why the test asserts exactly one refusal rather than at least one.
    private func sealMetadata(_ inner: Data, keyBytes: Data) throws -> (ciphertext: Data, nonce: Data) {
        let box = try AES.GCM.seal(
            inner,
            using: SymmetricKey(data: keyBytes),
            nonce: AES.GCM.Nonce(),
            authenticating: FernletCryptoPurpose.AEAD.meshEncryptedMetadataV2.data
        )
        var ciphertext = Data("FMGM2".utf8) + box.ciphertext
        ciphertext.append(box.tag)
        return (ciphertext, Data(box.nonce))
    }

    /// Hands the manager a `.meshEncryptedMetadata` envelope on a committed slot — the same public
    /// entry point a verified peer's wrapper arrives through.
    private func deliverMetadata(
        _ ciphertext: Data,
        nonce: Data,
        epoch: Int,
        to manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator
    ) throws {
        let wrapper = MeshEncryptedMetadataPayload(ciphertext: ciphertext, nonce: nonce, keyEpoch: epoch)
        let plaintext = try JSONEncoder().encode(wrapper)
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(.meshEncryptedMetadata, plaintext: plaintext),
                                     plaintext: plaintext,
                                     from: nil)
    }

    /// Drives the real descriptor → request → grant join flow so the manager ends up holding
    /// `keyBytes` at `epoch`. `currentGroupKey` is `private(set)` and every mint site is private, so
    /// the join flow is the only way to give the encrypted-metadata seam a key to work with.
    private func joinMesh(
        _ manager: MeshNetworkManager,
        on coordinator: ProximityCoordinator,
        admitter: IdentityService,
        keyBytes: Data,
        epoch: Int
    ) throws {
        let now = Date()
        let member = MeshMember(
            fingerprint: IdentityService.fingerprint(of: admitter.localSigningPublicKey),
            displayName: "Admitter",
            signingPublicKey: admitter.localSigningPublicKey,
            keyAgreementPublicKey: admitter.localKeyAgreementPublicKey,
            joinedAt: now)
        let mesh = MeshDescriptor(meshID: UUID(), name: "Metadata", mode: .open, members: [member],
                                  nameSetAt: now, nameSetBy: member.fingerprint,
                                  modeSetAt: now, modeSetBy: member.fingerprint, createdAt: now)
        let descriptor = try JSONEncoder().encode(MeshStateChangePayload(descriptor: mesh))
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(.meshDescriptor, plaintext: descriptor),
                                     plaintext: descriptor, from: nil)
        let token = try MeshAdmissionToken.signed(meshID: mesh.meshID,
                                                  joinerFingerprint: manager.localFingerprint,
                                                  joinerSigningPublicKey: manager.localSigningPublicKey,
                                                  admitterIdentity: admitter)
        let grant = MeshAdmissionGrantPayload(
            meshID: mesh.meshID,
            requesterFingerprint: manager.localFingerprint,
            token: token,
            encryptedCurrentKey: try admitter.encryptGroupKey(keyBytes, for: manager.localKeyAgreementPublicKey),
            currentKeyEpoch: epoch)
        let grantData = try JSONEncoder().encode(grant)
        manager.proximityCoordinator(coordinator,
                                     didReceive: inboundEnvelope(.meshAdmissionGrant, plaintext: grantData),
                                     plaintext: grantData, from: peerIdentity(for: admitter))
    }

    /// A coordinator the manager only ever identity-compares against its slots. Deliberately not
    /// provisioned: its init never touches the keychain, and provisioning would orphan keys under a
    /// never-reused UUID service on every run.
    private func throwawayCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "com.fernlet.meshenc.slot.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            replayCache: ReplayCache(),
            displayName: "Local",
            timeoutSeconds: 0)
    }

    private func meshPeer(name: String) -> PeerHandle {
        PeerHandle(id: UUID(), displayHint: name, discoveryInfo: nil,
                   advertisedFingerprint: nil)
    }

    private func peerIdentity(for identity: IdentityService) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Admitter",
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: IdentityService.fingerprint(of: identity.localSigningPublicKey),
            rangingMode: .none,
            firstSeenAt: Date())
    }

    /// An inbound envelope shell: `proximityCoordinator(_:didReceive:...)` receives envelopes that
    /// have already been verified, so the key and signature fields are unused here.
    private func inboundEnvelope(_ payloadType: PayloadType, plaintext: Data) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: "Peer",
            recipientFingerprint: nil,
            payloadType: payloadType,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Test"),
            payload: plaintext,
            createdAt: Date(),
            expiresAt: nil,
            signature: Data())
    }

    /// Gives up only once the deadline has passed AND `minimumPolls` observations have really been
    /// made. A wall-clock deadline alone keeps advancing while this `@MainActor` suite is starved in
    /// a loaded full-suite run, so it can expire having looked only a handful of times; counting
    /// observations ties the give-up decision to scheduling received. Terminates either way: `polls`
    /// only climbs and every turn of the loop yields.
    private func waitUntil(
        timeout: Duration = .seconds(3),
        minimumPolls: Int = 400,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// A metadata drop is silent by design — `handleEncryptedMetadata` changes no state and shows the
/// user nothing — so the audit trail is the only place "refused at the marker guard" and "rejected
/// by the AEAD" differ. Locked because ``FernletAuditLog`` invokes handlers on whatever executor
/// logged the event, and removed by token on teardown so it does not outlive the test.
private final class MeshMetadataAuditCapture {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var token: UUID?

    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, _ in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append(event)
            self.lock.unlock()
        }
    }

    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    func count(_ event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.filter { $0 == event }.count
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
