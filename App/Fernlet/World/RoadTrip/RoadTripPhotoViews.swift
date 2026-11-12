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

/// Road trip photos opened full screen (`rt-map`): each photo in the album post's pager, then its caption, "Road trip
/// to the coast · Nov 10 · Rae" (VoiceOver: "Photo from the road trip to the coast, by Rae"), and **Hide from the
/// map**, which takes that photo off the map (it stays on this iPhone), offered only while the photo is on the map.
///
/// - **From a print on the map** (``Origin/map``): the print's photos still on the map, under "Road trip", closed
///   with ✕; it closes itself when the last photo is hidden.
/// - **From the Album** (``Origin/album(title:)``, owner 2026-11-10: "Yes, in the Album"): every photo of the trip
///   held here, hidden ones too, under the trip's title with "‹ Album" back. A photo with no place on the map (none
///   yet, or gone with Delete map history) or already hidden has no Hide: the action would do nothing. A hidden one
///   that still has a place offers **Show on the map** instead (owner 2026-11-12), which puts it back.
///
/// Nothing in a decoy (the store hands out no detail and no byte), so it closes.
struct RoadTripPhotoViewer: View {
    /// Where the viewer was opened from.
    enum Origin: Equatable {
        /// A print on the map: its photos on the map.
        case map
        /// A trip's set in the Album, with the set's title: every photo of the trip held here.
        case album(title: String)
    }

    let store: FernletStore
    /// The photos, in order.
    let photoIDs: [UUID]
    let origin: Origin
    let onDismiss: () -> Void
    @State private var details: [RoadTripPhotoDetail] = []
    @State private var selection: UUID

    /// The viewer of `place`'s photos, opened from the map.
    init(store: FernletStore, place: WorldPhotoPlace, onDismiss: @escaping () -> Void) {
        self.init(store: store, photoIDs: place.photoIDs, origin: .map, onDismiss: onDismiss)
    }

    /// The viewer of `photoIDs`, opened from `origin`.
    init(store: FernletStore, photoIDs: [UUID], origin: Origin, onDismiss: @escaping () -> Void) {
        self.store = store
        self.photoIDs = photoIDs
        self.origin = origin
        self.onDismiss = onDismiss
        _selection = State(initialValue: photoIDs.first ?? UUID())
    }

    /// The plate's title: "Road trip" from the map, the trip's title from the Album.
    private var title: String {
        guard case .album(let title) = origin else { return AddressedCopy.plain(RoadTripCopy.title) }
        return title
    }

    /// "‹ Album" back to the grid, from the Album only.
    private var onBack: (() -> Void)? {
        origin == .map ? nil : onDismiss
    }

    var body: some View {
        WorldPanelFrame(panel: .friends, title: title, backTitle: onBack == nil ? nil : WorldPanel.friends.title,
                        onBack: onBack, onClose: onDismiss) {
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

    /// The paper card: the caption, then Hide from the map while the photo is on the map.
    @ViewBuilder
    private var card: some View {
        if let shown {
            VStack(alignment: .leading, spacing: 12) {
                Text(verbatim: shown.caption)
                    .font(FernletFramedFont.cardTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                if Self.offersHide(shown) {
                    Button { hide(shown.id) } label: { Text(RoadTripCopy.hideFromMap) }
                        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                        .accessibilityIdentifier("roadTrip.photo.hide")
                } else if Self.offersShow(shown) {
                    Button { show(shown.id) } label: { Text(RoadTripCopy.showOnMap) }
                        .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                        .accessibilityIdentifier("roadTrip.photo.show")
                }
            }
            .albumPostCard()
        }
    }

    /// Whether the card offers "Hide from the map" for `detail`: only while the photo is on the map (shown, with a
    /// place); for one with no place, or hidden already, the action would do nothing, so it is left out.
    static func offersHide(_ detail: RoadTripPhotoDetail) -> Bool {
        detail.isOnMap
    }

    /// Whether the card offers "Show on the map" for `detail`: only while it is hidden and still has a place to go
    /// back to (a photo whose place went with Delete map history has nowhere on the map, so it is left out).
    static func offersShow(_ detail: RoadTripPhotoDetail) -> Bool {
        detail.isHidden && detail.hasPlace
    }

    /// Reads the photos' captions again (a hide, a decoy); closes when none is left. From the map only the photos on it
    /// are read; from the Album every photo held, so a hidden one stays (without its Hide).
    private func read() {
        details = store.roadTripPhotoDetails(photoIDs, includingHidden: origin != .map)
        if !details.contains(where: { $0.id == selection }), let first = details.first { selection = first.id }
        if details.isEmpty { onDismiss() }
    }

    /// Hide from the map: the photo leaves the map. From the map the viewer then shows the next one; from the Album
    /// the photo stays, without its Hide.
    private func hide(_ id: UUID) {
        let hidden = store.hideRoadTripPhoto(id)
        FernletFeedback.system.play(hidden ? .done : .failed)
        read()
    }

    /// Show on the map (from the Album, where hidden photos are listed): the photo goes back on the map and the card
    /// offers its Hide again.
    private func show(_ id: UUID) {
        let shownAgain = store.showRoadTripPhoto(id)
        FernletFeedback.system.play(shownAgain ? .done : .failed)
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
