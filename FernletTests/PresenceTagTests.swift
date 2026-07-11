// PresenceTagTests.swift
// FernletTests
//
// Phase 4a (Docs/Proximity-Mesh-Redesign-2026-07-10.md): the static-static X25519 DH presence-tag
// primitive in IdentityService. Pins the load-bearing properties the presence layer stands on:
// MUTUAL derivation (both members of a friend pair derive the SAME tag for a given epoch —
// recognition is mutual-by-construction, which is what makes one-sided friend minting safe),
// pair independence (different pairs derive different tags), epoch rotation (tags change every
// 15-minute window), and the wire size (8 bytes → 12 base64 chars, the TXT-budget unit).
//
// Uses UUID-scoped keychain services + defer cleanup, mirroring IdentityServiceTests, so tests
// never touch the production identity.

import ProximityKit
import Foundation
import FernletFoundation
import Testing
import CryptoKit
import FernletDomainModel
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct PresenceTagTests {

    private func makeProvisionedService() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let svc = IdentityService(keychainService: serviceID)
        try svc.ensureProvisioned()
        return (svc, serviceID)
    }

    private func cleanup(_ serviceID: String) {
        KeychainItem.deleteAll(service: serviceID)
    }

    // MARK: - Mutual recognition

    @Test func bothMembersOfAPairDeriveTheSameTag() throws {
        let (alice, idA) = try makeProvisionedService()
        defer { cleanup(idA) }
        let (bob, idB) = try makeProvisionedService()
        defer { cleanup(idB) }

        let epoch = IdentityService.presenceEpoch(at: Date())
        let aliceTag = try alice.presenceTag(for: bob.localKeyAgreementPublicKey, epoch: epoch)
        let bobTag = try bob.presenceTag(for: alice.localKeyAgreementPublicKey, epoch: epoch)

        #expect(aliceTag == bobTag,
                "Static-static DH is symmetric — a friend pair must derive the SAME tag for the same epoch")
        #expect(aliceTag.count == IdentityService.presenceTagByteCount)
        #expect(IdentityService.presenceTagByteCount >= 8, "Spec floor: tags are >= 8 bytes")
    }

    @Test func pairSecretsAreSymmetricToo() throws {
        let (alice, idA) = try makeProvisionedService()
        defer { cleanup(idA) }
        let (bob, idB) = try makeProvisionedService()
        defer { cleanup(idB) }

        let secretA = try alice.presencePairSecret(with: bob.localKeyAgreementPublicKey)
        let secretB = try bob.presencePairSecret(with: alice.localKeyAgreementPublicKey)
        #expect(secretA.withUnsafeBytes { Data($0) } == secretB.withUnsafeBytes { Data($0) })
    }

    // MARK: - Pair independence

    @Test func differentPairsDeriveDifferentTags() throws {
        let (alice, idA) = try makeProvisionedService()
        defer { cleanup(idA) }
        let (bob, idB) = try makeProvisionedService()
        defer { cleanup(idB) }
        let (carol, idC) = try makeProvisionedService()
        defer { cleanup(idC) }

        let epoch: UInt64 = 1_234_567
        let aliceBob = try alice.presenceTag(for: bob.localKeyAgreementPublicKey, epoch: epoch)
        let aliceCarol = try alice.presenceTag(for: carol.localKeyAgreementPublicKey, epoch: epoch)
        let bobCarol = try bob.presenceTag(for: carol.localKeyAgreementPublicKey, epoch: epoch)

        #expect(aliceBob != aliceCarol, "A tag identifies exactly one pair, never a person")
        #expect(aliceBob != bobCarol)
        #expect(aliceCarol != bobCarol)
    }

    // MARK: - Epoch rotation

    @Test func tagsRotateEveryEpoch() throws {
        let (alice, idA) = try makeProvisionedService()
        defer { cleanup(idA) }
        let (bob, idB) = try makeProvisionedService()
        defer { cleanup(idB) }

        let epoch: UInt64 = 42
        let now = try alice.presenceTag(for: bob.localKeyAgreementPublicKey, epoch: epoch)
        let next = try alice.presenceTag(for: bob.localKeyAgreementPublicKey, epoch: epoch + 1)
        let prev = try alice.presenceTag(for: bob.localKeyAgreementPublicKey, epoch: epoch - 1)

        #expect(now != next)
        #expect(now != prev)
        #expect(next != prev)
        // Determinism: the same epoch always re-derives the same tag.
        #expect(try alice.presenceTag(for: bob.localKeyAgreementPublicKey, epoch: epoch) == now)
    }

    @Test func presenceEpochIs900SecondWindows() {
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let epoch = IdentityService.presenceEpoch(at: base)
        #expect(IdentityService.presenceEpoch(at: base.addingTimeInterval(899)) == epoch,
                "Same 15-minute window → same epoch")
        #expect(IdentityService.presenceEpoch(at: base.addingTimeInterval(900)) == epoch + 1,
                "Next window → next epoch")
        #expect(IdentityService.presenceEpoch(at: Date(timeIntervalSince1970: -5)) == 0,
                "Pre-1970 clocks clamp to epoch 0 rather than trapping on the UInt64 conversion")
    }

    // MARK: - Error paths

    @Test func garbagePeerKeyThrowsInvalidKeyData() throws {
        let (alice, idA) = try makeProvisionedService()
        defer { cleanup(idA) }

        #expect(throws: IdentityError.invalidKeyData) {
            _ = try alice.presenceTag(for: Data([1, 2, 3]), epoch: 1)
        }
    }

    @Test func unprovisionedServiceThrowsNotProvisioned() throws {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        defer { cleanup(serviceID) }
        let svc = IdentityService(keychainService: serviceID)
        let peerKey = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation

        #expect(throws: IdentityError.notProvisioned) {
            _ = try svc.presenceTag(for: peerKey, epoch: 1)
        }
    }

    // MARK: - Domain separation

    @Test func presenceSecretDiffersFromSealingDerivation() throws {
        // The presence salt ("fernlet.presence.tag.v1") is its own domain — a presence tag can
        // never be confused with (or leak) message-sealing key material. Cheap proxy check: the
        // pair secret is not the raw DH output reused by seal()'s derivation, by deriving what
        // seal's salt would have produced and expecting a different key.
        let (alice, idA) = try makeProvisionedService()
        defer { cleanup(idA) }
        let bobPrivate = Curve25519.KeyAgreement.PrivateKey()

        let presenceSecret = try alice.presencePairSecret(with: bobPrivate.publicKey.rawRepresentation)
        let rawShared = try bobPrivate.sharedSecretFromKeyAgreement(
            with: .init(rawRepresentation: alice.localKeyAgreementPublicKey))
        let sealStyle = rawShared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: Data("fernlet.proximity.v1".utf8),
            sharedInfo: Data(),
            outputByteCount: 32
        )
        #expect(presenceSecret.withUnsafeBytes { Data($0) } != sealStyle.withUnsafeBytes { Data($0) })
    }
}
