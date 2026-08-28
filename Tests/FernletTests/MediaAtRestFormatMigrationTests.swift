import CryptoKit
import FernletCrypto
import Foundation
import Testing
import UIKit
import FernletDomainModel
import PrivateMediaStore

/// Crypto-standardization Phase 2.3: `MediaAtRestFormatMigrator` retires every remaining
/// pre-domain-separation media blob so Phase 3 can delete `gcmOpen`'s legacy-read branch.
///
/// What this suite defends is the trustworthiness of `MediaAtRestFormatMigrationLatch` — a bit
/// that will later license deleting a READER over these exact bytes. So the closed directions
/// are pinned at least as hard as the open one: "could not look" always blocks (unreadable
/// bytes, unlistable directories, missing keys, a mid-pass rewrite), "should not exist" blocks
/// loudly (a friend-key own file the key latch claims impossible), and the two argued
/// non-blocking residues (`unopenableUnprefixed`, `refusedPlaintext`) are pinned as exactly the
/// classes the branch delete cannot cost. Division of labor with `OwnPhotoKeyMigrator` is
/// proven by composition, not asserted: the two sweeps run against the same corpus and land it
/// clean without fighting.
///
/// Fixture discipline: UUID-fresh temp roots per test (never shared container roots — see
/// `PhotoDirectoryIsolationTests`), `UserDefaults(suiteName: UUID)` per test for BOTH latches,
/// in-memory key providers, and fixtures that RE-SPELL the marker (`"FMA2"`) and build legacy
/// boxes as bare `AES.GCM.seal(_:using:).combined` — never asking production what the format
/// is, the `OwnPhotoKeyMigrationTests.opens` doctrine. Own-root tests seed the key-migration
/// latch SET unless stated.
@MainActor
struct MediaAtRestFormatMigrationTests {

    // MARK: - Fixtures

    /// A real JPEG, so plaintext fixtures carry genuine `FF D8 FF` bytes and the pixel-bounds
    /// gate has real dimensions to read.
    private func jpeg(width: Int = 64, height: Int = 64) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.7)!
    }

    /// A real PNG — a parseable, safe-bounds image the census's JPEG-only sniff does NOT class
    /// as plaintext (the §4 documented-limitation fixture).
    private func png(width: Int = 64, height: Int = 64) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.pngData()!
    }

    /// A byte-exact PRE-domain-separation box: combined (nonce + ciphertext + tag), no marker,
    /// no AAD — what the legacy writers put on disk and what the legacy-read branch still opens.
    private func legacySealed(_ plaintext: Data, under key: SymmetricKey) throws -> Data {
        try #require(try AES.GCM.seal(plaintext, using: key).combined)
    }

    /// A current-format box with the marker re-spelled here (never read from the module — a
    /// fixture that asked production what the format is could never notice production changing it).
    private func currentFormatSealed(
        _ plaintext: Data,
        under key: SymmetricKey,
        purpose: CryptographicPurpose
    ) throws -> Data {
        try Data("FMA2".utf8) + #require(
            try AES.GCM.seal(plaintext, using: key, authenticating: purpose.data).combined
        )
    }

    /// Opens an at-rest file the way the current readers do — marker, then AAD-authenticated
    /// open under the file's purpose. Nil for a missing marker, wrong key, or wrong purpose,
    /// which is exactly what the per-location AAD-binding assertions lean on.
    private func openCurrentFormat(_ url: URL, under key: SymmetricKey, purpose: CryptographicPurpose) -> Data? {
        guard let stored = try? Data(contentsOf: url) else { return nil }
        let marker = Data("FMA2".utf8)
        guard stored.starts(with: marker),
              let box = try? AES.GCM.SealedBox(combined: stored.dropFirst(marker.count)) else { return nil }
        return try? AES.GCM.open(box, using: key, authenticating: purpose.data)
    }

    /// A temp stand-in for the app's Documents directory with the own-photo corpora created.
    private func makeOwnRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaAtRestFormatMigrationTests-own-\(UUID().uuidString)", isDirectory: true)
        for directory in OwnPhotoCorpusLayout.sealedLocations(in: root).directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    /// A temp stand-in for the proximity support directory with the wall's two photo
    /// directories created.
    private func makeWallRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaAtRestFormatMigrationTests-wall-\(UUID().uuidString)", isDirectory: true)
        for directory in FriendWallCorpusLayout.resealableLocations(in: root).directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    /// An isolated defaults suite per test for BOTH latches, torn down by name.
    private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let name = "MediaAtRestFormatMigrationTests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// Every path under `root` plus the full bytes of every regular file — the byte-identity
    /// proof's before/after snapshot (the census tests' recipe).
    private func snapshot(of root: URL) throws -> (paths: [String], files: [String: Data]) {
        var paths: [String] = []
        var files: [String: Data] = [:]
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])
        while let url = enumerator?.nextObject() as? URL {
            let relative = url.path.replacingOccurrences(of: root.path, with: "")
            paths.append(relative)
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                files[relative] = try Data(contentsOf: url)
            }
        }
        return (paths.sorted(), files)
    }

    /// Builds the subject over explicit roots and providers, seeding the key-migration latch
    /// SET (the steady state) unless a test says otherwise.
    private func makeMigrator(
        ownRoot: URL,
        wallRoot: URL,
        ownKey: any PrivateMediaKeyProviding,
        wallKey: any PrivateMediaKeyProviding,
        defaults: UserDefaults,
        ownKeyMigrationComplete: Bool = true
    ) -> MediaAtRestFormatMigrator {
        let keyLatch = OwnPhotoMigrationLatch(defaults: defaults)
        if ownKeyMigrationComplete { keyLatch.markComplete() }
        return MediaAtRestFormatMigrator(
            ownLocations: OwnPhotoCorpusLayout.sealedLocations(in: ownRoot),
            wallLocations: FriendWallCorpusLayout.resealableLocations(in: wallRoot),
            ownKeyProvider: ownKey,
            wallKeyProvider: wallKey,
            ownKeyMigrationLatch: keyLatch,
            latch: MediaAtRestFormatMigrationLatch(defaults: defaults)
        )
    }

    /// Writes one legacy-sealed file into each own corpus (meal, recipe, progress bytes,
    /// progress index) and returns URL → plaintext.
    @discardableResult
    private func seedLegacyOwnCorpus(root: URL, key: SymmetricKey) throws -> [URL: Data] {
        let locations = OwnPhotoCorpusLayout.sealedLocations(in: root)
        var written: [URL: Data] = [:]
        for directory in locations.directories {
            let plaintext = jpeg()
            let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
            try legacySealed(plaintext, under: key).write(to: url)
            written[url] = plaintext
        }
        for file in locations.files {
            let plaintext = Data("[]".utf8)  // an empty but well-formed progress index
            try legacySealed(plaintext, under: key).write(to: file)
            written[file] = plaintext
        }
        return written
    }

    /// Writes one legacy-sealed file into each wall location (photo, thumbnail, sealed index)
    /// and returns URL → plaintext.
    @discardableResult
    private func seedLegacyWallCorpus(root: URL, key: SymmetricKey) throws -> [URL: Data] {
        let locations = FriendWallCorpusLayout.resealableLocations(in: root)
        var written: [URL: Data] = [:]
        for directory in locations.directories {
            let plaintext = jpeg()
            let url = directory.appendingPathComponent("\(UUID().uuidString).jpg")
            try legacySealed(plaintext, under: key).write(to: url)
            written[url] = plaintext
        }
        for file in locations.files {
            let plaintext = Data("[]".utf8)  // an empty but well-formed wall index
            try legacySealed(plaintext, under: key).write(to: file)
            written[file] = plaintext
        }
        return written
    }

    // MARK: - 1/2: legacy sealed boxes convert under the right key and the right purpose

    @Test func convertsLegacySealedFilesInEveryOwnCorpusUnderTheOwnKey() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyOwnCorpus(root: ownRoot, key: ownKey)
        #expect(seeded.count == 4, "fixture must cover meal, recipe, progress bytes and the index")

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(),
            defaults: defaults
        )
        let result = subject.performPass()

        #expect(result.converted == 4)
        #expect(result.conversionFailures == 0)
        #expect(result.indeterminate == 0)
        #expect(!result.isClean, "a pass that FOUND legacy files is not proof of completion")
        #expect(result.madeForwardProgress)

        for (url, plaintext) in seeded {
            let stored = try #require(try? Data(contentsOf: url))
            #expect(stored.starts(with: Data("FMA2".utf8)),
                    "\(url.lastPathComponent) is not in the current format")
            let purpose = OwnPhotoCorpusLayout.sealPurpose(for: url)
            #expect(openCurrentFormat(url, under: ownKey, purpose: purpose) == plaintext,
                    "\(url.lastPathComponent) did not re-seal under its own purpose")
            // The per-location AAD binding: the same key with the WRONG purpose must fail.
            let wrongPurpose = purpose == FernletCryptoPurpose.AEAD.mealPhotoV2
                ? FernletCryptoPurpose.AEAD.recipePhotoV2
                : FernletCryptoPurpose.AEAD.mealPhotoV2
            #expect(openCurrentFormat(url, under: ownKey, purpose: wrongPurpose) == nil,
                    "\(url.lastPathComponent) opens under a purpose that is not its location's")
        }
    }

    @Test func wallPhotosThumbnailsAndSealedIndexConvertUnderTheWallKeyAndPurposes() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wallKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyWallCorpus(root: wallRoot, key: wallKey)
        #expect(seeded.count == 3, "fixture must cover photos, thumbnails and the sealed index")

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()

        #expect(result.converted == 3)
        #expect(!result.isClean)

        // Pins `FriendWallCorpusLayout.sealPurpose(for:)` per location: each file opens ONLY
        // under its own location's purpose.
        let allWallPurposes = [
            FernletCryptoPurpose.AEAD.privateFriendPhotoImageV2,
            FernletCryptoPurpose.AEAD.privateFriendPhotoThumbnailV2,
            FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2
        ]
        for (url, plaintext) in seeded {
            let expected = FriendWallCorpusLayout.sealPurpose(for: url)
            #expect(openCurrentFormat(url, under: wallKey, purpose: expected) == plaintext,
                    "\(url.lastPathComponent) did not re-seal under its location's purpose")
            for other in allWallPurposes where other != expected {
                #expect(openCurrentFormat(url, under: wallKey, purpose: other) == nil,
                        "\(url.lastPathComponent) opens under \(other), not only its own purpose")
            }
        }
        // The mapping itself, stated once: index by frozen name, thumbnails by frozen component.
        let locations = FriendWallCorpusLayout.resealableLocations(in: wallRoot)
        #expect(FriendWallCorpusLayout.sealPurpose(for: locations.files[0])
                == FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2)
    }

    // MARK: - 3/4: idempotence and the latch

    @Test func secondPassIsAReadOnlyNoOpByteIdentical() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let wallKey = SymmetricKey(size: .bits256)
        try seedLegacyOwnCorpus(root: ownRoot, key: ownKey)
        try seedLegacyWallCorpus(root: wallRoot, key: wallKey)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        #expect(subject.run())

        let ownBefore = try snapshot(of: ownRoot)
        let wallBefore = try snapshot(of: wallRoot)
        let confirming = subject.performPass()

        #expect(confirming.isClean)
        #expect(confirming.converted == 0)
        #expect(confirming.convertedPlaintext == 0)
        #expect(confirming.alreadyCurrentFormat == 7)
        #expect(try snapshot(of: ownRoot).files == ownBefore.files,
                "the confirming pass rewrote own-root bytes")
        #expect(try snapshot(of: ownRoot).paths == ownBefore.paths)
        #expect(try snapshot(of: wallRoot).files == wallBefore.files,
                "the confirming pass rewrote wall-root bytes")
        #expect(try snapshot(of: wallRoot).paths == wallBefore.paths)
    }

    @Test func runLatchesOnlyAfterACleanConfirmingPass() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        try seedLegacyOwnCorpus(root: ownRoot, key: ownKey)
        let latch = MediaAtRestFormatMigrationLatch(defaults: defaults)
        #expect(!latch.isComplete, "the latch must start closed")

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(),
            defaults: defaults
        )
        // One pass converts, the confirming pass comes back clean — only then does run latch.
        #expect(subject.run())
        #expect(latch.isComplete)
    }

    @Test func latchShortCircuitsBeforeAnyDiskWork() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        MediaAtRestFormatMigrationLatch(defaults: defaults).markComplete()

        let legacyKey = SymmetricKey(size: .bits256)
        let seeded = try seedLegacyOwnCorpus(root: ownRoot, key: legacyKey)
        let ownTrap = KeychainTouchTrap()
        let wallTrap = KeychainTouchTrap()
        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: ownTrap, wallKey: wallTrap,
            defaults: defaults
        )

        #expect(subject.run(), "a latched migrator must report complete without doing work")
        for url in seeded.keys {
            let bytes = try #require(try? Data(contentsOf: url))
            #expect(!bytes.starts(with: Data("FMA2".utf8)), "a latched run touched the corpus")
        }
        #expect(!ownTrap.touched && !wallTrap.touched, "a latched run touched the keychain")
    }

    // MARK: - 5/6/7: the plaintext generations

    @Test func mealPlaintextJPEGIsSealedInPlace() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let plaintext = jpeg()
        let url = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try plaintext.write(to: url)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(),
            defaults: defaults
        )
        let result = subject.performPass()

        #expect(result.convertedPlaintext == 1)
        #expect(result.refusedPlaintext == 0)
        let stored = try #require(try? Data(contentsOf: url))
        #expect(stored.starts(with: Data("FMA2".utf8)))
        #expect(openCurrentFormat(url, under: ownKey, purpose: FernletCryptoPurpose.AEAD.mealPhotoV2) == plaintext,
                "the sealed meal photo does not open under mealPhotoV2 with its original bytes")
    }

    @Test func plaintextJPEGInBornSealedCorporaIsRefusedNotConverted() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let recipeFile = OwnPhotoCorpusLayout.recipePhotosDirectory(in: ownRoot)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let progressFile = OwnPhotoCorpusLayout.progressPhotosDirectory(in: ownRoot)
            .appendingPathComponent(OwnPhotoCorpusLayout.progressPhotosInnerDirectoryName, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let recipeBytes = jpeg()
        let progressBytes = jpeg(width: 80, height: 48)
        try recipeBytes.write(to: recipeFile)
        try progressBytes.write(to: progressFile)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(),
            defaults: defaults
        )
        let result = subject.performPass()

        // The §8 split: refused plaintext is census-`plaintextJPEG`, never part of the gate's
        // `unopenableUnprefixed` equality — laundering-refusal must not masquerade as legacy residue.
        #expect(result.refusedPlaintext == 2)
        #expect(result.unopenableUnprefixed == 0)
        #expect(result.convertedPlaintext == 0)
        #expect(result.isClean, "a refusal is a decision, not a blind spot — it must not block")
        #expect((try? Data(contentsOf: recipeFile)) == recipeBytes, "the refused recipe bytes changed")
        #expect((try? Data(contentsOf: progressFile)) == progressBytes, "the refused progress bytes changed")
        #expect(subject.run())
        #expect(MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
    }

    @Test func wallPlaintextPhotoAndThumbnailAreSealedInPlace() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wallKey = SymmetricKey(size: .bits256)
        let photoBytes = jpeg()
        let thumbnailBytes = jpeg(width: 32, height: 32)
        let photoURL = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let thumbnailURL = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.thumbnailsDirectoryName, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try photoBytes.write(to: photoURL)
        try thumbnailBytes.write(to: thumbnailURL)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()

        #expect(result.convertedPlaintext == 2)
        #expect(openCurrentFormat(
            photoURL, under: wallKey, purpose: FernletCryptoPurpose.AEAD.privateFriendPhotoImageV2
        ) == photoBytes)
        #expect(openCurrentFormat(
            thumbnailURL, under: wallKey, purpose: FernletCryptoPurpose.AEAD.privateFriendPhotoThumbnailV2
        ) == thumbnailBytes)
    }

    // MARK: - 8: the excluded plaintext wall index

    @Test func wallLegacyPlaintextIndexIsNeverTouchedAndNeverBlocks() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The exclusion is structural: the resealable set names ONLY the sealed index.
        #expect(FriendWallCorpusLayout.resealableLocations(in: wallRoot).files
                == [wallRoot.appendingPathComponent(FriendWallCorpusLayout.sealedIndexFileName)])

        let wallKey = SymmetricKey(size: .bits256)
        let indexURL = wallRoot.appendingPathComponent(FriendWallCorpusLayout.legacyPlaintextIndexFileName)
        let indexBytes = Data("[]".utf8)
        try indexBytes.write(to: indexURL)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.examined == 0, "the plaintext index was enumerated by a never-delete migrator")
        #expect(subject.run())
        #expect(MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete,
                "the excluded plaintext index held the latch open")
        #expect((try? Data(contentsOf: indexURL)) == indexBytes, "the excluded plaintext index was rewritten")

        // The shipped migration path is undisturbed: a wall load still seals and retires it.
        let store = PrivateMediaStore(
            indexURL: indexURL,
            keyProvider: InMemoryPrivateMediaKeyProvider(key: wallKey)
        )
        #expect(store.loadIndex() == PrivateMediaStore.IndexLoad.entries([]))
        #expect(FileManager.default.fileExists(
            atPath: wallRoot.appendingPathComponent(FriendWallCorpusLayout.sealedIndexFileName).path
        ), "loadIndex did not write the sealed index")
        #expect(!FileManager.default.fileExists(atPath: indexURL.path),
                "loadIndex did not retire the plaintext index")
    }

    // MARK: - 9/10/10b: division of labor with the key migrator

    @Test func ownRootCandidatesDeferWhileKeyMigrationLatchIsUnset() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let wallKey = SymmetricKey(size: .bits256)
        let ownPlaintext = jpeg()
        let ownFile = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let ownLegacyBytes = try legacySealed(ownPlaintext, under: ownKey)
        try ownLegacyBytes.write(to: ownFile)
        let wallFile = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try legacySealed(jpeg(), under: wallKey).write(to: wallFile)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults,
            ownKeyMigrationComplete: false
        )
        let result = subject.performPass()

        #expect(result.converted == 1, "the wall must convert even while the own root defers")
        #expect(result.deferredOwnKeyMigrationIncomplete == 1)
        #expect(!result.isClean)
        #expect((try? Data(contentsOf: ownFile)) == ownLegacyBytes,
                "a deferred own file was touched — this may be the key migrator's file")
        #expect(!subject.run())
        #expect(!MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete,
                "the format latch opened over a corpus the key latch has not proven")

        // Resumability: once the key pass reports complete, the same migrator finishes the job.
        OwnPhotoMigrationLatch(defaults: defaults).markComplete()
        #expect(subject.run())
        #expect(MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
        #expect(openCurrentFormat(ownFile, under: ownKey, purpose: FernletCryptoPurpose.AEAD.mealPhotoV2)
                == ownPlaintext)
    }

    @Test func aFriendKeySealedOwnFileBlocksTheLatchAndIsLeftForTheKeyMigrator() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let wallKey = SymmetricKey(size: .bits256)
        let plaintext = jpeg()
        let straggler = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let stragglerBytes = try legacySealed(plaintext, under: wallKey)
        try stragglerBytes.write(to: straggler)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()

        // NOT `unopenableUnprefixed`: the wall-key probe finds it — the loud should-not-exist
        // state the key latch's proof has a hole for. It must hold Phase 3 back, because this
        // file still needs the dual-open path the branch delete would kill.
        #expect(result.legacyKeySealedOwnFile == 1)
        #expect(result.unopenableUnprefixed == 0)
        #expect(!result.isClean)
        #expect(!subject.run())
        #expect(!MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
        #expect((try? Data(contentsOf: straggler)) == stragglerBytes,
                "the format migrator converted a friend-key file — that is the KEY migrator's job")

        // Division of labor, proven by composition: the key migrator converts it (emitting the
        // current format), and the next format pass is clean.
        let keyMigrator = OwnPhotoKeyMigrator(
            locations: OwnPhotoCorpusLayout.sealedLocations(in: ownRoot),
            ownKeyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKeyProvider: InMemoryPrivateMediaKeyProvider(key: wallKey),
            latch: OwnPhotoMigrationLatch(defaults: defaults)
        )
        #expect(keyMigrator.performPass().resealed == 1)
        let confirming = subject.performPass()
        #expect(confirming.isClean)
        #expect(confirming.alreadyCurrentFormat == 1)
        #expect(openCurrentFormat(straggler, under: ownKey, purpose: FernletCryptoPurpose.AEAD.mealPhotoV2)
                == plaintext)
    }

    @Test func ownRootUnopenableCandidatesWithNoWallKeyAreIndeterminate() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let wallKey = SymmetricKey(size: .bits256)
        let straggler = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try legacySealed(jpeg(), under: wallKey).write(to: straggler)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: NoMediaKeyProvider(),
            defaults: defaults
        )
        let result = subject.performPass()

        // `OwnPhotoKeyMigration`'s posture, pinned here: a verdict reached while a key was
        // unavailable is no verdict. And the diagnostic probe must NOT read as a wall-root abort.
        #expect(result.indeterminate == 1)
        #expect(result.unopenableUnprefixed == 0)
        #expect(!result.abortedNoWallKey,
                "the own root's diagnostic wall-key probe set the WALL root's abort flag")
        #expect(!result.isClean)
        #expect(!subject.run())
        #expect(!MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
    }

    // MARK: - 10c: the index-file compare-before-write guard

    @Test func indexFileRewrittenBetweenReadAndWriteIsSkippedNotClobbered() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wallKey = SymmetricKey(size: .bits256)
        let indexURL = wallRoot.appendingPathComponent(FriendWallCorpusLayout.sealedIndexFileName)
        try legacySealed(Data("[]".utf8), under: wallKey).write(to: indexURL)
        // The concurrent store's newer commit — a current-format sealed index the migrator's
        // stale snapshot must never write over.
        let storeCommit = try currentFormatSealed(
            Data(#"[{"newer":true}]"#.utf8),
            under: wallKey,
            purpose: FernletCryptoPurpose.AEAD.privateFriendPhotoIndexV2
        )
        // Deterministic stand-in for the concurrent save: the provider rewrites the index from
        // its THIRD key access on — after the pass's probe (1) and legacy open (2), i.e. inside
        // the convert's own seal — so the pre-write guard is what has to catch it.
        let provider = RewritingOnKeyAccessProvider(
            key: wallKey, target: indexURL, replacement: storeCommit, rewriteAfterAccessCount: 2
        )

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: provider,
            defaults: defaults
        )
        let result = subject.performPass()

        #expect(result.skippedConcurrentlyModified == 1)
        #expect(result.converted == 0)
        // "Closed THIS pass" is the pin — the raced pass itself may not latch. (A later run over
        // the store's committed current-format bytes legitimately comes back clean and latches;
        // that is the race resolving, not the guard failing.)
        #expect(!result.isClean, "a raced index must hold the latch closed for this pass")
        #expect((try? Data(contentsOf: indexURL)) == storeCommit,
                "the migrator clobbered the store's newer index with its stale snapshot")

        // A fresh pass over the (now current-format) file is clean.
        let fresh = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let confirming = fresh.performPass()
        #expect(confirming.isClean)
        #expect(confirming.alreadyCurrentFormat == 1)
    }

    // MARK: - 11: could-not-look blocks

    @Test func unreadableBytesBlockTheLatch() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wallKey = SymmetricKey(size: .bits256)
        let url = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try legacySealed(jpeg(), under: wallKey).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }
        // Portability: a process that can read a mode-000 file anyway (running as root) cannot
        // produce the condition under test — nothing to assert rather than something to fail.
        guard (try? Data(contentsOf: url)) == nil else { return }

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.indeterminate == 1, "unreadable bytes must be a blind spot, never a verdict")
        #expect(!result.isClean)
        #expect(!subject.run())
        #expect(!MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
    }

    @Test func unlistableDirectoryBlocksTheLatch() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
        try legacySealed(jpeg(), under: ownKey)
            .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mealDirectory.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mealDirectory.path) }
        guard (try? FileManager.default.contentsOfDirectory(
            at: mealDirectory, includingPropertiesForKeys: nil
        )) == nil else { return }

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.indeterminate == 1, "an unlistable directory hides an unknown count and must block")
        #expect(result.examined == 0)
        #expect(!result.isClean)
        #expect(!subject.run())
        #expect(!MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
    }

    // MARK: - 12: the non-blocking residues, argued and pinned

    @Test func garbageAndEmptyAndTruncatedMarkedFilesDoNotBlock() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let wallKey = SymmetricKey(size: .bits256)
        let wallPhotos = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
        // Random non-image bytes (wall root, so no own-latch interplay), a zero-byte file, and
        // a marked box with a garbage tail — which is `alreadyCurrentFormat` by the
        // marker-bytes-only contract (a corrupt FMA2 box already reads as nil everywhere).
        let garbage = Data((0..<64).map { UInt8(truncatingIfNeeded: $0) })
        let garbageURL = wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg")
        try garbage.write(to: garbageURL)
        let emptyURL = wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg")
        try Data().write(to: emptyURL)
        let truncatedMarked = Data("FMA2".utf8) + Data([0xde, 0xad])
        let truncatedURL = wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg")
        try truncatedMarked.write(to: truncatedURL)
        // The §4 documented limitation: a parseable NON-JPEG plaintext image in the meal corpus
        // is census-unprefixed, so the migrator must score it unopenable and leave it — convert
        // eligibility must never exceed the shared census sniff.
        let pngBytes = png()
        let pngID = UUID()
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
        let pngURL = mealDirectory.appendingPathComponent("\(pngID.uuidString).jpg")
        try pngBytes.write(to: pngURL)

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()

        #expect(result.unopenableUnprefixed == 2, "the garbage bytes and the PNG — read, and no key opens them")
        #expect(result.empty == 1)
        #expect(result.alreadyCurrentFormat == 1)
        #expect(result.examined == 4)
        #expect(result.isClean, "bytes proven unreachable through the legacy branch must not block")
        #expect((try? Data(contentsOf: garbageURL)) == garbage)
        #expect((try? Data(contentsOf: truncatedURL)) == truncatedMarked)
        #expect((try? Data(contentsOf: pngURL)) == pngBytes, "the PNG must drain organically, never here")

        // The organic drain path is undisturbed: the meal store still serves the PNG and
        // re-seals it in place on access.
        let store = MealPhotoStore(directory: mealDirectory, keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey))
        #expect(store.imageData(for: pngID) == pngBytes)
        let resealed = try #require(try? Data(contentsOf: pngURL))
        #expect(resealed.starts(with: Data("FMA2".utf8)), "the store's upgrade-on-access re-seal did not fire")
    }

    // MARK: - 13: missing keys and the empty sweep

    @Test func missingKeyWithCandidatesPresentAbortsWithoutLatching() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let key = SymmetricKey(size: .bits256)
        let ownFile = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        let ownBytes = try legacySealed(jpeg(), under: key)
        try ownBytes.write(to: ownFile)

        let ownAborted = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: NoMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: key),
            defaults: defaults
        )
        let ownResult = ownAborted.performPass()
        #expect(ownResult.abortedNoOwnKey)
        #expect(!ownResult.isClean)
        #expect(!ownAborted.run())
        #expect((try? Data(contentsOf: ownFile)) == ownBytes)

        // And the wall's mirror image.
        try FileManager.default.removeItem(at: ownFile)
        let wallFile = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try legacySealed(jpeg(), under: key).write(to: wallFile)
        let wallAborted = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: key),
            wallKey: NoMediaKeyProvider(),
            defaults: defaults
        )
        let wallResult = wallAborted.performPass()
        #expect(wallResult.abortedNoWallKey)
        #expect(!wallResult.isClean)
        #expect(!wallAborted.run())
        #expect(!MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
    }

    @Test func emptySweepNeverTouchesAKeyProvider() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownTrap = KeychainTouchTrap()
        let wallTrap = KeychainTouchTrap()
        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: ownTrap, wallKey: wallTrap,
            defaults: defaults
        )
        #expect(subject.run(), "an empty sweep is provably clean and must latch")
        #expect(MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
        #expect(!ownTrap.touched && !wallTrap.touched,
                "a sweep with zero convert candidates touched the keychain")
    }

    // MARK: - 14: a failed rewrite never harms the source

    @Test func failedRewriteBlocksTheLatchAndLeavesTheSourceIntact() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let wallKey = SymmetricKey(size: .bits256)
        let wallPhotos = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
        let url = wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg")
        let legacyBytes = try legacySealed(jpeg(), under: wallKey)
        try legacyBytes.write(to: url)
        // Read-only directory: the atomic re-seal cannot land, but listing and reading still work.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: wallPhotos.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wallPhotos.path) }
        // Portability: a process that can write into a 555 directory anyway (root) cannot
        // produce the condition under test.
        let canary = wallPhotos.appendingPathComponent("canary.tmp")
        if (try? Data("x".utf8).write(to: canary)) != nil {
            try? FileManager.default.removeItem(at: canary)
            return
        }

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.conversionFailures == 1)
        #expect(!result.isClean)
        #expect((try? Data(contentsOf: url)) == legacyBytes,
                "a failed rewrite deleted or corrupted the source bytes")
        #expect(!subject.run())
        #expect(!MediaAtRestFormatMigrationLatch(defaults: defaults).isComplete)
    }

    // MARK: - 15: read-path-level read-back through the owning stores

    @Test func convertedIndexesStillOpenThroughTheirOwningStores() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let ownKey = SymmetricKey(size: .bits256)
        let wallKey = SymmetricKey(size: .bits256)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        let record = ProgressPhotoRecord(
            id: UUID(),
            capturedAt: Date(timeIntervalSince1970: 1_756_000_000),
            caption: "week one"
        )
        let progressRoot = OwnPhotoCorpusLayout.progressPhotosDirectory(in: ownRoot)
        try legacySealed(try encoder.encode([record]), under: ownKey)
            .write(to: progressRoot.appendingPathComponent(OwnPhotoCorpusLayout.progressIndexFileName))

        // Byte-less on disk, exactly as the store's own index writer strips it.
        let payload = FriendPhotoPayload(
            id: UUID(),
            imageData: jpeg(),
            addedAt: Date(timeIntervalSince1970: 1_756_000_100),
            senderName: "Wall",
            senderFingerprint: "fp",
            senderSigningPublicKey: Data([0x01]),
            session: nil
        ).withoutImageData()
        try legacySealed(try encoder.encode([payload]), under: wallKey)
            .write(to: wallRoot.appendingPathComponent(FriendWallCorpusLayout.sealedIndexFileName))

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(key: ownKey),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        #expect(subject.run())

        // Stronger than raw gcmOpen: the owning stores decode the converted indexes.
        let progressStore = ProgressPhotoStore(
            directory: progressRoot,
            keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey)
        )
        #expect(progressStore.records().map(\.id) == [record.id],
                "the converted progress index does not decode through its owning store")

        let wallStore = PrivateMediaStore(
            indexURL: wallRoot.appendingPathComponent(FriendWallCorpusLayout.legacyPlaintextIndexFileName),
            keyProvider: InMemoryPrivateMediaKeyProvider(key: wallKey)
        )
        guard case .entries(let photos) = wallStore.loadIndex() else {
            Issue.record("the converted wall index did not load as entries")
            return
        }
        #expect(photos.map(\.id) == [payload.id])
    }

    // MARK: - 17: the shared classifier

    @Test func classifierAgreesWithTheCensusByConstruction() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }

        // The extracted header rule answers for bytes exactly as the census's file rule does.
        let wallKey = SymmetricKey(size: .bits256)
        #expect(MediaAtRestFormatCensus.format(ofHeader: Data()) == .empty)
        #expect(MediaAtRestFormatCensus.format(ofHeader: Data("FMA2".utf8) + Data([0x00])) == .v2Marked)
        #expect(MediaAtRestFormatCensus.format(ofHeader: Data("FMA1".utf8)) == .unprefixedLegacyOrUnrecognized)
        #expect(MediaAtRestFormatCensus.format(ofHeader: jpeg()) == .plaintextJPEG)
        #expect(MediaAtRestFormatCensus.format(ofHeader: try legacySealed(jpeg(), under: wallKey))
                == .unprefixedLegacyOrUnrecognized)

        // One file of each census class in the wall root; the census's counts and the
        // migrator's buckets are the documented mapping of the SAME classifier.
        let wallPhotos = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
        try currentFormatSealed(jpeg(), under: wallKey, purpose: FernletCryptoPurpose.AEAD.privateFriendPhotoImageV2)
            .write(to: wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg"))
        try legacySealed(jpeg(), under: wallKey)
            .write(to: wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg"))
        try jpeg().write(to: wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg"))
        try Data().write(to: wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg"))

        let census = MediaAtRestFormatCensus(
            locationSets: [FriendWallCorpusLayout.resealableLocations(in: wallRoot)]
        ).run()
        #expect(census.total == MediaAtRestFormatTally(
            v2Marked: 1, plaintextJPEG: 1, unprefixedLegacyOrUnrecognized: 1, empty: 1
        ))

        let subject = makeMigrator(
            ownRoot: ownRoot, wallRoot: wallRoot,
            ownKey: InMemoryPrivateMediaKeyProvider(),
            wallKey: InMemoryPrivateMediaKeyProvider(key: wallKey),
            defaults: defaults
        )
        let result = subject.performPass()
        #expect(result.examined == census.total.examined)
        #expect(result.alreadyCurrentFormat == census.total.v2Marked)
        #expect(result.empty == census.total.empty)
        #expect(result.converted == census.total.unprefixedLegacyOrUnrecognized,
                "every census-legacy blob the key opens converts")
        #expect(result.convertedPlaintext == census.total.plaintextJPEG,
                "every census-plaintext JPEG in an eligible location converts")
    }
}

/// A provider that must never be asked for a key. Records the touch (failing the test's
/// assertion) rather than crashing the whole suite the way a `fatalError` trap would.
private final class KeychainTouchTrap: PrivateMediaKeyProviding {
    private(set) var touched = false
    func mediaKey() -> SymmetricKey? {
        touched = true
        return nil
    }
}

/// Deterministic stand-in for a concurrent store save racing the migrator: from its Nth key
/// access on, every `mediaKey()` call rewrites the target file with the "store's" newer bytes —
/// `gcmSeal`/`gcmOpen` reach the key through `mediaKey()`, so the rewrite fires inside the
/// convert step, after the migrator's convert-time read and before its write.
private final class RewritingOnKeyAccessProvider: PrivateMediaKeyProviding {
    private let key: SymmetricKey
    private let target: URL
    private let replacement: Data
    private let rewriteAfterAccessCount: Int
    private var accessCount = 0

    init(key: SymmetricKey, target: URL, replacement: Data, rewriteAfterAccessCount: Int) {
        self.key = key
        self.target = target
        self.replacement = replacement
        self.rewriteAfterAccessCount = rewriteAfterAccessCount
    }

    func mediaKey() -> SymmetricKey? {
        accessCount += 1
        if accessCount > rewriteAfterAccessCount {
            try? replacement.write(to: target)
        }
        return key
    }
}
