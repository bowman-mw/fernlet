// StampWidget.swift
// FernletWidgets
//
// The stamp widget (World Review Batch 4, `b4-new-stamp`, the owner's pick of 2026-10-24): small — a
// stamp earned today with a "New today" ribbon, otherwise one stamp from the book, a different one each
// day, or "Your first stamp is waiting"; medium — the stamp, when it was earned, the last four stamps
// and how many of the nineteen. It reads the stamp book the app mirrors into the widget snapshot
// (tokens and days only; the book itself stays on this device). A tap opens the Stamp book.

import SwiftUI
import WidgetKit

/// The stamp widget: small and medium, on the companion widget's timeline (its midnight entry turns
/// the day's stamp over).
struct FernletStampWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: FernletWidgetKind.stamp, provider: FernletCompanionProvider()) { entry in
            StampWidgetView(entry: entry)
        }
        .configurationDisplayName("Stamps")
        .description("A stamp from your stamp book, and the one you earned today.")
        .supportedFamilies([.systemSmall, .systemMedium])
        .contentMarginsDisabled()
    }
}

/// Which stamps the widget shows, from the snapshot's book. Pure: dates in, stamps out.
enum WidgetStampShelf {
    /// One stamp the widget can draw.
    struct Stamp: Equatable {
        let kind: WidgetStampKind
        /// The day it was earned (`yyyy-MM-dd`).
        let dayKey: String
        let earnedAt: Date
    }

    /// The stamp to feature, and whether it was earned today.
    struct Featured: Equatable {
        let stamp: Stamp
        let isNewToday: Bool
    }

    /// The stamps this build knows, oldest first — one per kind, unknown tokens skipped.
    static func stamps(_ moments: [WidgetSnapshot.StampMoment]?) -> [Stamp] {
        var seen = Set<WidgetStampKind>()
        var out: [Stamp] = []
        for moment in moments ?? [] {
            guard let kind = WidgetStampKind(rawValue: moment.kindRaw), seen.insert(kind).inserted else { continue }
            out.append(Stamp(kind: kind, dayKey: moment.dayKey, earnedAt: moment.earnedAt))
        }
        return out.sorted { ($0.dayKey, $0.earnedAt) < ($1.dayKey, $1.earnedAt) }
    }

    /// The stamp for `date`: the newest one earned that day, with the ribbon; otherwise one from the
    /// book, a different one each day; nil before the first stamp.
    static func featured(_ stamps: [Stamp], at date: Date, calendar: Calendar = .current) -> Featured? {
        guard !stamps.isEmpty else { return nil }
        let today = WidgetDayKey.current(date)
        if let newest = stamps.last(where: { $0.dayKey == today }) {
            return Featured(stamp: newest, isNewToday: true)
        }
        let day = calendar.ordinality(of: .day, in: .era, for: date) ?? 0
        return Featured(stamp: stamps[abs(day) % stamps.count], isNewToday: false)
    }

    /// The newest `count` stamps, newest first.
    static func latest(_ stamps: [Stamp], count: Int = 4) -> [Stamp] {
        Array(stamps.suffix(max(count, 0)).reversed())
    }
}

extension FernletCompanionEntry {
    /// The stamp book this entry can draw, oldest first.
    var stamps: [WidgetStampShelf.Stamp] {
        WidgetStampShelf.stamps(snapshot?.stamps)
    }
}

/// The stamp widget's words.
enum StampWords {
    /// "Earned 9:12" (today) or "Earned Sunday, 19 October" / "Earned 19 Oct" (`short`).
    static func earned(_ featured: WidgetStampShelf.Featured, short: Bool) -> String {
        guard !featured.isNewToday else {
            let time = featured.stamp.earnedAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "widget.stamp.earnedAt", defaultValue: "Earned \(time)",
                          comment: "Under a stamp earned today on the stamp widget: the time it was earned. Example: 'Earned 9:12'")
        }
        let date = day(featured.stamp, short: short)
        return String(localized: "widget.stamp.earnedOn", defaultValue: "Earned \(date)",
                      comment: "Under a stamp on the stamp widget: the day it was earned. Example: 'Earned Sunday, 19 October'")
    }

    /// What VoiceOver says after the stamp's name: "earned today at 9:12", "earned Sunday, 19 October".
    static func spoken(_ featured: WidgetStampShelf.Featured) -> String {
        guard !featured.isNewToday else {
            let time = featured.stamp.earnedAt.formatted(date: .omitted, time: .shortened)
            return String(localized: "widget.stamp.spokenToday", defaultValue: "earned today at \(time)",
                          comment: "VoiceOver, after a stamp's name on the stamp widget: earned today, and when. Example: 'earned today at 9:12'")
        }
        let date = day(featured.stamp, short: false)
        return String(localized: "widget.stamp.spokenOn", defaultValue: "earned \(date)",
                      comment: "VoiceOver, after a stamp's name on the stamp widget: the day it was earned. Example: 'earned Sunday, 19 October'")
    }

    /// "5 of 19".
    static func count(_ held: Int, of total: Int) -> String {
        String(localized: "widget.stamp.count", defaultValue: "\(held) of \(total)",
               comment: "On the medium stamp widget: how many of the silly stamps you have. Example: '5 of 19'")
    }

    /// "5 of 19 stamps", for VoiceOver.
    static func spokenCount(_ held: Int, of total: Int) -> String {
        String(localized: "widget.stamp.countSpoken", defaultValue: "\(held) of \(total) stamps",
               comment: "VoiceOver on the medium stamp widget: how many of the silly stamps you have. Example: '5 of 19 stamps'")
    }

    /// The day a stamp was earned, in the reader's calendar.
    private static func day(_ stamp: WidgetStampShelf.Stamp, short: Bool) -> String {
        let date = WidgetStampShelf.date(fromDayKey: stamp.dayKey) ?? stamp.earnedAt
        let style: Date.FormatStyle = short ? .dateTime.day().month(.abbreviated) : .dateTime.weekday(.wide).day().month(.wide)
        return date.formatted(style)
    }
}

extension WidgetStampShelf {
    /// Noon on a `yyyy-MM-dd` day, local time (noon so no time-zone shift moves it a day).
    static func date(fromDayKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2], hour: 12))
    }
}

/// Picks the stamp widget's family layout; the "Open Fernlet" card before the first launch.
struct StampWidgetView: View {
    @Environment(\.widgetFamily) private var family
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetRenderingMode) private var renderingMode
    let entry: FernletCompanionEntry

    var body: some View {
        let mono = renderingMode.drawsInOneColour
        Group {
            if entry.snapshot == nil {
                PlaceholderView(mono: mono)
            } else if family == .systemMedium {
                StampMediumView(stamps: entry.stamps, date: entry.date, mono: mono)
            } else {
                StampSmallView(stamps: entry.stamps, date: entry.date, mono: mono)
            }
        }
        // A stamp can be a Health-derived fact (a koala day of sleep), so it redacts while locked.
        .privacySensitive()
        .containerBackground(for: .widget) { WidgetTheme.current(scheme).paper }
        .widgetURL(FernletWidgetLink.stamps)
    }
}

/// The small stamp card: the featured stamp on its gold disc with its name and when it was earned
/// (a "New today" ribbon above a stamp earned today), or the dashed empty disc before the first.
struct StampSmallView: View {
    let stamps: [WidgetStampShelf.Stamp]
    let date: Date
    let mono: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        // The disc gives way to the larger text at accessibility sizes.
        let disc: CGFloat = typeSize.isAccessibilitySize ? 48 : (WidgetStampShelf.featured(stamps, at: date)?.isNewToday == true ? 70 : 78)
        Group {
            if let featured = WidgetStampShelf.featured(stamps, at: date) {
                VStack(spacing: 3) {
                    if featured.isNewToday { StampRibbon(mono: mono) }
                    WidgetStampDisc(kind: featured.stamp.kind, size: disc, scale: disc < 60 ? 3 : 5, mono: mono, theme: theme)
                    Text(verbatim: featured.stamp.kind.displayName)
                        .font(WidgetFont.display(17))
                        .foregroundStyle(theme.text)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(verbatim: StampWords.earned(featured, short: true))
                        .font(WidgetFont.label(12.5))
                        .foregroundStyle(theme.muted)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: featured.stamp.kind.displayName))
                .accessibilityValue(Text(verbatim: StampWords.spoken(featured)))
            } else {
                StampFirstWaiting(theme: theme, mono: mono)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .widgetPaperFrame(theme, padding: EdgeInsets(top: 9, leading: 12, bottom: 11, trailing: 12))
    }
}

/// The medium stamp card: the featured stamp large, "From your stamp book" (or "New today"), its name
/// and day, then the last four stamps and "5 of 19".
struct StampMediumView: View {
    let stamps: [WidgetStampShelf.Stamp]
    let date: Date
    let mono: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let theme = mono ? WidgetTheme.mono : WidgetTheme.current(scheme, contrast: contrast)
        Group {
            if let featured = WidgetStampShelf.featured(stamps, at: date) {
                HStack(spacing: 14) {
                    WidgetStampDisc(kind: featured.stamp.kind, size: 110, scale: 6, mono: mono, theme: theme)
                    VStack(alignment: .leading, spacing: 5) {
                        StampFeatureText(featured: featured, theme: theme)
                        StampLatestRow(stamps: stamps, theme: theme, mono: mono)
                    }
                    Spacer(minLength: 0)
                }
                .frame(maxHeight: .infinity)
            } else {
                StampFirstWaiting(theme: theme, mono: mono)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .widgetPaperFrame(theme)
    }
}

/// The medium card's words about the featured stamp: one VoiceOver element.
struct StampFeatureText: View {
    let featured: WidgetStampShelf.Featured
    let theme: WidgetTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Group {
                if featured.isNewToday { Text("New today") } else { Text("From your stamp book") }
            }
            .font(WidgetFont.label(12.5))
            .foregroundStyle(theme.muted)
            .lineLimit(1)
            Text(verbatim: featured.stamp.kind.displayName)
                .font(WidgetFont.display(20))
                .foregroundStyle(theme.text)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
            Text(verbatim: StampWords.earned(featured, short: false))
                .font(WidgetFont.label(12.5))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: featured.stamp.kind.displayName))
        .accessibilityValue(Text(verbatim: StampWords.spoken(featured)))
    }
}

/// The last four stamps as small discs, then "5 of 19".
struct StampLatestRow: View {
    let stamps: [WidgetStampShelf.Stamp]
    let theme: WidgetTheme
    let mono: Bool

    var body: some View {
        let total = WidgetStampKind.allCases.count
        HStack(spacing: 5) {
            ForEach(WidgetStampShelf.latest(stamps), id: \.kind) { stamp in
                WidgetStampDisc(kind: stamp.kind, size: 30, scale: 2, mono: mono, theme: theme)
            }
            Text(verbatim: StampWords.count(stamps.count, of: total))
                .font(WidgetFont.label(12.5))
                .foregroundStyle(theme.muted)
                .lineLimit(1)
                .accessibilityLabel(Text(verbatim: StampWords.spokenCount(stamps.count, of: total)))
        }
    }
}

/// "New today" (`.ribbon`): white on brick in an ink frame.
struct StampRibbon: View {
    let mono: Bool

    var body: some View {
        Text("New today")
            .font(WidgetFont.label(11).weight(.bold))
            .foregroundStyle(.white)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(mono ? Color.white.opacity(0.2) : WidgetFixedInk.ribbon, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(mono ? Color.white.opacity(0.5) : WidgetFixedInk.bubbleFrame, lineWidth: 2))
    }
}

/// Before the first stamp: the dashed empty disc and "Your first stamp is waiting".
struct StampFirstWaiting: View {
    let theme: WidgetTheme
    let mono: Bool

    var body: some View {
        VStack(spacing: 6) {
            WidgetStampDisc(kind: nil, size: 70, scale: 4, mono: mono, theme: theme)
            Text("Your first stamp is waiting")
                .font(WidgetFont.display(16))
                .foregroundStyle(theme.text)
                .multilineTextAlignment(.center)
                .lineLimit(2)
                .minimumScaleFactor(0.7)
        }
    }
}

/// A stamp on its disc: the art on gold in an ink ring, or (nil) a dashed empty disc with a faded
/// ring. The disc keeps its gold in dark mode, like a stamp on a dark page, so one-colour ink art on it
/// stays ink (the app's `StampBookArt.discTint`).
struct WidgetStampDisc: View {
    let kind: WidgetStampKind?
    let size: CGFloat
    /// Points per sprite pixel of the art.
    let scale: CGFloat
    let mono: Bool
    let theme: WidgetTheme
    @Environment(\.redactionReasons) private var redaction

    var body: some View {
        ZStack {
            if redaction.contains(.privacy) {
                // A Canvas is not redacted by iOS on its own: a placeholder disc while locked.
                Circle().fill(.tertiary)
            } else if let kind {
                Circle().fill(mono ? Color.white.opacity(0.18) : WidgetFixedInk.stampGold)
                Circle().strokeBorder(mono ? Color.white.opacity(0.6) : WidgetFixedInk.bubbleFrame, lineWidth: size > 40 ? 3 : 2)
                WidgetSpriteView(sprite: kind.sprite, scale: scale, paint: artPaint(kind.sprite))
            } else {
                Circle().strokeBorder(theme.dashed, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                WidgetSpriteView(sprite: WidgetSprites.ring, scale: scale, paint: .solid(mono ? 0xFFFFFF : 0xC9BBA0))
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private func artPaint(_ sprite: WidgetSprite) -> WidgetSpritePaint {
        // In one colour the art keeps only its ink outline, so the duck still reads as a duck; art
        // with no ink key (the leaf) is drawn whole.
        if mono { return sprite.palette["k"] == nil ? .solid(0xFFFFFF) : .outline(0xFFFFFF) }
        return sprite.isMonoInk ? .solid(WidgetSprite.ink) : .plain
    }
}
