//
//  MilestonesView.swift
//  Fernlet
//
//  A modest lifetime-milestones surface: warm cumulative counts of care ("You've written 40
//  journal moments") plus the little coin gifts each milestone added. Cumulative ONLY — no rates,
//  no per-week stats, no completion percentages, and never anything "in a row". Counts come from
//  the append-only milestone ledger, so they can only grow — deleting entries, disabling
//  HealthKit, or even a full data reset never takes a milestone away.
//
//  Two ways to look at the same numbers, per the approved design:
//    • warm rows — the everyday screen: a count folded into a warm sentence, so it reads as a
//      memory, not a metric. Gifts are a soft aside, never a badge to chase.
//    • the keepsake shelf — a tap-in sub-view of pressed-metal medallions resting on wooden
//      ledges. A memento box, not a stat grid: only earned kinds appear, and counts stay soft.
//

import SwiftUI
import FernletDomainModel
import StoreCore
import FernletUI

/// The lifetime-milestones screen: warm cumulative counts of care plus the coin gifts each
/// milestone added.
///
/// Pushed from Home. Rows come from ``MilestoneRowModel`` over the store's append-only milestone
/// ledger (plus the device-local worries-let-go count), so numbers only ever grow — no rates,
/// streaks, or completion percentages, by design. A mostly-empty shelf swaps in a gentler header;
/// otherwise a link opens the `KeepsakeShelfView` medallion view, and the coins summary uses
/// the reset-aware `CoinEconomy.milestoneAwardCoins` so it can never disagree with the wallet.
struct MilestonesView: View {
    var store: FernletStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                eyebrow
                header

                VStack(spacing: 11) {
                    ForEach(rows, id: \.kind) { row in
                        milestoneRow(row)
                    }
                }

                coinsSummary
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("Milestones")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Eyebrow

    /// A small, spaced "MILESTONES" label sitting above the title — the keepsake-shelf eyebrow from
    /// the mockup, so the screen opens like a quiet page in a memento book rather than a stat panel.
    private var eyebrow: some View {
        Text("MILESTONES")
            .font(.fernlet(.labelSmall))
            .tracking(1.6)
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity)
            // Stable screen anchor (same convention as ScreenHeader's "screen.home" etc.) so UI tests
            // can assert this screen was actually reached, not just that some nav bar exists.
            .accessibilityIdentifier("screen.milestones")
    }

    // MARK: - Data

    private var rows: [MilestoneRowModel] {
        MilestoneRowModel.rows(counts: store.milestoneCounts, worriesLetGo: store.lifetimeWorriesLetGo)
    }

    /// Coins gifted by milestone awards so far. Reset-aware (the same voiding the wallet applies to
    /// milestone earns), so it can never disagree with the balance after a "Reset everything".
    private var totalMilestoneCoins: Int {
        CoinEconomy.milestoneAwardCoins(in: store.coinLedgerService.entries)
    }

    /// True while the shelf is barely filling in — a gentler header + softer coins note, and zero
    /// kinds show as a quiet dashed "your first … will land here" row rather than a full sentence.
    /// Threshold is deliberately loose: "mostly empty" is a feeling, not a metric. No gifts yet
    /// (nothing has crossed a threshold) and every kind is still in single digits.
    private var isMostlyEmpty: Bool {
        totalMilestoneCoins == 0 && rows.allSatisfy { $0.count < 10 }
    }

    // MARK: - Header

    @ViewBuilder
    private var header: some View {
        if isMostlyEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("The shelf is filling in")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Text("These only ever grow, in their own time. There's nothing to keep up with here.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
        } else {
            Text("All of it, added up")
                .font(.fernlet(.header))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()

            Text("Every bit of care you've logged, added up over all time. These numbers only ever grow — nothing here resets, expires, or asks you to keep a streak.")
                .font(.fernlet(.body))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            NavigationLink {
                KeepsakeShelfView(rows: rows, totalMilestoneCoins: totalMilestoneCoins)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "seal")
                        .font(.footnote.weight(.semibold))
                    Text("See your keepsake shelf")
                        .font(.fernlet(.label))
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.forward")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
                .foregroundStyle(Color.bark)
                .padding(.vertical, 12)
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(Color.goldenrod.opacity(0.28), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Rows (7a)

    @ViewBuilder
    private func milestoneRow(_ row: MilestoneRowModel) -> some View {
        if row.count == 0 {
            // A quiet, dashed "your first … will land here" placeholder — never a to-do item.
            HStack(spacing: 14) {
                iconTile(row, dimmed: true)
                Text(row.emptyPrompt)
                    .font(.fernlet(.bubble))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.cream.opacity(0.55))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.bark.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [5, 4]))
            )
            .accessibilityElement(children: .combine)
        } else {
            HStack(spacing: 14) {
                iconTile(row, dimmed: false)
                VStack(alignment: .leading, spacing: 5) {
                    Text(row.headline)
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    if row.reachedCount > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.goldenrod)
                            Text(row.reachedCount == 1 ? "1 milestone gift" : "\(row.reachedCount) milestone gifts")
                                .font(.fernlet(.labelSmall))
                                .foregroundStyle(Color.goldenrod)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityElement(children: .combine)
        }
    }

    private func iconTile(_ row: MilestoneRowModel, dimmed: Bool) -> some View {
        Image(systemName: row.icon)
            .font(.system(size: 20, weight: .regular))
            .foregroundStyle(row.tint.opacity(dimmed ? 0.5 : 1))
            .frame(width: 44, height: 44)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(row.tint.opacity(dimmed ? 0.12 : 0.18))
            )
    }

    // MARK: - Coins summary

    @ViewBuilder
    private var coinsSummary: some View {
        if totalMilestoneCoins > 0 {
            HStack(spacing: 15) {
                CoinGlyph(diameter: 46)
                Text("Milestone gifts have added \(totalMilestoneCoins) coins to your pouch.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .fill(Color.cream)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .strokeBorder(Color.goldenrod.opacity(0.3), lineWidth: 1)
            )
        } else {
            // No gifts yet: a reassuring note, never a countdown to chase.
            HStack(spacing: 14) {
                CoinGlyph(diameter: 40, muted: true)
                Text("No milestone gifts yet — the first lands with your very first log. No rush.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                Spacer(minLength: 0)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(Color.cream.opacity(0.7))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .strokeBorder(Color.goldenrod.opacity(0.22), lineWidth: 1)
            )
        }
    }
}

// MARK: - Keepsake shelf (7b)

/// The tap-in "shelf" view: each earned kind is a pressed-metal medallion resting on a wooden
/// ledge, grouped three to a shelf.
///
/// Only earned kinds appear — there are deliberately no locked or empty slots to goad a "collect
/// them all" — and counts stay soft (a small number under the medallion). Receives its rows and
/// coin total from ``MilestonesView`` so both surfaces always agree.
private struct KeepsakeShelfView: View {
    let rows: [MilestoneRowModel]
    let totalMilestoneCoins: Int

    /// Only kinds with something to show — no empty/locked slots by design.
    private var earned: [MilestoneRowModel] {
        rows.filter { $0.count > 0 }
    }

    /// Chunk into ledges of three so each shelf holds a tidy row of medallions.
    private var shelves: [[MilestoneRowModel]] {
        stride(from: 0, to: earned.count, by: 3).map { start in
            Array(earned[start ..< min(start + 3, earned.count)])
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if earned.isEmpty {
                    Text("Your keepsake shelf")
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text("Nothing pressed onto the shelf just yet. Every bit of care will find a place here, in its own time.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                } else {
                    Text("Every bit of care, pressed into a keepsake. These only ever grow — nothing resets or expires.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()

                    VStack(spacing: 22) {
                        ForEach(Array(shelves.enumerated()), id: \.offset) { _, ledge in
                            shelfLedge(ledge)
                        }
                    }

                    if totalMilestoneCoins > 0 {
                        HStack(spacing: 15) {
                            CoinGlyph(diameter: 46)
                            Text("Milestone gifts have added \(totalMilestoneCoins) coins to your pouch.")
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                            Spacer(minLength: 0)
                        }
                        .padding(.vertical, 16)
                        .padding(.horizontal, 18)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .fill(Color.cream)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.goldenrod.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.top, 4)
                    }
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("Keepsake shelf")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func shelfLedge(_ ledge: [MilestoneRowModel]) -> some View {
        VStack(spacing: 14) {
            HStack(alignment: .bottom, spacing: 0) {
                ForEach(ledge, id: \.kind) { row in
                    medallion(row)
                        .frame(maxWidth: .infinity)
                }
            }
            // The wooden ledge the medallions rest on.
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Color.shelfLedgeTop, Color.shelfLedgeBottom],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .frame(height: 8)
                .shadow(color: Color.bark.opacity(0.14), radius: 4, x: 0, y: 3)
        }
    }

    private func medallion(_ row: MilestoneRowModel) -> some View {
        VStack(spacing: 9) {
            PressedMedallion(icon: row.icon, tint: row.tint, diameter: 88)
            VStack(spacing: 1) {
                Text("\(row.count)")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
                Text(row.shelfLabel)
                    .font(.fernlet(.labelSmall))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(row.headline)
    }
}

// MARK: - Warm display copy

/// Warm display copy per milestone kind.
///
/// Kept as a tiny model so the row order and phrasing live in one place (and copy stays
/// count-aware without pluralization bugs). Built by ``MilestoneRowModel/rows(counts:worriesLetGo:)``,
/// which also encodes the worry-kind exceptions: worry counts come from the device-local Worry
/// Box rather than the synced ledger, and worries award no coins.
struct MilestoneRowModel {
    let kind: MilestoneEventKind
    let icon: String
    let tint: Color
    let headline: String
    let reachedCount: Int
    /// Raw lifetime count — drives the shelf medallions, empty-vs-filled row styling, and the
    /// mostly-empty header decision. (The sentence in `headline` already folds this in.)
    let count: Int
    /// A short lower-case label for under a shelf medallion ("journal", "worries let go").
    let shelfLabel: String
    /// A gentle "your first … will land here" line for a kind with no count yet.
    let emptyPrompt: String

    static func rows(counts: [MilestoneEventKind: Int], worriesLetGo: Int) -> [MilestoneRowModel] {
        let order: [(MilestoneEventKind, String, Color, String, String)] = [
            (.journal, "book.closed", .journalMedal, "journal", "Your first journal moment will land here."),
            (.meal, "fork.knife", .mealMedal, "meals", "Your first noticed meal will land here."),
            (.workout, "figure.walk", .workoutMedal, "workouts", "Your first time moving will land here."),
            (.water, "drop", .waterMedal, "water", "Your first well-watered day will land here."),
            (.breathing, "wind", .breathingMedal, "breathing", "Your first slow-breathing break will land here."),
            (.worry, "archivebox", .worryMedal, "worries let go", "Your first worry let go will land here.")
        ]
        return order.map { kind, icon, tint, shelfLabel, emptyPrompt in
            // Worry counts come from the device-local Worry Box (never the synced ledger), and worries
            // award no coins (a device-local coin award would desync the wallet), so their "gifts" is 0.
            let count = kind == .worry ? worriesLetGo : (counts[kind] ?? 0)
            let reachedCount = kind == .worry ? 0 : MilestoneEconomy.thresholds.filter { $0 <= count }.count
            return MilestoneRowModel(
                kind: kind,
                icon: icon,
                tint: tint,
                headline: headline(kind: kind, count: count),
                reachedCount: reachedCount,
                count: count,
                shelfLabel: shelfLabel,
                emptyPrompt: emptyPrompt
            )
        }
    }

    private static func headline(kind: MilestoneEventKind, count: Int) -> String {
        switch kind {
        case .journal:
            count == 0 ? "Your journal moments will gather here."
                : (count == 1 ? "You've written your first journal moment." : "You've written \(count) journal moments.")
        case .meal:
            count == 0 ? "Meals you notice will gather here."
                : (count == 1 ? "You've noted your first meal." : "You've noted \(count) meals.")
        case .workout:
            count == 0 ? "Times you move will gather here."
                : (count == 1 ? "You've moved your body once, on purpose." : "You've moved your body \(count) times.")
        case .water:
            count == 0 ? "Days you drink enough water will gather here."
                : (count == 1 ? "You've had one well-watered day." : "You've had \(count) well-watered days.")
        case .breathing:
            count == 0 ? "Breathing breaks will gather here."
                : (count == 1 ? "You've taken one slow-breathing break." : "You've taken \(count) slow-breathing breaks.")
        case .worry:
            count == 0 ? "Worries you let go will gather here."
                : (count == 1 ? "You've let one worry go." : "You've let \(count) worries go.")
        }
    }
}

// MARK: - Local shades

// Medallion metals + shelf/coin tones used only by this screen. Kept as private local constants so
// the shared palette isn't touched; each adapts for light + dark via the existing Color(light:dark:).
private extension Color {
    // Journal — soft amethyst.
    static let journalMedal = Color(
        light: Color(red: 0.663, green: 0.608, blue: 0.706),
        dark:  Color(red: 0.541, green: 0.486, blue: 0.596)
    )
    // Meals — warm honey.
    static let mealMedal = Color(
        light: Color(red: 0.788, green: 0.588, blue: 0.290),
        dark:  Color(red: 0.706, green: 0.514, blue: 0.243)
    )
    // Workouts — living green.
    static let workoutMedal = Color(
        light: Color(red: 0.420, green: 0.620, blue: 0.384),
        dark:  Color(red: 0.361, green: 0.529, blue: 0.329)
    )
    // Water — river blue.
    static let waterMedal = Color(
        light: Color(red: 0.549, green: 0.651, blue: 0.714),
        dark:  Color(red: 0.443, green: 0.541, blue: 0.604)
    )
    // Breathing — sage green.
    static let breathingMedal = Color(
        light: Color(red: 0.541, green: 0.678, blue: 0.494),
        dark:  Color(red: 0.451, green: 0.573, blue: 0.408)
    )
    // Worries let go — gilded gold.
    static let worryMedal = Color(
        light: Color(red: 0.831, green: 0.659, blue: 0.263),
        dark:  Color(red: 0.741, green: 0.573, blue: 0.220)
    )

    // Wooden shelf ledge.
    static let shelfLedgeTop = Color(
        light: Color(red: 0.847, green: 0.780, blue: 0.651),
        dark:  Color(red: 0.290, green: 0.243, blue: 0.176)
    )
    static let shelfLedgeBottom = Color(
        light: Color(red: 0.765, green: 0.686, blue: 0.533),
        dark:  Color(red: 0.220, green: 0.180, blue: 0.125)
    )
}
