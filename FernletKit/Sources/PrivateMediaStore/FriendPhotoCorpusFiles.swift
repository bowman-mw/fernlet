import Foundation
import UIKit
import ImageIO
import FernletCrypto
import FernletFoundation

/// The file half every friend-photo corpus shares: where the sealed full-size bytes and thumbnails
/// live, how they are sealed and opened, and how files the corpus no longer names are swept.
///
/// Extracted from ``PrivateMediaStore`` (the friend photo WALL) so the sealed pending corpus
/// (``PendingSessionPhotoStore``, session photos nobody has chosen yet) runs the same
/// decompression-bomb checks, the same thumbnail path and the same orphan sweep instead of a second
/// copy of each. The two corpora differ only in what is injected here:
///
/// | | Wall | Pending |
/// | --- | --- | --- |
/// | Directories | `MeshPhotos/`, `MeshPhotoThumbnails/` beside the wall index | `Photos/`, `Thumbnails/` inside `PendingSessionPhotos/` |
/// | Purposes | `privateFriendPhoto{Image,Thumbnail}V2` | `privatePendingSessionPhoto{Image,Thumbnail}V1` |
/// | Legacy plaintext | read and re-sealed in place (the wall predates sealing) | refused (born sealed) |
/// | Key | the friend-wall row | the device-bound pending row |
///
/// Files are named `<id>.jpg` by the corpus's own photo id. Nothing here knows about an index:
/// each owner keeps its own, and calls ``removeOrphanedFiles(keeping:)`` only after its index write
/// committed.
///
/// Fail-closed like every store in the module: no key means nothing is written and nothing opens;
/// bytes that neither open nor (where allowed) qualify as a safe legacy image read as missing.
///
/// Concurrency: a plain value type over `FileManager`; confined to its owning store's isolation
/// domain, because the injected key provider caches its key without synchronization.
struct FriendPhotoCorpusFiles {
    /// What one sealed full-size write did.
    enum ImageWrite: Equatable {
        /// The sealed bytes are on disk.
        case written
        /// Over the byte cap or outside the pixel bounds. Nothing was written, and nothing about a
        /// retry can change the answer: the bytes themselves are refused.
        case refusedUnsafe
        /// No key, the seal failed, or the write threw. Transient; nothing usable was written.
        case notWritten
    }

    // A small, highly-compressed JPEG can decode to a multi-gigabyte bitmap, so the byte cap is
    // not sufficient on its own; thumbnails are additionally generated through ImageIO's
    // thumbnail path at this bounded size, never by decoding the full image.
    private static let thumbnailMaxPixelSize = 400

    /// Full-size sealed photos, `<id>.jpg`.
    let imageDirectoryURL: URL
    /// Sealed thumbnails, `<id>.jpg`.
    let thumbnailDirectoryURL: URL
    /// The AEAD purpose every full-size file is sealed under.
    let imagePurpose: CryptographicPurpose
    /// The AEAD purpose every thumbnail is sealed under.
    let thumbnailPurpose: CryptographicPurpose
    /// Whether a pre-sealing plaintext JPEG is a legitimate generation here (the wall) or planted
    /// bytes to refuse (every born-sealed corpus).
    let allowsLegacyPlaintext: Bool
    /// The corpus's at-rest key.
    let keyProvider: PrivateMediaKeyProviding
    /// Short frozen label written into this helper's audit lines, so a failure names its corpus.
    let auditCorpus: String

    // MARK: - Writes

    /// The decompression-bomb checks every write runs, answerable without writing: the byte cap
    /// (``PrivateMediaStore/maxIncomingPhotoBytes``) and the pixel bounds
    /// (``PrivateMediaStore/isWithinSafePixelBounds(_:)``). A refusal is permanent — the bytes
    /// themselves are the problem.
    static func isSafeToStore(_ imageData: Data) -> Bool {
        imageData.count <= PrivateMediaStore.maxIncomingPhotoBytes
            && PrivateMediaStore.isWithinSafePixelBounds(imageData)
    }

    /// Checks, seals and writes one photo's full-size bytes, then (best-effort) its thumbnail.
    ///
    /// The byte cap and the pixel bounds run first because the bytes are peer-supplied. A failed
    /// full-size write is audited and still proceeds to the thumbnail, exactly as the wall always
    /// did; a nil key skips both. Only ``ImageWrite/written`` means the photo's bytes can be read
    /// back — the answer a caller that must not lose a photo needs (``PrivateMediaStore/commitKept(_:onto:)``,
    /// ``PendingSessionPhotoStore/hold(_:imageData:into:)``).
    func writeSealedImage(_ imageData: Data, for id: UUID) -> ImageWrite {
        guard imageData.count <= PrivateMediaStore.maxIncomingPhotoBytes else {
            FernletAuditLog.log("privateMedia.oversizedPhotoRefused", context: ["corpus": auditCorpus])
            return .refusedUnsafe
        }
        guard PrivateMediaStore.isWithinSafePixelBounds(imageData) else {
            FernletAuditLog.log("privateMedia.unsafePixelBoundsRefused", context: ["corpus": auditCorpus])
            return .refusedUnsafe
        }
        guard let sealedImage = keyProvider.gcmSeal(imageData, purpose: imagePurpose) else { return .notWritten }
        var outcome = ImageWrite.written
        do {
            try sealedImage.write(to: imageURL(for: id), options: [.atomic, .completeFileProtection])
        } catch {
            // Recovery: continue to the thumbnail write (the documented behaviour) — but the
            // failure is named, so an entry whose full-size bytes never persisted is not silent.
            FernletAuditLog.log(
                "privateMedia.imageWriteFailed",
                context: ["id": id.uuidString, "error": "\(error)", "corpus": auditCorpus]
            )
            outcome = .notWritten
        }
        if let thumbnailData = Self.safeThumbnailData(from: imageData) {
            keyProvider.sealAndWriteBestEffort(
                thumbnailData,
                to: thumbnailURL(for: id),
                purpose: thumbnailPurpose,
                reason: "thumbnail"
            )
        }
        return outcome
    }

    /// Removes both files of one photo, if present. Used to undo a write whose index never
    /// committed, so no unnamed file outlives the attempt.
    func removeFiles(for id: UUID) {
        for url in [imageURL(for: id), thumbnailURL(for: id)] {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // Recovery: the next committed sweep removes it (the index never named it).
                FernletAuditLog.log(
                    "privateMedia.orphanRemoveFailed",
                    context: ["file": url.lastPathComponent, "error": "\(error)", "corpus": auditCorpus]
                )
            }
        }
    }

    /// Deletes files whose id is not in `ids`. Only ever called after the owner's index write
    /// committed: the on-disk index is the corpus's file manifest, and a sweep keyed on a set that
    /// was not committed deletes files the committed index still names. A file that cannot be
    /// removed is logged and the sweep continues.
    func removeOrphanedFiles(keeping ids: Set<UUID>) {
        for directoryURL in [imageDirectoryURL, thumbnailDirectoryURL] {
            guard FileManager.default.fileExists(atPath: directoryURL.path) else { continue }
            let urls: [URL]
            do {
                urls = try FileManager.default.contentsOfDirectory(at: directoryURL, includingPropertiesForKeys: nil)
            } catch {
                // Recovery: skip this directory; the next committed sweep retries it.
                FernletAuditLog.log(
                    "privateMedia.orphanSweepSkipped",
                    context: ["directory": directoryURL.lastPathComponent, "error": "\(error)", "corpus": auditCorpus]
                )
                continue
            }
            removeFiles(at: urls, keeping: ids)
        }
    }

    /// The per-directory half of ``removeOrphanedFiles(keeping:)``.
    private func removeFiles(at urls: [URL], keeping ids: Set<UUID>) {
        for url in urls {
            guard let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent),
                  !ids.contains(id) else { continue }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // Recovery: continue the sweep — one stuck file must not abandon the rest.
                FernletAuditLog.log(
                    "privateMedia.orphanRemoveFailed",
                    context: ["file": url.lastPathComponent, "error": "\(error)", "corpus": auditCorpus]
                )
            }
        }
    }

    // MARK: - Reads

    /// The full-size plaintext bytes for `id`, decrypted from disk.
    ///
    /// Where legacy plaintext is allowed, a pre-sealing file is returned and re-sealed in place on
    /// this first access. Returns nil when no file exists or the bytes cannot be opened (no key,
    /// wrong key, corruption, planted plaintext in a born-sealed corpus) — never ciphertext.
    func imageData(forID id: UUID) -> Data? {
        let url = imageURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stored: Data
        do {
            stored = try Data(contentsOf: url)
        } catch {
            // Recovery: read as missing; the file is kept and a later read (after unlock) retries.
            FernletAuditLog.log("privateMedia.imageReadFailed", context: ["corpus": auditCorpus])
            return nil
        }
        switch openSealed(stored, purpose: imagePurpose) {
        case .opened(let data):
            return data
        case .legacyPlaintext(let data):
            // Upgrade a pre-encryption plaintext file to ciphertext on first access (spec §11).
            keyProvider.sealAndWriteBestEffort(data, to: url, purpose: imagePurpose, reason: "legacyPlaintextUpgrade")
            return data
        case .unreadable:
            return nil
        }
    }

    /// Thumbnail plaintext for `id`: the sealed thumbnail if it opens, else one regenerated (and
    /// sealed) from the full image — `inMemoryImage` when the caller already holds it, else the
    /// sealed full-size file. Nil only when neither can be opened.
    func thumbnailData(forID id: UUID, inMemoryImage: Data? = nil) -> Data? {
        if let stored = storedThumbnail(forID: id) {
            switch openSealed(stored, purpose: thumbnailPurpose) {
            case .opened(let data):
                return data
            case .legacyPlaintext(let data):
                keyProvider.sealAndWriteBestEffort(
                    data,
                    to: thumbnailURL(for: id),
                    purpose: thumbnailPurpose,
                    reason: "legacyThumbnailUpgrade"
                )
                return data
            case .unreadable:
                break  // corrupt/unopenable thumbnail — regenerate from the full image below
            }
        }
        guard let data = inMemoryImage ?? imageData(forID: id),
              let thumbnailData = Self.safeThumbnailData(from: data) else { return nil }
        keyProvider.sealAndWriteBestEffort(
            thumbnailData,
            to: thumbnailURL(for: id),
            purpose: thumbnailPurpose,
            reason: "regeneratedThumbnail"
        )
        return thumbnailData
    }

    /// The raw thumbnail bytes on disk, or nil when absent or unreadable (a read failure falls
    /// through to regeneration, which fails closed on the same condition).
    private func storedThumbnail(forID id: UUID) -> Data? {
        let url = thumbnailURL(for: id)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            FernletAuditLog.log("privateMedia.thumbnailReadFailed", context: ["corpus": auditCorpus])
            return nil
        }
    }

    // MARK: - Layout

    /// Creates both photo directories. A failure is logged rather than dropped, and reported: every
    /// later write would otherwise fail with a misleading error and no recorded root cause.
    /// - Returns: whether both directories exist afterwards.
    func createDirectories() -> Bool {
        var created = true
        for directory in [imageDirectoryURL, thumbnailDirectoryURL] {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                FernletAuditLog.log(
                    "privateMedia.directoryCreateFailed",
                    context: ["directory": directory.lastPathComponent, "error": "\(error)", "corpus": auditCorpus]
                )
                created = false
            }
        }
        return created
    }

    /// The full-size file for `id`.
    func imageURL(for id: UUID) -> URL {
        imageDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    /// The thumbnail file for `id`.
    func thumbnailURL(for id: UUID) -> URL {
        thumbnailDirectoryURL.appendingPathComponent("\(id.uuidString).jpg")
    }

    // MARK: - At-rest encryption

    /// Three-way outcome of opening an on-disk media file.
    ///
    /// Only `.opened` and `.legacyPlaintext` ever hand bytes to a caller, and `.legacyPlaintext`
    /// is reachable only where ``allowsLegacyPlaintext`` is true.
    private enum OpenResult {
        case opened(Data)           // decrypted from ciphertext
        case legacyPlaintext(Data)  // a pre-encryption plaintext file (re-encrypted in place on access)
        case unreadable             // no key, or bytes that are neither openable nor a valid image
    }

    /// Opens AES-256-GCM bytes. GCM open fails both for legacy pre-encryption plaintext files and
    /// for genuinely undecodable bytes (wrong/lost key, corruption); where legacy plaintext is a
    /// legitimate generation the two are told apart by whether the raw bytes are themselves a safe
    /// image, so a wrong key or a corrupt file still resolves to `.unreadable`.
    private func openSealed(_ stored: Data, purpose: CryptographicPurpose) -> OpenResult {
        // The explicit nil-key guard is load-bearing: without a key NOTHING opens — a legacy
        // plaintext file is `.unreadable` here, never handed back as a photo.
        guard keyProvider.mediaKey() != nil else { return .unreadable }
        if let plaintext = keyProvider.gcmOpen(stored, purpose: purpose) {
            return .opened(plaintext)
        }
        guard allowsLegacyPlaintext else { return .unreadable }
        return PrivateMediaStore.isWithinSafePixelBounds(stored) ? .legacyPlaintext(stored) : .unreadable
    }

    // MARK: - Safe thumbnail generation

    /// Generates a thumbnail using ImageIO to avoid fully decompressing untrusted image data.
    /// Checks pixel dimensions before decode and caps output at `thumbnailMaxPixelSize`.
    static func safeThumbnailData(from imageData: Data) -> Data? {
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
}
