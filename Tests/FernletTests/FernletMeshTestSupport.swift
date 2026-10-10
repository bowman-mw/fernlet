// FernletMeshTestSupport.swift
// FernletTests
//
// ProximityKit plan step A0.5.5: the one way the test target builds Fernlet's mesh as the app does —
// FernletSocial's composition (`FernletMeshFeatures`) over a mesh the manager's internal designated
// initializer builds, with the radio and the identity the rigs inject, and the pending photo corpus's
// key, which the composition hands to its session photos (since plan step A0.5.11).
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
    /// `heldPhotoKeys` goes to the composition's own initializer, which hands it to the session photos:
    /// the seam left the manager's designated initializer with the photos at plan step A0.5.11, when it
    /// stopped reaching the manager inside the mesh factory. This signature did not change.
    ///
    /// - Parameters:
    ///   - store: The host, as the composition takes it since plan step A0.5.10 (FernletSocial's
    ///     `FernletSocialHost`); the caller keeps it alive (the mesh and the features hold it `unowned`).
    ///   - transport: The radio, or nil for the one the app's build selects.
    ///   - identity: The device identity, or nil for the host's door.
    ///   - heldPhotoKeys: The pending corpus's key provider, or nil for the keychain row.
    /// - Returns: The composition; keep it for as long as its mesh is used.
    static func features(
        store: any FernletSocialHost,
        transport: (any MeshTransportSession)? = nil,
        identity: IdentityService? = nil,
        heldPhotoKeys: (any PrivateMediaKeyProviding)? = nil
    ) -> FernletMeshFeatures {
        let features = FernletMeshFeatures(host: store, identity: identity, heldPhotoKeys: heldPhotoKeys) { id in
            MeshNetworkManager(store: store, transport: transport, identity: id)
        }
        expectEveryInstallationHeld(by: features)
        return features
    }

    /// Every role the composition installs on its mesh is in place before it is handed out: today the
    /// capability provider and the vouch-list exchange (plan step A0.5.5), the session observer (plan
    /// step A0.5.6), the payload handlers (``featurePayloadTokens``: the shop's two since A0.5.6, the
    /// moderation report's and the friend state's since A0.5.7, the activity manager's five since
    /// A0.5.8), each read off the mesh's registry, the activity manager's two mesh seams (A0.5.8), and
    /// every routed registration's answer held to `true` (A0.5.9 on: the chat's projection handler,
    /// from A0.5.10 the hearts' ledger judge and from A0.5.11 the session photos' projection handler,
    /// whose refusals the composition records and logs rather than drops).
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
        #expect(features.activities.send != nil,
                "the composition set no mesh send on its activity manager")
        #expect(features.activities.committedActivityPeerFingerprints != nil,
                "the composition set no committed-peer query on its activity manager")
        #expect(features.refusedRoutedRegistrations.isEmpty,
                "the mesh refused the composition's routed registrations for \(features.refusedRoutedRegistrations)")
    }

    /// The payload tokens the composition registers a handler for through the mesh's token door, each
    /// spelled as its feature registers it (`PayloadType.<case>.rawValue`): the clothing catalog and its
    /// request (plan step A0.5.6), the item report and the friend state (A0.5.7), and the activity
    /// offer, join request, join grant, roster snapshot and sync (A0.5.8).
    private static let featurePayloadTokens = [
        PayloadType.clothingCatalog.rawValue, PayloadType.clothingCatalogRequest.rawValue,
        PayloadType.itemReport.rawValue, PayloadType.friendState.rawValue,
        PayloadType.activityOffer.rawValue, PayloadType.activityJoinRequest.rawValue,
        PayloadType.activityJoinGrant.rawValue, PayloadType.activityRosterSnapshot.rawValue,
        PayloadType.activitySync.rawValue
    ]
}
