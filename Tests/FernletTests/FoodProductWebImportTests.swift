import Foundation
import Testing
import FernletDomainModel
import AppServices
@testable import Fernlet

#if canImport(UIKit)
import UIKit
#endif

struct FoodProductWebImportTests {
    @MainActor
    @Test func structuredProductExtractsSchemaNutrition() throws {
        let html = """
        <html>
          <head>
            <script type="application/ld+json">
              {
                "@type": "Product",
                "name": "Chicken Melt",
                "brand": { "@type": "Brand", "name": "Example Foods" },
                "nutrition": {
                  "@type": "NutritionInformation",
                  "servingSize": "1 sandwich (142 g)",
                  "proteinContent": "19 g",
                  "carbohydrateContent": "31 g",
                  "fatContent": "13 g",
                  "fiberContent": "2 g",
                  "sodiumContent": "640 mg"
                }
              }
            </script>
          </head>
        </html>
        """

        guard let product = FoodProductWebImporter.structuredProduct(
            from: html,
            sourceURL: URL(string: "https://example.com/chicken-melt")!
        ) else {
            Issue.record("Expected structured product nutrition to be extracted.")
            return
        }

        #expect(product.name == "Chicken Melt")
        #expect(product.brand == "Example Foods")
        #expect(product.servingSize == "1 sandwich (142 g)")
        #expect(product.macros.protein == 19)
        #expect(product.macros.carbs == 31)
        #expect(product.macros.fat == 13)
        #expect(product.micronutrients.fiber == 2)
        #expect(product.micronutrients.sodium == 640)
    }

    @Test func candidateImageURLsIgnoreUnmarkedNonProductImages() throws {
        let sourceURL = try #require(URL(string: "https://example.com/products/chicken-melt"))
        let html = """
        <html>
          <body>
            <img src="/images/logo.png" alt="Brand logo" width="64" height="64">
            <img src="/images/lifestyle.jpg" alt="Serving suggestion">
          </body>
        </html>
        """

        #expect(FoodProductWebImporter.candidateImageURLs(from: html, sourceURL: sourceURL).isEmpty)
    }

    @Test func incompleteNutritionLabelScanIsRejected() {
        let partial = NutritionLabelResult(protein: 11, carbs: 2, fat: 2)
        #expect(!FoodProductWebImporter.isCompleteNutritionLabelScan(partial))

        let complete = NutritionLabelResult(
            servingSize: "1 snack sandwich (71g)",
            calories: 180,
            protein: 9,
            carbs: 18,
            fat: 7
        )
        #expect(FoodProductWebImporter.isCompleteNutritionLabelScan(complete))
    }

    @MainActor
    @Test func storeUpdatesEarlierWebImportByNormalizedName() throws {
        let store = makeTestStore()
        let sourceURL = try #require(URL(string: "https://example.com/chicken-melt"))
        let first = ImportedFoodProduct(
            sourceURL: sourceURL,
            name: "Chicken Melt",
            brand: "Example Foods",
            servingSize: "1 sandwich",
            macros: Macros(protein: 18, carbs: 30, fat: 12),
            micronutrients: Micronutrients()
        )
        let second = ImportedFoodProduct(
            sourceURL: sourceURL,
            name: " chicken melt ",
            brand: "Example Foods",
            servingSize: "1 sandwich",
            macros: Macros(protein: 19, carbs: 31, fat: 13),
            micronutrients: Micronutrients(sodium: 640)
        )

        let original = store.saveWebImportedFoodProduct(first)
        let updated = store.saveWebImportedFoodProduct(second)

        #expect(store.foodItems.count == 1)
        #expect(store.webImportedFoodItems.count == 1)
        #expect(updated.id == original.id)
        #expect(updated.source == .aiResolved)
        #expect(updated.dataType == .branded)
        #expect(updated.sourceURL == sourceURL)
        #expect(updated.servingDescription == "1 sandwich")
        #expect(updated.macros.protein == 19)
        #expect(updated.macros.carbs == 31)
        #expect(updated.macros.fat == 13)
        #expect(updated.micronutrients.sodium == 640)

        let meal = store.logWebImportedFoodProduct(updated, mealType: .snack)
        #expect(meal.name == updated.name)
        #expect(meal.mealType == .snack)
        #expect(meal.macros == updated.macros)
        #expect(meal.source == MealLogSource.webImport)
        #expect(store.day.meals.last?.id == meal.id)
    }

    @Test func candidateImageURLsResolveRelativePathsAndPrioritizeNutritionLabels() throws {
        let sourceURL = try #require(URL(string: "https://example.com/products/chicken-melt"))
        let html = """
        <html>
          <body>
            <img src="/images/front-package.jpg" alt="Chicken melt box">
            <img data-src="/images/chicken-melt-nutrition-facts.jpg" alt="Nutrition facts label">
            <img src="https://cdn.example.com/ingredients.jpg" alt="Ingredients">
          </body>
        </html>
        """

        let imageURLs = FoodProductWebImporter.candidateImageURLs(from: html, sourceURL: sourceURL)

        #expect(imageURLs.first == URL(string: "https://example.com/images/chicken-melt-nutrition-facts.jpg"))
        #expect(imageURLs.contains(URL(string: "https://cdn.example.com/ingredients.jpg")!))
    }

    @MainActor
    @Test func visibleNutritionTextUsesExistingLabelParser() async throws {
        let sourceURL = try #require(URL(string: "https://example.com/products/chicken-melt"))
        let html = """
        <html>
          <body>
            <div>Nutrition Facts</div>
            <div>Serving size 1 sandwich (142 g)</div>
            <div>Total Fat 13g</div>
            <div>Total Carbohydrate 31g</div>
            <div>Protein 19g</div>
            <div>Sodium 640mg</div>
          </body>
        </html>
        """

        guard let product = await FoodProductWebImporter.productFromVisibleNutritionText(
            in: html,
            fallbackName: "Chicken Melt",
            sourceURL: sourceURL
        ) else {
            Issue.record("Expected visible nutrition text to produce a product.")
            return
        }

        #expect(product.name == "Chicken Melt")
        #expect(product.servingSize == "1 sandwich (142 g)")
        #expect(product.macros.protein == 19)
        #expect(product.macros.carbs == 31)
        #expect(product.macros.fat == 13)
        #expect(product.micronutrients.sodium == 640)
    }

    @Test func bareRetailerURLDefaultsToHTTPS() {
        let url = FoodProductWebImporter.normalizedWebURL(
            from: "www.costco.com/p/-/sandwich-bros-chicken-melts/100433122"
        )

        #expect(url?.absoluteString == "https://www.costco.com/p/-/sandwich-bros-chicken-melts/100433122")
    }

    @Test func blockedRetailerFallbackQueryUsesProductSlug() throws {
        let url = try #require(URL(string: "https://www.costco.com/p/-/sandwich-bros-chicken-melts-pita-snack-sandwiches-25-oz-15-count/100433122"))

        #expect(FoodProductWebImporter.fallbackSearchText(from: url) == "sandwich bros chicken melts pita snack sandwiches 25 oz 15 count")
    }

    @Test func searchResultsDecodeDuckDuckGoRedirect() throws {
        let html = """
        <a class="result__a" href="//duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.costco.com%2Fp%2F-%2Fsandwich-bros-chicken-melts%2F100433122">
          Sandwich Bros Chicken Melts | Costco
        </a>
        """

        let result = try #require(FoodProductWebSearch.searchResults(from: html).first)

        #expect(result.title == "Sandwich Bros Chicken Melts | Costco")
        #expect(result.sourceURL.absoluteString == "https://www.costco.com/p/-/sandwich-bros-chicken-melts/100433122")
    }

    @Test func officialRetailerSearchResultWinsOverSecondaryNutritionDatabase() throws {
        let html = """
        <a class="result__a" href="https://foods.fatsecret.com/calories-nutrition/costco/chicken-melt">
          Calories in Costco Chicken Melt and Nutrition Facts - FatSecret
        </a>
        <a class="result__a" href="https://www.costco.com/p/-/sandwich-bros-chicken-melts/100433122">
          Sandwich Bros Chicken Melts | Costco
        </a>
        """

        let result = try #require(FoodProductWebSearch.preferredSearchResults(from: html).first)

        #expect(result.sourceURL.host() == "www.costco.com")
    }

    @Test func supplementalNutritionLabelURLsDiscoverFirstPartyNutritionAssetFromHTML() throws {
        let sourceURL = try #require(URL(string: "https://www.costco.com/p/-/sandwich-bros-chicken-melts/100433122"))
        let html = """
        <html>
          <body>
            <script>
              window.__PRODUCT__ = {
                images: [
                  "https:\\/\\/bfasset.costco-static.com\\/U447IH35\\/as\\/front-package.jpg",
                  "https:\\/\\/bfasset.costco-static.com\\/U447IH35\\/as\\/100433122-847_2-nutrition-facts.jpg?auto=webp&format=jpg&width=727"
                ]
              }
            </script>
          </body>
        </html>
        """

        let labelURL = try #require(FoodProductWebImporter.supplementalNutritionLabelURLs(from: html, sourceURL: sourceURL).first)

        #expect(labelURL.host() == "bfasset.costco-static.com")
        #expect(labelURL.path.contains("100433122-847_2-nutrition-facts"))
        #expect(FoodProductWebImporter.isDirectImageURL(labelURL))
    }

    @Test func supplementalNutritionLabelURLsDiscoverSrcsetMetaAndJSONLDImages() throws {
        let sourceURL = try #require(URL(string: "https://example.com/products/chicken-melt"))
        let html = """
        <html>
          <head>
            <meta property="og:image" content="/images/product-front.jpg">
            <script type="application/ld+json">
              { "@type": "Product", "image": ["/images/jsonld-nutrition-label.jpg"] }
            </script>
          </head>
          <body>
            <picture>
              <source srcset="/images/nutrition-small.jpg 400w, /images/nutrition-large.jpg 900w" media="(min-width: 600px)">
            </picture>
          </body>
        </html>
        """

        let imageURLs = FoodProductWebImporter.supplementalNutritionLabelURLs(from: html, sourceURL: sourceURL)

        #expect(imageURLs.contains(URL(string: "https://example.com/images/jsonld-nutrition-label.jpg")!))
        #expect(imageURLs.contains(URL(string: "https://example.com/images/nutrition-large.jpg")!))
    }

    @Test func retailerSpecificDescriptionTriggersSearchUntilReviewedProductExists() {
        let description = "2 chicken melts from costco"
        #expect(FoodProductWebSearch.shouldSearch(for: description, foodItems: []))
        #expect(FoodProductWebSearch.shouldSearch(for: "2 costco chicken melts", foodItems: []))

        let reviewedProduct = FoodItem(
            name: "Sandwich Bros Chicken Melts",
            brandSource: "Sandwich Bros",
            servingSize: 1,
            servingUnit: RecipeUnit.serving.rawValue,
            macros: Macros(protein: 12, carbs: 17, fat: 8),
            micronutrients: Micronutrients(),
            category: "web product",
            source: .aiResolved,
            tags: ["web-import"]
        )

        #expect(!FoodProductWebSearch.shouldSearch(for: description, foodItems: [reviewedProduct]))
    }

    @MainActor
    @Test func compactNutritionGridUsesExistingLabelParser() async throws {
        let sourceURL = try #require(URL(string: "https://foods.example.com/calories-nutrition/costco/chicken-melt"))
        let html = """
        <html>
          <head>
            <meta name="description" content="There are 180 calories in 1 package (71 g) of Costco Chicken Melt."/>
          </head>
          <body>
            <table><tr>
              <td class="box">Calories<div>180</div></td>
              <td class="box">Fat<div>8 g</div></td>
              <td class="box">Carbs<div>17 g</div></td>
              <td class="box">Protein<div>10 g</div></td>
            </tr></table>
          </body>
        </html>
        """

        guard let product = await FoodProductWebImporter.productFromVisibleNutritionText(
            in: html,
            fallbackName: "Calories in Costco Chicken Melt and Nutrition Facts - Example",
            sourceURL: sourceURL
        ) else {
            Issue.record("Expected compact webpage nutrition grid to produce a product.")
            return
        }

        #expect(product.name == "Costco Chicken Melt")
        #expect(product.servingSize == "1 package (71 g)")
        #expect(product.calories == 180)
        #expect(product.macros.protein == 10)
        #expect(product.macros.carbs == 17)
        #expect(product.macros.fat == 8)
    }

    // MARK: - Egress guards (2026-08-18 security round, findings L24 + L23)

    /// The product-page fetch used to be a bare `url.scheme == "https"` test, so a private, loopback
    /// or link-local literal reached the network — while the recipe importer next door already
    /// rejected all of these. `fetchHTML` now runs `RecipeWebImporter.isSafePublicHTTPSURL`.
    ///
    /// Deterministic and offline BY CONSTRUCTION: the guard rejects before a request is built, so a
    /// passing run makes zero network calls. Asserting the exact `.invalidURL` case (rather than
    /// merely "it throws") is what makes this a regression test — if the guard is ever reverted to
    /// scheme-only these hosts reach the network and surface as `.fetchFailed`, which fails here on
    /// the case mismatch instead of hanging for 15 s a host at a time.
    ///
    /// `.invalidURL` is also load-bearing beyond the guard: `preview(from:)` catches ONLY
    /// `.fetchFailed` before falling back to a DuckDuckGo search, so a URL rejected here is never
    /// re-egressed as a search query.
    @MainActor
    @Test func fetchHTMLRejectsPrivateAndLoopbackHostsInEverySpelling() async {
        let blocked = [
            "https://localhost/x", "https://127.0.0.1/x", "https://10.0.0.5/x",
            "https://192.168.1.1/setup", "https://172.16.0.1/x",
            "https://169.254.169.254/latest/meta-data",
            "https://2130706433/x", "https://0x7f.0.0.1/x", "https://0177.0.0.1/x",
            "https://127.1/x", "https://[::1]/x", "https://[::ffff:127.0.0.1]/x"
        ]
        for raw in blocked {
            guard let url = URL(string: raw) else {
                Issue.record("bad fixture \(raw)")
                continue
            }
            do {
                _ = try await FoodProductWebImporter.fetchHTML(from: url)
                Issue.record("\(raw) was fetched — the product-page SSRF guard is gone.")
            } catch FoodProductWebImportError.invalidURL {
                continue    // expected
            } catch {
                Issue.record("\(raw) failed as \(error), not .invalidURL — the guard was weakened.")
            }
        }
    }

    /// The redirect half of the SSRF guard cannot be reached by a unit test without a local HTTP
    /// server, which this suite does not have — so it is pinned structurally instead, the same
    /// grep-wall shape the repo already uses for `URLSession.shared`. The delegate is the half no
    /// runtime test here can observe, which is exactly why it needs a control that stays broken if
    /// someone drops it.
    @Test func everyProductPageFetchPassesTheRedirectValidator() throws {
        let source = try String(
            contentsOf: RepoRoot.url.appendingPathComponent("App/Fernlet/FoodProductWebImporter.swift"),
            encoding: .utf8
        )
        let calls = source.components(separatedBy: ".bytes(").dropFirst()
        #expect(!calls.isEmpty, "FoodProductWebImporter no longer streams a page — re-point this rule.")
        for call in calls {
            let head = String(call.prefix(200))
            #expect(
                head.contains("delegate:"),
                "A bytes(for:) call in FoodProductWebImporter has no delegate: argument. Without RecipeWebImporter.RedirectValidator a public page can 30x to an internal address and only the initial URL was ever checked."
            )
        }
    }

    #if canImport(UIKit)
    /// A web label image is untrusted bytes: the download's 12 MB cap bounds the TRANSFER, not the
    /// bitmap. A few-hundred-KB flat PNG can declare 256 MP, which `UIImage(data:)` would happily
    /// materialise as ~1 GB of RGBA — and then Vision's preprocessing renders it again.
    ///
    /// Fixtures are thin strips on purpose (mirroring `PrivateMediaStoreTests`): the over-dimension
    /// case must never allocate a real bomb inside the test process.
    @MainActor
    @Test func webLabelImageRejectsPixelBombAndBoundsTheDecode() throws {
        let overWide = try png(width: 7_000, height: 4)
        let overArea = try png(width: 5_000, height: 5_000)
        let acceptableLarge = try png(width: 3_000, height: 3_000)
        let ordinaryCrop = try png(width: 600, height: 800)

        #expect(FoodProductWebImporter.boundedLabelImage(from: overWide) == nil,
                "over the per-axis bound — must be refused from the header, without decoding.")
        #expect(FoodProductWebImporter.boundedLabelImage(from: overArea) == nil,
                "25 MP is inside the per-axis bound but over the area bound — the clause a dimension-only fix misses.")
        #expect(FoodProductWebImporter.boundedLabelImage(from: Data("not an image".utf8)) == nil,
                "undeterminable dimensions are unsafe.")

        guard let big = FoodProductWebImporter.boundedLabelImage(from: acceptableLarge) else {
            Issue.record("A 9 MP label image must still scan.")
            return
        }
        #expect(max(big.size.width, big.size.height) <= 2_400, "the OCR decode must be bounded.")

        guard let small = FoodProductWebImporter.boundedLabelImage(from: ordinaryCrop) else {
            Issue.record("An ordinary retailer label crop must be untouched.")
            return
        }
        #expect(small.size == CGSize(width: 600, height: 800), "a small image must never be upscaled.")
    }

    /// A flat 8-bit grayscale PNG of the requested pixel size.
    ///
    /// Grayscale, not RGBA, deliberately: the area-bound fixture is 25 MP by definition, and an RGBA
    /// renderer would allocate ~100 MB inside the test process to prove a guard that only ever reads
    /// the file header. One byte per pixel keeps it to ~25 MB, and the flat fill keeps the encoded
    /// PNG a few KB.
    private func png(width: Int, height: Int) throws -> Data {
        struct PNGEncodingFailed: Error {}
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            throw PNGEncodingFailed()
        }
        context.setFillColor(gray: 0.5, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        guard let cgImage = context.makeImage(),
              let data = UIImage(cgImage: cgImage).pngData() else {
            throw PNGEncodingFailed()
        }
        return data
    }
    #endif
}
