import Foundation
import Testing
import WorldMapStore

/// A made-up airport list for the flight readers' tests: real codes and zones, but only the handful these
/// tests fly through, plus EDT, USA and THE (real codes that are also everyday words). The one airline is the
/// spec's fictional Cedar Air.
nonisolated struct FlightTestAirports: FlightAirportLookup {
    static let zones = [
        "PDX": "America/Los_Angeles", "SEA": "America/Los_Angeles", "HNL": "Pacific/Honolulu",
        "OGG": "Pacific/Honolulu", "LHR": "Europe/London", "YVR": "America/Vancouver",
        "EDT": "America/Edmonton", "USA": "America/New_York", "THE": "America/Fortaleza",
    ]
    static let countries = ["PDX": "US", "SEA": "US", "HNL": "US", "OGG": "US", "LHR": "GB", "YVR": "CA"]
    /// Whether every airport has a country (the countries tile is left out otherwise).
    var everyCountry = true

    func timeZone(iata: String) -> TimeZone? {
        Self.zones[iata].flatMap(TimeZone.init(identifier:))
    }

    func airline(named text: String) -> WorldAirline? {
        let cedar = WorldAirline(icao: "CDR", iata: "CD", names: ["Cedar Air", "Cedar Airlines"])
        let wanted = text.lowercased()
        return [cedar.icao, cedar.iata].map { $0.lowercased() }.contains(wanted)
            || cedar.names.contains { $0.lowercased() == wanted } ? cedar : nil
    }

    func countryCode(iata: String) -> String? {
        everyCountry || iata != "YVR" ? Self.countries[iata] : nil
    }

    func airportPoint(iata: String) -> GeoPoint? {
        iata == "PDX" ? GeoPoint(45.5887, -122.5975) : nil
    }

    func airportName(iata: String) -> String? {
        iata == "PDX" ? "Portland International" : nil
    }
}

/// The instant an ISO 8601 UTC string names (a typo gives the distant past, which no expectation matches).
nonisolated func flightUTC(_ text: String) -> Date {
    ISO8601DateFormatter().date(from: text) ?? .distantPast
}

/// Reading a Flighty export (World-Airports-Spec §9): every fixture is made up (Cedar Air out of Portland),
/// shaped like the 33-column export, with booking codes, seats and notes in the columns that must never be read.
@MainActor
struct FlightyImportTests {
    static let header = """
        Date,Airline,Flight,From,To,Dep Terminal,Dep Gate,Arr Terminal,Arr Gate,Canceled,Diverted To,\
        Gate Departure (Scheduled),Gate Departure (Actual),Take off (Scheduled),Take off (Actual),\
        Landing (Scheduled),Landing (Actual),Gate Arrival (Scheduled),Gate Arrival (Actual),Aircraft Type Name,\
        Tail Number,PNR,Seat,Seat Type,Cabin Class,Flight Reason,Notes,Flight Flighty ID,Airline Flighty ID,\
        Departure Airport Flighty ID,Arrival Airport Flighty ID,Diverted To Airport Flighty ID,Aircraft Type Flighty ID
        """

    /// One 33-column row; take-off and landing are left empty, as in real exports.
    static func row(_ date: String, _ from: String, _ to: String, canceled: String = "false", diverted: String = "",
                    departure: (scheduled: String, actual: String) = ("", ""),
                    arrival: (scheduled: String, actual: String) = ("", ""), id: String = "",
                    notes: String = "\"Window seat, please \"\"if\"\" free\"") -> String {
        [date, "Cedar Air", "812", from, to, "B", "C4", "2", "A9", canceled, diverted,
         departure.scheduled, departure.actual, "", "", "", "", arrival.scheduled, arrival.actual,
         "Airbus A321neo", "N812CD", "K7QX2M", "14A", "WINDOW", "ECONOMY", "LEISURE", notes, id,
         "cedar-air", "pdx-1", "hnl-1", "", "a21n"].joined(separator: ",")
    }

    static func file(_ rows: [String], bom: Bool = true, lineEnd: String = "\r\n") -> Data {
        var data = bom ? Data([0xEF, 0xBB, 0xBF]) : Data()
        data.append(Data(([header] + rows).joined(separator: lineEnd).utf8))
        data.append(Data(lineEnd.utf8))
        return data
    }

    private nonisolated func read(_ data: Data,
                                  airports: FlightTestAirports = FlightTestAirports()) throws -> FlightyImport {
        try FlightyImport(data: data, airports: airports)
    }

    /// A BOM, CRLF lines and a quoted notes field holding commas, doubled quotes and a line break still read
    /// as one flight, its gate times read in each airport's zone.
    @Test func bomQuotingAndZones() throws {
        let notes = "\"Aisle, \"\"please\"\"\r\nsecond line\""
        let result = try read(Self.file([Self.row(
            "2026-03-12", "PDX", "HNL", departure: ("2026-03-12T09:00", "2026-03-12T09:05"),
            arrival: ("2026-03-12T11:40", "2026-03-12T11:45"), id: "f-1", notes: notes)]))
        #expect(result.flights.count == 1)
        let flight = try #require(result.flights.first)
        #expect(flight.from == "PDX" && flight.to == "HNL")
        #expect(flight.day == FlightDay(year: 2026, month: 3, day: 12))
        #expect(flight.departure == flightUTC("2026-03-12T16:05:00Z"), "09:05 PDT")
        #expect(flight.arrival == flightUTC("2026-03-12T21:45:00Z"), "11:45 HST")
        #expect(!flight.timesUnsure)
    }

    /// LF lines and no BOM read the same; scheduled times stand in where actual ones are empty.
    @Test func lfWithoutBOMAndScheduledTimes() throws {
        let result = try read(Self.file([Self.row(
            "2026-03-12", "PDX", "HNL", departure: ("2026-03-12T09:05", ""), arrival: ("2026-03-12T11:45", ""))],
            bom: false, lineEnd: "\n"))
        let flight = try #require(result.flights.first)
        #expect(flight.departure == flightUTC("2026-03-12T16:05:00Z"))
        #expect(flight.arrival == flightUTC("2026-03-12T21:45:00Z"))
    }

    /// Columns are found by name: a reordered file with an extra column imports.
    @Test func columnsMatchByName() throws {
        let text = "Seat,To,New Column,Gate Arrival (Actual),date,FROM,Gate Departure (Actual)\n"
            + "14A,HNL,whatever,2026-03-12T11:45,2026-03-12,PDX,2026-03-12T09:05\n"
        let result = try read(Data(text.utf8))
        let flight = try #require(result.flights.first)
        #expect(flight.from == "PDX" && flight.to == "HNL")
        #expect(flight.arrival == flightUTC("2026-03-12T21:45:00Z"))
    }

    /// Date, From and To are the only columns a file must have.
    @Test func missingRequiredColumnRefused() {
        #expect(throws: FlightyImportRefusal.missingColumn("From")) {
            try read(Data("Date,To\n2026-03-12,HNL\n".utf8))
        }
        #expect(throws: FlightyImportRefusal.empty) { try read(Data()) }
    }

    /// The caps turn a wrong or huge file away whole, with a reason.
    @Test func capsRefuseWithAReason() {
        #expect(throws: FlightyImportRefusal.tooLarge) {
            try read(Data(count: FlightyImport.maxFileBytes + 1))
        }
        let rows = String(repeating: "2026-03-12,PDX,SEA\n", count: FlightyImport.maxRows + 1)
        #expect(throws: FlightyImportRefusal.tooManyRows) { try read(Data(("Date,From,To\n" + rows).utf8)) }
        let wide = Array(repeating: "x", count: FlightyImport.maxFields + 1).joined(separator: ",")
        #expect(throws: FlightyImportRefusal.tooManyFields(row: 2)) {
            try read(Data("Date,From,To\n\(wide)\n".utf8))
        }
        let long = String(repeating: "x", count: FlightyImport.maxFieldBytes + 1)
        #expect(throws: FlightyImportRefusal.fieldTooLong(row: 2)) {
            try read(Data("Date,From,To,Notes\n2026-03-12,PDX,SEA,\"\(long)\"\n".utf8))
        }
        #expect(throws: FlightyImportRefusal.badQuoting(row: 2)) {
            try read(Data("Date,From,To,Notes\n2026-03-12,PDX,SEA,\"never closed\n".utf8))
        }
        #expect(throws: FlightyImportRefusal.badQuoting(row: 2)) {
            try read(Data("Date,From,To,Notes\n2026-03-12,PDX,SEA,\"closed\"then more\n".utf8))
        }
    }

    /// Exactly at the caps still reads.
    @Test func atTheCapsReads() throws {
        let rows = String(repeating: "2026-03-12,PDX,SEA\n", count: FlightyImport.maxRows)
        let result = try read(Data(("Date,From,To\n" + rows).utf8))
        #expect(result.flights.count == FlightyImport.maxRows)
        let field = String(repeating: "x", count: FlightyImport.maxFieldBytes)
        #expect(try read(Data("Date,From,To,Notes\n2026-03-12,PDX,SEA,\(field)\n".utf8)).flights.count == 1)
    }

    /// A cancelled row is skipped and counted.
    @Test func cancelledSkipped() throws {
        let result = try read(Self.file([
            Self.row("2026-03-12", "PDX", "HNL", canceled: "true", id: "f-1"),
            Self.row("2026-03-19", "HNL", "PDX", canceled: "false", id: "f-2"),
        ]))
        #expect(result.flights.map(\.from) == ["HNL"])
        #expect(result.summary.cancelled == 1)
    }

    /// Diverted To is the real destination; its actual arrival is read in the diversion's zone, and a diverted
    /// flight with only a scheduled arrival (at the airport it never reached) keeps no arrival.
    @Test func divertedLandsWhereItLanded() throws {
        let result = try read(Self.file([
            Self.row("2026-03-12", "PDX", "HNL", diverted: "OGG", departure: ("", "2026-03-12T09:05"),
                     arrival: ("2026-03-12T11:45", "2026-03-12T12:30"), id: "f-1"),
            Self.row("2026-03-13", "PDX", "HNL", diverted: "OGG", departure: ("", "2026-03-13T09:05"),
                     arrival: ("2026-03-13T11:45", ""), id: "f-2"),
        ]))
        #expect(result.flights.count == 2)
        #expect(result.flights.allSatisfy { $0.to == "OGG" })
        #expect(result.flights[0].arrival == flightUTC("2026-03-12T22:30:00Z"))
        #expect(!result.flights[0].timesUnsure)
        #expect(result.flights[1].arrival == nil && result.flights[1].timesUnsure)
    }

    /// A row repeating a Flighty flight ID counts once.
    @Test func repeatedRowCountsOnce() throws {
        let row = Self.row("2026-03-12", "PDX", "HNL", id: "f-1")
        let result = try read(Self.file([row, row, row]))
        #expect(result.flights.count == 1)
        #expect(result.summary.repeatedRows == 2)
    }

    /// A code that isn't in the list skips its row and is named, never guessed.
    @Test func unknownCodeNamed() throws {
        let result = try read(Self.file([
            Self.row("2026-03-12", "PDX", "ZZY", id: "f-1"),
            Self.row("2026-03-13", "ZZX", "ZZY", id: "f-2"),
            Self.row("2026-03-14", "PDX", "HNL", id: "f-3"),
        ]))
        #expect(result.flights.count == 1)
        #expect(result.summary.unknownCodes == ["ZZX", "ZZY"])
    }

    /// Rows with a bad date, a code that isn't three capitals, or one airport at both ends are counted, not read.
    @Test func unreadableRowsCounted() throws {
        let result = try read(Self.file([
            Self.row("2026-02-30", "PDX", "HNL", id: "f-1"),
            Self.row("12/03/2026", "PDX", "HNL", id: "f-2"),
            Self.row("2026-03-12", "pdx", "HNL", id: "f-3"),
            Self.row("2026-03-12", "PDX", "PDX", id: "f-4"),
        ]))
        #expect(result.flights.isEmpty)
        #expect(result.summary.unreadableRows == 4 && result.summary.unknownCodes.isEmpty)
    }

    /// Each end is read in its own airport's zone, including the weeks the US and UK change clocks apart.
    @Test func zonesAcrossDaylightSaving() throws {
        let result = try read(Self.file([
            Self.row("2026-03-20", "PDX", "LHR", departure: ("", "2026-03-20T13:00"),
                     arrival: ("", "2026-03-21T07:00"), id: "f-1"),
            Self.row("2026-04-02", "PDX", "LHR", departure: ("", "2026-04-02T13:00"),
                     arrival: ("", "2026-04-03T07:00"), id: "f-2"),
            Self.row("2026-01-15", "PDX", "LHR", departure: ("", "2026-01-15T13:00"),
                     arrival: ("", "2026-01-16T07:00"), id: "f-3"),
        ]))
        #expect(result.flights.count == 3)
        #expect(result.flights[0].departure == flightUTC("2026-03-20T20:00:00Z"), "PDT")
        #expect(result.flights[0].arrival == flightUTC("2026-03-21T07:00:00Z"), "GMT")
        #expect(result.flights[1].arrival == flightUTC("2026-04-03T06:00:00Z"), "BST")
        #expect(result.flights[2].departure == flightUTC("2026-01-15T21:00:00Z"), "PST")
        #expect(result.flights.allSatisfy { !$0.timesUnsure })
    }

    /// A trip of zero or less, or over 20 hours, drops the arrival and marks the times unsure; a row with no
    /// gate times gives the day only.
    @Test func durationsOutOfBounds() throws {
        let result = try read(Self.file([
            Self.row("2026-03-12", "PDX", "SEA", departure: ("", "2026-03-12T09:05"),
                     arrival: ("", "2026-03-12T09:05"), id: "f-1"),
            Self.row("2026-03-12", "PDX", "LHR", departure: ("", "2026-03-12T09:05"),
                     arrival: ("", "2026-03-13T14:00"), id: "f-2"),
            Self.row("2026-03-12", "PDX", "HNL", id: "f-3"),
            Self.row("2026-03-12", "PDX", "YVR", departure: ("", "2026-03-12T09:05"),
                     arrival: ("", "2026-03-12T10:10"), id: "f-4"),
        ]))
        #expect(result.flights.count == 4)
        #expect(result.flights[0].arrival == nil && result.flights[0].timesUnsure, "zero minutes")
        #expect(result.flights[1].arrival == nil && result.flights[1].timesUnsure, "21 hours")
        #expect(result.flights[2].departure == nil && result.flights[2].arrival == nil && !result.flights[2].timesUnsure)
        #expect(result.flights[3].arrival != nil && !result.flights[3].timesUnsure, "65 minutes")
    }

    /// The summary's tiles: flights, distinct airports, countries and the years flown; countries are left out
    /// when any airport has no country in the list.
    @Test func summaryTiles() throws {
        let data = Self.file([
            Self.row("2019-06-01", "PDX", "HNL", id: "f-1"),
            Self.row("2026-03-12", "PDX", "LHR", id: "f-2"),
            Self.row("2023-08-09", "SEA", "YVR", id: "f-3"),
        ])
        let summary = try read(data).summary
        #expect(summary.flights == 3 && summary.airports == 5)
        #expect(summary.countries == 3)
        #expect(summary.years == 2019...2026)
        #expect(summary.cancelled == 0 && summary.repeatedRows == 0 && summary.unreadableRows == 0)
        #expect(try read(data, airports: FlightTestAirports(everyCountry: false)).summary.countries == nil)
    }

    /// Columns that are never read are never decoded: bytes that aren't UTF-8 in the PNR and notes don't stop
    /// the row, and nothing from those columns reaches a flight.
    @Test func unreadColumnsAreNeverDecoded() throws {
        var data = Data((Self.header + "\n").utf8)
        let before = "2026-03-12,Cedar Air,812,PDX,HNL,B,C4,2,A9,false,,,2026-03-12T09:05,,,,,,2026-03-12T11:45,"
            + "Airbus A321neo,N812CD,"
        data.append(Data(before.utf8))
        data.append(contentsOf: [0xFF, 0xFE, 0x41])
        data.append(Data(",14A,WINDOW,ECONOMY,LEISURE,".utf8))
        data.append(contentsOf: [0xC3, 0x28])
        data.append(Data(",f-1,cedar-air,pdx-1,hnl-1,,a21n\n".utf8))
        let result = try read(data)
        let flight = try #require(result.flights.first)
        #expect(flight.from == "PDX" && flight.to == "HNL")
        let shown = String(describing: result)
        #expect(!shown.contains("Cedar") && !shown.contains("812") && !shown.contains("14A") && !shown.contains("f-1"))
    }
}
