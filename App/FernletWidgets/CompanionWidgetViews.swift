// CompanionWidgetViews.swift
// FernletWidgets
//
// The companion widget's families in the World design language (World Review Batch 4, approved
// 2026-10-24): the small card (`b4-w-companion-small`), the medium card with the pixel speech bubble
// (`b4-w-companion-medium`), the Lock Screen circle (`b4-w-lock`), the Lock Screen rectangle with the
// hearts and water (`b4-new-lock-rect`), and the card before Fernlet is first opened
// (`b4-w-placeholder`). Every family takes `mono` for the one-colour renderings (`b4-w-tinted`).

import SwiftUI
import WidgetKit

/// The small companion card: the pixel companion, its name top right, the state word, and Home's
/// hearts with any gold hearts after them.
///
/// While the companion is asleep it shows "Asleep" and the pixel "z", and drops the hearts — nothing
/// of the day (``WidgetCompanionEmotion/hidesTheDay``). A tap opens Home.
struct CompanionSmallView: View {
    let entry: FernletCompanionEntry
    /// One-colour rendering (tinted and clear Home Screens).
    let mono: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .top, spacing: 4) {
                    WidgetCompanionSprite(grid: entry.companionGrid, scale: 3, ink: mono ? .silhouette(0xFFFFFF) : .color,
                                          showsZee: entry.hidesTheDay)
                    Spacer(minLength: 0)
                    if let name = entry.companionName {
                        Text(verbatim: name)
                            .font(WidgetFont.label(12.5))
                            .foregroundStyle(theme.muted)
                            .lineLimit(1)
                    }
                }
                Text(entry.titleWord)
                    .font(WidgetFont.display(20))
                    .foregroundStyle(theme.text)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            // The face, the word and the name are one reading.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.companionLabel)
            .accessibilityValue(companionMoodValue(entry.currentDayCompanionState, entry.currentCompanionEmotion))
            Spacer(minLength: 4)
            if let score = entry.careScore {
                WidgetHeartRow(score: score, goldHearts: entry.goldHearts, mono: mono)
            }
        }
        .widgetPaperFrame(theme, padding: EdgeInsets(top: 14, leading: 15, bottom: 15, trailing: 15))
        .widgetURL(FernletWidgetLink.home)
    }
}

/// The medium card: the companion and its hearts beside one of the widget's own lines, in the pixel
/// speech bubble approved for Home, pointing at the companion.
///
/// The line comes from ``WidgetThoughtLines`` — a widget-only set chosen by state and time of day,
/// never the app's Home thought (which can quote today's journal tag). A tap opens Home.
struct CompanionThoughtView: View {
    let entry: FernletCompanionEntry
    let mono: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 8) {
                WidgetCompanionSprite(grid: entry.companionGrid, scale: 4, ink: mono ? .silhouette(0xFFFFFF) : .color,
                                      showsZee: entry.hidesTheDay)
                if let score = entry.careScore {
                    WidgetHeartRow(score: score, goldHearts: entry.goldHearts, mono: mono)
                }
            }
            .frame(width: entry.goldHearts > 0 ? 124 : 110)
            VStack(alignment: .leading, spacing: 8) {
                WidgetSpeechBubble(text: entry.thought, mono: mono)
                Text(verbatim: entry.caption)
                    .font(WidgetFont.label(12.5))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .padding(.leading, 4)
            }
        }
        .frame(maxHeight: .infinity)
        .widgetPaperFrame(theme, padding: EdgeInsets(top: 11, leading: 15, bottom: 11, trailing: 15))
        .widgetURL(FernletWidgetLink.home)
    }
}

/// The pixel speech bubble (`.tbub`): light paper in a 3-point ink frame with a small shade and a tail
/// pointing left at the companion. It stays light paper in dark mode, as on the Batch 4 page; in one
/// colour it becomes an outline.
struct WidgetSpeechBubble: View {
    /// The companion's line, already localized.
    let text: String
    let mono: Bool

    var body: some View {
        let frame = mono ? Color.white.opacity(0.5) : WidgetFixedInk.bubbleFrame
        Text(verbatim: text)
            .font(WidgetFont.label(15))
            .foregroundStyle(mono ? Color.white : WidgetFixedInk.bubbleText)
            .lineLimit(3)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(mono ? Color.white.opacity(0.14) : WidgetFixedInk.bubblePaper, in: RoundedRectangle(cornerRadius: 4))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(frame, lineWidth: 3))
            .overlay(alignment: .leading) {
                WidgetBubbleTail()
                    .fill(frame)
                    .frame(width: 10, height: 14)
                    .offset(x: -12)
                    .accessibilityHidden(true)
            }
            .background {
                if !mono {
                    RoundedRectangle(cornerRadius: 4).fill(WidgetFixedInk.shade).offset(y: 3)
                }
            }
    }
}

/// The speech bubble's tail: a small triangle pointing left.
struct WidgetBubbleTail: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

/// The Lock Screen circle: the pixel companion's silhouette with its face cut out, plus the pixel "z"
/// while asleep (`b4-w-lock`).
///
/// The state face only — the owner's 2026-09-24 rule — except asleep, which says nothing about the
/// day (``FernletWidgetEmotionPolicy``). No word, hearts or name.
struct CompanionLockView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        let emotion = FernletWidgetEmotionPolicy.lockScreenEmotion(entry.currentCompanionEmotion)
        ZStack {
            AccessoryWidgetBackground()
            WidgetCompanionSprite(grid: entry.companionGrid, scale: 2, ink: .silhouette(0xFFFFFF), showsZee: entry.hidesTheDay)
                .offset(y: 2)
        }
        // One Canvas is an unlabelled blank to VoiceOver; the face is this family's only reading.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.companionLabel)
        .accessibilityValue(companionMoodValue(entry.currentDayCompanionState, emotion))
        .widgetURL(FernletWidgetLink.home)
    }
}

/// The Lock Screen rectangle (`b4-new-lock-rect`): the companion's name and state, the six hearts with
/// any gold hearts (checked, in one colour), and today's water as drops and "2 / 4".
///
/// Before the phone is unlocked the name and hearts hide, as the companion circle does; the water
/// stays (owner, 2026-10-24). A tap opens Home; the water circle beside it still logs a bottle.
struct CompanionLockRectView: View {
    let entry: FernletCompanionEntry
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(verbatim: entry.caption)
                .font(.footnote.weight(.semibold))
                .lineLimit(1)
                .accessibilityLabel(entry.companionLabel)
                .accessibilityValue(companionMoodValue(entry.currentDayCompanionState,
                                                       FernletWidgetEmotionPolicy.lockScreenEmotion(entry.currentCompanionEmotion)))
                .privacySensitive()
            if let score = entry.careScore {
                WidgetHeartRow(score: score, goldHearts: entry.goldHearts, mono: true, scale: 2)
                    .privacySensitive()
            }
            WidgetLockWaterLine(bottles: entry.bottleCount, target: entry.hydrationTarget,
                                accessibilitySize: typeSize.isAccessibilitySize)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(AccessoryWidgetBackground())
        .widgetURL(FernletWidgetLink.home)
    }
}

/// The Lock Screen rectangle's water: drops, then "2 / 4" — one element, "Water, 2 of 4 bottles".
struct WidgetLockWaterLine: View {
    let bottles: Int
    let target: Int
    let accessibilitySize: Bool

    var body: some View {
        let water = WidgetWater.make(bottles: bottles, target: target, accessibilitySize: accessibilitySize)
        HStack(spacing: 5) {
            WidgetDropRow(water: water, mono: true, ink: .white, scale: 2, perLine: WidgetWater.maxDrops)
            if case .drops = water {
                Text(verbatim: WidgetWater.fraction(bottles, of: target))
                    .font(.footnote.weight(.bold))
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Water"))
        .accessibilityValue(Text(WaterWords.progress(bottles, of: target)))
    }
}

/// "Before first launch": a pale pixel ghost of the companion and an invitation to open the app
/// (`b4-w-placeholder`). Shown by the small and medium cards of every widget whenever the entry
/// carries no snapshot — the gentle invitation state rather than an error state.
struct PlaceholderView: View {
    let mono: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The ghost: the plain companion's okay face, as the Batch 4 page draws it.
    private static let ghost = WidgetCompanionPainter.paint(
        state: .okay, look: WidgetPixelLook(look: .standard, state: .okay, asleep: false), asleep: false)

    var body: some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        VStack(spacing: 6) {
            // There is no companion yet, so the ghost illustrates the invitation below rather than
            // reporting anything — hidden, in front of the real message.
            WidgetCompanionSprite(grid: Self.ghost, scale: 3, ink: .silhouette(mono ? 0xFFFFFF : WidgetFixedInk.ghost))
            Text("Open Fernlet")
                .font(WidgetFont.display(18))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text("to meet your companion")
                .font(WidgetFont.label(12.5))
                .foregroundStyle(theme.muted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetPaperFrame(theme)
    }
}
