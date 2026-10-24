import Foundation
import WorldMapStore

/// The seam a place's kind is decided through, on the device, at the moment of a visit or a solo photo
/// (World build step 5c): the places around a point, in plain values (``NearbyPlace``), or nil when no
/// answer came (offline, or the lookup failed). Fernlet keeps none of what comes back beyond the decision
/// (the MapKit terms): a visit keeps the person's own point, an allowed kind and the place's name as the
/// label it starts with; a photo keeps its point or nothing.
///
/// Phase 1's lookup is Apple's map (`ApplePlaceLookup`, in `AppleMutedBaseMap.swift`, the one MapKit file),
/// asked only in the foreground about where the person stands while the map is on screen, so it learns
/// nothing the map's own tiles of that area don't already show it. Tests stand in a fixed answer.
@MainActor
protocol WorldPlaceLooking {
    /// The places within about 80 m of `point`, or nil when there's no answer.
    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]?
}

/// A lookup with a fixed answer: tests, previews, and DEBUG screenshots.
struct FixedPlaceLookup: WorldPlaceLooking {
    /// The answer every call gets.
    let answer: [NearbyPlace]?

    func nearbyPlaces(around point: GeoPoint) async -> [NearbyPlace]? {
        answer
    }
}
