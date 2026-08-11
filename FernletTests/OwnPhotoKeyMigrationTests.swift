import CryptoKit
import Foundation
import Testing
import UIKit
import FernletDomainModel
import PrivateMediaStore

/// Security-hardening Phase 5, steps 5a-1…5a-4: the media key is split in two, the user's OWN
/// photos migrate off the shared (friend-wall) key onto their own key, and a dual-open safety net
/// carries any straggler until the eager pass finishes.
///
/// What these tests are actually defending is a **data-loss** property, not a feature. The own key
/// is on its way to being device-bound (5c) and the dual-open fallback is on its way out, and both
/// of those steps are gated on ``OwnPhotoMigrationLatch``. If the latch could be set while one file
/// was still sealed under the old key — or while the pass could not even tell — that file would
/// silently become unreadable bytes on a phone the user still owns. So the suite pins the latch's
/// *closed* directions at least as hard as its open one.
@MainActor
struct OwnPhotoKeyMigrationTests {

    // MARK: - Fixtures

    private func jpeg(width: Int = 120, height: Int = 120) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { ctx in
            UIColor.systemPink.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.7)!
    }

    /// AES-GCM-seals bytes the way every media store does, so a fixture file is byte-compatible
    /// with something the shipping code wrote.
    private func sealed(_ plaintext: Data, under key: SymmetricKey) throws -> Data {
        try #require(try AES.GCM.seal(plaintext, using: key).combined)
    }

    /// A temporary stand-in for the app's Documents directory, with the three own-photo corpora
    /// created underneath it.
    private func makeDocumentsDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("OwnPhotoKeyMigrationTests-\(UUID().uuidString)", isDirectory: true)
        let locations = OwnPhotoCorpusLayout.sealedLocations(in: root)
        for directory in locations.directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    /// An isolated defaults suite so a test never reads or writes the device's real latch. The
    /// suite name comes back so the test can remove the persistent domain when it finishes.
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let name = "OwnPhotoKeyMigrationTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Raw bytes of a symmetric key, for identity comparisons.
    private func bytes(_ key: SymmetricKey) -> Data {
        key.withUnsafeBytes { Data($0) }
    }

    private func migrator(
        root: URL,
        ownKey: any PrivateMediaKeyProviding,
        legacyKey: any PrivateMediaKeyProviding,
        defaults: UserDefaults
    ) -> OwnPhotoKeyMigrator {
        OwnPhotoKeyMigrator(
            locations: OwnPhotoCorpusLayout.sealedLocations(in: root),
            ownKeyProvider: ownKey,
            legacyKeyProvider: legacyKey,
            latch: OwnPhotoMigrationLatch(defaults: defaults)
        )
    }

    /// Writes one legacy-sealed file into each own corpus (meal, recipe, progress photo, progress
    /// index) and returns the file URLs plus the plaintext each one carries.
    @discardableResult
    private func seedLegacyCorpus(root: URL, key: SymmetricKey) throws -> [URL: Data] {
        let locations = OwnPhotoCorpusLayout.sealedLocations(in: root)
        var written: [URL: Data] = [:]
        for directory in locations.directories {
            let plaintext = jpeg()
            let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
            try sealed(plaintext, under: key).write(to: url)
            written[url] = plaintext
        }
        for file in locations.files {
            let plaintext = Data("[]".utf8)  // an empty but well-formed progress index
            try sealed(plaintext, under: key).write(to: file)
            written[file] = plaintext
        }
        return written
    }

    private func opens(_ url: URL, under key: SymmetricKey) -> Data? {
        guard let stored = try? Data(contentsOf: url),
              let box = try? AES.GCM.SealedBox(combined: stored) else { return nil }
        return try? AES.GCM.open(box, using: key)
    }

    // MARK: - Migration

    // MARK: Every own corpus — meal, recipe, progress bytes AND the sealed progress index — is
    // re-sealed onto the own key, and afterwards the friend key opens NONE of them. That second
    // half is the actual security property: a stolen container plus the backup-restorable friend
    // key must no longer yield the user's own photos.
    @Test func migrationResealsEveryOwnCorpusAndLocksOutTheFriendKey() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyCorpus(root: root, key: legacyKey)
        #expect(seeded.count == 4, "fixture must cover meal, recipe, progress bytes and the index")

        let subject = migrator(
            root: root,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKey: InMemoryPrivateMediaKeyProvider(key: legacyKey),
            defaults: defaults
        )
        let result = subject.performPass()

        #expect(result.examined == 4)
        #expect(result.resealed == 4)
        #expect(result.resealFailures == 0)
        #expect(result.indeterminate == 0)
        #expect(!result.isClean, "a pass that FOUND legacy files is not proof of completion")

        for (url, plaintext) in seeded {
            #expect(opens(url, under: ownKey) == plaintext, "\(url.lastPathComponent) did not re-seal under the own key")
            #expect(opens(url, under: legacyKey) == nil, "\(url.lastPathComponent) still opens under the friend key")
        }
    }

    // MARK: The second pass is a read-only sweep: nothing re-sealed, everything already own-key,
    // and the bytes are byte-identical (a pass that "helpfully" rewrote files would churn the disk
    // and, worse, hide a failure to recognise its own output).
    @Test func secondPassIsANoOp() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyCorpus(root: root, key: legacyKey)

        let subject = migrator(
            root: root,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKey: InMemoryPrivateMediaKeyProvider(key: legacyKey),
            defaults: defaults
        )
        _ = subject.performPass()
        let ordered = seeded.keys.sorted { $0.path < $1.path }
        let afterFirst = ordered.compactMap { try? Data(contentsOf: $0) }

        let second = subject.performPass()
        #expect(second.resealed == 0)
        #expect(second.alreadyOwnKey == 4)
        #expect(second.isClean)

        let afterSecond = ordered.compactMap { try? Data(contentsOf: $0) }
        #expect(afterFirst == afterSecond, "the idempotent pass rewrote files it had already migrated")
    }

    // MARK: Crash-safety: a truncated file opens under NEITHER key. It must be counted, left
    // exactly as-is (never overwritten with garbage, never deleted), re-examined on later passes,
    // and it must not stop its neighbours from migrating.
    @Test func truncatedFileIsRetriedNeverReturnedAsGarbage() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyCorpus(root: root, key: legacyKey)

        // Truncate one meal-photo file to a prefix of its sealed bytes.
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
        let mealFile = try #require(seeded.keys.first {
            $0.deletingLastPathComponent().standardizedFileURL.path == mealDirectory.standardizedFileURL.path
        })
        let intact = try #require(try? Data(contentsOf: mealFile))
        let truncated = Data(intact.prefix(12))
        try truncated.write(to: mealFile)

        let subject = migrator(
            root: root,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKey: InMemoryPrivateMediaKeyProvider(key: legacyKey),
            defaults: defaults
        )
        let first = subject.performPass()
        #expect(first.unopenable == 1)
        #expect(first.resealed == 3, "the truncated file must not block its neighbours")
        let onDisk = try? Data(contentsOf: mealFile)
        #expect(onDisk == truncated, "the pass rewrote a file it could not open")

        // Re-examined next pass (not remembered as done), still never handed back as bytes.
        let second = subject.performPass()
        #expect(second.examined == 4)
        #expect(second.unopenable == 1)
        let store = MealPhotoStore(
            directory: mealDirectory,
            keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKeyProvider: InMemoryPrivateMediaKeyProvider(key: legacyKey)
        )
        let id = try #require(UUID(uuidString: mealFile.deletingPathExtension().lastPathComponent))
        #expect(store.imageData(for: id) == nil, "truncated bytes were handed back as a photo")
    }

    // MARK: - Latch semantics

    // MARK: `run` drives passes until one is clean, and ONLY then latches. One clean pass over an
    // already-migrated corpus latches immediately; an empty corpus latches without touching a key.
    @Test func runLatchesOnlyAfterACleanPass() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        try seedLegacyCorpus(root: root, key: legacyKey)

        let latch = OwnPhotoMigrationLatch(defaults: defaults)
        #expect(!latch.isComplete, "the latch must start closed")

        let subject = migrator(
            root: root,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKey: InMemoryPrivateMediaKeyProvider(key: legacyKey),
            defaults: defaults
        )
        // One pass migrates, the confirming pass comes back clean.
        #expect(subject.run())
        #expect(latch.isComplete)
    }

    @Test func emptyCorpusLatchesWithoutAKey() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // Both providers are keyless: an empty corpus must still latch, because there is provably
        // nothing left under the old key.
        let subject = migrator(
            root: root,
            ownKey: NoMediaKeyProvider(),
            legacyKey: NoMediaKeyProvider(),
            defaults: defaults
        )
        #expect(subject.run())
        #expect(OwnPhotoMigrationLatch(defaults: defaults).isComplete)
    }

    // MARK: The fail-closed direction that matters most: when the pass cannot answer "is this
    // still under the old key?" — because the legacy key is unavailable — the latch stays closed,
    // so 5c's binding (and the dual-open drop) can never proceed on an unproven corpus.
    @Test func unavailableLegacyKeyLeavesTheLatchClosed() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        try seedLegacyCorpus(root: root, key: legacyKey)

        let subject = migrator(
            root: root,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            legacyKey: NoMediaKeyProvider(),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.indeterminate == 4)
        #expect(!result.isClean)
        #expect(!subject.run())
        #expect(!OwnPhotoMigrationLatch(defaults: defaults).isComplete)
    }

    // MARK: The third way a pass can fail to answer, and the one that used to slip through: the
    // KEYS are fine but the file's BYTES cannot be read. Own-photo files are written
    // `.completeFileProtection` while both keychain rows are `AfterFirstUnlock` and cached in
    // memory, so a device that locks mid-pass fails every read while both providers keep vending
    // keys. Scored as "unopenable" (which does not block the latch) that pass looks exactly like a
    // fully-migrated corpus: examined == N, resealed == 0, indeterminate == 0 → clean → latched,
    // after which binding drops the dual-open fallback and every straggler becomes permanently
    // unreadable with no error anywhere. It must be indeterminate, which blocks.
    @Test func anUnreadableFileIsIndeterminateNotUnopenable() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyCorpus(root: root, key: legacyKey)

        // Deny read on every seeded file — the closest a test can get to a Complete-class file
        // whose protected data is unavailable. Permissions are restored before the directory is
        // torn down so the cleanup can still remove them.
        for url in seeded.keys {
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        }
        defer {
            for url in seeded.keys {
                try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
            }
        }

        let subject = migrator(
            root: root,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKey: InMemoryPrivateMediaKeyProvider(key: legacyKey),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.examined == seeded.count)
        #expect(result.indeterminate == seeded.count,
                "a file whose bytes could not be read was scored as 'no key opens it'")
        #expect(result.unopenable == 0)
        #expect(!result.isClean, "a pass that read nothing at all claimed to prove the corpus migrated")
        #expect(!subject.run())
        #expect(!OwnPhotoMigrationLatch(defaults: defaults).isComplete,
                "the latch was set over files still sealed under the pre-split key")

        // ...and once the bytes are readable again, the same corpus migrates and latches normally,
        // so the fail-closed direction costs nothing but a retry.
        for url in seeded.keys {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        }
        #expect(subject.run())
        #expect(OwnPhotoMigrationLatch(defaults: defaults).isComplete)
        for (url, plaintext) in seeded {
            #expect(opens(url, under: ownKey) == plaintext)
        }
    }

    // MARK: And the same for the own key: a locked/failing keychain aborts the pass rather than
    // "finding" a clean corpus it never actually inspected.
    @Test func unavailableOwnKeyAbortsWithoutLatching() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        try seedLegacyCorpus(root: root, key: legacyKey)

        let subject = migrator(
            root: root,
            ownKey: NoMediaKeyProvider(),
            legacyKey: InMemoryPrivateMediaKeyProvider(key: legacyKey),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.abortedNoOwnKey)
        #expect(!result.isClean)
        #expect(!subject.run())
        #expect(!OwnPhotoMigrationLatch(defaults: defaults).isComplete)
    }

    // MARK: The headline dual-open + latch case from the plan: one file is left under the legacy
    // key (its re-seal cannot be written), and BOTH halves must hold — the user still sees that
    // photo through the fallback, and the latch stays closed so nothing binds over it.
    @Test func oneStragglerKeepsBytesReadableAndTheLatchClosed() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        let plaintext = jpeg()
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
        let id = UUID()
        let straggler = mealDirectory.appendingPathComponent("\(id.uuidString).jpg")
        try sealed(plaintext, under: legacyKey).write(to: straggler)

        // Make the directory unwritable so the atomic re-seal cannot land — the disk-error shape of
        // "a file is still legacy after the pass".
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: mealDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mealDirectory.path) }

        let subject = migrator(
            root: root,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKey: InMemoryPrivateMediaKeyProvider(key: legacyKey),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.resealFailures == 1, "expected the unwritable re-seal to be counted as a failure")
        #expect(!result.isClean)
        #expect(!subject.run())
        #expect(!OwnPhotoMigrationLatch(defaults: defaults).isComplete,
                "the latch opened while a file was still sealed under the old key")

        // Half two: the user can still see the photo, via the read-path dual-open fallback.
        let store = MealPhotoStore(
            directory: mealDirectory,
            keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKeyProvider: InMemoryPrivateMediaKeyProvider(key: legacyKey)
        )
        #expect(store.imageData(for: id) == plaintext)

        // Once the disk recovers, the same migrator finishes the job and latches.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: mealDirectory.path)
        #expect(subject.run())
        #expect(OwnPhotoMigrationLatch(defaults: defaults).isComplete)
        #expect(opens(straggler, under: ownKey) == plaintext)
    }

    // MARK: `run` short-circuits on the latch — no directory sweep, no keychain hit — so the
    // launch-time call stays free after the one-time migration.
    @Test func runShortCircuitsOnceLatched() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        OwnPhotoMigrationLatch(defaults: defaults).markComplete()

        let legacyKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyCorpus(root: root, key: legacyKey)
        let subject = migrator(
            root: root,
            ownKey: NoMediaKeyProvider(),
            legacyKey: NoMediaKeyProvider(),
            defaults: defaults
        )
        #expect(subject.run(), "a latched migrator must report complete without doing work")
        for url in seeded.keys {
            #expect(opens(url, under: legacyKey) != nil, "a latched run touched the corpus")
        }
    }

    // MARK: - End-to-end against the REAL keychain rows

    // MARK: The production wiring, not a mock of it: `standard(documentsDirectory:defaults:)` must
    // move files off the real friend row onto the real own row.
    @Test func standardMigratorMovesFilesFromTheRealFriendRowToTheRealOwnRow() throws {
        let root = try makeDocumentsDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let friendProvider = KeychainPrivateMediaKeyProvider(role: .friendWall)
        let ownProvider = KeychainPrivateMediaKeyProvider(role: .ownPhotos)
        let friendKey = try #require(friendProvider.mediaKey(), "could not read or mint the friend row")
        let ownKey = try #require(ownProvider.mediaKey(), "could not read or mint the own row")
        #expect(bytes(friendKey) != bytes(ownKey), "the split did not produce two distinct keys")

        let plaintext = jpeg()
        let file = OwnPhotoCorpusLayout.recipePhotosDirectory(in: root)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try sealed(plaintext, under: friendKey).write(to: file)

        #expect(OwnPhotoKeyMigrator.standard(documentsDirectory: root, defaults: defaults).run())
        #expect(opens(file, under: ownKey) == plaintext)
        #expect(opens(file, under: friendKey) == nil, "an own photo still opens under the backup-restorable friend key")
    }

    // MARK: The friend wall is on the OTHER side of the split and must be unaffected: bytes it
    // seals through its default (friend-role) provider stay readable through that role, and are
    // NOT readable by an own-role provider. This is the regression that would fire if someone
    // repointed `PrivateMediaStore`'s default at the own key.
    @Test func friendWallStaysOnTheOriginalRow() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FriendWallSplit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexURL = directory.appendingPathComponent("MeshPhotoCache.json")

        let photo = FriendPhotoPayload(
            id: UUID(),
            imageData: jpeg(width: 200, height: 200),
            addedAt: Date(),
            senderName: "Wall",
            senderFingerprint: "fp",
            senderSigningPublicKey: Data([0x01]),
            session: nil
        )
        // Default provider == friend role. Save through it, then read back through a fresh one.
        PrivateMediaStore(indexURL: indexURL).save([photo])
        let byteless = photo.withoutImageData()
        #expect(PrivateMediaStore(indexURL: indexURL).imageData(for: byteless) != nil,
                "the friend wall stopped being readable across the key split")

        let ownRoleStore = PrivateMediaStore(
            indexURL: indexURL,
            keyProvider: KeychainPrivateMediaKeyProvider(role: .ownPhotos)
        )
        #expect(ownRoleStore.imageData(for: byteless) == nil,
                "friend-wall bytes opened under the own-photos key — the two rows are not distinct")
    }
}

/// A provider that can never produce a key — the "locked or failing keychain" shape every media
/// store and the migration pass must fail closed on.
struct NoMediaKeyProvider: PrivateMediaKeyProviding {
    func mediaKey() -> SymmetricKey? { nil }
}
