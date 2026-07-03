import Foundation
import Testing
import FernletDomainModel
@testable import ProximityKit

/// Finding A regression: a peer catalog delivered before the peer's identity was verified is keyed by
/// DISPLAY NAME (`ProximityClothingCatalog.id == senderFingerprint ?? senderDisplayName`). The old
/// `clearCatalog(for:)` bailed on a nil fingerprint, so a display-name-keyed catalog stayed browsable /
/// buyable after the peer disconnected — a break of the "catalog discarded the moment you leave
/// proximity" guarantee (§2.3). The disconnect clear must evict it, and must NOT touch a still-connected
/// peer's catalog.
///
/// `@testable import ProximityKit` reaches the internal `clearCatalogs(fingerprint:identityDisplayName:
/// transportDisplayName:)` seam that `clearCatalog(for:)` delegates to. The live disconnect path is
/// driven by a real `MCSession`, so it cannot be reached from a unit test; exercising the seam runs the
/// exact same eviction rule.
@MainActor
struct ProximityClothingShareEphemeralityTests {

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    @Test func displayNameKeyedCatalogIsClearedOnDisconnect() throws {
        let manager = ProximityClothingShareManager(store: MockProximityHost())

        // Catalog arrives with `from: nil` (identity not yet verified) → keyed by displayName "Robin".
        try storeCatalog(in: manager, displayName: "Robin", designer: UUID(), itemName: "Star Cape")
        #expect(manager.peerCatalogs.count == 1)
        #expect(manager.catalog(for: "Robin") != nil)                      // browsable under the displayName key

        // The peer disconnects. Its connection never verified, so fingerprint is nil — the bug scenario.
        manager.clearCatalogs(fingerprint: nil, identityDisplayName: "Robin", transportDisplayName: "Robin")

        #expect(manager.peerCatalogs.isEmpty)                              // cleared, not left buyable (§2.3)
        #expect(manager.catalog(for: "Robin") == nil)
    }

    @Test func clearingOneDisconnectingPeerLeavesOtherPeersCatalogs() throws {
        let manager = ProximityClothingShareManager(store: MockProximityHost())

        try storeCatalog(in: manager, displayName: "Robin", designer: UUID(), itemName: "Star Cape")
        try storeCatalog(in: manager, displayName: "Alex", designer: UUID(), itemName: "Sun Hat")
        #expect(manager.peerCatalogs.count == 2)

        // Robin (display-name-keyed) disconnects; Alex is still nearby.
        manager.clearCatalogs(fingerprint: nil, identityDisplayName: "Robin", transportDisplayName: "Robin")

        #expect(manager.catalog(for: "Robin") == nil)                      // gone
        #expect(manager.catalog(for: "Alex") != nil)                       // NOT over-cleared
        #expect(manager.peerCatalogs.count == 1)
    }

    @Test func fingerprintKeyedCatalogStillClearsOnDisconnect() throws {
        // Verified peers key by fingerprint; the fix must not regress that path.
        let manager = ProximityClothingShareManager(store: MockProximityHost())
        try storeCatalog(in: manager, displayName: "Robin", fingerprint: "FP-ROBIN-000001", designer: UUID(), itemName: "Star Cape")
        #expect(manager.catalog(for: "FP-ROBIN-000001") != nil)

        manager.clearCatalogs(fingerprint: "FP-ROBIN-000001", identityDisplayName: "Robin", transportDisplayName: "Robin")
        #expect(manager.peerCatalogs.isEmpty)
    }

    // MARK: - Helpers

    /// Feed a catalog through the real public receive path so it is keyed exactly as production would key it.
    private func storeCatalog(
        in manager: ProximityClothingShareManager,
        displayName: String,
        fingerprint: String? = nil,
        designer: UUID,
        itemName: String
    ) throws {
        let item = CustomizationItem(
            name: itemName,
            slot: .hat,
            texture: ItemGridTexture.blank(for: .hat, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: designer),
            isShareable: true,
            price: 7
        )
        let payload = ClothingCatalogPayload(designerID: designer, displayName: displayName, items: [item])
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: displayName,
            recipientFingerprint: nil,
            payloadType: .clothingCatalog,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Clothing shop"),
            payload: plaintext,
            createdAt: day,
            expiresAt: nil,
            signature: Data()
        )
        let peer: ProximityCoordinator.PeerIdentity? = fingerprint.map {
            ProximityCoordinator.PeerIdentity(
                id: UUID(),
                displayName: displayName,
                signingPublicKey: Data(),
                keyAgreementPublicKey: Data(),
                fingerprint: $0,
                rangingMode: .none,
                firstSeenAt: day
            )
        }
        manager.proximityCoordinator(throwawayCoordinator(), didReceive: envelope, plaintext: plaintext, from: peer)
    }

    private func throwawayCoordinator() -> ProximityCoordinator {
        let identity = IdentityService(keychainService: "test.clothing.ephemeral.\(UUID().uuidString)")
        try? identity.ensureProvisioned()
        return ProximityCoordinator(
            identity: identity,
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }
}

/// Minimal `ProximityHost` — the clothing manager only reads display name + trust vault in these tests.
@MainActor
private final class MockProximityHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { [] }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool { false }
    func blockProximityPeer(signingPublicKey: Data) {}
}
