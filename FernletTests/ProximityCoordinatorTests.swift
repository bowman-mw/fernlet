import ProximityKit
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

    private func makePeer(name: String = "Peer", fingerprint: String? = nil) -> MultipeerPeer {
        let info = fingerprint.map { ["fp": $0] }
        return MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: info,
            advertisedFingerprint: fingerprint,
            underlying: MCPeerID(displayName: name)
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
    ) async throws -> MultipeerPeer {
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

    private func waitUntil(
        timeout: Duration = .seconds(1),
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition(), clock.now < deadline {
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
        try await Task.sleep(nanoseconds: 30_000_000)

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
        env.signature = try identity.sign(canonicalBytes(for: env))
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
