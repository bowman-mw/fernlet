import ProximityKit
import Foundation
import FernletDomainModel

/// Conforms `FernletStore` to the Proximity subsystem's `ProximityHost` seam
/// (plan §5d `ProximityHostAdapter`). Every requirement but `proximityDisplayName`
/// is already satisfied by existing store members (`trustedProximityPeers`,
/// `proximityTrustVault`, `isBlockedFingerprint`, `blockProximityPeer`). Kept in
/// the app target: this conformance is the one piece that cannot move into the
/// future `ProximityKit` module, since it bridges the module's abstraction to the
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
}
