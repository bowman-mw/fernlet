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

import SwiftUI
import FernletDomainModel
import StoreCore

struct MilestonesView: View {
    var store: FernletStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Every bit of care you've logged, added up over all time. These numbers only ever grow — nothing here resets, expires, or asks you to keep a streak.")
                    .font(.callout)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                VStack(spacing: 10) {
                    ForEach(MilestoneRowModel.rows(counts: store.milestoneCounts), id: \.kind) { row in
                        milestoneRow(row)
                    }
                }

                if totalMilestoneCoins > 0 {
                    HStack(spacing: 10) {
                        Image(systemName: "circlebadge.2.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(Color.sun)
                        Text("Milestone gifts have added \(totalMilestoneCoins) coins to your pouch.")
                            .font(.footnote)
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                } else {
                    Text("Each milestone quietly adds a few coins to your pouch.")
                        .font(.footnote.italic())
                        .foregroundStyle(Color.slate)
                }
            }
            .padding(20)
        }
        .background(Color.parchment)
        .navigationTitle("Milestones")
        .navigationBarTitleDisplayMode(.inline)
    }

    /// Coins gifted by milestone awards so far: the deduped `milestone:` earn rows. Reads the same
    /// in-memory ledger the balance uses, so it can never disagree with the wallet.
    private var totalMilestoneCoins: Int {
        CoinEconomy.deduplicatedByID(store.coinLedgerService.entries)
            .filter { $0.kind == .earn && $0.id.hasPrefix("milestone:") }
            .reduce(0) { $0 + max(0, $1.amount) }
    }

    private func milestoneRow(_ row: MilestoneRowModel) -> some View {
        HStack(spacing: 12) {
            Image(systemName: row.icon)
                .font(.headline.weight(.semibold))
                .foregroundStyle(row.tint)
                .frame(width: 38, height: 38)
                .background(row.tint.opacity(0.14), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(row.headline)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                if row.reachedCount > 0 {
                    Text(row.reachedCount == 1 ? "1 milestone gift" : "\(row.reachedCount) milestone gifts")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// Warm display copy per milestone kind. Kept as a tiny model so the row order and phrasing live
/// in one place (and copy stays count-aware without pluralization bugs).
struct MilestoneRowModel {
    let kind: MilestoneEventKind
    let icon: String
    let tint: Color
    let headline: String
    let reachedCount: Int

    static func rows(counts: [MilestoneEventKind: Int]) -> [MilestoneRowModel] {
        let order: [(MilestoneEventKind, String, Color)] = [
            (.journal, "book.closed", .moss),
            (.meal, "fork.knife", .goldenrod),
            (.workout, "figure.walk", .fern),
            (.water, "drop", .slate),
            (.breathing, "wind", .moss),
            (.worry, "archivebox", .goldenrod)
        ]
        return order.map { kind, icon, tint in
            let count = counts[kind] ?? 0
            return MilestoneRowModel(
                kind: kind,
                icon: icon,
                tint: tint,
                headline: headline(kind: kind, count: count),
                reachedCount: MilestoneEconomy.thresholds.filter { $0 <= count }.count
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
