import Foundation
import UIKit
import CryptoKit
import Testing
@testable import Fernlet

/// Deterministic, keychain-free key provider for tests.
struct InMemoryPrivateMediaKeyProvider: PrivateMediaKeyProviding {
    let key: SymmetricKey
    init(key: SymmetricKey = SymmetricKey(size: .bits256)) { self.key = key }
    func mediaKey() -> SymmetricKey? { key }
}

@MainActor
struct PrivateMediaStoreTests {
    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // output pixels == size, so dimensions are deterministic
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.gray.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.5)!
    }

    private func makeStore() -> (store: PrivateMediaStore, directory: URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateMediaStoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = PrivateMediaStore(
            indexURL: directory.appendingPathComponent("MeshPhotoCache.json"),
            keyProvider: InMemoryPrivateMediaKeyProvider()
        )
        return (store, directory)
    }

    private func imageFileURL(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("MeshPhotos/\(id.uuidString).jpg")
    }

    // MARK: - Decompression-bomb defense (regressions for prior finding #11)

    /// Regression for prior finding #11: normally-sized photos are accepted.
    @Test func acceptsNormallySizedImage() {
        #expect(PrivateMediaStore.isWithinSafePixelBounds(jpeg(width: 300, height: 300)))
    }

    /// A photo whose pixel dimensions exceed the safe bound is rejected *before* its
    /// full-resolution bytes are persisted or decoded by any display/library-save sink — the
    /// 10 MB byte cap alone cannot stop a tiny, highly-compressed image that decodes huge.
    @Test func rejectsOverlyLargeDimensions() {
        // 7000 px wide is over the 6000 px cap but trivially small in bytes/memory.
        #expect(!PrivateMediaStore.isWithinSafePixelBounds(jpeg(width: 7000, height: 4)))
    }

    /// Data whose dimensions cannot be read (non-image / malformed) is treated as unsafe.
    @Test func rejectsNonImageData() {
        #expect(!PrivateMediaStore.isWithinSafePixelBounds(Data("not an image".utf8)))
    }

    // MARK: - At-rest encryption

    /// Image bytes are AES-GCM-encrypted before they touch disk and round-trip back to the
    /// original plaintext when read back through the store.
    @Test func encryptsImageBytesAtRestAndRoundTrips() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageBytes = jpeg(width: 64, height: 64)
        let photo = FriendPhotoPayload(imageData: imageBytes, senderName: "Alice")

        store.save([photo])

        // On-disk bytes must be ciphertext — different from the JPEG and lacking its SOI marker.
        let onDisk = try #require(try? Data(contentsOf: imageFileURL(in: directory, id: photo.id)))
        #expect(onDisk != imageBytes)
        #expect(!onDisk.starts(with: Data([0xFF, 0xD8])))

        // Reading back through the store (no in-memory bytes) decrypts to the original.
        #expect(store.imageData(for: photo.withoutImageData()) == imageBytes)
    }

    /// A photo encrypted under one key cannot be read with a different key (the bytes are
    /// genuinely sealed, not merely obfuscated).
    @Test func cannotDecryptWithWrongKey() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PrivateMediaStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let indexURL = directory.appendingPathComponent("MeshPhotoCache.json")
        let imageBytes = jpeg(width: 64, height: 64)
        let photo = FriendPhotoPayload(imageData: imageBytes, senderName: "Alice")

        PrivateMediaStore(indexURL: indexURL, keyProvider: InMemoryPrivateMediaKeyProvider()).save([photo])

        // A different key can't open the ciphertext; since the raw bytes aren't a valid image
        // either, the store reports the photo as unreadable (nil) rather than handing back garbage.
        let otherStore = PrivateMediaStore(indexURL: indexURL, keyProvider: InMemoryPrivateMediaKeyProvider())
        #expect(otherStore.imageData(for: photo.withoutImageData()) == nil)
    }

    /// Bytes that are neither openable under the key nor a valid image (corruption, truncated
    /// write) resolve to nil — they are never handed back as if they were a photo.
    @Test func returnsNilForUndecodableBytes() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let id = UUID()
        let imageURL = imageFileURL(in: directory, id: id)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("neither ciphertext we can open nor a valid image".utf8).write(to: imageURL)

        let payload = FriendPhotoPayload(id: id, imageData: Data([1]), senderName: "X").withoutImageData()
        #expect(store.imageData(for: payload) == nil)
    }

    /// Files written before at-rest encryption (plaintext JPEG) remain readable AND are upgraded
    /// to ciphertext in place on first access, so existing caches are neither lost nor left plaintext.
    @Test func readsAndReEncryptsLegacyPlaintextFiles() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let imageBytes = jpeg(width: 48, height: 48)
        let id = UUID()
        let imageURL = imageFileURL(in: directory, id: id)
        try FileManager.default.createDirectory(at: imageURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try imageBytes.write(to: imageURL)  // simulate a pre-encryption plaintext file

        let payload = FriendPhotoPayload(id: id, imageData: imageBytes, senderName: "Legacy").withoutImageData()
        #expect(store.imageData(for: payload) == imageBytes)

        // The legacy plaintext file is upgraded to ciphertext on first access...
        let onDiskAfter = try #require(try? Data(contentsOf: imageURL))
        #expect(onDiskAfter != imageBytes)
        #expect(!onDiskAfter.starts(with: Data([0xFF, 0xD8])))
        // ...and still reads back as the original bytes.
        #expect(store.imageData(for: payload) == imageBytes)
    }

    // MARK: - Eviction / orphan cleanup (underpins per-photo delete)

    /// Re-saving without a photo (as `deletePhoto` does) removes that photo's image and thumbnail
    /// files from disk while keeping the survivors.
    @Test func saveRemovesOrphanedFilesForDroppedPhotos() throws {
        let (store, directory) = makeStore()
        defer { try? FileManager.default.removeItem(at: directory) }
        let keep = FriendPhotoPayload(imageData: jpeg(width: 64, height: 64), senderName: "Keep")
        let drop = FriendPhotoPayload(imageData: jpeg(width: 64, height: 64), senderName: "Drop")

        store.save([keep, drop])
        let keepURL = imageFileURL(in: directory, id: keep.id)
        let dropURL = imageFileURL(in: directory, id: drop.id)
        #expect(FileManager.default.fileExists(atPath: keepURL.path))
        #expect(FileManager.default.fileExists(atPath: dropURL.path))

        store.save([keep.withoutImageData()])
        #expect(FileManager.default.fileExists(atPath: keepURL.path))
        #expect(!FileManager.default.fileExists(atPath: dropURL.path))
    }
}
