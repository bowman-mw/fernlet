import Foundation
import Observation
import FernletPersistence
import FernletDomainModel

/// Owns the milestone (cumulative achievements) ledger in memory and persists it to its own
/// per-row store — a direct mirror of `CoinLedgerService`'s debounced append-only shape, minus any
/// reset: milestone rows are lifetime memories of care and deliberately survive
/// `FernletStore.resetAll` (the repository protocol has no delete; see
/// `MilestoneLedgerRepositoring`). Lifetime counts are distinct-row counts over the union-merged
/// rows (`MilestoneEconomy`), so they are monotonic and sync-safe across devices.
@MainActor
@Observable
public final class MilestoneLedgerService {
    public private(set) var entries: [MilestoneLedgerEntry] = []

    @ObservationIgnored private let repository: any MilestoneLedgerRepositoring
    /// Rows minted locally but not yet written. Only these are appended on flush, so the persisted
    /// store is touched surgically per-row and never re-writes the rest of the ledger.
    @ObservationIgnored private var pendingAppends: [MilestoneLedgerEntry] = []
    @ObservationIgnored private var saveScheduled = false

    public init(repository: any MilestoneLedgerRepositoring, initialEntries: [MilestoneLedgerEntry] = []) {
        self.repository = repository
        self.entries = initialEntries
    }

    // MARK: - Derived counts

    /// Lifetime care counts per kind (distinct-row counts — cumulative only, never a streak).
    public var lifetimeCounts: [MilestoneEventKind: Int] {
        MilestoneEconomy.lifetimeCounts(in: entries)
    }

    // MARK: - Loading

    public func loadSync() {
        entries = MilestoneEconomy.deduplicatedByID(repository.load())
    }

    public func loadAsync() async {
        entries = MilestoneEconomy.deduplicatedByID(await repository.loadAsync())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up event rows that synced in
    /// from another device. Mirrors `CoinLedgerService.reloadFromStore`, including the failed-flush
    /// re-merge: rows a failed append left only in `pendingAppends` are folded back on top of the
    /// freshly loaded set so a not-yet-persisted event never vanishes from the in-memory counts.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
        guard !pendingAppends.isEmpty else { return }
        entries = MilestoneEconomy.deduplicatedByID(pendingAppends + entries)
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
            pendingAppends.append(entry)
            added = true
        }
        if added { scheduleSave() }
    }

    // MARK: - Flush

    /// Same retry contract as `CoinLedgerService.flushPendingSave`: pending rows are the sole
    /// un-persisted copy, so they are cleared only after a confirmed save; a failed append keeps
    /// them queued for the next flush (and `reloadFromStore` re-merges them meanwhile).
    public func flushPendingSave() {
        saveScheduled = false
        guard !pendingAppends.isEmpty else { return }
        let saved = repository.append(pendingAppends)
        if saved { pendingAppends = [] }
    }

    // MARK: - Internals

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
