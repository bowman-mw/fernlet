import SwiftUI
import FernletDomainModel
import FernletUI
#if canImport(UIKit)
import UIKit
#endif

// The four G8 slots' pages (Hair, Eyes, Pattern, Background; the owner's picks on the "Sprout's New Looks"
// review page, 2026-11-15). Each is the same framed card of chips as the built-in slots, every chip showing
// the companion (or the scene) as it would look, then a colour row where the slot has one: Hair takes the
// hair colours, the slot colours and any colour of your own; Big and Button eyes take four eye colours.

/// A suggested colour on a G8 slot's colour row: its name and `#RRGGBB` (nil is the slot's default).
struct CustomizeHexPreset: Identifiable, Hashable {
    let name: String
    let hex: String?

    var id: String { hex ?? "default" }

    /// The hair colours first, then the slot colours every other piece offers (Mood aside: hair keeps
    /// its colour whatever the day).
    static var hair: [CustomizeHexPreset] {
        [CustomizeHexPreset(name: String(localized: "customize.hair.brown", defaultValue: "Brown", comment: "Customize › Hair colour: brown, the default"), hex: nil),
         CustomizeHexPreset(name: String(localized: "customize.hair.black", defaultValue: "Black", comment: "Customize › Hair colour: black"), hex: "#2A1A10"),
         CustomizeHexPreset(name: String(localized: "customize.hair.blond", defaultValue: "Blond", comment: "Customize › Hair colour: blond, a golden yellow"), hex: "#E2B85C"),
         CustomizeHexPreset(name: String(localized: "customize.hair.ginger", defaultValue: "Ginger", comment: "Customize › Hair colour: ginger, a red-orange"), hex: "#C0643A"),
         CustomizeHexPreset(name: String(localized: "customize.hair.grey", defaultValue: "Grey", comment: "Customize › Hair colour: grey"), hex: "#8A8F96"),
         CustomizeHexPreset(name: String(localized: "customize.hair.pink", defaultValue: "Pink", comment: "Customize › Hair colour: pink"), hex: "#D98C9A")]
            + CompanionAssetColor.allCases.filter { $0 != .state }.compactMap { slot in
                WidgetSnapshot.CompanionLook.hex(custom: nil, slot: slot).map { CustomizeHexPreset(name: slot.label, hex: $0) }
            }
    }

    /// The eye colours Big and Button eyes show.
    static var eyes: [CustomizeHexPreset] {
        [CustomizeHexPreset(name: String(localized: "customize.eyes.ink", defaultValue: "Ink", comment: "Customize › Eye colour: the face's dark ink, the default"), hex: nil),
         CustomizeHexPreset(name: String(localized: "customize.eyes.brown", defaultValue: "Brown", comment: "Customize › Eye colour: brown"), hex: "#5A3A22"),
         CustomizeHexPreset(name: String(localized: "customize.eyes.blue", defaultValue: "Blue", comment: "Customize › Eye colour: blue"), hex: "#3E5C7A"),
         CustomizeHexPreset(name: String(localized: "customize.eyes.green", defaultValue: "Green", comment: "Customize › Eye colour: green"), hex: "#3F6B3A")]
    }
}

/// A G8 slot's choices: its chips, and its colour row where it has one.
struct CustomizeLookChoices: View {
    var store: FernletStore
    let slot: CustomizeSlot

    var body: some View {
        let bindings = CustomizeAppearanceBindings(store: store)
        let appearance = store.settings.companionAppearance
        VStack(spacing: 14) {
            switch slot {
            case .hair:
                CompanionCustomizationCard(title: slot.title, items: CompanionHairStyle.allCases, selection: bindings.value(\.hairStyle),
                                           state: store.liveCompanionState, showsColor: false) { style in
                    chip(style.label) { $0.hairStyle = style }
                }
                if appearance.hairStyle != .none {
                    CustomizeHexColorCard(title: "Hair color", presets: CustomizeHexPreset.hair, hex: bindings.value(\.hairColorHex),
                                          defaultHex: WorldCompanionLook.hairBrown, allowsCustom: true)
                }
            case .eyes:
                CompanionCustomizationCard(title: slot.title, items: CompanionEyes.allCases, selection: bindings.value(\.eyeStyle),
                                           state: store.liveCompanionState, showsColor: false) { style in
                    chip(style.label) { $0.eyeStyle = style }
                }
                if appearance.eyeStyle.isLarge {
                    CustomizeHexColorCard(title: "Eye color", presets: CustomizeHexPreset.eyes, hex: bindings.value(\.eyeColorHex),
                                          defaultHex: WorldCompanionPainter.ink, allowsCustom: false)
                }
            case .pattern:
                CompanionCustomizationCard(title: slot.title, items: CompanionPattern.allCases, selection: bindings.value(\.pattern),
                                           state: store.liveCompanionState, showsColor: false) { pattern in
                    chip(pattern.label) { $0.pattern = pattern }
                }
            default:
                CompanionCustomizationCard(title: slot.title, items: CompanionBackground.allCases, selection: bindings.value(\.background),
                                           state: store.liveCompanionState, showsColor: false) { background in
                    sceneChip(background)
                }
            }
        }
    }

    /// A chip: the companion as it would look with `change`, at one and a half points a pixel, and the name.
    private func chip(_ name: String, change: (inout CompanionAppearance) -> Void) -> some View {
        var appearance = store.settings.companionAppearance
        change(&appearance)
        let state = store.liveCompanionState
        let look = WorldCompanionLook(appearance: appearance, state: state, asleep: false, items: store.equippedCustomItems)
        let grid = WorldCompanionPainter.paint(state: state, look: look, pose: WorldCompanionPose())
        return HStack(spacing: 8) {
            WorldCompanionCanvas(grid: grid, scale: 1.5, footprint: .frame)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }

    /// A background chip: the scene itself, small, and its name.
    private func sceneChip(_ background: CompanionBackground) -> some View {
        HStack(spacing: 8) {
            Group {
                if background == .none {
                    RoundedRectangle(cornerRadius: 3).fill(WorldPalette.adaptive(light: 0xE7E2D4, dark: 0x2A2017))
                } else {
                    WorldCompanionSceneBackdrop(kind: WorldCompanionSceneKind(background))
                }
            }
            .frame(width: 40, height: 35)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(WorldPalette.ink, lineWidth: 1.5))
            .accessibilityHidden(true)
            Text(verbatim: background.label)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
        }
    }
}

/// A colour row for a G8 slot: framed chips for the suggested colours, and (for hair) the custom picker.
struct CustomizeHexColorCard: View {
    var title: LocalizedStringKey
    let presets: [CustomizeHexPreset]
    @Binding var hex: String?
    /// The colour a nil hex wears, for the custom picker's starting point.
    let defaultHex: UInt32
    let allowsCustom: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    SectionLabel(title)
                    Spacer()
                    if allowsCustom {
                        ColorPicker("Custom color", selection: custom, supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10),
                                         count: dynamicTypeSize.isAccessibilitySize ? 1 : 3), spacing: 10) {
                    ForEach(presets) { preset in
                        presetButton(preset)
                    }
                }
            }
        }
    }

    private func presetButton(_ preset: CustomizeHexPreset) -> some View {
        let isSelected = Self.same(hex, preset.hex)
        return Button {
            if !isSelected { FernletFeedback.system.play(.tick) }
            hex = preset.hex
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(WorldPalette.rgb(WorldCompanionLook.value(preset.hex) ?? defaultHex))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 1.5))
                Text(verbatim: preset.name)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(ChipButtonStyle(selected: isSelected))
        .accessibilityLabel(Text(verbatim: preset.name))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    /// The custom colour as the `ColorPicker` edits it: the worn colour, written back as `#RRGGBB`.
    private var custom: Binding<Color> {
        Binding(
            get: { WorldPalette.rgb(WorldCompanionLook.value(hex) ?? defaultHex) },
            set: { newValue in
                #if canImport(UIKit)
                hex = UIColor(newValue).hexString
                #endif
            }
        )
    }

    /// Whether two `#RRGGBB` strings name the same colour (nil only matches nil).
    static func same(_ lhs: String?, _ rhs: String?) -> Bool {
        WorldCompanionLook.value(lhs?.uppercased()) == WorldCompanionLook.value(rhs?.uppercased())
    }
}

/// A G8 slot's tile on its Customize row: the hair's colour, an eye, a dotted body, or the scene itself.
struct CustomizeLookIcon: View {
    let slot: CustomizeSlot
    let appearance: CompanionAppearance
    let state: CompanionState
    var scale: CGFloat = 2

    var body: some View {
        switch slot {
        case .hair where appearance.hairStyle != .none:
            Circle()
                .fill(WorldPalette.rgb(WorldCompanionLook.value(appearance.hairColorHex) ?? WorldCompanionLook.hairBrown))
                .frame(width: 11 * scale, height: 11 * scale)
                .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 2))
        case .background where appearance.background != .none:
            WorldCompanionSceneBackdrop(kind: WorldCompanionSceneKind(appearance.background))
                .frame(width: 13 * scale, height: 11 * scale)
                .clipShape(RoundedRectangle(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(WorldPalette.ink, lineWidth: 1.5))
        default:
            CustomizePieceIcon(sprite: nil, systemImage: symbol, scale: scale)
        }
    }

    /// The tile's symbol where there is nothing of the person's to draw.
    private var symbol: String {
        switch slot {
        case .eyes: "eye"
        case .pattern: "circle.dotted"
        case .background: "photo"
        default: "circle.slash"
        }
    }
}
