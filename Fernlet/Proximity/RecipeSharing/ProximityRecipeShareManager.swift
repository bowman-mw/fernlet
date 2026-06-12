import Foundation
import Observation
import UIKit

private struct RecipeShareConnection: Identifiable {
    let id: UUID
    let peer: MultipeerPeer
    let channel: PeerChannelTransport
    let coordinator: ProximityCoordinator
    var fingerprint: String?
    var verifiedKeyAgreementPublicKey: Data?
}

struct ProximityRecipeShareDiagnosticEvent: Identifiable, Equatable {
    let id: UUID
    let timestamp: Date
    let message: String

    init(id: UUID = UUID(), timestamp: Date = Date(), message: String) {
        self.id = id
        self.timestamp = timestamp
        self.message = message
    }
}

enum ProximityRecipeShareDiagnostics {
    static let maxEvents = 40

    static func appending(
        _ event: ProximityRecipeShareDiagnosticEvent,
        to events: [ProximityRecipeShareDiagnosticEvent],
        maxCount: Int = maxEvents
    ) -> [ProximityRecipeShareDiagnosticEvent] {
        guard maxCount > 0 else { return [] }
        return Array((events + [event]).suffix(maxCount))
    }
}

@MainActor
@Observable
final class ProximityRecipeShareManager: ProximityPayloadHandling {
    enum SendState: Equatable {
        case idle
        case connecting(recipientName: String)
        case sending(recipientName: String)
        case sent(recipientName: String)
        case failed(message: String)
    }

    private(set) var nearbyRecipients: [ProximityRecipeShareRecipient] = []
    private(set) var sendState: SendState = .idle
    private(set) var diagnosticEvents: [ProximityRecipeShareDiagnosticEvent] = []
    var pendingRecipeShares: [PendingProximityRecipeShare] = []

    @ObservationIgnored private unowned let store: FernletStore
    @ObservationIgnored private let session = MeshMultipeerSession()
    @ObservationIgnored private let identity: IdentityService
    @ObservationIgnored private let replayCache = ReplayCache()
    @ObservationIgnored private var connections: [RecipeShareConnection] = []
    @ObservationIgnored private var discoveredPeers: [UUID: MultipeerPeer] = [:]
    @ObservationIgnored private var observationTask: Task<Void, Never>?
    @ObservationIgnored private var clearStatusTask: Task<Void, Never>?
    @ObservationIgnored private var pendingOutgoing: (payload: ProximityRecipeSharePayload, recipient: ProximityRecipeShareRecipient)?
    @ObservationIgnored private var isRunning = false

    private static let serviceType = "fernlet-recipe"

    init(store: FernletStore) {
        self.store = store
        let id = IdentityService()
        try? id.ensureProvisioned()
        self.identity = id
        setupSession()
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        recordDiagnostic("Recipe share discovery started.")
        session.start(serviceType: Self.serviceType, discoveryInfo: discoveryInfo())
        startObserving()
    }

    func stop() {
        if isRunning {
            recordDiagnostic("Recipe share discovery stopped.")
        }
        isRunning = false
        observationTask?.cancel()
        observationTask = nil
        clearStatusTask?.cancel()
        clearStatusTask = nil
        session.stop()
        nearbyRecipients.removeAll()
        pendingOutgoing = nil
        discoveredPeers.removeAll()
        connections.removeAll()
        sendState = .idle
    }

    func refreshDiscovery() {
        let shouldRestart = isRunning
        recordDiagnostic("Recipe share discovery refreshed.")
        observationTask?.cancel()
        observationTask = nil
        session.stop()
        nearbyRecipients.removeAll()
        pendingOutgoing = nil
        discoveredPeers.removeAll()
        connections.removeAll()
        sendState = .idle
        isRunning = false
        if shouldRestart {
            start()
        }
    }

    func sendRecipeShare(_ payload: ProximityRecipeSharePayload, to recipient: ProximityRecipeShareRecipient) {
        start()
        pendingOutgoing = (payload, recipient)
        sendState = .connecting(recipientName: recipient.displayName)
        recordDiagnostic("Connecting to \(recipient.displayName).")

        if let connection = connections.first(where: { $0.id == recipient.id }),
           connection.verifiedKeyAgreementPublicKey != nil {
            Task { [weak self] in await self?.sendPendingPayload(via: connection) }
            return
        }

        guard let peer = peer(for: recipient) else {
            sendState = .failed(message: "That nearby Fernlet is no longer available.")
            recordDiagnostic("Recipe share failed: \(recipient.displayName) is no longer available.")
            scheduleStatusClear()
            return
        }
        session.invite(peer)
    }

    func dismissRecipeShare(_ share: PendingProximityRecipeShare) {
        pendingRecipeShares.removeAll { $0.id == share.id }
    }

    func dismissRecipeShare(id: UUID) {
        pendingRecipeShares.removeAll { $0.id == id }
    }

    func proximityCoordinator(
        _ coordinator: ProximityCoordinator,
        didReceive envelope: FernletIdentityEnvelope,
        plaintext: Data,
        from peer: ProximityCoordinator.PeerIdentity?
    ) {
        guard envelope.payloadType == .recipeShare,
              let payload = try? JSONDecoder().decode(ProximityRecipeSharePayload.self, from: plaintext),
              payload.format == "fernlet.proximity.recipe",
              payload.version == 1 else { return }

        let pending = PendingProximityRecipeShare(
            senderDisplayName: envelope.senderDisplayName,
            senderFingerprint: peer?.fingerprint,
            receivedAt: Date(),
            payload: payload
        )
        pendingRecipeShares.removeAll { $0.id == pending.id }
        pendingRecipeShares.insert(pending, at: 0)
        recordDiagnostic("Received recipe share from \(envelope.senderDisplayName).")
    }

    private func setupSession() {
        session.onPeerDiscovered = { [weak self] peer in
            self?.handlePeerDiscovered(peer)
        }
        session.onPeerLost = { [weak self] peer in
            self?.handlePeerLost(peer)
        }
        session.onPeerChannelReady = { [weak self] channel in
            self?.handleChannelReady(channel)
        }
        session.onPeerDisconnected = { [weak self] peer, _ in
            self?.handlePeerLost(peer)
            self?.connections.removeAll { $0.peer.id == peer.id }
            self?.recordDiagnostic("\(peer.displayName) disconnected.")
        }
        session.shouldAcceptInvitation = { [weak self] peer in
            guard let self else { return false }
            if let fp = peer.advertisedFingerprint, self.store.isBlockedFingerprint(fp) {
                self.recordDiagnostic("Rejected blocked recipe-share invitation from \(peer.displayName).")
                return false
            }
            return self.connections.count < 1 || self.connections.contains(where: { $0.peer.id == peer.id })
        }
    }

    private func discoveryInfo() -> [String: String] {
        [
            "v": "1",
            "fp": identity.localFingerprint,
            "name": String(displayName.prefix(32)),
            "mode": "recipe"
        ]
    }

    private var displayName: String {
        let name = store.settings.proximityDisplayName.trimmingCharacters(in: .whitespaces)
        return name.isEmpty ? UIDevice.current.name : name
    }

    private func handlePeerDiscovered(_ peer: MultipeerPeer) {
        guard let fingerprint = peer.advertisedFingerprint,
              !fingerprint.isEmpty,
              !IdentityService.fingerprintsMatch(fingerprint, identity.localFingerprint),
              !store.isBlockedFingerprint(fingerprint) else { return }

        discoveredPeers[peer.id] = peer
        let recipient = ProximityRecipeShareRecipient(
            id: peer.id,
            displayName: peer.discoveryInfo?["name"] ?? peer.displayName,
            fingerprint: fingerprint
        )
        nearbyRecipients.removeAll { $0.id == recipient.id || $0.fingerprint == recipient.fingerprint }
        nearbyRecipients.append(recipient)
        nearbyRecipients.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        recordDiagnostic("Discovered \(recipient.displayName).")
    }

    private func handlePeerLost(_ peer: MultipeerPeer) {
        let displayName = nearbyRecipients.first { $0.id == peer.id }?.displayName ?? peer.displayName
        discoveredPeers.removeValue(forKey: peer.id)
        nearbyRecipients.removeAll { $0.id == peer.id }
        recordDiagnostic("\(displayName) is no longer nearby.")
    }

    private func handleChannelReady(_ channel: PeerChannelTransport) {
        guard !connections.contains(where: { $0.peer.id == channel.peer.id }) else { return }
        recordDiagnostic("Secure recipe-share channel opened with \(channel.peer.displayName).")
        let trustPolicy = FriendSessionTrustPolicy(vault: store.proximityTrustVault)
        let coordinator = ProximityCoordinator(
            identity: identity,
            transport: channel,
            ranging: NIRangingSession(),
            payloadHandler: self,
            trustPolicy: trustPolicy,
            replayCache: replayCache,
            displayName: displayName,
            timeoutSeconds: 25
        )
        let connection = RecipeShareConnection(
            id: channel.peer.id,
            peer: channel.peer,
            channel: channel,
            coordinator: coordinator,
            fingerprint: nil,
            verifiedKeyAgreementPublicKey: nil
        )
        connections.append(connection)

        Task { [weak self] in
            await coordinator.begin(role: .browser, mode: .friend)
            channel.notifyConnected()
            self?.checkCoordinatorStates()
        }
    }

    private func startObserving() {
        observationTask?.cancel()
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
                withObservationTracking {
                    _ = self.connections.count
                    for connection in self.connections {
                        _ = connection.coordinator.state
                    }
                } onChange: {
                    continuation.yield(())
                }
                await withTaskCancellationHandler {
                    for await _ in stream { break }
                } onCancel: {
                    continuation.finish()
                }
                continuation.finish()
                guard !Task.isCancelled else { return }
                self.checkCoordinatorStates()
            }
        }
    }

    private func checkCoordinatorStates() {
        for index in connections.indices {
            if case .connected(let peerIdentity) = connections[index].coordinator.state {
                let fingerprint = peerIdentity.fingerprint
                if connections[index].fingerprint != fingerprint {
                    connections[index].fingerprint = fingerprint
                    connections[index].verifiedKeyAgreementPublicKey = peerIdentity.keyAgreementPublicKey
                    ensureRecipient(for: connections[index], identity: peerIdentity)
                    recordDiagnostic("Verified \(peerIdentity.displayName).")
                }
                if pendingOutgoing?.recipient.id == connections[index].id {
                    let connection = connections[index]
                    Task { [weak self] in await self?.sendPendingPayload(via: connection) }
                }
            }
        }

        let stale = connections.filter { connection in
            switch connection.coordinator.state {
            case .ended, .failed: return true
            default: return false
            }
        }
        for connection in stale { connections.removeAll { $0.id == connection.id } }
    }

    private func ensureRecipient(for connection: RecipeShareConnection, identity peerIdentity: ProximityCoordinator.PeerIdentity) {
        let recipient = ProximityRecipeShareRecipient(
            id: connection.id,
            displayName: peerIdentity.displayName,
            fingerprint: peerIdentity.fingerprint
        )
        nearbyRecipients.removeAll { $0.id == recipient.id || $0.fingerprint == recipient.fingerprint }
        nearbyRecipients.append(recipient)
        nearbyRecipients.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func sendPendingPayload(via connection: RecipeShareConnection) async {
        guard let outgoing = pendingOutgoing,
              outgoing.recipient.id == connection.id else { return }
        pendingOutgoing = nil
        sendState = .sending(recipientName: outgoing.recipient.displayName)
        recordDiagnostic("Sending \(outgoing.payload.recipe.title) to \(outgoing.recipient.displayName).")
        do {
            let summary = PayloadSummary(
                title: outgoing.payload.recipe.title,
                subtitle: "Recipe share",
                itemCount: outgoing.payload.recipe.ingredientCount
            )
            let payloadData = try JSONEncoder().encode(outgoing.payload)
            try await connection.coordinator.sendPayload(
                type: .recipeShare,
                summary: summary,
                payload: payloadData,
                sealed: true
            )
            sendState = .sent(recipientName: outgoing.recipient.displayName)
            recordDiagnostic("Sent \(outgoing.payload.recipe.title) to \(outgoing.recipient.displayName).")
        } catch {
            sendState = .failed(message: "Could not send that recipe.")
            recordDiagnostic("Recipe share failed while sending to \(outgoing.recipient.displayName).")
        }
        scheduleStatusClear()
    }

    private func peer(for recipient: ProximityRecipeShareRecipient) -> MultipeerPeer? {
        if let connection = connections.first(where: { $0.id == recipient.id }) {
            return connection.peer
        }
        return discoveredPeers[recipient.id]
            ?? session.channels.values.map(\.peer).first { $0.id == recipient.id }
    }

    private func scheduleStatusClear() {
        clearStatusTask?.cancel()
        clearStatusTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.sendState = .idle
        }
    }

    private func recordDiagnostic(_ message: String) {
        diagnosticEvents = ProximityRecipeShareDiagnostics.appending(
            ProximityRecipeShareDiagnosticEvent(message: message),
            to: diagnosticEvents
        )
    }
}
