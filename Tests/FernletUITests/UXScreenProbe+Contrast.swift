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
//                   bar or past the window's edge, so the auditor sampled the glass or nothing. The
//                   same element is measured wherever it is NOT covered.
//   * `inkClears` — the element's rendered ink measures at or above its floor. The measurement is the
//                   90th percentile of the inked pixels against the crop's dominant colour: ink at
//                   full strength, not the anti-aliased fringe of a thin serif stroke.
// Anything else is a real finding: it is reported like every other audit issue and fails the
// screen unless it is in `auditBaselines` or `auditExemptions`, which name it and say why.
//
// THE HONEST CEILING. This judges only what the auditor nominates; an element it never reports is
// never measured. The dominant-colour background is wrong for text on a gradient or a photograph
// (none on the gallery). An element-less issue carries no frame and cannot be judged at all, so it
// is reported unexcused. And the measurement is of THIS run's appearance only: the Increase Contrast
// and dark-mode evidence in `Docs/Accessibility-Nutrition-Labels.md` comes from re-running the gallery
// with the simulator set that way, which no test can do for itself.

/// Why one contrast issue is not a defect — the three outcomes ``UXScreenProbe/contrastVerdict(_:in:)``
/// can excuse.
enum ContrastExcuse: String, Sendable {
    /// An inactive control; WCAG 1.4.3 / 1.4.11 exempt it.
    case disabled
    /// Not wholly on the visible canvas — under the tab bar or past the window's edge.
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

    /// Unpacks `screenshot` of a window `pointWidth` points wide, or `nil` when it has no bitmap.
    init?(_ screenshot: XCUIScreenshot, pointWidth: CGFloat, tabBar: CGRect?) {
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

    /// Whether `frame` is not wholly on the visible canvas: past the window's edge, or under the
    /// floating tab bar without being one of its own five items.
    ///
    /// A tab item is a BUTTON carrying a tab title. The title alone is not enough: Home's quick-log
    /// grid has a "Move" tile whose static text runs under the bar on the first viewport, and on
    /// 2026-10-17 it was measured as if it were the Move tab.
    private func isOccluded(_ frame: CGRect, isTabItem: Bool, in canvas: ContrastCanvas?) -> Bool {
        guard window.frame.contains(frame) else { return true }
        guard let band = canvas?.tabBar, frame.intersects(band) else { return false }
        return !(band.contains(frame) && isTabItem)
    }

    /// The five tab titles, as `FernletTab` labels its buttons.
    static let tabTitles = ["Home", "Food", "Move", "Friends", "Private"]

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

extension UXScreenProbe {

    /// Accessibility-snapshot nodes the sweep will walk on one screen; far past any gallery screen.
    static let maximumSweptNodes = 4_000

    /// Every static text on the visible canvas, measured against the 4.5:1 text floor — REPORT-ONLY.
    ///
    /// **Why this exists beside the auditor.** Measured 2026-10-17, the contrast auditor's recall is
    /// as poor as its precision on this palette: on the Move tab it never nominated the week strip's
    /// "Rest" captions, drawn in 45% slate at 1.83:1 — the faintest text on the screen. A wall that
    /// only judges what the auditor nominates cannot see that. This sweep measures every static text
    /// the snapshot holds, the same way ``contrastVerdict(_:in:)`` measures a nominated one, and lists
    /// each one under the floor in the run's attachment.
    ///
    /// It does not fail the test. Text over a photograph, a gradient or another element defeats the
    /// dominant-colour background, so a line here is a lead to look at, not a verdict; the gallery's
    /// measured counts in `Docs/Accessibility-Nutrition-Labels.md` are read from these listings.
    func contrastSweep(in canvas: ContrastCanvas?) -> (measured: Int, below: [String]) {
        // A snapshot that cannot be taken measures nothing, and the attachment says "0 measured"
        // rather than passing for a screen with no faint text.
        guard let canvas, let root = try? app.snapshot() else { return (0, []) }
        let visible = window.frame
        // (node, whether an ancestor is a disabled control): text inside an inactive control is
        // exempt under WCAG 1.4.3, the same excuse ``contrastVerdict(_:in:)`` gives a nominated one.
        var stack: [(node: XCUIElementSnapshot, disabled: Bool)] = [(root, false)]
        var texts: [(label: String, frame: CGRect)] = []
        for _ in 0..<Self.maximumSweptNodes {
            guard let entry = stack.popLast() else { break }
            let disabled = entry.disabled || !entry.node.isEnabled
            let node = entry.node
            if node.elementType == .staticText, !node.label.isEmpty, !disabled, visible.contains(node.frame) {
                texts.append((node.label, node.frame))
            } else if let prompt = Self.shownPlaceholder(of: node), !disabled, visible.contains(node.frame) {
                // An empty field's prompt is text a user has to read too (WCAG 1.4.3 covers it),
                // and it is the one kind the snapshot never reports as a static text.
                texts.append(("placeholder: " + prompt, node.frame))
            }
            stack.append(contentsOf: node.children.map { ($0, disabled) })
        }
        var below: [String] = []
        var measured = 0
        for text in texts {
            // The bar's own labels are hidden from the tree (the buttons carry the titles), so any
            // text in the band is app content under the glass.
            if let band = canvas.tabBar, text.frame.intersects(band) { continue }
            guard let ratio = Self.renderedContrast(of: text.frame, in: canvas) else { continue }
            measured += 1
            if ratio < Self.textContrastFloor {
                below.append(String(format: "%.2f:1", ratio) + " — “\(text.label)” \(text.frame)")
            }
        }
        return (measured, below.sorted())
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
