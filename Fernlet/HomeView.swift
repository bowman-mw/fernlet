import HealthKit
import SwiftUI

struct HomeView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var selectedTab: FernletTab
    @Binding var privateHubSection: PrivateHubSection
    @Binding var socialHubSection: SocialHubSection
    @State private var hasRecentPeriodEvent = false
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    homeHeader
                    photowallStrip
                    ForEach(store.settings.homeWidgets) { widget in
                        homeWidget(widget)
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("")
        }
        .task { await refreshRecentPeriodActivity() }
    }

    @ViewBuilder
    private func homeWidget(_ widget: HomeWidget) -> some View {
        switch widget {
        case .companion:
            companionSection
        case .todaySummary:
            todayCard
        case .todayIntent:
            todayIntentPrompt
        case .quickLog:
            quickLog
        case .macros:
            MacroCard(totals: store.macroTotals, targets: store.nutritionTargets, showCalories: store.settings.showCalories)
        case .hygiene:
            HygieneCard(store: store, activeSheet: $activeSheet)
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .trends:
            HomeActionWidget(widget: widget) {
                handleHomeWidget(widget)
            }
        }
    }

    private var homeHeader: some View {
        HStack(alignment: .top) {
            ScreenHeader(title: "Fernlet", subtitle: FernletDate.niceDate().uppercased(), subtitleFirst: true)
            Spacer()
            Button { activeSheet = .settings } label: {
                Image(systemName: "gearshape")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .frame(width: 44, height: 44)
                    .background(Color.bark.opacity(0.06), in: Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("home.settings")
        }
    }

    private var photowallStrip: some View {
        HStack(spacing: -8) {
            ForEach(photowallTiles) { tile in
                PolaroidTile(color: tile.color, caption: tile.caption, rotation: tile.rotation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .opacity(0.58)
        .padding(.top, -4)
        .padding(.bottom, -8)
        .allowsHitTesting(false)
    }

    private var photowallTiles: [PhotowallTile] {
        let seeds = store.photowallSeeds
        guard seeds.count == 4 else {
            return [
                PhotowallTile(caption: "park walk", rotation: -3, color: .fern.opacity(0.45)),
                PhotowallTile(caption: "dinner",    rotation:  2, color: .goldenrod.opacity(0.45)),
                PhotowallTile(caption: "morning",   rotation: -1, color: .slate.opacity(0.32)),
                PhotowallTile(caption: "music",     rotation:  3, color: .dustyRose.opacity(0.38)),
            ]
        }
        let palette: [Color] = [.fern.opacity(0.45), .goldenrod.opacity(0.45), .slate.opacity(0.32), .dustyRose.opacity(0.38)]
        return seeds.map { seed in
            PhotowallTile(caption: seed.caption, rotation: seed.rotation, color: palette[seed.colorIndex % palette.count])
        }
    }

    private var companionSection: some View {
        VStack(spacing: 10) {
            ThoughtBubble(text: ambientThought)
            CompanionView(state: store.companionState, size: 132)
            Text(store.companionState.rawValue)
                .font(.caption.weight(.semibold))
                .foregroundStyle(store.companionState.color)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(store.companionState.color.opacity(0.13), in: Capsule())
        }
        .frame(maxWidth: .infinity)
    }

    private var ambientThought: String {
        if let last = store.day.journals.last {
            return "You marked today as \(last.tag.label.lowercased()). Let that be enough information for now."
        }
        if let thought = store.companionThought {
            return thought
        }
        if let thought = signalThought {
            return thought
        }
        if store.day.meals.isEmpty && store.day.workouts.isEmpty {
            return "Start with one small thing. Enough, not everything."
        }
        return "A few ordinary care notes are already here. Keep the day simple."
    }

    private var signalThought: String? {
        let signals = store.derivedSignals
        if let energy = signals.first(where: { $0.signalName == "energyTrend" }) {
            if energy.value == "low" { return "Energy has been low lately. Rest counts as care." }
            if energy.value == "rising" { return "Something has been building. Notice the upward pull." }
        }
        if let mood = signals.first(where: { $0.signalName == "moodTrend" }) {
            if mood.value == "needs gentleness" { return "Some harder days in the window. Notice what is still steady." }
            if mood.value == "improving" { return "The mood trend has been moving upward. Quiet progress." }
        }
        if let readiness = signals.first(where: { $0.signalName == "intensityReadiness" }) {
            if readiness.value == "ready for hard" { return "The signals suggest room to push today if you want to." }
            if readiness.value == "ready for light" { return "Today looks like a day to move gently and restore." }
        }
        if let eating = signals.first(where: { $0.signalName == "eatingPattern" }) {
            if eating.value == "light" { return "Nutrition has been lighter lately. One nourishing meal is enough." }
        }
        return nil
    }

    private var todayCard: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Today")
                        .font(.title3.weight(.semibold))
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(FernletDate.niceDate().components(separatedBy: ",").first ?? "Today")
                            .font(.caption)
                        Text(store.settings.selectedGoal.displayName)
                            .font(.caption2.weight(.semibold))
                    }
                    .foregroundStyle(Color.slate)
                }
                HealthBar(state: store.companionState, value: store.score)
            }
        }
    }

    @ViewBuilder
    private var todayIntentPrompt: some View {
        if shouldShowTodayIntentPrompt {
            FernletCard {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "sun.max")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.goldenrod)
                        .frame(width: 34, height: 34)
                        .background(Color.goldenrod.opacity(0.14), in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Today's intent")
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.bark)
                        Text("One small care note is still a real note.")
                            .font(.callout)
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer()
                }
            }
        }
    }

    private var shouldShowTodayIntentPrompt: Bool {
        Calendar.current.component(.hour, from: Date()) >= 14 && hasNoUserLogsToday
    }

    private var hasNoUserLogsToday: Bool {
        store.day.meals.isEmpty &&
        store.day.workouts.isEmpty &&
        store.day.journals.isEmpty &&
        store.day.sleep == nil &&
        store.day.bottleCount == 0 &&
        store.day.hygiene.isEmpty
    }

    private var quickLog: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Quick log")
            FernletCard {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: store.isIntimateLoggingAllowed)) { item in
                        QuickLogButton(
                            title: title(for: item),
                            systemImage: item.systemImage,
                            active: isActive(item)
                        ) {
                            handleQuickLog(item)
                        }
                    }
                }
            }
        }
    }

    private func title(for item: FernletShortcut) -> String {
        switch item {
        case .meal:
            store.day.meals.isEmpty ? "Meal" : "\(store.day.meals.count) meal"
        case .water:
            store.day.bottleCount == 0 ? "Water" : "\(store.day.bottleCount)x"
        case .move:
            store.day.workouts.isEmpty ? "Move" : "Done"
        case .sleep:
            store.day.sleep == nil ? "Sleep" : "Logged"
        case .journal:
            "Journal"
        case .care:
            "Care"
        case .logPeriod, .periodTracking, .intimacyTracking, .friends, .photos, .hobbyNotes:
            item.title
        }
    }

    private func isActive(_ item: FernletShortcut) -> Bool {
        switch item {
        case .meal:
            !store.day.meals.isEmpty
        case .water:
            store.day.bottleCount > 0
        case .move:
            !store.day.workouts.isEmpty
        case .sleep:
            store.day.sleep != nil
        case .journal:
            !store.day.journals.isEmpty
        case .care:
            store.personalCareProgress().completed > 0
        case .logPeriod:
            hasRecentPeriodEvent
        case .periodTracking:
            store.day.healthContext?.cycle != nil
        case .intimacyTracking:
            store.day.healthContext?.intimate != nil
        case .friends:
            store.memories.contains { $0.category.localizedCaseInsensitiveContains("friend") }
        case .photos:
            false
        case .hobbyNotes:
            store.memories.contains { $0.category.localizedCaseInsensitiveContains("hobby") }
        }
    }

    private func handleHomeWidget(_ widget: HomeWidget) {
        switch widget {
        case .logFood:
            activeSheet = .meal
        case .recipeBook:
            activeSheet = .recipeBook
        case .newRecipe:
            activeSheet = .recipe
        case .workout:
            activeSheet = .workout
        case .journal:
            activeSheet = .journal
        case .sleep:
            activeSheet = .sleep
        case .water:
            activeSheet = .water
        case .hygiene:
            activeSheet = .hygiene
        case .trends:
            activeSheet = .trends
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros:
            break
        }
    }

    private func handleQuickLog(_ item: FernletShortcut) {
        switch item {
        case .meal:
            activeSheet = .meal
        case .water:
            activeSheet = .water
        case .move:
            activeSheet = .quickExercise
        case .sleep:
            activeSheet = .sleep
        case .journal:
            activeSheet = .journal
        case .care:
            activeSheet = .hygiene
        case .logPeriod:
            activeSheet = .logPeriod(targetDate: nil)
        case .periodTracking:
            privateHubSection = .period
            selectedTab = .personal
        case .intimacyTracking:
            guard store.isIntimateLoggingAllowed else { return }
            privateHubSection = .intimacy
            selectedTab = .personal
        case .friends:
            socialHubSection = .friends
            selectedTab = .social
        case .photos:
            // TODO: Route to a dedicated photos section if the social hub grows one.
            socialHubSection = .hobbies
            selectedTab = .social
        case .hobbyNotes:
            socialHubSection = .hobbies
            selectedTab = .social
        }
    }

    private func refreshRecentPeriodActivity() async {
        let service = HealthKitService()
        let start = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)
        let range = DateInterval(start: start, end: Date())
        hasRecentPeriodEvent = ((try? await service.loadPeriodEvents(in: range)) ?? []).contains { sample in
            (sample as? HKCategorySample)?.categoryType.identifier == HKCategoryTypeIdentifier.menstrualFlow.rawValue
        }
    }
}

struct SignalDetailRow: View {
    var signal: DerivedSignalRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: SignalPresentation.icon(for: signal.signalName))
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(SignalPresentation.color(for: signal.value))
                    .frame(width: 34, height: 34)
                    .background(SignalPresentation.color(for: signal.value).opacity(0.12), in: Circle())

                VStack(alignment: .leading, spacing: 4) {
                    Text(SignalPresentation.title(for: signal.signalName))
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text(signal.value.capitalized)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(SignalPresentation.color(for: signal.value))
                    Text(SignalPresentation.explanation(for: signal))
                        .font(.caption)
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer()
            }

            SignalTrendMeter(value: signal.value)

            FlowLayout(spacing: 6) {
                ForEach(signal.sourceFields, id: \.self) { field in
                    Text(field)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.slate)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(Color.bark.opacity(0.05), in: Capsule())
                }
            }

            if signal.nutrientGaps.isEmpty == false {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(signal.nutrientGaps.prefix(4)) { gap in
                        HStack {
                            Text(gap.nutrientName)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Color.bark)
                            Spacer()
                            Text(gap.status == .gap ? "gap" : "covered")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(gap.status == .gap ? Color.terracotta : Color.moss)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.bark.opacity(0.08), lineWidth: 1))
    }
}

struct SignalTrendMeter: View {
    var value: String

    private var fillCount: Int {
        SignalPresentation.strength(for: value)
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(index < fillCount ? SignalPresentation.color(for: value) : Color.bark.opacity(0.10))
                    .frame(height: 7)
            }
        }
    }
}

enum SignalPresentation {
    static func title(for name: String) -> String {
        switch name {
        case "moodTrend": "Mood trend"
        case "energyTrend": "Energy trend"
        case "eatingPattern": "Eating pattern"
        case "progressionTrend": "Progression"
        case "intensityReadiness": "Readiness"
        case "micronutrientGaps7Day": "7-day nutrients"
        case "micronutrientGaps14Day": "14-day nutrients"
        default: name
        }
    }

    static func icon(for name: String) -> String {
        switch name {
        case "moodTrend": "face.smiling"
        case "energyTrend": "bolt"
        case "eatingPattern": "fork.knife"
        case "progressionTrend": "chart.line.uptrend.xyaxis"
        case "intensityReadiness": "gauge.with.dots.needle.67percent"
        default: "leaf"
        }
    }

    static func color(for value: String) -> Color {
        let lower = value.lowercased()
        if lower.contains("low") || lower.contains("light") || lower.contains("declining") || lower.contains("dipping") || lower.contains("gap") || lower.contains("gentleness") {
            return .terracotta
        }
        if lower.contains("building") || lower.contains("improving") || lower.contains("rising") || lower.contains("hard") || lower.contains("covered") || lower.contains("protein") {
            return .moss
        }
        return .slate
    }

    static func strength(for value: String) -> Int {
        let lower = value.lowercased()
        if lower.contains("insufficient") { return 1 }
        if lower.contains("low") || lower.contains("light") || lower.contains("gentleness") { return 2 }
        if lower.contains("steady") || lower.contains("consistent") || lower.contains("moderate") { return 3 }
        if lower.contains("building") || lower.contains("improving") || lower.contains("rising") || lower.contains("hard") || lower.contains("protein") { return 5 }
        return 3
    }

    static func explanation(for signal: DerivedSignalRecord) -> String {
        switch signal.signalName {
        case "moodTrend":
            return "Compares recent journal tags against earlier tags in the rolling window."
        case "energyTrend":
            return "Combines sleep, journal tags, and recent workout load."
        case "eatingPattern":
            return "Looks at meal frequency, recent missed meal days, and protein totals."
        case "progressionTrend":
            return "Compares newer workout load against earlier workout load."
        case "intensityReadiness":
            return "Blends recent energy, training load, hard sessions, and meal coverage."
        default:
            if signal.nutrientGaps.isEmpty {
                return "Micronutrient coverage needs more meal data."
            }
            return "Tracks covered nutrients and possible gaps from logged meal snapshots."
        }
    }
}

struct CompactSignalRow: View {
    var signal: DerivedSignalRecord

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: SignalPresentation.icon(for: signal.signalName))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(SignalPresentation.color(for: signal.value))
                .frame(width: 30, height: 30)
                .background(SignalPresentation.color(for: signal.value).opacity(0.10), in: Circle())

            Text(SignalPresentation.title(for: signal.signalName))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.bark)

            Spacer()

            Text(signal.value.capitalized)
                .font(.caption.weight(.semibold))
                .foregroundStyle(SignalPresentation.color(for: signal.value))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(SignalPresentation.color(for: signal.value).opacity(0.10), in: Capsule())
        }
    }
}

struct TrendsModal: View {
    @Environment(\.dismiss) private var dismiss
    var signals: [DerivedSignalRecord]

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ScreenHeader(
                        title: "Trends",
                        subtitle: "Local signals from your logs. Prototype only — not production-private.",
                        subtitleFirst: false
                    )
                    if signals.isEmpty {
                        FernletCard { EmptyState(text: "More logs will make trends useful.") }
                    } else {
                        ForEach(signals) { signal in
                            SignalDetailRow(signal: signal)
                        }
                    }
                }
                .padding(20)
                .padding(.bottom, 80)
            }
            doneBar
        }
        .background(Color.parchment)
    }

    private var doneBar: some View {
        HStack {
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(.plain)
                .font(.headline)
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 16))
            Spacer()
        }
        .padding(20)
        .background(Color.parchment)
    }
}

struct FernletCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .bark.opacity(0.08), radius: 12, x: 0, y: 5)
    }
}

struct SectionLabel: View {
    private let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text.uppercased())
            .font(.caption2.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(Color.slate)
    }
}

struct CompanionView: View {
    var state: CompanionState
    var size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(state.color)
                .frame(width: size, height: size)
            Circle()
                .fill(.white.opacity(0.16))
                .frame(width: size * 0.34, height: size * 0.24)
                .offset(x: -size * 0.11, y: -size * 0.18)
            HStack(spacing: size * 0.18) {
                EyeView(tired: state == .tired || state == .resting, size: size)
                EyeView(tired: state == .tired || state == .resting, size: size)
            }
            .offset(y: -size * 0.08)
            RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(0.72))
                .frame(width: size * 0.18, height: state == .thriving ? 9 : state == .okay ? 6 : 3)
                .offset(y: size * 0.14)
        }
        .accessibilityLabel("Fernlet companion, \(state.rawValue)")
    }
}

struct EyeView: View {
    var tired: Bool
    var size: CGFloat

    var body: some View {
        ZStack {
            Ellipse()
                .fill(.white.opacity(0.92))
                .frame(width: size * 0.13, height: tired ? size * 0.07 : size * 0.13)
            Circle()
                .fill(Color(red: 0.239, green: 0.180, blue: 0.118))
                .frame(width: size * 0.06, height: size * 0.06)
        }
    }
}

struct ThoughtBubble: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout.italic())
            .foregroundStyle(Color.bark)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 18)
            .padding(.vertical, 14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
            .frame(maxWidth: 290)
    }
}

struct HealthBar: View {
    var state: CompanionState
    var value: Double

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<12, id: \.self) { index in
                RoundedRectangle(cornerRadius: 4)
                    .fill(index < Int((value * 12).rounded()) ? state.color : Color.bark.opacity(0.12))
                    .frame(height: 8)
            }
        }
        .accessibilityLabel("Care score \(Int(value * 100)) percent")
    }
}

struct HomeActionWidget: View {
    var widget: HomeWidget
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            FernletCard {
                HStack(spacing: 12) {
                    Image(systemName: widget.systemImage)
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.moss)
                        .frame(width: 36, height: 36)
                        .background(Color.moss.opacity(0.12), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(widget.title)
                            .font(.headline.weight(.semibold))
                            .foregroundStyle(Color.bark)
                        Text(actionSubtitle)
                            .font(.caption)
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.slate.opacity(0.65))
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var actionSubtitle: String {
        switch widget {
        case .logFood: "Add food to today."
        case .recipeBook: "Open saved recipes."
        case .newRecipe: "Build a recipe."
        case .workout: "Log training or movement."
        case .journal: "Add a short note."
        case .sleep: "Log rest."
        case .water: "Update hydration."
        case .hygiene: "Open care tasks."
        case .trends: "Review local signals."
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros: ""
        }
    }
}

struct QuickLogButton: View {
    var title: String
    var systemImage: String
    var active: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.title3)
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 66)
            .foregroundStyle(active ? Color.moss : Color.slate)
            .background(active ? Color.moss.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

struct MacroCard: View {
    var totals: MacroTotals
    var targets: NutritionTargets
    var showCalories: Bool

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel("Macros today")
                HStack(spacing: 14) {
                    MacroRing(label: "Protein", color: .moss, current: totals.protein, goal: targets.protein)
                    MacroRing(label: "Carbs", color: .goldenrod, current: totals.carbs, goal: targets.carbs)
                    MacroRing(label: "Fat", color: .terracotta, current: totals.fat, goal: targets.fat)
                }
                HStack {
                    if showCalories {
                        Label("\(totals.calories) / \(targets.calories) cal", systemImage: "flame")
                        Spacer()
                    }
                    Label("Fiber \(targets.fiber)g", systemImage: "leaf")
                }
                .font(.caption.weight(.medium))
                .foregroundStyle(Color.slate)
            }
        }
    }
}

struct MacroRing: View {
    var label: String
    var color: Color
    var current: Int
    var goal: Int

    var progress: Double { min(Double(current) / Double(goal), 1) }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle().stroke(Color.bark.opacity(0.1), lineWidth: 8)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(color, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                Text("\(current)g")
                    .font(.caption.weight(.medium))
            }
            .frame(width: 68, height: 68)
            Text(label)
                .font(.caption.weight(.medium))
            Text("of \(goal)g")
                .font(.caption2)
                .foregroundStyle(Color.slate)
        }
        .frame(maxWidth: .infinity)
    }
}

struct HygieneCard: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?

    var body: some View {
        Button { activeSheet = .hygiene } label: {
            FernletCard {
                VStack(alignment: .leading, spacing: 10) {
                    let progress = store.personalCareProgress()
                    HStack {
                        SectionLabel("Hygiene")
                        Spacer()
                        Text("\(progress.completed)/\(progress.total)")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(progress.completed == progress.total ? Color.moss : Color.slate)
                    }
                    HStack(spacing: 3) {
                        ForEach(store.personalCareTasks) { task in
                            RoundedRectangle(cornerRadius: 3)
                                .fill(store.isPersonalCareTaskCompleted(task) ? Color.moss : Color.bark.opacity(0.1))
                                .frame(height: 6)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 6)], spacing: 6) {
                        ForEach(store.personalCareTasks) { task in
                            Button { store.togglePersonalCareTask(task) } label: {
                                Label(task.label, systemImage: task.systemImage)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(1)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 6)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .foregroundStyle(store.isPersonalCareTaskCompleted(task) ? Color.moss : Color.slate)
                                    .background(store.isPersonalCareTaskCompleted(task) ? Color.moss.opacity(0.12) : Color.bark.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

struct EmptyState: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.callout.italic())
            .foregroundStyle(Color.slate)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.vertical, 18)
    }
}

struct FernletScrollSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    init(_ title: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                SectionLabel(title)
                    .padding(.horizontal, 4)
            }
            VStack(alignment: .leading, spacing: 0) {
                content
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .shadow(color: .bark.opacity(0.06), radius: 10, x: 0, y: 4)
        }
    }
}

struct FernletRowDivider: View {
    var body: some View {
        Divider()
            .overlay(Color.bark.opacity(0.08))
            .padding(.vertical, 8)
    }
}

struct PhotowallTile: Identifiable {
    let id = UUID()
    let caption: String
    let rotation: Double
    let color: Color
}

// MARK: - Styling
