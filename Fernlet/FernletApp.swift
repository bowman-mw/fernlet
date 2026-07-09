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
#endif

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
        let bark = UIColor(red: 0.239, green: 0.180, blue: 0.118, alpha: 1)
        let inlineFont = UIFont(name: FernletFontName.dmSerifDisplay, size: 18)
            ?? .systemFont(ofSize: 18, weight: .semibold)
        let largeFont = UIFont(name: FernletFontName.frauncesSemiBold, size: 30)
            ?? .systemFont(ofSize: 30, weight: .bold)
        let appearance = UINavigationBarAppearance()
        appearance.configureWithTransparentBackground()
        appearance.titleTextAttributes = [.font: inlineFont, .foregroundColor: bark]
        appearance.largeTitleTextAttributes = [.font: largeFont, .foregroundColor: bark]
        UINavigationBar.appearance().standardAppearance = appearance
        UINavigationBar.appearance().scrollEdgeAppearance = appearance
        UINavigationBar.appearance().compactAppearance = appearance
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
            #endif
        }
    }

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
