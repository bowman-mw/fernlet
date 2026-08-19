import Foundation
import os

/// Compiles this module's regex patterns, naming a compile failure instead of silently reporting
/// "no match".
///
/// R7: every pattern in `WebScrapingKit` is a compile-time literal, so a pattern that does not
/// compile is a programmer error — and a bare `try?` turned it into "this extraction quietly never
/// matches again". The nil-return contract is unchanged (a caller cannot recover from a bad
/// pattern), but the failure now reaches the unified log. `os.Logger`, not `FernletAuditLog`:
/// `WebScrapingKit` has ZERO in-package dependencies and must stay that way (see `Package.swift` —
/// the walled `AIProviders` inherits every edge added here).
enum WebScrapingRegex {
    private static let logger = Logger(subsystem: "com.fernlet", category: "webscraping")

    /// Compiles `pattern`, or logs and returns nil when it does not compile.
    static func compiled(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression? {
        do {
            return try NSRegularExpression(pattern: pattern, options: options)
        } catch {
            logger.error("webscraping.regex.invalidPattern: \(pattern, privacy: .public) — \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }
}

/// Pure HTML text-extraction helpers shared by the product and recipe web importers: regex capture
/// reads, HTML-entity decoding, and the "reduce a page to model-ready plain text" pass.
///
/// Every function is `static`, pure, and Foundation-only — no state, no network, no isolation. The
/// two importers previously each carried their own copy of all of this; the copies were compared
/// line by line before being merged, and the two places where they genuinely *differed* are exposed
/// as parameters rather than flattened (see ``htmlDecoded(_:decodingNumericEntities:)`` and the two
/// capture-read shapes below).
public enum HTMLScraper {

    // MARK: - Regex capture reads

    /// The **last** capture group of every match of `pattern` in `text`, in match order.
    ///
    /// "Last group" (`numberOfRanges - 1`) rather than group 1 is deliberate and is what both
    /// importers already did: several of their patterns wrap the interesting run in a trailing group
    /// after a leading structural one. For a single-group pattern the two rules coincide.
    ///
    /// A pattern that fails to compile, a match with no capture group, or a group that did not
    /// participate all contribute nothing rather than trapping.
    public static func allLastCaptures(in text: String, pattern: String) -> [String] {
        guard let regex = WebScrapingRegex.compiled(pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match -> String? in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: match.numberOfRanges - 1), in: text) else {
                return nil
            }
            return String(text[captureRange])
        }
    }

    /// The last capture group of the **first** match only, or `nil`.
    ///
    /// Deliberately NOT `allLastCaptures(in:pattern:).first`. The two differ in exactly one case: when
    /// the first match's capture group did not participate, this returns `nil` while the `.first`
    /// form falls through to the *second* match's capture. Both importers relied on their own shape,
    /// so both shapes are offered rather than picking one and hoping the difference never surfaces.
    /// (For every pattern in use today the trailing group is mandatory, so the two agree — but that
    /// is a property of today's patterns, not of the helper.)
    ///
    /// This is also the cheaper read: it stops at the first match instead of scanning the whole
    /// document, which matters on a 3 MB page.
    public static func firstMatchLastCapture(in text: String, pattern: String) -> String? {
        guard let regex = WebScrapingRegex.compiled(pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: match.numberOfRanges - 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }

    // MARK: - Meta tags

    /// The `content` attribute of the first `<meta>` tag whose `property` **or** `name` attribute
    /// equals `property` (case-insensitive), or `nil` when the page has no such tag.
    ///
    /// The shape both importers need for OpenGraph / Twitter-card reads (`og:image`,
    /// `twitter:image`, `og:title`, …). The attribute order is fixed — `property`/`name` before
    /// `content` — matching how real pages emit these tags and how both importers' private copies
    /// already matched. The captured value is returned raw; entity decoding stays the caller's
    /// policy (see ``htmlDecoded(_:decodingNumericEntities:)``).
    public static func metaContent(named property: String, in html: String) -> String? {
        let escapedProperty = NSRegularExpression.escapedPattern(for: property)
        return firstMatchLastCapture(
            in: html,
            pattern: #"(?is)<meta\b[^>]*(?:property|name)\s*=\s*["']\#(escapedProperty)["'][^>]*content\s*=\s*["'](.*?)["'][^>]*>"#
        )
    }

    // MARK: - Entity decoding

    /// The named HTML entities both importers decode, in the order they must be applied.
    ///
    /// `&amp;` is **last** on purpose: decoding it first would turn `&amp;lt;` into `&lt;` and then
    /// into `<`, unwrapping two layers of encoding in one pass. Applied last, each pass unwraps
    /// exactly one layer, which is what double-encoded product titles need.
    private static let namedEntities: [(String, String)] = [
        ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
        ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")
    ]

    /// Decodes HTML entities in `text`.
    ///
    /// - Parameters:
    ///   - text: The string to decode entities in.
    ///   - decodingNumericEntities: When `true`, decimal (`&#8217;`) and hexadecimal
    ///     (`&#x2019;`) character references are decoded first, then the named entities. When `false`,
    ///     only the named entities are decoded and a numeric reference is left as literal text.
    ///
    /// **This parameter is a real behavioural difference, not a style knob.** The recipe importer
    /// decoded numeric references; the product importer did not, and its callers include href
    /// unwrapping and JSON-LD blob repair where changing what gets decoded changes what parses. Both
    /// behaviours are preserved exactly: the product importer passes `false`, the recipe importer
    /// passes `true`. There is no default — a caller must state which one it wants.
    ///
    /// Note that the named pass includes `&#39;`, so an apostrophe decodes either way; when
    /// `decodingNumericEntities` is `true` the numeric pass simply gets to it first, with the same
    /// result.
    public static func htmlDecoded(_ text: String, decodingNumericEntities: Bool) -> String {
        var decoded = text
        if decodingNumericEntities {
            decoded = replacingNumericEntities(in: decoded, pattern: #"&#(\d+);"#) { UInt32($0) }
            decoded = replacingNumericEntities(in: decoded, pattern: #"&#x([0-9a-fA-F]+);"#) { UInt32($0, radix: 16) }
        }
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return decoded
    }

    /// Replaces every numeric character reference matching `pattern` with the scalar `transform`
    /// yields, walking matches in reverse so earlier ranges stay valid as later ones are spliced out.
    ///
    /// A reference whose value is not a legal Unicode scalar (a surrogate, or past `U+10FFFF`) is left
    /// untouched rather than dropped.
    private static func replacingNumericEntities(
        in text: String,
        pattern: String,
        transform: (String) -> UInt32?
    ) -> String {
        guard let regex = WebScrapingRegex.compiled(pattern) else { return text }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed()
        var result = text

        for match in matches {
            guard match.numberOfRanges > 1,
                  let scalarRange = Range(match.range(at: 1), in: result),
                  let fullRange = Range(match.range(at: 0), in: result),
                  let scalarValue = transform(String(result[scalarRange])),
                  let scalar = UnicodeScalar(scalarValue) else {
                continue
            }
            result.replaceSubrange(fullRange, with: String(Character(scalar)))
        }

        return result
    }

    // MARK: - Element walking (the linear replacement for `<tag …>(.*?)</tag>`)

    /// The next complete `<tag …>…</tag>` element at or after `cursor`, split into the three ranges
    /// the old `(?is)<tag\b([^>]*)>(.*?)</tag>` regex captured, or `nil` when the remainder of `html`
    /// holds no complete one.
    ///
    /// **Why this exists (2026-08-18, security review M10).** The regex form is quadratic on hostile
    /// input: `(.*?)` retries from every `<tag` position, and on a page that opens a tag N times and
    /// never closes it, all N starting positions each scan the whole remainder — ~N²/2 character
    /// comparisons for ZERO matches. A few hundred thousand `<script >` in a page inside the 3 MB
    /// fetch cap is enough to stall the main actor long enough for the watchdog. Here every search is
    /// a single linear `range(of:)` and `cursor` only moves forward, so a full walk is O(n).
    ///
    /// Behaviour is deliberately identical to the regex it replaces, including the awkward parts:
    /// - The close search starts after the OPEN tag, not after the next open tag, so the first
    ///   `</tag` wins even when it belongs to a later element — the same span `(.*?)` produced.
    /// - `attributes` stops at the first `>`, exactly like `[^>]*`.
    /// - A `<tag` immediately followed by a word character is not a tag open (`<scriptfoo>`), which is
    ///   what `\b` meant. `-` is NOT a word character, so `<header-bar>` still matches — that is the
    ///   regex's behaviour too, not an oversight.
    ///
    /// - Returns: `full` spans `<tag` through the closing `>`; `attributes` is the text between the
    ///   tag name and the open tag's `>`; `content` is the text between the two tags.
    static func nextElement(
        named tagName: String,
        in html: String,
        from cursor: String.Index
    ) -> (full: Range<String.Index>, attributes: Range<String.Index>, content: Range<String.Index>)? {
        guard !tagName.isEmpty, cursor < html.endIndex else { return nil }
        guard let open = openTagRange(named: tagName, in: html, from: cursor),
              let openEnd = html.range(of: ">", range: open.upperBound..<html.endIndex),
              let close = html.range(of: "</" + tagName, options: .caseInsensitive,
                                     range: openEnd.upperBound..<html.endIndex),
              let closeEnd = html.range(of: ">", range: close.upperBound..<html.endIndex) else {
            return nil
        }
        return (
            full: open.lowerBound..<closeEnd.upperBound,
            attributes: open.upperBound..<openEnd.lowerBound,
            content: openEnd.upperBound..<close.lowerBound
        )
    }

    /// The range of the next literal `<tag` at or after `cursor` that is a real tag open.
    ///
    /// R2: the only thing that repeats here is a candidate rejected by the word-boundary test
    /// (`<scriptfoo>`), so the budget bounds a pathological run of those. Exhausting it returns `nil`,
    /// which reads to every caller as "no more elements" — the same verdict a page with no further
    /// tags produces, and the same degrade the old regex gave on a page it could not match.
    private static func openTagRange(
        named tagName: String,
        in html: String,
        from cursor: String.Index
    ) -> Range<String.Index>? {
        guard !tagName.isEmpty, cursor < html.endIndex else { return nil }
        var search = cursor
        var probes = maxOpenTagProbes
        while probes > 0, search < html.endIndex {
            probes -= 1
            guard let hit = html.range(of: "<" + tagName, options: .caseInsensitive,
                                       range: search..<html.endIndex) else {
                return nil
            }
            guard hit.upperBound < html.endIndex else { return nil }
            let following = html[hit.upperBound]
            guard following == "_" || following.isLetter || following.isNumber else { return hit }
            search = hit.upperBound   // `<scriptfoo>` — not this tag; resume after the false hit
        }
        return nil
    }

    /// R2: how many rejected `<tag` candidates ``openTagRange(named:in:from:)`` probes before giving
    /// up. Ten thousand is far past any honest page and far short of anything the user would feel.
    private static let maxOpenTagProbes = 10_000

    /// R2: how many elements of ONE name ``removingElements(_:from:)`` strips per pass. A page with
    /// more `<script>` blocks than this is not a page anyone is importing a recipe from; the
    /// remainder survives untouched, which is the same "unbalanced markup simply survives" degrade
    /// this scrub has always had.
    private static let maxRemovedElements = 2_000

    // MARK: - Body text

    /// The page furniture stripped before a page is reduced to plain text: elements whose contents are
    /// never part of the article. Removed whole (open tag through close tag), not just untagged.
    public static let noiseElementNames = ["nav", "footer", "header", "aside", "script", "style"]

    /// R3: the input cap for the *text* extraction tiers — this type's ``cleanedBodyText(from:
    /// decodingNumericEntities:characterLimit:)`` and the product importer's visible-text /
    /// serving-size scrapes.
    ///
    /// Those keep `(.*?)` / `(.+?)` patterns whose cost is quadratic in the input length on markup
    /// that never closes, and the page is attacker-controlled up to the fetchers' 3 MB byte cap. A
    /// byte cap bounds memory, not CPU; this bounds CPU. 512 KB of source is far past where an honest
    /// page's article text ends and roughly 40× the 12 000-character text budget the model tier
    /// actually consumes.
    public static let maxTextExtractionCharacters = 512 * 1024

    /// Removes each named element — opening tag, contents, and closing tag — from `html`.
    ///
    /// Non-greedy and case-insensitive, so nested same-name elements close at the first match. This is
    /// a text scrub, not a parse: unbalanced markup simply survives.
    ///
    /// Walks ``nextElement(named:in:from:)`` rather than running six `.regularExpression` passes: the
    /// regex form was quadratic on a page that opens a noise tag and never closes it (M10).
    public static func removingElements(_ tagNames: [String], from html: String) -> String {
        tagNames.reduce(html) { currentHTML, tagName in
            removingElement(named: tagName, from: currentHTML)
        }
    }

    /// One tag name's pass of ``removingElements(_:from:)``: copies the text between elements and
    /// emits one space per removed element, stopping at the first incomplete one.
    private static func removingElement(named tagName: String, from html: String) -> String {
        guard !tagName.isEmpty, !html.isEmpty else { return html }
        var result = ""
        var cursor = html.startIndex
        var budget = maxRemovedElements
        while budget > 0, cursor < html.endIndex {
            budget -= 1
            guard let element = nextElement(named: tagName, in: html, from: cursor) else { break }
            result += html[cursor..<element.full.lowerBound]
            result += " "
            cursor = element.full.upperBound
        }
        result += html[cursor...]
        return result
    }

    /// Reduces a page to model-ready plain text: `<body>` only, ``noiseElementNames`` removed, all
    /// remaining tags flattened to spaces, entities decoded, whitespace collapsed to single spaces,
    /// and the result truncated to `characterLimit`.
    ///
    /// - Parameters:
    ///   - html: The page source to reduce.
    ///   - decodingNumericEntities: forwarded to ``htmlDecoded(_:decodingNumericEntities:)`` —
    ///     the one place the two importers' text pipelines differ. Product passes `false`, recipe `true`.
    ///   - characterLimit: Maximum length of the returned text; the result is truncated to it.
    /// - Returns: `nil` when the page reduces to nothing at all.
    ///
    /// **Returning `nil` rather than throwing is the point.** Both importers threw here, but each threw
    /// its own error case (`FoodProductWebImportError.productNotFound` versus
    /// `RecipeWebImportError.noRecipeFound`), and those cases carry different user-facing copy and
    /// different retry semantics. A shared helper must not pick one; each caller maps `nil` to its own
    /// error, so the observable behaviour of both importers is unchanged.
    ///
    /// A page with no `<body>` falls back to the whole document, matching both originals.
    ///
    /// **Input is capped at ``maxTextExtractionCharacters`` (2026-08-18, M10).** The `<body>` capture
    /// below still uses a `(.*?)` regex, whose cost is quadratic in the input on a page that never
    /// closes the tag; the cap is what bounds that residual. It is a real, small extraction
    /// regression — recipe or nutrition copy past 512 KB of source is now invisible to the AI text
    /// tier. It is applied HERE and not to `JSONLDScraper.scriptContents`, because JSON-LD
    /// legitimately sits at the end of long pages (that path got the linear rewrite instead).
    public static func cleanedBodyText(
        from html: String,
        decodingNumericEntities: Bool,
        characterLimit: Int = 12_000
    ) -> String? {
        // R5: `prefix` traps on a negative length, and this is a public entry point taking a caller's
        // budget. "No budget" reads the same as "the page reduced to nothing".
        guard characterLimit > 0 else { return nil }
        let source = String(html.prefix(maxTextExtractionCharacters))
        let bodyHTML = firstMatchLastCapture(in: source, pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#) ?? source
        let withoutNoise = removingElements(noiseElementNames, from: bodyHTML)
        let text = htmlDecoded(
            withoutNoise.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression),
            decodingNumericEntities: decodingNumericEntities
        )
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.isEmpty == false else { return nil }
        return String(normalized.prefix(characterLimit))
    }
}
