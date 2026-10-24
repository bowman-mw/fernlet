import SwiftUI
import FernletDomainModel
import FernletUI

/// The two previews at the top of Customize, a slot and Save item (designs `b2-customize`,
/// `b2-slot-picker`, `b2-studio-save`): the companion close up, and the pixel companion as it stands
/// on the map in a small framed box.
///
/// The close-up is the full companion, so what the Wardrobe made shows the moment it is worn; the map
/// draws only the built-in pieces as pixels. Decorative: the controls below carry the meaning.
struct CustomizePreviewCard: View {
    var store: FernletStore
    var petCount: Int
    /// Extra pieces worn in the previews (the Studio's drawing, before it is saved).
    var previewItems: [CustomizationItem]? = nil
    /// What VoiceOver hears, where the previews are the page's only sign of the drawing (Save item);
    /// nil keeps them decorative.
    var spokenName: Text? = nil

    var body: some View {
        FernletCard {
            HStack(alignment: .bottom, spacing: 34) {
                VStack(spacing: 6) {
                    closeUp
                    caption(Text("Close up"))
                }
                VStack(spacing: 6) {
                    mapPreview
                    caption(Text("On the map"))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spokenName ?? Text(verbatim: ""))
        .accessibilityHidden(spokenName == nil)
    }

    /// The companion close up: the pixel companion, or the full one while a Wardrobe piece is worn.
    @ViewBuilder
    private var closeUp: some View {
        let worn = previewItems ?? store.equippedCustomItems
        if worn.isEmpty {
            OnboardingPixelCompanion(appearance: store.settings.companionAppearance, state: store.companionState, scale: 6)
                .fixedSize()
        } else {
            CompanionView(state: store.companionState, appearance: store.settings.companionAppearance,
                          size: 104, interactionLevel: petCount, equippedItems: worn)
                .frame(width: 104, height: 104)
        }
    }

    /// The pixel companion in the map's framed grey box.
    private var mapPreview: some View {
        let state = store.companionState
        let look = WorldCompanionLook(appearance: store.settings.companionAppearance, state: state, asleep: false)
        let grid = WorldCompanionPainter.paint(state: state, look: look,
                                               pose: WorldCompanionPose(breathIn: false, settled: false, asleep: false))
        return WorldCompanionCanvas(grid: grid, scale: 3)
            .frame(width: CGFloat(WorldCompanionGrid.width) * 3, height: CGFloat(WorldCompanionGrid.height) * 3)
            .frame(width: 80, height: 80)
            .background(WorldPalette.adaptive(light: 0xE7E2D4, dark: 0x2A2017), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldPalette.ink, lineWidth: 3))
    }

    private func caption(_ text: Text) -> some View {
        text
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.dim)
    }
}

/// The coin balance in Customize's framed pill (design `b2-customize`): the pixel coin and the number.
/// At accessibility text sizes the coin steps aside and the number stays.
struct CustomizeCoinPill: View {
    let balance: Int
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        HStack(spacing: 6) {
            if !dynamicTypeSize.isAccessibilitySize {
                WorldSpriteView(sprite: WorldSprites.coin, scale: 3)
            }
            Text(balance, format: .number)
                .font(FernletFramedFont.button)
                .foregroundStyle(look?.text ?? Color.bark)
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 44)
        .background(look?.raised ?? Color.cream, in: shape)
        .overlay { if let look { shape.strokeBorder(look.ink, lineWidth: FernletFramedLook.frameWidth) } }
        .background { if let look { shape.fill(look.shadow).offset(y: 3) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: FernletUICopy.coinBalance(balance)))
        .accessibilityIdentifier("customize.coinBalance")
    }
}

/// A framed link card (Wardrobe, Creation Studio, “Design a new item”, “Design & recolor in Wardrobe”):
/// a framed icon tile, a title and an optional second line, then the pixel chevron.
struct CustomizeLinkCard: View {
    let sprite: WorldSprite
    let title: Text
    var detail: Text? = nil
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            HStack(spacing: 8) {
                FernletIconTile(size: 40) { WorldSpriteView(sprite: sprite, scale: 2) }
                VStack(alignment: .leading, spacing: 2) {
                    title
                        .font(FernletFramedFont.rowTitle.weight(.semibold))
                        .foregroundStyle(look?.text ?? Color.bark)
                    if let detail {
                        detail
                            .font(FernletFramedFont.rowDetail)
                            .foregroundStyle(look?.dim ?? Color.slate)
                    }
                }
                .fernletWrappingText()
                // The words take every point the tile and chevron leave, so a word ("Wardrobe") never
                // breaks in half in the narrow two-up cards.
                .frame(maxWidth: .infinity, alignment: .leading)
                FernletIcon(.chevron, scale: 2)
            }
        }
        .contentShape(Rectangle())
    }
}

/// The App colors row on Customize (design `b2-customize`, redrawn for the owner's colour note): the
/// name, “Paper, wood and accent”, and the three colours in use as framed swatches.
struct CustomizeAppColorsCard: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        FernletCard {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("App colors")
                        .font(FernletFramedFont.rowTitle.weight(.semibold))
                        .foregroundStyle(look?.text ?? Color.bark)
                    Text("Paper, wood and accent")
                        .font(FernletFramedFont.rowDetail)
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
                .fernletWrappingText()
                Spacer(minLength: 4)
                HStack(spacing: 5) {
                    ForEach(Array(swatches.enumerated()), id: \.offset) { _, colour in
                        AppColorSwatchChip(colour: colour, size: 22)
                    }
                }
                .accessibilityHidden(true)
                FernletIcon(.chevron, scale: 2)
            }
        }
        .contentShape(Rectangle())
    }

    /// Paper, wood and accent as the app draws them now.
    private var swatches: [Color] {
        [look?.paper ?? Color.cream, look?.wood ?? WorldPalette.wood, look?.accent ?? Color.moss]
    }
}

/// A small colour square in a 2-pt ink frame (App colors' swatches).
struct AppColorSwatchChip: View {
    let colour: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: 5)
            .fill(colour)
            .frame(width: size, height: size)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(WorldPalette.ink, lineWidth: 2))
    }
}

/// One slot row's words on Customize (design `b2-customize`): a framed tile with the slot's piece, the
/// slot's name in the section-label style, and what is worn there, before the row's chevron.
struct CustomizeSlotRowLabel<Icon: View>: View {
    let slot: Text
    let value: String
    let isEmpty: Bool
    @ViewBuilder let icon: Icon
    @Environment(\.fernletFramedLook) private var look
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                FernletIconTile(size: 40) { icon }
                SectionLabel(slot)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(verbatim: value)
                .font(FernletFramedFont.rowValue.weight(.semibold))
                .foregroundStyle(isEmpty ? (look?.dim ?? Color.slate) : (look?.text ?? Color.bark))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(slot): \(value)"))
    }
}

/// The pixel piece for each built-in item on Customize's slot rows and the slot pickers' chips; nil
/// where no pixel piece is drawn yet (the row shows the item's symbol in ink instead).
enum CustomizeSlotArt {
    static func sprite(for accessory: CompanionAccessory) -> WorldSprite? {
        switch accessory {
        case .none: WorldSprites.xx
        case .sprout: WorldSprites.leaf
        case .flower: WorldSprites.star
        case .glasses: WorldSprites.face
        }
    }

    static func sprite(for clothing: CompanionClothing) -> WorldSprite? {
        switch clothing {
        case .none: WorldSprites.xx
        case .scarf: nil
        case .sleepCap: WorldSprites.moon
        }
    }

    static func sprite(for item: CompanionSideItem) -> WorldSprite? {
        switch item {
        case .none: WorldSprites.xx
        case .waterBottle: WorldSprites.drop
        case .mug: WorldStampArt.cup
        case .book: WorldSprites.diary
        case .dumbbell: nil
        }
    }
}

/// A slot's piece in a framed tile or chip: its pixel art, or its SF Symbol in ink where none is drawn.
struct CustomizePieceIcon: View {
    let sprite: WorldSprite?
    let systemImage: String
    var scale: CGFloat = 2

    var body: some View {
        if let sprite {
            WorldSpriteView(sprite: sprite, scale: scale)
        } else {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(WorldPalette.iconInk)
                .accessibilityHidden(true)
        }
    }
}
