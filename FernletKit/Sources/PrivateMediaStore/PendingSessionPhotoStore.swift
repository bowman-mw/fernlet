import Foundation
import FernletCrypto
import FernletDomainModel
import FernletFoundation

// MARK: - Index model

/// Who minted a held photo and the id they chose — the identity every dedup, tombstone and routed
/// refusal keys on.
///
/// `origin` is the transport-verified origin fingerprint (this device's own for a capture, the
/// signed `manifest.originFingerprint` for a routed photo) and `itemID` is the origin's item id.
/// The store-side twin of ProximityKit's `MeshContentKey`, which this module cannot import (the
/// dependency graph runs ProximityKit → PrivateMediaStore).
///
/// Why not the photo id alone: a manifest publishes its item id to the whole roster before
/// delivery, and nothing refuses a duplicate id from a second origin, so a member can mint an item
/// carrying another member's photo id. Keyed by origin AND id, the copy can neither make the
/// genuine photo look "already held" nor get it tombstoned.
///
/// Frozen at rest: `origin` and `itemID` are field names of the sealed index.
///
/// Concurrency: an immutable `Sendable` value.
public nonisolated struct HeldPhotoKey: Codable, Hashable, Sendable {
    /// The origin's fingerprint.
    public let origin: String
    /// The origin's item id.
    public let itemID: UUID

    /// Creates a key.
    public init(origin: String, itemID: UUID) {
        self.origin = origin
        self.itemID = itemID
    }
}

/// One session photo held in the pending corpus, waiting for the person's answer.
///
/// Frozen at rest: `key`, `heldAt` and `payload` are field names of the sealed index.
///
/// Concurrency: an immutable `Sendable` value.
public nonisolated struct HeldSessionPhoto: Codable, Equatable, Sendable {
    /// The photo's identity (origin + item id). See ``HeldPhotoKey``.
    public let key: HeldPhotoKey
    /// This phone's clock when the photo was held. Orders the review; NEVER an expiry — no timer
    /// removes a held photo (a timer is either a silent keep or a silent discard).
    public let heldAt: Date
    /// Metadata only (`imageData == nil`). `payload.id` is the LOCAL id: equal to `key.itemID`
    /// unless the owner found that id already used by another held photo or a wall photo of a
    /// different origin, in which case it minted a fresh one at hold. Files are named by it; the
    /// review, the answer and the wall use it.
    public let payload: FriendPhotoPayload

    /// The local id — files, review selection and the wall all key on it.
    public var localID: UUID { payload.id }

    /// Creates a held photo. `payload` is stored metadata-only whatever it carries.
    public init(key: HeldPhotoKey, heldAt: Date, payload: FriendPhotoPayload) {
        self.key = key
        self.heldAt = heldAt
        self.payload = payload
    }
}

/// A tombstone: a photo that was answered (kept, discarded, or deleted from the wall) and must
/// never be held again from a re-delivery.
///
/// Deliberately records no answer kind — "never hold this again" is the whole job, and storing
/// "discarded" would keep a judgement nobody reads.
///
/// Frozen at rest: `key` and `expiresAt` are field names of the sealed index.
///
/// Concurrency: an immutable `Sendable` value.
public nonisolated struct AnsweredSessionPhoto: Codable, Equatable, Sendable {
    /// The answered photo's identity.
    public let key: HeldPhotoKey
    /// When the tombstone may go: the answer instant plus
    /// ``PendingSessionPhotoStore/answeredRetention``, comfortably past the latest instant a routed
    /// copy of the item can still be delivered (6 h ceiling + 20 min grace + skew).
    public let expiresAt: Date

    /// Creates a tombstone.
    public init(key: HeldPhotoKey, expiresAt: Date) {
        self.key = key
        self.expiresAt = expiresAt
    }
}

/// The pending corpus's durable truth: every held photo and every live tombstone, sealed at rest
/// as `PendingSessionPhotoIndex.sealed`.
///
/// The owner (`MeshNetworkManager`) keeps an in-memory mirror and passes it back into every
/// ``PendingSessionPhotoStore`` write; the store returns the committed successor. After a process
/// kill the review is rebuilt from this and nothing else.
///
/// Frozen at rest: `schemaVersion`, `photos` and `answered` are field names, and
/// ``schemaVersion`` only ever rises — an older build reading a newer file defers rather than
/// purging it (see ``PendingSessionPhotoStore/Deferral/unsupportedFormat``).
///
/// Concurrency: a `Sendable` value type.
public nonisolated struct PendingSessionPhotoIndex: Codable, Equatable, Sendable {
    /// The format this build writes and the only one it reads.
    public static let schemaVersion = 1
    /// An index with nothing held and nothing answered — what an absent file means.
    public static let empty = PendingSessionPhotoIndex(photos: [], answered: [])

    /// The format version of this value (see the static ``schemaVersion``).
    public var schemaVersion: Int
    /// Held photos, newest first by `heldAt`. At most ``PendingSessionPhotoStore/maxHeldPhotos``.
    public var photos: [HeldSessionPhoto]
    /// Live tombstones. At most ``PendingSessionPhotoStore/maxAnsweredIDs``.
    public var answered: [AnsweredSessionPhoto]

    /// Creates an index in the current format.
    public init(photos: [HeldSessionPhoto], answered: [AnsweredSessionPhoto]) {
        self.schemaVersion = Self.schemaVersion
        self.photos = photos
        self.answered = answered
    }

    /// Whether a photo with this identity is held.
    public func holds(_ key: HeldPhotoKey) -> Bool {
        photos.contains { $0.key == key }
    }

    /// Whether this identity carries a tombstone (expired ones are dropped on every load and write).
    public func isAnswered(_ key: HeldPhotoKey) -> Bool {
        answered.contains { $0.key == key }
    }

    /// The local ids of every held photo — the corpus's file manifest.
    public var heldLocalIDs: Set<UUID> {
        Set(photos.map(\.localID))
    }

    /// The held photo with this local id, if any.
    public func heldPhoto(localID: UUID) -> HeldSessionPhoto? {
        photos.first { $0.localID == localID }
    }
}

// MARK: - Store

/// The sealed corpus of session photos nobody has chosen yet — held from the moment they exist
/// (captured here or received from a peer) until the person answers the review, and NEVER the
/// friend wall.
///
/// Why a corpus of its own rather than a flag on wall entries: the wall's index is its file
/// manifest with a FIFO cap (a pending photo could evict a kept one, or be evicted unseen), every
/// wall reader would need a filter, the wall key and files are backup-restorable by product
/// decision, and delete-all keeps the wall. None of that is right for photos nobody chose.
///
/// ## Layout (every name a frozen token)
///
/// ```
/// <proximitySupportDirectory>/PendingSessionPhotos/     isExcludedFromBackup = true
///     Photos/<localID>.jpg                              FMA2 box, privatePendingSessionPhotoImageV1
///     Thumbnails/<localID>.jpg                          FMA2 box, privatePendingSessionPhotoThumbnailV1
///     PendingSessionPhotoIndex.sealed                   FMA2 box, privatePendingSessionPhotoIndexV1
/// ```
///
/// A subdirectory, never siblings of `MeshPhotos/`: each store sweeps orphans by directory, so a
/// sibling corpus would be swept by the other's save.
///
/// ## Fail-closed rules
///
/// - No key: nothing is written (the seal returns nil).
/// - An index that exists but cannot be read (no key, or a file read error) is
///   ``Load/deferred(_:)`` and is never written over by this store's contract: the owner must not
///   pass a mirror derived from a deferred load into a write.
/// - **Purge only on an AEAD failure.** Read, key present, bytes do not open: corruption or a
///   duress-swept key, so the corpus is removed at once (``Load/unrecoverable(purged:)``).
/// - **A file that opens but does not decode is never purged.** An opened file was written by a
///   Fernlet build; a different `schemaVersion` (an older TestFlight build over a newer one) or an
///   undecodable body is ``Deferral/unsupportedFormat``: never written, never purged.
/// - Every clean load sweeps files the index does not name (a kill between a hold's byte write and
///   its index write).
/// - Born sealed: no legacy-plaintext branch; planted plaintext reads as missing.
/// - The decompression-bomb checks run on every hold (received photos are peer-supplied).
/// - `PendingSessionPhotos/` carries `isExcludedFromBackup`, set on every write; a write whose
///   flag cannot be set fails rather than land a pending photo in a backed-up directory.
/// - **No timer.** A held photo leaves only through an answer, delete-all (``purgeAll()``), the
///   duress crypto-erase, or an index whose AEAD open fails under a present key.
///
/// Stateless like ``PrivateMediaStore``: all state is on disk, and the owner holds the mirror.
///
/// Concurrency: a plain value type; confined to its owner's isolation domain (in practice
/// `MeshNetworkManager`'s main actor) because the default key provider caches without locking.
public struct PendingSessionPhotoStore {
    /// Hard cap on held photos — equal to `MeshNetworkManager.maxSessionPhotos`. A hold past it is
    /// REFUSED (``Hold/full``), never an eviction: evicting a held photo would be a discard nobody
    /// chose.
    public static let maxHeldPhotos = 200
    /// Hard cap on tombstones — equal to the most items routed custody can hold. Past it the
    /// soonest-expiring tombstone goes; the worst case is a re-OFFER, never a silent keep.
    public static let maxAnsweredIDs = 1024
    /// How long a tombstone lives after its answer.
    public static let answeredRetention: TimeInterval = 24 * 60 * 60

    /// The corpus directory's name under the proximity support directory. Frozen token.
    public static let directoryName = "PendingSessionPhotos"
    /// Full-size files' subdirectory. Frozen token.
    public static let photosDirectoryName = "Photos"
    /// Thumbnails' subdirectory. Frozen token.
    public static let thumbnailsDirectoryName = "Thumbnails"
    /// The sealed index's file name. Frozen token.
    public static let indexFileName = "PendingSessionPhotoIndex.sealed"

    private static let indexPurpose = FernletCryptoPurpose.AEAD.privatePendingSessionPhotoIndexV1

    /// Why a load could not produce an index this build may write over.
    public enum Deferral: Equatable, Sendable {
        /// The index exists and no key is available right now (before the first unlock).
        case noKey
        /// The index file exists and cannot be read (locked device, I/O error).
        case fileUnreadable
        /// The index opened but is not this build's format (another `schemaVersion`, or a body
        /// that does not decode). A build that reads it will; this one never touches it.
        case unsupportedFormat
    }

    /// What ``load(now:)`` found.
    public enum Load: Equatable, Sendable {
        /// The index (an absent file is ``PendingSessionPhotoIndex/empty``), expired tombstones
        /// dropped, unindexed files swept.
        case loaded(PendingSessionPhotoIndex)
        /// Not readable by this build right now. Never written over, never purged.
        case deferred(Deferral)
        /// Key present, bytes do not open. The corpus was removed (`purged`), or its removal
        /// failed and is audited.
        case unrecoverable(purged: Bool)
    }

    /// What ``hold(_:imageData:into:)`` did.
    public enum Hold: Equatable, Sendable {
        /// Bytes, thumbnail and index are on disk.
        case held
        /// A photo with this key is already held. Nothing written.
        case alreadyHeld
        /// This key carries a tombstone: it was answered and must never come back. Nothing written.
        case answered
        /// ``maxHeldPhotos`` are held. Nothing written, nothing evicted; retry after an answer.
        case full
        /// The bytes are over the size cap or outside the pixel bounds. Nothing written, and no
        /// retry can change it.
        case unsafeImage
        /// No key, a directory or backup-exclusion failure, a failed write, or a local id another
        /// held photo already uses. Nothing written (files of a half-done hold are removed).
        case notPersisted
    }

    private let directory: URL
    private let indexURL: URL
    private let files: FriendPhotoCorpusFiles
    private let keyProvider: PrivateMediaKeyProviding
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    /// Creates a store over `directory` (in production `<proximitySupportDirectory>/PendingSessionPhotos`,
    /// built with ``directoryName``).
    ///
    /// - Parameters:
    ///   - directory: The corpus directory; created (and excluded from backup) on the first write.
    ///   - keyProvider: The at-rest key; defaults to the device-bound pending row. Tests inject an
    ///     in-memory one.
    public init(
        directory: URL,
        keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider(role: .pendingSessionPhotos)
    ) {
        self.directory = directory
        self.indexURL = directory.appendingPathComponent(Self.indexFileName)
        self.keyProvider = keyProvider
        self.files = FriendPhotoCorpusFiles(
            imageDirectoryURL: directory.appendingPathComponent(Self.photosDirectoryName, isDirectory: true),
            thumbnailDirectoryURL: directory.appendingPathComponent(Self.thumbnailsDirectoryName, isDirectory: true),
            imagePurpose: FernletCryptoPurpose.AEAD.privatePendingSessionPhotoImageV1,
            thumbnailPurpose: FernletCryptoPurpose.AEAD.privatePendingSessionPhotoThumbnailV1,
            allowsLegacyPlaintext: false,
            keyProvider: keyProvider,
            auditCorpus: "pendingSessionPhotos"
        )
    }

    /// Delete-all seam: drops the provider-cached key so RAM matches the keychain.
    public func invalidateEncryptionKeyCache() {
        keyProvider.invalidateCachedKey()
    }

    // MARK: Load

    /// Reads and classifies the index (see ``Load``).
    ///
    /// - Parameter now: This phone's clock, for dropping expired tombstones. Never used to remove a
    ///   held photo: a photo held a year ago loads exactly as it was held.
    public func load(now: Date) -> Load {
        guard FileManager.default.fileExists(atPath: indexURL.path) else {
            // No index yet: any file here is left over from a hold killed between its byte write
            // and its index write, and nothing names it.
            files.removeOrphanedFiles(keeping: [])
            return .loaded(.empty)
        }
        let stored: Data
        do {
            stored = try Data(contentsOf: indexURL)
        } catch {
            FernletAuditLog.log("privateMedia.pendingIndexDeferred", context: ["reason": "fileUnreadable"])
            return .deferred(.fileUnreadable)
        }
        guard keyProvider.mediaKey() != nil else {
            FernletAuditLog.log("privateMedia.pendingIndexDeferred", context: ["reason": "noKey"])
            return .deferred(.noKey)
        }
        guard let opened = keyProvider.gcmOpen(stored, purpose: Self.indexPurpose) else {
            let purged = purgeAll()
            FernletAuditLog.log("privateMedia.pendingIndexUnrecoverable", context: ["purged": "\(purged)"])
            return .unrecoverable(purged: purged)
        }
        guard let index = decodedIndex(opened) else {
            FernletAuditLog.log("privateMedia.pendingIndexUnsupportedFormat")
            return .deferred(.unsupportedFormat)
        }
        let pruned = Self.pruned(index, now: now)
        files.removeOrphanedFiles(keeping: pruned.heldLocalIDs)
        return .loaded(pruned)
    }

    /// Decodes an opened index, or nil when it is not exactly this build's format: the version is
    /// probed first, so a newer file is recognised as newer rather than as garbage.
    private func decodedIndex(_ opened: Data) -> PendingSessionPhotoIndex? {
        guard let probe = try? decoder.decode(SchemaProbe.self, from: opened),
              probe.schemaVersion == PendingSessionPhotoIndex.schemaVersion else { return nil }
        return try? decoder.decode(PendingSessionPhotoIndex.self, from: opened)
    }

    /// The one field every generation of the index is required to carry.
    private struct SchemaProbe: Decodable {
        let schemaVersion: Int
    }

    // MARK: Hold

    /// Holds one session photo: seals its bytes and thumbnail FIRST, then writes `index` with the
    /// entry added.
    ///
    /// On an index write failure the two just-written files are removed and ``Hold/notPersisted``
    /// comes back. A kill between the two writes leaves unindexed files, swept by the next clean
    /// ``load(now:)``. Expired tombstones are dropped in the same write, measured against
    /// `photo.heldAt` (this phone's clock at the hold).
    ///
    /// - Precondition: `index` is the committed mirror of a ``Load/loaded(_:)`` load (or of an
    ///   earlier write's return) — never a stand-in for a deferred index, which this write would
    ///   replace.
    /// - Returns: The outcome and the committed index — `index` unchanged unless ``Hold/held``.
    public func hold(
        _ photo: HeldSessionPhoto,
        imageData: Data,
        into index: PendingSessionPhotoIndex
    ) -> (Hold, PendingSessionPhotoIndex) {
        let current = Self.pruned(index, now: photo.heldAt)
        if let refusal = refusal(of: photo, imageData: imageData, in: current) { return (refusal, index) }
        let localID = photo.localID
        // No key: nothing is created, written or removed (the seal would refuse anyway, and the
        // clean-up below must only ever undo this call's own writes).
        guard keyProvider.mediaKey() != nil else { return (.notPersisted, index) }
        guard prepareDirectory() else { return (.notPersisted, index) }
        switch files.writeSealedImage(imageData, for: localID) {
        case .written:
            break
        case .refusedUnsafe:
            return (.unsafeImage, index)
        case .notWritten:
            files.removeFiles(for: localID)
            return (.notPersisted, index)
        }
        var next = current
        let entry = HeldSessionPhoto(key: photo.key, heldAt: photo.heldAt, payload: Self.metadataOnly(photo.payload))
        next.photos.append(entry)
        next.photos.sort { $0.heldAt > $1.heldAt }
        guard writeIndex(next) else {
            files.removeFiles(for: localID)
            return (.notPersisted, index)
        }
        return (.held, next)
    }

    /// Why a hold is refused before anything is written, or nil when it may proceed.
    private func refusal(
        of photo: HeldSessionPhoto,
        imageData: Data,
        in index: PendingSessionPhotoIndex
    ) -> Hold? {
        guard !index.isAnswered(photo.key) else { return .answered }
        guard !index.holds(photo.key) else { return .alreadyHeld }
        guard index.heldPhoto(localID: photo.localID) == nil else {
            // Two held photos under one local id would share one file. The owner mints a fresh
            // local id on a collision; this is the store refusing to overwrite if it ever did not.
            FernletAuditLog.log("privateMedia.pendingLocalIDCollision")
            return .notPersisted
        }
        guard index.photos.count < Self.maxHeldPhotos else { return .full }
        guard FriendPhotoCorpusFiles.isSafeToStore(imageData) else { return .unsafeImage }
        return nil
    }

    /// A payload with no bytes of any kind — the index holds metadata only.
    private static func metadataOnly(_ payload: FriendPhotoPayload) -> FriendPhotoPayload {
        // `withDecryptedImageData` rebuilds through the plaintext initialiser (clearing any
        // ciphertext fields); `withoutImageData` then drops the placeholder bytes.
        payload.withDecryptedImageData(Data()).withoutImageData()
    }

    // MARK: Answer

    /// Commits answers in ONE sealed index write: removes `keys` from the held photos, tombstones
    /// every one of them (refreshing an existing tombstone), and drops expired tombstones. Only
    /// after the write commits are the answered photos' files swept.
    ///
    /// A key that is not held is still tombstoned — the owner uses that for a photo deleted from
    /// the wall, so a routed re-delivery of it is refused too.
    ///
    /// - Precondition: `index` is a committed mirror (see ``hold(_:imageData:into:)``).
    /// - Returns: Whether the write committed, and the committed index (`index` unchanged when it
    ///   did not, or when `keys` is empty — there is nothing to write then).
    public func commitAnswers(
        _ keys: Set<HeldPhotoKey>,
        in index: PendingSessionPhotoIndex,
        now: Date
    ) -> (committed: Bool, PendingSessionPhotoIndex) {
        guard !keys.isEmpty else { return (true, index) }
        var next = index
        next.photos.removeAll { keys.contains($0.key) }
        next.answered.removeAll { keys.contains($0.key) }
        let expiresAt = now.addingTimeInterval(Self.answeredRetention)
        let ordered = keys.sorted { ($0.origin, $0.itemID.uuidString) < ($1.origin, $1.itemID.uuidString) }
        next.answered.append(contentsOf: ordered.map { AnsweredSessionPhoto(key: $0, expiresAt: expiresAt) })
        next = Self.pruned(next, now: now)
        guard prepareDirectory(), writeIndex(next) else { return (false, index) }
        files.removeOrphanedFiles(keeping: next.heldLocalIDs)
        return (true, next)
    }

    /// Drops expired tombstones and, past ``maxAnsweredIDs``, the soonest-expiring ones.
    /// Never touches a held photo.
    private static func pruned(_ index: PendingSessionPhotoIndex, now: Date) -> PendingSessionPhotoIndex {
        var next = index
        next.answered = index.answered.filter { $0.expiresAt > now }
        guard next.answered.count > maxAnsweredIDs else { return next }
        FernletAuditLog.log("mesh.heldPhotos.answeredCapReached", context: ["dropped": "\(next.answered.count - maxAnsweredIDs)"])
        next.answered = Array(next.answered.sorted { $0.expiresAt > $1.expiresAt }.prefix(maxAnsweredIDs))
        return next
    }

    // MARK: Reads

    /// A held photo's full-size plaintext, or nil (no key, missing, unopenable). The owner's review
    /// seam is the only caller, and it gates on its own access facts first.
    public func imageData(for photo: HeldSessionPhoto) -> Data? {
        files.imageData(forID: photo.localID)
    }

    /// A held photo's thumbnail plaintext (regenerated from the full image if needed), or nil.
    public func thumbnailData(for photo: HeldSessionPhoto) -> Data? {
        files.thumbnailData(forID: photo.localID)
    }

    /// The held photo's payload carrying its plaintext bytes — what a keep hands to the wall's
    /// ``PrivateMediaStore/commitKept(_:onto:)`` — or nil when the bytes cannot be opened.
    public func hydrated(_ photo: HeldSessionPhoto) -> FriendPhotoPayload? {
        guard let data = imageData(for: photo) else { return nil }
        return photo.payload.withDecryptedImageData(data)
    }

    // MARK: Delete-all

    /// Removes the whole `PendingSessionPhotos/` directory — every held photo, thumbnail and
    /// tombstone. Keyless: it deletes files, it never opens one.
    ///
    /// - Returns: whether the directory is gone (true when it never existed).
    public func purgeAll() -> Bool {
        guard FileManager.default.fileExists(atPath: directory.path) else { return true }
        do {
            try FileManager.default.removeItem(at: directory)
            return true
        } catch {
            FernletAuditLog.log("privateMedia.pendingPurgeFailed", context: ["error": "\(error)"])
            return false
        }
    }

    // MARK: Disk

    /// Creates the corpus directory and its two subdirectories, and marks the corpus directory
    /// `isExcludedFromBackup` — on every call, so a directory created by any other path is covered
    /// before a pending byte lands in it.
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
            FernletAuditLog.log("privateMedia.pendingDirectoryUnprepared", context: ["error": "\(error)"])
            return false
        }
        return files.createDirectories()
    }

    /// Seals and atomically writes the index. Nothing is written without a key.
    private func writeIndex(_ index: PendingSessionPhotoIndex) -> Bool {
        assert(index.photos.count <= Self.maxHeldPhotos, "the held-photo cap is enforced at hold")
        let data: Data
        do {
            data = try encoder.encode(index)
        } catch {
            FernletAuditLog.log("privateMedia.pendingIndexWriteFailed", context: ["error": "\(error)"])
            return false
        }
        guard let sealed = keyProvider.gcmSeal(data, purpose: Self.indexPurpose) else {
            FernletAuditLog.log("privateMedia.pendingIndexWriteFailed", context: ["error": "noKey"])
            return false
        }
        do {
            try sealed.write(to: indexURL, options: [.atomic, .completeFileProtection])
            return true
        } catch {
            FernletAuditLog.log("privateMedia.pendingIndexWriteFailed", context: ["error": "\(error)"])
            return false
        }
    }
}
