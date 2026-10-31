import Foundation

/// Why a Flighty file was turned away whole (World-Airports-Spec §9.1: a wrong or huge file gets a message).
/// Row numbers count records from 1, the header being record 1.
public nonisolated enum FlightyImportRefusal: Error, Equatable, Sendable {
    /// Over ``FlightyImport/maxFileBytes``.
    case tooLarge
    /// No header row.
    case empty
    /// The header isn't UTF-8 text.
    case notText
    /// Over ``FlightyImport/maxRows`` flights.
    case tooManyRows
    /// A record with over ``FlightyImport/maxFields`` fields.
    case tooManyFields(row: Int)
    /// A field over ``FlightyImport/maxFieldBytes``.
    case fieldTooLong(row: Int)
    /// A quoted field that never closes, or text straight after a closing quote.
    case badQuoting(row: Int)
    /// One of the three columns every import needs (Date, From, To) is missing.
    case missingColumn(String)
}

/// What a Flighty file held (spec §9.4): the sheet's tiles and its "Skipped" line.
public nonisolated struct FlightyImportSummary: Equatable, Sendable {
    /// The flights found.
    public let flights: Int
    /// The distinct airports they touch.
    public let airports: Int
    /// The distinct countries, or nil where any of those airports has no country in the list (the tile is
    /// left out rather than undercounted).
    public let countries: Int?
    /// The first and last year flown, or nil with no flights.
    public let years: ClosedRange<Int>?
    /// Rows marked cancelled.
    public let cancelled: Int
    /// Rows repeating a Flighty flight ID already read, counted once.
    public let repeatedRows: Int
    /// Codes that aren't in the airport list, sorted. Their rows are skipped and the codes named, never guessed.
    public let unknownCodes: [String]
    /// Rows with a missing or malformed date or airport code, or a route that starts and ends at one airport.
    public let unreadableRows: Int
}

/// A Flighty CSV export, read once on this iPhone and not kept (spec §9).
///
/// Only the date, From, To, Canceled, Diverted To, the four gate times and Flighty's flight ID are ever turned
/// into text; every other field (the airline, flight number, aircraft, PNR, seat, cabin, reason, notes, tail,
/// terminals and gates) is stepped over by its byte length and never decoded. Columns are found by name, so
/// a Flighty update that adds or reorders columns still imports.
public nonisolated struct FlightyImport: Sendable {
    /// The largest file read (5 MiB; the owner's years of flights are a few hundred KB).
    public static let maxFileBytes = 5_242_880
    /// The most records after the header.
    public static let maxRows = 20_000
    /// The most fields one record may have (the export has 33).
    public static let maxFields = 64
    /// The longest one field may be.
    public static let maxFieldBytes = 4_096

    /// The flights found, in the file's order.
    public let flights: [FlightRecord]
    public let summary: FlightyImportSummary

    /// The columns read, by their header names (compared ignoring case and surrounding spaces).
    private enum Column: String, CaseIterable {
        case date = "date"
        case from = "from"
        case to = "to"
        case canceled = "canceled"
        case divertedTo = "diverted to"
        case departureScheduled = "gate departure (scheduled)"
        case departureActual = "gate departure (actual)"
        case arrivalScheduled = "gate arrival (scheduled)"
        case arrivalActual = "gate arrival (actual)"
        case flightID = "flight flighty id"
    }

    /// Reads `data`, or throws why the whole file is refused. A row that can't be used is skipped and counted.
    public init(data: Data, airports: some FlightAirportLookup) throws(FlightyImportRefusal) {
        guard data.count <= Self.maxFileBytes else { throw .tooLarge }
        var scanner = CSVScanner(bytes: [UInt8](data))
        guard let header = try scanner.nextRecord(row: 1) else { throw .empty }
        var columns: [Column: Int] = [:]
        // Bounded: header.count <= maxFields.
        for (index, cell) in header.enumerated() {
            guard let name = scanner.text(cell) else { throw .notText }
            let key = name.trimmingCharacters(in: .whitespaces).lowercased()
            if let column = Column(rawValue: key), columns[column] == nil { columns[column] = index }
        }
        // Bounded: three columns.
        for required in [Column.date, .from, .to] where columns[required] == nil {
            throw .missingColumn(required.rawValue.capitalized)
        }

        var tally = Tally()
        var flights: [FlightRecord] = []
        var row = 1
        // Bounded: each pass consumes at least one byte of a file <= maxFileBytes, and records past maxRows throw.
        while let record = try scanner.nextRecord(row: row + 1) {
            row += 1
            guard row - 1 <= Self.maxRows else { throw .tooManyRows }
            if record.count == 1, record[0].isEmpty { continue }
            var values: [Column: String] = [:]
            // Bounded: Column has ten cases; every other field is never decoded.
            for (column, index) in columns where index < record.count {
                values[column] = scanner.text(record[index])?.trimmingCharacters(in: .whitespaces) ?? ""
            }
            if let flight = Self.flight({ values[$0] ?? "" }, airports: airports, tally: &tally) {
                flights.append(flight)
            }
        }

        self.flights = flights
        summary = tally.summary(flights: flights, airports: airports)
    }

    /// One row's flight, or nil with the reason counted.
    private static func flight(_ field: (Column) -> String, airports: some FlightAirportLookup,
                               tally: inout Tally) -> FlightRecord? {
        let id = field(.flightID)
        if !id.isEmpty {
            guard tally.seenIDs.insert(id).inserted else { tally.repeated += 1; return nil }
        }
        if field(.canceled).lowercased() == "true" { tally.cancelled += 1; return nil }
        guard let day = date(field(.date)), let from = code(field(.from)), let planned = code(field(.to)) else {
            tally.unreadable += 1
            return nil
        }
        let divertedText = field(.divertedTo)
        let diverted = divertedText.isEmpty ? nil : code(divertedText)
        guard divertedText.isEmpty || diverted != nil else { tally.unreadable += 1; return nil }
        let to = diverted ?? planned
        let fromZone = airports.timeZone(iata: from), toZone = airports.timeZone(iata: to)
        if fromZone == nil { tally.unknown.insert(from) }
        if toZone == nil { tally.unknown.insert(to) }
        guard let fromZone, let toZone else { return nil }
        guard from != to else { tally.unreadable += 1; return nil }

        let departureText = field(.departureActual).isEmpty ? field(.departureScheduled) : field(.departureActual)
        // A diverted flight's scheduled arrival is at the airport it never reached, so only an actual one counts.
        let arrivalText = diverted != nil ? field(.arrivalActual)
            : (field(.arrivalActual).isEmpty ? field(.arrivalScheduled) : field(.arrivalActual))
        guard let departure = localTime(departureText, in: fromZone) else {
            return FlightRecord(from: from, to: to, day: day, departure: nil, arrival: nil, timesUnsure: false)
        }
        let arrival = localTime(arrivalText, in: toZone)
        let checked = FlightClock.checked(departure: departure, arrival: arrival)
        let unsure = checked.unsure || (diverted != nil && arrival == nil)
        return FlightRecord(from: from, to: to, day: day, departure: departure, arrival: checked.arrival,
                            timesUnsure: unsure)
    }

    /// Three capital ASCII letters, else nil.
    static func code(_ text: String) -> String? {
        let bytes = Array(text.utf8)
        guard bytes.count == 3, bytes.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return text
    }

    /// `YYYY-MM-DD`.
    static func date(_ text: String) -> FlightDay? {
        let bytes = Array(text.utf8)
        guard bytes.count == 10, bytes[4] == 45, bytes[7] == 45, let year = number(bytes, 0, 4),
              let month = number(bytes, 5, 2), let day = number(bytes, 8, 2) else { return nil }
        return FlightDay(year: year, month: month, day: day)
    }

    /// `YYYY-MM-DDTHH:MM` (a space for the T and trailing `:SS` are allowed) read in `zone`, or nil.
    static func localTime(_ text: String, in zone: TimeZone) -> Date? {
        let bytes = Array(text.utf8)
        guard bytes.count == 16 || bytes.count == 19, bytes[4] == 45, bytes[7] == 45,
              bytes[10] == 84 || bytes[10] == 32, bytes[13] == 58,
              bytes.count == 16 || bytes[16] == 58,
              let year = number(bytes, 0, 4), let month = number(bytes, 5, 2), let day = number(bytes, 8, 2),
              let hour = number(bytes, 11, 2), let minute = number(bytes, 14, 2),
              bytes.count == 16 || number(bytes, 17, 2) != nil else { return nil }
        return FlightClock.instant(year: year, month: month, day: day, hour: hour, minute: minute, in: zone)
    }

    /// The decimal number in `bytes[start..<start+length]`, all digits.
    private static func number(_ bytes: [UInt8], _ start: Int, _ length: Int) -> Int? {
        guard start >= 0, start + length <= bytes.count else { return nil }
        var value = 0
        // Bounded: length <= 4.
        for byte in bytes[start..<(start + length)] {
            guard (48...57).contains(byte) else { return nil }
            value = value * 10 + Int(byte - 48)
        }
        return value
    }

    /// Counts kept while the file is read; the flight IDs here never leave this reader.
    private struct Tally {
        var seenIDs: Set<String> = []
        var repeated = 0
        var cancelled = 0
        var unreadable = 0
        var unknown: Set<String> = []

        func summary(flights: [FlightRecord], airports: some FlightAirportLookup) -> FlightyImportSummary {
            var codes: Set<String> = []
            var years: Set<Int> = []
            // Bounded: flights.count <= maxRows.
            for flight in flights {
                codes.insert(flight.from)
                codes.insert(flight.to)
                years.insert(flight.day.year)
            }
            let countryCodes = codes.map { airports.countryCode(iata: $0) }
            let countries = countryCodes.contains(nil) ? nil : Set(countryCodes.compactMap { $0 }).count
            let span = years.min().flatMap { first in years.max().map { first...$0 } }
            return FlightyImportSummary(
                flights: flights.count, airports: codes.count, countries: codes.isEmpty ? nil : countries,
                years: span, cancelled: cancelled, repeatedRows: repeated, unknownCodes: unknown.sorted(),
                unreadableRows: unreadable)
        }
    }
}

/// An RFC 4180 reader over raw bytes: commas, quotes, CR and LF are ASCII, so UTF-8 text never confuses it.
/// A record comes back as byte ranges, and only the ranges a reader asks for are ever decoded.
nonisolated struct CSVScanner {
    /// One field's bytes, inside its quotes where it was quoted.
    struct Field {
        let range: Range<Int>
        let quoted: Bool
        var isEmpty: Bool { range.isEmpty }
    }

    private let bytes: [UInt8]
    private var position: Int

    init(bytes: [UInt8]) {
        self.bytes = bytes
        position = bytes.starts(with: [0xEF, 0xBB, 0xBF]) ? 3 : 0
    }

    /// The next record, nil at the end of the file, or a refusal naming `row`.
    mutating func nextRecord(row: Int) throws(FlightyImportRefusal) -> [Field]? {
        guard position < bytes.count else { return nil }
        var fields: [Field] = []
        // Bounded: each pass consumes at least one byte or ends the record, and fields past maxFields throw.
        while true {
            let field = try nextField(row: row)
            guard field.range.count <= FlightyImport.maxFieldBytes else { throw .fieldTooLong(row: row) }
            fields.append(field)
            guard fields.count <= FlightyImport.maxFields else { throw .tooManyFields(row: row) }
            guard position < bytes.count else { return fields }
            switch bytes[position] {
            case 44:
                position += 1
                if position == bytes.count { fields.append(Field(range: position..<position, quoted: false)) }
                guard position < bytes.count else { return fields }
            case 13:
                position += 1
                if position < bytes.count, bytes[position] == 10 { position += 1 }
                return fields
            case 10:
                position += 1
                return fields
            default:
                throw .badQuoting(row: row)
            }
        }
    }

    /// One field, leaving `position` on the comma, line break or end that follows it.
    private mutating func nextField(row: Int) throws(FlightyImportRefusal) -> Field {
        guard position < bytes.count, bytes[position] == 34 else {
            let start = position
            // Bounded: at most bytes.count steps.
            while position < bytes.count, bytes[position] != 44, bytes[position] != 13, bytes[position] != 10 {
                position += 1
                guard position - start <= FlightyImport.maxFieldBytes else { throw .fieldTooLong(row: row) }
            }
            return Field(range: start..<position, quoted: false)
        }
        position += 1
        let start = position
        // Bounded: at most bytes.count steps.
        while position < bytes.count {
            guard position - start <= FlightyImport.maxFieldBytes else { throw .fieldTooLong(row: row) }
            if bytes[position] == 34 {
                if position + 1 < bytes.count, bytes[position + 1] == 34 {
                    position += 2
                    continue
                }
                let field = Field(range: start..<position, quoted: true)
                position += 1
                return field
            }
            position += 1
        }
        throw .badQuoting(row: row)
    }

    /// A field's text with doubled quotes undone, or nil where it isn't UTF-8.
    func text(_ field: Field) -> String? {
        guard let text = String(bytes: bytes[field.range], encoding: .utf8) else { return nil }
        return field.quoted ? text.replacingOccurrences(of: "\"\"", with: "\"") : text
    }
}
