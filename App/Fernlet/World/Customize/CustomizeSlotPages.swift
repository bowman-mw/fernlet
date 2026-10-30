import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletUI
#if canImport(UIKit)
import UIKit
#endif

// Customize's four slots (designs `b2-customize`, `b2-slot-picker`), made reusable for round 7's Sprout's
// passport (World-Passport-Spec §4): Customize's slot rows and page 1's slot buttons read one summary and push
// one page per slot, so the two can never show different values or pick through different code.

/// One of the companion's four slots: Body, Accessory, Clothing and Side item, in Customize's order.
nonisolated enum CustomizeSlot: CaseIterable, Hashable, Sendable {
    case body
    case accessory
    case clothing
    case sideItem

    /// The slot's name: its page's title and its row's caption.
    var title: LocalizedStringResource {
        switch self {
        case .body: CustomizeSlotTitle.body
        case .accessory: CustomizeSlotTitle.accessory
        case .clothing: CustomizeSlotTitle.clothing
        case .sideItem: CustomizeSlotTitle.sideItem
        }
    }

    /// The Creation Studio slots folded into this one (none for the body).
    var customSlots: [ItemSlot] {
        switch self {
        case .body: []
        case .accessory: [.hat, .face]
        case .clothing: [.body]
        case .sideItem: [.heldItem]
        }
    }

    /// A stable token for accessibility identifiers ("body", "sideItem"). Never shown.
    var token: String {
        switch self {
        case .body: "body"
        case .accessory: "accessory"
        case .clothing: "clothing"
        case .sideItem: "sideItem"
        }
    }

    /// One glyph per body shape. All four used to draw the same "seal", so the icons carried no
    /// information at all and the live preview above was the only cue to what a row would do.
    static func bodyStyleIcon(_ style: CompanionBodyStyle) -> String {
        switch style {
        case .circle: "circle"
        case .softBlob: "oval"
        case .pear: "drop"
        case .puddle: "capsule"
        }
    }

    /// The accessory's SF Symbol, where no pixel piece is drawn.
    static func accessoryIcon(_ accessory: CompanionAccessory) -> String {
        switch accessory {
        case .none: "circle.slash"
        case .sprout: "leaf"
        case .flower: "camera.macro"
        case .glasses: "eyeglasses"
        }
    }

    /// The clothing's SF Symbol, where no pixel piece is drawn.
    static func clothingIcon(_ clothing: CompanionClothing) -> String {
        switch clothing {
        case .none: "circle.slash"
        case .scarf: "wind"
        case .sleepCap: "moon"
        }
    }
}

/// What a slot shows on its row or button: what is worn there, and whether that is nothing.
///
/// A built-in piece names itself; with no built-in on, an equipped Creation Studio item folded into the slot
/// names itself (its own name, or its slot's); otherwise the built-in's "None".
nonisolated struct CustomizeSlotSummary: Equatable, Sendable {
    let slot: CustomizeSlot
    /// What is worn there ("Pear", "Scarf", "My hat", "None").
    let value: String
    /// Whether nothing is worn there (the row draws the value dimmed).
    let isEmpty: Bool

    /// The summary of `slot` for `appearance`, with `equipped` the worn Creation Studio items.
    static func make(_ slot: CustomizeSlot, appearance: CompanionAppearance, equipped: [CustomizationItem]) -> CustomizeSlotSummary {
        let builtIn: (label: String, empty: Bool)
        switch slot {
        case .body: return CustomizeSlotSummary(slot: slot, value: appearance.bodyStyle.label, isEmpty: false)
        case .accessory: builtIn = (appearance.accessory.label, appearance.accessory == .none)
        case .clothing: builtIn = (appearance.clothing.label, appearance.clothing == .none)
        case .sideItem: builtIn = (appearance.sideItem.label, appearance.sideItem == .none)
        }
        guard builtIn.empty else { return CustomizeSlotSummary(slot: slot, value: builtIn.label, isEmpty: false) }
        guard let item = equipped.first(where: { slot.customSlots.contains($0.slot) }) else {
            return CustomizeSlotSummary(slot: slot, value: builtIn.label, isEmpty: true)
        }
        return CustomizeSlotSummary(slot: slot, value: item.name.isEmpty ? item.slot.label : item.name, isEmpty: false)
    }

    /// The four summaries for the store's companion now.
    @MainActor
    static func current(store: FernletStore) -> [CustomizeSlotSummary] {
        CustomizeSlot.allCases.map { make($0, appearance: store.settings.companionAppearance, equipped: store.equippedCustomItems) }
    }
}

/// A slot's piece in its framed tile: the body as a dot in its colour, the others their pixel piece (or symbol).
struct CustomizeSlotIcon: View {
    let slot: CustomizeSlot
    let appearance: CompanionAppearance
    let state: CompanionState
    var scale: CGFloat = 2

    var body: some View {
        switch slot {
        case .body:
            Circle()
                .fill(appearance.bodyColor.color(for: state))
                .frame(width: 11 * scale, height: 11 * scale)
                .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 2))
        case .accessory:
            CustomizePieceIcon(sprite: CustomizeSlotArt.sprite(for: appearance.accessory),
                               systemImage: CustomizeSlot.accessoryIcon(appearance.accessory), scale: scale)
        case .clothing:
            CustomizePieceIcon(sprite: CustomizeSlotArt.sprite(for: appearance.clothing),
                               systemImage: CustomizeSlot.clothingIcon(appearance.clothing), scale: scale)
        case .sideItem:
            CustomizePieceIcon(sprite: CustomizeSlotArt.sprite(for: appearance.sideItem),
                               systemImage: appearance.sideItem.systemImage, scale: scale)
        }
    }
}

/// A slot's page (design `b2-slot-picker`): the previews, the built-in choices and their colours as framed
/// chips, then the person's own items for the slot(s) it covers and the way into the Wardrobe. Built-ins keep
/// the swatch/ColorPicker recolor; custom items carry their own painted colours and get no colour control.
///
/// Pushed from Customize's slot rows and from page 1 of Sprout's passport; its Back names the page under it.
/// All writes go through `FernletStore.setCompanionAppearance` / the equip APIs, so the previews and the map
/// stay in lockstep.
struct CustomizeSlotPage: View {
    var store: FernletStore
    let slot: CustomizeSlot
    /// "Hold to peek" at night, shared with the page that pushed this one (`comp-cust-night`).
    @Binding var peek: CustomizePeek
    /// Raised while a pushed Creation Studio holds unsaved paint.
    @Binding var isStudioDraftDirty: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                // The Accessory page (the only one holding the face slot) says why glasses don't show at night
                // (`comp-slot-night`).
                CustomizePreviewSection(store: store, showsGlassesLine: slot.customSlots.contains(.face), peek: $peek)
                choices
                CustomizeSlotItems(store: store, slots: slot.customSlots, isStudioDraftDirty: $isStudioDraftDirty)
            }
            .padding(20)
        }
        .fernletPageBackground()
        .fernletPushedPage(slot.title)
    }

    /// The slot's built-in choices and colours.
    @ViewBuilder
    private var choices: some View {
        let bindings = CustomizeAppearanceBindings(store: store)
        let appearance = store.settings.companionAppearance
        switch slot {
        case .body:
            CompanionCustomizationCard(title: slot.title, items: CompanionBodyStyle.allCases, selection: bindings.value(\.bodyStyle),
                                       colorTitle: "Body color", color: bindings.color(\.bodyColor, customHex: \.bodyCustomColorHex),
                                       state: store.liveCompanionState, showsColor: true) { style in
                Label(style.label, systemImage: CustomizeSlot.bodyStyleIcon(style))
            }
        case .accessory:
            CompanionCustomizationCard(title: slot.title, items: CompanionAccessory.allCases, selection: bindings.value(\.accessory),
                                       colorTitle: "Accessory color", color: bindings.color(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                                       state: store.liveCompanionState, showsColor: appearance.accessory != .none) { accessory in
                CustomizePieceLabel(name: accessory.label, sprite: CustomizeSlotArt.sprite(for: accessory),
                                    systemImage: CustomizeSlot.accessoryIcon(accessory))
            }
        case .clothing:
            CompanionCustomizationCard(title: slot.title, items: CompanionClothing.allCases, selection: bindings.value(\.clothing),
                                       colorTitle: "Clothing color", color: bindings.color(\.clothingColor, customHex: \.clothingCustomColorHex),
                                       state: store.liveCompanionState, showsColor: appearance.clothing != .none) { clothing in
                CustomizePieceLabel(name: clothing.label, sprite: CustomizeSlotArt.sprite(for: clothing),
                                    systemImage: CustomizeSlot.clothingIcon(clothing))
            }
        case .sideItem:
            CompanionCustomizationCard(title: slot.title, items: CompanionSideItem.allCases, selection: bindings.value(\.sideItem),
                                       colorTitle: "Item color", color: bindings.color(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                                       state: store.liveCompanionState, showsColor: appearance.sideItem != .none) { item in
                CustomizePieceLabel(name: item.label, sprite: CustomizeSlotArt.sprite(for: item), systemImage: item.systemImage)
            }
        }
    }
}

/// A built-in item's chip label: its pixel piece (or symbol) and its name.
struct CustomizePieceLabel: View {
    let name: String
    let sprite: WorldSprite?
    let systemImage: String

    var body: some View {
        HStack(spacing: 8) {
            CustomizePieceIcon(sprite: sprite, systemImage: systemImage)
            Text(verbatim: name)
        }
    }
}

/// The custom-item part of a slot's page: the person's own items for the covered slot(s), each tappable to
/// equip/unequip, then the standing way into the Wardrobe (which still owns designing, editing and recolouring
/// custom items). Nothing for the body, which no Creation Studio slot folds into.
struct CustomizeSlotItems: View {
    var store: FernletStore
    let slots: [ItemSlot]
    @Binding var isStudioDraftDirty: Bool

    var body: some View {
        let items = store.customItems.filter { slots.contains($0.slot) }
        if !slots.isEmpty {
            if !items.isEmpty {
                FernletFramedSection("Your items") {
                    ForEach(items) { item in
                        itemButton(item)
                    }
                }
            }
            NavigationLink {
                WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
            } label: {
                CustomizeLinkCard(sprite: WorldSprites.face, title: Text("Design & recolor in Wardrobe"),
                                  detail: Text("Open the closet"))
            }
            .buttonStyle(.plain)
        }
    }

    /// One custom-item row. Tap to equip; tap the equipped item to unequip.
    private func itemButton(_ item: CustomizationItem) -> some View {
        let isEquipped = store.equippedCustomItems.contains { $0.id == item.id }
        return Button {
            // A choice in Customize: the tick says it took; the preview and the "Equipped" tag show it.
            FernletFeedback.system.play(.tick)
            if isEquipped {
                store.unequipCustomSlot(item.slot)
            } else {
                store.equipCustomItem(id: item.id, slot: item.slot)
            }
        } label: {
            HStack(spacing: 12) {
                CustomItemThumbnail(texture: item.texture, size: 40)
                FernletRowLabel(title: Text(verbatim: item.name.isEmpty ? item.slot.label : item.name),
                                detail: Text(verbatim: item.slot.label))
                Spacer(minLength: 8)
                if isEquipped {
                    FernletTag("Equipped")
                }
            }
        }
        .buttonStyle(FernletRowButtonStyle(showsChevron: false))
        .accessibilityLabel(Self.spokenName(item, isEquipped: isEquipped))
    }

    /// What VoiceOver says for a custom-item row: its name and whether it is worn. Two whole keys,
    /// not one "%@, %@" with an English state word spliced into its second slot (that word never
    /// reached the catalog). The name is the user's own, or the slot's label when they left it blank.
    private static func spokenName(_ item: CustomizationItem, isEquipped: Bool) -> Text {
        let name = item.name.isEmpty ? item.slot.label : item.name
        return isEquipped
            ? Text("\(name), equipped", comment: "Customize sheet, VoiceOver: one of the user's own companion items, currently worn. The placeholder is the item's name.")
            : Text("\(name), not equipped", comment: "Customize sheet, VoiceOver: one of the user's own companion items, not worn right now. The placeholder is the item's name.")
    }
}

/// The bindings a slot page writes through: each reads the store's appearance and writes a changed copy back
/// with `setCompanionAppearance`.
@MainActor
struct CustomizeAppearanceBindings {
    var store: FernletStore

    /// One appearance field.
    func value<Value>(_ keyPath: WritableKeyPath<CompanionAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: keyPath] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: keyPath] = newValue
                store.setCompanionAppearance(appearance)
            }
        )
    }

    /// A slot's colour: the preset (picking one clears the custom colour), the custom hex, and the custom
    /// colour as the `ColorPicker` edits it.
    func color(_ preset: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
               customHex: WritableKeyPath<CompanionAppearance, String?>) -> CustomizeColorBindings {
        CustomizeColorBindings(preset: presetBinding(preset, customHex: customHex), customHex: value(customHex),
                               custom: customBinding(preset, customHex: customHex))
    }

    private func presetBinding(_ preset: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
                               customHex: WritableKeyPath<CompanionAppearance, String?>) -> Binding<CompanionAssetColor> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: preset] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: preset] = newValue
                appearance[keyPath: customHex] = nil
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func customBinding(_ preset: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
                               customHex: WritableKeyPath<CompanionAppearance, String?>) -> Binding<Color> {
        Binding(
            get: {
                let appearance = store.settings.companionAppearance
                if let hex = appearance[keyPath: customHex], let color = Color(customizeHex: hex) {
                    return color
                }
                return appearance[keyPath: preset].color(for: store.liveCompanionState)
            },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: customHex] = newValue.customizeHexString
                store.setCompanionAppearance(appearance)
            }
        )
    }
}

/// A slot colour's three bindings (``CustomizeAppearanceBindings/color(_:customHex:)``).
struct CustomizeColorBindings {
    let preset: Binding<CompanionAssetColor>
    let customHex: Binding<String?>
    let custom: Binding<Color>
}

private extension Color {
    init?(customizeHex: String) {
        guard let uiColor = UIColor(hex: customizeHex) else { return nil }
        self.init(uiColor)
    }

    var customizeHexString: String? {
        #if canImport(UIKit)
        UIColor(self).hexString
        #else
        nil
        #endif
    }
}

/// The built-in choices and colours on a slot's page (design `b2-slot-picker`): a two-column grid of
/// framed chips (the selected one in the accent), then the preset colours as framed chips with a dot,
/// and the custom `ColorPicker`.
///
/// Generic over the slot's item type so one card serves body styles, accessories, clothing, and
/// side items; selection and color flow back through the bindings ``CustomizeAppearanceBindings`` builds
/// onto the store.
private struct CompanionCustomizationCard<Item: Identifiable & Hashable, LabelContent: View>: View {
    /// The slot's name ("Accessory"), a catalog resource.
    var title: LocalizedStringResource
    var items: [Item]
    @Binding var selection: Item
    var colorTitle: LocalizedStringKey
    var color: CustomizeColorBindings
    var state: CompanionState
    /// Whether the built-in recolor control is shown. Off when no built-in is equipped in this slot —
    /// custom items carry their own painted colors and get no color control.
    var showsColor: Bool = true
    @ViewBuilder var label: (Item) -> LabelContent
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(verbatim: String(localized: title))
                LazyVGrid(columns: columns(2), spacing: 10) {
                    ForEach(items) { item in
                        itemChip(item)
                    }
                }
                if showsColor {
                    colorSection
                }
            }
        }
    }

    /// `count` equal columns, or one at accessibility text sizes.
    private func columns(_ count: Int) -> [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 10), count: dynamicTypeSize.isAccessibilitySize ? 1 : count)
    }

    private func itemChip(_ item: Item) -> some View {
        let isSelected = selection.id == item.id
        return Button {
            // Re-tapping the current pick changes nothing, so it says nothing.
            if !isSelected { FernletFeedback.system.play(.tick) }
            selection = item
        } label: {
            label(item)
                .frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(ChipButtonStyle(selected: isSelected))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var colorSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(colorTitle)
                Spacer()
                ColorPicker("Custom color", selection: color.custom, supportsOpacity: false)
                    .labelsHidden()
            }
            LazyVGrid(columns: columns(3), spacing: 10) {
                ForEach(CompanionAssetColor.allCases) { preset in
                    colorButton(for: preset)
                }
            }
        }
    }

    private func colorButton(for preset: CompanionAssetColor) -> some View {
        let isSelected = color.customHex.wrappedValue == nil && color.preset.wrappedValue == preset
        return Button {
            if !isSelected { FernletFeedback.system.play(.tick) }
            color.preset.wrappedValue = preset
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(preset.color(for: state))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 1.5))
                Text(preset.label)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(ChipButtonStyle(selected: isSelected))
        .accessibilityLabel(preset.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
