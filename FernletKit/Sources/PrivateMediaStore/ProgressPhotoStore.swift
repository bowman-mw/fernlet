import Foundation
import CryptoKit

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
    private let directory: URL
    private let photoStore: MealPhotoStore
    private let indexURL: URL
    private let keyProvider: PrivateMediaKeyProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a store rooted at `directory` (created if needed): sealed photo bytes go under a
    /// `Photos/` subdirectory (via an inner ``MealPhotoStore`` with the legacy-plaintext path
    /// disabled), the sealed index at `index.bin`.
    ///
    /// - Parameters:
    ///   - directory: Root for this timeline's files.
    ///   - keyProvider: Source of the shared at-rest key, passed through to the inner photo
    ///     store so both seal under the same key; defaults to the keychain-backed provider.
    public init(directory: URL, keyProvider: PrivateMediaKeyProviding = KeychainPrivateMediaKeyProvider()) {
        self.directory = directory
        self.keyProvider = keyProvider
        // Body photos never had a plaintext generation, so the legacy-plaintext-upgrade read path is
        // disabled: an unsealed file dropped at a valid id path (tampered restore, shared-container
        // write) resolves to nil rather than being trusted and re-sealed into authentic ciphertext.
        // This mirrors the sealed index's own fail-closed refusal (see `readIndex`).
        self.photoStore = MealPhotoStore(
            directory: directory.appendingPathComponent("Photos", isDirectory: true),
            keyProvider: keyProvider,
            allowsLegacyPlaintextUpgrade: false
        )
        self.indexURL = directory.appendingPathComponent("index.bin")
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        self.encoder = enc
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        self.decoder = dec
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
    @discardableResult
    public func add(_ data: Data, caption: String? = nil, capturedAt: Date) -> ProgressPhotoRecord? {
        guard let id = photoStore.save(data) else { return nil }
        guard var all = existingRecordsForWrite() else {
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
        _ = persist(all)
    }

    /// Edits a photo's capture date so an imported/older picture isn't pinned to "today" (the timeline is
    /// about dates). Same fail-closed sealed-index rewrite as `updateCaption`; `capturedAt` is a `let`, so
    /// the record is rebuilt in place, preserving its id and caption.
    public func updateCapturedAt(id: UUID, date: Date) {
        guard var all = existingRecordsForWrite(),
              let index = all.firstIndex(where: { $0.id == id }) else { return }
        all[index] = ProgressPhotoRecord(id: all[index].id, capturedAt: date, caption: all[index].caption)
        _ = persist(all)
    }

    /// Deletes one photo: the sealed bytes unconditionally, the index entry only when the index
    /// is readable (a corrupt index is never clobbered by a partial rewrite).
    public func delete(id: UUID) {
        // Remove the photo bytes regardless (the user asked to delete this one)...
        photoStore.delete(id: id)
        // ...but only rewrite the index when it's readable, so a corrupt index isn't clobbered.
        guard var all = existingRecordsForWrite() else { return }
        all.removeAll { $0.id == id }
        _ = persist(all)
    }

    /// Removes every progress photo and the index. Reached by "delete everything": progress photos are
    /// the user's own logged pictures (like meal photos), so a full wipe includes them.
    @discardableResult
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
    private func readIndex() -> IndexState {
        guard let stored = try? Data(contentsOf: indexURL), !stored.isEmpty else { return .absent }
        guard let opened = keyProvider.gcmOpen(stored),
              let records = try? decoder.decode([ProgressPhotoRecord].self, from: opened) else {
            return .undecodable
        }
        return .records(records)
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
