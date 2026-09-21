// MeshP10SchedulingSeamAcceptanceTests.swift
// FernletTests
//
// Network migration **P10's acceptance battery, clause (1)** (plan §17.2, §27.1, launcher item 9):
// the companion refresh's SCHEDULING SEAM, promoted to the clause level and run end to end on the
// shipping objects.
//
// **Why the name.** `CIGateSelectorBoundaryTests.isMeshBattery` matches `MeshP<digit>…AcceptanceTests`
// and three named convergence suites, and nothing else. A battery called
// `CompanionRefreshAcceptanceTests` would be DEMANDED by nothing — it would sit ungated exactly as
// P3/P4/P5's batteries did for three phases — so P10's five clause suites carry the `MeshP10` prefix
// as the WALL'S TOKEN rather than as a claim about the mesh. Nothing in this file touches a radio.
//
// **Values, not source text.** P9's own lesson, paid for in its clause (d): "a cell can pin source
// text and still not pin the shipping path". Everything assertable through `@testable import Fernlet`
// is asserted as a VALUE here — `CompanionRefresh.taskIdentifier`,
// `CompanionRefreshCoordinator.earliestBeginInterval`, `…maxEdgeSubmissionsPerLaunch`, the
// coordinator's own counters and its pending slot — and the one thing that cannot be
// (`Info.plist`'s permitted-identifier array, which iOS reads and no test links) is PARSED rather
// than grepped.
//
// **What this battery does not duplicate.** `CompanionRefreshSchedulingTests` owns the detail: the
// five-row exactly-once table, the audit line behind every refusal, the frozen mesh-protocol bodies.
// This suite owns the CLAUSE: one identifier shared by four places, one registration, an edge that
// asks only when nothing is pending, a cap that bounds the edge alone, and a chain that stays
// unbroken because every successor predates its own completion. It reuses that suite's fakes rather
// than declaring a second set — two fakes over one protocol is how a fake stops modelling it.
//
// **No audit capture anywhere in this battery.** `FernletAuditLog`'s handler registry is
// process-global and accumulates across parallel suites; items 4 and 5 kept capture out of their
// new suites for that reason, and every claim below is a value instead.
//
// `.serialized` because `CompanionRefreshCoordinator` is driven through main-actor state and the
// battery's cells share the `.noOp` pipeline.

import Foundation
import Testing
@testable import Fernlet

// MARK: - MeshP10Acceptance

/// The thin rig P10's five clause suites share: the paths they read, the five suite names the CI
/// wall must carry, and a registered coordinator over `CompanionRefreshSchedulingTests`' fakes.
///
/// A rig rather than five copies, for `MeshP9Acceptance`'s reason — and deliberately small: the
/// source walker (`MeshP7Acceptance.sources(under:)` / `homes(of:in:)`) and every fake this battery
/// drives already exist in the test target, and a sixth copy of either is what
/// `MeshContinuationRaiseWallTests` refused to write.
///
/// **No ledger path.** P8's and P9's honesty suites read their phase ledger; P10's is deliberately
/// absent here, because `Docs/Mesh-Migration-Loop-Ledger-P10.md` is not committed until the phase's
/// close-out. A cell that read it would be green in the worktree that wrote it and red in every
/// clean checkout and on CI — a battery that can only pass where it was authored. Clause (5) reads
/// the TRACKED records instead, and names that substitution out loud.
///
/// ## Concurrency
///
/// `nonisolated` values with one `@MainActor` builder; the suites that read the values are not all
/// main-actor isolated.
enum MeshP10Acceptance {

    /// The refresh directory — the one `BackgroundRefreshBoundaryTests` walks, and clause (4)'s
    /// subject.
    static let refreshRoot = "App/Fernlet/CompanionRefresh"

    /// The app target's `Info.plist`: the permitted identifier and the `fetch` background mode.
    static let plistPath = "App/Fernlet/Info.plist"

    /// The workflow that gates this battery.
    static let workflowPath = ".github/workflows/s3-wall.yml"

    /// The migration plan — §15's four device gates, §17.2's specification, §27.2's lanes.
    static let planPath = "Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md"

    /// The lane runbook — where item 8 recorded what a Simulator can and cannot show of a refresh.
    static let runbookPath = "Docs/Mesh-Network-Feasibility-Runbook.md"

    /// The tracked file catalogue — the committed home of P10's own deferred decision.
    static let fileIndexPath = "Docs/FileIndex.md"

    /// The frozen task identifier, spelled as a LITERAL.
    ///
    /// Repeated rather than read off `CompanionRefresh.taskIdentifier`: a cell that compares the
    /// app's constant to itself cannot see it drift, which is the fix item 3's verify asked for.
    static let taskIdentifier = "MBO.Fernlet.companion-refresh"

    /// The five clause suites, frozen — clause (5) asserts the workflow names every one of them.
    static let clauseSuites = [
        "MeshP10SchedulingSeamAcceptanceTests",
        "MeshP10HandlerPipelineAcceptanceTests",
        "MeshP10DiffRuleAcceptanceTests",
        "MeshP10ImportWallAcceptanceTests",
        "MeshP10HonestyAcceptanceTests"
    ]

    /// A frozen moment, so the schedule policy is assertable to the second rather than to a window.
    static let fixedNow = Date(timeIntervalSince1970: 1_750_000_000)

    /// A REGISTERED coordinator over a fake scheduler — the state in which the system may deliver.
    ///
    /// **Bind the coordinator at every call site.** The seam holds the launch handler's `self`
    /// weakly (production's owner is the `.shared` static let), so a `_` binding deallocates the
    /// subject and `deliver(_:)` then calls into nothing — a cell that counted only what the fake
    /// saw would pass over a coordinator that never ran. Item 3's apply paid for that once.
    ///
    /// - Parameters:
    ///   - pipeline: §17.2's steps; nil takes `CompanionRefreshPipeline.noOp`. Optional rather than
    ///     a default ARGUMENT, because a `@MainActor` value may not be one.
    ///   - clock: A clock the cell can move; nil freezes at ``fixedNow``.
    /// - Returns: The coordinator and its fake scheduler.
    @MainActor
    static func registeredCoordinator(
        pipeline: CompanionRefreshPipeline? = nil,
        clock: MovableCompanionRefreshClock? = nil
    ) -> (CompanionRefreshCoordinator, FakeCompanionRefreshScheduler) {
        let scheduler = FakeCompanionRefreshScheduler()
        let subject = CompanionRefreshCoordinator(
            scheduler: scheduler,
            now: { clock?.now ?? fixedNow },
            pipeline: pipeline ?? .noOp
        )
        subject.registerAtLaunch()
        return (subject, scheduler)
    }
}

// MARK: - The suite

/// **Clause (1): the scheduling seam.** One identifier in four places, one registration, an edge
/// that asks only when the system holds nothing of ours, a cap that bounds that edge and not the
/// handler's tail, and a chain whose every successor predates its own completion.
@MainActor
@Suite(.serialized)
struct MeshP10SchedulingSeamAcceptanceTests {

    /// **One literal, four places** — the app's constant, `Info.plist`'s permitted array, the
    /// import wall's own copy, and this cell.
    ///
    /// iOS matches `BGTaskSchedulerPermittedIdentifiers` LITERALLY against what the app registers,
    /// and a drift between them is an error nowhere: the registration is accepted and the task is
    /// simply never delivered, for the life of the install. The wall keeps a fourth copy because it
    /// does not link the app target, so a value read out of the thing being checked could not
    /// notice the value change — which makes this the one cell that sees all four at once.
    ///
    /// The plist is PARSED rather than grepped: iOS reads parsed values, and a malformed array is a
    /// silent non-delivery that a `contains` over the file's text would pass straight through.
    @Test func theFrozenIdentifierIsOneLiteralSharedByFourPlaces() throws {
        #expect(CompanionRefresh.taskIdentifier == "MBO.Fernlet.companion-refresh",
                "the constant the app registers is the frozen literal, pinned against the literal itself")
        #expect(BackgroundRefreshBoundaryTests.taskIdentifier == "MBO.Fernlet.companion-refresh",
                "and the import wall's fourth copy still agrees — it does not link the app target")

        let data = try Data(contentsOf: RepoRoot.url(MeshP10Acceptance.plistPath))
        let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
        let plist = try #require(parsed as? [String: Any], "the app Info.plist was not a dictionary")

        let identifiers = plist["BGTaskSchedulerPermittedIdentifiers"] as? [String] ?? []
        #expect(identifiers.contains("MBO.Fernlet.companion-refresh"), """
            the plist no longer permits the companion refresh. The registration would still be \
            accepted and the task would never be delivered again — there is no error, no audit \
            line and no observable state anywhere that says so
            """)
        #expect(identifiers.contains("MBO.Fernlet.mesh-continuation.*"),
                "and the mesh's wildcard survives: P10 ADDED an identifier, it did not replace one")

        let modes = plist["UIBackgroundModes"] as? [String] ?? []
        #expect(modes.contains("fetch"), "a `BGAppRefreshTask` is never delivered without the `fetch` mode")
        #expect(modes.contains("remote-notification"), "and the mode that was already there stays")
        #expect(!modes.contains("processing"),
                "no `BGProcessingTask` mode arrived in passing — neither task in this app is one")
    }

    /// **Registration is once per process, and nothing may be submitted without it.**
    ///
    /// `BGTaskScheduler` treats a second registration of one identifier as a programmer error, so
    /// "once" is not a preference; and an identifier the system never accepted can never deliver a
    /// task, so a refused registration closes the chain rather than degrading it. The refused arm is
    /// read as VALUES — the seam saw nothing, the coordinator counted no submission — because this
    /// battery installs no audit capture.
    @Test func registrationIsOnceAndNothingIsSubmittedWithoutIt() {
        let (subject, scheduler) = MeshP10Acceptance.registeredCoordinator()
        subject.registerAtLaunch()

        #expect(scheduler.registered == ["MBO.Fernlet.companion-refresh"],
                "one registration, for exactly the frozen identifier — compared against the literal")
        #expect(subject.didAttemptRegistration)
        #expect(subject.isRegistered)

        let refusing = FakeCompanionRefreshScheduler()
        refusing.registrationAccepted = false
        let refused = CompanionRefreshCoordinator(
            scheduler: refusing, now: { MeshP10Acceptance.fixedNow }, pipeline: .noOp)
        refused.registerAtLaunch()
        refused.appDidEnterBackground()

        #expect(refused.isRegistered == false, "the system refused, and the coordinator believes it")
        #expect(refusing.submitted.isEmpty, "so the background edge asked the seam for nothing")
        #expect(refused.submissions == 0, """
            …and no submission was counted either: the chain is closed at the registration, not \
            later at a refusal the audit trail would have to explain
            """)
        #expect(refused.pendingRequest == nil, "nothing is pending, because nothing was accepted")
    }

    /// **The background edge asks only when the system is holding nothing of ours** — so the floor
    /// does not slide fifteen minutes further out every time the person switches away.
    ///
    /// `BGTaskScheduler` REPLACES a pending request for an identifier rather than queueing another
    /// beside it. An unconditional ask on every `.background` edge is therefore not "scheduling a
    /// refresh": it re-bases the existing request on the NEW now, and somebody who opens Fernlet
    /// more often than every quarter hour would never be delivered one — with the chain's only
    /// other trigger being a delivery, it would never start at all.
    ///
    /// The clock MOVES between the edges, which is the whole point: three requests built from one
    /// frozen instant are indistinguishable from one, and "the floor slid" is unreadable without it.
    @Test func theBackgroundEdgeAsksOnceAndTheFloorDoesNotSlideWithUse() {
        #expect(CompanionRefreshCoordinator.earliestBeginInterval == 15 * 60,
                "fifteen minutes, as a value — the policy is assertable only because it is a constant")
        let clock = MovableCompanionRefreshClock(MeshP10Acceptance.fixedNow)
        let (subject, scheduler) = MeshP10Acceptance.registeredCoordinator(clock: clock)

        subject.appDidEnterBackground()
        clock.now = MeshP10Acceptance.fixedNow.addingTimeInterval(120)
        subject.appDidEnterBackground()
        clock.now = MeshP10Acceptance.fixedNow.addingTimeInterval(600)
        subject.appDidEnterBackground()

        #expect(scheduler.submitted.count == 1, """
            three switches away, ONE ask. The two later edges found the slot full and said nothing; \
            an unconditional edge would have left three requests here, each replacing the last, and \
            the delivered floor would be ten minutes later than the first ask asked for
            """)
        let expected = MeshP10Acceptance.fixedNow
            .addingTimeInterval(CompanionRefreshCoordinator.earliestBeginInterval)
        #expect(scheduler.submitted.first?.earliestBeginDate == expected,
                "and the one request still carries the FIRST edge's floor, to the second")
        #expect(subject.edgeSubmissions == 1, "one edge submission charged, not three")
        #expect(subject.pendingRequest == scheduler.submitted.first,
                "the slot holds exactly what the system accepted")
    }

    /// **The edge cap bounds the EDGE alone; the handler's tail is exempt.**
    ///
    /// A lifetime budget over both triggers is not merely wrong, it is fatal: iOS keeps a suspended
    /// process alive for days, so the sixty-fifth ask would end the chain permanently, with nothing
    /// to show for it. Every tail submission stands behind a delivery the SYSTEM chose to make, so
    /// iOS is already metering it.
    ///
    /// Driven through refusals, because with the pending-slot rule above that is the only shape an
    /// edge storm has: an accepted ask latches the slot until a delivery, and a refusal leaves it
    /// empty so the next edge asks again.
    @Test func theEdgeCapBoundsTheEdgeAloneAndTheTailIsExempt() async {
        let cap = CompanionRefreshCoordinator.maxEdgeSubmissionsPerLaunch
        #expect(cap == 64, "the R2 bound, as a value")
        let (subject, scheduler) = MeshP10Acceptance.registeredCoordinator()
        scheduler.submitRefusal = FakeCompanionRefreshRefusal()

        // R2: bounded by the coordinator's own constant.
        for _ in 0..<cap { subject.appDidEnterBackground() }
        subject.appDidEnterBackground()

        #expect(subject.edgeSubmissions == cap, "the bound is the bound: the 65th edge asked for nothing")
        #expect(subject.submissions == cap, "and every one of the 64 was a real ask through the seam")
        #expect(scheduler.submitted.isEmpty, "all refused, which is why the edge kept asking")

        scheduler.submitRefusal = nil
        let handle = FakeCompanionRefreshTaskHandle()
        scheduler.deliver(handle)
        await subject.pipelineRun?.value

        #expect(scheduler.submitted.count == 1, """
            the tail asked although the edge budget is spent for the life of this process. A tail \
            drawn from that budget would have found it empty and the chain would be over
            """)
        #expect(subject.edgeSubmissions == cap, "…and the tail was charged to nothing")
        #expect(handle.completions == [true], "…and the delivered task was completed exactly once")
    }

    /// **The chain is unbroken across three deliveries, and every successor predates its own
    /// completion.**
    ///
    /// The ORDER is the claim, and it is invisible to a count taken afterwards — both orders end
    /// with one request in hand. After `setTaskCompleted(success:)` iOS may suspend the app in the
    /// same breath, so a submission made after the completion is the one the chain never gets; the
    /// fake's `atCompletion` hook is what reads the world AT that instant rather than after it.
    ///
    /// Three rounds rather than one: a chain is the claim, a single delivery is an anecdote.
    /// `CompanionRefreshSchedulingTests.everyHandlerRunResubmitsBeforeItCompletes` owns ONE
    /// delivery's ordering; what is here is the chain — three rounds, the pending slot asserted
    /// round by round because that is the state the next background edge reads, and a tail that
    /// charged the edge budget for none of it.
    @Test func theChainIsUnbrokenAndEverySuccessorPredatesItsCompletion() async {
        let (subject, scheduler) = MeshP10Acceptance.registeredCoordinator()
        var submittedAtCompletion: [Int] = []

        // R2: bounded by the three rounds.
        for round in 1...3 {
            let handle = FakeCompanionRefreshTaskHandle()
            handle.atCompletion = { submittedAtCompletion.append(scheduler.submitted.count) }
            scheduler.deliver(handle)
            #expect(subject.pendingRequest != nil, """
                round \(round): the delivery emptied the slot and the tail refilled it before the \
                pipeline was even started
                """)
            await subject.pipelineRun?.value
            #expect(handle.completions == [true], "round \(round): completed exactly once")
            #expect(scheduler.submitted.count == round, "round \(round): one successor per delivery")
        }

        #expect(submittedAtCompletion == [1, 2, 3], """
            at every completion instant the successor already existed. Read AT the completion \
            because the opposite order finishes with the same count in hand, and it is the order \
            that decides whether a suspension landing on the completion ends the chain
            """)
        #expect(subject.submissions == 3, "the coordinator's own R2 counter agrees with the seam")
        #expect(subject.edgeSubmissions == 0, "and not one of the three came from the background edge")
        #expect(scheduler.submitted.allSatisfy { $0.identifier == "MBO.Fernlet.companion-refresh" },
                "every request in the chain names the one permitted identifier, against the literal")
    }
}
