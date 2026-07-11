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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
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
