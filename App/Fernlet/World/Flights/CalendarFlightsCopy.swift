import Foundation
import WorldMapStore

/// The words of the "Airports and flights" switch and Flights from Calendar (World-Airports-Spec §10, §11; the
/// approved page's copy, screens 13 and 25–28; Spanish drafts in `r7-airports-ui-es-calendar.json`).
nonisolated enum CalendarFlightsCopy {
    // MARK: The switch (13)

    /// "Airports and flights" (the switch's name; the card's title is the same words).
    static let airportsSwitch = LocalizedStringResource("Airports and flights",
                                                        comment: "Privacy & data: the switch that keeps airport stamps and flights")
    static let airportsSwitchSub = LocalizedStringResource("Airport stamps, flights and layovers, kept on this iPhone and only in the passport's sealed backup. Never shared.",
                                                           comment: "Privacy & data: the line under the Airports and flights switch")
    /// The question after the switch goes off.
    static let forgetTitle = LocalizedStringResource("Delete the airports and flights kept?",
                                                     comment: "Privacy & data: asked after Airports and flights is turned off")
    static let forgetBody = LocalizedStringResource("Airport stamps, layovers and flights leave your passport. Countries and everything else stay.",
                                                    comment: "Privacy & data: what deleting the kept airports and flights does")
    static let forgetConfirm = LocalizedStringResource("Delete", comment: "Privacy & data: deletes the kept airports and flights")
    static let forgetKeep = LocalizedStringResource("Keep them", comment: "Privacy & data: keeps the airports and flights already kept")
    /// "Deleted 12 airports and flights" (announced).
    static func forgotten(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("Deleted \(count) airports and flights",
                                comment: "VoiceOver: announced after the kept airports and flights were deleted; their number")
    }

    // MARK: Flights from Calendar (25, 26, 30)

    static let calendarSwitch = LocalizedStringResource("Flights from Calendar",
                                                        comment: "Privacy & data: the switch that finds flights in the calendar")
    static let calendarSwitchSub = LocalizedStringResource("Finds flight events and fills in arcs, the Flights page and your tickets. Off until you turn it on.",
                                                           comment: "Privacy & data: the line under Flights from Calendar")
    /// The note while it's on (spec §10.6, a draft for review).
    static let calendarOnNote = LocalizedStringResource("Turn off Calendar access in iOS Settings → Fernlet too, if you like.",
                                                        comment: "Privacy & data: the note under Flights from Calendar while it's on")
    /// The note after Don't Allow, or once access was taken away (spec §10.2).
    static let calendarRefusedNote = LocalizedStringResource("Fernlet can't read your calendar. To allow it, go to iOS Settings → Fernlet → Calendars, then turn this on again.",
                                                             comment: "Privacy & data: the note under Flights from Calendar when calendar access isn't allowed")
    /// While the first look runs.
    static let looking = LocalizedStringResource("Looking through your calendar…",
                                                 comment: "Privacy & data: shown while Fernlet looks through the calendar for flights")

    // MARK: The first look back (28)

    static let sheetTitle = LocalizedStringResource("Flights in your calendar", comment: "Airports: the calendar look's summary sheet's title")
    /// "Looked back to 2019".
    static func lookedBackTo(_ year: Int) -> LocalizedStringResource {
        let year = String(year)
        return LocalizedStringResource("Looked back to \(year)", comment: "Airports: the calendar summary's subtitle; the first year read")
    }
    static let tileUpcoming = LocalizedStringResource("upcoming", comment: "Airports: the calendar summary tile under the number of upcoming flights")
    /// "Found 23 flights, 14 airports, 2 upcoming, 2019 to 2026" (the tiles, for VoiceOver).
    static func foundLabel(flights: Int, airports: Int, upcoming: Int, years: ClosedRange<Int>?) -> LocalizedStringResource {
        guard let years else {
            return LocalizedStringResource("Found no flights", comment: "VoiceOver: the import summary when the file held no flights")
        }
        let first = String(years.lowerBound), last = String(years.upperBound)
        return LocalizedStringResource("Found \(flights) flights, \(airports) airports, \(upcoming) upcoming, \(first) to \(last)",
                                       comment: "VoiceOver: the calendar summary's tiles: flights, airports, upcoming flights, first and last year")
    }
    /// "3 flight events with no airport codes".
    static func noAirportCodes(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flight events with no airport codes",
                                comment: "Airports: calendar events that look like flights but name no airports, skipped")
    }
    /// "9 from your Flighty file and 2 Fernlet saw: same day, from and to, kept once", or one half alone.
    static func alreadyHeld(fromFlighty: Int, fernletSaw: Int) -> LocalizedStringResource? {
        switch (fromFlighty > 0, fernletSaw > 0) {
        case (true, true):
            LocalizedStringResource("\(fromFlighty) from your Flighty file and \(fernletSaw) Fernlet saw: same day, from and to, kept once",
                                    comment: "Airports: calendar flights the passport already holds, from a Flighty file and from Fernlet")
        case (true, false):
            LocalizedStringResource("\(fromFlighty) from your Flighty file: same day, from and to, kept once",
                                    comment: "Airports: calendar flights the passport already holds from a Flighty file")
        case (false, true):
            LocalizedStringResource("\(fernletSaw) Fernlet saw: same day, from and to, kept once",
                                    comment: "Airports: calendar flights the passport already holds because Fernlet saw them")
        case (false, false):
            nil
        }
    }
    static let upcomingTitle = LocalizedStringResource("Upcoming", comment: "Airports: the calendar summary's heading for flights still to come")
    /// "2 flights. They'll fill in your ticket on the day."
    static func upcoming(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("\(count) flights. They'll fill in your ticket on the day.",
                                comment: "Airports: the calendar's upcoming flights, kept for their day")
    }
    static let lockNotice = LocalizedStringResource("Read on this iPhone. Fernlet keeps each flight's date, airports and times, and never changes your calendar.",
                                                    comment: "Airports: the calendar summary's privacy notice")
    /// "Added 23 flights from your calendar" (the inline note after adding; Undo beside it).
    static func added(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("Added \(count) flights from your calendar",
                                comment: "Airports: shown after the calendar's past flights were added; Undo beside it")
    }

    // MARK: Problems

    static let problemTitle = LocalizedStringResource("Couldn't look in your calendar",
                                                      comment: "Airports: the alert's title when the calendar couldn't be read")

    /// The alert's message for `problem`.
    static func message(_ problem: CalendarLookProblem) -> LocalizedStringResource {
        switch problem {
        case .switchedOff:
            LocalizedStringResource("Turn on Airports and flights in Privacy & data first.",
                                    comment: "Airports: the calendar can't be read while Airports and flights is off")
        case .notAllowed:
            calendarRefusedNote
        case .noAirportList:
            LocalizedStringResource("Fernlet's airport list is missing from this copy of the app.",
                                    comment: "Airports: the bundled airport list couldn't be opened")
        case .passportClosed:
            LocalizedStringResource("The passport can't be opened right now. Unlock your iPhone and try again.",
                                    comment: "Airports: the passport couldn't be read or saved")
        }
    }
}
