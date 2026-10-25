import Foundation

/// What a place the person marked as their own base is (`ref-home-set`, owner-approved 2026-10-25).
///
/// Frozen tokens: the raw values are written in the places file's device side.
public nonisolated enum HomeKind: String, Codable, CaseIterable, Sendable {
    /// One of up to two homes: Sprout's house stands there.
    case home
    /// The hotel of the current stay (one at a time), or one remembered for a welcome back.
    case hotel
}

/// A home or a hotel the person marked (`ref-home-set`): their own name for it and the point they chose on
/// the map. Nothing of Apple's: the person picks the spot and the name (World build round 6; the MapKit
/// terms keep at most a reference, and a home keeps none).
///
/// Frozen at rest: `id`, `kind`, `label` and `point` are field names of the places file's device side.
public nonisolated struct HomePlace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var kind: HomeKind
    /// The person's name for it ("Home" until they change it; a hotel's name).
    public var label: String
    /// Where it is, as the person set the pin.
    public var point: GeoPoint

    /// A home or hotel `label` at `point`.
    public init(id: UUID = UUID(), kind: HomeKind, label: String, point: GeoPoint) {
        self.id = id
        self.kind = kind
        self.label = PlaceRecord.validLabel(label) ?? ""
        self.point = point
    }
}

/// What Sprout says once, the next time the map shows the person still there (`ref-home-arrive`,
/// `ref-hotel`). Frozen tokens.
public nonisolated enum HomeGreetingKind: String, Codable, Sendable {
    /// Back home after at least an hour away: "You're home! Long day?" and the rotating lines.
    case cameHome
    /// Checking in at a hotel for the first time: "Ooh, a hotel! I'll unpack."
    case hotelFirst
    /// Checking in again at a hotel stayed at before: "Welcome back to the Ace!"
    case hotelAgain
}

/// A greeting waiting for the map: what kind, and where (the home's or hotel's id).
public nonisolated struct HomeGreeting: Codable, Equatable, Sendable {
    public let kind: HomeGreetingKind
    public let placeID: UUID
    /// Which of the rotating welcome-home lines (0 is "You're home! Long day?").
    public let line: Int

    /// A greeting of `kind` at `placeID`.
    public init(kind: HomeGreetingKind, placeID: UUID, line: Int = 0) {
        self.kind = kind
        self.placeID = placeID
        self.line = line
    }
}

/// Where the person was last seen relative to their homes and hotel, so leaving and getting back can be
/// told (`ref-home-arrive`, `ref-home-where`). Kept only on the device side, never dated beyond the last
/// leave and the last sighting.
///
/// Frozen at rest: the field names.
public nonisolated struct HomePresence: Codable, Equatable, Sendable {
    /// The home or hotel the person was last seen at; nil when last seen away.
    public var atID: UUID?
    /// When the person was last seen there.
    public var lastSeenAt: Date?
    /// When the person left the home they were last at (nil while home, or before any leave was seen).
    public var leftAt: Date?
    /// The home they left.
    public var leftID: UUID?
    /// The greeting the map shows next, once.
    public var greeting: HomeGreeting?
    /// How many returns home were greeted (rotates the lines).
    public var returns: Int

    /// Nothing seen yet.
    public static let unknown = HomePresence(atID: nil, lastSeenAt: nil, leftAt: nil, leftID: nil, greeting: nil, returns: 0)
}

/// A leave or a return the presence rules noticed, for the timeline (`ref-home-where`).
public nonisolated struct HomeMove: Equatable, Sendable {
    /// Left (true) or got back (false).
    public let left: Bool
    /// The home's or hotel's id.
    public let placeID: UUID
    /// When.
    public let at: Date

    /// A leave (`left`) or a return at `placeID`, at `at`.
    public init(left: Bool, placeID: UUID, at: Date) {
        self.left = left
        self.placeID = placeID
        self.at = at
    }
}

/// The person's homes and hotel (owner, 2026-10-25, `ref-home-*`, `ref-hotel`): up to two homes, one hotel
/// at a time, the hotels stayed at before (for a welcome back), and where the person was last seen.
///
/// Each home and the current hotel uncovers the map for ``uncoverRadius`` around it (drawn, never written
/// into the fog, so removing one fogs its circle again except where the person has actually been). Getting
/// home ends a hotel stay; a hotel left is remembered in ``pastHotels``.
///
/// Kept in the places file's device side (`PlaceDeviceState/homes`), sealed on this iPhone: never synced,
/// backed up, exported, shared, given to the AI or sent anywhere; a decoy reads and writes none of it; every
/// wipe and an app-lock reset delete it. Plain values, so the rules are tested without a vault.
///
/// Frozen at rest: `homes`, `hotel`, `pastHotels` and `presence` are field names.
public nonisolated struct HomeBook: Codable, Equatable, Sendable {
    /// The most homes (owner: "Limit the number of homes to 2").
    public static let maxHomes = 2
    /// The most hotels remembered for a welcome back.
    public static let maxPastHotels = 30
    /// How far around a home or the hotel the map is uncovered, in metres.
    public static let uncoverRadius = 1_000.0
    /// How near a reading must be to count as being there, in metres.
    public static let atRadius = 120.0
    /// How long away before getting home is greeted.
    public static let greetingAway: TimeInterval = 60 * 60
    /// How near a new hotel must be to one stayed at before to be the same hotel, in metres.
    public static let sameHotelRadius = 150.0
    /// How many welcome-home lines rotate.
    public static let greetingLines = 3
    /// No homes, no hotel.
    public static let empty = HomeBook(homes: [], hotel: nil, pastHotels: [], presence: .unknown)

    public var homes: [HomePlace]
    /// The current stay, if any.
    public var hotel: HomePlace?
    /// Hotels stayed at before, newest first.
    public var pastHotels: [HomePlace]
    public var presence: HomePresence

    /// A book of `homes`, the current `hotel`, `pastHotels` and the last `presence`.
    public init(homes: [HomePlace], hotel: HomePlace?, pastHotels: [HomePlace], presence: HomePresence) {
        self.homes = Array(homes.prefix(Self.maxHomes))
        self.hotel = hotel
        self.pastHotels = Array(pastHotels.prefix(Self.maxPastHotels))
        self.presence = presence
    }

    /// The homes and the current hotel: what stands on the map and uncovers it.
    public var bases: [HomePlace] { homes + (hotel.map { [$0] } ?? []) }

    /// The home or current hotel within ``atRadius`` of `point`, nearest first.
    public func base(near point: GeoPoint) -> HomePlace? {
        bases.map { (place: $0, metres: $0.point.distance(to: point)) }
            .filter { $0.metres <= Self.atRadius }
            .min { $0.metres < $1.metres }?.place
    }

    /// The home or hotel with `id`, current or past.
    public func place(_ id: UUID) -> HomePlace? {
        (bases + pastHotels).first { $0.id == id }
    }

    /// Whether `point` is at a home or a hotel, current or stayed at before: such a place is never counted
    /// in Places you return to (`ref-home-where`).
    public func isHomeOrHotel(_ point: GeoPoint) -> Bool {
        (bases + pastHotels).contains { $0.point.distance(to: point) <= Self.atRadius }
    }

    // MARK: Setting them

    /// This book with `home` saved: an existing home (same id) moved or renamed, else added, replacing the
    /// home `replacing` when two are kept already (a third asks which to replace). Unchanged when two homes
    /// are kept and none is named to replace.
    public func savingHome(_ home: HomePlace, replacing: UUID? = nil) -> HomeBook {
        var next = self
        var saved = home
        saved.kind = .home
        if let index = next.homes.firstIndex(where: { $0.id == saved.id }) {
            next.homes[index] = saved
            return next
        }
        if let replacing { next.homes.removeAll { $0.id == replacing } }
        guard next.homes.count < Self.maxHomes else { return self }
        next.homes.append(saved)
        return next
    }

    /// This book with a stay at `hotel` begun (`ref-hotel`): the hotel before it is remembered, and the
    /// greeting is a welcome back when a hotel stayed at before is within ``sameHotelRadius`` (it takes that
    /// hotel's place in the past list), else the first-visit line. Renaming or moving the current hotel
    /// (same id) only changes it.
    public func checkingIn(_ hotel: HomePlace) -> HomeBook {
        var stay = hotel
        stay.kind = .hotel
        var next = self
        if next.hotel?.id == stay.id {
            next.hotel = stay
            return next
        }
        if let current = next.hotel { next.pastHotels.insert(current, at: 0) }
        let before = next.pastHotels.first { $0.point.distance(to: stay.point) <= Self.sameHotelRadius }
        next.pastHotels.removeAll { $0.id == before?.id }
        next.pastHotels = Array(next.pastHotels.prefix(Self.maxPastHotels))
        next.hotel = stay
        // Shown once the map sees the person there (``takingGreeting()``).
        next.presence.greeting = HomeGreeting(kind: before == nil ? .hotelFirst : .hotelAgain, placeID: stay.id)
        return next
    }

    /// This book with the stay ended (Check out, or getting home): the hotel is remembered for a welcome back.
    public var checkedOut: HomeBook {
        guard let hotel else { return self }
        var next = self
        next.pastHotels.insert(hotel, at: 0)
        next.pastHotels = Array(next.pastHotels.prefix(Self.maxPastHotels))
        next.hotel = nil
        if next.presence.atID == hotel.id { next.presence.atID = nil }
        if next.presence.greeting?.placeID == hotel.id { next.presence.greeting = nil }
        return next
    }

    /// This book without the home or hotel `id` (current or remembered): it is forgotten, not remembered.
    public func removing(_ id: UUID) -> HomeBook {
        var next = self
        next.homes.removeAll { $0.id == id }
        if next.hotel?.id == id { next.hotel = nil }
        next.pastHotels.removeAll { $0.id == id }
        if next.presence.atID == id { next.presence.atID = nil }
        if next.presence.leftID == id { next.presence.leftID = nil }
        if next.presence.greeting?.placeID == id { next.presence.greeting = nil }
        return next
    }
}

extension HomeBook {
    // MARK: Leaving and getting back

    /// This book after the person was seen at `point` at `date` (a reading while the map is open, or one of
    /// iOS's low-power visits, which also says when they `departed`), and the leaves and returns noticed.
    ///
    /// - Seen at a home or the hotel after being seen away: a return. Getting home after ``greetingAway`` or
    ///   more away (counted from the last sighting there) leaves a greeting for the map, once; getting home
    ///   also ends a hotel stay.
    /// - Seen away after being seen at one: a leave, dated at the last sighting there (the person left some
    ///   time after it; a visit's own departure is used when iOS gives one).
    public func observing(_ point: GeoPoint, at date: Date, departed: Date? = nil) -> (book: HomeBook, moves: [HomeMove]) {
        var next = self
        var moves: [HomeMove] = []
        if let here = base(near: point) {
            // Straight from one home or hotel to another: leave the first, then arrive.
            if let was = next.presence.atID, was != here.id { moves += next.leaving(at: next.presence.lastSeenAt ?? date) }
            if next.presence.atID != here.id { moves += next.arriving(at: here, date: date) }
            next.presence.atID = here.id
            next.presence.lastSeenAt = max(date, next.presence.lastSeenAt ?? date)
            guard let departed else { return (next, moves) }
            moves += next.leaving(at: departed)
            return (next, moves)
        }
        guard next.presence.atID != nil else { return (next, moves) }
        moves += next.leaving(at: next.presence.lastSeenAt ?? date)
        return (next, moves)
    }

    /// Arriving at `here` at `date`: a return, a greeting when it is a home after long enough away, and
    /// the end of a hotel stay when it is a home.
    private mutating func arriving(at here: HomePlace, date: Date) -> [HomeMove] {
        let isHome = homes.contains { $0.id == here.id }
        if isHome, let leftAt = presence.leftAt, date.timeIntervalSince(leftAt) >= Self.greetingAway {
            presence.greeting = HomeGreeting(kind: .cameHome, placeID: here.id, line: presence.returns % Self.greetingLines)
            presence.returns += 1
        }
        let cameBack = presence.leftID == here.id
        presence.leftAt = nil
        presence.leftID = nil
        if isHome, hotel != nil { self = checkedOut }
        return cameBack ? [HomeMove(left: false, placeID: here.id, at: date)] : []
    }

    /// Leaving the place the person was at, at `date`: the leave is remembered for the return's greeting.
    private mutating func leaving(at date: Date) -> [HomeMove] {
        guard let was = presence.atID else { return [] }
        presence.atID = nil
        presence.leftAt = date
        presence.leftID = was
        if presence.greeting?.placeID == was { presence.greeting = nil }
        return [HomeMove(left: true, placeID: was, at: date)]
    }

    /// The greeting waiting for the map while the person is still at its place, and this book without it.
    public func takingGreeting() -> (book: HomeBook, greeting: HomeGreeting?) {
        guard let greeting = presence.greeting, presence.atID == greeting.placeID else { return (self, nil) }
        var next = self
        next.presence.greeting = nil
        return (next, greeting)
    }
}
