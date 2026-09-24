// PendingWriteBuffer.swift
// The debounced pending-write machinery shared by the four per-row StoreCore services.
//
// SavedRecipeService/CustomItemService (upsert+delete rows) and CoinLedgerService/
// MilestoneLedgerService (append-only rows) used to carry four byte-identical copies of the same
// queue-then-debounce-then-flush mechanics — including the same hard-won bug-fix comments. The two
// classes here are those mechanics factored out verbatim; everything service-specific (what a row
// means, dedup on load, reset semantics, idempotent minting) stays in the owning service. The third
// type, `PendingResetBoundaries` (2026-09-24), is the durable reset-boundary half the two ledgers
// share: the marker a wipe appends is remembered device-locally before the rows go, so a failed
// append no longer lives only in the in-memory queue.

import Foundation
import FernletFoundation

/// Bounds shared by the two debounced pending-write buffers (R3: bounded growth).
///
/// A namespace enum rather than a static on the buffers themselves, because a generic type cannot
/// hold a static stored property.
public enum PendingWriteLimits {
    /// Hard cap on each pending queue.
    ///
    /// The queues clear only after a CONFIRMED write, so while the store keeps failing — a Core Data
    /// or CloudKit fault, or read-only recovery, which refuses every write for the rest of the
    /// session — every subsequent user mutation would otherwise append with no ceiling. "Drop
    /// nothing" is deliberate (these queues are the sole un-persisted copy of a mutation); "grow
    /// without bound" is not, so the oldest entry is evicted and audit-logged rather than dropped
    /// silently.
    public static let maxPendingItems = 2_000

    /// Hard cap on the reset-boundary markers one ledger's device-local sidecar holds while their
    /// synced append is outstanding (`PendingResetBoundaries`). One wipe mints one marker and a
    /// landed marker is retired, so this is only ever reached by repeated wipes on a store that
    /// keeps refusing writes; the oldest goes first, because on any sane clock a newer boundary voids
    /// everything an older one does.
    public static let maxPendingResetBoundaries = 8
}

/// The debounced per-row pending-write buffer shared by ``SavedRecipeService`` and
/// ``CustomItemService``: locally mutated rows are queued as upserts/deletes keyed by id and
/// written in one debounced main-actor flush per burst.
///
/// Durability contract (the type's whole point): the pending queues are the SOLE un-persisted
/// copy of a mutation. ``flush()`` clears each queue only after its confirmed write; a failed
/// write keeps that queue for retry and never traps (a Core Data / CloudKit hiccup is an
/// expected, handled runtime condition); and the owning service's `reloadFromStore()` re-applies
/// still-pending mutations — read via ``pendingUpserts`` / ``pendingDeletes`` — on top of freshly
/// loaded rows so nothing vanishes from the in-memory view while a retry is outstanding.
/// ``enqueueUpsert(_:)`` cancels a pending delete of the same id and vice versa; both schedule
/// the debounced flush.
///
/// The write closures are injected at init and must capture the owning service's repository (a
/// `let`), never the service itself — the service → buffer → closure chain then holds no retain
/// cycle, and the debounce task's weak self-capture preserves the original "owner gone → flush
/// skipped" lifetime semantics. `@MainActor`, like the repository protocols the closures call.
@MainActor
public final class DebouncedRowBuffer<Item: Identifiable> {
    /// Rows mutated locally but not yet written, keyed by id (a re-enqueued row replaces its
    /// earlier pending copy). Exposed read-only for the owner's failed-flush re-merge.
    public private(set) var pendingUpserts: [Item.ID: Item] = [:]
    /// Ids deleted locally but not yet written. Exposed read-only for the owner's failed-flush
    /// re-merge.
    public private(set) var pendingDeletes: Set<Item.ID> = []
    /// Insertion order of ``pendingUpserts`` / ``pendingDeletes`` keys, so "oldest" is well defined
    /// when the overflow cap evicts.
    private var pendingUpsertOrder: [Item.ID] = []
    private var pendingDeleteOrder: [Item.ID] = []
    private var saveScheduled = false

    private let upsert: @MainActor ([Item]) -> Bool
    private let delete: @MainActor ([Item.ID]) -> Bool

    /// Creates the buffer over the store's two per-row write primitives. The closures must
    /// capture the repository value, not the owning service (see the type docs for why).
    public init(
        upsert: @escaping @MainActor ([Item]) -> Bool,
        delete: @escaping @MainActor ([Item.ID]) -> Bool
    ) {
        self.upsert = upsert
        self.delete = delete
    }

    /// Whether any mutation is queued — the real "work to do" check for a flush.
    public var hasPending: Bool { !pendingUpserts.isEmpty || !pendingDeletes.isEmpty }

    /// Queues an upsert (cancelling any pending delete of the same id) and schedules a flush.
    /// Re-enqueuing an already-pending id replaces it in place and never grows the queue.
    public func enqueueUpsert(_ item: Item) {
        if pendingUpserts[item.id] == nil {
            evictOldestUpsertIfFull()
            pendingUpsertOrder.append(item.id)
        }
        pendingUpserts[item.id] = item
        if pendingDeletes.remove(item.id) != nil {
            pendingDeleteOrder.removeAll { $0 == item.id }
        }
        scheduleSave()
    }

    /// Queues a delete (cancelling any pending upsert of the same id) and schedules a flush.
    public func enqueueDelete(_ id: Item.ID) {
        if !pendingDeletes.contains(id) {
            evictOldestDeleteIfFull()
            pendingDeleteOrder.append(id)
            pendingDeletes.insert(id)
        }
        if pendingUpserts.removeValue(forKey: id) != nil {
            pendingUpsertOrder.removeAll { $0 == id }
        }
        scheduleSave()
    }

    /// Drops the oldest queued upsert once the queue is at ``maxPendingItems`` — oldest-out, logged.
    private func evictOldestUpsertIfFull() {
        guard pendingUpserts.count >= PendingWriteLimits.maxPendingItems, !pendingUpsertOrder.isEmpty else { return }
        let dropped = pendingUpsertOrder.removeFirst()
        pendingUpserts[dropped] = nil
        FernletAuditLog.log("rowBuffer.overflow", context: [
            "cap": "\(PendingWriteLimits.maxPendingItems)",
            "queue": "upserts"
        ])
    }

    /// Drops the oldest queued delete once the queue is at ``maxPendingItems`` — oldest-out, logged.
    private func evictOldestDeleteIfFull() {
        guard pendingDeletes.count >= PendingWriteLimits.maxPendingItems, !pendingDeleteOrder.isEmpty else { return }
        let dropped = pendingDeleteOrder.removeFirst()
        pendingDeletes.remove(dropped)
        FernletAuditLog.log("rowBuffer.overflow", context: [
            "cap": "\(PendingWriteLimits.maxPendingItems)",
            "queue": "deletes"
        ])
    }

    /// Writes any pending upserts/deletes to the store now; a failed write keeps that queue for retry.
    public func flush() {
        // Flush whenever mutations are pending, NOT only when a debounced save is scheduled: a prior
        // scheduled flush that failed its write leaves `saveScheduled` false while the pending queues still
        // hold the only un-persisted copy, so gating on `saveScheduled` made the background retry a no-op and
        // silently lost a mutation. The pending queues are the real "nothing to do" check.
        saveScheduled = false
        guard hasPending else { return }
        let upserts = Array(pendingUpserts.values)
        let deletes = Array(pendingDeletes)
        // Clear each pending queue only AFTER its confirmed write — the queues are the sole un-persisted
        // copy of these mutations, so dropping them on a failed write would silently lose one. On failure,
        // keep them; the next mutation (or the background flush) retries, and the owner's `reloadFromStore`
        // re-applies them so the in-memory view still reflects the pending mutations. A failed write is an
        // expected, handled runtime condition (Core Data / CloudKit hiccup), NOT a precondition violation — so
        // it must not trap; the retry path above is exactly what makes it recoverable.
        let upsertOK = upserts.isEmpty || upsert(upserts)
        let deleteOK = deletes.isEmpty || delete(deletes)
        if upsertOK {
            pendingUpserts = [:]
            pendingUpsertOrder = []
        }
        if deleteOK {
            pendingDeletes = []
            pendingDeleteOrder = []
        }
    }

    /// Drops every queued mutation and any scheduled flush — for the owner's `reset()`, where the
    /// persisted rows are being deleted wholesale and a pending write must not resurrect them.
    public func clear() {
        pendingUpserts = [:]
        pendingDeletes = []
        pendingUpsertOrder = []
        pendingDeleteOrder = []
        saveScheduled = false
    }

    /// Coalesces mutations into one debounced main-actor flush per burst.
    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            await Task.yield()
            await MainActor.run {
                guard let self else { return }
                self.flush()
            }
        }
    }
}

/// The debounced append-only pending-write buffer shared by ``CoinLedgerService`` and
/// ``MilestoneLedgerService``: locally minted ledger rows are queued and appended to the store in
/// one debounced main-actor flush per burst.
///
/// Same durability contract as ``DebouncedRowBuffer``: ``pending`` is the SOLE un-persisted copy
/// of the queued rows; ``flush()`` clears it only after a confirmed append; a failed append keeps
/// the rows queued for retry and never traps; and the owning service's `reloadFromStore()`
/// re-merges ``pending`` on top of freshly loaded rows. Unlike the row buffer, ``enqueue(_:)``
/// deliberately does NOT auto-schedule — the ledger services' `record` enqueues N rows and then
/// calls ``scheduleSave()`` once per batch, and `CoinLedgerService.reset()` uses the same split to
/// re-arm a failed reset-marker append.
///
/// The append closure must capture the owning service's repository (a `let`), never the service
/// itself — no retain cycle, and the debounce task's weak self-capture preserves the original
/// "owner gone → flush skipped" lifetime semantics. `@MainActor`, like the repository protocols.
@MainActor
public final class DebouncedAppendBuffer<Entry> {
    /// Rows minted locally but not yet written. Exposed read-only for the owner's failed-flush
    /// re-merge.
    public private(set) var pending: [Entry] = []
    private var saveScheduled = false

    private let append: @MainActor ([Entry]) -> Bool

    /// Creates the buffer over the store's append-only write primitive. The closure must capture
    /// the repository value, not the owning service (see the type docs for why).
    public init(append: @escaping @MainActor ([Entry]) -> Bool) {
        self.append = append
    }

    /// Queues a row for the next flush. Deliberately schedules nothing — callers batch enqueues
    /// and call ``scheduleSave()`` once per burst.
    public func enqueue(_ entry: Entry) {
        if pending.count >= PendingWriteLimits.maxPendingItems {
            pending.removeFirst()
            FernletAuditLog.log("appendBuffer.overflow", context: ["cap": "\(PendingWriteLimits.maxPendingItems)"])
        }
        pending.append(entry)
    }

    /// Writes any pending rows to the store now; a failed append keeps them queued for the next retry.
    public func flush() {
        // Flush whenever rows are pending, NOT only when a debounced save is scheduled: a prior scheduled
        // flush that failed its append leaves `saveScheduled` false while `pending` still holds the only
        // un-persisted copy, so gating on `saveScheduled` here made the background retry a no-op and
        // silently dropped a row on the next launch. `pending.isEmpty` is the real "nothing to do" condition.
        saveScheduled = false
        guard !pending.isEmpty else { return }
        // Clear the pending queue only AFTER a confirmed save — `pending` is the sole un-persisted copy of
        // these rows (the per-row store has no other retry queue), so dropping them on a failed append would
        // silently lose one. On failure, keep them; the next mutation (or the background flush) retries, and
        // the owner's `reloadFromStore` re-merges them so the in-memory view still reflects the pending rows.
        // A failed append is an expected, handled runtime condition (Core Data / CloudKit hiccup), NOT a
        // precondition violation — so it must not trap; the retry path above is what makes it recoverable.
        let saved = append(pending)
        if saved { pending = [] }
    }

    /// Drops every queued row and any scheduled flush — for the ledger resets:
    /// `CoinLedgerService.reset()` replaces the queue wholesale around its reset-boundary marker
    /// write, and `MilestoneLedgerService.reset(deletingRowsWith:)` drops the queue BEFORE deleting
    /// the stored rows so a queued row can never flush back onto a just-emptied store.
    public func clear() {
        pending = []
        saveScheduled = false
    }

    /// Coalesces mutations into one debounced main-actor flush per burst.
    public func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task { [weak self] in
            await Task.yield()
            await MainActor.run {
                guard let self else { return }
                self.flush()
            }
        }
    }
}

/// The DURABLE half of an append-only ledger's reset boundary, shared by ``CoinLedgerService`` and
/// ``MilestoneLedgerService`` (tracker §3.6, 2026-09-24).
///
/// A ledger reset deletes the rows and appends a boundary marker to the SYNCED store; the marker is
/// what keeps rows another signed-in device still holds from counting again when they sync back. A
/// marker that never lands is a wipe that device can undo. Before this type, a failed marker append
/// lived only in the in-memory ``DebouncedAppendBuffer``, so a process death before the retry lost
/// the boundary silently — `loadSync()` on the next launch had nothing to re-merge.
///
/// The contract, in the order a reset uses it:
/// 1. ``remember(_:)`` writes the marker to the store's device-local, never-synced sidecar
///    (`pendingResetBoundaries()` on the repository contract) BEFORE a single row is deleted.
/// 2. ``landPending()`` appends every remembered marker to the synced store and retires the sidecar
///    once they land, returning the markers that are STILL pending.
/// 3. Every load calls ``landPending()`` again and MERGES what it returns into the in-memory
///    ledger, so the aggregation voids pre-boundary rows even while the synced marker is missing —
///    and the append is retried on every launch until it lands. The append is an upsert by id, so a
///    retry of a marker that did land is a no-op.
///
/// Bounded (R3) at ``PendingWriteLimits/maxPendingResetBoundaries`` markers, oldest dropped. The
/// three closures capture the owning service's repository, never the service — the same no-cycle
/// rule as the buffers above. `@MainActor`, like the repository contracts they call.
@MainActor
struct PendingResetBoundaries<Entry: Identifiable> {
    /// Reads the sidecar.
    let load: @MainActor () -> [Entry]
    /// Replaces the sidecar (empty = retired); false when the write did not land.
    let save: @MainActor ([Entry]) -> Bool
    /// The synced store's append (an upsert by id).
    let append: @MainActor ([Entry]) -> Bool
    /// The frozen audit token prefix naming the ledger (`coinLedger`, `milestoneLedger`).
    let store: String

    /// Records `marker` as pending, durably, ahead of the row delete. A failed write is audited and
    /// the reset carries on — the user's delete must still happen — so the only cost is the
    /// pre-2026-09-24 behaviour for this one wipe.
    func remember(_ marker: Entry) {
        let pending = load().filter { $0.id != marker.id } + [marker]
        if !save(Array(pending.suffix(PendingWriteLimits.maxPendingResetBoundaries))) {
            FernletAuditLog.log("resetBoundary.notDurable", context: ["store": store])
        }
    }

    /// Appends every pending marker — plus `extra`, the marker a reset just minted, so it is appended
    /// even when ``remember(_:)`` could not reach the sidecar — to the synced store, and retires the
    /// sidecar once they land. Returns the markers still pending: empty once they have landed, or
    /// when nothing was.
    func landPending(including extra: [Entry] = []) -> [Entry] {
        var seen = Set<Entry.ID>()
        let pending = (load() + extra).filter { seen.insert($0.id).inserted }
        guard !pending.isEmpty else { return [] }
        guard append(pending) else {
            FernletAuditLog.log("resetBoundary.stillPending", context: ["store": store, "count": "\(pending.count)"])
            return pending
        }
        if !save([]) {
            // Landed but not retired: the next load re-appends (an idempotent upsert) and retires.
            FernletAuditLog.log("resetBoundary.retireFailed", context: ["store": store])
        }
        return []
    }
}
