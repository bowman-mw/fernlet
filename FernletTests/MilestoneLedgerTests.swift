import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import CloudKitSync
import StoreCore
@testable import Fernlet

/// Batch C: the cumulative-achievements milestone ledger — an append-only, deterministic-id,
/// union-merged store of counted care events (mirroring the coin ledger), whose distinct-row counts
/// are lifetime totals and whose thresholds pay idempotent coin awards (`milestone:<kind>:<n>`).
/// These tests pin the pure aggregation, the exactly-once award math (including its interaction
/// with the coin ledger's reset boundary), the day-history backfill, and the deliberate
/// reset-survival of milestone rows through a real store.
struct MilestoneLedgerTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func event(_ kind: MilestoneEventKind, ref: String, dayKey: String) -> MilestoneLedgerEntry {
        .event(kind: kind, ref: ref, dayKey: dayKey, at: now)
    }

    // MARK: - Deterministic ids + distinct-row counts

    @Test func eventIDsAreDeterministicFromKindAndRef() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        #expect(MilestoneLedgerEntry.eventID(kind: .journal, ref: id.uuidString) == "event:journal:\(id.uuidString)")
        #expect(MilestoneLedgerEntry.eventID(kind: .breathing, ref: "abc") == "event:breathing:abc")
        #expect(MilestoneLedgerEntry.eventID(kind: .water, ref: "2026-05-01") == "event:water:2026-05-01")
        #expect(MilestoneEconomy.awardID(kind: .journal, threshold: 40) == "milestone:journal:40")
    }

    @Test func lifetimeCountsAreDistinctRowCounts() {
        // Two devices independently minted the journal event (same deterministic id): counted once.
        let entries = [
            event(.journal, ref: "j1", dayKey: "2026-05-01"),
            event(.journal, ref: "j1", dayKey: "2026-05-01"),
            event(.journal, ref: "j2", dayKey: "2026-05-02"),
            event(.meal, ref: "m1", dayKey: "2026-05-01"),
        ]
        let counts = MilestoneEconomy.lifetimeCounts(in: entries)
        #expect(counts[.journal] == 2)
        #expect(counts[.meal] == 1)
        #expect(counts[.workout] == 0)
        #expect(MilestoneEconomy.count(of: .journal, in: entries) == 2)
    }

    @Test func unionMergeOfTwoDeviceRowSetsCountsSharedEventsOnce() {
        let deviceA = [
            event(.journal, ref: "shared", dayKey: "2026-05-01"),
            event(.meal, ref: "a-only", dayKey: "2026-05-01"),
        ]
        let deviceB = [
            event(.journal, ref: "shared", dayKey: "2026-05-01"),
            event(.meal, ref: "b-only", dayKey: "2026-05-02"),
        ]
        let counts = MilestoneEconomy.lifetimeCounts(in: deviceA + deviceB)
        #expect(counts[.journal] == 1)
        #expect(counts[.meal] == 2)
    }

    // MARK: - Deriving events from the day history (backfill/reconcile input)

    @Test func derivedEventsCoverJournalMealWorkoutAndWaterWithDeterministicIDs() {
        var day = FernletDay(date: "2026-05-01")
        let journal = JournalEntry(text: "note", tag: .good)
        let meal = Meal(
            name: "toast", mealType: .breakfast, macros: Macros(protein: 5, carbs: 20, fat: 4),
            quality: .good, confidence: "high", note: "", source: "manual"
        )
        let userWorkout = Workout(name: "Walk", type: .cardio, exercises: "walk", rpe: nil, notes: "", duration: 20, intensity: .light)
        var importedWorkout = Workout(name: "Run", type: .cardio, exercises: "run", rpe: nil, notes: "", duration: 20, intensity: .light)
        importedWorkout.healthKitUUID = UUID()
        day.journals = [journal]
        day.meals = [meal]
        day.workouts = [userWorkout, importedWorkout]
        day.bottleCount = 4

        let events = MilestoneEconomy.derivedEvents(from: ["2026-05-01": day], hydrationTarget: 4, at: now)
        let ids = Set(events.map(\.id))
        #expect(ids.contains("event:journal:\(journal.id.uuidString)"))
        #expect(ids.contains("event:meal:\(meal.id.uuidString)"))
        #expect(ids.contains("event:workout:\(userWorkout.id.uuidString)"))
        // HealthKit-imported workouts are passive data — deliberately not counted.
        #expect(!ids.contains("event:workout:\(importedWorkout.id.uuidString)"))
        // Water target met (4 >= 4): one day-grain row.
        #expect(ids.contains("event:water:2026-05-01"))
        #expect(events.count == 4)
        // Re-deriving is idempotent input: same ids every time.
        #expect(MilestoneEconomy.derivedEvents(from: ["2026-05-01": day], hydrationTarget: 4, at: now).map(\.id) == events.map(\.id))
    }

    @Test func derivedEventsSkipWaterBelowTargetAndZeroTarget() {
        var day = FernletDay(date: "2026-05-01")
        day.bottleCount = 3
        #expect(MilestoneEconomy.derivedEvents(from: ["2026-05-01": day], hydrationTarget: 4, at: now).isEmpty)
        day.bottleCount = 10
        #expect(MilestoneEconomy.derivedEvents(from: ["2026-05-01": day], hydrationTarget: 0, at: now).isEmpty)
    }

    // MARK: - Threshold awards (exactly once, deterministic, reset-aware)

    @Test func missingAwardsMintCrossedThresholdsExactlyOnce() {
        let events = (1...5).map { event(.journal, ref: "j\($0)", dayKey: "2026-05-0\($0)") }
        let awards = MilestoneEconomy.missingAwards(events: events, coinEntries: [], at: now)
        #expect(awards.map(\.id) == ["milestone:journal:1", "milestone:journal:5"])
        #expect(awards.allSatisfy { $0.kind == .earn && $0.amount == MilestoneEconomy.coinsPerMilestone })
        // Crossing days: 1st event's day for threshold 1, 5th event's day for threshold 5
        // (deterministic (dayKey, id) order shared by every device).
        #expect(awards.first?.dayKey == "2026-05-01")
        #expect(awards.last?.dayKey == "2026-05-05")

        // Once the awards exist in the coin ledger, re-running mints nothing — exactly once.
        #expect(MilestoneEconomy.missingAwards(events: events, coinEntries: awards, at: now).isEmpty)
    }

    @Test func duplicateEventRowsDoNotInflateAwardProgress() {
        // 1 distinct journal event duplicated across devices: only threshold 1 is crossed.
        let events = [
            event(.journal, ref: "j1", dayKey: "2026-05-01"),
            event(.journal, ref: "j1", dayKey: "2026-05-01"),
        ]
        let awards = MilestoneEconomy.missingAwards(events: events, coinEntries: [], at: now)
        #expect(awards.map(\.id) == ["milestone:journal:1"])
    }

    @Test func preResetCrossingsAreNeverReMintedAndLingeringRowsAreVoided() {
        // 5 journal events, all before the reset boundary day.
        let events = (1...5).map { event(.journal, ref: "j\($0)", dayKey: "2026-05-0\($0)") }
        let reset = CoinLedgerEntry.reset(dayKey: "2026-06-01", at: now)

        // The reconcile refuses to (re-)mint awards whose crossing day predates the boundary.
        #expect(MilestoneEconomy.missingAwards(events: events, coinEntries: [reset], at: now).isEmpty)

        // And a stale pre-reset award row that re-syncs from an offline device is voided by the
        // ledger's existing earn rule (its dayKey — the crossing day — is before the boundary).
        let staleAward = CoinLedgerEntry(
            id: MilestoneEconomy.awardID(kind: .journal, threshold: 5),
            kind: .earn, amount: MilestoneEconomy.coinsPerMilestone,
            dayKey: "2026-05-05", createdAt: now
        )
        #expect(CoinEconomy.balance(in: [reset, staleAward]) == 0)
    }

    @Test func thresholdsCrossedAfterResetStillMintFromSurvivingProgress() {
        // Milestone EVENTS survive a reset, so pre-reset progress counts toward LATER thresholds:
        // 4 events before the boundary, the 5th after — threshold 5's crossing day is post-reset
        // and mints, while threshold 1 (crossed pre-reset) stays voided.
        var events = (1...4).map { event(.journal, ref: "j\($0)", dayKey: "2026-05-0\($0)") }
        events.append(event(.journal, ref: "j5", dayKey: "2026-06-02"))
        let reset = CoinLedgerEntry.reset(dayKey: "2026-06-01", at: now)
        let awards = MilestoneEconomy.missingAwards(events: events, coinEntries: [reset], at: now)
        #expect(awards.map(\.id) == ["milestone:journal:5"])
        #expect(awards.first?.dayKey == "2026-06-02")
    }

    @Test func sameDayCrossingsAreVoidedByAResetLaterTheSameDay() {
        // Regression: a day-one user crosses thresholds TODAY, then taps "Reset everything" the same
        // day. The crossing events survive (dayKey == reset day), so a dayKey-only rule would re-mint
        // their awards seconds later with no user action. The createdAt tiebreak voids them.
        let today = "2026-06-08"
        let events = [
            event(.journal, ref: "j1", dayKey: today),
            event(.meal, ref: "m1", dayKey: today),
            event(.workout, ref: "w1", dayKey: today),
            event(.water, ref: today, dayKey: today),
        ]
        let reset = CoinLedgerEntry.reset(dayKey: today, at: now.addingTimeInterval(60))  // reset AFTER the crossings
        #expect(MilestoneEconomy.missingAwards(events: events, coinEntries: [reset], at: now.addingTimeInterval(120)).isEmpty)

        // A stale same-day award re-synced from another device (dayKey == reset day, so the plain
        // day<boundary rule can't void it) is voided by the milestone createdAt rule in the balance.
        let staleAward = CoinLedgerEntry(
            id: MilestoneEconomy.awardID(kind: .journal, threshold: 1),
            kind: .earn, amount: MilestoneEconomy.coinsPerMilestone,
            dayKey: today, createdAt: now
        )
        #expect(CoinEconomy.balance(in: [reset, staleAward]) == 0)
        #expect(CoinEconomy.milestoneAwardCoins(in: [reset, staleAward]) == 0)
    }

    @Test func thresholdCrossedByPostResetActivityStillMints() {
        // After a same-day reset, genuinely NEW post-reset events crossing a fresh threshold mint
        // normally (createdAt after the reset instant), while the pre-reset survivor stays voided.
        let today = "2026-06-08"
        let reset = CoinLedgerEntry.reset(dayKey: today, at: now)
        var events = [MilestoneLedgerEntry.event(kind: .journal, ref: "old", dayKey: today, at: now.addingTimeInterval(-60))]
        for i in 1...5 { events.append(.event(kind: .journal, ref: "new\(i)", dayKey: today, at: now.addingTimeInterval(60))) }
        // 6 journal events, preResetCount 1 → threshold 1 (pre-reset) stays voided, threshold 5 mints.
        let awards = MilestoneEconomy.missingAwards(events: events, coinEntries: [reset], at: now.addingTimeInterval(120))
        #expect(awards.map(\.id) == ["milestone:journal:5"])
        // The freshly-minted post-reset award (createdAt after the reset) counts toward the wallet.
        #expect(CoinEconomy.milestoneAwardCoins(in: [reset] + awards) == MilestoneEconomy.coinsPerMilestone)
    }

    @Test func pendingAIMealsAreExcludedFromDerivedEventsUntilResolved() {
        // Regression: an AI-fallback placeholder meal is replaced by a fresh-UUID resolved meal on
        // retry; counting both would double-count one logged meal. While pending, it's excluded.
        var day = FernletDay(date: "2026-05-01")
        let placeholder = Meal(
            name: "chicken and rice", mealType: .dinner, macros: Macros(protein: 30, carbs: 40, fat: 10),
            quality: .good, confidence: "low", note: "", source: "fallback"
        )
        day.meals = [placeholder]
        let withPlaceholder = MilestoneEconomy.derivedEvents(
            from: ["2026-05-01": day], hydrationTarget: 8, excludingMealIDs: [placeholder.id], at: now
        )
        #expect(!withPlaceholder.contains { $0.kind == .meal })
        // Once resolved (no longer in the queue), the meal is counted.
        let counted = MilestoneEconomy.derivedEvents(
            from: ["2026-05-01": day], hydrationTarget: 8, excludingMealIDs: [], at: now
        )
        #expect(counted.filter { $0.kind == .meal }.count == 1)
    }

    @Test func milestoneAwardDoesNotBlockTheSameDaysActiveDayEarn() {
        // Regression for the earnedDayKeys narrowing: a milestone award row carries a dayKey (its
        // crossing day), but only true active-day rows ("earn:<dayKey>") may satisfy the active-day
        // reconcile — otherwise a milestone crossed on a day would eat that day's 5 coins.
        let award = CoinLedgerEntry(
            id: MilestoneEconomy.awardID(kind: .journal, threshold: 1),
            kind: .earn, amount: MilestoneEconomy.coinsPerMilestone,
            dayKey: "2026-05-01", createdAt: now
        )
        let minted = CoinEconomy.missingEarnEntries(activeDayKeys: ["2026-05-01"], existing: [award], at: now)
        #expect(minted.map(\.id) == [CoinLedgerEntry.earnID(dayKey: "2026-05-01")])
        // And with the real earn present, nothing further is minted.
        #expect(CoinEconomy.missingEarnEntries(activeDayKeys: ["2026-05-01"], existing: [award] + minted, at: now).isEmpty)
    }

    // MARK: - Service (record idempotency + failed-flush retention)

    @MainActor @Test func serviceRecordDedupesByIdAndPersistsOnce() {
        let repo = StubMilestoneLedgerRepository()
        let service = MilestoneLedgerService(repository: repo)
        let entry = event(.breathing, ref: "b1", dayKey: "2026-05-01")
        service.record([entry])
        service.record([entry])                      // retried hook — no double count
        service.flushPendingSave()
        #expect(service.lifetimeCounts[.breathing] == 1)
        #expect(repo.rows.map(\.id) == [entry.id])   // persisted exactly once
    }

    @MainActor @Test func serviceReloadKeepsPendingRowsWhenFlushFails() {
        let repo = StubMilestoneLedgerRepository()
        let service = MilestoneLedgerService(repository: repo)
        repo.failAppends = true
        service.record([event(.worry, ref: "w1", dayKey: "2026-05-01")])
        service.flushPendingSave()                   // fails — row survives only in pendingAppends
        service.reloadFromStore()                    // must not drop the un-persisted event
        #expect(service.lifetimeCounts[.worry] == 1)
        repo.failAppends = false
        service.flushPendingSave()                   // retry succeeds
        #expect(repo.rows.count == 1)
    }

    // MARK: - Store wiring (backfill, immediacy, reset survival)

    @MainActor @Test func storeBackfillsCountsFromSurvivingDayHistory() {
        let testDate = Date(timeIntervalSince1970: 1_780_000_000)
        let (store, repository, narratives) = makeTestStoreWithRepositories(date: testDate)
        store.addJournal(text: "a day worth keeping", tag: .good)
        store.addMeal(from: "toast with butter", type: .breakfast)
        store.addWorkout(Workout(name: "Walk", type: .cardio, exercises: "walk", rpe: nil, notes: "", duration: 20, intensity: .light))
        store.day.bottleCount = store.settings.hydrationTarget
        store.flushPendingSnapshotSave()

        // A brand-new session over the SAME day history but an EMPTY milestone store (fresh install /
        // ledger introduced after the fact): init reconcile backfills counts from what survives.
        let fresh = makeStoreSharingStores(date: testDate, repository: repository, narratives: narratives)
        #expect(fresh.milestoneCounts[.journal] == 1)
        #expect(fresh.milestoneCounts[.meal] == 1)
        #expect(fresh.milestoneCounts[.workout] == 1)
        #expect(fresh.milestoneCounts[.water] == 1)
        // Threshold 1 of each backfilled kind paid its (idempotent) coin award.
        let coinIDs = Set(fresh.coinLedgerService.entries.map(\.id))
        #expect(coinIDs.contains("milestone:journal:1"))
        #expect(coinIDs.contains("milestone:water:1"))
    }

    @MainActor @Test func liveHookEventsCountOnceAndAwardImmediately() {
        let store = makeTestStore()
        store.recordMilestoneEvent(.breathing, ref: "session-1")
        store.recordMilestoneEvent(.breathing, ref: "session-1")  // retried delivery — idempotent
        #expect(store.milestoneCounts[.breathing] == 1)
        #expect(store.coinLedgerService.entries.filter { $0.id == "milestone:breathing:1" }.count == 1)
        store.recordMilestoneEvent(.worry, ref: "worry-1")
        #expect(store.milestoneCounts[.worry] == 1)
        #expect(store.coinLedgerService.entries.contains { $0.id == "milestone:worry:1" })
    }

    @MainActor @Test func resetAllPreservesMilestoneCountsButZeroesMilestoneCoins() {
        let testDate = Date(timeIntervalSince1970: 1_780_000_000)  // todayKey ≈ 2026-06
        let store = makeTestStore(date: testDate)
        // Care logged on a PAST day (so its milestone crossings predate a reset boundary).
        store.addJournal(text: "an older note", tag: .good, date: "2026-05-01")
        store.reconcileMilestones()
        #expect(store.milestoneCounts[.journal] == 1)
        #expect(store.coinBalance > 0)  // active-day earn + milestone award

        store.resetAll()
        // Milestone EVENTS survive the reset (deliberate: lifetime memories of care)…
        #expect(store.milestoneCounts[.journal] == 1)
        // …but milestone COINS follow coin reset semantics: the wiped ledger + boundary stay zero,
        // and a post-reset reconcile must NOT resurrect the pre-reset award from surviving events.
        store.reconcileCoinLedger()
        #expect(store.coinBalance == 0)
        #expect(!store.coinLedgerService.entries.contains { $0.id == "milestone:journal:1" })
    }
}

/// A non-persisting milestone repo (same shape as `StubCoinLedgerRepository`): appends without
/// deduping — like the real append-only store, which can hold duplicate-id rows synced from
/// multiple devices. `failAppends` simulates a Core Data append error (context rolled back).
private final class StubMilestoneLedgerRepository: MilestoneLedgerRepositoring {
    var rows: [MilestoneLedgerEntry]
    var failAppends = false
    init(rows: [MilestoneLedgerEntry] = []) { self.rows = rows }
    func load() -> [MilestoneLedgerEntry] { rows }
    func loadAsync() async -> [MilestoneLedgerEntry] { rows }
    @discardableResult func append(_ entries: [MilestoneLedgerEntry]) -> Bool {
        if failAppends { return false }
        rows += entries
        return true
    }
}
