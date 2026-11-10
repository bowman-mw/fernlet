import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// The passport's Road trips page (World-RoadTrip-Spec PR 4, `rt-end`, the owner's choice "passport": "The trip is also
/// added to the passport's trips, next to flights and country trips"), on the Flights page's pattern: one page, a log
/// per year, each trip one plain entry (its name, its days, its road), never a stamp; the page next to Flights and its
/// index row; and no page in a decoy, the demo, or before a trip is over.
@Suite(.serialized) @MainActor
struct PassportRoadTripsTests {
    let store = makeTestStore()

    /// A UTC calendar, so the days and years don't move with the machine's zone.
    static var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }

    /// Noon UTC on `day` `month` `year`.
    static func day(_ year: Int, _ month: Int, _ day: Int) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    /// An ended trip from `start`, `days` long, with `km` of road in its numbers (none when `summarised` is false).
    static func ended(_ start: Date, days: Double = 2, km: Double = 412, name: String? = "To the coast",
                      summarised: Bool = true) -> RoadTrip {
        var trip = RoadTripEndTests.trip(start: start, name: name)
        trip.endedAt = start.addingTimeInterval(days * 24 * 3_600)
        if summarised { trip.summary = RoadTripSummary(days: Int(days) + 1, metres: km * 1_000, newTiles: 10, towns: 1, photos: 2) }
        return trip
    }

    // MARK: The model

    /// Only trips no longer on, with their numbers, are entries; they group by the year they started, newest year
    /// first, earliest trip first in each; the totals count every trip and its road.
    @Test func entriesGroupByTheYearTheyStarted() throws {
        let newYear = Self.ended(Self.day(2025, 12, 30), days: 3, km: 600, name: "New Year")
        let summer = Self.ended(Self.day(2026, 7, 4), km: 412)
        let spring = Self.ended(Self.day(2026, 3, 1), km: 88, name: nil)
        let onNow = RoadTripEndTests.trip(start: Self.day(2026, 9, 1))
        let owed = Self.ended(Self.day(2026, 8, 1), summarised: false)
        let model = PassportRoadTripsModel(trips: [summer, onNow, newYear, owed, spring], calendar: Self.utc)
        #expect(model.trips.map(\.id) == [newYear.id, spring.id, summer.id], "on now and owed its numbers are left out")
        #expect(model.years.map(\.year) == [2026, 2025] && model.log(ofYear: 2025)?.trips.map(\.id) == [newYear.id])
        #expect(model.log(ofYear: 2026)?.trips.map(\.id) == [spring.id, summer.id] && model.position(ofYear: 2025) == 1)
        #expect(abs(model.totalMetres - 1_100_000) < 1 && abs((model.log(ofYear: 2026)?.metres ?? 0) - 500_000) < 1)
        #expect(!model.listsYears && !model.isEmpty)
        let entry = try #require(model.trips.first)
        #expect(entry.name == "New Year" && entry.start == newYear.startedAt && entry.end == newYear.endedAt)
        #expect(model.trips[1].name == RoadTripCopy.name(of: spring), "a trip given no name: Road trip and its day")
        #expect(PassportRoadTripsModel(trips: [onNow, owed]).isEmpty)
    }

    /// A trip this iPhone left is over for it: its entry runs to the leave; seven trips list the years.
    @Test func aLeftTripCountsAndSevenListTheYears() throws {
        var left = RoadTripEndTests.trip(start: Self.day(2026, 5, 1))
        left.leftAt = Self.day(2026, 5, 2)
        left.summary = RoadTripSummary(days: 2, metres: 5_000, newTiles: nil, towns: nil, photos: 0)
        let six = (1...6).map { Self.ended(Self.day(2024, $0, 10)) }
        let seven = PassportRoadTripsModel(trips: six + [left], calendar: Self.utc)
        #expect(seven.trips.last?.end == left.leftAt && seven.listsYears)
        #expect(!PassportRoadTripsModel(trips: six, calendar: Self.utc).listsYears, "six still fit the page")
    }

    /// The rows' words: days as the Flights page writes them (the year left out in a year's log), and what VoiceOver
    /// reads for a row and a year.
    @Test func theRowsSayTheNameTheDaysAndTheRoad() throws {
        let trip = PassportRoadTrip(id: UUID(), name: "To the coast", start: Self.day(2026, 11, 10), end: Self.day(2026, 11, 12),
                                    metres: 412_000)
        #expect(PassportRoadTripsText.days(of: trip, inYear: false, calendar: Self.utc, language: .english) == "10–12 NOV 2026")
        #expect(PassportRoadTripsText.days(of: trip, inYear: true, calendar: Self.utc, language: .english) == "10–12 NOV")
        let distance = RoadTripCopy.distance(412_000)
        let spoken = PassportRoadTripsText.spoken(trip, calendar: Self.utc)
        #expect(spoken.hasPrefix("To the coast, ") && spoken.hasSuffix(", " + distance) && spoken.contains(" to "))
        let oneDay = PassportRoadTrip(id: UUID(), name: "Day out", start: Self.day(2026, 11, 10), end: Self.day(2026, 11, 10),
                                      metres: 0)
        #expect(!PassportRoadTripsText.spoken(oneDay, calendar: Self.utc).contains(" to "), "one day said once")
        let log = PassportRoadTripYearLog(year: 2026, trips: [trip, oneDay])
        #expect(PassportRoadTripsText.yearSpoken(log) == "2026, 2 road trips, " + distance)
        #expect(RoadTripCopy.passportTotals(1, metres: 412_000) == "1 road trip · " + distance)
    }

    // MARK: The book and its index

    /// The Road trips page sits right after Flights (after the stamps without it) and before the index; a book
    /// without it keeps its numbers.
    @Test func theRoadTripsPageSitsNextToFlights() {
        let both = PassportBookModel(entries: [], showsFlights: true, showsRoadTrips: true)
        #expect(both.pageCount == 6 && both.flightsPage == 4 && both.roadTripsPage == 5 && both.indexPage == 6)
        #expect(both.page(at: 4) == .flights && both.page(at: 5) == .roadTrips && both.page(at: 6) == .index)
        let alone = PassportBookModel(entries: [], showsRoadTrips: true)
        #expect(alone.pageCount == 5 && alone.flightsPage == nil && alone.roadTripsPage == 4 && alone.page(at: 4) == .roadTrips)
        let none = PassportBookModel(entries: [], showsFlights: true)
        #expect(none.roadTripsPage == nil && none.pageCount == 5)
        #expect(String(localized: PassportBookCopy.name(of: .roadTrips)) == "Road trips")
    }

    /// The index's Road trips row counts every trip and turns to its page; with no page there is no row.
    @Test func theIndexRowCountsAndTurnsToThePage() throws {
        let roadTrips = PassportRoadTripsModel(trips: [Self.ended(Self.day(2026, 7, 4)), Self.ended(Self.day(2026, 8, 4))],
                                               calendar: Self.utc)
        let book = PassportBookModel(entries: [], showsFlights: true, showsRoadTrips: true, calendar: Self.utc)
        let index = PassportIndexModel(book: book, table: .empty, language: .english, roadTrips: roadTrips) { _ in "" }
        let row = try #require(index.roadTrips)
        #expect(row.count == 2 && row.page == 5)
        let without = PassportIndexModel(book: PassportBookModel(entries: [], showsFlights: true), table: .empty,
                                         language: .english, roadTrips: roadTrips) { _ in "" }
        #expect(without.roadTrips == nil, "no page, no row")
        #expect(PassportIndexModel(book: book, table: .empty, language: .english, roadTrips: nil) { _ in "" }.roadTrips == nil)
    }

    // MARK: The screen's page

    /// The book shows the page from the person's trips over, and none in a decoy, in the demo, or before any is over.
    @Test func noPageInADecoyTheDemoOrWithNone() throws {
        let presenter = WorldPassportPresenter()
        let screen = PassportBookScreen(presenter: presenter, store: store)
        let keeper = store.worldFog.roadTrip
        keeper.load()
        #expect(screen.roadTripsModel == nil, "no trips")
        let trip = RoadTripEndTests.trip(start: Self.day(2033, 5, 17))
        #expect(keeper.start(trip))
        #expect(screen.roadTripsModel == nil, "on now")
        #expect(keeper.end(now: Self.day(2033, 5, 18)))
        #expect(screen.roadTripsModel == nil, "before its numbers")
        store.refreshRoadTripEnd(now: Self.day(2033, 5, 18))
        #expect(screen.roadTripsModel?.trips.map(\.id) == [trip.id])
        store.duressSessionActive = true
        #expect(screen.roadTripsModel == nil, "a decoy")
        store.duressSessionActive = false
        presenter.demo = PassportBookDemo(entries: [])
        #expect(screen.roadTripsModel == nil, "the demo")
        presenter.demo = nil
        #expect(screen.roadTripsModel != nil)
    }
}
