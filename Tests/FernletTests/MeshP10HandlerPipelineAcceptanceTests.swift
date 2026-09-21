// MeshP10HandlerPipelineAcceptanceTests.swift
// FernletTests
//
// Network migration **P10's acceptance battery, clause (2)** (plan §17.2, launcher item 9): the
// refresh HANDLER — §17.2's steps, in §17.2's order, over values, and joined to the task the
// system is waiting on.
//
// **The order is half of what item 4 is.** A publish that ran before the day roll would publish
// yesterday's numbers under today's key, and a set of per-step booleans cannot tell that story — so
// the trace is asserted WHOLE, against the step enum's own `allCases`. That pairing is this suite's
// and not the unit suite's: `CompanionRefreshPipelineTests` pins the trace as a LITERAL, which
// stays green if two cases are reordered in the declaration, because the pipeline appends in code
// order rather than in `CaseIterable` order. The enum is the vocabulary every trace is written in,
// so "the declaration order and the execution order agree" is a claim somebody has to make.
//
// **Values over source text.** `CompanionRefreshStep`, `CompanionRefreshOutcome` and
// `CompanionRefreshRun` all reach this file through `@testable import Fernlet`, so every claim below
// is a value: the case list, the trace, the outcome, what the system is told, and the answer the
// store's own attach door gives. Nothing here greps a source file.
//
// **What this battery does not duplicate.** `CompanionRefreshPipelineTests` owns the detail — the
// `CaseIterable`-derived completion table, every refusal over fakes, the two cancellation
// boundaries, and the eight production bindings. `CompanionRefreshSchedulingTests` owns the frame:
// exactly-once across every order, over a no-op pipeline. Neither owns the JOIN, and each cell
// below is one: a refusal carried out to what `setTaskCompleted(success:)` was told AND to whether
// the chain still has a successor; both arms of the widget-queue decision in one breath; an
// expiration placed inside the run; and a refresh that leaves the cold-wake repair unspent.
//
// It reuses `FakeCompanionRefreshSteps` and `CompanionRefreshSchedulingTests`' two fakes rather
// than declaring more; a second fake over one seam is a second thing to keep in step with it.
//
// No `FernletAuditLog` capture: the registry is process-global and this battery asserts values.

import Foundation
import HealthKitGateway
import Testing
@testable import Fernlet

/// **Clause (2): the handler pipeline.** The step order whole, the acquire refusal, the scoring
/// refusal, both arms of the widget queue, an expiration landing inside the run, and a refresh that
/// does not spend the cold-wake gateway repair.
@MainActor
@Suite(.serialized)
struct MeshP10HandlerPipelineAcceptanceTests {

    /// §17.2's order, as the enum declares it and as a run walks it.
    ///
    /// Spelled once here and read by two cells, so the specification's order has a single home in
    /// this file rather than two that could be edited apart. Seven steps since item 4's verify
    /// fixes: `inspectScoringContext` sits third, between the widget queue and the day roll, which
    /// is the only place a refusal can stand before anything has been rolled or published.
    private static let specifiedOrder: [CompanionRefreshStep] = [
        .acquire, .inspectWidgetQueue, .inspectScoringContext, .rollDay, .recompute, .publish, .reload
    ]

    /// **The step order is the specification's, the enum agrees with it, and the trace records it
    /// whole.**
    ///
    /// Three independent halves. `allCases` is the DECLARATION order — a case inserted or moved
    /// there renumbers nothing and breaks no build, but it changes what "in order" means to every
    /// reader of every trace. The run is the BEHAVIOUR. And the raw values are what the audit line
    /// `companionRefresh.runFinished` actually carries off a device, which is the only form of this
    /// trace anybody will ever read on a phone.
    ///
    /// `reload` is the odd one out and is asserted as such: it is not a step the pipeline calls but
    /// one a publication REPORTS, which is why the fake's call list is exactly one shorter than the
    /// trace. Since item 4's verify fixes a day roll can report it too — with both of the fake's
    /// published snapshots left nil the roll republishes nothing, so this run carries the one
    /// reload the publish reported and the trace is `allCases` exactly.
    @Test func theStepOrderIsTheSpecificationsAndTheTraceRecordsItWhole() async {
        #expect(CompanionRefreshStep.allCases == Self.specifiedOrder, """
            the step vocabulary changed. §17.2 names acquire → check the queue → check the scoring \
            context → roll the day → recompute → publish → reload; a case added, removed or moved \
            here silently redefines what every trace in this battery means
            """)
        #expect(CompanionRefreshStep.allCases.map(\.rawValue)
                == ["acquire", "inspectWidgetQueue", "inspectScoringContext",
                    "rollDay", "recompute", "publish", "reload"],
                "and the raw values `companionRefresh.runFinished` carries are those, spelled out")

        let fake = FakeCompanionRefreshSteps()
        fake.publication = .reloaded
        fake.dayAdvanced = true

        let run = await fake.pipeline().run()

        #expect(run.steps == CompanionRefreshStep.allCases, """
            the ordinary interesting refresh walks the enum's own order, whole. Asserted against \
            `allCases` rather than against a literal, so a reordered declaration reds here
            """)
        #expect(fake.calls == CompanionRefreshStep.allCases.filter { $0 != .reload },
                "`reload` is reported by a publication, never called — the trace and the calls differ by it")
        #expect(run.outcome == .reloaded)
        #expect(run.outcome.completesSuccessfully, "and the system is told the task succeeded")
        #expect(run.dayAdvanced, "the roll's own answer is carried out rather than re-derived")
        #expect(fake.acquisitions == 1, "a refresh acquires once")
    }

    /// **A locked device refuses the acquisition, runs nothing, and the task is still completed —
    /// with `false`, and with the successor already standing.**
    ///
    /// `ExchangeIntentServiceError.deviceLocked` is thrown by `FernletStoreAccess.load()` BEFORE it
    /// opens anything, when protected data is unavailable — a background wake before first unlock.
    /// §17.2 forbids building a store to work around it, so the honest answer is to do nothing and
    /// let the successor, already submitted, try again later.
    ///
    /// The join: `CompanionRefreshPipelineTests.eachOutcomeCompletesTheTaskWithTheValueItNames`
    /// proves the task is no longer held and a successor exists for every outcome, and
    /// `theCompletionValueFollowsTheOutcome` proves the VALUE for the three publication arms only.
    /// A refusal that completed the task `true` would pass both of those and is exactly the failure
    /// that teaches iOS the refresh is fine when it did nothing at all.
    @Test func theAcquireRefusalUnderADeviceLockEndsTheRunAndStillCompletesTheTask() async {
        let fake = FakeCompanionRefreshSteps()
        fake.acquisitionError = ExchangeIntentServiceError.deviceLocked
        let (subject, scheduler) = MeshP10Acceptance.registeredCoordinator(pipeline: fake.pipeline())
        let handle = FakeCompanionRefreshTaskHandle()

        scheduler.deliver(handle)
        await subject.pipelineRun?.value

        #expect(fake.calls.isEmpty, "nothing ran: there was no store to run it against")
        #expect(fake.acquisitions == 1, "and it did not retry inside the run — the chain retries, not the handler")
        #expect(handle.completions == [false], """
            the task is still completed, exactly once, and told the truth. A handler that returned \
            without completing would cost the app the refreshes it is asking for; one that reported \
            success would be lying about a refresh that never opened a store
            """)
        #expect(scheduler.submitted.count == 1, "and the successor was already asked for, before the run")
        #expect(subject.isHoldingTask == false, "nothing is still owed to the system")
    }

    /// **A missing scoring bridge publishes nothing and still tells the system the task
    /// SUCCEEDED** — over a real store, through the coordinator.
    ///
    /// Decision D-10.4.6, carried to its join. `periodAdjustment(for:)` and `stressModifier(for:)`
    /// both return the IDENTITY when their bridge is nil, and both bridges are attached in one
    /// place only: `ContentView`'s store-ready wiring. A process woken COLD by `BGAppRefreshTask`
    /// runs no scene, so on such a wake `score` is the app's number minus whatever those two would
    /// have moved it by — a WRONG widget rather than a stale one.
    ///
    /// The refusal is a decision the handler made correctly, not a failure it suffered, so the
    /// completion value is `true`: reporting a failure here would teach the scheduler to stop
    /// granting the refreshes that are behaving. The unit suite proves the refusal over a store
    /// with no coordinator, and the outcome table proves the mapping over a coordinator with no
    /// store; this is the one place a real store's refusal reaches a real handle.
    @Test func aMissingScoringBridgePublishesNothingAndStillReportsSuccess() async {
        let store = makeTestStore()
        store.setStressAwarenessEnabled(true)
        #expect(store.hasCompleteScoringContext == false,
                "an adjustment is on and its bridge is nil — a cold wake's store, exactly")
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })
        let (subject, scheduler) = MeshP10Acceptance.registeredCoordinator(pipeline: pipeline)
        let handle = FakeCompanionRefreshTaskHandle()

        scheduler.deliver(handle)
        await subject.pipelineRun?.value

        #expect(store.ensureWidgetSnapshotMirror().currentSnapshot() == nil, """
            nothing reached the widget, which is the whole claim: a lower-fidelity score published \
            here would sit on the widget contradicting the app until a foreground run flipped it back
            """)
        #expect(handle.completions == [true], """
            …and the system was told the task SUCCEEDED, exactly once. The handler decided not to \
            publish; it did not fail to
            """)
        #expect(scheduler.submitted.count == 1, "and the chain keeps its successor, so a later wake can do better")
    }

    /// **Both arms of the widget-queue decision, and both tell the system it succeeded.**
    ///
    /// Decisions D-10.4.2 and D-10.4.8, which only make sense as a pair. The widget's "+1" App
    /// Intent writes a provisional count into the same app-group file the handler publishes to, so
    /// republishing the app's own lower count makes the number visibly go backwards — the handler
    /// skips. But across MIDNIGHT that same skip would leave the widget rendering yesterday's
    /// companion all day, which is worse than the count it was protecting, so the run continues and
    /// says so in its outcome.
    ///
    /// One cell rather than two, because the claim is the SPLIT: the same pending row, the same
    /// handler, two answers decided by one question — is the snapshot on disk still today's? Both
    /// arms report success, which is the half that keeps either from being a failure the scheduler
    /// learns from.
    @Test func theWidgetQueueSkipsOnTodaysSnapshotAndRunsAnywayAcrossMidnight() async {
        let sameDay = FakeCompanionRefreshSteps()
        sameDay.widgetActionsPending = true
        sameDay.publishedSnapshotIsForCurrentDay = true
        sameDay.publication = .reloaded

        let skipped = await sameDay.pipeline().run()

        #expect(skipped.steps == [.acquire, .inspectWidgetQueue], """
            the queue is asked FIRST, before the roll — a roll that happened and then skipped the \
            publish would leave the warm-process path to republish the lower count anyway
            """)
        #expect(sameDay.published == nil, "nothing was published, which is the point")
        #expect(skipped.outcome == .widgetActionsPending)

        let newDay = FakeCompanionRefreshSteps()
        newDay.widgetActionsPending = true
        newDay.publishedSnapshotIsForCurrentDay = false
        newDay.publication = .reloaded

        let ran = await newDay.pipeline().run()

        #expect(ran.steps == CompanionRefreshStep.allCases, """
            across the day boundary the same pending row runs the whole tail: a widget left on \
            yesterday's companion all day is a worse wrong than the optimistic count being redrawn
            """)
        #expect(newDay.published != nil, "something reached the widget, which is D-10.4.8's whole point")
        #expect(ran.outcome == .publishedDespitePendingActions, "…and the outcome names which arm this was")
        #expect(skipped.outcome.completesSuccessfully && ran.outcome.completesSuccessfully, """
            both arms tell the system the task SUCCEEDED. Reporting a failure on either would teach \
            the scheduler to stop granting the very refreshes that are deciding correctly
            """)
    }

    /// **An expiration landing inside the run completes the task once and leaves the successor
    /// standing.**
    ///
    /// The window item 4 created: the pipeline SUSPENDS at its acquisition, so for the first time a
    /// grant can run out mid-run. Two guards answer it and both are needed — the expiration door
    /// cancels the run BEFORE it completes the task, and a run that finishes anyway may complete
    /// only the handle it was started for, and only while that handle is still held.
    ///
    /// Driven from INSIDE the acquisition step rather than by racing a yield against it, which is
    /// the only way to place the expiration at exactly that boundary deterministically. This is the
    /// join `CompanionRefreshSchedulingTests` (orders, over a no-op pipeline) and
    /// `CompanionRefreshPipelineTests` (cancellation, over no coordinator) each own half of.
    @Test func anExpirationInsideTheRunCompletesOnceAndLeavesTheSuccessorStanding() async {
        let fake = FakeCompanionRefreshSteps()
        let (subject, scheduler) = MeshP10Acceptance.registeredCoordinator(pipeline: fake.pipeline())
        fake.beforeStep = { [weak subject] step in
            if step == .acquire { subject?.taskDidExpire() }
        }
        let handle = FakeCompanionRefreshTaskHandle()

        scheduler.deliver(handle)
        await subject.pipelineRun?.value

        #expect(handle.completions == [false], """
            exactly one completion, from the expiration door. The run returned afterwards and was \
            REFUSED — it no longer held the task it was started for — and a second \
            `setTaskCompleted(success:)` is the bug the whole guard exists to prevent
            """)
        #expect(fake.calls == [.acquire], "the queue, the roll, the recompute and the publish never ran")
        #expect(fake.published == nil, "and nothing was published on behalf of a task that was over")
        #expect(subject.isHoldingTask == false, "the handle was dropped before it was completed")
        #expect(scheduler.submitted.count == 1, """
            …and the chain survives the expiry: the successor was asked for at adoption, before the \
            pipeline started, which is the whole reason for that ordering
            """)
    }

    /// **A whole refresh over a gateway-less store leaves the cold-wake repair unspent.**
    ///
    /// Decision D-10.4.1, asserted as a consequence rather than as a unit. `FernletStoreAccess`
    /// caches ONE store per process and returns it whatever arguments a later caller passes, so
    /// whichever caller builds it first decides whether the process has a HealthKit gateway. The
    /// scene passes the app's long-lived service; every background caller — the App Intents, and
    /// now a fifteen-minute refresh — passes nil. The repair is a one-shot door: the store takes a
    /// gateway if it has none AND has not already built its workout sync around one.
    ///
    /// Which makes the acceptance claim a BEHAVIOURAL restatement of §16.4's wall. That wall proves
    /// the handler names no HealthKit spelling; this proves the handler's actual run touches no
    /// path that would build the workout sync — because if it did, the door would be shut and the
    /// scene arriving a moment later would be refused, leaving the foreground on a store whose sync
    /// holds a second gateway of its own. The unit suite's three attach cells drive the door
    /// directly; none of them runs a refresh first.
    @Test func aWholeRefreshLeavesTheColdWakeGatewayRepairUnspent() async {
        let store = makeTestStore()
        let pipeline = CompanionRefreshPipeline(acquire: { CompanionRefreshWiring.steps(for: store) })

        let run = await pipeline.run()

        #expect(run.outcome == .reloaded, "the refresh ran to the end over a store with no gateway at all")
        #expect(store.attachHealthKitServiceIfMissing(HealthKitService()), """
            the scene's gateway is still accepted AFTER a whole refresh. A handler that had reached \
            any workout path would have built the sync and shut this door, and nothing would say so \
            — the store would simply keep answering with a gateway the live sync does not hold
            """)
        #expect(store.attachHealthKitServiceIfMissing(HealthKitService()) == false, """
            …and the door is one-way: a second attach is refused rather than swapping a live gateway \
            out from under the sync, which is worse than never repairing it
            """)
    }
}
