import Foundation
import Testing
// @testable for the internal `save`, which seeds the share-extension inbox the way the extension does.
@testable import AppServices

/// Guards the hand-copied share-extension mirror of the recipe-import queue against drift.
///
/// `FernletShareExtension` deliberately links no FernletKit products (that is what keeps a share-sheet
/// launch cheap), so `SharedRecipeImportRecord` and the queue file's read/write conventions exist twice:
/// once in `FernletKit/Sources/AppServices/SharedRecipeImportQueue.swift` and once in
/// `FernletShareExtension/SharedRecipeImportQueueWriter.swift`. The extension is not a read-only
/// participant — every enqueue decodes the WHOLE queue file and rewrites it through the mirror type — so
/// a field the app declares and the mirror omits is silently stripped from every already-queued record on
/// the next share. That is exactly how `budgetDeferredDayKey` was being erased, which let the app re-fetch
/// a budget-deferred page on the very day it was deferred.
///
/// The extension's sources are compiled only into the extension target, so the test target cannot import
/// them. These tests therefore read both files off disk and compare their declared shapes — the same
/// source-scanning technique `S3BoundaryTests` uses for the grep-wall — and back that up with a real
/// round-trip over the on-disk JSON format.
struct SharedRecipeImportQueueMirrorTests {
    /// The repo root, via the shared ``RepoRoot`` locator (matching `S3BoundaryTests`).
    private static var repoRoot: URL {
        RepoRoot.url
    }

    private static let appSourcePath = "FernletKit/Sources/AppServices/SharedRecipeImportQueue.swift"
    private static let extensionSourcePath = "App/FernletShareExtension/SharedRecipeImportQueueWriter.swift"

    private func source(_ relativePath: String) throws -> String {
        try String(contentsOf: Self.repoRoot.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// The stored-property names declared by the `SharedRecipeImportRecord` struct in `source`, in
    /// declaration order. Deliberately crude (a `var <name>:` scan bounded to the struct body) — it only
    /// has to see the same thing a reader does, and both definitions are plain stored-property structs.
    ///
    /// Lines carrying a `{` are skipped so a computed property (the app side's `url`) is not mistaken for
    /// stored state: computed properties have no `CodingKey` and so never cross the file.
    private func recordFieldNames(in source: String) -> [String] {
        guard let structRange = source.range(of: "struct SharedRecipeImportRecord") else { return [] }
        let body = source[structRange.upperBound...]
        var names: [String] = []
        for line in body.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // The initializer is the last thing in both struct bodies; stop before its parameter list,
            // whose `name: Type` lines would otherwise read as declarations.
            if trimmed.hasPrefix("init(") || trimmed.hasPrefix("public init(") { break }
            if trimmed.contains("{") { continue }   // computed property / accessor — not stored state
            guard let match = trimmed.range(of: #"^(?:public\s+)?var\s+[A-Za-z_]\w*\s*:"#, options: .regularExpression) else {
                continue
            }
            let declaration = String(trimmed[match]).replacingOccurrences(of: ":", with: "")
            guard let name = declaration.split(separator: " ").last else { continue }
            names.append(String(name))
        }
        return names
    }

    /// THE regression test for the stripped-stamp bug: the extension's hand-copied record must declare
    /// every field the app-side record does, or a share silently drops the missing ones from the queue.
    /// Before the fix this failed on `budgetDeferredDayKey`.
    @Test func extensionMirrorDeclaresEveryAppSideRecordField() throws {
        let appFields = recordFieldNames(in: try source(Self.appSourcePath))
        let mirrorFields = recordFieldNames(in: try source(Self.extensionSourcePath))

        #expect(!appFields.isEmpty, "field scan found nothing in \(Self.appSourcePath) — the scan is broken, not the mirror")
        #expect(
            Set(appFields) == Set(mirrorFields),
            """
            The share-extension mirror of SharedRecipeImportRecord has drifted. Every enqueue rewrites the \
            whole queue file through the mirror, so a missing field is stripped from every queued record.
            app-only:    \(Set(appFields).subtracting(mirrorFields).sorted())
            mirror-only: \(Set(mirrorFields).subtracting(appFields).sorted())
            """
        )
        // `budgetDeferredDayKey` is called out by name: it is the field whose loss was user-visible
        // (a resting device re-fetching a budget-deferred page on every foreground).
        #expect(mirrorFields.contains("budgetDeferredDayKey"))
    }

    /// The JSON keys the app writes must be exactly the fields the mirror declares. Key-set equality is
    /// what makes "decode the whole file and re-encode it through the mirror" lossless; anything the
    /// mirror cannot name is dropped on the way back out.
    @Test func encodedRecordKeysMatchTheMirrorsDeclaredFields() throws {
        let record = SharedRecipeImportRecord(
            url: URL(string: "https://example.com/braise")!,
            attemptCount: 3,
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastErrorDescription: "fetch failed",
            budgetDeferredDayKey: "2026-08-09"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let object = try #require(
            try JSONSerialization.jsonObject(with: encoder.encode(record)) as? [String: Any]
        )
        let encodedKeys = Set(object.keys)

        let mirrorFields = Set(recordFieldNames(in: try source(Self.extensionSourcePath)))
        #expect(
            encodedKeys == mirrorFields,
            "wire keys \(encodedKeys.sorted()) != mirror fields \(mirrorFields.sorted())"
        )
    }

    /// A fully-annotated record survives the extension's exact coder configuration (pretty-printed,
    /// sorted keys, ISO-8601 dates) in both directions. If the two sides' coders ever disagree, the
    /// rewrite loses data even with a perfectly mirrored field list.
    @Test func annotatedRecordRoundTripsThroughTheExtensionCoderConfiguration() throws {
        // Whole-second dates on purpose: the shared `.iso8601` strategy carries no fractional seconds,
        // so `Date()`'s sub-second component is truncated on BOTH sides. That is consistent, not a bug —
        // but it would make an equality assertion here fail for reasons that have nothing to do with the
        // mirror.
        let original = SharedRecipeImportRecord(
            url: URL(string: "https://example.com/stew")!,
            queuedAt: Date(timeIntervalSince1970: 1_699_000_000),
            attemptCount: 2,
            lastAttemptAt: Date(timeIntervalSince1970: 1_700_000_000),
            lastErrorDescription: "the quiet helper is resting",
            budgetDeferredDayKey: "2026-08-09"
        )

        // Verbatim copies of the extension's `makeEncoder()` / `makeDecoder()`.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let reread = try decoder.decode([SharedRecipeImportRecord].self, from: try encoder.encode([original]))
        #expect(reread == [original])
        #expect(reread.first?.budgetDeferredDayKey == "2026-08-09")
    }

    /// The end-to-end shape of the bug, driven over a real queue file: the app stamps a record as
    /// budget-deferred, the extension then enqueues an unrelated URL (which rewrites the entire file),
    /// and the stamp must still be there. Before the mirror carried the field this read back `nil` and
    /// the drain re-fetched the deferred page the same day.
    ///
    /// The rewrite is performed here with the same decode-everything / re-encode-everything algorithm the
    /// extension uses; `extensionMirrorDeclaresEveryAppSideRecordField` is what proves the extension's own
    /// type can express every field this rewrite round-trips.
    @Test func extensionStyleRewritePreservesBudgetDeferralStamps() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-recipe-queue-\(UUID().uuidString)")
            .appendingPathComponent("SharedRecipeImports", isDirectory: true)
            .appendingPathComponent("PendingRecipeURLs.json")
        let queue = SharedRecipeImportQueue(fileURL: fileURL)

        let deferred = SharedRecipeImportRecord(url: URL(string: "https://example.com/deferred")!)
        queue.save([deferred])
        queue.markBudgetDeferred(deferred, dayKey: "2026-08-09")
        #expect(queue.records().first?.budgetDeferredDayKey == "2026-08-09", "precondition: the stamp did not land")

        // What the extension does on a share: decode the whole file, drop any prior record for the same
        // URL, append a fresh one, and write the whole array back.
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let sharedURL = URL(string: "https://example.com/new-share")!
        var records = try decoder.decode([SharedRecipeImportRecord].self, from: try Data(contentsOf: fileURL))
        records.removeAll { $0.urlString == sharedURL.absoluteString }
        records.append(SharedRecipeImportRecord(url: sharedURL))
        try encoder.encode(records).write(to: fileURL, options: [.atomic])

        let afterShare = queue.records()
        #expect(afterShare.count == 2)
        #expect(
            afterShare.first(where: { $0.id == deferred.id })?.budgetDeferredDayKey == "2026-08-09",
            "the share stripped the budget-deferral stamp — the drain will re-fetch the page today"
        )
        #expect(afterShare.contains { $0.urlString == sharedURL.absoluteString })

        try? FileManager.default.removeItem(at: fileURL.deletingLastPathComponent().deletingLastPathComponent())
    }

    /// Both processes write this file, so the extension must coordinate its read+write exactly like the
    /// app side does. Without coordination a share landing mid-drain is last-writer-wins: either the new
    /// URL or the drain's annotations are lost.
    @Test func extensionCoordinatesItsQueueFileAccess() throws {
        let extensionSource = try source(Self.extensionSourcePath)
        #expect(extensionSource.contains("NSFileCoordinator"))
        #expect(
            extensionSource.contains("readingItemAt") && extensionSource.contains("writingItemAt"),
            "the extension must take a combined coordinated read+write, matching the app's modifyRecords"
        )
    }

    /// The two sides must degrade to the SAME path when the App-Group container is unavailable, or the
    /// hand-off silently splits: the extension keeps enqueueing into a file the app never reads.
    @Test func bothSidesShareTheSameContainerFallbackChain() throws {
        for path in [Self.appSourcePath, Self.extensionSourcePath] {
            let text = try source(path)
            #expect(text.contains("group.MBO.Fernlet"), "\(path) lost the App-Group identifier")
            #expect(text.contains("SharedRecipeImports"), "\(path) lost the queue directory name")
            #expect(text.contains("PendingRecipeURLs.json"), "\(path) lost the queue file name")
            guard let applicationSupport = text.range(of: "applicationSupportDirectory"),
                  let temporary = text.range(of: "NSTemporaryDirectory") else {
                Issue.record("\(path) is missing a fallback step (Application Support → tmp)")
                continue
            }
            #expect(
                applicationSupport.lowerBound < temporary.lowerBound,
                "\(path) must fall back to Application Support BEFORE tmp — tmp is the purgeable last resort"
            )
        }
    }
}
