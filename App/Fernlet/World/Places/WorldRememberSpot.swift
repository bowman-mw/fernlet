import Foundation
import WorldMapStore

/// The spot "Remember this place" offers (World build round 7, owner-approved 2026-10-26: `ref-tag-home`
/// draft 2, `ref-tag-how`): where the person has stayed, since when, and what Fernlet could tell about it at
/// the moment it decided. In memory only, never kept; it goes when they move more than 50 m away, once they
/// remember it, or after "Not here".
///
/// Apple's name for a named place is held here only while the button shows (the MapKit terms allow showing
/// it, not keeping it), so the sheet can fill it in; a refused place's name never reaches it.
nonisolated struct WorldRememberSpot: Equatable, Identifiable, Sendable {
    /// What Fernlet could tell about the spot.
    enum Kind: Equatable, Sendable {
        /// A spot Fernlet won't name, to be careful (`ref-tag-name`): nothing can be kept but what the person
        /// adds, so "Not here" only hides the button until they leave.
        case refused
        /// A spot Apple has no name for, a flat, a friend's (`ref-tag-unnamed`).
        case unnamed
        /// A named everyday place (`ref-tag-named`): Apple's reference, its name as Apple gave it (nil until
        /// it is asked for again by the reference, or when no answer came) and its kind.
        case named(placeID: String, name: String?, category: PlaceCategory?)
    }

    /// How long the person must have stayed before the button shows ("more than 2 minutes").
    static let showAfter: TimeInterval = 2 * 60

    let id: UUID
    /// Where the stop was decided.
    let point: GeoPoint
    /// When the person began staying there.
    let since: Date
    var kind: Kind

    /// A spot at `point` the person has stayed at since `since`.
    init(id: UUID = UUID(), point: GeoPoint, since: Date, kind: Kind) {
        self.id = id
        self.point = point
        self.since = since
        self.kind = kind
    }

    /// Whether "Not here" can keep a quiet "don't ask here" for it: anywhere but a spot Fernlet won't name.
    var isNameable: Bool { kind != .refused }

    /// Apple's reference, for a named place.
    var placeID: String? {
        guard case .named(let placeID, _, _) = kind else { return nil }
        return placeID
    }

    /// Apple's name as it was given, for a named place that has one.
    var appleName: String? {
        guard case .named(_, let name, _) = kind else { return nil }
        return name.flatMap(PlaceRecord.validLabel)
    }

    /// The everyday kind of a named place, when Apple gave one.
    var category: PlaceCategory? {
        guard case .named(_, _, let category) = kind else { return nil }
        return category
    }

    /// Whether the person has stayed long enough at `date` for the button to show.
    func isDue(at date: Date) -> Bool {
        date.timeIntervalSince(since) > Self.showAfter
    }

    /// What a lookup's `verdict` makes of the spot, from the `nearby` places it was decided over: refused,
    /// unnamed, or the allowed place with Apple's reference and name. An allowed place with no reference is
    /// offered as unnamed, so an unchanged Apple name is never kept without one.
    static func kind(for verdict: PlaceVerdict, nearby: [NearbyPlace]) -> Kind {
        switch verdict {
        case .refused: return .refused
        case .unnamed: return .unnamed
        case .allowed(let placeID):
            guard let placeID, let place = nearby.first(where: { $0.placeID == placeID }) else { return .unnamed }
            guard case .allowed(let category) = place.kind else { return .named(placeID: placeID, name: place.name, category: nil) }
            return .named(placeID: placeID, name: place.name, category: category)
        }
    }
}

/// What remembering a spot did: the place's id in Where you've been, and whether the person's own name
/// still has to reach a place already folded into the log (which only Private, open, can rename).
nonisolated struct WorldRememberOutcome: Equatable, Sendable {
    let placeID: UUID
    /// The person's own name for a place Where you've been already holds under the hub key, or nil.
    let pendingRename: String?
}
