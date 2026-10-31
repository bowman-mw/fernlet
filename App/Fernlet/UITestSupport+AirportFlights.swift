import Foundation
import WorldMapStore

#if DEBUG
/// The airports screenshots' made-up flights (World-Airports-Spec's data rule: a traveller from Portland, never
/// anyone's real history): the Flights page's stubs and the Flighty import's summary. In memory only, never
/// written. Absent in Release.
enum AirportFlightsDemo {
    /// Fernlet's own flights (the mockup's page 11) and imported ones from 2014–15 (its page 23).
    static let flights: [PassportFlight] = {
        let rows: [(String, String, String, String?, PassportFlight.Sources)] = [
            ("PDX", "SFO", "2014-02-12T16:00:00Z", "2014-02-12T17:50:00Z", .flighty),
            ("SFO", "PDX", "2014-02-16T20:00:00Z", "2014-02-16T21:45:00Z", .flighty),
            ("PDX", "HNL", "2014-11-22T18:00:00Z", "2014-11-23T00:10:00Z", .flighty),
            ("HNL", "PDX", "2015-01-02T08:00:00Z", "2015-01-02T13:40:00Z", .flighty),
            ("PDX", "ORD", "2015-06-03T14:00:00Z", "2015-06-03T18:10:00Z", .flighty),
            ("ORD", "BOS", "2015-06-03T20:00:00Z", "2015-06-03T22:20:00Z", .flighty),
            ("PDX", "MEX", "2026-08-20T15:00:00Z", "2026-08-20T21:30:00Z", .fernlet),
            ("MEX", "PDX", "2026-08-28T16:00:00Z", "2026-08-28T22:20:00Z", .fernlet),
            ("PDX", "LHR", "2026-09-02T20:00:00Z", "2026-09-03T05:40:00Z", .fernlet),
            ("CDG", "HEL", "2026-09-21T09:00:00Z", "2026-09-21T11:50:00Z", .fernlet),
            ("HEL", "NRT", "2026-09-21T14:30:00Z", "2026-09-22T00:30:00Z", .fernlet),
        ]
        return rows.compactMap { row in
            ISO8601DateFormatter().date(from: row.2).flatMap { departure in
                PassportFlight(from: row.0, to: row.1, departure: departure,
                               arrival: row.3.flatMap { ISO8601DateFormatter().date(from: $0) }, sources: row.4)
            }
        }
    }()

    /// A Flighty file holding the same made-up flights, planned against a passport that already has Fernlet's
    /// own five ("5 flights Fernlet saw, kept once"), with two cancelled rows, four repeated and one unknown code.
    static let found: FlightyImportFound = {
        var book = PassportBook()
        book.addFlights(flights.filter { $0.sources.contains(.fernlet) })
        let records = flights.map { flight in
            FlightRecord(from: flight.from, to: flight.to, day: FlightDay(flight.departure, in: .gmt),
                         departure: flight.departure, arrival: flight.arrival, timesUnsure: false)
        }
        let plan = FlightImportPlan(records: records, source: .flighty, airports: NoFlightAirports(), book: book)
        let summary = FlightyImportSummary(flights: records.count, airports: 10, countries: 6, years: 2014 ... 2026,
                                           cancelled: 2, repeatedRows: 4, unknownCodes: ["XYZ"], unreadableRows: 0)
        return FlightyImportFound(fileName: "FlightyExport.csv", summary: summary, plan: plan)
    }()
}

/// No airports at all: the demo's records all carry their times, so no zone is looked up.
private nonisolated struct NoFlightAirports: FlightAirportLookup {
    func timeZone(iata: String) -> TimeZone? { nil }
    func airline(named text: String) -> WorldAirline? { nil }
}
#endif
