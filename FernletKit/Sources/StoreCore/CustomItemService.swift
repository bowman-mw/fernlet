import Foundation
import Observation
import FernletPersistence
import FernletDomainModel

/// Owns the user's custom-item (designed clothing) collection in memory and persists it to its own
/// per-row store (separate from the snapshot blob). Mirrors ``CoinLedgerService``: mutations are queued
/// per-row and flushed via an APPEND/UPSERT-ONLY repository, so flushing a stale in-memory set can never
/// delete rows that synced in from another device (the cross-device clobber the in-person clothing
/// shop's buy would otherwise trigger). Equip state is NOT here — it lives in settings (`DiaryStore`)
/// as a tiny UUID map.
///
/// Collaborators: the injected `CustomItemRepositoring` store (concretely CloudKitSync's
/// `CustomItemRepository`, behind the FernletPersistence protocol so this module needs no CloudKitSync
/// edge) and `FernletStore`, which owns the instance and calls ``reloadFromStore()`` on remote CloudKit
/// changes. The creation studio and in-person shop mutate through ``upsert(_:)`` /
/// ``setShareable(id:_:)`` / ``setPrice(id:_:)``.
///
/// Invariants: the pending queues (`pendingUpserts`/`pendingDeletes`) are the sole un-persisted copy of
/// a mutation — ``flushPendingSave()`` clears each queue only after its confirmed write, and
/// ``reloadFromStore()`` re-applies still-pending mutations after a failed flush, so a just-designed or
/// just-bought item is never silently lost. `@MainActor` and `@Observable`.
@MainActor
@Observable
public final class CustomItemService {
    /// The in-memory closet, union-merged (deduplicated by id) on init and every load.
    public private(set) var items: [CustomizationItem] = []

    @ObservationIgnored private let repository: any CustomItemRepositoring
    /// Rows mutated locally but not yet written. Only these are flushed (upserted/deleted) so the
    /// persisted store is touched surgically per-row and never re-writes (or deletes) the rest.
    @ObservationIgnored private var pendingUpserts: [UUID: CustomizationItem] = [:]
    @ObservationIgnored private var pendingDeletes: Set<UUID> = []
    @ObservationIgnored private var saveScheduled = false

    /// Creates the service over its per-row store; `initialItems` seeds the closet before the first load.
    public init(repository: any CustomItemRepositoring, initialItems: [CustomizationItem] = []) {
        self.repository = repository
        self.items = Self.deduplicatedByID(initialItems)
    }

    /// Replaces the in-memory closet with the store's rows, union-merged by id.
    public func loadSync() {
        items = Self.deduplicatedByID(repository.load())
    }

    /// Async variant of ``loadSync()`` for the off-main initial load.
    public func loadAsync() async {
        items = Self.deduplicatedByID(await repository.loadAsync())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up item rows that synced in from
    /// another device. Call when a remote CloudKit change lands so the closet tracks other devices.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
        // If the flush FAILED, its mutations survive only in the pending queues (the write rolled back), and
        // `loadSync()` just replaced `items` with store contents that LACK them — dropping a just-designed or
        // just-bought item from the closet. Re-apply the still-pending mutations on top of the freshly loaded
        // set (pending upserts win by id via the same dedup used everywhere; pending deletes are removed),
        // keeping the queues intact so the next scheduled save retries. On a SUCCESSFUL flush both queues are
        // empty, so this is a no-op and `loadSync()` stays authoritative.
        guard !pendingUpserts.isEmpty || !pendingDeletes.isEmpty else { return }
        let merged = Self.deduplicatedByID(Array(pendingUpserts.values) + items)
        items = merged.filter { !pendingDeletes.contains($0.id) }
    }

    /// Inserts a new item or replaces the existing one with the same id.
    public func upsert(_ item: CustomizationItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        enqueueUpsert(item)
    }

    /// Removes the item from the closet and enqueues its per-row delete.
    public func delete(id: UUID) {
        items.removeAll { $0.id == id }
        enqueueDelete(id)
    }

    /// Toggles whether the item is offered in the in-person shop; unknown ids are ignored.
    public func setShareable(id: UUID, _ shareable: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isShareable = shareable
        enqueueUpsert(items[index])
    }

    /// Sets the item's coin price for the in-person shop; unknown ids are ignored.
    public func setPrice(id: UUID, _ price: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].price = price
        enqueueUpsert(items[index])
    }

    /// Returns whether the persisted rows were actually deleted. Threaded back so "delete everything" can
    /// report a failed per-row CloudKit delete (designs left on disk to re-sync) instead of the funnel
    /// discarding it and claiming a complete wipe.
    @discardableResult
    public func reset() -> Bool {
        items = []
        pendingUpserts = [:]
        pendingDeletes = []
        saveScheduled = false
        return repository.deleteAll()
    }

    /// Writes any pending upserts/deletes to the store now; a failed write keeps that queue for retry.
    public func flushPendingSave() {
        // Flush whenever mutations are pending, NOT only when a debounced save is scheduled: a prior
        // scheduled flush that failed its write leaves `saveScheduled` false while the pending queues still
        // hold the only un-persisted copy, so gating on `saveScheduled` made the background retry a no-op and
        // silently lost a just-designed/bought item. The pending queues are the real "nothing to do" check.
        saveScheduled = false
        guard !pendingUpserts.isEmpty || !pendingDeletes.isEmpty else { return }
        let upserts = Array(pendingUpserts.values)
        let deletes = Array(pendingDeletes)
        // Clear each pending queue only AFTER its confirmed write — the queues are the sole un-persisted
        // copy of these mutations, so dropping them on a failed write would silently lose an item. On
        // failure, keep them; the next mutation (or the background flush) retries, and `reloadFromStore`
        // re-applies them so the in-memory closet still reflects the pending mutations. A failed write is an
        // expected, handled runtime condition (Core Data / CloudKit hiccup), NOT a precondition violation — so
        // it must not trap; the retry path above is exactly what makes it recoverable.
        let upsertOK = upserts.isEmpty || repository.upsert(upserts)
        let deleteOK = deletes.isEmpty || repository.delete(ids: deletes)
        if upsertOK { pendingUpserts = [:] }
        if deleteOK { pendingDeletes = [] }
    }

    // MARK: - Internals

    /// Queues an upsert (cancelling any pending delete of the same id) and schedules a flush.
    private func enqueueUpsert(_ item: CustomizationItem) {
        pendingUpserts[item.id] = item
        pendingDeletes.remove(item.id)
        scheduleSave()
    }

    /// Queues a delete (cancelling any pending upsert of the same id) and schedules a flush.
    private func enqueueDelete(_ id: UUID) {
        pendingDeletes.insert(id)
        pendingUpserts[id] = nil
        scheduleSave()
    }

    /// Collapses rows that share an id, keeping the first seen — the application-level union-merge for the
    /// per-row store (CloudKit can hold duplicate-id rows: two devices buying the same friend's item,
    /// which keeps its original id). Mirrors `CoinEconomy.deduplicatedByID`.
    private static func deduplicatedByID(_ items: [CustomizationItem]) -> [CustomizationItem] {
        var seen = Set<UUID>()
        var unique: [CustomizationItem] = []
        unique.reserveCapacity(items.count)
        for item in items where seen.insert(item.id).inserted { unique.append(item) }
        return unique
    }

    /// Coalesces mutations into one debounced main-actor flush per burst.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            await Task.yield()
            await MainActor.run {
                guard let self else { return }
                self.flushPendingSave()
            }
        }
    }
}
