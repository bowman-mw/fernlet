import SwiftUI
import FernletDomainModel
import FernletUI

/// The Quick-log shortcuts editor (2026-08-21 redesign, artboard 5g — SETT-23): ONE reorderable
/// six-row list instead of six slots that each redraw the whole chip palette — roughly 48 chips
/// become six rows. Drag to reorder; the order here is the order on Home. Tapping a row opens the
/// palette for that slot only, inline, with the current pick selected.
///
/// Invariants carried over from the old slot editor (they are the load-bearing part):
/// - The editor edits the **STORED** array via `FernletShortcut.normalizedQuickLog` /
///   `FernletStore.setQuickLogItems` — never a visibility-filtered one. Filtering the saved array
///   is destructive: `normalizedQuickLog` caps at 6 and back-fills, so a hidden `.periodTracking`
///   would be dropped from the SAVED layout and un-hiding could not bring it back. Home is where
///   display filtering happens (`visibleQuickLog`).
/// - The palette **fails closed** through `FernletShortcut.selectableQuickLogItems(visibility:)`:
///   when period surfaces are hidden the two cycle chips are ABSENT from the list, not shown
///   disabled. The slot's own current pick stays selectable even while hidden, so an
///   already-chosen chip renders as selected rather than vanishing mid-edit.
/// - The palette shows every other option **including ones used elsewhere**, so nothing silently
///   disappears — picking a chip that lives in another slot swaps the two slots.
/// - `.intimacyTracking` re-checks the age floor at the point of use.
///
/// Display names come from `FernletShortcut.title` — the display half of that enum's token/display
/// fork (the "Period" → "Cycle page" rename is a title-property change in `NavigationEnums.swift`,
/// never a rawValue change).
///
/// Dynamic Type (5g·AX3): the system drag handles hold their size while rows grow, and the inline
/// palette's `FlowLayout` naturally stacks one chip per row.
///
/// Under the World's framed look (`b2-settings-quicklog`) the list leaves edit mode: the system grip
/// drew on the card's right frame, so each row draws the ink ``ReorderGrip`` inside the card and a row
/// is pressed and dragged to move (List's own `onMove` drag). Every row also carries "Move up" and
/// "Move down" actions, so VoiceOver and Voice Control can reorder without dragging.
struct QuickLogShortcutsEditor: View {
    @Bindable var store: FernletStore
    /// The slot whose inline palette is open, by position. Nil when no slot is being chosen.
    @State private var editingSlot: Int?

    /// The layout being edited: the STORED array, deliberately NOT visibility-filtered (see the
    /// type doc — filtering the saved array destroys the hidden user's layout irreversibly).
    private var items: [FernletShortcut] {
        FernletShortcut.normalizedQuickLog(store.settings.quickLogItems)
    }

    /// The World's framed look: the six slots are one framed card of rows (`b2-settings-quicklog`).
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        List {
            // The two notes are rows on the page, not the list's header and footer: a plain list
            // draws its sticky footer on a white bar over the dotted page.
            note("Drag to reorder. Tap one to swap it.")
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                slotRow(index: index, item: item)
                    .fernletFramedListRow(isFirst: index == 0, isLast: index == items.count - 1)
            }
            .onMove(perform: moveItems)
            .listRowBackground(look == nil ? Color.cream : nil)
            note("Six tiles, in this order, in Log.")
        }
        // A plain list under the look, so the rows draw the framed card themselves.
        .modifier(QuickLogListStyle(framed: look != nil))
        // Without the look, always in edit mode: that is what makes `onMove` handles render, and this
        // page has no other editing state for a button to toggle. Under the look the rows draw their
        // own grip and List's press-and-drag reorders them.
        .environment(\.editMode, .constant(look == nil ? .active : .inactive))
        .scrollContentBackground(.hidden)
        .fernletPageBackground()
        .fernletPushedPage("Quick-log shortcuts")
    }

    /// A note on the page between the list's rows: the page's own background, no separator, never
    /// movable.
    private func note(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(FernletFramedFont.note)
            .foregroundStyle(look?.dim ?? Color.slate)
            .fernletWrappingText()
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
            .listRowInsets(EdgeInsets(top: 8, leading: 22, bottom: 8, trailing: 22))
            .moveDisabled(true)
    }

    /// One slot: the current pick, and — while this slot is being chosen — its inline palette.
    ///
    /// The row toggles its palette through a tap gesture rather than a full-row `Button`: the list
    /// is permanently in edit mode for its drag handles, and a row-sized button there fights the
    /// reorder affordance, while a tap gesture composes with it.
    private func slotRow(index: Int, item: FernletShortcut) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Label {
                    Text(verbatim: item.title)
                        .font(FernletFramedFont.rowTitle)
                        .foregroundStyle(look?.text ?? Color.bark)
                } icon: {
                    // The tile's pixel icon (`b2-settings-quicklog`); today's symbol without the look.
                    if look != nil {
                        WorldSpriteView(sprite: SettingsShortcutSprite.sprite(for: item), scale: 2)
                            .frame(width: 36)
                    } else {
                        Image(systemName: item.systemImage)
                            .foregroundStyle(Color.moss)
                    }
                }
                .fernletWrappingText()
                Spacer(minLength: 4)
                if editingSlot == index {
                    Text("Choosing")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(look?.dim ?? Color.slate)
                }
                if look != nil { ReorderGrip() }
            }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
            .onTapGesture {
                editingSlot = editingSlot == index ? nil : index
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(named: Text("Move up")) { step(index, by: -1) }
            .accessibilityAction(named: Text("Move down")) { step(index, by: 1) }
            .accessibilityIdentifier("settings.quickLog.slot.\(index)")
            if editingSlot == index {
                palette(for: index, current: item)
            }
        }
    }

    /// The palette for ONE slot: every currently-offerable option (fail-closed via
    /// `selectableQuickLogItems`), plus the slot's own pick even when hidden, with chips used by
    /// other slots included — choosing one swaps the two slots.
    private func palette(for index: Int, current: FernletShortcut) -> some View {
        FlowLayout(spacing: 8) {
            ForEach(paletteItems(current: current)) { option in
                Button {
                    choose(option, at: index)
                } label: {
                    Label(option.title, systemImage: option.systemImage)
                }
                .buttonStyle(ChipButtonStyle(selected: option == current))
            }
        }
    }

    /// The offerable chips in `allCases` order: the visibility gate withholds hidden surfaces
    /// (ABSENT, not disabled), while the slot's current pick stays so the selection can render.
    private func paletteItems(current: FernletShortcut) -> [FernletShortcut] {
        let visibility = store.sensitiveSurfaceVisibility
        return FernletShortcut.allCases.filter { $0 == current || visibility.allows($0) }
    }

    /// Commits one pick to the STORED array. A chip already used by another slot swaps into this
    /// one (nothing silently disappears); the intimacy age floor is re-checked at the point of use.
    private func choose(_ item: FernletShortcut, at index: Int) {
        guard store.isIntimateLoggingAllowed || item != .intimacyTracking else { return }
        var updated = items
        guard updated.indices.contains(index) else { return }
        if let existingIndex = updated.firstIndex(of: item), existingIndex != index {
            updated[existingIndex] = updated[index]
        }
        updated[index] = item
        // B13: the tiles changed (one replaced, or two swapped) — `moved`, with the row's new
        // title and the palette folding away as its twin. Re-picking the current chip says nothing.
        if updated != items { FernletFeedback.system.play(.moved) }
        store.setQuickLogItems(updated)
        editingSlot = nil
    }

    /// One tile one place up or down (the row's "Move up" / "Move down"), with the layout cue the
    /// palette's swap plays (report B13). Nothing at either end.
    private func step(_ index: Int, by offset: Int) {
        let updated = QuickLogOrder.stepping(items, at: index, by: offset)
        guard updated != items else { return }
        FernletFeedback.system.play(.moved)
        store.setQuickLogItems(updated)
        editingSlot = nil
    }

    /// Applies a drag reorder to the STORED array.
    ///
    /// No Fernlet cue here (report B13, "check the system's `.onMove` feel first"): the drag is the
    /// system list's own reorder, and a system control gets nothing extra (§3.8). Whether that
    /// reorder carries a feel of its own on iOS 26 is a device check; if it is silent, `moved` here
    /// is the one-line answer.
    private func moveItems(from source: IndexSet, to destination: Int) {
        var updated = items
        updated.move(fromOffsets: source, toOffset: destination)
        store.setQuickLogItems(updated)
        editingSlot = nil
    }
}

/// The quick-log list's style: plain under the framed look (its rows draw the framed card through
/// `fernletFramedListRow`), today's inset grouped list without it.
private struct QuickLogListStyle: ViewModifier {
    let framed: Bool

    func body(content: Content) -> some View {
        if framed {
            content.listStyle(.plain)
        } else {
            content.listStyle(.insetGrouped)
        }
    }
}
