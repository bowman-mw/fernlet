import Foundation
import FoodCatalog

#if canImport(FoundationModels)
import FoundationModels
import FernletDomainModel
#endif

struct ImportedRecipe: Equatable {
    var sourceURL: URL
    var name: String
    var ingredients: [String]
    var summary: String
    var servings: Int
    var protein: Int
    var carbs: Int
    var fat: Int
    var micronutrients: Micronutrients = Micronutrients()
}

enum RecipeWebImportError: LocalizedError {
    case invalidURL
    case fetchFailed
    case emptyHTML
    case noRecipeFound
    case modelUnavailable
    case incompleteRecipe

    var errorDescription: String? {
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
        }
    }
}

enum RecipeWebImporter {
    private static let maxFetchBytes = 3 * 1024 * 1024  // 3 MB

    /// - Parameter aiEnabled: When false, the FoundationModels fallback is skipped so that
    ///   users who have disabled AI are not silently opted in via recipe import.
    static func importRecipe(from url: URL, catalog: FoodCatalog, aiEnabled: Bool) async throws -> ImportedRecipe {
        guard isSafePublicHTTPSURL(url) else {
            throw RecipeWebImportError.invalidURL
        }

        let html = try await fetchHTML(from: url)
        if let recipe = try jsonLDRecipe(from: html, sourceURL: url, catalog: catalog) {
            return recipe
        }

        guard aiEnabled else {
            throw RecipeWebImportError.noRecipeFound
        }

        let cleanedText = try cleanedBodyText(from: html)
        return try await extractWithFoundationModel(from: cleanedText, sourceURL: url, catalog: catalog)
    }

    private static func fetchHTML(from url: URL) async throws -> String {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.setValue("Fernlet/1.0", forHTTPHeaderField: "User-Agent")

        let (asyncBytes, response): (URLSession.AsyncBytes, URLResponse)
        do {
            // Validate every redirect hop, not just the initial URL: a public https page can 30x
            // to an internal/link-local address. A rejected redirect surfaces the 3xx response,
            // which the status-code guard below treats as a failed fetch.
            (asyncBytes, response) = try await URLSession.shared.bytes(for: request, delegate: RedirectValidator())
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
    static func isSafePublicHTTPSURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), !host.isEmpty else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".localhost") { return false }
        return !isPrivateOrLoopbackIPLiteral(host)
    }

    static func isPrivateOrLoopbackIPLiteral(_ host: String) -> Bool {
        // IPv6 literals (URL.host strips the surrounding brackets).
        if host == "::1" { return true }                                  // loopback
        if host.hasPrefix("fe80:") { return true }                        // link-local
        if host.hasPrefix("fc") || host.hasPrefix("fd") { return true }   // unique-local fc00::/7
        // IPv4 literals.
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4, octets.allSatisfy({ (0...255).contains($0) }) else { return false }
        let (a, b) = (octets[0], octets[1])
        if a == 127 || a == 10 || a == 0 { return true }                  // loopback / private / this-network
        if a == 192 && b == 168 { return true }                           // private
        if a == 172 && (16...31).contains(b) { return true }              // private
        if a == 169 && b == 254 { return true }                           // link-local
        return false
    }

    /// Per-task delegate that re-validates each redirect target and cancels unsafe ones.
    private final class RedirectValidator: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(
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

    private static func jsonLDRecipe(from html: String, sourceURL: URL, catalog: FoodCatalog) throws -> ImportedRecipe? {
        for rawJSON in jsonLDScriptContents(from: html) {
            guard let jsonData = htmlDecoded(rawJSON).data(using: .utf8) else { continue }
            guard let object = try? JSONSerialization.jsonObject(with: jsonData) else { continue }
            if let recipe = recipeObject(in: object),
               let imported = importedRecipe(from: recipe, sourceURL: sourceURL, catalog: catalog) {
                return imported
            }
        }
        return nil
    }

    private static func cleanedBodyText(from html: String) throws -> String {
        let bodyHTML = firstCapture(in: html, pattern: #"(?is)<body\b[^>]*>(.*?)</body>"#) ?? html
        let withoutNoise = removingElements(
            ["nav", "footer", "header", "aside", "script", "style"],
            from: bodyHTML
        )
        let text = htmlDecoded(withoutNoise.replacingOccurrences(
            of: #"(?is)<[^>]+>"#,
            with: " ",
            options: .regularExpression
        ))
        let normalized = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard normalized.isEmpty == false else {
            throw RecipeWebImportError.noRecipeFound
        }
        return String(normalized.prefix(12_000))
    }

    private static func extractWithFoundationModel(from text: String, sourceURL: URL, catalog: FoodCatalog) async throws -> ImportedRecipe {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, visionOS 26.0, *) {
            guard RecipeExtractionAvailability.isFoundationModelAvailable else {
                throw RecipeWebImportError.modelUnavailable
            }

            let payload = RecipeExtractionPayload(
                sourceHost: sourceURL.host() ?? "unknown",
                cleanedTextCharCount: text.count
            )
            await AIAuditLog.shared.record(
                payloadKind: payload.payloadKind,
                destination: .onDeviceFoundationModels,
                includedFields: payload.includedFieldNames
            )

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
            let response = try await session.respond(to: prompt, generating: ExtractedRecipe.self)
            return try response.content.importedRecipe(sourceURL: sourceURL, catalog: catalog)
        }
        #endif

        throw RecipeWebImportError.modelUnavailable
    }

    // MARK: - JSON-LD parsing

    private static func jsonLDScriptContents(from html: String) -> [String] {
        let pattern = #"(?is)<script\b([^>]*)>(.*?)</script>"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)

        return regex.matches(in: html, range: range).compactMap { match in
            guard match.numberOfRanges >= 3,
                  let attributeRange = Range(match.range(at: 1), in: html),
                  let contentRange = Range(match.range(at: 2), in: html) else {
                return nil
            }
            let attributes = String(html[attributeRange])
            guard scriptAttributesContainJSONLD(attributes) else { return nil }
            let content = String(html[contentRange]).trimmingCharacters(in: .whitespacesAndNewlines)
            return content.isEmpty ? nil : content
        }
    }

    private static func scriptAttributesContainJSONLD(_ attributes: String) -> Bool {
        firstCapture(in: attributes, pattern: #"(?is)\btype\s*=\s*(["'])\s*application/ld\+json\s*\1"#) != nil ||
        attributes.range(of: "application/ld+json", options: [.caseInsensitive]) != nil
    }

    private static func recipeObject(in object: Any) -> [String: Any]? {
        if let dictionary = object as? [String: Any] {
            if isRecipe(dictionary) {
                return dictionary
            }
            if let graph = dictionary["@graph"] as? [Any] {
                return graph.compactMap { recipeObject(in: $0) }.first
            }
            if let itemList = dictionary["itemListElement"] as? [Any] {
                return itemList.compactMap { recipeObject(in: $0) }.first
            }
        }

        if let array = object as? [Any] {
            return array.compactMap { recipeObject(in: $0) }.first
        }

        return nil
    }

    private static func isRecipe(_ dictionary: [String: Any]) -> Bool {
        guard let type = dictionary["@type"] else { return false }
        if let typeString = type as? String {
            return typeString.caseInsensitiveCompare("Recipe") == .orderedSame
        }
        if let types = type as? [String] {
            return types.contains { $0.caseInsensitiveCompare("Recipe") == .orderedSame }
        }
        return false
    }

    private static func importedRecipe(from dictionary: [String: Any], sourceURL: URL, catalog: FoodCatalog) -> ImportedRecipe? {
        let name = stringValue(dictionary["name"])
        let ingredients = stringArrayValue(dictionary["recipeIngredient"])
        let fullSummary = instructionsText(from: dictionary["recipeInstructions"])
        let summary = briefSummary(from: fullSummary)
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
            micronutrients: micronutrients
        )
    }

    // MARK: - Servings

    private static func parseServings(from value: Any?) -> Int {
        if let n = value as? Int { return max(1, n) }
        if let d = value as? Double { return max(1, Int(d.rounded())) }
        if let s = stringValue(value) {
            // "4 servings", "Makes 12 cookies", "4-6 servings" — take the first integer
            let digits = s.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
            if let first = digits.first, let n = Int(first) { return max(1, n) }
        }
        if let array = value as? [Any] { return parseServings(from: array.first) }
        return 1
    }

    // MARK: - Nutrition label (JSON-LD schema.org/NutritionInformation)

    private static func nutritionMacros(from dictionary: [String: Any]) -> (protein: Int, carbs: Int, fat: Int, micronutrients: Micronutrients)? {
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
            )
        )
    }

    private static func nutritionDictionary(from value: Any?) -> [String: Any]? {
        if let dictionary = value as? [String: Any] { return dictionary }
        if let array = value as? [Any] {
            return array.compactMap { $0 as? [String: Any] }.first
        }
        return nil
    }

    private static func nutritionValue(_ value: Any?) -> Int? {
        nutritionDoubleValue(value).map { Int($0.rounded()) }
    }

    private static func nutritionDoubleValue(_ value: Any?) -> Double? {
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

    static func estimateMacrosFromIngredients(_ ingredients: [String], servings: Int, catalog: FoodCatalog) -> (Int, Int, Int) {
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
    private static func parseIngredient(_ text: String) -> (quantity: Double, unit: String, name: String)? {
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

    private static func parseQuantity(_ text: String) -> Double? {
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

    private static func parseFraction(_ text: String) -> Double? {
        let parts = text.split(separator: "/")
        guard parts.count == 2,
              let num = Double(parts[0].trimmingCharacters(in: .whitespaces)),
              let den = Double(parts[1].trimmingCharacters(in: .whitespaces)),
              den != 0 else { return nil }
        return num / den
    }

    private static func resolveUnit(quantity: Double, unitString: String) -> (Double, String) {
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

    private static func cleanFoodName(_ text: String) -> String {
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
        }
        if let string = stringValue(value) {
            return [string]
        }
        return []
    }

    private static func instructionsText(from value: Any?) -> String {
        if let string = stringValue(value) {
            return string
        }
        if let values = value as? [Any] {
            return values.compactMap(instructionText).joined(separator: " ")
        }
        if let dictionary = value as? [String: Any] {
            return instructionText(from: dictionary) ?? ""
        }
        return ""
    }

    nonisolated private static func instructionText(from value: Any) -> String? {
        if let string = stringValue(value) {
            return string
        }
        if let dictionary = value as? [String: Any] {
            return instructionText(from: dictionary)
        }
        return nil
    }

    nonisolated private static func instructionText(from dictionary: [String: Any]) -> String? {
        if let text = stringValue(dictionary["text"]) {
            return text
        }
        if let name = stringValue(dictionary["name"]) {
            return name
        }
        if let itemList = dictionary["itemListElement"] as? [Any] {
            let text = itemList.compactMap(instructionText).joined(separator: " ")
            return text.isEmpty ? nil : text
        }
        return nil
    }

    private static func removingElements(_ tagNames: [String], from html: String) -> String {
        tagNames.reduce(html) { currentHTML, tagName in
            currentHTML.replacingOccurrences(
                of: #"(?is)<\#(tagName)\b[^>]*>.*?</\#(tagName)>"#,
                with: " ",
                options: .regularExpression
            )
        }
    }

    private static func firstCapture(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range), match.numberOfRanges > 1 else {
            return nil
        }
        let captureIndex = match.numberOfRanges > 2 ? match.numberOfRanges - 1 : 1
        guard let captureRange = Range(match.range(at: captureIndex), in: text) else { return nil }
        return String(text[captureRange])
    }

    private static func htmlDecoded(_ text: String) -> String {
        var decoded = text
        decoded = replacingNumericEntities(in: decoded, pattern: #"&#(\d+);"#) { UInt32($0) }
        decoded = replacingNumericEntities(in: decoded, pattern: #"&#x([0-9a-fA-F]+);"#) { UInt32($0, radix: 16) }
        let namedEntities: [(String, String)] = [
            ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "), ("&amp;", "&")
        ]
        for (entity, replacement) in namedEntities {
            decoded = decoded.replacingOccurrences(of: entity, with: replacement, options: .caseInsensitive)
        }
        return decoded
    }

    private static func replacingNumericEntities(
        in text: String,
        pattern: String,
        transform: (String) -> UInt32?
    ) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
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
}

#if canImport(FoundationModels)
@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
private enum RecipeExtractionAvailability {
    static var isFoundationModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability {
            return true
        }
        return false
    }
}

@available(iOS 26.0, macOS 26.0, visionOS 26.0, *)
@Generable
struct ExtractedRecipe {
    var name: String
    var ingredients: [String]
    var summary: String

    func importedRecipe(sourceURL: URL, catalog: FoodCatalog) throws -> ImportedRecipe {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedIngredients = ingredients
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
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
