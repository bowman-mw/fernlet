// FernletVouchList.swift
// FernletSocial/Mesh
//
// ProximityKit plan step A0.5.5 (seam S14's host half): the friend vouch list's content — the cache of
// lists committed peers sent, the Phase 2 broadcast gate, the list this device would send, the
// receive hygiene and the "Friend of " label — moved from the mesh manager with no byte, golden or
// audit change. The mesh engine keeps the frame: the vouch role and token, the committed-slot gate and
// its `mesh.vouchList.droppedUncommittedSlot` line, the decode and both commit-time sends. It reaches
// the content only through the `MeshVouchListExchange` adapter nested below, which the composition
// (`FernletMeshFeatures`) installs on the mesh, so the engine's entry points are no part of this
// object's API: the app reads ``FernletVouchList/vouchLabel(for:)`` alone.

import Foundation
import FernletDomainModel
import ProximityKit

/// The friend vouch list's content: what this device would send a just-committed peer, and the labels
/// the lists committed peers sent compose ("Friend of Aisha").
///
/// A vouch list names the sender's whole trusted-peer graph, so both directions sit behind the Phase 2
/// gate (``isVouchListBroadcastEnabled``), off in shipping builds: nothing is built to send, and every
/// received list is dropped before it is cached. The cache is memory-only — never persisted across app
/// launches — and every cached list expires at most two hours after it was received.
///
/// Built by the composition (``FernletMeshFeatures``) over the features' host holder and the device
/// identity the mesh holds; the mesh reaches it through a private adapter that conforms to
/// ``MeshVouchListExchange``. `@MainActor`, like the frames that drive it.
@MainActor
public final class FernletVouchList {

    /// voucherFingerprint → cached payload; never persisted across app launches
    private var vouchCache: [String: MeshFriendVouchListPayload] = [:]

    /// Phase 2 gate (Docs/Proximity-Mesh-Redesign-2026-07-10.md, "Phase 2 — Friend minting"):
    /// the vouch-list broadcast disclosed every unblocked trusted fingerprint to all session
    /// peers, and was dormant only because the trust vault had no production writers. Friend
    /// minting (Phase 2) is exactly what would have switched it on, so it is gated OFF here.
    /// Re-enable only with an explicit consent design for sharing the friend graph.
    var isVouchListBroadcastEnabled = false

    /// The host the trusted peers and the local display name are read from, and the namespace a
    /// voucher's name is sanitized under.
    private let meshHost: FernletMeshHost

    /// The device identity the mesh holds, whose fingerprint names this device as the voucher.
    private let identity: IdentityService

    /// A vouch list over `meshHost`'s host and `identity`.
    ///
    /// - Parameters:
    ///   - meshHost: The features' host holder.
    ///   - identity: The device identity the composition handed the mesh.
    init(meshHost: FernletMeshHost, identity: IdentityService) {
        self.meshHost = meshHost
        self.identity = identity
    }

    /// Returns a label like "Friend of Aisha" if any cached voucher lists this fingerprint as trusted.
    public func vouchLabel(for fingerprint: String) -> String? {
        let now = Date()
        return vouchCache.values
            .first { $0.expiresAt > now && $0.trustedFingerprints.contains(fingerprint) }
            .map { "Friend of \($0.voucherDisplayName)" }
    }

    /// The payload the mesh's vouch-list send would broadcast, or nil while the broadcast is disabled.
    /// Internal seam so tests can pin both the gate (default off ⇒ nil) and the machinery
    /// (forced on ⇒ correct fingerprint filtering) without a live transport.
    func vouchListPayloadForBroadcast() -> MeshFriendVouchListPayload? {
        guard isVouchListBroadcastEnabled else { return nil }
        let trusted = meshHost.host.trustedProximityPeers
            .filter { $0.blockedAt == nil && $0.revokedAt == nil }
            .map { $0.fingerprint }
        return MeshFriendVouchListPayload(
            voucherFingerprint: identity.localFingerprint,
            voucherDisplayName: displayName,
            trustedFingerprints: trusted,
            expiresAt: Date().addingTimeInterval(2 * 3600)
        )
    }

    /// Inbound counterpart of the Phase-2 vouch gate. While `isVouchListBroadcastEnabled` is
    /// off, inbound vouch lists are dropped wholesale — no cache write, no "Friend of …" label:
    /// the gate exists because vouch lists disclose a peer's friend graph without a consent
    /// design, and accepting/rendering them would keep that disclosure live on the receive side
    /// even with our own broadcast off. When enabled, the cached entry is hygiened: expiry is
    /// capped at the protocol's 2 h TTL (the wire value is sender-controlled) and the
    /// peer-supplied display name is sanitized before it is stored or rendered.
    /// Internal seam so tests can drive it without a live transport.
    func receiveVouchList(_ payload: MeshFriendVouchListPayload, senderFingerprint: String?) {
        guard isVouchListBroadcastEnabled else { return }
        guard payload.expiresAt > Date(),
              payload.voucherFingerprint == senderFingerprint else { return }
        let cappedExpiry = min(payload.expiresAt, Date().addingTimeInterval(2 * 3600))
        let name = ProximityDisplayName.peerDisplayName(payload.voucherDisplayName, in: meshHost.namespace)
        vouchCache[payload.voucherFingerprint] = MeshFriendVouchListPayload(
            voucherFingerprint: payload.voucherFingerprint,
            voucherDisplayName: name,
            trustedFingerprints: payload.trustedFingerprints,
            expiresAt: cappedExpiry
        )
    }

    /// Test seam: the cached (gated, capped, sanitized) vouch payload for a voucher, if any.
    func cachedVouchList(from voucherFingerprint: String) -> MeshFriendVouchListPayload? {
        vouchCache[voucherFingerprint]
    }

    /// The advertised local display name (shared coercion; see `PeerDisplayNames.swift`).
    private var displayName: String { meshHost.host.resolvedProximityDisplayName }

    /// A new adapter through which the mesh reaches this list, for the composition to install as the
    /// mesh's ``MeshNetworkManager/vouchListExchange``. The adapter holds this list strongly and the
    /// list never holds an adapter, so the mesh retaining it forms no cycle.
    ///
    /// - Returns: the exchange the mesh asks for a list to send and hands every list it decodes.
    func makeExchange() -> any MeshVouchListExchange {
        Exchange(vouchList: self)
    }

    /// The mesh's half of the vouch list (S14): the engine asks it for the list to send a
    /// just-committed peer and hands it every list it decoded from a committed slot. Private and
    /// nested, so the engine's entry points stay off this object's public API (design rule 6).
    private final class Exchange: MeshVouchListExchange {

        /// The list whose content this adapter hands the engine.
        let vouchList: FernletVouchList

        /// An adapter over `vouchList`, held strongly.
        ///
        /// - Parameter vouchList: The list to adapt.
        init(vouchList: FernletVouchList) {
            self.vouchList = vouchList
        }

        /// The list to send a just-committed peer: ``FernletVouchList/vouchListPayloadForBroadcast()``.
        func vouchListForBroadcast() -> MeshFriendVouchListPayload? {
            vouchList.vouchListPayloadForBroadcast()
        }

        /// A list a committed peer sent: ``FernletVouchList/receiveVouchList(_:senderFingerprint:)``.
        func receiveVouchList(_ payload: MeshFriendVouchListPayload, senderFingerprint: String?) {
            vouchList.receiveVouchList(payload, senderFingerprint: senderFingerprint)
        }
    }
}
