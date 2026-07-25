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
