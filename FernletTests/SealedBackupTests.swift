import ProximityKit
import Foundation
import Security
import FernletFoundation
import Testing
import FernletDomainModel
import CloudKitSync
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

    /// Cross-device restore: the backup-escrow key syncs via iCloud Keychain while the proximity KA key
    /// is regenerated on the new device. Binding on the escrow key (not the per-device KA) must let the
    /// new-device identity open a backup sealed by the original device. (Regression test for the
    /// escrow-binding fix; before it, this failed closed with keyAgreementIdentityMismatch.)
    @Test func crossDeviceRestoreWithSyncedEscrowKeySucceeds() throws {
        let firstID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        let secondID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer {
            KeychainItem.deleteAll(service: firstID)
            KeychainItem.deleteAll(service: secondID)
        }

        let first = IdentityService(keychainService: firstID)
        try first.ensureProvisioned()

        // Copy ONLY the escrow key into the second keychain (as iCloud Keychain sync would), then
        // provision the second identity — it adopts the synced escrow but mints a fresh signing + KA pair.
        let escrowData = try #require(KeychainItem.load(account: "backupEscrowPrivateKey", service: firstID))
        KeychainItem.store(
            escrowData, account: "backupEscrowPrivateKey", service: secondID,
            accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true
        )
        let second = IdentityService(keychainService: secondID)
        try second.ensureProvisioned()

        // Same escrow identity, DIFFERENT proximity KA — the exact new-device condition.
        #expect(first.localBackupEscrowPublicKey == second.localBackupEscrowPublicKey)
        #expect(first.localKeyAgreementPublicKey != second.localKeyAgreementPublicKey)

        let plaintext = Data("private archive".utf8)
        let record = try SealedBackupCrypto.seal(plaintext, payloadType: .periodData, identityService: first)
        #expect(try SealedBackupCrypto.open(record, identityService: second) == plaintext)
    }

    /// A record sealed with OUR escrow key but carrying a stale/foreign keyAgreementPublicKey tag (e.g. an
    /// early record still tagged with the per-device proximity KA key) must still open — the AES-GCM
    /// authentication under the escrow key is the real ownership boundary; the tag is only an
    /// error-classification hint. (Would throw keyAgreementIdentityMismatch under a hard tag guard.)
    @Test func recordWithStaleTagButOurEscrowKeyStillOpens() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        let plaintext = Data("private archive".utf8)
        var record = try SealedBackupCrypto.seal(plaintext, payloadType: .sensitiveNotes, identityService: identity)
        // Simulate a pre-escrow-binding tag (unrelated bytes, not our escrow public key).
        record.keyAgreementPublicKey = Data(repeating: 0xAB, count: 32)

        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
    }
}
