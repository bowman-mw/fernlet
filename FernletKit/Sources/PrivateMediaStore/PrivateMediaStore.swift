import Foundation
import UIKit
import ImageIO
import CryptoKit
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
    private let imageDirectoryURL: URL
    private let thumbnailDirectoryURL: URL
    private let keyProvider: PrivateMediaKeyProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    // Reject incoming photos larger than this to prevent decompression-bomb OOM.
    private static let maxIncomingPhotoBytes = 10 * 1024 * 1024  // 10 MB
    private static let thumbnailMaxPixelSize = 400
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
        self.imageDirectoryURL = baseURL.appendingPathComponent("MeshPhotos", isDirectory: true)
        self.thumbnailDirectoryURL = baseURL.appendingPathComponent("MeshPhotoThumbnails", isDirectory: true)
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
        case .deferred:
            FernletAuditLog.log("privateMedia.indexDeferred", context: ["reason": "noKey"])
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
        createDirectories()
        for photo in capped {
            guard let imageData = photo.imageData else { continue }
            guard imageData.count <= Self.maxIncomingPhotoBytes else {
                print("[Fernlet] Dropped oversized peer photo (\(imageData.count) bytes)")
                continue
            }
            guard Self.isWithinSafePixelBounds(imageData) else {
                print("[Fernlet] Dropped peer photo exceeding safe pixel dimensions")
                continue
            }
            // Encrypt the plaintext bytes (post-validation) before they touch disk. If no key is
            // available we skip persisting bytes rather than write plaintext; the metadata index
            // is still saved and the photo rehydrates from the mesh on demand. Deliberately
            // two-step (seal, then best-effort write) rather than `sealAndWrite`: a failed image
            // write still proceeds to the thumbnail write, while a nil key skips both.
            guard let sealedImage = keyProvider.gcmSeal(imageData) else { continue }
            do {
                try sealedImage.write(to: imageURL(for: photo.id), options: [.atomic, .completeFileProtection])
            } catch {
                // Recovery: continue to the thumbnail write (the documented behaviour) — but the
                // failure is named, so a wall entry whose full-size bytes never persisted is not silent.
                FernletAuditLog.log(
                    "privateMedia.imageWriteFailed",
                    context: ["id": photo.id.uuidString, "error": "\(error)"]
                )
            }
            if let thumbnailData = Self.safeThumbnailData(from: imageData) {
                keyProvider.sealAndWriteBestEffort(thumbnailData, to: thumbnailURL(for: photo.id), reason: "thumbnail")
            }
        }
        // NEVER sweep against an index that was not committed: the on-disk index still names the
        // OLD photo set, so a sweep keyed on the NEW set would delete files it still references.
        guard writeSealedIndex(capped) else { return }
        removeOrphanedFiles(keeping: Set(capped.map(\.id)))
    }

    /// The canonical index view: newest first, capped at ``maxCachedPhotos``. ``save(_:)`` commits
    /// exactly this, and ``loadIndex()`` returns exactly this, so a caller's in-memory list can
    /// never disagree with the file manifest that was written.
    private static func cappedNewestFirst(_ photos: [FriendPhotoPayload]) -> [FriendPhotoPayload] {
        Array(photos.sorted { $0.addedAt > $1.addedAt }.prefix(maxCachedPhotos))
    }

    /// Seals and writes the metadata index (sender names, fingerprints, times), replacing whichever
    /// generation is on disk.
    ///
    /// Fail-closed like the photo bytes: with no key NOTHING is written, so the index never lands in
    /// the clear and the previous file — sealed or legacy plaintext — is left exactly as it was for
    /// the next attempt.
    /// - Returns: whether the index was committed; ``save(_:)``'s orphan sweep depends on it.
    private func writeSealedIndex(_ capped: [FriendPhotoPayload]) -> Bool {
        guard let data = try? encoder.encode(capped.map { $0.withoutImageData() }) else { return false }
        guard let sealed = keyProvider.gcmSeal(data) else {
            FernletAuditLog.log(
                "privateMedia.indexSealSkipped",
                context: ["reason": "noKey", "recovery": "orphanSweepSkipped"]
            )
            return false
        }
        do {
            try sealed.write(to: sealedIndexURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            FernletAuditLog.log(
                "privateMedia.indexWriteFailed",
                context: ["error": "\(error)", "recovery": "orphanSweepSkipped"]
            )
            return false
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
        guard let stored = try? Data(contentsOf: imageURL(for: photo.id)) else { return nil }
        switch openSealed(stored) {
        case .opened(let data):
            return data
        case .legacyPlaintext(let data):
            // Upgrade a pre-encryption plaintext file to ciphertext on first access (spec §11).
            keyProvider.sealAndWriteBestEffort(data, to: imageURL(for: photo.id), reason: "legacyPlaintextUpgrade")
            return data
        case .unreadable:
            return nil
        }
    }

    /// Returns plaintext thumbnail bytes for a photo, decrypting the cached thumbnail or
    /// regenerating (and sealing) one from the full image when the cache is missing or corrupt.
    ///
    /// Like ``imageData(for:)``, a legacy plaintext thumbnail is re-sealed in place on first
    /// access. Returns nil only when neither a thumbnail nor the full image can be opened.
    public func thumbnailData(for photo: FriendPhotoPayload) -> Data? {
        if let stored = try? Data(contentsOf: thumbnailURL(for: photo.id)) {
            switch openSealed(stored) {
            case .opened(let data):
                return data
            case .legacyPlaintext(let data):
                keyProvider.sealAndWriteBestEffort(data, to: thumbnailURL(for: photo.id), reason: "legacyThumbnailUpgrade")
                return data
            case .unreadable:
                break  // corrupt/unopenable thumbnail — regenerate from the full image below
            }
        }
        guard let data = imageData(for: photo),
              let thumbnailData = Self.safeThumbnailData(from: data) else { return nil }
        keyProvider.sealAndWriteBestEffort(thumbnailData, to: thumbnailURL(for: photo.id), reason: "regeneratedThumbnail")
        return thumbnailData
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
        /// A sealed index exists but no media key is available right now (an `AfterFirstUnlock`
        /// keychain row before the first post-boot unlock). Transient: retry, never write over it.
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
        case deferred
        case unrecoverable
    }

    /// Reads the index, sealed generation first, and classifies what it found.
    ///
    /// The sealed file wins whenever it exists: once migration has written it, a plaintext file
    /// left behind by a failed delete is stale by construction and must never be preferred.
    private func readIndex() -> IndexReadResult {
        if let stored = try? Data(contentsOf: sealedIndexURL), !stored.isEmpty {
            guard let opened = keyProvider.gcmOpen(stored),
                  let photos = try? decoder.decode([FriendPhotoPayload].self, from: opened) else {
                // No key at all is transient (the row is `AfterFirstUnlock`); a key that is present
                // and still does not open these bytes is not.
                return keyProvider.mediaKey() == nil ? .deferred : .unrecoverable
            }
            return .entries(photos, legacyPlaintext: false)
        }
        guard let legacy = try? Data(contentsOf: indexURL), !legacy.isEmpty else { return .absent }
        // Pre-sealing generation. Deliberately NOT gated on a key being available, unlike the photo
        // bytes in `openSealed`: these bytes are already plaintext on disk, so reading them
        // discloses nothing new, while refusing would strand the wall's whole index — and its file
        // manifest — behind a locked keychain. Sealing is retried on the next load.
        guard let photos = try? decoder.decode([FriendPhotoPayload].self, from: legacy) else {
            return .unrecoverable
        }
        return .entries(photos, legacyPlaintext: true)
    }

    // MARK: - At-rest encryption

    /// Three-way outcome of opening an on-disk media file via `openSealed(_:)`.
    ///
    /// Read paths branch on this to keep the seal seam fail-closed: only `.opened` and
    /// `.legacyPlaintext` ever hand bytes to a caller, and `.legacyPlaintext` additionally
    /// triggers an in-place re-seal so the plaintext generation shrinks over time.
    private enum OpenResult {
        case opened(Data)           // decrypted from ciphertext
        case legacyPlaintext(Data)  // a pre-encryption plaintext file (re-encrypted in place on access)
        case unreadable             // no key, or bytes that are neither openable nor a valid image
    }

    /// Opens AES-256-GCM bytes. GCM open fails both for legacy pre-encryption plaintext files and
    /// for genuinely undecodable bytes (wrong/lost key, corruption). We distinguish the two by
    /// checking whether the raw bytes are themselves a valid image — so a wrong key or a corrupt
    /// file resolves to `.unreadable` (treated as missing) rather than handing ciphertext/garbage
    /// back as if it were a photo. Files that predate encryption passed the same pixel-bounds gate
    /// at save time, so they are recognised as `.legacyPlaintext` and upgraded on access.
    private func openSealed(_ stored: Data) -> OpenResult {
        // The explicit nil-key guard is load-bearing: without a key NOTHING opens — a legacy
        // plaintext file is `.unreadable` here, never handed back as a photo.
        guard keyProvider.mediaKey() != nil else { return .unreadable }
        if let plaintext = keyProvider.gcmOpen(stored) {
            return .opened(plaintext)
        }
        return Self.isWithinSafePixelBounds(stored) ? .legacyPlaintext(stored) : .unreadable
    }

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

    // MARK: - Safe thumbnail generation

    /// Generates a thumbnail using ImageIO to avoid fully decompressing untrusted image data.
    /// Checks pixel dimensions before decode and caps output at thumbnailMaxPixelSize.
    private static func safeThumbnailData(from imageData: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(imageData as CFData, nil) else { return nil }

        // Check dimensions without full decode.
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            // Reject unreasonably large images that would OOM even as thumbnails.
            if width > 20_000 || height > 20_000 { return nil }
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: thumbnailMaxPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let uiImage = UIImage(cgImage: cgImage)
        return uiImage.jpegData(compressionQuality: 0.7)
    }

    /// Creates the image and thumbnail directories. A failure is logged rather than dropped: every
    /// later photo write would otherwise fail with a misleading error and no recorded root cause.
    private func createDirectories() {
        for directory in [imageDirectoryURL, thumbnailDirectoryURL] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                FernletAuditLog.log(
                    "privateMedia.directoryCreateFailed",
                    context: ["directory": directory.lastPathComponent, "error": "\(error)"]
                )
            }
        }
    }

    private func imageURL(for id: UUID) -> URL {
        imageDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// Deletes files whose id is no longer in the committed index. Only ever called after the index
    /// write succeeded (see ``save(_:)``). A file that cannot be removed is logged: it holds a friend
    /// photo the wall has already evicted past its cap.
    private func removeOrphanedFiles(keeping ids: Set<UUID>) {
        for directoryURL in [imageDirectoryURL, thumbnailDirectoryURL] {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { continue }
            for url in urls {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !ids.contains(id) else { continue }
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    // Recovery: continue the sweep — one stuck file must not abandon the rest.
                    FernletAuditLog.log(
                        "privateMedia.orphanRemoveFailed",
                        context: ["file": url.lastPathComponent, "error": "\(error)"]
                    )
                }
            }
        }
    }
}
