import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletUI
#if canImport(UIKit)
import UIKit
#endif

/// The companion customization sheet, for the World map's hold on the companion: ``CompanionCustomizationPage``
/// in its own stack under the sheet's paper header, “Customize” with Done.
///
/// The Today panel pushes the same page under its plate (design `b2-customize`). Here the sheet blocks
/// swipe-to-dismiss while a Creation Studio pushed anywhere on its stack holds unsaved paint.
struct CompanionCustomizationSheet: View {
    var store: FernletStore
    @Binding var petCount: Int
    @Environment(\.dismiss) private var dismiss
    /// Raised by a ``CreationStudioView`` pushed anywhere on this stack while it holds unsaved paint.
    @State private var isStudioDraftDirty = false

    var body: some View {
        NavigationStack {
            CompanionCustomizationPage(store: store, petCount: $petCount, isStudioDraftDirty: $isStudioDraftDirty)
                .fernletSheetToolbar(title: "Customize", onDone: { dismiss() })
        }
        .fernletSheet()
        .interactiveDismissDisabled(isStudioDraftDirty)
    }
}

/// Customize (design `b2-customize`, approved 2026-10-23): the coin pill, the close-up and on-the-map
/// previews, Wardrobe and Creation Studio, App colors, and one row per slot (body, accessory, clothing,
/// side item), each pushing its picker (`b2-slot-picker`).
///
/// A page inside the Today panel, opened from its Customize button (and in a sheet from the map's hold,
/// ``CompanionCustomizationSheet``). All writes go through `FernletStore.setCompanionAppearance` / the
/// equip APIs, so the previews and the map stay in lockstep. Wardrobe and Studio stay reachable only
/// through this stack's push wiring (binding-driven with `onExit`), so the studio's exit never tears
/// the stack down.
struct CompanionCustomizationPage: View {
    var store: FernletStore
    @Binding var petCount: Int
    /// Raised while a pushed ``CreationStudioView`` holds unsaved paint (the sheet blocks swipe-down).
    @Binding var isStudioDraftDirty: Bool
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Drives the root-level push into a NEW item's studio (HOME-30), binding-driven with `onExit`.
    @State private var isDesigningFromRoot = false

    /// "Customize", the page's title on the plate.
    static let title = LocalizedStringResource("Customize", comment: "Customize page title: the companion's look, Wardrobe and Creation Studio")

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                topRow
                CustomizePreviewCard(store: store, petCount: petCount)
                libraryRows
                NavigationLink {
                    AppColorsPage(store: store)
                } label: {
                    CustomizeAppColorsCard()
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("companion.appColors")
                FernletFramedSection {
                    bodyRow
                    accessoryRow
                    clothingRow
                    sideItemRow
                }
                unlockedFooter
            }
            .padding(20)
        }
        .fernletPageBackground()
        .navigationDestination(isPresented: $isDesigningFromRoot) {
            CreationStudioView(store: store,
                               draftIsDirty: $isStudioDraftDirty,
                               onExit: { isDesigningFromRoot = false })
        }
    }

    /// “Tap a slot to change it.” and the coin balance (moved here from the Wardrobe, HOME-22).
    private var topRow: some View {
        HStack(alignment: .center, spacing: 12) {
            Text("Tap a slot to change it.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
            Spacer(minLength: 8)
            CustomizeCoinPill(balance: store.coinBalance)
        }
    }

    /// Wardrobe and Creation Studio side by side, or stacked at accessibility text sizes.
    private var libraryRows: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
        return layout {
            wardrobeRow
            studioRow
        }
    }

    /// The Wardrobe card: the closet with its item count. Carries the `companion.wardrobe` test token.
    private var wardrobeRow: some View {
        NavigationLink {
            WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
        } label: {
            CustomizeLinkCard(sprite: WorldSprites.face, title: Text("Wardrobe"), detail: wardrobeCountText)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.wardrobe")
    }

    private var wardrobeCountText: Text? {
        let count = store.customItems.count
        guard count > 0 else { return nil }
        return Text(verbatim: HomeCopy.wardrobeItemCount(count))
    }

    /// The Creation Studio card — a straight door to designing a new item.
    private var studioRow: some View {
        Button {
            isDesigningFromRoot = true
        } label: {
            CustomizeLinkCard(sprite: WorldSprites.pen, title: Text("Creation Studio"))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.studio")
    }

    /// The reassurance line closing the page.
    private var unlockedFooter: some View {
        Text("Everything you've unlocked stays unlocked.")
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.dim)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 2)
    }

    // MARK: Selector rows — one per slot, each showing what's worn and pushing its picker.

    private var bodyRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: CustomizeSlotTitle.body,
                items: CompanionBodyStyle.allCases,
                selection: appearanceBinding(\.bodyStyle),
                colorTitle: "Body color",
                colorSelection: colorPresetBinding(\.bodyColor, customHex: \.bodyCustomColorHex),
                customColorHex: appearanceBinding(\.bodyCustomColorHex),
                customColor: customColorBinding(\.bodyColor, customHex: \.bodyCustomColorHex),
                isBuiltInEquipped: true,
                customSlots: []
            ) { style in
                Label(style.label, systemImage: bodyStyleIcon(style))
            }
        } label: {
            CustomizeSlotRowLabel(slot: Text("Body"), value: appearance.bodyStyle.label, isEmpty: false) {
                Circle()
                    .fill(appearance.bodyColor.color(for: store.companionState))
                    .frame(width: 22, height: 22)
                    .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 2))
            }
        }
        .buttonStyle(FernletRowButtonStyle())
    }

    private var accessoryRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: CustomizeSlotTitle.accessory,
                items: CompanionAccessory.allCases,
                selection: appearanceBinding(\.accessory),
                colorTitle: "Accessory color",
                colorSelection: colorPresetBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                customColorHex: appearanceBinding(\.accessoryCustomColorHex),
                customColor: customColorBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                isBuiltInEquipped: appearance.accessory != .none,
                customSlots: [.hat, .face]
            ) { accessory in
                pieceLabel(accessory.label, sprite: CustomizeSlotArt.sprite(for: accessory), systemImage: accessoryIcon(accessory))
            }
        } label: {
            CustomizeSlotRowLabel(
                slot: Text("Accessory"),
                value: rowValue(builtInLabel: appearance.accessory.label, builtInEmpty: appearance.accessory == .none, customSlots: [.hat, .face]),
                isEmpty: appearance.accessory == .none && equippedCustomItem(in: [.hat, .face]) == nil
            ) {
                CustomizePieceIcon(sprite: CustomizeSlotArt.sprite(for: appearance.accessory), systemImage: accessoryIcon(appearance.accessory))
            }
        }
        .buttonStyle(FernletRowButtonStyle())
    }

    private var clothingRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: CustomizeSlotTitle.clothing,
                items: CompanionClothing.allCases,
                selection: appearanceBinding(\.clothing),
                colorTitle: "Clothing color",
                colorSelection: colorPresetBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                customColorHex: appearanceBinding(\.clothingCustomColorHex),
                customColor: customColorBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                isBuiltInEquipped: appearance.clothing != .none,
                customSlots: [.body]
            ) { clothing in
                pieceLabel(clothing.label, sprite: CustomizeSlotArt.sprite(for: clothing), systemImage: clothingIcon(clothing))
            }
        } label: {
            CustomizeSlotRowLabel(
                slot: Text("Clothing"),
                value: rowValue(builtInLabel: appearance.clothing.label, builtInEmpty: appearance.clothing == .none, customSlots: [.body]),
                isEmpty: appearance.clothing == .none && equippedCustomItem(in: [.body]) == nil
            ) {
                CustomizePieceIcon(sprite: CustomizeSlotArt.sprite(for: appearance.clothing), systemImage: clothingIcon(appearance.clothing))
            }
        }
        .buttonStyle(FernletRowButtonStyle())
    }

    private var sideItemRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: CustomizeSlotTitle.sideItem,
                items: CompanionSideItem.allCases,
                selection: appearanceBinding(\.sideItem),
                colorTitle: "Item color",
                colorSelection: colorPresetBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                customColorHex: appearanceBinding(\.sideItemCustomColorHex),
                customColor: customColorBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                isBuiltInEquipped: appearance.sideItem != .none,
                customSlots: [.heldItem]
            ) { item in
                pieceLabel(item.label, sprite: CustomizeSlotArt.sprite(for: item), systemImage: item.systemImage)
            }
        } label: {
            CustomizeSlotRowLabel(
                slot: Text("Side item"),
                value: rowValue(builtInLabel: appearance.sideItem.label, builtInEmpty: appearance.sideItem == .none, customSlots: [.heldItem]),
                isEmpty: appearance.sideItem == .none && equippedCustomItem(in: [.heldItem]) == nil
            ) {
                CustomizePieceIcon(sprite: CustomizeSlotArt.sprite(for: appearance.sideItem), systemImage: appearance.sideItem.systemImage)
            }
        }
        .buttonStyle(FernletRowButtonStyle())
    }

    /// A built-in item's chip label: its pixel piece (or symbol) and its name.
    private func pieceLabel(_ name: String, sprite: WorldSprite?, systemImage: String) -> some View {
        HStack(spacing: 8) {
            CustomizePieceIcon(sprite: sprite, systemImage: systemImage)
            Text(verbatim: name)
        }
    }

    /// The value shown on a slot row: the built-in label when a built-in is on; otherwise the name of
    /// an equipped custom item folded into this slot; otherwise the built-in's "None" label.
    private func rowValue(builtInLabel: String, builtInEmpty: Bool, customSlots: [ItemSlot]) -> String {
        if !builtInEmpty { return builtInLabel }
        if let item = equippedCustomItem(in: customSlots) {
            return item.name.isEmpty ? item.slot.label : item.name
        }
        return builtInLabel
    }

    /// The first equipped custom item whose slot is folded into this row, if any.
    private func equippedCustomItem(in slots: [ItemSlot]) -> CustomizationItem? {
        store.equippedCustomItems.first { slots.contains($0.slot) }
    }

    /// A slot's page (design `b2-slot-picker`): the previews, the built-in choices and their colours as
    /// framed chips, then the user's own items for the slot(s) this row covers and the way into the
    /// Wardrobe. Built-ins keep the swatch/ColorPicker recolor; custom items carry their own painted
    /// colours and so get no colour control.
    private func slotPicker<Item: Identifiable & Hashable, LabelContent: View>(
        title: LocalizedStringResource,
        items: [Item],
        selection: Binding<Item>,
        colorTitle: LocalizedStringKey,
        colorSelection: Binding<CompanionAssetColor>,
        customColorHex: Binding<String?>,
        customColor: Binding<Color>,
        isBuiltInEquipped: Bool,
        customSlots: [ItemSlot],
        @ViewBuilder label: @escaping (Item) -> LabelContent
    ) -> some View {
        ScrollView {
            VStack(spacing: 14) {
                CustomizePreviewCard(store: store, petCount: petCount)
                CompanionCustomizationCard(
                    title: title,
                    items: items,
                    selection: selection,
                    colorTitle: colorTitle,
                    colorSelection: colorSelection,
                    customColorHex: customColorHex,
                    customColor: customColor,
                    state: store.companionState,
                    // Recolor is a built-in-only control: hidden when no built-in is equipped in
                    // this slot (custom items paint their own colors).
                    showsColor: isBuiltInEquipped,
                    label: label
                )
                customItemsSection(for: customSlots)
            }
            .padding(20)
        }
        .fernletPageBackground()
        .fernletPushedPage(title)
    }

    /// The custom-item part of a slot's page: the user's own items for the covered slot(s), each
    /// tappable to equip/unequip, then the standing way into the Wardrobe (which still owns designing,
    /// editing and recolouring custom items).
    @ViewBuilder
    private func customItemsSection(for slots: [ItemSlot]) -> some View {
        let items = store.customItems.filter { slots.contains($0.slot) }
        if !slots.isEmpty {
            if !items.isEmpty {
                FernletFramedSection("Your items") {
                    ForEach(items) { item in
                        customItemButton(item)
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

    /// One custom-item row inside a slot's page. Tap to equip; tap the equipped item to unequip.
    private func customItemButton(_ item: CustomizationItem) -> some View {
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
        .accessibilityLabel(customItemSpokenName(item, isEquipped: isEquipped))
    }

    /// What VoiceOver says for a custom-item row: its name and whether it is worn. Two whole keys,
    /// not one "%@, %@" with an English state word spliced into its second slot (that word never
    /// reached the catalog). The name is the user's own, or the slot's label when they left it blank.
    private func customItemSpokenName(_ item: CustomizationItem, isEquipped: Bool) -> Text {
        let name = item.name.isEmpty ? item.slot.label : item.name
        return isEquipped
            ? Text("\(name), equipped", comment: "Customize sheet, VoiceOver: one of the user's own companion items, currently worn. The placeholder is the item's name.")
            : Text("\(name), not equipped", comment: "Customize sheet, VoiceOver: one of the user's own companion items, not worn right now. The placeholder is the item's name.")
    }

    private func appearanceBinding<Value>(_ keyPath: WritableKeyPath<CompanionAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: keyPath] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: keyPath] = newValue
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func colorPresetBinding(
        _ presetKeyPath: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
        customHex customKeyPath: WritableKeyPath<CompanionAppearance, String?>
    ) -> Binding<CompanionAssetColor> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: presetKeyPath] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: presetKeyPath] = newValue
                appearance[keyPath: customKeyPath] = nil
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func customColorBinding(
        _ presetKeyPath: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
        customHex customKeyPath: WritableKeyPath<CompanionAppearance, String?>
    ) -> Binding<Color> {
        Binding(
            get: {
                let appearance = store.settings.companionAppearance
                if let hex = appearance[keyPath: customKeyPath], let color = Color(fernletHex: hex) {
                    return color
                }
                return appearance[keyPath: presetKeyPath].color(for: store.companionState)
            },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: customKeyPath] = newValue.fernletHexString
                store.setCompanionAppearance(appearance)
            }
        )
    }

    /// One glyph per body shape. All four used to draw the same "seal", so the icons carried no
    /// information at all and the live preview above was the only cue to what a row would do.
    private func bodyStyleIcon(_ style: CompanionBodyStyle) -> String {
        switch style {
        case .circle: "circle"
        case .softBlob: "oval"
        case .pear: "drop"
        case .puddle: "capsule"
        }
    }

    private func accessoryIcon(_ accessory: CompanionAccessory) -> String {
        switch accessory {
        case .none: "circle.slash"
        case .sprout: "leaf"
        case .flower: "camera.macro"
        case .glasses: "eyeglasses"
        }
    }

    private func clothingIcon(_ clothing: CompanionClothing) -> String {
        switch clothing {
        case .none: "circle.slash"
        case .scarf: "wind"
        case .sleepCap: "moon"
        }
    }

}

private extension Color {
    init?(fernletHex: String) {
        guard let uiColor = UIColor(hex: fernletHex) else { return nil }
        self.init(uiColor)
    }

    var fernletHexString: String? {
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
/// side items; selection and color flow back through the bindings
/// `CompanionCustomizationPage` builds onto the store.
private struct CompanionCustomizationCard<Item: Identifiable & Hashable, LabelContent: View>: View {
    /// The slot's name ("Accessory"), a catalog resource.
    var title: LocalizedStringResource
    var items: [Item]
    @Binding var selection: Item
    var colorTitle: LocalizedStringKey
    @Binding var colorSelection: CompanionAssetColor
    @Binding var customColorHex: String?
    @Binding var customColor: Color
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
                ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                    .labelsHidden()
            }
            LazyVGrid(columns: columns(3), spacing: 10) {
                ForEach(CompanionAssetColor.allCases) { color in
                    colorButton(for: color)
                }
            }
        }
    }

    private func colorButton(for color: CompanionAssetColor) -> some View {
        let isSelected = customColorHex == nil && colorSelection == color
        return Button {
            if !isSelected { FernletFeedback.system.play(.tick) }
            colorSelection = color
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.color(for: state))
                    .frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 1.5))
                Text(color.label)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, minHeight: 30)
        }
        .buttonStyle(ChipButtonStyle(selected: isSelected))
        .accessibilityLabel(color.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// The four slots' names, for their pages' titles on the plate (and the sheet's bar).
enum CustomizeSlotTitle {
    static let body = LocalizedStringResource("Body", comment: "Customize: the body slot's page title and row name")
    static let accessory = LocalizedStringResource("Accessory", comment: "Customize: the accessory slot's page title and row name")
    static let clothing = LocalizedStringResource("Clothing", comment: "Customize: the clothing slot's page title and row name")
    static let sideItem = LocalizedStringResource("Side item", comment: "Customize: the side-item slot's page title and row name")
}
