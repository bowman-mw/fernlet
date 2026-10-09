// FernletSocialHost.swift
// FernletSocial
//
// ProximityKit plan step A0.5.10 (seam S17): the host requirements only Fernlet's social features read,
// which left ProximityKit's `ProximityHost` once no ProximityKit code read them — the host's
// trusted-peer records, its durable trust store and the in-person hearts opt-in, with that opt-in's
// default — and the heart-eligibility check over the trust store and the host's block list. Each moved
// with its doc and its body; ProximityKit keeps the `ProximityTrustStore` protocol the store is typed
// by, which FernletConnections' vault conforms to.
//
// Presence, the session hearts, the vouch list, the moderation report and friend-state exchanges and
// the capability list read them through this refinement; the mesh engine reads none of them.

import Foundation
import FernletDomainModel
import ProximityKit

/// The host Fernlet's social features read: ProximityKit's ``ProximityHost`` and the three requirements
/// only those features read (plan step A0.5.10, S17).
///
/// A refinement, so a host conforms once and hands the same object to the mesh engine (which takes
/// any ``ProximityHost``) and to its features. Fernlet's app conforms `FernletStore` with members it
/// already has (`ProximityHostAdapter.swift`), and the test target's doubles that build presence or
/// the mesh composition declare it too; a double that conforms only to ``ProximityHost`` has none of
/// these members, so handing one to a feature fails to compile rather than reading a silent default.
///
/// Main-actor, like ``ProximityHost`` and the features that read it.
@MainActor
public protocol FernletSocialHost: ProximityHost {

    /// Every trusted-peer record the host keeps (kept, removed, blocked and reported alike), in the
    /// host's persisted type: Fernlet's features read a friend's record from them where they need one
    /// (presence for its tags, a heart connection's sealing key and a heart sender's filed name; the
    /// vouch list for the friends it vouches for). The same records ``proximityTrustStore`` answers
    /// from: Fernlet's app and every test double answer their vault's.
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { get }

    /// The host's durable trust records, asked the two questions Fernlet's features put to them outside
    /// a session: whether a signing key is a remembered, unrevoked peer, and whether it is blocked
    /// (ProximityKit's ``ProximityTrustStore`` says where each feature asks).
    ///
    /// **No default, like ``trustedProximityPeers``.** Which peers a device remembers is the host's
    /// record, not the mechanism's, so neither ProximityKit nor this module keeps any of its own: a host
    /// that supplies none fails to compile. Fernlet's app answers its `ProximityTrustVault` (the
    /// `FernletConnections` module) in `ProximityHostAdapter.swift`, and every test double answers its
    /// own vault. The features read it at each question, so an answer always reflects the records as
    /// they are then.
    var proximityTrustStore: any ProximityTrustStore { get }

    /// The in-person hearts opt-in (mesh redesign Phase 4b), the one hearts setting a host answers.
    /// ``PresenceManager`` consults it on the send side (block an outbound heart) and the receive side
    /// (drop an inbound heart), the session hearts (``MeshSessionHearts``) on their send and in their
    /// ledger judge's readiness, and the capability list (``FernletMeshCapabilities``) before it
    /// advertises the hearts capability. Presence VISIBILITY is a separate setting, so hearts-off +
    /// presence-on means a friend still sees you nearby but a heart to you is silently dropped. The
    /// away-delivery opt-in is no host requirement: the features that read it take a provider of their
    /// own (`heartsAwayEnabledProvider`).
    var allowNearbyHearts: Bool { get }
}

extension FernletSocialHost {

    /// Default for hosts that predate the hearts opt-out (e.g. test doubles). The app's
    /// `FernletStore` overrides this with the live setting.
    public var allowNearbyHearts: Bool { true }

    /// Whether a peer is a remembered, unrevoked and unblocked one: the heart-eligibility check.
    ///
    /// Three legs, all of which must hold, asked in this order and short-circuited: the host's
    /// ``ProximityTrustStore`` knows `signingPublicKey` as a remembered peer it has not removed, the
    /// store does not hold that key blocked, and the host's fingerprint block list
    /// (``ProximityHost/isBlockedFingerprint(_:)``) does not hold `fingerprint`. The block list is
    /// consulted with both inputs, so a peer blocked by either is refused. It reads only the host's
    /// answers at the moment it is asked and keeps nothing.
    ///
    /// One definition, two callers: a heart delivered in person over presence asks it with a
    /// handshake-verified peer's key and fingerprint, and the session hearts' ledger judge
    /// (``MeshSessionHearts``) with the admission ledger's signing key for a routed heart's origin and
    /// the origin's signed fingerprint. Main-actor, like ``ProximityHost``.
    ///
    /// - Parameters:
    ///   - signingPublicKey: The peer's Ed25519 signing key.
    ///   - fingerprint: The peer's fingerprint.
    /// - Returns: `true` when a heart from or to this peer may be recorded.
    public func isTrustedUnblockedPeer(signingPublicKey: Data, fingerprint: String) -> Bool {
        let trustStore = proximityTrustStore
        return trustStore.isTrustedProximityPeer(signingPublicKey: signingPublicKey)
            && !trustStore.isBlockedProximitySigningKey(signingPublicKey)
            && !isBlockedFingerprint(fingerprint)
    }
}
