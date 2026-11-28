import Foundation

// AmbientPlaces.swift
//
// The quiet-place gentle reminder (owner's picks P2-A, P3-B with the owner's note, P4-A; 2026-11-27):
// a place the person used to enjoy and hasn't been to in a while. Pure, with the clock injected. CAP-2:
// the places come in as `AmbientQuietPlace` values, built from Home's place summary by the one named
// reader (see AmbientReminders.swift); nothing here reads a store.
//
// Every kept kind counts, but restaurants and gyms are suggested less often than parks, beaches and
// campgrounds: they need twice the quiet days, they are offered only when no outdoor place qualifies,
// and at most once a quarter (`AmbientReminderMemory.indoorPlaceRested`). Their wording never mentions
// eating or exercise.

/// The everyday kind a quiet place is named by ("the park", "that restaurant"). Display only, never
/// stored: the app maps it from Home's place summary.
nonisolated enum AmbientPlaceKind: String, CaseIterable, Sendable {
    /// A park.
    case park
    /// A beach.
    case beach
    /// A campground.
    case campground
    /// A place to eat or drink.
    case restaurant
    /// A gym.
    case gym

    /// Whether it is an outdoor place (a park, a beach, a campground), suggested at the ordinary pace.
    var isOutdoor: Bool {
        switch self {
        case .park, .beach, .campground: true
        case .restaurant, .gym: false
        }
    }
}

/// One place from Home's place summary, as the quiet-place finder sees it.
nonisolated struct AmbientQuietPlace: Equatable, Sendable {
    /// The place's id in the summary (Fernlet's own), for a stable pick.
    let id: UUID
    /// The person's own name for the place, or nil.
    let label: String?
    /// Its kind, or nil while none is known.
    let kind: AmbientPlaceKind?
    /// The start of the day of the last visit.
    let lastVisitDay: Date
    /// The summary's 60-day visit count.
    let visits: Int

    /// Whether it is suggested at the ordinary pace: an outdoor kind. A restaurant, a gym, or a place
    /// known only by the person's name (whatever it is) is suggested less often.
    var isOutdoor: Bool { kind?.isOutdoor ?? false }

    /// Whether it can be named on a card: by the person's name, or by its kind.
    var isNameable: Bool { label != nil || kind != nil }
}

/// Finds the quiet place worth a card today. Pure: the clock and calendar are injected.
nonisolated enum AmbientQuietPlaceFinder {
    /// The visits (in the summary's 60-day count) that make a place one the person enjoyed.
    static let minimumVisits = 3
    /// How long a park, beach or campground must have been quiet.
    static let outdoorQuietDays = 30
    /// How long a restaurant, gym or name-only place must have been quiet (twice as long).
    static let indoorQuietDays = 60
    /// Past this, a place is no longer suggested (the person may well have moved on).
    static let maxQuietDays = 365
    /// How long after a restaurant or gym card another one may be offered.
    static let indoorRestDays = 90
    /// The most places looked at (Where you've been's own cap).
    static let maxPlaces = 300

    /// The quiet-place reminder for today, or nil. Outdoor places come first; a restaurant, gym or
    /// name-only place only when no outdoor one qualifies and `indoorAllowed` (its quarter has passed).
    /// Among the eligible: the most visits, then the most recent last visit, then the id.
    static func reminder(_ places: [AmbientQuietPlace], indoorAllowed: Bool, now: Date,
                         calendar: Calendar = .current) -> AmbientReminder? {
        let today = calendar.startOfDay(for: now)
        let eligible = places.prefix(maxPlaces).filter { place in
            guard place.isNameable, place.visits >= minimumVisits else { return false }
            let quiet = calendar.dateComponents([.day], from: place.lastVisitDay, to: today).day ?? 0
            let needed = place.isOutdoor ? outdoorQuietDays : indoorQuietDays
            return quiet >= needed && quiet <= maxQuietDays
        }
        let outdoor = eligible.filter(\.isOutdoor)
        let pool = !outdoor.isEmpty ? outdoor : (indoorAllowed ? eligible : [])
        guard let pick = pool.max(by: isLessLikely) else { return nil }
        return AmbientReminder(kind: .quietPlace, subject: .place(label: pick.label, kind: pick.kind))
    }

    /// The pick order: fewer visits first, then an older last visit, then the larger id.
    private static func isLessLikely(_ lhs: AmbientQuietPlace, _ rhs: AmbientQuietPlace) -> Bool {
        if lhs.visits != rhs.visits { return lhs.visits < rhs.visits }
        if lhs.lastVisitDay != rhs.lastVisitDay { return lhs.lastVisitDay < rhs.lastVisitDay }
        return lhs.id.uuidString > rhs.id.uuidString
    }

    /// Whether `reminder` names a place suggested less often (a restaurant, a gym, or a name-only place),
    /// so the card's quarter starts when it shows.
    static func isIndoor(_ reminder: AmbientReminder) -> Bool {
        guard case .place(_, let kind) = reminder.subject else { return false }
        return !(kind?.isOutdoor ?? false)
    }
}
