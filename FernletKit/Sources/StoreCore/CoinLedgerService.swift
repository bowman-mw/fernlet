import Foundation
import Observation
import FernletPersistence
import FernletDomainModel

/// Owns the coin ledger in memory and persists it to its own per-row store (separate from the snapshot
/// blob). Earning is recorded by `reconcile` — one idempotent `earn` row per active day, so the earned
/// total never shrinks when the day history does (HealthKit disable, 370-day prune). Spending appends a
/// `spend` row. The spendable balance is the aggregate (`CoinEconomy`, which collapses duplicate-id rows
/// — the cross-device union-merge — since the store itself does not). Mirrors `CustomItemService`'s
/// debounced-save shape, but the underlying store is APPEND-ONLY (`append`, never delete-unlisted), so
/// flushing a stale in-memory set can't clobber rows that synced in from another device.
@MainActor
@Observable
public final class CoinLedgerService {
    public private(set) var entries: [CoinLedgerEntry] = []

    @ObservationIgnored private let repository: any CoinLedgerRepositoring
    /// Rows minted locally but not yet written. Only these are appended on flush, so the persisted store
    /// is touched surgically per-row and never re-writes (or deletes) the rest of the ledger.
    @ObservationIgnored private var pendingAppends: [CoinLedgerEntry] = []
    @ObservationIgnored private var saveScheduled = false
    @ObservationIgnored private let now: () -> Date

    public init(repository: any CoinLedgerRepositoring, initialEntries: [CoinLedgerEntry] = [], now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.entries = initialEntries
        self.now = now
    }

    // MARK: - Derived balances

    public var earnedCoins: Int { CoinEconomy.earned(in: entries) }
    public var spentCoins: Int { CoinEconomy.spent(in: entries) }
    public var balance: Int { CoinEconomy.balance(in: entries) }

    // MARK: - Loading

    public func loadSync() {
        entries = CoinEconomy.deduplicatedByID(repository.load())
    }

    public func loadAsync() async {
        entries = CoinEconomy.deduplicatedByID(await repository.loadAsync())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up earn/spend rows that synced in
    /// from another device. Call when a remote CloudKit change lands so the balance tracks other devices.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
    }

    // MARK: - Earning (idempotent)

    /// Credits any active day not yet credited. Idempotent: an `earn` row's id is derived from its day,
    /// so re-running with the same (or an overlapping) set of days mints nothing new and never
    /// double-grants. Safe to call often (store launch, app foreground).
    public func reconcile(activeDayKeys: Set<String>) {
        let missing = CoinEconomy.missingEarnEntries(activeDayKeys: activeDayKeys, existing: entries, at: now())
        guard !missing.isEmpty else { return }
        record(missing)
    }

    // MARK: - Spending

    /// Spends `amount` coins if the balance covers it, appending a `spend` row keyed by `ref` (so a
    /// retried purchase with the same ref can't debit twice). Returns `false` and changes nothing when
    /// `amount` is non-positive or exceeds the balance, or when `ref` was already spent.
    ///
    /// The guard uses this device's current in-memory ledger. Across devices spending offline, each may
    /// independently approve a spend of the same coins; both rows then sum (distinct refs) and the balance
    /// floors at zero — a bounded over-acquisition that is inherent without a server and is accepted.
    /// `reloadFromStore` (on remote sync) narrows the window by refreshing before the next spend.
    @discardableResult
    public func spend(amount: Int, ref: String) -> Bool {
        guard CoinEconomy.canSpend(amount: amount, in: entries) else { return false }
        let id = CoinLedgerEntry.spendID(ref: ref)
        guard !entries.contains(where: { $0.id == id }) else { return false }
        record([CoinLedgerEntry.spend(ref: ref, amount: amount, at: now())])
        return true
    }

    // MARK: - Reset / flush

    public func reset() {
        entries = []
        pendingAppends = []
        saveScheduled = false
        repository.deleteAll()
    }

    public func flushPendingSave() {
        guard saveScheduled else { return }
        saveScheduled = false
        guard !pendingAppends.isEmpty else { return }
        // Clear the pending queue only AFTER a confirmed save — `pendingAppends` is the sole un-persisted
        // copy of these rows (the per-row store has no other retry queue), so dropping them on a failed
        // append would silently lose an earned day or a spend. On failure, keep them; the next mutation
        // (or the background flush in `flushPendingSnapshotSave`) retries.
        let saved = repository.append(pendingAppends)
        assert(saved, "coin ledger should save")
        if saved { pendingAppends = [] }
    }

    // MARK: - Internals

    /// Adds new rows to the in-memory ledger and the pending-append queue (deduped by id), then schedules
    /// a flush. Rows already present are ignored — the structural guarantee behind idempotent earning.
    private func record(_ newEntries: [CoinLedgerEntry]) {
        var added = false
        for entry in newEntries where !entries.contains(where: { $0.id == entry.id }) {
            entries.append(entry)
            pendingAppends.append(entry)
            added = true
        }
        if added { scheduleSave() }
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
