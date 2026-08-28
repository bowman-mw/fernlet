//
//  FormatMigratorTests.swift
//  FernletTests
//
//  The SYNC run loop's contract, driven over a scripted conformer — the other half of the
//  both-loops rule `AsyncFormatMigratorTests` states. `AsyncFormatMigrator.run(maxPasses:)` is a
//  deliberate line-for-line duplicate of `FormatMigrator.run(maxPasses:)` (the sync protocol
//  cannot express a pass that is itself `async`), and each loop's doc comment says a change to
//  either one's policy must land in both. A duplication defended only by a comment drifts; these
//  two suites are what make the rule checkable, and they pin the same three properties in the same
//  order so a diff between them reads as a diff between the loops:
//  1. the named bound (R2) — a run can never fund more passes than it was given;
//  2. the no-forward-progress stop — a permanently unconvertible blob cannot spin;
//  3. the latch is set by a clean pass and by nothing else, and a set latch short-circuits.
//
//  Deliberately no corpus of any kind: the conformer's passes are a script, so what is asserted is
//  the LOOP's policy rather than any one surface's idea of "clean" (`OwnPhotoKeyMigrationTests`
//  covers the shipping conformer's own idea of it). The suite and its doubles are `nonisolated`,
//  which is the other thing worth proving here: the sync protocol exists for surfaces that run
//  inside off-main launch tasks, so nothing in this contract may require the main actor.
//

import FernletCrypto
import Foundation
import Testing

nonisolated struct FormatMigratorTests {

    /// R2: the loop funds at most the passes it was given, even when the script would eventually
    /// come back clean. A bound that could be overrun is not a bound — this is the jetsam failure
    /// bounded passes exist to prevent, on surfaces whose every pass sweeps a whole corpus.
    @Test func theSyncRunLoopHonorsItsNamedBound() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrator = ScriptedSyncMigrator(defaults: defaults, script: [.progress, .progress, .clean])

        #expect(migrator.run(maxPasses: 2) == false)
        #expect(migrator.invocations == 2, "the loop funded more passes than its bound")
        #expect(!migrator.overran, "the loop asked for a pass the script never promised")
        #expect(!migrator.latch.isComplete, "an unfinished run latched")
    }

    /// A pass that proved nothing AND converted nothing would repeat identically, so the loop stops
    /// rather than burning a second whole-corpus sweep on it. The latch stays closed and the next
    /// launch re-scans — by which time whatever blocked it (a locked keychain, a full disk) may
    /// have recovered.
    @Test func theSyncRunLoopStopsOnNoForwardProgress() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrator = ScriptedSyncMigrator(defaults: defaults, script: [.blocked, .clean])

        #expect(migrator.run() == false)
        #expect(migrator.invocations == 1, "a pass that changed nothing was funded a second identical run")
        #expect(!migrator.latch.isComplete)
    }

    /// The latch comes from a CLEAN pass and from nowhere else — a converting pass is not its own
    /// proof, because it found legacy blobs, so the second pass exists to confirm by read-back.
    /// That matters more here than on the async side: every latch in this family gates an
    /// irreversible step (dropping a legacy reader, binding a key) whose cost falls on bytes the
    /// pass never saw. And once set the loop short-circuits: `run()` is idempotent and a proven
    /// device never pays for the sweep again.
    @Test func theSyncRunLoopLatchesOnlyOnACleanPassAndShortCircuitsAfter() throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrator = ScriptedSyncMigrator(defaults: defaults, script: [.progress, .clean])

        #expect(migrator.run() == true)
        #expect(migrator.invocations == 2, "the converting pass latched without a confirming pass")
        #expect(migrator.latch.isComplete)

        #expect(migrator.run() == true)
        #expect(migrator.invocations == 2, "a latched migration swept the corpus again")
    }

    private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "fernlet.tests.formatMigrator.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName) ?? .standard, suiteName)
    }
}

// MARK: - Scripted conformer
//
// A deliberate file-private duplicate of `AsyncFormatMigratorTests`' doubles rather than a shared
// pair: the two suites exist to catch the moment the two loops diverge, and a shared fixture is
// one more thing a divergence could hide behind.

/// One scripted pass verdict: the two Bools ``FormatMigrationPassResult`` names and nothing else,
/// because those are exactly what the shared loop reads off a real tally.
private struct ScriptedSyncPassResult: FormatMigrationPassResult {
    let isClean: Bool
    let madeForwardProgress: Bool

    /// A pass that converted something — and therefore, by the shared contract, cannot itself be
    /// proof: it FOUND legacy blobs.
    static let progress = ScriptedSyncPassResult(isClean: false, madeForwardProgress: true)
    /// A pass that proves the corpus fully migrated.
    static let clean = ScriptedSyncPassResult(isClean: true, madeForwardProgress: false)
    /// A pass that proved nothing and converted nothing — a corpus this device cannot finish.
    static let blocked = ScriptedSyncPassResult(isClean: false, madeForwardProgress: false)
}

/// A ``FormatMigrationLatching`` over one key in an isolated `UserDefaults` suite — the real
/// one-way semantics (absent reads false) without borrowing any shipping conformer's latch, so a
/// change to an app-side latch can never quietly rewrite what this loop test proves.
private struct ScriptedSyncLatch: FormatMigrationLatching {
    static let defaultsKey = "fernlet.tests.formatMigrator.latch"
    let defaults: UserDefaults

    var isComplete: Bool { defaults.bool(forKey: Self.defaultsKey) }
    func markComplete() { defaults.set(true, forKey: Self.defaultsKey) }
    func reset() { defaults.removeObject(forKey: Self.defaultsKey) }
}

/// A ``FormatMigrator`` whose passes are a script, counting how many the loop actually funded.
///
/// `nonisolated` throughout, and that is the point: the sync protocol exists for the file and
/// keychain surfaces that migrate inside off-main launch tasks (`OwnPhotoKeyMigrator` is the
/// shipping model), so a loop that quietly required the main actor would be unusable by every one
/// of them. A class rather than a struct only because the protocol's `performPass()` is
/// non-mutating and this double has to count its own invocations.
private final class ScriptedSyncMigrator: FormatMigrator {
    nonisolated let latch: ScriptedSyncLatch
    nonisolated static let maxMigrationPasses = 2

    /// Passes the loop actually funded.
    private(set) var invocations = 0
    /// Whether the loop asked for a pass past the end of the script — a bound overrun, reported
    /// rather than trapped so the failing expectation names the real problem.
    private(set) var overran = false

    private let script: [ScriptedSyncPassResult]

    init(defaults: UserDefaults, script: [ScriptedSyncPassResult]) {
        self.latch = ScriptedSyncLatch(defaults: defaults)
        self.script = script
    }

    func performPass() -> ScriptedSyncPassResult {
        defer { invocations += 1 }
        guard invocations < script.count else {
            overran = true
            return .blocked
        }
        return script[invocations]
    }
}
