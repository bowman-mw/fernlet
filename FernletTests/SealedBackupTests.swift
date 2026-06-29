import ProximityKit
import Foundation
import Security
import CryptoKit
import FernletFoundation
import Testing
import FernletDomainModel
import CloudKitSync
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct SealedBackupTests {
    /// The SEAL path now provisions the backup-escrow key lazily (WS-1): `ensureProvisioned` no longer
    /// mints it, so a test that wants to seal must mint/adopt it first, exactly as the production
    /// enable path does via `SealedBackupCoordinator`.
    private func makeSealingIdentity(_ serviceID: String) throws -> IdentityService {
        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()
        identity.provisionBackupEscrowKeyForSealing()
        return identity
    }

    @Test func cryptoRoundTripRestoresPlaintext() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let identity = try makeSealingIdentity(serviceID)
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
        let identity = try makeSealingIdentity(serviceID)
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
        // Two independent devices each mint their OWN local escrow key (no synced key shared), so a
        // record sealed by `first` must not open under `second`.
        let first = try makeSealingIdentity(firstID)
        let second = try makeSealingIdentity(secondID)
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

        // First device enables a sealed backup → provisions (mints) the escrow key (WS-1 lazy path).
        let first = try makeSealingIdentity(firstID)

        // Copy ONLY the escrow key into the second keychain as a SYNCHRONIZABLE item (as iCloud Keychain
        // sync would), at the SAME content-addressed account, then provision the second identity —
        // `ensureProvisioned` Case 2 adopts the synced escrow while minting a fresh signing + KA pair.
        let escrowAccount = IdentityService.escrowKeychainAccount(forPublicKey: first.localBackupEscrowPublicKey)
        let escrowData = try #require(KeychainItem.load(account: escrowAccount, service: firstID))
        KeychainItem.store(
            escrowData, account: escrowAccount, service: secondID,
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
        let identity = try makeSealingIdentity(serviceID)
        let plaintext = Data("private archive".utf8)
        var record = try SealedBackupCrypto.seal(plaintext, payloadType: .sensitiveNotes, identityService: identity)
        // Simulate a pre-escrow-binding tag (unrelated bytes, not our escrow public key).
        record.keyAgreementPublicKey = Data(repeating: 0xAB, count: 32)

        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
    }

    /// Content-addressed coexistence + try-all-keys restore: a record sealed under a key that is still
    /// present but NOT the adopted/canonical one (e.g. during an unresolved cross-device escrow conflict)
    /// must still open. The old fixed-slot design could SILENTLY OVERWRITE that key, stranding the backup;
    /// content-addressing keeps it alive and `open` tries every surviving key (decrypt-first).
    @Test func recordSealedUnderSurvivingNonAdoptedEscrowKeyStillOpens() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        let otherID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer {
            KeychainItem.deleteAll(service: serviceID)
            KeychainItem.deleteAll(service: otherID)
        }
        // This device mints its OWN escrow key (local) and seals a record under it.
        let identity = try makeSealingIdentity(serviceID)
        let ownPub = identity.localBackupEscrowPublicKey
        let plaintext = Data("private archive".utf8)
        let record = try SealedBackupCrypto.seal(plaintext, payloadType: .periodData, identityService: identity)

        // A DIFFERENT device's escrow key syncs in at its own content-addressed slot → coexists with ours.
        let other = try makeSealingIdentity(otherID)
        let otherPub = other.localBackupEscrowPublicKey
        let otherAccount = IdentityService.escrowKeychainAccount(forPublicKey: otherPub)
        let otherData = try #require(KeychainItem.load(account: otherAccount, service: otherID))
        KeychainItem.store(otherData, account: otherAccount, service: serviceID,
                           accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true)

        // Reconcile sees two keys → conflict; the SYNCED other-device key is adopted as canonical, but our
        // record's key still survives in the keychain.
        #expect(ownPub != otherPub)
        #expect(identity.reconcileBackupEscrowKey() == .conflict)
        #expect(identity.localBackupEscrowPublicKey == otherPub)

        // Restore still works with no manual resolution: open tries every surviving key.
        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
    }

    /// Back-compat: a pre-content-addressing device stored its escrow key at the legacy FIXED account. Both
    /// the seal and open paths must still find it (the legacy account is read, never written, by this build).
    @Test func legacyFixedAccountEscrowKeyStillSealsAndOpens() throws {
        let serviceID = "com.fernlet.sealed-backup.test.\(UUID().uuidString)"
        defer { KeychainItem.deleteAll(service: serviceID) }
        let legacyKey = Curve25519.KeyAgreement.PrivateKey()
        KeychainItem.store(legacyKey.rawRepresentation, account: "backupEscrowPrivateKey", service: serviceID,
                           accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true)

        let identity = IdentityService(keychainService: serviceID)
        try identity.ensureProvisioned()   // Case 2: signing/KA absent, escrow present (legacy read) → adopt.
        #expect(identity.localBackupEscrowPublicKey == legacyKey.publicKey.rawRepresentation)

        let plaintext = Data("legacy archive".utf8)
        let record = try SealedBackupCrypto.seal(plaintext, payloadType: .sensitiveNotes, identityService: identity)
        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
    }
}
