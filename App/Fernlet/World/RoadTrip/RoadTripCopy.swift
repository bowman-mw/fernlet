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

    // MARK: PR 2 — Start, Join and the catch-up (`rt-start`, `rt-join`, `rt-catchup`), verbatim

    static let startRow = LocalizedStringResource(
        "roadTrip.start.row", defaultValue: "Start a road trip",
        comment: "The hangout's menu on Home: starts a road trip with the friends in this hangout")
    static let startLine = LocalizedStringResource(
        "roadTrip.start.line",
        defaultValue: "One phone maps the road while the others rest. At each stop, Fernlet catches everyone up: the road you drove together and the photos you took.",
        comment: "Start a road trip sheet: what a road trip does; 'you' is everyone on the trip")
    static let startButton = LocalizedStringResource(
        "roadTrip.start.button", defaultValue: "Start the road trip",
        comment: "Start a road trip sheet: starts it and asks each friend in the hangout to join")
    static let notNow = LocalizedStringResource(
        "roadTrip.start.notNow", defaultValue: "Not now",
        comment: "Start a road trip sheet: closes it; nothing starts")
    static let join = LocalizedStringResource(
        "roadTrip.join.button", defaultValue: "Join",
        comment: "A friend started a road trip: joins it")
    static let notThisTime = LocalizedStringResource(
        "roadTrip.join.notThisTime", defaultValue: "Not this time",
        comment: "A friend started a road trip: says no; the hangout stays as it was")
    static let catchUp = LocalizedStringResource(
        "roadTrip.catchUp.button", defaultValue: "Catch up",
        comment: "World Home's note when a road trip friend is nearby: opens a short hangout that swaps the road and photos")

    /// "Mike started a road trip".
    static func joinTitle(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.join.title", defaultValue: "\(name) started a road trip",
                                comment: "The join prompt's title: the first name of the friend who started the road trip")
    }

    /// "Join, and Fernlet shares the road you drive together and your trip photos with Mike and Sam, in person at each
    /// stop."
    static func joinLine(_ names: String) -> LocalizedStringResource {
        LocalizedStringResource(
            "roadTrip.join.line",
            defaultValue: "Join, and Fernlet shares the road you drive together and your trip photos with \(names), in person at each stop.",
            comment: "The join prompt's line: the other people on the trip, first names joined, e.g. 'Mike and Sam'")
    }

    /// "Rae is here. Catch up the road trip?".
    static func catchUpQuestion(_ name: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.catchUp.question", defaultValue: "\(name) is here. Catch up the road trip?",
                                comment: "World Home's note, asked once when a road trip friend is nearby with Fernlet open: their first name")
    }

    /// "Caught up: 84 km of road, 6 photos.".
    static func caughtUp(distance: String, photos: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.caughtUp", defaultValue: "Caught up: \(distance) of road, \(photos).",
                                comment: "World Home's note after a road trip catch-up: the trip's road on this iPhone (e.g. '84 km') and its photos (e.g. '6 photos')")
    }

    // MARK: PR 3 — Photos and the map (`rt-photos`, `rt-map`)

    /// "Road trip · 26 of 30": the camera's title on the trip roll, in the review page's style (`rt-photos`); the
    /// count is the photos left of the person's 30, as the camera's film badge counts.
    static func cameraTitle(left: Int, limit: Int) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.camera.title", defaultValue: "Road trip · \(left) of \(limit)",
                                comment: "The disposable camera during a road trip, its title: how many photos this person can still take on the trip, of 30, e.g. 'Road trip · 26 of 30'. Keep it short")
    }

    /// "26 of 30 photos left on the road trip": VoiceOver for the camera's film badge on the trip roll (new copy).
    static func cameraFilmSpoken(left: Int, limit: Int) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.camera.filmLeft", defaultValue: "\(left) of \(limit) photos left on the road trip",
                                comment: "The disposable camera during a road trip, VoiceOver for the film badge: photos this person can still take on the trip, of 30, e.g. '26 of 30 photos left on the road trip'")
    }

    /// "Hide from the map": the trip photo viewer's action, for any trip photo (new copy; `rt-photos`: "any one can be
    /// hidden later").
    static let hideFromMap = LocalizedStringResource(
        "roadTrip.photo.hide", defaultValue: "Hide from the map",
        comment: "A road trip photo opened from the map: takes this photo off the map; it stays on this iPhone")

    /// "Road trip to the coast · Nov 10 · Rae".
    static func photoCaption(_ trip: String, day: String, name: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.photo.caption", defaultValue: "\(trip) · \(day) · \(name)",
                                comment: "A road trip photo opened from the map, its caption: the trip's name (or 'Road trip'), the day the photo was taken (e.g. 'Nov 10') and the first name of who took it")
    }

    /// "Photo from Road trip to the coast, by Rae": VoiceOver for a photo of a trip with a name.
    static func photoSpokenNamed(_ trip: String, name: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.photo.spoken", defaultValue: "Photo from \(trip), by \(name)",
                                comment: "VoiceOver for a road trip photo opened from the map: the trip's own name (e.g. 'Road trip to the coast') and the first name of who took it")
    }

    /// "Photo from the road trip, by Rae": VoiceOver for a photo of a trip given no name.
    static func photoSpokenUnnamed(name: String) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.photo.spokenUnnamed", defaultValue: "Photo from the road trip, by \(name)",
                                comment: "VoiceOver for a road trip photo opened from the map, the trip given no name: the first name of who took it")
    }

    /// "Road trip photos here, 3": VoiceOver for a trip print on the map (new copy, after the solo print's "Your
    /// photos here, 3").
    static func markerSpoken(count: Int) -> LocalizedStringResource {
        LocalizedStringResource("roadTrip.marker.photos", defaultValue: "Road trip photos here, \(count)",
                                comment: "World Home, VoiceOver: a print with a car stamp on the map where road trip photos were taken; how many")
    }

    /// A trip photo's caption: its trip's name (or "Road trip" for one given none), the day it was taken and the
    /// first name of who took it (left out when the trip is no longer on this iPhone).
    static func photoCaption(trip: RoadTrip?, takenAt: Date, author: String?) -> String {
        let label = trip?.name.flatMap { $0.isEmpty ? nil : $0 } ?? AddressedCopy.plain(title)
        let day = takenAt.formatted(.dateTime.month(.abbreviated).day())
        guard let author else { return "\(label) · \(day)" }
        return AddressedCopy.plain(photoCaption(label, day: day, name: author))
    }

    /// What VoiceOver says for a trip photo: "Photo from Road trip to the coast, by Rae", or for a trip given no
    /// name "Photo from the road trip, by Rae"; the trip's name alone when who took it is not known.
    static func photoSpoken(trip: RoadTrip?, author: String?) -> String {
        let named = trip?.name.flatMap { $0.isEmpty ? nil : $0 }
        guard let author else { return named ?? AddressedCopy.plain(title) }
        guard let named else { return AddressedCopy.plain(photoSpokenUnnamed(name: author)) }
        return AddressedCopy.plain(photoSpokenNamed(named, name: author))
    }

    /// The Start sheet's title, "Road trip with Rae and Sam", and the join prompt's people, in the reader's language.
    static func names(_ names: [String]) -> String {
        Array(names.prefix(RoadTrip.maxMembers)).formatted(.list(type: .and))
    }

    /// "Caught up: 84 km of road, 6 photos." as one string, for the note and VoiceOver.
    static func caughtUpLine(_ note: RoadTripCaughtUpNote) -> String {
        AddressedCopy.plain(caughtUp(distance: distance(note.metres), photos: AddressedCopy.plain(photos(note.photos))))
    }

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
