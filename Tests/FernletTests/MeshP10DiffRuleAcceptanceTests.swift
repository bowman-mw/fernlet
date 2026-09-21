// MeshP10DiffRuleAcceptanceTests.swift
// FernletTests
//
// Network migration **P10's acceptance battery, clause (3)** (plan §17.2, launcher item 9): "reload
// timelines only on change", from the field classification all the way out to a
// `CompanionRefreshOutcome`.
//
// **The trap the clause exists for.** `WidgetSnapshot` is `Equatable` by synthesis and the synthesis
// includes `computedAt`, which `FernletStore.currentWidgetSnapshot()` stamps `Date()` at every
// construction. So `==` is FALSE between two snapshots of an unchanged day a millisecond apart, and
// a handler that diffed with `==` would reload the widget every fifteen minutes forever, with a
// green suite behind it. That is why §27.3's decision reads "diff the MEANINGFUL fields, never the
// whole `Equatable`".
//
// **Values over source text.** The classification reaches this file as two VALUES —
// `WidgetSnapshotContentEqualityTests.contentFields` and `.metadataFields` — and the struct's own
// stored properties reach it through `Mirror`. Nothing here greps `contentEquals`'s body; the
// decision is exercised, not read.
//
// **The table is REUSED, not copied.** The flip table lives once, in the unit suite; a second copy
// here is a second thing to keep whole, and two tables edited together would still both be green.
// What this suite adds is the direction that suite does not carry: the diff decides an OUTCOME, and
// the outcome decides what iOS is told at `setTaskCompleted(success:)`.
//
// **And the half nobody else asserts: the file is written EITHER WAY.** "Always write, reload only
// on change" is a pair, and `CompanionRefreshPipelineTests.aSecondProductionRunOverAnUnchangedStore`
// `DoesNotReload` carries only its second half. A dull refresh that quietly skipped the write would
// pass every cell in that suite and would leave a reader — the widget's own timeline provider, a
// later diff — unable to tell a current snapshot from one the app stopped publishing hours ago.
//
// **The foreground path is pinned as the CURRENT truth, not as an ideal.** `publish(_:)` still
// reloads unconditionally; decision D-10.4.5 defers narrowing it to the close-out. A cell states
// that out loud so the scoping is a fact rather than an intention.

import FernletDomainModel
import Foundation
import Testing
@testable import Fernlet

/// **Clause (3): the diff rule.** The content/metadata partition, a stamp-only difference that
/// reloads nothing, every content flip that does, the untouched foreground path, and — on the
/// shipping bindings — the write that happens anyway.
@MainActor
@Suite(.serialized)
struct MeshP10DiffRuleAcceptanceTests {

    /// A directory nothing else writes to, standing in for the app group.
    ///
    /// - Returns: A fresh directory URL.
    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MeshP10DiffRuleAcceptanceTests-\(UUID().uuidString)", isDirectory: true)
    }

    /// §17.2's eight step bindings, bound to a real mirror and one fixed snapshot.
    ///
    /// The publish step is the SHIPPING door (`publishIfContentChanged(_:)`) over the real file
    /// store, so the diff under test is the app's and not a fake's idea of one. The recompute
    /// answers the snapshot's own raw state, so the pipeline's determinism check has nothing to
    /// complain about and the cells stay about the diff; the two gates ahead of it answer "nothing
    /// pending, context complete", which is the state this clause is about.
    ///
    /// - Parameters:
    ///   - mirror: The mirror to publish through.
    ///   - snapshot: What the run publishes.
    /// - Returns: The steps.
    private func steps(mirror: WidgetSnapshotMirror, snapshot: WidgetSnapshot) -> CompanionRefreshSteps {
        CompanionRefreshSteps(
            hasUndrainedWidgetActions: { false },
            publishedSnapshotIsForCurrentDay: { true },
            scoringContextIsComplete: { true },
            publishedSnapshot: { mirror.currentSnapshot() },
            rollDay: { false },
            recompute: { snapshot.companionStateRaw },
            makeSnapshot: { snapshot },
            publish: { mirror.publishIfContentChanged($0) }
        )
    }

    /// One run of §17.2's pipeline over a mirror and a snapshot.
    ///
    /// - Parameters:
    ///   - mirror: The mirror to publish through.
    ///   - snapshot: What to publish.
    /// - Returns: The finished run.
    private func run(_ mirror: WidgetSnapshotMirror, _ snapshot: WidgetSnapshot) async -> CompanionRefreshRun {
        let pipeline = CompanionRefreshPipeline(acquire: { self.steps(mirror: mirror, snapshot: snapshot) })
        return await pipeline.run()
    }

    /// **The classification is a PARTITION of the struct's stored fields, and it is behavioural.**
    ///
    /// Three claims in one place, because separately each is satisfiable by a table that is wrong.
    /// Disjoint and total against `Mirror` says a field cannot be classified twice or not at all — a
    /// field added without a classification reds here. `metadataFields == ["computedAt"]` says which
    /// side the one metadata field is on. And the last two assertions make the table BEHAVIOURAL
    /// rather than declarative: the metadata field flipped leaves the two snapshots content-equal
    /// and NOT `==`, which is the whole reason the refresh could not have used `==`.
    @Test func theClassificationPartitionsTheStructAndSaysWhatItMeans() {
        let baseline = WidgetSnapshotContentEqualityTests.baseline()
        let stored = Mirror(reflecting: baseline).children.compactMap(\.label)
        let content = Set(WidgetSnapshotContentEqualityTests.contentFields)
        let metadata = Set(WidgetSnapshotContentEqualityTests.metadataFields)

        #expect(content.isDisjoint(with: metadata), "no field is on both sides of the diff")
        #expect(content.union(metadata) == Set(stored), """
            the content/metadata table no longer covers WidgetSnapshot's stored fields \
            (\(stored.sorted())). A field added without a classification is a field the refresh \
            silently ignores, or one it reloads on forever — neither is a decision anybody made
            """)
        #expect(WidgetSnapshotContentEqualityTests.metadataFields == ["computedAt"],
                "one metadata field, and it is the construction stamp no widget family renders")
        #expect(Set(WidgetSnapshotContentEqualityTests.flips.map(\.field)) == content,
                "and the flip table this clause walks below covers every content field, exactly")

        var restamped = baseline
        restamped.computedAt = baseline.computedAt.addingTimeInterval(900)
        #expect(baseline.contentEquals(restamped), "a newer stamp alone renders identically")
        #expect(baseline != restamped, """
            …and is NOT `==`. Both directions in one breath: this is why a handler built on the \
            synthesised equality would reload the widget on every refresh, forever
            """)
    }

    /// **A stamp-only difference is written, is not reloaded, and ends the run `unchanged`.**
    ///
    /// The ordinary DULL refresh — what most of them are — carried all the way to the value the
    /// coordinator hands `setTaskCompleted(success:)`. Counted through the real
    /// `WidgetSnapshotMirror` and the `reloadTimelines` closure the type already injects, so it is
    /// the app's WidgetKit poke being counted.
    ///
    /// The WRITE is asserted as hard as the reload. Both stamps here are whole seconds, so they
    /// survive the encoder's ISO-8601 second resolution unchanged and the file's own value can be
    /// compared exactly.
    @Test func aStampOnlyDifferenceIsWrittenReloadsNothingAndEndsUnchanged() async {
        var reloads = 0
        let mirror = WidgetSnapshotMirror(directory: temporaryDirectory(), reloadTimelines: { reloads += 1 })
        let first = WidgetSnapshotContentEqualityTests.baseline()

        let opening = await run(mirror, first)
        #expect(opening.outcome == .reloaded, "nothing was published before, so a first publish is a change")
        #expect(opening.steps.contains(.reload))
        #expect(reloads == 1)

        var restamped = first
        restamped.computedAt = first.computedAt.addingTimeInterval(900)
        let dull = await run(mirror, restamped)

        #expect(dull.outcome == .unchanged, "same day, same numbers, a newer stamp")
        #expect(dull.outcome.completesSuccessfully, """
            …and the system is told the task SUCCEEDED. A refresh that correctly found nothing to \
            do finished on the app's terms; reporting a failure would teach the scheduler to stop \
            granting the refreshes that are working
            """)
        #expect(dull.steps.contains(.reload) == false, "the trace carries no reload, because none happened")
        #expect(reloads == 1, "THE assertion of this cell: a second reload here is the defect §17.2 names")
        #expect(mirror.currentSnapshot()?.computedAt == restamped.computedAt,
                "…and it was still WRITTEN — the stamp moves whether or not the widget is poked")
    }

    /// **Every content field, flipped alone, reloads and ends the run `reloaded`.**
    ///
    /// The complement of the cell above, walked over the table rather than sampled: six
    /// near-identical cells can be five near-identical cells and nobody notices. Each row starts
    /// from a fresh mirror and a published baseline, so the flip is the ONLY difference the diff
    /// can see.
    ///
    /// `dateKey` is in this table and is the one change a background refresh exists to catch: the
    /// app was backgrounded yesterday, the refresh runs after midnight, and the widget must stop
    /// rendering yesterday's companion.
    @Test func everyContentFieldFlipReloadsAndEndsReloaded() async {
        // R2: bounded by the flip table, itself pinned whole against the content fields above.
        for flip in WidgetSnapshotContentEqualityTests.flips {
            var reloads = 0
            let mirror = WidgetSnapshotMirror(
                directory: temporaryDirectory(), reloadTimelines: { reloads += 1 })
            let baseline = WidgetSnapshotContentEqualityTests.baseline()
            _ = await run(mirror, baseline)

            var changed = baseline
            flip.apply(&changed)
            changed.computedAt = baseline.computedAt.addingTimeInterval(900)
            let second = await run(mirror, changed)

            #expect(baseline.contentEquals(changed) == false, "\(flip.field): the flip is a content change")
            #expect(second.outcome == .reloaded, "\(flip.field): a real change reloads")
            #expect(second.steps.contains(.reload), "\(flip.field): and the trace says so")
            #expect(reloads == 2, "\(flip.field): the baseline's reload, and this one")
        }
    }

    /// **The unconditional foreground path is untouched, and that scoping is a fact.**
    ///
    /// §17.2 scopes "reload only on change" to the REFRESH handler. Narrowing `publish(_:)` would
    /// change every widget update in the app — a save, a day roll, a queue drain — each of which is
    /// a change by construction anyway, and each of which would then pay a file read it does not
    /// need. Decision D-10.4.5 defers that to the close-out; until it is taken, this is the current
    /// truth and an edit that routes the foreground through the diff reds here rather than passing
    /// as an improvement nobody decided on.
    @Test func theForegroundPublishPathStillReloadsUnconditionally() {
        var reloads = 0
        let mirror = WidgetSnapshotMirror(directory: temporaryDirectory(), reloadTimelines: { reloads += 1 })
        let snapshot = WidgetSnapshotContentEqualityTests.baseline()

        mirror.publish(snapshot)
        mirror.publish(snapshot)

        #expect(reloads == 2, "the foreground path is unconditional and stays that way (D-10.4.5)")
    }

    /// **On the shipping bindings, a dull refresh writes anyway** — the half of the clause the unit
    /// suite does not carry.
    ///
    /// `CompanionRefreshWiring.steps(for:)` is what production runs, byte for byte, so a binding
    /// wired to `publish(_:)` instead of `publishIfContentChanged(_:)` reds here. And the file is
    /// BACKDATED an hour between the two runs, which is what makes the write observable at all: the
    /// encoder's ISO-8601 dates are second-resolution, so two runs microseconds apart leave stamps
    /// a comparison cannot tell apart, and "it was written" would be an assertion about nothing.
    /// An hour is well clear of that floor.
    ///
    /// The pair is the clause in one cell — the content is identical, the run reloads nothing, and
    /// the stamp on disk moved forward by most of an hour anyway. Neither half alone says it.
    @Test func theDullRefreshWritesAnywayOnTheShippingBindings() async throws {
        let store = makeTestStore()
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })
        let mirror = store.ensureWidgetSnapshotMirror()

        let opening = await pipeline.run()
        #expect(opening.outcome == .reloaded, "the store's app-group directory is fresh: no previous snapshot")
        let published = try #require(mirror.currentSnapshot(), "the first run published nothing at all")

        var backdated = published
        backdated.computedAt = published.computedAt.addingTimeInterval(-3600)
        mirror.publish(backdated)

        let second = await pipeline.run()

        #expect(second.outcome == .unchanged, "nothing about the store moved, so the diff finds nothing")
        #expect(second.steps.contains(.reload) == false, "so nothing poked WidgetKit")
        let current = try #require(mirror.currentSnapshot(), "the second run left no snapshot at all")
        #expect(current.contentEquals(backdated), """
            the content is identical — which is why there was no reload, and why a handler built on \
            the synthesised `==` would have poked WidgetKit here anyway
            """)
        #expect(current.computedAt > backdated.computedAt, """
            …and the file was re-written regardless: the backdated stamp is gone. "Always write, \
            reload only on change" is a pair, and a dull refresh that skipped the write would leave \
            every later reader unable to tell this snapshot from one the app abandoned hours ago
            """)
        #expect(current.companionStateRaw == store.companionState.rawValue,
                "and the recompute binding still reads the store's own companion, not a copy of the rule")
    }
}
