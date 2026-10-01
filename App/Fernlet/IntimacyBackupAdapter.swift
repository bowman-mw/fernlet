import CloudKitSync
import CryptoKit
import Foundation
import PrivateHealthStore

/// The intimate-log Sealed backup's adapter for the v2 engine (journal and intimacy Sealed backup v2
/// design 2026-09-30, §4.1, §8): the gated ``IntimacyLogStore`` funnel, mapped onto
/// ``SealedBackupV2Adapter``.
///
/// - **One instance.** The adapter works through the app's ONE intimacy funnel — `ContentView`'s,
///   handed to the coordinator at launch wiring — read through ``storeProvider`` every time, so every
///   write any surface makes moves the same mutation hook (§4.4) and no second, unhooked instance
///   exists. Before it is handed over (and in a test that never attaches one) there is no store:
///   ``isStoreHealthy`` is false, so the engine's gates stop every pass before any network work.
/// - **The decrypt seam** is the derived intimacy visibility the coordinator installs on the funnel:
///   `!duress`, the 16+ age gate (fail closed until attested) and the user's setting. Every gated
///   member throws `IntimacyTrackingHiddenError` while it is shut and `FernletLockError.locked`
///   without a key, never an empty answer; every decrypt of an intimacy BACKUP chunk (the head probe,
///   E2, the restore) runs inside ``withOpenSeam(_:)``, so the check and the decrypt are one step.
/// - `snapshotIDs` is the store's keyless `allIDs()`; `classifiedChunk` its gated
///   `backupChunk(ids:contentKey:)` (opened, dead, needs a newer build, undecided); `restoreMerging`
///   its id-keyed merge (§8.2: keep local, fill a missing Health link, replace dead, never delete).
///   Intimacy rows carry only the hub key, so there is no second key to try and no follow-up write:
///   a log is self-contained and the calendar reads the store.
/// - A v1 chunk is a bare `[IntimacyLog]` array.
/// - Nothing here reads or writes HealthKit (BV19): the backup carries the sealed log — its date, note
///   and Health link — and a restore never writes a sample.
@MainActor
final class IntimacyBackupAdapter: SealedBackupV2Adapter {
    /// The app's one gated intimacy funnel, or nil before it is attached.
    let storeProvider: @MainActor () -> IntimacyLogStore?

    /// Creates the adapter over the funnel `storeProvider` answers.
    init(storeProvider: @escaping @MainActor () -> IntimacyLogStore?) {
        self.storeProvider = storeProvider
    }

    var payload: SealedBackupPayloadType { .intimacyLogs }
    var isSurfaceOpen: Bool { storeProvider()?.isVisible() ?? false }
    var isStoreHealthy: Bool { storeProvider()?.isStoreHealthy ?? false }

    func withOpenSeam<T>(_ body: () throws -> T) throws -> T {
        try requireStore().withBackupSeam(body)
    }

    func snapshotIDs() throws -> [UUID] {
        try requireStore().allIDs()
    }

    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<IntimacyLog> {
        let page = try requireStore().backupChunk(ids: ids, contentKey: hubKey)
        return SealedBackupChunkPage(
            records: page.records, deadIDs: page.deadIDs,
            needsNewerBuildIDs: page.needsNewerBuildIDs, transientCount: page.transientCount
        )
    }

    func recordID(_ record: IntimacyLog) -> UUID { record.id }

    func decodeV1Chunk(_ data: Data) throws -> [IntimacyLog] {
        try JSONDecoder().decode([IntimacyLog].self, from: data)
    }

    func restoreMerging(_ records: [IntimacyLog], hubKey: SymmetricKey) throws -> SealedBackupMergeResult {
        let result = try requireStore().restoreMerging(records, contentKey: hubKey)
        return SealedBackupMergeResult(inserted: result.inserted, merged: result.linked, replacedDead: result.replaced)
    }

    /// No follow-up: an intimacy log is self-contained and the calendar reads the store.
    func didRestore(_ result: SealedBackupMergeResult) -> Bool { true }

    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        let store = try requireStore()
        var stillDead: [UUID] = []
        let size = IntimacyLogRepository.maxPageSize
        for start in stride(from: 0, to: ids.count, by: size) {  // R2: bounded by `ids` (≤ the snapshot cap).
            let page = try store.backupChunk(ids: Array(ids[start..<min(start + size, ids.count)]), contentKey: hubKey)
            // Undecided rows: nothing is removed on a read that did not answer.
            guard page.transientCount == 0 else { throw IntimacyLogRepositoryError.undecidedRows(count: page.transientCount) }
            stillDead += page.deadIDs
        }
        return try store.delete(ids: stillDead)
    }

    /// The attached funnel, or the surface's hidden error when none is attached (fail closed).
    private func requireStore() throws -> IntimacyLogStore {
        guard let store = storeProvider() else { throw IntimacyTrackingHiddenError() }
        return store
    }
}
