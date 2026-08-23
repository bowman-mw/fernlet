// AccessibilityBoundaryTests.swift
// FernletTests
//
// The Swift port of the accessibility wall's grep half (Docs/Accessibility-Review-2026-08-22.md
// §4.5), sharing `Scripts/accessibility-allowlist.json` with `Scripts/accessibility-scan.py`.
//
// WHY A GREP WALL AND NOT A RUNTIME TEST. Every rule here is STRUCTURAL — a modifier that must (or
// must not) be present on a particular view — and every one of them fails SILENTLY when it is
// dropped: the screen looks identical, the build is clean, and only an assistive technology can
// tell. SwiftUI also does not materialise its accessibility node tree unless an assistive
// technology is attached to the process, so a runtime assertion routinely finds an empty tree and
// passes vacuously, which is the exact failure mode a wall exists to prevent. The runtime evidence
// is taken separately, by `performAccessibilityAudit` in `UXScreenProbe` across the 31 screens.
//
// WHY THE PORT IS CHECKED AGAINST THE PYTHON, LINE BY LINE. This half is the one CI enforces, and
// the 2026-08-23 adversarial review found it had already drifted: the A5 rule matched the exact
// substring `"GridItem(.adaptive(minimum:"` where the scanner used a whitespace-tolerant regex, so
// `GridItem( .adaptive(minimum: 80))` — one space — was a violation on a developer's machine and
// invisible in CI. Drift like that is silent in both directions, so the two halves are now pinned
// to each other by ``theSwiftPortAndThePythonScannerAgreeOnEveryBound()`` (shared constants) and
// ``portedPatternsAppearVerbatimInTheScanner()`` (shared regexes), and every planted evasion below
// is run against BOTH halves — the Python by `Scripts/accessibility-scan.py`, this one by the
// fixtures at the bottom of this file.
//
// WHAT THIS WALL CANNOT SEE — the honest ceiling, restated here because it is what stops the wall
// being mistaken for coverage, and kept in step with the scanner's module docstring. It catches
// seven named structural regressions. It does NOT catch a rawValue that reaches a label through a
// function call or across a file, a string computed at runtime, a label that is present but WRONG,
// focus order, a missing custom action, an unhonored Reduce Motion, or anything about how a screen
// actually sounds. Those stay manual, forever.
//
// ONE HOME PER RULE. The tempting eighth rule — "an accessibility label may not be a bare `String`"
// — is deliberately absent: a grep cannot distinguish `.accessibilityLabel(coverText)` (a `String`,
// a real defect) from `.accessibilityLabel(titleKey)` (a `LocalizedStringKey`, correct). It lives
// in `LocalizationBoundaryTests` as a TYPE check on the named members. Do not add it here too.

import Foundation
import Testing

/// Grep-wall enforcing the seven mechanically decidable accessibility invariants of §4.5.
///
/// Each rule is a pure matcher over source text, exercised both against the real tree (with a
/// file-count floor, so a green run cannot mean "the scan read nothing") and against planted
/// fixtures (so a green run cannot mean "the matcher never fires"). Both halves are required: the
/// tree scan proves the codebase is clean, the fixtures prove the check is alive.
///
/// The allowlist is read from the same JSON the Python scanner uses, so the two halves cannot
/// disagree about what is exempt — a divergence there would be a wall that passes in CI and fails
/// on a developer's machine, or worse, the reverse.
@Suite struct AccessibilityBoundaryTests {

    // MARK: - Shape

    /// The shipping roots scanned. Test and tool sources are deliberately excluded: a fixture in a
    /// test file is *supposed* to contain the shapes this wall forbids.
    static let shippingRoots = [
        "FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension"
    ]

    /// Floor on files scanned (385 at the time of writing). Set well below the real count so
    /// ordinary churn never trips it, but a root that stops resolving does. Without it, "zero
    /// violations" and "read nothing" are the same result.
    static let minimumFilesScanned = 300

    /// The canonical scanner this file ports, repo-relative.
    static let scannerPath = "Scripts/accessibility-scan.py"

    /// The regex shim, reused from the Power-of-10 wall rather than declared twice: both walls port
    /// Python `re` patterns into this one test target, and a second copy of one ICU adapter is
    /// exactly the duplication this repo removes on sight.
    typealias Pattern = PowerOfTenBoundaryTests.Pattern

    /// One successful ``Pattern`` match.
    typealias Match = PowerOfTenBoundaryTests.Match

    /// One rule violation.
    struct Finding: Hashable, Sendable {
        /// The rule ID, matching the Python scanner's and §4.5's.
        let rule: String
        /// Repo-relative path.
        let path: String
        /// 1-based line number.
        let line: Int
        /// The RAW source line — not the comment-and-literal-stripped form the matchers run on, so
        /// the allowlist's `line_contains` can name an actual string literal.
        let text: String

        /// `rule path:line: text` — pasteable into a search.
        var report: String { "\(rule) \(path):\(line): \(text.trimmingCharacters(in: .whitespaces))" }
    }

    /// One allowlist entry, decoded from `Scripts/accessibility-allowlist.json`.
    struct Exemption: Decodable, Sendable {
        /// The rule the entry exempts.
        let rule: String
        /// Repo-relative path; required, so an entry can never go tree-wide.
        let path: String
        /// A substring of the raw offending line. Omitting it exempts every hit of that rule in
        /// that file — use only when the whole file is the invariant, and say so in `reason`.
        let lineContains: String?
        /// The invariant that makes the exemption safe. Never decorative: the house rule is that a
        /// reader must be able to re-derive the decision from this sentence alone.
        let reason: String

        private enum CodingKeys: String, CodingKey {
            case rule, path, reason
            case lineContains = "line_contains"
        }

        /// Whether this entry covers `finding`.
        func covers(_ finding: Finding) -> Bool {
            guard rule == finding.rule, path == finding.path else { return false }
            guard let lineContains else { return true }
            return finding.text.contains(lineContains)
        }
    }
}

// MARK: - Fixed bounds (mirrored from the scanner)

extension AccessibilityBoundaryTests {

    /// Code lines joined so a wrapped `.accessibilityElement(…)` is read as one call.
    static let a1CallLines = 4
    /// Modifiers allowed between `.combine` and the label that replaces what it gathered.
    static let a1ChainSteps = 4
    /// Code lines joined so a wrapped spoken-modifier argument list is read as one call.
    static let a2Window = 8
    /// Code lines of a computed property's body read when binding identifiers to `.rawValue`.
    static let a2BodyLines = 4
    /// Code lines joined so a wrapped `GridItem(…)` is read as one call.
    static let a5Window = 3
    /// Code lines of a declaration read when deciding whether it derives from a `@ScaledMetric`.
    static let a5DerivationLines = 3
    /// Hops followed from a grid minimum back to a `@ScaledMetric`.
    static let a5DerivationPasses = 3
    /// Code lines after `Image(uiImage:)` searched for the Smart Invert opt-out.
    static let a6Window = 12
    /// Code lines searched backwards for the `Button` a `children: .ignore` chains onto.
    static let a7Lookback = 60
    /// `accessibilityAddTraits(` calls inspected inside one heading canary's braces.
    static let addTraitsScanLimit = 32
    /// `Text(verbatim: …)`-style wrappers peeled off a spoken argument before comparing it.
    static let wrapperUnwraps = 3
}

// MARK: - Tokenizer

extension AccessibilityBoundaryTests {

    /// One source line, split into what the matchers read and what a report shows.
    struct SourceLine: Sendable {
        /// 1-based line number.
        let number: Int
        /// The line with comments removed and string literals collapsed to `""`, so no rule can
        /// fire on a modifier name that appears inside a doc comment or a user-facing sentence.
        let code: String
        /// The line exactly as written.
        let raw: String
    }

    /// Tokenizer state carried across lines: `/* */` nesting depth and whether a `"""` literal is open.
    private struct ScanState {
        var block = 0
        var multiline = false
    }

    /// The code-only portion of `line`, updating `state`.
    ///
    /// Approximate but line-faithful, and deliberately the same shape as
    /// `Scripts/power-of-10-scan.py`'s `strip_code` so the two walls tokenize source identically.
    private static func stripped(_ line: String, _ state: inout ScanState) -> String {
        var out = ""
        let chars = Array(line)
        var i = 0
        while i < chars.count {
            if state.block > 0 {
                guard let j = find("*/", in: chars, from: i) else { return out }
                state.block -= 1
                i = j + 2
                continue
            }
            if state.multiline {
                guard let j = find("\"\"\"", in: chars, from: i) else { return out }
                state.multiline = false
                i = j + 3
                continue
            }
            if matches("\"\"\"", chars, i) { state.multiline = true; i += 3; continue }
            if matches("//", chars, i) { return out }
            if matches("/*", chars, i) { state.block += 1; i += 2; continue }
            if chars[i] == "\"" {
                i = consumeLiteral(chars, from: i, into: &out)
                continue
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }

    /// Consumes the string literal opening at `start`, appending `""` for its TEXT but appending
    /// each `\(…)` interpolation VERBATIM, and returns the index just past the closing quote.
    ///
    /// The interpolation half is load-bearing, not thoroughness. A Swift interpolation is code
    /// inside a literal, and it is where rule A2's defect actually lives: the shape the review
    /// found in the shipping app was `.accessibilityLabel("Fernlet companion, \(state.rawValue)")`
    /// (T1-10). A tokenizer that erased the whole literal — which is what both walls' first drafts
    /// did — would leave A2 blind to the only instance of the bug anyone has ever seen.
    private static func consumeLiteral(_ chars: [Character], from start: Int, into out: inout String) -> Int {
        var i = start + 1
        out += "\"\""
        while i < chars.count {
            if chars[i] == "\\" && i + 1 < chars.count && chars[i + 1] == "(" {
                var depth = 0
                var j = i + 1
                while j < chars.count {
                    if chars[j] == "(" { depth += 1 }
                    if chars[j] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    j += 1
                }
                out += String(chars[(i + 1)...min(j, chars.count - 1)])
                i = j + 1
                continue
            }
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "\"" { return i + 1 }
            i += 1
        }
        return i
    }

    private static func matches(_ needle: String, _ chars: [Character], _ i: Int) -> Bool {
        let n = Array(needle)
        guard i >= 0, i + n.count <= chars.count else { return false }
        for k in 0..<n.count where chars[i + k] != n[k] { return false }
        return true
    }

    private static func find(_ needle: String, in chars: [Character], from: Int) -> Int? {
        guard from <= chars.count else { return nil }
        for i in from..<max(from, chars.count) where matches(needle, chars, i) { return i }
        return nil
    }

    /// Character offset of the first `needle` at or after `from`, or nil — the port of Python's
    /// `str.find`, kept in integer offsets so a match can be mapped back to its line.
    static func offset(of needle: String, in chars: [Character], from: Int) -> Int? {
        guard !needle.isEmpty, from >= 0 else { return nil }
        return find(needle, in: chars, from: from)
    }

    /// Every line of `source` that carries code, tokenized.
    static func sourceLines(_ source: String) -> [SourceLine] {
        var state = ScanState()
        var result: [SourceLine] = []
        for (index, raw) in source.components(separatedBy: .newlines).enumerated() {
            let code = stripped(raw, &state)
            guard !code.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            result.append(SourceLine(number: index + 1, code: code, raw: raw))
        }
        return result
    }

    /// Leading-whitespace width of a code-only line — A7's whole notion of "same chain level".
    static func indentWidth(_ code: String) -> Int {
        code.prefix { $0.isWhitespace }.count
    }
}

// MARK: - Call spans and fixed windows

extension AccessibilityBoundaryTests {

    /// `(open, close)` character offsets of the balanced-paren call whose `(` is at or after `start`.
    ///
    /// Bounded by the length of `chars`: the index only advances, so it terminates on every input
    /// including unbalanced source (which yields the remainder).
    static func callBounds(_ chars: [Character], from start: Int) -> (open: Int, close: Int)? {
        guard start >= 0, let open = offset(of: "(", in: chars, from: start) else { return nil }
        var depth = 0
        for i in open..<chars.count {
            if chars[i] == "(" { depth += 1 }
            if chars[i] == ")" {
                depth -= 1
                if depth == 0 { return (open, i) }
            }
        }
        return (open, chars.count)
    }

    /// The balanced-paren argument text of the call whose `(` is at or after `start`.
    static func callSpan(_ chars: [Character], from start: Int) -> String {
        guard let bounds = callBounds(chars, from: start) else { return "" }
        let upper = min(bounds.close, chars.count)
        guard bounds.open + 1 <= upper else { return "" }
        return String(chars[(bounds.open + 1)..<upper])
    }

    /// A FIXED-size join of code lines, carrying the offset each line begins at so a match can be
    /// mapped back to the line that produced it.
    ///
    /// Comment-only and blank lines are already gone from `[SourceLine]`, so a window counts
    /// MODIFIERS, not source lines — a ten-line explanatory comment between two modifiers costs
    /// nothing, which is what makes a four-line window a usable bound in this codebase.
    struct Window: Sendable {
        /// The joined code text.
        let text: String
        /// `text` as characters, so every offset in this file is an `Int` and stays one.
        let chars: [Character]
        /// The offset at which each joined line begins.
        let starts: [Int]

        /// The window-relative index of the line containing character offset `position`.
        func line(at position: Int) -> Int {
            var found = 0
            for (index, start) in starts.enumerated() where start <= position { found = index }
            return found
        }
    }

    /// `count` code lines from `index`, joined by one space.
    static func window(_ lines: [SourceLine], from index: Int, count: Int) -> Window {
        guard index >= 0, count > 0, index < lines.count else {
            return Window(text: "", chars: [], starts: [])
        }
        var parts: [String] = []
        var starts: [Int] = []
        var offset = 0
        for position in index..<min(index + count, lines.count) {
            starts.append(offset)
            parts.append(lines[position].code)
            offset += lines[position].code.count + 1
        }
        let text = parts.joined(separator: " ")
        return Window(text: text, chars: Array(text), starts: starts)
    }

    /// Character offset of the START of `match` within `source`.
    static func matchStart(_ match: Match, in source: String) -> Int {
        guard let range = Range(match.result.range, in: source) else { return 0 }
        return source.distance(from: source.startIndex, to: range.lowerBound)
    }

    /// Character offset just past the END of `match` within `source` — Python's `m.end()`.
    static func matchEnd(_ match: Match, in source: String) -> Int {
        guard let range = Range(match.result.range, in: source) else { return 0 }
        return source.distance(from: source.startIndex, to: range.upperBound)
    }

    /// Every capture-group-1 string of `pattern` in `source`, in order.
    ///
    /// This is Python's `re.findall` FOR A PATTERN WITH ONE GROUP, which returns the group rather
    /// than the whole match — a difference that silently inverts a rule if it is ported wrong.
    static func captures(_ pattern: Pattern, in source: String) -> [String] {
        guard !source.isEmpty else { return [] }
        let range = NSRange(source.startIndex..<source.endIndex, in: source)
        return pattern.regex.matches(in: source, options: [], range: range).compactMap { result in
            guard result.numberOfRanges > 1, let group = Range(result.range(at: 1), in: source) else { return nil }
            return String(source[group])
        }
    }

    /// Every match of `pattern` as (character offset of the match, capture group 1) — Python's
    /// `finditer` where both the position and the group are needed.
    static func offsetCaptures(_ pattern: Pattern, in text: String) -> [(offset: Int, value: String)] {
        guard !text.isEmpty else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return pattern.regex.matches(in: text, options: [], range: range).compactMap { result in
            guard result.numberOfRanges > 1,
                  let whole = Range(result.range, in: text),
                  let group = Range(result.range(at: 1), in: text) else { return nil }
            return (text.distance(from: text.startIndex, to: whole.lowerBound), String(text[group]))
        }
    }
}

// MARK: - The shared vocabulary

extension AccessibilityBoundaryTests {

    /// Modifiers whose argument VoiceOver reads OUT LOUD.
    ///
    /// `accessibilityIdentifier` is deliberately absent. An identifier is a frozen automation
    /// token that is never spoken, and deriving one from a `rawValue` is the *correct* thing to do
    /// — 12 sites do exactly that. A rule that flagged them would be asking for the wrong thing,
    /// and a wall that asks for the wrong thing gets switched off. `accessibilityAction` IS here:
    /// a NAMED action is read out by the Actions rotor, which is speech like any other.
    static let spokenModifiers = [
        "accessibilityLabel", "accessibilityValue", "accessibilityHint",
        "accessibilityInputLabels", "accessibilityCustomContent", "accessibilityAction"
    ]

    /// UIKit's PROPERTY form of the same thing. `view.accessibilityLabel = mode.rawValue` has no
    /// call parentheses at all, so the modifier matcher is structurally blind to it — the two
    /// forms need two matchers, not one.
    static let spokenProperties = [
        "accessibilityLabel", "accessibilityValue", "accessibilityHint",
        "accessibilityUserInputLabels", "accessibilityAttributedLabel",
        "accessibilityAttributedValue", "accessibilityAttributedHint"
    ]

    /// The announcement channel: spoken IMMEDIATELY, present in no label, and therefore invisible
    /// to every label-shaped check. This is where T1-10's original defect lived and where batch A3
    /// shipped 24 announcer sites.
    static let announcementCalls = [
        "AccessibilityNotification.Announcement(", "UIAccessibility.post(", "NSAccessibility.post("
    ]

    /// The three shared components whose heading trait is the T1-1 regression canary, as
    /// (repo-relative path, type name).
    static let headingCanaries = [
        ("FernletKit/Sources/FernletUI/FernletPrimitives.swift", "SectionLabel"),
        ("FernletKit/Sources/FernletUI/FernletUIComponents.swift", "ScreenHeader"),
        ("FernletKit/Sources/FernletUI/SheetChrome.swift", "SheetHeader")
    ]

    /// Wrappers peeled off a spoken argument before it is compared to a rawValue-bound identifier.
    static let wrappers = ["Text(verbatim:", "Text(", "LocalizedStringKey(", "String(", "Optional("]

    static let elementCall = "accessibilityElement("
    static let addTraitsCall = "accessibilityAddTraits("
    static let invertNeedle = "accessibilityIgnoresInvertColors"

    static let combineArguments = Pattern(#"^\s*children:\s*\.combine\s*$"#)
    static let ignoreElement = Pattern(#"accessibilityElement\(\s*children:\s*\.ignore\s*\)"#)
    static let labelStep = Pattern(#"^\.\s*accessibilityLabel\s*\("#)
    static let labelAnywhere = Pattern(#"\.\s*accessibilityLabel\s*\("#)
    static let gridColumn = Pattern(#"GridItem\(\s*\.(?:adaptive\(\s*minimum:|fixed\()\s*([^,)]+)"#)
    static let scaledMetric = Pattern(#"@ScaledMetric\b[\s\S]{0,160}?\bvar\s+([A-Za-z_]\w*)"#)
    static let binding = Pattern(#"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::[^={]*)?(=(?!=)|\{)"#)
    static let boundArgument = Pattern(#"\(\s*([A-Za-z_]\w*)\s*\)"#)
    static let imageBitmap = Pattern(#"\bImage\(\s*uiImage:"#)
    static let buttonHead = Pattern(#"\bButton\s*[({<]"#)
    static let numericLiteral = Pattern(#"^\d+(?:\.\d+)?$"#)
    static let identifier = Pattern(#"[A-Za-z_]\w*"#)
    static let structHead = Pattern([
        #"^\s*(?:public\s+|internal\s+|package\s+|private\s+|fileprivate\s+|final\s+)*"#,
        #"(?:struct|class|enum)\s+([A-Za-z_]\w*)"#
    ])
    static let customFont = Pattern(#"\.custom\("#)

    /// UIKit's assignment form, built from ``spokenProperties`` exactly as the scanner builds it
    /// from `SPOKEN_PROPERTIES` — so adding a property name on one side and not the other is a
    /// difference the constant cross-check reports rather than a silent hole.
    static let assignment = Pattern([
        #"\.("#, spokenProperties.joined(separator: "|"), #")\s*=(?!=)\s*(.+)$"#
    ])

    /// Every pattern whose Python source must appear VERBATIM in the scanner.
    static let portedPatterns: [Pattern] = [
        combineArguments, ignoreElement, labelStep, labelAnywhere, gridColumn, scaledMetric,
        binding, boundArgument, imageBitmap, buttonHead, numericLiteral, identifier, structHead
    ]

    /// The two literal fragments of ``assignment``; its middle piece is COMPUTED on both sides, so
    /// it cannot be compared as text and is covered by the `SPOKEN_PROPERTIES` tuple check instead.
    static let assignmentFragments = [#"\.("#, #")\s*=(?!=)\s*(.+)$"#]
}

// MARK: - A1

extension AccessibilityBoundaryTests {

    /// Index into `lines` of the `.accessibilityLabel(` continuing the SAME modifier chain that
    /// ends at `endIndex`, or nil.
    ///
    /// The semantics being enforced is "anywhere later in this chain", not "the very next line":
    /// `.combine` / `.padding(4)` / `.accessibilityLabel(…)` silences the gathered fragments
    /// exactly as the adjacent pair does, and the review's third planted evasion was precisely one
    /// interleaved modifier. The walk stops at the first line that does not begin with `.`, which
    /// is what actually ends a SwiftUI chain — so ``a1ChainSteps`` is not a guess at scope, it is a
    /// ceiling on how far a legitimate chain may run before the wall stops looking. Four clears the
    /// three-modifier `.padding`/`.background`/`.contentShape` runs this codebase writes.
    static func chainLabel(_ lines: [SourceLine], endIndex: Int, leftover: String) -> Int? {
        guard endIndex >= 0, endIndex < lines.count else { return nil }
        let tail = leftover.trimmingCharacters(in: .whitespaces)
        if tail.hasPrefix(".") {
            if labelAnywhere.search(tail) != nil { return endIndex }
        } else if !tail.isEmpty {
            return nil
        }
        let upper = min(endIndex + 1 + a1ChainSteps, lines.count)
        guard endIndex + 1 < upper else { return nil }
        for index in (endIndex + 1)..<upper {
            let step = lines[index].code.trimmingCharacters(in: .whitespaces)
            guard step.hasPrefix(".") else { return nil }
            if labelStep.match(step) != nil { return index }
        }
        return nil
    }

    /// **A1** — `.accessibilityElement(children: .combine)` followed, in the same modifier chain,
    /// by `.accessibilityLabel(`.
    ///
    /// The label does not *add* to what `.combine` gathered; it REPLACES it. So the pair is a
    /// defect by default and correct only when the label says strictly MORE than the fragments it
    /// just silenced — a unit that is never drawn, a row kind the layout encodes by position, an
    /// ordinal. Every legitimate pair is allowlisted with exactly what it adds. The `.combine` call
    /// itself is read across a FIXED ``a1CallLines``-line join, so writing it as
    /// `.accessibilityElement(\n children: .combine\n)` — or as `children:.combine`, without the
    /// space — does not hide it.
    static func combineLabelFindings(_ path: String, _ lines: [SourceLine]) -> [Finding] {
        guard !path.isEmpty else { return [] }
        var findings: [Finding] = []
        for (index, line) in lines.enumerated() {
            guard line.code.contains(elementCall) else { continue }
            let win = window(lines, from: index, count: a1CallLines)
            guard let head = offset(of: elementCall, in: win.chars, from: 0),
                  let bounds = callBounds(win.chars, from: head),
                  combineArguments.match(callSpan(win.chars, from: head)) != nil else { continue }
            let relative = win.line(at: bounds.close)
            let nextStart = relative + 1 < win.starts.count ? win.starts[relative + 1] : win.chars.count + 1
            let low = min(bounds.close + 1, win.chars.count)
            let high = min(max(low, nextStart - 1), win.chars.count)
            let leftover = String(win.chars[low..<high])
            guard let found = chainLabel(lines, endIndex: index + relative, leftover: leftover) else { continue }
            findings.append(Finding(rule: "A1-COMBINE-LABEL", path: path,
                                    line: lines[found].number, text: lines[found].raw))
        }
        return findings
    }
}

// MARK: - A2

extension AccessibilityBoundaryTests {

    /// Identifiers in THIS file bound to an expression containing `.rawValue`.
    ///
    /// Two shapes, both bounded: `let/var X = …rawValue…` read on its own line, and a computed
    /// `var X: T { …rawValue… }` read across ``a2BodyLines`` code lines. Without this pass, hoisting
    /// `mode.rawValue` into a one-line `let` was enough to walk straight through rule A2 — which is
    /// what the review's fifth and sixth planted evasions did. Ceiling, stated plainly: it does not
    /// follow a rawValue through a `func`, through a parameter, or across a file.
    static func rawValueBoundNames(_ lines: [SourceLine]) -> Set<String> {
        guard !lines.isEmpty else { return [] }
        var names: Set<String> = []
        for (index, line) in lines.enumerated() {
            guard let match = binding.search(line.code), let name = match.group(1) else { continue }
            let end = matchEnd(match, in: line.code)
            if match.group(2) == "=" {
                if String(line.code.dropFirst(end)).contains(".rawValue") { names.insert(name) }
                continue
            }
            let body = window(lines, from: index, count: a2BodyLines).text
            if String(body.dropFirst(end)).contains(".rawValue") { names.insert(name) }
        }
        return names
    }

    /// Whether `arguments` IS (or interpolates) one of the rawValue-bound identifiers.
    static func speaksBoundName(_ arguments: String, _ bound: Set<String>) -> Bool {
        guard !bound.isEmpty else { return false }
        var core = arguments.trimmingCharacters(in: .whitespaces)
        for _ in 0..<wrapperUnwraps {
            var peeled = core
            for wrapper in wrappers where core.hasPrefix(wrapper) && core.hasSuffix(")") {
                peeled = String(core.dropFirst(wrapper.count).dropLast()).trimmingCharacters(in: .whitespaces)
                break
            }
            if peeled == core { break }
            core = peeled
        }
        if bound.contains(core) { return true }
        return captures(boundArgument, in: arguments).contains { bound.contains($0) }
    }

    /// A2's CALL forms: a spoken SwiftUI modifier, or a posted announcement.
    static func spokenCallFindings(_ path: String, _ line: SourceLine, _ win: Window,
                                   _ bound: Set<String>) -> [Finding] {
        guard !path.isEmpty else { return [] }
        var findings: [Finding] = []
        for token in spokenModifiers.map({ ".\($0)(" }) + announcementCalls {
            guard line.code.contains(token), let start = offset(of: token, in: win.chars, from: 0) else { continue }
            let arguments = callSpan(win.chars, from: start)
            guard arguments.contains(".rawValue") || speaksBoundName(arguments, bound) else { continue }
            findings.append(Finding(rule: "A2-RAWVALUE-SPOKEN", path: path, line: line.number, text: line.raw))
        }
        return findings
    }

    /// A2's UIKit PROPERTY form: `view.accessibilityLabel = mode.rawValue`, which carries no call
    /// parentheses and is therefore invisible to the modifier matcher above.
    static func spokenAssignmentFindings(_ path: String, _ line: SourceLine, _ bound: Set<String>) -> [Finding] {
        guard !path.isEmpty, let match = assignment.search(line.code),
              let right = match.group(2) else { return [] }
        guard right.contains(".rawValue") || speaksBoundName(right, bound) else { return [] }
        return [Finding(rule: "A2-RAWVALUE-SPOKEN", path: path, line: line.number, text: line.raw)]
    }

    /// **A2** — a `.rawValue` reaching anything VoiceOver speaks.
    ///
    /// A `rawValue` in this codebase is a frozen English token: a persisted column value, a mesh
    /// wire byte, a widget cross-process contract, a Coach export schema field. Speaking one both
    /// leaks an implementation detail into the user's ear and can never be translated — and the
    /// review caught the app doing exactly this with `CompanionState.rawValue` (T1-10). The join
    /// window is a FIXED ``a2Window`` lines; eight rather than the original four because a deeply
    /// wrapped argument list is five lines deep before it says anything, and four silently exempted
    /// it.
    static func spokenRawValueFindings(_ path: String, _ lines: [SourceLine]) -> [Finding] {
        guard !path.isEmpty else { return [] }
        let bound = rawValueBoundNames(lines)
        var findings: [Finding] = []
        for (index, line) in lines.enumerated() {
            let win = window(lines, from: index, count: a2Window)
            findings += spokenCallFindings(path, line, win, bound)
            findings += spokenAssignmentFindings(path, line, bound)
        }
        return findings
    }
}

// MARK: - A4 / A5

extension AccessibilityBoundaryTests {

    /// **A4** — a `.custom` font that cannot respond to Larger Text.
    ///
    /// `Font.custom(_:size:)` without `relativeTo:` pins the point size forever; `fixedSize:` says
    /// so outright. `size:`/`fixedSize:` is also what separates a font call from the unrelated
    /// `.custom(label:group:)` factories elsewhere in the tree. The baseline starts clean — all 11
    /// type roles and every one-off already pass `relativeTo:` — which is exactly when a canary is
    /// worth planting.
    static func fontScaleFindings(_ path: String, _ lines: [SourceLine]) -> [Finding] {
        guard !path.isEmpty else { return [] }
        var findings: [Finding] = []
        for (index, line) in lines.enumerated() {
            guard line.code.contains(".custom(") else { continue }
            let win = window(lines, from: index, count: 3)
            guard let start = offset(of: ".custom(", in: win.chars, from: 0) else { continue }
            let arguments = callSpan(win.chars, from: start)
            let fixed = arguments.contains("fixedSize:")
            let unscaled = arguments.contains("size:") && !arguments.contains("relativeTo:")
            guard fixed || unscaled else { continue }
            findings.append(Finding(rule: "A4-FONT-SCALES", path: path, line: line.number, text: line.raw))
        }
        return findings
    }

    /// Identifiers in this file that actually carry Dynamic Type scaling.
    ///
    /// Seeded with every `@ScaledMetric … var X`, then closed over declarations that READ one —
    /// `private var itemTileMinimum: CGFloat { min(scaledItemTileMinimum, 300) }` is the shipping
    /// shape and it is correct. The closure runs ``a5DerivationPasses`` FIXED passes, never to a
    /// fixpoint: a chain deeper than three hops is reported, and the fix is to bind the grid to the
    /// metric more directly rather than to widen the bound.
    ///
    /// This replaces the previous test, which was "the FILE contains the string `@ScaledMetric`
    /// anywhere" — one unrelated metric could launder every named minimum in a 3000-line view file,
    /// which is exactly the shape the review's thirteenth planted evasion took.
    static func scalingNames(_ source: String, _ lines: [SourceLine]) -> Set<String> {
        guard !source.isEmpty else { return [] }
        var names = Set(captures(scaledMetric, in: source))
        var order: [String] = []
        var declarations: [String: String] = [:]
        for (index, line) in lines.enumerated() {
            guard let match = binding.search(line.code), let name = match.group(1) else { continue }
            let body = window(lines, from: index, count: a5DerivationLines).text
            if declarations[name] == nil { order.append(name) }
            declarations[name] = String(body.dropFirst(matchEnd(match, in: line.code)))
        }
        for _ in 0..<a5DerivationPasses {
            var grew = false
            for name in order where !names.contains(name) {
                guard let body = declarations[name],
                      identifier.findAll(body).contains(where: { names.contains($0) }) else { continue }
                names.insert(name)
                grew = true
            }
            if !grew { break }
        }
        return names
    }

    /// **A5** — a grid column width that cannot grow with the text inside it.
    ///
    /// A bare numeric `GridItem(.adaptive(minimum:))` holds its point width at every text size, so
    /// at AX5 the cell stays put and its label truncates inside it instead of the grid reflowing to
    /// fewer columns; `GridItem(.fixed(_:))` is the same defect with the reflow removed as well. A
    /// named width is accepted only when this file derives it from a `@ScaledMetric`. The
    /// `GridItem(` call is read across a FIXED ``a5Window``-line join so a wrapped one is still one
    /// call, and a match counts only when the `GridItem(` token itself began on the window's first
    /// line, which is what stops overlapping windows reporting a site twice.
    static func gridScaleFindings(_ path: String, _ lines: [SourceLine], source: String) -> [Finding] {
        guard !path.isEmpty else { return [] }
        let scaling = scalingNames(source, lines)
        var findings: [Finding] = []
        for (index, line) in lines.enumerated() {
            guard line.code.contains("GridItem(") else { continue }
            let win = window(lines, from: index, count: a5Window)
            for match in offsetCaptures(gridColumn, in: win.text) where win.line(at: match.offset) == 0 {
                let argument = match.value.trimmingCharacters(in: .whitespaces)
                let literal = numericLiteral.match(argument) != nil
                let scales = identifier.findAll(argument).contains { scaling.contains($0) }
                guard literal || !scales else { continue }
                findings.append(Finding(rule: "A5-GRID-SCALES", path: path, line: line.number, text: line.raw))
            }
        }
        return findings
    }
}

// MARK: - A6 / A7

extension AccessibilityBoundaryTests {

    /// **A6** — a rendered-bitmap `Image(uiImage:)` that never opts out of Smart Invert.
    ///
    /// Smart Invert exists so a user can darken the UI while photographs stay photographs; without
    /// `.accessibilityIgnoresInvertColors()` a meal photo, a progress photo, a QR code or a scanned
    /// still is rendered as a colour NEGATIVE (T2-10) — unrecognisable to exactly the low-vision
    /// users the setting exists for. ``a6Window`` = 12 code lines: the widest legitimate gap in the
    /// tree is 8 (BarcodeScanView.swift:287 → :297, a resizable/scaledToFill/frame/clipped run), so
    /// twelve leaves headroom for a few more modifiers. Known false negative, stated rather than
    /// hidden: two `Image(uiImage:)` inside one window are satisfied by a single opt-out.
    static func invertColorFindings(_ path: String, _ lines: [SourceLine]) -> [Finding] {
        guard !path.isEmpty else { return [] }
        var findings: [Finding] = []
        for (index, line) in lines.enumerated() {
            guard imageBitmap.search(line.code) != nil else { continue }
            guard !window(lines, from: index, count: a6Window).text.contains(invertNeedle) else { continue }
            findings.append(Finding(rule: "A6-INVERT-COLORS", path: path, line: line.number, text: line.raw))
        }
        return findings
    }

    /// The source line of the `Button` a `children: .ignore` at `index` is chained onto, or nil.
    ///
    /// HONEST HEURISTIC, and its error direction is deliberate. A grep cannot parse SwiftUI, so
    /// "is this modifier on a Button?" is decided by LAYOUT: the nearest `Button` opening at the
    /// SAME indent, within ``a7Lookback`` code lines, with no SHALLOWER line in between (a
    /// shallower line means the walk has left the view expression the modifier belongs to). It errs
    /// towards FALSE NEGATIVES — a `Button` produced by a helper, a `NavigationLink`, a `Menu`, a
    /// `.onTapGesture` container (`HomeView.companionSection` is exactly that, and is correct as
    /// written), or reformatted source all read as "not a button" — because a false positive on a
    /// plain container is the shape that gets a wall switched off. On this tree it separated the
    /// four Button sites from the fifteen container sites with no misses in either direction.
    static func buttonHeadLine(_ lines: [SourceLine], at index: Int, before position: Int) -> Int? {
        guard index >= 0, index < lines.count, position >= 0 else { return nil }
        let code = lines[index].code
        if buttonHead.search(String(code.prefix(position))) != nil { return lines[index].number }
        let want = indentWidth(code)
        var step = index - 1
        for _ in 0..<a7Lookback {
            guard step >= 0 else { return nil }
            let here = indentWidth(lines[step].code)
            if here < want { return nil }
            if here == want, buttonHead.search(lines[step].code) != nil { return lines[step].number }
            step -= 1
        }
        return nil
    }

    /// **A7** — `.accessibilityElement(children: .ignore)` chained onto a `Button` (T2-29).
    ///
    /// `.ignore` on a control mints a SECOND, traitless accessibility element beside the real one:
    /// the button stops announcing as a button, VoiceOver stops offering "double tap to activate",
    /// and the Buttons rotor loses it. The correct fix is `.accessibilityLabel` alone — on a control
    /// the label already replaces the subtree's fragments, without minting anything.
    static func ignoreOnButtonFindings(_ path: String, _ lines: [SourceLine]) -> [Finding] {
        guard !path.isEmpty else { return [] }
        var findings: [Finding] = []
        for (index, line) in lines.enumerated() {
            guard let match = ignoreElement.search(line.code) else { continue }
            let start = matchStart(match, in: line.code)
            guard buttonHeadLine(lines, at: index, before: start) != nil else { continue }
            findings.append(Finding(rule: "A7-IGNORE-ON-BUTTON", path: path, line: line.number, text: line.raw))
        }
        return findings
    }
}

// MARK: - A3

extension AccessibilityBoundaryTests {

    /// Whether `body` ADDS `.isHeader`, rather than merely mentioning it.
    ///
    /// A bare `.isHeader` substring is not evidence: `.accessibilityRemoveTraits(.isHeader)`
    /// contains it and does the exact opposite, so the substring canary this replaces would have
    /// stayed green through the very regression it exists to catch (review finding #22). The trait
    /// must appear inside an `accessibilityAddTraits(` argument list.
    static func addsHeadingTrait(_ body: String) -> Bool {
        guard !body.isEmpty else { return false }
        let chars = Array(body)
        var position = 0
        for _ in 0..<addTraitsScanLimit {
            guard let found = offset(of: addTraitsCall, in: chars, from: position) else { return false }
            if callSpan(chars, from: found).contains(".isHeader") { return true }
            position = found + addTraitsCall.count
        }
        return false
    }

    /// **A3** — the named type in `source` must still ADD `.isHeader` inside its own braces.
    ///
    /// Scoped to the type's brace span rather than the whole file, so moving the trait onto a
    /// neighbouring view in the same file does not keep the canary green. Returns a finding when
    /// the trait is gone AND when the type itself is gone: a canary that cannot be found has not
    /// passed, it has stopped being asked.
    static func headingCanaryFindings(_ path: String, _ type: String, source: String) -> [Finding] {
        guard !type.isEmpty else { return [] }
        let lines = sourceLines(source)
        guard let start = lines.firstIndex(where: { structHead.match($0.code)?.group(1) == type }) else {
            return [Finding(rule: "A3-HEADING-CANARY", path: path, line: 0,
                            text: "\(type) no longer exists — the T1-1 canary cannot be asked")]
        }
        var depth = 0
        var body: [String] = []
        var end = lines[start].number
        for index in start..<lines.count {
            body.append(lines[index].code)
            depth += lines[index].code.filter { $0 == "{" }.count
            depth -= lines[index].code.filter { $0 == "}" }.count
            end = lines[index].number
            if depth <= 0 && index > start { break }
        }
        guard !addsHeadingTrait(body.joined(separator: " ")) else { return [] }
        return [Finding(rule: "A3-HEADING-CANARY", path: path, line: end,
                        text: "\(type) no longer ADDS .isHeader via accessibilityAddTraits(")]
    }
}

// MARK: - The tree scan

extension AccessibilityBoundaryTests {

    /// Every `.swift` file under the shipping roots, repo-relative.
    static func shippingFiles() -> [String] {
        var paths: [String] = []
        for root in shippingRoots {
            let base = RepoRoot.url.appendingPathComponent(root)
            guard let walker = FileManager.default.enumerator(atPath: base.path) else { continue }
            for case let entry as String in walker where entry.hasSuffix(".swift") {
                paths.append("\(root)/\(entry)")
            }
        }
        return paths.sorted()
    }

    /// Runs all seven rules over the shipping tree.
    static func scanTree() throws -> (findings: [Finding], filesScanned: Int) {
        var findings: [Finding] = []
        let paths = shippingFiles()
        for path in paths {
            let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
            let lines = sourceLines(source)
            findings += combineLabelFindings(path, lines)
            findings += spokenRawValueFindings(path, lines)
            findings += fontScaleFindings(path, lines)
            findings += gridScaleFindings(path, lines, source: source)
            findings += invertColorFindings(path, lines)
            findings += ignoreOnButtonFindings(path, lines)
        }
        // A3 asserts something EXISTS, so it runs off its own named paths rather than off the walk:
        // deleting the file must fail the canary, not quietly remove it from the scan.
        for (path, type) in headingCanaries {
            let source = try String(contentsOf: RepoRoot.url.appendingPathComponent(path), encoding: .utf8)
            findings += headingCanaryFindings(path, type, source: source)
        }
        return (findings, paths.count)
    }

    /// The allowlist, decoded from the JSON the Python scanner also reads.
    static func exemptions() throws -> [Exemption] {
        let url = RepoRoot.url.appendingPathComponent("Scripts/accessibility-allowlist.json")
        return try JSONDecoder().decode([Exemption].self, from: Data(contentsOf: url))
    }

    /// The wall itself: zero unexempted findings across the shipping tree.
    @Test func theShippingTreeHasNoUnexemptedAccessibilityViolations() throws {
        let (findings, filesScanned) = try Self.scanTree()
        let allowlist = try Self.exemptions()

        #expect(
            filesScanned >= Self.minimumFilesScanned,
            """
            Scanned only \(filesScanned) Swift files (floor \(Self.minimumFilesScanned)) — a \
            shipping root moved or the enumerator broke, and this wall is now passing without \
            looking at anything.
            """
        )

        let offenders = findings.filter { finding in !allowlist.contains { $0.covers(finding) } }
        #expect(
            offenders.isEmpty,
            """
            \(offenders.count) accessibility wall violation(s). Each fails SILENTLY at runtime — \
            the screen looks identical and only an assistive technology can tell — so this test is \
            the only thing that reports them. Fix each, or add an entry to \
            Scripts/accessibility-allowlist.json stating the invariant that makes it safe:
            \(offenders.map(\.report).sorted().joined(separator: "\n"))
            """
        )
    }

    /// Allowlist hygiene: an entry that matches nothing is a hole nobody is watching, and it would
    /// silently cover the next line that happens to contain its substring.
    @Test func everyAllowlistEntryStillMatchesSomething() throws {
        let (findings, _) = try Self.scanTree()
        let allowlist = try Self.exemptions()
        let stale = allowlist.filter { entry in !findings.contains { entry.covers($0) } }
        #expect(
            stale.isEmpty,
            """
            \(stale.count) allowlist entry(ies) match no finding any more — delete them:
            \(stale.map { "\($0.rule) \($0.path) \($0.lineContains ?? "<whole file>")" }.sorted().joined(separator: "\n"))
            """
        )
    }

    /// Every allowlist entry states an invariant, not an excuse.
    ///
    /// The one property a JSON schema cannot enforce and the house rule the other two walls both
    /// carry: a reader must be able to re-derive the decision from `reason` alone. A length floor
    /// is a crude proxy for that, but it does reliably catch "TODO", "legacy" and "see above".
    @Test func everyAllowlistEntryCarriesARealReason() throws {
        for entry in try Self.exemptions() {
            #expect(
                entry.reason.count >= 80,
                """
                \(entry.rule) \(entry.path): reason is \(entry.reason.count) characters — state the \
                invariant that makes this safe, not that it is allowed.
                """
            )
            #expect(!entry.path.isEmpty, "\(entry.rule): an allowlist entry with no path is tree-wide.")
        }
    }
}

// MARK: - Port equivalence: this file cannot drift from the scanner

extension AccessibilityBoundaryTests {

    /// The string elements of a Python tuple assignment `NAME = (…)`, single- or multi-line.
    static func pythonStringTuple(_ name: String, in source: String) -> [String] {
        guard let head = source.range(of: "\n\(name) = (") else { return [] }
        let rest = source[head.upperBound...]
        let candidates = [rest.range(of: ")\n")?.lowerBound, rest.range(of: "\n)")?.lowerBound]
        guard let close = candidates.compactMap({ $0 }).min() else { return [] }
        return Pattern(#""[^"]*""#).findAll(String(rest[..<close])).map { String($0.dropFirst().dropLast()) }
    }

    /// A top-level Python integer assignment `NAME = 12`.
    static func pythonInt(_ name: String, in source: String) -> Int? {
        guard let match = Pattern("(?m)^" + name + #"\s*=\s*([0-9]+)"#).search(source),
              let literal = match.group(1) else { return nil }
        return Int(literal)
    }

    /// Every shared constant matches the scanner's, name for name and value for value.
    ///
    /// This is the mechanism that closes review finding #10. Both halves read the same tree and the
    /// same allowlist, so a difference between them is not a disagreement anyone can see — it is a
    /// rule that fires locally and not in CI, or the reverse. Widening a window on one side now
    /// fails here until it is widened on the other.
    @Test func theSwiftPortAndThePythonScannerAgreeOnEveryBound() throws {
        let scanner = try RepoRoot.source(Self.scannerPath)
        #expect(Self.pythonStringTuple("SHIPPING_ROOTS", in: scanner) == Self.shippingRoots)
        #expect(Self.pythonStringTuple("SPOKEN_MODIFIERS", in: scanner) == Self.spokenModifiers)
        #expect(Self.pythonStringTuple("SPOKEN_PROPERTIES", in: scanner) == Self.spokenProperties)
        #expect(Self.pythonStringTuple("ANNOUNCEMENT_CALLS", in: scanner) == Self.announcementCalls)
        #expect(Self.pythonStringTuple("WRAPPERS", in: scanner) == Self.wrappers)
        #expect(Self.pythonStringTuple("HEADING_CANARIES", in: scanner)
                == Self.headingCanaries.flatMap { [$0.0, $0.1] })

        let bounds: [(String, Int)] = [
            ("A1_CALL_LINES", Self.a1CallLines), ("A1_CHAIN_STEPS", Self.a1ChainSteps),
            ("A2_WINDOW", Self.a2Window), ("A2_BODY_LINES", Self.a2BodyLines),
            ("A5_WINDOW", Self.a5Window), ("A5_DERIVATION_LINES", Self.a5DerivationLines),
            ("A5_DERIVATION_PASSES", Self.a5DerivationPasses), ("A6_WINDOW", Self.a6Window),
            ("A7_LOOKBACK", Self.a7Lookback), ("ADD_TRAITS_SCAN_LIMIT", Self.addTraitsScanLimit),
            ("WRAPPER_UNWRAPS", Self.wrapperUnwraps)
        ]
        for (name, value) in bounds {
            #expect(Self.pythonInt(name, in: scanner) == value,
                    "\(name) in \(Self.scannerPath) is not \(value) — the two halves now scan differently.")
        }
    }

    /// Every ported regex appears VERBATIM (Python syntax, piece by piece) in the scanner source.
    ///
    /// The A5 drift finding #10 named was exactly this: an exact substring here where the scanner
    /// carried a whitespace-tolerant regex. Editing a pattern on either side now fails until the
    /// other side is re-ported.
    @Test func portedPatternsAppearVerbatimInTheScanner() throws {
        let scanner = try RepoRoot.source(Self.scannerPath)
        var missing: [String] = []
        for pattern in Self.portedPatterns {
            for piece in pattern.pieces where !scanner.contains(piece) { missing.append(piece) }
        }
        for fragment in Self.assignmentFragments where !scanner.contains(fragment) { missing.append(fragment) }
        #expect(!Self.portedPatterns.isEmpty)
        #expect(missing.isEmpty, """
        Regex piece(s) no longer found verbatim in \(Self.scannerPath) — the scanner changed; \
        re-port and re-run the cross-check:
        \(missing.joined(separator: "\n"))
        """)
    }
}

// MARK: - Non-vacuity: planted fixtures

extension AccessibilityBoundaryTests {

    /// A1 fires on the pair, stays silent on `.combine` alone, and — the case that matters — stays
    /// silent when a comment sits between them but the pair is still adjacent in CODE.
    @Test func combineLabelRuleFiresOnlyOnTheAdjacentPair() {
        let planted = """
        VStack { Text("a") }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Planted")
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(planted)).count == 1)

        let combineOnly = """
        VStack { Text("a") }
            .accessibilityElement(children: .combine)
            .padding(4)
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(combineOnly)).isEmpty)

        // A comment between them is not a separator — the modifiers still chain, so the label
        // still replaces the fragments. Six sites in the tree are written exactly like this.
        let commented = """
        VStack { Text("a") }
            .accessibilityElement(children: .combine)
            // why the label says more:
            .accessibilityLabel("Planted")
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(commented)).count == 1)

        // `.contain` is the OPPOSITE construct — it keeps children individually focusable — so a
        // label beside it is not this defect.
        let contained = """
        VStack { Text("a") }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Planted")
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(contained)).isEmpty)
    }

    /// **E1–E4** — the four A1 evasions the 2026-08-23 adversarial review planted, all of which
    /// walked straight through the pre-hardening rule (it inspected one literal needle on
    /// `lines[i + 1]` and nothing else).
    @Test func combineLabelRuleCatchesAllFourPlantedEvasions() {
        let sameLine = #"Text("a").accessibilityElement(children: .combine).accessibilityLabel("E1")"#
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(sameLine)).count == 1,
                "E1: the whole pair on one line — `lines[i + 1]` never sees it")

        let noSpace = """
        Text("a")
            .accessibilityElement(children:.combine)
            .accessibilityLabel("E2")
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(noSpace)).count == 1,
                "E2: `children:.combine` is the same code as the spaced spelling")

        let interleaved = """
        Text("a")
            .accessibilityElement(children: .combine)
            .padding(4)
            .accessibilityLabel("E3")
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(interleaved)).count == 1,
                "E3: a label anywhere later in the chain replaces the gathered fragments")

        let wrappedCall = """
        Text("a")
            .accessibilityElement(
                children: .combine
            )
            .accessibilityLabel("E4")
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(wrappedCall)).count == 1,
                "E4: the `.combine` call itself wrapped across lines")
    }

    /// A2 fires on each spoken modifier, tolerates a wrapped argument list, and — the exemption
    /// that keeps the rule usable — never fires on `accessibilityIdentifier`.
    @Test func rawValueRuleFiresOnSpokenModifiersAndNeverOnIdentifiers() {
        for modifier in Self.spokenModifiers {
            let planted = ".\(modifier)(\"\\(state.rawValue)\")"
            #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(planted)).count == 1,
                    "\(modifier) must be treated as spoken")
        }

        let identifier = ".accessibilityIdentifier(\"workout.kind.\\(mode.rawValue)\")"
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(identifier)).isEmpty,
                "an identifier IS a frozen token — deriving it from a rawValue is correct")

        let wrapped = """
        Text("x")
            .accessibilityValue(
                Text(verbatim: companion.state.rawValue)
            )
        """
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(wrapped)).count == 1,
                "a wrapped argument list must not evade the rule")

        let clean = ".accessibilityLabel(Text(companion.state.displayName))"
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(clean)).isEmpty)
    }

    /// **E5–E7** — the A2 evasions that hide the rawValue behind a NAME or behind distance.
    @Test func rawValueRuleFollowsBindingsAndWideArgumentLists() {
        let localBinding = """
        let spoken = mode.rawValue
        return Text("a")
            .accessibilityLabel(spoken)
        """
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(localBinding)).count == 1,
                "E5: a one-line `let` is not a laundering service")

        let computed = """
        var spokenName: String { mode.rawValue }
        var body: some View {
            Text("a")
                .accessibilityValue(spokenName)
        }
        """
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(computed)).count == 1,
                "E6: nor is a computed property")

        let deeplyWrapped = """
        Text("a")
            .accessibilityHint(
                Text(
                    verbatim: String(
                        describing: Optional(
                            state.rawValue
                        )
                    )
                )
            )
        """
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(deeplyWrapped)).count == 1,
                "E7: five lines of wrapping is still one argument list")

        // The binding pass must not turn every identifier in the file into a suspect.
        let innocent = """
        let spoken = mode.displayName
        return Text("a")
            .accessibilityLabel(spoken)
        """
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(innocent)).isEmpty,
                "a binding that never touches .rawValue is not a defect")
    }

    /// **E8–E10** — the three A2 channels that carry no `.accessibilityLabel(` at all: a NAMED
    /// action, UIKit's property assignment, and the announcement post.
    @Test func rawValueRuleCoversActionsAssignmentsAndAnnouncements() {
        let namedAction = #".accessibilityAction(named: Text(verbatim: x.rawValue)) { }"#
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(namedAction)).count == 1,
                "E8: a named action is read out by the Actions rotor")

        let assignment = "label.accessibilityLabel = x.rawValue"
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(assignment)).count == 1,
                "E9: UIKit's assignment form has no call parentheses to match on")

        let swiftUIAnnouncement = "AccessibilityNotification.Announcement(x.rawValue).post()"
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(swiftUIAnnouncement)).count == 1,
                "E10a: the announcement channel is spoken and appears in no label")

        let uiKitAnnouncement = "UIAccessibility.post(notification: .announcement, argument: x.rawValue)"
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(uiKitAnnouncement)).count == 1,
                "E10b: same defect, UIKit spelling")

        // Comparison, not assignment: `==` must not read as the property form.
        let comparison = "if view.accessibilityLabel == mode.rawValue { return }"
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(comparison)).isEmpty,
                "reading a label back is not speaking one")
    }

    /// A3 fires when the trait is gone AND when the type is gone, and is scoped to the type's own
    /// braces so a neighbour's trait cannot satisfy it.
    @Test func headingCanaryFiresOnRemovalAndOnAbsence() {
        let good = """
        public struct SectionLabel: View {
            public var body: some View {
                text.accessibilityAddTraits(.isHeader)
            }
        }
        """
        #expect(Self.headingCanaryFindings("F.swift", "SectionLabel", source: good).isEmpty)

        let traitRemoved = """
        public struct SectionLabel: View {
            public var body: some View {
                text.textCase(.uppercase)
            }
        }
        """
        #expect(Self.headingCanaryFindings("F.swift", "SectionLabel", source: traitRemoved).count == 1)

        let typeGone = "public struct SomethingElse: View { public var body: some View { Text(\"x\") } }"
        #expect(Self.headingCanaryFindings("F.swift", "SectionLabel", source: typeGone).count == 1,
                "a canary that cannot be found has not passed — it has stopped being asked")

        // The trait on a NEIGHBOUR in the same file must not keep the canary green.
        let neighbourHasIt = """
        public struct SectionLabel: View {
            public var body: some View { text.textCase(.uppercase) }
        }
        public struct Neighbour: View {
            public var body: some View { Text("x").accessibilityAddTraits(.isHeader) }
        }
        """
        #expect(Self.headingCanaryFindings("F.swift", "SectionLabel", source: neighbourHasIt).count == 1)
    }

    /// Review finding #22: the canary greps the ADD-traits SHAPE, not the `.isHeader` substring.
    ///
    /// `accessibilityRemoveTraits(.isHeader)` contains `.isHeader` and does the exact opposite of
    /// what the canary asks. Under the old substring test this file passed while the Headings rotor
    /// went dark across all 124 headings — a green wall reporting the regression it exists to catch.
    @Test func headingCanaryIsNotSatisfiedByARemoveTraitsCall() {
        let removed = """
        public struct SectionLabel: View {
            public var body: some View {
                text.accessibilityRemoveTraits(.isHeader)
            }
        }
        """
        #expect(Self.headingCanaryFindings("F.swift", "SectionLabel", source: removed).count == 1,
                "removing the trait is not adding it, however similar the two lines look")
        #expect(!Self.addsHeadingTrait("x.accessibilityRemoveTraits(.isHeader)"))
        #expect(Self.addsHeadingTrait("x.accessibilityAddTraits(.isHeader)"))
        #expect(Self.addsHeadingTrait("x.accessibilityAddTraits([.isButton, .isHeader])"),
                "the trait inside a trait SET still adds it")
    }

    /// A4 fires on both non-scaling font forms and stays silent on the scaling one — and on the
    /// unrelated `.custom(label:group:)` factory that shares the method name.
    @Test func fontRuleFiresOnlyOnFontsThatCannotScale() {
        let unscaled = ".font(.custom(FernletFontName.dmSans, size: 12))"
        #expect(Self.fontScaleFindings("F.swift", Self.sourceLines(unscaled)).count == 1)

        let fixed = ".font(.custom(FernletFontName.dmSans, fixedSize: 12))"
        #expect(Self.fontScaleFindings("F.swift", Self.sourceLines(fixed)).count == 1)

        let scaled = ".font(.custom(FernletFontName.dmSans, size: 12, relativeTo: .caption))"
        #expect(Self.fontScaleFindings("F.swift", Self.sourceLines(scaled)).isEmpty)

        let notAFont = "tasks.append(PersonalCareTask.custom(label: trimmed, group: group))"
        #expect(Self.fontScaleFindings("F.swift", Self.sourceLines(notAFont)).isEmpty,
                "an unrelated .custom factory with no size: is not a font")
    }

    /// A5 fires on a literal minimum, on a named minimum in a file with no `@ScaledMetric`, and
    /// stays silent once the minimum is bound to one.
    @Test func gridRuleFiresOnMinimumsThatCannotGrow() {
        let literal = "LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)]) {"
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(literal), source: literal).count == 1)

        let namedButFixed = "LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum))]) {"
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(namedButFixed), source: namedButFixed).count == 1,
                "moving the constant into a `let` does not make it scale")

        let scaled = """
        @ScaledMetric(relativeTo: .body) private var tileMinimum: CGFloat = 120
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: tileMinimum))]) { EmptyView() }
        }
        """
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(scaled), source: scaled).isEmpty)

        // A literal stays a violation even in a file that declares a @ScaledMetric elsewhere —
        // the metric has to be the one bound to THIS minimum.
        let mixed = """
        @ScaledMetric(relativeTo: .body) private var other: CGFloat = 30
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120))]) { EmptyView() }
        }
        """
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(mixed), source: mixed).count == 1)
    }

    /// **E11–E14** — the four A5 evasions: a wrapped call, `.fixed(`, a laundered `@ScaledMetric`,
    /// and the one-space spelling that finding #10 showed this Swift half was blind to.
    @Test func gridRuleCatchesAllFourPlantedEvasions() {
        let wrappedCall = """
        LazyVGrid(columns: [
            GridItem(
                .adaptive(minimum: 80)
            )
        ]) { EmptyView() }
        """
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(wrappedCall), source: wrappedCall).count == 1,
                "E11: a wrapped GridItem( is still one call")

        let fixedColumn = "LazyVGrid(columns: [GridItem(.fixed(80))]) { EmptyView() }"
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(fixedColumn), source: fixedColumn).count == 1,
                "E12: .fixed( is the same defect with the reflow removed as well")

        let laundered = """
        @ScaledMetric(relativeTo: .body) private var unrelated: CGFloat = 44
        let spacingUnit: CGFloat = 80
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: spacingUnit))]) { EmptyView() }
        }
        """
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(laundered), source: laundered).count == 1,
                "E13: an unrelated metric elsewhere in the file exempts nothing")

        let oneSpace = "LazyVGrid(columns: [GridItem( .adaptive(minimum: 80))]) { EmptyView() }"
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(oneSpace), source: oneSpace).count == 1,
                "E14: finding #10 — the Swift half's exact substring could not see one space")

        // The derivation closure must still accept the shipping shape: a computed clamp over a metric.
        let derived = """
        @ScaledMetric(relativeTo: .title3) private var scaledItemTileMinimum: CGFloat = 150
        private var itemTileMinimum: CGFloat { min(scaledItemTileMinimum, 300) }
        var body: some View {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: itemTileMinimum))]) { EmptyView() }
        }
        """
        #expect(Self.gridScaleFindings("F.swift", Self.sourceLines(derived), source: derived).isEmpty,
                "a clamp over a @ScaledMetric still scales — FriendShopView and HomeView both write this")
    }

    /// A6 fires on an un-exempted bitmap and stays silent once the opt-out is in the chain.
    @Test func invertRuleFiresOnBitmapsThatSmartInvertWouldRuin() {
        let bare = """
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
        """
        #expect(Self.invertColorFindings("F.swift", Self.sourceLines(bare)).count == 1,
                "a user photograph rendered as a colour negative is the T2-10 defect")

        let exempt = """
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .accessibilityIgnoresInvertColors()
        """
        #expect(Self.invertColorFindings("F.swift", Self.sourceLines(exempt)).isEmpty)

        // A vector/SF Symbol image is NOT this rule: Smart Invert is supposed to invert UI chrome.
        let symbol = "Image(systemName: \"heart.fill\").foregroundStyle(Color.moss)"
        #expect(Self.invertColorFindings("F.swift", Self.sourceLines(symbol)).isEmpty)

        // Beyond the fixed window the opt-out no longer counts — the bound is real, not decorative.
        let distant = ([" Image(uiImage: image)"] + Array(repeating: "    .padding(1)", count: 14)
                       + ["    .accessibilityIgnoresInvertColors()"]).joined(separator: "\n")
        #expect(Self.invertColorFindings("F.swift", Self.sourceLines(distant)).count == 1)
    }

    /// A7 fires on `children: .ignore` chained onto a Button and stays silent on a plain container.
    ///
    /// The negative case is the one that matters: fifteen of the tree's nineteen `.ignore` sites are
    /// containers where `.ignore` is what CREATES the single element, and `HomeView`'s
    /// `companionSection` is a `.onTapGesture` view that supplies `.isButton` explicitly. A rule
    /// that flagged those would be asking for the wrong thing.
    @Test func ignoreOnButtonRuleSeparatesControlsFromContainers() {
        let onButton = """
        Button {
            act()
        } label: {
            VStack { Text("a") }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Do the thing")
        """
        #expect(Self.ignoreOnButtonFindings("F.swift", Self.sourceLines(onButton)).count == 1,
                "`.ignore` on a control mints a traitless twin beside it")

        let onContainer = """
        VStack { Text("a"); Text("b") }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Two things")
        """
        #expect(Self.ignoreOnButtonFindings("F.swift", Self.sourceLines(onContainer)).isEmpty,
                "on a container `.ignore` is what creates the element — the correct shape")

        let gestureView = """
        CompanionView(state: state)
            .onTapGesture { pet() }
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
        """
        #expect(Self.ignoreOnButtonFindings("F.swift", Self.sourceLines(gestureView)).isEmpty,
                "HomeView.companionSection's shape: not a Button, and the trait is added explicitly")

        let sameLine = #"Button("Go") { act() }.accessibilityElement(children: .ignore)"#
        #expect(Self.ignoreOnButtonFindings("F.swift", Self.sourceLines(sameLine)).count == 1,
                "the whole chain on one line is the same defect")
    }

    /// The tokenizer, which every rule above depends on: a forbidden shape written inside a
    /// comment or inside a user-facing string must not fire a rule. Without this, the wall's own
    /// documentation would fail it.
    @Test func rulesNeverFireOnCommentsOrStringContents() {
        let inComment = """
        // .accessibilityElement(children: .combine)
        // .accessibilityLabel("Planted")
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(inComment)).isEmpty)

        let inBlockComment = """
        /* .accessibilityElement(children: .combine)
           .accessibilityLabel("Planted") */
        """
        #expect(Self.combineLabelFindings("F.swift", Self.sourceLines(inBlockComment)).isEmpty)

        let inStringContent = "let help = \"pass .accessibilityLabel(x.rawValue) to name it\""
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(inStringContent)).isEmpty)

        let ignoreInComment = "// .accessibilityElement(children: .ignore) would break the Button"
        #expect(Self.ignoreOnButtonFindings("F.swift", Self.sourceLines(ignoreInComment)).isEmpty)
    }

    /// The tokenizer's sharpest edge, pinned on its own because getting it wrong is invisible: a
    /// literal's TEXT is erased but its `\(…)` INTERPOLATIONS are kept.
    ///
    /// Both walls' first drafts erased the whole literal, which silently exempted the exact shape
    /// rule A2 exists for — the app really did ship `.accessibilityLabel("Fernlet companion,
    /// \(state.rawValue)")`. The two assertions below are the same sentence with `.rawValue`
    /// inside the interpolation versus inside the prose, and they must disagree.
    @Test func literalTextIsErasedButInterpolationsAreKept() {
        let inInterpolation = #".accessibilityLabel("Fernlet companion, \(state.rawValue)")"#
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(inInterpolation)).count == 1,
                "an interpolated rawValue IS spoken — this is the shipping shape the review found")

        let inProse = #".accessibilityLabel("never write state.rawValue here")"#
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(inProse)).isEmpty,
                "the same words inside the literal's TEXT are copy, not code")

        let identifierInterpolation = #".accessibilityIdentifier("home.\(s.rawValue)")"#
        #expect(Self.spokenRawValueFindings("F.swift", Self.sourceLines(identifierInterpolation)).isEmpty,
                "an identifier built from a rawValue is the CORRECT thing to do — 12 sites do it")
    }
}
