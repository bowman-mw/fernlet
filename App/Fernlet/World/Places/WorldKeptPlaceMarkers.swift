import Foundation
import WorldMapStore

extension WorldMapMarker.Kind {
    /// Whether the marker is a place to eat's bowl (else a gym's dumbbell).
    var isEatingPlace: Bool {
        if case .eatingPlace = self { return true }
        return false
    }
}

extension FernletStore {
    /// The icons of the restaurants and gyms the person remembered (round 7, `ref-tag-named` →
    /// `ref-places-map`), at once, without waiting for three meals: a bowl or a dumbbell at Fernlet's point,
    /// named by the person or by Apple Maps again by reference (in memory only). A place to eat already drawn
    /// among `eating` (a favourite) isn't drawn twice. None in a decoy.
    func worldKeptPlaceMarkers(besides eating: [WorldMapMarker]) -> [WorldMapMarker] {
        guard !duressSessionActive else { return [] }
        let drawn = Set(eating.map(\.id))
        let references = Set(eating.compactMap { marker -> String? in
            guard case .eatingPlace(let placeID) = marker.kind else { return nil }
            return placeID
        })
        return worldPlaces.keptPlaces.compactMap { place -> WorldMapMarker? in
            guard let icon = place.icon, !drawn.contains(place.id) else { return nil }
            let name = place.label ?? worldPlaces.eatingNames[place.id] ?? ""
            switch icon {
            case .eat:
                guard let placeID = place.placeID, !references.contains(placeID) else { return nil }
                return WorldMapMarker(id: place.id, kind: .eatingPlace(placeID: placeID), name: name, point: place.point)
            case .gym:
                return WorldMapMarker(id: place.id, kind: .keptGym, name: name, point: place.point)
            }
        }
    }
}
