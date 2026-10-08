// FriendStateExchange.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.7: the fuzzy friend state's mesh wiring (Phase 4), moved from the mesh
// manager with no byte, golden or audit change: the opt-in that gates the advertised `friendState`
// capability; the `.friendState` handler, registered through the mesh's payload token door, which hands
// a vault-trusted, unblocked friend's well-formed state to the app; and the commit-time send of this
// device's own state to a vault-trusted friend, through the mesh's captured-slot feature send.
//
// The mesh calls none of it directly. The handler reaches it through the payload registry, the opt-in
// through the capability list the composition advertises (`FernletMeshCapabilities`), and the commit
// through FernletSocial's mesh composition (`FernletMeshFeatures`), whose session observer calls the
// commit leg after the moderation relay's, in the order the mesh manager ran them.

import Foundation
import FernletDomainModel
import ProximityKit

/// The fuzzy friend state's mesh adapter (Phase 4): this device's fuzzy state + appearance, shared with a
/// committed friend kept in person while the user opts in, and such a friend's state, handed to the app.
///
/// Built by the composition (``FernletMeshFeatures``) over its mesh, held weakly, and the features' host
/// holder, which answers the blocked-fingerprint and vault-trust questions, carries the namespace the
/// `friendState` capability token is read in and pins the host for a spawned send. The app wires the
/// opt-in, the provider and the sink (``FernletMeshFeatures/friendState``); the handler and the commit
/// leg are not its API. `@MainActor`, like the mesh and the frames that drive it.
@MainActor
public final class FriendStateExchange {

    /// Phase 4 (fuzzy state): whether the user opted into sharing, which gates the advertised
    /// `friendState` capability (the composition's capability list reads it).
    public var isEnabledProvider: (() -> Bool)?

    /// The local fuzzy-state + appearance payload to send; nil (opted out) sends nothing.
    public var payloadProvider: (() -> FriendStatePayload?)?

    /// The sink for a friend's received state, with the friend's verified fingerprint.
    public var onFriendStateReceived: ((String, FriendStatePayload) -> Void)?

    /// The mesh the handler is registered on and the send goes through. Weak: the composition owns
    /// the mesh, and a send spawned after it is gone does nothing, as one spawned by the mesh itself
    /// did once the mesh was gone.
    private weak var mesh: MeshNetworkManager?

    /// The host the blocked fingerprints and the trusted peers are read from, the namespace the
    /// `friendState` capability is read in, and the one helper that pins the host for a spawned send.
    private let meshHost: FernletMeshHost

    /// An exchange over `mesh` and `meshHost`.
    ///
    /// - Parameters:
    ///   - mesh: The composition's mesh, held weakly.
    ///   - meshHost: The features' host holder.
    init(mesh: MeshNetworkManager, meshHost: FernletMeshHost) {
        self.mesh = mesh
        self.meshHost = meshHost
    }

    // MARK: - Inbound

    /// Phase 4: fuzzy state + appearance exchange rides the friend session, through the mesh's payload
    /// token door. The committed-slot gate has run; require a verified, unblocked, vault-trusted sender
    /// and a well-formed payload, then hand it to the app (which applies its own opt-in + caches). Sealed
    /// (in Fernlet's `payloads.sealingRequired`). The handler holds this exchange weakly, so the mesh
    /// retaining it forms no cycle.
    ///
    /// - Parameter mesh: The mesh to register on: the composition's, while it is built.
    func registerHandler(on mesh: MeshNetworkManager) {
        mesh.registerPayloadHandler(forToken: PayloadType.friendState.rawValue) { [weak self] _, plaintext, peer in
            guard let self, let peer else { return }
            guard !self.meshHost.host.isBlockedFingerprint(peer.fingerprint) else { return }
            guard self.meshHost.host.proximityTrustStore.isTrustedProximityPeer(signingPublicKey: peer.signingPublicKey) else { return }
            guard let payload = try? JSONDecoder().decode(FriendStatePayload.self, from: plaintext),
                  payload.isWellFormed else { return }
            self.onFriendStateReceived?(peer.fingerprint, payload)
        }
    }

    // MARK: - The session's moments (called by the composition's session observer)

    /// The state at a slot commit: share our fuzzy vibe + appearance with this committed friend, when it
    /// advertises the `friendState` capability, in a task of its own. The send additionally requires
    /// the recipient be a vault-trusted (kept) friend.
    ///
    /// - Parameters:
    ///   - slot: The committed seat, as it stood at the commit: the send goes to it as captured.
    ///   - peerIdentity: Its peer's verified identity.
    func offerState(to slot: PeerSlot, peer peerIdentity: ProximityCoordinator.PeerIdentity) {
        // Phase 4: share our fuzzy vibe + appearance with this committed friend (kept friends only).
        if peerIdentity.supports(ProximityCapability.friendState.rawValue, in: meshHost.namespace.family.vocabulary.capabilities) {
            let recipientKey = peerIdentity.signingPublicKey
            meshHost.spawnHostPinned { [weak self] in await self?.sendFriendState(to: slot, recipientSigningKey: recipientKey) }
        }
    }

    // MARK: - Outbound

    /// Sends our fuzzy state + appearance to a committed friend. Gated on the recipient being a
    /// vault-TRUSTED (kept-in-person) peer — symmetric with the receive handler — so the fuzzy wellbeing
    /// vibe never leaks to a merely-committed stranger. A nil provider (opt-out) also sends nothing.
    ///
    /// - Parameters:
    ///   - slot: The seat to send to, as captured.
    ///   - recipientSigningKey: The committed peer's verified signing key, which the vault must trust.
    private func sendFriendState(to slot: PeerSlot, recipientSigningKey: Data) async {
        guard let mesh else { return }
        guard meshHost.host.proximityTrustStore.isTrustedProximityPeer(signingPublicKey: recipientSigningKey) else { return }
        guard let payload = payloadProvider?() else { return }
        await mesh.sendFeatureEnvelope(PayloadType.friendState.rawValue, encodable: payload, via: slot, sealed: true)
    }
}
