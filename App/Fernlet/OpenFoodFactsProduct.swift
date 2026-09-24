import Foundation
import FernletDomainModel

#if canImport(UIKit)
import AppServices
#endif

// The pure half of the optional online UPC lookup (tracker §3.3): barcode validation, the parsed
// Open Food Facts product, response classification, and the mapping into Fernlet's food model. No
// network API is named in this file — the one HTTP client for this lookup lives in
// `OpenFoodFactsClient.swift`, a file the no-tracking wall pins by name (Docs/No-Tracking-Wall.md).

// MARK: - Barcode validation

/// A scanned retail barcode that passed validation for an Open Food Facts lookup.
///
/// Built only through ``init(scanned:)``, which refuses anything that is not a well-formed GTIN, so
/// a malformed or mistyped code never reaches the network: digits only (ASCII — `Character.isNumber`
/// would also admit other scripts' digits), a GTIN length (8, 12, 13 or 14), a valid GS1 mod-10
/// check digit, and not all zeros. An 8-digit code is ambiguous between EAN-8 and UPC-E (the scanner
/// hands over the payload string, not the symbology); one starting with 0 or 1 whose UPC-E check
/// digit holds is read as UPC-E and expanded to its UPC-A form, because GS1 reserves those EAN-8
/// prefixes for in-store use and Open Food Facts keys US products by their UPC-A code.
///
/// Carries two renderings of one product: ``lookupCode`` in the form Open Food Facts keys its
/// products by (its documented normalization: leading zeros stripped, then padded to 8 digits for
/// 7 or fewer and to 13 for 9–12), and ``localCode``, the GTIN-14 `FoodBarcode.normalized` form of
/// what was SCANNED — the form a saved food must carry so the next scan resolves it locally.
nonisolated struct OpenFoodFactsBarcode: Equatable, Sendable {
    /// The code sent in the request path, in Open Food Facts' own canonical form.
    let lookupCode: String
    /// The scanned code as `FoodBarcode.normalized` renders it — stored on the saved food.
    let localCode: String

    /// Validates `raw` (a scanner payload or typed code); `nil` when it is not a product barcode.
    init?(scanned raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 14, trimmed.allSatisfy(Self.isASCIIDigit) else { return nil }
        guard [8, 12, 13, 14].contains(trimmed.count), trimmed.contains(where: { $0 != "0" }) else { return nil }
        guard let local = FoodBarcode.normalized(trimmed) else { return nil }
        let expanded: String
        if trimmed.count == 8, Self.readsAsUPCE(trimmed), let upca = Self.expandedUPCE(trimmed) {
            expanded = upca
        } else {
            guard Self.hasValidCheckDigit(trimmed) else { return nil }
            expanded = trimmed
        }
        self.lookupCode = Self.openFoodFactsCanonical(expanded)
        self.localCode = local
    }

    /// `0`–`9` only. `Character.isNumber` alone would also accept Arabic-Indic, Devanagari and
    /// fullwidth digits, which no barcode carries.
    static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    /// GS1 mod-10: weights 3,1,3,… from the digit left of the check digit. `digits` is ASCII-only.
    static func hasValidCheckDigit(_ digits: String) -> Bool {
        let values = digits.compactMap(\.wholeNumberValue)
        guard values.count == digits.count, values.count >= 2, let check = values.last else { return false }
        var sum = 0
        for (offset, value) in values.dropLast().reversed().enumerated() {
            sum += value * (offset.isMultiple(of: 2) ? 3 : 1)
        }
        return (10 - sum % 10) % 10 == check
    }

    /// Whether an 8-digit code should be treated as UPC-E: number system 0 or 1 and a UPC-E check
    /// digit that holds over the expanded UPC-A body.
    static func readsAsUPCE(_ digits: String) -> Bool {
        guard digits.count == 8, let first = digits.first, first == "0" || first == "1" else { return false }
        guard let expanded = expandedUPCE(digits) else { return false }
        return hasValidCheckDigit(expanded)
    }

    /// The 12-digit UPC-A a zero-suppressed UPC-E code stands for (the standard expansion keyed on
    /// the last data digit), carrying the UPC-E code's own check digit; `nil` when not 8 digits.
    static func expandedUPCE(_ digits: String) -> String? {
        let d = Array(digits)
        guard d.count == 8 else { return nil }
        let system = String(d[0]), check = String(d[7])
        let data = d[1...6].map(String.init)
        let body: String
        switch d[6] {
        case "0", "1", "2":
            body = data[0] + data[1] + data[5] + "0000" + data[2] + data[3] + data[4]
        case "3":
            body = data[0] + data[1] + data[2] + "00000" + data[3] + data[4]
        case "4":
            body = data[0] + data[1] + data[2] + data[3] + "00000" + data[4]
        default:
            body = data[0] + data[1] + data[2] + data[3] + data[4] + "0000" + data[5]
        }
        return system + body + check
    }

    /// Open Food Facts' documented barcode normalization, applied client-side so the request path
    /// is exactly the code OFF stores: strip leading zeros, pad to 8 when 7 or fewer remain and to
    /// 13 when 9–12 remain; 8, 13 and 14 significant digits pass through.
    static func openFoodFactsCanonical(_ digits: String) -> String {
        let significant = String(digits.drop(while: { $0 == "0" }))
        let width: Int
        switch significant.count {
        case ...7: width = 8
        case 9...12: width = 13
        default: width = significant.count
        }
        return String(repeating: "0", count: max(width - significant.count, 0)) + significant
    }
}

// MARK: - The parsed product

/// The quantity Open Food Facts' values are expressed on, as chosen by the parser.
///
/// A per-serving basis is preferred whenever OFF has computed `_serving` values (it does whenever a
/// serving quantity is known), because a barcode product is logged by the serving; otherwise the
/// values are per 100 g (or 100 ml for a liquid).
nonisolated enum OpenFoodFactsNutritionBasis: Equatable, Sendable {
    /// One serving: OFF's label text (`serving_size`), its gram/ml quantity when known, and the unit.
    case perServing(label: String?, quantity: Double?, unit: String)
    /// 100 g, or 100 ml when `unit` is `"ml"`.
    case per100(unit: String)

    /// The mass (or volume) the values describe, when known — the bound a single nutrient cannot
    /// exceed. `nil` for a serving whose size OFF does not know.
    var referenceQuantity: Double? {
        switch self {
        case .perServing(_, let quantity, _): quantity
        case .per100: 100
        }
    }

    /// The unit of ``referenceQuantity``: `"g"` or `"ml"`.
    var unit: String {
        switch self {
        case .perServing(_, _, let unit), .per100(let unit): unit
        }
    }

    /// The serving line ("1 bar (68 g)", "68 g", "100 g"), or `nil` when OFF knows neither a label
    /// nor a quantity for its serving — and then the completeness gate names "Serving size" as
    /// missing, which is the truth. Stored as `FoodItem.servingDescription`, so it is built from
    /// OFF's own text and locale-independent numbers only, never from localized copy.
    var servingDescription: String? {
        switch self {
        case .perServing(let label?, _, _):
            return label
        case .perServing(nil, let quantity?, let unit):
            return "\(String(format: "%g", quantity)) \(unit)"
        case .perServing(nil, nil, _):
            return nil
        case .per100(let unit):
            return "100 \(unit)"
        }
    }
}

/// One product as read from an Open Food Facts response: identity, the nutrition basis, and the
/// values on that basis, with **absent kept absent** — a nutrient OFF does not report stays `nil`
/// here and reaches the plausibility gate as missing, never as a claimed zero.
///
/// Every value has already passed the parser's import bounds (finite, non-negative, not more grams
/// of one nutrient than the whole reference quantity), so a unit slip in the crowd data — a value
/// entered in milligrams as grams, weighing more than the serving it belongs to — is dropped rather
/// than stored. (OFF's live Clif Bar record, captured for this change, carries 1 090 g of added
/// sugars per 68 g bar; Fernlet does not read added sugars, but the class of error is real.)
/// Micronutrients are in Fernlet's units (mg / µg / g per `FDADailyValues`), converted from OFF's
/// grams. Nothing here is persisted until the user reviews it and taps Remember.
nonisolated struct OpenFoodFactsProduct: Equatable, Sendable {
    /// The validated barcode this product was looked up by.
    let barcode: OpenFoodFactsBarcode
    /// OFF's product name, cleaned of control characters and capped; `nil` when OFF has none.
    let productName: String?
    /// The first brand OFF lists, cleaned and capped.
    let brand: String?
    /// The basis the values are on; `nil` when OFF has no usable nutrition for this product.
    let basis: OpenFoodFactsNutritionBasis?
    /// Declared energy (kcal) on ``basis``.
    let calories: Double?
    /// Protein grams on ``basis``.
    let protein: Double?
    /// Carbohydrate grams on ``basis`` — OFF's `carbohydrates-total` (the US convention Fernlet's
    /// catalog follows) when present, else its `carbohydrates`.
    let carbs: Double?
    /// Fat grams on ``basis``.
    let fat: Double?
    /// Trans fat grams — read only so the fat-fraction plausibility rule can see it (Fernlet's
    /// micronutrient model has no trans-fat field).
    let transFat: Double?
    /// The micronutrients OFF reports, in Fernlet's units.
    let micronutrients: Micronutrients

    /// Whether any energy or macro value survived the import bounds.
    var hasNutrition: Bool {
        basis != nil && (calories != nil || protein != nil || carbs != nil || fat != nil)
    }

    /// The name the naming screen is prefilled with: the brand prefixed when the name does not
    /// already carry it, and an all-capitals name (common in the US imports) softened to title case.
    var suggestedName: String? {
        guard let productName else { return nil }
        let softened = Self.softenedShouting(productName)
        guard let brand, !softened.localizedCaseInsensitiveContains(brand) else { return softened }
        return String("\(brand) \(softened)".prefix(OpenFoodFactsProductParser.maxNameLength))
    }

    /// Title-cases a name written entirely in capitals; leaves any name with a lowercase letter as is.
    static func softenedShouting(_ name: String) -> String {
        let letters = name.filter(\.isLetter)
        guard letters.count >= 4, !letters.contains(where: \.isLowercase) else { return name }
        return name.capitalized(with: Locale(identifier: "en_US_POSIX"))
    }
}

// MARK: - Outcomes

/// Why an Open Food Facts lookup produced nothing usable, as a frozen token for the device-local
/// audit line (never shown to the user verbatim — the lookup card maps each to calm copy).
nonisolated enum OpenFoodFactsLookupFailure: String, Equatable, Sendable {
    /// The request never completed (offline, DNS, TLS, connection reset).
    case network
    /// The whole-lookup deadline or the transport's idle timeout passed.
    case timedOut
    /// HTTP 429 — Open Food Facts' per-IP rate limit.
    case rateLimited
    /// Any other non-200, non-404 status (including a refused redirect's 3xx).
    case httpStatus
    /// A 200 whose content type is not JSON.
    case notJSON
    /// The body exceeded ``OpenFoodFactsClient/maxResponseBytes``.
    case oversize
    /// The body was not the documented v3 product envelope.
    case malformed
    /// No request could be built for this barcode (unreachable for a validated code).
    case invalidRequest
}

/// Everything one lookup can end in.
nonisolated enum OpenFoodFactsLookupOutcome: Equatable, Sendable {
    /// OFF knows the product. It may still lack nutrition — check ``OpenFoodFactsProduct/hasNutrition``.
    case found(OpenFoodFactsProduct)
    /// OFF has no product under this code (HTTP 404, or a v3 `failure` envelope).
    case notFound
    /// The web-nutrition-lookup consent does not permit a request right now; nothing was sent.
    case notPermitted
    /// The request failed or the answer was unusable.
    case failed(OpenFoodFactsLookupFailure)

    /// The outcome the AI activity log settles the dispatch-time entry to.
    var succeeded: Bool {
        if case .found = self { return true }
        return false
    }
}

// MARK: - Response classification and parsing

/// Turns one HTTP answer from the product endpoint into an ``OpenFoodFactsLookupOutcome``.
///
/// Pure, so every failure mode is testable without a network: 404 → not found; 429 → rate limited;
/// any other non-200 → failed; a 200 that is not JSON → failed; otherwise the body is parsed.
nonisolated enum OpenFoodFactsResponseClassifier {
    /// Classifies one response for `barcode`.
    static func outcome(statusCode: Int, contentType: String, body: Data,
                        barcode: OpenFoodFactsBarcode) -> OpenFoodFactsLookupOutcome {
        guard statusCode != 404 else { return .notFound }
        guard statusCode != 429 else { return .failed(.rateLimited) }
        guard statusCode == 200 else { return .failed(.httpStatus) }
        guard contentType.lowercased().contains("json") else { return .failed(.notJSON) }
        guard body.count <= OpenFoodFactsClient.maxResponseBytes else { return .failed(.oversize) }
        return OpenFoodFactsProductParser.parse(body, barcode: barcode)
    }
}

/// Parses the Open Food Facts v3 product envelope, reading a FIXED list of keys.
///
/// Bounded by construction (Power-of-10 R2/R3): the body is capped before it gets here, the JSON is
/// decoded once by `JSONSerialization`, and every read is a direct lookup of a named key — the
/// parser never iterates a dictionary or array the server chose the size of. Values OFF sometimes
/// serves as numeric strings are accepted; anything non-finite, negative, or larger than the whole
/// reference quantity is dropped to `nil`.
nonisolated enum OpenFoodFactsProductParser {
    /// Longest product name kept (the same order as the day-summary payload's name cap).
    static let maxNameLength = 80
    /// Longest brand kept.
    static let maxBrandLength = 40
    /// Longest serving label kept.
    static let maxServingLabelLength = 40
    /// The largest serving quantity believed, in g or ml.
    static let maxServingQuantity = 2_000.0
    /// Per-serving ceilings when the serving's mass is unknown — the same bounds the web importer's
    /// model tier applies (`FoodProductWebImporter.isPlausibleModelExtraction`).
    static let unknownServingProteinCeiling = 500.0
    /// See ``unknownServingProteinCeiling``.
    static let unknownServingCarbCeiling = 1_000.0
    /// See ``unknownServingProteinCeiling``.
    static let unknownServingFatCeiling = 500.0
    /// See ``unknownServingProteinCeiling``.
    static let unknownServingCalorieCeiling = 5_000.0

    /// Parses `data` for `barcode`.
    static func parse(_ data: Data, barcode: OpenFoodFactsBarcode) -> OpenFoodFactsLookupOutcome {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let envelope = object as? [String: Any],
              let status = envelope["status"] as? String else {
            return .failed(.malformed)
        }
        guard status != "failure" else { return .notFound }
        guard status.hasPrefix("success"), let product = envelope["product"] as? [String: Any] else {
            return .failed(.malformed)
        }
        return .found(self.product(from: product, barcode: barcode))
    }

    /// Builds the product from the envelope's `product` object.
    static func product(from product: [String: Any], barcode: OpenFoodFactsBarcode) -> OpenFoodFactsProduct {
        let nutriments = product["nutriments"] as? [String: Any] ?? [:]
        let hasNoNutrition = (product["no_nutrition_data"] as? String)?.lowercased() == "on"
        let basis = hasNoNutrition ? nil : self.basis(product: product, nutriments: nutriments)
        let reader = OpenFoodFactsNutrientReader(nutriments: nutriments, basis: basis)
        return OpenFoodFactsProduct(
            barcode: barcode,
            productName: cleanedText(product["product_name"], maxLength: maxNameLength),
            brand: firstBrand(product["brands"]),
            basis: reader.basis,
            calories: reader.calories,
            protein: reader.macro("proteins", unknownServingCeiling: unknownServingProteinCeiling),
            carbs: reader.macro("carbohydrates-total", unknownServingCeiling: unknownServingCarbCeiling)
                ?? reader.macro("carbohydrates", unknownServingCeiling: unknownServingCarbCeiling),
            fat: reader.macro("fat", unknownServingCeiling: unknownServingFatCeiling),
            transFat: reader.grams("trans-fat"),
            micronutrients: reader.micronutrients
        )
    }

    /// Picks the basis: per serving when any `_serving` energy/macro exists, else per 100 when any
    /// `_100g` one does, else none.
    static func basis(product: [String: Any], nutriments: [String: Any]) -> OpenFoodFactsNutritionBasis? {
        let keys = ["energy-kcal", "energy-kj", "proteins", "carbohydrates", "carbohydrates-total", "fat"]
        let unit = (product["serving_quantity_unit"] as? String)?.lowercased() == "ml" ? "ml" : "g"
        if keys.contains(where: { number(nutriments["\($0)_serving"]) != nil }) {
            let quantity = number(product["serving_quantity"])
                .flatMap { $0 > 0 && $0 <= maxServingQuantity ? $0 : nil }
            let label = cleanedText(product["serving_size"], maxLength: maxServingLabelLength)
            return .perServing(label: label, quantity: quantity, unit: unit)
        }
        guard keys.contains(where: { number(nutriments["\($0)_100g"]) != nil }) else { return nil }
        return .per100(unit: unit)
    }

    /// A finite, non-negative number from an `NSNumber` (never a JSON boolean) or a numeric string.
    static func number(_ value: Any?) -> Double? {
        let parsed: Double?
        if let number = value as? NSNumber, CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() {
            parsed = number.doubleValue
        } else if let string = value as? String, string.count <= 32 {
            parsed = Double(string.trimmingCharacters(in: .whitespaces))
        } else {
            parsed = nil
        }
        guard let parsed, parsed.isFinite, parsed >= 0 else { return nil }
        return parsed
    }

    /// Display text from an untrusted string: control characters and line breaks become spaces,
    /// whitespace runs collapse, and the result is capped — an OFF name ends up in meal names and,
    /// through them, in on-device prompts, so it must not be able to carry a line break.
    static func cleanedText(_ value: Any?, maxLength: Int) -> String? {
        guard let raw = value as? String else { return nil }
        let bounded = String(raw.prefix(maxLength * 4))
        let words = bounded
            .components(separatedBy: .controlCharacters)
            .joined(separator: " ")
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
        let cleaned = String(words.joined(separator: " ").prefix(maxLength))
        return cleaned.isEmpty ? nil : cleaned
    }

    /// The first entry of OFF's comma-separated `brands`.
    static func firstBrand(_ value: Any?) -> String? {
        guard let brands = value as? String,
              let first = brands.split(separator: ",", maxSplits: 1).first else { return nil }
        return cleanedText(String(first), maxLength: maxBrandLength)
    }
}

/// Reads energy, macros and micronutrients off an OFF `nutriments` object on one basis, applying
/// the import bounds and converting OFF's grams into Fernlet's micronutrient units.
nonisolated struct OpenFoodFactsNutrientReader {
    /// The raw `nutriments` object.
    let nutriments: [String: Any]
    /// The basis the reads are on; `nil` means nothing is read.
    let basis: OpenFoodFactsNutritionBasis?

    /// `_serving` or `_100g`, matching the basis.
    private var suffix: String? {
        switch basis {
        case .perServing?: "_serving"
        case .per100?: "_100g"
        case nil: nil
        }
    }

    /// The most grams any single nutrient can weigh on this basis — the reference quantity, with
    /// headroom for a dense liquid (honey is ~1.4 g/ml) and label rounding. `nil` when unknown.
    private var gramCeiling: Double? {
        guard let reference = basis?.referenceQuantity else { return nil }
        return reference * (basis?.unit == "ml" ? 1.5 : 1.0) + 0.5
    }

    /// Declared energy in kcal, from `energy-kcal`, else converted from `energy-kj`.
    var calories: Double? {
        let ceiling = gramCeiling.map { $0 * 9.5 } ?? OpenFoodFactsProductParser.unknownServingCalorieCeiling
        let kcal = raw("energy-kcal") ?? raw("energy-kj").map { $0 / 4.184 }
        guard let kcal, kcal <= ceiling else { return nil }
        return kcal
    }

    /// One macro in grams, bounded by the reference mass or, when that is unknown, by
    /// `unknownServingCeiling`.
    func macro(_ key: String, unknownServingCeiling: Double) -> Double? {
        guard let value = raw(key) else { return nil }
        return value <= (gramCeiling ?? unknownServingCeiling) ? value : nil
    }

    /// One nutrient in grams, bounded by the reference mass when known.
    func grams(_ key: String) -> Double? {
        guard let value = raw(key) else { return nil }
        guard let gramCeiling else { return value }
        return value <= gramCeiling ? value : nil
    }

    /// The micronutrients, converted: OFF normalizes every weighed nutrient to grams, Fernlet keeps
    /// minerals and most vitamins in mg, and vitamins A, D, K, B12 and folate in µg. The domain
    /// model's own import guard (`sanitizedForImport`) runs last as the outer absurdity bound.
    var micronutrients: Micronutrients {
        let mg = { (key: String) in self.grams(key).map { $0 * 1_000 } }
        let mcg = { (key: String) in self.grams(key).map { $0 * 1_000_000 } }
        return Micronutrients(
            fiber: grams("fiber"), sugar: grams("sugars"), saturatedFat: grams("saturated-fat"),
            cholesterol: mg("cholesterol"), vitaminA: mcg("vitamin-a"), vitaminC: mg("vitamin-c"),
            vitaminD: mcg("vitamin-d"), vitaminE: mg("vitamin-e"), vitaminK: mcg("vitamin-k"),
            vitaminB6: mg("vitamin-b6"), vitaminB12: mcg("vitamin-b12"), thiamin: mg("vitamin-b1"),
            riboflavin: mg("vitamin-b2"), niacin: mg("vitamin-pp"),
            folate: mcg("vitamin-b9") ?? mcg("folates"),
            calcium: mg("calcium"), iron: mg("iron"), magnesium: mg("magnesium"),
            phosphorus: mg("phosphorus"), potassium: mg("potassium"), sodium: mg("sodium"),
            zinc: mg("zinc"), omega3: grams("omega-3-fat")
        ).sanitizedForImport()
    }

    /// The raw value of `key` on this basis, before any bound.
    private func raw(_ key: String) -> Double? {
        guard let suffix else { return nil }
        return OpenFoodFactsProductParser.number(nutriments[key + suffix])
    }
}

// MARK: - Mapping into Fernlet

nonisolated extension OpenFoodFactsProduct {
    /// The local user-food record this product becomes once the user has reviewed it and chosen
    /// `name`: OFF's values on OFF's basis, provenance `.openFoodFacts`, the SCANNED barcode (so the
    /// next scan hits locally), never the bundled catalog. `nil` without usable nutrition or a name.
    ///
    /// A macro OFF did not report is stored as 0 — `Macros` has no absent state. That collapse is
    /// never silent: the naming screen's plausibility gate runs over this product's optional-typed
    /// values first and names every missing field before the user can choose "Remember it anyway".
    func foodItem(named name: String, verifiedAt: Date) -> FoodItem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let basis, hasNutrition else { return nil }
        let serving = Self.servingShape(for: basis)
        return FoodItem(
            name: String(trimmed.prefix(OpenFoodFactsProductParser.maxNameLength)),
            brandSource: brand,
            servingSize: serving.size,
            servingUnit: serving.unit,
            macros: Macros(
                protein: Macros.clampedInt(protein ?? 0),
                carbs: Macros.clampedInt(carbs ?? 0),
                fat: Macros.clampedInt(fat ?? 0)
            ),
            micronutrients: micronutrients,
            category: "packaged product",
            source: .openFoodFacts,
            dataType: .branded,
            servingDescription: basis.servingDescription,
            lastVerified: verifiedAt,
            tags: [],
            barcode: barcode.localCode
        )
    }

    /// The serving a saved food is expressed on: the real gram/ml quantity when OFF knows it (so
    /// recipe gram conversions work natively, the way USDA branded rows are stored), else one
    /// abstract serving.
    static func servingShape(for basis: OpenFoodFactsNutritionBasis) -> (size: Double, unit: String) {
        guard let quantity = basis.referenceQuantity, quantity > 0 else { return (1, RecipeUnit.serving.rawValue) }
        let unit = basis.unit == "ml" ? RecipeUnit.milliliter.rawValue : RecipeUnit.gram.rawValue
        return (quantity, unit)
    }
}

#if canImport(UIKit)
nonisolated extension OpenFoodFactsProduct {
    /// The product as the naming screen's scan model, so the screen's existing review gate — the
    /// fix-1.14 plausibility and completeness report, the empty-macro nudge — runs over OFF's values
    /// exactly as it runs over a label the user scanned. Optionals stay optional; `nil` without
    /// usable nutrition.
    func labelResult() -> NutritionLabelResult? {
        guard let basis, hasNutrition else { return nil }
        let micros = micronutrients
        return NutritionLabelResult(
            servingSize: basis.servingDescription,
            calories: calories.map(Macros.clampedInt),
            protein: protein.map(Macros.clampedInt),
            carbs: carbs.map(Macros.clampedInt),
            fat: fat.map(Macros.clampedInt),
            fiber: micros.fiber, sugar: micros.sugar, saturatedFat: micros.saturatedFat,
            transFat: transFat, cholesterol: micros.cholesterol,
            vitaminA: micros.vitaminA, vitaminC: micros.vitaminC, vitaminD: micros.vitaminD,
            vitaminE: micros.vitaminE, vitaminB12: micros.vitaminB12, thiamin: micros.thiamin,
            riboflavin: micros.riboflavin, niacin: micros.niacin, folate: micros.folate,
            calcium: micros.calcium, iron: micros.iron, magnesium: micros.magnesium,
            phosphorus: micros.phosphorus, potassium: micros.potassium, sodium: micros.sodium,
            zinc: micros.zinc, omega3: micros.omega3
        )
    }
}
#endif

/// Where a reviewed Open Food Facts product is stored: the user's own `foodItems`, upserted by
/// barcode among earlier OFF imports so a repeat lookup refreshes the row in place (same id, so
/// recipes and meals that reference it keep resolving) instead of duplicating it.
nonisolated enum OpenFoodFactsImport {
    /// Inserts `item`, or replaces an earlier `.openFoodFacts` row carrying the same barcode.
    /// Returns the stored row. A user's hand-entered (`.manual`) food is never overwritten.
    static func upsert(_ item: FoodItem, into foodItems: inout [FoodItem]) -> FoodItem {
        guard let code = item.barcode,
              let index = foodItems.firstIndex(where: { $0.source == .openFoodFacts && $0.barcode == code }) else {
            foodItems.append(item)
            return item
        }
        var replacement = item
        replacement.id = foodItems[index].id
        foodItems[index] = replacement
        return replacement
    }
}
