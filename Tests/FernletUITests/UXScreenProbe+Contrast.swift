import UIKit
import XCTest

// MARK: - Contrast triage: the measured second opinion behind `.contrast`
//
// XCUITest's contrast auditor nominates elements; it does not say why, and on this palette its
// verdicts do not follow the WCAG ratio. Measured 2026-10-17 on the `ScreenAppearanceUITests`
// gallery (iPhone 17, light, demo seed): 134 raw contrast issues, of which full-strength `bark`
// headings rendered at 19.4:1 and full-strength `slate` copy at 4.7–5.2:1 were reported
// "Contrast failed", while `moss` text at 3.73:1 was reported only "Contrast nearly passed". A wall
// built on those verdicts would fail on the app's most legible text and pass its least legible.
//
// So the auditor stays the NOMINATOR and this file is the judge. Every contrast issue is decided by
// measuring the element itself, in the screenshot taken for that screen, against the floors Apple's
// Sufficient Contrast criterion cites (4.5:1 for text, 3:1 for non-text). Three outcomes excuse an
// issue, each named in the run's attachment with its number, so nothing is excused silently:
//   * `disabled`  — the element reports `isEnabled == false`. WCAG 1.4.3 and 1.4.11 both exempt an
//                   inactive control, and the house Save pill dims exactly that way.
//   * `occluded`  — the element is not wholly on the visible canvas: it runs under the floating tab
//                   bar, under a bar pinned over a screen's scrolling content (`SheetSaveBar` or a
//                   bar like it at the bottom, a sheet's header at the top) and the scroll-edge fade
//                   beside it, or past the window's edge, so the auditor sampled the glass, the bar
//                   or nothing. The same element is measured wherever it is
//                   NOT covered.
//   * `inkClears` — the element's rendered ink measures at or above its floor. The measurement is the
//                   90th percentile of the inked pixels against the crop's dominant colour: ink at
//                   full strength, not the anti-aliased fringe of a thin serif stroke.
// Anything else is a real finding: it is reported like every other audit issue and fails the
// screen unless it is in `auditBaselines` or `auditExemptions`, which name it and say why.
//
// THE HONEST CEILING. The triage judges only what the auditor nominates; the sweep at the bottom of
// this file is what measures the rest. The dominant-colour background is wrong for text on a gradient or a photograph
// (none on the gallery). An element-less issue carries no frame and cannot be judged at all, so it
// is reported unexcused. And the measurement is of THIS run's appearance only: the Increase Contrast
// and dark-mode evidence in `Docs/Accessibility-Nutrition-Labels.md` comes from re-running the gallery
// with the simulator set that way, which no test can do for itself.

/// Why one contrast issue is not a defect — the three outcomes ``UXScreenProbe/contrastVerdict(_:in:)``
/// can excuse.
enum ContrastExcuse: String, Sendable {
    /// An inactive control; WCAG 1.4.3 / 1.4.11 exempt it.
    case disabled
    /// Not wholly on the visible canvas — under the tab bar, under a pinned header or footer, or
    /// past the window's edge.
    case occluded
    /// Its rendered ink measures at or above its floor.
    case inkClears
}

/// The measured decision about one contrast issue.
struct ContrastVerdict: Sendable {
    /// Why it is excused, or `nil` for a real finding.
    let excuse: ContrastExcuse?
    /// The rendered ratio, when the element could be measured.
    let ratio: Double?
    /// The floor it was held to.
    let floor: Double

    /// `inkClears 5.09:1 ≥ 4.5` — the line the attachment prints beside the issue.
    var summary: String {
        let measured = ratio.map { String(format: "%.2f:1", $0) } ?? "unmeasured"
        return "\(excuse?.rawValue ?? "REAL") \(measured) vs \(String(format: "%.1f", floor))"
    }
}

/// A bar pinned over a screen's scrolling content, and the elements drawn on it: a footer
/// (`SheetSaveBar`, or a bar built like it) found by ``UXScreenProbe/pinnedFooter(in:tabBar:)``, a
/// sheet's header found by ``UXScreenProbe/pinnedHeader(in:)``, or the system keyboard found by
/// ``UXScreenProbe/keyboardBar(in:)``.
///
/// Content scrolled under the bar is hidden by it, and the system's scroll-edge fade beside the bar
/// washes out whatever sits next to it. Measured 2026-10-18, that is where four of the sweep's
/// non-ink readings came from: the Workout sheet's search field (2.14:1) under `SheetSaveBar` and
/// "ANYTHING ELSE?" (1.80:1) under the suggest bar, on the gallery; "Calories" (2.27:1) and "cal"
/// (1.64:1) under Nutrition targets' header, and that card's footnote (1.43:1) and "HYDRATION"
/// (1.35:1) under the keyboard its UI test leaves up. None is text a reader is shown; each is measured
/// once it is scrolled into view.
struct PinnedBar: Sendable {
    /// The bar and its fade, from the window's edge, in points.
    let band: CGRect
    /// The frames of the bar's own elements. Their ink is measured like any other element's.
    let controls: [CGRect]

    /// Whether `frame` is content running under the bar, rather than one of its own elements.
    func covers(_ frame: CGRect) -> Bool {
        frame.intersects(band) && !controls.contains { $0.contains(frame) }
    }

    /// `y 724–874 under 1 element(s) …` — the line the attachment prints.
    var summary: String {
        "y \(Int(band.minY.rounded()))–\(Int(band.maxY.rounded())) under \(controls.count) element(s) "
            + "\(controls.map(\.debugDescription))"
    }
}

/// A screenshot unpacked once into RGBA bytes, so every issue on the screen is measured against the
/// same pixels the gallery attached.
struct ContrastCanvas {
    /// Pixel width.
    let width: Int
    /// Pixel height.
    let height: Int
    /// Pixels per point.
    let scale: CGFloat
    /// RGBA8, row-major.
    let bytes: [UInt8]
    /// The band the floating tab bar covers, in points, or `nil` when no tab bar is showing (a sheet
    /// covers it). See ``UXScreenProbe/floatingTabBarBand()``.
    let tabBar: CGRect?
    /// The header, footer and keyboard pinned over the scrolling content: whichever the screen has.
    let bars: [PinnedBar]

    /// Unpacks `screenshot` of a window `pointWidth` points wide, or `nil` when it has no bitmap.
    init?(_ screenshot: XCUIScreenshot, pointWidth: CGFloat, tabBar: CGRect?, bars: [PinnedBar]) {
        guard let image = screenshot.image.cgImage, pointWidth > 0 else { return nil }
        let scale = CGFloat(image.width) / pointWidth
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return nil }
        self.width = width
        self.height = height
        self.scale = scale
        self.bytes = bytes
        self.tabBar = tabBar
        self.bars = bars
    }

    /// Whether a pinned header, footer or keyboard covers `frame`.
    func barsCover(_ frame: CGRect) -> Bool {
        bars.contains { $0.covers(frame) }
    }
}

extension UXScreenProbe {

    /// WCAG 1.4.3's floor for text — the number Apple's criterion cites ("usually 4.5 to 1").
    static let textContrastFloor = 4.5
    /// WCAG 1.4.11's floor for a glyph or a control boundary.
    static let nonTextContrastFloor = 3.0
    /// Pixels examined per element; a larger crop is sampled on a stride. Bounds the cost of a
    /// full-width card to the cost of a caption.
    static let maximumSampledPixels = 160_000
    /// The inked-pixel percentile taken as the element's ink (see the file header).
    static let inkPercentile = 0.90
    /// A pixel this far from the background, in contrast, counts as ink rather than background noise.
    static let inkThreshold = 1.25

    /// Decides one contrast issue by measuring it. See the file header for the three excuses.
    func contrastVerdict(_ issue: XCUIAccessibilityAuditIssue, in canvas: ContrastCanvas?) -> ContrastVerdict {
        guard let element = issue.element else {
            return ContrastVerdict(excuse: nil, ratio: nil, floor: Self.textContrastFloor)
        }
        let floor = element.elementType == .image ? Self.nonTextContrastFloor : Self.textContrastFloor
        if !element.isEnabled {
            return ContrastVerdict(excuse: .disabled, ratio: nil, floor: floor)
        }
        let frame = element.frame
        if isOccluded(frame, isTabItem: element.elementType == .button && Self.tabTitles.contains(element.label),
                      in: canvas) {
            return ContrastVerdict(excuse: .occluded, ratio: nil, floor: floor)
        }
        let ratio = canvas.flatMap { Self.renderedContrast(of: frame, in: $0) }
        let clears = ratio.map { $0 >= floor } ?? false
        return ContrastVerdict(excuse: clears ? .inkClears : nil, ratio: ratio, floor: floor)
    }

    /// Whether `frame` is not wholly on the visible canvas: past the window's edge, under a pinned
    /// header or footer without being one of its own elements, or under the floating tab bar without
    /// being one of its own five items.
    ///
    /// A tab item is a BUTTON carrying a tab title. The title alone is not enough: Home's quick-log
    /// grid has a "Move" tile whose static text runs under the bar on the first viewport, and on
    /// 2026-10-17 it was measured as if it were the Move tab.
    private func isOccluded(_ frame: CGRect, isTabItem: Bool, in canvas: ContrastCanvas?) -> Bool {
        guard window.frame.contains(frame) else { return true }
        if canvas?.barsCover(frame) == true { return true }
        guard let band = canvas?.tabBar, frame.intersects(band) else { return false }
        return !(band.contains(frame) && isTabItem)
    }

    /// The five tab titles, as `FernletTab` labels its buttons.
    static let tabTitles = ["Home", "Food", "Move", "Album", "Private"]

    /// Points the floating bar's glass extends above its buttons: the bar's 6pt vertical padding
    /// plus its 1pt stroke and a point of shadow.
    static let tabBarOutset: CGFloat = 8

    /// The height of a non-compact tab button — icon, label and padding — as `ContentView`'s
    /// tab-bar comment measures it ("the non-compact button already measures ~58pt tall").
    static let tabButtonHeight: CGFloat = 58

    /// The band the floating tab bar covers, from just above its buttons to the window's bottom
    /// edge, or `nil` when it is not showing.
    ///
    /// The bar is a custom SwiftUI container carrying `.isTabBar`, which XCUITest does NOT expose as
    /// a `.tabBar` element — `app.tabBars` finds nothing (measured 2026-10-17: content under the bar
    /// was measured through the glass). So the band is read off the Home tab's button, as
    /// `assertAboveTabBar` already does: the five buttons share one row, and "Home" is the one title
    /// no other control on a tab carries (Home's own quick-log grid has a "Move" tile). The button
    /// can report only its label's 16pt row, so the band rises a full ``tabButtonHeight`` above the
    /// row's bottom. It errs wide by a few points, which only ever moves an element from "measured"
    /// to "occluded", and every occluded element is named in the attachment. A sheet leaves the
    /// button in the tree but not hittable, and then there is no bar to account for.
    func floatingTabBarBand() -> CGRect? {
        let home = app.buttons["Home"].firstMatch
        guard home.exists, home.isHittable else { return nil }
        let top = home.frame.maxY - max(home.frame.height, Self.tabButtonHeight) - Self.tabBarOutset
        return CGRect(x: window.frame.minX, y: top, width: window.frame.width, height: window.frame.maxY - top)
    }

    /// How far above the window's bottom edge a footer's control may sit: a sheet's pill (bottom
    /// safe area, the strip's padding, the pill) or a pushed editor's, which rides above the tab bar.
    static let footerReach: CGFloat = 170
    /// `SheetSaveBar`'s pill: at least 52pt tall, its label padded 16pt top and bottom.
    static let footerPillHeight: CGFloat = 52
    /// A reported frame at least this tall is the whole pill rather than its label. Lower than
    /// ``footerPillHeight`` because a sheet presented below its full height is drawn scaled: the
    /// Meal sheet's 52pt Save pill reports 49.9pt (2026-10-18).
    static let footerPillMinimumReported: CGFloat = 40
    /// The label's vertical padding inside `SheetSaveBar`'s pill.
    static let footerPillPadding: CGFloat = 16
    /// The strip's padding above the pill, as `SheetSaveBar` and the bars built like it draw it.
    static let footerStripPadding: CGFloat = 20
    /// Points the system's scroll-edge fade reaches above the strip's hairline.
    static let footerFadeOutset: CGFloat = 8
    /// Containers whose content scrolls, and can therefore run under a footer pinned outside them.
    static let scrollContainers: [XCUIElement.ElementType] = [.scrollView, .collectionView, .table]

    /// The footer pinned over this screen's scrolling content, or `nil` when there is none.
    ///
    /// A footer's control is a BUTTON that no scroll container holds (it does not scroll with the
    /// content), sitting within ``footerReach`` of the window's bottom edge. That is what
    /// `.safeAreaInset(edge: .bottom)` makes of `SheetSaveBar` and the eight bars like it. Its frame
    /// is either the whole pill (a bar that pads inside the button's label) or only the label
    /// (`SheetSaveBar`, which pads outside it under `.buttonStyle(.plain)`), so the pill's top is
    /// recovered from the label when the frame is shorter than ``footerPillMinimumReported``. The
    /// band starts ``footerStripPadding`` above the pill and ``footerFadeOutset`` more for the fade.
    ///
    /// The tab bar's row is left out by geometry, not by title: a button inside `tabBar` (from
    /// ``floatingTabBarBand()``) is never a footer's. Measured 2026-10-18 with a title check
    /// instead, four buttons in the tab bar's row still passed it on every tab screen, and the band
    /// they drew sat 20pt above the tab bar's own.
    ///
    /// Like the tab bar's band it errs wide by a few points, which only ever moves an element from
    /// "measured" to "occluded", and the attachment names the band. A screen with a fixed, unscrolled
    /// button near its bottom also yields a band; nothing scrolls under it, so all that costs is the
    /// few points of text just above it.
    func pinnedFooter(in root: XCUIElementSnapshot, tabBar: CGRect?) -> PinnedBar? {
        let reach = window.frame.maxY - Self.footerReach
        var stack: [(node: XCUIElementSnapshot, scrolled: Bool)] = [(root, false)]
        var controls: [CGRect] = []
        for _ in 0..<Self.maximumSweptNodes {
            guard let entry = stack.popLast() else { break }
            let node = entry.node
            if !entry.scrolled, node.elementType == .button, node.frame.maxY >= reach,
               node.frame.maxY <= window.frame.maxY, !(tabBar?.intersects(node.frame) ?? false) {
                controls.append(node.frame)
            }
            let scrolled = entry.scrolled || Self.scrollContainers.contains(node.elementType)
            stack.append(contentsOf: node.children.map { ($0, scrolled) })
        }
        let pillTops = controls.map { frame in
            frame.height >= Self.footerPillMinimumReported
                ? frame.minY
                : min(frame.minY - Self.footerPillPadding, frame.midY - Self.footerPillHeight / 2)
        }
        guard let pillTop = pillTops.min() else { return nil }
        let top = pillTop - Self.footerStripPadding - Self.footerFadeOutset
        let band = CGRect(x: window.frame.minX, y: top, width: window.frame.width, height: window.frame.maxY - top)
        return PinnedBar(band: band, controls: controls)
    }

    /// How far below the window's top edge a header's elements may reach: a sheet's back button and
    /// title row, a pushed page's header, a hub's section picker.
    static let headerReach: CGFloat = 150
    /// Points the system's scroll-edge fade reaches below a header's lowest element.
    static let headerFadeOutset: CGFloat = 12

    /// The header pinned over this screen's scrolling content, or `nil` when there is none.
    ///
    /// A header's elements are the buttons and static texts that no scroll container holds, lying
    /// wholly within ``headerReach`` of the window's top edge: a sheet's Cancel and Done, a pushed
    /// page's back button and title. The band runs from the window's top to the lowest of them, plus
    /// ``headerFadeOutset`` for the fade. Their own text is measured; content scrolled under them is
    /// not. Measured 2026-10-18 on Nutrition targets, whose UI test leaves the card scrolled so
    /// "Calories" sits in the header's fade (2.27:1, ink `#968C7E` where the label is drawn in full
    /// bark). Like the footer's, the band errs wide by a few points and the attachment names it.
    func pinnedHeader(in root: XCUIElementSnapshot) -> PinnedBar? {
        let reach = window.frame.minY + Self.headerReach
        var stack: [(node: XCUIElementSnapshot, scrolled: Bool)] = [(root, false)]
        var elements: [CGRect] = []
        for _ in 0..<Self.maximumSweptNodes {
            guard let entry = stack.popLast() else { break }
            let node = entry.node
            if !entry.scrolled, [.button, .staticText].contains(node.elementType),
               node.frame.minY >= window.frame.minY, node.frame.maxY <= reach, !node.frame.isEmpty {
                elements.append(node.frame)
            }
            let scrolled = entry.scrolled || Self.scrollContainers.contains(node.elementType)
            stack.append(contentsOf: node.children.map { ($0, scrolled) })
        }
        guard let bottom = elements.map(\.maxY).max() else { return nil }
        let band = CGRect(x: window.frame.minX, y: window.frame.minY, width: window.frame.width,
                          height: bottom + Self.headerFadeOutset - window.frame.minY)
        return PinnedBar(band: band, controls: elements)
    }

    /// The system keyboard as a bar over the content, or `nil` when no keyboard is up.
    ///
    /// Its keys are system ink, not the app's, so it has no elements to measure: everything from
    /// ``footerFadeOutset`` above its top edge to the window's bottom is covered. Measured
    /// 2026-10-18, Nutrition targets' UI test captures its pinned-calories state with the number pad
    /// still up, over the card's footnote and the HYDRATION heading.
    func keyboardBar(in root: XCUIElementSnapshot) -> PinnedBar? {
        var stack: [XCUIElementSnapshot] = [root]
        for _ in 0..<Self.maximumSweptNodes {
            guard let node = stack.popLast() else { break }
            if node.elementType == .keyboard, !node.frame.isEmpty {
                let top = node.frame.minY - Self.footerFadeOutset
                return PinnedBar(band: CGRect(x: window.frame.minX, y: top, width: window.frame.width,
                                              height: window.frame.maxY - top), controls: [])
            }
            stack.append(contentsOf: node.children)
        }
        return nil
    }

    /// The rendered WCAG ratio of the ink inside `frame` against the crop's dominant colour, or
    /// `nil` when the crop is empty or holds no ink at all.
    static func renderedContrast(of frame: CGRect, in canvas: ContrastCanvas) -> Double? {
        let x0 = max(0, Int((frame.minX * canvas.scale).rounded()))
        let y0 = max(0, Int((frame.minY * canvas.scale).rounded()))
        let x1 = min(canvas.width, Int((frame.maxX * canvas.scale).rounded()))
        let y1 = min(canvas.height, Int((frame.maxY * canvas.scale).rounded()))
        guard x1 - x0 >= 3, y1 - y0 >= 3 else { return nil }
        let area = (x1 - x0) * (y1 - y0)
        let stride = max(1, Int((Double(area) / Double(maximumSampledPixels)).squareRoot().rounded(.up)))
        var luminances: [Double] = []
        var counts: [Int: Int] = [:]
        var keyLuminance: [Int: Double] = [:]
        for y in Swift.stride(from: y0, to: y1, by: stride) {
            for x in Swift.stride(from: x0, to: x1, by: stride) {
                let offset = (y * canvas.width + x) * 4
                let (r, g, b) = (canvas.bytes[offset], canvas.bytes[offset + 1], canvas.bytes[offset + 2])
                let lum = relativeLuminance(r, g, b)
                luminances.append(lum)
                let key = (Int(r) / 4) << 12 | (Int(g) / 4) << 6 | Int(b) / 4
                counts[key, default: 0] += 1
                keyLuminance[key] = lum
            }
        }
        guard let background = counts.max(by: { $0.value < $1.value }).flatMap({ keyLuminance[$0.key] }) else {
            return nil
        }
        let ink = luminances.map { contrast($0, background) }.filter { $0 > inkThreshold }.sorted()
        guard !ink.isEmpty else { return nil }
        let index = min(ink.count - 1, Int((Double(ink.count - 1) * inkPercentile).rounded()))
        return ink[index]
    }

    /// WCAG relative luminance of one sRGB pixel.
    static func relativeLuminance(_ r: UInt8, _ g: UInt8, _ b: UInt8) -> Double {
        func linear(_ channel: UInt8) -> Double {
            let c = Double(channel) / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
    }

    /// The WCAG contrast ratio between two relative luminances.
    static func contrast(_ a: Double, _ b: Double) -> Double {
        (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

// MARK: - The measured sweep: every text element, not only the nominated ones

/// One screen's sweep: every visible text measured, and what each one under the floor came to.
struct ContrastSweep: Sendable {
    /// Text elements whose ink was measured.
    var measured = 0
    /// Under the floor and excused by nothing: each one fails the screen.
    var failing: [String] = []
    /// Under the floor and covered by an ``UXScreenProbe/auditExemptions`` entry, with its reason.
    var exempted: [String] = []
    /// Skipped because a pinned header, footer or keyboard, or the tab bar, covers them.
    var occluded: [String] = []

    /// The attachment's listing.
    var listing: [String] {
        ["\(measured) text element(s) measured; \(failing.count) under 4.5:1 and unexcused (FAILS)"]
            + failing
            + ["-- under 4.5:1, exempt --"] + (exempted.isEmpty ? ["none"] : exempted)
            + ["-- not measured: under a pinned header, footer or keyboard, or the tab bar --"] + (occluded.isEmpty ? ["none"] : occluded)
    }
}

extension UXScreenProbe.AuditExemption {

    /// Whether this entry covers a swept text: a `.contrast` entry that names that one text, by its
    /// normalised label or its identifier. An entry naming neither covers a category, and the sweep
    /// never excuses a category.
    @MainActor func coversSweptText(label: String, identifier: String) -> Bool {
        guard auditType.contains(.contrast) else { return false }
        if let elementIdentifier, elementIdentifier != identifier { return false }
        if let elementLabel, UXScreenProbe.normalisedLabel(label) != elementLabel { return false }
        return elementLabel != nil || elementIdentifier != nil
    }
}

extension UXScreenProbe {

    /// Accessibility-snapshot nodes the sweep will walk on one screen; far past any gallery screen.
    static let maximumSweptNodes = 4_000

    /// Every static text and every empty field's prompt on the visible canvas, measured against the
    /// 4.5:1 text floor — WALLED since 2026-10-18.
    ///
    /// **Why this exists beside the auditor.** Measured 2026-10-17, the contrast auditor's recall is
    /// as poor as its precision on this palette: on the Move tab it never nominated the week strip's
    /// "Rest" captions, drawn in 45% slate at 1.83:1, the faintest text on the screen, and it never
    /// reports a text field's prompt at all. A wall that only judges what the auditor nominates
    /// cannot see either. This sweep measures every text the snapshot holds, the same way
    /// ``contrastVerdict(_:in:)`` measures a nominated one.
    ///
    /// **What excuses a text under the floor**, each listed in the attachment: an inactive control
    /// around it (WCAG 1.4.3), the tab bar or a pinned header or footer over it (``PinnedBar``), or an
    /// ``auditExemptions`` entry naming that one text, which is how the moss-family labels on the
    /// Increase Contrast route pass in default light. Anything else fails the screen.
    ///
    /// **The honest ceiling.** The background is the crop's dominant colour, which is wrong for text
    /// over a photograph or a gradient (none on the gallery), so a new failure there is a lead to
    /// re-measure by hand, and then a case for an exemption, not for widening the rule.
    func contrastSweep(_ root: XCUIElementSnapshot, in canvas: ContrastCanvas) -> ContrastSweep {
        var sweep = ContrastSweep()
        for text in visibleTexts(in: root) {
            let line = "“\(text.label)” \(text.frame)"
            if canvas.barsCover(text.frame) || canvas.tabBar.map({ text.frame.intersects($0) }) == true {
                sweep.occluded.append(line)
                continue
            }
            guard let ratio = Self.renderedContrast(of: text.frame, in: canvas) else { continue }
            sweep.measured += 1
            guard ratio < Self.textContrastFloor else { continue }
            let measured = String(format: "%.2f:1", ratio) + " — " + line
            let swept = text.label.hasPrefix(Self.placeholderPrefix)
                ? String(text.label.dropFirst(Self.placeholderPrefix.count)) : text.label
            if let exemption = Self.auditExemptions.first(where: {
                $0.coversSweptText(label: swept, identifier: text.identifier)
            }) {
                sweep.exempted.append("\(measured) — exempt: \(exemption.reason.prefix(80))…")
            } else {
                sweep.failing.append(measured)
            }
        }
        sweep.failing.sort()
        sweep.exempted.sort()
        return sweep
    }

    /// What the sweep prints before an empty field's prompt.
    static let placeholderPrefix = "placeholder: "

    /// Every enabled static text and empty field's prompt wholly inside the window, as (label,
    /// identifier, frame). Text inside an inactive control is left out: WCAG 1.4.3 exempts it, the
    /// same excuse ``contrastVerdict(_:in:)`` gives a nominated one.
    private func visibleTexts(in root: XCUIElementSnapshot) -> [(label: String, identifier: String, frame: CGRect)] {
        let visible = window.frame
        var stack: [(node: XCUIElementSnapshot, disabled: Bool)] = [(root, false)]
        var texts: [(label: String, identifier: String, frame: CGRect)] = []
        for _ in 0..<Self.maximumSweptNodes {
            guard let entry = stack.popLast() else { break }
            let disabled = entry.disabled || !entry.node.isEnabled
            let node = entry.node
            if node.elementType == .staticText, !node.label.isEmpty, !disabled, visible.contains(node.frame) {
                texts.append((node.label, node.identifier, node.frame))
            } else if let prompt = Self.shownPlaceholder(of: node), !disabled, visible.contains(node.frame) {
                // An empty field's prompt is text a user has to read too (WCAG 1.4.3 covers it),
                // and it is the one kind the snapshot never reports as a static text.
                texts.append((Self.placeholderPrefix + prompt, node.identifier, node.frame))
            }
            stack.append(contentsOf: node.children.map { ($0, disabled) })
        }
        return texts
    }

    /// The prompt an empty text field is showing, or `nil` when the node is not an empty field.
    static func shownPlaceholder(of node: XCUIElementSnapshot) -> String? {
        let fields: [XCUIElement.ElementType] = [.textField, .secureTextField, .searchField, .textView]
        guard fields.contains(node.elementType),
              let prompt = node.placeholderValue, !prompt.isEmpty else { return nil }
        let typed = node.value as? String ?? ""
        return typed.isEmpty || typed == prompt ? prompt : nil
    }
}
