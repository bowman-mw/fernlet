import SwiftUI
import CloudKitSync
import FernletFoundation
import FernletLock
import HealthKitGateway
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
        // constructed. The gateway module defaults to a no-op cleaner; the real cleaner
        // reaches CloudKitSync/LocalPersistence (which the gateway must not depend on) and
        // therefore lives app-side and is injected through this static seam.
        HealthKitService.defaultCacheClearer = CoreDataHealthKitCacheCleaner()

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
        #endif
    }

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
                    .font(.system(size: 25, weight: .bold, design: .serif))
                    .foregroundStyle(Color.bark)
                    .multilineTextAlignment(.center)
                Text(error.localizedDescription)
                    .font(.callout)
                    .foregroundStyle(Color.slate)
                    .multilineTextAlignment(.center)
                    .fernletWrappingText()
            }

            Button("Try again", action: retry)
                .buttonStyle(.plain)
                .font(.headline)
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
