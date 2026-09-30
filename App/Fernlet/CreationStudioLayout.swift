import CoreGraphics

/// How the Creation Studio's drawing screen splits its height between the controls and the canvas.
///
/// **Owner decision 2026-09-29: the item designer does not scroll.** Drawing on a page that moves
/// under the finger was the report ("it still scrolls when you're drawing"), so the editor is laid
/// out to fit its visible page: the header (live preview beside the slot chips) and the tool row
/// take what they measure, and the canvas card is given exactly what is left. When that leftover
/// is at least ``minimumCanvasHeight`` the layout ``fits`` and the page's scrolling is switched off.
///
/// It fits on every iPhone in portrait at the default text size and standard Display Zoom
/// (measured down to an iPhone SE: a 227pt canvas slot). It does not fit — and the page scrolls —
/// in three places, even though no control is then out of reach:
///
/// - **Accessibility text sizes on small iPhones**, where the slot chips wrap into three rows and
///   the tool row becomes a column (an SE from accessibility-medium up; an iPhone 17 at AX5).
/// - **Display Zoom on an SE-class phone** (320×568pt): the header and tools leave roughly 90pt.
///   Estimated from the standard-zoom SE measurements (2026-09-30), not measured.
/// - **Landscape**, which the app allows on iPhone: the pinned palette and Next bar leave the page
///   about 160pt (measured on an iPhone 17), less than the minimum canvas alone.
///
/// There the canvas is sized so that the tool row and the canvas fill one screen when scrolled to
/// the bottom — or, where even that is under ``minimumCanvasHeight``, the canvas is capped at what
/// the page can show in one piece, so the whole drawing is always on screen at once. That scroll
/// is started only from the chips, buttons and margins: ``ZoomablePixelCanvas`` owns every touch
/// that begins on it, so a stroke never moves the page in either mode.
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
    /// ratio inside it). Whole points, so the fitted content never exceeds the viewport; and once
    /// the viewport is measured, never taller than it is inside its padding, so the whole canvas
    /// can be on screen at once.
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
            // the only thing that scrolls away. Where that screenful is under the minimum (a
            // short landscape page), the canvas gets the minimum — but never more than the page
            // shows in one piece, since a canvas cannot be scrolled from the canvas itself.
            fits = false
            let screenful = (viewportHeight - toolsHeight - spacing - 2 * padding).rounded(.down)
            let wholeOnScreen = max(0, (viewportHeight - 2 * padding).rounded(.down))
            canvasHeight = screenful >= minimum ? screenful : min(minimum, wholeOnScreen)
        }
    }
}
