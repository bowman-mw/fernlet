import FernletUI
import SwiftUI
import WorldMapStore

/// A place on the map where the person took solo photos (design `b1-markers`' photo print; World build
/// step 5c, owner's Q24): the print sprite, a 44-pt target. Only photos that have
/// shown (after the companion slept), never a friend's, never one taken at a refused place. Tapping it opens
/// those photos (`b4-mem-solo-open`'s "Just you" carousel). VoiceOver: "Your photos here, 3".
struct WorldPhotoMarkerView: View {
    let place: WorldPhotoPlace
    let onOpen: () -> Void

    var body: some View {
        // The approved marker is the print alone (`b1-markers`); how many photos it holds is spoken.
        Button(action: onOpen) {
            WorldSpriteView(sprite: WorldSprites.photo, scale: 3)
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: Self.spoken(place)))
        .accessibilityIdentifier("world.marker.photo")
    }

    /// What VoiceOver says.
    static func spoken(_ place: WorldPhotoPlace) -> String {
        String(localized: "worldMarker.photos", defaultValue: "Your photos here, \(place.photoIDs.count)",
               comment: "World Home, VoiceOver: a map marker where the person took photos on their own; how many")
    }
}

/// The photos taken at one place, opened from its marker: the "Just you" carousel of those photos alone,
/// closed with ✕ (no "‹ Album": it opened from the map).
struct WorldPhotoPlaceFeed: View {
    var store: FernletStore
    let place: WorldPhotoPlace
    let onDismiss: () -> Void
    @State private var album: SoloAlbumModel

    /// The feed of `place`'s photos.
    init(store: FernletStore, place: WorldPhotoPlace, onDismiss: @escaping () -> Void) {
        self.store = store
        self.place = place
        self.onDismiss = onDismiss
        _album = State(initialValue: SoloAlbumModel(only: Set(place.photoIDs)))
    }

    var body: some View {
        SoloPhotoFeedView(album: album, initialSetID: nil, fromMap: true, onDismiss: onDismiss)
            .onAppear {
                album.placeName = { [store] in store.soloPhotoPlaceName(for: $0) }
                album.refresh(roll: store.duressSessionActive ? nil : store.soloCameraRoll())
            }
    }
}

/// Presents a photo place's feed over Home when its marker is tapped.
struct WorldPhotoPlacePresenter: ViewModifier {
    var store: FernletStore
    @Binding var place: WorldPhotoPlace?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $place) { opened in
            WorldPhotoPlaceFeed(store: store, place: opened) { place = nil }
        }
    }
}
