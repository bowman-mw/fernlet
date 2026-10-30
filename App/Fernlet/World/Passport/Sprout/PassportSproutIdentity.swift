import FernletUI
import SwiftUI

// Page 1's top half (World-Passport-Spec §4, mockup `idBody`, `kit-passport.css` `.pphd`, `.ppid`, `.ppphoto`,
// `.ppf`, `.ppline`, `.ppmrz`): the header, the photo with its ghost, the details, Sprout's line and the two
// machine-readable lines.

/// The passport page's inks (`kit-passport.css` `--pp-*`), in light, dark and Increase Contrast. Every text
/// colour passes 4.5:1 on the paper (7:1 with Increase Contrast).
enum PassportSproutInk {
    /// The page's paper (`--pp-paper`), for the fade at the foot.
    static let paper = WorldPalette.adaptive(light: 0xFFF9EA, dark: 0x2A2721)
    /// Body text (`--pp-text`).
    static let text = WorldPalette.adaptive(light: 0x3A2414, dark: 0xFFF1CF, lightHC: 0x2A1808, darkHC: 0xFFF8E4)
    /// Labels and quiet words (`--pp-dim`).
    static let dim = WorldPalette.adaptive(light: 0x6B5C4A, dark: 0xCFC4B1, lightHC: 0x4E4030, darkHC: 0xE2D8C6)
    /// Headings in moss small caps (`--pp-moss`).
    static let moss = WorldPalette.adaptive(light: 0x46683A, dark: 0x9BCB84, lightHC: 0x34512A, darkHC: 0xB4DCA0)
    /// The header's rule (`--pp-rule`).
    static let rule = WorldPalette.adaptive(light: 0xD7CBB8, dark: 0x5C574C, lightHC: 0xAE9D8E, darkHC: 0x857D6C)
    /// A button's face (`--pp-tile`): the paper lifted a little.
    static let tile = WorldPalette.adaptive(light: 0xFFFCF4, dark: 0x312E27, lightHC: 0xFFFFFF, darkHC: 0x3A362E)
    /// The photo's mint ground (`--pp-photo`).
    static let photo = WorldPalette.adaptive(light: 0xE2EDD9, dark: 0x2F3B30)
    /// The Friend shops row's gold wash (`.ppgold`: `#E2B65E` at 28 % on the paper).
    static let gold = WorldPalette.adaptive(light: 0xF8E7C1, dark: 0x5A4A2C)
    /// The coins chip (`--k-chip`).
    static let chip = WorldPalette.adaptive(light: 0xF1E6CB, dark: 0x3E382E)
    /// Sprout's line stays light in dark mode (`.ppline`).
    static let bubble = WorldPalette.rgb(0xFFFBEF)
    static let bubbleText = WorldPalette.rgb(0x3A2414)
}

/// The page's fonts (`kit-passport.css`), each growing with Dynamic Type from its design size.
enum PassportSproutFont {
    /// Small caps headings and labels (DM Sans Bold 11 / 9.5).
    static func caps(_ size: CGFloat) -> Font { .custom(FernletFontName.dmSansBold, size: size, relativeTo: .caption2) }
    /// A value (DM Sans Bold 14 – 14.5).
    static func value(_ size: CGFloat = 14.5) -> Font { .custom(FernletFontName.dmSansBold, size: size, relativeTo: .subheadline) }
    /// The name, Fraunces 23.
    static let name = Font.custom(FernletFontName.frauncesSemiBold, size: 23, relativeTo: .title2)
    /// Sprout's line, DM Sans 13.5.
    static let line = Font.custom(FernletFontName.dmSansMedium, size: 13.5, relativeTo: .subheadline)
}

/// "PASSPORT" on the left in moss small caps, "Fernlet" on the right, over a rule. Decoration.
struct PassportSproutHeader: View {
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: PassportSproutCopy.passport)
                .textCase(.uppercase)
                .tracking(1.5)
                .foregroundStyle(PassportSproutInk.moss)
            Spacer(minLength: 8)
            Text(verbatim: "Fernlet")
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(PassportSproutInk.dim)
        }
        .font(PassportSproutFont.caps(11))
        .dynamicTypeSize(...DynamicTypeSize.xxxLarge)
        .lineLimit(1)
        .padding(.bottom, 6)
        .overlay(alignment: .bottom) { PassportSproutInk.rule.frame(height: 1.5) }
        .accessibilityHidden(true)
    }
}

/// The photo frame (100 × 122 pt, 2 pt ink, mint ground) with the companion at 4 pt a pixel standing on a soft
/// shadow, the ghost picture at map size in the top-right corner, and the pet's hearts over it. The pet itself
/// (and its reaction) belongs to the page: this draws what it is handed.
struct PassportSproutPhoto: View {
    let grid: WorldCompanionGrid
    /// The ghost's picture: the same companion at one point a pixel.
    let ghost: WorldCompanionGrid
    let reaction: WorldCloseUpReaction
    /// Changes with every pet, so the hearts start again.
    let petCount: Int

    /// The frame's size.
    static let size = CGSize(width: 100, height: 122)
    /// Points per sprite pixel in the photo.
    static let pixelScale: CGFloat = 4

    var body: some View {
        ZStack(alignment: .bottom) {
            PassportSproutInk.photo
            Ellipse()
                .fill(WorldPalette.ink.opacity(0.14))
                .frame(height: 10)
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
            WorldCompanionCanvas(grid: grid, scale: Self.pixelScale, footprint: .frame)
                .scaleEffect(x: reaction.squishes ? 1.08 : 1, y: reaction.squishes ? 0.9 : 1, anchor: .bottom)
                .padding(.bottom, 4)
                .overlay(alignment: .top) {
                    if reaction.hearts > 0 { WorldCloseUpHearts(count: reaction.hearts, compact: true).id(petCount) }
                }
        }
        .overlay(alignment: .topTrailing) {
            WorldCompanionCanvas(grid: ghost, scale: 1, footprint: .frame)
                .opacity(0.45)
                .padding(4)
                .accessibilityHidden(true)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WorldPalette.ink, lineWidth: 2))
    }
}

/// The details beside the photo: Name (Fraunces 23), Feeling, Shape and Care (the hearts at 2 pt a pixel). Each
/// is one VoiceOver element, "Name, Sprout".
struct PassportSproutDetails: View {
    let model: PassportSproutModel

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            field(PassportSproutCopy.nameLabel, spoken: model.name) {
                Text(verbatim: model.name).font(PassportSproutFont.name)
            }
            field(PassportSproutCopy.feelingLabel, spoken: model.feeling) {
                Text(verbatim: model.feeling).font(PassportSproutFont.value())
            }
            field(PassportSproutCopy.shapeLabel, spoken: model.shape) {
                Text(verbatim: model.shape).font(PassportSproutFont.value())
            }
            field(PassportSproutCopy.careLabel, spoken: PassportSproutCopy.spokenCare(
                percent: model.status.livePercent, goldHearts: model.status.goldHearts)) {
                WorldHeartRow(status: model.status, count: 6, scale: 2).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// One labelled field: the caps label over its value, read as one element ("Name, Sprout").
    private func field<Value: View>(_ label: String, spoken: String, @ViewBuilder value: () -> Value) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(verbatim: label)
                .font(PassportSproutFont.caps(9.5))
                .textCase(.uppercase)
                .tracking(0.9)
                .foregroundStyle(PassportSproutInk.dim)
            value()
                .foregroundStyle(PassportSproutInk.text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: label))
        .accessibilityValue(Text(verbatim: spoken))
    }
}

/// Sprout's line in the light bubble (it stays light in dark mode), its tail pointing up at the photo.
struct PassportSproutLine: View {
    let text: String

    var body: some View {
        Text(verbatim: text)
            .font(PassportSproutFont.line)
            .foregroundStyle(PassportSproutInk.bubbleText)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(PassportSproutInk.bubble, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(WorldPalette.ink, lineWidth: 2))
            .overlay(alignment: .topLeading) {
                PassportBubbleTail().fill(WorldPalette.ink).frame(width: 14, height: 9).offset(x: 44, y: -9)
            }
            .padding(.top, 9)
    }
}

/// The bubble's tail: an upward triangle.
struct PassportBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.midX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

/// The two machine-readable lines (``PassportMachineLines``) in a monospaced face. Decoration: hidden from
/// VoiceOver, kept at one size (shrinking a little on a narrow page) so the 44 characters always fit.
struct PassportSproutMachineLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .lineLimit(1)
            }
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .minimumScaleFactor(0.6)
        .foregroundStyle(PassportSproutInk.dim)
        .opacity(0.85)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityHidden(true)
    }
}
