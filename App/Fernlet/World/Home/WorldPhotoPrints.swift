import FernletDomainModel
import FernletSocial
import SwiftUI
import UIKit

/// The photo wall on the map: four friend prints, two over two, in the top right beside the status
/// plate (design `b1-home-day`, draft 3: 72-pt prints in the language's ink frame, no captions, so the
/// photos speak for themselves).
///
/// **Each print opens its own photo** (`ref-wall-photo`, approved 2026-10-25): a tap hands Home a
/// ``FriendsRoute/wallPhoto(_:)`` and the Album opens that photo in its carousel (`b2-album-post`), at that
/// photo, with "‹ Album" and ✕. Before there are any photos (the empty first-launch prints) the wall is one
/// button that opens the Album, as before. VoiceOver: each print its own button ("Photo from Picnic,
/// October 12", "Opens it.") inside a group named "Photo wall".
///
/// The prints are today's photo wall (`FernletStore.photowallSeeds`, chosen once per launch from the
/// friend photos). A print with no photo yet is an empty paper print with a small pixel sprite, as the
/// approved first-launch design draws it. Friends' photos stay in this strip and never go on the map.
/// At accessibility text sizes the strip gives way, as Home's photo wall does, and the album stays one
/// tap away in the item bar.
///
/// **Loading (W-04, the phone test).** The four thumbnails are read once per wall, not in `body`: a
/// `.task` keyed on the seeds' photo ids fills an `@State` cache. Reading and opening a sealed thumbnail
/// stays on the main actor, the photo store's own isolation (its key provider caches without
/// synchronization, `FriendPhotoCorpusFiles`); decoding the JPEG into a bitmap runs off it
/// (`byPreparingForDisplay`). Nothing is read while protected data is unavailable (the files are
/// `.completeFileProtection`, so a read under the lock only fails and logs): the prints keep the images
/// they last had, and the wall reads again when the phone unlocks.
struct WorldPhotoPrints: View {
    /// How the four prints lie.
    enum Arrangement {
        /// Two over two, top right on the map (`b1-home-day`, draft 3).
        case grid
        /// One row of four under the name, with location off (`b1-home-denied`, draft 4); `compact` at
        /// the largest text sizes.
        case row(compact: Bool)
    }

    var store: FernletStore
    var arrangement: Arrangement = .grid
    /// Opens a print: its photo in the Album's carousel (a ``FriendsRoute/wallPhoto(_:)``), or the Album
    /// itself (nil) for an empty print.
    let onOpen: (FriendsRoute?) -> Void

    /// The prints' decoded thumbnails, by photo id: filled once per wall, kept across re-renders.
    @State private var images: [UUID: UIImage] = [:]
    /// Bumped when protected data comes back while a print still waits for its photo, so the wall
    /// reads again after an unlock.
    @State private var unlockGeneration = 0

    /// Each print's corner and tilt in the strip (x, y, degrees), from the approved design.
    static let layout: [(x: CGFloat, y: CGFloat, angle: Double)] = [(2, 0, -4), (76, 6, 3), (6, 86, 2), (80, 92, -3)]
    /// The strip's size, which holds the four tilted prints.
    static let size = CGSize(width: 156, height: 178)
    /// The row's corners and tilts, from the approved location-off design.
    static let rowLayout: [(x: CGFloat, y: CGFloat, angle: Double)] = [(0, 0, -3), (86, 0, 2), (172, 0, -2), (258, 0, 3)]
    /// The empty prints' sprites, in order.
    private static let emptySprites = [WorldSprites.onigiri, WorldSprites.shoe, WorldSprites.photo, WorldSprites.diary]

    var body: some View {
        wall
            .task(id: LoadKey(photoIDs: seedPhotoIDs, generation: unlockGeneration)) { await loadImages() }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in
                if Self.idsToRead(wanted: seedPhotoIDs, cached: Set(images.keys)).isEmpty == false { unlockGeneration &+= 1 }
            }
    }

    /// One button for the empty first-launch wall; otherwise a group of print buttons.
    @ViewBuilder
    private var wall: some View {
        if seedPhotoIDs.allSatisfy({ $0 == nil }) {
            Button { onOpen(nil) } label: { strip }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(Self.label))
                .accessibilityHint(Text(Self.hint))
                .accessibilityInputLabels([Text(Self.label), Text(Self.shortName)])
                .accessibilityIdentifier("world.photoWall")
        } else {
            strip
                .accessibilityElement(children: .contain)
                .accessibilityLabel(Text(Self.label))
                .accessibilityIdentifier("world.photoWall")
        }
    }

    /// The four prints at their corners and tilts; each its own button once the wall has a photo.
    private var strip: some View {
        let isOneButton = seedPhotoIDs.allSatisfy { $0 == nil }
        return ZStack(alignment: .topLeading) {
            ForEach(0..<positions.count, id: \.self) { index in
                Group {
                    if isOneButton { printTile(at: index) } else { printButton(at: index) }
                }
                .rotationEffect(.degrees(positions[index].angle))
                .offset(x: positions[index].x, y: positions[index].y)
                .zIndex(Double(index))
            }
        }
        .frame(width: frameSize.width, height: frameSize.height, alignment: .topLeading)
        .contentShape(Rectangle())
    }

    /// One print as its own button: its photo in the Album's carousel, or the Album for an empty print.
    @ViewBuilder
    private func printButton(at index: Int) -> some View {
        let photo = payload(at: index)
        Button { onOpen(photo.map { FriendsRoute.wallPhoto($0.id) }) } label: { printTile(at: index) }
            .buttonStyle(.plain)
            .accessibilityLabel(photo.map { Text(verbatim: Self.spokenTitle(of: $0)) } ?? Text(Self.emptyLabel))
            .accessibilityHint(Text(photo == nil ? Self.hint : Self.photoHint))
            .accessibilityInputLabels(photo.map { [Text(verbatim: Self.name(of: $0))] } ?? [Text(Self.shortName)])
            .accessibilityIdentifier("world.photoWall.print\(index)")
    }

    /// Where each print lies in this arrangement.
    private var positions: [(x: CGFloat, y: CGFloat, angle: Double)] {
        switch arrangement {
        case .grid: Self.layout
        case .row(let compact): compact ? Self.rowLayout.map { (x: $0.x * 0.78, y: $0.y, angle: $0.angle) } : Self.rowLayout
        }
    }

    /// The strip's whole size in this arrangement.
    private var frameSize: CGSize {
        switch arrangement {
        case .grid: Self.size
        case .row(let compact): compact ? CGSize(width: 290, height: 76) : CGSize(width: 360, height: 98)
        }
    }

    /// One photo's size inside its print.
    private var photoSize: CGSize {
        switch arrangement {
        case .grid: CGSize(width: 60, height: 62)
        case .row(let compact): compact ? CGSize(width: 62, height: 54) : CGSize(width: 84, height: 74)
        }
    }

    /// One framed print: the photo (or an empty print) on white paper in a 2-pt ink frame.
    private func printTile(at index: Int) -> some View {
        fill(at: index)
            .frame(width: photoSize.width, height: photoSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 1))
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 11, trailing: 4))
            .background(WorldPalette.rgb(0xFFFDF8), in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .background {
                RoundedRectangle(cornerRadius: 2).fill(WorldPalette.ink.opacity(0.25)).offset(y: 3)
            }
    }

    /// The photo for print `index` from the cache, or the empty print with its sprite.
    @ViewBuilder
    private func fill(at index: Int) -> some View {
        if let id = photoID(at: index), let image = images[id] {
            // A photograph: Smart Invert must not turn it into a negative.
            Image(uiImage: image).resizable().scaledToFill().accessibilityIgnoresInvertColors()
        } else {
            ZStack {
                WorldPalette.rgb(0xF3EAD6)
                WorldSpriteView(sprite: Self.emptySprites[index % Self.emptySprites.count], scale: 2)
            }
        }
    }

    // MARK: - The wall's photos

    /// The four prints' photo ids, in order (nil for a print with no photo).
    private var seedPhotoIDs: [UUID?] {
        let seeds = store.photowallSeeds
        return (0..<Self.layout.count).map { seeds.indices.contains($0) ? seeds[$0].photoID : nil }
    }

    /// Print `index`'s photo, while the wall still holds it (a deleted or reported photo leaves the
    /// print empty, and it opens the Album).
    private func payload(at index: Int) -> FriendPhotoPayload? {
        guard let id = photoID(at: index) else { return nil }
        return store.meshFeatures.photos.meshPhotos.first { $0.id == id }
    }

    /// Print `index`'s photo id, if it has one.
    private func photoID(at index: Int) -> UUID? {
        let ids = seedPhotoIDs
        return ids.indices.contains(index) ? ids[index] : nil
    }

    /// Reads the thumbnails the cache lacks, once per wall (W-04). Keeps every image it already has,
    /// and reads nothing while protected data is unavailable.
    private func loadImages() async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let wanted = seedPhotoIDs.compactMap { $0 }
        var next = images.filter { wanted.contains($0.key) }
        for id in Self.idsToRead(wanted: seedPhotoIDs, cached: Set(next.keys)) {
            guard !Task.isCancelled else { return }
            // Read and opened on the store's actor (its key provider is confined there).
            guard let data = store.meshFeatures.photos.thumbnailData(forPhotoID: id) else { continue }
            // Decoded into a bitmap off the main actor.
            if let image = await UIImage(data: data)?.byPreparingForDisplay() { next[id] = image }
        }
        guard !Task.isCancelled else { return }
        images = next
    }

    /// The photo ids the wall still has to read: each print's photo the cache doesn't hold, once.
    static func idsToRead(wanted: [UUID?], cached: Set<UUID>) -> [UUID] {
        var seen = cached
        var ids: [UUID] = []
        for id in wanted.prefix(layout.count).compactMap({ $0 }) where !seen.contains(id) {
            seen.insert(id)
            ids.append(id)
        }
        return ids
    }

    /// What keys the load: the wall's photos, and the unlock that may let a skipped read through.
    private struct LoadKey: Hashable {
        let photoIDs: [UUID?]
        let generation: Int
    }

    // MARK: - VoiceOver

    /// The name a print goes by: its hangout's name, else the friend who took it.
    static func name(of photo: FriendPhotoPayload) -> String {
        let hangout = photo.session?.meshName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return hangout.isEmpty ? photo.senderName : hangout
    }

    /// What VoiceOver calls a photo print: "Photo from Picnic, October 12".
    static func spokenTitle(of photo: FriendPhotoPayload) -> String {
        let day = photo.addedAt.formatted(.dateTime.month(.wide).day())
        return String(localized: "worldPhotos.print.label", defaultValue: "Photo from \(name(of: photo)), \(day)",
                      comment: "World Home, VoiceOver: one print on the photo wall. The hangout's name (or the friend's), then the day, e.g. Photo from Picnic, October 12")
    }

    static let label = LocalizedStringResource("worldPhotos.label", defaultValue: "Photo wall",
                                               comment: "World Home: the friend photos in the top right, for VoiceOver")
    static let hint = LocalizedStringResource("worldPhotos.hint.album", defaultValue: "Opens Album.",
                                              comment: "World Home: what tapping the photo wall does, for VoiceOver. Album is the item bar's name for the photo album (Spanish: Abre Álbum.)")
    static let photoHint = LocalizedStringResource("worldPhotos.print.hint", defaultValue: "Opens it.",
                                                   comment: "World Home, VoiceOver: what tapping a print on the photo wall does: opens that photo")
    static let emptyLabel = LocalizedStringResource("worldPhotos.print.empty", defaultValue: "Empty print",
                                                    comment: "World Home, VoiceOver: a print on the photo wall with no photo yet (it opens the Album)")
    static let shortName = LocalizedStringResource("worldPhotos.inputLabel", defaultValue: "Photos",
                                                   comment: "World Home: a short name Voice Control can use for the photo wall")
}
