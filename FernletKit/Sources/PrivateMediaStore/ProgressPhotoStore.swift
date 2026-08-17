import Foundation
import CryptoKit
import FernletFoundation

/// One entry in the user's gym progress-photo timeline: a stored photo, when it was taken, and an
/// optional short note.
///
/// The unit of ``ProgressPhotoStore``'s sealed index (and the model the Move-tab timeline renders).
/// `capturedAt` drives the timeline order; `caption` is the user's own label (e.g. "8 weeks in"),
/// which is why the index it lives in is sealed too — a body-photo timeline's dates and notes are
/// as personal as the pictures. The init routes captions through
/// `ProgressPhotoStore.normalizedCaption(_:)` so blanks collapse to nil.
public struct ProgressPhotoRecord: Codable, Identifiable, Hashable, Sendable {
    /// Stable identity; also the key of the sealed photo file in the inner ``MealPhotoStore``.
    public let id: UUID
    /// When the photo was taken — the timeline sort key (editable via
    /// ``ProgressPhotoStore/updateCapturedAt(id:date:)``, which rebuilds the record).
    public let capturedAt: Date
    /// The user's optional note, trimmed and nil when blank.
    public var caption: String?

    public init(id: UUID = UUID(), capturedAt: Date, caption: String? = nil) {
        self.id = id
        self.capturedAt = capturedAt
        self.caption = ProgressPhotoStore.normalizedCaption(caption)
    }
}

/// On-device, at-rest-encrypted store for the user's gym **progress photos** — body pictures the user
/// takes to see how they're changing over time, shown as a timeline under the Move tab.
///
/// Composition, not duplication: the photo *bytes* go through the hardened ``MealPhotoStore`` (the same
/// AES-256-GCM seal + ImageIO downscale + fail-closed-on-no-key path that was built for meal photos and
/// body photos before this landed), pointed at a private `Photos/` subdirectory. This store adds the one
/// thing meal photos get for free from `Meal.photoID` but progress photos have no home for: a **dated
/// index**. That index (`index.bin`) is itself GCM-sealed under the shared media key, so the capture
/// dates and captions never sit on disk in the clear.
///
/// Everything is fail-closed. A photo whose bytes can't be normalized/sealed is dropped rather than
/// stored; an index that can't be sealed is not written in plaintext, and the just-saved photo file is
/// removed so no orphan bytes are stranded. Mutations refuse to rewrite a present-but-unreadable
/// index (which would clobber a still-sealed timeline) — see `existingRecordsForWrite()`.
///
/// Owned by the app's `FernletStore` (main actor). Plain nonisolated struct: thread safety comes from
/// the owner's isolation, shared with the inner photo store and key provider it constructs.
public struct ProgressPhotoStore {
    /// R3: hard cap on timeline entries. A capture past it is REFUSED (nothing is written) rather
    /// than evicting the oldest — these are the user's own body photos, so silently dropping the
    /// earliest ones would be the opposite of the promise the timeline makes.
    public static let maxRecords = 2_000
    /// R5: byte cap on a restored index payload, validated before it is decoded.
    private static let maxIndexPayloadBytes = 4 * 1024 * 1024

    private let directory: URL
    private let photoStore: MealPhotoStore
    private let indexURL: URL
    private let keyProvider: PrivateMediaKeyProviding
    /// Optional PRE-SPLIT key for the dual-open safety net, forwarded to the inner photo store and
    /// applied to the sealed index too — the index is sealed under the same key as the bytes, so a
    /// migration that reached the photos but not `index.bin` would render an empty timeline over a
    /// full photo directory. See `MealPhotoStore.legacyKeyProvider`.
    private let legacyKeyProvider: PrivateMediaKeyProviding?
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a store rooted at `directory` (created if needed): sealed photo bytes go under a
    /// `Photos/` subdirectory (via an inner ``MealPhotoStore`` with the legacy-plaintext path
    /// disabled), the sealed index at `index.bin`.
    ///
    /// - Parameters:
    ///   - directory: Root for this timeline's files.
    ///   - keyProvider: Source of the at-rest key, passed through to the inner photo store so both
    ///     seal under the same key; defaults to the keychain-backed OWN-photos provider (body
    ///     photos are the user's own, never friend-wall media).
    ///   - legacyKeyProvider: Optional pre-split key for the dual-open safety net, applied to both
    ///     the index and the inner photo store. Nil — the default — means no fallback.
    public init(
        directory: URL,
        keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider(role: .ownPhotos),
        legacyKeyProvider: PrivateMediaKeyProviding? = nil
    ) {
        self.directory = directory
        self.keyProvider = keyProvider
        self.legacyKeyProvider = legacyKeyProvider
        // Body photos never had a plaintext generation, so the legacy-plaintext-upgrade read path is
        // disabled: an unsealed file dropped at a valid id path (tampered restore, shared-container
        // write) resolves to nil rather than being trusted and re-sealed into authentic ciphertext.
        // This mirrors the sealed index's own fail-closed refusal (see `readIndex`).
        self.photoStore = MealPhotoStore(
            directory: directory.appendingPathComponent(
                OwnPhotoCorpusLayout.progressPhotosInnerDirectoryName, isDirectory: true
            ),
            keyProvider: keyProvider,
            allowsLegacyPlaintextUpgrade: false,
            legacyKeyProvider: legacyKeyProvider
        )
        self.indexURL = directory.appendingPathComponent(OwnPhotoCorpusLayout.progressIndexFileName)
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            // Recovery: stay constructible — every write path already fails closed. The failure is
            // named so a later sealed-index write error has a recorded root cause.
            FernletAuditLog.log("progressPhotoStore.directoryCreateFailed", context: ["error": "\(error)"])
        }
    }

    /// Delete-all seam (Docs/PrivacyWipeCoverage.md): one call covers both this store and its
    /// inner photo store — they share the same provider instance.
    public func invalidateEncryptionKeyCache() {
        keyProvider.invalidateCachedKey()
    }

    /// The timeline, newest first.
    public func records() -> [ProgressPhotoRecord] {
        loadIndex().sorted { $0.capturedAt > $1.capturedAt }
    }

    /// Normalizes + seals the photo bytes, records the entry, and persists the sealed index. Returns the
    /// new record, or nil — writing NOTHING — when the bytes aren't a decodable image, no encryption key
    /// is available, the index can't be sealed, OR an existing index is present but won't decode. That
    /// last case matters: appending to a `loadIndex()`-returns-empty would OVERWRITE an unreadable index
    /// with a single-record array, silently dropping the prior timeline AND orphaning its sealed photo
    /// files (nothing left references them, so per-id delete can never reach them). So we refuse rather
    /// than clobber, and remove the just-saved photo so the failure leaves no orphan bytes.
    ///
    /// R7: not `@discardableResult` — `nil` IS the failure signal (nothing was written).
    public func add(_ data: Data, caption: String? = nil, capturedAt: Date) -> ProgressPhotoRecord? {
        guard let id = photoStore.save(data) else { return nil }
        guard var all = existingRecordsForWrite() else {
            photoStore.delete(id: id)
            return nil
        }
        // R3: refuse past the cap, rolling back the just-sealed bytes exactly as the other refusal
        // paths do, so a refused capture strands nothing on disk.
        guard all.count < Self.maxRecords else {
            photoStore.delete(id: id)
            return nil
        }
        let record = ProgressPhotoRecord(id: id, capturedAt: capturedAt, caption: caption)
        all.append(record)
        guard persist(all) else {
            photoStore.delete(id: id)
            return nil
        }
        return record
    }

    /// Returns the decrypted photo bytes for a record's `id`, or nil when missing or unopenable
    /// (delegates to the inner sealed photo store, which fails closed on unsealed bytes).
    public func imageData(for id: UUID) -> Data? {
        photoStore.imageData(for: id)
    }

    /// Rewrites a record's caption (normalized via `normalizedCaption`) in the sealed index.
    public func updateCaption(id: UUID, caption: String?) {
        // Fail-closed on an unreadable index: never overwrite it with a partial rebuild.
        guard var all = existingRecordsForWrite(),
              let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index].caption = Self.normalizedCaption(caption)
        guard persist(all) else {
            // Recovery: none possible here — the edit is lost. Name it, so a silently reverted
            // caption is at least attributable.
            FernletAuditLog.log(
                "progressPhoto.indexPersistFailed",
                context: ["op": "updateCaption", "id": id.uuidString]
            )
            return
        }
    }

    /// Edits a photo's capture date so an imported/older picture isn't pinned to "today" (the timeline is
    /// about dates). Same fail-closed sealed-index rewrite as `updateCaption`; `capturedAt` is a `let`, so
    /// the record is rebuilt in place, preserving its id and caption.
    public func updateCapturedAt(id: UUID, date: Date) {
        guard var all = existingRecordsForWrite(),
              let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index] = ProgressPhotoRecord(id: all[index].id, capturedAt: date, caption: all[index].caption)
        guard persist(all) else {
            FernletAuditLog.log(
                "progressPhoto.indexPersistFailed",
                context: ["op": "updateCapturedAt", "id": id.uuidString]
            )
            return
        }
    }

    /// Deletes one photo: the sealed bytes unconditionally, the index entry only when the index
    /// is readable (a corrupt index is never clobbered by a partial rewrite).
    public func delete(id: UUID) {
        // Remove the photo bytes regardless (the user asked to delete this one)...
        photoStore.delete(id: id)
        // ...but only rewrite the index when it's readable, so a corrupt index isn't clobbered.
        guard var all = existingRecordsForWrite() else { return }
        all.removeAll { $0.id == id }
        guard persist(all) else {
            // Worst of the three: the bytes are already gone, so a failed index write leaves a
            // phantom record whose image can never load and a delete that looks like it never ran.
            FernletAuditLog.log(
                "progressPhoto.indexPersistFailed",
                context: ["op": "delete", "id": id.uuidString]
            )
            return
        }
    }

    /// Removes every progress photo and the index. Reached by "delete everything": progress photos are
    /// the user's own logged pictures (like meal photos), so a full wipe includes them.
    ///
    /// R7: not `@discardableResult` — `false` means the photos or the sealed index survived
    /// "delete everything".
    /// - Returns: whether both the photo bytes and the index are now gone.
    public func deleteAll() -> Bool {
        let photosCleared = photoStore.deleteAll()
        let indexCleared: Bool
        if FileManager.default.fileExists(atPath: indexURL.path) {
            indexCleared = (try? FileManager.default.removeItem(at: indexURL)) != nil
        } else {
            indexCleared = true
        }
        return photosCleared && indexCleared
    }

    // MARK: - Own-photo escrow seam (Phase 5, step 5b)

    /// The timeline index encoded for the own-photo escrow backup, or **nil when the index is
    /// present but unreadable**.
    ///
    /// The nil is load-bearing, not an error channel: body photos restored without their dates and
    /// captions render as an invisible timeline, so the index travels with them (as the manifest's
    /// sidecar). Returning an empty array for an unreadable index would upload "you have no progress
    /// photos" over a good cloud copy — the same clobber the sealed-narrative exports refuse — so
    /// unreadable answers nil and the caller skips the corpus. An ABSENT index answers an encoded
    /// empty array, which is the honest "nothing logged yet".
    public func backupIndexPayload() -> Data? {
        switch readIndex() {
        case .absent: return try? encoder.encode([ProgressPhotoRecord]())
        case .records(let records): return try? encoder.encode(records)
        case .undecodable: return nil
        }
    }

    /// Writes a restored timeline index, refusing if this device already has a LIVE one.
    ///
    /// The refusal is the store-level half of the escrow restore's no-clobber gate: the caller
    /// checks ``isEmptyForRestore()`` before restoring, and this re-checks at the write point, so a
    /// restore that raced a local capture can never overwrite the user's own timeline. Fail-closed
    /// on an undecodable payload too — bytes that are not a valid index are refused, never persisted.
    ///
    /// A present-but-**undecodable** index is the one case that is written over, and only when a key
    /// is actually available. Those are dead bytes, not a timeline: the phone-swap case leaves an
    /// index sealed under a key that did not travel to this device, and refusing there would restore
    /// every body photo into a corpus that can never render them. The key check is what keeps the
    /// two apart — an unavailable key ALSO resolves `.undecodable`, and overwriting then would
    /// destroy a perfectly good timeline that is merely locked right now.
    ///
    /// - Returns: whether the index was written (false = refused or the seal/write failed). R7:
    ///   deliberately not `@discardableResult` — ignoring it would let a restore report success
    ///   while the timeline index was refused.
    public func restoreIndexPayload(_ payload: Data) -> Bool {
        // R5: a restore boundary — validate the caller-supplied bytes before decoding them, and the
        // decoded record count before sealing it back as the user's index.
        guard payload.count <= Self.maxIndexPayloadBytes else { return false }
        switch readIndex() {
        case .absent:
            break
        case .records:
            return false
        case .undecodable:
            guard keyProvider.mediaKey() != nil else { return false }
        }
        guard let records = try? decoder.decode([ProgressPhotoRecord].self, from: payload),
              records.count <= Self.maxRecords else { return false }
        return persist(records)
    }

    /// Seals ALREADY-NORMALIZED restored bytes under `id` in the inner photo store — see
    /// ``MealPhotoStore/restoreSealedPhoto(_:forID:)`` for why the normalization pass is skipped.
    ///
    /// R7: not `@discardableResult` — a discarded `false` is a body photo silently missing from the
    /// restore.
    /// - Returns: whether the sealed bytes reached disk.
    public func restoreSealedPhoto(_ normalizedJPEG: Data, forID id: UUID) -> Bool {
        photoStore.restoreSealedPhoto(normalizedJPEG, forID: id)
    }

    /// The photo ids on disk in the inner store. Backups drive from ``records()`` (the index is the
    /// user-visible timeline); this exists so the emptiness gate and any orphan accounting can see
    /// the bytes themselves.
    public func storedPhotoIDs() -> [UUID] {
        photoStore.storedPhotoIDs()
    }

    /// Whether this corpus holds nothing at all — **no index file and no photo bytes**.
    ///
    /// Both halves are required: an index-only corpus (photos deleted, timeline kept) and a
    /// bytes-only corpus (index lost) are each "in use", and restoring over either would clobber or
    /// duplicate. Mirrors the per-payload emptiness gates on the sealed-narrative restores.
    public func isEmptyForRestore() -> Bool {
        let indexAbsent: Bool
        if case .absent = readIndex() { indexAbsent = true } else { indexAbsent = false }
        return indexAbsent && photoStore.isEmptyForRestore()
    }

    /// Whether this corpus holds files but **nothing this install can open** — see
    /// ``MealPhotoStore/holdsOnlyUnopenableFiles()`` for why the escrow restore needs this question
    /// answered separately from ``isEmptyForRestore()``.
    ///
    /// The timeline index decides it first, because the index is the user-visible corpus: an index
    /// that OPENS means this device's timeline is live, whatever the bytes look like, so the answer
    /// is no. An index that is present but undecodable (the device-backup-onto-a-new-phone case:
    /// sealed under a key that did not travel) is itself one of the dead files, so the bytes decide
    /// — and a corpus with no bytes left is then dead index and nothing else.
    public func holdsOnlyUnopenableFiles() -> Bool {
        // No key ⇒ nothing here can be classified at all, and "I cannot look" must never read as
        // "it is dead". Checked up front because an unavailable key also makes a perfectly good
        // index resolve `.undecodable`.
        guard keyProvider.mediaKey() != nil else { return false }
        switch readIndex() {
        case .records:
            return false
        case .absent:
            return photoStore.holdsOnlyUnopenableFiles()
        case .undecodable:
            return photoStore.isEmptyForRestore() || photoStore.holdsOnlyUnopenableFiles()
        }
    }

    // MARK: - Caption hygiene

    /// Trims a caption and collapses an empty one to nil, so blank notes don't render as empty strings.
    static func normalizedCaption(_ caption: String?) -> String? {
        guard let trimmed = caption?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    // MARK: - Sealed index

    /// How the on-disk index resolved when read.
    ///
    /// The distinction exists so writers can tell "nothing there yet" from "something we can't
    /// read": `absent` (no/empty file) is safe to write over; `undecodable` (a file that won't
    /// GCM-open + decode) is NOT — overwriting it would drop a still-sealed timeline.
    private enum IndexState {
        case absent
        case records([ProgressPhotoRecord])
        case undecodable
    }

    /// Reads the sealed index, distinguishing "nothing there yet" from "something there we can't read."
    ///
    /// Deliberately NO plaintext fallback. This is a brand-new store with no legacy unsealed format, so a
    /// bare-JSON fallback wouldn't be a migration path — it would be an injection/laundering sink: a
    /// plaintext `index.bin` dropped into the container (tampered backup restore, shared-container write)
    /// would be trusted as the user's own body-photo timeline and then RE-SEALED under the real media key
    /// on the next mutation, laundering attacker plaintext into the authentic store. The seal seam is
    /// fail-closed: bytes that don't decrypt resolve to `.undecodable`, never to trusted plaintext.
    ///
    /// The Phase-5 dual-open fallback is a different thing and stays safe: it accepts only bytes that
    /// GCM-open (and then decode) under the app's OWN pre-split key, so nothing an attacker could
    /// author is ever trusted — and it re-seals under the current key on the spot, so the index leaves
    /// the legacy generation on first read rather than on the next mutation.
    private func readIndex() -> IndexState {
        guard let stored = try? Data(contentsOf: indexURL), !stored.isEmpty else { return .absent }
        if let opened = keyProvider.gcmOpen(stored),
           let records = try? decoder.decode([ProgressPhotoRecord].self, from: opened) {
            return .records(records)
        }
        if let legacyKeyProvider,
           let opened = legacyKeyProvider.gcmOpen(stored),
           let records = try? decoder.decode([ProgressPhotoRecord].self, from: opened) {
            // Re-seal in place under the current (own) key; a failed write just leaves the index
            // legacy for the migration pass to retry, which is the fail-closed direction — now
            // audit-logged instead of silently discarded.
            keyProvider.sealAndWriteBestEffort(opened, to: indexURL, reason: "progressIndexUpgrade")
            return .records(records)
        }
        return .undecodable
    }

    /// Records to display: an unreadable index reads as empty rather than erroring (fail-closed display).
    private func loadIndex() -> [ProgressPhotoRecord] {
        if case .records(let records) = readIndex() { return records }
        return []
    }

    /// The base records a mutating write should build on, or nil when the index is present-but-unreadable
    /// — the signal that the caller must NOT persist (persisting would clobber the sealed timeline).
    private func existingRecordsForWrite() -> [ProgressPhotoRecord]? {
        switch readIndex() {
        case .absent: return []
        case .records(let records): return records
        case .undecodable: return nil
        }
    }

    /// Encodes, GCM-seals, and atomically writes the index; false (nothing written) when the
    /// records can't be encoded, no key is available, or sealing/writing fails.
    private func persist(_ records: [ProgressPhotoRecord]) -> Bool {
        guard let plaintext = try? encoder.encode(records) else { return false }
        return keyProvider.sealAndWrite(plaintext, to: indexURL)
    }
}
