// CompanionRefreshPipelineTests.swift
// FernletTests
//
// Network migration P10 item 4 (plan §17.2): the companion refresh HANDLER — the step order, the
// reload decision, the failure arms, what the coordinator tells the system for each of them, and
// the acquire path's own repair.
//
// **Why a pipeline of closures is testable and a method on the store is not.** §17.2's handler must
// acquire the store that already exists and must never build one. A handler written as a method on
// `FernletStore` could be exercised only by building a store — the one thing it is forbidden to do
// — and the suite would then be a Core Data test wearing a background-task hat.
// `CompanionRefreshPipeline` takes its eight post-acquisition steps as closures, so most cells below
// assert an ORDER and a DECISION over counters.
//
// **The bindings are exercised too, and that is deliberate.** A pipeline of fakes proves the
// handler's logic and nothing about whether `rollDay` really rolls the day. So the last section
// runs `CompanionRefreshWiring.steps(for:)` — the eight production expressions, byte for byte —
// against an ordinary test store. What is left untested is `FernletStoreAccess.shared.load()`,
// which is its own file's subject and cannot be driven without the process-global cache.
//
// **What is NOT claimed here.** That `load()` refuses on a locked device (its own suite's), that
// the day roll re-keys the diary correctly (`FernletStore`'s), that `WidgetSnapshotMirror` reloads
// only on a content change (`WidgetSnapshotContentEqualityTests`'), or that iOS ever delivers the
// task at all (item 9's device row). Each is pinned exactly once, where it lives.
//
// **No audit capture anywhere below.** `CompanionRefreshSchedulingTests` installs
// `FernletAuditLog` handlers, the registry is process-global and accumulates across suites, and two
// suites capturing the same `companionRefresh.` prefix in parallel would read each other's events.
// Everything here is asserted as a VALUE instead, which is the whole reason the pipeline returns
// one.
//
// Not a `MeshP<n>…AcceptanceTests`: gated on the `s3-grep` CI step.

import FernletDomainModel
import FernletFoundation
import Foundation
import HealthKitGateway
import Testing
@testable import Fernlet

// MARK: - The fake

/// Records what the pipeline asked for, and answers whatever the cell told it to.
///
/// One object rather than eight loose closures so a cell reads as a scenario: what the steps ANSWER
/// is set up front, what they were ASKED is read afterwards, and the two never interleave in the
/// cell's own text.
@MainActor
final class FakeCompanionRefreshSteps {

    /// Set to make ``pipeline()``'s acquisition throw instead of returning steps.
    var acquisitionError: Error?

    /// What ``CompanionRefreshSteps/hasUndrainedWidgetActions`` answers.
    var widgetActionsPending = false

    /// What ``CompanionRefreshSteps/publishedSnapshotIsForCurrentDay`` answers. `true` by default,
    /// so a cell that says nothing about the day gets the ordinary same-day skip.
    var publishedSnapshotIsForCurrentDay = true

    /// What ``CompanionRefreshSteps/scoringContextIsComplete`` answers. `true` by default: both
    /// adjustments are opt-in and off for most people, and a cell that does not mention them wants
    /// the refresh to run.
    var scoringContextIsComplete = true

    /// What ``CompanionRefreshSteps/publishedSnapshot`` answers BEFORE the day roll.
    var publishedSnapshotBeforeRoll: WidgetSnapshot?

    /// …and after it. A pair rather than a closure with a counter, because the only thing the
    /// pipeline does with these two values is compare them: a day roll on a warm process publishes
    /// through the store's own mirror, and this is how a cell scripts whether it did.
    var publishedSnapshotAfterRoll: WidgetSnapshot?

    /// What ``CompanionRefreshSteps/rollDay`` answers — whether the day advanced.
    var dayAdvanced = false

    /// What ``CompanionRefreshSteps/recompute`` answers.
    var companionStateRaw = "Okay"

    /// The snapshot ``CompanionRefreshSteps/makeSnapshot`` hands back. Defaults to one whose raw
    /// state agrees with ``companionStateRaw``, so a cell that does not care never trips the
    /// determinism check by accident.
    var snapshot: WidgetSnapshot?

    /// What ``CompanionRefreshSteps/publish`` answers.
    var publication: WidgetSnapshotPublication = .unchanged

    /// Run at the start of every step, so a cell can act from INSIDE a chosen step — the only way
    /// to place a cancellation at a specific boundary deterministically rather than by racing a
    /// yield against it.
    var beforeStep: ((CompanionRefreshStep) -> Void)?

    /// The run a cell wants cancelled from inside a step. Held here rather than captured as a local
    /// `var`, because the handle only exists AFTER the task it names has been created, and a
    /// mutable capture shared with an escaping closure is the shape Swift 6 refuses.
    var runToCancel: Task<CompanionRefreshRun, Never>?

    /// Every step that was actually called, in order. The oracle for "the handler does these
    /// things in this order, and nothing else".
    private(set) var calls: [CompanionRefreshStep] = []

    /// The snapshot the publish step was handed, so a cell can assert WHAT was published.
    private(set) var published: WidgetSnapshot?

    /// How many times the acquisition was attempted. A refresh acquires once or not at all.
    private(set) var acquisitions = 0

    /// A snapshot whose companion agrees with ``companionStateRaw``.
    ///
    /// - Returns: The snapshot ``snapshot`` defaults to.
    private func defaultSnapshot() -> WidgetSnapshot {
        WidgetSnapshot(
            companionStateRaw: companionStateRaw,
            score: 0.62,
            bottleCount: 3,
            hydrationTarget: 8,
            macroSummary: WidgetSnapshot.MacroSummary(protein: 42, carbs: 118, fat: 31),
            dateKey: "2026-09-20",
            computedAt: Date(timeIntervalSince1970: 1_780_000_123)
        )
    }

    /// A pipeline over this fake.
    ///
    /// - Returns: The pipeline the cells run.
    func pipeline() -> CompanionRefreshPipeline {
        CompanionRefreshPipeline(acquire: { [self] in
            acquisitions += 1
            beforeStep?(.acquire)
            if let acquisitionError { throw acquisitionError }
            calls.append(.acquire)
            return steps()
        })
    }

    /// The eight recording steps.
    ///
    /// - Returns: The steps the pipeline drives.
    private func steps() -> CompanionRefreshSteps {
        CompanionRefreshSteps(
            hasUndrainedWidgetActions: { [self] in
                beforeStep?(.inspectWidgetQueue)
                calls.append(.inspectWidgetQueue)
                return widgetActionsPending
            },
            publishedSnapshotIsForCurrentDay: { [self] in publishedSnapshotIsForCurrentDay },
            scoringContextIsComplete: { [self] in
                beforeStep?(.inspectScoringContext)
                calls.append(.inspectScoringContext)
                return scoringContextIsComplete
            },
            publishedSnapshot: { [self] in
                calls.contains(.rollDay) ? publishedSnapshotAfterRoll : publishedSnapshotBeforeRoll
            },
            rollDay: { [self] in
                beforeStep?(.rollDay)
                calls.append(.rollDay)
                return dayAdvanced
            },
            recompute: { [self] in
                beforeStep?(.recompute)
                calls.append(.recompute)
                return companionStateRaw
            },
            makeSnapshot: { [self] in snapshot ?? defaultSnapshot() },
            publish: { [self] value in
                beforeStep?(.publish)
                calls.append(.publish)
                published = value
                return publication
            }
        )
    }
}

// MARK: - The suite

/// §17.2's handler as a pipeline over values, plus the acquire path's cold-wake repair.
@MainActor
struct CompanionRefreshPipelineTests {

    /// A registered coordinator over a fake scheduler, running `pipeline`.
    ///
    /// - Parameter pipeline: The pipeline to run.
    /// - Returns: The coordinator and its fake scheduler.
    private func registeredCoordinator(
        pipeline: CompanionRefreshPipeline
    ) -> (CompanionRefreshCoordinator, FakeCompanionRefreshScheduler) {
        let scheduler = FakeCompanionRefreshScheduler()
        let subject = CompanionRefreshCoordinator(
            scheduler: scheduler,
            now: { Date(timeIntervalSince1970: 1_750_000_000) },
            pipeline: pipeline
        )
        subject.registerAtLaunch()
        return (subject, scheduler)
    }

    // MARK: - The order

    /// **The ordinary interesting refresh**: every step, in §17.2's order, ending in a reload.
    ///
    /// The trace is asserted WHOLE rather than step by step, because the order is half of what item
    /// 4 is: a publish that ran before the day roll would publish yesterday's numbers under today's
    /// key, and a set of per-step booleans cannot tell that story.
    @Test func everyStepRunsInOrderAndAContentChangeReloads() async {
        let fake = FakeCompanionRefreshSteps()
        fake.publication = .reloaded
        fake.dayAdvanced = true

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .inspectScoringContext, .rollDay, .recompute, .publish, .reload],
                "acquire → check the queue → roll → recompute → publish → reload, and nothing else")
        #expect(fake.calls == [.acquire, .inspectWidgetQueue, .inspectScoringContext, .rollDay, .recompute, .publish],
                "the steps the pipeline actually CALLED — `reload` is reported by the publish, never called")
        #expect(run.outcome == .reloaded)
        #expect(run.outcome.completesSuccessfully)
        #expect(run.dayAdvanced, "the roll's own answer is carried out, not re-derived")
        #expect(run.companionStateRaw == "Okay")
        #expect(fake.acquisitions == 1, "a refresh acquires once")
        #expect(fake.published?.companionStateRaw == "Okay", "and it published the snapshot it built")
    }

    /// **The ordinary DULL refresh**: everything ran, nothing changed, nothing reloaded — and the
    /// system is still told the task succeeded.
    ///
    /// This is the outcome §17.2's diff exists to produce, and the `true` is the load-bearing half:
    /// reporting `false` for a refresh that correctly found nothing to do would teach the scheduler
    /// to stop granting the refreshes that are working.
    @Test func unchangedContentReloadsNothingAndStillSucceeds() async {
        let fake = FakeCompanionRefreshSteps()
        fake.publication = .unchanged

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .inspectScoringContext, .rollDay, .recompute, .publish],
                "no `reload` in the trace — that is the whole claim")
        #expect(run.outcome == .unchanged)
        #expect(run.outcome.completesSuccessfully, "a refresh that found nothing to do finished on the app's terms")
    }

    /// A failed app-group write is not a reload by another name.
    @Test func aFailedWriteEndsTheRunUnsuccessfully() async {
        let fake = FakeCompanionRefreshSteps()
        fake.publication = .writeFailed

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .inspectScoringContext, .rollDay, .recompute, .publish])
        #expect(run.outcome == .writeFailed)
        #expect(run.outcome.completesSuccessfully == false,
                "the widget is on its last good snapshot and the app could not write; that is not a success")
    }

    // MARK: - The widget queue

    /// **The undrained-actions skip** (decision D-10.4.2): a queued widget action ends the run
    /// after the acquisition, before anything can publish.
    ///
    /// Why so early, rather than "skip only the publish": the widget's "+1 water" App Intent has
    /// already written a PROVISIONAL bottle count into the same snapshot file, and the app has not
    /// folded that row in yet. Publishing the app's own lower count would make the water count go
    /// backwards in front of the person until the next foreground drain. The day ROLL is skipped
    /// along with the publish because on a warm process a roll publishes through the store's own
    /// internal path — a second route to the same regression, which a "skip the publish" guard
    /// placed after it could not see.
    ///
    /// §17.2 limits the handler to its listed steps, so draining here is not an option: the drain
    /// mutates the diary.
    @Test func anUndrainedWidgetActionSkipsEverythingAfterTheAcquisition() async {
        let fake = FakeCompanionRefreshSteps()
        fake.widgetActionsPending = true
        // The other half of decision D-10.4.8, said out loud rather than taken from the default:
        // the skip holds only while the snapshot it is protecting is still the one on screen.
        fake.publishedSnapshotIsForCurrentDay = true
        fake.publication = .reloaded

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue],
                "the run stops at the queue check — before the roll, not merely before the publish")
        #expect(fake.calls == [.acquire, .inspectWidgetQueue], "and it CALLED nothing else")
        #expect(run.outcome == .widgetActionsPending)
        #expect(run.outcome.completesSuccessfully, """
            deciding not to publish is a decision the handler made correctly, not a failure it \
            suffered — telling the scheduler otherwise would cost the chain refreshes for doing \
            the right thing.
            """)
        #expect(fake.published == nil, "nothing was published, which is the point")
        #expect(run.companionStateRaw == nil, "and the run never got far enough to have one")
    }

    /// **The same undrained row on a NEW day runs the whole tail** (decision D-10.4.8).
    ///
    /// The skip's cost is a widget one tap behind. Across midnight its cost is a BLANK widget: the
    /// published snapshot still carries yesterday's `dateKey`, `WidgetDayGate.snapshotReflectsDay`
    /// refuses it, and the companion stops being drawn at all. So the day boundary overrides the
    /// skip, and the outcome names what happened rather than reporting an ordinary reload.
    @Test func anUndrainedWidgetActionOnANewDayPublishesAndSaysSo() async {
        let fake = FakeCompanionRefreshSteps()
        fake.widgetActionsPending = true
        fake.publishedSnapshotIsForCurrentDay = false
        fake.publication = .reloaded

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .inspectScoringContext,
                              .rollDay, .recompute, .publish, .reload],
                "the queue check no longer ends the run: everything after it ran")
        #expect(run.outcome == .publishedDespitePendingActions, """
            not `.reloaded`: this run knowingly republished over a provisional count, and the \
            audit line for a widget whose "+1" appeared to vanish is the one worth reading.
            """)
        #expect(run.outcome.completesSuccessfully)
        #expect(fake.published != nil, "something reached the widget, which is the whole point")
    }

    // MARK: - The scoring context (decision D-10.4.6)

    /// **A missing scoring bridge ends the run between the queue check and the roll.**
    ///
    /// Placed there for two reasons: the roll PUBLISHES on its own through a warm store's mirror,
    /// so a refusal after it would reach the widget by a route this decision cannot see; and the
    /// roll is the first step that writes anything, so refusing before it leaves the process
    /// exactly as it found it.
    @Test func aMissingScoringBridgeEndsTheRunBeforeAnythingIsRolledOrPublished() async {
        let fake = FakeCompanionRefreshSteps()
        fake.scoringContextIsComplete = false
        fake.publication = .reloaded

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .inspectScoringContext],
                "the run stops at the scoring check — after the queue, before the roll")
        #expect(fake.calls == [.acquire, .inspectWidgetQueue, .inspectScoringContext],
                "and it CALLED nothing else")
        #expect(run.outcome == .scoringContextUnavailable)
        #expect(run.outcome.completesSuccessfully, """
            refusing to publish a score the app itself disagrees with is the handler working; a \
            `false` would cost the chain the very refreshes that start succeeding the moment a \
            foreground attaches the bridges.
            """)
        #expect(fake.published == nil)
        #expect(run.companionStateRaw == nil, "it never recomputed the score it refused to publish")
    }

    // MARK: - The day roll's own publish

    /// **A roll that republished through the store is recorded as the reload it was.**
    ///
    /// `refreshCurrentDayIfNeeded()` publishes through the store's own mirror when it advances, and
    /// on a warm process that write lands BEFORE the handler's diff reads the previous value — so
    /// the diff sees nothing to change. Reading the file either side of the roll is what keeps
    /// `dayAdvanced` from coexisting with an empty reload column, and keeps the busiest refresh of
    /// the day from being reported as the dullest.
    @Test func aRollThatRepublishedThroughTheStoreIsRecordedAsAReload() async {
        let fake = FakeCompanionRefreshSteps()
        fake.dayAdvanced = true
        fake.publishedSnapshotBeforeRoll = Self.snapshot(dateKey: "2026-09-20")
        fake.publishedSnapshotAfterRoll = Self.snapshot(dateKey: "2026-09-21")
        fake.publication = .unchanged

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .inspectScoringContext,
                              .rollDay, .reload, .recompute, .publish],
                "the reload is recorded where it happened — straight after the roll, not after the publish")
        #expect(run.dayAdvanced)
        #expect(run.outcome == .reloaded, "the widget WAS reloaded; `unchanged` would be a lie about it")
    }

    /// …and a roll whose own app-group write failed is NOT.
    ///
    /// The half that keeps the rule above from degrading into "an advance always claims a reload".
    /// `WidgetSnapshotMirror.publish(_:)` skips the reload when the write fails, so the file is
    /// unchanged either side of the roll — and a content comparison sees that, where an assumption
    /// about what a roll does would not.
    @Test func aRollWhoseOwnWriteFailedClaimsNoReload() async {
        let fake = FakeCompanionRefreshSteps()
        fake.dayAdvanced = true
        fake.publishedSnapshotBeforeRoll = Self.snapshot(dateKey: "2026-09-20")
        fake.publishedSnapshotAfterRoll = Self.snapshot(dateKey: "2026-09-20")
        fake.publication = .unchanged

        let run = await fake.pipeline().run()

        #expect(run.steps.contains(.reload) == false, "nothing moved on disk, so nothing was reloaded")
        #expect(run.outcome == .unchanged)
    }

    /// A snapshot for a given day key, for the two cells above.
    ///
    /// - Parameter dateKey: The day the snapshot claims.
    /// - Returns: The snapshot.
    private static func snapshot(dateKey: String) -> WidgetSnapshot {
        WidgetSnapshot(
            companionStateRaw: "Okay",
            score: 0.62,
            bottleCount: 3,
            hydrationTarget: 8,
            macroSummary: WidgetSnapshot.MacroSummary(protein: 42, carbs: 118, fat: 31),
            dateKey: dateKey,
            computedAt: Date(timeIntervalSince1970: 1_780_000_123)
        )
    }

    // MARK: - The failure arms

    /// A locked device ends the run at the acquisition, unsuccessfully, having touched nothing.
    ///
    /// `ExchangeIntentServiceError.deviceLocked` is what `FernletStoreAccess.load()` throws BEFORE
    /// it opens anything when protected data is unavailable — a background wake before first
    /// unlock. The handler must not build a store to work around it (§17.2), so the honest answer
    /// is to do nothing and let the successor, already submitted, try again later.
    @Test func aLockedDeviceEndsTheRunAtTheAcquisition() async {
        let fake = FakeCompanionRefreshSteps()
        fake.acquisitionError = ExchangeIntentServiceError.deviceLocked

        let run = await fake.pipeline().run()

        #expect(run.steps.isEmpty, "nothing ran: there was no store to run it against")
        #expect(fake.calls.isEmpty)
        #expect(run.outcome == .acquisitionFailed)
        #expect(run.outcome.completesSuccessfully == false)
        #expect(fake.acquisitions == 1, "and it did not retry inside the run — the chain retries, not the handler")
    }

    /// A run cancelled before it starts acquires nothing at all.
    ///
    /// The cheapest of the two cancellation checks, and the one that matters most in production:
    /// the expiration handler can fire between the coordinator creating the run's `Task` and that
    /// task's first line, and a run that acquired a store for an expired task would be doing work
    /// on behalf of nobody.
    @Test func aCancellationBeforeTheRunStartsAcquiresNothing() async {
        let fake = FakeCompanionRefreshSteps()
        let pipeline = fake.pipeline()

        let task = Task { @MainActor in await pipeline.run() }
        task.cancel()
        let run = await task.value

        #expect(run.outcome == .cancelled)
        #expect(run.steps.isEmpty)
        #expect(fake.acquisitions == 0, "it never even asked for the store")
    }

    /// A cancellation landing DURING the acquisition stops the run before the day roll.
    ///
    /// The acquisition is the pipeline's one suspension point, and therefore the one window an
    /// expiration can interleave with. Driven from inside the step so the cancellation lands at
    /// exactly that boundary rather than whenever the scheduler feels like it.
    @Test func aCancellationDuringTheAcquisitionStopsBeforeTheDayRoll() async {
        let fake = FakeCompanionRefreshSteps()
        let pipeline = fake.pipeline()
        fake.beforeStep = { [weak fake] step in
            if step == .acquire { fake?.runToCancel?.cancel() }
        }

        let task = Task { @MainActor in await pipeline.run() }
        fake.runToCancel = task
        let run = await task.value

        #expect(run.outcome == .cancelled)
        #expect(run.steps == [.acquire], "it got the store and stopped")
        #expect(fake.calls == [.acquire], "the roll, the recompute and the publish never ran")
        #expect(fake.published == nil)
    }

    /// The outcome table says what the system is told, for every case there is.
    ///
    /// Derived from `CaseIterable` rather than listed, so a ninth outcome added later cannot be
    /// left without a stated answer — it reds here until somebody decides one.
    @Test func everyOutcomeStatesWhatTheSystemIsTold() {
        let expected: [CompanionRefreshOutcome: Bool] = [
            .reloaded: true,
            .unchanged: true,
            .widgetActionsPending: true,
            .publishedDespitePendingActions: true,
            .scoringContextUnavailable: true,
            .writeFailed: false,
            .acquisitionFailed: false,
            .cancelled: false
        ]
        #expect(Set(expected.keys) == Set(CompanionRefreshOutcome.allCases), """
            an outcome has no row in this table. `setTaskCompleted(success:)` is how iOS decides \
            whether to keep granting this app refreshes, so a new outcome is a decision about the \
            chain's future, not a new enum case.
            """)
        // R2: bounded by the case list.
        for outcome in CompanionRefreshOutcome.allCases {
            #expect(outcome.completesSuccessfully == expected[outcome],
                    "\(outcome.rawValue) tells the system the wrong thing")
        }
    }

    // MARK: - Through the coordinator

    /// Every outcome completes the delivered task exactly once, with the value it names — and the
    /// successor is submitted either way.
    ///
    /// The join between this suite and `CompanionRefreshSchedulingTests`: that one drives the frame
    /// with a no-op pipeline and owns exactly-once across every ORDER; this one drives the frame
    /// with each outcome in turn and owns the MAPPING. `.cancelled` is absent on purpose — the
    /// coordinator never asks a cancelled run what to tell the system, because the expiration door
    /// already completed the task, and that order is the other suite's `during` rows.
    @Test func eachOutcomeCompletesTheTaskWithTheValueItNames() async {
        // R2: bounded by the case list.
        for outcome in CompanionRefreshOutcome.allCases where outcome != .cancelled {
            let fake = FakeCompanionRefreshSteps()
            switch outcome {
            case .reloaded: fake.publication = .reloaded
            case .unchanged: fake.publication = .unchanged
            case .writeFailed: fake.publication = .writeFailed
            case .widgetActionsPending: fake.widgetActionsPending = true
            case .publishedDespitePendingActions:
                fake.widgetActionsPending = true
                fake.publishedSnapshotIsForCurrentDay = false
            case .scoringContextUnavailable: fake.scoringContextIsComplete = false
            case .acquisitionFailed: fake.acquisitionError = ExchangeIntentServiceError.deviceLocked
            case .cancelled: continue
            }
            let (subject, scheduler) = registeredCoordinator(pipeline: fake.pipeline())

            scheduler.deliver(FakeCompanionRefreshTaskHandle())
            await subject.pipelineRun?.value

            #expect(subject.isHoldingTask == false, "\(outcome.rawValue): the task was completed")
            #expect(scheduler.submitted.count == 1,
                    "\(outcome.rawValue): one successor, whatever the run decided")
            #expect(scheduler.submitted.first?.identifier == CompanionRefresh.taskIdentifier,
                    "\(outcome.rawValue): and it names the one permitted identifier")
        }
    }

    /// The completion VALUE each outcome produces, read off the handle rather than off the
    /// coordinator's state.
    @Test func theCompletionValueFollowsTheOutcome() async {
        let rows: [(publication: WidgetSnapshotPublication, expected: Bool)] = [
            (.reloaded, true), (.unchanged, true), (.writeFailed, false)
        ]
        // R2: bounded by the row list.
        for row in rows {
            let fake = FakeCompanionRefreshSteps()
            fake.publication = row.publication
            let (subject, scheduler) = registeredCoordinator(pipeline: fake.pipeline())
            let handle = FakeCompanionRefreshTaskHandle()

            scheduler.deliver(handle)
            await subject.pipelineRun?.value

            #expect(handle.completions == [row.expected],
                    "\(row.publication): completed once, with the value the outcome names")
        }
    }

    // MARK: - The acquire path (decision D-10.4.1)

    /// **A store built on a cold background wake takes the scene's gateway later.**
    ///
    /// `FernletStoreAccess` caches one store for the whole process and returns it whatever
    /// arguments the caller passes, so whichever caller builds it first decides whether the
    /// process's store has a HealthKit gateway. The scene passes the app's one long-lived service;
    /// every background caller — the App Intents, and now a fifteen-minute refresh — passes nil. So
    /// a background wake that wins the race left the foreground on a gateway-less store for the
    /// rest of the process, with its workout sync silently falling back to a second instance of its
    /// own.
    ///
    /// The repair is here, in the store, rather than in the handler: the handler may not speak a
    /// HealthKit spelling at all (§16.4's wall), and a repair at the acquisition covers the App
    /// Intents, which have had this defect since they were written.
    ///
    /// **Asserted through the attach door's own answer, not through a reader.** Item 4 shipped a
    /// `FernletStore.attachedHealthKitService` getter for these cells and nothing else — a
    /// production surface that HANDS OUT the HealthKit gateway to any file able to name the store,
    /// existing so a test could read back what an attach did. It is gone; what remains observable
    /// is the door's `Bool`, which is enough: an attach that did not land would let the next one
    /// through.
    @Test func aStoreBuiltWithoutAGatewayTakesOneLater() {
        let store = makeTestStore()
        let service = HealthKitService()

        #expect(store.attachHealthKitServiceIfMissing(service),
                "a test store, like a cold background wake, has no gateway — so the attach is accepted")
        #expect(store.attachHealthKitServiceIfMissing(HealthKitService()) == false,
                "and the next one is refused, which is only true because the first one LANDED")
    }

    /// A store that already has a gateway refuses a second, and keeps the one it has.
    ///
    /// The ordinary case in production: the foreground usually wins the race, and every later
    /// `load()` — including the refresh's — must leave its store alone.
    @Test func aStoreThatAlreadyHasAGatewayRefusesAnother() {
        let store = makeTestStore()
        let first = HealthKitService()
        #expect(store.attachHealthKitServiceIfMissing(first))

        let second = HealthKitService()
        #expect(store.attachHealthKitServiceIfMissing(second) == false, "the second is refused")
        #expect(store.attachHealthKitServiceIfMissing(second) == false,
                "and asking again does not wear the refusal down — a door that eventually said yes would be worse than no repair")
    }

    /// An attach arriving after the workout sync was already built is REFUSED.
    ///
    /// The guard that keeps the repair honest. Once the sync exists it holds its gateway for good —
    /// observation query included — so letting the store start answering with a different one would
    /// be a half-attach nothing could see: the store would claim the scene's service while the live
    /// sync kept its own. Driven by reaching a workout path first, which is what builds the sync.
    @Test func anAttachAfterTheWorkoutSyncWasBuiltIsRefused() async {
        let store = makeTestStore()
        await store.refreshWorkoutsFromHealth()

        #expect(store.attachHealthKitServiceIfMissing(HealthKitService()) == false,
                "too late: the sync already has a gateway, and this store must not claim a different one")
    }

    // MARK: - The production bindings, over a real store

    /// **The eight bindings run the real store's steps, in order, and publish.**
    ///
    /// `CompanionRefreshWiring.steps(for:)` is what production runs; everything above this section
    /// proves the pipeline's logic over fakes, and would be equally green if `rollDay` were bound
    /// to something that did not roll the day. This runs the actual expressions.
    ///
    /// The publication is `.reloaded` because the store's app-group directory is unique per test
    /// store, so there is no previous snapshot — and "no previous snapshot is a change" is the
    /// mirror's own rule.
    @Test func theProductionBindingsRunTheRealStoresStepsAndPublish() async {
        let store = makeTestStore()
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

        let run = await pipeline.run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .inspectScoringContext, .rollDay, .recompute, .publish, .reload])
        #expect(run.outcome == .reloaded)
        #expect(run.dayAdvanced == false, "a store built moments ago is already on today's key")
        #expect(run.companionStateRaw == store.companionState.rawValue,
                "the recompute binding reads the store's own computed companion, not a copy of the rule")

        let published = store.ensureWidgetSnapshotMirror().currentSnapshot()
        #expect(published?.dateKey == store.todayKey, "and the snapshot on disk is the store's own day")
        #expect(published?.companionStateRaw == store.companionState.rawValue)
        #expect(published?.bottleCount == store.day.bottleCount)
    }

    /// A second run over an unchanged store publishes without reloading.
    ///
    /// The dull refresh, end to end through the real bindings: the store did not change, the
    /// snapshot's stamp did, and the diff is what tells those apart.
    @Test func aSecondProductionRunOverAnUnchangedStoreDoesNotReload() async {
        let store = makeTestStore()
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })
        _ = await pipeline.run()

        let second = await pipeline.run()

        #expect(second.outcome == .unchanged, "nothing about the store moved between the two runs")
        #expect(second.steps.contains(.reload) == false, "so nothing poked WidgetKit")
    }

    /// The bindings skip the publish while a widget action is undrained — over the real queue.
    ///
    /// The queue read is the production one (`records()`, which claims nothing), so this also pins
    /// that asking does not consume the row: it is still there afterwards for the foreground drain
    /// that owes it.
    @Test func theProductionBindingsSkipThePublishWhileAnActionIsUndrained() async {
        let store = makeTestStore()
        // The widget's own "+1" App Intent writes its provisional count INTO this file, so a
        // pending row with no published snapshot at all is a state production cannot reach — and
        // it is the state decision D-10.4.8 answers the other way. Publish TODAY's snapshot first,
        // which is what the skip exists to leave standing.
        store.ensureWidgetSnapshotMirror().publish(store.currentWidgetSnapshot())
        // Read the file back rather than keeping the value that was written: the encoder's ISO-8601
        // dates are second-resolution, so a `computedAt` that survived a round trip and one that
        // did not are unequal even between two reads of the same bytes.
        let standing = store.ensureWidgetSnapshotMirror().currentSnapshot()
        #expect(standing != nil, "the snapshot the skip exists to leave standing is on disk")
        let queued = PendingWidgetAction(
            id: UUID(), dateKey: store.todayKey,
            action: PendingWidgetAction.waterPlusOne, createdAt: Date())
        #expect(store.pendingWidgetActionQueue.append(queued), "the row is durably queued")
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

        let run = await pipeline.run()

        #expect(run.outcome == .widgetActionsPending)
        #expect(run.steps == [.acquire, .inspectWidgetQueue])
        #expect(store.ensureWidgetSnapshotMirror().currentSnapshot() == standing, """
            the file was not rewritten — whole-value, so a republish that changed nothing but the \
            stamp would still be caught — and the widget's own optimistic count still stands
            """)
        #expect(store.pendingWidgetActionQueue.records().map(\.id) == [queued.id],
                "and the row is still queued — the handler READ the queue, it did not claim it")
    }

    // MARK: - The scoring context (decision D-10.4.6)

    /// **An adjustment switched on without its bridge refuses the publish.**
    ///
    /// `FernletStore.periodAdjustment(for:)` and `stressModifier(for:)` both return the IDENTITY
    /// when their bridge is nil, and both bridges are attached in one place only —
    /// `ContentView`'s store-ready wiring. A cold `BGAppRefreshTask` wake runs no scene, so on such
    /// a wake `score` is the app's number MINUS whatever those two would have moved it by. The
    /// widget would then carry a companion the app itself disagrees with until the next foreground
    /// publish flipped it back, which is a wrong widget rather than merely a stale one.
    ///
    /// A test store is a cold wake in this respect: it has no bridges either.
    @Test func eitherAdjustmentSwitchedOnWithoutItsBridgeRefusesThePublish() async {
        // R2: bounded by the literal list.
        for adjustment in ["period", "stress"] {
            let store = makeTestStore()
            if adjustment == "period" {
                store.setPeriodAwareScoringEnabled(true)
            } else {
                store.setStressAwarenessEnabled(true)
            }
            let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

            let run = await pipeline.run()

            #expect(run.steps.contains(.publish) == false,
                    "\(adjustment): the run must end before it can publish a lower-fidelity score")
            #expect(run.steps.contains(.rollDay) == false,
                    "\(adjustment): and before the roll, whose own publish would reach the widget by a second route")
            #expect(run.outcome == .scoringContextUnavailable, "\(adjustment): and it says which refusal this was")
            #expect(run.companionStateRaw == nil,
                    "\(adjustment): it never got as far as a recompute worth reporting")
            #expect(store.ensureWidgetSnapshotMirror().currentSnapshot() == nil,
                    "\(adjustment): nothing reached the widget, which is the whole claim")
        }
    }

    /// **Both opt-ins off: the identity IS the app's number, so the run publishes.**
    ///
    /// The common case — both adjustments are opt-in and off by default — and the half that keeps
    /// the refusal above from being "the background never publishes".
    @Test func bothAdjustmentsOffPublishesBecauseTheIdentityIsTheAppsOwnScore() async {
        let store = makeTestStore()
        #expect(store.settings.periodAwareScoringEnabled == false, "off by default")
        #expect(store.settings.stressAwarenessEnabled == false, "off by default")
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

        let run = await pipeline.run()

        #expect(run.steps.contains(.publish), "nothing is missing, so nothing is refused")
        #expect(run.outcome == .reloaded, "an ordinary first publish over an empty app-group directory")
        #expect(run.companionStateRaw == store.companionState.rawValue)
        #expect(store.ensureWidgetSnapshotMirror().currentSnapshot()?.companionStateRaw
                == store.companionState.rawValue)
    }

    // MARK: - The day roll's own reload

    /// **`dayAdvanced` implies a reload in the trace — including when the STORE caused it.**
    ///
    /// The invariant `CompanionRefreshRun.dayAdvanced` exists to support: a day that advanced is
    /// the one case where the snapshot's `dateKey` is guaranteed to differ, so an advance with no
    /// reload recorded is a defect the acceptance battery can name.
    ///
    /// It is not free. `refreshCurrentDayIfNeeded()` publishes through the store's OWN mirror on an
    /// advance, and on a warm process — one that already has a mirror, which is what
    /// `publish(_:)` below installs — that write lands before the handler's diff can read the
    /// previous value. The diff then sees no change, reports `unchanged`, and the run ends with
    /// `dayAdvanced` true and no reload in its trace, on the single most consequential refresh of
    /// the day. Reading the file either side of the roll is what lets the trace name that reload.
    @Test func aDayRollThatRepublishedThroughTheStoreStillNamesItsReload() async {
        let store = makeTestStore(date: Date().addingTimeInterval(-24 * 60 * 60))
        // A WARM process: the scene ran, so the mirror exists and the store's own roll publishes.
        store.ensureWidgetSnapshotMirror().publish(store.currentWidgetSnapshot())
        #expect(store.ensureWidgetSnapshotMirror().currentSnapshot()?.dateKey == store.todayKey,
                "the widget is on yesterday's key, which is what the roll is about to change")
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

        let run = await pipeline.run()

        #expect(run.dayAdvanced, "the store was built on yesterday's key, so the roll crosses midnight")
        #expect(run.steps.contains(.reload), """
            `dayAdvanced` with no reload in the trace is the combination the acceptance battery \
            calls a defect — and it is exactly what a warm midnight roll produced, because the \
            store's own publish satisfied the diff before the diff could run.
            """)
        #expect(run.outcome == .reloaded,
                "the widget WAS reloaded, so calling this refresh a dull one would be a lie about the busiest one")
    }

    // MARK: - The queue skip across midnight (decision D-10.4.8)

    /// **One undrained row must not blank the widget at midnight.**
    ///
    /// The skip protects the widget's own optimistic water count from being republished over by
    /// the app's lower one. Across a day boundary it protects nothing: the provisional bump belongs
    /// to a day that has ended, and a snapshot left on yesterday's `dateKey` fails
    /// `WidgetDayGate.snapshotReflectsDay` — the widget stops drawing the companion at all until
    /// the next foreground. A widget one tap behind beats a blank one, so the skip yields to a new
    /// day.
    @Test func aPendingWidgetActionAcrossMidnightPublishesRatherThanBlankingTheWidget() async {
        let store = makeTestStore(date: Date().addingTimeInterval(-24 * 60 * 60))
        let yesterdayKey = store.todayKey
        store.ensureWidgetSnapshotMirror().publish(store.currentWidgetSnapshot())
        let queued = PendingWidgetAction(
            id: UUID(), dateKey: yesterdayKey,
            action: PendingWidgetAction.waterPlusOne, createdAt: Date())
        #expect(store.pendingWidgetActionQueue.append(queued), "the row is durably queued")
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

        let run = await pipeline.run()

        #expect(run.steps.contains(.publish),
                "the skip must not outlive the day whose count it was protecting")
        #expect(run.outcome == .publishedDespitePendingActions,
                "and the run says it republished over a provisional count rather than calling it an ordinary reload")
        #expect(store.ensureWidgetSnapshotMirror().currentSnapshot()?.dateKey
                == FernletDate.dayKey(for: Date()),
                "the widget is on TODAY's key — the alternative is a companion that stops being drawn")
        #expect(store.pendingWidgetActionQueue.records().map(\.id) == [queued.id],
                "and the row is still queued for the foreground drain that owes it yesterday's bump")
    }
}
