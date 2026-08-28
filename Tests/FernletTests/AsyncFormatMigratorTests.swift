//
//  AsyncFormatMigratorTests.swift
//  FernletTests
//
//  The ASYNC run loop's contract, driven over a scripted conformer (crypto-standardization
//  Phase 2.1). `AsyncFormatMigrator.run(maxPasses:)` is a deliberate line-for-line duplicate of
//  `FormatMigrator.run(maxPasses:)` — the sync protocol cannot express a pass that is itself
//  `async` and main-actor over CloudKit, and bridging one into a synchronous `performPass()` would
//  mean parking a thread on main-actor work. A duplicated loop is only safe while BOTH copies are
//  pinned, and these are the pin for this copy:
//  1. the named bound (R2) — a run can never fund more passes than it was given;
//  2. the no-forward-progress stop — a permanently blocked corpus cannot spin;
//  3. the latch is set by a clean pass and by nothing else, and a set latch short-circuits.
//
//  Deliberately no CloudKit, no crypto and no corpus of any kind: the conformer's passes are a
//  script, so what is asserted is the LOOP's policy rather than one surface's idea of "clean".
//

import FernletCrypto
import Foundation
import Testing

@MainActor
struct AsyncFormatMigratorTests {

    /// R2: the loop funds at most the passes it was given, even when the script would eventually
    /// come back clean. A bound that could be overrun is not a bound — this is the jetsam failure
    /// bounded passes exist to prevent, on a surface whose every pass decrypts a whole library.
    @Test func theAsyncRunLoopHonorsItsNamedBound() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrator = ScriptedAsyncMigrator(defaults: defaults, script: [.progress, .progress, .clean])

        #expect(await migrator.run(maxPasses: 2) == false)
        #expect(migrator.invocations == 2, "the loop funded more passes than its bound")
        #expect(!migrator.overran, "the loop asked for a pass the script never promised")
        #expect(!migrator.latch.isComplete, "an unfinished run latched")
    }

    /// A pass that proved nothing AND converted nothing would repeat identically, so the loop
    /// stops rather than burning a second whole-corpus sweep on it. The latch stays closed and the
    /// next user-initiated run re-evaluates — by which time whatever blocked it (a transport
    /// failure, another device's unhealed entries) may have cleared.
    @Test func theAsyncRunLoopStopsOnNoForwardProgress() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrator = ScriptedAsyncMigrator(defaults: defaults, script: [.blocked, .clean])

        #expect(await migrator.run() == false)
        #expect(migrator.invocations == 1, "a pass that changed nothing was funded a second identical run")
        #expect(!migrator.latch.isComplete)
    }

    /// The latch comes from a CLEAN pass and from nowhere else — a converting pass is not its own
    /// proof, because it found legacy blobs, so the second pass exists to confirm by read-back.
    /// And once set the loop short-circuits: `run()` is idempotent and a proven device never pays
    /// for the sweep again.
    @Test func theAsyncRunLoopLatchesOnlyOnACleanPassAndShortCircuitsAfter() async throws {
        let (defaults, suiteName) = isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let migrator = ScriptedAsyncMigrator(defaults: defaults, script: [.progress, .clean])

        #expect(await migrator.run() == true)
        #expect(migrator.invocations == 2, "the converting pass latched without a confirming pass")
        #expect(migrator.latch.isComplete)

        #expect(await migrator.run() == true)
        #expect(migrator.invocations == 2, "a latched migration swept the corpus again")
    }

    private func isolatedDefaults() -> (defaults: UserDefaults, suiteName: String) {
        let suiteName = "fernlet.tests.asyncFormatMigrator.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName) ?? .standard, suiteName)
    }
}

// MARK: - Scripted conformer

/// One scripted pass verdict: the two Bools ``FormatMigrationPassResult`` names and nothing else,
/// because those are exactly what the shared loop reads off a real tally.
private struct ScriptedPassResult: FormatMigrationPassResult {
    let isClean: Bool
    let madeForwardProgress: Bool

    /// A pass that converted something — and therefore, by the shared contract, cannot itself be
    /// proof: it FOUND legacy blobs.
    static let progress = ScriptedPassResult(isClean: false, madeForwardProgress: true)
    /// A pass that proves the corpus fully migrated.
    static let clean = ScriptedPassResult(isClean: true, madeForwardProgress: false)
    /// A pass that proved nothing and converted nothing — a corpus this device cannot finish.
    static let blocked = ScriptedPassResult(isClean: false, madeForwardProgress: false)
}

/// A ``FormatMigrationLatching`` over one key in an isolated `UserDefaults` suite — the real
/// one-way semantics (absent reads false) without borrowing any shipping conformer's latch, so a
/// change to an app-side latch can never quietly rewrite what this loop test proves.
private struct ScriptedLatch: FormatMigrationLatching {
    static let defaultsKey = "fernlet.tests.asyncFormatMigrator.latch"
    let defaults: UserDefaults

    var isComplete: Bool { defaults.bool(forKey: Self.defaultsKey) }
    func markComplete() { defaults.set(true, forKey: Self.defaultsKey) }
    func reset() { defaults.removeObject(forKey: Self.defaultsKey) }
}

/// An ``AsyncFormatMigrator`` whose passes are a script, counting how many the loop actually
/// funded. `@MainActor` state behind a `nonisolated let latch`, mirroring
/// `SealedPhotoBackupFormatMigrator`: that shape (main-actor pass state reached through a
/// nonisolated async requirement) is itself part of what these tests keep honest.
///
/// `performPass()` is `nonisolated` and hops with `MainActor.run`, which is what the app target's
/// witness thunk does implicitly. It has to be written out HERE because `AsyncFormatMigrator` is a
/// `nonisolated protocol` — its requirements are explicitly nonisolated, so a witness cannot be
/// main-actor-isolated. The app target gets the isolated conformance inferred for
/// `SealedPhotoBackupFormatMigrator` from its `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` build
/// setting; `FernletTests` does not set it, so the hop is spelled out. The loop under test is
/// unaffected either way — it awaits `performPass()` and reads the two verdicts.
@MainActor
private final class ScriptedAsyncMigrator: AsyncFormatMigrator {
    nonisolated let latch: ScriptedLatch
    nonisolated static let maxMigrationPasses = 2

    /// Passes the loop actually funded.
    private(set) var invocations = 0
    /// Whether the loop asked for a pass past the end of the script — a bound overrun, reported
    /// rather than trapped so the failing expectation names the real problem.
    private(set) var overran = false

    private let script: [ScriptedPassResult]

    init(defaults: UserDefaults, script: [ScriptedPassResult]) {
        self.latch = ScriptedLatch(defaults: defaults)
        self.script = script
    }

    nonisolated func performPass() async -> ScriptedPassResult {
        await MainActor.run { self.nextScriptedPass() }
    }

    /// The main-actor half of one pass: tallies the invocation and returns the scripted verdict.
    private func nextScriptedPass() -> ScriptedPassResult {
        defer { invocations += 1 }
        guard invocations < script.count else {
            overran = true
            return .blocked
        }
        return script[invocations]
    }
}
