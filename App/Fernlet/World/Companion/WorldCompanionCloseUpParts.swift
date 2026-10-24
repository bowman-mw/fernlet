import FernletScoring
import FernletUI
import SwiftUI

// The pieces of the companion's close-up (`ref-comp-close`, `kit-ref.css` `.cu*`): the veil over the
// map, the name and ✕, the bubble, the patch of grass, the pet's hearts, the hearts and Customize, and
// the presenter the map companion opens it with.

extension View {
    /// Presents the companion's close-up over the map while `isPresented` is true: full screen, the map
    /// still showing under its veil, no slide (it fades in itself). Customize, from the close-up, waits
    /// for the close-up to go and then calls `onCustomize`, so the map's customize sheet can present.
    func worldCompanionCloseUp(isPresented: Binding<Bool>, store: FernletStore, bodySignal: CompanionBodySignal?,
                               onCustomize: @escaping () -> Void) -> some View {
        modifier(WorldCompanionCloseUpPresenter(isPresented: isPresented, store: store, bodySignal: bodySignal,
                                                onCustomize: onCustomize))
    }
}

/// Implements `worldCompanionCloseUp(isPresented:store:bodySignal:onCustomize:)`.
struct WorldCompanionCloseUpPresenter: ViewModifier {
    @Binding var isPresented: Bool
    var store: FernletStore
    var bodySignal: CompanionBodySignal?
    let onCustomize: () -> Void
    @State private var customizesAfterClose = false

    /// A transaction that presents or dismisses the close-up without the cover's slide.
    static var instant: Transaction {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        return transaction
    }

    func body(content: Content) -> some View {
        content.fullScreenCover(isPresented: $isPresented, onDismiss: customizeIfAsked) {
            WorldCompanionCloseUp(store: store, bodySignal: bodySignal, onClose: close) {
                customizesAfterClose = true
                close()
            }
            .presentationBackground(.clear)
        }
    }

    private func close() {
        withTransaction(Self.instant) { isPresented = false }
    }

    private func customizeIfAsked() {
        guard customizesAfterClose else { return }
        customizesAfterClose = false
        onCustomize()
    }
}

/// The softened map: the page's parchment over it, 80 % in light mode and 84 % in dark around the
/// companion, so it and its paper bubble stand out in both. Behind the name and behind the footer it
/// thickens to 96 %, so Home's plate, prints, blue button and item bar don't show through the words
/// (the approved page drew the map alone under the veil).
struct WorldCloseUpVeil: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let base = colorScheme == .dark ? 0.84 : 0.8
        let page = WorldPalette.page
        LinearGradient(stops: [.init(color: page.opacity(Self.edge), location: 0),
                               .init(color: page.opacity(Self.edge), location: 0.3),
                               .init(color: page.opacity(base), location: 0.42),
                               .init(color: page.opacity(base), location: 0.68),
                               .init(color: page.opacity(Self.edge), location: 0.78),
                               .init(color: page.opacity(Self.edge), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .accessibilityHidden(true)
    }

    /// The veil behind the name and the footer.
    static let edge = 0.96
}

/// The name in Fraunces, the state and feeling under it, and the ✕ top right.
struct WorldCloseUpHeader: View {
    let name: String
    let status: String
    let onClose: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: name)
                    .font(.custom(FernletFontName.frauncesSemiBold, size: 30, relativeTo: .title))
                    .foregroundStyle(WorldPalette.bark)
                Text(verbatim: status)
                    .font(.custom(FernletFontName.dmSansBold, size: 15, relativeTo: .subheadline))
                    .foregroundStyle(WorldPalette.dim)
            }
            .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            FernletCloseButton(action: onClose)
                .accessibilityIdentifier("world.closeUp.close")
        }
    }
}

/// The line in the map's speech bubble, larger up close (17 pt, at most 300 pt wide), centred.
struct WorldCloseUpBubble: View {
    let text: String
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        WorldSpeechBubble(text: text, font: .custom(FernletFontName.dmSans, size: 17, relativeTo: .body),
                          maxWidth: dynamicTypeSize.isAccessibilitySize ? 340 : 300, alignment: .center,
                          typeCap: .xxxLarge)
            // Paper in dark mode too (`ref-comp-dark`): the light bubble stands out on the dark veil.
            .environment(\.colorScheme, .light)
            .padding(.bottom, 14)
            .accessibilityHidden(true)
    }
}

/// The patch of grass it stands on: the map's park green in an ink frame.
struct WorldCloseUpGround: View {
    /// The map's park (`--m-park`).
    static let park = WorldPalette.adaptive(light: 0xD7E3C6, dark: 0x26332A)

    var body: some View {
        Ellipse()
            .fill(Self.park)
            .overlay(Ellipse().strokeBorder(WorldPalette.ink, lineWidth: 3))
            .frame(width: 270, height: 50)
            .accessibilityHidden(true)
    }
}

/// The pet's three pixel hearts: they rise and fade, or, with Reduce Motion, fade where they appear.
struct WorldCloseUpHearts: View {
    let count: Int
    @State private var isGone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where each heart starts over the companion's head (x, y), and its pixel scale.
    private static let placements: [(x: CGFloat, y: CGFloat, scale: CGFloat)] = [(-36, 6, 3), (34, -6, 3), (0, -18, 4)]

    var body: some View {
        ZStack {
            ForEach(0..<min(count, Self.placements.count), id: \.self) { index in
                let place = Self.placements[index]
                WorldSpriteView(sprite: WorldSprites.heartSm, scale: place.scale)
                    .offset(x: place.x, y: place.y - (isGone ? WorldCloseUpMotion.heartsRise(reduceMotion: reduceMotion) : 0))
            }
        }
        .opacity(isGone ? 0 : 1)
        .offset(y: -30)
        .onAppear {
            withAnimation(.easeOut(duration: WorldCloseUpMotion.heartsDuration)) { isGone = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The hearts with any gold ones (four bigger hearts at the largest sizes, as on Home), how to pet it,
/// and Customize.
struct WorldCloseUpFooter: View {
    let status: WorldStatus
    let onCustomize: () -> Void
    @Environment(\.worldTheme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let isLarge = dynamicTypeSize.isAccessibilitySize
        VStack(spacing: 12) {
            WorldHeartRow(status: status, count: isLarge ? 4 : 6, scale: theme.scale(accessibilitySize: isLarge))
            Text(verbatim: WorldCloseUpCopy.hint)
                .font(.custom(FernletFontName.dmSansBold, size: 14, relativeTo: .footnote))
                .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
                .foregroundStyle(WorldPalette.dim)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            Button(action: onCustomize) {
                HStack(spacing: 8) {
                    WorldSpriteView(sprite: WorldSprites.pen, scale: 2)
                    Text("Customize")
                }
                .frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(.secondary))
            .accessibilityHint("Change how your companion looks")
            .accessibilityIdentifier("world.closeUp.customize")
        }
    }
}
