import Foundation
import MultipeerConnectivity
import Combine
import FernletDomainModel

nonisolated enum MultipeerServiceType {
    static let trainer = "fernlet-coach"
}

enum MultipeerTransportState: Equatable {
    case idle
    case advertising
    case browsing
    case discovered([MultipeerPeer])
    case awaitingPeerAcceptance(MultipeerPeer)
    case awaitingLocalAcceptance(MultipeerPendingInvite)
    case connecting(MultipeerPeer)
    case connected(MultipeerPeer)
    case disconnected(reason: String)
    case failed(MultipeerTransportError)

    static func == (lhs: MultipeerTransportState, rhs: MultipeerTransportState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.advertising, .advertising), (.browsing, .browsing):
            return true
        case (.discovered(let a), .discovered(let b)):                       return a == b
        case (.awaitingPeerAcceptance(let a), .awaitingPeerAcceptance(let b)): return a == b
        case (.awaitingLocalAcceptance(let a), .awaitingLocalAcceptance(let b)): return a == b
        case (.connecting(let a), .connecting(let b)):                       return a == b
        case (.connected(let a), .connected(let b)):                         return a == b
        case (.disconnected(let a), .disconnected(let b)):                   return a == b
        case (.failed(let a), .failed(let b)):                               return a == b
        default: return false
        }
    }
}

struct MultipeerPendingInvite: Equatable {
    let peer: MultipeerPeer
    let advertisedInfo: [String: String]
    let context: Data?
    let respond: (Bool) -> Void

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.peer == rhs.peer && lhs.advertisedInfo == rhs.advertisedInfo && lhs.context == rhs.context
    }
}

enum MultipeerTransportError: Equatable, Error {
    case wifiUnavailable, bluetoothUnavailable, peerIDLoadFailed
    case sessionRejected, sessionTimeout, unexpectedState
    case sendFailed(reason: String)
}

struct MultipeerInboundMessage {
    let peer: MultipeerPeer
    let data: Data
    let receivedAt: Date
    let bytesReceived: Int
}

@MainActor
protocol MultipeerTransport: AnyObject {
    var state: AnyPublisher<MultipeerTransportState, Never> { get }
    var inbound: AnyPublisher<MultipeerInboundMessage, Never> { get }
    var connectedPeers: [MultipeerPeer] { get }

    func startAdvertising(serviceType: String, discoveryInfo: [String: String]) async throws
    func startBrowsing(serviceType: String) async throws
    func invite(_ peer: MultipeerPeer) async throws
    func accept(_ invite: MultipeerPendingInvite) async throws
    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws
    func disconnect() async
}
