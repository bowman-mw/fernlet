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

    private func makePeer(named name: String) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: nil,
            advertisedFingerprint: nil,
            underlying: MCPeerID(displayName: name)
        )
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
        peer: MultipeerPeer
    ) -> ProximityCoordinator {
        registerConnection(on: manager, peer: peer, transport: MockMultipeerTransport())
    }

    @discardableResult
    private func registerConnection(
        on manager: ProximityRecipeShareManager,
        peer: MultipeerPeer,
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

    // MARK: - Belt-and-braces third-peer admission

    @Test func thirdPeerChannelIsNotAdmittedWhilePaired() {
        let host = RecipeCapTestHost()
        let manager = ProximityRecipeShareManager(store: host)
        let paired = makePeer(named: "Alex")
        registerConnection(on: manager, peer: paired)

        #expect(!manager.shouldAdmitChannel(for: makePeer(named: "Blair")))
        #expect(manager.shouldAdmitChannel(for: paired))
    }
}
