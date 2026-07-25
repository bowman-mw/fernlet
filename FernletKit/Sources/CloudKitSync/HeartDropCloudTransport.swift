import Foundation
import CloudKit
import FernletDomainModel

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
    /// CloudKit `IN` predicates degrade past ~portions of this; fetches chunk the tag list.
    static let fetchChunkSize = 50

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

    public func upload(tag: String, payload: Data) async throws -> String {
        let record = CKRecord(recordType: Self.recordType)
        record[Self.tagField] = tag as CKRecordValue
        record[Self.payloadField] = payload as CKRecordValue
        let saved = try await database.save(record)
        return saved.recordID.recordName
    }

    public func fetch(tags: [String]) async throws -> [HeartDropRecord] {
        guard !tags.isEmpty else { return [] }
        var results: [HeartDropRecord] = []
        for chunk in stride(from: 0, to: tags.count, by: Self.fetchChunkSize).map({
            Array(tags[$0..<min($0 + Self.fetchChunkSize, tags.count)])
        }) {
            let query = CKQuery(
                recordType: Self.recordType,
                predicate: NSPredicate(format: "%K IN %@", Self.tagField, chunk)
            )
            let (matches, _) = try await database.records(matching: query)
            for (recordID, result) in matches {
                guard let record = try? result.get(),
                      let tag = record[Self.tagField] as? String,
                      let payload = record[Self.payloadField] as? Data else { continue }
                results.append(HeartDropRecord(tag: tag, payload: payload, recordName: recordID.recordName))
            }
        }
        return results
    }

    public func deleteOwnRecords(recordNames: [String]) async throws {
        guard !recordNames.isEmpty else { return }
        let ids = recordNames.map { CKRecord.ID(recordName: $0) }
        _ = try await database.modifyRecords(saving: [], deleting: ids)
    }
}
