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
        steps: [RecipeStep]? = nil
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
        if let recipe = try jsonLDRecipe(from: html, sourceURL: url, catalog: catalog) {
            return recipe
        }

        guard aiEnabled else {
            throw RecipeWebImportError.noRecipeFound
        }

        let cleanedText = try cleanedBodyText(from: html)
        return try await extractWithFoundationModel(from: cleanedText, sourceURL: url, catalog: catalog, userInvoked: userInvoked, gate: gate)
    }

    /// Streams the page with a 15 s timeout, redirect re-validation, an HTML-only MIME check, and the
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

    nonisolated static func isPrivateOrLoopbackIPLiteral(_ host: String) -> Bool {
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
    ///
    /// Closes the redirect half of the SSRF guard: a public HTTPS page can 30x toward an internal or
    /// link-local address, so every hop re-runs ``RecipeWebImporter/isSafePublicHTTPSURL(_:)`` and an
    /// unsafe hop is refused — the 3xx then becomes the final response and fails the caller's
    /// status-code guard. Stateless, which is why the `@unchecked Sendable` is sound even though
    /// URLSession invokes it off the main actor.
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

    /// Scans every `application/ld+json` script block for a schema.org `Recipe` object and converts
    /// the first usable one; `nil` sends the caller to the AI fallback.
    private static func jsonLDRecipe(from html: String, sourceURL: URL, catalog: FoodCatalog) throws -> ImportedRecipe? {
        for rawJSON in JSONLDScraper.scriptContents(from: html) {
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
    private static func cleanedBodyText(from html: String) throws -> String {
        guard let text = HTMLScraper.cleanedBodyText(from: html, decodingNumericEntities: true) else {
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
        let name = stringValue(dictionary["name"])
        let ingredients = stringArrayValue(dictionary["recipeIngredient"])
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

    /// USDA fallback when the site publishes no nutrition label: parses each ingredient line, matches
    /// its cleaned name against the catalog's top result, sums scaled macros, and divides by servings.
    /// Unparseable or unmatched lines contribute nothing, so this UNDERestimates rather than invents.
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

    /// F5: parse `recipeInstructions` into ORDERED steps rather than flattening them (which
    /// `instructionsText` does for the `briefSummary`). Preserves step order and section order:
    /// - a plain string array → one step per element, in order;
    /// - an array of `HowToStep` dictionaries → one step each (`text`, falling back to `name`);
    /// - `HowToSection` dictionaries (those with `itemListElement`) → their sub-steps flattened in
    ///   place, so sections concatenate section-by-section in order;
    /// - a single string → one step.
    /// Web JSON-LD steps rarely carry per-step timing, so `durationSeconds` stays nil here (manual
    /// entry supplies timers). Blank steps are dropped. Purely shape-based, like `instructionText`.
    /// Public so `RecipeStepsTests` can drive it directly (plain `import AIProviders`, matching the other
    /// importer tests) — it needs no network fetch or `FoodCatalog`, unlike the full import path.
    public nonisolated static func orderedSteps(from value: Any?) -> [RecipeStep] {
        if let string = stringValue(value) {
            return [RecipeStep(text: string)]
        }
        if let values = value as? [Any] {
            return values.flatMap(orderedSteps(from:))
        }
        if let dictionary = value as? [String: Any] {
            // HowToSection: flatten its ordered sub-steps (never surface the section name as a step).
            // schema.org permits `itemListElement` to be either an array OR a single object, so recurse
            // on the raw value rather than only matching `[Any]` — a single-object section would
            // otherwise fall through to the text/name branch and emit the SECTION NAME as the step
            // (dropping every real sub-step).
            if let itemList = dictionary["itemListElement"], !(itemList is NSNull) {
                // Presence of `itemListElement` marks this as a section; return its flattened sub-steps
                // and do NOT fall through to the section's own `name` (that would surface the section
                // heading as a step). An empty result drops the section, matching the array path.
                return orderedSteps(from: itemList)
            }
            // HowToStep: prefer `text`, fall back to `name`.
            if let text = stringValue(dictionary["text"]) ?? stringValue(dictionary["name"]) {
                return [RecipeStep(text: text)]
            }
        }
        return []
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

    /// This importer's entity-decoding policy: numeric character references (`&#8217;`, `&#x2019;`)
    /// ARE decoded, then the named entities.
    ///
    /// The machinery is shared with the product importer, but the policy is not — that importer
    /// decodes named entities only, and the difference is real (it changes what an href or a JSON-LD
    /// blob looks like after decoding), so `WebScrapingKit` takes it as a required parameter rather
    /// than guessing. Kept as a one-line shim so this file states its policy in exactly one place.
    private static func htmlDecoded(_ text: String) -> String {
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
