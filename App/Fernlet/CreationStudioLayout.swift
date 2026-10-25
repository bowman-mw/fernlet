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
    /// The smallest canvas card the fitted layout accepts, in points. Since the canvases went to the
    /// companion's own scale (W-07, 2026-10-25: at most 18 columns and 13 rows), 150 still gives an
    /// Outfit canvas ~11.5pt a cell before pinch-zoom (the old 48×40 grid needed 200 for 4.6pt);
    /// below it the page scrolls instead.
    static let minimumCanvasHeight: CGFloat = 150

    /// True when the header, the tools and a canvas of at least ``minimumCanvasHeight`` all fit in
    /// the visible page: scrolling is off.
    let fits: Bool
    /// The height of the slot the canvas card is fitted into (the card keeps its slot's aspect
    /// ratio inside it). Whole points, so the fitted content never exceeds the viewport; and once
    /// the viewport is measured, never taller than it is inside its padding, so the whole canvas
    /// can be on screen at once.
    let canvasHeight: CGFloat
    /// Whether the up-close and on-the-map previews show under the canvas. They give way (the
    /// preview beside the chips stays) only where they alone would turn scrolling on; where the page
    /// scrolls anyway, they show.
    let showsPreviews: Bool

    /// - Parameters:
    ///   - viewportHeight: The page's visible height, between the navigation bar and the pinned
    ///     palette. Zero before the first measurement, which reads as "does not fit".
    ///   - headerHeight: The measured preview-and-chips row (with the size line under it).
    ///   - toolsHeight: The measured Undo · Clear · Mirror row.
    ///   - footerHeight: The measured note under the canvas (a held item's); zero for none, which
    ///     also drops its gap.
    ///   - previewsHeight: The measured up-close and on-the-map previews (W-07); zero for none.
    ///   - spacing: The gap between the header, the tools, the canvas and what is under it.
    ///   - padding: The page's padding on each vertical edge.
    init(viewportHeight: CGFloat, headerHeight: CGFloat, toolsHeight: CGFloat, footerHeight: CGFloat = 0,
         previewsHeight: CGFloat = 0, spacing: CGFloat, padding: CGFloat) {
        let minimum = Self.minimumCanvasHeight
        let inputs = [viewportHeight, headerHeight, toolsHeight, footerHeight, previewsHeight, spacing, padding]
        guard viewportHeight > 0, inputs.allSatisfy({ $0.isFinite && $0 >= 0 }) else {
            fits = false
            canvasHeight = minimum
            showsPreviews = true
            return
        }
        let note = footerHeight > 0 ? footerHeight + spacing : 0
        let previews = previewsHeight > 0 ? previewsHeight + spacing : 0
        let page = viewportHeight - headerHeight - toolsHeight - note - 2 * spacing - 2 * padding
        if (page - previews).rounded(.down) >= minimum {
            (fits, canvasHeight, showsPreviews) = (true, (page - previews).rounded(.down), true)
        } else if page.rounded(.down) >= minimum {
            (fits, canvasHeight, showsPreviews) = (true, page.rounded(.down), false)
        } else {
            // Scrolled to the bottom, the tool row, the canvas and what is under it fill one screen:
            // the header is the only thing that scrolls away. Where that screenful is under the
            // minimum (a short landscape page), the canvas gets the minimum — but never more than the
            // page shows in one piece, since a canvas cannot be scrolled from the canvas itself.
            fits = false
            showsPreviews = true
            let screenful = (viewportHeight - toolsHeight - note - previews - spacing - 2 * padding).rounded(.down)
            let wholeOnScreen = max(0, (viewportHeight - 2 * padding).rounded(.down))
            canvasHeight = screenful >= minimum ? screenful : min(minimum, wholeOnScreen)
        }
    }
}
