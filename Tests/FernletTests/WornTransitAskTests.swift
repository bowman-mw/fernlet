import CoreGraphics
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Ferry and train paths' "ask and fix" (Docs/World-Transit-Paths-Exploration-2026-11-15.md §5, §9 C1 and C2): Home's
/// question maps each answer to the kind the fog keeper is told, a tap finds the worn way under it (a marker's tap
/// winning), "Paths near you" lists one way per kind, and the sheet's line reads "Train path · used 12 times · last
/// 3 days ago".
@MainActor
struct WornTransitAskTests {
    private static let here = GeoPoint(45.5205, -122.6255)
    private static let today: UInt16 = 2_000
    private static let english = Locale(identifier: "en_US")

    private static func trip(_ kind: WornWayKind, confirmed: Bool = false) -> WornTrip {
        WornTrip(kind: kind, confirmed: confirmed, day: today, start: Date(timeIntervalSince1970: 0),
                 end: Date(timeIntervalSince1970: 600), line: [here])
    }

    /// A drawn tally (level 1 for roads, rail and ferry: three trips), last used `daysAgo`.
    private static func drawn(daysAgo: UInt16 = 0) -> WornTally { WornTally(count: 3, lastDay: today - daysAgo) }

    // MARK: The question (C1)

    @Test func aRailGuessMapsTrainRoadAndNotSure() throws {
        let question = try #require(WornTransitQuestion(Self.trip(.rail)))
        #expect(question.guess == .rail)
        #expect(question.kind(for: .guess) == .rail)
        #expect(question.kind(for: .road) == .road)
        #expect(question.kind(for: .notSure) == nil)
        #expect(String(localized: WornTransitAskCopy.question(.rail)) == "Was that a train?")
        #expect(String(localized: WornTransitAskCopy.title(.guess, guess: .rail)) == "Train")
        #expect(String(localized: WornTransitAskCopy.title(.road, guess: .rail)) == "Bus or car")
        #expect(String(localized: WornTransitAskCopy.title(.notSure, guess: .rail)) == "Not sure")
    }

    @Test func aFerryGuessMapsFerryRoadAndNotSure() throws {
        let question = try #require(WornTransitQuestion(Self.trip(.ferry)))
        #expect(question.kind(for: .guess) == .ferry)
        #expect(question.kind(for: .road) == .road)
        #expect(question.kind(for: .notSure) == nil)
        #expect(String(localized: WornTransitAskCopy.question(.ferry)) == "Was that a ferry?")
        #expect(String(localized: WornTransitAskCopy.title(.guess, guess: .ferry)) == "Ferry")
        #expect(String(localized: WornTransitAskCopy.title(.road, guess: .ferry)) == "Car or bus")
    }

    @Test func noQuestionForARoadGuessAConfirmedTripOrNothing() {
        #expect(WornTransitQuestion(Self.trip(.road)) == nil)
        #expect(WornTransitQuestion(Self.trip(.rail, confirmed: true)) == nil)
        #expect(WornTransitQuestion(nil) == nil)
    }

    // MARK: Tap to way (C2)

    @Test func aTapNearARailCellFindsRail() {
        let cell = MercatorHexGrid.cell(containing: Self.here)
        let tallies = [WornWayKey(cell: cell, kind: .rail): Self.drawn(daysAgo: 400)]  // abandoned still counts
        let tap = Self.here.offset(east: 12, north: 6)
        #expect(WornWayLookup.way(at: tap, within: 40, tallies: tallies, today: Self.today) == WornWayKey(cell: cell, kind: .rail))
    }

    @Test func anEmptySpotOrAnUndrawnCountFindsNothing() {
        let cell = MercatorHexGrid.cell(containing: Self.here)
        let tallies = [WornWayKey(cell: cell, kind: .rail): Self.drawn(),
                       WornWayKey(cell: MercatorHexGrid.cell(containing: Self.here.offset(east: 0, north: 600)), kind: .road):
                           WornTally(count: 1, lastDay: Self.today)]
        #expect(WornWayLookup.way(at: Self.here.offset(east: 300, north: 0), within: 30, tallies: tallies, today: Self.today) == nil)
        // One trip never reached level 1: not drawn, not tappable.
        #expect(WornWayLookup.way(at: Self.here.offset(east: 0, north: 600), within: 30, tallies: tallies, today: Self.today) == nil)
        #expect(WornWayLookup.way(at: Self.here, within: 30, tallies: [:], today: Self.today) == nil)
    }

    @Test func theNearestWayWinsAndRailBeatsRoadOnTheSameCell() {
        let cell = MercatorHexGrid.cell(containing: Self.here)
        let tallies = [WornWayKey(cell: cell, kind: .road): Self.drawn(), WornWayKey(cell: cell, kind: .rail): Self.drawn()]
        #expect(WornWayLookup.way(at: Self.here, within: 30, tallies: tallies, today: Self.today)?.kind == .rail)
    }

    @Test func aMarkerOrSproutTapWins() {
        let marker = CGPoint(x: 100, y: 100), sprout = CGPoint(x: 200, y: 400)
        #expect(WornWayLookup.isOnMarker(CGPoint(x: 110, y: 112), markers: [marker], companion: nil))
        #expect(WornWayLookup.isOnMarker(CGPoint(x: 200, y: 340), markers: [], companion: sprout))
        #expect(!WornWayLookup.isOnMarker(CGPoint(x: 300, y: 250), markers: [marker], companion: sprout))
    }

    @Test func theFingerReachFollowsTheZoomWithinItsRange() {
        #expect(WornWayLookup.toleranceMetres(pointsPerMetre: 2) == 18)
        #expect(WornWayLookup.toleranceMetres(pointsPerMetre: 0.5) == 44)
        #expect(WornWayLookup.toleranceMetres(pointsPerMetre: 0.01) == 150)
        #expect(WornWayLookup.toleranceMetres(pointsPerMetre: 0) == 18)
    }

    @Test func pathsNearYouListsOneWayPerKindNearestFirst() {
        let near = MercatorHexGrid.cell(containing: Self.here.offset(east: 40, north: 0))
        let farther = MercatorHexGrid.cell(containing: Self.here.offset(east: 120, north: 0))
        let tooFar = MercatorHexGrid.cell(containing: Self.here.offset(east: 900, north: 0))
        let tallies = [WornWayKey(cell: near, kind: .road): Self.drawn(), WornWayKey(cell: farther, kind: .road): Self.drawn(),
                       WornWayKey(cell: farther, kind: .rail): Self.drawn(), WornWayKey(cell: tooFar, kind: .ferry): Self.drawn()]
        let ways = WornWayLookup.nearby(around: Self.here, tallies: tallies, today: Self.today)
        #expect(ways.map(\.key) == [WornWayKey(cell: near, kind: .road), WornWayKey(cell: farther, kind: .rail)])
    }

    // MARK: The sheet's line

    @Test func theHeaderReadsKindUsesAndLastDay() {
        let line = WornWayCopy.header(kind: .rail, tally: WornTally(count: 12, lastDay: Self.today - 3), today: Self.today,
                                      locale: Self.english)
        #expect(line == "Train path · used 12 times · last 3 days ago")
        let ferry = WornWayCopy.header(kind: .ferry, tally: WornTally(count: 1, lastDay: Self.today), today: Self.today,
                                       locale: Self.english)
        #expect(ferry == "Ferry path · used 1 time · last today")
        let road = WornWayCopy.header(kind: .road, tally: WornTally(count: 40, lastDay: Self.today - 1), today: Self.today,
                                      locale: Self.english)
        #expect(road == "Frequent road · used 40 times · last yesterday")
    }

    @Test func longAgoReadsInWeeksMonthsAndYears() {
        #expect(WornWayCopy.relative(daysAgo: 21, locale: Self.english) == "3 weeks ago")
        #expect(WornWayCopy.relative(daysAgo: 95, locale: Self.english) == "3 months ago")
        #expect(WornWayCopy.relative(daysAgo: 800, locale: Self.english) == "2 years ago")
    }

    @Test func eachWayOffersTheTwoKindsItIsNot() {
        #expect(WornWayCopy.otherKinds(than: .rail) == [.road, .ferry])
        #expect(WornWayCopy.otherKinds(than: .road) == [.rail, .ferry])
        #expect(String(localized: WornWayCopy.thisWas(.road)) == "This was a road")
    }
}
