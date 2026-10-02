import ProximityKit
import FernletConnections
import Foundation
import FernletDomainModel

/// Conforms `FernletStore` to the Proximity subsystem's `ProximityHost` seam
/// (plan §5d `ProximityHostAdapter`). Every requirement but `proximityDisplayName`,
/// `proximityNamespace` and `proximityInstallBinding` is already satisfied by existing store
/// members (`trustedProximityPeers`, `proximityTrustVault`, `isBlockedFingerprint`,
/// `blockProximityPeer`). Kept in the app target: this conformance is the one piece that cannot
/// move into the future `ProximityKit` module, since it bridges the module's abstraction to the
/// app's concrete store.
extension FernletStore: ProximityHost {
    var proximityDisplayName: String { settings.proximityDisplayName }
    /// The live hearts opt-in — `PresenceManager` gates both the outbound send and the inbound
    /// drop on this (mesh redesign Phase 4b). Overrides the protocol's `true` default.
    var allowNearbyHearts: Bool { settings.allowNearbyHearts }
    var heartsAwayDeliveryEnabled: Bool { settings.heartsAwayDelivery }
    /// This store's own proximity-sidecar root, so the friend photo wall is isolated per store the
    /// same way the own-photo corpora are. Production resolves to the unchanged
    /// `Application Support/Fernlet`; only tests redirect it. Overrides the protocol's default.
    var proximitySupportDirectory: URL { proximitySupportRoot }
    /// Fernlet's protocol identity, `ProximityNamespace.fernlet` from `FernletConnections`: the one
    /// value this composition root hands ProximityKit for every label, radio value, keychain row and
    /// storage name it reads (ProximityKit plan step A0.2.3). The requirement has no default, so a
    /// host that left this out would not compile.
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
}
