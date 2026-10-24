import Foundation

/// The everyday places "Where you've been" may name and count (owner, 2026-10-22: an allowlist, never a
/// blocklist): food and drink, gyms, parks, beaches and campgrounds. Anything else is never named or kept;
/// doctors, lawyers and therapists least of all.
///
/// The raw values are frozen tokens (sealed at rest); ``PlaceCategory`` names nothing a person reads.
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
/// Fernlet's own terms, and how far it is from the person.
public nonisolated struct NearbyPlace: Equatable, Sendable {
    /// What kind of place it is, decided on the device from the lookup's category.
    public enum Kind: Equatable, Sendable {
        /// One of the everyday kinds Fernlet may name.
        case allowed(PlaceCategory)
        /// A place Fernlet never names or keeps: medical, legal or therapy.
        case refused
        /// Anything else (a shop, a station, an office with no category).
        case other
    }

    /// The place's name as the lookup gave it.
    public let name: String
    public let kind: Kind
    /// How far it is from the person, in metres.
    public let metres: Double

    /// A place `name` of `kind`, `metres` away.
    public init(name: String, kind: Kind, metres: Double) {
        self.name = name
        self.kind = kind
        self.metres = metres
    }
}

/// What the device decided about where the person is, from the places a lookup found around them.
public nonisolated enum PlaceVerdict: Equatable, Sendable {
    /// At an everyday place: its kind and the name it starts with (the person can rename it).
    case allowed(PlaceCategory, name: String)
    /// At, or right beside, a place Fernlet never names or keeps.
    case refused
    /// Nowhere Fernlet names.
    case unnamed
}

/// The device's rules for naming a place and keeping a photo's place (owner, 2026-10-24: "agree with your
/// take on the doctors / lawyers office"; World build step 5c). Plain values, so the rules are tested
/// without a lookup.
///
/// - **A visit** names only the nearest place within ``visitRadius``, and only when that nearest place is
///   one of the allowed kinds and its name reads as none of the refused ones. When the nearest place is a
///   refused one, the visit is refused even if a café stands next door. With nothing that near, a park,
///   beach or campground within ``areaRadius`` names it (the person is inside it, far from its one point),
///   unless a refused place is within ``areaRefuseRadius``.
/// - **A solo photo** keeps its point unless a refused place is within ``photoRefuseRadius``, by kind or by
///   name. With no lookup answer at all (offline) the photo keeps no place: a refused place can't be ruled
///   out.
///
/// The name check catches what the lookup's categories can't: Apple's categories have hospitals and
/// pharmacies but no doctors' offices, lawyers or therapists, so a name such as "Riverside Family Clinic"
/// or "Ortiz Law Office" is refused by its words. A place a lookup doesn't list at all can't be recognised;
/// that is the rule's known limit, and why a visit (an allowlist) names nothing it can't place.
public nonisolated enum PlaceClassifier {
    /// How near the nearest place must be for a visit to be there, in metres.
    public static let visitRadius = 50.0
    /// How near a refused place must be for a photo to keep no place, in metres.
    public static let photoRefuseRadius = 60.0

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
        let measured = nearby.filter { $0.metres.isFinite && $0.metres >= 0 }.sorted { $0.metres < $1.metres }
        guard let nearest = measured.first, nearest.metres <= visitRadius else { return areaVerdict(measured) }
        if isRefused(nearest) { return .refused }
        guard case .allowed(let category) = nearest.kind else { return .unnamed }
        return named(nearest, category)
    }

    /// Nothing within ``visitRadius``: the nearest park, beach or campground within ``areaRadius``, unless a
    /// refused place is within ``areaRefuseRadius``.
    private static func areaVerdict(_ measured: [NearbyPlace]) -> PlaceVerdict {
        if measured.contains(where: { $0.metres <= areaRefuseRadius && isRefused($0) }) { return .refused }
        for place in measured where place.metres <= areaRadius && !isRefused(place) {
            guard case .allowed(let category) = place.kind, category.isArea else { continue }
            return named(place, category)
        }
        return .unnamed
    }

    /// The allowed verdict for `place`, or unnamed when it has no name.
    private static func named(_ place: NearbyPlace, _ category: PlaceCategory) -> PlaceVerdict {
        let name = place.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? .unnamed : .allowed(category, name: String(name.prefix(PlaceRecord.maxNameLength)))
    }

    /// Whether a solo photo taken where `nearby` was found may keep its point: never with no answer (nil),
    /// never with a refused place within ``photoRefuseRadius``.
    public static func photoMayKeepPlace(_ nearby: [NearbyPlace]?) -> Bool {
        guard let nearby else { return false }
        return !nearby.contains { $0.metres.isFinite && $0.metres <= photoRefuseRadius && isRefused($0) }
    }

    /// Whether `place` is one Fernlet never names or keeps: by its kind, or by the words in its name.
    public static func isRefused(_ place: NearbyPlace) -> Bool {
        if place.kind == .refused { return true }
        let folded = place.name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        return refusedWords.contains { folded.contains($0) }
    }
}

/// A place the person returns to, in "Where you've been" (`b2-where-been`): a name, a kind, the point the
/// person stood at (Fernlet's own reading, never Apple's), and how many times they've been. A count, never
/// dates (owner, 2026-10-22).
///
/// Frozen at rest: `id`, `name`, `category`, `point` and `visits` are field names of the sealed log.
public nonisolated struct PlaceRecord: Codable, Equatable, Identifiable, Sendable {
    /// The longest name kept.
    public static let maxNameLength = 80

    public let id: UUID
    /// The name it shows under: the lookup's name when it was first visited, or the person's own.
    public var name: String
    public let category: PlaceCategory
    /// Where the person stood on the first visit.
    public let point: GeoPoint
    /// How many visits it has had.
    public var visits: Int

    /// A place record.
    public init(id: UUID = UUID(), name: String, category: PlaceCategory, point: GeoPoint, visits: Int = 0) {
        self.id = id
        self.name = String(name.prefix(Self.maxNameLength))
        self.category = category
        self.point = point
        self.visits = visits
    }
}

/// One entry on the 30-day timeline: a stop at a place, or a walk or run the person recorded.
///
/// Frozen at rest: the field names and ``Kind``'s raw values.
public nonisolated struct PlaceStop: Codable, Equatable, Identifiable, Sendable {
    /// What the stop was.
    public enum Kind: String, Codable, Sendable {
        case visit
        case walk
        case run
    }

    public let id: UUID
    public let kind: Kind
    /// When it began.
    public let at: Date
    /// The place visited (``PlaceRecord/id``), for a visit.
    public let placeID: UUID?
    /// A walk's or run's length, in metres.
    public let metres: Double?
    /// The walk's or run's workout, whose saved line (if any) the day's map draws.
    public let workoutID: UUID?

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

/// An allowed place's point and kind, without its name: what background visits are matched against while
/// Private is closed (the names stay under the hub key).
///
/// Frozen at rest: the field names.
public nonisolated struct KnownPlace: Codable, Equatable, Sendable {
    public let id: UUID
    public let category: PlaceCategory
    public let point: GeoPoint

    /// A known place.
    public init(id: UUID, category: PlaceCategory, point: GeoPoint) {
        self.id = id
        self.category = category
        self.point = point
    }
}
