//
//  SillyStampViews.swift
//  Fernlet
//
//  The stamps as drawn: the stamp itself, the stamp book at the top of the silly stats page, and the
//  banner that says a stamp was just earned. In the app only — a stamp never raises a notification.
//

import SwiftUI
import FernletUI
import FernletFoundation

/// A stamp: the stat's emoji inside a round, inked rim with a perforated edge, tilted a little as if
/// pressed by hand.
///
/// Decorative — the name beside it carries the meaning — so it is hidden from VoiceOver. Drawn
/// rather than laid out for the reason ``SillyStatsHomeCard``'s emoji is: the accessibility audit
/// reports a bare emoji `Text` as clipped. Grows with the user's text size.
struct SillyStampBadge: View {
    let kind: SillyStatKind
    /// The diameter at the default text size.
    var diameter: CGFloat = 56
    @ScaledMetric(relativeTo: .body) private var scale: CGFloat = 1

    var body: some View {
        let side = diameter * min(max(scale, 0.8), 2.2)
        let palette = Self.palette(for: kind)
        ZStack {
            Circle().fill(Color.parchment)
            Circle().fill(palette.fill.opacity(0.16))
            Circle().strokeBorder(palette.ink, style: StrokeStyle(lineWidth: max(1.5, side * 0.04), dash: [side * 0.07, side * 0.05]))
            Circle().inset(by: side * 0.12).strokeBorder(palette.ink.opacity(0.5), lineWidth: 1)
            Canvas { context, size in
                let glyph = context.resolve(Text(verbatim: SillyStampCopy.emoji(for: kind)).font(.system(size: size.width * 0.4)))
                context.draw(glyph, at: CGPoint(x: size.width / 2, y: size.height / 2))
            }
        }
        .frame(width: side, height: side)
        .rotationEffect(.degrees(Self.tilt(for: kind)))
        // Paper and ink in both appearances, like a real stamp on a dark page: the dark palette's
        // fills lost the darker emoji (the paw prints all but vanished on dark goldenrod).
        .environment(\.colorScheme, .light)
        .accessibilityHidden(true)
    }

    /// The stamp's ink: terracotta, moss or goldenrod, taking turns down the page order.
    static func palette(for kind: SillyStatKind) -> (fill: Color, ink: Color) {
        let inks: [(fill: Color, ink: Color)] = [
            (Color.terracotta, Color.terracottaInk), (Color.moss, Color.mossInk), (Color.goldenrod, Color.goldenrodInk),
        ]
        let index = SillyStatKind.allCases.firstIndex(of: kind) ?? 0
        return inks[index % inks.count]
    }

    /// A few degrees either way, fixed per stamp so the book looks hand-stamped but never shuffles.
    static func tilt(for kind: SillyStatKind) -> Double {
        let tilts: [Double] = [-6, 4, -3, 6, -5, 2, -2, 5]
        let index = SillyStatKind.allCases.firstIndex(of: kind) ?? 0
        return tilts[index % tilts.count]
    }
}

/// The stamp book: every stamp earned so far, in the order they were earned, each with its day.
///
/// At the top of ``SillyStatsList``, so it is on the silly stats page and on the push from
/// Milestones alike. Drawn only once there is a stamp in it: like the stats themselves, the book
/// never lists what is missing. Each stamp is one VoiceOver element that says its name, its stat
/// and the day it was earned.
struct SillyStampBookCard: View {
    var stamps: [SillyStampEntry]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// The narrowest a stamp's column may be, growing with the text size so a name never truncates.
    @ScaledMetric(relativeTo: .body) private var columnMinimum: CGFloat = 88

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 16) {
                header
                LazyVGrid(columns: columns, alignment: .center, spacing: 18) {
                    ForEach(stamps) { entry in
                        SillyStampCell(entry: entry)
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sillyStats.stampBook")
    }

    private var header: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text("Stamp book")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
                .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text("\(stamps.count) of \(SillyStatKind.allCases.count)")
                .font(.fernlet(.label))
                .foregroundStyle(Color.slate)
        }
    }

    /// Three or four stamps a row, or one a row at accessibility text sizes.
    private var columns: [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible(), alignment: .top)]
        }
        return [GridItem(.adaptive(minimum: columnMinimum), spacing: 10, alignment: .top)]
    }
}

/// One stamp in the book: the stamp, its name and the day it was earned.
struct SillyStampCell: View {
    var entry: SillyStampEntry

    var body: some View {
        let name = SillyStampCopy.name(for: entry.kind)
        let earned = FernletDate.date(fromDayKey: entry.dayKey) ?? entry.createdAt
        VStack(spacing: 6) {
            SillyStampBadge(kind: entry.kind)
                .padding(.bottom, 2)
            Text(verbatim: name)
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Text(earned, format: Self.dayFormat(for: earned))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("\(name), \(SillyStampCopy.statTitle(for: entry.kind)), earned \(earned, format: .dateTime.day().month(.wide).year())"))
        .accessibilityIdentifier("sillyStats.stamp.\(entry.kind.rawValue)")
    }

    /// "22 Oct", or "22 Oct 2025" for a stamp from another year.
    static func dayFormat(for date: Date, now: Date = .now, calendar: Calendar = .current) -> Date.FormatStyle {
        let thisYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return thisYear ? .dateTime.day().month(.abbreviated) : .dateTime.day().month(.abbreviated).year()
    }
}

/// The banner for a stamp earned just now: the stamp, "New stamp: Crumb Goblin" and "Cookies Per
/// Day has begun." Tapping it opens the silly stats page, where the stamp book is.
///
/// World build: drawn in the pixel language (design `b1-stamp-banner`): a paper plate in a 3-pt ink
/// frame with a solid drop shadow, the stamp's pixel art (``WorldStampArt``) on a gold disc.
///
/// Purely presentational. ``ContentView`` decides when it shows (never over a sheet), how long it
/// stays (``FernletDismissalWindow``), and speaks it for VoiceOver — the banner appears with no
/// focus change, so the announcement is how a VoiceOver user hears of it. The stamp thumps down
/// once as it lands; under Reduce Motion it is simply there.
struct SillyStampBanner: View {
    var kind: SillyStatKind
    var onOpen: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasLanded = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 12, style: .continuous)
        let settled = hasLanded || reduceMotion
        Button(action: onOpen) {
            HStack(alignment: .center, spacing: 12) {
                WorldSpriteView(sprite: WorldStampArt.sprite(for: kind), scale: 4)
                    .frame(width: 44, height: 44)
                    .background(WorldPalette.rgb(0xF2C14E), in: Circle())
                    .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 3))
                    .scaleEffect(settled ? 1 : 1.4)
                    .opacity(settled ? 1 : 0)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: SillyStampCopy.bannerTitle(for: kind))
                        .font(WorldType.bannerTitle)
                        .foregroundStyle(WorldPalette.bark)
                        .fernletWrappingText()
                    Text(verbatim: SillyStampCopy.bannerDetail(for: kind))
                        .font(WorldType.bannerDetail)
                        .foregroundStyle(WorldPalette.bark)
                        .fernletWrappingText()
                }
                Spacer(minLength: 0)
            }
            .padding(EdgeInsets(top: 9, leading: 9, bottom: 9, trailing: 14))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(WorldPalette.paper, in: shape)
            .overlay(shape.strokeBorder(WorldPalette.ink, lineWidth: 3))
            .background { shape.fill(WorldPalette.ink.opacity(0.35)).offset(y: 4) }
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: SillyStampCopy.announcement(for: kind)))
        .accessibilityHint(Text("Opens your stamp book."))
        .accessibilityIdentifier("sillyStampBanner")
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.spring(response: 0.34, dampingFraction: 0.5).delay(0.18)) {
                hasLanded = true
            }
        }
    }
}
