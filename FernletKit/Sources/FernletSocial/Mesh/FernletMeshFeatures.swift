// FernletMeshFeatures.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.5: the composition of Fernlet's mesh features over ProximityKit's routed
// mesh engine. The app builds one, in the lazy initializer that built the mesh manager before it: it
// asks the host for the device identity once, builds the mesh through a factory with that identity,
// builds each feature object over the mesh and the same identity, and installs every engine role a
// feature plays before its initializer returns, so no restore, re-entry or radio start can see a mesh
// without them. It owns all of it: FernletStore reaches the mesh as `meshFeatures.mesh`.
//
// It grows one feature per plan step (A0.5.6 to A0.5.11). Today it holds the capability list the mesh
// advertises, the friend vouch list's content and the clothing shop, and it is the mesh's session
// observer, through a private adapter, for the moments its features act on.

import Foundation
import ProximityKit

/// Fernlet's mesh features and the mesh engine they ride: the composition the app builds once and owns.
///
/// The initializer runs in a fixed order: the device identity (handed in, or asked of the host's
/// ``ProximityHost/makeProximityIdentity()`` exactly once), the mesh (built by the factory with that
/// identity, which checks and provisions it), the feature objects (over the mesh and the same
/// identity), then the installations on the mesh — the capability provider, the vouch-list exchange,
/// the clothing shop's two payload handlers and, last, the session observer — all before the
/// initializer returns. The mesh is reachable by no other code until then.
///
/// **Ownership.** This object holds the mesh and every feature strongly, and the session observer, a
/// private adapter that holds this object `unowned`. The mesh retains only what it calls: the capability
/// provider's closure, which captures ``capabilities`` alone, the vouch-list exchange, a private adapter
/// that holds ``vouchList``, and the shop's handlers, which hold its exchange weakly; it holds the
/// session observer weakly, so the adapter lives exactly as long as this object. Each feature holds the
/// mesh weakly, and the host `unowned` through the features' host holder, as the mesh holds it, so
/// nothing the mesh retains retains the mesh or this object.
///
/// Conforms to nothing of the engine's: each engine role a feature plays is a private adapter nested in
/// that feature, and the session observer one nested here (design rule 6), so the engine's entry points
/// are never API on an object the app holds.
@MainActor
public final class FernletMeshFeatures {

    /// The mesh engine this composition built and owns.
    public let mesh: MeshNetworkManager

    /// The capability tokens the mesh advertises in this device's identity introduction.
    public let capabilities: FernletMeshCapabilities

    /// The friend vouch list's content, and the "Friend of" labels it composes.
    public let vouchList: FernletVouchList

    /// The friend-mesh clothing shop (Phase 3a): catalogs exchanged during the session + the 1-hour
    /// post-session browse window. Its lifecycle follows the same moments that drive the friend-review
    /// batch — but the two deliberately diverge on session FORMATION (the first slot commit): the
    /// review batch survives it, the shop window closes. Search starts (startJoin/startNewMesh — which
    /// fire on every Social-tab entry and scene reactivation) touch NEITHER.
    public let clothingShop: MeshClothingShop

    /// Phase 5: a friend session committed with this fingerprint (an in-person meeting) — feeds
    /// closeness. Called first at every slot commit, before any other feature's commit leg.
    public var onFriendSessionCommitted: ((String) -> Void)?

    /// The clothing shop's mesh wiring: its handlers, its commit-time sends and their tracking.
    /// Internal, not private, so the test target reaches its send seams and its offer gate through
    /// `@testable import`; the app never reaches it.
    let shopExchange: ClothingShopExchange

    /// The device identity the mesh holds, the one the host's door built (or the one handed in).
    private let identity: IdentityService

    /// The host the features read, held `unowned`, with its namespace read once.
    private let meshHost: FernletMeshHost

    /// The mesh's session observer: the private adapter this composition installs on the mesh last,
    /// once every other stored property is set, and keeps for its own lifetime (the mesh holds it
    /// weakly).
    private var sessionObserver: SessionObserver?

    /// The factory the composition builds its mesh with, from the device identity it was handed or
    /// asked the host for.
    public typealias MakeMesh = @MainActor (IdentityService) -> MeshNetworkManager

    /// The app's composition: one identity from the host's door, the mesh over the host's radio, then
    /// the features.
    ///
    /// - Parameter host: The app's host, which owns this composition and keeps it alive.
    public convenience init(host: any ProximityHost) {
        self.init(host: host, identity: nil) { identity in
            MeshNetworkManager(store: host, identity: identity)
        }
    }

    /// The composition over a mesh the factory builds: the seam the test rig uses to inject an
    /// identity and a mesh over a fake radio.
    ///
    /// - Parameters:
    ///   - host: The app's host; the caller keeps it alive.
    ///   - injected: The device identity, or nil to ask the host's door once.
    ///   - makeMesh: Builds the mesh with the identity.
    init(host: any ProximityHost, identity injected: IdentityService?, makeMesh: MakeMesh) {
        let identity = injected ?? host.makeProximityIdentity()
        let mesh = makeMesh(identity)
        let meshHost = FernletMeshHost(host: host)
        let clothingShop = MeshClothingShop()
        self.identity = identity
        self.meshHost = meshHost
        self.mesh = mesh
        self.clothingShop = clothingShop
        self.capabilities = FernletMeshCapabilities(mesh: mesh, meshHost: meshHost, clothingShop: clothingShop)
        self.vouchList = FernletVouchList(meshHost: meshHost, identity: identity)
        self.shopExchange = ClothingShopExchange(shop: clothingShop, mesh: mesh, meshHost: meshHost)
        installOnMesh()
    }

    /// Installs every engine role a feature plays on the mesh, before the initializer returns: the
    /// capability provider, in a closure that captures the capability list alone, the vouch-list
    /// exchange, the clothing shop's two payload handlers and, last, the session observer, created here
    /// once every stored property is set, so it may hold this object `unowned`.
    private func installOnMesh() {
        let capabilities = self.capabilities
        mesh.localCapabilitiesProvider = { capabilities.localCapabilities() }
        mesh.vouchListExchange = vouchList.makeExchange()
        shopExchange.registerHandlers(on: mesh)
        let observer = SessionObserver(features: self)
        sessionObserver = observer
        mesh.sessionObserver = observer
    }

    /// The mesh's session observer (S15): each moment of a session's life the mesh reports, fanned out
    /// to the features in the order the mesh manager ran them before they left it. Private and nested,
    /// so the engine's entry points stay off this object's public API (design rule 6), and so it
    /// reaches this object's private members.
    private final class SessionObserver: MeshSessionObserver {

        /// The composition whose features each moment reaches. `unowned`: the composition owns this
        /// adapter and the mesh holds it weakly, so it never outlives the composition.
        unowned let features: FernletMeshFeatures

        /// An observer over `features`.
        ///
        /// - Parameter features: The composition, every stored property already set.
        init(features: FernletMeshFeatures) {
            self.features = features
        }

        /// A slot committed: the closeness hook first (this committed friend is physically present —
        /// feed closeness, day-capped downstream); on a formation, the shop's new session; then the
        /// shop's catalog offer to this slot.
        ///
        /// - Parameter commit: The committed slot, its peer and whether it formed the session.
        func meshSlotDidCommit(_ commit: MeshSlotCommit) {
            features.onFriendSessionCommitted?(commit.peer.fingerprint)
            if commit.formsSession {
                features.shopExchange.beginNewSession()
            }
            features.shopExchange.offerCatalog(to: commit.slot, peer: commit.peer)
        }

        /// A slot was dropped: the shop forgets it sent to that slot, so a rejoining friend
        /// re-exchanges.
        ///
        /// - Parameter slotID: The dropped slot's id.
        func meshSlotDidLeave(slotID: UUID) {
            features.shopExchange.pruneShopSendTracking(for: slotID)
        }

        /// The search stopped: the shop forgets every slot it sent to and every request it answered.
        func meshSearchDidStop() {
            features.shopExchange.clearShopSendTracking()
        }

        /// The session ended: the shop's one-hour browse window opens over the catalogs it holds.
        ///
        /// - Parameter end: The ending.
        func meshSessionDidEnd(_ end: MeshSessionEnd) {
            features.clothingShop.openWindowAtSessionEnd()
        }
    }
}
