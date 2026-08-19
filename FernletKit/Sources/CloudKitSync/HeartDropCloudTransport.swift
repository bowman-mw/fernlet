import Foundation
import CloudKit
import FernletDomainModel
import FernletFoundation

/// CloudKit PUBLIC-database ferry for heart drops (bitchat adoptions Increment 3,
/// Docs/Plan-Bitchat-Adoptions-2026-07-25.md) — the app's first public-DB use.
///
/// The production conformer of the `HeartDropTransporting` seam (declared in
/// `FernletDomainModel`), driven by `HeartDropService` in `ProximityKit`: upload one sealed drop
/// per tag, fetch drops for a friend's tag window with per-chunk anti-starvation budgeting, and
/// delete own records after pickup. `@unchecked Sendable` over two immutable, documented
/// thread-safe CloudKit references only.
///
/// Wall note (S3): this type sees only pseudonymous rotating day tags and sealed blobs; every
/// byte of crypto lives on the ProximityKit side of the `HeartDropTransporting` seam declared in
/// FernletDomainModel. Known accepted residual: public-DB records carry a `creatorUserRecordID`, a
/// per-container STABLE pseudonymous id. Tags are uncorrelatable across days, but the CREATOR is
/// not — a dashboard observer gets one anonymous account's send-activity timeline, and its distinct
/// tags-per-day equal how many different friends it sent to that day. Never who they are, never to
/// whom, never what. Records are deletable only by their creator, from the record names in this
/// device's outbox: an uninstall (or a wipe whose purge failed) strands them permanently — there is
/// no server-side TTL.
///
/// Schema (dev auto-creates on first save; PRODUCTION promotion — with the `tag` field queryable —
/// is an owner console action, tracked in RemainingWork): record type `HeartDrop`, fields
/// `tag: String (queryable)`, `payload: Bytes`. Independent of the iCloud *sync* preference —
/// gated solely by the caller's `heartsAwayDelivery` consent.
public final class HeartDropCloudTransport: HeartDropTransporting, @unchecked Sendable {

    /// CloudKit record type for one dropped heart in the public database.
    public static let recordType = "HeartDrop"
    /// Queryable field holding the pseudonymous rotating day tag.
    static let tagField = "tag"
    /// Bytes field holding the sealed (ChaChaPoly + deflate) drop payload.
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
    public static let maxRecordsPerFetch = HeartDropWireLimits.maxRecordsPerFetch
    /// Belt-and-braces bound on cursor follows per chunk, so a server that keeps handing back a
    /// non-nil cursor can't spin the sync forever.
    static let maxPagesPerChunk = 40
    /// Upper bound on one drop's sealed payload (R3: caller-supplied bytes are validated where they
    /// enter, not discovered as a server error).
    ///
    /// This is the RECEIVER's cap, not CloudKit's ~1 MB per-record budget: a record the recipient's
    /// pre-decrypt gate will reject is a record no honest sender should ever write, and bounding it
    /// here also bounds what a fetch can be made to download. `HeartDropSealer.seal` refuses
    /// anything larger first, so no legitimate send can trip this.
    public static let maxPayloadBytes = HeartDropWireLimits.maxRecordByteCount

    // CKContainer/CKDatabase are documented thread-safe — the @unchecked Sendable is these two
    // immutable references only.
    private let container: CKContainer
    private let database: CKDatabase

    public init(container: CKContainer = CKContainer(identifier: CloudKitDataService.containerIdentifier)) {
        self.container = container
        self.database = container.publicCloudDatabase
    }

    /// Whether an iCloud account is available (errors read as unavailable — the caller skips sync).
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

    /// Saves one sealed drop under `tag` and returns the server-assigned record name (kept so
    /// the sender can delete its own record after the outbox lifetime).
    ///
    /// Validates its two parameters at entry (R5): an empty tag would be unqueryable and therefore
    /// uncollectable, and an oversize payload is rejected here rather than after a round trip.
    public func upload(tag: String, payload: Data) async throws -> String {
        guard !tag.isEmpty else { throw HeartDropTransportError.invalidTag }
        guard payload.count <= Self.maxPayloadBytes else { throw HeartDropTransportError.payloadTooLarge }
        let record = CKRecord(recordType: Self.recordType)
        record[Self.tagField] = tag as CKRecordValue
        record[Self.payloadField] = payload as CKRecordValue
        let saved = try await database.save(record)
        return saved.recordID.recordName
    }

    /// Paginated: CloudKit returns one page plus a cursor, and dropping the cursor meant only the
    /// first page of each chunk was ever read — one hostile writer flooding a single valid tag
    /// could then starve every other tag in that chunk indefinitely.
    ///
    /// Both loop bounds are visible at the `while` (R2): the per-chunk record budget (via
    /// `chunkFull`) and `maxPagesPerChunk`.
    public func fetch(tags: [String]) async throws -> [HeartDropRecord] {
        guard !tags.isEmpty else { return [] }
        var results: [HeartDropRecord] = []
        var truncated = false
        var skipped = 0

        let chunks = Self.chunked(tags)
        let perChunkBudget = Self.perChunkBudget(chunkCount: chunks.count)
        // Bytes, not just records: a record budget alone bounds nothing if the server hands back a
        // page of fat records. Counted per chunk, so one hostile writer can't spend another's.
        let byteBudget = perChunkBudget * HeartDropWireLimits.maxRecordByteCount

        for chunk in chunks {
            let query = CKQuery(
                recordType: Self.recordType,
                predicate: NSPredicate(format: "%K IN %@", Self.tagField, chunk)
            )
            // `resultsLimit` is load-bearing, not a hint: without it the SERVER chooses the page
            // size, so a chunk's first page can arrive far larger than the budget that is about to
            // reject most of it — paid for in download bytes before ingest sees one.
            var page = try await database.records(matching: query, resultsLimit: perChunkBudget)
            var pagesRead = 1
            var chunkCount = 0
            var chunkBytes = 0
            var chunkFull = ingest(page, budget: perChunkBudget, byteBudget: byteBudget,
                                   into: &results, count: &chunkCount, bytes: &chunkBytes,
                                   skipped: &skipped)
            var cursor = page.queryCursor
            while !chunkFull, pagesRead < Self.maxPagesPerChunk, let next = cursor {
                page = try await database.records(continuingMatchFrom: next, resultsLimit: perChunkBudget)
                pagesRead += 1
                chunkFull = ingest(page, budget: perChunkBudget, byteBudget: byteBudget,
                                   into: &results, count: &chunkCount, bytes: &chunkBytes,
                                   skipped: &skipped)
                cursor = page.queryCursor
            }
            if chunkFull || cursor != nil { truncated = true }
            // Deliberately NO `break` here: a truncated chunk stops ITSELF, never its successors.
            // The remaining records stay on the server and the next sync picks them up.
        }

        if truncated {
            FernletAuditLog.log("heartdrop.fetch.truncated", context: [
                "records": "\(results.count)",
                "tags": "\(tags.count)"
            ])
        }
        if skipped > 0 {
            // A chunk in which every record failed to materialise must not read as an empty one.
            FernletAuditLog.log("heartdrop.fetch.skippedRecords", context: [
                "skipped": "\(skipped)",
                "kept": "\(results.count)"
            ])
        }
        return results
    }

    /// Appends one query page's usable records to `results`, returning whether the chunk's record
    /// or byte budget ran out mid-page (the `chunkFull` signal the fetch loop's condition reads).
    ///
    /// `internal` rather than `private` so the budget rule is testable against synthesized record
    /// pages: it is the seam that decides both what reaches the main actor and whether the fetch
    /// keeps following cursors, and `fetch` itself needs a live `CKDatabase`.
    func ingest(
        _ page: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?),
        budget: Int,
        byteBudget: Int,
        into results: inout [HeartDropRecord],
        count: inout Int,
        bytes: inout Int,
        skipped: inout Int
    ) -> Bool {
        for (recordID, result) in page.matchResults {
            // Checked PER RECORD, not once per page: a server-chosen page can carry far
            // more matches than the remaining headroom, and every record admitted here
            // costs the receiver a ChaChaPoly open plus a deflate inflate on the main
            // actor — the work this cap exists to bound.
            guard count < budget, bytes < byteBudget else { return true }
            guard let record = try? result.get(),
                  let tag = record[Self.tagField] as? String,
                  let payload = record[Self.payloadField] as? Data else {
                skipped += 1
                continue
            }
            // Counted even for records dropped just below: the bytes were already downloaded, and
            // spending the budget on them is exactly what stops the cursor follows for this chunk.
            bytes += payload.count
            // A record the recipient's pre-decrypt gate would reject anyway is dropped here rather
            // than carried to the main actor. Counted into `skipped`, which the fetch logs.
            guard payload.count <= HeartDropWireLimits.maxRecordByteCount else {
                skipped += 1
                continue
            }
            results.append(HeartDropRecord(tag: tag, payload: payload, recordName: recordID.recordName))
            count += 1
        }
        return false
    }

    /// Deletes the caller's own drop records by name (public-DB records are deletable only by
    /// their creator) — the post-pickup/expiry cleanup path.
    ///
    /// CloudKit's async `modifyRecords` reports per-record failures inside the returned `Result`s
    /// rather than throwing, so the delete results are inspected (R7) instead of discarded: a
    /// partially failed cleanup would otherwise leave the sender's own drops in the PUBLIC database
    /// past their intended lifetime while the caller marks its outbox rows collected.
    public func deleteOwnRecords(recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        let ids = recordNames.map { CKRecord.ID(recordName: $0) }
        let (_, deleteResults) = try await database.modifyRecords(saving: [], deleting: ids)
        let failed = deleteResults.values.filter { if case .failure = $0 { return true } else { return false } }.count
        if failed > 0 {
            FernletAuditLog.log("heartdrop.delete.partialFailure", context: [
                "failed": "\(failed)",
                "requested": "\(ids.count)"
            ])
        }
    }
}

/// Parameter-validation failures raised by ``HeartDropCloudTransport`` before any network call.
public enum HeartDropTransportError: Error {
    /// The drop tag was empty — an untagged record would be unqueryable and uncollectable.
    case invalidTag
    /// The sealed payload exceeded ``HeartDropCloudTransport/maxPayloadBytes``.
    case payloadTooLarge
}
