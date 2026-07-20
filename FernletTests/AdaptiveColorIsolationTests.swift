import Foundation
import SwiftUI
import Testing
import FernletUI
#if canImport(UIKit)
import UIKit
#endif

/// Regression guard for the device-only tab crash of 2026-07-19.
///
/// UIKit resolves a dynamic `UIColor` on whatever thread asks for it, and on device SwiftUI updates its
/// view graph on an off-main render thread — so the adaptive tokens get resolved there. While the
/// providers inherited the module's `defaultIsolation(MainActor.self)`, that resolution hit the Swift 6
/// executor check and killed the app with SIGTRAP. The Simulator renders on the main thread, so it never
/// reproduced. These tests assert the whole theme path stays callable off the main thread; if a provider
/// or a palette helper regains MainActor isolation, they trap here instead of on a tester's phone.
@MainActor
struct AdaptiveColorIsolationTests {
    /// Every adaptive token, plus the `Color(light:dark:)` initializer, resolved off-main in both styles.
    @Test func adaptiveTokensResolveOffTheMainThread() async {
        let tokens: [(String, UIColor)] = [
            ("parchment", UIColor(.parchment)),
            ("cream", UIColor(.cream)),
            ("bark", UIColor(.bark)),
            ("slate", UIColor(.slate)),
            ("moss", UIColor(.moss)),
            ("fern", UIColor(.fern)),
            ("goldenrod", UIColor(.goldenrod)),
            ("sun", UIColor(.sun)),
            ("light/dark init", UIColor(Color(light: .white, dark: .black))),
        ]

        let resolved: [String] = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                #expect(Thread.isMainThread == false)
                var failures: [String] = []
                for (name, color) in tokens {
                    for style in [UIUserInterfaceStyle.light, .dark] {
                        let traits = UITraitCollection(userInterfaceStyle: style)
                        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
                        guard color.resolvedColor(with: traits)
                            .getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                            failures.append("\(name) (\(style.rawValue))")
                            continue
                        }
                    }
                }
                continuation.resume(returning: failures)
            }
        }

        #expect(resolved.isEmpty, "tokens failed to resolve off-main: \(resolved.joined(separator: ", "))")
    }

    /// The palette computation and the hex/luminance helpers it leans on must stay callable off the main
    /// thread. Deliberately reads `UserDefaults` rather than writing it — the theme key is global state and
    /// mutating it here would bleed into whatever else the suite runs in parallel.
    @Test func paletteAndColorHelpersResolveOffTheMainThread() async {
        struct Resolved {
            var lightHex: String?
            var darkHex: String?
            var customBoxHex: String?
            var luminance: CGFloat?
        }

        let resolved: Resolved = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var out = Resolved()
                out.lightHex = FernletThemePalette.current(for: .light).background.hexString
                out.darkHex = FernletThemePalette.current(for: .dark).background.hexString
                // The custom-background branch's helpers, exercised directly so no global theme key is touched.
                if let custom = UIColor(hex: "#3A5F2B") {
                    out.luminance = custom.relativeLuminance
                    out.customBoxHex = custom.hexString
                }
                continuation.resume(returning: out)
            }
        }

        // Only that the palette resolved off-main — not which color it picked, since a custom theme key
        // set elsewhere in the suite would legitimately change the value.
        #expect(resolved.lightHex != nil)
        #expect(resolved.darkHex != nil)
        #expect(resolved.customBoxHex?.caseInsensitiveCompare("#3A5F2B") == .orderedSame)
        #expect((resolved.luminance ?? -1) > 0 && (resolved.luminance ?? 1) < 0.46)
    }
}
