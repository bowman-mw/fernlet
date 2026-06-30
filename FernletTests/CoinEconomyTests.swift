import Foundation
import Testing
import FernletDomainModel
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
        repo.append([CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day)])
        repo.append([CoinLedgerEntry.spend(ref: "hat", amount: 2, at: day)])  // a different row
        let rows = repo.load()
        #expect(rows.count == 2)                                    // the first row survived
        #expect(CoinEconomy.balance(in: rows) == 3)
    }
}

/// A non-persisting ledger repo that appends without deduping (like the real append-only store, which
/// can hold duplicate-id rows synced from multiple devices) so tests can hand the service raw rows.
private final class StubCoinLedgerRepository: CoinLedgerRepositoring {
    var rows: [CoinLedgerEntry]
    init(rows: [CoinLedgerEntry] = []) { self.rows = rows }
    func load() -> [CoinLedgerEntry] { rows }
    func loadAsync() async -> [CoinLedgerEntry] { rows }
    @discardableResult func append(_ entries: [CoinLedgerEntry]) -> Bool { rows += entries; return true }
    @discardableResult func deleteAll() -> Bool { rows = []; return true }
}
