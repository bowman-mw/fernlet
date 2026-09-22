// MeshReturningMemberReseatTests.swift
// FernletTests
//
// 2026-09-22 — the owner's phone ↔ Simulator report: a pair whose phone was backgrounded long enough
// for iOS to suspend it re-dialed when the phone came back, "nothing looked wrong", and chat sent
// from either side never arrived. The audit stream named the state: the re-dialed slot was never
// committed, so every frame the peer sent was dropped (`mesh.groupKey.droppedUncommittedSlot`).
//
// The cause: every channel — a first meeting and a re-dial alike — parks a verified peer at the
// coordinator's proximity gate until a 15 cm dwell or a tap, and the only controls that answer that
// gate are the Friends tab's pre-session rows, which the session's camera covers. Lane C never saw it
// because `MeshFlowDriver` stood in for the tap on re-dialed slots too. The fix re-seats a peer the
// signed roster already names (`MeshNetworkManager.reseatReturningMembers()`), which is plan §3's
// invariant 5 and §10.3 taken literally: a reconnect of an existing member is a merge.
//
// The claims walled here:
//
//  1. A member of the live mesh re-dialing after a partition is committed WITHOUT the proximity
//     gesture, through the ordinary commit path — so the partition heals. It is asked exactly once,
//     and it keeps the name its first meeting disclosed (Option 1b withholds it on the re-dial).
//  2. Skipping the gesture needs the identity to be the one the TUNNEL proved: a member's identity
//     introduction replayed over another key's tunnel is refused (and audited once); a link whose
//     key is not proven yet is left open, not refused, and judged again (the blind review's HIGH 1).
//     The decision is only an ask, so the SEAT re-checks all three legs — the judged key, the
//     transport's key, still a returning member — and evicts, naming the reason (the re-review's F1).
//  3. A member this device voted out stays out, even though a two-voter removal leaves it on the
//     signed roster (the blind review's HIGH 2).
//  4. A member whose admission lands AFTER its link reached the gate is re-seated when it lands.
//  5. Nothing about a first meeting changes: a stranger, and a member whose departure is on record,
//     still wait at the gate for a person. Only the four participating states re-seat anybody.
//  6. Asking to remove the only other person in a pair ends the session on the PARTNER's phone as
//     well — the signed termination, not the silent teardown that left the partner in a mesh of one.
//  7. A final pair's leaver asks its radio to wait (bounded) for the partner's close — only for
//     committed roster members — BEFORE the radio goes down, and audits how the wait ended; a
//     departure does not wait; a second leave while one is handing off does nothing. The radio
//     watches the tunnel INSTANCE, so its own re-dial under the same key does not read as the partner
//     still open — asserted on the wait's OUTCOME, never on a clock.
//
// Every audit count is read through the mesh suites' one reader, `count(of:where:)` scoped by
// `heldBy(_:)`: the capture is process-global, and a second reader is what the P9 ratchet forbids.
//
// The gate here is always the manual one (`MockRangingProvider(isHardwareSupported: false)`): that is
// the gate the owner's phone sat at, and it has no proximity evidence that could commit it by itself —
// unlike a Simulator pair, whose simulated Nearby Interaction dwell can.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - MeshReturningMemberReseatTests

/// A returning member is re-seated by the product; nobody else is; a pair's ending is told.
@MainActor
@Suite(.serialized)
struct MeshReturningMemberReseatTests {

    let store = makeTestStore()

    /// What a scenario needs: the manager, its recording radio, the member that will re-dial, and
    /// the mesh id.
    private struct Rig {
        let manager: MeshNetworkManager
        let radio: FakeMeshTransportSession
        let member: IdentityService
        /// The rig's other admitted members, in `extraMembers` order.
        let extras: [IdentityService]
        let meshID: UUID
    }

    /// One re-dialed link: its coordinator, the channel it runs on, and the radio's handle for it.
    private struct Redial {
        let coordinator: ProximityCoordinator
        let transport: MockMultipeerTransport
        let peer: PeerHandle
    }

    /// A manager holding a founded mesh with `member` on its signed roster (plus `extraMembers`),
    /// then partitioned by the member's link dropping — the Simulator's state in the owner's run.
    ///
    /// - Parameters:
    ///   - extraMembers: More admitted members, so a cell can build a roster of four.
    ///   - rosterIncludesMember: False seeds a roster WITHOUT the member, for the cell whose member
    ///     is admitted only later.
    ///   - ledgerExtras: Mutates the seeded ledger before it is armed (a departure on record, say).
    private func makeRig(
        extraMembers: Int = 0,
        rosterIncludesMember: Bool = true,
        ledgerExtras: (inout MeshMembershipLedger, IdentityService, UUID) throws -> Void = { _, _, _ in }
    ) throws -> Rig {
        let radio = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: radio)
        let meshID = UUID()
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: meshID)
        let member = try MeshPartitionFixtures.identity("reseat-member")
        let extras = try (0..<extraMembers).map { try MeshPartitionFixtures.identity("reseat-extra\($0)") }
        let local = manager.identityForTesting
        var ledger = try MeshPartitionFixtures.ledger(
            founder: local, others: (rosterIncludesMember ? [member] : []) + extras, meshID: meshID
        )
        try ledgerExtras(&ledger, member, meshID)
        manager.seedMembershipLedgerForTesting(
            meshID: meshID, founderSigningPublicKey: local.localSigningPublicKey, ledger: ledger
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            manager.applySessionEvent(.linksLost)
        }
        #expect(manager.sessionState == .partitioned, "the rig must start partitioned")
        return Rig(manager: manager, radio: radio, member: member, extras: extras, meshID: meshID)
    }

    /// Seats a fresh slot the way a re-dial does and drives its coordinator through `remote`'s
    /// signed identity introduction to the MANUAL proximity gate (no UWB on either side).
    ///
    /// - Parameter provenKey: The key the radio's channel introduction proved for this link: the
    ///   remote's own key by default, another key for a replayed introduction, nil for "not yet".
    private func redialToGate(
        _ rig: Rig, remote: IdentityService, provenKey: Data?? = .none
    ) async throws -> ProximityCoordinator {
        try await redialLinkToGate(rig, remote: remote, provenKey: provenKey).coordinator
    }

    /// ``redialToGate(_:remote:provenKey:)``, keeping the link, for a cell that sends more over it.
    ///
    /// The handle advertises NO fingerprint, exactly as every QUIC-radio handle does
    /// (`NetworkMeshSession`'s `advertisedFingerprint` is always nil): nothing below the coordinator
    /// ties an identity introduction to the link it arrived on, which is why the re-seat must.
    private func redialLinkToGate(
        _ rig: Rig, remote: IdentityService, provenKey: Data?? = .none
    ) async throws -> Redial {
        let transport = MockMultipeerTransport()
        let peer = PeerHandle(
            id: UUID(), displayHint: "Returning", discoveryInfo: ["v": "1"],
            advertisedFingerprint: nil, endpoint: PeerEndpointKey()
        )
        let proven = provenKey ?? remote.localSigningPublicKey
        if let proven { rig.radio.verifiedSigningKeys[peer.endpoint] = proven }
        let coordinator = rig.manager.makeRetainedSlotCoordinatorForTesting(
            peer: peer, transport: transport, ranging: MockRangingProvider(isHardwareSupported: false)
        )
        let introduction = try FernletIdentityEnvelope.signed(
            identityService: remote,
            senderDisplayName: "Returning",
            payloadType: .identityIntroduction,
            payloadSummary: PayloadSummary(title: "Hello"),
            payload: Data()
        )
        await coordinator.begin(role: .browser, mode: .friend)
        transport.simulateConnected(peer: peer)
        await waitUntil {
            if case .awaitingIdentityIntroduction = coordinator.state { return true }
            return false
        }
        transport.simulateInboundData(try JSONEncoder().encode(introduction), from: peer)
        await waitUntil { MeshNetworkManager.gatedPeer(of: coordinator.state) != nil }
        guard case .awaitingManualCommit = coordinator.state else {
            Issue.record("precondition: the re-dial must wait at the manual gate, got \(coordinator.state)")
            return Redial(coordinator: coordinator, transport: transport, peer: peer)
        }
        return Redial(coordinator: coordinator, transport: transport, peer: peer)
    }

    private func isConnected(_ coordinator: ProximityCoordinator) -> Bool {
        if case .connected = coordinator.state { return true }
        return false
    }

    /// Ends a rig's session and drops whatever rotation its removal asked for.
    private func teardown(_ rig: Rig) {
        _ = rig.manager.consumePendingRotationForTesting()
        rig.manager.leaveMesh()
    }

    // MARK: Claim 1 — a returning member is re-seated, once

    @Test func aReturningMemberIsReSeatedWithoutTheProximityGestureAndTheSessionHeals() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let coordinator = try await redialToGate(rig, remote: rig.member)
        #expect(!rig.manager.hasCommittedPeer, "precondition: the re-dialed slot is uncommitted")

        // The observation pass a live loop runs on the coordinator reaching its gate — twice, before
        // the commit can land, which is what the one-ask latch exists for.
        rig.manager.checkCoordinatorStatesForTesting()
        rig.manager.checkCoordinatorStatesForTesting()
        #expect(rig.manager.slots.first?.returningMemberReseat == .commitRequested(signingPublicKey: rig.member.localSigningPublicKey))
        #expect(capture.count(of: "mesh.slot.returningMemberCommitted", where: heldBy(rig.meshID)) == 1,
                "asked exactly once, however many passes run before the commit lands")

        await waitUntil { isConnected(coordinator) }
        #expect(isConnected(coordinator), "the coordinator committed with no dwell and no tap")
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            // The commit's own state change drives the seat, exactly like a dwell's.
            rig.manager.checkCoordinatorStatesForTesting()
        }
        #expect(rig.manager.hasCommittedPeer, "the slot is seated, so the peer's frames are admitted")
        #expect(rig.manager.slots.first?.fingerprint == rig.member.localFingerprint)
        #expect(rig.manager.sessionState == .activeForeground,
                "`.peerCommitted` healed the partition through the one merge path")
    }

    /// Option 1b meets the re-seat: the re-dial's introduction carries no name, so the commit
    /// arrives name-withheld — and it must not overwrite the name the first meeting disclosed, or a
    /// link that drops again before the disclosure repeats leaves the keep prompt showing a
    /// fingerprint for a friend.
    @Test func aReSeatedMemberKeepsTheNameItsFirstMeetingDisclosed() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }
        rig.manager.recordSessionParticipant(
            displayName: "Bea", fingerprint: rig.member.localFingerprint,
            signingPublicKey: rig.member.localSigningPublicKey,
            keyAgreementPublicKey: rig.member.localKeyAgreementPublicKey
        )
        let coordinator = try await redialToGate(rig, remote: rig.member)
        #expect(MeshNetworkManager.gatedPeer(of: coordinator.state)?.isDisplayNameWithheld == true,
                "precondition: the re-dial's identity is name-withheld, whatever the peer sent")

        rig.manager.checkCoordinatorStatesForTesting()
        await waitUntil { isConnected(coordinator) }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.checkCoordinatorStatesForTesting()
        }
        #expect(rig.manager.slots.first?.fingerprint == rig.member.localFingerprint,
                "precondition: the re-seat's commit landed")
        let names = rig.manager.sessionRoster.filter { $0.fingerprint == rig.member.localFingerprint }
            .map(\.displayName)
        #expect(names == ["Bea"], "the first meeting's name survives the name-withheld re-commit")
    }

    // MARK: Claim 2 — the identity must be the one the tunnel proved

    /// The blind review's HIGH 1. A device M that was sent the member's identity introduction (as a
    /// provisional stranger on the member's own radio, say) replays it over M's OWN tunnel: the
    /// signature is the member's and verifies, but the radio's channel introduction proved M's key.
    @Test func aMemberIdentityReplayedOverAnotherKeysTunnelIsRefusedAndAuditedOnce() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let replayer = try MeshPartitionFixtures.identity("reseat-replayer")
        let coordinator = try await redialToGate(
            rig, remote: rig.member, provenKey: .some(replayer.localSigningPublicKey)
        )

        rig.manager.checkCoordinatorStatesForTesting()
        rig.manager.checkCoordinatorStatesForTesting()

        #expect(rig.manager.slots.first?.returningMemberReseat == .refusedMismatchedKey)
        #expect(capture.count(of: "mesh.slot.returningMemberRefusedMismatchedKey", where: heldBy(rig.meshID)) == 1,
                "refused out loud, and once for the life of the slot")
        #expect(capture.count(of: "mesh.slot.returningMemberCommitted", where: heldBy(rig.meshID)) == 0)
        #expect(MeshNetworkManager.gatedPeer(of: coordinator.state) != nil,
                "a borrowed identity is left at the gate, where only a person could let it through")
        #expect(!rig.manager.hasCommittedPeer)
    }

    /// The re-review's F1. The re-seat's decision is an ASK, and the coordinator commits whatever
    /// identity it holds when a commit lands; it also accepts a second identity introduction in any
    /// state and re-gates to it. So member M, whose key the tunnel proved, can replay member V's
    /// introduction on its own link after the re-seat judged M — and a commit landing after that
    /// re-gate (the queued ask, or a dwell) commits V. The seat must refuse it and evict the link,
    /// never seat M's link as V.
    ///
    /// Driven in a fixed order rather than raced: the ask lands (M), the replay re-gates the
    /// coordinator to V, a commit lands (V), then the seat runs. Whichever order the production race
    /// takes, it converges on exactly this state — a coordinator committed as V on a slot the re-seat
    /// asked to commit as M.
    @Test func anIdentitySwappedInAfterTheJudgementIsEvictedAtTheSeatNotSeated() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig(extraMembers: 1)
        defer { teardown(rig) }
        let victim = try #require(rig.extras.first, "precondition: a second member to impersonate")
        let link = try await redialLinkToGate(rig, remote: rig.member)

        rig.manager.checkCoordinatorStatesForTesting()
        #expect(rig.manager.slots.first?.returningMemberReseat
                    == .commitRequested(signingPublicKey: rig.member.localSigningPublicKey),
                "precondition: the re-seat judged M, whose key the tunnel proved, and asked")
        await waitUntil { isConnected(link.coordinator) }

        let replayed = try FernletIdentityEnvelope.signed(
            identityService: victim, senderDisplayName: "Replayed",
            payloadType: .identityIntroduction, payloadSummary: PayloadSummary(title: "Hello"), payload: Data()
        )
        link.transport.simulateInboundData(try JSONEncoder().encode(replayed), from: link.peer)
        await waitUntil {
            MeshNetworkManager.gatedPeer(of: link.coordinator.state)?.signingPublicKey == victim.localSigningPublicKey
        }
        #expect(MeshNetworkManager.gatedPeer(of: link.coordinator.state)?.fingerprint == victim.localFingerprint,
                "precondition: the replay re-gated M's link to V")
        await link.coordinator.commitManualProximity()
        #expect(isConnected(link.coordinator), "precondition: a commit landed on the swapped identity")

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.checkCoordinatorStatesForTesting()
        }
        #expect(!rig.manager.slots.contains { $0.fingerprint == victim.localFingerprint },
                "M's link is never seated as V")
        #expect(rig.manager.slots.isEmpty, "the link is evicted, not left half-seated")
        #expect(!rig.manager.hasCommittedPeer)
        #expect(capture.count(of: "mesh.slot.returningMemberRefusedAtSeat", where: heldBy(rig.meshID)) == 1,
                "refused out loud")
        #expect(seatRefusalReasons(capture, rig) == ["identityChanged"], "and the log says it was a swap")
        #expect(rig.manager.sessionState == .partitioned, "no heal was raised for a seat that never happened")
    }

    /// The seat re-checks the TRANSPORT's key as well as the coordinator's (the verify of
    /// 2026-09-22): a link whose proven key moves between the ask and the seat — its endpoint key
    /// now held by another peer's tunnel — is evicted, never seated on the strength of the old proof.
    @Test func aLinkWhoseProvenKeyMovesBeforeTheSeatIsEvicted() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let link = try await redialLinkToGate(rig, remote: rig.member)
        rig.manager.checkCoordinatorStatesForTesting()
        #expect(rig.manager.slots.first?.returningMemberReseat
                    == .commitRequested(signingPublicKey: rig.member.localSigningPublicKey),
                "precondition: the re-seat judged and asked")

        rig.radio.verifiedSigningKeys[link.peer.endpoint] = Data(repeating: 0x42, count: 32)
        await waitUntil { isConnected(link.coordinator) }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.checkCoordinatorStatesForTesting()
        }
        #expect(rig.manager.slots.isEmpty, "evicted at the seat")
        #expect(!rig.manager.hasCommittedPeer)
        #expect(seatRefusalReasons(capture, rig) == ["transportKeyChanged"])
    }

    /// …and re-checks that the peer is STILL a returning member: a commit that lands after the
    /// session stopped re-seating anybody (here, this device started leaving) is evicted. The same
    /// leg refuses a seat whose admission record rolled back because it could not be sealed (F2).
    @Test func aCommitThatLandsAfterTheSessionStoppedReSeatingIsEvicted() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let link = try await redialLinkToGate(rig, remote: rig.member)
        rig.manager.checkCoordinatorStatesForTesting()
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.applySessionEvent(.terminationRequested(.finalPairTermination))
        }
        #expect(rig.manager.sessionState == .handingOff, "precondition: this device is leaving")

        await waitUntil { isConnected(link.coordinator) }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.checkCoordinatorStatesForTesting()
        }
        #expect(rig.manager.slots.isEmpty, "evicted at the seat")
        #expect(!rig.manager.hasCommittedPeer)
        #expect(seatRefusalReasons(capture, rig) == ["notAReturningMember"])
    }

    /// The `reason` of every seat refusal this rig's mesh logged, in order.
    private func seatRefusalReasons(_ capture: MeshRoutedBackpressureAuditCapture, _ rig: Rig) -> [String?] {
        capture.records(withEventPrefix: "mesh.slot.returningMemberRefusedAtSeat")
            .filter { heldBy(rig.meshID)($0.context) }
            .map { $0.context["reason"] }
    }

    @Test func aLinkWithNoProvenKeyYetIsLeftOpenAndReSeatedOnceItIsProven() async throws {
        let rig = try makeRig()
        defer { teardown(rig) }
        let coordinator = try await redialToGate(rig, remote: rig.member, provenKey: .some(nil))

        rig.manager.checkCoordinatorStatesForTesting()
        #expect(rig.manager.slots.first?.returningMemberReseat == .open,
                "cannot tell is not mismatched: nothing is refused for good")
        #expect(MeshNetworkManager.gatedPeer(of: coordinator.state) != nil)

        let endpoint = try #require(rig.manager.slots.first?.peer.endpoint)
        rig.radio.verifiedSigningKeys[endpoint] = rig.member.localSigningPublicKey
        rig.manager.checkCoordinatorStatesForTesting()
        #expect(rig.manager.slots.first?.returningMemberReseat == .commitRequested(signingPublicKey: rig.member.localSigningPublicKey))
        await waitUntil { isConnected(coordinator) }
        #expect(isConnected(coordinator))
    }

    // MARK: Claim 3 — a member voted out here stays out

    /// The blind review's HIGH 2. The two-party vote records its verdict locally; its two-voter
    /// removal record cannot reach a quorum the signed ledger accepts, so the member stays on the
    /// signed roster — and before this guard the re-seat undid the vote the moment it re-dialed.
    @Test func aMemberThisDeviceVotedOutIsNotReSeated() async throws {
        let rig = try makeRig(extraMembers: 2)
        defer { teardown(rig) }
        rig.manager.secondRemoval(MeshRemovalProposalPayload(
            id: UUID(),
            targetFingerprint: rig.member.localFingerprint,
            targetDisplayName: "Voted Out",
            proposerFingerprint: "proposer-fp-00112233",
            proposerDisplayName: "Proposer",
            createdAt: Date(),
            expiresAt: Date().addingTimeInterval(60)
        ))
        #expect(rig.manager.membershipVerifier?.roster.contains(fingerprint: rig.member.localFingerprint)
                == true, "precondition: the signed roster still names the voted-out member")
        #expect(!rig.manager.isReturningMember(signingPublicKey: rig.member.localSigningPublicKey))

        let coordinator = try await redialToGate(rig, remote: rig.member)
        rig.manager.checkCoordinatorStatesForTesting()

        #expect(rig.manager.slots.first?.returningMemberReseat == .open)
        #expect(MeshNetworkManager.gatedPeer(of: coordinator.state) != nil, "the vote stands")
    }

    // MARK: Claim 4 — an admission that lands after the gate re-seats

    @Test func aMemberAdmittedWhileItsLinkWaitsIsReSeatedWhenTheAdmissionLands() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig(extraMembers: 1, rosterIncludesMember: false)
        defer { teardown(rig) }
        let coordinator = try await redialToGate(rig, remote: rig.member)
        rig.manager.checkCoordinatorStatesForTesting()
        #expect(rig.manager.slots.first?.returningMemberReseat == .open, "not a member yet")

        // The admission arrives (another member admitted it while this device was away). Nothing a
        // coordinator does changes here, so only the roster's own hook can notice.
        let local = rig.manager.identityForTesting
        rig.manager.seedMembershipLedgerForTesting(
            meshID: rig.meshID, founderSigningPublicKey: local.localSigningPublicKey,
            ledger: try MeshPartitionFixtures.ledger(founder: local, others: [rig.member], meshID: rig.meshID)
        )

        #expect(rig.manager.slots.first?.returningMemberReseat == .commitRequested(signingPublicKey: rig.member.localSigningPublicKey))
        #expect(capture.count(of: "mesh.slot.returningMemberCommitted", where: heldBy(rig.meshID)) == 1)
        await waitUntil { isConnected(coordinator) }
        #expect(isConnected(coordinator))
    }

    // MARK: Claim 5 — a first meeting is unchanged

    @Test func aStrangerAtTheGateStillWaitsForAPerson() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let rig = try makeRig()
        defer { teardown(rig) }
        let stranger = try MeshPartitionFixtures.identity("reseat-stranger")
        #expect(!rig.manager.isReturningMember(signingPublicKey: stranger.localSigningPublicKey))

        let coordinator = try await redialToGate(rig, remote: stranger)
        rig.manager.checkCoordinatorStatesForTesting()

        #expect(rig.manager.slots.first?.returningMemberReseat == .open)
        #expect(capture.count(of: "mesh.slot.returningMemberCommitted", where: heldBy(rig.meshID)) == 0)
        #expect(MeshNetworkManager.gatedPeer(of: coordinator.state) != nil,
                "a first meeting's gate is the consent ceremony, and only a person answers it")
        #expect(!rig.manager.hasCommittedPeer)
    }

    @Test func aMemberWhoseDepartureIsOnRecordIsNotReSeated() async throws {
        let rig = try makeRig { ledger, member, meshID in
            ledger.departures = ledger.departures.inserting(
                try SignedDepartureRecord.signed(meshID: meshID, identity: member, custodyHandoff: .none)
            )
        }
        defer { teardown(rig) }
        #expect(rig.manager.membershipVerifier?.roster.contains(fingerprint: rig.member.localFingerprint)
                == false, "precondition: the departure took the member off the derived roster")
        #expect(!rig.manager.isReturningMember(signingPublicKey: rig.member.localSigningPublicKey))

        let coordinator = try await redialToGate(rig, remote: rig.member)
        rig.manager.checkCoordinatorStatesForTesting()

        #expect(rig.manager.slots.first?.returningMemberReseat == .open)
        #expect(MeshNetworkManager.gatedPeer(of: coordinator.state) != nil,
                "somebody who left is a stranger again, not a returning member")
    }

    @Test func thisDevicesOwnKeyIsNeverAReturningMember() throws {
        let rig = try makeRig()
        defer { teardown(rig) }
        #expect(rig.manager.isReturningMember(signingPublicKey: rig.member.localSigningPublicKey))
        #expect(!rig.manager.isReturningMember(
            signingPublicKey: rig.manager.identityForTesting.localSigningPublicKey
        ))
    }

    @Test func onlyTheFourParticipatingStatesReSeatAReturningMember() {
        let reseating: Set<MeshSessionState> = [
            .joining, .activeForeground, .continuingInBackground, .partitioned
        ]
        for state in MeshSessionState.allCases {
            #expect(MeshNetworkManager.reseatsReturningMembers(in: state) == reseating.contains(state),
                    "\(state.rawValue)")
        }
    }

    @Test func anEndedSessionReSeatsNobody() throws {
        let rig = try makeRig()
        defer { teardown(rig) }
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            rig.manager.applySessionEvent(.terminationVerified)
        }
        #expect(rig.manager.sessionState == .terminated)
        #expect(!rig.manager.isReturningMember(signingPublicKey: rig.member.localSigningPublicKey),
                "a terminated mesh can never be rejoined, by a tap or by this")
    }

    // MARK: Claim 6 — a pair's removal ends the partner's session too

    @Test func askingToRemoveTheOnlyOtherPersonEndsTheSessionOnTheirPhoneToo() async throws {
        let rig = try MeshFoundingRig.build(2, label: "reseat-remove")
        defer { rig.teardown() }
        rig.link(0, 1)
        rig.commit(0, 1)
        try await rig.settle()
        rig.commit(1, 0)
        try await rig.settle(until: { rig.roster(0).count == 2 && rig.roster(1).count == 2 })
        #expect(rig.roster(0).count == 2 && rig.roster(1).count == 2, "precondition: a founded pair")
        let asker = rig.nodes[0].manager
        let partner = rig.nodes[1].manager
        let other = try #require(asker.sessionParticipants.first { !$0.isLocal })

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            asker.proposeRemoval(of: other)
        }
        try await rig.settle(until: { partner.sessionState == .terminated })

        #expect(asker.currentMesh == nil, "the asker's own session ended")
        #expect(partner.sessionState == .terminated,
                "and the partner was told: a mesh of one is over, so it ended there too")
        #expect(partner.currentMesh == nil)
    }

    /// The re-review's F3. The shortcut prunes the roster and then leaves ASYNCHRONOUSLY, so a
    /// re-dial committed inside that window — a re-seat, or a dwell — re-recorded the peer, and the
    /// teardown offered the person the user had just asked to remove on the keep-as-friend prompt.
    @Test func aPeerAskedToBeRemovedStaysOffTheKeepPromptEvenIfItReconnectsDuringTheLeave() async throws {
        let leaver = try makeLeaver(others: 1)
        let partner = try #require(leaver.manager.sessionParticipants.first { !$0.isLocal },
                                   "precondition: a pair, so the shortcut applies")
        func recordPartner() {
            leaver.manager.recordSessionParticipant(
                displayName: "Bea", fingerprint: partner.fingerprint,
                signingPublicKey: Data([1]), keyAgreementPublicKey: Data([2])
            )
        }
        recordPartner()
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            leaver.manager.proposeRemoval(of: partner)
        }
        // The re-dial's commit, landing before the asynchronous leave has run.
        recordPartner()
        #expect(!leaver.manager.sessionRoster.contains { $0.fingerprint == partner.fingerprint },
                "a commit during the leave does not bring them back")

        await waitUntil { leaver.manager.currentMesh == nil }
        #expect(leaver.manager.currentMesh == nil, "precondition: the leave ran")
        #expect(!(leaver.manager.pendingFriendReview?.entries ?? []).contains { $0.fingerprint == partner.fingerprint },
                "and the teardown offers nobody the user asked to remove")
    }

    // MARK: Claim 7 — a final pair's leaver lets the partner read the termination first

    /// A manager in a live, founded mesh whose signed roster is this device plus `others`, with a
    /// committed slot for each of them, over a recording fake radio.
    private func makeLeaver(
        others count: Int, seatsOthers: Bool = true
    ) throws -> (manager: MeshNetworkManager, radio: FakeMeshTransportSession, handles: [PeerHandle], meshID: UUID) {
        let radio = FakeMeshTransportSession()
        let manager = MeshNetworkManager(store: store, transport: radio)
        let meshID = UUID()
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: meshID)
        let others = try (0..<count).map { try MeshPartitionFixtures.identity("grace-\($0)") }
        let local = manager.identityForTesting
        manager.seedMembershipLedgerForTesting(
            meshID: meshID, founderSigningPublicKey: local.localSigningPublicKey,
            ledger: try MeshPartitionFixtures.ledger(founder: local, others: others, meshID: meshID)
        )
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
        }
        let handles = seatsOthers ? others.map {
            MeshP3Acceptance.attachSlot(to: manager, fingerprint: $0.localFingerprint).peer
        } : []
        return (manager, radio, handles, meshID)
    }

    @Test func aFinalPairLeaverWaitsForThePartnersCloseBeforeItsRadioGoesDown() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let leaver = try makeLeaver(others: 1)
        leaver.radio.remoteCloseOutcome = .closed
        // A committed stranger waiting on an admission prompt: it has no mesh to end, so its close
        // would acknowledge nothing, and it must not be waited on.
        MeshP3Acceptance.attachSlot(to: leaver.manager, fingerprint: "stranger-fp-0011223344")
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await leaver.manager.leaveSessionAfterNotifyingPeers()
        }

        #expect(leaver.manager.lastDevelopmentPlan?.ending == .termination,
                "precondition: a roster of two ends in a termination")
        #expect(leaver.radio.remoteCloseWaits.count == 1, "the leaver asked its radio to wait, once")
        let wait = try #require(leaver.radio.remoteCloseWaits.first)
        #expect(wait.peers.count == 1 && wait.peers[0].isSameEndpoint(as: leaver.handles[0]),
                "for the roster partner's close, and nobody else's")
        #expect(wait.seconds == MeshNetworkManager.terminationReceiptGraceSeconds)
        #expect(leaver.radio.stopCountAtRemoteCloseWaits == [0],
                "BEFORE the radio went down — after it there is no link left to close")
        #expect(leaver.radio.stopCount >= 1, "and the radio does go down once the wait is over")
        #expect(leaver.manager.sessionState == .terminated)
        #expect(capture.records(withEventPrefix: "mesh.development.partnerReceipt")
                    .filter { heldBy(leaver.meshID)($0.context) }.map { $0.context["outcome"] } == ["closed"],
                "how the wait ended is a line in the log, not a silence")
    }

    @Test func aDepartureDoesNotWaitBecauseTheMeshGoesOnWithoutThisDevice() async throws {
        let leaver = try makeLeaver(others: 2)
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await leaver.manager.leaveSessionAfterNotifyingPeers()
        }

        #expect(leaver.manager.lastDevelopmentPlan?.ending == .departure,
                "precondition: a roster of three ends in a departure")
        #expect(leaver.radio.remoteCloseWaits.isEmpty,
                "the members a departure is sent to keep their links, so there is no close to wait for")
        #expect(leaver.manager.sessionState == .departed)
    }

    /// The re-review's F4: a termination sent with no committed partner to watch — the partner
    /// already gone, or never re-seated — is a line in the log, not a silence.
    @Test func aTerminationWithNoCommittedPartnerSaysSoRatherThanStayingSilent() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let leaver = try makeLeaver(others: 1, seatsOthers: false)
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await leaver.manager.leaveSessionAfterNotifyingPeers()
        }

        #expect(leaver.manager.lastDevelopmentPlan?.ending == .termination,
                "precondition: a roster of two ends in a termination")
        #expect(leaver.radio.remoteCloseWaits.isEmpty, "no link to wait on, so the radio is not asked")
        let receipts = capture.records(withEventPrefix: "mesh.development.partnerReceipt")
            .filter { heldBy(leaver.meshID)($0.context) }
        #expect(receipts.map { $0.context["outcome"] } == ["nothingToWaitFor"])
        #expect(receipts.map { $0.context["partners"] } == ["0"])
    }

    /// The review's LOW 4: a second tap while the first leave is handing off must not sign a second
    /// record, repeat the transfer or wait again.
    @Test func aSecondLeaveWhileOneIsHandingOffDoesNothing() async throws {
        let capture = MeshRoutedBackpressureAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let leaver = try makeLeaver(others: 1)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            leaver.manager.applySessionEvent(.terminationRequested(.finalPairTermination))
        }
        #expect(leaver.manager.sessionState == .handingOff, "precondition: a leave is in flight")
        let stopsBefore = leaver.radio.stopCount

        await leaver.manager.leaveSessionAfterNotifyingPeers()

        #expect(leaver.manager.lastDevelopmentPlan == nil, "no second plan was derived, so nothing was signed")
        #expect(leaver.radio.remoteCloseWaits.isEmpty, "no second wait")
        #expect(leaver.radio.stopCount == stopsBefore, "no second teardown")
        #expect(leaver.manager.sessionState == .handingOff, "the leave in flight still owns the ending")
        #expect(capture.count(of: "mesh.development.alreadyInFlight", where: heldBy(leaver.meshID)) == 1,
                "the refused second leave is named, not silent")
        _ = leaver.manager.consumePendingRotationForTesting()
        leaver.manager.leaveMesh()
    }

    /// A booked, activated tunnel and the handle the owner would hold for it.
    private func radioWithOneActivatedTunnel(
        _ key: MeshLinkKey
    ) throws -> (radio: NetworkMeshSession, peer: PeerHandle) {
        let radio = NetworkMeshSession()
        let verified = MeshVerifiedPeer(
            signingPublicKey: Data(repeating: 0x5A, count: 32),
            fingerprint: "reseat-grace-peer",
            sessionID: "grace-sid"
        )
        radio.bookTunnelForTesting(key, role: .initiator, verified: verified)
        let peer = try #require(radio.connectedPeers.first, "a booked tunnel carries a handle")
        return (radio, peer)
    }

    /// The Simulator lanes' finding (2026-09-22): when the far end of an OUTBOUND link closes, this
    /// radio's own tick re-dials it under the same key within a second. A wait that asked "is there
    /// a tunnel under this key" read the partner that had already read the termination and closed
    /// as still open, and ran to the bound. The wait watches the tunnel instance instead — asserted
    /// on its outcome, which main-actor starvation cannot move.
    @Test func aReDialUnderTheSameKeyDoesNotKeepTheLeaverWaiting() async throws {
        let key = MeshLinkKey("grace-redial")
        let (radio, peer) = try radioWithOneActivatedTunnel(key)
        let wait = Task { @MainActor in await radio.awaitRemoteClose(of: [peer], within: 2) }
        try await Task.sleep(for: .milliseconds(100))

        // The tunnel that carried the termination ends (through the radio's one removal funnel —
        // `endTunnel` is file-private), then the tick's re-dial books a fresh one under the same key.
        // Booked ACTIVATED on purpose, so it is the instance check that ends the wait and not the
        // activation check beside it.
        radio.disconnectPeer(peer)
        radio.bookTunnelForTesting(key, role: .initiator, verified: MeshVerifiedPeer(
            signingPublicKey: Data(repeating: 0x5A, count: 32),
            fingerprint: "reseat-grace-peer",
            sessionID: "grace-sid-redial"
        ))
        let outcome = await wait.value

        #expect(radio.tunnelKeysForTesting == [key], "precondition: a new tunnel sits under the same key")
        #expect(outcome == .closed, "the tunnel that carried the termination is gone")
    }

    @Test func aLinkThatStaysOpenIsWaitedOnForTheBoundAndNoLonger() async throws {
        let (radio, peer) = try radioWithOneActivatedTunnel(MeshLinkKey("grace-open"))
        let clock = ContinuousClock()
        let started = clock.now
        let outcome = await radio.awaitRemoteClose(of: [peer], within: 0.3)

        #expect(outcome == .boundReached, "a partner that never closes is given the whole grace")
        #expect(clock.now - started >= .milliseconds(250), "the deadline cannot pass early")
    }

    @Test func theRadioReturnsAtOnceWhenItHoldsNoLinkToWaitOn() async {
        let radio = NetworkMeshSession()
        let peer = PeerHandle(
            id: UUID(), displayHint: "Gone", discoveryInfo: nil,
            advertisedFingerprint: nil, endpoint: PeerEndpointKey()
        )
        let outcome = await radio.awaitRemoteClose(of: [peer], within: 30)
        #expect(outcome == .nothingToWaitFor,
                "a peer with no tunnel has nothing to acknowledge, so nothing is waited on")
        #expect(radio.verifiedSigningPublicKey(for: peer) == nil, "and the radio vouches for nobody")
    }

    // MARK: - Waiting

    /// Gives up only once the deadline has passed AND `minimumPolls` observations have been made
    /// (wall-clock alone expires while a `@MainActor` suite is starved in a loaded full-suite run).
    private func waitUntil(
        timeout: Duration = .seconds(2),
        minimumPolls: Int = 400,
        condition: @escaping @MainActor () -> Bool
    ) async {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        var polls = 0
        while !condition() {
            polls += 1
            if polls >= minimumPolls, clock.now >= deadline { return }
            // A cancelled sleep ends the wait; the cell's own expectation then reports the state.
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }
}
