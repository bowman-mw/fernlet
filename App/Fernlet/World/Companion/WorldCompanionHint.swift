import FernletUI
import SwiftUI

/// The one-time hint to tap the companion (refinement `ref-hint`, approved 2026-10-24; World build step
/// 5c): the first time Home appears, the companion's bubble says "Tap me to say hi!" and a dashed ring
/// pulses gently round it. It ends on the first tap (which opens Sprout's passport) or after 12
/// seconds on Home, and never shows again on this iPhone (``WorldMapPreferences/companionHintShown(in:)``,
/// cleared only by the wipes).
///
/// It waits its turn: never under the location question (the map intro or iOS's own prompt), never under
/// a stamp banner, never in a decoy (which keeps nothing, not even "shown"). With VoiceOver on it isn't
/// timed: it ends when the companion is first activated. Under Reduce Motion the ring stays still and
/// the bubble fades.
nonisolated enum WorldCompanionHint {
    /// How long the hint stays on Home.
    static let duration: Duration = .seconds(12)

    /// Whether the hint should show now.
    static func isDue(alreadyShown: Bool, introAnswered: Bool, permission: WorldLocationPermission, isAsking: Bool,
                      stampBannerShowing: Bool, isFrontmost: Bool, isDecoy: Bool) -> Bool {
        guard !alreadyShown, isFrontmost, !stampBannerShowing, !isDecoy, !isAsking else { return false }
        return introAnswered || permission != .notAsked
    }

    /// The bubble's line.
    static let line = LocalizedStringResource("worldHint.line", defaultValue: "Tap me to say hi!",
                                              comment: "World Home: the companion's one-time hint in its bubble (Spanish: ¡Tócame para saludar!)")

    /// What VoiceOver reads for the bubble: "Double-tap Sprout to say hi".
    static func spoken(name: String) -> String {
        String(localized: "worldHint.spoken", defaultValue: "Double-tap \(name) to say hi",
               comment: "World Home, VoiceOver: the one-time hint; the companion's name (Spanish: Toca dos veces a Sprout para saludar)")
    }

    /// The companion's VoiceOver hint, always (World-Passport-Spec §1): "Opens Sprout's passport."
    static func opensPassport(name: String) -> LocalizedStringResource {
        LocalizedStringResource("worldHint.opensPassport", defaultValue: "Opens \(name)'s passport.",
                                comment: "World Home, VoiceOver: what tapping or holding the companion does; the companion's name (Spanish: Abre el pasaporte de Sprout.)")
    }
}

/// The hint's dashed ring round the companion (the kit's `.hring`: 92 pt, a 3-pt dashed moss-ink ring
/// with a soft paper halo), pulsing every 1.8 s unless Reduce Motion is on. Decoration.
struct WorldHintRing: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var pulse = false

    var body: some View {
        let dark = colorScheme == .dark
        Circle()
            .strokeBorder(dark ? WorldPalette.rgb(0xCFE3B8) : WorldPalette.mossInk, style: StrokeStyle(lineWidth: 3, dash: [7, 5]))
            .background(Circle().stroke((dark ? WorldPalette.rgb(0x1C1E1B) : WorldPalette.rgb(0xFFF6E2)).opacity(0.55), lineWidth: 5))
            .frame(width: 92, height: 92)
            .scaleEffect(pulse ? 1.1 : 1)
            .opacity(pulse ? 0.65 : 1)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
            }
    }
}
