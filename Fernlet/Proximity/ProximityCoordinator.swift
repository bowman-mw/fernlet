import Foundation
import Combine
import MultipeerConnectivity
import UIKit

@MainActor
protocol ProximityInspectorRecording: AnyObject {
    func beginSession(role: ProximityCoordinator.Role, mode: ProximityCoordinator.Mode, localFingerprint: String)
    func recordCoordinatorEvent(_ message: String)
    func recordEnvelope(_ record: ConnectionSessionLog.EnvelopeRecord)
    func recordRangingSample(_ sample: ConnectionSessionLog.DistanceSample)
    func updatePeer(_ peer: ConnectionSessionLog.PeerInfo)
    func updateTransport(_ block: (inout ConnectionSessionLog.TransportInfo) -> Void)
    func updateRangingMode(_ mode: ProximityCoordinator.RangingMode)
    func recordError(domain: String, message: String, recoverable: Bool)
    func endSession(endState: String)
}

@MainActor
protocol ProximityPayloadHandling: AnyObject {
    func proximityCoordinator(
        _ coordinator: ProximityCoordinator,
        didReceive envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: ProximityCoordinator.PeerIdentity?
    )
}

extension ProximityInspectorRecording {
    func beginSession(role: ProximityCoordinator.Role, mode: ProximityCoordinator.Mode, localFingerprint: String) {}
    func recordEnvelope(_ record: ConnectionSessionLog.EnvelopeRecord) {}
    func recordRangingSample(_ sample: ConnectionSessionLog.DistanceSample) {}
    func updatePeer(_ peer: ConnectionSessionLog.PeerInfo) {}
    func updateTransport(_ block: (inout ConnectionSessionLog.TransportInfo) -> Void) {}
    func updateRangingMode(_ mode: ProximityCoordinator.RangingMode) {}
    func recordError(domain: String, message: String, recoverable: Bool) {}
    func endSession(endState: String) {}
}

@MainActor
final class ProximityInspectorEventRecorder: ProximityInspectorRecording {
    private(set) var events: [String] = []

    func recordCoordinatorEvent(_ message: String) {
        events.append(message)
    }
}

private struct IdentityRangingPayload: Codable {
    let rangingMode: String
    let discoveryToken: Data?
}

private struct SessionHeartbeatPayload: Codable {
    enum Kind: String, Codable {
        case ping
        case ack
    }

    let kind: Kind
    let heartbeatID: UUID
    let sentAt: Date
    let responseTo: UUID?
}

@MainActor
final class ProximityCoordinator: ObservableObject {
    enum Role: String, Codable, Equatable {
        case advertiser
        case browser
    }

    enum Mode: String, Codable, Equatable {
        case trainer
        case friend
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastKnownDistance: RangingDistance?

    private let identity: IdentityService
    private let transport: any MultipeerTransport
    private let ranging: any RangingProvider
    private weak var inspector: (any ProximityInspectorRecording)?
    private weak var payloadHandler: (any ProximityPayloadHandling)?
    private weak var trustPolicy: (any ProximityTrustPolicy)?
    private let replayCache: ReplayCache
    private let foregroundAnchor: any ProximityForegroundAnchoring
    private let displayName: String
    private let timeoutSeconds: TimeInterval
    private let now: () -> Date

    private var cancellables: Set<AnyCancellable> = []
    private var timeoutTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private let tapDetector = TapConfirmedDetector()
    private var currentRole: Role?
    private var currentMode: Mode?
    private var currentTransportPeer: MultipeerPeer?
    private var pendingInvite: MultipeerSession.PendingInvite?
    private var pendingPeerIdentity: PeerIdentity?
    private var connectedPeerIdentity: PeerIdentity?
    private var rangingMode: RangingMode = .none
    private var lastInboundHeartbeatAt: Date?
    private var lastTransferCompletedAt: Date?
    private var bytesSent = 0
    private var bytesReceived = 0
    private var heartbeatSendFailures = 0
    private var pendingHeartbeatSentAtByID: [UUID: Date] = [:]
    private var autoReconnect = false

    init(
        identity: IdentityService,
        transport: any MultipeerTransport,
        ranging: any RangingProvider,
        inspector: (any ProximityInspectorRecording)? = nil,
        payloadHandler: (any ProximityPayloadHandling)? = nil,
        trustPolicy: (any ProximityTrustPolicy)? = nil,
        replayCache: ReplayCache,
        foregroundAnchor: (any ProximityForegroundAnchoring)? = nil,
        displayName: String = "Fernlet",
        timeoutSeconds: TimeInterval = 30,
        now: @escaping () -> Date = Date.init
    ) {
        self.identity = identity
        self.transport = transport
        self.ranging = ranging
        self.inspector = inspector
        self.payloadHandler = payloadHandler
        self.trustPolicy = trustPolicy
        self.replayCache = replayCache
        if let foregroundAnchor {
            self.foregroundAnchor = foregroundAnchor
        } else {
            #if canImport(ActivityKit)
            self.foregroundAnchor = ActivityKitProximityForegroundAnchor()
            #else
            self.foregroundAnchor = NoopProximityForegroundAnchor()
            #endif
        }
        self.displayName = displayName
        self.timeoutSeconds = timeoutSeconds
        self.now = now
        self.rangingMode = ranging.isHardwareSupported ? .uwb : .rssi
        subscribeToTransport()
        subscribeToRanging()
    }

    deinit {
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
    }

    func attachPayloadHandler(_ payloadHandler: any ProximityPayloadHandling) {
        self.payloadHandler = payloadHandler
    }

    func begin(role: Role, mode: Mode) async {
        await transport.disconnect()
        do {
            try prepareSession(role: role, mode: mode)

            switch role {
            case .advertiser:
                try await transport.startAdvertising(
                    serviceType: serviceType(for: mode),
                    discoveryInfo: discoveryInfo(for: role, mode: mode)
                )
            case .browser:
                try await transport.startBrowsing(serviceType: serviceType(for: mode))
            }
            transition(to: .discovering)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func beginFriendJoin() async {
        await transport.disconnect()
        do {
            try prepareSession(role: .browser, mode: .friend)
            try await transport.startAdvertising(
                serviceType: serviceType(for: .friend),
                discoveryInfo: discoveryInfo(for: .browser, mode: .friend)
            )
            try await transport.startBrowsing(serviceType: serviceType(for: .friend))
            transition(to: .discovering)
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func prepareSession(role: Role, mode: Mode) throws {
        try identity.ensureProvisioned()
        currentRole = role
        currentMode = mode
        inspector?.beginSession(role: role, mode: mode, localFingerprint: identity.localFingerprint)
        trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
            kind: .pairingStarted,
            peerFingerprint: nil,
            peerDisplayName: nil,
            message: "Pairing started as \(role.rawValue) in \(mode.rawValue) mode"
        ))
        currentTransportPeer = nil
        connectedPeerIdentity = nil
        pendingPeerIdentity = nil
        pendingInvite = nil
        lastInboundHeartbeatAt = nil
        lastTransferCompletedAt = nil
        bytesSent = 0
        bytesReceived = 0
        pendingHeartbeatSentAtByID.removeAll()
        tapDetector.reset()
        rangingMode = ranging.isHardwareSupported ? .uwb : .rssi
        transition(to: .starting)
        armTimeoutIfNeeded()
    }

    func acceptPendingInvite() async {
        guard let invite = pendingInvite else {
            fail("No pending invite to accept")
            return
        }

        do {
            try await transport.accept(invite)
            currentTransportPeer = invite.peer
            transition(to: .awaitingTapConfirmation(peer: invite.peer))
            inspector?.recordCoordinatorEvent("invite accepted")
        } catch {
            fail(error.localizedDescription)
        }
    }

    func rejectPendingInvite() async {
        if case .awaitingUserConfirmation = state {
            await end(.userCancelled)
            return
        }

        pendingInvite?.respond(false)
        pendingInvite = nil
        currentTransportPeer = nil
        transition(to: .idle)
        inspector?.recordCoordinatorEvent("invite rejected")
    }

    func tapToConfirm() async {
        guard case .awaitingTapConfirmation(let peer) = state else { return }
        await finishTapConfirmation(for: peer)
    }

    func confirmPeerIdentity() async {
        guard let peer = pendingPeerIdentity else {
            fail("No peer identity awaiting confirmation")
            return
        }
        pendingPeerIdentity = nil
        connectedPeerIdentity = peer
        updateInspectorPeer(identity: peer, transportPeer: currentTransportPeer)
        updateInspectorRangingMode(peer.rangingMode)
        transition(to: .connected(peer: peer))
        timeoutTask?.cancel()
        lastInboundHeartbeatAt = now()
        heartbeatSendFailures = 0
        if currentMode == .friend { autoReconnect = true }
        startHeartbeatLoop()
        await foregroundAnchor.start(peerName: peer.displayName, startedAt: now())
        inspector?.recordCoordinatorEvent("identity confirmed \(peer.fingerprint)")
    }

    func send(_ envelope: FernletIdentityEnvelope) async throws {
        guard let peer = currentTransportPeer, let identity = connectedIdentity else {
            throw CoordinatorError.notConnected
        }

        transition(to: .transferring(peer: identity, progress: 0.0))
        let data = try JSONEncoder().encode(envelope)
        try await transport.send(data, to: peer, mode: .reliable)
        recordEnvelope(envelope, direction: .sent, byteCount: data.count, signatureVerified: true)
        bytesSent += data.count
        await foregroundAnchor.update(bytesSent: bytesSent, bytesReceived: bytesReceived)
        inspector?.recordCoordinatorEvent("envelope sent \(envelope.payloadType.rawValue)")
        trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
            kind: .envelopeSent,
            peerFingerprint: identity.fingerprint,
            peerDisplayName: identity.displayName,
            payloadType: envelope.payloadType,
            message: "Sent \(envelope.payloadType.rawValue)"
        ))
        lastTransferCompletedAt = now()
        transition(to: .connected(peer: identity))
    }

    func sendPayload(type: PayloadType, summary: PayloadSummary, payload: Data) async throws {
        guard let peer = currentTransportPeer else { throw CoordinatorError.notConnected }
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: identity,
            senderDisplayName: displayName,
            recipientFingerprint: peer.advertisedFingerprint,
            payloadType: type,
            payloadSummary: summary,
            payload: payload
        )
        try await send(envelope)
    }

    func cancel() async {
        autoReconnect = false
        await end(.userCancelled)
    }

    private var connectedIdentity: PeerIdentity? {
        switch state {
        case .connected(let peer), .transferring(let peer, _):
            return peer
        default:
            return connectedPeerIdentity
        }
    }

    private func subscribeToTransport() {
        transport.state
            .sink { [weak self] transportState in
                Task { @MainActor [weak self] in
                    await self?.handleTransportState(transportState)
                }
            }
            .store(in: &cancellables)

        transport.inbound
            .sink { [weak self] message in
                Task { @MainActor [weak self] in
                    await self?.handleInbound(message)
                }
            }
            .store(in: &cancellables)
    }

    private func subscribeToRanging() {
        ranging.distance
            .sink { [weak self] distance in
                Task { @MainActor [weak self] in
                    await self?.handleDistance(distance)
                }
            }
            .store(in: &cancellables)

        ranging.state
            .sink { [weak self] rangingState in
                Task { @MainActor [weak self] in
                    self?.handleRangingState(rangingState)
                }
            }
            .store(in: &cancellables)
    }

    private var isSessionLive: Bool {
        switch state {
        case .connected, .transferring, .awaitingIdentityIntroduction, .awaitingUserConfirmation:
            return true
        default:
            return false
        }
    }

    private func handleTransportState(_ transportState: MultipeerSession.State) async {
        switch transportState {
        case .advertising, .browsing:
            if isSessionLive { return }
            transition(to: .discovering)
        case .discovered(let peers):
            if isSessionLive { return }
            guard let peer = peers.first else {
                transition(to: .discovering)
                return
            }
            currentTransportPeer = peer
            updateInspectorPeer(transportPeer: peer)
            transition(to: .peerInRange(peer: peer, distance: .unknown))
            guard currentRole == .browser else { return }
            guard shouldInviteDiscoveredPeer(peer) else { return }
            do {
                try await transport.invite(peer)
                inspector?.recordCoordinatorEvent("invite sent to \(peer.displayName)")
            } catch {
                fail(error.localizedDescription)
            }
        case .awaitingPeerAcceptance(let peer):
            currentTransportPeer = peer
            updateInspectorPeer(transportPeer: peer)
            updateInspectorTransport(state: "connecting")
            transition(to: .awaitingTapConfirmation(peer: peer))
        case .awaitingLocalAcceptance(let invite):
            pendingInvite = invite
            currentTransportPeer = invite.peer
            updateInspectorPeer(transportPeer: invite.peer)
            if currentMode == .friend {
                await acceptPendingInvite()
            } else {
                transition(to: .pendingInvite(invite))
            }
        case .connecting(let peer):
            currentTransportPeer = peer
            updateInspectorPeer(transportPeer: peer)
            updateInspectorTransport(state: "connecting")
            if case .awaitingTapConfirmation = state { return }
            if case .connected = state { return }
            transition(to: .awaitingTapConfirmation(peer: peer))
        case .connected(let peer):
            currentTransportPeer = peer
            updateInspectorPeer(transportPeer: peer)
            updateInspectorTransport(state: "connected")
            if case .connected = state { return }
            if currentMode == .friend {
                if case .awaitingIdentityIntroduction = state { return }
                await finishTapConfirmation(for: peer)
            } else {
                if case .awaitingTapConfirmation = state { return }
                transition(to: .awaitingTapConfirmation(peer: peer))
            }
        case .disconnected:
            updateInspectorTransport(state: "notConnected", disconnected: true)
            await end(.transportLost)
        case .failed(let error):
            updateInspectorTransport(state: "failed", disconnected: true)
            inspector?.recordError(domain: "Multipeer", message: String(describing: error), recoverable: false)
            fail(String(describing: error))
        case .idle:
            break
        }
    }

    private func shouldInviteDiscoveredPeer(_ peer: MultipeerPeer) -> Bool {
        guard currentMode == .friend else { return true }
        guard let remoteFingerprint = peer.advertisedFingerprint else { return true }
        if identity.localFingerprint == remoteFingerprint {
            return displayName < peer.displayName
        }
        return identity.localFingerprint < remoteFingerprint
    }

    private func handleRangingState(_ rangingState: RangingState) {
        switch rangingState {
        case .fallback(let rssiOnly) where rssiOnly:
            rangingMode = .rssi
            updateInspectorRangingMode(.rssi)
            inspector?.recordCoordinatorEvent("ranging fallback: rssi only")
        case .running:
            rangingMode = .uwb
            updateInspectorRangingMode(.uwb)
            inspector?.recordCoordinatorEvent("ranging started: uwb")
        case .invalidated(let reason):
            fail(reason)
        case .idle, .fallback:
            break
        }
    }

    private func handleDistance(_ distance: RangingDistance) async {
        lastKnownDistance = distance
        if case .meters(let meters, let direction) = distance {
            inspector?.recordRangingSample(ConnectionSessionLog.DistanceSample(
                timestamp: now(),
                meters: meters,
                direction: direction
            ))
        }
        guard case .awaitingTapConfirmation(let peer) = state else { return }
        guard ranging.isHardwareSupported, case .meters(let meters, _) = distance else { return }
        if tapDetector.ingest(distanceMeters: meters, at: now()) {
            await finishTapConfirmation(for: peer)
        }
    }

    private func finishTapConfirmation(for peer: MultipeerPeer) async {
        currentTransportPeer = peer
        transition(to: .awaitingIdentityIntroduction(peer: peer))
        inspector?.recordCoordinatorEvent("tap confirmed")
        await sendIdentityIntroduction(to: peer)
    }

    private func sendIdentityIntroduction(to peer: MultipeerPeer) async {
        do {
            let envelope = try FernletIdentityEnvelope.signed(
                identityService: identity,
                senderDisplayName: displayName,
                recipientFingerprint: peer.advertisedFingerprint,
                payloadType: .identityIntroduction,
                payloadSummary: PayloadSummary(title: "Hello from \(displayName)"),
                payload: try await makeIdentityRangingPayload()
            )
            let data = try JSONEncoder().encode(envelope)
            try await transport.send(data, to: peer, mode: .reliable)
            recordEnvelope(envelope, direction: .sent, byteCount: data.count, signatureVerified: true)
            inspector?.recordCoordinatorEvent("identity introduction sent")
        } catch {
            fail(error.localizedDescription)
        }
    }

    private func handleInbound(_ message: MultipeerSession.InboundMessage) async {
        currentTransportPeer = message.peer
        do {
            let envelope = try JSONDecoder().decode(FernletIdentityEnvelope.self, from: message.data)
            if trustPolicy?.isRevokedProximitySigningKey(envelope.senderSigningPublicKey) == true {
                let fingerprint = IdentityService.fingerprint(of: envelope.senderSigningPublicKey)
                trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
                    kind: .revokedPeerBlocked,
                    peerFingerprint: fingerprint,
                    peerDisplayName: envelope.senderDisplayName,
                    payloadType: envelope.payloadType,
                    message: "Blocked envelope from revoked key"
                ))
                fail("revokedKey")
                return
            }
            let plaintext = try envelope.verify(identityService: identity, replayCache: replayCache)
            recordEnvelope(envelope, direction: .received, byteCount: message.bytesReceived, signatureVerified: true)
            bytesReceived += message.bytesReceived
            await foregroundAnchor.update(bytesSent: bytesSent, bytesReceived: bytesReceived)
            inspector?.recordCoordinatorEvent("envelope received \(envelope.payloadType.rawValue)")
            trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
                kind: .envelopeReceived,
                peerFingerprint: IdentityService.fingerprint(of: envelope.senderSigningPublicKey),
                peerDisplayName: envelope.senderDisplayName,
                payloadType: envelope.payloadType,
                message: "Received \(envelope.payloadType.rawValue)"
            ))

            switch envelope.payloadType {
            case .identityIntroduction, .identityAcknowledge:
                try await handleIdentityEnvelope(envelope, plaintext: plaintext, from: message.peer)
            case .sessionHeartbeat:
                await handleHeartbeat(envelope, plaintext: plaintext, from: message.peer)
            default:
                inspector?.recordCoordinatorEvent("envelope verified \(envelope.payloadType.rawValue)")
                payloadHandler?.proximityCoordinator(self, didReceive: envelope, plaintext: plaintext, from: connectedIdentity ?? pendingPeerIdentity)
            }
        } catch {
            trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
                kind: .envelopeRejected,
                peerFingerprint: message.peer.advertisedFingerprint,
                peerDisplayName: message.peer.displayName,
                message: "Envelope verification failed: \(error)"
            ))
            inspector?.recordError(domain: "Envelope", message: String(describing: error), recoverable: false)
            fail("Envelope verification failed: \(error)")
        }
    }

    private func makeIdentityRangingPayload() async throws -> Data {
        let token: Data?
        if ranging.isHardwareSupported {
            token = try? await ranging.myDiscoveryToken()
        } else {
            token = nil
        }
        let payload = IdentityRangingPayload(
            rangingMode: ranging.isHardwareSupported ? RangingMode.uwb.rawValue : RangingMode.rssi.rawValue,
            discoveryToken: token
        )
        return try JSONEncoder().encode(payload)
    }

    private func sendIdentityAcknowledgement(to peer: MultipeerPeer) async {
        do {
            let envelope = try FernletIdentityEnvelope.signed(
                identityService: identity,
                senderDisplayName: displayName,
                recipientFingerprint: peer.advertisedFingerprint,
                payloadType: .identityAcknowledge,
                payloadSummary: PayloadSummary(title: "Identity acknowledged"),
                payload: try await makeIdentityRangingPayload()
            )
            let data = try JSONEncoder().encode(envelope)
            try await transport.send(data, to: peer, mode: .reliable)
            recordEnvelope(envelope, direction: .sent, byteCount: data.count, signatureVerified: true)
            inspector?.recordCoordinatorEvent("identity acknowledge sent")
        } catch {
            inspector?.recordCoordinatorEvent("identity acknowledge failed")
        }
    }

    private func handleHeartbeat(
        _ envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: MultipeerPeer
    ) async {
        lastInboundHeartbeatAt = now()
        inspector?.recordCoordinatorEvent("heartbeat received")

        guard let heartbeat = try? JSONDecoder().decode(SessionHeartbeatPayload.self, from: plaintext) else { return }
        switch heartbeat.kind {
        case .ping:
            await sendHeartbeatAcknowledgement(for: heartbeat.heartbeatID, to: peer)
        case .ack:
            guard let responseTo = heartbeat.responseTo,
                  let sentAt = pendingHeartbeatSentAtByID.removeValue(forKey: responseTo) else { return }
            let rttMs = max(0, now().timeIntervalSince(sentAt) * 1000)
            inspector?.updateTransport { transport in
                transport.rttSamplesMs.append(rttMs)
                transport.rttSamplesMs = Array(transport.rttSamplesMs.suffix(50))
            }
            inspector?.recordCoordinatorEvent(String(format: "heartbeat rtt %.0fms", rttMs))
        }
    }

    private func sendHeartbeatAcknowledgement(for heartbeatID: UUID, to peer: MultipeerPeer) async {
        do {
            let now = now()
            let payload = SessionHeartbeatPayload(
                kind: .ack,
                heartbeatID: UUID(),
                sentAt: now,
                responseTo: heartbeatID
            )
            let envelope = try FernletIdentityEnvelope.signed(
                identityService: identity,
                senderDisplayName: displayName,
                recipientFingerprint: peer.advertisedFingerprint,
                payloadType: .sessionHeartbeat,
                payloadSummary: PayloadSummary(title: "Heartbeat ack"),
                payload: try JSONEncoder().encode(payload),
                createdAt: now,
                expiresAt: now.addingTimeInterval(30)
            )
            let data = try JSONEncoder().encode(envelope)
            try await transport.send(data, to: peer, mode: .unreliable)
            recordEnvelope(envelope, direction: .sent, byteCount: data.count, signatureVerified: true)
            bytesSent += data.count
            await foregroundAnchor.update(bytesSent: bytesSent, bytesReceived: bytesReceived)
            inspector?.recordCoordinatorEvent("heartbeat ack sent")
        } catch {
            inspector?.recordCoordinatorEvent("heartbeat ack failed")
        }
    }

    private func recordEnvelope(
        _ envelope: FernletIdentityEnvelope,
        direction: ConnectionSessionLog.EnvelopeRecord.Direction,
        byteCount: Int,
        signatureVerified: Bool?
    ) {
        let encrypted: Bool
        switch envelope.payloadEncryption {
        case .none:
            encrypted = false
        case .sealedTo:
            encrypted = true
        }
        inspector?.recordEnvelope(ConnectionSessionLog.EnvelopeRecord(
            envelopeID: envelope.envelopeID,
            direction: direction,
            payloadType: envelope.payloadType.rawValue,
            payloadByteCount: byteCount,
            timestamp: now(),
            signatureVerified: signatureVerified,
            encrypted: encrypted,
            summary: envelope.payloadSummary.title
        ))
    }

    private func updateInspectorPeer(identity: PeerIdentity? = nil, transportPeer: MultipeerPeer? = nil) {
        let displayName = identity?.displayName ?? transportPeer?.displayName ?? "Unknown"
        let advertisedFingerprint = transportPeer?.advertisedFingerprint
        let confirmedFingerprint = identity?.fingerprint
        inspector?.updatePeer(ConnectionSessionLog.PeerInfo(
            displayName: displayName,
            advertisedFingerprint: advertisedFingerprint,
            confirmedFingerprint: confirmedFingerprint,
            signingPublicKey: identity?.signingPublicKey,
            firstSeenAt: identity?.firstSeenAt ?? now(),
            lastSeenAt: now()
        ))
    }

    private func updateInspectorTransport(state: String, disconnected: Bool = false) {
        inspector?.updateTransport { transport in
            transport.mcSessionState = state
            if state == "connected", transport.connectedAt == nil {
                transport.connectedAt = now()
            }
            if disconnected {
                transport.disconnectedAt = now()
            }
        }
    }

    private func updateInspectorRangingMode(_ mode: RangingMode) {
        inspector?.updateRangingMode(mode)
    }

    private func handleIdentityEnvelope(_ envelope: FernletIdentityEnvelope, plaintext: Data, from peer: MultipeerPeer) async throws {
        let fingerprint = IdentityService.fingerprint(of: envelope.senderSigningPublicKey)
        if let advertised = peer.advertisedFingerprint, advertised != fingerprint {
            throw CoordinatorError.fingerprintMismatch
        }

        let rangingPayload = try? JSONDecoder().decode(IdentityRangingPayload.self, from: plaintext)
        await startRangingIfPossible(with: rangingPayload, from: peer)

        let peerIdentity = PeerIdentity(
            id: peer.id,
            displayName: envelope.senderDisplayName,
            signingPublicKey: envelope.senderSigningPublicKey,
            keyAgreementPublicKey: envelope.senderKeyAgreementPublicKey,
            fingerprint: fingerprint,
            rangingMode: rangingMode,
            firstSeenAt: now()
        )
        updateInspectorPeer(identity: peerIdentity, transportPeer: peer)

        if envelope.payloadType == .identityAcknowledge {
            if pendingPeerIdentity == nil && connectedPeerIdentity == nil {
                pendingPeerIdentity = peerIdentity
            }
            inspector?.recordCoordinatorEvent("identity acknowledge received \(fingerprint)")
            return
        }

        pendingPeerIdentity = peerIdentity
        await sendIdentityAcknowledgement(to: peer)

        if currentMode == .friend, trustPolicy?.isTrustedProximityPeer(fingerprint: fingerprint) == true {
            inspector?.recordCoordinatorEvent("trusted peer auto-confirmed \(fingerprint)")
            await confirmPeerIdentity()
        } else {
            transition(to: .awaitingUserConfirmation(peer: peerIdentity))
            inspector?.recordCoordinatorEvent("identity verified \(fingerprint)")
        }
    }

    private func startRangingIfPossible(with payload: IdentityRangingPayload?, from peer: MultipeerPeer) async {
        guard ranging.isHardwareSupported else {
            rangingMode = .rssi
            updateInspectorRangingMode(.rssi)
            inspector?.recordCoordinatorEvent("ranging fallback: rssi estimate unavailable")
            return
        }
        guard payload?.rangingMode == RangingMode.uwb.rawValue,
              let discoveryToken = payload?.discoveryToken else {
            rangingMode = .rssi
            updateInspectorRangingMode(.rssi)
            inspector?.recordCoordinatorEvent("ranging fallback: peer token unavailable")
            return
        }

        do {
            try await ranging.start(with: discoveryToken)
            rangingMode = .uwb
            updateInspectorRangingMode(.uwb)
            inspector?.recordCoordinatorEvent("ranging token accepted from \(peer.displayName)")
        } catch {
            rangingMode = .rssi
            updateInspectorRangingMode(.rssi)
            inspector?.recordError(domain: "Ranging", message: error.localizedDescription, recoverable: true)
            inspector?.recordCoordinatorEvent("ranging fallback: \(error.localizedDescription)")
        }
    }

    private func serviceType(for mode: Mode) -> String {
        switch mode {
        case .trainer: return MultipeerSession.defaultServiceType
        case .friend: return "fernlet-friend"
        }
    }

    private func discoveryInfo(for role: Role, mode: Mode) -> [String: String] {
        let advertisedRole: String
        switch mode {
        case .trainer:
            advertisedRole = role == .advertiser ? "trainer" : "client"
        case .friend:
            advertisedRole = "peer"
        }

        return [
            "v": "1",
            "role": advertisedRole,
            "fp": identity.localFingerprint,
            "name": String(displayName.prefix(32)),
            "caps": mode == .trainer ? "plan,live,delta" : "share"
        ]
    }

    private func transition(to newState: State) {
        state = newState
        inspector?.recordCoordinatorEvent("state: \(newState.debugLabel)")
        trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
            kind: .stateTransition,
            peerFingerprint: connectedIdentity?.fingerprint ?? pendingPeerIdentity?.fingerprint ?? currentTransportPeer?.advertisedFingerprint,
            peerDisplayName: connectedIdentity?.displayName ?? pendingPeerIdentity?.displayName ?? currentTransportPeer?.displayName,
            message: newState.debugLabel
        ))
    }

    private func fail(_ reason: String) {
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
        lastKnownDistance = nil
        transition(to: .failed(reason: reason))
        inspector?.recordCoordinatorEvent("failed: \(reason)")
        trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
            kind: .error,
            peerFingerprint: connectedIdentity?.fingerprint ?? pendingPeerIdentity?.fingerprint ?? currentTransportPeer?.advertisedFingerprint,
            peerDisplayName: connectedIdentity?.displayName ?? pendingPeerIdentity?.displayName ?? currentTransportPeer?.displayName,
            message: reason
        ))
        inspector?.endSession(endState: "failed")
        Task { await foregroundAnchor.stop() }
    }

    private func end(_ reason: EndReason) async {
        timeoutTask?.cancel()
        heartbeatTask?.cancel()
        lastKnownDistance = nil
        await ranging.stop()
        await transport.disconnect()
        await foregroundAnchor.stop()

        trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
            kind: .sessionEnded,
            peerFingerprint: connectedIdentity?.fingerprint ?? pendingPeerIdentity?.fingerprint ?? currentTransportPeer?.advertisedFingerprint,
            peerDisplayName: connectedIdentity?.displayName ?? pendingPeerIdentity?.displayName ?? currentTransportPeer?.displayName,
            message: "\(reason)"
        ))

        if autoReconnect && reason == .transportLost {
            inspector?.recordCoordinatorEvent("transport lost, reconnecting")
            inspector?.endSession(endState: "reconnecting")
            transition(to: .discovering)
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await beginFriendJoin()
            return
        }

        transition(to: .ended(reason: reason))
        inspector?.endSession(endState: "ended.\(reason)")
    }

    private func startHeartbeatLoop() {
        heartbeatTask?.cancel()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = await MainActor.run { self?.heartbeatInterval ?? 0 }
                guard interval > 0 else {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    continue
                }
                let nanoseconds = UInt64(interval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanoseconds)
                guard !Task.isCancelled else { return }
                await self?.heartbeatTick()
            }
        }
    }

    var heartbeatInterval: TimeInterval {
        switch state {
        case .idle, .ended, .failed:
            return 0
        case .transferring:
            return 3
        case .connected:
            if let lastTransferCompletedAt,
               now().timeIntervalSince(lastTransferCompletedAt) < 30 {
                return 10
            }
            return 30
        default:
            return 0
        }
    }

    func heartbeatTick() async {
        let interval = heartbeatInterval
        guard interval > 0 else { return }
        if case .connected = state, let lastInboundHeartbeatAt,
           now().timeIntervalSince(lastInboundHeartbeatAt) > interval * 3 {
            await end(.transportLost)
            return
        }
        guard let peer = currentTransportPeer else { return }
        do {
            let sentAt = now()
            let heartbeatID = UUID()
            let payload = SessionHeartbeatPayload(
                kind: .ping,
                heartbeatID: heartbeatID,
                sentAt: sentAt,
                responseTo: nil
            )
            let envelope = try FernletIdentityEnvelope.signed(
                identityService: identity,
                senderDisplayName: displayName,
                recipientFingerprint: peer.advertisedFingerprint,
                payloadType: .sessionHeartbeat,
                payloadSummary: PayloadSummary(title: "Heartbeat"),
                payload: try JSONEncoder().encode(payload),
                createdAt: sentAt,
                expiresAt: sentAt.addingTimeInterval(interval * 2)
            )
            let data = try JSONEncoder().encode(envelope)
            try await transport.send(data, to: peer, mode: .unreliable)
            pendingHeartbeatSentAtByID[heartbeatID] = sentAt
            heartbeatSendFailures = 0
            recordEnvelope(envelope, direction: .sent, byteCount: data.count, signatureVerified: true)
            bytesSent += data.count
            await foregroundAnchor.update(bytesSent: bytesSent, bytesReceived: bytesReceived)
            inspector?.recordCoordinatorEvent("heartbeat sent")
        } catch {
            heartbeatSendFailures += 1
            inspector?.recordCoordinatorEvent("heartbeat send failed (\(heartbeatSendFailures))")
            if heartbeatSendFailures >= 3 {
                await end(.transportLost)
            }
        }
    }

    private func armTimeoutIfNeeded() {
        timeoutTask?.cancel()
        guard timeoutSeconds > 0 else { return }
        let timeoutSeconds = self.timeoutSeconds
        // Task inherits @MainActor from the calling context — no MainActor.run hop needed.
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            switch self.state {
            case .idle, .connected, .transferring, .ended, .failed:
                break
            default:
                self.transition(to: .ended(reason: .timeout))
                self.trustPolicy?.recordTrainerAudit(TrainerAuditEvent(
                    kind: .sessionEnded,
                    peerFingerprint: self.connectedIdentity?.fingerprint ?? self.pendingPeerIdentity?.fingerprint ?? self.currentTransportPeer?.advertisedFingerprint,
                    peerDisplayName: self.connectedIdentity?.displayName ?? self.pendingPeerIdentity?.displayName ?? self.currentTransportPeer?.displayName,
                    message: "timeout"
                ))
                self.inspector?.recordCoordinatorEvent("ended: timeout")
                self.inspector?.endSession(endState: "timeout")
            }
        }
    }
}

extension ProximityCoordinator {
    enum State: Equatable {
        case idle
        case starting
        case discovering
        case peerInRange(peer: MultipeerPeer, distance: RangingDistance)
        case pendingInvite(MultipeerSession.PendingInvite)
        case awaitingTapConfirmation(peer: MultipeerPeer)
        case awaitingIdentityIntroduction(peer: MultipeerPeer)
        case awaitingUserConfirmation(peer: PeerIdentity)
        case connected(peer: PeerIdentity)
        case transferring(peer: PeerIdentity, progress: Double)
        case ended(reason: EndReason)
        case failed(reason: String)

        var debugLabel: String {
            switch self {
            case .idle: return "idle"
            case .starting: return "starting"
            case .discovering: return "discovering"
            case .peerInRange: return "peerInRange"
            case .pendingInvite: return "pendingInvite"
            case .awaitingTapConfirmation: return "awaitingTapConfirmation"
            case .awaitingIdentityIntroduction: return "awaitingIdentityIntroduction"
            case .awaitingUserConfirmation: return "awaitingUserConfirmation"
            case .connected: return "connected"
            case .transferring: return "transferring"
            case .ended(let reason): return "ended(\(reason))"
            case .failed(let reason): return "failed(\(reason))"
            }
        }
    }

    struct PeerIdentity: Equatable, Identifiable {
        let id: UUID
        let displayName: String
        let signingPublicKey: Data
        let keyAgreementPublicKey: Data
        let fingerprint: String
        let rangingMode: RangingMode
        let firstSeenAt: Date
    }

    enum RangingMode: String, Codable, Equatable {
        case uwb
        case rssi
        case none
    }

    enum EndReason: Equatable {
        case userCancelled
        case peerCancelled
        case timeout
        case verificationFailed
        case transportLost
        case completedSuccessfully
    }

    enum CoordinatorError: Error, Equatable {
        case notConnected
        case fingerprintMismatch
    }
}
