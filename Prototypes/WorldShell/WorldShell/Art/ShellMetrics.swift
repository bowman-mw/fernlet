import SwiftUI

/// How big the shell draws, so it keeps the mockup's proportions on any iPhone.
///
/// The design page draws its phone 300 pt wide, so every mockup size here is multiplied by the
/// screen width over 300 (1.34 on iPhone 17, 1.25 on a 375 pt phone). Pixel art steps in whole
/// points per sprite pixel instead, so it stays crisp: 3 where the mockup used 2, and 2 only on a
/// screen too narrow for 3.
nonisolated struct ShellMetrics: Equatable, Sendable {
    /// Screen width ÷ the mockup's 300 pt.
    let ui: CGFloat
    /// Points per sprite pixel.
    let pixel: CGFloat

    /// The metrics for a screen `width` points wide.
    static func forWidth(_ width: CGFloat) -> ShellMetrics {
        let ui = max(1, width / 300)
        return ShellMetrics(ui: ui, pixel: ui >= 1.2 ? 3 : 2)
    }

    /// A mockup size, in points on this screen, rounded to a whole point.
    func pt(_ mockup: CGFloat) -> CGFloat { (mockup * ui).rounded() }

    /// The item bar's height (64 pt in the mockup).
    var barHeight: CGFloat { pt(64) }
}

extension EnvironmentValues {
    /// The shell's scale, set once at the root from the screen width.
    @Entry var shellMetrics = ShellMetrics.forWidth(402)
}
