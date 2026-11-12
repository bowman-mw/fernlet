import FernletDomainModel
import FernletUI
import SwiftUI

/// A road trip's set in the Album (owner, 2026-11-10: "Yes, in the Album"), drawn like a "Just you" set
/// (``SoloSetTile``): its newest photo edge to edge, the pixel stack on a carousel, and the framed tag bottom left,
/// which carries the set's title: the trip's name, or "Road trip" and the days once the trip itself is gone. The
/// presenter makes it one Button, with ``accessibilityLabel(for:)`` and ``inputLabels``.
struct RoadTripSetTile: View {
    let photoSet: RoadTripAlbumSet
    /// Loads a shown photo's thumbnail.
    let thumbnail: (UUID) -> Data?

    var body: some View {
        WorldPalette.paperShade
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LazyFriendPhotoImage(loadData: { thumbnail(photoSet.cover) }, contentMode: .fill)
            }
            .clipped()
            .overlay(alignment: .topTrailing) {
                if photoSet.isCarousel {
                    WorldSpriteView(sprite: FriendsSprites.stack, scale: 2)
                        .padding(8)
                }
            }
            .overlay(alignment: .bottomLeading) { tag }
    }

    /// What VoiceOver says for a set's tile: its title, then, like the other sets, "carousel" and the count when it
    /// holds more than one photo ("Road trip to the coast, carousel, 6 photos").
    static func accessibilityLabel(for photoSet: RoadTripAlbumSet) -> Text {
        guard photoSet.isCarousel else { return Text(verbatim: photoSet.title) }
        let photos = AddressedCopy.plain(RoadTripCopy.photos(photoSet.photoIDs.count))
        return Text(RoadTripCopy.albumSpoken(photoSet.title, photos: photos))
    }

    /// Short spoken names for Voice Control: "Road trip" first, then the generic "Photo", as "Just you" does.
    static var inputLabels: [Text] { [Text(RoadTripCopy.title), Text("Photo")] }

    /// The framed tag with the set's title: cream paper, ink frame — fixed colours, because it sits on a photo. At
    /// most two lines, so a long name or a large text size stays on the tile.
    private var tag: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Text(verbatim: photoSet.title)
            .font(FernletFramedFont.tag)
            .foregroundStyle(WorldPalette.rgb(0x3A2414))
            .lineLimit(2)
            .truncationMode(.tail)
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(WorldPalette.rgb(0xFFF6E2), in: shape)
            .overlay(shape.strokeBorder(WorldPalette.rgb(0x4A2E1C), lineWidth: 2))
            .padding(6)
    }
}

/// Hangs the road trips' sets on the Album page: reads them when the page appears and whenever the trip roll or the
/// trips' records change (a photo kept or hidden, Delete map history, the decoy starting or ending), and presents a
/// tapped set full screen in the trip photo viewer (``RoadTripPhotoViewer``, from the Album: "‹ Album" back, every
/// photo of the trip, hidden ones too). A decoy reads none.
struct RoadTripAlbumHost: ViewModifier {
    let store: FernletStore
    /// The sets the page shows, newest first.
    @Binding var sets: [RoadTripAlbumSet]
    /// The set opened full screen, if any.
    @Binding var openSet: RoadTripAlbumSet?

    func body(content: Content) -> some View {
        content
            .onAppear(perform: read)
            .onChange(of: refreshKey) { _, _ in read() }
            .fullScreenCover(item: $openSet) { opened in
                RoadTripPhotoViewer(store: store, photoIDs: opened.photoIDs, origin: .album(title: opened.title)) {
                    openSet = nil
                }
            }
    }

    /// What, when it changes, makes the page read again: the decoy, the roll's revision, and the trips' records.
    private var refreshKey: [Int] {
        let keeper = store.worldFog.roadTrip
        return [store.duressSessionActive ? 1 : 0, store.roadTripPhotos.revision, keeper.isLoaded ? 1 : 0, keeper.book.trips.count]
    }

    /// Reads the sets afresh (none in a decoy).
    private func read() {
        sets = store.roadTripAlbumSets()
    }
}
