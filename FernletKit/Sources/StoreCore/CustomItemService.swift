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
/// Invariants: the buffer's pending queues are the sole un-persisted copy of a mutation —
/// ``flushPendingSave()`` clears each queue only after its confirmed write, and ``reloadFromStore()``
/// re-applies still-pending mutations after a failed flush, so a just-designed or just-bought item is
/// never silently lost (the shared contract lives on ``DebouncedRowBuffer``). `@MainActor` and
/// `@Observable`.
@MainActor
@Observable
public final class CustomItemService {
    /// The in-memory closet, union-merged (deduplicated by id) on init and every load.
    public private(set) var items: [CustomizationItem] = []

    @ObservationIgnored private let repository: any CustomItemRepositoring
    /// The shared debounced per-row queue — the sole un-persisted copy of local mutations, flushed
    /// (upserted/deleted) surgically per-row so the persisted store never re-writes (or deletes) the
    /// rest (see ``DebouncedRowBuffer``). Its write closures capture `repository`, never `self`.
    @ObservationIgnored private let buffer: DebouncedRowBuffer<CustomizationItem>

    /// Creates the service over its per-row store; `initialItems` seeds the closet before the first load.
    public init(repository: any CustomItemRepositoring, initialItems: [CustomizationItem] = []) {
        self.repository = repository
        self.buffer = DebouncedRowBuffer(
            upsert: { repository.upsert($0) },
            delete: { repository.delete(ids: $0) }
        )
        self.items = initialItems.deduplicatedByID()
    }

    /// Replaces the in-memory closet with the store's rows, union-merged by id.
    public func loadSync() {
        items = repository.load().deduplicatedByID()
    }

    /// Async variant of ``loadSync()`` for the off-main initial load.
    public func loadAsync() async {
        items = await repository.loadAsync().deduplicatedByID()
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
        guard buffer.hasPending else { return }
        let merged = (Array(buffer.pendingUpserts.values) + items).deduplicatedByID()
        items = merged.filter { !buffer.pendingDeletes.contains($0.id) }
    }

    /// Inserts a new item or replaces the existing one with the same id.
    public func upsert(_ item: CustomizationItem) {
        if let index = items.firstIndex(where: { $0.id == item.id }) {
            items[index] = item
        } else {
            items.append(item)
        }
        buffer.enqueueUpsert(item)
    }

    /// Removes the item from the closet and enqueues its per-row delete.
    public func delete(id: UUID) {
        items.removeAll { $0.id == id }
        buffer.enqueueDelete(id)
    }

    /// Toggles whether the item is offered in the in-person shop; unknown ids are ignored.
    public func setShareable(id: UUID, _ shareable: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isShareable = shareable
        buffer.enqueueUpsert(items[index])
    }

    /// Sets the item's coin price for the in-person shop; unknown ids are ignored.
    public func setPrice(id: UUID, _ price: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].price = price
        buffer.enqueueUpsert(items[index])
    }

    /// Returns whether the persisted rows were actually deleted. Threaded back so "delete everything" can
    /// report a failed per-row CloudKit delete (designs left on disk to re-sync) instead of the funnel
    /// discarding it and claiming a complete wipe.
    @discardableResult
    public func reset() -> Bool {
        items = []
        buffer.clear()
        return repository.deleteAll()
    }

    /// Writes any pending upserts/deletes to the store now; a failed write keeps that queue for
    /// retry (the full durability contract lives on ``DebouncedRowBuffer/flush()``).
    public func flushPendingSave() {
        buffer.flush()
    }
}
