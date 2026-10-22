// CompanionWidgetViews.swift
// FernletWidgets
//
// The companion widget's families (design round 2, 2026-10-21): the small companion card (2b), the
// medium thought card (2c) and the Lock Screen face (2i). Water moved to its own widget
// (WaterWidget.swift); the rectangular Lock Screen card was retired (owner, 2026-10-21).

import SwiftUI
import WidgetKit

/// The small companion card: the person's companion, its state word and name, and the care bar.
///
/// While the companion is asleep it shows "Asleep" and drops the care bar — nothing of the day
/// (``WidgetCompanionEmotion/hidesTheDay``). A tap opens Home.
struct CompanionSmallView: View {
    let entry: FernletCompanionEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let theme = WidgetTheme.current(scheme)
        VStack(spacing: 0) {
            VStack(spacing: 2) {
                CompanionFigure(look: entry.look, state: entry.currentDayCompanionState,
                                emotion: entry.currentCompanionEmotion, monochrome: renderingMode != .fullColor)
                    .frame(width: 76, height: 76)
                Text(entry.titleWord)
                    .font(WidgetFont.display(19))
                    .foregroundStyle(theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if let name = entry.companionName {
                    Text(verbatim: name)
                        .font(WidgetFont.label(11))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                }
            }
            // The face, the word and the name are one reading.
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.companionLabel)
            .accessibilityValue(companionMoodValue(entry.currentDayCompanionState, entry.currentCompanionEmotion))
            Spacer(minLength: 4)
            if let score = entry.careScore {
                WidgetCareBar(score: score, fill: FernletWidgetPalette.mood(entry.currentDayCompanionState), line: theme.line)
            }
        }
        .widgetURL(FernletWidgetLink.home)
    }
}

/// The medium thought card: the companion and its care bar beside one of the widget's own lines.
///
/// The line comes from ``WidgetThoughtLines`` — a widget-only set chosen by state and time of day,
/// never the app's Home thought (which can quote today's journal tag). A tap opens Home.
struct CompanionThoughtView: View {
    let entry: FernletCompanionEntry
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode

    var body: some View {
        let theme = WidgetTheme.current(scheme)
        HStack(alignment: .center, spacing: 14) {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                CompanionFigure(look: entry.look, state: entry.currentDayCompanionState,
                                emotion: entry.currentCompanionEmotion, monochrome: renderingMode != .fullColor)
                    .frame(width: 88, height: 88)
                    .accessibilityHidden(true)      // the caption beside it says the same thing
                if let score = entry.careScore {
                    WidgetCareBar(score: score, fill: FernletWidgetPalette.mood(entry.currentDayCompanionState),
                                  line: theme.line, height: 7)
                }
            }
            .frame(width: 96)
            VStack(alignment: .leading, spacing: 8) {
                Text(entry.thought)
                    .font(WidgetFont.thought(17))
                    .foregroundStyle(theme.ink)
                    .lineLimit(3)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).strokeBorder(theme.chip, lineWidth: 1.5))
                Text(entry.caption)
                    .font(WidgetFont.label(11))
                    .foregroundStyle(theme.muted)
                    .lineLimit(1)
                    .padding(.leading, 8)
            }
        }
        .widgetURL(FernletWidgetLink.home)
    }
}

/// The Lock Screen circle: the companion's face alone, in one tint (2i).
///
/// The state face only — the owner's 2026-09-24 rule — except asleep, which says nothing about the
/// day (``FernletWidgetEmotionPolicy``). No word, bar or name.
struct CompanionLockView: View {
    let entry: FernletCompanionEntry

    var body: some View {
        let emotion = FernletWidgetEmotionPolicy.lockScreenEmotion(entry.currentCompanionEmotion)
        ZStack {
            AccessoryWidgetBackground()
            CompanionFigure(look: entry.look, state: entry.currentDayCompanionState, emotion: emotion, monochrome: true)
                .padding(5)
        }
        // One Canvas is an unlabelled blank to VoiceOver; the face is this family's only reading.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(entry.companionLabel)
        .accessibilityValue(companionMoodValue(entry.currentDayCompanionState, emotion))
        .widgetURL(FernletWidgetLink.home)
    }
}

/// "Before first launch": a soft dashed companion and an invitation to open the app.
///
/// Shown by every Home Screen family whenever the entry carries no snapshot — the gentle invitation
/// state rather than an error state.
struct PlaceholderView: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let theme = WidgetTheme.current(scheme)
        VStack(spacing: 12) {
            DashedCompanionOutline(color: theme.line)
                .frame(width: 56, height: 56)
                // There is no companion yet, so the dashed blob illustrates the invitation below
                // rather than reporting anything — an empty element in front of the real message.
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text("Open Fernlet")
                    .font(WidgetFont.label(15))
                    .foregroundStyle(theme.ink)
                Text("to meet your companion")
                    .font(WidgetFont.body(12))
                    .foregroundStyle(theme.muted)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The dashed placeholder blob (a simple always-happy face, drawn as strokes, not cut out).
///
/// Only used inside ``PlaceholderView``; it never varies by mood, so the cheaper stroke drawing is
/// fine here.
struct DashedCompanionOutline: View {
    /// The stroke colour — the theme's outline colour.
    let color: Color

    var body: some View {
        Canvas { context, size in
            let s = min(size.width, size.height) / 100.0
            context.scaleBy(x: s, y: s)
            let shading = GraphicsContext.Shading.color(color)
            let ring = Path(ellipseIn: CGRect(x: 10, y: 12, width: 80, height: 80))
            context.stroke(ring, with: shading, style: StrokeStyle(lineWidth: 3.5, lineCap: .round, dash: [5, 7]))
            context.fill(Path(ellipseIn: CGRect(x: 34, y: 44, width: 8, height: 8)), with: shading)
            context.fill(Path(ellipseIn: CGRect(x: 58, y: 44, width: 8, height: 8)), with: shading)
            var smile = Path()
            smile.move(to: CGPoint(x: 40, y: 62))
            smile.addQuadCurve(to: CGPoint(x: 60, y: 62), control: CGPoint(x: 50, y: 69))
            context.stroke(smile, with: shading, style: StrokeStyle(lineWidth: 4, lineCap: .round))
        }
    }
}
