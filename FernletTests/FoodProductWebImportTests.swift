import Foundation
import Testing
import FernletDomainModel
@testable import Fernlet

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
    @Test func visibleNutritionTextUsesExistingLabelParser() throws {
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

        guard let product = FoodProductWebImporter.productFromVisibleNutritionText(
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
    @Test func compactNutritionGridUsesExistingLabelParser() throws {
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

        guard let product = FoodProductWebImporter.productFromVisibleNutritionText(
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
}
