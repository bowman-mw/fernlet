import FernletDomainModel
import FernletUI
import SwiftUI

/// The ink drag handle at the end of a reorderable framed row (`b2-settings-quicklog`): three bold
/// square-ended bars, drawn inside the card's frame where the system's pale grip used to overlap it.
/// The Quick-log editor makes it a handle grabbed at once (owner, 2026-10-24, question 16:
/// ``QuickLogGripDrag``); hidden from VoiceOver, which moves the row with its "Move up" and "Move
/// down" actions, as Voice Control does.
struct ReorderGrip: View {
    @Environment(\.fernletFramedLook) private var look

    var body: some View {
        VStack(spacing: 3) {
            bar
            bar
            bar
        }
        // Narrow: the bars end where the design's do, 4 pt inside the row's trailing inset.
        .frame(width: 24, height: 44)
        // The whole 24 × 44 is the handle, not only the bars.
        .contentShape(Rectangle())
        .accessibilityHidden(true)
    }

    /// One bar of the handle, in the look's text ink.
    private var bar: some View {
        Rectangle()
            .fill(look?.text ?? Color.bark)
            .frame(width: 16, height: 2.5)
    }
}

/// The quick-log layout's one-step moves (the drag's VoiceOver and Voice Control twin): pure, so the
/// editor and its tests share them.
nonisolated enum QuickLogOrder {
    /// `items` with the tile at `index` swapped one place up (-1) or down (+1); unchanged at either end
    /// or for an index outside the layout.
    static func stepping(_ items: [FernletShortcut], at index: Int, by offset: Int) -> [FernletShortcut] {
        guard items.indices.contains(index), items.indices.contains(index + offset) else { return items }
        var updated = items
        updated.swapAt(index, index + offset)
        return updated
    }
}

/// A Quick-log grip drag in progress (owner, 2026-10-24, question 16: the handle is grabbed at once,
/// no press-and-hold first). The held row moves one place each time the finger passes half a row
/// beyond the row's slot, and follows the finger within it. Pure, so the editor and its tests share it.
nonisolated struct QuickLogGripDrag: Equatable, Sendable {
    /// The held row's place now.
    var index: Int
    /// The finger's travel (points down from where it went down) at the row's last move.
    var anchor: CGFloat = 0

    /// The step the finger's `translation` asks for: +1 (down) or -1 (up) once it is more than half
    /// a row past the row's slot, 0 otherwise or before a row height is known.
    func step(at translation: CGFloat, rowHeight: CGFloat) -> Int {
        guard rowHeight > 0 else { return 0 }
        let travel = translation - anchor
        if travel > rowHeight / 2 { return 1 }
        if travel < -rowHeight / 2 { return -1 }
        return 0
    }

    /// The drag after its row moved `offset` places, the anchor following the row's new slot.
    func moved(by offset: Int, rowHeight: CGFloat) -> QuickLogGripDrag {
        QuickLogGripDrag(index: index + offset, anchor: anchor + CGFloat(offset) * rowHeight)
    }

    /// How far the held row follows the finger inside its slot: half a row at most either way.
    func lift(at translation: CGFloat, rowHeight: CGFloat) -> CGFloat {
        let half = max(rowHeight, 0) / 2
        return min(max(translation - anchor, -half), half)
    }
}
