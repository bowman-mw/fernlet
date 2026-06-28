// FernletIdentityEnvelopeTests.swift
// FernletTests
//
// Tests for FernletIdentityEnvelope, PayloadEncryption, ReplayCache (Phase 7.2).
// Each test uses UUID-scoped Keychain services cleaned up via defer.

import ProximityKit
import Foundation
import FernletFoundation
import Testing
import FernletDomainModel
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

        let meshID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        try token.verify(joinerSigningPublicKey: joiner.localSigningPublicKey, expectedMeshID: meshID, now: grantedAt.addingTimeInterval(60))
        let canonicalBefore = canonicalBytes(for: token)
        token.admitterSignature = Data("tampered".utf8)
        #expect(canonicalBytes(for: token) == canonicalBefore)
        #expect(throws: MeshAdmissionToken.VerifyError.signatureInvalid) {
            try token.verify(joinerSigningPublicKey: joiner.localSigningPublicKey, expectedMeshID: meshID, now: grantedAt.addingTimeInterval(60))
        }
    }

    @Test func meshAdmissionTokenRejectsMismatchedMeshID() throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let token = try MeshAdmissionToken.signed(
            meshID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt
        )
        // A token issued for mesh ...0002 must not verify when presented as a grant for ...0009.
        #expect(throws: MeshAdmissionToken.VerifyError.meshMismatch) {
            try token.verify(
                joinerSigningPublicKey: joiner.localSigningPublicKey,
                expectedMeshID: UUID(uuidString: "00000000-0000-0000-0000-000000000009")!,
                now: grantedAt.addingTimeInterval(60)
            )
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
                             expectedMeshID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
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
            expectedMeshID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!,
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
        try cache.recordIfNew(envelopeID: id1, createdAt: clock.date)

        // Confirm it's tracked
        #expect(throws: FernletIdentityEnvelope.VerifyError.replayDetected) {
            try cache.recordIfNew(envelopeID: id1, createdAt: clock.date)
        }

        // Advance clock by 25 hours — past the 24-hour retention window
        clock.date = clock.date.addingTimeInterval(25 * 60 * 60)

        // Old entry purged; same ID can be recorded again
        try cache.recordIfNew(envelopeID: id1, createdAt: clock.date)
    }

    // MARK: - WI-6 cross-platform canonical signing serializer

    // Pinned golden vectors for the canonical v2 serializer. These bytes are the cross-platform
    // signing contract: a future Android/Kotlin re-implementation must reproduce them byte-for-byte,
    // and any accidental drift in the Swift serializer breaks these tests. Generated from a fixed
    // input (see `fixedGoldenEnvelope`/`fixedGoldenToken`).
    static let goldenEnvelopeHex = "00000000000000266665726e6c65742e63616e6f6e6963616c2e6964656e746974792d656e76656c6f70652e7632000000000000000211111111222233334444555555555555000000000000000401020304000000000000000405060708000000000000000a416973686120f09f8cbf0100000000000000106162636465663031323334353637383900000000000000176665726e6c65742e7265636970652e73686172652e7631010000000000000002aabb0000000000000004536f757001000000000000000644696e6e6572000000000000000301000000006553f100000000006553ff1000000000000000030000000000000001610000000000000005666972737400000000000000016d00000000000000066d6964646c6500000000000000017a00000000000000046c617374000000000000000d7061796c6f61642d6279746573000000006553f100010000000065540d20"
    static let goldenTokenHex = "00000000000000296665726e6c65742e63616e6f6e6963616c2e6d6573682d61646d697373696f6e2d746f6b656e2e7632000000000000000000000000000000aa00000000000000106a6f696e65722d66702d3132333435360000000000000003101112000000000000001061646d69747465722d66702d37383930000000006553f1000000000065540d200000000000000003202122"

    /// A fully-specified envelope with non-ASCII text, a sealed encryption case, a populated
    /// `dateRange`, and an out-of-order `extraDetails` map — exercises every canonical branch.
    private func fixedGoldenEnvelope() -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            senderSigningPublicKey: Data([0x01, 0x02, 0x03, 0x04]),
            senderKeyAgreementPublicKey: Data([0x05, 0x06, 0x07, 0x08]),
            senderDisplayName: "Aisha 🌿",
            recipientFingerprint: "abcdef0123456789",
            payloadType: .recipeShare,
            payloadEncryption: .sealedTo(recipientKeyAgreementPublicKey: Data([0xAA, 0xBB])),
            payloadSummary: PayloadSummary(
                title: "Soup",
                subtitle: "Dinner",
                itemCount: 3,
                dateRange: DateRange(
                    start: Date(timeIntervalSince1970: 1_700_000_000),
                    end: Date(timeIntervalSince1970: 1_700_003_600)
                ),
                extraDetails: ["z": "last", "a": "first", "m": "middle"]
            ),
            payload: Data("payload-bytes".utf8),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_007_200),
            signature: Data("ignored — excluded from canonical bytes".utf8)
        )
    }

    private func fixedGoldenToken() -> MeshAdmissionToken {
        MeshAdmissionToken(
            meshID: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
            joinerFingerprint: "joiner-fp-123456",
            joinerSigningPublicKey: Data([0x10, 0x11, 0x12]),
            admitterFingerprint: "admitter-fp-7890",
            grantedAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_007_200),
            admitterSigningPublicKey: Data([0x20, 0x21, 0x22]),
            admitterSignature: Data("ignored — excluded from canonical bytes".utf8)
        )
    }

    private func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    /// Builds a v1 (pre-WI-6) signed envelope: signs over the LEGACY canonical bytes and stamps the
    /// legacy schema version, exactly as a not-yet-updated in-field peer would.
    private func legacySignedEnvelope(sender: IdentityService, payload: Data) throws -> FernletIdentityEnvelope {
        var env = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.legacySchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: sender.localSigningPublicKey,
            senderKeyAgreementPublicKey: sender.localKeyAgreementPublicKey,
            senderDisplayName: "Legacy Sender",
            recipientFingerprint: nil,
            payloadType: .inspectorEcho,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Legacy"),
            payload: payload,
            createdAt: Date(),
            expiresAt: nil,
            signature: Data()
        )
        env.signature = try sender.sign(legacyCanonicalBytes(for: env))
        return env
    }

    @Test func wi6_canonicalEnvelopeBytesAreGoldenStable() {
        let actual = hex(canonicalBytes(for: fixedGoldenEnvelope()))
        #expect(actual == Self.goldenEnvelopeHex, "actual envelope golden hex = \(actual)")
    }

    @Test func wi6_canonicalTokenBytesAreGoldenStable() {
        let actual = hex(canonicalBytes(for: fixedGoldenToken()))
        #expect(actual == Self.goldenTokenHex, "actual token golden hex = \(actual)")
    }

    /// The canonical bytes must ignore `extraDetails` insertion order (map ordering is non-canonical),
    /// proving the byte-lexicographic key sort defeats Swift's per-process dictionary seed.
    @Test func wi6_canonicalBytesIndependentOfMapInsertionOrder() {
        let forward = PayloadSummary(title: "t", extraDetails: ["a": "1", "b": "2", "c": "3"])
        let reverse = PayloadSummary(title: "t", extraDetails: ["c": "3", "b": "2", "a": "1"])
        func envelope(_ summary: PayloadSummary) -> FernletIdentityEnvelope {
            FernletIdentityEnvelope(
                schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
                envelopeID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                senderSigningPublicKey: Data([0x01]), senderKeyAgreementPublicKey: Data([0x02]),
                senderDisplayName: "n", recipientFingerprint: nil, payloadType: .inspectorEcho,
                payloadEncryption: .none, payloadSummary: summary, payload: Data(),
                createdAt: Date(timeIntervalSince1970: 1_700_000_000), expiresAt: nil, signature: Data()
            )
        }
        #expect(canonicalBytes(for: envelope(forward)) == canonicalBytes(for: envelope(reverse)))
    }

    @Test func wi6_signNewVerifyNewRoundTrip() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(sender: alice, payload: Data("v2 payload".utf8))
        #expect(env.schemaVersion == FernletIdentityEnvelope.currentSchemaVersion)
        let recovered = try env.verify(identityService: bob, replayCache: ReplayCache())
        #expect(recovered == Data("v2 payload".utf8))
    }

    @Test func wi6_dualVerifyAcceptsLegacyAndNewEnvelopes() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        // New (v2) signs and verifies via the cross-platform serializer.
        let newEnv = try signedEnvelope(sender: alice, payload: Data("hello".utf8))
        #expect(newEnv.schemaVersion == FernletIdentityEnvelope.currentSchemaVersion)
        #expect(try newEnv.verify(identityService: bob, replayCache: ReplayCache()) == Data("hello".utf8))

        // Legacy (v1) — minted with the old encoder — still verifies (no in-field peer cut off).
        let legacyEnv = try legacySignedEnvelope(sender: alice, payload: Data("hello".utf8))
        #expect(legacyEnv.schemaVersion == FernletIdentityEnvelope.legacySchemaVersion)
        #expect(try legacyEnv.verify(identityService: bob, replayCache: ReplayCache()) == Data("hello".utf8))
    }

    @Test func wi6_dualVerifyAcceptsLegacyAndNewTokens() throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }
        let meshID = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let expiresAt = grantedAt.addingTimeInterval(3600)

        // New (v2)
        let newToken = try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt,
            expiresAt: expiresAt
        )
        try newToken.verify(joinerSigningPublicKey: joiner.localSigningPublicKey,
                            expectedMeshID: meshID, now: grantedAt.addingTimeInterval(60))

        // Legacy — signed over the old canonical bytes — still verifies via the legacy fallback.
        var legacyToken = MeshAdmissionToken(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterFingerprint: admitter.localFingerprint,
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            admitterSigningPublicKey: admitter.localSigningPublicKey,
            admitterSignature: Data()
        )
        legacyToken.admitterSignature = try admitter.sign(legacyCanonicalBytes(for: legacyToken))
        try legacyToken.verify(joinerSigningPublicKey: joiner.localSigningPublicKey,
                               expectedMeshID: meshID, now: grantedAt.addingTimeInterval(60))
    }

    @Test func wi6_verifyRejectsTamperedCanonicalEnvelopeField() throws {
        let (alice, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (bob, bid) = try makeIdentity()
        defer { cleanup(bid) }

        let env = try signedEnvelope(sender: alice, payload: Data("original".utf8))
        // Flip a canonical field (display name) while retaining the original signature.
        let bad = tamperDisplayName(env, to: env.senderDisplayName + "!")
        #expect(throws: FernletIdentityEnvelope.VerifyError.signatureInvalid) {
            try bad.verify(identityService: bob, replayCache: ReplayCache())
        }
    }

    @Test func wi6_tokenVerifyRejectsTamperedCanonicalField() throws {
        let (admitter, aid) = try makeIdentity()
        defer { cleanup(aid) }
        let (joiner, jid) = try makeIdentity()
        defer { cleanup(jid) }
        let meshID = UUID(uuidString: "00000000-0000-0000-0000-0000000000cc")!
        let grantedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let token = try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: joiner.localFingerprint,
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            admitterIdentity: admitter,
            grantedAt: grantedAt,
            expiresAt: grantedAt.addingTimeInterval(3600)
        )
        // Tamper `grantedAt` (a canonical field that isn't re-derived before the signature check),
        // keeping the original signature — so the failure is specifically `signatureInvalid`.
        let bad = MeshAdmissionToken(
            meshID: token.meshID,
            joinerFingerprint: token.joinerFingerprint,
            joinerSigningPublicKey: token.joinerSigningPublicKey,
            admitterFingerprint: token.admitterFingerprint,
            grantedAt: token.grantedAt.addingTimeInterval(1),
            expiresAt: token.expiresAt,
            admitterSigningPublicKey: token.admitterSigningPublicKey,
            admitterSignature: token.admitterSignature
        )
        #expect(throws: MeshAdmissionToken.VerifyError.signatureInvalid) {
            try bad.verify(joinerSigningPublicKey: joiner.localSigningPublicKey,
                           expectedMeshID: meshID, now: grantedAt.addingTimeInterval(60))
        }
    }

    private func tamperDisplayName(_ env: FernletIdentityEnvelope, to name: String) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: env.schemaVersion,
            envelopeID: env.envelopeID,
            senderSigningPublicKey: env.senderSigningPublicKey,
            senderKeyAgreementPublicKey: env.senderKeyAgreementPublicKey,
            senderDisplayName: name,
            recipientFingerprint: env.recipientFingerprint,
            payloadType: env.payloadType,
            payloadEncryption: env.payloadEncryption,
            payloadSummary: env.payloadSummary,
            payload: env.payload,
            createdAt: env.createdAt,
            expiresAt: env.expiresAt,
            signature: env.signature
        )
    }
}
