import Testing
import FernletFoundation
import Foundation
import MultipeerConnectivity
@testable import Fernlet

@Suite(.serialized) @MainActor
struct TrainerProximityServiceTests {
    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.trainer.proximity.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    private func cleanup(_ id: String) {
        KeychainItem.deleteAll(service: id)
    }

    private func makePeerIdentity(from identity: IdentityService, name: String = "Coach Alex") -> ProximityCoordinator.PeerIdentity {
        ProximityCoordinator.PeerIdentity(
            id: UUID(),
            displayName: name,
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            fingerprint: identity.localFingerprint,
            rangingMode: .uwb,
            firstSeenAt: Date()
        )
    }

    private func makeMultipeerPeer(name: String, fingerprint: String?) -> MultipeerPeer {
        MultipeerPeer(
            id: UUID(),
            displayName: name,
            discoveryInfo: fingerprint.map { ["fp": $0] },
            advertisedFingerprint: fingerprint,
            underlying: MCPeerID(displayName: name)
        )
    }

    private func signedIntroduction(from identity: IdentityService, displayName: String = "Coach Alex") throws -> FernletIdentityEnvelope {
        try FernletIdentityEnvelope.signed(
            identityService: identity,
            senderDisplayName: displayName,
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello from \(displayName)"),
            payload: Data()
        )
    }

    @Test func revocationBlocksSubsequentEnvelopeAndWritesAudit() async throws {
        let (local, localID) = try makeIdentity()
        defer { cleanup(localID) }
        let (remote, remoteID) = try makeIdentity()
        defer { cleanup(remoteID) }
        let store = makeTestStore()
        let transport = MockMultipeerTransport()
        let coordinator = ProximityCoordinator(
            identity: local,
            transport: transport,
            ranging: MockRangingProvider(),
            trustPolicy: store,
            replayCache: ReplayCache(),
            displayName: "Client",
            timeoutSeconds: 0
        )
        let peerIdentity = makePeerIdentity(from: remote)
        store.trustProximityPeer(peerIdentity, mode: .trainer)
        serviceRevoke(store: store, signingPublicKey: remote.localSigningPublicKey)
        let peer = makeMultipeerPeer(name: "Coach Alex", fingerprint: remote.localFingerprint)
        let data = try JSONEncoder().encode(signedIntroduction(from: remote))

        await coordinator.begin(role: .browser, mode: .trainer)
        transport.simulateConnected(peer: peer)
        try await Task.sleep(nanoseconds: 10_000_000)
        await coordinator.tapToConfirm()
        transport.simulateInboundData(data, from: peer)
        try await Task.sleep(nanoseconds: 10_000_000)

        guard case .failed(let reason) = coordinator.state else {
            Issue.record("Expected revoked key failure, got \(coordinator.state)")
            return
        }
        #expect(reason == "revokedKey")
        #expect(store.trainerAuditEvents.contains { $0.kind == .revokedPeerBlocked && $0.peerFingerprint == remote.localFingerprint })
    }

    @Test func coordinatorStateTransitionsWriteAuditEvents() async throws {
        let (local, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let store = makeTestStore()
        let coordinator = ProximityCoordinator(
            identity: local,
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            trustPolicy: store,
            replayCache: ReplayCache(),
            displayName: "Client",
            timeoutSeconds: 0
        )

        await coordinator.begin(role: .browser, mode: .trainer)

        #expect(store.trainerAuditEvents.contains { $0.kind == .pairingStarted })
        #expect(store.trainerAuditEvents.contains { $0.kind == .stateTransition && $0.message == "starting" })
        #expect(store.trainerAuditEvents.contains { $0.kind == .stateTransition && $0.message == "discovering" })
    }

    private func serviceRevoke(store: FernletStore, signingPublicKey: Data) {
        store.revokeTrustedProximityPeer(signingPublicKey: signingPublicKey)
    }
}
