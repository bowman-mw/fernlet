// IdentityServiceEscrowTests.swift
// FernletTests
//
// Escrow-key provisioning race fixes (Docs/Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md):
//   WS-1 — escrow generation is DEFERRED out of ensureProvisioned(); the open/restore path never mints.
//   WS-2 — a freshly minted escrow key is stored ThisDeviceOnly, never published as synchronizable
//          until a later launch confirms no conflict.
//   WS-3 — reconcileBackupEscrowKey() adopts/promotes non-silently and surfaces a divergent-key conflict.
//
// Content-addressed escrow slot (the residual eliminator): each escrow key is stored at a keychain
// account derived from a hash of its OWN public key (`IdentityService.escrowKeychainAccount`). Two
// different keys therefore occupy DIFFERENT accounts → distinct iCloud-Keychain slots that COEXIST,
// instead of resolving by "newest-modification-date wins" on one shared slot. A divergent key can no
// longer silently overwrite the genuine one; divergence becomes an additive, detectable `.conflict`.
//
// Every test uses a UUID-scoped Keychain service and cleans up in a defer block.

import ProximityKit
import Foundation
import FernletFoundation
import Testing
import CryptoKit
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct IdentityServiceEscrowTests {

    private let legacyEscrowAccount = "backupEscrowPrivateKey"

    private func makeService() -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.escrow.test.\(UUID().uuidString)"
        return (IdentityService(keychainService: serviceID), serviceID)
    }

    /// Every escrow keychain row (legacy fixed account + content-addressed accounts) under a service,
    /// tagged with whether it is a synchronizable row. Used to assert the FULL slot picture, not just one
    /// hard-coded account, now that keys live at content-addressed accounts.
    private func escrowRows(_ service: String) -> [(account: String, data: Data, synced: Bool)] {
        var rows: [(account: String, data: Data, synced: Bool)] = []
        for (account, data) in KeychainItem.loadAll(service: service, synchronizable: .synced)
        where account.hasPrefix(legacyEscrowAccount) {
            rows.append((account, data, true))
        }
        for (account, data) in KeychainItem.loadAll(service: service, synchronizable: .local)
        where account.hasPrefix(legacyEscrowAccount) {
            rows.append((account, data, false))
        }
        return rows
    }

    // MARK: - Content-addressed slot invariant

    @Test func escrowKeychainAccountIsContentAddressedAndDeterministic() {
        let pub1 = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let pub2 = Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
        let account1 = IdentityService.escrowKeychainAccount(forPublicKey: pub1)
        // Same key → same account (deterministic, so a device can re-find its own slot).
        #expect(account1 == IdentityService.escrowKeychainAccount(forPublicKey: pub1))
        // Different keys → DIFFERENT accounts → distinct, coexisting slots (the overwrite eliminator).
        #expect(account1 != IdentityService.escrowKeychainAccount(forPublicKey: pub2))
        #expect(account1.hasPrefix("backupEscrowPrivateKey.k."))
    }

    // MARK: - WS-1: deferred generation / open never mints

    @Test func ensureProvisionedDoesNotMintEscrowKey() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }

        try svc.ensureProvisioned()

        // Signing + KA exist, but NO escrow key was minted at ANY slot (deferred to enable time).
        #expect(KeychainItem.load(account: "signingPrivateKey", service: id) != nil)
        #expect(KeychainItem.load(account: "keyAgreementPrivateKey", service: id) != nil)
        #expect(escrowRows(id).isEmpty)
        #expect(svc.localBackupEscrowPublicKey.isEmpty)
        #expect(throws: IdentityError.notProvisioned) { try svc.sealedBackupKey() }
    }

    @Test func openPathNeverMintsEscrowKey() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()

        // The restore/open path: no key present → reports "not synced yet" and mints NOTHING.
        #expect(svc.loadBackupEscrowKeyForOpen() == false)
        #expect(escrowRows(id).isEmpty)
        #expect(svc.localBackupEscrowPublicKey.isEmpty)
        #expect(svc.sealedBackupKeyCandidates().isEmpty)
    }

    // MARK: - WS-2: seal path mints ThisDeviceOnly at a content-addressed slot

    @Test func provisionForSealingMintsLocalNotSynchronizable() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()

        let pub = svc.provisionBackupEscrowKeyForSealing()
        #expect(!pub.isEmpty)
        #expect(svc.localBackupEscrowPublicKey == pub)
        // Stored at the key's CONTENT-ADDRESSED account, as a device-only item, NOT synchronizable.
        let account = IdentityService.escrowKeychainAccount(forPublicKey: pub)
        #expect(account != legacyEscrowAccount)
        #expect(KeychainItem.load(account: account, service: id, synchronizable: .local) != nil)
        #expect(KeychainItem.load(account: account, service: id, synchronizable: .synced) == nil)
        // Exactly one escrow row exists, and it is device-only (the worst-case blast radius reducer).
        #expect(escrowRows(id).count == 1)
        #expect(escrowRows(id).allSatisfy { !$0.synced })
        // The minted key is usable for sealing.
        #expect((try? svc.sealedBackupKey()) != nil)
    }

    @Test func provisionForSealingAdoptsExistingSyncedKeyInsteadOfMinting() throws {
        let (origin, originID) = makeService()
        defer { KeychainItem.deleteAll(service: originID) }
        try origin.ensureProvisioned()
        let originPub = origin.provisionBackupEscrowKeyForSealing()
        let originAccount = IdentityService.escrowKeychainAccount(forPublicKey: originPub)

        // Simulate the origin's escrow key having synced into a fresh device's keychain (same account).
        let (fresh, freshID) = makeService()
        defer { KeychainItem.deleteAll(service: freshID) }
        let escrowData = try #require(KeychainItem.load(account: originAccount, service: originID))
        #expect(KeychainItem.store(escrowData, account: originAccount, service: freshID,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)

        try fresh.ensureProvisioned()
        let freshPub = fresh.provisionBackupEscrowKeyForSealing()

        // Adopts the synced key (same public key) rather than minting a divergent one — no local row added.
        #expect(freshPub == originPub)
        #expect(escrowRows(freshID).filter { !$0.synced }.isEmpty)
    }

    // MARK: - WS-3: reconcile

    @Test func reconcileReportsNoEscrowWhenAbsent() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()

        #expect(svc.reconcileBackupEscrowKey() == .noEscrow)
    }

    @Test func reconcilePromotesLocalKeyToSynchronizable() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()
        let pub = svc.provisionBackupEscrowKeyForSealing()   // mints LOCAL only
        let account = IdentityService.escrowKeychainAccount(forPublicKey: pub)

        // A later launch with no conflicting key → promote (publish) it at its content-addressed account.
        #expect(svc.reconcileBackupEscrowKey() == .promotedLocal)
        #expect(KeychainItem.load(account: account, service: id, synchronizable: .synced) != nil)
        #expect(KeychainItem.load(account: account, service: id, synchronizable: .local) == nil)
        // Same key bytes (public key) preserved across the promotion — restore still works.
        #expect(svc.localBackupEscrowPublicKey == pub)
    }

    @Test func reconcileAdoptsSyncedKeyWhenOnlySyncedPresent() throws {
        let (origin, originID) = makeService()
        defer { KeychainItem.deleteAll(service: originID) }
        try origin.ensureProvisioned()
        let originPub = origin.provisionBackupEscrowKeyForSealing()
        let originAccount = IdentityService.escrowKeychainAccount(forPublicKey: originPub)
        let escrowData = try #require(KeychainItem.load(account: originAccount, service: originID))

        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        #expect(KeychainItem.store(escrowData, account: originAccount, service: id,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)
        try svc.ensureProvisioned()

        #expect(svc.reconcileBackupEscrowKey() == .usingSynced)
        #expect(svc.localBackupEscrowPublicKey == originPub)
    }

    @Test func reconcileDetectsConflictWithoutOverwritingEitherKey() throws {
        // The CORE residual test. A genuine cross-device conflict: a synced key (from another device) AND a
        // divergent local key both present. Under content-addressing they land on DIFFERENT accounts, so
        // injecting the synced key CANNOT touch the local one (no shared slot, no newest-wins overwrite).
        // Reconcile must surface .conflict and leave BOTH rows intact.
        let (other, otherID) = makeService()
        defer { KeychainItem.deleteAll(service: otherID) }
        try other.ensureProvisioned()
        let otherPub = other.provisionBackupEscrowKeyForSealing()
        let otherAccount = IdentityService.escrowKeychainAccount(forPublicKey: otherPub)
        let syncedKeyData = try #require(KeychainItem.load(account: otherAccount, service: otherID))

        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()
        let localPub = svc.provisionBackupEscrowKeyForSealing()                       // local (divergent) key
        let localAccount = IdentityService.escrowKeychainAccount(forPublicKey: localPub)
        let localKeyData = try #require(KeychainItem.load(account: localAccount, service: id, synchronizable: .local))
        #expect(localAccount != otherAccount)
        #expect(syncedKeyData != localKeyData)
        // The DIFFERENT synced key arrives at ITS OWN content-addressed account — coexists with the local one.
        #expect(KeychainItem.store(syncedKeyData, account: otherAccount, service: id,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)

        #expect(svc.reconcileBackupEscrowKey() == .conflict)
        // Both rows survive at their distinct accounts — nothing silently overwritten.
        #expect(KeychainItem.load(account: otherAccount, service: id, synchronizable: .synced) == syncedKeyData)
        #expect(KeychainItem.load(account: localAccount, service: id, synchronizable: .local) == localKeyData)
        // The full set is visible to restore (both keys), so the genuine key is never stranded.
        #expect(svc.sealedBackupKeyCandidates().count == 2)
    }

    @Test func adoptSyncedKeyResolvesConflict() throws {
        let (other, otherID) = makeService()
        defer { KeychainItem.deleteAll(service: otherID) }
        try other.ensureProvisioned()
        let syncedPub = other.provisionBackupEscrowKeyForSealing()
        let syncedAccount = IdentityService.escrowKeychainAccount(forPublicKey: syncedPub)
        let syncedKeyData = try #require(KeychainItem.load(account: syncedAccount, service: otherID))

        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()
        let localPub = svc.provisionBackupEscrowKeyForSealing()
        let localAccount = IdentityService.escrowKeychainAccount(forPublicKey: localPub)
        #expect(KeychainItem.store(syncedKeyData, account: syncedAccount, service: id,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)
        #expect(svc.reconcileBackupEscrowKey() == .conflict)

        // User confirms switching to the other device's key: adopt synced, drop the divergent local copy.
        let adopted = svc.adoptSyncedBackupEscrowKey()
        #expect(adopted == syncedPub)
        #expect(svc.localBackupEscrowPublicKey == syncedPub)
        #expect(KeychainItem.load(account: localAccount, service: id, synchronizable: .local) == nil)
        // The synced (authoritative) key is never deleted by adoption.
        #expect(KeychainItem.load(account: syncedAccount, service: id, synchronizable: .synced) == syncedKeyData)
        // A second reconcile is now clean.
        #expect(svc.reconcileBackupEscrowKey() == .usingSynced)
    }

    // MARK: - Back-compat: legacy fixed-account escrow key

    @Test func reconcileAdoptsLegacyFixedAccountKey() throws {
        // A pre-content-addressing device synced its escrow key at the legacy FIXED account. A new build
        // must still read & adopt it (no migration required for a pure new-build fleet — the legacy slot is
        // never written again, so it is never overwritten).
        let legacyKey = Curve25519.KeyAgreement.PrivateKey()
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        #expect(KeychainItem.store(legacyKey.rawRepresentation, account: legacyEscrowAccount, service: id,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)
        try svc.ensureProvisioned()

        #expect(svc.reconcileBackupEscrowKey() == .usingSynced)
        #expect(svc.localBackupEscrowPublicKey == legacyKey.publicKey.rawRepresentation)
        #expect((try? svc.sealedBackupKey()) != nil)
    }

    @Test func reconcileMigratesLegacySyncedKeyToContentAddressedSlot() throws {
        // A genuine legacy-origin synced key is ADDITIVELY migrated onto its overwrite-immune content-
        // addressed slot, while the legacy row is left intact for old-build back-compat.
        let legacyKey = Curve25519.KeyAgreement.PrivateKey()
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        #expect(KeychainItem.store(legacyKey.rawRepresentation, account: legacyEscrowAccount, service: id,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)
        try svc.ensureProvisioned()

        #expect(svc.reconcileBackupEscrowKey() == .usingSynced)
        let caAccount = IdentityService.escrowKeychainAccount(forPublicKey: legacyKey.publicKey.rawRepresentation)
        // Migrated: the key now ALSO lives at its content-addressed synced slot...
        #expect(KeychainItem.load(account: caAccount, service: id, synchronizable: .synced) == legacyKey.rawRepresentation)
        // ...and the legacy row is left intact (additive, never deleted — old builds keep reading it).
        #expect(KeychainItem.load(account: legacyEscrowAccount, service: id, synchronizable: .synced) == legacyKey.rawRepresentation)
        // Coalesced to ONE candidate — no false conflict, zero-config recovery preserved.
        #expect(svc.sealedBackupKeyCandidates().count == 1)
        // Idempotent: a second reconcile stays .usingSynced (contentAddressed now true → no re-migrate).
        #expect(svc.reconcileBackupEscrowKey() == .usingSynced)
    }

    // MARK: - Integrity guard

    @Test func gatherRejectsKeyStoredAtForeignContentAddressedAccount() throws {
        // Defense-in-depth: a content-addressed row whose account does NOT equal hash(its own public key)
        // — a corrupted/foreign/misfiled value — is rejected outright, never surfaced as a usable key.
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()
        let keyA = Curve25519.KeyAgreement.PrivateKey()
        let keyB = Curve25519.KeyAgreement.PrivateKey()
        // Plant key A's bytes at the CA account DERIVED FROM key B's public key (account ≠ hash(keyA.pub)).
        let foreignAccount = IdentityService.escrowKeychainAccount(forPublicKey: keyB.publicKey.rawRepresentation)
        #expect(KeychainItem.store(keyA.rawRepresentation, account: foreignAccount, service: id,
                                  accessibility: kSecAttrAccessibleAfterFirstUnlock,
                                  synchronizable: true) == errSecSuccess)

        #expect(svc.reconcileBackupEscrowKey() == .noEscrow)
        #expect(svc.sealedBackupKeyCandidates().isEmpty)
        #expect(svc.localBackupEscrowPublicKey.isEmpty)
    }
}
