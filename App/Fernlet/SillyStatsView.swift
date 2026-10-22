//
//  SillyStatsView.swift
//  Fernlet
//
//  The silly stats page (a large sheet from the Home card, or pushed from Milestones) and the Home
//  card itself. Only stats with something behind them show; the rest stay hidden until life gets
//  around to them, with no list of what is missing — nothing here is a goal. The stamp book
//  (`SillyStampViews`) sits at the top of the page once a stat has earned its stamp.
//

import SwiftUI
import FernletUI
import FernletFoundation

/// The silly stats sheet: its own header and Done, over ``SillyStatsList``.
///
/// Presented from the Home card as a large sheet (the read-only-from-Home rule Milestones and
/// Trends follow), with its own `NavigationStack` like ``MilestonesView``.
struct SillyStatsView: View {
    var store: FernletStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                SheetHeader(
                    title: "Silly stats",
                    subtitle: "Completely useless numbers, lovingly counted.",
                    onDone: { dismiss() }
                )
                SillyStatsList(store: store)
            }
            .background(Color.parchment)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// The stamp book and the revealed stat cards, refreshed from the diary and Apple Health each time
/// they appear.
///
/// Used by the sheet and by the push from Milestones.
struct SillyStatsList: View {
    var store: FernletStore

    var body: some View {
        let stats = store.sillyStats
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if !stats.stamps.isEmpty {
                    SillyStampBookCard(stamps: stats.stamps)
                }
                if stats.revealed.isEmpty {
                    Text("Nothing silly to report yet. Stats turn up on their own as you log — no hurry.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                } else {
                    ForEach(stats.revealed, id: \.self) { kind in
                        SillyStatCard(kind: kind, tally: stats.tally)
                    }
                    if stats.revealed.count < SillyStatKind.allCases.count {
                        Text("More stats turn up as life happens.")
                            .font(.fernlet(.bubble))
                            .foregroundStyle(Color.slate)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 4)
                    }
                }
            }
            .padding(20)
            .uxScreenAnchor("screen.sillyStats")
        }
        .background(Color.parchment)
        .task { await store.sillyStats.refresh(store: store) }
    }
}

/// One stat: emoji and title, the big number, the comparison, extras (the cookie table, the pizza
/// chart), and how it's counted.
struct SillyStatCard: View {
    var kind: SillyStatKind
    var tally: SillyStatsTally

    var body: some View {
        let text = SillyStatsCopy.text(for: kind, tally: tally)
        FernletCard {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text(verbatim: text.emoji)
                        .accessibilityHidden(true)
                    Text(verbatim: text.title)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.slate)
                }
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: text.headline)
                            .font(.fernlet(.displayMedium))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        Text(verbatim: text.detail)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                    if kind == .pizzaPieChart {
                        SillyPizzaPie(slices: tally.pizzaSlices)
                    }
                }
                if kind == .cookiesPerDay {
                    SillyCookieTableDisclosure()
                }
                Text(verbatim: text.footnote)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("sillyStats.\(kind.rawValue)")
    }
}

/// The cookie table behind CPD, folded away under the CPD card.
struct SillyCookieTableDisclosure: View {
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(SillyFoodCounter.cookieTable) { rule in
                    row(label: Self.label(for: rule.kind), value: rule.value)
                }
                row(label: Text("Homemade, any size"), value: SillyFoodCounter.homemadeCookieValue)
            }
            .padding(.top, 6)
        } label: {
            Text("The cookie table")
                .font(.fernlet(.label))
                .foregroundStyle(Color.bark)
        }
        .tint(Color.bark)
    }

    private func row(label: Text, value: Double) -> some View {
        HStack {
            label
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Spacer(minLength: 8)
            Text(verbatim: Self.fraction(value))
                .font(.fernlet(.stat))
                .foregroundStyle(Color.bark)
        }
        .accessibilityElement(children: .combine)
    }

    /// "½" and "¼" for the halves and quarters, the plain number otherwise.
    static func fraction(_ value: Double) -> String {
        switch value {
        case 0.25: "¼"
        case 0.5: "½"
        default: value.formatted(.number.precision(.fractionLength(0...2)))
        }
    }

    static func label(for kind: SillyCookieRule.Kind) -> Text {
        switch kind {
        case .fortune: Text("Fortune cookie (mostly fortune)")
        case .animalCracker: Text("Animal cracker, each")
        case .giantBakery: Text("Giant bakery cookie")
        case .sandwich: Text("Oreos and other sandwich cookies")
        case .girlScoutHalf: Text("Thin Mints, Trefoils, Do-si-dos")
        case .figNewton: Text("Fig Newtons (legally a cookie)")
        case .girlScoutFull: Text("Samoas, Tagalongs (they're doing a lot)")
        case .standard: Text("Any other cookie")
        }
    }
}

/// A literal pie chart that is also a pizza: the slices of the pizza in progress, pepperoni on
/// the ones eaten. Decorative — the card's text carries the numbers.
struct SillyPizzaPie: View {
    var slices: Double

    private static let slicesPerPie = 8

    var body: some View {
        let eaten = Self.slicesOnCurrentPizza(slices)
        let wedges = Self.slicesPerPie
        Canvas { context, size in
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: 3, dy: 3)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = rect.width / 2
            context.fill(Path(ellipseIn: rect), with: .color(Color.goldenrod.opacity(0.15)))
            for index in 0..<wedges {
                let start = Angle.degrees(Double(index) * 45 - 90)
                var wedge = Path()
                wedge.move(to: center)
                wedge.addArc(center: center, radius: radius, startAngle: start, endAngle: start + .degrees(45), clockwise: false)
                wedge.closeSubpath()
                if index < eaten {
                    context.fill(wedge, with: .color(Color.sun.opacity(0.85)))
                    let middle = start.radians + Double.pi / 8
                    let dot = CGPoint(x: center.x + cos(middle) * radius * 0.6, y: center.y + sin(middle) * radius * 0.6)
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - 4, y: dot.y - 4, width: 8, height: 8)), with: .color(Color.terracotta))
                }
                context.stroke(wedge, with: .color(Color.goldenrod), lineWidth: 1.5)
            }
            context.stroke(Path(ellipseIn: rect), with: .color(Color.goldenrod), lineWidth: 4)
        }
        .frame(width: 76, height: 76)
        .accessibilityHidden(true)
    }

    /// Slices on the pizza in progress: a whole pizza shows full rather than empty.
    static func slicesOnCurrentPizza(_ slices: Double) -> Int {
        guard slices.isFinite, slices > 0 else { return 0 }
        let whole = Int(min(slices, 1_000_000).rounded(.down))
        let remainder = whole % slicesPerPie
        return remainder == 0 && whole > 0 ? slicesPerPie : remainder
    }
}

/// The Home card: one revealed stat, chosen by the day so it changes now and then, and a way into
/// the page.
struct SillyStatsHomeCard: View {
    var stats: SillyStatsService
    var onOpen: () -> Void

    var body: some View {
        let featured = Self.featured(in: stats.revealed, todayKey: FernletDate.dayKey(for: .now))
        let text = featured.map { SillyStatsCopy.text(for: $0, tally: stats.tally) }
        Button(action: onOpen) {
            FernletCard {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Silly stats")
                            .font(.fernlet(.headerMedium))
                            .foregroundStyle(Color.bark)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.slate)
                            .accessibilityHidden(true)
                    }
                    if let text {
                        // The emoji apart from the headline, and drawn rather than set as text: in the
                        // headline it overran Instrument Serif's short line, and even alone in a
                        // system-font `Text` the audit reports an emoji's glyph as clipped text.
                        HStack(alignment: .center, spacing: 8) {
                            SillyStatEmoji(emoji: text.emoji)
                            Text(verbatim: text.headline)
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                        }
                        Text(verbatim: text.detail)
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    } else {
                        Text("Useless numbers, lovingly counted. They turn up as you log.")
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.sillyStats")
        .accessibilityInputLabels([Text("Silly stats")])
    }

    /// The stat the card shows today: a day-seeded pick, so it is stable across relaunches.
    static func featured(in revealed: [SillyStatKind], todayKey: String) -> SillyStatKind? {
        guard !revealed.isEmpty else { return nil }
        return revealed[GentleOfferEngine.rotationSeed(dateKey: todayKey) % revealed.count]
    }
}

/// A silly stat's emoji, drawn into a `Canvas` at a size that tracks Dynamic Type.
///
/// Decorative beside the headline it illustrates, so it is hidden from VoiceOver as the stats page
/// hides it. Drawn rather than laid out because the accessibility audit reports a bare emoji `Text`
/// as clipped (its glyph overhangs the line box) at every size; the canvas is the same picture,
/// scaled by `@ScaledMetric` so it still grows with the user's text size.
private struct SillyStatEmoji: View {
    let emoji: String
    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 22

    var body: some View {
        Canvas { context, size in
            let glyph = context.resolve(Text(verbatim: emoji).font(.system(size: side * 0.8)))
            context.draw(glyph, at: CGPoint(x: size.width / 2, y: size.height / 2))
        }
        .frame(width: side, height: side)
        .accessibilityHidden(true)
    }
}
