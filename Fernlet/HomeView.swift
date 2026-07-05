import ProximityKit
import HealthKit
import LocalPersistence
import FernletFoundation
import SwiftUI
import FernletScoring
import PrivateHealthStore
import PeriodContextBridge
import HealthKitGateway

#if canImport(UIKit)
import UIKit
import FernletDomainModel
#endif

struct HomeView: View {
    var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    @Binding var selectedTab: FernletTab
    @Binding var privateHubSection: PrivateHubSection
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    /// Shared period store + abstract bridge, threaded from ContentView for the (opt-in) cycle surfaces.
    var periodStore: PeriodTrackerStore? = nil
    var periodContext: PeriodContextBridge? = nil
    /// Shared body-signals service, threaded from ContentView for the (opt-in) stress surfaces.
    var stressService: StressService? = nil
    @State private var hasRecentPeriodEvent = false
    @State private var isCompanionThoughtVisible = true
    @State private var companionTapThought: String?
    @State private var isCompanionSheetPresented = false
    @State private var companionPetCount = 0
    @State private var companionTapCount = 0
    @State private var isCompanionJumping = false
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
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
            .background(Color.parchment)
            .navigationTitle("")
        }
        .sheet(isPresented: $isCompanionSheetPresented) {
            CompanionCustomizationSheet(
                store: store,
                petCount: $companionPetCount
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
        }
        .task {
            await refreshRecentPeriodActivity()
            try? await Task.sleep(for: .seconds(6))
            withAnimation(.easeInOut(duration: 0.35)) {
                isCompanionThoughtVisible = false
            }
        }
        .onChange(of: activeSheet?.id) { _, new in
            if new == nil { Task { await refreshRecentPeriodActivity() } }
        }
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
        case .ambient:
            AmbientCardsView(
                store: store,
                activeSheet: $activeSheet,
                periodPrediction: homePeriodPrediction,
                stressState: store.settings.stressAwarenessEnabled ? stressService?.assessment?.state : nil
            )
        case .logFood, .recipeBook, .newRecipe, .workout, .journal, .sleep, .water, .trends:
            HomeActionWidget(widget: widget) {
                handleHomeWidget(widget)
            }
        }
    }

    private var homeHeader: some View {
        HStack(alignment: .top) {
            ScreenHeader(title: "Fernlet", subtitle: FernletDate.niceDate().uppercased(), subtitleFirst: true, identifier: "screen.home")
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
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                let tiles = photowallTiles
                let horizontalInset: CGFloat = 46
                let finalIndex = max(tiles.count - 1, 1)

                ZStack {
                    ForEach(Array(tiles.enumerated()), id: \.element.id) { index, tile in
                        PolaroidTile(
                            color: tile.color,
                            caption: tile.caption,
                            rotation: tile.rotation,
                            imageData: tile.photoID.flatMap { store.meshNetworkManager.thumbnailData(forPhotoID: $0) },
                            imageWidth: 104,
                            imageHeight: 92
                        )
                        .position(
                            x: horizontalInset
                                + (geometry.size.width - horizontalInset * 2)
                                * CGFloat(index) / CGFloat(finalIndex),
                            y: geometry.size.height / 2
                        )
                        .zIndex(Double(index))
                    }
                }
            }

            ThoughtBubble(text: companionTapThought ?? ambientThought)
                .padding(.bottom, 8)
                .opacity(isCompanionThoughtVisible ? 1 : 0)
                .zIndex(100)
        }
        .frame(height: 132, alignment: .bottom)
        .padding(.top, 4)
        .padding(.bottom, -8)
        .allowsHitTesting(false)
    }

    private var photowallTiles: [PhotowallTile] {
        let seeds = store.photowallSeeds
        guard seeds.count == 4 else {
            return [
                PhotowallTile(caption: "park walk", rotation: -3, color: .fern.opacity(0.45), photoID: nil),
                PhotowallTile(caption: "dinner",    rotation:  2, color: .goldenrod.opacity(0.45), photoID: nil),
                PhotowallTile(caption: "morning",   rotation: -1, color: .slate.opacity(0.32), photoID: nil),
                PhotowallTile(caption: "music",     rotation:  3, color: .dustyRose.opacity(0.38), photoID: nil),
            ]
        }
        let palette: [Color] = [.fern.opacity(0.45), .goldenrod.opacity(0.45), .slate.opacity(0.32), .dustyRose.opacity(0.38)]
        return seeds.map { seed in
            PhotowallTile(
                caption: seed.caption,
                rotation: seed.rotation,
                color: palette[seed.colorIndex % palette.count],
                photoID: seed.photoID
            )
        }
    }

    private var companionSection: some View {
        VStack(spacing: 10) {
            CompanionView(
                state: store.companionState,
                appearance: store.settings.companionAppearance,
                size: 132,
                interactionLevel: companionPetCount,
                equippedItems: store.equippedCustomItems,
                stressTint: stressTintActive
            )
            .contentShape(Rectangle())
            .onTapGesture {
                interactWithCompanion()
            }
            .onLongPressGesture(minimumDuration: 0.45) {
                isCompanionSheetPresented = true
            }
            .accessibilityLabel("Fernlet companion")
            .accessibilityHint("Tap to interact. Press and hold to edit.")

            HStack(spacing: 8) {
                Text(store.companionState.rawValue)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(store.companionState.color)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(store.companionState.color.opacity(0.13), in: Capsule())

                firstAidPill
            }

            signalsCard

            stressLineView
        }
        .frame(maxWidth: .infinity)
    }

    /// Small persistent First Aid affordance beside the companion state chip (quick-log-chip
    /// styling): always reachable, quietly present, never demanding attention.
    private var firstAidPill: some View {
        Button {
            activeSheet = .firstAid(nil)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "heart.circle")
                    .font(.caption.weight(.semibold))
                Text("First aid")
                    .font(.caption.weight(.semibold))
            }
            .foregroundStyle(Color.moss)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .background(Color.moss.opacity(0.13), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("home.firstAid")
        .accessibilityHint("Opens calm tools: breathing, grounding, and the worry box")
    }

    /// Gentle opt-in body-signals line under the companion — offered, never alarming.
    /// Tapping opens the small explainer sheet, which also links on to First Aid.
    @ViewBuilder
    private var stressLineView: some View {
        if let line = stressLine {
            Button {
                activeSheet = .stressExplainer
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wind")
                        .font(.caption.weight(.semibold))
                    Text(line)
                        .font(.caption)
                        .multilineTextAlignment(.leading)
                        .fernletWrappingText()
                }
                .foregroundStyle(Color.slate)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.slate.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("home.stressLine")
            .accessibilityHint("Opens how Fernlet estimates this")
        }
    }

    /// The body-signals copy — shown only when opted in and the reading is at least "tense".
    /// Calm/okay days keep Home quiet (a soft positive lives in the explainer instead).
    private var stressLine: String? {
        guard store.settings.stressAwarenessEnabled,
              let assessment = stressService?.assessment else { return nil }
        switch (assessment.state, assessment.annotation) {
        case (.tense, .workedOut):
            return "Your body is working a bit harder than your usual — probably that good kind of tired from moving."
        case (.tense, .possiblyUnwell):
            return "Your body seems a bit more tense than your usual — it might just be fighting something off. Rest counts."
        case (.tense, nil):
            return "Your body seems a bit more tense than your usual — be extra kind to yourself today."
        case (.needsCare, _):
            return "Your body has seemed extra tense for a couple of days. Going gently today is more than enough."
        default:
            return nil
        }
    }

    /// Presentation-only frazzle flag for the companion. Never overrides the sick/resting
    /// postures (their own care states win), and only ever appears when the user opted in.
    private var stressTintActive: Bool {
        guard store.settings.stressAwarenessEnabled,
              let state = stressService?.assessment?.state,
              state == .tense || state == .needsCare else { return false }
        return store.companionState != .sick && store.companionState != .resting
    }

    /// A compact mood/energy/readiness chip row (plus a "resting today" sickness chip) that taps
    /// through to the Trends modal. Reads the already-built derived signals.
    @ViewBuilder
    private var signalsCard: some View {
        let chips = signalChips(from: store.derivedSignals)
        let resting = store.isSick(on: store.todayKey)
        let phaseChip = periodPhaseChip
        if !chips.isEmpty || resting || phaseChip != nil {
            Button {
                activeSheet = .trends
            } label: {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        if resting {
                            signalChip(text: "Resting today", color: .terracotta, icon: "thermometer.medium")
                        }
                        if let phaseChip {
                            signalChip(text: phaseChip.label, color: phaseChip.color, icon: phaseChip.icon)
                        }
                        ForEach(chips) { chip in
                            signalChip(text: chip.label, color: chip.color, icon: chip.icon)
                        }
                    }
                    .padding(.horizontal, 2)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Wellbeing signals")
            .accessibilityHint("Opens trends")
        }
    }

    /// Abstract cycle-phase chip, shown only when the user has opted into period-aware care and isn't
    /// hiding predictions. Reads the bridge's abstract phase (never raw cycle data) so a glance at Home
    /// surfaces the phase without exposing dates or symptoms.
    private var periodPhaseChip: HomeSignalChip? {
        guard store.settings.periodAwareScoringEnabled, !store.settings.hidePredictions,
              let phase = periodContext?.currentPhaseSignal(), phase != .unknown else { return nil }
        return HomeSignalChip(label: "Cycle: \(phase.rawValue.capitalized)", color: .dustyRose, icon: "drop")
    }

    /// The next-period outlook for the Home ambient bubble, gated by the same opt-in + hide-predictions.
    private var homePeriodPrediction: CyclePrediction? {
        guard store.settings.periodAwareScoringEnabled, !store.settings.hidePredictions else { return nil }
        return periodStore?.prediction
    }

    private struct HomeSignalChip: Identifiable {
        let id = UUID()
        let label: String
        let color: Color
        let icon: String
    }

    private func signalChips(from signals: [DerivedSignalRecord]) -> [HomeSignalChip] {
        var chips: [HomeSignalChip] = []
        if let mood = signals.first(where: { $0.signalName == "moodTrend" }) {
            chips.append(HomeSignalChip(label: "Mood: \(compactSignalValue(mood.value))", color: .dustyRose, icon: "heart"))
        }
        if let energy = signals.first(where: { $0.signalName == "energyTrend" }) {
            chips.append(HomeSignalChip(label: "Energy: \(compactSignalValue(energy.value))", color: .goldenrod, icon: "bolt"))
        }
        if let readiness = signals.first(where: { $0.signalName == "intensityReadiness" }) {
            chips.append(HomeSignalChip(label: "Readiness: \(compactSignalValue(readiness.value))", color: .moss, icon: "figure.run"))
        }
        return chips
    }

    private func compactSignalValue(_ value: String) -> String {
        switch value {
        case "needs gentleness": return "gentle"
        case "ready for hard": return "hard"
        case "ready for light": return "light"
        case "ready for moderate": return "moderate"
        case "improving", "rising": return "up"
        default: return value
        }
    }

    private func signalChip(text: String, color: Color, icon: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon).font(.caption2.weight(.semibold))
            Text(text).font(.caption2.weight(.semibold))
        }
        .foregroundStyle(color)
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(color.opacity(0.13), in: Capsule())
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

    private var companionTapThoughts: [String] {
        [
            "Fernlet notices you.",
            "A little check-in counts.",
            "Still here with you.",
            "Small care is still care."
        ]
    }

    private func interactWithCompanion() {
        guard !isCompanionJumping else { return }
        isCompanionJumping = true
        companionTapCount += 1
        let tapID = companionTapCount

        withAnimation(.easeInOut(duration: 0.44)) {
            companionPetCount += 1
        }

        Task {
            try? await Task.sleep(for: .milliseconds(440))
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                withAnimation(.easeInOut(duration: 0.46)) {
                    companionPetCount += 1
                }
            }
            try? await Task.sleep(for: .milliseconds(460))
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                isCompanionJumping = false
            }
        }

        let shouldShowThought = companionTapCount.isMultiple(of: 3)
        companionTapThought = shouldShowThought ? companionTapThoughts[companionTapCount % companionTapThoughts.count] : nil

        withAnimation(.easeInOut(duration: 0.22)) {
            isCompanionThoughtVisible = shouldShowThought
        }

        guard shouldShowThought else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            await MainActor.run {
                guard companionTapCount == tapID else { return }
                withAnimation(.easeInOut(duration: 0.30)) {
                    isCompanionThoughtVisible = false
                }
                companionTapThought = nil
            }
        }
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
                    Button {
                        store.dismissTodayIntent()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 28, height: 28)
                            .background(Color.slate.opacity(0.10), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss today's intent")
                }
            }
        }
    }

    private var shouldShowTodayIntentPrompt: Bool {
        Calendar.current.component(.hour, from: Date()) >= 14
            && hasNoUserLogsToday
            && !store.isTodayIntentDismissed
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
                VStack(spacing: 12) {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                        ForEach(FernletShortcut.visibleQuickLog(store.settings.quickLogItems, allowsIntimacy: store.isIntimateLoggingAllowed)) { item in
                            quickLogTile(item)
                        }
                    }
                    FernletRowDivider()
                    // One-tap mood check-in: a tag-only journal entry, no writing required.
                    QuickMoodRow(store: store)
                }
            }
        }
    }

    @ViewBuilder
    private func quickLogTile(_ item: FernletShortcut) -> some View {
        let button = QuickLogButton(
            title: title(for: item),
            systemImage: item.systemImage,
            active: isActive(item)
        ) {
            handleQuickLog(item)
        }
        if item == .water {
            // One-tap water quick-add: "+1 bottle" without opening the sheet (the tile itself
            // still opens the full water sheet, unchanged).
            button.overlay(alignment: .topTrailing) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        store.addBottle()
                    }
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.body)
                        .foregroundStyle(Color.moss)
                        .background(Color.parchment, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(5)
                .accessibilityLabel("Add a bottle of water")
                .accessibilityIdentifier("home.water.quickAdd")
            }
        } else {
            button
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
        case .logPeriod, .periodTracking, .intimacyTracking, .friends:
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
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient:
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
            activeSheet = .logPeriod(targetDate: nil, editingEntry: nil)
        case .periodTracking:
            privateHubSection = .period
            selectedTab = .personal
        case .intimacyTracking:
            guard store.isIntimateLoggingAllowed else { return }
            privateHubSection = .intimacy
            selectedTab = .personal
        case .friends:
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

private struct CompanionCustomizationSheet: View {
    enum Section: String, CaseIterable, Identifiable {
        case style = "Style"
        case slots = "Customization"

        var id: String { rawValue }
    }

    var store: FernletStore
    @Binding var petCount: Int
    @Environment(\.dismiss) private var dismiss
    @State private var section: Section = .style

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                companionPreview

                ScrollView {
                    VStack(spacing: 16) {
                        walletBadge
                        milestonesLink
                        wardrobeLink
                        switch section {
                        case .style:
                            styleControls
                        case .slots:
                            slotControls
                        }
                    }
                    .padding(20)
                }
            }
            .background(Color.parchment)
            .navigationTitle("Fernlet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Color.moss)
                }
            }
        }
    }

    private var companionPreview: some View {
        VStack(spacing: 14) {
            CompanionView(
                state: store.companionState,
                appearance: store.settings.companionAppearance,
                size: 150,
                interactionLevel: petCount,
                equippedItems: store.equippedCustomItems
            )
            .frame(maxWidth: .infinity)

            Picker("Companion options", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 16)
        .background(Color.parchment)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.bark.opacity(0.08))
                .frame(height: 1)
        }
    }

    private var walletBadge: some View {
        // Read `store.coinBalance` directly (not a snapshot): it is a cheap derived read over the
        // warm-cached day history, so it stays correct from the first frame and refreshes with the
        // observable store instead of going stale or flashing 0 → N on appear.
        let balance = store.coinBalance
        return HStack(spacing: 12) {
            Image(systemName: "circlebadge.2.fill")
                .font(.system(size: 18))
                .foregroundStyle(Color.sun)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(balance) coins")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .contentTransition(.numericText())
                Text("earned from days you showed up")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.cream)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(balance) coins, earned from days you showed up")
    }

    /// Entry to the Milestones sheet, placed right under the coin balance — milestone gifts are
    /// where coins and lifetime counts meet, so this is where people will look for them.
    private var milestonesLink: some View {
        NavigationLink {
            MilestonesView(store: store)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "leaf.circle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.fern)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Milestones")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("All the care you've logged, added up over all time")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.bark.opacity(0.4))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cream)
            )
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("companion.milestones")
    }

    private var wardrobeLink: some View {
        NavigationLink {
            WardrobeView(store: store)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "tshirt.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(Color.moss)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Custom items & wardrobe")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("Design your own clothes in the grid editor")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.bark.opacity(0.4))
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.cream)
            )
        }
        .buttonStyle(.plain)
    }

    private var styleControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            CompanionCustomizationCard(
                title: "Blob",
                items: CompanionBodyStyle.allCases,
                selection: appearanceBinding(\.bodyStyle),
                colorTitle: "Body color",
                colorSelection: colorPresetBinding(\.bodyColor, customHex: \.bodyCustomColorHex),
                customColorHex: appearanceBinding(\.bodyCustomColorHex),
                customColor: customColorBinding(\.bodyColor, customHex: \.bodyCustomColorHex),
                state: store.companionState
            ) { style in
                Label(style.label, systemImage: "seal")
            }

            CompanionCustomizationCard(
                title: "Accessory",
                items: CompanionAccessory.allCases,
                selection: appearanceBinding(\.accessory),
                colorTitle: "Accessory color",
                colorSelection: colorPresetBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                customColorHex: appearanceBinding(\.accessoryCustomColorHex),
                customColor: customColorBinding(\.accessoryColor, customHex: \.accessoryCustomColorHex),
                state: store.companionState
            ) { accessory in
                Label(accessory.label, systemImage: accessoryIcon(accessory))
            }
        }
    }

    private var slotControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            CompanionCustomizationCard(
                title: "Clothing",
                items: CompanionClothing.allCases,
                selection: appearanceBinding(\.clothing),
                colorTitle: "Clothing color",
                colorSelection: colorPresetBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                customColorHex: appearanceBinding(\.clothingCustomColorHex),
                customColor: customColorBinding(\.clothingColor, customHex: \.clothingCustomColorHex),
                state: store.companionState
            ) { clothing in
                Label(clothing.label, systemImage: clothingIcon(clothing))
            }

            CompanionCustomizationCard(
                title: "Side item",
                items: CompanionSideItem.allCases,
                selection: appearanceBinding(\.sideItem),
                colorTitle: "Item color",
                colorSelection: colorPresetBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                customColorHex: appearanceBinding(\.sideItemCustomColorHex),
                customColor: customColorBinding(\.sideItemColor, customHex: \.sideItemCustomColorHex),
                state: store.companionState
            ) { item in
                Label(item.label, systemImage: item.systemImage)
            }
        }
    }

    private func appearanceBinding<Value>(_ keyPath: WritableKeyPath<CompanionAppearance, Value>) -> Binding<Value> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: keyPath] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: keyPath] = newValue
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func colorPresetBinding(
        _ presetKeyPath: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
        customHex customKeyPath: WritableKeyPath<CompanionAppearance, String?>
    ) -> Binding<CompanionAssetColor> {
        Binding(
            get: { store.settings.companionAppearance[keyPath: presetKeyPath] },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: presetKeyPath] = newValue
                appearance[keyPath: customKeyPath] = nil
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func customColorBinding(
        _ presetKeyPath: WritableKeyPath<CompanionAppearance, CompanionAssetColor>,
        customHex customKeyPath: WritableKeyPath<CompanionAppearance, String?>
    ) -> Binding<Color> {
        Binding(
            get: {
                let appearance = store.settings.companionAppearance
                if let hex = appearance[keyPath: customKeyPath], let color = Color(fernletHex: hex) {
                    return color
                }
                return appearance[keyPath: presetKeyPath].color(for: store.companionState)
            },
            set: { newValue in
                var appearance = store.settings.companionAppearance
                appearance[keyPath: customKeyPath] = newValue.fernletHexString
                store.setCompanionAppearance(appearance)
            }
        )
    }

    private func accessoryIcon(_ accessory: CompanionAccessory) -> String {
        switch accessory {
        case .none: "circle.slash"
        case .sprout: "leaf"
        case .flower: "camera.macro"
        case .glasses: "eyeglasses"
        }
    }

    private func clothingIcon(_ clothing: CompanionClothing) -> String {
        switch clothing {
        case .none: "circle.slash"
        case .scarf: "wind"
        case .sleepCap: "moon"
        }
    }

    private func colorLabel(_ color: CompanionAssetColor) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(color.color(for: store.companionState))
                .frame(width: 12, height: 12)
            Text(color.label)
        }
    }
}

private extension Color {
    init?(fernletHex: String) {
        guard let uiColor = UIColor(hex: fernletHex) else { return nil }
        self.init(uiColor)
    }

    var fernletHexString: String? {
        #if canImport(UIKit)
        UIColor(self).hexString
        #else
        nil
        #endif
    }
}

private struct CompanionCustomizationCard<Item: Identifiable & Hashable, LabelContent: View>: View {
    var title: String
    var items: [Item]
    @Binding var selection: Item
    var colorTitle: String
    @Binding var colorSelection: CompanionAssetColor
    @Binding var customColorHex: String?
    @Binding var customColor: Color
    var state: CompanionState
    @ViewBuilder var label: (Item) -> LabelContent

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 2)
    private let colorColumns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)

    var body: some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionLabel(title)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(items) { item in
                        Button {
                            selection = item
                        } label: {
                            label(item)
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(selection.id == item.id ? Color.cream : Color.bark)
                                .frame(maxWidth: .infinity, minHeight: 42)
                                .background(
                                    selection.id == item.id ? Color.moss : Color.bark.opacity(0.06),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        SectionLabel(colorTitle)
                        Spacer()
                        ColorPicker("Custom color", selection: $customColor, supportsOpacity: false)
                            .labelsHidden()
                    }

                    LazyVGrid(columns: colorColumns, spacing: 6) {
                        ForEach(CompanionAssetColor.allCases) { color in
                            colorButton(for: color)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func colorButton(for color: CompanionAssetColor) -> some View {
        let isSelected = customColorHex == nil && colorSelection == color
        Button {
            colorSelection = color
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(color.color(for: state))
                    .frame(width: 11, height: 11)
                Text(color.label)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
            .foregroundStyle(isSelected ? Color.cream : Color.bark)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(
                isSelected ? Color.moss : Color.bark.opacity(0.05),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .buttonStyle(.plain)
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
        case .companion, .todaySummary, .todayIntent, .quickLog, .macros, .ambient: ""
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
    let caption: String
    let rotation: Double
    let color: Color
    let photoID: UUID?

    var id: String {
        photoID?.uuidString ?? caption
    }
}

// MARK: - Styling
