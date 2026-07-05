import Foundation
import Observation
import FernletPersistence
import FernletDomainModel
import FernletFoundation

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
        // If the flush FAILED, its rows survive only in `pendingAppends` (append rolled the Core Data context
        // back), and `loadSync()` just replaced `entries` with store contents that LACK them — dropping an
        // un-persisted earn/spend from the in-memory ledger and inflating the balance (the user could re-spend
        // the same coins). Re-merge the still-pending rows on top of the freshly loaded set (union by id, via
        // the same dedup used everywhere), keeping the pending queue intact so the next scheduled save retries.
        // On a SUCCESSFUL flush `pendingAppends` is empty, so this is a no-op and `loadSync()` stays authoritative.
        guard !pendingAppends.isEmpty else { return }
        entries = CoinEconomy.deduplicatedByID(pendingAppends + entries)
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

    /// Appends caller-built earn rows carrying DETERMINISTIC ids (milestone awards,
    /// `milestone:<kind>:<threshold>` — see `MilestoneEconomy.missingAwards`, which also applies the
    /// reset-boundary filter before building them). Idempotent per id via `record`; non-earn rows
    /// are refused so this can never be misused to inject spends or reset markers.
    public func grantEarns(_ newEntries: [CoinLedgerEntry]) {
        record(newEntries.filter { $0.kind == .earn })
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
        // Delete every row (honoring the user's "delete all data" intent — the deletes propagate to their
        // other devices via CloudKit), THEN append a reset-boundary marker. The marker makes reconcile refuse
        // to re-mint earns for pre-reset days and makes the balance void any pre-reset row that lingers or
        // re-syncs from an offline device, so a reset can't be undone by another device deterministically
        // re-minting earns for pre-reset days. This is the append-only economy's "zero the balance".
        repository.deleteAll()
        let at = now()
        let marker = CoinLedgerEntry.reset(dayKey: FernletDate.dayKey(for: at), at: at)
        entries = [marker]
        saveScheduled = false
        if repository.append([marker]) {
            pendingAppends = []
        } else {
            pendingAppends = [marker]
            scheduleSave()
        }
    }

    public func flushPendingSave() {
        // Flush whenever rows are pending, NOT only when a debounced save is scheduled: a prior scheduled
        // flush that failed its append leaves `saveScheduled` false while `pendingAppends` still holds the
        // only un-persisted copy, so gating on `saveScheduled` here made the background retry
        // (flushPendingSnapshotSave) a no-op and silently dropped an earned day or a spend on the next
        // launch. `pendingAppends.isEmpty` is the real "nothing to do" condition.
        saveScheduled = false
        guard !pendingAppends.isEmpty else { return }
        // Clear the pending queue only AFTER a confirmed save — `pendingAppends` is the sole un-persisted
        // copy of these rows (the per-row store has no other retry queue), so dropping them on a failed
        // append would silently lose an earned day or a spend. On failure, keep them; the next mutation
        // (or the background flush in `flushPendingSnapshotSave`) retries, and `reloadFromStore` re-merges
        // them so the in-memory balance still reflects the pending rows. A failed append is an expected,
        // handled runtime condition (Core Data / CloudKit hiccup), NOT a precondition violation — so it must
        // not trap; the retry path above is exactly what makes it recoverable.
        let saved = repository.append(pendingAppends)
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
