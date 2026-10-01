import ProximityKit
import CryptoKit
import FernletCrypto
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
/// why the salt/version travel on the record rather than being assumed. Because those two fields are
/// unauthenticated CloudKit metadata that an older writer can leave stale (CloudKit merges fields, it
/// does not replace records), `open` retries the v1 derivation once when a v2-labelled record fails —
/// AES-GCM, not the label, decides. Records are bound to the
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
    /// Candidates are derived under the record's own `formatVersion`/`keySalt` first; if none of them
    /// authenticate and the record claims v2, the v1 (static, empty-salt) candidates are retried once.
    /// See the inline note on why that retry is security-neutral.
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
            if let plaintext = firstOpening(sealedBox, aad: aad, candidates: candidates) { return plaintext }

            // STALE-METADATA FALLBACK. `formatVersion`/`keySalt` are unauthenticated CloudKit fields,
            // and CloudKit's `.allKeys` save is a per-FIELD update, not a record replace: a writer that
            // never sets those keys (any build from before v2 shipped) overwrites the ciphertext while
            // the server KEEPS the previous v2 write's version + salt. The resulting record is v1
            // ciphertext wearing v2 metadata, and deriving only under the stamped version would strand
            // a perfectly recoverable backup forever. So when a v2-labelled record fails, retry the v1
            // derivation once before declaring corruption.
            //
            // Security-neutral by construction: the version field is a HINT about which key to try,
            // never an authorization decision. AES-GCM remains the sole authority — a genuine v2
            // ciphertext cannot open under a v1 key, a tampered record still fails both passes, the AAD
            // is untouched, and the generation high-water check in `SealedBackupService.restoreChunks`
            // still catches rollback. Cost is one extra derivation pass on the already-failing path.
            if record.formatVersion >= 2 {
                let legacy = identityService.sealedBackupKeyCandidates(formatVersion: 1, salt: Data())
                if let plaintext = firstOpening(sealedBox, aad: aad, candidates: legacy) { return plaintext }
            }
        }
        if !candidates.contains(where: { $0.publicKey == record.keyAgreementPublicKey }) {
            throw SealedBackupError.keyAgreementIdentityMismatch
        }
        throw SealedBackupError.malformedRecord
    }

    /// The plaintext from the first candidate key that authenticates `sealedBox` under `aad`, or `nil`
    /// when none does. Factored out so ``open(_:identityService:)`` can run the same decrypt-first
    /// sweep twice — once under the record's stamped format, once under v1 as the stale-metadata
    /// fallback — without duplicating the loop.
    private static func firstOpening(
        _ sealedBox: AES.GCM.SealedBox,
        aad: Data,
        candidates: [(publicKey: Data, key: SymmetricKey)]
    ) -> Data? {
        for candidate in candidates {
            if let plaintext = try? AES.GCM.open(sealedBox, using: candidate.key, authenticating: aad) { // cryptographic-domain: authenticatedData-bound aad
                return plaintext
            }
        }
        return nil
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
        var aad = FernletCryptoPurpose.AEAD.sealedBackupV2.data + Data([0])
        aad += Data(payloadType.rawValue.utf8) + Data([0])
        aad += signingPublicKey + Data([0])
        aad += Data("\(chunkIndex)/\(chunkCount)".utf8) + Data([0])
        aad += bigEndianBytes(UInt64(bitPattern: generation))
        // Whole seconds: a Double's sub-second bits are not reproducible across an encode/decode
        // round trip through CloudKit, and would make an otherwise valid record fail to open.
        let seconds = Int64(updatedAt.timeIntervalSince1970.rounded(.down))
        aad += bigEndianBytes(UInt64(bitPattern: seconds))
        return aad
    }
}

/// The eight big-endian bytes of `value`, without an unsafe raw-buffer copy (Power-of-10 R9).
///
/// Byte-identical to `withUnsafeBytes(of: value.bigEndian) { Data($0) }` — the AAD layout it feeds is
/// an at-rest format pinned by `SealedBackupFormatPinTests`, so the encoding may never drift.
private func bigEndianBytes(_ value: UInt64) -> Data {
    Data((0..<8).map { UInt8(truncatingIfNeeded: value >> (8 * (7 - $0))) })
}

/// Seals payloads and moves them to/from the private CloudKit database — the transport half of
/// the sealed iCloud backup.
///
/// Composes ``SealedBackupCrypto`` with `CloudKitDataService`: ``reconcile(_:payloadType:enabled:)``
/// handles single-record payloads (enable = seal + upload, disable = delete),
/// ``reconcileChunked(payloadType:chunkCount:chunk:)`` pages the v1 payloads (journal, intimacy)
/// through bounded chunks with the head record written last as the commit marker, and
/// ``restoreChunks(payloadType:)`` fetches and opens a complete v1 set all-or-nothing. The Sealed backup
/// v2 primitives (``fetchHeadRecord(payloadType:)``, ``fetchSuffixRecords(payloadType:chunkCount:setTag:)``,
/// ``sealChunk(_:payloadType:chunkIndex:chunkCount:generation:keySalt:)``, ``save(_:setTag:)``,
/// ``pruneSets(payloadType:keepingSetTag:belowGeneration:)``) are single steps the
/// ``SealedBackupV2Engine`` sequences, so it can re-check its gates between any two of them.
/// ``SealedBackupCoordinator`` and the engine own the policy (visibility gates, no-clobber checks,
/// escrow reconciliation, the order) and are the only production callers; this class stays
/// mechanism-only. Main-actor isolated, matching its `IdentityService` dependency.
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

    /// Single-record reconcile. Disabling deletes the whole chunk set, so it also tears down any
    /// multi-record backup — the coordinator's disable path for every payload, and the retirement
    /// sweep's delete of the retired sensitive-notes copy. The enable (seal-one-record) arm was only
    /// ever driven by that payload, so production no longer reaches it; it stays as mechanism, and
    /// for the format/round-trip tests that pin how such a record was written.
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
    ///
    /// The journal and intimacy (v1) exports write through here, sealing each chunk as it uploads it,
    /// at fixed, unscoped record names. The v2 payloads never do: the engine seals its whole set in
    /// memory first and writes set-scoped suffix chunks (design 2026-09-30, §5.2).
    ///
    /// - Parameters:
    ///   - payloadType: The payload being written.
    ///   - chunkCount: How many chunks (at least one is always written).
    ///   - chunk: The plaintext for a chunk index.
    /// - Returns: The generation the set was written under. Discardable: no caller records it; a
    ///   failure is always a throw.
    @discardableResult
    func reconcileChunked(
        payloadType: SealedBackupPayloadType,
        chunkCount: Int,
        chunk: (Int) throws -> Data
    ) async throws -> Int64 {
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
        return generation
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

    /// Mints one backup generation's HKDF salt: 32 CSPRNG bytes from `SystemRandomNumberGenerator`
    /// (`UInt8.random`), the platform CSPRNG — no unsafe buffer access (Power-of-10 R9).
    ///
    /// **Never empty.** An empty salt would mean record format v1 at the seal seam, silently
    /// reintroducing the static derivation this hardening exists to remove (the versioned info string
    /// is the second line of defense, not the first). Every production write goes through here.
    static func mintKeySalt() -> Data {
        let salt = Data((0..<Self.keySaltByteCount).map { _ in UInt8.random(in: .min ... .max) })
        assert(salt.count == Self.keySaltByteCount)
        return salt
    }

    /// The per-generation HKDF salt width; the derivation and its fixtures assume 32 bytes.
    private static let keySaltByteCount = 32

    /// Upper bound on the chunks one restore will decrypt (Power-of-10 R3: bounded growth).
    ///
    /// The chunk count originates in `head.chunkCount`, an UNAUTHENTICATED CloudKit field read
    /// before any AEAD check, so a substituted head could otherwise drive an unbounded fetch and an
    /// unbounded plaintext array. Exports write ceil(rowCount / 250) chunks, so 400 chunks (100k
    /// rows) is far above any real backup; anything larger is a malformed record, not a big user.
    static let maxRestoreChunkCount = 400

    /// Fetches and opens every chunk of a payload, returning each chunk's plaintext in chunk order, or
    /// `nil` when no backup exists. Works for both single-record and multi-record payloads (a single
    /// blob is just `chunkCount == 1`). Throws if the chunk set is incomplete or mixed-generation
    /// (`CloudKitDataService.sealedBackupChunks` validates contiguity), and if any chunk fails to open,
    /// so callers restore all-or-nothing.
    func restoreChunks(payloadType: SealedBackupPayloadType) async throws -> [Data]? {
        let records = try await cloudDataService.sealedBackupChunks(payloadType: payloadType)
        guard !records.isEmpty else { return nil }
        // R3 (bounded growth): the set size ultimately comes from `head.chunkCount`, an
        // unauthenticated CloudKit field. Refuse an absurd set before decrypting it into memory, so
        // a substituted head cannot drive an unbounded plaintext array on this side of the transport.
        guard records.count <= Self.maxRestoreChunkCount else {
            FernletAuditLog.log("sealedBackup.restore.chunkCountRejected", context: [
                "payloadType": payloadType.rawValue,
                "found": String(records.count),
                "max": String(Self.maxRestoreChunkCount)
            ])
            throw SealedBackupError.malformedRecord
        }

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

    // MARK: - Sealed backup v2 primitives (design 2026-09-30, §4.2, §5)
    //
    // Mechanism only: `SealedBackupV2Engine` owns the order (gates, E1–E3, prepare then commit) and
    // calls these one step at a time, so a gate can be re-checked between any two of them.

    /// The head record (chunk 0) of a payload's set as CloudKit holds it — unopened — or nil when none.
    func fetchHeadRecord(payloadType: SealedBackupPayloadType) async throws -> SealedBackupRecord? {
        try await cloudDataService.sealedBackup(payloadType: payloadType)
    }

    /// The suffix chunks of the set a head names, unopened: a v2 set's scoped chunks when `setTag` is
    /// given, a v1 set's unscoped ones otherwise (CloudKit checks contiguity, count and generation).
    func fetchSuffixRecords(
        payloadType: SealedBackupPayloadType,
        chunkCount: Int,
        setTag: String?
    ) async throws -> [SealedBackupRecord] {
        try await cloudDataService.sealedBackupSuffixChunks(payloadType: payloadType, chunkCount: chunkCount, setTag: setTag)
    }

    /// Opens one record under this device's escrow keys (no key is ever minted here).
    func open(_ record: SealedBackupRecord) throws -> Data {
        try SealedBackupCrypto.open(record, identityService: identityService)
    }

    /// Seals one v2 chunk in memory under this device's escrow key (nothing is uploaded).
    func sealChunk(
        _ plaintext: Data,
        payloadType: SealedBackupPayloadType,
        chunkIndex: Int,
        chunkCount: Int,
        generation: Int64,
        keySalt: Data
    ) throws -> SealedBackupRecord {
        try SealedBackupCrypto.seal(
            plaintext,
            payloadType: payloadType,
            identityService: identityService,
            chunkIndex: chunkIndex,
            chunkCount: chunkCount,
            generation: generation,
            keySalt: keySalt
        )
    }

    /// Uploads one sealed chunk under its set-scoped name (the head under the bare name).
    func save(_ record: SealedBackupRecord, setTag: String) async throws {
        try await cloudDataService.saveSealedBackup(record, setTag: setTag)
    }

    /// Deletes the stale sets a committed set left behind (best-effort for the caller).
    ///
    /// - Returns: How many records were deleted.
    func pruneSets(payloadType: SealedBackupPayloadType, keepingSetTag: String, belowGeneration: Int64) async throws -> Int {
        try await cloudDataService.pruneSealedBackupSets(
            payloadType: payloadType, keepingSetTag: keepingSetTag, belowGeneration: belowGeneration
        )
    }

    /// This install's signing public key — bound into every record's AAD, device-only, so a v1 head
    /// whose authenticated `signingPublicKey` equals it was written by this install (§5.5).
    var localSigningPublicKey: Data { identityService.localSigningPublicKey }

    /// The highest generation this device has committed or accepted for `payloadType` — the rollback
    /// floor (§5.4). Raised only by a verified commit or an accepted restore.
    func lastSeenGeneration(for payloadType: SealedBackupPayloadType) -> Int64 {
        generationStore.lastSeen(for: payloadType)
    }

    /// Raises the rollback floor after a verified commit or an accepted restore (never lowers it).
    func recordCommittedOrAccepted(_ generation: Int64, for payloadType: SealedBackupPayloadType) {
        generationStore.recordAccepted(generation, for: payloadType)
    }
}

private extension AES.GCM.Nonce {
    /// The nonce's raw bytes, for storage in a `SealedBackupRecord`.
    ///
    /// `AES.GCM.Nonce` is a `Sequence` of `UInt8`, so `Data.init(_:)` copies it with no unsafe
    /// buffer access (Power-of-10 R9).
    var data: Data {
        Data(self)
    }
}
