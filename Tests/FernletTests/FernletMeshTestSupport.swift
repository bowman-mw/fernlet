// FernletMeshTestSupport.swift
// FernletTests
//
// ProximityKit plan step A0.5.5: the one way the test target builds Fernlet's mesh as the app does —
// FernletSocial's composition (`FernletMeshFeatures`) over a mesh the manager's internal designated
// initializer builds, with the radio, the identity and the pending corpus's key the rigs inject.
//
// THE RULE. A rig node keeps the composition for its whole lifetime, and the rig returns the
// composition, never a bare mesh: the composition owns the feature objects, so a node that kept only
// `features.mesh` would lose them, and the mesh, which holds its session observer weakly (plan step
// A0.5.6), would run every lifecycle moment with no feature leg, silently. A suite that wants a bare engine builds
// `MeshNetworkManager(store:)` explicitly: it advertises only the host's wire2 token, holds no vouch
// list, and from each feature commit on registers no handler for that feature, so a cell that silently
// depended on a feature fails rather than passing.

import FernletDomainModel
import Foundation
import PrivateMediaStore
import Testing
@testable import FernletSocial
@testable import ProximityKit

/// Builds Fernlet's mesh composition for a rig node.
@MainActor
enum FernletMeshRig {

    /// The app's composition over `store`, its mesh built by the manager's internal designated
    /// initializer with the rig's seams, and every installation the composition owes its mesh checked.
    ///
    /// `heldPhotoKeys` reaches only the manager's designated initializer, inside the composition's
    /// mesh factory, until the photo object leaves the manager (plan step A0.5.11), when it moves to the
    /// composition's own initializer; this signature does not change then.
    ///
    /// - Parameters:
    ///   - store: The host; the caller keeps it alive (the mesh and the features hold it `unowned`).
    ///   - transport: The radio, or nil for the one the app's build selects.
    ///   - identity: The device identity, or nil for the host's door.
    ///   - heldPhotoKeys: The pending corpus's key provider, or nil for the keychain row.
    /// - Returns: The composition; keep it for as long as its mesh is used.
    static func features(
        store: any ProximityHost,
        transport: (any MeshTransportSession)? = nil,
        identity: IdentityService? = nil,
        heldPhotoKeys: (any PrivateMediaKeyProviding)? = nil
    ) -> FernletMeshFeatures {
        let features = FernletMeshFeatures(host: store, identity: identity) { id in
            MeshNetworkManager(store: store, transport: transport, identity: id, heldPhotoKeys: heldPhotoKeys)
        }
        expectEveryInstallationHeld(by: features)
        return features
    }

    /// Every role the composition installs on its mesh is in place before it is handed out: today the
    /// capability provider and the vouch-list exchange (plan step A0.5.5), the session observer (plan
    /// step A0.5.6) and the payload handlers (``featurePayloadTokens``: the shop's two since A0.5.6, the
    /// moderation report's and the friend state's since A0.5.7), each read off the mesh's registry. Each
    /// later feature step adds its own here, and the routed registrations' answers (A0.5.9 on) are each
    /// held to `true`.
    ///
    /// - Parameter features: The composition just built.
    private static func expectEveryInstallationHeld(by features: FernletMeshFeatures) {
        #expect(features.mesh.localCapabilitiesProvider != nil,
                "the composition installed no capability provider on its mesh")
        #expect(features.mesh.vouchListExchange != nil,
                "the composition installed no vouch-list exchange on its mesh")
        #expect(features.mesh.sessionObserver != nil,
                "the composition installed no session observer on its mesh")
        // R2: bounded by the composition's payload tokens.
        for token in featurePayloadTokens {
            #expect(features.mesh.hasPayloadHandlerForTesting(forToken: token),
                    "the composition registered no handler for \(token) on its mesh")
        }
    }

    /// The payload tokens the composition registers a handler for through the mesh's token door, each
    /// spelled as its feature registers it (`PayloadType.<case>.rawValue`): the clothing catalog and its
    /// request (plan step A0.5.6), the item report and the friend state (A0.5.7).
    private static let featurePayloadTokens = [
        PayloadType.clothingCatalog.rawValue, PayloadType.clothingCatalogRequest.rawValue,
        PayloadType.itemReport.rawValue, PayloadType.friendState.rawValue
    ]
}
