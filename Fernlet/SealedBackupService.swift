import ProximityKit
import CryptoKit
import Foundation
import FernletDomainModel
import CloudKitSync

enum SealedBackupCrypto {
    @MainActor
    static func seal(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        identityService: IdentityService,
        chunkIndex: Int = 0,
        chunkCount: Int = 1,
        updatedAt: Date = Date()
    ) throws -> SealedBackupRecord {
        let key = try identityService.sealedBackupKey()
        let nonce = AES.GCM.Nonce()
        let signingPublicKey = identityService.localSigningPublicKey
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: authenticatedData(
                payloadType: payloadType,
                signingPublicKey: signingPublicKey,
                chunkIndex: chunkIndex,
                chunkCount: chunkCount
            )
        )
        return SealedBackupRecord(
            payloadType: payloadType,
            signingPublicKey: signingPublicKey,
            // Bind the record to the backup-ESCROW public key, not the proximity KA key. The escrow key
            // syncs via iCloud Keychain (stable across devices), so a backup sealed on one device is
            // recognized as "mine" and restorable on another; the proximity KA key is regenerated per
            // device and would otherwise make the open() guard reject a legitimate cross-device restore.
            keyAgreementPublicKey: identityService.localBackupEscrowPublicKey,
            nonce: nonce.data,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag,
            updatedAt: updatedAt,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
    }

    @MainActor
    static func open(_ record: SealedBackupRecord, identityService: IdentityService) throws -> Data {
        // The AES-GCM authentication under our escrow-derived key is the REAL ownership boundary: only a
        // record sealed with our backup-escrow key (which syncs via iCloud Keychain) can open. We attempt
        // decryption FIRST so a record still opens even if its `keyAgreementPublicKey` identity tag
        // predates the escrow-binding fix (e.g. an early record still tagged with the per-device proximity
        // KA key) or was written on another device — no stranding. The tag is consulted ONLY to choose a
        // clearer error when decryption fails: a record not tagged with our escrow identity is someone
        // else's (or unrelated); otherwise it is a tampered/corrupt record of ours.
        let key = try identityService.sealedBackupKey()
        do {
            let nonce = try AES.GCM.Nonce(data: record.nonce)
            let sealedBox = try AES.GCM.SealedBox(nonce: nonce, ciphertext: record.ciphertext, tag: record.tag)
            return try AES.GCM.open(
                sealedBox,
                using: key,
                authenticating: authenticatedData(
                    payloadType: record.payloadType,
                    signingPublicKey: record.signingPublicKey,
                    chunkIndex: record.chunkIndex,
                    chunkCount: record.chunkCount
                )
            )
        } catch {
            if record.keyAgreementPublicKey != identityService.localBackupEscrowPublicKey {
                throw SealedBackupError.keyAgreementIdentityMismatch
            }
            throw SealedBackupError.malformedRecord
        }
    }

    /// Binds the payload type, signing identity, and the record's position within its chunk set into
    /// the GCM additional-authenticated-data. Including `chunkIndex`/`chunkCount` makes a chunk's
    /// ciphertext unopenable in any other slot (reordering/substitution) or across a differently-sized
    /// backup generation, so a partially-overwritten chunk set fails closed on restore.
    private static func authenticatedData(
        payloadType: SealedBackupPayloadType,
        signingPublicKey: Data,
        chunkIndex: Int,
        chunkCount: Int
    ) -> Data {
        Data(payloadType.rawValue.utf8) + Data([0]) + signingPublicKey
            + Data([0]) + Data("\(chunkIndex)/\(chunkCount)".utf8)
    }
}

@MainActor
final class SealedBackupService {
    private let cloudDataService: CloudKitDataService
    private let identityService: IdentityService

    init(cloudDataService: CloudKitDataService, identityService: IdentityService) {
        self.cloudDataService = cloudDataService
        self.identityService = identityService
    }

    /// Single-record reconcile for payloads that fit one sealed blob (sensitive notes; period-disable).
    /// Disabling deletes the whole chunk set, so it also tears down any multi-record period backup.
    func reconcile(_ plaintext: Data, payloadType: SealedBackupPayloadType, enabled: Bool) async throws {
        if enabled {
            let record = try SealedBackupCrypto.seal(
                plaintext,
                payloadType: payloadType,
                identityService: identityService
            )
            try await cloudDataService.saveSealedBackup(record)
        } else {
            try await cloudDataService.deleteSealedBackup(payloadType: payloadType)
        }
    }

    /// Seals and uploads a payload as `chunkCount` independent sealed records, materializing only one
    /// chunk's plaintext at a time (the `chunk` closure yields the plaintext for a given index). The
    /// suffixed chunks (`1...n-1`) are written first and the head (`0`, which carries `chunkCount`) is
    /// written last as the commit marker, so a restore only ever sees a complete set. Stale chunks
    /// from a previously larger backup are then pruned. Each chunk's GCM AAD binds its index/count, so
    /// a mixed-generation set fails closed on restore.
    func reconcileChunked(
        payloadType: SealedBackupPayloadType,
        chunkCount: Int,
        chunk: (Int) throws -> Data
    ) async throws {
        let count = max(1, chunkCount)
        for index in stride(from: count - 1, through: 1, by: -1) {
            try await saveChunk(chunk(index), payloadType: payloadType, chunkIndex: index, chunkCount: count)
        }
        try await saveChunk(chunk(0), payloadType: payloadType, chunkIndex: 0, chunkCount: count)
        try await cloudDataService.deleteSealedBackupChunks(payloadType: payloadType, withIndexAtLeast: count)
    }

    private func saveChunk(_ plaintext: Data, payloadType: SealedBackupPayloadType, chunkIndex: Int, chunkCount: Int) async throws {
        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: payloadType,
            identityService: identityService,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount
        )
        try await cloudDataService.saveSealedBackup(record)
    }

    /// Fetches and opens every chunk of a payload, returning each chunk's plaintext in chunk order, or
    /// `nil` when no backup exists. Works for both single-record and multi-record payloads (a single
    /// blob is just `chunkCount == 1`). Throws if the chunk set is incomplete or mixed-generation
    /// (`CloudKitDataService.sealedBackupChunks` validates contiguity), so callers restore all-or-nothing.
    func restoreChunks(payloadType: SealedBackupPayloadType) async throws -> [Data]? {
        let records = try await cloudDataService.sealedBackupChunks(payloadType: payloadType)
        guard !records.isEmpty else { return nil }
        return try records.map { try SealedBackupCrypto.open($0, identityService: identityService) }
    }
}

private extension AES.GCM.Nonce {
    var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
