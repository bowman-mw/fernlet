// LedgerResetBoundaryDurabilityTests.swift
// FernletTests
//
// Tracker §3.6 (2026-09-24): the reset boundary of BOTH append-only ledgers is durable.
//
// The failure it closes: "Delete everything" deletes the coin and milestone rows and appends a
// boundary marker to the synced store; the marker is what keeps rows a second signed-in device still
// holds from counting again when they sync back. When the marker's append FAILED, the marker lived
// only in the service's in-memory queue — and a process death before the retry lost it, so the next
// launch loaded a ledger with no boundary and the re-synced rows came back.
//
// What is pinned here, for each ledger: the marker is in the device-local sidecar BEFORE any row is
// deleted; a failed append plus a process death (a fresh service over the same store) does not
// resurrect anything — neither the balance/counts nor what the reconciles would mint; the marker
// eventually lands and the sidecar is then retired, exactly once; and the real Core Data conformers
// keep the sidecar scoped to their own store (never production defaults in a test).

import Foundation
import Testing
import CloudKitSync
import FernletDomainModel
import FernletPersistence
import StoreCore

/// A clock a test moves by hand (the services read `now` on every stamp). Only ever touched from
/// the test's own main-actor body, which is what the unchecked conformance rests on.
private final class LedgerTestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
}

/// A coin store that behaves like the real one where it matters here: `append` UPSERTS by id (a
/// retried marker never duplicates), the device-local sidecar outlives any one service instance (the
/// "disk" a relaunch reads), and switches fail the append or the sidecar write.
@MainActor
private final class DurableCoinStore: CoinLedgerRepositoring {
    var rows: [CoinLedgerEntry] = []
    var sidecar: [CoinLedgerEntry] = []
    var failAppends = false
    var failSidecarWrites = false
    /// The sidecar as it stood the moment the rows were deleted — the durable-before-delete witness.
    var sidecarAtDelete: [CoinLedgerEntry]?

    func load() -> [CoinLedgerEntry] { rows }
    func loadAsync() async -> [CoinLedgerEntry] { rows }
    func append(_ entries: [CoinLedgerEntry]) -> Bool {
        guard !failAppends else { return false }
        for entry in entries {
            rows.removeAll { $0.id == entry.id }
            rows.append(entry)
        }
        return true
    }
    func deleteAll() -> Bool {
        sidecarAtDelete = sidecar
        rows = []
        return true
    }
    func pendingResetBoundaries() -> [CoinLedgerEntry] { sidecar }
    func savePendingResetBoundaries(_ markers: [CoinLedgerEntry]) -> Bool {
        guard !failSidecarWrites else { return false }
        sidecar = markers
        return true
    }
}

/// The milestone twin of ``DurableCoinStore``; `deleteAllRows()` is the funnel's row delete (the
/// milestone contract carries none).
@MainActor
private final class DurableMilestoneStore: MilestoneLedgerRepositoring {
    var rows: [MilestoneLedgerEntry] = []
    var sidecar: [MilestoneLedgerEntry] = []
    var failAppends = false
    /// The sidecar as it stood the moment the rows were deleted — the durable-before-delete witness.
    var sidecarAtDelete: [MilestoneLedgerEntry]?

    func load() -> [MilestoneLedgerEntry] { rows }
    func loadAsync() async -> [MilestoneLedgerEntry] { rows }
    func append(_ entries: [MilestoneLedgerEntry]) -> Bool {
        guard !failAppends else { return false }
        for entry in entries {
            rows.removeAll { $0.id == entry.id }
            rows.append(entry)
        }
        return true
    }
    func deleteAllRows() -> Bool {
        sidecarAtDelete = sidecar
        rows = []
        return true
    }
    func pendingResetBoundaries() -> [MilestoneLedgerEntry] { sidecar }
    func savePendingResetBoundaries(_ markers: [MilestoneLedgerEntry]) -> Bool {
        sidecar = markers
        return true
    }
}

/// 2026-08-29 (pre-wipe) and 2026-09-21 (the wipe) — far enough apart that every pre-wipe day key is
/// strictly before the wipe day in any time zone.
private let beforeWipe = Date(timeIntervalSince1970: 1_788_000_000)
private let atWipe = Date(timeIntervalSince1970: 1_790_000_000)

// MARK: - Coins

@MainActor
struct CoinResetBoundaryDurabilityTests {

    /// Coins earned on two pre-wipe days — what a second signed-in device still holds after the wipe.
    private let preWipeEarns = [
        CoinLedgerEntry.earn(dayKey: "2026-08-26", amount: CoinEconomy.coinsPerActiveDay, at: beforeWipe),
        CoinLedgerEntry.earn(dayKey: "2026-08-27", amount: CoinEconomy.coinsPerActiveDay, at: beforeWipe)
    ]

    /// A device that earned, then wiped with the marker's append failing. Returns the store and clock.
    private func wipedWithFailedMarker() -> (DurableCoinStore, LedgerTestClock) {
        let store = DurableCoinStore()
        let clock = LedgerTestClock(beforeWipe)
        let device = CoinLedgerService(repository: store, now: { clock.now })
        device.reconcile(activeDayKeys: ["2026-08-26", "2026-08-27"])
        device.flushPendingSave()
        #expect(device.balance == 2 * CoinEconomy.coinsPerActiveDay)

        clock.now = atWipe
        store.failAppends = true
        #expect(device.reset())
        #expect(store.rows.isEmpty, "the rows are deleted and the marker never reached the store")
        return (store, clock)   // `device` dies here: nothing it holds in memory survives
    }

    /// The headline: a failed marker append, a process death, and the other device's pre-wipe rows
    /// syncing back — the relaunched ledger still voids them, and its reconcile mints nothing for a
    /// pre-wipe day that came back either.
    @Test func aFailedMarkerAppendPlusAProcessDeathDoesNotResurrectCoins() {
        let (store, clock) = wipedWithFailedMarker()
        #expect(store.sidecarAtDelete?.map(\.kind) == [.reset], "the marker was durable BEFORE any row was deleted")

        store.rows = preWipeEarns                       // re-synced from the second device
        let relaunched = CoinLedgerService(repository: store, now: { clock.now })
        relaunched.loadSync()
        #expect(relaunched.balance == 0, "pre-wipe coins came back after the process death")

        relaunched.reconcile(activeDayKeys: ["2026-08-25", "2026-08-26"])   // a pre-wipe day re-synced
        #expect(relaunched.balance == 0, "the reconcile re-minted a pre-wipe day")
        #expect(store.sidecar.map(\.kind) == [.reset], "still pending: the append is still failing")
    }

    /// The same through the async launch path.
    @Test func theAsyncLaunchLoadMergesThePendingBoundaryToo() async {
        let (store, clock) = wipedWithFailedMarker()
        store.rows = preWipeEarns
        let relaunched = CoinLedgerService(repository: store, now: { clock.now })
        await relaunched.loadAsync()
        #expect(relaunched.balance == 0)
    }

    /// The synced marker eventually lands — on the first launch that can write — the sidecar is
    /// retired, and from then on the synced marker alone does the voiding. Exactly one marker row.
    @Test func theMarkerEventuallyLandsAndTheSidecarIsRetired() {
        let (store, clock) = wipedWithFailedMarker()
        store.rows = preWipeEarns
        CoinLedgerService(repository: store, now: { clock.now }).loadSync()     // still failing
        #expect(!store.sidecar.isEmpty)

        store.failAppends = false
        let nextLaunch = CoinLedgerService(repository: store, now: { clock.now })
        nextLaunch.loadSync()
        #expect(store.rows.filter { $0.kind == .reset }.count == 1, "the marker landed, once")
        #expect(store.sidecar.isEmpty, "a landed marker retires the sidecar")
        #expect(nextLaunch.balance == 0)

        let afterThat = CoinLedgerService(repository: store, now: { clock.now })
        afterThat.loadSync()
        #expect(afterThat.balance == 0, "the synced marker alone now voids the re-synced rows")
        #expect(store.rows.filter { $0.kind == .reset }.count == 1)
    }

    /// A healthy wipe never leaves the sidecar behind: remembered first, landed, retired in the
    /// same call.
    @Test func aHealthyResetRetiresTheSidecarInTheSameCall() {
        let store = DurableCoinStore()
        let service = CoinLedgerService(repository: store, now: { atWipe })
        #expect(service.reset())
        #expect(store.sidecarAtDelete?.map(\.kind) == [.reset])
        #expect(store.rows.map(\.kind) == [.reset])
        #expect(store.sidecar.isEmpty)
    }

    /// The in-process retry still works alongside the sidecar: the next debounced flush lands the
    /// marker, and the next load retires the sidecar without writing a second marker row.
    @Test func theInProcessRetryLandsTheMarkerAndTheNextLoadRetiresTheSidecar() {
        let store = DurableCoinStore()
        let service = CoinLedgerService(repository: store, now: { atWipe })
        store.failAppends = true
        #expect(service.reset())
        store.failAppends = false
        service.flushPendingSave()
        #expect(store.rows.map(\.kind) == [.reset])
        service.loadSync()
        #expect(store.sidecar.isEmpty)
        #expect(store.rows.map(\.kind) == [.reset])
    }

    /// A sidecar that cannot be written never blocks the wipe, and the marker is still appended.
    @Test func aSidecarWriteFailureNeverBlocksTheWipe() {
        let store = DurableCoinStore()
        store.rows = preWipeEarns
        store.failSidecarWrites = true
        let service = CoinLedgerService(repository: store, now: { atWipe })
        #expect(service.reset())
        #expect(store.rows.map(\.kind) == [.reset], "the rows went and the marker landed anyway")
        #expect(service.balance == 0)
    }
}

// MARK: - Milestones

@MainActor
struct MilestoneResetBoundaryDurabilityTests {

    /// Two counted events from before the wipe — what a second signed-in device still holds.
    private let preWipeEvents = [
        MilestoneLedgerEntry.event(kind: .journal, ref: "j1", dayKey: "2026-08-26", at: beforeWipe),
        MilestoneLedgerEntry.event(kind: .meal, ref: "m1", dayKey: "2026-08-27", at: beforeWipe)
    ]

    private func wipedWithFailedMarker() -> (DurableMilestoneStore, LedgerTestClock) {
        let store = DurableMilestoneStore()
        let clock = LedgerTestClock(beforeWipe)
        let device = MilestoneLedgerService(repository: store, now: { clock.now })
        device.record(preWipeEvents)
        device.flushPendingSave()
        #expect(device.lifetimeCounts[.journal] == 1)

        clock.now = atWipe
        store.failAppends = true
        let deleted = device.reset(deletingRowsWith: { store.deleteAllRows() })
        #expect(deleted)
        #expect(store.rows.isEmpty)
        return (store, clock)
    }

    /// A failed marker append plus a process death: the re-synced events raise no count, award no
    /// coin, and a pre-wipe day that came back re-derives nothing.
    @Test func aFailedMarkerAppendPlusAProcessDeathDoesNotResurrectTheTrail() {
        let (store, clock) = wipedWithFailedMarker()
        #expect(store.sidecarAtDelete?.map(\.kind) == [.resetBoundary], "the marker was durable BEFORE any row was deleted")

        store.rows = preWipeEvents
        let relaunched = MilestoneLedgerService(repository: store, now: { clock.now })
        relaunched.loadSync()
        #expect(relaunched.lifetimeCounts[.journal] == 0, "the dated trail came back after the process death")
        #expect(relaunched.lifetimeCounts[.meal] == 0, "the dated trail came back after the process death")
        #expect(MilestoneEconomy.missingAwards(events: relaunched.entries, coinEntries: [], at: atWipe).isEmpty,
                "a re-synced event re-minted a milestone coin")

        var reSyncedDay = FernletDay(date: "2026-08-25")
        reSyncedDay.journals = [JournalEntry(text: "pre-wipe", tag: .good)]
        let derived = MilestoneEconomy.derivedEvents(
            from: ["2026-08-25": reSyncedDay], hydrationTarget: 0, ledgerEntries: relaunched.entries, at: atWipe)
        #expect(derived.isEmpty, "the reconcile re-derived a row for a day the wipe destroyed")
    }

    /// The marker eventually lands, the sidecar is retired, and the synced marker takes over.
    @Test func theMarkerEventuallyLandsAndTheSidecarIsRetired() {
        let (store, clock) = wipedWithFailedMarker()
        store.rows = preWipeEvents
        store.failAppends = false
        let nextLaunch = MilestoneLedgerService(repository: store, now: { clock.now })
        nextLaunch.loadSync()
        #expect(store.rows.filter { $0.kind == .resetBoundary }.count == 1)
        #expect(store.sidecar.isEmpty)
        #expect(nextLaunch.lifetimeCounts[.journal] == 0)

        let afterThat = MilestoneLedgerService(repository: store, now: { clock.now })
        afterThat.loadSync()
        #expect(afterThat.lifetimeCounts[.journal] == 0)
        #expect(afterThat.lifetimeCounts[.meal] == 0)
    }
}

// MARK: - The real conformers' sidecar

/// The Core Data conformers keep their sidecar on the controller's ``PersistenceController/localDefaults``:
/// shared by two repositories over ONE store (a relaunch), invisible to any other store, and — for
/// an in-memory controller — never `UserDefaults.standard`.
@MainActor
struct LedgerResetBoundarySidecarScopeTests {

    @Test func theCoinSidecarRoundTripsWithinItsStoreAndNowhereElse() {
        let controller = PersistenceController(inMemory: true)
        #expect(controller.localDefaults !== UserDefaults.standard, "a test store must never write production defaults")
        let repository = CoinLedgerRepository(controller: controller)
        #expect(repository.pendingResetBoundaries().isEmpty)

        let marker = CoinLedgerEntry.reset(dayKey: "2026-09-21", at: atWipe)
        #expect(repository.savePendingResetBoundaries([marker]))
        #expect(CoinLedgerRepository(controller: controller).pendingResetBoundaries() == [marker],
                "a relaunch over the same store reads the boundary back")
        #expect(CoinLedgerRepository(controller: PersistenceController(inMemory: true)).pendingResetBoundaries().isEmpty,
                "another store never sees it")
        #expect(repository.savePendingResetBoundaries([]))
        #expect(repository.pendingResetBoundaries().isEmpty)
    }

    @Test func theMilestoneSidecarRoundTripsWithinItsStoreAndNowhereElse() {
        let controller = PersistenceController(inMemory: true)
        let repository = MilestoneLedgerRepository(controller: controller)
        let marker = MilestoneLedgerEntry.resetBoundary(dayKey: "2026-09-21", at: atWipe)
        #expect(repository.savePendingResetBoundaries([marker]))
        #expect(MilestoneLedgerRepository(controller: controller).pendingResetBoundaries() == [marker])
        #expect(MilestoneLedgerRepository(controller: PersistenceController(inMemory: true)).pendingResetBoundaries().isEmpty)
        #expect(repository.savePendingResetBoundaries([]))
        #expect(repository.pendingResetBoundaries().isEmpty)
    }

    /// The whole path over the real Core Data conformer: a reset lands its marker and leaves no
    /// sidecar behind, and a relaunch over the same store sees exactly one boundary.
    @Test func aRealStoreResetLandsTheMarkerAndLeavesNoSidecar() {
        let controller = PersistenceController(inMemory: true)
        let service = CoinLedgerService(repository: CoinLedgerRepository(controller: controller), now: { atWipe })
        #expect(service.reset())
        let relaunchRepository = CoinLedgerRepository(controller: controller)
        #expect(relaunchRepository.pendingResetBoundaries().isEmpty)
        #expect(relaunchRepository.load().filter { $0.kind == .reset }.count == 1)
    }
}
