import Foundation
import Observation
import FernletPersistence
import FernletDomainModel

/// Owns the user's custom-item collection in memory and persists it to its own per-row store (separate
/// from the snapshot blob). Mirrors `CoinLedgerService`: mutations are queued per-row and flushed via an
/// APPEND/UPSERT-ONLY repository, so flushing a stale in-memory set can never delete rows that synced in
/// from another device (the cross-device clobber the in-person clothing shop's buy would otherwise
/// trigger). Equip state is NOT here — it lives in settings (`DiaryStore`) as a tiny UUID map.
@MainActor
@Observable
public final class CustomItemService {
    public private(set) var items: [CustomizationItem] = []

    @ObservationIgnored private let repository: any CustomItemRepositoring
    /// Rows mutated locally but not yet written. Only these are flushed (upserted/deleted) so the
    /// persisted store is touched surgically per-row and never re-writes (or deletes) the rest.
    @ObservationIgnored private var pendingUpserts: [UUID: CustomizationItem] = [:]
    @ObservationIgnored private var pendingDeletes: Set<UUID> = []
    @ObservationIgnored private var saveScheduled = false

    public init(repository: any CustomItemRepositoring, initialItems: [CustomizationItem] = []) {
        self.repository = repository
        self.items = Self.deduplicatedByID(initialItems)
    }

    public func loadSync() {
        items = Self.deduplicatedByID(repository.load())
    }

    public func loadAsync() async {
        items = Self.deduplicatedByID(await repository.loadAsync())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up item rows that synced in from
    /// another device. Call when a remote CloudKit change lands so the closet tracks other devices.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
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

    public func delete(id: UUID) {
        items.removeAll { $0.id == id }
        enqueueDelete(id)
    }

    public func setShareable(id: UUID, _ shareable: Bool) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isShareable = shareable
        enqueueUpsert(items[index])
    }

    public func setPrice(id: UUID, _ price: Int) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].price = price
        enqueueUpsert(items[index])
    }

    public func reset() {
        items = []
        pendingUpserts = [:]
        pendingDeletes = []
        saveScheduled = false
        repository.deleteAll()
    }

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
        // failure, keep them; the next mutation (or the background flush) retries.
        let upsertOK = upserts.isEmpty || repository.upsert(upserts)
        let deleteOK = deletes.isEmpty || repository.delete(ids: deletes)
        assert(upsertOK && deleteOK, "custom items should save")
        if upsertOK { pendingUpserts = [:] }
        if deleteOK { pendingDeletes = [] }
    }

    // MARK: - Internals

    private func enqueueUpsert(_ item: CustomizationItem) {
        pendingUpserts[item.id] = item
        pendingDeletes.remove(item.id)
        scheduleSave()
    }

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
