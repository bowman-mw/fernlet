// ProximityRecipeShareCapTests.swift
// FernletTests
//
// Phase 3b (Proximity Mesh Redesign): recipe sharing is hard-capped at exactly 2 devices —
// the radio "closes" (stops advertising + browsing, MCSession kept alive) once a connection
// is established and reopens when the manager-level connection record is evicted. These tests
// drive the manager's session callbacks and internal seams directly — NO real radios are ever
// started (`markRunningForTesting` flips the run flag without `start()`, and the
// MeshMultipeerSession under test is never `start()`ed, so pause/resume toggle its
// `isDiscoveryPaused` flag without touching MCNearbyService* objects).
//
// The reopen contract under test: resume is keyed on manager-level record eviction, NOT on MC
// disconnect events — a failed handshake never fires one, so keying on MC events would leave
// the radio paused forever with no connection (the deadlock class the redesign closes). All
// three removal paths are covered: onPeerDisconnected, the stale-coordinator sweep
// (.ended/.failed), and the parked pre-verification sweep (.idle/.starting/.discovering).

@testable import ProximityKit
import Foundation
import MultipeerConnectivity
import Testing
import FernletDomainModel
import AIProviders
@testable import Fernlet

private final class RecipeCapTestHost: ProximityHost {
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

@MainActor
struct ProximityRecipeShareCapTests {

    /// `endpoint` defaults to a fresh key, so two calls are two devices. Passing the same key
    /// twice is the only way to express "one device, two discovery handles" — see
    /// `makeReturningDevice`.
    private func makePeer(named name: String, endpoint: PeerEndpointKey = PeerEndpointKey()) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            endpoint: endpoint
        )
    }

    /// One device seen twice under different discovery handles.
    ///
    /// Plan §6.5 made `PeerHandle.id` stable for the life of a transport session, so the transport
    /// no longer produces this pair casually — but it still produces it: the identity map is
    /// bounded (a very old endpoint ages out), a `stop()`/`start()` re-mints deliberately, and the
    /// next transport is free to key identity differently. Mirrors `MeshNetworkManagerTests`.
    private func makeReturningDevice(named name: String) -> (first: PeerHandle, again: PeerHandle) {
        let endpoint = PeerEndpointKey(UUID())
        return (makePeer(named: name, endpoint: endpoint), makePeer(named: name, endpoint: endpoint))
    }

    private func makePayload() -> ProximityRecipeSharePayload {
        let createdAt = Date(timeIntervalSince1970: 1_779_664_800)
        let recipe = RecipeDefinition(
            name: "Cap Test Bowl",
            servings: 1,
            ingredients: [],
            notes: "",
            source: "manual",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        return RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])
    }

    /// Registers a connection record through the manager's production add-path (pauses the
    /// radio) and returns its coordinator, driven by the given mock transport.
    @discardableResult
    private func registerConnection(
        on manager: ProximityRecipeShareManager,
        peer: PeerHandle
    ) -> ProximityCoordinator {
        registerConnection(on: manager, peer: peer, transport: MockMultipeerTransport())
    }

    @discardableResult
    private func registerConnection(
        on manager: ProximityRecipeShareManager,
        peer: PeerHandle,
        transport: MockMultipeerTransport
    ) -> ProximityCoordinator {
        manager.makeRetainedConnectionCoordinatorForTesting(
            peer: peer, transport: transport, ranging: MockRangingProvider()
        )
    }

    /// Gives up only when the deadline has passed AND `minimumPolls` observations have actually
    /// been made. See `waitForValue` for why the second half is load-earned.
    private func waitUntil(
        timeout: Duration = .seconds(5),
        minimumPolls: Int = 400,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Polls `value` until `predicate` holds and returns it AS OBSERVED at that moment, giving up
    /// only once the deadline has passed AND `minimumPolls` observations have actually been made.
    ///
    /// Two separate load failures are being closed here, and each needs its own half.
    ///
    /// The LATCH: `sendState` is not a resting place — every terminal state arms
    /// `scheduleStatusClear`, which resets it to `.idle` 2.5 s later. So waiting and then
    /// re-reading the live property has a deadline it must thread between: long enough to survive
    /// starvation, short enough not to race that reset. No value satisfies both. Returning the
    /// observed value removes the upper bound.
    ///
    /// The POLL FLOOR: a `ContinuousClock` deadline measures wall clock, which keeps advancing
    /// while this `@MainActor` suite is starved by every other `@MainActor` suite in a loaded
    /// full-suite run. `connectTimeoutSurfacesBusyPeerFailure` failed exactly that way with a
    /// 10 s deadline — 41.8 s of wall clock, `sendState` still `.connecting`, because the 0.05 s
    /// timer task had not been *scheduled* yet and the poll had genuinely looked only a handful
    /// of times before its clock ran out. Counting observations makes the give-up decision
    /// proportional to scheduling actually received rather than to time elapsed. The pair still
    /// terminates: `polls` only climbs, and every turn of the loop sleeps.
    private func waitForValue<T>(
        timeout: Duration = .seconds(10),
        minimumPolls: Int = 400,
        of value: @escaping @MainActor () -> T,
        until predicate: @escaping @MainActor (T) -> Bool
    ) async -> T {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var latest = value()
        var polls = 1
        while !predicate(latest) {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return latest }
            try? await Task.sleep(for: .milliseconds(5))
            latest = value()
        }
        return latest
    }

    // MARK: - Inbound acceptance gate

    @Test func invitationAcceptedWhenIdle() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)

        #expect(manager.shouldAcceptInvitationForTesting(makePeer(named: "Alex")))
    }

    @Test func invitationRefusedWhileConnectionHeldButSamePeerMayReinvite() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        let paired = makePeer(named: "Alex")
        registerConnection(on: manager, peer: paired)

        #expect(!manager.shouldAcceptInvitationForTesting(makePeer(named: "Blair")))
        // Retry of a dropped attempt from the peer that already holds the pairing stays open.
        #expect(manager.shouldAcceptInvitationForTesting(paired))
    }

    /// The connecting-window race: a second inviter must be refused while a FIRST peer is
    /// invited/accepted but not yet MC-connected (`connections` alone can't see that window).
    @Test func invitationRefusedDuringConnectingWindow() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        let connecting = makePeer(named: "Alex")
        manager.multipeerSessionForTesting.registerPendingConnectionForTesting(connecting)

        #expect(!manager.shouldAcceptInvitationForTesting(makePeer(named: "Blair")))
        // The pending peer itself re-inviting is not "besides" its own window.
        #expect(manager.shouldAcceptInvitationForTesting(connecting))
    }

    // MARK: - Outbound cap

    @Test func sendRefusedVisiblyWhilePairedWithAnotherPeer() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        let paired = makePeer(named: "Alex")
        registerConnection(on: manager, peer: paired)

        let other = ProximityRecipeShareRecipient(id: UUID(), displayName: "Blair", fingerprint: nil)
        manager.sendRecipeShare(makePayload(), to: other)

        guard case .failed(let message) = manager.sendState else {
            Issue.record("Expected visible outbound-cap failure, got \(manager.sendState)")
            return
        }
        #expect(message.contains("two Fernlets"))
        // The refusal must not disturb the live pairing.
        #expect(manager.connectionCountForTesting == 1)
        #expect(manager.engagedRecipientID == paired.id)
    }

    @Test func sendRefusedWhileConnectingWindowBusyWithAnotherPeer() throws {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()  // keeps sendRecipeShare's start() from touching radios
        let target = makePeer(named: "Blair")
        manager.multipeerSessionForTesting.onPeerDiscovered?(target)
        manager.multipeerSessionForTesting.registerPendingConnectionForTesting(makePeer(named: "Alex"))
        let recipient = try #require(manager.nearbyRecipients.first)

        manager.sendRecipeShare(makePayload(), to: recipient)

        guard case .failed(let message) = manager.sendState else {
            Issue.record("Expected connecting-window refusal, got \(manager.sendState)")
            return
        }
        #expect(message.contains("two Fernlets"))
    }

    // MARK: - Pause on connect / resume on eviction

    @Test func establishingConnectionPausesDiscovery() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        #expect(!manager.multipeerSessionForTesting.isDiscoveryPaused)

        // Same add-path both roles share (handleChannelReady fires on inviter and invitee).
        registerConnection(on: manager, peer: makePeer(named: "Alex"))

        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)
        #expect(manager.diagnosticEvents.contains { $0.message.contains("closed to others") })
    }

    @Test func peerDisconnectEvictionResumesDiscovery() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        let peer = makePeer(named: "Alex")
        registerConnection(on: manager, peer: peer)
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)

        manager.multipeerSessionForTesting.onPeerDisconnected?(peer, "Peer disconnected")

        #expect(manager.connectionCountForTesting == 0)
        #expect(!manager.multipeerSessionForTesting.isDiscoveryPaused)
        #expect(manager.diagnosticEvents.contains { $0.message.contains("reopened") })
    }

    /// A coordinator that fails/ends WITHOUT an MC disconnect (failed handshakes never fire
    /// one) must still reopen the radio via the stale-coordinator sweep.
    @Test func staleCoordinatorSweepResumesDiscovery() async {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        let peer = makePeer(named: "Alex")
        let transport = MockMultipeerTransport()
        let coordinator = registerConnection(on: manager, peer: peer, transport: transport)
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateDisconnection()
        await waitUntil { if case .ended = coordinator.state { return true }; return false }
        manager.checkCoordinatorStatesForTesting()

        #expect(manager.connectionCountForTesting == 0)
        #expect(!manager.multipeerSessionForTesting.isDiscoveryPaused)
        #expect(manager.diagnosticEvents.contains { $0.message.contains("reopened") })
    }

    /// The removal path the .ended/.failed sweep misses: a coordinator parked in a
    /// pre-verification state (here .discovering — where the friend-mode auto-reconnect path
    /// also lands after a dead transport). It must be evicted after the parked timeout, and
    /// the eviction must reopen the radio.
    @Test func parkedDiscoveringCoordinatorIsSweptAndResumesDiscovery() async {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        let peer = makePeer(named: "Alex")
        let coordinator = registerConnection(on: manager, peer: peer)

        await coordinator.begin(role: .browser, mode: .friend)
        #expect(coordinator.state == .discovering)

        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        manager.sweepParkedConnections(now: t0)
        // First sighting only marks the record — no eviction before the timeout.
        #expect(manager.connectionCountForTesting == 1)
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)

        manager.sweepParkedConnections(now: t0.addingTimeInterval(31))

        #expect(manager.connectionCountForTesting == 0)
        #expect(!manager.multipeerSessionForTesting.isDiscoveryPaused)
        #expect(manager.diagnosticEvents.contains { $0.message.contains("stalled connection") })
        #expect(manager.diagnosticEvents.contains { $0.message.contains("reopened") })
    }

    /// A coordinator that progressed past verification must never be counted as parked.
    @Test func parkedSweepIgnoresProgressingCoordinators() async {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        let peer = makePeer(named: "Alex")
        let transport = MockMultipeerTransport()
        let coordinator = registerConnection(on: manager, peer: peer, transport: transport)

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil { if case .awaitingIdentityIntroduction = coordinator.state { return true }; return false }

        let t0 = Date(timeIntervalSince1970: 1_780_000_000)
        manager.sweepParkedConnections(now: t0)
        manager.sweepParkedConnections(now: t0.addingTimeInterval(600))

        #expect(manager.connectionCountForTesting == 1)
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)
    }

    // MARK: - Cap-aware refresh

    @Test func refreshDiscoveryIsNoOpWhilePaired() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        registerConnection(on: manager, peer: makePeer(named: "Alex"))

        manager.refreshDiscovery()

        // The pairing (and the paused radio) survive; the refusal is user-visible.
        #expect(manager.connectionCountForTesting == 1)
        #expect(manager.multipeerSessionForTesting.isDiscoveryPaused)
        guard case .failed(let message) = manager.sendState else {
            Issue.record("Expected visible cap-aware refresh status, got \(manager.sendState)")
            return
        }
        #expect(message.contains("two Fernlets"))
    }

    // MARK: - Connect timeout

    @Test func connectTimeoutSurfacesBusyPeerFailure() async throws {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        manager.connectTimeoutSeconds = 0.05
        let target = makePeer(named: "Blair")
        manager.multipeerSessionForTesting.onPeerDiscovered?(target)
        let recipient = try #require(manager.nearbyRecipients.first)

        manager.sendRecipeShare(makePayload(), to: recipient)
        #expect(manager.sendState == .connecting(recipientName: "Blair"))
        #expect(manager.engagedRecipientID == recipient.id)

        let observed = await waitForValue(of: { manager.sendState }) {
            if case .failed = $0 { return true }; return false
        }

        guard case .failed(let message) = observed else {
            Issue.record("Expected connect-timeout failure, got \(observed)")
            return
        }
        #expect(message.contains("busy"))
        #expect(manager.engagedRecipientID == nil)
    }

    /// The connect timeout covers ONLY the pre-connect stage: the moment the connection record
    /// exists (handleChannelReady → registerConnection) it is cancelled — from there the
    /// coordinator's own 25 s handshake budget governs, and the shorter timer firing would
    /// best-effort kick a pairing that is still progressing.
    @Test func connectTimeoutIsCancelledOnceTheConnectionRecordExists() async throws {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        manager.connectTimeoutSeconds = 0.05
        let target = makePeer(named: "Blair")
        manager.multipeerSessionForTesting.onPeerDiscovered?(target)
        let recipient = try #require(manager.nearbyRecipients.first)

        manager.sendRecipeShare(makePayload(), to: recipient)
        #expect(manager.sendState == .connecting(recipientName: "Blair"))

        // MC connect succeeds for the engaged recipient (the same add-path handleChannelReady
        // uses) — the pre-connect stage is over.
        registerConnection(on: manager, peer: target)

        try? await Task.sleep(for: .milliseconds(200))
        #expect(manager.sendState == .connecting(recipientName: "Blair"),
                "Past connect, the coordinator's handshake budget owns failure — the pre-connect timer must not fire")
        #expect(manager.connectionCountForTesting == 1, "…and must not kick the progressing pairing")
    }

    // MARK: - Transport-error recovery

    /// A failed discovery (re)start (advertiser/browser didNotStart — e.g. the Bonjour restart
    /// after a record eviction's resumeDiscovery) must stop the manager outright: with
    /// `isRunning` left true, ContentView's idempotent start() no-ops forever and passive
    /// listening stays dark until app relaunch.
    @Test func transportErrorWhileListeningStopsTheManagerSoTheNextGateEventRestartsIt() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        #expect(manager.isRunningForTesting)

        manager.multipeerSessionForTesting.onTransportError?("Could not start browsing for nearby Fernlets.")

        #expect(!manager.isRunningForTesting, "stop() must run so the next gate event genuinely restarts discovery")
        #expect(manager.diagnosticEvents.contains { $0.message.contains("retry on the next app event") })
    }

    /// The recovery path must never tear down a live pairing (didNotStart* only fires from start
    /// attempts, and resume runs only with no connection held — but the guard is load-bearing).
    @Test func transportErrorNeverTearsDownALivePairing() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        registerConnection(on: manager, peer: makePeer(named: "Alex"))

        manager.multipeerSessionForTesting.onTransportError?("Advertiser failed.")

        #expect(manager.isRunningForTesting)
        #expect(manager.connectionCountForTesting == 1)
    }

    // MARK: - Wire-boundary coercion of peer text (M7 / M15)

    /// An inbound envelope shell — the receive path takes post-verification envelopes, so a
    /// dummy signature is fine here.
    private func recipeEnvelope(senderDisplayName: String, plaintext: Data) -> FernletIdentityEnvelope {
        FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: Data(),
            senderKeyAgreementPublicKey: Data(),
            senderDisplayName: senderDisplayName,
            recipientFingerprint: nil,
            payloadType: .recipeShare,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Recipe"),
            payload: plaintext,
            createdAt: Date(),
            expiresAt: nil,
            signature: Data()
        )
    }

    private func deliverShare(
        _ payload: ProximityRecipeSharePayload,
        senderDisplayName: String,
        to manager: ProximityRecipeShareManager
    ) {
        let plaintext = try! JSONEncoder().encode(payload)
        manager.proximityCoordinator(
            throwawayRecipeCoordinator(),
            didReceive: recipeEnvelope(senderDisplayName: senderDisplayName, plaintext: plaintext),
            plaintext: plaintext,
            from: nil)
    }

    private func throwawayRecipeCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "test.recipe.wire.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0)
    }

    /// M7: a decoded recipe plaintext is size-gated BEFORE `JSONDecoder`. The image cap alone only
    /// applies after a multi-megabyte body has already been decoded.
    @Test func oversizedRecipePlaintextIsDroppedBeforeDecode() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        let oversized = Data(count: ProximityRecipeSharePayload.maxWireBytes + 1)

        manager.proximityCoordinator(
            throwawayRecipeCoordinator(),
            didReceive: recipeEnvelope(senderDisplayName: "Loud", plaintext: oversized),
            plaintext: oversized,
            from: nil)

        #expect(manager.pendingRecipeShares.isEmpty, "An oversized share must never reach the pending queue")
        #expect(manager.diagnosticEvents.contains { $0.message.contains("oversized recipe share") },
                "The drop must be named, not silent")
    }

    /// M15: the peer-supplied sender name is rendered in the review sheet and every diagnostic,
    /// so it is coerced once at ingest.
    @Test func receivedShareSenderNameIsSanitized() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)

        deliverShare(makePayload(), senderDisplayName: "Ma\u{200B}ya", to: manager)

        #expect(manager.pendingRecipeShares.first?.senderDisplayName == "Maya")
        #expect(!manager.diagnosticEvents.contains { $0.message.unicodeScalars.contains { $0.value == 0x200B } },
                "No zero-width scalar may reach the diagnostics ring either")
    }

    /// The deliberate exception: the per-sender RATE-LIMIT key stays RAW. Sanitizing it would
    /// collapse distinct unfingerprinted senders whose names differ only by a zero-width character
    /// into one bucket, which is the opposite of what the limiter is for.
    @Test func rateLimitKeyStaysRawSoLookalikeSendersAreNotCollapsed() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)

        deliverShare(makePayload(), senderDisplayName: "Maya", to: manager)
        deliverShare(makePayload(), senderDisplayName: "Ma\u{200B}ya", to: manager)

        #expect(manager.pendingRecipeShares.count == 2,
                "Two distinct raw sender keys must not share one rate-limit bucket")
    }

    // MARK: - Saved-arm wire bounds (M16 / M8 / M11)

    /// An honest saved (web-imported) share, at values a real page produces.
    private func honestSavedPayload() -> SharedSavedRecipePayload {
        SharedSavedRecipePayload(
            name: "Sheet-pan salmon",
            sourceURLString: "https://example.com/recipes/salmon",
            ingredients: ["1 salmon fillet", "2 tbsp olive oil"],
            summary: "Roast at 200C for 15 minutes.",
            servings: 2,
            protein: 34,
            carbs: 6,
            fat: 18,
            micronutrients: Micronutrients(fiber: 2, sodium: 380),
            steps: [RecipeStep(text: "Heat the oven."), RecipeStep(text: "Roast the salmon.")]
        )
    }

    /// Encodes an honest saved share, then pokes hostile values into the WIRE JSON — the encoder
    /// cannot produce these shapes, which is exactly why the bounds live in `init(from:)`.
    private func savedShareWire(_ overrides: [String: Any]) throws -> Data {
        let payload = ProximityRecipeSharePayload(
            recipe: ProximitySharedRecipe(kind: .saved, saved: honestSavedPayload()))
        let encoded = try JSONEncoder().encode(payload)
        var root = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
        var recipe = (root["recipe"] as? [String: Any]) ?? [:]
        var saved = (recipe["saved"] as? [String: Any]) ?? [:]
        for (key, value) in overrides { saved[key] = value }
        recipe["saved"] = saved
        root["recipe"] = recipe
        return try JSONSerialization.data(withJSONObject: root)
    }

    private func decodeSavedShare(_ overrides: [String: Any]) throws -> ProximityRecipeSharePayload {
        try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: savedShareWire(overrides))
    }

    /// M16: the saved arm had NO bounded decode at all — name, source URL, summary, ingredient lines
    /// and step text rode in unbounded and straight into the synced snapshot.
    @Test func savedRecipeDecodeRejectsOversizedFields() throws {
        let cases: [[String: Any]] = [
            ["name": String(repeating: "x", count: SharedRecipeLimits.maxNameCharacters + 1)],
            ["ingredients": ["ok", String(repeating: "x", count: SharedRecipeLimits.maxIngredientLineCharacters + 1)]],
            ["ingredients": Array(repeating: "line", count: SharedRecipeLimits.maxIngredients + 1)],
            ["summary": String(repeating: "x", count: SharedRecipeLimits.maxSummaryCharacters + 1)],
            ["sourceURLString": "https://example.com/" + String(repeating: "x", count: SharedRecipeLimits.maxSourceURLCharacters)],
            ["steps": [["text": String(repeating: "x", count: SharedRecipeLimits.maxStepTextCharacters + 1)]]],
            ["steps": Array(repeating: ["text": "stir"], count: SharedRecipeLimits.maxSavedSteps + 1)]
        ]
        for override in cases {
            #expect(throws: RecipeImportError.invalidPayload) {
                _ = try decodeSavedShare(override)
            }
        }
    }

    /// M8's saved arm: `Macros.calories` multiplies and adds these, so `Int.max` traps on the first
    /// render of the imported recipe.
    @Test func savedRecipeDecodeRejectsOutOfRangeMacros() throws {
        for override in [["protein": Int.max], ["carbs": SharedRecipeLimits.maxMacroGrams + 1], ["fat": -1]] {
            #expect(throws: RecipeImportError.invalidPayload) {
                _ = try decodeSavedShare(override)
            }
        }
        // Exactly at the cap must SUCCEED — the bound is inclusive, honest shares are unaffected.
        let atCap = try decodeSavedShare(["protein": SharedRecipeLimits.maxMacroGrams])
        #expect(atCap.recipe.saved?.protein == SharedRecipeLimits.maxMacroGrams)
    }

    /// M11's mesh half: an implausible micronutrient is dropped to "not measured" at the wire.
    @Test func savedRecipeDecodeSanitizesMicronutrients() throws {
        let decoded = try decodeSavedShare(["micronutrients": ["sodium": 1e300, "fiber": 12.0, "iron": -3.0]])
        let micros = try #require(decoded.recipe.saved?.micronutrients)
        #expect(micros.sodium == nil)
        #expect(micros.iron == nil)
        #expect(micros.fiber == 12)
    }

    /// THE COMPAT TEST: the saved arm's step cap is 200 (`maxSavedSteps`), not `maxSteps` (60),
    /// because this app's own web importer keeps up to `RecipeWebImporter.maxImportedSteps` steps.
    /// A 60-cap here would silently refuse a recipe Fernlet itself imported and shared.
    @Test func savedRecipeDecodeAcceptsAWebImportedRecipeAtItsCaps() throws {
        let decoded = try decodeSavedShare([
            "name": String(repeating: "n", count: SharedRecipeLimits.maxNameCharacters),
            "ingredients": Array(repeating: String(repeating: "i", count: SharedRecipeLimits.maxIngredientLineCharacters),
                                 count: SharedRecipeLimits.maxIngredients),
            "steps": Array(repeating: ["text": "stir"], count: SharedRecipeLimits.maxSavedSteps)
        ])
        #expect(decoded.recipe.saved?.steps?.count == SharedRecipeLimits.maxSavedSteps)
        #expect(decoded.recipe.saved?.ingredients.count == SharedRecipeLimits.maxIngredients)
        #expect(SharedRecipeLimits.maxSavedSteps == RecipeWebImporter.maxImportedSteps,
                "The wire's saved-step cap must track what the web importer can produce")
        #expect(RecipeWebImporter.maxImportedNameCharacters <= SharedRecipeLimits.maxNameCharacters,
                "Fernlet must never import a name its own wire decoder would refuse")
    }

    /// Wire compatibility: `steps` stays the ONE optional key. An older peer sends no steps at all.
    @Test func olderPeerPayloadWithoutStepsStillDecodes() throws {
        let payload = ProximityRecipeSharePayload(
            recipe: ProximitySharedRecipe(kind: .saved, saved: honestSavedPayload()))
        let encoded = try JSONEncoder().encode(payload)
        var root = (try JSONSerialization.jsonObject(with: encoded) as? [String: Any]) ?? [:]
        var recipe = (root["recipe"] as? [String: Any]) ?? [:]
        var saved = (recipe["saved"] as? [String: Any]) ?? [:]
        saved.removeValue(forKey: "steps")
        recipe["saved"] = saved
        root["recipe"] = recipe

        let decoded = try JSONDecoder().decode(
            ProximityRecipeSharePayload.self,
            from: try JSONSerialization.data(withJSONObject: root))

        #expect(decoded.recipe.saved?.steps == nil)
        #expect(decoded.recipe.saved?.name == "Sheet-pan salmon")
    }

    /// The send side must never emit a share the new decoder refuses.
    @Test func savedRecipeWireRoundTripsThroughTheRealSendPath() throws {
        let recipe = RecipeDefinition(
            name: "Saved bowl",
            servings: 3,
            ingredients: [],
            notes: "A saved web recipe summary.",
            source: MealLogSource.webImport,
            createdAt: Date(timeIntervalSince1970: 1_779_664_800),
            updatedAt: Date(timeIntervalSince1970: 1_779_664_800),
            webImport: RecipeWebImport(
                sourceURLString: "https://example.com/saved-bowl",
                ingredientLines: ["Oats", "Greek yogurt"],
                macros: Macros(protein: 24, carbs: 42, fat: 6),
                micronutrients: Micronutrients(fiber: 6)
            ),
            steps: [RecipeStep(text: "Follow the linked recipe.")]
        )
        let payload = RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])
        let encoded = try JSONEncoder().encode(payload)

        let decoded = try JSONDecoder().decode(ProximityRecipeSharePayload.self, from: encoded)

        #expect(decoded.recipe.saved?.name == "Saved bowl")
        #expect(decoded.recipe.saved?.protein == 24)
        #expect(decoded.recipe.saved?.steps?.count == 1)
    }

    /// M8: the review sheet renders BEFORE the store's clamps and can be handed an in-process
    /// payload (tests, the send-side preview), so its macro sum must be total on its own.
    @Test func reviewSheetMacroSumSurvivesHostileIngredients() {
        let hostile = [
            SharedRecipeIngredient(name: "a", quantity: 1, unit: "g", protein: .max, carbs: .max, fat: .max),
            SharedRecipeIngredient(name: "b", quantity: 1, unit: "g", protein: .max, carbs: .max, fat: .max)
        ]

        let protein = ProximityRecipeShareReviewSheet.boundedMacroSum(hostile, \.protein)

        #expect(protein == 2 * SharedRecipeLimits.maxMacroGrams)
        #expect(ProximityRecipeShareReviewSheet.boundedMacro(.min) == 0)
        #expect(ProximityRecipeShareReviewSheet.boundedMacro(42) == 42)
    }

    // MARK: - Belt-and-braces third-peer admission

    @Test func thirdPeerChannelIsNotAdmittedWhilePaired() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        let paired = makePeer(named: "Alex")
        registerConnection(on: manager, peer: paired)

        #expect(!manager.shouldAdmitChannel(for: makePeer(named: "Blair")))
        #expect(manager.shouldAdmitChannel(for: paired))
    }

    // MARK: - Identity asymmetry (plan §6.4, recipe-share half)

    /// The ready path must recognize a returning device exactly as the admission path does.
    ///
    /// `shouldAdmitChannel` has always matched by endpoint; the duplicate guard ahead of it
    /// compared `id`. So a paired device whose handle churned (a bounded identity-map eviction, a
    /// transport `stop()`/restart) missed the duplicate guard, was recognized by
    /// `shouldAdmitChannel`, and was admitted a SECOND time — two connection records, two
    /// coordinators and two ranging sessions for one device, on a radio capped at two devices.
    @Test func returningDeviceIsRecognizedAsAlreadyConnected() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        let alex = makeReturningDevice(named: "Alex")
        registerConnection(on: manager, peer: alex.first)

        #expect(manager.channelAdmission(for: alex.again) == .alreadyConnected,
                "a device that already holds the pairing must never be admitted twice")
        #expect(manager.channelAdmission(for: alex.first) == .alreadyConnected,
                "and the same handle it connected under is answered the same way")
    }

    /// The other two arms of the same decision, pinned so the extraction cannot quietly lose them:
    /// a third device is turned away while paired (best-effort kick, existing pairing untouched),
    /// and an idle radio still admits.
    @Test func channelAdmissionTurnsAwayAThirdDeviceAndAdmitsWhenIdle() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)

        #expect(manager.channelAdmission(for: makePeer(named: "Alex")) == .admit,
                "with no pairing held, a channel is admitted")

        registerConnection(on: manager, peer: makePeer(named: "Alex"))
        #expect(manager.channelAdmission(for: makePeer(named: "Blair")) == .turnAway,
                "recipe sharing links two Fernlets at a time — the third is turned away")
    }

    /// The OUTBOUND cap gate must recognize the picked row's device the way the channel gates do.
    ///
    /// The picker row's `id` is the discovery handle's `id`, and the cap gate compared it against
    /// the connection's `id` — also a handle `id`. So a device that connected under a churned
    /// handle refused the user's send to the very device it was paired with, naming that device as
    /// the peer it was "still sharing with". The gate now asks the same same-device question the
    /// invitation and channel-ready gates ask.
    @Test func sendToTheDeviceAlreadyPairedIsNotRefusedByTheOutboundCap() throws {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()  // keeps sendRecipeShare's start() from touching radios
        let alex = makeReturningDevice(named: "Alex")
        // Discovery holds the first handle (so the row is minted from it); the pairing came up
        // under the second.
        manager.multipeerSessionForTesting.onPeerDiscovered?(alex.first)
        let recipient = try #require(manager.nearbyRecipients.first)
        registerConnection(on: manager, peer: alex.again)

        manager.sendRecipeShare(makePayload(), to: recipient)

        if case .failed(let message) = manager.sendState {
            Issue.record("The device we are paired with must not be refused by its own cap: \(message)")
        }
        #expect(manager.connectionCountForTesting == 1,
                "and the live pairing is neither doubled nor dropped")

        // Control: a genuinely different device is still refused while the pairing is held.
        manager.sendRecipeShare(makePayload(), to: ProximityRecipeShareRecipient(
            id: UUID(), displayName: "Blair", fingerprint: nil))
        guard case .failed(let message) = manager.sendState else {
            Issue.record("Expected the outbound cap to refuse a third device, got \(manager.sendState)")
            return
        }
        #expect(message.contains("two Fernlets"))
    }

    /// The sender-side connect timeout must stand down once the pairing exists, however the device
    /// arrived. Its stage check compared the row `id` against connection `id`s, so a device that
    /// answered under a churned handle left the timer live: it failed the send as "no answer" and
    /// best-effort kicked the pairing that was in fact progressing.
    @Test func connectTimeoutStandsDownWhenTheDeviceAnsweredUnderAChurnedHandle() async throws {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        manager.markRunningForTesting()
        manager.connectTimeoutSeconds = 0.05
        let alex = makeReturningDevice(named: "Alex")
        manager.multipeerSessionForTesting.onPeerDiscovered?(alex.first)
        let recipient = try #require(manager.nearbyRecipients.first)

        manager.sendRecipeShare(makePayload(), to: recipient)
        #expect(manager.sendState == .connecting(recipientName: "Alex"))
        // The device answers under its OTHER handle — registerConnection is the production
        // channel-ready add path, which is also what cancels the timer.
        registerConnection(on: manager, peer: alex.again)

        // A fixed wait is the right shape for "this must NOT happen": ten times the timer it is
        // waiting out, on a decision the timer makes the moment it fires.
        try await Task.sleep(for: .seconds(0.5))

        if case .failed(let message) = manager.sendState {
            Issue.record("The connect timeout must not fail a send whose device is connected: \(message)")
        }
        #expect(manager.connectionCountForTesting == 1,
                "and the pairing the timeout would have kicked is untouched")
        #expect(manager.engagedRecipientID == recipient.id,
                "the picked row stays the engaged one — the timeout never cleared the send")
    }
}
