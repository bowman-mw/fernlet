import Foundation
import Testing
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct SealedBackupTests {
    @Test func cryptoRoundTripRestoresPlaintext() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        let plaintext = Data("private archive".utf8)

        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .sensitiveNotes,
            identityService: identity
        )

        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
        #expect(record.ciphertext != plaintext)
    }

    @Test func tamperedCiphertextIsRejected() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        var record = try SealedBackupCrypto.seal(
            Data("private archive".utf8),
            payloadType: .periodData,
            identityService: identity
        )
        record.ciphertext[record.ciphertext.startIndex] ^= 0xff

        #expect(throws: SealedBackupError.malformedRecord) {
            try SealedBackupCrypto.open(record, identityService: identity)
        }
    }

    @Test func wrongKeyAgreementIdentityIsRejected() throws {
        let firstID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        let secondID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer {
            KeychainItem.deleteAll(service: firstID)
            KeychainItem.deleteAll(service: secondID)
        }
        let first = IdentityService(keychainService: firstID)
        let second = IdentityService(keychainService: secondID)
        try first.ensureProvisioned()
        try second.ensureProvisioned()
        let record = try SealedBackupCrypto.seal(
            Data("private archive".utf8),
            payloadType: .periodData,
            identityService: first
        )

        #expect(throws: SealedBackupError.keyAgreementIdentityMismatch) {
            try SealedBackupCrypto.open(record, identityService: second)
        }
    }
}
