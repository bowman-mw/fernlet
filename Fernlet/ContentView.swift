//
//  ContentView.swift
//  Fernlet
//
//  Created by Michael Bowman on 5/16/26.
//

import ProximityKit
import CloudKitSync
import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletLock
import PrivateHealthStore
import PrivateMemoryStore
import PeriodContextBridge
import HealthKitGateway
import FernletUI

struct ContentView: View {
    @Bindable var store: FernletStore
    @State private var launcher = LaunchPreparationService()
    @State private var periodStore = PeriodTrackerStore(healthService: HealthKitService())
    @State private var intimacyStore = IntimacyLogStore()
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
                applySealedJournalActivation(for: newState)
                worryBoxService.updateActivation(
                    lockState: newState,
                    contentKey: lockService.contentKey(for: .privateHub)
                )
                // The sealed period backup is sealed under the hub's content key, so turning it on
                // from Settings (reached from Home, where the hub is always re-locked) can only ever
                // DEFER the upload. This is the moment that debt can be paid: the hub just unlocked,
                // so the narratives are readable. No-op unless a deferral is actually outstanding.
                if newState.isUnlocked(for: .privateHub) {
                    Task { await store.retryDeferredSealedPeriodBackupIfNeeded() }
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
            // Scrub on the gate VALUE, not on the toggle that usually changes it. Visibility is derived
            // (`periodTrackingVisible ?? sex == .female`, and intimacy ANDs the 18+ age check), so the
            // Settings toggle is only ONE of its inputs — editing Gender or Age in the profile editor, or
            // a HealthKit body-profile auto-import, flips the gate just as surely and never goes near
            // `setPeriodTrackingVisible`. Keying the scrub to the setter left those paths hiding the UI
            // while 240 days of decrypted narratives, the bridge's derived trends, and a persisted
            // `healthContext.cycle` all stayed live. Watching the value covers every writer by construction.
            .onChange(of: store.sensitiveSurfaceVisibility) { _, visibility in
                if !visibility.period { store.periodScrubHook?() }
                store.scrubHiddenHealthContext()
            }
            .task {
                periodStore.attachLockService(lockService)
                // Hard visibility gate. Injected before ANY load below: the store's own `.task` runs
                // on every cold launch, so wiring this later would let one full decrypt + HealthKit
                // read through before the gate existed.
                periodStore.isVisible = { [store] in store.isPeriodTrackingVisible }
                // Same hard gate for the intimacy sealed-notes seam. `IntimacyLogStore` funnels every
                // decrypt/seal and is fail-closed by default, so wiring it here — before any read below —
                // is what turns the gate from "reads nothing" into "reads exactly when visible".
                intimacyStore.isVisible = { [store] in store.isIntimacyTrackingVisible }
                // A day record written before the user hid a feature keeps its last cycle/intimate
                // value (HealthDailyContext.merge coalesces), so scrub on load, not just on toggle.
                store.scrubHiddenHealthContext()
                if periodContext == nil {
                    let bridge = PeriodContextBridge(source: periodStore)
                    store.attachPeriodScoringContext(bridge)
                    periodContext = bridge
                }
                // Set AFTER the bridge exists so the closure can capture it. Scrubbing the store alone
                // is not enough: the bridge memoizes derived period-start dates and per-phase symptom
                // trends of its own, and nothing else invalidates them on a preference change. `refresh`
                // is its documented invalidation point — with entries now empty it collapses trends to
                // [] and drops the cached starts. `unlocked: false` is the fail-closed reading of hidden.
                let bridge = periodContext
                store.periodScrubHook = { [periodStore, store] in
                    periodStore.scrubCycleState()
                    bridge?.refresh(unlocked: false, wellbeingByDay: store.periodWellbeingByDay)
                }
                // Body signals (opt-in): wire the stress service to the store + a fresh
                // gateway fetch. Foreground-pull only — refreshed below and on scene-active.
                stressService.attach(store: store, fetchMetricDays: { [storagePreferencesStore] daysBack in
                    try await HealthKitService(preferencesStore: storagePreferencesStore).stressMetricDays(daysBack: daysBack)
                })
                store.attachStressScoringContext(stressService)
                let initialLockState = lockService.state
                store.lockState = initialLockState
                applySealedJournalActivation(for: initialLockState)
                worryBoxService.updateActivation(
                    lockState: initialLockState,
                    contentKey: lockService.contentKey(for: .privateHub)
                )
                // Worry "let go" counts are DEVICE-LOCAL (WorryBoxService owns them, incremented at the
                // "let it go" write) — never the synced milestone ledger, so worry metadata honors the
                // box's "never sync anywhere" promise. The store reads the count through this provider
                // for MilestonesView, and purges the sealed rows + count on "Reset everything".
                store.worriesLetGoProvider = { worryBoxService.lifetimeLetGoCount }
                store.worryBoxResetHook = { worryBoxService.releaseAll() }
                attachDeleteAllHooks()
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
                    // If the app stayed resident across local midnight, roll the store over to the new
                    // day FIRST (flushes yesterday under its own key, re-keys "today") so the widget/
                    // coin refreshers below and any subsequent logging operate on the correct day.
                    store.refreshCurrentDayIfNeeded()
                    Task { await store.processSharedRecipeImportQueue() }
                    // Apply widget "+1 water" taps that arrived while backgrounded (also refreshes
                    // the mirrored snapshot across day rollovers).
                    store.processPendingWidgetActions()
                    // Credit any day that became active while backgrounded (or synced in from another
                    // device). Idempotent, so a no-op when nothing new is logged.
                    store.reconcileCoinLedger()
                    // Body signals refresh (debounced to >= 30 min inside the service).
                    Task { await stressService.refreshIfNeeded() }
                    // Belt-and-braces for the foreground App Intent deep-link: the `requestNotification`
                    // handler below is the primary path, but if a token is present when the scene reactivates
                    // (and within its expiry window), honor it here too.
                    consumePendingNotificationSheet()
                    if selectedTab == .social { startFriendsDiscovery() }
                } else if selectedTab == .social {
                    stopFriendsDiscovery()
                }
                updateRecipeShareListener()
            }
            .onReceive(NotificationCenter.default.publisher(for: FernletNotificationDelegate.pendingSheetRequestNotification)) { _ in
                consumePendingNotificationSheet()
            }
            // A foreground App Intent (#6, "Log a meal"/"Write in my journal") posts this AFTER writing its
            // deep-link token. On the warm path the system foregrounds this already-running view before the
            // intent's `perform()` writes the token, so the scene-active handler above ran too early to see
            // it — this event-driven consume is what actually opens the sheet.
            .onReceive(NotificationCenter.default.publisher(for: PendingIntentSheet.requestNotification)) { _ in
                consumePendingNotificationSheet()
            }
            .onChange(of: store.settings.allowNearbyPresence) { _, _ in
                // Enabling in Settings (or via the first-friend prompt) starts the radio right
                // away; disabling is already stopped by the setter — this keeps both in sync
                // with the scene/tab/lock gate.
                updatePresenceListener()
            }
            // One-time "first kept friend" presence offer (Phase 4a). Attached to the stable
            // root — not the Social-tab layout (which is destroyed in the same transaction as
            // session teardown, the Phase-2 lesson) — and driven by observable store state.
            .alert(
                "Turn on Nearby Friends?",
                isPresented: Binding(
                    get: { store.presenceEnablePromptRequested },
                    set: { if !$0 { store.presenceEnablePromptRequested = false } }
                )
            ) {
                Button("Turn on") {
                    store.setAllowNearbyPresence(true)
                    updatePresenceListener()
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("See when friends you've kept are nearby. Fernlet broadcasts only rotating tags that your friends' devices can recognize — never your name or a stable ID — and only while the app is open. You can change this anytime in Settings.")
            }
    }

    /// Opens the sheet a notification tap asked for (daily check-in → journal). Skipped while
    /// launch preparation is still running — the startup task consumes the flag afterwards.
    private func consumePendingNotificationSheet() {
        guard launcher.isDone else { return }
        // A sheet is already open — leave the request PENDING (don't clear it) so it isn't silently
        // dropped; `handleActiveSheetDismiss` re-consumes it once the covering sheet closes.
        guard activeSheet == nil else { return }
        // A foreground App Intent (#6, e.g. "Log a meal in Fernlet") records which sheet it wants; honor
        // it before the notification path so a Siri/Shortcuts open lands on the right screen.
        if let target = PendingIntentSheet.consume() {
            switch target {
            case .meal: activeSheet = .meal
            case .journal: activeSheet = .journal
            }
            return
        }
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
                // Only a genuine user dismissal discards the incoming share. SwiftUI ALSO writes nil
                // here when the getter goes nil because another sheet opened (`activeSheet != nil`) —
                // that is suppression, not dismissal. The old setter could not tell them apart and
                // called `dismissRecipeShare` on both, silently dropping an unreviewed recipe whenever
                // any other sheet happened to open; the share sheet then re-opened to nothing. Gating
                // on `activeSheet == nil` keeps the share queued through the suppression and lets it
                // re-present once the other sheet closes.
                guard newValue == nil, activeSheet == nil,
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
                if !isDisposableCameraSessionActive {
                    customTabBar
                        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isCustomTabBarCompact)
                        // Keep the floating tab bar pinned to the physical bottom (behind the
                        // keyboard) instead of riding up above it. Scoping the keyboard-safe-area
                        // ignore to the bar ONLY changes how safeAreaInset anchors the bar — the
                        // main tab content still receives the keyboard region in its safe area, so
                        // scroll views and focused fields inside the pages keep avoiding the keyboard.
                        .ignoresSafeArea(.keyboard, edges: .bottom)
                }
            }
            .tint(Color.moss)
            .background(sceneBackground.ignoresSafeArea())
    }

    /// Always the five-tab `pagedTabs`, unconditionally — its structural identity must never
    /// change, or SwiftUI tears down and rebuilds every tab (losing all @State) on the swap.
    ///
    /// This used to be an `if isDisposableCameraSessionActive { SocialHubView(...) } else { pagedTabs }`.
    /// Because a `@ViewBuilder` if/else is `_ConditionalContent<SocialHubView, TabView>` — two
    /// different types in the same slot — flipping the condition removed the whole `TabView` and
    /// inserted a bare `SocialHubView`, then reversed it at session end. Every tab (Home/Food/Move/
    /// Journal/Private) was destroyed and rebuilt with empty @State, each painting `Color.parchment`
    /// before its `.onAppear` `store.loadDays()` refilled it — the "blank then loads" symptom, fired
    /// on every friend-mesh session edge (and every Social↔other tab hop during a session).
    ///
    /// The swap was also redundant: the disposable camera is NOT a separate top-level surface —
    /// `FriendsView` (the body of the `.social` tab's `SocialHubView`) already swaps itself to
    /// `DisposableCameraView` while `isInSession && sessionReady` (ConnectView.swift:36). So the
    /// camera still takes over the Social tab full-bleed here; the takeover's *look* — dark
    /// `sceneBackground`, suppressed bottom scrim, and the landscape tab-bar hide — is applied by
    /// the modifiers in `mainInterface` that read `isDisposableCameraSessionActive`, entirely
    /// independent of this slot's identity. Removing the swap also revives the connection-success
    /// overlay + haptic in `FriendsView.onChange(of: isInSession)`, which the old swap defeated by
    /// destroying that instance in the same transaction as the flip.
    private var mainTabContent: some View {
        pagedTabs
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
            PrivateHubView(store: store, periodStore: periodStore, intimacyStore: intimacyStore, periodContext: periodContext, worryBox: worryBoxService, activeSheet: $activeSheet, section: $privateHubSection, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .personal))
                .tag(FernletTab.personal)
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        // Restore the "locked takeover" the old mainTabContent swap provided implicitly. With the
        // camera now rendered as the live `.social` PAGE (rather than a bare, TabView-less
        // SocialHubView), interactive paging is active beneath it — a stray horizontal drag would
        // swipe off the camera mid-session. That is worst in landscape, where the tab bar is hidden
        // and the session is meant to be fully locked. Disabling the page scroll only while the
        // camera session is active re-locks it without any identity change. The condition already
        // requires `selectedTab == .social`, so paging stays enabled everywhere else — including when
        // the user tap-navigates to another tab (in portrait) and swipes back toward Social.
        .scrollDisabled(isDisposableCameraSessionActive)
    }

    private var isDisposableCameraSessionActive: Bool {
        selectedTab == .social
            && store.meshNetworkManager.isInSession
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
                // Match the ~35 sibling sheets (all 20); the outlier 28 read visibly rounder. The
                // first-aid mockup's 30px is the inner content card, not the sheet presentation corner.
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
            LogIntimacySheet(intimacyStore: intimacyStore)
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

    /// Journal plaintext follows the `.privateHub` scope and nothing else. Written as an exhaustive
    /// switch (not a chain of `if case .unlocked`) so an unlock taken out on the progress-photo strip
    /// or the App-lock settings page lands in the DEACTIVATE branch rather than silently falling
    /// through and leaving journals decrypted from a previous hub session.
    private func applySealedJournalActivation(for lockState: FernletLockState) {
        switch lockState {
        case .unlocked(.privateHub):
            if let contentKey = lockService.contentKey(for: .privateHub) {
                store.activateSealedJournals(contentKey: contentKey)
            } else {
                store.deactivateSealedJournals()
            }
        case .unlocked, .locked:
            store.deactivateSealedJournals()
        case .notConfigured:
            store.activateNoLockJournals()
        }
    }

    private func drainPendingPeriodNarrativesIfUnlocked(_ lockState: FernletLockState) async {
        guard lockState.isUnlocked(for: .privateHub),
              let contentKey = lockService.contentKey(for: .privateHub) else {
            // Withholding the key is not enough: `periodStore.entries` still hold the DECRYPTED
            // narratives from the last hub session, and `prediction` feeds the Home tab's ungated
            // "cycle outlook" card. So a lock that isn't open for the hub — whether re-locked or
            // held by the photo strip / App-lock settings — has to drop them, exactly as the
            // visibility gate's `periodScrubHook` does. Skipped when no lock is configured, where
            // a nil content key is normal and the entries are the user's ordinary, ungated data.
            if lockState != .notConfigured { periodStore.scrubCycleState() }
            refreshPeriodContext()
            return
        }
        try? await periodStore.drainPendingBuffer(contentKey: contentKey)
        await periodStore.loadEntries(unlockedContentKey: contentKey)
        refreshPeriodContext()
    }

    /// Loads period entries with whatever content key is currently available (nil when locked / no lock),
    /// so the bridge has cycle data for phase resolution and trends.
    /// Wires the "delete everything" seams for the sealed stores `FernletStore` doesn't own. Each drops
    /// rows WITHOUT decrypting them, so deletion stays available even while the app is locked and the
    /// data itself is unreadable.
    ///
    /// Extracted from the launch `.task` rather than inlined: the closures pushed that already-large
    /// body past the type-checker's budget.
    private func attachDeleteAllHooks() {
        // `(try? …) != nil` rather than a bare `try?`: a throw here means the user's sealed rows are
        // still on disk, and the dialog promises they are gone. The failure has to reach the outcome.
        store.periodDataDeleteHook = { (try? MenstrualNarrativeRepository().deleteAll()) != nil }
        // Routed through the gated funnel rather than constructing a raw repository — every intimacy
        // touch goes through `IntimacyLogStore` (pinned by the app-target source grep in
        // `SensitiveSurfaceGateTests`). Its `deleteAll` is deliberately UNGATED (drops rows without
        // decrypting), so the wipe still works while hidden and while locked.
        store.intimacyDataDeleteHook = { [intimacyStore] in (try? intimacyStore.deleteAll()) != nil }
        store.journalDataDeleteHook = { (try? JournalNarrativeRepository().deleteAll()) != nil }
        // Cycle notes written while the app was locked live in a file, not in the rows above. The lock
        // service owns the buffer, so the store can only reach it through a hook.
        store.pendingNarrativeBufferPurgeHook = { [lockService] in
            (try? lockService.purgePendingNarratives()) != nil
        }
        store.healthKitSampleDeleteHook = { [storagePreferencesStore] in
            await HealthKitService(preferencesStore: storagePreferencesStore).deleteAllAuthoredSamples()
        }
        // The "Stop syncing, keep cloud data" copy: a full day blob left in the user's CloudKit zone with
        // sync off. `deleteAllCloudKitData` opens its own connection (no live sync session needed) and the
        // user already confirmed the wipe via the destructive dialog, so "DELETE" is passed programmatically.
        store.cloudCopyDeleteHook = {
            do {
                _ = try await CloudKitDataService().deleteAllCloudKitData(
                    confirmation: DeletionConfirmation(userTypedConfirmation: "DELETE")
                )
                return true
            } catch {
                return false
            }
        }
        // Persists the period re-upload deferral so the obligation survives relaunch. Routed through the
        // app's SINGLE StoragePreferencesStore instance — a second writer would leave its in-memory copy
        // stale and the next `update` would clobber the flag. The no-change guard keeps a launch-time
        // re-record from bumping `lastModifiedAt` (or minting a keychain row) for nothing.
        store.sealedBackupDeferralPersistHook = { [storagePreferencesStore] deferred in
            guard storagePreferencesStore.preferences.sealedBackupPeriodReuploadDeferred != deferred else { return }
            storagePreferencesStore.update { $0.sealedBackupPeriodReuploadDeferred = deferred }
        }
        store.storagePreferencesResetHook = { [storagePreferencesStore] keepSealedBackupFlags, keepCloudCopyFlag in
            // Two preferences survive the reset, both because erasing them would BREAK the delete rather
            // than because they're worth keeping:
            //
            // - `iCloudSyncEnabled`: the local Core Data deletes reach the server by propagating over
            //   the still-live sync session. Flipping sync off here would tear that down first and
            //   strand the server copy, ready to sync straight back when the user next turned iCloud on.
            // - the sealed-backup flags, ONLY when a backup delete just failed: they are how a retry
            //   finds the backup again. Clearing them would make a transient network failure permanent.
            //
            // Everything else — Health access, per-capability grants, backup exclusion — goes back to
            // first-launch defaults.
            let current = storagePreferencesStore.preferences
            var reset = StoragePreferences(iCloudSyncEnabled: current.iCloudSyncEnabled)
            if keepSealedBackupFlags {
                reset.sealedBackupSensitiveNotesEnabled = current.sealedBackupSensitiveNotesEnabled
                reset.sealedBackupPeriodEnabled = current.sealedBackupPeriodEnabled
            }
            // Same reasoning as the sealed-backup flags: keep `cloudCopyKept` only when the kept-copy
            // delete FAILED, so the retry the alert invites still knows there is a copy in iCloud to
            // remove. On success it clears to first-launch default (no copy left to point at).
            if keepCloudCopyFlag {
                reset.cloudCopyKept = current.cloudCopyKept
            }
            if reset == StoragePreferences(lastModifiedAt: reset.lastModifiedAt) {
                // Nothing worth preserving: drop the keychain row entirely, so not even a
                // `lastModifiedAt` survives as a trace of use.
                storagePreferencesStore.resetToDefaults()
            } else {
                storagePreferencesStore.update { $0 = reset }
            }
            // The store's write paths don't report failure; `true` here means "the reset ran" — the
            // hook's Bool exists so an UNWIRED funnel surfaces "your storage settings" instead of
            // silently leaving Health grants and backup flags as they were.
            return true
        }
    }

    private func loadPeriodEntriesIfPossible() async {
        await periodStore.loadEntries(unlockedContentKey: lockService.contentKey(for: .privateHub))
    }

    /// Recomputes the bridge's per-phase trends from current period data + the store's wellbeing scores.
    /// Phase resolution itself always reads the live period store, so this only refreshes the (optional)
    /// softening gate — staleness can only *withhold* softening, never apply it incorrectly.
    private func refreshPeriodContext() {
        guard let periodContext else { return }
        // Cycle narratives are Private Hub content: an unlock held by another surface is not one.
        let unlocked = lockService.isUnlocked(for: .privateHub)
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
        // Phase 4b: hearts ride the presence radio (the standalone heart listener is gone), so the
        // recipe listener chain hands straight off to the presence gate.
        updatePresenceListener()
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

    // Phase 3a: the clothing-shop listener chain that lived here is gone — the shop rides the friend
    // mesh (`MeshNetworkManager.clothingShop`), whose radio lifecycle is user-driven
    // (startJoin/leaveSession), and the `allowNearbyClothingShares` opt-out is payload-layer (providers
    // wired in FernletStore.meshNetworkManager). There is deliberately NO scene-dip clearing of the
    // shop's held catalogs: the post-session window outlives the session by design, and radio privacy
    // is the mesh lifecycle's job.

    /// Presence radio gating (mesh redesign Phase 4a/4b): runs only while opted in, foregrounded,
    /// unlocked, and on a main tab — driven from the same listener chain events as the recipe
    /// and heart listeners (tab / scene / lock changes all funnel through
    /// `updateRecipeShareListener`), plus a direct observation of the setting so toggling it ON
    /// in Settings starts the radio without waiting for the next scene event.
    private func updatePresenceListener() {
        if shouldRunPresence {
            store.presenceManager.start()
        } else {
            store.presenceManager.stop()
        }
        // Away-hearts drop sync (bitchat adoptions Increment 3): piggybacks the same
        // scene/tab/lock listener chain — reentrancy-guarded inside the service and a consent-
        // gated no-op while `heartsAwayDelivery` is off, so this costs nothing when unused.
        //
        // This chain fires on every tab switch, scene change and lock change, and each pass is a
        // full public-database round trip (account check + upload flush + a tag query per friend +
        // cleanup). `syncNow()` rate-limits itself to `HeartDropService.minimumSyncInterval` — the
        // floor lives in the service so every caller inherits it. Sends are unaffected: `queueHeart`
        // schedules its own pass directly, so a heart still leaves immediately.
        if scenePhase == .active {
            store.heartDropService.syncNow()
            // Consent is off but our own records may still be on the public database. Retrying here
            // is what keeps "off" eventually true; it self-cancels once nothing is outstanding.
            //
            // The condition is DERIVED (consent off AND the outbox still names uploaded records),
            // not a flag the toggle set, so this one call covers three cases the old wiring missed:
            // a purge that failed at toggle-off, a purge still owed from a PREVIOUS launch (a
            // process flag died with the process; the outbox did not), and consent withdrawn on
            // ANOTHER device — `heartsAwayDelivery` rides the synced snapshot, so it lands here as a
            // state change that never runs this device's setter. The launch `.task` reaches this
            // same chain (via `updateRecipeShareListener`), which is what makes the relaunch case
            // fire without waiting for a scene transition.
            store.retryHeartsAwayPurgeIfNeeded()
        }
    }

    /// Same tab set as hearts (Home/Food/Move/Social — everywhere but Private), same privacy
    /// posture: never while backgrounded or locked, and the opt-out setter
    /// (`FernletStore.setAllowNearbyPresence`) stops the radio immediately.
    private var shouldRunPresence: Bool {
        guard store.settings.allowNearbyPresence else { return false }
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
    /// The gated funnel for intimacy sealed-note reads. Owned by `ContentView`, threaded through
    /// `PrivateHubView`. Its `isVisible` is wired to the derived gate in `ContentView`'s launch task, so
    /// the `logs()` call in `loadIntimacyCalendar` decrypts nothing while intimacy tracking is hidden.
    var intimacyStore: IntimacyLogStore
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
            // Hiding must drop plaintext already on screen, not just refuse the next load — this view
            // holds decrypted logs in @State for as long as it stays in the hierarchy.
            .onChange(of: store.isIntimacyTrackingVisible) { _, visible in
                if !visible { scrubIntimacyState() }
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

    /// Drops the intimacy plaintext held in view state. Safe to call when already empty.
    private func scrubIntimacyState() {
        intimacyLogs = []
        intimacyEventsByDay = [:]
    }

    private func loadIntimacyCalendar() async {
        // Back-stop to the authoritative gate. The sealed-note decrypt is now gated at the seam by
        // `intimacyStore` (fail-closed), so this view-level check no longer guards the plaintext — but
        // it still does real extra work: it scrubs the logs already resident in @State (hiding
        // mid-session must drop them, not leave them readable until process death) and skips the
        // HealthKit read below, which the sealed store never covered.
        guard store.isIntimacyTrackingVisible else {
            scrubIntimacyState()
            return
        }
        let contentKey = lockService.contentKey(for: .privateHub)
        let localLogs: [IntimacyLog] = (try? intimacyStore.logs(contentKey: contentKey)) ?? []
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
