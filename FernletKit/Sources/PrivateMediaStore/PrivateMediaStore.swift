import Foundation
import UIKit
import ImageIO
import CryptoKit
import FernletCrypto
import FernletDomainModel
import FernletFoundation

/// On-device, at-rest-encrypted store for friend/mesh media (the photowall cache).
///
/// This is the peer-photo half of the module: `MeshNetworkManager` (in `ProximityKit`) owns one
/// instance as its photowall cache, persisting the photos friends share over the proximity mesh.
/// Self-contained: it depends only on Foundation/CryptoKit/ImageIO and an injected
/// ``PrivateMediaKeyProviding``. It shares files with nothing else and is a sealed S3 store
/// (spec §3 — `PrivateMediaStore` must not be importable by AI providers; the SPM dependency
/// graph enforces that wall).
///
/// Image and thumbnail bytes are encrypted with AES-256-GCM before they touch disk (spec §11:
/// "Photos are stored in `PrivateMediaStore` with encryption"), and so is the metadata index —
/// `senderName`, `senderFingerprint` and `addedAt` used to sit in the clear beside the sealed
/// bytes they describe. Files retain `.completeFileProtection` as defense-in-depth.
/// Because the photos arrive from PEERS, every write path is guarded against decompression
/// bombs: a byte-size cap plus an ImageIO pixel-dimension/area check that never decodes the
/// full bitmap (``isWithinSafePixelBounds(_:)``). Fail-closed throughout — when no key is
/// available, plaintext bytes are dropped rather than written; bytes that neither GCM-open nor
/// parse as a safe image read back as missing, never as garbage handed to the UI.
///
/// On-disk names (`MeshPhotos/`, `MeshPhotoThumbnails/`) are kept from the former
/// `MeshPhotoCacheStore` so existing caches load without migration; legacy plaintext files are
/// recognised on read and re-encrypted in place on first access. The index is the one file that
/// moved: the plaintext `MeshPhotoCache.json` a caller passes as `indexURL` is read once, rewritten
/// sealed as `MeshPhotoCache.sealed`, and only then deleted (``loadIndex()``).
///
/// - Important: the index is also the wall's file manifest — ``save(_:)`` deletes every photo file
///   the index does not name. An index that cannot be READ therefore must never be mistaken for an
///   empty wall, which is why ``loadIndex()`` reports a deferred read instead of an empty array.
///
/// Concurrency: a plain nonisolated value type with no internal locking. All state is on disk;
/// in practice every instance is confined to `MeshNetworkManager`'s main actor. The default
/// ``KeychainPrivateMediaKeyProvider`` caches its key without synchronization, so instances
/// sharing a provider must share an isolation domain.
public struct PrivateMediaStore {
    private let indexURL: URL
    private let sealedIndexURL: URL
    /// The wall's photo and thumbnail files: `MeshPhotos/` + `MeshPhotoThumbnails/`, the wall's
    /// purposes, legacy plaintext allowed. Shared machinery with ``PendingSessionPhotoStore``.
    private let files: FriendPhotoCorpusFiles
    private let keyProvider: PrivateMediaKeyProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// The largest incoming photo this store will accept, in **plaintext** bytes — the
    /// decompression-bomb byte cap, paired with ``isWithinSafePixelBounds(_:)``'s pixel check
    /// because a tiny, highly-compressed image can still decode to a multi-gigabyte bitmap.
    ///
    /// `public` since P6 item 3 so the routed mesh path can **derive** its per-type ciphertext cap
    /// from this one number instead of restating it: `ProximityKit` owns this store as its
    /// photowall cache and already depends on the module, and the S3 wall it sits behind is about
    /// which targets may import `PrivateMediaStore` at all (the AI providers may not) — never about
    /// the visibility of a byte bound inside it. Two restatements of "10 MB" that could drift is the
    /// larger risk; see `MeshRoutedItemSealFormat.maxResidentBlobByteCount`.
    public static let maxIncomingPhotoBytes = 10 * 1024 * 1024  // 10 MB
    // A small, highly-compressed JPEG can decode to a multi-gigabyte bitmap, so the byte cap
    // above is not sufficient. Reject by pixel dimensions/area before the full-resolution bytes
    // are ever persisted (and therefore before any display/library-save sink decodes them).
    // Legitimately shared photos are downscaled to <=1400px, so these bounds leave wide headroom.
    private static let maxImagePixelDimension = 6_000
    private static let maxImagePixelCount = 24_000_000  // ~24 MP
    // Spec §11: cap the on-device photo cache at 1000 (FIFO by recency), with a soft warning near 900.
    // Newest photos are kept; oldest are evicted.
    /// Hard cap on cached photos (spec §11). ``save(_:)`` keeps the newest and evicts the rest.
    public static let maxCachedPhotos = 1000
    /// Soft threshold at which the UI warns the user the photo cache is nearly full.
    public static let cacheWarningThreshold = 900
    // Frozen on-disk token: the extension the sealed index is written under, beside the legacy
    // plaintext index it replaces. Never localized, never renamed — a rename strands every
    // existing wall's index behind a file nothing looks for.
    private static let sealedIndexExtension = "sealed"

    /// Creates a store rooted at `indexURL`'s directory.
    ///
    /// - Parameters:
    ///   - indexURL: Location of the LEGACY plaintext metadata index; the sealed index replaces it
    ///     at the same path with the `.sealed` extension, and the `MeshPhotos/` and
    ///     `MeshPhotoThumbnails/` directories are created as its siblings.
    ///   - keyProvider: Source of the AES-256-GCM at-rest key; defaults to the keychain-backed
    ///     FRIEND-WALL provider — the original, backup-restorable row, which the Phase-5 key split
    ///     left untouched precisely so the wall needs no re-encryption. Tests inject an in-memory
    ///     one. This store has no dual-open fallback and needs none: its key never changed.
    public init(indexURL: URL, keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider(role: .friendWall)) {
        self.indexURL = indexURL
        self.sealedIndexURL = indexURL.deletingPathExtension()
            .appendingPathExtension(Self.sealedIndexExtension)
        let baseURL = indexURL.deletingLastPathComponent()
        self.files = FriendPhotoCorpusFiles(
            imageDirectoryURL: baseURL.appendingPathComponent("MeshPhotos", isDirectory: true),
            thumbnailDirectoryURL: baseURL.appendingPathComponent("MeshPhotoThumbnails", isDirectory: true),
            imagePurpose: FernletCryptoPurpose.AEAD.privateFriendPhotoImageV2,
            thumbnailPurpose: FernletCryptoPurpose.AEAD.privateFriendPhotoThumbnailV2,
            allowsLegacyPlaintext: true,
            keyProvider: keyProvider,
            auditCorpus: "friendWall"
        )
        self.keyProvider = keyProvider
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder.dateDecodingStrategy = .iso8601
    }

    /// Delete-all seam (Docs/PrivacyWipeCoverage.md): drops this store's provider-cached media
    /// key after the shared keychain row is deleted, so RAM matches the keychain until relaunch.
    public func invalidateEncryptionKeyCache() {
        keyProvider.invalidateCachedKey()
    }

    /// Loads the cached photo metadata, newest first, with image bytes stripped.
    ///
    /// Convenience over ``loadIndex()`` for callers that have nothing to do about a deferred read:
    /// both failure classes read as an empty wall. `MeshNetworkManager` — the one owner that also
    /// SAVES the index — uses ``loadIndex()`` instead, because an empty array it cannot tell apart
    /// from a locked keychain is exactly what a later save would write over the real index.
    /// - Returns: The index entries (metadata only; `imageData` is nil on every payload).
    public func load() -> [FriendPhotoPayload] {
        guard case .entries(let photos) = loadIndex() else { return [] }
        return photos
    }

    /// Loads the metadata index, classifying a read that produced nothing (see ``IndexLoad``).
    ///
    /// Also re-runs ``save(_:)`` on the decoded entries as a normalization pass (cap enforcement +
    /// orphan-file sweep) — and for a pre-sealing plaintext index that same pass IS the migration:
    /// the entries are rewritten sealed, and the plaintext original is deleted only once the sealed
    /// file exists. Bytes are fetched lazily per photo via ``imageData(for:)`` /
    /// ``thumbnailData(for:)``.
    public func loadIndex() -> IndexLoad {
        switch readIndex() {
        case .absent:
            return .entries([])
        case .entries(let photos, let legacyPlaintext):
            save(photos)
            if legacyPlaintext { removeMigratedPlaintextIndex() }
            // The COMMITTED view, not the decoded one: `save` caps and reorders, and a caller
            // holding entries the file manifest no longer names would re-save photos whose bytes
            // were just swept (a legacy index could carry more than the cap).
            return .entries(Self.cappedNewestFirst(photos).map { $0.withoutImageData() })
        case .deferred(let reason):
            FernletAuditLog.log("privateMedia.indexDeferred", context: ["reason": reason])
            return .deferred
        case .unrecoverable:
            FernletAuditLog.log("privateMedia.indexUnrecoverable")
            return .unrecoverable
        }
    }

    /// Persists the photo set: seals each payload's in-memory bytes to disk, writes the
    /// byte-less metadata index, and sweeps files no longer referenced.
    ///
    /// The set is capped at ``maxCachedPhotos`` (newest by `addedAt` win). Per photo, bytes are
    /// written only after passing the size cap and ``isWithinSafePixelBounds(_:)``, and only
    /// sealed. Payloads without in-memory bytes keep whatever file already exists for their id.
    /// With no key available NOTHING is written — neither the bytes nor the index, which now
    /// carries the sender names and times under the same seal — and the previous index therefore
    /// stays authoritative until a key returns.
    /// - Important: This is a full-index rewrite; pass the COMPLETE set, not a delta —
    ///   any photo omitted here has its on-disk files deleted as orphans. Never pass a set derived
    ///   from an index that ``loadIndex()`` reported as ``IndexLoad/deferred``.
    public func save(_ photos: [FriendPhotoPayload]) {
        let capped = Self.cappedNewestFirst(photos)
        // A directory that cannot be created is audited inside; every write below then fails and
        // is audited on its own, and the index still commits the metadata (the wall's standing rule).
        _ = files.createDirectories()
        for photo in capped {
            guard let imageData = photo.imageData else { continue }
            // Refused bytes (cap, pixel bounds) and a keyless or failed write leave the index entry
            // in place, and the photo rehydrates from the mesh on demand — this store's contract
            // since before sealing. Only ``commitKept(_:onto:)`` must know which photos landed.
            _ = files.writeSealedImage(imageData, for: photo.id)
        }
        // NEVER sweep against an index that was not committed: the on-disk index still names the
        // OLD photo set, so a sweep keyed on the NEW set would delete files it still references.
        guard writeSealedIndex(capped) != nil else { return }
        files.removeOrphanedFiles(keeping: Set(capped.map(\.id)))
    }

    /// What ``commitKept(_:onto:)`` actually put on the wall.
    ///
    /// Concurrency: an immutable `Sendable` value.
    public struct WallKeepResult: Equatable, Sendable {
        /// Ids whose sealed image write landed AND that the committed index names — the only ids a
        /// caller may treat as kept, and the only ones an export may read back.
        public let keptOnWall: Set<UUID>
        /// Whether the wall index was rewritten. False when nothing landed (there was nothing to
        /// commit) or when the write failed (the files just written were removed again).
        public let indexCommitted: Bool
        /// The wall exactly as the committed index names it, metadata only, newest first — the
        /// same list a later ``load()`` returns, including which wall photos were evicted to make
        /// room. The owner REPLACES its in-memory wall with this; it never inserts the kept photos
        /// into its old list, because only the store knows which wall photos the keep evicted, and
        /// a mirror that still names an evicted photo (its bytes are gone) or misses a surviving
        /// one makes the owner's next full-index ``save(_:)`` sweep a photo nobody chose to lose.
        /// When ``indexCommitted`` is false the index was not rewritten and this is the `wall`
        /// passed in, unchanged.
        public let committedWall: [FriendPhotoPayload]

        /// Creates a result; the store is the only producer outside tests.
        public init(keptOnWall: Set<UUID>, indexCommitted: Bool, committedWall: [FriendPhotoPayload]) {
            self.keptOnWall = keptOnWall
            self.indexCommitted = indexCommitted
            self.committedWall = committedWall
        }
    }

    /// Adds chosen photos to the wall and reports, per photo, which ones are really on it.
    ///
    /// ``save(_:)`` answers "did the index get written", which cannot say whether a given photo is
    /// on the wall: it skips bytes it refuses or cannot seal, only audits a failed image write, and
    /// trims to the newest ``maxCachedPhotos`` by a peer-signed `addedAt`. A keep must never lose a
    /// photo the person ticked, so this is the one wall write an answer uses:
    ///
    /// 1. Each kept photo passes the byte cap and pixel bounds, is sealed and written; only a photo
    ///    whose full-size write landed joins `written` (the thumbnail stays best-effort). A kept id
    ///    already on `wall`, or repeated in `kept`, is refused.
    /// 2. Room is made by evicting only photos ALREADY on the wall, oldest `addedAt` first, so the
    ///    index is `written` plus the newest `maxCachedPhotos - written.count` wall photos: a kept
    ///    photo is never evicted by its own keep, whatever its `addedAt`.
    /// 3. The index is written. On failure the files just written are removed (the old index never
    ///    named them) and nothing is reported kept.
    /// 4. Only after a committed index, the orphan sweep removes the evicted wall photos' files.
    ///
    /// The result carries the committed wall (``WallKeepResult/committedWall``), which the owner
    /// assigns as its new in-memory wall — never "old wall plus the kept photos".
    ///
    /// - Parameters:
    ///   - kept: The photos to add, each carrying its plaintext bytes (`imageData`).
    ///   - wall: The COMPLETE current wall, metadata only — never a set derived from a
    ///     ``IndexLoad/deferred`` read, for the same reason as ``save(_:)``.
    public func commitKept(_ kept: [FriendPhotoPayload], onto wall: [FriendPhotoPayload]) -> WallKeepResult {
        let written = writeKeptPhotos(kept, besides: wall)
        guard !written.isEmpty else {
            return WallKeepResult(keptOnWall: [], indexCommitted: false, committedWall: wall)
        }
        let room = max(0, Self.maxCachedPhotos - written.count)
        let survivors = wall.sorted { $0.addedAt > $1.addedAt }.prefix(room)
        let committed = Self.cappedNewestFirst(written + survivors)
        assert(committed.count == written.count + survivors.count, "a keep must never be trimmed by the cap")
        guard let committedWall = writeSealedIndex(committed) else {
            for photo in written { files.removeFiles(for: photo.id) }
            return WallKeepResult(keptOnWall: [], indexCommitted: false, committedWall: wall)
        }
        files.removeOrphanedFiles(keeping: Set(committedWall.map(\.id)))
        return WallKeepResult(keptOnWall: Set(written.map(\.id)), indexCommitted: true, committedWall: committedWall)
    }

    /// Step 1 of ``commitKept(_:onto:)``: writes each keepable photo's sealed bytes and returns the
    /// metadata of exactly those whose full-size write landed. Bounded by ``maxCachedPhotos``.
    private func writeKeptPhotos(
        _ kept: [FriendPhotoPayload],
        besides wall: [FriendPhotoPayload]
    ) -> [FriendPhotoPayload] {
        guard files.createDirectories() else { return [] }
        let wallIDs = Set(wall.map(\.id))
        var seen: Set<UUID> = []
        var written: [FriendPhotoPayload] = []
        for photo in kept.prefix(Self.maxCachedPhotos) {
            // Unreachable while a keep's ids are the pending corpus's local ids (never a wall id);
            // defended because writing over a wall photo's file would replace a kept photo's bytes.
            guard !wallIDs.contains(photo.id), seen.insert(photo.id).inserted else {
                FernletAuditLog.log("privateMedia.keepRefused", context: ["reason": "idOnWallOrRepeated"])
                continue
            }
            guard let imageData = photo.imageData else {
                FernletAuditLog.log("privateMedia.keepRefused", context: ["reason": "noBytes"])
                continue
            }
            guard files.writeSealedImage(imageData, for: photo.id) == .written else {
                // A thumbnail can land beside a failed full-size write; nothing names it.
                files.removeFiles(for: photo.id)
                continue
            }
            written.append(photo.withoutImageData())
        }
        return written
    }

    /// The canonical index view: newest first, capped at ``maxCachedPhotos``. ``save(_:)`` commits
    /// exactly this, ``loadIndex()`` returns exactly this, and ``commitKept(_:onto:)`` returns what
    /// it committed as ``WallKeepResult/committedWall``, so a caller that holds the returned view
    /// never disagrees with the file manifest that was written.
    private static func cappedNewestFirst(_ photos: [FriendPhotoPayload]) -> [FriendPhotoPayload] {
        Array(photos.sorted { $0.addedAt > $1.addedAt }.prefix(maxCachedPhotos))
    }

    /// Seals and writes the metadata index (sender names, fingerprints, times), replacing whichever
    /// generation is on disk.
    ///
    /// Fail-closed like the photo bytes: with no key NOTHING is written, so the index never lands in
    /// the clear and the previous file — sealed or legacy plaintext — is left exactly as it was for
    /// the next attempt.
    ///
    /// Every entry is first cut to the wire decode bounds
    /// (`FriendPhotoCorpusFiles.withinDecodeBounds(_:)`), and the encoded bytes are decoded back
    /// BEFORE anything is sealed: an index this build could not read would load as
    /// ``IndexLoad/unrecoverable``, and the save after that would sweep every kept photo. A body
    /// that does not read back is refused like a keyless write — the previous file stays.
    /// - Returns: the entries exactly as a later read decodes them (ISO-8601 drops fractional
    ///   seconds), or nil when nothing was committed; ``save(_:)``'s orphan sweep depends on it.
    private func writeSealedIndex(_ capped: [FriendPhotoPayload]) -> [FriendPhotoPayload]? {
        let entries = capped.map { FriendPhotoCorpusFiles.withinDecodeBounds($0.withoutImageData()) }
        guard let data = try? encoder.encode(entries) else { return nil }
        let readBack: [FriendPhotoPayload]
        do {
            readBack = try decoder.decode([FriendPhotoPayload].self, from: data)
        } catch {
            FernletAuditLog.log(
                "privateMedia.indexWouldNotReadBack",
                context: ["error": "\(error)", "recovery": "orphanSweepSkipped"]
            )
            return nil
        }
        guard let sealed = keyProvider.gcmSeal(
            data,
            purpose: FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2
        ) else {
            FernletAuditLog.log(
                "privateMedia.indexSealSkipped",
                context: ["reason": "noKey", "recovery": "orphanSweepSkipped"]
            )
            return nil
        }
        do {
            try sealed.write(to: sealedIndexURL, options: [.atomic, .completeFileProtection])
            return readBack
        } catch {
            FernletAuditLog.log(
                "privateMedia.indexWriteFailed",
                context: ["error": "\(error)", "recovery": "orphanSweepSkipped"]
            )
            return nil
        }
    }

    /// Completes the plaintext→sealed index migration by deleting the legacy file — but only once
    /// the sealed index it was rewritten into actually exists.
    ///
    /// The ordering is the whole point: a reseal that could not run (no key) or failed to write must
    /// leave the plaintext index in place, because it is then still the wall's only index. Retried
    /// on every later load until it lands.
    private func removeMigratedPlaintextIndex() {
        guard FileManager.default.fileExists(atPath: sealedIndexURL.path) else {
            FernletAuditLog.log("privateMedia.indexMigrationDeferred")
            return
        }
        do {
            try FileManager.default.removeItem(at: indexURL)
        } catch {
            // Named, not dropped: the entries are safe in the sealed file, but a plaintext copy of
            // every sender name and fingerprint is still on disk until a later load retries.
            FernletAuditLog.log(
                "privateMedia.legacyIndexRemoveFailed",
                context: ["error": "\(error)"]
            )
        }
    }

    /// Returns the full-resolution plaintext bytes for a photo, preferring in-memory bytes,
    /// then decrypting the on-disk file.
    ///
    /// A legacy pre-encryption plaintext file is returned and re-sealed in place on this first
    /// access. Returns nil when no file exists or the bytes can't be opened (missing key,
    /// corruption) — never ciphertext or garbage.
    public func imageData(for photo: FriendPhotoPayload) -> Data? {
        if let inMemory = photo.imageData { return inMemory }
        return files.imageData(forID: photo.id)
    }

    /// Returns plaintext thumbnail bytes for a photo, decrypting the cached thumbnail or
    /// regenerating (and sealing) one from the full image when the cache is missing or corrupt.
    ///
    /// Like ``imageData(for:)``, a legacy plaintext thumbnail is re-sealed in place on first
    /// access. Returns nil only when neither a thumbnail nor the full image can be opened.
    public func thumbnailData(for photo: FriendPhotoPayload) -> Data? {
        files.thumbnailData(forID: photo.id, inMemoryImage: photo.imageData)
    }

    /// Rebuilds a byte-less index payload into one carrying its decrypted image bytes
    /// (e.g. to re-share a cached photo over the mesh).
    ///
    /// - Returns: The payload with `imageData` populated, or nil when the bytes can't be loaded.
    public func hydrated(_ photo: FriendPhotoPayload) -> FriendPhotoPayload? {
        guard let data = imageData(for: photo) else { return nil }
        return FriendPhotoPayload(
            id: photo.id,
            imageData: data,
            addedAt: photo.addedAt,
            senderName: photo.senderName,
            senderFingerprint: photo.senderFingerprint,
            senderSigningPublicKey: photo.senderSigningPublicKey,
            session: photo.session
        )
    }

    // MARK: - Metadata index

    /// Outcome of reading the metadata index: the "genuinely empty" vs "not readable right now"
    /// distinction the wall's owner needs before it saves anything.
    ///
    /// The hazard this exists for is the one `ProtectedSidecar` documents for the heart sidecars —
    /// a store that treats every failed read as "no data" lets the next save write that emptiness
    /// over the real file. Here it is worse than losing metadata: ``save(_:)`` sweeps every photo
    /// file the index does not name, so an index read as empty would take the kept wall's bytes
    /// with it.
    public enum IndexLoad: Equatable {
        /// The index was read. An absent index is an empty wall — genuinely no photos.
        case entries([FriendPhotoPayload])
        /// An index exists but cannot be read right now: no media key is available (an
        /// `AfterFirstUnlock` keychain row before the first post-boot unlock), or the FILE itself
        /// cannot be read (a `.completeFileProtection` file while the device is locked, or any I/O
        /// error). Transient: retry, never write over it.
        case deferred
        /// The index exists, a key IS available, and the bytes still neither open nor decode —
        /// corruption, or a key row swept by the duress wipe. Nothing can recover these entries;
        /// the caller may start empty and let the next save replace the file.
        case unrecoverable
    }

    /// What the on-disk index turned out to be — the private, generation-aware form of
    /// ``IndexLoad`` that ``loadIndex()`` maps (running the migration for the legacy case).
    private enum IndexReadResult {
        case absent
        case entries([FriendPhotoPayload], legacyPlaintext: Bool)
        /// Carries the audit reason: `noKey` or `fileUnreadable`.
        case deferred(reason: String)
        case unrecoverable
    }

    /// One index file on disk, read without conflating "absent" and "cannot be read".
    private enum IndexFileRead {
        case absent
        case bytes(Data)
        case unreadable
    }

    /// Reads the index, sealed generation first, and classifies what it found.
    ///
    /// The sealed file wins whenever it exists: once migration has written it, a plaintext file
    /// left behind by a failed delete is stale by construction and must never be preferred. A file
    /// that EXISTS but cannot be read is a deferral, never absence: the key row is
    /// `AfterFirstUnlock` while the file is `.completeFileProtection`, so a background launch on a
    /// locked device has the key and still cannot read the file — reading that as an empty wall
    /// would let the next save sweep every kept photo.
    private func readIndex() -> IndexReadResult {
        switch readIndexFile(at: sealedIndexURL) {
        case .unreadable:
            return .deferred(reason: "fileUnreadable")
        case .bytes(let stored) where !stored.isEmpty:
            guard let opened = keyProvider.gcmOpen(
                stored,
                purpose: FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2
            ),
                  let photos = try? decoder.decode([FriendPhotoPayload].self, from: opened) else {
                // No key at all is transient (the row is `AfterFirstUnlock`); a key that is present
                // and still does not open these bytes is not.
                return keyProvider.mediaKey() == nil ? .deferred(reason: "noKey") : .unrecoverable
            }
            return .entries(photos, legacyPlaintext: false)
        case .absent, .bytes:
            break
        }
        return readLegacyIndex()
    }

    /// The pre-sealing generation of ``readIndex()``.
    ///
    /// Deliberately NOT gated on a key being available, unlike the photo bytes: these bytes are
    /// already plaintext on disk, so reading them discloses nothing new, while refusing would strand
    /// the wall's whole index — and its file manifest — behind a locked keychain. Sealing is retried
    /// on the next load.
    private func readLegacyIndex() -> IndexReadResult {
        switch readIndexFile(at: indexURL) {
        case .absent:
            return .absent
        case .unreadable:
            return .deferred(reason: "fileUnreadable")
        case .bytes(let legacy):
            guard !legacy.isEmpty else { return .absent }
            guard let photos = try? decoder.decode([FriendPhotoPayload].self, from: legacy) else {
                return .unrecoverable
            }
            return .entries(photos, legacyPlaintext: true)
        }
    }

    /// Reads one index file, keeping "not there" and "there but unreadable" apart.
    private func readIndexFile(at url: URL) -> IndexFileRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .absent }
        do {
            return .bytes(try Data(contentsOf: url))
        } catch {
            return .unreadable
        }
    }

    // MARK: - Decompression-bomb bounds

    /// Reads pixel dimensions via ImageIO (without decoding the pixels) and rejects images whose
    /// dimensions or total area would decompress to an unreasonable bitmap, independent of the
    /// on-the-wire byte size. Undeterminable dimensions are treated as unsafe.
    public static func isWithinSafePixelBounds(_ imageData: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return false
        }
        return width <= maxImagePixelDimension
            && height <= maxImagePixelDimension
            && width * height <= maxImagePixelCount
    }
}
