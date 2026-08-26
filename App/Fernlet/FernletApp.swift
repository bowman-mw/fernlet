import SwiftUI
import CloudKitSync
import FernletFoundation
import FernletLock
import HealthKitGateway
import LocalPersistence
import PrivateStoreCore
import UserNotifications
#if canImport(UIKit)
import UIKit
import FernletDomainModel
import FernletUI
#endif

/// The `@main` scene entry point: process-wide service bootstrap plus the launch state machine.
///
/// Owns the app-lifetime singletons a cold launch needs before any view exists — the
/// `FernletLockService` (keychain-backed app lock), the `StoragePreferencesStore`, and the
/// ``FernletStoreLoader`` that loads ``FernletStore`` off the first frame. `init()` runs the
/// must-happen-before-launch wiring: installing ``CoreDataHealthKitCacheCleaner`` into the
/// HealthKit gateway's static seam, setting ``FernletNotificationDelegate`` on the notification
/// center (so a cold-launch tap is delivered), and baking the UIKit nav-bar appearance.
///
/// The body swaps between `LaunchScreen` (preparing), onboarding or ``ContentView`` (ready), and
/// `LaunchFailureView` (failed). Scene-phase changes relock the app and flush the pending
/// snapshot save on background, and reconcile guided-workout/cooking runs made from the Live
/// Activity on re-activation. Storage-preference changes reload `PersistenceController` (queueing
/// a follow-up reload when one is already in flight) and re-apply the sealed store's and the
/// local day blob's backup exclusion; a delayed post-startup task activates CloudKit sync so
/// launch never waits on it. The ready phase also runs the one-shot Phase-6
/// `BackupExclusionLaunchGate` (fresh installs default to backup-excluded; existing installs get
/// a one-time honest trade-off alert); a launch whose preferences keychain was unreadable defers
/// the gate and retries it on each foreground activation. DEBUG launch arguments
/// (`-resetOnboarding`, `-completeOnboarding`, `FERNLET_UI_TEST_OPEN_PRIVACY_DATA`) support the
/// UI-test harness.
@main
struct FernletApp: App {
    @State private var lockService = FernletLockService()
    @State private var storagePreferencesStore = StoragePreferencesStore()
    /// App-lifetime owner of the capture-friction triggers (screenshot pulse + capture cover)
    /// behind `captureProtected(surface:)` on the Private-tab surfaces. Injected below in
    /// `readyContent(store:)` and re-injected per sheet case in `ContentView`, never
    /// self-discovered — the injection IS the test seam, since neither real trigger can be
    /// driven from automation. `FERNLET_UI_TEST_FORCE_CAPTURE=1` forces the Tier-2 cover for the
    /// capture-protection UI tests (DEBUG-only; the flag is a hard-coded no-op in release).
    @State private var captureProtection = CaptureProtectionState(
        captureOverride: UITestSupport.forceCaptureCover ? true : nil
    )
    @State private var loader = FernletStoreLoader()
    @AppStorage(OnboardingDefaults.hasCompletedOnboardingKey) private var hasCompletedOnboarding = false
    /// The System/Light/Dark choice, applied to the WHOLE scene — launch screen, onboarding and
    /// main UI alike. Onboarding lives outside `ContentView`, so before this it was the one surface
    /// that followed the phone while every tab and sheet was pinned by ContentView's own modifier:
    /// a dark-mode user got a dark onboarding, then a light app the moment it finished.
    @AppStorage(FernletAppearanceMode.storageKey) private var appearanceMode: FernletAppearanceMode = .system
    @State private var didScheduleStartupCloudSync = false
    @State private var pendingPreferenceReload: StoragePreferences?
    /// One-shot guard for the Phase-6 backup-exclusion launch gate — set once the gate actually
    /// RESOLVES (like `didScheduleStartupCloudSync`), so a re-fired `.task` can't re-run the
    /// resolution. Deliberately left false when the gate defers on an unreadable keychain
    /// (pre-first-unlock prewarm / background relaunch): the scene-activation hook retries until
    /// a launch can read the blob and resolve for real.
    @State private var didResolveBackupExclusionDefault = false
    /// Presents the one-time existing-install backup-exclusion prompt (see
    /// `BackupExclusionLaunchGate`); only ever set when the gate classifies this launch as an
    /// existing install with no recorded choice.
    @State private var backupExclusionPromptPresented = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // App Intents resolve this dependency before any scene exists. Registering it at process
        // startup gives background file exchange the same main-process store access as the UI.
        ExchangeIntentService.registerAppDependency()
        // Install the concrete HealthKit cache cleaner before any HealthKitService is
        // constructed. The gateway module has NO default cleaner (WI-2: defaultCacheClearer
        // is nil, so disableIntegration() fails closed rather than silently skipping the
        // purge); the real cleaner reaches CloudKitSync/LocalPersistence (which the gateway
        // must not depend on) and therefore lives app-side, injected through this static seam.
        HealthKitService.defaultCacheClearer = CoreDataHealthKitCacheCleaner()

        // Foreground presentation + tap deep-links for the gentle daily check-in. Must be set
        // before launch finishes so a cold-launch notification tap is delivered; `shared` keeps
        // the strong reference the weak center delegate needs.
        UNUserNotificationCenter.current().delegate = FernletNotificationDelegate.shared

        StartupTiming.beginAppLaunch()

        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-resetOnboarding") {
            UserDefaults.standard.removeObject(forKey: OnboardingDefaults.hasCompletedOnboardingKey)
            UserDefaults.standard.removeObject(forKey: OnboardingDefaults.lockSetupDeferredKey)
        }
        if ProcessInfo.processInfo.arguments.contains("-completeOnboarding") {
            UserDefaults.standard.set(true, forKey: OnboardingDefaults.hasCompletedOnboardingKey)
        }
        #endif
        // Carry the pre-three-way "Dark mode" Bool into the System/Light/Dark choice before the
        // first `@AppStorage` read below, so an existing user's app opens in the appearance they
        // picked and a fresh install starts on System.
        FernletAppearanceMode.migrateLegacyDarkModePreferenceIfNeeded()

        #if canImport(UIKit)
        UIScrollView.appearance().isDirectionalLockEnabled = true
        // The window ground behind sheets and transitions. Adaptive — the same palette the
        // `Color.parchment` token resolves — because a hard-coded light parchment flashed pale
        // behind every sheet and push while the app was rendering dark.
        UIWindow.appearance().backgroundColor = UIColor { @Sendable trait in
            // Forwards `accessibilityContrast` as well as the style (§4.2): the two UIKit
            // appearance proxies resolve the same palette the SwiftUI tokens do, so leaving the
            // contrast axis off here would make the window ground and the nav title the only two
            // surfaces in the app that ignore Increase Contrast.
            FernletThemePalette.current(for: trait.userInterfaceStyle,
                                        contrast: trait.accessibilityContrast).background
        }
        Self.configureNavigationBarAppearance()
        #endif
    }

    #if canImport(UIKit)
    /// Route pushed/sheet navigation titles through the design-system serif faces so title typography
    /// is consistent app-wide. Transparent background preserves the current look on the many screens
    /// that pair an empty nav title with an in-content `ScreenHeader`.
    private static func configureNavigationBarAppearance() {
        // Mirror Color.bark so nav titles stay legible in dark mode instead of a fixed bark.
        // `@Sendable` keeps the provider off this target's MainActor default isolation — UIKit resolves it
        // on whatever thread needs the color, and the executor check traps there. See FernletTheme.swift.
        let bark = UIColor { @Sendable trait in
            FernletThemePalette.current(for: trait.userInterfaceStyle,
                                        contrast: trait.accessibilityContrast).primaryText
        }
        // Scale the serif faces with Dynamic Type via UIFontMetrics.
        let baseInlineFont = UIFont(name: FernletFontName.dmSerifDisplay, size: 18)
            ?? .systemFont(ofSize: 18, weight: .semibold)
        let inlineFont = UIFontMetrics(forTextStyle: .headline).scaledFont(for: baseInlineFont)
        let baseLargeFont = UIFont(name: FernletFontName.frauncesSemiBold, size: 30)
            ?? .systemFont(ofSize: 30, weight: .bold)
        let largeFont = UIFontMetrics(forTextStyle: .largeTitle).scaledFont(for: baseLargeFont)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.font: inlineFont, .foregroundColor: bark]
        appearance.largeTitleTextAttributes = [.font: largeFont, .foregroundColor: bark]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
    }

    /// Re-apply the nav-bar appearance on a Dynamic Type change and push the fresh, re-scaled
    /// fonts onto already-visible bars. The appearance proxy is baked once at launch (fixed-size
    /// UIFonts), so without this titles stay frozen at the launch-time text size while the rest of
    /// the UI rescales live via `Font.custom(relativeTo:)`. Proxy changes alone only affect bars
    /// created *after* the change, so we also copy the new appearance onto every on-screen bar.
    @MainActor
    private static func refreshNavigationBarAppearanceForContentSizeChange() {
        configureNavigationBarAppearance()
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                for bar in window.navigationBars() {
                    bar.standardAppearance = UINavigationBar.appearance().standardAppearance
                    bar.scrollEdgeAppearance = UINavigationBar.appearance().scrollEdgeAppearance
                    bar.compactAppearance = UINavigationBar.appearance().compactAppearance
                    bar.setNeedsLayout()
                }
            }
        }
    }
    #endif

    var body: some Scene {
        WindowGroup {
            ZStack {
                Color.parchment.ignoresSafeArea()
                content
            }
            .preferredColorScheme(appearanceMode.colorScheme)
            .task {
                guard !shouldOpenPrivacyDataForUITest else { return }
                await loader.startIfNeeded()
            }
            .onOpenURL { _ = FernletMessagesRecipeImportRequest.request(from: $0) }
            // Relock on background and on device lock
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    if case .ready(let store) = loader.phase {
                        store.flushPendingSnapshotSave()
                    }
                    lockService.lock(reason: .background)
                } else if newPhase == .active {
                    // A launch that could not read the keychain (background relaunch / pre-first-unlock
                    // prewarm) failed CLOSED to `.locked`, which is right but sticky: on an
                    // UNCONFIGURED device it paints "unlock Fernlet" over a lock that does not exist
                    // for the whole process. Activation means protected data is readable, so re-derive
                    // the real state here. A no-op while unlocked, and while the state is already right.
                    lockService.refreshStateFromKeychain()
                    // Self-heal a sealed store whose rebuild could not re-add it — the dominant
                    // cause is the device auto-locking mid-wipe, and writing anything again means
                    // unlocking the device, which lands here. Without this the coordinator stays
                    // storeless for the whole session and every sealed write fails.
                    do {
                        try PrivatePersistenceController.shared.reloadStoreIfNeeded()
                    } catch {
                        // Benign in isolation — the next foreground activation retries — but a
                        // chronically storeless session (every sealed write failing) must be visible.
                        FernletAuditLog.log("privatePersistence.reloadStoreIfNeeded.failed", context: [
                            "trigger": "sceneActive",
                            "errorType": "\(type(of: error))"
                        ])
                    }
                    // Pick up a guided-workout finish or set/rest advance made from the Live Activity
                    // while the app was backgrounded — even if the Move tab isn't the one on screen.
                    // Roll the day FIRST (a foreground can cross local midnight without onAppear), so a
                    // finish reconciled here anchors/back-dates to the correct day.
                    if case .ready(let store) = loader.phase {
                        store.refreshCurrentDayIfNeeded()
                        store.reconcileGuidedRunFromAppGroup()
                        // Same for a cooking Next/Finish made from the Live Activity / Siri while
                        // backgrounded — reconcile even if the Food tab isn't the one on screen, so an
                        // orphan cooking activity is retired and the walker/card stay in step.
                        store.reconcileCookingRunFromAppGroup()
                        // Phase-6 gate retry: a launch that reached readyContent while the
                        // preferences keychain was unreadable (pre-first-unlock prewarm /
                        // background relaunch) DEFERRED the backup-exclusion resolution; every
                        // foreground activation retries until it resolves. A no-op once
                        // `didResolveBackupExclusionDefault` is set.
                        resolveBackupExclusionDefaultIfNeeded()
                    }
                }
            }
            #if canImport(UIKit)
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataWillBecomeUnavailableNotification
                )
            ) { _ in
                lockService.lock(reason: .protectedDataUnavailable)
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIApplication.protectedDataDidBecomeAvailableNotification
                )
            ) { _ in
                // The companion of the `willBecomeUnavailable` lock above, and the earliest moment a
                // launch that booted blind (keychain unreadable → fail-closed `.locked`) can learn what
                // the keychain actually holds. Scene activation retries the same call, but a background
                // relaunch may never become active.
                lockService.refreshStateFromKeychain()
            }
            .onReceive(
                NotificationCenter.default.publisher(
                    for: UIContentSizeCategory.didChangeNotification
                )
            ) { _ in
                Self.refreshNavigationBarAppearanceForContentSizeChange()
            }
            #endif
        }
    }

    /// The scene's main slot: the UI-test privacy-data shortcut when requested, otherwise the
    /// loader-phase switch (launch screen / ready content / failure view).
    @ViewBuilder
    private var content: some View {
        if shouldOpenPrivacyDataForUITest {
            privacyDataTestContent
        } else {
            switch loader.phase {
            case .preparing:
                LaunchScreen(statusMessage: loader.statusMessage)
                    .transition(.opacity)
            case .ready(let store):
                readyContent(store: store)
                    .transition(.opacity)
            case .failed(let error):
                LaunchFailureView(error: error) {
                    Task { await loader.retry() }
                }
                .transition(.opacity)
            }
        }
    }

    /// DEBUG-only: `FERNLET_UI_TEST_OPEN_PRIVACY_DATA=1` renders the Privacy Data settings screen
    /// directly (no store load), so its UI tests never wait on the full launch pipeline.
    private var shouldOpenPrivacyDataForUITest: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["FERNLET_UI_TEST_OPEN_PRIVACY_DATA"] == "1"
        #else
        false
        #endif
    }

    private var privacyDataTestContent: some View {
        // The environments wrap the NavigationStack, not its root view: pushed destinations and
        // presented sheets are hosted by the stack's own chrome, which on iOS 26 evaluates outside
        // the root view's injections — with them inside, pushing Health access fatals with
        // "No Observable object of type StoragePreferencesStore found". Production is unaffected
        // (ContentView injects above the Settings stack); only this standalone harness needed it.
        NavigationStack {
            PrivacyDataSettingsView()
        }
        .environment(lockService)
        .environment(storagePreferencesStore)
    }

    /// The post-load surface: onboarding until it completes, then ``ContentView``. Also watches
    /// storage-preference changes (reloading persistence / stopping workout observation) and kicks
    /// the delayed startup CloudKit-sync activation.
    @ViewBuilder
    private func readyContent(store: FernletStore) -> some View {
        Group {
            if hasCompletedOnboarding {
                ContentView(store: store)
                    .environment(lockService)
                    .environment(storagePreferencesStore)
                    .environment(captureProtection)
            } else {
                OnboardingCoordinator(
                    store: store,
                    detector: OnboardingCloudDataDetectorFactory.makeDetector()
                ) {
                    hasCompletedOnboarding = true
                }
                .environment(lockService)
                .environment(storagePreferencesStore)
                .onAppear {
                    StartupTiming.endAppLaunch()
                }
            }
        }
        .onChange(of: storagePreferencesStore.preferences) { old, new in
            let storageChanged = old.iCloudSyncEnabled != new.iCloudSyncEnabled
                || old.localBackupExcludedFromiOSBackup != new.localBackupExcludedFromiOSBackup
            if storageChanged {
                Task { await reloadPersistenceForPreferenceChange(new) }
            }
            if old.healthKitMasterEnabled && !new.healthKitMasterEnabled {
                store.stopHealthKitWorkoutObservation()
            }
        }
        .task {
            await activateCloudSyncAfterStartupIfNeeded()
        }
        // Phase-6 default-on backup exclusion. Runs here — after StoragePreferencesStore loaded in
        // `init` and the store is ready — and BEFORE onboarding can complete, which is what makes
        // the fresh-vs-existing classification sound: a genuinely fresh install still shows
        // onboarding at this moment, so it carries neither prior-use signal.
        .task {
            resolveBackupExclusionDefaultIfNeeded()
        }
        .alert("Keep Fernlet data out of device backups?", isPresented: $backupExclusionPromptPresented) {
            Button("Exclude from backups", role: .destructive) {
                BackupExclusionLaunchGate().recordPromptChoice(
                    excludeFromBackups: true,
                    store: storagePreferencesStore,
                    applyExclusionNow: applyLocalBackupExclusionNow
                )
            }
            Button("Keep in backups") {
                BackupExclusionLaunchGate().recordPromptChoice(
                    excludeFromBackups: false,
                    store: storagePreferencesStore,
                    applyExclusionNow: applyLocalBackupExclusionNow
                )
            }
        } message: {
            // The honest trade-off, matching the Privacy & Data exclude confirmation: name exactly
            // what excluding costs (no device-backup restore for the sealed store) and what it
            // doesn't (escrow-backed encrypted iCloud backups restore regardless).
            Text("Fernlet can keep its local data — including your journals, intimate logs, and "
                + "cycle notes — out of iPhone and iCloud device backups. They're encrypted with a "
                + "key that never leaves this device, so a backup can't reveal them; but if you "
                + "exclude them, they won't come back if you restore this device from a backup. "
                + "Anything you've switched on an encrypted iCloud backup for is restored from that "
                + "backup either way. You can change this anytime in Privacy & Data.")
        }
    }

    /// Defers CloudKit-sync activation ~5 s past first render so launch never blocks on iCloud.
    /// One-shot per process (`didScheduleStartupCloudSync`) and re-checks the preference after the
    /// sleep so a user who turned sync off in the window is honored.
    @MainActor
    private func activateCloudSyncAfterStartupIfNeeded() async {
        guard !didScheduleStartupCloudSync else { return }
        didScheduleStartupCloudSync = true

        guard storagePreferencesStore.preferences.iCloudSyncEnabled else { return }
        do {
            try await Task.sleep(for: .seconds(5))
        } catch {
            // `Task.sleep` throws only on cancellation: the scene task was torn down, and a
            // cancelled launch must not go on to activate sync.
            return
        }
        let current = storagePreferencesStore.preferences
        guard current.iCloudSyncEnabled else { return }
        await reloadPersistenceForPreferenceChange(current)
    }

    /// Runs the Phase-6 backup-exclusion launch gate — once per process once it actually
    /// resolves: fresh installs silently adopt the excluded default, existing installs with no
    /// recorded choice get the one-time honest trade-off alert above. When the gate defers
    /// because the preferences keychain is unreadable (a pre-first-unlock prewarmed or
    /// background-relaunched process), the one-shot flag stays unset and the scene-activation
    /// hook retries on the next foreground. Suppressed entirely under any test harness — an
    /// unanswered launch alert would deadlock every UI test, and a unit-test host would mutate
    /// the real preference blob (`UITestSupport.isTestHarnessActive`; release builds always run).
    @MainActor
    private func resolveBackupExclusionDefaultIfNeeded() {
        guard !didResolveBackupExclusionDefault else { return }
        guard !UITestSupport.isTestHarnessActive else {
            didResolveBackupExclusionDefault = true
            return
        }
        switch BackupExclusionLaunchGate().resolveAtLaunch(
            store: storagePreferencesStore,
            applyExclusionNow: applyLocalBackupExclusionNow
        ) {
        case .resolved(let needsPrompt):
            didResolveBackupExclusionDefault = true
            if needsPrompt {
                backupExclusionPromptPresented = true
            }
        case .deferredKeychainUnreadable:
            // Nothing happened (no classification, no write, no marker latch); the next
            // foreground activation retries via the scenePhase hook.
            break
        }
    }

    /// Immediately flags the two stores whose exclusion does not ride the Core Data reload — the
    /// sealed `FernletPrivate` store and the local JSON day blob — so a gate/prompt decision (or a
    /// toggle change) lands on disk in the same moment it is recorded. The synced store follows
    /// via `reloadPersistenceForPreferenceChange`, which re-applies exclusion at store load.
    @MainActor
    private func applyLocalBackupExclusionNow(_ excluded: Bool) {
        PrivatePersistenceController.shared.applyBackupExclusion(excluded: excluded)
        LocalFernletRepository().applyBackupExclusion(excluded: excluded)
    }

    /// R1/R2: how many parked preference reloads one call may replay before it stops and leaves the
    /// remainder for the next change to pick up. Replaces the former self-`await` chain, whose depth
    /// followed user behaviour.
    private static let maxChainedPreferenceReloads = 4

    /// Reloads the Core Data stack for a storage-preference change (iCloud sync on/off, backup
    /// exclusion). If a reload is already in flight the request is parked in
    /// `pendingPreferenceReload` and replayed afterwards — as a bounded loop, at most
    /// ``maxChainedPreferenceReloads`` replays per call; a failed reload is audit-logged rather
    /// than crashing the scene.
    @MainActor
    private func reloadPersistenceForPreferenceChange(_ preferences: StoragePreferences) async {
        var next: StoragePreferences? = preferences
        var budget = Self.maxChainedPreferenceReloads
        while let current = next, budget > 0 {
            budget -= 1
            next = nil
            // The sealed store is local-only and never reloads, and the local JSON day blob has no
            // reload at all — re-apply both here so a runtime toggle covers them immediately instead
            // of lagging until the next launch.
            applyLocalBackupExclusionNow(current.localBackupExcludedFromiOSBackup)
            guard !PersistenceController.shared.isReloading else {
                pendingPreferenceReload = current
                return
            }
            do {
                try await PersistenceController.shared.reload(with: current)
                next = pendingPreferenceReload
                pendingPreferenceReload = nil
            } catch {
                FernletAuditLog.log("persistence.reload.failed", context: [
                    "trigger": "appPreferencesChanged",
                    "errorType": "\(type(of: error))"
                ])
            }
        }
        if let leftover = next {
            // Budget exhausted with work still parked: leave it parked so the next preference
            // change (or the startup sync activation) replays it.
            pendingPreferenceReload = leftover
            FernletAuditLog.log("persistence.reload.chainBudgetExhausted", context: [
                "budget": "\(Self.maxChainedPreferenceReloads)"
            ])
        }
    }
}

#if canImport(UIKit)
private extension UIView {
    /// R1/R2 bound on the subtree walk below: a UIKit window tree is orders of magnitude smaller,
    /// so exhausting the budget means a pathological (or cyclic) hierarchy — return what was found.
    static let maxNavigationBarTraversal = 4096

    /// Every `UINavigationBar` in this view's subtree — used to push a re-scaled appearance onto
    /// bars that already exist (the appearance proxy only reaches bars created after it changes).
    /// Walks an explicit worklist (R1: no recursion) with a named node budget (R2).
    func navigationBars() -> [UINavigationBar] {
        var found: [UINavigationBar] = []
        var work: [UIView] = subviews
        var budget = Self.maxNavigationBarTraversal
        while let view = work.popLast(), budget > 0 {
            budget -= 1
            if let bar = view as? UINavigationBar {
                found.append(bar)
            }
            work.append(contentsOf: view.subviews)
        }
        return found
    }
}
#endif

/// Full-screen fallback for a failed store load: names the error and offers a retry.
///
/// Rendered only from ``FernletApp``'s `.failed` loader phase; the button re-runs
/// ``FernletStoreLoader/retry()`` so a transient persistence failure never strands the user on a
/// blank screen.
private struct LaunchFailureView: View {
    let error: Error
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(Color.terracotta)

            VStack(spacing: 8) {
                Text("Fernlet couldn't open")
                    .font(.fernlet(.header))
                    .foregroundStyle(Color.bark)
                    .multilineTextAlignment(.center)
                Text(error.localizedDescription)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            }

            Button("Try again", action: retry)
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onMoss)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
