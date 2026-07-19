@testable import ProximityKit
import Foundation
import Testing
import MultipeerConnectivity
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

struct RecipeShareCodecTests {
    @MainActor
    @Test func payloadRoundTripsThroughJSON() throws {
        let fixture = makeRecipeFixture()
        let payload = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        let decoded = try RecipeShareCodec.decodePayload(from: json)

        #expect(decoded == payload)
    }

    @MainActor
    @Test func shareTextRoundTripsWithPreamble() throws {
        let fixture = makeRecipeFixture()
        let payload = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)
        let shareText = RecipeShareCodec.shareText(for: fixture.recipe, foodItems: fixture.foodItems)
        let text = "Try this after training.\n\n\(shareText)\n\nSent from Fernlet."

        let decoded = try RecipeShareCodec.decodePayload(from: text)

        #expect(decoded == payload)
    }

    @Test func decodeRejectsTextWithoutPayloadMarker() {
        #expect(throws: RecipeImportError.missingPayload) {
            try RecipeShareCodec.decodePayload(from: "Recipe: oats, yogurt, berries")
        }
    }

    @Test func decodeRejectsInvalidJSONAfterMarker() {
        #expect(throws: RecipeImportError.invalidPayload) {
            try RecipeShareCodec.decodePayload(from: "Fernlet recipe data:\n{not valid json}")
        }
    }

    @MainActor
    @Test func decodeRejectsUnsupportedFormatVersion() throws {
        let fixture = makeRecipeFixture()
        var payload = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)
        payload.version = 2
        let data = try JSONEncoder().encode(payload)
        let json = try #require(String(data: data, encoding: .utf8))

        #expect(throws: RecipeImportError.unsupportedFormat) {
            try RecipeShareCodec.decodePayload(from: json)
        }
    }

    @MainActor
    @Test func proximityPayloadForLocalRecipePreservesSharePayload() throws {
        let fixture = makeRecipeFixture()
        let expected = RecipeShareCodec.payload(for: fixture.recipe, foodItems: fixture.foodItems)

        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)
        let decoded = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: JSONEncoder().encode(payload))

        #expect(decoded.format == "fernlet.proximity.recipe")
        #expect(decoded.version == 1)
        #expect(decoded.recipe.kind == .local)
        #expect(decoded.recipe.local == expected)
        #expect(decoded.recipe.saved == nil)
    }

    @MainActor
    @Test func proximityPayloadForSavedRecipePreservesSavedRecipeFields() throws {
        let recipe = makeSavedRecipe()
        let webImport = try #require(recipe.webImport)

        let payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])
        let decoded = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: JSONEncoder().encode(payload))
        let saved = try #require(decoded.recipe.saved)

        #expect(decoded.recipe.kind == .saved)
        #expect(decoded.recipe.local == nil)
        #expect(saved.name == recipe.name)
        #expect(saved.sourceURLString == webImport.sourceURLString)
        #expect(saved.ingredients == webImport.ingredientLines)
        #expect(saved.summary == recipe.notes)
        #expect(saved.servings == recipe.servings)
        #expect(saved.protein == webImport.macros.protein)
        #expect(saved.carbs == webImport.macros.carbs)
        #expect(saved.fat == webImport.macros.fat)
    }

    @MainActor
    @Test func omittingShareNotesRemovesLocalRecipeNotesOnly() throws {
        let fixture = makeRecipeFixture()
        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)

        let stripped = payload.omittingShareNotes()

        #expect(payload.hasShareNotes)
        #expect(stripped.recipe.local?.notes == "")
        #expect(stripped.recipe.local?.name == payload.recipe.local?.name)
        #expect(stripped.recipe.local?.ingredients == payload.recipe.local?.ingredients)
    }

    @MainActor
    @Test func omittingShareNotesRemovesSavedRecipeSummaryOnly() {
        let payload = RecipeShareCodec.proximityPayload(for: makeSavedRecipe(), foodItems: [])

        let stripped = payload.omittingShareNotes()

        #expect(payload.hasShareNotes)
        #expect(stripped.recipe.saved?.summary == "")
        #expect(stripped.recipe.saved?.name == payload.recipe.saved?.name)
        #expect(stripped.recipe.saved?.ingredients == payload.recipe.saved?.ingredients)
    }

    @MainActor
    @Test func importProximityLocalRecipeCreatesRecipeAndIngredients() throws {
        let fixture = makeRecipeFixture()
        let store = makeTestStore()
        let payload = RecipeShareCodec.proximityPayload(for: fixture.recipe, foodItems: fixture.foodItems)

        let importedName = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.recipes.first)

        #expect(importedName == "Training Bowl")
        #expect(imported.name == "Training Bowl")
        #expect(imported.servings == 2)
        #expect(imported.ingredients.count == 3)
        #expect(store.foodItems.filter { $0.tags.contains("imported") }.count == 3)
    }

    @MainActor
    @Test func importProximitySavedRecipeAddsSavedRecipe() throws {
        let store = makeTestStore()
        let recipe = makeSavedRecipe()
        let webImport = try #require(recipe.webImport)
        let payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])

        let importedName = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.savedRecipes.first)
        let importedWebImport = try #require(imported.webImport)

        #expect(importedName == recipe.name)
        #expect(imported.name == recipe.name)
        #expect(importedWebImport.sourceURLString == webImport.sourceURLString)
        #expect(importedWebImport.ingredientLines == webImport.ingredientLines)
        #expect(imported.notes == recipe.notes)
        #expect(imported.servings == recipe.servings)
        #expect(importedWebImport.macros == webImport.macros)
        #expect(imported.isWebImport)
    }

    @MainActor
    @Test func importProximityRecipeRejectsUnsupportedVersion() {
        let store = makeTestStore()
        var payload = RecipeShareCodec.proximityPayload(for: makeSavedRecipe(), foodItems: [])
        payload.version = 2

        #expect(throws: RecipeImportError.unsupportedFormat) {
            try store.importProximityRecipeShare(payload)
        }
    }

    // MARK: - Safari-presentable URL guard (SFSafariViewController crashes on non-http(s) URLs)

    @Test func safariPresentableGuardAcceptsWebSchemesOnly() throws {
        // http/https are the only schemes SFSafariViewController accepts.
        #expect(try #require(URL(string: "https://example.com/recipe")).isSafariPresentable)
        #expect(try #require(URL(string: "http://example.com/recipe")).isSafariPresentable)
        #expect(try #require(URL(string: "HTTPS://EXAMPLE.COM")).isSafariPresentable)   // scheme is case-insensitive
        // Everything else must be rejected — these are exactly the shapes that crash the Safari sheet.
        #expect(!(try #require(URL(string: "file:///etc/passwd")).isSafariPresentable))
        #expect(!URL(fileURLWithPath: "/").isSafariPresentable)
        #expect(!(try #require(URL(string: "javascript:alert(1)")).isSafariPresentable))
        #expect(!(try #require(URL(string: "tel:1")).isSafariPresentable))
        #expect(!(try #require(URL(string: "recipes.html")).isSafariPresentable))       // schemeless relative
    }

    @MainActor
    @Test func importProximitySavedRecipeBlanksNonWebSourceURLButKeepsRecipe() throws {
        let store = makeTestStore()
        // A peer sends a saved recipe whose source URL is a file:// path — a real string that parses via
        // URL(string:) but would crash the in-app Safari sheet. The recipe must survive; only the bad
        // source link is blanked to "no source".
        let malicious = RecipeDefinition(
            name: "Shared Bowl",
            servings: 2,
            ingredients: [],
            notes: "From a friend.",
            source: MealLogSource.webImport,
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800),
            webImport: RecipeWebImport(
                sourceURLString: "file:///etc/passwd",
                ingredientLines: ["Oats", "Yogurt"],
                macros: Macros(protein: 20, carbs: 30, fat: 5),
                micronutrients: Micronutrients()
            )
        )
        let payload = RecipeShareCodec.proximityPayload(for: malicious, foodItems: [])

        let importedName = try store.importProximityRecipeShare(payload)
        let imported = try #require(store.savedRecipes.first)
        let importedWebImport = try #require(imported.webImport)

        #expect(importedName == "Shared Bowl")
        #expect(imported.name == "Shared Bowl")
        #expect(importedWebImport.ingredientLines == ["Oats", "Yogurt"])   // recipe body preserved
        #expect(importedWebImport.sourceURLString == "")                    // bad URL blanked
        #expect(importedWebImport.sourceURL == nil)                         // derived link is now absent
    }

    // MARK: - Retained trust policy enforces revoked keys at the envelope layer
    //
    // Regression for the manager-side weak-trust-policy deallocation (cloned from the heart-manager bug):
    // ProximityRecipeShareManager created its FriendSessionTrustPolicy as a local in `handleChannelReady`
    // and passed it to a ProximityCoordinator that holds it only `weak`. The local deallocated when
    // handleChannelReady returned, so by the time an envelope arrived the coordinator's revoked/blocked-key
    // rejection + audit calls all no-op'd against nil. The fix retains the policy on RecipeShareConnection.
    // This drives a connection the manager actually built (and retains in its `connections` array); after
    // the seam returns the local policy is gone, so the coordinator's weak ref survives ONLY because the
    // connection holds it. A BLOCKED-key envelope is then dropped (`.failed("revokedKey")`) and audited —
    // enforcement that silently no-op'd before the fix. (Phase-2 friend lifecycle semantics moved the
    // friend-mode transport ban to blocked keys only — a revoked-only "Removed" peer may handshake
    // again — so this test blocks rather than revokes; block() sets both timestamps and fires the same
    // coordinator gate.) Mirrors HeartShareTests.retainedTrustPolicyDropsEnvelopeFromBlockedKey.
    @MainActor
    @Test func retainedTrustPolicyDropsEnvelopeFromBlockedKey() async throws {
        let host = RecipeRevokedKeyTestHost()
        let (remote, remoteID) = try makeProvisionedIdentity(); defer { KeychainItem.deleteAll(service: remoteID) }

        // Trust then BLOCK the remote's signing key in the host's vault (the manager's policy reads it).
        let remotePeer = ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: "Revoked",
            signingPublicKey: remote.localSigningPublicKey,
            keyAgreementPublicKey: remote.localKeyAgreementPublicKey,
            fingerprint: remote.localFingerprint,
            rangingMode: .none,
            firstSeenAt: Date(timeIntervalSince1970: 1_780_000_000)
        )
        host.proximityTrustVault.trust(remotePeer, mode: .friend)
        host.proximityTrustVault.block(signingPublicKey: remote.localSigningPublicKey)

        let manager = ProximityRecipeShareManager(store: host)
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
        #expect(host.proximityTrustVault.auditEvents.contains { $0.kind == .revokedPeerBlocked })
    }

    @MainActor
    private func makeProvisionedIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.proximity.recipe.trust.test.\(UUID().uuidString)"
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

    private func makeRecipeFixture() -> (recipe: RecipeDefinition, foodItems: [FoodItem]) {
        let oats = foodItem(
            name: "Rolled oats",
            servingSize: 40,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 5, carbs: 27, fat: 3)
        )
        let yogurt = foodItem(
            name: "Greek yogurt",
            servingSize: 170,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 18, carbs: 6, fat: 0)
        )
        let berries = foodItem(
            name: "Blueberries",
            servingSize: 100,
            servingUnit: RecipeUnit.gram.rawValue,
            macros: Macros(protein: 1, carbs: 14, fat: 0)
        )
        let recipe = RecipeDefinition(
            name: "Training Bowl",
            servings: 2,
            ingredients: [
                RecipeIngredient(foodItemId: oats.id, quantity: 80, unit: RecipeUnit.gram.rawValue),
                RecipeIngredient(foodItemId: yogurt.id, quantity: 340, unit: RecipeUnit.gram.rawValue),
                RecipeIngredient(foodItemId: berries.id, quantity: 150, unit: RecipeUnit.gram.rawValue)
            ],
            notes: "Chill before serving.",
            source: "manual",
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800)
        )
        return (recipe, [oats, yogurt, berries])
    }

    private func makeSavedRecipe() -> RecipeDefinition {
        let savedAt = Date(timeIntervalSince1970: 1_779_664_800)
        return RecipeDefinition(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000777")!,
            name: "Saved Training Bowl",
            servings: 3,
            ingredients: [],
            notes: "A saved web recipe summary.",
            source: MealLogSource.webImport,
            createdAt: savedAt,
            updatedAt: savedAt,
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/saved-training-bowl",
                ingredientLines: ["Oats", "Greek yogurt", "Blueberries"],
                macros: Macros(protein: 24, carbs: 42, fat: 6),
                micronutrients: Micronutrients()
            )
        )
    }

    private func foodItem(name: String, servingSize: Double, servingUnit: String, macros: Macros) -> FoodItem {
        FoodItem(
            name: name,
            brandSource: nil,
            servingSize: servingSize,
            servingUnit: servingUnit,
            macros: macros,
            micronutrients: Micronutrients(),
            category: "test",
            source: .manual,
            tags: ["recipe"]
        )
    }
}

/// Minimal `ProximityHost` for the trust-policy regression test — the manager only reads the display name
/// and the trust vault, and delegates block checks to the vault so it is the single source of truth.
@MainActor
private final class RecipeRevokedKeyTestHost: ProximityHost {
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
