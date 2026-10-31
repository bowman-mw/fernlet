//
//  SillyStampViews.swift
//  Fernlet
//
//  The stamps as drawn: the stamp itself, the Silly stamps card in the Stamp book, and the banner that
//  says a stamp was just earned. In the app only — a stamp never raises a notification.
//

import SwiftUI
import FernletUI
import FernletFoundation

/// A stamp (design `b2-stamp-art`, approved 2026-10-24): the stat's pixel art (``WorldStampArt``) on a
/// gold disc in a 3-pt ink ring once earned; before that, a faded silhouette of the art in a dashed ring.
///
/// Decorative — the name beside it carries the meaning — so it is hidden from VoiceOver. The gold disc
/// keeps its colour in both appearances, so a one-colour ink stamp (Encore's note) stays ink on it.
struct SillyStampBadge: View {
    let kind: SillyStatKind
    var earned = true
    /// The disc's diameter.
    var diameter: CGFloat = 54
    /// Points per sprite pixel.
    var scale: CGFloat = 3

    var body: some View {
        let sprite = WorldStampArt.sprite(for: kind)
        Group {
            if earned {
                WorldSpriteView(sprite: sprite, scale: scale, tint: StampBookArt.discTint(for: sprite))
                    .frame(width: diameter, height: diameter)
                    .background(WorldPalette.rgb(StampBookArt.stampGold), in: Circle())
                    .overlay(Circle().strokeBorder(WorldPalette.ink, lineWidth: 3))
            } else {
                WorldSpriteView(sprite: sprite, scale: scale, tint: WorldPalette.rgb(StampBookArt.silhouette))
                    .frame(width: diameter, height: diameter)
                    .overlay(Circle().strokeBorder(WorldPalette.ink.opacity(0.25), style: StrokeStyle(lineWidth: 2, dash: [5, 4])))
            }
        }
        .accessibilityHidden(true)
    }
}

/// The Stamp book's Silly stamps card (designs `b1-stamp-book`, folded into `b2-milestones` draft 2, and
/// `b2-stamp-art`): all twenty stamps, four a row (two at accessibility text sizes), the earned ones on
/// gold with their names and days, the rest as faded silhouettes over “?”, with “3 of 19” beside the title.
///
/// The owner approved showing the silhouettes (`b2-stamp-art`: “Unearned stamps still show as a faded
/// silhouette with ?”); the stats themselves still stay hidden until they mean something. Each stamp is
/// one VoiceOver element: its name, stat and day, or “A stamp not earned yet”.
struct SillyStampBookCard: View {
    var stamps: [SillyStampEntry]
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let earned = Dictionary(stamps.map { ($0.kind, $0) }, uniquingKeysWith: { first, _ in first })
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                header(count: earned.count)
                Text("A stamp arrives the day a silly stat first shows up. They only add up.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(WorldPalette.dim)
                    .fernletWrappingText()
                LazyVGrid(columns: columns, alignment: .center, spacing: 12) {
                    ForEach(SillyStatKind.allCases, id: \.self) { kind in
                        SillyStampCell(kind: kind, entry: earned[kind])
                    }
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sillyStats.stampBook")
    }

    private func header(count: Int) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 8))
        return layout {
            Text("Silly stamps")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(WorldPalette.bark)
                .accessibilityAddTraits(.isHeader)
            if !dynamicTypeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text("\(count) of \(SillyStatKind.allCases.count)")
                .font(.fernlet(.label))
                .foregroundStyle(WorldPalette.dim)
        }
    }

    /// Four stamps a row, or two at accessibility text sizes.
    private var columns: [GridItem] {
        let count = dynamicTypeSize.isAccessibilitySize ? 2 : 4
        return Array(repeating: GridItem(.flexible(), spacing: 6, alignment: .top), count: count)
    }
}

/// One stamp in the book: the stamp, its name and the day it was earned, or a silhouette over “?”.
struct SillyStampCell: View {
    var kind: SillyStatKind
    var entry: SillyStampEntry?

    var body: some View {
        if let entry {
            earnedCell(entry)
        } else {
            VStack(spacing: 4) {
                SillyStampBadge(kind: kind, earned: false)
                Text(verbatim: "?")
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(WorldPalette.dim)
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Text(Self.unearnedLabel))
        }
    }

    /// An unearned stamp's spoken name. Static: nothing can activate it, so Voice Control never names it.
    private static let unearnedLabel = LocalizedStringResource("A stamp not earned yet",
                                                               comment: "Stamp book: VoiceOver for a stamp slot whose silly stat hasn't shown up yet (drawn as a faded silhouette over '?')")

    private func earnedCell(_ entry: SillyStampEntry) -> some View {
        let name = SillyStampCopy.name(for: entry.kind)
        let earned = FernletDate.date(fromDayKey: entry.dayKey) ?? entry.createdAt
        return VStack(spacing: 4) {
            SillyStampBadge(kind: entry.kind)
            Text(verbatim: name)
                .font(.fernlet(.labelSmall).weight(.semibold))
                .foregroundStyle(WorldPalette.bark)
                .multilineTextAlignment(.center)
                .fernletWrappingText()
            Text(earned, format: Self.dayFormat(for: earned))
                .font(.fernlet(.labelSmall))
                .foregroundStyle(WorldPalette.dim)
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
/// Day has begun." Tapping it opens the Stamp book at its stamps.
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
                WorldSpriteView(sprite: WorldStampArt.sprite(for: kind), scale: 4,
                                tint: StampBookArt.discTint(for: WorldStampArt.sprite(for: kind)))
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
