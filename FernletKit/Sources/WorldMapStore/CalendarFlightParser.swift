import CryptoKit
import Foundation

/// One calendar event as plain values (World-Airports-Spec §10), filled in by whoever reads EventKit. The
/// title and location are cut to ``maxTitleBytes`` and ``maxLocationBytes`` and the notes to
/// ``maxNotesBytes`` as the value is made, so nothing past them is ever read. Attendees, links and the
/// calendar's name have no place here: they're never trusted, so they're never handed over.
public nonisolated struct CalendarFlightEvent: Sendable {
    /// The longest title read.
    public static let maxTitleBytes = 1_024
    /// The longest location read.
    public static let maxLocationBytes = 1_024
    /// The notes read (spec §10.6: only the first 4 KB).
    public static let maxNotesBytes = 4_096

    public let title: String
    /// The location text, or empty.
    public let location: String
    /// The notes' first ``maxNotesBytes``, or empty.
    public let notes: String
    /// The event's start (a true instant unless the event is floating).
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// The event's IANA zone, or nil for a floating event (its times are wall-clock times).
    public let timeZoneIdentifier: String?
    /// The structured location's coordinate, where it has one.
    public let locationCoordinate: GeoPoint?
    /// `calendarItemExternalIdentifier`, hashed with a salt before anything keeps it.
    public let externalIdentifier: String?

    public init(title: String, location: String?, notes: String?, start: Date, end: Date, isAllDay: Bool,
                timeZoneIdentifier: String?, locationCoordinate: GeoPoint?, externalIdentifier: String?) {
        self.title = Self.prefix(title, bytes: Self.maxTitleBytes)
        self.location = Self.prefix(location ?? "", bytes: Self.maxLocationBytes)
        self.notes = Self.prefix(notes ?? "", bytes: Self.maxNotesBytes)
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.timeZoneIdentifier = timeZoneIdentifier
        self.locationCoordinate = locationCoordinate
        self.externalIdentifier = externalIdentifier
    }

    /// `text`'s first `bytes` UTF-8 bytes (a character cut in half becomes a replacement mark).
    static func prefix(_ text: String, bytes: Int) -> String {
        guard text.utf8.count > bytes else { return text }
        return String(decoding: text.utf8.prefix(bytes), as: UTF8.self)
    }
}

/// A calendar event read as a flight (spec §10.4): the flight and a salted hash of the event's identifier,
/// so a later look recognises the event without keeping its ID.
public nonisolated struct CalendarFlight: Equatable, Sendable {
    public let flight: FlightRecord
    /// HMAC-SHA256 of the external identifier under the caller's salt, as 64 lowercase hex, or nil where the
    /// event has no external identifier (it's then matched like any other source, by route and ±3 hours).
    public let eventHash: String?
    /// Whether the event's location agrees with the departure (its coordinate within
    /// ``CalendarFlightParser/locationConfirmRadius`` of the airport, or its text naming the airport). The
    /// location only ever confirms; it never names an airport.
    public let locationConfirmsDeparture: Bool
}

/// Why an event wasn't read as a flight. Nothing from a skipped event is kept.
public nonisolated enum CalendarFlightSkip: Error, Equatable, Sendable {
    /// The title doesn't look like a flight (the cheap first pass).
    case notAFlight
    /// No two airports in the list, in a route's words (the summary's "flight events with no airport codes").
    case noRoute
    /// A route, but no flight number.
    case noFlightNumber
}

/// One event's reading.
public nonisolated enum CalendarFlightReading: Equatable, Sendable {
    case flight(CalendarFlight)
    case skipped(CalendarFlightSkip)
}

/// The event shapes Fernlet knows (spec §10.3). Each has its own recognizer; an event no recognizer reads is
/// skipped. Found in Mail/Siri, Google, TripIt, Flighty's own events and airline apps wait for owner samples.
public nonisolated enum CalendarFlightShape: CaseIterable, Sendable {
    /// Outlook's "added from email" event (the one confirmed shape): "from <place> (ABC)" and
    /// "in <place> (DEF)" in the notes, "flight 812" in the title or notes, and local "Departs at" /
    /// "Arrives at" lines for the cross-check.
    case outlookFromEmail
    /// A title naming two codes joined by an arrow, a dash or "to" ("PDX → HNL"), or "from <place> (ABC)" and
    /// "to <place> (DEF)", with a flight number in the title.
    case codesInTitle
}

/// Reads calendar events as flights (spec §10.3–§10.4), on values alone: no EventKit, no network.
///
/// A flight needs a route (two airports in the list, each in a route's words) and a flight number. A bare
/// three-capital word never counts as an airport (EDT, USA and THE are real codes), a city alone never does,
/// and the title's parenthesis (the booking code) never does on its own. The airline and flight number are
/// only checked for in memory and never come out; the booking code, links and notes text are never kept.
public nonisolated enum CalendarFlightParser {
    /// How far a notes time may be from the event's own (spec §10.4).
    public static let crossCheckTolerance: TimeInterval = 5 * 60
    /// How near a structured location must be to the departure airport to confirm it.
    public static let locationConfirmRadius = 25_000.0
    /// The longest place name between a route word and its "(ABC)".
    static let maxPlaceCharacters = 80

    /// The cheap first pass over a title alone (spec §10.6): "flight", "vuelo", a plane, two known codes
    /// joined by an arrow, a dash or "to", or a carrier (by code or by name from the airline table) with
    /// a number.
    public static func mightBeFlight(title: String, airports: some FlightAirportLookup) -> Bool {
        let title = CalendarFlightEvent.prefix(title, bytes: CalendarFlightEvent.maxTitleBytes)
        if title.range(of: "flight", options: .caseInsensitive) != nil
            || title.range(of: "vuelo", options: [.caseInsensitive, .diacriticInsensitive]) != nil
            || title.unicodeScalars.contains(where: { $0.value == 0x2708 }) {
            return true
        }
        let text = FlightText(title)
        return text.joinedRoute(airports: airports) != nil || text.hasFlightNumber(airports: airports)
    }

    /// Reads `event`, trying each shape in turn. `salt` keys the event hash; `deviceTimeZone` is the zone
    /// EventKit used for floating and all-day events (the phone's own).
    public static func read(_ event: CalendarFlightEvent, airports: some FlightAirportLookup, salt: SymmetricKey,
                            deviceTimeZone: TimeZone = .current) -> CalendarFlightReading {
        guard mightBeFlight(title: event.title, airports: airports) else { return .skipped(.notAFlight) }
        let title = FlightText(event.title), notes = FlightText(event.notes)
        var sawRoute = false
        // Bounded: two shapes.
        for shape in CalendarFlightShape.allCases {
            guard let candidate = candidate(shape, title: title, notes: notes, airports: airports) else { continue }
            sawRoute = true
            guard candidate.hasFlightNumber else { continue }
            guard let flight = flight(candidate, event: event, airports: airports, deviceTimeZone: deviceTimeZone)
            else { continue }
            return .flight(CalendarFlight(
                flight: flight, eventHash: event.externalIdentifier.map { eventHash($0, salt: salt) },
                locationConfirmsDeparture: locationConfirms(candidate.from, event: event, airports: airports)))
        }
        return .skipped(sawRoute ? .noFlightNumber : .noRoute)
    }

    /// HMAC-SHA256 of `identifier` under `salt`, as 64 lowercase hex.
    public static func eventHash(_ identifier: String, salt: SymmetricKey) -> String {
        let code = HMAC<SHA256>.authenticationCode(for: Data(identifier.utf8), using: salt)
        let digits = Array("0123456789abcdef")
        var hex = ""
        hex.reserveCapacity(64)
        // Bounded: 32 bytes.
        for byte in code {
            hex.append(digits[Int(byte >> 4)])
            hex.append(digits[Int(byte & 0x0F)])
        }
        return hex
    }

    // MARK: - Shapes

    /// What a recognizer found: a route of two known airports, whether there's a flight number, and the
    /// notes' local times where the shape has them.
    struct Candidate {
        let from: String
        let to: String
        let hasFlightNumber: Bool
        var localDeparture: LocalStamp?
        var localArrival: LocalStamp?
    }

    /// A wall-clock time with no zone.
    struct LocalStamp: Equatable {
        let year: Int, month: Int, day: Int, hour: Int, minute: Int

        func instant(in zone: TimeZone) -> Date? {
            FlightClock.instant(year: year, month: month, day: day, hour: hour, minute: minute, in: zone)
        }
    }

    static func candidate(_ shape: CalendarFlightShape, title: FlightText, notes: FlightText,
                          airports: some FlightAirportLookup) -> Candidate? {
        switch shape {
        case .outlookFromEmail:
            guard let route = notes.placeRoute(airports: airports) else { return nil }
            let number = title.hasFlightNumber(airports: airports) || notes.hasFlightNumber(airports: airports)
            return Candidate(from: route.from, to: route.to, hasFlightNumber: number,
                             localDeparture: notes.localStamp(after: "Departs at "),
                             localArrival: notes.localStamp(after: "Arrives at "))
        case .codesInTitle:
            guard let route = title.joinedRoute(airports: airports) ?? title.placeRoute(airports: airports)
            else { return nil }
            return Candidate(from: route.from, to: route.to, hasFlightNumber: title.hasFlightNumber(airports: airports))
        }
    }

    /// The flight's day and times (spec §10.4): the event's start and end are trusted as instants, a floating
    /// event's are read in the airports' zones, an all-day event gives the day only, and notes times more than
    /// ``crossCheckTolerance`` off mark the times unsure.
    static func flight(_ candidate: Candidate, event: CalendarFlightEvent, airports: some FlightAirportLookup,
                       deviceTimeZone: TimeZone) -> FlightRecord? {
        guard let fromZone = airports.timeZone(iata: candidate.from),
              let toZone = airports.timeZone(iata: candidate.to) else { return nil }
        if event.isAllDay {
            return FlightRecord(from: candidate.from, to: candidate.to, day: FlightDay(event.start, in: deviceTimeZone),
                                departure: nil, arrival: nil, timesUnsure: false)
        }
        let floating = event.timeZoneIdentifier == nil
        let start = floating ? FlightClock.rezoned(event.start, from: deviceTimeZone, to: fromZone) : event.start
        let end = floating ? FlightClock.rezoned(event.end, from: deviceTimeZone, to: toZone) : event.end
        guard let departure = start else { return nil }
        let checked = FlightClock.checked(departure: departure, arrival: end)
        var unsure = checked.unsure
        if let local = candidate.localDeparture {
            unsure = unsure || !agrees(local.instant(in: fromZone), departure)
        }
        if let local = candidate.localArrival, let arrival = checked.arrival {
            unsure = unsure || !agrees(local.instant(in: toZone), arrival)
        }
        return FlightRecord(from: candidate.from, to: candidate.to, day: FlightDay(departure, in: fromZone),
                            departure: departure, arrival: checked.arrival, timesUnsure: unsure)
    }

    private static func agrees(_ notes: Date?, _ event: Date) -> Bool {
        guard let notes else { return false }
        return abs(notes.timeIntervalSince(event)) <= crossCheckTolerance
    }

    /// Whether the event's location agrees with the departure airport.
    static func locationConfirms(_ code: String, event: CalendarFlightEvent, airports: some FlightAirportLookup) -> Bool {
        if let coordinate = event.locationCoordinate, coordinate.isValid, let point = airports.airportPoint(iata: code),
           coordinate.distance(to: point) <= locationConfirmRadius {
            return true
        }
        guard !event.location.isEmpty else { return false }
        if let name = airports.airportName(iata: code), !name.isEmpty,
           event.location.range(of: name, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
            return true
        }
        return FlightText(event.location).containsCode(code)
    }
}

/// A short text (a title, a location, the first 4 KB of notes) as characters, with the scans the shapes use.
nonisolated struct FlightText {
    let chars: [Character]

    init(_ text: String) {
        chars = Array(text)
    }

    // MARK: Codes

    /// The three-capital code starting at `index`, standing alone as a word, else nil.
    func code(at index: Int) -> String? {
        guard index >= 0, index + 3 <= chars.count else { return nil }
        // Bounded: three characters.
        for offset in 0..<3 where !Self.isCapital(chars[index + offset]) { return nil }
        if index > 0, Self.isWord(chars[index - 1]) { return nil }
        if index + 3 < chars.count, Self.isWord(chars[index + 3]) { return nil }
        return String(chars[index..<(index + 3)])
    }

    /// Whether `code` stands alone as a word anywhere here (used only to confirm, never to find).
    func containsCode(_ wanted: String) -> Bool {
        // Bounded: chars.count <= maxLocationBytes.
        for index in chars.indices where code(at: index) == wanted { return true }
        return false
    }

    /// Two known codes joined by an arrow, a dash, ">" or "to" ("PDX → HNL", "PDX-HNL", "PDX to HNL").
    func joinedRoute(airports: some FlightAirportLookup) -> (from: String, to: String)? {
        // Bounded: chars.count <= maxTitleBytes.
        for index in chars.indices {
            guard let from = code(at: index) else { continue }
            var cursor = skipSpaces(from: index + 3)
            guard cursor < chars.count else { return nil }
            if Self.isJoiner(chars[cursor]) {
                cursor += 1
                if chars[cursor - 1] == "-", cursor < chars.count, chars[cursor] == ">" { cursor += 1 }
            } else if cursor + 2 < chars.count, chars[cursor] == "t" || chars[cursor] == "T", chars[cursor + 1] == "o",
                      Self.isSpace(chars[cursor + 2]), cursor > index + 3 {
                cursor += 2
            } else {
                continue
            }
            cursor = skipSpaces(from: cursor)
            guard let to = code(at: cursor), to != from, airports.timeZone(iata: from) != nil,
                  airports.timeZone(iata: to) != nil else { continue }
            return (from, to)
        }
        return nil
    }

    /// "from <place> (ABC)" for the departure and "in <place> (DEF)" or "to <place> (DEF)" for the arrival,
    /// both known and different. A lone "(ABC)", with no pair, never makes a route.
    func placeRoute(airports: some FlightAirportLookup) -> (from: String, to: String)? {
        let from = placeCodes(after: ["from"]).first { airports.timeZone(iata: $0) != nil }
        guard let from else { return nil }
        let to = placeCodes(after: ["in", "to"]).first { $0 != from && airports.timeZone(iata: $0) != nil }
        guard let to else { return nil }
        return (from, to)
    }

    /// Every code written as "<word> <place> (ABC)" for one of `words`, in order (at most eight).
    func placeCodes(after words: [String]) -> [String] {
        var codes: [String] = []
        // Bounded: chars.count <= maxNotesBytes, and at most eight codes.
        for index in chars.indices where codes.count < 8 {
            guard let word = words.first(where: { isWord($0, at: index) }) else { continue }
            var cursor = index + word.count
            guard cursor < chars.count, Self.isSpace(chars[cursor]) else { continue }
            cursor += 1
            let placeStart = cursor
            // Bounded: at most maxPlaceCharacters steps.
            while cursor < chars.count, cursor - placeStart < CalendarFlightParser.maxPlaceCharacters,
                  !chars[cursor].isNewline, chars[cursor] != "(", chars[cursor] != ")" {
                cursor += 1
            }
            guard cursor < chars.count, chars[cursor] == "(", cursor - placeStart >= 2,
                  Self.isSpace(chars[cursor - 1]), let code = code(at: cursor + 1), cursor + 4 < chars.count,
                  chars[cursor + 4] == ")" else { continue }
            codes.append(code)
        }
        return codes
    }

    // MARK: Flight numbers

    /// "flight 812" (or "vuelo 812"), a carrier code with 1–4 digits ("CD812", "CD 812", "CDR812"), or an
    /// airline's name from the table with 1–4 digits ("Cedar Air 812"). Nothing found here leaves the reader.
    func hasFlightNumber(airports: some FlightAirportLookup) -> Bool {
        let words = self.words()
        // Bounded: words.count <= chars.count.
        for (position, word) in words.enumerated() {
            let text = String(chars[word])
            if Self.digitsOnly(text) {
                guard text.count <= 4, position > 0 else { continue }
                if followsFlightWord(position, words) || carrier(before: position, words: words, airports: airports) {
                    return true
                }
            } else if let split = Self.designatorSplit(text), split.digits.count <= 4,
                      Self.isCarrierCode(split.designator, airports: airports) {
                return true
            }
        }
        return false
    }

    /// Whether the number at `position` follows "flight" or "vuelo", maybe with "#" or "no.".
    private func followsFlightWord(_ position: Int, _ words: [Range<Int>]) -> Bool {
        let previous = words[position - 1]
        let word = String(chars[previous]).lowercased()
        if word == "flight" || word == "vuelo" {
            return spacesOnly(between: previous, and: words[position], allowing: ["#"])
        }
        guard word == "no", position > 1, spacesOnly(between: previous, and: words[position], allowing: [".", "#"]),
              spacesOnly(between: words[position - 2], and: previous, allowing: []) else { return false }
        let flightWord = String(chars[words[position - 2]]).lowercased()
        return flightWord == "flight" || flightWord == "vuelo"
    }

    /// Whether the words just before the number at `position` are a carrier: its code ("CD 812") or one to
    /// three words of an airline's name ("Cedar Air 812"), joined by spaces only.
    private func carrier(before position: Int, words: [Range<Int>], airports: some FlightAirportLookup) -> Bool {
        var right = words[position]
        var phrase = ""
        // Bounded: at most three words.
        for count in 1...3 {
            let index = position - count
            guard index >= 0 else { return false }
            let left = words[index]
            guard spacesOnly(between: left, and: right, allowing: []) else { return false }
            let word = String(chars[left])
            if count == 1, Self.isCarrierCode(word, airports: airports) { return true }
            phrase = count == 1 ? word : word + " " + phrase
            if let airline = airports.airline(named: phrase), airline.names.contains(where: {
                $0.compare(phrase, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            }) {
                return true
            }
            right = left
        }
        return false
    }

    /// The runs of letters and digits, as character ranges.
    private func words() -> [Range<Int>] {
        var runs: [Range<Int>] = []
        var start: Int?
        // Bounded: chars.count <= maxNotesBytes.
        for index in chars.indices {
            if Self.isWord(chars[index]) {
                if start == nil { start = index }
            } else if let first = start {
                runs.append(first..<index)
                start = nil
            }
        }
        if let first = start { runs.append(first..<chars.count) }
        return runs
    }

    /// Whether only spaces (or the `allowing` marks), at most three, sit between two words.
    private func spacesOnly(between left: Range<Int>, and right: Range<Int>, allowing marks: [Character]) -> Bool {
        guard left.upperBound <= right.lowerBound, right.lowerBound - left.upperBound <= 3 else { return false }
        // Bounded: at most three characters.
        for index in left.upperBound..<right.lowerBound where !Self.isSpace(chars[index]) && !marks.contains(chars[index]) {
            return false
        }
        return true
    }

    /// Whether the word `text` starts at `index`, ignoring case, standing alone.
    private func isWord(_ text: String, at index: Int) -> Bool {
        let word = Array(text)
        guard index + word.count <= chars.count else { return false }
        if index > 0, Self.isWord(chars[index - 1]) { return false }
        if index + word.count < chars.count, Self.isWord(chars[index + word.count]) { return false }
        // Bounded: word.count <= 4.
        for offset in word.indices where chars[index + offset].lowercased() != word[offset].lowercased() {
            return false
        }
        return true
    }

    /// A word written as a carrier code with digits: two capitals or digits with at least one capital
    /// ("CD812", "B6123"), or three capitals ("CDR812"), then the digits.
    static func designatorSplit(_ text: String) -> (designator: String, digits: String)? {
        let letters = Array(text)
        // Bounded: the two lengths a designator has.
        for length in [3, 2] where letters.count > length {
            let designator = letters[0..<length], digits = letters[length...]
            guard digitsOnly(String(digits)),
                  designator.allSatisfy({ isCapital($0) || ($0.isASCII && $0.isNumber) }),
                  designator.contains(where: isCapital),
                  length == 2 || designator.allSatisfy(isCapital) else { continue }
            return (String(designator), String(digits))
        }
        return nil
    }

    /// Whether `text`, written in capitals, is an airline's IATA or ICAO code in the table.
    static func isCarrierCode(_ text: String, airports: some FlightAirportLookup) -> Bool {
        guard text.count == 2 || text.count == 3, text.allSatisfy({ isCapital($0) || ($0.isASCII && $0.isNumber) }),
              text.contains(where: isCapital), let airline = airports.airline(named: text) else { return false }
        return airline.iata == text || airline.icao == text
    }

    // MARK: Local times

    /// The local time on the line starting with `lead` ("Departs at 9:05 AM on Thursday, March 12, 2026 …").
    func localStamp(after lead: String) -> CalendarFlightParser.LocalStamp? {
        let text = String(chars)
        guard let found = text.range(of: lead, options: .caseInsensitive) else { return nil }
        let line = text[found.upperBound...].prefix { !$0.isNewline }
        guard let on = line.range(of: " on ") else { return nil }
        guard let time = Self.clock(String(line[..<on.lowerBound])),
              let date = Self.date(String(line[on.upperBound...])) else { return nil }
        return CalendarFlightParser.LocalStamp(year: date.year, month: date.month, day: date.day,
                                               hour: time.hour, minute: time.minute)
    }

    /// "9:05 AM", "9:05pm", "9:05 a.m." or "21:05".
    static func clock(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.trimmingCharacters(in: .whitespaces).split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let hour = Int(parts[0]), (0...23).contains(hour) else { return nil }
        let rest = parts[1]
        let minuteText = rest.prefix(2)
        guard minuteText.count == 2, digitsOnly(String(minuteText)), let minute = Int(minuteText),
              minute < 60 else { return nil }
        let marker = rest.dropFirst(2).replacingOccurrences(of: ".", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
        switch marker {
        case "": return (hour, minute)
        case "am": return (1...12).contains(hour) ? (hour % 12, minute) : nil
        case "pm": return (1...12).contains(hour) ? (hour % 12 + 12, minute) : nil
        default: return nil
        }
    }

    /// "Thursday, March 12, 2026 from …" or "March 12, 2026": the first comma-separated piece that's a month
    /// and a day, then the year leading the next piece.
    static func date(_ text: String) -> (year: Int, month: Int, day: Int)? {
        let pieces = text.split(separator: ",", maxSplits: 3).map { $0.trimmingCharacters(in: .whitespaces) }
        // Bounded: at most four pieces.
        for (index, piece) in pieces.enumerated() where index + 1 < pieces.count {
            let words = piece.split(separator: " ")
            guard words.count == 2, let month = month(String(words[0])), let day = Int(words[1]) else { continue }
            let yearText = pieces[index + 1].prefix(4)
            guard yearText.count == 4, digitsOnly(String(yearText)), let year = Int(yearText),
                  FlightDay(year: year, month: month, day: day) != nil else { return nil }
            return (year, month, day)
        }
        return nil
    }

    private static let months = ["january", "february", "march", "april", "may", "june", "july", "august",
                                 "september", "october", "november", "december"]

    /// An English month, in full or its first three letters.
    private static func month(_ text: String) -> Int? {
        let word = text.lowercased().replacingOccurrences(of: ".", with: "")
        guard word.count >= 3 else { return nil }
        return months.firstIndex { $0 == word || ($0.hasPrefix(word) && word.count == 3) }.map { $0 + 1 }
    }

    // MARK: Characters

    private func skipSpaces(from index: Int) -> Int {
        var cursor = index
        // Bounded: at most three spaces.
        while cursor < chars.count, cursor - index < 3, Self.isSpace(chars[cursor]) { cursor += 1 }
        return cursor
    }

    static func isCapital(_ character: Character) -> Bool {
        guard let ascii = character.asciiValue, character.unicodeScalars.count == 1 else { return false }
        return (65...90).contains(ascii)
    }

    static func isWord(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func isSpace(_ character: Character) -> Bool {
        character == " " || character == "\u{00A0}" || character == "\t"
    }

    static func digitsOnly(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isASCII && $0.isNumber }
    }

    /// An arrow, a dash, ">" or a plane between two codes.
    static func isJoiner(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        return [0x2192, 0x2794, 0x279D, 0x27F6, 0x2708, 0x2D, 0x2013, 0x2014, 0x3E].contains(scalar.value)
    }
}
