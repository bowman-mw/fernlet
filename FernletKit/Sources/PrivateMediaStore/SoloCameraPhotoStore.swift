import Foundation
import FernletCrypto
import FernletFoundation

// MARK: - Index model

/// One photo taken with the disposable camera on your own: when it was taken, when it shows, and
/// when it was first shown.
///
/// The unit of ``SoloCameraIndex`` (World build; owner 2026-10-24: alone, ten photos a day, no
/// Develop step, and the photos appear after the companion sleeps). `revealsAt` is fixed at capture
/// from the sleep window the app had then, so moving the bedtime later never hides a photo again;
/// `revealedAt` is the "marked visible" stamp ``SoloCameraPhotoStore/reveal(asOf:)`` writes once a
/// photo is due, so a clock set back afterwards never hides it either.
///
/// Frozen at rest: `id`, `takenAt`, `revealsAt`, `revealedAt` and `isFavorite` are field names of
/// the sealed index.
///
/// Concurrency: a `Sendable` value type.
public nonisolated struct SoloCameraPhoto: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// Stable identity; also the name of the photo's sealed files (`<id>.jpg`).
    public let id: UUID
    /// When the shutter fired (this phone's clock).
    public let takenAt: Date
    /// When the photo starts to show: the first time the companion falls asleep after the shot.
    public let revealsAt: Date
    /// When the photo was first marked visible; nil while it is still held.
    public var revealedAt: Date?
    /// Whether this is its day's favorite (the "Just you" set's cover); nil when it is not.
    public var isFavorite: Bool?

    /// Creates a photo entry.
    public init(id: UUID = UUID(), takenAt: Date, revealsAt: Date, revealedAt: Date? = nil, isFavorite: Bool? = nil) {
        self.id = id
        self.takenAt = takenAt
        self.revealsAt = revealsAt
        self.revealedAt = revealedAt
        self.isFavorite = isFavorite
    }

    /// Whether the photo shows at `now`: already marked visible, or due.
    public func isVisible(at now: Date) -> Bool {
        revealedAt != nil || now >= revealsAt
    }
}

/// The disposable camera's film for one local day: which day it counts and how many shots it used.
///
/// A counter, not a count of the photos on disk: deleting a photo never gives its film back, as on a
/// real disposable camera. Kept inside the sealed index (never `UserDefaults`), so it is sealed,
/// device-only and wiped with the photos.
///
/// Frozen at rest: `dayKey` and `used` are field names of the sealed index.
///
/// Concurrency: a `Sendable` value type.
public nonisolated struct SoloCameraFilm: Codable, Equatable, Sendable {
    /// The local day the count belongs to (`FernletDate.dayKey(for:)`, `yyyy-MM-dd`).
    public let dayKey: String
    /// Shots used that day.
    public let used: Int

    /// Creates a film record.
    public init(dayKey: String, used: Int) {
        self.dayKey = dayKey
        self.used = used
    }

    /// Shots used on `dayKey`: the count when it is this record's day, else 0 (a new day's film).
    public func used(on dayKey: String) -> Int {
        self.dayKey == dayKey ? max(0, used) : 0
    }
}

/// The solo camera corpus's durable truth: every photo and the day's film count, sealed at rest as
/// `SoloCameraIndex.sealed`.
///
/// Frozen at rest: `schemaVersion`, `photos` and `film` are field names, and ``schemaVersion`` only
/// ever rises — an older build reading a newer file defers rather than purging it.
///
/// Concurrency: a `Sendable` value type.
public nonisolated struct SoloCameraIndex: Codable, Equatable, Sendable {
    /// The format this build writes and the only one it reads.
    public static let schemaVersion = 1
    /// An index with no photos and no film used — what an absent file means.
    public static let empty = SoloCameraIndex(photos: [], film: nil)

    /// The format version of this value (see the static ``schemaVersion``).
    public var schemaVersion: Int
    /// Every photo, newest first. At most ``SoloCameraPhotoStore/maxPhotos``.
    public var photos: [SoloCameraPhoto]
    /// The latest day's film count; nil before the first shot.
    public var film: SoloCameraFilm?

    /// Creates an index in the current format.
    public init(photos: [SoloCameraPhoto], film: SoloCameraFilm?) {
        self.schemaVersion = Self.schemaVersion
        self.photos = photos
        self.film = film
    }

    /// Shots used on `dayKey` (0 on a day with no film record).
    public func used(on dayKey: String) -> Int {
        film?.used(on: dayKey) ?? 0
    }

    /// The photos that show at `now`, newest first.
    public func visible(at now: Date) -> [SoloCameraPhoto] {
        photos.filter { $0.isVisible(at: now) }.sorted { $0.takenAt > $1.takenAt }
    }
}

// MARK: - Store

/// The sealed corpus of photos taken with the disposable camera on your own (World build; owner
/// 2026-10-24: "I think the photos can be saved in the friend area"). No session, no review, no
/// Develop step: each shot is sealed the moment it is taken and held until the companion's sleep.
///
/// Built on the pattern of ``PendingSessionPhotoStore`` — the corpus today's session camera writes —
/// because it wants the same custody: its own directory and its own born-device-bound key
/// (``KeychainPrivateMediaKeyProvider/Role/soloCameraPhotos``), excluded from the device backup,
/// never escrowed, never synced, never exported, never handed to the AI or the app group. It shares
/// the wall's file machinery (bomb checks, thumbnails, orphan sweep) through `FriendPhotoCorpusFiles`.
/// Deliberately NOT one of the own-photo corpora (``OwnPhotoCorpusLayout``): those are minted
/// backup-restorable and escrowed, and their format pass and binding gate enumerate a fixed set.
///
/// ## Layout (every name a frozen token)
///
/// ```
/// <proximitySupportDirectory>/SoloCameraPhotos/     isExcludedFromBackup = true
///     Photos/<id>.jpg                               FMA2 box, privateSoloCameraPhotoImageV1
///     Thumbnails/<id>.jpg                           FMA2 box, privateSoloCameraPhotoThumbnailV1
///     SoloCameraIndex.sealed                        FMA2 box, privateSoloCameraIndexV1
/// ```
///
/// ## Fail-closed rules (the pending corpus's)
///
/// - No key: nothing is written. An index that cannot be read right now is ``Load/deferred(_:)``
///   and is never written over.
/// - **Purge only on an AEAD failure** under a present key (corruption, or the duress wipe's
///   crypto-erase followed by a fresh key): the bytes can never open again, so the corpus goes.
/// - A file that opens but does not decode (another `schemaVersion`) is never written or purged.
/// - Every write re-reads the index from disk first, so two callers never clobber each other's
///   photos with a stale copy, and every write it makes reads back by construction.
/// - Born sealed: planted plaintext reads as missing. The film count lives in the sealed index.
/// - Bounded: at most ``maxPhotos`` photos; a shot past it is refused, never an eviction.
///
/// Concurrency: a plain value type over `FileManager`; confined to its owner's isolation (the app's
/// main actor), because the default key provider caches its key without synchronization.
public struct SoloCameraPhotoStore {
    /// Hard cap on photos kept: a year of full film. A shot past it is refused (``Add/full``).
    public static let maxPhotos = 3_650
    /// The largest index file this store opens (a full index is well under a megabyte).
    static let maxIndexFileBytes = 4 * 1_024 * 1_024

    /// The corpus directory's name under the proximity support directory. Frozen token.
    public static let directoryName = "SoloCameraPhotos"
    /// Full-size files' subdirectory. Frozen token.
    public static let photosDirectoryName = "Photos"
    /// Thumbnails' subdirectory. Frozen token.
    public static let thumbnailsDirectoryName = "Thumbnails"
    /// The sealed index's file name. Frozen token.
    public static let indexFileName = "SoloCameraIndex.sealed"

    private static let indexPurpose = FernletCryptoPurpose.AEAD.privateSoloCameraIndexV1

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
        /// The index (an absent file is ``SoloCameraIndex/empty``), unindexed files swept.
        case loaded(SoloCameraIndex)
        /// Not readable by this build right now. Never written over, never purged.
        case deferred(Deferral)
        /// Key present, bytes do not open. The corpus was removed (`purged`), or its removal failed.
        case unrecoverable(purged: Bool)
    }

    /// What ``add(_:imageData:filmDay:dailyLimit:)`` did.
    public enum Add: Equatable, Sendable {
        /// Bytes, thumbnail and index are on disk; the committed index.
        case added(SoloCameraIndex)
        /// The day's film is used up. Nothing written.
        case noFilmLeft
        /// ``maxPhotos`` are kept. Nothing written, nothing evicted.
        case full
        /// The bytes are over the size cap or outside the pixel bounds. Nothing written.
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
    ///   - keyProvider: The at-rest key; defaults to the device-bound solo-camera row. Tests inject an
    ///     in-memory one.
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
            imagePurpose: FernletCryptoPurpose.AEAD.privateSoloCameraPhotoImageV1,
            thumbnailPurpose: FernletCryptoPurpose.AEAD.privateSoloCameraPhotoThumbnailV1,
            allowsLegacyPlaintext: false,
            keyProvider: keyProvider,
            auditCorpus: "soloCameraPhotos"
        )
    }

    /// Delete-all seam: drops the provider-cached key so RAM matches the keychain.
    public func invalidateEncryptionKeyCache() {
        keyProvider.invalidateCachedKey()
    }

    // MARK: Load

    /// Reads and classifies the index (see ``Load``). Sweeps files the index does not name (a kill
    /// between a shot's byte write and its index write).
    public func load() -> Load {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            files.removeOrphanedFiles(keeping: [])
            return .loaded(.empty)
        }
        let stored: Data
        do {
            stored = try Data(contentsOf: indexURL)
        } catch {
            FernletAuditLog.log("privateMedia.soloIndexDeferred", context: ["reason": "fileUnreadable"])
            return .deferred(.fileUnreadable)
        }
        guard stored.count <= Self.maxIndexFileBytes else {
            FernletAuditLog.log("privateMedia.soloIndexDeferred", context: ["reason": "oversize"])
            return .deferred(.unsupportedFormat)
        }
        guard keyProvider.mediaKey() != nil else { return .deferred(.noKey) }
        guard let opened = keyProvider.gcmOpen(stored, purpose: Self.indexPurpose) else {
            let purged = purgeAll()
            FernletAuditLog.log("privateMedia.soloIndexUnrecoverable", context: ["purged": "\(purged)"])
            return .unrecoverable(purged: purged)
        }
        guard let index = decodedIndex(opened) else {
            FernletAuditLog.log("privateMedia.soloIndexDeferred", context: ["reason": "unsupportedFormat"])
            return .deferred(.unsupportedFormat)
        }
        files.removeOrphanedFiles(keeping: Set(index.photos.map(\.id)))
        return .loaded(index)
    }

    /// Decodes an opened index, or nil when it is not exactly this build's format or holds more
    /// photos than this store ever writes.
    private func decodedIndex(_ opened: Data) -> SoloCameraIndex? {
        guard let probe = try? decoder.decode(SchemaProbe.self, from: opened),
              probe.schemaVersion == SoloCameraIndex.schemaVersion,
              let index = try? decoder.decode(SoloCameraIndex.self, from: opened),
              index.photos.count <= Self.maxPhotos else { return nil }
        return index
    }

    /// The one field every generation of the index is required to carry.
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    /// The index a write builds on, read afresh from disk — or the refusal when there is none. A
    /// corpus the load just purged (it could never open again) starts empty.
    private func writeBase() -> Result<SoloCameraIndex, Refusal> {
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

    /// Keeps one shot: checks the day's film, seals the bytes and thumbnail FIRST, then writes the
    /// index with the photo added and one more shot used on `filmDay`. On an index write failure the
    /// two just-written files are removed and ``Add/notPersisted`` comes back (no film is used).
    ///
    /// - Parameters:
    ///   - photo: The entry (its id names the files).
    ///   - imageData: The normalized JPEG.
    ///   - filmDay: The local day the shot counts against (`FernletDate.dayKey(for:)`).
    ///   - dailyLimit: Shots allowed per local day (the app's rule, ten).
    public func add(_ photo: SoloCameraPhoto, imageData: Data, filmDay: String, dailyLimit: Int) -> Add {
        guard dailyLimit > 0, !filmDay.isEmpty else { return .noFilmLeft }
        let index: SoloCameraIndex
        switch writeBase() {
        case .success(let base): index = base
        case .failure(let refusal): return refusal.add
        }
        let used = index.used(on: filmDay)
        guard used < dailyLimit else { return .noFilmLeft }
        guard index.photos.count < Self.maxPhotos else { return .full }
        guard !index.photos.contains(where: { $0.id == photo.id }) else { return .notPersisted }
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
        // A new shot is never marked visible yet, whatever the caller passed.
        next.photos.append(SoloCameraPhoto(id: photo.id, takenAt: photo.takenAt, revealsAt: photo.revealsAt))
        next.photos.sort { $0.takenAt > $1.takenAt }
        next.film = SoloCameraFilm(dayKey: filmDay, used: used + 1)
        guard let committed = writeIndex(next) else {
            files.removeFiles(for: photo.id)
            return .notPersisted
        }
        return .added(committed)
    }

    /// Marks every photo due at `now` visible (``SoloCameraPhoto/revealedAt``), in one sealed write.
    ///
    /// - Returns: whether every due photo is now marked (true when none was due). False when the
    ///   index cannot be read right now or the write failed — the photos still show by their
    ///   `revealsAt`, and a later call marks them.
    public func reveal(asOf now: Date) -> Bool {
        guard case .loaded(var index) = load() else { return false }
        var changed = false
        // R2: bounded by the photo cap.
        for position in index.photos.indices where index.photos[position].revealedAt == nil
            && now >= index.photos[position].revealsAt {
            index.photos[position].revealedAt = now
            changed = true
        }
        guard changed else { return true }
        return prepareDirectory() && writeIndex(index) != nil
    }

    /// Makes `id` the favorite among `ids` (one day's set) and clears the others, in one sealed write;
    /// nil clears them all.
    ///
    /// - Returns: whether the index now says so (true when nothing had to change).
    public func setFavorite(_ id: UUID?, among ids: Set<UUID>) -> Bool {
        guard case .success(var index) = writeBase() else { return false }
        var changed = false
        // R2: bounded by the photo cap.
        for position in index.photos.indices where ids.contains(index.photos[position].id) {
            let wanted: Bool? = index.photos[position].id == id ? true : nil
            guard index.photos[position].isFavorite != wanted else { continue }
            index.photos[position].isFavorite = wanted
            changed = true
        }
        guard changed else { return true }
        return prepareDirectory() && writeIndex(index) != nil
    }

    /// Deletes one photo: the index entry first, then its files. The day's film is not given back.
    ///
    /// - Returns: whether the photo is gone (true when it was never here).
    public func delete(id: UUID) -> Bool {
        guard case .success(var index) = writeBase() else { return false }
        guard index.photos.contains(where: { $0.id == id }) else {
            files.removeFiles(for: id)
            return true
        }
        index.photos.removeAll { $0.id == id }
        guard prepareDirectory(), writeIndex(index) != nil else { return false }
        files.removeFiles(for: id)
        return true
    }

    // MARK: Reads

    /// A photo's full-size plaintext, or nil (no key, missing, unopenable, unreadable right now). The
    /// owner gates on visibility first: a held photo's bytes are never handed out.
    public func imageData(for id: UUID) -> Data? {
        files.imageData(forID: id)
    }

    /// A photo's thumbnail plaintext (regenerated from the full image if needed), or nil.
    public func thumbnailData(for id: UUID) -> Data? {
        files.thumbnailData(forID: id)
    }

    // MARK: Delete-all

    /// Removes the whole `SoloCameraPhotos/` directory — every photo, thumbnail, the index and the
    /// film count. Keyless: it deletes files, it never opens one.
    ///
    /// - Returns: whether the directory is gone (true when it never existed).
    public func purgeAll() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            FernletAuditLog.log("privateMedia.soloPurgeFailed", context: ["error": "\(error)"])
            return false
        }
    }

    // MARK: Disk

    /// Creates the corpus directory and its two subdirectories, and marks the corpus directory
    /// `isExcludedFromBackup` — on every call, so a directory made by any other path is covered
    /// before a photo lands in it.
    /// - Returns: false (audited) when a directory cannot be created or the flag cannot be set; the
    ///   caller then writes nothing.
    private func prepareDirectory() -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            var mutableDirectory = directory
            try mutableDirectory.setResourceValues(values)
        } catch {
            FernletAuditLog.log("privateMedia.soloDirectoryUnprepared", context: ["error": "\(error)"])
            return false
        }
        return files.createDirectories()
    }

    /// Seals and atomically writes the index. The encoded bytes are decoded back through the load's
    /// own path BEFORE anything is sealed, so a body this build could not read is never written.
    /// - Returns: the index exactly as a later load decodes it, or nil when nothing was written.
    private func writeIndex(_ index: SoloCameraIndex) -> SoloCameraIndex? {
        let data: Data
        do {
            data = try encoder.encode(index)
        } catch {
            FernletAuditLog.log("privateMedia.soloIndexWriteFailed", context: ["error": "\(error)"])
            return nil
        }
        guard let readBack = decodedIndex(data) else {
            FernletAuditLog.log("privateMedia.soloIndexWriteFailed", context: ["error": "wouldNotReadBack"])
            return nil
        }
        guard let sealed = keyProvider.gcmSeal(data, purpose: Self.indexPurpose),
              sealed.count <= Self.maxIndexFileBytes else {
            FernletAuditLog.log("privateMedia.soloIndexWriteFailed", context: ["error": "notSealed"])
            return nil
        }
        do {
            try sealed.write(to: indexURL, options: [.atomic, .completeFileProtection])
            return readBack
        } catch {
            FernletAuditLog.log("privateMedia.soloIndexWriteFailed", context: ["error": "\(error)"])
            return nil
        }
    }
}
