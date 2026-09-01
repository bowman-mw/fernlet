import Combine
import Foundation
import MultipeerConnectivity
import ProximityKit
import Testing
@testable import ProximityKit

/// The identity rule the seven "same device?" call sites depend on, which had **no test at all**
/// before transport neutrality made it nameable.
///
/// Until this file existed, every test peer was built with its own fresh `MCPeerID`, and two
/// separately constructed `MCPeerID`s are never equal — so no test ever constructed two peer values
/// that stood for one device. The `$0.peer.id == peer.id || $0.peer.underlying == peer.underlying`
/// disjunct those sites were written with could have been deleted outright and the whole suite would
/// have stayed green. That is the worst possible state for a check whose failure mode is silent:
/// a slot that is never removed on disconnect keeps its seat and its coordinator is never cancelled,
/// so ranging is never invalidated and the foreground Live Activity anchor is orphaned until the
/// system's time cap; and a returning partner is refused by the very cap it already occupies.
///
/// The rule now lives in one place — ``PeerHandle/isSameEndpoint(as:)`` — and is tested here.
@MainActor
@Suite(.serialized)
struct PeerHandleIdentityTests {

    /// The property `==` does not have. A device re-discovered after the transport's peer cache
    /// missed comes back under a **new `id`** and the **same endpoint**, and every record matched
    /// against a transport event has to recognize it.
    @Test func aReDiscoveredPeerIsTheSameEndpointDespiteANewID() {
        let endpoint = PeerEndpointKey(UUID())
        let first = makeHandle(named: "Robin", endpoint: endpoint)
        let reDiscovered = makeHandle(named: "Robin", endpoint: endpoint)

        #expect(first.id != reDiscovered.id, "the fixture must model a re-mint, not a copy")
        #expect(first != reDiscovered, "`==` compares id — this is exactly the false negative")
        #expect(first.isSameEndpoint(as: reDiscovered))
        #expect(reDiscovered.isSameEndpoint(as: first), "the relation must be symmetric")
    }

    /// The other half: two genuinely different devices must never collapse into one, however
    /// similar their advertisements. A false positive here would seat one peer in another's slot.
    @Test func differentEndpointsAreNeverTheSameDevice() {
        let a = makeHandle(named: "Robin", endpoint: PeerEndpointKey(UUID()))
        let b = makeHandle(named: "Robin", endpoint: PeerEndpointKey(UUID()))

        #expect(!a.isSameEndpoint(as: b))
        #expect(a != b)
    }

    /// Equal `id` implies equal endpoint in production, so keeping the `id` disjunct can only add a
    /// match a cache miss would otherwise lose. This pins the direction that matters: a handle is
    /// always the same endpoint as itself, and the `id` arm alone is enough to say so.
    @Test func aHandleIsAlwaysTheSameEndpointAsItself() {
        let handle = makeHandle(named: "Robin", endpoint: PeerEndpointKey(UUID()))
        #expect(handle.isSameEndpoint(as: handle))

        // Same id, different endpoint key cannot arise from a real transport — but if it ever did,
        // the id arm still answers "same device", which is the conservative direction.
        let sameIDDifferentEndpoint = PeerHandle(
            id: handle.id,
            displayHint: handle.displayHint,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            endpoint: PeerEndpointKey(UUID())
        )
        #expect(handle.isSameEndpoint(as: sameIDDifferentEndpoint))
    }

    /// Hashing and equality stay keyed on `id` alone. Changing that would silently re-key every
    /// `Set<PeerHandle>` and dictionary in the three radio managers, so it is pinned rather than
    /// assumed.
    @Test func equalityAndHashingRemainKeyedOnTheDiscoveryID() {
        let id = UUID()
        let first = PeerHandle(id: id, displayHint: "A", discoveryInfo: ["v": "1"], advertisedFingerprint: nil)
        let refreshed = PeerHandle(id: id, displayHint: "A", discoveryInfo: ["v": "2"], advertisedFingerprint: "fp")

        #expect(first == refreshed, "an advertisement update must not make it a different peer")
        #expect(Set([first, refreshed]).count == 1)
    }

    /// A default-constructed handle gets its own endpoint, so the ~20 fixtures across the suite that
    /// omit the argument cannot accidentally alias each other into one device.
    @Test func defaultConstructedHandlesDoNotShareAnEndpoint() {
        let handles = (0..<8).map { makeHandle(named: "Peer \($0)") }
        for outer in handles.indices {
            for inner in handles.indices where inner != outer {
                #expect(!handles[outer].isSameEndpoint(as: handles[inner]))
            }
        }
    }

    private func makeHandle(named name: String, endpoint: PeerEndpointKey = PeerEndpointKey()) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            endpoint: endpoint
        )
    }
}

/// The §6.5 root fix: the transport's endpoint→identity map lives **outside** the dictionary
/// discovery prunes, so `PeerHandle.id` is stable for the life of a session.
///
/// Before the split, `peer(for:)` minted a fresh `UUID` on every `peerMap` miss, and `peerMap` was
/// evicted whenever a peer was lost while holding no channel — so ordinary discovery churn silently
/// changed a device's `id` under every owner holding a record for it. That is what made `id` a
/// false-negative-only test and forced seven call sites into a disjunction. These tests drive the
/// real MC delegate callbacks, which are the only production writers of that map.
///
/// The suite is `.serialized` and every test builds its own transport with an EPHEMERAL peer ID, so
/// none of them touches the archived `FileMCPeerIDStore` the other radios depend on.
@MainActor
@Suite(.serialized)
struct MeshMultipeerSessionIdentityTests {

    /// The core property. A prune between two sightings must cost a `PeerHandle` rebuild and
    /// nothing else — same `id`, same endpoint, same peer to every owner.
    @Test func aPeerReDiscoveredAfterADiscoveryPruneKeepsItsIdentity() async {
        let session = MeshMultipeerSession(usesEphemeralPeerID: true)
        var discovered: [PeerHandle] = []
        var lost: [PeerHandle] = []
        session.onPeerDiscovered = { discovered.append($0) }
        session.onPeerLost = { lost.append($0) }
        let browser = Self.makeBrowser(for: session)
        let remote = MCPeerID(displayName: "Robin")

        session.browser(browser, foundPeer: remote, withDiscoveryInfo: ["sid": "one"])
        await waitUntil { discovered.count == 1 }
        // No channel exists for this peer, so this is the eviction that used to re-mint the id.
        session.browser(browser, lostPeer: remote)
        await waitUntil { lost.count == 1 }
        session.browser(browser, foundPeer: remote, withDiscoveryInfo: ["sid": "one"])
        await waitUntil { discovered.count == 2 }

        #expect(discovered.count == 2)
        #expect(discovered.first?.id == discovered.last?.id,
                "a discovery prune must not re-mint the peer's id — this is the §6.5 root fix")
        #expect(discovered.first?.endpoint == discovered.last?.endpoint)
        #expect(discovered.first == discovered.last,
                "`==` is by id, so a returning device is now the same peer to every owner")
        #expect(session.trackedEndpointCountForTesting == 1,
                "one device, one identity — a re-sighting must not grow the map")
    }

    /// The other cache-miss source §6.1 named: an inbound invitation is resolved *before* the
    /// channel is prepared, so a device that drops and re-invites arrives through a path that had
    /// nothing cached. Its slot, QR binding and admission request are all keyed on the id it
    /// carried the first time.
    @Test func aReconnectingPeerInvitesUsUnderTheSameID() async {
        let session = MeshMultipeerSession(usesEphemeralPeerID: true)
        var discovered: [PeerHandle] = []
        var invitedBy: [PeerHandle] = []
        session.onPeerDiscovered = { discovered.append($0) }
        session.shouldAcceptInvitation = { invitedBy.append($0); return false }
        let browser = Self.makeBrowser(for: session)
        let advertiser = MCNearbyServiceAdvertiser(
            peer: session.localPeerID,
            discoveryInfo: nil,
            serviceType: MeshMultipeerSession.friendServiceType
        )
        let remote = MCPeerID(displayName: "Robin")

        session.browser(browser, foundPeer: remote, withDiscoveryInfo: nil)
        await waitUntil { discovered.count == 1 }
        session.browser(browser, lostPeer: remote)
        session.advertiser(advertiser, didReceiveInvitationFromPeer: remote, withContext: nil) { _, _ in }
        await waitUntil { invitedBy.count == 1 }

        #expect(discovered.first?.id == invitedBy.first?.id,
                "the reconnecting device must be the same peer as the one we discovered")
        #expect(discovered.first?.isSameEndpoint(as: invitedBy[0]) == true)
    }

    /// Two devices must never collapse into one identity, however the discovery cycles interleave.
    /// A false positive here would seat one peer in another's slot.
    @Test func distinctDevicesNeverShareAnIdentity() async {
        let session = MeshMultipeerSession(usesEphemeralPeerID: true)
        var discovered: [PeerHandle] = []
        session.onPeerDiscovered = { discovered.append($0) }
        let browser = Self.makeBrowser(for: session)
        let robin = MCPeerID(displayName: "Robin")
        let sam = MCPeerID(displayName: "Sam")

        session.browser(browser, foundPeer: robin, withDiscoveryInfo: nil)
        session.browser(browser, foundPeer: sam, withDiscoveryInfo: nil)
        session.browser(browser, lostPeer: robin)
        session.browser(browser, foundPeer: robin, withDiscoveryInfo: nil)
        await waitUntil { discovered.count == 3 }

        let robinHandles = discovered.filter { $0.displayHint == "Robin" }
        let samHandles = discovered.filter { $0.displayHint == "Sam" }
        #expect(robinHandles.count == 2)
        #expect(robinHandles.first?.id == robinHandles.last?.id)
        #expect(samHandles.first?.id != robinHandles.first?.id)
        #expect(samHandles.first?.isSameEndpoint(as: robinHandles[0]) == false)
        #expect(session.trackedEndpointCountForTesting == 2)
    }

    /// The privacy constraint plan §6.5 attaches to the fix, asserted directly rather than inferred.
    ///
    /// The map is session-scoped: memory-only, never persisted, never advertised, and gone at
    /// teardown. That is what keeps it off the privacy-wipe ledger, and what keeps the presence
    /// radio's per-start-random posture intact — a map that outlived a stop/start would link two
    /// runs of that radio to one device.
    @Test func stopClearsEverySessionIdentity() async {
        let session = MeshMultipeerSession(usesEphemeralPeerID: true)
        var discovered: [PeerHandle] = []
        session.onPeerDiscovered = { discovered.append($0) }
        let browser = Self.makeBrowser(for: session)
        let remote = MCPeerID(displayName: "Robin")

        session.browser(browser, foundPeer: remote, withDiscoveryInfo: nil)
        await waitUntil { discovered.count == 1 }
        #expect(session.trackedEndpointCountForTesting == 1)

        session.stop()
        #expect(session.trackedEndpointCountForTesting == 0,
                "no peer identity may outlive the session that minted it")

        session.browser(browser, foundPeer: remote, withDiscoveryInfo: nil)
        await waitUntil { discovered.count == 2 }
        #expect(discovered.first?.id != discovered.last?.id,
                "a new session mints a new identity for the same device — that is the session scope")
    }

    private static func makeBrowser(for session: MeshMultipeerSession) -> MCNearbyServiceBrowser {
        // Never started: the delegate methods under test ignore the browser they are handed, and
        // starting one would put a real advertisement on the local network from a unit test.
        MCNearbyServiceBrowser(peer: session.localPeerID, serviceType: MeshMultipeerSession.friendServiceType)
    }

    /// The MC delegates are `nonisolated` and hop to the main actor via `Task { @MainActor }`, so a
    /// `@MainActor` test observes nothing until it suspends.
    ///
    /// Polls with BOTH a wall-clock deadline and a minimum observation count. That pairing is this
    /// repository's house rule for exactly this shape: a deadline alone measures wall time, which
    /// keeps advancing while a `@MainActor` suite is starved by every other `@MainActor` suite in a
    /// loaded full-suite run, and expires having genuinely looked only a handful of times.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        minimumPolls: Int = 200,
        _ condition: @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }
}

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
    /// working, matching `MeshMultipeerSession`, where relying on it is undocumented behaviour.
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
