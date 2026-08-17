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

    // MARK: - Body text

    /// The page furniture stripped before a page is reduced to plain text: elements whose contents are
    /// never part of the article. Removed whole (open tag through close tag), not just untagged.
    public static let noiseElementNames = ["nav", "footer", "header", "aside", "script", "style"]

    /// Removes each named element — opening tag, contents, and closing tag — from `html`.
    ///
    /// Non-greedy and case-insensitive, so nested same-name elements close at the first match. This is
    /// a text scrub, not a parse: unbalanced markup simply survives.
    public static func removingElements(_ tagNames: [String], from html: String) -> String {
        tagNames.reduce(html) { currentHTML, tagName in
            currentHTML.replacingOccurrences(
                of: #"(?is)<\#(tagName)\b[^>]*>.*?</\#(tagName)>"#,
                with: " ",
                options: .regularExpression
            )
        }
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
    public static func cleanedBodyText(
        from html: String,
        decodingNumericEntities: Bool,
        characterLimit: Int = 12_000
    ) -> String? {
        // R5: `prefix` traps on a negative length, and this is a public entry point taking a caller's
        // budget. "No budget" reads the same as "the page reduced to nothing".
        guard characterLimit > 0 else { return nil }
        let bodyHTML = firstMatchLastCapture(in: html, pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#) ?? html
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
