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
/// connection inspector, incoming proximity recipe shares, and the meal-logged toast's Adjust
/// correction sheet), with dismiss-then-represent chaining for editor and First Aid handoffs.
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
    @AppStorage(FernletThemeDefaults.customLightBackgroundKey) private var customLightBackgroundHex = FernletThemeDefaults.lightBackgroundHex
    @AppStorage(FernletThemeDefaults.customDarkBackgroundKey) private var customDarkBackgroundHex = FernletThemeDefaults.darkBackgroundHex
    @State private var selectedTab: FernletTab = .home
    @State private var privateHubSection: PrivateHubSection = .journal
    @State private var isHomeTabBarCompact = false
    /// The floating tab bar's live measured height (the whole `safeAreaInset` block), fed to the
    /// pages as `\.fernletTabBarClearance` so their scroll content ends clear of the bar.
    @State private var tabBarMeasuredHeight: CGFloat = 0
    @State private var tabResetTokens: [FernletTab: Int] = Dictionary(uniqueKeysWithValues: FernletTab.allCases.map { ($0, 0) })
    @State private var activeSheet: FernletSheet?
    @State private var mealLogNotification: MealLogNotification?
    /// The just-logged meal the toast's "Adjust" action opens the correction sheet for — a local
    /// `.sheet(item:)` slot beside the `activeSheet` router (the toast fires only after the logging
    /// sheet has dismissed, so the two slots never race).
    @State private var adjustingLoggedMeal: Meal?
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
    /// Read by ``customTabBar`` (at accessibility text sizes the five labels break mid-word —
    /// "Hom/e", "Frien/ds" — and the bar swallows a fifth of the screen, so they stop being drawn)
    /// and by the `.workout` route (3b·AX3: the sheet opens `.large` when the kind chips can no
    /// longer fit the medium detent).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    var body: some View {
        rootSheetHost
            .onChange(of: activeSheet?.id) { oldID, newID in
                handleActiveSheetIDChange(oldID: oldID, newID: newID)
            }
            .onChange(of: lockService.state) { _, newState in
                handleLockStateChange(newState)
            }
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

    /// `launchRoot` plus the four root-presented sheet slots — the single `activeSheet` router, the
    /// connection inspector, an incoming proximity recipe share, and the meal-logged toast's
    /// "Adjust" correction slot — in their original order.
    ///
    /// Split out of `body` for length only; the modifier chain is the one `body` used to carry
    /// (plus the FLOW-15 correction slot appended last), so presentation identity and ordering are
    /// unchanged for the pre-existing slots.
    ///
    /// Deliberately carries NO `preferredColorScheme`. Appearance is the app root's
    /// (`FernletApp`'s `WindowGroup` body, from ``FernletAppearanceMode``), because only the root
    /// covers the launch screen and onboarding too, and only the enum can pass `nil` for "System".
    /// This view used to pin `.dark`/`.light` off the pre-three-way `fernletDarkModeEnabled` Bool —
    /// a key nothing writes any more, so the modifier could only ever resolve `.light` and, if it
    /// won over the root's, would force every tab light while the App Store "Dark Interface" row
    /// says it does not. Do not re-add one here: a second `preferredColorScheme` on the same window
    /// makes the app's appearance depend on which preference write SwiftUI resolves last.
    private var rootSheetHost: some View {
        launchRoot
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
            // FLOW-15: the toast's "Adjust" action — the same correction sheet the meal row's
            // Adjust opens, presented from the root because the toast outlives the logging sheet.
            .sheet(item: $adjustingLoggedMeal) { meal in
                MealCorrectionSheet(store: store, meal: meal)
                    .fernletSheetChrome(anchor: "sheet.mealCorrection", detents: [.large])
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
        // R7: `true` means an enrollment this device's identity had outlived was actually retired
        // — a rare, security-relevant state change, so it is recorded rather than dropped.
        if DuressRecoveryCoordinator(
            identity: IdentityService(),
            lockService: lockService
        ).reconcileEnrollmentWithLocalIdentity() {
            FernletAuditLog.log("duress.recoveryEnrollment.retired", context: ["site": "launch"])
        }
        // Hard visibility gate. Injected before ANY load below: the store's own `.task` runs
        // on every cold launch, so wiring this later would let one full decrypt + HealthKit
        // read through before the gate existed.
        periodStore.attachVisibilityGate { [store] in store.isPeriodTrackingVisible }
        // The staleness half of the same gate: the cycle load awaits HealthKit, and the hub can lock
        // (or re-key) during that await. Wiring the live key here lets the store abandon a load whose
        // authorization expired mid-flight instead of publishing narratives decrypted with a key the
        // hub has since dropped.
        periodStore.attachLiveContentKeyProvider { [lockService] in lockService.contentKey(for: .privateHub) }
        // Same hard gate for the intimacy sealed-notes seam. `IntimacyLogStore` funnels every
        // decrypt/seal and is fail-closed by default, so wiring it here — before any read below —
        // is what turns the gate from "reads nothing" into "reads exactly when visible".
        intimacyStore.attachVisibilityGate { [store] in store.isIntimacyTrackingVisible }
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
            // The bar's measured height + 8pt breathing room, zeroed while the camera session
            // hides the bar. Consumed by fernletTabBarBottomClearance() on each page's scroll
            // content — the fix for the last card resting behind the floating bar at max scroll.
            .environment(
                \.fernletTabBarClearance,
                isDisposableCameraSessionActive ? 0 : tabBarMeasuredHeight + 8
            )
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
            // FLOW-15 (artboard 4b): the meal-logged toast sits at the BOTTOM, inside the tab-bar
            // `safeAreaInset` boundary below, so the bar's inset pushes it up — the toast and the
            // bar never cover each other. Attached after the scrim overlay so the toast draws over it.
            .overlay(alignment: .bottom) { mealLogToastOverlay }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: mealLogNotification?.id)
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
                        // Measure the bar's live block height for the pages' bottom clearance:
                        // this safeAreaInset positions the bar but does NOT reach the pages'
                        // scroll views through the UIKit-backed TabView, so each page ends its
                        // own scroll content clear of the bar via fernletTabBarBottomClearance().
                        .onGeometryChange(for: CGFloat.self) { proxy in
                            proxy.size.height
                        } action: { height in
                            tabBarMeasuredHeight = height
                        }
                }
            }
            .tint(Color.moss)
            .background(sceneBackground.ignoresSafeArea())
    }

    /// Always the five-tab `tabPages`, unconditionally — its structural identity must never
    /// change, or SwiftUI tears down and rebuilds every tab (losing all @State) on the swap.
    ///
    /// This used to be an `if isDisposableCameraSessionActive { SocialHubView(...) } else { tabPages }`.
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
        tabPages
    }

    /// True while any ROOT-presented sheet is covering the tab pages: the `activeSheet` router
    /// (Settings, Trends, First Aid, the logging sheets, …), the connection inspector, an
    /// incoming recipe-share review, or the toast's meal-correction slot. Composed into the
    /// Private hub's capture-friction `isFrontmost` — the hub stays alive beneath a root sheet,
    /// so a screenshot taken while an unprotected sheet covers the Personal tab must not spend
    /// the once-per-session nudge on a banner nobody can see. The recipe-share slot presents
    /// only while `activeSheet` is nil, so checking the pending queue directly covers it in
    /// both states.
    private var rootSheetIsCoveringTabs: Bool {
        activeSheet != nil
            || store.showConnectionInspector
            || store.recipeShareManager.pendingRecipeShares.first != nil
            || adjustingLoggedMeal != nil
    }

    private var tabPages: some View {
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
            .tabPage(.home)
            FoodView(store: store, onMealsLogged: showMealLogNotification, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .food))
                .tabPage(.food)
            MoveView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .move))
                .tabPage(.move)
            SocialHubView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .social))
                .tabPage(.social)
            // `!rootSheetIsCoveringTabs`: the hub stays alive beneath a root-presented sheet, so
            // its capture-friction pulse must not fire (and spend the once-per-session nudge
            // invisibly) while an unprotected sheet — Settings, Trends, First Aid from a
            // notification tap, an incoming recipe share — fully covers the Personal tab. The
            // protected sheets claim the nudge themselves, visibly, via their own attachments.
            PrivateHubView(store: store, periodStore: periodStore, intimacyStore: intimacyStore, periodContext: periodContext, worryBox: worryBoxService, activeSheet: $activeSheet, section: $privateHubSection, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .personal), isFrontmost: selectedTab == .personal && !rootSheetIsCoveringTabs)
                .tabPage(.personal)
        }
        // Paging is OFF: the floating tab bar is the navigation. `.page` style handed every
        // horizontal drag not swallowed by an inner scroller to the pager, so a drag on Home's
        // polaroid strip (hit-testing disabled), the mood row, or "Recent bites" flipped the user
        // onto Food mid-gesture. Making the strip hit-testable is not a fix — a non-scrolling view
        // still lets the pager take the drag — so the page style is gone entirely and tab switching
        // is deliberate (tab-bar taps only). That also subsumes the old camera-session special case
        // (`.scrollDisabled(isDisposableCameraSessionActive)`), which existed only to stop a stray
        // drag swiping off the live camera.
        //
        // Locking the *pager* with `.scrollDisabled(true)` is NOT the way to do this: that modifier
        // is an environment write, so it reached every scroll view underneath and froze all five
        // tabs' own feeds solid — content below the fold became permanently unreachable — and a
        // per-page `.scrollDisabled(false)` counter-write does not win against it. Structure, not
        // environment, is what keeps the drags and the scrolls apart.
        //
        // The plain style keeps every property `tabPages` is documented to need: one stable
        // container identity for all five tabs, `selection:` driven by the floating bar, and pages
        // that survive a tab switch with their @State intact. `tabPage(_:)` hides the system tab
        // bar this style would otherwise draw beneath the floating one.
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
        // The label is drawn only when there is room for it to stay one word: compacted (scrolled)
        // or at accessibility text sizes it is dropped visually and survives as the button's
        // VoiceOver label, which is what stops "Hom/e" / "Frien/ds" and the SF-Symbol announcements
        // ("leaf", "person.2") the hidden label used to leave behind.
        let hidesLabel = isCompact || dynamicTypeSize.isAccessibilitySize

        return HStack(spacing: isCompact ? 4 : 0) {
            ForEach(FernletTab.allCases) { tab in
                tabButton(tab, isCompact: isCompact, hidesLabel: hidesLabel)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isTabBar)
        .padding(.horizontal, isCompact ? 6 : 8)
        // T1-9: compact trimmed from 5 to 2 to compensate for each button's frame now carrying a
        // 44pt minimum height (was 38pt compacted) — keeps the floating bar's own footprint close
        // to its previous size (4+44=48, was 10+38=48) while the tap target inside it grows.
        // F5 correction: non-compact restored to its original 6 — the non-compact button already
        // measures ~58pt tall (icon + label + padding), so `minHeight: 44` is a no-op there and
        // trimming this padding shrank the bar's non-compact footprint by 6pt for zero accessibility
        // gain, an unreviewed density change.
        .padding(.vertical, isCompact ? 2 : 6)
        .frame(maxWidth: isCompact ? 300 : .infinity)
        .background(tabBarBackground, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                .stroke(Color.bark.opacity(0.08), lineWidth: 1)
        )
        .shadow(color: Color.bark.opacity(0.12), radius: isCompact ? 12 : 16, x: 0, y: isCompact ? 4 : 6)
        .padding(.horizontal, isCompact ? 40 : 20)
        .padding(.bottom, isCompact ? 4 : 12)
    }

    /// T3-13, folded into the T1-9 commit: Reduce Transparency asks system materials to be
    /// replaced with an opaque equivalent rather than merely dimmed — the tab bar is one of only
    /// four material surfaces in the tree, so this is a one-site fix rather than a wall.
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var tabBarBackground: AnyShapeStyle {
        reduceTransparency ? AnyShapeStyle(Color.parchment) : AnyShapeStyle(.regularMaterial)
    }

    /// One tab bar button — extracted from ``customTabBar`` (54 of 60 code lines on its own)
    /// before T1-9's 44pt frame and T3-13's material swap could land on top of it.
    private func tabButton(_ tab: FernletTab, isCompact: Bool, hidesLabel: Bool) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            VStack(spacing: hidesLabel ? 0 : 3) {
                Image(systemName: tab.systemImage)
                    // Scales with Dynamic Type instead of a fixed 18/20pt, so the bar's one
                    // remaining element grows with the user's text size.
                    .font(isCompact ? .body : .title3)
                    .frame(minHeight: isCompact ? 22 : 24)
                Text(verbatim: tab.title)
                    .font(.fernlet(.labelSmall))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .opacity(hidesLabel ? 0 : 1)
                    .frame(height: hidesLabel ? 0 : nil)
                    // Always hidden: the Button carries the title as its accessibility
                    // label, so VoiceOver reads it in every state (drawn or not) exactly once.
                    .accessibilityHidden(true)
            }
            // F1 fix: under Reduce Transparency `tabBarBackground` resolves to solid `Color.parchment`
            // (below), which is exactly the selected pill's own fill — the indicator went invisible
            // (1.00:1) for the low-vision users the accommodation serves, leaving hue-only (moss vs
            // slate) encoding. Swap to the existing filled-button pair instead of inventing a hex:
            // `mossFill` measures **4.67:1 against parchment** (well past the 3:1 non-text floor) and
            // its own `onMoss` ink measures 5.36:1 on it (clears 4.5:1 text too, for the non-compact
            // label). Both tokens are already adaptive, so dark mode (mossFill 6.65:1 on midnight)
            // needs no separate branch.
            // A5 carried finding (A2's review, §4.2). The `reduceTransparency` half above was fixed
            // and measured; the DEFAULT half was not. The selected pill fills with opaque
            // `Color.parchment` and the label under it is `.fernlet(.labelSmall)` — small text, so
            // the 4.5:1 floor applies — and `moss` on parchment measures **3.74:1**. Swapped to
            // `mossInk`, the already-approved deepened text variant of the same hue: **5.54:1 on
            // parchment**, unchanged in dark mode (dark `mossInk` and dark `moss` are the same
            // value), and it costs the pill nothing visually because the fill and the `.isSelected`
            // trait carry the selection, not the exact green.
            .foregroundStyle(isSelected ? (reduceTransparency ? Color.onMoss : Color.mossInk) : Color.slate)
            .frame(maxWidth: .infinity)
            .padding(.vertical, isCompact ? 8 : 9)
            .background(
                isSelected ? (reduceTransparency ? Color.mossFill : Color.parchment) : Color.clear,
                in: RoundedRectangle(cornerRadius: isCompact ? 14 : 16, style: .continuous)
            )
            .animation(.spring(response: 0.3, dampingFraction: 0.8), value: isSelected)
            // T1-9: AssistiveTouch, Switch Control and Eye Tracking all key off the element's own
            // frame, not the drawn pill — grows the tap target to 44pt without growing the visible
            // background (the outer bar's own padding above was trimmed to match).
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(verbatim: tab.title))
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // Settings is reachable from every tab (FLOW-34): the gear itself lives only on the
        // Home header, so a long press on the Home tab item opens it from wherever you are.
        // `simultaneousGesture` leaves the plain tap — switch tabs — untouched.
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                guard tab == .home else { return }
                selectedTab = .home
                activeSheet = .settings
            }
        )
    }

    /// Routes a sheet case to its family builder. Split per family (not per case) because the flat
    /// 22-case switch was one 128-line function; each family below keeps the exact view, anchor,
    /// detents and environment injections the flat switch used.
    @ViewBuilder
    private func sheetContent(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .meal, .recipe, .water, .sleep, .journal,
             .workout, .workoutSuggestion, .goals, .hygiene:
            loggingSheet(for: sheet)
        case .settings, .recipeBook, .trends, .milestones, .stressExplainer, .firstAid:
            librarySheet(for: sheet)
        case .logPeriod, .logIntimacy:
            privateSheet(for: sheet)
        case .editRecipe, .editSavedRecipe:
            recipeEditorSheet(for: sheet)
        }
    }

    /// The quick-log family: meal, recipe, water, sleep, journal, workout(s), goals, hygiene.
    /// (`.quickExercise` is retired — the Home Move tile now presents the Move tab's own
    /// `WorkoutSheet`, artboard 3b.)
    @ViewBuilder
    private func loggingSheet(for sheet: FernletSheet) -> some View {
        switch sheet {
        case .meal:
            // At accessibility sizes the six 80pt meal-type chips overflow the medium detent, so
            // the sheet opens .large instead of hiding a control (artboard 4a·AX3).
            MealSheet(store: store, onLogged: showMealLogNotification)
                .fernletSheetChrome(
                    anchor: "sheet.meal",
                    detents: dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large]
                )
        case .recipe:
            RecipeSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.recipe", detents: [.large])
        case .water:
            // [.medium, .large] per the 2026-08-21 template (artboard 2c): the whole task fits
            // above the medium line; the drag is for context, never for reaching a control.
            WaterSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.water", detents: [.medium, .large])
        case .sleep:
            // `[.medium, .large]` like Care: locked at medium the fourth quality option, the Hours
            // field and the Note field all sat below the fold behind the floating Save pill.
            SleepSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.sleep", detents: [.medium, .large])
        case .journal:
            // `[.large]`: at medium only one line of the editor cleared the feeling chips + prompt
            // card, and at accessibility sizes the editor and Save were entirely off-screen.
            JournalSheet(store: store)
                .fernletSheetChrome(anchor: "sheet.journal", detents: [.large])
                .environment(captureProtection)
        case .workout:
            // [.medium, .large] per artboards 1f/3b (2026-08-21): Kind, Recent and the search sit
            // above the medium line, so the quick path from the Home Move tile is never a sheet
            // the user has to drag open first. At accessibility sizes the 80pt kind chips plus the
            // primary no longer fit the 437pt medium detent, so the sheet opens .large instead of
            // hiding a control (artboard 3b·AX3).
            WorkoutSheet(store: store)
                .fernletSheetChrome(
                    anchor: "sheet.workout",
                    detents: dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large]
                )
        case .workoutSuggestion:
            // 1b·AX3: chips at 80pt plus the primary no longer fit the medium detent — grow the
            // sheet, never hide the control (both MoveView-side presenters do the same).
            WorkoutSuggestionSheet(store: store)
                .fernletSheetChrome(
                    anchor: "sheet.workoutSuggestion",
                    detents: dynamicTypeSize.isAccessibilitySize ? [.large] : [.medium, .large]
                )
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
            // onMealsLogged threads the FLOW-15 toast into the Home-presented book's Log pills —
            // without it those logs would land silently.
            RecipeBookSheet(
                store: store,
                editingRecipe: $editingRecipeFromHome,
                editingSavedRecipe: $editingSavedRecipeFromHome,
                onMealsLogged: showMealLogNotification
            )
            .fernletSheetChrome(anchor: "sheet.recipeBook", detents: [.large])
        case .trends:
            TrendsModal(signals: store.derivedSignals)
                .fernletSheetChrome(anchor: "sheet.trends", detents: [.large])
        case .milestones:
            // Artboard 3f: one rule for read-only destinations from Home — they present as large
            // sheets, matching Trends, First aid and the gear. MilestonesView carries its own
            // NavigationStack so the keepsake shelf pushes inside the sheet's own stack.
            MilestonesView(store: store)
                .fernletSheetChrome(anchor: "sheet.milestones", detents: [.large])
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
                // R7: the outcome is recorded on the store inside the call — that recording is the
                // restore banner and its Retry — so there is no decision left for this seam to make.
                _ = await store.restoreJournalBackupTargeted()
            }
            // The intimacy gate is re-checked inside the targeted restore too (fail-closed at the
            // decrypt seam); this is the cheap pre-check that avoids the CloudKit fetch entirely.
            if preferences.sealedBackupIntimacyEnabled, store.isIntimacyTrackingVisible {
                // Same as above: the outcome lands on the store's observable restore status.
                _ = await store.restoreIntimacyBackupTargeted()
            }
        }
        await store.retryDeferredSealedPeriodBackupIfNeeded()
        await store.retryDeferredSealedBackupIfNeeded(payloadType: .journalNarratives)
        await store.retryDeferredSealedBackupIfNeeded(payloadType: .intimacyLogs)
    }

    /// Wires the "delete everything" seams for the stores `FernletStore` doesn't own — the sealed
    /// repositories, the locked-note buffer, both store rebuilds, HealthKit, the duress purge, the
    /// identity reconcile, the preferences, and (via ``attachCloudDeleteAllHooks()``) CloudKit. The
    /// sealed row deletes drop rows WITHOUT decrypting them, so deletion stays available even while
    /// the app is locked and the data itself is unreadable.
    ///
    /// Extracted from the launch `.task` rather than inlined: the closures pushed that already-large
    /// body past the type-checker's budget.
    ///
    /// - Important: this function is part of the wipe path scanned by `PrivacyWipeCoverageTests` —
    ///   several of the funnel's real clears live only inside these closures. A hook wired here
    ///   needs its manifest token and doc row like any funnel leg.
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
        // The synced store's residue pass. Checkpoint + vacuum, NOT the sealed store's
        // destroy-and-re-add: this file carries the CloudKit mirror's pending export queue in its
        // persistent history, and destroying it would strand the server copy of the deletes that
        // have not shipped yet. `compactStoreAfterWipe()` is a no-op success on the in-memory
        // (`/dev/null`) store, so a preview/test container reports a clean pass rather than a
        // failure that means nothing there.
        store.mainStoreRebuildHook = {
            (try? await PersistenceController.shared.compactStoreAfterWipe()) != nil
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
        // Installed through the set-once seam: this closure is the wipe's durable half, and a later
        // writer replacing it would defuse the wipe silently.
        lockService.installDuressPurgeHook { [store] in
            Task { _ = await store.deleteAllData(includingHealthKitSamples: true) }
        }
        // The other half of the duress-recovery custody story, and the one that is NOT a duress path
        // at all: "Delete everything" regenerates this device's proximity identity while deliberately
        // keeping the app lock, and the recovery blob is sealed with the OLD identity key mixed into
        // its derivation. Reconciling here retires an enrollment the wipe just made unopenable, so
        // `DuressMode.recoveryLock` can neither stay armed nor be re-armed over it. Runs at launch
        // too (see the `.task` below), which covers a rotation from any other route.
        store.identityRotatedHook = { [lockService] in
            if DuressRecoveryCoordinator(
                identity: IdentityService(),
                lockService: lockService
            ).reconcileEnrollmentWithLocalIdentity() {
                FernletAuditLog.log("duress.recoveryEnrollment.retired", context: ["site": "identityRotated"])
            }
        }
        attachCloudDeleteAllHooks()
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

    /// The two direct-CloudKit legs of "delete everything" — split out of ``attachDeleteAllHooks()``
    /// for the Power-of-10 60-line rule, and kept together because they are the pair: between them
    /// they cover every server-side record the local row deletes cannot reach by propagating.
    ///
    /// Both pass "DELETE" programmatically: the user already confirmed the wipe on the destructive
    /// dialog, and neither call needs a live sync session (each opens its own connection).
    ///
    /// - Important: this function is part of the wipe path scanned by `PrivacyWipeCoverageTests`.
    ///   A new hook wired here needs its manifest token and doc row like any funnel leg.
    private func attachCloudDeleteAllHooks() {
        // The "Stop syncing, keep cloud data" copy: a full day blob left in the user's CloudKit zone
        // with sync off, which the funnel invokes only when `cloudCopyKept` is set.
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
        // The legacy direct-CloudKit records, which the hook above cannot reach: it runs only on the
        // "stop syncing, keep the copy" path, and a live sync deletes the server copy by propagating
        // the local row deletes — which the mirror can only do for the `CD_`-prefixed types it wrote
        // itself. Unconditional for that reason, which is why the service reports a missing iCloud
        // account as a clean sweep rather than a failure.
        store.legacyCloudRecordDeleteHook = {
            do {
                _ = try await CloudKitDataService().deleteLegacyDirectCloudKitRecords(
                    confirmation: DeletionConfirmation(userTypedConfirmation: "DELETE")
                )
                return true
            } catch {
                FernletAuditLog.log("deleteAll.legacyCloudDeleteFailed", context: ["error": String(describing: error)])
                return false
            }
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
    /// first-launch defaults. Returns whether the reset actually LANDED in the keychain: the
    /// row-delete path reports its `OSStatus` and the rewrite path reports `lastPersistError`, so a
    /// keychain that refused the write (most often `errSecInteractionNotAllowed`) surfaces as "your
    /// storage settings" in the funnel's incomplete list instead of a silently kept row. The hook's
    /// Bool also covers an UNWIRED funnel, which reports the same way.
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
            return preferencesStore.resetToDefaults()
        }
        preferencesStore.update { $0 = reset }
        // `update` publishes before it persists, so the keychain verdict is the store's own error
        // record — not the assignment above.
        return preferencesStore.lastPersistError == nil
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
            // `rawValue`, not `title`: an audit line is a diagnostic record, and `title` localizes.
            FernletAuditLog.log("health.contextRefreshSkipped",
                                context: ["tab": tab.rawValue, "error": String(describing: error)])
        }
    }

    private func showMealLogNotification(_ meals: [Meal]) {
        guard meals.isEmpty == false else { return }
        let notification = MealLogNotification(meals: meals)
        // Deliberately does NOT switch to Home. The toast overlays the tab pages, so it shows
        // over whichever tab the log started from; jumping to Home meant a meal logged from Food
        // landed the user on another tab and cost them a tab switch to check the match.
        mealLogNotification = notification

        // Read at post time, not at view construction: VoiceOver can be turned on mid-session.
        let window = FernletDismissalWindow.system.window(
            standard: .seconds(5),
            assistive: FernletDismissalWindow.assistiveActionWindow)
        Task { @MainActor in
            do {
                // 5 seconds (FLOW-15): the toast is now the fastest correction path — Undo and
                // Adjust need a window long enough to actually read and tap. Under VoiceOver or
                // Switch Control that budget buys nothing — the toast is gone before the cursor
                // has reached it — so the stretched action window applies instead.
                try await Task.sleep(for: window)
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

    /// The bottom toast slot (artboard 4b). Lives INSIDE the tab-bar `safeAreaInset` boundary in
    /// ``mainInterface``, so the bar's inset pushes it up and neither covers the other. The card
    /// occupies only its own frame, so VoiceOver (and touch) still reach the tab bar beneath it.
    @ViewBuilder
    private var mealLogToastOverlay: some View {
        if let notification = mealLogNotification {
            MealLogNotificationView(
                notification: notification,
                onUndo: { undoLoggedMeals(notification) },
                onAdjust: { adjustLoggedMeal(notification) }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The toast's "Undo": removes the just-logged meal(s) exactly as the meal row's X does —
    /// `store.deleteMeal` per meal (sealed photo cleanup and AI-retry clearing included).
    private func undoLoggedMeals(_ notification: MealLogNotification) {
        for meal in notification.meals {
            store.deleteMeal(meal)
        }
        if mealLogNotification?.id == notification.id {
            mealLogNotification = nil
        }
    }

    /// The toast's "Adjust": opens the meal-correction sheet for the single just-logged meal.
    /// A multi-meal log has no single target, so the view only offers Adjust when
    /// `notification.singleMeal` exists — this guard is the belt to that suspender.
    private func adjustLoggedMeal(_ notification: MealLogNotification) {
        guard let meal = notification.singleMeal else { return }
        if mealLogNotification?.id == notification.id {
            mealLogNotification = nil
        }
        adjustingLoggedMeal = meal
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
    /// Marks one page of ``ContentView/tabPages``: tags it for `selectedTab`, and hides the system
    /// tab bar underneath it so only the app's own floating bar is ever drawn.
    ///
    /// The tab container is a plain `TabView` rather than a `.page` one precisely so there is no
    /// horizontal pager to steal drags (see `tabPages`). Hiding the system bar per page is the
    /// documented way to suppress it — it also drops the bar's safe-area inset, so the floating bar
    /// `mainInterface` installs with `safeAreaInset(edge: .bottom)` stays the only bottom chrome.
    func tabPage(_ tab: FernletTab) -> some View {
        toolbar(.hidden, for: .tabBar)
            .tag(tab)
    }

    /// The presentation chrome every routed sheet shares: the UX-test screen anchor, the detent set,
    /// a visible drag indicator, the house 20pt presentation corner radius, the moss tint, and the
    /// keyboard "Done" accessory.
    ///
    /// One modifier rather than the same lines repeated per case — the values are identical across
    /// all 22 sheets except the anchor and the detents.
    ///
    /// The last two are here rather than per sheet because a routed sheet is attached to
    /// `launchRoot`, OUTSIDE the `.tint(Color.moss)` on `mainInterface`: every un-tinted system
    /// control inside one (the Effort slider, the recipe unit menu, the cycle Observation pickers,
    /// the Settings hub's toggles and links) rendered Apple blue. And numeric keypads have no return
    /// key, so without ``SwiftUI/View/keyboardDoneToolbar()`` the pad floated over the Save bar with
    /// no way to dismiss it.
    func fernletSheetChrome(anchor: String, detents: Set<PresentationDetent>) -> some View {
        uxScreenAnchor(anchor)
            .presentationDetents(detents)
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
            .tint(Color.moss)
            .keyboardDoneToolbar()
    }
}

/// The payload behind the transient "meal logged" toast: the meals a sheet just logged, plus
/// their summed macros.
///
/// Built by `ContentView.showMealLogNotification`; the fresh `id` per instance is what lets a
/// newer toast supersede an older one's auto-dismiss timer. Carries the full `[Meal]` (FLOW-15)
/// so the toast's Undo can remove exactly what was logged and Adjust can open the correction
/// sheet for a single-meal log.
struct MealLogNotification: Identifiable, Equatable {
    let id = UUID()
    /// The just-logged meals, in the order the sheet reported them. Never empty (the presenter
    /// guards), and the Undo action deletes each one exactly as the meal row's X does.
    let meals: [Meal]

    init(meals: [Meal]) {
        self.meals = meals
    }

    /// The one logged meal when exactly one was logged — the only case with an Adjust target
    /// (a multi-meal log has no single meal to correct).
    var singleMeal: Meal? {
        meals.count == 1 ? meals.first : nil
    }

    /// The summed macros across every logged meal, for the toast's detail line.
    var macros: MacroTotals {
        meals.reduce(into: MacroTotals()) { totals, meal in
            totals.protein += meal.macros.protein
            totals.carbs += meal.macros.carbs
            totals.fat += meal.macros.fat
        }
    }
}

/// The bottom toast card for a just-logged meal (artboard 4b): message block plus Undo and — for
/// a single-meal log — Adjust, each a 44pt pill.
///
/// Presented by ``ContentView`` for ~5 seconds above the floating tab bar after a meal sheet
/// reports a log; purely presentational (the timing, deletion, and correction-sheet routing live
/// with the presenting view). At accessibility text sizes the two actions stack under the message
/// full-width (artboard 4b·AX3). The card is a plain accessibility container — message and
/// buttons are individually reachable, and the card claims only its own frame so VoiceOver still
/// reaches the tab bar beneath it.
struct MealLogNotificationView: View {
    var notification: MealLogNotification
    /// Removes the just-logged meal(s); the presenter owns the store call.
    var onUndo: () -> Void
    /// Opens the correction sheet for ``MealLogNotification/singleMeal``; only invoked when the
    /// Adjust pill renders (single-meal logs).
    var onAdjust: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    messageBlock
                    actionButtons
                }
            } else {
                HStack(alignment: .center, spacing: 12) {
                    messageBlock
                    Spacer(minLength: 8)
                    actionButtons
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cream, in: shape)
        .overlay(shape.stroke(Color.bark.opacity(0.10), lineWidth: 1))
        .shadow(color: Color.bark.opacity(0.12), radius: 14, x: 0, y: 7)
        .accessibilityElement(children: .contain)
    }

    /// Title ("<name> logged" / "<n> meals logged") over the slot + macros detail line.
    private var messageBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            titleText
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .lineLimit(2)
                .minimumScaleFactor(0.82)
            detailText
                .font(.fernlet(.labelSmall).monospacedDigit())
                .foregroundStyle(Color.slate)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
    }

    private var titleText: Text {
        if let meal = notification.singleMeal {
            Text("\(meal.name) logged")
        } else {
            Text("\(notification.meals.count) meals logged")
        }
    }

    /// "Lunch · P 42g · C 58g · F 14g" for a single meal; macros alone for a multi-meal log
    /// (the meals may span slots). `displayName` is already localized, so it interpolates as data.
    private var detailText: Text {
        let macros = notification.macros
        if let meal = notification.singleMeal {
            return Text("\(meal.mealType.displayName) · P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
        }
        return Text("P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
    }

    /// Undo (always) and Adjust (single-meal logs only), side by side — or stacked full-width,
    /// one per row, at accessibility sizes (artboard 4b·AX3).
    @ViewBuilder
    private var actionButtons: some View {
        let expands = dynamicTypeSize.isAccessibilitySize
        let layout = expands ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button("Undo", action: onUndo)
                .buttonStyle(MealToastPillStyle(prominent: false, expands: expands))
                .accessibilityIdentifier("mealToast.undo")
            if notification.singleMeal != nil {
                Button("Adjust", action: onAdjust)
                    .buttonStyle(MealToastPillStyle(prominent: true, expands: expands))
                    .accessibilityIdentifier("mealToast.adjust")
            }
        }
    }
}

/// The toast's two action pills (artboard 4b): a 44pt capsule — parchment with bark ink for the
/// neutral Undo, a moss tint with moss ink for the prominent Adjust.
///
/// Local to the toast rather than an `ActionPillButtonStyle` role: the shared secondary pill is
/// cream, which would vanish on the toast's cream card, and the canvas gives these pills no
/// hairline. `expands` stretches the pill full-width for the stacked accessibility layout.
private struct MealToastPillStyle: ButtonStyle {
    var prominent: Bool
    var expands: Bool

    func makeBody(configuration: Configuration) -> some View {
        let shape = Capsule(style: .continuous)
        return configuration.label
            .font(.fernlet(.label))
            .multilineTextAlignment(.center)
            .foregroundStyle(prominent ? Color.moss : Color.bark)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .frame(maxWidth: expands ? .infinity : nil, minHeight: 44)
            .background(prominent ? Color.moss.opacity(0.14) : Color.parchment, in: shape)
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.75 : 1.0)
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

    /// T1-6: pauses both `TimelineView` clocks below — the halo pulse and the loading-dot wave —
    /// rather than hiding them, so the launch screen still renders, just without the perpetual
    /// motion Reduce Motion asks to remove.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    TimelineView(.animation(paused: reduceMotion)) { timeline in
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
                            // Decorative: the launch illustration. The greeting below it is what
                            // the screen actually says.
                            .accessibilityHidden(true)
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

                TimelineView(.animation(paused: reduceMotion)) { timeline in
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
