import ProximityKit
import FernletCrypto
import Testing
import FernletFoundation
import Foundation
import MultipeerConnectivity
import Combine
import FernletDomainModel
@testable import Fernlet

@Suite(.serialized) @MainActor
struct ProximityCoordinatorTests {

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.proximity.coordinator.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    private func cleanup(_ id: String) {
        KeychainItem.deleteAll(service: id)
    }

    private func makePeer(name: String = "Peer", fingerprint: String? = nil) -> PeerHandle {
        let info = fingerprint.map { ["fp": $0] }
        return PeerHandle(
            id: UUID(),
            displayHint: name,
            discoveryInfo: info,
            advertisedFingerprint: fingerprint
        )
    }

    private func makeCoordinator(
        identity: IdentityService,
        transport: MockMultipeerTransport? = nil,
        ranging: MockRangingProvider? = nil,
        inspector: (any ProximityInspectorRecording)? = nil,
        foregroundAnchor: (any ProximityForegroundAnchoring)? = nil,
        timeoutSeconds: TimeInterval = 0,
        now: @escaping () -> Date = Date.init
    ) -> ProximityCoordinator {
        let resolvedTransport = transport ?? MockMultipeerTransport()
        let resolvedRanging = ranging ?? MockRangingProvider()
        return ProximityCoordinator(
            identity: identity,
            transport: resolvedTransport,
            ranging: resolvedRanging,
            inspector: inspector,
            replayCache: ReplayCache(),
            foregroundAnchor: foregroundAnchor,
            displayName: "Local Device",
            timeoutSeconds: timeoutSeconds,
            now: now
        )
    }

    private func signedIntroduction(from identity: IdentityService, displayName: String = "Remote Device") throws -> FernletIdentityEnvelope {
        try FernletIdentityEnvelope.signed(
            identityService: identity,
            senderDisplayName: displayName,
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from \(displayName)"),
            payload: Data()
        )
    }

    private func connectCoordinator(
        _ coordinator: ProximityCoordinator,
        transport: MockMultipeerTransport,
        local: IdentityService,
        remote: IdentityService
    ) async throws -> PeerHandle {
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let data = try JSONEncoder().encode(signedIntroduction(from: remote))
        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.confirmPeerIdentity()
        return peer
    }

    /// Bounded spin for the coordinator's fire-and-forget `Task`s (the timeout timer, the
    /// post-handshake transitions). Gives up only once the deadline has passed AND `minimumPolls`
    /// observations have actually been made.
    ///
    /// Both halves are load-earned. A fixed sleep sized to the timer races the moment the timer
    /// task is *scheduled*, which under full-suite load lands long after its nominal fire time.
    /// But a wall-clock deadline alone does not fix that: every proximity suite is `@MainActor`,
    /// and while this one is starved `ContinuousClock` keeps advancing, so a deadline can expire
    /// having genuinely looked only a handful of times (that is how the sibling
    /// `ProximityRecipeShareCapTests.connectTimeoutSurfacesBusyPeerFailure` still failed at
    /// 41.8 s with a 10 s deadline). Counting observations makes the give-up decision
    /// proportional to scheduling actually received. It still terminates: `polls` only climbs,
    /// and every turn of the loop sleeps.
    private func waitUntil(
        timeout: Duration = .seconds(2),
        minimumPolls: Int = 200,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test func beginAsBrowserStartsBrowsing() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)

        await coordinator.begin(role: .browser, mode: .trainer)

        #expect(transport.browsingStarted == true)
        #expect(transport.lastServiceType == MultipeerServiceType.trainer)
        #expect(coordinator.state == .discovering)
    }

    @Test func beginAsAdvertiserStartsAdvertising() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)

        await coordinator.begin(role: .advertiser, mode: .trainer)

        #expect(transport.advertisingStarted == true)
        #expect(transport.lastDiscoveryInfo?["fp"] == identity.localFingerprint)
        #expect(transport.lastDiscoveryInfo?["role"] == "trainer")
        #expect(coordinator.state == .discovering)
    }

    @Test func peerDiscoveryUpdatesState() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)
        await coordinator.begin(role: .browser, mode: .trainer)

        let peer = makePeer(name: "Coach")
        transport.simulateDiscovery(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        switch coordinator.state {
        case .peerInRange(let discovered, .unknown):
            #expect(discovered == peer)
        case .awaitingTapConfirmation(let discovered):
            #expect(discovered == peer)
        default:
            Issue.record("Expected discovered peer state, got \(coordinator.state)")
        }
    }

    @Test func friendConnectedEventAutoStartsIdentityIntroductionFromAwaitingTap() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)
        await coordinator.beginFriendJoin()
        let peer = makePeer(name: "Friend")

        transport.simulateInvite(from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(coordinator.state == .awaitingIdentityIntroduction(peer: peer))
        #expect(transport.sentData.count == 1)

        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state == .awaitingIdentityIntroduction(peer: peer))
        #expect(transport.sentData.count == 1)
        let sentEnvelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: transport.sentData[0].0)
        #expect(sentEnvelope.payloadType == .identityIntroduction)
    }

    @Test func acceptInviteMovesToAwaitingTap() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)
        await coordinator.begin(role: .advertiser, mode: .trainer)

        let peer = makePeer(name: "Client")
        transport.simulateInvite(from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.acceptPendingInvite()

        #expect(coordinator.state == .awaitingTapConfirmation(peer: peer))
        #expect(transport.acceptedInvites.count == 1)
    }

    @Test func rejectInviteReturnsToIdle() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)
        await coordinator.begin(role: .advertiser, mode: .trainer)

        transport.simulateInvite(from: makePeer(name: "Client"))
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.rejectPendingInvite()

        #expect(coordinator.state == .idle)
    }

    /// `tapToConfirm()` remains a manual override during the transient connecting window (a
    /// future tap UI could use it); the dwell-driven pre-identity tap detector retired with the
    /// gate — identity now comes first on every hardware class (see the auto-advance tests).
    @Test func tapToConfirmStillAdvancesTheTransientGate() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)
        let peer = makePeer(name: "Peer")
        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnecting(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(coordinator.state == .awaitingTapConfirmation(peer: peer))

        await coordinator.tapToConfirm()
        #expect(coordinator.state == .awaitingIdentityIntroduction(peer: peer))
    }

    /// Increment 10 (Plan-Prekeys-ProtectedLoad-CoachMesh-2026-07-26): the pre-identity trainer
    /// tap gate could never fire on ANY hardware — the distance stream needs an NI ranging
    /// session, which only starts after the identity exchange the gate itself blocked
    /// (`startRangingIfPossible` runs in `handleIdentityEnvelope`), and `tapToConfirm()` has no
    /// production caller — so every trainer session hung to timeout. The session now
    /// auto-advances to the identity exchange on connect; the human gate is the explicit
    /// post-identity confirmation. (An earlier test here pinned the hang.)
    @Test func nonUWBTrainerAutoAdvancesPastTheTapGate() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider(isHardwareSupported: false)
        let coordinator = makeCoordinator(identity: identity, transport: transport, ranging: ranging)
        let peer = makePeer(name: "Peer")

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state == .awaitingIdentityIntroduction(peer: peer))
        #expect(transport.sentData.count == 1, "the identity introduction went out without a tap")
    }

    /// The auto-advance is hardware-blind (the UWB path had the identical structural hang) and
    /// covers BOTH entry points: the fresh `.connected` entry, and the connecting-then-connected
    /// two-step the real MC session delegate always produces — which is the advertiser/coach-app
    /// side of the handshake, where the tap gate is seated BEFORE the connected event arrives.
    @Test func trainerTapGateAutoAdvancesFromTheAlreadyWaitingEntry() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider() // UWB-capable: the hang was not hardware-specific
        let coordinator = makeCoordinator(identity: identity, transport: transport, ranging: ranging)
        let peer = makePeer(name: "Peer")

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnecting(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(coordinator.state == .awaitingTapConfirmation(peer: peer),
                "precondition: the gate is seated before the connected event")

        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state == .awaitingIdentityIntroduction(peer: peer))
        #expect(transport.sentData.count == 1, "the already-waiting gate advanced on connect")
    }

    @Test func identityIntroductionWithRangingTokenStartsRanging() async throws {
        struct RangingPayload: Encodable {
            let rangingMode: String
            let discoveryToken: Data?
        }

        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider()
        let inspector = ConnectionInspector()
        let coordinator = makeCoordinator(identity: local, transport: transport, ranging: ranging, inspector: inspector)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let payload = try JSONEncoder().encode(RangingPayload(rangingMode: "uwb", discoveryToken: Data([9, 8, 7])))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Remote Device",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from Remote Device"),
            payload: payload
        )

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(ranging.startCalled == true)
        #expect(ranging.lastPeerTokenData == Data([9, 8, 7]))
        #expect(inspector.liveLog?.ranging.mode == .uwb)
        #expect(transport.sentData.contains { sent in
            (try? JSONDecoder().decode(FernletIdentityEnvelope.self, from: sent.0))?.payloadType == .identityAcknowledge
        } == true)
    }

    @Test func unsupportedRangingRecordsRssiFallback() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider(isHardwareSupported: false)
        let inspector = ConnectionInspector()
        let coordinator = makeCoordinator(identity: local, transport: transport, ranging: ranging, inspector: inspector)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let envelope = try signedIntroduction(from: remote)

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(ranging.startCalled == false)
        #expect(inspector.liveLog?.ranging.mode == .rssi)
        #expect(inspector.liveLog?.events.contains { $0.message.contains("rssi estimate unavailable") } == true)
    }

    @Test func friendRangingInvalidationFallsBackToManualCommit() async throws {
        struct RangingPayload: Encodable {
            let rangingMode: String
            let discoveryToken: Data?
        }

        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider()
        let coordinator = makeCoordinator(identity: local, transport: transport, ranging: ranging)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let payload = try JSONEncoder().encode(RangingPayload(rangingMode: "uwb", discoveryToken: Data([9, 8, 7])))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Remote Device",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from Remote Device"),
            payload: payload
        )

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .awaitingProximityCommit(let peerIdentity) = coordinator.state else {
            Issue.record("Expected proximity gate, got \(coordinator.state)")
            return
        }

        ranging.simulateInvalidated(reason: "Nearby Interaction unavailable")
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state == .awaitingManualCommit(peer: peerIdentity))
    }

    @Test func validIdentityIntroductionMovesToUserConfirmation() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let envelope = try signedIntroduction(from: remote)
        let data = try JSONEncoder().encode(envelope)

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .awaitingUserConfirmation(let peerIdentity) = coordinator.state else {
            Issue.record("Expected awaiting user confirmation, got \(coordinator.state)")
            return
        }
        #expect(peerIdentity.fingerprint == remote.localFingerprint)
        #expect(peerIdentity.displayName == "Remote Device")
    }

    @Test func legacyAdvertisedFingerprintNoLongerBindsToCanonicalIntroduction() async throws {
        // Tightened 2026-07-25 (bitchat-adoptions follow-up): an advertised 8-char fingerprint is
        // a grindable 32-bit binding, so the advertised-vs-derived check now requires the full
        // 16 chars. Only pre-2026-06-12 builds advertised short values — a deliberate compat
        // break with builds that predate the mesh redesign anyway.
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)
        let peer = makePeer(name: "Remote", fingerprint: String(remote.localFingerprint.prefix(8)))
        let envelope = try signedIntroduction(from: remote)
        let data = try JSONEncoder().encode(envelope)

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        if case .awaitingUserConfirmation = coordinator.state {
            Issue.record("A legacy 8-char advertised fingerprint must no longer bind to a canonical identity introduction")
        }
    }

    @Test func inspectorRecordsRangingSamplesFromDistanceUpdates() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider()
        let inspector = ConnectionInspector()
        let coordinator = makeCoordinator(identity: local, transport: transport, ranging: ranging, inspector: inspector)
        let peer = makePeer(name: "Remote")

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        ranging.simulateDistance(0.42)
        ranging.simulateDistance(0.36)
        ranging.simulateDistance(0.31)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(inspector.liveLog?.ranging.samples.count == 1)
        #expect(inspector.liveLog?.ranging.samples.first?.meters == 0.31)
        #expect(inspector.liveLog?.ranging.minDistanceMeters == 0.31)
        #expect(inspector.liveLog?.ranging.maxDistanceMeters == 0.31)
    }

    @Test func heartbeatAcknowledgementRecordsAverageRtt() async throws {
        struct DecodedHeartbeat: Decodable {
            let heartbeatID: UUID
        }
        struct AckHeartbeat: Encodable {
            let kind: String
            let heartbeatID: UUID
            let sentAt: Date
            let responseTo: UUID
        }

        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let inspector = ConnectionInspector()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        var currentDate = start
        let coordinator = makeCoordinator(identity: local, transport: transport, inspector: inspector) { currentDate }
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let introData = try JSONEncoder().encode(signedIntroduction(from: remote))

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(introData, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.confirmPeerIdentity()

        await coordinator.heartbeatTick()
        let heartbeatEnvelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: transport.sentData.last!.0)
        let heartbeat = try JSONDecoder().decode(DecodedHeartbeat.self, from: heartbeatEnvelope.payload)
        currentDate = start.addingTimeInterval(0.125)
        let ackPayload = AckHeartbeat(
            kind: "ack",
            heartbeatID: UUID(),
            sentAt: currentDate,
            responseTo: heartbeat.heartbeatID
        )
        let ackData = try JSONEncoder().encode(ackPayload)
        let ackEnvelope = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Remote",
            recipientFingerprint: local.localFingerprint,
            payloadType: .sessionHeartbeat,
            payloadSummary: PayloadSummary(title: "Heartbeat ack"),
            payload: ackData,
            createdAt: currentDate,
            expiresAt: currentDate.addingTimeInterval(30)
        )
        transport.simulateInboundData(try JSONEncoder().encode(ackEnvelope), from: peer)
        await waitUntil {
            inspector.liveLog?.transport.rttSamplesMs.count == 1
        }

        #expect(inspector.liveLog?.transport.rttSamplesMs.count == 1)
        #expect(inspector.liveLog?.transport.averageRttMs == 125)
    }

    @Test func inspectorRecordsVerifiedEnvelopeAndPeerIdentity() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let inspector = ConnectionInspector()
        let coordinator = makeCoordinator(identity: local, transport: transport, inspector: inspector)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let envelope = try signedIntroduction(from: remote)
        let data = try JSONEncoder().encode(envelope)

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(inspector.liveLog?.peer?.displayName == "Remote Device")
        #expect(inspector.liveLog?.peer?.confirmedFingerprint == remote.localFingerprint)
        #expect(inspector.liveLog?.envelopes.contains { record in
            record.envelopeID == envelope.envelopeID &&
            record.direction == .received &&
            record.payloadType == PayloadType.identityIntroduction.rawValue &&
            record.signatureVerified == true
        } == true)
    }

    @Test func tamperedIdentityIntroductionTransitionsToFailed() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        var envelope = try signedIntroduction(from: remote)
        envelope.signature = Data(repeating: 0xFF, count: envelope.signature.count)
        let data = try JSONEncoder().encode(envelope)

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .failed(let reason) = coordinator.state else {
            Issue.record("Expected failed state, got \(coordinator.state)")
            return
        }
        #expect(reason.contains("signatureInvalid"))
    }

    @Test func confirmPeerIdentityMovesToConnected() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let data = try JSONEncoder().encode(signedIntroduction(from: remote))

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.confirmPeerIdentity()

        guard case .connected(let peerIdentity) = coordinator.state else {
            Issue.record("Expected connected state, got \(coordinator.state)")
            return
        }
        #expect(peerIdentity.fingerprint == remote.localFingerprint)
    }

    @Test func transportLossMovesToEndedTransportLost() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: identity, transport: transport)

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateDisconnection()
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(coordinator.state == .ended(reason: .transportLost))
    }

    @Test func cancelMovesToEndedUserCancelled() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider()
        let coordinator = makeCoordinator(identity: identity, transport: transport, ranging: ranging)

        await coordinator.begin(role: .browser, mode: .trainer)
        await coordinator.cancel()

        #expect(coordinator.state == .ended(reason: .userCancelled))
        #expect(transport.disconnectCalled == true)
        #expect(ranging.stopCalled == true)
    }

    @Test func timeoutInDiscoveringMovesToEndedTimeout() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let coordinator = makeCoordinator(identity: identity, timeoutSeconds: 0.01)

        await coordinator.begin(role: .browser, mode: .trainer)
        // Waited on, not slept past: a fixed 30 ms sleep left only a 3x margin over the 10 ms
        // timer, and under full-suite load the timer's Task had not been scheduled yet when the
        // assertion ran.
        await waitUntil(timeout: .seconds(5)) { coordinator.state == .ended(reason: .timeout) }

        #expect(coordinator.state == .ended(reason: .timeout))
    }

    @Test func connectedToTransferringOnSendAndReturnsToConnected() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let introduction = try JSONEncoder().encode(signedIntroduction(from: remote))
        let payload = try FernletIdentityEnvelope.signed(
            identityService: local,
            senderDisplayName: "Local Device",
            payloadType: .inspectorEcho,
            payloadSummary: PayloadSummary(title: "Echo"),
            payload: Data("payload".utf8)
        )

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(introduction, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.confirmPeerIdentity()
        try await coordinator.send(payload)

        #expect(transport.sentData.count >= 2)
        guard case .connected(let connectedPeer) = coordinator.state else {
            Issue.record("Expected connected state, got \(coordinator.state)")
            return
        }
        #expect(connectedPeer.fingerprint == remote.localFingerprint)
    }

    @Test func heartbeatIsDisabledBeforeConnection() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let coordinator = makeCoordinator(identity: identity)

        await coordinator.begin(role: .browser, mode: .trainer)

        #expect(coordinator.heartbeatInterval == 0)
    }

    @Test func heartbeatSlowsToIdleIntervalWhenStable() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)

        _ = try await connectCoordinator(coordinator, transport: transport, local: local, remote: remote)

        #expect(coordinator.heartbeatInterval == 30)
    }

    @Test func heartbeatAcceleratesDuringTransferAndUsesCooldownAfterTransfer() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        transport.sendDelayNanoseconds = 80_000_000
        var currentDate = Date()
        let coordinator = makeCoordinator(identity: local, transport: transport) { currentDate }
        let payload = try FernletIdentityEnvelope.signed(
            identityService: local,
            senderDisplayName: "Local Device",
            payloadType: .inspectorEcho,
            payloadSummary: PayloadSummary(title: "Echo"),
            payload: Data("payload".utf8)
        )

        _ = try await connectCoordinator(coordinator, transport: transport, local: local, remote: remote)
        let sendTask = Task { try await coordinator.send(payload) }
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(coordinator.heartbeatInterval == 3)
        try await sendTask.value
        #expect(coordinator.heartbeatInterval == 10)
        currentDate = currentDate.addingTimeInterval(31)
        #expect(coordinator.heartbeatInterval == 30)
    }

    @Test func threeMissedHeartbeatsTriggersTransportLost() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        var currentDate = Date()
        let coordinator = makeCoordinator(identity: local, transport: transport) { currentDate }

        _ = try await connectCoordinator(coordinator, transport: transport, local: local, remote: remote)
        currentDate = currentDate.addingTimeInterval(91)
        await coordinator.heartbeatTick()

        #expect(coordinator.state == .ended(reason: .transportLost))
    }

    @Test func foregroundAnchorStartsWhenConnectedAndStopsWhenCancelled() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let anchor = MockProximityForegroundAnchor()
        let coordinator = makeCoordinator(identity: local, transport: transport, foregroundAnchor: anchor)

        _ = try await connectCoordinator(coordinator, transport: transport, local: local, remote: remote)
        #expect(anchor.startCount == 1)
        #expect(anchor.isActive == true)
        await coordinator.cancel()
        #expect(anchor.stopCount == 1)
        #expect(anchor.isActive == false)
    }

    @Test func replayedEnvelopeTransitionsToFailed() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let replayCache = ReplayCache()
        let coordinator = ProximityCoordinator(
            identity: local,
            transport: transport,
            ranging: MockRangingProvider(),
            replayCache: replayCache,
            displayName: "Local Device",
            timeoutSeconds: 0
        )
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let data = try JSONEncoder().encode(signedIntroduction(from: remote))

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .failed(let reason) = coordinator.state else {
            Issue.record("Expected failed state, got \(coordinator.state)")
            return
        }
        #expect(reason.contains("replayDetected"))
    }

    // MARK: - Phase 1: unknown payload types are parked, never session-fatal

    /// Mints a signed envelope whose payload type only a FUTURE build knows (raw-token fixture).
    private func signedUnknownTypeEnvelope(
        from identity: IdentityService,
        token: String = "fernlet.future.sparkle.v1"
    ) throws -> FernletIdentityEnvelope {
        var env = FernletIdentityEnvelope(
            schemaVersion: FernletIdentityEnvelope.currentSchemaVersion,
            envelopeID: UUID(),
            senderSigningPublicKey: identity.localSigningPublicKey,
            senderKeyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            senderDisplayName: "Future Remote",
            recipientFingerprint: nil,
            payloadTypeToken: token,
            payloadEncryption: .none,
            payloadSummary: PayloadSummary(title: "Future"),
            payload: Data("future payload".utf8),
            createdAt: Date(),
            expiresAt: nil,
            signature: Data()
        )
        env.signature = try identity.sign(canonicalBytes(for: env),
                                          purpose: FernletCryptoPurpose.Signature.identityEnvelopeV2)
        return env
    }

    /// The pre-Phase-1 brick: an unknown payload type threw inside handleInbound's decode and the
    /// catch `fail()`ed the whole session. Now the verified envelope is parked (diagnostic event,
    /// no dispatch) and the session stays connected — and its envelopeID still lands in the replay
    /// cache, so a replay of it is rejected exactly like a known type's.
    @Test func phase1_unknownPayloadTypeIsParkedWithoutFailingSession() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let inspector = ProximityInspectorEventRecorder()
        let coordinator = makeCoordinator(identity: local, transport: transport, inspector: inspector)

        let peer = try await connectCoordinator(coordinator, transport: transport, local: local, remote: remote)
        guard case .connected = coordinator.state else {
            Issue.record("Harness failure: expected connected state, got \(coordinator.state)")
            return
        }

        let unknown = try signedUnknownTypeEnvelope(from: remote)
        let data = try JSONEncoder().encode(unknown)
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .connected = coordinator.state else {
            Issue.record("Unknown payload type must not fail the session, got \(coordinator.state)")
            return
        }
        #expect(inspector.events.contains("parked unknown payload type fernlet.future.sparkle.v1"))

        // Replay protection recorded the parked envelope: the same bytes again are a replay,
        // handled exactly like a replayed known-type envelope.
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        guard case .failed(let reason) = coordinator.state else {
            Issue.record("Expected replay rejection, got \(coordinator.state)")
            return
        }
        #expect(reason.contains("replayDetected"))
    }

    // MARK: - Phase 1: capability advertisement in the identity handshake

    private struct CapableRangingPayload: Codable {
        let rangingMode: String
        let discoveryToken: Data?
        let capabilities: [String]?
    }

    @Test func phase1_identityIntroductionCarriesCapabilitiesOntoPeerIdentity() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let payload = try JSONEncoder().encode(CapableRangingPayload(
            rangingMode: "rssi",
            discoveryToken: nil,
            capabilities: [ProximityCapability.photos.rawValue, ProximityCapability.shop.rawValue]
        ))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Remote Device",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from Remote Device"),
            payload: payload
        )

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .awaitingUserConfirmation(let peerIdentity) = coordinator.state else {
            Issue.record("Expected awaiting user confirmation, got \(coordinator.state)")
            return
        }
        #expect(peerIdentity.capabilities == ["photos", "shop"])
        #expect(peerIdentity.supports(.photos))
        #expect(peerIdentity.supports(.shop))
        #expect(!peerIdentity.supports(.hearts))
        #expect(!peerIdentity.supports(.messages))
    }

    /// An intro without the additive `capabilities` key (a pre-Phase-1 client) decodes to nil and
    /// is treated as a legacy photos-only peer.
    @Test func phase1_legacyIntroductionWithoutCapabilitiesIsPhotosOnly() async throws {
        let (local, localServiceID) = try makeIdentity()
        defer { cleanup(localServiceID) }
        let (remote, remoteServiceID) = try makeIdentity()
        defer { cleanup(remoteServiceID) }
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport)
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let envelope = try signedIntroduction(from: remote)

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .awaitingUserConfirmation(let peerIdentity) = coordinator.state else {
            Issue.record("Expected awaiting user confirmation, got \(coordinator.state)")
            return
        }
        #expect(peerIdentity.capabilities == nil)
        #expect(peerIdentity.supports(.photos))
        #expect(!peerIdentity.supports(.shop))
        #expect(!peerIdentity.supports(.hearts))
    }

    /// The sender side threads its configured capability set into the intro payload.
    @Test func phase1_coordinatorAdvertisesConfiguredCapabilitiesInIntroduction() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let coordinator = ProximityCoordinator(
            identity: identity,
            transport: transport,
            ranging: MockRangingProvider(isHardwareSupported: false),
            replayCache: ReplayCache(),
            displayName: "Local Device",
            capabilities: [ProximityCapability.photos.rawValue],
            timeoutSeconds: 0
        )
        await coordinator.beginFriendJoin()
        transport.simulateInvite(from: makePeer(name: "Friend"))
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(transport.sentData.count == 1)
        let sentEnvelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: transport.sentData[0].0)
        #expect(sentEnvelope.payloadType == .identityIntroduction)
        let payload = try JSONDecoder().decode(CapableRangingPayload.self, from: sentEnvelope.payload)
        #expect(payload.capabilities == ["photos"])
    }

    @Test func coordinatorEmitsConnectionInspectorEvents() async throws {
        let (identity, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let transport = MockMultipeerTransport()
        let inspector = ProximityInspectorEventRecorder()
        let coordinator = makeCoordinator(identity: identity, transport: transport, inspector: inspector)

        await coordinator.begin(role: .advertiser, mode: .trainer)
        transport.simulateInvite(from: makePeer(name: "Client"))
        try await Task.sleep(nanoseconds: 10_000_000)

        #expect(inspector.events.contains("state: starting"))
        #expect(inspector.events.contains("state: discovering"))
        #expect(inspector.events.contains("state: pendingInvite"))
    }

    // MARK: - Peer display names are bounded, but never before verification (M15)

    /// M15: `senderDisplayName` is unbounded attacker-chosen wire text that reaches the trainer
    /// audit list (500 CloudKit-synced rows) and every `PeerIdentity`. It is coerced on READ.
    ///
    /// The first assertion is the load-bearing one: `verify` recomputes the canonical bytes from
    /// the decoded fields, so sanitizing in `init(from:)` or before `canonicalBytes` would break
    /// the signature for every name that changes under sanitisation. This test fails loudly if
    /// anyone "simplifies" the accessor into the decode path.
    @Test func envelopeSenderNameIsBoundedOnReadWhileTheSignatureStillVerifies() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (remote, remoteID) = try makeIdentity(); defer { cleanup(remoteID) }

        let hugeName = String(repeating: "A", count: 100_000)
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: hugeName,
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: Data())

        // (a) The RAW field is signature-covered and must still verify untouched.
        _ = try envelope.verify(identityService: local, replayCache: ReplayCache())
        #expect(envelope.senderDisplayName.count == 100_000, "The raw field must not be mutated")

        // (b) Every render/persist site reads the bounded accessor.
        #expect(envelope.sanitizedSenderDisplayName.count <= 24)

        // (c) …and the identity the coordinator builds carries the bounded form.
        let transport = MockMultipeerTransport()
        let coordinator = makeCoordinator(identity: local, transport: transport,
                                          ranging: MockRangingProvider(isHardwareSupported: false))
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 20_000_000)

        guard case .awaitingManualCommit(let identity) = coordinator.state else {
            Issue.record("Expected the proximity gate, got \(coordinator.state)")
            return
        }
        #expect(identity.displayName.count <= 24, "PeerIdentity must carry the bounded name")
    }

    // MARK: - Peer heartbeats must not substitute for local consent (H1)

    /// Wire shape of `SessionHeartbeatPayload`, which is file-private to the coordinator. Kept
    /// structurally identical (default `JSONEncoder` date strategy, same keys) so these tests
    /// exercise the real decode path rather than a stub.
    private struct HeartbeatWireBody: Encodable {
        let kind: String
        let heartbeatID: UUID
        let sentAt: Date
        let responseTo: UUID?
    }

    private func signedHeartbeat(
        from identity: IdentityService,
        kind: String = "ack",
        payloadOverride: Data? = nil
    ) throws -> Data {
        let body = HeartbeatWireBody(kind: kind, heartbeatID: UUID(), sentAt: Date(), responseTo: nil)
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: identity,
            senderDisplayName: "Remote Device",
            payloadType: .sessionHeartbeat,
            payloadSummary: PayloadSummary(title: "Heartbeat"),
            payload: payloadOverride ?? (try JSONEncoder().encode(body))
        )
        return try JSONEncoder().encode(envelope)
    }

    /// Drives a friend-mode coordinator to its proximity gate and returns the peer.
    /// `uwbCapable == false` lands in `.awaitingManualCommit`; `true` (peer advertises a UWB
    /// discovery token) lands in `.awaitingProximityCommit`.
    private func friendGate(
        coordinator: ProximityCoordinator,
        transport: MockMultipeerTransport,
        remote: IdentityService,
        uwbCapable: Bool
    ) async throws -> PeerHandle {
        struct RangingPayload: Encodable {
            let rangingMode: String
            let discoveryToken: Data?
        }
        let peer = makePeer(name: "Remote", fingerprint: remote.localFingerprint)
        let payload = try JSONEncoder().encode(RangingPayload(
            rangingMode: uwbCapable ? "uwb" : "rssi",
            discoveryToken: uwbCapable ? Data([1, 2, 3]) : nil))
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Remote Device",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: payload)

        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        transport.simulateInboundData(try JSONEncoder().encode(envelope), from: peer)
        try await Task.sleep(nanoseconds: 20_000_000)
        return peer
    }

    private func isConnected(_ coordinator: ProximityCoordinator) -> Bool {
        if case .connected = coordinator.state { return true }
        return false
    }

    /// A peer's message is not the local user's consent. The manual-commit gate has NO local
    /// proximity evidence at all, so its only exit is the on-screen confirm — an inbound heartbeat
    /// must leave it exactly where it was.
    @Test func peerHeartbeatDoesNotCommitWithoutLocalProximityEvidence() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (remote, remoteID) = try makeIdentity(); defer { cleanup(remoteID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider(isHardwareSupported: false)
        let coordinator = makeCoordinator(identity: local, transport: transport, ranging: ranging)

        let peer = try await friendGate(coordinator: coordinator, transport: transport,
                                        remote: remote, uwbCapable: false)
        guard case .awaitingManualCommit = coordinator.state else {
            Issue.record("precondition: expected .awaitingManualCommit, got \(coordinator.state)")
            return
        }
        let sentAfterAck = transport.sentData.count

        transport.simulateInboundData(try signedHeartbeat(from: remote), from: peer)
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(!isConnected(coordinator),
                "A peer heartbeat must never commit the manual gate — that gate is the user's tap alone")
        guard case .awaitingManualCommit = coordinator.state else {
            Issue.record("Expected to stay at the manual gate, got \(coordinator.state)")
            return
        }
        #expect(transport.sentData.count == sentAfterAck,
                "An `ack` heartbeat with no matching ping emits nothing back")
    }

    /// The asymmetric-UWB robustness path still works — but only once THIS device's own ranging
    /// has seen the peer inside the commit threshold.
    @Test func peerHeartbeatCommitsOnlyAfterLocalCloseSample() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (remote, remoteID) = try makeIdentity(); defer { cleanup(remoteID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider()
        let coordinator = makeCoordinator(identity: local, transport: transport, ranging: ranging)

        let peer = try await friendGate(coordinator: coordinator, transport: transport,
                                        remote: remote, uwbCapable: true)
        guard case .awaitingProximityCommit = coordinator.state else {
            Issue.record("precondition: expected .awaitingProximityCommit, got \(coordinator.state)")
            return
        }

        // Without evidence: dropped.
        transport.simulateInboundData(try signedHeartbeat(from: remote), from: peer)
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(!isConnected(coordinator), "No local close sample yet — the heartbeat must be dropped")

        // One close sample is enough evidence, and is NOT enough for the dwell detector on its own
        // (3 samples / 0.8 s), so the commit below is genuinely the heartbeat's doing.
        ranging.simulateDistance(0.10)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(!isConnected(coordinator), "precondition: one sample must not trip the dwell detector")

        transport.simulateInboundData(try signedHeartbeat(from: remote), from: peer)
        await waitUntil { if case .connected = coordinator.state { return true }; return false }
        #expect(isConnected(coordinator), "A locally evidenced heartbeat still ratifies the commit")
    }

    /// The evidence check runs AFTER the payload decode, so bytes any connected peer can emit
    /// cannot commit anything.
    @Test func undecodableHeartbeatNeverCommits() async throws {
        let (local, localID) = try makeIdentity(); defer { cleanup(localID) }
        let (remote, remoteID) = try makeIdentity(); defer { cleanup(remoteID) }
        let transport = MockMultipeerTransport()
        let ranging = MockRangingProvider()
        let coordinator = makeCoordinator(identity: local, transport: transport, ranging: ranging)

        let peer = try await friendGate(coordinator: coordinator, transport: transport,
                                        remote: remote, uwbCapable: true)
        ranging.simulateDistance(0.10)          // evidence IS present — only the decode fails
        try await Task.sleep(nanoseconds: 20_000_000)

        transport.simulateInboundData(
            try signedHeartbeat(from: remote, payloadOverride: Data("not a heartbeat".utf8)),
            from: peer)
        try await Task.sleep(nanoseconds: 30_000_000)

        #expect(!isConnected(coordinator),
                "An undecodable heartbeat body must never commit, even with local proximity evidence")
    }

}

@MainActor
private final class MockProximityForegroundAnchor: ProximityForegroundAnchoring {
    private(set) var isActive = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var updates: [(Int, Int)] = []

    func start(peerName: String, startedAt: Date) async {
        startCount += 1
        isActive = true
    }

    func update(bytesSent: Int, bytesReceived: Int) async {
        updates.append((bytesSent, bytesReceived))
    }

    func stop() async {
        stopCount += 1
        isActive = false
    }
}
