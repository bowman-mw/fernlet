import CryptoKit
import Foundation
import Testing
import WorldMapStore

extension CalendarFlightReading {
    /// The flight read, or nil where the event was skipped.
    nonisolated var found: CalendarFlight? {
        if case .flight(let flight) = self { return flight }
        return nil
    }
}

/// Reading calendar events as flights (World-Airports-Spec §10.3–§10.4). Every event is made up in the shape
/// of Outlook's "added from email" event: Cedar Air flight 812 from Portland to Honolulu, its booking code a
/// made-up K7QX2M and its link an example.invalid address.
@MainActor
struct CalendarFlightParserTests {
    static let title = "Cedar Air flight 812 to Honolulu (K7QX2M)"
    static let location = "Portland International Airport (Portland, Oregon, United States)"
    static let notes = """
        Cedar Air flight 812 (5 hours, 40 minutes)
        Confirmation code: K7QX2M

        Check in online<https://example.invalid/checkin>

        Departs at 9:05 AM on Thursday, March 12, 2026 from Portland (PDX)

        Arrives at 11:45 AM on Thursday, March 12, 2026 in Honolulu (HNL)

        Showing airport local time.

        This event was automatically added to your calendar from email by Outlook.
        """
    static let salt = SymmetricKey(data: Data(repeating: 7, count: 32))
    static let pacific = TimeZone(identifier: "America/Los_Angeles") ?? .gmt

    /// An event; by default the Outlook one, 09:05 PDT to 11:45 HST (14:45 PDT) on 12 March 2026.
    static func event(title: String = title, location: String? = location, notes: String? = notes,
                      start: String = "2026-03-12T16:05:00Z", end: String = "2026-03-12T21:45:00Z",
                      isAllDay: Bool = false, zone: String? = "America/Los_Angeles", coordinate: GeoPoint? = nil,
                      id: String? = "event-1") throws -> CalendarFlightEvent {
        CalendarFlightEvent(title: title, location: location, notes: notes, start: flightUTC(start),
                            end: flightUTC(end), isAllDay: isAllDay, timeZoneIdentifier: zone,
                            locationCoordinate: coordinate, externalIdentifier: id)
    }

    static func read(_ event: CalendarFlightEvent, device: TimeZone = pacific) -> CalendarFlightReading {
        CalendarFlightParser.read(event, airports: FlightTestAirports(), salt: salt, deviceTimeZone: device)
    }

    /// The Outlook shape reads as Portland to Honolulu, its instants trusted, the notes' local times agreeing,
    /// the location confirming the departure and the event's ID kept only as a salted hash.
    @Test func outlookShape() throws {
        let found = try #require(Self.read(try Self.event()).found)
        #expect(found.flight.from == "PDX" && found.flight.to == "HNL")
        #expect(found.flight.day == FlightDay(year: 2026, month: 3, day: 12))
        #expect(found.flight.departure == flightUTC("2026-03-12T16:05:00Z"))
        #expect(found.flight.arrival == flightUTC("2026-03-12T21:45:00Z"))
        #expect(!found.flight.timesUnsure)
        #expect(found.locationConfirmsDeparture)
        #expect(found.eventHash == CalendarFlightParser.eventHash("event-1", salt: Self.salt))
    }

    /// Nothing from the event's text comes out: not the booking code, the link, the airline, the number or
    /// the notes.
    @Test func nothingButTheFlightComesOut() throws {
        let found = try #require(Self.read(try Self.event()).found)
        let shown = String(describing: found)
        for secret in ["K7QX2M", "example.invalid", "Cedar", "Outlook", "Honolulu", "Portland", "Confirmation", "event-1"] {
            #expect(!shown.contains(secret), "\(secret) leaked")
        }
        #expect(!String(describing: found.flight).contains("812"))
    }

    /// The title's parenthesis holds the booking code and never names an airport, even one shaped like a code.
    @Test func bookingCodeNeverAnAirport() throws {
        let bare = try Self.event(title: "Cedar Air flight 812 to London (LHR)", notes: nil)
        #expect(Self.read(bare) == .skipped(.noRoute))
        let codeShaped = try Self.event(title: "Cedar Air flight 812 to Honolulu (SEAHNL)",
                                        notes: Self.notes.replacingOccurrences(of: "K7QX2M", with: "SEAHNL"))
        let found = try #require(Self.read(codeShaped).found)
        #expect(found.flight.from == "PDX" && found.flight.to == "HNL")
    }

    /// A bare three-capital word is never an airport, though EDT, USA and THE are real codes.
    @Test func bareCodesIgnored() throws {
        #expect(Self.read(try Self.event(title: "Cedar Air flight 812 USA EDT THE", notes: nil)) == .skipped(.noRoute))
        #expect(Self.read(try Self.event(title: "Cedar Air flight 812, USA, EDT", notes: "USA\nEDT\nTHE (USA)"))
                == .skipped(.noRoute))
        #expect(Self.read(try Self.event(title: "Call with the USA team, 9 AM EDT", notes: nil)) == .skipped(.notAFlight))
    }

    /// A city alone, or the location alone, never makes a route.
    @Test func cityOnlyRejected() throws {
        let event = try Self.event(title: "Cedar Air flight 812 to Honolulu", notes: "Flying to Honolulu from Portland")
        #expect(Self.read(event) == .skipped(.noRoute))
    }

    /// A route with no flight number isn't a flight.
    @Test func flightNumberRequired() throws {
        #expect(Self.read(try Self.event(title: "PDX → HNL", notes: nil)) == .skipped(.noFlightNumber))
        #expect(Self.read(try Self.event(title: "Holiday PDX to HNL", notes: nil)) == .skipped(.noFlightNumber))
        #expect(Self.read(try Self.event(title: "Room 101 PDX-HNL", notes: nil)) == .skipped(.noFlightNumber))
        let outlookNoNumber = Self.notes.replacingOccurrences(of: "Cedar Air flight 812 (5 hours, 40 minutes)\n", with: "")
        #expect(Self.read(try Self.event(title: "Flight to Honolulu (K7QX2M)", notes: outlookNoNumber))
                == .skipped(.noFlightNumber))
    }

    /// The generic title shape: two codes joined by an arrow, a dash or "to", with a carrier and number.
    @Test func codesInTitle() throws {
        let titles = ["CD 812 PDX → HNL", "CD812 PDX-HNL", "Cedar Air 812: PDX to HNL", "CDR812 PDX->HNL",
                      "Flight 812 PDX – HNL", "Flight #812 PDX→HNL", "Cedar Airlines 812 PDX > HNL"]
        for title in titles {
            let found = Self.read(try Self.event(title: title, location: nil, notes: nil)).found
            #expect(found?.flight.from == "PDX" && found?.flight.to == "HNL", "\(title)")
            #expect(found?.flight.timesUnsure == false, "\(title)")
            #expect(found?.locationConfirmsDeparture == false, "\(title)")
        }
    }

    /// Notes times more than five minutes off the event's mark the times unsure; the event's instants stay.
    @Test func mismatchMarksTimesUnsure() throws {
        let lateEnd = try #require(Self.read(try Self.event(end: "2026-03-12T20:45:00Z")).found)
        #expect(lateEnd.flight.timesUnsure, "13:45 PDT is 10:45 in Honolulu, not 11:45")
        #expect(lateEnd.flight.arrival == flightUTC("2026-03-12T20:45:00Z"))
        let lateStart = try #require(Self.read(try Self.event(start: "2026-03-12T16:15:00Z")).found)
        #expect(lateStart.flight.timesUnsure)
        let withinTolerance = try #require(Self.read(try Self.event(start: "2026-03-12T16:09:00Z")).found)
        #expect(!withinTolerance.flight.timesUnsure)
        let backwards = try #require(Self.read(try Self.event(end: "2026-03-12T15:00:00Z")).found)
        #expect(backwards.flight.arrival == nil && backwards.flight.timesUnsure)
    }

    /// A floating event's wall-clock times are read in the airports' zones, whatever zone the phone is in.
    @Test func floatingEventReadInAirportZones() throws {
        let eastern = try #require(TimeZone(identifier: "America/New_York"))
        let event = try Self.event(start: "2026-03-12T13:05:00Z", end: "2026-03-12T15:45:00Z", zone: nil)
        let found = try #require(Self.read(event, device: eastern).found)
        #expect(found.flight.departure == flightUTC("2026-03-12T16:05:00Z"), "09:05 in Portland")
        #expect(found.flight.arrival == flightUTC("2026-03-12T21:45:00Z"), "11:45 in Honolulu")
        #expect(!found.flight.timesUnsure)
    }

    /// An all-day event gives the day only.
    @Test func allDayGivesTheDay() throws {
        let event = try Self.event(start: "2026-03-12T07:00:00Z", end: "2026-03-13T07:00:00Z", isAllDay: true, zone: nil)
        let found = try #require(Self.read(event).found)
        #expect(found.flight.day == FlightDay(year: 2026, month: 3, day: 12))
        #expect(found.flight.departure == nil && found.flight.arrival == nil && !found.flight.timesUnsure)
    }

    /// The event hash is HMAC-SHA256 as 64 lowercase hex: stable for one salt, different for another, and
    /// absent with no identifier.
    @Test func saltedHash() throws {
        let known = CalendarFlightParser.eventHash("The quick brown fox jumps over the lazy dog",
                                                   salt: SymmetricKey(data: Data("key".utf8)))
        #expect(known == "f7bc83f430538424b13298e6aa6fb143ef4d59a14946175997479dbc2d1a3cd8")
        let first = CalendarFlightParser.eventHash("event-1", salt: Self.salt)
        #expect(first == CalendarFlightParser.eventHash("event-1", salt: Self.salt))
        #expect(first != CalendarFlightParser.eventHash("event-1", salt: SymmetricKey(data: Data(repeating: 8, count: 32))))
        #expect(first != CalendarFlightParser.eventHash("event-2", salt: Self.salt))
        #expect(first.count == 64 && first.allSatisfy { "0123456789abcdef".contains($0) })
        #expect(Self.read(try Self.event(id: nil)).found?.eventHash == nil)
    }

    /// The cheap first pass looks at the title alone.
    @Test func firstPass() {
        let airports = FlightTestAirports()
        for title in [Self.title, "PDX → HNL", "CD 812", "Cedar Air 812", "✈️ Honolulu", "Vuelo a Honolulu"] {
            #expect(CalendarFlightParser.mightBeFlight(title: title, airports: airports), "\(title)")
        }
        for title in ["Dentist", "Call with the USA team, 9 AM EDT", "Room 101", "Walk to the park"] {
            #expect(!CalendarFlightParser.mightBeFlight(title: title, airports: airports), "\(title)")
        }
    }

    /// Only the notes' first 4 KB are read: a route past them isn't found.
    @Test func notesCappedAt4KB() throws {
        let event = try Self.event(notes: String(repeating: "x", count: 4_200) + "\n" + Self.notes)
        #expect(event.notes.utf8.count == CalendarFlightEvent.maxNotesBytes)
        #expect(Self.read(event) == .skipped(.noRoute))
    }

    /// The location only confirms: by its coordinate near the airport, its name or its code; a location
    /// elsewhere confirms nothing and changes nothing else.
    @Test func locationOnlyConfirms() throws {
        let elsewhere = try #require(Self.read(try Self.event(location: "Somewhere else")).found)
        #expect(!elsewhere.locationConfirmsDeparture && elsewhere.flight.from == "PDX")
        let near = try #require(Self.read(try Self.event(location: nil, coordinate: GeoPoint(45.59, -122.60))).found)
        #expect(near.locationConfirmsDeparture)
        let code = try #require(Self.read(try Self.event(location: "Gate C4 (PDX)")).found)
        #expect(code.locationConfirmsDeparture)
    }
}
