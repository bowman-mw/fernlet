import FernletUI
import SwiftUI

extension View {
    /// The presentation chrome for a sheet the Food screens present themselves: the UX-test screen
    /// anchor, the World sheet frame (``SwiftUI/View/fernletSheet()``: full height, paper, the wooden
    /// grabber; Batch 3 draws every sheet full height), the moss tint and the keyboard's Done.
    ///
    /// It stands in for the root's `fernletSheetChrome(anchor:detents:)` on the Food screens' own
    /// presenters, without the `.medium` detent and the system grabber that would otherwise win over
    /// the sheet's frame (the presenter's presentation modifiers win over anything inside a sheet).
    func fernletFoodSheet(anchor: String) -> some View {
        uxScreenAnchor(anchor)
            .fernletSheet()
            .tint(Color.moss)
            .keyboardDoneToolbar()
    }

    /// A Food sheet's background: the framed sheet's paper under the World look, today's parchment
    /// without it. Use it in place of `.background(Color.parchment)` on a sheet's content.
    func foodSheetBackground() -> some View {
        modifier(FoodSheetBackground())
    }
}

/// Implements ``SwiftUI/View/foodSheetBackground()``.
private struct FoodSheetBackground: ViewModifier {
    @Environment(\.fernletFramedLook) private var look

    func body(content: Content) -> some View {
        content.background(look?.paper ?? Color.parchment)
    }
}
