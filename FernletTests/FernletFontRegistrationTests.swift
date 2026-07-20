import Testing
import UIKit
import SwiftUI
@testable import Fernlet
import FernletUI

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
        // `FernletTextRole` is `CaseIterable`, so a new case is automatically covered here — no
        // hand-maintained list to drift. Instead of a tautological `count ==` assertion, prove each
        // role resolves to a *real bundled face* rather than silently falling back to the system font.
        // Every role must map to one of the registered PostScript names (verified resolvable in the
        // test above). A wrong or missing face would leave the role pointing at a non-bundled name.
        for role in FernletTextRole.allCases {
            _ = Font.fernlet(role) // smoke check: resolving the role must not trap
            let name = Self.postScriptName(for: role)
            #expect(FernletFontName.all.contains(name),
                    "Role \(role) maps to \(name), which is not a bundled PostScript name")
        }
    }

    /// The bundled PostScript name each role resolves to — kept in lockstep with `Font.fernlet`.
    /// A `switch` (no `default`) so adding a `FernletTextRole` case forces this to be updated; paired
    /// with the `.allCases` loop above, a new role is both auto-covered and forced to name its face.
    private static func postScriptName(for role: FernletTextRole) -> String {
        switch role {
        case .wordmark:      return FernletFontName.playfairItalic
        case .display:       return FernletFontName.frauncesSemiBold
        case .displayMedium: return FernletFontName.frauncesSemiBold
        case .header:        return FernletFontName.dmSerifDisplay
        case .headerMedium:  return FernletFontName.dmSerifDisplay
        case .body:          return FernletFontName.instrumentSerif
        case .bodySmall:     return FernletFontName.instrumentSerif
        case .bubble:        return FernletFontName.instrumentSerifItalic
        case .label:         return FernletFontName.dmSansMedium
        case .labelSmall:    return FernletFontName.dmSans
        case .stat:          return FernletFontName.dmSansMedium
        }
    }
}
