import SwiftUI

/// The Today panel the hearts open: Home's cards, in Home's order. The companion card with
/// Customize first, then Today, Macros, Gold hearts, Trends, Milestones, Body signals, the stamp
/// book, Silly stats and First Aid (design page, "Same data, new look").
struct TodayPanel: View {
    let model: WorldShellModel

    var body: some View {
        companionCard
        ShellCard {
            HStack {
                Text("Today").font(.subheadline.weight(.semibold))
                Spacer()
                StateChip(state: model.careState)
            }
            HealthBarView(state: model.careState, value: model.careState.careScore)
            Text(model.careState == .sick ? "Scoring goes gentle until tomorrow." : "Goal · Wellness")
                .font(.caption).foregroundStyle(FernColors.dim)
        }
        MacrosCard(protein: model.protein, carbs: model.carbs, fat: model.fat)
        if model.level.goldHearts > 0 { goldCard }
        ShellCard {
            CardLabel(text: "Trends")
            Text("Eating pattern: steady · Sleep: settling · Movement: gentle").font(.caption).foregroundStyle(FernColors.dim)
        }
        ShellCard {
            LinkRow(title: "Milestones") { model.showToast("Milestones open here, as today.") }
            LinkRow(title: "Body signals") { model.showToast("Body signals open here, as today.") }
        }
        ShellCard {
            HStack {
                Text("Stamp book").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.stampBook.count) of 19").font(.caption).foregroundStyle(FernColors.dim)
            }
            Text(model.stampBook.isEmpty ? "Stamps arrive as your silly stats begin. Try logging a meal." : model.stampBook.joined(separator: " · "))
                .font(.caption).foregroundStyle(FernColors.dim)
        }
        if model.level != .dayOne {
            ShellCard {
                CardLabel(text: "Silly stats")
                Text(model.level == .year ? "You've walked 0.4% of the way to the Moon." : "That's 11 koala days of sleep so far.")
                    .font(.subheadline.weight(.semibold))
            }
        }
        ShellCard { LinkRow(title: "First Aid") { model.showToast("First Aid opens here, as today.") } }
    }

    /// The companion card: the crisp companion, its state, and the second door to Customize.
    private var companionCard: some View {
        ShellCard {
            HStack(spacing: 10) {
                CompanionVectorView(state: model.careState, size: 46)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Fernlet").font(.subheadline.weight(.semibold))
                    Text("\(model.careState.label) · or hold it on the map").font(.caption).foregroundStyle(FernColors.dim)
                }
                Spacer(minLength: 0)
                PillButton(title: "Customize") { model.toggle(.customize) }
            }
        }
    }

    /// Gold hearts from a friend in person: the boost while they last, and the saved day without it.
    private var goldCard: some View {
        let score = model.careState.careScore
        let gold = model.level.goldHearts
        let boosted = Int((min(1, score + Double(gold) / 12) * 100).rounded())
        return ShellCard {
            HStack {
                Text("Gold hearts").font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(gold) from Sam").font(.caption).foregroundStyle(FernColors.dim)
            }
            Text("Care score \(Int((score * 100).rounded())) → \(boosted) until 11:40 pm. Your saved day keeps \(Int((score * 100).rounded())).")
                .font(.caption).foregroundStyle(FernColors.dim)
        }
    }
}

/// The state chip: a dot in the state's colour and its name.
struct StateChip: View {
    let state: ShellCompanionState

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(state.color).frame(width: 8, height: 8)
            Text(state.label).font(.caption.weight(.semibold))
        }
        .padding(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 8))
        .background(state.color.opacity(0.18), in: Capsule())
    }
}

/// The macro card: protein, carbs and fat against targets, and fiber.
struct MacrosCard: View {
    let protein: Int
    let carbs: Int
    let fat: Int

    var body: some View {
        let targets = WorldFixtures.macroTargets
        ShellCard {
            CardLabel(text: "Macros")
            row("Protein", protein, targets.protein, FernColors.terracotta)
            row("Carbs", carbs, targets.carbs, FernColors.goldenrod)
            row("Fat", fat, targets.fat, FernColors.teal)
            Text("Fiber 14 of 30 g").font(.caption).foregroundStyle(FernColors.dim)
        }
    }

    private func row(_ name: String, _ value: Int, _ target: Int, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Text(name).font(.footnote).frame(width: 56, alignment: .leading)
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(FernColors.bark.opacity(0.1))
                    Capsule().fill(color).frame(width: proxy.size.width * min(1, Double(value) / Double(target)))
                }
            }
            .frame(height: 7)
            Text("\(value) of \(target) g").font(.caption).foregroundStyle(FernColors.dim).frame(width: 78, alignment: .trailing)
        }
    }
}
