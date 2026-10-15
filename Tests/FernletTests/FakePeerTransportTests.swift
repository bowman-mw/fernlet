// FakePeerTransportTests.swift
// FernletTests
//
// The check of Fernlet's copy of the deterministic peer fabric, `Mocks/FakePeerTransport.swift`
// (`VirtualClock`, `FakePeerNetwork`, `FakePeerTransport`), which Fernlet's mesh acceptance batteries
// and partition scenarios build on. ProximityKit's repository holds the same suite over its own copy of
// the fabric, in its package tests (`PeerTransportNeutralityTests.swift`, with `PeerHandleIdentityTests`,
// the `PeerHandle.isSameEndpoint(as:)` rule, which is ProximityKit's alone); since plan step A1.3, when
// Fernlet began consuming ProximityKit's tag and the package's tests left this repository, this copy
// keeps Fernlet's fabric checked on the `mesh-batteries` line for as long as the batteries ride it: a
// fake nobody checks is a source of false confidence. The two copies of the fabric are no longer held
// identical, so each suite checks the copy its own batteries use.

import Combine
import Foundation
import Testing
@testable import ProximityKit

/// The deterministic fabric plan §16.2's partition matrix is built on, tested as a thing in its own
/// right — a fake nobody has checked is a source of false confidence, not signal.
///
/// The property every test here shares: **no wall-clock sleep**. Nothing awaits real time; a
/// scenario either settles when the clock is advanced or it does not settle at all. That is
/// deliberate: this repository has a documented flake family whose cause was wait helpers with no
/// deadline floor, and a partition suite built on sleeps would reproduce it once per scenario.
@MainActor
@Suite(.serialized)
struct FakePeerTransportTests {

    @Test func aFrameCrossesAConnectedLinkAfterItsLatency() async throws {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (bob, bobHandle) = network.addEndpoint(named: "Bob")
        network.connect(aliceHandle, bobHandle)
        network.clock.advance(by: .milliseconds(50))

        try await alice.send(Data("hello".utf8), to: bobHandle, mode: .reliable)
        #expect(bob.receivedFrames.isEmpty, "nothing arrives before the clock moves")

        network.clock.advance(by: .milliseconds(50))
        #expect(bob.receivedFrames.count == 1)
        #expect(bob.receivedFrames.first?.data == Data("hello".utf8))
        #expect(bob.receivedFrames.first?.peer.isSameEndpoint(as: aliceHandle) == true)
        #expect(alice.droppedFrames.isEmpty)
    }

    @Test func connectingPublishesConnectedAtBothEnds() {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (bob, bobHandle) = network.addEndpoint(named: "Bob")
        var aliceStates: [PeerTransportState] = []
        var cancellables: Set<AnyCancellable> = []
        alice.state.sink { aliceStates.append($0) }.store(in: &cancellables)

        network.connect(aliceHandle, bobHandle)
        network.clock.advance(by: .seconds(1))

        #expect(aliceStates.contains(.connected(bobHandle)))
        #expect(alice.connectedPeers.contains { $0.isSameEndpoint(as: bobHandle) })
        #expect(bob.connectedPeers.contains { $0.isSameEndpoint(as: aliceHandle) })
    }

    /// A partition is silent. The sender is not told, which is the whole reason membership cannot
    /// be inferred from connectivity (plan §3 invariant 1) — so the fake must not "helpfully" throw.
    @Test func aPartitionedLinkDropsFramesWithoutTellingTheSender() async throws {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (bob, bobHandle) = network.addEndpoint(named: "Bob")
        network.connect(aliceHandle, bobHandle)
        network.clock.advance(by: .seconds(1))

        network.partition(aliceHandle, from: bobHandle)
        try await alice.send(Data("lost".utf8), to: bobHandle, mode: .reliable)
        network.clock.advance(by: .seconds(1))

        #expect(bob.receivedFrames.isEmpty)
        #expect(alice.droppedFrames.count == 1, "the drop is recorded, not raised")
        #expect(alice.sentFrames.count == 1, "the send still happened from the sender's point of view")
    }

    /// Healing restores carriage but does **not** replay what was dropped. Convergence after a
    /// merge is the application's job (plan §10.3); a fabric that replayed would prove a property
    /// the real world does not provide.
    @Test func healingCarriesNewFramesAndNeverReplaysLostOnes() async throws {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (bob, bobHandle) = network.addEndpoint(named: "Bob")
        network.connect(aliceHandle, bobHandle)
        network.clock.advance(by: .seconds(1))

        network.partition(aliceHandle, from: bobHandle)
        try await alice.send(Data("during-split".utf8), to: bobHandle, mode: .reliable)
        network.clock.advance(by: .seconds(1))

        network.heal(aliceHandle, from: bobHandle)
        try await alice.send(Data("after-merge".utf8), to: bobHandle, mode: .reliable)
        network.clock.advance(by: .seconds(1))

        #expect(bob.receivedFrames.map(\.data) == [Data("after-merge".utf8)])
    }

    /// A frame already in flight when the link is cut does not land. Delivery is re-checked at
    /// arrival, not only at send — the ordering that makes a mid-flight partition observable.
    @Test func aFrameInFlightWhenTheLinkIsCutNeverLands() async throws {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (bob, bobHandle) = network.addEndpoint(named: "Bob")
        network.setLatency(.seconds(5), between: aliceHandle, and: bobHandle)
        network.connect(aliceHandle, bobHandle)
        network.clock.advance(by: .seconds(6))

        try await alice.send(Data("in-flight".utf8), to: bobHandle, mode: .reliable)
        network.clock.advance(by: .seconds(1))
        network.partition(aliceHandle, from: bobHandle)
        network.clock.advance(by: .seconds(10))

        #expect(bob.receivedFrames.isEmpty)
        #expect(alice.droppedFrames.isEmpty, "the send was carried; the cut happened afterwards")
    }

    /// The n-way form used by the scenario matrix: a 2/2 split of a four-endpoint fabric leaves
    /// each pair reachable inside its group and nothing reachable across.
    @Test func aTwoTwoSplitCutsExactlyTheCrossingLinks() {
        let network = FakePeerNetwork()
        let (_, a) = network.addEndpoint(named: "A")
        let (_, b) = network.addEndpoint(named: "B")
        let (_, c) = network.addEndpoint(named: "C")
        let (_, d) = network.addEndpoint(named: "D")
        for pair in [(a, b), (a, c), (a, d), (b, c), (b, d), (c, d)] {
            network.connect(pair.0, pair.1)
        }
        network.clock.advance(by: .seconds(1))

        network.partition(into: [[a, b], [c, d]])

        #expect(network.canReach(a, b))
        #expect(network.canReach(c, d))
        for pair in [(a, c), (a, d), (b, c), (b, d)] {
            #expect(!network.canReach(pair.0, pair.1), "a cross-group link must be cut")
        }
    }

    /// Latency orders delivery. Without this the fabric would let a test pass on an ordering the
    /// real radio does not guarantee.
    @Test func aSlowerLinkDeliversAfterAFasterOne() async throws {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (fast, fastHandle) = network.addEndpoint(named: "Fast")
        let (slow, slowHandle) = network.addEndpoint(named: "Slow")
        network.setLatency(.milliseconds(10), between: aliceHandle, and: fastHandle)
        network.setLatency(.seconds(2), between: aliceHandle, and: slowHandle)
        network.connect(aliceHandle, fastHandle)
        network.connect(aliceHandle, slowHandle)
        network.clock.advance(by: .seconds(3))

        try await alice.send(Data("x".utf8), to: slowHandle, mode: .reliable)
        try await alice.send(Data("x".utf8), to: fastHandle, mode: .bestEffort)

        network.clock.advance(by: .milliseconds(500))
        #expect(fast.receivedFrames.count == 1)
        #expect(slow.receivedFrames.isEmpty)

        network.clock.advance(by: .seconds(2))
        #expect(slow.receivedFrames.count == 1)
    }

    /// The preserved pause contract: `invite` while paused fails loudly rather than quietly
    /// working, matching the retired MultipeerConnectivity radio, where relying on it was
    /// undocumented behaviour.
    @Test func invitingWhileDiscoveryIsPausedFailsLoudly() async {
        let network = FakePeerNetwork()
        let (alice, _) = network.addEndpoint(named: "Alice")
        let (_, bobHandle) = network.addEndpoint(named: "Bob")

        alice.pauseDiscovery()
        await #expect(throws: PeerTransportError.unexpectedState) {
            try await alice.invite(bobHandle)
        }

        alice.resumeDiscovery()
        await #expect(throws: Never.self) { try await alice.invite(bobHandle) }
    }

    /// A disconnect tells both sides; a partition does not. Plan §3 invariant 1 turns on that
    /// difference, so the fabric has to be able to produce each without the other.
    @Test func disconnectIsAnnouncedWhereAPartitionIsNot() async throws {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (bob, bobHandle) = network.addEndpoint(named: "Bob")
        network.connect(aliceHandle, bobHandle)
        network.clock.advance(by: .seconds(1))

        var bobStates: [PeerTransportState] = []
        var cancellables: Set<AnyCancellable> = []
        bob.state.sink { bobStates.append($0) }.store(in: &cancellables)

        network.partition(aliceHandle, from: bobHandle)
        try await alice.send(Data("silently-lost".utf8), to: bobHandle, mode: .reliable)
        network.clock.advance(by: .seconds(1))
        #expect(bob.receivedFrames.isEmpty, "the partition must actually stop carriage")
        #expect(!bobStates.contains { if case .disconnected = $0 { return true } else { return false } },
                "a partition must not announce itself — that is what makes membership != connectivity")

        network.heal(aliceHandle, from: bobHandle)
        network.disconnect(aliceHandle, bobHandle)
        network.clock.advance(by: .seconds(1))
        #expect(bobStates.contains { if case .disconnected = $0 { return true } else { return false } })
        #expect(bob.connectedPeers.isEmpty)
    }

    /// The clock is the only source of time. Scheduled work does not run until it is advanced past,
    /// and `pendingCount` makes an unfinished scenario visible instead of silently green.
    @Test func nothingHappensUntilTheClockIsAdvanced() async throws {
        let network = FakePeerNetwork()
        let (alice, aliceHandle) = network.addEndpoint(named: "Alice")
        let (bob, bobHandle) = network.addEndpoint(named: "Bob")
        let start = network.clock.now

        network.connect(aliceHandle, bobHandle)
        #expect(network.clock.pendingCount == 1)
        #expect(network.clock.now == start, "connecting must not move the clock by itself")
        #expect(bob.connectedPeers.isEmpty)

        network.clock.advance(by: .seconds(1))
        #expect(network.clock.pendingCount == 0)
        try await alice.send(Data("q".utf8), to: bobHandle, mode: .reliable)
        #expect(network.clock.pendingCount == 1, "an undelivered frame is visible as pending work")
        network.clock.advance(by: .seconds(1))
        #expect(network.clock.pendingCount == 0)
    }
}
