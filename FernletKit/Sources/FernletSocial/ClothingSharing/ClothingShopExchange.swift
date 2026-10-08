// ClothingShopExchange.swift
// FernletSocial/ClothingSharing
//
// ProximityKit plan step A0.5.6: the clothing shop's mesh wiring, moved from the mesh manager with no
// byte, golden or audit change: the two inbound handlers (the catalog and the commit-symmetry request),
// registered through the mesh's payload token door; the commit-time offer and catalog request and the
// request answer, sent through the mesh's captured-slot feature send; the once-per-slot send tracking
// and the request-answer rate limit, pruned when a slot leaves and cleared when the search stops; the
// outbound capability gate; and the shop's two send test seams. The shop itself (`MeshClothingShop`)
// keeps its receive, window and opt-out state, unchanged.
//
// The mesh calls none of it directly. The handlers reach it through the payload registry, and the
// session's moments through FernletSocial's mesh composition (`FernletMeshFeatures`), whose session
// observer calls the commit, slot-loss and search-stop legs below in the order the mesh manager ran
// them, and opens the shop's window at the session's end.

import Foundation
import FernletDomainModel
import FernletFoundation
import ProximityKit

/// The clothing shop's mesh adapter: what the friend mesh sends and receives for the shop (Phase 3a),
/// over the shop the composition owns.
///
/// Built by the composition (``FernletMeshFeatures``) over its mesh, held weakly, and the features' host
/// holder, which answers the blocked-fingerprint question, carries the namespace the capability token is
/// read in and pins the host for a spawned send. Internal: the app reaches the shop
/// (``FernletMeshFeatures/clothingShop``), never this object; the test target reaches its seams through
/// `@testable import`. `@MainActor`, like the mesh and the frames that drive it.
@MainActor
final class ClothingShopExchange {

    /// The shop whose catalogs this exchange receives and whose provider it sends from.
    private let shop: MeshClothingShop

    /// The mesh the handlers are registered on and the sends go through. Weak: the composition owns
    /// the mesh, and a send spawned after it is gone does nothing, as one spawned by the mesh itself
    /// did once the mesh was gone.
    private weak var mesh: MeshNetworkManager?

    /// The host the blocked fingerprints are read from, the namespace the `shop` capability is read in,
    /// and the one helper that pins the host for a spawned send.
    private let meshHost: FernletMeshHost

    /// Slots the local shop catalog was already sent to (belt-and-braces once-per-slot guard — the
    /// commit transition in checkCoordinatorStates fires once per fingerprint change already). Pruned
    /// per-slot on eviction (removeSlot/disconnectSlot) so a rejoining friend re-exchanges — the
    /// transport's peerMap persists across a remote teardown, so a returning peer reuses its old slot
    /// UUID. `clothingCatalogRequest` responses deliberately BYPASS this set (idempotent — the receiver
    /// replaces by fingerprint).
    private var sentShopCatalogSlotIDs: Set<UUID> = []
    /// Per-slot rate limit for `clothingCatalogRequest` responses (request-spam amplification guard:
    /// each response is a full catalog send). Pruned with `sentShopCatalogSlotIDs`.
    private var shopCatalogRequestResponseAt: [UUID: Date] = [:]
    /// Test seam: fires with the slot ID whenever a shop-catalog send is initiated (commit offer or
    /// request response) and the provider produced a catalog — unit tests can't observe the real
    /// channel (no live radio behind the test slots).
    var onShopCatalogSendForTesting: ((UUID) -> Void)?
    /// Test seam: fires AFTER a `clothingCatalogRequest` send completes — i.e. after the commit
    /// task's last touch of mesh state. Tests that drive commits await this so the async send
    /// task drains inside the test's lifetime (the mesh's `unowned store` must not be reached
    /// after the test's store deallocates).
    var onShopCatalogRequestSendForTesting: ((UUID) -> Void)?

    /// An exchange for `shop` over `mesh` and `meshHost`.
    ///
    /// - Parameters:
    ///   - shop: The shop the composition owns.
    ///   - mesh: The composition's mesh, held weakly.
    ///   - meshHost: The features' host holder.
    init(shop: MeshClothingShop, mesh: MeshNetworkManager, meshHost: FernletMeshHost) {
        self.shop = shop
        self.mesh = mesh
        self.meshHost = meshHost
    }

    // MARK: - Inbound

    /// Phase 3a: the shop rides the friend mesh as registered feature payloads, through the mesh's
    /// payload token door. The dispatch default's committed-slot gate has already run by the time these
    /// fire; the remaining guards mirror the routed photo projection: a transport-VERIFIED fingerprint
    /// is required (catalogs are keyed by it exclusively — never a display name) and blocked
    /// fingerprints drop silently. Each handler holds this exchange weakly, so the mesh retaining it
    /// forms no cycle.
    ///
    /// - Parameter mesh: The mesh to register on: the composition's, while it is built.
    func registerHandlers(on mesh: MeshNetworkManager) {
        mesh.registerPayloadHandler(forToken: PayloadType.clothingCatalog.rawValue) { [weak self] envelope, plaintext, peer in
            guard let self else { return }
            guard let fingerprint = peer?.fingerprint else {
                FernletAuditLog.log("mesh.clothingCatalog.droppedUnverifiedSender")
                return
            }
            guard !self.meshHost.host.isBlockedFingerprint(fingerprint) else { return }
            self.shop.receiveCatalog(envelope, plaintext: plaintext, verifiedFingerprint: fingerprint)
        }
        // Commit-symmetry request (spec: "Catalog delivery must not assume commit symmetry"): a
        // committed peer is asking for our catalog because ITS commit landed after OUR once-per-slot
        // send. The payload carries nothing — the verified sender identity is the whole message.
        mesh.registerPayloadHandler(forToken: PayloadType.clothingCatalogRequest.rawValue) { [weak self] _, _, peer in
            guard let self else { return }
            guard let fingerprint = peer?.fingerprint else {
                FernletAuditLog.log("mesh.clothingCatalogRequest.droppedUnverifiedSender")
                return
            }
            guard !self.meshHost.host.isBlockedFingerprint(fingerprint) else { return }
            self.respondToShopCatalogRequest(fromVerifiedFingerprint: fingerprint, identity: peer)
        }
    }

    // MARK: - The session's moments (called by the composition's session observer)

    /// Phase 3a outbound gate: send our catalog only to peers advertising the `shop` capability (a
    /// legacy client would park-and-drop it anyway — skip the bytes), and only while sharing is
    /// enabled locally. Internal seam so tests can pin the gate without a transport.
    ///
    /// - Parameter peerIdentity: A committed peer's verified identity.
    /// - Returns: whether to offer that peer this device's catalog.
    func shouldOfferShopCatalog(to peerIdentity: ProximityCoordinator.PeerIdentity) -> Bool {
        shop.isSharingEnabled
            && peerIdentity.supports(ProximityCapability.shop.rawValue, in: meshHost.namespace.family.vocabulary.capabilities)
    }

    /// Session formation (spec: "'Next session start' = first slot COMMIT, not search start"): the
    /// previous post-session window closes and its catalogs drop, and the send tracking starts over.
    /// Called once per formation, on the mesh's formation fact.
    func beginNewSession() {
        shop.beginNewSession()
        clearShopSendTracking()
    }

    /// The catalog offer at a slot commit — send our catalog once per slot, pairwise sealed (the same
    /// sealed send photos use; `slot.verifiedKeyAgreementPublicKey` was set just before the commit),
    /// capability-gated, nil provider (sharing off) sends nothing — PLUS a `clothingCatalogRequest`
    /// for the peer's catalog: our send fires at OUR commit, but the peer's registry gate requires the
    /// PEER's commit, so a slightly-later committer would drop our catalog forever under once-per-slot
    /// tracking. The request, sent at its own commit, makes the exchange commit-order-independent
    /// (spec: "Catalog delivery must not assume commit symmetry").
    ///
    /// - Parameters:
    ///   - slot: The committed seat, as it stood at the commit: the sends go to it as captured.
    ///   - peerIdentity: Its peer's verified identity.
    func offerCatalog(to slot: PeerSlot, peer peerIdentity: ProximityCoordinator.PeerIdentity) {
        if shouldOfferShopCatalog(to: peerIdentity), sentShopCatalogSlotIDs.insert(slot.id).inserted {
            meshHost.spawnHostPinned { [weak self] in
                await self?.sendShopCatalog(to: slot)
                await self?.sendShopCatalogRequest(to: slot)
            }
        }
    }

    /// Slot eviction prunes the shop send-tracking so a REJOINING friend re-exchanges catalogs: the
    /// transport's peerMap persists across a remote teardown, so a returning peer reuses its old slot
    /// UUID — without this, the once-per-slot guard would silently skip its re-commit send forever.
    ///
    /// - Parameter slotID: The dropped slot's id.
    func pruneShopSendTracking(for slotID: UUID) {
        sentShopCatalogSlotIDs.remove(slotID)
        shopCatalogRequestResponseAt.removeValue(forKey: slotID)
    }

    /// Forgets every slot the catalog was sent to and every request answered: the search stopped, or a
    /// new session formed.
    func clearShopSendTracking() {
        sentShopCatalogSlotIDs.removeAll()
        shopCatalogRequestResponseAt.removeAll()
    }

    // MARK: - Outbound

    /// Answers a verified `clothingCatalogRequest` from a committed, unblocked peer (the registry gate
    /// + handler already enforced both): re-send our catalog to that slot, BYPASSING the once-per-slot
    /// guard — idempotent, the receiver replaces by fingerprint. Rate-limited per slot so a hostile
    /// peer can't use requests as a send-amplification lever, and gated on the same sharing-enabled +
    /// capability checks as the commit-time offer.
    ///
    /// - Parameters:
    ///   - fingerprint: The requester's transport-verified fingerprint.
    ///   - peerIdentity: The identity the mesh credited the request to.
    private func respondToShopCatalogRequest(
        fromVerifiedFingerprint fingerprint: String,
        identity peerIdentity: ProximityCoordinator.PeerIdentity?
    ) {
        guard let mesh else { return }
        guard let peerIdentity, shouldOfferShopCatalog(to: peerIdentity) else { return }
        guard let slot = mesh.slots.first(where: { $0.fingerprint == fingerprint }) else { return }
        let now = Date()
        if let last = shopCatalogRequestResponseAt[slot.id],
           now.timeIntervalSince(last) < MeshClothingShop.perSenderRateLimitSeconds {
            return
        }
        shopCatalogRequestResponseAt[slot.id] = now
        meshHost.spawnHostPinned { [weak self] in await self?.sendShopCatalog(to: slot) }
    }

    /// Sends this device's current catalog to a committed slot, pairwise sealed. A nil provider
    /// result (sharing disabled, or the app never wired it) sends nothing — the payload-layer opt-out.
    ///
    /// - Parameter slot: The seat to send to, as captured.
    private func sendShopCatalog(to slot: PeerSlot) async {
        guard let mesh else { return }
        guard let payload = shop.localCatalogProvider?() else { return }
        onShopCatalogSendForTesting?(slot.id)
        await mesh.sendFeatureEnvelope(PayloadType.clothingCatalog.rawValue, encodable: payload, via: slot, sealed: true)
    }

    /// Asks a just-committed peer for its catalog (commit symmetry — see ``offerCatalog(to:peer:)``).
    /// Signed like every control payload but not sealed: it carries nothing (the summary is the whole
    /// body, mirroring `.sessionGoodbye`), and it is deliberately NOT in Fernlet's `payloads.sealingRequired`.
    ///
    /// - Parameter slot: The seat to send to, as captured.
    private func sendShopCatalogRequest(to slot: PeerSlot) async {
        guard let mesh else { return }
        // DO NOT LOCALIZE "Clothing catalog request" — as the doc comment above says, the summary is
        // the whole body here, so this literal is signed wire bytes AND the receiving peer's
        // Inspector row. See `FernletIdentityEnvelope.payloadSummary`.
        await mesh.sendFeatureEnvelope(
            PayloadType.clothingCatalogRequest.rawValue,
            encodable: PayloadSummary(title: "Clothing catalog request"), via: slot
        )
        onShopCatalogRequestSendForTesting?(slot.id)
    }
}
