// IdentityServiceTests.swift
// FernletTests
//
// Tests for IdentityService (Phase 7.1).
// Every test uses a UUID-scoped Keychain service and cleans up in a defer block
// so tests never touch each other's state and never reach the production service.

import Foundation
import FernletFoundation
import Testing
import CryptoKit
import FernletDomainModel
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct IdentityServiceTests {

    // MARK: - Harness helpers

    private func makeService() -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.test.\(UUID().uuidString)"
        return (IdentityService(keychainService: serviceID), serviceID)
    }

    private func cleanup(_ serviceID: String) {
        KeychainItem.deleteAll(service: serviceID)
    }

    // MARK: - Provisioning

    @Test func ensureProvisionedCreatesIdentityOnFirstCall() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }

        #expect(KeychainItem.load(account: "signingPrivateKey", service: id) == nil,
                "Keychain should be empty before provisioning")

        try svc.ensureProvisioned()

        #expect(KeychainItem.load(account: "signingPrivateKey", service: id) != nil)
        #expect(KeychainItem.load(account: "keyAgreementPrivateKey", service: id) != nil)
        #expect(!svc.localSigningPublicKey.isEmpty)
        #expect(!svc.localKeyAgreementPublicKey.isEmpty)
    }

    @Test func ensureProvisionedIsIdempotent() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }

        try svc.ensureProvisioned()
        let pubKey1 = svc.localSigningPublicKey
        let kaKey1  = svc.localKeyAgreementPublicKey

        try svc.ensureProvisioned()

        #expect(svc.localSigningPublicKey == pubKey1)
        #expect(svc.localKeyAgreementPublicKey == kaKey1)
    }

    @Test func ensureProvisionedLoadsExistingIdentityFromKeychain() throws {
        let (svc1, id) = makeService()
        defer { cleanup(id) }
        try svc1.ensureProvisioned()
        let pubKey1 = svc1.localSigningPublicKey

        let svc2 = IdentityService(keychainService: id)
        try svc2.ensureProvisioned()

        #expect(svc2.localSigningPublicKey == pubKey1,
                "New instance should load the same identity from Keychain")
    }

    // MARK: - Signing

    @Test func signAndVerifyRoundTrip() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }
        try svc.ensureProvisioned()

        let data = Data("hello world".utf8)
        let sig  = try svc.sign(data)

        #expect(IdentityService.verify(sig, of: data, by: svc.localSigningPublicKey))
    }

    @Test func verifyRejectsTamperedData() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }
        try svc.ensureProvisioned()

        let data = Data("hello world".utf8)
        let sig  = try svc.sign(data)

        var tampered = data
        tampered[0] ^= 0xFF

        #expect(!IdentityService.verify(sig, of: tampered, by: svc.localSigningPublicKey))
    }

    @Test func verifyRejectsWrongPublicKey() throws {
        let (svc1, id1) = makeService()
        defer { cleanup(id1) }
        try svc1.ensureProvisioned()

        let (svc2, id2) = makeService()
        defer { cleanup(id2) }
        try svc2.ensureProvisioned()

        let data = Data("hello".utf8)
        let sig  = try svc1.sign(data)

        #expect(!IdentityService.verify(sig, of: data, by: svc2.localSigningPublicKey))
    }

    // MARK: - Fingerprint

    @Test func localFingerprintIsStable() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }
        try svc.ensureProvisioned()

        #expect(svc.localFingerprint == svc.localFingerprint)
        #expect(!svc.localFingerprint.isEmpty)
    }

    @Test func localFingerprintIs16HexChars() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }
        try svc.ensureProvisioned()

        let fp = svc.localFingerprint
        #expect(fp.count == 16)
        #expect(fp.allSatisfy { $0.isHexDigit })
    }

    @Test func fingerprintMatcherAcceptsLegacyEightCharacterPrefix() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }
        try svc.ensureProvisioned()

        let canonical = svc.localFingerprint
        let legacy = String(canonical.prefix(8))
        #expect(IdentityService.fingerprintsMatch(canonical, legacy))
        #expect(IdentityService.fingerprintsMatch(legacy, canonical))
        #expect(!IdentityService.fingerprintsMatch(canonical, "deadbeef"))
    }

    @Test func fingerprintOfDifferentKeysDiffers() {
        var fingerprints = Set<String>()
        for _ in 0..<100 {
            let key = Curve25519.Signing.PrivateKey()
            fingerprints.insert(IdentityService.fingerprint(of: key.publicKey.rawRepresentation))
        }
        #expect(fingerprints.count == 100,
                "All 100 randomly generated keys should produce distinct fingerprints")
    }

    // MARK: - Seal / Open

    @Test func sealOpenRoundTrip() throws {
        let (alice, aliceID) = makeService()
        defer { cleanup(aliceID) }
        try alice.ensureProvisioned()

        let (bob, bobID) = makeService()
        defer { cleanup(bobID) }
        try bob.ensureProvisioned()

        let plaintext = Data("secret message".utf8)
        let sealed = try alice.seal(plaintext, to: bob.localKeyAgreementPublicKey)
        let opened = try bob.open(sealed, from: alice.localKeyAgreementPublicKey)

        #expect(opened == plaintext)
    }

    @Test func openRejectsTamperedCiphertext() throws {
        let (alice, aliceID) = makeService()
        defer { cleanup(aliceID) }
        try alice.ensureProvisioned()

        let (bob, bobID) = makeService()
        defer { cleanup(bobID) }
        try bob.ensureProvisioned()

        var sealed = try alice.seal(Data("secret".utf8), to: bob.localKeyAgreementPublicKey)
        sealed[sealed.count - 1] ^= 0xFF

        #expect(throws: IdentityError.openFailed) {
            try bob.open(sealed, from: alice.localKeyAgreementPublicKey)
        }
    }

    @Test func openRejectsWrongRecipientKey() throws {
        let (bob, bobID) = makeService()
        defer { cleanup(bobID) }
        try bob.ensureProvisioned()

        let (carol, carolID) = makeService()
        defer { cleanup(carolID) }
        try carol.ensureProvisioned()

        let (eve, eveID) = makeService()
        defer { cleanup(eveID) }
        try eve.ensureProvisioned()

        // Bob seals to Carol; Eve tries to open
        let sealed = try bob.seal(Data("for carol".utf8), to: carol.localKeyAgreementPublicKey)

        #expect(throws: IdentityError.openFailed) {
            try eve.open(sealed, from: bob.localKeyAgreementPublicKey)
        }
    }

    // MARK: - Wipe

    @Test func wipeRemovesAllKeyMaterial() throws {
        let (svc, id) = makeService()
        defer { cleanup(id) }
        try svc.ensureProvisioned()
        let fp1 = svc.localFingerprint

        try svc.wipe()

        #expect(svc.localSigningPublicKey.isEmpty, "Public key should be cleared after wipe")
        #expect(KeychainItem.load(account: "signingPrivateKey", service: id) == nil,
                "Keychain entry should be gone after wipe")

        try svc.ensureProvisioned()
        let fp2 = svc.localFingerprint

        #expect(fp1 != fp2, "Fresh identity after wipe should have a different fingerprint")
    }
}
