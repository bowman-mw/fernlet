// ProximityActivityManager+Mesh.swift
// FernletSocial/Activities
//
// ProximityKit plan step A0.5.8: the activity manager's mesh wiring (Phase 6), moved from the mesh
// manager with no byte, golden or audit change: the five activity handlers, registered through the
// mesh's payload token door, each taking a frame only from a transport-verified, unblocked sender; the
// fingerprint-addressed send, which looks the peer's committed slot up at send time and goes through
// the mesh's feature send; and the committed-peer query, which reads the mesh's committed slots that
// advertise the `activities` capability.
//
// The mesh calls none of it directly. The handlers reach the manager through the payload registry, the
// send and the query through the two closures `attach(to:meshHost:)` sets on it, and the commit through
// FernletSocial's mesh composition (`FernletMeshFeatures`), which builds the manager first, attaches it
// here before its session observer, and offers its activities at each slot commit, after the other
// features' legs, in the order the mesh manager ran them.

import Foundation
import FernletDomainModel
import ProximityKit

extension ProximityActivityManager {

    /// Attaches this manager to `mesh`, once, while the composition builds it: registers the five
    /// activity handlers, then sets the two mesh seams the manager uses instead of touching a radio —
    /// a sealed or unsealed send to a verified fingerprint's committed slot (``send``), and the
    /// committed peers advertising `activities` (``committedActivityPeerFingerprints``). Both seams
    /// hold `mesh` weakly, as the mesh manager's held itself, so a send or a query after the mesh is
    /// gone does nothing.
    ///
    /// - Parameters:
    ///   - mesh: The composition's mesh.
    ///   - meshHost: The features' host holder: the host the handlers ask about a blocked sender, and
    ///     the namespace the `activities` capability token is read in.
    func attach(to mesh: MeshNetworkManager, meshHost: FernletMeshHost) {
        registerActivityHandlers(on: mesh, meshHost: meshHost)
        // Phase 6: give the activity manager the two mesh seams it needs — a sealed/unsealed send to a
        // verified fingerprint's committed slot, and the list of committed peers advertising `.activities`.
        send = { [weak mesh] type, payload, fingerprint, sealed in
            guard let mesh else { return }
            await ProximityActivityManager.sendActivityEnvelope(
                type, payload, toFingerprint: fingerprint, sealed: sealed, on: mesh)
        }
        committedActivityPeerFingerprints = { [weak mesh] in
            guard let mesh else { return [] }
            return ProximityActivityManager.activityPeerFingerprints(committedOn: mesh, meshHost: meshHost)
        }
    }

    /// Phase 6: Group Activities ride the friend mesh as registered feature payloads, through the mesh's
    /// payload token door. The dispatch default's committed-slot gate has already run; the remaining
    /// guard mirrors `.clothingCatalog` (a transport-VERIFIED, unblocked sender) — NOT the vault-trust
    /// gate the friend-state/moderation handlers use. Activities are ad-hoc, in-session interactions;
    /// authorization is carried by the host-signed, invitee-key-bound `ActivityJoinToken`, not by prior
    /// vault friendship (kickoff: "authorization is independent of the shared handshake").
    /// `.activityJoinRequest` is UNSEALED (identity-only, host re-validates against the verified slot);
    /// the other four are sealed. Each handler holds this manager weakly, so the mesh retaining it forms
    /// no cycle.
    ///
    /// - Parameters:
    ///   - mesh: The mesh to register on: the composition's, while it is built.
    ///   - meshHost: The features' host holder, whose host answers the blocked-fingerprint question.
    private func registerActivityHandlers(on mesh: MeshNetworkManager, meshHost: FernletMeshHost) {
        mesh.registerPayloadHandler(forToken: PayloadType.activityOffer.rawValue) { [weak self] _, plaintext, peer in
            guard let self, let peer else { return }
            guard !meshHost.host.isBlockedFingerprint(peer.fingerprint) else { return }
            guard let payload = try? JSONDecoder().decode(ActivityOfferPayload.self, from: plaintext),
                  payload.isWellFormed else { return }   // R5: format+version validated at entry
            self.receiveOffer(payload, fromFingerprint: peer.fingerprint,
                              verifiedHostSigningPublicKey: peer.signingPublicKey)
        }
        mesh.registerPayloadHandler(forToken: PayloadType.activityJoinRequest.rawValue) { [weak self] _, plaintext, peer in
            guard let self, let peer else { return }
            guard !meshHost.host.isBlockedFingerprint(peer.fingerprint) else { return }
            guard let payload = try? JSONDecoder().decode(ActivityJoinRequestPayload.self, from: plaintext),
                  payload.isWellFormed else { return }   // R5: rejects empty keys too
            self.receiveJoinRequest(payload,
                                    verifiedFingerprint: peer.fingerprint,
                                    verifiedSigningPublicKey: peer.signingPublicKey,
                                    verifiedKeyAgreementPublicKey: peer.keyAgreementPublicKey)
        }
        mesh.registerPayloadHandler(forToken: PayloadType.activityJoinGrant.rawValue) { [weak self] _, plaintext, peer in
            guard let self, let peer else { return }
            guard !meshHost.host.isBlockedFingerprint(peer.fingerprint) else { return }
            guard let payload = try? JSONDecoder().decode(ActivityJoinGrantPayload.self, from: plaintext),
                  payload.isWellFormed else { return }   // R5: format+version validated at entry
            self.receiveGrant(payload, fromFingerprint: peer.fingerprint)
        }
        mesh.registerPayloadHandler(forToken: PayloadType.activityRosterSnapshot.rawValue) { [weak self] _, plaintext, peer in
            guard let self, let peer else { return }
            guard !meshHost.host.isBlockedFingerprint(peer.fingerprint) else { return }
            guard let payload = try? JSONDecoder().decode(ActivityRosterSnapshotPayload.self, from: plaintext),
                  payload.isWellFormed else { return }
            self.receiveSnapshot(payload.snapshot)
        }
        mesh.registerPayloadHandler(forToken: PayloadType.activitySync.rawValue) { [weak self] _, plaintext, peer in
            guard let self, let peer else { return }
            guard !meshHost.host.isBlockedFingerprint(peer.fingerprint) else { return }
            guard let payload = try? JSONDecoder().decode(ActivitySyncPayload.self, from: plaintext),
                  payload.isWellFormed else { return }   // R5: format+version validated at entry
            self.receiveSync(payload, fromFingerprint: peer.fingerprint)
        }
    }

    /// Fingerprints of currently-committed slots that advertise the `.activities` capability — the
    /// activity manager's "who can I offer/gossip to right now" seam.
    ///
    /// - Parameters:
    ///   - mesh: The mesh whose slots are read.
    ///   - meshHost: The features' host holder, whose namespace the capability token is read in.
    /// - Returns: The committed slots' fingerprints, in slot order.
    private static func activityPeerFingerprints(committedOn mesh: MeshNetworkManager,
                                                 meshHost: FernletMeshHost) -> [String] {
        mesh.slots.compactMap { slot in
            guard let fingerprint = slot.fingerprint,
                  slot.supports(ProximityCapability.activities.rawValue,
                                in: meshHost.namespace.family.vocabulary.capabilities)
            else { return nil }
            return fingerprint
        }
    }

    /// Seal + sign + transmit an activity payload to a verified fingerprint's committed slot. Nothing is
    /// sent if that peer no longer has a committed slot (they left the session). The slot is looked up
    /// by fingerprint when the send runs, not captured at a commit as the other features' sends are.
    ///
    /// - Parameters:
    ///   - type: The activity payload's type, whose token the envelope is signed under.
    ///   - payload: The payload.
    ///   - fingerprint: The recipient's verified fingerprint.
    ///   - sealed: Whether to seal the payload to the slot's verified key-agreement key.
    ///   - mesh: The mesh whose slot and feature send carry it.
    private static func sendActivityEnvelope(_ type: PayloadType, _ payload: any Encodable,
                                             toFingerprint fingerprint: String, sealed: Bool,
                                             on mesh: MeshNetworkManager) async {
        guard let slot = mesh.slots.first(where: { $0.fingerprint == fingerprint }) else { return }
        await mesh.sendFeatureEnvelope(type.rawValue, encodable: payload, via: slot, sealed: sealed)
    }
}
