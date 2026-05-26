import Testing
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

    @Test func disclosureCardIncludesTrainerPermissionsAndFingerprint() throws {
        let (remote, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let store = makeTestStore()
        let service = TrainerProximityService(store: store)
        let peer = makePeerIdentity(from: remote)

        let disclosure = service.disclosure(for: peer)

        #expect(disclosure.title == "Accept plan from Coach Alex?")
        #expect(disclosure.fingerprint == remote.localFingerprint)
        #expect(disclosure.canSend.contains("Planned workouts"))
        #expect(disclosure.canSend.contains("Completed workout summaries"))
        #expect(disclosure.canSend.contains("Plan swaps"))
        #expect(disclosure.cannotAccess.contains("Journal"))
        #expect(disclosure.cannotAccess.contains("Period history"))
        #expect(disclosure.cannotAccess.contains("Sleep"))
        #expect(disclosure.cannotAccess.contains("Private notes"))
        #expect(disclosure.cannotAccess.contains("Data before today"))
        #expect(store.trainerAuditEvents.contains { $0.kind == .disclosureShown })
    }

    @Test func acceptingPeerStoresTrustedRecordAndReturningPeerSkipsPreInvite() async throws {
        let (remote, serviceID) = try makeIdentity()
        defer { cleanup(serviceID) }
        let store = makeTestStore()
        let service = TrainerProximityService(store: store)
        let peer = makePeerIdentity(from: remote)

        #expect(service.shouldShowPreInviteDialog(displayName: peer.displayName, fingerprint: peer.fingerprint))
        await service.accept(peer)

        let trusted = store.trustedProximityPeer(fingerprint: remote.localFingerprint)
        #expect(trusted?.displayName == "Coach Alex")
        #expect(trusted?.revokedAt == nil)
        #expect(service.shouldShowPreInviteDialog(displayName: peer.displayName, fingerprint: peer.fingerprint) == false)
        #expect(store.trainerAuditEvents.contains { $0.kind == .peerAccepted })
    }

    @Test func keyChangeWarningAppearsForSameDisplayNameWithDifferentFingerprint() throws {
        let (first, firstID) = try makeIdentity()
        defer { cleanup(firstID) }
        let (second, secondID) = try makeIdentity()
        defer { cleanup(secondID) }
        let store = makeTestStore()
        let service = TrainerProximityService(store: store)

        store.trustProximityPeer(makePeerIdentity(from: first), mode: .trainer)

        let warning = service.keyChangeWarning(displayName: "Coach Alex", fingerprint: second.localFingerprint)
        #expect(warning?.contains("different proximity key") == true)
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
        serviceRevoke(store: store, fingerprint: remote.localFingerprint)
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

    private func serviceRevoke(store: FernletStore, fingerprint: String) {
        TrainerProximityService(store: store).revokeTrainer(fingerprint: fingerprint)
    }
}
