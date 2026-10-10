import ProximityKit
import FernletConnections
import FernletSocial
import Foundation
import FernletDomainModel
import UIKit

/// Conforms `FernletStore` to the Proximity subsystem's `ProximityHost` seam
/// (plan §5d `ProximityHostAdapter`). Every requirement but `proximityDisplayName`,
/// `proximityFallbackDisplayName`, `proximitySupportDirectory`, `proximityNamespace`,
/// `proximityInstallBinding`, `makeProximityTrustPolicy()`, `makeProximityRangingProvider()`,
/// `makeProximityIdentity()` and `meshRoutedTypeEntries` is already satisfied by existing store
/// members (`isBlockedFingerprint`, `blockProximityPeer`, and the two storage scopes,
/// `meshSessionStorage` and `meshRoutedStorage`). This extension also holds the two members the
/// store's `FernletSocialHost` conformance (below) adds, `allowNearbyHearts` and `proximityTrustStore`.
/// Kept in the app target: this conformance is the one piece that cannot move into `ProximityKit`,
/// since it bridges the module's abstraction to the app's concrete store.
extension FernletStore: ProximityHost {
    var proximityDisplayName: String { settings.proximityDisplayName }
    /// The name this device goes by on the radios when its user set none, which
    /// `resolvedProximityDisplayName` falls back to: `UIDevice.current.name`, the expression
    /// ProximityKit read itself until plan step A0.6.2, read at the same moments (on the main actor,
    /// on every resolution, never cached, and only when the user's own name trims to nothing), so the
    /// recipe radio's TXT `name`, the coordinator's disclosed name and every FernletSocial sender name
    /// carry the bytes they did. iOS 16+ reports the generic model name without the
    /// user-assigned-device-name entitlement, which Fernlet does not hold. The requirement has no
    /// default, so a host that left this out would not compile; `FernletFeatureGoldenTests`' group 30
    /// holds it to this device's name. `proximityDisplayName` above stays the raw setting: the
    /// activities and the heart dead-drop send it as it is, so an unnamed user sends "" there.
    var proximityFallbackDisplayName: String { UIDevice.current.name }
    /// The live hearts opt-in — `PresenceManager` gates both the outbound send and the inbound
    /// drop on this (mesh redesign Phase 4b), and the session hearts their send and their ledger
    /// judge's readiness. Witnesses `FernletSocialHost.allowNearbyHearts`, overriding its `true`
    /// default.
    var allowNearbyHearts: Bool { settings.allowNearbyHearts }
    /// This store's own proximity-sidecar root, so the friend photo wall is isolated per store the
    /// same way the own-photo corpora are. Production resolves to the unchanged
    /// `Application Support/Fernlet` (`FernletProximityStorage.productionDirectory`, from
    /// `FernletConnections`); only tests redirect it. The requirement has no default since
    /// ProximityKit plan step A0.6.6 (where an installation keeps its files is its host's fact), so
    /// a host that left this out would not compile.
    var proximitySupportDirectory: URL { proximitySupportRoot }
    /// Fernlet's protocol identity, `ProximityNamespace.fernlet` from `FernletConnections`: the one
    /// value this composition root hands ProximityKit for the protocol labels, radio values, QR
    /// scheme, identity and mesh seal-key rows, storage names and log subsystem it reads (ProximityKit
    /// plan step A0.2.3; ProximityKit reads the radios' presentation strings off it too, and the
    /// payload vocabulary it carries, its mesh engine's own frames' tokens included; the mesh
    /// features' tokens, Fernlet's `PayloadType` cases, the activities' and the moderation report's
    /// feature labels and the heart-drop and moderation ban services are FernletSocial's, and the
    /// sealed-backup escrow's labels this app's).
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
    /// FernletSocial's kept-friend gates (the moderation report's and the friend state's exchanges)
    /// and its heart eligibility (presence's and the session hearts' ledger judge's) ask it whether a
    /// key is a remembered, unrevoked friend and whether it is blocked, and `trustedProximityPeers`
    /// reads the same vault's records. Witnesses `FernletSocialHost.proximityTrustStore`, which has no
    /// default, so a host that left this out would not compile.
    var proximityTrustStore: any ProximityTrustStore { proximityTrustVault }
    /// Fernlet's friend-session rule, `FriendSessionTrustPolicy` from `FernletConnections`, fresh for
    /// each connection the mesh, presence and recipe-share managers open, over this store's vault:
    /// proximity is the authorization, so every peer is trusted and only a blocked key is refused.
    /// The requirement has no default, so a host that left this out would not compile.
    func makeProximityTrustPolicy() -> any ProximityTrustPolicy {
        FriendSessionTrustPolicy(vault: proximityTrustVault)
    }
    /// The ranging provider each connection's coordinator measures distance with: a fresh
    /// `NIRangingSession()`, which the mesh's, the recipe radio's and presence's heart channel-ready
    /// doors ask for once per connection, at the argument position where each built it itself before
    /// ProximityKit plan step A0.6.3, a new one per call, so no session's `stop()` can end another's
    /// ranging. It reads the device's capability and degrades to the manual commit without UWB; the
    /// app declares `NSNearbyInteractionUsageDescription`. The requirement has no default, so a host
    /// that left this out would not compile; `FernletFeatureGoldenTests`' group 30 pins the type, a new
    /// instance per call and this body as source, since whether a provider has UWB is the device's
    /// answer, not this code's.
    func makeProximityRangingProvider() -> any RangingProvider { NIRangingSession() }
    /// The identity the mesh, presence and recipe-share managers build when they are handed none:
    /// Fernlet's, from the app's one factory, `IdentityService.fernletApp()` (`SealedBackupEscrowKey.swift`),
    /// so it carries the sealed-backup escrow key as its provisioning participant and runs the escrow's
    /// provisioning cases like every other identity the app builds. The requirement has no default (an
    /// identity's custody is the host's), so a host that left this out would not compile;
    /// `KeyCustodyBoundaryTests` holds each of the store's three managers to an identity carrying the
    /// escrow key.
    func makeProximityIdentity() -> IdentityService { .fernletApp() }
    /// Fernlet's routed-type rows: FernletSocial's `FernletRoutedTypes.entries` over this store's
    /// namespace's routed types (ProximityKit plan step A0.5.9) — the temporary-message, heart and
    /// photo rows, every row the mesh's routed type registry holds. Read once, by the mesh's
    /// initializer. The requirement has no default, so a host that left this out would not compile.
    var meshRoutedTypeEntries: [MeshRoutedTypeEntry] {
        FernletRoutedTypes.entries(proximityNamespace.family.vocabulary.routedTypes)
    }
}

/// Conforms `FernletStore` to FernletSocial's `FernletSocialHost`, the host its features read
/// (ProximityKit plan step A0.5.10, S17): the composition (`FernletMeshFeatures`) and presence
/// (`PresenceManager`) take this store as one. Empty, because the store already has all three members:
/// `trustedProximityPeers` (`FernletStore.swift`), and `allowNearbyHearts` and `proximityTrustStore`
/// (above); the eligibility check, `isTrustedUnblockedPeer(signingPublicKey:fingerprint:)`, is the
/// protocol's own.
extension FernletStore: FernletSocialHost {}
