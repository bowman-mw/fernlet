import Foundation
import Testing
import WebScrapingKit

/// Regression cover for `WebScrapingKit`'s HTML/JSON-LD extraction primitives.
///
/// Net-new as of the 2026-08-18 security round (finding M10): nothing in the suite named
/// `JSONLDScraper` or `HTMLScraper` before, even though `scriptContents(from:)` runs unconditionally
/// on EVERY recipe and product import, before any other tier. It ran as
/// `(?is)<script\b([^>]*)>(.*?)</script>`, whose `(.*?)` retries from every `<script` position: a
/// page carrying a few hundred thousand unclosed `<script >` — well inside the importers' 3 MB fetch
/// cap — cost ~N²/2 character comparisons for ZERO matches and could stall the main actor into a
/// watchdog kill.
///
/// Two halves, and both matter: the flood cases prove the cost is now linear, and the equivalence
/// cases pin the rewrite's OUTPUT against the regex it replaced, including the awkward parts
/// (`<scriptfoo>` is not a `<script>`, and the first `</script>` wins even inside a JSON string).
struct WebScrapingKitTests {

    // MARK: - Cost: a hostile page must degrade an import, not stall the app

    /// The ceiling is deliberately generous. These assertions run on a shared, loaded CI machine, and
    /// the claim under test is a change of COMPLEXITY CLASS — the old form took minutes on this input,
    /// the new one is a handful of linear scans (measured at 0.1–1.4 s in an unoptimised build). A
    /// tight millisecond budget here would buy nothing and would flake under load (see the
    /// "wall-clock deadlines vs MainActor starvation" note): if this ever fails it must be because the
    /// quadratic term came back, not because the machine was busy.
    private static let floodCeiling: Duration = .seconds(20)

    @Test func scriptContentsSurvivesUnclosedScriptFlood() {
        let html = String(repeating: "<script >", count: 350_000)
        var found: [String] = []
        let elapsed = ContinuousClock().measure {
            found = JSONLDScraper.scriptContents(from: html)
        }
        #expect(found.isEmpty)
        #expect(elapsed < Self.floodCeiling, "scriptContents took \(elapsed) on an unclosed-<script> flood — the scan is quadratic again.")
    }

    /// The variant a "does the page even contain `</script>`?" precheck would miss: there IS a closing
    /// tag, it is just consumed by the first, legitimate block, leaving the flood with none.
    @Test func scriptContentsSurvivesLateClosingTagFlood() {
        let html = "<script>{}</script>" + String(repeating: "<script >", count: 200_000)
        var found: [String] = []
        let elapsed = ContinuousClock().measure {
            found = JSONLDScraper.scriptContents(from: html)
        }
        #expect(found.isEmpty, "the one closed block is not ld+json, so nothing should be returned.")
        #expect(elapsed < Self.floodCeiling, "scriptContents took \(elapsed) on a late-closing-tag flood.")
    }

    @Test func removingElementsSurvivesUnclosedTagFlood() {
        // Smaller than the JSON-LD floods above on purpose: this one makes SIX passes (one per noise
        // tag name) over the whole string, so an equal fixture would cost six times as much for the
        // same complexity-class evidence.
        let html = String(repeating: "<script >", count: 150_000)
        var scrubbed = ""
        let elapsed = ContinuousClock().measure {
            scrubbed = HTMLScraper.removingElements(HTMLScraper.noiseElementNames, from: html)
        }
        // Unbalanced markup simply survives — the documented contract, unchanged by the rewrite.
        #expect(scrubbed == html)
        #expect(elapsed < Self.floodCeiling, "removingElements took \(elapsed) on an unclosed-tag flood.")
    }

    // MARK: - Equivalence: the rewrite must extract exactly what the regex did

    @Test func scriptContentsKeepsOnlyLDJSONBlocks() {
        let html = """
        <script type="text/javascript">var x = 1;</script>
        <script type="application/ld+json">{"a":1}</script>
        <script type="application/ld+json">  {"b":2}  </script>
        """
        #expect(JSONLDScraper.scriptContents(from: html) == ["{\"a\":1}", "{\"b\":2}"])
    }

    @Test func scriptContentsMatchesTagAndTypeCaseInsensitively() {
        let html = #"<SCRIPT TYPE="application/LD+JSON">{"a":1}</SCRIPT>"#
        #expect(JSONLDScraper.scriptContents(from: html) == ["{\"a\":1}"])
    }

    /// `\b` in the old pattern: `<scriptfoo>` was never a `<script>` open tag, and must still not be.
    @Test func scriptContentsIgnoresLongerTagNames() {
        let html = """
        <scriptfoo type="application/ld+json">SKIPME</scriptfoo>
        <script type="application/ld+json">{"ok":1}</script>
        """
        #expect(JSONLDScraper.scriptContents(from: html) == ["{\"ok\":1}"])
    }

    @Test func scriptContentsDropsAnUnterminatedTrailingBlock() {
        let html = #"<script type="application/ld+json">{"a":1}</script><script type="application/ld+json">{"b":2}"#
        #expect(JSONLDScraper.scriptContents(from: html) == ["{\"a\":1}"])
    }

    /// First-`</script>`-wins, even when the literal text sits inside a JSON string. This is what the
    /// non-greedy `(.*?)` did, so the (mangled) result is PINNED rather than assumed: changing it
    /// would silently change what parses on any page whose JSON-LD embeds that text.
    @Test func scriptContentsStopsAtTheFirstClosingTagEvenInsideAString() {
        let html = #"<script type="application/ld+json">{"name":"a </script> b"}</script>"#
        #expect(JSONLDScraper.scriptContents(from: html) == [#"{"name":"a"#])
    }

    @Test func removingElementsStripsWholeNoiseElements() {
        let html = "<p>keep</p><nav>drop me</nav><p>keep2</p><script>drop2</script>"
        let scrubbed = HTMLScraper.removingElements(HTMLScraper.noiseElementNames, from: html)
        #expect(scrubbed.contains("keep"))
        #expect(scrubbed.contains("keep2"))
        #expect(!scrubbed.contains("drop me"))
        #expect(!scrubbed.contains("drop2"))
    }

    // MARK: - The text tiers' input cap

    /// `cleanedBodyText` still uses a `(.*?)` `<body>` capture, whose cost is quadratic in the input
    /// on markup that never closes the tag; `maxTextExtractionCharacters` is what bounds that
    /// residual. The cost of the cap is real and is asserted here so it is a decision, not a surprise:
    /// page text past 512 KB of SOURCE is invisible to the model tier.
    @Test func textExtractionIsCappedAtTheDocumentedPrefix() {
        let filler = String(repeating: "<p>lorem ipsum</p>", count: 60_000)   // ~1.08 MB
        let html = "<html><body>" + filler + "<p>TAILMARKER</p></body></html>"
        #expect(html.count > HTMLScraper.maxTextExtractionCharacters)

        let text = HTMLScraper.cleanedBodyText(
            from: html, decodingNumericEntities: false, characterLimit: 2_000_000
        )
        #expect(text?.contains("lorem") == true, "the head of the page must still be extracted.")
        #expect(text?.contains("TAILMARKER") == false, "content past the input cap must not be read.")
    }

    // MARK: - The shared session's whole-transfer ceiling

    /// The no-tracking grep-wall pins the NAME `timeoutIntervalForResource` in the factory; only this
    /// pins the VALUE. Without it a regression to the 7-day platform default passes every other check.
    @Test func ephemeralSessionBoundsWholeTransferNotJustIdleTime() {
        let configuration = EphemeralWebSession.makeConfiguration()
        #expect(
            configuration.timeoutIntervalForResource == EphemeralWebSession.maxResourceSeconds,
            "The 15 s at each caller is URLRequest.timeoutInterval — an IDLE timer reset by every byte. Without a whole-transfer ceiling a server trickling one byte every 14 s holds an import open to the 7-day platform default and wedges the share-extension drain for the session."
        )
        #expect(EphemeralWebSession.maxResourceSeconds == 120)
    }
}
