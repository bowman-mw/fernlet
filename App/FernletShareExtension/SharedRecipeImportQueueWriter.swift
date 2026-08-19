import Foundation

/// One queued recipe-URL import as the share extension writes it: the shared URL plus the retry
/// bookkeeping fields the main app fills in later.
///
/// **DELIBERATE TWIN — keep in sync with `SharedRecipeImportRecord` in
/// `FernletKit/Sources/AppServices/SharedRecipeImportQueue.swift`.** This target links NO FernletKit
/// products (`packageProductDependencies` is empty; it imports only Foundation/UIKit/
/// UniformTypeIdentifiers) so a share sheet launches without paging in the whole app framework —
/// so the record is hand-copied rather than imported. The two definitions share ONE on-disk JSON
/// schema, and the extension is a *full* participant in it: every enqueue decodes the entire queue
/// file, rewrites it with THIS type, and writes it back. Any app-side field missing here is
/// therefore not merely unused — it is **silently stripped from every already-queued record** the
/// next time the user shares anything.
///
/// That is not hypothetical: `budgetDeferredDayKey` was previously absent, so a single share erased
/// the budget-deferral stamp from every queued record and the app re-fetched budget-deferred pages
/// on the same day they were deferred (the exact re-fetch storm the stamp exists to prevent).
///
/// The extension populates only `id`, `urlString`, and `queuedAt` (via ``init(url:)``); every other
/// field exists purely so records the app has already annotated survive the decode/re-encode
/// round-trip. All of them stay optional (or defaulted) so a record written by either side keeps
/// decoding on the other.
///
/// - Important: When a field is added to the app-side record, add it here in the same commit.
///   `FernletTests/SharedRecipeImportQueueMirrorTests` reads BOTH source files and fails when the
///   two field lists diverge, so drift is caught by the test suite rather than by a user losing a
///   stamp.
struct SharedRecipeImportRecord: Codable, Identifiable, Equatable {
    /// Stable identity for the record; the app-side drain removes and annotates records by this id.
    var id: UUID
    /// The shared page URL as an absolute string — also the de-duplication key for re-shares.
    var urlString: String
    /// When the share extension enqueued the URL.
    var queuedAt: Date
    /// App-side bookkeeping: failed import attempts so far. The extension always writes `0`.
    var attemptCount: Int
    /// App-side bookkeeping: when the last import attempt ran. Never set by the extension.
    var lastAttemptAt: Date?
    /// App-side bookkeeping: the last import failure's user-facing text. Never set by the extension.
    var lastErrorDescription: String?
    /// App-side bookkeeping: the day-key on which the drain last hit the daily AI budget. Never set
    /// by the extension, but it MUST round-trip: the app's ambient drain skips a record stamped with
    /// today's key, and dropping the stamp here makes a resting device re-fetch the page's HTML on
    /// every foreground for a lookup the budget cannot serve until midnight.
    var budgetDeferredDayKey: String?

    /// Creates a fresh, never-attempted record for `url`, stamped with the current time.
    init(url: URL) {
        self.id = UUID()
        self.urlString = url.absoluteString
        self.queuedAt = Date()
        self.attemptCount = 0
    }
}

/// Appends a shared recipe URL to the App-Group JSON queue that the main app drains.
///
/// The write side of the extension-to-app hand-off: ``ShareViewController`` calls ``enqueue(_:)``
/// with the shared URL, and the main app later reads the same file through `SharedRecipeImportQueue`
/// (in the `AppServices` module), draining it via `FernletStore.processSharedRecipeImportQueue()`
/// on launch and each foreground. The file is a single JSON array of ``SharedRecipeImportRecord``
/// at `SharedRecipeImports/PendingRecipeURLs.json` inside the `group.MBO.Fernlet` container.
///
/// **DELIBERATE TWIN — keep in sync with `SharedRecipeImportQueue` in
/// `FernletKit/Sources/AppServices/SharedRecipeImportQueue.swift`.** Same file path, same container
/// fallback order (App Group → Application Support → tmp), same encoding conventions
/// (pretty-printed, sorted keys, ISO-8601 dates), same `NSFileCoordinator` coordination, and same
/// atomic `.completeFileProtectionUntilFirstUserAuthentication` write — so a queued URL is readable
/// after first unlock even if the device relocks. Coordination is load-bearing rather than
/// cosmetic: two *processes* touch this file, and a share arriving while the app is mid-drain would
/// otherwise be a last-writer-wins race that drops either the new URL or the drain's edits. The
/// struct is a stateless value type (a file URL plus JSON coders), cheap to create per call.
///
/// One behaviour is deliberately NOT mirrored: the app's `modifyRecords` aborts a mutation when the
/// existing file is corrupt (an edit must never destroy records it cannot parse), whereas an
/// unreadable file here reads as empty and is replaced. The asymmetry is intentional — the app can
/// simply skip a drain and retry, but the extension's only alternative is to fail the user's share,
/// and an unparseable queue would then fail every share forever.
///
/// Only `http`/`https` URLs are accepted; re-sharing a URL already in the queue replaces its old
/// record with a fresh one (restarting its retry budget). Failure modes: a non-web URL throws
/// `QueueWriterError.invalidURL`; an over-long URL throws `QueueWriterError.urlTooLong`;
/// directory-creation, encoding, and coordination errors propagate to the caller, which cancels
/// the share.
struct SharedRecipeImportQueueWriter {
    /// The shared container identifier; must match the extension and app entitlements and the
    /// app-side `SharedRecipeImportQueue.appGroupIdentifier`.
    static let appGroupIdentifier = "group.MBO.Fernlet"

    /// Max queued imports kept on disk; the OLDEST are dropped when a share exceeds it.
    ///
    /// R3 (bounded growth): a share is a repeated user action whose whole point is that the app may
    /// stay closed, so nothing else bounds this file — and every enqueue decodes and re-encodes the
    /// entire array inside the extension's small memory budget, where a jetsam is a visibly failed
    /// share. 100 pending pages is far beyond any real backlog; the newest shares always survive.
    static let maxQueuedRecords = 100

    /// The largest shared URL this queue will persist, in UTF-8 bytes.
    ///
    /// R3 (bounded growth, byte half): ``maxQueuedRecords`` bounds the record COUNT but nothing
    /// bounds a single record's size, so a hostile or broken provider can hand the extension a
    /// multi-megabyte "URL" string that is decoded and re-encoded on every later enqueue inside the
    /// extension's small memory budget. 2048 is the classic browser/CDN ceiling; real recipe URLs are
    /// two orders of magnitude under it.
    ///
    /// **Twin note:** must equal `SharedRecipeImportQueue.maxURLByteCount`. A smaller value on the
    /// app side silently deletes rows the extension considers valid; `SharedRecipeImportQueueMirrorTests`
    /// pins the two literals together.
    static let maxURLByteCount = 2048

    private let fileManager: FileManager
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    /// Creates a writer over the queue file.
    ///
    /// - Parameters:
    ///   - fileManager: The file manager used for container lookup and directory creation.
    ///   - fileURL: An override for the queue file's location, used by tests; `nil` resolves the
    ///     standard App-Group path.
    init(fileManager: FileManager = .default, fileURL: URL? = nil) {
        self.fileManager = fileManager
        self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
        self.encoder = Self.makeEncoder()
        self.decoder = Self.makeDecoder()
    }

    /// Validates `url` and appends a fresh record for it to the queue file.
    ///
    /// Reads whatever records already exist (best effort), removes any prior record for the same
    /// URL string, appends a new never-attempted record, trims the queue to
    /// ``maxQueuedRecords`` oldest-first, and rewrites the whole file — all inside a single
    /// coordinated read+write, so the app's drain cannot interleave between the read and the
    /// rewrite and have its annotations (attempt counts, budget-deferral stamps) clobbered.
    ///
    /// The rewrite is why ``SharedRecipeImportRecord`` must mirror EVERY app-side field: records
    /// this call never touches are still decoded and re-encoded through the mirror type.
    ///
    /// - Parameter url: The shared page URL; only `http` and `https` schemes are accepted.
    /// - Throws: `QueueWriterError.invalidURL` for a non-web scheme, `QueueWriterError.urlTooLong`
    ///   for a URL past the length cap, any encoding / file-system error from the rewrite, or the
    ///   `NSFileCoordinator` failure when coordination itself fails.
    func enqueue(_ url: URL) throws {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw QueueWriterError.invalidURL
        }
        // R3: reject oversize input up front, so an unbounded string is never written to a file every
        // later enqueue must decode and re-encode.
        guard url.absoluteString.utf8.count <= Self.maxURLByteCount else {
            throw QueueWriterError.urlTooLong
        }

        let urlString = url.absoluteString
        var writeError: Error?
        var coordinatorError: NSError?
        let coordinator = NSFileCoordinator()
        coordinator.coordinate(readingItemAt: fileURL, options: .withoutChanges,
                               writingItemAt: fileURL, options: .forReplacing,
                               error: &coordinatorError) { readURL, writeURL in
            var records = existingRecords(at: readURL)
            records.removeAll { $0.urlString == urlString }
            records.append(SharedRecipeImportRecord(url: url))
            if records.count > Self.maxQueuedRecords {          // R3: drop the oldest, keep this share
                records.removeFirst(records.count - Self.maxQueuedRecords)
            }
            do {
                try save(records, to: writeURL)
            } catch {
                writeError = error
            }
        }
        if let writeError { throw writeError }
        if let coordinatorError { throw coordinatorError }
    }

    /// Best-effort read of the current queue: a missing, unreadable, or undecodable file all
    /// return an empty array so the enqueue can proceed (see the type doc for why this diverges
    /// from the app side's preserve-on-corrupt policy). Called only from inside the coordinated
    /// block, on the URL the coordinator handed us.
    private func existingRecords(at url: URL) -> [SharedRecipeImportRecord] {
        guard fileManager.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url),
              let records = try? decoder.decode([SharedRecipeImportRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// Replaces the queue file with `records`, creating the parent directory if needed. The write
    /// is atomic and protected until first user authentication. Called only from inside the
    /// coordinated block, on the URL the coordinator handed us.
    private func save(_ records: [SharedRecipeImportRecord], to url: URL) throws {
        try fileManager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(records)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The standard queue location: `SharedRecipeImports/PendingRecipeURLs.json` in the App-Group
    /// container.
    ///
    /// The fallback chain (Application Support, then the temporary directory) mirrors the app-side
    /// `SharedRecipeImportQueue.defaultFileURL` exactly. Both sides must degrade to the SAME path or
    /// the hand-off silently splits in two: the extension would keep enqueueing into a file the app
    /// never reads. tmp is the last resort precisely because it is the one the system may purge.
    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return directory
            .appendingPathComponent("SharedRecipeImports", isDirectory: true)
            .appendingPathComponent("PendingRecipeURLs.json")
    }

    /// The queue's JSON encoding conventions (pretty-printed, sorted keys, ISO-8601 dates),
    /// matching the app-side `SharedRecipeImportQueue`.
    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    /// The matching decoder (ISO-8601 dates) for reading records back before a rewrite.
    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Failure raised when a shared URL is not an importable web URL.
///
/// Thrown by ``SharedRecipeImportQueueWriter/enqueue(_:)`` for any scheme other than `http` or
/// `https`, and for a URL over ``SharedRecipeImportQueueWriter/maxURLByteCount`` bytes; the
/// `errorDescription` is the user-facing copy shown when the share is cancelled.
private enum QueueWriterError: LocalizedError {
    /// The shared item is not an `http`/`https` URL.
    case invalidURL
    /// The shared URL is longer than the queue will persist (R3).
    case urlTooLong

    var errorDescription: String? {
        switch self {
        case .invalidURL: "Fernlet can only import web recipe URLs."
        case .urlTooLong: "That link is too long for Fernlet to import."
        }
    }
}
