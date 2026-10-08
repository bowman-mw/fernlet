// ModerationReportExchange.swift
// FernletSocial/Moderation
//
// ProximityKit plan step A0.5.7: the moderation report relay's mesh wiring (Phase 3b), moved from the
// mesh manager with no byte, golden or audit change: the `.itemReport` handler, registered through the
// mesh's payload token door, which keeps a vault-trusted, unblocked friend's own verified rows for the
// app; and the commit-time send of this device's own signed reports to a vault-trusted friend, through
// the mesh's captured-slot feature send, signed by the device identity the mesh was built with. The relay
// itself (`ModerationReportRelay`) builds and verifies the payload, unchanged.
//
// The mesh calls none of it directly. The handler reaches it through the payload registry, and the
// commit through FernletSocial's mesh composition (`FernletMeshFeatures`), whose session observer calls
// the commit leg after the clothing shop's, in the order the mesh manager ran them.

import Foundation
import FernletDomainModel
import FernletFoundation
import ProximityKit

/// The moderation report relay's mesh adapter (Phase 3b): this device's own signed reports, handed to a
/// committed friend kept in person, and such a friend's verified report rows, handed to the app.
///
/// Built by the composition (``FernletMeshFeatures``) over its mesh, held weakly; the features' host
/// holder, which answers the blocked-fingerprint and vault-trust questions, carries the namespace the
/// `moderation` capability token is read in and pins the host for a spawned send; and the composition's
/// device identity, the one its mesh was built with, which signs the rows. The app wires the provider
/// and the sink (``FernletMeshFeatures/moderation``); the handler and the commit leg are not its API.
/// `@MainActor`, like the mesh and the frames that drive it.
@MainActor
public final class ModerationReportExchange {

    /// Phase 3b (one-hop moderation relay): the local user's own moderation report rows, supplied by the
    /// app so the relay signs + hands them to a committed friend.
    public var ownModerationReportsProvider: (() -> [ModerationLedgerEntry])?

    /// The sink for peers' verified report rows (stored + reconciled by the app).
    public var onModerationRowsReceived: (([ModerationLedgerEntry]) -> Void)?

    /// The mesh the handler is registered on and the send goes through. Weak: the composition owns
    /// the mesh, and a send spawned after it is gone does nothing, as one spawned by the mesh itself
    /// did once the mesh was gone.
    private weak var mesh: MeshNetworkManager?

    /// The host the blocked fingerprints and the trusted peers are read from, the namespace the
    /// `moderation` capability is read in, and the one helper that pins the host for a spawned send.
    private let meshHost: FernletMeshHost

    /// The device identity the composition built its mesh with, which signs this device's own rows.
    private let identity: IdentityService

    /// An exchange over `mesh` and `meshHost`, signing with `identity`.
    ///
    /// - Parameters:
    ///   - mesh: The composition's mesh, held weakly.
    ///   - meshHost: The features' host holder.
    ///   - identity: The device identity the composition handed its mesh.
    init(mesh: MeshNetworkManager, meshHost: FernletMeshHost, identity: IdentityService) {
        self.mesh = mesh
        self.meshHost = meshHost
        self.identity = identity
    }

    // MARK: - Inbound

    /// Phase 3b: one-hop moderation reports ride the friend mesh, through the mesh's payload token
    /// door. The committed-slot gate has already run; the remaining guards require a transport-verified,
    /// unblocked, vault-TRUSTED sender (reports count only from friends accepted in person — the Sybil
    /// defense). `.itemReport` is sealed, so an unsealed bundle was already rejected at `verify()`; each
    /// row's Ed25519 signature is re-checked against the sender key inside `verifiedRows`, and rows the
    /// sender didn't personally sign drop. The handler holds this exchange weakly, so the mesh retaining
    /// it forms no cycle.
    ///
    /// - Parameter mesh: The mesh to register on: the composition's, while it is built.
    func registerHandler(on mesh: MeshNetworkManager) {
        mesh.registerPayloadHandler(forToken: PayloadType.itemReport.rawValue) { [weak self] _, plaintext, peer in
            guard let self else { return }
            guard let peer else {
                FernletAuditLog.log("mesh.itemReport.droppedUnverifiedSender")
                return
            }
            guard !self.meshHost.host.isBlockedFingerprint(peer.fingerprint) else { return }
            guard self.meshHost.host.proximityTrustStore.isTrustedProximityPeer(signingPublicKey: peer.signingPublicKey) else { return }
            guard let payload = try? JSONDecoder().decode(ModerationReportPayload.self, from: plaintext) else { return }
            let rows = ModerationReportRelay.verifiedRows(
                from: payload, senderSigningKey: peer.signingPublicKey, now: Date())
            guard !rows.isEmpty else { return }
            self.onModerationRowsReceived?(rows)
        }
    }

    // MARK: - The session's moments (called by the composition's session observer)

    /// The reports at a slot commit: hand our own signed moderation reports to this committed friend
    /// (one-hop relay), when it advertises the `moderation` capability, in a task of their own. The send
    /// additionally requires the recipient be a vault-trusted (kept) friend.
    ///
    /// - Parameters:
    ///   - slot: The committed seat, as it stood at the commit: the send goes to it as captured.
    ///   - peerIdentity: Its peer's verified identity.
    func offerReports(to slot: PeerSlot, peer peerIdentity: ProximityCoordinator.PeerIdentity) {
        // Phase 3b: hand our own signed moderation reports to this committed friend (one-hop relay).
        // The send method additionally requires the recipient be a vault-trusted (kept) friend.
        if peerIdentity.supports(ProximityCapability.moderation.rawValue, in: meshHost.namespace.family.vocabulary.capabilities) {
            let recipientKey = peerIdentity.signingPublicKey
            meshHost.spawnHostPinned { [weak self] in await self?.sendModerationReports(to: slot, recipientSigningKey: recipientKey) }
        }
    }

    // MARK: - Outbound

    /// Hands this device's OWN signed reports to a committed friend (one-hop). Gated on the recipient
    /// being a vault-TRUSTED (kept-in-person) peer — symmetric with the receive handler — so your signed,
    /// non-repudiable reports never leak to a merely-committed stranger you didn't keep as a friend. No
    /// provider, an empty set, or no signable rows → sends nothing.
    ///
    /// - Parameters:
    ///   - slot: The seat to send to, as captured.
    ///   - recipientSigningKey: The committed peer's verified signing key, which the vault must trust.
    private func sendModerationReports(to slot: PeerSlot, recipientSigningKey: Data) async {
        guard let mesh else { return }
        guard meshHost.host.proximityTrustStore.isTrustedProximityPeer(signingPublicKey: recipientSigningKey) else { return }
        guard let rows = ownModerationReportsProvider?(), !rows.isEmpty else { return }
        let payload = ModerationReportRelay.buildPayload(ownReports: rows, identity: identity)
        guard !payload.reports.isEmpty else { return }
        await mesh.sendFeatureEnvelope(PayloadType.itemReport.rawValue, encodable: payload, via: slot, sealed: true)
    }
}
