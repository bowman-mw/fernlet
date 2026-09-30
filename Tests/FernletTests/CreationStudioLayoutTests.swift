import CoreGraphics
import Testing
@testable import Fernlet

/// Pins ``CreationStudioLayout``, the rule that keeps the item designer from scrolling.
///
/// Owner decision 2026-09-29: the drawing screen does not scroll. The layout gives the canvas what
/// the header and tool row leave of the visible page, and scrolling is switched off whenever that
/// is at least the minimum canvas; only where the controls genuinely cannot fit (the largest
/// accessibility sizes on the smallest iPhones) does it fall back to a scrolling page. The first
/// two cases use heights measured on the simulator, so a change to the threshold that would turn
/// scrolling back on for an iPhone SE at the default text size fails here.
struct CreationStudioLayoutTests {

    private let spacing: CGFloat = 12
    private let padding: CGFloat = 12

    private func layout(viewport: CGFloat, header: CGFloat, tools: CGFloat) -> CreationStudioLayout {
        CreationStudioLayout(viewportHeight: viewport, headerHeight: header, toolsHeight: tools,
                             spacing: spacing, padding: padding)
    }

    /// iPhone SE (3rd generation), text size `large`, measured 2026-09-29: 415pt between the
    /// navigation bar and the pinned palette, a 96pt header (the chips' two rows beside the 88pt
    /// preview) and a 44pt tool row leave a 227pt canvas slot — it fits, so the page does not scroll.
    @Test func iPhoneSEAtTheDefaultTextSizeFitsWithoutScrolling() {
        let result = layout(viewport: 415, header: 96, tools: 44)
        #expect(result.fits)
        #expect(result.canvasHeight == 227)
    }

    /// iPhone SE at `accessibility-extra-extra-extra-large`: the chips wrap into three tall rows,
    /// so no canvas of the minimum height fits. The page scrolls (from the chips and margins only),
    /// and the canvas is sized so the tool row and canvas fill one screen at the bottom.
    @Test func iPhoneSEAtTheLargestAccessibilitySizeScrollsWithAScreenfulCanvas() {
        let result = layout(viewport: 400, header: 226, tools: 44)
        let screenfulBelowTheHeader: CGFloat = 400 - 44 - spacing - 2 * padding
        #expect(!result.fits)
        #expect(result.canvasHeight == screenfulBelowTheHeader)
    }

    /// The threshold is inclusive, and a fraction of a point short of it scrolls.
    @Test func theMinimumCanvasHeightIsTheInclusiveThreshold() {
        let minimum = CreationStudioLayout.minimumCanvasHeight
        let chrome: CGFloat = 96 + 44 + 2 * spacing + 2 * padding
        let exact = layout(viewport: minimum + chrome, header: 96, tools: 44)
        #expect(exact.fits)
        #expect(exact.canvasHeight == minimum)

        let short = layout(viewport: minimum + chrome - 0.5, header: 96, tools: 44)
        #expect(!short.fits)
        #expect(short.canvasHeight >= minimum)
    }

    /// Fitted content never exceeds the viewport, even from fractional measurements: the canvas
    /// slot is rounded DOWN to whole points, so scrolling-off can never clip the canvas's last row.
    @Test func fittedContentNeverExceedsTheViewport() {
        let viewport: CGFloat = 423.5
        let header: CGFloat = 96.33
        let tools: CGFloat = 44.25
        let result = layout(viewport: viewport, header: header, tools: tools)
        #expect(result.fits)
        let content = 2 * padding + header + spacing + tools + spacing + result.canvasHeight
        #expect(content <= viewport)
        #expect(viewport - content < 1)
    }

    /// A tool row taller than the whole page still leaves the canvas its minimum.
    @Test func theScrollingCanvasNeverShrinksBelowTheMinimum() {
        let result = layout(viewport: 300, header: 400, tools: 400)
        #expect(!result.fits)
        #expect(result.canvasHeight == CreationStudioLayout.minimumCanvasHeight)
    }

    /// Before the first measurement (zero) or on a nonsense one, the layout fails safe to the
    /// scrolling page with a minimum canvas — never to a scroll-disabled page that clips controls.
    @Test func unmeasuredOrInvalidInputsFailSafeToTheScrollingLayout() {
        let cases: [(CGFloat, CGFloat, CGFloat)] = [
            (0, 0, 0), (-10, 96, 44), (.nan, 96, 44), (.infinity, 96, 44),
            (423, -1, 44), (423, 96, .nan),
        ]
        for (viewport, header, tools) in cases {
            let result = layout(viewport: viewport, header: header, tools: tools)
            #expect(!result.fits, "viewport \(viewport), header \(header), tools \(tools)")
            #expect(result.canvasHeight == CreationStudioLayout.minimumCanvasHeight)
        }
    }
}
