import CloudKitSync
import CryptoKit
import FernletFoundation
import Foundation
import PrivateMemoryStore

/// A sealed-content DEVICE key (journal, Worry Box) read WITHOUT minting — the one helper the "entries
/// this iPhone can't open" check and the journal Sealed backup share (journal and intimacy Sealed
/// backup v2 design 2026-09-30, §7.2). Found, absent and unreadable are three different answers: a
/// row is dead under a key that does not exist, but nothing may be decided on a keychain read that did
/// not answer — and nothing here ever mints one over it (which would replace the real key and turn
/// every row it sealed into garbage).
enum SealedDeviceKeyRead {
    /// The key exists.
    case found(SymmetricKey)
    /// No such key on this iPhone.
    case absent
    /// The keychain did not answer (the failing status).
    case unreadable(OSStatus)

    /// Reads `account` under `service` without minting.
    ///
    /// - Parameters:
    ///   - account: The device key's account (`deviceJournalKey`, `deviceWorryKey`).
    ///   - service: Its keychain service (`KeychainItem.journalService` in production).
    static func read(_ account: KeychainItem.Account, service: String) -> SealedDeviceKeyRead {
        switch KeychainItem.loadDistinguishingAbsence(account: account.rawValue, service: service) {
        case .found(let data): return .found(SymmetricKey(data: data))
        case .absent: return .absent
        case .unreadable(let status): return .unreadable(status)
        }
    }

    /// The journal backup's view of this read (``JournalBackupDeviceKey``).
    var journalBackupDeviceKey: JournalBackupDeviceKey {
        switch self {
        case .found(let key): return .present(key)
        case .absent: return .absent
        case .unreadable: return .unreadable
        }
    }
}

/// The journal's Sealed backup seam is shut: a duress session is active (the journal has no hide
/// switch, so duress is the only way it closes). Thrown by every gated member of
/// ``JournalBackupAdapter`` — never an empty answer.
struct JournalBackupSeamClosedError: Error, Equatable {}

/// The journal Sealed backup's adapter for the v2 engine (journal and intimacy Sealed backup v2 design
/// 2026-09-30, §4.1, §7): the sealed ``JournalNarrativeRepository`` mapped onto
/// ``SealedBackupV2Adapter``.
///
/// - **What a backup holds (§7.1).** The snapshot is the sealed ids that some day's journals still
///   reference (``referencedIDs``: every persisted day, the in-memory today and `previousJournals`),
///   intersected with the store's keyless `allIDs()`. An ORPHAN row — no skeleton anywhere: a delete
///   whose row delete failed, an entry the other iPhone deleted with sync on, a past-day append whose
///   day write failed — is never exported, so it can never come back through a restore.
/// - **Both keys (§7.2).** Each chunk is read under the hub key, then under the journal DEVICE key
///   read without minting (``deviceKey``), so an entry written from Home and not yet folded is backed
///   up as it is; the fold is no backup precondition, and an edit from Home mid-export never aborts
///   it. An unreadable keychain is undecided (a retry), never dead; an unknown feeling tag needs a
///   newer build, never dead.
/// - **The decrypt seam** is `!duress` (journaling has no hide switch): every gated member throws
///   ``JournalBackupSeamClosedError`` while a duress session runs, and every decrypt of a journal
///   BACKUP chunk (the head probe, E2, the restore) runs inside ``withOpenSeam(_:)``.
/// - **The restore (§7.3, §7.4)** is the repository's id-keyed merge — absent entries inserted with
///   their own stamps, local entries that open never touched, a different text added beside the local
///   one as its own entry, dead rows replaced, never a delete — and its follow-up rebuilds the day
///   skeleton of every entry that carries a backup entry's content (``reinstate``), read keylessly. A
///   skeleton write that failed answers false: the restore stays unresolved and the next session's
///   idempotent merge re-adds the missing ones.
/// - A v1 chunk is a bare `[JournalNarrative]` array.
///
/// No tier-two memory, Core Memory note or summary is carried (§7.5): exactly `JournalNarrative` rows.
@MainActor
final class JournalBackupAdapter: SealedBackupV2Adapter {
    /// Answers the sealed journal store — read on first use, so an adapter whose payload never runs
    /// never opens the shared store.
    private let repositoryProvider: @MainActor () -> JournalNarrativeRepository
    /// The store, once resolved.
    private var resolvedRepository: JournalNarrativeRepository?
    /// Whether the journal's decrypt seam is open (`!duress`).
    let isOpen: @MainActor () -> Bool
    /// The ids some day's journals reference right now (persisted days, today, `previousJournals`).
    let referencedIDs: @MainActor () -> Set<UUID>
    /// The journal device key, read without minting.
    let deviceKey: @MainActor () -> SealedDeviceKeyRead
    /// Rebuilds the day skeletons of restored entries; false when a day write failed.
    let reinstate: @MainActor ([JournalNarrativeSkeleton]) -> Bool

    /// Creates the adapter.
    ///
    /// - Parameters:
    ///   - repository: Answers the sealed journal store (resolved on first use).
    ///   - isOpen: Whether the seam is open (`!duress`).
    ///   - referencedIDs: The ids some day's journals reference.
    ///   - deviceKey: The journal device key, read without minting.
    ///   - reinstate: Rebuilds day skeletons; false when a write failed.
    init(
        repository: @escaping @MainActor () -> JournalNarrativeRepository,
        isOpen: @escaping @MainActor () -> Bool,
        referencedIDs: @escaping @MainActor () -> Set<UUID>,
        deviceKey: @escaping @MainActor () -> SealedDeviceKeyRead,
        reinstate: @escaping @MainActor ([JournalNarrativeSkeleton]) -> Bool
    ) {
        self.repositoryProvider = repository
        self.isOpen = isOpen
        self.referencedIDs = referencedIDs
        self.deviceKey = deviceKey
        self.reinstate = reinstate
    }

    /// The sealed journal store (resolved once).
    var repository: JournalNarrativeRepository {
        if let resolvedRepository { return resolvedRepository }
        let store = repositoryProvider()
        resolvedRepository = store
        return store
    }

    var payload: SealedBackupPayloadType { .journalNarratives }
    var isSurfaceOpen: Bool { isOpen() }
    var isStoreHealthy: Bool { repository.isStoreHealthy }

    func withOpenSeam<T>(_ body: () throws -> T) throws -> T {
        guard isOpen() else { throw JournalBackupSeamClosedError() }
        return try body()
    }

    func snapshotIDs() throws -> [UUID] {
        let referenced = referencedIDs()
        return try repository.allIDs().filter(referenced.contains)
    }

    func classifiedChunk(_ ids: [UUID], hubKey: SymmetricKey) throws -> SealedBackupChunkPage<JournalNarrative> {
        try withOpenSeam {
            let page = try repository.backupRecords(ids: ids, hubKey: hubKey, deviceKey: deviceKey().journalBackupDeviceKey)
            return SealedBackupChunkPage(
                records: page.records, deadIDs: page.deadIDs,
                needsNewerBuildIDs: page.needsNewerBuildIDs, transientCount: page.transientCount
            )
        }
    }

    func recordID(_ record: JournalNarrative) -> UUID { record.id }

    func decodeV1Chunk(_ data: Data) throws -> [JournalNarrative] {
        try JSONDecoder().decode([JournalNarrative].self, from: data)
    }

    func restoreMerging(_ records: [JournalNarrative], hubKey: SymmetricKey) throws -> SealedBackupMergeResult {
        try withOpenSeam {
            let result = try repository.upsertMerged(records, hubKey: hubKey, deviceKey: deviceKey().journalBackupDeviceKey)
            return SealedBackupMergeResult(
                inserted: result.inserted, replacedDead: result.replaced, forked: result.forked,
                followUpIDs: result.followUpIDs
            )
        }
    }

    /// The day skeletons (§7.4): every entry that now carries a backup entry's content gets one when
    /// its day lacks it (never an edit of an existing one). False — the restore stays unresolved —
    /// when a day write failed, the skeleton read failed, or the seam shut.
    func didRestore(_ result: SealedBackupMergeResult) -> Bool {
        guard !result.followUpIDs.isEmpty else { return true }
        guard isOpen() else { return false }
        do {
            return reinstate(try repository.skeletons(ids: result.followUpIDs))
        } catch {
            FernletAuditLog.log("sealedBackup.v2.journalSkeletonReadFailed")
            return false
        }
    }

    func removeStillDead(_ ids: [UUID], hubKey: SymmetricKey) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        return try withOpenSeam {
            let key = deviceKey().journalBackupDeviceKey
            var stillDead: [UUID] = []
            let size = SealedBackupV2Engine.chunkSize
            for start in stride(from: 0, to: ids.count, by: size) {  // R2: bounded by `ids` (≤ the snapshot cap).
                let page = try repository.backupRecords(ids: Array(ids[start..<min(start + size, ids.count)]), hubKey: hubKey, deviceKey: key)
                // Undecided rows: nothing is removed on a read that did not answer.
                guard page.transientCount == 0 else { throw JournalNarrativeRepositoryError.undecidedRows(count: page.transientCount) }
                stillDead += page.deadIDs
            }
            let batch = JournalNarrativeRepository.maxIDsPerDelete
            for start in stride(from: 0, to: stillDead.count, by: batch) {  // R2: bounded by `stillDead`.
                try repository.delete(ids: Array(stillDead[start..<min(start + batch, stillDead.count)]))
            }
            return stillDead.count
        }
    }
}
