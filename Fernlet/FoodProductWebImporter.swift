import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(FoundationModels)
import FoundationModels
import FernletDomainModel
#endif

struct ProductPagePreview: Equatable {
    var sourceURL: URL
    var title: String

    var sourceName: String {
        sourceURL.host() ?? sourceURL.absoluteString
    }
}

enum FoodProductWebSearch {
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

    static func preview(for query: String) async throws -> ProductPagePreview {
        var components = URLComponents(string: "https://html.duckduckgo.com/html/")
        components?.queryItems = [URLQueryItem(name: "q", value: "\(query) nutrition facts")]
        guard let url = components?.url else {
            throw FoodProductWebImportError.invalidURL
        }
        let html = try await FoodProductWebImporter.fetchHTML(from: url)
        guard let result = preferredSearchResults(from: html).first else {
            throw FoodProductWebImportError.productNotFound
        }
        return result
    }

    static func preferredSearchResults(from html: String) -> [ProductPagePreview] {
        searchResults(from: html).sorted { first, second in
            sourcePriority(for: first.sourceURL) > sourcePriority(for: second.sourceURL)
        }
    }

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

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[captureRange])
    }
}

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

enum FoodProductWebImporter {
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

    static func fallbackSearchText(from url: URL) -> String {
        let ignoredPathComponents: Set<String> = ["p", "product", "products", "-"]
        let slug = url.pathComponents
            .filter { $0 != "/" && Double($0) == nil && !ignoredPathComponents.contains($0.lowercased()) }
            .joined(separator: " ")
            .replacingOccurrences(of: "-", with: " ")
        return slug.isEmpty ? (url.host() ?? url.absoluteString) : slug
    }

    static func importProduct(from preview: ProductPagePreview) async throws -> ImportedFoodProduct {
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
        return try await extractWithFoundationModel(from: cleanedText, fallbackName: preview.title, sourceURL: preview.sourceURL)
    }

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
            (asyncBytes, response) = try await URLSession.shared.bytes(for: request)
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
        for rawJSON in jsonLDScriptContents(from: html) {
            guard let data = htmlDecoded(rawJSON).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data),
                  let product = productObject(in: object) else {
                continue
            }
            return product
        }
        return nil
    }

    private static func productObject(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if schemaTypes(in: dictionary).contains("product") {
                return dictionary
            }
            if let graph = dictionary["@graph"] as? [Any] {
                for item in graph {
                    if let product = productObject(in: item) {
                        return product
                    }
                }
            }
            if let itemList = dictionary["itemListElement"] as? [Any] {
                for item in itemList {
                    if let product = productObject(in: item) {
                        return product
                    }
                }
            }
        }
        if let array = object as? [Any] {
            for item in array {
                if let product = productObject(in: item) {
                    return product
                }
            }
        }
        return nil
    }

    private static func schemaTypes(in dictionary: [String: Any]) -> Set<String> {
        if let type = dictionary["@type"] as? String {
            return [type.lowercased()]
        }
        if let types = dictionary["@type"] as? [String] {
            return Set(types.map { $0.lowercased() })
        }
        return []
    }

    private static func importedProduct(from dictionary: [String: Any], sourceURL: URL) -> ImportedFoodProduct? {
        guard let name = stringValue(dictionary["name"]), let nutrition = nutritionDictionary(from: dictionary) else {
            return nil
        }
        return importedProduct(
            sourceURL: sourceURL,
            name: name,
            brand: brandName(from: dictionary["brand"]),
            servingSize: stringValue(nutrition["servingSize"]) ?? "1 serving",
            calories: nutritionDoubleValue(nutrition["calories"]).map { Int($0.rounded()) },
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
        return ImportedFoodProduct(
            sourceURL: sourceURL,
            name: name,
            brand: brand,
            servingSize: servingSize,
            calories: calories,
            macros: Macros(protein: Int(protein.rounded()), carbs: Int(carbs.rounded()), fat: Int(fat.rounded())),
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
    private static func productFromNutritionLabelImages(in html: String, fallbackName: String, sourceURL: URL) async -> ImportedFoodProduct? {
        for imageURL in candidateImageURLs(from: html, sourceURL: sourceURL).prefix(8) {
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

    private static func fetchImage(from url: URL) async -> UIImage? {
        guard url.scheme == "https" else { return nil }
        // Explicit 15s timeout (vs the 60s default): up to 8 candidate images are fetched
        // sequentially, so a stalling host would otherwise chain into a multi-minute hang.
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("image/*", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode),
              data.count <= 12_000_000 else {
            return nil
        }
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

    private static func extractWithFoundationModel(from text: String, fallbackName: String, sourceURL: URL) async throws -> ImportedFoodProduct {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard case .available = SystemLanguageModel.default.availability else {
                throw FoodProductWebImportError.modelUnavailable
            }

            let payload = WebPageNutritionExtractionPayload(
                sourceHost: sourceURL.host() ?? "unknown",
                cleanedTextCharCount: text.count
            )
            await AIAuditLog.shared.record(
                payloadKind: payload.payloadKind,
                destination: .onDeviceFoundationModels,
                includedFields: payload.includedFieldNames
            )

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
            let response = try await session.respond(to: prompt, generating: ExtractedFoodProduct.self)
            guard let product = response.content.importedProduct(sourceURL: sourceURL, fallbackName: fallbackName) else {
                throw FoodProductWebImportError.nutritionNotFound
            }
            // Plausibility: per-field bounds + macro-calorie consistency
            let p = product.macros.protein, c = product.macros.carbs, f = product.macros.fat
            let macroCalories = p * 4 + c * 4 + f * 9
            if let reportedCalories = product.calories {
                let allowedLow = max(0, reportedCalories / 2 - 50)
                let allowedHigh = reportedCalories * 2 + 100
                guard reportedCalories >= 0 && reportedCalories <= 5000,
                      p >= 0 && p <= 500, c >= 0 && c <= 1000, f >= 0 && f <= 500,
                      macroCalories >= allowedLow && macroCalories <= allowedHigh else {
                    throw FoodProductWebImportError.nutritionNotFound
                }
            }
            return product
        }
        #endif
        throw FoodProductWebImportError.modelUnavailable
    }

    private static func cleanedBodyText(from html: String) throws -> String {
        let bodyHTML = firstCapture(in: html, pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#) ?? html
        let withoutNoise = ["nav", "footer", "header", "aside", "script", "style"].reduce(bodyHTML) { currentHTML, tagName in
            currentHTML.replacingOccurrences(of: #"(?is)<\#(tagName)\b[^>]*>.*?</\#(tagName)>"#, with: " ", options: .regularExpression)
        }
        let text = htmlDecoded(withoutNoise.replacingOccurrences(of: #"(?is)<[^>]+>"#, with: " ", options: .regularExpression))
        let normalized = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        guard !normalized.isEmpty else {
            throw FoodProductWebImportError.productNotFound
        }
        return String(normalized.prefix(12_000))
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
        jsonLDScriptContents(from: html).flatMap { rawJSON -> [ImageCandidate] in
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

    private static func imageValues(in object: Any) -> [String] {
        if let string = object as? String {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? [] : [trimmed]
        }
        if let array = object as? [Any] {
            return array.flatMap { imageValues(in: $0) }
        }
        guard let dictionary = object as? [String: Any] else { return [] }
        var values: [String] = []
        if let image = dictionary["image"] {
            values.append(contentsOf: imageValues(in: image))
        }
        if let graph = dictionary["@graph"] {
            values.append(contentsOf: imageValues(in: graph))
        }
        if schemaTypes(in: dictionary).contains("imageobject"), let url = dictionary["url"] {
            values.append(contentsOf: imageValues(in: url))
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

    private static func jsonLDScriptContents(from html: String) -> [String] {
        let pattern = #"(?is)<script\b([^>]*)>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let attributesRange = Range(match.range(at: 1), in: html),
                  let contentRange = Range(match.range(at: 2), in: html),
                  String(html[attributesRange]).range(of: "application/ld+json", options: .caseInsensitive) != nil else {
                return nil
            }
            return String(html[contentRange])
        }
    }

    private static func metadataContent(named property: String, in html: String) -> String? {
        let escapedProperty = NSRegularExpression.escapedPattern(for: property)
        return firstCapture(in: html, pattern: #"(?is)<meta\b[^>]*(?:property|name)\s*=\s*["']\#(escapedProperty)["'][^>]*content\s*=\s*["'](.*?)["'][^>]*>"#)
    }

    fileprivate static func nutritionDoubleValue(_ value: Any?) -> Double? {
        guard let string = stringValue(value) else { return nil }
        let normalized = Self.normalizeDecimalSeparator(string)
        let numeric = normalized.prefix(while: { $0.isNumber || $0 == "." })
        return Double(numeric)
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
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captureRange = Range(match.range(at: match.numberOfRanges - 1), in: text) else { return nil }
            return String(text[captureRange])
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        allCaptures(in: text, pattern: pattern).first
    }

    static func htmlDecoded(_ text: String) -> String {
        let entities: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")
        ]
        return entities.reduce(text) { result, entity in
            result.replacingOccurrences(of: entity.0, with: entity.1, options: .caseInsensitive)
        }
    }
}

#if canImport(FoundationModels)
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
            calories: FoodProductWebImporter.nutritionDoubleValue(calories).map { Int($0.rounded()) },
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
