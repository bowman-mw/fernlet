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
// `CompanionRefreshPipeline` takes its five post-acquisition steps as closures, so most cells below
// assert an ORDER and a DECISION over counters.
//
// **The bindings are exercised too, and that is deliberate.** A pipeline of fakes proves the
// handler's logic and nothing about whether `rollDay` really rolls the day. So the last section
// runs `CompanionRefreshWiring.steps(for:)` — the five production expressions, byte for byte —
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
/// One object rather than five loose closures so a cell reads as a scenario: what the steps ANSWER
/// is set up front, what they were ASKED is read afterwards, and the two never interleave in the
/// cell's own text.
@MainActor
final class FakeCompanionRefreshSteps {

    /// Set to make ``pipeline()``'s acquisition throw instead of returning steps.
    var acquisitionError: Error?

    /// What ``CompanionRefreshSteps/hasUndrainedWidgetActions`` answers.
    var widgetActionsPending = false

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

    /// The five recording steps.
    ///
    /// - Returns: The steps the pipeline drives.
    private func steps() -> CompanionRefreshSteps {
        CompanionRefreshSteps(
            hasUndrainedWidgetActions: { [self] in
                beforeStep?(.inspectWidgetQueue)
                calls.append(.inspectWidgetQueue)
                return widgetActionsPending
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

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .rollDay, .recompute, .publish, .reload],
                "acquire → check the queue → roll → recompute → publish → reload, and nothing else")
        #expect(fake.calls == [.acquire, .inspectWidgetQueue, .rollDay, .recompute, .publish],
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

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .rollDay, .recompute, .publish],
                "no `reload` in the trace — that is the whole claim")
        #expect(run.outcome == .unchanged)
        #expect(run.outcome.completesSuccessfully, "a refresh that found nothing to do finished on the app's terms")
    }

    /// A failed app-group write is not a reload by another name.
    @Test func aFailedWriteEndsTheRunUnsuccessfully() async {
        let fake = FakeCompanionRefreshSteps()
        fake.publication = .writeFailed

        let run = await fake.pipeline().run()

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .rollDay, .recompute, .publish])
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
    /// Derived from `CaseIterable` rather than listed, so a seventh outcome added later cannot be
    /// left without a stated answer — it reds here until somebody decides one.
    @Test func everyOutcomeStatesWhatTheSystemIsTold() {
        let expected: [CompanionRefreshOutcome: Bool] = [
            .reloaded: true,
            .unchanged: true,
            .widgetActionsPending: true,
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
    @Test func aStoreBuiltWithoutAGatewayTakesOneLater() {
        let store = makeTestStore()
        #expect(store.attachedHealthKitService == nil, "a test store, like a cold background wake, has none")

        let service = HealthKitService()
        #expect(store.attachHealthKitServiceIfMissing(service), "the attach is accepted")
        #expect(store.attachedHealthKitService as? HealthKitService === service,
                "and it is THAT service — identity, not merely non-nil, because the defect is a second instance")
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
        #expect(store.attachedHealthKitService as? HealthKitService === first,
                "and the first is still the one in use — a refusal that swapped anyway would be worse than no repair")
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
        #expect(store.attachedHealthKitService == nil,
                "…and it says so rather than reporting a service its own sync is not using")
    }

    // MARK: - The production bindings, over a real store

    /// **The five bindings run the real store's steps, in order, and publish.**
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

        #expect(run.steps == [.acquire, .inspectWidgetQueue, .rollDay, .recompute, .publish, .reload])
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
        let queued = PendingWidgetAction(
            id: UUID(), dateKey: store.todayKey,
            action: PendingWidgetAction.waterPlusOne, createdAt: Date())
        #expect(store.pendingWidgetActionQueue.append(queued), "the row is durably queued")
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

        let run = await pipeline.run()

        #expect(run.outcome == .widgetActionsPending)
        #expect(run.steps == [.acquire, .inspectWidgetQueue])
        #expect(store.ensureWidgetSnapshotMirror().currentSnapshot() == nil,
                "nothing was written, so the widget's own optimistic count still stands")
        #expect(store.pendingWidgetActionQueue.records().map(\.id) == [queued.id],
                "and the row is still queued — the handler READ the queue, it did not claim it")
    }
}
