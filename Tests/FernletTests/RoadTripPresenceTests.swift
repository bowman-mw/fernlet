import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Proof of presence and the catch-up's rules (World-RoadTrip-Spec §2.3, §2.5, §2.6, owner-approved 2026-11-10), as
/// pure functions: "you get only the road between two catch-ups you were part of, plus from the start if you were
/// there at the start"; who maps from every member's state at a stop; the end reaching everyone; Not this time.
@MainActor
struct RoadTripPresenceTests {
    private static let start = Date(timeIntervalSince1970: 2_000_000_000)

    /// `minutes` after the start.
    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// Mike (this iPhone), Rae and Sam; `atStart` nil for all three; Mike starts and maps.
    static func trip(atStart: [String]? = nil, ledger: [String: [Date]]? = nil, mapper: String = "me") -> RoadTrip {
        RoadTrip(id: UUID(), name: nil, startedAt: start, starterID: "me", selfID: "me",
                 members: [RoadTripMember(id: "me", firstName: "Mike"), RoadTripMember(id: "rae", firstName: "Rae"),
                           RoadTripMember(id: "sam", firstName: "Sam")],
                 mapperID: mapper, mapperOverride: nil, lastCatchUp: start, endedAt: nil, leftAt: nil,
                 atStart: atStart, ledger: ledger, states: nil, endToTell: nil)
    }

    /// One point a minute for `minutes` minutes from the start, 1 km apart.
    static func road(_ minutes: Int) -> [RoadTripPoint] {
        (0...minutes).map { RoadTripPoint(point: GeoPoint(45.5, -122.6).offset(east: Double($0) * 1_000, north: 0), at: at(Double($0))) }
    }

    // MARK: What a member is sent

    /// At the first stop everyone who was at the start gets the road from the start; at the next, only the stretch
    /// since the last catch-up they shared with this iPhone.
    @Test func aMemberGetsTheStretchSinceTheirLastCatchUp() throws {
        var trip = Self.trip()
        let first = try #require(RoadTripPresence.sendWindow(to: "rae", in: trip, now: Self.at(60)))
        #expect(first.after == Self.start && first.through == Self.at(60))
        #expect(RoadTripPresence.points(Self.road(120), after: first.after, through: first.through).count == 60,
                "minutes 1 to 60; the start's own point was theirs to see, being there")
        trip = RoadTripPresence.recording(catchUpWith: ["rae"], at: Self.at(60), in: trip)
        let second = try #require(RoadTripPresence.sendWindow(to: "rae", in: trip, now: Self.at(120)))
        #expect(second.after == Self.at(60))
        let stretch = RoadTripPresence.points(Self.road(120), after: second.after, through: second.through)
        #expect(stretch.first?.at == Self.at(61) && stretch.last?.at == Self.at(120) && stretch.count == 60)
        // Sam missed the stop at 60: his stretch still runs from the start, which he was at.
        #expect(RoadTripPresence.sendWindow(to: "sam", in: trip, now: Self.at(120))?.after == Self.start)
        #expect(RoadTripPresence.sendWindow(to: "me", in: trip, now: Self.at(120)) == nil, "never to itself")
        #expect(RoadTripPresence.sendWindow(to: "zoe", in: trip, now: Self.at(120)) == nil, "never to someone not on it")
    }

    /// A member who was not at the start gets nothing until two catch-ups bound their stretch: the first catch-up
    /// with them opens it, and the second sends only what lies between.
    @Test func aMemberNotAtTheStartGetsOnlyBetweenTwoCatchUps() throws {
        var trip = Self.trip(atStart: ["me", "rae"])
        #expect(!RoadTripPresence.wasAtStart("sam", in: trip) && RoadTripPresence.wasAtStart("rae", in: trip))
        #expect(RoadTripPresence.sendWindow(to: "sam", in: trip, now: Self.at(90)) == nil, "no road before their first catch-up")
        trip = RoadTripPresence.recording(catchUpWith: ["sam"], at: Self.at(90), in: trip)
        let window = try #require(RoadTripPresence.sendWindow(to: "sam", in: trip, now: Self.at(150)))
        #expect(window.after == Self.at(90) && window.through == Self.at(150))
        #expect(RoadTripPresence.presence(of: "sam", in: trip) == [Self.at(90)])
        #expect(RoadTripPresence.presence(of: "rae", in: trip) == [Self.start])
    }

    // MARK: What this iPhone accepts

    /// This iPhone keeps only road from its own first presence through now (and a friend's clock running a little
    /// ahead): from the start when it was there, else from its first catch-up.
    @Test func thisPhoneAcceptsOnlyFromItsOwnFirstPresence() throws {
        let there = try #require(RoadTripPresence.acceptWindow(in: Self.trip(), now: Self.at(60)))
        #expect(there.from == Self.start && there.through == Self.at(60).addingTimeInterval(RoadTripPresence.clockSkew))
        let late = Self.trip(atStart: ["rae", "sam"])
        #expect(RoadTripPresence.acceptWindow(in: late, now: Self.at(60)) == nil, "not at the start, no catch-up yet: nothing")
        let caughtUp = RoadTripPresence.recording(catchUpWith: ["rae"], at: Self.at(30), in: late)
        let window = try #require(RoadTripPresence.acceptWindow(in: caughtUp, now: Self.at(90)))
        #expect(window.from == Self.at(30))
        let kept = RoadTripPresence.points(Self.road(120), from: window.from, through: window.through)
        #expect(kept.first?.at == Self.at(30) && kept.last?.at == Self.at(95), "the skew lets five minutes ahead through")
    }

    // MARK: The ledger

    /// The ledger records this iPhone and the friend; a second record at the same stop moves the entry; a full list
    /// moves its last entry, so a member's first presence is never lost; members not on the trip are skipped.
    @Test func theLedgerIsBoundedAndKeepsTheFirstPresence() {
        var trip = RoadTripPresence.recording(catchUpWith: ["rae", "zoe"], at: Self.at(60), in: Self.trip())
        #expect(trip.ledger == ["rae": [Self.at(60)], "me": [Self.at(60)]] && trip.lastCatchUp == Self.at(60))
        trip = RoadTripPresence.recording(catchUpWith: ["rae"], at: Self.at(65), in: trip)
        #expect(trip.ledger?["rae"] == [Self.at(65)], "the offer and its reply are one stop")
        trip = RoadTripPresence.recording(catchUpWith: ["rae"], at: Self.at(120), in: trip)
        #expect(trip.ledger?["rae"] == [Self.at(65), Self.at(120)])
        var full = (0..<RoadTripPresence.maxCatchUps).map { Self.at(Double($0) * 20) }
        full = RoadTripPresence.recorded(Self.at(10_000), in: full)
        #expect(full.count == RoadTripPresence.maxCatchUps && full.first == Self.start && full.last == Self.at(10_000))
        #expect(RoadTripPresence.recorded(Self.at(5), in: [Self.at(10)]) == [Self.at(10)], "never backwards")
        #expect(trip.isValid)
        #expect(RoadTripPresence.recording(catchUpWith: ["zoe"], at: Self.at(130), in: trip) == trip)
    }

    // MARK: Who maps, the end, Not this time

    /// At a stop the friend's state joins this phone's: the one on CarPlay or charging maps; with both or neither,
    /// the starter; and it switches back when that changes.
    @Test func whoMapsSwitchesFromTheMembersStates() {
        let idle = RoadTripDeviceState(onCarPlay: false, isCharging: false)
        let carPlay = RoadTripDeviceState(onCarPlay: true, isCharging: false)
        let raeOnCarPlay = RoadTripReceivedCatchUp(state: carPlay, takeover: nil, endedAt: nil)
        var trip = RoadTripCatchUpRules.applying(raeOnCarPlay, from: "rae", to: Self.trip(), own: idle, now: Self.at(60))
        #expect(trip.mapperID == "rae" && !trip.isMapping, "Rae's phone is on CarPlay: she maps, this phone rests")
        #expect(trip.states == ["rae": carPlay, "me": idle] && trip.ledger?["rae"] == [Self.at(60)])
        trip = RoadTripCatchUpRules.applying(raeOnCarPlay, from: "rae", to: trip, own: RoadTripDeviceState(onCarPlay: false, isCharging: true),
                                             now: Self.at(120))
        #expect(trip.mapperID == "me", "both on a power source: the starter")
        let raeIdle = RoadTripReceivedCatchUp(state: idle, takeover: nil, endedAt: nil)
        trip = RoadTripCatchUpRules.applying(raeIdle, from: "rae", to: trip, own: idle, now: Self.at(180))
        #expect(trip.mapperID == "me")
        #expect(RoadTripCatchUpRules.applying(raeOnCarPlay, from: "zoe", to: trip, own: idle, now: Self.at(200)) == trip)
    }

    /// "Map from this iPhone" made on a friend's phone holds here while the rule answers what it did then, and the
    /// newer of two takeovers wins.
    @Test func aFriendsTakeoverHoldsUntilTheRuleMoves() {
        let idle = RoadTripDeviceState(onCarPlay: false, isCharging: false)
        let samTook = RoadTripMapperOverride(memberID: "sam", at: Self.at(30), ruleAnswer: "me")
        let fromSam = RoadTripReceivedCatchUp(state: idle, takeover: samTook, endedAt: nil)
        var trip = RoadTripCatchUpRules.applying(fromSam, from: "sam", to: Self.trip(), own: idle, now: Self.at(60))
        #expect(trip.mapperID == "sam" && trip.mapperOverride == samTook)
        let raeTook = RoadTripMapperOverride(memberID: "rae", at: Self.at(70), ruleAnswer: "me")
        #expect(RoadTripCatchUpRules.newer(samTook, raeTook, members: trip.memberIDs) == raeTook)
        #expect(RoadTripCatchUpRules.newer(samTook, RoadTripMapperOverride(memberID: "zoe", at: Self.at(90), ruleAnswer: "me"),
                                           members: trip.memberIDs) == samTook)
        let raeOnCarPlay = RoadTripReceivedCatchUp(state: RoadTripDeviceState(onCarPlay: true, isCharging: false), takeover: samTook, endedAt: nil)
        trip = RoadTripCatchUpRules.applying(raeOnCarPlay, from: "rae", to: trip, own: idle, now: Self.at(90))
        #expect(trip.mapperID == "rae" && trip.mapperOverride == nil, "the rule now answers Rae: Sam's takeover lapses")
    }

    /// End the road trip here owes the end to every other member; a friend's end ends it here and owes it to whoever
    /// neither phone has told; each catch-up settles what was owed to that member.
    @Test func theEndReachesEveryoneAtTheirNextCatchUp() {
        let idle = RoadTripDeviceState(onCarPlay: false, isCharging: false)
        let ended = RoadTripCatchUpRules.ending(Self.trip(), now: Self.at(300))
        #expect(ended.endedAt == Self.at(300) && Set(ended.endToTell ?? []) == ["rae", "sam"] && !ended.isActive)
        let told = RoadTripCatchUpRules.applying(RoadTripReceivedCatchUp(state: idle, takeover: nil, endedAt: nil),
                                                 from: "rae", to: ended, own: idle, now: Self.at(310))
        #expect(told.endToTell == ["sam"] && told.endedAt == Self.at(300))
        let fromRae = RoadTripReceivedCatchUp(state: idle, takeover: nil, endedAt: Self.at(280))
        let relayed = RoadTripCatchUpRules.applying(fromRae, from: "rae", to: Self.trip(), own: idle, now: Self.at(320))
        #expect(relayed.endedAt == Self.at(280) && relayed.endToTell == ["sam"] && relayed.isValid)
    }

    /// Not this time takes a friend off every field; the mapper is decided again when it was them; the starter and
    /// this iPhone never leave the record.
    @Test func notThisTimeTakesAFriendOff() {
        var trip = Self.trip(mapper: "rae")
        trip.ledger = ["rae": [Self.at(10)], "me": [Self.at(10)]]
        trip.states = ["rae": RoadTripDeviceState(onCarPlay: true, isCharging: false)]
        trip.mapperOverride = RoadTripMapperOverride(memberID: "rae", at: Self.at(5), ruleAnswer: "me")
        let without = RoadTripCatchUpRules.removing("rae", from: trip)
        #expect(without.memberIDs == ["me", "sam"] && without.ledger?["rae"] == nil && without.states?["rae"] == nil)
        #expect(without.mapperID == "me" && without.mapperOverride == nil && without.isValid)
        #expect(RoadTripCatchUpRules.removing("me", from: trip) == trip)
        #expect(RoadTripCatchUpRules.removing("zoe", from: trip) == trip)
        var raeStarted = Self.trip()
        raeStarted = RoadTrip(id: raeStarted.id, name: nil, startedAt: Self.start, starterID: "rae", selfID: "me",
                              members: raeStarted.members, mapperID: "rae", mapperOverride: nil, lastCatchUp: Self.start,
                              endedAt: nil, leftAt: nil)
        #expect(RoadTripCatchUpRules.removing("rae", from: raeStarted) == raeStarted)
    }

    /// Who the note asks about: the first member nearby, once while they stay; not one just caught up with.
    @Test func theNoteAsksOnceAboutAMemberNearby() {
        let now = Self.at(60)
        #expect(RoadTripCatchUpAsk.next(members: ["rae", "sam"], nearby: ["sam", "zoe"], asked: [], caughtUpAt: [:], now: now) == "sam")
        #expect(RoadTripCatchUpAsk.next(members: ["rae", "sam"], nearby: ["sam"], asked: ["sam"], caughtUpAt: [:], now: now) == nil)
        #expect(RoadTripCatchUpAsk.next(members: ["rae"], nearby: ["rae"], asked: [], caughtUpAt: ["rae": Self.at(55)], now: now) == nil)
        #expect(RoadTripCatchUpAsk.next(members: ["rae"], nearby: ["rae"], asked: [], caughtUpAt: ["rae": Self.at(45)], now: now) == "rae")
        let state = RoadTripMeshState()
        state.refreshQuestion(members: ["rae"], nearby: ["rae"], isFree: true, now: now)
        #expect(state.question == "rae")
        state.clearQuestion()
        state.refreshQuestion(members: ["rae"], nearby: ["rae"], isFree: true, now: now)
        #expect(state.question == nil, "asked once while she stays")
        state.refreshQuestion(members: ["rae"], nearby: [], isFree: true, now: now)
        state.refreshQuestion(members: ["rae"], nearby: ["rae"], isFree: true, now: now)
        #expect(state.question == "rae", "she went away and came back")
        state.refreshQuestion(members: ["rae"], nearby: ["rae"], isFree: false, now: now)
        #expect(state.question == nil, "not with a hangout up or Home behind something")
    }
}
