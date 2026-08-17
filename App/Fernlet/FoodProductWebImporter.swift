import Foundation
import AIContext
import AIProviders
import AppServices
import WebScrapingKit

#if canImport(UIKit)
import UIKit
#endif

#if canImport(FoundationModels)
import FoundationModels
import FernletDomainModel
#endif

/// The "here's the page I found" step of a web product lookup: the resolved product-page URL and its
/// best-known title, shown to the user before any nutrition is extracted.
///
/// Produced by ``FoodProductWebSearch/preview(for:)`` / `FoodProductWebImporter.preview(from:)` and
/// displayed in `FoodProductReviewSheet` so the source is always disclosed alongside the values.
struct ProductPagePreview: Equatable {
    var sourceURL: URL
    var title: String

    /// The host to display as the source name, falling back to the whole URL when there is none.
    var sourceName: String {
        sourceURL.host() ?? sourceURL.absoluteString
    }
}

/// Web search for a packaged/branded product's page, plus the "is this query worth searching?"
/// gate.
///
/// Runs only behind the web-nutrition-lookup opt-in (the query egresses to DuckDuckGo's HTML
/// endpoint). Result links are unwrapped from DuckDuckGo redirects, restricted to https, and ranked
/// so retailer/chain sites beat secondary nutrition aggregators. `MealSheet`'s Save path consults
/// ``shouldSearch(for:foodItems:)`` to decide whether a typed description is a specific branded
/// product (and not already imported) before offering the web route.
enum FoodProductWebSearch {
    /// Whether `description` names a specific retail/branded product worth a web lookup: it must
    /// carry a retailer/brand signal, have at least two meaningful tokens, and not already match a
    /// previously web-imported (`aiResolved`) food item.
    static func shouldSearch(for description: String, foodItems: [FoodItem]) -> Bool {
        let normalized = FoodItemSearch.normalized(description)
        let retailerTerms = [
            "costco", "kirkland", "trader joe", "whole foods", "aldi", "walmart",
            "target", "starbucks", "sandwich bros"
        ]
        let isSpecificProduct = normalized.contains(" from ")
            || retailerTerms.contains(where: normalized.contains)
            || FoodBrandLexicon.queryContainsBrandToken(description)
        guard isSpecificProduct else { return false }

        let queryTokens = meaningfulTokens(in: normalized)
        guard queryTokens.count >= 2 else { return false }
        return !foodItems.contains { foodItem in
            guard foodItem.source == .aiResolved else { return false }
            let foodTokens = meaningfulTokens(in: FoodItemSearch.normalized(foodItem.name))
            return queryTokens.intersection(foodTokens).count >= min(2, foodTokens.count)
        }
    }

    /// Searches the web for "`query` nutrition facts" and returns the highest-priority result as a
    /// ``ProductPagePreview``.
    /// - Throws: ``FoodProductWebImportError/productNotFound`` when no usable result parses.
    static func preview(for query: String) async throws -> ProductPagePreview {
        // R5: nothing egresses for an empty/whitespace query — a blank search would return whatever
        // the engine's front page lists.
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw FoodProductWebImportError.productNotFound
        }
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: "\(trimmedQuery) nutrition facts")]
        guard let url = components?.url else {
            throw FoodProductWebImportError.invalidURL
        }
        let html = try await FoodProductWebImporter.fetchHTML(from: url)
        guard let result = preferredSearchResults(from: html).first else {
            throw FoodProductWebImportError.productNotFound
        }
        return result
    }

    /// The parsed search results reordered by source priority — retailer/chain hosts first,
    /// secondary nutrition aggregators demoted.
    static func preferredSearchResults(from html: String) -> [ProductPagePreview] {
        searchResults(from: html).sorted { first, second in
            sourcePriority(for: first.sourceURL) > sourcePriority(for: second.sourceURL)
        }
    }

    /// Extracts deduplicated (URL, title) result links from the search page's HTML, unwrapping
    /// DuckDuckGo `uddg` redirects and keeping only https, non-DuckDuckGo destinations.
    static func searchResults(from html: String) -> [ProductPagePreview] {
        let pattern = #"(?is)<a\b([^>]*)>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        var seen = Set<URL>()
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let attributesRange = Range(match.range(at: 1), in: html),
                  let titleRange = Range(match.range(at: 2), in: html),
                  let href = firstCapture(in: String(html[attributesRange]), pattern: #"(?is)\bhref\s*=\s*["'](.*?)["']"#),
                  let url = resultURL(from: href),
                  seen.insert(url).inserted else {
                return nil
            }
            let title = plainText(String(html[titleRange]))
            guard !title.isEmpty else { return nil }
            return ProductPagePreview(sourceURL: url, title: title)
        }
    }

    private static func resultURL(from href: String) -> URL? {
        let decodedHref = FoodProductWebImporter.htmlDecoded(href)
        guard let url = URL(string: decodedHref, relativeTo: URL(string: "https://duckduckgo.com"))?.absoluteURL else {
            return nil
        }
        if url.host()?.contains("duckduckgo.com") == true,
           let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
           let redirect = components.queryItems?.first(where: { $0.name == "uddg" })?.value,
           let redirectedURL = URL(string: redirect),
           redirectedURL.scheme == "https",
           !(redirectedURL.host()?.contains("duckduckgo.com") ?? false) {
            return redirectedURL
        }
        guard url.scheme == "https",
              url.host()?.contains("duckduckgo.com") != true else {
            return nil
        }
        return url
    }

    private static func meaningfulTokens(in normalizedText: String) -> Set<String> {
        let ignored: Set<String> = [
            "from", "costco", "kirkland", "trader", "joe", "whole", "foods", "aldi",
            "walmart", "target", "starbucks", "sandwich", "bros", "count", "pack"
        ]
        return Set(normalizedText.split(separator: " ").map(String.init).filter {
            $0.count >= 3 && Double($0) == nil && !ignored.contains($0)
        })
    }

    private static func sourcePriority(for url: URL) -> Int {
        let host = url.host()?.lowercased() ?? ""
        let preferredHosts = [
            "costco.com", "costco-static.com", "sandwichbros.com", "kirkland.com",
            "traderjoes.com", "wholefoodsmarket.com", "walmart.com", "target.com",
            "chipotle.com", "tacobell.com", "mcdonalds.com", "wendys.com",
            "burgerking.com", "subway.com", "starbucks.com", "chick-fil-a.com",
            "dominos.com", "pizzahut.com", "kfc.com", "popeyes.com", "panerabread.com"
        ]
        if preferredHosts.contains(where: { preferred in host == preferred || host.hasSuffix("." + preferred) }) {
            return 20
        }
        let secondaryNutritionHosts = ["fatsecret.com", "snapcalorie.com", "myfooddiary.com"]
        if secondaryNutritionHosts.contains(where: { preferred in host == preferred || host.hasSuffix("." + preferred) }) {
            return -10
        }
        return 0
    }

    private static func plainText(_ html: String) -> String {
        FoodProductWebImporter.htmlDecoded(
            html.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        )
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
    }

    /// The href out of an `<a>` tag's attributes.
    ///
    /// Routes to `WebScrapingKit`. This helper used to read capture group **1** where
    /// ``FoodProductWebImporter``'s read the *last* group; for its single-capture-group href pattern
    /// the two indices are the same group, so the shared last-group rule is exact here.
    private static func firstCapture(in text: String, pattern: String) -> String? {
        HTMLScraper.firstMatchLastCapture(in: text, pattern: pattern)
    }
}

/// A packaged food's per-serving nutrition as extracted from its web page, ready for user
/// confirmation.
///
/// The unit of exchange across the web-import flow: built by ``FoodProductWebImporter``, reviewed in
/// `FoodProductReviewSheet`, and persisted as an `aiResolved` catalog `FoodItem` via
/// `FernletStore.saveWebImportedFoodProduct` only after the user confirms. `lookupQuery` carries the
/// text the user originally typed so repeat lookups hit the cache. The second initializer rebuilds
/// one from an already-saved `FoodItem` for the cached-product fast path.
struct ImportedFoodProduct: Equatable {
    var sourceURL: URL
    var name: String
    var brand: String?
    var servingSize: String
    var calories: Int? = nil
    var macros: Macros
    var micronutrients: Micronutrients
    var lookupQuery: String? = nil

    init(
        sourceURL: URL,
        name: String,
        brand: String?,
        servingSize: String,
        calories: Int? = nil,
        macros: Macros,
        micronutrients: Micronutrients,
        lookupQuery: String? = nil
    ) {
        self.sourceURL = sourceURL
        self.name = name
        self.brand = brand
        self.servingSize = servingSize
        self.calories = calories
        self.macros = macros
        self.micronutrients = micronutrients
        self.lookupQuery = lookupQuery
    }

    init(foodItem: FoodItem, lookupQuery: String) {
        self.sourceURL = foodItem.sourceURL ?? URL(fileURLWithPath: "/")
        self.name = foodItem.name
        self.brand = foodItem.brandSource
        self.servingSize = foodItem.servingDescription ?? "1 serving"
        self.calories = foodItem.calories
        self.macros = foodItem.macros
        self.micronutrients = foodItem.micronutrients
        self.lookupQuery = lookupQuery
    }
}

/// Every way a web product lookup/import can fail, with a user-facing sentence for each.
///
/// Thrown across ``FoodProductWebSearch`` and ``FoodProductWebImporter``; the import screen shows
/// `errorDescription` as its calm inline notice rather than a hard error.
enum FoodProductWebImportError: LocalizedError {
    case invalidURL
    case fetchFailed
    case emptyHTML
    case productNotFound
    case nutritionNotFound
    case modelUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            "Enter a valid product page URL."
        case .fetchFailed:
            "Could not fetch that product page."
        case .emptyHTML:
            "The page did not return readable HTML."
        case .productNotFound:
            "Fernlet could not identify a product on that page."
        case .nutritionNotFound:
            "Fernlet could not find a complete nutrition label on that page."
        case .modelUnavailable:
            "The page did not include structured nutrition data, and on-device extraction is not available."
        }
    }
}

/// Extracts one packaged food's nutrition from a product web page, trying progressively less
/// structured sources: schema.org JSON-LD → visible nutrition-facts text → OCR over candidate label
/// images → a last-resort on-device Foundation Models extraction over the cleaned body text.
///
/// The workhorse behind the "Import product" flow (and the barcode TODO's future opt-in). Runs only
/// behind the web-nutrition-lookup opt-in; fetches are https-only, size-capped (3 MB HTML, 12 MB
/// images), and 15-second-bounded. Only the model tier touches AI — it routes through `FernletAIGate`,
/// is audited in `AIAuditLog`, and its output must pass per-field bounds plus a macro-calorie
/// consistency check before it is believed. Every tier funnels into ``ImportedFoodProduct``, which is
/// never persisted until the user confirms in the review sheet.
enum FoodProductWebImporter {
    /// Normalizes free text into an https product-page URL (prefixing `https://` when the scheme is
    /// missing), or `nil` when it can't be a valid web URL.
    static func normalizedWebURL(from text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://\(trimmed)"
        guard let url = URL(string: candidate),
              url.scheme == "https",
              url.host() != nil else {
            return nil
        }
        return url
    }

    /// Fetches `url` and builds its preview (JSON-LD product name → og:title → `<title>` → host).
    /// A fetch failure falls back to a web search built from the URL's path slug, so a dead or
    /// bot-walled product link can still resolve to a working page.
    static func preview(from url: URL) async throws -> ProductPagePreview {
        let html: String
        do {
            html = try await fetchHTML(from: url)
        } catch FoodProductWebImportError.fetchFailed {
            return try await FoodProductWebSearch.preview(for: fallbackSearchText(from: url))
        }
        let title = productDictionary(in: html).flatMap { stringValue($0["name"]) }
            ?? metadataContent(named: "og:title", in: html)
            ?? firstCapture(in: html, pattern: #"(?is)<title\b[^>]*>(.*?)</title>"#)
            ?? url.host()
            ?? url.absoluteString
        return ProductPagePreview(sourceURL: url, title: htmlDecoded(title))
    }

    /// A human-ish search query recovered from a URL's path slug (numbers and boilerplate path
    /// segments dropped, hyphens spaced), for when the page itself couldn't be fetched.
    static func fallbackSearchText(from url: URL) -> String {
        let ignoredPathComponents: Set<String> = ["p", "product", "products", "-"]
        let slug = url.pathComponents
            .filter { $0 != "/" && Double($0) == nil && !ignoredPathComponents.contains($0.lowercased()) }
            .joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ")
        return slug.isEmpty ? (url.host() ?? url.absoluteString) : slug
    }

    /// Runs the full extraction ladder over the previewed page: a direct image URL is OCR'd as a
    /// label; otherwise structured JSON-LD, visible nutrition text, candidate label images, and
    /// finally the gated on-device model are tried in order.
    /// - Returns: The first tier's complete ``ImportedFoodProduct``.
    /// - Throws: A ``FoodProductWebImportError`` when every tier comes up empty.
    static func importProduct(from preview: ProductPagePreview, gate: FernletAIGate) async throws -> ImportedFoodProduct {
        #if canImport(UIKit)
        if isDirectImageURL(preview.sourceURL),
           let product = await productFromNutritionLabelImage(
               at: preview.sourceURL,
               fallbackName: preview.title,
               sourceURL: preview.sourceURL
           ) {
            return product
        }
        #endif
        let html: String
        do {
            html = try await fetchHTML(from: preview.sourceURL)
        } catch {
            throw error
        }
        if let product = structuredProduct(from: html, sourceURL: preview.sourceURL) {
            return product
        }
        if let product = productFromVisibleNutritionText(
            in: html,
            fallbackName: preview.title,
            sourceURL: preview.sourceURL
        ) {
            return product
        }
        #if canImport(UIKit)
        if let product = await productFromNutritionLabelImages(
            in: html,
            fallbackName: preview.title,
            sourceURL: preview.sourceURL
        ) {
            return product
        }
        #endif
        let cleanedText = try cleanedBodyText(from: html)
        return try await extractWithFoundationModel(from: cleanedText, fallbackName: preview.title, sourceURL: preview.sourceURL, gate: gate)
    }

    /// The structured tier: a product built from the page's schema.org JSON-LD `Product` +
    /// `nutrition` data, or `nil` when the page carries none (or the macros are incomplete).
    static func structuredProduct(from html: String, sourceURL: URL) -> ImportedFoodProduct? {
        guard let dictionary = productDictionary(in: html) else { return nil }
        return importedProduct(from: dictionary, sourceURL: sourceURL)
    }

    static func candidateImageURLs(from html: String, sourceURL: URL) -> [URL] {
        supplementalNutritionLabelURLs(from: html, sourceURL: sourceURL)
    }

    static func supplementalNutritionLabelURLs(from html: String, sourceURL: URL) -> [URL] {
        let candidates = imageCandidates(from: html, sourceURL: sourceURL)
            .map { candidate in
                (url: candidate.url, score: imageCandidateScore(candidate, sourceURL: sourceURL))
            }
            .filter { $0.score > 0 }
            .sorted { first, second in
                if first.score != second.score { return first.score > second.score }
                return first.url.absoluteString.localizedStandardCompare(second.url.absoluteString) == .orderedAscending
            }

        var seen = Set<String>()
        return candidates.compactMap { candidate in
            let key = canonicalImageURLKey(candidate.url)
            guard seen.insert(key).inserted else { return nil }
            return candidate.url
        }
    }

    static func isDirectImageURL(_ url: URL) -> Bool {
        let pathExtension = url.pathExtension.lowercased()
        let imageExtensions = ["jpg", "jpeg", "png", "webp", "heic", "gif"]
        let imageHost = url.host()?.lowercased() ?? ""
        return imageExtensions.contains(pathExtension)
            || imageHost == "costco-static.com" || imageHost.hasSuffix(".costco-static.com")
            || URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .contains(where: { item in
                    ["format", "auto"].contains(item.name)
                        && ["jpg", "jpeg", "png", "webp"].contains(item.value?.lowercased())
                }) == true
    }

    /// Fetches a page as HTML with a Safari-like User-Agent: https-only, 15 s timeout, 2xx +
    /// text/html content-type required, and the body capped at 3 MB (streamed so an oversized page
    /// aborts early).
    ///
    /// Transport is `WebScrapingKit`'s `EphemeralWebSession` — no cookie jar, no cache, no credential
    /// store — so a retailer page cannot set state during one lookup and read it back during the
    /// next. Everything *else* here is this importer's own policy and deliberately differs from the
    /// recipe importer's: the https guard is inline (not the SSRF helper), the User-Agent spoofs
    /// Safari so retailer bot-walls serve real markup, the content-type check reads the raw header
    /// string, and an over-cap body THROWS rather than truncating (a half-read nutrition table is
    /// worse than no table).
    /// - Throws: ``FoodProductWebImportError/fetchFailed`` / `emptyHTML` / `invalidURL`.
    static func fetchHTML(from url: URL) async throws -> String {
        guard url.scheme == "https" else {
            throw FoodProductWebImportError.invalidURL
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            (asyncBytes, response) = try await EphemeralWebSession.shared.bytes(for: request)
        } catch {
            throw FoodProductWebImportError.fetchFailed
        }
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw FoodProductWebImportError.fetchFailed
        }
        let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type") ?? ""
        guard contentType.contains("text/html") || contentType.contains("application/xhtml") else {
            throw FoodProductWebImportError.fetchFailed
        }
        let maxBytes = 3 * 1024 * 1024
        var data = Data()
        data.reserveCapacity(min(256 * 1024, maxBytes))
        for try await byte in asyncBytes {
            data.append(byte)
            if data.count > maxBytes {
                throw FoodProductWebImportError.fetchFailed
            }
        }
        let html = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1)
        guard let html, !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FoodProductWebImportError.emptyHTML
        }
        return html
    }

    private static func productDictionary(in html: String) -> [String: Any]? {
        for rawJSON in JSONLDScraper.scriptContents(from: html) {
            guard let data = htmlDecoded(rawJSON).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let product = JSONLDScraper.object(ofType: "Product", in: object) else {
                continue
            }
            return product
        }
        return nil
    }

    // `productObject` / `schemaTypes` now live in WebScrapingKit as
    // `JSONLDScraper.object(ofType:in:)` / `JSONLDScraper.schemaTypes(in:)`, shared with the recipe
    // importer. The algorithm is unchanged for this side — the search order and the lowercased
    // `@type` comparison are exactly what `productObject` did.

    private static func importedProduct(from dictionary: [String: Any], sourceURL: URL) -> ImportedFoodProduct? {
        guard let name = stringValue(dictionary["name"]), let nutrition = nutritionDictionary(from: dictionary) else {
            return nil
        }
        return importedProduct(
            sourceURL: sourceURL,
            name: name,
            brand: brandName(from: dictionary["brand"]),
            servingSize: stringValue(nutrition["servingSize"]) ?? "1 serving",
            calories: nutritionDoubleValue(nutrition["calories"]).flatMap { Int(exactly: $0.rounded()) },
            protein: nutritionDoubleValue(nutrition["proteinContent"]),
            carbs: nutritionDoubleValue(nutrition["carbohydrateContent"]),
            fat: nutritionDoubleValue(nutrition["fatContent"]),
            micronutrients: Micronutrients(
                fiber: nutritionDoubleValue(nutrition["fiberContent"]),
                sugar: nutritionDoubleValue(nutrition["sugarContent"]),
                saturatedFat: nutritionDoubleValue(nutrition["saturatedFatContent"]),
                cholesterol: nutritionDoubleValue(nutrition["cholesterolContent"]),
                sodium: nutritionDoubleValue(nutrition["sodiumContent"])
            )
        )
    }

    fileprivate static func importedProduct(
        sourceURL: URL,
        name: String,
        brand: String?,
        servingSize: String,
        calories: Int? = nil,
        protein: Double?,
        carbs: Double?,
        fat: Double?,
        micronutrients: Micronutrients
    ) -> ImportedFoodProduct? {
        guard let protein, let carbs, let fat else { return nil }
        // R5: the macros arrive from untrusted page JSON-LD / model output, where `Int(Double)` would
        // trap on an out-of-range magnitude. A value that cannot be represented is no product at all.
        guard let proteinGrams = Int(exactly: protein.rounded()),
              let carbGrams = Int(exactly: carbs.rounded()),
              let fatGrams = Int(exactly: fat.rounded()) else {
            return nil
        }
        return ImportedFoodProduct(
            sourceURL: sourceURL,
            name: name,
            brand: brand,
            servingSize: servingSize,
            calories: calories,
            macros: Macros(protein: proteinGrams, carbs: carbGrams, fat: fatGrams),
            micronutrients: micronutrients
        )
    }

    private static func nutritionDictionary(from dictionary: [String: Any]) -> [String: Any]? {
        if let nutrition = dictionary["nutrition"] as? [String: Any] {
            return nutrition
        }
        return (dictionary["nutrition"] as? [[String: Any]])?.first
    }

    private static func brandName(from value: Any?) -> String? {
        if let brand = stringValue(value) {
            return brand
        }
        return (value as? [String: Any]).flatMap { stringValue($0["name"]) }
    }

    /// The visible-text tier: flattens the page body to lines, normalizes shorthand ("fat 5g" →
    /// "Total Fat 5g"), and runs the shared `NutritionLabelScanner` line parser over them.
    static func productFromVisibleNutritionText(in html: String, fallbackName: String, sourceURL: URL) -> ImportedFoodProduct? {
        var lines: [String] = []
        for line in visibleTextLines(from: html) {
            lines.append(normalizedWebNutritionLine(line))
        }
        if let servingSize = inferredServingSize(from: html) {
            lines.append("Serving size \(servingSize)")
        }
        let result = NutritionLabelScanner.parse(lines: lines)
        return importedProduct(from: result, fallbackName: productName(from: fallbackName), sourceURL: sourceURL)
    }

    #if canImport(UIKit)
    /// R3: how many scraped candidate images the OCR tier will fetch, however many the page carries.
    private static let maxLabelImagesToScan = 8

    private static func productFromNutritionLabelImages(in html: String, fallbackName: String, sourceURL: URL) async -> ImportedFoodProduct? {
        for imageURL in candidateImageURLs(from: html, sourceURL: sourceURL).prefix(maxLabelImagesToScan) {
            if let product = await productFromNutritionLabelImage(
                at: imageURL,
                fallbackName: fallbackName,
                sourceURL: sourceURL
            ) {
                return product
            }
        }
        return nil
    }

    private static func productFromNutritionLabelImage(at imageURL: URL, fallbackName: String, sourceURL: URL) async -> ImportedFoodProduct? {
        guard let image = await fetchImage(from: imageURL) else { return nil }
        guard let scanned = try? await NutritionLabelScanner.scanAll(image: image).primary else { return nil }
        guard isCompleteNutritionLabelScan(scanned) else { return nil }
        return importedProduct(from: scanned, fallbackName: fallbackName, sourceURL: sourceURL)
    }

    /// Fetches one candidate label image through the recipe importer's guarded image downloader —
    /// upgraded (2026-08-09) from a bare https-scheme check to the full page-fetch guard rigor:
    /// SSRF host validation, per-hop redirect re-validation, an image MIME requirement (`image/*`,
    /// or a generic octet-stream declaration whose bytes pass the magic-number sniff — retailer
    /// CDNs serving label images off S3-style origins with no content-type metadata keep working,
    /// HTML error pages don't), the 15 s timeout, and a streaming 12 MB cap that aborts oversize
    /// bodies instead of buffering them whole. Transport stays `EphemeralWebSession.shared`
    /// (inside the downloader), and this importer's Safari User-Agent spoof is preserved so
    /// retailer CDNs keep serving real images.
    private static func fetchImage(from url: URL) async -> UIImage? {
        guard let data = try? await RecipeWebImporter.downloadImage(
            from: url,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1",
            maxBytes: 12_000_000
        ) else { return nil }
        return UIImage(data: data)
    }
    #endif

    private static func importedProduct(from result: NutritionLabelResult, fallbackName: String, sourceURL: URL) -> ImportedFoodProduct? {
        importedProduct(
            sourceURL: sourceURL,
            name: productName(from: fallbackName),
            brand: sourceURL.host(),
            servingSize: result.servingSize ?? "1 serving",
            calories: result.calories,
            protein: result.protein.map(Double.init),
            carbs: result.carbs.map(Double.init),
            fat: result.fat.map(Double.init),
            micronutrients: result.micronutrients()
        )
    }

    /// Whether an OCR'd label scan is complete enough to trust from an arbitrary web image: serving
    /// size, calories, and all three macros must all be present. Guards the image tier against
    /// accepting a partial read off a lifestyle photo.
    static func isCompleteNutritionLabelScan(_ result: NutritionLabelResult) -> Bool {
        guard let servingSize = result.servingSize?.trimmingCharacters(in: .whitespacesAndNewlines),
              servingSize.isEmpty == false,
              result.calories != nil,
              result.protein != nil,
              result.carbs != nil,
              result.fat != nil else {
            return false
        }
        return true
    }

    /// Last-resort on-device model extraction (`standard` tier, user-invoked — the user searched for
    /// / pasted a product). Routes through `gate`: capability cap + sleepy/resting budget + one-call
    /// charge. A fallback result surfaces as `.modelUnavailable`, matching the prior
    /// no-on-device-model behavior.
    private static func extractWithFoundationModel(from text: String, fallbackName: String, sourceURL: URL, gate: FernletAIGate) async throws -> ImportedFoodProduct {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard let destination = gate.dispatch(tier: .standard, userInvoked: true) else {
                throw FoodProductWebImportError.modelUnavailable
            }

            let payload = WebPageNutritionExtractionPayload(
                sourceHost: sourceURL.host() ?? "unknown",
                cleanedTextCharCount: text.count
            )
            let auditKind = payload.payloadKind
            let auditFields = payload.includedFieldNames

            let instructions = """
            Extract nutrition facts for one packaged food product from webpage text.
            Use values for one labeled serving. Do not estimate or invent values.
            Return an empty string for any value that is not explicitly present.
            Keep numeric nutrition values in their original text form, including units.
            """
            let prompt = """
            Fallback product name: \(fallbackName)

            Cleaned webpage text:
            \(text)
            """
            let session = LanguageModelSession(instructions: instructions)
            do {
                let response = try await session.respond(to: prompt, generating: ExtractedFoodProduct.self)
                guard let product = response.content.importedProduct(sourceURL: sourceURL, fallbackName: fallbackName) else {
                    throw FoodProductWebImportError.nutritionNotFound
                }
                guard isPlausibleModelExtraction(product) else {
                    throw FoodProductWebImportError.nutritionNotFound
                }
                await AIAuditLog.shared.record(
                    payloadKind: auditKind,
                    destination: destination,
                    modelIdentifier: AIAuditEntry.onDeviceFoundationModel,
                    includedFields: auditFields,
                    outcome: .succeeded
                )
                return product
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
        throw FoodProductWebImportError.modelUnavailable
    }

    /// Whether a model-extracted product may be believed: per-field macro bounds always, plus a
    /// macro-calorie consistency check when the model also reported calories (R5).
    ///
    /// The field bounds are deliberately outside the calories branch — a calorie-less answer is still
    /// model output and must clear the same per-field checks.
    private static func isPlausibleModelExtraction(_ product: ImportedFoodProduct) -> Bool {
        let p = product.macros.protein, c = product.macros.carbs, f = product.macros.fat
        guard p >= 0, p <= 500, c >= 0, c <= 1000, f >= 0, f <= 500 else { return false }
        guard let reportedCalories = product.calories else { return true }
        let allowedLow = max(0, reportedCalories / 2 - 50)
        let allowedHigh = reportedCalories * 2 + 100
        let macroCalories = product.macros.calories
        return reportedCalories >= 0 && reportedCalories <= 5000
            && macroCalories >= allowedLow && macroCalories <= allowedHigh
    }

    /// Reduces the page to model-ready plain text for the last-resort model tier.
    ///
    /// The pass itself is `WebScrapingKit`'s; only the *empty-page* verdict is this importer's, which
    /// is why the shared helper returns `nil` instead of throwing — `.productNotFound` carries product
    /// copy the recipe importer's `.noRecipeFound` does not.
    private static func cleanedBodyText(from html: String) throws -> String {
        guard let text = HTMLScraper.cleanedBodyText(from: html, decodingNumericEntities: false) else {
            throw FoodProductWebImportError.productNotFound
        }
        return text
    }

    private static func visibleTextLines(from html: String) -> [String] {
        let bodyHTML = firstCapture(in: html, pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#) ?? html
        let withLineBreaks = bodyHTML.replacingOccurrences(
            of: #"(?is)</?(?:br|p|li|tr|td|th|section|article|h[1-6])\b[^>]*>"#,
            with: "\n",
            options: .regularExpression
        )
        let withoutTags = withLineBreaks.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression)
        return htmlDecoded(withoutTags)
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func normalizedWebNutritionLine(_ line: String) -> String {
        let lower = line.lowercased()
        if lower.hasPrefix("fat ") {
            return "Total Fat \(line.dropFirst(4))"
        }
        if lower.hasPrefix("carbs ") {
            return "Total Carbohydrate \(line.dropFirst(6))"
        }
        return line
    }

    private static func inferredServingSize(from html: String) -> String? {
        let decodedHTML = htmlDecoded(html)
        return firstCapture(
            in: decodedHTML,
            pattern: #"(?is)\bcalories\s+in\s+(.+?)\s+of\b"#
        )
    }

    private static func productName(from fallbackName: String) -> String {
        fallbackName
            .replacingOccurrences(of: #"(?i)^calories\s+in\s+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+and\s+nutrition\s+facts.*$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A possible nutrition-label image scraped from the page: its URL plus the surrounding
    /// attribute/JSON context used to score it.
    ///
    /// Candidates from `<img>`/`<source>` tags, social metadata, JSON-LD, and raw embedded URLs are
    /// scored by label-ish context terms, then the top few are fetched and OCR'd.
    private struct ImageCandidate {
        var url: URL
        var context: String
    }

    private static func imageCandidates(from html: String, sourceURL: URL) -> [ImageCandidate] {
        var candidates: [ImageCandidate] = []
        candidates.append(contentsOf: elementImageCandidates(tag: "img", html: html, sourceURL: sourceURL))
        candidates.append(contentsOf: elementImageCandidates(tag: "source", html: html, sourceURL: sourceURL))
        candidates.append(contentsOf: metadataImageCandidates(from: html, sourceURL: sourceURL))
        candidates.append(contentsOf: jsonLDImageCandidates(from: html, sourceURL: sourceURL))
        candidates.append(contentsOf: embeddedImageCandidates(from: html, sourceURL: sourceURL))
        return candidates
    }

    private static func elementImageCandidates(tag: String, html: String, sourceURL: URL) -> [ImageCandidate] {
        let escapedTag = NSRegularExpression.escapedPattern(for: tag)
        let pattern = #"(?is)<\#(escapedTag)\b([^>]*)>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).flatMap { match -> [ImageCandidate] in
            guard let attributesRange = Range(match.range(at: 1), in: html) else { return [] }
            let attributes = htmlDecoded(String(html[attributesRange]))
            return imageSources(in: attributes).compactMap { source in
                normalizedImageURL(from: source, relativeTo: sourceURL).map { ImageCandidate(url: $0, context: attributes) }
            }
        }
    }

    private static func metadataImageCandidates(from html: String, sourceURL: URL) -> [ImageCandidate] {
        let names = ["og:image", "og:image:url", "twitter:image", "twitter:image:src", "image"]
        return names.compactMap { name in
            metadataContent(named: name, in: html).flatMap { source in
                normalizedImageURL(from: source, relativeTo: sourceURL).map { ImageCandidate(url: $0, context: name) }
            }
        }
    }

    private static func jsonLDImageCandidates(from html: String, sourceURL: URL) -> [ImageCandidate] {
        JSONLDScraper.scriptContents(from: html).flatMap { rawJSON -> [ImageCandidate] in
            guard let data = htmlDecoded(rawJSON).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) else { return [] }
            return imageValues(in: object).compactMap { source in
                normalizedImageURL(from: source, relativeTo: sourceURL).map { ImageCandidate(url: $0, context: "json-ld image") }
            }
        }
    }

    private static func embeddedImageCandidates(from html: String, sourceURL: URL) -> [ImageCandidate] {
        let decodedHTML = htmlDecoded(html)
        let pattern = #"(?i)(https?:\\?/\\?/[^\s"'<>]+?\.(?:jpg|jpeg|png|webp|gif)(?:\?[^\s"'<>]+)?)"#
        return allCaptures(in: decodedHTML, pattern: pattern).compactMap { source in
            let cleaned = source.replacingOccurrences(of: "\\/", with: "/")
            return normalizedImageURL(from: cleaned, relativeTo: sourceURL).map { ImageCandidate(url: $0, context: cleaned) }
        }
    }

    private static func imageSources(in attributes: String) -> [String] {
        var sources: [String] = []
        for attribute in ["src", "data-src", "data-original", "data-lazy", "data-lazy-src", "data-zoom", "data-image"] {
            let escapedAttribute = NSRegularExpression.escapedPattern(for: attribute)
            if let source = firstCapture(
                in: attributes,
                pattern: #"(?is)\b\#(escapedAttribute)\s*=\s*["'](.*?)["']"#
            ) {
                sources.append(source)
            }
        }
        for attribute in ["srcset", "data-srcset"] {
            let escapedAttribute = NSRegularExpression.escapedPattern(for: attribute)
            if let sourceSet = firstCapture(
                in: attributes,
                pattern: #"(?is)\b\#(escapedAttribute)\s*=\s*["'](.*?)["']"#
            ) {
                sources.append(contentsOf: imageSources(fromSourceSet: sourceSet))
            }
        }
        return sources
    }

    private static func imageSources(fromSourceSet sourceSet: String) -> [String] {
        sourceSet.split(separator: ",").compactMap { entry in
            entry.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .first
                .map(String.init)
        }
    }

    /// R1/R2: the JSON-LD comes from an arbitrary page, so the walk is an explicitly bounded worklist
    /// — this is the maximum number of nodes visited, whatever nesting the page ships.
    private static let maxJSONLDNodes = 4_096

    /// Every image-ish string value reachable from a JSON-LD node (`image`, `@graph`, and an
    /// `ImageObject`'s `url`), collected by a bounded worklist rather than recursion.
    ///
    /// Pushing children reversed keeps the left-to-right, depth-first order the recursive form had.
    private static func imageValues(in object: Any) -> [String] {
        var work: [Any] = [object]
        var values: [String] = []
        var budget = maxJSONLDNodes
        while let node = work.popLast(), budget > 0 {
            budget -= 1
            if let string = node as? String {
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { values.append(trimmed) }
            } else if let array = node as? [Any] {
                work.append(contentsOf: array.reversed())
            } else if let dictionary = node as? [String: Any] {
                var children: [Any] = []
                if let image = dictionary["image"] { children.append(image) }
                if let graph = dictionary["@graph"] { children.append(graph) }
                if JSONLDScraper.schemaTypes(in: dictionary).contains("imageobject"), let url = dictionary["url"] {
                    children.append(url)
                }
                work.append(contentsOf: children.reversed())
            }
        }
        return values
    }

    private static func normalizedImageURL(from source: String, relativeTo sourceURL: URL) -> URL? {
        let trimmed = source.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("data:"),
              let url = URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL,
              url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    private static func imageCandidateScore(_ candidate: ImageCandidate, sourceURL: URL) -> Int {
        let context = FoodItemSearch.normalized("\(candidate.context) \(candidate.url.absoluteString)")
        let discardTerms = ["logo", "icon", "sprite", "avatar", "badge", "favicon", "placeholder", "tracking", "pixel", "spinner", "lifestyle", "serving suggestion"]
        if discardTerms.contains(where: { context.contains(FoodItemSearch.normalized($0)) }) { return 0 }
        if isTinyImageHint(candidate.context) { return 0 }

        var score = 0
        let strongTerms = ["nutrition facts", "nutrition", "nutritional", "facts", "label", "supplement", "ingredients"]
        for term in strongTerms where context.contains(FoodItemSearch.normalized(term)) {
            score += 40
        }
        let galleryTerms = ["gallery", "product", "media", "carousel", "alternate", "secondary", "zoom"]
        let hasGalleryHint = galleryTerms.contains { context.contains($0) }
        guard score > 0 || hasGalleryHint else { return 0 }
        if hasGalleryHint { score += 12 }
        if isSameSiteOrCDN(candidate.url, sourceURL: sourceURL) { score += 10 }
        if isDirectImageURL(candidate.url) { score += 8 }
        if context.contains("thumb") || context.contains("thumbnail") { score -= 20 }
        return max(score, 0)
    }

    private static func isSameSiteOrCDN(_ imageURL: URL, sourceURL: URL) -> Bool {
        let imageHost = imageURL.host()?.lowercased() ?? ""
        let sourceHost = sourceURL.host()?.lowercased() ?? ""
        guard !imageHost.isEmpty, !sourceHost.isEmpty else { return false }
        if imageHost == sourceHost || imageHost.hasSuffix("." + sourceHost) { return true }
        let sourceParts = sourceHost.split(separator: ".")
        let sourceRoot = sourceParts.suffix(2).joined(separator: ".")
        return !sourceRoot.isEmpty && (imageHost == sourceRoot || imageHost.hasSuffix("." + sourceRoot))
    }

    private static func isTinyImageHint(_ context: String) -> Bool {
        let width = firstCapture(in: context, pattern: #"(?is)\bwidth\s*=\s*["']?(\d+)"#).flatMap(Int.init)
        let height = firstCapture(in: context, pattern: #"(?is)\bheight\s*=\s*["']?(\d+)"#).flatMap(Int.init)
        if let width, width <= 96 { return true }
        if let height, height <= 96 { return true }
        return false
    }

    private static func canonicalImageURLKey(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return url.absoluteString
        }
        components.queryItems = components.queryItems?.filter { item in
            !["width", "height", "w", "h", "fit", "canvas", "auto", "format"].contains(item.name.lowercased())
        }
        return components.url?.absoluteString ?? url.absoluteString
    }

    /// Delegates to the shared `HTMLScraper.metaContent(named:in:)` — an identical pattern that was
    /// hand-copied here before the helper existed; behavior-preserving by construction.
    private static func metadataContent(named property: String, in html: String) -> String? {
        HTMLScraper.metaContent(named: property, in: html)
    }

    /// The largest nutrition magnitude a real label can carry (per serving, in the label's own unit).
    /// R5: page/model text is untrusted, and anything past this is a parsing artifact — rejecting it
    /// here keeps every downstream `Int(...)` conversion inside range.
    private static let maxPlausibleNutrientValue = 100_000.0

    fileprivate static func nutritionDoubleValue(_ value: Any?) -> Double? {
        guard let string = stringValue(value) else { return nil }
        let normalized = Self.normalizeDecimalSeparator(string)
        let numeric = normalized.prefix(while: { $0.isNumber || $0 == "." })
        guard let parsed = Double(numeric), parsed.isFinite,
              parsed >= 0, parsed <= Self.maxPlausibleNutrientValue else {
            return nil
        }
        return parsed
    }

    private static func normalizeDecimalSeparator(_ string: String) -> String {
        let commaCount = string.filter { $0 == "," }.count
        guard commaCount > 0 else { return string }
        if commaCount > 1 {
            return string.replacingOccurrences(of: ",", with: "")
        }
        // Single comma: 3-digit group = thousands separator; 1-2-digit group = decimal separator.
        let isThousands = string.range(of: #",\d{3}(?!\d)"#, options: .regularExpression) != nil
        return string.replacingOccurrences(of: ",", with: isThousands ? "" : ".")
    }

    fileprivate static func stringValue(_ value: Any?) -> String? {
        if let string = value as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        return (value as? NSNumber)?.stringValue
    }

    private static func allCaptures(in text: String, pattern: String) -> [String] {
        HTMLScraper.allLastCaptures(in: text, pattern: pattern)
    }

    /// The last capture of the first *usable* match.
    ///
    /// Kept as `allCaptures(...).first` rather than `HTMLScraper.firstMatchLastCapture` because the
    /// two differ when a first match's capture group does not participate: this form falls through to
    /// the next match, that one returns nil. Every pattern here has a mandatory trailing group so they
    /// agree today, but the shape this file has always had is the one it keeps.
    private static func firstCapture(in text: String, pattern: String) -> String? {
        allCaptures(in: text, pattern: pattern).first
    }

    /// This importer's entity-decoding policy: named entities ONLY — a numeric character reference
    /// (`&#8217;`) is left as literal text.
    ///
    /// The machinery is shared with the recipe importer via `WebScrapingKit`, but the policy is not:
    /// that importer also decodes numeric references. The difference changes what an href and a
    /// JSON-LD blob look like after decoding, so it is a required parameter there rather than a
    /// guess. Kept as a one-line shim so this file states its policy in exactly one place.
    /// (`&amp;` is still decoded last inside the shared helper, so double-encoded text unwraps one
    /// layer per pass exactly as before.)
    static func htmlDecoded(_ text: String) -> String {
        HTMLScraper.htmlDecoded(text, decodingNumericEntities: false)
    }
}

#if canImport(FoundationModels)
/// The `@Generable` schema for the last-resort on-device model extraction: every field is a raw
/// string in the page's own wording (empty when absent), so the model never invents numbers.
///
/// `importedProduct(sourceURL:fallbackName:)` parses the strings back into an
/// ``ImportedFoodProduct``; the caller then applies bounds and macro-calorie consistency checks
/// before trusting the result.
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
private struct ExtractedFoodProduct {
    var name: String
    var brand: String
    var servingSize: String
    var calories: String
    var protein: String
    var carbs: String
    var fat: String
    var fiber: String
    var sugar: String
    var saturatedFat: String
    var cholesterol: String
    var sodium: String

    func importedProduct(sourceURL: URL, fallbackName: String) -> ImportedFoodProduct? {
        FoodProductWebImporter.importedProduct(
            sourceURL: sourceURL,
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fallbackName : name,
            brand: brand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : brand,
            servingSize: servingSize.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "1 serving" : servingSize,
            calories: FoodProductWebImporter.nutritionDoubleValue(calories).flatMap { Int(exactly: $0.rounded()) },
            protein: FoodProductWebImporter.nutritionDoubleValue(protein),
            carbs: FoodProductWebImporter.nutritionDoubleValue(carbs),
            fat: FoodProductWebImporter.nutritionDoubleValue(fat),
            micronutrients: Micronutrients(
                fiber: FoodProductWebImporter.nutritionDoubleValue(fiber),
                sugar: FoodProductWebImporter.nutritionDoubleValue(sugar),
                saturatedFat: FoodProductWebImporter.nutritionDoubleValue(saturatedFat),
                cholesterol: FoodProductWebImporter.nutritionDoubleValue(cholesterol),
                sodium: FoodProductWebImporter.nutritionDoubleValue(sodium)
            )
        )
    }
}
#endif
