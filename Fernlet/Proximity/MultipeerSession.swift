import Foundation
import MultipeerConnectivity
import Combine
import UIKit

// MARK: - MultipeerPeer

struct MultipeerPeer: Hashable, Identifiable {
    let id: UUID
    let displayName: String
    let discoveryInfo: [String: String]?
    let advertisedFingerprint: String?
    let underlying: MCPeerID  // internal for @testable access

    static func == (lhs: MultipeerPeer, rhs: MultipeerPeer) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

// MARK: - MCPeerID persistence

protocol MCPeerIDStoring {
    func load() -> MCPeerID?
    func save(_ peerID: MCPeerID)
}

struct FileMCPeerIDStore: MCPeerIDStoring {
    let fileURL: URL

    init(fileURL: URL? = nil) {
        self.fileURL = fileURL ?? {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            return support.appendingPathComponent("FernletPeerID.archive")
        }()
    }

    func load() -> MCPeerID? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: MCPeerID.self, from: data)
    }

    func save(_ peerID: MCPeerID) {
        guard let data = try? NSKeyedArchiver.archivedData(withRootObject: peerID, requiringSecureCoding: true) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

// MARK: - MultipeerTransport protocol

@MainActor
protocol MultipeerTransport: AnyObject {
    var state: AnyPublisher<MultipeerSession.State, Never> { get }
    var inbound: AnyPublisher<MultipeerSession.InboundMessage, Never> { get }
    var connectedPeers: [MultipeerPeer] { get }

    func startAdvertising(serviceType: String, discoveryInfo: [String: String]) async throws
    func startBrowsing(serviceType: String) async throws
    func invite(_ peer: MultipeerPeer) async throws
    func accept(_ invite: MultipeerSession.PendingInvite) async throws
    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws
    func disconnect() async
}

// MARK: - MultipeerSession

@MainActor
final class MultipeerSession: NSObject, MultipeerTransport {

    static let defaultServiceType = "fernlet-coach"

    // MARK: Nested types

    enum State: Equatable {
        case idle
        case advertising
        case browsing
        case discovered([MultipeerPeer])
        case awaitingPeerAcceptance(MultipeerPeer)
        case awaitingLocalAcceptance(PendingInvite)
        case connecting(MultipeerPeer)
        case connected(MultipeerPeer)
        case disconnected(reason: String)
        case failed(MultipeerError)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.advertising, .advertising), (.browsing, .browsing):
                return true
            case (.discovered(let a), .discovered(let b)):             return a == b
            case (.awaitingPeerAcceptance(let a), .awaitingPeerAcceptance(let b)): return a == b
            case (.awaitingLocalAcceptance(let a), .awaitingLocalAcceptance(let b)): return a == b
            case (.connecting(let a), .connecting(let b)):             return a == b
            case (.connected(let a), .connected(let b)):               return a == b
            case (.disconnected(let a), .disconnected(let b)):         return a == b
            case (.failed(let a), .failed(let b)):                     return a == b
            default: return false
            }
        }
    }

    struct PendingInvite: Equatable {
        let peer: MultipeerPeer
        let advertisedInfo: [String: String]
        let context: Data?
        let respond: (Bool) -> Void

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.peer == rhs.peer && lhs.advertisedInfo == rhs.advertisedInfo && lhs.context == rhs.context
        }
    }

    enum MultipeerError: Equatable, Error {
        case wifiUnavailable, bluetoothUnavailable, peerIDLoadFailed
        case sessionRejected, sessionTimeout, unexpectedState
        case sendFailed(reason: String)
    }

    struct InboundMessage {
        let peer: MultipeerPeer
        let data: Data
        let receivedAt: Date
        let bytesReceived: Int
    }

    // MARK: Properties

    private let peerIDStore: any MCPeerIDStoring
    let localPeerID: MCPeerID
    private var mcSession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?
    private var discoveredPeers: [MCPeerID: MultipeerPeer] = [:]

    private let stateSubject = CurrentValueSubject<State, Never>(.idle)
    private let inboundSubject = PassthroughSubject<InboundMessage, Never>()

    var state: AnyPublisher<State, Never> { stateSubject.eraseToAnyPublisher() }
    var inbound: AnyPublisher<InboundMessage, Never> { inboundSubject.eraseToAnyPublisher() }
    var connectedPeers: [MultipeerPeer] { mcSession?.connectedPeers.compactMap { discoveredPeers[$0] } ?? [] }

    // MARK: Init

    init(peerIDStore: (any MCPeerIDStoring)? = nil) {
        let store: any MCPeerIDStoring = peerIDStore ?? FileMCPeerIDStore()
        self.peerIDStore = store
        if let existing = store.load() {
            self.localPeerID = existing
        } else {
            let new = MCPeerID(displayName: UIDevice.current.name)
            self.localPeerID = new
            store.save(new)
        }
        super.init()
    }

    // MARK: MultipeerTransport

    func startAdvertising(serviceType: String, discoveryInfo: [String: String]) async throws {
        ensureSession()
        let adv = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: discoveryInfo, serviceType: serviceType)
        adv.delegate = self
        advertiser = adv
        adv.startAdvertisingPeer()
        stateSubject.send(.advertising)
    }

    func startBrowsing(serviceType: String) async throws {
        ensureSession()
        let br = MCNearbyServiceBrowser(peer: localPeerID, serviceType: serviceType)
        br.delegate = self
        browser = br
        br.startBrowsingForPeers()
        stateSubject.send(.browsing)
    }

    func invite(_ peer: MultipeerPeer) async throws {
        guard let session = mcSession else { throw MultipeerError.unexpectedState }
        browser?.invitePeer(peer.underlying, to: session, withContext: nil, timeout: 30)
        stateSubject.send(.awaitingPeerAcceptance(peer))
    }

    func accept(_ invite: PendingInvite) async throws {
        invite.respond(true)
        stateSubject.send(.connecting(invite.peer))
    }

    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws {
        guard let session = mcSession else { throw MultipeerError.unexpectedState }
        do {
            try session.send(data, toPeers: [peer.underlying], with: mode)
        } catch {
            throw MultipeerError.sendFailed(reason: error.localizedDescription)
        }
    }

    func disconnect() async {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        mcSession?.disconnect()
        advertiser = nil
        browser = nil
        mcSession = nil
        discoveredPeers = [:]
        stateSubject.send(.idle)
    }

    // MARK: Helpers

    private func ensureSession() {
        guard mcSession == nil else { return }
        let session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .optional)
        session.delegate = self
        mcSession = session
    }

    private func peer(for mcPeerID: MCPeerID, discoveryInfo: [String: String]? = nil) -> MultipeerPeer {
        if let existing = discoveredPeers[mcPeerID] { return existing }
        let peer = MultipeerPeer(
            id: UUID(),
            displayName: mcPeerID.displayName,
            discoveryInfo: discoveryInfo,
            advertisedFingerprint: discoveryInfo?["fp"],
            underlying: mcPeerID
        )
        discoveredPeers[mcPeerID] = peer
        return peer
    }
}

// MARK: - MCSessionDelegate

extension MultipeerSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peer(for: peerID)
            switch state {
            case .connecting:   self.stateSubject.send(.connecting(peer))
            case .connected:    self.stateSubject.send(.connected(peer))
            case .notConnected: self.stateSubject.send(.disconnected(reason: "Peer disconnected"))
            @unknown default:   break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peer(for: peerID)
            self.inboundSubject.send(InboundMessage(peer: peer, data: data, receivedAt: Date(), bytesReceived: data.count))
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MultipeerSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID, withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peer(for: peerID)
            let session = self.mcSession
            let invite = PendingInvite(
                peer: peer,
                advertisedInfo: [:],
                context: context,
                respond: { accepted in invitationHandler(accepted, accepted ? session : nil) }
            )
            self.stateSubject.send(.awaitingLocalAcceptance(invite))
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {
        Task { @MainActor [weak self] in self?.stateSubject.send(.failed(.unexpectedState)) }
    }
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            _ = self.peer(for: peerID, discoveryInfo: info)
            self.stateSubject.send(.discovered(Array(self.discoveredPeers.values)))
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.discoveredPeers.removeValue(forKey: peerID)
            self.stateSubject.send(.discovered(Array(self.discoveredPeers.values)))
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {
        Task { @MainActor [weak self] in self?.stateSubject.send(.failed(.unexpectedState)) }
    }
}
