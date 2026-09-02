// MeshP3AcceptanceTests.swift
// FernletTests
//
// P3 item 8: **the P3 acceptance battery** (plan §8.4's acceptance list, verbatim).
//
//     Acceptance (P3): unit tests for every state edge; disconnect ≠ removal; idle-lapse resume;
//     ceiling at both bounds; rotation on removal/departure/merge with old-key rejection after
//     grace; context load/deferred/corrupt matrix; legacy `sessionGoodbye` interop.
//
// Items 1–7 each shipped their own unit tests, and those remain the fine-grained evidence: the
// pure state machine's totality (`MeshSessionStateMachineTests`), the epoch model
// (`MeshEpochModelTests`), the five-state sealed store (`MeshSessionStoreTests`), the rotation
// triggers (`MeshRotationTriggerTests`), the wire tokens (`MeshMembershipEventWireTests`) and the
// derived-roster authority (`MeshIntroductionAuthorityTests`).
//
// **This file is deliberately not those tests again.** Each scenario below walks one acceptance
// line across the *integrated* `MeshNetworkManager` — its sealed store, its verifier, its epoch
// keyring, its radio and its state machine at once, on `FakeMeshTransportSession` with every
// instant passed in — because the failure mode a unit test cannot see is the one where each half
// is right and the seam between them is not. Where an existing unit test already IS the evidence
// for a line, the scenario's doc comment names it and adds only what the unit test cannot reach.
//
// Nothing here reads a wall clock for a *decision*: `now` and `monotonicElapsed` are arguments,
// the grace window is measured from an instant the test captured, and the only real time that
// passes is whatever the seal takes.

import Foundation
import Testing
@testable import FernletCrypto
import FernletDomainModel
@testable import ProximityKit
@testable import Fernlet

// MARK: - Shared rig

/// One §8.2 edge as a value: the bounded prefix that puts the manager into the source state, the
/// event under test, and the state plan §8.2's diagram says it lands in.
///
/// Held as a table rather than as a test each so a new state or event cannot quietly acquire an
/// unwalked edge — the walk is one bounded loop over this array.
nonisolated struct MeshSessionEdgeCase: Sendable {

    /// The edge, spelled as the diagram spells it (`"partitioned → localIdleStop"`).
    let name: String

    /// Events replayed from `idle` to reach the source state. Bounded by construction.
    let prefix: [MeshSessionEvent]

    /// The event whose edge is under test.
    let edge: MeshSessionEvent

    /// Where the manager must end up.
    let expected: MeshSessionState
}

/// What the sealed-store root holds, as a value two probes can be compared on.
///
/// Only the two files the mesh-session store owns are read: the root is shared with the other
/// proximity sidecars, so a directory-wide listing would make "nothing was written" depend on a
/// neighbour's behaviour instead of on this store's.
nonisolated struct MeshSessionDiskState: Equatable, Sendable {

    /// The sealed context's bytes, or nil when there is no file.
    let sealed: Data?

    /// The quarantined sibling's bytes, or nil when nothing has been set aside.
    let quarantined: Data?
}

/// The integrated rig every scenario in this file runs on.
///
/// `internal` helpers on an enum rather than a base class: Swift Testing builds a fresh suite
/// instance per test, so the state that must not leak between scenarios (the `FernletStore` and
/// therefore the sealed root) is a suite property, while everything stateless lives here once.
@MainActor
enum MeshP3Acceptance {

    /// A pinned install identity, so every seal in this file is deterministic rather than whatever
    /// the simulator's real device-binding row happens to be.
    static let install = Data(repeating: 0x83, count: 16)

    /// The fixed instant the clock-bearing scenarios measure from.
    static let base = Date(timeIntervalSince1970: 1_800_000_000)

    /// A descriptor naming this manager's own identity as the only member.
    static func mesh(
        for manager: MeshNetworkManager, meshID: UUID = UUID(), createdAt: Date = Date()
    ) -> MeshDescriptor {
        let local = MeshMember(
            fingerprint: manager.identityForTesting.localFingerprint,
            displayName: "Local",
            signingPublicKey: manager.identityForTesting.localSigningPublicKey,
            keyAgreementPublicKey: manager.identityForTesting.localKeyAgreementPublicKey,
            joinedAt: createdAt
        )
        return MeshDescriptor(
            meshID: meshID,
            name: "Acceptance Meadow",
            mode: .open,
            members: [local],
            nameSetAt: createdAt,
            nameSetBy: local.fingerprint,
            modeSetAt: createdAt,
            modeSetBy: local.fingerprint,
            createdAt: createdAt
        )
    }

    /// A coordinator with no live dependencies, for slots a scenario only needs to exist.
    static func coordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "test.mesh.p3accept.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }

    /// Attaches a committed slot for `fingerprint` and returns both the coordinator frames arrive
    /// over and the peer handle a radio drop names.
    @discardableResult
    static func attachSlot(
        to manager: MeshNetworkManager, fingerprint: String
    ) -> (coordinator: ProximityCoordinator, peer: PeerHandle) {
        let coordinator = coordinator()
        let peer = PeerHandle(
            id: UUID(),
            displayHint: "iPhone",
            discoveryInfo: ["v": "1"],
            advertisedFingerprint: fingerprint,
            endpoint: PeerEndpointKey()
        )
        manager.addSlotForTesting(coordinator: coordinator, peer: peer, fingerprint: fingerprint)
        return (coordinator, peer)
    }

    /// Delivers one frame through the REAL receive entry point, under the pinned install so the
    /// seal the receive path owes can actually be written.
    static func deliver(
        _ plaintext: Data,
        type: PayloadType,
        to manager: MeshNetworkManager,
        from sender: IdentityService,
        over coordinator: ProximityCoordinator
    ) throws {
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Peer",
            payloadType: type,
            payloadSummary: PayloadSummary(title: "Acceptance"),
            payload: plaintext
        )
        DeviceBindingID.$testOverride.withValue(.identifier(install)) {
            manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: nil)
        }
    }

    /// The encoding half of ``deliver(_:type:to:from:over:)``.
    static func deliver(
        encoding payload: some Encodable,
        type: PayloadType,
        to manager: MeshNetworkManager,
        from sender: IdentityService,
        over coordinator: ProximityCoordinator
    ) throws {
        try deliver(
            try JSONEncoder().encode(payload), type: type, to: manager, from: sender, over: coordinator
        )
    }

    /// Reads the sealed context back, under the same pinned install everything here writes with.
    static func loadContext(from store: FernletStore) -> MeshSessionContext? {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        let load = DeviceBindingID.$testOverride.withValue(.identifier(install)) { sessionStore.load() }
        guard case .loaded(let context, _) = load else { return nil }
        return context
    }

    /// What the sealed root holds right now — the file-system spy the "no writer" claims turn on.
    static func diskState(of store: FernletStore) -> MeshSessionDiskState {
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        return MeshSessionDiskState(
            sealed: bytes(at: sessionStore.fileURL), quarantined: bytes(at: sessionStore.quarantineURL)
        )
    }

    /// One file's bytes, or nil when it is not there. A missing file is an answer, not an error.
    private static func bytes(at url: URL) -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            Issue.record("the sealed-store file at \(url.lastPathComponent) could not be read: \(error)")
            return nil
        }
    }

    /// A donor ledger holding this device's own admission, signed by this device as founder — the
    /// one merge input the fail-closed verifier accepts without a chain to somebody else's root.
    static func selfAdmittingLedger(
        _ manager: MeshNetworkManager, meshID: UUID
    ) throws -> MeshMembershipLedger {
        let identity = manager.identityForTesting
        var donor = MeshMembershipLedger.empty
        donor.admissions = donor.admissions.inserting(
            SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                meshID: meshID,
                joinerFingerprint: identity.localFingerprint,
                joinerSigningPublicKey: identity.localSigningPublicKey,
                admitterIdentity: identity
            ))
        )
        return donor
    }

    /// A two-member ledger: `founder` self-admitted, and `member` admitted by it.
    ///
    /// Both records are honestly signed, so the verifier accepts a later record signed by either.
    static func pairLedger(
        founder: IdentityService, member: IdentityService, meshID: UUID
    ) throws -> MeshMembershipLedger {
        var ledger = MeshMembershipLedger.empty
        for joined in [founder, member] {
            ledger.admissions = ledger.admissions.inserting(
                SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                    meshID: meshID,
                    joinerFingerprint: joined.localFingerprint,
                    joinerSigningPublicKey: joined.localSigningPublicKey,
                    admitterIdentity: founder
                ))
            )
        }
        return ledger
    }

    /// Puts the manager on a named epoch without spending a rotation, and returns the head so a
    /// scenario can ask whether that (now superseded) key still opens anything.
    static func seedEpoch(_ manager: MeshNetworkManager, counter: UInt32) -> MeshEpochRef? {
        guard let head = MeshEpochRef.minted(
            counter: counter,
            coordinatorFingerprint: manager.identityForTesting.localFingerprint,
            meshID: manager.currentMesh?.meshID ?? UUID()
        ) else {
            Issue.record("could not mint the seed epoch — is the local fingerprint canonical?")
            return nil
        }
        manager.seedEpochKeyringForTesting(
            head: head,
            key: MeshGroupKey(
                epoch: Int(counter), keyBytes: Data(repeating: 0x11, count: 32), activeSince: base
            )
        )
        return head
    }

    /// Plan §8.4's grace, asserted on the integrated keyring: the superseded epoch opens in-flight
    /// frames for ≤ 5 minutes and is gone one second later, with no fallback and no "try anyway".
    ///
    /// The window is BRACKETED rather than measured from one instant, and that is load-bearing:
    /// the keyring stamps the supersession itself, somewhere inside the manager's rotation (which
    /// spends a real drain waiting for acks a fake peer never sends). The true instant is therefore
    /// only known to lie in `[startedAt, finishedAt]`, so the still-open assertions are made from
    /// the EARLIEST it can have been and the closed one from the LATEST — both hold for any drain
    /// shorter than the grace, and neither can pass by accident.
    ///
    /// - Parameters:
    ///   - manager: The rotated manager.
    ///   - old: The epoch the rotation superseded.
    ///   - startedAt: Captured immediately before the rotation.
    ///   - finishedAt: Captured immediately after it.
    static func expectOldKeyDiesAfterTheGrace(
        _ manager: MeshNetworkManager, superseded old: MeshEpochRef, startedAt: Date, finishedAt: Date
    ) {
        let grace = MeshEpochBounds.predecessorGraceSeconds
        #expect(finishedAt.timeIntervalSince(startedAt) < grace,
                "the rotation itself must not outlast the grace, or this bracket says nothing")
        #expect(manager.epochKeyring?.canOpen(old, at: finishedAt) == true,
                "in-flight frames under the closing epoch must still open")
        #expect(manager.epochKeyring?.canOpen(old, at: startedAt.addingTimeInterval(grace - 1)) == true,
                "inside the ≤ 5-minute window the superseded key still opens")
        let pastGrace = finishedAt.addingTimeInterval(grace + 1)
        #expect(manager.epochKeyring?.canOpen(old, at: pastGrace) == false,
                "past the grace the excluded member's key must be rejected")
        guard let head = manager.epochKeyring?.head else {
            Issue.record("a rotated manager must hold a head")
            return
        }
        #expect(manager.epochKeyring?.canOpen(head, at: pastGrace.addingTimeInterval(60)) == true,
                "the head itself never expires")
        #expect(manager.epochKeyring?.openableEpochs(at: pastGrace) == [head])
    }

    /// The longest prefix any edge row needs, so the walk's inner loop is bounded by a constant
    /// rather than by the table (Power of 10 rule 2).
    static let maxEdgePrefix = 4

    /// The §8.2 edges, one row each. `contextRestored` is deliberately absent: at manager level
    /// that edge is only reachable through the launch restore, which the load matrix walks.
    static let stateEdges: [MeshSessionEdgeCase] = [
        MeshSessionEdgeCase(name: "idle → joining (founded)", prefix: [], edge: .founded, expected: .joining),
        MeshSessionEdgeCase(name: "idle → joining (joined)", prefix: [], edge: .joined, expected: .joining),
        MeshSessionEdgeCase(
            name: "joining → activeForeground", prefix: [.founded], edge: .peerCommitted,
            expected: .activeForeground
        ),
        MeshSessionEdgeCase(
            name: "joining → joining (link lost before commit)", prefix: [.founded], edge: .linksLost,
            expected: .joining
        ),
        MeshSessionEdgeCase(
            name: "activeForeground → continuingInBackground", prefix: [.founded, .peerCommitted],
            edge: .backgrounded, expected: .continuingInBackground
        ),
        MeshSessionEdgeCase(
            name: "continuingInBackground → activeForeground",
            prefix: [.founded, .peerCommitted, .backgrounded], edge: .foregrounded,
            expected: .activeForeground
        ),
        MeshSessionEdgeCase(
            name: "activeForeground → partitioned", prefix: [.founded, .peerCommitted],
            edge: .linksLost, expected: .partitioned
        ),
        MeshSessionEdgeCase(
            name: "continuingInBackground → partitioned",
            prefix: [.founded, .peerCommitted, .backgrounded], edge: .linksLost, expected: .partitioned
        ),
        MeshSessionEdgeCase(
            name: "partitioned → activeForeground (merge)",
            prefix: [.founded, .peerCommitted, .linksLost], edge: .linksRestored,
            expected: .activeForeground
        ),
        MeshSessionEdgeCase(
            name: "partitioned → localIdleStop", prefix: [.founded, .peerCommitted, .linksLost],
            edge: .idleLapsed, expected: .localIdleStop
        ),
        MeshSessionEdgeCase(
            name: "localIdleStop → activeForeground (rejoin-as-merge)",
            prefix: [.founded, .peerCommitted, .linksLost, .idleLapsed], edge: .resumedAfterLapse,
            expected: .activeForeground
        ),
        MeshSessionEdgeCase(
            name: "activeForeground → handingOff (develop)", prefix: [.founded, .peerCommitted],
            edge: .developed, expected: .handingOff
        ),
        MeshSessionEdgeCase(
            name: "partitioned → handingOff (departure requested)",
            prefix: [.founded, .peerCommitted, .linksLost], edge: .departureRequested,
            expected: .handingOff
        ),
        MeshSessionEdgeCase(
            name: "handingOff → departed", prefix: [.founded, .peerCommitted, .departureRequested],
            edge: .departureSent, expected: .departed
        ),
        MeshSessionEdgeCase(
            name: "handingOff → terminated",
            prefix: [.founded, .peerCommitted, .terminationRequested(.finalPairTermination)],
            edge: .terminationSent, expected: .terminated
        ),
        MeshSessionEdgeCase(
            name: "localIdleStop → expired (signed bound)",
            prefix: [.founded, .peerCommitted, .linksLost, .idleLapsed],
            edge: .hardDeadlineReached(.signedAbsolute), expected: .expired
        ),
        MeshSessionEdgeCase(
            name: "activeForeground → expired (monotonic bound)", prefix: [.founded, .peerCommitted],
            edge: .hardDeadlineReached(.localMonotonic), expected: .expired
        ),
        MeshSessionEdgeCase(
            name: "activeForeground → departed (removed)", prefix: [.founded, .peerCommitted],
            edge: .removed, expected: .departed
        ),
        MeshSessionEdgeCase(
            name: "activeForeground → terminated (termination verified)",
            prefix: [.founded, .peerCommitted], edge: .terminationVerified, expected: .terminated
        )
    ]
}

// MARK: - The lifecycle lines

/// Plan §8.4 acceptance, lines 1–4: every state edge, disconnect ≠ removal, idle-lapse resume, and
/// the ceiling at both bounds — each walked on the integrated manager rather than on the pure
/// machine.
@MainActor
@Suite(.serialized)
struct MeshP3SessionAcceptanceTests {

    let store = makeTestStore()

    /// A manager on the fake radio, already holding a descriptor so every `persistContext` effect
    /// has a mesh to write.
    private func makeManager() -> MeshNetworkManager {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        return manager
    }

    /// **"unit tests for every state edge"** — walked end to end through
    /// `MeshNetworkManager.applySessionEvent`, so each edge is taken with its effects actually
    /// performed (the seal written, the idle window armed, the radios stopped) rather than with the
    /// effect list merely inspected. `MeshSessionStateMachineTests` walls the pure function's
    /// totality; this walls the performer beneath it.
    ///
    /// **What "end to end" does not yet mean for three of these events.** `.developed`,
    /// `.backgrounded` and `.foregrounded` have no shipping caller — nothing in `ProximityKit` or
    /// the app fires them, because the develop hand-off and the scene-phase wiring are P7's (item
    /// 6 recorded the same seam). Every other event in this table is driven from shipping code, so
    /// those three edges are walled here as the machine + performer they will be attached to, not
    /// as behaviour a user can currently reach.
    @Test func everyStateEdgeIsTakenThroughTheIntegratedManager() {
        for edge in MeshP3Acceptance.stateEdges {
            let manager = makeManager()
            DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                for event in edge.prefix.prefix(MeshP3Acceptance.maxEdgePrefix) {
                    manager.applySessionEvent(event)
                }
                manager.applySessionEvent(edge.edge)
            }
            #expect(manager.sessionState == edge.expected, "\(edge.name) must land in \(edge.expected)")
            #expect(manager.lastSessionEffectFailure == nil,
                    "\(edge.name): no effect may fail with a writable store")
            manager.leaveMesh()
        }
    }

    /// **"disconnect ≠ removal"** — on two independent fakes, each dropping the other. Neither
    /// device mints a record, neither roster moves, and the peer that came back is still in the
    /// next epoch's key distribution. Two managers rather than one because the asymmetric failure
    /// (the dropper removes, the dropped does not) is invisible from a single side.
    @Test func aDisconnectIsNotARemovalOnEitherSideOfTheDrop() throws {
        let peerStore = makeTestStore()
        let transports = [FakeMeshTransportSession(), FakeMeshTransportSession()]
        let managers = [
            MeshNetworkManager(store: store, transport: transports[0]),
            MeshNetworkManager(store: peerStore, transport: transports[1])
        ]
        for (index, manager) in managers.enumerated() {
            let mesh = MeshP3Acceptance.mesh(for: manager)
            manager.currentMesh = mesh
            manager.prepareMembershipLedger(
                meshID: mesh.meshID,
                founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
            )
            let attached = MeshP3Acceptance.attachSlot(to: manager, fingerprint: "fp-peer-\(1 - index)")
            try DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                _ = manager.mergeMembershipLedger(
                    try MeshP3Acceptance.selfAdmittingLedger(manager, meshID: mesh.meshID)
                )
                manager.applySessionEvent(.founded)
                manager.applySessionEvent(.peerCommitted)
                transports[index].drop(attached.peer)
            }
        }

        for manager in managers {
            #expect(manager.sessionState == .partitioned, "a dropped link partitions, it never removes")
            #expect(manager.idleLapseDeadline != nil, "the idle window arms on the partition")
            #expect(manager.membershipVerifier?.roster.memberCount == 1, "the roster does not move")
            #expect(manager.membershipVerifier?.ledger.departures.isEmpty == true)
            #expect(manager.membershipVerifier?.ledger.removals.isEmpty == true)
            #expect(manager.removedMemberFingerprints.isEmpty, "a disconnect bars nobody")
            let selfFP = manager.identityForTesting.localFingerprint
            let recipients = MeshRotationPolicy.recipients(
                acked: [selfFP], selfFingerprint: selfFP,
                derivedRoster: manager.membershipVerifier?.roster, locallyRemoved: []
            )
            #expect(recipients.contains(selfFP),
                    "a disconnected member keeps its place in the key distribution")
            manager.leaveMesh()
        }
    }

    /// **"idle-lapse resume"** — and plan §8.4's coexistence rule underneath it. Both sides rotate
    /// to the SAME counter while partitioned; on resume neither epoch accepts the other, both
    /// survive in the sealed `epochHeads`, and exactly one `.merge` rotation is armed.
    @Test func anIdleLapseResumesAsAMergeWithBothDivergentHeadsSurviving() async throws {
        let manager = makeManager()
        guard let meshID = manager.currentMesh?.meshID else {
            Issue.record("the rig must hand back a manager holding a descriptor")
            return
        }
        guard MeshP3Acceptance.seedEpoch(manager, counter: 3) != nil else { return }
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.rotateNowForTesting(cause: .timer)
        }
        manager.prepareMembershipLedger(
            meshID: meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        guard let ownHead = manager.epochKeyring?.head,
              let peerHead = MeshEpochRef.minted(
                  counter: ownHead.counter,
                  coordinatorFingerprint: MeshEpochFixtures.coordinatorB,
                  meshID: meshID
              ) else {
            Issue.record("the rotation must leave a head to diverge from")
            return
        }
        #expect(MeshEpochAcceptance.rotationVerdict(
            local: ownHead, presented: peerHead,
            presentedRoster: [MeshEpochFixtures.coordinatorB],
            presenterFingerprint: MeshEpochFixtures.coordinatorB
        ) == .coexist, "two partitions at the same counter coexist — neither accepts the other")

        let donor = try MeshP3Acceptance.selfAdmittingLedger(manager, meshID: meshID)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
            manager.applySessionEvent(.linksLost)
            _ = manager.evaluateIdleLapse(now: Date().addingTimeInterval(MeshNetworkManager.idleWindowSeconds + 1))
            #expect(manager.sessionState == .localIdleStop, "the lapse stops participation, not membership")
            _ = manager.resumeSessionAfterLapse(mergingLedger: donor, peerEpochHead: peerHead)
        }

        #expect(manager.sessionState == .activeForeground)
        #expect(manager.currentMesh?.meshID == meshID, "the SAME session resumes, not a fresh one")
        #expect(manager.rotationTriggers.pendingCause == .merge, "the resume rotates as a merge, once")
        let heads = MeshP3Acceptance.loadContext(from: store)?.epochHeads ?? []
        #expect(heads.contains(ownHead) && heads.contains(peerHead),
                "both branch heads survive the resume — coexistence, not a silent re-key")
        manager.leaveMesh()
    }

    /// **"ceiling at both bounds"** — with the two clock jumps each bound exists for. A wall clock
    /// set a day backwards buys no membership (the monotonic guard ends it anyway); a clock set an
    /// hour forwards ends it by the SIGNED bound, and the reason written down names which one.
    @Test func theCeilingEndsTheSessionAtBothBoundsAcrossBothClockJumps() async {
        let jumps: [(bound: MeshSessionCeilingBound, now: Date, elapsed: TimeInterval)] = [
            (.localMonotonic, MeshP3Acceptance.base.addingTimeInterval(-86_400),
             MeshSessionCeiling.ceilingSeconds),
            (.signedAbsolute,
             MeshP3Acceptance.base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds + 3_600), 5)
        ]
        for jump in jumps {
            let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
            let created = MeshP3Acceptance.base
            manager.currentMesh = MeshP3Acceptance.mesh(for: manager, createdAt: created)
            var emitted: [PayloadType] = []
            manager.onMembershipEventSentForTesting = { emitted.append($0) }

            await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
                manager.applySessionEvent(.founded)
                manager.startSessionCeiling(
                    hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
                    startedAt: created
                )
                await manager.enforceSessionCeiling(now: jump.now, monotonicElapsed: jump.elapsed)
            }

            #expect(manager.sessionState == .expired, "\(jump.bound) must end the session")
            #expect(emitted == [.meshTerminated], "the ceiling announces itself (plan §8.2)")
            #expect(MeshP3Acceptance.loadContext(from: store)?.localTermination?.reason
                    == jump.bound.terminationReason, "the reason names the bound that ended it")
            manager.leaveMesh()
        }
    }
}

// MARK: - The rotation line

/// Plan §8.4 acceptance, line 5: **"rotation on removal/departure/merge with old-key rejection
/// after grace"** — one scenario per cause, each ending in the same grace assertion so the three
/// causes cannot drift apart on the half that matters.
@MainActor
@Suite(.serialized)
struct MeshP3RotationAcceptanceTests {

    let store = makeTestStore()

    private func makeManager() -> MeshNetworkManager {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager)
        return manager
    }

    /// **Rotation on removal.** A completed vote rotates at once rather than at the next timer
    /// tick, the voted-out member is excluded from the new epoch's key, and their old key stops
    /// opening anything past the grace — which is the whole of the voted-out-member-keeps-key gap.
    @Test func aRemovalRotatesAndTheExcludedMembersOldKeyDiesAfterTheGrace() async {
        let manager = makeManager()
        guard let old = MeshP3Acceptance.seedEpoch(manager, counter: 3) else { return }
        let proposal = MeshRemovalProposalPayload(
            id: UUID(), targetFingerprint: "fp-target", targetDisplayName: "Target",
            proposerFingerprint: "fp-proposer", proposerDisplayName: "Proposer",
            createdAt: MeshP3Acceptance.base, expiresAt: MeshP3Acceptance.base.addingTimeInterval(60)
        )

        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.secondRemoval(proposal)
        }
        #expect(manager.rotationTriggers.pendingCause == .membership,
                "a voted-out member rotates the key now, not at the next 15-minute tick")
        let startedAt = Date()
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.rotateNowForTesting(cause: .membership)
        }
        let finishedAt = Date()

        #expect(manager.epochKeyring?.head.counter == old.counter + 1)
        #expect(manager.lastRotationCause == .membership)
        let selfFP = manager.identityForTesting.localFingerprint
        let recipients = MeshRotationPolicy.recipients(
            acked: [selfFP, "fp-target"], selfFingerprint: selfFP,
            derivedRoster: manager.membershipVerifier?.roster,
            locallyRemoved: manager.removedMemberFingerprints
        )
        #expect(!recipients.contains("fp-target"), "the removed member is not sent the new epoch's key")
        MeshP3Acceptance.expectOldKeyDiesAfterTheGrace(
            manager, superseded: old, startedAt: startedAt, finishedAt: finishedAt
        )
        manager.leaveMesh()
    }

    /// **Rotation on departure.** A leaver's own signed record, arriving over the receive path,
    /// moves the derived roster — so it rotates like any other roster change, and the departed
    /// member's key dies on the same schedule as a removed one's.
    @Test func aDepartureRotatesAndTheDepartedMembersOldKeyDiesAfterTheGrace() async throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        let identity = manager.identityForTesting
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: fixture.meshID)
        // This device founds a PAIR and admits the leaver, so that once the leaver goes the roster
        // is this device alone — which is what makes it the deterministic coordinator of the
        // rotation the departure triggers, whatever the fixture's random fingerprints sort to.
        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: identity.localSigningPublicKey,
            ledger: try MeshP3Acceptance.pairLedger(
                founder: identity, member: fixture.joiner, meshID: fixture.meshID
            )
        )
        guard let old = MeshP3Acceptance.seedEpoch(manager, counter: 5) else { return }
        let slot = MeshP3Acceptance.attachSlot(to: manager, fingerprint: fixture.joiner.localFingerprint)

        try MeshP3Acceptance.deliver(
            encoding: MeshMemberDeparturePayload(record: try SignedDepartureRecord.signed(
                meshID: fixture.meshID, identity: fixture.joiner
            )),
            type: .meshMemberDeparture, to: manager, from: fixture.joiner, over: slot.coordinator
        )

        #expect(manager.membershipVerifier?.ledger.departures.count == 1, "the record is inserted")
        #expect(manager.membershipVerifier?.roster.contains(
            fingerprint: fixture.joiner.localFingerprint
        ) == false, "and the derived roster drops the leaver")
        #expect(manager.rotationTriggers.pendingCause == .membership,
                "a departure is a roster change, so it rotates (plan §8.3)")
        let startedAt = Date()
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.rotateNowForTesting(cause: .membership)
        }
        let finishedAt = Date()

        let recipients = MeshRotationPolicy.recipients(
            acked: [fixture.joiner.localFingerprint, identity.localFingerprint],
            selfFingerprint: identity.localFingerprint,
            derivedRoster: manager.membershipVerifier?.roster, locallyRemoved: []
        )
        #expect(!recipients.contains(fixture.joiner.localFingerprint),
                "a departed member is not sent the next key")
        MeshP3Acceptance.expectOldKeyDiesAfterTheGrace(
            manager, superseded: old, startedAt: startedAt, finishedAt: finishedAt
        )
        manager.leaveMesh()
    }

    /// **Rotation on merge.** A merge that MOVES the roster rotates as `.merge`; the superseded
    /// epoch keeps opening in-flight frames for the grace and not one second longer.
    @Test func aMergeRotatesAndTheSupersededEpochDiesAfterTheGrace() async throws {
        let manager = makeManager()
        guard let meshID = manager.currentMesh?.meshID else {
            Issue.record("the rig must hand back a manager holding a descriptor")
            return
        }
        manager.prepareMembershipLedger(
            meshID: meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        guard let old = MeshP3Acceptance.seedEpoch(manager, counter: 7) else { return }
        let donor = try MeshP3Acceptance.selfAdmittingLedger(manager, meshID: meshID)

        let rejections = DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.mergeMembershipLedger(donor)
        }
        #expect(rejections.isEmpty)
        #expect(manager.rotationTriggers.pendingCause == .merge, "a roster-moving merge rotates")
        let startedAt = Date()
        await DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            await manager.rotateNowForTesting(cause: .merge)
        }
        let finishedAt = Date()

        #expect(manager.epochKeyring?.head.counter == old.counter + 1)
        #expect(manager.lastRotationCause == .merge)
        MeshP3Acceptance.expectOldKeyDiesAfterTheGrace(
            manager, superseded: old, startedAt: startedAt, finishedAt: finishedAt
        )
        manager.leaveMesh()
    }
}

// MARK: - The store-matrix line

/// One launch restore, run on its own sealed root: what the manager concluded, and exactly what
/// moved on the disk while it concluded it.
@MainActor
struct MeshSessionRestoreProbe {

    /// What the launch decided.
    let outcome: MeshSessionRestoreOutcome

    /// The state the manager ended in.
    let state: MeshSessionState

    /// The root before the restore ran.
    let before: MeshSessionDiskState

    /// The root after it ran — equal to ``before`` for every state that must run no writer.
    let after: MeshSessionDiskState
}

/// Plan §8.4 acceptance, line 6: **"context load/deferred/corrupt matrix"**, plus the fifth load
/// state the launcher's §5 design call added (**refused**).
///
/// `MeshSessionStoreTests` walls the five load states and `MeshSessionStateMachineTests` the pure
/// five-to-seven mapping. What only the integrated manager can show is the pairing of each outcome
/// with what reached the disk: an `absent` that is really a refusal is the shape that overwrites
/// live data, so every non-writable state is asserted against a file-system spy rather than
/// against a return value.
@MainActor
@Suite(.serialized)
struct MeshP3RestoreMatrixAcceptanceTests {

    /// A live context created at the fixed base instant.
    private func context(termination: MeshSessionLocalTermination? = nil) -> MeshSessionContext {
        MeshSessionContext(
            meshID: UUID(),
            protocolVersion: 3,
            createdAt: MeshP3Acceptance.base,
            hardDeadline: MeshP3Acceptance.base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            localTermination: termination
        )
    }

    /// Runs one launch restore on a freshly isolated sealed root.
    ///
    /// - Parameters:
    ///   - seed: The context to seal first, or nil for the absent case.
    ///   - corrupt: Truncates the sealed ciphertext after writing it (junk bytes would be a
    ///     *refusal* by name, not a corruption — they carry no v3 prefix).
    ///   - binding: The install-binding answer the restore runs under.
    ///   - now: The instant the launch happens at.
    private func probe(
        seed: MeshSessionContext?,
        corrupt: Bool = false,
        binding: DeviceBindingID.TestOverride,
        now: Date
    ) throws -> MeshSessionRestoreProbe {
        let store = makeTestStore()
        let sessionStore = MeshSessionStore(scope: store.meshSessionStorage)
        if let seed {
            try MeshSessionStoreFixtures.save(seed, into: sessionStore, install: MeshP3Acceptance.install)
        }
        if corrupt {
            let sealed = try Data(contentsOf: sessionStore.fileURL)
            try MeshSessionStoreFixtures.writeRaw(sealed.prefix(sealed.count - 8), into: sessionStore)
        }
        let before = MeshP3Acceptance.diskState(of: store)
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        let outcome = DeviceBindingID.$testOverride.withValue(binding) {
            manager.restoreSessionContextAtLaunch(now: now)
        }
        return MeshSessionRestoreProbe(
            outcome: outcome, state: manager.sessionState,
            before: before, after: MeshP3Acceptance.diskState(of: store)
        )
    }

    /// The three loaded outcomes: a live context resumes (never auto-reconnects), a recorded
    /// ending comes back ended, and a ceiling that passed while the process was gone is WRITTEN
    /// down rather than merely noticed.
    @Test func theThreeLoadedOutcomesAreDistinctAndOnlyTheExpiredOneWrites() throws {
        let live = try probe(
            seed: context(), binding: .identifier(MeshP3Acceptance.install),
            now: MeshP3Acceptance.base.addingTimeInterval(3_600)
        )
        #expect(live.outcome.disposition == .resumable)
        #expect(live.state == .localIdleStop, "a relaunch never auto-reconnects")
        #expect(live.after == live.before, "a resumable restore reads; it does not write")

        let ended = try probe(
            seed: context(termination: MeshSessionLocalTermination(
                reason: .finalPairTermination, at: MeshP3Acceptance.base
            )),
            binding: .identifier(MeshP3Acceptance.install),
            now: MeshP3Acceptance.base.addingTimeInterval(60)
        )
        #expect(ended.outcome.disposition == .terminated)
        #expect(ended.state == .terminated, "a restart must not resurrect an ended session")

        let expired = try probe(
            seed: context(), binding: .identifier(MeshP3Acceptance.install),
            now: MeshP3Acceptance.base.addingTimeInterval(MeshSessionCeiling.ceilingSeconds + 86_400)
        )
        #expect(expired.outcome.logToken == "expired")
        #expect(expired.state == .expired)
        #expect(expired.after != expired.before,
                "the expiry the launch discovered is written down — the one restore that must write")
    }

    /// The four non-loaded outcomes, each distinct, and the three of them that must run **no
    /// writer**: `deferred`, `refused` and `corrupt` leave the sealed file exactly as they found
    /// it (the corrupt one is *moved* aside intact — preserved, never overwritten, never replaced
    /// by a green field).
    @Test func absentDeferredRefusedAndCorruptAreDistinctAndRunNoWriter() throws {
        let absent = try probe(seed: nil, binding: .identifier(MeshP3Acceptance.install), now: .now)
        #expect(absent.outcome == .noSession)
        #expect(absent.state == .idle)
        #expect(absent.after == absent.before, "the one green field writes nothing either")

        let deferred = try probe(seed: context(), binding: .readError, now: MeshP3Acceptance.base)
        #expect(deferred.outcome.logToken.hasPrefix("deferred:"))
        #expect(deferred.outcome.isRetryable)
        #expect(deferred.state == .idle, "a deferral never starts a session")
        #expect(deferred.after == deferred.before, "and it runs no writer")

        let refused = try probe(seed: context(), binding: .unavailable, now: MeshP3Acceptance.base)
        #expect(refused.outcome.logToken.hasPrefix("refused:"), "a refusal is logged apart from a deferral")
        #expect(refused.outcome.isRetryable)
        #expect(refused.state == .idle)
        #expect(refused.after == refused.before,
                "an `absent` that is really a refusal is the shape that overwrites live data")

        let corrupt = try probe(
            seed: context(), corrupt: true, binding: .identifier(MeshP3Acceptance.install), now: .now
        )
        #expect(corrupt.outcome.logToken == "corrupt")
        #expect(!corrupt.outcome.isRetryable, "a corrupt file is quarantined, not retried")
        #expect(corrupt.state == .idle)
        #expect(corrupt.after.sealed == nil, "no writer ran: nothing replaced the bytes it could not read")
        #expect(corrupt.after.quarantined == corrupt.before.sealed,
                "the bytes are set aside intact, not destroyed")
    }
}

// MARK: - The interop and propagation lines

/// Plan §8.4 acceptance, line 7 (**"legacy `sessionGoodbye` interop"**), plan §10.5's propagation
/// example, and plan §3.6's durable-before-acknowledged rule, which every line above sits on.
@MainActor
@Suite(.serialized)
struct MeshP3InteropAcceptanceTests {

    let store = makeTestStore()

    /// **Legacy `sessionGoodbye` interop.** A peer still running a pre-transition build sends the
    /// unsigned goodbye; it is parsed, the LINK closes, and membership is untouched — the peer
    /// stays on the derived roster, no departure record is minted, and the session never reaches
    /// `departed`. `MeshMembershipEventWireTests` states the same rule at the type; this is it
    /// arriving over the receive path with a committed slot on the other end.
    @Test func aLegacyGoodbyeClosesTheLinkAndNeverTheMembership() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: fixture.meshID)
        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: fixture.founder.localSigningPublicKey,
            ledger: try fixture.fullLedger()
        )
        let slot = MeshP3Acceptance.attachSlot(to: manager, fingerprint: fixture.joiner.localFingerprint)
        DeviceBindingID.$testOverride.withValue(.identifier(MeshP3Acceptance.install)) {
            manager.applySessionEvent(.founded)
            manager.applySessionEvent(.peerCommitted)
        }
        let rosterBefore = manager.membershipVerifier?.roster

        try MeshP3Acceptance.deliver(
            Data("{}".utf8), type: MeshMembershipGoodbyeInterop.payloadType,
            to: manager, from: fixture.joiner, over: slot.coordinator
        )

        #expect(MeshMembershipGoodbyeInterop.outcome(
            forGoodbyeFrom: fixture.joiner.localFingerprint
        ) == .disconnected, "a goodbye can only mean the link went away")
        #expect(MeshMembershipGoodbyeInterop.departureRecord(
            forGoodbyeFrom: fixture.joiner.localFingerprint
        ) == nil, "an unsigned frame may never subtract a signed member")
        #expect(manager.slots.isEmpty, "the link is closed")
        #expect(manager.membershipVerifier?.roster == rosterBefore, "and the roster is not")
        #expect(manager.membershipVerifier?.ledger.departures.isEmpty == true)
        #expect(manager.sessionState != .departed, "a goodbye never ends this device's membership")
        manager.leaveMesh()
    }

    /// The other half of the interop line: no shipping source EMITS a goodbye any more. Item 3's
    /// `MeshMembershipEventWireTests.noShippingSourceEmitsAGoodbye` is the same wall; the battery
    /// re-affirms it here because "parsed, never emitted" is half of the acceptance line and the
    /// scenario above can only show the parsed half.
    @Test func theGoodbyeGrepWallStillHolds() throws {
        var offenders: [String] = []
        for url in try CryptographicWallScan.sourceFiles() {
            let source = try String(contentsOf: url, encoding: .utf8)
            for line in source.components(separatedBy: .newlines)
            where line.contains("sendEnvelope(.sessionGoodbye") {
                offenders.append(CryptographicWallScan.repoRelativePath(url))
            }
        }
        #expect(offenders.isEmpty, "still emitting `.sessionGoodbye`: \(offenders.sorted())")
    }

    /// **Plan §10.5's propagation example, at tier 1.** Three nodes converge on one roster (item 7
    /// proved the derivation; this re-runs it as acceptance and adds the key half), and then a
    /// departure by the third member is carried to a member that missed it — by the digest answer
    /// path, as the frames that already carry the record, without a new wire shape.
    @Test func aThreeNodeRosterConvergesAndADepartureReachesTheMemberThatMissedIt() async throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        manager.currentMesh = MeshP3Acceptance.mesh(for: manager, meshID: fixture.meshID)
        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: fixture.founder.localSigningPublicKey,
            ledger: try fixture.fullLedger()
        )
        let expected = [
            fixture.founder.localFingerprint, fixture.admitter.localFingerprint,
            fixture.joiner.localFingerprint
        ].sorted()
        #expect(manager.membershipVerifier?.roster.memberFingerprints == expected,
                "A → B → C: a member learned of by record is on the roster")
        // Who the next epoch's key goes to is decided from the derived roster, so C — whom A only
        // ever learned of by record — is in the distribution. The mint itself is coordinator-gated
        // (lowest fingerprint of the presented roster) and is walled by the rotation scenarios
        // above, where this device IS that coordinator.
        let recipients = MeshRotationPolicy.recipients(
            acked: Set(expected), selfFingerprint: fixture.founder.localFingerprint,
            derivedRoster: manager.membershipVerifier?.roster, locallyRemoved: []
        )
        #expect(recipients.contains(fixture.joiner.localFingerprint),
                "C receives the key minted after the rotation")

        let joinerSlot = MeshP3Acceptance.attachSlot(
            to: manager, fingerprint: fixture.joiner.localFingerprint
        )
        try MeshP3Acceptance.deliver(
            encoding: MeshMemberDeparturePayload(record: try SignedDepartureRecord.signed(
                meshID: fixture.meshID, identity: fixture.joiner
            )),
            type: .meshMemberDeparture, to: manager, from: fixture.joiner, over: joinerSlot.coordinator
        )
        #expect(manager.membershipVerifier?.roster.contains(
            fingerprint: fixture.joiner.localFingerprint
        ) == false, "C's departure lands on A")

        var emitted: [PayloadType] = []
        manager.onMembershipEventSentForTesting = { emitted.append($0) }
        let admitterSlot = MeshP3Acceptance.attachSlot(
            to: manager, fingerprint: fixture.admitter.localFingerprint
        )
        var behind = MeshMembershipLedger.empty
        behind.admissions = behind.admissions.inserting(try fixture.founderAdmission())
        try MeshP3Acceptance.deliver(
            encoding: try MeshInventoryDigestPayload.signed(
                meshID: fixture.meshID, ledger: behind, identity: fixture.admitter
            ),
            type: .meshInventoryDigest, to: manager, from: fixture.admitter, over: admitterSlot.coordinator
        )
        var yields = 0
        while !emitted.contains(.meshMemberDeparture), yields < 400 {
            await Task.yield()
            yields += 1
        }

        #expect(emitted.contains(.meshMemberDeparture),
                "B, which missed the departure, is re-gossiped it (plan §10.5)")
        #expect(emitted.filter { $0 == .meshMemberAdmission }.count == 3,
                "the whole ledger goes, as the frames that already carry it")
        manager.leaveMesh()
    }

    /// **Durable before acknowledged** (plan §3.6), the rule every line above rests on: a store
    /// that refuses to seal blocks the join acknowledgement, the record insertion and the rotation
    /// alike — and the file-system spy shows that nothing at all reached the disk while all three
    /// were refused.
    @Test func nothingIsAcknowledgedWhileTheStoreRefusesToSeal() async throws {
        let manager = MeshNetworkManager(store: store, transport: FakeMeshTransportSession())
        let mesh = MeshP3Acceptance.mesh(for: manager)
        manager.currentMesh = mesh
        manager.prepareMembershipLedger(
            meshID: mesh.meshID, founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey
        )
        guard let seeded = MeshP3Acceptance.seedEpoch(manager, counter: 3) else { return }
        let donor = try MeshP3Acceptance.selfAdmittingLedger(manager, meshID: mesh.meshID)
        let before = MeshP3Acceptance.diskState(of: store)

        let acknowledged = DeviceBindingID.$testOverride.withValue(.unavailable) {
            manager.recordVerifiedAdmissionDurably()
        }
        let rejections = DeviceBindingID.$testOverride.withValue(.unavailable) {
            manager.mergeMembershipLedger(donor)
        }
        await DeviceBindingID.$testOverride.withValue(.unavailable) {
            await manager.rotateNowForTesting(cause: .membership)
        }

        #expect(!acknowledged, "a refused seal must block the join acknowledgement")
        #expect(manager.sessionState == .idle, "a half-joined state is not a state")
        #expect(rejections.isEmpty, "the record verified — it is the SAVE that failed")
        #expect(manager.membershipVerifier?.ledger.admissions.isEmpty == true,
                "a record that could not be written down is not inserted for roster purposes")
        #expect(manager.rotationTriggers.pendingCause == nil,
                "and the rotation that record would have caused must not fire")
        #expect(manager.epochKeyring?.head == seeded, "a rotation that cannot be sealed must not happen")
        #expect(manager.lastRotationBlockReason != nil, "a blocked rotation is never silent")
        #expect(MeshP3Acceptance.diskState(of: store) == before,
                "nothing acknowledged, and nothing on the disk")
        manager.leaveMesh()
    }
}
