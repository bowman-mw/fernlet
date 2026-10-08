// FernletMeshCapabilities.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.5 (seam S13's host half): the capability tokens Fernlet advertises in a
// device's signed identity introduction, composed here from Fernlet's feature switches and handed to
// the mesh engine through its capability-list provider, which advertises the list verbatim.
//
// The ORDER is a signed wire byte: the coordinator carries the array verbatim into the introduction and
// its acknowledgement, so the composer below is the mesh manager's own `localCapabilities()` body,
// moved with its nine appends in their order and its comments. The switches it reads are read where
// they live: the clothing shop's sharing gate on the composition's shop, the chat age gate on the mesh
// (still the engine's until chat moves), the friend-state opt-in on the composition's friend-state
// exchange, the in-person hearts opt-in on the host, the away-hearts consent on this object, and the
// wire2 token on the namespace the host was read for once.

import Foundation
import FernletDomainModel
import ProximityKit

/// The capability tokens this device advertises in its identity introduction: the mesh's capability
/// provider, composed from Fernlet's feature switches in a frozen order.
///
/// Photos always (the mesh's founding feature); `shop` only while clothing-shop sharing is enabled —
/// the opt-out is payload-layer (Phase 3a), so an opted-out device neither advertises nor is sent
/// catalogs. Snapshot at coordinator creation (capabilities ride the handshake intro): the mesh reads
/// the list once per coordinator, so a mid-session toggle affects the NEXT session's advertisement,
/// while its send/receive effect is immediate via the provider gates.
///
/// The composition (``FernletMeshFeatures``) installs ``localCapabilities()`` as the mesh's
/// ``MeshNetworkManager/localCapabilitiesProvider`` while it is built, in a closure that captures this
/// object alone; this object holds the mesh weakly, so the mesh retaining that closure forms no cycle.
@MainActor
public final class FernletMeshCapabilities {

    /// The away-hearts consent (bitchat adoptions Increment 3), wired by FernletStore: gates the
    /// `heartsAway` advertisement, which tells a peer this device's intros carry a prekey bundle and it
    /// accepts drops. Optional-and-nil means not consented, so a list nobody wired never advertises it.
    public var heartsAwayEnabledProvider: (() -> Bool)?

    /// The mesh whose feature switches the list reads. Weak: the mesh retains the provider closure
    /// that retains this object.
    private weak var mesh: MeshNetworkManager?

    /// The host the hearts opt-in is read from, and the namespace the wire2 token is read from.
    private let meshHost: FernletMeshHost

    /// The composition's clothing shop, whose sharing gate the `shop` token follows. Held strongly: the
    /// shop holds nothing back.
    private let clothingShop: MeshClothingShop

    /// The composition's friend-state exchange, whose opt-in the `friendState` token follows. Held
    /// strongly: the exchange holds the mesh weakly and nothing else back.
    private let friendState: FriendStateExchange

    /// A composer over `mesh`'s feature switches, `meshHost`'s host and namespace, the shop's gate and
    /// the friend-state opt-in.
    ///
    /// - Parameters:
    ///   - mesh: The mesh this list is advertised by, held weakly.
    ///   - meshHost: The features' host holder.
    ///   - clothingShop: The composition's clothing shop.
    ///   - friendState: The composition's friend-state exchange.
    init(mesh: MeshNetworkManager, meshHost: FernletMeshHost, clothingShop: MeshClothingShop,
         friendState: FriendStateExchange) {
        self.mesh = mesh
        self.meshHost = meshHost
        self.clothingShop = clothingShop
        self.friendState = friendState
    }

    /// The capability tokens advertised in this device's identity introduction, in their frozen order:
    /// photos, the host's wire2 token, then each switched token in place around moderation and
    /// activities, hearts last.
    ///
    /// The mesh it reads is the one that calls this through its provider, so it is always alive when
    /// asked; were it gone, the list would be the engine's own, the wire2 token alone.
    ///
    /// - Returns: the ordered capability tokens.
    func localCapabilities() -> [String] {
        guard let mesh else { return [meshHost.namespace.family.vocabulary.capabilities.wire2] }
        var capabilities = [ProximityCapability.photos.rawValue]
        // wire2 (bitchat adoptions Increment 2): sealed-payload compress+pad framing. A wire
        // format, not a user feature — no opt-out; advertised by every build that ships it, under
        // the host's wire2 token, the one every peer's sealed sends look for.
        capabilities.append(meshHost.namespace.family.vocabulary.capabilities.wire2)
        // heartsAway (bitchat adoptions Increment 3): advertised only when the user opted into
        // away delivery — signals our intro carries a prekey bundle and we accept drops.
        if heartsAwayEnabledProvider?() == true {
            capabilities.append(ProximityCapability.heartsAway.rawValue)
        }
        if clothingShop.isSharingEnabled {
            capabilities.append(ProximityCapability.shop.rawValue)
        }
        // Phase 5: temporary messages are a core in-session feature with no separate v1 opt-out —
        // session membership (the UWB dwell + admission) IS the consent gate. The one thing that DOES
        // withhold it is the 13+ age gate: a device below the line never advertises `messages`, so
        // friends' devices skip it in the room broadcast instead of sending into a surface it will drop.
        if mesh.isChatAllowed {
            capabilities.append(ProximityCapability.messages.rawValue)
        }
        // Content-moderation reports are a safety feature with no opt-out — always advertised so a
        // friend's device knows it may hand us the reports it has verified.
        capabilities.append(ProximityCapability.moderation.rawValue)
        // Phase 4: advertise fuzzy-state exchange only when the user opted in, so a friend sends us their
        // vibe only if we accept (and share) ours.
        if friendState.isEnabledProvider?() == true {
            capabilities.append(ProximityCapability.friendState.rawValue)
        }
        // Phase 6: group activities are session-scoped; membership (the UWB dwell + the host's explicit
        // confirm) is the consent gate, so advertise unconditionally like messages. Offers are only sent
        // for activities the user chose to host, so there is nothing to opt out of.
        capabilities.append(ProximityCapability.activities.rawValue)
        // TF b19 item 5: in-session hearts ride the live mesh session. Advertise `.hearts` ONLY when this
        // device has opted in (`allowNearbyHearts`). The receiver enforces that same opt-out (plus the
        // trusted-friend requirement + block list) before recording anything, so advertising it while
        // opted out would make an opted-out device look heart-reachable: a sender would send, see a false
        // "Sent … good vibes", and burn the 5-minute cooldown even though the receiver silently drops it
        // (`receiveSessionHeart`). Gating the advertisement means opted-out peers never appear reachable,
        // so the sender's button reflects the true unavailable state. Also lets a sender skip peers on an
        // older build (no `.friendHeart` mesh handler) and fall back to presence.
        //
        // Accepted limitation: capabilities are exchanged once at the session handshake, so toggling this
        // setting mid-session does not retroactively update peers already connected in the session.
        if meshHost.host.allowNearbyHearts {
            capabilities.append(ProximityCapability.hearts.rawValue)
        }
        return capabilities
    }
}
