import Foundation
import CryptoKit
import FernletCrypto

/// The on-disk layout of the user's OWN photo corpora, in ONE place.
///
/// Three separate owners need to agree on these names — the app's `FernletStore` (which builds the
/// three store instances), ``ProgressPhotoStore`` (which owns its inner `Photos/` directory and
/// sealed `index.bin`), and ``MediaAtRestFormatMigrator`` (which must enumerate **every** file
/// sealed under the own-photos key). A name that drifts in one of them and not the others would not
/// fail any build; it would silently leave a corpus unswept, and — because sweeping it is half of
/// ``OwnPhotoKeyBinder``'s irreversible binding gate — let the gate be satisfied by a device that
/// never looked. So the strings live here and nowhere else.
///
/// The fourth owner was `OwnPhotoKeyMigrator`, the eager re-seal pass of the security-hardening
/// media-key split. It was retired by owner decision at the close of the crypto standardization
/// round (`Docs/Plan-Crypto-Standardization-2026-08-27.md`), once Phase 3's deletion of the
/// unmarked at-rest read left its convert arm with no input any shipping writer could produce.
///
/// Concurrency: `nonisolated` namespace of pure path arithmetic; no state.
public enum OwnPhotoCorpusLayout {
    /// Meal photos (`Meal.photoID` → sealed `<uuid>.jpg`). Has a pre-sealing plaintext generation.
    public static let mealPhotosDirectoryName = "MealPhotos"
    /// Recipe photos, keyed by recipe id. Born sealed.
    public static let recipePhotosDirectoryName = "RecipePhotos"
    /// Root of the gym progress-photo timeline (holds the inner photo directory + sealed index).
    public static let progressPhotosDirectoryName = "ProgressPhotos"
    /// ``ProgressPhotoStore``'s inner photo-bytes directory, relative to its root.
    public static let progressPhotosInnerDirectoryName = "Photos"
    /// ``ProgressPhotoStore``'s GCM-sealed index file, relative to its root. Sealed under the same
    /// key as the bytes, so the migration must cover it too — a timeline whose index still opens
    /// only under the old key would read as empty after binding.
    public static let progressIndexFileName = "index.bin"

    /// Meal-photo directory under `documentsDirectory`.
    public static func mealPhotosDirectory(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(mealPhotosDirectoryName, isDirectory: true)
    }

    /// Recipe-photo directory under `documentsDirectory`.
    public static func recipePhotosDirectory(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(recipePhotosDirectoryName, isDirectory: true)
    }

    /// Progress-photo timeline root under `documentsDirectory`.
    public static func progressPhotosDirectory(in documentsDirectory: URL) -> URL {
        documentsDirectory.appendingPathComponent(progressPhotosDirectoryName, isDirectory: true)
    }

    /// Every on-disk location sealed under the own-photos key for an app container rooted at
    /// `documentsDirectory` — the exact input the format pass must enumerate.
    public static func sealedLocations(in documentsDirectory: URL) -> OwnPhotoSealedLocations {
        let progressRoot = progressPhotosDirectory(in: documentsDirectory)
        return OwnPhotoSealedLocations(
            directories: [
                mealPhotosDirectory(in: documentsDirectory),
                recipePhotosDirectory(in: documentsDirectory),
                progressRoot.appendingPathComponent(progressPhotosInnerDirectoryName, isDirectory: true)
            ],
            files: [progressRoot.appendingPathComponent(progressIndexFileName)]
        )
    }

    /// The AEAD purpose a file at `url` is sealed under, derived from this fixed, app-owned layout.
    /// A path outside it defaults to the original meal corpus; untrusted file names never select or
    /// construct a purpose.
    ///
    /// Lives here rather than in the pass that consumes it because it IS layout knowledge — the
    /// same "in ONE place" this type exists for. The format pass, the census, and anything else that
    /// opens these bytes outside their owning store must agree with the stores, and there is exactly
    /// one mapping for them to agree with.
    public static func sealPurpose(for url: URL) -> CryptographicPurpose {
        let components = Set(url.pathComponents)
        if url.lastPathComponent == progressIndexFileName {
            return FernletCryptoPurpose.AEAD.progressPhotoIndexV2
        }
        if components.contains(progressPhotosDirectoryName) {
            return FernletCryptoPurpose.AEAD.progressPhotoV2
        }
        if components.contains(recipePhotosDirectoryName) {
            return FernletCryptoPurpose.AEAD.recipePhotoV2
        }
        return FernletCryptoPurpose.AEAD.mealPhotoV2
    }
}

/// The set of on-disk locations sealed under the own-photos key: flat directories of sealed files
/// plus individually-named sealed files.
///
/// A value type (and `Sendable`) so the app can hand it to the off-main launch task without
/// dragging any non-`Sendable` store or key provider across the isolation boundary.
public struct OwnPhotoSealedLocations: Sendable, Equatable {
    /// Directories whose every regular file is sealed media (enumerated non-recursively).
    public let directories: [URL]
    /// Individually-named sealed files (today: the progress index).
    public let files: [URL]

    /// Creates a location set. Missing paths are simply skipped by the pass that walks it.
    public init(directories: [URL], files: [URL]) {
        self.directories = directories
        self.files = files
    }
}
