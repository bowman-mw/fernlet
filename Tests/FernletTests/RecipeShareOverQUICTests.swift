// RecipeShareOverQUICTests.swift
// FernletTests
//
// P9 item 3 pass 2 (Docs/Plan-ProximityKit-Network-Migration-2026-08-27.md §17.1): the recipe-share
// radio's move onto Network.framework/QUIC — the posture that goes on the air, the dial hello that
// replaces the retired transport's free inbound-peer resolution, the pause/resume that closes this
// Fernlet to a third device while a pairing is held, and the per-transfer stream a picture recipe
// earns.
//
// No cell here starts Bonjour — the unit-test invariant for proximity. The session cells run the
// real `NetworkRecipeShareSession` with its framework objects suppressed
// (`runWithoutRadiosForTesting`), so every decision around the listener runs; the manager cells
// drive it over `FakeRecipeShareRadioSession`, the in-memory conformer of the seam pass 2 added.

@testable import ProximityKit
import Combine
import Foundation
import Testing
import FernletDomainModel
import AIProviders
@testable import Fernlet

/// The in-memory recipe radio: records what it was asked to advertise, dial and end, holds the
/// pause flag as a plain toggle, and vends real ``NetworkPeerChannel``s with itself as the host so
/// a share rig can round-trip bytes.
///
/// Shared by every recipe-share suite — `ProximityRecipeShareCapTests` and
/// `RecipeShareTransferTests` drive the manager through it too, because pass 2 replaced the
/// never-started MultipeerConnectivity session those cells used to poke.
@MainActor
final class FakeRecipeShareRadioSession: RecipeShareRadioSession, NetworkChannelHost {
    var onPeerDiscovered: ((PeerHandle) -> Void)?
    var onPeerLost: ((PeerHandle) -> Void)?
    var onPeerChannelReady: ((NetworkPeerChannel) -> Void)?
    var onPeerDisconnected: ((PeerHandle, String) -> Void)?
    var onTransportError: ((String) -> Void)?
    var resolveDialer: ((String) -> PeerHandle?)?
    var shouldAcceptDialer: ((PeerHandle) -> Bool)?

    /// Set to make `start(advertisement:)` throw, standing in for a listener that could not be
    /// created — the Local Network prompt on a fresh install's very first start.
    var startError: (any Error)?

    /// Peers the owner should consider mid-connect, so the connecting-window gate is drivable.
    var connectingPeers: [PeerHandle] = []

    /// Inbound connections booked but not yet resolved to a peer, and the one being adjudicated.
    ///
    /// The real radio books a pending inbound BEFORE the hello can be read and asks the owner's
    /// gate while it is still booked, so a fake that models no pending inbound at all cannot see
    /// the gate refusing the very connection it is ruling on. Keyed by an opaque token because
    /// nothing about a pending connection is resolvable to a peer yet.
    var pendingInboundKeys: Set<String> = []

    /// The pending connection currently under adjudication, excluded from the window.
    var adjudicatingInboundKey: String?

    /// Whether `start(advertisement:)` has left this radio up — the read the fake used not to have.
    private(set) var isStarted = false

    private(set) var isDiscoveryPaused = false
    private(set) var advertisedSessionID = UUID().uuidString
    private(set) var advertised: [[String: String]] = []
    private(set) var stopCount = 0
    private(set) var pauseCount = 0
    private(set) var resumeCount = 0
    private(set) var dials: [(peer: PeerHandle, helloSID: String)] = []
    private(set) var endedTunnels: [PeerHandle] = []
    private(set) var sent: [(peer: PeerHandle, data: Data)] = []

    var connectedPeers: [PeerHandle] = []

    func start(advertisement: [String: String]) throws {
        if let startError { throw startError }
        advertised.append(advertisement)
        isStarted = true
    }

    func stop() {
        stopCount += 1
        isStarted = false
        // The production radio clears its OWN pause flag here; the fake must too, or the gate's
        // three "unchanged" rows would be resting on a fake that is kinder than the radio.
        isDiscoveryPaused = false
    }

    func dial(_ peer: PeerHandle, helloSID: String) { dials.append((peer, helloSID)) }
    func endTunnel(_ peer: PeerHandle) { endedTunnels.append(peer) }

    func hasConnectingPeers(besides peer: PeerHandle?) -> Bool {
        // Same two populations, and the same exclusion, as the production radio.
        guard pendingInboundKeys.allSatisfy({ $0 == adjudicatingInboundKey }) else { return true }
        return connectingPeers.contains { candidate in
            guard let peer else { return true }
            return !candidate.isSameEndpoint(as: peer)
        }
    }

    func pauseDiscovery() {
        guard !isDiscoveryPaused else { return }
        isDiscoveryPaused = true
        pauseCount += 1
    }

    func resumeDiscovery() {
        guard isDiscoveryPaused else { return }
        isDiscoveryPaused = false
        resumeCount += 1
        advertisedSessionID = UUID().uuidString
    }

    func channel(for peer: PeerHandle) -> NetworkPeerChannel {
        NetworkPeerChannel(peer: peer, host: self)
    }

    func send(_ data: Data, to peer: PeerHandle, mode: PeerDeliveryMode) async throws {
        sent.append((peer, data))
    }

    func openTransferCount(for peer: PeerHandle) -> Int { 0 }
}

/// A host whose display name the advertisement cells choose.
private final class RecipeQUICTestHost: ProximityHost {
    let name: String
    init(name: String = "Tester") { self.name = name }
    var proximityDisplayName: String { name }
    var trustedProximityPeers: [ProximityTrustedPeerRecord] { proximityTrustVault.trustedPeers }
    let proximityTrustVault = ProximityTrustVault()
    func isBlockedFingerprint(_ fingerprint: String) -> Bool {
        proximityTrustVault.isBlockedFingerprint(fingerprint)
    }
    func blockProximityPeer(signingPublicKey: Data) {
        proximityTrustVault.block(signingPublicKey: signingPublicKey)
    }
}

@MainActor
struct RecipeShareOverQUICTests {

    // MARK: - Fixtures

    private func makePeer(
        named name: String,
        advertising fields: [String: String]? = nil
    ) -> PeerHandle {
        PeerHandle(
            id: UUID(),
            displayHint: name,
            discoveryInfo: fields,
            advertisedFingerprint: nil,
            endpoint: PeerEndpointKey()
        )
    }

    /// A browsed peer advertising `sessionID`, encoded the way this radio encodes its own record.
    private func peer(advertisingSessionID sessionID: String, name: String = "Blair") -> PeerHandle {
        makePeer(
            named: "fernlet-mesh-\(UUID().uuidString.prefix(12))",
            advertising: RecipeShareAdvertisement.publishedFields(
                from: [
                    RecipeShareAdvertisement.versionKey: RecipeShareAdvertisement.version,
                    RecipeShareAdvertisement.modeKey: RecipeShareAdvertisement.mode,
                    RecipeShareAdvertisement.nameKey: name
                ],
                sessionID: sessionID
            )
        )
    }

    /// A name that sorts ABOVE `name`, so a peer wearing it is the preferred dialer — every real
    /// instance name starts `fernlet-mesh-`, so these two helpers cannot collide with one.
    private func outranking(_ name: String) -> String { "zz" + name }

    /// A name that sorts BELOW `name`.
    private func outranked(_ name: String) -> String { "aa" + name }

    // MARK: - The posture and what goes on the air

    /// The radio advertises the owner's fields beside a `sid` of its OWN, under a fresh instance
    /// name and a fresh certificate, and a second `start()` on a second radio shares nothing.
    ///
    /// This is pass 2's posture claim, and it is the one thing a source scan cannot see: a radio
    /// that reused the retired transport's device-name identity would compile, would advertise, and
    /// would look exactly like this from the outside.
    @Test func theRadioAdvertisesAFreshPostureBesideTheOwnersFields() throws {
        let radio = NetworkRecipeShareSession()
        let owner = [
            RecipeShareAdvertisement.versionKey: RecipeShareAdvertisement.version,
            RecipeShareAdvertisement.modeKey: RecipeShareAdvertisement.mode,
            RecipeShareAdvertisement.nameKey: "Alex"
        ]
        let posture = try radio.runWithoutRadiosForTesting(advertisement: owner)

        let fields = radio.advertisedFieldsForTesting
        #expect(fields[RecipeShareAdvertisement.versionKey] == "1")
        #expect(fields[RecipeShareAdvertisement.modeKey] == "recipe")
        #expect(fields[RecipeShareAdvertisement.nameKey] == "Alex")
        #expect(fields[RecipeShareAdvertisement.sessionIDKey] == posture.sessionID,
                "the sid on the air is the radio's own, not a copy the owner kept")
        #expect(radio.advertisedSessionID == posture.sessionID)
        #expect(radio.advertisedInstanceNameForTesting == posture.instanceName)
        #expect(posture.instanceName.hasPrefix(MeshLinkAdvertisement.instanceNamePrefix),
                "the name is the mesh's random shape, never a device name")

        let second = NetworkRecipeShareSession()
        let other = try second.runWithoutRadiosForTesting(advertisement: owner)
        #expect(other.instanceName != posture.instanceName)
        #expect(other.sessionID != posture.sessionID)
        #expect(other.tlsIdentity.certificateDER != posture.tlsIdentity.certificateDER,
                "two radios must not share a certificate")
    }

    /// Every published TXT entry fits DNS-SD's 255-byte ceiling, at the longest name the owner can
    /// publish.
    ///
    /// Presence learned this the expensive way: 24 advertised tags were already 311 bytes, over the
    /// limit before the key was counted, and `NWTXTRecord` either refuses or truncates. This
    /// record's worst case is asserted rather than assumed.
    @Test func everyAdvertisedEntryFitsTheTXTLimit() throws {
        let longest = String(repeating: "a", count: MeshLinkAdvertisement.maxFieldValueLength)
        let fields = RecipeShareAdvertisement.publishedFields(
            from: [
                RecipeShareAdvertisement.versionKey: RecipeShareAdvertisement.version,
                RecipeShareAdvertisement.modeKey: RecipeShareAdvertisement.mode,
                RecipeShareAdvertisement.nameKey: longest
            ],
            sessionID: UUID().uuidString
        )
        #expect(fields.count == 4)
        #expect(RecipeShareAdvertisement.entriesFitTheTXTLimit(fields))
        #expect(!RecipeShareAdvertisement.entriesFitTheTXTLimit(
            ["t": String(repeating: "x", count: RecipeShareAdvertisement.maxEntryByteCount)]
        ), "the bound is a bound — an over-long entry must fail it")
    }

    /// A record that is not a version-1 recipe advertisement names no session id, in either
    /// direction: a presence or mesh registration browsed on the wrong service type, or a peer that
    /// publishes `sid` with no `mode`, must not resolve a dialer.
    @Test func onlyAVersionOneRecipeAdvertisementCarriesASessionID() {
        let good = RecipeShareAdvertisement.publishedFields(
            from: [
                RecipeShareAdvertisement.versionKey: RecipeShareAdvertisement.version,
                RecipeShareAdvertisement.modeKey: RecipeShareAdvertisement.mode
            ],
            sessionID: "abc"
        )
        #expect(RecipeShareAdvertisement.sessionID(from: good) == "abc")
        #expect(RecipeShareAdvertisement.sessionID(from: ["sid": "abc"]) == nil)
        #expect(RecipeShareAdvertisement.sessionID(from: ["v": "2", "mode": "recipe", "sid": "abc"]) == nil)
        #expect(RecipeShareAdvertisement.sessionID(from: ["v": "1", "mode": "near", "sid": "abc"]) == nil)
        #expect(RecipeShareAdvertisement.sessionID(from: nil) == nil)
    }

    // MARK: - The dial hello

    /// The hello is a golden frame: two frozen keys, in canonical (sorted) order, and nothing else.
    ///
    /// The ordering is pinned by the encoder rather than by the property declarations — the
    /// synthesized `Codable` emitted them the other way round on this toolchain, which is exactly
    /// the kind of thing a golden vector is supposed to catch before a peer does.
    @Test func theDialHelloIsAGoldenFrame() throws {
        let encoded = try RecipeShareDialHello.encoded(sessionID: "550e8400-e29b-41d4-a716-446655440000")
        #expect(String(data: encoded, encoding: .utf8) ==
                #"{"sid":"550e8400-e29b-41d4-a716-446655440000","v":"1"}"#)
        #expect(encoded.count <= RecipeShareDialHello.maxEncodedBytes)
        let decoded = try #require(RecipeShareDialHello.decoded(encoded))
        #expect(decoded.sessionID == "550e8400-e29b-41d4-a716-446655440000")
        #expect(decoded.version == RecipeShareAdvertisement.version)
    }

    /// The decoder's half of the rejection matrix: every malformed shape answers nil, which the
    /// radio turns into a refusal before any channel or handle exists.
    @Test func theDialHelloRefusesEveryMalformedShape() throws {
        let cases: [(String, Data)] = [
            ("not JSON", Data("nonsense".utf8)),
            ("no version", Data(#"{"sid":"abc"}"#.utf8)),
            ("wrong version", Data(#"{"v":"2","sid":"abc"}"#.utf8)),
            ("no sid", Data(#"{"v":"1"}"#.utf8)),
            ("empty sid", Data(#"{"v":"1","sid":""}"#.utf8)),
            ("over-long sid", Data(
                "{\"v\":\"1\",\"sid\":\"\(String(repeating: "x", count: MeshLinkAdvertisement.maxFieldValueLength + 1))\"}".utf8
            )),
            ("oversize frame", Data(count: RecipeShareDialHello.maxEncodedBytes + 1))
        ]
        for (label, wire) in cases {
            #expect(RecipeShareDialHello.decoded(wire) == nil, "\(label) was believed")
        }
        // And the encoder refuses to WRITE a frame it would refuse to read.
        #expect(throws: MeshTransportError.self) {
            _ = try RecipeShareDialHello.encoded(
                sessionID: String(repeating: "y", count: RecipeShareDialHello.maxEncodedBytes)
            )
        }
    }

    /// The radio's half of the matrix: an unwired owner resolves nobody, our OWN session id is
    /// refused as a self-dial, a `sid` no browsed peer carries is refused, and a resolved peer the
    /// owner declines is refused too. Only the last row admits.
    @Test func anInboundDialerResolvesOnlyToABrowsedPeerTheOwnerAccepts() throws {
        let radio = NetworkRecipeShareSession()
        let posture = try radio.runWithoutRadiosForTesting()
        let friend = peer(advertisingSessionID: "friend-sid")

        // Fail closed: nothing wired at all.
        #expect(radio.resolveInboundForTesting(RecipeShareDialHello(sessionID: "friend-sid")) == nil,
                "a radio nobody has wired must resolve nobody")

        radio.resolveDialer = { $0 == "friend-sid" ? friend : nil }
        radio.shouldAcceptDialer = { _ in false }
        #expect(radio.resolveInboundForTesting(RecipeShareDialHello(sessionID: "friend-sid")) == nil,
                "the owner's cap gate said no and the connection was admitted anyway")

        radio.shouldAcceptDialer = { _ in true }
        #expect(radio.resolveInboundForTesting(RecipeShareDialHello(sessionID: "nobody")) == nil,
                "a sid no browse result carries must not resolve")
        #expect(radio.resolveInboundForTesting(RecipeShareDialHello(sessionID: posture.sessionID)) == nil,
                "our own sid is an echo or a replay, never a peer")
        #expect(radio.resolveInboundForTesting(RecipeShareDialHello(sessionID: "friend-sid"))?.id == friend.id)
    }

    // MARK: - Pause, resume, stop

    /// A pause stands discovery down; a resume reopens it under a WHOLLY new posture — new name,
    /// new certificate, new session id.
    ///
    /// The re-mint is the half a reviewer would not miss if it were absent: a pause and its resume
    /// bracket a pairing, so coming back under the same name hands any scanner in the room "the
    /// device that went quiet is the device that came back".
    @Test func aResumeReopensDiscoveryUnderAWhollyNewPosture() throws {
        let radio = NetworkRecipeShareSession()
        let first = try radio.runWithoutRadiosForTesting()
        #expect(!radio.isDiscoveryPaused)

        radio.pauseDiscovery()
        #expect(radio.isDiscoveryPaused)
        #expect(radio.advertisedInstanceNameForTesting == first.instanceName,
                "a pause withdraws the registration; it does not re-mint")

        radio.resumeDiscovery()
        #expect(!radio.isDiscoveryPaused)
        #expect(radio.advertisedInstanceNameForTesting != first.instanceName)
        #expect(radio.advertisedSessionID != first.sessionID)
        #expect(radio.advertisedCertificateForTesting != first.tlsIdentity.certificateDER)
    }

    /// A pause is idempotent, a resume over an unpaused radio is a no-op, and neither touches a
    /// radio that was never started.
    @Test func pauseAndResumeAreRefusedOnARadioThatIsNotUp() {
        let radio = NetworkRecipeShareSession()
        radio.pauseDiscovery()
        #expect(!radio.isDiscoveryPaused, "a stopped radio has no discovery to stand down")
        radio.resumeDiscovery()
        #expect(!radio.isDiscoveryPaused)
    }

    /// **`stop()` clears the radio's OWN pause flag.**
    ///
    /// ``RecipeShareDiscoveryGate``'s three "unchanged" rows — `refreshRequested`,
    /// `transportErrorWhileListening` and `stopped` — say discovery is resolved by the radio's own
    /// `stop()`/`start()` rather than by the gate. That is only true if the flag resets here: a
    /// pause that survived a stop would leave the next `start()` advertising behind a radio that
    /// believes it is closed, and the gate would never reopen it because `connectionsEvicted`
    /// requires `isPaused` to be *this* radio's paused, not a stale one's.
    @Test func stoppingClearsTheRadiosOwnPauseFlag() throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        radio.pauseDiscovery()
        #expect(radio.isDiscoveryPaused)

        radio.stop()

        #expect(!radio.isDiscoveryPaused, "a stopped radio must not come back up still holding a pause")
        #expect(!radio.isRunning)
        #expect(radio.advertisedInstanceNameForTesting == nil, "and it keeps no posture")
        #expect(radio.advertisedSessionID.isEmpty)

        try radio.runWithoutRadiosForTesting()
        #expect(!radio.isDiscoveryPaused, "the restart is open")
    }

    // MARK: - Dialing and glare

    /// A dial for a peer whose registration has gone is a refusal, not a transport failure.
    ///
    /// The regression this guards is item 2's: a per-dial miss reported through `onTransportError`
    /// reaches the owner's START-failure door and stands the WHOLE radio down — here, in the
    /// middle of the user tapping a recipient whose Bonjour registration happened to lapse.
    @Test func aDialForAPeerWithNoBrowsedEndpointRefusesTheDialAndNotTheRadio() throws {
        let radio = NetworkRecipeShareSession()
        let posture = try radio.runWithoutRadiosForTesting()
        var reported: [String] = []
        radio.onTransportError = { reported.append($0) }

        let key = MeshLinkKey("endpoint-gone")
        radio.dial(radio.handleForTesting(key), helloSID: posture.sessionID)

        #expect(reported.isEmpty, "a per-dial miss must never reach the owner's start-failure door")
        #expect(radio.isRunning, "the radio is still up")
        #expect(radio.advertisedInstanceNameForTesting == posture.instanceName)
        #expect(radio.tunnelCountForTesting == 0, "and it opened nothing")
    }

    /// Two Fernlets that sight each other at the same moment and both dial keep exactly ONE
    /// connection, and it is the same connection seen from both ends.
    ///
    /// Refusing the inbound on both sides ends with zero tunnels — the refusal closes the peer's
    /// connection, so each side's own dial dies at the far end too. The rule is the mesh's
    /// `MeshTunnelConvergence` over the two advertised instance names.
    @Test func simultaneousDialsCollapseToOneConnectionTheSameWayOnBothDevices() throws {
        let alice = NetworkRecipeShareSession()
        let bob = NetworkRecipeShareSession()
        let alicePosture = try alice.runWithoutRadiosForTesting()
        let bobPosture = try bob.runWithoutRadiosForTesting()

        let bobKey = MeshLinkKey("bob-endpoint")
        let aliceKey = MeshLinkKey("alice-endpoint")
        alice.noteBrowsedNameForTesting(bobKey, instanceName: bobPosture.instanceName)
        bob.noteBrowsedNameForTesting(aliceKey, instanceName: alicePosture.instanceName)
        alice.bookTunnelForTesting(bobKey, role: .initiator)
        bob.bookTunnelForTesting(aliceKey, role: .initiator)

        let aliceAdmits = alice.admitInboundForTesting(at: bobKey)
        let bobAdmits = bob.admitInboundForTesting(at: aliceKey)
        #expect(aliceAdmits != bobAdmits, "exactly one side yields — both yielding or both refusing is the bug")

        if aliceAdmits { alice.bookTunnelForTesting(bobKey, role: .responder) }
        if bobAdmits { bob.bookTunnelForTesting(aliceKey, role: .responder) }
        #expect(alice.tunnelCountForTesting == 1)
        #expect(bob.tunnelCountForTesting == 1)
        let aliceRole = try #require(alice.tunnelRoleForTesting(at: bobKey))
        let bobRole = try #require(bob.tunnelRoleForTesting(at: aliceKey))
        #expect(aliceRole != bobRole, "the survivor must be ONE connection seen from both ends")
        #expect((aliceRole == .initiator) == (alicePosture.instanceName > bobPosture.instanceName))
    }

    /// When the tie-break says the arriving connection wins, we yield and the OWNER IS TOLD — the
    /// channel-ready gate answers "already connected" for a device it still holds a record for, so
    /// a silent yield would leave a coordinator waiting on a dead connection.
    @Test func aYieldEndsTheHeldTunnelAndTellsTheOwner() throws {
        let radio = NetworkRecipeShareSession()
        let posture = try radio.runWithoutRadiosForTesting()
        let key = MeshLinkKey("peer-endpoint")
        radio.noteBrowsedNameForTesting(key, instanceName: outranking(posture.instanceName))
        radio.bookTunnelForTesting(key, role: .initiator)

        var disconnects: [String] = []
        radio.onPeerDisconnected = { _, reason in disconnects.append(reason) }
        var reported: [String] = []
        radio.onTransportError = { reported.append($0) }

        #expect(radio.admitInboundForTesting(at: key), "the peer must not be refused")
        #expect(radio.tunnelCountForTesting == 0, "our own dial was collapsed to make room")
        #expect(disconnects == [NetworkRecipeShareSession.redundantTunnelCloseReason])
        #expect(reported.isEmpty, "a collapse is not a transport failure")
    }

    /// And when our connection is the survivor, the arriving one is dropped and nothing we hold is
    /// disturbed — including the hard cap, which refuses a SECOND device outright.
    @Test func anInboundThatLosesTheTieBreakLeavesTheHeldTunnelAloneAndAThirdDeviceIsCapped() throws {
        let radio = NetworkRecipeShareSession()
        let posture = try radio.runWithoutRadiosForTesting()
        let key = MeshLinkKey("peer-endpoint")
        radio.noteBrowsedNameForTesting(key, instanceName: outranked(posture.instanceName))
        radio.bookTunnelForTesting(key, role: .initiator)

        var disconnects: [PeerHandle] = []
        radio.onPeerDisconnected = { peer, _ in disconnects.append(peer) }

        #expect(!radio.admitInboundForTesting(at: key))
        #expect(radio.tunnelCountForTesting == 1, "the connection we hold is untouched")
        #expect(disconnects.isEmpty, "and the owner hears nothing, because nothing of its own ended")

        // The cap's radio-level floor: recipe sharing links two Fernlets at a time.
        #expect(NetworkRecipeShareSession.maxTunnels == 1)
        #expect(!radio.admitInboundForTesting(at: MeshLinkKey("third-device")),
                "a second device must never be seated, however the owner is wired")
    }

    /// The connecting window: a dial in flight is a connecting peer until its control stream
    /// arrives, and the peer it is for is not "besides" itself.
    @Test func aDialInFlightCountsAsAConnectingPeerUntilItActivates() throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        #expect(!radio.hasConnectingPeers(besides: nil))

        let key = MeshLinkKey("peer-endpoint")
        let peer = radio.handleForTesting(key)
        radio.bookTunnelForTesting(key, role: .initiator)

        #expect(radio.hasConnectingPeers(besides: nil))
        #expect(!radio.hasConnectingPeers(besides: peer), "a peer is not besides itself")
    }

    // MARK: - The inbound dialer gate

    /// **The only inbound dial in flight is ADMITTED.**
    ///
    /// The cell this pass did not have, and the one defect it would have caught outright: a QUIC
    /// responder has to BOOK a pending connection before it can read anything off it, so by the
    /// time the owner's gate is asked, the connection being ruled on is already sitting in the
    /// connecting window. A window that counted it answered "something else is mid-connect" about
    /// the connection itself and refused every inbound dial there is — end to end, both users see
    /// the sender's 12 s "that Fernlet may be busy sharing with someone else".
    ///
    /// The gate is wired the shape `ProximityRecipeShareManager` wires it, ending in
    /// `hasConnectingPeers(besides:)`, because that is where the question is actually asked.
    @Test func theOnlyInboundDialInFlightIsAdmitted() throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        let browsed = MeshLinkKey("friend-endpoint")
        radio.noteBrowsedNameForTesting(browsed, instanceName: "fernlet-mesh-friendname")
        let friend = radio.handleForTesting(browsed)
        radio.resolveDialer = { $0 == "friend-sid" ? friend : nil }
        radio.shouldAcceptDialer = { [weak radio] peer in
            guard let radio else { return false }
            return !radio.hasConnectingPeers(besides: peer)
        }

        let pending = MeshLinkKey("inbound-connection")
        radio.bookPendingInboundForTesting(pending)
        #expect(radio.pendingInboundCountForTesting == 1, "booked before the hello, as the radio books it")

        let admitted = radio.adjudicateInboundForTesting(
            RecipeShareDialHello(sessionID: "friend-sid"), pendingKey: pending
        )
        #expect(admitted == browsed, """
            the inbound dial was refused with nothing else in flight — the connecting window \
            counted the very connection its gate was being asked to rule on
            """)
        #expect(radio.pendingInboundCountForTesting == 0, "an admitted connection stops being pending")
    }

    /// And its sibling, which is the half the exclusion must not cost: a SECOND dialer arriving
    /// while one is still mid-hello is refused, so two devices cannot race past the cap.
    @Test func aSecondDialerArrivingWhileOneIsMidHelloIsRefused() throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        let browsed = MeshLinkKey("friend-endpoint")
        radio.noteBrowsedNameForTesting(browsed, instanceName: "fernlet-mesh-friendname")
        let friend = radio.handleForTesting(browsed)
        radio.resolveDialer = { $0 == "friend-sid" ? friend : nil }
        radio.shouldAcceptDialer = { [weak radio] peer in
            guard let radio else { return false }
            return !radio.hasConnectingPeers(besides: peer)
        }

        let first = MeshLinkKey("inbound-connection-1")
        let second = MeshLinkKey("inbound-connection-2")
        radio.bookPendingInboundForTesting(first)
        radio.bookPendingInboundForTesting(second)

        #expect(radio.adjudicateInboundForTesting(
            RecipeShareDialHello(sessionID: "friend-sid"), pendingKey: first
        ) == nil, "a second connection mid-hello is a connecting peer and the cap must hold")
        #expect(radio.pendingInboundCountForTesting == 2, "a refusal does not drop the OTHER connection")
    }

    /// The owner's own gate, over the seam: a booked pending inbound that is the one being
    /// adjudicated does not refuse itself, and a second booked connection does refuse it.
    @Test func theOwnersGateRulesOnAPendingInboundWithoutCountingIt() {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        let dialer = makePeer(named: "Blair")

        radio.pendingInboundKeys = ["inbound-1"]
        radio.adjudicatingInboundKey = "inbound-1"
        #expect(manager.shouldAcceptDialerForTesting(dialer),
                "the owner refused the only dialer there was")

        radio.pendingInboundKeys = ["inbound-1", "inbound-2"]
        #expect(!manager.shouldAcceptDialerForTesting(dialer),
                "a second connection mid-hello must still refuse the cap's fourth layer")
    }

    // MARK: - What a user is allowed to read

    /// **No `fernlet-mesh-` token may reach anything a user reads.**
    ///
    /// `PeerHandle.displayHint` changed meaning with the transport: under MultipeerConnectivity it
    /// was `UIDevice.current.name`, a name a person chose; under QUIC the only candidates are the
    /// random Bonjour instance name and the endpoint key that contains it. The picker row, the
    /// four "Connection details" lines and the cap's status line all used to render it directly.
    ///
    /// The peer here is handed a hint of exactly the shape the radio used to publish, so the cell
    /// fails on any reader that still prefers it.
    @Test func noInstanceNameTokenReachesThePickerOrTheConnectionLog() {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        manager.markRunningForTesting()

        // A browsed peer with NO advertised name, wearing the token as its transport hint.
        let nameless = makePeer(
            named: "fernlet-mesh-3f2a9c81b4de",
            advertising: [
                RecipeShareAdvertisement.versionKey: RecipeShareAdvertisement.version,
                RecipeShareAdvertisement.modeKey: RecipeShareAdvertisement.mode,
                RecipeShareAdvertisement.sessionIDKey: "friend-sid"
            ]
        )
        radio.onPeerDiscovered?(nameless)
        #expect(manager.nearbyRecipients.first?.displayName == ItemNameModeration.moderatedPeerDisplayName(""),
                "a peer that published no name renders the picker's existing placeholder")

        // The connection log, over the surfaces that name a peer. The connection-keyed lines go
        // through the same function by construction (`displayName(for connection:)` delegates).
        radio.onPeerDisconnected?(nameless, "test")
        radio.onPeerLost?(nameless)
        for event in manager.diagnosticEvents {
            #expect(!event.message.contains(MeshLinkAdvertisement.instanceNamePrefix),
                    "a user-visible line named a peer by its Bonjour instance name: \(event.message)")
        }
        #expect(manager.diagnosticEvents.count >= 3, "the lines under test were actually written")
    }

    /// An advertised name is still preferred over the placeholder — the fix must not flatten every
    /// peer to "A friend".
    @Test func anAdvertisedNameStillNamesThePickerRow() {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        manager.markRunningForTesting()

        radio.onPeerDiscovered?(peer(advertisingSessionID: "friend-sid", name: "Blair"))
        #expect(manager.nearbyRecipients.first?.displayName == "Blair")
    }

    // MARK: - Runtime failures of the listener and the browser

    /// **A browser failure while a dial is in flight must not stand the radio down.**
    ///
    /// Under MultipeerConnectivity this door was reachable from `didNotStartBrowsingForPeers`
    /// alone — at start and nowhere else. A QUIC browser fails at runtime, and a stand-down cancels
    /// every tunnel and every pending connection: an interface going away mid-dial would abort the
    /// user's tap and clear the picker.
    @Test func aBrowserFailureDuringTheConnectingWindowLeavesTheDialAlive() {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        manager.markRunningForTesting()
        radio.connectingPeers = [makePeer(named: "Blair")]

        radio.onTransportError?("The recipe-share browser failed: test")

        #expect(manager.isListening, "a dial in flight was cancelled by a browse failure")
        #expect(radio.stopCount == 0, "and the radio was torn down under it")
        #expect(manager.diagnosticEvents.contains { $0.message.contains("browser failed") },
                "nothing about it may be silent")

        // With nothing in flight the same message IS a stand-down, which is the honest answer.
        radio.connectingPeers = []
        radio.onTransportError?("The recipe-share browser failed: test")
        #expect(!manager.isListening)
    }

    /// The radio's own classification of a browser failure: the browser is stood down and audited,
    /// and the radio stays up.
    @Test func aBrowserFailureStandsTheBrowserDownAndNotTheRadio() throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        var reported: [String] = []
        radio.onTransportError = { reported.append($0) }

        radio.reportBrowserFailureForTesting("The recipe-share browser failed: test")

        #expect(!radio.hasBrowserForTesting, "the failed browser is not kept")
        #expect(radio.isRunning, "a browser is the find half; the listener is still up")
        #expect(reported.count == 1, "the owner still hears it — it decides whether to stand down")
    }

    /// **A withdrawn Bonjour registration republishes.** P8 item 0's device finding (b) in its
    /// exact shape: this radio publishes once per `start()`/resume and owns no timer, so a silent
    /// `.remove` leaves nothing on the air with `isListening` still answering yes, forever.
    @Test func aWithdrawnRegistrationRepublishesUnderAFreshPosture() throws {
        let radio = NetworkRecipeShareSession()
        let first = try radio.runWithoutRadiosForTesting()
        var reported: [String] = []
        radio.onTransportError = { reported.append($0) }

        radio.republishListenerForTesting()

        #expect(radio.isRunning, "a republish is not a stand-down")
        #expect(reported.isEmpty, "and a republish that worked is not a start failure")
        #expect(radio.advertisedInstanceNameForTesting != first.instanceName,
                "back on the air under a fresh name — a name that went away and came back is a link")
        #expect(radio.advertisedSessionID != first.sessionID)
        #expect(radio.advertisedCertificateForTesting != first.tlsIdentity.certificateDER)
    }

    /// And the source needle that the `.remove` branch is not a bare assignment — the shape the
    /// whole finding is: a state flag cleared and nothing else done about it.
    @Test func theRegistrationRemoveBranchIsNotABareAssignment() throws {
        let code = MeshRoutedSourceScan.codeOnly(try Self.sessionSource())
        let body = try #require(
            MeshRoutedSourceScan.bracedBody(after: "func listenerRegistrationChanged(", in: code),
            "listenerRegistrationChanged is gone or its braces do not close"
        )
        let removeIndex = try #require(body.range(of: "case .remove:")?.upperBound,
                                       "the `.remove` branch is gone")
        #expect(body[removeIndex...].contains("republishListener()"),
                "a withdrawn registration is silent again: nothing on the air, isListening still true")
    }

    // MARK: - The per-transfer stream

    /// A text recipe rides the control stream; a recipe carrying a picture earns a stream of its
    /// own, and gives the slot back when it finishes.
    ///
    /// The route is projected by size alone through the same table the mesh's photo path uses, so
    /// the projection `RecipeShareTransfer.route` reports and the pipe the radio actually takes
    /// cannot drift apart.
    @Test func aPictureRecipeEarnsATransferStreamAndATextRecipeDoesNot() throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        let key = MeshLinkKey("peer-endpoint")
        radio.bookTunnelForTesting(key, role: .initiator)

        let textBytes = 4 * 1024
        let pictureBytes = ProximityRecipeSharePayload.maxImageBytes
        #expect(MeshTransferStreamTable.route(reliableByteCount: textBytes) == .controlStream)
        #expect(MeshTransferStreamTable.route(reliableByteCount: pictureBytes) == .transferStream)

        #expect(radio.claimOutboundTransferForTesting(key, byteCount: textBytes) == nil,
                "a text recipe must stay in order on the control stream")
        let claim = try #require(radio.claimOutboundTransferForTesting(key, byteCount: pictureBytes))
        radio.releaseOutboundTransferForTesting(key, id: claim)
        #expect(radio.claimOutboundTransferForTesting(key, byteCount: pictureBytes) != nil,
                "the slot was not given back")
    }

    /// The inbound acceptor's budget: a peer may hold at most
    /// `MeshTransferStreamTable.maxConcurrentInbound` streams, and a stream for a tunnel this radio
    /// does not hold is refused before a byte is read.
    @Test func theInboundTransferBudgetIsBoundedAndAnUnknownTunnelIsRefused() throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        let key = MeshLinkKey("peer-endpoint")
        radio.bookTunnelForTesting(key, role: .responder)

        for index in 0..<MeshTransferStreamTable.maxConcurrentInbound {
            #expect(radio.claimInboundTransferForTesting(key) != nil, "slot \(index) was refused")
        }
        #expect(radio.claimInboundTransferForTesting(key) == nil, "the budget is not a bound")
        #expect(radio.claimInboundTransferForTesting(MeshLinkKey("stranger")) == nil,
                "a stream from a connection this radio never admitted must never reach a channel")
    }

    /// A frame above the shared wire ceiling is refused by the sender, before any stream is opened.
    @Test func anOversizedFrameIsRefusedBeforeItIsWritten() async throws {
        let radio = NetworkRecipeShareSession()
        try radio.runWithoutRadiosForTesting()
        let key = MeshLinkKey("peer-endpoint")
        radio.bookTunnelForTesting(key, role: .initiator)
        let peer = radio.handleForTesting(key)

        await #expect(throws: PeerTransportError.self) {
            try await radio.send(
                Data(count: NetworkRecipeShareSession.maxInboundWireBytes + 1),
                to: peer,
                mode: .reliable
            )
        }
        #expect(NetworkRecipeShareSession.maxInboundWireBytes == NetworkMeshSession.maxInboundWireBytes,
                "all three transports must refuse identically")
        #expect(ProximityRecipeSharePayload.maxWireBytes < NetworkRecipeShareSession.maxInboundWireBytes,
                "an honest recipe must fit the ceiling with room to seal")
    }

    /// The channel path round-trips a payload, and holds its radio weakly (memory lifecycle: the
    /// manager owns the session, the session's channels point back weakly).
    @Test func theChannelRoundTripsAPayloadAndHoldsItsRadioWeakly() async throws {
        let radio = FakeRecipeShareRadioSession()
        let target = makePeer(named: "Blair")
        let channel = radio.channel(for: target)

        var received: [Data] = []
        let subscription = channel.inbound.sink { received.append($0.data) }
        defer { subscription.cancel() }

        let payload = Data("a sealed recipeShare".utf8)
        channel.receive(payload, at: Date())
        #expect(received == [payload])
        try await channel.send(payload, to: target, mode: .reliable)
        #expect(radio.sent.first?.data == payload)

        var transient: FakeRecipeShareRadioSession? = FakeRecipeShareRadioSession()
        let orphan = try #require(transient?.channel(for: target))
        transient = nil
        await #expect(throws: PeerTransportError.self) {
            try await orphan.send(Data([0x01]), to: target, mode: .reliable)
        }
    }

    // MARK: - The manager over the seam

    /// A QUIC start failure stands the radio down by its own account, so the run-policy seam
    /// re-applies a running verdict at its next run rather than waiting for a verdict edge.
    @Test func aStartFailureStandsTheManagerDownByItsOwnAccount() {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        radio.startError = MeshTransportError.tlsIdentityUnavailable
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })

        manager.start()

        #expect(!manager.isListening, "a radio that never came up must not read as listening")
        #expect(manager.diagnosticEvents.contains { $0.message.contains("retry on the next app event") })
    }

    /// The manager dials claiming the RADIO's current session id — never a copy of its own, which
    /// would go stale at the first resume.
    @Test func aSendDialsClaimingTheRadiosCurrentSessionID() throws {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        manager.markRunningForTesting()
        let target = peer(advertisingSessionID: "their-sid")
        radio.onPeerDiscovered?(target)
        let recipient = try #require(manager.nearbyRecipients.first)

        manager.sendRecipeShare(makeSharePayload(), to: recipient)

        #expect(radio.dials.count == 1)
        #expect(radio.dials.first?.helloSID == radio.advertisedSessionID)
        #expect(radio.dials.first?.peer.id == target.id)
    }

    /// The manager's dialer resolution: a browsed peer is found by the `sid` it advertises, and our
    /// own echo never enters the browse list in the first place.
    @Test func theManagerResolvesADialerBySessionIDAndDropsItsOwnEcho() throws {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        let target = peer(advertisingSessionID: "their-sid")
        radio.onPeerDiscovered?(target)

        #expect(manager.resolveDialerForTesting("their-sid")?.id == target.id)
        #expect(manager.resolveDialerForTesting("nobody") == nil)
        #expect(manager.resolveDialerForTesting("") == nil)

        let echo = peer(advertisingSessionID: radio.advertisedSessionID)
        radio.onPeerDiscovered?(echo)
        #expect(manager.nearbyRecipients.count == 1, "our own advertisement reached the picker")
    }

    // MARK: - The per-send token (pass 1's recorded defect)

    /// Two overlapping shares to ONE already-paired peer: the first send's completion must land on
    /// the record that began it, not on whichever record happens to be live.
    ///
    /// `recipientID` cannot tell them apart — it is the same peer — so without a per-send token the
    /// older send's completion is counted against the newer record, and the status line credits the
    /// wrong recipe. Pass 1 recorded this and left it; this is the fix.
    @Test func aCompletionIsAttributedToTheSendThatBeganIt() throws {
        let host = RecipeQUICTestHost()
        let radio = FakeRecipeShareRadioSession()
        let manager = ProximityRecipeShareManager(store: host, makeSession: { radio })
        let recipientID = UUID()

        manager.beginTransferForTesting(recipientID: recipientID)
        let firstToken = try #require(manager.transferForTesting?.token)
        manager.applyTransferForTesting(.peerVerified)
        #expect(manager.applyTransferForTesting(.sendBegan(wireByteCount: 2_048), token: firstToken))

        // The user picks the same peer again before the first send returns.
        manager.beginTransferForTesting(recipientID: recipientID)
        let secondToken = try #require(manager.transferForTesting?.token)
        #expect(secondToken != firstToken)

        #expect(manager.applyTransferForTesting(.sendCompleted, token: firstToken) == false,
                "the older send's completion was counted against the newer share")
        #expect(manager.transferForTesting?.completionCount == 0)
        #expect(manager.transferForTesting?.phase == .connecting)

        // The newer send's own outcome still lands.
        manager.applyTransferForTesting(.peerVerified)
        #expect(manager.applyTransferForTesting(.sendBegan(wireByteCount: 2_048), token: secondToken))
        #expect(manager.applyTransferForTesting(.sendCompleted, token: secondToken))
        #expect(manager.transferForTesting?.completionCount == 1)
    }

    // MARK: - Rule-7 gates

    /// The listener and browser task bodies check for cancellation before they report.
    ///
    /// A source claim because it has to be: `NetworkListener.run` is a framework call a unit test
    /// cannot make throw. The order is the whole of it — `pauseDiscovery()` cancels the listener
    /// task every time a pairing forms, so a `CancellationError` reported as a start failure would
    /// stand the radio down on the very event that is supposed to keep it up and quiet.
    @Test func theListenerAndBrowserTasksDoNotReportTheirOwnCancellation() throws {
        let code = MeshRoutedSourceScan.codeOnly(try Self.sessionSource())
        // The browser's door is `reportBrowserFailure(` since the runtime-failure fix — a browser
        // failure is not a start failure — so each task is pinned to the door it actually uses.
        let doors = [
            "func startListener() throws": "report(",
            "func startBrowser()": "reportBrowserFailure("
        ]
        for (signature, door) in doors.sorted(by: { $0.key < $1.key }) {
            let body = try #require(
                MeshRoutedSourceScan.bracedBody(after: signature, in: code),
                "\(signature) is gone or its braces do not close"
            )
            let guardIndex = try #require(
                body.range(of: "guard !Task.isCancelled else { return }")?.lowerBound,
                "\(signature)'s task body reports without checking for its own cancellation first"
            )
            let reportIndex = try #require(
                body.range(of: door)?.lowerBound, "\(signature) no longer reports at all"
            )
            #expect(guardIndex < reportIndex, "\(signature) guards AFTER it reports, which guards nothing")
        }
    }

    /// **The rule-7 gate for pass 2.** Pass 1 changed nothing on the air, so the only mechanical
    /// proof that pass 2 RAN is that the retired radio is gone from the manager, the new service
    /// type is declared, and the session binds its own ALPN.
    ///
    /// Pinned in both directions — a file that names neither has been renamed or emptied, not
    /// cleaned.
    ///
    /// Vacuous by design since the deletion round (2026-09-22): the framework is gone from the tree,
    /// so these needles can no longer match anything. Kept anyway — they cost nothing and they are
    /// the per-manager half of the tree-wide wall (`TransportNeutralityBoundaryTests`).
    @Test func theManagerNoLongerNamesTheRetiredRadio() throws {
        let source = try Self.managerSource()
        let code = MeshRoutedSourceScan.codeOnly(source)
        for needle in ["MeshMultipeerSession", "MCPeerID", "MCSession", "MultipeerConnectivity",
                       "PeerChannelTransport", "shouldAcceptInvitation", "hasPendingConnections",
                       "disconnectPeer"] {
            #expect(!code.contains(needle), "ProximityRecipeShareManager still names `\(needle)` in code")
        }
        // One FILE is not the unit: an `extension ProximityRecipeShareManager` in a new file, or a
        // `typealias`, reintroduces every needle above without reddening a scan of this one. The
        // subtree is, and `displayHint` joins the list — under QUIC the hint is empty, so a reader
        // that still prefers it renders nothing where a name belongs.
        for (path, other) in try Self.recipeSharingSources() where path != Self.managerPath {
            let otherCode = MeshRoutedSourceScan.codeOnly(other)
            for needle in ["MeshMultipeerSession", "MCPeerID", "MCSession", "MultipeerConnectivity",
                           "displayHint"] {
                #expect(!otherCode.contains(needle), "\(path) names `\(needle)` in code")
            }
        }
        #expect(!code.contains("displayHint"),
                "a user-visible line names a peer by the transport hint again — see displayName(for peer:)")
        #expect(code.contains("RecipeShareRadioSession"), "and it drives the QUIC recipe radio's seam")
        #expect(code.contains("NetworkRecipeShareSession"), "whose production conformer it builds")
        #expect(code.contains("RecipeShareAdvertisement"), "through the recipe TXT vocabulary")

        // Comments get the narrower rule the presence retirement drew: a framework API TYPE name in
        // prose describes machinery this file no longer has, while the framework's NAME describes
        // history and is the sentence that explains why the posture is ephemeral at all.
        for needle in ["MCPeerID", "MCSession", "MCNearbyServiceAdvertiser", "MCNearbyServiceBrowser"] {
            #expect(!source.contains(needle),
                    "a ProximityRecipeShareManager comment still describes `\(needle)` machinery")
        }
    }

    /// The recipe radio's service type and ALPN are its own, and the Info.plist carries the type.
    ///
    /// A service type missing from `NSBonjourServices` fails discovery silently on device, and a
    /// shared ALPN would let a recipe dial complete a TLS handshake with a mesh or presence
    /// listener.
    @Test func theRecipeServiceTypeIsItsOwnAndIsDeclared() throws {
        #expect(NetworkRecipeShareSession.serviceType == "_fernlet-recipe2._udp")
        #expect(NetworkRecipeShareSession.alpn == "fernlet-recipe-v1")
        #expect(NetworkRecipeShareSession.serviceType != NetworkMeshSession.friendServiceType)
        #expect(NetworkRecipeShareSession.serviceType != NetworkPresenceSession.serviceType)
        #expect(NetworkRecipeShareSession.alpn != NetworkMeshSession.alpn)
        #expect(NetworkRecipeShareSession.alpn != NetworkPresenceSession.alpn)
        let plist = try RepoRoot.source("App/Fernlet/Info.plist")
        #expect(plist.contains("<string>\(NetworkRecipeShareSession.serviceType)</string>"))
        let session = try Self.sessionSource()
        #expect(session.contains("alpn: Self.alpn"), "the session must actually bind its ALPN")
    }

    // MARK: - Helpers

    private func makeSharePayload() -> ProximityRecipeSharePayload {
        let createdAt = Date(timeIntervalSince1970: 1_779_664_800)
        let recipe = RecipeDefinition(
            name: "QUIC Test Bowl",
            servings: 1,
            ingredients: [],
            notes: "",
            source: "manual",
            createdAt: createdAt,
            updatedAt: createdAt
        )
        return RecipeShareCodec.proximityPayload(for: recipe, foodItems: [])
    }

    private static let managerPath =
        "FernletKit/Sources/ProximityKit/RecipeSharing/ProximityRecipeShareManager.swift"

    private static func managerSource() throws -> String {
        try RepoRoot.source(managerPath)
    }

    /// Every Swift file under `RecipeSharing/`, plus any file ANYWHERE in ProximityKit that
    /// extends the manager — the unit the rule-7 scan has to cover, because one file is not it.
    private static func recipeSharingSources() throws -> [(String, String)] {
        let root = "FernletKit/Sources/ProximityKit"
        let directory = RepoRoot.url(root)
        let names = try FileManager.default
            .contentsOfDirectory(atPath: directory.appendingPathComponent("RecipeSharing").path)
            .filter { $0.hasSuffix(".swift") }
            .sorted()
        #expect(names.count >= 3, "the RecipeSharing directory moved or emptied — the scan would pass vacuously")
        var sources = try names.prefix(64).map {
            ("\(root)/RecipeSharing/\($0)", try RepoRoot.source("\(root)/RecipeSharing/\($0)"))
        }
        let all = FileManager.default.enumerator(atPath: directory.path)?
            .compactMap { $0 as? String }.filter { $0.hasSuffix(".swift") } ?? []
        for relative in all.sorted().prefix(512) where !relative.hasPrefix("RecipeSharing/") {
            let source = try RepoRoot.source("\(root)/\(relative)")
            guard source.contains("extension ProximityRecipeShareManager") else { continue }
            sources.append(("\(root)/\(relative)", source))
        }
        return sources
    }

    private static func sessionSource() throws -> String {
        try RepoRoot.source("FernletKit/Sources/ProximityKit/Transport/NetworkRecipeShareSession.swift")
    }
}
