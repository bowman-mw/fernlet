import SwiftUI
import CloudKitSync
import FernletFoundation
import FernletLock
import HealthKitGateway
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
/// ``LaunchFailureView`` (failed). Scene-phase changes relock the app and flush the pending
/// snapshot save on background, and reconcile guided-workout/cooking runs made from the Live
/// Activity on re-activation. Storage-preference changes reload `PersistenceController` (queueing
/// a follow-up reload when one is already in flight) and re-apply the sealed store's backup
/// exclusion; a delayed post-startup task activates CloudKit sync so launch never waits on it.
/// DEBUG launch arguments (`-resetOnboarding`, `-completeOnboarding`,
/// `FERNLET_UI_TEST_OPEN_PRIVACY_DATA`) support the UI-test harness.
@main
struct FernletApp: App {
    @State private var lockService = FernletLockService()
    @State private var storagePreferencesStore = StoragePreferencesStore()
    @State private var loader = FernletStoreLoader()
    @AppStorage(OnboardingDefaults.hasCompletedOnboardingKey) private var hasCompletedOnboarding = false
    @State private var didScheduleStartupCloudSync = false
    @State private var pendingPreferenceReload: StoragePreferences?
    @Environment(\.scenePhase) private var scenePhase

    init() {
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
        #if canImport(UIKit)
        UIScrollView.appearance().isDirectionalLockEnabled = true
        UIWindow.appearance().backgroundColor = UIColor(red: 0.961, green: 0.937, blue: 0.878, alpha: 1)
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
            FernletThemePalette.current(for: trait.userInterfaceStyle).primaryText
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
            .task {
                guard !shouldOpenPrivacyDataForUITest else { return }
                await loader.startIfNeeded()
            }
            // Relock on background and on device lock
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .background {
                    if case .ready(let store) = loader.phase {
                        store.flushPendingSnapshotSave()
                    }
                    lockService.lock(reason: .background)
                } else if newPhase == .active {
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
        NavigationStack {
            PrivacyDataSettingsView()
                .environment(lockService)
                .environment(storagePreferencesStore)
        }
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
    }

    /// Defers CloudKit-sync activation ~5 s past first render so launch never blocks on iCloud.
    /// One-shot per process (`didScheduleStartupCloudSync`) and re-checks the preference after the
    /// sleep so a user who turned sync off in the window is honored.
    @MainActor
    private func activateCloudSyncAfterStartupIfNeeded() async {
        guard !didScheduleStartupCloudSync else { return }
        didScheduleStartupCloudSync = true

        guard storagePreferencesStore.preferences.iCloudSyncEnabled else { return }
        try? await Task.sleep(for: .seconds(5))
        guard !Task.isCancelled else { return }
        let current = storagePreferencesStore.preferences
        guard current.iCloudSyncEnabled else { return }
        await reloadPersistenceForPreferenceChange(current)
    }

    /// Reloads the Core Data stack for a storage-preference change (iCloud sync on/off, backup
    /// exclusion). If a reload is already in flight the request is parked in
    /// `pendingPreferenceReload` and replayed afterwards; a failed reload is audit-logged rather
    /// than crashing the scene.
    @MainActor
    private func reloadPersistenceForPreferenceChange(_ preferences: StoragePreferences) async {
        // The sealed store is local-only and never reloads, so re-apply its backup exclusion here so a
        // runtime toggle covers it immediately instead of lagging until the next launch.
        PrivatePersistenceController.shared.applyBackupExclusion(
            excluded: preferences.localBackupExcludedFromiOSBackup
        )
        guard !PersistenceController.shared.isReloading else {
            pendingPreferenceReload = preferences
            return
        }
        do {
            try await PersistenceController.shared.reload(with: preferences)
            if let pending = pendingPreferenceReload {
                pendingPreferenceReload = nil
                await reloadPersistenceForPreferenceChange(pending)
            }
        } catch {
            FernletAuditLog.log("persistence.reload.failed", context: [
                "trigger": "appPreferencesChanged",
                "errorType": "\(type(of: error))"
            ])
        }
    }
}

#if canImport(UIKit)
private extension UIView {
    /// Every `UINavigationBar` in this view's subtree — used to push a re-scaled appearance onto
    /// bars that already exist (the appearance proxy only reaches bars created after it changes).
    func navigationBars() -> [UINavigationBar] {
        var found = subviews.compactMap { $0 as? UINavigationBar }
        for subview in subviews {
            found.append(contentsOf: subview.navigationBars())
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
                .foregroundStyle(.white)
                .padding(.horizontal, 28)
                .padding(.vertical, 14)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
        }
        .padding(28)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
