// MeshRoutedCustodyHandoffTests.swift
// FernletTests
//
// Network migration P5 item 8 (plan §10.6, §11): custody-transfer-on-departure — the load-bearing
// case, and increment 1's ONLY relay hop.
//
// Tier 1 only — `FakePeerNetwork` + `FakeMeshTransportSession` + an injected clock, no radio and no
// wall-clock sleeps. The rig is item 6's `MeshRoutedDrainRig` with the three verbs the drain never
// needed, not a second rig; the nodes, links, pumps, settles and rotation samples are item 4's.
//
// The invariant every cell here is about: custody is at the ORIGIN, or — after exactly one
// transfer, at exactly one moment, a development — at the custodians the leaver's own signed
// departure record names AND served the manifest to. Never between two live connected members, and
// never a second hop.
//
// **One anchor, and it is the rig's** (item 6a). Every `let base` below is
// `MeshRoutedDrainRig.createdAt`, not a second pinned literal: the items these cells develop are
// minted at `MeshRoutedDrainRig.now` (= that anchor + 600), and a development instant anchored
// somewhere else drifts away from the mint the moment the rig's anchor rolls. Measured: with the
// two anchors split, seven cells in this family fail on the hand-off count.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

// MARK: - The three verbs item 6's rig never needed

@MainActor
extension MeshRoutedDrainRig {

    /// Raises plan §10.2's split at every named node and asserts the three answers a partition must
    /// not move: the roster does not shrink, a branch is not a final pair, and reachability is
    /// presence rather than membership.
    ///
    /// - Parameters:
    ///   - branches: Global node indices, one array per branch.
    ///   - now: The injected instant.
    func raisePartition(_ branches: [[Int]], at now: Date) {
        // R2: bounded by the rig's own node count.
        for branch in branches {
            let reachable = Set(branch.map { nodes[$0].fingerprint })
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                for index in branch {
                    let manager = nodes[index].manager
                    #expect(manager.evaluatePartition(reachable: reachable, now: now) == .linksLost)
                    #expect(manager.branchView?.rosterMemberCount == nodes.count,
                            "a split never shrinks a roster")
                }
            }
        }
    }

    /// One node develops on an injected clock. Returns what the departure actually emitted, so "a
    /// departure, not a termination" is asserted at the seam that signed it.
    ///
    /// The shipping path reads the clock three times on the transfer path — window open, transfer,
    /// outcome — plus once per custodian inside the best-effort push. The list saturates at its last
    /// instant, so a short list simply hands every later read the same one.
    @discardableResult
    func develop(_ index: Int, clock instants: [Date]) async -> [PayloadType] {
        let collected = MeshCustodyHandoffEmissions()
        nodes[index].manager.onMembershipEventSentForTesting = { collected.append($0) }
        let stepped = MeshTerminationFixtures.SteppedClock(instants)
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await nodes[index].manager.leaveSessionAfterNotifyingPeers(clock: { stepped.next() })
        }
        // The hook is removed rather than left installed: it outlives the development otherwise, and
        // a second development on the same node would append to a buffer nobody reads.
        nodes[index].manager.onMembershipEventSentForTesting = nil
        return collected.emitted
    }

    /// Cuts a seated link without telling either end — a radio that stopped reaching, not a
    /// disconnect. Used to take a departed origin off the air, never to build the initial split.
    func cut(_ near: Int, _ far: Int) {
        fabric.partition(nodes[near].handle, from: nodes[far].handle)
    }

    /// One node's development plan, derived exactly as the manager derives it.
    func plan(_ index: Int, at now: Date) -> MeshDevelopmentPlan {
        nodes[index].manager.developmentPlan(startedAt: now)
    }

    /// The item's per-destination delivery map as ONE node's own store holds it.
    func target(_ index: Int, _ key: MeshRoutedItemKey) -> MeshDeliveryTarget? {
        routedIndex(nodes[index])?.record(for: key)?.deliveryTarget
    }

    /// The earliest departure record one node's ledger holds.
    func departure(at index: Int) -> SignedDepartureRecord? {
        nodes[index].manager.membershipVerifier?.ledger.departures.earliest
    }

    /// The routed content frames one node received from another — what a peer's session frame
    /// budget is charged for, counted on the wire.
    func contentFrames(at receiver: Int, from sender: Int) -> Int {
        let bulk: Set<String> = [
            PayloadType.meshRoutedManifest.rawValue, PayloadType.meshRoutedChunk.rawValue,
            PayloadType.meshCustodyReceipt.rawValue, PayloadType.meshRecipientReceipt.rawValue
        ]
        return tokens(at: receiver, from: sender).filter { bulk.contains($0) }.count
    }
}

// MARK: - Test-local helpers

/// The membership events one development emitted. A class so the escaping test hook and the caller
/// share one buffer without capturing a `var` across an `await`.
@MainActor
final class MeshCustodyHandoffEmissions {

    /// What was emitted, in order.
    private(set) var emitted: [PayloadType] = []

    /// Records one emission.
    func append(_ type: PayloadType) { emitted.append(type) }
}

/// Collects audit lines WITH their context for one test, installed on entry and removed by token on
/// teardown so it never outlives the test that installed it.
///
/// A lock-guarded class rather than a captured local: the sink is a plain non-`Sendable` closure the
/// log invokes outside its own lock, so the only safe place for the collected lines is behind one.
final class MeshCustodyHandoffAudit {

    private let lock = NSLock()
    private var storedLines: [(event: String, context: [String: String])] = []
    private var token: UUID?

    /// Starts capturing.
    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedLines.append((event, context))
            self.lock.unlock()
        }
    }

    /// Stops capturing.
    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    /// Whether an event was logged at all.
    func logged(_ event: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storedLines.contains { $0.event == event }
    }

    /// Every event whose name starts with `prefix`, in order — the diagnostic a failing custody
    /// cell needs so "nothing happened" names which door said so.
    func events(prefix: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event.hasPrefix(prefix) }.map(\.event)
    }

    /// Every value logged under `key` for `event`, in order.
    func values(of event: String, key: String) -> [String] {
        lock.lock(); defer { lock.unlock() }
        return storedLines.filter { $0.event == event }.map { $0.context[key] ?? "missing" }
    }
}

// MARK: - MeshCustodyHandoffScenario

/// The three-node scenario every custody cell drives: origin (0) mints for the custodian (1) and the
/// destination (2); the destination is on the other side of the split and is **never seated**, so no
/// committed slot points at it; the origin↔custodian pair drains, so the custodian holds the whole
/// item and the origin holds the custodian's signed custody receipt; the origin develops inside the
/// fifteen-second window; the origin's radio is then cut and the destination heals to the custodian.
///
/// Phases are methods rather than one long test function (Power of 10 R4), and each carries the
/// claims it is *for*.
@MainActor
struct MeshCustodyHandoffScenario {

    /// Global indices, named once so no assertion reads a bare integer.
    static let origin = 0, custodian = 1, destination = 2

    /// The rig every phase runs on.
    let rig: MeshRoutedDrainRig

    /// The routed item the origin minted.
    let item: MeshRoutedDrainItem

    /// The item's signed pair.
    var key: MeshRoutedItemKey { item.key }

    /// The custodian's fingerprint.
    var custodianFingerprint: String { rig.nodes[Self.custodian].fingerprint }

    /// The destination's fingerprint.
    var destinationFingerprint: String { rig.nodes[Self.destination].fingerprint }

    /// Builds the roster of three, mints the item at the origin, stages it there, and links ONLY the
    /// origin↔custodian pair.
    static func build(label: String, byteCount: Int = 2_000) throws -> MeshCustodyHandoffScenario {
        let rig = try MeshRoutedDrainRig.build(3, label: label)
        let item = try MeshRoutedDrainItem.mint(rig, origin: origin, byteCount: byteCount)
        #expect(item.manifest.destinations.sorted()
                == [rig.nodes[custodian].fingerprint, rig.nodes[destination].fingerprint].sorted(),
                "destinations are the full roster minus the origin, at creation")
        item.stage(into: rig, at: origin)
        rig.link(origin, custodian)
        return MeshCustodyHandoffScenario(rig: rig, item: item)
    }

    /// The split: {origin, custodian} | {destination}. Presence only — nothing is minted, no record
    /// moves, and the destination is still a destination.
    func splitAwayTheDestination(at now: Date) {
        rig.raisePartition([[Self.origin, Self.custodian], [Self.destination]], at: now)
        let plan = rig.plan(Self.origin, at: now)
        #expect(plan.ending == .departure, "merged roster 3 ⇒ a departure, never a termination")
        #expect(plan.handoffTargets == [custodianFingerprint],
                "custody is offered to the reachable branch only")
    }

    /// The ordinary drain runs across the one live link, so the custodian holds the ciphertext
    /// BEFORE anything is handed off, and the origin holds the custodian's custody receipt.
    func drainToTheCustodian() async throws {
        rig.commit(Self.origin, Self.custodian)
        try await rig.settle([Self.origin, Self.custodian], until: {
            rig.routedIndex(rig.nodes[Self.custodian])?.record(for: key)?.isComplete == true
        })
        let held = try #require(rig.routedIndex(rig.nodes[Self.custodian])?.record(for: key))
        #expect(held.isComplete, "the custodian holds every chunk")
        try await rig.settle([Self.origin, Self.custodian], until: {
            rig.routedIndex(rig.nodes[Self.origin])?
                .record(for: key)?.receipts.isEmpty == false
        })
        #expect(rig.target(Self.origin, key)?.state(of: destinationFingerprint) == .pending,
                "the unreachable leg has not moved: a split is not a delivery")
    }

    /// The development. The transfer happens inside `leaveSessionAfterNotifyingPeers`, between the
    /// window-open and outcome clock reads, and the departure record carries what actually moved.
    @discardableResult
    func developInsideTheWindow(at base: Date) async throws -> [PayloadType] {
        let emitted = await rig.develop(
            Self.origin,
            clock: [base, base.addingTimeInterval(3), base.addingTimeInterval(3)]
        )
        // The seam that SIGNED it, not the decision that chose it: `plan.ending == .departure` is a
        // claim about a pure value, and this is the claim that a departure — never a termination —
        // is the frame the development actually put on the wire, ahead of any routed bytes (D-8.27).
        #expect(emitted.first == .meshMemberDeparture,
                "a departure, not a termination, was signed — and it went out before the bytes")
        #expect(emitted.contains(.meshTerminated) == false, "\(emitted)")
        try await rig.settle([Self.custodian], until: {
            MeshMergeFixtures.roster(rig.nodes[Self.custodian].manager).count == 2
        })
        // The origin's radio stops with it: nothing from it reaches anybody after this line.
        rig.cut(Self.origin, Self.custodian)
        return emitted
    }

    /// The destination heals to the custodian — an ORDERED heal, a commit round, and then a SECOND
    /// one so the healed pair re-forms as a full mesh.
    func healTheDestinationToTheCustodian() async throws {
        rig.link(Self.custodian, Self.destination)
        rig.commit(Self.custodian, Self.destination)
        try await rig.settle([Self.custodian, Self.destination], until: {
            rig.routedIndex(rig.nodes[Self.destination])?.record(for: key)?.isComplete == true
        })
        rig.commit(Self.custodian, Self.destination)
        try await rig.settle([Self.custodian, Self.destination], until: {
            rig.routedIndex(rig.nodes[Self.destination])?
                .record(for: key)?.recipientReceipts.isEmpty == false
        })
    }

    /// Ends every session so nothing outlives the scenario.
    func teardown() { rig.teardown() }

    /// ``MeshRoutedDrainRig/quiesce()``: end the sessions AND drain what the teardown could not
    /// cancel, while the stores are still alive.
    func quiesce() async { await rig.quiesce() }
}

// MARK: - MeshCustodyChainScenario

/// The A→B→C chain plan §0.2 warns about, on a roster of four with **no partition raised** — the
/// production shape, because nothing calls `evaluatePartition` until P7 wires the poller, so
/// `branchView == nil` and ``MeshDevelopmentPlan/handoffTargets`` is the whole roster minus the
/// leaver.
///
/// That shape is what makes the hop bound measurable. The origin (0) drains to the first hop (1) and
/// departs naming **every** other member a custodian; the first hop claims and serves the second (2).
/// The second hop is therefore a device the leaver's own signed record names, holding the complete
/// item, with an outstanding `pending` leg to the third (3) — every gate open except the one §4.2a
/// exists to close.
@MainActor
struct MeshCustodyChainScenario {

    /// Global indices, named once so no assertion reads a bare integer.
    static let origin = 0, first = 1, second = 2, third = 3

    /// The rig every phase runs on.
    let rig: MeshRoutedDrainRig

    /// The routed item the origin minted, for the full roster minus itself.
    let item: MeshRoutedDrainItem

    /// The item's signed pair.
    var key: MeshRoutedItemKey { item.key }

    /// Builds the roster of four, mints at the origin, stages it there, and links ONLY origin↔first
    /// — so the second hop can only ever get the item from the first.
    static func build(label: String) throws -> MeshCustodyChainScenario {
        let rig = try MeshRoutedDrainRig.build(4, label: label)
        let item = try MeshRoutedDrainItem.mint(rig, origin: origin, byteCount: 1_200)
        item.stage(into: rig, at: origin)
        rig.link(origin, first)
        return MeshCustodyChainScenario(rig: rig, item: item)
    }

    /// The ordinary drain across the one live link: the first hop holds the whole item, taken from
    /// the origin itself, and the origin holds its signed custody receipt.
    func drainToTheFirstHop() async throws {
        rig.commit(Self.origin, Self.first)
        try await rig.settle([Self.origin, Self.first], until: {
            rig.routedIndex(rig.nodes[Self.first])?.record(for: key)?.isComplete == true
        })
        try await rig.settle([Self.origin, Self.first], until: {
            rig.routedIndex(rig.nodes[Self.origin])?.record(for: key)?.receipts.isEmpty == false
        })
        #expect(rig.nodes[Self.first].manager.originServedItemsForTesting.contains(key),
                "the first hop took the manifest from the ORIGIN, so it may courier")
    }

    /// The origin develops with **no partition raised**, so its record names every other member.
    /// Its radio then stops, and nothing from it reaches anybody again.
    func developNamingEveryone(at base: Date) async throws {
        let plan = rig.plan(Self.origin, at: base)
        #expect(plan.ending == .departure, "merged roster 4 ⇒ a departure, never a termination")
        #expect(Set(plan.handoffTargets) == Set([Self.first, Self.second, Self.third].map {
            rig.nodes[$0].fingerprint
        }), "no branch view ⇒ the custodians are the whole roster minus the leaver")
        await rig.develop(
            Self.origin, clock: [base, base.addingTimeInterval(2), base.addingTimeInterval(2)]
        )
        try await rig.settle([Self.first], until: {
            MeshMergeFixtures.roster(rig.nodes[Self.first].manager).count == 3
        })
        rig.cut(Self.origin, Self.first)
    }

    /// The first hop serves the second — the second hop of the chain. An ORDERED heal with two
    /// commit rounds, so the leaver's record re-gossips and the bytes follow it.
    func serveTheSecondHop() async throws {
        rig.link(Self.first, Self.second)
        rig.commit(Self.first, Self.second)
        try await rig.settle([Self.first, Self.second], until: {
            rig.routedIndex(rig.nodes[Self.second])?.record(for: key)?.isComplete == true
        })
        rig.commit(Self.first, Self.second)
        try await rig.settle([Self.first, Self.second])
    }

    /// Ends every session so nothing outlives the scenario.
    func teardown() { rig.teardown() }

    /// ``MeshRoutedDrainRig/quiesce()``: end the sessions AND drain what the teardown could not
    /// cancel, while the stores are still alive.
    func quiesce() async { await rig.quiesce() }
}

// MARK: - The scenario suite

/// Plan §10.6's load-bearing case, end to end on the fake fabric.
@MainActor
@Suite(.serialized)
struct MeshRoutedCustodyHandoffTests {

    /// **Item 6's deferred D3, retired by name.** After the heal the destination holds the ORIGIN's
    /// bytes, byte for byte: a custodian forwards the origin's exact signed objects and is never a
    /// co-signer.
    @Test func aCustodianServesTheOriginsExactBytes() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-exact")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try await scenario.developInsideTheWindow(at: base)
        try await scenario.healTheDestinationToTheCustodian()

        let held = try #require(
            scenario.rig.routedIndex(scenario.rig.nodes[MeshCustodyHandoffScenario.destination])?
                .record(for: scenario.key)
        )
        let manifest = try #require(held.manifest)
        #expect(canonicalBytes(for: manifest) == canonicalBytes(for: scenario.item.manifest),
                "the origin's exact signed manifest, forwarded unchanged")
        #expect(manifest.signature == scenario.item.manifest.signature)
        #expect(held.chunks.count == scenario.item.chunks.count)
    }

    /// The rung `mayCourier` reads lives in the CUSTODIAN's own index — a transfer recorded only at
    /// the departing origin buys nothing after the heal.
    @Test func theCustodianHoldsTheRungTheOriginWrote() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-rung")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try await scenario.developInsideTheWindow(at: base)

        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.custodian, scenario.key
        )?.state(of: scenario.destinationFingerprint) == .custodied(by: scenario.custodianFingerprint),
                "the custodian claimed the leg the leaver's record entitled it to")
    }

    /// Both receipts land: the custodian's own durable custody, and the destination's final ack.
    @Test func theCustodyReceiptAndTheRecipientReceiptBothLand() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-receipts")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try await scenario.developInsideTheWindow(at: base)
        try await scenario.healTheDestinationToTheCustodian()

        let custodian = scenario.rig.routedIndex(
            scenario.rig.nodes[MeshCustodyHandoffScenario.custodian]
        )?.record(for: scenario.key)
        let destination = scenario.rig.routedIndex(
            scenario.rig.nodes[MeshCustodyHandoffScenario.destination]
        )?.record(for: scenario.key)
        #expect(custodian?.custodiedAt != nil, "the custodian's durable custody stands")
        let acked = destination?.recipientReceipts
            .contains { $0.recipientFingerprint == scenario.destinationFingerprint } == true
        #expect(acked, "the destination filed its own final ack")
    }

    /// **The one field P5 fills.** The signed count is what actually transferred, never the
    /// candidate count: a second item no custodian holds the bytes for is not counted.
    @Test func theDepartureRecordCountsWhatActuallyTransferred() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-count")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        // A second candidate the custodian has never seen: live, complete at the origin, with two
        // outstanding destinations — and no stored receipt, so nobody can be named its custodian.
        let orphan = try MeshRoutedDrainItem.mint(scenario.rig, origin: 0, byteCount: 1_500)
        orphan.stage(into: scenario.rig, at: 0)
        try await scenario.developInsideTheWindow(at: base)

        let departure = try #require(scenario.rig.departure(at: MeshCustodyHandoffScenario.custodian))
        #expect(departure.custodyHandoff.handedOffItemCount == 1,
                "one item transferred, two were candidates")
        let handoff = try #require(
            scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager.lastDevelopmentHandoff
        )
        #expect(handoff.unplacedItemKeys == [orphan.key],
                "the candidate nobody could take is named, not silently dropped")
    }

    /// A transfer inside the window is `.completed`, and the rung is written at the origin.
    @Test func aTransferInsideTheWindowCompletes() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-window")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try await scenario.developInsideTheWindow(at: base)

        let manager = scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager
        #expect(manager.lastDevelopmentHandoffOutcome == .completed)
        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.origin, scenario.key
        )?.state(of: scenario.destinationFingerprint) == .custodied(by: scenario.custodianFingerprint))
    }

    /// A window that closed before the transfer transfers **nothing**, writes no rung anywhere, and
    /// says so — never a silent zero.
    @Test func anExpiredWindowTransfersNothingAndSaysSo() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-expired")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        let expired = base.addingTimeInterval(15)
        await scenario.rig.develop(
            MeshCustodyHandoffScenario.origin, clock: [base, expired, expired]
        )
        try await scenario.rig.settle([MeshCustodyHandoffScenario.custodian])

        let manager = scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager
        #expect(manager.lastDevelopmentHandoffOutcome == .windowExpired)
        #expect(manager.lastDevelopmentHandoff?.transferredItemCount == 0)
        #expect(manager.lastDevelopmentHandoff?.suppression == .windowExpired,
                "a device that ran out of clock is not a device that held nothing")
        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.origin, scenario.key
        )?.state(of: scenario.destinationFingerprint) == .pending, "no rung was written")
        #expect(scenario.rig.departure(at: MeshCustodyHandoffScenario.custodian)?
            .custodyHandoff.handedOffItemCount == 0)
    }

    /// A reachable custodian that never took the bytes is **not** counted, and the item it could not
    /// place is named — a visible failure, never a silent skip.
    @Test func aCustodianThatNeverTookTheBytesIsNotCounted() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-nobytes")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        // No drain: the custodian holds nothing, so the origin stores no receipt from it.
        try await scenario.developInsideTheWindow(at: base)

        let handoff = try #require(
            scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager.lastDevelopmentHandoff
        )
        #expect(handoff.transferredItemCount == 0)
        #expect(handoff.unplacedItemKeys == [scenario.key])
    }

    /// A store that cannot say what it holds transfers nothing and says which state refused —
    /// **never** confused with a store that held nothing (plan §19.5).
    @Test func aStoreThatCannotSayWhatItHoldsTransfersNothingAndSaysSo() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-unreadable")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try MeshRoutedStoreFixtures.writeRaw(
            Data("not a sealed index".utf8),
            into: scenario.rig.routedStore(scenario.rig.nodes[MeshCustodyHandoffScenario.origin])
        )
        try await scenario.developInsideTheWindow(at: base)

        let handoff = try #require(
            scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager.lastDevelopmentHandoff
        )
        #expect(handoff.suppression == .storeUnavailable)
        #expect(handoff.transferredItemCount == 0)
        #expect(scenario.rig.departure(at: MeshCustodyHandoffScenario.custodian)?
            .custodyHandoff.handedOffItemCount == 0)
    }

    /// A partition of one develops alone: nobody is reachable, so nothing transfers and the outcome
    /// names it rather than reporting a completed handoff.
    @Test func nothingTransfersWhenNobodyIsReachable() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-alone")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        try await scenario.drainToTheCustodian()
        scenario.rig.raisePartition([[0], [1], [2]], at: base)
        await scenario.rig.develop(
            MeshCustodyHandoffScenario.origin,
            clock: [base, base.addingTimeInterval(1), base.addingTimeInterval(1)]
        )

        let manager = scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager
        #expect(manager.lastDevelopmentHandoffOutcome == .noReachableCustodian)
        #expect(manager.lastDevelopmentHandoff?.suppression == .noReachableCustodian)
        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.origin, scenario.key
        )?.state(of: scenario.destinationFingerprint) == .pending, "no rung was written")
    }

    /// **Increment 1's line, from the other side.** A full drain round between live members moves
    /// bytes and receipts and moves **no** `custodied(by:)` rung anywhere: only a development does.
    @Test func noTransferHappensBetweenTwoLiveMembers() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "h8-live")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.link(0, 2)
        rig.commit(0, 1)
        rig.commit(0, 2)
        try await rig.settle(until: {
            rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.isComplete == true
                && rig.routedIndex(rig.nodes[2])?.record(for: item.key)?.isComplete == true
        })
        try await rig.settle()

        for node in 0..<3 {
            guard let target = rig.target(node, item.key) else { continue }
            let custodied = target.destinations.contains {
                target.state(of: $0)?.token == .custodied
            }
            #expect(custodied == false, "node \(node) holds a custody rung nobody handed it")
        }
    }

    /// **No second hop, at the enumerator.** A departing CUSTODIAN hands off nothing: the required
    /// `originatedBy:` makes another origin's content unrepresentable at the departure.
    ///
    /// On a roster of FOUR, so the departing custodian's merged roster is still three: the ending is
    /// a departure and its custodian list is non-empty, which means neither the termination guard
    /// nor the empty-custodian guard can be what returns zero. The value-level pair beside it is the
    /// filter's own negative and positive control over one index.
    @Test func aDepartingCustodianHandsOffNothing() async throws {
        let scenario = try MeshCustodyChainScenario.build(label: "h8-second")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        try await scenario.drainToTheFirstHop()
        try await scenario.developNamingEveryone(at: base)
        let rig = scenario.rig
        let custodian = MeshCustodyChainScenario.first
        let plan = rig.plan(custodian, at: base)
        #expect(plan.ending == .departure, "merged roster 3 ⇒ a departure, never a termination")
        #expect(plan.handoffTargets.isEmpty == false,
                "and it has custodians to offer to, so the enumerator really runs")
        let manager = rig.nodes[custodian].manager
        // Sampled BEFORE the development: `leaveMesh` clears the verifier, and the value pair below
        // is about the enumerator, not about what a departed device remembers.
        let roster = try #require(manager.membershipVerifier?.roster)
        await rig.develop(
            custodian, clock: [base, base.addingTimeInterval(2), base.addingTimeInterval(2)]
        )
        // Drained before the assertions: a roster move queues a coordinator beacon per slot on its
        // own `Task`, and the manager reads its host store `unowned` — a task that outlives the rig
        // traps the whole test PROCESS, not just this cell.
        try await rig.settle()
        try await rig.settle()

        #expect(manager.lastDevelopmentHandoffOutcome == .completed,
                "neither the window nor an empty custodian list short-circuited the transfer")
        let handoff = try #require(manager.lastDevelopmentHandoff)
        #expect(handoff.transferredItemCount == 0, "a custodian is a courier, never a second origin")
        #expect(handoff.unplacedItemKeys.isEmpty, "it was not even a candidate")
        // The filter's own negative, and the positive control that makes it falsifiable: ONE index,
        // one instant, one roster — the only thing that differs is the origin.
        let index = try #require(rig.routedIndex(rig.nodes[custodian]))
        #expect(index.itemsAwaitingHandoff(
            at: base, in: roster, originatedBy: rig.nodes[custodian].fingerprint
        ).isEmpty, "an item this device did not mint is not a candidate for its own departure")
        #expect(index.itemsAwaitingHandoff(
            at: base, in: roster, originatedBy: rig.nodes[MeshCustodyChainScenario.origin].fingerprint
        ).isEmpty == false, "and the same index does enumerate it under its real origin")
        await scenario.quiesce()
    }

    /// **Exactly one transfer.** Re-running the transfer over an index whose legs are already
    /// `custodied` advances nothing: the only writer of the rung is this door, so a leg carrying one
    /// was already handed.
    @Test func aSecondDevelopmentTransfersNothing() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-once")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        let store = scenario.rig.routedStore(
            scenario.rig.nodes[MeshCustodyHandoffScenario.origin]
        )
        let receipt = try #require(
            scenario.rig.routedIndex(scenario.rig.nodes[MeshCustodyHandoffScenario.origin])?
                .record(for: scenario.key)?.receipts.first
        )
        let transfer = MeshRoutedCustodyHandoff(
            item: scenario.key,
            destinations: [scenario.destinationFingerprint],
            receipt: receipt
        )
        let outcomes = DeviceBindingID.$testOverride
            .withValue(.identifier(MeshP3Acceptance.install)) {
                (
                    first: store.recordingCustodyHandoff([transfer], now: MeshRoutedDrainRig.now),
                    second: store.recordingCustodyHandoff([transfer], now: MeshRoutedDrainRig.now)
                )
            }
        #expect(outcomes.first.value?.advanced == [scenario.key])
        #expect(outcomes.second.value?.advanced.isEmpty == true,
                "a leg already custodied is never re-handed")
    }

    /// A leg that already reached `delivered` is not walked backwards by the hand-off: the custodian
    /// is its own destination here, and the transfer never names it.
    @Test func aDeliveredLegIsNotWalkedBackwardsByTheHandoff() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-delivered")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        let before = scenario.rig.target(MeshCustodyHandoffScenario.origin, scenario.key)?
            .state(of: scenario.custodianFingerprint)
        try await scenario.developInsideTheWindow(at: base)

        #expect(before == .delivered, "the custodian's own leg closed in the ordinary drain")
        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.origin, scenario.key
        )?.state(of: scenario.custodianFingerprint) == .delivered,
                "the batch left the closed leg exactly where it was")
    }

    /// **R9's positive half.** A transfer built over `pending` legs never refuses: the four
    /// ``MeshDeliveryRefusal`` cases are unreachable by construction, and the audit stream carries no
    /// refusal line.
    @Test func aTransferOverPendingLegsNeverRefuses() async throws {
        let audit = MeshCustodyHandoffAudit()
        audit.install()
        defer { audit.uninstall() }
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-norefusal")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try await scenario.developInsideTheWindow(at: base)

        // The observable half first: every candidate was placed, which is what "no refusal"
        // means at the seam that signs the count. The audit line is the secondary claim —
        // `FernletAuditLog` is process-global, so only a NEGATIVE assertion is safe there, and no
        // other suite has routed content at a development to refuse.
        let handoff = try #require(
            scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager.lastDevelopmentHandoff
        )
        #expect(handoff.transferredItemCount == 1)
        #expect(handoff.unplacedItemKeys.isEmpty, "nothing was left unplaced, so nothing refused")
        #expect(audit.logged("mesh.development.handoffRefused") == false,
                "the caller owes a refusal-free list, and it delivered one")
    }

    /// A destination that departed first is derived out by `outstanding(in:)`, so it appears in no
    /// transfer and in no claim — the roster closed it, and the drain stops rather than backing off.
    @Test func aDepartedDestinationIsNeverHandedOff() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "h8-departed")
        defer { rig.teardown() }
        let item = try MeshRoutedDrainItem.mint(rig, origin: 0)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle([0, 1], until: {
            rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.isComplete == true
        })
        let base = MeshRoutedDrainRig.createdAt
        // Node 2 leaves the mesh for real, so the origin's roster no longer names it.
        rig.link(0, 2)
        rig.commit(0, 2)
        await rig.develop(2, clock: [base, base.addingTimeInterval(1), base.addingTimeInterval(1)])
        try await rig.settle([0, 1], until: {
            MeshMergeFixtures.roster(rig.nodes[0].manager).count == 2
        })
        await rig.develop(0, clock: [base, base.addingTimeInterval(2), base.addingTimeInterval(2)])

        let handoff = try #require(rig.nodes[0].manager.lastDevelopmentHandoff)
        #expect(handoff.transferredItemCount == 0,
                "the only outstanding destination had departed, so nothing was owed")
        #expect(rig.target(0, item.key)?.state(of: rig.nodes[2].fingerprint) == .pending,
                "the stored state is untouched; departed is DERIVED at read")
    }

    /// **Q7.** A leaver the mesh removed grants nothing: a removal is the statement that this
    /// member's word no longer counts, and retention on it would let an ejected device park content
    /// across the mesh.
    @Test func aCustodianNamedByARemovedMembersRecordClaimsNothing() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-removed")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        let custodianNode = scenario.rig.nodes[MeshCustodyHandoffScenario.custodian]
        // A real, quorum-shaped removal of the origin, signed by the custodian and folded into its
        // own ledger BEFORE the departure record arrives.
        let removal = try SignedRemovalRecord.signed(
            meshID: scenario.rig.meshID,
            identity: scenario.rig.identities[MeshCustodyHandoffScenario.custodian],
            memberFingerprint: scenario.rig.nodes[MeshCustodyHandoffScenario.origin].fingerprint,
            proposalID: UUID(),
            voterFingerprints: [custodianNode.fingerprint, scenario.destinationFingerprint],
            occurredAt: base
        )
        var ledger = MeshMembershipLedger.empty
        ledger.removals = ledger.removals.inserting(removal)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            custodianNode.manager.mergeMembershipLedger(ledger, now: base)
        }
        #expect(custodianNode.manager.membershipVerifier?.ledger.removals.count == 1,
                "the removal really was accepted")
        await scenario.rig.develop(
            MeshCustodyHandoffScenario.origin,
            clock: [base, base.addingTimeInterval(3), base.addingTimeInterval(3)]
        )
        try await scenario.rig.settle(
            [MeshCustodyHandoffScenario.origin, MeshCustodyHandoffScenario.custodian]
        )

        // Both records are folded, and every other gate is open. The claim is then run at its own
        // seam: a departure of an ALREADY-removed member moves no derived roster, so no shipping
        // door evaluates it on this ordering — and a gate whose only cell never reaches it is a gate
        // with no coverage at all.
        #expect(custodianNode.manager.membershipVerifier?.ledger.departures.count == 1,
                "the departure record really was folded")
        #expect(custodianNode.manager.originServedItemsForTesting.contains(scenario.key),
                "and the item is origin-served, so the hop bound is not what refuses it")
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            custodianNode.manager.claimHandedOffCustodyForTesting(now: base)
        }

        try await scenario.rig.settle()
        try await scenario.rig.settle()

        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.custodian, scenario.key
        )?.state(of: scenario.destinationFingerprint) == .pending,
                "a removed member's departure record entitles nobody")
        await scenario.quiesce()
    }

    /// The claim is one idempotent derivation, not an event hook: applying it twice leaves one
    /// custodian and one rung, and the second pass writes nothing.
    @Test func theCustodianClaimIsIdempotent() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-idempotent")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try await scenario.developInsideTheWindow(at: base)
        let custodianNode = scenario.rig.nodes[MeshCustodyHandoffScenario.custodian]
        let store = scenario.rig.routedStore(custodianNode)
        let claim = MeshRoutedHandoffClaim(
            item: scenario.key,
            destinations: [scenario.destinationFingerprint],
            custodian: custodianNode.fingerprint
        )
        let second = DeviceBindingID.$testOverride
            .withValue(.identifier(MeshP3Acceptance.install)) {
                store.claimingHandedOffLegs([claim], now: MeshRoutedDrainRig.now)
            }

        #expect(second.value?.advanced.isEmpty == true, "the second application writes nothing")
        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.custodian, scenario.key
        )?.state(of: scenario.destinationFingerprint)
            == .custodied(by: scenario.custodianFingerprint), "and the one rung still stands")
    }

    /// **D-8.14's deferral, made real.** The durable commit is capped per evaluation because it
    /// re-streams and re-hashes whole items — but the overflow cannot be re-*planned*, since after a
    /// claim no named leg is `pending`. It is therefore carried and drained at the next evaluation:
    /// without that queue the deferral is permanent, and the items over the cap would never get a
    /// `custodiedAt`, an advertised custody signer, or a forwardable receipt.
    ///
    /// Every item is addressed to node 2 alone, so node 1 is a **pure courier**: nothing commits its
    /// custody except the claim, which is what makes `custodiedAt` the measurement.
    @Test func theDeferredCustodyCommitIsRetriedAtTheNextEvaluation() async throws {
        let audit = MeshCustodyHandoffAudit()
        audit.install()
        defer { audit.uninstall() }
        let cap = MeshRoutedDrainBounds.increment1.maxItems
        let rig = try MeshRoutedDrainRig.build(3, label: "h8-deferred")
        defer { rig.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        rig.link(0, 1)
        var keys: [MeshRoutedItemKey] = []
        // R2: bounded by the per-evaluation cap plus one — exactly one item more than a single
        // evaluation may durably commit. The origin forwards each one itself, so every manifest is
        // origin-served and the hop bound is open.
        for _ in 0...cap {
            let item = try MeshCustodyHandoffFixtures.narrowedItem(
                rig, origin: 0, destination: 2, byteCount: 200
            )
            item.stage(into: rig, at: 0)
            let chunk = try #require(item.chunks.first)
            #expect(item.chunks.count == 1, "one chunk per item keeps this cell about the cap")
            // `dispatch`, not `deliver`: one settle at the end rather than thirty-four, because the
            // main actor is shared with every other suite in this process and a starved one lands
            // its async sends after its own rig is gone.
            try rig.dispatch(
                MeshRoutedManifestPayload(manifest: item.manifest),
                type: .meshRoutedManifest, sender: 0, receiver: 1
            )
            try rig.dispatch(
                MeshChunkPayload(chunk: chunk), type: .meshRoutedChunk, sender: 0, receiver: 1
            )
            keys.append(item.key)
        }
        try await rig.settle([0, 1])
        #expect(keys.allSatisfy {
            rig.routedIndex(rig.nodes[1])?.record(for: $0)?.isComplete == true
        }, "the courier must hold every item before the departure")
        #expect(keys.allSatisfy {
            rig.routedIndex(rig.nodes[1])?.record(for: $0)?.custodiedAt == nil
        }, "a pure courier commits nothing until the claim: that is what makes this measurable")
        await rig.develop(0, clock: [base, base.addingTimeInterval(2), base.addingTimeInterval(2)])
        try await rig.settle([1], until: { MeshMergeFixtures.roster(rig.nodes[1].manager).count == 2 })

        let manager = rig.nodes[1].manager
        #expect(keys.allSatisfy {
            rig.target(1, $0)?.state(of: rig.nodes[2].fingerprint)
                == .custodied(by: rig.nodes[1].fingerprint)
        }, "the RUNGS are uncapped — one save, and they are cheap")
        #expect(audit.logged("mesh.development.handoffCommitDeferred"),
                "the cap was never reached: \(audit.events(prefix: "mesh.development"))")
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.claimHandedOffCustodyForTesting(now: base)
        }

        try await rig.settle([0, 1])
        try await rig.settle([0, 1])
        #expect(manager.deferredCustodyCommitCountForTesting == 0, "the queue drained")
        let committed = keys.filter {
            rig.routedIndex(rig.nodes[1])?.record(for: $0)?.custodiedAt != nil
        }
        #expect(committed.count == keys.count,
                "\(keys.count - committed.count) item(s) were claimed and never committed")
        await rig.quiesce()
    }

    /// **R8.** Custody depends on no membership window at all: a development with a merge window
    /// open still writes the rung and signs the count.
    @Test func theTransferNeverWaitsOnAMembershipWindowClosing() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-window-open")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        scenario.rig.commit(MeshCustodyHandoffScenario.origin, MeshCustodyHandoffScenario.custodian)
        let manager = scenario.rig.nodes[MeshCustodyHandoffScenario.origin].manager
        #expect(manager.awaitingResumeMerge, "a merge window is open at the moment of the departure")
        await scenario.rig.develop(
            MeshCustodyHandoffScenario.origin,
            clock: [base, base.addingTimeInterval(3), base.addingTimeInterval(3)]
        )

        #expect(manager.lastDevelopmentHandoff?.transferredItemCount == 1,
                "an open window neither delayed nor blocked the transfer")
    }

    /// **The hop-depth measurement (§4.2a).** The second-hop holder — a destination that took the
    /// bytes from the custodian rather than from the origin — writes **no** custody rung of its own,
    /// because the manifest did not come from the origin.
    @Test func aSecondHopHolderClaimsNothing() async throws {
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-hop")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        try await scenario.developInsideTheWindow(at: base)
        try await scenario.healTheDestinationToTheCustodian()

        let target = try #require(
            scenario.rig.target(MeshCustodyHandoffScenario.destination, scenario.key)
        )
        let claimed = target.destinations.contains {
            target.state(of: $0) == .custodied(by: scenario.destinationFingerprint)
        }
        #expect(claimed == false,
                "the origin never served this device the manifest, so it may courier nothing")
        #expect(scenario.rig.nodes[MeshCustodyHandoffScenario.destination]
            .manager.originServedItemsForTesting.contains(scenario.key) == false,
                "a manifest forwarded by a custodian never enters the origin-served set")
        await scenario.quiesce()
    }

    /// **The hop bound, measured where the record cannot be what refuses it (§4.2a, D-8.17).**
    ///
    /// No partition at the development, so the leaver's own record names the second hop a custodian
    /// too — the production shape. The second hop holds the origin's complete item and has an
    /// outstanding `pending` leg to a fourth member, so every gate the claim applies is open except
    /// the origin-served one. It claims nothing; one hop from the origin, the identical mechanism
    /// did fire, which is what makes this a measurement rather than a dead path.
    @Test func aSecondHopHolderNamedACustodianStillClaimsNothing() async throws {
        let scenario = try MeshCustodyChainScenario.build(label: "h8-chain")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        try await scenario.drainToTheFirstHop()
        try await scenario.developNamingEveryone(at: base)
        try await scenario.serveTheSecondHop()
        let rig = scenario.rig
        let second = rig.nodes[MeshCustodyChainScenario.second].fingerprint
        let third = rig.nodes[MeshCustodyChainScenario.third].fingerprint

        // The first hop DID claim — the positive control, one hop from the origin.
        #expect(rig.target(MeshCustodyChainScenario.first, scenario.key)?.state(of: third)
                == .custodied(by: rig.nodes[MeshCustodyChainScenario.first].fingerprint),
                "the first hop claims: this is the mechanism the second hop is denied")
        // Every other gate is open at the second hop.
        let record = try #require(rig.departure(at: MeshCustodyChainScenario.second),
                                  "the leaver's record must have re-gossiped this far")
        #expect(record.custodyHandoff.custodianFingerprints.contains(second),
                "the leaver's own record NAMES this device, so the record guard cannot refuse it")
        #expect(rig.routedIndex(rig.nodes[MeshCustodyChainScenario.second])?
            .record(for: scenario.key)?.isComplete == true,
                "and it holds the complete item, so completeness cannot refuse it either")
        #expect(rig.target(MeshCustodyChainScenario.second, scenario.key)?.state(of: third)
                == .pending, "with a pending leg the planner would otherwise have taken")

        #expect(rig.nodes[MeshCustodyChainScenario.second]
            .manager.originServedItemsForTesting.contains(scenario.key) == false,
                "the manifest came from the first hop, never from the origin")
        let target = try #require(rig.target(MeshCustodyChainScenario.second, scenario.key))
        let claimed = target.destinations.contains {
            target.state(of: $0) == .custodied(by: second)
        }
        #expect(claimed == false, "the content walked A→B→C and C became a courier: that is A→B→C→D")
        await scenario.quiesce()
    }

    /// **The merge door's order.** A merge that hands this device its own removal ejects it BEFORE
    /// the claim runs — so an ejected device never writes custody rungs, and never re-streams up to
    /// a per-answer allowance of items for a mesh it is no longer in.
    @Test func aMergeThatEjectsThisDeviceClaimsNothing() async throws {
        let audit = MeshCustodyHandoffAudit()
        audit.install()
        defer { audit.uninstall() }
        let scenario = try MeshCustodyChainScenario.build(label: "h8-ejected")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        try await scenario.drainToTheFirstHop()
        let rig = scenario.rig
        let custodian = rig.nodes[MeshCustodyChainScenario.first]
        // The origin's departure reaches this device only as a MERGED record, in the very ledger
        // that carries this device's own removal. Roster 4 ⇒ after the departure the merged roster
        // is three and quorum two, so the two surviving voters really do carry the removal.
        let departure = try SignedDepartureRecord.signed(
            meshID: rig.meshID,
            identity: rig.identities[MeshCustodyChainScenario.origin],
            occurredAt: base,
            custodyHandoff: MeshCustodyHandoffSummary(
                custodianFingerprints: [custodian.fingerprint], handedOffItemCount: 1
            )
        )
        let removal = try SignedRemovalRecord.signed(
            meshID: rig.meshID,
            identity: rig.identities[MeshCustodyChainScenario.second],
            memberFingerprint: custodian.fingerprint,
            proposalID: UUID(),
            voterFingerprints: [rig.nodes[MeshCustodyChainScenario.second].fingerprint,
                                rig.nodes[MeshCustodyChainScenario.third].fingerprint],
            occurredAt: base
        )
        var ledger = MeshMembershipLedger.empty
        ledger.departures = ledger.departures.inserting(departure)
        ledger.removals = ledger.removals.inserting(removal)
        let rejections = DeviceBindingID.$testOverride
            .withValue(.identifier(MeshP3Acceptance.install)) {
                custodian.manager.mergeMembershipLedger(ledger, now: base)
            }

        try await rig.settle()
        try await rig.settle()
        #expect(rejections.isEmpty, "both records had to be ACCEPTED: \(rejections)")
        #expect(audit.logged("mesh.membershipEvent.selfRemoved"),
                "the merge really did eject this device: \(audit.events(prefix: "mesh.membership"))")
        let target = try #require(rig.target(MeshCustodyChainScenario.first, scenario.key))
        let claimed = target.destinations.contains {
            target.state(of: $0) == .custodied(by: custodian.fingerprint)
        }
        #expect(claimed == false, "a device the merge ejected wrote a custody rung anyway")
        await scenario.quiesce()
    }

    /// **GAP-4 shape B's proof.** A custodian that is not a destination and has never seen the item
    /// takes the bytes on the departure push, claims on the leaver's record, and serves the real
    /// destination after the heal.
    @Test func aPureCourierCustodianTakesTheBytesInsideTheWindow() async throws {
        let rig = try MeshRoutedDrainRig.build(3, label: "h8-courier")
        defer { rig.teardown() }
        let item = try MeshCustodyHandoffFixtures.narrowedItem(rig, origin: 0, destination: 2)
        #expect(item.manifest.destinations == [rig.nodes[2].fingerprint],
                "the custodian is deliberately NOT a destination")
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle([0, 1])
        let base = MeshRoutedDrainRig.createdAt
        rig.raisePartition([[0, 1], [2]], at: base)
        await rig.develop(0, clock: [base, base.addingTimeInterval(1), base.addingTimeInterval(2)])
        try await rig.settle([1], until: {
            rig.routedIndex(rig.nodes[1])?.record(for: item.key)?.isComplete == true
        })
        rig.cut(0, 1)

        let handoff = try #require(rig.nodes[0].manager.lastDevelopmentHandoff)
        #expect(handoff.pushedItemKeys == [item.key], "no custodian held it, so it goes on the push")
        #expect(rig.contentFrames(at: 1, from: 0) > 0, "the push put the origin's bytes on the wire")
        #expect(rig.routedIndex(rig.nodes[1])?.record(for: item.key) != nil,
                "the courier admitted the origin's own forward")
        #expect(rig.target(1, item.key)?.state(of: rig.nodes[2].fingerprint)
                == .custodied(by: rig.nodes[1].fingerprint),
                "the pure courier admitted the origin's push and claimed on the record")
        rig.link(1, 2)
        rig.commit(1, 2)
        try await rig.settle([1, 2], until: {
            rig.routedIndex(rig.nodes[2])?.record(for: item.key)?.isComplete == true
        })
        let held = try #require(rig.routedIndex(rig.nodes[2])?.record(for: item.key)?.manifest)
        #expect(canonicalBytes(for: held) == canonicalBytes(for: item.manifest),
                "the destination got the origin's exact bytes, through a device it never met")
    }

    /// **D-8.21's value contract.** Rungs written for custodians no record will ever name are
    /// reported **unplaced**, and the push list empties: bytes pushed to a device that will never be
    /// told it is a custodian are retention with no delivery.
    @Test func aRecordThatWasNeverEmittedIsNotCountedAsTransferred() throws {
        let keys = [
            MeshRoutedItemKey(originFingerprint: "fpOrigin", itemID: UUID()),
            MeshRoutedItemKey(originFingerprint: "fpOrigin", itemID: UUID())
        ]
        let announced = MeshCustodyHandoffResult(
            transferredItemKeys: [keys[0]], unplacedItemKeys: [keys[1]],
            pushedItemKeys: [keys[1]], unrestorableCount: 0, suppression: nil
        )
        let silent = announced.notAnnounced()

        #expect(silent.transferredItemCount == 0, "a count nobody was told is not a transfer")
        #expect(Set(silent.unplacedItemKeys) == Set(keys))
        #expect(silent.pushedItemKeys.isEmpty, "and no bytes chase a custodian nobody named")
        #expect(silent.suppression == .recordNotEmitted)
    }

    /// **The fourth claim door.** A custodian whose store could not be read when the departure
    /// record folded claims at the next drain exchange — with no new roster move and no item
    /// becoming complete, which is exactly what the other three doors need.
    @Test func aDeferredStoreClaimsAtTheNextDrainExchange() async throws {
        let audit = MeshCustodyHandoffAudit()
        audit.install()
        defer { audit.uninstall() }
        let scenario = try MeshCustodyHandoffScenario.build(label: "h8-fourth")
        defer { scenario.teardown() }
        let base = MeshRoutedDrainRig.createdAt
        scenario.splitAwayTheDestination(at: base)
        try await scenario.drainToTheCustodian()
        let custodianNode = scenario.rig.nodes[MeshCustodyHandoffScenario.custodian]
        let store = scenario.rig.routedStore(custodianNode)
        let sealed = try Data(contentsOf: store.indexURL)
        try MeshRoutedStoreFixtures.writeRaw(Data("unreadable".utf8), into: store)
        try await scenario.developInsideTheWindow(at: base)
        #expect(scenario.rig.routedIndex(custodianNode) == nil, "the store said nothing at the fold")

        try MeshRoutedStoreFixtures.writeRaw(sealed, into: store)
        #expect(scenario.rig.target(
            MeshCustodyHandoffScenario.custodian, scenario.key
        )?.state(of: scenario.destinationFingerprint) == .pending, "still no rung")
        try await scenario.healTheDestinationToTheCustodian()
        #expect(scenario.rig.tokens(
            at: MeshCustodyHandoffScenario.custodian,
            from: MeshCustodyHandoffScenario.destination
        ).contains(PayloadType.meshRoutedInventoryDigest.rawValue),
                "the drain exchange really did reach the custodian")

        // The rung moved, and the only device that could have moved it is this one: a courier
        // serves nothing until `mayCourier` reads a `custodied(by: self)` rung, so the destination
        // holding the origin's complete item IS the claim having fired at the exchange door.
        let state = scenario.rig.target(
            MeshCustodyHandoffScenario.custodian, scenario.key
        )?.state(of: scenario.destinationFingerprint)
        #expect(state != .pending, "\(audit.events(prefix: "mesh.development"))")
        #expect(scenario.rig.routedIndex(
            scenario.rig.nodes[MeshCustodyHandoffScenario.destination]
        )?.record(for: scenario.key)?.isComplete == true,
                "the destination got the origin's bytes through the custodian's claimed leg")
        let served = scenario.rig.routedIndex(
            scenario.rig.nodes[MeshCustodyHandoffScenario.destination]
        )?.record(for: scenario.key)?.manifest
        #expect(served.map { canonicalBytes(for: $0) }
                == canonicalBytes(for: scenario.item.manifest),
                "and what it served was the origin's exact signed manifest")
    }

    /// **D-8.22.** The push is bounded by the plan's own deadline, re-read per custodian: a frame
    /// cap is not a time bound. The custodian the window did not reach gets zero frames, and the
    /// already-signed count is unaffected.
    @Test func thePushStopsAtTheWindowDeadline() async throws {
        let audit = MeshCustodyHandoffAudit()
        audit.install()
        defer { audit.uninstall() }
        let rig = try MeshRoutedDrainRig.build(4, label: "h8-deadline")
        defer { rig.teardown() }
        // Addressed to node 3 alone, so nodes 1 and 2 are PURE COURIERS: the ordinary drain offers
        // them nothing and every byte they receive came from the departure push.
        let item = try MeshCustodyHandoffFixtures.narrowedItem(rig, origin: 0, destination: 3)
        item.stage(into: rig, at: 0)
        rig.link(0, 1)
        rig.link(0, 2)
        rig.commit(0, 1)
        rig.commit(0, 2)
        try await rig.settle([0, 1, 2])
        let base = MeshRoutedDrainRig.createdAt
        rig.raisePartition([[0, 1, 2], [3]], at: base)
        await rig.develop(0, clock: [
            base, base.addingTimeInterval(1), base.addingTimeInterval(2),
            base.addingTimeInterval(16)
        ])
        try await rig.settle([1, 2])

        let served = [1, 2].filter { rig.contentFrames(at: $0, from: 0) > 0 }
        #expect(served.count == 1, "the second custodian was past the deadline: \(served)")
        #expect(audit.logged("mesh.development.handoffPushDeadline"))
        #expect(rig.nodes[0].manager.lastDevelopmentHandoff?.transferredItemCount == 0,
                "nothing had a stored receipt, so nothing was ever counted")
    }
}

// MARK: - Fixtures for the narrowed (pure-courier) item

/// Item shapes item 8 needs that the drain's own fixture does not mint.
@MainActor
enum MeshCustodyHandoffFixtures {

    /// An item addressed to ONE named node, built from a two-member sub-ledger of the rig's own
    /// mesh — the trick `aManifestAddressedElsewhereIsRefused` uses, so a third node is neither the
    /// origin nor a destination and can only ever hold the bytes as a pure courier.
    static func narrowedItem(
        _ rig: MeshRoutedDrainRig, origin: Int, destination: Int, byteCount: Int = 1_200
    ) throws -> MeshRoutedDrainItem {
        let signer = rig.identities[origin]
        let pair = try MeshPartitionFixtures.ledger(
            founder: signer, others: [rig.identities[destination]], meshID: rig.meshID
        )
        let target = MeshDeliveryTarget(
            contentID: UUID(), roster: pair.derivedRoster, selfFingerprint: signer.localFingerprint
        )
        let payload = MeshRoutedCustodyFixtures.blob(byteCount: byteCount)
        let manifest = try MeshRoutedManifest.signed(
            meshID: rig.meshID,
            target: target,
            typeToken: MeshRoutedTypeToken.photo,
            contentHash: MeshRoutedContentDigest.contentHash(of: payload),
            size: UInt64(payload.count),
            createdAt: MeshRoutedDrainRig.createdAt.addingTimeInterval(60),
            hardDeadline: MeshRoutedDrainRig.hardDeadline,
            contentKey: Data(repeating: 0x51, count: 32),
            recipientKeys: [
                rig.nodes[destination].fingerprint:
                    rig.identities[destination].localKeyAgreementPublicKey
            ],
            identity: signer
        )
        return MeshRoutedDrainItem(
            manifest: manifest,
            chunks: try MeshChunker.chunks(of: payload, for: manifest, identity: signer)
        )
    }
}

// MARK: - The store doors, with no manager at all

/// The two batch doors' own rules: one load, N updates, one save, and three lists that never
/// collapse into each other.
@MainActor
@Suite(.serialized)
struct MeshRoutedCustodyHandoffDoorTests {

    private typealias Fixture = MeshRoutedStoreFixtures

    /// One call advances every item's rung, and every one survives the single save.
    @Test func aBatchTransferWritesEveryRungInOneSave() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let first = try MeshRoutedCustodyFixtures.rig(scope: scope)
        let second = try MeshRoutedCustodyFixtures.rig(scope: scope)
        let transfers = [
            MeshRoutedCustodyHandoff(
                item: first.key, destinations: first.otherDestinations,
                receipt: try MeshRoutedCustodyFixtures.receipt(first)
            ),
            MeshRoutedCustodyHandoff(
                item: second.key, destinations: second.otherDestinations,
                receipt: try MeshRoutedCustodyFixtures.receipt(second)
            )
        ]
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            first.store.recordingCustodyHandoff(transfers, now: Fixture.now)
        }

        #expect(outcome.value?.advanced.count == 2, "\(outcome)")
        let index = try #require(MeshRoutedCustodyFixtures.loadedIndex(first.store))
        for transfer in transfers {
            let target = try #require(index.record(for: transfer.item)?.deliveryTarget)
            let custodian = transfer.receipt.custodianFingerprint
            let moved = transfer.destinations.allSatisfy {
                target.state(of: $0) == .custodied(by: custodian)
            }
            #expect(moved, "one save carried every rung the batch planned")
        }
    }

    /// A per-item refusal skips **that** item: nothing about one item's receipt says anything about
    /// another's, so the batch continues and the refusal is named.
    @Test func aRefusedItemDoesNotAbortTheBatch() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(scope: scope)
        let receipt = try MeshRoutedCustodyFixtures.receipt(rig)
        let stranger = MeshRoutedItemKey(originFingerprint: "fpNobody", itemID: UUID())
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.recordingCustodyHandoff(
                [
                    MeshRoutedCustodyHandoff(
                        item: stranger, destinations: rig.otherDestinations, receipt: receipt
                    ),
                    MeshRoutedCustodyHandoff(
                        item: rig.key, destinations: rig.otherDestinations, receipt: receipt
                    )
                ],
                now: Fixture.now
            )
        }

        #expect(outcome.value?.advanced == [rig.key])
        #expect(outcome.value?.refused.map(\.refusal) == [.store(.unknownItem)])
        #expect(outcome.value?.refused.map(\.item) == [stranger])
    }

    /// **A delivery-level refusal keeps its own name.** `advancingAll` refuses the whole item at the
    /// first ladder refusal and applies nothing, so reporting it as `unchanged` would make a caller
    /// bug indistinguishable from "every leg was already where the door would have put it" — and it
    /// would reach no report and no audit line at all.
    @Test func aDeliveryLevelRefusalIsNamedRatherThanCalledUnchanged() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(
            scope: scope, typeToken: MeshRoutedTypeToken.photo
        )
        MeshRoutedCustodyFixtures.stageAll(rig)
        _ = MeshRoutedCustodyFixtures.commit(rig)
        let commit = MeshRoutedCustodyFixtures.commitDelivery(rig)
        let witness = try #require(MeshRoutedCustodyFixtures.deliveryWitness(commit), "\(commit)")
        let receipt = try MeshRecipientReceipt.signed(
            witness: witness, manifest: rig.manifest, identity: rig.custodian
        )
        let closed = rig.custodian.localFingerprint
        let filed = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.recordingRecipientReceipt(item: rig.key, receipt: receipt, now: Fixture.now)
        }
        #expect(filed.value?.target != nil, "the leg must actually reach `delivered`: \(filed)")
        #expect(MeshRoutedCustodyFixtures.loadedIndex(rig.store)?
            .record(for: rig.key)?.deliveryTarget?.state(of: closed) == .delivered)
        // A caller bug by construction: naming another member the courier for a leg that is already
        // terminal. The ladder refuses it, and the batch must say which refusal that was.
        let courier = try #require(rig.otherDestinations.first)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.claimingHandedOffLegs(
                [MeshRoutedHandoffClaim(
                    item: rig.key, destinations: [closed], custodian: courier
                )],
                now: Fixture.now
            )
        }

        #expect(outcome.value?.refused.map(\.refusal) == [.delivery(.alreadyDelivered)], "\(outcome)")
        #expect(outcome.value?.advanced.isEmpty == true, "and nothing was written")
        #expect(outcome.value?.incomplete.isEmpty == true, "a refusal is not a 'not yet'")
    }

    /// A store that cannot be read writes nothing at all — not even the items it could have taken.
    @Test func anUnavailableStoreWritesNothing() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(scope: scope)
        let receipt = try MeshRoutedCustodyFixtures.receipt(rig)
        try Fixture.writeRaw(Data("not a sealed index".utf8), into: rig.store)
        let before = Fixture.snapshot(scope)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.recordingCustodyHandoff(
                [MeshRoutedCustodyHandoff(
                    item: rig.key, destinations: rig.otherDestinations, receipt: receipt
                )],
                now: Fixture.now
            )
        }

        #expect(outcome.unavailability != nil, "\(outcome)")
        #expect(Fixture.snapshot(scope) == before, "an unreadable store was written to anyway")
    }

    /// "Not yet" is not a refusal: an incomplete item has no ``MeshRoutedStoreRefusal`` spelling, so
    /// it rides its own list and is retried when the item completes.
    @Test func aClaimNamesAnIncompleteItemInItsOwnList() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(scope: scope)
        DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            #expect(rig.store.admittingManifest(rig.manifest, now: Fixture.now).value != nil)
        }
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.claimingHandedOffLegs(
                [MeshRoutedHandoffClaim(
                    item: rig.key, destinations: rig.otherDestinations,
                    custodian: rig.custodian.localFingerprint
                )],
                now: Fixture.now
            )
        }

        #expect(outcome.value?.incomplete == [rig.key])
        #expect(outcome.value?.refused.isEmpty == true, "not yet is not a refusal")
        #expect(outcome.value?.advanced.isEmpty == true)
    }

    /// The claim is receipt-free: a record's evidence set holds OTHER members' receipts, and this
    /// device's own custody is `custodiedAt` plus a re-mint on demand.
    @Test func aClaimStoresNoReceiptOfItsOwn() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(scope: scope)
        MeshRoutedCustodyFixtures.stageAll(rig)
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            rig.store.claimingHandedOffLegs(
                [MeshRoutedHandoffClaim(
                    item: rig.key, destinations: rig.otherDestinations,
                    custodian: rig.custodian.localFingerprint
                )],
                now: Fixture.now
            )
        }

        #expect(outcome.value?.advanced == [rig.key], "\(outcome)")
        let record = try #require(MeshRoutedCustodyFixtures.loadedIndex(rig.store)?.record(for: rig.key))
        #expect(record.receipts.isEmpty, "the claim burned no evidence slot on a self-receipt")
        #expect(record.custodiedAt == nil, "and it committed nothing: the rung is not the commit")
    }

    /// A parked item — chunks with no manifest — answers `manifestMismatch` by name, the same answer
    /// the single-item transfer door gives.
    @Test func aParkedItemAnswersManifestMismatch() throws {
        let scope = Fixture.scope()
        defer { Fixture.tearDown(scope) }
        let rig = try MeshRoutedCustodyFixtures.rig(scope: scope)
        let receipt = try MeshRoutedCustodyFixtures.receipt(rig)
        let parkedScope = Fixture.scope()
        defer { Fixture.tearDown(parkedScope) }
        let parked = MeshRoutedStore(scope: parkedScope)
        DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            for chunk in rig.chunks {
                #expect(parked.stagingChunk(chunk, now: Fixture.now).value != nil)
            }
        }
        let outcome = DeviceBindingID.$testOverride.withValue(.identifier(Fixture.installA)) {
            parked.recordingCustodyHandoff(
                [MeshRoutedCustodyHandoff(
                    item: rig.key, destinations: rig.otherDestinations, receipt: receipt
                )],
                now: Fixture.now
            )
        }

        #expect(outcome.value?.refused.map(\.refusal) == [.store(.manifestMismatch)], "\(outcome)")
        #expect(outcome.value?.advanced.isEmpty == true)
    }

    /// **The cell that would have caught the memberwise-initializer bypass.** The push batch goes
    /// through the drain's narrowing initializer, so a maximal local index still fits inside the
    /// per-answer bounds instead of charging a thousand frames to send sixty-four.
    @Test func aPushBatchNeverExceedsTheDrainFrameBound() throws {
        let index = Self.bulkyIndex(items: 40, chunks: 100)
        let meshID = MeshRoutedManifestFixtures.meshID
        let local = try #require(MeshRoutedInventory(
            meshID: meshID, index: index, selfFingerprint: "fpSelf", at: Fixture.now
        ))
        let bounds = MeshRoutedDrainBounds.increment1
        let batch = try #require(MeshCustodyHandoffPlan.pushBatch(
            local: local,
            remote: MeshRoutedInventory(meshID: meshID, members: [], entries: []),
            offerable: Set(index.items.map(\.key)),
            refused: [],
            frameAllowance: bounds.maxFrames
        ))

        #expect(batch.frameCount <= bounds.maxFrames, "\(batch.frameCount) frames planned")
        #expect(batch.manifests.count <= bounds.maxItems)
        #expect(batch.chunks.reduce(0) { $0 + $1.indices.count } <= bounds.maxChunksPerAnswer)
        #expect(batch.truncated, "the remainder is owed, not lost")
    }

    /// A synthetic index of `items` complete, manifest-bound records with `chunks` slots each —
    /// bigger than any single answer may carry, which is the whole point.
    private static func bulkyIndex(items: Int, chunks: Int) -> MeshRoutedIndex {
        var records: [MeshRoutedItemRecord] = []
        // R2: bounded by the caller's own item count.
        for _ in 0..<items {
            let manifest = MeshRoutedManifestFixtures.manifest().replacing(itemID: UUID())
            let descriptors = (0..<chunks).map {
                Fixture.descriptor(index: UInt32($0), count: UInt32(chunks), bytes: 16)
            }
            records.append(MeshRoutedItemRecord(
                key: MeshRoutedItemKey(manifest),
                contentHash: manifest.contentHash,
                chunkCount: UInt32(chunks),
                expiresAt: manifest.expiresAt,
                manifest: manifest,
                firstSeenAt: MeshRoutedManifestFixtures.base,
                custodiedAt: nil,
                deliveredAt: nil,
                chunks: descriptors,
                delivery: nil,
                receipts: [],
                recipientReceipts: []
            ))
        }
        return MeshRoutedIndex(items: records)
    }
}

// MARK: - The walls

/// The mechanical halves of "exactly one transfer, at exactly one moment", "no second hop" and "no
/// merge-window dependence" — grep-walls over the shipping source, brace-matched per function so a
/// claim is about a FUNCTION rather than about a file's line count.
@MainActor
@Suite(.serialized)
struct MeshRoutedCustodyHandoffWallTests {

    private func managerSource() throws -> String {
        MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshNetworkManager.swift")
        )
    }

    private func storeSource() throws -> String {
        MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedCustodyHandoff.swift")
        )
    }

    /// **The rung moves on the development path and nowhere else.** Both batch doors have exactly
    /// one call site each, in the one function that owns them; the single-item transfer door still
    /// has **zero** shipping callers, so nothing else in the manager can write a `custodied(by:)`
    /// rung; and the claim's custodian is this device's own fingerprint, supplied at the call site
    /// rather than read inside an identity-free store.
    @Test func theRungMovesOnlyOnTheDevelopmentPath() throws {
        let source = try managerSource()
        #expect(source.components(separatedBy: "recordingCustodyHandoff(").count - 1 == 1)
        #expect(source.components(separatedBy: "claimingHandedOffLegs(").count - 1 == 1)
        #expect(source.components(separatedBy: "recordingCustodyTransfer(").count - 1 == 0,
                "the single-item transfer door still has no shipping caller")
        let apply = try #require(Self.body(startingWith: "private func applyCustodyHandoff(", in: source))
        #expect(apply.contains("recordingCustodyHandoff("))
        let transfer = try #require(
            Self.body(startingWith: "private func transferCustodyOnDevelopment(", in: source)
        )
        #expect(transfer.contains("applyCustodyHandoff("), "one owner, one call")
        #expect(source.components(separatedBy: "applyCustodyHandoff(").count - 1 == 2,
                "one declaration plus exactly one call site")
        let claims = try #require(
            Self.body(startingWith: "private func applyHandedOffClaims(", in: source)
        )
        #expect(claims.contains("claimingHandedOffLegs("))
        let claim = try #require(
            Self.body(startingWith: "private func claimHandedOffCustody(", in: source)
        )
        #expect(claim.contains("let me = identity.localFingerprint"))
        #expect(claim.contains("selfFingerprint: me"), "the custodian is this device, at the caller")
    }

    /// Each batch door is one load, N updates and **one** save — the shape that keeps a fifteen-second
    /// window from becoming two thousand crypto passes, and that makes the whole batch
    /// durable-before-acknowledged at once.
    @Test func eachBatchDoorLoadsOnceAndSavesOnce() throws {
        let source = try storeSource()
        for door in [
            "func recordingCustodyHandoff(", "func claimingHandedOffLegs("
        ] {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshRoutedCustodyHandoff.swift")
            #expect(body.components(separatedBy: "indexForWriting()").count - 1 == 1,
                    "\(door) loads exactly once")
            #expect(body.components(separatedBy: "try save(").count - 1 == 1,
                    "\(door) saves exactly once")
        }
        #expect(source.components(separatedBy: "try save(").count - 1 == 2,
                "and nothing else in the file writes at all")
    }

    /// **R8.** The custody path names no merge-window symbol: custody depends on no window closing,
    /// which is what keeps item 7's "a window is not guaranteed to close" from becoming a custody
    /// liveness problem.
    @Test func theDevelopmentPathNamesNoMergeWindowSymbol() throws {
        let source = try managerSource()
        for door in [
            "private func transferCustodyOnDevelopment(",
            "private func pushCustodyToCustodians(",
            "private func claimHandedOffCustody(",
            "private func handoffEntitlement("
        ] {
            let body = try #require(Self.body(startingWith: door, in: source),
                                    "\(door) is gone from MeshNetworkManager.swift")
            for symbol in [
                "mergeWindow", "concludeMergeIfConverged", "readvertiseMergeProof(",
                "sendInventoryDigest(", "sendRoutedInventory("
            ] {
                #expect(!body.contains(symbol), "\(door) reads \(symbol)")
            }
        }
    }

    /// The entitlement a development opens is armed at exactly one site and cleared at exactly one,
    /// so it cannot outlive the session it belongs to. Arming plus clearing is two assignment sites:
    /// "exactly one assignment" would be a wall that could never go green.
    @Test func theHandoffEntitlementDiesWithTheSession() throws {
        let source = try managerSource()
        #expect(source.components(separatedBy: "developmentHandoff = ").count - 1 == 2,
                "one arming site and one clear")
        let armed = try #require(
            Self.body(startingWith: "private func transferCustodyOnDevelopment(", in: source)
        )
        #expect(armed.contains("developmentHandoff = MeshCustodyHandoffScope("))
        let reset = try #require(
            Self.body(startingWith: "private func resetSessionStateMachine(", in: source)
        )
        #expect(reset.contains("developmentHandoff = nil"))
        #expect(!source.contains("lastDevelopmentPlan?.handoffTargets"),
                "the entitlement is never read off the plan that outlives the session")
    }

    /// **D-6.16 declined, by name.** The two receive clauses still admit only a destination's own
    /// item or the origin's own forward, and neither names a hand-off target: widening either is
    /// increment 2.
    @Test func theReceiveClauseIsStillOneHopFromTheOrigin() throws {
        let source = try managerSource()
        let manifestDoor = try #require(
            Self.body(startingWith: "private func ingestRoutedManifest(", in: source)
        )
        #expect(manifestDoor.contains("context.sender == manifest.originFingerprint"))
        #expect(!manifestDoor.contains("handoffTargets"))
        let chunkDoor = try #require(
            Self.body(startingWith: "private func ingestRoutedChunk(", in: source)
        )
        #expect(chunkDoor.contains("context.sender == chunk.originFingerprint"))
        #expect(!chunkDoor.contains("handoffTargets"))
    }

    /// **The hop bound.** The origin-served set has one writer, one reader and one clear. A second
    /// writer is increment 2 arriving without a decision.
    ///
    /// **Amended by P5 item 12, and strengthened in the same commit.** The wall used to count one
    /// call site; the replay window's probe is sender-BLIND (author = the origin, id = the item), so
    /// a courier's copy and the origin's own are indistinguishable to it, and leaving the write
    /// inside the probe's early return would drop the origin's own hand-off copy as `replayed` and
    /// strand that leg at the origin's next departure. The write therefore runs on the replayed path
    /// too — so the count moved to two and the wall became **per door**: both call sites must sit
    /// inside `ingestRoutedManifest`, which a bare count could never say.
    @Test func theOriginServedSetIsWrittenAtOneDoorAndDiesWithTheSession() throws {
        let source = try managerSource()
        #expect(source.components(separatedBy: "originServedItems.insert(").count - 1 == 1)
        #expect(source.components(separatedBy: "noteOriginServed(").count - 1 == 3,
                "one declaration plus exactly two call sites")
        let writer = try #require(Self.body(startingWith: "private func noteOriginServed(", in: source))
        #expect(writer.contains("originServedItems.insert("))
        let manifestDoor = try #require(
            Self.body(startingWith: "private func ingestRoutedManifest(", in: source)
        )
        #expect(manifestDoor.contains("noteOriginServed(key)"))
        #expect(manifestDoor.components(separatedBy: "noteOriginServed(").count - 1 == 2,
                "BOTH writes live in the one door — the admitted path and the replayed one")
        let reader = try #require(
            Self.body(startingWith: "private func claimHandedOffCustody(", in: source)
        )
        #expect(reader.components(separatedBy: "originServed: originServedItems").count - 1 == 2,
                "the claim planner and its residual counter are the only readers")
        let reset = try #require(
            Self.body(startingWith: "private func resetSessionStateMachine(", in: source)
        )
        #expect(reset.contains("originServedItems.removeAll()"))
    }

    /// **The deferred commit queue is drained by the claim itself, and dies with the session.**
    ///
    /// Routing the retry through the claim *planner* is what would make the deferral permanent —
    /// after a claim no named leg is `pending`, so a re-plan is empty by construction. The queue is
    /// therefore drained even when an evaluation plans nothing, and it is cleared with the session
    /// because it names items of one mesh.
    @Test func theDeferredCommitQueueIsDrainedByTheClaimAndDiesWithTheSession() throws {
        let source = try managerSource()
        let claim = try #require(
            Self.body(startingWith: "private func claimHandedOffCustody(", in: source)
        )
        #expect(claim.contains("mintClaimedCustody([], at: now)"),
                "an evaluation that plans nothing still drains the queue")
        let mint = try #require(
            Self.body(startingWith: "private func mintClaimedCustody(", in: source)
        )
        #expect(mint.contains("deferredCustodyCommits + keys"), "the queue runs AHEAD of new work")
        #expect(mint.components(separatedBy: "deferredCustodyCommits = ").count - 1 == 2,
                "one carry-the-whole-queue site and one overflow site, and nothing else assigns it")
        let reset = try #require(
            Self.body(startingWith: "private func resetSessionStateMachine(", in: source)
        )
        #expect(reset.contains("deferredCustodyCommits.removeAll()"))
    }

    /// **The merge door runs the verdict FIRST.** A merge that ejects this device, or ends the mesh,
    /// must not first write custody rungs — the same order the live-record twin uses.
    @Test func theMergeDoorClaimsOnlyWhenTheVerdictDeclinedToEndTheSession() throws {
        let source = try managerSource()
        let merge = try #require(
            Self.body(startingWith: "func mergeMembershipLedger(", in: source)
        )
        #expect(merge.contains("if moved, !applyMergedRosterVerdict(from: before) {"),
                "the claim and the rotation both hang off the verdict declining")
        #expect(merge.components(separatedBy: "claimHandedOffCustody(").count - 1 == 1)
        let verdictFirst = try #require(merge.range(of: "applyMergedRosterVerdict(from: before)"))
        let claimAfter = try #require(merge.range(of: "claimHandedOffCustody("))
        #expect(verdictFirst.lowerBound < claimAfter.lowerBound,
                "the claim is inside the verdict's own guard, never before it")
        let move = try #require(
            Self.body(startingWith: "private func applyRosterMove(", in: source)
        )
        let selfRemoval = try #require(move.range(of: "applyVerifiedSelfRemoval()"))
        let termination = try #require(move.range(of: "applyVerifiedTermination()"))
        let liveClaim = try #require(move.range(of: "claimHandedOffCustody("))
        #expect(selfRemoval.lowerBound < liveClaim.lowerBound
                && termination.lowerBound < liveClaim.lowerBound,
                "the live-record twin still ends the session before it claims")
    }

    /// **D-8.21, mechanically.** A departure record that was never emitted is folded into the result
    /// rather than reported as a transfer, and the byte push runs only when it WAS emitted.
    @Test func aRecordThatWasNeverEmittedSkipsThePush() throws {
        let source = try managerSource()
        let body = try #require(
            Self.body(startingWith: "func leaveSessionAfterNotifyingPeers(clock:", in: source)
        )
        #expect(body.contains("let emitted = await sendMembershipEvent("))
        #expect(body.contains("if emitted {"))
        #expect(body.contains("handoff = handoff.notAnnounced()"))
        #expect(body.components(separatedBy: "pushCustodyToCustodians(").count - 1 == 1,
                "the push has exactly one call site, inside the emitted branch")
        let emit = try #require(Self.body(startingWith: "func sendMembershipEvent(", in: source))
        #expect(emit.components(separatedBy: "return false").count - 1 == 4,
                "every exit that broadcast nothing answers false")
    }

    /// One function's body found from a declaration **prefix**, brace-matched from the first `{`
    /// after it — so a declaration whose parameters wrap onto several lines can still be named.
    private static func body(startingWith prefix: String, in source: String) -> String? {
        guard let start = source.range(of: prefix),
              let open = source.range(of: "{", range: start.upperBound..<source.endIndex)
        else { return nil }
        var depth = 1
        var index = open.upperBound
        var scanned = 0
        // R2: bounded by the file's own length.
        while index < source.endIndex, scanned < source.count {
            scanned += 1
            if source[index] == "{" { depth += 1 }
            if source[index] == "}" {
                depth -= 1
                if depth == 0 { return String(source[open.upperBound..<index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
