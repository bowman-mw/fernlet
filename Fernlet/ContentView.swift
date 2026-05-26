//
//  ContentView.swift
//  Fernlet
//
//  Created by Michael Bowman on 5/16/26.
//

import SwiftUI

struct ContentView: View {
    @ObservedObject var store: FernletStore
    @StateObject private var launcher = LaunchPreparationService()
    @StateObject private var periodStore = PeriodTrackerStore()
    @EnvironmentObject private var lockService: FernletLockService
    @EnvironmentObject private var storagePreferencesStore: StoragePreferencesStore
    @AppStorage("fernletDarkModeEnabled") private var isDarkModeEnabled = false
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
    @State private var selectedTab: FernletTab = .home
    @State private var privateHubSection: PrivateHubSection = .journal
    @State private var socialHubSection: SocialHubSection = .workshop
    @State private var activeSheet: FernletSheet?
    @State private var mealLogNotification: MealLogNotification?
    @State private var editingRecipeFromHome: RecipeDefinition?
    @State private var editingSavedRecipeFromHome: SavedRecipe?
    @State private var didAutoImportHealthProfile = false
    @State private var didAutoImportHealthContext = false
    var body: some View {
        launchRoot
            .preferredColorScheme(isDarkModeEnabled ? .dark : .light)
            .sheet(item: $activeSheet) { sheet in
                sheetContent(for: sheet)
            }
            .sheet(item: $editingRecipeFromHome) { recipe in
                RecipeSheet(store: store, recipe: recipe)
                    .presentationDetents([.large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
            .sheet(item: $editingSavedRecipeFromHome) { recipe in
                SavedRecipeNotesSheet(store: store, recipe: recipe)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationCornerRadius(20)
            }
            .sheet(isPresented: $store.showConnectionInspector) {
                ConnectionInspectorView(inspector: store.connectionInspector)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled)
            }
            .onChange(of: lockService.state) { _, newState in
                store.lockState = newState
                Task { await drainPendingPeriodNarrativesIfUnlocked(newState) }
            }
            .overlay(alignment: .top) {
                if let mealLogNotification {
                    MealLogNotificationView(notification: mealLogNotification)
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: mealLogNotification?.id)
            .animation(.easeOut(duration: 0.45), value: launcher.isDone)
            .task {
                periodStore.attachLockService(lockService)
                try? await Task.sleep(for: .milliseconds(120))
                if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_OPEN_SETTINGS"] == "1" {
                    activeSheet = .settings
                }
                async let _ = autoImportHealthProfileIfAvailable()
                async let _ = autoImportHealthContextIfAvailable()
                await launcher.prepare(store: store)
                store.markLaunchScreenDismissed()
                store.deferredPostLaunchTasks()
                store.ensureBundledFoodItemsSeeded()
            }
            .onChange(of: selectedTab) { _, newTab in
                Task { await refreshHealthContextForActiveTab(newTab) }
            }
            .onChange(of: customLightBackgroundHex) { _, _ in }
            .onChange(of: customDarkBackgroundHex) { _, _ in }
    }

    private var launchRoot: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()
            if launcher.isDone {
                mainInterface
                    .transition(.opacity)
            } else {
                LaunchScreen(statusMessage: launcher.statusMessage)
                    .transition(.opacity)
            }
        }
        .background(Color.parchment)
    }

    private var mainInterface: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                store: store,
                activeSheet: $activeSheet,
                selectedTab: $selectedTab,
                privateHubSection: $privateHubSection,
                socialHubSection: $socialHubSection
            )
            .tag(FernletTab.home)
            FoodView(store: store, activeSheet: $activeSheet)
                .tag(FernletTab.food)
            MoveView(store: store, activeSheet: $activeSheet)
                .tag(FernletTab.move)
            SocialHubView(store: store, activeSheet: $activeSheet, section: $socialHubSection)
                .tag(FernletTab.social)
            PrivateHubView(store: store, periodStore: periodStore, activeSheet: $activeSheet, section: $privateHubSection)
                .tag(FernletTab.personal)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .overlay(alignment: .bottom) {
            LinearGradient(
                colors: [Color.parchment.opacity(0), Color.parchment],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 26)
            .allowsHitTesting(false)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            customTabBar
        }
        .tint(Color.moss)
        .background(Color.parchment)
    }

    private var customTabBar: some View {
        HStack(spacing: 0) {
            ForEach(FernletTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    let isSelected = selectedTab == tab
                    VStack(spacing: 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: 20))
                            .frame(height: 24)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(isSelected ? Color.moss : Color(UIColor.secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(
                        isSelected ? Color.parchment : Color.clear,
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .stroke(Color.bark.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.bark.opacity(0.12), radius: 16, x: 0, y: 6)
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
    }

    @ViewBuilder
    private func sheetContent(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .meal:
            MealSheet(store: store, onLogged: showMealLogNotification)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .recipe:
            RecipeSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .water:
            WaterSheet(store: store)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .sleep:
            SleepSheet(store: store)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .journal:
            JournalSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .quickExercise:
            QuickExerciseSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .workout:
            WorkoutSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .workoutSuggestion:
            WorkoutSuggestionSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .goals:
            GoalsSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .hygiene:
            HygieneSheet(store: store)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .texture:
            TextureSheet(store: store)
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .settings:
            SettingsSheet(store: store)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environmentObject(lockService)
                .environmentObject(storagePreferencesStore)
        case .recipeBook:
            RecipeBookSheet(store: store, editingRecipe: $editingRecipeFromHome, editingSavedRecipe: $editingSavedRecipeFromHome)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .trends:
            TrendsModal(signals: store.derivedSignals)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .logPeriod(let targetDate):
            LogPeriodSheet(periodStore: periodStore, targetDate: targetDate)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environmentObject(lockService)
        }
    }

    private func autoImportHealthProfileIfAvailable() async {
        guard !didAutoImportHealthProfile else { return }
        didAutoImportHealthProfile = true

        do {
            let healthProfile = try await HealthKitService(preferencesStore: storagePreferencesStore).loadBodyProfile()
            guard healthProfile.appliedFieldCount > 0 else { return }
            store.settings.userProfile = healthProfile.applying(to: store.settings.userProfile)
        } catch {
            // Health profile import is optional; manual settings remain the fallback.
        }
    }

    private func autoImportHealthContextIfAvailable() async {
        guard !didAutoImportHealthContext else { return }
        didAutoImportHealthContext = true

        do {
            let context = try await HealthKitService(preferencesStore: storagePreferencesStore).loadDailyHealthContext(
                referenceDate: .now,
                capabilities: store.allowedHealthCapabilities(from: Set(HealthCapability.allCases))
            )
            store.updateHealthContext(context)
        } catch {
            // Health context import is optional; manual app entries remain available.
        }
    }

    private func drainPendingPeriodNarrativesIfUnlocked(_ lockState: FernletLockState) async {
        guard case .unlocked = lockState, let contentKey = lockService.contentKey() else { return }
        try? await periodStore.drainPendingBuffer(contentKey: contentKey)
        await periodStore.loadEntries(unlockedContentKey: contentKey)
    }

    private func refreshHealthContextForActiveTab(_ tab: FernletTab) async {
        let capabilities: Set<HealthCapability>
        switch tab {
        case .home:
            capabilities = store.allowedHealthCapabilities(from: Set(HealthCapability.allCases))
        case .move:
            capabilities = [.activityContext, .bodyContext]
        case .food:
            await autoImportHealthProfileIfAvailable()
            capabilities = [.activityContext]
        case .social:
            return
        case .personal:
            capabilities = store.allowedHealthCapabilities(from: [.cycleTracking, .mindfulness, .intimateLogging, .bodyContext])
        }

        do {
            let context = try await HealthKitService(preferencesStore: storagePreferencesStore).loadDailyHealthContext(referenceDate: .now, capabilities: capabilities)
            store.updateHealthContext(context)
        } catch {
            // Health context refresh is opportunistic and should never block tab navigation.
        }
    }

    private func showMealLogNotification(_ meals: [Meal]) {
        guard meals.isEmpty == false else { return }
        let notification = MealLogNotification(meals: meals)
        mealLogNotification = notification
        selectedTab = .home

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            if mealLogNotification?.id == notification.id {
                mealLogNotification = nil
            }
        }
    }
}

struct PersonalScreenView: View {
    var screen: FernletScreen
    @ObservedObject var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(title: screen.title, subtitle: screen.subtitle)
                        Spacer()
                        HeaderActionButton(systemImage: primaryActionIcon) {
                            handlePrimaryAction()
                        }
                    }
                    .padding(.top, 4)

                    FernletScrollSection(todaySectionTitle) {
                        personalScreenBody
                    }
                }
                .padding(20)
            }
            .background(Color.parchment)
            .navigationTitle("")
            .toolbar(isInHub ? .hidden : .visible, for: .navigationBar)
        }
    }

    private var todaySectionTitle: String {
        switch screen {
        case .periodTracking: "Cycle"
        case .intimacyTracking: "Private"
        case .friends: "People"
        case .photos: "Photo wall"
        case .hobbyNotes: "Notes"
        case .food, .move, .journal, .workshop: "Today"
        }
    }

    private var primaryActionIcon: String {
        switch screen {
        case .periodTracking, .intimacyTracking:
            "heart.text.square"
        case .photos:
            "photo.badge.plus"
        case .friends, .hobbyNotes:
            "square.and.pencil"
        case .food, .move, .journal, .workshop:
            "plus"
        }
    }

    @ViewBuilder
    private var personalScreenBody: some View {
        switch screen {
        case .periodTracking:
            VStack(alignment: .leading, spacing: 8) {
                Label(cycleSummary, systemImage: screen.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.bark)
                Text("Use Health access in Settings to keep cycle context available here.")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(.vertical, 8)
        case .intimacyTracking:
            VStack(alignment: .leading, spacing: 8) {
                Label(intimacySummary, systemImage: screen.systemImage)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Color.bark)
                Text("Intimacy access is private, optional, and age-gated.")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(.vertical, 8)
        case .friends:
            PersonalMemoryList(category: "friend", emptyText: "No friend notes yet.", store: store)
        case .photos:
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: -8) {
                    PolaroidTile(color: .fern.opacity(0.45), caption: "today", rotation: -2)
                    PolaroidTile(color: .dustyRose.opacity(0.38), caption: "people", rotation: 2)
                    PolaroidTile(color: .goldenrod.opacity(0.45), caption: "places", rotation: -1)
                }
                Text("Photo imports can live here when the photo picker is added.")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }
            .padding(.vertical, 4)
        case .hobbyNotes:
            PersonalMemoryList(category: "hobby", emptyText: "No hobby notes yet.", store: store)
        case .food, .move, .journal, .workshop:
            EmptyView()
        }
    }

    private var cycleSummary: String {
        "Tap to view your cycle"
    }

    private var intimacySummary: String {
        guard store.isIntimateLoggingAllowed else { return "Available for adults only." }
        guard let count = store.day.healthContext?.intimate?.eventCount else { return "No intimacy context for today." }
        return count == 0 ? "No intimacy events today." : "\(count) private event\(count == 1 ? "" : "s") today"
    }

    private func handlePrimaryAction() {
        switch screen {
        case .periodTracking, .intimacyTracking:
            activeSheet = .settings
        case .friends, .hobbyNotes:
            activeSheet = .journal
        case .photos:
            break
        case .food, .move, .journal, .workshop:
            break
        }
    }
}

struct PersonalMemoryList: View {
    var category: String
    var emptyText: String
    @ObservedObject var store: FernletStore

    private var memories: [MemoryNote] {
        store.memories.filter { $0.category.localizedCaseInsensitiveContains(category) }
    }

    var body: some View {
        if memories.isEmpty {
            EmptyState(text: emptyText)
        } else {
            ForEach(Array(memories.prefix(8).enumerated()), id: \.element.id) { index, memory in
                VStack(alignment: .leading, spacing: 4) {
                    Text(memory.text)
                        .font(.body)
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    Text(memory.sourceDate.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.caption2)
                        .foregroundStyle(Color.slate)
                }
                .padding(.vertical, 4)
                if index < min(memories.count, 8) - 1 {
                    FernletRowDivider()
                }
            }
        }
    }
}

struct MealLogNotification: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let macros: MacroTotals

    init(meals: [Meal]) {
        title = meals.count == 1 ? "\(meals[0].name) logged" : "\(meals.count) meals logged"
        macros = meals.reduce(into: MacroTotals()) { totals, meal in
            totals.protein += meal.macros.protein
            totals.carbs += meal.macros.carbs
            totals.fat += meal.macros.fat
        }
    }
}

struct MealLogNotificationView: View {
    var notification: MealLogNotification

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.moss)
                .frame(width: 30, height: 30)
                .background(Color.moss.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(notification.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("P \(notification.macros.protein)g · C \(notification.macros.carbs)g · F \(notification.macros.fat)g")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.slate)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.bark.opacity(0.10), lineWidth: 1)
        )
        .shadow(color: Color.bark.opacity(0.12), radius: 14, x: 0, y: 7)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Launch screen

struct LaunchScreen: View {
    var statusMessage: String

    private var greeting: String {
        Self.greeting(for: Date.now)
    }

    private var displayedStatusMessage: String {
        statusMessage.isEmpty ? LaunchPreparationService.initialStatusMessage : statusMessage
    }

    static func greeting(for date: Date, calendar: Calendar = .autoupdatingCurrent) -> String {
        let hour = calendar.component(.hour, from: date)
        if (5..<12).contains(hour) { return "Good morning." }
        if (12..<17).contains(hour) { return "Good afternoon." }
        return "Good evening."
    }

    var body: some View {
        ZStack {
            Color.parchment.ignoresSafeArea()

            VStack(spacing: 32) {
                Spacer()

                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate
                    let pulse = 1 + 0.14 * ((sin(elapsed * .pi / 0.85) + 1) / 2)

                    ZStack {
                        Circle()
                            .fill(Color.fern.opacity(0.07))
                            .frame(width: 168, height: 168)
                            .scaleEffect(pulse)
                        CompanionView(state: .thriving, size: 112)
                    }
                }

                VStack(spacing: 10) {
                    Text(greeting)
                        .font(.system(size: 34, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    Text(displayedStatusMessage)
                        .font(.callout.italic())
                        .foregroundStyle(Color.slate)
                        .animation(.easeInOut(duration: 0.25), value: displayedStatusMessage)
                }

                TimelineView(.animation) { timeline in
                    let elapsed = timeline.date.timeIntervalSinceReferenceDate

                    HStack(spacing: 7) {
                        ForEach(0..<3, id: \.self) { i in
                            let wave = (sin((elapsed - Double(i) * 0.18) * .pi / 0.55) + 1) / 2
                            Circle()
                                .fill(Color.moss)
                                .frame(width: 7, height: 7)
                                .opacity(0.2 + 0.65 * wave)
                        }
                    }
                }

                Spacer()
            }
        }
    }
}

#Preview {
    ContentView(store: FernletStore())
}
