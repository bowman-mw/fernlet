import Foundation
import SwiftUI
import Testing
import AIContext
import AppServices
import FernletDomainModel
import FoodCatalog
@testable import Fernlet

/// The optional online UPC lookup (tracker §3.3): barcode validation, the exact request, every
/// failure mode through an offline canned transport, the consent gate (no request without consent),
/// real-shaped Open Food Facts fixtures through parsing → mapping → the plausibility gate, the
/// `.openFoodFacts` provenance token, and persistence as a local user food.
///
/// NO test here touches the network. The fixtures are trimmed from real API v3.4 responses captured
/// on 2026-09-24 (the Clif Bar and Nutella records, and a real 404 body), with the shape — envelope
/// keys, `success_with_warnings`, OFF's numbers-as-numbers-or-strings, its gram-normalized
/// micronutrients and its real unit slips — kept intact.
struct OpenFoodFactsLookupTests {

    // MARK: - Fixtures

    /// A US product with serving data, as OFF serves it (the `_serving` values are OFF-computed).
    /// Carries OFF's own unit slips: 1 090 g of added sugars per 68 g bar, and 0.13 mg of sodium.
    static let clifJSON = #"""
    {"code":"0722252100900","errors":[],"result":{"id":"product_found","lc_name":"Product found","name":"Product found"},
     "status":"success_with_warnings",
     "warnings":[{"field":{"id":"code","value":"0722252100900"},"impact":{"id":"none","lc_name":"None","name":"None"},"message":{"id":"different_normalized_product_code","lc_name":"","name":""}}],
     "product":{"brands":"CLIF","nutrition_data":"on","nutrition_data_per":"100g","nutrition_data_prepared_per":"100g",
      "product_name":"CHOCOLATE CHIP ENERGY BAR","serving_quantity":68,"serving_quantity_unit":"g","serving_size":"1 bar (68 g)",
      "nutriments":{"added-sugars_100g":1600,"added-sugars_serving":1090,"calcium_100g":0.0970588235294118,"calcium_serving":0.066,
       "carbohydrates":63.2352941176471,"carbohydrates-total_100g":63.2352941176471,"carbohydrates-total_serving":43,
       "carbohydrates_100g":63.2352941176471,"carbohydrates_serving":43,"energy-kcal_100g":367.647058823529,"energy-kcal_serving":250,
       "energy-kj_serving":1160,"fat_100g":8.82352941176471,"fat_serving":6,"fiber_100g":7.35294117647059,"fiber_serving":5,
       "iron_serving":0.0019,"magnesium_serving":0.015,"nova-group_serving":5.88235294117647,"phosphorus_serving":0.15,
       "potassium_serving":0.379,"proteins_100g":14.7058823529412,"proteins_serving":10,"salt_serving":0.000325,
       "saturated-fat_serving":2,"sodium_serving":0.00013,"sugars_serving":17}}}
    """#

    /// A European product with per-100 g data only (no serving known).
    static let nutellaJSON = #"""
    {"code":"3017620422003","errors":[],"result":{"id":"product_found","lc_name":"Product found","name":"Product found"},
     "status":"success","warnings":[],
     "product":{"brands":"Nutella, Ferrero","nutrition_data":"on","nutrition_data_per":"100g","product_name":"Nutella",
      "serving_quantity_unit":"g",
      "nutriments":{"carbohydrates_100g":57.5,"energy-kcal_100g":539,"energy-kj_100g":2252,"fat_100g":30.9,"fiber_100g":0,
       "proteins_100g":6.3,"salt_100g":0.107,"saturated-fat_100g":10.6,"sodium_100g":0.0428,"sugars_100g":56.3}}}
    """#

    /// The real 404 body for an unknown code.
    static let notFoundJSON = #"""
    {"code":"00000017","errors":[{"field":{"id":"code","value":"00000017"},"impact":{"id":"failure","lc_name":"Failure","name":"Failure"},"message":{"id":"product_not_found","lc_name":"","name":""}}],
     "result":{"id":"product_not_found","lc_name":"Product not found","name":"Product not found"},"status":"failure","warnings":[]}
    """#

    static let clifCode = OpenFoodFactsBarcode(scanned: "722252100900")
    static let nutellaCode = OpenFoodFactsBarcode(scanned: "3017620422003")

    static func data(_ json: String) -> Data { Data(json.utf8) }

    static func settings(permitted: Bool) -> FernletSettings {
        var settings = FernletSettings()
        settings.aiStatus = .ready
        if permitted {
            settings.webNutritionLookupEnabled = true
            settings.webNutritionLookupConsent = .accepted
        }
        return settings
    }

    /// The parsed product for `json`, or a recorded failure.
    static func product(_ json: String, code: OpenFoodFactsBarcode?) throws -> OpenFoodFactsProduct {
        let code = try #require(code)
        guard case .found(let product) = OpenFoodFactsProductParser.parse(data(json), barcode: code) else {
            Issue.record("fixture did not parse as a found product")
            throw ParseFailure()
        }
        return product
    }

    /// Thrown after `Issue.record` so a failed precondition stops the test.
    struct ParseFailure: Error {}

    // MARK: - Barcode validation

    @Test func validGTINsNormalizeToOpenFoodFactsForm() throws {
        let ean13 = try #require(OpenFoodFactsBarcode(scanned: "3017620422003"))
        #expect(ean13.lookupCode == "3017620422003")
        #expect(ean13.localCode == "03017620422003")

        let upcA = try #require(OpenFoodFactsBarcode(scanned: "722252100900"))
        #expect(upcA.lookupCode == "0722252100900", "OFF pads a 12-digit UPC-A to 13")
        #expect(upcA.localCode == FoodBarcode.normalized("722252100900"))

        #expect(OpenFoodFactsBarcode(scanned: "0722252100900")?.lookupCode == "0722252100900")
        #expect(OpenFoodFactsBarcode(scanned: "00722252100900")?.lookupCode == "0722252100900")
        #expect(OpenFoodFactsBarcode(scanned: " 3017620422003\n")?.lookupCode == "3017620422003")
        #expect(OpenFoodFactsBarcode(scanned: "96385074")?.lookupCode == "96385074", "EAN-8 stays 8 digits")
    }

    @Test func upcEExpandsToItsUPCAForLookupButKeepsTheScannedFormLocally() throws {
        #expect(OpenFoodFactsBarcode.expandedUPCE("06543217") == "065100004327")
        #expect(OpenFoodFactsBarcode.expandedUPCE("04252614") == "042100005264")
        #expect(OpenFoodFactsBarcode.expandedUPCE("01234565") == "012345000065")
        #expect(OpenFoodFactsBarcode.expandedUPCE("00123457") == "001234000057")
        let upcE = try #require(OpenFoodFactsBarcode(scanned: "06543217"))
        #expect(upcE.lookupCode == "0065100004327")
        #expect(upcE.localCode == FoodBarcode.normalized("06543217"), "the next scan must hit locally")
    }

    @Test func malformedBarcodesNeverBecomeARequest() {
        let rejected = [
            "", "   ", "3017620422004",          // bad check digit
            "30176204220O3", "3017-620422003",    // not digits
            "٣٠١٧٦٢٠٤٢٢٠٠٣",                       // Arabic-Indic digits: `isNumber`, not ASCII
            "３０１７６２０４２２００３",           // fullwidth digits
            "12345", "1234567890", "123456789012345", // not a GTIN length
            "00000000", "0000000000000",          // all zeros
            "96385075"                            // EAN-8 with a bad check digit, not a UPC-E either
        ]
        for raw in rejected {
            #expect(OpenFoodFactsBarcode(scanned: raw) == nil, "\(raw.debugDescription) must be refused")
        }
    }

    @Test func checkDigitAndCanonicalFormMatchGS1AndOpenFoodFacts() {
        #expect(OpenFoodFactsBarcode.hasValidCheckDigit("4006381333931"))
        #expect(!OpenFoodFactsBarcode.hasValidCheckDigit("4006381333932"))
        #expect(OpenFoodFactsBarcode.openFoodFactsCanonical("034000470693") == "0034000470693",
                "the example in OFF's barcode-normalization reference")
        #expect(OpenFoodFactsBarcode.openFoodFactsCanonical("00000123") == "00000123")
    }

    // MARK: - The request

    @Test func theRequestIsOneReadOnlyGETToOneHostWithNothingAboutTheUser() throws {
        let code = try #require(Self.clifCode)
        let request = try #require(OpenFoodFactsClient.productRequest(for: code, appVersion: "2.3.1"))
        #expect(request.url?.absoluteString == "https://world.openfoodfacts.org/api/v3.4/product/0722252100900?fields=product_name,brands,serving_size,serving_quantity,serving_quantity_unit,nutrition_data_per,no_nutrition_data,nutriments&product_type=food")
        #expect(request.url?.host() == "world.openfoodfacts.org")
        #expect(request.httpMethod == "GET")
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.timeoutInterval == 10)
        #expect(request.allHTTPHeaderFields?.keys.sorted() == ["Accept", "Accept-Language", "User-Agent"])
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept-Language") == "en")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "Fernlet/2.3.1 (fernlet.com)")
    }

    @Test func theUserAgentCarriesOnlyAppNameVersionAndSite() {
        #expect(OpenFoodFactsClient.userAgent(appVersion: "") == "Fernlet/1.0 (fernlet.com)")
        let hostile = OpenFoodFactsClient.userAgent(appVersion: "1.2 (someone@example.com) \n X-Injected: 1")
        #expect(!hostile.contains("@"))
        #expect(!hostile.contains("\n"))
        #expect(!hostile.contains("example"))
        #expect(hostile.hasPrefix("Fernlet/1.2") && hostile.hasSuffix("(fernlet.com)"))
    }

    // MARK: - Consent gating and the transport seam

    @Test func noRequestIsMadeWithoutConsent() async throws {
        let code = try #require(Self.clifCode)
        let recorder = RequestRecorder()
        let transport = CannedTransport(recorder: recorder, reply: .success(Self.ok(Self.clifJSON)))
        var denied = [Self.settings(permitted: false)]            // undecided
        var declined = Self.settings(permitted: false)
        declined.webNutritionLookupConsent = .declined
        var requestedNotAccepted = Self.settings(permitted: false)
        requestedNotAccepted.webNutritionLookupEnabled = true      // Settings may request, never grant
        var aiOff = Self.settings(permitted: true)
        aiOff.aiStatus = .off                                       // the whole lane closes with AI off
        denied += [declined, requestedNotAccepted, aiOff]
        for settings in denied {
            let outcome = await OpenFoodFactsClient.lookUp(code, under: settings, appVersion: "1", transport: transport)
            #expect(outcome == .notPermitted)
        }
        #expect(await recorder.count == 0, "a closed consent gate must never reach the transport")

        let permitted = await OpenFoodFactsClient.lookUp(
            code, under: Self.settings(permitted: true), appVersion: "1", transport: transport)
        #expect(permitted.succeeded)
        #expect(await recorder.count == 1, "one tap, one request — nothing retries")
    }

    @MainActor
    @Test func theAuditedRunRecordsNothingWithoutConsentAndAuditsAtDispatchWithIt() async throws {
        let code = try #require(Self.clifCode)
        let recorder = RequestRecorder()
        let transport = CannedTransport(recorder: recorder, reply: .success(Self.ok(Self.clifJSON)))
        let log = AIAuditLog()

        let refused = await OpenFoodFactsBarcodeLookup.run(
            code, settings: Self.settings(permitted: false), auditLog: log, transport: transport)
        #expect(refused == .notPermitted)
        #expect(await log.entries.isEmpty, "nothing left the device, so nothing is recorded")
        #expect(await recorder.count == 0)

        let found = await OpenFoodFactsBarcodeLookup.run(
            code, settings: Self.settings(permitted: true), auditLog: log, transport: transport)
        #expect(found.succeeded)
        let entries = await log.entries
        #expect(entries.count == 1)
        #expect(entries.first?.payloadKind == "barcode-lookup")
        #expect(entries.first?.includedFields == ["barcode"])
        #expect(entries.first?.destination == .webNutritionLookup)
        #expect(entries.first?.outcome == .succeeded)
    }

    @Test func everyFailureModeIsANamedOutcomeNotACrash() async throws {
        let code = try #require(Self.clifCode)
        let cases: [(reply: Result<OpenFoodFactsHTTPResponse, OpenFoodFactsTransportError>, expected: OpenFoodFactsLookupOutcome)] = [
            (.success(Self.response(404, body: Self.notFoundJSON)), .notFound),
            (.success(Self.response(429, body: "")), .failed(.rateLimited)),
            (.success(Self.response(500, body: "oops")), .failed(.httpStatus)),
            (.success(Self.response(302, body: "")), .failed(.httpStatus)),
            (.success(Self.response(200, body: "<html></html>", contentType: "text/html")), .failed(.notJSON)),
            (.success(Self.ok("{\"status\":\"success\",\"product\":")), .failed(.malformed)),
            (.success(Self.ok("[1,2,3]")), .failed(.malformed)),
            (.success(Self.ok("{\"status\":\"success\"}")), .failed(.malformed)),
            (.success(Self.ok("{\"status\":\"failure\",\"result\":{\"id\":\"product_not_found\"}}")), .notFound),
            (.failure(.oversize), .failed(.oversize)),
            (.failure(.network), .failed(.network)),
            (.failure(.timedOut), .failed(.timedOut)),
            (.failure(.notHTTP), .failed(.network))
        ]
        for testCase in cases {
            let transport = CannedTransport(recorder: RequestRecorder(), reply: testCase.reply)
            let outcome = await OpenFoodFactsClient.lookUp(
                code, under: Self.settings(permitted: true), appVersion: "1", transport: transport)
            #expect(outcome == testCase.expected, "\(testCase.reply) should be \(testCase.expected), got \(outcome)")
        }
    }

    @Test func aStalledServerHitsTheWholeLookupDeadline() async throws {
        let code = try #require(Self.clifCode)
        let transport = CannedTransport(
            recorder: RequestRecorder(), reply: .success(Self.ok(Self.clifJSON)), delay: .seconds(30))
        let started = ContinuousClock.now
        let outcome = await OpenFoodFactsClient.lookUp(
            code, under: Self.settings(permitted: true), appVersion: "1", transport: transport, deadlineSeconds: 0.2)
        #expect(outcome == .failed(.timedOut))
        #expect(ContinuousClock.now - started < .seconds(10), "the deadline, not the transport, ends the lookup")
    }

    @Test func anOversizeBodyIsRefusedEvenIfATransportLetsItThrough() throws {
        let code = try #require(Self.clifCode)
        let huge = Data(repeating: UInt8(ascii: " "), count: OpenFoodFactsClient.maxResponseBytes + 1)
        let outcome = OpenFoodFactsResponseClassifier.outcome(
            statusCode: 200, contentType: "application/json", body: huge, barcode: code)
        #expect(outcome == .failed(.oversize))
        #expect(EphemeralOpenFoodFactsTransport.transportError(for: URLError(.timedOut)) == .timedOut)
        #expect(EphemeralOpenFoodFactsTransport.transportError(for: URLError(.notConnectedToInternet)) == .network)
    }

    // MARK: - Parsing and mapping (real-shaped fixtures)

    @Test func aUSProductMapsPerServingIntoFernletUnits() throws {
        let product = try Self.product(Self.clifJSON, code: Self.clifCode)
        #expect(product.basis == .perServing(label: "1 bar (68 g)", quantity: 68, unit: "g"))
        #expect(product.protein == 10 && product.carbs == 43 && product.fat == 6 && product.calories == 250)
        #expect(product.suggestedName == "CLIF Chocolate Chip Energy Bar")
        let micros = product.micronutrients
        #expect(micros.fiber == 5 && micros.sugar == 17 && micros.saturatedFat == 2)
        #expect(abs((micros.calcium ?? 0) - 66) < 0.001, "OFF grams → mg")
        #expect(abs((micros.iron ?? 0) - 1.9) < 0.001)
        #expect(abs((micros.potassium ?? 0) - 379) < 0.001)
        #expect(abs((micros.sodium ?? 0) - 0.13) < 0.001, "OFF's own unit slip survives: it is not detectable")

        let item = try #require(product.foodItem(named: "  Clif chocolate chip  ", verifiedAt: Date()))
        #expect(item.name == "Clif chocolate chip")
        #expect(item.source == .openFoodFacts)
        #expect(item.dataType == .branded)
        #expect(item.brandSource == "CLIF")
        #expect(item.servingSize == 68 && item.servingUnit == RecipeUnit.gram.rawValue)
        #expect(item.servingDescription == "1 bar (68 g)")
        #expect(item.macros == Macros(protein: 10, carbs: 43, fat: 6))
        #expect(item.barcode == FoodBarcode.normalized("722252100900"))
        #expect(item.sourceURL == nil)
    }

    @Test func aEuropeanProductMapsPer100Grams() throws {
        let product = try Self.product(Self.nutellaJSON, code: Self.nutellaCode)
        #expect(product.basis == .per100(unit: "g"))
        #expect(product.brand == "Nutella")
        #expect(product.suggestedName == "Nutella", "no brand prefix when the name already carries it")
        #expect(abs((product.micronutrients.sodium ?? 0) - 42.8) < 0.001)
        let item = try #require(product.foodItem(named: "Nutella", verifiedAt: Date()))
        #expect(item.servingSize == 100 && item.servingUnit == "g" && item.servingDescription == "100 g")
        #expect(item.macros == Macros(protein: 6, carbs: 58, fat: 31))
    }

    @Test func importBoundsDropImplausibleValuesInsteadOfStoringThem() throws {
        let json = #"""
        {"status":"success","product":{"product_name":"Test\nbar\u0000 with‏control","serving_quantity":"30",
         "serving_quantity_unit":"g","serving_size":"1 bar","nutriments":{"proteins_serving":45,"carbohydrates_serving":"12.5",
         "fat_serving":true,"energy-kcal_serving":-4,"sodium_serving":0.2,"fiber_serving":31,"sugars_serving":"NaN"}}}
        """#
        let product = try Self.product(json, code: Self.clifCode)
        #expect(product.basis == .perServing(label: "1 bar", quantity: 30, unit: "g"))
        #expect(product.protein == nil, "45 g of protein cannot fit in a 30 g bar")
        #expect(product.carbs == 12.5, "OFF sometimes serves numbers as strings")
        #expect(product.fat == nil, "a JSON boolean is not a number")
        #expect(product.calories == nil, "negative energy is dropped")
        #expect(product.micronutrients.fiber == nil)
        #expect(product.micronutrients.sugar == nil)
        #expect(abs((product.micronutrients.sodium ?? 0) - 200) < 0.001)
        #expect(product.productName == "Test bar with control", "no line break can ride into a meal name or a prompt")
    }

    @Test func aProductWithoutNutritionIsFoundButNeverSavedAsAnImport() throws {
        let json = #"{"status":"success","product":{"product_name":"Mystery tea","no_nutrition_data":"on","nutriments":{"proteins_100g":1}}}"#
        let product = try Self.product(json, code: Self.clifCode)
        #expect(product.basis == nil)
        #expect(!product.hasNutrition)
        #expect(product.suggestedName == "Mystery tea")
        #expect(product.foodItem(named: "Mystery tea", verifiedAt: Date()) == nil)
        #expect(product.labelResult() == nil)
    }

    @Test func productNameIsCappedAndShoutingIsSoftened() {
        #expect(OpenFoodFactsProduct.softenedShouting("PEANUT BUTTER CUPS") == "Peanut Butter Cups")
        #expect(OpenFoodFactsProduct.softenedShouting("Dark 70% Cacao") == "Dark 70% Cacao")
        let long = String(repeating: "a", count: 500)
        #expect(OpenFoodFactsProductParser.cleanedText(long, maxLength: 80)?.count == 80)
        #expect(OpenFoodFactsProductParser.cleanedText("   ", maxLength: 80) == nil)
    }

    // MARK: - The review gate

    @MainActor
    @Test func openFoodFactsValuesRunThroughTheNamingScreensPlausibilityGate() throws {
        let clif = try Self.product(Self.clifJSON, code: Self.clifCode)
        let clean = BarcodeNotFoundView.plausibility(ofScan: clif.labelResult())
        #expect(clean.contradictions.isEmpty)
        #expect(clean.missingFields.isEmpty)

        let contradictory = #"""
        {"status":"success","product":{"product_name":"Suspicious bar","serving_size":"1 bar (40 g)","serving_quantity":40,
         "nutriments":{"energy-kcal_serving":380,"proteins_serving":2,"carbohydrates_serving":10,"fat_serving":1}}}
        """#
        let suspicious = try Self.product(contradictory, code: Self.clifCode)
        let report = BarcodeNotFoundView.plausibility(ofScan: suspicious.labelResult())
        #expect(report.contradictions.contains { finding in
            if case .caloriesDisagreeWithMacros = finding { return true }
            return false
        }, "380 kcal from 2/10/1 g of macros must reach the user as a contradiction")

        let partial = #"{"status":"success","product":{"product_name":"Half a label","nutriments":{"proteins_serving":8,"carbohydrates_serving":20}}}"#
        let missing = BarcodeNotFoundView.plausibility(ofScan: try Self.product(partial, code: Self.clifCode).labelResult())
        #expect(missing.missingFields.contains(.fat), "absent stays absent — never a claimed zero")
        #expect(missing.missingFields.contains(.servingSize))
        #expect(missing.missingFields.contains(.calories))
    }

    @MainActor
    @Test func onlyUnchangedImportedValuesKeepOpenFoodFactsProvenance() throws {
        let clif = try Self.product(Self.clifJSON, code: Self.clifCode)
        #expect(BarcodeNotFoundView.savesAsOnlineImport(scan: clif.labelResult(), imported: clif))
        var rescanned = try #require(clif.labelResult())
        rescanned.protein = 11
        #expect(!BarcodeNotFoundView.savesAsOnlineImport(scan: rescanned, imported: clif),
                "a label the user scanned since makes the numbers theirs")
        #expect(!BarcodeNotFoundView.savesAsOnlineImport(scan: nil, imported: clif))
    }

    @MainActor
    @Test func savingIsLocalUpsertsByBarcodeAndLogsNothing() throws {
        let store = makeTestStore()
        let clif = try Self.product(Self.clifJSON, code: Self.clifCode)
        let mealsBefore = store.day.meals.count

        let first = try #require(store.saveOpenFoodFactsFood(clif, named: "CLIF Chocolate Chip Energy Bar"))
        #expect(store.foodItems.contains { $0.id == first.id && $0.source == .openFoodFacts })
        #expect(store.day.meals.count == mealsBefore, "remembering is not logging — the serving step logs")
        #expect(store.foodCatalog.item(forBarcode: "722252100900")?.id == first.id, "the next scan resolves locally")
        #expect(store.foodCatalog.item(forBarcode: "0722252100900")?.id == first.id)

        let again = try #require(store.saveOpenFoodFactsFood(clif, named: "Clif bar"))
        #expect(again.id == first.id, "a repeat import refreshes the row in place")
        #expect(store.foodItems.filter { $0.source == .openFoodFacts }.count == 1)
        #expect(store.saveOpenFoodFactsFood(clif, named: "   ") == nil)

        let meal = store.logBarcodeScannedFoodItem(again, mealType: .snack, servings: 2)
        #expect(meal.macros == Macros(protein: 20, carbs: 86, fat: 12))
    }

    @Test func upsertNeverOverwritesAHandEnteredFood() throws {
        let clif = try Self.product(Self.clifJSON, code: Self.clifCode)
        let imported = try #require(clif.foodItem(named: "Clif", verifiedAt: Date()))
        var manual = imported
        manual.id = UUID()
        manual.source = .manual
        var foods = [manual]
        let stored = OpenFoodFactsImport.upsert(imported, into: &foods)
        #expect(foods.count == 2)
        #expect(foods.first == manual)
        #expect(stored.id == imported.id)
    }

    // MARK: - Consent-state routing on the card

    @Test func theCardOnlyOffersALookupTheConsentAllowsOrMayAskFor() {
        var settings = Self.settings(permitted: true)
        #expect(OpenFoodFactsLookupAccess.access(for: settings) == .permitted)
        settings = Self.settings(permitted: false)
        #expect(OpenFoodFactsLookupAccess.access(for: settings) == .askFirst, "undecided: ask at the first tap")
        settings.webNutritionLookupConsent = .declined
        #expect(OpenFoodFactsLookupAccess.access(for: settings) == .off, "declined: explain, point to Settings")
        settings.webNutritionLookupEnabled = true
        #expect(OpenFoodFactsLookupAccess.access(for: settings) == .askFirst, "re-requested in Settings: ask again")
        settings.aiStatus = .off
        #expect(OpenFoodFactsLookupAccess.access(for: settings) == .offBecauseAIOff)
    }

    // MARK: - Provenance token, attribution, ranking, audit display

    @Test func theProvenanceTokenIsFrozenAndRoundTrips() throws {
        #expect(FoodItemSource.openFoodFacts.rawValue == "openFoodFacts")
        let clif = try Self.product(Self.clifJSON, code: Self.clifCode)
        let item = try #require(clif.foodItem(named: "Clif", verifiedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        let decoded = try JSONDecoder().decode(FoodItem.self, from: JSONEncoder().encode(item))
        #expect(decoded.source == .openFoodFacts)
        #expect(decoded.unknownSourceToken == nil)
        #expect(decoded == item)
    }

    @Test func everySourceDisplayOfAnImportCarriesTheODbLAttribution() throws {
        let attribution = FoodItemSource.openFoodFactsAttribution
        #expect(attribution.contains("Open Food Facts") && attribution.contains("ODbL"))
        #expect(FoodItemSource.openFoodFacts.attributionLine == attribution)
        #expect(FoodItemSource.manual.attributionLine == nil)
        #expect(FoodItemSource.usda.attributionLine == nil)
        #expect(FoodItemSource.aiResolved.attributionLine == nil)
        let item = try #require(try Self.product(Self.clifJSON, code: Self.clifCode).foodItem(named: "Clif", verifiedAt: Date()))
        #expect(item.dataSourceLabel == attribution, "search rows name the source through dataSourceLabel")
    }

    @Test func searchRanksAnImportBetweenTheUsersOwnFoodAndReferenceData() throws {
        let base = try #require(try Self.product(Self.clifJSON, code: Self.clifCode).foodItem(named: "Energy bar", verifiedAt: Date()))
        var usda = base
        usda.id = UUID()
        usda.source = .usda
        var manual = base
        manual.id = UUID()
        manual.source = .manual
        var estimate = base
        estimate.id = UUID()
        estimate.source = .aiResolved
        let ranked = FoodItemSearch.results(for: "energy bar", in: [estimate, usda, base, manual], limit: 4)
        #expect(ranked.map(\.source) == [.manual, .openFoodFacts, .usda, .aiResolved])
    }

    @MainActor
    @Test func theActivityLogNamesABarcodeLookupAndSaysItLeftTheDevice() {
        let entry = AIAuditEntry(
            timestamp: Date(), payloadKind: "barcode-lookup", destination: .webNutritionLookup,
            outcome: .succeeded, includedFields: ["barcode"]
        )
        let row = AIAuditRow.rows(from: [entry]).first
        #expect(row?.kind == .known("Barcode lookup on Open Food Facts"))
        #expect(row?.boundary == .leftDevice)
    }

    @Test func theBarcodePayloadCarriesTheBarcodeAndNothingElse() {
        let payload = BarcodeLookupPayload(barcode: "0722252100900")
        #expect(payload.payloadKind == "barcode-lookup")
        #expect(payload.includedFieldNames == ["barcode"])
        #expect(Mirror(reflecting: payload).children.compactMap(\.label).sorted() == ["barcode", "payloadKind"])
    }

    // MARK: - Canned transport

    static func response(_ status: Int, body: String, contentType: String = "application/json; charset=utf-8") -> OpenFoodFactsHTTPResponse {
        OpenFoodFactsHTTPResponse(statusCode: status, contentType: contentType, body: data(body))
    }

    static func ok(_ json: String) -> OpenFoodFactsHTTPResponse {
        response(200, body: json)
    }
}

/// Counts the requests a canned transport received — the witness for "no request without consent".
actor RequestRecorder {
    private(set) var requests: [URLRequest] = []

    var count: Int { requests.count }

    func record(_ request: URLRequest) {
        requests.append(request)
    }
}

/// An offline transport answering every request with one canned reply, optionally after a delay.
struct CannedTransport: OpenFoodFactsTransporting {
    let recorder: RequestRecorder
    let reply: Result<OpenFoodFactsHTTPResponse, OpenFoodFactsTransportError>
    var delay: Duration?

    init(recorder: RequestRecorder, reply: Result<OpenFoodFactsHTTPResponse, OpenFoodFactsTransportError>, delay: Duration? = nil) {
        self.recorder = recorder
        self.reply = reply
        self.delay = delay
    }

    func response(for request: URLRequest, maxBytes: Int) async throws -> OpenFoodFactsHTTPResponse {
        await recorder.record(request)
        if let delay {
            try await Task.sleep(for: delay)
        }
        return try reply.get()
    }
}
