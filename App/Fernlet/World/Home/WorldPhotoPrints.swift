import FernletSocial
import SwiftUI
import UIKit

/// The photo wall on the map: four friend prints, two over two, in the top right beside the status
/// plate (design `b1-home-day`, draft 3: 72-pt prints in the language's ink frame, no captions, so the
/// photos speak for themselves). One button: it opens the shared album, the Friends panel's first page.
///
/// The prints are today's photo wall (`FernletStore.photowallSeeds`, chosen once per launch from the
/// friend photos). A print with no photo yet is an empty paper print with a small pixel sprite, as the
/// approved first-launch design draws it. Friends' photos stay in this strip and never go on the map.
/// At accessibility text sizes the strip gives way, as Home's photo wall does, and the album stays one
/// tap away in the item bar.
struct WorldPhotoPrints: View {
    var store: FernletStore
    let onOpen: () -> Void

    /// Each print's corner and tilt in the strip (x, y, degrees), from the approved design.
    static let layout: [(x: CGFloat, y: CGFloat, angle: Double)] = [(2, 0, -4), (76, 6, 3), (6, 86, 2), (80, 92, -3)]
    /// The strip's size, which holds the four tilted prints.
    static let size = CGSize(width: 156, height: 178)
    /// The empty prints' sprites, in order.
    private static let emptySprites = [WorldSprites.onigiri, WorldSprites.shoe, WorldSprites.photo, WorldSprites.diary]

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<Self.layout.count, id: \.self) { index in
                    printTile(at: index)
                        .rotationEffect(.degrees(Self.layout[index].angle))
                        .offset(x: Self.layout[index].x, y: Self.layout[index].y)
                        .zIndex(Double(index))
                }
            }
            .frame(width: Self.size.width, height: Self.size.height, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.label))
        .accessibilityHint(Text(Self.hint))
        .accessibilityInputLabels([Text(Self.label), Text(Self.shortName)])
        .accessibilityIdentifier("world.photoWall")
    }

    /// One framed print: the photo (or an empty print) on white paper in a 2-pt ink frame.
    private func printTile(at index: Int) -> some View {
        fill(at: index)
            .frame(width: 60, height: 62)
            .clipShape(RoundedRectangle(cornerRadius: 1))
            .padding(EdgeInsets(top: 4, leading: 4, bottom: 11, trailing: 4))
            .background(WorldPalette.rgb(0xFFFDF8), in: RoundedRectangle(cornerRadius: 2))
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .background {
                RoundedRectangle(cornerRadius: 2).fill(WorldPalette.ink.opacity(0.25)).offset(y: 3)
            }
    }

    /// The photo for print `index`, or the empty print with its sprite.
    @ViewBuilder
    private func fill(at index: Int) -> some View {
        if let image = photo(at: index) {
            // A photograph: Smart Invert must not turn it into a negative.
            Image(uiImage: image).resizable().scaledToFill().accessibilityIgnoresInvertColors()
        } else {
            ZStack {
                WorldPalette.rgb(0xF3EAD6)
                WorldSpriteView(sprite: Self.emptySprites[index % Self.emptySprites.count], scale: 2)
            }
        }
    }

    /// The friend photo behind seed `index`, when there is one and its thumbnail decodes.
    private func photo(at index: Int) -> UIImage? {
        let seeds = store.photowallSeeds
        guard seeds.indices.contains(index), let id = seeds[index].photoID,
              let data = store.meshFeatures.photos.thumbnailData(forPhotoID: id) else { return nil }
        return UIImage(data: data)
    }

    static let label = LocalizedStringResource("worldPhotos.label", defaultValue: "Photo wall",
                                               comment: "World Home: the friend photos in the top right, for VoiceOver")
    static let hint = LocalizedStringResource("worldPhotos.hint", defaultValue: "Opens the shared album in Friends.",
                                              comment: "World Home: what tapping the photo wall does, for VoiceOver")
    static let shortName = LocalizedStringResource("worldPhotos.inputLabel", defaultValue: "Photos",
                                                   comment: "World Home: a short name Voice Control can use for the photo wall")
}
