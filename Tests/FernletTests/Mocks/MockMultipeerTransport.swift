import ProximityKit
import Foundation
import MultipeerConnectivity
import Combine
import FernletDomainModel
@testable import Fernlet

@MainActor
final class MockMultipeerTransport: MultipeerTransport {

    private let stateSubject = CurrentValueSubject<MultipeerTransportState, Never>(.idle)
    private let inboundSubject = PassthroughSubject<MultipeerInboundMessage, Never>()

    var state: AnyPublisher<MultipeerTransportState, Never> { stateSubject.eraseToAnyPublisher() }
    var inbound: AnyPublisher<MultipeerInboundMessage, Never> { inboundSubject.eraseToAnyPublisher() }
    var connectedPeers: [MultipeerPeer] = []

    // Recorded calls
    var advertisingStarted = false
    var browsingStarted = false
    var lastServiceType: String?
    var lastDiscoveryInfo: [String: String]?
    var disconnectCalled = false
    var sendDelayNanoseconds: UInt64 = 0
    var sentData: [(Data, MultipeerPeer, MCSessionSendDataMode)] = []
    var acceptedInvites: [MultipeerPendingInvite] = []

    // MARK: MultipeerTransport

    func startAdvertising(serviceType: String, discoveryInfo: [String: String]) async throws {
        advertisingStarted = true
        lastServiceType = serviceType
        lastDiscoveryInfo = discoveryInfo
        stateSubject.send(.advertising)
    }

    func startBrowsing(serviceType: String) async throws {
        browsingStarted = true
        lastServiceType = serviceType
        stateSubject.send(.browsing)
    }

    func invite(_ peer: MultipeerPeer) async throws {
        stateSubject.send(.awaitingPeerAcceptance(peer))
    }

    func accept(_ invite: MultipeerPendingInvite) async throws {
        acceptedInvites.append(invite)
        invite.respond(true)
    }

    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws {
        if sendDelayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: sendDelayNanoseconds)
        }
        sentData.append((data, peer, mode))
    }

    func disconnect() async {
        disconnectCalled = true
        connectedPeers = []
        stateSubject.send(.idle)
    }

    // MARK: Simulation helpers

    func simulateDiscovery(peer: MultipeerPeer) {
        if case .discovered(let existing) = stateSubject.value {
            stateSubject.send(.discovered(existing + [peer]))
        } else {
            stateSubject.send(.discovered([peer]))
        }
    }

    func simulatePeerLost(peer: MultipeerPeer) {
        if case .discovered(let existing) = stateSubject.value {
            stateSubject.send(.discovered(existing.filter { $0.id != peer.id }))
        }
    }

    func simulateInvite(from peer: MultipeerPeer, info: [String: String] = [:]) {
        let invite = MultipeerPendingInvite(
            peer: peer,
            advertisedInfo: info,
            context: nil,
            respond: { [weak self] accepted in
                guard let self, accepted else { return }
                self.stateSubject.send(.connecting(peer))
            }
        )
        stateSubject.send(.awaitingLocalAcceptance(invite))
    }

    /// The MC-realistic two-step: a `.connecting` event lands before `.connected` (the real
    /// session delegate always reports both), which is what puts a trainer coordinator into
    /// `.awaitingTapConfirmation` BEFORE the connected event — the second of the tap-gate
    /// auto-advance's two entry points.
    func simulateConnecting(peer: MultipeerPeer) {
        stateSubject.send(.connecting(peer))
    }

    func simulateConnected(peer: MultipeerPeer) {
        connectedPeers = [peer]
        stateSubject.send(.connected(peer))
    }

    func simulateInboundData(_ data: Data, from peer: MultipeerPeer) {
        let msg = MultipeerInboundMessage(peer: peer, data: data, receivedAt: Date(), bytesReceived: data.count)
        inboundSubject.send(msg)
    }

    func simulateDisconnection() {
        connectedPeers = []
        stateSubject.send(.disconnected(reason: "Simulated disconnection"))
    }
}
