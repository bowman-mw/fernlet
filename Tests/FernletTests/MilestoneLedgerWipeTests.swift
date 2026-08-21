// MilestoneLedgerWipeTests.swift
// FernletTests
//
// The milestone ledger's delete path. The rows are a dated metadata trail of the content "delete
// everything" destroys — a journal entry happened on this day, a worry was let go on that one —
// living in Core Data and, mirrored, in the user's CloudKit private database, so the wipe has to
// take them with the content. Until this round the store had no delete at all.
//
// Three things are pinned here: the local rows really go (through a second repository instance, so
// no in-memory cache can fake it), the service's reset drops the pending-append queue as well as the
// stored rows (a queued row flushed back onto a just-emptied store is a resurrection), and the
// delete stays object-by-object through the view context — the shape that makes it reach CloudKit.

import Foundation
import Testing
import FernletDomainModel
import FernletPersistence
import CloudKitSync
import StoreCore

/// Coverage for `MilestoneLedgerRepository.deleteAll()` and
/// `MilestoneLedgerService.reset(deletingRowsWith:)` — the two halves of taking the milestone trail
/// out with the data it describes.
///
/// Every persistence case builds its own `PersistenceController(inMemory: true)`, so the suite holds
/// no process-global disk state and stays safe under the parallel test runner.
@Suite
struct MilestoneLedgerWipeTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    private func event(_ kind: MilestoneEventKind, ref: String, dayKey: String) -> MilestoneLedgerEntry {
        MilestoneLedgerEntry.event(kind: kind, ref: ref, dayKey: dayKey, at: day)
    }

    // MARK: - The local rows

    @MainActor @Test func deleteAllEmptiesThePersistedLedger() {
        let controller = PersistenceController(inMemory: true)
        let repository = MilestoneLedgerRepository(controller: controller)
        #expect(repository.append([
            event(.journal, ref: "j1", dayKey: "2026-05-01"),
            event(.worry, ref: "w1", dayKey: "2026-05-02"),
            event(.meal, ref: "m1", dayKey: "2026-05-03")
        ]))
        #expect(repository.load().count == 3)

        #expect(repository.deleteAll())
        #expect(repository.load().isEmpty)
        // A second repository over the same controller: the rows are gone from the STORE, not from
        // one instance's view of it.
        #expect(MilestoneLedgerRepository(controller: controller).load().isEmpty)
    }

    @MainActor @Test func deleteAllOnAnEmptyLedgerStillSucceeds() {
        let repository = MilestoneLedgerRepository(controller: PersistenceController(inMemory: true))
        // A second wipe (or a wipe on a device that never earned a milestone) must not report an
        // incomplete store — the funnel would name a trail that does not exist.
        #expect(repository.deleteAll())
        #expect(repository.deleteAll())
        #expect(repository.load().isEmpty)
    }

    @MainActor @Test func deleteAllTouchesNoSiblingRowStore() {
        // The delete is bounded to `MilestoneLedgerRecord`. The coin ledger shares the container and
        // the same AppendOnlyRowStore engine, so a wrong entity name here would be invisible in every
        // other assertion in this file.
        let controller = PersistenceController(inMemory: true)
        let milestones = MilestoneLedgerRepository(controller: controller)
        let coins = CoinLedgerRepository(controller: controller)
        #expect(milestones.append([event(.journal, ref: "j1", dayKey: "2026-05-01")]))
        #expect(coins.append([CoinLedgerEntry.earn(dayKey: "2026-05-01", amount: 5, at: day)]))

        #expect(milestones.deleteAll())
        #expect(milestones.load().isEmpty)
        #expect(coins.load().count == 1)
    }

    // MARK: - The service's reset

    @MainActor @Test func resetEmptiesTheLedgerAndDropsRowsStillQueued() {
        let controller = PersistenceController(inMemory: true)
        let repository = MilestoneLedgerRepository(controller: controller)
        let service = MilestoneLedgerService(repository: repository)
        service.record([event(.journal, ref: "j1", dayKey: "2026-05-01")])
        service.flushPendingSave()                                          // one row on disk
        service.record([event(.worry, ref: "w1", dayKey: "2026-05-02")])    // one row only in the queue
        #expect(service.entries.count == 2)

        // Hoisted out of #expect: the macro wraps its subexpressions in @Sendable closures, which
        // rejects the non-Sendable repository capture.
        let didReset = service.reset(deletingRowsWith: { repository.deleteAll() })
        #expect(didReset)
        #expect(service.entries.isEmpty)
        #expect(repository.load().isEmpty)

        // The queued row must be DROPPED, not flushed back on top of the emptied store: reload
        // flushes first, so a surviving pending row would reappear here as both a count and a row.
        service.reloadFromStore()
        #expect(service.entries.isEmpty)
        #expect(repository.load().isEmpty)
        let countsAllZero = service.lifetimeCounts.values.allSatisfy({ $0 == 0 })
        #expect(countsAllZero)
    }

    @MainActor @Test func resetReportsAFailedRowDeleteAndStillEmptiesMemory() {
        let controller = PersistenceController(inMemory: true)
        let repository = MilestoneLedgerRepository(controller: controller)
        let service = MilestoneLedgerService(repository: repository)
        service.record([event(.journal, ref: "j1", dayKey: "2026-05-01")])
        service.flushPendingSave()

        // A deleter that cannot reach the rows: the funnel needs `false` back so the delete dialog
        // names the milestone trail instead of claiming a complete wipe. (Hoisted out of #expect —
        // the macro's @Sendable rewrite rejects the closure argument.)
        let didReset = service.reset(deletingRowsWith: { false })
        #expect(didReset == false)
        // In-memory state goes regardless — a failed delete leaves rows on disk, not counts on screen.
        #expect(service.entries.isEmpty)
        #expect(service.lifetimeCounts[.journal] == 0)
    }

    @MainActor @Test func theFunnelCanNarrowTheExposedStoreToTheRowDeleter() {
        // The seam the app's deletion funnel depends on: `MilestoneLedgerRepositoring` carries no
        // delete, so the funnel narrows `persistedStore` to the CloudKit conformer. If this stops
        // being the production conformer, the wipe silently degrades to memory-only.
        let controller = PersistenceController(inMemory: true)
        let service = MilestoneLedgerService(repository: MilestoneLedgerRepository(controller: controller))
        let rows = service.persistedStore as? MilestoneLedgerRepository
        #expect(rows != nil, "the funnel's `as? MilestoneLedgerRepository` narrowing no longer resolves — the wipe would leave every milestone row on disk and in iCloud.")
        #expect(rows?.deleteAll() == true)
    }

    // MARK: - The CloudKit half

    /// The cloud copies are deleted by the LOCAL delete propagating through
    /// NSPersistentCloudKitContainer's mirror, which only happens for objects deleted through a
    /// managed context. An `NSBatchDeleteRequest` goes straight to the store file: the rows would
    /// vanish here and stay in the user's private database, ready to sync back. That is a property
    /// of the code's shape, so it is pinned by shape — a behavioral test cannot reach CloudKit.
    @Test func theRowDeleteIsContextBasedSoItReachesTheCloudKitMirror() throws {
        let source = try String(
            contentsOf: RepoRoot.url.appendingPathComponent("FernletKit/Sources/CloudKitSync/MilestoneLedgerRepository.swift"),
            encoding: .utf8
        )
        let body = try PrivacyWipeCoverageTests.functionBody(matching: "public func deleteAll() -> Bool", in: source)
        #expect(body.contains("context.delete("), "the milestone delete no longer removes objects through the view context — the scan is reading the wrong function, or the delete stopped mirroring.")
        #expect(
            !body.contains("NSBatchDeleteRequest"),
            "the milestone delete uses a batch delete: it bypasses the CloudKit mirror, so the rows would be deleted on this device and left in the user's iCloud private database."
        )
        #expect(body.contains("MilestoneLedgerRecord"), "the delete no longer names its entity — a renamed entity would delete nothing and still return true.")
    }
}
