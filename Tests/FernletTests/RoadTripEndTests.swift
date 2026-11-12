@testable import FernletSocial
import Foundation
import Testing
import UIKit
import WorldMapStore
@testable import Fernlet

/// Road trip mode's end (World-RoadTrip-Spec PR 4, `rt-end`, owner-approved 2026-11-10): "The trip ends when someone
/// taps End the road trip, when everyone has left, or by itself after 7 days without a catch-up. A summary card shows
/// once on Home … kept on each phone like a walk's line: sealed, never synced, deleted with map history." The seven
/// quiet days to the second and a catch-up resetting them; everyone having left, the leave carried on the wire; the
/// summary's numbers from a scripted trip (own road, received road, photos and a long gap); and the card shown once,
/// never in a decoy, gone with map history.
@Suite(.serialized) @MainActor
struct RoadTripEndTests {
    let store = makeTestStore()
    private static let here = GeoPoint(45.5205, -122.6255)
    /// Noon, local time, on a day well after the real clock (so the map's own load never ends these trips).
    nonisolated static let start: Date = Calendar.current.date(from: DateComponents(year: 2033, month: 5, day: 17, hour: 12))
        ?? Date(timeIntervalSince1970: 2_000_000_000)
    private static let week = RoadTripEndRules.quietSeconds

    /// `minutes` after the start.
    static func at(_ minutes: Double) -> Date { start.addingTimeInterval(minutes * 60) }

    /// A trip this store is on, started at `start` by `starter`, `mapper` mapping, with `others`.
    static func trip(start: Date = start, others: [String] = ["rae", "sam"], starter: String = "me",
                     mapper: String = "me", name: String? = nil) -> RoadTrip {
        let members = [RoadTripMember(id: "me", firstName: "Mike")] + others.map { RoadTripMember(id: $0, firstName: $0.capitalized) }
        return RoadTrip(id: UUID(), name: name, startedAt: start, starterID: starter, selfID: "me", members: members,
                        mapperID: mapper, mapperOverride: nil, lastCatchUp: start, endedAt: nil, leftAt: nil)
    }

    /// A precise reading `east` metres east of ``here`` at `date`.
    static func fix(east: Double, at date: Date) -> WorldFix {
        WorldFix(point: here.offset(east: east, north: 0), accuracy: 8, at: date, isPrecise: true)
    }

    // MARK: By itself, after seven days

    /// A trip ends by itself exactly seven days after its last catch-up, to the second, and its end is the mark, not
    /// the moment the check ran; nobody is owed it, and the quiet days take this iPhone off the trip too.
    @Test func sevenQuietDaysEndTheTripAtTheMark() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip()
        #expect(keeper.start(trip))
        let mark = Self.start.addingTimeInterval(Self.week)
        #expect(RoadTripEndRules.quietEnd(of: trip) == mark && Self.week == 604_800)
        #expect(!keeper.endIfQuiet(now: mark.addingTimeInterval(-1)), "one second short")
        #expect(keeper.active?.id == trip.id)
        store.refreshRoadTripEnd(now: mark.addingTimeInterval(3 * 3_600))
        let ended = try #require(keeper.book.trips.last)
        #expect(keeper.active == nil && ended.endedAt == mark && ended.leftAt == mark, "the mark, not the check's moment")
        #expect(ended.endToTell == nil, "each phone counts its own seven days")
        #expect(keeper.hasLeft(trip.id, sharedWith: "rae") && !keeper.hasLeft(trip.id, sharedWith: "stranger"),
                "a member met later hears this iPhone left")
        #expect(RoadTripEndRules.endingIfQuiet(ended, now: mark.addingTimeInterval(Self.week)) == nil, "it ends once")
    }

    /// A catch-up moves the seven days on from itself.
    @Test func aCatchUpResetsTheSevenDays() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip()
        #expect(keeper.start(trip))
        let caughtUp = Self.at(3 * 24 * 60)
        store.receiveRoadTripCatchUp(RoadTripMeshTests.catchUp(for: trip.id, points: []), from: "rae", now: caughtUp)
        #expect(keeper.active?.lastCatchUp == caughtUp)
        store.refreshRoadTripEnd(now: Self.start.addingTimeInterval(Self.week))
        #expect(keeper.active?.id == trip.id, "the old mark has passed, but a catch-up came since")
        #expect(!keeper.endIfQuiet(now: caughtUp.addingTimeInterval(Self.week - 1)))
        #expect(keeper.endIfQuiet(now: caughtUp.addingTimeInterval(Self.week)))
        #expect(keeper.book.trips.last?.endedAt == caughtUp.addingTimeInterval(Self.week))
    }

    /// The map's own load (each foreground, the locked launch) ends a trip whose seven days have passed by the real
    /// clock, before anything else reads it.
    @Test func theMapsLoadEndsAQuietTrip() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let started = Date().addingTimeInterval(-8 * 24 * 3_600)
        let trip = Self.trip(start: started)
        #expect(keeper.start(trip))
        store.worldFog.load()
        #expect(keeper.active == nil)
        #expect(keeper.book.trips.last?.endedAt == started.addingTimeInterval(Self.week))
        #expect(!store.worldLocation.isRoadTripPassenger)
    }

    // MARK: Everyone has left

    /// A member who left says so; the one who mapped hands the road to the rule's next answer among those still on it;
    /// the chip counts only them; once every other member has left, the trip ends here, owed to no one.
    @Test func everyoneLeavingEndsTheTrip() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip(starter: "rae", mapper: "rae")
        #expect(keeper.start(trip))
        #expect(keeper.isPassenger)
        store.receiveRoadTripAnswer(RoadTripJoinPayload(tripID: trip.id, joins: false, left: true), from: "RAE", now: Self.at(30))
        let afterRae = try #require(keeper.active)
        #expect(afterRae.othersLeft == ["rae"] && afterRae.memberIDs == ["me", "rae", "sam"], "kept on the record, as gone")
        #expect(afterRae.onTripIDs == ["me", "sam"] && afterRae.othersOnTrip.map(\.id) == ["sam"])
        #expect(afterRae.mapperID == "me" && keeper.isMapping, "the starter left: the first still on maps")
        #expect(!store.worldLocation.isRoadTripPassenger, "the passenger gate follows")
        store.receiveRoadTripAnswer(RoadTripJoinPayload(tripID: trip.id, joins: false, left: true), from: "rae", now: Self.at(31))
        #expect(keeper.active?.othersLeft == ["rae"], "a leave heard twice counts once")
        store.receiveRoadTripAnswer(RoadTripJoinPayload(tripID: trip.id, joins: false, left: true), from: "sam", now: Self.at(45))
        let ended = try #require(keeper.book.trips.last)
        #expect(keeper.active == nil && ended.endedAt == Self.at(45) && ended.leftAt == nil)
        #expect(ended.endToTell == nil, "nobody is left to tell")
    }

    /// The pure rule: this iPhone and strangers are never marked, an End is owed only to those still on, and a member
    /// taken off the record leaves its list of leavers too.
    @Test func theLeaveRuleKeepsItsBounds() {
        let trip = Self.trip()
        #expect(RoadTripEndRules.markingLeft("me", in: trip, now: Self.at(1)) == trip)
        #expect(RoadTripEndRules.markingLeft("stranger", in: trip, now: Self.at(1)) == trip)
        let raeLeft = RoadTripEndRules.markingLeft("rae", in: trip, now: Self.at(1))
        #expect(raeLeft.isActive && raeLeft.isValid && raeLeft.mapperID == "me", "this iPhone mapped and still does")
        #expect(RoadTripCatchUpRules.ending(raeLeft, now: Self.at(2)).endToTell == ["sam"])
        #expect(RoadTripCatchUpRules.removing("rae", from: raeLeft).othersLeft == [])
        var invalid = raeLeft
        invalid.othersLeft = ["me"]
        #expect(!invalid.isValid, "this iPhone never leaves its own list")
    }

    /// The leave rides the existing Not this time as one optional flag: it round-trips under its frozen name, an
    /// answer without it reads as a plain Not this time, and a Join never says left.
    @Test func theLeaveIsCarriedOnTheJoinAnswer() throws {
        let left = RoadTripPayload.join(RoadTripJoinPayload(tripID: UUID(), joins: false, left: true))
        let body = try JSONEncoder().encode(left)
        let json = try #require(String(data: body, encoding: .utf8))
        #expect(json.contains("\"left\":true"), "frozen field name: \(json)")
        let decoded = try #require(RoadTripPayload.decoded(from: body))
        #expect(decoded == left && decoded.join?.saysLeft == true)
        let plain = try JSONEncoder().encode(RoadTripPayload.join(RoadTripJoinPayload(tripID: UUID(), joins: false)))
        let plainJSON = try #require(String(data: plain, encoding: .utf8))
        #expect(!plainJSON.contains("left"), "an answer without a leave writes what PR 2 wrote")
        #expect(RoadTripPayload.decoded(from: plain)?.join?.saysLeft == false)
        #expect(!RoadTripJoinPayload(tripID: UUID(), joins: true, left: true).saysLeft)
    }

    // MARK: The summary

    /// A scripted trip: this iPhone's own drive on the first day, a long gap overnight, a friend's road received on the
    /// third, two own photos and one of Rae's. The numbers are worked out once at the end: three calendar days, the
    /// whole road this iPhone holds, the tiles first uncovered during the trip (not the walk before it), the photos.
    @Test func theSummaryAddsUpTheTrip() throws {
        let fog = store.worldFog
        fog.load()
        fog.handle(Self.fix(east: -3_000, at: Self.at(-60)))
        let before = try #require(fog.uncoveredCellCount)
        let keeper = fog.roadTrip
        let trip = Self.trip(others: ["rae"])
        #expect(keeper.start(trip))
        #expect(keeper.active?.cellsAtStart == before, "stamped at the start")
        // R2: forty readings.
        for step in 0..<40 { fog.handle(Self.fix(east: Double(step) * 30, at: Self.at(10).addingTimeInterval(Double(step) * 2)), thinLine: true) }
        #expect(store.takeRoadTripPhoto(try RoadTripPhotoTests.jpeg(), fix: nil, now: Self.at(12)) == .kept)
        #expect(store.takeRoadTripPhoto(try RoadTripPhotoTests.jpeg(.systemPink), fix: nil, now: Self.at(14)) == .kept)
        let dayThree = Self.at(2 * 24 * 60 - 180)
        let received = (0..<20).map {
            RoadTripPoint(point: Self.here.offset(east: 6_000 + Double($0) * 30, north: 0), at: dayThree.addingTimeInterval(Double($0) * 2))
        }
        store.receiveRoadTripCatchUp(RoadTripMeshTests.catchUp(for: trip.id, points: received), from: "rae", now: dayThree.addingTimeInterval(600))
        #expect(store.receiveRoadTripPhoto(try RoadTripPhotoTests.received(trip, at: Self.at(20)), from: "rae", now: dayThree.addingTimeInterval(700)))
        store.roadTripMesh.settleNow()
        #expect(keeper.pointCount == 60, "own road and received road, one line")
        #expect(store.endRoadTrip(now: dayThree.addingTimeInterval(3_600)))
        store.refreshRoadTripEnd(now: dayThree.addingTimeInterval(3_660))
        let ended = try #require(keeper.book.trips.last)
        let summary = try #require(ended.summary)
        let line = try #require(keeper.linePoints(of: ended, after: .distantPast, through: .distantFuture))
        #expect(summary.days == 3, "day one to day three")
        #expect(abs(summary.metres - RoadTripLine.length(of: line, from: nil)) < 0.5 && summary.metres > 6_500)
        #expect(summary.newTiles == (fog.uncoveredCellCount ?? 0) - before && (summary.newTiles ?? 0) > 0)
        #expect(summary.photos == 3)
        #expect(summary.towns.map { $0 >= 1 } ?? true, "Portland, when the atlas is on this iPhone")
        // Worked out once: a later look leaves them as they were.
        fog.handle(Self.fix(east: 20_000, at: dayThree.addingTimeInterval(4_000)))
        store.refreshRoadTripEnd(now: dayThree.addingTimeInterval(5_000))
        #expect(keeper.book.trips.last?.summary == summary)
    }

    /// The pure numbers: days are calendar days inclusive; points after the end are left out; the towns are counted
    /// once each along the road; the tiles are left out when the start wasn't known, the towns without an atlas.
    @Test func theNumbersByTheRule() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let morning = try #require(calendar.date(from: DateComponents(year: 2033, month: 5, day: 17, hour: 8)))
        #expect(RoadTripEndRules.days(from: morning, to: morning.addingTimeInterval(3_600), calendar: calendar) == 1)
        #expect(RoadTripEndRules.days(from: morning, to: morning.addingTimeInterval(17 * 3_600), calendar: calendar) == 2, "past midnight")
        var trip = Self.trip(start: morning)
        trip.endedAt = morning.addingTimeInterval(2 * 24 * 3_600)
        trip.cellsAtStart = 100
        let line = (0..<101).map { RoadTripPoint(point: Self.here.offset(east: Double($0) * 100, north: 0), at: morning.addingTimeInterval(Double($0) * 60)) }
        let past = RoadTripPoint(point: Self.here.offset(east: 50_000, north: 0), at: morning.addingTimeInterval(3 * 24 * 3_600))
        let towns: (GeoPoint) -> String? = { point in
            let east = point.distance(to: Self.here)
            return east < 2_000 ? "A" : (east < 6_000 ? nil : "B")
        }
        let summary = try #require(RoadTripEndRules.summary(of: trip, line: line + [past], uncovered: 1_380, photos: 23,
                                                            towns: towns, calendar: calendar))
        #expect(summary == RoadTripSummary(days: 3, metres: summary.metres, newTiles: 1_280, towns: 2, photos: 23))
        #expect(abs(summary.metres - 10_000) < 5, "the point after the end is left out")
        var unknown = trip
        unknown.cellsAtStart = nil
        let bare = try #require(RoadTripEndRules.summary(of: unknown, line: line, uncovered: 1_380, photos: 0, towns: nil, calendar: calendar))
        #expect(bare.newTiles == nil && bare.towns == nil)
        #expect(RoadTripEndRules.summary(of: Self.trip(), line: line, uncovered: 1, photos: 0, towns: nil) == nil, "still on")
    }

    /// The card's VoiceOver line is the approved one-line form, leaving out what isn't known, with singulars.
    @Test func theCardReadsTheApprovedLine() {
        let full = RoadTripSummary(days: 3, metres: 412_000, newTiles: 1_280, towns: 4, photos: 23)
        let distance = RoadTripCopy.distance(412_000)
        #expect(RoadTripCopy.summarySpoken(title: "Road trip to the coast", full)
                == "Road trip to the coast · 3 days · \(distance) · 1,280 new tiles · 4 towns · 23 photos")
        let sparse = RoadTripSummary(days: 1, metres: 412_000, newTiles: nil, towns: nil, photos: 1)
        #expect(RoadTripCopy.summarySpoken(title: "Road trip", sparse) == "Road trip · 1 day · \(distance) · 1 photo")
        let ones = RoadTripSummary(days: 1, metres: 0, newTiles: 1, towns: 1, photos: 0)
        #expect(RoadTripCopy.summarySpoken(title: "T", ones).contains("1 new tile · 1 town · 0 photos"))
        #expect(!RoadTripSummary(days: 0, metres: 1, newTiles: nil, towns: nil, photos: 0).isValid)
        #expect(!RoadTripSummary(days: 1, metres: -.infinity, newTiles: nil, towns: nil, photos: 0).isValid)
    }

    // MARK: The card

    /// The card shows once: it waits for the numbers, shows the newest trip over, never in a decoy (which marks
    /// nothing), goes when Done is written into the sealed record, and goes with Delete map history.
    @Test func theCardShowsOnceAndNeverInADecoy() throws {
        let keeper = store.worldFog.roadTrip
        keeper.load()
        let trip = Self.trip(name: "To the coast")
        #expect(keeper.start(trip))
        #expect(keeper.appendLine(RoadTripMeshTests.road(30)) > 0)
        #expect(store.roadTripSummaryCard == nil, "nothing while it is on")
        #expect(store.leaveRoadTrip(now: Self.at(90)))
        #expect(store.roadTripSummaryCard == nil, "nothing before the numbers")
        store.refreshRoadTripEnd(now: Self.at(91))
        let card = try #require(store.roadTripSummaryCard)
        #expect(card.id == trip.id && card.title == "To the coast" && card.summary.days == 1, "a trip this iPhone left is over for it too")
        #expect(card.spoken.hasPrefix("To the coast · 1 day · "))
        store.duressSessionActive = true
        #expect(store.roadTripSummaryCard == nil && !store.markRoadTripSummaryShown(card.id))
        store.refreshRoadTripEnd(now: Self.at(92))
        store.duressSessionActive = false
        #expect(store.roadTripSummaryCard?.id == card.id, "the decoy marked nothing")
        #expect(store.markRoadTripSummaryShown(card.id))
        #expect(store.roadTripSummaryCard == nil, "shown once")
        let reread = RoadTripKeeper(vault: store.worldMapVault)
        reread.load()
        #expect(reread.book.trips.last?.summaryShown == true && reread.book.trips.last?.summary == card.summary, "sealed")
        #expect(store.deleteWorldMapHistory())
        #expect(store.worldFog.roadTrip.book.trips.isEmpty && store.roadTripSummaryCard == nil)
    }
}
