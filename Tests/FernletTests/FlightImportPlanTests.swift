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
    /// isn't; the pages hold six trips each under year headings.
    @Test func joinsStopsAndPagesByYear() throws {
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
        #expect(model.pages.count == 2)
        #expect(model.rows(onPage: 0).prefix(3) == [.year(2025), .trip(0), .year(2026)])
        #expect(model.rows(onPage: 1).first == .year(2026))
        #expect(PassportFlightsModel(flights: [], point: { _ in nil }).pages == [[]])
    }

    /// A trip's distance is the great circle: Portland to London is about 7,890 km, not a flat projection's.
    @Test func distancesAreGreatCircles() throws {
        let leg = try #require(Self.flight("PDX", "LHR", "2026-09-02T20:00:00Z"))
        let points = ["PDX": GeoPoint(45.5887, -122.5975), "LHR": GeoPoint(51.4700, -0.4543)]
        let model = PassportFlightsModel(flights: [leg], point: { points[$0] })
        #expect(abs(model.totalMetres - 7_890_000) < 30_000)
    }

    /// Distances round to 10 km and group by threes, with "." in Spanish.
    @Test func kilometresGroupByLanguage() {
        #expect(PassportFlightsText.kilometres(24_848_000, language: .english) == "24,850 km")
        #expect(PassportFlightsText.kilometres(162_400_000, language: .spanish) == "162.400 km")
        #expect(PassportFlightsText.kilometres(880_400, language: .english) == "880 km")
        #expect(PassportFlightsText.duration(9_600) == "2 h 40 min")
    }

    /// The Flights pages sit between the last stamp page and the index; a book without them keeps its numbers.
    @Test func flightsPagesSitBeforeTheIndex() throws {
        let fresh = PassportBookModel(entries: [])
        #expect(fresh.pageCount == 4 && fresh.flightPageNumbers == nil)
        let withFlights = PassportBookModel(entries: [], flightPageCount: 2)
        #expect(withFlights.pageCount == 6 && withFlights.flightPageNumbers == 4 ... 5 && withFlights.indexPage == 6)
        #expect(withFlights.page(at: 4) == .flights(0) && withFlights.page(at: 5) == .flights(1))
        #expect(withFlights.page(at: 3) == .stamps(0) && withFlights.page(at: 6) == .index)
    }
}
