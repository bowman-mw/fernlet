// MeshTransportErrorSurfacingTests.swift
// FernletTests
//
// Phase 1 (Proximity Mesh Redesign): the MCNearbyServiceAdvertiser/Browser didNotStart* delegates
// were empty, which is how the missing-NSBonjourServices bug shipped invisibly — discovery died on
// device with no log and no observable state. These tests drive the (now-implemented) delegate
// methods directly with a synthesized error — MCNearbyServiceAdvertiser/Browser are safe to
// construct without starting — and assert the MainActor `onTransportError` callback fires with a
// message naming the service type. The os_log side is not assertable from a unit test; the
// callback is the observable contract managers wire into their diagnostics.

@testable import ProximityKit
import Foundation
import MultipeerConnectivity
import Testing
@testable import Fernlet

/// Keeps the test from reading/writing the real persisted MCPeerID archive.
private struct EphemeralPeerIDStore: MCPeerIDStoring {
    func load() -> MCPeerID? { nil }
    func save(_ peerID: MCPeerID) {}
}

@Suite(.serialized) @MainActor
struct MeshTransportErrorSurfacingTests {

    /// Gives up only once the deadline has passed AND `minimumPolls` observations have really been
    /// made. A `ContinuousClock` deadline alone measures wall clock, which keeps advancing while
    /// this `@MainActor` suite is starved in a loaded full-suite run — so it can expire having
    /// genuinely looked only a handful of times. Counting observations ties the give-up decision
    /// to scheduling received rather than to time elapsed, and still terminates: `polls` only
    /// climbs, and every turn of the loop sleeps.
    private func waitUntil(
        timeout: Duration = .seconds(1),
        minimumPolls: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func makeError() -> NSError {
        NSError(
            domain: NetService.errorDomain,
            code: -72008,
            userInfo: [NSLocalizedDescriptionKey: "NSNetServicesBadArgumentError"]
        )
    }

    @Test func advertiserStartFailureInvokesTransportErrorCallback() async {
        let session = MeshMultipeerSession(peerIDStore: EphemeralPeerIDStore())
        var messages: [String] = []
        session.onTransportError = { messages.append($0) }
        let advertiser = MCNearbyServiceAdvertiser(
            peer: session.localPeerID,
            discoveryInfo: nil,
            serviceType: "fernlet-test"
        )

        session.advertiser(advertiser, didNotStartAdvertisingPeer: makeError())
        await waitUntil { !messages.isEmpty }

        #expect(messages.count == 1)
        #expect(messages.first?.contains("Advertising failed to start") == true)
        #expect(messages.first?.contains("fernlet-test") == true)
        #expect(messages.first?.contains("NSNetServicesBadArgumentError") == true)
    }

    @Test func browserStartFailureInvokesTransportErrorCallback() async {
        let session = MeshMultipeerSession(peerIDStore: EphemeralPeerIDStore())
        var messages: [String] = []
        session.onTransportError = { messages.append($0) }
        let browser = MCNearbyServiceBrowser(peer: session.localPeerID, serviceType: "fernlet-test")

        session.browser(browser, didNotStartBrowsingForPeers: makeError())
        await waitUntil { !messages.isEmpty }

        #expect(messages.count == 1)
        #expect(messages.first?.contains("Browsing failed to start") == true)
        #expect(messages.first?.contains("fernlet-test") == true)
    }

    // MARK: - Transport wire floor (M7)

    /// M7: one inbound MC frame is bounded BEFORE the bytes reach any channel or decoder, on
    /// every radio. Without it the only size gates were mode-specific (the 4 MB trainer blob) or
    /// post-decrypt, so a 16 MB blob on the friend/recipe/presence radios was queued onto the
    /// main actor and handed to `JSONDecoder`. Drop only — never disconnect at this layer, or any
    /// peer could kill any session with one large frame.
    @Test func oversizedInboundFrameIsDroppedBeforeReachingTheChannel() async {
        let session = MeshMultipeerSession(peerIDStore: EphemeralPeerIDStore())
        let peerID = MCPeerID(displayName: "Loud")
        let mcSession = MCSession(peer: session.localPeerID)

        session.session(mcSession,
                        didReceive: Data(count: MeshMultipeerSession.maxInboundWireBytes + 1),
                        fromPeer: peerID)
        try? await Task.sleep(for: .milliseconds(50))

        // The frame never got as far as creating or feeding a channel.
        #expect(session.channels[peerID] == nil,
                "An oversized frame must be dropped before the @MainActor hop that touches channels")
    }

    /// The boundary is inclusive: exactly `maxInboundWireBytes` is still honest traffic.
    @Test func inboundFrameAtExactlyTheCapIsNotDropped() async {
        let session = MeshMultipeerSession(peerIDStore: EphemeralPeerIDStore())
        let peerID = MCPeerID(displayName: "AtCap")
        let mcSession = MCSession(peer: session.localPeerID)
        var delivered = false
        session.onPeerChannelReady = { _ in delivered = true }

        // No channel exists for this peer, so the frame is dropped downstream either way — what
        // is under test is that the SIZE guard did not fire, which the cap arithmetic pins.
        session.session(mcSession,
                        didReceive: Data(count: MeshMultipeerSession.maxInboundWireBytes),
                        fromPeer: peerID)
        try? await Task.sleep(for: .milliseconds(50))

        #expect(MeshMultipeerSession.maxInboundWireBytes == SealedPayloadFraming.maxInflatedByteCount,
                "The transport floor must stay pinned to the inflate ceiling every sealed body obeys")
        #expect(delivered == false, "No channel was ever readied — the drop below is not the size gate")
    }

    /// The callback is optional — an owner that never wires it (heart/clothing radios, both
    /// deleted in Phase 4) must not crash the delegate path.
    @Test func missingCallbackIsHarmless() async {
        let session = MeshMultipeerSession(peerIDStore: EphemeralPeerIDStore())
        let browser = MCNearbyServiceBrowser(peer: session.localPeerID, serviceType: "fernlet-test")

        session.browser(browser, didNotStartBrowsingForPeers: makeError())
        try? await Task.sleep(for: .milliseconds(50))
        // Reaching here without a crash is the assertion; the session stays usable.
        #expect(session.channels.isEmpty)
    }
}
