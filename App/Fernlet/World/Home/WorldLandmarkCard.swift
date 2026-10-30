import FernletUI
import SwiftUI
import WorldMapStore

/// A found landmark's card (`ex-landmark`: "Tapping a found landmark shows its card as approved"; the kit's
/// `.excard`): over the dimmed map, a paper card in a 3-pt ink frame with ✕ top right; the art in full colour, the
/// name in Fraunces, "Landmark · Portland", and "Found on your walk today. Your passport keeps it with Portland."
/// A modal to VoiceOver; ✕, a tap on the dim and Escape close it.
struct WorldLandmarkCard: View {
    let model: WorldLandmarkCardModel
    let images: WorldLandmarkImages
    let onClose: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack(alignment: .bottom) {
            WorldPalette.rgb(0x1E140A).opacity(0.35)
                .ignoresSafeArea()
                .onTapGesture(perform: onClose)
                .accessibilityHidden(true)
            card
                .padding(.horizontal, 18)
                .padding(.bottom, WorldMapHome.bottomLift)
        }
        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .bottom)))
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                if let image = images.image(for: model.landmark, look: WorldLandmarkLook(found: true, dark: colorScheme == .dark)) {
                    WorldLandmarkArtView(image: image, scale: Self.artScale(image))
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: WorldExploreCopy.name(of: model.landmark))
                        .font(FernletFramedFont.cardTitle)
                        .foregroundStyle(WorldPalette.bark)
                        .accessibilityAddTraits(.isHeader)
                    Text(verbatim: WorldExploreCopy.cardKind(city: model.cityName))
                        .font(FernletFramedFont.note)
                        .foregroundStyle(WorldPalette.dim)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                FernletCloseButton(action: onClose)
                    .accessibilityIdentifier("world.landmark.card.close")
            }
            Text(verbatim: WorldExploreCopy.cardFound(on: model.foundAt, city: model.cityName))
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            // The drop shadow is the frame's alone: no text shadows.
            RoundedRectangle(cornerRadius: 14).fill(WorldPalette.paper)
                .shadow(color: WorldPalette.rgb(0x281408).opacity(0.3), radius: 0, x: 0, y: 4)
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityAction(.escape, onClose)
        .accessibilityIdentifier("world.landmark.card")
    }

    /// Points per art pixel on the card: 2, or 1 for art over 40 pixels tall, so the art stays within about 80 pt.
    static func artScale(_ image: CGImage) -> CGFloat {
        image.height > 40 ? 1 : 2
    }
}
