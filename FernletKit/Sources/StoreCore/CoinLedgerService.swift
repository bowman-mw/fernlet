import Foundation
import Observation
import FernletPersistence
import FernletDomainModel
import FernletFoundation

/// Owns the coin ledger in memory and persists it to its own per-row store (separate from the snapshot
/// blob). Earning is recorded by ``reconcile(activeDayKeys:)`` — one idempotent `earn` row per active day,
/// so the earned total never shrinks when the day history does (HealthKit disable, 370-day prune).
/// Spending appends a `spend` row. The spendable balance is the aggregate (`CoinEconomy`, which collapses
/// duplicate-id rows — the cross-device union-merge — since the store itself does not). Mirrors
/// ``CustomItemService``'s debounced-save shape, but the underlying store is APPEND-ONLY (`append`, never
/// delete-unlisted), so flushing a stale in-memory set can't clobber rows that synced in from another device.
///
/// Collaborators: the injected `CoinLedgerRepositoring` store (concretely CloudKitSync's
/// `CoinLedgerRepository`, kept behind the FernletPersistence protocol so this module needs no
/// CloudKitSync edge), the pure `CoinEconomy` math in FernletDomainModel, and `FernletStore`, which
/// owns the instance, reconciles on launch/foreground, and calls ``reloadFromStore()`` when a remote
/// CloudKit change lands.
///
/// Invariants: rows are immutable once minted and carry deterministic ids (per-day earns, per-ref
/// spends), which is what makes every write path idempotent; pending rows are the sole un-persisted
/// copy of a mutation, so ``flushPendingSave()`` clears them only after a confirmed append and
/// ``reloadFromStore()`` re-merges them after a failed one — an earned day or a spend is never
/// silently dropped. `@MainActor` and `@Observable`; the injected `now` clock keeps row timestamps
/// testable.
@MainActor
@Observable
public final class CoinLedgerService {
    /// The in-memory ledger, union-merged (deduplicated by id) on every load.
    public private(set) var entries: [CoinLedgerEntry] = []

    @ObservationIgnored private let repository: any CoinLedgerRepositoring
    /// The shared debounced append-only queue — the sole un-persisted copy of locally minted rows,
    /// appended surgically per-row so the persisted store never re-writes (or deletes) the rest of
    /// the ledger (see ``DebouncedAppendBuffer``). Its append closure captures `repository`, never `self`.
    @ObservationIgnored private let buffer: DebouncedAppendBuffer<CoinLedgerEntry>
    @ObservationIgnored private let now: () -> Date

    /// Creates the service over its per-row store; `initialEntries` seeds the ledger before the first load.
    public init(repository: any CoinLedgerRepositoring, initialEntries: [CoinLedgerEntry] = [], now: @escaping () -> Date = Date.init) {
        self.repository = repository
        self.buffer = DebouncedAppendBuffer(append: { repository.append($0) })
        self.entries = initialEntries
        self.now = now
    }

    // MARK: - Derived balances

    /// Total coins earned, per `CoinEconomy` (reset-boundary markers void pre-reset earns).
    public var earnedCoins: Int { CoinEconomy.earned(in: entries) }
    /// Total coins spent, per `CoinEconomy` (reset-boundary markers void pre-reset spends).
    public var spentCoins: Int { CoinEconomy.spent(in: entries) }
    /// The spendable balance — earned minus spent over the id-collapsed rows, floored at zero.
    public var balance: Int { CoinEconomy.balance(in: entries) }

    // MARK: - Loading

    /// Replaces the in-memory ledger with the store's rows, union-merged by id.
    public func loadSync() {
        entries = CoinEconomy.deduplicatedByID(repository.load())
    }

    /// Async variant of ``loadSync()`` for the off-main initial load.
    public func loadAsync() async {
        entries = CoinEconomy.deduplicatedByID(await repository.loadAsync())
    }

    /// Re-reads the store (flushing any unsaved rows first), picking up earn/spend rows that synced in
    /// from another device. Call when a remote CloudKit change lands so the balance tracks other devices.
    public func reloadFromStore() {
        flushPendingSave()
        loadSync()
        // If the flush FAILED, its rows survive only in the pending queue (append rolled the Core Data context
        // back), and `loadSync()` just replaced `entries` with store contents that LACK them — dropping an
        // un-persisted earn/spend from the in-memory ledger and inflating the balance (the user could re-spend
        // the same coins). Re-merge the still-pending rows on top of the freshly loaded set (union by id, via
        // the same dedup used everywhere), keeping the pending queue intact so the next scheduled save retries.
        // On a SUCCESSFUL flush the queue is empty, so this is a no-op and `loadSync()` stays authoritative.
        guard !buffer.pending.isEmpty else { return }
        entries = CoinEconomy.deduplicatedByID(buffer.pending + entries)
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

    /// Returns whether the persisted rows were actually deleted. Threaded back so "delete everything" can
    /// report a failed per-row CloudKit delete (coins left on disk to re-sync) instead of the funnel
    /// discarding it and claiming a complete wipe. The returned value reflects only the row DELETE — the
    /// reset-boundary marker below is a new row whose write has its own retry, not data left behind.
    @discardableResult
    public func reset() -> Bool {
        // Delete every row (honoring the user's "delete all data" intent — the deletes propagate to their
        // other devices via CloudKit), THEN append a reset-boundary marker. The marker makes reconcile refuse
        // to re-mint earns for pre-reset days and makes the balance void any pre-reset row that lingers or
        // re-syncs from an offline device, so a reset can't be undone by another device deterministically
        // re-minting earns for pre-reset days. This is the append-only economy's "zero the balance".
        let deleted = repository.deleteAll()
        let at = now()
        let marker = CoinLedgerEntry.reset(dayKey: FernletDate.dayKey(for: at), at: at)
        entries = [marker]
        buffer.clear()
        if !repository.append([marker]) {
            buffer.enqueue(marker)
            buffer.scheduleSave()
        }
        return deleted
    }

    /// Writes any pending rows to the store now; a failed append keeps them queued for the next
    /// retry (the full durability contract lives on ``DebouncedAppendBuffer/flush()``).
    public func flushPendingSave() {
        buffer.flush()
    }

    // MARK: - Internals

    /// Adds new rows to the in-memory ledger and the pending-append queue (deduped by id), then schedules
    /// a flush. Rows already present are ignored — the structural guarantee behind idempotent earning.
    private func record(_ newEntries: [CoinLedgerEntry]) {
        var added = false
        for entry in newEntries where !entries.contains(where: { $0.id == entry.id }) {
            entries.append(entry)
            buffer.enqueue(entry)
            added = true
        }
        if added { buffer.scheduleSave() }
    }
}
