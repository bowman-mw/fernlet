import ProximityKit
import CryptoKit
import Foundation
import FernletDomainModel
import FernletFoundation
import CloudKitSync

/// AES-GCM seal/open for `SealedBackupRecord`s — the pure crypto half of the sealed iCloud backup.
///
/// ``seal(_:payloadType:identityService:chunkIndex:chunkCount:updatedAt:generation:)`` encrypts a
/// payload chunk under the identity's backup-escrow-derived key and binds the payload type, signing
/// identity, chunk position, and the backup's generation + timestamp into the GCM
/// additional-authenticated-data, so a chunk cannot be replayed in another slot, across
/// differently-sized backup generations, or as part of an older generation.
/// ``open(_:identityService:)`` attempts decryption against every escrow key candidate the device
/// holds — derived under **that record's** format version and salt — and consults the record's
/// identity tag only to classify failures (someone else's record versus a tampered/corrupt one of
/// ours). New writes are record format v2 (a per-generation HKDF salt, so one escrow-key compromise
/// no longer opens every generation); v1 records already in CloudKit keep opening unchanged, which is
/// why the salt/version travel on the record rather than being assumed. Records are bound to the
/// backup-escrow public key
/// (which syncs via iCloud Keychain) rather than the per-device proximity key, so a backup sealed
/// on one device is recognized and restorable on another. Stateless namespace; the methods are
/// `@MainActor` because `IdentityService` is. ``SealedBackupService`` is the only production
/// caller.
enum SealedBackupCrypto {
    /// Seals one payload chunk into a `SealedBackupRecord` under the escrow-derived backup key.
    ///
    /// - Parameters:
    ///   - plaintext: The chunk's serialized payload.
    ///   - payloadType: Which sealed backup this chunk belongs to (bound into the GCM AAD, so a
    ///     record cannot be replayed as a different payload).
    ///   - identityService: Vends the backup-escrow key the chunk is sealed under and the signing
    ///     public key stamped onto the record.
    ///   - chunkIndex: This record's position in its chunk set (bound into the GCM AAD).
    ///   - chunkCount: The set's total size (also bound, so mixed-generation sets fail closed).
    ///   - updatedAt: The record's timestamp; also bound into the AAD (floored to whole seconds,
    ///     matching what survives a CloudKit round trip).
    ///   - generation: The minted rollback counter for this write, bound into the AAD so an older
    ///     but validly-sealed generation cannot be substituted.
    ///   - keySalt: The generation's per-backup HKDF salt (32 random bytes), shared by every chunk of
    ///     the generation. Non-empty selects **record format v2** (salted derivation under the
    ///     versioned info string); empty — the default, kept only for v1 fixtures and legacy call
    ///     sites — reproduces the v1 static derivation byte-for-byte. Every production write passes a
    ///     freshly minted salt.
    /// - Returns: The sealed record, tagged with the escrow public key so another of the user's
    ///   devices recognizes it as theirs, and stamped with the format version + salt needed to
    ///   re-derive its key.
    @MainActor
    static func seal(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        identityService: IdentityService,
        chunkIndex: Int = 0,
        chunkCount: Int = 1,
        updatedAt: Date = Date(),
        generation: Int64,
        keySalt: Data = Data()
    ) throws -> SealedBackupRecord {
        // The salt's presence IS the format choice at the seal seam; from here down the version is
        // explicit, and it is what the record carries (the reader never re-infers it).
        let formatVersion = keySalt.isEmpty ? 1 : 2
        let key = try identityService.sealedBackupKey(formatVersion: formatVersion, salt: keySalt)
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
                chunkCount: chunkCount,
                generation: generation,
                updatedAt: updatedAt
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
            chunkCount: chunkCount,
            generation: generation,
            formatVersion: formatVersion,
            keySalt: keySalt
        )
    }

    /// Opens a sealed record, trying every backup-escrow key this device holds.
    ///
    /// - Returns: The decrypted plaintext when any candidate key authenticates the record.
    /// - Throws: `SealedBackupError.keyAgreementIdentityMismatch` when the record is not tagged
    ///   with any of our escrow identities (someone else's, or unrelated), or
    ///   `SealedBackupError.malformedRecord` for a tampered/corrupt record of ours.
    @MainActor
    static func open(_ record: SealedBackupRecord, identityService: IdentityService) throws -> Data {
        // The AES-GCM authentication under our escrow-derived key is the REAL ownership boundary: only a
        // record sealed with one of OUR backup-escrow keys (all of which sync via iCloud Keychain) can open.
        // We attempt decryption FIRST — and against EVERY escrow key this device holds (the adopted key plus
        // any coexisting content-addressed / legacy keys, `sealedBackupKeyCandidates`) — so a record still
        // opens even if (a) its `keyAgreementPublicKey` identity tag predates the escrow-binding fix or is
        // foreign, or (b) it was sealed under a SURVIVING-but-not-adopted key during an unresolved
        // cross-device escrow conflict (content-addressing keeps that genuine key alive). The tag is
        // consulted ONLY to classify the failure: a record not tagged with ANY of our escrow identities is
        // someone else's (or unrelated) → mismatch; otherwise it is a tampered/corrupt record of ours.
        //
        // Candidates are derived under THIS record's format version and salt, so a v1 record and a v2
        // record open on the same identity with no migration and no fetch-order dependency. (Each
        // record re-derives; a restore of N chunks therefore does N derivations × candidates. Restore
        // is rare and network-bound per chunk, so that is deliberate rather than hoisted — hoisting
        // would have to key a cache by salt anyway.)
        let candidates = identityService.sealedBackupKeyCandidates(
            formatVersion: record.formatVersion,
            salt: record.keySalt
        )
        guard !candidates.isEmpty else { throw IdentityError.notProvisioned }

        if let nonce = try? AES.GCM.Nonce(data: record.nonce),
           let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: record.ciphertext, tag: record.tag) {
            let aad = authenticatedData(
                payloadType: record.payloadType,
                signingPublicKey: record.signingPublicKey,
                chunkIndex: record.chunkIndex,
                chunkCount: record.chunkCount,
                generation: record.generation,
                updatedAt: record.updatedAt
            )
            for candidate in candidates {
                if let plaintext = try? AES.GCM.open(sealedBox, using: candidate.key, authenticating: aad) {
                    return plaintext
                }
            }
        }
        if !candidates.contains(where: { $0.publicKey == record.keyAgreementPublicKey }) {
            throw SealedBackupError.keyAgreementIdentityMismatch
        }
        throw SealedBackupError.malformedRecord
    }

    /// Binds the payload type, signing identity, the record's position within its chunk set, and the
    /// backup's generation + timestamp into the GCM additional-authenticated-data.
    ///
    /// `chunkIndex`/`chunkCount` make a chunk's ciphertext unopenable in any other slot (reordering
    /// or substitution) or across a differently-sized generation, so a partially-overwritten chunk
    /// set fails closed on restore. `generation` and `updatedAt` close the rollback hole (code
    /// review finding 14): before they were bound, both fields were attacker-editable metadata, so a
    /// substituted older backup authenticated cleanly and restored silently.
    ///
    /// Note the AEAD alone cannot *detect* rollback — a wholesale older generation is authentic by
    /// construction. Binding the counter is what makes the app-side high-water check
    /// (`SealedBackupGenerationStore`) trustworthy: the generation a record claims is now the
    /// generation it was sealed with.
    ///
    /// **Encoding** follows the `CanonicalSignatureSerializer` precedent rather than string
    /// interpolation: a version tag first, then fixed big-endian integers and a whole-second
    /// timestamp. `\(chunkIndex)/\(chunkCount)` is kept for the two chunk fields only because
    /// changing it would buy nothing — the whole AAD is already versioned by the `v2` tag, and every
    /// field is length-delimited by a `0` separator or a fixed width.
    private static func authenticatedData(
        payloadType: SealedBackupPayloadType,
        signingPublicKey: Data,
        chunkIndex: Int,
        chunkCount: Int,
        generation: Int64,
        updatedAt: Date
    ) -> Data {
        var aad = Data("fernlet.sealed-backup.aad.v2".utf8) + Data([0])
        aad += Data(payloadType.rawValue.utf8) + Data([0])
        aad += signingPublicKey + Data([0])
        aad += Data("\(chunkIndex)/\(chunkCount)".utf8) + Data([0])
        aad += withUnsafeBytes(of: UInt64(bitPattern: generation).bigEndian) { Data($0) }
        // Whole seconds: a Double's sub-second bits are not reproducible across an encode/decode
        // round trip through CloudKit, and would make an otherwise valid record fail to open.
        let seconds = Int64(updatedAt.timeIntervalSince1970.rounded(.down))
        aad += withUnsafeBytes(of: UInt64(bitPattern: seconds).bigEndian) { Data($0) }
        return aad
    }
}

/// Seals payloads and moves them to/from the private CloudKit database — the transport half of
/// the sealed iCloud backup.
///
/// Composes ``SealedBackupCrypto`` with `CloudKitDataService`: ``reconcile(_:payloadType:enabled:)``
/// handles single-record payloads (enable = seal + upload, disable = delete),
/// ``reconcileChunked(payloadType:chunkCount:chunk:)`` pages large payloads through bounded chunks
/// with the head record written last as the commit marker, and ``restoreChunks(payloadType:)``
/// fetches and opens a complete set all-or-nothing. ``SealedBackupCoordinator`` owns the policy
/// (visibility gates, no-clobber checks, escrow reconciliation) and is the only production caller;
/// this class stays mechanism-only. Main-actor isolated, matching its `IdentityService` dependency.
@MainActor
final class SealedBackupService {
    private let cloudDataService: CloudKitDataService
    private let identityService: IdentityService
    /// Device-local rollback high-water mark. `var` because minting and accepting both mutate it.
    private var generationStore: SealedBackupGenerationStore

    /// Creates the service over its CloudKit transport and the sealing identity.
    ///
    /// - Parameters:
    ///   - cloudDataService: The private-database transport the sealed records are written to.
    ///   - identityService: Vends the backup-escrow key every record is sealed under.
    ///   - generationStore: Injectable so tests can drive rollback scenarios against an
    ///     isolated `UserDefaults` suite; `nil` (the default) takes the `.standard`-backed store.
    ///     It is defaulted to `nil` and resolved here rather than defaulted to
    ///     `SealedBackupGenerationStore()` directly, because that type is `@MainActor` and default
    ///     argument expressions are evaluated in a nonisolated context in the Swift 5 language mode.
    init(
        cloudDataService: CloudKitDataService,
        identityService: IdentityService,
        generationStore: SealedBackupGenerationStore? = nil
    ) {
        self.cloudDataService = cloudDataService
        self.identityService = identityService
        self.generationStore = generationStore ?? SealedBackupGenerationStore()
    }

    /// Single-record reconcile for payloads that fit one sealed blob (sensitive notes; period-disable).
    /// Disabling deletes the whole chunk set, so it also tears down any multi-record period backup.
    func reconcile(_ plaintext: Data, payloadType: SealedBackupPayloadType, enabled: Bool) async throws {
        if enabled {
            let record = try SealedBackupCrypto.seal(
                plaintext,
                payloadType: payloadType,
                identityService: identityService,
                generation: generationStore.mintNext(for: payloadType),
                keySalt: Self.mintKeySalt()
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
    /// a mixed-generation set fails closed on restore. The whole set shares one generation counter and
    /// one per-generation HKDF salt (record format v2), both stamped on every chunk.
    func reconcileChunked(
        payloadType: SealedBackupPayloadType,
        chunkCount: Int,
        chunk: (Int) throws -> Data
    ) async throws {
        let count = max(1, chunkCount)
        // ONE generation for the whole set, minted before the first write. Minting per chunk would
        // make every multi-chunk backup look mixed-generation and fail its own restore check.
        let generation = generationStore.mintNext(for: payloadType)
        // ONE salt for the whole set, for the same reason — and stamped on EVERY chunk rather than
        // only the head, because the head is written last as the commit marker, so a head-only salt
        // could not be read while the suffix chunks were being sealed.
        let keySalt = Self.mintKeySalt()
        for index in stride(from: count - 1, through: 1, by: -1) {
            try await saveChunk(
                chunk(index),
                payloadType: payloadType,
                chunkIndex: index,
                chunkCount: count,
                generation: generation,
                keySalt: keySalt
            )
        }
        try await saveChunk(
            chunk(0),
            payloadType: payloadType,
            chunkIndex: 0,
            chunkCount: count,
            generation: generation,
            keySalt: keySalt
        )
        try await cloudDataService.deleteSealedBackupChunks(payloadType: payloadType, withIndexAtLeast: count)
    }

    /// Seals one chunk and uploads it (shared by both `reconcileChunked` write phases).
    private func saveChunk(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        chunkIndex: Int,
        chunkCount: Int,
        generation: Int64,
        keySalt: Data
    ) async throws {
        let record = try SealedBackupCrypto.seal(
            plaintext,
            payloadType: payloadType,
            identityService: identityService,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            generation: generation,
            keySalt: keySalt
        )
        try await cloudDataService.saveSealedBackup(record)
    }

    /// Mints one backup generation's HKDF salt: 32 CSPRNG bytes from `SymmetricKey(size: .bits256)`.
    ///
    /// **Never empty.** An empty salt would mean record format v1 at the seal seam, silently
    /// reintroducing the static derivation this hardening exists to remove (the versioned info string
    /// is the second line of defense, not the first). Every production write goes through here.
    private static func mintKeySalt() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }

    /// Fetches and opens every chunk of a payload, returning each chunk's plaintext in chunk order, or
    /// `nil` when no backup exists. Works for both single-record and multi-record payloads (a single
    /// blob is just `chunkCount == 1`). Throws if the chunk set is incomplete, mixed-generation, or
    /// mixes record formats / per-generation salts (`CloudKitDataService.sealedBackupChunks` validates
    /// contiguity), so callers restore all-or-nothing.
    func restoreChunks(payloadType: SealedBackupPayloadType) async throws -> [Data]? {
        let records = try await cloudDataService.sealedBackupChunks(payloadType: payloadType)
        guard !records.isEmpty else { return nil }

        // Open FIRST, then check the generation. Order matters: the generation is only meaningful
        // once the AEAD has authenticated it, since an unopened record's fields are attacker-typed
        // bytes. Checking before opening would let a forged high generation suppress the check.
        let plaintexts = try records.map {
            try SealedBackupCrypto.open($0, identityService: identityService)
        }

        // Every chunk shares one generation (enforced in `sealedBackupChunks`), so the head speaks
        // for the set.
        let generation = records[0].generation
        let lastSeen = generationStore.lastSeen(for: payloadType)
        guard generation >= lastSeen else {
            FernletAuditLog.log("sealedBackup.restore.staleGeneration", context: [
                "payloadType": payloadType.rawValue,
                "found": String(generation),
                "lastSeen": String(lastSeen)
            ])
            throw SealedBackupError.staleGeneration(found: generation, lastSeen: lastSeen)
        }
        generationStore.recordAccepted(generation, for: payloadType)
        return plaintexts
    }
}

private extension AES.GCM.Nonce {
    /// The nonce's raw bytes, for storage in a `SealedBackupRecord`.
    var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
