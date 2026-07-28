import Foundation
import CloudKit
import FernletDomainModel
import FernletFoundation

/// CloudKit PUBLIC-database ferry for heart drops (bitchat adoptions Increment 3,
/// Docs/Plan-Bitchat-Adoptions-2026-07-25.md) — the app's first public-DB use.
///
/// Wall note (S3): this type sees only pseudonymous rotating day tags and sealed blobs; every
/// byte of crypto lives on the ProximityKit side of the `HeartDropTransporting` seam declared in
/// FernletDomainModel. Known accepted residual (documented in the plan): public-DB records carry
/// a `creatorUserRecordID` — an observer can see that SOME iCloud user wrote N drops on a day,
/// never to whom, and tags are uncorrelatable across days.
///
/// Schema (dev auto-creates on first save; PRODUCTION promotion — with the `tag` field queryable —
/// is an owner console action, tracked in RemainingWork): record type `HeartDrop`, fields
/// `tag: String (queryable)`, `payload: Bytes`. Independent of the iCloud *sync* preference —
/// gated solely by the caller's `heartsAwayDelivery` consent.
public final class HeartDropCloudTransport: HeartDropTransporting, @unchecked Sendable {

    public static let recordType = "HeartDrop"
    static let tagField = "tag"
    static let payloadField = "payload"
    /// CloudKit `IN` predicates degrade past ~portions of this; fetches chunk the tag list. Kept
    /// deliberately small: one query page is shared by every tag in a chunk, so a friend flooding
    /// their own valid tag crowds out the other tags in the SAME chunk first. Smaller chunks mean
    /// fewer peers can be starved by one hostile writer (the pickup window is 15 tags per friend
    /// since it was aligned to the outbox lifetime, so this is ~1.3 friends per chunk).
    static let fetchChunkSize = 20
    /// Safety cap on records pulled in one `fetch(tags:)`. A truncated fetch is LOGGED, never
    /// silent — the remaining records stay on the server and the next sync picks them up.
    /// Public alongside `perChunkBudget` so the anti-starvation split is assertable in tests.
    public static let maxRecordsPerFetch = 500
    /// Belt-and-braces bound on cursor follows per chunk, so a server that keeps handing back a
    /// non-nil cursor can't spin the sync forever.
    static let maxPagesPerChunk = 40

    // CKContainer/CKDatabase are documented thread-safe — the @unchecked Sendable is these two
    // immutable references only.
    private let container: CKContainer
    private let database: CKDatabase

    public init(container: CKContainer = CKContainer(identifier: CloudKitDataService.containerIdentifier)) {
        self.container = container
        self.database = container.publicCloudDatabase
    }

    public func accountAvailable() async -> Bool {
        (try? await container.accountStatus()) == .available
    }

    // MARK: - Fetch budgeting (pure, so the starvation rule is unit-testable without CloudKit)

    /// Splits the tag list into `IN`-predicate-sized query chunks.
    public static func chunked(_ tags: [String]) -> [[String]] {
        stride(from: 0, to: tags.count, by: fetchChunkSize).map {
            Array(tags[$0..<min($0 + fetchChunkSize, tags.count)])
        }
    }

    /// Each chunk's share of `maxRecordsPerFetch`.
    ///
    /// The budget is split EVENLY ACROSS CHUNKS rather than spent first-come. A single global cap
    /// plus a `break` out of the chunk loop meant one hostile writer flooding one tag in chunk 0
    /// consumed the whole budget and every later chunk's tags were never queried at all — on that
    /// pass and every subsequent one, so those friends' hearts were never picked up. That is exactly
    /// the starvation the small `fetchChunkSize` claims to bound, and the chunk size was irrelevant
    /// to it (review finding, 2026-07-27). Per-chunk budgeting keeps the same total work while
    /// guaranteeing every chunk gets queried. Never zero: a chunk with no budget could never make
    /// progress at all.
    public static func perChunkBudget(chunkCount: Int) -> Int {
        guard chunkCount > 0 else { return maxRecordsPerFetch }
        return max(1, maxRecordsPerFetch / chunkCount)
    }

    public func upload(tag: String, payload: Data) async throws -> String {
        let record = CKRecord(recordType: Self.recordType)
        record[Self.tagField] = tag as CKRecordValue
        record[Self.payloadField] = payload as CKRecordValue
        let saved = try await database.save(record)
        return saved.recordID.recordName
    }

    /// Paginated: CloudKit returns one page plus a cursor, and dropping the cursor meant only the
    /// first page of each chunk was ever read — one hostile writer flooding a single valid tag
    /// could then starve every other tag in that chunk indefinitely.
    public func fetch(tags: [String]) async throws -> [HeartDropRecord] {
        guard !tags.isEmpty else { return [] }
        var results: [HeartDropRecord] = []
        var truncated = false

        let chunks = Self.chunked(tags)
        let perChunkBudget = Self.perChunkBudget(chunkCount: chunks.count)

        for chunk in chunks {
            let query = CKQuery(
                recordType: Self.recordType,
                predicate: NSPredicate(format: "%K IN %@", Self.tagField, chunk)
            )
            var page = try await database.records(matching: query)
            var pagesRead = 1
            var chunkCount = 0
            var chunkFull = false
            while true {
                for (recordID, result) in page.matchResults {
                    // Checked PER RECORD, not once per page: a server-chosen page can carry far
                    // more matches than the remaining headroom, and every record admitted here
                    // costs the receiver a ChaChaPoly open plus a deflate inflate on the main
                    // actor — the work this cap exists to bound.
                    guard chunkCount < perChunkBudget else { chunkFull = true; break }
                    guard let record = try? result.get(),
                          let tag = record[Self.tagField] as? String,
                          let payload = record[Self.payloadField] as? Data else { continue }
                    results.append(HeartDropRecord(tag: tag, payload: payload, recordName: recordID.recordName))
                    chunkCount += 1
                }
                guard !chunkFull else { truncated = true; break }
                guard let cursor = page.queryCursor, pagesRead < Self.maxPagesPerChunk else {
                    if page.queryCursor != nil { truncated = true }
                    break
                }
                page = try await database.records(continuingMatchFrom: cursor)
                pagesRead += 1
            }
            // Deliberately NO `break` here: a truncated chunk stops ITSELF, never its successors.
            // The remaining records stay on the server and the next sync picks them up.
        }

        if truncated {
            FernletAuditLog.log("heartdrop.fetch.truncated", context: [
                "records": "\(results.count)",
                "tags": "\(tags.count)"
            ])
        }
        return results
    }

    public func deleteOwnRecords(recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        let ids = recordNames.map { CKRecord.ID(recordName: $0) }
        _ = try await database.modifyRecords(saving: [], deleting: ids)
    }
}
