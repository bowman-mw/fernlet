import XCTest
import FernletFoundation
import FernletDomainModel
@testable import ProximityKit

/// Group Activities (Phase 6) — token/snapshot crypto + the host→join→grant flow through
/// `ProximityActivityManager`. The join-token verification is the security-critical surface (this is the
/// suite the adversarial review targets): a token must verify only for the exact activity, params, and
/// invitee key it was minted for, and only while unexpired.
@MainActor
final class ActivityTests: XCTestCase {

    private let fixedNow = Date(timeIntervalSince1970: 1_800_000_000)
    private var keychainServices: [String] = []

    override func tearDown() {
        for service in keychainServices { KeychainItem.deleteAll(service: service) }
        keychainServices = []
        super.tearDown()
    }

    private func makeIdentity() throws -> IdentityService {
        let service = "com.fernlet.proximity.activity.test.\(UUID().uuidString)"
        keychainServices.append(service)
        let identity = IdentityService(keychainService: service)
        try identity.ensureProvisioned()
        return identity
    }

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
    }

    private func descriptor(host: IdentityService, id: UUID = UUID(), expiresAt: Date) -> ActivityDescriptor {
        ActivityDescriptor(
            activityID: id,
            hostFingerprint: host.localFingerprint,
            hostSigningPublicKey: host.localSigningPublicKey,
            title: "Sunset walk",
            activityTypeToken: "walk",
            coarseLocation: "the park",
            createdAt: fixedNow,
            expiresAt: expiresAt
        )
    }

    // MARK: - Token sign → verify

    func testTokenSignVerifyRoundTrip() throws {
        let host = try makeIdentity()
        let joiner = try makeIdentity()
        let desc = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(3600))
        let hash = ActivityParamsHash.of(desc)
        let token = try ActivityJoinToken.signed(
            activityID: desc.activityID, activityParamsHash: hash,
            joinerFingerprint: joiner.localFingerprint, joinerSigningPublicKey: joiner.localSigningPublicKey,
            hostIdentity: host, grantedAt: fixedNow, expiresAt: desc.expiresAt, rosterVersionAtGrant: 2)
        // Correct key + activity + params + host + time → no throw.
        XCTAssertNoThrow(try token.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            expectedActivityID: desc.activityID, expectedParamsHash: hash,
            expectedHostSigningPublicKey: host.localSigningPublicKey, now: fixedNow))
    }

    func testTokenForActivityARejectedForActivityB() throws {
        let host = try makeIdentity()
        let joiner = try makeIdentity()
        let descA = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(3600))
        let hashA = ActivityParamsHash.of(descA)
        let token = try ActivityJoinToken.signed(
            activityID: descA.activityID, activityParamsHash: hashA,
            joinerFingerprint: joiner.localFingerprint, joinerSigningPublicKey: joiner.localSigningPublicKey,
            hostIdentity: host, grantedAt: fixedNow, expiresAt: descA.expiresAt, rosterVersionAtGrant: 1)
        let otherActivityID = UUID()
        XCTAssertThrowsError(try token.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            expectedActivityID: otherActivityID, expectedParamsHash: hashA,
            expectedHostSigningPublicKey: host.localSigningPublicKey, now: fixedNow)) { error in
            XCTAssertEqual(error as? ActivityJoinToken.VerifyError, .activityMismatch)
        }
    }

    func testExpiredTokenRejected() throws {
        let host = try makeIdentity()
        let joiner = try makeIdentity()
        let desc = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(60))
        let hash = ActivityParamsHash.of(desc)
        let token = try ActivityJoinToken.signed(
            activityID: desc.activityID, activityParamsHash: hash,
            joinerFingerprint: joiner.localFingerprint, joinerSigningPublicKey: joiner.localSigningPublicKey,
            hostIdentity: host, grantedAt: fixedNow, expiresAt: desc.expiresAt, rosterVersionAtGrant: 1)
        // One second past expiry.
        XCTAssertThrowsError(try token.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            expectedActivityID: desc.activityID, expectedParamsHash: hash,
            expectedHostSigningPublicKey: host.localSigningPublicKey,
            now: desc.expiresAt.addingTimeInterval(1))) { error in
            XCTAssertEqual(error as? ActivityJoinToken.VerifyError, .expired)
        }
    }

    func testParamsHashMismatchRejected() throws {
        let host = try makeIdentity()
        let joiner = try makeIdentity()
        let desc = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(3600))
        let hash = ActivityParamsHash.of(desc)
        let token = try ActivityJoinToken.signed(
            activityID: desc.activityID, activityParamsHash: hash,
            joinerFingerprint: joiner.localFingerprint, joinerSigningPublicKey: joiner.localSigningPublicKey,
            hostIdentity: host, grantedAt: fixedNow, expiresAt: desc.expiresAt, rosterVersionAtGrant: 1)
        // A descriptor with a different title hashes differently — a host can't swap params post-pin.
        var tampered = desc
        tampered = ActivityDescriptor(
            activityID: desc.activityID, hostFingerprint: desc.hostFingerprint,
            hostSigningPublicKey: desc.hostSigningPublicKey, title: "Different plan",
            activityTypeToken: desc.activityTypeToken, coarseLocation: desc.coarseLocation,
            createdAt: desc.createdAt, expiresAt: desc.expiresAt)
        let differentHash = ActivityParamsHash.of(tampered)
        XCTAssertNotEqual(hash, differentHash)
        XCTAssertThrowsError(try token.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            expectedActivityID: desc.activityID, expectedParamsHash: differentHash,
            expectedHostSigningPublicKey: host.localSigningPublicKey, now: fixedNow)) { error in
            XCTAssertEqual(error as? ActivityJoinToken.VerifyError, .paramsHashMismatch)
        }
    }

    func testJoinerKeyBindingRejectsWrongPresentedKey() throws {
        let host = try makeIdentity()
        let joiner = try makeIdentity()
        let attacker = try makeIdentity()
        let desc = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(3600))
        let hash = ActivityParamsHash.of(desc)
        let token = try ActivityJoinToken.signed(
            activityID: desc.activityID, activityParamsHash: hash,
            joinerFingerprint: joiner.localFingerprint, joinerSigningPublicKey: joiner.localSigningPublicKey,
            hostIdentity: host, grantedAt: fixedNow, expiresAt: desc.expiresAt, rosterVersionAtGrant: 1)
        // A token bound to the joiner's key can't be verified by a device holding a different key.
        XCTAssertThrowsError(try token.verify(
            joinerSigningPublicKey: attacker.localSigningPublicKey,
            expectedActivityID: desc.activityID, expectedParamsHash: hash,
            expectedHostSigningPublicKey: host.localSigningPublicKey, now: fixedNow)) { error in
            XCTAssertEqual(error as? ActivityJoinToken.VerifyError, .joinerKeyMismatch)
        }
    }

    func testTamperedTokenSignatureRejected() throws {
        let host = try makeIdentity()
        let joiner = try makeIdentity()
        let desc = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(3600))
        let hash = ActivityParamsHash.of(desc)
        let token = try ActivityJoinToken.signed(
            activityID: desc.activityID, activityParamsHash: hash,
            joinerFingerprint: joiner.localFingerprint, joinerSigningPublicKey: joiner.localSigningPublicKey,
            hostIdentity: host, grantedAt: fixedNow, expiresAt: desc.expiresAt, rosterVersionAtGrant: 1)
        // Re-issue the SAME signature over a token whose expiry was pushed out — the signature no longer
        // covers the bytes.
        let tampered = ActivityJoinToken(
            schemaVersion: token.schemaVersion, activityID: token.activityID,
            activityParamsHash: token.activityParamsHash, joinerFingerprint: token.joinerFingerprint,
            joinerSigningPublicKey: token.joinerSigningPublicKey, hostFingerprint: token.hostFingerprint,
            hostSigningPublicKey: token.hostSigningPublicKey, grantedAt: token.grantedAt,
            expiresAt: token.expiresAt.addingTimeInterval(999_999), rosterVersionAtGrant: token.rosterVersionAtGrant,
            hostSignature: token.hostSignature)
        XCTAssertThrowsError(try tampered.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            expectedActivityID: desc.activityID, expectedParamsHash: hash,
            expectedHostSigningPublicKey: host.localSigningPublicKey, now: fixedNow)) { error in
            XCTAssertEqual(error as? ActivityJoinToken.VerifyError, .signatureInvalid)
        }
    }

    func testTokenSignedByWrongHostRejected() throws {
        let host = try makeIdentity()
        let imposter = try makeIdentity()
        let joiner = try makeIdentity()
        let desc = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(3600))
        // `activityParamsHash` is public, so an imposter can mint a token over the real descriptor's hash
        // but sign it with its OWN host key. verify() must reject it because it pins the host key the
        // joiner captured from the offer — the token is self-sufficient as "the authorization" (L1).
        let hash = ActivityParamsHash.of(desc)
        let token = try ActivityJoinToken.signed(
            activityID: desc.activityID, activityParamsHash: hash,
            joinerFingerprint: joiner.localFingerprint, joinerSigningPublicKey: joiner.localSigningPublicKey,
            hostIdentity: imposter, grantedAt: fixedNow, expiresAt: desc.expiresAt, rosterVersionAtGrant: 1)
        XCTAssertThrowsError(try token.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            expectedActivityID: desc.activityID, expectedParamsHash: hash,
            expectedHostSigningPublicKey: host.localSigningPublicKey, now: fixedNow)) { error in
            XCTAssertEqual(error as? ActivityJoinToken.VerifyError, .hostKeyMismatch)
        }
        // But it DOES verify under its own (imposter) host key — proving the pin is the differentiator.
        XCTAssertNoThrow(try token.verify(
            joinerSigningPublicKey: joiner.localSigningPublicKey,
            expectedActivityID: desc.activityID, expectedParamsHash: hash,
            expectedHostSigningPublicKey: imposter.localSigningPublicKey, now: fixedNow))
    }

    // MARK: - Roster snapshot

    func testRosterSnapshotVerifyAndPinnedHostKey() throws {
        let host = try makeIdentity()
        let other = try makeIdentity()
        let activityID = UUID()
        let hostParticipant = ActivityParticipant(
            fingerprint: host.localFingerprint, displayName: "Host",
            signingPublicKey: host.localSigningPublicKey, keyAgreementPublicKey: host.localKeyAgreementPublicKey,
            joinedAt: fixedNow)
        let snapshot = try ActivityRosterSnapshot.signed(
            activityID: activityID, version: 3, participants: [hostParticipant], issuedAt: fixedNow, hostIdentity: host)
        XCTAssertNoThrow(try snapshot.verify(
            expectedActivityID: activityID, expectedHostSigningPublicKey: host.localSigningPublicKey))
        // Pinned to the wrong host key → rejected.
        XCTAssertThrowsError(try snapshot.verify(
            expectedActivityID: activityID, expectedHostSigningPublicKey: other.localSigningPublicKey)) { error in
            XCTAssertEqual(error as? ActivityRosterSnapshot.VerifyError, .hostKeyMismatch)
        }
        // Wrong activity id → rejected.
        XCTAssertThrowsError(try snapshot.verify(
            expectedActivityID: UUID(), expectedHostSigningPublicKey: host.localSigningPublicKey)) { error in
            XCTAssertEqual(error as? ActivityRosterSnapshot.VerifyError, .activityMismatch)
        }
    }

    func testOversizedRosterRejected() throws {
        let host = try makeIdentity()
        let activityID = UUID()
        var participants: [ActivityParticipant] = []
        for i in 0...ActivityLimits.maxParticipants {  // one over the cap
            participants.append(ActivityParticipant(
                fingerprint: "fp\(i)", displayName: "P\(i)",
                signingPublicKey: Data([UInt8(i)]), keyAgreementPublicKey: Data([UInt8(i)]), joinedAt: fixedNow))
        }
        let snapshot = try ActivityRosterSnapshot.signed(
            activityID: activityID, version: 1, participants: participants, issuedAt: fixedNow, hostIdentity: host)
        XCTAssertThrowsError(try snapshot.verify(
            expectedActivityID: activityID, expectedHostSigningPublicKey: host.localSigningPublicKey)) { error in
            XCTAssertEqual(error as? ActivityRosterSnapshot.VerifyError, .rosterTooLarge)
        }
    }

    // MARK: - Descriptor / payload contracts

    func testExpiryClampedToSevenDays() {
        let created = fixedNow
        let tenDays = created.addingTimeInterval(10 * 24 * 3600)
        let clamped = ActivityDescriptor.clampedExpiry(createdAt: created, requested: tenDays)
        XCTAssertEqual(clamped, created.addingTimeInterval(ActivityLimits.maxLifetime))
        // A sane request is left alone.
        let oneDay = created.addingTimeInterval(24 * 3600)
        XCTAssertEqual(ActivityDescriptor.clampedExpiry(createdAt: created, requested: oneDay), oneDay)
        // A non-positive request falls back to the ceiling.
        XCTAssertEqual(ActivityDescriptor.clampedExpiry(createdAt: created, requested: created),
                       created.addingTimeInterval(ActivityLimits.maxLifetime))
    }

    func testPayloadWireFormatStableAndWellFormed() throws {
        // Lock the wire rawValues (older clients park unknown tokens; these five must never drift).
        XCTAssertEqual(PayloadType.activityOffer.rawValue, "fernlet.activity.offer.v1")
        XCTAssertEqual(PayloadType.activityJoinRequest.rawValue, "fernlet.activity.join.request.v1")
        XCTAssertEqual(PayloadType.activityJoinGrant.rawValue, "fernlet.activity.join.grant.v1")
        XCTAssertEqual(PayloadType.activityRosterSnapshot.rawValue, "fernlet.activity.roster.v1")
        XCTAssertEqual(PayloadType.activitySync.rawValue, "fernlet.activity.sync.v1")
        // A future/unknown activity token is not a known case → the envelope parks it (no brick).
        XCTAssertNil(PayloadType(rawValue: "fernlet.activity.future.v9"))

        let host = try makeIdentity()
        let desc = descriptor(host: host, expiresAt: fixedNow.addingTimeInterval(3600))
        let offer = ActivityOfferPayload(descriptor: desc, rosterVersion: 1)
        let round = try JSONDecoder().decode(ActivityOfferPayload.self, from: JSONEncoder().encode(offer))
        XCTAssertTrue(round.isWellFormed)
        XCTAssertEqual(round.descriptor.activityID, desc.activityID)
        // A bumped version fails the shape check (forward-tolerant boundary).
        var bumped = offer
        bumped.version = 2
        XCTAssertFalse(bumped.isWellFormed)
    }

    // MARK: - End-to-end through the managers

    func testEndToEndHostOfferJoinGrant() async throws {
        let hostId = try makeIdentity()
        let joinerId = try makeIdentity()
        // Retain the mock hosts: the manager holds `store` unowned (it points back at the owner in
        // production), so an inline temporary would deallocate and dangle.
        let hostHost = MockActivityHost(name: "Ada")
        let joinerHost = MockActivityHost(name: "Bo")
        let host = ProximityActivityManager(store: hostHost, identity: hostId, fileURL: tempURL(), now: { self.fixedNow })
        let joiner = ProximityActivityManager(store: joinerHost, identity: joinerId, fileURL: tempURL(), now: { self.fixedNow })
        connect(host: host, hostId: hostId, joiner: joiner, joinerId: joinerId)

        // Host creates an activity → offer flows to the joiner.
        let desc = host.host(title: "Coffee", activityTypeToken: "coffee", coarseLocation: "Blue Bottle",
                             expiresAt: fixedNow.addingTimeInterval(3600))
        XCTAssertNotNil(desc)
        await drain()
        XCTAssertEqual(joiner.offeredActivities.count, 1)
        XCTAssertEqual(joiner.offeredActivities.first?.descriptor.activityID, desc?.activityID)

        // Joiner asks to join → host queues a pending request bound to the joiner's verified key.
        joiner.requestJoin(joiner.offeredActivities[0])
        await drain()
        XCTAssertEqual(host.pendingJoinRequests.count, 1)
        XCTAssertEqual(host.pendingJoinRequests.first?.verifiedFingerprint, joinerId.localFingerprint)

        // Host admits → signed grant flows back → joiner verifies + persists membership.
        host.admitJoin(host.pendingJoinRequests[0])
        await drain()
        XCTAssertTrue(host.pendingJoinRequests.isEmpty)
        XCTAssertEqual(host.hostedActivities.first?.participants.count, 2)
        XCTAssertEqual(joiner.joinedActivities.count, 1)
        let joined = try XCTUnwrap(joiner.joinedActivities.first)
        XCTAssertEqual(joined.descriptor.activityID, desc?.activityID)
        XCTAssertEqual(joined.lastSnapshot.participants.count, 2)
        XCTAssertTrue(joiner.offeredActivities.isEmpty)  // consumed
    }

    func testGrantForUnofferedActivityRefused() async throws {
        let hostId = try makeIdentity()
        let joinerId = try makeIdentity()
        let joinerHost = MockActivityHost(name: "Bo")
        let joiner = ProximityActivityManager(store: joinerHost, identity: joinerId, fileURL: tempURL(), now: { self.fixedNow })
        // A well-formed grant for an activity the joiner was NEVER offered in person.
        let desc = descriptor(host: hostId, expiresAt: fixedNow.addingTimeInterval(3600))
        let hash = ActivityParamsHash.of(desc)
        let token = try ActivityJoinToken.signed(
            activityID: desc.activityID, activityParamsHash: hash,
            joinerFingerprint: joinerId.localFingerprint, joinerSigningPublicKey: joinerId.localSigningPublicKey,
            hostIdentity: hostId, grantedAt: fixedNow, expiresAt: desc.expiresAt, rosterVersionAtGrant: 1)
        let snapshot = try ActivityRosterSnapshot.signed(
            activityID: desc.activityID, version: 1,
            participants: [ActivityParticipant(fingerprint: hostId.localFingerprint, displayName: "Host",
                signingPublicKey: hostId.localSigningPublicKey, keyAgreementPublicKey: hostId.localKeyAgreementPublicKey,
                joinedAt: fixedNow)],
            issuedAt: fixedNow, hostIdentity: hostId)
        joiner.receiveGrant(ActivityJoinGrantPayload(token: token, snapshot: snapshot), fromFingerprint: hostId.localFingerprint)
        // No pinned offer → the grant is dropped. Authorization is independent of the shared handshake.
        XCTAssertTrue(joiner.joinedActivities.isEmpty)
    }

    func testRemoveParticipantBumpsVersion() async throws {
        let hostId = try makeIdentity()
        let joinerId = try makeIdentity()
        let hostHost = MockActivityHost(name: "Ada")
        let joinerHost = MockActivityHost(name: "Bo")
        let host = ProximityActivityManager(store: hostHost, identity: hostId, fileURL: tempURL(), now: { self.fixedNow })
        let joiner = ProximityActivityManager(store: joinerHost, identity: joinerId, fileURL: tempURL(), now: { self.fixedNow })
        connect(host: host, hostId: hostId, joiner: joiner, joinerId: joinerId)
        _ = host.host(title: "Study", activityTypeToken: "study", coarseLocation: nil, expiresAt: fixedNow.addingTimeInterval(3600))
        await drain()
        joiner.requestJoin(joiner.offeredActivities[0])
        await drain()
        host.admitJoin(host.pendingJoinRequests[0])
        await drain()
        let versionAfterJoin = try XCTUnwrap(host.hostedActivities.first).version
        host.removeParticipant(activityID: try XCTUnwrap(host.hostedActivities.first).descriptor.activityID,
                               fingerprint: joinerId.localFingerprint)
        await drain()
        let hosted = try XCTUnwrap(host.hostedActivities.first)
        XCTAssertEqual(hosted.participants.count, 1)  // host only
        XCTAssertGreaterThan(hosted.version, versionAfterJoin)
    }

    // MARK: - Review-fix regression tests

    /// H1: the roster (members' identities) must never be served to a committed peer who isn't in the
    /// activity — a non-member probing the sync path gets nothing back.
    func testSyncDoesNotServeRosterToNonMember() async throws {
        let hostId = try makeIdentity()
        let hostHost = MockActivityHost(name: "Ada")
        let host = ProximityActivityManager(store: hostHost, identity: hostId, fileURL: tempURL(), now: { self.fixedNow })
        let recorder = SendRecorder()
        host.send = { type, _, fingerprint, _ in recorder.record(type, fingerprint) }
        let desc = try XCTUnwrap(host.host(title: "Walk", activityTypeToken: "walk", coarseLocation: nil,
                                           expiresAt: fixedNow.addingTimeInterval(3600)))
        await drain()
        recorder.reset()
        // A stranger (not in the roster) probes the activity id — must be served nothing.
        host.receiveSync(ActivitySyncPayload(held: [.init(activityID: desc.activityID, versionHeld: 0)]),
                         fromFingerprint: "stranger-fingerprint-not-a-member")
        await drain()
        XCTAssertFalse(recorder.types.contains(.activityRosterSnapshot), "a non-member must not be served the roster")
    }

    /// M1: an offer whose descriptor lifetime blows past the 7-day ceiling (a patched host hand-crafting
    /// a far-future descriptor that would never be GC'd) is rejected on receipt.
    func testFarFutureOfferRejected() throws {
        let hostId = try makeIdentity()
        let joinerHost = MockActivityHost(name: "Bo")
        let joinerId = try makeIdentity()
        let joiner = ProximityActivityManager(store: joinerHost, identity: joinerId, fileURL: tempURL(), now: { self.fixedNow })
        let farFuture = ActivityDescriptor(
            activityID: UUID(), hostFingerprint: hostId.localFingerprint, hostSigningPublicKey: hostId.localSigningPublicKey,
            title: "Forever", activityTypeToken: "walk", coarseLocation: nil,
            createdAt: fixedNow, expiresAt: fixedNow.addingTimeInterval(100 * 365 * 24 * 3600))
        joiner.receiveOffer(ActivityOfferPayload(descriptor: farFuture, rosterVersion: 1),
                            fromFingerprint: hostId.localFingerprint, verifiedHostSigningPublicKey: hostId.localSigningPublicKey)
        XCTAssertTrue(joiner.offeredActivities.isEmpty, "an offer exceeding the 7-day ceiling must be rejected")
    }

    // MARK: - Integration harness

    /// Waits for the managers' spawned send Tasks (offers, grants, gossip) to drain on the main actor.
    private func drain() async {
        for _ in 0..<40 { await Task.yield() }
    }

    /// Wires two managers so `send` routes payloads straight into the other's receive methods, simulating
    /// the sealed mesh transport with transport-verified identities.
    private func connect(host: ProximityActivityManager, hostId: IdentityService,
                         joiner: ProximityActivityManager, joinerId: IdentityService) {
        host.committedActivityPeerFingerprints = { [f = joinerId.localFingerprint] in [f] }
        joiner.committedActivityPeerFingerprints = { [f = hostId.localFingerprint] in [f] }
        host.send = { type, payload, _, _ in
            Self.route(type, payload, into: joiner, fromFingerprint: hostId.localFingerprint,
                       fromSigning: hostId.localSigningPublicKey, fromKeyAgreement: hostId.localKeyAgreementPublicKey)
        }
        joiner.send = { type, payload, _, _ in
            Self.route(type, payload, into: host, fromFingerprint: joinerId.localFingerprint,
                       fromSigning: joinerId.localSigningPublicKey, fromKeyAgreement: joinerId.localKeyAgreementPublicKey)
        }
    }

    private static func route(_ type: PayloadType, _ payload: any Encodable, into target: ProximityActivityManager,
                              fromFingerprint: String, fromSigning: Data, fromKeyAgreement: Data) {
        switch type {
        case .activityOffer:
            if let p = payload as? ActivityOfferPayload {
                target.receiveOffer(p, fromFingerprint: fromFingerprint, verifiedHostSigningPublicKey: fromSigning)
            }
        case .activityJoinRequest:
            if let p = payload as? ActivityJoinRequestPayload {
                target.receiveJoinRequest(p, verifiedFingerprint: fromFingerprint,
                                          verifiedSigningPublicKey: fromSigning, verifiedKeyAgreementPublicKey: fromKeyAgreement)
            }
        case .activityJoinGrant:
            if let p = payload as? ActivityJoinGrantPayload {
                target.receiveGrant(p, fromFingerprint: fromFingerprint)
            }
        case .activityRosterSnapshot:
            if let p = payload as? ActivityRosterSnapshotPayload {
                target.receiveSnapshot(p.snapshot)
            }
        case .activitySync:
            if let p = payload as? ActivitySyncPayload {
                target.receiveSync(p, fromFingerprint: fromFingerprint)
            }
        default:
            break
        }
    }
}

/// Records the payload types a manager tried to send (reference type so the send closure captures a
/// `let`, avoiding a captured-var-in-concurrent-code warning).
@MainActor
private final class SendRecorder {
    private(set) var types: [PayloadType] = []
    func record(_ type: PayloadType, _ fingerprint: String) { types.append(type) }
    func reset() { types.removeAll() }
}

/// Minimal `ProximityHost` for the activity manager: it reads the display name; the trust vault + block
/// checks exist for protocol conformance (activities don't gate on vault trust).
@MainActor
private final class MockActivityHost: ProximityHost {
    let name: String
    init(name: String) { self.name = name }
    var proximityDisplayName: String { name }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool { proximityTrustVault.isBlockedFingerprint(fingerprint) }
    func blockProximityPeer(signingPublicKey: Data) { proximityTrustVault.block(signingPublicKey: signingPublicKey) }
}
