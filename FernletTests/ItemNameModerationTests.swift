import Foundation
import Testing
import FernletDomainModel

/// The list-for-sale name gate for the clothing shop (Increment 3). Pins the profanity screen (including
/// separator / leetspeak / diacritic evasions) and the never-throw name sanitizer used at the wire boundary.
struct ItemNameModerationTests {

    @Test func cleanNamesAreAllowedForListing() {
        for name in ["Sun Hat", "Cozy Sweater", "Star Cape", "Midnight Cloak", "Cool 01", "  Hat  ", ""] {
            #expect(ItemNameModeration.isAllowedForListing(name), "expected ‘\(name)’ to be allowed")
        }
    }

    @Test func profanityIsBlockedIncludingEvasions() {
        // Plain, separator-injected, leetspeak, symbol-substituted, and diacritic-folded variants.
        for name in ["shit", "a shitty hat", "ASSHOLE", "f u c k", "f.u.c.k", "5h1t", "@sshole", "fück"] {
            #expect(!ItemNameModeration.isAllowedForListing(name), "expected ‘\(name)’ to be blocked")
        }
    }

    @Test func sanitizedNameClampsLengthAndStripsInvisibleScalars() {
        let raw = "Hat\u{200B}\u{202E}" + String(repeating: "x", count: 40)
        let cleaned = ItemNameModeration.sanitizedName(raw)
        #expect(cleaned.count <= ItemNameModeration.maxNameLength)
        #expect(!cleaned.unicodeScalars.contains("\u{200B}"))   // zero-width
        #expect(!cleaned.unicodeScalars.contains("\u{202E}"))   // RTL override
    }

    @Test func sanitizedNameCollapsesWhitespace() {
        #expect(ItemNameModeration.sanitizedName("  Sun   Hat  ") == "Sun Hat")
    }
}
