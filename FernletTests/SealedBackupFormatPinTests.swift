import CloudKitSync
import CryptoKit
import Foundation
import ProximityKit
import Security
import Testing
import FernletFoundation
@testable import Fernlet

/// Pins the sealed-backup at-rest format end-to-end so it cannot drift silently: **both record
/// formats** of the escrow HKDF derivation (v1 — `IdentityService.sealedBackupKey()`, whose info
/// string and empty salt are part of the format; and v2 — the per-generation salted derivation
/// under `com.fernlet.sealed-backup.v2`) plus the AAD v2 byte layout (`SealedBackupCrypto`), which
/// is shared by both record formats and deliberately unchanged by v2.
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
    /// A fixed 32-byte stand-in for a minted per-generation salt (bytes 0x40…0x5f), so the v2
    /// derivation has a known answer the way v1 does.
    private let knownKeySalt = Data((0..<32).map { UInt8(0x40 &+ $0) })
    /// Known-answer: HKDF-SHA256(plantedEscrowRaw, salt: knownKeySalt,
    /// info: "com.fernlet.sealed-backup.v2", 32). Record format v2.
    private let pinnedSealedBackupKeyV2Hex = "551e26e42d80c7104ec6a6bee8b6c11bf7cbb3dd07696032f17ef8b35120c9a8"

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

    // MARK: Pins the RECORD FORMAT V2 derivation (per-generation salt + versioned info string) to its
    // own known-answer vector, and proves the two formats are genuinely domain-separated. Drift here
    // strands every v2 backup; a collision with the v1 answer would mean the salt/info never took.
    @Test func escrowSealedBackupKeyV2DerivationIsPinned() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        let v2 = try identity.sealedBackupKey(formatVersion: 2, salt: knownKeySalt)
        #expect(v2.withUnsafeBytes { Data($0) }.hexEncoded == pinnedSealedBackupKeyV2Hex,
                "v2 sealed-backup key derivation drifted — existing v2 sealed backups would stop opening")

        // Deterministic, and NOT the v1 key: the salt + versioned info actually reach the HKDF.
        let again = try identity.sealedBackupKey(formatVersion: 2, salt: knownKeySalt)
        #expect(again.withUnsafeBytes { Data($0) } == v2.withUnsafeBytes { Data($0) })
        #expect(v2.withUnsafeBytes { Data($0) }.hexEncoded != pinnedSealedBackupKeyHex,
                "v2 derived the v1 key — the per-generation salt bought nothing")

        // The no-argument entry point is still v1, byte-for-byte. The seven no-arg callers and every
        // record already in users' CloudKit databases depend on this.
        let v1 = try identity.sealedBackupKey()
        #expect(v1.withUnsafeBytes { Data($0) }.hexEncoded == pinnedSealedBackupKeyHex)
        #expect(try identity.sealedBackupKey(formatVersion: 1, salt: knownKeySalt)
            .withUnsafeBytes { Data($0) }.hexEncoded == pinnedSealedBackupKeyHex,
                "a salt leaked into the v1 derivation — v1 records would stop opening")

        // A different salt is a different key: that IS the blast-radius bound.
        let otherSalt = Data((0..<32).map { UInt8(0x90 &+ $0) })
        #expect(try identity.sealedBackupKey(formatVersion: 2, salt: otherSalt)
            .withUnsafeBytes { Data($0) } != v2.withUnsafeBytes { Data($0) })
    }

    // MARK: The candidate SET is version-independent — the format changes the derived keys, never which
    // escrow identities exist. The open path classifies failures off those public keys, so a version
    // that dropped or added candidates would misreport "someone else's record".
    @Test func candidateSetIsUnchangedByFormatVersion() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        let v1 = identity.sealedBackupKeyCandidates()
        let v2 = identity.sealedBackupKeyCandidates(formatVersion: 2, salt: knownKeySalt)
        #expect(!v1.isEmpty)
        #expect(v1.count == v2.count, "the record format changed WHICH escrow candidates exist")
        #expect(v1.map(\.publicKey) == v2.map(\.publicKey))
        #expect(zip(v1, v2).allSatisfy {
            $0.key.withUnsafeBytes { Data($0) } != $1.key.withUnsafeBytes { Data($0) }
        }, "v2 candidates derived the v1 keys — the salt never reached the candidate derivation")
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

    // MARK: The v2 counterpart: seal through the production path WITH a known salt, then open the
    // record independently with the pinned v2 key and the SAME byte-for-byte AAD as v1. The AAD is
    // deliberately untouched by the record-format bump (the salt is a key-derivation input, not an
    // authenticated field), so this test failing means either the v2 key or the AAD moved.
    @Test func sealedBackupV2StampsSaltAndLeavesTheAADUnchanged() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        let plaintext = Data("format-pin payload v2".utf8)
        let updatedAt = Date(timeIntervalSince1970: 1_700_000_000.75)  // fractional → floored
        let generation: Int64 = 41
        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .periodData,
            identityService: identity,
            chunkIndex: 3,
            chunkCount: 7,
            updatedAt: updatedAt,
            generation: generation,
            keySalt: knownKeySalt
        )

        #expect(record.formatVersion == 2, "a salted seal must stamp record format 2")
        #expect(record.keySalt == knownKeySalt, "the salt must travel on the record or nothing reopens")

        // Identical construction to the v1 pin — no salt, no version, nothing new in the AAD.
        var aad = Data("fernlet.sealed-backup.aad.v2".utf8) + Data([0])
        aad += Data("periodData".utf8) + Data([0])
        aad += record.signingPublicKey + Data([0])
        aad += Data("3/7".utf8) + Data([0])
        aad += withUnsafeBytes(of: UInt64(bitPattern: generation).bigEndian) { Data($0) }
        aad += withUnsafeBytes(of: UInt64(bitPattern: Int64(1_700_000_000)).bigEndian) { Data($0) }

        let pinnedV2Key = SymmetricKey(data: Data(hexEncoded: pinnedSealedBackupKeyV2Hex))
        let box = try AES.GCM.SealedBox(
            nonce: AES.GCM.Nonce(data: record.nonce),
            ciphertext: record.ciphertext,
            tag: record.tag
        )
        #expect(try AES.GCM.open(box, using: pinnedV2Key, authenticating: aad) == plaintext,
                "v2 key derivation or the AAD layout drifted — v2 sealed records would fail to restore")

        // The v1 key must NOT open a v2 record: the formats are separate keys, which is the point.
        let pinnedV1Key = SymmetricKey(data: Data(hexEncoded: pinnedSealedBackupKeyHex))
        #expect((try? AES.GCM.open(box, using: pinnedV1Key, authenticating: aad)) == nil,
                "a v2 record opened under the v1 key — the blast-radius bound is not real")

        #expect(record.keyAgreementPublicKey == identity.localBackupEscrowPublicKey)
        #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext)
    }

    // MARK: THE COEXISTENCE RULE, proved on one identity: a v1 record (no salt, no version — exactly
    // what is sitting in users' CloudKit today) and a v2 record both open through the same production
    // `open`, because each record carries the format its key was derived under. If this ever fails,
    // shipping v2 stranded every existing backup.
    @Test func v1AndV2RecordsBothOpenOnOneIdentity() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        let legacyPlaintext = Data("sealed before v2 existed".utf8)
        let legacy = try SealedBackupCrypto.seal(
            legacyPlaintext,
            payloadType: .sensitiveNotes,
            identityService: identity,
            generation: 7
        )
        #expect(legacy.formatVersion == 1)
        #expect(legacy.keySalt.isEmpty, "an unsalted seal must stay v1 on the wire")

        let modernPlaintext = Data("sealed after v2 shipped".utf8)
        let modern = try SealedBackupCrypto.seal(
            modernPlaintext,
            payloadType: .sensitiveNotes,
            identityService: identity,
            generation: 8,
            keySalt: knownKeySalt
        )

        #expect(try SealedBackupCrypto.open(legacy, identityService: identity) == legacyPlaintext)
        #expect(try SealedBackupCrypto.open(modern, identityService: identity) == modernPlaintext)

        // The version SELECTS the derivation to try first; v1 is the last-resort retry. A v1-sealed
        // record wearing a v2 label + salt is exactly what a downlevel writer leaves behind (CloudKit
        // merges fields, so an old build's write cannot clear the previous v2 write's metadata), and it
        // must still open — the ciphertext is intact and only the unauthenticated label is wrong.
        var mislabeled = legacy
        mislabeled.formatVersion = 2
        mislabeled.keySalt = knownKeySalt
        #expect(try SealedBackupCrypto.open(mislabeled, identityService: identity) == legacyPlaintext,
                "a v1 record carrying stale v2 metadata must fall back to the v1 derivation")

        // The other direction stays fatal: no fallback can recover a salt that was dropped, so a v2
        // record relabelled v1 is unopenable. That is what keeps the label from being a downgrade lever.
        var stripped = modern
        stripped.formatVersion = 1
        stripped.keySalt = Data()
        #expect(throws: SealedBackupError.malformedRecord) {
            _ = try SealedBackupCrypto.open(stripped, identityService: identity)
        }
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

    // MARK: The same guard for record format v2: the per-generation salt must not become a second
    // secret the restoring device has to already hold. It rides on the record in the clear, so a fresh
    // device with only the synced escrow key still restores — the escrow key stays the ONLY input.
    @Test func v2RestoreNeedsOnlyTheEscrowKey() throws {
        let (sealingIdentity, sealingService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: sealingService) }
        let plaintext = Data("restore my v2 backup elsewhere".utf8)
        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: .sensitiveNotes,
            identityService: sealingIdentity,
            generation: 1,
            keySalt: knownKeySalt
        )
        #expect(record.formatVersion == 2)

        let (restoringIdentity, restoringService) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: restoringService) }
        #expect(try SealedBackupCrypto.open(record, identityService: restoringIdentity) == plaintext)
    }

    // MARK: EVERY payload type is pinned, not just the two that existed when v2 shipped. The rawValue
    // keys the CloudKit record name AND is bound into the AAD, so this walks `allCases` — a payload
    // added later without a pin would otherwise ship unverified, and renaming an existing one would
    // orphan every backup already in users' databases.
    @Test func everyPayloadTypeSealsAndOpensOnV2() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        // The rawValues are at-rest format. Spelled out literally so a rename is a failing diff here
        // rather than a silent orphaning of existing CloudKit records.
        #expect(Set(SealedBackupPayloadType.allCases.map(\.rawValue))
                == ["sensitiveNotes", "periodData", "journalNarratives", "intimacyLogs"])

        for payloadType in SealedBackupPayloadType.allCases {
            let plaintext = Data("payload for \(payloadType.rawValue)".utf8)
            let record = try SealedBackupCrypto.seal(
                plaintext,
                payloadType: payloadType,
                identityService: identity,
                generation: 3,
                keySalt: knownKeySalt
            )
            #expect(record.formatVersion == 2, "\(payloadType.rawValue) did not seal as record format v2")
            #expect(record.keySalt == knownKeySalt)
            #expect(try SealedBackupCrypto.open(record, identityService: identity) == plaintext,
                    "\(payloadType.rawValue) failed to round-trip on v2")
        }
    }

    // MARK: The payload type is AUTHENTICATED, so a chunk cannot be replayed as a different payload —
    // the property that keeps four separate backups from becoming one interchangeable pool. Proved by
    // relabelling a sealed journal record as intimacy and watching the open fail.
    @Test func aChunkCannotBeReplayedAsADifferentPayloadType() throws {
        let (identity, service) = try plantedIdentity()
        defer { KeychainItem.deleteAll(service: service) }

        let record = try SealedBackupCrypto.seal(
            Data("journal chunk".utf8),
            payloadType: .journalNarratives,
            identityService: identity,
            generation: 4,
            keySalt: knownKeySalt
        )
        var replayed = record
        replayed.payloadType = .intimacyLogs
        #expect(throws: SealedBackupError.malformedRecord) {
            _ = try SealedBackupCrypto.open(replayed, identityService: identity)
        }
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
