import Foundation
@testable import ProximityKit

// The manager-side half of the transport seam P2 item 8 introduced. `FakePeerTransport` beside it is
// a per-peer CHANNEL on an in-memory fabric; this is the shared RADIO that vends those channels and
// records what its owner asked it to do.
//
// Before the seam existed, `MeshNetworkManager` owned `private let meshSession =
// MeshMultipeerSession()` outright, so nothing at tier 1 could observe an invite being SENT — only
// the decision to send one. Everything recorded here is a thing the manager did to its radio, and
// everything in "Driving the owner" is a thing a radio does to the manager.

/// An in-memory ``MeshTransportSession``: records every call the manager makes, and lets a test fire
/// every callback a live radio would.
///
/// Deliberately not a state machine. A fake that invented advertising/browsing behaviour would test
/// a shape production does not have — the two real conformers each own that themselves, and what the
/// manager can be held to is only what crosses this surface.
@MainActor
final class FakeMeshTransportSession: MeshTransportSession {

    /// The fabric this session's channels live on, so a test that wants to move frames between two
    /// endpoints has one ready. Unused by the manager itself, which never touches a channel's wire.
    let network = FakePeerNetwork()

    // MARK: Recorded calls

    private(set) var handlers = MeshTransportHandlers()
    /// The authority the owner attached, if any. `nil` after construction is the honest reading of
    /// "this radio cannot authenticate anybody".
    private(set) weak var attachedAuthority: (any MeshIntroductionAuthority)?
    private(set) var startedDiscoveryInfo: [[String: String]] = []
    private(set) var republishedDiscoveryInfo: [[String: String]] = []
    private(set) var stopCount = 0
    private(set) var invitedPeers: [PeerHandle] = []
    private(set) var disconnectedPeers: [PeerHandle] = []

    // MARK: - MeshTransportSession

    func wire(_ handlers: MeshTransportHandlers) {
        self.handlers = handlers
    }

    func attachIntroductionAuthority(_ authority: any MeshIntroductionAuthority) {
        attachedAuthority = authority
    }

    func startRadios(discoveryInfo: [String: String]) {
        startedDiscoveryInfo.append(discoveryInfo)
    }

    func stop() {
        stopCount += 1
    }

    func updateDiscoveryInfo(_ info: [String: String]) {
        republishedDiscoveryInfo.append(info)
    }

    func invite(_ peer: PeerHandle) {
        invitedPeers.append(peer)
    }

    func disconnectPeer(_ peer: PeerHandle) {
        disconnectedPeers.append(peer)
    }

    // MARK: - Driving the owner

    /// Adds an endpoint to the fabric and returns the channel a radio would hand up for it.
    func makeChannel(named name: String) -> (channel: FakePeerTransport, handle: PeerHandle) {
        let endpoint = network.addEndpoint(named: name)
        return (endpoint.transport, endpoint.handle)
    }

    /// A peer appeared in discovery.
    func discover(_ peer: PeerHandle) {
        handlers.onPeerDiscovered?(peer)
    }

    /// A peer's channel came up.
    func connect(_ channel: FakePeerTransport) {
        handlers.onChannelReady?(channel)
    }

    /// A peer's link dropped.
    func drop(_ peer: PeerHandle, reason: String = "Peer disconnected") {
        handlers.onPeerDisconnected?(peer, reason)
    }

    /// Asks the owner's admission gate about an inbound connection. Fails closed when nothing is
    /// wired, exactly as both real radios do.
    func offerInboundConnection(from peer: PeerHandle) -> Bool {
        handlers.shouldAcceptInvitation?(peer) ?? false
    }

    /// Discovery failed to start.
    func failDiscovery(_ message: String) {
        handlers.onTransportError?(message)
    }
}
