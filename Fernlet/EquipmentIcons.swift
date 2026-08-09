import SwiftUI
import FernletDomainModel

// MARK: - Editable vector icons
//
// Every equipment / location glyph is stored below as a plain SVG-markup string (the inner elements
// of an SVG: <path>, <circle>, <rect>, <ellipse>, <line>). They render through the lightweight
// renderer in this file, tinted with the view's foreground colour.
//
// HOW TO EDIT AN ICON:
//   1. Design it in any SVG tool (Figma, Illustrator, Inkscape, etc.) on a 44×44 canvas
//      (40×40 for location icons), stroke only, no fill.
//   2. Copy the inner elements (everything between <svg> and </svg>).
//   3. Paste the string into the matching entry in `EquipmentIconLibrary.equipment` / `.location`.
// Coordinates are in the 0…viewBox space. Use `EquipmentIconLibrary.equipmentViewBox` (44).
//
// To swap an icon for an SF Symbol instead, just remove its entry — the card falls back to the
// `systemImage` on `GymEquipment` / `LocationTemplate`.

/// The hand-drawn vector artwork for every equipment and location glyph, stored as raw SVG-markup
/// strings plus their viewBox sizes.
///
/// Each entry holds the inner elements of a stroke-only SVG (see the editing guide in the comment
/// above). ``EquipmentGlyph`` and ``LocationGlyph`` look their artwork up here and fall back to an
/// SF Symbol when an entry is missing — so deleting a string is how an icon opts back into symbols.
enum EquipmentIconLibrary {
    static let equipmentViewBox: CGFloat = 44
    static let locationViewBox: CGFloat = 40

    /// Equipment glyphs, keyed by the equipment they represent. Edit these freely.
    static let equipment: [GymEquipment: String] = [
        .treadmill: #"<rect x="5" y="27" width="26" height="6" rx="3"/><path d="M29 27V13"/><path d="M26 13h7"/>"#,
        .exerciseBike: #"<circle cx="12" cy="30" r="5"/><circle cx="31" cy="30" r="5"/><path d="M12 30l7-13 12 13"/><path d="M19 17l-3 13"/><path d="M16 13h6M19 13v4"/><path d="M27 14h4l-2 3"/>"#,
        .rowingMachine: #"<circle cx="11" cy="21" r="6"/><path d="M6 31h32"/><rect x="22" y="27.5" width="10" height="3.5" rx="1.2"/><path d="M11 27v4"/><path d="M9 31v4M24 31v4M37 31v4"/><path d="M17 21h6"/>"#,
        .elliptical: #"<path d="M10 24a5 5 0 1 0 0 9l22-4.5z"/><path d="M19 30V12"/><path d="M16 12h7"/><path d="M13 30l-4-11M27 30l7-11"/>"#,
        .stairClimber: #"<path d="M6 34h7v-6h7v-6h7v-6"/><path d="M30 34V15c0-4 6-4 6 0"/>"#,
        .dumbbells: #"<rect x="8" y="16" width="5" height="13" rx="1.5"/><rect x="31" y="16" width="5" height="13" rx="1.5"/><rect x="5" y="19" width="3" height="7" rx="1.2"/><rect x="36" y="19" width="3" height="7" rx="1.2"/><path d="M13 22.5h18"/>"#,
        .barbell: #"<path d="M3 22h38"/><rect x="11" y="16" width="4" height="13" rx="1.2"/><rect x="16" y="13" width="4" height="19" rx="1.2"/><rect x="24" y="13" width="4" height="19" rx="1.2"/><rect x="29" y="16" width="4" height="13" rx="1.2"/>"#,
        .kettlebells: #"<path d="M16 26l5-10h2l5 10"/><path d="M16 33a8 8 0 1 1 12 0z"/>"#,
        .weightPlates: #"<circle cx="17" cy="22" r="11"/><circle cx="17" cy="22" r="3.5"/><path d="M30 12.5a11 11 0 0 1 0 19"/>"#,
        .weightBench: #"<path d="M6 21h28"/><path d="M6 21v-3M34 21v-3"/><path d="M10 21v8M30 21v8"/><path d="M8 29h4M28 29h4"/>"#,
        .cableMachine: #"<path d="M10 9v27M34 9v27"/><path d="M8 36h6M30 36h6"/><path d="M10 9h24"/><path d="M14 9v9"/><path d="M11 18h6"/><path d="M30 9v9"/><path d="M27 18h6"/>"#,
        .latPulldown: #"<path d="M9 23h26"/><path d="M9 23l-2 4M35 23l2 4"/><path d="M22 23V9"/><path d="M13 9h18"/><path d="M16 9V6M28 9V6"/>"#,
        .legPress: #"<path d="M7 32h11l15-13"/><path d="M7 32v-3"/><rect x="24" y="9" width="13" height="9" rx="2"/><path d="M13 27l7-6"/>"#,
        .smithMachine: #"<path d="M12 8v28M32 8v28"/><path d="M7 36h9M28 36h9"/><path d="M9 22h26"/><rect x="10" y="20" width="4" height="4" rx="1"/><rect x="30" y="20" width="4" height="4" rx="1"/>"#,
        .chestPress: #"<path d="M13 13v18"/><path d="M13 31h7"/><path d="M13 19h12M13 25h12"/><path d="M25 17v4M25 23v4"/>"#,
        .pullUpBar: #"<path d="M8 13h28"/><path d="M13 13V8M31 13V8"/><path d="M17 13v8M27 13v8"/>"#,
        .squatRack: #"<path d="M11 10v26M33 10v26"/><path d="M7 36h8M29 36h8"/><path d="M9 19h26"/><circle cx="10" cy="19" r="3"/><circle cx="34" cy="19" r="3"/>"#,
        .resistanceBands: #"<path d="M15 12c-7 4-7 16 0 20"/><path d="M29 12c7 4 7 16 0 20"/><path d="M15 12h14M15 32h14"/><circle cx="15" cy="12" r="1.8"/><circle cx="29" cy="32" r="1.8"/>"#,
        .medicineBall: #"<circle cx="22" cy="22" r="12"/><path d="M22 10v24M10 22h24"/><path d="M13.5 14.5c5 3 12 3 17 0M13.5 29.5c5-3 12-3 17 0"/>"#,
        .battleRopes: #"<path d="M8 16c4 4 8-4 11 0s7 4 11 0"/><path d="M8 22c4 4 8-4 11 0s7 4 11 0"/><rect x="30" y="12" width="6" height="4" rx="1"/><rect x="30" y="18" width="6" height="4" rx="1"/>"#,
        .yogaMat: #"<rect x="9" y="11" width="9" height="22" rx="4.5"/><path d="M13.5 11h14M13.5 33h14"/><path d="M27.5 11a4.5 11 0 0 1 0 22"/><ellipse cx="13.5" cy="22" rx="2.6" ry="6.5"/>"#,
        .foamRoller: #"<rect x="8" y="16" width="28" height="12" rx="6"/><path d="M30 16a6 6 0 0 1 0 12"/><path d="M14 16v12M20 16v12"/>"#,
    ]

    /// Location-template glyphs, keyed by `LocationTemplate.id`. 40×40 viewBox.
    static let location: [String: String] = [
        "full-gym": #"<rect x="6" y="14" width="5" height="16" rx="1.5"/><rect x="29" y="14" width="5" height="16" rx="1.5"/><rect x="3" y="18" width="3" height="8" rx="1.2"/><rect x="34" y="18" width="3" height="8" rx="1.2"/><path d="M11 22h18"/>"#,
        "hotel-gym": #"<path d="M5 31V18"/><path d="M5 24h28a4 4 0 0 1 4 4v3"/><path d="M5 31h32"/><path d="M10 24v-3a2 2 0 0 1 2-2h6a2 2 0 0 1 2 2v3"/>"#,
        "apartment-gym": #"<rect x="9" y="7" width="22" height="29" rx="2"/><path d="M14 13h3M23 13h3M14 19h3M23 19h3M14 25h3M23 25h3"/><path d="M17 36v-5h6v5"/>"#,
        "home-setup": #"<path d="M8 20L20 9l12 11"/><path d="M11 18v17h18V18"/><path d="M17 35v-8h6v8"/>"#,
    ]
}

// MARK: - Glyph views (use the SVG icon, fall back to an SF Symbol)

/// The tintable icon for one piece of gym equipment.
///
/// Renders the ``EquipmentIconLibrary`` vector when one exists for the item, otherwise falls back
/// to the item's `systemImage` SF Symbol. Used by the equipment checklist cards in
/// ``WorkoutLocationSetupView``; tint comes from the surrounding foreground style.
struct EquipmentGlyph: View {
    let item: GymEquipment
    var size: CGFloat = 24

    var body: some View {
        if let markup = EquipmentIconLibrary.equipment[item] {
            VectorIcon(markup: markup, viewBox: EquipmentIconLibrary.equipmentViewBox)
                .frame(width: size, height: size)
        } else {
            Image(systemName: item.systemImage).font(.system(size: size * 0.82))
        }
    }
}

/// The tintable icon for a workout-location template.
///
/// Renders the ``EquipmentIconLibrary`` location vector for the template id when one exists,
/// otherwise the given SF Symbol fallback. Used by the template cards in
/// ``WorkoutLocationSetupView``.
struct LocationGlyph: View {
    let templateID: String
    var fallbackSystemImage: String = "mappin.and.ellipse"
    var size: CGFloat = 24

    var body: some View {
        if let markup = EquipmentIconLibrary.location[templateID] {
            VectorIcon(markup: markup, viewBox: EquipmentIconLibrary.locationViewBox)
                .frame(width: size, height: size)
        } else {
            Image(systemName: fallbackSystemImage).font(.system(size: size * 0.82))
        }
    }
}

// MARK: - Renderer

/// Renders SVG markup as a stroked, tintable icon.
///
/// Stroke weight scales with the icon size to keep proportions consistent with the source design
/// (≈1.9 units in the viewBox); the stroke color comes from the surrounding view's foreground
/// style, which is how the glyph views tint. Wraps ``SVGShape`` in a `GeometryReader` so the line
/// width can track the rendered size.
struct VectorIcon: View {
    let markup: String
    var viewBox: CGFloat = 44
    var strokeUnits: CGFloat = 1.9

    var body: some View {
        GeometryReader { geo in
            let scale = min(geo.size.width, geo.size.height) / viewBox
            SVGShape(markup: markup, viewBox: viewBox)
                .stroke(style: StrokeStyle(lineWidth: max(strokeUnits * scale, 1), lineCap: .round, lineJoin: .round))
        }
    }
}

/// A SwiftUI `Shape` whose path is parsed from SVG markup via ``SVGMarkupParser``.
///
/// Scales the viewBox-space path uniformly to fit the proposed rect (centered on the shorter axis),
/// so ``VectorIcon`` can stroke it at any rendered size without distorting the artwork.
private struct SVGShape: Shape {
    let markup: String
    let viewBox: CGFloat

    func path(in rect: CGRect) -> Path {
        let raw = SVGMarkupParser.path(from: markup)
        let scale = min(rect.width, rect.height) / viewBox
        let offsetX = rect.minX + (rect.width - viewBox * scale) / 2
        let offsetY = rect.minY + (rect.height - viewBox * scale) / 2
        let transform = CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: offsetX, ty: offsetY)
        return raw.applying(transform)
    }
}

// MARK: - SVG markup → Path

/// A minimal SVG parser sufficient for stroke-only icons: <path> (M/L/H/V/C/S/Q/T/A/Z, absolute and
/// relative), <circle>, <rect>, <ellipse>, <line>. Intentionally small and dependency-free.
enum SVGMarkupParser {
    static func path(from markup: String) -> Path {
        var path = Path()
        for element in elements(in: markup) {
            switch element.tag {
            case "path":
                if let d = element.attributes["d"] { appendPathData(d, to: &path) }
            case "circle":
                if let cx = element.number("cx"), let cy = element.number("cy"), let r = element.number("r") {
                    path.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
                }
            case "ellipse":
                if let cx = element.number("cx"), let cy = element.number("cy"),
                   let rx = element.number("rx"), let ry = element.number("ry") {
                    path.addEllipse(in: CGRect(x: cx - rx, y: cy - ry, width: rx * 2, height: ry * 2))
                }
            case "rect":
                if let x = element.number("x"), let y = element.number("y"),
                   let w = element.number("width"), let h = element.number("height") {
                    let r = element.number("rx") ?? 0
                    path.addRoundedRect(in: CGRect(x: x, y: y, width: w, height: h), cornerSize: CGSize(width: r, height: r))
                }
            case "line":
                if let x1 = element.number("x1"), let y1 = element.number("y1"),
                   let x2 = element.number("x2"), let y2 = element.number("y2") {
                    path.move(to: CGPoint(x: x1, y: y1))
                    path.addLine(to: CGPoint(x: x2, y: y2))
                }
            default:
                break
            }
        }
        return path
    }

    /// One parsed SVG element: its tag name plus a raw attribute dictionary.
    ///
    /// The regex-based `elements(in:)` scan produces these; `number(_:)` is the shared numeric
    /// attribute accessor the per-tag path builders use.
    private struct Element {
        let tag: String
        let attributes: [String: String]
        func number(_ key: String) -> CGFloat? {
            attributes[key].flatMap { Double($0) }.map { CGFloat($0) }
        }
    }

    private static func elements(in markup: String) -> [Element] {
        var result: [Element] = []
        guard let elementRegex = try? NSRegularExpression(pattern: "<(path|circle|rect|ellipse|line)\\b([^>]*?)/?>", options: []),
              let attrRegex = try? NSRegularExpression(pattern: "([a-zA-Z0-9_-]+)\\s*=\\s*\"([^\"]*)\"", options: []) else {
            return result
        }
        let ns = markup as NSString
        let full = NSRange(location: 0, length: ns.length)
        for match in elementRegex.matches(in: markup, options: [], range: full) {
            let tag = ns.substring(with: match.range(at: 1))
            let attrString = ns.substring(with: match.range(at: 2))
            let attrNS = attrString as NSString
            var attributes: [String: String] = [:]
            for attrMatch in attrRegex.matches(in: attrString, options: [], range: NSRange(location: 0, length: attrNS.length)) {
                let key = attrNS.substring(with: attrMatch.range(at: 1))
                let value = attrNS.substring(with: attrMatch.range(at: 2))
                attributes[key] = value
            }
            result.append(Element(tag: tag, attributes: attributes))
        }
        return result
    }

    // MARK: Path-data ("d") parsing

    private static func appendPathData(_ d: String, to path: inout Path) {
        var scanner = NumberScanner(d)
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        var lastControl: CGPoint?
        var command: Character = " "

        while true {
            scanner.skipSeparators()
            guard let peek = scanner.peek() else { break }
            if peek.isLetter {
                command = scanner.readCharacter()!
            } else {
                // Implicit repeat: a moveto's extra coordinate pairs become linetos.
                if command == "M" { command = "L" } else if command == "m" { command = "l" }
            }

            let relative = command.isLowercase
            switch Character(command.lowercased()) {
            case "m":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return }
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.move(to: current)
                subpathStart = current
                lastControl = nil
            case "l":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return }
                current = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addLine(to: current)
                lastControl = nil
            case "h":
                guard let x = scanner.readNumber() else { return }
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                path.addLine(to: current)
                lastControl = nil
            case "v":
                guard let y = scanner.readNumber() else { return }
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                path.addLine(to: current)
                lastControl = nil
            case "c":
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x2 = scanner.readNumber(), let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else { return }
                let c1 = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let c2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "s":
                guard let x2 = scanner.readNumber(), let y2 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else { return }
                let c1 = reflectedControl(lastControl, around: current)
                let c2 = relative ? CGPoint(x: current.x + x2, y: current.y + y2) : CGPoint(x: x2, y: y2)
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addCurve(to: end, control1: c1, control2: c2)
                lastControl = c2
                current = end
            case "q":
                guard let x1 = scanner.readNumber(), let y1 = scanner.readNumber(),
                      let x = scanner.readNumber(), let y = scanner.readNumber() else { return }
                let c = relative ? CGPoint(x: current.x + x1, y: current.y + y1) : CGPoint(x: x1, y: y1)
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case "t":
                guard let x = scanner.readNumber(), let y = scanner.readNumber() else { return }
                let c = reflectedControl(lastControl, around: current)
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                path.addQuadCurve(to: end, control: c)
                lastControl = c
                current = end
            case "a":
                guard let rx = scanner.readNumber(), let ry = scanner.readNumber(),
                      let rot = scanner.readNumber(), let large = scanner.readFlag(),
                      let sweep = scanner.readFlag(), let x = scanner.readNumber(), let y = scanner.readNumber() else { return }
                let end = relative ? CGPoint(x: current.x + x, y: current.y + y) : CGPoint(x: x, y: y)
                addArc(to: &path, start: current, rx: rx, ry: ry, xRotDeg: rot, largeArc: large, sweep: sweep, end: end)
                current = end
                lastControl = nil
            case "z":
                path.closeSubpath()
                current = subpathStart
                lastControl = nil
            default:
                return
            }
        }
    }

    private static func reflectedControl(_ last: CGPoint?, around current: CGPoint) -> CGPoint {
        guard let last else { return current }
        return CGPoint(x: 2 * current.x - last.x, y: 2 * current.y - last.y)
    }

    /// Endpoint-to-centre arc conversion, emitted as ≤90° cubic-bézier segments (SVG spec appendix).
    private static func addArc(to path: inout Path, start p0: CGPoint, rx rxIn: CGFloat, ry ryIn: CGFloat,
                               xRotDeg: CGFloat, largeArc: Bool, sweep: Bool, end p1: CGPoint) {
        var rx = abs(rxIn), ry = abs(ryIn)
        if rx == 0 || ry == 0 || p0 == p1 { path.addLine(to: p1); return }
        let phi = xRotDeg * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (p0.x - p1.x) / 2, dy = (p0.y - p1.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        let lambda = (x1p * x1p) / (rx * rx) + (y1p * y1p) / (ry * ry)
        if lambda > 1 { let s = sqrt(lambda); rx *= s; ry *= s }

        let sign: CGFloat = (largeArc != sweep) ? 1 : -1
        let numerator = max(rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p, 0)
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        let coef = sign * sqrt(denominator == 0 ? 0 : numerator / denominator)
        let cxp = coef * (rx * y1p / ry)
        let cyp = coef * (-ry * x1p / rx)
        let cx = cosPhi * cxp - sinPhi * cyp + (p0.x + p1.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (p0.y + p1.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            let dot = ux * vx + uy * vy
            let len = sqrt((ux * ux + uy * uy) * (vx * vx + vy * vy))
            var a = acos(min(max(len == 0 ? 1 : dot / len, -1), 1))
            if ux * vy - uy * vx < 0 { a = -a }
            return a
        }

        let theta1 = angle(1, 0, (x1p - cxp) / rx, (y1p - cyp) / ry)
        var dTheta = angle((x1p - cxp) / rx, (y1p - cyp) / ry, (-x1p - cxp) / rx, (-y1p - cyp) / ry)
        if !sweep && dTheta > 0 { dTheta -= 2 * .pi }
        if sweep && dTheta < 0 { dTheta += 2 * .pi }

        let segments = max(Int(ceil(abs(dTheta) / (.pi / 2))), 1)
        let delta = dTheta / CGFloat(segments)
        let t = 4.0 / 3.0 * tan(delta / 4)
        var start = theta1

        func mapToEllipse(_ p: CGPoint) -> CGPoint {
            let x = p.x * rx, y = p.y * ry
            return CGPoint(x: cosPhi * x - sinPhi * y + cx, y: sinPhi * x + cosPhi * y + cy)
        }

        for _ in 0..<segments {
            let cosA1 = cos(start), sinA1 = sin(start)
            let end = start + delta
            let cosA2 = cos(end), sinA2 = sin(end)
            let control1 = mapToEllipse(CGPoint(x: cosA1 - t * sinA1, y: sinA1 + t * cosA1))
            let control2 = mapToEllipse(CGPoint(x: cosA2 + t * sinA2, y: sinA2 - t * cosA2))
            let endPoint = mapToEllipse(CGPoint(x: cosA2, y: sinA2))
            path.addCurve(to: endPoint, control1: control1, control2: control2)
            start = end
        }
    }
}

// MARK: - Number scanner for path data

/// A tiny forward-only tokenizer over SVG path-data ("d") strings.
///
/// Yields command letters, numbers, and single-character arc flags while skipping the
/// comma/whitespace separators the SVG grammar allows; ``SVGMarkupParser``'s path-data walker is
/// its only client.
private struct NumberScanner {
    private let characters: [Character]
    private var index = 0

    init(_ string: String) { characters = Array(string) }

    func peek() -> Character? { index < characters.count ? characters[index] : nil }

    mutating func skipSeparators() {
        while index < characters.count {
            let c = characters[index]
            if c == " " || c == "," || c == "\n" || c == "\t" || c == "\r" { index += 1 } else { break }
        }
    }

    mutating func readCharacter() -> Character? {
        skipSeparators()
        guard index < characters.count, characters[index].isLetter else { return nil }
        let c = characters[index]
        index += 1
        return c
    }

    mutating func readNumber() -> CGFloat? {
        skipSeparators()
        var string = ""
        if index < characters.count, characters[index] == "-" || characters[index] == "+" {
            string.append(characters[index]); index += 1
        }
        var seenDot = false
        while index < characters.count {
            let c = characters[index]
            if c.isNumber { string.append(c); index += 1 }
            else if c == "." && !seenDot { seenDot = true; string.append(c); index += 1 }
            else { break }
        }
        guard string.isEmpty == false, let value = Double(string) else { return nil }
        return CGFloat(value)
    }

    /// Arc flags are a single 0/1 character with no separator required.
    mutating func readFlag() -> Bool? {
        skipSeparators()
        guard index < characters.count else { return nil }
        let c = characters[index]
        if c == "0" { index += 1; return false }
        if c == "1" { index += 1; return true }
        return nil
    }
}
