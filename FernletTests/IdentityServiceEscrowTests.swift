// IdentityServiceEscrowTests.swift
// FernletTests
//
// Escrow-key provisioning race fixes (Docs/Sealed-Backup-Escrow-Recovery-FollowUp-2026-06-28.md):
//   WS-1 — escrow generation is DEFERRED out of ensureProvisioned(); the open/restore path never mints.
//   WS-2 — a freshly minted escrow key is stored ThisDeviceOnly, never published as synchronizable
//          until a later launch confirms no conflict.
//   WS-3 — reconcileBackupEscrowKey() adopts/promotes non-silently and surfaces a divergent-key conflict.
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

    private let escrowAccount = "backupEscrowPrivateKey"

    private func makeService() -> (IdentityService, String) {
        let serviceID = "com.fernlet.identity.escrow.test.\(UUID().uuidString)"
        return (IdentityService(keychainService: serviceID), serviceID)
    }

    // MARK: - WS-1: deferred generation / open never mints

    @Test func ensureProvisionedDoesNotMintEscrowKey() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }

        try svc.ensureProvisioned()

        // Signing + KA exist, but NO escrow key was minted (deferred to enable time).
        #expect(KeychainItem.load(account: "signingPrivateKey", service: id) != nil)
        #expect(KeychainItem.load(account: "keyAgreementPrivateKey", service: id) != nil)
        #expect(KeychainItem.load(account: escrowAccount, service: id) == nil)
        #expect(svc.localBackupEscrowPublicKey.isEmpty)
        #expect(throws: IdentityError.notProvisioned) { try svc.sealedBackupKey() }
    }

    @Test func openPathNeverMintsEscrowKey() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()

        // The restore/open path: no key present → reports "not synced yet" and mints NOTHING.
        #expect(svc.loadBackupEscrowKeyForOpen() == false)
        #expect(KeychainItem.load(account: escrowAccount, service: id) == nil)
        #expect(svc.localBackupEscrowPublicKey.isEmpty)
    }

    // MARK: - WS-2: seal path mints ThisDeviceOnly

    @Test func provisionForSealingMintsLocalNotSynchronizable() throws {
        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()

        let pub = svc.provisionBackupEscrowKeyForSealing()
        #expect(!pub.isEmpty)
        #expect(svc.localBackupEscrowPublicKey == pub)
        // Stored as a device-only item, NOT as a synchronizable one (the worst-case blast radius reducer).
        #expect(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .local) != nil)
        #expect(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .synced) == nil)
        // The minted key is usable for sealing.
        #expect((try? svc.sealedBackupKey()) != nil)
    }

    @Test func provisionForSealingAdoptsExistingSyncedKeyInsteadOfMinting() throws {
        let (origin, originID) = makeService()
        defer { KeychainItem.deleteAll(service: originID) }
        try origin.ensureProvisioned()
        let originPub = origin.provisionBackupEscrowKeyForSealing()

        // Simulate the origin's escrow key having synced into a fresh device's keychain.
        let (fresh, freshID) = makeService()
        defer { KeychainItem.deleteAll(service: freshID) }
        let escrowData = try #require(KeychainItem.load(account: escrowAccount, service: originID))
        KeychainItem.store(escrowData, account: escrowAccount, service: freshID,
                           accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true)

        try fresh.ensureProvisioned()
        let freshPub = fresh.provisionBackupEscrowKeyForSealing()

        // Adopts the synced key (same public key) rather than minting a divergent one.
        #expect(freshPub == originPub)
        #expect(KeychainItem.load(account: escrowAccount, service: freshID, synchronizable: .local) == nil)
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

        // A later launch with no conflicting synced key → promote (publish) it.
        #expect(svc.reconcileBackupEscrowKey() == .promotedLocal)
        #expect(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .synced) != nil)
        #expect(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .local) == nil)
        // Same key bytes (public key) preserved across the promotion — restore still works.
        #expect(svc.localBackupEscrowPublicKey == pub)
    }

    @Test func reconcileAdoptsSyncedKeyWhenOnlySyncedPresent() throws {
        let (origin, originID) = makeService()
        defer { KeychainItem.deleteAll(service: originID) }
        try origin.ensureProvisioned()
        let originPub = origin.provisionBackupEscrowKeyForSealing()
        let escrowData = try #require(KeychainItem.load(account: escrowAccount, service: originID))

        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        KeychainItem.store(escrowData, account: escrowAccount, service: id,
                           accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true)
        try svc.ensureProvisioned()

        #expect(svc.reconcileBackupEscrowKey() == .usingSynced)
        #expect(svc.localBackupEscrowPublicKey == originPub)
    }

    @Test func reconcileDetectsConflictWithoutOverwritingEitherKey() throws {
        // A genuine cross-device conflict: a synced key (from another device) AND a divergent local key
        // both present. Reconcile must surface .conflict and overwrite NEITHER.
        let (other, otherID) = makeService()
        defer { KeychainItem.deleteAll(service: otherID) }
        try other.ensureProvisioned()
        _ = other.provisionBackupEscrowKeyForSealing()
        let syncedKeyData = try #require(KeychainItem.load(account: escrowAccount, service: otherID))

        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()
        _ = svc.provisionBackupEscrowKeyForSealing()                       // local (divergent) key
        let localKeyData = try #require(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .local))
        // Now a DIFFERENT key syncs in alongside the local one. iCloud Keychain adds the synchronizable
        // row without disturbing the device-only row, so inject with `replacing: .synced` (don't clobber
        // the local item) to reproduce the genuine two-row conflict.
        KeychainItem.store(syncedKeyData, account: escrowAccount, service: id,
                           accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true,
                           replacing: .synced)
        #expect(syncedKeyData != localKeyData)

        #expect(svc.reconcileBackupEscrowKey() == .conflict)
        // Both rows survive — nothing silently overwritten.
        #expect(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .synced) == syncedKeyData)
        #expect(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .local) == localKeyData)
    }

    @Test func adoptSyncedKeyResolvesConflict() throws {
        let (other, otherID) = makeService()
        defer { KeychainItem.deleteAll(service: otherID) }
        try other.ensureProvisioned()
        let syncedPub = other.provisionBackupEscrowKeyForSealing()
        let syncedKeyData = try #require(KeychainItem.load(account: escrowAccount, service: otherID))

        let (svc, id) = makeService()
        defer { KeychainItem.deleteAll(service: id) }
        try svc.ensureProvisioned()
        _ = svc.provisionBackupEscrowKeyForSealing()
        KeychainItem.store(syncedKeyData, account: escrowAccount, service: id,
                           accessibility: kSecAttrAccessibleAfterFirstUnlock, synchronizable: true,
                           replacing: .synced)
        #expect(svc.reconcileBackupEscrowKey() == .conflict)

        // User confirms switching to the other device's key: adopt synced, drop the divergent local copy.
        let adopted = svc.adoptSyncedBackupEscrowKey()
        #expect(adopted == syncedPub)
        #expect(svc.localBackupEscrowPublicKey == syncedPub)
        #expect(KeychainItem.load(account: escrowAccount, service: id, synchronizable: .local) == nil)
        // A second reconcile is now clean.
        #expect(svc.reconcileBackupEscrowKey() == .usingSynced)
    }
}
