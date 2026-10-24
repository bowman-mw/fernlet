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
    let onOpen: () -> Void

    /// Each print's corner and tilt in the strip (x, y, degrees), from the approved design.
    static let layout: [(x: CGFloat, y: CGFloat, angle: Double)] = [(2, 0, -4), (76, 6, 3), (6, 86, 2), (80, 92, -3)]
    /// The strip's size, which holds the four tilted prints.
    static let size = CGSize(width: 156, height: 178)
    /// The row's corners and tilts, from the approved location-off design.
    static let rowLayout: [(x: CGFloat, y: CGFloat, angle: Double)] = [(0, 0, -3), (86, 0, 2), (172, 0, -2), (258, 0, 3)]
    /// The empty prints' sprites, in order.
    private static let emptySprites = [WorldSprites.onigiri, WorldSprites.shoe, WorldSprites.photo, WorldSprites.diary]

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .topLeading) {
                ForEach(0..<positions.count, id: \.self) { index in
                    printTile(at: index)
                        .rotationEffect(.degrees(positions[index].angle))
                        .offset(x: positions[index].x, y: positions[index].y)
                        .zIndex(Double(index))
                }
            }
            .frame(width: frameSize.width, height: frameSize.height, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(Self.label))
        .accessibilityHint(Text(Self.hint))
        .accessibilityInputLabels([Text(Self.label), Text(Self.shortName)])
        .accessibilityIdentifier("world.photoWall")
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
