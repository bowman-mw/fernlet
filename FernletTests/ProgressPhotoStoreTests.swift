import Foundation
import UIKit
import CryptoKit
import Testing
import PrivateMediaStore

/// #11 piece 3: `ProgressPhotoStore` is the gym progress-photo timeline. Body photos, so both the photo
/// bytes (via the hardened `MealPhotoStore`) AND the dated index (capture dates + captions) are
/// AES-256-GCM-sealed at rest, and every write is fail-closed when there is no key.
@MainActor
struct ProgressPhotoStoreTests {
    private func jpeg(width: Int, height: Int) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            UIColor.systemIndigo.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.7)!
    }

    private func makeStore(key: SymmetricKey = SymmetricKey(size: .bits256)) -> (store: ProgressPhotoStore, dir: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        let store = ProgressPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
        return (store, dir)
    }

    private func indexURL(_ dir: URL) -> URL { dir.appendingPathComponent("index.bin") }

    /// A decoder configured exactly like the store's, so "the on-disk index does not decode" is a true
    /// negative — a plaintext index written by a regressed store WOULD decode with this same config.
    private func matchingDecoder() -> JSONDecoder {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }

    @Test func addSealsTheIndexButRecordsRoundTrip() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let secret = "week one — private note"
        let record = try #require(store.add(jpeg(width: 200, height: 240), caption: secret, capturedAt: Date()))

        // The on-disk index is sealed: it does not decode as a plaintext record array (with the store's
        // own decoder config), and the caption text is nowhere in the ciphertext.
        let onDisk = try #require(try? Data(contentsOf: indexURL(dir)))
        #expect((try? matchingDecoder().decode([ProgressPhotoRecord].self, from: onDisk)) == nil,
                "the index was written in the clear, not sealed")
        #expect(onDisk.range(of: Data(secret.utf8)) == nil, "the caption sits in the index in plaintext")

        // Round-trips through the store: the record and a decodable photo come back.
        let records = store.records()
        #expect(records.count == 1)
        #expect(records.first?.id == record.id)
        #expect(records.first?.caption == secret)
        #expect(store.imageData(for: record.id).flatMap { UIImage(data: $0) } != nil)
    }

    @Test func recordsAreNewestFirst() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let now = Date()
        let old = try #require(store.add(jpeg(width: 100, height: 100), capturedAt: now.addingTimeInterval(-100_000)))
        let mid = try #require(store.add(jpeg(width: 100, height: 100), capturedAt: now.addingTimeInterval(-10_000)))
        let new = try #require(store.add(jpeg(width: 100, height: 100), capturedAt: now))

        #expect(store.records().map(\.id) == [new.id, mid.id, old.id])
    }

    @Test func noKeyFailsClosedAndWritesNothing() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProgressPhotoStore(directory: dir, keyProvider: NoKeyProgressProvider())

        #expect(store.add(jpeg(width: 100, height: 100), caption: "x", capturedAt: Date()) == nil)
        #expect(store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: indexURL(dir).path), "an index was written without a key")
        let photos = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Photos").path)) ?? []
        #expect(photos.filter { $0.hasSuffix(".jpg") }.isEmpty, "a photo was written without a key")
    }

    @Test func deleteRemovesTheRecordAndItsPhoto() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = try #require(store.add(jpeg(width: 100, height: 100), capturedAt: Date()))
        let b = try #require(store.add(jpeg(width: 100, height: 100), capturedAt: Date().addingTimeInterval(-1)))

        store.delete(id: a.id)
        #expect(store.records().map(\.id) == [b.id])
        #expect(store.imageData(for: a.id) == nil)
        #expect(store.imageData(for: b.id) != nil)
    }

    @Test func deleteAllClearsEverythingAndStaysUsable() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = try #require(store.add(jpeg(width: 100, height: 100), capturedAt: Date()))
        _ = try #require(store.add(jpeg(width: 100, height: 100), capturedAt: Date()))

        #expect(store.deleteAll())
        #expect(store.records().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: indexURL(dir).path))
        // Still usable after a wipe without a relaunch.
        #expect(store.add(jpeg(width: 100, height: 100), capturedAt: Date()) != nil)
    }

    @Test func updateCaptionPersistsAndTrimsBlankToNil() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try #require(store.add(jpeg(width: 100, height: 100), caption: "before", capturedAt: Date()))

        store.updateCaption(id: record.id, caption: "  after  ")
        #expect(store.records().first?.caption == "after", "caption edit was not persisted/trimmed")

        store.updateCaption(id: record.id, caption: "   ")
        #expect(store.records().first?.caption == nil, "a blank caption should clear to nil, not empty string")
    }

    @Test func updateCapturedAtPersistsTheNewDateAndKeepsCaption() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = Date()
        let record = try #require(store.add(jpeg(width: 100, height: 100), caption: "8 weeks in", capturedAt: original))

        // Re-date it to a month earlier (an imported photo that shouldn't sit at "today").
        let corrected = original.addingTimeInterval(-30 * 24 * 60 * 60)
        store.updateCapturedAt(id: record.id, date: corrected)

        let reloaded = try #require(store.records().first)
        #expect(reloaded.id == record.id)
        #expect(abs(reloaded.capturedAt.timeIntervalSince(corrected)) < 1, "the new capture date was not persisted/reloaded")
        #expect(reloaded.caption == "8 weeks in", "editing the date clobbered the caption")
    }

    @Test func blankCaptionAtAddIsStoredAsNil() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let record = try #require(store.add(jpeg(width: 100, height: 100), caption: "   ", capturedAt: Date()))
        #expect(record.caption == nil)
        #expect(store.records().first?.caption == nil)
    }

    /// A plaintext index dropped into the container (tampered restore, shared-container write) must NOT be
    /// trusted as the user's timeline — the seal seam is fail-closed. Before the fix, loadIndex had a
    /// bare-JSON fallback that would surface these injected records (and reseal them on the next write).
    @Test func plaintextIndexIsNotTrustedAsTheTimeline() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let injected = ProgressPhotoRecord(id: UUID(), capturedAt: Date(), caption: "injected")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode([injected]).write(to: indexURL(dir))

        #expect(store.records().isEmpty, "a plaintext index was trusted and surfaced injected records")
    }

    /// The photo BYTES go through a `MealPhotoStore` composed with the legacy-plaintext upgrade DISABLED
    /// (body photos never had a plaintext generation). So an unsealed JPEG dropped into the `Photos/`
    /// subdir at a valid id path (tampered restore, shared-container write) must resolve to nil — never be
    /// trusted as a progress photo and re-sealed into authentic ciphertext. Against the pre-flag store,
    /// which always upgraded plaintext on read, `imageData` would return the injected image instead.
    @Test func plaintextPhotoFileIsNotTrustedAsProgressPhoto() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let photosDir = dir.appendingPathComponent("Photos", isDirectory: true)
        try FileManager.default.createDirectory(at: photosDir, withIntermediateDirectories: true)
        let id = UUID()
        let plaintext = jpeg(width: 150, height: 150)
        let photoURL = photosDir.appendingPathComponent("\(id.uuidString).jpg")
        try plaintext.write(to: photoURL)

        #expect(store.imageData(for: id) == nil, "an unsealed photo file was trusted as a progress photo")
        // Left untouched (not re-sealed in place).
        let afterRead = try #require(try? Data(contentsOf: photoURL))
        #expect(afterRead == plaintext, "the unsealed photo file was re-sealed despite the disabled upgrade")
    }

    /// An index that is present but won't decrypt (bit-rot / truncation / wrong key) must NOT be
    /// overwritten by a new add — doing so would silently drop the sealed timeline and orphan its photo
    /// files. add() refuses (returns nil) and leaves the index untouched and no orphan photo behind.
    @Test func undecodableIndexIsNotClobberedByAdd() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let garbage = Data(repeating: 0x7A, count: 256)
        try garbage.write(to: indexURL(dir))

        #expect(store.add(jpeg(width: 100, height: 100), caption: "x", capturedAt: Date()) == nil,
                "add overwrote an unreadable index instead of refusing")
        let after = try #require(try? Data(contentsOf: indexURL(dir)))
        #expect(after == garbage, "the unreadable index was clobbered by add()")
        let photos = (try? FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("Photos").path)) ?? []
        #expect(photos.filter { $0.hasSuffix(".jpg") }.isEmpty, "add left an orphan photo after refusing to write the index")
    }

    // MARK: - Phase-5 key split: dual-open safety net

    /// The timeline is TWO sealed things — the bytes and the index — under the same key, so the
    /// dual-open fallback has to cover both. An index left under the pre-split key while the photos
    /// migrated would render an empty timeline over a full photo directory: the user's body-photo
    /// history would look deleted.
    @Test func dualOpenRecoversAPreSplitTimelineAndReSealsTheIndex() throws {
        let legacyKey = SymmetricKey(size: .bits256)
        let ownKey = SymmetricKey(size: .bits256)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // A timeline written entirely by the pre-split build.
        let legacyStore = ProgressPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider(key: legacyKey))
        let record = try #require(legacyStore.add(jpeg(width: 160, height: 160), caption: "8 weeks in", capturedAt: Date()))

        // The own key alone sees neither the index nor the bytes.
        let ownOnly = ProgressPhotoStore(directory: dir, keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey))
        #expect(ownOnly.records().isEmpty)
        #expect(ownOnly.imageData(for: record.id) == nil)

        // With the fallback both come back, and both are re-sealed under the own key in place.
        let dualOpen = ProgressPhotoStore(
            directory: dir,
            keyProvider: InMemoryPrivateMediaKeyProvider(key: ownKey),
            legacyKeyProvider: InMemoryPrivateMediaKeyProvider(key: legacyKey)
        )
        #expect(dualOpen.records().map(\.id) == [record.id])
        #expect(dualOpen.records().first?.caption == "8 weeks in")
        #expect(dualOpen.imageData(for: record.id) != nil)

        #expect(ownOnly.records().map(\.id) == [record.id], "the index was not re-sealed under the own key")
        #expect(ownOnly.imageData(for: record.id) != nil, "the photo bytes were not re-sealed under the own key")
    }

    /// The fallback must not become a plaintext-index injection sink: it accepts only bytes that
    /// GCM-open under the app's own pre-split key, so a bare-JSON `index.bin` dropped into the
    /// container is still `.undecodable` — and therefore still refuses to be clobbered by a write.
    @Test func dualOpenStillRefusesAPlaintextIndex() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ProgressPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let planted = [ProgressPhotoRecord(id: UUID(), capturedAt: Date(), caption: "planted")]
        try encoder.encode(planted).write(to: indexURL(dir))

        let store = ProgressPhotoStore(
            directory: dir,
            keyProvider: InMemoryPrivateMediaKeyProvider(),
            legacyKeyProvider: InMemoryPrivateMediaKeyProvider()
        )
        #expect(store.records().isEmpty, "a plaintext index was trusted through the dual-open fallback")
        #expect(store.add(jpeg(width: 100, height: 100), caption: "x", capturedAt: Date()) == nil,
                "the plaintext index was treated as writable rather than undecodable")
    }
}

/// A key provider that never yields a key — exercises the fail-closed write path.
private struct NoKeyProgressProvider: PrivateMediaKeyProviding {
    func mediaKey() -> SymmetricKey? { nil }
}
