// FernletIdentityEnvelopeTests.swift
// FernletTests
//
// Tests for FernletIdentityEnvelope, PayloadEncryption, ReplayCache (Phase 7.2).
// Each test uses UUID-scoped Keychain services cleaned up via defer.

import Foundation
import Testing
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct FernletIdentityEnvelopeTests {

    // MARK: - Harness

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.identity.test.\(UUID().uuidString)"
        let svc = IdentityService(keychainService: id)
        try svc.ensureProvisioned()
        return (svc, id)
    }

    private func cleanup(_ id: String) {
        KeychainItem.deleteAll(service: id)
    }

    private func signedEnvelope(
        sender: IdentityService,
        payload: Data = Data("hello".utf8),
        payloadType: PayloadType = .inspectorEcho,
        payloadEncryption: PayloadEncryption = .none,
        recipientFingerprint: String? = nil,
        expiresAt: Date? = nil,
        createdAt: Date = Date()
    ) throws -> FernletIdentityEnvelope {
        try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Test Sender",
            recipientFingerprint: recipientFingerprint,
            payloadType: payloadType,
            payloadEncryption: payloadEncryption,
            payloadSummary: PayloadSummary(title: "Test"),
            payload: payload,
            createdAt: createdAt,
            expiresAt: expiresAt
        )
    }

    /// Rebuilds an envelope with one field replaced, keeping the original signature (for tamper tests).
    private func tamper(_ env: FernletIdentityEnvelope,
                        schemaVersion: Int? = nil,
                        payload: Data? = nil,
                        payloadSummary: PayloadSummary? = nil) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion:               schemaVersion ?? env.schemaVersion,
            envelopeID:                  env.envelopeID,
            senderSigningPublicKey:      env.senderSigningPublicKey,
            senderKeyAgreementPublicKey: env.senderKeyAgreementPublicKey,
            senderDisplayName:           env.senderDisplayName,
            recipientFingerprint:        env.recipientFingerprint,
            payloadType:                 env.payloadType,
            payloadEncryption:           env.payloadEncryption,
            payloadSummary:              payloadSummary ?? env.payloadSummary,
            payload:                     payload ?? env.payload,
            createdAt:                   env.createdAt,
            expiresAt:                   env.expiresAt,
            signature:                   env.signature
        )
    }

    // MARK: - Codable round-trips

    @Test func codableRoundTripAllPayloadTypes() throws {
        let (sender, sid) = try makeIdentity()
        defer { cleanup(sid) }

        // Use default date encoding (Double timestamp) — preserves exact sub-second precision.
        // ISO8601 is only needed for canonical signing bytes, not general Codable round-trips.
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for pt in PayloadType.allCases {
            let env = try signedEnvelope(sender: sender, payloadType: pt)
            let data = try encoder.encode(env)
            let decoded = try decoder.decode(FernletIdentityEnvelope.self, from: data)
            #expect(decoded == env, "Round-trip failed for PayloadType.\(pt.rawValue)")
        }
    }

    @Test func codableRoundTripUnencryptedPayloadEncryption() throws {
        let (sender, sid) = try makeIdentity()
        defer { cleanup(sid) }

        let env = try signedEnvelope(sender: sender, payloadEncryption: .none)
        let decoded = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: JSONEncoder().encode(env))

        #expect(decoded == env)
        #expect(decoded.payloadEncryption == .none)
    }

    @Test func codableRoundTripSealedPayloadEncryption() throws {
        let (sender, sid) = try makeIdentity()
        defer { cleanup(sid) }
        let (recipient, rid) = try makeIdentity()
        defer { cleanup(rid) }

        let sealedPayload = try sender.seal(Data("secret".utf8), to: recipient.localKeyAgreementPublicKey)
        let enc: PayloadEncryption = .sealedTo(recipientKeyAgreementPublicKey: recipient.localKeyAgreementPublicKey)
        let env = try signedEnvelope(sender: sender, payload: sealedPayload, payloadEncryption: enc)

        let decoded = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: JSONEncoder().encode(env))

        #expect(decoded == env)
        #expect(decoded.payloadEncryption == enc)
    }

    // MARK: - Sign and verify

    @Test func signAndVerifyRoundTrip() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let plaintext = Data("trainer plan payload".utf8)
        let env = try signedEnvelope(sender: alice, payload: plaintext)
        let recovered = try env.verify(identityService: bob, replayCache: ReplayCache())

        #expect(recovered == plaintext)
    }

    @Test func verifyRejectsTamperedPayload() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(sender: alice, payload: Data("original".utf8))
        let bad = tamper(env, payload: Data("tampered".utf8))

        #expect(throws: FernletIdentityEnvelope.VerifyError.signatureInvalid) {
            try bad.verify(identityService: bob, replayCache: ReplayCache())
        }
    }

    @Test func verifyRejectsTamperedSummaryTitle() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(sender: alice)
        let bad = tamper(env, payloadSummary: PayloadSummary(title: "TAMPERED TITLE"))

        #expect(throws: FernletIdentityEnvelope.VerifyError.signatureInvalid) {
            try bad.verify(identityService: bob, replayCache: ReplayCache())
        }
    }

    @Test func verifyRejectsExpiredEnvelope() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(sender: alice, expiresAt: .distantPast)

        #expect(throws: FernletIdentityEnvelope.VerifyError.expired) {
            try env.verify(identityService: bob, replayCache: ReplayCache())
        }
    }

    @Test func verifyRejectsWrongSchemaVersion() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(sender: alice)
        let bad = tamper(env, schemaVersion: 99)

        #expect(throws: FernletIdentityEnvelope.VerifyError.schemaVersionUnsupported) {
            try bad.verify(identityService: bob, replayCache: ReplayCache())
        }
    }

    @Test func verifyRejectsRecipientMismatch() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }
        let (carol, cid) = try makeIdentity()
        defer { cleanup(cid) }

        // Addressed to Carol
        let env = try signedEnvelope(sender: alice, recipientFingerprint: carol.localFingerprint)

        // Bob tries to verify — fingerprint doesn't match
        #expect(throws: FernletIdentityEnvelope.VerifyError.recipientMismatch) {
            try env.verify(identityService: bob, replayCache: ReplayCache())
        }
    }

    @Test func verifyAcceptsLegacyEightCharacterRecipientFingerprint() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let legacyRecipient = String(bob.localFingerprint.prefix(8))
        let env = try signedEnvelope(sender: alice, recipientFingerprint: legacyRecipient)

        #expect(try env.verify(identityService: bob, replayCache: ReplayCache()) == env.payload)
    }

    @Test func verifyRejectsReplay() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(sender: alice, payload: Data("data".utf8))
        let replayCache = ReplayCache()

        _ = try env.verify(identityService: bob, replayCache: replayCache)

        #expect(throws: FernletIdentityEnvelope.VerifyError.replayDetected) {
            try env.verify(identityService: bob, replayCache: replayCache)
        }
    }

    // MARK: - Sealed envelopes

    @Test func sealedEnvelopeRoundTrips() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let secret = Data("secret plan data".utf8)
        let sealedPayload = try alice.seal(secret, to: bob.localKeyAgreementPublicKey)
        let env = try signedEnvelope(
            sender: alice,
            payload: sealedPayload,
            payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey: bob.localKeyAgreementPublicKey)
        )

        let recovered = try env.verify(identityService: bob, replayCache: ReplayCache())
        #expect(recovered == secret)
    }

    @Test func sealedEnvelopeRejectsWrongRecipient() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }
        let (eve, eid) = try makeIdentity()
        defer { cleanup(eid) }

        let sealedPayload = try alice.seal(Data("secret".utf8), to: bob.localKeyAgreementPublicKey)
        // Addressed to Bob explicitly
        let env = try signedEnvelope(
            sender: alice,
            payload: sealedPayload,
            payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey: bob.localKeyAgreementPublicKey),
            recipientFingerprint: bob.localFingerprint
        )

        // Eve's fingerprint doesn't match — fails before even attempting decryption
        #expect(throws: FernletIdentityEnvelope.VerifyError.recipientMismatch) {
            try env.verify(identityService: eve, replayCache: ReplayCache())
        }
    }

    @Test func recipeShareEnvelopeRejectsUnsealedPayload() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(
            sender: alice,
            payload: Data("recipe payload".utf8),
            payloadType: .recipeShare,
            payloadEncryption: .none,
            recipientFingerprint: bob.localFingerprint
        )

        #expect(throws: FernletIdentityEnvelope.VerifyError.sealingRequired) {
            try env.verify(identityService: bob, replayCache: ReplayCache())
        }
    }

    // MARK: - Canonical bytes

    @Test func canonicalBytesAreDeterministic() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }

        let env = try signedEnvelope(sender: alice)
        #expect(canonicalBytes(for: env) == canonicalBytes(for: env))
    }

    @Test func canonicalBytesIgnoreSignatureField() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }

        var env = try signedEnvelope(sender: alice)
        let before = canonicalBytes(for: env)
        env.signature = Data("totally different bytes".utf8)
        let after = canonicalBytes(for: env)
        #expect(before == after)
    }

    @Test func meshPayloadTypesRoundTrip() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }

        let meshPayloadTypes: [PayloadType] = [
            .meshDescriptor,
            .meshAdmissionGrant,
            .meshAdmissionToken,
            .meshAdmissionRequest,
            .meshStateChange,
            .meshFriendVouchList
        ]

        for payloadType in meshPayloadTypes {
            let envelope = try signedEnvelope(sender: alice, payloadType: payloadType)
            let decoded = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: JSONEncoder().encode(envelope))
            #expect(decoded.payloadType == payloadType)
        }
    }

    @Test func meshDescriptorCanonicalPayloadRoundTrips() throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let member = MeshMember(
            fingerprint: "abc12345",
            displayName: "Aisha",
            signingPublicKey: Data("signing".utf8),
            keyAgreementPublicKey: Data("agreement".utf8),
            joinedAt: now
        )
        let descriptor = MeshDescriptor(
            meshID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            name: "Fernlet Friends",
            mode: .open,
            members: [member],
            nameSetAt: now,
            nameSetBy: member.fingerprint,
            modeSetAt: now,
            modeSetBy: member.fingerprint,
            createdAt: now
        )

        let data = try JSONEncoder().encode(MeshStateChangePayload(descriptor: descriptor))
        let decoded = try JSONDecoder().decode(MeshStateChangePayload.self, from: data)

        #expect(decoded.descriptor == descriptor)
    }

    @Test func meshAdmissionTokenSignsVerifiesAndRejectsTampering() throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiresAt = grantedAt.addingTimeInterval(2 * 60 * 60)
        var token = try MeshAdmissionToken.signed(
            meshID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt,
            expiresAt: expiresAt
        )

        try token.verify(joinerSigningPublicKey: joiner.localSigningPublicKey, now: grantedAt.addingTimeInterval(60))
        let canonicalBefore = canonicalBytes(for: token)
        token.admitterSignature = Data("tampered".utf8)
        #expect(canonicalBytes(for: token) == canonicalBefore)
        #expect(throws: MeshAdmissionToken.VerifyError.signatureInvalid) {
            try token.verify(joinerSigningPublicKey: joiner.localSigningPublicKey, now: grantedAt.addingTimeInterval(60))
        }
    }

    @Test func meshAdmissionTokenRejectsWrongJoinerKey() throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }
        let (attacker, attackid) = try makeIdentity()
        defer { cleanup(attackid) }
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let token = try MeshAdmissionToken.signed(
            meshID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt
        )
        #expect(throws: MeshAdmissionToken.VerifyError.joinerKeyMismatch) {
            try token.verify(joinerSigningPublicKey: attacker.localSigningPublicKey,
                             now: grantedAt.addingTimeInterval(60))
        }
    }

    @Test func meshAdmissionTokenAcceptsLegacyEightCharacterJoinerFingerprint() throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let token = try MeshAdmissionToken.signed(
            meshID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            joinerFingerprint: String(joiner.localFingerprint.prefix(8)),
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt
        )

        try token.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            now: grantedAt.addingTimeInterval(60)
        )
    }

    @Test func verifyRejectsFriendPhotoWithoutSealing() throws {
        let (sender, sid) = try makeIdentity()
        defer { cleanup(sid) }
        let (recipient, rid) = try makeIdentity()
        defer { cleanup(rid) }
        let envelope = try signedEnvelope(sender: sender, payloadType: .friendPhoto, payloadEncryption: .none)
        #expect(throws: FernletIdentityEnvelope.VerifyError.sealingRequired) {
            try envelope.verify(identityService: recipient, replayCache: ReplayCache())
        }
    }

    @Test func friendPhotoPayloadDecodesLegacyWithoutProvenance() throws {
        let id = UUID(uuidString: "00000000-0000-0000-0000-000000000003")!
        let addedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let legacy = FriendPhotoPayload(id: id, imageData: Data([1, 2, 3]), addedAt: addedAt, senderName: "Legacy")
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(FriendPhotoPayload.self, from: data)

        #expect(decoded.id == id)
        #expect(decoded.senderFingerprint == nil)
        #expect(decoded.senderSigningPublicKey == nil)
    }

    // MARK: - ReplayCache

    @Test func replayCachePurgesOldEntries() throws {
        final class Clock: @unchecked Sendable { var date = Date() }
        let clock = Clock()
        let cache = ReplayCache(dateProvider: { clock.date })

        let id1 = UUID()
        try cache.recordIfNew(envelopeID: id1)

        // Confirm it's tracked
        #expect(throws: FernletIdentityEnvelope.VerifyError.replayDetected) {
            try cache.recordIfNew(envelopeID: id1)
        }

        // Advance clock by 25 hours — past the 24-hour retention window
        clock.date = clock.date.addingTimeInterval(25 * 60 * 60)

        // Old entry purged; same ID can be recorded again
        try cache.recordIfNew(envelopeID: id1)
    }
}
