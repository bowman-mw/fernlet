import Foundation
import Testing
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
}
