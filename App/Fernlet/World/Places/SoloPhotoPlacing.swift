import FernletUI
import PrivateMediaStore
import SwiftUI
import WorldMapStore

/// A "Just you" photo that kept no place (`ref-tag-photo`, approved 2026-10-25): its card says "No place, to
/// be careful" after the date, with a pixel pin, and a small "Put on the map" button that opens the Remember
/// this place sheet titled "Put on the map". Nothing shows for a photo with a place, or where the album has
/// no store to place it through (a decoy has none). VoiceOver reads the line after the date, then the button.
struct SoloNoPlaceRow: View {
    let album: SoloAlbumModel
    let photo: SoloCameraPhoto

    var body: some View {
        if let store = album.placesStore, !store.duressSessionActive, !hasPlace(store) {
            HStack(alignment: .center, spacing: 10) {
                HStack(spacing: 6) {
                    WorldSpriteView(sprite: WorldSprites.pin, scale: 2)
                        .accessibilityHidden(true)
                    Text(WorldHomeCopy.noPlace)
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 6)
                if startPoint(store) != nil {
                    Button { album.placing = photo } label: { Text(WorldHomeCopy.putOnMap) }
                        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                        .accessibilityIdentifier("soloPhoto.putOnMap")
                }
            }
        }
    }

    /// Whether the photo has a place (read again when one is put on the map).
    private func hasPlace(_ store: FernletStore) -> Bool {
        _ = album.placesRevision
        return store.soloPhotoHasPlace(photo.id)
    }

    /// Where the pin starts: where the person last stood, else their first home.
    private func startPoint(_ store: FernletStore) -> GeoPoint? {
        store.worldLocation.latest?.point ?? store.worldHomes.homes.first?.point
    }
}

/// Presents "Put on the map" for the photo the album is placing; the card reads again once it has a place.
struct SoloPutOnMapPresenter: ViewModifier {
    @Bindable var album: SoloAlbumModel

    func body(content: Content) -> some View {
        content.sheet(item: $album.placing) { photo in
            if let store = album.placesStore, let start = store.worldLocation.latest?.point ?? store.worldHomes.homes.first?.point {
                WorldRememberPlaceSheet(store: store, mode: .photo(id: photo.id, start: start, takenAt: photo.takenAt)) {
                    album.placing = nil
                    album.placed()
                }
            }
        }
    }
}
