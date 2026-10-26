import SwiftUI
import FernletDomainModel
import FernletUI

/// The launch screen in the pixel world (design `b2-launch`, approved 2026-10-23): the dotted page,
/// the pixel companion once the store exists, the time-of-day greeting in Fraunces, the status line,
/// and a framed moss bar that keeps moving while Fernlet gets ready.
///
/// The bar says “still working”, not how far: a moss segment glides along the framed track (Reduce
/// Motion holds it still at the middle). `LaunchScreen` hands it its greeting and status line.
struct WorldLaunchScene: View {
    let greeting: String
    let status: String
    /// The companion to show, once the store has loaded; nil while it loads.
    var companion: (state: CompanionState, appearance: CompanionAppearance)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            FernletDottedPage()
                .environment(\.fernletFramedLook, WorldTheme.framedLook)
                .ignoresSafeArea()
            VStack(spacing: 18) {
                Spacer()
                if let companion {
                    OnboardingPixelCompanion(appearance: companion.appearance, state: companion.state, scale: 7)
                }
                VStack(spacing: 10) {
                    Text(verbatim: greeting)
                        .font(.fernlet(.display))
                        .foregroundStyle(WorldPalette.bark)
                        .multilineTextAlignment(.center)
                    Text(verbatim: status)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(WorldPalette.dim)
                        .multilineTextAlignment(.center)
                        .animation(.easeInOut(duration: 0.25), value: status)
                }
                .fernletWrappingText()
                WorldLaunchBar(isMoving: !reduceMotion)
                Spacer()
            }
            .padding(.horizontal, 28)
        }
    }
}

/// The launch screen's framed bar: a 160 × 14 pt paper track in a 2-pt ink frame with a moss segment
/// gliding back and forth. Decorative: the status line above says what is happening.
struct WorldLaunchBar: View {
    var isMoving = true

    var body: some View {
        TimelineView(.animation(paused: !isMoving)) { timeline in
            let phase = isMoving ? (sin(timeline.date.timeIntervalSinceReferenceDate * .pi / 1.1) + 1) / 2 : 0.5
            GeometryReader { proxy in
                let segment = proxy.size.width * 0.45
                RoundedRectangle(cornerRadius: 3)
                    .fill(WorldPalette.moss)
                    .frame(width: segment)
                    .offset(x: (proxy.size.width - segment) * phase)
            }
            .padding(3)
            .frame(width: 160, height: 14)
            .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .accessibilityHidden(true)
    }
}

/// When Fernlet can't open (design `b2-launch-fail`, approved 2026-10-23): the dotted page, the pixel
/// warning sign, “Fernlet couldn't open”, what went wrong, and a framed Try again.
struct WorldLaunchFailure: View {
    let message: String
    let retry: () -> Void

    var body: some View {
        ZStack {
            FernletDottedPage().ignoresSafeArea()
            VStack(spacing: 14) {
                WorldSpriteView(sprite: WorldLaunchArt.warning, scale: 4)
                Text("Fernlet couldn't open")
                    .font(.fernlet(.header))
                    .foregroundStyle(WorldPalette.bark)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: message)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(WorldPalette.dim)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
                Button("Try again", action: retry)
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .padding(.top, 6)
            }
            .padding(28)
            .frame(maxWidth: 420)
        }
        .environment(\.fernletFramedLook, WorldTheme.framedLook)
    }
}

/// The launch screens' own pixel art.
enum WorldLaunchArt {
    /// The warning sign on `b2-launch-fail`: a terracotta triangle with an ink outline and mark.
    static let warning = WorldSprite(rows: ["....k....", "...kkk...", "...kkk...", "..kokok..", "..kokok..",
                                            ".kookook.", ".koooook.", "koookoook", "kkkkkkkkk"],
                                     palette: ["k": 0x4A2E1C, "o": 0xE07A47])
}
