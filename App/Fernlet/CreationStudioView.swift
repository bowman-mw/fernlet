import SwiftUI
import FernletDomainModel
import FernletUI

/// The Animal-Crossing-style fabric editor for custom companion clothing.
///
/// The user paints a per-slot pixel grid from a fixed palette on a ``ZoomablePixelCanvas`` (with
/// per-stroke undo, mirror mode, and per-slot draft buffers so switching slots never loses a
/// drawing — the slot picker is Fernlet chips, and the palette is pinned above the Next bar so a
/// colour is pickable before the first stroke), then taps Next into the confirmation step to name
/// it and optionally list it in their shop — the save is unlisted-first, so a flagged name or a
/// full shop still keeps the item. New
/// creations auto-equip so the result is immediately visible on the companion.
///
/// The drawing screen does not scroll (owner decision 2026-09-29): the live preview sits beside
/// the slot chips, Clear joins Undo and Mirror in one tool row, and the canvas takes the height
/// that is left, as ``CreationStudioLayout`` decides from measured heights. Only where the controls
/// cannot fit at all — accessibility text sizes on small iPhones, Display Zoom on an SE-class
/// phone, and landscape — does the page scroll, and then only from touches outside the canvas:
/// the canvas owns every touch that starts on it (``ZoomablePixelCanvas``). Pushed within the
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
    /// How the host pops this studio off ITS stack. Supplied by ``WardrobeView``, which owns both
    /// pushes into here; nil only when nothing owns the push (previews, tests), where the
    /// environment `dismiss` is the right exit. See ``leaveStudio()`` for why the environment
    /// action alone is not enough.
    var onExit: (() -> Void)?

    @Environment(\.dismiss) private var dismiss
    /// Stacks the tool row into a column at accessibility sizes (see `canvasTools`).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
    /// The three measurements ``CreationStudioLayout`` reads, in points: the page's visible height
    /// and the header and tool rows. Zero until first measured, which the layout reads as "does not
    /// fit" for the one frame before the real numbers land.
    @State private var viewportHeight: CGFloat = 0
    @State private var headerHeight: CGFloat = 0
    @State private var toolsHeight: CGFloat = 0
    /// The measured held-item note and previews under the canvas (W-07).
    @State private var noteHeight: CGFloat = 0
    @State private var previewsHeight: CGFloat = 0
    /// Returned to the top whenever the layout comes to fit (a text-size change back down, say): with
    /// scrolling switched off, an offset left over from the scrolling layout could not be undone.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    /// Bounded so a long session can't grow without limit. An outfit canvas is 18×13 Ints ≈ 2 KB, so
    /// 32 snapshots is ~60 KB worst case — irrelevant next to the images this app already holds.
    private static let maxUndoSteps = 32

    private let palette = ItemDesignPalette.hexes

    /// The gap between the header, the tool row and the canvas.
    private static let sectionSpacing: CGFloat = 12
    /// 12pt, not 20. The canvas is the point of this screen and its cell size is set by the room
    /// around it, so page padding is the one thing directly costing drawing resolution — and it was
    /// being paid twice (here and inside `editorCanvas`).
    private static let pagePadding: CGFloat = 12
    /// The live pixel preview beside the slot chips: three points a pixel, the map's own size, so the
    /// 24 × 24 item frame is 72 pt and shares the chips' two rows (`comp-studio-hat`).
    private static let previewScale: CGFloat = 3

    init(store: FernletStore,
         editingItem: CustomizationItem? = nil,
         draftIsDirty: Binding<Bool>? = nil,
         onExit: (() -> Void)? = nil) {
        self.store = store
        self.editingItem = editingItem
        self.draftIsDirty = draftIsDirty
        self.onExit = onExit
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
            // The UI-test seed paints the canvas so "Next" is enabled without a stroke: a blank
            // canvas leaves the confirmation step unreachable, and the flow tests are about that
            // step, not about painting. (Synthesized strokes do reach the canvas —
            // `CreationStudioCanvasUITests` drives them.)
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
        let layout = studioLayout
        ScrollView {
            VStack(spacing: Self.sectionSpacing) {
                studioHeader
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headerHeight = $0 }
                canvasTools
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { toolsHeight = $0 }
                editorCanvas
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .frame(height: layout.canvasHeight)
                studioFooter(showsPreviews: layout.showsPreviews)
            }
            .padding(Self.pagePadding)
        }
        // Owner decision 2026-09-29: drawing on a page that moves is what made this screen hard to
        // use, so it does not scroll whenever everything fits — every iPhone in portrait at the
        // default text size and standard Display Zoom (measured down to an iPhone SE). See
        // `CreationStudioLayout` for where it cannot fit: accessibility sizes on small phones,
        // a Display-Zoomed SE, and landscape.
        .scrollDisabled(layout.fits)
        .scrollBounceBehavior(.basedOnSize, axes: .vertical)
        .scrollPosition($scrollPosition)
        // `containerSize` is already the page INSIDE its safe area — between the navigation bar
        // and the pinned palette (measured 2026-09-29 on an iPhone 17: 556pt, with 70 + 186pt of
        // insets that `visibleRect` spans and `containerSize` does not), so the insets must not be
        // subtracted again; doing so roughly halves the canvas.
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.containerSize.height
        } action: { _, visibleHeight in
            viewportHeight = visibleHeight
        }
        .onChange(of: layout.fits) { _, fits in
            if fits { scrollPosition.scrollTo(edge: .top) }
        }
        .fernletPageBackground()
        .tint(Color.moss)
        // Under the Today panel's plate (design `b2-studio`): ‹ Back, New item, ✕. While there is
        // unsaved paint the plate's Back asks first and the edge swipe is off, as the toolbar Back
        // below does in a sheet's own bar.
        .fernletGuardedPushedPage(editingItem == nil ? Self.newItemTitle : Self.editItemTitle,
                                  isGuarded: hasUnsavedDrawing, onBlockedBack: { askingToDiscard = true })
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            // The editor screen is just the drawing now; naming + listing move to a confirmation
            // step. The palette is pinned here, above Next (3e): a colour is pickable before the
            // first stroke, and the fitted canvas ends just above it.
            VStack(spacing: 0) {
                pinnedPalette
                SheetSaveBar(label: "Next", disabled: !canSave) { showingConfirmation = true }
            }
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

    /// "New item", the studio's title for a new design.
    static let newItemTitle = LocalizedStringResource("New item", comment: "Creation Studio title while designing a new companion item")
    /// "Edit item", the studio's title for an existing design.
    static let editItemTitle = LocalizedStringResource("Edit item", comment: "Creation Studio title while editing one of the user's companion items")
    /// "Save item", the confirmation step's title.
    static let saveItemTitle = LocalizedStringResource("Save item", comment: "Creation Studio: the step that names a new item and lists it in the shop")

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
    ///
    /// The exit is driven by explicit state, NOT by the environment `dismiss`, because "Save to
    /// closet" leaves from the confirmation step — one push ABOVE the studio. From there the
    /// studio's own `DismissAction` no longer pops: it degrades to dismissing the nearest
    /// presentation, which is the whole customization sheet, dropping the user on Home instead of
    /// back in the closet holding the thing they just saved. (From the editor, where the studio IS
    /// the top screen, the same action pops correctly — which is why only the save path looked
    /// broken.) So: pop our own confirmation step, then ask the host to pop us. `dismiss` remains
    /// the fallback for a studio nobody owns the push for (previews, tests).
    private func leaveStudio() {
        draftIsDirty?.wrappedValue = false
        showingConfirmation = false
        if let onExit {
            onExit()
        } else {
            dismiss()
        }
    }

    /// The fit-or-scroll decision for the current measurements (see ``CreationStudioLayout``).
    private var studioLayout: CreationStudioLayout {
        CreationStudioLayout(viewportHeight: viewportHeight, headerHeight: headerHeight,
                             toolsHeight: toolsHeight, footerHeight: slot == .heldItem ? noteHeight : 0,
                             previewsHeight: previewsHeight, spacing: Self.sectionSpacing, padding: Self.pagePadding)
    }

    // MARK: - Sections

    /// The live pixel preview beside the slot chips — one row rather than two, which is most of the
    /// height the canvas needed to fit without scrolling — then the kind's size in squares
    /// (`comp-studio-hat`). The edit path has no chips, so its preview sits on its own.
    private var studioHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                // Decorative: a live render of the item being designed, on the pixel companion at the
                // map's scale (W-06b). The chips and fields are the semantics.
                StudioPixelPreview(store: store, items: previewEquipped, scale: Self.previewScale)
                if editingItem == nil {
                    slotPicker
                }
            }
            .frame(maxWidth: .infinity, alignment: editingItem == nil ? .leading : .center)
            StudioSizeLine(slot: slot, name: companionName)
        }
    }

    /// Under the canvas (W-07): the held item's note, and the up-close and on-the-map previews where
    /// they fit without turning scrolling on (``CreationStudioLayout/showsPreviews``).
    @ViewBuilder
    private func studioFooter(showsPreviews: Bool) -> some View {
        if slot == .heldItem {
            StudioHeldNote(name: companionName)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { noteHeight = $0 }
        }
        if showsPreviews {
            StudioPreviewsRow(store: store, items: previewEquipped)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { previewsHeight = $0 }
        }
    }

    /// The companion's name (``FernletStore/worldCompanionName``), for the Studio's words.
    private var companionName: String {
        CustomizeNightCopy.companionName(store)
    }

    /// The slot picker as Fernlet chips (3e), replacing the system segmented control — the one
    /// non-Fernlet control this screen carried. Selection state and the buffer-stashing
    /// `onChange` below are unchanged.
    private var slotPicker: some View {
        FlowLayout(spacing: 8) {
            ForEach(ItemSlot.allCases) { candidate in
                Button(candidate.label) {
                    if slot != candidate { FernletFeedback.system.play(.tick) }
                    slot = candidate
                }
                .buttonStyle(ChipButtonStyle(selected: slot == candidate))
            }
        }
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

    /// Undo · Clear canvas · Mirror, sat directly above the canvas where the drawing hand already
    /// is. Clear lived under the canvas until the screen stopped scrolling (2026-09-29).
    ///
    /// One row, whose titles wrap rather than truncate as text grows; at accessibility sizes, one
    /// button per row. The switch is an `AnyLayout`, not a `ViewThatFits`, because the buttons must
    /// keep their identity across it: `ViewThatFits` swaps in a different subtree as text grows, and
    /// the accessibility audit reads the titles in it as Dynamic Type left partially unsupported
    /// (measured on this screen, 2026-09-29).
    private var canvasTools: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 0))
            : AnyLayout(HStackLayout(spacing: 12))
        return layout {
            undoButton
            Spacer(minLength: 0)
            clearCanvasButton
            Spacer(minLength: 0)
            mirrorButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }

    private var undoButton: some View {
        Button {
            undoTapped()
        } label: {
            Label("Undo", systemImage: "arrow.uturn.backward")
                .font(.fernlet(.label))
        }
        .buttonStyle(.plain)
        .foregroundStyle(undoStack.isEmpty ? Color.slate.opacity(0.4) : Color.fern)
        .disabled(undoStack.isEmpty)
        .fernletTapTarget()
        .accessibilityIdentifier("studio.undo")
    }

    private var mirrorButton: some View {
        Button {
            FernletFeedback.system.play(.tick)
            isSymmetric.toggle()
        } label: {
            Label("Mirror", systemImage: isSymmetric ? "square.righthalf.filled" : "rectangle.split.2x1")
                .font(.fernlet(.label))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isSymmetric ? Color.fern : Color.slate)
        .fernletTapTarget()
        .accessibilityIdentifier("studio.mirror")
        .accessibilityAddTraits(isSymmetric ? [.isSelected] : [])
    }

    private var editorCanvas: some View {
        // Zoomable/pannable surface (#15): pinch to zoom, two fingers to pan, one finger paints. The
        // pixel/undo/symmetry logic stays here; the canvas just reports the touched cell + stroke start.
        ZoomablePixelCanvas(
            pixels: $pixels,
            cols: Self.canvasSize(for: slot).cols,
            rows: Self.canvasSize(for: slot).rows,
            palette: palette,
            // The companion faintly under the canvas, so a hat sits on the head (`comp-studio-hat`).
            ghost: StudioGhost.cells(store: store, slot: slot),
            onStrokeBegan: { beginStroke() },
            onStrokeCancelled: { cancelStroke() },
            onPaintCell: { x, y in paintCell(x: x, y: y) }
        )
        // "Drawing canvas, 18 by 11" (`comp-studio-hat`), on the canvas itself, so the hint over it keeps its own
        // element and id.
        .accessibilityLabel(Text(verbatim: Self.canvasSpokenName(for: slot)))
        .accessibilityIdentifier("studio.canvas")
        // Fitted into whatever slot `body` gives it — the full width, or the height the layout
        // left, whichever binds first — so the card hugs the grid rather than the slot.
        .aspectRatio(CGFloat(Self.canvasSize(for: slot).cols) / CGFloat(Self.canvasSize(for: slot).rows), contentMode: .fit)
        // The corner squares (paint or the companion's ghost) stay inside the card's rounded frame.
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(WorldPalette.paperLight)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(WorldPalette.ink, lineWidth: 3)
        )
        .overlay {
            // Gentle first-touch hint when the grid is still blank.
            if isCanvasBlank {
                Text("Drag to paint · pinch to zoom")
                    .font(.fernlet(.body))
                    // The canvas the layout leaves can be small (about 220×180pt at the largest
                    // text size on an iPhone SE), so the hint shrinks to fit rather than truncate
                    // to "pinc…" — it is the only on-screen word about pinch-to-zoom.
                    .multilineTextAlignment(.center)
                    .minimumScaleFactor(0.5)
                    .padding(8)
                    // Full-strength ink: over the paper and the companion's ghost the dim ink read 4.47:1.
                    .foregroundStyle(WorldPalette.ink)
                    .allowsHitTesting(false)
                    // Words on screen, so VoiceOver can read them (hidden, they were the editor's "Potentially
                    // inaccessible text" audit finding); its own id, never the canvas's `studio.canvas`.
                    .accessibilityIdentifier("studio.canvasHint")
            }
        }
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldPalette.ink.opacity(0.22)).offset(y: 3)
        }
    }

    /// True while every cell is still transparent — drives the "Drag to paint" hint.
    private var isCanvasBlank: Bool {
        !pixels.contains { $0 != ItemGridTexture.transparent }
    }

    /// The palette, pinned above the Next bar since the 2026-08-21 redesign (3e) — it used to
    /// scroll below the canvas, so picking a colour before the first stroke meant scrolling past
    /// the thing you were about to paint.
    private var pinnedPalette: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                eraserSwatch
                ForEach(Array(palette.enumerated()), id: \.offset) { index, hex in
                    swatch(index: index, hex: hex)
                }
            }
            .padding(.vertical, 2)
            .padding(.horizontal, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(WorldPalette.page)
    }

    private var eraserSwatch: some View {
        Button {
            chooseColor(ItemGridTexture.transparent)
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
            chooseColor(index)
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

    /// Spoken names for `ItemDesignPalette.hexes`, in its order — one catalog key each.
    ///
    /// The ARRAY is the palette's order (a token: index N must keep naming `hexes[N]`); each entry
    /// is display, so each is keyed and commented individually, exactly as
    /// `CompanionAssetColor.label` does for the nine companion colours. An earlier pass routed
    /// these through `Text(verbatim:)`, which type-checks and reads correctly in English while
    /// leaving all sixteen names out of every catalog — the localization loss this whole round is
    /// about, laundered through the one modifier that is exempt from the wall by construction.
    private static var paletteNames: [String] {
        [
            String(localized: "palette.nearBlack", defaultValue: "Near-black",
                   comment: "Design-canvas colour name: the darkest swatch, spoken by VoiceOver"),
            String(localized: "palette.bark", defaultValue: "Bark",
                   comment: "Design-canvas colour name: the app's dark brown"),
            String(localized: "palette.taupe", defaultValue: "Taupe",
                   comment: "Design-canvas colour name: a soft grey-brown"),
            String(localized: "palette.cream", defaultValue: "Cream",
                   comment: "Design-canvas colour name: the app's off-white card colour"),
            String(localized: "palette.parchment", defaultValue: "Parchment",
                   comment: "Design-canvas colour name: the app's background off-white"),
            String(localized: "palette.white", defaultValue: "White",
                   comment: "Design-canvas colour name: pure white"),
            String(localized: "palette.moss", defaultValue: "Moss",
                   comment: "Design-canvas colour name: the app's green"),
            String(localized: "palette.fern", defaultValue: "Fern",
                   comment: "Design-canvas colour name: a lighter green"),
            String(localized: "palette.terracotta", defaultValue: "Terracotta",
                   comment: "Design-canvas colour name: the app's warm orange-red"),
            String(localized: "palette.sun", defaultValue: "Sun",
                   comment: "Design-canvas colour name: yellow"),
            String(localized: "palette.rose", defaultValue: "Rose",
                   comment: "Design-canvas colour name: pink"),
            String(localized: "palette.plum", defaultValue: "Plum",
                   comment: "Design-canvas colour name: dark purple"),
            String(localized: "palette.slateBlue", defaultValue: "Slate blue",
                   comment: "Design-canvas colour name: a muted blue"),
            String(localized: "palette.deepSlate", defaultValue: "Deep slate",
                   comment: "Design-canvas colour name: a dark blue-grey"),
            String(localized: "palette.red", defaultValue: "Red",
                   comment: "Design-canvas colour name: red"),
            String(localized: "palette.emerald", defaultValue: "Emerald",
                   comment: "Design-canvas colour name: a deep green"),
        ]
    }

    /// `Text` rather than `String` (review T2-1): these are spoken colour names, and a `String`
    /// reaches `.accessibilityLabel(_:)` through the verbatim overload.
    ///
    /// `Text(verbatim:)` here is honest — the name arrives already resolved from the keyed list
    /// above — rather than a way of avoiding the lookup, which is what it was before.
    private static func paletteName(at index: Int) -> Text {
        let names = paletteNames
        guard index >= 0, index < names.count else { return Text("Color \(index + 1)") }
        return Text(verbatim: names[index])
    }

    /// Selected → moss ring; unselected → a hairline so light swatches (cream, parchment, white) never
    /// vanish into the cream card behind them (the 6b "palette that never disappears" fix).
    private func selectionRing(isSelected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .strokeBorder(isSelected ? WorldPalette.moss : WorldPalette.ink, lineWidth: isSelected ? 3 : 2)
    }

    /// Clear-canvas lives on the editor (it's a drawing action), in the tool row since 2026-09-29;
    /// naming + shop listing moved to the confirmation step.
    private var clearCanvasButton: some View {
        Button(role: .destructive) {
            // Snapshot before blanking so Clear is a single undoable step; guard skips a no-op snapshot on
            // an already-blank canvas.
            if !isCanvasBlank {
                pushUndoSnapshot()
                // Clear is undoable, so it is a change to the drawing rather than a loss: `moved`,
                // with the blank grid as its twin. A blank canvas has nothing to clear.
                FernletFeedback.system.play(.moved)
            }
            pixels = Self.blankPixels(for: slot)
        } label: {
            // `terracottaInk`, the destructive TEXT token: plain `terracotta` measured 4.16:1 here and
            // has no Increase Contrast twin, so it failed on every route.
            Label("Clear canvas", systemImage: "trash")
                .font(.fernlet(.label))
                .foregroundStyle(Color.terracottaInk)
        }
        .buttonStyle(.plain)
        .fernletTapTarget()
        .accessibilityIdentifier("studio.clearCanvas")
    }

    // MARK: - Confirmation (name + shop) — the follow-up "save" step

    /// The follow-up screen after drawing: a preview of the finished item, the name, and (for your own
    /// designs) whether to list it in your shop — then the actual save. Reached via "Next" on the editor.
    private var confirmationScreen: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // The previews (design `b2-studio-save`): the pixel companion awake, wearing the
                // drawing (W-06b). One element with a real label: this step has no header above it, so
                // VoiceOver hears the drawing survived.
                CustomizePreviewCard(store: store, previewItems: previewEquipped,
                                     spokenName: Text("Preview of your item on your companion"), night: .awake)
                .accessibilityIdentifier("studio.confirm.preview")

                SheetField("Name") {
                    // R3: bounded where the text enters, at the same length the shop's name
                    // moderation enforces.
                    TextField("Name your item", text: Binding(
                        get: { name },
                        set: { name = String($0.prefix(ItemNameModeration.maxNameLength)) }
                    ), prompt: .fieldPrompt("Name your item"))
                    .sheetTextInput()
                    .accessibilityIdentifier("studio.confirm.name")
                }

                if canSell {
                    shopSection
                }

                // `comp-studio-save`: the drawing is already its size on the companion.
                StudioSaveNote(name: companionName)
            }
            .padding(20)
            .padding(.bottom, 24)
        }
        .fernletPageBackground()
        .tint(Color.moss)
        .fernletPushedPage(Self.saveItemTitle)
        .navigationBarTitleDisplayMode(.inline)
        // The name field's keyboard "Done", on this page because it is always pushed (the
        // customization sheet's stack or the Wardrobe's): a Done declared outside the stack, or on
        // another of its pages, never reaches it.
        .keyboardDoneToolbar()
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
                                .font(FernletFramedFont.rowTitle)
                                .foregroundStyle(WorldPalette.bark)
                            Text("Friends nearby can buy it for their companion.")
                                .font(FernletFramedFont.rowDetail)
                                .foregroundStyle(WorldPalette.dim)
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
                .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(WorldPalette.ink, lineWidth: 2)
                )
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous).fill(WorldPalette.ink.opacity(0.22)).offset(y: 3)
                }
            }

            if isShareable {
                Text(shopHint)
                    .font(FernletFramedFont.note)
                    .foregroundStyle(WorldPalette.dim)
            }
        }
    }

    // MARK: - Behavior

    private var canSave: Bool {
        !ItemGridTexture(cols: Self.canvasSize(for: slot).cols, rows: Self.canvasSize(for: slot).rows, palette: palette, pixels: pixels).isBlank
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
            texture: ItemGridTexture(cols: Self.canvasSize(for: slot).cols, rows: Self.canvasSize(for: slot).rows, palette: palette, pixels: pixels),
            designer: ItemDesigner(id: store.localDesignerID)
        )
    }

    /// Paints the grid cell reported by the zoomable canvas (plus its mirror when symmetry is on). The
    /// canvas maps the touch to a cell at any zoom level; this owns the colour + symmetry.
    private func paintCell(x: Int, y: Int) {
        setCell(x: x, y: y)
        if isSymmetric {
            // Every canvas is even-width (18/16/18/10), so the axis falls cleanly between the two centre
            // columns and there is no self-mirroring centre column to special-case.
            setCell(x: Self.canvasSize(for: slot).cols - 1 - x, y: y)
        }
    }

    /// Paints one cell. Extracted so symmetry can paint both sides: the "already this colour" guard used
    /// to early-return out of `paint` itself, which would have silently skipped the mirrored cell
    /// whenever the touched cell happened to already match the selected colour.
    private func setCell(x: Int, y: Int) {
        guard x >= 0, x < Self.canvasSize(for: slot).cols, y >= 0, y < Self.canvasSize(for: slot).rows else { return }
        let index = y * Self.canvasSize(for: slot).cols + x
        guard index >= 0, index < pixels.count, pixels[index] != selectedColor else { return }
        pixels[index] = selectedColor
    }

    /// Snapshots the canvas before a stroke mutates it. Called once per stroke, from the drag's first
    /// `onChanged`.
    private func pushUndoSnapshot() {
        undoStack.append(pixels)
        if undoStack.count > Self.maxUndoSteps { undoStack.removeFirst() }
    }

    /// The Undo button: a tick as the last stroke comes back off the canvas.
    private func undoTapped() {
        guard !undoStack.isEmpty else { return }
        FernletFeedback.system.play(.tick)
        undo()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        pixels = previous
    }

    /// A stroke (or a single dab) started: snapshot for undo, and ONE tick under the finger (report
    /// C6). Never per cell: a drag samples dozens of cells a second, and a tick on each would be a
    /// buzz. The canvas reports this once per stroke (`ZoomablePixelCanvas`).
    private func beginStroke() {
        pushUndoSnapshot()
        FernletFeedback.system.play(.tick)
    }

    /// A palette pick (a colour or the eraser): a tick when it changes the brush.
    private func chooseColor(_ color: Int) {
        if selectedColor != color { FernletFeedback.system.play(.tick) }
        selectedColor = color
    }

    /// A zoom/pan interrupted a stroke mid-drag: pop the snapshot that stroke pushed in `onStrokeBegan`
    /// back into `pixels`, so a staggered-pinch stray dab is reverted rather than left painted. Reuses the
    /// undo machinery — the interrupted stroke's snapshot is exactly the top of the stack. Silent: the
    /// person didn't ask for it, and the stroke's start already ticked.
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
        let texture = ItemGridTexture(cols: Self.canvasSize(for: slot).cols, rows: Self.canvasSize(for: slot).rows, palette: palette, pixels: pixels)
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
            FernletFeedback.system.play(.done)
            leaveStudio()
            return
        }

        let outcome = store.listCustomItemForSale(id: itemID, price: price)
        FernletFeedback.system.play(Self.saveFeedbackEvent(for: outcome))
        switch outcome {
        case .listed:
            leaveStudio()
        case .nameFlagged:
            shopAlert = .nameFlagged   // stay so the user can rename and re-save
        case .capReached:
            shopAlert = .capReached
        case .notAllowed:
            leaveStudio()              // not your design (unreachable — `canSell` guards); item saved, just unlisted
        case .storeBanned(let remainingSeconds):
            shopAlert = .storeBanned(remainingSeconds: remainingSeconds)
        }
    }

    /// What "Save to closet" feels like once the shop has answered (report B16): `done` when the
    /// studio closes on a saved item, `caveat` when a refused listing keeps the person here — the
    /// item IS saved, unlisted, and the alert says why. Felt at once, before the alert or the pop.
    static func saveFeedbackEvent(for outcome: FernletStore.ShopListingResult) -> FernletFeedbackEvent {
        switch outcome {
        case .listed, .notAllowed: .done
        case .nameFlagged, .capReached, .storeBanned: .caveat
        }
    }

    // MARK: - Helpers

    private static func blankPixels(for slot: ItemSlot) -> [Int] {
        Array(repeating: ItemGridTexture.transparent, count: Self.canvasSize(for: slot).cols * Self.canvasSize(for: slot).rows)
    }

    /// A minimally-painted canvas (one filled row) used ONLY by the UI-test seed hook, so `canSave` is
    /// true without a paint gesture. Release builds never reach this — `shouldSeedStudioCanvas` is a
    /// hard-coded `false` outside DEBUG.
    private static func seededPixels(for slot: ItemSlot) -> [Int] {
        var pixels = blankPixels(for: slot)
        let row = Self.canvasSize(for: slot).rows / 2
        for x in 0..<Self.canvasSize(for: slot).cols {
            pixels[row * Self.canvasSize(for: slot).cols + x] = 0
        }
        return pixels
    }

    /// Builds an editor pixel buffer sized exactly to the item's canvas (its box on the companion,
    /// ``canvasSize(for:)``), holding the art exactly as the companion wears it: a piece drawn at its
    /// box's size is copied 1:1, and one drawn bigger (made before the Studio went to the companion's
    /// own scale, or bought from a friend on the old Fernlet) is shrunk to fit and placed as the map
    /// places it (``WorldItemBox/fit(_:slot:)``). Palette indices are remapped onto the editor palette
    /// by exact hex match (unmatched → transparent); a matching palette is a fast copy. Saving then
    /// re-encodes at the canvas size, so the first edit of an old piece keeps what the person saw.
    /// Internal rather than private so the path is reachable from tests — it is the one path here that
    /// can silently destroy a user's art, and it must not be verified by eye.
    static func editorPixels(for item: CustomizationItem, palette: [String]) -> [Int] {
        let (cols, rows) = canvasSize(for: item.slot)
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
        let box = WorldItemBox.box(for: item.slot)
        let fitted = WorldItemBox.fit(texture, slot: item.slot)
        let left = fitted.x - box.x, top = fitted.y - box.y
        for y in 0..<fitted.height {
            for x in 0..<fitted.width {
                let source = fitted.indices[y * fitted.width + x]
                let (cx, cy) = (left + x, top + y)
                guard source >= 0, source < texture.palette.count, cx >= 0, cx < cols, cy >= 0, cy < rows else { continue }
                buffer[cy * cols + cx] = samePalette ? source : (lookup[texture.palette[source].uppercased()] ?? ItemGridTexture.transparent)
            }
        }
        return buffer
    }

    /// A slot's canvas: its box on the companion, one square per sprite pixel (W-07, draft 2) — Hat
    /// 18 × 11, Face 16 × 8, Outfit 18 × 13, Held item 10 × 12. Every width is even, so Mirror's axis
    /// falls between two columns. (`ItemSlot.gridCols`/`gridRows` stay the shop's acceptance bounds.)
    static func canvasSize(for slot: ItemSlot) -> (cols: Int, rows: Int) {
        let box = WorldItemBox.box(for: slot)
        return (box.width, box.height)
    }

    /// What VoiceOver calls the canvas: "Drawing canvas, 18 by 11".
    static func canvasSpokenName(for slot: ItemSlot) -> String {
        let size = canvasSize(for: slot)
        return String(localized: "worldStudio.canvas", defaultValue: "Drawing canvas, \(size.cols) by \(size.rows)",
                      comment: "Creation Studio, VoiceOver: the drawing canvas and its size in squares, columns by rows. Spanish: 'Lienzo, 18 por 11'")
    }
}
