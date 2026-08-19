import SwiftUI
import FernletDomainModel
import FernletUI

/// The Animal-Crossing-style fabric editor for custom companion clothing.
///
/// The user paints a per-slot pixel grid from a fixed palette on a ``ZoomablePixelCanvas`` (with
/// per-stroke undo, mirror mode, and per-slot draft buffers so switching slots never loses a
/// drawing), then taps Next into the confirmation step to name it and optionally list it in their
/// shop — the save is unlisted-first, so a flagged name or a full shop still keeps the item. New
/// creations auto-equip so the result is immediately visible on the companion. Pushed within the
/// Wardrobe's navigation stack; pass `editingItem` to edit an existing item in place (id /
/// createdAt / designer preserved, with cross-dimension textures resampled via
/// ``CreationStudioView/editorPixels(for:palette:)``).
struct CreationStudioView: View {
    var store: FernletStore
    /// When non-nil we edit an existing item in place (id / createdAt / designer preserved).
    var editingItem: CustomizationItem?
    /// Optional back-channel to the hosting customization sheet, so it can block swipe-to-dismiss
    /// while there is unsaved paint on the canvas. Nil when the studio is shown without a host that
    /// cares (previews, tests) — never a crash, just no swipe guard.
    var draftIsDirty: Binding<Bool>?

    @Environment(\.dismiss) private var dismiss

    @State private var slot: ItemSlot
    @State private var pixels: [Int]
    @State private var name: String
    @State private var selectedColor: Int
    @State private var isShareable: Bool
    @State private var price: Int
    /// Set only by `save()`, and presented from `confirmationScreen` (the topmost view when a listing is
    /// refused) — see the `.alert` there for why it must not hang off the editor.
    @State private var shopAlert: ShopAlert?
    /// Per-slot draft ids for the create path, seeded for every slot up front so reads during body
    /// (the companion preview) never mutate state. Keyed by slot because `CustomItemService.upsert`
    /// is a whole-row replace: a single session-wide id let a save after switching slots silently
    /// destroy the item already saved on the first slot — and put duplicate Identifiable ids in the
    /// preview's `ForEach` (saved body item + draft preview sharing one id).
    @State private var draftIDs: [ItemSlot: UUID] = Dictionary(
        uniqueKeysWithValues: ItemSlot.allCases.map { ($0, UUID()) }
    )
    /// Whole-canvas snapshots, one per completed stroke. A stroke — not a cell — is the unit a user
    /// thinks in: one drag can paint dozens of cells, and undoing them one at a time would be useless.
    @State private var undoStack: [[Int]] = []
    /// Per-slot canvas storage so switching slots stashes each drawing (and its undo history) instead of
    /// destroying it. Keyed by slot, so every buffer is already at that slot's dimensions — restoring can
    /// never index a wrong-sized grid, the hazard the old blank-on-switch was guarding against.
    @State private var slotBuffers: [ItemSlot: (pixels: [Int], undoStack: [[Int]])] = [:]
    /// Mirror mode: painting one side also paints the horizontal mirror. Off by default — a mirror the
    /// user didn't ask for is more surprising than a toggle they have to find.
    @State private var isSymmetric = false
    /// Drives the push to the naming + shop-listing confirmation step. The editor screen itself no longer
    /// carries the name/shop controls — you draw, tap Next, then name and (optionally) list it.
    @State private var showingConfirmation = false
    /// The canvas as it was last persisted (the item's own art on the edit path, blank on create).
    /// `pixels != savedPixels` is what "unsaved paint" means when editing.
    @State private var savedPixels: [Int]
    /// Set by `save()` so a saved-but-still-open studio (a refused listing keeps the user here to
    /// rename) stops claiming there is anything to lose.
    @State private var didSave = false
    /// Drives the custom back button's discard prompt.
    @State private var askingToDiscard = false

    /// Bounded so a long session can't grow without limit. A body grid is 48×40 Ints ≈ 15 KB, so 32
    /// snapshots is ~0.5 MB worst case — irrelevant next to the images this app already holds.
    private static let maxUndoSteps = 32

    private let palette = ItemDesignPalette.hexes

    init(store: FernletStore, editingItem: CustomizationItem? = nil, draftIsDirty: Binding<Bool>? = nil) {
        self.store = store
        self.editingItem = editingItem
        self.draftIsDirty = draftIsDirty
        if let item = editingItem {
            let initialPixels = Self.editorPixels(for: item, palette: ItemDesignPalette.hexes)
            _slot = State(initialValue: item.slot)
            _pixels = State(initialValue: initialPixels)
            _savedPixels = State(initialValue: initialPixels)
            _name = State(initialValue: item.name)
            _isShareable = State(initialValue: item.isShareable)
            _price = State(initialValue: ClothingShopLimits.clampedPrice(item.price))
        } else {
            let initialSlot = ItemSlot.body
            _slot = State(initialValue: initialSlot)
            // The UI-test seed paints the canvas so "Next" is enabled: XCUITest can't synthesize the
            // custom canvas's paint gesture, and a blank canvas leaves the confirmation step unreachable.
            let initialPixels = UITestSupport.shouldSeedStudioCanvas
                ? Self.seededPixels(for: initialSlot)
                : Self.blankPixels(for: initialSlot)
            _pixels = State(initialValue: initialPixels)
            _savedPixels = State(initialValue: initialPixels)
            _name = State(initialValue: "")
            _isShareable = State(initialValue: false)
            _price = State(initialValue: ClothingShopLimits.minPrice)
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
                canvasTools
                editorCanvas
                paletteRow
                clearCanvasButton
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
            // The editor screen is just the drawing now; naming + listing move to a confirmation step.
            SheetSaveBar(label: "Next", disabled: !canSave) { showingConfirmation = true }
        }
        .navigationDestination(isPresented: $showingConfirmation) {
            confirmationScreen
        }
        // A painted canvas is unsaved work: hiding the system back button (which also disables the
        // interactive swipe-back) and substituting one that ASKS is what stops a stray chevron tap
        // from throwing the drawing away. A blank / already-saved canvas keeps the ordinary back.
        .navigationBarBackButtonHidden(hasUnsavedDrawing)
        .toolbar {
            if hasUnsavedDrawing {
                ToolbarItem(placement: .topBarLeading) {
                    Button { askingToDiscard = true } label: {
                        Image(systemName: "chevron.backward")
                    }
                    .fernletIconButton("Back")
                    .accessibilityIdentifier("studio.back")
                }
            }
        }
        .discardConfirmation(isPresented: $askingToDiscard) { leaveStudio() }
        // The other half of the same guard: the studio is pushed INSIDE the customization sheet, so
        // a swipe-down anywhere on it dismissed the whole stack. Reported up so the host can block
        // interactive dismissal while the drawing is unsaved. (`onAppear` + `onChange` rather than
        // `onChange(initial:)` — the report writes the HOST's state, so it must land after the first
        // render, never during it.)
        .onAppear { draftIsDirty?.wrappedValue = hasUnsavedDrawing }
        .onChange(of: hasUnsavedDrawing) { _, dirty in
            draftIsDirty?.wrappedValue = dirty
        }
    }

    /// True while the studio holds paint that has not been saved: the live canvas, or a per-slot
    /// buffer stashed on the way here (switching slots keeps each drawing alive, so those count too).
    private var hasUnsavedDrawing: Bool {
        guard !didSave else { return false }
        if editingItem != nil { return pixels != savedPixels }
        if !isCanvasBlank { return true }
        return slotBuffers.values.contains { buffer in
            buffer.pixels.contains { $0 != ItemGridTexture.transparent }
        }
    }

    /// The single exit from the studio. Clears the host sheet's swipe-dismiss block before popping —
    /// a flag left standing would leave the customization sheet permanently un-swipeable.
    private func leaveStudio() {
        draftIsDirty?.wrappedValue = false
        dismiss()
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
        .onChange(of: slot) { oldSlot, newSlot in
            guard oldSlot != newSlot else { return }
            // Stash the slot we're leaving so its drawing — and its undo history — survives the trip.
            slotBuffers[oldSlot] = (pixels, undoStack)
            // Restore the slot we're entering, or start it blank. Each buffer was captured at its own
            // slot's dimensions, so pixels + undoStack always move together and can never mismatch the
            // grid (the corruption the old blank-and-clear was avoiding).
            if let saved = slotBuffers[newSlot] {
                pixels = saved.pixels
                undoStack = saved.undoStack
            } else {
                pixels = Self.blankPixels(for: newSlot)
                undoStack.removeAll()
            }
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
                Label("Mirror", systemImage: isSymmetric ? "square.righthalf.filled" : "rectangle.split.2x1")
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
            onStrokeCancelled: { cancelStroke() },
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
                    // Decorative; hidden from a11y so it doesn't also carry the canvas's `studio.canvas` id.
                    .accessibilityHidden(true)
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
        .accessibilityAddTraits(selectedColor == ItemGridTexture.transparent ? [.isSelected] : [])
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
        // "Color 7" tells a VoiceOver user nothing about what they are about to paint with.
        .accessibilityLabel(Self.paletteName(at: index))
        .accessibilityAddTraits(selectedColor == index ? [.isSelected] : [])
    }

    /// Spoken names for `ItemDesignPalette.hexes`, in its order. Kept here (not on the domain
    /// palette) so this stays a presentation concern; the index fallback keeps it total if a colour
    /// is ever appended upstream.
    private static let paletteNames = [
        "Near-black", "Bark", "Taupe", "Cream", "Parchment", "White",
        "Moss", "Fern", "Terracotta", "Sun", "Rose", "Plum",
        "Slate blue", "Deep slate", "Red", "Emerald"
    ]

    private static func paletteName(at index: Int) -> String {
        guard index >= 0, index < paletteNames.count else { return "Color \(index + 1)" }
        return paletteNames[index]
    }

    /// Selected → moss ring; unselected → a hairline so light swatches (cream, parchment, white) never
    /// vanish into the cream card behind them (the 6b "palette that never disappears" fix).
    private func selectionRing(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isSelected ? Color.moss : Color.bark.opacity(0.22), lineWidth: isSelected ? 2.5 : 1)
    }

    /// Clear-canvas lives on the editor (it's a drawing action); naming + shop listing moved to the
    /// confirmation step.
    private var clearCanvasButton: some View {
        Button(role: .destructive) {
            // Snapshot before blanking so Clear is a single undoable step; guard skips a no-op snapshot on
            // an already-blank canvas.
            if !isCanvasBlank { pushUndoSnapshot() }
            pixels = Self.blankPixels(for: slot)
        } label: {
            Label("Clear canvas", systemImage: "trash")
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracotta)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("studio.clearCanvas")
    }

    // MARK: - Confirmation (name + shop) — the follow-up "save" step

    /// The follow-up screen after drawing: a preview of the finished item, the name, and (for your own
    /// designs) whether to list it in your shop — then the actual save. Reached via "Next" on the editor.
    private var confirmationScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                CompanionView(
                    state: store.companionState,
                    appearance: store.settings.companionAppearance,
                    size: 148,
                    equippedItems: previewEquipped
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
                .accessibilityIdentifier("studio.confirm.preview")

                SheetField("Name") {
                    // R3: bounded where the text enters, at the same length the shop's name
                    // moderation enforces.
                    TextField("Name your item", text: Binding(
                        get: { name },
                        set: { name = String($0.prefix(ItemNameModeration.maxNameLength)) }
                    ))
                    .sheetTextInput()
                    .accessibilityIdentifier("studio.confirm.name")
                }

                if canSell {
                    shopSection
                }
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .background(Color.parchment)
        .tint(Color.moss)
        .navigationTitle("Save item")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            SheetSaveBar(label: "Save to closet", disabled: !canSave) { save() }
        }
        // The moderation alert lives HERE, on the confirmation screen, not back on the editor: `save()`
        // only ever runs from this screen's save bar, and a refused listing deliberately does NOT
        // `dismiss()` (the user stays to rename and retry). An alert anchored to the editor — by then the
        // covered middle of the stack (Wardrobe → editor → confirmation) — is not reliably presented, so
        // the refusal read as an inert Save button while the item was quietly saved-but-unlisted.
        .alert(item: $shopAlert) { $0.alert(in: .studioConfirmation) }
    }

    private var shopSection: some View {
        VStack(alignment: .leading, spacing: 10) {
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
                    .accessibilityIdentifier("studio.confirm.listToggle")

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
            id: editingItem?.id ?? draftID(for: slot),
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

    /// A zoom/pan interrupted a stroke mid-drag: pop the snapshot that stroke pushed in `onStrokeBegan`
    /// back into `pixels`, so a staggered-pinch stray dab is reverted rather than left painted. Reuses the
    /// undo machinery — the interrupted stroke's snapshot is exactly the top of the stack.
    private func cancelStroke() {
        undo()
    }

    /// The slot's stable draft id. Every slot is seeded at init, so this is a pure read in practice;
    /// the mint is a defensive fallback that keeps the accessor total without a force-unwrap.
    private func draftID(for slot: ItemSlot) -> UUID {
        if let id = draftIDs[slot] { return id }
        let id = UUID()
        draftIDs[slot] = id
        return id
    }

    /// Persists the freshly-drawn item on the create path and returns its id. The id is the SLOT'S
    /// stable draft id — NOT a fresh UUID per call — so the rename-and-retry loop after a `.nameFlagged` /
    /// `.capReached` / `.storeBanned` alert re-saves the SAME row (an upsert) instead of stacking a
    /// duplicate item on every attempt, while a save after switching slots gets that slot's own id and
    /// so its own row (a session-wide id made it silently replace the previous slot's saved item).
    /// Internal (not private) so the dedup tests can drive it; `slot` is passed explicitly for the
    /// same reason.
    ///
    /// `@discardableResult` is safe here (R7): the returned value is an IDENTIFIER, not a
    /// success/failure signal — `store.saveCustomItem` has already happened when this returns, and
    /// only `save()` needs the id (to equip the new item).
    @discardableResult
    func persistDraftItem(named finalName: String, texture: ItemGridTexture, slot: ItemSlot) -> UUID {
        let item = CustomizationItem(
            id: editingItem?.id ?? draftID(for: slot),
            name: finalName,
            slot: slot,
            texture: texture,
            designer: ItemDesigner(id: store.localDesignerID),
            isShareable: false,
            price: ClothingShopLimits.clampedPrice(price)
        )
        store.saveCustomItem(item)
        return item.id
    }

    private func save() {
        guard canSave else { return }
        // Everything below persists the canvas, so from here on there is nothing unsaved to warn
        // about — including on the refusal branches that deliberately keep the user on this screen.
        didSave = true
        savedPixels = pixels
        let texture = ItemGridTexture(cols: slot.gridCols, rows: slot.gridRows, palette: palette, pixels: pixels)
        // R5: the UNLISTED save also persists this name (the shop gate's moderation only runs when
        // listing), and it later renders in the Wardrobe and on the companion — so apply the same
        // charset/length sanitizer here, and fall back to the slot label when nothing survives.
        let sanitized = ItemNameModeration.sanitizedName(name)
        let finalName = sanitized.isEmpty ? slot.label : sanitized
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
            itemID = persistDraftItem(named: finalName, texture: texture, slot: slot)
            store.equipCustomItem(id: itemID, slot: slot)
        }

        guard canSell, isShareable else {
            // Toggled off (or not sellable): make sure it isn't listed, then leave.
            if canSell { store.unlistCustomItem(id: itemID) }
            leaveStudio()
            return
        }

        switch store.listCustomItemForSale(id: itemID, price: price) {
        case .listed:
            leaveStudio()
        case .nameFlagged:
            shopAlert = .nameFlagged   // stay so the user can rename and re-save
        case .capReached:
            shopAlert = .capReached
        case .notAllowed:
            leaveStudio()              // not your design (unreachable — `canSell` guards); item saved, just unlisted
        case .storeBanned:
            shopAlert = .storeBanned
        }
    }

    // MARK: - Helpers

    private static func blankPixels(for slot: ItemSlot) -> [Int] {
        Array(repeating: ItemGridTexture.transparent, count: slot.gridCols * slot.gridRows)
    }

    /// A minimally-painted canvas (one filled row) used ONLY by the UI-test seed hook, so `canSave` is
    /// true without a paint gesture. Release builds never reach this — `shouldSeedStudioCanvas` is a
    /// hard-coded `false` outside DEBUG.
    private static func seededPixels(for slot: ItemSlot) -> [Int] {
        var pixels = blankPixels(for: slot)
        let row = slot.gridRows / 2
        for x in 0..<slot.gridCols {
            pixels[row * slot.gridCols + x] = 0
        }
        return pixels
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
