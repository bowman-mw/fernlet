// LiveActivityLook.swift
// FernletWidgets
//
// The World look of the workout and cooking Live Activities (World Review Batch 4, rows b4-la-* and
// b4-di-*, approved 2026-10-24). On the Lock Screen the card is paper in an ink frame, with a dark
// version for dark mode (today's card was always light). In the Dynamic Island iOS keeps its black;
// Fernlet's part is pixel icons in leaf green, Fraunces numbers and framed buttons, as on the watch.
// Both activities draw their colours, faces and buttons from here, so they stay one family.

import SwiftUI
import WidgetKit

/// The Lock Screen card's colours for one appearance: the design's `.lan` card.
///
/// Every text pairing clears WCAG AA on its paper. Light: ink 13.5:1, soft 6.0:1 (9.3:1 under
/// Increase Contrast), moss 5.9:1, the button's word 6.3:1 on its moss. Dark: ink 13.3:1, soft 9.4:1
/// (10.5:1), moss 8.0:1, the button's word 8.3:1. The progress squares carry no meaning of their own
/// (the "Exercise 3 of 6" beside them says it), so they keep the design's colours in both looks.
struct LiveActivityLook {
    /// The card behind everything.
    let paper: Color
    /// The 3-point frame around the card.
    let frame: Color
    /// Primary text: the exercise, the step, the countdown.
    let ink: Color
    /// Secondary text: the header, the set line, last time.
    let soft: Color
    /// "Rest" and "Step 3 of 8".
    let moss: Color
    /// One-colour pixel icons (the dumbbell, the runner, the pause bars).
    let icon: Color
    /// The primary framed button (Done set, Next, Skip rest, Finish) and its word.
    let buttonFill: Color
    let buttonInk: Color
    /// The secondary framed button (−15 s, +15 s) and its word.
    let secondaryFill: Color
    let secondaryInk: Color
    /// Every framed button's edge.
    let buttonEdge: Color

    /// Cream paper and bark ink.
    static let light = LiveActivityLook(
        paper: Color(laHex: 0xFFF6E2), frame: Color(laHex: 0x4A2E1C), ink: Color(laHex: 0x3A2414),
        soft: Color(laHex: 0x6B5C4A), moss: Color(laHex: 0x46683A), icon: Color(laHex: 0x4A2E1C),
        buttonFill: Color(laHex: 0x46683A), buttonInk: Color(laHex: 0xFFFDF5),
        secondaryFill: Color(laHex: 0xFFF8E4), secondaryInk: Color(laHex: 0x3A2414), buttonEdge: Color(laHex: 0x4A2E1C))

    /// Warm night browns and cream.
    static let dark = LiveActivityLook(
        paper: Color(laHex: 0x2E261D), frame: Color(laHex: 0x120A04), ink: Color(laHex: 0xFFF1CF),
        soft: Color(laHex: 0xD9CCB4), moss: Color(laHex: 0x9BCB84), icon: Color(laHex: 0xFFF1CF),
        buttonFill: Color(laHex: 0x8DBB78), buttonInk: Color(laHex: 0x10170D),
        secondaryFill: Color(laHex: 0x45372A), secondaryInk: Color(laHex: 0xF1EDE3), buttonEdge: Color(laHex: 0x120A04))

    /// The look for the Lock Screen's appearance. Increase Contrast deepens the soft text, as the
    /// app's own high-contrast palette does (`--k-dim2`).
    static func current(_ scheme: ColorScheme, contrast: ColorSchemeContrast) -> LiveActivityLook {
        let base = scheme == .dark ? dark : light
        guard contrast == .increased else { return base }
        return base.withSoft(Color(laHex: scheme == .dark ? 0xE2D8C6 : 0x4E4030))
    }

    /// This look with another soft colour.
    private func withSoft(_ soft: Color) -> LiveActivityLook {
        LiveActivityLook(paper: paper, frame: frame, ink: ink, soft: soft, moss: moss, icon: icon,
                         buttonFill: buttonFill, buttonInk: buttonInk, secondaryFill: secondaryFill,
                         secondaryInk: secondaryInk, buttonEdge: buttonEdge)
    }

    /// The pixel progress squares (`.pdot`): done or current, still to come, and their edge.
    static let squareOn = Color(laHex: 0x5E844D)
    static let squareOff = Color(laHex: 0xE2C893)
    static let squareEdge = Color(laHex: 0x4A2E1C)
}

/// The Dynamic Island's colours. iOS draws the island black in both appearances, so these are fixed.
///
/// On black: the soft text 9.0:1, leaf green 9.5:1; the primary button's word 8.3:1 on its leaf, the
/// secondary's 13.4:1 on its brown.
enum LiveActivityIslandLook {
    /// Pixel icons and "Rest" (`#8DBB78`, the watch's leaf).
    static let leaf = Color(laHex: 0x8DBB78)
    /// Secondary text: the header, "Set 2 of 3", last time.
    static let soft = Color(laHex: 0xA9A9AE)
    /// Primary text and the compact counts.
    static let text = Color.white
    /// The primary framed button (`.wb4.wgo`).
    static let buttonFill = Color(laHex: 0x8DBB78)
    static let buttonInk = Color(laHex: 0x10170D)
    static let buttonEdge = Color(laHex: 0x46683A)
    /// The secondary framed button (`.wb4`).
    static let secondaryFill = Color(laHex: 0x2A2620)
    static let secondaryInk = Color(laHex: 0xFFF1CF)
    static let secondaryEdge = Color(laHex: 0x4A2E1C)
}

/// The Live Activities' faces: Fraunces for titles and countdowns, DM Sans for everything else, at
/// the design's sizes. Each scales with Larger Text from the text style it stands in for. The files
/// are the extension's own copies (`UIAppFonts`); a missing face falls back to the system's.
enum LiveActivityFont {
    private static let fraunces = "Fraunces-72ptSemiBoldNonWonky"
    private static let dmSans = "DMSans-14pt"
    private static let dmSansBold = "DMSans-Bold"

    /// The exercise or "Rest" on the Lock Screen (`.laT`): Fraunces 19.
    static let title = Font.custom(fraunces, size: 19, relativeTo: .title3)
    /// The Lock Screen countdown (`.laBig`): Fraunces 36.
    static let countdown = Font.custom(fraunces, size: 36, relativeTo: .title)
    /// The expanded island's countdown (`.diBig`): Fraunces 38.
    static let islandCountdown = Font.custom(fraunces, size: 38, relativeTo: .title)
    /// The header: the workout or the recipe (`.lah`): DM Sans bold 12.5.
    static let header = Font.custom(dmSansBold, size: 12.5, relativeTo: .caption)
    /// "Step 3 of 8" (`.lmoss`): DM Sans bold 13.
    static let stepCount = Font.custom(dmSansBold, size: 13, relativeTo: .caption)
    /// The set line, "Next up", "Open Fernlet…" (`.lsoft`): DM Sans 13.5.
    static let line = Font.custom(dmSans, size: 13.5, relativeTo: .subheadline)
    /// Last time, the heart rate, the rest's weight (`.lsoft` 12.5): DM Sans 12.5.
    static let detail = Font.custom(dmSans, size: 12.5, relativeTo: .caption)
    /// The weight inside that line ("**25 lb** · 25–30 lb"): DM Sans Bold 12.5.
    static let detailBold = Font.custom(dmSansBold, size: 12.5, relativeTo: .caption)
    /// "Exercise 3 of 6" (`.lsoft` 11.5): DM Sans 11.5.
    static let progress = Font.custom(dmSansBold, size: 11.5, relativeTo: .caption2)
    /// A cooking step's words: DM Sans 14.5.
    static let step = Font.custom(dmSans, size: 14.5, relativeTo: .subheadline)
    /// The set's weight: DM Sans bold 15.
    static let weight = Font.custom(dmSansBold, size: 15, relativeTo: .subheadline)
    /// The range under the weight: DM Sans 12.
    static let range = Font.custom(dmSans, size: 12, relativeTo: .caption2)
    /// A framed button's word (`.pxbtn.sm` in the card): DM Sans bold 15.
    static let button = Font.custom(dmSansBold, size: 15, relativeTo: .subheadline)
}

extension Color {
    /// A literal `0xRRGGBB` design token, fully opaque.
    init(laHex value: UInt32) {
        self.init(red: Double((value >> 16) & 0xFF) / 255,
                  green: Double((value >> 8) & 0xFF) / 255,
                  blue: Double(value & 0xFF) / 255)
    }
}

/// The Lock Screen card's ground: paper inside the 3-point ink frame, following the Lock Screen's
/// appearance. iOS clips the card to its own rounded shape; the frame follows that shape
/// (`ContainerRelativeShape`), so it sits just inside the system's edge.
///
/// Sets the activity's background tint too, so the system's own banner and the always-on dimming
/// start from the same paper.
struct LiveActivityCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    /// The card's content; it reads the look from the environment.
    @ViewBuilder let content: () -> Content

    var body: some View {
        let look = LiveActivityLook.current(scheme, contrast: contrast)
        content()
            .environment(\.liveActivityLook, look)
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .padding(.bottom, 13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(look.paper)
            .overlay(ContainerRelativeShape().strokeBorder(look.frame, lineWidth: 3))
            .activityBackgroundTint(look.paper)
            .activitySystemActionForegroundColor(look.buttonFill)
    }
}

extension EnvironmentValues {
    /// The Lock Screen card's look, set by ``LiveActivityCard``; light outside one.
    @Entry var liveActivityLook: LiveActivityLook = .light
}
