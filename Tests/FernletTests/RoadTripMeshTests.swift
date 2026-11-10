@testable import ProximityKit
@testable import FernletSocial
import FernletConnections
import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Road trip mode's mesh exchange (World-RoadTrip-Spec PR 2, owner-approved 2026-11-10), end to end on a test store:
/// the `.roadTrip` handler takes only a kept friend's well-formed body; an offer is answered with a reply computed
/// before the offer is applied; a catch-up sends only the stretch since the last catch-up and keeps only this phone's
/// own presence; received road joins the line and lifts the fog as driven cells, never walked; a member's state
/// moves who maps; an invite is joined or declined; and a decoy sends, receives and keeps nothing.
@Suite(.serialized) @MainActor
struct RoadTripMeshTests {
    let store = makeTestStore()
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)
    private static let here = GeoPoint(45.5205, -122.6255)

    /// `minutes` after the start.
    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// A kept friend's verified identity, trusted in `store`'s vault unless `kept` is false.
    static func friend(_ name: String, key: UInt8, in store: FernletStore, kept: Bool = true,
                       capabilities: [String] = [ProximityCapability.roadTrip.rawValue]) -> ProximityCoordinator.PeerIdentity {
        let signing = Data(repeating: key, count: 32)
        let peer = ProximityCoordinator.PeerIdentity(
            id: UUID(), displayName: name, signingPublicKey: signing, keyAgreementPublicKey: Data(repeating: key &+ 1, count: 32),
            fingerprint: IdentityService.fingerprint(of: signing), rangingMode: .none, firstSeenAt: start,
            capabilities: capabilities)
        if kept { store.proximityTrustVault.trust(peer, mode: .friend) }
        return peer
    }

    /// A trip this store is on with `rae` (her id), started at ``start``, `mapper` mapping.
    static func trip(with rae: String, mapper: String? = nil) -> RoadTrip {
        RoadTrip(id: UUID(), name: nil, startedAt: start, starterID: "me", selfID: "me",
                 members: [RoadTripMember(id: "me", firstName: "Mike"), RoadTripMember(id: rae, firstName: "Rae")],
                 mapperID: mapper ?? "me", mapperOverride: nil, lastCatchUp: start, endedAt: nil, leftAt: nil,
                 atStart: nil, ledger: nil, states: nil, endToTell: nil)
    }

    /// A road east of ``here``: a point every 30 m and 10 s, for `count` points from `first`.
    static func road(_ count: Int, from first: Int = 0) -> [RoadTripPoint] {
        (first..<(first + count)).map {
            RoadTripPoint(point: here.offset(east: Double($0) * 30, north: 0), at: start.addingTimeInterval(Double($0) * 10))
        }
    }

    /// A catch-up from a friend carrying `points`.
    static func catchUp(for tripID: UUID, points: [RoadTripPoint], isReply: Bool = false, onCarPlay: Bool = false,
                        endedAt: Date? = nil) -> RoadTripCatchUpPayload {
        RoadTripCatchUpPayload(tripID: tripID, isReply: isReply, segments: RoadTripWire.segments(points),
                               mapper: RoadTripWireMapperState(onCarPlay: onCarPlay, isCharging: false, takeover: nil),
                               endedAt: endedAt.map(RoadTripPayload.seconds))
    }

    // MARK: The handler

    /// Only a kept, unblocked friend's well-formed body reaches the app, and only while the gate is open; the
    /// handler is registered on the composition's mesh under the road trip token.
    @Test func onlyAKeptFriendsWellFormedBodyGetsThrough() throws {
        let exchange = store.meshFeatures.roadTrip
        #expect(store.meshNetworkManager.hasPayloadHandlerForTesting(forToken: PayloadType.roadTrip.rawValue))
        var invites: [String] = []
        exchange.onInvite = { fingerprint, _ in invites.append(fingerprint) }
        let mike = Self.friend("Mike", key: 7, in: store)
        let stranger = Self.friend("Stranger", key: 9, in: store, kept: false)
        let body = try JSONEncoder().encode(RoadTripPayload.invite(RoadTripWireTests.invite()))
        exchange.receive(body, from: mike)
        exchange.receive(body, from: stranger)
        exchange.receive(Data("{\"version\":1}".utf8), from: mike)
        #expect(invites == [mike.fingerprint], "the stranger and the malformed body were dropped")
        store.duressSessionActive = true
        exchange.receive(body, from: mike)
        #expect(invites.count == 1, "nothing is received in a decoy")
        #expect(exchange.reachableFriends().isEmpty && exchange.offerCatchUp(to: [mike.fingerprint]) == 0)
        store.duressSessionActive = false
    }

    /// An offer's reply is computed before the offer is applied, a reply is never answered, and a second offer from
    /// the same friend within the interval is not answered again.
    @Test func anOfferIsAnsweredOnceWithTheRoadFromBefore() throws {
        let exchange = store.meshFeatures.roadTrip
        var order: [String] = []
        exchange.catchUpProvider = { _, _, isReply in
            order.append(isReply ? "reply" : "offer")
            return Self.catchUp(for: UUID(), points: [], isReply: isReply)
        }
        exchange.onCatchUp = { _, payload in order.append(payload.isReply ? "gotReply" : "gotOffer") }
        let rae = Self.friend("Rae", key: 11, in: store)
        let offer = try JSONEncoder().encode(RoadTripPayload.catchUp(Self.catchUp(for: UUID(), points: Self.road(3))))
        let reply = try JSONEncoder().encode(RoadTripPayload.catchUp(Self.catchUp(for: UUID(), points: [], isReply: true)))
        exchange.receive(offer, from: rae)
        exchange.receive(reply, from: rae)
        exchange.receive(offer, from: rae)
        #expect(order == ["reply", "gotOffer", "gotReply", "gotOffer"], "the order was \(order)")
        exchange.forgetReplies()
        exchange.receive(offer, from: rae)
        #expect(order.suffix(2) == ["reply", "gotOffer"], "a new session answers at once")
    }

    // MARK: The swap

    /// The road a member is sent is the stretch since the last catch-up the two shared; after a catch-up with them,
    /// the next send starts there.
    @Test func aCatchUpSendsOnlyTheStretchSinceTheLastOne() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip(with: "rae")
        #expect(keeper.start(trip))
        #expect(keeper.appendLine(Self.road(60)) == 60)
        let first = try #require(store.roadTripCatchUp(for: "RAE", tripID: nil, isReply: false, now: Self.at(20)))
        #expect(first.tripID == trip.id && first.pointCount == 59 && !first.isReply, "every point after the start")
        store.receiveRoadTripCatchUp(Self.catchUp(for: trip.id, points: []), from: "rae", now: Self.at(6))
        let second = try #require(store.roadTripCatchUp(for: "rae", tripID: trip.id, isReply: true, now: Self.at(20)))
        let sent = RoadTripWire.points(second.segments)
        #expect(sent.allSatisfy { $0.at > Self.at(6) } && sent.count == 23, "only after the catch-up at minute 6")
        #expect(store.roadTripCatchUp(for: "sam", tripID: nil, isReply: false, now: Self.at(20)) == nil, "not on the trip")
        #expect(keeper.active?.ledger?["rae"] == [Self.at(6)] && keeper.active?.lastCatchUp == Self.at(6))
    }

    /// Received road joins the line and lifts the fog along it as driven cells; ground walked before stays walked;
    /// road from before this phone's presence is dropped; the friend on CarPlay becomes the mapper, and this phone a
    /// passenger.
    @Test func receivedRoadIsDrivenAndTheMapperFollows() throws {
        store.worldFog.load()
        let keeper = store.worldFog.roadTrip
        let walked = Self.here.offset(east: 300, north: 0)
        store.worldFog.handle(WorldFix(point: walked, accuracy: 8, at: Self.start, isPrecise: true))
        let walkedCells = Set(MercatorHexGrid.cells(around: walked, within: WorldFogKeeper.liftRadius))
        var trip = Self.trip(with: "rae", mapper: "rae")
        trip.atStart = ["rae"]
        trip.ledger = ["me": [Self.at(2)], "rae": [Self.at(2)]]
        #expect(keeper.start(trip))
        let road = Self.road(40)
        store.receiveRoadTripCatchUp(Self.catchUp(for: trip.id, points: road, onCarPlay: true), from: "rae", now: Self.at(10))
        #expect(keeper.pointCount == road.filter { $0.at >= Self.at(2) }.count, "only from this phone's first catch-up")
        #expect(!store.worldFog.drivenCells.isEmpty && store.worldFog.drivenCells.isSubset(of: store.worldFog.visibleCells))
        #expect(store.worldFog.drivenCells.isDisjoint(with: walkedCells), "walked ground stays walked")
        let early = MercatorHexGrid.cell(containing: road[0].point)
        #expect(!store.worldFog.visibleCells.contains(early) || walkedCells.contains(early), "road before presence lifts nothing")
        // Rae's phone is on CarPlay: she maps, unless this phone is on a power source too (then the starter does).
        let expected = store.roadTripDeviceState().mapsTheRoad ? "me" : "rae"
        #expect(keeper.active?.mapperID == expected && keeper.isPassenger == (expected == "rae"))
        #expect(store.worldLocation.isRoadTripPassenger == keeper.isPassenger, "the passenger gate follows")
        // PR 3: the note waits for the swap's photos to settle, then says Caught up.
        #expect(store.roadTripMesh.isSettling && store.roadTripMesh.caughtUp == nil, "the photos settle first")
        store.roadTripMesh.settleNow()
        #expect(store.roadTripMesh.caughtUp != nil, "Home says Caught up")
    }

    /// A friend's end ends the trip here; a catch-up for a trip this phone is not on changes nothing.
    @Test func aFriendsEndEndsTheTripHere() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip(with: "rae")
        #expect(keeper.start(trip))
        store.receiveRoadTripCatchUp(Self.catchUp(for: UUID(), points: Self.road(5), isReply: true), from: "rae", now: Self.at(5))
        #expect(keeper.active == trip, "another trip's catch-up changed nothing")
        store.receiveRoadTripCatchUp(Self.catchUp(for: trip.id, points: [], endedAt: Self.at(30)), from: "rae", now: Self.at(31))
        #expect(keeper.active == nil && keeper.book.trips.last?.endedAt == Self.at(30))
        #expect(store.roadTripInfo() == nil, "the chip and Trip info go")
    }

    // MARK: Start and join

    /// An invite naming this phone from its starter waits for an answer; Join starts the trip here with everyone at
    /// the start; Not this time from a friend takes them off; Start is offered only in a hangout.
    @Test func anInviteIsHeldAndJoined() throws {
        let selfID = store.roadTripSelfID
        try #require(!selfID.isEmpty, "the mesh identity is provisioned")
        let mike = Self.friend("Mike", key: 21, in: store)
        let mikeID = RoadTripMembers.id(mike.fingerprint)
        let invite = RoadTripInvitePayload(tripID: UUID(), name: nil, starterID: mikeID,
                                           members: [RoadTripWireMember(id: mikeID, firstName: "Mike"),
                                                     RoadTripWireMember(id: selfID, firstName: "Rae"),
                                                     RoadTripWireMember(id: "cccccccccccccccc", firstName: "Sam")],
                                           startedAt: RoadTripPayload.seconds(Self.start))
        store.receiveRoadTripInvite(invite, from: "dddddddddddddddd")
        #expect(store.roadTripMesh.invite == nil, "only its starter may send it")
        store.receiveRoadTripInvite(invite, from: mike.fingerprint)
        #expect(store.roadTripMesh.invite?.id == invite.tripID)
        #expect(store.answerRoadTripInvite(join: true))
        let trip = try #require(store.worldFog.roadTrip.active)
        #expect(trip.id == invite.tripID && trip.selfID == selfID && trip.atStart == trip.memberIDs && store.roadTripMesh.invite == nil)
        store.receiveRoadTripAnswer(RoadTripJoinPayload(tripID: trip.id, joins: false), from: "CCCCCCCCCCCCCCCC")
        #expect(store.worldFog.roadTrip.active?.memberIDs == [mikeID, selfID], "Sam said Not this time")
        store.receiveRoadTripAnswer(RoadTripJoinPayload(tripID: trip.id, joins: false), from: mike.fingerprint)
        #expect(store.worldFog.roadTrip.active?.memberIDs == [mikeID, selfID], "the starter never leaves the record")
        #expect(store.roadTripStartCandidates() == nil, "a trip is on, and there is no hangout")
    }

    /// In a decoy, Start, Join and the swap do nothing, and nothing is kept; the waiting invite goes when one begins.
    @Test func theDecoySendsReceivesAndKeepsNothing() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip(with: "rae")
        #expect(keeper.start(trip))
        let mike = Self.friend("Mike", key: 31, in: store)
        let mikeID = RoadTripMembers.id(mike.fingerprint)
        store.roadTripMesh.offer(RoadTripPendingInvite(from: mikeID, invite: RoadTripWireTests.invite()))
        store.duressSessionActive = true
        #expect(store.roadTripMesh.invite == nil, "the decoy drops the waiting invite")
        #expect(store.roadTripCatchUp(for: "rae", tripID: nil, isReply: false, now: Self.at(5)) == nil)
        store.receiveRoadTripCatchUp(Self.catchUp(for: trip.id, points: Self.road(20)), from: "rae", now: Self.at(5))
        #expect(!store.startRoadTrip(name: "", members: [RoadTripMember(id: "rae", firstName: "Rae")]))
        #expect(!store.answerRoadTripInvite(join: true) && !store.catchUpRoadTrip(with: "rae"))
        #expect(store.worldFog.liftReceivedRoad(Self.road(20).map(\.point)) == 0)
        #expect(store.roadTripMesh.caughtUp == nil)
        store.duressSessionActive = false
        #expect(keeper.active == trip && keeper.pointCount == 0, "nothing of the decoy's reached the real trip")
    }
}
