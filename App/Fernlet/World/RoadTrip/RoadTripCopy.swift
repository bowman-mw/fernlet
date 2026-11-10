import FernletDomainModel
import Foundation

/// The road trip's words (World-RoadTrip-Spec §2, owner-approved 2026-11-10: `rt-home`, `rt-info`), keyed in the app's
/// catalog. The chip, its VoiceOver label, Trip info's rows and its four buttons are the approved copy verbatim; the
/// default name ("Road trip" and the date) follows `rt-start`; the two confirmations before Leave and End are drawn
/// from the approved buttons' own notes ("map and photos so far stay", "ends it for everyone at their next
/// catch-up").
nonisolated enum RoadTripCopy {
    static let title = LocalizedStringResource(
        "roadTrip.title", defaultValue: "Road trip",
        comment: "World Home: a road trip with friends; the chip's VoiceOver label with no other names, and Voice Control's short name for it")
    static let catchUpNow = LocalizedStringResource(
        "roadTrip.catchUpNow", defaultValue: "Catch up now",
        comment: "Trip info: swaps the road and photos with another member nearby with Fernlet open")
    static let mapFromHere = LocalizedStringResource(
        "roadTrip.mapFromHere", defaultValue: "Map from this iPhone",
        comment: "Trip info: this iPhone takes over mapping the road")
    static let leave = LocalizedStringResource(
        "roadTrip.leave", defaultValue: "Leave the road trip",
        comment: "Trip info: destructive button; this person leaves the road trip, and the map and photos so far stay")
    static let end = LocalizedStringResource(
        "roadTrip.end", defaultValue: "End the road trip",
        comment: "Trip info: destructive button; ends the road trip for everyone at their next catch-up")
    static let leaveTitle = LocalizedStringResource(
        "roadTrip.leave.title", defaultValue: "Leave the road trip?",
        comment: "Trip info: the confirmation before leaving the road trip")
    static let leaveMessage = LocalizedStringResource(
        "roadTrip.leave.message", defaultValue: "The map and photos so far stay.",
        comment: "Trip info: the leave confirmation's message; what was uncovered and the trip photos stay on this iPhone")
    static let endTitle = LocalizedStringResource(
        "roadTrip.end.title", defaultValue: "End the road trip?",
        comment: "Trip info: the confirmation before ending the road trip")
    static let endMessage = LocalizedStringResource(
        "roadTrip.end.message", defaultValue: "It ends for everyone at their next catch-up.",
        comment: "Trip info: the end confirmation's message; the other members' phones end it when they next catch up")

    /// "Road trip · 3": the chip under the status plate, with how many people are on the trip, this one included.
    static func chip(members: Int) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.chip", defaultValue: "Road trip · \(members)",
                                comment: "World Home: the chip under the status plate during a road trip; how many people are on it, you included")
    }

    /// "Road trip with Rae and Sam".
    static func with(_ names: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.with", defaultValue: "Road trip with \(names)",
                                comment: "World Home, VoiceOver: the road trip chip; the other people's first names joined, e.g. 'Rae and Sam'")
    }

    /// "Road trip · Nov 10": a trip given no name.
    static func defaultName(_ day: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.defaultName", defaultValue: "Road trip · \(day)",
                                comment: "Trip info's title for a road trip given no name: 'Road trip' and the day it started, e.g. 'Nov 10'")
    }

    /// "Mapping: Mike's iPhone".
    static func mapping(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.info.mapping", defaultValue: "Mapping: \(name)'s iPhone",
                                comment: "Trip info: whose iPhone maps the road now; their first name")
    }

    /// "Last caught up 2:14 pm".
    static func caughtUp(_ time: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.info.caughtUp", defaultValue: "Last caught up \(time)",
                                comment: "Trip info: when this iPhone last caught up with the others (the start, before any stop); a time, or a day and time")
    }

    /// "6 photos".
    static func photos(_ count: Int) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.info.photos", defaultValue: "\(count) photos",
                                comment: "Trip info: the photos taken on the road trip so far. Plural on the number")
    }

    /// What VoiceOver reads for the chip: "Road trip with Rae and Sam" (the list in the reader's language), or "Road
    /// trip" with no one else on it.
    static func spokenChip(others: [String]) -> String {
        let names = Array(others.prefix(RoadTrip.maxMembers))
        guard !names.isEmpty else { return AddressedCopy.plain(title) }
        return AddressedCopy.plain(with(names.formatted(.list(type: .and))))
    }

    /// The trip's name: the person's own, or "Road trip" and the day it started.
    static func name(of trip: RoadTrip) -> String {
        if let name = trip.name, !name.isEmpty { return name }
        return AddressedCopy.plain(defaultName(trip.startedAt.formatted(.dateTime.month(.abbreviated).day())))
    }

    /// When the trip last caught up, as Trip info says it: the time on the same day as `now`, else the day and time.
    static func caughtUpTime(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
        guard !calendar.isDate(date, inSameDayAs: now) else { return date.formatted(date: .omitted, time: .shortened) }
        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    /// The road so far as the person's region writes a road distance, to the whole unit ("84 km", "52 mi").
    static func distance(_ metres: Double) -> String {
        Measurement(value: max(0, metres.isFinite ? metres : 0), unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}
