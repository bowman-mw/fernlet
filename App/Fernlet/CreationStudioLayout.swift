import CoreGraphics

/// How the Creation Studio's drawing screen splits its height between the controls and the canvas.
///
/// **Owner decision 2026-09-29: the item designer does not scroll.** Drawing on a page that moves
/// under the finger was the report ("it still scrolls when you're drawing"), so the editor is laid
/// out to fit its visible page: the header (live preview beside the slot chips) and the tool row
/// take what they measure, and the canvas card is given exactly what is left. When that leftover
/// is at least ``minimumCanvasHeight`` the layout ``fits`` and the page's scrolling is switched off.
///
/// When it is not — the largest accessibility text sizes on an iPhone SE, where the four slot
/// chips alone wrap into three or four rows, or a Display Zoom SE — there is no layout that keeps
/// every control on one screen, so the page scrolls, and the canvas is sized so that the tool row
/// and the canvas fill one screen when scrolled to the bottom. That scroll is started only from
/// the chips, buttons and margins: ``ZoomablePixelCanvas`` owns every touch that begins on it, so
/// a stroke never moves the page in either mode.
///
/// A pure value so the threshold is testable without a view; ``CreationStudioView`` feeds it the
/// measured viewport and the measured header and tool-row heights. Those two blocks never depend
/// on the canvas height, so the choice it makes cannot feed back into its own inputs and flip.
nonisolated struct CreationStudioLayout: Equatable {
    /// The smallest canvas card the fitted layout accepts, in points. At 200 an Outfit canvas
    /// (48×40 cells) is still ~4.6pt a cell before pinch-zoom; below it the page scrolls instead.
    static let minimumCanvasHeight: CGFloat = 200

    /// True when the header, the tools and a canvas of at least ``minimumCanvasHeight`` all fit in
    /// the visible page: scrolling is off.
    let fits: Bool
    /// The height of the slot the canvas card is fitted into (the card keeps its slot's aspect
    /// ratio inside it). Whole points, so the fitted content never exceeds the viewport.
    let canvasHeight: CGFloat

    /// - Parameters:
    ///   - viewportHeight: The page's visible height, between the navigation bar and the pinned
    ///     palette. Zero before the first measurement, which reads as "does not fit".
    ///   - headerHeight: The measured preview-and-chips row.
    ///   - toolsHeight: The measured Undo · Clear · Mirror row.
    ///   - spacing: The gap between the header, the tools and the canvas (two gaps).
    ///   - padding: The page's padding on each vertical edge.
    init(viewportHeight: CGFloat, headerHeight: CGFloat, toolsHeight: CGFloat,
         spacing: CGFloat, padding: CGFloat) {
        let minimum = Self.minimumCanvasHeight
        let inputs = [viewportHeight, headerHeight, toolsHeight, spacing, padding]
        guard viewportHeight > 0, inputs.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            fits = false
            canvasHeight = minimum
            return
        }
        let fitted = (viewportHeight - headerHeight - toolsHeight - 2 * spacing - 2 * padding)
            .rounded(.down)
        if fitted >= minimum {
            fits = true
            canvasHeight = fitted
        } else {
            // Scrolled to the bottom, the tool row and the canvas fill one screen: the header is
            // the only thing that scrolls away.
            fits = false
            canvasHeight = max(minimum, (viewportHeight - toolsHeight - spacing - 2 * padding).rounded(.down))
        }
    }
}
