import CryptoKit
import Foundation
import Testing
import UIKit
import FernletCrypto
import FernletDomainModel
import PrivateMediaStore

/// The sealed pending corpus: session photos held from the moment they exist until the person
/// chooses, never on the friend wall before that (design 2026-09-30, Unit 1).
///
/// Everything here drives the REAL store against a per-test directory with an in-memory key, so
/// nothing touches the simulator keychain or the app-support wall. The keychain half (the row is
/// device-bound and lives under the service the duress wipe sweeps) is in `KeyCustodyBoundaryTests`.
///
/// The format fixtures below re-spell the at-rest box (`FMA2` + AES-GCM combined, the purpose as
/// authenticated data) rather than asking production for it, so a silent format change fails here.
@MainActor
struct PendingSessionPhotoStoreTests {

    // MARK: - Fixtures

    private func makeDirectory() -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PendingSessionPhotoStoreTests-\(UUID().uuidString)", isDirectory: true)
        return root.appendingPathComponent(PendingSessionPhotoStore.directoryName, isDirectory: true)
    }

    private func cleanUp(_ directory: URL) {
        try? FileManager.default.removeItem(at: directory.deletingLastPathComponent())
    }

    private func indexURL(in directory: URL) -> URL {
        directory.appendingPathComponent("PendingSessionPhotoIndex.sealed")
    }

    private func imageURL(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("Photos/\(id.uuidString).jpg")
    }

    private func thumbnailURL(in directory: URL, id: UUID) -> URL {
        directory.appendingPathComponent("Thumbnails/\(id.uuidString).jpg")
    }

    private func jpeg(width: Int = 32, height: Int = 32, color: UIColor = .gray) -> Data {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { ctx in
            color.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        return image.jpegData(compressionQuality: 0.5) ?? Data()
    }

    /// The fixtures' clock. Holds and answers in one test share it: a hold drops tombstones that
    /// expired by ITS `heldAt`, so a later-dated hold would legitimately outlive an answer.
    nonisolated private static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func held(
        origin: String = "fp-origin",
        itemID: UUID = UUID(),
        localID: UUID? = nil,
        sender: String = "Sam",
        at heldAt: Date = PendingSessionPhotoStoreTests.t0
    ) -> HeldSessionPhoto {
        let payload = FriendPhotoPayload(
            id: localID ?? itemID,
            imageData: Data(),
            addedAt: heldAt,
            senderName: sender,
            senderFingerprint: origin
        )
        return HeldSessionPhoto(key: HeldPhotoKey(origin: origin, itemID: itemID), heldAt: heldAt, payload: payload)
    }

    /// Holds `photo` and requires it to land, returning the committed index.
    private func requireHeld(
        _ photo: HeldSessionPhoto,
        bytes: Data,
        into index: PendingSessionPhotoIndex,
        store: PendingSessionPhotoStore
    ) throws -> PendingSessionPhotoIndex {
        let (outcome, next) = store.hold(photo, imageData: bytes, into: index)
        try #require(outcome == .held, "hold did not land: \(outcome)")
        return next
    }

    /// Seals `json` as a pending index exactly as the format is specified, under `key`.
    private func sealedIndex(_ json: String, key: SymmetricKey) throws -> Data {
        let purpose = FernletCryptoPurpose.AEAD.privatePendingSessionPhotoIndexV1
        let box = try AES.GCM.seal(Data(json.utf8), using: key, authenticating: Data(purpose.rawValue.utf8))
        return Data("FMA2".utf8) + (try #require(box.combined))
    }

    /// Thrown when a load that must be clean is not.
    private struct UnexpectedLoad: Error {
        let load: PendingSessionPhotoStore.Load
    }

    private func loadedIndex(_ store: PendingSessionPhotoStore, now: Date = Date()) throws -> PendingSessionPhotoIndex {
        let load = store.load(now: now)
        guard case .loaded(let index) = load else { throw UnexpectedLoad(load: load) }
        return index
    }

    private func regularFiles(under directory: URL) -> [URL] {
        let enumerator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        var found: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(url) }
        }
        return found
    }

    // MARK: - Round trip and format

    /// A held photo survives a fresh store on the same directory (the process-kill case): the index
    /// comes back equal, the bytes hydrate, and the thumbnail opens.
    @Test func aHeldPhotoRoundTripsThroughAFreshStore() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
        let bytes = jpeg()
        let photo = held(sender: "Alice")

        let committed = try requireHeld(photo, bytes: bytes, into: .empty, store: store)

        let reopened = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
        let loaded = try loadedIndex(reopened)
        #expect(loaded == committed)
        let entry = try #require(loaded.photos.first)
        #expect(entry.payload.imageData == nil, "the index must hold metadata only")
        #expect(entry.payload.senderName == "Alice")
        #expect(reopened.imageData(for: entry) == bytes)
        #expect(reopened.hydrated(entry)?.imageData == bytes)
        #expect(reopened.thumbnailData(for: entry) != nil)
    }

    /// Every file the corpus writes is an `FMA2` box, and the index discloses neither the sender
    /// name nor the fingerprint.
    @Test func everyFileIsAnFMA2BoxAndTheIndexIsSealed() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        _ = try requireHeld(held(origin: "fp-secret", sender: "Secret Sam"), bytes: jpeg(), into: .empty, store: store)

        let files = regularFiles(under: directory)
        #expect(files.count == 3, "expected image, thumbnail and index; found \(files.map(\.lastPathComponent))")
        for file in files {
            let bytes = try Data(contentsOf: file)
            #expect(bytes.starts(with: Data("FMA2".utf8)), "\(file.lastPathComponent) is not an FMA2 box")
        }
        let index = try Data(contentsOf: indexURL(in: directory))
        #expect(index.range(of: Data("Secret Sam".utf8)) == nil)
        #expect(index.range(of: Data("fp-secret".utf8)) == nil)
    }

    /// Domain separation between the two corpora, under ONE key: a pending file moved into the
    /// wall does not open as a wall photo, a wall file moved into the corpus does not open as a
    /// pending one, and the pending index is not a wall index. A photo can reach the wall only
    /// through the wall's own write path.
    @Test func pendingAndWallBytesDoNotOpenInEachOther() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let provider = InMemoryPrivateMediaKeyProvider()
        let pending = PendingSessionPhotoStore(directory: directory, keyProvider: provider)
        let wallRoot = directory.deletingLastPathComponent()
        let wall = PrivateMediaStore(indexURL: wallRoot.appendingPathComponent("MeshPhotoCache.json"), keyProvider: provider)
        let photo = held()
        let index = try requireHeld(photo, bytes: jpeg(), into: .empty, store: pending)
        let wallPhoto = FriendPhotoPayload(imageData: jpeg(color: .red), senderName: "Wall")
        wall.save([wallPhoto])

        // Pending bytes planted under the wall's name for the same id.
        let wallImage = wallRoot.appendingPathComponent("MeshPhotos/\(photo.localID.uuidString).jpg")
        try FileManager.default.copyItem(at: imageURL(in: directory, id: photo.localID), to: wallImage)
        #expect(wall.imageData(for: photo.payload.withoutImageData()) == nil, "a pending box opened as a wall photo")
        #expect(wall.thumbnailData(for: photo.payload.withoutImageData()) == nil)

        // Wall bytes planted under the pending name of a held photo.
        let pendingImage = imageURL(in: directory, id: photo.localID)
        try FileManager.default.removeItem(at: pendingImage)
        try FileManager.default.copyItem(
            at: wallRoot.appendingPathComponent("MeshPhotos/\(wallPhoto.id.uuidString).jpg"),
            to: pendingImage
        )
        #expect(pending.imageData(for: try #require(index.photos.first)) == nil, "a wall box opened as a pending photo")

        // The pending index is not a wall index.
        try FileManager.default.removeItem(at: wallRoot.appendingPathComponent("MeshPhotoCache.sealed"))
        try FileManager.default.copyItem(at: indexURL(in: directory), to: wallRoot.appendingPathComponent("MeshPhotoCache.sealed"))
        #expect(wall.loadIndex() == .unrecoverable)
    }

    /// Born sealed: plaintext planted at a held photo's paths reads as missing, and is not
    /// laundered into authentic ciphertext by a read.
    @Test func plantedPlaintextReadsAsMissingAndIsNeverResealed() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let photo = held()
        let index = try requireHeld(photo, bytes: jpeg(), into: .empty, store: store)
        let planted = jpeg(color: .blue)
        try planted.write(to: imageURL(in: directory, id: photo.localID))
        try planted.write(to: thumbnailURL(in: directory, id: photo.localID))
        let entry = try #require(index.photos.first)

        #expect(store.imageData(for: entry) == nil)
        #expect(store.thumbnailData(for: entry) == nil)
        #expect(store.hydrated(entry) == nil)
        #expect(try Data(contentsOf: imageURL(in: directory, id: photo.localID)) == planted,
                "a born-sealed corpus re-sealed planted plaintext")
    }

    /// The corpus directory is excluded from the device backup.
    @Test func theCorpusDirectoryIsExcludedFromBackup() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        _ = try requireHeld(held(), bytes: jpeg(), into: .empty, store: store)

        let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
        #expect(values.isExcludedFromBackup == true)
    }

    // MARK: - Deferral, purge, format

    /// No key: an existing index is DEFERRED (never read as empty), and a keyless hold or answer
    /// writes nothing over it.
    @Test func noKeyDefersAndNothingIsOverwritten() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let photo = held()
        _ = try requireHeld(photo, bytes: jpeg(), into: .empty, store: store)
        let before = try Data(contentsOf: indexURL(in: directory))

        let locked = PendingSessionPhotoStore(directory: directory, keyProvider: NoMediaKeyProvider())
        #expect(locked.load(now: Date()) == .deferred(.noKey))
        let (outcome, _) = locked.hold(held(), imageData: jpeg(), into: .empty)
        #expect(outcome == .notPersisted)
        #expect(locked.commitAnswers([photo.key], in: .empty, now: Date()).committed == false)

        #expect(try Data(contentsOf: indexURL(in: directory)) == before, "a keyless write replaced the index")
        #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path))
    }

    /// An index that EXISTS but cannot be read — a directory at its path, or a mode-000 file — is a
    /// deferral, never an empty corpus, and nothing is swept.
    @Test func anUnreadableIndexDefersAndSweepsNothing() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let photo = held()
        _ = try requireHeld(photo, bytes: jpeg(), into: .empty, store: store)
        let index = indexURL(in: directory)

        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index.path)
        #expect(store.load(now: Date()) == .deferred(.fileUnreadable))
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: index.path)
        #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path))

        try FileManager.default.removeItem(at: index)
        try FileManager.default.createDirectory(at: index, withIntermediateDirectories: true)
        #expect(store.load(now: Date()) == .deferred(.fileUnreadable))
        #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path),
                "a deferred load swept a held photo")
    }

    /// A present key that does not open the index (a duress-swept and re-minted key, corruption)
    /// purges the corpus at once: nothing in it can ever open again.
    @Test func aWrongKeyIsUnrecoverableAndPurgesTheCorpus() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        _ = try requireHeld(held(), bytes: jpeg(), into: .empty, store: store)

        let rekeyed = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        #expect(rekeyed.load(now: Date()) == .unrecoverable(purged: true))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(rekeyed.load(now: Date()) == .loaded(.empty))
    }

    /// A file that OPENS but is not this build's format — a newer `schemaVersion`, a body that does
    /// not decode, no version at all — is deferred as `unsupportedFormat`: never written over,
    /// never purged, and the photos it names keep their files.
    @Test func anOpenedIndexInAnotherFormatDefersAndIsNeverPurged() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
        let photo = held()
        _ = try requireHeld(photo, bytes: jpeg(), into: .empty, store: store)

        let variants = [
            #"{"schemaVersion":2,"photos":[],"answered":[],"future":true}"#,
            #"{"schemaVersion":1,"photos":"not a list","answered":[]}"#,
            #"{"photos":[],"answered":[]}"#,
        ]
        for json in variants {
            let planted = try sealedIndex(json, key: key)
            try planted.write(to: indexURL(in: directory))

            #expect(store.load(now: Date()) == .deferred(.unsupportedFormat), "variant \(json)")
            #expect(try Data(contentsOf: indexURL(in: directory)) == planted, "the load rewrote \(json)")
            #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path),
                    "an unsupported-format load purged or swept (\(json))")
        }
    }

    /// Files nothing names — a hold killed between its byte write and its index write — are swept
    /// on a clean load, with or without an index; named files stay.
    @Test func unindexedFilesAreSweptOnACleanLoad() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let photo = held()
        _ = try requireHeld(photo, bytes: jpeg(), into: .empty, store: store)
        let stray = UUID()
        try Data("stray".utf8).write(to: imageURL(in: directory, id: stray))
        try Data("stray".utf8).write(to: thumbnailURL(in: directory, id: stray))

        _ = try loadedIndex(store)
        #expect(!FileManager.default.fileExists(atPath: imageURL(in: directory, id: stray).path))
        #expect(!FileManager.default.fileExists(atPath: thumbnailURL(in: directory, id: stray).path))
        #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path))

        // With no index at all, every file is unnamed.
        try FileManager.default.removeItem(at: indexURL(in: directory))
        #expect(try loadedIndex(store) == .empty)
        #expect(!FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path))
    }

    // MARK: - Identity and bounds

    /// Two origins' photos with the same item id are two photos: both held under their own keys
    /// and local ids, neither "already held" because of the other, and a tombstone for one never
    /// refuses the other. A hold that would reuse another photo's local id is refused rather than
    /// overwrite its file.
    @Test func sameItemIDFromTwoOriginsIsTwoPhotos() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let itemID = UUID()
        let genuine = held(origin: "fp-genuine", itemID: itemID)
        let impostor = held(origin: "fp-impostor", itemID: itemID, localID: UUID())
        let genuineBytes = jpeg(color: .green)
        let impostorBytes = jpeg(color: .red)

        var index = try requireHeld(impostor, bytes: impostorBytes, into: .empty, store: store)
        index = try requireHeld(genuine, bytes: genuineBytes, into: index, store: store)
        #expect(index.photos.count == 2)
        #expect(store.imageData(for: try #require(index.heldPhoto(localID: genuine.localID))) == genuineBytes)
        #expect(store.imageData(for: try #require(index.heldPhoto(localID: impostor.localID))) == impostorBytes)

        let clash = held(origin: "fp-third", itemID: UUID(), localID: genuine.localID)
        #expect(store.hold(clash, imageData: impostorBytes, into: index).0 == .notPersisted)
        #expect(store.imageData(for: try #require(index.heldPhoto(localID: genuine.localID))) == genuineBytes,
                "a colliding local id overwrote another photo's file")

        let (committed, answered) = store.commitAnswers([impostor.key], in: index, now: Self.t0)
        #expect(committed)
        #expect(answered.isAnswered(impostor.key))
        #expect(!answered.isAnswered(genuine.key))
        #expect(answered.holds(genuine.key))
        #expect(store.hold(held(origin: "fp-impostor", itemID: itemID, localID: UUID()), imageData: impostorBytes, into: answered).0
                == .answered)
    }

    /// Re-holding a held key or an answered key writes nothing.
    @Test func aHeldOrAnsweredKeyIsNotHeldAgain() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let photo = held()
        let index = try requireHeld(photo, bytes: jpeg(), into: .empty, store: store)

        let (again, unchanged) = store.hold(photo, imageData: jpeg(), into: index)
        #expect(again == .alreadyHeld)
        #expect(unchanged == index)

        let (_, answered) = store.commitAnswers([photo.key], in: index, now: Self.t0)
        #expect(store.hold(photo, imageData: jpeg(), into: answered).0 == .answered)

        // The same clock one retention period on: the tombstone has done its job and goes.
        let expiredHold = held(origin: photo.key.origin, itemID: photo.key.itemID,
                               at: Self.t0.addingTimeInterval(PendingSessionPhotoStore.answeredRetention + 1))
        #expect(store.hold(expiredHold, imageData: jpeg(), into: answered).0 == .held)
    }

    /// The cap is a REFUSAL: the 201st hold is `.full` and nothing already held is evicted.
    @Test func theTwoHundredAndFirstHoldIsFullAndNothingIsEvicted() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let bytes = jpeg(width: 8, height: 8)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var index = PendingSessionPhotoIndex.empty
        for offset in 0..<PendingSessionPhotoStore.maxHeldPhotos {
            index = try requireHeld(held(at: start.addingTimeInterval(Double(offset))), bytes: bytes, into: index, store: store)
        }
        let before = index.heldLocalIDs
        let extra = held(at: start.addingTimeInterval(10_000))

        let (outcome, after) = store.hold(extra, imageData: bytes, into: index)

        #expect(outcome == .full)
        #expect(after.heldLocalIDs == before)
        #expect(try loadedIndex(store).heldLocalIDs == before)
        #expect(!FileManager.default.fileExists(atPath: imageURL(in: directory, id: extra.localID).path))
    }

    /// Bytes over the pixel bounds are refused for good, before anything is written.
    @Test func unsafeBytesAreRefusedAndNothingIsWritten() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let photo = held()

        let (outcome, index) = store.hold(photo, imageData: jpeg(width: 7_000, height: 4), into: .empty)

        #expect(outcome == .unsafeImage)
        #expect(index == .empty)
        #expect(!FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path))
        #expect(!FileManager.default.fileExists(atPath: indexURL(in: directory).path))
    }

    // MARK: - Answers and tombstones

    /// An answer is one committed index write: the answered photos leave the index and are
    /// tombstoned, their files are swept after the commit, the others stay.
    @Test func commitAnswersRemovesTombstonesAndSweeps() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let kept = held()
        let discarded = held()
        let waiting = held()
        var index = PendingSessionPhotoIndex.empty
        for photo in [kept, discarded, waiting] { index = try requireHeld(photo, bytes: jpeg(), into: index, store: store) }
        let now = Date(timeIntervalSince1970: 1_800_000_100)

        let (committed, next) = store.commitAnswers([kept.key, discarded.key], in: index, now: now)

        #expect(committed)
        #expect(next.heldLocalIDs == [waiting.localID])
        #expect(next.isAnswered(kept.key) && next.isAnswered(discarded.key))
        #expect(next.answered.allSatisfy { $0.expiresAt == now.addingTimeInterval(PendingSessionPhotoStore.answeredRetention) })
        #expect(try loadedIndex(store, now: now) == next)
        for gone in [kept, discarded] {
            #expect(!FileManager.default.fileExists(atPath: imageURL(in: directory, id: gone.localID).path))
            #expect(!FileManager.default.fileExists(atPath: thumbnailURL(in: directory, id: gone.localID).path))
        }
        #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, id: waiting.localID).path))
    }

    /// An answer whose index write fails changes nothing: no file is swept, the index is untouched,
    /// and the caller gets its old mirror back.
    @Test func aFailedAnswerWriteSweepsNothing() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let photo = held()
        let index = try requireHeld(photo, bytes: jpeg(), into: .empty, store: store)
        try FileManager.default.removeItem(at: indexURL(in: directory))
        try FileManager.default.createDirectory(at: indexURL(in: directory), withIntermediateDirectories: true)

        let (committed, returned) = store.commitAnswers([photo.key], in: index, now: Date())

        #expect(!committed)
        #expect(returned == index)
        #expect(FileManager.default.fileExists(atPath: imageURL(in: directory, id: photo.localID).path),
                "an uncommitted answer swept the photo it did not answer")
    }

    /// Tombstones expire (on every write and load) and are capped, soonest-expiring first.
    @Test func expiredAndOverCapTombstonesArePruned() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let first = HeldPhotoKey(origin: "fp", itemID: UUID())
        let (_, afterFirst) = store.commitAnswers([first], in: .empty, now: t0)
        let second = HeldPhotoKey(origin: "fp", itemID: UUID())
        let later = t0.addingTimeInterval(PendingSessionPhotoStore.answeredRetention + 60)

        let (_, afterSecond) = store.commitAnswers([second], in: afterFirst, now: later)
        #expect(!afterSecond.isAnswered(first) && afterSecond.isAnswered(second))
        #expect(try loadedIndex(store, now: later.addingTimeInterval(PendingSessionPhotoStore.answeredRetention)).answered.isEmpty)

        let batch = Set((0..<PendingSessionPhotoStore.maxAnsweredIDs).map { _ in HeldPhotoKey(origin: "fp", itemID: UUID()) })
        let (_, full) = store.commitAnswers(batch, in: .empty, now: t0)
        #expect(full.answered.count == PendingSessionPhotoStore.maxAnsweredIDs)
        let extra = HeldPhotoKey(origin: "fp", itemID: UUID())
        let (_, capped) = store.commitAnswers([extra], in: full, now: t0.addingTimeInterval(1))
        #expect(capped.answered.count == PendingSessionPhotoStore.maxAnsweredIDs)
        #expect(capped.isAnswered(extra), "the cap dropped the newest tombstone instead of the soonest-expiring")
    }

    /// A held photo whose session lists more participants than the wire decoder accepts (a long
    /// session with churn) is cut to that bound as it is held, so the index still loads. Before, the
    /// index opened but its WHOLE body failed to decode: `.deferred(.unsupportedFormat)` for good —
    /// never written, never purged, no build able to read it, every later hold refused (review
    /// U1-L-U1-F1).
    @Test func aSessionPastTheParticipantBoundStillLoads() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let key = SymmetricKey(size: .bits256)
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
        let participants = (0...FriendPhotoLimits.maxParticipants).map {
            FriendPhotoSessionParticipant(fingerprint: "fp-\($0)", displayName: "Person \($0)")
        }
        let session = FriendPhotoSessionMetadata(
            id: UUID(), meshID: UUID(), meshName: "Long evening", startedAt: Self.t0, participants: participants
        )
        let plain = held(sender: "Crowd")
        let crowded = HeldSessionPhoto(key: plain.key, heldAt: plain.heldAt, payload: plain.payload.withSession(session))

        let committed = try requireHeld(crowded, bytes: jpeg(), into: .empty, store: store)

        let reopened = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider(key: key))
        let loaded = try loadedIndex(reopened, now: Self.t0)
        #expect(loaded == committed, "the committed mirror is not what a load reads back")
        let entry = try #require(loaded.photos.first)
        #expect(entry.payload.session?.participants == Array(participants.prefix(FriendPhotoLimits.maxParticipants)))
        // Not stuck: the next hold onto the loaded mirror lands.
        _ = try requireHeld(held(sender: "Next"), bytes: jpeg(), into: loaded, store: reopened)
    }

    /// No timer: a photo held a year ago loads exactly as it was held, and still opens.
    @Test func aHeldPhotoIsStillHeldAYearLater() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        let heldAt = Date(timeIntervalSince1970: 1_800_000_000)
        let bytes = jpeg()
        let committed = try requireHeld(held(at: heldAt), bytes: bytes, into: .empty, store: store)

        let yearLater = try loadedIndex(store, now: heldAt.addingTimeInterval(366 * 24 * 60 * 60))

        #expect(yearLater.photos == committed.photos)
        #expect(store.imageData(for: try #require(yearLater.photos.first)) == bytes)
    }

    /// Delete-all's seam removes the whole corpus directory, keylessly.
    @Test func purgeAllRemovesTheWholeCorpus() throws {
        let directory = makeDirectory()
        defer { cleanUp(directory) }
        let store = PendingSessionPhotoStore(directory: directory, keyProvider: InMemoryPrivateMediaKeyProvider())
        _ = try requireHeld(held(), bytes: jpeg(), into: .empty, store: store)

        let locked = PendingSessionPhotoStore(directory: directory, keyProvider: NoMediaKeyProvider())
        #expect(locked.purgeAll())
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(store.load(now: Date()) == .loaded(.empty))
        #expect(locked.purgeAll(), "purging an absent corpus is success")
    }
}
