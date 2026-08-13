// SealedPayloadFramingTests.swift
// FernletTests
//
// wire2 sealed-payload framing (bitchat adoptions Increment 2,
// Docs/Plan-Bitchat-Adoptions-2026-07-25.md): codec round-trips, bucket padding, the inflate
// bomb guard, and the IdentityService seal/open integration including the legacy-tolerant
// receive path. IdentityService tests use UUID-scoped keychain services + defer cleanup, per
// IdentityServiceTests convention.

import Foundation
import Testing
import CryptoKit
import ProximityKit
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct SealedPayloadFramingTests {

    // MARK: - Harness

    private func makeService() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: serviceID)
        try service.ensureProvisioned()
        return (service, serviceID)
    }

    private func cleanup(_ serviceID: String) {
        KeychainItem.deleteAll(service: serviceID)
    }

    private func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: .min ... .max) })
    }

    // MARK: - Codec

    @Test func rawRoundTripPadsToSmallestBucket() throws {
        let original = randomBytes(64) // below the compression threshold → raw tag
        let framed = SealedPayloadFraming.frame(original)
        #expect(framed.first == 0x02)
        #expect(framed.count == 256)
        #expect(try SealedPayloadFraming.unframe(framed) == original)
    }

    @Test func compressibleBodyRoundTripsAndShrinks() throws {
        let original = Data(String(repeating: #"{"kind":"vibes","value":"gentle"},"#, count: 64).utf8)
        #expect(original.count > 1024)
        let framed = SealedPayloadFraming.frame(original)
        #expect(framed.first == 0x01)
        #expect(framed.count < original.count) // deflate + pad still beats the raw body
        #expect(try SealedPayloadFraming.unframe(framed) == original)
    }

    @Test func bucketBoundariesAreExact() throws {
        // Random bodies don't deflate smaller, so the raw path is taken deterministically.
        // 253 raw bytes → 1 + 253 + 2 == 256 exactly (zero padding).
        let exact = SealedPayloadFraming.frame(randomBytes(253))
        #expect(exact.count == 256)
        // One more byte spills into the next bucket.
        let spilled = SealedPayloadFraming.frame(randomBytes(254))
        #expect(spilled.count == 512)
        // Past 4096, buckets continue at 4 KiB multiples: 1 + 5000 + 2 → 8192.
        let large = SealedPayloadFraming.frame(randomBytes(5000))
        #expect(large.count == 8192)
    }

    @Test func equalSizeClassesAreIndistinguishable() throws {
        // The point of padding: a tiny heart and a mid-size message land in the same bucket.
        let heartish = SealedPayloadFraming.frame(Data(#"{"id":"x"}"#.utf8))
        let messageish = SealedPayloadFraming.frame(randomBytes(200))
        #expect(heartish.count == messageish.count)
    }

    @Test func unframeRejectsMalformedInput() {
        #expect(throws: SealedPayloadFraming.FramingError.malformed) {
            try SealedPayloadFraming.unframe(Data())
        }
        #expect(throws: SealedPayloadFraming.FramingError.malformed) {
            try SealedPayloadFraming.unframe(Data([0x02, 0x00]))
        }
        // Legacy JSON must never parse as a frame.
        #expect(throws: SealedPayloadFraming.FramingError.malformed) {
            try SealedPayloadFraming.unframe(Data(#"{"a":1}"#.utf8))
        }
        // padCount larger than the frame allows.
        #expect(throws: SealedPayloadFraming.FramingError.malformed) {
            try SealedPayloadFraming.unframe(Data([0x02, 0xFF, 0xFF]))
        }
    }

    @Test func inflateBombIsRejected() throws {
        // 16 MiB + 1 of zeros deflates to a few KiB; unframe must refuse to inflate it.
        let bomb = Data(count: SealedPayloadFraming.maxInflatedByteCount + 1)
        let framed = SealedPayloadFraming.frame(bomb)
        #expect(framed.first == 0x01)
        #expect(throws: SealedPayloadFraming.FramingError.inflatedTooLarge) {
            try SealedPayloadFraming.unframe(framed)
        }
    }

    @Test func frameTagDetection() {
        #expect(!SealedPayloadFraming.hasFrameTag(Data(#"{"a":1}"#.utf8)))
        #expect(!SealedPayloadFraming.hasFrameTag(Data()))
        #expect(SealedPayloadFraming.hasFrameTag(SealedPayloadFraming.frame(Data([0x00]))))
    }

    // MARK: - IdentityService integration

    @Test func wire2SealOpenRoundTripsAndPadsCiphertext() throws {
        let (alice, aliceID) = try makeService()
        defer { cleanup(aliceID) }
        let (bob, bobID) = try makeService()
        defer { cleanup(bobID) }

        let payload = Data(#"{"format":"fernlet.proximity.heart","version":1}"#.utf8)
        let sealed = try alice.seal(payload, to: bob.localKeyAgreementPublicKey, format: .wire2)
        // eph pub (32) + nonce (12) + 256-bucket frame + tag (16): padding is visible on the wire.
        #expect(sealed.count == 32 + 12 + 256 + 16)
        let opened = try bob.open(sealed, from: alice.localKeyAgreementPublicKey, format: .wire2)
        #expect(opened == payload)
    }

    @Test func wire2OpenToleratesLegacySealedBody() throws {
        // The handshake race: a wire2-capable sender sealed legacy before learning our
        // capabilities. The receiver's .wire2 open must pass the JSON body through unchanged.
        let (alice, aliceID) = try makeService()
        defer { cleanup(aliceID) }
        let (bob, bobID) = try makeService()
        defer { cleanup(bobID) }

        let payload = Data(#"{"hello":"there"}"#.utf8)
        let sealedLegacy = try alice.seal(payload, to: bob.localKeyAgreementPublicKey)
        let opened = try bob.open(sealedLegacy, from: alice.localKeyAgreementPublicKey, format: .wire2)
        #expect(opened == payload)
    }

    // MARK: - The 0x7B compatibility invariant

    // SealedPayloadFraming's load-bearing precondition (its file header): every legacy (unframed)
    // sealed body in this codebase is a JSON OBJECT, first byte 0x7B, which is what makes 0x01/0x02
    // collision-free frame tags. Before this it was prose, enforced by nothing — and the tolerant
    // receive path (`hasFrameTag` + the sender's advertised `wire2`) silently mis-reads any sealed
    // body that starts with a tag byte.
    //
    // The property that actually matters is that the four PRODUCTION seal sites all feed
    // `JSONEncoder` output into `IdentityService.seal`:
    //   • `ProximityCoordinator.sealIfNeeded` — every presence / recipe-share sealed payload;
    //   • `ProximityCoordinator.encodeIdentityEnvelopeForTransport` — the sealed introduction, which
    //     seals an encoded `FernletIdentityEnvelope` rather than a payload struct;
    //   • `MeshNetworkManager.sendEnvelope(_:encodable:via:sealed:)`;
    //   • `MeshNetworkManager.sendVerifyEnvelope(...)`.
    // So the tests below encode a representative value of each sealed payload type (plus the envelope
    // itself) exactly the way those sites do, and assert the leading byte.

    /// One representative value per `PayloadType` in `FernletIdentityEnvelope.sealingRequiredTypes`
    /// that has a concrete payload type in this repo. Values are shape-only — nothing is signed or
    /// sent — because the assertion is about the ENCODING, not the contents.
    private static func sealedPayloadRepresentatives() -> [(caseName: String, payload: any Encodable)] {
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let descriptor = ActivityDescriptor(
            activityID: UUID(), hostFingerprint: "abc", hostSigningPublicKey: Data([1]),
            title: "Sunset walk", activityTypeToken: "walk", coarseLocation: "the park",
            createdAt: now, expiresAt: now.addingTimeInterval(3600)
        )
        let snapshot = ActivityRosterSnapshot(
            activityID: descriptor.activityID, version: 1, participants: [], issuedAt: now,
            hostSigningPublicKey: Data([1]), hostSignature: Data([2])
        )
        let token = ActivityJoinToken(
            activityID: descriptor.activityID, activityParamsHash: Data([3]),
            joinerFingerprint: "def", joinerSigningPublicKey: Data([4]),
            hostFingerprint: "abc", hostSigningPublicKey: Data([1]),
            grantedAt: now, expiresAt: now.addingTimeInterval(3600),
            rosterVersionAtGrant: 1, hostSignature: Data([5])
        )
        return [
            ("friendPhoto", FriendPhotoPayload(imageData: Data([1, 2, 3]), senderName: "Friend")),
            ("recipeShare", SharedRecipePayload(name: "Soup", servings: 2, notes: "", ingredients: [])),
            ("clothingCatalog", ClothingCatalogPayload(designerID: UUID(), displayName: "Friend", items: [])),
            ("friendHeart", HeartPayload(sentAtDayKey: "2026-07-25")),
            ("tempMessage", TempMessagePayload(text: "hi")),
            ("itemReport", ModerationReportPayload(reports: [])),
            ("friendState", FriendStatePayload(state: .okay, appearance: .standard)),
            ("activityOffer", ActivityOfferPayload(descriptor: descriptor, rosterVersion: 1)),
            ("activityJoinGrant", ActivityJoinGrantPayload(token: token, snapshot: snapshot)),
            ("activityRosterSnapshot", ActivityRosterSnapshotPayload(snapshot: snapshot)),
            ("activitySync", ActivitySyncPayload(held: [])),
            ("workoutCompletion", TrainerExportPayload(bundle: Data([0x7B, 0x7D]))),
            ("verifyChallenge", VerifyChallengePayload(qrNonce: Data([1]), challengeNonce: Data([2]))),
            ("verifyResponse", VerifyResponsePayload(challengeNonce: Data([2]), signature: Data([3])))
        ]
    }

    /// Sealed types with no concrete payload struct in this repo yet: the trainer plan/live wire is a
    /// declared seam whose transport is deferred to the separate coach app (TrainerPayloads.swift), so
    /// there is nothing to encode. `sealedPayloadTypeCoverageIsComplete` fails if a NEW sealed type
    /// joins them without a representative here.
    private static let uncoveredSealedTypes: Set<String> = [
        "trainerPlan", "trainerPlanDelta", "workoutLiveUpdate"
    ]

    @Test func everySealedPayloadEncodesToAJSONObject() throws {
        for (caseName, payload) in Self.sealedPayloadRepresentatives() {
            let encoded = try JSONEncoder().encode(payload)
            #expect(
                encoded.first == 0x7B,
                "\(caseName) does not encode to a JSON object — the wire2 frame tags stop being collision-free and a legacy body from this type can be mis-read as a frame."
            )
            // The receive-side consequence, stated directly.
            #expect(!SealedPayloadFraming.hasFrameTag(encoded), "\(caseName) encodes to something the tolerant receive path would try to unframe.")
        }
    }

    /// The tag bytes can never be the first byte of ANY JSON text, so the discriminator holds for
    /// payload shapes this repo hasn't written yet (an array body, a bare string, a number).
    @Test func framingTagsCannotCollideWithAnyJSONFirstByte() {
        // RFC 8259: a JSON text starts with insignificant whitespace (only 0x20/0x09/0x0A/0x0D) or the
        // first byte of a value — `{ [ "` , `-`, a digit, or the leading letter of true/false/null.
        var possibleFirstBytes: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D,
                                              0x7B, 0x5B, 0x22, 0x2D, 0x74, 0x66, 0x6E]
        possibleFirstBytes.formUnion((UInt8(ascii: "0")...UInt8(ascii: "9")))

        for byte in possibleFirstBytes.sorted() {
            #expect(!SealedPayloadFraming.hasFrameTag(Data([byte])), "0x\(String(byte, radix: 16)) is a legal JSON first byte AND reads as a frame tag.")
        }
        // And the inverse: the two tags are outside that set entirely.
        #expect(!possibleFirstBytes.contains(0x01))
        #expect(!possibleFirstBytes.contains(0x02))
        #expect(SealedPayloadFraming.hasFrameTag(Data([0x01])))
        #expect(SealedPayloadFraming.hasFrameTag(Data([0x02])))
    }

    /// Coverage guard: every case listed in `FernletIdentityEnvelope.sealingRequiredTypes` must either
    /// have a representative above or be a documented gap. `sealingRequiredTypes` is `private`, so this
    /// reads the declaration from source — the same grep-wall stance as `PrivacyWipeCoverageTests`.
    @Test func sealedPayloadTypeCoverageIsComplete() throws {
        let repoRoot = RepoRoot.url
        let source = try String(
            contentsOf: repoRoot.appendingPathComponent("FernletKit/Sources/ProximityKit/Wire/FernletIdentityEnvelope.swift"),
            encoding: .utf8
        )
        guard let declaration = source.components(separatedBy: "\n")
            .first(where: { $0.contains("sealingRequiredTypes: Set<PayloadType>") }),
              let open = declaration.firstIndex(of: "["),
              let close = declaration.lastIndex(of: "]") else {
            Issue.record("Could not read `sealingRequiredTypes` from FernletIdentityEnvelope.swift — moved or reformatted? The 0x7B invariant is then unguarded.")
            return
        }
        let required = Set(
            declaration[declaration.index(after: open)..<close]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { $0.hasPrefix(".") }
                .map { String($0.dropFirst()) }
        )
        #expect(required.count >= 14, "Parsed only \(required.count) sealed types — the parse is broken, not the wall.")

        let covered = Set(Self.sealedPayloadRepresentatives().map(\.caseName)).union(Self.uncoveredSealedTypes)
        let unguarded = required.subtracting(covered).sorted()
        #expect(unguarded.isEmpty, "Sealed payload type(s) \(unguarded) have no 0x7B representative — add one (or add to `uncoveredSealedTypes` with a reason). A sealed body that isn't a JSON object breaks the wire2 frame-tag discriminator.")
    }

    /// The sealed INTRODUCTION seals an encoded envelope, not a payload struct — so the invariant has
    /// to hold for `FernletIdentityEnvelope` itself, over a real signed value.
    @Test func theSealedIntroductionBodyIsAlsoAJSONObject() throws {
        let (alice, aliceID) = try makeService()
        defer { cleanup(aliceID) }

        let envelope = try FernletIdentityEnvelope.signed(
            identityService: alice,
            senderDisplayName: "Alice",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: PayloadType.identityIntroduction.rawValue),
            payload: Data()
        )
        let encoded = try JSONEncoder().encode(envelope)
        #expect(encoded.first == 0x7B)
        #expect(!SealedPayloadFraming.hasFrameTag(encoded))
    }

    @Test func legacySealOpenIsUnchanged() throws {
        let (alice, aliceID) = try makeService()
        defer { cleanup(aliceID) }
        let (bob, bobID) = try makeService()
        defer { cleanup(bobID) }

        let payload = randomBytes(300)
        let sealed = try alice.seal(payload, to: bob.localKeyAgreementPublicKey)
        // Legacy ciphertext length tracks the plaintext exactly — no framing, no padding.
        #expect(sealed.count == 32 + 12 + payload.count + 16)
        #expect(try bob.open(sealed, from: alice.localKeyAgreementPublicKey) == payload)
    }
}
