import Foundation
import UIKit
import Testing
import FernletDomainModel
import PrivateMediaStore

/// The friend photo-wall INDEX is sealed, not just the bytes it points at.
///
/// `MeshPhotoCache.json` used to sit in the clear beside GCM-sealed photos, carrying `senderName`,
/// `senderFingerprint` and `addedAt` for every photo on the wall — the wall the delete-all funnel
/// deliberately KEEPS, so the plaintext lived for the life of the install. It is now written sealed
/// as `MeshPhotoCache.sealed` under the same friend-wall media key as the bytes (not the user-lock
/// content key: the wall renders without an unlock and must keep doing so).
///
/// The index is also the store's file manifest — `save(_:)` deletes every photo file the index does
/// not name — so the read path has to distinguish "no photos" from "not readable right now". Both
/// halves are pinned here: the migration must not drop entries or their files, and an index that
/// cannot be opened must never be handed back as an empty wall that the next save writes over.
@MainActor
struct MeshPhotoCacheSealingTests {

    // MARK: - Fixtures

    /// A per-test directory: parallel suites share process-global disk roots, so nothing here may
    /// touch the app-support wall.
    private func makeDirectory() -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshPhotoCacheSealingTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The path a caller passes as `indexURL` — the LEGACY plaintext index.
    private func legacyIndexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("MeshPhotoCache.json")
    }

    /// The sealed index the store actually writes.
    private func sealedIndexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("MeshPhotoCache.sealed")
    }

    private func imageFileURL(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("MeshPhotos/\(id.uuidString).jpg")
    }

    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.5) ?? Data()
    }

    private func photo(named name: String, fingerprint: String, at addedAt: Date) -> FriendPhotoPayload {
        FriendPhotoPayload(
            id: UUID(),
            imageData: jpeg(width: 48, height: 48),
            addedAt: addedAt,
            senderName: name,
            senderFingerprint: fingerprint,
            senderSigningPublicKey: nil,
            session: nil
        )
    }

    /// Writes a pre-sealing plaintext index exactly as the old store did (ISO-8601 dates).
    private func writeLegacyIndex(_ photos: [FriendPhotoPayload], to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(photos.map { $0.withoutImageData() }).write(to: url)
    }

    // MARK: - Sealed at rest

    /// A saved index round-trips through the store while the on-disk bytes disclose neither the
    /// sender name nor the fingerprint, and the plaintext path is not written at all.
    @Test func indexIsSealedAtRestAndRoundTrips() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateMediaStore(
            indexURL: legacyIndexURL(in: directory),
            keyProvider: InMemoryPrivateMediaKeyProvider()
        )
        let saved = photo(named: "Alice", fingerprint: "fp-alice", at: Date())

        store.save([saved])

        #expect(!FileManager.default.fileExists(atPath: legacyIndexURL(in: directory).path),
                "the sealed store must not write the plaintext index path")
        let onDisk = try #require(try? Data(contentsOf: sealedIndexURL(in: directory)))
        #expect(onDisk.range(of: Data("Alice".utf8)) == nil, "sender name is in the clear in the index")
        #expect(onDisk.range(of: Data("fp-alice".utf8)) == nil, "sender fingerprint is in the clear in the index")
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode([FriendPhotoPayload].self, from: onDisk)
        }

        let loaded = try #require(store.load().first)
        #expect(loaded.id == saved.id)
        #expect(loaded.senderName == "Alice")
        #expect(loaded.senderFingerprint == "fp-alice")
        #expect(loaded.imageData == nil)
    }

    /// An install with no wall at all reads as an empty wall — the one case that genuinely is one.
    @Test func absentIndexReadsAsEmptyEntries() {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateMediaStore(
            indexURL: legacyIndexURL(in: directory),
            keyProvider: InMemoryPrivateMediaKeyProvider()
        )

        #expect(store.loadIndex() == .entries([]))
        #expect(store.load().isEmpty)
    }

    // MARK: - Migration off the plaintext index

    /// A pre-sealing plaintext index is resealed on first load, keeps every entry, and the
    /// plaintext original is gone afterwards.
    @Test func legacyPlaintextIndexMigratesAndThePlaintextFileIsDeleted() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = InMemoryPrivateMediaKeyProvider()
        let store = PrivateMediaStore(indexURL: legacyIndexURL(in: directory), keyProvider: provider)
        let older = photo(named: "Alice", fingerprint: "fp-alice", at: Date(timeIntervalSince1970: 1_000))
        let newer = photo(named: "Bruno", fingerprint: "fp-bruno", at: Date(timeIntervalSince1970: 2_000))
        try writeLegacyIndex([older, newer], to: legacyIndexURL(in: directory))

        let loaded = store.load()

        #expect(loaded.count == 2, "the migration dropped entries")
        #expect(loaded.map(\.senderName) == ["Bruno", "Alice"], "entries must come back newest first")
        #expect(!FileManager.default.fileExists(atPath: legacyIndexURL(in: directory).path),
                "the plaintext index survived the migration")
        let onDisk = try #require(try? Data(contentsOf: sealedIndexURL(in: directory)))
        #expect(onDisk.range(of: Data("Bruno".utf8)) == nil, "the migrated index is still plaintext")

        // And the sealed file — not the deleted plaintext one — is what a fresh store reads.
        let reopened = PrivateMediaStore(indexURL: legacyIndexURL(in: directory), keyProvider: provider)
        #expect(reopened.load().count == 2)
    }

    /// The migration must not sweep the photos it just re-indexed: the sealed bytes of every
    /// migrated entry stay on disk and readable.
    @Test func migrationKeepsTheSealedPhotoFiles() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = InMemoryPrivateMediaKeyProvider()
        let store = PrivateMediaStore(indexURL: legacyIndexURL(in: directory), keyProvider: provider)
        let kept = photo(named: "Alice", fingerprint: "fp-alice", at: Date())
        store.save([kept])
        let imageBytes = try #require(store.imageData(for: kept.withoutImageData()))

        // Rewind to a pre-sealing install: the same photo files, a plaintext index, no sealed one.
        try writeLegacyIndex([kept], to: legacyIndexURL(in: directory))
        try FileManager.default.removeItem(at: sealedIndexURL(in: directory))

        let migrated = PrivateMediaStore(indexURL: legacyIndexURL(in: directory), keyProvider: provider)
        #expect(migrated.load().count == 1)
        #expect(FileManager.default.fileExists(atPath: imageFileURL(in: directory, id: kept.id).path),
                "the migration swept the photo file it had just re-indexed")
        #expect(migrated.imageData(for: kept.withoutImageData()) == imageBytes)
    }

    // MARK: - Fail safe, never crash, never overwrite

    /// A corrupt legacy index reads as an empty wall and is reported as unrecoverable — it must
    /// never crash, and it must never be mistaken for a deferred read that blocks saves forever.
    @Test func corruptLegacyIndexReadsAsEmptyRatherThanCrashing() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateMediaStore(
            indexURL: legacyIndexURL(in: directory),
            keyProvider: InMemoryPrivateMediaKeyProvider()
        )
        try Data("{ this was never JSON".utf8).write(to: legacyIndexURL(in: directory))

        #expect(store.load().isEmpty)
        #expect(store.loadIndex() == .unrecoverable)
    }

    /// The regression this classification exists for: with no key available (an `AfterFirstUnlock`
    /// row before the first post-boot unlock) the index is DEFERRED, not empty — and a store in
    /// that state writes nothing, so neither the index nor the photo files are lost.
    @Test func sealedIndexWithoutAKeyDefersAndIsNeverOverwritten() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let provider = InMemoryPrivateMediaKeyProvider()
        let store = PrivateMediaStore(indexURL: legacyIndexURL(in: directory), keyProvider: provider)
        let kept = photo(named: "Alice", fingerprint: "fp-alice", at: Date())
        store.save([kept])

        let locked = PrivateMediaStore(indexURL: legacyIndexURL(in: directory), keyProvider: NoMediaKeyProvider())
        #expect(locked.loadIndex() == .deferred)
        #expect(locked.load().isEmpty)

        // A save driven by that empty read must not commit: the index still names the photo and
        // its bytes are still on disk.
        locked.save([])

        #expect(FileManager.default.fileExists(atPath: imageFileURL(in: directory, id: kept.id).path),
                "a keyless save swept the kept wall's photo file")
        #expect(store.load().count == 1, "a keyless save overwrote the sealed index")
    }

    /// A sealed index under a key that is present but WRONG (corruption, or a key row swept by the
    /// duress wipe) is unrecoverable rather than deferred — deferring would freeze the wall
    /// forever, since no later unlock can ever open those bytes.
    @Test func sealedIndexUnderAnotherKeyIsUnrecoverable() throws {
        let directory = makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PrivateMediaStore(
            indexURL: legacyIndexURL(in: directory),
            keyProvider: InMemoryPrivateMediaKeyProvider()
        )
        store.save([photo(named: "Alice", fingerprint: "fp-alice", at: Date())])

        let otherKey = PrivateMediaStore(
            indexURL: legacyIndexURL(in: directory),
            keyProvider: InMemoryPrivateMediaKeyProvider()
        )
        #expect(otherKey.loadIndex() == .unrecoverable)
        #expect(otherKey.load().isEmpty)
    }
}
