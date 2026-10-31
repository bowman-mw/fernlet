import CryptoKit
import Foundation
import WorldMapStore

/// Whether Fernlet may read the calendar (World-Airports-Spec §10.2): iOS gives a reading app only full access.
nonisolated enum CalendarAccess: Sendable, Equatable {
    /// Full access: events can be read.
    case allowed
    /// iOS hasn't asked yet.
    case notAsked
    /// Don't Allow, taken away later in iOS Settings, write-only, or restricted: nothing is read.
    case refused
}

/// What one read of the calendar handed over: the events whose titles might be flights (the cheap first pass,
/// spec §10.6), as plain values, and how many events were looked at in all (each counts toward the look's cap).
nonisolated struct CalendarEventBatch: Sendable {
    let events: [CalendarFlightEvent]
    let looked: Int
}

/// Where calendar events come from: EventKit in the app (`EventKitCalendarSource`, the only file that imports
/// it), made-up events in tests. Read-only by design: there is no way to write, change or delete an event, and an
/// event's links, attendees and calendar name are never handed over.
nonisolated protocol CalendarEventSource: Sendable {
    /// Whether events can be read now.
    func access() -> CalendarAccess
    /// Asks iOS for full access (iOS shows its prompt once; after that it answers at once) and says where it
    /// stands afterwards.
    func requestAccess() async -> CalendarAccess
    /// The events overlapping `interval` (at most four years long), at most `limit` looked at: each one's title
    /// goes through `mightBeFlight` first, and only those that pass have their location, notes and times read.
    /// Nothing without full access.
    func events(in interval: DateInterval, limit: Int, mightBeFlight: (String) -> Bool) -> CalendarEventBatch
}

/// Reads a window of the calendar as flights (World-Airports-Spec §10.5, §10.6), off the main actor: the window
/// in pieces of at most four years (``CalendarFlightLook/chunks(of:)``), at most
/// ``CalendarFlightLook/maxEvents`` events looked at in all, each title through the parser's first pass before
/// anything else of it is read.
nonisolated enum CalendarFlightReader {
    /// The look over `window` from `source`, read with `airports` and hashed under `salt`.
    static func look(_ source: any CalendarEventSource, window: DateInterval, airports: any FlightAirportLookup,
                     salt: SymmetricKey, now: Date, deviceTimeZone: TimeZone = .current) -> CalendarFlightLook {
        var events: [CalendarFlightEvent] = [], budget = CalendarFlightLook.maxEvents
        // Bounded: at most CalendarFlightLook.maxChunks pieces, and maxEvents events in all.
        for piece in CalendarFlightLook.chunks(of: window) where budget > 0 {
            let batch = source.events(in: piece, limit: budget) { title in
                CalendarFlightParser.mightBeFlight(title: title, airports: airports)
            }
            budget -= batch.looked
            events += batch.events.prefix(max(CalendarFlightLook.maxEvents - events.count, 0))
        }
        return CalendarFlightLook(events: events, airports: airports, salt: salt, now: now, deviceTimeZone: deviceTimeZone)
    }
}
