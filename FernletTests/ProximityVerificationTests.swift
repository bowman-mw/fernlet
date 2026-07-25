// ProximityVerificationTests.swift
// FernletTests
//
// QR verification ceremony (bitchat adoptions Increment 4): the signed verify-QR URL round trip,
// freshness + tamper rejection, base64url edge cases, and the challenge/response transcript
// signature. Mesh-flow integration (slot state machine) is exercised on-device; these pin the
// crypto contract. UUID-scoped keychain per IdentityServiceTests convention.

import Foundation
import Testing
import CryptoKit
import ProximityKit
import FernletFoundation
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct ProximityVerificationTests {

    private func makeIdentity() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: serviceID)
        try service.ensureProvisioned()
        return (service, serviceID)
    }

    @Test func verifyQRRoundTripsAndValidates() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }

        let made = try ProximityVerifyQR.makeURL(identity: identity)
        #expect(made.url.scheme == "fernlet")
        #expect(made.nonce.count == 16)

        let parsed = try #require(ProximityVerifyQR.parse(made.url))
        #expect(parsed.signingPublicKey == identity.localSigningPublicKey)
        #expect(parsed.keyAgreementPublicKey == identity.localKeyAgreementPublicKey)
        #expect(parsed.nonce == made.nonce)
        #expect(ProximityVerifyQR.isValid(parsed))
    }

    @Test func verifyQRRejectsTamperStalenessAndForeignURLs() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let made = try ProximityVerifyQR.makeURL(identity: identity)
        let parsed = try #require(ProximityVerifyQR.parse(made.url))

        // Stale: outside the ±5 min freshness window in either direction.
        let past = Date(timeIntervalSince1970: TimeInterval(parsed.timestamp) + ProximityVerifyQR.freshnessWindow + 60)
        #expect(!ProximityVerifyQR.isValid(parsed, at: past))
        let future = Date(timeIntervalSince1970: TimeInterval(parsed.timestamp) - ProximityVerifyQR.freshnessWindow - 60)
        #expect(!ProximityVerifyQR.isValid(parsed, at: future))

        // Tamper: a swapped key agreement key breaks the signature.
        let (mallory, malloryID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: malloryID) }
        let swapped = ProximityVerifyQR.Payload(
            version: parsed.version,
            signingPublicKey: parsed.signingPublicKey,
            keyAgreementPublicKey: mallory.localKeyAgreementPublicKey,
            timestamp: parsed.timestamp,
            nonce: parsed.nonce,
            signature: parsed.signature
        )
        #expect(!ProximityVerifyQR.isValid(swapped))

        // Foreign URLs never parse.
        #expect(ProximityVerifyQR.parse(URL(string: "https://example.com/verify?d=abc")!) == nil)
        #expect(ProximityVerifyQR.parse(URL(string: "fernlet://other?d=abc")!) == nil)
    }

    @Test func base64URLSurvivesPaddingVariants() {
        for length in 1...8 {
            let data = Data((0..<length).map { UInt8($0 * 37 % 251) })
            let encoded = ProximityVerifyQR.base64URLEncode(data)
            #expect(!encoded.contains("="), "base64url must be unpadded")
            #expect(ProximityVerifyQR.base64URLDecode(encoded) == data)
        }
    }

    @Test func responseTranscriptSignatureBindsScannerAndNonces() throws {
        let (displayer, displayerID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: displayerID) }
        let (scanner, scannerID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: scannerID) }

        let qrNonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let challengeNonce = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })

        let message = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: scanner.localKeyAgreementPublicKey,
            challengeNonce: challengeNonce,
            qrNonce: qrNonce
        )
        let signature = try displayer.sign(message)
        #expect(IdentityService.verify(signature, of: message, by: displayer.localSigningPublicKey))

        // Any transcript substitution breaks it: different scanner, nonce, or signer.
        let otherScannerMessage = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: displayer.localKeyAgreementPublicKey,
            challengeNonce: challengeNonce,
            qrNonce: qrNonce
        )
        #expect(!IdentityService.verify(signature, of: otherScannerMessage, by: displayer.localSigningPublicKey))
        let otherNonceMessage = ProximityVerifySignature.message(
            scannerKeyAgreementPublicKey: scanner.localKeyAgreementPublicKey,
            challengeNonce: qrNonce,
            qrNonce: challengeNonce
        )
        #expect(!IdentityService.verify(signature, of: otherNonceMessage, by: displayer.localSigningPublicKey))
        #expect(!IdentityService.verify(signature, of: message, by: scanner.localSigningPublicKey))
    }
}
