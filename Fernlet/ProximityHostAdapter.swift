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
}
