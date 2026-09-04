// MeshHostPinTests.swift
// FernletTests
//
// P5 item 1a: the ONE-SHOT reproduction of the `unowned` host trap, staged deterministically.
//
// `MeshNetworkManager` reads its host through `unowned let store` — correct in production, where the
// host is the process-lifetime `FernletStore` that owns the manager. A detached send task, though,
// holds `self` strongly for the operation it awaits, so it can outlive a *rig's* host and then read
// destroyed memory: `swift_abortRetainUnowned` aborts the whole test process. That is the crash the
// P5 gauntlet kept paying a second invocation for (`displayName.getter ← sendEnvelopeCore ←
// closure #1 in broadcastCoordinatorBeacon`). The fix is the host pin: every detached spawn captures
// the host for the duration of the operation that will read it (invariant HP1).
//
// WHAT THIS SUITE IS, AND IS NOT. It is a reproduction, not a re-runnable canary. On a tree where a
// pin is missing, assertion 1 records a failure and the drain that follows drives `displayName` at a
// destroyed host, which kills the test host and takes every other suite's results with it — so a
// future regression presents as "the run crashed again", not as one red test. The durable guards are
// rule ML4 in ``MemoryLifecycleBoundaryTests`` (no unmarked `Task` in a host-holding file) and the
// per-run `Attempted to read an unowned reference` grep. This suite's job is to produce the crash
// once, on purpose, on an unpinned tree.
//
// Determinism: `broadcastCoordinatorBeacon()` spawns its per-slot send tasks synchronously on the
// main actor, and a main-actor task cannot start until the current one suspends. The cell releases
// the host in the SAME synchronous run as the spawn, with no `await` in between, so the send task is
// guaranteed to resume against a released host. No sleeps, no wall clock.

import Foundation
import Testing
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshHostPinProbe

/// Owns a mesh manager's host the way a rig node does, so a cell can drop the host while the manager
/// is still alive — the state P5 item 1a's crash reports were taken in.
///
/// A class rather than a struct because the two lifetimes must be separable: ``releaseHost()`` drops
/// the store and ``releaseManager()`` drops the manager, independently and in either order.
///
/// The `FakePeerNetwork` is held strongly here, and must stay held: `FakePeerNetwork` owns the
/// endpoints while a `FakePeerTransport` points back at its fabric **`weak`** (P5 item 1a,
/// D-1a.impl.1), so this probe is the only strong reference keeping the link routable for the cell's
/// lifetime. Release it and every send lands in the endpoint's `fabricGoneFrames` instead of
/// reaching a peer.
@MainActor
final class MeshHostPinProbe {

    /// The strong reference ``releaseHost()`` drops.
    private var host: FernletStore?

    /// The same store, weakly: how a cell observes whether anything still pins it.
    private(set) weak var weakHost: FernletStore?

    /// The manager under test.
    private(set) var manager: MeshNetworkManager?

    /// The recording endpoint seated on the manager's one slot.
    let channel: FakePeerTransport

    /// What a LIVE host resolves its display name to, sampled while it is alive so the cell can tell
    /// a valid read from a survived one.
    let expectedDisplayName: String

    private let network: FakePeerNetwork
    private let peer: PeerHandle

    init() {
        let store = makeTestStore()
        let fabric = FakePeerNetwork()
        let endpoint = fabric.addEndpoint(named: "host-pin-peer")
        network = fabric
        channel = endpoint.transport
        peer = endpoint.handle
        expectedDisplayName = store.resolvedProximityDisplayName
        host = store
        weakHost = store
        manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
    }

    /// Seats one slot on the recording endpoint, so the beacon fan-out has somewhere to send.
    func seatSlot() {
        manager?.addSlotForTesting(
            coordinator: Self.throwawayCoordinator(),
            peer: peer,
            fingerprint: nil,
            channel: channel
        )
    }

    /// Drops the host. Nothing else in this file holds it.
    func releaseHost() {
        host = nil
    }

    /// Drops the manager, so a cell can watch the pin dissolve.
    func releaseManager() {
        manager = nil
    }

    /// The sender display name carried by every frame the manager put on the wire.
    func sentSenderDisplayNames() -> [String] {
        let decoder = JSONDecoder()
        return channel.sentFrames
            .compactMap { try? decoder.decode(FernletIdentityEnvelope.self, from: $0.data) }
            .map(\.senderDisplayName)
    }

    /// A never-begun coordinator, so a slot can be seeded without a live radio or ranging session.
    /// Its own keychain service is per-instance: `IdentityService()` is keyed on one process-wide
    /// service, and a shared one couples unrelated suites.
    static func throwawayCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "test.mesh.hostpin.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }
}

// MARK: - MeshHostPinTests

/// The host pin, staged: an in-flight beacon send outlives the rig's release of its host.
@MainActor
@Suite(.serialized)
struct MeshHostPinTests {

    @Test func anInFlightBeaconSendPinsItsHostAfterTheRigReleasesIt() async {
        let probe = MeshHostPinProbe()
        probe.seatSlot()
        probe.manager?.broadcastCoordinatorBeaconForTesting()   // spawns the per-slot send Task
        probe.releaseHost()                                     // same synchronous run: nothing has run yet

        let pinned = probe.weakHost != nil
        #expect(pinned, "an in-flight mesh send must pin its host for its own lifetime")
        if !pinned {
            // The drain below WILL abort the test host on an unpinned tree — that IS the
            // reproduction. Name the cause first, so the crash report is not the only evidence.
            FernletAuditLog.log("meshHostPin.missingPin.aborting")
        }

        for _ in 0..<16 { await Task.yield() }                  // bounded drain, no sleeps
        #expect(probe.sentSenderDisplayNames() == [probe.expectedDisplayName],
                "the pinned send must have read a LIVE host, not merely survived")

        probe.releaseManager()
        var polls = 0
        while probe.weakHost != nil, polls < 64 {
            polls += 1
            await Task.yield()
        }
        #expect(probe.weakHost == nil, "the pin dissolves with the task — it must never form a cycle")
    }
}
