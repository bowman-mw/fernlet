import CoreGraphics
import Testing
@testable import Fernlet

/// Pins ``CreationStudioLayout``, the rule that keeps the item designer from scrolling.
///
/// Owner decision 2026-09-29: the drawing screen does not scroll. The layout gives the canvas what
/// the header and tool row leave of the visible page, and scrolling is switched off whenever that
/// is at least the minimum canvas; only where the controls genuinely cannot fit (the largest
/// accessibility sizes on small iPhones, and landscape) does it fall back to a scrolling page.
/// Every device case uses the viewport, header and tool-row heights measured on the simulator
/// (settled values, traced from the running studio 2026-09-29/30), so a change to the threshold
/// that would turn scrolling back on for an iPhone SE at the default text size fails here.
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

    /// iPhone SE at `accessibility-extra-extra-extra-large` (AX5), measured 2026-09-30: the chips
    /// wrap into three tall rows (a 224.5pt header) and the tool row is a column (161.8pt), in a
    /// 381.5pt page. Nothing close to a canvas fits beside them, so the page scrolls (from the
    /// controls only). Even the screenful below the header is under the minimum here, so the
    /// canvas gets the minimum — which the page can still show whole.
    @Test func iPhoneSEAtTheLargestAccessibilitySizeScrollsWithAWholeMinimumCanvas() {
        let result = layout(viewport: 381.5, header: 224.5, tools: 161.8)
        #expect(!result.fits)
        #expect(result.canvasHeight == CreationStudioLayout.minimumCanvasHeight)
        #expect(2 * padding + result.canvasHeight <= 381.5)
    }

    /// iPhone 17 at AX5, measured 2026-09-30: a 225pt header and a 161.5pt tool column in a
    /// 522.3pt page. It does not fit, and the canvas is sized so that, scrolled to the bottom, the
    /// tool row and the canvas fill one screen.
    @Test func iPhone17AtTheLargestAccessibilitySizeScrollsWithAScreenfulCanvas() {
        let result = layout(viewport: 522.3, header: 225, tools: 161.5)
        #expect(!result.fits)
        #expect(result.canvasHeight == 324)
        let screenful = 2 * padding + 161.5 + spacing + result.canvasHeight
        #expect(screenful <= 522.3)
        #expect(522.3 - screenful < 1)
    }

    /// Landscape, at the default text size, measured 2026-09-30: the pinned palette and Next bar
    /// leave the page 160pt on an iPhone 17 and 145pt on an iPhone SE — less than the minimum
    /// canvas alone. The page scrolls (from the controls and margins only), and the canvas is
    /// capped at what the page shows in one piece rather than held at a minimum that could never
    /// be on screen whole: a canvas cannot be scrolled from the canvas.
    @Test func landscapeScrollsWithACanvasThePageShowsWhole() {
        for (viewport, expected) in [(CGFloat(160), CGFloat(136)), (145, 121)] {
            let result = layout(viewport: viewport, header: 88, tools: 44)
            #expect(!result.fits, "viewport \(viewport)")
            #expect(result.canvasHeight == expected, "viewport \(viewport)")
            #expect(2 * padding + result.canvasHeight <= viewport, "viewport \(viewport)")
        }
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

    /// A tool row taller than the whole page still leaves the canvas its minimum, when the page is
    /// tall enough to show a minimum canvas whole.
    @Test func theScrollingCanvasKeepsTheMinimumWhereThePageCanShowIt() {
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
