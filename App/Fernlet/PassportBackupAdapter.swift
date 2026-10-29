import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import WorldMapStore

/// The World passport's Sealed backup seam is shut: a duress session is active (the decoy shows an
/// empty passport and keeps nothing). Thrown by every gated member of ``PassportBackupAdapter`` —
/// never an empty answer.
struct PassportBackupSeamClosedError: Error, Equatable {}

/// One World passport entry as the passport's Sealed iCloud backup carries it (round 7, owner
/// 2026-10-29), inside a sealed v2 chunk (``SealedBackupV2Envelope``): the kind and frozen token of one
/// place first visited, with the date of that first visit. FROZEN keys: `id`, `kind`, `token`, `first`
/// (seconds since 1970).
///
/// The `id` is minted when the export's snapshot is taken and names the record only within its set
/// (the engine keeps one copy per id of a hostile set); it says nothing about the place and is never
/// kept on the iPhone. A restore merges by kind and token, never by id. `kind` is kept as its raw
/// spelling, so a kind this build does not know still decodes and the restore can refuse the set as
/// one a newer Fernlet wrote.
struct PassportBackupRecord: Codable, Equatable {
    /// The record's id within its set.
    var id: UUID
    /// The kind's frozen rawValue (`AtlasDiscoveryKind`).
    var kind: String
    /// The place's frozen token (`AtlasDiscovery.token`).
    var token: String
    /// When it was first visited.
    var firstVisit: Date

    /// FROZEN keys.
    enum CodingKeys: String, CodingKey {
        case id, kind, token
        case firstVisit = "first"
    }

    /// Creates a record.
    init(id: UUID, kind: String, token: String, firstVisit: Date) {
        self.id = id
        self.kind = kind
        self.token = token
        self.firstVisit = firstVisit
    }

    /// Decodes the frozen shape (`first` in seconds since 1970).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        token = try container.decode(String.self, forKey: .token)
        firstVisit = Date(timeIntervalSince1970: try container.decode(Double.self, forKey: .firstVisit))
    }

    /// Encodes the frozen shape.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(kind, forKey: .kind)
        try container.encode(token, forKey: .token)
        try container.encode(firstVisit.timeIntervalSince1970, forKey: .firstVisit)
    }

    /// The passport entry this record carries, or nil for a kind this build does not know.
    var discovery: AtlasDiscovery? {
        AtlasDiscoveryKind(rawValue: kind).map { AtlasDiscovery(kind: $0, token: token, at: firstVisit) }
    }
}

/// The World passport's Sealed backup adapter for the v2 engine (round 7; owner 2026-10-29: the
/// passport backup should "have its own switch"): the passport the app's one `WorldAtlasKeeper` keeps,
/// mapped onto ``SealedBackupV2Adapter``, so it runs on the same engine as the period, intimate-log and
/// journal backups with nothing forked — its own switch (`sealedBackupPassportEnabled`), E1, the E2
/// compare-and-swap, the owner hold, spacing and deletes, and every record sealed through the same
/// content-key path (``SealedBackupService``) before anything reaches CloudKit.
///
/// - **What a backup holds.** One ``PassportBackupRecord`` per entry: every country or territory,
///   continent, ocean, sea, city, landmark and terrain class first visited, with that first date. An
///   empty passport exports an empty set.
/// - **The seam** is `!duress` (the passport has no hide switch; a decoy shows an empty passport): every
///   gated member throws ``PassportBackupSeamClosedError`` while a duress session runs, and the keeper
///   itself refuses in a decoy, so a decoy exports and restores nothing.
/// - **The snapshot** reads the passport (``passport``), which THROWS while it can't be read right now
///   (the phone locked) — never an empty passport in its place — so the export fails with nothing
///   written and the upload still owed. Each chunk reads the passport again: an entry removed since the
///   snapshot is left out, and the date is the one held now.
/// - **The restore** merges by kind and token, keeping the earliest date and never removing a local
///   entry (``mergePassport``, `PassportBook.merge`). A record of a kind this build does not know, a
///   token it would refuse or a set over a cap is ``SealedBackupV2FormatError/unreadableRecords`` (a
///   newer Fernlet wrote it: never dropped, never written over); a failed save is rethrown, so the
///   restore stays unresolved and a later pass merges again. No follow-up write.
/// - No row of a passport is ever dead (the entries are not sealed one by one), so nothing pauses and
///   "Remove them" removes nothing. There never was a v1 passport set.
@MainActor
final class PassportBackupAdapter: SealedBackupV2Adapter {
    /// One snapshotted entry, by kind and token.
    private struct Entry: Equatable {
        let kind: AtlasDiscoveryKind
        let token: String
    }

    /// Whether the passport's seam is open (`!duress`).
    let isOpen: @MainActor () -> Bool
    /// The World passport as it is now; throws when it can't be read right now (never an empty one in
    /// its place).
    let passport: @MainActor () throws -> PassportBook
    /// Merges a restored passport into this iPhone's (by token, the earliest date kept) and saves;
    /// returns how many entries were added or moved earlier, and throws when it was not saved.
    let mergePassport: @MainActor (PassportBook) throws -> Int
    /// The entries the last snapshot named, by the id minted for each.
    private var snapshot: [UUID: Entry] = [:]

    /// Creates the adapter.
    ///
    /// - Parameters:
    ///   - isOpen: Whether the seam is open (`!duress`).
    ///   - passport: The World passport now; throws when it can't be read.
    ///   - mergePassport: Merges a restored passport and saves; how many entries changed.
    init(
        isOpen: @escaping @MainActor () -> Bool,
        passport: @escaping @MainActor () throws -> PassportBook,
        mergePassport: @escaping @MainActor (PassportBook) throws -> Int
    ) {
        self.isOpen = isOpen
        self.passport = passport
        self.mergePassport = mergePassport
    }

    var payload: SealedBackupPayloadType { .worldPassport }
    var isSurfaceOpen: Bool { isOpen() }
    /// The passport has no store to attach: one that can't be read right now fails the snapshot.
    var isStoreHealthy: Bool { true }

    func withOpenSeam<T>(_ body: () throws -> T) throws -> T {
        guard isOpen() else { throw PassportBackupSeamClosedError() }
        return try body()
    }

    /// One id per passport entry, earliest first — or the passport's own error while it can't be read
    /// (never an empty snapshot in its place). Gated: throws while the seam is shut.
    func snapshotIDs() throws -> [UUID] {
        let entries = try withOpenSeam { try passport() }.discoveries
        var ids: [UUID] = []
        var taken: [UUID: Entry] = [:]
        ids.reserveCapacity(entries.count)
        for discovery in entries.prefix(PassportBook.maxEntries) {  // R2: bounded by the caps' sum.
            let id = UUID()
            ids.append(id)
            taken[id] = Entry(kind: discovery.kind, token: discovery.token)
        }
        snapshot = taken
        return ids
    }

    /// The snapshotted entries among `ids` that the passport still holds, with their dates now. The
    /// hub key is not needed: the records are sealed by the engine's content-key path alone.
    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<PassportBackupRecord> {
        try withOpenSeam {
            let book = try passport()
            var page = SealedBackupChunkPage<PassportBackupRecord>()
            for id in ids {  // R2: bounded by one chunk (SealedBackupV2Engine.chunkSize).
                guard let entry = snapshot[id], let date = book.firstVisit(entry.kind, token: entry.token) else { continue }
                page.records.append(PassportBackupRecord(id: id, kind: entry.kind.rawValue, token: entry.token, firstVisit: date))
            }
            return page
        }
    }

    func recordID(_ record: PassportBackupRecord) -> UUID { record.id }

    /// There never was a v1 passport set: a bare array under this payload's name is not this build's.
    func decodeV1Chunk(_ data: Data) throws -> [PassportBackupRecord] {
        throw SealedBackupV2FormatError.malformedEnvelope
    }

    /// Merges `records` into this iPhone's passport by kind and token, keeping the earliest date and
    /// removing nothing. A set this build can't hold whole is ``SealedBackupV2FormatError/unreadableRecords``.
    func restoreMerging(_ records: [PassportBackupRecord], hubKey: SymmetricKey) throws -> SealedBackupMergeResult {
        try withOpenSeam {
            let restored = try Self.book(of: records)
            guard !restored.isEmpty else { return SealedBackupMergeResult() }
            return SealedBackupMergeResult(merged: try mergePassport(restored))
        }
    }

    /// No follow-up: the map and the passport screen read the keeper.
    func didRestore(_ result: SealedBackupMergeResult) -> Bool { true }

    /// Nothing of a passport is ever dead; nothing is removed (gated like every other member).
    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int {
        try withOpenSeam { 0 }
    }

    /// The passport `records` carry, or ``SealedBackupV2FormatError/unreadableRecords`` for a kind this
    /// build does not know, a token it would refuse, or more than a cap allows.
    static func book(of records: [PassportBackupRecord]) throws -> PassportBook {
        guard records.count <= PassportBook.maxEntries else { throw SealedBackupV2FormatError.unreadableRecords }
        var discoveries: [AtlasDiscovery] = []
        discoveries.reserveCapacity(records.count)
        for record in records {  // R2: bounded by the caps' sum (checked above).
            guard let discovery = record.discovery else {
                FernletAuditLog.log("sealedBackup.v2.passportKindUnknown")
                throw SealedBackupV2FormatError.unreadableRecords
            }
            discoveries.append(discovery)
        }
        do {
            return try PassportBook(discoveries: discoveries)
        } catch {
            FernletAuditLog.log("sealedBackup.v2.passportRecordsUnreadable")
            throw SealedBackupV2FormatError.unreadableRecords
        }
    }
}
