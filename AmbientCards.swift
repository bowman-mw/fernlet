import SwiftUI

/// Gentle, low-cost "ambient" home surfaces (spec §12): a looking-back journal card, a macro-gap
/// meal nudge, forgotten-favorite meal chips, a forgotten-good workout nudge, and a dismissible
/// preventive-care micronutrient bubble. Each renders only when it has something worth surfacing,
/// so the section quietly disappears on a sparse day rather than nagging.
struct AmbientCardsView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    /// Calendar-math next-period outlook, already gated by the caller for opt-in + hide-predictions.
    /// Nil when there is nothing to show (locked, too few cycles, or surfacing turned off).
    var periodPrediction: CyclePrediction? = nil

    @State private var didLoad = false
    @State private var lookBack: LookBack?
    @State private var forgottenFavorites: [String] = []
    @State private var forgottenWorkout: String?
    @State private var weatherPrompt: String?

    struct LookBack: Equatable { let label: String; let text: String }

    var body: some View {
        VStack(spacing: 12) {
            lookingBackCard
            macroGapCard
            forgottenFavoritesCard
            forgottenWorkoutCard
            weatherCard
            periodPredictionBubble
            micronutrientBubble
        }
        .task {
            // History reads (decryption, full-day scan) are done once, off the per-render path.
            guard !didLoad else { return }
            didLoad = true
            lookBack = computeLookBack()
            forgottenFavorites = computeForgottenFavorites()
            forgottenWorkout = computeForgottenWorkout()
            if store.settings.weatherPromptsEnabled {
                weatherPrompt = await WeatherKitService.shared.moodRecoveryPrompt()
            }
        }
    }

    // MARK: - Looking back

    @ViewBuilder
    private var lookingBackCard: some View {
        if let lookBack {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.goldenrod).frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(lookBack.label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.goldenrod)
                        Text(lookBack.text)
                            .font(.callout)
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                            .lineLimit(4)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func computeLookBack() -> LookBack? {
        let windows: [(Int, String)] = [(365, "A year ago today"), (180, "Six months ago"), (90, "Three months ago")]
        for (days, label) in windows {
            guard let date = Calendar.current.date(byAdding: .day, value: -days, to: Date()) else { continue }
            let day = store.loadDayWithDecryptedJournals(for: FernletDate.dayKey(for: date))
            if let entry = day.journals.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                return LookBack(label: label, text: entry.text)
            }
        }
        return nil
    }

    // MARK: - Macro gap

    @ViewBuilder
    private var macroGapCard: some View {
        if let gap = macroGapSuggestion() {
            Button { activeSheet = .meal } label: {
                FernletCard {
                    HStack(spacing: 12) {
                        ambientIcon("fork.knife", tint: .fern)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Room for a little more")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.bark)
                            Text(gap)
                                .font(.callout)
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func macroGapSuggestion() -> String? {
        guard !store.day.meals.isEmpty else { return nil }
        let proteinGap = store.nutritionTargets.protein - store.macroTotals.protein
        guard proteinGap >= 20 else { return nil }
        return "About \(proteinGap)g protein left today — yogurt, eggs, or chicken would help close it."
    }

    // MARK: - Forgotten favorites (food)

    @ViewBuilder
    private var forgottenFavoritesCard: some View {
        if !forgottenFavorites.isEmpty {
            FernletCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Haven't had these in a while")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    FlowLayout(spacing: 8) {
                        ForEach(forgottenFavorites, id: \.self) { name in
                            Button {
                                store.addMeal(from: name, date: store.todayKey)
                                forgottenFavorites.removeAll { $0 == name }
                            } label: {
                                Text(name)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.bark)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(Color.goldenrod.opacity(0.16), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }

    private func computeForgottenFavorites() -> [String] {
        let meals = store.recentMeals
        guard meals.count >= 5 else { return [] }
        let recentNames = Set(meals.prefix(7).map { $0.name.lowercased() })
        let counts = Dictionary(grouping: meals, by: { $0.name }).mapValues(\.count)
        return counts
            .filter { $0.value >= 2 && !recentNames.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .prefix(3)
            .map(\.key)
    }

    // MARK: - Forgotten-good workout

    @ViewBuilder
    private var forgottenWorkoutCard: some View {
        if let name = forgottenWorkout {
            Button { activeSheet = .workout } label: {
                FernletCard {
                    HStack(spacing: 12) {
                        ambientIcon("figure.run", tint: .moss)
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remember this one?")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.bark)
                            Text("You did \u{201C}\(name)\u{201D} before — it might feel good again.")
                                .font(.callout)
                                .foregroundStyle(Color.slate)
                                .fernletWrappingText()
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func computeForgottenWorkout() -> String? {
        let days = store.loadDays()
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) else { return nil }
        let cutoffKey = FernletDate.dayKey(for: cutoff)
        var counts: [String: Int] = [:]
        var recent: Set<String> = []
        for (key, day) in days {
            for workout in day.workouts {
                let name = workout.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                counts[name, default: 0] += 1
                if key >= cutoffKey { recent.insert(name.lowercased()) }
            }
        }
        return counts
            .filter { $0.value >= 2 && !recent.contains($0.key.lowercased()) }
            .sorted { $0.value > $1.value }
            .first?.key
    }

    // MARK: - Weather-aware recovery

    @ViewBuilder
    private var weatherCard: some View {
        if let weatherPrompt {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    ambientIcon("cloud.rain", tint: .slate)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A gentler day")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                        Text(weatherPrompt)
                            .font(.callout)
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Period outlook

    @ViewBuilder
    private var periodPredictionBubble: some View {
        if let prediction = periodPrediction {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    ambientIcon("calendar", tint: .dustyRose)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Cycle outlook")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.dustyRose)
                        Text(periodOutlookText(prediction))
                            .font(.callout)
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private func periodOutlookText(_ prediction: CyclePrediction) -> String {
        let start = FernletDate.shortDate(for: prediction.likelyStartRange.lowerBound)
        let end = FernletDate.shortDate(for: prediction.likelyStartRange.upperBound)
        let window = start == end ? start : "\(start)–\(end)"
        let qualifier: String
        if prediction.confidence >= 0.7 { qualifier = "" }
        else if prediction.confidence >= 0.4 { qualifier = ", still settling" }
        else { qualifier = ", an early estimate" }
        return "Your next period is likely around \(window)\(qualifier). Gentle planning, no pressure."
    }

    // MARK: - Preventive-care micronutrient bubble

    @ViewBuilder
    private var micronutrientBubble: some View {
        if let gap = activeNutrientGap() {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    ambientIcon("leaf", tint: .fern)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("A gentle nudge")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.fern)
                        Text("\(gap.nutrientName) has been a little low lately. No pressure — a bit more when it's easy.")
                            .font(.callout)
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    Spacer(minLength: 0)
                    Button {
                        store.dismissNutrientBubble(gap.nutrientKey)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 28, height: 28)
                            .background(Color.slate.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss nutrient nudge")
                }
            }
        }
    }

    private func activeNutrientGap() -> NutrientGap? {
        store.derivedSignals
            .flatMap(\.nutrientGaps)
            .filter { $0.status == .gap && $0.windowDays >= 7 && $0.dataCoverageRatio >= 0.5 }
            .first { store.isNutrientBubbleActive(for: $0.nutrientKey) }
    }

    // MARK: - Shared

    private func ambientIcon(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.headline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(width: 34, height: 34)
            .background(tint.opacity(0.14), in: Circle())
    }
}
