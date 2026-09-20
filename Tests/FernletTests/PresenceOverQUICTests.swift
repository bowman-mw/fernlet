// PresenceOverQUICTests.swift
// FernletTests
//
// P9 item 2 pass 2 (plan §17.1): the presence radio's move onto Network.framework/QUIC — the
// BIND between `PresenceEpochPosture` and what actually goes on the air, the epoch boundary's
// re-advertisement, the dial hello that replaces MultipeerConnectivity's free inbound-peer
// resolution, and the stand-down on a start failure.
//
// Every cell drives the manager over `FakePresenceRadioSession`, the in-memory conformer of
// `PresenceRadioSession` that pass 2 added the seam for. No test here starts Bonjour — the
// unit-test invariant for proximity — and none of these decisions was reachable at tier 1 before
// the seam existed.

@testable import ProximityKit
import Combine
import Foundation
import Testing
import CryptoKit
import FernletFoundation
import FernletDomainModel
@testable import Fernlet

@MainActor
private final class MockPresenceQUICHost: ProximityHost {
    var proximityDisplayName: String { "Tester" }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    var allowNearbyHearts: Bool = true
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

/// One advertisement the radio was asked to put on the air.
private struct AdvertiseCall {
    let instanceName: String
    let certificateDER: Data
    let epoch: UInt64
    let fields: [String: String]
}

/// The in-memory presence radio: records what it was asked to advertise, dial and disconnect, and
/// vends real ``NetworkPeerChannel``s with itself as the host so a heart rig can round-trip bytes.
@MainActor
private final class FakePresenceRadioSession: PresenceRadioSession, NetworkChannelHost {
    var onPeerDiscovered: ((PeerHandle) -> Void)?
    var onPeerLost: ((PeerHandle) -> Void)?
    var onPeerChannelReady: ((NetworkPeerChannel) -> Void)?
    var onPeerDisconnected: ((PeerHandle, String) -> Void)?
    var onTransportError: ((String) -> Void)?
    var resolveDialer: ((String) -> PeerHandle?)?

    /// Set to make `start(posture:discoveryInfo:)` throw, standing in for a listener that could
    /// not be created — the Local Network prompt on a fresh install's very first start.
    var startError: (any Error)?

    private(set) var advertised: [AdvertiseCall] = []
    private(set) var republished: [AdvertiseCall] = []
    private(set) var stopCount = 0
    private(set) var dials: [(peer: PeerHandle, tag: String)] = []
    private(set) var disconnects: [PeerHandle] = []
    private(set) var sent: [(peer: PeerHandle, data: Data)] = []

    /// Every advertisement the radio has been asked to make, in order — start first, then each
    /// republish. The sequence a boundary is read off.
    var allAdvertisements: [AdvertiseCall] { advertised + republished }

    func start(posture: PresenceEpochPosture, discoveryInfo: [String: String]) throws {
        if let startError { throw startError }
        advertised.append(call(posture, discoveryInfo))
    }

    func republish(posture: PresenceEpochPosture, discoveryInfo: [String: String]) {
        republished.append(call(posture, discoveryInfo))
    }

    func stop() { stopCount += 1 }
    func dial(_ peer: PeerHandle, helloTag: String) { dials.append((peer, helloTag)) }
    func disconnectPeer(_ peer: PeerHandle) { disconnects.append(peer) }
    func channel(for peer: PeerHandle) -> NetworkPeerChannel {
        NetworkPeerChannel(peer: peer, host: self)
    }

    func send(_ data: Data, to peer: PeerHandle, mode: PeerDeliveryMode) async throws {
        sent.append((peer, data))
    }

    func openTransferCount(for peer: PeerHandle) -> Int { 0 }

    private func call(_ posture: PresenceEpochPosture, _ fields: [String: String]) -> AdvertiseCall {
        AdvertiseCall(
            instanceName: posture.instanceName,
            certificateDER: posture.tlsIdentity.certificateDER,
            epoch: posture.epoch,
            fields: fields
        )
    }
}

@MainActor
@Suite(.serialized)
struct PresenceOverQUICTests {

    /// Deliberately NOT on a 900 s multiple, so "one second before the boundary" is measured from
    /// the boundary rather than from this instant (the trap pass 1's rotation cell names).
    private let baseDate = Date(timeIntervalSince1970: 1_780_000_000)

    // MARK: - Fixtures

    private func makeIdentity() throws -> (IdentityService, String) {
        let serviceID = "com.fernlet.presencequic.test.\(UUID().uuidString)"
        let svc = IdentityService(keychainService: serviceID)
        try svc.ensureProvisioned()
        return (svc, serviceID)
    }

    private func makeLedger() -> ProximityHeartLedger {
        ProximityHeartLedger(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("presence-quic-tests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("HeartLedger.json"),
            now: { self.baseDate })
    }

    private func kaPublic() -> Data {
        Curve25519.KeyAgreement.PrivateKey().publicKey.rawRepresentation
    }

    private func makeFriend(fingerprint: String, keyAgreementPublicKey: Data) -> ProximityTrustedPeerRecord {
        ProximityTrustedPeerRecord(
            displayName: "Friend",
            fingerprint: fingerprint,
            signingPublicKey: Data((0..<8).map { _ in UInt8.random(in: 0...255) }),
            keyAgreementPublicKey: keyAgreementPublicKey,
            mode: .friend,
            firstAcceptedAt: baseDate,
            lastSeenAt: baseDate)
    }

    /// A browsed peer advertising `tokens`, encoded the way the radio encodes its own record.
    private func peer(tokens: [String]) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: "fn-\(UUID().uuidString.prefix(16))",
            discoveryInfo: PresenceAdvertisement.publishedFields(tags: tokens),
            advertisedFingerprint: nil)
    }

    /// The radio's own resolution of a claimed tag, flattened: the hook is itself optional, so a
    /// bare `== nil` would compare the WRAPPER and pass over a refusal it never looked at.
    private func resolve(_ radio: FakePresenceRadioSession, _ tag: String) -> PeerHandle? {
        radio.resolveDialer.flatMap { $0(tag) }
    }

    /// A name that sorts ABOVE `name`, so a peer wearing it is the preferred dialer — every real
    /// posture name starts `fn-`, so the two helpers cannot collide with one.
    private func outranking(_ name: String) -> String { "zz" + name }

    /// A name that sorts BELOW `name`, so a peer wearing it is not the preferred dialer.
    private func outranked(_ name: String) -> String { "aa" + name }

    /// Seconds from `baseDate` to the next epoch boundary.
    private var toBoundary: TimeInterval {
        let into = baseDate.timeIntervalSince1970
            .truncatingRemainder(dividingBy: IdentityService.presenceEpochSeconds)
        return IdentityService.presenceEpochSeconds - into
    }

    // MARK: - The bind

    /// The radio advertises the posture's own name and the posture's own certificate — not a
    /// session-minted name, and not a second identity.
    ///
    /// This is the whole of pass 2's claim, and it is the one thing a source scan cannot see: a
    /// listener registered under `MeshLinkAdvertisement.randomInstanceName()` instead would
    /// compile, would rotate nothing, and would look exactly like this from the outside.
    @Test func theRadioAdvertisesUnderThePosturesOwnNameAndCertificate() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.makeSession = { radio }
        manager.start()

        let posture = try #require(manager.presencePosture)
        #expect(radio.advertised.count == 1, "the radio comes up exactly once")
        let call = try #require(radio.advertised.first)
        #expect(call.instanceName == posture.instanceName)
        #expect(call.certificateDER == posture.tlsIdentity.certificateDER)
        #expect(call.epoch == IdentityService.presenceEpoch(at: baseDate))
        #expect(manager.isListening, "and says so by its own account")
    }

    /// A radio brought up in the middle of an epoch advertises for THAT epoch, and rotates at the
    /// next boundary like any other.
    ///
    /// The tier-2 runner starts two Simulators a couple of minutes before a boundary, so a
    /// mid-epoch start is the only start that row ever performs.
    @Test func aMidEpochStartAdvertisesForTheEpochItStartsInAndRotatesAtTheNextBoundary() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        var clock = baseDate.addingTimeInterval(toBoundary - 120)
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { clock }
        manager.makeSession = { radio }
        manager.start()

        let startEpoch = IdentityService.presenceEpoch(at: clock)
        #expect(radio.advertised.first?.epoch == startEpoch)

        clock = clock.addingTimeInterval(121)
        manager.rotateEpochIfNeeded()
        #expect(radio.republished.count == 1, "the boundary re-advertises")
        #expect(radio.republished.first?.epoch == startEpoch + 1)
    }

    /// At a boundary the radio is re-advertised under an entirely new name AND a new certificate,
    /// and the old name is never put on the air again.
    ///
    /// Both halves matter. Re-advertising is how the OLD Bonjour registration is withdrawn —
    /// there is no other way — so a boundary that only re-derived tags would leave the previous
    /// name live beside the new one, and an observer who saw both would have linked them by
    /// construction. And a name that rotated while the certificate did not is the same failure a
    /// step lower down.
    @Test func anEpochBoundaryReAdvertisesUnderAWhollyNewPostureAndRetiresTheOldName() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        var clock = baseDate
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { clock }
        manager.makeSession = { radio }
        manager.start()
        let first = try #require(radio.advertised.first)

        // Inside the epoch nothing is re-advertised, not even by a roster refresh.
        clock = baseDate.addingTimeInterval(toBoundary - 1)
        manager.rotateEpochIfNeeded()
        #expect(radio.republished.isEmpty, "a tick inside the epoch re-advertises nothing")

        clock = baseDate.addingTimeInterval(toBoundary + 1)
        manager.rotateEpochIfNeeded()
        let second = try #require(radio.republished.last)
        #expect(second.epoch == first.epoch + 1)
        #expect(second.instanceName != first.instanceName, "the advertised name must rotate with the tags")
        #expect(second.certificateDER != first.certificateDER, "and so must the certificate")
        #expect(
            radio.allAdvertisements.filter { $0.instanceName == first.instanceName }.count == 1,
            "the old name is advertised once, before the boundary, and never again"
        )
    }

    /// A roster refresh that lands after a boundary re-advertises under the new posture too —
    /// never fresh tags under a stale name.
    @Test func aRosterRefreshAcrossABoundaryReAdvertisesUnderTheNewPosture() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        var clock = baseDate
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { clock }
        manager.makeSession = { radio }
        manager.start()
        let first = try #require(radio.advertised.first)

        clock = baseDate.addingTimeInterval(toBoundary + 1)
        manager.refreshRoster()
        let refreshed = try #require(radio.republished.last)
        #expect(refreshed.epoch == first.epoch + 1)
        #expect(refreshed.instanceName == manager.presencePosture?.instanceName)
    }

    /// The advertised TXT is the version plus the tags, and carries nothing else at any roster size.
    @Test func theAdvertisedRecordCarriesOnlyTheVersionAndTheTags() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let friends = (0..<4).map { makeFriend(fingerprint: "fp0000000000000\($0)", keyAgreementPublicKey: kaPublic()) }
        host.proximityTrustVault.apply(peers: friends, audit: [])
        let radio = FakePresenceRadioSession()
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.makeSession = { radio }
        manager.start()

        let fields = try #require(radio.advertised.first?.fields)
        #expect(fields[PresenceAdvertisement.versionKey] == PresenceAdvertisement.version)
        let allowed = Set((0..<PresenceAdvertisement.maxChunks).map { PresenceAdvertisement.tagsKey(chunk: $0) })
            .union([PresenceAdvertisement.versionKey])
        #expect(Set(fields.keys).isSubset(of: allowed), "no name, no session id, no fingerprint: \(fields.keys)")
        #expect(PresenceAdvertisement.tags(from: fields).count == friends.count)
    }

    // MARK: - Stand-down

    /// A radio that cannot start stands itself down by its own account, so the run policy — which
    /// re-applies a running verdict to a listener whose `isListening` says it is down — has
    /// something to see.
    ///
    /// P8 item 0's device finding (b), carried across the transport swap: with `isRunning` left
    /// true the idempotent `start()` no-ops forever over a dead radio. The failure here is the one
    /// the Local Network permission prompt guarantees on a fresh install's very first start.
    @Test func aQUICStartFailureStandsTheRadioDownByItsOwnAccount() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        radio.startError = MeshTransportError.tlsIdentityUnavailable
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.makeSession = { radio }
        manager.start()

        #expect(!manager.isListening, "a radio that never came up must not read as listening")
        #expect(radio.advertised.isEmpty)
        #expect(radio.stopCount == 1, "and the teardown ran, so a later start builds a fresh radio")
        #expect(manager.presencePosture == nil, "the stood-down radio keeps no name to come back under")
    }

    /// A transport error reported after the radio is up stands it down the same way.
    @Test func aTransportErrorAfterStartStandsTheRadioDown() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.makeSession = { radio }
        manager.start()
        #expect(manager.isListening)

        radio.onTransportError?("The presence listener failed.")
        #expect(!manager.isListening)
        #expect(radio.stopCount == 1)
    }

    /// `stop()` tears the radio down and drops the posture with it.
    @Test func stoppingTearsTheRadioDownAndDropsThePosture() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let radio = FakePresenceRadioSession()
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.makeSession = { radio }
        manager.start()
        manager.stop()

        #expect(radio.stopCount == 1)
        #expect(!manager.isListening)
        #expect(manager.presencePosture == nil)
        #expect(manager.nearbyFriendFingerprints.isEmpty)
    }

    // MARK: - Dialing and the inbound resolution

    /// A heart send dials the browsed peer claiming the pairwise tag we advertise for that friend
    /// — the same token the friend derives on their side to match it.
    ///
    /// The tag is what replaces MultipeerConnectivity's free inbound resolution, so a dial that
    /// carried the wrong token (or none) would be refused by the far side with no local symptom.
    @Test func aHeartSendDialsClaimingThePairwiseTagWeAdvertiseForThatFriend() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA)
        host.proximityTrustVault.apply(peers: [friend], audit: [])
        let radio = FakePresenceRadioSession()
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.makeSession = { radio }
        manager.start()

        let epoch = IdentityService.presenceEpoch(at: baseDate)
        let ourTag = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let theirOther = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()
        let browsed = peer(tokens: [ourTag, theirOther])
        radio.onPeerDiscovered?(browsed)
        #expect(manager.nearbyFriendFingerprints == [friend.fingerprint])

        manager.sendHeart(to: friend)
        #expect(radio.dials.count == 1)
        let dial = try #require(radio.dials.first)
        #expect(dial.peer.isSameEndpoint(as: browsed))
        #expect(dial.tag == ourTag, "the hello claims the very token we put on the air for this friend")
        let advertised = try #require(radio.advertised.first?.fields)
        #expect(PresenceAdvertisement.tags(from: advertised).contains(ourTag))
    }

    /// An inbound dialer is admitted only when the tag it claims resolves, through OUR OWN derived
    /// candidate tokens, to a friend we have already browsed.
    ///
    /// Both gates fail closed, and the answer is the BROWSED peer's handle — which is what gives
    /// the QUIC radio the collapse MultipeerConnectivity had for free: the inbound tunnel lands
    /// under the same endpoint key an outbound dial to that device would.
    @Test func anInboundDialerResolvesOnlyToAnAlreadyBrowsedTagMatchedFriend() throws {
        let (identity, serviceID) = try makeIdentity()
        defer { KeychainItem.deleteAll(service: serviceID) }
        let host = MockPresenceQUICHost()
        let friendKA = kaPublic()
        let friend = makeFriend(fingerprint: "f00df00df00df00d", keyAgreementPublicKey: friendKA)
        host.proximityTrustVault.apply(peers: [friend], audit: [])
        let radio = FakePresenceRadioSession()
        let manager = PresenceManager(store: host, ledger: makeLedger(), identity: identity)
        manager.nowProvider = { self.baseDate }
        manager.makeSession = { radio }
        manager.start()

        let epoch = IdentityService.presenceEpoch(at: baseDate)
        let ourTag = try identity.presenceTag(for: friendKA, epoch: epoch).base64EncodedString()
        let stranger = Data((0..<8).map { _ in UInt8.random(in: 0...255) }).base64EncodedString()

        // Pre-discovery race: the tag resolves to a friend, but we have not browsed them yet.
        #expect(resolve(radio, ourTag) == nil, "a dialer we have not browsed is refused; it retries")
        #expect(resolve(radio, stranger) == nil, "a tag we cannot derive names nobody")

        let browsed = peer(tokens: [ourTag, stranger])
        radio.onPeerDiscovered?(browsed)
        let resolved = try #require(resolve(radio, ourTag))
        #expect(resolved.isSameEndpoint(as: browsed), "the answer is the browsed peer, not a fresh handle")

        // The hearts opt-out is one of the gates in front of it.
        host.allowNearbyHearts = false
        #expect(resolve(radio, ourTag) == nil, "hearts off refuses the connection outright")
    }

    // MARK: - A dial that cannot be made

    /// A dial for a peer this radio holds no browsed endpoint for is a DIAL refusal: the radio
    /// stays up, wearing its posture, and the owner hears nothing.
    ///
    /// The regression: the miss used to go through `report(…)` → `onTransportError` →
    /// `PresenceManager.handleTransportError` → `stop()`, which is the START-failure door and
    /// stands the WHOLE radio down. It is reachable on an ordinary evening — a friend's own epoch
    /// boundary withdraws their Bonjour registration, `noteLost` drops the endpoint while the
    /// manager's 45 s lost-grace still offers them as nearby, the user taps the heart — and the
    /// cost was the nearby list emptying and the posture being dropped until the next scene event.
    @Test func aDialForAPeerWithNoBrowsedEndpointRefusesTheDialAndNotTheRadio() throws {
        let radio = NetworkPresenceSession()
        let posture = try PresenceEpochPosture.minted(at: baseDate)
        radio.runWithoutRadiosForTesting(posture: posture)

        var reported: [String] = []
        radio.onTransportError = { reported.append($0) }

        // A peer this radio has browsed and since lost: the identity map still knows it (that is
        // what makes the handle resolvable at all), the endpoint cache does not.
        let key = MeshLinkKey("endpoint-gone")
        let peer = radio.handleForTesting(key)
        radio.dial(peer, helloTag: "dGFn")

        #expect(reported.isEmpty, "a per-dial miss must never reach the owner's start-failure door")
        #expect(radio.isRunning, "the radio is still up")
        #expect(radio.advertisedInstanceNameForTesting == posture.instanceName, "and still wearing its posture")
        #expect(radio.tunnelCountForTesting == 0, "and opened nothing")
    }

    /// The listener and browser task bodies check for cancellation before they report.
    ///
    /// A source claim because it has to be: `NetworkListener.run` is a framework call a unit test
    /// cannot make throw. The order is the whole of it — `republish(posture:discoveryInfo:)`
    /// cancels the listener task at EVERY epoch boundary and every roster refresh, because
    /// re-creating the listener is the only way to withdraw a Bonjour registration, so a
    /// `CancellationError` reported as a start failure would stand presence down every 900 s.
    @Test func theListenerAndBrowserTasksDoNotReportTheirOwnCancellation() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Transport/NetworkPresenceSession.swift")
        )
        for signature in ["func startListener() throws", "func startBrowser()"] {
            let body = try #require(
                MeshRoutedSourceScan.bracedBody(after: signature, in: code),
                "\(signature) is gone or its braces do not close"
            )
            let guardIndex = try #require(
                body.range(of: "guard !Task.isCancelled else { return }")?.lowerBound,
                "\(signature)'s task body reports without checking for its own cancellation first"
            )
            let reportIndex = try #require(
                body.range(of: "report(")?.lowerBound, "\(signature) no longer reports at all"
            )
            #expect(guardIndex < reportIndex, "\(signature) guards AFTER it reports, which guards nothing")
        }
    }

    // MARK: - Glare

    /// Two friends who sight each other at the same moment and both dial keep exactly ONE
    /// connection, and it is the same connection on both devices.
    ///
    /// The defect: the inbound path refused any connection resolving to a key it already held, so
    /// each side refused the other's dial — and a refusal closes that connection, so each side's
    /// OWN dial died at the far end too. Both tunnels gone, both hearts undelivered, on the most
    /// ordinary case there is (two phones approaching). MultipeerConnectivity collapsed it for
    /// free; QUIC has to be told how.
    ///
    /// The rule is the mesh's `MeshTunnelConvergence` over the two advertised instance names — the
    /// only pair of values both devices hold and agree on before a presence handshake has run — so
    /// both sides compute the same verdict from the same two strings.
    @Test func simultaneousDialsCollapseToOneConnectionTheSameWayOnBothDevices() throws {
        let alice = NetworkPresenceSession()
        let bob = NetworkPresenceSession()
        let alicePosture = try PresenceEpochPosture.minted(at: baseDate)
        let bobPosture = try PresenceEpochPosture.minted(at: baseDate)
        alice.runWithoutRadiosForTesting(posture: alicePosture)
        bob.runWithoutRadiosForTesting(posture: bobPosture)

        // Each has browsed the other and dialed it: one outbound tunnel apiece, under the other's
        // browsed key.
        let bobKey = MeshLinkKey("bob-endpoint")
        let aliceKey = MeshLinkKey("alice-endpoint")
        alice.noteBrowsedNameForTesting(bobKey, instanceName: bobPosture.instanceName)
        bob.noteBrowsedNameForTesting(aliceKey, instanceName: alicePosture.instanceName)
        alice.bookTunnelForTesting(bobKey, role: .initiator)
        bob.bookTunnelForTesting(aliceKey, role: .initiator)

        // Each side's inbound arrives, resolving to the key it already holds.
        let aliceAdmits = alice.admitInboundForTesting(at: bobKey)
        let bobAdmits = bob.admitInboundForTesting(at: aliceKey)
        #expect(aliceAdmits != bobAdmits, "exactly one side yields — both yielding or both refusing is the bug")

        // The production path books the inbound tunnel on whichever side admitted it.
        if aliceAdmits { alice.bookTunnelForTesting(bobKey, role: .responder) }
        if bobAdmits { bob.bookTunnelForTesting(aliceKey, role: .responder) }

        #expect(alice.tunnelCountForTesting == 1, "exactly one tunnel on Alice's side")
        #expect(bob.tunnelCountForTesting == 1, "exactly one tunnel on Bob's side")
        // One connection, named from each end: whoever kept their dial holds the initiator end and
        // the other holds the responder end. Two initiators would be two connections.
        let aliceRole = try #require(alice.tunnelRoleForTesting(at: bobKey))
        let bobRole = try #require(bob.tunnelRoleForTesting(at: aliceKey))
        #expect(
            aliceRole != bobRole,
            "the survivor must be ONE connection seen from both ends, not one connection each"
        )
        // And the survivor is the dial of the side whose advertised name ranks higher — the same
        // comparison `MeshDialPreference` makes, so the two radios cannot disagree.
        let aliceKeptItsDial = alice.tunnelRoleForTesting(at: bobKey) == .initiator
        #expect(aliceKeptItsDial == (alicePosture.instanceName > bobPosture.instanceName))
    }

    /// A re-invite from a peer we already hold an outbound dial to is ADMITTED when the tie-break
    /// says the peer's dial is the survivor — and the owner is told, so it can drop the record for
    /// the connection that is going away.
    ///
    /// Telling the owner is load-bearing, not incidental: the channel-ready gate answers "already
    /// connected" for a device it still holds a record for, so a silent yield would hand the fresh
    /// channel to an owner that dropped it and leave a coordinator waiting on a dead connection.
    @Test func aReInviteFromAHeldPeerIsAdmittedRatherThanRefused() throws {
        let radio = NetworkPresenceSession()
        let posture = try PresenceEpochPosture.minted(at: baseDate)
        radio.runWithoutRadiosForTesting(posture: posture)

        // A peer whose name outranks ours: its dial is the one that survives.
        let key = MeshLinkKey("peer-endpoint")
        radio.noteBrowsedNameForTesting(key, instanceName: outranking(posture.instanceName))
        radio.bookTunnelForTesting(key, role: .initiator)

        var disconnects: [String] = []
        radio.onPeerDisconnected = { _, reason in disconnects.append(reason) }
        var reported: [String] = []
        radio.onTransportError = { reported.append($0) }

        #expect(radio.admitInboundForTesting(at: key), "the peer must not be refused")
        #expect(radio.tunnelCountForTesting == 0, "our own dial was collapsed to make room")
        #expect(disconnects == [NetworkPresenceSession.redundantTunnelCloseReason],
                "the owner is told, under the benign-collapse token")
        #expect(reported.isEmpty, "a collapse is not a transport failure")
    }

    /// When the tie-break says OUR connection is the survivor, the arriving one is dropped and
    /// nothing we hold is disturbed — the peer is not refused, it is simply already connected to
    /// us on the tunnel that won.
    @Test func anInboundThatLosesTheTieBreakLeavesTheHeldTunnelAlone() throws {
        let radio = NetworkPresenceSession()
        let posture = try PresenceEpochPosture.minted(at: baseDate)
        radio.runWithoutRadiosForTesting(posture: posture)

        let key = MeshLinkKey("peer-endpoint")
        radio.noteBrowsedNameForTesting(key, instanceName: outranked(posture.instanceName))
        radio.bookTunnelForTesting(key, role: .initiator)

        var disconnects: [PeerHandle] = []
        radio.onPeerDisconnected = { peer, _ in disconnects.append(peer) }

        #expect(!radio.admitInboundForTesting(at: key))
        #expect(radio.tunnelCountForTesting == 1, "the connection we hold is untouched")
        #expect(radio.tunnelRoleForTesting(at: key) == .initiator)
        #expect(disconnects.isEmpty, "and the owner hears nothing, because nothing of its own ended")
    }

    // MARK: - The channel path

    /// The hearts/channel path round-trips a payload over the new transport: what the radio hands
    /// the owner is a live channel whose inbound frames reach a subscriber and whose sends reach
    /// the radio.
    ///
    /// The envelope, ledger and trust-gate halves of a heart are covered by `PresenceHeartsTests`
    /// and `HeartShareTests` over the manager's own seams; what only pass 2 can break is the
    /// bytes' route, which is this.
    @Test func theHeartChannelRoundTripsAPayloadOverTheNewTransport() async throws {
        let radio = FakePresenceRadioSession()
        let peer = peer(tokens: ["tag"])
        let channel = radio.channel(for: peer)

        var received: [Data] = []
        let subscription = channel.inbound.sink { received.append($0.data) }
        defer { subscription.cancel() }

        let payload = Data("a sealed friendHeart".utf8)
        channel.receive(payload, at: Date())
        #expect(received == [payload], "an inbound frame reaches the coordinator's subscriber")

        try await channel.send(payload, to: peer, mode: .reliable)
        #expect(radio.sent.count == 1)
        #expect(radio.sent.first?.data == payload, "and an outbound frame reaches the radio")
        #expect(channel.openTransferCount == 0, "presence opens no per-transfer streams")
    }

    /// The channel holds its host weakly: a radio that goes away leaves a channel that refuses to
    /// send rather than one that keeps the radio alive (memory lifecycle — the manager owns the
    /// session, the session's channels point back weakly).
    @Test func theChannelHoldsItsRadioWeakly() async throws {
        let peer = peer(tokens: ["tag"])
        var radio: FakePresenceRadioSession? = FakePresenceRadioSession()
        let channel = try #require(radio?.channel(for: peer))
        radio = nil
        await #expect(throws: PeerTransportError.self) {
            try await channel.send(Data([0x01]), to: peer, mode: .reliable)
        }
    }

    // MARK: - The retirement scan

    /// `PresenceManager` no longer names MultipeerConnectivity anywhere in its code, and does name
    /// the radio that replaced it.
    ///
    /// The rule-7 gate for a two-pass item: pass 1 changed nothing on the air, so the only
    /// mechanical proof that pass 2 RAN is that the MC path is gone from this file. Pinned in both
    /// directions — a file that names neither has been renamed or emptied, not cleaned.
    @Test func theManagerNoLongerNamesTheRetiredRadio() throws {
        let source = try RepoRoot.source("FernletKit/Sources/ProximityKit/Presence/PresenceManager.swift")
        let code = MeshRoutedSourceScan.codeOnly(source)
        for needle in ["MeshMultipeerSession", "MCPeerID", "MCSession", "PeerChannelTransport",
                       "updateDiscoveryInfo", "serviceType", "MultipeerConnectivity"] {
            #expect(!code.contains(needle), "PresenceManager still names `\(needle)` in code")
        }
        #expect(code.contains("PresenceRadioSession"), "and it drives the QUIC presence radio's seam")
        #expect(code.contains("NetworkPresenceSession"), "whose production conformer it builds")
        #expect(code.contains("PresenceAdvertisement"), "through the presence TXT vocabulary")

        // The COMMENTS get a narrower rule, and the line is drawn where it is un-brittle: the
        // framework's API TYPE names describe a mechanism, so a comment carrying one is describing
        // machinery this file no longer has (stale, and the review found two such lines). The
        // framework's NAME describes history, and "what the retired MultipeerConnectivity
        // advertiser could not do" is exactly the sentence that explains why the posture rotation
        // exists — banning it would delete the reason along with the reference.
        for needle in ["MCPeerID", "MCSession", "MCNearbyServiceAdvertiser", "MCNearbyServiceBrowser"] {
            #expect(
                !source.contains(needle),
                "a PresenceManager comment still describes `\(needle)` machinery — the radio is QUIC now"
            )
        }
    }

    /// The presence radio's service type and ALPN are its own, and the Info.plist carries the type.
    ///
    /// A service type missing from `NSBonjourServices` fails discovery silently on device, and a
    /// shared ALPN would let a presence dial complete a TLS handshake with a mesh listener.
    @Test func thePresenceServiceTypeIsItsOwnAndIsDeclared() throws {
        #expect(NetworkPresenceSession.serviceType == "_fernlet-near2._udp")
        #expect(NetworkPresenceSession.serviceType != NetworkMeshSession.friendServiceType)
        #expect(NetworkPresenceSession.alpn != NetworkMeshSession.alpn)
        let plist = try RepoRoot.source("App/Fernlet/Info.plist")
        #expect(plist.contains("<string>\(NetworkPresenceSession.serviceType)</string>"))
    }
}
