import CloudKitSync
import CryptoKit
import Foundation
import ProximityKit
import Security
import Testing
import FernletFoundation
@testable import Fernlet

/// Pins the sealed-backup at-rest format end-to-end so it cannot drift silently: the escrow
/// HKDF derivation (`IdentityService.sealedBackupKey()` — its info string and empty salt are
/// part of the record format) and the AAD v2 byte layout (`SealedBackupCrypto`).
///
/// Method: plant a KNOWN escrow private key in an isolated keychain service (the legacy fixed
/// account, which the escrow discovery still reads for back-compat), then drive the REAL
/// production seal path and open the produced record independently — with a key derived from
/// pinned constants and an AAD built byte-by-byte in this file. If either the derivation or the
/// AAD layout moves, the independent open fails loudly, because that drift would strand every
/// sealed backup already in users' CloudKit databases (Docs/Verifiability.md §2).
@MainActor
struct SealedBackupFormatPinTests {
    /// The known escrow private-key bytes planted in the keychain (X25519 accepts them verbatim;
    /// `rawRepresentation` round-trips them unchanged, which the derivation test re-proves).
    private let plantedEscrowRaw = Data((0..<32).map { UInt8($0 &+ 1) })
    /// Known-answer: HKDF-SHA256(plantedEscrowRaw, salt: empty, info: "com.fernlet.sealed-backup", 32).
    private let pinnedSealedBackupKeyHex = "84206218f042c043706ab10ee2f2de180d180958ae224d8ca54fa9fb7d5dc610"

    /// Builds an isolated IdentityService whose keychain holds the planted escrow key, fully
    /// provisioned for sealing. Callers must `KeychainItem.deleteAll` the returned service name.
    private func plantedIdentity() throws -> (identity: IdentityService, service: String) {
        let service = "com.fernlet.identity.test.formatpin.\(UUID().uuidString)"
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        KeychainItem.store(
            plantedEscrowRaw,
            account: "backupEscrowPrivateKey",
            service: service,
            accessibility: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            synchronizable: false
        )
        #expect(identity.loadBackupEscrowKeyForOpen(), "planted escrow key was not discovered")
        return (identity, service)
    }

    // MARK: Pins the escrow-derived sealed-backup key to a known-answer vector through the REAL
    // production derivation (private key loaded from the keychain → sealedBackupKey()). Any drift
    // in the HKDF info string, salt, or IKM handling fails here.
    @Test func escrowSealedBackupKeyDerivationIsPinned() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        let key = try identity.sealedBackupKey()
        let keyData = key.withUnsafeBytes { Data($0) }
        #expect(keyData.hexEncoded == pinnedSealedBackupKeyHex,
                "sealed-backup key derivation drifted — existing sealed backups would stop opening")
    }

    // MARK: Pins the AAD v2 byte layout end-to-end: seal through the production path, then open
    // the record INDEPENDENTLY with the pinned key and an AAD constructed byte-by-byte here
    // (version tag, NUL separators, chunk "i/c" text, big-endian UInt64 generation, big-endian
    // whole-second timestamp). Also proves the timestamp is floored, not rounded.
    @Test func sealedBackupAADv2ByteLayoutIsPinned() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        let plaintext = Data("format-pin payload".utf8)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000.75)  // fractional → floored
        let generation: Int64 = 41
        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .periodData,
            identityService: identity,
            chunkIndex: 3,
            chunkCount: 7,
            updatedAt: updatedAt,
            generation: generation
        )

        // Independent AAD construction — this IS the pinned layout. Do not derive it from the
        // production helper; the point is that two implementations agree.
        var aad = Data("fernlet.sealed-backup.aad.v2".utf8) + Data([0])
        aad += Data("periodData".utf8) + Data([0])
        aad += record.signingPublicKey + Data([0])
        aad += Data("3/7".utf8) + Data([0])
        aad += withUnsafeBytes(of: UInt64(bitPattern: generation).bigEndian) { Data($0) }
        aad += withUnsafeBytes(of: UInt64(bitPattern: Int64(1_700_000_000)).bigEndian) { Data($0) }

        let pinnedKey = SymmetricKey(data: Data(hexEncoded: pinnedSealedBackupKeyHex))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: record.nonce),
            ciphertext: record.ciphertext,
            tag: record.tag
        )
        let opened = try AES.GCM.open(box, using: pinnedKey, authenticating: aad)
        #expect(opened == plaintext,
                "AAD v2 layout or escrow key derivation drifted — sealed records would fail to restore")

        // The record must be identity-tagged with the ESCROW public key (the cross-device-stable
        // tag), and the production open path must accept its own record.
        #expect(record.keyAgreementPublicKey == identity.localBackupEscrowPublicKey)
        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
    }

    // MARK: RESTORE-PATH GUARD for the device-binding work: proves a sealed-backup record is
    // openable with the escrow key candidates ALONE — no lock content key, no install binding ID
    // involved — so device-binding the sealed columns cannot brick cross-device restore (the
    // backup ships escrow-sealed plaintext, never column ciphertext).
    @Test func restoreNeedsOnlyTheEscrowKey() throws {
        let (sealingIdentity, sealingService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: sealingService) }
        let record = try SealedBackupCrypto.seal(
            Data("restore me elsewhere".utf8),
            payloadType: .sensitiveNotes,
            identityService: sealingIdentity,
            generation: 1
        )

        // A brand-new "device": fresh proximity identity, fresh keychain — only the escrow key
        // has synced in (simulated by planting the same bytes).
        let (restoringIdentity, restoringService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: restoringService) }
        let opened = try SealedBackupCrypto.open(record, identityService: restoringIdentity)
        #expect(opened == Data("restore me elsewhere".utf8))
    }
}

private extension Data {
    /// Lowercase hex rendering for known-answer comparisons.
    var hexEncoded: String { map { String(format: "%02x", $0) }.joined() }

    /// Builds Data from a lowercase hex string (test fixture helper; even-length input assumed).
    init(hexEncoded: String) {
        var bytes: [UInt8] = []
        var index = hexEncoded.startIndex
        while index < hexEncoded.endIndex {
            let next = hexEncoded.index(index, offsetBy: 2)
            bytes.append(UInt8(hexEncoded[index..<next], radix: 16) ?? 0)
            index = next
        }
        self.init(bytes)
    }
}
