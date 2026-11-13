import Foundation
import FernletCrypto
import FernletFoundation

// MARK: - Index model

/// One photo on a road trip's roll (World-RoadTrip-Spec §2.7, `rt-photos`, owner-approved 2026-11-10): one this
/// iPhone took during the trip, or one a friend on the trip handed over at a catch-up.
///
/// - ``id`` is this iPhone's own id for the photo, and names its sealed files (`<id>.jpg`); a friend's photo gets a
///   fresh one on arrival, so two people's ids can never collide on disk.
/// - ``authorID`` is who took it (the trip member's stable id, this iPhone's own for its photos) and ``sourceID`` its
///   id on their phone: the pair is how a photo is recognised again at a later catch-up (dedupe), and the only id a
///   friend is ever told (``RoadTripPhotoIndex/sourceIDs(trip:author:)``).
/// - ``isHidden``: "Hide from the map" (any trip photo, a friend's or this iPhone's).
///
/// Frozen at rest: `id`, `tripID`, `authorID`, `sourceID`, `takenAt` and `isHidden` are field names of the sealed
/// index. Concurrency: a `Sendable` value type.
public nonisolated struct RoadTripPhoto: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The longest author id kept (a member id is a 16-character fingerprint).
    public static let maxAuthorIDLength = 128

    /// This iPhone's id for the photo; also the name of its sealed files.
    public let id: UUID
    /// The road trip it was taken on.
    public let tripID: UUID
    /// Who took it: the member's stable id.
    public let authorID: String
    /// Its id on the author's phone (the same as ``id`` for this iPhone's own photos).
    public let sourceID: UUID
    /// When the shutter fired (the author's clock).
    public let takenAt: Date
    /// Whether it is hidden from the map; nil when it is not.
    public var isHidden: Bool?

    /// Creates an entry.
    public init(id: UUID = UUID(), tripID: UUID, authorID: String, sourceID: UUID, takenAt: Date, isHidden: Bool? = nil) {
        self.id = id
        self.tripID = tripID
        self.authorID = authorID
        self.sourceID = sourceID
        self.takenAt = takenAt
        self.isHidden = isHidden
    }

    /// Whether its fields are within their bounds.
    public var isValid: Bool {
        !authorID.isEmpty && authorID.count <= Self.maxAuthorIDLength && takenAt.timeIntervalSince1970.isFinite
    }

    /// Whether it shows on the map (not hidden).
    public var isShown: Bool { isHidden != true }
}

/// The trip photos' durable truth, sealed at rest as `RoadTripPhotoIndex.sealed`: every photo, oldest first.
///
/// Frozen at rest: `schemaVersion` and `photos` are field names, and `schemaVersion` only ever rises — an older
/// build reading a newer file defers rather than purging it. Concurrency: a `Sendable` value type.
public nonisolated struct RoadTripPhotoIndex: Codable, Equatable, Sendable {
    /// The format this build writes and the only one it reads.
    public static let schemaVersion = 1
    /// An index with no photos — what an absent file means.
    public static let empty = RoadTripPhotoIndex(photos: [])

    /// The format version of this value (see the static ``schemaVersion``).
    public var schemaVersion: Int
    /// Every photo, oldest first. At most ``RoadTripPhotoStore/maxPhotos``.
    public var photos: [RoadTripPhoto]

    /// Creates an index in the current format.
    public init(photos: [RoadTripPhoto]) {
        self.schemaVersion = Self.schemaVersion
        self.photos = photos
    }

    /// The photos of trip `trip`, oldest first.
    public func photos(of trip: UUID) -> [RoadTripPhoto] {
        photos.filter { $0.tripID == trip }
    }

    /// How many photos of trip `trip` `author` took that this iPhone holds.
    public func count(trip: UUID, author: String) -> Int {
        photos.lazy.filter { $0.tripID == trip && $0.authorID == author }.count
    }

    /// The ids (on `author`'s phone) of the photos of trip `trip` they took that this iPhone holds: what a catch-up
    /// tells them, so they send only the ones missing.
    public func sourceIDs(trip: UUID, author: String) -> [UUID] {
        photos.filter { $0.tripID == trip && $0.authorID == author }.map(\.sourceID)
    }

    /// Whether this iPhone holds `author`'s photo `sourceID` of trip `trip`.
    public func holds(trip: UUID, author: String, sourceID: UUID) -> Bool {
        photos.contains { $0.tripID == trip && $0.authorID == author && $0.sourceID == sourceID }
    }
}

// MARK: - Store

/// The sealed corpus of road trip photos (World-RoadTrip-Spec PR 3, owner-approved 2026-11-10: "During a trip, Home's
/// camera puts photos on the trip's roll, up to 30 per person"; friends' trip photos arrive at catch-ups and go
/// straight onto the map). The trip's roll, apart from the solo daily roll: no film per day, no hold until the
/// companion sleeps.
///
/// Built on ``SoloCameraPhotoStore``'s pattern because it wants the same custody, and **sealed under the same
/// device-bound key row** (``KeychainPrivateMediaKeyProvider/Role/soloCameraPhotos``): excluded from the device
/// backup, never escrowed, never synced, never exported, never handed to the AI or the app group. Its own three AEAD
/// purposes keep it apart from every other corpus (`AEAD.privateRoadTripPhoto{Image,Thumbnail,Index}V1`), and
/// sharing the row means the duress silent wipe's sweep of `com.fernlet.private-media` crypto-erases it with the
/// solo corpus. It shares the wall's file machinery (bomb checks, thumbnails, orphan sweep) through
/// `FriendPhotoCorpusFiles`. Where each photo was taken is NOT here: it is map data, in the map's vault (the app's
/// `PhotoPlaceStore` over `road-trip-photo-places.bin`), deleted with map history.
///
/// ## Layout (every name a frozen token)
///
/// ```
/// <proximitySupportDirectory>/RoadTripPhotos/       isExcludedFromBackup = true
///     Photos/<id>.jpg                               FMA2 box, privateRoadTripPhotoImageV1
///     Thumbnails/<id>.jpg                           FMA2 box, privateRoadTripPhotoThumbnailV1
///     RoadTripPhotoIndex.sealed                     FMA2 box, privateRoadTripPhotoIndexV1
/// ```
///
/// ## Rules
///
/// - **Bounded** (Power of 10): at most `perAuthor` photos per person per trip and `perTrip` per trip (the app's
///   30 and 150), and ``maxPhotos`` in all; a photo past any of them is refused, never an eviction.
/// - **Once:** a second copy of an author's photo (same trip, author and ``RoadTripPhoto/sourceID``) is refused as
///   ``Add/duplicate``, so a transfer sent again at a later catch-up lands once.
/// - **Fail-closed** like the solo corpus: no key, nothing written; an index that can't be read right now is
///   ``Load/deferred(_:)`` and never written over; it is purged only on an AEAD failure under a present key; every
///   write re-reads the index first; born sealed (planted plaintext reads as missing).
///
/// Concurrency: a plain value type over `FileManager`; confined to its owner's isolation (the app's main actor),
/// because the default key provider caches its key without synchronization.
public struct RoadTripPhotoStore {
    /// Hard cap on photos kept, across every trip.
    public static let maxPhotos = 3_000
    /// The largest index file this store opens (a full index is well under a megabyte).
    static let maxIndexFileBytes = 4 * 1_024 * 1_024

    /// The corpus directory's name under the proximity support directory. Frozen token.
    public static let directoryName = "RoadTripPhotos"
    /// Full-size files' subdirectory. Frozen token.
    public static let photosDirectoryName = "Photos"
    /// Thumbnails' subdirectory. Frozen token.
    public static let thumbnailsDirectoryName = "Thumbnails"
    /// The sealed index's file name. Frozen token.
    public static let indexFileName = "RoadTripPhotoIndex.sealed"

    private static let indexPurpose = FernletCryptoPurpose.AEAD.privateRoadTripPhotoIndexV1

    /// Why a load could not produce an index this build may write over.
    public enum Deferral: Equatable, Sendable {
        /// The index exists and no key is available right now.
        case noKey
        /// The index file exists and cannot be read (locked device, I/O error).
        case fileUnreadable
        /// The index opened but is not this build's format, or is larger than any index it writes.
        case unsupportedFormat
    }

    /// What ``load()`` found.
    public enum Load: Equatable, Sendable {
        /// The index (an absent file is ``RoadTripPhotoIndex/empty``), unindexed files swept.
        case loaded(RoadTripPhotoIndex)
        /// Not readable by this build right now. Never written over, never purged.
        case deferred(Deferral)
        /// Key present, bytes do not open. The corpus was removed (`purged`), or its removal failed.
        case unrecoverable(purged: Bool)
    }

    /// What ``add(_:imageData:perAuthor:perTrip:)`` did.
    public enum Add: Equatable, Sendable {
        /// Bytes, thumbnail and index are on disk; the committed index.
        case added(RoadTripPhotoIndex)
        /// The author already has this photo here. Nothing written.
        case duplicate
        /// The author's roll for the trip is full. Nothing written.
        case authorFull
        /// The trip is full, or ``maxPhotos`` are kept. Nothing written, nothing evicted.
        case full
        /// The bytes are over the size cap or outside the pixel bounds, or the entry is invalid. Nothing written.
        case unsafeImage
        /// No key, a directory or backup-exclusion failure, or a failed write. Nothing kept.
        case notPersisted
        /// The index cannot be read right now; nothing is written over it.
        case deferred(Deferral)
    }

    private let directory: URL
    private let indexURL: URL
    private let files: FriendPhotoCorpusFiles
    private let keyProvider: PrivateMediaKeyProviding
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// The corpus directory under a proximity support root (production: `Application Support/Fernlet`).
    public static func directory(in proximitySupportDirectory: URL) -> URL {
        proximitySupportDirectory.appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Creates a store over `directory` (built with ``directory(in:)``).
    ///
    /// - Parameters:
    ///   - directory: The corpus directory; created (and excluded from backup) on the first write.
    ///   - keyProvider: The at-rest key; defaults to the device-bound solo-camera row. Tests inject an in-memory one.
    public init(
        directory: URL,
        keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider(role: .soloCameraPhotos)
    ) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent(Self.indexFileName)
        self.keyProvider = keyProvider
        self.files = FriendPhotoCorpusFiles(
            imageDirectoryURL: directory.appendingPathComponent(Self.photosDirectoryName, isDirectory: true),
            thumbnailDirectoryURL: directory.appendingPathComponent(Self.thumbnailsDirectoryName, isDirectory: true),
            imagePurpose: FernletCryptoPurpose.AEAD.privateRoadTripPhotoImageV1,
            thumbnailPurpose: FernletCryptoPurpose.AEAD.privateRoadTripPhotoThumbnailV1,
            allowsLegacyPlaintext: false,
            keyProvider: keyProvider,
            auditCorpus: "roadTripPhotos"
        )
    }

    /// Delete-all seam: drops the provider-cached key so RAM matches the keychain.
    public func invalidateEncryptionKeyCache() {
        keyProvider.invalidateCachedKey()
    }

    // MARK: Load

    /// Reads and classifies the index (see ``Load``). Sweeps files the index does not name (a kill between a
    /// photo's byte write and its index write).
    public func load() -> Load {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            files.removeOrphanedFiles(keeping: [])
            return .loaded(.empty)
        }
        let stored: Data
        do {
            stored = try Data(contentsOf: indexURL)
        } catch {
            FernletAuditLog.log("privateMedia.roadTripIndexDeferred", context: ["reason": "fileUnreadable"])
            return .deferred(.fileUnreadable)
        }
        guard stored.count <= Self.maxIndexFileBytes else {
            FernletAuditLog.log("privateMedia.roadTripIndexDeferred", context: ["reason": "oversize"])
            return .deferred(.unsupportedFormat)
        }
        guard keyProvider.mediaKey() != nil else { return .deferred(.noKey) }
        guard let opened = keyProvider.gcmOpen(stored, purpose: Self.indexPurpose) else {
            let purged = purgeAll()
            FernletAuditLog.log("privateMedia.roadTripIndexUnrecoverable", context: ["purged": "\(purged)"])
            return .unrecoverable(purged: purged)
        }
        guard let index = decodedIndex(opened) else {
            FernletAuditLog.log("privateMedia.roadTripIndexDeferred", context: ["reason": "unsupportedFormat"])
            return .deferred(.unsupportedFormat)
        }
        files.removeOrphanedFiles(keeping: Set(index.photos.map(\.id)))
        return .loaded(index)
    }

    /// Decodes an opened index, or nil when it is not exactly this build's format, holds more photos than this
    /// store ever writes, or holds an entry out of its bounds.
    private func decodedIndex(_ opened: Data) -> RoadTripPhotoIndex? {
        guard let probe = try? decoder.decode(SchemaProbe.self, from: opened),
              probe.schemaVersion == RoadTripPhotoIndex.schemaVersion,
              let index = try? decoder.decode(RoadTripPhotoIndex.self, from: opened),
              index.photos.count <= Self.maxPhotos, index.photos.allSatisfy(\.isValid) else { return nil }
        return index
    }

    /// The one field every generation of the index is required to carry.
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    /// The index a write builds on, read afresh from disk — or the refusal when there is none. A corpus the load
    /// just purged (it could never open again) starts empty.
    private func writeBase() -> Result<RoadTripPhotoIndex, Refusal> {
        switch load() {
        case .loaded(let index): return .success(index)
        case .unrecoverable(purged: true): return .success(.empty)
        case .unrecoverable(purged: false): return .failure(Refusal(add: .notPersisted))
        case .deferred(let deferral): return .failure(Refusal(add: .deferred(deferral)))
        }
    }

    /// A write refused before anything was touched, carried as the ``Add`` it answers.
    private struct Refusal: Error {
        let add: Add
    }

    // MARK: Writes

    /// Keeps one photo: checks the bounds and the dedupe, seals the bytes and thumbnail FIRST, then writes the index
    /// with the photo added. On an index write failure the two just-written files are removed.
    ///
    /// - Parameters:
    ///   - photo: The entry (its id names the files).
    ///   - imageData: The normalized JPEG (this iPhone's) or the verified bytes a friend sent.
    ///   - perAuthor: The most photos one person may have on one trip's roll here (the app's 30).
    ///   - perTrip: The most photos one trip may have here (the app's 150).
    public func add(_ photo: RoadTripPhoto, imageData: Data, perAuthor: Int, perTrip: Int) -> Add {
        guard photo.isValid, perAuthor > 0, perTrip > 0 else { return .unsafeImage }
        let index: RoadTripPhotoIndex
        switch writeBase() {
        case .success(let base): index = base
        case .failure(let refusal): return refusal.add
        }
        if let refusal = refusal(adding: photo, to: index, perAuthor: perAuthor, perTrip: perTrip) { return refusal }
        guard FriendPhotoCorpusFiles.isSafeToStore(imageData) else { return .unsafeImage }
        guard keyProvider.mediaKey() != nil, prepareDirectory() else { return .notPersisted }
        switch files.writeSealedImage(imageData, for: photo.id) {
        case .written:
            break
        case .refusedUnsafe:
            return .unsafeImage
        case .notWritten:
            files.removeFiles(for: photo.id)
            return .notPersisted
        }
        var next = index
        next.photos.append(photo)
        next.photos.sort { $0.takenAt < $1.takenAt }
        guard let committed = writeIndex(next) else {
            files.removeFiles(for: photo.id)
            return .notPersisted
        }
        return .added(committed)
    }

    /// Why `photo` may not join `index`, or nil when it may.
    private func refusal(adding photo: RoadTripPhoto, to index: RoadTripPhotoIndex, perAuthor: Int, perTrip: Int) -> Add? {
        if index.holds(trip: photo.tripID, author: photo.authorID, sourceID: photo.sourceID) { return .duplicate }
        if index.photos.contains(where: { $0.id == photo.id }) { return .notPersisted }
        if index.count(trip: photo.tripID, author: photo.authorID) >= perAuthor { return .authorFull }
        if index.photos.count >= Self.maxPhotos || index.photos(of: photo.tripID).count >= perTrip { return .full }
        return nil
    }

    /// Hides photo `id` from the map, or shows it again (`hidden` false), in one sealed write.
    ///
    /// - Returns: whether the index now says so (false when the photo isn't here or the write failed).
    public func setHidden(_ id: UUID, _ hidden: Bool) -> Bool {
        guard case .success(var index) = writeBase(),
              let position = index.photos.firstIndex(where: { $0.id == id }) else { return false }
        let wanted: Bool? = hidden ? true : nil
        guard index.photos[position].isHidden != wanted else { return true }
        index.photos[position].isHidden = wanted
        return prepareDirectory() && writeIndex(index) != nil
    }

    /// Deletes the photos in `ids`: the index entries first, then their files.
    ///
    /// - Returns: whether they are gone (true when none was here).
    public func delete(_ ids: Set<UUID>) -> Bool {
        guard case .success(var index) = writeBase() else { return false }
        let before = index.photos.count
        index.photos.removeAll { ids.contains($0.id) }
        if index.photos.count != before {
            guard prepareDirectory(), writeIndex(index) != nil else { return false }
        }
        // R2: bounded by the photo cap (the caller passes ids it read from the index).
        for id in ids.prefix(Self.maxPhotos) { files.removeFiles(for: id) }
        return true
    }

    // MARK: Reads

    /// A photo's full-size plaintext, or nil (no key, missing, unopenable, unreadable right now).
    public func imageData(for id: UUID) -> Data? {
        files.imageData(forID: id)
    }

    /// A photo's thumbnail plaintext (regenerated from the full image if needed), or nil.
    public func thumbnailData(for id: UUID) -> Data? {
        files.thumbnailData(forID: id)
    }

    // MARK: Delete-all

    /// Removes the whole `RoadTripPhotos/` directory — every photo, thumbnail and the index (with every hidden
    /// flag). Keyless: it deletes files, it never opens one.
    ///
    /// - Returns: whether the directory is gone (true when it never existed).
    public func purgeAll() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            FernletAuditLog.log("privateMedia.roadTripPurgeFailed", context: ["error": "\(error)"])
            return false
        }
    }

    // MARK: Disk

    /// Creates the corpus directory and its two subdirectories, and marks the corpus directory
    /// `isExcludedFromBackup` — on every call, so a directory made by any other path is covered before a photo
    /// lands in it.
    /// - Returns: false (audited) when a directory cannot be created or the flag cannot be set; the caller then
    ///   writes nothing.
    private func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(values)
        } catch {
            FernletAuditLog.log("privateMedia.roadTripDirectoryUnprepared", context: ["error": "\(error)"])
            return false
        }
        return files.createDirectories()
    }

    /// Seals and atomically writes the index. The encoded bytes are decoded back through the load's own path
    /// BEFORE anything is sealed, so a body this build could not read is never written.
    /// - Returns: the index exactly as a later load decodes it, or nil when nothing was written.
    private func writeIndex(_ index: RoadTripPhotoIndex) -> RoadTripPhotoIndex? {
        let data: Data
        do {
            data = try encoder.encode(index)
        } catch {
            FernletAuditLog.log("privateMedia.roadTripIndexWriteFailed", context: ["error": "\(error)"])
            return nil
        }
        guard let readBack = decodedIndex(data) else {
            FernletAuditLog.log("privateMedia.roadTripIndexWriteFailed", context: ["error": "wouldNotReadBack"])
            return nil
        }
        guard let sealed = keyProvider.gcmSeal(data, purpose: Self.indexPurpose),
              sealed.count <= Self.maxIndexFileBytes else {
            FernletAuditLog.log("privateMedia.roadTripIndexWriteFailed", context: ["error": "notSealed"])
            return nil
        }
        do {
            try sealed.write(to: indexURL, options: [.atomic, .completeFileProtection])
            return readBack
        } catch {
            FernletAuditLog.log("privateMedia.roadTripIndexWriteFailed", context: ["error": "\(error)"])
            return nil
        }
    }
}
