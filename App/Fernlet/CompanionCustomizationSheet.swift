import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletUI
#if canImport(UIKit)
import UIKit
#endif

/// The companion customization sheet (reached by the Customize chip under the hero companion, or
/// the legacy long-press, and on the World map by holding the companion): the template
/// ``SheetHeader`` with the coin balance leading, a live companion preview beside named Wardrobe /
/// Creation Studio rows, and one selector row per slot (body / accessory / clothing / side item).
///
/// Each slot row pushes a picker that combines the built-in item grid + recolor controls with the
/// user's own Wardrobe-designed items for the covered `ItemSlot`s; all writes go through
/// `FernletStore.setCompanionAppearance` / the equip APIs, so the preview and the Home hero stay
/// in lockstep. Wardrobe and Studio stay reachable ONLY through this stack's push wiring
/// (binding-driven with `onExit`) so an environment dismiss can never tear the sheet down.
struct CompanionCustomizationSheet: View {
    var store: FernletStore
    @Binding var petCount: Int
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Raised by a ``CreationStudioView`` pushed anywhere on this stack while it holds unsaved paint.
    /// The studio is a PUSH inside this sheet, so without this a swipe-down from the studio threw the
    /// drawing away with no prompt.
    @State private var isStudioDraftDirty = false
    /// Drives the root-level push into a NEW item's studio (HOME-30). A binding-driven push with
    /// `onExit`, mirroring ``WardrobeView``'s wiring, because the studio must be popped by its
    /// host — its environment `dismiss` from the confirmation step tears the whole sheet down
    /// (see ``CreationStudioView/leaveStudio()``).
    @State private var isDesigningFromRoot = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // The template chrome (XCUT-14/XCUT-15): left-aligned Fraunces title with Done as
                // the trailing text button, replacing the centred system title + toolbar Done. The
                // coin balance leads — a balance is information, not an action, so it never takes
                // the slot that dismisses the sheet.
                SheetHeader(
                    title: Text("Customize"),
                    subtitle: Text("Tap a slot to change it."),
                    onDone: { dismiss() }
                ) {
                    coinAccessory
                }
                ScrollView {
                    VStack(spacing: 9) {
                        companionAndLibraryRows
                        bodyRow
                        accessoryRow
                        clothingRow
                        sideItemRow
                        unlockedFooter
                    }
                    .padding(20)
                }
            }
            .background(Color.parchment)
            .tint(Color.moss)
            // The root draws its own SheetHeader; pushed screens (slot pickers, Wardrobe, Studio)
            // keep their system navigation bars and back buttons.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $isDesigningFromRoot) {
                CreationStudioView(store: store,
                                   draftIsDirty: $isStudioDraftDirty,
                                   onExit: { isDesigningFromRoot = false })
            }
        }
        .interactiveDismissDisabled(isStudioDraftDirty)
    }

    /// The leading header slot: the wallet, moved here from the Wardrobe's toolbar (HOME-22 /
    /// XCUT-14). 3e·AX3: the balance keeps its slot but drops the coin glyph.
    @ViewBuilder
    private var coinAccessory: some View {
        if dynamicTypeSize.isAccessibilitySize {
            Text(verbatim: "\(store.coinBalance)")
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
                // The pill's own spoken balance (`FernletUICopy`, plural-ruled), so the numeral form
                // and the pill it replaces say the same words.
                .accessibilityLabel(Text(verbatim: FernletUICopy.coinBalance(store.coinBalance)))
                .accessibilityIdentifier("customize.coinBalance")
        } else {
            CoinBalancePill(balance: store.coinBalance)
                .accessibilityIdentifier("customize.coinBalance")
        }
    }

    /// The companion preview beside the Wardrobe / Creation Studio rows (HOME-30: both become
    /// named rows at the sheet root, one chevron each). 3e·AX3: the companion stops sharing the
    /// row and sits above them, centred.
    @ViewBuilder
    private var companionAndLibraryRows: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: 9) {
                companionPreview.frame(maxWidth: .infinity)
                wardrobeRow
                studioRow
            }
        } else {
            HStack(alignment: .center, spacing: 12) {
                companionPreview
                VStack(spacing: 9) {
                    wardrobeRow
                    studioRow
                }
            }
        }
    }

    /// The live 84pt companion preview; every write below refreshes it via the store.
    private var companionPreview: some View {
        CompanionView(
            state: store.companionState,
            appearance: store.settings.companionAppearance,
            size: 84,
            interactionLevel: petCount,
            equippedItems: store.equippedCustomItems
        )
        .frame(width: 84, height: 84)
        // Decorative: a live preview of the edits being made below, not a control.
        .accessibilityHidden(true)
    }

    /// The named Wardrobe row: the closet with its item count, one chevron. Carries the
    /// `companion.wardrobe` test token — this is the primary Wardrobe entry now.
    private var wardrobeRow: some View {
        NavigationLink {
            WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
        } label: {
            libraryRowLabel(
                systemImage: "tshirt.fill",
                title: Text("Wardrobe"),
                detail: wardrobeCountText
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.wardrobe")
    }

    private var wardrobeCountText: Text? {
        let count = store.customItems.count
        guard count > 0 else { return nil }
        return Text(verbatim: HomeCopy.wardrobeItemCount(count))
    }

    /// The named Creation Studio row — a straight door to designing a new item.
    private var studioRow: some View {
        Button {
            isDesigningFromRoot = true
        } label: {
            libraryRowLabel(
                systemImage: "paintbrush.pointed.fill",
                title: Text("Creation Studio"),
                detail: nil
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.studio")
    }

    /// Shared chrome for the Wardrobe / Studio rows: icon tile, title, optional count, one chevron.
    private func libraryRowLabel(systemImage: String, title: Text, detail: Text?) -> some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            title
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
            Spacer(minLength: 8)
            if let detail {
                detail
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.slate)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream)
        )
    }

    /// The reassurance line closing the sheet root.
    private var unlockedFooter: some View {
        Text("Everything you've unlocked stays unlocked.")
            .font(.fernlet(.bodySmall))
            .italic()
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 8)
    }

    // MARK: Selector rows — one per slot, each showing what's equipped and pushing its picker.

    private var bodyRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Body",
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
            slotRowLabel(
                slot: "Body",
                value: appearance.bodyStyle.label,
                isEmpty: false
            ) {
                Circle()
                    .fill(appearance.bodyColor.color(for: store.companionState))
            }
        }
        .buttonStyle(.plain)
    }

    private var accessoryRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Accessory",
                items: CompanionAccessory.allCases,
                selection: appearanceBinding(\.accessory),
                colorTitle: "Accessory color",
                colorSelection: colorPresetBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                customColorHex: appearanceBinding(\.accessoryCustomColorHex),
                customColor: customColorBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                isBuiltInEquipped: appearance.accessory != .none,
                customSlots: [.hat, .face]
            ) { accessory in
                Label(accessory.label, systemImage: accessoryIcon(accessory))
            }
        } label: {
            slotRowLabel(
                slot: "Accessory",
                value: rowValue(builtInLabel: appearance.accessory.label, builtInEmpty: appearance.accessory == .none, customSlots: [.hat, .face]),
                isEmpty: appearance.accessory == .none && equippedCustomItem(in: [.hat, .face]) == nil
            ) {
                slotIcon(accessoryIcon(appearance.accessory))
            }
        }
        .buttonStyle(.plain)
    }

    private var clothingRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Clothing",
                items: CompanionClothing.allCases,
                selection: appearanceBinding(\.clothing),
                colorTitle: "Clothing color",
                colorSelection: colorPresetBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                customColorHex: appearanceBinding(\.clothingCustomColorHex),
                customColor: customColorBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                isBuiltInEquipped: appearance.clothing != .none,
                customSlots: [.body]
            ) { clothing in
                Label(clothing.label, systemImage: clothingIcon(clothing))
            }
        } label: {
            slotRowLabel(
                slot: "Clothing",
                value: rowValue(builtInLabel: appearance.clothing.label, builtInEmpty: appearance.clothing == .none, customSlots: [.body]),
                isEmpty: appearance.clothing == .none && equippedCustomItem(in: [.body]) == nil
            ) {
                slotIcon(clothingIcon(appearance.clothing))
            }
        }
        .buttonStyle(.plain)
    }

    private var sideItemRow: some View {
        let appearance = store.settings.companionAppearance
        return NavigationLink {
            slotPicker(
                title: "Side item",
                items: CompanionSideItem.allCases,
                selection: appearanceBinding(\.sideItem),
                colorTitle: "Item color",
                colorSelection: colorPresetBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                customColorHex: appearanceBinding(\.sideItemCustomColorHex),
                customColor: customColorBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                isBuiltInEquipped: appearance.sideItem != .none,
                customSlots: [.heldItem]
            ) { item in
                Label(item.label, systemImage: item.systemImage)
            }
        } label: {
            slotRowLabel(
                slot: "Side item",
                value: rowValue(builtInLabel: appearance.sideItem.label, builtInEmpty: appearance.sideItem == .none, customSlots: [.heldItem]),
                isEmpty: appearance.sideItem == .none && equippedCustomItem(in: [.heldItem]) == nil
            ) {
                slotIcon(appearance.sideItem.systemImage)
            }
        }
        .buttonStyle(.plain)
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

    /// The shared selector-row chrome: a small icon/swatch, an uppercase slot label, the current
    /// value right-aligned, and a chevron. `isEmpty` renders the value as a soft italic nudge.
    /// - Parameter slot: `LocalizedStringKey`, not `String` (review A4 follow-up F5). All four call
    ///   sites pass a literal, and a `String` parameter bound `Text`'s verbatim overload — so the
    ///   four slot names were never harvested and the `.textCase(.uppercase)` below had no catalog
    ///   lookup to run after. One word of type is the whole fix.
    private func slotRowLabel<Icon: View>(
        slot: LocalizedStringKey,
        value: String,
        isEmpty: Bool,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        HStack(spacing: 12) {
            icon()
                .frame(width: 30, height: 30)
                .background(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.bark.opacity(0.06))
                )

            // `.textCase`, not `String.uppercased()`: the transform has to run after any catalog
            // lookup so it uppercases the translation, not the English key (T2-1).
            Text(slot)
                .textCase(.uppercase)
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .frame(width: 66, alignment: .leading)

            Spacer(minLength: 8)

            Text(value)
                .font(.fernlet(.body))
                .italic(isEmpty)
                .foregroundStyle(isEmpty ? Color.slate : Color.bark)
                .multilineTextAlignment(.trailing)
                .lineLimit(1)

            Image(systemName: "chevron.right")
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.slate)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream)
        )
        .accessibilityElement(children: .combine)
        // `Text(slot)`, not `slot`: a `LocalizedStringKey` cannot be interpolated INTO another
        // `LocalizedStringKey` (the compiler deprecates it — it would fall back to a debug
        // description), but a `Text` can, and it carries the caption's own lookup with it.
        .accessibilityLabel("\(Text(slot)): \(value)")
    }

    /// A slot swatch built from an SF Symbol, tinted to read as a quiet placeholder.
    private func slotIcon(_ systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 15, weight: .light))
            .foregroundStyle(Color.slate)
    }

    /// A full-screen picker for one slot: a live companion preview, the built-in item grid + recolor
    /// controls, and — folded into the same picker — the user's custom items for the slot(s) this row
    /// covers. Built-ins keep the swatch/ColorPicker recolor; custom items carry their own painted
    /// colors and so get no color control. Reuses the existing customization card verbatim so all
    /// built-in pick / recolor / custom-color behavior is preserved.
    private func slotPicker<Item: Identifiable & Hashable, LabelContent: View>(
        title: LocalizedStringKey,
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
            VStack(spacing: 16) {
                pickerPreview

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
        .background(Color.parchment)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }

    /// A live companion preview shown atop each slot picker, so recolor + equip changes are visible
    /// without leaving the picker.
    private var pickerPreview: some View {
        CompanionView(
            state: store.companionState,
            appearance: store.settings.companionAppearance,
            size: 96,
            interactionLevel: petCount,
            equippedItems: store.equippedCustomItems
        )
        .frame(width: 96, height: 96)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        // Decorative: a live preview above the slot picker; the picker carries the semantics.
        .accessibilityHidden(true)
    }

    /// The custom-item section folded into a slot picker: the user's own items for the covered
    /// slot(s), each tappable to equip/unequip, plus the standing route into the Wardrobe (which
    /// still owns designing, editing, and recoloring custom items).
    @ViewBuilder
    private func customItemsSection(for slots: [ItemSlot]) -> some View {
        let items = store.customItems.filter { slots.contains($0.slot) }
        if slots.isEmpty {
            EmptyView()
        } else {
            FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Your items")

                if items.isEmpty {
                    Text("Design one in the Wardrobe to fold it in here.")
                        .font(.fernlet(.body))
                        .italic()
                        .foregroundStyle(Color.slate)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(items) { item in
                        customItemButton(item)
                    }
                }

                // The `companion.wardrobe` test token migrated to the sheet root's Wardrobe row
                // (HOME-30) — this contextual link stays, without the identifier, so a slot picker
                // still routes into designing.
                NavigationLink {
                    WardrobeView(store: store, studioDraftIsDirty: $isStudioDraftDirty)
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "tshirt.fill")
                            .font(.system(size: 15))
                            .foregroundStyle(Color.moss)
                            .frame(width: 34, height: 34)
                            .background(Color.moss.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Design & recolor in Wardrobe")
                                .font(.fernlet(.label))
                                .foregroundStyle(Color.moss)
                            Text("Open the closet")
                                .font(.fernlet(.bodySmall))
                                .italic()
                                .foregroundStyle(Color.slate)
                        }
                        Spacer(minLength: 8)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.moss)
                    }
                }
                .buttonStyle(.plain)
            }
            }
        }
    }

    /// One custom-item row inside a slot picker. Tap to equip; tap the equipped item to unequip.
    private func customItemButton(_ item: CustomizationItem) -> some View {
        let isEquipped = store.equippedCustomItems.contains { $0.id == item.id }
        return Button {
            // A choice in the customize sheet: the tick says it took; the preview and the
            // "Equipped" pill show it.
            FernletFeedback.system.play(.tick)
            if isEquipped {
                store.unequipCustomSlot(item.slot)
            } else {
                store.equipCustomItem(id: item.id, slot: item.slot)
            }
        } label: {
            HStack(spacing: 12) {
                CustomItemThumbnail(texture: item.texture, size: 40)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.name.isEmpty ? item.slot.label : item.name)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text(item.slot.label)
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                }
                Spacer(minLength: 8)
                if isEquipped {
                    Text("Equipped")
                        .font(.fernlet(.labelSmall))
                        // T1-3: text ink, not the `moss` accent (3.74:1, fails 4.5:1 small text).
                        .foregroundStyle(Color.mossInk)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.moss.opacity(0.12), in: Capsule())
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(isEquipped ? Color.moss.opacity(0.10) : Color.bark.opacity(0.04))
            )
        }
        .buttonStyle(.plain)
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

/// The reusable built-in item grid + color controls inside a slot picker: a 2-column grid of
/// selectable items and (optionally) the preset swatches + custom `ColorPicker`.
///
/// Generic over the slot's item type so one card serves body styles, accessories, clothing, and
/// side items; selection and color flow back through the bindings
/// `CompanionCustomizationSheet` builds onto the store.
private struct CompanionCustomizationCard<Item: Identifiable & Hashable, LabelContent: View>: View {
    /// Authored copy ("Body", "Clothing", …), so `LocalizedStringKey`: every caller passes a
    /// literal, and only that type extracts into the string catalog.
    var title: LocalizedStringKey
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

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        let isSelected = selection.id == item.id
                        Button {
                            // Re-tapping the current pick changes nothing, so it says nothing.
                            if !isSelected { FernletFeedback.system.play(.tick) }
                            selection = item
                        } label: {
                            label(item)
                                .font(.fernlet(.label))
                                // The contrast-safe fill/ink pair, not cream on plain `moss`.
                                .foregroundStyle(isSelected ? Color.onMoss : Color.bark)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    isSelected ? Color.mossFill : Color.bark.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
                    }
                }

                if showsColor {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack {
                            SectionLabel(colorTitle)
                            Spacer()
                            ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                                .labelsHidden()
                        }

                        LazyVGrid(columns: colorColumns, spacing: 6) {
                            ForEach(CompanionAssetColor.allCases) { color in
                                colorButton(for: color)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func colorButton(for color: CompanionAssetColor) -> some View {
        let isSelected = customColorHex == nil && colorSelection == color
        Button {
            if !isSelected { FernletFeedback.system.play(.tick) }
            colorSelection = color
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.color(for: state))
                    .frame(width: 11, height: 11)
                Text(color.label)
                    .font(.fernlet(.label))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.onMoss : Color.bark)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                isSelected ? Color.mossFill : Color.bark.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(color.label)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}
