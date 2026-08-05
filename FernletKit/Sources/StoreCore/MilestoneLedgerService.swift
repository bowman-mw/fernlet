import Foundation
import Observation
import FernletPersistence
import FernletDomainModel

/// Owns the milestone (cumulative achievements) ledger in memory and persists it to its own
/// per-row store — a direct mirror of ``CoinLedgerService``'s debounced append-only shape, minus any
/// reset: milestone rows are lifetime memories of care and deliberately survive
/// `FernletStore.resetAll` (the repository protocol has no delete; see
/// `MilestoneLedgerRepositoring`). Lifetime counts are distinct-row counts over the union-merged
/// rows (`MilestoneEconomy`), so they are monotonic and sync-safe across devices.
///
/// Collaborators: the injected `MilestoneLedgerRepositoring` store (concretely CloudKitSync's
/// `MilestoneLedgerRepository`, behind the FernletPersistence protocol) and `FernletStore`, which
/// records events from both the live logging hooks and the day-history reconcile — deterministic
/// event ids make those overlapping inputs safe. Same durability invariant as the coin ledger:
/// pending rows are the sole un-persisted copy, cleared only after a confirmed append, with
/// ``reloadFromStore()`` re-merging them after a failed flush. `@MainActor` and `@Observable`.
@MainActor
@Observable
public final class MilestoneLedgerService {
    /// The in-memory ledger, union-merged (deduplicated by id) on every load.
    public private(set) var entries: [MilestoneLedgerEntry] = []

    @ObservationIgnored private let repository: any MilestoneLedgerRepositoring
    /// The shared debounced append-only queue — the sole un-persisted copy of locally minted rows,
    /// appended surgically per-row so the persisted store never re-writes the rest of the ledger
    /// (see ``DebouncedAppendBuffer``). Its append closure captures `repository`, never `self`.
    @ObservationIgnored private let buffer: DebouncedAppendBuffer<MilestoneLedgerEntry>

    /// Creates the service over its per-row store; `initialEntries` seeds the ledger before the first load.
    public init(repository: any MilestoneLedgerRepositoring, initialEntries: [MilestoneLedgerEntry] = []) {
        self.repository = repository
        self.buffer = DebouncedAppendBuffer(append: { repository.append($0) })
        self.entries = initialEntries
    }

    // MARK: - Derived counts

    /// Lifetime care counts per kind (distinct-row counts — cumulative only, never a streak).
    public var lifetimeCounts: [MilestoneEventKind: Int] {
        MilestoneEconomy.lifetimeCounts(in: entries)
    }

    // MARK: - Loading

    /// Replaces the in-memory ledger with the store's rows, union-merged by id.
    public func loadSync() {
        entries = MilestoneEconomy.deduplicatedByID(repository.load())
    }

    /// Async variant of ``loadSync()`` for the off-main initial load.
    public func loadAsync() async {
        entries = MilestoneEconomy.deduplicatedByID(await repository.loadAsync())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up event rows that synced in
    /// from another device. Mirrors `CoinLedgerService.reloadFromStore`, including the failed-flush
    /// re-merge: rows a failed append left only in the pending queue are folded back on top of the
    /// freshly loaded set so a not-yet-persisted event never vanishes from the in-memory counts.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
        guard !buffer.pending.isEmpty else { return }
        entries = MilestoneEconomy.deduplicatedByID(buffer.pending + entries)
    }

    // MARK: - Recording (idempotent)

    /// Adds any of `newEntries` not already present (by id) to the in-memory ledger and the
    /// pending-append queue, then schedules a flush. Re-recording a known event is a no-op — the
    /// structural guarantee behind idempotent counting (deterministic ids make this safe to call
    /// from both the live hooks and the day-history reconcile with overlapping inputs).
    public func record(_ newEntries: [MilestoneLedgerEntry]) {
        guard !newEntries.isEmpty else { return }
        var existingIDs = Set(entries.map(\.id))
        var added = false
        for entry in newEntries where existingIDs.insert(entry.id).inserted {
            entries.append(entry)
            buffer.enqueue(entry)
            added = true
        }
        if added { buffer.scheduleSave() }
    }

    // MARK: - Flush

    /// Same retry contract as `CoinLedgerService.flushPendingSave`: pending rows are the sole
    /// un-persisted copy, so they are cleared only after a confirmed save; a failed append keeps
    /// them queued for the next flush (and `reloadFromStore` re-merges them meanwhile). The full
    /// durability contract lives on ``DebouncedAppendBuffer/flush()``.
    public func flushPendingSave() {
        buffer.flush()
    }
}
