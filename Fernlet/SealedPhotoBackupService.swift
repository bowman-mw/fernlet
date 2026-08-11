import ProximityKit
import CryptoKit
import Foundation
import FernletFoundation
import CloudKitSync

/// AES-GCM seal/open for ``SealedPhotoRecord``s — the pure crypto half of the own-photo escrow
/// route (security-hardening Phase 5, step 5b).
///
/// The sibling of `SealedBackupCrypto`, and deliberately its own namespace rather than a fifth
/// payload type: the chunked scheme binds `chunkIndex/chunkCount` into its AAD, which forces a
/// rewrite of the WHOLE set on every change. Photos need the opposite property (add one, rewrite
/// nothing else), so each photo is its own record and the AAD binds a **v3** layout instead:
/// domain tag, corpus, signing key, slot, generation, timestamp.
///
/// Key material is shared with the chunked route on purpose — the same backup-escrow-derived key,
/// on the **v2 salted path** (`IdentityService.sealedBackupKey(formatVersion: 2, salt:)`), so a
/// photo backup restores on any device holding the user's escrow key and one escrow-key compromise
/// still only opens one generation. Domain separation between the two routes comes from the AAD's
/// version tag, not from a second key.
///
/// Stateless namespace; `@MainActor` because `IdentityService` is.
enum SealedPhotoCrypto {
    /// Seals one photo body (or a corpus manifest) into a ``SealedPhotoRecord``.
    ///
    /// - Parameters:
    ///   - plaintext: The normalized JPEG, or the encoded manifest.
    ///   - corpus: Which own-photo corpus (bound into the AAD).
    ///   - slot: Which record within the corpus (bound into the AAD, and the record's name suffix).
    ///   - identityService: Vends the escrow-derived key and the signing key stamped on the record.
    ///   - updatedAt: The record's timestamp, bound into the AAD floored to whole seconds (what
    ///     survives a CloudKit round trip).
    ///   - generation: The minted per-corpus counter for this write, bound into the AAD.
    ///   - keySalt: This write's 32-byte HKDF salt. **Required and never empty** — the route was
    ///     born on the v2 salted derivation, so there is no unsalted spelling to fall back to.
    @MainActor
    static func seal(
        _ plaintext: Data,
        corpus: SealedPhotoCorpus,
        slot: SealedPhotoSlot,
        identityService: IdentityService,
        updatedAt: Date = Date(),
        generation: Int64,
        keySalt: Data
    ) throws -> SealedPhotoRecord {
        // Fail closed rather than silently reproducing the v1 static derivation this route never had.
        guard keySalt.count == 32 else { throw SealedBackupError.malformedRecord }
        let key = try identityService.sealedBackupKey(formatVersion: 2, salt: keySalt)
        let nonce = AES.GCM.Nonce()
        let signingPublicKey = identityService.localSigningPublicKey
        let sealedBox = try AES.GCM.seal(
            plaintext,
            using: key,
            nonce: nonce,
            authenticating: authenticatedData(
                corpus: corpus,
                signingPublicKey: signingPublicKey,
                slot: slot,
                generation: generation,
                updatedAt: updatedAt
            )
        )
        return SealedPhotoRecord(
            corpus: corpus,
            slot: slot,
            signingPublicKey: signingPublicKey,
            // Tagged with the backup-ESCROW public key (iCloud-Keychain-synced, device-stable), not
            // the per-device proximity key — otherwise a legitimate cross-device restore would be
            // classified as somebody else's record. Same rule as `SealedBackupCrypto.seal`.
            keyAgreementPublicKey: identityService.localBackupEscrowPublicKey,
            nonce: nonce.data,
            ciphertext: sealedBox.ciphertext,
            tag: sealedBox.tag,
            updatedAt: updatedAt,
            generation: generation,
            formatVersion: 2,
            keySalt: keySalt
        )
    }

    /// Opens a sealed photo record, trying every backup-escrow key this device holds.
    ///
    /// Decrypt-first, exactly like `SealedBackupCrypto.open`: AES-GCM under one of OUR escrow keys is
    /// the real ownership boundary, and the record's identity tag is consulted ONLY to classify a
    /// failure (someone else's record versus a tampered one of ours). There is no v1 retry — this
    /// record type has no v1 spelling, so a record that fails under its stamped format is corrupt,
    /// not downlevel.
    ///
    /// - Throws: `SealedBackupError.keyAgreementIdentityMismatch` when the record is not tagged with
    ///   any escrow identity of ours, `SealedBackupError.malformedRecord` otherwise.
    @MainActor
    static func open(_ record: SealedPhotoRecord, identityService: IdentityService) throws -> Data {
        let candidates = identityService.sealedBackupKeyCandidates(
            formatVersion: record.formatVersion,
            salt: record.keySalt
        )
        guard !candidates.isEmpty else { throw IdentityError.notProvisioned }

        if let nonce = try? AES.GCM.Nonce(data: record.nonce),
           let sealedBox = try? AES.GCM.SealedBox(nonce: nonce, ciphertext: record.ciphertext, tag: record.tag) {
            let aad = authenticatedData(
                corpus: record.corpus,
                signingPublicKey: record.signingPublicKey,
                slot: record.slot,
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

    /// Binds the corpus, signing identity, slot, generation and timestamp into the GCM
    /// additional-authenticated-data — **AAD v3**, the per-photo sibling of
    /// `SealedBackupCrypto.authenticatedData`'s v2 layout.
    ///
    /// What each field buys:
    /// - the **domain tag** separates this route from the chunked one even though both derive the
    ///   same escrow key, so no record of either kind can be replayed as the other;
    /// - **corpus** stops a meal photo being replayed as a progress (body) photo;
    /// - **slot** is the record's own name suffix, so a record moved to another name — including
    ///   from a photo slot to the manifest slot, or vice versa — fails to open rather than opening
    ///   in the wrong place;
    /// - **generation + updatedAt** close the rollback hole exactly as they do for the chunked
    ///   route: the AEAD cannot detect a wholesale substitution of an older generation, but binding
    ///   the counter is what makes the app-side high-water check trustworthy.
    ///
    /// **Encoding** follows the same precedent as v2: a version tag first, then NUL-separated
    /// fields and fixed big-endian integers, with the timestamp floored to whole seconds because a
    /// Double's sub-second bits do not survive a CloudKit round trip.
    ///
    /// - Important: this byte layout is at-rest format. It is pinned byte-for-byte in
    ///   `SealedBackupFormatPinTests`; changing it strands every photo backup already uploaded.
    private static func authenticatedData(
        corpus: SealedPhotoCorpus,
        signingPublicKey: Data,
        slot: SealedPhotoSlot,
        generation: Int64,
        updatedAt: Date
    ) -> Data {
        var aad = Data("fernlet.sealed-photo.aad.v3".utf8) + Data([0])
        aad += Data(corpus.rawValue.utf8) + Data([0])
        aad += signingPublicKey + Data([0])
        aad += Data(slot.recordNameSuffix.utf8) + Data([0])
        aad += withUnsafeBytes(of: UInt64(bitPattern: generation).bigEndian) { Data($0) }
        let seconds = Int64(updatedAt.timeIntervalSince1970.rounded(.down))
        aad += withUnsafeBytes(of: UInt64(bitPattern: seconds).bigEndian) { Data($0) }
        return aad
    }
}

/// What one own-photo upload pass actually did, so the caller can audit it instead of logging a
/// bare "reconciled".
struct SealedPhotoUploadSummary: Equatable, Sendable {
    /// Photo bodies sealed and uploaded by this pass.
    var uploaded = 0
    /// Photos already in the cloud with the same content hash — nothing rewritten. This is the
    /// incremental property, measured.
    var skipped = 0
    /// Photos whose local bytes could not be read (locked keychain, corrupt file). Their existing
    /// cloud entry is KEPT rather than dropped from the manifest — an unreadable local file must
    /// never delete a good cloud copy.
    var unreadable = 0
    /// Records deleted after the manifest commit: photos removed locally that THIS device had
    /// uploaded (the `prunableIDs` scope). Never another device's.
    var pruned = 0
}

/// What one own-photo restore pass produced.
struct SealedPhotoRestoreSummary: Equatable, Sendable {
    /// Photos opened, hash-verified, and handed to the writer successfully.
    var restored = 0
    /// Manifest ids that could not be restored: no record, an unopenable record, a content-hash
    /// mismatch, or a writer that refused. Per the commit-marker contract these fail THAT photo, not
    /// the set.
    var failed: [UUID] = []
    /// The corpus sidecar carried by the manifest this restore authenticated — the progress
    /// timeline index — or nil when the manifest has none.
    ///
    /// Returned WITH the photos rather than fetched again afterwards, deliberately: a second fetch
    /// could be served a different (older but authentic) manifest, and its index would then be
    /// written without ever facing the generation high-water check this restore just made.
    var sidecar: Data?
}

/// Seals own photos and moves them to/from the private CloudKit database — the transport half of
/// the own-photo escrow route.
///
/// Composes ``SealedPhotoCrypto`` with `CloudKitDataService`, the way `SealedBackupService` does for
/// the chunked payloads, and keeps the same division of labour: this class is mechanism only, and
/// `OwnPhotoBackupCoordinator` owns the policy (the opt-in preference, the per-corpus no-clobber
/// gate, restore-before-reupload ordering, delete-all teardown).
///
/// The three operations that define the scheme:
/// - ``reconcile(corpus:ids:sidecar:photo:)`` uploads only what changed and writes the manifest
///   **LAST** as the commit marker;
/// - ``addPhoto(_:id:corpus:sidecar:)`` is the incremental add — one new record plus a rewritten
///   (small) manifest, nothing else touched;
/// - ``restore(corpus:write:)`` opens the manifest FIRST (authenticate, then generation high-water,
///   in that order), then fetches each listed id.
///
/// Main-actor isolated, matching its `IdentityService` dependency.
@MainActor
final class SealedPhotoBackupService {
    private let cloudDataService: CloudKitDataService
    private let identityService: IdentityService
    /// Device-local rollback high-water mark (photo namespace). `var` because minting and accepting
    /// both mutate it.
    private var generationStore: SealedBackupGenerationStore

    /// Creates the service over its CloudKit transport and the sealing identity.
    ///
    /// - Parameter generationStore: Injectable so tests drive rollback scenarios against an isolated
    ///   `UserDefaults` suite. Defaulted to `nil` and resolved in the body because
    ///   `SealedBackupGenerationStore` is `@MainActor` and default-argument expressions evaluate in a
    ///   nonisolated context in the Swift 5 language mode.
    init(
        cloudDataService: CloudKitDataService,
        identityService: IdentityService,
        generationStore: SealedBackupGenerationStore? = nil
    ) {
        self.cloudDataService = cloudDataService
        self.identityService = identityService
        self.generationStore = generationStore ?? SealedBackupGenerationStore()
    }

    // MARK: - Upload

    /// Uploads the corpus: seals every id whose bytes are new or changed, then writes the manifest
    /// LAST as the commit marker, then prunes records the manifest no longer names.
    ///
    /// Memory stays bounded to one photo: `photo` is called per id and yields that id's plaintext
    /// (nil when the local bytes cannot be read), so a 250 MB corpus never materializes.
    ///
    /// Three ordering rules, all load-bearing:
    /// 1. **Read the existing manifest first** and raise our own high-water mark from it. Without
    ///    that, a second device would mint a generation BELOW what the cloud already holds and its
    ///    own next restore would reject the backup it just wrote as a rollback.
    /// 2. **Manifest last.** A set whose bodies are uploaded but whose manifest was never written
    ///    restores NOTHING — which is the correct outcome for a half-finished upload.
    /// 3. **Prune after the commit.** An orphan record is ignored on restore, so deleting it is
    ///    housekeeping; deleting before the commit would drop a body the current manifest still
    ///    names.
    ///
    /// 4. **Union, not replacement.** A committed id this device does not have is CARRIED FORWARD
    ///    into the new manifest rather than dropped. Own photos are device-local files that no sync
    ///    carries between devices, so "not in my id set" means "belongs to my other phone" at least
    ///    as often as it means "deleted". Replacing the manifest with this device's set alone would
    ///    make each device's upload delete the other's photos — and, because each would then
    ///    re-upload on its next pass, ping-pong the whole library every launch.
    ///
    /// - Parameter verifyingContentHashes: When true (the FULL pass — enabling the backup, or the
    ///   user's explicit Retry) every id's plaintext is read and hashed, so a photo REPLACED in
    ///   place under the same id is re-uploaded. When false (the ambient launch pass) an id already
    ///   committed with a present record is skipped **without reading its bytes at all**, so a
    ///   launch never decrypts the user's whole library on the main actor — only genuinely new ids
    ///   are read. The honest cost: an in-place replacement (recipe photos are the only corpus where
    ///   an id's bytes change) waits for the next full pass.
    /// - Parameter prunableIDs: Ids this device has itself uploaded in the past — the ONLY ids it is
    ///   allowed to remove. An id in here that is no longer in `ids` was genuinely deleted on this
    ///   device, so it leaves the manifest (and its record is deleted); an id NOT in here is another
    ///   device's and is carried forward untouched. Empty means "prune nothing", the safe default.
    @discardableResult
    func reconcile(
        corpus: SealedPhotoCorpus,
        ids: [UUID],
        sidecar: Data? = nil,
        verifyingContentHashes: Bool = true,
        prunableIDs: Set<UUID> = [],
        photo: (UUID) throws -> Data?
    ) async throws -> SealedPhotoUploadSummary {
        var summary = SealedPhotoUploadSummary()
        // Best-effort: a manifest we cannot open (never written, foreign, corrupt) simply means
        // "nothing known to skip" — we re-upload everything rather than refuse. Only an OPENED
        // manifest may raise the high-water mark, because only then has AES-GCM vouched for its
        // generation.
        let existing = try? await openManifest(corpus: corpus)
        if let existing {
            generationStore.recordAcceptedPhoto(existing.generation, for: corpus)
        }
        let existingHashes = Dictionary(
            (existing?.manifest.entries ?? []).map { ($0.id, $0.contentHash) },
            uniquingKeysWith: { first, _ in first }
        )
        let presentIDs = (try? await cloudDataService.existingSealedPhotoIDs(corpus: corpus)) ?? []

        let generation = generationStore.mintNextPhoto(for: corpus)
        let keySalt = Self.mintKeySalt()

        var entries: [SealedPhotoManifest.Entry] = []
        for id in ids {
            // Cheap path first: this id is already committed AND its record is really there, and
            // this pass is not verifying bytes. Nothing is read, nothing is decrypted.
            if !verifyingContentHashes, let known = existingHashes[id], presentIDs.contains(id) {
                entries.append(SealedPhotoManifest.Entry(id: id, contentHash: known))
                summary.skipped += 1
                continue
            }
            guard let plaintext = try photo(id), !plaintext.isEmpty else {
                summary.unreadable += 1
                // KEEP a good cloud copy of a photo this device merely failed to read right now.
                // Dropping it from the manifest would let a transient local failure (locked
                // keychain, a file the migration has not re-sealed yet) delete the backup.
                if let hash = existingHashes[id], presentIDs.contains(id) {
                    entries.append(SealedPhotoManifest.Entry(id: id, contentHash: hash))
                }
                continue
            }
            let hash = Self.contentHash(plaintext)
            if existingHashes[id] == hash, presentIDs.contains(id) {
                entries.append(SealedPhotoManifest.Entry(id: id, contentHash: hash))
                summary.skipped += 1
                continue
            }
            try await save(plaintext, corpus: corpus, slot: .photo(id), generation: generation, keySalt: keySalt)
            entries.append(SealedPhotoManifest.Entry(id: id, contentHash: hash))
            summary.uploaded += 1
        }

        // UNION: keep every committed id this device does not have, unless this device is the one
        // that uploaded it and has since deleted it. See rule 4 above — own photos do not sync
        // between devices, so an unknown id is another phone's, not a deletion.
        var committed = Set(entries.map(\.id))
        for entry in existing?.manifest.entries ?? [] where !committed.contains(entry.id) {
            guard !prunableIDs.contains(entry.id) else { continue }
            entries.append(entry)
            committed.insert(entry.id)
        }

        try await writeManifest(
            // Same union reasoning for the sidecar: a caller that has none to offer must not erase
            // the committed one. (Today only the progress corpus carries one, and its coordinator
            // skips the whole upload rather than passing nil for an unreadable index — this is the
            // belt to that braces.)
            SealedPhotoManifest(
                corpus: corpus,
                entries: entries,
                sidecar: sidecar ?? existing?.manifest.sidecar
            ),
            generation: generation,
            keySalt: keySalt
        )

        for orphan in presentIDs.subtracting(committed) where prunableIDs.contains(orphan) {
            // Best-effort: an orphan that survives is ignored on restore (the manifest is the
            // authority on membership), so a failed delete costs quota, never correctness. Scoped to
            // `prunableIDs` for the same reason the union above exists — a body whose owner this
            // device cannot vouch for is left alone.
            if (try? await cloudDataService.deleteSealedPhoto(corpus: corpus, id: orphan)) != nil {
                summary.pruned += 1
            }
        }
        FernletAuditLog.log("sealedPhoto.reconciled", context: [
            "corpus": corpus.rawValue,
            "uploaded": String(summary.uploaded),
            "skipped": String(summary.skipped),
            "unreadable": String(summary.unreadable),
            "pruned": String(summary.pruned),
            "generation": String(generation)
        ])
        return summary
    }

    /// The **incremental add**: uploads one new photo record, then rewrites the (small) manifest.
    /// Every other record in the corpus is left byte-identical — the property the chunked scheme
    /// cannot offer.
    ///
    /// A corpus with no manifest yet gets one containing just this photo; the caller's full
    /// ``reconcile(corpus:ids:sidecar:verifyingContentHashes:prunableIDs:photo:)`` pass fills in the
    /// rest. Like that pass it never drops another id: the existing entries are carried forward.
    func addPhoto(
        _ plaintext: Data,
        id: UUID,
        corpus: SealedPhotoCorpus,
        sidecar: Data? = nil
    ) async throws {
        let existing = try? await openManifest(corpus: corpus)
        if let existing {
            generationStore.recordAcceptedPhoto(existing.generation, for: corpus)
        }
        let generation = generationStore.mintNextPhoto(for: corpus)
        let keySalt = Self.mintKeySalt()
        try await save(plaintext, corpus: corpus, slot: .photo(id), generation: generation, keySalt: keySalt)

        var entries = (existing?.manifest.entries ?? []).filter { $0.id != id }
        entries.append(SealedPhotoManifest.Entry(id: id, contentHash: Self.contentHash(plaintext)))
        try await writeManifest(
            SealedPhotoManifest(
                corpus: corpus,
                entries: entries,
                sidecar: sidecar ?? existing?.manifest.sidecar
            ),
            generation: generation,
            keySalt: keySalt
        )
        FernletAuditLog.log("sealedPhoto.added", context: [
            "corpus": corpus.rawValue, "generation": String(generation)
        ])
    }

    /// Removes one photo from the backup: drops it from the manifest (the commit), then deletes its
    /// record best-effort.
    ///
    /// Manifest FIRST here, unlike an add — the manifest is the authority on membership, so once the
    /// entry is gone the photo is logically removed even if the record delete fails and leaves an
    /// ignored orphan behind. A no-op when there is no manifest to edit.
    func deletePhoto(id: UUID, corpus: SealedPhotoCorpus, sidecar: Data? = nil) async throws {
        guard let existing = try? await openManifest(corpus: corpus) else { return }
        generationStore.recordAcceptedPhoto(existing.generation, for: corpus)
        let entries = existing.manifest.entries.filter { $0.id != id }
        let generation = generationStore.mintNextPhoto(for: corpus)
        try await writeManifest(
            SealedPhotoManifest(
                corpus: corpus,
                entries: entries,
                sidecar: sidecar ?? existing.manifest.sidecar
            ),
            generation: generation,
            keySalt: Self.mintKeySalt()
        )
        try? await cloudDataService.deleteSealedPhoto(corpus: corpus, id: id)
        FernletAuditLog.log("sealedPhoto.deleted", context: [
            "corpus": corpus.rawValue, "generation": String(generation)
        ])
    }

    // MARK: - Restore

    /// Restores a corpus, handing each opened photo to `write` one at a time.
    ///
    /// Order, mirroring `SealedBackupService.restoreChunks` exactly: open the manifest (so the
    /// generation it claims has been AUTHENTICATED before it is compared), then check the rollback
    /// high-water mark, then raise it, then fetch bodies. Checking before opening would let a forged
    /// high generation suppress the check.
    ///
    /// Per-photo failures are isolated by design: a record not in the manifest is an ignored orphan,
    /// and a manifest id with no openable record — or one whose bytes do not match the hash the
    /// manifest committed — fails that photo and is reported in
    /// ``SealedPhotoRestoreSummary/failed``, never the whole set. `write` returns whether the bytes
    /// reached the local store; a refusal counts as a failed photo.
    ///
    /// - Returns: nil when the corpus has no manifest at all (nothing was ever committed).
    /// - Throws: `SealedBackupError.staleGeneration` on rollback, `.keyAgreementIdentityMismatch`
    ///   when the manifest is not ours, `.malformedRecord` when it is ours but corrupt.
    func restore(
        corpus: SealedPhotoCorpus,
        write: (UUID, Data) -> Bool
    ) async throws -> SealedPhotoRestoreSummary? {
        guard let opened = try await openManifest(corpus: corpus) else { return nil }
        let lastSeen = generationStore.lastSeenPhoto(for: corpus)
        guard opened.generation >= lastSeen else {
            FernletAuditLog.log("sealedPhoto.restore.staleGeneration", context: [
                "corpus": corpus.rawValue,
                "found": String(opened.generation),
                "lastSeen": String(lastSeen)
            ])
            throw SealedBackupError.staleGeneration(found: opened.generation, lastSeen: lastSeen)
        }
        generationStore.recordAcceptedPhoto(opened.generation, for: corpus)

        var summary = SealedPhotoRestoreSummary(sidecar: opened.manifest.sidecar)
        for entry in opened.manifest.entries {
            guard let record = try? await cloudDataService.sealedPhoto(corpus: corpus, slot: .photo(entry.id)),
                  let plaintext = try? SealedPhotoCrypto.open(record, identityService: identityService),
                  Self.contentHash(plaintext) == entry.contentHash,
                  write(entry.id, plaintext) else {
                summary.failed.append(entry.id)
                continue
            }
            summary.restored += 1
        }
        FernletAuditLog.log("sealedPhoto.restored", context: [
            "corpus": corpus.rawValue,
            "restored": String(summary.restored),
            "failed": String(summary.failed.count),
            "generation": String(opened.generation)
        ])
        return summary
    }

    /// The corpus sidecar (the progress timeline index) from the committed manifest, or nil when
    /// there is no manifest or it carries none.
    ///
    /// A diagnostic/read-only accessor. The restore path does NOT use it — it takes the sidecar from
    /// ``SealedPhotoRestoreSummary/sidecar``, which came out of the same manifest whose generation it
    /// checked; re-fetching would reopen a window for an older-but-authentic manifest's index.
    func sidecar(corpus: SealedPhotoCorpus) async throws -> Data? {
        try await openManifest(corpus: corpus)?.manifest.sidecar
    }

    /// Tears the whole corpus down — every photo record and the manifest. The delete-all leg.
    func deleteCorpus(_ corpus: SealedPhotoCorpus) async throws {
        try await cloudDataService.deleteSealedPhotoCorpus(corpus)
    }

    // MARK: - Internals

    /// Fetches and opens a corpus manifest, returning it with the generation its record carried.
    ///
    /// The decoded `corpus` is re-checked against the corpus asked for: it is bound into the AAD, so
    /// a mismatch cannot survive a legitimate seal, and failing closed here keeps a manifest from
    /// ever being interpreted for the wrong corpus.
    private func openManifest(
        corpus: SealedPhotoCorpus
    ) async throws -> (manifest: SealedPhotoManifest, generation: Int64)? {
        guard let record = try await cloudDataService.sealedPhoto(corpus: corpus, slot: .manifest) else {
            return nil
        }
        let plaintext = try SealedPhotoCrypto.open(record, identityService: identityService)
        guard let manifest = try? JSONDecoder().decode(SealedPhotoManifest.self, from: plaintext),
              manifest.corpus == corpus else {
            throw SealedBackupError.malformedRecord
        }
        return (manifest, record.generation)
    }

    private func writeManifest(
        _ manifest: SealedPhotoManifest,
        generation: Int64,
        keySalt: Data
    ) async throws {
        try await save(
            try JSONEncoder().encode(manifest),
            corpus: manifest.corpus,
            slot: .manifest,
            generation: generation,
            keySalt: keySalt
        )
    }

    private func save(
        _ plaintext: Data,
        corpus: SealedPhotoCorpus,
        slot: SealedPhotoSlot,
        generation: Int64,
        keySalt: Data
    ) async throws {
        let record = try SealedPhotoCrypto.seal(
            plaintext,
            corpus: corpus,
            slot: slot,
            identityService: identityService,
            generation: generation,
            keySalt: keySalt
        )
        try await cloudDataService.saveSealedPhoto(record)
    }

    /// SHA-256 of a photo's plaintext — what the manifest commits per id, and what a restore
    /// re-computes before trusting the bytes it opened.
    static func contentHash(_ plaintext: Data) -> Data {
        Data(SHA256.hash(data: plaintext))
    }

    /// Mints one write's HKDF salt: 32 CSPRNG bytes. Never empty — an empty salt is not a valid
    /// spelling of this record type (``SealedPhotoCrypto/seal`` refuses it).
    private static func mintKeySalt() -> Data {
        SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
    }
}

private extension AES.GCM.Nonce {
    /// The nonce's raw bytes, for storage in a ``SealedPhotoRecord``.
    var data: Data {
        withUnsafeBytes { Data($0) }
    }
}
