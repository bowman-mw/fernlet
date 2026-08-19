import Foundation
import AIContext
import FoodCatalog
import FernletDomainModel
import WebScrapingKit

#if canImport(FoundationModels)
import FoundationModels
#endif

/// The structured result of a recipe web import: name, ingredient lines, per-serving macros, and
/// optional ordered cooking steps, tied to the page they came from.
///
/// Produced by ``RecipeWebImporter`` from either JSON-LD structured data (macros from the site's
/// own nutrition label when present, else USDA estimation against the local catalog) or the
/// on-device model fallback (always USDA-estimated, `servings == 1`). The `AppServices` module
/// bridges it into a `RecipeDefinition` via `RecipeDefinition(importedRecipe:)` — the wall-legal
/// downward edge that carries imports into the diary. Explicitly `nonisolated`: a plain value type
/// in a MainActor-default module.
public nonisolated struct ImportedRecipe: Equatable {
    /// The page the recipe was imported from, retained for attribution.
    public var sourceURL: URL
    /// The recipe title as the source gave it.
    public var name: String
    /// Raw ingredient lines exactly as the source listed them (unparsed display strings).
    public var ingredients: [String]
    /// A short 1–2 sentence cooking-method blurb (site instructions condensed, or model-written).
    public var summary: String
    /// The serving count the macros are divided by; 1 when the source gave none.
    public var servings: Int
    /// Per-serving grams of protein.
    public var protein: Int
    /// Per-serving grams of carbohydrate.
    public var carbs: Int
    /// Per-serving grams of fat.
    public var fat: Int
    /// Per-serving micronutrient detail from the site's own nutrition label; empty when macros were
    /// estimated from ingredients.
    public var micronutrients: Micronutrients
    /// Ordered cooking steps parsed from JSON-LD `recipeInstructions` (F5). `nil` when the source had no
    /// structured instructions. `summary` stays the short blurb; steps are a separate, ordered list.
    public var steps: [RecipeStep]?
    /// The page's main food-picture URL (JSON-LD `image` first, `og:image`/`twitter:image` meta
    /// fallback — see ``RecipeWebImporter/extractedImageURL(from:sourceURL:)``), or `nil` when the
    /// page offered none. Only the URL is extracted here; the bytes are downloaded separately by
    /// user-present paths (owner decision 2026-08-09) via
    /// ``RecipeWebImporter/downloadImage(from:userAgent:maxBytes:)`` — never during the
    /// share-extension background drain.
    public var imageURL: URL?

    public init(
        sourceURL: URL,
        name: String,
        ingredients: [String],
        summary: String,
        servings: Int,
        protein: Int,
        carbs: Int,
        fat: Int,
        micronutrients: Micronutrients = Micronutrients(),
        steps: [RecipeStep]? = nil,
        imageURL: URL? = nil
    ) {
        self.sourceURL = sourceURL
        self.name = name
        self.ingredients = ingredients
        self.summary = summary
        self.servings = servings
        self.protein = protein
        self.carbs = carbs
        self.fat = fat
        self.micronutrients = micronutrients
        self.steps = steps
        self.imageURL = imageURL
    }
}

/// Failure modes of the recipe web-import pipeline, each carrying user-facing copy.
///
/// The one distinction callers branch on is transient vs. persistent: ``aiBudgetExhausted`` clears
/// at midnight (retry tomorrow, without consuming a bounded retry attempt), while every other case
/// is terminal for this attempt. The share-extension queue drain relies on that split.
public enum RecipeWebImportError: LocalizedError {
    /// The URL failed the SSRF guard: not HTTPS, no host, or a loopback / private / link-local
    /// address literal.
    case invalidURL
    /// The network fetch failed, returned a non-2xx status (including a refused redirect), or was
    /// not HTML.
    case fetchFailed
    /// The response body decoded to empty or whitespace-only text.
    case emptyHTML
    /// The page had no JSON-LD recipe and AI extraction was disabled, or the cleaned body text was
    /// empty.
    case noRecipeFound
    /// The device cannot run on-device extraction — a PERSISTENT incapability, unlike
    /// ``aiBudgetExhausted``.
    case modelUnavailable
    /// The model's extraction lacked a name or any ingredients.
    case incompleteRecipe
    /// The device is capable of on-device extraction, but today's AI budget is spent
    /// (`.resting` / `.sleepy` ambient) — a TRANSIENT state that clears at midnight. Distinct from
    /// `.modelUnavailable` (a persistent device incapability) so a deferred queue can retry tomorrow
    /// instead of burning a finite retry attempt on a state that isn't the page's fault.
    case aiBudgetExhausted

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Pasteboard does not contain a valid URL."
        case .fetchFailed:
            "Could not fetch that recipe page."
        case .emptyHTML:
            "The page did not return readable HTML."
        case .noRecipeFound:
            "No recipe could be extracted from that page."
        case .modelUnavailable:
            "On-device recipe extraction is not available on this device."
        case .incompleteRecipe:
            "The extracted recipe was missing a name or ingredients."
        case .aiBudgetExhausted:
            "The quiet helper is resting for today. I'll try this recipe again tomorrow."
        }
    }
}

/// Fetches a public recipe page and turns it into an ``ImportedRecipe`` — structured JSON-LD first,
/// on-device AI extraction as the fallback.
///
/// The pipeline (``importRecipe(from:catalog:aiEnabled:userInvoked:gate:)``):
/// 1. SSRF guard — ``isSafePublicHTTPSURL(_:)`` rejects non-HTTPS URLs and loopback / private /
///    link-local address literals, and the `RedirectValidator` delegate re-applies the same check
///    on every redirect hop.
/// 2. Bounded fetch — HTML content types only, capped at 3 MB, over `WebScrapingKit`'s
///    `EphemeralWebSession`: no cookie jar, no URL cache, no credential store, so nothing a page sets
///    during one import survives to be read back during another (Docs/No-Tracking-Wall.md §2a).
/// 3. JSON-LD path — a schema.org `Recipe` object yields name, ingredients, servings, ordered steps
///    (``orderedSteps(from:)``), and macros from the site's own nutrition label, else USDA
///    estimation against the local `FoodCatalog`. No model call, no gate charge.
/// 4. AI fallback — only when no JSON-LD recipe was found AND `aiEnabled` is true: body text is
///    cleaned and truncated to 12k characters, dispatch routes through `FernletAIGate` (via
///    `resolveRoute`, so a transient budget fallback surfaces as
///    ``RecipeWebImportError/aiBudgetExhausted`` while persistent incapability surfaces as
///    ``RecipeWebImportError/modelUnavailable``), and every model call is recorded in `AIAuditLog`.
///
/// Only the page host and the cleaned-text character count reach the audit payload
/// (`RecipeExtractionPayload`) — never page content. Callers: the paste-a-URL import flow
/// (user-invoked) and the share-extension queue drain (`userInvoked: false`, which defers on budget
/// exhaustion rather than burning a retry attempt). MainActor by the module's default isolation;
/// the parsing and SSRF helpers are `nonisolated` pure functions, and the module persists nothing.
///
/// The importer also owns the app's only recipe-image HTTP path (owner decision 2026-08-09):
/// ``extractedImageURL(from:sourceURL:)`` pulls the page's main food-picture URL out of the already
/// fetched HTML (no extra request), and ``downloadImage(from:userAgent:maxBytes:)`` downloads image
/// bytes under the same SSRF/redirect/MIME/size guard rigor as the page fetch. Import never
/// downloads the image itself — user-present callers do, so the background drain stays image-free.
public enum RecipeWebImporter {
    /// Fetch cap: HTML accumulation stops at 3 MB so a hostile or bloated page cannot exhaust memory.
    private static let maxFetchBytes = 3 * 1024 * 1024  // 3 MB

    /// Imports one recipe page end to end: SSRF-guarded fetch, JSON-LD extraction, then the gated
    /// on-device model fallback.
    ///
    /// - Parameter url: Public HTTPS page to fetch and inspect for recipe content.
    /// - Parameter catalog: Food catalog used to resolve imported ingredients against Fernlet foods.
    /// - Parameter aiEnabled: When false, the FoundationModels fallback is skipped so that
    ///   users who have disabled AI are not silently opted in via recipe import.
    /// - Parameter gate: routes the on-device model dispatch (`standard` tier). The gate caps by device
    ///   capability, applies the sleepy/resting budget, and charges one call; a persistent fallback
    ///   surfaces as `.modelUnavailable`, a transient budget fallback as `.aiBudgetExhausted`.
    /// - Parameter userInvoked: `true` for a foreground tap (the user pasted a recipe URL and is
    ///   waiting); `false` for the ambient share-extension queue drain. Ambient work falls back in the
    ///   `.sleepy` band (a user tap still runs), so the drain leaves the record queued for tomorrow
    ///   rather than consuming a retry attempt on a state that clears at midnight.
    public static func importRecipe(from url: URL, catalog: FoodCatalog, aiEnabled: Bool, userInvoked: Bool, gate: FernletAIGate) async throws -> ImportedRecipe {
        guard isSafePublicHTTPSURL(url) else {
            throw RecipeWebImportError.invalidURL
        }

        let html = try await fetchHTML(from: url)
        // M10: the JSON-LD scan is linear now, but it still walks up to 3 MB of page-controlled
        // markup, and this module is MainActor-by-default. Run the scan OFF the main actor and bring
        // back only the `[String]` blocks (Sendable) — the JSON parse, the bounded object walk and
        // the catalog conversion stay on-actor. A pathological page then degrades this import
        // instead of freezing the UI that is awaiting it.
        let scripts = await Task.detached(priority: .userInitiated) {
            JSONLDScraper.scriptContents(from: html)
        }.value
        // The page's main food picture, as a URL only — no second fetch happens here, so the
        // background queue drain stays image-free; user-present callers download it later.
        let imageURL = extractedImageURL(from: html, sourceURL: url)
        if var recipe = try jsonLDRecipe(from: scripts, sourceURL: url, catalog: catalog) {
            recipe.imageURL = imageURL
            return recipe
        }

        guard aiEnabled else {
            throw RecipeWebImportError.noRecipeFound
        }

        let cleanedText = try await cleanedBodyText(from: html)
        var recipe = try await extractWithFoundationModel(from: cleanedText, sourceURL: url, catalog: catalog, userInvoked: userInvoked, gate: gate)
        recipe.imageURL = imageURL
        return recipe
    }

    /// Streams the page with a 15 s idle timeout (plus the session's 120 s whole-transfer ceiling,
    /// `EphemeralWebSession.maxResourceSeconds`), redirect re-validation, an HTML-only MIME check, and the
    /// 3 MB cap; UTF-8 with an ISO-Latin-1 fallback.
    ///
    /// Transport is `WebScrapingKit`'s `EphemeralWebSession` — no cookie jar, no cache, no credential
    /// store — so a page imported today cannot set state that a later, unrelated import hands back.
    /// Everything *else* here is this importer's own policy and deliberately differs from the product
    /// importer's: an honest `Fernlet/1.0` User-Agent (not a Safari spoof), a `mimeType`-prefix content
    /// check (not a header-substring one), and truncation rather than failure at the size cap.
    private static func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Fernlet/1.0", forHTTPHeaderField: "User-Agent")

        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            // Validate every redirect hop, not just the initial URL: a public https page can 30x
            // to an internal/link-local address. A rejected redirect surfaces the 3xx response,
            // which the status-code guard below treats as a failed fetch.
            //
            // RedirectValidator is a per-TASK delegate, so it keeps working unchanged on a custom
            // session — the SSRF guard is untouched by the move off URLSession.shared.
            (asyncBytes, response) = try await EphemeralWebSession.shared.bytes(for: request, delegate: RedirectValidator())
        } catch {
            throw RecipeWebImportError.fetchFailed
        }

        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw RecipeWebImportError.fetchFailed
        }

        let mimeType = httpResponse.mimeType ?? ""
        guard mimeType.hasPrefix("text/html") || mimeType.hasPrefix("application/xhtml+xml") else {
            throw RecipeWebImportError.fetchFailed
        }

        var accumulated = Data()
        do {
            for try await byte in asyncBytes {
                accumulated.append(byte)
                if accumulated.count >= maxFetchBytes { break }
            }
        } catch {
            throw RecipeWebImportError.fetchFailed
        }

        let html = String(data: accumulated, encoding: .utf8) ?? String(data: accumulated, encoding: .isoLatin1)
        guard let html, html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw RecipeWebImportError.emptyHTML
        }
        return html
    }

    // MARK: - SSRF guard

    /// A URL is safe to fetch only if it is https with a host that is not a loopback, private, or
    /// link-local address literal. Applied to the initial URL and re-checked on every redirect.
    public nonisolated static func isSafePublicHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        return !isPrivateOrLoopbackIPLiteral(host)
    }

    /// Classifies `host` as a loopback / private / link-local IP literal in ANY of its spellings.
    ///
    /// IPv4 literals are canonicalized through `inet_aton`, which accepts every classic form the
    /// system connector does — dotted quad, hexadecimal (`0x7f.0.0.1`), octal (`0177.0.0.1`),
    /// bare 32-bit integer (`2130706433` = 127.0.0.1), and 2/3-part forms — so an encoding trick
    /// can't smuggle a loopback/private target past a dotted-quad-only check. That matters most
    /// for the image download: its URL comes verbatim from page-controlled content (JSON-LD
    /// `image` / `og:image`), not from anything the user typed. IPv6 literals go through
    /// `inet_pton` (URL.host strips the surrounding brackets), covering loopback, link-local,
    /// unique-local, and the IPv4-mapped/compatible forms (`::ffff:127.0.0.1`) whose embedded
    /// IPv4 is classified by the same rules. Non-literal hostnames are never classified here —
    /// and, unlike the old prefix check, a REAL hostname starting with "fc"/"fd" is no longer
    /// misread as a unique-local IPv6 literal.
    nonisolated static func isPrivateOrLoopbackIPLiteral(_ host: String) -> Bool {
        if host.contains(":") {
            // IPv6 literal in any spelling.
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return false }
            // The platform's own typed accessor for the same 16 bytes — no Unsafe* seam (R9).
            let octets = address.__u6_addr.__u6_addr8
            let bytes: [UInt8] = [octets.0, octets.1, octets.2, octets.3,
                                  octets.4, octets.5, octets.6, octets.7,
                                  octets.8, octets.9, octets.10, octets.11,
                                  octets.12, octets.13, octets.14, octets.15]
            if bytes == Array(repeating: 0, count: 15) + [1] { return true }        // ::1 loopback
            if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return true }            // fe80::/10 link-local
            if bytes[0] & 0xFE == 0xFC { return true }                              // fc00::/7 unique-local
            if bytes[0..<10].allSatisfy({ $0 == 0 }),
               (bytes[10] == 0xFF && bytes[11] == 0xFF) || (bytes[10] == 0 && bytes[11] == 0) {
                // ::ffff:a.b.c.d (v4-mapped) / ::a.b.c.d (v4-compatible): judge the embedded IPv4.
                return isPrivateOrLoopbackIPv4(a: Int(bytes[12]), b: Int(bytes[13]))
            }
            return false
        }
        // IPv4 literal in any classic spelling; real hostnames fail inet_aton and pass through.
        var address = in_addr()
        guard inet_aton(host, &address) == 1 else { return false }
        let value = UInt32(bigEndian: address.s_addr)
        return isPrivateOrLoopbackIPv4(a: Int(value >> 24), b: Int((value >> 16) & 0xFF))
    }

    /// The IPv4 range classification shared by the plain and IPv6-embedded paths: loopback
    /// (127/8), this-network (0/8), RFC 1918 private (10/8, 172.16/12, 192.168/16), and
    /// link-local (169.254/16). Takes the two leading octets of the CANONICAL address.
    private nonisolated static func isPrivateOrLoopbackIPv4(a: Int, b: Int) -> Bool {
        if a == 127 || a == 10 || a == 0 { return true }                  // loopback / private / this-network
        if a == 192 && b == 168 { return true }                           // private
        if a == 172 && (16...31).contains(b) { return true }              // private
        if a == 169 && b == 254 { return true }                           // link-local
        return false
    }

    /// Per-task delegate that re-validates each redirect target and cancels unsafe ones.
    ///
    /// Closes the redirect half of the SSRF guard: a public HTTPS page can 30x toward an internal or
    /// link-local address, so every hop re-runs ``RecipeWebImporter/isSafePublicHTTPSURL(_:)`` and an
    /// unsafe hop is refused — the 3xx then becomes the final response and fails the caller's
    /// status-code guard. Stateless, which is why the `@unchecked Sendable` is sound even though
    /// URLSession invokes it off the main actor.
    ///
    /// **Public because the product importer needs the same delegate** (2026-08-18). Reused, not
    /// relocated: `App/Fernlet/FoodProductWebImporter.swift` passes one of these to its own page
    /// fetch so both egress seams re-validate every hop with one implementation. Moving it into
    /// `WebScrapingKit` instead would drag ``isSafePublicHTTPSURL(_:)`` below the wall and add a
    /// third shipping file naming `URLSession` — which the no-tracking wall's
    /// `onlyThePinnedWebImportersMayHoldAnHTTPClient` pins to exactly three.
    ///
    /// Explicitly `nonisolated`: this module is built with `.defaultIsolation(MainActor.self)`
    /// (see `Package.swift`), and URLSession invokes the delegate off the main actor.
    public nonisolated final class RedirectValidator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        /// Creates a stateless validator. One per task; it holds nothing between hops.
        public override init() { super.init() }

        public func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            if let url = request.url, RecipeWebImporter.isSafePublicHTTPSURL(url) {
                completionHandler(request)
            } else {
                completionHandler(nil)   // refuse the redirect; the 3xx becomes the final response
            }
        }
    }

    // MARK: - Recipe image (owner decision 2026-08-09, reversing the 2026-07-16 "no external
    // image fetch" tester decision — see Docs/No-Tracking-Wall.md §4b)

    /// Hard byte cap for a recipe-image download (10 MB). An image stream that exceeds it is
    /// ABORTED (the download throws), never truncated — a truncated JPEG is corrupt, not smaller.
    public static let maxImageFetchBytes = 10 * 1024 * 1024

    /// The page's best "main food picture" URL, or `nil` when the page offers none.
    ///
    /// Precedence: the JSON-LD `Recipe` object's `image` value first (handling a bare string, a
    /// string array, an `ImageObject` dictionary, and an array of `ImageObject`s), then the
    /// `og:image` / `og:image:url` / `twitter:image` / `twitter:image:src` meta tags. Values are
    /// entity-decoded per this importer's policy, resolved against `sourceURL` when relative, and
    /// an `http` scheme is upgraded to `https` (the download guard would refuse plain http anyway,
    /// and virtually every image host serves both). `data:` URIs and non-web schemes yield `nil`.
    /// Pure and `nonisolated` so tests can drive it with literal HTML.
    public nonisolated static func extractedImageURL(from html: String, sourceURL: URL) -> URL? {
        for rawJSON in JSONLDScraper.scriptContents(from: html) {
            guard let jsonData = htmlDecoded(rawJSON).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: jsonData),
                  let recipe = JSONLDScraper.object(ofType: "Recipe", in: object),
                  let url = imageURLValue(recipe["image"], relativeTo: sourceURL) else { continue }
            return url
        }
        for name in ["og:image", "og:image:url", "twitter:image", "twitter:image:src"] {
            if let content = HTMLScraper.metaContent(named: name, in: html),
               let url = normalizedImageURL(from: htmlDecoded(content), relativeTo: sourceURL) {
                return url
            }
        }
        return nil
    }

    /// Max JSON-LD nodes examined while resolving one `image` value (R1/R3: the value comes from an
    /// arbitrary page, so the walk needs a bound that is visible at the loop).
    nonisolated private static let maxImageNodeVisits = 256

    /// Resolves a JSON-LD `image` value of any of its four schema.org shapes — string, `[string]`,
    /// `ImageObject`, `[ImageObject]` — to the first usable URL. `ImageObject` reads `url` first,
    /// then `contentUrl` (both appear in the wild).
    ///
    /// A bounded pre-order worklist rather than recursion (R1): the value is page-controlled, so
    /// stack depth must not follow it. Precedence is preserved by push order — the last node pushed
    /// is the next one popped.
    nonisolated static func imageURLValue(_ value: Any?, relativeTo sourceURL: URL) -> URL? {
        var work: [Any] = value.map { [$0] } ?? []
        var budget = maxImageNodeVisits
        while let node = work.popLast(), budget > 0 {
            budget -= 1
            if let string = stringValue(node) {
                if let url = normalizedImageURL(from: string, relativeTo: sourceURL) { return url }
                continue
            }
            if let array = node as? [Any] {
                work.append(contentsOf: array.reversed())      // reversed → first element popped first
                continue
            }
            if let dictionary = node as? [String: Any] {
                if let contentURL = dictionary["contentUrl"] { work.append(contentURL) }
                if let url = dictionary["url"] { work.append(url) }   // pushed last → tried first
            }
        }
        return nil
    }

    /// Trims, resolves against the page URL, upgrades `http` to `https`, and refuses anything that
    /// is not a web URL (`data:` and exotic schemes yield `nil`). The full SSRF guard runs again at
    /// download time; this only normalizes what extraction hands over.
    nonisolated static func normalizedImageURL(from source: String, relativeTo sourceURL: URL) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.lowercased().hasPrefix("data:"),
              let resolved = URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL else { return nil }
        switch resolved.scheme?.lowercased() {
        case "https":
            return resolved
        case "http":
            var components = URLComponents(url: resolved, resolvingAgainstBaseURL: false)
            components?.scheme = "https"
            return components?.url
        default:
            return nil
        }
    }

    /// Downloads image bytes with the SAME guard rigor as the page fetch: ``isSafePublicHTTPSURL(_:)``
    /// on the initial URL, `RedirectValidator` re-validation on every redirect hop, a 2xx +
    /// image MIME requirement (an `image/*` declaration, or a generic binary one whose bytes then
    /// must pass the ``looksLikeImageBytes(_:)`` magic-number sniff — mislabeled S3-style image
    /// CDNs stay importable, HTML error pages do not), a 15 s idle timeout (the session adds the 120 s
    /// whole-transfer ceiling), and a hard byte cap that
    /// aborts (never truncates) an oversize stream — all over `EphemeralWebSession.shared`.
    ///
    /// - Parameter url: The image URL (typically from ``extractedImageURL(from:sourceURL:)``).
    /// - Parameter userAgent: Sent as `User-Agent`. This importer's honest default; the product
    ///   importer passes its Safari spoof so retailer CDNs keep serving its label images.
    /// - Parameter maxBytes: The abort cap; defaults to ``maxImageFetchBytes``.
    /// - Throws: ``RecipeWebImportError/invalidURL`` on a guard-refused URL,
    ///   ``RecipeWebImportError/fetchFailed`` on any transport, status, MIME, or size failure.
    /// - Returns: The raw image bytes. Callers own decoding/normalizing them (the app seals recipe
    ///   pictures through its private media store, which downscales and strips EXIF).
    public static func downloadImage(
        from url: URL,
        userAgent: String = "Fernlet/1.0",
        maxBytes: Int = maxImageFetchBytes
    ) async throws -> Data {
        guard isSafePublicHTTPSURL(url) else {
            throw RecipeWebImportError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            // Same per-hop SSRF re-validation as the page fetch — an image URL can 30x to an
            // internal/link-local address exactly like a page URL can.
            (asyncBytes, response) = try await EphemeralWebSession.shared.bytes(for: request, delegate: RedirectValidator())
        } catch {
            throw RecipeWebImportError.fetchFailed
        }

        try validateImageResponse(response, maxBytes: maxBytes)

        let data: Data
        do {
            data = try await accumulateImageBytes(asyncBytes, maxBytes: maxBytes)
        } catch {
            throw RecipeWebImportError.fetchFailed
        }
        guard !data.isEmpty else { throw RecipeWebImportError.fetchFailed }
        // A response tolerated under a generic binary declaration must actually LOOK like an
        // image: the header check alone would let an octet-stream HTML error page through, and
        // the sniff closes that without refusing the (common) mislabeled image CDNs.
        if !isImageMIMEType(response.mimeType), !looksLikeImageBytes(data) {
            throw RecipeWebImportError.fetchFailed
        }
        return data
    }

    /// Response-header half of the image-download guard: 2xx status, an `image/*` MIME type — or a
    /// generic binary one (``isGenericBinaryMIMEType(_:)``), which ``downloadImage(from:userAgent:maxBytes:)``
    /// then re-checks against the received bytes' magic numbers — and a declared `Content-Length`
    /// (when present) within `maxBytes`. Factored out `nonisolated` — and public, matching
    /// ``orderedSteps(from:)``'s plain-`import` test precedent — so tests can drive it with
    /// constructed `HTTPURLResponse`s, no network required.
    /// - Throws: ``RecipeWebImportError/fetchFailed`` on any violation.
    public nonisolated static func validateImageResponse(_ response: URLResponse, maxBytes: Int) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw RecipeWebImportError.fetchFailed
        }
        guard isImageMIMEType(httpResponse.mimeType) || isGenericBinaryMIMEType(httpResponse.mimeType) else {
            throw RecipeWebImportError.fetchFailed
        }
        if httpResponse.expectedContentLength > Int64(maxBytes) {
            throw RecipeWebImportError.fetchFailed
        }
    }

    /// Whether a response MIME type is an image (`image/*` prefix, case-insensitive). `nil` fails.
    /// Public for plain-`import` tests, like the response validator above.
    public nonisolated static func isImageMIMEType(_ mimeType: String?) -> Bool {
        mimeType?.lowercased().hasPrefix("image/") == true
    }

    /// Whether a response MIME type is a generic binary declaration (`application/octet-stream` /
    /// `binary/octet-stream`) — the S3-style default when an image host sets no content-type
    /// metadata. Real label and hero images ship under these in the wild (browsers sniff `<img>`
    /// sources, so the mislabel persists), so the download guard tolerates them — but ONLY paired
    /// with the ``looksLikeImageBytes(_:)`` sniff of the received bytes, which keeps text/HTML
    /// error pages out. `nil` fails. Public for plain-`import` tests.
    public nonisolated static func isGenericBinaryMIMEType(_ mimeType: String?) -> Bool {
        guard let mimeType = mimeType?.lowercased() else { return false }
        let bare = mimeType.split(separator: ";").first.map(String.init) ?? mimeType
        let trimmed = bare.trimmingCharacters(in: .whitespaces)
        return trimmed == "application/octet-stream" || trimmed == "binary/octet-stream"
    }

    /// Magic-number sniff for the image containers the downstream decoders accept: JPEG, PNG, GIF,
    /// WebP (RIFF), the ISO BMFF family (HEIC/HEIF/AVIF via `ftyp`), TIFF, and BMP. Consulted only
    /// for responses tolerated under a generic binary MIME type — a correctly-declared `image/*`
    /// response skips it, and every other declaration was already refused at the header check.
    /// `UIImage(data:)`/ImageIO remain the final arbiters; this only keeps obvious non-images from
    /// riding the octet-stream tolerance. Public for plain-`import` tests.
    public nonisolated static func looksLikeImageBytes(_ data: Data) -> Bool {
        func hasPrefix(_ magic: [UInt8]) -> Bool {
            data.count >= magic.count && data.prefix(magic.count).elementsEqual(magic)
        }
        if hasPrefix([0xFF, 0xD8, 0xFF]) { return true }                                // JPEG
        if hasPrefix([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }  // PNG
        if hasPrefix([0x47, 0x49, 0x46, 0x38]) { return true }                          // GIF
        if hasPrefix([0x52, 0x49, 0x46, 0x46]),                                         // RIFF…
           data.dropFirst(8).prefix(4).elementsEqual([0x57, 0x45, 0x42, 0x50]) {        // …WEBP
            return true
        }
        if data.count >= 12,
           data.dropFirst(4).prefix(4).elementsEqual([0x66, 0x74, 0x79, 0x70]) {        // ISO BMFF ftyp
            return true
        }
        if hasPrefix([0x49, 0x49, 0x2A, 0x00]) || hasPrefix([0x4D, 0x4D, 0x00, 0x2A]) { return true } // TIFF
        if hasPrefix([0x42, 0x4D]) { return true }                                      // BMP
        return false
    }

    /// Streaming-accumulation half of the image-download guard: collects `bytes` and ABORTS (throws)
    /// the moment the count exceeds `maxBytes` — an undeclared-length oversize stream must fail,
    /// not silently truncate into a corrupt image. Generic over the byte sequence so tests can feed
    /// an `AsyncStream` instead of a live `URLSession.AsyncBytes`. Explicitly `nonisolated` with a
    /// `sending` sequence: accumulating up to megabytes of a live byte stream (the product path
    /// tries as many as 8 label images) must not run its buffered synchronous bursts on the main
    /// actor during a user-visible import — the stream is handed off whole, iterated off-main, and
    /// only the finished `Data` returns to the caller.
    /// - Throws: ``RecipeWebImportError/fetchFailed`` when the cap is exceeded; rethrows transport errors.
    /// Public for plain-`import` tests, like the response validator above.
    public nonisolated static func accumulateImageBytes<S: AsyncSequence>(
        _ bytes: sending S, maxBytes: Int
    ) async throws -> Data where S.Element == UInt8 {
        var accumulated = Data()
        accumulated.reserveCapacity(min(256 * 1024, maxBytes))
        for try await byte in bytes {
            accumulated.append(byte)
            if accumulated.count > maxBytes {
                throw RecipeWebImportError.fetchFailed
            }
        }
        return accumulated
    }

    /// Converts the first usable schema.org `Recipe` object in `scripts` (the page's already-extracted
    /// `application/ld+json` blocks); `nil` sends the caller to the AI fallback.
    ///
    /// Takes the extracted blocks rather than the raw HTML so the caller can run the scan off the main
    /// actor (M10) — the catalog conversion below is MainActor work and cannot move with it.
    private static func jsonLDRecipe(from scripts: [String], sourceURL: URL, catalog: FoodCatalog) throws -> ImportedRecipe? {
        for rawJSON in scripts {
            guard let jsonData = htmlDecoded(rawJSON).data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: jsonData) else { continue }
            if let recipe = JSONLDScraper.object(ofType: "Recipe", in: object),
               let imported = importedRecipe(from: recipe, sourceURL: sourceURL, catalog: catalog) {
                return imported
            }
        }
        return nil
    }

    /// Reduces the page to model-ready plain text: body only, nav/footer/script/style stripped, tags
    /// flattened, entities decoded, whitespace collapsed, capped at 12k characters.
    ///
    /// The pass itself is `WebScrapingKit`'s; only the *empty-page* verdict is this importer's, which
    /// is why the shared helper returns `nil` instead of throwing — `.noRecipeFound` carries recipe
    /// copy and recipe retry semantics that the product importer's `.productNotFound` does not.
    /// M10: the reduction runs off the main actor — it keeps regex passes over page-controlled
    /// markup (bounded by `HTMLScraper.maxTextExtractionCharacters`, but still up to 512 KB of it) —
    /// and only the `String?` verdict crosses back.
    private static func cleanedBodyText(from html: String) async throws -> String {
        let text = await Task.detached(priority: .userInitiated) {
            HTMLScraper.cleanedBodyText(from: html, decodingNumericEntities: true)
        }.value
        guard let text else {
            throw RecipeWebImportError.noRecipeFound
        }
        return text
    }

    /// The gated model dispatch: resolves the route (distinguishing transient budget fallbacks from
    /// persistent incapability), runs guided extraction into ``ExtractedRecipe``, and records the
    /// outcome in `AIAuditLog` before returning or rethrowing.
    private static func extractWithFoundationModel(from text: String, sourceURL: URL, catalog: FoodCatalog, userInvoked: Bool, gate: FernletAIGate) async throws -> ImportedRecipe {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            let destination: AIDestination
            switch gate.resolveRoute(tier: .standard, userInvoked: userInvoked) {
            case .destination(let resolved):
                destination = resolved
            case .deterministicFallback(let reason):
                // A transient daily-budget fallback (clears at midnight) is distinct from a persistent
                // device incapability: the caller (share-extension queue) uses this to decide whether
                // to retry tomorrow vs. give up.
                switch reason {
                case .resting, .sleepy:
                    throw RecipeWebImportError.aiBudgetExhausted
                default:
                    throw RecipeWebImportError.modelUnavailable
                }
            }

            let payload = RecipeExtractionPayload(
                sourceHost: sourceURL.host() ?? "unknown",
                cleanedTextCharCount: text.count
            )
            let auditKind = payload.payloadKind
            let auditFields = payload.includedFieldNames

            let instructions = """
            Extract one cooking recipe from cleaned webpage text.
            Use the recipe title as the name. Put each ingredient line in ingredients.
            Summarize the cooking method in 1-2 sentences. Do not invent missing details.
            """
            let prompt = """
            Cleaned webpage text:
            \(text)
            """
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: ExtractedRecipe.self)
                let recipe = try response.content.importedRecipe(sourceURL: sourceURL, catalog: catalog)
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: .succeeded
                )
                return recipe
            } catch {
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: AIAuditOutcome.fromModelError(error)
                )
                throw error
            }
        }
        #endif

        throw RecipeWebImportError.modelUnavailable
    }

    // MARK: - JSON-LD parsing

    // `jsonLDScriptContents` / `scriptAttributesContainJSONLD` / `recipeObject` / `isRecipe` now live
    // in WebScrapingKit as `JSONLDScraper.scriptContents(from:)` and
    // `JSONLDScraper.object(ofType:in:)`, shared with the product importer. The one behaviour change
    // is documented on `JSONLDScraper.object(ofType:in:)`: the old `@graph` branch returned early, so
    // a page whose `@graph` held no recipe never reached `itemListElement`. The shared version falls
    // through, which can only find MORE recipes, never a different kind of object.

    private static func importedRecipe(from dictionary: [String: Any], sourceURL: URL, catalog: FoodCatalog) -> ImportedRecipe? {
        let name = stringValue(dictionary["name"]).map { String($0.prefix(maxImportedNameCharacters)) }
        // R3: `recipeIngredient` is page-controlled and otherwise bounded only by the 3 MB HTML cap;
        // every kept line costs one main-actor catalog search in estimateMacrosFromIngredients.
        let ingredients = Array(stringArrayValue(dictionary["recipeIngredient"]).prefix(maxImportedIngredients))
        let fullSummary = instructionsText(from: dictionary["recipeInstructions"])
        let summary = briefSummary(from: fullSummary)
        // F5: keep the ordered steps separately (briefSummary above still destroys them into a blurb).
        let steps = orderedSteps(from: dictionary["recipeInstructions"])
        guard let name, name.isEmpty == false, ingredients.isEmpty == false else {
            return nil
        }

        let servings = parseServings(from: dictionary["recipeYield"])

        // Prefer the site's own nutrition label; fall back to USDA ingredient matching
        let protein: Int
        let carbs: Int
        let fat: Int
        let micronutrients: Micronutrients
        if let siteNutrition = nutritionMacros(from: dictionary) {
            protein = siteNutrition.protein
            carbs = siteNutrition.carbs
            fat = siteNutrition.fat
            micronutrients = siteNutrition.micronutrients
        } else {
            (protein, carbs, fat) = estimateMacrosFromIngredients(ingredients, servings: servings, catalog: catalog)
            micronutrients = Micronutrients()
        }

        return ImportedRecipe(
            sourceURL: sourceURL,
            name: name,
            ingredients: ingredients,
            summary: summary.isEmpty ? "Imported from structured recipe data." : summary,
            servings: servings,
            protein: protein,
            carbs: carbs,
            fat: fat,
            micronutrients: micronutrients,
            steps: steps.isEmpty ? nil : steps
        )
    }

    // MARK: - Servings

    /// Max array-nesting levels unwrapped from a page's `recipeYield` (R1/R2: page-controlled input,
    /// so the unwrap needs a bound visible at the loop).
    nonisolated private static let maxYieldUnwrapDepth = 8

    /// Public for tests: `RecipeWebImporterTests` drives it with a literal `recipeYield` (plain
    /// `import AIProviders`, matching ``orderedSteps(from:)``) — no network, no `FoodCatalog`.
    public nonisolated static func parseServings(from value: Any?) -> Int {
        // Unwrap `[[4]]`-style nesting iteratively rather than recursively (R1); a scalar or a string
        // is not an `[Any]`, so this loop leaves every classified shape untouched.
        var current = value
        var depth = 0
        while let array = current as? [Any], depth < maxYieldUnwrapDepth {
            current = array.first
            depth += 1
        }
        // R5: `recipeYield` is page-controlled. `Int(d.rounded())` TRAPS for a `Double` outside
        // Int's range (1e300 in a JSON-LD field is one hostile page away), so the conversion is
        // `Int(exactly:)` and a non-representable value falls through to the trailing `return 1` —
        // "unreadable yield means one serving", the default this function already had.
        if let n = current as? Int { return boundedServings(n) }
        if let d = current as? Double, let n = Int(exactly: d.rounded()) { return boundedServings(n) }
        if let s = stringValue(current) {
            // "4 servings", "Makes 12 cookies", "4-6 servings" — take the first integer
            let digits = s.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let first = digits.first, let n = Int(first) { return boundedServings(n) }
        }
        return 1
    }

    /// Clamps a page's claimed yield into `[1, maxImportedServings]`. Clamping (not rejecting) is
    /// right here because servings is a DIVISOR, not a claim: a bogus yield must not fail an
    /// otherwise-good import, it must only stop skewing the per-serving macros.
    nonisolated private static func boundedServings(_ count: Int) -> Int {
        min(max(count, 1), maxImportedServings)
    }

    // MARK: - Nutrition label (JSON-LD schema.org/NutritionInformation)

    /// Public for tests (same reason as ``orderedSteps(from:)``): the hostile-number cases below are
    /// pure-function tests over a literal JSON-LD dictionary.
    public nonisolated static func nutritionMacros(from dictionary: [String: Any]) -> (protein: Int, carbs: Int, fat: Int, micronutrients: Micronutrients)? {
        guard let nutrition = nutritionDictionary(from: dictionary["nutrition"]) else { return nil }
        guard let protein = nutritionValue(nutrition["proteinContent"]),
              let carbs = nutritionValue(nutrition["carbohydrateContent"]),
              let fat = nutritionValue(nutrition["fatContent"]) else { return nil }
        return (
            protein,
            carbs,
            fat,
            Micronutrients(
                fiber: nutritionDoubleValue(nutrition["fiberContent"]),
                sugar: nutritionDoubleValue(nutrition["sugarContent"]),
                saturatedFat: nutritionDoubleValue(nutrition["saturatedFatContent"]),
                cholesterol: nutritionDoubleValue(nutrition["cholesterolContent"]),
                sodium: nutritionDoubleValue(nutrition["sodiumContent"])
            // R5: the page's own micronutrient numbers are finite by the guard in
            // `nutritionDoubleValue`, but a finite 1e300 sodium would still reach a trapping
            // `Int(_:)` in a day-detail row, so drop implausible amounts at the door.
            ).sanitizedForImport()
        )
    }

    nonisolated private static func nutritionDictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }.first
        }
        return nil
    }

    /// A page's nutrition figure as `Int`, or nil when it is not representable.
    ///
    /// R5: `Int(_: Double)` traps outside Int's range (see `Macros.clampedInt`'s note), so the
    /// conversion is `Int(exactly:)`. A nil here makes ``nutritionMacros(from:)`` return nil for the
    /// WHOLE label, which falls the import back to USDA ingredient estimation — the degrade path
    /// every other unparseable nutrition field already takes.
    nonisolated private static func nutritionValue(_ value: Any?) -> Int? {
        nutritionDoubleValue(value).flatMap { Int(exactly: $0.rounded()) }
    }

    /// Page-supplied nutrition numbers, rejected unless finite and non-negative.
    ///
    /// R5: a long digit run parses to `+infinity` and a 27-digit one to ~1e27; both would trap in
    /// `Int(_:)` one line later. One guard covers every branch, so no shape can slip past it.
    nonisolated private static func nutritionDoubleValue(_ value: Any?) -> Double? {
        guard let raw = rawNutritionDouble(value), raw.isFinite, raw >= 0 else { return nil }
        return raw
    }

    /// The raw shape-matching half of ``nutritionDoubleValue(_:)`` — Int, Double, or leading numeric
    /// prefix of a string. Never call it directly: it applies no bounds.
    nonisolated private static func rawNutritionDouble(_ value: Any?) -> Double? {
        if let n = value as? Int { return Double(n) }
        if let d = value as? Double { return d }
        if let s = stringValue(value) {
            // "25 g", "25g", "25.4 grams" — take leading numeric part
            let numeric = s.prefix(while: { $0.isNumber || $0 == "." })
            if !numeric.isEmpty, let d = Double(numeric) { return d }
        }
        return nil
    }

    // MARK: - USDA ingredient macro estimation

    /// USDA fallback when the site publishes no nutrition label: parses each ingredient line, matches
    /// its cleaned name against the catalog's top result, sums scaled macros, and divides by servings.
    /// Unparseable or unmatched lines contribute nothing, so this UNDERestimates rather than invents.
    ///
    /// - Important: one catalog search per line, on the main actor. Callers cap `ingredients` at
    ///   ``maxImportedIngredients`` where the page's list enters (R3); do not hand it an uncapped
    ///   page-controlled array.
    nonisolated static func estimateMacrosFromIngredients(_ ingredients: [String], servings: Int, catalog: FoodCatalog) -> (Int, Int, Int) {
        var totalProtein = 0.0, totalCarbs = 0.0, totalFat = 0.0

        for text in ingredients {
            guard let parsed = parseIngredient(text),
                  let match = catalog.results(for: parsed.name, limit: 1).first else { continue }
            let ri = RecipeIngredient(foodItemId: match.id, quantity: parsed.quantity, unit: parsed.unit)
            let macros = ri.scaledMacros(using: match)
            totalProtein += Double(macros.protein)
            totalCarbs += Double(macros.carbs)
            totalFat += Double(macros.fat)
        }

        let d = max(Double(servings), 1.0)
        return (
            Int((totalProtein / d).rounded()),
            Int((totalCarbs / d).rounded()),
            Int((totalFat / d).rounded())
        )
    }

    // MARK: - Ingredient parsing

    // Parses "2 cups all-purpose flour" → (quantity: 2.0, unit: "cup", name: "flour")
    nonisolated private static func parseIngredient(_ text: String) -> (quantity: Double, unit: String, name: String)? {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Leading quantity: mixed fraction "1 1/2", pure fraction "3/4", or decimal/integer "2"
        // Followed by optional unit, then food name
        let pattern = #"^(\d+\s+\d+/\d+|\d+/\d+|\d+(?:\.\d+)?)\s*(tablespoons?|teaspoons?|cups?|ounces?|pounds?|tbsps?|tsps?|oz|lbs?|g|grams?|ml|milliliters?|millilitres?|cloves?|large|medium|small|whole|each)?\s*(.+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = regex.firstMatch(in: s, range: NSRange(s.startIndex..<s.endIndex, in: s)),
              match.numberOfRanges >= 4 else { return nil }

        guard let qRange = Range(match.range(at: 1), in: s),
              let quantity = parseQuantity(String(s[qRange])) else { return nil }

        let unitStr: String
        if match.range(at: 2).location != NSNotFound, let uRange = Range(match.range(at: 2), in: s) {
            unitStr = String(s[uRange])
        } else {
            unitStr = ""
        }

        guard let nRange = Range(match.range(at: 3), in: s) else { return nil }
        let name = cleanFoodName(String(s[nRange]))
        guard name.count >= 3 else { return nil }

        let (resolvedQty, resolvedUnit) = resolveUnit(quantity: quantity, unitString: unitStr)
        return (quantity: resolvedQty, unit: resolvedUnit, name: name)
    }

    nonisolated private static func parseQuantity(_ text: String) -> Double? {
        let s = text.trimmingCharacters(in: .whitespaces)
        // Mixed number: "1 1/2"
        let parts = s.components(separatedBy: " ")
        if parts.count == 2, let whole = Double(parts[0]), let frac = parseFraction(parts[1]) {
            return whole + frac
        }
        // Pure fraction: "3/4"
        if let frac = parseFraction(s) { return frac }
        // Integer or decimal
        return Double(s)
    }

    nonisolated private static func parseFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard parts.count == 2,
              let num = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let den = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              den != 0 else { return nil }
        return num / den
    }

    nonisolated private static func resolveUnit(quantity: Double, unitString: String) -> (Double, String) {
        switch unitString.lowercased().trimmingCharacters(in: .whitespaces) {
        case "cup", "cups":
            return (quantity, RecipeUnit.cup.rawValue)
        case "tbsp", "tablespoon", "tablespoons":
            return (quantity, RecipeUnit.tablespoon.rawValue)
        case "tsp", "teaspoon", "teaspoons":
            return (quantity, RecipeUnit.teaspoon.rawValue)
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres":
            return (quantity, RecipeUnit.milliliter.rawValue)
        case "oz", "ounce", "ounces":
            return (quantity, RecipeUnit.ounce.rawValue)
        case "g", "gram", "grams":
            return (quantity, RecipeUnit.gram.rawValue)
        case "lb", "lbs", "pound", "pounds":
            return (quantity * 453.592, RecipeUnit.gram.rawValue)
        case "clove", "cloves", "large", "medium", "small", "whole", "each":
            return (quantity, RecipeUnit.each.rawValue)
        default:
            return (quantity, RecipeUnit.serving.rawValue)
        }
    }

    nonisolated private static func cleanFoodName(_ text: String) -> String {
        var s = text
        // Strip parenthetical notes: "(optional)", "(about 2 cups)"
        s = s.replacingOccurrences(of: #"\s*\([^)]*\)"#, with: "", options: .regularExpression)
        // Cut at comma: "chicken, boneless skinless" → "chicken"
        if let comma = s.range(of: ",") { s = String(s[s.startIndex..<comma.lowerBound]) }
        // Remove common prep descriptors that reduce search accuracy
        let prefixes = ["fresh ", "frozen ", "chopped ", "diced ", "sliced ", "minced ",
                        "grated ", "shredded ", "cooked ", "uncooked ", "raw ",
                        "dried ", "canned ", "packed ", "of "]
        for prefix in prefixes where s.lowercased().hasPrefix(prefix) {
            s = String(s.dropFirst(prefix.count))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Shared text helpers

    private static func briefSummary(from text: String, maxLength: Int = 280) -> String {
        guard text.count > maxLength else { return text }
        let prefix = String(text.prefix(maxLength))
        for sep in [". ", "! ", "? "] {
            if let range = prefix.range(of: sep, options: .backwards) {
                return String(prefix[...range.lowerBound]) + "."
            }
        }
        if let range = prefix.range(of: " ", options: .backwards) {
            return String(prefix[..<range.lowerBound]) + "…"
        }
        return prefix + "…"
    }

    nonisolated private static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return nil
    }

    private static func stringArrayValue(_ value: Any?) -> [String] {
        if let strings = value as? [String] {
            return strings
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                // R3: one page-controlled ingredient line is otherwise bounded only by the 3 MB HTML cap.
                .map { String($0.prefix(RecipeWebImporter.maxImportedIngredientLineCharacters)) }
        }
        if let string = stringValue(value) {
            return [string]
        }
        return []
    }

    /// Max JSON-LD nodes examined while flattening one `recipeInstructions` value (R1/R2/R3: the
    /// value comes from an arbitrary page, so both the walk and the result need visible bounds).
    nonisolated private static let maxInstructionNodeVisits = 4_000

    /// Ingredient lines kept from one imported page (R3: page-controlled input). No real recipe
    /// approaches 100 lines, and each kept line costs one catalog search during a user-visible import.
    nonisolated public static let maxImportedIngredients = 100

    /// Ordered steps kept from one imported page (R3: page-controlled input). A real recipe is far
    /// below this; the cap exists because these steps are persisted and then serialised into the
    /// app-group file a cold-launched Live Activity intent must decode on every Lock Screen tap.
    nonisolated public static let maxImportedSteps = 200

    /// Largest serving count believed from a page's `recipeYield` (R3/R5: page-controlled). Matches
    /// `FernletStore.RecipeImportLimits.maxServings`, the cap the mesh/paste paths already enforce.
    nonisolated public static let maxImportedServings = 100

    /// Longest recipe NAME kept from an imported page (R3: page-controlled input). Deliberately
    /// EQUAL to the wire cap, not larger: a web-imported recipe can be shared over the mesh, and a
    /// name this importer kept but `SharedSavedRecipePayload.init(from:)` rejects would mean Fernlet
    /// emitting a share Fernlet refuses.
    nonisolated public static let maxImportedNameCharacters = SharedRecipeLimits.maxNameCharacters

    /// Longest single ingredient LINE kept from an imported page (R3: page-controlled input).
    nonisolated public static let maxImportedIngredientLineCharacters = 300

    /// Longest single STEP text kept from an imported page (R3: page-controlled input; the steps are
    /// persisted and then serialised into the app-group file a cold Live Activity intent decodes).
    nonisolated public static let maxImportedStepTextCharacters = 2_000

    // Page strings are TRUNCATED here, not rejected: unlike a peer's wire payload, page text carries
    // no authorship contract, and failing a whole import over one long step is bad UX.

    private static func instructionsText(from value: Any?) -> String {
        instructionTexts(from: value).joined(separator: " ")
    }

    /// Flattens any `recipeInstructions` shape to its text, in order, with a node budget.
    ///
    /// The bounded, iterative replacement for the old mutually-recursive `instructionText` overload
    /// pair (R1) — depth used to follow page-controlled `itemListElement` nesting. Joining the flat
    /// leaf sequence with a single space is what the nested joins produced, because every level used
    /// the same separator and an empty subtree contributed nothing. The one ordering detail kept from
    /// the old dictionary overload: `text`/`name` win over `itemListElement`.
    nonisolated private static func instructionTexts(from value: Any?) -> [String] {
        var out: [String] = []
        var work: [Any] = value.map { [$0] } ?? []
        var budget = maxInstructionNodeVisits
        while let node = work.popLast(), budget > 0 {
            budget -= 1
            if let string = stringValue(node) { out.append(string); continue }
            if let array = node as? [Any] {
                work.append(contentsOf: array.reversed())      // reversed → original order
                continue
            }
            if let dictionary = node as? [String: Any] {
                if let text = stringValue(dictionary["text"]) ?? stringValue(dictionary["name"]) {
                    out.append(text)
                    continue
                }
                if let itemList = dictionary["itemListElement"], !(itemList is NSNull) {
                    work.append(itemList)
                }
            }
        }
        return out
    }

    /// F5: parse `recipeInstructions` into ORDERED steps rather than flattening them (which
    /// `instructionsText` does for the `briefSummary`). Preserves step order and section order:
    /// - a plain string array → one step per element, in order;
    /// - an array of `HowToStep` dictionaries → one step each (`text`, falling back to `name`);
    /// - `HowToSection` dictionaries (those with `itemListElement`) → their sub-steps flattened in
    ///   place, so sections concatenate section-by-section in order;
    /// - a single string → one step.
    /// Web JSON-LD steps rarely carry per-step timing, so `durationSeconds` stays nil here (manual
    /// entry supplies timers). Blank steps are dropped. Purely shape-based.
    /// The result is capped at ``maxImportedSteps`` and the walk at ``maxInstructionNodeVisits``.
    /// Public so `RecipeStepsTests` can drive it directly (plain `import AIProviders`, matching the other
    /// importer tests) — it needs no network fetch or `FoodCatalog`, unlike the full import path.
    public nonisolated static func orderedSteps(from value: Any?) -> [RecipeStep] {
        // A bounded pre-order worklist rather than recursion (R1) — the value is page-controlled, so
        // stack depth must not follow it — and capped at `maxImportedSteps` (R3).
        var out: [RecipeStep] = []
        var work: [Any] = value.map { [$0] } ?? []
        var budget = maxInstructionNodeVisits
        while let node = work.popLast(), budget > 0, out.count < maxImportedSteps {
            budget -= 1
            if let string = stringValue(node) {
                out.append(RecipeStep(text: String(string.prefix(maxImportedStepTextCharacters))))
                continue
            }
            if let values = node as? [Any] {
                work.append(contentsOf: values.reversed())     // reversed → original order
                continue
            }
            guard let dictionary = node as? [String: Any] else { continue }
            // HowToSection: flatten its ordered sub-steps (never surface the section name as a step).
            // schema.org permits `itemListElement` to be either an array OR a single object, so push
            // the raw value rather than only matching `[Any]` — a single-object section would
            // otherwise fall through to the text/name branch and emit the SECTION NAME as the step
            // (dropping every real sub-step). An empty result drops the section, matching the array path.
            if let itemList = dictionary["itemListElement"], !(itemList is NSNull) {
                work.append(itemList)
                continue
            }
            // HowToStep: prefer `text`, fall back to `name`.
            if let text = stringValue(dictionary["text"]) ?? stringValue(dictionary["name"]) {
                out.append(RecipeStep(text: String(text.prefix(maxImportedStepTextCharacters))))
            }
        }
        return out
    }

    /// This importer's entity-decoding policy: numeric character references (`&#8217;`, `&#x2019;`)
    /// ARE decoded, then the named entities.
    ///
    /// The machinery is shared with the product importer, but the policy is not — that importer
    /// decodes named entities only, and the difference is real (it changes what an href or a JSON-LD
    /// blob looks like after decoding), so `WebScrapingKit` takes it as a required parameter rather
    /// than guessing. Kept as a one-line shim so this file states its policy in exactly one place.
    /// `nonisolated` (pure) so the nonisolated image-extraction helpers can apply the same policy.
    nonisolated private static func htmlDecoded(_ text: String) -> String {
        HTMLScraper.htmlDecoded(text, decodingNumericEntities: true)
    }
}

#if canImport(FoundationModels)
/// The `@Generable` response schema for AI recipe extraction: a name, raw ingredient lines, and a
/// short method summary — no numbers, per the prompt's instructions.
///
/// ``importedRecipe(sourceURL:catalog:)`` validates and converts the raw response; the model never
/// supplies macros, so nutrition is always USDA-estimated in code at one serving.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct ExtractedRecipe {
    var name: String
    var ingredients: [String]
    var summary: String

    /// Trims and validates the response — a blank name or zero ingredients throws
    /// ``RecipeWebImportError/incompleteRecipe`` — then builds the ``ImportedRecipe`` with
    /// USDA-estimated macros at `servings: 1`.
    func importedRecipe(sourceURL: URL, catalog: FoodCatalog) throws -> ImportedRecipe {
        let trimmedName = String(name.trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(RecipeWebImporter.maxImportedNameCharacters))
        // Same R3 cap as the JSON-LD path: the model's ingredient list is derived from page content.
        let trimmedIngredients = ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(RecipeWebImporter.maxImportedIngredients)
            .map { String($0.prefix(RecipeWebImporter.maxImportedIngredientLineCharacters)) }
        let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmedName.isEmpty == false, trimmedIngredients.isEmpty == false else {
            throw RecipeWebImportError.incompleteRecipe
        }

        let (protein, carbs, fat) = RecipeWebImporter.estimateMacrosFromIngredients(
            trimmedIngredients, servings: 1, catalog: catalog
        )

        return ImportedRecipe(
            sourceURL: sourceURL,
            name: trimmedName,
            ingredients: trimmedIngredients,
            summary: trimmedSummary.isEmpty ? "Imported with on-device extraction." : trimmedSummary,
            servings: 1,
            protein: protein,
            carbs: carbs,
            fat: fat
        )
    }
}
#endif
