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
import PrivateStoreCore
import PeriodContextBridge
import HealthKitGateway
import FernletUI

/// The post-onboarding root shell: the five-tab pager, the single-active-sheet router, and the
/// app's runtime wiring hub.
///
/// Structure: `launchRoot` shows `LaunchScreen` until ``LaunchPreparationService`` finishes, then
/// the paged `TabView` (Home/Food/Move/Friends/Private) with the custom floating tab bar. All
/// modal surfaces flow through one `activeSheet: FernletSheet?` slot (plus dedicated slots for the
/// connection inspector and incoming proximity recipe shares), with dismiss-then-represent
/// chaining for editor and First Aid handoffs.
///
/// Wiring owned here (mostly in the launch `.task`): the sensitive-surface visibility gates
/// injected into `PeriodTrackerStore`/`IntimacyLogStore` BEFORE any load, the
/// `PeriodContextBridge` and `StressService` scoring contexts, the lock-state → sealed-journal
/// activation plumbing, the Worry Box seams, every "delete everything" hook the store can't reach
/// itself (`attachDeleteAllHooks`), the widget bridge, and the proximity listener lifecycles
/// (recipe shares, presence radio, heart-drop sync, friends discovery) gated on tab + scene +
/// lock. Notification and App Intent deep-links are consumed through
/// `consumePendingNotificationSheet`.
///
/// Invariants: `mainTabContent` must keep a single structural identity (swapping view types in
/// that slot destroys every tab's @State — see its doc), and scrubs key off derived gate VALUES
/// (`sensitiveSurfaceVisibility`), not the setters, so every writer is covered.
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
    /// The injected capture-friction state (screenshot pulse + capture cover; friction, never a
    /// security control). Read here only to RE-INJECT it into the sheet cases that host protected
    /// surfaces (`.journal`, `.logPeriod`, `.logIntimacy`), matching the explicit per-sheet
    /// environment convention used for `lockService` — a missing environment object in a sheet is
    /// a runtime crash, not a compile error.
    @Environment(CaptureProtectionState.self) private var captureProtection
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
    /// The ONE in-flight period drain/load. Every trigger (lock transitions, `.logPeriod` dismissals)
    /// cancels and replaces it, so completions can never land out of order and re-populate `entries`
    /// after a scrub — the load captures its content key by value and cannot notice a later lock.
    @State private var periodLoadTask: Task<Void, Never>?
    /// Reentrancy latch for the hub-unlock sealed-backup settle. Unlock/lock/unlock used to run two
    /// full CloudKit restore + re-upload passes concurrently; a second call is a no-op while one is in
    /// flight (rather than a cancel, which must never interrupt a restore mid-write).
    @State private var isSettlingSealedBackups = false
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        rootSheetHost
            .onChange(of: activeSheet?.id) { oldID, newID in
                handleActiveSheetIDChange(oldID: oldID, newID: newID)
            }
            .onChange(of: lockService.state) { _, newState in
                handleLockStateChange(newState)
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
            // The duress flag needs its OWN observer, not just the lock-state one above: the duress
            // branches of `changeCredential` and `setBiometricEnabled` fire while the user is
            // already standing on an unlocked App-lock settings screen, so they set `state` to the
            // value it already holds and `.onChange(of: lockService.state)` never runs. Watching the
            // flag directly covers every way it can flip, including the real-passcode unlock that
            // clears it.
            .onChange(of: lockService.isDuressSessionActive) { _, active in
                store.duressSessionActive = active
            }
            .task { await performLaunchWiring() }
            .onChange(of: selectedTab) { oldTab, newTab in
                handleTabChange(from: oldTab, to: newTab)
            }
            .onChange(of: scenePhase) { _, phase in
                handleScenePhaseChange(phase)
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
            .alert("Turn on Nearby Friends?", isPresented: presenceEnablePromptBinding) {
                Button("Turn on") {
                    store.setAllowNearbyPresence(true)
                    updatePresenceListener()
                }
                Button("Not now", role: .cancel) {}
            } message: {
                Text("See when friends you've kept are nearby. Fernlet broadcasts only rotating tags that your friends' devices can recognize — never your name or a stable ID — and only while the app is open. You can change this anytime in Settings.")
            }
    }

    /// `launchRoot` plus the three root-presented sheet slots — the single `activeSheet` router, the
    /// connection inspector, and an incoming proximity recipe share — in their original order.
    ///
    /// Split out of `body` for length only; the modifier chain is byte-for-byte the one `body` used
    /// to carry, so presentation identity and ordering are unchanged.
    private var rootSheetHost: some View {
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
    }

    /// One-time "first kept friend" presence offer (Phase 4a), driven by observable store state.
    private var presenceEnablePromptBinding: Binding<Bool> {
        Binding(
            get: { store.presenceEnablePromptRequested },
            set: { if !$0 { store.presenceEnablePromptRequested = false } }
        )
    }

    /// Logging/editing a period event persists to HealthKit but doesn't mutate the in-memory entries,
    /// so reload + refresh when the period sheet dismisses to keep the chip/outlook/trends/score
    /// current (catches logging from Home or the period screen alike).
    private func handleActiveSheetIDChange(oldID: String?, newID: String?) {
        guard newID == nil, oldID == "logPeriod" else { return }
        // Cancel-and-replace on the ONE period-load handle (R3): a dismissal per sheet used to spawn
        // an un-deduplicated task, and the older one could land after a lock and re-populate entries.
        periodLoadTask?.cancel()
        periodLoadTask = Task {
            await loadPeriodEntriesIfPossible()
            settlePeriodEntriesAfterLoad()
        }
    }

    private func handleLockStateChange(_ newState: FernletLockState) {
        store.lockState = newState
        // The decoy's app half (P7): a duress unlock arrives as an ordinary `.unlocked`
        // transition, so this is where the store learns the difference. Mirroring the flag
        // rather than branching per view is the point — the sensitive-visibility getters
        // AND it in, and the whole existing hide machinery follows from there.
        store.duressSessionActive = lockService.isDuressSessionActive
        // One in-flight drain/load at a time (R3). Every lock transition used to add another
        // unstructured task, and the loser of that race could write cycle plaintext AFTER a scrub.
        periodLoadTask?.cancel()
        periodLoadTask = Task { await drainPendingPeriodNarrativesIfUnlocked(newState) }
        applySealedJournalActivation(for: newState)
        worryBoxService.updateActivation(
            lockState: newState,
            contentKey: lockService.contentKey(for: .privateHub)
        )
        // Every paged sealed backup is sealed under the hub's content key, so turning one on
        // from Settings (reached from Home, where the hub is always re-locked) can only ever
        // DEFER the upload. This is the moment that debt can be paid: the hub just unlocked,
        // so the sealed stores are readable. No-op unless a deferral is actually outstanding.
        //
        // It is also the only moment a journal/intimacy RESTORE can decrypt what it pulls down,
        // so the targeted restores run here too — and strictly BEFORE the re-uploads, because a
        // re-upload from a not-yet-restored store would replace the good cloud backup with an
        // empty chunk set. The re-uploads re-check `mayReuploadFromLocalStore` regardless.
        if newState.isUnlocked(for: .privateHub) {
            Task { await settleSealedBackupsAfterHubUnlock() }
        }
        updateRecipeShareListener()
    }

    private func handleTabChange(from oldTab: FernletTab, to newTab: FernletTab) {
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

    private func handleScenePhaseChange(_ phase: ScenePhase) {
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
            // handler is the primary path, but if a token is present when the scene reactivates
            // (and within its expiry window), honor it here too.
            consumePendingNotificationSheet()
            if selectedTab == .social { startFriendsDiscovery() }
        } else if selectedTab == .social {
            stopFriendsDiscovery()
        }
        updateRecipeShareListener()
    }

    // MARK: - Launch wiring

    /// Everything the root `.task` does, in its original order: the sensitive-surface gates and
    /// scoring contexts first (before any load can observe a missing gate), then the lock / worry-box
    /// activation and the delete-all hooks, then the post-launch sequence.
    private func performLaunchWiring() async {
        wireSensitiveGatesAndScoringContexts()
        wireLockAndWorryBox()
        await runPostLaunchSequence()
    }

    /// The hard visibility gates and the two scoring contexts (period bridge, body signals).
    ///
    /// Runs before ANY load: `PeriodTrackerStore`/`IntimacyLogStore` must never perform a decrypt or a
    /// HealthKit read before their `isVisible` closures exist.
    private func wireSensitiveGatesAndScoringContexts() {
        periodStore.attachLockService(lockService)
        // Before the visibility closures below are wired and before the first scrub, so no
        // load can observe a stale `false` (the flag is process-lifetime and never
        // persisted, so at launch this is only ever a mirror of `false` — it is here for
        // the invariant, not for a case that exists today).
        store.duressSessionActive = lockService.isDuressSessionActive
        // Retire a duress-recovery enrollment this device's identity has outlived, before
        // anything can arm or fire the response over it. Cheap (two keychain reads and a
        // comparison when an enrollment exists, one when it does not) and idempotent; the
        // delete-all funnel fires the same reconcile in-line via `identityRotatedHook`, and
        // this is the backstop for a rotation from any other route — including a wipe whose
        // process died before the hook ran.
        DuressRecoveryCoordinator(
            identity: IdentityService(),
            lockService: lockService
        ).reconcileEnrollmentWithLocalIdentity()
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
    }

    /// Mirrors the initial lock state into the store, activates the sealed journal / worry-box seams
    /// for it, and attaches the delete-all hooks (plus the DEBUG demo seed).
    private func wireLockAndWorryBox() {
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
    }

    /// The asynchronous half of launch: the brief settle, the optional Health auto-imports, launch
    /// preparation, deep-link consumption, the listener/widget wiring, and the first period + body
    /// signals refresh.
    private func runPostLaunchSequence() async {
        do {
            try await Task.sleep(for: .milliseconds(120))
        } catch {
            // Cancelled with the view's `.task`: nothing below should wire a torn-down view.
            return
        }
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
        // view finished preparing — open it now (live taps arrive via the onReceive handlers).
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
        settlePeriodEntriesAfterLoad()
        await stressService.refreshIfNeeded()
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

    /// True while any ROOT-presented sheet is covering the tab pages: the `activeSheet` router
    /// (Settings, Trends, First Aid, the logging sheets, …), the connection inspector, or an
    /// incoming recipe-share review. Composed into the Private hub's capture-friction
    /// `isFrontmost` — the hub stays alive beneath a root sheet, so a screenshot taken while an
    /// unprotected sheet covers the Personal tab must not spend the once-per-session nudge on a
    /// banner nobody can see. The recipe-share slot presents only while `activeSheet` is nil, so
    /// checking the pending queue directly covers it in both states.
    private var rootSheetIsCoveringTabs: Bool {
        activeSheet != nil
            || store.showConnectionInspector
            || store.recipeShareManager.pendingRecipeShares.first != nil
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
            // `!rootSheetIsCoveringTabs`: the hub stays alive beneath a root-presented sheet, so
            // its capture-friction pulse must not fire (and spend the once-per-session nudge
            // invisibly) while an unprotected sheet — Settings, Trends, First Aid from a
            // notification tap, an incoming recipe share — fully covers the Personal tab. The
            // protected sheets claim the nudge themselves, visibly, via their own attachments.
            PrivateHubView(store: store, periodStore: periodStore, intimacyStore: intimacyStore, periodContext: periodContext, worryBox: worryBoxService, activeSheet: $activeSheet, section: $privateHubSection, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .personal), isFrontmost: selectedTab == .personal && !rootSheetIsCoveringTabs)
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

    /// Routes a sheet case to its family builder. Split per family (not per case) because the flat
    /// 22-case switch was one 128-line function; each family below keeps the exact view, anchor,
    /// detents and environment injections the flat switch used.
    @ViewBuilder
    private func sheetContent(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .meal, .recipe, .water, .sleep, .journal, .quickExercise,
             .workout, .workoutSuggestion, .goals, .hygiene:
            loggingSheet(for: sheet)
        case .settings, .recipeBook, .trends, .stressExplainer, .firstAid:
            librarySheet(for: sheet)
        case .logPeriod, .logIntimacy:
            privateSheet(for: sheet)
        case .editRecipe, .editSavedRecipe:
            recipeEditorSheet(for: sheet)
        }
    }

    /// The quick-log family: meal, recipe, water, sleep, journal, exercise, workout(s), goals, hygiene.
    @ViewBuilder
    private func loggingSheet(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .meal:
            MealSheet(store: store, onLogged: showMealLogNotification)
                .fernletSheetChrome(anchor: "sheet.meal", detents: [.medium, .large])
        case .recipe:
            RecipeSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.recipe", detents: [.large])
        case .water:
            WaterSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.water", detents: [.medium])
        case .sleep:
            SleepSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.sleep", detents: [.medium])
        case .journal:
            JournalSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.journal", detents: [.medium, .large])
                .environment(captureProtection)
        case .quickExercise:
            QuickExerciseSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.quickExercise", detents: [.medium, .large])
        case .workout:
            WorkoutSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.workout", detents: [.large])
        case .workoutSuggestion:
            WorkoutSuggestionSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.workoutSuggestion", detents: [.medium, .large])
        case .goals:
            GoalsSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.goals", detents: [.large])
        case .hygiene:
            HygieneSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.hygiene", detents: [.medium, .large])
        default:
            EmptyView()
        }
    }

    /// The reference/library family: settings, recipe book, trends, the body-signals explainer, and
    /// First Aid. (First Aid's corner radius matches the ~35 sibling sheets at 20; the first-aid
    /// mockup's 30px is the inner content card, not the sheet presentation corner.)
    @ViewBuilder
    private func librarySheet(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .settings:
            SettingsSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.settings", detents: [.large])
                .environment(lockService)
                .environment(storagePreferencesStore)
        case .recipeBook:
            RecipeBookSheet(store: store, editingRecipe: $editingRecipeFromHome, editingSavedRecipe: $editingSavedRecipeFromHome)
                .fernletSheetChrome(anchor: "sheet.recipeBook", detents: [.large])
        case .trends:
            TrendsModal(signals: store.derivedSignals)
                .fernletSheetChrome(anchor: "sheet.trends", detents: [.large])
        case .stressExplainer:
            StressExplainerSheet(assessment: stressService.assessment, onFirstAid: {
                // Chain into First Aid via the dismiss-then-represent pattern (single-active sheet).
                pendingFirstAidAfterDismiss = true
                activeSheet = nil
            })
                .fernletSheetChrome(anchor: "sheet.stressExplainer", detents: [.medium, .large])
        case .firstAid(let tool):
            FirstAidView(store: store, worryBox: worryBoxService, initialTool: tool)
                .fernletSheetChrome(anchor: "sheet.firstAid", detents: [.large])
                .environment(storagePreferencesStore)
        default:
            EmptyView()
        }
    }

    /// The Private-hub family: the two sealed logging sheets, which additionally carry the lock
    /// service and the capture-friction state (a missing environment object here is a runtime crash).
    @ViewBuilder
    private func privateSheet(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .logPeriod(let targetDate, let editingEntry):
            LogPeriodSheet(periodStore: periodStore, targetDate: targetDate, editingEntry: editingEntry)
                .fernletSheetChrome(anchor: "sheet.logPeriod", detents: [.large])
                .environment(lockService)
                .environment(captureProtection)
        case .logIntimacy:
            LogIntimacySheet(intimacyStore: intimacyStore)
                .fernletSheetChrome(anchor: "sheet.logIntimacy", detents: [.large])
                .environment(lockService)
                .environment(storagePreferencesStore)
                .environment(captureProtection)
        default:
            EmptyView()
        }
    }

    /// The recipe editor family, reached by the dismiss-then-represent chain from the recipe book.
    @ViewBuilder
    private func recipeEditorSheet(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .editRecipe(let recipe):
            RecipeSheet(store: store, recipe: recipe)
                .fernletSheetChrome(anchor: "sheet.editRecipe", detents: [.large])
        case .editSavedRecipe(let recipe):
            SavedRecipeNotesSheet(store: store, recipe: recipe)
                .fernletSheetChrome(anchor: "sheet.editSavedRecipe", detents: [.medium, .large])
        default:
            EmptyView()
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
            // Health profile import is optional; manual settings remain the fallback. Event name plus
            // the error only — never a health value.
            FernletAuditLog.log("health.profileAutoImportSkipped", context: ["error": String(describing: error)])
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
            FernletAuditLog.log("health.contextAutoImportSkipped", context: ["error": String(describing: error)])
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
        do {
            try await periodStore.drainPendingBuffer(contentKey: contentKey)
        } catch {
            // Benign for THIS call — the callee purges the pending buffer only after every insert
            // succeeds, so the notes are retained and re-drained at the next hub unlock. The audit
            // line is the recovery: a persistently failing drain would otherwise be invisible forever.
            FernletAuditLog.log("periodNarratives.pendingDrainFailed", context: ["error": String(describing: error)])
        }
        await periodStore.loadEntries(unlockedContentKey: contentKey)
        settlePeriodEntriesAfterLoad()
    }

    /// The post-`await` gate every period load runs through.
    ///
    /// `loadEntries` captures its content key BY VALUE and assigns `entries`/`prediction` after a
    /// HealthKit round trip, so a lock that lands while it is suspended (auto-lock on background, a
    /// manual re-lock, a duress wipe) would otherwise leave decrypted cycle plaintext resident — and
    /// `prediction` feeds the ungated Home outlook card. Re-checking the LIVE lock state here scrubs
    /// exactly that window. `.notConfigured` is untouched: with no lock, the entries are the user's
    /// ordinary, ungated data.
    private func settlePeriodEntriesAfterLoad() {
        let state = lockService.state
        if state != .notConfigured, !state.isUnlocked(for: .privateHub) {
            periodStore.scrubCycleState()
        }
        refreshPeriodContext()
    }

    /// Settles the sealed backups whose payloads are sealed under the `.privateHub` content key, at the
    /// one moment that key is live.
    ///
    /// Both halves are needed and the ORDER is the invariant. The Privacy & Data toggles are reached
    /// from Home, where the hub is always re-locked, so turning journal/intimacy backup on can only
    /// ever DEFER — and the launch restore pass runs while locked, so its journal/intimacy arms defer
    /// too. This unlock is the only production seam where both debts can actually be paid.
    ///
    /// **Restore before re-upload.** Each targeted restore is `.payloadStoreOnly` (it keeps the
    /// per-payload store-empty check and the one-way divergence latch, so it can only ADD data back),
    /// and each re-upload runs afterwards behind `mayReuploadFromLocalStore`, so a store this device
    /// has not restored into yet can never replace the cloud backup with the single empty head record
    /// `reconcileChunked` writes for a count of 0.
    private func settleSealedBackupsAfterHubUnlock() async {
        // Bounded fan-out (R3): one settle pass at a time. The work is idempotent, so a second unlock
        // arriving mid-pass has nothing to add — and cancelling the in-flight one would risk
        // interrupting a restore rather than duplicating a round trip.
        guard !isSettlingSealedBackups else { return }
        isSettlingSealedBackups = true
        defer { isSettlingSealedBackups = false }
        let preferences = storagePreferencesStore.preferences
        if preferences.iCloudSyncEnabled {
            if preferences.sealedBackupJournalEnabled {
                _ = await store.restoreJournalBackupTargeted()
            }
            // The intimacy gate is re-checked inside the targeted restore too (fail-closed at the
            // decrypt seam); this is the cheap pre-check that avoids the CloudKit fetch entirely.
            if preferences.sealedBackupIntimacyEnabled, store.isIntimacyTrackingVisible {
                _ = await store.restoreIntimacyBackupTargeted()
            }
        }
        await store.retryDeferredSealedPeriodBackupIfNeeded()
        await store.retryDeferredSealedBackupIfNeeded(payloadType: .journalNarratives)
        await store.retryDeferredSealedBackupIfNeeded(payloadType: .intimacyLogs)
    }

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
        // The residue half of the wipe: the row hooks above empty the sealed store, this destroys
        // and re-creates the FILE they lived in so the freed pages and `-wal` frames go with it.
        // Keyless like the row deletes (it never touches the content key), so it works while the
        // app is locked. `.shared` because that is the one on-device sealed store every sealed
        // repository above writes through.
        store.sealedStoreRebuildHook = {
            (try? PrivatePersistenceController.shared.rebuildStore()) != nil
        }
        store.healthKitSampleDeleteHook = { [storagePreferencesStore] in
            await HealthKitService(preferencesStore: storagePreferencesStore).deleteAllAuthoredSamples()
        }
        // The duress WIPE's durable half (P7). The crypto-erase already happened inside the lock
        // service before this runs, so this is cleanup, not the guarantee — it drops the sealed rows,
        // the day blob and the cloud copies through the ONE audited deletion funnel rather than
        // growing a second one. Fire-and-forget: nothing waits on it, and a failure leaves a device
        // whose data is unopenable rather than a device that is still readable.
        //
        // `includingHealthKitSamples: true` deliberately. The cycle and intimate-activity SAMPLES
        // live in HealthKit, outside everything the content key seals — leaving them would hand a
        // coercer the Health app with the exact data the wipe exists to remove. This is the one
        // caller that never asks: a duress wipe has no dialog to ask on.
        lockService.duressPurgeHook = { [store] in
            Task { _ = await store.deleteAllData(includingHealthKitSamples: true) }
        }
        // The other half of the duress-recovery custody story, and the one that is NOT a duress path
        // at all: "Delete everything" regenerates this device's proximity identity while deliberately
        // keeping the app lock, and the recovery blob is sealed with the OLD identity key mixed into
        // its derivation. Reconciling here retires an enrollment the wipe just made unopenable, so
        // `DuressMode.recoveryLock` can neither stay armed nor be re-armed over it. Runs at launch
        // too (see the `.task` below), which covers a rotation from any other route.
        store.identityRotatedHook = { [lockService] in
            DuressRecoveryCoordinator(
                identity: IdentityService(),
                lockService: lockService
            ).reconcileEnrollmentWithLocalIdentity()
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
                // The `false` is what the funnel surfaces as "your iCloud copy"; the log line is what
                // makes the REASON (not signed in vs. network vs. CKError) recoverable afterwards.
                FernletAuditLog.log("deleteAll.cloudCopyDeleteFailed", context: ["error": String(describing: error)])
                return false
            }
        }
        // Both preference hooks forward to the static helpers below (see their docs for the
        // single-writer and keep-what-a-retry-needs invariants).
        store.sealedBackupDeferralPersistHook = { [storagePreferencesStore] deferred, payloadType in
            Self.persistSealedBackupDeferral(deferred, payloadType: payloadType, in: storagePreferencesStore)
        }
        store.storagePreferencesResetHook = { [storagePreferencesStore] keepSealedBackupFlags, keepCloudCopyFlag in
            Self.resetStoragePreferencesAfterWipe(
                keepSealedBackupFlags: keepSealedBackupFlags,
                keepCloudCopyFlag: keepCloudCopyFlag,
                in: storagePreferencesStore
            )
        }
    }

    /// Persists the per-payload re-upload deferral so the obligation survives relaunch. Routed through
    /// the app's SINGLE `StoragePreferencesStore` instance — a second writer would leave its in-memory
    /// copy stale and the next `update` would clobber the flag. The no-change guard keeps a launch-time
    /// re-record from bumping `lastModifiedAt` (or minting a keychain row) for nothing.
    ///
    /// `static` with an explicit store parameter so the escaping hook stored on `FernletStore` never
    /// captures the `ContentView` value.
    private static func persistSealedBackupDeferral(
        _ deferred: Bool,
        payloadType: SealedBackupPayloadType,
        in preferencesStore: StoragePreferencesStore
    ) {
        let current = preferencesStore.preferences
        switch payloadType {
        case .periodData:
            guard current.sealedBackupPeriodReuploadDeferred != deferred else { return }
            preferencesStore.update { $0.sealedBackupPeriodReuploadDeferred = deferred }
        case .journalNarratives:
            guard current.sealedBackupJournalReuploadDeferred != deferred else { return }
            preferencesStore.update { $0.sealedBackupJournalReuploadDeferred = deferred }
        case .intimacyLogs:
            guard current.sealedBackupIntimacyReuploadDeferred != deferred else { return }
            preferencesStore.update { $0.sealedBackupIntimacyReuploadDeferred = deferred }
        case .sensitiveNotes:
            // No deferral exists for the whole-store overwrite payload — the store never records
            // one, so this arm is unreachable and deliberately writes nothing.
            return
        }
    }

    /// Resets storage preferences to first-launch defaults after a wipe, preserving exactly the two
    /// things whose erasure would BREAK the delete rather than complete it.
    ///
    /// - `iCloudSyncEnabled`: the local Core Data deletes reach the server by propagating over the
    ///   still-live sync session. Flipping sync off here would tear that down first and strand the
    ///   server copy, ready to sync straight back when the user next turned iCloud on.
    /// - the sealed-backup flags, ONLY when a backup delete just failed: they are how a retry finds
    ///   the backup again. Clearing them would make a transient network failure permanent.
    ///
    /// Everything else — Health access, per-capability grants, backup exclusion — goes back to
    /// first-launch defaults. Returns `true` meaning "the reset ran": the store's write paths don't
    /// report failure, and the hook's Bool exists so an UNWIRED funnel surfaces "your storage
    /// settings" instead of silently leaving Health grants and backup flags as they were.
    private static func resetStoragePreferencesAfterWipe(
        keepSealedBackupFlags: Bool,
        keepCloudCopyFlag: Bool,
        in preferencesStore: StoragePreferencesStore
    ) -> Bool {
        let current = preferencesStore.preferences
        var reset = StoragePreferences(iCloudSyncEnabled: current.iCloudSyncEnabled)
        // Every payload flag, assigned in ONE place next to `hasSealedBackup` rather than
        // open-coded here: the open-coded version silently dropped the journal and intimacy flags
        // when Phase 3 added them, which would have abandoned those CKRecords after a failed
        // delete (`hasSealedBackup` false → no retry, no later wipe, ever finds them again).
        if keepSealedBackupFlags {
            reset.copySealedBackupFlags(from: current)
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
            preferencesStore.resetToDefaults()
        } else {
            preferencesStore.update { $0 = reset }
        }
        return true
    }

    /// Loads period entries with whatever content key is currently available (nil when locked / no lock),
    /// so the bridge has cycle data for phase resolution and trends.
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
            // Health context refresh is opportunistic and should never block tab navigation — but a
            // tab that never refreshes has to be diagnosable.
            FernletAuditLog.log("health.contextRefreshSkipped", context: ["tab": tab.title, "error": String(describing: error)])
        }
    }

    private func showMealLogNotification(_ meals: [Meal]) {
        guard meals.isEmpty == false else { return }
        let notification = MealLogNotification(meals: meals)
        mealLogNotification = notification
        selectedTab = .home

        Task { @MainActor in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                // Cancelled: leave the toast to whatever superseded this one (the id check below is
                // the same supersede rule).
                return
            }
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
            do {
                try await Task.sleep(for: .seconds(5 * 60))
            } catch {
                // Cancellation means the timeout was superseded (`stopFriendsDiscovery`, or a new
                // discovery start), so returning WITHOUT `stopJoin()` is the intended behavior.
                return
            }
            guard !manager.isInSession else { return }
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

extension View {
    /// The presentation chrome every routed sheet shares: the UX-test screen anchor, the detent set,
    /// a visible drag indicator, and the house 20pt presentation corner radius.
    ///
    /// One modifier rather than the same four lines repeated per case — the values are identical
    /// across all 22 sheets except the anchor and the detents.
    func fernletSheetChrome(anchor: String, detents: Set<PresentationDetent>) -> some View {
        uxScreenAnchor(anchor)
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
    }
}

/// The payload behind the transient "meal logged" toast: a title plus the summed macros.
///
/// Built by `ContentView.showMealLogNotification` from the meals a sheet just logged; the fresh
/// `id` per instance is what lets a newer toast supersede an older one's auto-dismiss timer.
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

/// The top-overlay toast card for a just-logged meal: checkmark, title, and a P/C/F macro line.
///
/// Presented by ``ContentView`` for ~3 seconds after a meal sheet reports a log; purely
/// presentational (the timing and dismissal live with the presenting view).
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

/// The calm launch/loading screen: a time-of-day greeting, a rotating status line, and (once the
/// store exists) the pulsing companion.
///
/// Shown twice per cold launch — by ``FernletApp`` while ``FernletStoreLoader`` runs (no
/// companion) and by ``ContentView`` while ``LaunchPreparationService`` prepares (with the
/// companion). Status text falls back to `LaunchPreparationService.initialStatusMessage` so the
/// line never renders empty.
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

#Preview {
    ContentView(store: FernletStore())
}
