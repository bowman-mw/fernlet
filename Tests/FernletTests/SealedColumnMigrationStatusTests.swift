// SealedColumnMigrationStatusTests.swift
// FernletTests
//
// Pins the Phase 2.6 D3 surface — `FernletStore.sealedColumnMigrationStatus`, the in-hub
// status capsule's session state (design §8): duress-blind three ways, reset on every lock
// engage, `.idle` (never `.blocked`) for a key-revocation-only stop, and a `.finished` epoch
// that spans split runs within one process. The capsule itself renders from ONE filter,
// `sealedColumnMigrationCapsuleStatus`, so these pins govern the UI by construction.

import CryptoKit
import FernletLock
import Foundation
import LocalPersistence
import PrivateStoreCore
import Testing
@testable import Fernlet

@MainActor
@Suite(.serialized)
struct SealedColumnMigrationStatusTests {

    private func makeStore(_ name: String) -> FernletStore {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name)-\(UUID().uuidString).json")
        return FernletStore(
            repository: LocalFernletRepository(fileURL: url),
            sensitiveVisibilityDefaults: uniqueSensitiveVisibilityDefaults(),
            photoDocumentsDirectory: uniquePhotoDirectory()
        )
    }

    private func worryColumn() -> SealedColumnIdentifier {
        SealedColumnIdentifier(entityName: "WorryNarrative", attributeName: "textCiphertext")
    }

    /// A pass result blocked by a real failure (an unopenable legacy blob).
    private func blockedResult() -> SealedColumnMigrationResult {
        SealedColumnMigrationResult(
            columns: [worryColumn(): SealedColumnMigrationTally(unopenableUnprefixed: 1)],
            rowsScanned: 1, rowsAvailable: 1
        )
    }

    /// A convert-then-relock pass: real conversions, then the vend answered nil — no failure.
    private func keyRevokedAfterConvertingResult() -> SealedColumnMigrationResult {
        SealedColumnMigrationResult(
            columns: [worryColumn(): SealedColumnMigrationTally(convertedFromLegacyUnprefixed: 2)],
            notAttempted: [.keyRevoked: 3],
            rowsScanned: 2, rowsAvailable: 5
        )
    }

    /// A converting pass over a legacy corpus (the pass that precedes a latching confirm).
    private func convertingResult() -> SealedColumnMigrationResult {
        SealedColumnMigrationResult(
            columns: [worryColumn(): SealedColumnMigrationTally(convertedFromLegacyUnprefixed: 2)],
            rowsScanned: 2, rowsAvailable: 2
        )
    }

    /// The clean confirming pass (everything openedV3).
    private func cleanResult() -> SealedColumnMigrationResult {
        SealedColumnMigrationResult(
            columns: [worryColumn(): SealedColumnMigrationTally(openedV3: 2)],
            rowsScanned: 2, rowsAvailable: 2
        )
    }

    // MARK: A blocked run surfaces the hub status row; a latching converting run finishes; the
    // latched steady state shows nothing at all.
    @Test func blockedPassSurfacesTheHubStatusRow() {
        let store = makeStore("column-status-blocked")
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: false, passResults: [blockedResult()])
        #expect(store.sealedColumnMigrationStatus == .blocked)
        #expect(store.sealedColumnMigrationCapsuleStatus == .blocked)
    }

    @Test func finishedStateIsSessionScoped() {
        let store = makeStore("column-status-finished")
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: true, passResults: [convertingResult(), cleanResult()])
        #expect(store.sealedColumnMigrationStatus == .finished)
        #expect(store.sealedColumnMigrationCapsuleStatus == .finished)
        // Session-scoped: the lock engage clears it; the latch is its durable half.
        store.lockState = .locked(cooldownDeadline: nil)
        #expect(store.sealedColumnMigrationStatus == .idle)
        #expect(store.sealedColumnMigrationCapsuleStatus == nil)
    }

    // MARK: The latched steady state (a clean run that never converted anything, ever) shows
    // nothing — no capsule flicker for the common case.
    @Test func latchedSteadyStateNeverLeavesIdle() {
        let store = makeStore("column-status-steady")
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: true, passResults: [cleanResult()])
        #expect(store.sealedColumnMigrationStatus == .idle)
        #expect(store.sealedColumnMigrationCapsuleStatus == nil)
    }

    // MARK: §8 pin 1 (17a): a duress session never shows the capsule for ANY status value, and
    // the funding call itself early-outs. Fully seam-isolated: the injected defaults and task
    // body mean this test can never touch `UserDefaults.standard` or the shared sealed store.
    @Test func duressSessionNeverShowsMigrationCapsule() throws {
        let store = makeStore("column-status-duress")
        let isolatedDefaults = try #require(UserDefaults(suiteName: "column-status-duress-\(UUID().uuidString)"))
        store.sealedColumnMigrationLatchDefaultsForTesting = isolatedDefaults
        store.sealedColumnMigrationTaskBodyForTesting = { _, _ in }
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: false, passResults: [blockedResult()])
        #expect(store.sealedColumnMigrationStatus == .blocked)
        store.duressSessionActive = true
        #expect(store.sealedColumnMigrationCapsuleStatus == nil, "the decoy must never render migration state")
        // And the funding call never funds under duress — defense in depth on top of the key
        // vend answering nil for a decoy session.
        let funded = store.runSealedColumnFormatMigrationIfNeeded { nil }
        #expect(!funded)
    }

    // MARK: THE DURESS-BLINDNESS WALL (grep-style, the house boundary-test idiom): the hub view
    // renders the capsule ONLY through the store's one duress-blind filter. A future edit that
    // reads the unfiltered status would bypass §8 pin 1 with every behavior test still green —
    // this makes that a compile-adjacent failure instead of a silent decoy leak.
    @Test func privateHubRendersOnlyTheDuressBlindCapsuleFilter() throws {
        let source = try String(
            contentsOf: RepoRoot.url.appendingPathComponent("App/Fernlet/PrivateHubView.swift"),
            encoding: .utf8
        )
        #expect(source.contains("store.sealedColumnMigrationCapsuleStatus"),
                "the capsule must render from the duress-blind filter")
        #expect(!source.contains("store.sealedColumnMigrationStatus"),
                "PrivateHubView must NEVER read the unfiltered status — the filter IS the duress blindness")
    }

    // MARK: §8 pin 2 (17b): a `.blocked` from a legitimate session cannot survive a re-lock into
    // anyone's next session — duress or real.
    @Test func lockEngageResetsMigrationStatusToIdle() {
        let store = makeStore("column-status-lockengage")
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: false, passResults: [blockedResult()])
        #expect(store.sealedColumnMigrationStatus == .blocked)
        store.lockState = .locked(cooldownDeadline: nil)
        #expect(store.sealedColumnMigrationStatus == .idle)
        // A subsequent (decoy or real) unlock starts from nothing.
        store.lockState = .unlocked(scope: .privateHub)
        #expect(store.sealedColumnMigrationStatus == .idle)
        #expect(store.sealedColumnMigrationCapsuleStatus == nil)
    }

    // MARK: §8 pin 3 (17c): a stop whose ONLY reason is the key vend answering nil records
    // `.idle`, never `.blocked` — the duress session's own would-be pass stops exactly this way,
    // and a "couldn't be re-secured" line for a routine re-lock would be false alarm noise.
    @Test func keyRevokedOnlyStopRecordsIdleNotBlocked() {
        let store = makeStore("column-status-keyrevoked")
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: false, passResults: [keyRevokedAfterConvertingResult()])
        #expect(store.sealedColumnMigrationStatus == .idle)
        #expect(store.sealedColumnMigrationCapsuleStatus == nil)
    }

    // MARK: 17d: the `.finished` epoch spans split runs within a process — a convert pass, a
    // re-lock (status → .idle), then a later clean latching run still earns `.finished` via the
    // process-local converted flag; and a latch reset + later converting run re-arms it for the
    // new epoch.
    @Test func finishedCapsuleSpansSplitRunsWithinAProcess() {
        let store = makeStore("column-status-split")
        store.lockState = .unlocked(scope: .privateHub)
        // Run 1: converted a page, then the hub re-locked (key revoked) — records .idle.
        store.recordSealedColumnMigrationRun(latched: false, passResults: [keyRevokedAfterConvertingResult()])
        #expect(store.sealedColumnMigrationStatus == .idle)
        store.lockState = .locked(cooldownDeadline: nil)
        // Run 2, next unlock: the confirming run latches WITHOUT converting anything itself.
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: true, passResults: [cleanResult()])
        #expect(store.sealedColumnMigrationStatus == .finished, "the process-local converted flag covers the split")
        // A new epoch: latch reset elsewhere, a later converting run latches again — re-arms.
        store.lockState = .locked(cooldownDeadline: nil)
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationRun(latched: true, passResults: [convertingResult(), cleanResult()])
        #expect(store.sealedColumnMigrationStatus == .finished)
    }

    // MARK: The `.running` gate: only a pass that has BOTH run longer than the named delay and
    // converted at least one row may show the capsule — the steady-state clean pass never
    // flickers it.
    @Test func runningRequiresBothElapsedTimeAndConversions() {
        let store = makeStore("column-status-running")
        store.lockState = .unlocked(scope: .privateHub)
        store.recordSealedColumnMigrationProgress(convertedSoFar: 0, elapsed: .seconds(5))
        #expect(store.sealedColumnMigrationStatus == .idle, "no conversions — no capsule")
        store.recordSealedColumnMigrationProgress(convertedSoFar: 3, elapsed: .milliseconds(200))
        #expect(store.sealedColumnMigrationStatus == .idle, "too fast — no flicker")
        store.recordSealedColumnMigrationProgress(convertedSoFar: 3, elapsed: .seconds(2))
        #expect(store.sealedColumnMigrationStatus == .running)
        #expect(store.sealedColumnMigrationCapsuleStatus == .running)
        // And a duress mirror flipping mid-pass blinds the capsule immediately.
        store.duressSessionActive = true
        #expect(store.sealedColumnMigrationCapsuleStatus == nil)
    }

    // MARK: The funding call's synchronous guards: one run at a time, and a revalidation slot
    // that an `.unavailable` recheck does NOT consume. Fully seam-isolated (isolated defaults
    // suite + a task body that records into a box and touches nothing shared), so no stray
    // funded task can ever reach `UserDefaults.standard` or `PrivatePersistenceController.shared`.
    @Test func fundingCallGuardsAndRevalidationSlot() throws {
        let store = makeStore("column-status-funding")
        store.lockState = .unlocked(scope: .privateHub)
        let defaults = try #require(UserDefaults(suiteName: "column-status-funding-\(UUID().uuidString)"))
        store.sealedColumnMigrationLatchDefaultsForTesting = defaults
        let fundedBodies = StatusTaskCounter()
        store.sealedColumnMigrationTaskBodyForTesting = { _, _ in fundedBodies.increment() }
        let latch = SealedColumnFormatMigrator.latch(defaults: defaults)
        latch.reset()

        let funded = store.runSealedColumnFormatMigrationIfNeeded { nil }
        #expect(funded, "an unlatched trigger funds a run")
        let refunded = store.runSealedColumnFormatMigrationIfNeeded { nil }
        #expect(!refunded, "the in-flight guard prevents self-racing")

        // The revalidation slot: `.unavailable` clears in-flight WITHOUT consuming the slot…
        let shouldRunAfterUnavailable = store.recordSealedColumnRevalidationOutcome(.unavailable)
        #expect(!shouldRunAfterUnavailable)
        latch.markComplete()
        let fundedAgain = store.runSealedColumnFormatMigrationIfNeeded { nil }
        #expect(fundedAgain, "an unconfirmed latch is re-checked at the next funded trigger")
        // …while `.confirmed` consumes it: the next latched trigger is a Bool read, no task.
        let shouldRunAfterConfirmed = store.recordSealedColumnRevalidationOutcome(.confirmed)
        #expect(!shouldRunAfterConfirmed)
        let fundedThird = store.runSealedColumnFormatMigrationIfNeeded { nil }
        #expect(!fundedThird, "a confirmed latch costs nothing further this process")
        // And `.reset` is the one outcome that continues into a keyed pass.
        let shouldRunAfterReset = store.recordSealedColumnRevalidationOutcome(.reset)
        #expect(shouldRunAfterReset)
        store.recordSealedColumnMigrationRun(latched: false, passResults: [])
    }
}

/// Thread-safe counter for the injected task-body seam — the only thing a funded test task
/// touches. `@unchecked Sendable` on the documented invariant: the one mutable field is only
/// ever touched under `lock`.
private nonisolated final class StatusTaskCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    /// Records one body invocation.
    func increment() {
        lock.withLock { count += 1 }
    }

    /// The invocation count so far.
    var value: Int {
        lock.withLock { count }
    }
}
