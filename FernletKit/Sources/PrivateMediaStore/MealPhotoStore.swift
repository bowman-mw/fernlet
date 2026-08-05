import Foundation
import UIKit
import ImageIO
import CryptoKit
import FernletDomainModel

/// On-device, at-rest-encrypted store for the user's OWN photos attached to logged meals (and, from
/// here on, other private personal photos such as gym progress pictures — body photos, which is why
/// this store had to be sealed before they were added).
///
/// Every photo is normalized (downscaled + re-encoded to a bounded JPEG) and then AES-256-GCM-sealed
/// under the shared `PrivateMediaKeyProviding` key before it touches disk — the same at-rest scheme as
/// `PrivateMediaStore`. It used to write the raw, full-resolution JPEG in the clear (relying only on
/// iOS `.completeFileProtection`); that was fine for a lunch snapshot but not for a body photo, and it
/// stored multi-megabyte originals. Normalizing on the way in also means a 48 MP phone photo is bounded
/// rather than rejected the way the peer decompression-bomb gate would reject it.
///
/// Photos written by the pre-sealing build are recognised as legacy plaintext on read and re-sealed in
/// place on first access, so no migration pass is needed and existing meal photos keep working.
///
/// The app's `FernletStore` (main actor) owns the instances: one for meal photos (legacy upgrade ON),
/// one for recipe photos (legacy upgrade OFF, keyed by recipe id via ``save(_:forID:)``), and
/// ``ProgressPhotoStore`` composes a third internally for body-photo bytes. Ownership of a photo id
/// lives with the caller (`Meal.photoID`, the recipe id, or the progress index) — this store is a flat
/// id-to-sealed-file map with no index of its own. Plain nonisolated struct; thread safety comes from
/// the owner's isolation, and the shared ``PrivateMediaKeyProviding`` must stay in that same domain.
public struct MealPhotoStore {
    private let directory: URL
    private let keyProvider: PrivateMediaKeyProviding
    /// Whether an unsealed on-disk file that parses as a safe-bounds image is trusted as pre-sealing
    /// "legacy plaintext", re-sealed in place, and returned. TRUE only for the original meal-photo store,
    /// which legitimately has such files from the pre-sealing build. Body (progress) photos and recipe
    /// photos never had a plaintext generation, so their stores pass FALSE: unsealed bytes at a valid id
    /// path resolve to nil (fail-closed) rather than being laundered into authentic ciphertext by an
    /// attacker-dropped JPEG. Matches the index's own fail-closed refusal in `ProgressPhotoStore`.
    private let allowsLegacyPlaintextUpgrade: Bool

    /// Longest-side cap for stored photos. Ample for the polaroid card and a full-screen detail view,
    /// while keeping originals off disk. Small images are passed through at their native size.
    private static let maxStoredPixelSize = 1600
    private static let jpegQuality: CGFloat = 0.8
    /// Refuse to even downscale a source whose dimensions are absurd (OOM guard), matching
    /// `PrivateMediaStore`. The user's own camera photos are far below this.
    private static let maxSourcePixelDimension = 20_000

    /// Creates a store over `directory` (created if needed), sealing under `keyProvider`'s key.
    ///
    /// - Parameters:
    ///   - directory: Where the sealed `<uuid>.jpg` files live; each logical store gets its own.
    ///   - keyProvider: Source of the shared at-rest key; defaults to the keychain-backed provider.
    ///   - allowsLegacyPlaintextUpgrade: Pass true ONLY for a store that really has a pre-sealing
    ///     plaintext generation on disk (the original meal-photo store); pass false for stores that
    ///     were born sealed (recipe/body photos) so unsealed bytes are refused, not laundered.
    public init(
        directory: URL,
        keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider(),
        allowsLegacyPlaintextUpgrade: Bool = true
    ) {
        self.directory = directory
        self.keyProvider = keyProvider
        self.allowsLegacyPlaintextUpgrade = allowsLegacyPlaintextUpgrade
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    /// Delete-all seam (Docs/PrivacyWipeCoverage.md): drops the provider-cached media key after
    /// the global wipe deletes the shared keychain row, so RAM matches the keychain until relaunch.
    public func invalidateEncryptionKeyCache() {
        keyProvider.invalidateCachedKey()
    }

    /// Normalizes, seals and stores `data`, returning the new id. Returns nil — writing NOTHING — when
    /// the bytes aren't a decodable image or no encryption key is available: a photo is dropped rather
    /// than persisted in the clear (fail-closed, as with the sealed peer store).
    public func save(_ data: Data) -> UUID? {
        guard let normalized = Self.normalizedJPEG(from: data) else { return nil }
        let id = UUID()
        guard keyProvider.sealAndWrite(normalized, to: url(for: id)) else { return nil }
        return id
    }

    /// Normalizes, seals and stores `data` under a CALLER-supplied id (overwriting any existing photo at
    /// that id), returning whether it was written. Used where the owning record already has a stable id —
    /// e.g. a recipe's own photo keyed by the recipe id — so there's no second id to track. Fail-closed
    /// like `save`: writes nothing on non-image bytes or no key.
    @discardableResult public func save(_ data: Data, forID id: UUID) -> Bool {
        guard let normalized = Self.normalizedJPEG(from: data) else { return false }
        return keyProvider.sealAndWrite(normalized, to: url(for: id))
    }

    /// Returns the decrypted photo bytes for `id`, or nil when there is no file, no key, or the
    /// bytes won't open (never ciphertext/garbage).
    ///
    /// When `allowsLegacyPlaintextUpgrade` is true, a pre-sealing plaintext JPEG at this id is
    /// returned and re-sealed in place on this first access; otherwise unsealed bytes are refused.
    public func imageData(for id: UUID) -> Data? {
        guard let stored = try? Data(contentsOf: url(for: id)) else { return nil }
        // Sealed bytes (the normal case).
        if let opened = keyProvider.gcmOpen(stored) {
            return opened
        }
        // A file written by the pre-sealing build is plaintext JPEG. GCM-open fails for it AND for
        // genuinely corrupt/wrong-key bytes; tell them apart by whether the raw bytes are a valid
        // image (a legacy photo passed the same image encode at save time). If so, re-seal in place
        // and return it; otherwise treat it as missing rather than hand back ciphertext/garbage.
        // Stores with NO legacy plaintext generation (body/recipe photos) skip this branch entirely:
        // an unsealed file that merely parses as an image is refused, not trusted and re-sealed.
        if allowsLegacyPlaintextUpgrade, PrivateMediaStore.isWithinSafePixelBounds(stored) {
            keyProvider.sealAndWrite(stored, to: url(for: id))
            return stored
        }
        return nil
    }

    /// Whether a sealed file exists on disk for `id` — an existence check ONLY: no read, no decrypt, no
    /// key, no plaintext ever touched. `imageData` returns nil both when the bytes never synced to this
    /// device (no file) AND when a file is here but can't be opened (corrupt / wrong key); this lets a
    /// caller tell those two apart so a broken photo doesn't get mislabelled "on your other device".
    public func hasSealedData(forID id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Removes the sealed file for `id` (best-effort; a missing file is a no-op).
    public func delete(id: UUID) {
        try? FileManager.default.removeItem(at: url(for: id))
    }

    /// Deletes every stored photo file.
    ///
    /// Ownership lives in `Meal.photoID`, scattered across day records — so once the days are cleared
    /// there is nothing left that knows these files exist, and per-id deletion can no longer reach them.
    /// A "delete everything" that skipped this would strand the user's food photos on disk permanently,
    /// unreferenced and invisible. Removing the directory itself also takes any stray non-.jpg contents.
    @discardableResult public func deleteAll() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            // Recreate so the store stays usable for the rest of the session without a relaunch.
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Normalization

    /// Downscales `data` so its longest side is at most `maxStoredPixelSize` and re-encodes it as a
    /// JPEG, using ImageIO's thumbnail path so the full-resolution bitmap is never materialised (the
    /// bomb-safe decode). Returns nil for non-image or absurdly-dimensioned input. Images already
    /// within the cap are re-encoded at their native size (never upscaled).
    static func normalizedJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width > 0, height > 0,
                  width <= maxSourcePixelDimension, height <= maxSourcePixelDimension else { return nil }
        } else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxStoredPixelSize,
            kCGImageSourceCreateThumbnailWithTransform: true  // bake in EXIF orientation
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cgImage).jpegData(compressionQuality: jpegQuality)
    }

    private func url(for id: UUID) -> URL {
        directory.appendingPathComponent("\(id.uuidString).jpg")
    }
}
