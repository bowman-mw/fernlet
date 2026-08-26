// ProximityWireOffMainDecodeTests.swift
// FernletTests
//
// WI-9 regression suite. ProximityKit declares `.defaultIsolation(MainActor.self)`, which would
// otherwise MainActor-isolate the proximity wire value types (and their synthesized `Codable`
// conformances), the canonical signing serializer, and the pure `IdentityService` crypto statics —
// pinning decode + signature verification of untrusted MCSession bytes to the main actor and forcing
// reliance on the `.swiftLanguageMode(.v5)` escape hatch. WI-9 marks all of those `nonisolated`
// (+ `Sendable`).
//
// These tests lock that in two ways:
//   1. Compile-time: a `T: Sendable` constraint over the wire types. If any regresses to non-Sendable
//      this file fails to compile in ANY language mode (generic-constraint satisfaction is checked
//      regardless of strict concurrency).
//   2. Runtime: each test signs on the `@MainActor` IdentityService, then decodes + verifies the bytes
//      inside a `Task.detached` — a genuinely off-main, nonisolated execution context. The detached
//      bodies decode the wire type, recompute its canonical bytes, and check the Ed25519 signature off
//      the main actor; under Swift 6 / CI they would fail to compile if those APIs regressed to
//      MainActor isolation, and at runtime they prove the off-main path produces correct results with
//      no shared-state data race.

import ProximityKit
import Foundation
import FernletCrypto
import FernletFoundation
import Testing
import FernletDomainModel
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct ProximityWireOffMainDecodeTests {

    // MARK: - Harness

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.identity.wi9.\(UUID().uuidString)"
        let svc = IdentityService(keychainService: id)
        try svc.ensureProvisioned()
        return (svc, id)
    }

    private func cleanup(_ id: String) {
        KeychainItem.deleteAll(service: id)
    }

    // MARK: - Compile-time Sendable guard

    /// Type-level assertion: instantiating this with a non-`Sendable` `T` is a hard compile error.
    private func assertSendable<T: Sendable>(_: T.Type) {}

    /// Exercising this `@Test` is trivially true at runtime; the VALUE is that it only compiles while
    /// every listed wire type stays `Sendable` (the `nonisolated, Sendable` annotations from WI-9).
    @Test func wireTypesRemainSendable() {
        assertSendable(FernletIdentityEnvelope.self)
        assertSendable(MeshAdmissionToken.self)
        assertSendable(MeshAdmissionGrantPayload.self)
        assertSendable(MeshDescriptor.self)
        assertSendable(MeshMember.self)
        assertSendable(MeshStateChangePayload.self)
        assertSendable(MeshKeyRotationPayload.self)
        assertSendable(MeshEncryptedMetadataPayload.self)
        assertSendable(ProximityRecipeSharePayload.self)
        assertSendable(ProximitySharedRecipe.self)
        assertSendable(SharedSavedRecipePayload.self)
        assertSendable(SharedRecipePayload.self)
        assertSendable(FriendPhotoPayload.self)
        assertSendable(FriendPhotoManifestPayload.self)
        assertSendable(FriendPhotoRequestPayload.self)
        assertSendable(FriendPhotoSessionMetadata.self)
        #expect(Bool(true))
    }

    // MARK: - Off-main decode + verify

    @Test func envelopeDecodesAndSignatureVerifiesOffMainActor() async throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }

        let env = try FernletIdentityEnvelope.signed(
            identityService: alice,
            senderDisplayName: "Off-main Sender",
            payloadType: .inspectorEcho,
            payloadSummary: PayloadSummary(title: "WI-9"),
            payload: Data("off-main payload".utf8)
        )
        let json = try JSONEncoder().encode(env)        // Sendable Data crosses into the detached task
        let signerKey = alice.localSigningPublicKey      // Sendable Data

        // Decode the wire bytes AND re-derive + check the signature entirely off the main actor.
        let verified = await Task.detached { () -> Bool in
            guard let decoded = try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: json) else {
                return false
            }
            let canon = canonicalBytes(for: decoded)
            return IdentityService.verify(
                decoded.signature,
                of: canon,
                by: signerKey,
                purpose: FernletCryptoPurpose.Signature.identityEnvelopeV2
            )
        }.value

        #expect(verified)
    }

    @Test func tamperedEnvelopeFailsSignatureOffMainActor() async throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }

        let env = try FernletIdentityEnvelope.signed(
            identityService: alice,
            senderDisplayName: "Off-main Sender",
            payloadType: .inspectorEcho,
            payloadSummary: PayloadSummary(title: "WI-9"),
            payload: Data("off-main payload".utf8)
        )
        // Flip a canonical-covered field (display name) while keeping the original signature.
        let tampered = FernletIdentityEnvelope(
            schemaVersion: env.schemaVersion,
            envelopeID: env.envelopeID,
            senderSigningPublicKey: env.senderSigningPublicKey,
            senderKeyAgreementPublicKey: env.senderKeyAgreementPublicKey,
            senderDisplayName: env.senderDisplayName + "!",
            recipientFingerprint: env.recipientFingerprint,
            payloadTypeToken: env.payloadTypeToken,
            payloadEncryption: env.payloadEncryption,
            payloadSummary: env.payloadSummary,
            payload: env.payload,
            createdAt: env.createdAt,
            expiresAt: env.expiresAt,
            signature: env.signature
        )
        let json = try JSONEncoder().encode(tampered)
        let signerKey = alice.localSigningPublicKey

        let verified = await Task.detached { () -> Bool in
            guard let decoded = try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: json) else {
                return false
            }
            return IdentityService.verify(
                decoded.signature,
                of: canonicalBytes(for: decoded),
                by: signerKey,
                purpose: FernletCryptoPurpose.Signature.identityEnvelopeV2
            )
        }.value

        #expect(verified == false)
    }

    @Test func meshAdmissionTokenVerifiesOffMainActor() async throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }

        let meshID = UUID(uuidString: "00000000-0000-0000-0000-0000000000d9")!
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let token = try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt,
            expiresAt: grantedAt.addingTimeInterval(3600)
        )
        let joinerKey = joiner.localSigningPublicKey
        let admitterKey = admitter.localSigningPublicKey
        let now = grantedAt.addingTimeInterval(60)

        // `MeshAdmissionToken.verify` is `nonisolated` (pure signature math) — call it off the main actor.
        let result = await Task.detached { () -> Bool in
            do {
                try token.verify(joinerSigningPublicKey: joinerKey, expectedMeshID: meshID,
                                 expectedAdmitterSigningPublicKey: admitterKey, now: now)
                return true
            } catch {
                return false
            }
        }.value

        #expect(result)
    }

    @Test func tamperedMeshAdmissionTokenFailsVerifyOffMainActor() async throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }

        let meshID = UUID(uuidString: "00000000-0000-0000-0000-0000000000da")!
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let token = try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt,
            expiresAt: grantedAt.addingTimeInterval(3600)
        )
        // Tamper `grantedAt` (a signed canonical field), keeping the original signature.
        let tampered = MeshAdmissionToken(
            meshID: token.meshID,
            joinerFingerprint: token.joinerFingerprint,
            joinerSigningPublicKey: token.joinerSigningPublicKey,
            admitterFingerprint: token.admitterFingerprint,
            grantedAt: token.grantedAt.addingTimeInterval(1),
            expiresAt: token.expiresAt,
            admitterSigningPublicKey: token.admitterSigningPublicKey,
            admitterSignature: token.admitterSignature
        )
        let joinerKey = joiner.localSigningPublicKey
        let admitterKey = admitter.localSigningPublicKey
        let now = grantedAt.addingTimeInterval(60)

        let threwSignatureInvalid = await Task.detached { () -> Bool in
            do {
                try tampered.verify(joinerSigningPublicKey: joinerKey, expectedMeshID: meshID,
                                    expectedAdmitterSigningPublicKey: admitterKey, now: now)
                return false
            } catch let error as MeshAdmissionToken.VerifyError {
                return error == .signatureInvalid
            } catch {
                return false
            }
        }.value

        #expect(threwSignatureInvalid)
    }
}
