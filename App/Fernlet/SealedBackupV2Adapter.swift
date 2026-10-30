import CloudKitSync
import CryptoKit
import Foundation

/// One payload's sealed store as the Sealed backup v2 engine sees it (design 2026-09-30, §4.1): the
/// one seam through which ``SealedBackupV2Engine`` snapshots, reads, decodes and merges a payload, so
/// the period, journal and intimacy backups run on the same engine with nothing forked.
///
/// Every member that decrypts or writes is GATED by the adapter's own sealed funnel — it throws while
/// the surface is closed (hidden, under age, a duress session) or keyless, and never answers empty —
/// and the engine re-checks its gates (``SealedBackupV2Engine``'s G) immediately before calling one.
/// The engine itself never touches a store.
@MainActor
protocol SealedBackupV2Adapter: AnyObject {
    /// The payload's record type (its `Codable` coding keys are frozen tokens, §5.1).
    associatedtype Record: Codable

    /// The payload this adapter backs up (a frozen token).
    var payload: SealedBackupPayloadType { get }
    /// Whether the decrypt seam is open right now: the derived visibility (age gate, setting,
    /// `!duress`) for a hideable surface. Re-read before every decrypt.
    var isSurfaceOpen: Bool { get }
    /// Whether the sealed store is attached and loaded (R2-F2).
    var isStoreHealthy: Bool { get }
    /// Runs `body` only while the seam is open, else throws the surface's hidden error. Every decrypt
    /// of this payload's BACKUP chunks (the head probe, E2, the restore) runs inside it, so the gate
    /// check and the decrypt are one synchronous step (R1-BR-12).
    func withOpenSeam<T>(_ body: () throws -> T) throws -> T
    /// Keyless, ungated ids of the rows that belong in a backup, in the store's total order.
    func snapshotIDs() throws -> [UUID]
    /// One chunk's records, classified under the live hub key. A missing row was deleted since the
    /// snapshot (absent from the page). Gated: throws while closed or keyless, never answers empty.
    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<Record>
    /// A record's id.
    func recordID(_ record: Record) -> UUID
    /// The records a v1 chunk (a bare JSON array an earlier build wrote) carries.
    func decodeV1Chunk(_ data: Data) throws -> [Record]
    /// The atomic id-keyed merge of a restored set (never deletes, never overwrites an entry this
    /// iPhone can open). Gated; throws while closed or keyless.
    func restoreMerging(_ records: [Record], hubKey: SymmetricKey) throws -> SealedBackupMergeResult
    /// Follow-up writes after a merge (journal: day skeletons). False when any failed: the restore
    /// then stays unresolved and is retried (R1-BR-6).
    func didRestore(_ result: SealedBackupMergeResult) -> Bool
    /// "Remove them": re-classifies `ids` under every key this iPhone holds and deletes only those
    /// still dead (R2-F12). Returns how many went.
    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int
}

/// One export chunk's records, classified (§4.1).
struct SealedBackupChunkPage<Record> {
    /// Records that opened.
    var records: [Record] = []
    /// Ids whose rows open under no key this iPhone holds.
    var deadIDs: [UUID] = []
    /// Ids whose rows open but carry a plaintext field this build cannot read (an unknown tag).
    var needsNewerBuildIDs: [UUID] = []
    /// Rows this attempt could not decide (the install binding or the keychain did not answer).
    var transientCount = 0
}

/// What one restore merge changed (§4.1).
struct SealedBackupMergeResult: Equatable {
    /// Records that were absent and are now stored.
    var inserted = 0
    /// Records whose stored copy was merged with the incoming one and changed.
    var merged = 0
    /// Records whose stored rows were all dead and were replaced.
    var replacedDead = 0
    /// Incoming copies added as new entries beside a local one that differs (journal only, §7.3).
    var forked = 0
    /// The ids a follow-up write must cover (journal: the day skeletons of every entry that carries a
    /// backup entry's content — inserted, replaced, forked or already equal — so a retry after a failed
    /// skeleton write rebuilds them). Empty for a payload with no follow-up.
    var followUpIDs: [UUID] = []

    /// How many records the merge inserted, merged, replaced or forked.
    var changedCount: Int { inserted + merged + replacedDead + forked }
    /// Whether the save changed anything on disk.
    var changedAnything: Bool { changedCount > 0 }
}
