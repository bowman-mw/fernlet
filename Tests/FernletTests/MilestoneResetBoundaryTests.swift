// MilestoneResetBoundaryTests.swift
// FernletTests
//
// The milestone ledger's reset-boundary marker (2026-08-21) — the half of "delete everything" a row
// delete cannot do on its own.
//
// The gap this closes: the wipe deletes every milestone row locally and, through the CloudKit
// mirror, in the user's private database — but a SECOND signed-in device that was offline at the
// time still holds its own copies, and they sync back into the emptied store afterwards. Without a
// boundary the dated trail ("a journal entry happened on this day, a worry was let go on that one")
// simply reappears, and `MilestoneEconomy.missingAwards` re-mints the coin awards that go with it.
// The fix is the mechanism the coin ledger has always used: the reset appends a `resetBoundary` row,
// and every aggregate voids what falls on the wrong side of it.
//
// THE TRAIL HAS TWO WAYS BACK, so the rule has two halves — a row counts only when its `dayKey` is
// at or after the marker's day AND its `createdAt` is strictly after the marker's instant:
//   • a re-synced ledger ROW (voided by either half), and
//   • a re-synced DAY, from which the reconcile RE-DERIVES rows stamped with its own clock. Those
//     are post-boundary by construction, so only the day half can void them — and the reconcile
//     additionally refuses to mint for days before the boundary at all.
//
// What is pinned here: both resurrection routes, through the store's real wipe and reconcile paths;
// post-boundary events counting and awarding normally from zero; the rule's edges (clock skew, the
// same-instant row, the water same-id undercount, the wipe-day grain shared with coins); the marker
// never being counted, displayed or awarded; and the marker's frozen raw value round-tripping
// through the real per-row store while a genuinely unknown kind is still dropped per row. The
// reset's own end state (exactly the marker, in memory and in the store) is pinned by
// `MilestoneLedgerWipeTests`; the funnel-level version by `DeleteAllDataTests`.

import CoreData
import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletFoundation
import FernletPersistence
import StoreCore
@testable import Fernlet

/// Serialized like `DeleteAllDataTests`, and for the same reason: three cases here drive the REAL
/// `deleteAllData` funnel, and each store is built by `makeTestStore*`, whose per-instance app-group
/// / photo / proximity / heart-drop / defaults-suite seams are what keep a wipe inside its own
/// store. Honest limit (the same one `DeleteAllDataTests` carries): `.serialized` orders this suite's
/// own cases, it does not isolate them from suites running in parallel, and the funnel still reaches
/// a handful of genuinely process-global surfaces with no injection seam.
@MainActor
@Suite(.serialized)
struct MilestoneResetBoundaryTests {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func event(_ kind: MilestoneEventKind, ref: String, dayKey: String, at date: Date) -> MilestoneLedgerEntry {
        .event(kind: kind, ref: ref, dayKey: dayKey, at: date)
    }

    // MARK: - The resurrection the marker exists to stop

    /// The headline property: a milestone row the wipe could not reach — held by another signed-in
    /// device, synced back after the delete — raises no lifetime count and re-mints no coin award,
    /// driven through the store's real reconcile paths rather than the pure math.
    ///
    /// The wipe runs through `deleteAllData`, never `resetAll()` alone: `resetAll` does not purge the
    /// persisted DAY rows (the funnel purges them in a later step), so a store wiped that way still
    /// has the day history the reconcile derives from — an unreachable production state that made an
    /// earlier version of this test red for the wrong reason. `deleteAllData` is the only way a user
    /// reaches either.
    @Test func aPreBoundaryRowSyncedBackAfterTheWipeRaisesNoCountAndReMintsNoAward() async {
        let testDate = Date(timeIntervalSince1970: 1_780_000_000)
        let store = makeTestStore(date: testDate)
        store.addJournal(text: "an older note", tag: .good, date: "2026-05-01")
        store.reconcileMilestones()
        #expect(store.milestoneCounts[.journal] == 1)
        #expect(store.coinLedgerService.entries.contains { $0.id == "milestone:journal:1" })

        _ = await store.deleteAllData(includingHealthKitSamples: false)
        #expect(store.milestoneCounts[.journal] == 0)

        // The other device's row lands in the (already emptied) store — appended straight through the
        // repository, which is exactly how a CloudKit import arrives: the service never sees it until
        // the remote-change reload below. Hoisted out of `#expect`: the macro wraps subexpressions in
        // @Sendable closures, which rejects the non-Sendable repository capture.
        let rows = store.milestoneLedgerService.persistedStore as? MilestoneLedgerRepository
        #expect(rows != nil, "the funnel's `as? MilestoneLedgerRepository` narrowing no longer resolves")
        let resynced = event(.journal, ref: "row-from-the-other-device", dayKey: "2026-05-01", at: testDate.addingTimeInterval(-3_600))
        let appended = rows?.append([resynced])
        #expect(appended == true)

        store.milestoneLedgerService.reloadFromStore()
        let reachedTheLedger = store.milestoneLedgerService.entries.contains { $0.id == resynced.id }
        #expect(reachedTheLedger, "precondition: the re-synced row never reached the in-memory ledger, so this proves nothing")

        // Both reconciles, the way launch/foreground drive them.
        store.reconcileMilestones()
        store.reconcileCoinLedger()
        #expect(store.milestoneCounts[.journal] == 0, "a pre-boundary row that synced back after the wipe restored a lifetime count")
        #expect(!store.coinLedgerService.entries.contains { $0.id == "milestone:journal:1" },
                "a pre-boundary row that synced back after the wipe re-minted its milestone coin award")
        #expect(store.coinBalance == 0)
    }

    /// The other half of the same rule: the boundary must not freeze the ledger. Genuinely new care
    /// after the wipe counts from zero and pays its threshold-1 award, with a post-boundary
    /// `createdAt` that survives both the milestone filter and the coin ledger's own void.
    @Test func postBoundaryEventsCountAndAwardFromZero() async {
        // Deliberately NOT a fixed `date:` — the ledger services stamp their rows and markers with
        // the wall clock, so a store whose todayKey is months away from it would make the day-grain
        // half of both reset rules read a genuinely post-wipe event as pre-reset. Every assertion
        // here is about the day the wipe happened, which is the day this store is on.
        let store = makeTestStore()
        store.addJournal(text: "an older note", tag: .good, date: "2026-05-01")
        store.reconcileMilestones()
        _ = await store.deleteAllData(includingHealthKitSamples: false)

        store.recordMilestoneEvent(.breathing, ref: "session-after-the-wipe")
        #expect(store.milestoneCounts[.breathing] == 1)
        #expect(store.coinLedgerService.entries.contains { $0.id == "milestone:breathing:1" })
        #expect(CoinEconomy.milestoneAwardCoins(in: store.coinLedgerService.entries) == MilestoneEconomy.coinsPerMilestone)
        // The wiped kind stays at zero — the boundary voided its rows, it did not merely pause them.
        #expect(store.milestoneCounts[.journal] == 0)
    }

    /// The second resurrection route, and the reason the boundary needs a DAY as well as an instant:
    /// the trail can come back through a re-synced DAY rather than a re-synced ledger row. Day
    /// records keep no tombstones (the delete dialog discloses exactly that), and rows re-derived
    /// from a day are stamped with the reconcile's own clock — post-boundary by construction, so an
    /// instant-only rule could not void them and `missingAwards` re-minted the award too.
    @Test func aPreWipeDayReAddedAfterTheWipeReDerivesNothingAndReMintsNoAward() async {
        let testDate = Date(timeIntervalSince1970: 1_780_000_000)
        let (store, repository, _) = makeTestStoreWithRepositories(date: testDate)
        store.addJournal(text: "an older note", tag: .good, date: "2026-05-01")
        store.reconcileMilestones()
        #expect(store.milestoneCounts[.journal] == 1)

        _ = await store.deleteAllData(includingHealthKitSamples: false)
        #expect(store.milestoneCounts[.journal] == 0)

        // The other device re-uploads its copy of a pre-wipe day, written straight through the day
        // repository the way a CloudKit import lands.
        var day = FernletDay(date: "2026-05-01")
        day.journals = [JournalEntry(text: "an older note", tag: .good)]
        let sanitized = SanitizedDay.sanitizing(day, sealedJournalIDs: [])
        let wrote = repository.updateDay(sanitized, for: "2026-05-01", todayKey: store.todayKey)
        #expect(wrote, "precondition: the re-added day was not written")
        let dayCameBack = store.loadDays()["2026-05-01"]?.journals.isEmpty == false
        #expect(dayCameBack, "precondition: the re-added day never reached the store, so this proves nothing")

        store.reconcileMilestones()
        store.reconcileCoinLedger()
        #expect(store.milestoneCounts[.journal] == 0,
                "the dated trail came back through a re-synced DAY — the reconcile re-derived a milestone row for a pre-wipe day")
        #expect(!store.coinLedgerService.entries.contains { $0.id == "milestone:journal:1" },
                "a row re-derived from a re-synced pre-wipe day re-minted its milestone coin award")
        // And nothing junk was written either: the mint side skips pre-boundary days outright, so
        // the ledger still holds only its marker.
        #expect(store.milestoneLedgerService.entries.map(\.kind) == [.resetBoundary])
    }

    // MARK: - The marker itself: bookkeeping, never a milestone

    /// Never counted, never awarded — and not even present as a zero in the counts dictionary, which
    /// is what keeps it off every surface that iterates the keys it is handed.
    @Test func theMarkerIsNeverCountedAndNeverAwarded() {
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: "2026-06-08", at: now)
        let entries = [marker, event(.journal, ref: "j1", dayKey: "2026-06-08", at: now.addingTimeInterval(60))]

        #expect(MilestoneEconomy.count(of: .resetBoundary, in: entries) == 0)
        let counts = MilestoneEconomy.lifetimeCounts(in: entries)
        #expect(counts[.resetBoundary] == nil, "the marker kind appeared in the counts dictionary — every allCases consumer would draw it")
        #expect(counts[.journal] == 1)
        #expect(!MilestoneEconomy.countedKinds.contains(.resetBoundary))
        #expect(MilestoneEconomy.countedKinds.count == MilestoneEventKind.allCases.count - 1)
        #expect(MilestoneEconomy.missingAwards(events: [marker], coinEntries: [], at: now).isEmpty,
                "the reset-boundary marker minted a coin award — the wipe would pay the user for wiping")
    }

    /// Never displayed. Fed a count directly — the state that can only be reached by a bug — the row
    /// model still builds no row for the marker, so no keepsake, headline or shelf medallion exists
    /// for "you deleted everything". A value-level pin over the row model's own input, which is the
    /// single table both the Milestones screen and Home's card render from.
    @Test func theMarkerCanNeverProduceAMilestoneRow() {
        let rows = MilestoneRowModel.rows(counts: [.resetBoundary: 5, .journal: 1], worriesLetGo: 0)
        #expect(!rows.contains { $0.kind == .resetBoundary })
        #expect(rows.count == MilestoneEconomy.countedKinds.count)
        #expect(rows.contains { $0.kind == .journal })
    }

    /// Home's keepsake shelf is the one display path that iterates the enum rather than a fixed
    /// list, so it is pinned by shape: it must read the ledger's counted kinds, never `allCases`.
    /// A behavioral test cannot reach it (the card and its helper are private to `HomeView`).
    @Test func theKeepsakeShelfIteratesTheCountedKindsNotEveryCase() throws {
        let source = try String(
            contentsOf: RepoRoot.url.appendingPathComponent("App/Fernlet/HomeView.swift"),
            encoding: .utf8
        )
        let body = try PrivacyWipeCoverageTests.functionBody(matching: "private func keptKeepsakes(counts:", in: source)
        #expect(body.contains("MilestoneEconomy.countedKinds"),
                "Home's keepsake shelf no longer iterates the ledger's counted kinds")
        #expect(!body.contains("MilestoneEventKind.allCases"),
                "Home's keepsake shelf is back on `allCases`, which now includes the reset-boundary marker — a wipe would put a keepsake on the shelf.")
    }

    // MARK: - The rule itself: day AND instant, row by row

    /// The fixture for the re-derivation defect: rows shaped exactly as a reconcile over re-synced
    /// days produces them — pre-wipe `dayKey`s, all stamped with the reconcile's own (post-marker)
    /// clock. The day half voids them; the instant half never could. The one row for the wipe DAY
    /// survives, which is the accepted grain `countedEvents` documents (coins' `earn:<resetDay>`).
    @Test func reDerivedRowsAreVoidedByDayEvenThoughTheirTimestampsArePostBoundary() {
        let wipeDay = "2026-06-08"
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: wipeDay, at: now)
        let reDerivedAt = now.addingTimeInterval(300)   // the reconcile ran five minutes after the wipe
        var rows = (1...5).map { event(.journal, ref: "old\($0)", dayKey: "2026-05-0\($0)", at: reDerivedAt) }
        rows.append(event(.journal, ref: "wipe-day", dayKey: wipeDay, at: reDerivedAt))
        let entries = [marker] + rows

        let counted = MilestoneEconomy.countedEvents(in: entries)
        #expect(counted.map(\.dayKey) == [wipeDay], "a row re-derived for a pre-wipe day is still being counted")
        #expect(MilestoneEconomy.count(of: .journal, in: entries) == 1)
        // The thresholds those five voided rows would have carried mint nothing: only threshold 1,
        // from the single row that legitimately counts.
        let awards = MilestoneEconomy.missingAwards(events: entries, coinEntries: [], at: reDerivedAt)
        #expect(awards.map(\.id) == ["milestone:journal:1"],
                "voided rows carried a threshold into the mint — the award side is reading un-filtered rows")
    }

    /// Cross-device clock skew, closed by the same day half: a row minted BEFORE the wipe on a device
    /// whose clock runs fast carries a `createdAt` after the marker's instant. Its day is what says
    /// which side of the wipe it belongs to.
    @Test func aPreWipeRowFromAFastClockIsVoidedByItsDay() {
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: "2026-06-08", at: now)
        let skewed = event(.journal, ref: "from-a-fast-clock", dayKey: "2026-06-07", at: now.addingTimeInterval(3_600))
        #expect(MilestoneEconomy.countedEvents(in: [marker, skewed]).isEmpty)
        #expect(MilestoneEconomy.missingAwards(events: [marker, skewed], coinEntries: [], at: now).isEmpty)
    }

    /// The instant half is STRICTLY after, not at-or-after: a row sharing the marker's instant is
    /// voided (it belongs to the history the wipe was destroying at that moment), and the very next
    /// instant counts.
    @Test func aRowCreatedInTheSameInstantAsTheMarkerIsVoided() {
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: "2026-06-08", at: now)
        let sameInstant = event(.journal, ref: "j1", dayKey: "2026-06-08", at: now)
        #expect(MilestoneEconomy.countedEvents(in: [marker, sameInstant]).isEmpty,
                "a row created at the marker's own instant counted — the boundary is not strictly-after")
        let justAfter = event(.journal, ref: "j2", dayKey: "2026-06-08", at: now.addingTimeInterval(0.001))
        #expect(MilestoneEconomy.count(of: .journal, in: [marker, justAfter]) == 1)
    }

    /// The documented water undercount, pinned so it stays a known cost rather than a surprise:
    /// dedup runs BEFORE the boundary filter, so when the same deterministic id exists on both sides
    /// of the boundary the older row wins and the pair is voided. Only `event:water:<dayKey>` can
    /// reach this — every other kind's id is content-derived, and wiped content never comes back
    /// under its old id. The array order models the store's load order (oldest first).
    @Test func aWaterDayHeldOnBothSidesOfTheBoundaryIsVoidedByItsOlderCopy() {
        let wipeDay = "2026-06-08"
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: wipeDay, at: now)
        let older = event(.water, ref: wipeDay, dayKey: wipeDay, at: now.addingTimeInterval(-600))
        let newer = event(.water, ref: wipeDay, dayKey: wipeDay, at: now.addingTimeInterval(600))
        #expect(older.id == newer.id, "precondition: the water id stopped being day-deterministic")
        #expect(MilestoneEconomy.countedEvents(in: [marker, older, newer]).isEmpty)
        // The safe direction: an undercount of one water day, never a resurrected row.
        #expect(MilestoneEconomy.count(of: .water, in: [marker, newer]) == 1)
    }

    /// The mint side of the same rule: the reconcile never even WRITES rows for days before the
    /// boundary, so the ledger cannot accumulate rows the aggregation would only void. The wipe day
    /// itself stays derivable (the accepted grain), and `ledgerEntries` is non-defaulted so a caller
    /// cannot silently opt out of the filter.
    @Test func derivedEventsSkipDaysBeforeTheBoundaryAndKeepTheWipeDay() {
        let wipeDay = "2026-06-08"
        var before = FernletDay(date: "2026-05-01")
        before.journals = [JournalEntry(text: "pre-wipe", tag: .good)]
        var onTheDay = FernletDay(date: wipeDay)
        onTheDay.journals = [JournalEntry(text: "wipe day", tag: .good)]
        let days = ["2026-05-01": before, wipeDay: onTheDay]
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: wipeDay, at: now)

        let derived = MilestoneEconomy.derivedEvents(
            from: days, hydrationTarget: 0, ledgerEntries: [marker], at: now.addingTimeInterval(300)
        )
        #expect(derived.map(\.dayKey) == [wipeDay], "the reconcile re-derived rows for a day the wipe destroyed")
        // Without a boundary in the ledger, both days derive — the filter is the marker's doing, not
        // a new blanket restriction.
        let unfiltered = MilestoneEconomy.derivedEvents(from: days, hydrationTarget: 0, ledgerEntries: [], at: now)
        #expect(unfiltered.count == 2)
    }

    // MARK: - The wire: the marker persists, unknown kinds still don't

    /// The marker has to survive the round trip through the real per-row store, or the boundary
    /// vanishes on the next load and the wipe becomes undoable again. Pinned alongside the property
    /// it depends on — the per-row `try?` that drops a row only a NEWER build understands (the
    /// forward-compat contract `MilestoneEventKind` documents, and the reason an old build degrades
    /// safely: it drops the marker row rather than failing the whole load).
    @Test func theMarkerRowRoundTripsWhileAnUnknownKindIsStillDroppedPerRow() throws {
        let controller = PersistenceController(inMemory: true)
        let repository = MilestoneLedgerRepository(controller: controller)
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: "2026-06-08", at: now)
        let appended = repository.append([marker, event(.journal, ref: "j1", dayKey: "2026-06-09", at: now)])
        #expect(appended)

        // A row from a build that knows a kind this one doesn't, planted exactly as the store writes
        // one (same JSON coder, same three attributes).
        let encoder = RowPayloadCoders.makeEncoder()
        let known = try encoder.encode(event(.journal, ref: "future", dayKey: "2026-06-09", at: now))
        // Only `"kind":"journal"` matches the quoted needle — the id spells the kind between colons.
        let unknownJSON = Data(
            String(decoding: known, as: UTF8.self)
                .replacingOccurrences(of: "\"journal\"", with: "\"stargazing\"")
                .utf8
        )
        let context = controller.container.viewContext
        let record = NSEntityDescription.insertNewObject(forEntityName: "MilestoneLedgerRecord", into: context)
        record.setValue("event:stargazing:future", forKey: "idString")
        record.setValue(unknownJSON, forKey: "payloadData")
        record.setValue(now, forKey: "createdAt")
        try context.save()

        let loaded = repository.load()
        #expect(loaded.contains { $0.id == marker.id && $0.kind == .resetBoundary },
                "the reset-boundary marker no longer round-trips through the store — the wipe's boundary would be lost on the next load")
        #expect(loaded.count == 2, "the unknown-kind row was not dropped per row: \(loaded.map(\.id))")

        // The value-level property the store's per-row `try?` rests on, both directions.
        let markerJSON = try encoder.encode(marker)
        #expect(String(decoding: markerJSON, as: UTF8.self).contains("\"resetBoundary\""),
                "the marker's frozen raw value changed — persisted rows and their ids would stop matching")
        let decoded = try RowPayloadCoders.makeDecoder().decode(MilestoneLedgerEntry.self, from: markerJSON)
        #expect(decoded == marker)
        #expect(throws: (any Error).self) {
            try RowPayloadCoders.makeDecoder().decode(MilestoneLedgerEntry.self, from: unknownJSON)
        }
    }

    /// The marker id can never collide with an event id, whatever a caller passes as `ref` — the two
    /// live in disjoint prefixes (`reset:` vs `event:`), and two distinct resets stay two rows under
    /// the union-merge because the instant is in the id.
    @Test func markerIDsAreDistinctFromEventIDsAndFromEachOther() {
        let first = MilestoneLedgerEntry.resetBoundaryID(at: now)
        let second = MilestoneLedgerEntry.resetBoundaryID(at: now.addingTimeInterval(1))
        #expect(first != second)
        #expect(first.hasPrefix("reset:"))
        for kind in MilestoneEventKind.allCases {
            #expect(MilestoneLedgerEntry.eventID(kind: kind, ref: first).hasPrefix("event:"))
            #expect(MilestoneLedgerEntry.eventID(kind: kind, ref: first) != first)
        }
    }

    // MARK: - The service seam

    /// The marker is minted by the reset alone: `record` refuses a boundary row, mirroring
    /// `CoinLedgerService.grantEarns`'s refusal of non-earn rows. Without this, any caller of the
    /// public recording seam (`FernletStore.recordMilestoneEvent` takes its kind from ITS caller)
    /// could void every lifetime count on the device with an ordinary logging call.
    @Test func recordRefusesABoundaryRowSoOnlyTheResetCanMintOne() {
        let repository = StubMilestoneRepository()
        let stamp = now
        let service = MilestoneLedgerService(repository: repository, now: { stamp })
        service.record([
            event(.journal, ref: "j1", dayKey: "2026-06-09", at: now),
            MilestoneLedgerEntry.resetBoundary(dayKey: "2026-06-09", at: now.addingTimeInterval(60))
        ])
        service.flushPendingSave()
        #expect(service.entries.map(\.kind) == [.journal])
        #expect(repository.rows.map(\.kind) == [.journal])
        // And the count survives: a smuggled boundary would have voided the journal row minted with it.
        #expect(service.lifetimeCounts[.journal] == 1)
    }

    /// The marker's timestamp comes from the injected clock, and a failed append keeps it queued for
    /// the debounced retry rather than dropping it — a boundary that never persists is a wipe another
    /// device can undo.
    @Test func aFailedMarkerAppendIsRetriedNotDropped() {
        let repository = StubMilestoneRepository()
        let stamp = now
        let service = MilestoneLedgerService(repository: repository, now: { stamp })
        service.record([event(.journal, ref: "j1", dayKey: "2026-06-09", at: now)])
        service.flushPendingSave()

        repository.failAppends = true
        let didDelete = service.reset(deletingRowsWith: {
            repository.rows = []
            return true
        })
        #expect(didDelete)
        #expect(service.entries.map(\.id) == [MilestoneLedgerEntry.resetBoundaryID(at: now)])
        #expect(repository.rows.isEmpty, "precondition: the failing append somehow wrote the marker")

        repository.failAppends = false
        service.flushPendingSave()
        #expect(repository.rows.map(\.kind) == [.resetBoundary], "the marker was dropped after a failed append instead of being retried")
    }
}

/// A non-persisting milestone repo for the service-seam cases (same shape as the stub in
/// `MilestoneLedgerTests`, kept private to this file so neither suite can perturb the other):
/// appends without deduping, like the real append-only store, and `failAppends` simulates a Core
/// Data append error with the context rolled back.
private final class StubMilestoneRepository: MilestoneLedgerRepositoring {
    var rows: [MilestoneLedgerEntry] = []
    var failAppends = false
    func load() -> [MilestoneLedgerEntry] { rows }
    func loadAsync() async -> [MilestoneLedgerEntry] { rows }
    @discardableResult func append(_ entries: [MilestoneLedgerEntry]) -> Bool {
        if failAppends { return false }
        rows += entries
        return true
    }
}
