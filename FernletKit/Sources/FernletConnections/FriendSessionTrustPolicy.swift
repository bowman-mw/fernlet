// FriendSessionTrustPolicy.swift
// FernletConnections
//
// Fernlet's friend-session trust policy: what the app's `ProximityHost` adapter answers for
// `makeProximityTrustPolicy()`, a fresh instance for every connection the mesh, presence and
// recipe-share managers open. It is a rule, not mechanism, so it lives with Fernlet's connection
// rules; the protocol it answers (`ProximityTrustPolicy`) is ProximityKit's, and the vault it wraps
// (`ProximityTrustVault`) is this module's.

import Foundation
import FernletDomainModel
import ProximityKit

/// The `ProximityTrustPolicy` for friend-mode radios (mesh, recipe share, presence hearts):
/// physical proximity is the authorization, so every peer is "trusted" and only BLOCKED keys ban.
///
/// Wraps a `ProximityTrustVault` and deliberately maps the revoked check onto the blocked check —
/// a revoked-only ("Removed") peer is an unfriend, not a ban, and may handshake again in person.
/// `isTrustedProximityPeer` is unconditionally `true` because friend sessions authorize through the
/// UWB dwell / manual-commit proximity gate, not remembered trust. The app's `ProximityHost` adapter
/// returns a fresh instance from `makeProximityTrustPolicy()` for every connection, and the manager
/// that asked retains it for the connection's lifetime (the coordinator's `trustPolicy` is `weak`).
public final class FriendSessionTrustPolicy: ProximityTrustPolicy {
    private let vault: ProximityTrustVault

    public init(vault: ProximityTrustVault) {
        self.vault = vault
    }

    // Friend lifecycle semantics (Phase 2, Docs/Proximity-Mesh-Redesign-2026-07-10.md): the
    // friend-mode transport ban is for BLOCKED keys only. A revoked-only ("Removed") peer is an
    // unfriend, not a ban — they may handshake again in person and be re-offered by the keep
    // prompt after a fresh verified session, so the coordinator's hard-fail on this check must
    // not fire for them. Blocked stays a silent transport drop via isBlockedProximitySigningKey.
    public func isRevokedProximitySigningKey(_ publicKey: Data) -> Bool {
        vault.isBlockedProximitySigningKey(publicKey)
    }

    public func isBlockedProximitySigningKey(_ publicKey: Data) -> Bool {
        vault.isBlockedProximitySigningKey(publicKey)
    }

    // Friend sessions authorize through the proximity gate; remembered trust is not required.
    public func isTrustedProximityPeer(signingPublicKey: Data) -> Bool { true }

    /// Keeps the coordinator's audit in the vault as Fernlet's persisted row
    /// (`TrainerAuditEvent.init(_:)`, the module's one conversion).
    public func recordSessionAudit(_ audit: ProximitySessionAudit) {
        vault.recordTrainerAudit(TrainerAuditEvent(audit))
    }
}
