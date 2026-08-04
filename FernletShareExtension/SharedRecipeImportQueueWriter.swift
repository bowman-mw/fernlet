import Foundation

/// One queued recipe-URL import as the share extension writes it: the shared URL plus the retry
/// bookkeeping fields the main app fills in later.
///
/// This is the extension-side mirror of the app's `SharedRecipeImportRecord` in the `AppServices`
/// module. The two targets share the JSON schema by convention only — this target deliberately
/// links no FernletKit products, so the type is duplicated rather than imported. The extension
/// populates just `id`, `urlString`, and `queuedAt` (via ``init(url:)``); `attemptCount`,
/// `lastAttemptAt`, and `lastErrorDescription` exist so records the app has already annotated
/// survive the decode/re-encode round-trip when ``SharedRecipeImportQueueWriter/enqueue(_:)``
/// rewrites the file.
///
/// - Important: Any field added to the app-side record but not mirrored here is silently dropped
///   when the extension rewrites the queue (the app side already carries `budgetDeferredDayKey`,
///   which this mirror does not).
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
/// at `SharedRecipeImports/PendingRecipeURLs.json` inside the `group.MBO.Fernlet` container
/// (falling back to the process's temporary directory when the container is unavailable).
///
/// Encoding conventions match the app side — pretty-printed, sorted keys, ISO-8601 dates — and
/// writes are atomic with `.completeFileProtectionUntilFirstUserAuthentication`, so a queued URL
/// is readable after first unlock even if the device relocks. Only `http`/`https` URLs are
/// accepted; re-sharing a URL already in the queue replaces its old record with a fresh one.
/// The struct is a stateless value type (a file URL plus JSON coders), cheap to create per call.
///
/// Unlike the app-side queue, reads and writes here are **not** `NSFileCoordinator`-coordinated;
/// the atomic write only protects against torn files. Failure modes: a missing, unreadable, or
/// corrupt existing file reads as empty (so the enqueue still succeeds and replaces the file);
/// a non-web URL throws ``QueueWriterError/invalidURL``; directory-creation or write errors
/// propagate to the caller, which cancels the share.
struct SharedRecipeImportQueueWriter {
    /// The shared container identifier; must match the extension and app entitlements and the
    /// app-side `SharedRecipeImportQueue.appGroupIdentifier`.
    static let appGroupIdentifier = "group.MBO.Fernlet"

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
    /// URL string, appends a new never-attempted record, and rewrites the whole file. The
    /// de-duplication means re-sharing a page restarts its retry budget from zero.
    ///
    /// - Parameter url: The shared page URL; only `http` and `https` schemes are accepted.
    /// - Throws: ``QueueWriterError/invalidURL`` for a non-web scheme, or any encoding /
    ///   file-system error from the rewrite.
    func enqueue(_ url: URL) throws {
        guard url.scheme == "http" || url.scheme == "https" else {
            throw QueueWriterError.invalidURL
        }

        var records = existingRecords()
        let urlString = url.absoluteString
        records.removeAll { $0.urlString == urlString }
        records.append(SharedRecipeImportRecord(url: url))
        try save(records)
    }

    /// Best-effort read of the current queue: a missing, unreadable, or undecodable file all
    /// return an empty array so the enqueue can proceed.
    private func existingRecords() -> [SharedRecipeImportRecord] {
        guard fileManager.fileExists(atPath: fileURL.path),
              let data = try? Data(contentsOf: fileURL),
              let records = try? decoder.decode([SharedRecipeImportRecord].self, from: data) else {
            return []
        }
        return records
    }

    /// Replaces the queue file with `records`, creating the parent directory if needed. The write
    /// is atomic and protected until first user authentication.
    private func save(_ records: [SharedRecipeImportRecord]) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let data = try encoder.encode(records)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The standard queue location: `SharedRecipeImports/PendingRecipeURLs.json` in the App-Group
    /// container, or the temporary directory when the container cannot be resolved.
    private static func defaultFileURL(fileManager: FileManager) -> URL {
        let directory = fileManager.containerURL(forSecurityApplicationGroupIdentifier: appGroupIdentifier)
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
/// `https`; the `errorDescription` is the user-facing copy shown when the share is cancelled.
private enum QueueWriterError: LocalizedError {
    case invalidURL

    var errorDescription: String? {
        "Fernlet can only import web recipe URLs."
    }
}
