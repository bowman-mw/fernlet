import Foundation
import CryptoKit
import FernletCrypto

/// The on-disk layout of the user's OWN photo corpora, in ONE place.
///
/// Three separate owners need to agree on these names — the app's `FernletStore` (which builds the
/// three store instances), ``ProgressPhotoStore`` (which owns its inner `Photos/` directory and
/// sealed `index.bin`), and ``OwnPhotoKeyMigrator`` (which must enumerate **every** file sealed
/// under the own-photos key). A name that drifts in one of them and not the others would not fail
/// any build; it would silently leave a corpus un-migrated and therefore still openable under the
/// backup-restorable friend key — exactly the leak Phase 5 exists to close. So the strings live
/// here and nowhere else.
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
    /// `documentsDirectory` — the exact input the migration pass must enumerate.
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
}

/// The set of on-disk locations sealed under the own-photos key: flat directories of sealed files
/// plus individually-named sealed files.
///
/// A value type (and `Sendable`) so the app can hand it to the off-main migration task without
/// dragging any non-`Sendable` store or key provider across the isolation boundary.
public struct OwnPhotoSealedLocations: Sendable, Equatable {
    /// Directories whose every regular file is sealed media (enumerated non-recursively).
    public let directories: [URL]
    /// Individually-named sealed files (today: the progress index).
    public let files: [URL]

    /// Creates a location set. Missing paths are simply skipped by the migration pass.
    public init(directories: [URL], files: [URL]) {
        self.directories = directories
        self.files = files
    }
}

/// The persisted "every own photo is sealed under the own-photos key" completion latch.
///
/// **Load-bearing, and deliberately one-way + fail-closed.** Two later steps are gated on it:
/// flipping the own-photos keychain row to `AfterFirstUnlockThisDeviceOnly` (step 5c) and dropping
/// the dual-open legacy fallback from the own read path. Doing either while one file is still
/// sealed under the old shared key would convert that file to permanently unreadable bytes with no
/// error anywhere — so the latch is set ONLY by a full pass that found nothing left to migrate and
/// nothing it could not classify. A crash mid-pass leaves it false and the next launch re-scans;
/// re-scanning a fully-migrated corpus is cheap (one GCM open per file) and harmless.
///
/// Device-local by construction (`UserDefaults`, never synced): the property it records is about
/// THIS device's files and THIS device's keychain rows, so it must not ride a backup to a phone
/// whose files have not been re-sealed.
///
/// Concurrency: `nonisolated` value type over `UserDefaults` (itself thread-safe).
public struct OwnPhotoMigrationLatch {
    /// The `UserDefaults` key holding the latch.
    public static let defaultsKey = "com.fernlet.private-media.ownPhotoKeyMigrationComplete"

    private let defaults: UserDefaults

    /// Creates a latch over `defaults`; tests inject an isolated suite so they never touch the
    /// device's real completion state.
    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a full clean pass has proven every own-photo file is sealed under the own key.
    /// Absent (never set) reads as false — the fail-closed direction.
    public var isComplete: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Records completion. Called ONLY from ``OwnPhotoKeyMigrator/run(maxPasses:)`` after a clean
    /// pass; never from a UI path, and never speculatively.
    public func markComplete() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Clears the latch, forcing a re-scan on the next run. For tests and for any future step that
    /// invalidates the proof (e.g. restoring own photos from an escrow backup sealed elsewhere).
    public func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// The tally of one ``OwnPhotoKeyMigrator`` pass — and, through ``isClean``, the sole authority on
/// whether the completion latch may be set.
public struct OwnPhotoKeyMigrationResult: Sendable, Equatable {
    /// Files the pass looked at (the sum of the five buckets below).
    public let examined: Int
    /// Already sealed under the own-photos key — nothing to do.
    public let alreadyOwnKey: Int
    /// Opened under the legacy shared key and successfully re-sealed under the own key by THIS
    /// pass. Non-zero means the corpus was not yet clean when the pass started, so the latch stays
    /// closed until a following pass confirms zero.
    public let resealed: Int
    /// Opened under the legacy key but could not be written back (disk error). Blocks the latch.
    public let resealFailures: Int
    /// Read successfully and then opened under NEITHER key while the legacy key was available:
    /// truncated, corrupt, or (in the meal corpus) a pre-sealing plaintext JPEG. Does **not** block
    /// the latch — no key custody decision can make these bytes any more or less readable, and the
    /// read paths already resolve them to nil (or, for legitimate legacy plaintext, re-seal them
    /// under the own key on access).
    ///
    /// - Important: this bucket means "we READ the bytes and no key opens them". A file whose bytes
    ///   could not be read at all is ``indeterminate``, never this — see ``indeterminate``.
    public let unopenable: Int
    /// Could not be classified: the legacy key was unavailable, a directory could not be listed, or
    /// the file's bytes could not be READ at all. Blocks the latch — the fail-closed direction.
    ///
    /// The read-failure case is the subtle one and it is why this bucket exists rather than a
    /// second "unopenable" tally. Own-photo files are written `.completeFileProtection`
    /// (`MediaAtRestCrypto.sealAndWrite`) while BOTH key rows are `AfterFirstUnlock` and cached in
    /// memory — so once the device locks mid-pass, every `Data(contentsOf:)` fails while the keys
    /// stay perfectly available. Scoring that as ``unopenable`` would let a pass that read nothing
    /// at all look identical to a fully-migrated corpus and latch on it, after which binding drops
    /// the dual-open fallback and every straggler becomes permanently unreadable. "I could not see
    /// the bytes" is not "no key opens these bytes"; only the second is safe to ignore.
    public let indeterminate: Int
    /// The pass did nothing because the own-photos key itself was unavailable (locked or failing
    /// keychain). Blocks the latch.
    public let abortedNoOwnKey: Bool

    /// Whether this pass proves the corpus is fully migrated: it re-sealed nothing (so nothing was
    /// left under the old key when it started), failed nothing, and could classify everything.
    public var isClean: Bool {
        !abortedNoOwnKey && resealed == 0 && resealFailures == 0 && indeterminate == 0
    }

    /// Creates a result. Public so tests can build expectations; production values come from
    /// ``OwnPhotoKeyMigrator/performPass()``.
    public init(
        examined: Int = 0,
        alreadyOwnKey: Int = 0,
        resealed: Int = 0,
        resealFailures: Int = 0,
        unopenable: Int = 0,
        indeterminate: Int = 0,
        abortedNoOwnKey: Bool = false
    ) {
        self.examined = examined
        self.alreadyOwnKey = alreadyOwnKey
        self.resealed = resealed
        self.resealFailures = resealFailures
        self.unopenable = unopenable
        self.indeterminate = indeterminate
        self.abortedNoOwnKey = abortedNoOwnKey
    }
}

/// Re-seals the user's OWN photos from the pre-split shared media key onto the own-photos key.
///
/// Own files were sealed under the one shared key that is now the FRIEND-wall key, so a fresh
/// own-photos key cannot open them until they are re-sealed. This is that pass:
/// **eager, idempotent, and crash-safe.**
///
/// - **Eager**, not lazy: a photo the user never opens would otherwise stay under the
///   backup-restorable key forever, and the whole point of the split is that own photos stop being
///   restorable off-device. The read-path dual-open fallback (`MealPhotoStore` /
///   `ProgressPhotoStore`) is a safety net for the window before this finishes, not a substitute.
/// - **Idempotent**: per file, "does it already open under the own key?" is the first question, so
///   a second pass over a migrated corpus is a read-only sweep. ``run(maxPasses:)`` additionally
///   short-circuits once ``OwnPhotoMigrationLatch`` is set.
/// - **Crash-safe**: each re-seal is a single atomic, fully-protected write of the sealed bytes
///   (`sealAndWrite`), so a file is either wholly old or wholly new. A file that is neither — a
///   truncation from any other cause — fails GCM-open under both keys and is simply re-examined
///   next pass; it is never handed back as garbage and never written over blindly.
///
/// Order matters for safety: the pass NEVER deletes and never writes a file it could not first
/// open, so the worst case of any interruption is "try again next launch".
///
/// Concurrency: a nonisolated struct holding two non-`Sendable` key providers, so an instance is
/// confined to whatever isolation domain built it. The app builds one INSIDE its off-main launch
/// task (see ``standard(documentsDirectory:defaults:)``) rather than sharing the store providers,
/// precisely so no provider crosses a domain.
public struct OwnPhotoKeyMigrator {
    private let locations: OwnPhotoSealedLocations
    private let ownKeyProvider: any PrivateMediaKeyProviding
    private let legacyKeyProvider: any PrivateMediaKeyProviding
    private let latch: OwnPhotoMigrationLatch

    /// Creates a migrator over an explicit location set and key providers (the test seam).
    ///
    /// - Parameters:
    ///   - locations: Directories and files to sweep; missing paths are skipped.
    ///   - ownKeyProvider: Vends the own-photos key — the destination of every re-seal.
    ///   - legacyKeyProvider: Vends the pre-split shared (now friend-wall) key. Should be a
    ///     NON-minting provider in production: minting here would create a useless fresh key.
    ///   - latch: The completion latch ``run(maxPasses:)`` sets.
    public init(
        locations: OwnPhotoSealedLocations,
        ownKeyProvider: any PrivateMediaKeyProviding,
        legacyKeyProvider: any PrivateMediaKeyProviding,
        latch: OwnPhotoMigrationLatch
    ) {
        self.locations = locations
        self.ownKeyProvider = ownKeyProvider
        self.legacyKeyProvider = legacyKeyProvider
        self.latch = latch
    }

    /// The production migrator for an app container rooted at `documentsDirectory`.
    ///
    /// Builds its OWN key providers rather than borrowing the stores' — the providers are not
    /// `Sendable`, and this is called from a background launch task. The legacy provider is
    /// non-minting on purpose (``KeychainPrivateMediaKeyProvider/mintsIfAbsent``).
    public static func standard(documentsDirectory: URL, defaults: UserDefaults = .standard) -> OwnPhotoKeyMigrator {
        OwnPhotoKeyMigrator(
            locations: OwnPhotoCorpusLayout.sealedLocations(in: documentsDirectory),
            ownKeyProvider: KeychainPrivateMediaKeyProvider(role: .ownPhotos),
            legacyKeyProvider: KeychainPrivateMediaKeyProvider(role: .friendWall, mintsIfAbsent: false),
            latch: latch(defaults: defaults)
        )
    }

    /// The completion latch over `defaults` — the same one ``standard(documentsDirectory:defaults:)``
    /// uses, exposed so a caller can read the gate without building a migrator.
    public static func latch(defaults: UserDefaults = .standard) -> OwnPhotoMigrationLatch {
        OwnPhotoMigrationLatch(defaults: defaults)
    }

    /// Whether the migration has already been proven complete (see ``OwnPhotoMigrationLatch``).
    public var isComplete: Bool { latch.isComplete }

    /// R2: the named maximum number of sweep passes ``run(maxPasses:)`` will fund — one to re-seal,
    /// one to confirm the corpus is now clean.
    public static let maxMigrationPasses = 2

    /// Runs passes until one comes back clean, then sets the latch.
    ///
    /// A pass that re-sealed files is by definition not proof — it FOUND legacy files — so a second
    /// pass runs to confirm the corpus is now clean; that is what `maxPasses` funds. Stops early
    /// (leaving the latch closed) when a pass makes no forward progress, so a permanently
    /// unwritable file cannot spin.
    ///
    /// - Returns: the latch state afterwards — true only when completion is now proven. R7:
    ///   deliberately not `@discardableResult` — this Bool gates an irreversible key binding
    ///   downstream, so ignoring it is never safe.
    public func run(maxPasses: Int = Self.maxMigrationPasses) -> Bool {
        if latch.isComplete { return true }
        // R2: the named bound. `passesLeft` is decremented as the first statement of every
        // iteration, and two early returns (a clean pass, or a pass with no forward progress) exit
        // sooner.
        var passesLeft = max(1, maxPasses)
        while passesLeft > 0 {
            passesLeft -= 1
            let result = performPass()
            if result.isClean {
                latch.markComplete()
                return true
            }
            // No forward progress (aborted, or everything left is unwritable/indeterminate):
            // another identical pass would change nothing. Leave the latch closed and retry at the
            // next launch, when the keychain or the disk may have recovered.
            if result.resealed == 0 { return false }
        }
        return false
    }

    /// Sweeps every location once, re-sealing legacy-key files under the own-photos key.
    ///
    /// Never sets the latch — ``run(maxPasses:)`` owns that decision — so tests can drive passes
    /// directly and assert idempotence.
    ///
    /// - Returns: the pass tally, which carries the pass's failure information
    ///   (`abortedNoOwnKey`, `resealFailures`, `indeterminate`). R7: not `@discardableResult`.
    public func performPass() -> OwnPhotoKeyMigrationResult {
        let scan = candidateFiles()
        // Nothing on disk (a fresh install, or a corpus already wiped): trivially clean, and no
        // reason to touch the keychain at all.
        if scan.urls.isEmpty && scan.unreadableDirectories == 0 {
            return OwnPhotoKeyMigrationResult()
        }
        guard ownKeyProvider.mediaKey() != nil else {
            return OwnPhotoKeyMigrationResult(abortedNoOwnKey: true)
        }
        // Probed once per pass: a nil legacy key does NOT abort (files may all be migrated
        // already), but it makes every non-own-key file indeterminate rather than "garbage".
        let legacyKeyAvailable = legacyKeyProvider.mediaKey() != nil

        var alreadyOwnKey = 0
        var resealed = 0
        var resealFailures = 0
        var unopenable = 0
        // A directory that exists but could not be listed hides an unknown number of files, so it
        // is indeterminate — never silently "nothing to do".
        var indeterminate = scan.unreadableDirectories

        for url in scan.urls {
            let purpose = purpose(for: url)
            let stored: Data
            do {
                stored = try Data(contentsOf: url)
            } catch {
                // Could NOT READ the bytes — which is a different fact from "read them and no key
                // opens them", and the difference is load-bearing. Own-photo files are
                // `.completeFileProtection` while both key rows are `AfterFirstUnlock` + cached, so
                // a device that locks mid-pass fails every read while the keys stay available. If
                // that scored as `unopenable` the pass would look clean, latch, and let the binder
                // drop the dual-open fallback over files still sealed under the pre-split key. A
                // read failure has no answer to "is this still under the old key?", so it is
                // indeterminate — the same fail-closed direction as an unlistable directory.
                indeterminate += 1
                continue
            }
            guard !stored.isEmpty else {
                // A genuinely empty file: no bytes to migrate, and nothing the key flip can cost.
                unopenable += 1
                continue
            }
            if ownKeyProvider.gcmOpen(stored, purpose: purpose) != nil {
                alreadyOwnKey += 1
                continue
            }
            guard legacyKeyAvailable else {
                indeterminate += 1
                continue
            }
            guard let plaintext = legacyKeyProvider.gcmOpen(stored, purpose: purpose) else {
                unopenable += 1
                continue
            }
            if ownKeyProvider.sealAndWrite(plaintext, to: url, purpose: purpose) {
                resealed += 1
            } else {
                resealFailures += 1
            }
        }

        return OwnPhotoKeyMigrationResult(
            examined: scan.urls.count,
            alreadyOwnKey: alreadyOwnKey,
            resealed: resealed,
            resealFailures: resealFailures,
            unopenable: unopenable,
            indeterminate: indeterminate
        )
    }

    /// Maps the fixed, app-owned corpus layout to the purpose its store uses. A test-only path
    /// outside that layout defaults to the original meal corpus; untrusted file names never select
    /// or construct a purpose.
    private func purpose(for url: URL) -> CryptographicPurpose {
        let components = Set(url.pathComponents)
        if url.lastPathComponent == OwnPhotoCorpusLayout.progressIndexFileName {
            return FernletCryptoPurpose.AEAD.progressPhotoIndexV2
        }
        if components.contains(OwnPhotoCorpusLayout.progressPhotosDirectoryName) {
            return FernletCryptoPurpose.AEAD.progressPhotoV2
        }
        if components.contains(OwnPhotoCorpusLayout.recipePhotosDirectoryName) {
            return FernletCryptoPurpose.AEAD.recipePhotoV2
        }
        return FernletCryptoPurpose.AEAD.mealPhotoV2
    }

    /// One directory sweep's output: the files to examine plus how many existing directories could
    /// not be listed (each of which blocks the latch).
    private struct Scan {
        var urls: [URL] = []
        var unreadableDirectories = 0
    }

    /// Enumerates every regular file in the configured directories (non-recursively — all own
    /// corpora are flat id→file maps) plus the individually-named sealed files that exist.
    private func candidateFiles() -> Scan {
        var scan = Scan()
        let fileManager = FileManager.default
        for directory in locations.directories {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            guard let contents = try? fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
            ) else {
                scan.unreadableDirectories += 1
                continue
            }
            for url in contents {
                let isRegularFile = (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile
                guard isRegularFile == true else { continue }
                scan.urls.append(url)
            }
        }
        for url in locations.files where fileManager.fileExists(atPath: url.path) {
            scan.urls.append(url)
        }
        return scan
    }
}
