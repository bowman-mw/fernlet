import CryptoKit
import Foundation
import Testing
import UIKit
import FernletDomainModel
import PrivateMediaStore

/// Phase 0 of the crypto-standardization plan (`Docs/Plan-Crypto-Standardization-2026-08-27.md`)
/// for the media at-rest surface: ``MediaAtRestFormatCensus`` must be able to *count* the two
/// on-disk generations before anything may be deleted.
///
/// What this suite defends is the trustworthiness of a NUMBER that will later license removing the
/// legacy reader. Three ways it could lie, all pinned below:
///
/// 1. **Miscounting a generation.** Fixtures are byte-exact: the current-format file is written by
///    a real production store (`MealPhotoStore`/`PrivateMediaStore`), the legacy file is a bare
///    combined GCM box with no prefix — the exact shape the pre-domain-separation build wrote —
///    and the plaintext file is a real JPEG. A near-miss prefix (`FMA` + one wrong byte) proves the
///    marker test is the whole four bytes, not a hopeful prefix.
/// 2. **Reporting a confident zero it did not earn.** A missing path is zero (nothing is hidden by
///    a path that does not exist); an unlistable directory and a capped sweep are BLIND SPOTS, and
///    ``MediaAtRestFormatTally/hasBlindSpots`` must say so — that flag is what stops a locked
///    device's silence from reading as "no legacy blobs left".
/// 3. **Not being read-only.** A census that rewrote or created anything would be a migration
///    nobody reviewed. Every seeded byte and every path is snapshotted before and after a pass.
///
/// Fixture discipline: UUID-fresh temp roots per test (never a shared container root — see
/// `PhotoDirectoryIsolationTests`), no `FernletStore`, and no keychain anywhere: the census takes no
/// key provider, and the two stores used as writers take in-memory ones.
@MainActor
struct MediaAtRestFormatCensusTests {

    // MARK: - Fixtures

    /// A real JPEG, so the plaintext-generation fixture carries genuine `FF D8 FF` bytes and the
    /// production writers have something they will actually accept.
    private func jpeg(width: Int = 64, height: Int = 64) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        return renderer.image { context in
            UIColor.systemTeal.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }.jpegData(compressionQuality: 0.7)!
    }

    /// A byte-exact PRE-domain-separation box: combined (nonce + ciphertext + tag) with no marker,
    /// which is what the legacy writers put on disk and what the reader's `legacy-read` branch
    /// still opens.
    private func legacySealed(_ plaintext: Data, under key: SymmetricKey) throws -> Data {
        try #require(try AES.GCM.seal(plaintext, using: key).combined)
    }

    /// A current-format box, with the marker spelled out here rather than read from the module.
    ///
    /// Deliberate, and the same choice `OwnPhotoKeyMigrationTests.opens` makes: this suite asserts
    /// the at-rest FORMAT, and a fixture that asked production what the format is could never
    /// notice production changing it. Where a fixture must prove agreement with what the app really
    /// writes, it uses a production store instead (see ``currentFormatComesFromARealStoreWrite``).
    private func currentFormatSealed(_ plaintext: Data, under key: SymmetricKey) throws -> Data {
        try Data("FMA2".utf8) + legacySealed(plaintext, under: key)
    }

    /// A temp stand-in for the app's Documents directory with the own-photo corpora created.
    private func makeOwnRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaAtRestFormatCensusTests-own-\(UUID().uuidString)", isDirectory: true)
        for directory in OwnPhotoCorpusLayout.sealedLocations(in: root).directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    /// A temp stand-in for the app's per-host proximity support directory (the OTHER root — the
    /// friend wall lives outside Documents), with the wall's two photo directories created.
    private func makeWallRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaAtRestFormatCensusTests-wall-\(UUID().uuidString)", isDirectory: true)
        for directory in FriendWallCorpusLayout.sealedLocations(in: root).directories {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return root
    }

    /// Every path under `root` (directories included) plus the full bytes of every regular file —
    /// the read-only proof's before/after snapshot.
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

    // MARK: - The four generations, counted exactly

    /// One directory holding one of everything the reader can meet: a file a real production store
    /// wrote, a byte-exact legacy box, a pre-sealing plaintext JPEG, and a zero-byte file. Each
    /// lands in its own bucket, `examined` is their sum, and nothing is a blind spot.
    @Test func countsEveryGenerationTheReaderKnows() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
        let legacyKey = SymmetricKey(size: .bits256)

        // The current-format file is written by the real store, not hand-assembled: this is the
        // half that proves the census classifies what production ACTUALLY writes today.
        let writer = MealPhotoStore(directory: mealDirectory, keyProvider: InMemoryPrivateMediaKeyProvider())
        _ = try #require(writer.save(jpeg()), "the production writer must have produced a sealed file")
        try legacySealed(jpeg(), under: legacyKey)
            .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try jpeg().write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try Data().write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))

        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)]
        ).run()

        let meal = try #require(report.tally(for: mealDirectory))
        #expect(meal.v2Marked == 1)
        #expect(meal.plaintextJPEG == 1)
        #expect(meal.unprefixedLegacyOrUnrecognized == 1)
        #expect(meal.empty == 1)
        #expect(meal.indeterminate == 0)
        #expect(meal.examined == 4)
        #expect(!meal.hasBlindSpots, "every file was read; nothing here is unknown")
        // The other own corpora exist and are empty, so the fold is the meal tally.
        #expect(report.total == meal)
        // The per-class accessor a diagnostic row renders must agree with the fields.
        #expect(MediaAtRestFormatClass.allCases.map(meal.count(of:)).reduce(0, +) == meal.examined)
    }

    /// The marker test is all four bytes. `FMA` + one wrong byte is NOT the current format — it is
    /// indistinguishable from a legacy nonce, and must be counted as one.
    @Test func nearMissMarkerIsNotCountedAsCurrentFormat() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let recipeDirectory = OwnPhotoCorpusLayout.recipePhotosDirectory(in: root)
        let nearMiss = try Data("FMA1".utf8) + legacySealed(jpeg(), under: SymmetricKey(size: .bits256))
        try nearMiss.write(to: recipeDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))

        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)]
        ).run()

        let recipe = try #require(report.tally(for: recipeDirectory))
        #expect(recipe.v2Marked == 0, "a three-byte prefix match must not count as the current format")
        #expect(recipe.unprefixedLegacyOrUnrecognized == 1)
        #expect(recipe.examined == 1)
    }

    /// The friend-wall layout helper is a RESTATEMENT of literals private to `PrivateMediaStore`,
    /// so the one thing that can silently break it is the store putting its files somewhere else.
    /// Drive a real wall write and prove the census finds those bytes at the paths it sweeps.
    @Test func currentFormatComesFromARealStoreWrite() throws {
        let root = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let indexURL = root.appendingPathComponent(FriendWallCorpusLayout.legacyPlaintextIndexFileName)
        let store = PrivateMediaStore(indexURL: indexURL, keyProvider: InMemoryPrivateMediaKeyProvider())
        store.save([FriendPhotoPayload(imageData: jpeg(), senderName: "Alice")])

        let report = MediaAtRestFormatCensus(
            locationSets: [FriendWallCorpusLayout.sealedLocations(in: root)]
        ).run()

        let photos = try #require(report.tally(
            for: root.appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
        ))
        #expect(photos.v2Marked == 1, "the wall's photo bytes are not where the census sweeps")
        let index = try #require(report.tally(
            for: root.appendingPathComponent(FriendWallCorpusLayout.sealedIndexFileName)
        ))
        #expect(index.v2Marked == 1, "the sealed index is not where the census sweeps")
        // The thumbnail is a best-effort write (ImageIO may decline a given source), so its COUNT
        // is not pinned — but whatever landed there must be the current format, never legacy.
        let thumbnails = try #require(report.tally(
            for: root.appendingPathComponent(FriendWallCorpusLayout.thumbnailsDirectoryName, isDirectory: true)
        ))
        #expect(thumbnails.v2Marked == thumbnails.examined)
        #expect(!report.total.hasBlindSpots)
    }

    // MARK: - Two roots, seven locations

    /// Own photos live under Documents and the friend wall lives under the proximity support
    /// directory — different roots with different key custody. One pass covers both, and every
    /// count is attributed to the location it came from rather than smeared across a grand total.
    @Test func sweepsBothRootsAndAttributesPerLocation() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let key = SymmetricKey(size: .bits256)

        let progressRoot = OwnPhotoCorpusLayout.progressPhotosDirectory(in: ownRoot)
        let progressPhotos = progressRoot
            .appendingPathComponent(OwnPhotoCorpusLayout.progressPhotosInnerDirectoryName, isDirectory: true)
        let progressIndex = progressRoot.appendingPathComponent(OwnPhotoCorpusLayout.progressIndexFileName)
        try currentFormatSealed(jpeg(), under: key)
            .write(to: progressPhotos.appendingPathComponent("\(UUID().uuidString).jpg"))
        try currentFormatSealed(Data("[]".utf8), under: key).write(to: progressIndex)

        let wallPhotos = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
        let wallThumbnails = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.thumbnailsDirectoryName, isDirectory: true)
        let wallLegacyIndex = wallRoot
            .appendingPathComponent(FriendWallCorpusLayout.legacyPlaintextIndexFileName)
        try legacySealed(jpeg(), under: key)
            .write(to: wallPhotos.appendingPathComponent("\(UUID().uuidString).jpg"))
        try currentFormatSealed(jpeg(), under: key)
            .write(to: wallThumbnails.appendingPathComponent("\(UUID().uuidString).jpg"))
        // A device that never re-opened its wall still has the pre-sealing PLAINTEXT index. It is
        // swept like everything else and the bucket speaks: JSON is neither the marker nor a JPEG.
        try Data("[]".utf8).write(to: wallLegacyIndex)

        let report = MediaAtRestFormatCensus(
            ownPhotoDocumentsDirectory: ownRoot,
            friendWallSupportDirectory: wallRoot
        ).run()

        // Four own-photo locations (meal, recipe, progress bytes, progress index) plus four wall
        // ones (photos, thumbnails, the sealed index, and the pre-sealing plaintext index).
        #expect(report.locations.count == 8)
        let progressBytesTally = try #require(report.tally(for: progressPhotos))
        #expect(progressBytesTally.v2Marked == 1)
        let progressIndexTally = try #require(report.tally(for: progressIndex))
        #expect(progressIndexTally.v2Marked == 1)
        let wallPhotosTally = try #require(report.tally(for: wallPhotos))
        #expect(wallPhotosTally.unprefixedLegacyOrUnrecognized == 1)
        let wallThumbnailsTally = try #require(report.tally(for: wallThumbnails))
        #expect(wallThumbnailsTally.v2Marked == 1)
        let wallLegacyIndexTally = try #require(report.tally(for: wallLegacyIndex))
        #expect(wallLegacyIndexTally.unprefixedLegacyOrUnrecognized == 1)
        // The corpora that were left empty must not borrow anyone else's numbers.
        let mealTally = try #require(report.tally(for: OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)))
        #expect(mealTally == .zero)
        let wallSealedIndexTally = try #require(report.tally(
            for: wallRoot.appendingPathComponent(FriendWallCorpusLayout.sealedIndexFileName)
        ))
        #expect(wallSealedIndexTally == .zero)
        #expect(report.total == MediaAtRestFormatTally(v2Marked: 3, unprefixedLegacyOrUnrecognized: 2))
        #expect(!report.total.hasBlindSpots)
    }

    // MARK: - The fail-closed directions

    /// A path that does not exist hides nothing, so it is an honest zero — NOT a blind spot. A
    /// fresh install must be able to report "no legacy blobs" and mean it.
    ///
    /// It must ALSO be able to say which of the two all-zero readings it is. Absent locations and
    /// swept-empty ones produce identical tallies, so `existed` is the only thing separating "this
    /// corpus holds no legacy blobs" from "there is no corpus here" — and an all-absent sweep is
    /// the shape a census pointed at the wrong roots takes.
    @Test func missingLocationsAreZeroNotBlindSpots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaAtRestFormatCensusTests-absent-\(UUID().uuidString)", isDirectory: true)
        // Deliberately NOT created — no directory, no file, nothing on disk at all.
        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)]
        ).run()

        #expect(report.locations.count == 4)
        #expect(report.locations.allSatisfy { $0.tally == .zero })
        #expect(report.total == .zero)
        #expect(!report.total.hasBlindSpots)
        #expect(report.locations.allSatisfy { !$0.existed }, "not one of these paths is on disk")
        #expect(report.absentLocationCount == 4)
        #expect(report.allLocationsAbsent, "a sweep that found no location at all must say so")
        #expect(!FileManager.default.fileExists(atPath: root.path), "the census created a root that was not there")
    }

    /// The other side of `existed`: a corpus that IS there and holds nothing reports the same
    /// zeros, and must be distinguishable from the test above. Without this pair, `existed` could be
    /// hard-coded either way and both tests would still pass on their own.
    @Test func aSweptEmptyCorpusIsNotAnAbsentOne() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // `makeOwnRoot` creates the three photo DIRECTORIES; the progress index FILE is not written.
        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)]
        ).run()

        #expect(report.total == .zero, "the same all-zero tally as an absent sweep")
        #expect(!report.allLocationsAbsent, "these corpora exist — they are empty, which is evidence")
        #expect(report.absentLocationCount == 1, "only the progress index is missing")
        for location in report.locations where location.kind == .directory {
            #expect(location.existed, "\(location.url.lastPathComponent) was created by the fixture")
        }
    }

    /// A listing entry that is positively NOT a regular file — a subdirectory, a fifo, a dangling
    /// symlink — was never a media blob and is skipped, consuming no part of the per-directory
    /// budget. (Verified against the simulator filesystem: `URLResourceValues` reports all three as
    /// a clean `isRegularFile == false`, no error.)
    @Test func nonRegularEntriesAreSkippedRatherThanCounted() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
        try legacySealed(jpeg(), under: SymmetricKey(size: .bits256))
            .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try FileManager.default.createDirectory(
            at: mealDirectory.appendingPathComponent("nested", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            atPath: mealDirectory.appendingPathComponent("dangling.jpg").path,
            withDestinationPath: mealDirectory.appendingPathComponent("gone.jpg").path
        )

        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)]
        ).run()

        let meal = try #require(report.tally(for: mealDirectory))
        #expect(meal.examined == 1, "only the one regular file is a media blob")
        #expect(meal.unprefixedLegacyOrUnrecognized == 1)
        #expect(meal.indeterminate == 0, "a positive 'not a regular file' is a skip, not a blind spot")
        #expect(!meal.hasBlindSpots)
    }

    /// THE SILENT-DROP PIN. When the filesystem cannot say what an entry IS, the entry is examined
    /// as indeterminate — never dropped. Dropping it removes a file that is demonstrably on disk
    /// from every bucket including `examined`, which is a silent subtraction from the corpus the
    /// Phase 3 gate counts: the pass would report having swept N files when it swept N + k.
    ///
    /// Driven through ``MediaAtRestFormatCensus/format(ofListedEntry:isRegularFile:)`` rather than a
    /// planted file, and that is not a shortcut: `contentsOfDirectory(at:includingPropertiesForKeys:)`
    /// PREFETCHES the requested keys onto the URLs it returns, so within the census's own listing
    /// the resource-value read is served from that cache and does not fail. Every FS fixture tried
    /// (dangling symlink, symlink loop, fifo, subdirectory) reports a clean `false` instead, and a
    /// directory with read-but-no-search permission fails the LISTING — which is already pinned as
    /// `unlistableDirectoryIsABlindSpot`. So the seam is where the failure is constructible.
    @Test func anEntryWhoseTypeCannotBeReadIsExaminedAsIndeterminate() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
            .appendingPathComponent("\(UUID().uuidString).jpg")
        try legacySealed(jpeg(), under: SymmetricKey(size: .bits256)).write(to: file)

        // The read FAILED: nothing is known about a file that is provably listed. Fail-closed.
        #expect(
            MediaAtRestFormatCensus.format(ofListedEntry: file, isRegularFile: nil)
                == MediaAtRestFormatClass.indeterminate
        )
        // The read SUCCEEDED and said "not a regular file": skip, and say so with nil.
        #expect(MediaAtRestFormatCensus.format(ofListedEntry: file, isRegularFile: false) == nil)
        // The read succeeded and said "regular file": classify by bytes, as ever.
        #expect(
            MediaAtRestFormatCensus.format(ofListedEntry: file, isRegularFile: true)
                == MediaAtRestFormatClass.unprefixedLegacyOrUnrecognized
        )
        // And an indeterminate entry is a BLIND SPOT once it lands in a tally — the whole reason it
        // must not be dropped, since a dropped file leaves `hasBlindSpots` false.
        #expect(MediaAtRestFormatTally(indeterminate: 1).hasBlindSpots)
        #expect(MediaAtRestFormatTally(indeterminate: 1).examined == 1)
    }

    /// A directory that EXISTS but will not enumerate is the opposite case: it hides an unknown
    /// number of files, so it is counted as a blind spot and never as "nothing to migrate".
    @Test func unlistableDirectoryIsABlindSpot() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
        try legacySealed(jpeg(), under: SymmetricKey(size: .bits256))
            .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: mealDirectory.path)
        // Restore before the root is removed (defers unwind last-in-first-out), or the cleanup
        // cannot recurse into it.
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: mealDirectory.path) }

        // Portability: a process that can read a mode-000 directory anyway (running as root) cannot
        // produce the condition under test, so there is nothing to assert rather than something to
        // fail. The census's own listing failure is what the assertions below are about.
        guard (try? FileManager.default.contentsOfDirectory(
            at: mealDirectory,
            includingPropertiesForKeys: nil
        )) == nil else { return }

        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)]
        ).run()

        let meal = try #require(report.tally(for: mealDirectory))
        #expect(meal.unlistableDirectories == 1)
        #expect(meal.examined == 0, "no file was classified — the hidden count is unknown, not zero")
        #expect(meal.hasBlindSpots)
        #expect(report.total.hasBlindSpots, "one unlistable corpus makes the whole pass unproven")
    }

    /// The per-directory cap is a bound, and hitting it is REPORTED rather than absorbed: the
    /// counts become lower bounds, so the pass is a blind spot too.
    @Test func capStopsTheSweepAndSaysSo() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
        let key = SymmetricKey(size: .bits256)
        for _ in 0..<3 {
            try legacySealed(jpeg(), under: key)
                .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        }

        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)],
            maxFilesPerDirectory: 2
        ).run()

        let meal = try #require(report.tally(for: mealDirectory))
        #expect(meal.truncated)
        #expect(meal.examined == 2)
        #expect(meal.unprefixedLegacyOrUnrecognized == 2, "a capped count is a lower bound, not a total")
        #expect(meal.hasBlindSpots)
    }

    /// A cap below one would examine nothing and report a confident, wrong zero — the one answer
    /// this type must never give — so it is clamped at entry.
    @Test func nonPositiveCapIsClampedRatherThanCensusingNothing() throws {
        let root = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: root)
        try legacySealed(jpeg(), under: SymmetricKey(size: .bits256))
            .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))

        let report = MediaAtRestFormatCensus(
            locationSets: [OwnPhotoCorpusLayout.sealedLocations(in: root)],
            maxFilesPerDirectory: 0
        ).run()

        let meal = try #require(report.tally(for: mealDirectory))
        #expect(meal.examined == 1)
        #expect(meal.unprefixedLegacyOrUnrecognized == 1)
    }

    // MARK: - Read-only

    /// The census must not write, rewrite, create, or delete ANYTHING. Every path under both roots
    /// and every byte of every file is identical across a pass — and a second pass returns the
    /// same numbers, because a census that quietly migrated would count differently the second time.
    @Test func censusLeavesEveryByteAndPathUnchanged() throws {
        let ownRoot = try makeOwnRoot()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let wallRoot = try makeWallRoot()
        defer { try? FileManager.default.removeItem(at: wallRoot) }
        let key = SymmetricKey(size: .bits256)
        let mealDirectory = OwnPhotoCorpusLayout.mealPhotosDirectory(in: ownRoot)
        try currentFormatSealed(jpeg(), under: key)
            .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try legacySealed(jpeg(), under: key)
            .write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try jpeg().write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try Data().write(to: mealDirectory.appendingPathComponent("\(UUID().uuidString).jpg"))
        try legacySealed(jpeg(), under: key).write(
            to: wallRoot
                .appendingPathComponent(FriendWallCorpusLayout.photosDirectoryName, isDirectory: true)
                .appendingPathComponent("\(UUID().uuidString).jpg")
        )

        let ownBefore = try snapshot(of: ownRoot)
        let wallBefore = try snapshot(of: wallRoot)
        let census = MediaAtRestFormatCensus(
            ownPhotoDocumentsDirectory: ownRoot,
            friendWallSupportDirectory: wallRoot
        )

        let first = census.run()
        let ownAfter = try snapshot(of: ownRoot)
        let wallAfter = try snapshot(of: wallRoot)

        #expect(ownBefore.paths == ownAfter.paths, "the census changed what exists under Documents")
        #expect(ownBefore.files == ownAfter.files, "the census rewrote own-photo bytes")
        #expect(wallBefore.paths == wallAfter.paths, "the census changed what exists under the wall root")
        #expect(wallBefore.files == wallAfter.files, "the census rewrote friend-wall bytes")
        #expect(first.total == MediaAtRestFormatTally(
            v2Marked: 1,
            plaintextJPEG: 1,
            unprefixedLegacyOrUnrecognized: 2,
            empty: 1
        ))
        #expect(census.run() == first, "a second pass over an untouched corpus must count identically")
    }
}
