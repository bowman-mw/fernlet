import CryptoKit
import Foundation
import WorldMapStore

// The calendar's DEBUG screenshot hook (World-Airports-Spec §10.5, screen 28):
// `FERNLET_UI_TEST_CALENDAR_FLIGHTS=summary` opens the first look's summary sheet when Privacy & data's "Airports
// and flights" card appears, on a made-up look (a Portland traveller on Cedar Air, never anyone's calendar),
// planned against a made-up passport holding one of its flights from a Flighty file and one Fernlet saw. In memory
// only: nothing is read from the calendar and nothing is written unless "Add" is tapped. Absent in Release.

extension UITestSupport {
    #if DEBUG
    /// The calendar scene to show (`FERNLET_UI_TEST_CALENDAR_FLIGHTS`), or nil.
    static var calendarFlightsScene: String? { ProcessInfo.processInfo.environment["FERNLET_UI_TEST_CALENDAR_FLIGHTS"] }
    #else
    static var calendarFlightsScene: String? { nil }
    #endif
}

#if DEBUG
extension UITestSupport {
    /// The made-up first look for `summary`, or nil.
    @MainActor
    static var calendarFlightsDemo: CalendarFlightsFound? {
        guard calendarFlightsScene == "summary", let airports = WorldAirportsShelf().pack() else { return nil }
        return CalendarFlightsDemo.found(airports: airports, now: Date())
    }
}

/// The made-up events and passport behind the calendar's screenshot.
enum CalendarFlightsDemo {
    /// Cedar Air out of Portland: five flown, two upcoming, and one "flight" naming no airports.
    static func events(now: Date) -> [CalendarFlightEvent] {
        let flown: [(String, String, String)] = [
            ("Cedar Air flight 812 PDX → HNL", "2019-03-14T17:05:00Z", "2019-03-14T22:50:00Z"),
            ("Cedar Air flight 813 HNL → PDX", "2019-03-21T23:00:00Z", "2019-03-22T04:30:00Z"),
            ("Cedar Air flight 220 PDX → SEA", "2021-07-02T15:00:00Z", "2021-07-02T16:00:00Z"),
            ("Cedar Air flight 64 PDX → LHR", "2024-05-10T20:00:00Z", "2024-05-11T05:40:00Z"),
            ("Cedar Air flight 65 LHR → PDX", "2024-05-24T11:00:00Z", "2024-05-24T21:10:00Z"),
        ]
        var events = flown.compactMap { row -> CalendarFlightEvent? in
            let parse = ISO8601DateFormatter()
            guard let start = parse.date(from: row.1), let end = parse.date(from: row.2) else { return nil }
            return event(row.0, start: start, end: end)
        }
        let day: TimeInterval = 24 * 60 * 60
        events.append(event("Cedar Air flight 812 PDX → HNL", start: now.addingTimeInterval(10 * day),
                            end: now.addingTimeInterval(10 * day + 5.75 * 3_600)))
        events.append(event("Cedar Air flight 813 HNL → PDX", start: now.addingTimeInterval(17 * day),
                            end: now.addingTimeInterval(17 * day + 5.5 * 3_600)))
        events.append(event("Flight to Honolulu", start: now.addingTimeInterval(-90 * day),
                            end: now.addingTimeInterval(-90 * day + 3_600)))
        return events
    }

    /// The look, planned against a passport holding PDX → SEA from a Flighty file and LHR → PDX that Fernlet saw.
    static func found(airports: WorldAirports, now: Date) -> CalendarFlightsFound {
        let look = CalendarFlightLook(events: events(now: now), airports: airports,
                                      salt: SymmetricKey(data: Data(repeating: 1, count: 32)), now: now)
        var book = PassportBook()
        book.addFlights(look.flown.compactMap { (flight: PassportFlight) -> PassportFlight? in
            switch flight.route {
            case "PDX>SEA": PassportFlight(from: flight.from, to: flight.to, departure: flight.departure, sources: .flighty)
            case "LHR>PDX": PassportFlight(from: flight.from, to: flight.to, departure: flight.departure, sources: .fernlet)
            default: nil
            }
        })
        let held = look.alreadyHeld(in: book)
        return CalendarFlightsFound(look: look, plan: look.plan(against: book), fromFlighty: held.fromFlighty,
                                    fernletSaw: held.fernletSaw)
    }

    private static func event(_ title: String, start: Date, end: Date) -> CalendarFlightEvent {
        CalendarFlightEvent(title: title, location: nil, notes: nil, start: start, end: end, isAllDay: false,
                            timeZoneIdentifier: "America/Los_Angeles", locationCoordinate: nil,
                            externalIdentifier: "demo-\(title)-\(start.timeIntervalSince1970)")
    }
}
#endif
