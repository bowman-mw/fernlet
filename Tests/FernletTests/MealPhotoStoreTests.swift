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

    @Test func savingUnderAGivenIdSealsRoundTripsAndOverwrites() throws {
        // The recipe-photo path (#1) seals under the recipe's OWN id rather than a generated one.
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let id = UUID()
        #expect(store.save(jpeg(width: 200, height: 200), forID: id))
        // Sealed on disk (not a plain JPEG), and reads back as a decodable image.
        let onDisk = try #require(try? Data(contentsOf: fileURL(dir, id)))
        #expect(UIImage(data: onDisk) == nil, "recipe photo was written in the clear, not sealed")
        #expect(store.imageData(for: id).flatMap { UIImage(data: $0) } != nil)

        // A second save under the same id overwrites in place (a replaced recipe photo).
        #expect(store.save(jpeg(width: 120, height: 120), forID: id))
        #expect(store.imageData(for: id) != nil)

        // No key → fail-closed, nothing written.
        let noKeyDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: noKeyDir) }
        let noKeyStore = MealPhotoStore(directory: noKeyDir, keyProvider: NoKeyProvider())
        #expect(noKeyStore.save(jpeg(width: 100, height: 100), forID: UUID()) == false)
    }

    @Test func legacyPlaintextUpgradeDisabledResolvesNilAndDoesNotReseal() throws {
        // Body (progress) and recipe photo stores never had a plaintext generation, so they construct
        // with the legacy-plaintext upgrade DISABLED: an unsealed file that merely parses as an image
        // must NOT be trusted, returned, or re-sealed in place (that would launder attacker-dropped
        // plaintext into authentic ciphertext). Against the OLD flag-less store — which always upgraded —
        // this same file WOULD round-trip and get re-sealed, so this test fails there.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MealPhotoStore(
            directory: dir,
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false
        )

        let id = UUID()
        let plaintext = jpeg(width: 150, height: 150)
        try plaintext.write(to: fileURL(dir, id))

        // Fail-closed: an unsealed file at a valid id path resolves to nil...
        #expect(store.imageData(for: id) == nil,
                "an unsealed file was trusted despite the legacy upgrade being disabled")
        // ...and is left exactly as-is on disk (never re-sealed).
        let afterRead = try #require(try? Data(contentsOf: fileURL(dir, id)))
        #expect(afterRead == plaintext,
                "the unsealed file was re-sealed despite the legacy upgrade being disabled")
    }

    @Test func hasSealedDataReportsFilePresenceWithoutDecrypting() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // No file yet → the "bytes never synced here" signal.
        let id = try #require(store.save(jpeg(width: 120, height: 120)))
        #expect(store.hasSealedData(forID: id))
        #expect(!store.hasSealedData(forID: UUID()), "a never-written id reported a file")

        // A file that's present but can't be opened (garbage) still reports as present — that's the whole
        // point: imageData returns nil for it, but it's here-and-broken, not on another device.
        let brokenID = UUID()
        try Data(repeating: 0xAB, count: 512).write(to: fileURL(dir, brokenID))
        #expect(store.hasSealedData(forID: brokenID))
        #expect(store.imageData(for: brokenID) == nil)

        // After deletion the file is gone.
        store.delete(id: id)
        #expect(!store.hasSealedData(forID: id))
    }

    @Test func bytePathSaveMatchesTheUIImagePathButAvoidsTheExtraEncode() throws {
        // F1 §2.5 double-encode fix: the meal sheet's library pick now seals the picked JPEG bytes
        // straight through the store (one normalize at q0.8) instead of the UIImage overload's redundant
        // `jpegData(0.82)` pre-encode. Both paths must produce an equivalent stored photo — same bounded
        // dimensions — and the byte path (no generation-loss pre-encode) is never larger.
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        // A "library pick": a fairly large source JPEG whose bytes the byte path seals directly.
        let picked = jpeg(width: 2400, height: 1800)

        // Byte path — what FernletStore.saveMealPhoto(data:) does: seal the picked bytes as-is.
        let byteID = try #require(store.save(picked))
        // Legacy UIImage path — what saveMealPhoto(_ image:) does: decode, re-encode at 0.82, then seal.
        let image = try #require(UIImage(data: picked))
        let reEncoded = try #require(image.jpegData(compressionQuality: 0.82))
        let imageID = try #require(store.save(reEncoded))

        let byteImage = try #require(store.imageData(for: byteID).flatMap(UIImage.init(data:)))
        let uiImage = try #require(store.imageData(for: imageID).flatMap(UIImage.init(data:)))

        // Both saved photos downscale to the same bounded size (longest side ≤ 1600).
        #expect(byteImage.size == uiImage.size)
        #expect(max(byteImage.size.width, byteImage.size.height) <= 1600)
        // The byte path skips the extra full-resolution encode, so it is never the larger file.
        let byteBytes = try #require(store.imageData(for: byteID)).count
        let imageBytes = try #require(store.imageData(for: imageID)).count
        #expect(byteBytes <= imageBytes)
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

    // MARK: - Phase-5 key split: dual-open safety net

    @Test func dualOpenReturnsAPreSplitPhotoAndReSealsItUnderTheOwnKey() throws {
        // The window this covers: the media key has been split, but the eager migration pass has not
        // reached this file yet, so it is still sealed under the OLD shared (now friend-wall) key.
        // Without the fallback the user's own photo would simply vanish from the UI.
        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write the file the way the pre-split build did: sealed under the legacy key.
        let legacyStore = MealPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider(key: legacyKey))
        let id = try #require(legacyStore.save(jpeg(width: 180, height: 180)))
        let expected = try #require(legacyStore.imageData(for: id))

        // Own key alone cannot open it...
        let ownOnly = MealPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey))
        #expect(ownOnly.imageData(for: id) == nil, "the split is meaningless if the own key opens pre-split bytes")

        // ...but with the legacy provider injected as the fallback the bytes come back, and the file
        // is upgraded in place so it leaves the legacy generation on this first read.
        let dualOpen = MealPhotoStore(
            directory: dir,
            keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKeyProvider: InMemoryPrivateMediaKeyProvider(key: legacyKey)
        )
        #expect(dualOpen.imageData(for: id) == expected)
        #expect(ownOnly.imageData(for: id) == expected, "the dual-open read did not re-seal under the own key")
        // And the legacy key no longer opens it — the upgrade is a move, not a copy.
        let legacyOnly = MealPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider(key: legacyKey))
        #expect(legacyOnly.imageData(for: id) == nil)
    }

    @Test func dualOpenNeverLaundersPlaintextIntoTheSealedStore() throws {
        // The fallback accepts only bytes that GCM-open under the app's own pre-split key. A
        // plaintext JPEG dropped at a valid id path in a born-sealed store must STILL be refused —
        // adding a second key must not reopen the laundering hole the upgrade flag closed.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MealPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = MealPhotoStore(
            directory: dir,
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            allowsLegacyPlaintextUpgrade: false,
            legacyKeyProvider: InMemoryPrivateMediaKeyProvider()
        )

        let id = UUID()
        let plaintext = jpeg(width: 150, height: 150)
        try plaintext.write(to: fileURL(dir, id))

        #expect(store.imageData(for: id) == nil, "the dual-open fallback trusted unsealed bytes")
        let afterRead = try #require(try? Data(contentsOf: fileURL(dir, id)))
        #expect(afterRead == plaintext, "unsealed bytes were laundered into authentic ciphertext")
    }
}

/// A key provider that never yields a key — exercises the fail-closed save path.
private struct NoKeyProvider: PrivateMediaKeyProviding {
    func mediaKey() -> SymmetricKey? { nil }
}
