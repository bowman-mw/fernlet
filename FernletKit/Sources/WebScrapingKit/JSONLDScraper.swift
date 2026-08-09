import Foundation

/// Locates schema.org objects inside a page's `application/ld+json` blocks — the structured, no-model
/// tier both web importers try before falling back to text scraping or on-device AI.
///
/// Pure and Foundation-only. Works on the loosely typed `Any` tree `JSONSerialization` produces
/// rather than a `Decodable` model, because real-world JSON-LD is wildly polymorphic: `@type` is a
/// string *or* an array of strings, `nutrition` is an object *or* a one-element array, and the useful
/// object is often buried inside an `@graph` or an `itemListElement` list.
public enum JSONLDScraper {

    /// The contents of every `<script type="application/ld+json">` block in `html`, trimmed, with
    /// empty blocks dropped.
    ///
    /// Detection is a case-insensitive substring test for `application/ld+json` anywhere in the
    /// script tag's attributes. The recipe importer additionally tried a stricter
    /// `type="application/ld+json"` regex first, but that test is strictly narrower than the substring
    /// test it fell back to (a tag matching the regex necessarily contains the substring), so the
    /// merged behaviour is identical to both originals.
    ///
    /// Trimming and empty-dropping came from the recipe side; the product side returned raw contents.
    /// That difference cannot be observed by either caller: both hand the string to
    /// `JSONSerialization`, which skips surrounding whitespace and rejects an empty document, and both
    /// `continue` past a parse failure. The tidier contract is kept.
    public static func scriptContents(from html: String) -> [String] {
        let pattern = #"(?is)<script\b([^>]*)>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match -> String? in
            guard match.numberOfRanges >= 3,
                  let attributesRange = Range(match.range(at: 1), in: html),
                  let contentRange = Range(match.range(at: 2), in: html),
                  String(html[attributesRange]).range(of: "application/ld+json", options: .caseInsensitive) != nil else {
                return nil
            }
            let content = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : content
        }
    }

    /// The lowercased `@type` value(s) of a JSON-LD object — one entry for the common string form, one
    /// per entry for the array form, empty when `@type` is absent or an unexpected shape.
    ///
    /// Lowercasing here (rather than comparing case-insensitively at each call site) is what lets
    /// ``object(ofType:in:)`` take a plain type name and lets callers ask about secondary types such
    /// as `ImageObject` with the same rule.
    public static func schemaTypes(in dictionary: [String: Any]) -> Set<String> {
        if let type = dictionary["@type"] as? String {
            return [type.lowercased()]
        }
        if let types = dictionary["@type"] as? [String] {
            return Set(types.map { $0.lowercased() })
        }
        return []
    }

    /// Depth-first search for the first object whose `@type` is `schemaType` (compared
    /// case-insensitively), descending through `@graph`, `itemListElement`, and bare arrays.
    ///
    /// - Parameters:
    ///   - schemaType: the bare schema.org type name, e.g. `"Product"` or `"Recipe"`. Fully
    ///     qualified `@type` URLs are **not** matched — neither original did, and adding that would
    ///     change what both importers accept.
    ///   - json: The parsed JSON-LD value to search — a dictionary, an array, or any nesting of them.
    ///
    /// **One deliberate behaviour change, in the safe direction.** The recipe importer's version
    /// returned early out of the `@graph` branch: a page whose `@graph` held no recipe was abandoned
    /// without ever looking at `itemListElement`. The product importer's version fell through and
    /// tried the next branch. This merged version falls through, so the recipe path can now find a
    /// recipe on pages where it previously found none. It can only ever find *more*, never something
    /// different: every object this returns satisfies the same `@type` test the old code applied.
    public static func object(ofType schemaType: String, in json: Any) -> [String: Any]? {
        let wanted = schemaType.lowercased()

        if let dictionary = json as? [String: Any] {
            if schemaTypes(in: dictionary).contains(wanted) {
                return dictionary
            }
            if let graph = dictionary["@graph"] as? [Any] {
                for item in graph {
                    if let match = object(ofType: schemaType, in: item) { return match }
                }
            }
            if let itemList = dictionary["itemListElement"] as? [Any] {
                for item in itemList {
                    if let match = object(ofType: schemaType, in: item) { return match }
                }
            }
        }

        if let array = json as? [Any] {
            for item in array {
                if let match = object(ofType: schemaType, in: item) { return match }
            }
        }

        return nil
    }
}
