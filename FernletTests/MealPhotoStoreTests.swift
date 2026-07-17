import Foundation
import UIKit
import CryptoKit
import Testing
import PrivateMediaStore

/// #11 hardening: `MealPhotoStore` now AES-256-GCM-seals every photo at rest, downscales on the way in,
/// upgrades pre-sealing plaintext files on read, and fails closed when there is no key. These had to
/// hold before body (gym progress) photos were routed through the store.
@MainActor
struct MealPhotoStoreTests {
    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1  // output pixels == size, so dimensions are deterministic
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.systemTeal.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.7)!
    }

    private func makeStore(key: SymmetricKey = SymmetricKey(size: .bits256)) -> (store: MealPhotoStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = MealPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
        return (store, dir)
    }

    private func fileURL(_ dir: URL, _ id: UUID) -> URL {
        dir.appendingPathComponent("\(id.uuidString).jpg")
    }

    @Test func savedPhotoIsSealedOnDiskButRoundTripsThroughTheStore() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try #require(store.save(jpeg(width: 200, height: 200)))
        // Inspect the on-disk bytes BEFORE any read: `imageData` re-seals a plaintext file via the
        // legacy-upgrade path, so reading first would seal an unsealed save and hide the bug.
        let onDisk = try #require(try? Data(contentsOf: fileURL(dir, id)))
        #expect(UIImage(data: onDisk) == nil, "photo bytes were written in the clear, not sealed")
        #expect(!PrivateMediaStore.isWithinSafePixelBounds(onDisk))
        // Now the round-trip: reading back through the store yields a decodable image.
        let read = try #require(store.imageData(for: id))
        #expect(UIImage(data: read) != nil)
    }

    @Test func legacyPlaintextFileIsUpgradedInPlaceOnRead() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Simulate a photo written by the pre-sealing build: raw JPEG at the id filename.
        let id = UUID()
        let plaintext = jpeg(width: 150, height: 150)
        try plaintext.write(to: fileURL(dir, id))

        // First read returns the image AND re-seals the file.
        let read = try #require(store.imageData(for: id))
        #expect(UIImage(data: read) != nil)
        let afterRead = try #require(try? Data(contentsOf: fileURL(dir, id)))
        #expect(UIImage(data: afterRead) == nil, "legacy plaintext was not re-sealed on read")

        // Second read still works, now via the sealed path.
        #expect(store.imageData(for: id) != nil)
    }

    @Test func noKeyFailsClosedAndWritesNothing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MealPhotoStore(directory: dir, keyProvider: NoKeyProvider())

        #expect(store.save(jpeg(width: 100, height: 100)) == nil)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        #expect(contents.filter { $0.hasSuffix(".jpg") }.isEmpty, "a photo was written to disk without a key")
    }

    @Test func oversizedPhotoIsDownscaledOnSave() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try #require(store.save(jpeg(width: 3000, height: 2000)))
        let data = try #require(store.imageData(for: id))
        let image = try #require(UIImage(data: data))
        #expect(max(image.size.width, image.size.height) <= 1600, "photo was not downscaled: \(image.size)")
    }

    @Test func smallPhotoIsNotUpscaled() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = try #require(store.save(jpeg(width: 240, height: 240)))
        let data = try #require(store.imageData(for: id))
        let image = try #require(UIImage(data: data))
        #expect(max(image.size.width, image.size.height) <= 260, "small photo was upscaled: \(image.size)")
    }

    @Test func nonImageDataIsRejectedOnSave() {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(store.save(Data("not an image".utf8)) == nil)
    }

    @Test func garbageFileReadsBackAsNilNotMisclassifiedAsLegacy() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        try Data(repeating: 0xAB, count: 512).write(to: fileURL(dir, id))
        #expect(store.imageData(for: id) == nil)
    }

    @Test func wrongKeyDoesNotReturnCiphertextAsAPhoto() throws {
        // Seal with one key, read with a store that has a different key: must be nil, not garbage.
        let keyA = SymmetricKey(size: .bits256)
        let (storeA, dir) = makeStore(key: keyA)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try #require(storeA.save(jpeg(width: 120, height: 120)))

        let storeB = MealPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider())
        #expect(storeB.imageData(for: id) == nil)
    }

    @Test func deleteRemovesTheFileAndDeleteAllClearsTheStore() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try #require(store.save(jpeg(width: 100, height: 100)))
        let b = try #require(store.save(jpeg(width: 100, height: 100)))

        store.delete(id: a)
        #expect(store.imageData(for: a) == nil)
        #expect(store.imageData(for: b) != nil)

        #expect(store.deleteAll())
        #expect(store.imageData(for: b) == nil)
        // Still usable after a wipe.
        #expect(store.save(jpeg(width: 100, height: 100)) != nil)
    }
}

/// A key provider that never yields a key — exercises the fail-closed save path.
private struct NoKeyProvider: PrivateMediaKeyProviding {
    func mediaKey() -> SymmetricKey? { nil }
}
