import FernletUI
import SwiftUI

/// The quick start's teal, the one colour the blue button and its leading choice wear (the design
/// kit's `--g-teal` family). Dark mode deepens it, so the cream text on the leading choice clears AA
/// (4.5:1 for its 13.5-pt line) where the kit's dark teal would not.
nonisolated enum WorldQuickStartPalette {
    /// The button's face and the leading choice's fill.
    static let teal = WorldPalette.adaptive(light: 0x5FB8C9, dark: 0x2C6B78)
    /// The button's frame.
    static let tealEdge = WorldPalette.adaptive(light: 0x24505E, dark: 0x0E2B33)
    /// The inset shade along the bottom.
    static let tealLow = WorldPalette.adaptive(light: 0x3F95A8, dark: 0x1F525D)
    /// The inset light along the button's top.
    static let tealHigh = WorldPalette.adaptive(light: 0x9ADDEA, dark: 0x4C93A2)
    /// Text on the leading choice: deep teal on light (6.1:1), cream on dark.
    static let onTeal = WorldPalette.adaptive(light: 0x10303A, dark: 0xF2FBFD)
    /// The icon tile on the leading choice.
    static let tileOnTeal = Color(.sRGB, red: 36 / 255, green: 80 / 255, blue: 94 / 255, opacity: 0.55)
}

/// The quick start's type: DM Sans throughout, as the approved card draws it (heading 19 pt bold,
/// choice names 16 pt bold, lines 13.5 to 14 pt), each scaling with Dynamic Type.
nonisolated enum WorldQuickStartType {
    static let heading = Font.custom(FernletFontName.dmSansBold, size: 19, relativeTo: .title3)
    static let note = Font.custom(FernletFontName.dmSans, size: 14, relativeTo: .subheadline)
    static let optionTitle = FernletFramedFont.button
    static let optionDetail = FernletFramedFont.note
}

/// The blue quick-start button, bottom right over the map (design `b1-home-day`: 60 × 60 pt, teal in
/// its own dark frame, a white pixel icon). It quick-starts what the person usually does where they
/// stand (``WorldQuickStart``); it never badges, buzzes or notifies. When its action changes to the
/// camera, a workout or a run, the word slides out beside it for 30 seconds, every time
/// (``WorldQuickStartLabel``), and VoiceOver hears "Quick start, Camera" as its name.
struct WorldQuickStartButton: View {
    let glyph: WorldQuickStartGlyph
    /// What VoiceOver hears after the name when the button has news ("Sam is nearby. Start a session
    /// or an activity."), nil otherwise.
    var spokenStatus: String? = nil
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            WorldSpriteView(sprite: Self.sprite(for: glyph), scale: dynamicTypeSize.isAccessibilitySize ? 5 : 4)
                .frame(width: 60, height: 60)
                .background(WorldQuickStartPalette.teal, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .bottom) { WorldQuickStartPalette.tealLow.frame(height: 4).padding(.horizontal, 3).padding(.bottom, 3) }
                .overlay(alignment: .top) { WorldQuickStartPalette.tealHigh.frame(height: 3).padding(.horizontal, 3).padding(.top, 3) }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorldQuickStartPalette.tealEdge, lineWidth: 3))
                .background {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(.sRGB, red: 20 / 255, green: 40 / 255, blue: 50 / 255, opacity: 0.4)).offset(y: 3)
                }
        }
        .buttonStyle(.plain)
        // Refinement 6 (`ref-blue-how`): the action's word slides out when it changes; the name always says it.
        .worldQuickStartLabel(for: glyph)
        .accessibilityLabel(Text(verbatim: WorldQuickStartLabel.buttonName(for: glyph)))
        .accessibilityValue(Text(verbatim: spokenStatus ?? ""))
        .accessibilityHint(Text(WorldQuickStartCopy.buttonHint))
        .accessibilityInputLabels([Text(WorldQuickStartCopy.buttonLabel)])
        .accessibilityIdentifier("world.quickStart")
    }

    /// The pixel icon for each glyph.
    static func sprite(for glyph: WorldQuickStartGlyph) -> WorldSprite {
        switch glyph {
        case .walk: WorldSprites.pair
        case .space: WorldSprites.dumbbell
        case .rest: WorldSprites.rest
        case .camera: WorldSprites.disposableCamera
        case .trail: WorldSprites.tree
        case .run: WorldSprites.runner
        case .friends: WorldSprites.pair
        case .eat: WorldSprites.bowl
        }
    }
}

/// The card the blue button opens (the design's `.qs` card, `b1-qs-*`): paper in a 3-pt ink frame over
/// the map's bottom right, the heading with a ✕, the line, and the choices, the first leading in teal.
struct WorldQuickStartCardView: View {
    let card: WorldQuickStartCard
    let onChoose: (WorldQuickStartOption) -> Void
    let onClose: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // Over the map the card grows with text size up to the first accessibility size (the approved
        // largest-text card), and scrolls when its choices outgrow the space above the blue button.
        ViewThatFits(in: .vertical) {
            content
            ScrollView { content }
                .scrollBounceBehavior(.basedOnSize)
        }
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
        .frame(maxWidth: dynamicTypeSize.isAccessibilitySize ? 370 : 316, alignment: .leading)
        .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 13))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(WorldPalette.ink, lineWidth: 3))
        .background {
            RoundedRectangle(cornerRadius: 13).fill(Color(.sRGB, red: 40 / 255, green: 20 / 255, blue: 8 / 255, opacity: 0.35)).offset(y: 4)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("world.quickStart.card")
    }

    /// The heading with its ✕, the line, and the choices.
    private var content: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 8) {
                Text(verbatim: WorldQuickStartCopy.heading(card.heading))
                    .font(WorldQuickStartType.heading)
                    .foregroundStyle(WorldPalette.bark)
                    .fernletWrappingText()
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 4)
                FernletCloseButton(action: onClose)
            }
            if let note = card.note {
                Text(verbatim: WorldQuickStartCopy.note(note))
                    .font(WorldQuickStartType.note.weight(note == .restingCounts ? .semibold : .regular))
                    .foregroundStyle(note == .restingCounts ? WorldPalette.bark : WorldPalette.dim)
                    .fernletWrappingText()
            }
            ForEach(Array(card.options.enumerated()), id: \.element) { index, option in
                WorldQuickStartOptionRow(option: option, leads: index == 0) { onChoose(option) }
            }
        }
        .padding(12)
    }
}

/// One choice: its pixel icon in a teal tile, its name and its line. The leading choice is teal.
struct WorldQuickStartOptionRow: View {
    let option: WorldQuickStartOption
    let leads: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                WorldSpriteView(sprite: Self.sprite(for: option), scale: 3)
                    .frame(width: 44, height: 44)
                    .background(leads ? WorldQuickStartPalette.tileOnTeal : WorldQuickStartPalette.teal,
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: WorldQuickStartCopy.title(option))
                        .font(WorldQuickStartType.optionTitle)
                    Text(verbatim: WorldQuickStartCopy.detail(option))
                        .font(WorldQuickStartType.optionDetail)
                }
                .foregroundStyle(leads ? WorldQuickStartPalette.onTeal : WorldPalette.bark)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 9, leading: 11, bottom: 9, trailing: 11))
            .frame(minHeight: 54)
            .background(leads ? WorldQuickStartPalette.teal : WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 11))
            .overlay(alignment: .bottom) {
                if leads { WorldQuickStartPalette.tealLow.frame(height: 4).padding(.horizontal, 3).padding(.bottom, 3) }
            }
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(WorldPalette.ink, lineWidth: 3))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityInputLabels([Text(verbatim: WorldQuickStartCopy.title(option))])
        .accessibilityIdentifier("world.quickStart.\(Self.identifier(for: option))")
    }

    /// The pixel icon for a choice.
    static func sprite(for option: WorldQuickStartOption) -> WorldSprite {
        switch option {
        case .todaysPlan, .suggestWorkout, .backToWorkout: WorldSprites.dumbbell
        case .gentleStretch: WorldSprites.rest
        case .walkTogether: WorldSprites.pair
        case .walkSavedLine: WorldSprites.tree
        case .runSavedLine: WorldSprites.runner
        case .sessionCamera, .soloCamera: WorldSprites.disposableCamera
        case .startSession: WorldSprites.pair
        case .startActivity: FriendsSprites.flag
        case .friendsNearby: WorldSprites.face
        case .logUsual, .findMenu: WorldSprites.bowl
        }
    }

    /// A stable accessibility identifier per kind of choice (a frozen token).
    static func identifier(for option: WorldQuickStartOption) -> String {
        switch option {
        case .todaysPlan: "todaysPlan"
        case .suggestWorkout: "suggest"
        case .gentleStretch: "gentleStretch"
        case .walkTogether: "walk"
        case .walkSavedLine: "savedLine"
        case .runSavedLine: "savedRun"
        case .sessionCamera: "sessionCamera"
        case .soloCamera: "soloCamera"
        case .backToWorkout: "backToWorkout"
        case .startSession: "startSession"
        case .startActivity: "startActivity"
        case .friendsNearby: "friendsNearby"
        case .logUsual: "logUsual"
        case .findMenu: "findMenu"
        }
    }
}
