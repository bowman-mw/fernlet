// CompanionSceneViews.swift
// FernletWidgets
//
// The companion cards and "Your drive" on the person's background scene (owner's pick A, 2026-11-18):
// the scene fills the card (``WidgetCardGround``), Sprout stands on its ground, and the words sit on
// framed paper plates (``WidgetScenePlate``). Colour only; the plain background and one colour draw the
// paper cards in CompanionWidgetViews.swift and DriveWidget.swift.

import SwiftUI
import WidgetKit

/// Sprout on a scene card: the Home Screen face, without its own square of scene (the card is the
/// scene), its feet on the card's ground and centred at `x`.
struct WidgetSceneSprout: View {
    let entry: FernletCompanionEntry
    let scale: CGFloat
    /// The sprite's centre, from the card's leading edge.
    let x: CGFloat
    let size: CGSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        WidgetCompanionSprite(grid: entry.homeScreenGrid(increasedContrast: contrast == .increased), scale: scale,
                              showsZee: entry.hidesTheDay, motif: entry.homeScreenMotif)
            .position(x: x, y: WidgetSceneLayout.spriteCentreY(in: size, scale: scale))
    }
}

/// The small companion card on a scene: one plate top left with the name, the state word and Home's
/// hearts (no hearts while asleep), and Sprout standing on the ground below it, centred. A tap opens Home.
struct CompanionSmallSceneView: View {
    let entry: FernletCompanionEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let theme = WidgetTheme.current(scheme, contrast: contrast)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                WidgetSceneSprout(entry: entry, scale: 3, x: proxy.size.width / 2, size: proxy.size)
                plate(theme)
                    .widgetScenePlate(theme)
                    .padding(EdgeInsets(top: 11, leading: 11, bottom: 0, trailing: 11))
            }
        }
        .dynamicTypeSize(...WidgetPaperFrame.maxTypeSize)
        .overlay { ContainerRelativeShape().strokeBorder(theme.frame, lineWidth: 3) }
        .widgetURL(FernletWidgetLink.home)
    }

    private func plate(_ theme: WidgetTheme) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            VStack(alignment: .leading, spacing: 0) {
                if let name = entry.companionName {
                    Text(verbatim: name)
                        .font(WidgetFont.label(12))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
                Text(entry.titleWord)
                    .font(WidgetFont.display(19))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            // The face, the word and the name are one reading, as on the paper card.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.companionLabel)
            .accessibilityValue(companionMoodValue(entry.currentDayCompanionState, entry.currentCompanionEmotion))
            if let score = entry.careScore {
                WidgetHeartRow(score: score, goldHearts: entry.goldHearts, mono: false, scale: 2)
            }
        }
    }
}

/// The medium companion card on a scene: Sprout standing on the ground at the left; at the right its
/// line in the speech bubble (which carries its own paper) and a plate with Home's hearts and the
/// "Pip · Thriving" caption. A tap opens Home.
struct CompanionThoughtSceneView: View {
    let entry: FernletCompanionEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The column Sprout stands in, from the card's leading edge.
    private static let spriteColumn: CGFloat = 132

    var body: some View {
        let theme = WidgetTheme.current(scheme, contrast: contrast)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                WidgetSceneSprout(entry: entry, scale: 4, x: 15 + (Self.spriteColumn - 15) / 2, size: proxy.size)
                VStack(alignment: .leading, spacing: 8) {
                    WidgetSpeechBubble(text: entry.thought, mono: false)
                    Spacer(minLength: 0)
                    plate(theme)
                        .widgetScenePlate(theme)
                }
                .padding(EdgeInsets(top: 11, leading: Self.spriteColumn + 12, bottom: 13, trailing: 15))
            }
        }
        .dynamicTypeSize(...WidgetPaperFrame.maxTypeSize)
        .overlay { ContainerRelativeShape().strokeBorder(theme.frame, lineWidth: 3) }
        .widgetURL(FernletWidgetLink.home)
    }

    private func plate(_ theme: WidgetTheme) -> some View {
        HStack(spacing: 8) {
            if let score = entry.careScore {
                WidgetHeartRow(score: score, goldHearts: entry.goldHearts, mono: false, scale: 2)
            }
            Text(verbatim: entry.caption)
                .font(WidgetFont.label(12))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
    }
}

/// "Your drive" on a scene: the count's plate top left and Sprout on the ground at the right while there
/// is a drive to show; else Sprout centred on the ground under a plate with its name. A tap opens Home.
struct DriveSceneView: View {
    let entry: FernletDriveEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let theme = WidgetTheme.current(scheme, contrast: contrast)
        GeometryReader { proxy in
            ZStack(alignment: .topLeading) {
                switch entry.shown {
                case .thisDrive(let tiles), .lastDrive(let tiles):
                    sprout(scale: 3, x: proxy.size.width - 14 - WidgetCompanionSprite.size(scale: 3).width / 2, size: proxy.size)
                    count(tiles, theme: theme)
                        .widgetScenePlate(theme)
                        .padding(EdgeInsets(top: 10, leading: 10, bottom: 0, trailing: 10))
                case .sprout:
                    sprout(scale: 4, x: proxy.size.width / 2, size: proxy.size)
                    name(theme)
                        .widgetScenePlate(theme)
                        .frame(maxWidth: .infinity)
                        .padding(EdgeInsets(top: 10, leading: 12, bottom: 0, trailing: 12))
                }
            }
        }
        .overlay { ContainerRelativeShape().strokeBorder(theme.frame, lineWidth: 3) }
        .widgetURL(FernletWidgetLink.home)
    }

    /// Sprout as the person dressed it; its day shows in its face, so it redacts while locked.
    private func sprout(scale: CGFloat, x: CGFloat, size: CGSize) -> some View {
        WidgetSceneSprout(entry: entry.companion, scale: scale, x: x, size: size)
            .privacySensitive()
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.companion.companionLabel)
    }

    private func count(_ tiles: Int, theme: WidgetTheme) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(verbatim: DriveWords.plus(tiles))
                .font(WidgetFont.display(26))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.5)
            Text(verbatim: DriveWords.tilesWord(tiles))
                .font(WidgetFont.label(12.5))
                .foregroundStyle(theme.text)
            Text(verbatim: DriveWords.when(entry.shown))
                .font(WidgetFont.label(12))
                .foregroundStyle(theme.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: DriveWords.spoken(tiles, entry.shown)))
    }

    private func name(_ theme: WidgetTheme) -> some View {
        entry.companion.companionLabel
            .font(WidgetFont.display(16))
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .privacySensitive()
            .accessibilityHidden(true)
    }
}
