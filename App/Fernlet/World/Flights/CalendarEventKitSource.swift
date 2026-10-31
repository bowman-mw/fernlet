import EventKit
import Foundation
import WorldMapStore

/// The calendar through EventKit (World-Airports-Spec §10.2–§10.6): the only file in the app that imports it
/// (`CalendarFlightsBoundaryTests`).
///
/// - **Asking** is iOS 17's `requestFullAccessToEvents()`; iOS gives a reading app only full access. The usage
///   string is `NSCalendarsFullAccessUsageDescription`.
/// - **Reading only.** Nothing here saves, changes or removes an event, and no event's URL, attendees,
///   organizer or calendar is read. A title goes through the caller's first pass before the event's location,
///   notes (cut to the first 4 KB by ``CalendarFlightEvent``) and times are read; the structured location's
///   coordinate is never read (the location's text alone confirms a departure, and the file needs no
///   CoreLocation).
/// - **Changes** come as ``changedNotification`` (`EKEventStoreChanged`), posted while this source is alive.
///
/// `@unchecked Sendable`: the only state is the `let` event store, which EventKit lets any thread query; the
/// reads run off the main actor.
nonisolated final class EventKitCalendarSource: CalendarEventSource, @unchecked Sendable {
    /// Posted when the calendar database changes (another app, a sync, iOS Settings).
    static let changedNotification = Notification.Name.EKEventStoreChanged

    private let store = EKEventStore()

    func access() -> CalendarAccess {
        Self.currentAccess()
    }

    /// Where iOS stands on Fernlet's calendar access, without making an event store.
    static func currentAccess() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: .allowed
        case .notDetermined: .notAsked
        case .denied, .restricted, .writeOnly: .refused
        @unknown default: .refused
        }
    }

    func requestAccess() async -> CalendarAccess {
        do {
            _ = try await store.requestFullAccessToEvents()
        } catch {
            return .refused
        }
        return access()
    }

    func events(in interval: DateInterval, limit: Int, mightBeFlight: (String) -> Bool) -> CalendarEventBatch {
        guard access() == .allowed, limit > 0 else { return CalendarEventBatch(events: [], looked: 0) }
        let predicate = store.predicateForEvents(withStart: interval.start, end: interval.end, calendars: nil)
        let all = store.events(matching: predicate)
        var events: [CalendarFlightEvent] = []
        // Bounded: at most `limit` events looked at.
        for event in all.prefix(limit) {
            guard let title = event.title, mightBeFlight(title), let start = event.startDate,
                  let end = event.endDate else { continue }
            events.append(CalendarFlightEvent(title: title, location: event.location, notes: event.notes, start: start,
                                              end: end, isAllDay: event.isAllDay,
                                              timeZoneIdentifier: event.timeZone?.identifier, locationCoordinate: nil,
                                              externalIdentifier: event.calendarItemExternalIdentifier))
        }
        return CalendarEventBatch(events: events, looked: min(all.count, limit))
    }
}
