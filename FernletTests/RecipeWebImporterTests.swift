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

    /// Non-dotted-quad IP-literal encodings must classify like their canonical spelling: the image
    /// URL is page-controlled content (JSON-LD `image` / og:image), so a malicious page could
    /// otherwise smuggle a loopback/private target past a dotted-quad-only check via decimal,
    /// hex, octal, partial-form, or IPv4-mapped-IPv6 spellings.
    @Test func rejectsEncodedLoopbackAndPrivateIPLiterals() {
        let unsafe = [
            "https://2130706433/x",             // decimal integer = 127.0.0.1
            "https://0x7f.0.0.1/x",             // hex = 127.0.0.1
            "https://0177.0.0.1/x",             // octal = 127.0.0.1
            "https://0x7f000001/x",             // hex integer = 127.0.0.1
            "https://127.1/x",                  // 2-part form = 127.0.0.1
            "https://10.5/x",                   // 2-part form = 10.0.0.5
            "https://[::ffff:127.0.0.1]/x",     // IPv4-mapped IPv6 loopback
            "https://[::ffff:10.0.0.5]/x",      // IPv4-mapped IPv6 private
            "https://[::127.0.0.1]/x",          // IPv4-compatible IPv6 loopback
            "https://3232235777/x"              // decimal integer = 192.168.1.1
        ]
        for raw in unsafe {
            #expect(!RecipeWebImporter.isSafePublicHTTPSURL(URL(string: raw)!), "must reject \(raw)")
        }
        // Public addresses in exotic spellings and real hostnames stay allowed — including
        // hostnames starting with "fc"/"fd", which the old prefix check misread as IPv6 literals.
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://134744072/x")!))  // 8.8.8.8
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://fcbarcelona.com/x")!))
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://fda.gov/x")!))
        // A hostname with an embedded private-looking dotted prefix is a hostname, not a literal.
        #expect(RecipeWebImporter.isSafePublicHTTPSURL(URL(string: "https://10.0.0.5.example.com/x")!))
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

    /// Generic binary declarations — the S3-style default for image CDNs with no content-type
    /// metadata — are tolerated (paired with the byte sniff below); anything else stays refused.
    @Test func genericBinaryMIMETypeCheck() {
        #expect(RecipeWebImporter.isGenericBinaryMIMEType("application/octet-stream"))
        #expect(RecipeWebImporter.isGenericBinaryMIMEType("APPLICATION/OCTET-STREAM"))
        #expect(RecipeWebImporter.isGenericBinaryMIMEType("binary/octet-stream"))
        #expect(!RecipeWebImporter.isGenericBinaryMIMEType("text/html"))
        #expect(!RecipeWebImporter.isGenericBinaryMIMEType("application/json"))
        #expect(!RecipeWebImporter.isGenericBinaryMIMEType(nil))
    }

    /// The magic-number sniff that gates the octet-stream tolerance: real image containers pass,
    /// HTML error pages and arbitrary bytes do not.
    @Test func imageByteSniffAcceptsRealContainersOnly() {
        #expect(RecipeWebImporter.looksLikeImageBytes(Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00])))         // JPEG
        #expect(RecipeWebImporter.looksLikeImageBytes(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]))) // PNG
        #expect(RecipeWebImporter.looksLikeImageBytes(Data("GIF89a".utf8)))                          // GIF
        var webp = Data("RIFF".utf8); webp.append(Data([0x10, 0x00, 0x00, 0x00])); webp.append(Data("WEBP".utf8))
        #expect(RecipeWebImporter.looksLikeImageBytes(webp))                                         // WebP
        var heic = Data([0x00, 0x00, 0x00, 0x18]); heic.append(Data("ftypheic".utf8))
        #expect(RecipeWebImporter.looksLikeImageBytes(heic))                                         // HEIC (ftyp)
        #expect(!RecipeWebImporter.looksLikeImageBytes(Data("<!DOCTYPE html><html>".utf8)))
        #expect(!RecipeWebImporter.looksLikeImageBytes(Data("Access denied".utf8)))
        #expect(!RecipeWebImporter.looksLikeImageBytes(Data()))
        // RIFF that is NOT WebP (e.g. a WAV) must not pass.
        var wav = Data("RIFF".utf8); wav.append(Data([0x10, 0x00, 0x00, 0x00])); wav.append(Data("WAVE".utf8))
        #expect(!RecipeWebImporter.looksLikeImageBytes(wav))
    }

    /// The header validator tolerates a generic binary declaration (the bytes are then sniffed at
    /// download time) — restoring the label images retailer CDNs serve as octet-stream — while
    /// text/html and other explicit non-image declarations stay refused.
    @Test func validateImageResponseToleratesGenericBinaryDeclarations() throws {
        let octetStream = imageResponse(headers: ["Content-Type": "application/octet-stream", "Content-Length": "1024"])
        try RecipeWebImporter.validateImageResponse(octetStream, maxBytes: 10 * 1024 * 1024)  // must not throw
        let binaryStream = imageResponse(headers: ["Content-Type": "binary/octet-stream"])
        try RecipeWebImporter.validateImageResponse(binaryStream, maxBytes: 10 * 1024 * 1024) // must not throw
        // The oversize check still applies to tolerated declarations.
        let oversize = imageResponse(headers: ["Content-Type": "application/octet-stream", "Content-Length": "\(11 * 1024 * 1024)"])
        #expect(throws: RecipeWebImportError.fetchFailed) {
            try RecipeWebImporter.validateImageResponse(oversize, maxBytes: 10 * 1024 * 1024)
        }
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
        // The bridge must NOT pre-suppress — no user intent exists yet, and the attempt
        // bookkeeping is device-local, never a row field.
        #expect(recipe.webImport?.webImageSuppressed == nil)
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
