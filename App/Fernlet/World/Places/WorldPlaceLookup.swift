import Foundation
import WorldMapStore

/// The seam a place is decided and named through (World build step 5c and round 5).
///
/// - **At capture**, on the device, at the moment of a visit or a solo photo: the places around a point, in
///   plain values (``NearbyPlace``), or nil when no answer came (offline, or the lookup failed). Fernlet
///   keeps none of what comes back beyond the decision (the MapKit terms): a visit keeps the person's own
///   point and the lookup's reference to the place; a photo keeps its point or nothing.
/// - **When the person looks** at their places (Private's Places page): the name and kind of a kept place,
///   asked for again by its reference (``placeName(for:)``) and held in memory only, never written; and, on
///   their tap, the place opened in Apple Maps by that reference (``openInMaps(placeID:)``).
///
/// Phase 1's lookup is Apple's map (`ApplePlaceLookup`, in `AppleMutedBaseMap.swift`, the one MapKit file).
/// Capture lookups run only in the foreground about where the person stands while the map is on screen;
/// name lookups only while Places is open. Tests stand in fixed answers.
@MainActor
protocol WorldPlaceLooking {
    /// The places within about 300 m of `point`, or nil when there's no answer.
    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]?

    /// The name and kind of the place the lookup refers to as `placeID`, held in memory only; nil when there
    /// is no answer (offline, the place is gone, or it now reads as a place Fernlet never names).
    func placeName(for placeID: String) async -> WorldPlaceName?

    /// Forgets every name held in memory (the wipes, Delete all of it, a decoy).
    func forgetNames()

    /// Opens the place the lookup refers to as `placeID` in Apple's Maps app, on the person's tap (owner's
    /// form answer 53, 2026-10-25): looked up by that reference and handed to Maps, which fetches and
    /// shows its name and address; Fernlet keeps nothing of it. False when there is no answer (offline,
    /// or the place is gone) or Maps did not open.
    func openInMaps(placeID: String) async -> Bool
}

extension WorldPlaceLooking {
    /// No Maps to open: tests and the fixed lookups.
    func openInMaps(placeID: String) async -> Bool {
        false
    }
}

/// A kept place's name and kind as the lookup gives them again, by the place's reference: shown on the
/// Places page and held in memory only (the MapKit terms let Fernlet keep the reference, not the data).
nonisolated struct WorldPlaceName: Equatable, Sendable {
    /// The place's name.
    let name: String
    /// Its everyday kind, when the lookup's category is one; nil otherwise.
    let category: PlaceCategory?

    /// The name `name` and the kind `category`, or nil when the place reads as one Fernlet never names
    /// (a refused kind, or a refused word in its name) or has no name.
    static func shown(name: String, kind: NearbyPlace.Kind) -> WorldPlaceName? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !PlaceClassifier.isRefused(NearbyPlace(name: trimmed, kind: kind, metres: 0)) else { return nil }
        guard case .allowed(let category) = kind else { return WorldPlaceName(name: trimmed, category: nil) }
        return WorldPlaceName(name: trimmed, category: category)
    }
}

/// A lookup with fixed answers: tests, previews, and DEBUG screenshots.
struct FixedPlaceLookup: WorldPlaceLooking {
    /// The answer every capture lookup gets.
    let answer: [NearbyPlace]?
    /// The names it gives by reference (none by default: every place unnamed, as offline).
    var names: [String: WorldPlaceName] = [:]

    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]? {
        answer
    }

    func placeName(for placeID: String) async -> WorldPlaceName? {
        names[placeID]
    }

    func forgetNames() {}
}
