// MeshP8AcceptanceTests.swift
// FernletTests
//
// Network migration **P8's acceptance battery** (plan §14, launcher item 10): one serialized suite
// per clause, each promoting the named tier-1 claims of the item it speaks for and running its
// clause END TO END on the shipping seams, so CI gating a clause fails on this battery's own
// assertions rather than on a unit suite's. The P7 battery is the template and the rule is the same
// — where an exhaustive space already exists it is RE-WALKED here rather than sampled, and never by
// calling the unit suite's oracle: clause (a) carries its own 48-row expectation, spelled
// EVENT-outermost with every state a literal row — a THIRD decomposition, neither the shipped
// table's state-first helpers nor `MeshContinuationProduct`'s event-first predicates — so a table
// and an oracle that drifted together would still redden here, and a sweep that rewrites a
// production helper finds no identically-shaped twin in this file to rewrite with it.
//
// **Six suites.** The coordinator's table whole (item 4), the hold verb (item 3), the two raises and
// the disagreement on a real founding (item 5), the presentation table (item 7), the task wiring
// through item 6's fakes (item 6), and an honesty suite naming — by §15 row — what no Simulator can
// run. `CIGateSelectorBoundaryTests` therefore moves its battery pin from 42 to 48, and the same
// commit gates the six `MeshContinuation*` suites items 4/5/7 left on no CI line at all plus item
// 6's two.
//
// **What this battery does NOT claim** is in the honesty suite, by name and not by omission:
// `BGTaskScheduler` refuses a continued-processing submission on a Simulator (error 1), so every
// wiring cell drives a fake; §15.1–§15.4 are hardware gates; and the QUIC hold on real radios is
// item 3's tier-2 row. The two determinism digests keep their one home in `MeshP5AcceptanceTests`,
// this file spells neither, and the gate that runs it re-runs the three determinism suites.

import Foundation
import SwiftUI
import Testing
@testable import FernletCrypto
import LocalPersistence
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshP8Acceptance

/// The thin rig P8's clauses share: the battery's OWN expectation of item 4's table, and the founded
/// heart pair the raise clause drives.
///
/// The source walker and the per-occurrence home list are deliberately **not** re-spelled here — a
/// fifth copy of `MeshP7Acceptance.sources(under:)` / `homes(of:in:)` is what
/// `MeshContinuationRaiseWallTests` already refused to write; both are `nonisolated static`, so a
/// non-isolated cell may call them.
@MainActor
enum MeshP8Acceptance {

    /// **This battery's own expectation of one cell of item 4's table, spelled EVENT-outermost.**
    ///
    /// A **third** decomposition of the same 48 cells, deliberately. The shipped table switches
    /// state → event (`fromIdle` … `fromCompleted`, with cases grouped per state); the unit suite's
    /// oracle — `MeshContinuationProduct` — re-states the landing event-first as three predicate
    /// projections (`expectedNext` / `expectedCompletion` / `expectedAudit`). This is neither: eight
    /// per-event helpers, each spelling **all six states as its own literal row**, no case grouped,
    /// no `default`, no predicate. So a sweep that rewrites the production file's `fromRequested`
    /// finds no identically-named, identically-shaped twin to land on here, and a table and an
    /// oracle edited together in one sweep still redden against these literals.
    ///
    /// Total over the 48-row product; no row traps. Written from plan §14 and the state machine's
    /// documented rules, never by calling either of the other two.
    ///
    /// - Parameters:
    ///   - state: Where the claim stands.
    ///   - event: What happened.
    /// - Returns: The cell this battery expects.
    nonisolated static func expected(
        from state: MeshContinuationState, on event: MeshContinuationEvent
    ) -> MeshContinuationOutcome {
        switch event {
        case .meshStarted: return onMeshStarted(state)
        case .firstPeerCommitted: return onFirstPeerCommitted(state)
        case .taskStarted: return onTaskStarted(state)
        case .taskRefused: return onTaskRefused(state)
        case .taskExpired: return onTaskExpired(state)
        case .taskCancelled: return onTaskCancelled(state)
        case .sessionEnded: return onSessionEnded(state)
        case .appForegrounded: return onAppForegrounded(state)
        }
    }

    /// A mesh started: the registration from rest, and from everywhere else the reset — a new mesh
    /// never inherits the old mesh's claim, and a task still in hand is paid `false` on the way out.
    private nonisolated static func onMeshStarted(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.idle, .registered)
        case .requested: return cell(.idle, .meshChanged)
        case .running: return cell(.idle, .meshChanged, .failed)
        case .refused: return cell(.idle, .meshChanged)
        case .expired: return cell(.idle, .meshChanged)
        case .completed: return cell(.idle, .meshChanged)
        }
    }

    /// The first peer committed: it submits from rest and is absorbed everywhere else, so a peer
    /// that walked out of range and back can re-arm a withdrawn claim and cannot double-submit a
    /// live one.
    private nonisolated static func onFirstPeerCommitted(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.requested, .submitted)
        case .requested: return cell(.requested, .absorbed)
        case .running: return cell(.running, .absorbed)
        case .refused: return cell(.refused, .absorbed)
        case .expired: return cell(.expired, .absorbed)
        case .completed: return cell(.completed, .absorbed)
        }
    }

    /// The system delivered the task: adopted from every state but `running`, where a second
    /// delivery for one registered identifier is absorbed rather than stacked.
    private nonisolated static func onTaskStarted(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.running, .started)
        case .requested: return cell(.running, .started)
        case .running: return cell(.running, .absorbed)
        case .refused: return cell(.running, .started)
        case .expired: return cell(.running, .started)
        case .completed: return cell(.running, .started)
        }
    }

    /// The submission was refused: only a request in flight can be refused, and nothing else moves.
    private nonisolated static func onTaskRefused(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.idle, .absorbed)
        case .requested: return cell(.refused, .refused)
        case .running: return cell(.running, .absorbed)
        case .refused: return cell(.refused, .absorbed)
        case .expired: return cell(.expired, .absorbed)
        case .completed: return cell(.completed, .absorbed)
        }
    }

    /// An expiry: a request the system never ran lands on `refused` (it was never granted), while a
    /// delivered task that ran out of time lands on `expired` and completes `false`.
    private nonisolated static func onTaskExpired(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.idle, .absorbed)
        case .requested: return cell(.refused, .expired)
        case .running: return cell(.expired, .expired, .failed)
        case .refused: return cell(.refused, .absorbed)
        case .expired: return cell(.expired, .absorbed)
        case .completed: return cell(.completed, .absorbed)
        }
    }

    /// A cancel WITHDRAWS a request that was never granted — the claim resets to `idle` so the next
    /// commit re-arms it (landing on `completed` would strand the mesh) — and ends a delivered task.
    private nonisolated static func onTaskCancelled(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.idle, .absorbed)
        case .requested: return cell(.idle, .cancelled)
        case .running: return cell(.expired, .cancelled, .failed)
        case .refused: return cell(.refused, .absorbed)
        case .expired: return cell(.expired, .absorbed)
        case .completed: return cell(.completed, .absorbed)
        }
    }

    /// The session ended: the terminal from every state but rest and the terminal itself, and the
    /// one ending that pays a delivered task `true`.
    private nonisolated static func onSessionEnded(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.idle, .absorbed)
        case .requested: return cell(.completed, .completed)
        case .running: return cell(.completed, .completed, .succeeded)
        case .refused: return cell(.completed, .completed)
        case .expired: return cell(.completed, .completed)
        case .completed: return cell(.completed, .absorbed)
        }
    }

    /// The app came back: it spends a delivered task `true` and re-arms the claim at `requested` —
    /// the token names the ending, the next state is the instruction — and is absorbed everywhere
    /// else, because the card is READ in the foreground.
    private nonisolated static func onAppForegrounded(
        _ state: MeshContinuationState
    ) -> MeshContinuationOutcome {
        switch state {
        case .idle: return cell(.idle, .absorbed)
        case .requested: return cell(.requested, .absorbed)
        case .running: return cell(.requested, .completed, .succeeded)
        case .refused: return cell(.refused, .absorbed)
        case .expired: return cell(.expired, .absorbed)
        case .completed: return cell(.completed, .absorbed)
        }
    }

    /// One expected cell, spelled once.
    private nonisolated static func cell(
        _ next: MeshContinuationState,
        _ audit: MeshContinuationAudit,
        _ completion: MeshContinuationCompletion? = nil
    ) -> MeshContinuationOutcome {
        MeshContinuationOutcome(next: next, completion: completion, audit: audit)
    }

    /// **The 23 cells of item 7's 6 × 10 product that present a card, by identity.**
    ///
    /// Spelled as literal `"<state>+<audit token>"` keys — `"nothing"` for the tenth column, no
    /// token at all — rather than counted: a table that made one silent cell present and one
    /// present cell silent keeps 23/37 and stays green against a count. The two spent claims
    /// present under every token they can carry (a state the token cannot contradict), and the
    /// terminal presents only the three endings a session that is over still owes the person.
    ///
    /// - Returns: The set the presentation clause compares for equality.
    nonisolated static func presentingCells() -> Set<String> {
        [
            "refused+mesh.continuation.registered",
            "refused+mesh.continuation.submitted",
            "refused+mesh.continuation.started",
            "refused+mesh.continuation.refused",
            "refused+mesh.continuation.expired",
            "refused+mesh.continuation.cancelled",
            "refused+mesh.continuation.completed",
            "refused+mesh.continuation.meshChanged",
            "refused+mesh.continuation.absorbed",
            "refused+nothing",
            "expired+mesh.continuation.registered",
            "expired+mesh.continuation.submitted",
            "expired+mesh.continuation.started",
            "expired+mesh.continuation.refused",
            "expired+mesh.continuation.expired",
            "expired+mesh.continuation.cancelled",
            "expired+mesh.continuation.completed",
            "expired+mesh.continuation.meshChanged",
            "expired+mesh.continuation.absorbed",
            "expired+nothing",
            "completed+mesh.continuation.refused",
            "completed+mesh.continuation.expired",
            "completed+mesh.continuation.cancelled"
        ]
    }

    /// The key one cell of that product is named by, spelled once so the walk and the literal set
    /// above cannot drift apart in their spelling while disagreeing about their contents.
    ///
    /// - Parameters:
    ///   - state: The claim's state.
    ///   - audit: The token that named its last move, or nil.
    /// - Returns: The key.
    nonisolated static func presentationKey(
        _ state: MeshContinuationState, _ audit: MeshContinuationAudit?
    ) -> String {
        "\(state.rawValue)+\(audit?.rawValue ?? "nothing")"
    }

    /// The gate the run policy pushes for a BACKGROUNDED scene on an unlocked device —
    /// `FernletApp.routedGateForeground(for: .background)` is false and the device is still
    /// unlocked, so this is the honest value rather than `MeshRoutedAccessGate.closed`.
    static let backgroundedGate = MeshRoutedAccessGate(
        protectedDataAvailable: true, appIsForeground: false, duressActive: false
    )

    /// The one stated instant the heart clauses judge against; nothing here reads a clock.
    static let day = Date(timeIntervalSince1970: 1_780_000_000)

    /// A founded pair with hearts on at both ends, a ledger at each, the vault rows a mesh heart
    /// needs, and the recipient's gate open.
    ///
    /// The same honesty as the ceremony suite applies: production reaches mutual vault rows only
    /// across two sessions, so this proves the mechanics and Lane C proves the feature.
    ///
    /// - Parameter label: The diagnostic prefix.
    /// - Returns: The rig; the caller tears it down.
    static func foundedHeartPair(_ label: String) async throws -> MeshFoundingRig {
        let rig = try MeshFoundingRig.build(2, label: label)
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle()
        rig.nodes[0].manager.heartLedger = rig.isolatedHeartLedger(now: day)
        rig.nodes[1].manager.heartLedger = rig.isolatedHeartLedger(now: day)
        rig.nodes[0].store.setAllowNearbyHearts(true)
        rig.nodes[1].store.setAllowNearbyHearts(true)
        rig.trustPeer(at: 1, asSeenFrom: 0)
        rig.trustPeer(at: 0, asSeenFrom: 1)
        rig.openGate(at: 1)
        return rig
    }

    /// Pushes one routed access gate at a node under the founding rig's pinned install binding,
    /// exactly as the store's funnel pushes it — without it a persisting effect is refused.
    ///
    /// - Parameters:
    ///   - gate: The facts to push.
    ///   - node: Which node.
    ///   - rig: The rig.
    /// - Returns: What the re-entry pass did, or nil when nothing moved.
    @discardableResult
    static func pushGate(
        _ gate: MeshRoutedAccessGate, at node: Int, in rig: MeshFoundingRig
    ) -> MeshRoutedReentryReport? {
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            let report = rig.nodes[node].manager.applyRoutedAccessGate(gate, now: Date())
            return report
        }
    }
}

// MARK: - (a) The coordinator's table

/// **Item 4: the claim's table, whole.** All 48 rows re-walked through the shipped transition against
/// this battery's own expectation, the exactly-once biconditional over the same product, and the
/// progress ratchet that keeps the system from killing the task.
@MainActor
@Suite(.serialized)
struct MeshP8CoordinatorTableAcceptanceTests {

    /// Every state × every event, compared with ``MeshP8Acceptance/expected(from:on:)`` — the
    /// battery's own reading of §14, never `MeshContinuationProduct`'s.
    @Test func theWholeFortyEightRowTableAgreesWithThisBatterysOwnExpectation() {
        let states = MeshContinuationState.allCases
        let events = MeshContinuationEvent.allCases
        #expect(states.count == 6 && events.count == 8,
                "six states and eight events — a new one must move this number deliberately")
        var walked = 0
        var disagreements: [String] = []
        // R2: bounded by the 6 × 8 product.
        for state in states {
            for event in events {
                walked += 1
                let shipped = MeshContinuationCoordinator.transition(from: state, on: event)
                let expected = MeshP8Acceptance.expected(from: state, on: event)
                if shipped != expected {
                    disagreements.append("\(state.rawValue) + \(event.rawValue): \(shipped) != \(expected)")
                }
                if shipped.feed != shipped.next.feed {
                    disagreements.append("\(state.rawValue) + \(event.rawValue): feed is not next.feed")
                }
            }
        }
        #expect(walked == 48, "the product is 48 rows and every one was walked")
        #expect(disagreements.isEmpty, """
            the shipped table disagrees with this battery's own expectation of plan §14:
            \(disagreements.joined(separator: "\n"))
            """)
        #expect(MeshContinuationCoordinator.initialState == .idle,
                "and a claim begins where a fresh coordinator does")
    }

    /// **The exactly-once oracle, as a biconditional over the whole product.** A completion fires on
    /// a row if and only if that row LEAVES `running`, and its flag is the ending's own.
    @Test func aCompletionFiresIfAndOnlyIfARowLeavesRunning() {
        var completing = 0
        var wrong: [String] = []
        // R2: bounded by the 6 × 8 product.
        for state in MeshContinuationState.allCases {
            for event in MeshContinuationEvent.allCases {
                let outcome = MeshContinuationCoordinator.transition(from: state, on: event)
                let leavesRunning = state == .running && outcome.next != .running
                if (outcome.completion != nil) != leavesRunning {
                    wrong.append("\(state.rawValue) + \(event.rawValue)")
                }
                if outcome.completion != nil { completing += 1 }
            }
        }
        #expect(wrong.isEmpty, """
            completion != nil ⟺ (from == .running && next != .running) fails on:
            \(wrong.joined(separator: ", "))
            """)
        #expect(completing == 5, "the five exits from `running`, and no other row in the table")
        let running = MeshContinuationCoordinator.transition(from: .running, on: .sessionEnded)
        #expect(running.completion == .succeeded && running.completion?.success == true,
                "a session that finished completes true")
        let expired = MeshContinuationCoordinator.transition(from: .running, on: .taskExpired)
        #expect(expired.completion == .failed && expired.completion?.success == false,
                "a task that ran out of time completes false")
        let foreground = MeshContinuationCoordinator.transition(from: .running, on: .appForegrounded)
        #expect(foreground.next == .requested && foreground.audit == .completed,
                "and the foreground return spends the task while re-arming the claim — the token is the ending, the next state is the instruction")
    }

    /// **The progress ratchet.** Monotonic by construction and monotonic again by `max`, clamped one
    /// short of the total, and unmovable by a budget no arithmetic can divide by.
    @Test func theProgressRatchetNeverRetreatsAndNeverClaimsTheWorkIsDone() {
        let budget: TimeInterval = 6 * 3_600
        var reading = MeshContinuationProgress.zero
        var retreats = 0
        // R2: bounded by the thirteen stated elapsed readings.
        for elapsed in [0.0, 600, 1_800, 900, 3_600, 3_000, 7_200, 10_800, 21_600, 21_599, 43_200,
                        .infinity, .nan] as [TimeInterval] {
            let next = MeshContinuationProgress.advancing(from: reading, elapsed: elapsed, budget: budget)
            if next.fraction < reading.fraction { retreats += 1 }
            reading = next
        }
        #expect(retreats == 0, "the bar never retreats, not even on a clock that went backwards or a non-finite reading")
        #expect(reading.fraction == 1, "and six hours in it is full")
        #expect(reading.completedUnitCount == MeshContinuationProgress.totalUnitCount - 1,
                "yet the reported count stops one short of the total: a Progress that completes says the work has finished, and the mesh has not")
        let halfway = MeshContinuationProgress.advancing(from: nil, elapsed: budget / 2, budget: budget)
        #expect(halfway.fraction == 0.5 && halfway.completedUnitCount == 50, "halfway reads halfway")
        // R2: bounded by the three unusable budgets.
        for bad in [0.0, -1, .nan] as [TimeInterval] {
            let held = MeshContinuationProgress.advancing(from: halfway, elapsed: 600, budget: bad)
            #expect(held == halfway, "an unusable budget yields no NEW progress rather than a division by zero")
        }
        #expect(MeshContinuationProgress.advancing(from: nil, elapsed: 600, budget: 0) == .zero,
                "and a first reading over one is zero")
    }
}

// MARK: - (b) The verb

/// **Item 3: the hold, on the founding rig.** The verb keeps the committed link, closes all three
/// doors, pauses the transport rather than stopping it, stands the give-up clock down and drops the
/// slots it is not keeping; the resume reopens every one of them; and the policy row that P7 could
/// only refuse now executes, with the refusal's token a zero count under `App/`.
@MainActor
@Suite(.serialized)
struct MeshP8HoldVerbAcceptanceTests {

    /// The link, its coordinator, the group key and the mesh all survive, and the radio went quiet
    /// through `pauseDiscovery()` and never through `stop()` — which is the whole difference between
    /// a stand-down and the teardown `stopJoin()` would have done.
    ///
    /// The group key is SEEDED first (the fake fabric never runs the admission grant that would mint
    /// one), so "the key is still here" is a claim about something that was there; and the teeth are
    /// at the end — the peer's own `stopJoin()`, in this same cell and on this same rig, funnels
    /// through `stopSearching()` → `clearGroupKeyState()` and nils exactly the observable the hold
    /// is asserted to keep.
    @Test func theHoldKeepsTheCommittedLinkAndPausesTheTransportRatherThanStoppingIt() async throws {
        let rig = try MeshFoundingRig.build(2, label: "p8-hold-keeps")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let manager = rig.nodes[0].manager
        manager.resumeSearchingForPartitionedMesh()
        #expect(manager.isSearching, "the radios are up, so lowering the flag below says something")
        let radio = try #require(manager.transportForTesting as? FakeMeshTransportSession)
        let mesh = try #require(manager.currentMesh?.meshID)
        let coordinator = try #require(manager.slots.first, "the commit seated a slot").coordinator
        _ = MeshP3Acceptance.seedEpoch(manager, counter: 1)
        _ = MeshP3Acceptance.seedEpoch(rig.nodes[1].manager, counter: 1)
        #expect(manager.currentGroupKey?.epoch == 1, "the session really holds a key to lose")

        manager.holdCommittedLinks()

        #expect(!manager.isSearching, "browsing is down")
        #expect(radio.pauseDiscoveryCount == 1, "through the radio's own pause, exactly once")
        #expect(radio.stopCount == 0,
                "and never through stop(), which disconnects every peer and drops every peer-keyed record")
        #expect(manager.hasCommittedPeer && manager.isInSession && manager.isSessionLive,
                "the committed peer, the session surface and the live session are all untouched")
        #expect(manager.slots.count == 1 && manager.slots.first?.coordinator === coordinator,
                "the same slot, the SAME coordinator object — neither cancelled away nor replaced")
        #expect(manager.currentMesh?.meshID == mesh && rig.roster(0).count == 2,
                "over the same mesh, on the same derived roster")
        #expect(manager.currentGroupKey?.epoch == 1,
                "and the epoch's group key is untouched — a stand-down is not clearGroupKeyState()")

        rig.nodes[1].manager.stopJoin()

        #expect(rig.nodes[1].manager.currentGroupKey == nil, """
            which is a claim with teeth, measured on the same observable at the other end of the \
            same mesh: the verb the policy row could NOT use funnels through `stopSearching()` and \
            takes the group key with it, so the assertion above is not one a nil could satisfy
            """)
    }

    /// All three admission doors, driven through the radio rather than around it, plus the
    /// uncommitted slot the hold does NOT keep — and the inverse that reopens every one.
    @Test func theHoldClosesEveryDoorDropsTheUncommittedSlotAndTheResumeReopensThem() async throws {
        let rig = try MeshFoundingRig.build(3, label: "p8-hold-doors")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle([0, 1], until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let manager = rig.nodes[0].manager
        let radio = try #require(manager.transportForTesting as? FakeMeshTransportSession)
        manager.resumeSearchingForPartitionedMesh()
        rig.link(0, 2)
        let candidate = rig.nodes[2].handle
        let committed = rig.nodes[1].handle
        #expect(manager.slots.count == 2, "two slots — one committed, one still proving itself")
        let dialled = radio.invitedPeers.count

        manager.holdCommittedLinks()

        radio.discover(candidate)
        #expect(radio.invitedPeers.count == dialled, "door 1: a held mesh dials nobody it discovers")
        #expect(!radio.offerInboundConnection(from: candidate), "door 2: and accepts no invitation")
        #expect(manager.channelAdmission(for: candidate) == .kick, "door 3: and seats no channel")
        #expect(manager.channelAdmission(for: committed) == .alreadySeated,
                "while the peer that already holds a seat is left entirely alone")
        #expect(manager.slots.count == 1 && manager.slots.first?.fingerprint != nil,
                "the uncommitted candidate is disconnected — a dwell finishing behind shut doors would seat into the mesh they just refused")

        manager.resumeSearchingForPartitionedMesh()

        #expect(manager.isSearching, "the inverse brings browsing back")
        radio.discover(candidate)
        #expect(radio.invitedPeers.count == dialled + 1, "door 1 reopens")
        #expect(radio.offerInboundConnection(from: candidate) && manager.channelAdmission(for: candidate) == .seat,
                "and doors 2 and 3 with it — the hold is a stand-down, never a one-way latch")
    }

    /// **The clock pauses with the radios.** A committed link lost behind a hold lights no
    /// five-minute fuse, six minutes of holding is not an ending, and the resume restarts the clock
    /// from the moment browsing really resumes.
    @Test func aLinkLostBehindAHoldLightsNoFuseAndTheResumeRestartsTheClock() async throws {
        let rig = try MeshFoundingRig.build(2, label: "p8-hold-clock")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        let manager = rig.nodes[0].manager
        let radio = try #require(manager.transportForTesting as? FakeMeshTransportSession)
        manager.resumeSearchingForPartitionedMesh()
        #expect(!manager.isSessionGiveUpClockArmed, "a linked pair is counting down to nothing")

        manager.holdCommittedLinks()
        let blipAt = Date()
        radio.drop(rig.nodes[1].handle)

        #expect(!manager.hasCommittedPeer, "the blip really took the committed link")
        #expect(!manager.isSessionGiveUpClockArmed,
                "and door 3 did not start counting behind the shut doors — the re-link that cancels it is what the hold made impossible")
        manager.evaluateSessionGiveUp(now: blipAt.addingTimeInterval(6 * 60))
        #expect(manager.isSessionLive && manager.currentMesh != nil,
                "so six minutes of holding is a wait, not an ending")

        let resumedAt = Date()
        manager.resumeSearchingForPartitionedMesh()

        #expect(manager.isSearching && manager.isSessionGiveUpClockArmed,
                "the foreground return reopens the doors and restarts door 3 from HERE")
        manager.evaluateSessionGiveUp(now: resumedAt.addingTimeInterval(6 * 60))
        #expect(!manager.isSessionLive,
                "while a genuine timeout AFTER the resume still ends the session, unchanged")
    }

    /// **Pass 2 ran.** The policy's mesh-`run` / discovery-`stop` row emits the hold, the executor
    /// runs the verb, the verb's only home under `App/` is the seams file, and the refusal P7 shipped
    /// for that row is a zero count in the app.
    @Test func thePolicyRowExecutesTheHoldAndTheRefusalsTokenIsGoneFromTheApp() throws {
        let continued = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(
            continuation: .running, session: .peerCommitted
        ))
        let background = ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(
            phase: .background, continuation: .running, session: .peerCommitted
        ))
        #expect(background.mesh == .run && background.discovery == .stop,
                "the row P7 could only refuse: the mesh runs in the background, discovery never does")
        let live = ProximityRunTransition.MeshFacts(
            isSearching: true, isInSession: true, hasCommittedPeer: true,
            presenceListening: true, recipeShareListening: false
        )
        #expect(ProximityRunTransition.actions(from: continued, to: background, mesh: live)
                == [.holdLinks, .presence(.stop)],
                "and the transition answers it with the hold rather than with a refusal")
        let sources = try MeshP7Acceptance.sources(under: "App")
        #expect(sources.count >= 100, "the app-target scan lost its files")
        #expect(MeshP7Acceptance.homes(of: ".holdCommittedLinks(", in: sources) == ["ProximityRunSeams.swift"],
                "the verb's one home under App/ is the seams file — the retirement wall's rule, applied to the new verb")
        #expect(MeshP7Acceptance.homes(of: "proximityRunPolicy.unsupportedTransition", in: sources).isEmpty,
                "no shipping file refuses a policy row any more")
        #expect(MeshP7Acceptance.homes(of: "refuseBackgroundDiscoveryStop", in: sources).isEmpty,
                "and the action case it rode on is gone with it")
    }
}

// MARK: - (c) The raises and the disagreement

/// **Item 5: the two session-state raises and the cell §24.1 and §25.1 name.** The wall's three
/// counts re-asserted here, the four corners of the two legs on a real founding, and the reset that
/// must give the session leg back or strand a mesh in the background forever.
@MainActor
@Suite(.serialized)
struct MeshP8RaiseAndDisagreementAcceptanceTests {

    /// The wall, re-walked: one raise of each scene event in the whole package, each inside the
    /// public door named for it; the app speaks each public raise exactly once and only from the
    /// driver; and the app offers the session machine no event directly.
    @Test func eachRaiseHasOneHomeAndTheAppReachesTheSessionMachineNoOtherWay() throws {
        let kit = try MeshP7Acceptance.sources(under: "FernletKit/Sources")
        #expect(kit.count >= 100, "the package scan lost its files")
        #expect(MeshP7Acceptance.homes(of: "applySessionEvent(.backgrounded", in: kit) == ["MeshNetworkManager.swift"],
                "the backgrounded raise has exactly one home")
        #expect(MeshP7Acceptance.homes(of: "applySessionEvent(.foregrounded", in: kit) == ["MeshNetworkManager.swift"],
                "and so does the foregrounded raise")
        let manager = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift"))
        let began = try #require(
            MeshRoutedSourceScan.bracedBody(after: "public func beginBackgroundContinuation()", in: manager),
            "the public begin door is gone")
        #expect(began.contains("applySessionEvent(.backgrounded)"), "and the begin door is what raises it")
        let ended = try #require(
            MeshRoutedSourceScan.bracedBody(after: "public func endBackgroundContinuation()", in: manager),
            "the public end door is gone")
        #expect(ended.contains("applySessionEvent(.foregrounded)"), "and its sibling raises the other")
        let app = try MeshP7Acceptance.sources(under: "App")
        #expect(app.count >= 100, "the app-target scan lost its files")
        #expect(MeshP7Acceptance.homes(of: "beginBackgroundContinuation()", in: app) == ["MeshContinuationDriver.swift"],
                "the app speaks the begin raise once, from the continuation driver")
        #expect(MeshP7Acceptance.homes(of: "endBackgroundContinuation()", in: app) == ["MeshContinuationDriver.swift"],
                "and the end raise once, from the same file")
        #expect(MeshP7Acceptance.homes(of: "applySessionEvent(", in: app).isEmpty,
                "and offers the session machine no event directly — the two public raises are its only session verbs")
    }

    /// **The independence claim, as four corners, on a real founding** — driven through item 6's own
    /// two-part raise rule: a task delivered while the app is still on screen raises nothing, and the
    /// scene going dark is what tells the mesh it is being continued.
    @Test func theTwoLegsMoveIndependentlyAndOnlyBothTogetherOpenTheHeartStage() async throws {
        let rig = try await MeshP8Acceptance.foundedHeartPair("p8-legs")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].manager
        let driver = MeshContinuationDriver(meshNetworkManager: recipient)
        #expect(recipient.sessionState == .activeForeground, "the precondition: a live FOREGROUND session")
        #expect(recipient.mayCommitRoutedHeartLedgerJudgement, "corner 1: both legs open ⇒ open")

        driver.taskDidStart(sceneIsDark: false)

        #expect(recipient.sessionState == .activeForeground, """
            a task delivered while the person is looking at Fernlet raises NOTHING: the claim is \
            adopted so the handle stays completable, and the mesh is told only when the scene is \
            really dark — a mesh told it is continuing while it is on screen stops judging hearts \
            for no reason
            """)

        driver.sceneDidGoDark()

        #expect(recipient.routedAccessGate.isOpen, "the raise touched the gate not at all")
        #expect(recipient.sessionState == .continuingInBackground,
                "the mesh knows it is being CONTINUED rather than merely dark")
        #expect(!recipient.mayCommitRoutedHeartLedgerJudgement,
                "corner 2: gate OPEN, session continuing in the background ⇒ still closed")

        driver.taskDidEnd(.appForegrounded)
        #expect(driver.consumePendingCompletion() == .succeeded, "the delivered task is completed once")
        MeshP8Acceptance.pushGate(MeshP8Acceptance.backgroundedGate, at: 1, in: rig)

        #expect(recipient.sessionState == .activeForeground, "the gate push moved the session leg not at all")
        #expect(!recipient.mayCommitRoutedHeartLedgerJudgement,
                "corner 3: gate CLOSED, session foreground ⇒ still closed")

        MeshP8Acceptance.pushGate(MeshRoutedDrainRig.openGate, at: 1, in: rig)

        #expect(recipient.mayCommitRoutedHeartLedgerJudgement, "corner 4: and only both together open it")
    }

    /// **A reset mid-task ends it first.** The hard stop item 6 wires this to will be made with a
    /// task in hand: a reset that merely cleared the fields would leave the mesh
    /// `continuingInBackground` for the life of the session, with the heart stage shut behind it and
    /// nothing left in shipping able to raise `.foregrounded`.
    @Test func aResetMidTaskCompletesTheHandleAndGivesTheSessionLegBack() async throws {
        let rig = try await MeshP8Acceptance.foundedHeartPair("p8-reset-midtask")
        defer { rig.teardown() }
        let recipient = rig.nodes[1].manager
        let driver = MeshContinuationDriver(meshNetworkManager: recipient)
        driver.taskDidStart(sceneIsDark: true)
        #expect(recipient.sessionState == .continuingInBackground && driver.state == .running,
                "the precondition: a task in hand and a mesh being continued behind it")

        driver.reset()

        #expect(driver.consumePendingCompletion() == .failed,
                "the handle is still owed a completion — the cancelled one, taken exactly once")
        #expect(recipient.sessionState == .activeForeground,
                "and the session leg comes back; nothing else in shipping raises .foregrounded")
        #expect(recipient.mayCommitRoutedHeartLedgerJudgement,
                "so a wipe does not close the heart stage for the life of the mesh")
        #expect(driver.state == .idle && driver.lastAudit == nil,
                "with the projection back where a driver is born, and nothing to present")
    }
}

// MARK: - (d) The presentation table

/// **Item 7: what a refusal, an expiry and a system end present.** The whole 6 × 10 product through
/// the shipped `card(state:lastAudit:)`, the projection rule that keeps an ending across the session
/// end, and the slot decision's six rows.
@MainActor
@Suite(.serialized)
struct MeshP8PresentationAcceptanceTests {

    /// Every claim state against every token and against no token at all: the same 23 cells present
    /// a card — pinned by IDENTITY against ``MeshP8Acceptance/presentingCells()``, not by the count
    /// a swapped pair would keep — 37 are silent, the three that present after the session ended
    /// carry the past-tense fold, and every presented card has a kind whose accessibility identifier
    /// is its frozen token.
    @Test func theSixByTenProductDecidesAndEveryPresentedCellCarriesItsEnding() {
        let audits: [MeshContinuationAudit?] = MeshContinuationAudit.allCases.map { $0 } + [nil]
        #expect(MeshContinuationAudit.allCases.count == 9 && audits.count == 10,
                "nine tokens plus `nothing yet` — the table's second input, whole")
        var present: [MeshContinuationCard] = []
        var presentKeys: Set<String> = []
        var silent = 0
        // R2: bounded by the 6 × 10 product.
        for state in MeshContinuationState.allCases {
            for audit in audits {
                guard let card = MeshContinuationCardPresentation.card(state: state, lastAudit: audit) else {
                    silent += 1
                    continue
                }
                present.append(card)
                presentKeys.insert(MeshP8Acceptance.presentationKey(state, audit))
                #expect(card.sessionHasEnded == (state == .completed),
                        "only a completed claim's card is about a session that has itself ended")
                #expect(card.accessibilityIdentifier == "friends.meshContinuation.\(card.kind.rawValue)",
                        "the identifier is the kind's frozen token, which the UI suite matches on")
            }
        }
        #expect(present.count == 23 && silent == 37, "23 present, 37 silent, over the 60-cell product")
        let pinned = MeshP8Acceptance.presentingCells()
        #expect(presentKeys == pinned, """
            a DIFFERENT 23 cells present than the ones this battery pins by identity — a count of 23 \
            says nothing about which, and swapping one silent cell for one present cell keeps it:
            present but not pinned \(presentKeys.subtracting(pinned).sorted())
            pinned but silent \(pinned.subtracting(presentKeys).sorted())
            """)
        #expect(present.filter(\.sessionHasEnded).count == 3,
                "and exactly the three endings a session that is over still owes the person")
        let live = MeshContinuationCardKind.allCases.map {
            MeshContinuationCardPresentation.card(for: $0, sessionHasEnded: false)
        }
        #expect(Set(live.map(\.symbolName)).count == 3, "each live ending has its own symbol")
        #expect(live.allSatisfy { !$0.sessionHasEnded }, "and none of them claims the session has ended")
        let roundTrip = MeshContinuationCardKind.allCases.allSatisfy {
            MeshContinuationCardPresentation.card(state: $0.presentingState, lastAudit: $0.presentingAudit)?.kind == $0
        }
        #expect(roundTrip, "and the table's inverse — what the DEBUG hook asks for — reaches every kind")
    }

    /// **The projection keeps the ending across the session end.** Driven through the real
    /// transitions rather than asserted on the rule in isolation: a refusal, then the 6-hour
    /// ceiling's own `sessionEnded` on top of it, and the card still says which ending it was.
    @Test func theProjectionKeepsTheEndingWhenTheSessionItselfEnds() throws {
        var state = MeshContinuationCoordinator.initialState
        var audit: MeshContinuationAudit?
        // R2: bounded by the four stated events.
        for event in [MeshContinuationEvent.firstPeerCommitted, .taskRefused, .appForegrounded, .sessionEnded] {
            let outcome = MeshContinuationCoordinator.transition(from: state, on: event)
            audit = MeshContinuationCardPresentation.projectedAudit(previous: audit, outcome: outcome)
            state = outcome.next
        }
        #expect(state == .completed, "the session ended on top of a refusal")
        #expect(audit == .refused, """
            and the projection kept the refusal: the foreground return was ABSORBED by a spent claim \
            and the move into `completed` carries the token `completed`, so assigning outcome.audit \
            blindly would have erased the only thing the card had to tell the person
            """)
        let card = try #require(MeshContinuationCardPresentation.card(state: state, lastAudit: audit),
                                "a completed claim carrying a refusal still has something to say")
        #expect(card.kind == .refused && card.sessionHasEnded,
                "the card still names the refusal, in the past tense the ended session deserves")
        let absorbed = MeshContinuationCoordinator.transition(from: .completed, on: .appForegrounded)
        #expect(MeshContinuationCardPresentation.projectedAudit(previous: .refused, outcome: absorbed) == .refused,
                "an absorbed row moved nothing and records nothing — the card is READ in the foreground")
        let started = MeshContinuationCoordinator.transition(from: .requested, on: .taskStarted)
        #expect(MeshContinuationCardPresentation.projectedAudit(previous: .refused, outcome: started) == .started,
                "while a row that really moved the claim records its own token")
    }

    /// **The slot decision's six rows.** A live spent claim outranks P7's resume card; once its own
    /// session has ended the ordering inverts, because a session the person can pick back up is the
    /// more useful truth.
    @Test func theSlotDecisionDecidesAllSixRows() {
        let live = MeshContinuationCardPresentation.card(for: .refused, sessionHasEnded: false)
        let ended = MeshContinuationCardPresentation.card(for: .refused, sessionHasEnded: true)
        let resume = SessionResumeCopy.card(for: .offerResume)
        #expect(resume != nil, "P7's resume card is the other arm — without one there is no contest")
        #expect(!live.sessionHasEnded && ended.sessionHasEnded, "the two continuation arms differ in exactly that")
        #expect(MeshContinuationCardPresentation.slotDecision(continuation: nil, resume: nil) == .nothing,
                "row 1: neither has anything to say")
        #expect(MeshContinuationCardPresentation.slotDecision(continuation: nil, resume: resume) == .resume,
                "row 2: only the resume card speaks")
        #expect(MeshContinuationCardPresentation.slotDecision(continuation: live, resume: nil) == .continuation,
                "row 3: only the continuation card speaks")
        #expect(MeshContinuationCardPresentation.slotDecision(continuation: live, resume: resume) == .continuation,
                "row 4: a LIVE spent claim describes the session running right now, and outranks the last one")
        #expect(MeshContinuationCardPresentation.slotDecision(continuation: ended, resume: nil) == .continuation,
                "row 5: an ended one still speaks when nothing else does")
        #expect(MeshContinuationCardPresentation.slotDecision(continuation: ended, resume: resume) == .resume,
                "row 6: but yields to a session the person can pick back up")
        #expect(MeshContinuationSlotDecision.allCases.count == 3, "three arms, and the table reaches all three")
    }
}

// MARK: - (e) The wiring

/// **Item 6: registration, submission, expiry, cancellation and exactly-once completion**, driven
/// end to end through item 6's own fakes — `BGTaskScheduler` refuses a continued-processing
/// submission on a Simulator, so the seam is the only way any of this runs at all.
@MainActor
@Suite(.serialized)
struct MeshP8TaskWiringAcceptanceTests {

    private let store = makeTestStore()
    private let meshID = UUID()

    /// A host over a fresh manager, with the fake scheduler it speaks to.
    ///
    /// - Returns: The host and its scheduler.
    private func makeHost() -> (host: MeshContinuationTaskHost, scheduler: FakeContinuationScheduler) {
        let scheduler = FakeContinuationScheduler()
        return (MeshContinuationTaskHost(
            store: store, meshNetworkManager: store.meshNetworkManager, scheduler: scheduler
        ), scheduler)
    }

    /// The mesh's own edges: a founded mesh registers its CONCRETE identifier, asks for nothing until
    /// a peer commits, and then submits exactly one request carrying the rendered copy.
    @Test func aFoundedMeshRegistersItsOwnIdentifierAndTheFirstCommitSubmitsOnce() {
        let (host, scheduler) = makeHost()
        let identifier = MeshContinuationTaskHost.identifier(for: meshID)
        #expect(identifier.hasPrefix(MeshContinuationTaskHost.identifierPrefix),
                "the identifier sits inside the Info.plist wildcard")

        host.meshDidStart(meshID: meshID, hasCommittedPeer: false)

        #expect(scheduler.registered == [identifier], "registered at mesh start, for this mesh alone")
        #expect(scheduler.submitted.isEmpty, "a mesh with nobody on it has nothing to continue")
        #expect(store.meshContinuationState == .idle, "and the card says nothing")

        host.committedPeerDidChange(hasPeer: true)

        let expected = MeshContinuationCopy.card(friendCount: 0)
        #expect(scheduler.submitted.count == 1, "exactly one request, on the 0 → 1 edge")
        #expect(scheduler.submitted.first?.title == String(localized: expected.title),
                "carrying copy rendered from the catalog resource, never a String literal")
        #expect(store.meshContinuationState == .requested, "and the run policy has been fed the claim")

        host.committedPeerDidChange(hasPeer: false)
        host.committedPeerDidChange(hasPeer: true)

        #expect(scheduler.submitted.count == 1,
                "a peer that blipped and came back queues no second request — the instruction is the ENTRY into `requested`")
    }

    /// A refusal is a MOVE of the claim, never a silence: the store hears it and item 7's card has
    /// its sentence.
    @Test func aRefusedSubmissionMovesTheClaimAndReachesTheCard() {
        let (host, scheduler) = makeHost()
        scheduler.submitRefusal = FakeSchedulerRefusal()

        host.meshDidStart(meshID: meshID, hasCommittedPeer: true)

        #expect(scheduler.submitted.isEmpty, "the system refused the request outright")
        #expect(host.driver.state == .refused, "which is a move of the claim, not an error swallowed")
        #expect(store.meshContinuationState == .refused && store.meshContinuationLastAudit == .refused,
                "the store holds the claim and the token that named the move")
        #expect(MeshContinuationCardPresentation.card(
            state: store.meshContinuationState, lastAudit: store.meshContinuationLastAudit
        )?.kind == .refused, "and the Friends card says the session stays on screen")
        #expect(store.proximityRunVerdict?.mesh == .hold && store.proximityRunVerdict?.discovery == .stop, """
            the setter re-ran the run policy and the VERDICT says what it decided — a refused claim \
            grants the mesh no background, so on this store's scene (none pushed, so the most \
            restrictive: backgrounded, protected data away) the mesh is held and browsing stopped. \
            `!= nil` would have passed on any verdict at all
            """)
        #expect(ProximityRunPolicy.verdict(for: ProximityRunPolicyProduct.row(
            continuation: .refused, session: .peerCommitted
        )).mesh == .foregroundOnly,
                "and the policy, fed a refusal, makes the mesh foreground-only — which is what that sentence means")
    }

    /// The delivered task: adopted, its expiration handler installed, the bar advanced on the
    /// poller's tick, and completed EXACTLY ONCE when the time runs out.
    @Test func aDeliveredTaskIsCompletedExactlyOnceWhenItsTimeRunsOut() throws {
        let (host, scheduler) = makeHost()
        host.meshDidStart(meshID: meshID, hasCommittedPeer: true)
        let handle = FakeContinuationTaskHandle()

        scheduler.deliver(handle)

        #expect(host.isHoldingTask, "the task is in hand")
        #expect(store.meshContinuationState == .running, "and the policy hears that the mesh has the background")
        let expire = try #require(handle.expirationHandler,
                                  "the expiration handler is installed at adoption, not at the first tick")
        host.sessionPollerDidTick()

        expire()

        #expect(handle.completions == [false],
                "the system is paid exactly once, false — the time it granted was spent")
        #expect(!host.isHoldingTask, "the handle is dropped in the same turn it is completed")
        #expect(store.meshContinuationState == .expired && store.meshContinuationLastAudit == .expired,
                "and the claim is spent, with the token the card reads")

        expire()

        #expect(handle.completions == [false],
                "a second expiry pays nothing more: consumePendingCompletion() answers nil on a second read")
    }

    /// Cancellation: the proximity hard stop pays the debt for the handle in hand, withdraws the
    /// pending request and resets the claim to silence — a wipe does not excuse the app from
    /// completing a task it is holding.
    @Test func theHardStopPaysTheDebtWithdrawsTheRequestAndResetsToSilence() {
        let (host, scheduler) = makeHost()
        host.meshDidStart(meshID: meshID, hasCommittedPeer: true)
        let handle = FakeContinuationTaskHandle()
        scheduler.deliver(handle)
        #expect(host.isHoldingTask && store.meshContinuationState == .running, "the precondition")

        host.proximityHardStopWillBegin()

        #expect(handle.completions == [false], "the handle in hand is completed once, false")
        #expect(!host.isHoldingTask, "and dropped")
        #expect(scheduler.cancelled.contains(MeshContinuationTaskHost.identifier(for: meshID)),
                "any request the system has not answered is withdrawn")
        #expect(store.meshContinuationState == .idle && store.meshContinuationLastAudit == nil,
                "and the Friends card says nothing about a background session on an emptied device")
    }

    /// **The feed is the only way this reaches a radio, and the tunnel is kept.** The host speaks no
    /// radio verb, the funnel's one line is the claim's own feed, and the probe's teardown is
    /// deliberately not copied.
    @Test func theFeedReachesThePolicyThroughTheStoreAndNothingTearsTheTunnelDown() throws {
        let app = try MeshP7Acceptance.sources(under: "App")
        #expect(app.count >= 100, "the app-target scan lost its files")
        #expect(MeshP7Acceptance.homes(of: "continuation: meshContinuationState.feed", in: app)
                == ["FernletStore.swift"],
                "the policy is FED the claim's own state, exactly once, in the run-policy core")
        #expect(MeshP7Acceptance.homes(of: "continuation: .notRequested", in: app).isEmpty
                && MeshP7Acceptance.homes(of: "continuation: .running", in: app).isEmpty,
                "and never a literal — what reaches the policy is the claim, not a hardcoded answer")
        let host = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/MeshContinuationTaskHost.swift"))
        #expect(!host.isEmpty, "the task host is gone")
        let verbs = [".startJoin(", ".stopJoin(", ".holdCommittedLinks(", ".leaveSession()",
                     ".resumeSearchingForPartitionedMesh(", "applyRoutedAccessGate(",
                     "presenceManager.", "recipeShareManager.", "stopNetworkOperations("]
        // R2: bounded by the literal list.
        for verb in verbs {
            #expect(!host.contains(verb), """
                the host must not contain `\(verb)`: what the radios do about a running task is the \
                run policy's decision, and the probe's endProbe — which tears its own tunnel down \
                before completing — is the one thing the product must not copy
                """)
        }
        #expect(host.contains("store?.setMeshContinuation("),
                "the one way it reaches a radio is the feed, and it is not a verb")
    }
}

// MARK: - (f) Honesty

/// **What P8's battery cannot run, named rather than implied.** Every plan §15 row, item 3's tier-2
/// QUIC row, the Simulator's own refusal, and the two determinism digests' single home.
@MainActor
@Suite(.serialized)
struct MeshP8HonestyAcceptanceTests {

    /// **Plan §15, row by row.** The four hardware gates are named here so a renamed or deleted one
    /// reddens rather than quietly narrowing what P8 admits it has not proved, and the device
    /// runbook's F-rows are asserted to still carry them with the P8 item each waits on.
    @Test func theBatteryNamesEveryGateOnlyHardwareCanAnswer() throws {
        let plan = try RepoRoot.source("Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md")
        let sections = [
            "**15.1 Radio matrix:**",        // background+lock, cached-endpoint re-dial, AWDL, Low Power Mode
            "**15.2 Partition walks:**",     // 2/2 and 3/1 physically, a removal vote, a carried departure
            "**15.3 Progress soak:**",       // 3 h and 6 h of elapsed-based progress under real phone use
            "**15.4 Wi-Fi Aware evaluation"  // the bounded two-day evaluation, and its recommendation
        ]
        // R2: bounded by the four stated sections.
        for section in sections {
            #expect(plan.contains(section), "plan §15's `\(section)` is gone — the gate it named is still unrun")
        }
        #expect(plan.contains("returns error 1 there at all"), """
            and the plan's own reason no cell in this battery can speak to any of them: \
            `BGTaskScheduler` refuses a continued-processing submission on a Simulator, which is \
            why every wiring cell in clause (e) drives `BackgroundContinuationScheduling` fakes
            """)
        let runbook = try RepoRoot.source("Docs/Mesh-P7-Physical-Device-Test-Plan-2026-09-18.md")
        // R2: bounded by the four gate labels.
        for gate in ["§15.1", "§15.2", "§15.3", "§15.4"] {
            #expect(runbook.contains(gate), "the device runbook's Lane B row for \(gate) is gone")
        }
        #expect(runbook.contains("mesh.session.linksHeld"), """
            item 3's hold is proved here over `FakeMeshTransportSession` — `pauseDiscoveryCount`, \
            never a radio. Its tier-2 row is a DEVICE observation: the transcript pair \
            mesh.session.linksHeld / linksResumed over a real QUIC tunnel, which no cell here makes
            """)
        let production = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/MeshContinuationScheduling.swift"))
        #expect(production.contains("BGTaskScheduler.shared.submit")
                && production.contains("BGContinuedProcessingTaskRequest("),
                "and the production conformer is real, untested code — item 9's device rows, claimed by nothing above")
    }

    /// Neither determinism digest moved and neither is spelled here: each keeps its ONE home in
    /// `MeshP5AcceptanceTests`, and the gate that runs this battery re-runs the P4/P5/P6 determinism
    /// suites, which is where a moved digest actually reddens.
    @Test func neitherDeterminismDigestMovedNorLeftItsOneHome() throws {
        let tests = try MeshP7Acceptance.sources(under: "Tests/FernletTests")
        #expect(tests.count >= 100, "the test-target scan lost its files")
        #expect(MeshP7Acceptance.homes(of: "ca898" + "bcc", in: tests) == ["MeshP5AcceptanceTests.swift"],
                "the schedule digest has exactly one home, and this file's split spelling is not a second")
        #expect(MeshP7Acceptance.homes(of: "594b6" + "f77", in: tests) == ["MeshP5AcceptanceTests.swift"],
                "and so does the overlay digest — a move is a red, never a re-pin")
        let me = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("Tests/FernletTests/MeshP8AcceptanceTests.swift"))
        let spellsADigest = me.contains("ca898" + "bcc") || me.contains("594b6" + "f77")
        #expect(!spellsADigest, "and P8's battery spells neither contiguously")
    }

    /// The battery is gated, and so are the continuation suites P8 left on no CI line: every suite in
    /// this file plus items 4/5/6/7's own are named on the workflow's mesh step.
    @Test func everySuiteHereAndEveryContinuationSuiteIsOnTheMeshStep() throws {
        let workflow = try RepoRoot.source(".github/workflows/s3-wall.yml")
        let clauses = ["MeshP8CoordinatorTableAcceptanceTests", "MeshP8HoldVerbAcceptanceTests",
                       "MeshP8RaiseAndDisagreementAcceptanceTests", "MeshP8PresentationAcceptanceTests",
                       "MeshP8TaskWiringAcceptanceTests", "MeshP8HonestyAcceptanceTests"]
        #expect(clauses.allSatisfy { workflow.contains($0) },
                "every P8 clause suite is named on the mesh-batteries step")
        let continuation = ["MeshContinuationCoordinatorTests", "MeshContinuationProgressTests",
                            "MeshContinuationCardPresentationTests", "MeshContinuationDriverTests",
                            "MeshContinuationRaiseWallTests", "MeshContinuationDisagreementTests",
                            "MeshContinuationTaskHostTests", "MeshContinuationTaskHostWallTests"]
        #expect(continuation.allSatisfy { workflow.contains($0) }, """
            items 4, 5, 6 and 7's own suites ran on no CI line until this commit — none is a \
            MeshP<n>…AcceptanceTests, so `everyMeshAcceptanceBatteryIsGated` never demanded them
            """)
        let steps = CIGateSelectorBoundaryTests.gatedSteps(in: workflow).filter { $0.label == "mesh-batteries" }
        #expect(steps.count == 1, "one mesh-batteries step")
        #expect(steps.first.map { $0.suites.count == Set($0.suites).count } == true,
                "and no suite is named on it twice — a duplicate selector runs its tests twice and inflates the floor")
    }
}
