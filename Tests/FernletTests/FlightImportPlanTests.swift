import FernletDomainModel
import Foundation
import Testing
import WorldMapStore
@testable import Fernlet

/// Planning a file's flights against the passport, and the Flights pages built from them (World-Airports-Spec §8,
/// §9.4, §9.5). Every flight is made up (Cedar Air out of Portland); none is anyone's real history.
@MainActor
struct FlightImportPlanTests {
    static let airports = FlightTestAirports()

    static func record(_ from: String, _ to: String, _ day: (Int, Int, Int), departure: String?, arrival: String? = nil,
                       unsure: Bool = false) -> FlightRecord? {
        guard let flightDay = FlightDay(year: day.0, month: day.1, day: day.2) else { return nil }
        return FlightRecord(from: from, to: to, day: flightDay, departure: departure.map(flightUTC),
                            arrival: arrival.map(flightUTC), timesUnsure: unsure)
    }

    static func flight(_ from: String, _ to: String, _ departure: String, _ arrival: String? = nil,
                       sources: PassportFlight.Sources = .fernlet) -> PassportFlight? {
        PassportFlight(from: from, to: to, departure: flightUTC(departure), arrival: arrival.map(flightUTC), sources: sources)
    }

    /// The plan counts what the passport already holds and Undo takes the file's source off only what it added.
    @Test func plansAgainstThePassportAndUndoesOnlyItsOwn() throws {
        var book = PassportBook()
        let seen = try #require(Self.flight("PDX", "HNL", "2026-03-01T18:00:00Z", "2026-03-02T00:00:00Z"))
        let earlier = try #require(Self.flight("PDX", "SEA", "2026-04-01T15:00:00Z", sources: .flighty))
        book.addFlights([seen, earlier])
        let records = [
            Self.record("PDX", "HNL", (2026, 3, 1), departure: "2026-03-01T19:00:00Z"),
            Self.record("PDX", "SEA", (2026, 4, 1), departure: "2026-04-01T15:30:00Z"),
            Self.record("SEA", "LHR", (2026, 5, 1), departure: "2026-05-01T20:00:00Z"),
        ].compactMap { $0 }
        let plan = FlightImportPlan(records: records, source: .flighty, airports: Self.airports, book: book)
        #expect(plan.flights.count == 3 && plan.alreadySeen == 1 && plan.alreadyImported == 1 && plan.newFlights == 1)
        #expect(plan.undoFlights.map(\.route) == ["PDX>HNL", "SEA>LHR"])

        book.addFlights(plan.flights)
        #expect(book.flights.count == 3)
        #expect(book.flights.first { $0.route == "PDX>HNL" }?.sources == [.fernlet, .flighty])

        book.removeSource(.flighty, fromFlightsMatching: plan.undoFlights)
        #expect(book.flights.map(\.route) == ["PDX>HNL", "PDX>SEA"])
        #expect(book.flights.first { $0.route == "PDX>HNL" }?.sources == .fernlet)
        #expect(book.flights.first { $0.route == "PDX>SEA" }?.sources == .flighty)
    }

    /// A date-only record leaves at noon local to its departure airport, its times marked unsure.
    @Test func aDateOnlyRecordLeavesAtLocalNoon() throws {
        let record = try #require(Self.record("PDX", "HNL", (2026, 7, 4), departure: nil))
        let plan = FlightImportPlan(records: [record], source: .flighty, airports: Self.airports, book: PassportBook())
        let flight = try #require(plan.flights.first)
        #expect(flight.departure == flightUTC("2026-07-04T19:00:00Z") && flight.timesUnsure && flight.arrival == nil)
    }

    /// Two flights through one airport within the stop window are one trip with a stop; a return the same day
    /// isn't; the trips group by the year they left, newest first.
    @Test func joinsStopsAndGroupsByYear() throws {
        let legs = [
            Self.flight("PDX", "SEA", "2025-12-30T16:00:00Z", "2025-12-30T17:00:00Z", sources: .flighty),
            Self.flight("SEA", "LHR", "2025-12-30T19:40:00Z", "2025-12-31T05:00:00Z", sources: .flighty),
            Self.flight("PDX", "HNL", "2026-01-05T18:00:00Z", "2026-01-06T00:00:00Z"),
            Self.flight("HNL", "PDX", "2026-01-06T02:00:00Z", "2026-01-06T08:00:00Z"),
        ].compactMap { $0 }
        let more = (1...6).compactMap { Self.flight("PDX", "SEA", "2026-02-\(String(format: "%02d", $0 * 2))T16:00:00Z") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let model = PassportFlightsModel(flights: legs + more, point: { _ in nil }, calendar: calendar)
        #expect(model.trips.count == 9 && model.flightCount == 10)
        let first = try #require(model.trips.first)
        #expect(first.codes == ["PDX", "SEA", "LHR"] && first.isImported)
        let stop = try #require(first.stops.first)
        #expect(stop.code == "SEA" && stop.seconds.map { Int($0) } == 9_600)
        #expect(model.layoverCount == 1 && model.layoverSeconds == 2 * 3_600 + 40 * 60)
        #expect(model.years.map(\.year) == [2026, 2025])
        #expect(model.log(ofYear: 2025)?.trips == [first] && model.log(ofYear: 2025)?.flightCount == 2)
        #expect(model.log(ofYear: 2026)?.flightCount == 8)
        #expect(model.position(ofYear: 2025) == 1 && model.log(ofYear: 2019) == nil)
        #expect(model.listsYears, "nine trips don't fit one page")
        #expect(PassportFlightsModel(flights: [], point: { _ in nil }).years.isEmpty)
    }

    /// Six trips still show as stubs on the page itself; a seventh lists the years.
    @Test func aShortHistoryKeepsItsStubs() {
        let six = (1...6).compactMap { Self.flight("PDX", "SEA", "2026-02-\(String(format: "%02d", $0 * 2))T16:00:00Z") }
        #expect(!PassportFlightsModel(flights: six, point: { _ in nil }).listsYears)
        let seven = six + [Self.flight("PDX", "SEA", "2026-03-01T16:00:00Z")].compactMap { $0 }
        #expect(PassportFlightsModel(flights: seven, point: { _ in nil }).listsYears)
    }

    /// The owner's import: 178 flights add one page to the book, however they fall across the years, and every
    /// flight is in one year's log.
    @Test func aLongHistoryAddsOnePage() {
        let model = PassportFlightsModel(flights: AirportFlightsDemo.many, point: { _ in nil })
        #expect(model.flightCount == 178 && model.years.count == 13)
        #expect(model.years.reduce(0) { $0 + $1.flightCount } == 178)
        #expect(model.years.reduce(0) { $0 + $1.trips.count } == model.trips.count)
        #expect(model.layoverCount > 0, "the made-up history has connections")
        #expect(model.years.first?.year == 2026 && model.years.last?.year == 2014, "newest year first")
        let bare = PassportBookModel(entries: [])
        let book = PassportBookModel(entries: [], showsFlights: !model.isEmpty)
        #expect(book.pageCount == bare.pageCount + 1)
    }

    /// In a year's log the header gives the year, so the days leave it out unless the trip lands in the next year.
    @Test func aYearsLogLeavesTheYearOut() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        func days(_ departure: String, _ arrival: String?) throws -> String {
            let flight = try #require(Self.flight("PDX", "HNL", departure, arrival))
            let trip = PassportFlightTrip(legs: [flight], metres: 0)
            return PassportFlightsText.daysInYear(of: trip, calendar: calendar, language: .english)
        }
        #expect(try days("2024-03-12T16:00:00Z", nil) == "12 MAR")
        #expect(try days("2024-03-21T20:00:00Z", "2024-03-22T02:00:00Z") == "21–22 MAR")
        #expect(try days("2024-08-31T20:00:00Z", "2024-09-01T02:00:00Z") == "31 AUG – 1 SEP")
        #expect(try days("2024-12-31T20:00:00Z", "2025-01-01T02:00:00Z") == "31 DEC 2024 – 1 JAN 2025")
    }

    /// A trip's distance is the great circle: Portland to London is about 7,890 km, not a flat projection's.
    @Test func distancesAreGreatCircles() throws {
        let leg = try #require(Self.flight("PDX", "LHR", "2026-09-02T20:00:00Z"))
        let points = ["PDX": GeoPoint(45.5887, -122.5975), "LHR": GeoPoint(51.4700, -0.4543)]
        let model = PassportFlightsModel(flights: [leg], point: { points[$0] })
        #expect(abs(model.totalMetres - 7_890_000) < 30_000)
    }

    /// Distances round to 10 km and group by threes, with "." in Spain's Spanish and "," in English and Mexico's.
    @Test func kilometresGroupByLanguage() {
        #expect(PassportFlightsText.kilometres(24_848_000, separator: ",") == "24,850 km")
        #expect(PassportFlightsText.kilometres(162_400_000, separator: ".") == "162.400 km")
        #expect(PassportFlightsText.kilometres(880_400, separator: ",") == "880 km")
        #expect(FernletLanguage.thousandsSeparator(localization: "en") == ",")
        #expect(FernletLanguage.thousandsSeparator(localization: "es") == ".")
        #expect(FernletLanguage.thousandsSeparator(localization: "es-MX") == ",")
        #expect(PassportFlightsText.duration(9_600) == "2 h 40 min")
    }

    /// The Flights page sits between the last stamp page and the index; a book without it keeps its numbers.
    @Test func flightsPageSitsBeforeTheIndex() throws {
        let fresh = PassportBookModel(entries: [])
        #expect(fresh.pageCount == 4 && fresh.flightsPage == nil)
        let withFlights = PassportBookModel(entries: [], showsFlights: true)
        #expect(withFlights.pageCount == 5 && withFlights.flightsPage == 4 && withFlights.indexPage == 5)
        #expect(withFlights.page(at: 4) == .flights)
        #expect(withFlights.page(at: 3) == .stamps(0) && withFlights.page(at: 5) == .index)
    }
}
