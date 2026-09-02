// MeshIntroductionAuthorityTests.swift
// FernletTests
//
// P3 item 7 (plan §8.1, §8.3, §10.5, §20.4.4): the introduction authority answers from the DERIVED
// roster, and a joiner holds a ledger to derive it from.
//
// Four claims are walled here, each one a thing the items before this could not reach:
//
// 1. **A joiner adopts a ledger.** Item 3 recorded the gap verbatim — "joiners never adopt a
//    ledger, so every received event on a joiner is refused `signerNotAdmitted`". Bootstrap from
//    the admission this device verified, then rebase onto the mesh's real founder once the offered
//    ledger's chain to this device's admitter is proven.
// 2. **`barred` has real contents.** Plan §20.1's gap: the live manager kept removals by
//    fingerprint and held no signing key for a member it had dropped, so a removed peer refused as
//    an anonymous `unknownIdentity` and matrix row 3 was produced by a chaos hook. The admission
//    record carries the key, so the shipping authority now answers `.barredMember` itself.
// 3. **The legacy fallback is reachable only with an empty ledger, and says so.** A roster derived
//    from gossip rather than from signed records is a fact the log has to carry.
// 4. **Three nodes converge on one roster.** A(founder) → B → C, with C never having met A: all
//    three derive the same members, and the rotation's key distribution includes C. Without the
//    admission on the wire an unpropagated joiner is silently excluded from the group key.

import CryptoKit
import Foundation
@testable import FernletCrypto
import FernletDomainModel
import FernletFoundation
import Testing
@testable import ProximityKit
@testable import Fernlet

// MARK: - Shared fixtures

/// The three-identity mesh every suite in this file builds: a founder, the member it admitted, and
/// the joiner that member admitted in turn.
///
/// Held as a type rather than as loose helpers because the *chain* is the fixture — C's admission
/// is signed by B, and B's by A — and a test that rebuilt it inline would keep re-deriving the one
/// property adoption turns on.
@MainActor
struct MeshLedgerChainFixture {

    /// The mesh every record names.
    let meshID = UUID()
    /// The founder, who self-admits.
    let founder: IdentityService
    /// The member the founder admitted, and the one that admits the joiner.
    let admitter: IdentityService
    /// The joiner, which has never met the founder.
    let joiner: IdentityService

    /// Keychain services to delete on teardown.
    let services: [String]

    /// Builds three provisioned identities in isolated keychain services.
    init() throws {
        var built: [(IdentityService, String)] = []
        for index in 0..<3 {
            let name = "com.fernlet.mesh-authority.test.\(index).\(UUID().uuidString)"
            let service = IdentityService(keychainService: name)
            try service.ensureProvisioned()
            built.append((service, name))
        }
        founder = built[0].0
        admitter = built[1].0
        joiner = built[2].0
        services = built.map(\.1)
    }

    /// Deletes every keychain item the fixture provisioned.
    func tearDown() {
        for service in services { KeychainItem.deleteAll(service: service) }
    }

    /// One admission record: `admitter` signing `member` in.
    func admission(
        of member: IdentityService,
        by admittingIdentity: IdentityService
    ) throws -> SignedAdmissionRecord {
        SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
            meshID: meshID,
            joinerFingerprint: member.localFingerprint,
            joinerSigningPublicKey: member.localSigningPublicKey,
            admitterIdentity: admittingIdentity
        ))
    }

    /// The founder's own self-admission — the root of every chain.
    func founderAdmission() throws -> SignedAdmissionRecord {
        try admission(of: founder, by: founder)
    }

    /// The full three-member ledger the admitter holds: A self-admitted, B by A, C by B.
    func fullLedger() throws -> MeshMembershipLedger {
        var ledger = MeshMembershipLedger.empty
        ledger.admissions = ledger.admissions
            .inserting(try founderAdmission())
            .inserting(try admission(of: admitter, by: founder))
            .inserting(try admission(of: joiner, by: admitter))
        return ledger
    }

    /// The grant payload the joiner verified: the token that admitted it, wrapped for the manager
    /// path that arms the ledger.
    func joinerGrant() throws -> MeshAdmissionGrantPayload {
        MeshAdmissionGrantPayload(
            meshID: meshID,
            requesterFingerprint: joiner.localFingerprint,
            token: try admission(of: joiner, by: admitter).token
        )
    }
}

// MARK: - Adoption, pure (plan §8.3, §20.4.4)

/// P3 item 7: how a joiner comes to hold a ledger, with no store and no transport in sight.
@MainActor
@Suite struct MeshLedgerAdoptionTests {

    /// A joiner arms itself from the one thing it authenticated: the admission its transport-
    /// verified peer signed. The root is provisional — the admitter's key, not the founder's — and
    /// the roster it derives is exactly one member, this device.
    @Test func aJoinerBootstrapsFromTheAdmissionItVerified() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let own = try fixture.admission(of: fixture.joiner, by: fixture.admitter)

        guard case .adopted(let verifier) = MeshLedgerAdoption.bootstrapVerifier(
            meshID: fixture.meshID, ownAdmission: own
        ) else {
            Issue.record("a verified admission must arm a ledger")
            return
        }

        #expect(verifier.roster.memberFingerprints == [fixture.joiner.localFingerprint])
        #expect(verifier.founderSigningPublicKey == fixture.admitter.localSigningPublicKey)
        #expect(MeshLedgerAdoption.isBootstrap(
            verifier.ledger, selfFingerprint: fixture.joiner.localFingerprint
        ))
    }

    /// A founder's ledger is also one admission long, and must never be rebased: the difference is
    /// in the record, not in a flag — its author is the founder itself.
    @Test func aFounderLedgerIsNotABootstrapToRebase() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        var founderLedger = MeshMembershipLedger.empty
        founderLedger.admissions = founderLedger.admissions.inserting(try fixture.founderAdmission())

        #expect(!MeshLedgerAdoption.isBootstrap(
            founderLedger, selfFingerprint: fixture.founder.localFingerprint
        ))
    }

    /// The rebase: a peer's ledger is re-verified from its OWN root, and that root is accepted as
    /// the founder because the resulting roster admits this device's admitter under exactly the key
    /// its token names. Merging record-by-record could never have got here — the founder's
    /// self-admission is `unauthorizedAdmitter` to a ledger rooted at the admitter.
    @Test func adoptingAPeerLedgerRebasesOntoTheRealFounder() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let own = try fixture.admission(of: fixture.joiner, by: fixture.admitter)

        guard case .adopted(let adopted) = MeshLedgerAdoption.adopt(
            offered: try fixture.fullLedger(), ownAdmission: own, meshID: fixture.meshID
        ) else {
            Issue.record("a chained ledger must be adopted")
            return
        }

        #expect(adopted.founderSigningPublicKey == fixture.founder.localSigningPublicKey)
        #expect(adopted.roster.memberFingerprints == [
            fixture.founder.localFingerprint,
            fixture.admitter.localFingerprint,
            fixture.joiner.localFingerprint
        ].sorted())
    }

    /// The chain check is the whole of the rebase's safety: a ledger that does not admit the peer
    /// that admitted this device proves nothing about this mesh's history, however well-formed.
    @Test func aLedgerThatDoesNotAdmitMyAdmitterIsRefused() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        // The founder's own ledger, before it ever admitted the admitter.
        var lonely = MeshMembershipLedger.empty
        lonely.admissions = lonely.admissions.inserting(try fixture.founderAdmission())
        let own = try fixture.admission(of: fixture.joiner, by: fixture.admitter)

        let outcome = MeshLedgerAdoption.adopt(
            offered: lonely, ownAdmission: own, meshID: fixture.meshID
        )

        guard case .refused(let refusal) = outcome else {
            Issue.record("an unchained ledger must be refused")
            return
        }
        #expect(refusal == .admitterNotChained)
    }

    /// A root that is not self-admitted is nobody's founder: every other record needs an
    /// already-admitted admitter, so a ledger rooted in one would derive an empty roster anyway —
    /// and refusing it by name is what stops a forged "root" being adopted silently.
    @Test func aLedgerWhoseRootIsNotSelfAdmittedIsRefused() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        var rootless = MeshMembershipLedger.empty
        rootless.admissions = rootless.admissions
            .inserting(try fixture.admission(of: fixture.admitter, by: fixture.founder))
        let own = try fixture.admission(of: fixture.joiner, by: fixture.admitter)

        let outcome = MeshLedgerAdoption.adopt(
            offered: rootless, ownAdmission: own, meshID: fixture.meshID
        )

        guard case .refused(let refusal) = outcome else {
            Issue.record("a ledger with no self-admitted root must be refused")
            return
        }
        #expect(refusal == .rootNotSelfAdmitted)
    }

    /// A ledger for another mesh is a refusal, not a difference — records never cross meshes.
    @Test func aForeignLedgerIsRefused() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let own = try fixture.admission(of: fixture.joiner, by: fixture.admitter)

        let outcome = MeshLedgerAdoption.adopt(
            offered: try fixture.fullLedger(), ownAdmission: own, meshID: UUID()
        )

        guard case .refused(let refusal) = outcome else {
            Issue.record("a foreign ledger must be refused")
            return
        }
        #expect(refusal == .foreignMesh)
    }

    /// Plan §10.5's convergence, and the reason the admission needed a frame at all: all three
    /// devices derive the SAME roster, and the joiner is in the set the next rotation wraps the
    /// group key for. An admission that stopped at its admitter would leave C on nobody else's
    /// roster and therefore out of the key distribution — silently.
    @Test func threeNodesConvergeAndTheJoinerIsInTheKeyDistribution() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let full = try fixture.fullLedger()
        let own = try fixture.admission(of: fixture.joiner, by: fixture.admitter)

        var founderView = MeshMembershipRecordVerifier(
            meshID: fixture.meshID, founderSigningPublicKey: fixture.founder.localSigningPublicKey
        )
        founderView.merge(full)
        var admitterView = MeshMembershipRecordVerifier(
            meshID: fixture.meshID, founderSigningPublicKey: fixture.founder.localSigningPublicKey
        )
        admitterView.merge(full)
        guard case .adopted(let joinerView) = MeshLedgerAdoption.adopt(
            offered: full, ownAdmission: own, meshID: fixture.meshID
        ) else {
            Issue.record("the joiner must adopt")
            return
        }

        let expected = [
            fixture.founder.localFingerprint,
            fixture.admitter.localFingerprint,
            fixture.joiner.localFingerprint
        ].sorted()
        #expect(founderView.roster.memberFingerprints == expected)
        #expect(admitterView.roster.memberFingerprints == expected)
        #expect(joinerView.roster.memberFingerprints == expected)
        let recipients = MeshRotationPolicy.recipients(
            acked: Set(expected),
            selfFingerprint: fixture.founder.localFingerprint,
            derivedRoster: founderView.roster,
            locallyRemoved: []
        )
        #expect(recipients.contains(fixture.joiner.localFingerprint),
                "a member the founder learned of by record must receive the next epoch's key")
    }
}

// MARK: - The shipping authority (plan §20.1, §20.4.4)

/// P3 item 7: `MeshIntroductionAuthority.roster` is the derived roster, and matrix row 3 is its own
/// answer rather than a chaos hook's.
@MainActor
@Suite(.serialized)
struct MeshIntroductionAuthorityRosterTests {

    let store = makeTestStore()

    private func makeIdentity() throws -> (IdentityService, String) {
        let id = "com.fernlet.mesh-authority-roster.test.\(UUID().uuidString)"
        let service = IdentityService(keychainService: id)
        try service.ensureProvisioned()
        return (service, id)
    }

    private func makeMesh(_ manager: MeshNetworkManager, meshID: UUID, members: [MeshMember]) -> MeshDescriptor {
        let now = Date()
        return MeshDescriptor(
            meshID: meshID,
            name: "Authority Acre",
            mode: .open,
            members: members,
            nameSetAt: now,
            nameSetBy: manager.identityForTesting.localFingerprint,
            modeSetAt: now,
            modeSetBy: manager.identityForTesting.localFingerprint,
            createdAt: now
        )
    }

    private func member(_ identity: IdentityService) -> MeshMember {
        MeshMember(
            fingerprint: identity.localFingerprint,
            displayName: "Peer",
            signingPublicKey: identity.localSigningPublicKey,
            keyAgreementPublicKey: identity.localKeyAgreementPublicKey,
            joinedAt: Date()
        )
    }

    /// The three verdicts, all three read off signed records: a member, a member with a verified
    /// departure record (`barred`, plan §20.1's gap), and a key this mesh never admitted.
    @Test func theAuthorityAnswersMemberBarredAndUnknownFromRecords() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let (stranger, sid) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: sid) }
        let manager = MeshNetworkManager(store: store)
        var ledger = try fixture.fullLedger()
        ledger.departures = ledger.departures.inserting(
            try SignedDepartureRecord.signed(meshID: fixture.meshID, identity: fixture.joiner)
        )
        manager.currentMesh = makeMesh(manager, meshID: fixture.meshID, members: [])
        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: fixture.founder.localSigningPublicKey,
            ledger: ledger
        )

        let roster = manager.roster

        #expect(roster.verdict(for: fixture.founder.localSigningPublicKey) == .member)
        #expect(roster.verdict(for: fixture.joiner.localSigningPublicKey) == .barred,
                "a departed member is now NAMED as barred, not silently absent (plan §20.1)")
        #expect(roster.verdict(for: stranger.localSigningPublicKey) == .stranger)
        manager.leaveMesh()
    }

    /// Matrix row 3 as the shipping answer: a peer holding a verified removal record is refused at
    /// the signed introduction with the named reason, from the manager's own roster and with no
    /// chaos hook in the process.
    @Test func aRemovedMemberIsRefusedAtTheIntroductionByTheShippingAuthority() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store)
        var ledger = try fixture.fullLedger()
        ledger.removals = ledger.removals.inserting(try SignedRemovalRecord.signed(
            meshID: fixture.meshID,
            identity: fixture.founder,
            memberFingerprint: fixture.joiner.localFingerprint,
            proposalID: UUID(),
            voterFingerprints: [fixture.founder.localFingerprint, fixture.admitter.localFingerprint]
        ))
        manager.currentMesh = makeMesh(manager, meshID: fixture.meshID, members: [])
        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: fixture.founder.localSigningPublicKey,
            ledger: ledger
        )
        let localHello = MeshChannelHello(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion,
            meshID: fixture.meshID,
            epochRef: "",
            signingPublicKey: manager.identityForTesting.localSigningPublicKey,
            nonce: MeshChannelIntroductionFormat.randomNonce(),
            sessionID: "local"
        )
        let removedHello = MeshChannelHello(
            protocolVersion: MeshChannelIntroductionFormat.protocolVersion,
            meshID: fixture.meshID,
            epochRef: "",
            signingPublicKey: fixture.joiner.localSigningPublicKey,
            nonce: MeshChannelIntroductionFormat.randomNonce(),
            sessionID: "removed"
        )
        var exchange = MeshChannelIntroductionExchange(role: .responder, localHello: localHello)
        var nonces = MeshIntroductionNonceCache()

        let rejection = exchange.receive(removedHello, roster: manager.roster, nonces: &nonces)

        #expect(rejection == .barredMember,
                "the removal record — not a chaos hook — is what refuses this peer")
        #expect(exchange.derivedTranscript == nil)
        manager.leaveMesh()
    }

    /// The gossip fallback is reachable only with no ledger at all, and it says so once. A roster
    /// that came from a descriptor rather than from signed records is a fact the log must carry —
    /// silently answering from gossip is how a removal stops being enforced without anyone noticing.
    @Test func theLegacyFallbackIsUsedOnlyWithAnEmptyLedgerAndIsLogged() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let capture = MeshAuthorityAuditCapture()
        capture.install()
        defer { capture.uninstall() }
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(
            manager, meshID: fixture.meshID, members: [member(fixture.founder)]
        )

        let fallback = manager.roster

        #expect(fallback.memberCount == 1, "with no ledger the descriptor is all there is")
        #expect(capture.count("mesh.introductionAuthority.legacyRosterFallback") == 1)

        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: fixture.founder.localSigningPublicKey,
            ledger: try fixture.fullLedger()
        )
        let derived = manager.roster

        #expect(derived.memberCount == 3, "records outrank gossip once there are any")
        #expect(capture.count("mesh.introductionAuthority.legacyRosterFallback") == 1,
                "and the fallback is not taken again")
        manager.leaveMesh()
    }
}

// MARK: - Convergence and the edges it unblocks

/// P3 item 7 on the manager: the joiner's ledger arriving over the real receive path, the digest's
/// answer half, item 3b's local insert, and plan §8.2's `terminationVerified` edge.
@MainActor
@Suite(.serialized)
struct MeshLedgerConvergenceTests {

    let store = makeTestStore()

    /// A pinned install identity, so every seal in this suite is deterministic.
    private static let install = Data(repeating: 0x4C, count: 16)

    private func makeMesh(_ manager: MeshNetworkManager, meshID: UUID) -> MeshDescriptor {
        let now = Date()
        let local = MeshMember(
            fingerprint: manager.identityForTesting.localFingerprint,
            displayName: "Local",
            signingPublicKey: manager.identityForTesting.localSigningPublicKey,
            keyAgreementPublicKey: manager.identityForTesting.localKeyAgreementPublicKey,
            joinedAt: now
        )
        return MeshDescriptor(
            meshID: meshID,
            name: "Converge Cove",
            mode: .open,
            members: [local],
            nameSetAt: now,
            nameSetBy: local.fingerprint,
            modeSetAt: now,
            modeSetBy: local.fingerprint,
            createdAt: now
        )
    }

    /// A coordinator with no live dependencies, for slots this suite only needs to exist.
    private static func throwawayCoordinator() -> ProximityCoordinator {
        ProximityCoordinator(
            identity: IdentityService(keychainService: "test.mesh.converge.\(UUID().uuidString)"),
            transport: MockMultipeerTransport(),
            ranging: MockRangingProvider(),
            inspector: nil,
            replayCache: ReplayCache(),
            foregroundAnchor: nil,
            displayName: "Local",
            timeoutSeconds: 0
        )
    }

    @discardableResult
    private func attachSlot(to manager: MeshNetworkManager, fingerprint: String) -> ProximityCoordinator {
        let coordinator = Self.throwawayCoordinator()
        manager.addSlotForTesting(
            coordinator: coordinator,
            peer: PeerHandle(
                id: UUID(),
                displayHint: "iPhone",
                discoveryInfo: ["v": "1"],
                advertisedFingerprint: fingerprint,
                endpoint: PeerEndpointKey()
            ),
            fingerprint: fingerprint
        )
        return coordinator
    }

    /// Delivers one membership frame through the REAL receive entry point, under a pinned install
    /// so the seal the receive path owes can actually be written.
    private func deliver(
        _ payload: some Encodable,
        type: PayloadType,
        to manager: MeshNetworkManager,
        from sender: IdentityService,
        over coordinator: ProximityCoordinator
    ) throws {
        let plaintext = try JSONEncoder().encode(payload)
        let envelope = try FernletIdentityEnvelope.signed(
            identityService: sender,
            senderDisplayName: "Peer",
            payloadType: type,
            payloadSummary: PayloadSummary(title: "Membership"),
            payload: plaintext
        )
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.proximityCoordinator(coordinator, didReceive: envelope, plaintext: plaintext, from: nil)
        }
    }

    /// The joiner's round trip, end to end on the receive path: it arms a bootstrap ledger from the
    /// grant it verified, buffers the re-gossiped records it cannot yet insert, and rebases onto the
    /// founder's ledger the moment the chain to its admitter is complete — no second round trip.
    @Test func aJoinerConvergesFromOneReGossip() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager, meshID: fixture.meshID)
        let grant = MeshAdmissionGrantPayload(
            meshID: fixture.meshID,
            requesterFingerprint: manager.identityForTesting.localFingerprint,
            token: try MeshAdmissionToken.signed(
                meshID: fixture.meshID,
                joinerFingerprint: manager.identityForTesting.localFingerprint,
                joinerSigningPublicKey: manager.identityForTesting.localSigningPublicKey,
                admitterIdentity: fixture.admitter
            )
        )
        let armed = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.armJoinerLedger(grant)
        }
        #expect(armed, "a verified admission arms the joiner's ledger")
        #expect(manager.membershipVerifier?.roster.memberCount == 1)
        let coordinator = attachSlot(to: manager, fingerprint: fixture.admitter.localFingerprint)

        // The admitter's bounded re-gossip: the founder's self-admission, then its own.
        try deliver(
            MeshMemberAdmissionPayload(record: try fixture.founderAdmission()),
            type: .meshMemberAdmission, to: manager, from: fixture.admitter, over: coordinator
        )
        #expect(manager.membershipVerifier?.roster.memberCount == 1,
                "one record short of the chain, the joiner stays on its bootstrap ledger")
        try deliver(
            MeshMemberAdmissionPayload(
                record: try fixture.admission(of: fixture.admitter, by: fixture.founder)
            ),
            type: .meshMemberAdmission, to: manager, from: fixture.admitter, over: coordinator
        )

        #expect(manager.membershipVerifier?.roster.memberFingerprints == [
            fixture.founder.localFingerprint,
            fixture.admitter.localFingerprint,
            manager.identityForTesting.localFingerprint
        ].sorted(), "the chain completed, so the joiner rebased onto the founder's ledger")
        #expect(manager.membershipVerifier?.founderSigningPublicKey
                == fixture.founder.localSigningPublicKey)
        manager.leaveMesh()
    }

    /// The answer half of plan §10.5: a member whose digest says it holds fewer records is sent
    /// them, as the frames that already carry them — and only once per peer, so a peer cannot spend
    /// this device's bytes by re-asking.
    @Test func aDifferingDigestIsAnsweredWithABoundedReGossip() async throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager, meshID: fixture.meshID)
        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: fixture.founder.localSigningPublicKey,
            ledger: try fixture.fullLedger()
        )
        let coordinator = attachSlot(to: manager, fingerprint: fixture.joiner.localFingerprint)
        var emitted: [PayloadType] = []
        manager.onMembershipEventSentForTesting = { emitted.append($0) }
        var behind = MeshMembershipLedger.empty
        behind.admissions = behind.admissions.inserting(
            try fixture.admission(of: fixture.joiner, by: fixture.admitter)
        )
        let digest = try MeshInventoryDigestPayload.signed(
            meshID: fixture.meshID, ledger: behind, identity: fixture.joiner
        )

        try deliver(
            digest, type: .meshInventoryDigest, to: manager, from: fixture.joiner, over: coordinator
        )
        var yields = 0
        while emitted.count < 3, yields < 200 {
            await Task.yield()
            yields += 1
        }

        #expect(emitted == [.meshMemberAdmission, .meshMemberAdmission, .meshMemberAdmission],
                "the whole ledger is re-gossiped as the frames that already carry it")
        manager.leaveMesh()
    }

    /// Item 3b's open gap, closed: the vote site's LOCAL insert was refused `signerNotAdmitted` on
    /// every node but the founder, because no node but the founder held a ledger. A member that
    /// adopted one files its own removal record like anybody else.
    @Test func aNonFounderFilesItsOwnRemovalRecord() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store)
        manager.currentMesh = makeMesh(manager, meshID: fixture.meshID)
        // This device is the JOINER: admitted by the admitter, itself admitted by the founder.
        var ledger = MeshMembershipLedger.empty
        ledger.admissions = ledger.admissions
            .inserting(try fixture.founderAdmission())
            .inserting(try fixture.admission(of: fixture.admitter, by: fixture.founder))
            .inserting(SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                meshID: fixture.meshID,
                joinerFingerprint: manager.identityForTesting.localFingerprint,
                joinerSigningPublicKey: manager.identityForTesting.localSigningPublicKey,
                admitterIdentity: fixture.admitter
            )))
        manager.seedMembershipLedgerForTesting(
            meshID: fixture.meshID,
            founderSigningPublicKey: fixture.founder.localSigningPublicKey,
            ledger: ledger
        )

        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.secondRemoval(MeshRemovalProposalPayload(
                id: UUID(),
                targetFingerprint: fixture.admitter.localFingerprint,
                targetDisplayName: "Target",
                proposerFingerprint: fixture.founder.localFingerprint,
                proposerDisplayName: "Proposer",
                createdAt: Date(),
                expiresAt: Date().addingTimeInterval(60)
            ))
        }

        #expect(manager.membershipVerifier?.ledger.removals.count == 1,
                "a non-founder now files the record it signed (item 3b's gap)")
        #expect(manager.membershipVerifier?.roster.contains(
            fingerprint: fixture.admitter.localFingerprint
        ) == false)
        manager.leaveMesh()
    }

    /// Plan §8.2's `terminationVerified` edge, wired: a final-pair partner's signed record ends
    /// this device's session and bars the rejoin.
    @Test func aVerifiedTerminationEndsTheSession() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.startNewMesh(name: "Final Pair")
        }
        guard let meshID = manager.currentMesh?.meshID else {
            Issue.record("founding must produce a mesh")
            return
        }
        // A two-member roster: this device (the founder) and the peer that will terminate.
        var ledger = MeshMembershipLedger.empty
        ledger.admissions = ledger.admissions
            .inserting(SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                meshID: meshID,
                joinerFingerprint: manager.identityForTesting.localFingerprint,
                joinerSigningPublicKey: manager.identityForTesting.localSigningPublicKey,
                admitterIdentity: manager.identityForTesting
            )))
            .inserting(SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                meshID: meshID,
                joinerFingerprint: fixture.admitter.localFingerprint,
                joinerSigningPublicKey: fixture.admitter.localSigningPublicKey,
                admitterIdentity: manager.identityForTesting
            )))
        manager.seedMembershipLedgerForTesting(
            meshID: meshID,
            founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey,
            ledger: ledger
        )
        let coordinator = attachSlot(to: manager, fingerprint: fixture.admitter.localFingerprint)

        try deliver(
            MeshTerminationPayload(record: try SignedTerminationRecord.signed(
                meshID: meshID,
                identity: fixture.admitter,
                rosterAtSigning: [
                    manager.identityForTesting.localFingerprint, fixture.admitter.localFingerprint
                ].sorted()
            )),
            type: .meshTerminated, to: manager, from: fixture.admitter, over: coordinator
        )

        #expect(manager.sessionState == .terminated, "a final-pair termination ends the mesh")
        #expect(manager.rejoinBar?.meshID == meshID, "and a terminated mesh can never be rejoined")
    }

    /// The other branch of plan §8.3's rule: a termination signed by a member of a roster LARGER
    /// than two is a partitioned member's mistake. It downgrades to that signer's departure — the
    /// mesh survives, this device stays in it, and the signer is the only one who left.
    @Test func aTerminationFromALargerRosterDowngradesToADeparture() throws {
        let fixture = try MeshLedgerChainFixture()
        defer { fixture.tearDown() }
        let manager = MeshNetworkManager(store: store)
        DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            manager.startNewMesh(name: "Three Up")
        }
        guard let meshID = manager.currentMesh?.meshID else {
            Issue.record("founding must produce a mesh")
            return
        }
        var ledger = MeshMembershipLedger.empty
        for joined in [manager.identityForTesting, fixture.admitter, fixture.joiner] {
            ledger.admissions = ledger.admissions.inserting(
                SignedAdmissionRecord(token: try MeshAdmissionToken.signed(
                    meshID: meshID,
                    joinerFingerprint: joined.localFingerprint,
                    joinerSigningPublicKey: joined.localSigningPublicKey,
                    admitterIdentity: manager.identityForTesting
                ))
            )
        }
        manager.seedMembershipLedgerForTesting(
            meshID: meshID,
            founderSigningPublicKey: manager.identityForTesting.localSigningPublicKey,
            ledger: ledger
        )
        let coordinator = attachSlot(to: manager, fingerprint: fixture.admitter.localFingerprint)

        try deliver(
            MeshTerminationPayload(record: try SignedTerminationRecord.signed(
                meshID: meshID,
                identity: fixture.admitter,
                rosterAtSigning: [
                    manager.identityForTesting.localFingerprint, fixture.admitter.localFingerprint
                ].sorted()
            )),
            type: .meshTerminated, to: manager, from: fixture.admitter, over: coordinator
        )

        #expect(manager.sessionState != .terminated, "a roster of three is not a final pair")
        #expect(manager.membershipVerifier?.roster.status == .active)
        #expect(manager.membershipVerifier?.roster.contains(
            fingerprint: fixture.admitter.localFingerprint
        ) == false, "the wrongly-issued termination cost its signer their own membership")
        #expect(manager.membershipVerifier?.roster.contains(
            fingerprint: manager.identityForTesting.localFingerprint
        ) == true)
        manager.leaveMesh()
    }
}

// MARK: - Audit capture

/// Counts audit events for one test, installed on entry and removed by token on teardown so it does
/// not outlive the test that installed it.
private final class MeshAuthorityAuditCapture {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var token: UUID?

    /// Starts capturing.
    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, _ in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append(event)
            self.lock.unlock()
        }
    }

    /// Stops capturing.
    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    /// How many times `event` was logged.
    func count(_ event: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return storedEvents.filter { $0 == event }.count
    }
}
