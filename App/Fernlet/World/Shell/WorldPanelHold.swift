import FernletUI
import SwiftUI

extension View {
    /// Holds the World panel this page sits in while `isHeld`: the plate's Back and the panel's ✕ are
    /// off and the edge swipe does not go back (``FernletPlateNavigation/isHeld``). For a page running
    /// something the person must not walk away from halfway: Delete everything's wipe on Settings and
    /// Privacy & Data, which hid their own Back and blocked the sheet's swipe before the plate took
    /// those over. Outside a panel (the Settings sheet) it only gates the edge swipe.
    func worldPanelHeld(_ isHeld: Bool) -> some View {
        modifier(WorldPanelHoldModifier(isHeld: isHeld))
    }
}

/// Implements ``SwiftUI/View/worldPanelHeld(_:)``: mirrors the flag into the plate's model and gates
/// the swipe; the hold goes with the page.
private struct WorldPanelHoldModifier: ViewModifier {
    let isHeld: Bool
    @Environment(\.fernletPlateNavigation) private var plate

    func body(content: Content) -> some View {
        content
            .background {
                EdgeSwipeGate(isEnabled: !isHeld).frame(width: 0, height: 0).accessibilityHidden(true)
            }
            .onChange(of: isHeld, initial: true) { _, held in plate?.isHeld = held }
            .onDisappear { if isHeld { plate?.isHeld = false } }
    }
}
