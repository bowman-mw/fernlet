import Foundation
import Observation
import FernletPersistence
import FernletDomainModel
import FernletFoundation

/// Owns the milestone (cumulative achievements) ledger in memory and persists it to its own
/// per-row store — a direct mirror of ``CoinLedgerService``'s debounced append-only shape, down to
/// the reset: ``reset(deletingRowsWith:)`` empties the ledger on "delete everything", because the
/// rows are a dated record that journal entries and Worry Box releases HAPPENED, kept in Core Data
/// and mirrored into the user's CloudKit private database — metadata about the very content the
/// wipe destroys. Lifetime counts are distinct-row counts over the union-merged rows
/// (`MilestoneEconomy`), so between resets they are monotonic and sync-safe across devices.
///
/// The reset does BOTH halves as of 2026-08-21: it deletes the rows (which the coin ledger does not)
/// **and** appends a `resetBoundary` marker (which it previously did not). The delete is what honors
/// "delete everything" — the trail is metadata about destroyed content and has to go, on this device
/// and, through the mirror, in iCloud. The marker is what makes the delete stick: rows a second
/// signed-in device was holding offline sync back into the emptied store afterwards, and
/// `MilestoneEconomy` counts only rows on the far side of the latest boundary (day at or after the
/// marker's day AND created strictly after its instant), so they raise no count and re-mint no coin
/// award. In-memory state after a reset is therefore `[marker]`, never `[]`.
///
/// **Known durability ceiling, shared verbatim with ``CoinLedgerService`` and written down in
/// Docs/PrivacyWipeCoverage.md.** If the marker's own append fails, the marker survives only in the
/// pending queue — process memory. ``loadSync()`` does not re-merge pending rows (only
/// ``reloadFromStore()`` does, within the same process), so a process death before a successful
/// flush loses the boundary silently. The delete itself already happened, so nothing on THIS device
/// returns; the exposure is that rows re-synced from another device would no longer be voided. The
/// reset's returned verdict deliberately covers the row DELETE only — widening it would report an
/// incomplete wipe when the user's data really is gone. Deliberately not fixed here: any fix belongs
/// to both ledgers at once.
///
/// Collaborators: the injected `MilestoneLedgerRepositoring` store (concretely CloudKitSync's
/// `MilestoneLedgerRepository`, behind the FernletPersistence protocol) and `FernletStore`, which
/// records events from both the live logging hooks and the day-history reconcile — deterministic
/// event ids make those overlapping inputs safe. Same durability invariant as the coin ledger:
/// pending rows are the sole un-persisted copy, cleared only after a confirmed append, with
/// ``reloadFromStore()`` re-merging them after a failed flush. `@MainActor` and `@Observable`; the
/// injected `now` clock keeps the marker's timestamp testable.
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
    /// The clock the reset-boundary marker is stamped with — injected exactly like
    /// ``CoinLedgerService``'s, so a test can place the boundary relative to its own rows.
    @ObservationIgnored private let now: () -> Date

    /// Creates the service over its per-row store; `initialEntries` seeds the ledger before the first load.
    public init(
        repository: any MilestoneLedgerRepositoring,
        initialEntries: [MilestoneLedgerEntry] = [],
        now: @escaping () -> Date = Date.init
    ) {
        self.repository = repository
        self.buffer = DebouncedAppendBuffer(append: { repository.append($0) })
        self.entries = initialEntries
        self.now = now
    }

    /// The store this service persists through, exposed read-only for exactly one caller: the app's
    /// single deletion funnel, which narrows it to the concrete CloudKit conformer to reach
    /// `deleteAll()` and hands that call to ``reset(deletingRowsWith:)``. The row delete is not on
    /// `MilestoneLedgerRepositoring`, and this module has no dependency edge to CloudKitSync, so the
    /// narrowing can only happen app-side (the same `as?` the app already uses to reach
    /// `CoreDataFernletRepository`'s async loader). Nothing else should write through it — every
    /// mutation belongs to this service, which owns the pending-append queue.
    public var persistedStore: any MilestoneLedgerRepositoring { repository }

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
    ///
    /// `resetBoundary` rows are REFUSED here, mirroring `CoinLedgerService.grantEarns`'s refusal of
    /// non-earn rows: the marker is minted by ``reset(deletingRowsWith:)`` alone, and a caller that
    /// could record one (this method is public, and `FernletStore.recordMilestoneEvent` takes a kind
    /// from its caller) could void every count on the device with an ordinary logging call.
    public func record(_ newEntries: [MilestoneLedgerEntry]) {
        let events = newEntries.filter { $0.kind != .resetBoundary }
        guard !events.isEmpty else { return }
        var existingIDs = Set(entries.map(\.id))
        var added = false
        for entry in events where existingIDs.insert(entry.id).inserted {
            entries.append(entry)
            buffer.enqueue(entry)
            added = true
        }
        if added { buffer.scheduleSave() }
    }

    // MARK: - Reset

    /// Empties the ledger for "delete everything": the in-memory rows, the pending-append queue and
    /// the persisted rows `deleteRows` removes — then appends the reset-boundary marker that keeps
    /// them from coming back.
    ///
    /// The deleter is passed in rather than taken from ``persistedStore`` because the row delete
    /// lives on the concrete CloudKit conformer and this module cannot name it; the funnel narrows
    /// the store and supplies the call. A `deleteRows` that cannot reach the rows must return
    /// `false` — a wipe that could not delete them has to say so.
    ///
    /// Ordering is why this is one method and not three calls, and every step of it is load-bearing:
    /// the pending queue is dropped BEFORE the stored rows (a queued row flushed back onto a
    /// just-emptied store is a resurrection), and the marker is appended AFTER the delete (a marker
    /// written first would be deleted by the very sweep it exists to survive). The marker is written
    /// through the repository directly, exactly like `CoinLedgerService.reset()`, and a failed append
    /// is re-queued for the debounced retry rather than dropped — a wipe whose boundary never
    /// persists is a wipe another device can undo.
    ///
    /// The in-memory ledger afterwards is `[marker]`, not `[]`; `MilestoneEconomy` never counts,
    /// awards or displays a marker row, so every lifetime count still reads 0.
    ///
    /// - Returns: whether the persisted rows were confirmed deleted. Threaded back (R7, exactly like
    ///   ``CoinLedgerService/reset()``) so the funnel can report a milestone trail it failed to
    ///   remove instead of claiming a complete wipe. It reflects only the row DELETE — the marker
    ///   append below is a new row whose write has its own retry, not data left behind. The
    ///   in-memory ledger is zeroed either way — a failed delete leaves rows on disk, not counts on
    ///   screen.
    public func reset(deletingRowsWith deleteRows: @MainActor () -> Bool) -> Bool {
        buffer.clear()
        let deleted = deleteRows()
        let at = now()
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: FernletDate.dayKey(for: at), at: at)
        entries = [marker]
        if !repository.append([marker]) {
            buffer.enqueue(marker)
            buffer.scheduleSave()
        }
        return deleted
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
