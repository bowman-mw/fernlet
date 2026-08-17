import Foundation
import Testing
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import CloudKitSync
import StoreCore
@testable import Fernlet

/// Increment 2 of the custom-clothing feature: the coin economy, modelled as an append-only ledger of
/// `earn`/`spend` rows in a per-row, union-merged synced store. These tests pin the pure aggregation
/// (`CoinEconomy`), the structural idempotency that makes earning sync-safe and monotonic, the day-content
/// predicate, and the end-to-end wiring through a real store (earning survives a shrinking day history;
/// spending debits, refuses when short, and is idempotent per reference).
struct CoinEconomyTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Pure aggregation

    @Test func balanceIsEarnedMinusSpentFlooredAtZero() {
        let entries = [
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),
            CoinLedgerEntry.earn(dayKey: "2026-05-02", amount: 5, at: day),
            CoinLedgerEntry.spend(ref: "hat", amount: 3, at: day),
        ]
        #expect(CoinEconomy.earned(in: entries) == 10)
        #expect(CoinEconomy.spent(in: entries) == 3)
        #expect(CoinEconomy.balance(in: entries) == 7)
        #expect(CoinEconomy.balance(in: []) == 0)
    }

    @Test func balanceNeverGoesNegative() {
        let entries = [
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),
            CoinLedgerEntry.spend(ref: "a", amount: 1000, at: day),
        ]
        #expect(CoinEconomy.balance(in: entries) == 0)
    }

    @Test func canSpendGuardsAmountAndBalance() {
        let entries = [
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),
            CoinLedgerEntry.earn(dayKey: "2026-05-02", amount: 5, at: day),
        ]
        #expect(CoinEconomy.canSpend(amount: 10, in: entries) == true)
        #expect(CoinEconomy.canSpend(amount: 11, in: entries) == false)
        #expect(CoinEconomy.canSpend(amount: 0, in: entries) == false)
        #expect(CoinEconomy.canSpend(amount: -5, in: entries) == false)
    }

    // MARK: - Reset boundary (append-only "zero the balance")

    @Test func resetMarkerVoidsPreResetEarnsAndSpends() {
        let resetDate = Date(timeIntervalSince1970: 1_780_500_000)
        let before = Date(timeIntervalSince1970: 1_780_000_000)  // < resetDate
        let after = Date(timeIntervalSince1970: 1_781_000_000)   // > resetDate
        let entries = [
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: before),
            CoinLedgerEntry.earn(dayKey: "2026-05-05", amount: 5, at: before),
            CoinLedgerEntry.spend(ref: "hat", amount: 3, at: before),
            CoinLedgerEntry.reset(dayKey: "2026-05-10", at: resetDate),
            CoinLedgerEntry.earn(dayKey: "2026-05-11", amount: 5, at: after),  // post-reset day survives
        ]
        // Earns for days STRICTLY BEFORE the reset boundary and the pre-reset spend are voided; only the
        // post-reset earn counts.
        #expect(CoinEconomy.earned(in: entries) == 5)
        #expect(CoinEconomy.spent(in: entries) == 0)
        #expect(CoinEconomy.balance(in: entries) == 5)
    }

    @Test func sameDayAsResetEarnCountsAndPriorDaysStayVoided() {
        // Finding A: a day logged on/after a same-day reset (marker dayKey == that day) must be able to earn.
        // Previously `earn:<resetDay>` was both voided (day <= boundary) AND excluded from re-mint (day not >
        // boundary) — so same-day activity could NEVER earn. A soft reset wipes the reset day's content, so
        // its re-appearance in the ledger represents genuine post-reset activity and legitimately earns.
        let resetDate = Date(timeIntervalSince1970: 1_780_500_000)
        let after = Date(timeIntervalSince1970: 1_781_000_000)
        let entries = [
            CoinLedgerEntry.earn(dayKey: "2026-05-09", amount: 5, at: after),   // strictly before → voided
            CoinLedgerEntry.reset(dayKey: "2026-05-10", at: resetDate),
            CoinLedgerEntry.earn(dayKey: "2026-05-10", amount: 5, at: after),   // the reset day itself → counts
        ]
        #expect(CoinEconomy.earned(in: entries) == 5)   // only the reset-day earn, NOT the strictly-prior one
        #expect(CoinEconomy.balance(in: entries) == 5)
    }

    @Test func reconcileDoesNotReMintEarnsStrictlyBeforeResetButDoesReMintResetDayAndLater() {
        // Another device re-running reconcile after a reset (its days not yet deleted) must NOT re-mint earns
        // for days STRICTLY BEFORE the reset boundary — that is exactly how a reset would otherwise be undone.
        // The reset day itself AND later days DO re-mint (same-day/post-reset activity earns normally).
        let entries = [CoinLedgerEntry.reset(dayKey: "2026-05-10", at: day)]
        let active: Set<String> = ["2026-05-08", "2026-05-10", "2026-05-12"]
        let missing = CoinEconomy.missingEarnEntries(activeDayKeys: active, existing: entries, at: day)
        #expect(missing.map { $0.dayKey } == ["2026-05-10", "2026-05-12"])  // 05-08 (strictly before) stays voided
    }

    @Test func secondDeviceCannotResurrectStrictlyPreResetEarnToUndoReset() {
        // Anti-undo guarantee (Finding A must not regress it): even if a second device re-mints `earn:<preDay>`
        // for a day strictly before the reset (its day history not yet deleted), the reset marker still voids
        // it in the aggregate AND `missingEarnEntries` refuses to hand it back — so the reset holds.
        let resetBoundary = "2026-05-10"
        let existing = [CoinLedgerEntry.reset(dayKey: resetBoundary, at: day)]
        // The second device tries to reconcile a strictly-pre-reset active day.
        let reMinted = CoinEconomy.missingEarnEntries(activeDayKeys: ["2026-05-01"], existing: existing, at: day)
        #expect(reMinted.isEmpty)   // never re-minted
        // And even if such a row somehow lands in the store, the aggregate voids it.
        let withResurrected = existing + [CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day)]
        #expect(CoinEconomy.earned(in: withResurrected) == 0)
        #expect(CoinEconomy.balance(in: withResurrected) == 0)
    }

    @Test func futureActiveDaysAreNeverMinted() {
        // A plan-only day (F3 planned recipes, or planned workouts) can sit on a FUTURE date, and it now
        // counts as an active day via `hasLoggedContent`. Reconcile runs over EVERY stored row on each
        // launch/foreground, so without a future cap a user could page the planner forward, plan a recipe
        // per day, and farm `coinsPerActiveDay` for days that haven't happened (unplanning never revokes —
        // the earn row is append-only and keyed off the day). Days strictly after `at:` must mint nothing;
        // today and past active days still accrue.
        let today = FernletDate.dayKey(for: day)              // 2026-05-28
        let past = "2026-05-20"
        let missing = CoinEconomy.missingEarnEntries(
            activeDayKeys: [past, today, "2026-06-01", "2026-12-25"], existing: [], at: day)
        #expect(missing.map(\.dayKey) == [past, today])       // sorted; both future days dropped
        // And re-running with future days present still hands back nothing new for them.
        #expect(CoinEconomy.missingEarnEntries(
            activeDayKeys: ["2026-06-01", "2026-12-25"], existing: missing, at: day).isEmpty)
    }

    // MARK: - Structural idempotency (the heart of sync-safety)

    @Test func earnIdIsDeterministicFromDayKey() {
        #expect(CoinLedgerEntry.earnID(dayKey: "2026-05-01") == "earn:2026-05-01")
        #expect(CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day).id
                == CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: Date()).id)
    }

    @Test func reconcileDeltaSkipsAlreadyEarnedDays() {
        let existing = [CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day)]
        let delta = CoinEconomy.missingEarnEntries(
            activeDayKeys: ["2026-05-01", "2026-05-02", "2026-05-03"],
            existing: existing, at: day)
        #expect(delta.map(\.dayKey) == ["2026-05-02", "2026-05-03"])  // sorted, 05-01 skipped
        // Re-running with everything already present yields nothing — no double-grant.
        let all = existing + delta
        #expect(CoinEconomy.missingEarnEntries(activeDayKeys: ["2026-05-01", "2026-05-02", "2026-05-03"],
                                               existing: all, at: day).isEmpty)
    }

    @Test func aggregationCollapsesDuplicateIdRows() {
        // The store does NOT collapse duplicate-id rows (CloudKit mirrors by record identity, not the
        // idString attribute), so two devices that each mint earn:2026-05-01 leave TWO physical rows.
        // The aggregation must collapse them by id, or that day double-grants. This is the real
        // "union-merge" — exercised directly, not via a test-only helper.
        let entries = [
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),  // same id, other device
            CoinLedgerEntry.spend(ref: "hat", amount: 5, at: day),
            CoinLedgerEntry.spend(ref: "scarf", amount: 5, at: day),         // distinct ref → sums
        ]
        #expect(CoinEconomy.deduplicatedByID(entries).count == 3)
        #expect(CoinEconomy.earned(in: entries) == 5)   // NOT 10 — the day is credited once
        #expect(CoinEconomy.spent(in: entries) == 10)
        #expect(CoinEconomy.balance(in: entries) == 0)
    }

    @MainActor @Test func serviceDedupesDuplicateSyncedRowsOnLoad() {
        // A raw store (here a stub that, like the real append-only repo, does NOT dedup) hands the
        // service two rows with the same earn id — as CloudKit would after two devices minted the day.
        let repo = StubCoinLedgerRepository(rows: [
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),  // duplicate from other device
            CoinLedgerEntry.spend(ref: "hat", amount: 2, at: day),
        ])
        let service = CoinLedgerService(repository: repo)
        service.loadSync()
        #expect(service.earnedCoins == 5)   // collapsed, not 10
        #expect(service.spentCoins == 2)
        #expect(service.balance == 3)
    }

    @MainActor @Test func reloadFromStoreKeepsPendingRowsWhenFlushFails() async {
        // Finding B: `reloadFromStore()` = flush + loadSync. If the flush's append FAILS, the rows survive
        // only in `pendingAppends` (the append rolled back), and a naive `loadSync()` would REPLACE `entries`
        // with store contents that LACK them — dropping an un-persisted spend/earn from the in-memory ledger
        // and inflating the balance (the user could re-spend the same coins). The fix re-merges pending rows.
        let repo = StubCoinLedgerRepository(rows: [
            CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day),  // 5 already persisted
        ])
        let service = CoinLedgerService(repository: repo)
        service.loadSync()
        #expect(service.balance == 5)

        // Every append fails from here — a locally recorded spend can only live in `pendingAppends`.
        repo.failAppends = true
        #expect(service.spend(amount: 5, ref: "hat") == true)   // guarded by in-memory balance (5 >= 5)
        #expect(service.balance == 0)                            // reflected in memory immediately

        // A remote sync triggers reloadFromStore while the append is still failing. The pending spend must
        // NOT vanish (which would wrongly show balance 5 again and let the user re-spend those coins).
        service.reloadFromStore()
        #expect(service.balance == 0)                            // pending spend re-merged, not dropped
        #expect(service.entries.contains { $0.id == CoinLedgerEntry.spendID(ref: "hat") })

        // The store recovers; the next flush persists the pending spend exactly once (no double-count).
        repo.failAppends = false
        service.reloadFromStore()
        #expect(service.balance == 0)                            // still 0 — spent once, not twice
        #expect(service.spentCoins == 5)
        #expect(repo.rows.filter { $0.id == CoinLedgerEntry.spendID(ref: "hat") }.count == 1)

        // Let any lingering scheduled save drain; the balance stays stable (idempotent).
        await Task.yield()
        #expect(service.balance == 0)
    }

    // MARK: - FernletDay.hasLoggedContent (the active-day predicate)

    @Test func hasLoggedContentReflectsAnyRecordedSignal() {
        #expect(FernletDay(date: "d").hasLoggedContent == false)
        #expect(FernletDay(date: "d", bottleCount: 1).hasLoggedContent == true)
        #expect(FernletDay(date: "d", journals: [JournalEntry(text: "x", tag: .good)]).hasLoggedContent == true)
        #expect(FernletDay(date: "d", sleep: SleepLog(quality: .good, note: "")).hasLoggedContent == true)
        #expect(FernletDay(date: "d", hygiene: [.shower]).hasLoggedContent == true)
        #expect(FernletDay(date: "d",
                           healthContext: HealthDailyContext(
                               activity: HealthActivitySummary(steps: 5_000))).hasLoggedContent == true)
    }

    @Test func contentFreeHealthContextDoesNotCountAsLogged() {
        // HealthKit stamps a bare context (just syncedAt, every metric nil) on any day the app is opened
        // while integration is enabled — that must NOT make the day "active" (no coins for nothing).
        #expect(HealthDailyContext().hasContent == false)
        #expect(HealthDailyContext(activity: HealthActivitySummary()).hasContent == false)
        #expect(HealthDailyContext(activity: HealthActivitySummary(steps: 1)).hasContent == true)
        #expect(FernletDay(date: "d", healthContext: HealthDailyContext()).hasLoggedContent == false)
    }

    // MARK: - End-to-end through a real store

    @MainActor @Test func reconcileCreditsActiveDaysAndSpendDebits() {
        let (store, repo, _) = makeTestStoreWithRepositories()

        // Fresh store: nothing logged, nothing earned.
        #expect(store.coinBalance == 0)
        #expect(store.earnedCoins == 0)

        // Log today + seed two past days, then reconcile → 3 active days × 5 = 15 earned.
        store.day.bottleCount = 3
        for key in ["2026-05-01", "2026-05-02"] {
            repo.updateDay(FernletDay(date: key, bottleCount: 3), for: key, todayKey: store.todayKey)
        }
        store.reconcileCoinLedger()
        #expect(store.earnedCoins == 3 * CoinEconomy.coinsPerActiveDay)
        #expect(store.coinBalance == 15)

        // Reconcile again — idempotent, no double-grant.
        store.reconcileCoinLedger()
        #expect(store.earnedCoins == 15)

        // Spend within balance; idempotent per ref.
        #expect(store.spendCoins(5, ref: "hat-1") == true)
        #expect(store.coinBalance == 10)
        #expect(store.spendCoins(5, ref: "hat-1") == false)   // same ref → no double debit
        #expect(store.coinBalance == 10)

        // Refuse a spend that exceeds the balance and a non-positive spend.
        #expect(store.spendCoins(9_999, ref: "x") == false)
        #expect(store.spendCoins(0, ref: "y") == false)
        #expect(store.coinBalance == 10)
    }

    @MainActor @Test func earnedSurvivesAShrinkingDayHistory() {
        // The core fix: earned coins are recorded as ledger rows, so they do NOT drop when the day
        // history shrinks (HealthKit disabled purges contexts; the 370-day cap prunes old days).
        let (store, repo, _) = makeTestStoreWithRepositories()
        for key in ["2026-05-01", "2026-05-02", "2026-05-03"] {
            repo.updateDay(FernletDay(date: key, bottleCount: 2), for: key, todayKey: store.todayKey)
        }
        store.reconcileCoinLedger()
        #expect(store.earnedCoins == 15)

        // Now blank those days (as the HealthKit cache-cleaner / prune would) and reconcile again.
        for key in ["2026-05-01", "2026-05-02", "2026-05-03"] {
            repo.updateDay(FernletDay(date: key), for: key, todayKey: store.todayKey)  // empty day
        }
        store.reconcileCoinLedger()
        #expect(store.earnedCoins == 15)   // unchanged — ledger rows persist
        #expect(store.coinBalance == 15)
    }

    @MainActor @Test func appendNeverClobbersRowsItWasNotGiven() {
        // The append-only invariant: writing one device's rows must not delete another device's rows
        // already in the store (unlike CustomItemRepository's delete-unlisted save).
        let controller = PersistenceController(inMemory: true)
        let repo = CoinLedgerRepository(controller: controller)
        #expect(repo.append([CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day)]) == true)
        // A different row.
        #expect(repo.append([CoinLedgerEntry.spend(ref: "hat", amount: 2, at: day)]) == true)
        let rows = repo.load()
        #expect(rows.count == 2)                                    // the first row survived
        #expect(CoinEconomy.balance(in: rows) == 3)
    }
}

/// A non-persisting ledger repo that appends without deduping (like the real append-only store, which
/// can hold duplicate-id rows synced from multiple devices) so tests can hand the service raw rows.
/// `failAppends` simulates a Core Data append error (the context rolls back → nothing persisted).
private final class StubCoinLedgerRepository: CoinLedgerRepositoring {
    var rows: [CoinLedgerEntry]
    var failAppends = false
    init(rows: [CoinLedgerEntry] = []) { self.rows = rows }
    func load() -> [CoinLedgerEntry] { rows }
    func loadAsync() async -> [CoinLedgerEntry] { rows }
    @discardableResult func append(_ entries: [CoinLedgerEntry]) -> Bool {
        if failAppends { return false }   // rolled back — nothing persisted
        rows += entries
        return true
    }
    @discardableResult func deleteAll() -> Bool { rows = []; return true }
}
