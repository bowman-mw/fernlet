// PendingWriteBuffer.swift
// The debounced pending-write machinery shared by the four per-row StoreCore services.
//
// SavedRecipeService/CustomItemService (upsert+delete rows) and CoinLedgerService/
// MilestoneLedgerService (append-only rows) used to carry four byte-identical copies of the same
// queue-then-debounce-then-flush mechanics — including the same hard-won bug-fix comments. The two
// classes here are those mechanics factored out verbatim; everything service-specific (what a row
// means, dedup on load, reset semantics, idempotent minting) stays in the owning service.

import Foundation

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
    public func enqueueUpsert(_ item: Item) {
        pendingUpserts[item.id] = item
        pendingDeletes.remove(item.id)
        scheduleSave()
    }

    /// Queues a delete (cancelling any pending upsert of the same id) and schedules a flush.
    public func enqueueDelete(_ id: Item.ID) {
        pendingDeletes.insert(id)
        pendingUpserts[id] = nil
        scheduleSave()
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
        if upsertOK { pendingUpserts = [:] }
        if deleteOK { pendingDeletes = [] }
    }

    /// Drops every queued mutation and any scheduled flush — for the owner's `reset()`, where the
    /// persisted rows are being deleted wholesale and a pending write must not resurrect them.
    public func clear() {
        pendingUpserts = [:]
        pendingDeletes = []
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

    /// Drops every queued row and any scheduled flush — for `CoinLedgerService.reset()`, which
    /// replaces the queue wholesale around its reset-boundary marker write.
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
