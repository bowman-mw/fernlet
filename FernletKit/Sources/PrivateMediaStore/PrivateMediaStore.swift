import Foundation
import UIKit
import ImageIO
import CryptoKit
import FernletDomainModel

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
/// "Photos are stored in `PrivateMediaStore` with encryption"); only metadata lives in the
/// (unencrypted) JSON index. Files retain `.completeFileProtection` as defense-in-depth.
/// Because the photos arrive from PEERS, every write path is guarded against decompression
/// bombs: a byte-size cap plus an ImageIO pixel-dimension/area check that never decodes the
/// full bitmap (``isWithinSafePixelBounds(_:)``). Fail-closed throughout — when no key is
/// available, plaintext bytes are dropped rather than written; bytes that neither GCM-open nor
/// parse as a safe image read back as missing, never as garbage handed to the UI.
///
/// On-disk names (`MeshPhotoCache.json`, `MeshPhotos/`, `MeshPhotoThumbnails/`) are kept from the
/// former `MeshPhotoCacheStore` so existing caches load without migration; legacy plaintext files
/// are recognised on read and re-encrypted in place on first access.
///
/// Concurrency: a plain nonisolated value type with no internal locking. All state is on disk;
/// in practice every instance is confined to `MeshNetworkManager`'s main actor. The default
/// ``KeychainPrivateMediaKeyProvider`` caches its key without synchronization, so instances
/// sharing a provider must share an isolation domain.
public struct PrivateMediaStore {
    private let indexURL: URL
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

    /// Creates a store rooted at `indexURL`'s directory.
    ///
    /// - Parameters:
    ///   - indexURL: Location of the metadata index JSON; the `MeshPhotos/` and
    ///     `MeshPhotoThumbnails/` directories are created as its siblings.
    ///   - keyProvider: Source of the AES-256-GCM at-rest key; defaults to the shared
    ///     keychain-backed provider, with tests injecting an in-memory one.
    public init(indexURL: URL, keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider()) {
        self.indexURL = indexURL
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
    /// Also re-runs ``save(_:)`` on the decoded entries as a normalization pass (cap enforcement +
    /// orphan-file sweep). Bytes are fetched lazily per photo via ``imageData(for:)`` /
    /// ``thumbnailData(for:)``. An unreadable or absent index reads as empty.
    /// - Returns: The index entries (metadata only; `imageData` is nil on every payload).
    public func load() -> [FriendPhotoPayload] {
        guard let data = try? Data(contentsOf: indexURL), !data.isEmpty,
              let photos = try? decoder.decode([FriendPhotoPayload].self, from: data) else { return [] }
        save(photos)
        return photos.map { $0.withoutImageData() }
    }

    /// Persists the photo set: seals each payload's in-memory bytes to disk, writes the
    /// byte-less metadata index, and sweeps files no longer referenced.
    ///
    /// The set is capped at ``maxCachedPhotos`` (newest by `addedAt` win). Per photo, bytes are
    /// written only after passing the size cap and ``isWithinSafePixelBounds(_:)``, and only
    /// sealed — with no key available the bytes are skipped (the metadata entry is still indexed
    /// and the photo rehydrates from the mesh on demand). Payloads without in-memory bytes keep
    /// whatever file already exists for their id.
    /// - Important: This is a full-index rewrite; pass the COMPLETE set, not a delta —
    ///   any photo omitted here has its on-disk files deleted as orphans.
    public func save(_ photos: [FriendPhotoPayload]) {
        let capped = Array(photos.sorted { $0.addedAt > $1.addedAt }.prefix(Self.maxCachedPhotos))
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
            // is still saved and the photo rehydrates from the mesh on demand.
            guard let sealedImage = encrypt(imageData) else { continue }
            try? sealedImage.write(to: imageURL(for: photo.id), options: [.atomic, .completeFileProtection])
            if let thumbnailData = Self.safeThumbnailData(from: imageData),
               let sealedThumbnail = encrypt(thumbnailData) {
                try? sealedThumbnail.write(to: thumbnailURL(for: photo.id), options: [.atomic, .completeFileProtection])
            }
        }
        guard let data = try? encoder.encode(capped.map { $0.withoutImageData() }) else { return }
        try? data.write(to: indexURL, options: [.atomic, .completeFileProtection])
        removeOrphanedFiles(keeping: Set(capped.map(\.id)))
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
            reseal(data, to: imageURL(for: photo.id))
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
                reseal(data, to: thumbnailURL(for: photo.id))
                return data
            case .unreadable:
                break  // corrupt/unopenable thumbnail — regenerate from the full image below
            }
        }
        guard let data = imageData(for: photo),
              let thumbnailData = Self.safeThumbnailData(from: data) else { return nil }
        reseal(thumbnailData, to: thumbnailURL(for: photo.id))
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

    /// Seals plaintext bytes with AES-256-GCM under the store's key. Returns nil if no key.
    private func encrypt(_ plaintext: Data) -> Data? {
        guard let key = keyProvider.mediaKey() else { return nil }
        return try? AES.GCM.seal(plaintext, using: key).combined
    }

    /// Encrypts and atomically overwrites a file with the sealed bytes (best-effort).
    private func reseal(_ plaintext: Data, to url: URL) {
        guard let sealed = encrypt(plaintext) else { return }
        try? sealed.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Opens AES-256-GCM bytes. GCM open fails both for legacy pre-encryption plaintext files and
    /// for genuinely undecodable bytes (wrong/lost key, corruption). We distinguish the two by
    /// checking whether the raw bytes are themselves a valid image — so a wrong key or a corrupt
    /// file resolves to `.unreadable` (treated as missing) rather than handing ciphertext/garbage
    /// back as if it were a photo. Files that predate encryption passed the same pixel-bounds gate
    /// at save time, so they are recognised as `.legacyPlaintext` and upgraded on access.
    private func openSealed(_ stored: Data) -> OpenResult {
        guard let key = keyProvider.mediaKey() else { return .unreadable }
        if let box = try? AES.GCM.SealedBox(combined: stored),
           let plaintext = try? AES.GCM.open(box, using: key) {
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

    private func createDirectories() {
        try? FileManager.default.createDirectory(at: imageDirectoryURL, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: thumbnailDirectoryURL, withIntermediateDirectories: true)
    }

    private func imageURL(for id: UUID) -> URL {
        imageDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    private func removeOrphanedFiles(keeping ids: Set<UUID>) {
        for directoryURL in [imageDirectoryURL, thumbnailDirectoryURL] {
            guard let urls = try? FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil) else { continue }
            for url in urls {
                guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                      !ids.contains(id) else { continue }
                try? FileManager.default.removeItem(at: url)
            }
        }
    }
}
