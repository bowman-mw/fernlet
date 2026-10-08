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
// advertises and the friend vouch list's content.

import Foundation
import ProximityKit

/// Fernlet's mesh features and the mesh engine they ride: the composition the app builds once and owns.
///
/// The initializer runs in a fixed order: the device identity (handed in, or asked of the host's
/// ``ProximityHost/makeProximityIdentity()`` exactly once), the mesh (built by the factory with that
/// identity, which checks and provisions it), the feature objects (over the mesh and the same
/// identity), then the installations on the mesh — the capability provider and the vouch-list
/// exchange — all before the initializer returns. The mesh is reachable by no other code until then.
///
/// **Ownership.** This object holds the mesh and every feature strongly. The mesh retains only what it
/// calls: the capability provider's closure, which captures ``capabilities`` alone, and the vouch-list
/// exchange, a private adapter that holds ``vouchList``. Each feature holds the mesh weakly, and the
/// host `unowned` through the features' host holder, as the mesh holds it, so nothing the mesh retains
/// retains the mesh or this object.
///
/// Conforms to nothing of the engine's: each engine role a feature plays is a private adapter nested in
/// that feature (design rule 6), so the engine's entry points are never API on an object the app holds.
@MainActor
public final class FernletMeshFeatures {

    /// The mesh engine this composition built and owns.
    public let mesh: MeshNetworkManager

    /// The capability tokens the mesh advertises in this device's identity introduction.
    public let capabilities: FernletMeshCapabilities

    /// The friend vouch list's content, and the "Friend of" labels it composes.
    public let vouchList: FernletVouchList

    /// The device identity the mesh holds, the one the host's door built (or the one handed in).
    private let identity: IdentityService

    /// The host the features read, held `unowned`, with its namespace read once.
    private let meshHost: FernletMeshHost

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
        self.identity = identity
        self.meshHost = meshHost
        self.mesh = mesh
        self.capabilities = FernletMeshCapabilities(mesh: mesh, meshHost: meshHost)
        self.vouchList = FernletVouchList(meshHost: meshHost, identity: identity)
        installOnMesh()
    }

    /// Installs every engine role a feature plays on the mesh, before the initializer returns: the
    /// capability provider, in a closure that captures the capability list alone, and the vouch-list
    /// exchange.
    private func installOnMesh() {
        let capabilities = self.capabilities
        mesh.localCapabilitiesProvider = { capabilities.localCapabilities() }
        mesh.vouchListExchange = vouchList.makeExchange()
    }
}
