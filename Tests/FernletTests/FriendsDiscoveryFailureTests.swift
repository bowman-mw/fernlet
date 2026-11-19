// FriendsDiscoveryFailureTests.swift
// FernletTests
//
// Release review since build 460 (2026-11-18): Friends nearby showed "Can't look for nearby friends …
// needs Local Network access" for every line ProximityKit 0.2.0 reports into `discoveryError`, and drew
// it in place of the friend cards. Two everyday refusals land there too: a stranger's Fernlet nearby
// (`noDialProof`) and a friend still on build 460 (protocol 1, whose introduction fails with a decode or
// stream-closed error). Neither is a Local Network problem, and neither says anything about the other
// friends on the page.
//
// What the cells hold:
//   - every radio-level line ProximityKit 0.2.0 reports (browser, listener, radio start) keeps the card;
//   - every per-tunnel line (refused, did not complete, gave up) does not, so the cards stay;
//   - through the real `MeshNetworkManager`, a refusal does reach `discoveryError` (the reason the page
//     must sort it) and the page's rule leaves the cards for it.

import Foundation
@testable import ProximityKit
import Testing
@testable import Fernlet

@MainActor
struct FriendsDiscoveryFailureTests {

    /// The radio-level lines ProximityKit 0.2.0's `NetworkMeshSession` and transport selection report,
    /// with stand-in error text: the Local Network card's cases.
    static let radioFailures = [
        "The Bonjour browser failed: The operation couldn't be completed. (Network.NWError error -65570.)",
        "The Bonjour browser stopped: PolicyDenied",
        "The QUIC listener failed: The operation couldn't be completed.",
        "The QUIC listener stopped: cancelled",
        "The QUIC listener could not be republished: busy",
        "The QUIC listener could not be resumed: busy",
        "The QUIC mesh radio could not start: The operation couldn't be completed."
    ]

    /// The per-tunnel lines: one phone refused or never finished its introduction.
    static let tunnelRefusals = [
        "A QUIC tunnel was refused: noDialProof",
        "A QUIC tunnel was refused: unknownMesh",
        "A QUIC channel introduction did not complete: The data couldn't be read because it is missing.",
        "A QUIC channel introduction did not complete: The operation couldn't be completed. (Network.NWError error 57.)",
        "The QUIC tunnel gave up after 3 attempts: connection refused",
        "The QUIC transport could not derive a TLS exporter binding for this tunnel.",
        "The QUIC transport could not derive a channel-introduction transcript."
    ]

    /// **A radio failure keeps the Local Network card.**
    @Test func radioFailuresKeepTheLocalNetworkCard() {
        for line in Self.radioFailures {
            #expect(FriendsDiscoveryFailure.isRadioFailure(line), "\"\(line)\" no longer shows the card")
        }
    }

    /// **A refused tunnel is not a Local Network failure.**
    @Test func refusedTunnelsDoNotShowTheLocalNetworkCard() {
        for line in Self.tunnelRefusals {
            #expect(!FriendsDiscoveryFailure.isRadioFailure(line), "\"\(line)\" would replace the friend cards")
        }
    }

    /// **Through the real manager: a stranger's refusal reaches `discoveryError`, and the page keeps the
    /// cards for it; a browser failure after it shows the card.**
    @Test func aRefusalThroughTheManagerLeavesTheCards() throws {
        let store = makeTestStore()
        let transport = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: transport)
        let report = try #require(transport.handlers.onTransportError, "the manager wired no transport-error hook")

        report("A QUIC tunnel was refused: noDialProof")
        let refusal = try #require(manager.discoveryError, "a refusal no longer reaches discoveryError")
        #expect(!FriendsDiscoveryFailure.isRadioFailure(refusal), "one stranger's refusal hides every friend card")

        report("The Bonjour browser failed: PolicyDenied")
        let denial = try #require(manager.discoveryError)
        #expect(FriendsDiscoveryFailure.isRadioFailure(denial), "a Local Network denial lost its card")
    }
}
