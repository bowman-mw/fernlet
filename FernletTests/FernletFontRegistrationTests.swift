import Testing
import UIKit
import SwiftUI
@testable import Fernlet

/// Verifies every bundled design-system font is registered (Info.plist `UIAppFonts`) and resolvable
/// by the exact PostScript name used in `FernletFontName`. Because `Font.custom` silently falls back
/// to the system font on a name miss, this is the only guard that a wrong filename or PostScript name
/// would otherwise slip through unnoticed. Unit tests are hosted in the app, so its `UIAppFonts` are
/// registered here.
@Suite @MainActor
struct FernletFontRegistrationTests {

    @Test func allBundledFontsResolveByPostScriptName() {
        for name in FernletFontName.all {
            let font = UIFont(name: name, size: 17)
            #expect(font != nil, "Font not registered or wrong PostScript name: \(name)")
            // UIFont(name:) resolves the requested face exactly when the name matches.
            #expect(font?.fontName == name, "Resolved to \(font?.fontName ?? "nil"), expected \(name)")
        }
    }

    @Test func everyTypeRoleProducesAFont() {
        let roles: [FernletTextRole] = [
            .wordmark, .display, .displayMedium, .header, .headerMedium,
            .body, .bodySmall, .bubble, .label, .labelSmall, .stat,
        ]
        // Smoke check that resolving each role doesn't trap; the registration test above proves the
        // underlying faces exist.
        for role in roles {
            _ = Font.fernlet(role)
        }
        #expect(roles.count == 11)
    }
}
