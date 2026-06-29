//
//  ContentView.swift
//  Fernlet
//
//  Created by Michael Bowman on 5/16/26.
//

import ProximityKit
import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletLock
import PrivateHealthStore
import PeriodContextBridge
import HealthKitGateway

struct ContentView: View {
    @Bindable var store: FernletStore
    @State private var launcher = LaunchPreparationService()
    @State private var periodStore = PeriodTrackerStore(healthService: HealthKitService())
    @State private var periodContext: PeriodContextBridge?
    @Environment(FernletLockService.self) private var lockService
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @AppStorage("fernletDarkModeEnabled") private var isDarkModeEnabled = false
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
    @State private var selectedTab: FernletTab = .home
    @State private var privateHubSection: PrivateHubSection = .journal
    @State private var isHomeTabBarCompact = false
    @State private var tabResetTokens: [FernletTab: Int] = Dictionary(uniqueKeysWithValues: FernletTab.allCases.map { ($0, 0) })
    @State private var activeSheet: FernletSheet?
    @State private var mealLogNotification: MealLogNotification?
    @State private var editingRecipeFromHome: RecipeDefinition?
    @State private var editingSavedRecipeFromHome: RecipeDefinition?
    @State private var didAutoImportHealthProfile = false
    @State private var didAutoImportHealthContext = false
    @State private var discoveryTimeoutTask: Task<Void, Never>?
    @State private var healthRefreshTask: Task<Void, Never>?
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        launchRoot
            .preferredColorScheme(isDarkModeEnabled ? .dark : .light)
            .sheet(item: $activeSheet, onDismiss: handleActiveSheetDismiss) { sheet in
                sheetContent(for: sheet)
            }
            .sheet(isPresented: $store.showConnectionInspector) {
                ConnectionInspectorView(inspector: store.connectionInspector)
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
                    .presentationBackgroundInteraction(.enabled)
            }
            .sheet(item: pendingRecipeShareBinding) { share in
                ProximityRecipeShareReviewSheet(
                    share: share,
                    store: store,
                    manager: store.recipeShareManager
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
            }
            .onChange(of: activeSheet?.id) { oldID, newID in
                // Logging/editing a period event persists to HealthKit but doesn't mutate the in-memory
                // entries, so reload + refresh when the period sheet dismisses to keep the chip/outlook/
                // trends/score current (catches logging from Home or the period screen alike).
                guard newID == nil, oldID == "logPeriod" else { return }
                Task {
                    await loadPeriodEntriesIfPossible()
                    refreshPeriodContext()
                }
            }
            .onChange(of: lockService.state) { _, newState in
                store.lockState = newState
                Task { await drainPendingPeriodNarrativesIfUnlocked(newState) }
                if case .unlocked = newState, let contentKey = lockService.contentKey() {
                    store.activateSealedJournals(contentKey: contentKey)
                } else if case .locked = newState {
                    store.deactivateSealedJournals()
                } else if case .notConfigured = newState {
                    store.activateNoLockJournals()
                }
                updateRecipeShareListener()
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
                if periodContext == nil {
                    let bridge = PeriodContextBridge(source: periodStore)
                    store.attachPeriodScoringContext(bridge)
                    periodContext = bridge
                }
                let initialLockState = lockService.state
                store.lockState = initialLockState
                if case .unlocked = initialLockState, let contentKey = lockService.contentKey() {
                    store.activateSealedJournals(contentKey: contentKey)
                } else if case .locked = initialLockState {
                    store.deactivateSealedJournals()
                } else {
                    store.activateNoLockJournals()
                }
                #if DEBUG
                // UX appearance tests: populate the diary so every tab renders real cards.
                if UITestSupport.shouldSeedDemoContent { store.seedDemoContent() }
                #endif
                try? await Task.sleep(for: .milliseconds(120))
                async let _ = autoImportHealthProfileIfAvailable()
                async let _ = autoImportHealthContextIfAvailable()
                await launcher.prepare(store: store)
                store.markLaunchScreenDismissed()
                #if DEBUG
                // UX appearance tests: jump straight to a sheet by its FernletSheet.id
                // (generalizes the older FERNLET_UI_TEST_OPEN_SETTINGS hook).
                if let initialSheet = UITestSupport.initialSheet { activeSheet = initialSheet }
                #endif
                store.meshNetworkManager.injectUITestStateIfNeeded()
                updateRecipeShareListener()
                store.deferredPostLaunchTasks()
                store.ensureBundledFoodItemsSeeded()
                await store.processSharedRecipeImportQueue()
                await loadPeriodEntriesIfPossible()
                refreshPeriodContext()
            }
            .onChange(of: selectedTab) { oldTab, newTab in
                tabResetTokens[oldTab, default: 0] += 1
                isHomeTabBarCompact = false
                if newTab == .social {
                    startFriendsDiscovery()
                } else if oldTab == .social {
                    stopFriendsDiscovery()
                }
                updateRecipeShareListener()
                healthRefreshTask?.cancel()
                healthRefreshTask = Task { await refreshHealthContextForActiveTab(newTab) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    Task { await store.processSharedRecipeImportQueue() }
                    if selectedTab == .social { startFriendsDiscovery() }
                } else if selectedTab == .social {
                    stopFriendsDiscovery()
                }
                updateRecipeShareListener()
            }
    }

    private func resetTokenBinding(for tab: FernletTab) -> Binding<Int> {
        Binding(
            get: { tabResetTokens[tab, default: 0] },
            set: { tabResetTokens[tab] = $0 }
        )
    }

    private var pendingRecipeShareBinding: Binding<PendingProximityRecipeShare?> {
        Binding(
            get: { activeSheet == nil ? store.recipeShareManager.pendingRecipeShares.first : nil },
            set: { newValue in
                guard newValue == nil,
                      let first = store.recipeShareManager.pendingRecipeShares.first else { return }
                store.recipeShareManager.dismissRecipeShare(first)
            }
        )
    }

    private var launchRoot: some View {
        ZStack {
            sceneBackground.ignoresSafeArea()
            if launcher.isDone {
                mainInterface
                    .transition(.opacity)
            } else {
                LaunchScreen(
                    statusMessage: launcher.statusMessage,
                    companionState: store.companionState,
                    companionAppearance: store.settings.companionAppearance,
                    showsCompanion: true
                )
                    .transition(.opacity)
            }
        }
        .background(sceneBackground)
    }

    private var mainInterface: some View {
        mainTabContent
            .overlay(alignment: .bottom) {
                if !isDisposableCameraSessionActive {
                    LinearGradient(
                        colors: [Color.parchment.opacity(0), Color.parchment],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 26)
                    .allowsHitTesting(false)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !isLandscapeDisposableCameraActive {
                    customTabBar
                        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isCustomTabBarCompact)
                }
            }
            .tint(Color.moss)
            .background(sceneBackground.ignoresSafeArea())
    }

    @ViewBuilder
    private var mainTabContent: some View {
        if isDisposableCameraSessionActive {
            SocialHubView(store: store, activeSheet: $activeSheet, isTabBarCompact: .constant(false), tabResetToken: .constant(0))
        } else {
            pagedTabs
        }
    }

    private var pagedTabs: some View {
        TabView(selection: $selectedTab) {
            HomeView(
                store: store,
                activeSheet: $activeSheet,
                selectedTab: $selectedTab,
                privateHubSection: $privateHubSection,
                isTabBarCompact: $isHomeTabBarCompact,
                tabResetToken: resetTokenBinding(for: .home),
                periodStore: periodStore,
                periodContext: periodContext
            )
            .tag(FernletTab.home)
            FoodView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .food))
                .tag(FernletTab.food)
            MoveView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .move))
                .tag(FernletTab.move)
            SocialHubView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .social))
                .tag(FernletTab.social)
            PrivateHubView(store: store, periodStore: periodStore, periodContext: periodContext, activeSheet: $activeSheet, section: $privateHubSection, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .personal))
                .tag(FernletTab.personal)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
    }

    private var isDisposableCameraSessionActive: Bool {
        selectedTab == .social
            && store.meshNetworkManager.isInSession
    }

    private var isLandscapeDisposableCameraActive: Bool {
        isDisposableCameraSessionActive
            && store.isDisposableCameraLandscape
    }

    private var isCustomTabBarCompact: Bool {
        !isDisposableCameraSessionActive && isHomeTabBarCompact
    }

    private var sceneBackground: Color {
        isDisposableCameraSessionActive
            ? Color(red: 0.13, green: 0.10, blue: 0.08)
            : Color.parchment
    }

    private var customTabBar: some View {
        let isCompact = isCustomTabBarCompact
        let cornerRadius: CGFloat = isCompact ? 22 : 26

        return HStack(spacing: isCompact ? 4 : 0) {
            ForEach(FernletTab.allCases) { tab in
                Button {
                    selectedTab = tab
                } label: {
                    let isSelected = selectedTab == tab
                    VStack(spacing: isCompact ? 0 : 3) {
                        Image(systemName: tab.systemImage)
                            .font(.system(size: isCompact ? 18 : 20))
                            .frame(height: isCompact ? 22 : 24)
                        Text(tab.title)
                            .font(.system(size: 10, weight: .medium))
                            .opacity(isCompact ? 0 : 1)
                            .frame(height: isCompact ? 0 : nil)
                            .accessibilityHidden(isCompact)
                    }
                    .foregroundStyle(isSelected ? Color.moss : Color(UIColor.secondaryLabel))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, isCompact ? 8 : 9)
                    .background(
                        isSelected ? Color.parchment : Color.clear,
                        in: RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous)
                    )
                    .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, isCompact ? 6 : 8)
        .padding(.vertical, isCompact ? 5 : 6)
        .frame(maxWidth: isCompact ? 300 : .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.bark.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.bark.opacity(0.12), radius: isCompact ? 12 : 16, x: 0, y: isCompact ? 4 : 6)
        .padding(.horizontal, isCompact ? 40 : 20)
        .padding(.bottom, isCompact ? 4 : 12)
    }

    @ViewBuilder
    private func sheetContent(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .meal:
            MealSheet(store: store, onLogged: showMealLogNotification)
                .uxScreenAnchor("sheet.meal")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .recipe:
            RecipeSheet(store: store)
                .uxScreenAnchor("sheet.recipe")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .water:
            WaterSheet(store: store)
                .uxScreenAnchor("sheet.water")
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .sleep:
            SleepSheet(store: store)
                .uxScreenAnchor("sheet.sleep")
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .journal:
            JournalSheet(store: store)
                .uxScreenAnchor("sheet.journal")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .quickExercise:
            QuickExerciseSheet(store: store)
                .uxScreenAnchor("sheet.quickExercise")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .workout:
            WorkoutSheet(store: store)
                .uxScreenAnchor("sheet.workout")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .workoutSuggestion:
            WorkoutSuggestionSheet(store: store)
                .uxScreenAnchor("sheet.workoutSuggestion")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .goals:
            GoalsSheet(store: store)
                .uxScreenAnchor("sheet.goals")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .hygiene:
            HygieneSheet(store: store)
                .uxScreenAnchor("sheet.hygiene")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .settings:
            SettingsSheet(store: store)
                .uxScreenAnchor("sheet.settings")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(lockService)
                .environment(storagePreferencesStore)
        case .recipeBook:
            RecipeBookSheet(store: store, editingRecipe: $editingRecipeFromHome, editingSavedRecipe: $editingSavedRecipeFromHome)
                .uxScreenAnchor("sheet.recipeBook")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .trends:
            TrendsModal(signals: store.derivedSignals)
                .uxScreenAnchor("sheet.trends")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .logPeriod(let targetDate, let editingEntry):
            LogPeriodSheet(periodStore: periodStore, targetDate: targetDate, editingEntry: editingEntry)
                .uxScreenAnchor("sheet.logPeriod")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(lockService)
        case .logIntimacy:
            LogIntimacySheet()
                .uxScreenAnchor("sheet.logIntimacy")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(lockService)
                .environment(storagePreferencesStore)
        case .editRecipe(let recipe):
            RecipeSheet(store: store, recipe: recipe)
                .uxScreenAnchor("sheet.editRecipe")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .editSavedRecipe(let recipe):
            SavedRecipeNotesSheet(store: store, recipe: recipe)
                .uxScreenAnchor("sheet.editSavedRecipe")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
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
        guard case .unlocked = lockState, let contentKey = lockService.contentKey() else {
            refreshPeriodContext()
            return
        }
        try? await periodStore.drainPendingBuffer(contentKey: contentKey)
        await periodStore.loadEntries(unlockedContentKey: contentKey)
        refreshPeriodContext()
    }

    /// Loads period entries with whatever content key is currently available (nil when locked / no lock),
    /// so the bridge has cycle data for phase resolution and trends.
    private func loadPeriodEntriesIfPossible() async {
        let contentKey = { if case .unlocked = lockService.state { return lockService.contentKey() } else { return nil } }()
        await periodStore.loadEntries(unlockedContentKey: contentKey)
    }

    /// Recomputes the bridge's per-phase trends from current period data + the store's wellbeing scores.
    /// Phase resolution itself always reads the live period store, so this only refreshes the (optional)
    /// softening gate — staleness can only *withhold* softening, never apply it incorrectly.
    private func refreshPeriodContext() {
        guard let periodContext else { return }
        let unlocked = { if case .unlocked = lockService.state { return true } else { return false } }()
        periodContext.refresh(unlocked: unlocked, wellbeingByDay: store.periodWellbeingByDay)
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

    private func handleActiveSheetDismiss() {
        if let recipe = editingRecipeFromHome {
            editingRecipeFromHome = nil
            activeSheet = .editRecipe(recipe)
        } else if let recipe = editingSavedRecipeFromHome {
            editingSavedRecipeFromHome = nil
            activeSheet = .editSavedRecipe(recipe)
        }
    }

    private func updateRecipeShareListener() {
        if shouldListenForRecipeShares {
            store.recipeShareManager.start()
        } else {
            store.recipeShareManager.stop()
        }
    }

    private var shouldListenForRecipeShares: Bool {
        guard store.settings.allowNearbyRecipeShares else { return false }
        guard scenePhase == .active else { return false }
        guard selectedTab == .home || selectedTab == .food || selectedTab == .move else { return false }
        switch lockService.state {
        case .notConfigured, .unlocked:
            return true
        case .locked:
            return false
        }
    }

    private func startFriendsDiscovery() {
        let manager = store.meshNetworkManager
        guard !manager.isInSession, !manager.isSearching else { return }
        manager.startJoin()
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(5 * 60))
            guard !Task.isCancelled, !manager.isInSession else { return }
            manager.stopJoin()
        }
    }

    private func stopFriendsDiscovery() {
        discoveryTimeoutTask?.cancel()
        discoveryTimeoutTask = nil
        let manager = store.meshNetworkManager
        guard !manager.isInSession else { return }
        manager.stopJoin()
    }
}

struct PersonalScreenView: View {
    var screen: FernletScreen
    @Bindable var store: FernletStore
    @Binding var activeSheet: FernletSheet?
    var isInHub: Bool = false
    @Binding var isTabBarCompact: Bool
    @Binding var tabResetToken: Int
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @Environment(FernletLockService.self) private var lockService
    @State private var intimacyDisplayedMonth: Date = .now
    @State private var intimacyEventsByDay: [String: Int] = [:]
    @State private var intimacyLogs: [IntimacyLog] = []

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .top) {
                        ScreenHeader(
                            title: screen.title,
                            subtitle: screen.subtitle,
                            identifier: screen == .intimacyTracking ? "screen.intimacy" : nil
                        )
                        Spacer()
                        HeaderActionButton(systemImage: primaryActionIcon) {
                            handlePrimaryAction()
                        }
                    }
                    .padding(.top, 4)

                    if screen == .intimacyTracking {
                        personalScreenBody
                    } else {
                        FernletScrollSection(todaySectionTitle) {
                            personalScreenBody
                        }
                    }
                }
                .padding(20)
            }
            .fernletTabBarCompaction($isTabBarCompact, resetToken: $tabResetToken)
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
        case .food, .move, .journal: "Today"
        }
    }

    private var primaryActionIcon: String {
        switch screen {
        case .periodTracking, .intimacyTracking:
            "plus"
        case .photos:
            "photo.badge.plus"
        case .friends:
            "square.and.pencil"
        case .food, .move, .journal:
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
            VStack(alignment: .leading, spacing: 12) {
                IntimacyCalendarCard(
                    displayedMonth: $intimacyDisplayedMonth,
                    eventsByDay: intimacyEventsByDay
                )
                Text("Intimacy access is private, optional, and age-gated.")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                FernletScrollSection("Notes") {
                    if intimacyLogs.isEmpty {
                        EmptyState(text: "No private intimacy notes yet.")
                    } else {
                        ForEach(Array(intimacyLogs.prefix(12).enumerated()), id: \.element.id) { index, log in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(log.eventDate.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.slate)
                                if !log.note.isEmpty {
                                    Text(log.note)
                                        .font(.callout)
                                        .foregroundStyle(Color.bark)
                                        .fernletWrappingText()
                                }
                                if log.healthKitExternalUUID != nil {
                                    Label("Saved to Apple Health", systemImage: "heart.text.square")
                                        .font(.caption2)
                                        .foregroundStyle(Color.moss)
                                }
                            }
                            .padding(.vertical, 4)
                            if index < intimacyLogs.prefix(12).count - 1 {
                                FernletRowDivider()
                            }
                        }
                    }
                }
            }
            .task(id: intimacyDisplayedMonth) { await loadIntimacyCalendar() }
            .onChange(of: activeSheet?.id) { _, newValue in
                if newValue == nil { Task { await loadIntimacyCalendar() } }
            }
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
        case .food, .move, .journal:
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

    private func loadIntimacyCalendar() async {
        guard store.isIntimateLoggingAllowed else { return }
        let contentKey = lockService.contentKey()
        let localLogs: [IntimacyLog] = (try? IntimacyLogRepository().logs(contentKey: contentKey)) ?? []
        intimacyLogs = localLogs
        let localEventsByDay = Dictionary(grouping: localLogs, by: \.dayKey).mapValues(\.count)
        do {
            let service = HealthKitService(preferencesStore: storagePreferencesStore)
            let healthEventsByDay = try await service.loadIntimacyEventsByDay(for: intimacyDisplayedMonth)
            intimacyEventsByDay = healthEventsByDay.merging(localEventsByDay) { max($0, $1) }
        } catch {
            intimacyEventsByDay = localEventsByDay
        }
    }

    private func handlePrimaryAction() {
        switch screen {
        case .periodTracking:
            activeSheet = .settings
        case .intimacyTracking:
            activeSheet = .logIntimacy
        case .friends:
            activeSheet = .journal
        case .photos:
            break
        case .food, .move, .journal:
            break
        }
    }
}

struct PersonalMemoryList: View {
    var category: String
    var emptyText: String
    @Bindable var store: FernletStore

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
    var companionState: CompanionState = .thriving
    var companionAppearance: CompanionAppearance = .standard
    var showsCompanion = false

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

                if showsCompanion {
                    TimelineView(.animation) { timeline in
                        let elapsed = timeline.date.timeIntervalSinceReferenceDate
                        let pulse = 1 + 0.14 * ((sin(elapsed * .pi / 0.85) + 1) / 2)

                        ZStack {
                            Circle()
                                .fill(Color.fern.opacity(0.07))
                                .frame(width: 168, height: 168)
                                .scaleEffect(pulse)
                            CompanionView(
                                state: companionState,
                                appearance: companionAppearance,
                                size: 112
                            )
                        }
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

// MARK: - Intimacy Calendar Card

private struct IntimacyCalendarCard: View {
    @Binding var displayedMonth: Date
    var eventsByDay: [String: Int]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 4), count: 7)
    private var cal: Calendar { .current }
    private var todayKey: String { FernletDate.dayKey(for: Date()) }

    var body: some View {
        let model = IntimacyMonthModel(date: displayedMonth, eventsByDay: eventsByDay, todayKey: todayKey)
        FernletCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center) {
                    Button {
                        displayedMonth = cal.date(byAdding: .month, value: -1, to: displayedMonth) ?? displayedMonth
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)

                    Text(model.monthTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.bark)
                        .frame(maxWidth: .infinity)

                    let isCurrentMonth = cal.isDate(displayedMonth, equalTo: .now, toGranularity: .month)
                    Button {
                        if !isCurrentMonth {
                            displayedMonth = cal.date(byAdding: .month, value: 1, to: displayedMonth) ?? displayedMonth
                        }
                    } label: {
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(isCurrentMonth ? Color.slate.opacity(0.25) : Color.slate)
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .disabled(isCurrentMonth)
                }

                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(Array(model.weekdaySymbols.enumerated()), id: \.offset) { _, day in
                        Text(day).font(.caption2.weight(.semibold)).foregroundStyle(Color.slate)
                    }
                    ForEach(model.cells) { cell in
                        IntimacyCalendarCell(cell: cell)
                    }
                }
            }
        }
    }
}

private struct IntimacyCalendarCell: View {
    var cell: IntimacyMonthCell

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5)
                .fill(cell.fill)
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(cell.isToday ? Color.moss : Color.clear, lineWidth: 1.5)
                )
            if let day = cell.day {
                VStack(spacing: 1) {
                    Text("\(day)")
                        .font(.caption2.weight(cell.isToday ? .bold : .medium))
                        .foregroundStyle(
                            cell.isFuture ? Color.bark.opacity(0.28)
                                : cell.isToday ? Color.moss
                                : Color.bark.opacity(0.68)
                        )
                    if cell.hasEvent {
                        Circle()
                            .fill(Color.dustyRose.opacity(0.75))
                            .frame(width: 4, height: 4)
                    }
                }
                .padding(.bottom, 2)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(cell.accessibilityLabel)
    }
}

private struct IntimacyMonthCell: Identifiable {
    let id = UUID()
    var day: Int?
    var dateKey: String?
    var hasEvent: Bool
    var isToday: Bool
    var isFuture: Bool

    var fill: Color {
        guard day != nil else { return Color.softTaupe.opacity(0.05) }
        if hasEvent { return Color.dustyRose.opacity(0.15) }
        return isToday ? Color.moss.opacity(0.18) : Color.softTaupe.opacity(0.16)
    }

    var accessibilityLabel: String {
        guard let day else { return "Empty calendar cell" }
        if isFuture { return "Day \(day)" }
        if isToday { return hasEvent ? "Today, day \(day), event logged" : "Today, day \(day)" }
        return hasEvent ? "Day \(day), event logged" : "Day \(day)"
    }
}

private struct IntimacyMonthModel {
    let monthTitle: String
    let weekdaySymbols: [String]
    let cells: [IntimacyMonthCell]

    init(date: Date, eventsByDay: [String: Int], todayKey: String, calendar: Calendar = .current) {
        let monthInterval = calendar.dateInterval(of: .month, for: date)
        let start = monthInterval?.start ?? date
        let range = calendar.range(of: .day, in: .month, for: date) ?? 1..<2
        let firstWeekday = calendar.component(.weekday, from: start)

        self.monthTitle = date.formatted(.dateTime.month(.wide).year())
        self.weekdaySymbols = calendar.veryShortWeekdaySymbols

        let ymFormatter = DateFormatter()
        ymFormatter.dateFormat = "yyyy-MM"
        ymFormatter.calendar = Calendar(identifier: .gregorian)
        let yearMonth = ymFormatter.string(from: date)

        let blanks = (0..<(firstWeekday - 1)).map { _ in
            IntimacyMonthCell(day: nil, dateKey: nil, hasEvent: false, isToday: false, isFuture: false)
        }
        let days = range.map { d -> IntimacyMonthCell in
            let key = "\(yearMonth)-\(String(format: "%02d", d))"
            return IntimacyMonthCell(
                day: d,
                dateKey: key,
                hasEvent: (eventsByDay[key] ?? 0) > 0,
                isToday: key == todayKey,
                isFuture: key > todayKey
            )
        }
        self.cells = blanks + days
    }
}

#Preview {
    ContentView(store: FernletStore())
}
