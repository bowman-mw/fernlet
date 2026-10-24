import SwiftUI
import FernletDomainModel
import FernletFoundation
import FernletProximityUI
import FernletUI
import PrivateMediaStore

// The solo camera's photos in the Friends album (owner, 2026-10-24: "I think the photos can be saved
// in the friend area"; `b4-mem-solo-waiting`, `b4-mem-solo-revealed`, `b4-mem-solo-open`, approved
// 2026-10-24). Drawn as parts that slot into today's Friends page — the friends lane's 3-wide album —
// so they can move to the Album page when that page is approved. A decoy session shows none of it.

/// The solo album's pixel art.
nonisolated enum SoloAlbumSprites {
    /// The crescent moon on the waiting tile and its line (`b4-mem-solo-waiting`): ink outline, slate fill.
    static let moon = WorldSprite(
        rows: ["...kkk..", "..kmmmk.", ".kmmkk..", "kmmk....", "kmmk....", "kmmk....", ".kmmkk..", "..kmmmk.", "...kkk.."],
        palette: ["k": WorldSprite.ink, "m": 0x8E9BB0])
}

/// The line above the album while photos are held (`b4-mem-solo-waiting`), in the camera's own words:
/// "3 photos from today appear tonight, after Fernlet goes to sleep."
struct SoloWaitingNote: View {
    /// Photos still held.
    let count: Int
    /// The companion's own name, or Fernlet.
    let companionName: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            WorldSpriteView(sprite: SoloAlbumSprites.moon, scale: 2)
                .accessibilityHidden(true)
            line
                .font(FernletFramedFont.notice)
                .foregroundStyle(WorldPalette.dim)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("friends.soloWaitingNote")
    }

    private var line: Text {
        guard count != 1 else { return Text("1 photo from today appears tonight, after \(companionName) goes to sleep.") }
        return Text("\(count) photos from today appear tonight, after \(companionName) goes to sleep.")
    }
}

/// The placeholder tile first in the album while photos are held (`b4-mem-solo-waiting`): a striped
/// square with a dashed frame, the pixel moon, "Tonight" and the count — so today's photos read as
/// safe, without showing one before the companion sleeps.
struct SoloWaitingTile: View {
    /// Photos still held.
    let count: Int

    var body: some View {
        SoloStripes()
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                Rectangle()
                    .strokeBorder(WorldPalette.iconInk.opacity(0.45), style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                    .padding(6)
            }
            .overlay {
                VStack(spacing: 3) {
                    WorldSpriteView(sprite: SoloAlbumSprites.moon, scale: 3)
                    Text("Tonight")
                        .font(FernletFramedFont.buttonSmall)
                    countText
                        .font(FernletFramedFont.rowDetail)
                        .opacity(0.85)
                }
                .foregroundStyle(WorldPalette.bark)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.7)
                .padding(10)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityText)
            .accessibilityIdentifier("friends.soloWaitingTile")
    }

    private var countText: Text {
        count == 1 ? Text("1 photo") : Text("\(count) photos")
    }

    private var accessibilityText: Text {
        guard count != 1 else { return Text("Just you, 1 photo from today. It appears tonight.") }
        return Text("Just you, \(count) photos from today. They appear tonight.")
    }
}

/// The waiting tile's paper stripes at 135°, 8 pt each (light and dark from the approved kit).
struct SoloStripes: View {
    private static let light = WorldPalette.adaptive(light: 0xF3EAD6, dark: 0x3A2E22)
    private static let shade = WorldPalette.adaptive(light: 0xEBDFC6, dark: 0x33281D)

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Self.light))
            let reach = size.width + size.height
            // R2: bounded by the tile's size, one band per 16 pt.
            for start in stride(from: -size.height, through: reach, by: 16) {
                var band = Path()
                band.move(to: CGPoint(x: start, y: 0))
                band.addLine(to: CGPoint(x: start + 8, y: 0))
                band.addLine(to: CGPoint(x: start + 8 + size.height, y: size.height))
                band.addLine(to: CGPoint(x: start + size.height, y: size.height))
                band.closeSubpath()
                context.fill(band, with: .color(Self.shade))
            }
        }
        .accessibilityHidden(true)
    }
}

/// A "Just you" set in the album (`b4-mem-solo-revealed`): its cover edge to edge, the pixel stack on
/// a carousel, and the framed "Just you" tag bottom left — like a hangout's tile.
struct SoloSetTile: View {
    let photoSet: SoloPhotoSet
    /// Loads a shown photo's thumbnail.
    let thumbnail: (UUID) -> Data?

    var body: some View {
        WorldPalette.paperShade
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                LazyFriendPhotoImage(loadData: { thumbnail(photoSet.cover.id) }, contentMode: .fill)
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

    /// What VoiceOver says for a set's tile — "Just you, Oct 23, carousel, 3 photos", like the other
    /// sets. The presenter puts it on its Button, with ``inputLabels`` for Voice Control.
    static func accessibilityLabel(for photoSet: SoloPhotoSet) -> Text {
        let when = photoSet.date.formatted(date: .abbreviated, time: .omitted)
        guard photoSet.isCarousel else { return Text("Just you, \(when)") }
        return Text("Just you, \(when), carousel, \(photoSet.photos.count) photos")
    }

    /// Short spoken names for Voice Control: "Just you" first, then the generic "Photo".
    static var inputLabels: [Text] { [Text("Just you"), Text("Photo")] }

    /// The framed tag: cream paper, ink frame — fixed colours, because it sits on a photo.
    private var tag: some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        return Text("Just you")
            .font(FernletFramedFont.tag)
            .foregroundStyle(WorldPalette.rgb(0x3A2414))
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(WorldPalette.rgb(0xFFF6E2), in: shape)
            .overlay(shape.strokeBorder(WorldPalette.rgb(0x4A2E1C), lineWidth: 2))
            .padding(6)
    }
}

/// The "Just you" sets opened full screen (`b4-mem-solo-open`): the Album panel's plate titled "Just
/// you" with "‹ Album" in the icon's place (draft: "Back now says Album"), then each set as the album post's carousel, starting at the one tapped. Closes itself
/// when the last photo is deleted.
struct SoloPhotoFeedView: View {
    let album: SoloAlbumModel
    let initialSetID: String?
    /// Whether it was opened from a photo marker on the map (World build step 5c): then ✕ alone closes it,
    /// with no "‹ Album".
    let fromMap: Bool
    let onDismiss: () -> Void

    @State private var visibleSetID: String?

    /// The feed over `album`'s sets, opened at `initialSetID`.
    init(album: SoloAlbumModel, initialSetID: String?, fromMap: Bool = false, onDismiss: @escaping () -> Void) {
        self.album = album
        self.initialSetID = initialSetID
        self.fromMap = fromMap
        self.onDismiss = onDismiss
    }

    var body: some View {
        WorldPanelFrame(panel: .friends, title: String(localized: "Just you", comment: "The name of a set of photos taken with the camera on your own"),
                        backTitle: fromMap ? nil : WorldPanel.friends.title, onBack: fromMap ? nil : onDismiss, onClose: onDismiss) {
            GeometryReader { geometry in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        ForEach(album.sets) { entry in
                            SoloPhotoPostView(photoSet: entry, album: album, width: geometry.size.width)
                                .id(entry.id)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollIndicators(.hidden)
                .scrollPosition(id: $visibleSetID, anchor: .top)
                .onAppear { visibleSetID = initialSetID ?? album.sets.first?.id }
            }
        }
        .onChange(of: album.sets.isEmpty) { _, isEmpty in
            // Deleting the last photo empties the feed; close instead of a blank screen.
            if isEmpty { onDismiss() }
        }
    }
}

/// One "Just you" set in the feed: the album post's pager, then the paper card — "Just you", the day,
/// Save, Favorite and Delete (no Report: nobody else is in these), and the lock line "Only you can see
/// these. They're never shared."
///
/// Delete removes the sealed photo (its film is not given back). Save goes through the app's one
/// photo-library path (`FriendPhotoLibrarySaver`, add-only), with the shared failure alert.
struct SoloPhotoPostView: View {
    let photoSet: SoloPhotoSet
    let album: SoloAlbumModel
    let width: CGFloat

    @State private var selectedPhotoID: UUID
    @State private var pendingDeletePhotoID: UUID?
    @State private var saveFailure: PhotoSaveFailure?
    @State private var savedPhotoIDs: Set<UUID> = []
    /// Photos with a save running — at most one per photo (R3).
    @State private var inFlightSaveIDs: Set<UUID> = []

    init(photoSet: SoloPhotoSet, album: SoloAlbumModel, width: CGFloat) {
        self.photoSet = photoSet
        self.album = album
        self.width = width
        self._selectedPhotoID = State(initialValue: photoSet.photos.first?.id ?? photoSet.cover.id)
    }

    var body: some View {
        VStack(spacing: 0) {
            AlbumPostPager(ids: photoSet.photoIDs, selection: $selectedPhotoID, height: width * 1.25) { id in
                photoPage(id)
            }
            card
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
        }
        .onChange(of: photoSet.photoIDs) { _, ids in
            // A deleted photo leaves the selection on a missing page: re-anchor to one that is left.
            if !ids.contains(selectedPhotoID), let first = ids.first { selectedPhotoID = first }
        }
        .alert("Delete this picture?", isPresented: $pendingDeletePhotoID.isPresent()) {
            Button("Delete", role: .destructive) { deletePending() }
            Button("Cancel", role: .cancel) { pendingDeletePhotoID = nil }
        } message: {
            Text("This removes it from this device. It can't be undone.")
        }
        .photoSaveFailureAlert("Couldn't Save Photo", failure: $saveFailure)
    }

    /// The photo on screen.
    private var selectedPhoto: SoloCameraPhoto {
        photoSet.photos.first { $0.id == selectedPhotoID } ?? photoSet.cover
    }

    private func photoPage(_ id: UUID) -> some View {
        let index = photoSet.photoIDs.firstIndex(of: id) ?? 0
        let current = photoSet.photoIDs.firstIndex(of: selectedPhotoID) ?? 0
        return Color.clear
            .overlay {
                LazyFriendPhotoImage(loadData: { album.imageData(for: id) }, contentMode: .fit,
                                     shouldLoad: abs(index - current) <= 1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: width * 1.25)
    }

    /// The paper card: the title and the day with the actions, then the lock line.
    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    titleAndDay
                    Spacer(minLength: 6)
                    actions
                }
                VStack(alignment: .leading, spacing: 10) {
                    titleAndDay
                    actions
                }
            }
            HStack(alignment: .center, spacing: 6) {
                WorldSpriteView(sprite: WorldSprites.lock, scale: 2)
                    .accessibilityHidden(true)
                Text("Only you can see these. They're never shared.")
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
        }
        .albumPostCard()
    }

    /// "Just you" over the day the photo was taken ("Thursday, October 23").
    private var titleAndDay: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Just you")
                .font(FernletFramedFont.cardTitle)
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
            Text(verbatim: dayLine)
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(WorldPalette.dim)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// The day the photo was taken, then its place's name when it has one (`b4-mem-solo-open`: "Thursday 23
    /// October · Oak Park"). A photo taken at a refused place has no place, so no name.
    private var dayLine: String {
        let day = selectedPhoto.takenAt.formatted(.dateTime.weekday(.wide).month(.wide).day())
        guard let place = album.placeName(selectedPhoto.id) else { return day }
        return String(localized: "soloPhoto.dayAndPlace", defaultValue: "\(day) · \(place)",
                      comment: "A solo photo's card: the day it was taken, then where (a workout space's name)")
    }

    /// Save, Favorite and Delete for the photo on screen.
    private var actions: some View {
        let photo = selectedPhoto
        let isSaved = savedPhotoIDs.contains(photo.id)
        let isFavorite = photo.isFavorite == true
        return HStack(spacing: 8) {
            AlbumPostActionButton(sprite: isSaved ? WorldSprites.check : FriendsSprites.download,
                                  accessibilityLabel: isSaved ? "Saved to Photos" : "Save this picture to your Photos library") {
                save(photo)
            }
            AlbumPostActionButton(sprite: isFavorite ? WorldSprites.heartSm : FriendsSprites.heartOutline,
                                  accessibilityLabel: "Favorite this photo", selected: isFavorite) {
                if album.toggleFavorite(photo.id, in: photoSet) { FernletFeedback.system.play(.tick) }
            }
            AlbumPostActionButton(sprite: FriendsSprites.trash, accessibilityLabel: "Delete this picture") {
                pendingDeletePhotoID = photo.id
            }
        }
    }

    /// Deletes the photo the alert asked about from the sealed corpus.
    private func deletePending() {
        if let id = pendingDeletePhotoID, !album.delete(id) {
            FernletAuditLog.log("soloCamera.deleteNotApplied")
        }
        pendingDeletePhotoID = nil
    }

    /// Saves one photo to the Photos library through the app's one save path, never a false success.
    private func save(_ photo: SoloCameraPhoto) {
        guard !savedPhotoIDs.contains(photo.id), !inFlightSaveIDs.contains(photo.id) else { return }
        guard let data = album.imageData(for: photo.id) else {
            saveFailure = .generic
            return
        }
        inFlightSaveIDs.insert(photo.id)
        let payload = FriendPhotoPayload(id: photo.id, imageData: data, addedAt: photo.takenAt, senderName: "")
        Task {
            defer { inFlightSaveIDs.remove(photo.id) }
            do {
                try await FriendPhotoLibrarySaver.save([payload])
                savedPhotoIDs.insert(photo.id)
                FernletFeedback.system.play(.done)
            } catch {
                saveFailure = FriendPhotoLibrarySaver.userFacingFailure(for: error, photoCount: 1)
            }
        }
    }
}

/// Hangs the solo camera's album on a page (the Album page, `b4-mem-root`): reads the roll when the
/// page appears and whenever `refreshKey` changes (the decoy starting or ending), reads again the moment the next held photo is due (the companion
/// falling asleep while the page is open), and presents a tapped "Just you" set full screen.
struct SoloAlbumHost: ViewModifier {
    let album: SoloAlbumModel
    /// The set opened full screen, if any.
    @Binding var openSetID: String?
    /// Changes when the page should read again.
    let refreshKey: [Bool]
    /// The roll to read; nil in a decoy, which shows none of it.
    let roll: () -> SoloCameraRoll?

    func body(content: Content) -> some View {
        content
            .onAppear { album.refresh(roll: roll()) }
            .onChange(of: refreshKey) { _, _ in album.refresh(roll: roll()) }
            .task(id: album.nextRevealAt) { await refreshWhenDue() }
            .fullScreenCover(isPresented: $openSetID.isPresent()) {
                SoloPhotoFeedView(album: album, initialSetID: openSetID) { openSetID = nil }
            }
    }

    /// Waits for the next held photo's time, then reads again so it shows without leaving the page.
    private func refreshWhenDue() async {
        guard let due = album.nextRevealAt else { return }
        let wait = due.timeIntervalSinceNow
        if wait > 0 {
            do {
                try await Task.sleep(for: .seconds(wait))
            } catch {
                // Superseded: the page went, or a newer reveal time owns the wait.
                return
            }
        }
        album.refresh(roll: roll())
    }
}
