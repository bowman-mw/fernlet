// PowerOfTenBoundaryTests.swift
// FernletTests
//
// The Swift grep-wall half of the Power-of-10 wall (Docs/Power-of-10-Swift.md), sibling of the S3
// wall (S3BoundaryTests) and the no-tracking wall (NoTrackingBoundaryTests).
//
// THE RULE: shipping Swift is held to Holzmann's Power of 10 — no unbounded loop, no function over
// one printed page, no silent trap, no mutable global, no swallowed error, no preprocessor games, no
// unsafe pointer outside a named seam, and warnings-as-errors everywhere. The rules a tokenizer can
// decide are enforced mechanically; the CANONICAL checker is Scripts/power-of-10-scan.py (CI runs it
// on every push, the pre-push hook runs it locally). This file is a faithful PORT of that scanner —
// same tokenizer, same body finder, same regexes, same allowlist contract — so that a regression also
// fails the ordinary test run, and so that neither tool can be quietly weakened without the other
// noticing: the constants and every ported regex are read back out of the scanner file and compared.
//
// Every scan DISCOVERS its inputs from the file system and carries a hard FLOOR, so a moved root or a
// broken enumerator fails loudly instead of passing vacuously over zero files (the S3BoundaryTests
// house rule). Every pure matcher is exercised by planted-token fixtures — one snippet that MUST trip
// it and a near-miss that MUST NOT — for the same reason.
//
// Advisory signals (R1-RECURSION, R2-WHILE, R7-DISCARD) are review lists, not enforcement, and are
// deliberately NOT ported. Test code is exempt from R4/R5/R7 (tests trap on purpose) but the R10 pins
// below cover every target.

import Foundation
import Testing

/// Grep-wall enforcing the mechanical half of the Power-of-10 rules over the four shipping roots,
/// as a line-for-line port of `Scripts/power-of-10-scan.py`.
///
/// Enforcement (one test per rule family, each listing every violation as `path:line: [symbol] text`):
/// - ``shippingRootsResolveAndClearTheFileFloor()`` — discovery floor (≥ 300 files, every root non-empty).
/// - ``r2NoLoopWithoutABound()`` — `R2-WHILE-TRUE`.
/// - ``r4NoBodyLongerThanSixtyCodeLines()`` — `R4-LENGTH`.
/// - ``r5NoSilentTrap()`` — `R5-FORCE` + `R5-TRAP`.
/// - ``r5AssertionDensityClearsTheFloor()`` — `R5-DENSITY`.
/// - ``r6NoMutableGlobal()`` — `R6-FILE-VAR` + `R6-STATIC-VAR`.
/// - ``r7NoSwallowedTry()`` — `R7-SWALLOW`.
/// - ``r8PreprocessorDiscipline()`` — `R8-IF-COND` + `R8-IF-NEST`.
/// - ``r9UnsafeOnlyAtAllowlistedSeams()`` — `R9-UNSAFE`.
/// - ``allowlistIsWellFormedAndFullyUsed()`` — the shared allowlist contract.
/// - ``constantsMatchTheCanonicalScanner()`` / ``portedPatternsAppearVerbatimInTheCanonicalScanner()`` — anti-drift.
/// - the `r10…` tests — rule 10 pins (project file, package manifest, wall script, CI, pre-push hook).
///
/// The scan runs ONCE per process (``sharedScan`` / ``sharedVerdict``) and every enforcement test reads
/// from it. Concurrency: every cached value is an immutable `static let` of `Sendable` value types.
struct PowerOfTenBoundaryTests {

    // MARK: - Scope, floors, and constants mirrored from the canonical scanner

    /// The five shipping roots — exactly the scanner's `SHIPPING_ROOTS`. Test targets are excluded on
    /// purpose (tests trap on purpose); ``constantsMatchTheCanonicalScanner()`` pins the two lists equal.
    ///
    /// `App/FernletMessagesExtension` was added on 2026-08-27. It had been missing since `a814ac4`
    /// shipped the target — an embedded, user-facing appex that this wall simply never looked at,
    /// the same omission that left it with no string catalog. It carried zero enforced violations
    /// when it was finally scanned, which is the point: nobody knew that, because nothing checked.
    static let shippingRoots = [
        "FernletKit/Sources", "App/Fernlet", "App/FernletWidgets", "App/FernletShareExtension",
        "App/FernletMessagesExtension",
    ]

    /// Floor for the shipping scan (366 files at the time of writing). Set below the real count so
    /// ordinary churn never trips it, but a root that stops resolving does.
    static let minimumShippingFilesScanned = 300

    /// NASA rule 4: one printed page. Mirrors the scanner's `MAX_BODY_LINES`.
    static let maxBodyLines = 60

    /// The R5 assertion-density ratchet. Mirrors the scanner's `DENSITY_FLOOR`; only ever raised.
    static let densityFloor = 0.68

    /// A body must have at least this many code lines to count in the density denominator. Mirrors the
    /// scanner's `DENSITY_MIN_LINES`.
    static let densityMinimumLines = 3

    /// Density is measured over LOGIC functions only — `func` / `init` / `deinit` / `subscript` bodies.
    /// Computed properties (SwiftUI `body`, view fragments) and closure initialisers are excluded: a
    /// view tree has nothing to guard, and splitting long bodies for R4 would otherwise dilute the
    /// ratio. Mirrors the scanner's `DENSITY_KINDS`.
    static let densityKinds = ["func", "init", "deinit", "subscript"]

    /// The only identifiers an `#if` condition may name. Mirrors the scanner's `ALLOWED_IF_TOKENS`.
    static let allowedIfTokens = ["DEBUG", "canImport", "os", "targetEnvironment", "swift", "compiler", "arch"]

    /// Signature-continuation prefixes: a pending head whose parentheses are balanced stays pending only
    /// while the next code line starts with one of these. Mirrors the scanner's `SIGNATURE_CONTINUATION`.
    static let signatureContinuation = ["{", "->", "where", "throws", "rethrows", "async", "reasync"]

    /// The enforced rule IDs. The port must emit nothing outside this set (advisory signals are not
    /// ported), which ``shippingRootsResolveAndClearTheFileFloor()`` asserts.
    static let enforcedRules = [
        "R2-WHILE-TRUE", "R4-LENGTH", "R5-FORCE", "R5-TRAP", "R6-FILE-VAR", "R6-STATIC-VAR",
        "R7-SWALLOW", "R8-IF-COND", "R8-IF-NEST", "R9-UNSAFE"
    ]

    /// Repo-relative path of the canonical checker this file ports.
    static let scannerPath = "Scripts/power-of-10-scan.py"

    /// Repo-relative path of the single allowlist BOTH tools read.
    static let allowlistPath = "Scripts/power-of-10-allowlist.json"

    /// Longest `text` an emitted finding carries (the scanner's `[:160]`, counted in code points).
    static let findingTextLimit = 160

    // MARK: - Records

    /// One mechanical finding: which rule, where, and the offending code (or the synthesized R4 note).
    ///
    /// `text` is the raw source line stripped and capped at ``findingTextLimit`` code points — the
    /// exact string the allowlist's `line_contains` narrows against.
    struct Finding: Hashable, Sendable {
        /// Rule ID, e.g. `R7-SWALLOW`.
        let rule: String
        /// Repo-relative path.
        let path: String
        /// 1-based line.
        let line: Int
        /// The matched token / function name / `#if` condition — what `symbol` in the allowlist matches.
        let symbol: String
        /// The stripped source line (or the R4 length note), capped at 160 code points.
        let text: String

        /// `path:line: [symbol] text` — the scanner's human-readable line, so failure output can be
        /// pasted straight into a search.
        var report: String { "\(path):\(line): [\(symbol)] \(text)" }
    }

    /// One reviewed exemption from `Scripts/power-of-10-allowlist.json`. `symbol` and `lineContains`
    /// are optional narrowings; an entry with neither covers every hit of `rule` in `path`.
    struct AllowlistEntry: Equatable, Sendable {
        /// Rule ID the entry excuses.
        let rule: String
        /// Repo-relative path the entry applies to.
        let path: String
        /// Optional narrowing: the finding's `symbol` must equal this.
        let symbol: String?
        /// Optional narrowing: the finding's `text` must contain this substring.
        let lineContains: String?
        /// The invariant that makes the exemption safe (never matched against; shown on failure).
        let reason: String

        /// The entry rendered as compact JSON for failure output.
        var report: String {
            var parts = ["\"rule\": \"\(rule)\"", "\"path\": \"\(path)\""]
            if let symbol { parts.append("\"symbol\": \"\(symbol)\"") }
            if let lineContains { parts.append("\"line_contains\": \"\(lineContains)\"") }
            parts.append("\"reason\": \"\(reason)\"")
            return "{" + parts.joined(separator: ", ") + "}"
        }
    }

    /// The parsed allowlist plus everything that went wrong parsing it. A missing or malformed file is
    /// reported (never silently treated as empty) by ``allowlistIsWellFormedAndFullyUsed()``.
    struct AllowlistLoad: Sendable {
        /// Well-formed entries in file order (order matters: the FIRST matching entry is the one used).
        let entries: [AllowlistEntry]
        /// Human-readable problems: unreadable file, not a JSON array, entries missing rule/path/reason.
        let problems: [String]
    }

    /// One function-like body located by the body finder: `func` / `init` / `deinit` / `subscript` /
    /// computed `var` / closure initialiser. Line numbers are 1-based; `codeLines` counts code lines
    /// strictly inside the braces.
    struct Body: Equatable, Sendable {
        /// Function name, `init`, `deinit`, `subscript`, or the property name.
        let name: String
        /// `func`, `init`, `deinit`, `subscript`, `var`, or `closure`.
        let kind: String
        /// 1-based line of the declaration head.
        let start: Int
        /// 1-based line of the opening brace.
        let open: Int
        /// 1-based line of the closing brace.
        let close: Int
        /// Code lines strictly inside the braces (blank and comment-only lines excluded).
        let codeLines: Int
    }

    /// A declaration head waiting for its body brace. Mirrors the scanner's `pending` dict.
    struct PendingHead: Equatable, Sendable {
        /// Symbol name.
        var name: String
        /// `func`, `init`, `deinit`, `subscript`, `var`, `var?` (needs a `{` on the next line), `closure`.
        var kind: String
        /// 0-based line of the head.
        var decl: Int
        /// Open-parenthesis balance of the signature so far.
        var paren: Int
        /// Whether the signature has opened a parenthesis (or needs none).
        var seenParen: Bool
    }

    /// Tokenizer state carried from one line to the next: block-comment nesting depth, whether the
    /// cursor is inside a multi-line string literal, and that literal's raw-string hash count.
    struct TokenizerState: Equatable, Sendable {
        /// Nesting depth of `/* */`.
        var blockDepth = 0
        /// Inside a `"""` literal.
        var inMultiLineString = false
        /// Hash count of the open multi-line raw string (`#"""` … `"""#`).
        var rawHashes = 0
    }

    /// One tokenized line: the code-only text (string literals collapsed to `""`, comments removed),
    /// its stripped form, and whether the line counts as a code line.
    struct TokenizedLine: Equatable, Sendable {
        /// Code-only text.
        let code: String
        /// `code` with Python-`str.strip()` whitespace removed from both ends.
        let stripped: String
        /// Whether the line counts as code (a payload line inside a multi-line string counts).
        let isCode: Bool
    }

    /// The per-file scan output: every hit plus the density inputs.
    struct FileScan: Sendable {
        /// Findings before the allowlist is applied.
        let hits: [Finding]
        /// Logic-function bodies (``densityKinds``) with at least ``densityMinimumLines`` code lines.
        let functions: Int
        /// `guard` statements + `assert`/`assertionFailure`/`precondition` calls inside those bodies.
        let checks: Int
    }

    /// The whole-tree scan over the shipping roots.
    struct TreeScan: Sendable {
        /// Swift files scanned.
        var files = 0
        /// Files per shipping root — each must be non-empty.
        var filesPerRoot: [String: Int] = [:]
        /// Every hit before the allowlist is applied.
        var hits: [Finding] = []
        /// Density denominator.
        var functions = 0
        /// Density numerator.
        var checks = 0
        /// Files that could not be read (a hard failure in every enforcement test).
        var unreadable: [String] = []

        /// `checks / functions`, or 0 when nothing was counted (which the floor test then fails).
        var density: Double { functions > 0 ? Double(checks) / Double(functions) : 0 }
    }

    /// The allowlist applied to the scan: what remains, what was excused, and which entries matched
    /// nothing (an unused entry is a failure — the list cannot rot).
    struct Verdict: Sendable {
        /// Hits not covered by any allowlist entry.
        let violations: [Finding]
        /// Hits excused by an entry.
        let allowedCount: Int
        /// Entries that matched no hit.
        let unused: [AllowlistEntry]
    }

    /// A compiled regular expression with Python-`re`-shaped entry points, so the port reads
    /// line-for-line against the scanner: ``match(_:)`` is anchored at the start (`re.match`),
    /// ``search(_:)`` matches anywhere (`re.search`), ``findAll(_:)`` is `re.findall`.
    ///
    /// The pattern is stored in the scanner's own (Python) syntax in `pieces` — one piece per source
    /// line of the scanner, so ``portedPatternsAppearVerbatimInTheCanonicalScanner()`` can assert each
    /// piece appears verbatim in the scanner file. The only translation to ICU is `(?P<` → `(?<`.
    ///
    /// `@unchecked Sendable`: `NSRegularExpression` is documented immutable and thread-safe; the wrapper
    /// exists so the compiled patterns can live in `static let`s.
    struct Pattern: @unchecked Sendable {
        /// The Python-syntax pattern, split exactly as the scanner's source splits it.
        let pieces: [String]
        /// The compiled ICU expression.
        let regex: NSRegularExpression

        /// Compiles `pieces` joined. Traps on an invalid pattern: every pattern is a compile-time
        /// constant exercised by the fixtures, so a failure here is a typo in this file, and a wall
        /// whose matcher cannot compile must stop the run rather than scan with a missing rule.
        init(_ pieces: [String]) {
            self.pieces = pieces
            let icu = pieces.joined().replacingOccurrences(of: "(?P<", with: "(?<")
            do {
                regex = try NSRegularExpression(pattern: icu)
            } catch {
                fatalError("PowerOfTenBoundaryTests: pattern does not compile — \(icu): \(error)")
            }
        }

        /// Convenience for a single-piece pattern.
        init(_ piece: String) { self.init([piece]) }

        /// `re.match`: a match anchored at the start of `text` (not necessarily reaching its end).
        func match(_ text: String) -> Match? {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let result = regex.firstMatch(in: text, options: [.anchored], range: range) else { return nil }
            return Match(result: result, source: text)
        }

        /// `re.search`: the leftmost match anywhere in `text`.
        func search(_ text: String) -> Match? {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            guard let result = regex.firstMatch(in: text, options: [], range: range) else { return nil }
            return Match(result: result, source: text)
        }

        /// `re.findall` for a pattern without capture groups: every non-overlapping match, in order.
        func findAll(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return regex.matches(in: text, options: [], range: range).compactMap { result in
                Range(result.range, in: text).map { String(text[$0]) }
            }
        }
    }

    /// One successful ``Pattern`` match with Python-`re`-shaped group accessors.
    struct Match {
        /// The underlying result.
        let result: NSTextCheckingResult
        /// The text that was matched against.
        let source: String

        /// `m.group(0)`.
        var text: String { group(0) ?? "" }

        /// `m.group(i)`; nil when the group did not participate.
        func group(_ index: Int) -> String? {
            guard index < result.numberOfRanges, let range = Range(result.range(at: index), in: source) else { return nil }
            return String(source[range])
        }

        /// `m.group("name")`; nil when the named group did not participate.
        func group(_ name: String) -> String? {
            let nsRange = result.range(withName: name)
            guard nsRange.location != NSNotFound, let range = Range(nsRange, in: source) else { return nil }
            return String(source[range])
        }
    }

    // MARK: - Patterns (Python syntax, split exactly as the scanner's source splits them)

    /// `DECL_HEAD_RE` — a func/init/deinit/subscript/computed-var declaration head.
    static let declHeadPattern = Pattern([
        #"^\s*(?:@\w[\w.]*(?:\([^)]*\))?\s+)*"#,
        #"(?:(?:public|open|internal|package|private|fileprivate|final|override|static|class|mutating|"#,
        #"nonmutating|nonisolated|convenience|required|dynamic|consuming|borrowing|indirect|distributed|"#,
        #"lazy|weak|unowned|optional|prefix|postfix|infix)\s+)*"#,
        #"(?:(?P<kind>func)\s+(?P<fname>[A-Za-z_]\w*|`[^`]+`|[-+*/%<>=!&|^~?.]+)"#,
        #"|(?P<init>init)\b[?!]?"#,
        #"|(?P<deinit>deinit)\b"#,
        #"|(?P<subscript>subscript)\b"#,
        #"|(?P<var>var)\s+(?P<vname>[A-Za-z_]\w*)\s*:[^{=]*?\{\s*$"#,
        #"|(?P<var2>var)\s+(?P<vname2>[A-Za-z_]\w*)\s*:[^{=]*$"#,
        #")"#
    ])

    /// `CLOSURE_ONLY_RE` — `let x = { … }` on one line: a closure literal that is NOT a body.
    static let closureOnlyPattern = Pattern(#"^\s*(?:let|var)\s+\w+\s*(?::[^=]*)?=\s*\{"#)

    /// `CLOSURE_DECL_RE` — `let table: [X] = {` at end of line: a closure initialiser, a function in disguise.
    static let closureDeclPattern = Pattern([
        #"^\s*(?:@\w[\w.]*(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|"#,
        #"package|static|lazy|final|nonisolated|nonisolated\(unsafe\))\s+)*(?:let|var)\s+"#,
        #"(?P<name>[A-Za-z_]\w*)\s*(?::[^=]*)?=\s*\{\s*$"#
    ])

    /// `FORCE_UNWRAP_RE` — postfix `!` on an identifier / `)` / `]` / `?`, not followed by `=`.
    static let forceUnwrapPattern = Pattern(#"(?<![!=<>&|(\[,\s{])[\w\)\]\?]!(?![=])"#)

    /// `IUO_RE` — an implicitly-unwrapped `T!` declaration.
    static let iuoPattern = Pattern(#"\b(?:var|let)\s+\w+\s*:\s*[A-Za-z_][\w<>.,\[\]: ]*?!\s*(?:=|$|,|\))"#)

    /// `TRY_BANG_RE`.
    static let tryBangPattern = Pattern(#"\btry!"#)

    /// `AS_BANG_RE`.
    static let asBangPattern = Pattern(#"\bas!"#)

    /// `TRAP_RE` — `fatalError(` / `preconditionFailure(`.
    static let trapPattern = Pattern(#"\b(?:fatalError|preconditionFailure)\s*\("#)

    /// `WHILE_TRUE_RE` — `while true {` (parenthesised or not, brace or end of line).
    static let whileTruePattern = Pattern(#"\bwhile\s*\(?\s*true\s*\)?\s*(?:\{|$)"#)

    /// The inline `repeat { … } while true` tail check.
    static let repeatWhileTruePattern = Pattern(#"\}\s*while\s*\(?\s*true\s*\)?\s*$"#)

    /// `SWALLOW_RE` — a bare-statement `try?` or `_ = try?`.
    static let swallowPattern = Pattern(#"^\s*(?:_\s*=\s*)?try\?\s"#)

    /// `UNSAFE_RE` — the unsafe surface.
    static let unsafePattern = Pattern([
        #"\bUnsafe(?:Mutable)?(?:Raw)?(?:Buffer)?Pointer\b|\bwithUnsafe\w*|\bunsafeBitCast\b|"#,
        #"\bUnmanaged\b|\bunowned\(unsafe\)|\bnonisolated\(unsafe\)|\bunsafeDowncast\b|"#,
        #"\bunsafelyUnwrapped\b|\bUnsafeContinuation\b|\bwithUnsafeContinuation\b"#
    ])

    /// `FILE_VAR_RE` — a `var` at column 0 (checked only at brace depth 0).
    static let fileVarPattern = Pattern(#"^(?:(?:public|private|fileprivate|internal|package|nonisolated\(unsafe\))\s+)*var\s+\w+"#)

    /// `STATIC_VAR_RE` — a `static var` declaration; the `rest` group decides stored vs computed.
    static let staticVarPattern = Pattern(#"^\s*(?:(?:public|private|fileprivate|internal|package|nonisolated\(unsafe\)|open|final|override|class)\s+)*static\s+var\s+(\w+)(?P<rest>.*)$"#)

    /// `IF_RE` — an `#if` line; group 1 is the condition.
    static let ifPattern = Pattern(#"^\s*#if\s+(.*)$"#)

    /// The inline `#endif` check.
    static let endifPattern = Pattern(#"^\s*#endif\b"#)

    /// `GUARD_RE` — a `guard` statement (density numerator).
    static let guardPattern = Pattern(#"^\s*guard\b"#)

    /// `ASSERT_RE` — `assert(` / `assertionFailure(` / `precondition(` (density numerator).
    static let assertPattern = Pattern(#"\b(?:assert|assertionFailure|precondition)\s*\("#)

    /// The identifier tokenizer for `#if` conditions.
    static let ifTokenPattern = Pattern(#"[A-Za-z_]\w*"#)

    /// Prefix of the "argument of an allowed function" check for `#if` tokens; the token is appended.
    static let ifAllowedArgumentPrefix = #"\b(?:canImport|os|targetEnvironment|swift|compiler|arch)\s*\(\s*"#

    /// Every ported pattern, for the verbatim anti-drift check.
    static let portedPatterns: [Pattern] = [
        declHeadPattern, closureOnlyPattern, closureDeclPattern, forceUnwrapPattern, iuoPattern,
        tryBangPattern, asBangPattern, trapPattern, whileTruePattern, repeatWhileTruePattern,
        swallowPattern, unsafePattern, fileVarPattern, staticVarPattern, ifPattern, endifPattern,
        guardPattern, assertPattern, ifTokenPattern, Pattern(ifAllowedArgumentPrefix)
    ]

    // MARK: - Shared scan (runs once per process)

    /// The whole-tree scan, computed once and shared by every enforcement test.
    static let sharedScan: TreeScan = scanShippingRoots(repoRoot: RepoRoot.url)

    /// The parsed allowlist, loaded once.
    static let sharedAllowlist: AllowlistLoad = loadAllowlist(at: RepoRoot.url(allowlistPath))

    /// The allowlist applied to the shared scan, once.
    static let sharedVerdict: Verdict = apply(sharedAllowlist.entries, to: sharedScan.hits)

    // MARK: - Enforcement

    /// Discovery floor: every shipping root resolves to at least one Swift file, the total clears the
    /// hard floor, and every file was readable. Without this the rule tests below could pass over
    /// nothing.
    @Test func shippingRootsResolveAndClearTheFileFloor() {
        let scan = Self.sharedScan
        for root in Self.shippingRoots {
            let count = scan.filesPerRoot[root] ?? 0
            #expect(count > 0, "Scanned zero Swift files under '\(root)' — the root moved and the Power-of-10 scan is silently narrower.")
        }
        #expect(
            scan.files >= Self.minimumShippingFilesScanned,
            "Scanned only \(scan.files) shipping Swift files (floor \(Self.minimumShippingFilesScanned)) — discovery is broken; the wall would pass vacuously."
        )
        #expect(scan.unreadable.isEmpty, "Unreadable Swift files: \(scan.unreadable) — every shipping file must be scanned.")
        // The port emits only the enforced rule IDs (advisory signals are deliberately not ported).
        let unknownRules = Set(scan.hits.map(\.rule)).subtracting(Self.enforcedRules).sorted()
        #expect(unknownRules.isEmpty, "The port emitted unknown rule ID(s) \(unknownRules).")
    }

    /// R2: no `while true` / `repeat … while true`. A loop that "breaks when done" hides its bound.
    @Test func r2NoLoopWithoutABound() {
        expectNoViolations(of: ["R2-WHILE-TRUE"], hint: "hoist the exit condition into the `while`, or count attempts against a named maximum (Docs/Power-of-10-Swift.md §R2)")
    }

    /// R4: no func/init/deinit/subscript/computed property/closure initialiser over 60 code lines.
    @Test func r4NoBodyLongerThanSixtyCodeLines() {
        expectNoViolations(of: ["R4-LENGTH"], hint: "split into named subviews / helpers; data-table-shaped code belongs in a `static let` (Docs/Power-of-10-Swift.md §R4)")
    }

    /// R5: no silent trap — no postfix `!`, `try!`, `as!`, IUO, `fatalError`, `preconditionFailure`.
    @Test func r5NoSilentTrap() {
        expectNoViolations(of: ["R5-FORCE", "R5-TRAP"], hint: "replace with `guard let … else { recover }`; a compile-time literal may be allowlisted with `line_contains` + a unit test that evaluates it (Docs/Power-of-10-Swift.md §R5)")
    }

    /// R5 density: `(guard + assert/assertionFailure/precondition) / logic functions with ≥ 3 code lines`
    /// (func / init / deinit / subscript — computed vars and closures excluded) over the shipping roots
    /// must not drop below the ratchet floor.
    @Test func r5AssertionDensityClearsTheFloor() {
        let scan = Self.sharedScan
        #expect(scan.unreadable.isEmpty, "Unreadable Swift files: \(scan.unreadable).")
        #expect(scan.functions > 0, "Counted zero logic-function bodies with ≥ \(Self.densityMinimumLines) code lines — the body finder is broken, not the code dense.")
        let value = (scan.density * 1000).rounded() / 1000
        #expect(
            scan.density >= Self.densityFloor,
            "R5-DENSITY: assertion density \(scan.checks)/\(scan.functions) = \(value) is BELOW the floor \(Self.densityFloor). Validate inputs with `guard` at entry and assert invariants (Docs/Power-of-10-Swift.md §R5). The floor is a ratchet: never lower it."
        )
    }

    /// R6: no file-scope `var`, no stored `static var` outside the allowlist.
    @Test func r6NoMutableGlobal() {
        expectNoViolations(of: ["R6-FILE-VAR", "R6-STATIC-VAR"], hint: "narrow the scope; a deliberate process-global registry is allowlisted with its concurrency story in the reason (Docs/Power-of-10-Swift.md §R6)")
    }

    /// R7: no swallowed `try?` — every error feeds a decision or is caught and named.
    @Test func r7NoSwallowedTry() {
        expectNoViolations(of: ["R7-SWALLOW"], hint: "feed the result into `guard let` / `if let` / `??`, or `do { } catch { log the recovery }` (Docs/Power-of-10-Swift.md §R7)")
    }

    /// R8: `#if` only over the allowed conditions, never nested.
    @Test func r8PreprocessorDiscipline() {
        expectNoViolations(of: ["R8-IF-COND", "R8-IF-NEST"], hint: "allowed: DEBUG, canImport, os, targetEnvironment, swift, compiler, arch; flatten nested `#if`s (Docs/Power-of-10-Swift.md §R8)")
    }

    /// R9: no unsafe pointer / bit cast / `Unmanaged` / `unowned(unsafe)` / `nonisolated(unsafe)`
    /// outside a per-file allowlisted seam whose reason names the invariant.
    @Test func r9UnsafeOnlyAtAllowlistedSeams() {
        expectNoViolations(of: ["R9-UNSAFE"], hint: "prefer Data / ContiguousBytes / real actor isolation; a bridging seam is allowlisted per FILE with the invariant in the reason (Docs/Power-of-10-Swift.md §R9)")
    }

    /// The allowlist contract, shared with the scanner: the file exists and is a JSON array; every entry
    /// carries `rule`, `path`, `reason`; and every entry matched at least one hit (a stale entry is a
    /// failure, so the list cannot rot).
    @Test func allowlistIsWellFormedAndFullyUsed() {
        let load = Self.sharedAllowlist
        #expect(load.problems.isEmpty, "\(Self.allowlistPath): \(load.problems.joined(separator: "; "))")
        let unused = Self.sharedVerdict.unused
        if !unused.isEmpty {
            Issue.record("UNUSED ALLOWLIST ENTRY (matches nothing — remove it or fix its rule/path/symbol/line_contains):\n\(unused.map(\.report).joined(separator: "\n"))")
        }
    }

    /// The Swift constants equal the scanner's: `DENSITY_FLOOR`, `MAX_BODY_LINES`, `DENSITY_MIN_LINES`,
    /// `SHIPPING_ROOTS`, `ALLOWED_IF_TOKENS` are read out of the scanner file by regex so the two tools
    /// cannot drift on a number or a root.
    @Test func constantsMatchTheCanonicalScanner() throws {
        let scanner = try RepoRoot.source(Self.scannerPath)

        #expect(Self.pythonNumber("DENSITY_FLOOR", in: scanner) == Self.densityFloor, "DENSITY_FLOOR in \(Self.scannerPath) differs from densityFloor here (\(Self.densityFloor)).")
        #expect(Self.pythonNumber("MAX_BODY_LINES", in: scanner) == Double(Self.maxBodyLines), "MAX_BODY_LINES in \(Self.scannerPath) differs from maxBodyLines here (\(Self.maxBodyLines)).")
        #expect(Self.pythonNumber("DENSITY_MIN_LINES", in: scanner) == Double(Self.densityMinimumLines), "DENSITY_MIN_LINES in \(Self.scannerPath) differs from densityMinimumLines here (\(Self.densityMinimumLines)).")
        #expect(Self.pythonStringTuple("SHIPPING_ROOTS", in: scanner) == Self.shippingRoots, "SHIPPING_ROOTS in \(Self.scannerPath) differs from shippingRoots here.")
        #expect(Self.pythonStringTuple("ALLOWED_IF_TOKENS", in: scanner) == Self.allowedIfTokens, "ALLOWED_IF_TOKENS in \(Self.scannerPath) differs from allowedIfTokens here.")
        #expect(Self.pythonStringTuple("SIGNATURE_CONTINUATION", in: scanner) == Self.signatureContinuation, "SIGNATURE_CONTINUATION in \(Self.scannerPath) differs from signatureContinuation here.")
        #expect(Self.pythonStringTuple("DENSITY_KINDS", in: scanner) == Self.densityKinds, "DENSITY_KINDS in \(Self.scannerPath) differs from densityKinds here.")
    }

    /// Every ported regex appears VERBATIM (Python syntax, piece by piece) in the scanner source. Editing
    /// a regex in the scanner therefore fails here until the port is re-verified — the port cannot
    /// silently fall behind the canonical checker.
    @Test func portedPatternsAppearVerbatimInTheCanonicalScanner() throws {
        let scanner = try RepoRoot.source(Self.scannerPath)
        var missing: [String] = []
        for pattern in Self.portedPatterns {
            for piece in pattern.pieces where !scanner.contains(piece) {
                missing.append(piece)
            }
        }
        #expect(!Self.portedPatterns.isEmpty)
        if !missing.isEmpty {
            Issue.record("Regex piece(s) no longer found verbatim in \(Self.scannerPath) — the scanner changed; re-port and re-run the cross-check:\n\(missing.joined(separator: "\n"))")
        }
    }

    // MARK: - Rule 10 pins

    /// R10: `App/Fernlet.xcodeproj` treats warnings as errors — both flags present at least twice
    /// (project-level Debug + Release) and never switched back to `NO` on any configuration.
    @Test func r10ProjectFileTreatsWarningsAsErrors() throws {
        let path = "App/Fernlet.xcodeproj/project.pbxproj"
        let pbxproj = try RepoRoot.source(path)
        for flag in ["SWIFT_TREAT_WARNINGS_AS_ERRORS", "GCC_TREAT_WARNINGS_AS_ERRORS"] {
            let yes = Self.occurrences(of: "\(flag) = YES;", in: pbxproj)
            #expect(yes >= 2, "\(path): '\(flag) = YES;' appears \(yes) time(s), expected ≥ 2 (project-level Debug + Release). Warnings are errors on every target (Docs/Power-of-10-Swift.md §R10).")
            #expect(!pbxproj.contains("\(flag) = NO;"), "\(path): '\(flag) = NO;' switches warnings-as-errors OFF for some configuration — rule 10 has no exemptions.")
        }
    }

    /// R10: `FernletKit/Package.swift` must NOT carry `.treatAllWarnings(as:)` / `-warnings-as-errors`.
    /// Xcode passes `-suppress-warnings` to every local-package target, and swiftc rejects the pair as
    /// "conflicting options" — verified 2026-08-16: the whole Xcode build fails. The package gets
    /// warnings-as-errors from the strict build COMMAND instead (``r10WallCheckScriptBuildsStrict()``),
    /// so a manifest flag here would only ever break the build (Docs/Power-of-10-Swift.md §R10).
    @Test func r10PackageManifestDoesNotCarryTheConflictingWarningsFlag() throws {
        let path = "FernletKit/Package.swift"
        let code = Self.nonCommentLines(try RepoRoot.source(path), commentPrefix: "//")
        for token in [".treatAllWarnings(", "-warnings-as-errors"] {
            #expect(
                !code.contains { $0.contains(token) },
                "\(path) contains `\(token)` — it conflicts with the `-suppress-warnings` Xcode passes to local-package targets and breaks the build; rule 10 for the package is enforced on the strict build command (Docs/Power-of-10-Swift.md §R10)."
            )
        }
    }

    /// R10: `Scripts/spm-wall-check.sh` builds strict — package warnings un-suppressed and both
    /// warnings-as-errors flags on the build command (on non-comment lines).
    @Test func r10WallCheckScriptBuildsStrict() throws {
        let path = "Scripts/spm-wall-check.sh"
        let code = Self.nonCommentLines(try RepoRoot.source(path), commentPrefix: "#")
        for flag in ["SUPPRESS_WARNINGS=NO", "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES", "GCC_TREAT_WARNINGS_AS_ERRORS=YES"] {
            #expect(
                code.contains { $0.contains(flag) },
                "\(path) no longer passes \(flag) on the xcodebuild command — the S3 wall build is also the rule-10 build; every warning, including hidden local-package warnings, must fail it (Docs/Power-of-10-Swift.md §R10)."
            )
        }
    }

    /// R10: the scanner runs on every push — a dedicated CI workflow invokes it, and so does the
    /// committed pre-push hook (both on non-comment lines).
    @Test func r10ScannerRunsInCIAndOnPrePush() throws {
        let workflowPath = ".github/workflows/power-of-10.yml"
        let workflowURL = RepoRoot.url(workflowPath)
        #expect(FileManager.default.fileExists(atPath: workflowURL.path), "\(workflowPath) is missing — the Power-of-10 scanner must run in CI on every push (Docs/Power-of-10-Swift.md §R10).")
        if let workflow = try? String(contentsOf: workflowURL, encoding: .utf8) {
            let code = Self.nonCommentLines(workflow, commentPrefix: "#")
            #expect(code.contains { $0.contains("power-of-10-scan.py") }, "\(workflowPath) does not invoke Scripts/power-of-10-scan.py on a non-comment line.")
        }

        let hookPath = "Scripts/git-hooks/pre-push"
        let hook = Self.nonCommentLines(try RepoRoot.source(hookPath), commentPrefix: "#")
        #expect(hook.contains { $0.contains("power-of-10-scan.py") }, "\(hookPath) no longer invokes power-of-10-scan.py — the hook is the always-available complement to CI.")
    }

    // MARK: - Fixtures: the tokenizer

    /// Fixture: the tokenizer collapses string literals to `""` (so a `//` or `!` inside a string is not
    /// code), removes line and block comments, tracks multi-line strings and raw strings, and counts
    /// a multi-line-string payload line as a code line that carries no tokens.
    @Test func tokenizerStripsCommentsAndStringsButKeepsCodeLines() {
        let lines = Self.tokenize(Self.lines(of: #"""
        let a = "// not a comment"; foo!   // trailing comment
        /* block
           still block */ let b = 1
        let c = #"raw " quote"#
        let d = "\(x!) interpolated"
        let e = """
            payload with foo! and while true {
            """
        let f = ##"raw #" text"##
        // whole-line comment
        """#))
        #expect(lines.count == 10)
        #expect(lines[0].code == "let a = \"\"; foo!   ")
        #expect(lines[0].isCode)
        #expect(lines[1].isCode == false, "a block-comment-only line is not code")
        #expect(lines[2].code == " let b = 1")
        #expect(lines[3].code == "let c = \"\"")
        #expect(lines[4].code == "let d = \"\"", "an interpolation is part of the literal")
        #expect(lines[5].code == "let e = \"\"")
        #expect(lines[6].code == "" && lines[6].isCode, "a multi-line-string payload line is a token-free code line")
        #expect(lines[7].code == "" && lines[7].isCode == false, "the closing \"\"\" line carries no code")
        #expect(lines[8].code == "let f = \"\"")
        #expect(lines[9].isCode == false)
        // The `!` and `while true` inside the string literal are invisible to every rule.
        let scan = Self.scanSnippet(lines: Self.lines(of: "let e = \"\"\"\n    payload with foo! and while true {\n    \"\"\""))
        #expect(scan.hits.isEmpty, "tokens inside a multi-line string were treated as code: \(scan.hits.map(\.report))")
    }

    // MARK: - Fixtures: the body finder

    /// Fixture: the body finder locates func / init / deinit / subscript / computed var / closure
    /// initialiser bodies, opens the body at the first `{` reached with the signature's parentheses
    /// balanced (a default-value closure in the parameter list does not start it early), needs a `{` on
    /// the NEXT line for a bare `var x: T`, and drops protocol requirements and stored properties.
    @Test func bodyFinderLocatesFunctionLikeBodiesOnly() {
        let bodies = Self.findBodies(Self.tokenize(Self.lines(of: """
        struct S {
            func f(handler: () -> Void = { },
                   count: Int) -> Int
            {
                let x = 1
                return x + count
            }
            required init?(coder: NSCoder) {
                nil
            }
            deinit {
                cleanUp()
            }
            subscript(i: Int) -> Int {
                i
            }
            var body: some View {
                Text("hi")
            }
            var lazyBody: Int
            {
                42
            }
            var stored: Int
            var stored2: Int = 5
            let table: [Int] = {
                [1, 2, 3]
            }()
            let oneLiner = { print("x") }
        }
        protocol P {
            func requirement()
            var requirementVar: Int { get }
        }
        """)))
        let byName = Dictionary(uniqueKeysWithValues: bodies.map { ($0.name, $0) })
        #expect(byName["f"] == Body(name: "f", kind: "func", start: 2, open: 4, close: 7, codeLines: 2))
        #expect(byName["init"] == Body(name: "init", kind: "init", start: 8, open: 8, close: 10, codeLines: 1))
        #expect(byName["deinit"] == Body(name: "deinit", kind: "deinit", start: 11, open: 11, close: 13, codeLines: 1))
        #expect(byName["subscript"] == Body(name: "subscript", kind: "subscript", start: 14, open: 14, close: 16, codeLines: 1))
        #expect(byName["body"] == Body(name: "body", kind: "var", start: 17, open: 17, close: 19, codeLines: 1))
        #expect(byName["lazyBody"] == Body(name: "lazyBody", kind: "var", start: 20, open: 21, close: 23, codeLines: 1))
        #expect(byName["table"] == Body(name: "table", kind: "closure", start: 26, open: 26, close: 28, codeLines: 1))
        #expect(byName["stored"] == nil && byName["stored2"] == nil, "stored properties are not bodies")
        #expect(byName["oneLiner"] == nil, "a one-line closure literal is not a body")
        #expect(byName["requirement"] == nil && byName["requirementVar"] == nil, "protocol requirements are not bodies")
        #expect(bodies.count == 7, "found \(bodies.map(\.name))")
    }

    // MARK: - Fixtures: one planted violation and one near-miss per matcher

    /// Fixture R2: `while true` (bare, parenthesised, `repeat … while true`) trips; a bounded `while` and
    /// an identifier that merely starts with `true` do not.
    @Test func r2MatcherFlagsPlantedWhileTrueOnly() {
        #expect(Self.lines("R2-WHILE-TRUE", in: "while true {\n    step()\n}") == [1])
        #expect(Self.lines("R2-WHILE-TRUE", in: "while (true) {\n}") == [1])
        #expect(Self.lines("R2-WHILE-TRUE", in: "repeat {\n    step()\n} while true") == [3])
        #expect(Self.lines("R2-WHILE-TRUE", in: "while attempt < Self.maxAttempts {\n    attempt += 1\n}").isEmpty)
        #expect(Self.lines("R2-WHILE-TRUE", in: "while trueish {\n}").isEmpty)
        #expect(Self.lines("R2-WHILE-TRUE", in: "while let next = iterator.next() {\n}").isEmpty)
    }

    /// Fixture R4: a body with 61 code lines trips; the same body padded with 60 comment lines and 60
    /// blank lines does not, and a body of exactly 60 code lines does not.
    @Test func r4MatcherCountsCodeLinesOnly() {
        let sixtyOne = "func f() {\n" + Array(repeating: "    x += 1", count: 61).joined(separator: "\n") + "\n}"
        let hits = Self.hits("R4-LENGTH", in: sixtyOne)
        #expect(hits.map(\.line) == [1] && hits.first?.symbol == "f")
        #expect(hits.first?.text == "func f: 61 code lines (max 60)")

        let sixty = "func f() {\n" + Array(repeating: "    x += 1", count: 60).joined(separator: "\n") + "\n}"
        #expect(Self.hits("R4-LENGTH", in: sixty).isEmpty)

        let padded = "func f() {\n"
            + Array(repeating: "    // commentary", count: 60).joined(separator: "\n") + "\n"
            + Array(repeating: "", count: 60).joined(separator: "\n") + "\n"
            + Array(repeating: "    x += 1", count: 60).joined(separator: "\n") + "\n}"
        #expect(Self.hits("R4-LENGTH", in: padded).isEmpty, "comment-only and blank lines must not count")

        let computed = "var body: some View {\n" + Array(repeating: "    Text(\"x\")", count: 61).joined(separator: "\n") + "\n}"
        #expect(Self.hits("R4-LENGTH", in: computed).map(\.symbol) == ["body"], "SwiftUI bodies are functions too")
    }

    /// Fixture R5-FORCE: postfix `!`, `try!`, `as!`, and an IUO declaration trip; `!=`, prefix `!`, and a
    /// `!` inside a string literal do not.
    @Test func r5ForceMatcherFlagsPlantedTrapsOnly() {
        #expect(Self.symbols("R5-FORCE", in: "let v = dict[key]!.value") == ["!"])
        #expect(Self.symbols("R5-FORCE", in: "let v = try! decode(data)").contains("try!"))
        #expect(Self.symbols("R5-FORCE", in: "let v = layer as! CALayer").contains("as!"))
        #expect(Self.symbols("R5-FORCE", in: "var label: UILabel!") == ["IUO"])
        #expect(Self.symbols("R5-FORCE", in: "let ok = a != b").isEmpty)
        #expect(Self.symbols("R5-FORCE", in: "guard !flag else { return }").isEmpty)
        #expect(Self.symbols("R5-FORCE", in: "if x !== y {").isEmpty)
        #expect(Self.symbols("R5-FORCE", in: #"let s = "wow!""#).isEmpty)
        #expect(Self.symbols("R5-FORCE", in: "// force!").isEmpty)
    }

    /// Fixture R5-TRAP: `fatalError(` / `preconditionFailure(` trip with the call name as symbol; a
    /// longer identifier and a plain `precondition(` (an assertion, not a trap) do not.
    @Test func r5TrapMatcherFlagsPlantedTrapsOnly() {
        #expect(Self.symbols("R5-TRAP", in: #"fatalError("unreachable")"#) == ["fatalError"])
        #expect(Self.symbols("R5-TRAP", in: "preconditionFailure()") == ["preconditionFailure"])
        #expect(Self.symbols("R5-TRAP", in: "fatalErrorHandler()").isEmpty)
        #expect(Self.symbols("R5-TRAP", in: "precondition(x > 0)").isEmpty)
    }

    /// Fixture R5-DENSITY: `guard` and `assert`/`assertionFailure`/`precondition` inside logic-function
    /// bodies with ≥ 3 code lines count; a 2-line body, a computed property, and a closure initialiser
    /// do not enter the denominator (nor contribute checks).
    @Test func r5DensityCountsGuardsAndAssertsInLogicFunctionsOfThreeOrMoreLines() {
        let scan = Self.scanSnippet(lines: Self.lines(of: """
        func a(x: Int?) -> Int {
            guard let x else { return 0 }
            precondition(x >= 0)
            assert(x < 100, "small")
            return x
        }
        func b() {
            step()
            step()
            step()
        }
        func tiny() {
            guard ok else { return }
        }
        var body: some View {
            guard ok else { return EmptyView() }
            assert(ready)
            return Text("x")
        }
        let table: [Int] = {
            guard ok else { return [] }
            precondition(ready)
            return [1]
        }()
        init(x: Int) {
            guard x > 0 else { return nil }
            self.x = x
            ready = true
        }
        """))
        #expect(scan.functions == 3, "func a, func b, init — not the 1-line `tiny`, not the computed var, not the closure")
        #expect(scan.checks == 4, "guard + precondition + assert in `a`, guard in `init`; nothing from `body` or `table`")
    }

    /// Fixture R6-FILE-VAR: a `var` at file scope trips; `let`, and a `var` inside a type body, do not.
    @Test func r6FileVarMatcherFlagsPlantedGlobalsOnly() {
        #expect(Self.lines("R6-FILE-VAR", in: "var counter = 0") == [1])
        #expect(Self.lines("R6-FILE-VAR", in: "private var cache: [String: Int] = [:]") == [1])
        #expect(Self.lines("R6-FILE-VAR", in: "let constant = 0").isEmpty)
        #expect(Self.lines("R6-FILE-VAR", in: "struct S {\n    var member = 0\n}").isEmpty)
        #expect(Self.lines("R6-FILE-VAR", in: "enum E {\n}\nvar afterType = 1") == [3])
    }

    /// Fixture R6-STATIC-VAR: a STORED `static var` trips (with or without an initial value, even with a
    /// `didSet`); a computed `static var` does not, and neither does a `static let`.
    @Test func r6StaticVarMatcherFlagsStoredStaticsOnly() {
        #expect(Self.symbols("R6-STATIC-VAR", in: "    static var shared = Registry()") == ["shared"])
        #expect(Self.symbols("R6-STATIC-VAR", in: "    public static var handler: Handler?") == ["handler"])
        #expect(Self.symbols("R6-STATIC-VAR", in: "    nonisolated(unsafe) private static var didRun = false") == ["didRun"])
        #expect(Self.symbols("R6-STATIC-VAR", in: "    static var count: Int = 0 { didSet { log() } }") == ["count"])
        #expect(Self.symbols("R6-STATIC-VAR", in: "    static var current: Int { compute() }").isEmpty)
        #expect(Self.symbols("R6-STATIC-VAR", in: "    static var isReady: Bool {").isEmpty)
        #expect(Self.symbols("R6-STATIC-VAR", in: "    static let shared = Registry()").isEmpty)
    }

    /// Fixture R7-SWALLOW: a bare `try?` statement and `_ = try?` trip; a `try?` feeding `guard let`,
    /// `if let`, an assignment, `??`, or `return` does not.
    @Test func r7SwallowMatcherFlagsPlantedSwallowsOnly() {
        #expect(Self.lines("R7-SWALLOW", in: "try? FileManager.default.removeItem(at: url)") == [1])
        #expect(Self.lines("R7-SWALLOW", in: "_ = try? store.save()") == [1])
        #expect(Self.lines("R7-SWALLOW", in: "guard let data = try? Data(contentsOf: url) else { return }").isEmpty)
        #expect(Self.lines("R7-SWALLOW", in: "if let value = try? decode() {").isEmpty)
        #expect(Self.lines("R7-SWALLOW", in: "let value = try? decode()").isEmpty)
        #expect(Self.lines("R7-SWALLOW", in: "return try? decode()").isEmpty)
        #expect(Self.lines("R7-SWALLOW", in: "let value = (try? decode()) ?? fallback").isEmpty)
    }

    /// Fixture R8-IF-COND / R8-IF-NEST: a custom compilation condition trips COND with the condition as
    /// symbol; a nested `#if` trips NEST only; the allowed conditions — negated, combined, with
    /// arguments — trip nothing, and an `#if` after an `#endif` is not nested.
    @Test func r8MatchersFlagPlantedConditionsAndNestingOnly() {
        #expect(Self.symbols("R8-IF-COND", in: "#if FEATURE_FLAG\n#endif") == ["FEATURE_FLAG"])
        #expect(Self.symbols("R8-IF-COND", in: "#if os(iOS) || MY_FLAG\n#endif") == ["os(iOS) || MY_FLAG"])
        #expect(Self.symbols("R8-IF-COND", in: "#if DEBUG\n#endif").isEmpty)
        #expect(Self.symbols("R8-IF-COND", in: "#if canImport(UIKit) && !os(watchOS)\n#endif").isEmpty)
        #expect(Self.symbols("R8-IF-COND", in: "#if targetEnvironment(simulator)\n#endif").isEmpty)
        #expect(Self.symbols("R8-IF-COND", in: "#if swift(>=5.9) && compiler(>=6.0) && arch(arm64)\n#endif").isEmpty)
        #expect(Self.symbols("R8-IF-COND", in: "#if DEBUG // why\n#endif").isEmpty, "a trailing comment is not part of the condition")

        let nested = "#if os(iOS)\n#if DEBUG\nprint()\n#endif\n#endif\n#if DEBUG\n#endif"
        #expect(Self.lines("R8-IF-NEST", in: nested) == [2])
        #expect(Self.symbols("R8-IF-COND", in: nested).isEmpty, "a nested ALLOWED condition trips only R8-IF-NEST")
        #expect(Self.lines("R8-IF-NEST", in: "#if DEBUG\n#endif\n#if os(iOS)\n#endif").isEmpty)
    }

    /// Fixture R9-UNSAFE: the unsafe surface trips with the matched token as symbol; look-alike
    /// identifiers and safe `unowned` / `nonisolated` do not.
    @Test func r9MatcherFlagsPlantedUnsafeSeamsOnly() {
        #expect(Self.symbols("R9-UNSAFE", in: "let p = UnsafeMutableRawPointer.allocate(byteCount: 8, alignment: 8)") == ["UnsafeMutableRawPointer"])
        #expect(Self.symbols("R9-UNSAFE", in: "data.withUnsafeBytes { buffer in }") == ["withUnsafeBytes"])
        #expect(Self.symbols("R9-UNSAFE", in: "let y = unsafeBitCast(x, to: Int.self)") == ["unsafeBitCast"])
        #expect(Self.symbols("R9-UNSAFE", in: "let u = Unmanaged.passUnretained(self)") == ["Unmanaged"])
        #expect(Self.symbols("R9-UNSAFE", in: "unowned(unsafe) let owner: Owner") == ["unowned(unsafe)"])
        #expect(Self.symbols("R9-UNSAFE", in: "nonisolated(unsafe) static var cache: Data?") == ["nonisolated(unsafe)"])
        #expect(Self.symbols("R9-UNSAFE", in: "let v = optional.unsafelyUnwrapped") == ["unsafelyUnwrapped"])
        #expect(Self.symbols("R9-UNSAFE", in: "struct UnsafePointerLike {}").isEmpty)
        #expect(Self.symbols("R9-UNSAFE", in: "unowned let owner: Owner").isEmpty)
        #expect(Self.symbols("R9-UNSAFE", in: "nonisolated let id: Int").isEmpty)
        #expect(Self.symbols("R9-UNSAFE", in: "let isUnsafe = false").isEmpty)
    }

    /// Fixture: the allowlist matcher honours rule + path, the optional `symbol` and `line_contains`
    /// narrowings, marks only the FIRST matching entry as used, and reports the rest as unused.
    @Test func allowlistMatcherNarrowsByRulePathSymbolAndLine() {
        let hit = Finding(rule: "R5-FORCE", path: "App/Fernlet/A.swift", line: 3, symbol: "!", text: #"let id = UUID(uuidString: "0000")!"#)
        let other = Finding(rule: "R9-UNSAFE", path: "App/Fernlet/B.swift", line: 9, symbol: "Unmanaged", text: "Unmanaged.passUnretained(self)")
        let entries = [
            AllowlistEntry(rule: "R5-FORCE", path: "App/Fernlet/A.swift", symbol: "try!", lineContains: nil, reason: "wrong symbol"),
            AllowlistEntry(rule: "R5-FORCE", path: "App/Fernlet/A.swift", symbol: nil, lineContains: "uuidString", reason: "literal"),
            AllowlistEntry(rule: "R5-FORCE", path: "App/Fernlet/A.swift", symbol: nil, lineContains: nil, reason: "shadowed by the entry above"),
            AllowlistEntry(rule: "R9-UNSAFE", path: "App/Fernlet/Other.swift", symbol: nil, lineContains: nil, reason: "wrong path"),
            AllowlistEntry(rule: "R5-FORCE", path: "App/Fernlet/B.swift", symbol: nil, lineContains: nil, reason: "wrong rule")
        ]
        let verdict = Self.apply(entries, to: [hit, other])
        #expect(verdict.violations == [other])
        #expect(verdict.allowedCount == 1)
        #expect(verdict.unused.map(\.reason) == ["wrong symbol", "shadowed by the entry above", "wrong path", "wrong rule"])

        // A whole-file entry (neither narrowing) covers every hit of that rule in that file.
        let fileWide = Self.apply([AllowlistEntry(rule: "R9-UNSAFE", path: "App/Fernlet/B.swift", symbol: nil, lineContains: nil, reason: "seam")], to: [hit, other])
        #expect(fileWide.violations == [hit] && fileWide.unused.isEmpty)
    }

    /// Fixture: the allowlist LOADER accepts the documented shape and reports every malformed entry
    /// (missing or blank rule/path/reason, non-object entries, a non-array document).
    @Test func allowlistLoaderReportsMalformedEntries() {
        let good = Self.loadAllowlist(Data(#"[{"rule": "R9-UNSAFE", "path": "A.swift", "reason": "seam", "symbol": "Unmanaged"}]"#.utf8))
        #expect(good.problems.isEmpty)
        #expect(good.entries == [AllowlistEntry(rule: "R9-UNSAFE", path: "A.swift", symbol: "Unmanaged", lineContains: nil, reason: "seam")])

        let empty = Self.loadAllowlist(Data("[]".utf8))
        #expect(empty.problems.isEmpty && empty.entries.isEmpty)

        let bad = Self.loadAllowlist(Data(#"[{"rule": "R9-UNSAFE", "path": "A.swift"}, {"rule": " ", "path": "B.swift", "reason": "x"}, 7]"#.utf8))
        #expect(bad.problems.count == 3, "\(bad.problems)")
        #expect(Self.loadAllowlist(Data(#"{"rule": "R9-UNSAFE"}"#.utf8)).problems.count == 1)
        #expect(Self.loadAllowlist(nil).problems.count == 1)
        #expect(Self.loadAllowlist(Data("not json".utf8)).problems.count == 1)
    }

    /// Fixture: the report line has the `path:line: [symbol] text` shape a developer can act on.
    @Test func findingReportIsActionable() {
        let finding = Finding(rule: "R7-SWALLOW", path: "App/Fernlet/X.swift", line: 12, symbol: "try?", text: "try? save()")
        #expect(finding.report == "App/Fernlet/X.swift:12: [try?] try? save()")
    }

    // MARK: - Cross-check dump (DEBUG only)

    #if DEBUG
    /// Writes this port's findings as JSON — the scanner's `--json` shape — to the path named by the
    /// `FERNLET_P10_DUMP` environment variable, so the two tools can be diffed
    /// (`TEST_RUNNER_FERNLET_P10_DUMP=/path/out.json xcodebuild test-without-building …`). A no-op
    /// when the variable is unset.
    @Test func dumpFindingsForCrossCheckWhenRequested() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["FERNLET_P10_DUMP"] ?? environment["TEST_RUNNER_FERNLET_P10_DUMP"],
              !destination.isEmpty else { return }
        let scan = Self.sharedScan
        let verdict = Self.sharedVerdict
        let density = (scan.density * 1000).rounded() / 1000
        let object: [String: Any] = [
            "files": scan.files,
            "violations": verdict.violations.map { finding -> [String: Any] in
                ["rule": finding.rule, "path": finding.path, "line": finding.line, "symbol": finding.symbol, "text": finding.text]
            },
            "allowed": verdict.allowedCount,
            "unused_allowlist": verdict.unused.map { entry -> [String: Any] in
                var dict: [String: Any] = ["rule": entry.rule, "path": entry.path, "reason": entry.reason]
                if let symbol = entry.symbol { dict["symbol"] = symbol }
                if let lineContains = entry.lineContains { dict["line_contains"] = lineContains }
                return dict
            },
            "density": [
                "checks": scan.checks, "functions": scan.functions, "value": density,
                "floor": Self.densityFloor, "ok": scan.density >= Self.densityFloor
            ] as [String: Any],
            "unreadable": scan.unreadable
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: destination))
    }
    #endif

    // MARK: - Enforcement helper

    /// Asserts there is no remaining violation of `rules` after the allowlist, listing every one as
    /// `path:line: [symbol] text` (sorted by path, then line) so the failure output is the to-do list.
    private func expectNoViolations(of rules: [String], hint: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let scan = Self.sharedScan
        #expect(scan.unreadable.isEmpty, "Unreadable Swift files: \(scan.unreadable).", sourceLocation: sourceLocation)
        #expect(scan.files >= Self.minimumShippingFilesScanned, "Scanned only \(scan.files) files — discovery is broken.", sourceLocation: sourceLocation)
        for rule in rules {
            let violations = Self.sharedVerdict.violations
                .filter { $0.rule == rule }
                .sorted { ($0.path, $0.line) < ($1.path, $1.line) }
            // Recorded as an Issue rather than `#expect(violations.isEmpty)` so the failure text is the
            // report itself — the macro would otherwise prepend a dump of every Finding struct.
            guard !violations.isEmpty else { continue }
            Issue.record(
                "== \(rule): \(violations.count) violation(s) == Fix each, or add a reviewed allowlist entry with the invariant in its reason — \(hint):\n\(violations.map(\.report).joined(separator: "\n"))",
                sourceLocation: sourceLocation
            )
        }
    }

    // MARK: - Port: tokenizer (`strip_code` / `tokenize`)

    /// Whether `scalar` is whitespace to Python's `str.strip()` / `str.isspace()`.
    static func isPythonWhitespace(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x09...0x0D, 0x1C...0x20, 0x85, 0xA0, 0x1680, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000:
            return true
        default:
            return false
        }
    }

    /// Python `str.strip()`: whitespace removed from both ends, by Unicode scalar.
    static func pyStrip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isPythonWhitespace($0) }),
              let last = scalars.lastIndex(where: { !isPythonWhitespace($0) }) else { return "" }
        return String(scalars[first...last])
    }

    /// The first `findingTextLimit` code points of `text` — Python's `[:160]` on a `str`.
    static func truncateForFinding(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.prefix(findingTextLimit)))
    }

    /// Splits raw file bytes into lines the way Python's text-mode `readlines()` does (universal
    /// newlines: `\n`, `\r\n`, or `\r`; no trailing empty line after a final newline).
    static func splitLines(_ bytes: [UInt8]) -> [[UInt8]] {
        var lines: [[UInt8]] = []
        var current: [UInt8] = []
        var index = 0
        let count = bytes.count
        while index < count {
            let byte = bytes[index]
            if byte == 0x0A {
                lines.append(current)
                current = []
                index += 1
            } else if byte == 0x0D {
                lines.append(current)
                current = []
                index += (index + 1 < count && bytes[index + 1] == 0x0A) ? 2 : 1
            } else {
                current.append(byte)
                index += 1
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }

    /// Lines of an in-memory snippet (fixtures), via the same splitter the file scan uses.
    static func lines(of source: String) -> [[UInt8]] {
        splitLines(Array(source.utf8))
    }

    /// Index of `needle` in `haystack` at or after `from`, or nil — Python's `str.find`.
    static func find(_ needle: [UInt8], in haystack: [UInt8], from start: Int) -> Int? {
        let needleCount = needle.count
        guard needleCount > 0, start >= 0, haystack.count >= needleCount else { return nil }
        var index = start
        while index + needleCount <= haystack.count {
            if haystack[index] == needle[0] {
                var offset = 1
                while offset < needleCount, haystack[index + offset] == needle[offset] { offset += 1 }
                if offset == needleCount { return index }
            }
            index += 1
        }
        return nil
    }

    /// Whether `haystack` has `needle` at exactly `position` — Python's `str.startswith(needle, i)`.
    static func hasPrefix(_ needle: [UInt8], in haystack: [UInt8], at position: Int) -> Bool {
        guard position >= 0, position + needle.count <= haystack.count else { return false }
        var offset = 0
        while offset < needle.count {
            if haystack[position + offset] != needle[offset] { return false }
            offset += 1
        }
        return true
    }

    /// The code-only portion of one raw line — string literals collapsed to `""`, comments removed —
    /// updating the cross-line tokenizer `state`. Byte-faithful to the scanner's `strip_code`.
    static func stripCode(_ line: [UInt8], state: inout TokenizerState) -> TokenizedLine {
        let quote = UInt8(ascii: "\""), hash = UInt8(ascii: "#"), backslash = UInt8(ascii: "\\")
        let openParen = UInt8(ascii: "("), closeParen = UInt8(ascii: ")")
        let lineComment: [UInt8] = Array("//".utf8), blockOpen: [UInt8] = Array("/*".utf8), blockClose: [UInt8] = Array("*/".utf8)
        let tripleQuote: [UInt8] = Array("\"\"\"".utf8)
        var out: [UInt8] = []
        var index = 0
        let count = line.count

        func finish(_ isCode: Bool? = nil) -> TokenizedLine {
            let code = String(decoding: out, as: UTF8.self)
            let stripped = pyStrip(code)
            return TokenizedLine(code: code, stripped: stripped, isCode: isCode ?? !stripped.isEmpty)
        }

        if state.inMultiLineString {
            let close = tripleQuote + Array(repeating: hash, count: state.rawHashes)
            // A payload line inside a multi-line string counts as code (and carries no tokens).
            guard let closeIndex = find(close, in: line, from: 0) else { return finish(true) }
            state.inMultiLineString = false
            index = closeIndex + close.count
        }
        if state.blockDepth > 0 {
            while index < count, state.blockDepth > 0 {
                let open = find(blockOpen, in: line, from: index)
                guard let close = find(blockClose, in: line, from: index) else { return finish(false) }
                if let open, open < close {
                    state.blockDepth += 1
                    index = open + 2
                } else {
                    state.blockDepth -= 1
                    index = close + 2
                }
            }
        }
        while index < count {
            if hasPrefix(lineComment, in: line, at: index) { break }
            if hasPrefix(blockOpen, in: line, at: index) {
                state.blockDepth = 1
                index += 2
                while index < count, state.blockDepth > 0 {
                    let open = find(blockOpen, in: line, from: index)
                    guard let close = find(blockClose, in: line, from: index) else { return finish() }
                    if let open, open < close {
                        state.blockDepth += 1
                        index = open + 2
                    } else {
                        state.blockDepth -= 1
                        index = close + 2
                    }
                }
                continue
            }
            // Raw / multi-line / plain string literals.
            var hashes = 0
            while index + hashes < count, line[index + hashes] == hash { hashes += 1 }
            if hasPrefix(tripleQuote, in: line, at: index + hashes) {
                let openLength = hashes + 3
                let close = tripleQuote + Array(repeating: hash, count: hashes)
                out.append(quote)
                out.append(quote)
                guard let closeIndex = find(close, in: line, from: index + openLength) else {
                    state.inMultiLineString = true
                    state.rawHashes = hashes
                    return finish(true)
                }
                index = closeIndex + close.count
                continue
            }
            if hashes >= 1, index + hashes < count, line[index + hashes] == quote {
                let close = [quote] + Array(repeating: hash, count: hashes)
                out.append(quote)
                out.append(quote)
                if let closeIndex = find(close, in: line, from: index + hashes + 1) {
                    index = closeIndex + close.count
                } else {
                    index = count
                }
                continue
            }
            let byte = line[index]
            if byte == quote {
                var cursor = index + 1
                var depth = 0
                while cursor < count {
                    let current = line[cursor]
                    if current == backslash {
                        if cursor + 1 < count, line[cursor + 1] == openParen {
                            depth += 1
                            cursor += 2
                            continue
                        }
                        cursor += 2
                        continue
                    }
                    if depth > 0 {
                        if current == openParen {
                            depth += 1
                        } else if current == closeParen {
                            depth -= 1
                        }
                        cursor += 1
                        continue
                    }
                    if current == quote { break }
                    cursor += 1
                }
                out.append(quote)
                out.append(quote)
                index = cursor + 1
                continue
            }
            out.append(byte)
            index += 1
        }
        return finish()
    }

    /// Tokenizes every line of a file, threading the tokenizer state across lines.
    static func tokenize(_ lines: [[UInt8]]) -> [TokenizedLine] {
        var state = TokenizerState()
        var result: [TokenizedLine] = []
        result.reserveCapacity(lines.count)
        for line in lines {
            result.append(stripCode(line, state: &state))
        }
        return result
    }

    // MARK: - Port: body finder (`_match_decl` / `find_bodies`)

    /// A fresh pending record for a declaration head on this code line, or nil. Mirrors `_match_decl`.
    static func matchDeclaration(_ code: String) -> PendingHead? {
        if let closure = closureDeclPattern.match(code) {
            // `let table: [X] = {` — a closure literal initialiser is a function in disguise.
            return PendingHead(name: closure.group("name") ?? "", kind: "closure", decl: 0, paren: 0, seenParen: true)
        }
        if closureOnlyPattern.match(code) != nil { return nil }
        guard let head = declHeadPattern.match(code) else { return nil }
        if head.group("kind") != nil {
            return PendingHead(name: head.group("fname") ?? "", kind: "func", decl: 0, paren: 0, seenParen: false)
        }
        if head.group("init") != nil {
            return PendingHead(name: "init", kind: "init", decl: 0, paren: 0, seenParen: false)
        }
        if head.group("deinit") != nil {
            return PendingHead(name: "deinit", kind: "deinit", decl: 0, paren: 0, seenParen: true)
        }
        if head.group("subscript") != nil {
            return PendingHead(name: "subscript", kind: "subscript", decl: 0, paren: 0, seenParen: false)
        }
        if head.group("var") != nil {
            return PendingHead(name: head.group("vname") ?? "", kind: "var", decl: 0, paren: 0, seenParen: true)
        }
        if head.group("var2") != nil {
            // `var x: T` alone on its line is computed only if the NEXT line opens a `{`; a stored
            // property or protocol requirement is dropped when anything else follows.
            return PendingHead(name: head.group("vname2") ?? "", kind: "var?", decl: 0, paren: 0, seenParen: true)
        }
        return nil
    }

    /// Locates function-like bodies. A declaration head becomes pending until its body brace opens —
    /// the first `{` reached with the signature's parentheses balanced, so a default-value closure in
    /// the parameter list does not start the body early. A pending signature that is complete and is
    /// followed by a line that does not continue it is a protocol requirement / stored property and is
    /// dropped — and that same line is then examined as a fresh head. Mirrors `find_bodies`.
    static func findBodies(_ lines: [TokenizedLine]) -> [Body] {
        var bodies: [Body] = []
        var stack: [(name: String, kind: String, decl: Int, depthAtOpen: Int, openLine: Int)] = []
        var depth = 0
        var pending: PendingHead?
        for (index, line) in lines.enumerated() {
            let stripped = line.stripped
            if stripped.isEmpty { continue }
            // 1. Retire a stale pending head.
            if let head = pending, index > head.decl {
                if head.kind == "var?" {
                    if !stripped.hasPrefix("{") { pending = nil }
                } else if head.paren == 0, head.seenParen {
                    if !signatureContinuation.contains(where: { stripped.hasPrefix($0) }) { pending = nil }
                } else if index - head.decl > 40 {
                    pending = nil
                }
            }
            // 2. A fresh declaration head?
            if pending == nil, var fresh = matchDeclaration(line.code) {
                fresh.decl = index
                pending = fresh
            }
            // 3. Scan braces / parentheses.
            for byte in line.code.utf8 {
                switch byte {
                case UInt8(ascii: "("):
                    if pending != nil {
                        pending?.paren += 1
                        pending?.seenParen = true
                    }
                case UInt8(ascii: ")"):
                    if pending != nil { pending?.paren -= 1 }
                case UInt8(ascii: "{"):
                    if let head = pending, head.paren <= 0 {
                        let kind = head.kind == "var?" ? "var" : head.kind
                        stack.append((head.name, kind, head.decl, depth, index))
                        pending = nil
                    }
                    depth += 1
                case UInt8(ascii: "}"):
                    depth -= 1
                    if let top = stack.last, top.depthAtOpen == depth {
                        stack.removeLast()
                        var count = 0
                        var cursor = top.openLine + 1
                        while cursor < index {
                            if lines[cursor].isCode { count += 1 }
                            cursor += 1
                        }
                        bodies.append(Body(name: top.name, kind: top.kind, start: top.decl + 1, open: top.openLine + 1, close: index + 1, codeLines: count))
                    }
                default:
                    break
                }
            }
        }
        return bodies
    }

    // MARK: - Port: line rules (`scan_file`)

    /// Scans one file's raw lines: bodies (R4, density) then the line-level rules. Mirrors `scan_file`
    /// minus the advisory signals.
    static func scanSnippet(lines rawLines: [[UInt8]], path: String = "fixture.swift") -> FileScan {
        let tokens = tokenize(rawLines)
        let bodies = findBodies(tokens)
        var hits: [Finding] = []
        func emit(_ rule: String, _ index: Int, _ symbol: String, _ text: String? = nil) {
            let raw = text ?? String(decoding: rawLines[index], as: UTF8.self)
            hits.append(Finding(rule: rule, path: path, line: index + 1, symbol: symbol, text: truncateForFinding(pyStrip(raw))))
        }

        // -- bodies: length, density
        var functions = 0
        var checks = 0
        for body in bodies {
            if body.codeLines > maxBodyLines {
                emit("R4-LENGTH", body.start - 1, body.name, "\(body.kind) \(body.name): \(body.codeLines) code lines (max \(maxBodyLines))")
            }
            if body.codeLines >= densityMinimumLines, densityKinds.contains(body.kind) {
                functions += 1
                var cursor = body.open
                while cursor < body.close - 1 {
                    let code = tokens[cursor].code
                    if code.contains("guard"), guardPattern.match(code) != nil { checks += 1 }
                    if code.contains("assert") || code.contains("precondition") {
                        checks += assertPattern.findAll(code).count
                    }
                    cursor += 1
                }
            }
        }

        // -- line-level rules
        var ifStack: [Int] = []
        var braceDepth = 0
        for (index, line) in tokens.enumerated() {
            let code = line.code
            if line.stripped.isEmpty { continue }
            if code.contains("#if"), let ifMatch = ifPattern.match(code) {
                let condition = pyStrip(ifMatch.group(1) ?? "")
                let bad = ifTokenPattern.findAll(condition).filter { token in
                    !allowedIfTokens.contains(token)
                        && Pattern(ifAllowedArgumentPrefix + NSRegularExpression.escapedPattern(for: token)).search(condition) == nil
                }
                if !bad.isEmpty { emit("R8-IF-COND", index, condition) }
                if !ifStack.isEmpty { emit("R8-IF-NEST", index, condition) }
                ifStack.append(index)
            } else if code.contains("#endif"), endifPattern.match(code) != nil {
                if !ifStack.isEmpty { ifStack.removeLast() }
            }
            if code.contains("!") {
                if code.contains("try!"), tryBangPattern.search(code) != nil { emit("R5-FORCE", index, "try!") }
                if code.contains("as!"), asBangPattern.search(code) != nil { emit("R5-FORCE", index, "as!") }
                if iuoPattern.search(code) != nil {
                    emit("R5-FORCE", index, "IUO")
                } else if forceUnwrapPattern.search(code) != nil {
                    emit("R5-FORCE", index, "!")
                }
            }
            if code.contains("fatalError") || code.contains("preconditionFailure"), let trap = trapPattern.search(code) {
                var symbol = trap.text
                while symbol.hasSuffix("(") { symbol.removeLast() }
                emit("R5-TRAP", index, pyStrip(symbol))
            }
            if code.contains("while"), whileTruePattern.search(code) != nil || repeatWhileTruePattern.search(code) != nil {
                emit("R2-WHILE-TRUE", index, "while true")
            }
            if code.contains("try?"), swallowPattern.match(code) != nil { emit("R7-SWALLOW", index, "try?") }
            if code.contains("nsafe") || code.contains("Unmanaged"), let unsafe = unsafePattern.search(code) {
                emit("R9-UNSAFE", index, unsafe.text)
            }
            if braceDepth == 0, code.contains("var"), fileVarPattern.match(code) != nil { emit("R6-FILE-VAR", index, "var") }
            if code.contains("static"), let staticVar = staticVarPattern.match(code) {
                let rest = staticVar.group("rest") ?? ""
                // Computed if a `{` opens on this line and no `=` precedes it; stored otherwise.
                let equals = rest.firstIndex(of: "=")
                let brace = rest.firstIndex(of: "{")
                let stored: Bool
                if let brace {
                    if let equals { stored = equals < brace } else { stored = false }
                } else {
                    stored = true
                }
                if stored { emit("R6-STATIC-VAR", index, staticVar.group(1) ?? "") }
            }
            var opens = 0
            var closes = 0
            for byte in code.utf8 {
                if byte == UInt8(ascii: "{") { opens += 1 } else if byte == UInt8(ascii: "}") { closes += 1 }
            }
            braceDepth += opens - closes
        }
        return FileScan(hits: hits, functions: functions, checks: checks)
    }

    // MARK: - Port: allowlist (`load_allowlist` / `allowed`)

    /// Parses the allowlist bytes (nil = the file could not be read). Never traps: every problem is
    /// returned for the caller to report.
    static func loadAllowlist(_ data: Data?) -> AllowlistLoad {
        guard let data else { return AllowlistLoad(entries: [], problems: ["allowlist file is missing or unreadable"]) }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [])
        } catch {
            return AllowlistLoad(entries: [], problems: ["allowlist is not valid JSON: \(error.localizedDescription)"])
        }
        guard let array = object as? [Any] else {
            return AllowlistLoad(entries: [], problems: ["allowlist must be a JSON array of entries"])
        }
        var entries: [AllowlistEntry] = []
        var problems: [String] = []
        for (position, element) in array.enumerated() {
            guard let dict = element as? [String: Any] else {
                problems.append("entry #\(position) is not a JSON object")
                continue
            }
            var required: [String: String] = [:]
            for key in ["rule", "path", "reason"] {
                let value = dict[key].map { "\($0)" } ?? ""
                if pyStrip(value).isEmpty {
                    problems.append("entry #\(position) missing '\(key)': \(dict)")
                } else {
                    required[key] = value
                }
            }
            guard required.count == 3 else { continue }
            var symbol: String?
            if let raw = dict["symbol"] {
                guard let string = raw as? String else {
                    problems.append("entry #\(position) 'symbol' must be a string")
                    continue
                }
                symbol = string
            }
            var lineContains: String?
            if let raw = dict["line_contains"] {
                guard let string = raw as? String else {
                    problems.append("entry #\(position) 'line_contains' must be a string")
                    continue
                }
                lineContains = string
            }
            entries.append(AllowlistEntry(rule: required["rule"] ?? "", path: required["path"] ?? "", symbol: symbol, lineContains: lineContains, reason: required["reason"] ?? ""))
        }
        return AllowlistLoad(entries: entries, problems: problems)
    }

    /// Reads and parses the allowlist file at `url`.
    static func loadAllowlist(at url: URL) -> AllowlistLoad {
        loadAllowlist(try? Data(contentsOf: url))
    }

    /// Applies the allowlist: for each hit the FIRST entry (file order) with the same rule + path whose
    /// optional `symbol` / `line_contains` narrowings also match excuses it and is marked used. Mirrors
    /// `allowed`.
    static func apply(_ entries: [AllowlistEntry], to hits: [Finding]) -> Verdict {
        var used = Array(repeating: false, count: entries.count)
        var violations: [Finding] = []
        var allowedCount = 0
        for hit in hits {
            var excused = false
            for (position, entry) in entries.enumerated() {
                if entry.rule != hit.rule || entry.path != hit.path { continue }
                if let symbol = entry.symbol, symbol != hit.symbol { continue }
                if let lineContains = entry.lineContains, !hit.text.contains(lineContains) { continue }
                used[position] = true
                excused = true
                break
            }
            if excused { allowedCount += 1 } else { violations.append(hit) }
        }
        let unused = entries.enumerated().filter { !used[$0.offset] }.map(\.element)
        return Verdict(violations: violations, allowedCount: allowedCount, unused: unused)
    }

    // MARK: - Discovery

    /// Every `.swift` file under `root`, as repo-relative paths, skipping `.docc` bundles and `.git` /
    /// `.build` directories exactly as the scanner's `iter_swift` does. An unreachable root yields an
    /// empty array; callers assert their floor on top.
    static func swiftFiles(under root: String, repoRoot: URL) -> [String] {
        let rootPath = repoRoot.appendingPathComponent(root).path
        guard let enumerator = FileManager.default.enumerator(atPath: rootPath) else { return [] }
        var files: [String] = []
        for case let relative as String in enumerator {
            let name = (relative as NSString).lastPathComponent
            if name.hasSuffix(".docc") || name == ".git" || name == ".build" {
                enumerator.skipDescendants()
                continue
            }
            guard name.hasSuffix(".swift") else { continue }
            var isDirectory: ObjCBool = false
            let fullPath = (rootPath as NSString).appendingPathComponent(relative)
            guard FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory), !isDirectory.boolValue else { continue }
            files.append(root + "/" + relative)
        }
        return files.sorted()
    }

    /// Scans every Swift file under the four shipping roots. Never throws or traps: unreadable files
    /// are listed on the result for the enforcement tests to fail on.
    static func scanShippingRoots(repoRoot: URL) -> TreeScan {
        var scan = TreeScan()
        for root in shippingRoots {
            let files = swiftFiles(under: root, repoRoot: repoRoot)
            scan.filesPerRoot[root] = files.count
            for relative in files {
                guard let data = try? Data(contentsOf: repoRoot.appendingPathComponent(relative)) else {
                    scan.unreadable.append(relative)
                    continue
                }
                scan.files += 1
                let file = scanSnippet(lines: splitLines(Array(data)), path: relative)
                scan.hits.append(contentsOf: file.hits)
                scan.functions += file.functions
                scan.checks += file.checks
            }
        }
        return scan
    }

    // MARK: - Fixture + pin helpers

    /// Hits of `rule` in an in-memory snippet.
    static func hits(_ rule: String, in source: String) -> [Finding] {
        scanSnippet(lines: lines(of: source)).hits.filter { $0.rule == rule }
    }

    /// The `symbol` of every hit of `rule` in `source`, in line order.
    static func symbols(_ rule: String, in source: String) -> [String] {
        hits(rule, in: source).map(\.symbol)
    }

    /// The 1-based line of every hit of `rule` in `source`.
    static func lines(_ rule: String, in source: String) -> [Int] {
        hits(rule, in: source).map(\.line)
    }

    /// Non-overlapping occurrences of `needle` in `text`.
    static func occurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }

    /// The lines of `text` that are not comment-only (leading `commentPrefix` after whitespace) — so a
    /// pin distinguishes SETTING a flag from documenting it.
    static func nonCommentLines(_ text: String, commentPrefix: String) -> [String] {
        text.components(separatedBy: "\n").filter { !pyStrip($0).hasPrefix(commentPrefix) }
    }

    /// The numeric value of a top-level Python assignment `NAME = <number>` in `source`, or nil.
    static func pythonNumber(_ name: String, in source: String) -> Double? {
        guard let match = Pattern("(?m)^" + name + #"\s*=\s*([0-9.]+)"#).search(source),
              let literal = match.group(1) else { return nil }
        return Double(literal)
    }

    /// The string elements of a top-level Python tuple assignment `NAME = ("a", "b", …)` in `source`,
    /// in order, or nil.
    static func pythonStringTuple(_ name: String, in source: String) -> [String]? {
        guard let match = Pattern("(?m)^" + name + #"\s*=\s*\((.*)\)"#).search(source),
              let inner = match.group(1) else { return nil }
        return Pattern(#""([^"]*)""#).findAll(inner).map { String($0.dropFirst().dropLast()) }
    }
}
