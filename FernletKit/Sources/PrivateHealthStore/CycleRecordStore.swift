import CryptoKit
import FernletFoundation
import Foundation
import PrivateStoreCore

/// What the Sealed backup's export pre-pass found (period-data design 2026-09-30, §9.10 E3): the
/// keyless id snapshot the export's chunks are built from, and how every one of those rows answered
/// the key — decrypted once and not kept.
///
/// The export may write only when ``isExportable``; any dead row refuses (named, nothing written),
/// any undecided row defers. ``mutationCounter`` is the store's counter when the pass began, so the
/// caller can tell whether anything changed underneath the export.
///
/// `Sendable`: a plain value.
public nonisolated struct CycleRecordBackupPrePass: Equatable, Sendable {
    /// Every stored id when the pass began, in store order.
    public var snapshotIDs: [UUID]
    /// Snapshot ids whose rows can never open.
    public var deadIDs: [UUID]
    /// Snapshot rows this pass could not decide.
    public var transientCount: Int
    /// ``CycleRecordStore/mutationCounter`` when the pass began.
    public var mutationCounter: Int

    /// Creates a pre-pass result.
    public init(snapshotIDs: [UUID], deadIDs: [UUID], transientCount: Int, mutationCounter: Int) {
        self.snapshotIDs = snapshotIDs
        self.deadIDs = deadIDs
        self.transientCount = transientCount
        self.mutationCounter = mutationCounter
    }

    /// Whether every snapshot row opened, so an export built from the snapshot is complete.
    public var isExportable: Bool { deadIDs.isEmpty && transientCount == 0 }
}

/// The `@MainActor` funnel for every sealed cycle-record read and write — the HARD visibility gate
/// at the decrypt/seal seam (period-data design 2026-09-30, §6.2; mirrors ``IntimacyLogStore``).
///
/// While ``isVisible`` answers false the store is INERT at the seam: the display read returns an
/// empty page and decrypts nothing; every write, upsert, backup pre-pass, backup chunk and restore
/// throws ``PeriodTrackingHiddenError`` (a throw, not an empty answer, wherever an empty answer
/// could be mistaken for "nothing here" by an export or a restore). For the same reason the whole
/// sealed-backup seam — pre-pass, chunk and restore — throws `FernletLockError.locked` when it is
/// visible but handed no key, never an empty answer. Deliberately UNGATED, because they
/// decrypt nothing and hiding must never block deletion: ``recordCount()``, ``allIDs()``,
/// ``delete(ids:)``, ``deleteAll()``.
///
/// **Mutation hook (§9.10, R2-F3).** After every call that changed something on disk — an insert,
/// an update, an upsert that inserted, merged, replaced or retired anything, a delete that removed a
/// row — ``mutationCounter`` moves and the installed hook runs. The app wires the hook to mark the
/// period backup dirty (never to its enabled switch); the counter lets the backup export tell whether
/// a mutation landed while it ran.
///
/// Since the cutover (design unit 4) ``PeriodTrackerStore`` composes one as the cycle history's source
/// of truth (its visibility gate is the period store's); the app also constructs one for the keyless
/// count and deletes (the "entries this iPhone can't open" check and "Delete everything"). The app
/// target never constructs a raw `CycleRecordRepository` (grep-walled in `SensitiveSurfaceGateTests`).
@MainActor
public final class CycleRecordStore {
    /// The sealed persistence layer this funnel gates.
    private let repository: CycleRecordRepository

    /// Fail-closed hard gate, re-read on every call; installed only through
    /// ``attachVisibilityGate(_:)``.
    public private(set) var isVisible: () -> Bool = { false }

    /// Runs after every call that changed something on disk; installed only through
    /// ``attachMutationHook(_:)``. Nothing by default.
    private var onMutation: @MainActor () -> Void = {}

    /// Moves by one after every call that changed something on disk. In memory only; it answers
    /// "did anything change since I looked", never "how much".
    public private(set) var mutationCounter = 0

    /// Creates the funnel over a sealed repository.
    ///
    /// - Parameter repository: The sealed CRUD layer; defaults to one on the shared private store.
    public init(repository: CycleRecordRepository = CycleRecordRepository()) {
        self.repository = repository
    }

    /// Creates the funnel over a repository on `controller`'s store (`nil`: the shared on-device
    /// one) — how the app target reaches a non-default store without constructing a repository.
    public convenience init(controller: PrivatePersistenceController?) {
        self.init(repository: CycleRecordRepository(controller: controller))
    }

    /// Installs the visibility gate — the derived period-tracking visibility.
    public func attachVisibilityGate(_ gate: @escaping () -> Bool) {
        isVisible = gate
    }

    /// Installs the mutation hook.
    public func attachMutationHook(_ hook: @escaping @MainActor () -> Void) {
        onMutation = hook
    }

    // MARK: - Gated

    /// Every stored record, reduced by id — or an empty page while hidden (nothing decrypted).
    public func allRecords(contentKey: SymmetricKey?) throws -> CycleRecordPage {
        guard isVisible() else { return CycleRecordPage() }
        return try repository.allRecords(contentKey: contentKey)
    }

    /// The records with these ids, classified — or an empty page while hidden (nothing decrypted).
    /// What an edit reads its stored copy from.
    ///
    /// - Parameter ids: At most `CycleRecordRepository.maxPageSize` ids.
    public func records(ids: [UUID], contentKey: SymmetricKey?) throws -> CycleRecordPage {
        guard isVisible() else { return CycleRecordPage() }
        return try repository.records(ids: ids, contentKey: contentKey)
    }

    /// Stores one new record. Throws while hidden.
    public func insert(_ record: CycleRecord, contentKey: SymmetricKey?) throws {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        try repository.insert(record, contentKey: contentKey)
        recordMutation()
    }

    /// Replaces a stored record in place (an edit). Throws while hidden.
    public func update(_ record: CycleRecord, contentKey: SymmetricKey?, now: Date = Date()) throws {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        try repository.update(record, contentKey: contentKey, now: now)
        recordMutation()
    }

    /// The one merge write (drain, import, fill-on-read). Throws while hidden.
    public func upsertMerged(
        _ records: [CycleRecord],
        retiringNarrativeIDs: [UUID],
        contentKey: SymmetricKey?
    ) throws -> CycleRecordUpsertResult {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        let result = try repository.upsertMerged(records, retiringNarrativeIDs: retiringNarrativeIDs, contentKey: contentKey)
        if result.changedAnything { recordMutation() }
        return result
    }

    // MARK: - Sealed-backup seam (gated; throws rather than answering empty)

    /// The export's pre-pass (§9.10 E3): a keyless id snapshot, then every snapshot row decrypted
    /// once and classified, in chunks of `CycleRecordRepository.maxPageSize`. Nothing decrypted is
    /// kept. Throws while hidden — an empty answer would read as "nothing to back up".
    public func backupPrePass(contentKey: SymmetricKey?) throws -> CycleRecordBackupPrePass {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        guard contentKey != nil else { throw FernletLockError.locked }
        let counter = mutationCounter
        let ids = try repository.allIDs()
        var classified = CycleRecordPage()
        let size = CycleRecordRepository.maxPageSize
        for start in stride(from: 0, to: ids.count, by: size) {  // R2: ids ≤ maxStoredRecords.
            let page = try repository.records(ids: Array(ids[start..<min(start + size, ids.count)]), contentKey: contentKey)
            classified.deadIDs += page.deadIDs
            classified.transientCount += page.transientCount
        }
        return CycleRecordBackupPrePass(
            snapshotIDs: ids,
            deadIDs: classified.deadIDs,
            transientCount: classified.transientCount,
            mutationCounter: counter
        )
    }

    /// One export chunk: the records with these snapshot ids. Throws while hidden, and throws
    /// `FernletLockError.locked` without a key — never an empty page. An empty chunk is a legitimate
    /// answer (every id in it was deleted mid-export, §9.10 E3), so a keyless chunk that answered
    /// empty would be indistinguishable from it, and an export whose key went between the pre-pass
    /// and a chunk would write a short set over the cloud copy (review C-U3-R1 / L-U3-R1).
    ///
    /// - Parameter ids: At most `CycleRecordRepository.maxPageSize` ids.
    public func backupChunk(ids: [UUID], contentKey: SymmetricKey?) throws -> CycleRecordPage {
        guard isVisible() else { throw PeriodTrackingHiddenError() }
        guard contentKey != nil else { throw FernletLockError.locked }
        return try repository.records(ids: ids, contentKey: contentKey)
    }

    /// A restore: an id-keyed merge (inserts absent ids, completes present ones, replaces dead ones,
    /// never deletes an openable record and never overwrites a newer block). Throws while hidden.
    public func restoreMerging(_ records: [CycleRecord], contentKey: SymmetricKey?) throws -> CycleRecordUpsertResult {
        try upsertMerged(records, retiringNarrativeIDs: [], contentKey: contentKey)
    }

    // MARK: - Ungated (keyless)

    /// How many records are stored. Keyless and ungated: a hidden store must never read as empty.
    public func recordCount() throws -> Int {
        try repository.recordCount()
    }

    /// Every stored id. Keyless and ungated.
    public func allIDs() throws -> [UUID] {
        try repository.allIDs()
    }

    /// Deletes these records without decrypting them. Ungated: hiding never blocks deletion.
    ///
    /// - Returns: How many rows were removed.
    public func delete(ids: [UUID]) throws -> Int {
        let removed = try repository.delete(ids: ids)
        if removed > 0 { recordMutation() }
        return removed
    }

    /// Deletes every record without decrypting. Ungated — "Delete everything" and the "entries this
    /// iPhone can't open" removal run while the tab is closed and whatever the visibility.
    public func deleteAll() throws {
        if try repository.deleteAll() { recordMutation() }
    }

    /// Moves the counter, then runs the hook.
    private func recordMutation() {
        mutationCounter &+= 1
        onMutation()
    }
}
