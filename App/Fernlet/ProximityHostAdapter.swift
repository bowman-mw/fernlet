import ProximityKit
import FernletConnections
import Foundation
import FernletDomainModel

/// Conforms `FernletStore` to the Proximity subsystem's `ProximityHost` seam
/// (plan §5d `ProximityHostAdapter`). Every requirement but `proximityDisplayName`,
/// `proximityNamespace`, `proximityInstallBinding`, `proximityTrustStore`,
/// `makeProximityTrustPolicy()` and `makeProximityIdentity()` is already satisfied by existing store
/// members (`trustedProximityPeers`, `isBlockedFingerprint`,
/// `blockProximityPeer`). Kept in the app target: this conformance is the one piece that cannot
/// move into `ProximityKit`, since it bridges the module's abstraction to the app's concrete store.
extension FernletStore: ProximityHost {
    var proximityDisplayName: String { settings.proximityDisplayName }
    /// The live hearts opt-in — `PresenceManager` gates both the outbound send and the inbound
    /// drop on this (mesh redesign Phase 4b). Overrides the protocol's `true` default.
    var allowNearbyHearts: Bool { settings.allowNearbyHearts }
    /// This store's own proximity-sidecar root, so the friend photo wall is isolated per store the
    /// same way the own-photo corpora are. Production resolves to the unchanged
    /// `Application Support/Fernlet`; only tests redirect it. Overrides the protocol's default.
    var proximitySupportDirectory: URL { proximitySupportRoot }
    /// Fernlet's protocol identity, `ProximityNamespace.fernlet` from `FernletConnections`: the one
    /// value this composition root hands ProximityKit for the protocol labels, radio values, QR
    /// scheme, identity and mesh seal-key rows, storage names and log subsystem it reads (ProximityKit
    /// plan step A0.2.3; ProximityKit reads the radios' presentation strings off it too, and the
    /// payload vocabulary it carries, its mesh engine's own frames' tokens included, while the mesh
    /// features' tokens stay Fernlet's `PayloadType` cases until A0.5 and A0.7 and the activities'
    /// and the moderation report's feature labels stay outside it until A0.5; the heart-drop and
    /// moderation ban services are FernletSocial's, and the sealed-backup escrow's labels this app's).
    /// The requirement has no default, so a host that left this out would not compile. The app's name
    /// surfaces hand `PeerNameDisplay` the same `.fernlet`.
    ///
    /// `nonisolated`: the namespace is inert `Sendable` value data, and the store's nonisolated
    /// storage-scope properties (`meshSessionStorage`, `meshRoutedStorage`) read it: since plan step
    /// A0.2.8 each scope carries it, and its production seal-key service is derived from it.
    nonisolated var proximityNamespace: ProximityNamespace { .fernlet }
    /// Fernlet's install binding, `FernletDeviceBindingAdapter` from `FernletConnections`:
    /// FernletCrypto's `DeviceBindingID`, read at each seal and open of the two sealed mesh stores, so
    /// they keep sealing under the one row the private stores share (ProximityKit plan step A0.2.9).
    /// The requirement has no default, so a host that left this out would not compile.
    ///
    /// `nonisolated`: the adapter is a stateless `Sendable` value, and the store's nonisolated
    /// storage-scope properties hand it to both scopes.
    nonisolated var proximityInstallBinding: any ProximityInstallBinding { FernletDeviceBindingAdapter() }
    /// Fernlet's durable trust records, this store's `ProximityTrustVault` from `FernletConnections`:
    /// the mesh's kept-friend gates and presence's heart eligibility ask it whether a key is a
    /// remembered, unrevoked friend and whether it is blocked, and `trustedProximityPeers` reads the
    /// same vault's records. The requirement has no default, so a host that left this out would not
    /// compile.
    var proximityTrustStore: any ProximityTrustStore { proximityTrustVault }
    /// Fernlet's friend-session rule, `FriendSessionTrustPolicy` from `FernletConnections`, fresh for
    /// each connection the mesh, presence and recipe-share managers open, over this store's vault:
    /// proximity is the authorization, so every peer is trusted and only a blocked key is refused.
    /// The requirement has no default, so a host that left this out would not compile.
    func makeProximityTrustPolicy() -> any ProximityTrustPolicy {
        FriendSessionTrustPolicy(vault: proximityTrustVault)
    }
    /// The identity the mesh, presence and recipe-share managers build when they are handed none:
    /// Fernlet's, from the app's one factory, `IdentityService.fernletApp()` (`SealedBackupEscrowKey.swift`),
    /// so it carries the sealed-backup escrow key as its provisioning participant and runs the escrow's
    /// provisioning cases like every other identity the app builds. The requirement has no default (an
    /// identity's custody is the host's), so a host that left this out would not compile;
    /// `KeyCustodyBoundaryTests` holds each of the store's three managers to an identity carrying the
    /// escrow key.
    func makeProximityIdentity() -> IdentityService { .fernletApp() }
}
