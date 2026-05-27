import Foundation
import MultipeerConnectivity
import Combine
import UIKit

// MARK: - PeerChannelTransport

/// Per-peer MultipeerTransport adapter for mesh slots.
/// MeshMultipeerSession manages the shared MCSession; this type routes
/// state and data events for a single peer without managing MC lifecycle.
@MainActor
final class PeerChannelTransport: MultipeerTransport {
    let peer: MultipeerPeer
    private weak var session: MeshMultipeerSession?

    private let stateSubject = CurrentValueSubject<MultipeerSession.State, Never>(.idle)
    private let inboundSubject = PassthroughSubject<MultipeerSession.InboundMessage, Never>()

    var state: AnyPublisher<MultipeerSession.State, Never> { stateSubject.eraseToAnyPublisher() }
    var inbound: AnyPublisher<MultipeerSession.InboundMessage, Never> { inboundSubject.eraseToAnyPublisher() }
    var connectedPeers: [MultipeerPeer] { [] }

    init(peer: MultipeerPeer, session: MeshMultipeerSession) {
        self.peer = peer
        self.session = session
    }

    // MC advertising/browsing is handled by MeshMultipeerSession, not per-channel
    func startAdvertising(serviceType: String, discoveryInfo: [String: String]) async throws {}
    func startBrowsing(serviceType: String) async throws {}
    func invite(_ peer: MultipeerPeer) async throws {}
    func accept(_ invite: MultipeerSession.PendingInvite) async throws {}

    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws {
        guard let session else { throw MultipeerSession.MultipeerError.unexpectedState }
        try await session.send(data, to: peer, mode: mode)
    }

    func disconnect() async {
        // Only signals idle locally — does not disconnect the shared MCSession
        stateSubject.send(.idle)
    }

    // MARK: - Called by MeshMultipeerSession

    func notifyConnected() {
        stateSubject.send(.connected(peer))
    }

    func notifyDisconnected(reason: String = "Peer disconnected") {
        stateSubject.send(.disconnected(reason: reason))
    }

    func receive(_ data: Data) {
        inboundSubject.send(MultipeerSession.InboundMessage(
            peer: peer,
            data: data,
            receivedAt: Date(),
            bytesReceived: data.count
        ))
    }
}

// MARK: - MeshMultipeerSession

/// Owns a single MCSession shared across all mesh peers.
/// Creates PeerChannelTransport instances on demand and routes MC delegate
/// callbacks to the appropriate channel.
@MainActor
final class MeshMultipeerSession: NSObject {

    static let serviceType = "fernlet-mesh"

    let localPeerID: MCPeerID
    private(set) var channels: [MCPeerID: PeerChannelTransport] = [:]
    private(set) var peerInfoCache: [MCPeerID: [String: String]] = [:]
    private var peerMap: [MCPeerID: MultipeerPeer] = [:]
    private var mcSession: MCSession?
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    var onPeerDiscovered: ((MultipeerPeer) -> Void)?
    var onPeerLost: ((MultipeerPeer) -> Void)?
    var onPeerChannelReady: ((PeerChannelTransport) -> Void)?
    var onPeerDisconnected: ((MultipeerPeer, String) -> Void)?
    var shouldAcceptInvitation: ((MultipeerPeer) -> Bool)?

    init(peerIDStore: (any MCPeerIDStoring)? = nil) {
        let store: any MCPeerIDStoring = peerIDStore ?? FileMCPeerIDStore()
        if let existing = store.load() {
            self.localPeerID = existing
        } else {
            let new = MCPeerID(displayName: UIDevice.current.name)
            self.localPeerID = new
            store.save(new)
        }
        super.init()
    }

    func start(discoveryInfo: [String: String] = [:]) {
        ensureSession()
        startAdvertiser(info: discoveryInfo)
        startBrowser()
    }

    func updateDiscoveryInfo(_ info: [String: String]) {
        advertiser?.stopAdvertisingPeer()
        startAdvertiser(info: info)
    }

    func stop() {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        mcSession?.disconnect()
        advertiser = nil
        browser = nil
        mcSession = nil
        channels.removeAll()
        peerInfoCache.removeAll()
        peerMap.removeAll()
    }

    func invite(_ peer: MultipeerPeer) {
        guard let session = mcSession else { return }
        _ = prepareChannel(for: peer.underlying)
        browser?.invitePeer(peer.underlying, to: session, withContext: nil, timeout: 30)
    }

    func send(_ data: Data, to peer: MultipeerPeer, mode: MCSessionSendDataMode) async throws {
        guard let session = mcSession else {
            throw MultipeerSession.MultipeerError.unexpectedState
        }
        do {
            try session.send(data, toPeers: [peer.underlying], with: mode)
        } catch {
            throw MultipeerSession.MultipeerError.sendFailed(reason: error.localizedDescription)
        }
    }

    func prepareChannel(for mcPeerID: MCPeerID) -> PeerChannelTransport {
        if let existing = channels[mcPeerID] { return existing }
        let p = peer(for: mcPeerID)
        let channel = PeerChannelTransport(peer: p, session: self)
        channels[mcPeerID] = channel
        return channel
    }

    // MARK: - Private helpers

    private func ensureSession() {
        guard mcSession == nil else { return }
        let session = MCSession(peer: localPeerID, securityIdentity: nil, encryptionPreference: .optional)
        session.delegate = self
        mcSession = session
    }

    private func startAdvertiser(info: [String: String]) {
        let adv = MCNearbyServiceAdvertiser(peer: localPeerID, discoveryInfo: info, serviceType: Self.serviceType)
        adv.delegate = self
        advertiser = adv
        adv.startAdvertisingPeer()
    }

    private func startBrowser() {
        let br = MCNearbyServiceBrowser(peer: localPeerID, serviceType: Self.serviceType)
        br.delegate = self
        browser = br
        br.startBrowsingForPeers()
    }

    private func peer(for mcPeerID: MCPeerID, discoveryInfo: [String: String]? = nil) -> MultipeerPeer {
        if let existing = peerMap[mcPeerID] { return existing }
        let info = discoveryInfo ?? peerInfoCache[mcPeerID]
        let p = MultipeerPeer(
            id: UUID(),
            displayName: mcPeerID.displayName,
            discoveryInfo: info,
            advertisedFingerprint: info?["fp"],
            underlying: mcPeerID
        )
        peerMap[mcPeerID] = p
        if let discoveryInfo { peerInfoCache[mcPeerID] = discoveryInfo }
        return p
    }
}

// MARK: - MCSessionDelegate

extension MeshMultipeerSession: MCSessionDelegate {
    nonisolated func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peer(for: peerID)
            switch state {
            case .connected:
                let channel = self.prepareChannel(for: peerID)
                channel.notifyConnected()
                self.onPeerChannelReady?(channel)
            case .notConnected:
                if let channel = self.channels[peerID] {
                    channel.notifyDisconnected()
                }
                self.channels.removeValue(forKey: peerID)
                self.onPeerDisconnected?(peer, "Peer disconnected")
            case .connecting:
                break
            @unknown default:
                break
            }
        }
    }

    nonisolated func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self, let channel = self.channels[peerID] else { return }
            channel.receive(data)
        }
    }

    nonisolated func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    nonisolated func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    nonisolated func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - MCNearbyServiceAdvertiserDelegate

extension MeshMultipeerSession: MCNearbyServiceAdvertiserDelegate {
    nonisolated func advertiser(
        _ advertiser: MCNearbyServiceAdvertiser,
        didReceiveInvitationFromPeer peerID: MCPeerID,
        withContext context: Data?,
        invitationHandler: @escaping (Bool, MCSession?) -> Void
    ) {
        Task { @MainActor [weak self] in
            guard let self else { invitationHandler(false, nil); return }
            let peer = self.peer(for: peerID)
            let accept = self.shouldAcceptInvitation?(peer) ?? false
            if accept { _ = self.prepareChannel(for: peerID) }
            invitationHandler(accept, accept ? self.mcSession : nil)
        }
    }

    nonisolated func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didNotStartAdvertisingPeer error: Error) {}
}

// MARK: - MCNearbyServiceBrowserDelegate

extension MeshMultipeerSession: MCNearbyServiceBrowserDelegate {
    nonisolated func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let info { self.peerInfoCache[peerID] = info }
            let peer = self.peer(for: peerID, discoveryInfo: info)
            self.onPeerDiscovered?(peer)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let peer = self.peer(for: peerID)
            self.peerMap.removeValue(forKey: peerID)
            self.onPeerLost?(peer)
        }
    }

    nonisolated func browser(_ browser: MCNearbyServiceBrowser, didNotStartBrowsingForPeers error: Error) {}
}
