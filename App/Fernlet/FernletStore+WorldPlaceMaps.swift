import Foundation
import WorldMapStore

/// "Open in Apple Maps" on a kept place (owner's form answer 53, 2026-10-25; World build round 6b): the
/// place's stored Apple reference is looked up again and the place opened in Apple's Maps app, which
/// fetches and shows its name and address. Fernlet keeps only the reference it already kept (the MapKit
/// terms); nothing that comes back is written.
extension FernletStore {
    /// Opens `place` in Apple Maps by its reference. Never in a decoy (whose Places page is empty anyway),
    /// never for a place with no reference (one the person added themselves, a home or a hotel), and never
    /// for a DEBUG screenshot run that stands in "offline" names.
    ///
    /// - Returns: Whether Maps opened.
    func openWorldPlaceInAppleMaps(_ place: PlaceRecord) async -> Bool {
        guard !duressSessionActive, !UITestSupport.worldHomeScenes.contains("namesOffline"),
              let placeID = place.placeID, !placeID.isEmpty else { return false }
        return await worldPlaceLookup.openInMaps(placeID: placeID)
    }
}
