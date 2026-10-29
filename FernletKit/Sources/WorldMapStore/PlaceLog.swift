import Foundation

/// The everyday places "Where you've been" may name and count (owner, 2026-10-22: an allowlist, never a
/// blocklist): food and drink, gyms, parks, beaches and campgrounds. Anything else is never named or kept;
/// doctors, lawyers and therapists least of all.
///
/// A capture-time value only: the device decides with it and keeps none of it (World build round 5, the
/// MapKit terms); a place's kind is asked for again with its name when the person looks. The raw values are
/// frozen tokens; ``PlaceCategory`` names nothing a person reads.
public nonisolated enum PlaceCategory: String, Codable, CaseIterable, Sendable {
    case foodAndDrink
    case gym
    case park
    case beach
    case campground

    /// Whether a person stands inside it rather than at its door: a park, a beach, a campground.
    public var isArea: Bool {
        switch self {
        case .park, .beach, .campground: true
        case .foodAndDrink, .gym: false
        }
    }
}

/// One point of interest near a spot, as a lookup reported it, kept only for the moment of the decision
/// (the MapKit terms allow no store of Apple's place data): its name, what kind of place it is in
/// Fernlet's own terms, how far it is from the person, and the lookup's own reference to it when it gave
/// one. Of all of it, only the reference may outlive the decision: a place the person returns to keeps it,
/// so its name can be asked for again when the person looks (World build round 5).
public nonisolated struct NearbyPlace: Equatable, Sendable {
    /// What kind of place it is, decided on the device from the lookup's category.
    public enum Kind: Equatable, Sendable {
        /// One of the everyday kinds Fernlet may name.
        case allowed(PlaceCategory)
        /// A place Fernlet never names or keeps: medical, legal or therapy.
        case refused
        /// An outdoor feature a park, beach or campground holds or stands beside (a lake, a restroom, a bike
        /// dock, a playground, a trail, a court; World build round 6, owner: "No park features should be
        /// fine. Why block it?"). It never decides a stop on its own: inside or beside a park, beach or
        /// campground area the area keeps the visit; anywhere else nothing is kept.
        case feature
        /// Anything else (a shop, a station, an office with a category of its own).
        case other
    }

    /// The place's name as the lookup gave it: read for the refused words, never kept.
    public let name: String
    public let kind: Kind
    /// How far it is from the person, in metres.
    public let metres: Double
    /// The lookup's persistent reference to the place (Apple's `MKMapItem.Identifier` raw value), or nil
    /// when it gave none. Opaque to Fernlet: it names nothing until it is resolved again.
    public let placeID: String?

    /// A place `name` of `kind`, `metres` away, with the lookup's `placeID` when it gave a usable one.
    public init(name: String, kind: Kind, metres: Double, placeID: String? = nil) {
        self.name = name
        self.kind = kind
        self.metres = metres
        self.placeID = placeID.flatMap(PlaceRecord.validPlaceID)
    }
}

/// What the device decided about where the person is, from the places a lookup found around them. The
/// decision is all that outlives the lookup: an allowed place keeps only the lookup's reference to it, never
/// its name or its kind (World build round 5, the MapKit terms).
public nonisolated enum PlaceVerdict: Equatable, Sendable {
    /// At an everyday place, with the lookup's reference to it when it gave one.
    case allowed(placeID: String?)
    /// At, or right beside, a place Fernlet never names or keeps.
    case refused
    /// Nowhere Fernlet names.
    case unnamed
}

/// The device's rules for keeping a visit and keeping a photo's place (owner, 2026-10-24: "agree with your
/// take on the doctors / lawyers office"; World build step 5c and round 5). Plain values, so the rules are
/// tested without a lookup.
///
/// - **A visit** is kept only at the nearest place within ``visitRadius``, and only when that nearest place
///   is one of the allowed kinds and its name reads as none of the refused ones. When the nearest place is
///   a refused one, the visit is refused even if a café stands next door. With nothing that near, or with
///   only a park's own feature that near (a lake, a restroom, a bike dock, a playground; round 6), a park,
///   beach or campground within ``areaRadius`` keeps it (the person is inside it, far from its one point),
///   unless a refused place is within ``areaRefuseRadius``. A feature with no park, beach or campground
///   around it keeps nothing: what can't be identified outside a park area is still never kept.
/// - **A solo photo** keeps its point only where a visit would be kept (owner, round 5): at an everyday
///   place, or inside a park, beach or campground. Anywhere else, and with no lookup answer at all
///   (offline), it keeps no place.
///
/// The name check catches what the lookup's categories can't: Apple's categories have hospitals and
/// pharmacies but no doctors' offices, lawyers or therapists, so a name such as "Riverside Family Clinic"
/// or "Ortiz Law Office" is refused by its words. A place a lookup doesn't list at all can't be recognised;
/// that is why both rules are allowlists: they keep nothing they can't place.
public nonisolated enum PlaceClassifier {
    /// How near the nearest place must be for a visit to be there, in metres.
    public static let visitRadius = 50.0

    /// Words (lowercased, without accents) that mark a place as medical, legal or therapy, in English and
    /// Spanish. A false match only drops a visit or a photo's place, never keeps one.
    static let refusedWords: [String] = [
        "clinic", "clinica", "medical", "medico", "medica", "hospital", "doctor", "dentist", "dental",
        "orthodont", "pediatric", "pediatr", "physician", "urgent care", "health center", "health centre",
        "centro de salud", "pharmacy", "farmacia", "therap", "terapi", "terapeut", "counsel", "psych", "psiqu",
        "psico", "mental health", "salud mental", "rehab", "planned parenthood", "gynec", "ginec", "obgyn",
        "fertility", "fertilidad", "abortion", "aborto", "oncolog", "cancer", "chiropract", "quiropract",
        "physio", "fisioter", "optometr", "dermatolog", "cardiolog", "radiolog", "laborator", "lawyer",
        "attorney", "law office", "law firm", "law group", "legal aid", "abogad", "bufete", "notari",
        "immigration", "inmigracion", "courthouse", "juzgado", "tribunal", "bail bond",
    ]

    /// How far a park, beach or campground's own point may be when nothing else is near: the person can
    /// stand well inside one, far from the single point a lookup gives it, in metres.
    public static let areaRadius = 300.0
    /// With nothing within ``visitRadius``, how near a refused place still refuses the visit, in metres.
    public static let areaRefuseRadius = 80.0

    /// What a visit at a spot with `nearby` places around it is.
    public static func visitVerdict(_ nearby: [NearbyPlace]) -> PlaceVerdict {
        decide(nearby).verdict
    }

    /// The place to eat a visit at a spot with `nearby` places around it is at, by Apple's reference, or nil
    /// (World build round 6, "Remember places I eat out"): only when the visit would be kept and the place
    /// it is kept at is food and drink, and only with a reference. Decided at the moment and never stored as
    /// a kind: what is kept is the meals logged there.
    public static func eatingPlaceID(_ nearby: [NearbyPlace]) -> String? {
        let decision = decide(nearby)
        guard decision.category == .foodAndDrink, case .allowed(let placeID) = decision.verdict else { return nil }
        return placeID
    }

    /// The verdict, and the allowed place's kind when the verdict is allowed.
    private static func decide(_ nearby: [NearbyPlace]) -> (verdict: PlaceVerdict, category: PlaceCategory?) {
        let measured = nearby.filter { $0.metres.isFinite && $0.metres >= 0 }.sorted { $0.metres < $1.metres }
        guard let nearest = measured.first, nearest.metres <= visitRadius else { return areaVerdict(measured) }
        if isRefused(nearest) { return (.refused, nil) }
        // A park's own feature (round 6): the park around it decides, as if nothing stood that near.
        if nearest.kind == .feature { return areaVerdict(measured) }
        guard case .allowed(let category) = nearest.kind else { return (.unnamed, nil) }
        return named(nearest, category)
    }

    /// Nothing within ``visitRadius``: the nearest park, beach or campground within ``areaRadius``, unless a
    /// refused place is within ``areaRefuseRadius``.
    private static func areaVerdict(_ measured: [NearbyPlace]) -> (verdict: PlaceVerdict, category: PlaceCategory?) {
        if measured.contains(where: { $0.metres <= areaRefuseRadius && isRefused($0) }) { return (.refused, nil) }
        for place in measured where place.metres <= areaRadius && !isRefused(place) {
            guard case .allowed(let category) = place.kind, category.isArea else { continue }
            return named(place, category)
        }
        return (.unnamed, nil)
    }

    /// The allowed verdict for `place` (of an allowed `category`), or unnamed when it has no name: a
    /// nameless place can't be read for the refused words.
    private static func named(_ place: NearbyPlace, _ category: PlaceCategory) -> (verdict: PlaceVerdict, category: PlaceCategory?) {
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? (.unnamed, nil) : (.allowed(placeID: place.placeID), category)
    }

    /// Whether a solo photo taken where `nearby` was found may keep its point: only where a visit would be
    /// kept (an everyday place, or inside a park, beach or campground), never with no answer (nil).
    public static func photoMayKeepPlace(_ nearby: [NearbyPlace]?) -> Bool {
        guard let nearby, case .allowed = visitVerdict(nearby) else { return false }
        return true
    }

    /// Whether `place` is one Fernlet never names or keeps: by its kind, or by the words in its name.
    public static func isRefused(_ place: NearbyPlace) -> Bool {
        if place.kind == .refused { return true }
        let folded = place.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return refusedWords.contains { folded.contains($0) }
    }
}

/// A place the person returns to, in "Where you've been" (`b2-where-been`): the point the person stood at
/// (Fernlet's own reading, never Apple's), the lookup's reference to the place when it gave one, the
/// person's own name for it once they rename it, and how many times they've been. A count, never dates
/// (owner, 2026-10-22).
///
/// Nothing of Apple's answer is kept but the reference (World build round 5: Apple's terms let a place's
/// identifier be kept, and its data be cached only for a while). The name shown is asked for again by that
/// reference each time the person looks and is held in memory only; with no answer (offline) or no
/// reference the place shows under the person's own name, or as "A place you return to".
///
/// Frozen at rest: `id`, `label`, `placeID`, `point` and `visits` are field names of the sealed log. A
/// record from the first format (which held the lookup's `name` and a `category`) reads with both dropped:
/// that format never marked which names the person gave, so none of its names can be kept.
public nonisolated struct PlaceRecord: Codable, Equatable, Identifiable, Sendable {
    /// The longest name kept.
    public static let maxNameLength = 80
    /// The longest reference kept (Apple's identifiers are far shorter).
    public static let maxPlaceIDLength = 256

    public let id: UUID
    /// The person's own name for the place, once they rename it; nil until then.
    public var label: String?
    /// The lookup's reference to the place, or nil when it gave none.
    public let placeID: String?
    /// Where the person stood on the first visit.
    public let point: GeoPoint
    /// How many visits it has had.
    public var visits: Int

    /// A place record.
    public init(id: UUID = UUID(), label: String? = nil, placeID: String? = nil, point: GeoPoint, visits: Int = 0) {
        self.id = id
        self.label = label.flatMap(Self.validLabel)
        self.placeID = placeID.flatMap(Self.validPlaceID)
        self.point = point
        self.visits = visits
    }

    /// `label` trimmed and capped at ``maxNameLength``, or nil when nothing is left.
    public static func validLabel(_ label: String) -> String? {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : String(trimmed.prefix(maxNameLength))
    }

    /// `placeID` when it is a usable reference (not empty, at most ``maxPlaceIDLength``), else nil.
    public static func validPlaceID(_ placeID: String) -> String? {
        placeID.isEmpty || placeID.count > maxPlaceIDLength ? nil : placeID
    }
}

/// One entry on the 30-day timeline: a stop at a place, a walk or run the person recorded, or a bike ride
/// Fernlet logged.
///
/// Frozen at rest: the field names and ``Kind``'s raw values. A kind this build doesn't know (written by a
/// newer one, then read back from a restore) can't be read; the logs that hold stops skip such a stop
/// rather than fail whole (`LossyStops`).
public nonisolated struct PlaceStop: Codable, Equatable, Identifiable, Sendable {
    /// What the stop was.
    public enum Kind: String, Codable, Sendable {
        case visit
        case walk
        case run
        /// A bike ride Fernlet logged (Refinements group 19, `ref-ride-timeline`): `at` is when it started,
        /// `metres` its distance when known, `workoutID` its cycling workout. Added in round 7.
        case ride
        /// The person left a home or their hotel (round 6, `ref-home-where`: "Home · you left").
        case leftHome
        /// The person got back to it ("Home · you got back").
        case cameHome
    }

    public let id: UUID
    public let kind: Kind
    /// When it began.
    public let at: Date
    /// The place visited (``PlaceRecord/id``), for a visit; the home or hotel (``HomePlace/id``) for a
    /// leave or a return.
    public let placeID: UUID?
    /// A walk's, run's or ride's length, in metres (nil for a ride whose distance is unknown).
    public let metres: Double?
    /// The walk's, run's or ride's workout, whose saved line (if any) the day's map draws.
    public let workoutID: UUID?

    /// Whether it is an outing the person made (a walk, a run or a bike ride), with a workout and a line.
    public var isOuting: Bool {
        switch kind {
        case .walk, .run, .ride: true
        case .visit, .leftHome, .cameHome: false
        }
    }

    /// Whether this stop and `other` are visits to the same place within
    /// ``PlaceDeviceState/sameVisitWindow`` of each other: one visit, noted twice.
    public func isSameVisit(as other: PlaceStop) -> Bool {
        kind == .visit && other.kind == .visit && placeID != nil && placeID == other.placeID
            && abs(at.timeIntervalSince(other.at)) < PlaceDeviceState.sameVisitWindow
    }

    /// A stop.
    public init(id: UUID = UUID(), kind: Kind, at: Date, placeID: UUID? = nil, metres: Double? = nil, workoutID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.at = at
        self.placeID = placeID
        self.metres = metres
        self.workoutID = workoutID
    }
}

/// An allowed place's point and the lookup's reference to it, without any name: what background visits are
/// matched against while Private is closed, and what a new lookup's answer is matched against by reference
/// (a park can be entered far from where it was first visited).
///
/// Frozen at rest: the field names. A first-format entry (which held a `category`) reads with it dropped.
public nonisolated struct KnownPlace: Codable, Equatable, Sendable {
    public let id: UUID
    public let point: GeoPoint
    /// The lookup's reference to the place, or nil.
    public let placeID: String?

    /// A known place.
    public init(id: UUID, point: GeoPoint, placeID: String? = nil) {
        self.id = id
        self.point = point
        self.placeID = placeID
    }
}

/// A sealed list of timeline stops read one by one (Refinements group 19): a stop this build can't read (a
/// kind a newer build wrote, then restored here) is skipped, never failing the whole log with it. Bounded:
/// at most ``maxRead`` entries are looked at, well over either log's own cap.
nonisolated struct LossyStops: Decodable {
    /// The most entries one list is read for.
    static let maxRead = 10_000

    /// The stops that could be read, in their order.
    let stops: [PlaceStop]

    /// Reads each entry as a stop, stepping over one that isn't (the unkeyed container moves on only when
    /// an entry is read, so a skipped one is read as ``Skipped``).
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var read: [PlaceStop] = []
        for _ in 0..<min(container.count ?? Self.maxRead, Self.maxRead) {
            guard !container.isAtEnd else { break }
            if let stop = try? container.decode(PlaceStop.self) {
                read.append(stop)
            } else {
                _ = try container.decode(Skipped.self)
            }
        }
        stops = read
    }

    /// Any one entry, read as nothing.
    private struct Skipped: Decodable {
        /// Reads nothing of the entry.
        init(from decoder: any Decoder) throws {}
    }
}
