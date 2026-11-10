import FernletDomainModel
import FernletFoundation
import FernletUI
import SwiftUI
import WorldMapStore

/// A print on the map where road trip photos were taken (World-RoadTrip-Spec §2.8, `rt-map`, owner-approved
/// 2026-11-10): the solo photos' print sprite with a small car stamp on its corner (the review page's amber tile), so
/// trip photos are told apart; photos within 40 m share one print. A 44-pt target; tapping it opens the photos
/// (``RoadTripPhotoViewer``). VoiceOver: "Road trip photos here, 3".
///
/// **The trip-only exception:** a friend's trip photo sits here as this iPhone's own does (the owner's decision:
/// "photos anyone takes on the trip may sit on each member's map where they were taken"). Hangout and wall photos
/// never reach a print: only the trip roll feeds ``FernletStore/roadTripPhotoMarkers(near:)``.
struct RoadTripPhotoMarkerView: View {
    let place: WorldPhotoPlace
    let onOpen: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topTrailing) {
                WorldSpriteView(sprite: WorldSprites.photo, scale: 3)
                carStamp.offset(x: 9, y: -9)
            }
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(RoadTripCopy.markerSpoken(count: place.photoIDs.count)))
        .accessibilityInputLabels([Text(RoadTripCopy.title)])
        .accessibilityIdentifier("world.marker.roadTripPhoto")
    }

    /// The small car stamp: the ride's pixel car on an amber tile in the ink frame.
    private var carStamp: some View {
        WorldSpriteView(sprite: WorldSprites.rideCar(dark: colorScheme == .dark, increasedContrast: contrast == .increased),
                        scale: 1)
            .padding(2)
            .background(WorldPalette.rgb(0xF2B54A), in: RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(WorldPalette.ink, lineWidth: 1.5))
            .accessibilityHidden(true)
    }
}

/// The road trip photos of one print, opened from the map (`rt-map`): each photo in the album post's pager, then
/// its caption, "Road trip to the coast · Nov 10 · Rae" (VoiceOver: "Photo from the road trip to the coast, by
/// Rae"), and **Hide from the map**, which takes that photo off the map (it stays on this iPhone). Closed with ✕;
/// closes itself when the last photo is hidden. Nothing in a decoy (the store hands out no detail and no byte).
struct RoadTripPhotoViewer: View {
    let store: FernletStore
    let place: WorldPhotoPlace
    let onDismiss: () -> Void
    @State private var details: [RoadTripPhotoDetail] = []
    @State private var selection: UUID

    /// The viewer of `place`'s photos.
    init(store: FernletStore, place: WorldPhotoPlace, onDismiss: @escaping () -> Void) {
        self.store = store
        self.place = place
        self.onDismiss = onDismiss
        _selection = State(initialValue: place.photoIDs.first ?? place.id)
    }

    var body: some View {
        WorldPanelFrame(panel: .friends, title: AddressedCopy.plain(RoadTripCopy.title), onClose: onDismiss) {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        AlbumPostPager(ids: details.map(\.id), selection: $selection, height: geometry.size.width * 1.25) { id in
                            page(id, width: geometry.size.width)
                        }
                        card.padding(.horizontal, 16).padding(.vertical, 14)
                    }
                }
                .scrollIndicators(.hidden)
            }
        }
        .onAppear(perform: read)
        .onChange(of: store.duressSessionActive) { _, _ in read() }
        .accessibilityIdentifier("roadTrip.photoViewer")
    }

    /// The photo on screen's detail.
    private var shown: RoadTripPhotoDetail? {
        details.first { $0.id == selection } ?? details.first
    }

    /// One photo, fitted, with its VoiceOver label.
    private func page(_ id: UUID, width: CGFloat) -> some View {
        let index = details.firstIndex { $0.id == id } ?? 0
        let current = details.firstIndex { $0.id == selection } ?? 0
        return Color.clear
            .overlay {
                LazyFriendPhotoImage(loadData: { store.roadTripPhotoImage(id) }, contentMode: .fit,
                                     shouldLoad: abs(index - current) <= 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: width * 1.25)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isImage)
            .accessibilityLabel(Text(verbatim: details.first { $0.id == id }?.spoken ?? ""))
    }

    /// The paper card: the caption, then Hide from the map.
    @ViewBuilder
    private var card: some View {
        if let shown {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: shown.caption)
                    .font(FernletFramedFont.cardTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Button { hide(shown.id) } label: { Text(RoadTripCopy.hideFromMap) }
                    .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                    .accessibilityIdentifier("roadTrip.photo.hide")
            }
            .albumPostCard()
        }
    }

    /// Reads the photos' captions again (a hide, a decoy); closes when none is left.
    private func read() {
        details = store.roadTripPhotoDetails(place.photoIDs)
        if !details.contains(where: { $0.id == selection }), let first = details.first { selection = first.id }
        if details.isEmpty { onDismiss() }
    }

    /// Hide from the map: the photo leaves the map, and the viewer shows the next one.
    private func hide(_ id: UUID) {
        let hidden = store.hideRoadTripPhoto(id)
        FernletFeedback.system.play(hidden ? .done : .failed)
        read()
    }
}

/// Presents a trip print's photos over Home when it is tapped (``RoadTripPhotoViewer``).
struct RoadTripPhotoPresenter: ViewModifier {
    var store: FernletStore
    @Binding var place: WorldPhotoPlace?

    func body(content: Content) -> some View {
        content.fullScreenCover(item: $place) { opened in
            RoadTripPhotoViewer(store: store, place: opened) { place = nil }
        }
    }
}
