// MeshClothingShopTests.swift
// Phase 3a — the clothing shop on the friend mesh (Docs/Proximity-Mesh-Redesign-2026-07-10.md).
//
// Ports the deleted standalone-radio suites (ProximityClothingShareEphemeralityTests + the delivery
// half of FriendShopTests) to the mesh-owned lifecycle. Covers: catalog accumulation during the
// session (keyed by VERIFIED fingerprint only — never a display name), the post-session shop window
// (opens at the same teardown moment that promotes pendingFriendReview, 1-hour lazy expiry, early
// close at the next session FORMATION — the first slot commit, NOT the startJoin/startNewMesh search
// start, which fires on every Social-tab entry / scene dip and must leave the window intact, exactly
// like the friend-review batch), the commit-symmetry catalog exchange (a `clothingCatalogRequest`
// from a later-committing peer is answered bypassing the once-per-slot guard; eviction prunes the
// tracking so rejoiners re-exchange), the payload-layer opt-out (provider nil when off, inbound
// dropped when off, OFF transition clears held state), the hostile-input guards that must survive
// the port (per-sender rate limit, item-count cap before mapping, blocked-fingerprint drop, per-slot
// request-response rate limit), the capability-gated outbound, and the retained trust-policy
// blocked-key drop (ported from ClothingShareCodecTests — the clothing manager it drove is deleted;
// the mesh's slotTrustPolicies retention is the same pattern).

@testable import ProximityKit
import Foundation
import Testing
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@Suite(.serialized) @MainActor
struct MeshClothingShopTests {
    // Keeps the FernletStore alive past the manager's `unowned let store` (mirrors
    // MeshNetworkManagerTests). Uses the store's own lazily-wired mesh manager so the payload-layer
    // opt-out closures (isSharingEnabledProvider / localCatalogProvider) are the production wiring.
    let store = makeTestStore()

    private let day = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Fixtures

    private func sellerItem(name: String = "Star Cape", price: Int = 7, designer: UUID) -> CustomizationItem {
        CustomizationItem(
            name: name,
            slot: .hat,
            texture: ItemGridTexture.blank(for: .hat, palette: ItemDesignPalette.hexes),
            designer: ItemDesigner(id: designer),
            isShareable: true,
            price: price
        )
    }

    private func catalogEnvelope(
        displayName: String,
        items: [CustomizationItem],
        designerID: UUID = UUID()
    ) throws -> (envelope: FernletIdentityEnvelope, plaintext: Data) {
        let payload = ClothingCatalogPayload(designerID: designerID, displayName: displayName, items: items)
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
        return (envelope, plaintext)
    }

    private func makePeerIdentity(
        name: String,
        signingPublicKey: Data,
        capabilities: [String]? = [ProximityCapability.photos.rawValue, ProximityCapability.shop.rawValue]
    ) -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: name,
            signingPublicKey: signingPublicKey,
            keyAgreementPublicKey: Data([9, 9, 9]),
            fingerprint: IdentityService.fingerprint(of: signingPublicKey),
            rangingMode: .none,
            firstSeenAt: day,
            capabilities: capabilities
        )
    }

    private func makeMultipeerPeer(name: String) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: name)
        )
    }

    private func throwawayCoordinator() -> ProximityCoordinator {
        // Deliberately NOT provisioned: the coordinator's init never touches the keychain, and the
        // manager only identity-compares it against its slots (mirrors MeshNetworkManagerTests).
        let identity = IdentityService(keychainService: "test.mesh.shop.\(UUID().uuidString)")
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

    /// Registers a COMMITTED slot for a fresh coordinator and drives a catalog through the full
    /// production dispatch path (registry commit gate → blocked drop → shop receive).
    @discardableResult
    private func deliverCatalog(
        via manager: MeshNetworkManager,
        senderName: String,
        senderSigningKey: Data,
        items: [CustomizationItem],
        designerID: UUID = UUID()
    ) throws -> ProximityCoordinator.PeerIdentity {
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: senderName, signingPublicKey: senderSigningKey)
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: makeMultipeerPeer(name: senderName),
            fingerprint: identity.fingerprint
        )
        let (envelope, plaintext) = try catalogEnvelope(displayName: senderName, items: items, designerID: designerID)
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)
        return identity
    }

    /// Registers a COMMITTED slot AND drives the production per-commit shop hook
    /// (`noteSlotCommittedForShop`) — session formation + the once-per-slot catalog offer — as
    /// `onSlotConnected` does at a real handshake commit.
    @discardableResult
    private func commitSlot(
        via manager: MeshNetworkManager,
        name: String,
        signingKey: Data,
        capabilities: [String]? = [ProximityCapability.photos.rawValue, ProximityCapability.shop.rawValue]
    ) -> (coordinator: ProximityCoordinator, peer: MultipeerPeer, identity: ProximityCoordinator.PeerIdentity) {
        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: name, signingPublicKey: signingKey, capabilities: capabilities)
        let peer = makeMultipeerPeer(name: name)
        manager.addSlotForTesting(coordinator: coordinator, peer: peer, fingerprint: identity.fingerprint)
        if let slot = manager.slots.first(where: { $0.id == peer.id }) {
            manager.noteSlotCommittedForShop(slot: slot, identity: identity)
        }
        return (coordinator, peer, identity)
    }

    /// An inbound `clothingCatalogRequest` shell — it carries no payload body; the verified sender
    /// identity (the dispatch `from:` argument) is the whole message.
    private func requestEnvelope(displayName: String) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: displayName,
            recipientFingerprint: nil,
            payloadType: .clothingCatalogRequest,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Clothing catalog request"),
            payload: Data(),
            createdAt: day,
            expiresAt: nil,
            signature: Data()
        )
    }

    // MARK: - In-session accumulation

    @Test func catalogsAccumulateDuringSessionKeyedByVerifiedFingerprint() throws {
        let manager = store.meshNetworkManager
        let robin = try deliverCatalog(via: manager, senderName: "Robin", senderSigningKey: Data([1, 2, 3]),
                                       items: [sellerItem(designer: UUID())])
        let alex = try deliverCatalog(via: manager, senderName: "Alex", senderSigningKey: Data([4, 5, 6]),
                                      items: [sellerItem(name: "Sun Hat", designer: UUID())])

        #expect(manager.clothingShop.peerCatalogs.count == 2)
        #expect(Set(manager.clothingShop.peerCatalogs.map(\.id)) == [robin.fingerprint, alex.fingerprint])
        // Keyed by the transport-VERIFIED fingerprint exclusively — never a display name.
        #expect(manager.clothingShop.peerCatalogs.allSatisfy { $0.senderFingerprint != nil })
        // Catalogs accumulate mid-session; no window yet (the session hasn't ended).
        #expect(manager.clothingShop.window == nil)
    }

    @Test func reBroadcastReplacesTheSendersPriorCatalogInsteadOfStacking() throws {
        let shop = MeshClothingShop()
        shop.isSharingEnabledProvider = { true }
        let fingerprint = "FP-ROBIN-000001"

        let (first, firstPlain) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(designer: UUID())])
        shop.receiveCatalog(first, plaintext: firstPlain, verifiedFingerprint: fingerprint, now: day)

        let (second, secondPlain) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(name: "New Hat", designer: UUID())])
        shop.receiveCatalog(second, plaintext: secondPlain, verifiedFingerprint: fingerprint, now: day.addingTimeInterval(10))

        #expect(shop.peerCatalogs.count == 1)
        #expect(shop.peerCatalogs.first?.payload.items.first?.name == "New Hat")
    }

    // MARK: - Hostile-input guards (must survive the port)

    @Test func perSenderRateLimitDropsRapidReBroadcasts() throws {
        let shop = MeshClothingShop()
        shop.isSharingEnabledProvider = { true }
        let fingerprint = "FP-ROBIN-000001"

        let (first, firstPlain) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(designer: UUID())])
        shop.receiveCatalog(first, plaintext: firstPlain, verifiedFingerprint: fingerprint, now: day)

        let (flood, floodPlain) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(name: "Flood", designer: UUID())])
        shop.receiveCatalog(flood, plaintext: floodPlain, verifiedFingerprint: fingerprint, now: day.addingTimeInterval(1))

        #expect(shop.peerCatalogs.first?.payload.items.first?.name == "Star Cape",
                "A re-broadcast inside the 3 s window must be dropped")

        // Past the window it is accepted again (and replaces).
        shop.receiveCatalog(flood, plaintext: floodPlain, verifiedFingerprint: fingerprint, now: day.addingTimeInterval(4))
        #expect(shop.peerCatalogs.first?.payload.items.first?.name == "Flood")
    }

    @Test func itemCountIsCappedBeforeMappingAndItemsAreSanitized() throws {
        let shop = MeshClothingShop()
        shop.isSharingEnabledProvider = { true }
        // A hostile catalog over the listing cap, with an out-of-range price on every item.
        let items = (0..<(ClothingShopLimits.maxListedItems + 3)).map { i in
            sellerItem(name: "Item\(i)", price: 9_999, designer: UUID())
        }
        let (envelope, plaintext) = try catalogEnvelope(displayName: "Robin", items: items)

        shop.receiveCatalog(envelope, plaintext: plaintext, verifiedFingerprint: "FP-HOSTILE", now: day)

        let held = try #require(shop.peerCatalogs.first)
        #expect(held.payload.items.count == ClothingShopLimits.maxListedItems)   // capped BEFORE mapping
        #expect(held.payload.items.allSatisfy { $0.price <= ClothingShopLimits.maxPrice })  // clamped
    }

    @Test func catalogFromBlockedFingerprintIsDropped() throws {
        let manager = store.meshNetworkManager
        let signingKey = Data([7, 7, 7])
        let identity = makePeerIdentity(name: "Blocked", signingPublicKey: signingKey)
        // Block mirrors .friendPhoto: trust then block so the vault holds the fingerprint.
        store.proximityTrustVault.trust(identity, mode: .friend)
        store.proximityTrustVault.block(signingPublicKey: signingKey)

        let coordinator = throwawayCoordinator()
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: makeMultipeerPeer(name: "Blocked"),
            fingerprint: identity.fingerprint
        )
        let (envelope, plaintext) = try catalogEnvelope(displayName: "Blocked", items: [sellerItem(designer: UUID())])
        manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: identity)

        #expect(manager.clothingShop.peerCatalogs.isEmpty)
    }

    // MARK: - Post-session window lifecycle

    @Test func windowOpensAtSessionEndWithHeldCatalogs() throws {
        let manager = store.meshNetworkManager
        try deliverCatalog(via: manager, senderName: "Robin", senderSigningKey: Data([1, 2, 3]),
                           items: [sellerItem(designer: UUID())])
        #expect(manager.clothingShop.window == nil)

        manager.leaveSession()   // the same teardown funnel that promotes pendingFriendReview

        let window = try #require(manager.clothingShop.window)
        #expect(manager.clothingShop.isWindowOpen)
        #expect(abs(window.expiresAt.timeIntervalSince(window.opensAt) - MeshClothingShop.windowDuration) < 1)
        #expect(manager.clothingShop.peerCatalogs.count == 1, "Catalogs stay browsable through the window")
    }

    @Test func windowDoesNotOpenWithoutCatalogs() {
        let manager = store.meshNetworkManager
        manager.leaveSession()
        #expect(manager.clothingShop.window == nil)
        #expect(!manager.clothingShop.isWindowOpen)
    }

    @Test func windowExpiresLazilyAfterOneHour() throws {
        let shop = MeshClothingShop()
        shop.isSharingEnabledProvider = { true }
        let (envelope, plaintext) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(designer: UUID())])
        shop.receiveCatalog(envelope, plaintext: plaintext, verifiedFingerprint: "FP-ROBIN", now: day)

        shop.openWindowAtSessionEnd(now: day)

        #expect(shop.isWindowOpen(at: day.addingTimeInterval(30 * 60)))
        #expect(shop.remainingWindowMinutes(at: day.addingTimeInterval(30 * 60)) == 30)
        #expect(!shop.isWindowOpen(at: day.addingTimeInterval(61 * 60)))
        #expect(shop.remainingWindowMinutes(at: day.addingTimeInterval(61 * 60)) == nil)

        // Lazy cleanup drops the window AND the held catalogs (memory-only, gone after the hour).
        shop.cleanupIfExpired(now: day.addingTimeInterval(61 * 60))
        #expect(shop.window == nil)
        #expect(shop.peerCatalogs.isEmpty)
    }

    @Test func repeatedTeardownNeverExtendsAnOpenWindow() throws {
        let shop = MeshClothingShop()
        shop.isSharingEnabledProvider = { true }
        let (envelope, plaintext) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(designer: UUID())])
        shop.receiveCatalog(envelope, plaintext: plaintext, verifiedFingerprint: "FP-ROBIN", now: day)

        shop.openWindowAtSessionEnd(now: day)
        shop.openWindowAtSessionEnd(now: day.addingTimeInterval(30 * 60))   // late second funnel call

        #expect(shop.window?.opensAt == day, "Only beginNewSession resets an open window")
    }

    /// Spec ("'Next session start' = first slot COMMIT, not search start"): startJoin/startNewMesh
    /// fire automatically on every Social-tab entry and scene reactivation, so the search-start seam
    /// must NOT touch the window or held catalogs — closing it there would destroy the window before
    /// the user could ever reach its only entry point. The friend-review batch survives the same seam
    /// (as it always did); the two lifecycles diverge only at session FORMATION.
    @Test func searchStartLeavesWindowCatalogsAndPendingReviewIntact() throws {
        let manager = store.meshNetworkManager
        manager.recordSessionParticipant(
            displayName: "Robin", fingerprint: "aabbccdd11223344",
            signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]))
        try deliverCatalog(via: manager, senderName: "Robin", senderSigningKey: Data([1, 2, 3]),
                           items: [sellerItem(designer: UUID())])

        manager.leaveSession()
        #expect(manager.clothingShop.isWindowOpen)
        #expect(manager.pendingFriendReview != nil)

        manager.resetSessionRosterForNewSession()   // the startJoin/startNewMesh seam (tab entry / scene dip)

        #expect(manager.clothingShop.isWindowOpen, "The window survives search starts — it closes at session FORMATION")
        #expect(manager.clothingShop.peerCatalogs.count == 1, "Held catalogs survive with it")
        #expect(manager.pendingFriendReview != nil, "The friend-review batch survives search starts by design")
    }

    /// The owner decision "closes when a new session starts" keys on FORMATION: the first slot
    /// commit after a no-session state closes the previous window and drops its catalogs so the
    /// fresh session accumulates from a clean slate.
    @Test func firstSlotCommitClosesTheWindowAndClearsCatalogs() throws {
        let manager = store.meshNetworkManager
        try deliverCatalog(via: manager, senderName: "Robin", senderSigningKey: Data([1, 2, 3]),
                           items: [sellerItem(designer: UUID())])
        manager.leaveSession()
        #expect(manager.clothingShop.isWindowOpen)

        // photos-only peer: formation runs regardless of capability, and no async catalog-offer
        // task is spawned to outlive this synchronous test (the offer path has its own tests).
        commitSlot(via: manager, name: "Alex", signingKey: Data([4, 5, 6]),
                   capabilities: [ProximityCapability.photos.rawValue])   // session formation

        #expect(manager.clothingShop.window == nil, "The first commit closes the previous window")
        #expect(manager.clothingShop.peerCatalogs.isEmpty, "…and drops the previous session's catalogs")
    }

    /// The formation reset is once-per-formation: later commits (promoteToMesh's loop re-enters the
    /// same hook) must never wipe catalogs already received mid-session.
    @Test func laterCommitsDoNotClearMidSessionCatalogs() throws {
        let manager = store.meshNetworkManager
        // photos-only peers: no async catalog-offer tasks outlive this synchronous test; the
        // formation/clear behavior under test is capability-independent.
        let photosOnly = [ProximityCapability.photos.rawValue]
        let robin = commitSlot(via: manager, name: "Robin", signingKey: Data([1, 2, 3]), capabilities: photosOnly)
        let (envelope, plaintext) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(designer: UUID())])
        manager.proximityCoordinator(robin.coordinator, didReceive: envelope, plaintext: plaintext, from: robin.identity)
        #expect(manager.clothingShop.peerCatalogs.count == 1)

        commitSlot(via: manager, name: "Alex", signingKey: Data([4, 5, 6]), capabilities: photosOnly)   // 2nd commit, same session

        #expect(manager.clothingShop.peerCatalogs.count == 1, "A mid-session commit must not clear catalogs")
        #expect(manager.clothingShop.window == nil)
    }

    /// The transient-drop case the formation model makes coherent: last slot lost mid-outing opens
    /// the window; further teardowns without a commit never extend it; a re-commit closes it, clears
    /// catalogs, the exchange re-runs, and the REAL session end opens a fresh 1 h window.
    @Test func transientDropThenRecommitYieldsAFreshWindowAtTheRealSessionEnd() throws {
        let manager = store.meshNetworkManager
        // photos-only peers: no async catalog-offer tasks outlive this synchronous test.
        let photosOnly = [ProximityCapability.photos.rawValue]
        let first = commitSlot(via: manager, name: "Robin", signingKey: Data([1, 2, 3]), capabilities: photosOnly)
        let (envelope, plaintext) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(designer: UUID())])
        manager.proximityCoordinator(first.coordinator, didReceive: envelope, plaintext: plaintext, from: first.identity)

        // Transient drop: the last committed slot is lost mid-outing — the window opens.
        manager.evictSlotForTesting(peerID: first.peer.id)
        let transientWindow = try #require(manager.clothingShop.window)

        // A second teardown with NO intervening commit must not extend the open window.
        manager.leaveSession()
        #expect(manager.clothingShop.window == transientWindow, "Repeated teardowns never extend an open window")

        // Re-commit: formation closes the transient window, clears catalogs, the exchange re-runs.
        let second = commitSlot(via: manager, name: "Robin", signingKey: Data([1, 2, 3]), capabilities: photosOnly)
        #expect(manager.clothingShop.window == nil)
        #expect(manager.clothingShop.peerCatalogs.isEmpty)
        let (again, againPlain) = try catalogEnvelope(displayName: "Robin", items: [sellerItem(name: "Sun Hat", designer: UUID())])
        manager.proximityCoordinator(second.coordinator, didReceive: again, plaintext: againPlain, from: second.identity)

        // The real session end opens a FRESH 1 h window over the re-received catalogs.
        manager.leaveSession()
        let freshWindow = try #require(manager.clothingShop.window)
        #expect(freshWindow.opensAt >= transientWindow.opensAt)
        #expect(manager.clothingShop.peerCatalogs.first?.payload.items.first?.name == "Sun Hat")
    }

    // MARK: - Commit-symmetry catalog exchange (clothingCatalogRequest)

    /// The asymmetry the request closes: our catalog goes out at OUR commit, but the peer's registry
    /// gate needs the PEER's commit — a later committer would drop it forever under once-per-slot
    /// tracking. Its request (sent at its own commit) must be answered, BYPASSING that guard; and the
    /// per-slot response rate limit caps request-spam amplification.
    @Test func requestFromCommittedSlotIsAnsweredBypassingOncePerSlotAndRateLimited() async throws {
        let manager = store.meshNetworkManager
        var catalogSends = 0
        var requestSends = 0
        manager.onShopCatalogSendForTesting = { _ in catalogSends += 1 }
        manager.onShopCatalogRequestSendForTesting = { _ in requestSends += 1 }

        let robin = commitSlot(via: manager, name: "Robin", signingKey: Data([1, 2, 3]))
        // The commit-time offer sends the catalog AND the commit-symmetry request; awaiting the
        // request (the task's last step) drains the async send task inside the test's lifetime.
        await waitUntil { catalogSends == 1 && requestSends == 1 }
        #expect(catalogSends == 1)
        #expect(requestSends == 1, "Our own commit also asks for the peer's catalog")

        manager.proximityCoordinator(robin.coordinator, didReceive: requestEnvelope(displayName: "Robin"),
                                     plaintext: Data(), from: robin.identity)
        await waitUntil { catalogSends == 2 }
        #expect(catalogSends == 2, "A committed peer's request re-sends past the once-per-slot guard")

        // An immediate repeat request is dropped by the per-slot response rate limit.
        manager.proximityCoordinator(robin.coordinator, didReceive: requestEnvelope(displayName: "Robin"),
                                     plaintext: Data(), from: robin.identity)
        try? await Task.sleep(for: .milliseconds(80))
        #expect(catalogSends == 2, "Responses are rate-limited per slot")
    }

    /// The commit-time offer itself stays once-per-slot: a re-entry of the commit hook for the same
    /// slot (promoteToMesh's committed loop) must not duplicate the send.
    @Test func commitOffersTheCatalogOncePerSlot() async throws {
        let manager = store.meshNetworkManager
        var catalogSends = 0
        var requestSends = 0
        manager.onShopCatalogSendForTesting = { _ in catalogSends += 1 }
        manager.onShopCatalogRequestSendForTesting = { _ in requestSends += 1 }

        let robin = commitSlot(via: manager, name: "Robin", signingKey: Data([1, 2, 3]))
        await waitUntil { catalogSends == 1 && requestSends == 1 }

        let slot = try #require(manager.slots.first { $0.id == robin.peer.id })
        manager.noteSlotCommittedForShop(slot: slot, identity: robin.identity)   // hook re-entry
        try? await Task.sleep(for: .milliseconds(80))
        #expect(catalogSends == 1)
        #expect(requestSends == 1)
    }

    @Test func requestFromUncommittedSlotIsDroppedByTheRegistryGate() async throws {
        let manager = store.meshNetworkManager
        var catalogSends = 0
        manager.onShopCatalogSendForTesting = { _ in catalogSends += 1 }

        let coordinator = throwawayCoordinator()
        let identity = makePeerIdentity(name: "Pending", signingPublicKey: Data([9, 9, 1]))
        manager.addSlotForTesting(coordinator: coordinator, peer: makeMultipeerPeer(name: "Pending"), fingerprint: nil)
        manager.proximityCoordinator(coordinator, didReceive: requestEnvelope(displayName: "Pending"),
                                     plaintext: Data(), from: identity)

        try? await Task.sleep(for: .milliseconds(80))
        #expect(catalogSends == 0, "Feature payloads are for committed session members only")
    }

    @Test func optedOutLocalNeverAnswersCatalogRequests() async throws {
        let manager = store.meshNetworkManager
        store.setAllowNearbyClothingShares(false)
        var catalogSends = 0
        manager.onShopCatalogSendForTesting = { _ in catalogSends += 1 }

        let robin = commitSlot(via: manager, name: "Robin", signingKey: Data([1, 2, 3]))
        manager.proximityCoordinator(robin.coordinator, didReceive: requestEnvelope(displayName: "Robin"),
                                     plaintext: Data(), from: robin.identity)

        try? await Task.sleep(for: .milliseconds(80))
        #expect(catalogSends == 0, "Sharing off sends nothing — commit offer and request response alike")
    }

    /// Slot eviction prunes the send tracking so a REJOINING friend re-exchanges (the transport's
    /// peerMap persists across a remote teardown, so a returning peer reuses its old slot UUID).
    /// Two committed peers keep the session alive across the eviction, pinning the PER-SLOT prune
    /// rather than the formation reset.
    @Test func slotEvictionPrunesSendTrackingSoARejoiningFriendReExchanges() async throws {
        let manager = store.meshNetworkManager
        var catalogSends = 0
        var requestSends = 0
        manager.onShopCatalogSendForTesting = { _ in catalogSends += 1 }
        manager.onShopCatalogRequestSendForTesting = { _ in requestSends += 1 }

        let robin = commitSlot(via: manager, name: "Robin", signingKey: Data([1, 2, 3]))
        commitSlot(via: manager, name: "Alex", signingKey: Data([4, 5, 6]))
        await waitUntil { catalogSends == 2 && requestSends == 2 }

        manager.evictSlotForTesting(peerID: robin.peer.id)
        #expect(manager.clothingShop.window == nil, "Alex keeps the session alive — no window mid-session")

        // Robin rejoins with the SAME transport identity (same slot UUID).
        manager.addSlotForTesting(coordinator: robin.coordinator, peer: robin.peer, fingerprint: robin.identity.fingerprint)
        let slot = try #require(manager.slots.first { $0.id == robin.peer.id })
        manager.noteSlotCommittedForShop(slot: slot, identity: robin.identity)

        await waitUntil { catalogSends == 3 && requestSends == 3 }
        #expect(catalogSends == 3, "The pruned once-per-slot guard re-sends to the rejoined friend")
    }

    // MARK: - Payload-layer opt-out

    @Test func localCatalogProviderIsNilWhileSharingIsOff() {
        let shop = store.meshNetworkManager.clothingShop
        #expect(store.settings.allowNearbyClothingShares)
        #expect(shop.isSharingEnabled)
        #expect(shop.localCatalogProvider?() != nil)

        store.setAllowNearbyClothingShares(false)

        #expect(!shop.isSharingEnabled)
        #expect(shop.localCatalogProvider?() == nil, "Nothing is sent while the opt-out is off")
    }

    @Test func inboundCatalogIsDroppedWhileSharingIsOff() throws {
        let manager = store.meshNetworkManager
        store.setAllowNearbyClothingShares(false)

        try deliverCatalog(via: manager, senderName: "Robin", senderSigningKey: Data([1, 2, 3]),
                           items: [sellerItem(designer: UUID())])

        #expect(manager.clothingShop.peerCatalogs.isEmpty)
    }

    @Test func turningSharingOffClearsHeldCatalogsAndClosesTheWindow() throws {
        let manager = store.meshNetworkManager
        try deliverCatalog(via: manager, senderName: "Robin", senderSigningKey: Data([1, 2, 3]),
                           items: [sellerItem(designer: UUID())])
        manager.leaveSession()
        #expect(manager.clothingShop.isWindowOpen)

        store.setAllowNearbyClothingShares(false)

        #expect(manager.clothingShop.window == nil)
        #expect(manager.clothingShop.peerCatalogs.isEmpty)
    }

    // MARK: - Capability-gated outbound

    @Test func localCapabilitiesAdvertiseShopOnlyWhileSharingIsEnabled() {
        let manager = store.meshNetworkManager
        #expect(manager.localCapabilities().contains(ProximityCapability.shop.rawValue))
        #expect(manager.localCapabilities().contains(ProximityCapability.photos.rawValue))

        store.setAllowNearbyClothingShares(false)
        #expect(!manager.localCapabilities().contains(ProximityCapability.shop.rawValue))
        #expect(manager.localCapabilities().contains(ProximityCapability.photos.rawValue),
                "Photos are the mesh's founding capability — always advertised")
    }

    @Test func shopCatalogIsOfferedOnlyToPeersAdvertisingTheShopCapability() {
        let manager = store.meshNetworkManager
        let withShop = ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: "New", signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2]),
            fingerprint: "fp-new", rangingMode: .none, firstSeenAt: day,
            capabilities: [ProximityCapability.photos.rawValue, ProximityCapability.shop.rawValue]
        )
        let photosOnly = ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: "Old", signingPublicKey: Data([3]), keyAgreementPublicKey: Data([4]),
            fingerprint: "fp-old", rangingMode: .none, firstSeenAt: day,
            capabilities: [ProximityCapability.photos.rawValue]
        )
        let legacy = ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: "Legacy", signingPublicKey: Data([5]), keyAgreementPublicKey: Data([6]),
            fingerprint: "fp-legacy", rangingMode: .none, firstSeenAt: day
        )

        #expect(manager.shouldOfferShopCatalog(to: withShop))
        #expect(!manager.shouldOfferShopCatalog(to: photosOnly))
        #expect(!manager.shouldOfferShopCatalog(to: legacy), "A pre-capability legacy peer is photos-only")

        store.setAllowNearbyClothingShares(false)
        #expect(!manager.shouldOfferShopCatalog(to: withShop), "Sharing off sends nothing to anyone")
    }

    // MARK: - Retained trust policy enforces blocked keys at the envelope layer
    //
    // Ported from ClothingShareCodecTests (the ProximityClothingShareManager it drove is deleted): the
    // mesh manager creates its FriendSessionTrustPolicy per slot in `handleChannelReady` and the
    // coordinator holds it only `weak` — the policy survives ONLY because `slotTrustPolicies` retains
    // it. If that retention regresses, the revoked/blocked-key rejection + audit silently no-op
    // (`nil?.isRevokedProximitySigningKey(...) == true` → false). A BLOCKED-key envelope must be
    // dropped (`.failed("revokedKey")`) and audited. (Phase-2 friend lifecycle semantics: the
    // friend-mode transport ban applies to blocked keys only, so this blocks rather than revokes;
    // block() sets both timestamps and fires the same coordinator gate.)
    @Test func retainedSlotTrustPolicyDropsEnvelopeFromBlockedKey() async throws {
        let (remote, remoteID) = try makeProvisionedIdentity(); defer { KeychainItem.deleteAll(service: remoteID) }

        let remotePeer = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Revoked",
            signingPublicKey: remote.localSigningPublicKey,
            keyAgreementPublicKey: remote.localKeyAgreementPublicKey,
            fingerprint: remote.localFingerprint,
            rangingMode: .none,
            firstSeenAt: day
        )
        store.proximityTrustVault.trust(remotePeer, mode: .friend)
        store.proximityTrustVault.block(signingPublicKey: remote.localSigningPublicKey)

        let manager = store.meshNetworkManager
        let transport = MockMultipeerTransport()
        let peer = MultipeerPeer(
            id: UUID(),
            displayName: "Revoked",
            discoveryInfo: ["fp": remote.localFingerprint],
            advertisedFingerprint: remote.localFingerprint,
            underlying: MCPeerID(displayName: "Revoked")
        )
        // The manager builds AND retains the slot — its FriendSessionTrustPolicy lives in
        // slotTrustPolicies, and the coordinator holds it only `weak`, so this exercises the retention.
        let coordinator = manager.makeRetainedSlotCoordinatorForTesting(
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
        // banned-key gate there runs before any mode-specific identity handling, so it exercises the same
        // enforcement the friend-mode production session relies on.
        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        await waitUntil { if case .awaitingTapConfirmation = coordinator.state { return true }; return false }
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(intro), from: peer)
        await waitUntil { if case .failed = coordinator.state { return true }; return false }

        guard case .failed(let reason) = coordinator.state else {
            Issue.record("Expected .failed from blocked-key drop, got \(coordinator.state)")
            return
        }
        #expect(reason.contains("revokedKey"))
        #expect(store.proximityTrustVault.auditEvents.contains { $0.kind == .revokedPeerBlocked })
    }

    private func makeProvisionedIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.proximity.meshshop.trust.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

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
