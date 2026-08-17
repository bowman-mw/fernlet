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
        guard let regex = WebScrapingRegex.compiled(pattern) else { return [] }
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
    ///
    /// R1/R2: an explicit worklist with a named budget, not recursion. The tree is
    /// attacker-controlled — a hostile page can nest `@graph`/`itemListElement` as deep as it likes —
    /// so recursion put stack depth under the page's control. The traversal order is unchanged:
    /// still depth-first, self before `@graph` before `itemListElement`, each list in order (the
    /// stack is LIFO, so children are pushed reversed and `itemListElement` before `@graph`).
    public static func object(ofType schemaType: String, in json: Any) -> [String: Any]? {
        let wanted = schemaType.lowercased()
        var work: [Any] = [json]
        var budget = maxNodesVisited

        while budget > 0, let node = work.popLast() {
            budget -= 1
            if let dictionary = node as? [String: Any] {
                if schemaTypes(in: dictionary).contains(wanted) {
                    return dictionary
                }
                if let itemList = dictionary["itemListElement"] as? [Any] {
                    work.append(contentsOf: itemList.reversed())
                }
                if let graph = dictionary["@graph"] as? [Any] {
                    work.append(contentsOf: graph.reversed())
                }
            } else if let array = node as? [Any] {
                work.append(contentsOf: array.reversed())
            }
        }

        return nil
    }

    /// The traversal budget for ``object(ofType:in:)`` — the visible upper bound (R2) on a search
    /// over a page's own JSON-LD. Real structured data is a handful of objects deep; ten thousand
    /// nodes is far past any honest page and far short of anything that costs the user a stall.
    private static let maxNodesVisited = 10_000
}
