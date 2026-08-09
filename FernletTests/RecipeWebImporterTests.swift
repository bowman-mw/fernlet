import Foundation
import Testing
import FernletDomainModel
import AIProviders
import AppServices
@testable import Fernlet

struct RecipeWebImporterTests {
    /// Regression for prior finding #19: ordinary public https recipe URLs are allowed.
    @Test func acceptsPublicHTTPSURLs() {
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://example.com/recipe")!))
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://www.allrecipes.com/r/123")!))
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://8.8.8.8/x")!))
        // 172.32.x is just outside the private 172.16–31 range.
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://172.32.0.1/x")!))
    }

    @Test func rejectsNonHTTPSOrHostlessURLs() {
        #expect(!RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "http://example.com")!))
        #expect(!RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "ftp://example.com")!))
        #expect(!RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "file:///etc/passwd")!))
    }

    /// The SSRF surface: a public page must not be able to redirect (or a queued URL point) to a
    /// loopback / private / link-local address — including the cloud metadata endpoint.
    @Test func rejectsLoopbackPrivateAndLinkLocalHosts() {
        let unsafe = [
            "https://localhost/x",
            "https://127.0.0.1/x",
            "https://10.0.0.5/x",
            "https://192.168.1.1/x",
            "https://172.16.0.1/x",
            "https://172.31.255.255/x",
            "https://169.254.169.254/x",
            "https://[::1]/x",
            "https://[fe80::1]/x",
            "https://[fd00::abcd]/x"
        ]
        for raw in unsafe {
            #expect(!RecipeWebImporter.isSafePublicHTTPSURL(URL(string: raw)!), "must reject \(raw)")
        }
    }

    // MARK: - Image extraction (owner decision 2026-08-09)

    private let pageURL = URL(string: "https://example.com/recipes/oats")!

    private func jsonLDPage(imageJSON: String) -> String {
        """
        <html><head>
        <script type="application/ld+json">
        {"@context":"https://schema.org","@type":"Recipe","name":"Oats","recipeIngredient":["1 cup oats"],"image":\(imageJSON)}
        </script>
        </head><body></body></html>
        """
    }

    @Test func extractsJSONLDImageString() {
        let html = jsonLDPage(imageJSON: #""https://cdn.example.com/hero.jpg""#)
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/hero.jpg")
    }

    @Test func extractsJSONLDImageStringArray() {
        let html = jsonLDPage(imageJSON: #"["https://cdn.example.com/a.jpg","https://cdn.example.com/b.jpg"]"#)
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/a.jpg")
    }

    @Test func extractsJSONLDImageObject() {
        let html = jsonLDPage(imageJSON: #"{"@type":"ImageObject","url":"https://cdn.example.com/obj.jpg","width":1200}"#)
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/obj.jpg")
    }

    @Test func extractsJSONLDImageObjectContentUrl() {
        let html = jsonLDPage(imageJSON: #"{"@type":"ImageObject","contentUrl":"https://cdn.example.com/content.jpg"}"#)
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/content.jpg")
    }

    @Test func extractsJSONLDImageObjectArray() {
        let html = jsonLDPage(imageJSON: #"[{"@type":"ImageObject","url":"https://cdn.example.com/first.jpg"},{"@type":"ImageObject","url":"https://cdn.example.com/second.jpg"}]"#)
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/first.jpg")
    }

    @Test func fallsBackToOGImageWhenNoJSONLDImage() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://cdn.example.com/og.jpg" />
        </head><body></body></html>
        """
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/og.jpg")
    }

    @Test func fallsBackToTwitterImage() {
        let html = """
        <html><head>
        <meta name="twitter:image" content="https://cdn.example.com/tw.jpg" />
        </head><body></body></html>
        """
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/tw.jpg")
    }

    @Test func jsonLDImageWinsOverMetaTags() {
        let html = """
        <html><head>
        <meta property="og:image" content="https://cdn.example.com/og.jpg" />
        <script type="application/ld+json">
        {"@type":"Recipe","name":"Oats","recipeIngredient":["oats"],"image":"https://cdn.example.com/ld.jpg"}
        </script>
        </head></html>
        """
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/ld.jpg")
    }

    @Test func resolvesRelativeImageURLAgainstThePage() {
        let html = jsonLDPage(imageJSON: #""/images/hero.jpg""#)
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://example.com/images/hero.jpg")
    }

    @Test func upgradesHTTPImageURLToHTTPS() {
        let html = jsonLDPage(imageJSON: #""http://cdn.example.com/hero.jpg""#)
        #expect(RecipeWebImporter.extractedImageURL(from: html, sourceURL: pageURL)?.absoluteString == "https://cdn.example.com/hero.jpg")
    }

    @Test func rejectsDataURIAndMissingImage() {
        let dataURI = jsonLDPage(imageJSON: #""data:image/png;base64,AAAA""#)
        #expect(RecipeWebImporter.extractedImageURL(from: dataURI, sourceURL: pageURL) == nil)
        let none = "<html><head></head><body>no picture here</body></html>"
        #expect(RecipeWebImporter.extractedImageURL(from: none, sourceURL: pageURL) == nil)
    }

    // MARK: - Image download guard

    @Test func downloadRejectsNonHTTPSImageURL() async {
        await #expect(throws: RecipeWebImportError.invalidURL) {
            _ = try await RecipeWebImporter.downloadImage(from: URL(string: "http://example.com/hero.jpg")!)
        }
    }

    @Test func downloadRejectsPrivateAndLoopbackImageHosts() async {
        for raw in ["https://127.0.0.1/x.jpg", "https://10.0.0.5/x.jpg", "https://169.254.169.254/x.jpg", "https://[::1]/x.jpg"] {
            await #expect(throws: RecipeWebImportError.invalidURL, "must reject \(raw)") {
                _ = try await RecipeWebImporter.downloadImage(from: URL(string: raw)!)
            }
        }
    }

    @Test func imageMIMETypeCheck() {
        #expect(RecipeWebImporter.isImageMIMEType("image/jpeg"))
        #expect(RecipeWebImporter.isImageMIMEType("IMAGE/PNG"))
        #expect(!RecipeWebImporter.isImageMIMEType("text/html"))
        #expect(!RecipeWebImporter.isImageMIMEType("application/octet-stream"))
        #expect(!RecipeWebImporter.isImageMIMEType(nil))
    }

    private func imageResponse(status: Int = 200, headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://cdn.example.com/hero.jpg")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )!
    }

    @Test func validateImageResponseAcceptsWellFormedImage() throws {
        let response = imageResponse(headers: ["Content-Type": "image/jpeg", "Content-Length": "1024"])
        try RecipeWebImporter.validateImageResponse(response, maxBytes: 10 * 1024 * 1024)  // must not throw
    }

    @Test func validateImageResponseRejectsWrongMIME() {
        let response = imageResponse(headers: ["Content-Type": "text/html"])
        #expect(throws: RecipeWebImportError.fetchFailed) {
            try RecipeWebImporter.validateImageResponse(response, maxBytes: 10 * 1024 * 1024)
        }
    }

    @Test func validateImageResponseRejectsDeclaredOversize() {
        let response = imageResponse(headers: ["Content-Type": "image/jpeg", "Content-Length": "\(11 * 1024 * 1024)"])
        #expect(throws: RecipeWebImportError.fetchFailed) {
            try RecipeWebImporter.validateImageResponse(response, maxBytes: 10 * 1024 * 1024)
        }
    }

    @Test func validateImageResponseRejectsNon2xx() {
        let response = imageResponse(status: 404, headers: ["Content-Type": "image/jpeg"])
        #expect(throws: RecipeWebImportError.fetchFailed) {
            try RecipeWebImporter.validateImageResponse(response, maxBytes: 10 * 1024 * 1024)
        }
    }

    /// The undeclared-length half of the size guard: a stream that exceeds the cap ABORTS (throws),
    /// never truncates into a corrupt image.
    @MainActor
    @Test func accumulateAbortsOversizeStream() async {
        let oversize = AsyncStream<UInt8> { continuation in
            for _ in 0..<64 { continuation.yield(0xFF) }
            continuation.finish()
        }
        await #expect(throws: RecipeWebImportError.fetchFailed) {
            _ = try await RecipeWebImporter.accumulateImageBytes(oversize, maxBytes: 32)
        }

        let withinCap = AsyncStream<UInt8> { continuation in
            for _ in 0..<16 { continuation.yield(0x11) }
            continuation.finish()
        }
        let data = try? await RecipeWebImporter.accumulateImageBytes(withinCap, maxBytes: 32)
        #expect(data?.count == 16)
    }

    // MARK: - Bridge carry-through

    @MainActor
    @Test func bridgeCarriesImageURLIntoWebImport() {
        let imported = ImportedRecipe(
            sourceURL: URL(string: "https://example.com/recipes/oats")!,
            name: "Oats",
            ingredients: ["1 cup oats"],
            summary: "Cook the oats.",
            servings: 2,
            protein: 10,
            carbs: 30,
            fat: 5,
            imageURL: URL(string: "https://cdn.example.com/hero.jpg")
        )
        let recipe = RecipeDefinition(importedRecipe: imported)
        #expect(recipe.webImport?.imageURLString == "https://cdn.example.com/hero.jpg")
        // The bridge must NOT pre-stamp the attempt — the one automatic download hasn't run yet.
        #expect(recipe.webImport?.webImageFetchAttempted == nil)
    }

    @MainActor
    @Test func bridgeLeavesImageURLNilWhenPageHadNone() {
        let imported = ImportedRecipe(
            sourceURL: URL(string: "https://example.com/recipes/oats")!,
            name: "Oats",
            ingredients: ["1 cup oats"],
            summary: "Cook the oats.",
            servings: 1,
            protein: 10,
            carbs: 30,
            fat: 5
        )
        #expect(RecipeDefinition(importedRecipe: imported).webImport?.imageURLString == nil)
    }
}
