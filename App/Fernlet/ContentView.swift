//
//  ContentView.swift
//  Fernlet
//
//  Created by Michael Bowman on 5/16/26.
//

import ProximityKit
import FernletConnections
import FernletSocial
import CloudKitSync
import HealthKit
import SwiftUI
import FernletFoundation
import FernletDomainModel
import FernletExchange
import FernletLock
import FernletLockUI
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
/// the five-page `TabView` (Home/Food/Move/Friends/Private). **World build:** Home is the live map
/// (`WorldMapHome`) with the item bar over it (`WorldItemBar`), the other four pages are full-screen
/// panels in the approved frame (`WorldPanelFrame`), and Today, Log and Settings open as panels over
/// everything (`worldOverlay`); the tab still drives every gate, exactly as the floating bar did. All
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
    private let healthKitService: HealthKitService
    @State private var launcher = LaunchPreparationService()
    @State private var periodStore: PeriodTrackerStore
    @State private var intimacyStore = IntimacyLogStore()
    @State private var periodContext: PeriodContextBridge?
    @State private var stressService = StressService()
    @State private var worryBoxService = WorryBoxService()
    /// The no-passcode Private tab's open coordinator (period-data design 2026-09-30, §4.9), built by
    /// the launch wiring once the lock service is in reach and handed to the hub's gate.
    @State private var privateHubOpener: PrivateHubOpenCoordinator?
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
    /// The World Home's panel that is not a tab (Today, Log, Settings), open over everything; nil when
    /// none is. The four tab panels are the `TabView`'s own pages (World build, plan step 1b).
    @State private var worldOverlay: WorldPanel?
    /// Whether the World Home's disposable camera (the blue button's, ``WorldDisposableCamera``) is open
    /// full screen over everything: the session button and the stamp banner hold back while it is.
    @State private var isWorldCameraOpen = false
    /// A page of the Album panel Home asked for (Friends nearby, Activities, Friend shops), handed to the
    /// panel, which pushes it one deep and clears this (`b4-mem-blue-*`, `b4-mem-home-shop`).
    @State private var pendingFriendsRoute: FriendsRoute?
    /// The Stamp book asked for by the stamp banner or the stamp widget: Today opens and pushes it at its
    /// stamps (owner, 2026-10-24: no sheet), and the Today panel's HomeView takes and clears this.
    @State private var pendingStampBook = false
    /// Whether the session-end keep-as-friends prompt is up (``KeepFriendsPromptHost``, owner
    /// 2026-10-24: shown wherever the person is, Home included).
    @State private var isKeepFriendsPromptUp = false
    /// Whether one of the Album's full-screen covers is up (a wall photo, a "Just you" set, the
    /// session celebration): the keep prompt is never requested over one.
    @State private var isAlbumCoverUp = false
    /// How far the keyboard reaches above the interface's bottom edge, zero while it is down. The
    /// bar stays behind the keyboard; the meal-logged toast reads this to rest on the keyboard.
    @State private var keyboardOverlap: CGFloat = 0
    /// The home indicator's safe area under the interface. The item bar sits in it (26 pt off the
    /// physical bottom, as the design draws it); the meal toast, which keeps the safe area, takes it
    /// off its lift so it still rests 8 pt above the bar.
    @State private var bottomSafeArea: CGFloat = 0
    /// Per-tab re-select tokens: bumped each time the ALREADY-selected tab is tapped again. Each tab
    /// page decides what that means from its own navigation state (`tabReselect`): pop to its main
    /// page when something is pushed, otherwise scroll to the top.
    @State private var tabResetTokens: [FernletTab: Int] = Dictionary(uniqueKeysWithValues: FernletTab.allCases.map { ($0, 0) })
    @State private var activeSheet: FernletSheet?
    /// Foreground trainer Shortcuts hand their requested first action to Move's existing local
    /// presenter, preserving its post-import calendar refresh.
    @State private var trainerExportLaunchAction: TrainerExportLaunchAction?
    @State private var mealLogNotification: MealLogNotification?
    /// True while VoiceOver's cursor is on the meal-logged toast, which then waits rather than
    /// vanishing from under it (see ``showMealLogNotification(_:loggedTo:landedWithCaveat:)``).
    @State private var isMealToastUnderCursor = false
    /// The just-logged meal the toast's "Adjust" action opens the correction sheet for — a local
    /// `.sheet(item:)` slot beside the `activeSheet` router (the toast fires only after the logging
    /// sheet has dismissed, so the two slots never race).
    @State private var adjustingLoggedMeal: Meal?
    @State private var editingRecipeFromHome: RecipeDefinition?
    @State private var editingSavedRecipeFromHome: RecipeDefinition?
    /// A Messages packet survives here only while Fernlet's review sheet is visible; its protected
    /// App Group inbox record remains available until the user saves it or it expires.
    @State private var messagesRecipeImport: FernletMessagesInboxRecord?
    @State private var messagesWorkoutPlanImport: FernletMessagesWorkoutInboxRecord?
    @State private var messagesRecipeImportError: String?
    private let messagesRecipeInbox = FernletMessagesRecipeInboxCoordinator()
    /// Set by the stress explainer's First Aid link; consumed by `handleActiveSheetDismiss`
    /// (the same dismiss-then-represent chaining the recipe editors use).
    @State private var pendingFirstAidAfterDismiss = false
    @State private var didAutoImportHealthProfile = false
    @State private var didAutoImportHealthContext = false
    /// Coalesces HealthKit change notifications. Tab selection is deliberately not a HealthKit
    /// trigger; launch performs the initial read and observer events are the only later trigger.
    @State private var healthRefreshTask: Task<Void, Never>?
    @State private var pendingObservedHealthTypeIdentifiers: Set<String> = []
    /// The ONE in-flight period drain/load. Every trigger (lock transitions, `.logPeriod` dismissals)
    /// cancels and replaces it, so completions can never land out of order and re-populate `entries`
    /// after a scrub — the load captures its content key by value and cannot notice a later lock.
    @State private var periodLoadTask: Task<Void, Never>?
    /// Defers selected-section hydration until after SwiftUI has removed the unlock overlay. Lock
    /// and section departures still scrub synchronously; only the safe unlock direction is deferred.
    @State private var privateActivationTask: Task<Void, Never>?
    /// Whether the hub session's 300 ms settle wait is running (a second section opening during it does
    /// not start another).
    @State private var isSettlingSealedBackups = false
    /// Whether this hub session has asked the Sealed backup v2 engine for its settle yet — once per
    /// hub session, on whichever Private section opens first (Worry Box included; design 2026-09-30
    /// §4.5). Cleared when the hub locks.
    @State private var requestedSealedBackupV2Settle = false
    @Environment(\.scenePhase) private var scenePhase
    /// Read by the `.workout` route (3b·AX3: the sheet opens `.large` when the kind chips can no
    /// longer fit the medium detent).
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Read by the silly-stats stamp banner: it fades in place of sliding down under Reduce Motion.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(store: FernletStore, healthKitService: HealthKitService) {
        self.store = store
        self.healthKitService = healthKitService
        _periodStore = State(initialValue: PeriodTrackerStore(healthService: healthKitService))
    }

    var body: some View {
        rootSheetHost
            // Every passcode setup sheet, wherever it is presented from, asks the same coordinator
            // before it mints a fresh key over sealed entries (period-data design §4.4 step 2).
            .environment(\.fernletPrivateHubOpener, privateHubOpener)
            // World build: the one design language (b1-language) on every screen and every sheet the
            // root presents: framed cards, chips, buttons and switches (`FernletFramedLook`).
            .worldDesignLanguage()
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
            .onChange(of: privateHubSection) { _, newSection in
                handlePrivateHubSectionChange(newSection)
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
            .onReceive(NotificationCenter.default.publisher(for: FernletMessagesRecipeImportRequest.requestNotification)) { _ in
                consumePendingMessagesRecipeImport()
            }
            .onChange(of: store.settings.allowNearbyPresence) { _, _ in
                // The opt-in can also arrive through the synced snapshot, which never runs this
                // device's setter — so the run policy re-runs on the VALUE (P7 item 3), exactly as
                // the setter already makes it.
                applyProximityRunPolicyFromView()
            }
            // The age ruling is a run-policy input (P7 item 3): a final below-the-line verdict, or
            // a guardian's communication limits, stops every radio — and clears the same way.
            .onChange(of: store.ageAssurance.record) { _, _ in
                applyProximityRunPolicyFromView()
            }
            // Session liveness is the poller's predicate (P7 item 4): a session founded or ended
            // between the scene's and this view's edges must start or stop the one timer too, and
            // the policy's session presence moves with it.
            .onChange(of: store.meshNetworkManager.isSessionLive) { _, _ in
                applyProximityRunPolicyFromView()
            }
            // Session photos U3: while an ended session's photos wait for the person's choice — or an
            // answer or a leave the review started is still running — discovery must not start a
            // second session or resume the ended one, so the block's every edge re-runs the policy.
            .onChange(of: store.sessionPhotoReviewCoordinator.blocksDiscovery) { _, _ in applyProximityRunPolicyFromView() }
            // P8 item 6: the mesh this device is on IS the background task's identity
            // (`MBO.Fernlet.mesh-continuation.<meshID>`), so a new mesh registers a new handler and
            // a mesh ending ends the task that was continuing it. Observed here rather than in the
            // Friends surface because a mesh founds, changes and ends regardless of which tab is up.
            // The host speaks no radio verb; it feeds the store, which re-runs the policy.
            .onChange(of: store.meshNetworkManager.currentMesh?.meshID) { _, meshID in
                handleMeshIdentityChange(meshID)
            }
            // The 0 → 1 edge is the submission instruction (plan §14: once the first peer commits).
            // `hasCommittedPeer` is the "is there a peer this instant" predicate — never
            // `isSessionLive`, which answers whether the session has ENDED, and never `isInSession`,
            // which is the layout swap's.
            .onChange(of: store.meshNetworkManager.hasCommittedPeer) { _, hasPeer in
                store.meshContinuationHost.committedPeerDidChange(hasPeer: hasPeer)
            }
            // One-time "first kept friend" presence offer (Phase 4a). Attached to the stable
            // root — not the Social-tab layout (which is destroyed in the same transaction as
            // session teardown, the Phase-2 lesson) — and driven by observable store state.
            .alert("Turn on Nearby Friends?", isPresented: presenceEnablePromptBinding) {
                Button("Turn on") {
                    // The setter re-runs the run policy, which starts the radio (P7 item 3).
                    store.setAllowNearbyPresence(true)
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
                // The inspector carries its own sheet frame (`fernletSheet()`, Done top right); a detent or
                // grabber line here would win over it.
                ConnectionInspectorView(inspector: store.connectionInspector)
                    .presentationBackgroundInteraction(.enabled)
                    .worldDesignLanguage()
            }
            .sheet(item: pendingRecipeShareBinding) { share in
                ProximityRecipeShareReviewSheet(
                    share: share,
                    store: store,
                    manager: store.recipeShareManager
                )
                .fernletSheet()
                .worldDesignLanguage()
            }
            // FLOW-15: the toast's "Adjust" action — the same correction sheet the meal row's
            // Adjust opens, presented from the root because the toast outlives the logging sheet.
            .sheet(item: $adjustingLoggedMeal) { meal in
                MealCorrectionSheet(store: store, meal: meal)
                    .fernletSheetChrome(anchor: "sheet.mealCorrection", detents: [.large])
            }
            .sheet(item: $messagesRecipeImport, onDismiss: handleMessagesRecipeImportDismiss) { record in
                MessagesRecipeImportReviewSheet(record: record, inbox: messagesRecipeInbox) {
                    messagesRecipeImport = nil
                }
                .fernletSheetChrome(anchor: "sheet.messagesRecipeImport", detents: [.medium, .large])
            }
            .sheet(item: $messagesWorkoutPlanImport, onDismiss: handleMessagesRecipeImportDismiss) { record in
                MessagesWorkoutPlanImportReviewSheet(record: record, inbox: messagesRecipeInbox) {
                    messagesWorkoutPlanImport = nil
                }
                .fernletSheetChrome(anchor: "sheet.messagesWorkoutPlanImport", detents: [.medium, .large])
            }
            .alert("Couldn't open Messages item", isPresented: messagesRecipeImportErrorBinding) {
                Button("OK", role: .cancel) { messagesRecipeImportError = nil }
            } message: {
                Text(messagesRecipeImportError ?? "")
            }
            // Session photos U3: the session-end photo review is the first thing shown — its own
            // overlay window above every sheet here, never one of them. This feeds its presenter the
            // window scene, the scene phase, the launch and the root sheet (First Aid waits it out).
            .modifier(SessionPhotoReviewTriggers(
                store: store, activeSheet: activeSheet, launchComplete: launcher.isDone, scenePhase: scenePhase
            ))
            // A session that ended with no photos asks "Keep as friends?" wherever the person is, Home
            // included (owner, 2026-10-24), once per session end; never over a root presentation or a
            // cover, never in a decoy.
            .modifier(KeepFriendsPromptHost(
                store: store, isRootSheetUp: rootSheetIsCoveringTabs, launchComplete: launcher.isDone,
                isCoverUp: isWorldCameraOpen || isAlbumCoverUp, keepFriendsPromptPresented: $isKeepFriendsPromptUp
            ))
    }

    /// One-time "first kept friend" presence offer (Phase 4a), driven by observable store state.
    private var presenceEnablePromptBinding: Binding<Bool> {
        Binding(
            get: { store.presenceEnablePromptRequested },
            set: { if !$0 { store.presenceEnablePromptRequested = false } }
        )
    }

    private var messagesRecipeImportErrorBinding: Binding<Bool> {
        Binding(
            get: { messagesRecipeImportError != nil },
            set: { if !$0 { messagesRecipeImportError = nil } }
        )
    }

    /// Logging/editing a period event persists to HealthKit but doesn't mutate the in-memory entries,
    /// so reload + refresh when the period sheet dismisses to keep the chip/outlook/trends/score
    /// current (catches logging from Home or the period screen alike).
    private func handleActiveSheetIDChange(oldID: String?, newID: String?) {
        if newID == nil, oldID == "settings" {
            configureHealthChangeObservation()
            Task { await store.refreshWorkoutsFromHealth() }
        }
        guard newID == nil, oldID == "logPeriod",
              privateHubSection == .cycle,
              lockService.isUnlocked(for: .privateHub) else { return }
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
        updatePrivateDataActivation(section: privateHubSection, lockState: newState)
        // Every sealed backup is sealed under the hub's content key, so turning one on from Settings
        // (reached from Home, where the hub is always re-locked) can only ever OWE the upload. This
        // is the moment that debt can be paid: the hub just unlocked, so the sealed stores are
        // readable. It is also the only moment a RESTORE can decrypt what it pulls down — the v2
        // engine's passes restore first, then export (design 2026-09-30, §4.2, §4.5).
        if newState.isUnlocked(for: .privateHub) {
            requestSealedBackupSettlement()
        }
        applyProximityRunPolicyFromView()
        syncAwayHeartsIfActive()
    }

    private func handlePrivateHubSectionChange(_ section: PrivateHubSection) {
        updatePrivateDataActivation(section: section, lockState: lockService.state)
        guard lockService.isUnlocked(for: .privateHub) else { return }
        requestSealedBackupSettlement()
    }

    private func handleTabChange(from oldTab: FernletTab, to newTab: FernletTab) {
        isHomeTabBarCompact = false
        // A card in Today or Log that opens a tab (a period log opens Private) leaves the overlay.
        if newTab != .home { worldOverlay = nil }
        // P7 items 2–3: the run policy's tab fact, mirrored into the store the way `lockState` and
        // `duressSessionActive` are — and then the policy re-run, which is what arms or stands down
        // the Friends radios and the two listeners now (`ProximityRunSeams.swift`).
        store.selectedTab = newTab
        if oldTab == .personal || newTab == .personal {
            updatePrivateDataActivation(section: privateHubSection, lockState: lockService.state)
        }
        applyProximityRunPolicyFromView()
        syncAwayHeartsIfActive()
    }

    /// The mesh this device is on changed (network migration P8 item 6).
    ///
    /// A method rather than a closure in `body` because `body` is held to 60 code lines like every
    /// other, and because it is the same shape as this view's other edge handlers. It speaks no
    /// radio verb: the host registers the new mesh's task identifier or ends the task the old one
    /// was being continued for, and reaches the radios only by feeding the store.
    ///
    /// - Parameter meshID: The mesh's id, or nil when the mesh is over.
    private func handleMeshIdentityChange(_ meshID: UUID?) {
        guard let meshID else {
            store.meshContinuationHost.meshDidEnd()
            return
        }
        store.meshContinuationHost.meshDidStart(
            meshID: meshID, hasCommittedPeer: store.meshNetworkManager.hasCommittedPeer
        )
    }

    private func handleScenePhaseChange(_ phase: ScenePhase) {
        if phase == .active {
            // If the app stayed resident across local midnight, roll the store over to the new
            // day FIRST (flushes yesterday under its own key, re-keys "today") so the widget/
            // coin refreshers below and any subsequent logging operate on the correct day.
            if store.refreshCurrentDayIfNeeded() {
                // A new day may be a silly-stat day: the launch pick was made for yesterday.
                Task { await store.refreshSillyStats() }
            }
            Task { await store.processSharedRecipeImportQueue() }
            // Apply widget "+1 water" taps that arrived while backgrounded (also refreshes
            // the mirrored snapshot across day rollovers).
            store.processPendingWidgetActions()
            // Credit any day that became active while backgrounded (or synced in from another
            // device). Idempotent, so a no-op when nothing new is logged.
            store.reconcileCoinLedger()
            // Belt-and-braces for the foreground App Intent deep-link: the `requestNotification`
            // handler is the primary path, but if a token is present when the scene reactivates
            // (and within its expiry window), honor it here too.
            consumePendingNotificationSheet()
        }
        // P7 item 3: the radios no longer move here. A scene edge is `FernletApp`'s — its handler
        // hands the phase to the run-policy funnel in the order P5 item 10 fixed (after
        // `refreshStateFromKeychain()` on activation), and the seams act on the verdict. Only the
        // away-hearts sync still rides this view's scene edge.
        syncAwayHeartsIfActive()
    }

    // MARK: - Launch wiring

    /// Everything the root `.task` does, in its original order: the sensitive-surface gates and
    /// scoring contexts first (before any load can observe a missing gate), then the lock / worry-box
    /// activation and the delete-all hooks, then the post-launch sequence.
    private func performLaunchWiring() async {
        #if DEBUG
        UITestPrivateHubSeed.applyLaunchHooks(lockService: lockService)
        #endif
        wirePrivateHubCustody()
        wireSensitiveGatesAndScoringContexts()
        wireLockAndWorryBox()
        wireWorkoutHealthAccessOffer()
        await runPostLaunchSequence()
    }

    /// The no-passcode Private tab: the one-button gate's open coordinator, the sealed backups'
    /// hub-key provider and the app-lock reset funnel (period-data design 2026-09-30, §4.9, §9.10,
    /// §9.21). Before anything else in the launch wiring, so no settle can read a backup key from the
    /// retired journal-section source and no reset can land without its funnel.
    private func wirePrivateHubCustody() {
        let preferencesStore = storagePreferencesStore
        let appStore = store
        // The Sealed backup gates read sync and the backup switches from the app's in-memory
        // preferences, never a keychain read per check (design 2026-09-30 §4.2 G4).
        store.sealedBackupPreferencesProvider = { [preferencesStore] in preferencesStore.preferences }
        // The intimate-log Sealed backup works through THIS funnel — the app's one intimacy instance —
        // so every write any surface makes marks its upload owed; handed over before the bookkeeping
        // is seeded below, whose intimate-log marker seeds from this funnel's latch (design 2026-09-30,
        // §4.3, §4.4).
        store.attachIntimacyLogStore(intimacyStore)
        let priorEntries = SealedPriorEntryStore(
            intimacyStore: intimacyStore,
            periodVisible: { appStore.isPeriodTrackingVisible },
            intimacyVisible: { appStore.isIntimacyTrackingVisible },
            restoresAfterRemoval: {
                Self.sealedBackupRestoresAfterRemoval(
                    preferencesStore.preferences,
                    periodVisible: appStore.isPeriodTrackingVisible,
                    intimacyVisible: appStore.isIntimacyTrackingVisible,
                    restoreHeldForOwner: appStore.sealedBackupRestoreAwaitsOwner
                )
            },
            bookkeepingCleared: { appStore.sealedBackupKeyLossForgotPendingChoices() }
        )
        Self.wirePrivateHubCustody(store: store, lockService: lockService, priorEntries: priorEntries)
        privateHubOpener = PrivateHubOpenCoordinator(custody: lockService, entries: priorEntries)
    }

    /// The two custody hooks, as one testable step: the sealed backups read the Private tab's key
    /// from the lock service (R2-F1: never the journal section's, which is nil on the Cycle section in
    /// both passcode modes), and `reset()` hands its aftermath to the store's reset funnel (§9.21),
    /// which clears the backup bookkeeping and holds ambient restores for the device owner. Wired once
    /// here, so both reset entry points (the gate's lost-key card and Settings → App lock) get it.
    ///
    /// - Parameters:
    ///   - store: The app store.
    ///   - lockService: The lock service.
    ///   - priorEntries: Where the divergence latches are cleared.
    static func wirePrivateHubCustody(
        store: FernletStore,
        lockService: FernletLockService,
        priorEntries: any PriorPrivateEntryStore
    ) {
        store.hubContentKeyProvider = { [weak lockService] in lockService?.contentKey(for: .privateHub) }
        // The v2 markers seed once (and owe one complete export per enabled backup) before any
        // settle can read them (design 2026-09-30 §4.3, R1-BR-11).
        store.seedSealedBackupBookkeepingOnce()
        lockService.onResetCompleted = { [weak store] in
            store?.handleAppLockResetCompleted(clearBookkeeping: { priorEntries.clearBackupBookkeeping() })
        }
    }

    /// Whether a Sealed backup REALLY comes back once the "can't be opened" card's entries are
    /// removed — the card promises it only when this is true (review C-U2-R3). Nothing is restored
    /// while an app-lock reset is waiting for the device owner (every ambient restore is held);
    /// otherwise:
    /// - the period half counts while the period backup is on and cycle tracking is visible: the
    ///   removal reopens this install's period restore, and the next hub settle MERGES the backup in
    ///   (period-data design 2026-09-30, §9.10), whatever else the store holds;
    /// - the journal half counts while the journal backup is on: the removal reopens this install's
    ///   journal restore and the next hub settle MERGES the backup in, whatever entries stay behind
    ///   (journal and intimacy Sealed backup v2 design 2026-09-30, §7.4 — the old "only into an empty
    ///   journal store" condition is gone with the empty-store restore);
    /// - the intimacy half counts while intimacy tracking is visible: the removal reopens this install's
    ///   intimate-log restore and the next hub settle MERGES the backup in (design 2026-09-30, §8);
    ///   hidden defers it.
    ///
    /// - Parameters:
    ///   - preferences: The storage preferences (sync and the per-payload switches).
    ///   - periodVisible: The derived period-tracking visibility.
    ///   - intimacyVisible: The derived intimacy-tracking visibility.
    ///   - restoreHeldForOwner: Whether an app-lock reset is waiting for the device owner.
    static func sealedBackupRestoresAfterRemoval(
        _ preferences: StoragePreferences,
        periodVisible: Bool,
        intimacyVisible: Bool,
        restoreHeldForOwner: Bool
    ) -> Bool {
        guard preferences.iCloudSyncEnabled, !restoreHeldForOwner else { return false }
        let periodRestores = preferences.sealedBackupPeriodEnabled && periodVisible
        let journalRestores = preferences.sealedBackupJournalEnabled
        let intimacyRestores = preferences.sealedBackupIntimacyEnabled && intimacyVisible
        return periodRestores || journalRestores || intimacyRestores
    }

    /// The first-workout Health offer ("Asked the first time you log a workout…"), over the app's
    /// gateway and its single preferences store (`WorkoutHealthAccessOffer`).
    ///
    /// Not under a test harness, for the backup-exclusion launch gate's two reasons: an unanswered
    /// Health sheet would stall every UI test that logs a workout, and a unit-test host would flip the
    /// REAL preferences blob on the test simulator.
    private func wireWorkoutHealthAccessOffer() {
        guard !UITestSupport.isTestHarnessActive else { return }
        store.installWorkoutHealthAccessOffer(service: healthKitService, preferencesStore: storagePreferencesStore)
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
        // P7 item 2: the run policy's tab fact, same mirror; `handleTabChange` keeps it current.
        store.selectedTab = selectedTab
        // Retire a duress-recovery enrollment this device's identity has outlived, before
        // anything can arm or fire the response over it. Cheap (two keychain reads and a
        // comparison when an enrollment exists, one when it does not) and idempotent; the
        // delete-all funnel fires the same reconcile in-line via `identityRotatedHook`, and
        // this is the backstop for a rotation from any other route — including a wipe whose
        // process died before the hook ran.
        // R7: `true` means an enrollment this device's identity had outlived was actually retired
        // — a rare, security-relevant state change, so it is recorded rather than dropped.
        if DuressRecoveryCoordinator(
            identity: .fernletApp(),
            lockService: lockService
        ).reconcileEnrollmentWithLocalIdentity() {
            FernletAuditLog.log("duress.recoveryEnrollment.retired", context: ["site": "launch"])
        }
        // Hard visibility gate. Injected before ANY load below: the store's own `.task` runs
        // on every cold launch, so wiring this later would let one full decrypt + HealthKit
        // read through before the gate existed.
        periodStore.attachVisibilityGate { [store] in store.isPeriodTrackingVisible }
        // Every change to a sealed cycle record moves the period backup's mutation epoch and marks its
        // upload owed (never its switch), so the next hub settle re-exports it (design 2026-09-30
        // §4.4, R2-F3, R2-F8).
        periodStore.recordStore.attachMutationHook { [store] in store.markSealedBackupDirty(.periodData) }
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
        // Body signals (opt-in): wire the stress service to the shared gateway. The initial read
        // happens during launch preparation; later reads follow observed Health changes.
        stressService.attach(store: store, fetchMetricDays: { [healthKitService] daysBack in
            try await healthKitService.stressMetricDays(daysBack: daysBack)
        })
        store.attachStressScoringContext(stressService)
    }

    /// Mirrors the initial lock state into the store, leaves offscreen private caches inactive, and
    /// attaches the delete-all hooks (plus the DEBUG demo seed).
    private func wireLockAndWorryBox() {
        let initialLockState = lockService.state
        store.lockState = initialLockState
        updatePrivateDataActivation(section: privateHubSection, lockState: initialLockState)
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
            // Same for the silly stats' companion pacing: every seeded run starts with a mention due.
            SillyStatsCompanionPacer.clearPersistentState()
            // And with an empty stamp book, which the launch refresh begins afresh from the seed.
            SillyStampStore.clearPersistentState()
            store.sillyStats.clear()
        }
        // Period log suite: cycle sharing OFF (the shipped default) whatever an earlier suite left
        // in this simulator's keychain. Before the sheet hook below presents anything.
        if UITestSupport.pinsHealthSharingOff {
            storagePreferencesStore.update { preferences in
                preferences.healthKitMasterEnabled = false
                preferences.healthKitCapabilityEnabled[HealthCapability.cycleTracking.rawValue] = false
            }
        }
        // P8 item 7: seed the background-continuation claim so the Friends tab can render the
        // refused / expired / system-ended card. Through the kind's own inverse, so the hook can
        // only ask for a cell the presentation table answers; no task, no radio, no scene edge.
        if let seeded = UITestSupport.seededMeshContinuationCard {
            store.meshContinuationState = seeded.presentingState
            store.meshContinuationLastAudit = seeded.presentingAudit
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
        if let initialWorldPanel = UITestSupport.initialWorldPanel { openWorldPanel(initialWorldPanel) }
        // Session photos U3: an ended session's photos held for review before the first evaluation.
        UITestSupport.seedHeldSessionPhotosIfRequested(on: store.meshFeatures.photos)
        #endif
        // A notification tapped during a cold launch stored its deep-link before this
        // view finished preparing — open it now (live taps arrive via the onReceive handlers).
        consumePendingNotificationSheet()
        store.meshNetworkManager.injectUITestStateIfNeeded()
        // P7 item 3: the launch edge of the run policy from this view's side. The scene's own edge
        // is `FernletApp`'s launch push; whichever lands second applies with the tab mirror set.
        applyProximityRunPolicyFromView()
        syncAwayHeartsIfActive()
        store.deferredPostLaunchTasks()
        store.ensureBundledFoodItemsSeeded()
        // Widget bridge: wire the mirror, drain "+1 water" taps queued while the app was
        // closed, and publish the first snapshot (store is fully loaded by this point).
        store.activateWidgetBridge()
        // The Messages extension receives only this bounded, privacy-filtered packet catalog.
        // It never opens Fernlet's canonical repositories directly.
        store.activateMessagesCatalog()
        _ = messagesRecipeInbox.purgeExpired()
        consumePendingMessagesRecipeImport()
        await store.processSharedRecipeImportQueue()
        await stressService.refreshIfNeeded()
        configureHealthChangeObservation()
    }

    /// Opens the sheet a notification tap asked for (daily check-in → journal). Skipped while
    /// launch preparation is still running — the startup task consumes the flag afterwards.
    private func consumePendingNotificationSheet() {
        guard launcher.isDone else { return }
        // A sheet is already open — leave the request PENDING (don't clear it) so it isn't silently
        // dropped; `handleActiveSheetDismiss` re-consumes it once the covering sheet closes.
        guard activeSheet == nil, messagesRecipeImport == nil, messagesWorkoutPlanImport == nil else { return }
        // A foreground App Intent (#6, e.g. "Log a meal in Fernlet") records which sheet it wants; honor
        // it before the notification path so a Siri/Shortcuts open lands on the right screen.
        if let target = PendingIntentSheet.consume() {
            switch target {
            case .meal: activeSheet = .meal
            case .journal: activeSheet = .journal
            case .water: activeSheet = .water
            case .home: selectedTab = .home
            case .stamps: openStampBookInToday()
            case .trainerPrepareSummary: openTrainerExport(.prepareSummary)
            case .trainerCopySummaryAndPrompt: openTrainerExport(.copySummaryAndPrompt)
            case .trainerPastePlan: openTrainerExport(.pastePlan)
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

    /// Resolves an opaque containing-app deep link after the launch shell and any existing sheet
    /// have yielded. The URL holds only an ID; the validated packet remains in the App Group inbox.
    private func consumePendingMessagesRecipeImport() {
        guard launcher.isDone, !rootSheetIsCoveringTabs,
              let target = FernletMessagesRecipeImportRequest.consume() else { return }
        do {
            switch target.destination {
            case .recipe:
                guard let record = try messagesRecipeInbox.record(id: target.inboxID) else {
                    messagesRecipeImportError = String(localized: "messagesImport.error.recipeGone",
                                                       defaultValue: "This recipe review is no longer available.",
                                                       comment: "Alert body after tapping a recipe card in Messages whose import review has already been handled or cleared.")
                    return
                }
                messagesRecipeImport = record
            case .workoutPlan:
                guard let record = try messagesRecipeInbox.workoutRecord(id: target.inboxID) else {
                    messagesRecipeImportError = String(localized: "messagesImport.error.planGone",
                                                       defaultValue: "This workout-plan review is no longer available.",
                                                       comment: "Alert body after tapping a workout-plan card in Messages whose import review has already been handled or cleared.")
                    return
                }
                messagesWorkoutPlanImport = record
            }
        } catch {
            messagesRecipeImportError = String(localized: "messagesImport.error.unreadable",
                                               defaultValue: "Fernlet couldn't read this review. Unlock your iPhone and try again.",
                                               comment: "Alert body when a recipe or workout-plan card from Messages can't be read, usually because the iPhone is locked. 'Fernlet' is the app's name.")
        }
    }

    /// Lands foreground trainer Shortcuts on Move and presents the same handoff UI as its Share pill.
    private func openTrainerExport(_ action: TrainerExportLaunchAction) {
        selectedTab = .move
        trainerExportLaunchAction = action
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
                    companionState: store.liveCompanionState,
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
            // World build: the panels cover the whole screen, so nothing under a page needs room for
            // a bar; the item bar shows only over the map, which scrolls nothing.
            .environment(\.fernletTabBarClearance, 0)
            .overlay(alignment: .bottom) { worldItemBarOverlay }
            // Keep the item bar pinned to the physical bottom, behind the keyboard, instead
            // of riding up on top of it. The ignore belongs HERE, on the view carrying the inset, and
            // not inside the inset's closure: SwiftUI lays an inset's content out with no bottom safe
            // area of its own, so an ignore in there reaches nothing. Until 2026-10-01 the closure
            // carried it, and the bar rode the keyboard on every tab, root and pushed alike (iOS 26.5:
            // the bar's own bottom inset read 0 while this view ended at the keyboard's top). The
            // pages are unaffected: each tab page sits in its own UIKit-hosted view that avoids the
            // keyboard itself — a page ended at the keyboard's top before this line existed and still
            // does — so the fields and scroll views inside them keep clearing the keyboard.
            .ignoresSafeArea(.keyboard, edges: .bottom)
            .onGeometryChange(for: CGFloat.self) { $0.safeAreaInsets.bottom } action: { bottomSafeArea = $0 }
            // FLOW-15 (artboard 4b): the meal-logged toast sits at the BOTTOM, lifted over the bar so
            // the two never cover each other. Outside the keyboard ignore above, so with the keyboard
            // up it rests on the keyboard instead of hiding behind it with the bar.
            .overlay(alignment: .bottom) { mealLogToastOverlay }
            .animation(.spring(response: 0.34, dampingFraction: 0.86), value: mealLogNotification?.id)
            // A silly-stats stamp earned just now: a banner at the TOP, clear of the meal toast a
            // cookie's log raises at the bottom.
            .overlay { worldOverlayPanel }
            .overlay(alignment: .top) { sillyStampBannerOverlay }
            .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(response: 0.36, dampingFraction: 0.86), value: shownStampBanner)
            .fernletKeyboardOverlap($keyboardOverlap)
            .tint(Color.moss)
            .background(sceneBackground.ignoresSafeArea())
    }

    /// How far the meal-logged toast rises off the interface's bottom edge: clear of the item bar while
    /// the map shows it, and nothing once the keyboard reaches over the bar or a panel covers it.
    private var mealLogToastLift: CGFloat {
        FernletTabBarClearance.reservation(
            clearance: isWorldMapFrontmost ? max(0, WorldItemBar.height + WorldItemBar.bottomGap + 8 - bottomSafeArea) : 0,
            keyboardOverlap: keyboardOverlap
        )
    }

    /// Always the five-tab `tabPages`, unconditionally — its structural identity must never
    /// change, or SwiftUI tears down and rebuilds every tab (losing all @State) on the swap.
    ///
    /// This used to be an `if <camera session> { SocialHubView(...) } else { tabPages }`. Because a
    /// `@ViewBuilder` if/else is `_ConditionalContent<SocialHubView, TabView>` — two different types
    /// in the same slot — flipping the condition removed the whole `TabView` and rebuilt every tab
    /// with empty @State on every friend-mesh session edge (the "blank then loads" symptom). The
    /// session camera is a full-screen cover of the Friends panel now (b3-friends-session), so nothing
    /// here swaps or takes over the tab at all.
    private var mainTabContent: some View {
        tabPages
    }

    /// True while any ROOT-presented sheet is covering the tab pages: the `activeSheet` router
    /// (Settings, Trends, First Aid, the logging sheets, …), the connection inspector, an
    /// incoming recipe-share review, the toast's meal-correction slot, or the session-end keep-as-friends
    /// prompt (``KeepFriendsPromptHost``). Composed into the
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
            || messagesRecipeImport != nil
            || messagesWorkoutPlanImport != nil
            || isKeepFriendsPromptUp
    }

    private var tabPages: some View {
        TabView(selection: $selectedTab) {
            // World build (plan step 1b): Home is the live map; the four other tabs are full-screen
            // panels in the approved frame. Same pages, same tab gates, same @State lifetimes.
            WorldMapHome(store: store, isFrontmost: isWorldMapFrontmost,
                         bodySignal: HomeView.companionBodySignal(enabled: store.settings.stressAwarenessEnabled,
                                                                  assessment: stressService.assessment),
                         onOpen: openWorldPanel,
                         // The blue button's friend choices open Friends nearby or Activities in the Album.
                         onFriends: openFriends,
                         // The quick start's "Suggest today's workout" opens Move's suggestion sheet.
                         onSheet: { activeSheet = $0 },
                         stampBannerShowing: shownStampBanner != nil,
                         isCameraOpen: $isWorldCameraOpen)
                .tabPage(.home)
            WorldPanelFrame(panel: .food, onClose: closeWorldPanel) {
                FoodView(store: store, onMealsLogged: mealLogReporter, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .food))
            }
            .tabPage(.food)
            WorldPanelFrame(panel: .move, onClose: closeWorldPanel) {
                MoveView(
                    store: store,
                    activeSheet: $activeSheet,
                    trainerExportLaunchAction: $trainerExportLaunchAction,
                    isTabBarCompact: $isHomeTabBarCompact,
                    tabResetToken: resetTokenBinding(for: .move)
                )
            }
            .tabPage(.move)
            // The Album (b4-mem-root): just the album, the same in a session. Home's buttons push its pages
            // (Friends nearby, Activities, Friend shops), and a session started from Friends nearby closes
            // it back to Home.
            WorldPanelFrame(panel: .friends, onClose: closeWorldPanel) {
                SocialHubView(store: store, activeSheet: $activeSheet, isTabBarCompact: $isHomeTabBarCompact,
                              tabResetToken: resetTokenBinding(for: .social), requestedRoute: $pendingFriendsRoute,
                              onFinished: closeWorldPanel, keepFriendsPromptIsUp: isKeepFriendsPromptUp,
                              albumCoverIsUp: $isAlbumCoverUp)
            }
            .tabPage(.social)
            // `!rootSheetIsCoveringTabs`: the hub stays alive beneath a root-presented sheet, so
            // its capture-friction pulse must not fire (and spend the once-per-session nudge
            // invisibly) while an unprotected sheet — Settings, Trends, First Aid from a
            // notification tap, an incoming recipe share — fully covers the Personal tab. The
            // protected sheets claim the nudge themselves, visibly, via their own attachments.
            WorldPanelFrame(panel: .personal, onClose: closeWorldPanel) {
                PrivateHubView(store: store, periodStore: periodStore, intimacyStore: intimacyStore, healthKitService: healthKitService, periodContext: periodContext, worryBox: worryBoxService, activeSheet: $activeSheet, section: $privateHubSection, isTabBarCompact: $isHomeTabBarCompact, tabResetToken: resetTokenBinding(for: .personal), isActive: selectedTab == .personal, isFrontmost: selectedTab == .personal && !rootSheetIsCoveringTabs, privateHubOpener: privateHubOpener)
            }
            .tabPage(.personal)
        }
        // Paging is OFF: the floating tab bar is the navigation. `.page` style handed every
        // horizontal drag not swallowed by an inner scroller to the pager, so a drag on Home's
        // polaroid strip (hit-testing disabled), the mood row, or "Recent bites" flipped the user
        // onto Food mid-gesture. Making the strip hit-testable is not a fix — a non-scrolling view
        // still lets the pager take the drag — so the page style is gone entirely and tab switching
        // is deliberate (tab-bar taps only). That also subsumes the old camera-session special case
        // (a `.scrollDisabled` while the camera took over the tab), which existed only to stop a stray
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

    /// Whether the World map is what the person sees: launch done, Home, no panel over it, no root sheet.
    /// The companion's first line and the location updates wait for the launch screen to lift.
    private var isWorldMapFrontmost: Bool {
        launcher.isDone && selectedTab == .home && worldOverlay == nil && !rootSheetIsCoveringTabs
    }

    /// The item bar, over the map only (every panel covers it), behind the keyboard, 26 pt off the
    /// physical bottom. The clear full-height container is what reaches into the home indicator's safe
    /// area: a fixed-height bar ignoring it on its own stays where the safe area ends. Clear takes no
    /// touches and is no element, so the map under it stays reachable.
    @ViewBuilder
    private var worldItemBarOverlay: some View {
        if selectedTab == .home && worldOverlay == nil {
            ZStack(alignment: .bottom) {
                Color.clear
                // The session on Home (b3-home-session): the green session button bottom left, the
                // mirror of the blue button, beside the item bar's left end. It draws nothing outside a
                // session, and hosts the session's prompts only while the map is in front and the blue
                // button's camera is not over it (one surface for the prompts at a time).
                WorldSessionButton(store: store, isFrontmost: isWorldMapFrontmost && !isWorldCameraOpen)
                    .padding(.bottom, WorldMapHome.bottomLift)
                // For the hour after a session the same corner is the gold shop button (b4-mem-home-shop);
                // it draws nothing during a session, so the two never show together.
                WorldShopButton(store: store) { openFriends(.friendShop) }
                    .padding(.bottom, WorldMapHome.bottomLift)
                WorldItemBar(onOpen: openWorldPanel)
                    .padding(.horizontal, 9)
                    .padding(.bottom, WorldItemBar.bottomGap)
            }
            .ignoresSafeArea(edges: .bottom)
            .transition(.opacity)
        }
    }

    /// The panel that is not a tab, open over everything: Today (today's whole Home until the Today
    /// panel of step 4), Log (Home's Quick log and mood cards) or Settings.
    @ViewBuilder
    private var worldOverlayPanel: some View {
        if let panel = worldOverlay {
            WorldPanelFrame(panel: panel, onClose: closeWorldPanel) {
                if panel == .settings {
                    SettingsSheet(store: store, onClose: closeWorldPanel)
                        .environment(lockService)
                        .environment(storagePreferencesStore)
                } else {
                    HomeView(
                        store: store,
                        healthKitService: healthKitService,
                        activeSheet: $activeSheet,
                        selectedTab: $selectedTab,
                        privateHubSection: $privateHubSection,
                        isTabBarCompact: $isHomeTabBarCompact,
                        tabResetToken: resetTokenBinding(for: .home),
                        periodStore: periodStore,
                        stressService: stressService,
                        isActive: !rootSheetIsCoveringTabs,
                        onMealsLogged: mealLogReporter,
                        presentation: panel == .log ? .quickLog : .today,
                        stampBookRequest: panel == .today ? $pendingStampBook : .constant(false)
                    )
                }
            }
            .transition(.opacity)
        }
    }

    /// Opens a World panel: a tab panel by selecting its tab (so every tab gate runs as it always
    /// did), any other over the map.
    private func openWorldPanel(_ panel: WorldPanel) {
        if let tab = panel.tab {
            worldOverlay = nil
            selectedTab = tab
        } else {
            worldOverlay = panel
        }
    }

    /// Opens the Album panel at one of its pages (Friends nearby, Activities, Friend shops): the page is
    /// handed over first, so the panel pushes it as it opens.
    private func openFriends(_ route: FriendsRoute) {
        pendingFriendsRoute = route
        openWorldPanel(.friends)
    }

    /// Closes whatever panel is open and returns to the map. Closing Settings does what dismissing
    /// its sheet always did: re-arm Health observation and refresh workouts.
    private func closeWorldPanel() {
        if worldOverlay == .settings {
            configureHealthChangeObservation()
            Task { await store.refreshWorkoutsFromHealth() }
        }
        worldOverlay = nil
        if selectedTab != .home { selectedTab = .home }
    }

    /// The scene behind every page. Parchment always: the session camera used to take over the
    /// Friends tab and darken this scene, but it is a full-screen cover now that paints its own
    /// (b3-friends-session), so the takeover's dark scene is retired with it.
    private var sceneBackground: Color {
        Color.parchment
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
        case .settings, .recipeBook, .trends, .milestones, .sillyStats, .stressExplainer, .firstAid:
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
            // Full height like every World sheet (`b3-meal`; the chrome no longer reads detents). The
            // reporter, not a bare closure: a meal kept without its photo lands on the toast as a caveat.
            MealSheet(store: store, onLogged: mealLogReporter)
                .fernletSheetChrome(anchor: "sheet.meal", detents: [.large])
        case .recipe:
            // "Log & save" reports its meal to the toast, which shows once this sheet has closed.
            RecipeSheet(store: store, onMealsLogged: mealLogReporter)
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
                onMealsLogged: mealLogReporter
            )
            .fernletSheetChrome(anchor: "sheet.recipeBook", detents: [.large])
        case .trends:
            TrendsModal(signals: store.derivedSignals)
                .fernletSheetChrome(anchor: "sheet.trends", detents: [.large])
        case .milestones:
            // Artboard 3f: one rule for read-only destinations from Home — they present as large
            // sheets, matching Trends, First aid and the gear. MilestonesView carries its own
            // NavigationStack so the keepsake shelf pushes inside the sheet's own stack.
            // World build: MilestonesView is the Stamp book in a sheet and carries its own
            // `fernletSheet()`, so the presenter adds no sheet chrome of its own (a second frame would
            // draw a second grabber). The stamp banner's route; Today pushes the same page.
            MilestonesView(store: store)
                .uxScreenAnchor("sheet.milestones")
                .keyboardDoneToolbar()
                .worldDesignLanguage()
        case .sillyStats:
            SillyStatsView(store: store)
                .uxScreenAnchor("sheet.sillyStats")
                .keyboardDoneToolbar()
                .worldDesignLanguage()
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
        case .logPeriod(let targetDate, let editingRecord):
            LogPeriodSheet(periodStore: periodStore, targetDate: targetDate, editingRecord: editingRecord)
                .fernletSheetChrome(anchor: "sheet.logPeriod", detents: [.large])
                .environment(lockService)
                .environment(storagePreferencesStore)
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
        guard healthKitService.isCapabilityRequestedAndEnabled(.bodyProfile) else { return }

        do {
            let healthProfile = try await healthKitService.loadBodyProfile()
            try Task.checkCancellation()
            guard healthProfile.appliedFieldCount > 0 else { return }
            // Device-local, laid over the typed profile — never written into the synced settings.
            store.recordHealthImportedBodyProfile(healthProfile)
        } catch {
            // Health profile import is optional; manual settings remain the fallback. Event name plus
            // the error only — never a health value.
            FernletAuditLog.log("health.profileAutoImportSkipped", context: ["error": String(describing: error)])
        }
    }

    private func autoImportHealthContextIfAvailable() async {
        guard !didAutoImportHealthContext else { return }
        didAutoImportHealthContext = true
        let allowed = store.allowedHealthCapabilities(from: Set(HealthCapability.allCases))
        let capabilities = healthKitService.requestedAndEnabledCapabilities(from: allowed)
        guard !capabilities.isEmpty else { return }

        do {
            let context = try await healthKitService.loadDailyHealthContext(
                referenceDate: .now,
                capabilities: capabilities
            )
            try Task.checkCancellation()
            store.updateHealthContext(context)
        } catch {
            // Health context import is optional; manual app entries remain available.
            FernletAuditLog.log("health.contextAutoImportSkipped", context: ["error": String(describing: error)])
        }
    }

    /// Launch performs the initial Health reads. After that, payload-free HealthKit observers are
    /// the only daily-context trigger; tab selection and ordinary view lifecycle never query Health.
    private func configureHealthChangeObservation() {
        let capabilities: Set<HealthCapability> = [
            .bodyProfile, .cycleTracking, .bodyContext, .activityContext,
            .mindfulness, .intimateLogging
        ]
        do {
            try healthKitService.startObservingChanges(for: capabilities) { type in
                scheduleHealthRefreshAfterObservedChange(typeIdentifier: type.identifier)
            }
        } catch {
            FernletAuditLog.log(
                "health.changeObservationUnavailable",
                context: ["error": String(describing: error)]
            )
        }
    }

    /// How long a burst of Health change notifications is allowed to accumulate before one refresh
    /// runs. Named rather than inline so the invariant can be pinned: `269003c` reduced a
    /// per-sample-type refresh storm to one refresh per batch, and a shortened window (or a dropped
    /// `cancel()` below) reinstates that churn with nothing failing —
    /// `HealthKitLifecycleBoundaryTests.theObservedHealthRefreshStaysCoalesced()` is what notices.
    ///
    /// 500 ms is chosen to outlast a single `HKHealthStore.save` batch, which delivers its observer
    /// callbacks within a few tens of milliseconds, while staying short enough that a refresh still
    /// feels immediate.
    static let healthChangeCoalescingWindow: Duration = .milliseconds(500)

    /// A Health write can notify several sample types in one batch. Newest-wins coalescing turns
    /// that burst into one profile/context refresh and cancellation prevents an older result from
    /// updating state after a newer notification supersedes it.
    private func scheduleHealthRefreshAfterObservedChange(typeIdentifier: String) {
        pendingObservedHealthTypeIdentifiers.insert(typeIdentifier)
        healthRefreshTask?.cancel()
        healthRefreshTask = Task {
            do {
                try await Task.sleep(for: Self.healthChangeCoalescingWindow)
            } catch {
                return
            }
            let changedTypes = pendingObservedHealthTypeIdentifiers
            pendingObservedHealthTypeIdentifiers.removeAll()
            await refreshHealthAfterObservedChange(typeIdentifiers: changedTypes)
        }
    }

    private func refreshHealthAfterObservedChange(typeIdentifiers: Set<String>) async {
        if !typeIdentifiers.isDisjoint(with: Self.bodyProfileTypeIdentifiers) {
            await refreshBodyProfileAfterObservedChange()
        }
        guard !Task.isCancelled else { return }
        if !typeIdentifiers.isSubset(of: Self.bodyProfileTypeIdentifiers) {
            await refreshDailyContextAfterObservedChange()
        }
        guard !Task.isCancelled else { return }
        if !typeIdentifiers.isDisjoint(with: Self.stressTypeIdentifiers) {
            await stressService.refresh()
        }
        reloadPeriodEntriesAfterObservedChangeIfNeeded(typeIdentifiers)
    }

    private func refreshBodyProfileAfterObservedChange() async {
        guard healthKitService.isCapabilityRequestedAndEnabled(.bodyProfile) else { return }
        do {
            let profile = try await healthKitService.loadBodyProfile()
            try Task.checkCancellation()
            guard profile.appliedFieldCount > 0 else { return }
            // Device-local, laid over the typed profile — never written into the synced settings.
            store.recordHealthImportedBodyProfile(profile)
        } catch is CancellationError {
            return
        } catch {
            FernletAuditLog.log("health.profileChangeRefreshSkipped", context: [
                "error": String(describing: error)
            ])
        }
    }

    private func refreshDailyContextAfterObservedChange() async {
        do {
            let allowed = store.allowedHealthCapabilities(from: Set(HealthCapability.allCases))
            let capabilities = healthKitService.requestedAndEnabledCapabilities(from: allowed)
            guard !capabilities.isEmpty else { return }
            let context = try await healthKitService.loadDailyHealthContext(
                referenceDate: .now,
                capabilities: capabilities
            )
            try Task.checkCancellation()
            store.updateHealthContext(context)
        } catch is CancellationError {
            return
        } catch {
            FernletAuditLog.log("health.contextChangeRefreshSkipped", context: [
                "error": String(describing: error)
            ])
        }
    }

    private func reloadPeriodEntriesAfterObservedChangeIfNeeded(_ identifiers: Set<String>) {
        guard !identifiers.isDisjoint(with: Self.cycleTypeIdentifiers),
              privateHubSection == .cycle,
              lockService.isUnlocked(for: .privateHub) else { return }
        periodLoadTask?.cancel()
        periodLoadTask = Task {
            await loadPeriodEntriesIfPossible()
            settlePeriodEntriesAfterLoad()
        }
    }

    private static let bodyProfileTypeIdentifiers: Set<String> = [
        HKQuantityTypeIdentifier.height.rawValue,
        HKQuantityTypeIdentifier.bodyMass.rawValue
    ]
    private static let stressTypeIdentifiers: Set<String> = [
        HKQuantityTypeIdentifier.heartRateVariabilitySDNN.rawValue,
        HKQuantityTypeIdentifier.restingHeartRate.rawValue,
        HKQuantityTypeIdentifier.respiratoryRate.rawValue,
        HKQuantityTypeIdentifier.appleSleepingWristTemperature.rawValue,
        HKCategoryTypeIdentifier.sleepAnalysis.rawValue
    ]
    private static let cycleTypeIdentifiers: Set<String> = [
        HKCategoryTypeIdentifier.menstrualFlow.rawValue,
        HKQuantityTypeIdentifier.basalBodyTemperature.rawValue,
        HKCategoryTypeIdentifier.cervicalMucusQuality.rawValue,
        HKCategoryTypeIdentifier.intermenstrualBleeding.rawValue,
        HKCategoryTypeIdentifier.ovulationTestResult.rawValue
    ]

    /// Scrubs every private cache immediately, then hydrates only the selected synchronous store
    /// after the unlock overlay has had one frame to disappear. Cycle owns its async view task.
    private func updatePrivateDataActivation(
        section: PrivateHubSection,
        lockState: FernletLockState
    ) {
        privateActivationTask?.cancel()
        periodLoadTask?.cancel()
        // The tab closed: a settle request still in its 300 ms wait is dropped (review
        // U5-backup-v2-C-U5-3 / L-U5-R4). A set the engine already sealed still finishes uploading —
        // stopped part-way it would only orphan its own set-scoped chunks (design 2026-09-30, §5.2).
        if !lockState.isUnlocked(for: .privateHub) {
            store.privateSectionBackupSettleTask?.cancel()
            // The hub session ended: the v2 engine's once-per-session spacing resets. Its worker is not
            // stopped — a commit decrypts nothing and finishes; a restore or prepare fails its next
            // gate (the hub key is gone).
            if requestedSealedBackupV2Settle {
                requestedSealedBackupV2Settle = false
                store.sealedBackupHubSessionEnded()
            }
        }
        store.deactivateSealedJournals()
        worryBoxService.deactivate()
        scrubPeriodDataIfNeeded()
        guard selectedTab == .personal,
              lockState.isUnlocked(for: .privateHub),
              section != .cycle else { return }
        privateActivationTask = Task {
            do {
                try await Task.sleep(for: .milliseconds(20))
            } catch {
                return
            }
            guard selectedTab == .personal,
                  lockService.state == lockState,
                  privateHubSection == section else { return }
            activateSelectedPrivateData(section: section, lockState: lockState)
        }
    }

    private func activateSelectedPrivateData(
        section: PrivateHubSection,
        lockState: FernletLockState
    ) {
        switch section {
        case .journal:
            applySealedJournalActivation(for: lockState)
        case .cycle:
            break
        case .worryBox:
            worryBoxService.updateActivation(
                lockState: lockState,
                contentKey: lockService.contentKey(for: .privateHub)
            )
        }
    }

    private func scrubPeriodDataIfNeeded() {
        guard !periodStore.entries.isEmpty
                || periodStore.prediction != nil
                || periodStore.currentPhase != .unknown else { return }
        periodStore.scrubCycleState()
        refreshPeriodContext()
    }

    /// Journal plaintext follows the `.privateHub` scope and nothing else. Written as an exhaustive
    /// switch (not a chain of `if case .unlocked`) so an unlock taken out on the progress-photo strip
    /// or the App-lock settings page lands in the DEACTIVATE branch rather than silently falling
    /// through and leaving journals decrypted from a previous hub session.
    ///
    /// The no-passcode tap opens the same scope, so it activates exactly like a passcode unlock of
    /// it; `.notConfigured` is the CLOSED no-passcode state and deactivates (the device key stays the
    /// journal's write fallback while closed — period-data design 2026-09-30, §9.17).
    private func applySealedJournalActivation(for lockState: FernletLockState) {
        switch lockState {
        case .unlocked(.privateHub), .openedWithoutPasscode(.privateHub):
            if let contentKey = lockService.contentKey(for: .privateHub) {
                store.activateSealedJournals(contentKey: contentKey)
            } else {
                store.deactivateSealedJournals()
            }
        case .unlocked, .openedWithoutPasscode, .locked, .notConfigured:
            store.deactivateSealedJournals()
        }
    }

    /// The post-`await` gate every period load runs through.
    ///
    /// `loadEntries` captures its content key BY VALUE and assigns `entries`/`prediction` after a
    /// HealthKit round trip, so a lock that lands while it is suspended (auto-lock on background, a
    /// manual re-lock, a duress wipe) would otherwise leave decrypted cycle plaintext resident — and
    /// `prediction` feeds the ungated Home outlook card. Re-checking the LIVE lock state here scrubs
    /// exactly that window, in BOTH passcode modes: `.notConfigured` is the closed no-passcode state,
    /// no longer "ordinary, ungated data" (design invariant I11).
    private func settlePeriodEntriesAfterLoad() {
        if !lockService.state.isUnlocked(for: .privateHub) {
            periodStore.scrubCycleState()
        }
        refreshPeriodContext()
    }

    /// Asks for the hub session's Sealed backup v2 settle — every payload (period, intimate logs,
    /// journal), on whichever Private section opens first, Worry Box included (design 2026-09-30,
    /// §4.5): the hub key is the same on every section, so the journal no longer waits for the Journal
    /// section (R1-BR-16). Once per hub session; the request is held on the store so "delete
    /// everything" and the tab closing can cancel the 300 ms wait before it asks. The engine runs the
    /// passes on its own held, serial worker — restore first, then export — so nothing here can write
    /// a set over a backup this iPhone has not pulled yet.
    private func requestSealedBackupSettlement() {
        guard !requestedSealedBackupV2Settle, !isSettlingSealedBackups else { return }
        isSettlingSealedBackups = true
        store.privateSectionBackupSettleTask = Task { await settleSealedBackupsAfterUnlock() }
    }

    /// The settle request's body: waits for the unlock to finish drawing, re-checks that the Private tab
    /// is selected and open, then asks the engine (once per hub session).
    private func settleSealedBackupsAfterUnlock() async {
        defer { isSettlingSealedBackups = false }
        // Backup repair is not user-visible. Give authentication, lock-gate removal, and the
        // selected section's first frame priority before any Core Data/CloudKit reconciliation.
        do {
            try await Task.sleep(for: .milliseconds(300))
        } catch {
            return
        }
        guard selectedTab == .personal,
              lockService.isUnlocked(for: .privateHub),
              !requestedSealedBackupV2Settle else { return }
        requestedSealedBackupV2Settle = true
        store.requestSealedBackupHubSettle()
    }

    /// The period leg of "delete everything": the sealed cycle records AND the legacy cycle
    /// narratives, both keyless (period-data design 2026-09-30, §9.11). BOTH are attempted whatever
    /// the first does — a throw from one must not leave the other's rows on disk — and the leg
    /// reports cleared only when both cleared, because the dialog promises the cycle history is gone.
    ///
    /// - Parameters:
    ///   - records: The gated cycle-record funnel (its delete is ungated; the app target never
    ///     constructs a raw record repository).
    ///   - narratives: The legacy narrative repository.
    /// - Returns: Whether both deletes succeeded.
    static func deletePeriodRows(records: CycleRecordStore, narratives: MenstrualNarrativeRepository) -> Bool {
        let recordsCleared = (try? records.deleteAll()) != nil
        let narrativesCleared = (try? narratives.deleteAll()) != nil
        return recordsCleared && narrativesCleared
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
        store.periodDataDeleteHook = { Self.deletePeriodRows(records: CycleRecordStore(), narratives: MenstrualNarrativeRepository()) }
        // The period store's background writers — the held legacy cycle import and any fill-on-read
        // that began before the wipe — stopped in the funnel's FIRST leg, so neither can write records
        // back into the store this wipe empties (period-data design 2026-09-30, §8.4, R2-F7).
        store.periodWritersStopHook = { [periodStore] in periodStore.cancelBackgroundWriters() }
        // Routed through the gated funnel rather than constructing a raw repository — every intimacy
        // touch goes through `IntimacyLogStore` (pinned by the app-target source grep in
        // `SensitiveSurfaceGateTests`). Its `deleteAll` is deliberately UNGATED (drops rows without
        // decrypting), so the wipe still works while hidden and while locked.
        store.intimacyDataDeleteHook = { [intimacyStore] in (try? intimacyStore.deleteAll()) != nil }
        store.journalDataDeleteHook = { (try? JournalNarrativeRepository().deleteAll()) != nil }
        // Cycle notes written while the app was locked live in a file, not in the rows above. The lock
        // service owns the buffer, so the store can only reach it through a hook.
        store.pendingNarrativeBufferPurgeHook = { [lockService] in
            // Nothing to clear beside the purge any more: Phase 3 deleted this surface's legacy
            // reader and the format migrator that healed for it, so no latch stands over the file
            // this closure removes.
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
        store.healthKitSampleDeleteHook = { [healthKitService] in
            await healthKitService.deleteAllAuthoredSamples()
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
        // The recovery lock keeps the recoverable corpus but not where someone has been: the World
        // map's sealed location history and its keys go (design page answer 16; World build only).
        lockService.installRecoveryLockPurgeHook { [store] in
            if !store.worldFog.clearAll() { FernletAuditLog.log("worldMap.recoveryLockPurge.incomplete") }
        }
        // The other half of the duress-recovery custody story, and the one that is NOT a duress path
        // at all: "Delete everything" regenerates this device's proximity identity while deliberately
        // keeping the app lock, and the recovery blob is sealed with the OLD identity key mixed into
        // its derivation. Reconciling here retires an enrollment the wipe just made unopenable, so
        // `DuressMode.recoveryLock` can neither stay armed nor be re-armed over it. Runs at launch
        // too (see the `.task` below), which covers a rotation from any other route.
        store.identityRotatedHook = { [lockService] in
            if DuressRecoveryCoordinator(
                identity: .fernletApp(),
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
        // Attaching the hook re-persists every in-memory owed-upload flag that differs, so a writer
        // that ran before this wiring (the launch seed, a launch-time scrub insert) is not lost
        // (design 2026-09-30 §4.4, R2-F14). The hook writes only on a change.
        for payload in SealedBackupBookkeeping.v2Payloads {
            Self.persistSealedBackupDeferral(store.isSealedBackupReuploadOwed(payload), payloadType: payload, in: storagePreferencesStore)
        }
        store.retiredSealedBackupClearedHook = { [storagePreferencesStore] payloadType in
            Self.clearRetiredSealedBackupMarker(payloadType, in: storagePreferencesStore)
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
        // The sealed backups iCloud holds, found by existence: a new iPhone's backup switches start
        // off, so they alone never named the old phone's backups (bug confirmation 2026-10-15 §2).
        store.sealedBackupPresenceHook = { try await CloudKitDataService().sealedBackupPresence() }
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
            // The retired payload never seals, so the store never records a deferral for it — this
            // arm is unreachable and deliberately writes nothing.
            return
        }
    }

    /// Clears the persisted "a retired payload's copy may still be in iCloud" marker after the
    /// sealed-backup launch pass has deleted that copy. Only `.sensitiveNotes` is retired; for every
    /// other payload the enable flag is the user's live consent, changed only by the Privacy & Data
    /// toggles and "delete everything", so this writes nothing for them. A static helper for the same
    /// single-writer reason as ``persistSealedBackupDeferral(_:payloadType:in:)``.
    private static func clearRetiredSealedBackupMarker(
        _ payloadType: SealedBackupPayloadType,
        in preferencesStore: StoragePreferencesStore
    ) {
        guard payloadType == .sensitiveNotes,
              preferencesStore.preferences.sealedBackupSensitiveNotesEnabled else { return }
        preferencesStore.update { $0.sealedBackupSensitiveNotesEnabled = false }
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

    /// The meal-logged toast as the food surfaces report to it (``MealLogReporter``), so a log made
    /// anywhere on the Food tab, in the recipe book, on Home or in the meal sheet lands on the same toast.
    private var mealLogReporter: MealLogReporter {
        MealLogReporter { meals, dayKey, landedWithCaveat in
            showMealLogNotification(meals, loggedTo: dayKey, landedWithCaveat: landedWithCaveat)
        }
    }

    /// Raises the meal-logged toast: Undo, Adjust for a single meal logged to today, and the spoken
    /// confirmation. `dayKey` is the day the meals went to, `nil` for today; a cook that began before
    /// midnight passes the day it began, and the toast names that day and undoes the meals from it.
    /// `landedWithCaveat` is a log that kept something to read beside it (the meal sheet's unsealed
    /// photo); the toast then lands with `caveat` rather than `done`.
    private func showMealLogNotification(_ meals: [Meal], loggedTo dayKey: String?, landedWithCaveat: Bool) {
        guard meals.isEmpty == false else { return }
        let notification = MealLogNotification(
            meals: meals, dayKey: dayKey ?? store.todayKey, todayKey: store.todayKey,
            landedWithCaveat: landedWithCaveat)
        // Deliberately does NOT switch to Home. The toast overlays the tab pages, so it shows
        // over whichever tab the log started from; jumping to Home meant a meal logged from Food
        // landed the user on another tab and cost them a tab switch to check the match.
        mealLogNotification = notification
        // A8: the meal landed — often after a "Matching…" wait. Felt at once, not after the sheet's
        // settle the announcement below waits for. B9: one haptic, `caveat` when the log kept
        // something to read, never `done` and then `caveat` (the sheet plays nothing of its own).
        FernletFeedback.system.play(notification.landingEvent)
        // The toast appears with no focus change, so without this a VoiceOver user is never told
        // the meal landed or that an Undo exists. Spoken after the logging sheet has settled.
        Task { @MainActor in
            await TaskConfirmation.mealLogged(count: meals.count).announceAfterSheetCloses()
        }

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
                // Never pull the toast out from under VoiceOver's cursor: a user who reached it at
                // second 19 would hear "Undo, button" and then nothing. While it is focused the
                // window waits, a second at a time, up to ``mealToastCursorHoldLimit``.
                for _ in 0..<Self.mealToastCursorHoldLimit
                where isMealToastUnderCursor && mealLogNotification?.id == notification.id {
                    try await Task.sleep(for: .seconds(1))
                }
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

    /// The most seconds the meal-logged toast waits past its window while VoiceOver's cursor is on
    /// it. Five minutes: far longer than reading two buttons takes, short enough that a phone set
    /// down with the cursor parked on Undo still clears the toast eventually.
    static let mealToastCursorHoldLimit = 300

    /// The bottom toast slot (artboard 4b). Overlays ``mainInterface`` outside its tab-bar inset and
    /// keyboard ignore, lifted by ``mealLogToastLift``: 8pt above the bar while the keyboard is down
    /// (where the bar's inset used to push it), 8pt above the keyboard while it is up (the bar is
    /// behind the keyboard then). The card occupies only its own frame, so VoiceOver (and touch)
    /// still reach the tab bar beneath it.
    @ViewBuilder
    private var mealLogToastOverlay: some View {
        if let notification = mealLogNotification {
            MealLogNotificationView(
                notification: notification,
                isUnderCursor: $isMealToastUnderCursor,
                onUndo: { undoLoggedMeals(notification) },
                onAdjust: { adjustLoggedMeal(notification) }
            )
            .padding(.horizontal, 16)
            .padding(.bottom, 8 + mealLogToastLift)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    /// The stamp banner on screen: the first one waiting, held back while the launch screen, a root
    /// sheet or the World Home's disposable camera (a full-screen cover) covers the tabs, so a banner is
    /// never spent where nobody can see it. A held banner stays queued and shows when the cover lifts.
    private var shownStampBanner: SillyStatKind? {
        guard launcher.isDone, !rootSheetIsCoveringTabs, !isWorldCameraOpen else { return nil }
        return store.sillyStats.pendingStampBanners.first
    }

    /// The top banner slot for a stamp earned just now (``SillyStampBanner``). Slides down from the
    /// top, or fades under Reduce Motion. Claims only its own frame, like the meal toast, so the
    /// page beneath stays reachable.
    @ViewBuilder
    private var sillyStampBannerOverlay: some View {
        if let kind = shownStampBanner {
            SillyStampBanner(kind: kind) { openStampBook(from: kind) }
                // Grows with text size up to the map's own plates' cap, so at the largest sizes it
                // holds its lines without covering half the map.
                .dynamicTypeSize(...DynamicTypeSize.accessibility2)
                .frame(maxWidth: 352)
                .padding(.horizontal, 16)
                .padding(.top, stampBannerTop)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(kind)
                .task(id: kind) { await presentStampBanner(kind) }
        }
    }

    /// How far below the top the stamp banner drops: under the status plate over the map (design
    /// `b1-stamp-banner`), under the wooden title plate in a panel.
    private var stampBannerTop: CGFloat {
        guard isWorldMapFrontmost else { return 72 }
        return dynamicTypeSize.isAccessibilitySize ? 150 : 112
    }

    /// Speaks the stamp banner for VoiceOver, holds it for its window, then lets the next one show.
    ///
    /// Cancelled when a sheet covers the banner before its window ends; the stamp then stays queued
    /// and the banner (with its announcement) comes back when the sheet closes.
    private func presentStampBanner(_ kind: SillyStatKind) async {
        // Spoken once a closing sheet has settled — and when a meal toast is up, after that toast's
        // own sentence, since an announcement cuts off the one before it. A reasoned pause, like
        // `TaskConfirmation.sheetSettle`; the owner's VoiceOver device pass is where it is heard.
        let pause = mealLogNotification == nil ? TaskConfirmation.sheetSettle : TaskConfirmation.sheetSettle + Self.stampAfterMealToastPause
        // Read at post time, not at view construction: VoiceOver can be turned on mid-session. The
        // banner opens the stamp book, so an assistive user gets the action window.
        let window = FernletDismissalWindow.system.window(
            standard: .seconds(4),
            assistive: FernletDismissalWindow.assistiveActionWindow)
        do {
            try await Task.sleep(for: pause)
            FernletAnnouncer.system.announce(.status, resolved: SillyStampCopy.announcement(for: kind))
            try await Task.sleep(for: window)
        } catch {
            // Covered by a sheet, or the app is going away: the banner stays queued.
            return
        }
        store.sillyStats.bannerShown(kind)
    }

    /// How long the stamp's announcement waits behind the meal toast's ("Meal logged. Undo is at
    /// the bottom of the screen.") — about the time that sentence takes to speak.
    static let stampAfterMealToastPause: Duration = .seconds(3)

    /// The stamp banner's tap: opens Today and pushes the Stamp book at its stamps (owner, 2026-10-24).
    private func openStampBook(from kind: SillyStatKind) {
        store.sillyStats.bannerShown(kind)
        openStampBookInToday()
    }

    /// Opens the Today panel over Home and asks it to push the Stamp book at its stamps: the stamp
    /// banner's tap and the stamp widget's land the same way.
    private func openStampBookInToday() {
        pendingStampBook = true
        if selectedTab != .home { selectedTab = .home }
        openWorldPanel(.today)
    }

    /// The toast's "Undo": removes the just-logged meal(s) from the day they were logged to — for
    /// today exactly as the meal row's X does (`store.deleteMeal`, sealed photo cleanup and AI-retry
    /// clearing included). Only the meals actually removed are announced: a past day's write can
    /// fail, and "removed" must not be said over a meal that is still there.
    private func undoLoggedMeals(_ notification: MealLogNotification) {
        var removedCount = 0
        for meal in notification.meals {
            if store.deleteMeal(meal, loggedTo: notification.dayKey) { removedCount += 1 }
        }
        if mealLogNotification?.id == notification.id {
            mealLogNotification = nil
        }
        guard removedCount > 0 else { return }
        TaskConfirmation.mealUndone(count: removedCount).announce()
    }

    /// The toast's "Adjust": opens the meal-correction sheet for the single just-logged meal.
    /// A multi-meal log has no single target, and the correction sheet edits today's meals only, so
    /// the view offers Adjust only when `notification.adjustableMeal` exists — this guard is the
    /// belt to that suspender.
    private func adjustLoggedMeal(_ notification: MealLogNotification) {
        guard let meal = notification.adjustableMeal else { return }
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
            consumePendingMessagesRecipeImport()
        }
    }

    private func handleMessagesRecipeImportDismiss() {
        messagesRecipeImport = nil
        messagesWorkoutPlanImport = nil
        consumePendingNotificationSheet()
        consumePendingMessagesRecipeImport()
    }

    /// Hands this view's edges — a tab change, a lock-state change, the presence opt-in moving, the
    /// age record moving, the session's liveness moving, and the launch wiring — to the run-policy
    /// funnel (network migration P7 item 3), with the lock service's duress fact read fresh at the
    /// edge and the scene facts the last scene edge handed down through `FernletApp`.
    ///
    /// P9-3-A's fix (2026-09-22) retired the app-lock fact from the policy, and the lock-state edge
    /// stays: a duress unlock moves the lock state and `isDuressSessionActive` together, so that
    /// edge is this view's duress feed (a belt — `FernletApp`'s duress observer feeds it too), and
    /// every pass reconciles a listener whose radio no longer matches its verdict. It is not a gate
    /// re-entry pass: an unchanged gate is a no-op push. What used to be three private guards here
    /// (`shouldListenForRecipeShares`, `shouldRunPresence`, the Friends three-way arm) is one table,
    /// `ProximityRunPolicy`, and what used to be six direct radio calls is one executor,
    /// `ProximityRunSeams.swift`; this view speaks no radio verb (`ProximityRunSeamsTests`).
    private func applyProximityRunPolicyFromView() {
        store.applyProximityRunPolicy(duressSessionActive: lockService.isDuressSessionActive)
    }

    // Phase 3a: the clothing-shop listener chain that lived here is gone — the shop rides the friend
    // mesh (FernletSocial's `MeshClothingShop`, the store's `meshFeatures.clothingShop`), whose radio
    // lifecycle is user-driven (startJoin/leaveSession), and the `allowNearbyClothingShares` opt-out is
    // payload-layer (providers wired in FernletStore.meshFeatures). There is deliberately NO scene-dip
    // clearing of the shop's held catalogs: the post-session window outlives the session by design, and
    // radio privacy is the mesh lifecycle's job.

    /// Away-hearts drop sync (bitchat adoptions Increment 3), on the same tab / scene / lock edges
    /// the radio listener chain used to carry it on — beside the run policy now, not inside it,
    /// because it is a CloudKit sync and not a radio. Reentrancy-guarded inside the service and a
    /// consent-gated no-op while `heartsAwayDelivery` is off, so this costs nothing when unused.
    ///
    /// Each pass is a full public-database round trip (account check + upload flush + a tag query
    /// per friend + cleanup). `syncNow()` rate-limits itself to `HeartDropService.minimumSyncInterval`
    /// — the floor lives in the service so every caller inherits it. Sends are unaffected:
    /// `queueHeart` schedules its own pass directly, so a heart still leaves immediately.
    ///
    /// `scenePhase == .active` here is the sync's own foreground rule, unchanged; the radios' rule is
    /// the policy's, where `.inactive` is foreground.
    private func syncAwayHeartsIfActive() {
        guard scenePhase == .active else { return }
        store.heartDropService.syncNow()
        // Consent is off but our own records may still be on the public database. Retrying here
        // is what keeps "off" eventually true; it self-cancels once nothing is outstanding.
        //
        // The condition is DERIVED (consent off AND the outbox still names uploaded records),
        // not a flag the toggle set, so this one call covers three cases the old wiring missed:
        // a purge that failed at toggle-off, a purge still owed from a PREVIOUS launch (a
        // process flag died with the process; the outbox did not), and consent withdrawn on
        // ANOTHER device — `heartsAwayDelivery` rides the synced snapshot, so it lands here as a
        // state change that never runs this device's setter. The launch wiring reaches this same
        // call, which is what makes the relaunch case fire without waiting for a scene transition.
        store.retryHeartsAwayPurgeIfNeeded()
    }

    // P7 item 3: `startFriendsDiscovery()`, `armDiscoveryTimeout()` and `stopFriendsDiscovery()` —
    // the Friends three-way arm, the tab's half of door 3 and the `hasCommittedPeer`-guarded
    // stand-down — moved out of this view into `ProximityRunTransition` (the decision) and the
    // store's executor (`ProximityRunSeams.swift`); `FriendsDiscoveryEntry` is still the three-way,
    // unmoved.
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

    /// The presentation chrome every routed sheet shares: the UX-test screen anchor, the World sheet
    /// frame (``SwiftUI/View/fernletSheet()``: full height, paper, the ink top edge and the wooden
    /// grabber), the moss tint, the keyboard "Done" accessory, and the one design language.
    ///
    /// One modifier rather than the same lines repeated per case — the values are identical across
    /// all 22 sheets except the anchor.
    ///
    /// World build (Batch 3, owner 2026-10-24): every sheet is full height, so `detents` is no longer
    /// read. The parameter stays so every call site (here and in the Food tab) keeps compiling while the
    /// lanes still pass one; the presenter's own detent and grabber lines would otherwise win over the
    /// sheet's `fernletSheet()` and keep the half detent and the system grabber.
    ///
    /// `worldDesignLanguage()` is applied here, on the sheet's own content, because a presented sheet
    /// does not inherit the root's toggle and form styles: without it a routed sheet's switches and
    /// Forms drew the system look under the framed paper.
    ///
    /// The last two are here rather than per sheet because a routed sheet is attached to
    /// `launchRoot`, OUTSIDE the `.tint(Color.moss)` on `mainInterface`: every un-tinted system
    /// control inside one (the Effort slider, the recipe unit menu, the cycle Observation pickers,
    /// the Settings hub's toggles and links) rendered Apple blue. And numeric keypads have no return
    /// key, so without ``SwiftUI/View/keyboardDoneToolbar()`` the pad floated over the Save bar with
    /// no way to dismiss it.
    ///
    /// That Done reaches only a sheet with no `NavigationStack` of its own. Where the sheet's view
    /// wraps a stack (meal, recipe, recipe book, Settings, First aid), every page of the stack —
    /// its root included — is hosted in its own controller and never sees it, so those pages
    /// declare their own (2026-10-01).
    func fernletSheetChrome(anchor: String, detents _: Set<PresentationDetent>) -> some View {
        uxScreenAnchor(anchor)
            .fernletSheet()
            .tint(Color.moss)
            .keyboardDoneToolbar()
            .worldDesignLanguage()
    }
}

/// The payload behind the transient "meal logged" toast: the meals a sheet just logged, plus
/// their summed macros.
///
/// Built by `ContentView.showMealLogNotification`; the fresh `id` per instance is what lets a
/// newer toast supersede an older one's auto-dismiss timer. Carries the full `[Meal]` (FLOW-15)
/// so the toast's Undo can remove exactly what was logged and Adjust can open the correction
/// sheet for a single-meal log. Carries the day the meals went to (B1, 2026-10-20): a cook that
/// began before midnight logs to the day it began, and the toast must neither undo from today nor
/// pass that meal off as today's.
struct MealLogNotification: Identifiable, Equatable {
    let id = UUID()
    /// The just-logged meals, in the order the sheet reported them. Never empty (the presenter
    /// guards), and the Undo action deletes each one exactly as the meal row's X does.
    let meals: [Meal]
    /// The day key the meals were logged to. Undo removes them from this day.
    let dayKey: String
    /// Whether ``dayKey`` was today when the meals were logged. False for a back-dated log, which
    /// names its day on the toast and offers no Adjust (the correction sheet edits today's meals).
    let isLoggedToToday: Bool
    /// Whether the log kept something the person needs to read beside it: the meal sheet's photo
    /// that couldn't be sealed, whose notice the sheet stays open on.
    let landedWithCaveat: Bool

    /// Creates the payload for meals logged to `dayKey`, judged against today's `todayKey`.
    init(meals: [Meal], dayKey: String, todayKey: String, landedWithCaveat: Bool = false) {
        self.meals = meals
        self.dayKey = dayKey
        self.isLoggedToToday = dayKey == todayKey
        self.landedWithCaveat = landedWithCaveat
    }

    /// The one notification haptic the toast lands with (B9): `caveat` for a log that kept something
    /// to read, `done` otherwise. Never both: back to back in one instant they blur into one buzz.
    var landingEvent: FernletFeedbackEvent {
        landedWithCaveat ? .caveat : .done
    }

    /// The one logged meal when exactly one was logged (a multi-meal log has no single meal to
    /// name or correct).
    var singleMeal: Meal? {
        meals.count == 1 ? meals.first : nil
    }

    /// The Adjust target: the single logged meal, and only when it went to today, because the
    /// correction sheet edits today's meals and nothing else.
    var adjustableMeal: Meal? {
        isLoggedToToday ? singleMeal : nil
    }

    /// The day the toast names because it is not today, or `nil` for a log to today.
    var otherLoggedDay: Date? {
        isLoggedToToday ? nil : FernletDate.date(fromDayKey: dayKey)
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
    /// Set while VoiceOver's cursor is on any part of the toast, so the presenter's timer waits
    /// instead of removing the element being read.
    @Binding var isUnderCursor: Bool
    /// Removes the just-logged meal(s); the presenter owns the store call.
    var onUndo: () -> Void
    /// Opens the correction sheet for ``MealLogNotification/adjustableMeal``; only invoked when the
    /// Adjust pill renders (single-meal logs to today).
    var onAdjust: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    /// Which of the toast's three elements VoiceOver's cursor is on, if any. Read, never written:
    /// the toast does not take focus — the announcement says where it is — it only notices it.
    @AccessibilityFocusState private var cursor: ToastPart?

    /// The toast's accessibility elements, for ``cursor``.
    private enum ToastPart: Hashable {
        case message, undo, adjust
    }

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
        .onChange(of: cursor) { _, part in isUnderCursor = part != nil }
        // The toast can leave while focused (Undo, a newer log); the hold must not outlive it.
        .onDisappear { isUnderCursor = false }
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
        .accessibilityFocused($cursor, equals: .message)
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
    /// A log to another day leads with that day ("Sun, Oct 19 · Dinner · …"), so a meal the Food
    /// tab's today list will not show is never mistaken for today's.
    private var detailText: Text {
        let macros = notification.macros
        if let day = notification.otherLoggedDay {
            return otherDayDetailText(day, macros: macros)
        }
        if let meal = notification.singleMeal {
            return Text("\(meal.mealType.displayName) · P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
        }
        return Text("P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
    }

    /// ``detailText`` for a back-dated log: the day, in the locale's own short form, then the slot
    /// (single meal only) and the macros.
    private func otherDayDetailText(_ day: Date, macros: MacroTotals) -> Text {
        let dayFormat = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        if let meal = notification.singleMeal {
            return Text("\(day, format: dayFormat) · \(meal.mealType.displayName) · P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
        }
        return Text("\(day, format: dayFormat) · P \(macros.protein)g · C \(macros.carbs)g · F \(macros.fat)g")
    }

    /// Undo (always) and Adjust (single-meal logs to today only), side by side — or stacked
    /// full-width, one per row, at accessibility sizes (artboard 4b·AX3).
    @ViewBuilder
    private var actionButtons: some View {
        let expands = dynamicTypeSize.isAccessibilitySize
        let layout = expands ? AnyLayout(VStackLayout(spacing: 10)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Button("Undo", action: onUndo)
                .buttonStyle(MealToastPillStyle(prominent: false, expands: expands))
                .accessibilityIdentifier("mealToast.undo")
                .accessibilityFocused($cursor, equals: .undo)
            if notification.adjustableMeal != nil {
                Button("Adjust", action: onAdjust)
                    .buttonStyle(MealToastPillStyle(prominent: true, expands: expands))
                    .accessibilityIdentifier("mealToast.adjust")
                    .accessibilityFocused($cursor, equals: .adjust)
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
/// store exists) the companion — drawn as the World launch scene (design `b2-launch`): the dotted page,
/// the pixel companion, the Fraunces greeting, the status line and the framed moss bar, which stands
/// still under Reduce Motion (``WorldLaunchScene`` handles that itself).
///
/// Shown twice per cold launch — by ``FernletApp`` while ``FernletStoreLoader`` runs (no
/// companion) and by ``ContentView`` while ``LaunchPreparationService`` prepares (with the
/// companion) — so both phases match. Status text falls back to
/// `LaunchPreparationService.initialStatusMessage` so the line never renders empty.
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
        if (5..<12).contains(hour) {
            return String(localized: "launch.greeting.morning", defaultValue: "Good morning.",
                          comment: "Launch screen greeting before noon, above the loading line.")
        }
        if (12..<17).contains(hour) {
            return String(localized: "launch.greeting.afternoon", defaultValue: "Good afternoon.",
                          comment: "Launch screen greeting from noon to 5 pm, above the loading line.")
        }
        return String(localized: "launch.greeting.evening", defaultValue: "Good evening.",
                      comment: "Launch screen greeting from 5 pm until 5 am, above the loading line.")
    }

    var body: some View {
        WorldLaunchScene(greeting: greeting, status: displayedStatusMessage,
                         companion: showsCompanion ? (companionState, companionAppearance) : nil)
            // UX-test anchor (a frozen token, never display text): `UXTestApp.launch` waits for this
            // to leave the tree before a test's first tap. `.contain` keeps the greeting and the status
            // line individually readable, exactly as they were.
            .uxScreenAnchor("launch.screen")
    }
}

#Preview {
    ContentView(store: FernletStore(), healthKitService: HealthKitService())
}
