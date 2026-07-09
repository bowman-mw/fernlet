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
    @State private var stressService = StressService()
    @State private var worryBoxService = WorryBoxService()
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
    /// Set by the stress explainer's First Aid link; consumed by `handleActiveSheetDismiss`
    /// (the same dismiss-then-represent chaining the recipe editors use).
    @State private var pendingFirstAidAfterDismiss = false
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
                worryBoxService.updateActivation(lockState: newState, contentKey: lockService.contentKey())
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
                // Body signals (opt-in): wire the stress service to the store + a fresh
                // gateway fetch. Foreground-pull only — refreshed below and on scene-active.
                stressService.attach(store: store, fetchMetricDays: { [storagePreferencesStore] daysBack in
                    try await HealthKitService(preferencesStore: storagePreferencesStore).stressMetricDays(daysBack: daysBack)
                })
                store.attachStressScoringContext(stressService)
                let initialLockState = lockService.state
                store.lockState = initialLockState
                if case .unlocked = initialLockState, let contentKey = lockService.contentKey() {
                    store.activateSealedJournals(contentKey: contentKey)
                } else if case .locked = initialLockState {
                    store.deactivateSealedJournals()
                } else {
                    store.activateNoLockJournals()
                }
                worryBoxService.updateActivation(lockState: initialLockState, contentKey: lockService.contentKey())
                // Worry "let go" counts are DEVICE-LOCAL (WorryBoxService owns them, incremented at the
                // "let it go" write) — never the synced milestone ledger, so worry metadata honors the
                // box's "never sync anywhere" promise. The store reads the count through this provider
                // for MilestonesView, and purges the sealed rows + count on "Reset everything".
                store.worriesLetGoProvider = { worryBoxService.lifetimeLetGoCount }
                store.worryBoxResetHook = { worryBoxService.releaseAll() }
                #if DEBUG
                // UX appearance tests: populate the diary so every tab renders real cards.
                if UITestSupport.shouldSeedDemoContent {
                    store.seedDemoContent()
                    // Deterministic runs: never start with the companion already settled
                    // from petting in a previous test on the same simulator.
                    PetInteractionGovernor.clearPersistentState()
                }
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
                // A notification tapped during a cold launch stored its deep-link before this
                // view finished preparing — open it now (live taps arrive via onReceive below).
                consumePendingNotificationSheet()
                store.meshNetworkManager.injectUITestStateIfNeeded()
                updateRecipeShareListener()
                store.deferredPostLaunchTasks()
                store.ensureBundledFoodItemsSeeded()
                // Widget bridge: wire the mirror, drain "+1 water" taps queued while the app was
                // closed, and publish the first snapshot (store is fully loaded by this point).
                store.activateWidgetBridge()
                await store.processSharedRecipeImportQueue()
                await loadPeriodEntriesIfPossible()
                refreshPeriodContext()
                await stressService.refreshIfNeeded()
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
                    // Apply widget "+1 water" taps that arrived while backgrounded (also refreshes
                    // the mirrored snapshot across day rollovers).
                    store.processPendingWidgetActions()
                    // Credit any day that became active while backgrounded (or synced in from another
                    // device). Idempotent, so a no-op when nothing new is logged.
                    store.reconcileCoinLedger()
                    // Body signals refresh (debounced to >= 30 min inside the service).
                    Task { await stressService.refreshIfNeeded() }
                    if selectedTab == .social { startFriendsDiscovery() }
                } else if selectedTab == .social {
                    stopFriendsDiscovery()
                }
                updateRecipeShareListener()
            }
            .onReceive(NotificationCenter.default.publisher(for: FernletNotificationDelegate.pendingSheetRequestNotification)) { _ in
                consumePendingNotificationSheet()
            }
    }

    /// Opens the sheet a notification tap asked for (daily check-in → journal). Skipped while
    /// launch preparation is still running — the startup task consumes the flag afterwards.
    private func consumePendingNotificationSheet() {
        guard launcher.isDone else { return }
        // A sheet is already open — leave the request PENDING (don't clear it) so it isn't silently
        // dropped; `handleActiveSheetDismiss` re-consumes it once the covering sheet closes.
        guard activeSheet == nil else { return }
        guard let id = FernletNotificationDelegate.shared.pendingSheetID else { return }
        FernletNotificationDelegate.shared.pendingSheetID = nil
        switch id {
        case "journal": activeSheet = .journal
        case "firstAid": activeSheet = .firstAid(nil)
        default: break
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
                stressService: stressService
            )
            .tag(FernletTab.home)
            FoodView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .food))
                .tag(FernletTab.food)
            MoveView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .move))
                .tag(FernletTab.move)
            SocialHubView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .social))
                .tag(FernletTab.social)
            PrivateHubView(store: store, periodStore: periodStore, periodContext: periodContext, worryBox: worryBoxService, activeSheet: $activeSheet, section: $privateHubSection, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .personal))
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
                            .font(.fernlet(.labelSmall))
                            .opacity(isCompact ? 0 : 1)
                            .frame(height: isCompact ? 0 : nil)
                            .accessibilityHidden(isCompact)
                    }
                    .foregroundStyle(isSelected ? Color.moss : Color.slate)
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
        case .stressExplainer:
            StressExplainerSheet(assessment: stressService.assessment, onFirstAid: {
                // Chain into First Aid via the dismiss-then-represent pattern (single-active sheet).
                pendingFirstAidAfterDismiss = true
                activeSheet = nil
            })
                .uxScreenAnchor("sheet.stressExplainer")
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
        case .firstAid(let tool):
            FirstAidView(store: store, worryBox: worryBoxService, initialTool: tool)
                .uxScreenAnchor("sheet.firstAid")
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
                .presentationCornerRadius(20)
                .environment(storagePreferencesStore)
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
        } else if pendingFirstAidAfterDismiss {
            pendingFirstAidAfterDismiss = false
            activeSheet = .firstAid(nil)
        } else {
            // A notification tap that arrived while a sheet was open left its request pending — now
            // that the sheet has closed, honor it (no-op if there was nothing pending).
            consumePendingNotificationSheet()
        }
    }

    private func updateRecipeShareListener() {
        if shouldListenForRecipeShares {
            store.recipeShareManager.start()
        } else {
            store.recipeShareManager.stop()
        }
        updateClothingShareListener()
        updateHeartShareListener()
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

    private func updateClothingShareListener() {
        if shouldListenForClothingShares {
            store.clothingShareManager.start()
        } else {
            store.clothingShareManager.stop()
        }
    }

    /// The clothing shop is in-person + social-only: discover/broadcast while on the Friends tab so the
    /// FriendShopView can browse nearby shops. Cleared (and the ephemeral peer catalogs dropped) otherwise.
    ///
    /// PRIVACY (deliberate — do NOT loosen): every guard here tears the manager down the moment its
    /// condition fails, and `stop()` both ends the Multipeer session (so the display name / designer id /
    /// shop catalog stop being advertised) AND drops the ephemeral peer catalogs — the session-only
    /// guarantee. The `scenePhase == .active` gate is intentional: a privacy-first app must NOT keep
    /// broadcasting its shop while inactive/backgrounded (notification shade, call banner, app switcher,
    /// lock). Collapsing an in-progress shop session on a transient dip is the accepted cost of never
    /// advertising in the background — favour not-broadcasting over shop-session convenience. The opt-out
    /// (`allowNearbyClothingShares`) and lock (`.locked`) are enforced here too, and the opt-out setter
    /// (`FernletStore.setAllowNearbyClothingShares`) calls `stop()` directly so turning it OFF takes effect
    /// immediately without waiting for a scene / tab / lock event.
    private var shouldListenForClothingShares: Bool {
        guard store.settings.allowNearbyClothingShares else { return false }
        guard scenePhase == .active else { return false }
        guard selectedTab == .social else { return false }
        switch lockService.state {
        case .notConfigured, .unlocked:
            return true
        case .locked:
            return false
        }
    }

    private func updateHeartShareListener() {
        if shouldListenForHearts {
            store.heartShareManager.start()
        } else {
            store.heartShareManager.stop()
        }
    }

    /// Hearts are in-person v1: listen on the recipe-share tabs (so a heart arrives while the
    /// receiver is anywhere on the main surfaces) PLUS Social, where the send buttons live
    /// (FriendListView + the session People list). Same privacy posture as the other two
    /// listeners: never while backgrounded or locked, and the opt-out setter
    /// (`FernletStore.setAllowNearbyHearts`) stops the manager immediately.
    private var shouldListenForHearts: Bool {
        guard store.settings.allowNearbyHearts else { return false }
        guard scenePhase == .active else { return false }
        guard selectedTab == .home || selectedTab == .food || selectedTab == .move || selectedTab == .social else { return false }
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
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                Text("Use Health access in Settings to keep cycle context available here.")
                    .font(.fernlet(.bodySmall))
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
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                FernletScrollSection("Notes") {
                    if intimacyLogs.isEmpty {
                        EmptyState(text: "No private intimacy notes yet.")
                    } else {
                        ForEach(Array(intimacyLogs.prefix(12).enumerated()), id: \.element.id) { index, log in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(log.eventDate.formatted(.dateTime.month(.abbreviated).day().hour().minute()))
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.slate)
                                if !log.note.isEmpty {
                                    Text(log.note)
                                        .font(.fernlet(.body))
                                        .foregroundStyle(Color.bark)
                                        .fernletWrappingText()
                                }
                                if log.healthKitExternalUUID != nil {
                                    Label("Saved to Apple Health", systemImage: "heart.text.square")
                                        .font(.fernlet(.labelSmall))
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
                    .font(.fernlet(.bodySmall))
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
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                    Text(memory.sourceDate.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.fernlet(.labelSmall))
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
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                Text("P \(notification.macros.protein)g · C \(notification.macros.carbs)g · F \(notification.macros.fat)g")
                    .font(.fernlet(.stat))
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
                        .font(.fernlet(.display))
                        .foregroundStyle(Color.bark)

                    Text(displayedStatusMessage)
                        .font(.fernlet(.bubble))
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
                        .font(.fernlet(.headerMedium))
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
                        Text(day).font(.fernlet(.labelSmall)).foregroundStyle(Color.slate)
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
                        .font(.fernlet(.stat))
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
