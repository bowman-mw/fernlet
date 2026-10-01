import CloudKitSync
import CryptoKit
import Foundation
import PrivateHealthStore

/// The period Sealed backup's adapter for the v2 engine (design 2026-09-30, §4.1): the gated
/// ``CycleRecordStore`` funnel, mapped onto ``SealedBackupV2Adapter``.
///
/// - `snapshotIDs` is the store's keyless `allIDs()`; `classifiedChunk` is its gated
///   `backupChunk(ids:contentKey:)`, already a classified page (undecided rows are transient; this
///   build reads every `CycleRecord` field it stores, so nothing is "needs a newer build" here);
///   `restoreMerging` is the store's id-keyed merge (§5.1a); `withOpenSeam` is its
///   `withBackupSeam`. The store's own `backupPrePass` is not used (R2-F8): the engine owns the
///   snapshot and the prepare.
/// - The decrypt seam is the derived period-tracking visibility, which a duress session forces shut,
///   installed on the store by the coordinator; every gated call throws `PeriodTrackingHiddenError`
///   while it is shut and `FernletLockError.locked` without a key.
/// - A v1 chunk is a bare `[MenstrualNarrative]` array: each narrative becomes a narrative-only
///   record under its deterministic legacy id with origin `.restored`, so it merges with the same
///   entry's import or drain.
@MainActor
final class CycleRecordBackupAdapter: SealedBackupV2Adapter {
    /// The gated cycle-record funnel (its visibility gate and mutation hook installed by the owner).
    let store: CycleRecordStore

    /// Creates the adapter over a gated funnel.
    init(store: CycleRecordStore) {
        self.store = store
    }

    var payload: SealedBackupPayloadType { .periodData }
    var isSurfaceOpen: Bool { store.isVisible() }
    var isStoreHealthy: Bool { store.isStoreHealthy }

    func withOpenSeam<T>(_ body: () throws -> T) throws -> T {
        try store.withBackupSeam(body)
    }

    func snapshotIDs() throws -> [UUID] {
        try store.allIDs()
    }

    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<CycleRecord> {
        let page = try store.backupChunk(ids: ids, contentKey: hubKey)
        return SealedBackupChunkPage(records: page.records, deadIDs: page.deadIDs, transientCount: page.transientCount)
    }

    func recordID(_ record: CycleRecord) -> UUID { record.id }

    func decodeV1Chunk(_ data: Data) throws -> [CycleRecord] {
        try JSONDecoder().decode([MenstrualNarrative].self, from: data)
            .map { CycleRecord(legacyNarrative: $0, origin: .restored) }
    }

    func restoreMerging(_ records: [CycleRecord], hubKey: SymmetricKey) throws -> SealedBackupMergeResult {
        let result = try store.restoreMerging(records, contentKey: hubKey)
        return SealedBackupMergeResult(inserted: result.inserted, merged: result.merged, replacedDead: result.replaced)
    }

    /// No follow-up: a cycle record is self-contained and the Cycle page reads the store.
    func didRestore(_ result: SealedBackupMergeResult) -> Bool { true }

    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        var stillDead: [UUID] = []
        let size = CycleRecordRepository.maxPageSize
        for start in stride(from: 0, to: ids.count, by: size) {  // R2: bounded by `ids` (≤ the snapshot cap).
            let page = try store.backupChunk(ids: Array(ids[start..<min(start + size, ids.count)]), contentKey: hubKey)
            // Undecided rows: nothing is removed on a read that did not answer.
            guard page.transientCount == 0 else { throw CycleRecordRepositoryError.undecidedRows(count: page.transientCount) }
            stillDead += page.deadIDs
        }
        return try store.delete(ids: stillDead)
    }
}
