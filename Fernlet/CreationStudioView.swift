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
    @State private var draftID = UUID()

    private let palette = ItemDesignPalette.hexes

    init(store: FernletStore, editingItem: CustomizationItem? = nil) {
        self.store = store
        self.editingItem = editingItem
        if let item = editingItem {
            _slot = State(initialValue: item.slot)
            _pixels = State(initialValue: Self.editorPixels(for: item, palette: ItemDesignPalette.hexes))
            _name = State(initialValue: item.name)
            _isShareable = State(initialValue: item.isShareable)
        } else {
            let initialSlot = ItemSlot.body
            _slot = State(initialValue: initialSlot)
            _pixels = State(initialValue: Self.blankPixels(for: initialSlot))
            _name = State(initialValue: "")
            _isShareable = State(initialValue: false)
        }
        _selectedColor = State(initialValue: 0)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                preview
                if editingItem == nil {
                    slotPicker
                }
                editorCanvas
                paletteRow
                detailsCard
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle(editingItem == nil ? "New item" : "Edit item")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Save") { save() }
                    .fontWeight(.semibold)
                    .foregroundStyle(canSave ? Color.moss : Color.bark.opacity(0.35))
                    .disabled(!canSave)
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
        }
    }

    private var editorCanvas: some View {
        GeometryReader { geo in
            let cellW = geo.size.width / CGFloat(slot.gridCols)
            let cellH = geo.size.height / CGFloat(slot.gridRows)
            Canvas { context, _ in
                for y in 0..<slot.gridRows {
                    for x in 0..<slot.gridCols {
                        let rect = CGRect(x: CGFloat(x) * cellW, y: CGFloat(y) * cellH, width: cellW, height: cellH)
                        let flat = y * slot.gridCols + x
                        let idx = flat < pixels.count ? pixels[flat] : ItemGridTexture.transparent
                        if idx >= 0, idx < palette.count, let color = Color(itemHex: palette[idx]) {
                            context.fill(Path(rect), with: .color(color))
                        }
                        context.stroke(Path(rect), with: .color(Color.bark.opacity(0.12)), lineWidth: 0.5)
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        paint(at: value.location, cellW: cellW, cellH: cellH)
                    }
            )
        }
        .aspectRatio(CGFloat(slot.gridCols) / CGFloat(slot.gridRows), contentMode: .fit)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.cream)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.bark.opacity(0.12), lineWidth: 1)
        )
    }

    private var paletteRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Palette")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.parchment)
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

    private func selectionRing(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isSelected ? Color.moss : Color.bark.opacity(0.15), lineWidth: isSelected ? 2.5 : 1)
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            TextField("Name your item", text: $name)
                .textFieldStyle(.roundedBorder)

            Toggle(isOn: $isShareable) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Available in my shop")
                    Text("Friends can browse and buy this when you connect in person.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .tint(Color.moss)

            Button(role: .destructive) {
                pixels = Self.blankPixels(for: slot)
            } label: {
                Label("Clear canvas", systemImage: "trash")
                    .font(.subheadline)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream)
        )
    }

    // MARK: - Behavior

    private var canSave: Bool {
        !ItemGridTexture(cols: slot.gridCols, rows: slot.gridRows, palette: palette, pixels: pixels).isBlank
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

    private func paint(at location: CGPoint, cellW: CGFloat, cellH: CGFloat) {
        guard cellW > 0, cellH > 0 else { return }
        let x = Int(location.x / cellW)
        let y = Int(location.y / cellH)
        guard x >= 0, x < slot.gridCols, y >= 0, y < slot.gridRows else { return }
        let index = y * slot.gridCols + x
        guard index >= 0, index < pixels.count, pixels[index] != selectedColor else { return }
        pixels[index] = selectedColor
    }

    private func save() {
        guard canSave else { return }
        let texture = ItemGridTexture(cols: slot.gridCols, rows: slot.gridRows, palette: palette, pixels: pixels)
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = trimmed.isEmpty ? slot.label : trimmed

        if let existing = editingItem {
            var updated = existing
            updated.name = finalName
            updated.texture = texture
            updated.isShareable = isShareable
            store.saveCustomItem(updated)
        } else {
            let item = CustomizationItem(
                name: finalName,
                slot: slot,
                texture: texture,
                designer: ItemDesigner(id: store.localDesignerID),
                isShareable: isShareable
            )
            store.saveCustomItem(item)
            store.equipCustomItem(id: item.id, slot: slot)
        }
        dismiss()
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
    private static func editorPixels(for item: CustomizationItem, palette: [String]) -> [Int] {
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
        let copyCols = min(cols, texture.cols)
        let copyRows = min(rows, texture.rows)
        for y in 0..<copyRows {
            for x in 0..<copyCols {
                let source = texture.pixels[y * texture.cols + x]
                guard source >= 0, source < texture.palette.count else { continue }
                buffer[y * cols + x] = samePalette ? source : (lookup[texture.palette[source].uppercased()] ?? ItemGridTexture.transparent)
            }
        }
        return buffer
    }
}
