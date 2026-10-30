import SwiftUI
import FernletDomainModel
import FernletUI

/// The pixel companion wearing what is being drawn, awake (the Creation Studio's previews, W-06b and
/// W-07, approved 2026-10-25): no vector companion anywhere in the Studio. Decorative.
struct StudioPixelPreview: View {
    var store: FernletStore
    /// Everything it wears: the worn pieces with the drawing in its slot.
    let items: [CustomizationItem]
    /// Points per sprite pixel.
    let scale: CGFloat
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let now = WorldCompanionLook.current(store: store, at: Date(), night: .awake, items: items)
        WorldCompanionCanvas(grid: WorldCompanionPainter.paint(state: now.state, look: now.look, pose: now.pose,
                                                               increasedContrast: contrast == .increased),
                             scale: scale, footprint: .frame)
            .accessibilityHidden(true)
    }
}

/// Under the Studio's slot chips: the kind and its size in squares ("Hat · 18 × 11"), and what a square
/// is (`comp-studio-hat`).
struct StudioSizeLine: View {
    let slot: ItemSlot
    let name: String
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let size = CreationStudioView.canvasSize(for: slot)
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: StudioCopy.size(slot: slot, cols: size.cols, rows: size.rows))
                .font(FernletFramedFont.rowTitleBold)
                .foregroundStyle(look?.text ?? Color.bark)
            Text(verbatim: StudioCopy.squares(name: name))
                .font(FernletFramedFont.rowDetail)
                .foregroundStyle(WorldPalette.dim)
        }
        .fernletWrappingText()
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("studio.size")
    }
}

/// Under a held item's canvas (`comp-studio-held`): where held items sit.
struct StudioHeldNote: View {
    let name: String

    var body: some View {
        Text(verbatim: StudioCopy.heldNote(name: name))
            .font(FernletFramedFont.rowDetail)
            .foregroundStyle(WorldPalette.dim)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("studio.heldNote")
    }
}

/// Under the Studio's canvas (`comp-studio-hat`): the companion wearing the drawing up close and on
/// the map, live. The pictures are decoration (the preview beside the chips and the canvas say the same), but
/// their captions are words on screen, so VoiceOver reads them as plain text (hiding them was the editor's
/// "Potentially inaccessible text" audit finding once the passport's taller page let the previews show).
struct StudioPreviewsRow: View {
    var store: FernletStore
    /// Everything the previews wear.
    let items: [CustomizationItem]
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        HStack(alignment: .bottom, spacing: 18) {
            VStack(spacing: 4) {
                StudioPixelPreview(store: store, items: items, scale: 5)
                caption(StudioCopy.upClose)
            }
            VStack(spacing: 4) {
                StudioPixelPreview(store: store, items: items, scale: 2)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 14)
                    // The map's grey box, as Customize's "On the map" draws it.
                    .background(WorldPalette.adaptive(light: 0xE7E2D4, dark: 0x2A2017), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(WorldPalette.ink, lineWidth: 2))
                caption(StudioCopy.onTheMap)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func caption(_ words: String) -> some View {
        Text(verbatim: words)
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.dim)
    }
}

/// Save item's note (`comp-studio-save`, approved 2026-10-25): the drawing is already its size on the
/// companion. A sage card in the frame rule.
struct StudioSaveNote: View {
    let name: String
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12)
        Text(verbatim: StudioCopy.saveNote(name: name))
            .font(FernletFramedFont.note)
            .foregroundStyle(look?.text ?? Color.bark)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(look?.sage ?? WorldPalette.sage, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 2))
            .background { shape.fill(WorldPalette.ink.opacity(0.22)).offset(y: 3) }
            .accessibilityIdentifier("studio.confirm.note")
    }
}

/// The faint companion under the Studio's canvas (`comp-studio-hat`): the person's own body shape in
/// its live colour, bare (no topper, clothing, side item or piece), cut to the slot's box, so they draw
/// in place.
enum StudioGhost {
    /// The box's cells, row by row: the body's colour where it lies under the box, else clear.
    @MainActor
    static func cells(store: FernletStore, slot: ItemSlot) -> [UInt32?] {
        var look = WorldCompanionLook.current(store: store, at: Date(), night: .awake, items: []).look
        look.topper = .none
        look.scarf = nil
        look.cap = nil
        look.side = .none
        let grid = WorldCompanionPainter.paint(state: store.liveCompanionState, look: look, pose: WorldCompanionPose())
        return cells(of: grid, in: WorldItemBox.box(for: slot))
    }

    /// `grid`'s cells under `box`, row by row.
    nonisolated static func cells(of grid: WorldCompanionGrid, in box: WorldItemBox.Box) -> [UInt32?] {
        var result: [UInt32?] = []
        result.reserveCapacity(box.width * box.height)
        for y in 0..<box.height {
            for x in 0..<box.width { result.append(grid.color(x: box.x + x, y: box.y + y)) }
        }
        return result
    }
}

/// The Creation Studio's words for the companion's own scale (W-07), resolved here so the views and the
/// tests read one copy.
enum StudioCopy {
    /// "Hat · 18 × 11": the kind and its canvas in squares.
    static func size(slot: ItemSlot, cols: Int, rows: Int) -> String {
        String(localized: "worldStudio.size", defaultValue: "\(slot.label) · \(cols) × \(rows)",
               comment: "Creation Studio, under the kind chips: the kind of item, then its canvas in squares, columns × rows. Example: 'Hat · 18 × 11'")
    }

    /// What a square is.
    static func squares(name: String) -> String {
        String(localized: "worldStudio.squares",
               defaultValue: "One square is one pixel on \(name). The faint shape is \(name), so you draw in place.",
               comment: "Creation Studio, under the size: one square of the canvas is one pixel of the companion; the faint shape behind is the companion. Both placeholders are the companion's name")
    }

    /// The held item's note, under the canvas.
    static func heldNote(name: String) -> String {
        String(localized: "worldStudio.heldNote",
               defaultValue: "Held items sit against \(name)'s side: the box overlaps the body by 5 squares and reaches 2 past the old edge, so \(name) can hold something big.",
               comment: "Creation Studio, Held item, under the canvas: where held items sit. Both placeholders are the companion's name")
    }

    /// The previews' captions.
    static var upClose: String {
        String(localized: "worldStudio.upClose", defaultValue: "Up close",
               comment: "Creation Studio, under the canvas: the companion wearing the drawing, large")
    }

    static var onTheMap: String {
        String(localized: "worldStudio.onTheMap", defaultValue: "On the map",
               comment: "Creation Studio, under the canvas: the companion wearing the drawing at the map's size")
    }

    /// Save item's note.
    static func saveNote(name: String) -> String {
        String(localized: "worldStudio.saveNote",
               defaultValue: "Your drawing is the size it shows on \(name): one square, one pixel, on the map and up close. Items made before, or bought from friends on the old Fernlet, are shrunk to fit automatically.",
               comment: "Creation Studio, Save item: the drawing is already its size on the companion; older pieces shrink to fit. The placeholder is the companion's name")
    }
}
