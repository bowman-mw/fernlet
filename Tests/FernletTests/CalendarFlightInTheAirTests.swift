import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// A calendar flight's times stand in for GPS that can't hear the sky (owner 2026-11-02): Home shows the plane between
/// departure and arrival when the person was last known to be at its departure airport, since a calendar also holds
/// the flights of people they're picking up. Any reading since it left overrules it. The sample flight is made up.
@MainActor
struct CalendarFlightInTheAirTests {
    static let leaves = Date(timeIntervalSince1970: 1_793_000_000)
    static let arrives = leaves.addingTimeInterval(4 * 3_600)
    static let during = leaves.addingTimeInterval(3_600)
    /// The last reading, half an hour before it left.
    static let atTheGate = leaves.addingTimeInterval(-1_800)

    private func flight(sources: PassportFlight.Sources = .calendar, arrives: Bool = true, timesUnsure: Bool = false) throws -> PassportFlight {
        try #require(PassportFlight(from: "PDX", to: "HNL", departure: Self.leaves, arrival: arrives ? Self.arrives : nil, sources: sources,
                                    timesUnsure: timesUnsure, eventHash: sources.contains(.calendar) ? String(repeating: "a", count: 64) : nil))
    }

    private func book(upcoming: [PassportFlight] = [], flown: [PassportFlight] = []) -> PassportBook {
        var book = PassportBook()
        book.setUpcomingFlights(upcoming)
        book.addFlights(flown)
        return book
    }

    @Test func aCalendarFlightSaysInTheAirOnlyBetweenItsTimes() throws {
        let book = book(upcoming: [try flight()])
        #expect(book.calendarFlightInTheAir(now: Self.leaves.addingTimeInterval(-60), lastReading: Self.atTheGate, lastAirport: "PDX") == nil)
        #expect(book.calendarFlightInTheAir(now: Self.during, lastReading: Self.atTheGate, lastAirport: "PDX")?.to == "HNL")
        #expect(book.calendarFlightInTheAir(now: Self.arrives, lastReading: Self.atTheGate, lastAirport: "PDX") == nil, "it has landed by its times")
    }

    @Test func someoneElsesFlightSaysNothing() throws {
        let book = book(upcoming: [try flight()])
        #expect(book.calendarFlightInTheAir(now: Self.during, lastReading: Self.atTheGate, lastAirport: nil) == nil,
                "last seen away from any airport: a flight being picked up")
        #expect(book.calendarFlightInTheAir(now: Self.during, lastReading: Self.atTheGate, lastAirport: "SEA") == nil,
                "last seen at another airport")
    }

    @Test func aReadingSinceItLeftOverrulesIt() throws {
        let delayed = Self.leaves.addingTimeInterval(600)
        let book = book(upcoming: [try flight()])
        #expect(book.calendarFlightInTheAir(now: Self.during, lastReading: delayed, lastAirport: "PDX") == nil, "still on the ground: back to the map")
    }

    @Test func aFlightAlreadyMovedToTheFlownListStillCounts() throws {
        let book = book(flown: [try flight()])
        #expect(book.calendarFlightInTheAir(now: Self.during, lastReading: Self.atTheGate, lastAirport: "PDX") != nil)
    }

    @Test func onlyACalendarFlightWithSureTimesCounts() throws {
        let imported = book(flown: [try flight(sources: .flighty)])
        #expect(imported.calendarFlightInTheAir(now: Self.during, lastReading: Self.atTheGate, lastAirport: "PDX") == nil)
        let unsure = book(upcoming: [try flight(timesUnsure: true)])
        #expect(unsure.calendarFlightInTheAir(now: Self.during, lastReading: Self.atTheGate, lastAirport: "PDX") == nil)
        let open = book(upcoming: [try flight(arrives: false)])
        #expect(open.calendarFlightInTheAir(now: Self.during, lastReading: Self.atTheGate, lastAirport: "PDX") == nil)
    }

    // MARK: The layover plate

    @Test func theLayoverPlateWaitsThirtyMinutesOrForANextFlight() {
        #expect(!WorldLayoverPlate.shows(since: 0, hasNextFlight: false), "a landing is no layover yet")
        #expect(!WorldLayoverPlate.shows(since: 29 * 60, hasNextFlight: false))
        #expect(WorldLayoverPlate.shows(since: 30 * 60, hasNextFlight: false))
        #expect(WorldLayoverPlate.shows(since: 0, hasNextFlight: true), "another flight on the calendar shows it at once")
    }

    @Test func aNextFlightLeavesThisAirportWithinADay() throws {
        let book = book(upcoming: [try flight()])
        let dayBefore = Self.leaves.addingTimeInterval(-20 * 3_600)
        #expect(book.calendarFlightLeaves("PDX", now: dayBefore))
        #expect(!book.calendarFlightLeaves("SEA", now: dayBefore), "from another airport")
        #expect(!book.calendarFlightLeaves("PDX", now: Self.leaves.addingTimeInterval(-3 * 86_400)), "a later trip's")
        #expect(!book.calendarFlightLeaves("PDX", now: Self.leaves.addingTimeInterval(60)), "already gone")
    }

    @Test func theKeeperKeepsTheMinuteOfTheNewestReadingAndItsAirportsCode() {
        let at = GeoPoint(45.5887, -122.5975)
        let pdx = WorldAirport(token: "TOKEN", iata: "PDX", ident: "KPDX", point: at, countryCode: "US", size: .large,
                               timeZoneIdentifier: "America/Los_Angeles", englishName: "PDX", spanishName: nil, englishCity: "PDX",
                               spanishCity: nil, grounds: .circle(radiusMetres: 3_000))
        let keeper = WorldFlightKeeper(grounds: { OneAirport(airport: pdx) }, iataCode: { $0 == "TOKEN" ? "PDX" : nil })
        #expect(keeper.lastReadingMinute == nil && keeper.currentAirportCode == nil)
        let when = Date(timeIntervalSince1970: 1_793_000_000 + 30)
        _ = keeper.admits(WorldFix(point: at, accuracy: 10, at: when, isPrecise: true))
        #expect(keeper.lastReadingMinute == Date(timeIntervalSince1970: (when.timeIntervalSince1970 / 60).rounded(.down) * 60))
        #expect(keeper.currentAirportCode == "PDX")
    }
}

/// One airport whose grounds hold every point it's asked about.
private nonisolated struct OneAirport: AirportGroundsLookup {
    let airport: WorldAirport

    func airports(containing point: GeoPoint) -> [WorldAirport] { [airport] }
}
