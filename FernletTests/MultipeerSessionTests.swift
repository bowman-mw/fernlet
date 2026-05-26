import Testing
import Foundation
import MultipeerConnectivity
import Combine
@testable import Fernlet

@Suite(.serialized) @MainActor
struct MultipeerSessionTests {

    // MARK: Helpers

    private func makePeer(name: String = "TestPeer", discoveryInfo: [String: String]? = nil) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: discoveryInfo,
            advertisedFingerprint: discoveryInfo?["fp"],
            underlying: MCPeerID(displayName: name)
        )
    }

    // MARK: Tests

    @Test func discoveryInfoIncludesFingerprintAndRole() async throws {
        let transport = MockMultipeerTransport()
        let info: [String: String] = ["v": "1", "role": "trainer", "fp": "abcd1234", "name": "Alice"]
        try await transport.startAdvertising(serviceType: MultipeerSession.defaultServiceType, discoveryInfo: info)
        #expect(transport.lastDiscoveryInfo?["fp"] == "abcd1234")
        #expect(transport.lastDiscoveryInfo?["role"] == "trainer")
    }

    @Test func startAdvertisingPublishesAdvertisingState() async throws {
        let transport = MockMultipeerTransport()
        var states: [MultipeerSession.State] = []
        let cancellable = transport.state.sink { states.append($0) }
        defer { cancellable.cancel() }

        try await transport.startAdvertising(serviceType: MultipeerSession.defaultServiceType, discoveryInfo: [:])
        #expect(states.last == .advertising)
    }

    @Test func startBrowsingPublishesBrowsingState() async throws {
        let transport = MockMultipeerTransport()
        var states: [MultipeerSession.State] = []
        let cancellable = transport.state.sink { states.append($0) }
        defer { cancellable.cancel() }

        try await transport.startBrowsing(serviceType: MultipeerSession.defaultServiceType)
        #expect(states.last == .browsing)
    }

    @Test func discoveringAPeerEmitsDiscoveredState() {
        let transport = MockMultipeerTransport()
        var states: [MultipeerSession.State] = []
        let cancellable = transport.state.sink { states.append($0) }
        defer { cancellable.cancel() }

        let alice = makePeer(name: "Alice")
        transport.simulateDiscovery(peer: alice)

        guard case .discovered(let peers) = states.last else {
            Issue.record("Expected .discovered state, got \(String(describing: states.last))")
            return
        }
        #expect(peers.count == 1)
        #expect(peers.first?.displayName == "Alice")
    }

    @Test func peerLossEmitsDiscoveredStateWithReducedList() {
        let transport = MockMultipeerTransport()
        var states: [MultipeerSession.State] = []
        let cancellable = transport.state.sink { states.append($0) }
        defer { cancellable.cancel() }

        let alice = makePeer(name: "Alice")
        let bob = makePeer(name: "Bob")
        transport.simulateDiscovery(peer: alice)
        transport.simulateDiscovery(peer: bob)
        transport.simulatePeerLost(peer: alice)

        guard case .discovered(let peers) = states.last else {
            Issue.record("Expected .discovered state, got \(String(describing: states.last))")
            return
        }
        #expect(peers.count == 1)
        #expect(peers.first?.displayName == "Bob")
    }

    @Test func acceptingAnInviteTransitionsToConnecting() async throws {
        let transport = MockMultipeerTransport()
        var states: [MultipeerSession.State] = []
        let cancellable = transport.state.sink { states.append($0) }
        defer { cancellable.cancel() }

        let charlie = makePeer(name: "Charlie")
        transport.simulateInvite(from: charlie, info: [:])

        guard case .awaitingLocalAcceptance(let invite) = states.last else {
            Issue.record("Expected .awaitingLocalAcceptance state, got \(String(describing: states.last))")
            return
        }

        try await transport.accept(invite)
        #expect(states.last == .connecting(charlie))
    }

    @Test func inboundMessagePublishesWithCorrectBytes() {
        let transport = MockMultipeerTransport()
        var received: [MultipeerSession.InboundMessage] = []
        let cancellable = transport.inbound.sink { received.append($0) }
        defer { cancellable.cancel() }

        let dave = makePeer(name: "Dave")
        let payload = Data([0xDE, 0xAD, 0xBE])
        transport.simulateInboundData(payload, from: dave)

        #expect(received.count == 1)
        #expect(received.first?.data == payload)
        #expect(received.first?.bytesReceived == 3)
        #expect(received.first?.peer.displayName == "Dave")
    }

    @Test func disconnectTransitionsToIdle() async {
        let transport = MockMultipeerTransport()
        var states: [MultipeerSession.State] = []
        let cancellable = transport.state.sink { states.append($0) }
        defer { cancellable.cancel() }

        let eve = makePeer(name: "Eve")
        transport.simulateConnected(peer: eve)
        await transport.disconnect()

        #expect(states.last == .idle)
    }

    @Test func peerIDPersistsAcrossInit() throws {
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".archive")

        let store = FileMCPeerIDStore(fileURL: tempURL)
        _ = MultipeerSession(peerIDStore: store)

        let bytesAfterFirst = try Data(contentsOf: tempURL)

        _ = MultipeerSession(peerIDStore: store)
        let bytesAfterSecond = try Data(contentsOf: tempURL)

        #expect(bytesAfterFirst == bytesAfterSecond)
    }
}
