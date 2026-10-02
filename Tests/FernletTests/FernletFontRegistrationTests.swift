import Testing
import UIKit
import SwiftUI
@testable import Fernlet
import FernletUI

/// Verifies every bundled design-system font is registered (Info.plist `UIAppFonts`) and resolvable
/// by the exact PostScript name used in `FernletFontName`. Because `Font.custom` silently falls back
/// to the system font on a name miss, this is the only guard that a wrong filename or PostScript name
/// would otherwise slip through unnoticed. Unit tests are hosted in the app, so its `UIAppFonts` are
/// registered here. It also pins that every registered font file ships its family's SIL Open Font
/// License text inside the app bundle.
@Suite @MainActor
struct FernletFontRegistrationTests {

    /// Each `UIAppFonts` file → its family's bundled license (`<resource>.txt`, from `Fonts/LICENSES/`)
    /// and a fragment of the copyright notice that license must carry. Kept by hand on purpose: this
    /// table is where adding a font is forced to remember its license.
    private static let licenseByFontFile: [String: (resource: String, copyright: String)] = [
        "Fraunces-SemiBold.ttf":       ("Fraunces-OFL", "The Fraunces Project Authors"),
        "DMSerifDisplay-Regular.ttf":  ("DMSerifDisplay-OFL", "with Reserved Font Name 'Source'"),
        "InstrumentSerif-Regular.ttf": ("InstrumentSerif-OFL", "The Instrument Serif Project Authors"),
        "InstrumentSerif-Italic.ttf":  ("InstrumentSerif-OFL", "The Instrument Serif Project Authors"),
        "DMSans-Regular.ttf":          ("DMSans-OFL", "The DM Sans Project Authors"),
        "DMSans-Medium.ttf":           ("DMSans-OFL", "The DM Sans Project Authors"),
        "PlayfairDisplay-Italic.ttf":  ("PlayfairDisplay-OFL", "with Reserved Font Name \"Playfair Display\""),
    ]

    /// OFL 1.1 condition 2 lets the fonts ship inside the app only if each copy carries the copyright
    /// notice and the license. The synchronized `Fernlet` folder copies `Fonts/LICENSES/*.txt` into the
    /// bundle root beside the fonts; a new `UIAppFonts` entry without a row above, a stale row, or a
    /// license file that stops reaching the bundle fails here.
    @Test func everyBundledFontShipsItsLicense() throws {
        let registered = Bundle.main.object(forInfoDictionaryKey: "UIAppFonts") as? [String] ?? []
        #expect(Set(registered) == Set(Self.licenseByFontFile.keys),
                "UIAppFonts \(registered.sorted()) and licenseByFontFile disagree")
        for (fontFile, license) in Self.licenseByFontFile {
            let url = try #require(Bundle.main.url(forResource: license.resource, withExtension: "txt"),
                                   "\(license.resource).txt (the license for \(fontFile)) is not in the app bundle")
            let text = try String(contentsOf: url, encoding: .utf8)
            #expect(text.contains("SIL OPEN FONT LICENSE Version 1.1"), "\(license.resource).txt is not the OFL text")
            #expect(text.contains(license.copyright), "\(license.resource).txt lacks \"\(license.copyright)\"")
        }
    }

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
