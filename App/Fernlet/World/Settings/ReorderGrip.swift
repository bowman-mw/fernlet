import FernletDomainModel
import FernletUI
import SwiftUI

/// The ink drag handle at the end of a reorderable framed row (`b2-settings-quicklog`): three bold
/// square-ended bars, drawn inside the card's frame where the system's pale grip used to overlap it.
/// Decorative: the row is what a person presses and drags, and VoiceOver and Voice Control move it
/// with the row's "Move up" and "Move down" actions.
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
