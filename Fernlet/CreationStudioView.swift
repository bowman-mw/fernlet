import SwiftUI
import FernletDomainModel

/// The Animal-Crossing-style fabric editor. The user paints a per-slot pixel grid from a fixed palette,
/// names it, and saves it into their Wardrobe. New creations auto-equip so the result is immediately
/// visible on the companion. Pushed within the Wardrobe's navigation stack.
struct CreationStudioView: View {
    var store: FernletStore
    /// When non-nil we edit an existing item in place (id / createdAt / designer preserved).
    var editingItem: CustomizationItem?

    @Environment(\.dismiss) private var dismiss

    @State private var slot: ItemSlot
    @State private var pixels: [Int]
    @State private var name: String
    @State private var selectedColor: Int
    @State private var isShareable: Bool
    @State private var price: Int
    @State private var shopAlert: ShopAlert?
    @State private var draftID = UUID()
    /// Whole-canvas snapshots, one per completed stroke. A stroke — not a cell — is the unit a user
    /// thinks in: one drag can paint dozens of cells, and undoing them one at a time would be useless.
    @State private var undoStack: [[Int]] = []
    /// Mirror mode: painting one side also paints the horizontal mirror. Off by default — a mirror the
    /// user didn't ask for is more surprising than a toggle they have to find.
    @State private var isSymmetric = false

    /// Bounded so a long session can't grow without limit. A body grid is 48×40 Ints ≈ 15 KB, so 32
    /// snapshots is ~0.5 MB worst case — irrelevant next to the images this app already holds.
    private static let maxUndoSteps = 32

    private let palette = ItemDesignPalette.hexes

    init(store: FernletStore, editingItem: CustomizationItem? = nil) {
        self.store = store
        self.editingItem = editingItem
        if let item = editingItem {
            _slot = State(initialValue: item.slot)
            _pixels = State(initialValue: Self.editorPixels(for: item, palette: ItemDesignPalette.hexes))
            _name = State(initialValue: item.name)
            _isShareable = State(initialValue: item.isShareable)
            _price = State(initialValue: ClothingShopLimits.clampedPrice(item.price))
        } else {
            let initialSlot = ItemSlot.body
            _slot = State(initialValue: initialSlot)
            _pixels = State(initialValue: Self.blankPixels(for: initialSlot))
            _name = State(initialValue: "")
            _isShareable = State(initialValue: false)
            _price = State(initialValue: ClothingShopLimits.minPrice)
        }
        _selectedColor = State(initialValue: 0)
    }

    private enum ShopAlert: Identifiable {
        case nameFlagged
        case capReached
        case storeBanned
        var id: Int {
            switch self {
            case .nameFlagged: 0
            case .capReached: 1
            case .storeBanned: 2
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                preview
                if editingItem == nil {
                    slotPicker
                }
                canvasTools
                editorCanvas
                paletteRow
                detailsCard
            }
            // 12pt, not 20. The canvas is the point of this screen and its cell size is
            // width / gridCols, so horizontal padding is the one thing directly costing drawing
            // resolution — and it was being paid twice (here and inside `editorCanvas`).
            .padding(12)
        }
        .background(Color.parchment)
        .tint(Color.moss)
        .navigationTitle(editingItem == nil ? "New item" : "Edit item")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            // Prominent capsule save, not a bare toolbar link.
            SheetSaveBar(label: "Save to closet", disabled: !canSave) { save() }
        }
        .alert(item: $shopAlert) { alert in
            switch alert {
            case .nameFlagged:
                return Alert(
                    title: Text("Pick a friendlier name"),
                    message: Text("This name can't be used in your shop. Your item is saved — rename it and try listing again. (Private items can be named anything.)"),
                    dismissButton: .default(Text("OK"))
                )
            case .capReached:
                return Alert(
                    title: Text("Your shop is full"),
                    message: Text("You can list up to \(ClothingShopLimits.maxListedItems) items at once. Unlist one to make room. Your item is saved and ready whenever you are."),
                    dismissButton: .default(Text("OK"))
                )
            case .storeBanned:
                return Alert(
                    title: Text("Your shop is closed"),
                    message: Text("Your shop is paused because items you shared were reported. It reopens automatically after a while — your items are still saved."),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    // MARK: - Sections

    private var preview: some View {
        CompanionView(
            state: store.companionState,
            appearance: store.settings.companionAppearance,
            size: 140,
            equippedItems: previewEquipped
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }

    private var slotPicker: some View {
        Picker("Slot", selection: $slot) {
            ForEach(ItemSlot.allCases) { slot in
                Text(slot.label).tag(slot)
            }
        }
        .pickerStyle(.segmented)
        .onChange(of: slot) { _, newSlot in
            // Resizing the canvas discards the current art (only reachable while creating a new item).
            pixels = Self.blankPixels(for: newSlot)
            // The history belongs to the old canvas — its snapshots are the wrong dimensions, so undoing
            // into them would index a 48×40 buffer with 36×16 offsets and scramble the art.
            undoStack.removeAll()
        }
    }

    /// Undo + mirror, sat directly above the canvas where the drawing hand already is.
    private var canvasTools: some View {
        HStack(spacing: 12) {
            Button {
                undo()
            } label: {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.fernlet(.label))
            }
            .buttonStyle(.plain)
            .foregroundStyle(undoStack.isEmpty ? Color.slate.opacity(0.4) : Color.fern)
            .disabled(undoStack.isEmpty)
            .accessibilityIdentifier("studio.undo")

            Spacer()

            Button {
                isSymmetric.toggle()
            } label: {
                Label("Mirror", systemImage: isSymmetric ? "square.righthalf.filled" : "square.righthalf.filled")
                    .font(.fernlet(.label))
            }
            .buttonStyle(.plain)
            .foregroundStyle(isSymmetric ? Color.fern : Color.slate)
            .accessibilityIdentifier("studio.mirror")
            .accessibilityAddTraits(isSymmetric ? [.isSelected] : [])
        }
        .padding(.horizontal, 4)
    }

    private var editorCanvas: some View {
        // Zoomable/pannable surface (#15): pinch to zoom, two fingers to pan, one finger paints. The
        // pixel/undo/symmetry logic stays here; the canvas just reports the touched cell + stroke start.
        ZoomablePixelCanvas(
            pixels: $pixels,
            cols: slot.gridCols,
            rows: slot.gridRows,
            palette: palette,
            onStrokeBegan: { pushUndoSnapshot() },
            onPaintCell: { x, y in paintCell(x: x, y: y) }
        )
        .aspectRatio(CGFloat(slot.gridCols) / CGFloat(slot.gridRows), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.parchment)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.bark.opacity(0.10), lineWidth: 1)
        )
        .overlay {
            // Gentle first-touch hint when the grid is still blank.
            if isCanvasBlank {
                Text("Drag to paint · pinch to zoom")
                    .font(.fernlet(.body))
                    .italic()
                    .foregroundStyle(Color.slate.opacity(0.6))
                    .allowsHitTesting(false)
            }
        }
        // 8pt, not 16 — see the outer padding note. Together these give the grid back ~32pt of width,
        // which at 48 columns is real cell size rather than decoration.
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cream)
        )
        .fernletCardShadow()
        .accessibilityIdentifier("studio.canvas")
    }

    /// True while every cell is still transparent — drives the "Drag to paint" hint.
    private var isCanvasBlank: Bool {
        !pixels.contains { $0 != ItemGridTexture.transparent }
    }

    private var paletteRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Palette".uppercased())
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .tracking(0.8)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    eraserSwatch
                    ForEach(Array(palette.enumerated()), id: \.offset) { index, hex in
                        swatch(index: index, hex: hex)
                    }
                }
                .padding(.vertical, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var eraserSwatch: some View {
        Button {
            selectedColor = ItemGridTexture.transparent
        } label: {
            ZStack {
                // A checker fill reads as "transparent / erase" — it can never blend into the card.
                Canvas { context, size in
                    let step: CGFloat = 7
                    context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Color.cream))
                    var y: CGFloat = 0
                    var row = 0
                    while y < size.height {
                        var x: CGFloat = (row.isMultiple(of: 2) ? 0 : step)
                        while x < size.width {
                            context.fill(
                                Path(CGRect(x: x, y: y, width: step, height: step)),
                                with: .color(Color.bark.opacity(0.14))
                            )
                            x += step * 2
                        }
                        y += step
                        row += 1
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                Image(systemName: "eraser")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.bark.opacity(0.7))
            }
            .frame(width: 34, height: 34)
            .overlay(selectionRing(isSelected: selectedColor == ItemGridTexture.transparent))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Eraser")
    }

    private func swatch(index: Int, hex: String) -> some View {
        Button {
            selectedColor = index
        } label: {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color(itemHex: hex) ?? .gray)
                .frame(width: 34, height: 34)
                .overlay(selectionRing(isSelected: selectedColor == index))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Color \(index + 1)")
    }

    /// Selected → moss ring; unselected → a hairline so light swatches (cream, parchment, white) never
    /// vanish into the cream card behind them (the 6b "palette that never disappears" fix).
    private func selectionRing(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isSelected ? Color.moss : Color.bark.opacity(0.22), lineWidth: isSelected ? 2.5 : 1)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 18) {
            SheetField("Name") {
                TextField("Name your item", text: $name)
                    .sheetTextInput()
            }

            if canSell {
                SheetField("Shop") {
                    VStack(spacing: 0) {
                        Toggle(isOn: $isShareable) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("List in my shop")
                                    .font(.fernlet(.label))
                                    .foregroundStyle(Color.bark)
                                Text("Friends nearby can buy it for their companion.")
                                    .font(.fernlet(.bodySmall))
                                    .italic()
                                    .foregroundStyle(Color.slate)
                            }
                        }
                        .tint(Color.moss)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                        if isShareable {
                            Divider().overlay(Color.bark.opacity(0.08))
                            Stepper(value: $price, in: ClothingShopLimits.minPrice...ClothingShopLimits.maxPrice) {
                                HStack(spacing: 6) {
                                    Text("Price")
                                        .font(.fernlet(.label))
                                        .foregroundStyle(Color.bark)
                                    Spacer(minLength: 8)
                                    Image(systemName: "circlebadge.2.fill").foregroundStyle(Color.sun)
                                    Text("\(price) coins")
                                        .font(.fernlet(.stat))
                                        .foregroundStyle(Color.bark)
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                        }
                    }
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .stroke(Color.bark.opacity(0.08), lineWidth: 1)
                    )
                }

                if isShareable {
                    Text(shopHint)
                        .font(.fernlet(.bodySmall))
                        .italic()
                        .foregroundStyle(Color.slate)
                }
            }

            Button(role: .destructive) {
                pixels = Self.blankPixels(for: slot)
            } label: {
                Label("Clear canvas", systemImage: "trash")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.terracotta)
            }
            .buttonStyle(.plain)
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.cream.opacity(0.55))
        )
    }

    // MARK: - Behavior

    private var canSave: Bool {
        !ItemGridTexture(cols: slot.gridCols, rows: slot.gridRows, palette: palette, pixels: pixels).isBlank
    }

    /// Only your own designs can be sold. New items are always yours; a friend-received item never is.
    private var canSell: Bool {
        editingItem.map { store.isSelfDesigned($0) } ?? true
    }

    private var shopHint: String {
        let listed = store.listedShopItems.count
        if store.shopUpdatedToday {
            return "\(listed) of \(ClothingShopLimits.maxListedItems) listed · you've already refreshed your shop today — that's plenty."
        }
        return "\(listed) of \(ClothingShopLimits.maxListedItems) listed."
    }

    private var previewEquipped: [CustomizationItem] {
        store.equippedCustomItems.filter { $0.slot != slot } + [draftPreviewItem]
    }

    private var draftPreviewItem: CustomizationItem {
        CustomizationItem(
            id: editingItem?.id ?? draftID,
            name: name,
            slot: slot,
            texture: ItemGridTexture(cols: slot.gridCols, rows: slot.gridRows, palette: palette, pixels: pixels),
            designer: ItemDesigner(id: store.localDesignerID)
        )
    }

    /// Paints the grid cell reported by the zoomable canvas (plus its mirror when symmetry is on). The
    /// canvas maps the touch to a cell at any zoom level; this owns the colour + symmetry.
    private func paintCell(x: Int, y: Int) {
        setCell(x: x, y: y)
        if isSymmetric {
            // Every grid is even-width (32/36/48/28), so the axis falls cleanly between the two centre
            // columns and there is no self-mirroring centre column to special-case.
            setCell(x: slot.gridCols - 1 - x, y: y)
        }
    }

    /// Paints one cell. Extracted so symmetry can paint both sides: the "already this colour" guard used
    /// to early-return out of `paint` itself, which would have silently skipped the mirrored cell
    /// whenever the touched cell happened to already match the selected colour.
    private func setCell(x: Int, y: Int) {
        guard x >= 0, x < slot.gridCols, y >= 0, y < slot.gridRows else { return }
        let index = y * slot.gridCols + x
        guard index >= 0, index < pixels.count, pixels[index] != selectedColor else { return }
        pixels[index] = selectedColor
    }

    /// Snapshots the canvas before a stroke mutates it. Called once per stroke, from the drag's first
    /// `onChanged`.
    private func pushUndoSnapshot() {
        undoStack.append(pixels)
        if undoStack.count > Self.maxUndoSteps { undoStack.removeFirst() }
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        pixels = previous
    }

    private func save() {
        guard canSave else { return }
        let texture = ItemGridTexture(cols: slot.gridCols, rows: slot.gridRows, palette: palette, pixels: pixels)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? slot.label : trimmed
        let itemID: UUID

        // Save the item UNLISTED first; the shop gate (cap + name moderation) decides whether it becomes
        // listed, so a flagged/over-cap item is still saved (just private).
        if let existing = editingItem {
            var updated = existing
            updated.name = finalName
            updated.texture = texture
            updated.isShareable = false
            updated.price = ClothingShopLimits.clampedPrice(price)
            store.saveCustomItem(updated)
            itemID = updated.id
        } else {
            let item = CustomizationItem(
                name: finalName,
                slot: slot,
                texture: texture,
                designer: ItemDesigner(id: store.localDesignerID),
                isShareable: false,
                price: ClothingShopLimits.clampedPrice(price)
            )
            store.saveCustomItem(item)
            store.equipCustomItem(id: item.id, slot: slot)
            itemID = item.id
        }

        guard canSell, isShareable else {
            // Toggled off (or not sellable): make sure it isn't listed, then leave.
            if canSell { store.unlistCustomItem(id: itemID) }
            dismiss()
            return
        }

        switch store.listCustomItemForSale(id: itemID, price: price) {
        case .listed:
            dismiss()
        case .nameFlagged:
            shopAlert = .nameFlagged   // stay so the user can rename and re-save
        case .capReached:
            shopAlert = .capReached
        case .notAllowed:
            dismiss()                  // not your design (unreachable — `canSell` guards); item saved, just unlisted
        case .storeBanned:
            shopAlert = .storeBanned
        }
    }

    // MARK: - Helpers

    private static func blankPixels(for slot: ItemSlot) -> [Int] {
        Array(repeating: ItemGridTexture.transparent, count: slot.gridCols * slot.gridRows)
    }

    /// Builds an editor pixel buffer sized exactly to the item's slot grid (`gridCols * gridRows`),
    /// reprojecting the stored texture cell-by-cell so the buffer always matches what the canvas indexes
    /// — even if the stored texture's dimensions differ from the current slot grid (a friend-received
    /// item, or data authored under different grid constants). Palette indices are remapped onto the
    /// editor palette by exact hex match (unmatched → transparent); a matching palette is a fast copy.
    /// Internal rather than private so the resample below is reachable from tests — it is the one path
    /// here that can silently destroy a user's art, and it must not be verified by eye.
    static func editorPixels(for item: CustomizationItem, palette: [String]) -> [Int] {
        let cols = item.slot.gridCols
        let rows = item.slot.gridRows
        var buffer = Array(repeating: ItemGridTexture.transparent, count: cols * rows)
        let texture = item.texture
        guard texture.cols > 0, texture.rows > 0, texture.pixels.count == texture.cols * texture.rows else {
            return buffer
        }
        let samePalette = texture.palette == palette
        var lookup: [String: Int] = [:]
        if !samePalette {
            for (index, hex) in palette.enumerated() { lookup[hex.uppercased()] = index }
        }
        // Nearest-neighbour RESAMPLE across the whole canvas, rather than the 1:1 top-left copy this
        // used to do. That copy was harmless only while every texture already matched the current slot
        // dimensions: any texture drawn at a different budget (a smaller one from an older build, or a
        // larger one from a newer build via the P2P shop) opened with its art crammed into one corner —
        // and `save()` re-encodes at the current slot dims, making the damage permanent on first edit.
        //
        // Sampling by ratio is exact for the 2× case (each source cell fills a clean 2×2 block, so a
        // round-trip is lossless) and merely approximate for arbitrary ratios, which beats corrupting.
        for y in 0..<rows {
            let sourceY = texture.rows == rows ? y : min(texture.rows - 1, y * texture.rows / rows)
            for x in 0..<cols {
                let sourceX = texture.cols == cols ? x : min(texture.cols - 1, x * texture.cols / cols)
                let source = texture.pixels[sourceY * texture.cols + sourceX]
                guard source >= 0, source < texture.palette.count else { continue }
                buffer[y * cols + x] = samePalette ? source : (lookup[texture.palette[source].uppercased()] ?? ItemGridTexture.transparent)
            }
        }
        return buffer
    }
}
