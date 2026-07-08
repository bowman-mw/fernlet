import Foundation
import Testing
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

/// The clothing-shop codec (Increment 3): building a peer's broadcast catalog from the user's own
/// shareable designs (capped, deterministically ordered, clamped) and sanitizing an untrusted received
/// catalog before it is rendered or bought.
struct ClothingShareCodecTests {

    private let designerID = UUID()
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func item(
        name: String = "Hat",
        slot: ItemSlot = .hat,
        shareable: Bool,
        price: Int,
        designer: UUID,
        offset: Double = 0
    ) -> CustomizationItem {
        CustomizationItem(
            name: name,
            slot: slot,
            texture: ItemGridTexture.blank(for: slot, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: designer),
            createdAt: base.addingTimeInterval(offset),
            isShareable: shareable,
            price: price
        )
    }

    @Test func catalogListsOnlyOwnShareableItemsCappedAndOrdered() {
        var items: [CustomizationItem] = []
        for i in 0..<7 {  // seven own shareable items — over the cap of six
            items.append(item(name: "Item\(i)", shareable: true, price: 10 + i, designer: designerID, offset: Double(i)))
        }
        items.append(item(name: "Private", shareable: false, price: 5, designer: designerID, offset: 100))
        items.append(item(name: "Friend", shareable: true, price: 5, designer: UUID(), offset: 101))  // someone else's

        let catalog = ClothingShareCodec.catalog(forShareable: items, designerID: designerID, displayName: "Robin")

        #expect(catalog.items.count == ClothingShopLimits.maxListedItems)            // capped at 6
        #expect(catalog.items.allSatisfy { $0.designer.id == designerID })           // only your own designs
        #expect(!catalog.items.contains { $0.name == "Private" })                    // private items excluded
        #expect(!catalog.items.contains { $0.name == "Friend" })                     // friend's design excluded
        let times = catalog.items.map(\.createdAt)
        #expect(times == times.sorted())                                             // deterministic order
        #expect(catalog.designerID == designerID)
        #expect(catalog.displayName == "Robin")
    }

    @Test func catalogClampsPriceAndSanitizesName() throws {
        let big = item(name: "X" + String(repeating: "y", count: 60), shareable: true, price: 9_999, designer: designerID)
        let catalog = ClothingShareCodec.catalog(forShareable: [big], designerID: designerID, displayName: "Robin")
        let listed = try #require(catalog.items.first)
        #expect(listed.price == ClothingShopLimits.maxPrice)
        #expect(listed.name.count <= ItemNameModeration.maxNameLength)
    }

    @Test func catalogPayloadRoundTripsThroughJSON() throws {
        let catalog = ClothingShareCodec.catalog(
            forShareable: [item(shareable: true, price: 12, designer: designerID)],
            designerID: designerID,
            displayName: "Robin"
        )
        let data = try JSONEncoder().encode(catalog)
        let decoded = try JSONDecoder().decode(ClothingCatalogPayload.self, from: data)
        #expect(decoded == catalog)
    }

    @Test func sanitizedItemsClampUntrustedTexturePriceAndDeDuplicate() throws {
        // A hostile payload: an oversized texture with out-of-range palette indices, a negative price, an
        // invisible-char name, and a duplicate row (same id).
        var bad = item(shareable: true, price: -5, designer: designerID)
        bad.texture = ItemGridTexture(cols: 200, rows: 200, palette: ["FF0000"], pixels: Array(repeating: 9, count: 200 * 200))
        bad.name = "Hat\u{200B}"
        let payload = ClothingCatalogPayload(designerID: designerID, displayName: "Robin", items: [bad, bad])

        let cleaned = ClothingShareCodec.sanitizedItems(from: payload)

        #expect(cleaned.count == 1)                                                  // deduped by id
        let only = try #require(cleaned.first)
        #expect(only.texture.cols <= ItemSlot.hat.gridCols)                          // refit to slot grid
        #expect(only.texture.rows <= ItemSlot.hat.gridRows)
        #expect(only.texture.pixels.allSatisfy { $0 == ItemGridTexture.transparent || ($0 >= 0 && $0 < only.texture.palette.count) })
        #expect(only.price >= ClothingShopLimits.minPrice && only.price <= ClothingShopLimits.maxPrice)
        #expect(!only.name.unicodeScalars.contains("\u{200B}"))
    }

    @Test func sanitizedItemsSurviveHostileNegativeTextureDimensions() throws {
        // Remotely-triggerable crash: a peer broadcasts a catalog whose item texture carries `rows: -1`
        // (or `cols: -1`). Synthesized Codable happily decodes negative Ints, and the sanitizer used to
        // trap building an inverted Range. Decode-then-sanitize must never crash and must yield a safely
        // bounded texture. Encoding a payload with negative dims and decoding it exercises the real wire path.
        var neg = item(shareable: true, price: 10, designer: designerID)
        neg.texture = ItemGridTexture(cols: -1, rows: -1, palette: ["FF0000"], pixels: [0, 0, 0])
        let payload = ClothingCatalogPayload(designerID: designerID, displayName: "Robin", items: [neg])

        // Round-trip through JSON to prove the negative dims genuinely survive decoding (the untrusted path).
        let data = try JSONEncoder().encode(payload)
        let decoded = try JSONDecoder().decode(ClothingCatalogPayload.self, from: data)
        #expect(decoded.items.first?.texture.rows == -1)

        let cleaned = ClothingShareCodec.sanitizedItems(from: decoded)   // must not trap

        let only = try #require(cleaned.first)
        #expect(only.texture.cols >= 0)
        #expect(only.texture.rows >= 0)
        #expect(only.texture.cols <= ItemSlot.hat.gridCols)
        #expect(only.texture.rows <= ItemSlot.hat.gridRows)
        #expect(only.texture.pixels.count == only.texture.cols * only.texture.rows)
    }

    // MARK: - Retained trust policy enforces revoked keys at the envelope layer
    //
    // Regression for the manager-side weak-trust-policy deallocation (cloned from the heart-manager bug):
    // ProximityClothingShareManager created its FriendSessionTrustPolicy as a local in `handleChannelReady`
    // and passed it to a ProximityCoordinator that holds it only `weak`. The local deallocated when
    // handleChannelReady returned, so by the time an envelope arrived the coordinator's revoked/blocked-key
    // rejection + audit calls all no-op'd against nil. The fix retains the policy on ClothingShareConnection.
    // This drives a connection the manager actually built (and retains in its `connections` array); after
    // the seam returns the local policy is gone, so the coordinator's weak ref survives ONLY because the
    // connection holds it. A revoked-key envelope is then dropped (`.failed("revokedKey")`) and audited —
    // enforcement that silently no-op'd before the fix. Mirrors
    // HeartShareTests.retainedTrustPolicyDropsEnvelopeFromRevokedKey.
    @MainActor
    @Test func retainedTrustPolicyDropsEnvelopeFromRevokedKey() async throws {
        let host = ClothingRevokedKeyTestHost()
        let (remote, remoteID) = try makeProvisionedIdentity(); defer { KeychainItem.deleteAll(service: remoteID) }

        // Trust then revoke the remote's signing key in the host's vault (the manager's policy reads it).
        let remotePeer = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Revoked",
            signingPublicKey: remote.localSigningPublicKey,
            keyAgreementPublicKey: remote.localKeyAgreementPublicKey,
            fingerprint: remote.localFingerprint,
            rangingMode: .none,
            firstSeenAt: base
        )
        host.proximityTrustVault.trust(remotePeer, mode: .friend)
        host.proximityTrustVault.revoke(signingPublicKey: remote.localSigningPublicKey)

        let manager = ProximityClothingShareManager(store: host)
        let transport = MockMultipeerTransport()
        let peer = MultipeerPeer(
            id: UUID(),
            displayName: "Revoked",
            discoveryInfo: ["fp": remote.localFingerprint],
            advertisedFingerprint: remote.localFingerprint,
            underlying: MCPeerID(displayName: "Revoked")
        )
        // The manager builds AND retains the connection — its FriendSessionTrustPolicy lives on the
        // connection struct, and the coordinator holds it only `weak`, so this exercises the retention fix.
        let coordinator = manager.makeRetainedConnectionCoordinatorForTesting(
            peer: peer, transport: transport, ranging: MockRangingProvider()
        )

        let intro = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Revoked",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: Data()
        )
        // Trainer harness reaches handleInbound with the simplest deterministic path (tapToConfirm); the
        // revoked-key gate there runs before any mode-specific identity handling, so it exercises the same
        // enforcement the friend-mode production session relies on.
        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        await waitUntil { if case .awaitingTapConfirmation = coordinator.state { return true }; return false }
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(intro), from: peer)
        await waitUntil { if case .failed = coordinator.state { return true }; return false }

        guard case .failed(let reason) = coordinator.state else {
            Issue.record("Expected .failed from revoked-key drop, got \(coordinator.state)")
            return
        }
        #expect(reason.contains("revokedKey"))
        #expect(host.proximityTrustVault.auditEvents.contains { $0.kind == .revokedPeerBlocked })
    }

    @MainActor
    private func makeProvisionedIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.proximity.clothing.trust.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    @MainActor
    private func waitUntil(
        timeout: Duration = .seconds(2),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }
}

/// Minimal `ProximityHost` for the trust-policy regression test — the manager only reads the display name
/// and the trust vault, and delegates block checks to the vault so it is the single source of truth.
@MainActor
private final class ClothingRevokedKeyTestHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}
