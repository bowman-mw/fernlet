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
// advertises, the friend vouch list's content, the clothing shop, the moderation report relay, the
// fuzzy friend state and the Group Activities manager, and it is the mesh's session observer, through a
// private adapter, for the moments its features act on.

import Foundation
import FernletDomainModel
import ProximityKit

/// Fernlet's mesh features and the mesh engine they ride: the composition the app builds once and owns.
///
/// The initializer runs in a fixed order: the device identity (handed in, or asked of the host's
/// ``ProximityHost/makeProximityIdentity()`` exactly once), the mesh (built by the factory with that
/// identity, which checks and provisions it), the feature objects (over the mesh and the same
/// identity, the activity manager first, whose ledger loads, collects and may write as it is built),
/// then the installations on the mesh — the capability provider, the vouch-list exchange, the clothing
/// shop's two payload handlers, the moderation report's, the friend state's, the activity manager's
/// five and its two mesh seams and, last, the session observer — all before the initializer returns.
/// The mesh is reachable by no other code until then.
///
/// **Ownership.** This object holds the mesh and every feature strongly, and the session observer, a
/// private adapter that holds this object `unowned`. The mesh retains only what it calls: the capability
/// provider's closure, which captures ``capabilities`` alone, the vouch-list exchange, a private adapter
/// that holds ``vouchList``, and the nine payload handlers, which hold their features weakly (the
/// activity manager's hold the features' host holder too); it holds the session observer weakly, so the
/// adapter lives exactly as long as this object. Each feature holds the mesh weakly (the activity
/// manager in its two seams), and the host `unowned`, through the features' host holder as the mesh
/// holds it (the activity manager in its own reference), so nothing the mesh retains retains the mesh
/// or this object.
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

    /// The one-hop moderation report relay (Phase 3b): this device's own signed reports, handed to a
    /// committed friend kept in person, and such a friend's verified rows, handed to the app.
    public let moderation: ModerationReportExchange

    /// The fuzzy friend state (Phase 4): this device's state + appearance, shared with a committed friend
    /// kept in person while the user opts in, and such a friend's state, handed to the app.
    public let friendState: FriendStateExchange

    /// Phase 6 (Group Activities): the state + host-authoritative roster/token brain. Rides this friend
    /// mesh (no new radio); constructed first among the features and attached to the mesh in `init`.
    /// Memory + a device-local sidecar (NEVER synced).
    public let activities: ProximityActivityManager

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
        // Per-HOST root like the mesh's photo wall: `FernletStore.resetAll` calls
        // `meshFeatures.activities.clearAll()`, which removes this sidecar.
        let activities = ProximityActivityManager(
            store: host,
            identity: identity,
            fileURL: ProximityActivityManager.fileURL(in: host.proximitySupportDirectory)
        )
        let meshHost = FernletMeshHost(host: host)
        let clothingShop = MeshClothingShop()
        let friendState = FriendStateExchange(mesh: mesh, meshHost: meshHost)
        self.identity = identity
        self.meshHost = meshHost
        self.mesh = mesh
        self.clothingShop = clothingShop
        self.moderation = ModerationReportExchange(mesh: mesh, meshHost: meshHost, identity: identity)
        self.friendState = friendState
        self.activities = activities
        self.capabilities = FernletMeshCapabilities(
            mesh: mesh, meshHost: meshHost, clothingShop: clothingShop, friendState: friendState)
        self.vouchList = FernletVouchList(meshHost: meshHost, identity: identity)
        self.shopExchange = ClothingShopExchange(shop: clothingShop, mesh: mesh, meshHost: meshHost)
        installOnMesh()
    }

    /// Installs every engine role a feature plays on the mesh, before the initializer returns: the
    /// capability provider, in a closure that captures the capability list alone, the vouch-list
    /// exchange, the payload handlers (the clothing shop's two, then the moderation report's, the
    /// friend state's and the activity manager's five, the order the mesh manager registered them in),
    /// the activity manager's two mesh seams and, last, the session observer, created here once every
    /// stored property is set, so it may hold this object `unowned`.
    private func installOnMesh() {
        let capabilities = self.capabilities
        mesh.localCapabilitiesProvider = { capabilities.localCapabilities() }
        mesh.vouchListExchange = vouchList.makeExchange()
        shopExchange.registerHandlers(on: mesh)
        moderation.registerHandler(on: mesh)
        friendState.registerHandler(on: mesh)
        activities.attach(to: mesh, meshHost: meshHost)
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
        /// shop's catalog offer to this slot, this device's own moderation reports and its friend state,
        /// each send spawned in that order; and, last, the activities this device hosts, offered to this
        /// peer with a roster version digest, their sends spawned after the others.
        ///
        /// - Parameter commit: The committed slot, its peer and whether it formed the session.
        func meshSlotDidCommit(_ commit: MeshSlotCommit) {
            features.onFriendSessionCommitted?(commit.peer.fingerprint)
            if commit.formsSession {
                features.shopExchange.beginNewSession()
            }
            features.shopExchange.offerCatalog(to: commit.slot, peer: commit.peer)
            features.moderation.offerReports(to: commit.slot, peer: commit.peer)
            features.friendState.offerState(to: commit.slot, peer: commit.peer)
            // Phase 6: offer any activities we host to this committed peer + exchange a roster version digest
            // so the highest verified snapshot converges. The manager sends via its wired `send` closure.
            if commit.peer.supports(ProximityCapability.activities.rawValue,
                                    in: features.meshHost.namespace.family.vocabulary.capabilities) {
                features.activities.onPeerCommitted(fingerprint: commit.peer.fingerprint)
            }
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
