import Foundation
import UIKit
import ImageIO
import CryptoKit
import FernletCrypto
import FernletDomainModel
import FernletFoundation

/// On-device, at-rest-encrypted store for the user's OWN photos attached to logged meals (and, from
/// here on, other private personal photos such as gym progress pictures — body photos, which is why
/// this store had to be sealed before they were added).
///
/// Every photo is normalized (downscaled + re-encoded to a bounded JPEG) and then AES-256-GCM-sealed
/// under the injected `PrivateMediaKeyProviding` key — since the Phase-5 key split, the OWN-photos key
/// (`KeychainPrivateMediaKeyProvider.Role.ownPhotos`), never the friend wall's — before it touches
/// disk; the same at-rest scheme as `PrivateMediaStore`. It used to write the raw, full-resolution JPEG in the clear (relying only on
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
    /// Separates meal, recipe, and progress image boxes even when their reusable at-rest keys
    /// share the same keychain role during a migration.
    private let atRestPurpose: CryptographicPurpose
    /// Optional PRE-SPLIT key, tried on read when the own key can't open a file — the dual-open
    /// safety net for files not yet re-sealed under the own key. Since Phase 3 of the crypto
    /// standardization plan required the `FMA2` marker on read it reaches only marked files, and the
    /// eager re-seal pass it was a net for was retired at that round's close — so in practice it
    /// recovers nothing. Dropping it is the BINDING's decision (`OwnPhotoKeyBinder`), not this
    /// store's, which is why it is still here.
    ///
    /// Bytes it opens are authentic ciphertext under a key this app owns, so — unlike the
    /// legacy-PLAINTEXT branch — trusting them launders nothing: they are re-sealed under the own
    /// key in place and the file leaves the legacy generation on first access. Nil disables the
    /// fallback entirely; step 5c passes nil once the migration latch proves it is unnecessary,
    /// which is what makes the own key's device binding meaningful.
    private let legacyKeyProvider: PrivateMediaKeyProviding?
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
    /// AREA clause of the same OOM guard. Per-dimension bounds alone admit a declared
    /// 20,000 × 20,000 source — 400 MP, ~1.6 GB decoded, yet a few hundred KB on the wire as a
    /// solid-colour PNG, and PNG has no reduced-size decode so even the thumbnail path in
    /// ``normalizedJPEG(from:)`` materialises the full bitmap. Reachable with attacker-declared
    /// dimensions via a shared recipe's web image (`FernletStore.saveRecipePhoto(data:for:)`).
    /// Deliberately looser than `PrivateMediaStore`'s 24 MP peer gate: this store also takes the
    /// user's OWN camera/library picks — 24 MP default iPhone output (5712 × 4284 ≈ 24.5 MP),
    /// 48 MP HEIC, ~63 MP panoramas — which must stay bounded-then-downscaled, never rejected
    /// (see the type doc). 80 MP clears every real photo while capping the worst transient
    /// decode near ~320 MB.
    private static let maxSourcePixelCount = 80_000_000
    /// R5: byte cap on anything entering this store. Photos now arrive from a library picker and from
    /// an escrow restore, not only from the camera, so the incoming BYTE count is validated before
    /// ImageIO is asked to look at it — mirroring `PrivateMediaStore.maxIncomingPhotoBytes`.
    private static let maxIncomingPhotoBytes = 20 * 1024 * 1024

    /// Creates a store over `directory` (created if needed), sealing under `keyProvider`'s key.
    ///
    /// - Parameters:
    ///   - directory: Where the sealed `<uuid>.jpg` files live; each logical store gets its own.
    ///   - keyProvider: Source of the at-rest key; defaults to the keychain-backed OWN-photos
    ///     provider, because every instance of this store holds the user's own pictures. (The
    ///     friend wall uses `PrivateMediaStore`, whose default is the friend-wall role.)
    ///   - allowsLegacyPlaintextUpgrade: Pass true ONLY for a store that really has a pre-sealing
    ///     plaintext generation on disk (the original meal-photo store); pass false for stores that
    ///     were born sealed (recipe/body photos) so unsealed bytes are refused, not laundered.
    ///   - legacyKeyProvider: Optional pre-split key for the dual-open safety net (see
    ///     ``legacyKeyProvider``). Nil — the default — means no fallback.
    public init(
        directory: URL,
        keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider(role: .ownPhotos),
        allowsLegacyPlaintextUpgrade: Bool = true,
        legacyKeyProvider: PrivateMediaKeyProviding? = nil,
        purpose: CryptographicPurpose = FernletCryptoPurpose.AEAD.mealPhotoV2
    ) {
        self.directory = directory
        self.keyProvider = keyProvider
        self.allowsLegacyPlaintextUpgrade = allowsLegacyPlaintextUpgrade
        self.legacyKeyProvider = legacyKeyProvider
        self.atRestPurpose = purpose
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Recovery: stay constructible (this is built on the main actor at launch) — `save` and
            // `imageData` already fail closed. The failure is named so a later misleading write error
            // has a recorded root cause. `withIntermediateDirectories: true` does not throw for an
            // existing directory, so reaching here is a real permissions/disk failure.
            FernletAuditLog.log("mealPhotoStore.directoryCreateFailed", context: ["error": "\(error)"])
        }
    }

    /// Delete-all seam (Docs/PrivacyWipeCoverage.md): drops the provider-cached media key after
    /// the global wipe deletes the shared keychain row, so RAM matches the keychain until relaunch.
    public func invalidateEncryptionKeyCache() {
        keyProvider.invalidateCachedKey()
    }

    /// Normalizes, seals and stores `data`, returning the new id. Returns nil — writing NOTHING — when
    /// the bytes aren't a decodable image within the source pixel caps (dimension AND area — the
    /// decompression-bomb gate) or no encryption key is available: a photo is dropped rather
    /// than persisted in the clear (fail-closed, as with the sealed peer store).
    public func save(_ data: Data) -> UUID? {
        guard data.count <= Self.maxIncomingPhotoBytes else { return nil }
        guard let normalized = Self.normalizedJPEG(from: data) else { return nil }
        let id = UUID()
        guard keyProvider.sealAndWrite(normalized, to: url(for: id), purpose: atRestPurpose) else { return nil }
        return id
    }

    /// Normalizes, seals and stores `data` under a CALLER-supplied id (overwriting any existing photo at
    /// that id), returning whether it was written. Used where the owning record already has a stable id —
    /// e.g. a recipe's own photo keyed by the recipe id — so there's no second id to track. Fail-closed
    /// like `save`: writes nothing on non-image bytes or no key.
    ///
    /// R7: not `@discardableResult` — the `Bool` IS the success/failure signal (false means NOTHING
    /// was written), so every caller must act on it. This id-keyed overload is the recipe web-image
    /// sink, so the bytes can carry ATTACKER-declared dimensions from a shared link's page — the
    /// same source-cap gate (dimension AND area) applies inside the normalize funnel.
    public func save(_ data: Data, forID id: UUID) -> Bool {
        guard data.count <= Self.maxIncomingPhotoBytes else { return false }
        guard let normalized = Self.normalizedJPEG(from: data) else { return false }
        return keyProvider.sealAndWrite(normalized, to: url(for: id), purpose: atRestPurpose)
    }

    /// Returns the decrypted photo bytes for `id`, or nil when there is no file, no key, or the
    /// bytes won't open (never ciphertext/garbage).
    ///
    /// Two upgrade-on-read paths can fire here, in this order and no other:
    /// 1. **Dual-open** — bytes still sealed under the PRE-SPLIT shared key open via
    ///    `legacyKeyProvider` (when one is injected) and are re-sealed under the own key in place.
    ///    Must precede the plaintext branch: those bytes are ciphertext, and the plaintext branch
    ///    would (correctly) refuse them.
    /// 2. **Legacy plaintext** — when `allowsLegacyPlaintextUpgrade` is true, a pre-sealing
    ///    plaintext JPEG at this id is returned and re-sealed in place; otherwise unsealed bytes
    ///    are refused.
    public func imageData(for id: UUID) -> Data? {
        guard let stored = try? Data(contentsOf: url(for: id)) else { return nil }
        // Sealed bytes (the normal case).
        if let opened = keyProvider.gcmOpen(stored, purpose: atRestPurpose) {
            return opened
        }
        // Dual-open safety net: a file the eager migration pass has not reached yet is still sealed
        // under the pre-split shared key. Open it, hand back the bytes, and re-seal under the own
        // key so this file leaves the legacy generation now rather than waiting for the next pass.
        // A failed re-seal is deliberately non-fatal: the user still sees their photo, and the file
        // stays legacy (so the migration latch stays closed — which is exactly the fail-closed
        // signal that binding must not proceed yet).
        if let legacyKeyProvider, let opened = legacyKeyProvider.gcmOpen(stored, purpose: atRestPurpose) {
            keyProvider.sealAndWriteBestEffort(
                opened, to: url(for: id), purpose: atRestPurpose, reason: "dualOpenUpgrade")
            return opened
        }
        // A file written by the pre-sealing build is plaintext JPEG. GCM-open fails for it AND for
        // genuinely corrupt/wrong-key bytes; tell them apart by whether the raw bytes are a valid
        // image (a legacy photo passed the same image encode at save time). If so, re-seal in place
        // and return it; otherwise treat it as missing rather than hand back ciphertext/garbage.
        // Stores with NO legacy plaintext generation (body/recipe photos) skip this branch entirely:
        // an unsealed file that merely parses as an image is refused, not trusted and re-sealed.
        if allowsLegacyPlaintextUpgrade, PrivateMediaStore.isWithinSafePixelBounds(stored) {
            keyProvider.sealAndWriteBestEffort(
                stored, to: url(for: id), purpose: atRestPurpose, reason: "legacyPlaintextUpgrade")
            return stored
        }
        return nil
    }

    /// Writes ALREADY-NORMALIZED photo bytes under `id`, sealing them as-is — the escrow-restore
    /// seam (security-hardening Phase 5, step 5b).
    ///
    /// Deliberately skips ``normalizedJPEG(from:)``, unlike ``save(_:forID:)``: the bytes being
    /// restored were normalized once before they were uploaded, so re-encoding them here would be a
    /// second lossy JPEG pass AND would change their SHA-256 — which is the hash the sealed manifest
    /// committed, so every subsequent backup would see the whole restored corpus as "changed" and
    /// re-upload it forever.
    ///
    /// - Important: bytes reaching this method must already have been authenticated — in production
    ///   that means opened from an escrow-sealed record whose manifest entry's content hash matched.
    ///   It is NOT a general write path and must never be handed unauthenticated input; the
    ///   image-bounds check below is a cheap backstop, not the authorization.
    /// - Returns: whether the sealed bytes reached disk (false on oversize or non-image input, absurd
    ///   dimensions, no key, or a write failure — fail-closed, nothing written). R7: deliberately not
    ///   `@discardableResult` — a discarded false is a photo silently missing from a restore.
    public func restoreSealedPhoto(_ normalizedJPEG: Data, forID id: UUID) -> Bool {
        guard normalizedJPEG.count <= Self.maxIncomingPhotoBytes else { return false }
        guard PrivateMediaStore.isWithinSafePixelBounds(normalizedJPEG) else { return false }
        return keyProvider.sealAndWrite(normalizedJPEG, to: url(for: id), purpose: atRestPurpose)
    }

    /// The ids this store currently holds files for, parsed from the flat `<uuid>.jpg` file names.
    ///
    /// The corpus has no index of its own (ownership lives in `Meal.photoID` / the recipe id), so
    /// the directory IS the id set — which is exactly what an own-photo escrow upload has to
    /// enumerate. Non-recursive; unparseable names are skipped rather than guessed at.
    public func storedPhotoIDs() -> [UUID] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )) ?? []
        return contents.compactMap { url in
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { return nil }
            return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
        }
    }

    /// Whether this corpus holds **no file at all** — the FILE-PRESENCE half of the escrow restore's
    /// per-corpus no-clobber gate.
    ///
    /// Deliberately not "no parseable id": any regular file counts, so a corpus holding bytes this
    /// build cannot name still reads as non-empty and is never restored over. A missing directory is
    /// empty; an unlistable one is NOT (fails closed → no restore), because an unknown number of
    /// files is not the same as none.
    public func isEmptyForRestore() -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return true }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return false }
        return !contents.contains { url in
            (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
        }
    }

    /// Whether this corpus holds files but **not one of them can be opened by this install** — the
    /// second half of the escrow restore's no-clobber gate.
    ///
    /// ``isEmptyForRestore()`` alone cannot distinguish "in use" from "full of bytes that are dead
    /// to this install", and the difference is exactly the phone-swap case the escrow backup exists
    /// for: a device backup restored onto a NEW phone brings the sealed photo files back but not the
    /// device-bound own-photos key, so every file is permanently unopenable — and a pure
    /// file-presence gate reads that as "this corpus is in use" and declines the one restore that
    /// would bring the photos back.
    ///
    /// **Answered by probing, not by a persisted verdict, and that is deliberate.** A verdict
    /// written by the migration sweep lives in `UserDefaults`, which rides the device backup — so on
    /// the new phone it would arrive already saying "openable" about files whose key did not come
    /// with it, i.e. it would be confidently wrong in precisely the scenario it was meant to
    /// answer. The probe cannot go stale. It is also cheap where it runs often: it **stops at the
    /// first file that opens**, so a healthy corpus costs one GCM open per pass. Only a corpus that
    /// really is entirely dead reads all of it — once, and immediately before a restore that
    /// downloads the whole corpus anyway.
    ///
    /// Fails **closed** in every uncertain direction (returns false ⇒ no restore): an empty corpus,
    /// an unlistable directory, an unavailable key, or a file whose bytes cannot be READ (a locked
    /// container answers "I cannot see it", never "it is dead"). A zero-byte file is skipped rather
    /// than counted either way — it holds nothing a restore could clobber.
    ///
    /// "Openable" means openable by any path this store's READ actually uses: the own key, the
    /// dual-open legacy key, and — only where the corpus legitimately has one
    /// (``allowsLegacyPlaintextUpgrade``) — a pre-sealing plaintext JPEG. That last clause is why
    /// this is not simply the migration pass's `unopenable` tally: legacy plaintext scores
    /// unopenable there and is still returned to the user here.
    public func holdsOnlyUnopenableFiles() -> Bool {
        guard keyProvider.mediaKey() != nil else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else { return false }
        var sawFile = false
        for url in contents {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            sawFile = true
            guard let stored = try? Data(contentsOf: url) else { return false }
            guard !stored.isEmpty else { continue }
            if keyProvider.gcmOpen(stored, purpose: atRestPurpose) != nil { return false }
            if let legacyKeyProvider, legacyKeyProvider.gcmOpen(stored, purpose: atRestPurpose) != nil { return false }
            if allowsLegacyPlaintextUpgrade, PrivateMediaStore.isWithinSafePixelBounds(stored) { return false }
        }
        return sawFile
    }

    /// Whether a sealed file exists on disk for `id` — an existence check ONLY: no read, no decrypt, no
    /// key, no plaintext ever touched. `imageData` returns nil both when the bytes never synced to this
    /// device (no file) AND when a file is here but can't be opened (corrupt / wrong key); this lets a
    /// caller tell those two apart so a broken photo doesn't get mislabelled "on your other device".
    public func hasSealedData(forID id: UUID) -> Bool {
        FileManager.default.fileExists(atPath: url(for: id).path)
    }

    /// Removes the sealed file for `id` (best-effort; a missing file is a no-op).
    ///
    /// A failure is audit-logged rather than dropped: this is the ONLY deletion path for one
    /// meal/recipe/progress photo, and ownership (`Meal.photoID`, the recipe id, the progress index)
    /// has usually already been released by the caller — so an unremoved file is unreachable bytes
    /// the user believes are gone.
    public func delete(id: UUID) {
        let target = url(for: id)
        guard FileManager.default.fileExists(atPath: target.path) else { return }
        do {
            try FileManager.default.removeItem(at: target)
        } catch {
            FernletAuditLog.log(
                "mealPhotoStore.deleteFailed",
                context: ["id": id.uuidString, "error": "\(error)"]
            )
        }
    }

    /// Deletes every stored photo file.
    ///
    /// Ownership lives in `Meal.photoID`, scattered across day records — so once the days are cleared
    /// there is nothing left that knows these files exist, and per-id deletion can no longer reach them.
    /// A "delete everything" that skipped this would strand the user's food photos on disk permanently,
    /// unreferenced and invisible. Removing the directory itself also takes any stray non-.jpg contents.
    ///
    /// R7: not `@discardableResult` — `false` means the user's photos survived "delete everything".
    /// - Returns: whether the corpus is now empty.
    public func deleteAll() -> Bool {
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
    /// JPEG via ImageIO's thumbnail path. That path decodes JPEG at reduced size, but formats with
    /// no reduced-size decode (PNG) materialise the FULL source bitmap first — which is why the
    /// guard below enforces the per-dimension AND total-area caps on the DECLARED size before
    /// ImageIO decodes any pixels. Returns nil for non-image or absurdly-dimensioned input. Images
    /// already within the cap are re-encoded at their native size (never upscaled).
    static func normalizedJPEG(from data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            let width = properties[kCGImagePropertyPixelWidth] as? Int ?? 0
            let height = properties[kCGImagePropertyPixelHeight] as? Int ?? 0
            guard width > 0, height > 0,
                  width <= maxSourcePixelDimension, height <= maxSourcePixelDimension,
                  width * height <= maxSourcePixelCount else { return nil }
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
