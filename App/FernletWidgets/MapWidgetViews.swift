// MapWidgetViews.swift
// FernletWidgets
//
// The large map widget's views (`b4-new-map`): the map picture (or the plain ground before there is one),
// Sprout standing in its middle where you are, Home's status plate top left, and "Map from 9:40" bottom
// right. Light and dark, Increase Contrast, the one-colour Home Screens and the largest text sizes.

import SwiftUI
import UIKit
import WidgetKit

/// The map widget's root: the placeholder before Fernlet is first opened, else the card; paper behind.
///
/// `.privacySensitive()` as on every companion family: iOS shows no large widget on the Lock Screen or in
/// StandBy, so this is a backstop, as is the picture's complete file protection.
struct FernletMapWidgetView: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FernletMapEntry

    var body: some View {
        Group {
            if entry.companion.snapshot == nil {
                PlaceholderView(mono: renderingMode.drawsInOneColour)
            } else {
                MapWidgetCard(entry: entry, mono: renderingMode.drawsInOneColour).privacySensitive()
            }
        }
        .containerBackground(for: .widget) { WidgetTheme.current(scheme).paper }
    }
}

/// The card: the ground, Sprout on it, the plate and the tag, inside the paper's 3-point ink frame. A tap
/// opens Home.
struct MapWidgetCard: View {
    let entry: FernletMapEntry
    let mono: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// Points per sprite pixel for Sprout (the map's own size).
    static let spriteScale: CGFloat = 3

    var body: some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        ZStack(alignment: .topLeading) {
            MapWidgetGround(picture: entry.picture, dark: scheme == .dark, mono: mono)
            GeometryReader { proxy in
                companion
                    .position(x: proxy.size.width / 2, y: proxy.size.height / 2 - 10.5 * Self.spriteScale)
            }
            VStack(alignment: .leading, spacing: 0) {
                MapWidgetPlate(entry: entry, mono: mono, theme: theme)
                Spacer(minLength: 8)
                HStack {
                    Spacer(minLength: 0)
                    MapWidgetTag(text: tagText, theme: theme, mono: mono)
                }
            }
            .padding(12)
        }
        .dynamicTypeSize(...WidgetPaperFrame.maxTypeSize)
        .overlay { ContainerRelativeShape().strokeBorder(theme.frame, lineWidth: 3) }
        .widgetURL(FernletWidgetLink.home)
    }

    /// Sprout, its feet on the picture's middle (where you were when it was taken), with its name and mood
    /// for VoiceOver.
    private var companion: some View {
        WidgetCompanionSprite(grid: entry.companion.homeScreenGrid(increasedContrast: contrast == .increased),
                              scale: Self.spriteScale, ink: mono ? .silhouette(0xFFFFFF) : .color,
                              showsZee: entry.companion.hidesTheDay, motif: entry.companion.homeScreenMotif)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(entry.companion.companionLabel)
            .accessibilityValue(companionMoodValue(entry.companion.currentDayCompanionState, entry.companion.currentCompanionEmotion))
    }

    /// "Map from 9:40" (a picture from another day says its date), or "Open Fernlet" with no picture yet.
    private var tagText: String {
        guard case .picture(let picture) = entry.picture else { return String(localized: "Open Fernlet") }
        let sameDay = Calendar.current.isDate(picture.takenAt, inSameDayAs: entry.date)
        let when = sameDay ? picture.takenAt.formatted(date: .omitted, time: .shortened)
                           : picture.takenAt.formatted(.dateTime.month(.abbreviated).day())
        return String(localized: "widget.map.takenAt", defaultValue: "Map from \(when)",
                      comment: "The map widget's tag: when its picture of the map was taken, a time today or else a date. Example: 'Map from 9:40 AM'")
    }
}

/// The map's picture filling the widget, or before there is one (and while it is locked away, or in a
/// decoy) Home's plain ground with its faint survey grid. Decoration to VoiceOver.
struct MapWidgetGround: View {
    let picture: WidgetMapPictureRead
    let dark: Bool
    let mono: Bool

    var body: some View {
        Group {
            if case .picture(let map) = picture, let image = UIImage(data: dark ? map.dark : map.light) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .accessibilityIgnoresInvertColors()
                    .scaledToFill()
            } else {
                plainGround
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .accessibilityHidden(true)
    }

    /// Home's plain ground (`PlainBaseMap`'s colours), a faint grid every 24 points.
    private var plainGround: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .color(mono ? Color.white.opacity(0.06) : Color(widgetRGB: dark ? 0x2E2A24 : 0xEDE6D3)))
            var grid = Path()
            for index in 0...Int(max(size.width, size.height) / 24) {
                let at = CGFloat(index) * 24
                grid.move(to: CGPoint(x: at, y: 0))
                grid.addLine(to: CGPoint(x: at, y: size.height))
                grid.move(to: CGPoint(x: 0, y: at))
                grid.addLine(to: CGPoint(x: size.width, y: at))
            }
            context.stroke(grid, with: .color(Color(widgetRGB: 0x3A2414).opacity(mono ? 0.0 : 0.08)), lineWidth: 1)
        }
    }
}

/// Home's status plate on the map (`b1-home-day`'s, as `b4-new-map` draws it): the six hearts with a
/// friend's gold hearts, the protein, carbs and fat bars, and the day's water drops, on paper in a 3-point
/// ink frame. While Sprout sleeps the hearts and bars hide (nothing of the day); water stays, as on the
/// Lock Screen.
struct MapWidgetPlate: View {
    let entry: FernletMapEntry
    let mono: Bool
    let theme: WidgetTheme
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let score = entry.companion.careScore {
                WidgetHeartRow(score: score, goldHearts: entry.companion.goldHearts, mono: mono, scale: 3)
            }
            if !entry.companion.hidesTheDay {
                MapWidgetMacroBars(macros: entry.macros, mono: mono, theme: theme)
            }
            water
        }
        .padding(EdgeInsets(top: 8, leading: 10, bottom: 8, trailing: 10))
        .background(mono ? Color.white.opacity(0.12) : theme.paper, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(theme.frame, lineWidth: 3))
        .background {
            if !mono { RoundedRectangle(cornerRadius: 9).fill(WidgetFixedInk.shade).offset(y: 3) }
        }
    }

    /// Water: Home's drops, or one drop and "2 / 4" at the largest sizes; one element.
    private var water: some View {
        let bottles = entry.companion.bottleCount, target = entry.companion.hydrationTarget
        return WidgetDropRow(water: WidgetWater.make(bottles: bottles, target: target, accessibilitySize: typeSize.isAccessibilitySize),
                             mono: mono, ink: theme.text, scale: 3, perLine: WidgetWater.maxDrops)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text("Water"))
            .accessibilityValue(Text(WaterWords.progress(bottles, of: target)))
    }
}

/// The protein, carbs and fat bars (Home's plate's): a letter and a framed bar each, in the one set of
/// data colours. One VoiceOver element: "Protein 42 of 120 grams, carbs 118 of 250, fat 31 of 70."
struct MapWidgetMacroBars: View {
    let macros: WidgetMacros
    let mono: Bool
    let theme: WidgetTheme
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorScheme) private var scheme
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        HStack(spacing: typeSize.isAccessibilitySize ? 6 : 9) {
            bar(String(localized: "widget.macro.protein", defaultValue: "P", comment: "The letter before the protein bar on the map widget (Spanish: P)"),
                macros.protein, colour: 0x5E844D)
            bar(String(localized: "widget.macro.carbs", defaultValue: "C", comment: "The letter before the carbs bar on the map widget (Spanish: C)"),
                macros.carbs, colour: 0xD2973B)
            bar(String(localized: "widget.macro.fat", defaultValue: "F", comment: "The letter before the fat bar on the map widget (Spanish: G, grasa)"),
                macros.fat, colour: 0xB8543D)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(Self.spoken(macros)))
    }

    /// One letter and its framed bar.
    private func bar(_ letter: String, _ macro: WidgetMacros.Macro, colour: UInt32) -> some View {
        let width: CGFloat = typeSize.isAccessibilitySize ? 34 : 44
        return HStack(spacing: 4) {
            Text(verbatim: letter)
                .font(WidgetFont.bold(13))
                .foregroundStyle(theme.text)
            ZStack(alignment: .leading) {
                (mono ? Color.white.opacity(0.2) : Color(widgetRGB: scheme == .dark ? 0x2A2017 : 0xF3E2BD))
                // Shapes aren't redacted by iOS: under the privacy reason the bars read empty, as text hides.
                (mono ? Color.white : Color(widgetRGB: colour)).frame(width: redaction.contains(.privacy) ? 0 : width * macro.fraction)
            }
            .frame(width: width, height: 5)
            .padding(3)
            .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(theme.frame, lineWidth: 3))
        }
    }

    /// What VoiceOver says for the three bars (the app's own sentence).
    static func spoken(_ macros: WidgetMacros) -> String {
        String(localized: "widget.macros.spoken",
               defaultValue: "Protein \(macros.protein.grams) of \(macros.protein.target) grams, carbs \(macros.carbs.grams) of \(macros.carbs.target), fat \(macros.fat.grams) of \(macros.fat.target).",
               comment: "The map widget, VoiceOver: today's macros against their targets (the app's status plate says the same)")
    }
}

/// The small paper tag bottom right: "Map from 9:40", or "Open Fernlet" before there is a picture.
struct MapWidgetTag: View {
    let text: String
    let theme: WidgetTheme
    let mono: Bool

    var body: some View {
        Text(verbatim: text)
            .font(WidgetFont.label(14))
            .foregroundStyle(theme.text)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(mono ? Color.white.opacity(0.12) : theme.paper, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(theme.frame, lineWidth: 2.5))
    }
}
