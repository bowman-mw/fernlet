import LocalAuthentication
import CloudKitSync
import FernletFoundation
import FernletLock
import SwiftUI
import UIKit
import FernletDomainModel
import HealthKitGateway

@MainActor
protocol PrivacyCloudDataManaging {
    func detectExistingData() async throws -> ExistingDataSummary?
    func deleteAllCloudKitData(confirmation: DeletionConfirmation) async throws -> DeletionResult
}

extension CloudKitDataService: PrivacyCloudDataManaging {}

@MainActor
protocol PrivacyPersistenceReloading {
    func reload(with preferences: StoragePreferences) async throws
}

extension PersistenceController: PrivacyPersistenceReloading {}

@MainActor
protocol PrivacyHealthKitServicing {
    func disableIntegration() async throws
    func enableIntegration() async throws
    func openHealthPrivacySettings() async
}

extension HealthKitService: PrivacyHealthKitServicing {}

/// One sealed-backup payload whose most recent restore attempt needs the user's attention (WS-4).
private struct SealedBackupAttention: Identifiable {
    let payload: SealedBackupPayloadType
    let outcome: SealedBackupRestoreOutcome
    var id: SealedBackupPayloadType { payload }
}

struct PrivacyDataSettingsView: View {
    @Environment(FernletLockService.self) private var lockService
    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore

    @State private var hasFreshVerification = false
    @State private var isVerifying = false
    @State private var verificationError: String?
    @State private var showLockSetup = false

    @State private var existingDataSummary: ExistingDataSummary?
    @State private var deleteConfirmationText = ""
    @State private var isShowingDisableConfirmation = false
    @State private var isShowingEnableConfirmation = false
    @State private var isShowingDeleteProtectedDataAlert = false
    @State private var isUpdatingStorage = false
    @State private var isDetectingCloudData = false
    @State private var operationError: String?
    @State private var didSeedUITestPreferences = false
    @State private var showTrainerShare = false
    @State private var pendingSealedBackupEnable: SealedBackupPayloadType?
    /// Drives the shared destructive-confirmation alert. Any OFF/destructive toggle assigns to this
    /// instead of mutating directly, so the warning (and only-on-confirm mutation) is guaranteed (WS-5).
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    @State private var isResolvingEscrowConflict = false
    @State private var exportPayload: DataExportPayload?
    @State private var isBuildingExport = false

    private let cloudDataService: any PrivacyCloudDataManaging
    private let persistenceController: any PrivacyPersistenceReloading
    private let store: FernletStore?

    init(
        store: FernletStore? = nil,
        cloudDataService: (any PrivacyCloudDataManaging)? = nil,
        persistenceController: (any PrivacyPersistenceReloading)? = nil
    ) {
        self.store = store
        self.cloudDataService = cloudDataService ?? PrivacyDataServiceFactory.makeCloudDataService()
        self.persistenceController = persistenceController ?? PrivacyDataServiceFactory.makePersistenceReloader()
    }

    var body: some View {
        ZStack {
            ScrollView {
                content
                    .padding(20)
                    .padding(.bottom, 24)
            }
            .scrollContentBackground(.hidden)
            .background(Color.parchment)

            if isUpdatingStorage {
                storageSpinner
            }
        }
        .navigationTitle("Privacy & Data")
        .sheet(isPresented: $showLockSetup) {
            FernletLockSetupView()
                .environment(lockService)
        }
        .sheet(isPresented: $isShowingDisableConfirmation) {
            disableICloudConfirmationSheet
        }
        .alert("Turn on iCloud sync?", isPresented: $isShowingEnableConfirmation) {
            Button("Cancel", role: .cancel) { }
            Button("Turn on") { enableICloudSync() }
        } message: {
            Text("Your local data will upload to iCloud and sync to your other Fernlet devices.")
        }
        .alert("Turn on encrypted backup?", isPresented: Binding(
            get: { pendingSealedBackupEnable != nil },
            set: { if !$0 { pendingSealedBackupEnable = nil } }
        )) {
            Button("Cancel", role: .cancel) { pendingSealedBackupEnable = nil }
            Button("Encrypt & back up") {
                if let payload = pendingSealedBackupEnable { applySealedBackup(payload, enabled: true) }
                pendingSealedBackupEnable = nil
            }
        } message: {
            Text(sealedBackupDisclosure(for: pendingSealedBackupEnable))
        }
        .destructiveConfirmation($pendingDestructiveAction)
        .sheet(item: $exportPayload) { payload in
            ActivityShareView(items: [payload.url])
        }
        .task {
            #if DEBUG
            seedUITestPreferencesIfNeeded()
            if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_AUTH"] == "1" {
                hasFreshVerification = true
            }
            #endif
            await loadCloudCountsIfNeeded()
        }
    }

    @ViewBuilder
    private var content: some View {
        if !isLockConfigured {
            lockSetupInterstitial
        } else if hasFreshVerification {
            privacyControls
        } else {
            freshVerificationGate
        }
    }

    private var freshVerificationGate: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("Fresh verification required")
            Text("Privacy & Data requires a fresh biometric or device passcode check every time you enter.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if let verificationError {
                Text(verificationError)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
            }

            Button {
                verifyFreshAccess()
            } label: {
                Label(isVerifying ? "Verifying" : "Verify to continue", systemImage: "lock.shield.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
            .disabled(isVerifying)
            .accessibilityIdentifier("privacy.verify")
        }
        .padding(16)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("privacy.lock.gate")
    }

    private var lockSetupInterstitial: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionLabel("App lock needed")
            Text("Set up app lock to access privacy settings")
                .font(.fernlet(.headerMedium))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Text("Privacy controls include iCloud deletion, Health access, and backup behavior, so Fernlet requires a lock before showing them.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button("Set up app lock") { showLockSetup = true }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.moss, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("privacy.lock.setup")
        }
        .padding(16)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("privacy.lock.interstitial")
    }

    private var privacyControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            iCloudCard
            multiDeviceWarningBanner
            sealedBackupStatusBanner
            healthKitCard
            localBackupCard
            if store != nil { exportDataCard }
            if let store { trainerShareCard(store) }
            lockDataCard

            if let operationError {
                Text(operationError)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
                    .padding(.horizontal, 4)
            }
        }
        .accessibilityIdentifier("privacy.controls")
    }

    private var exportDataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Your data")
            Text("Export a readable copy of your own Fernlet data as a JSON file. It leaves out your "
                 + "sealed period, intimate, and sensitive-memory data, and your photos.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button {
                runExport()
            } label: {
                Label(isBuildingExport ? "Preparing…" : "Export my data",
                      systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            .disabled(isBuildingExport)
            .accessibilityIdentifier("privacy.export")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func trainerShareCard(_ store: FernletStore) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Share with a trainer")
            Text("Send a curated summary of your workouts and nutrition to a trainer or nutritionist "
                 + "you're with in person. You choose exactly what to include; your journal, period, "
                 + "intimate, photo, and friend data are never shared.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button {
                showTrainerShare = true
            } label: {
                Label("Share with a trainer…", systemImage: "figure.strengthtraining.traditional")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("privacy.trainerShare")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .sheet(isPresented: $showTrainerShare) {
            TrainerExportView(store: store)
        }
    }

    private func runExport() {
        guard let store else { return }
        isBuildingExport = true
        operationError = nil
        do {
            let url = try store.writeDataExportFile()
            exportPayload = DataExportPayload(url: url)
        } catch {
            operationError = "Couldn't prepare your export. Please try again."
        }
        isBuildingExport = false
    }

    /// Identifiable wrapper so the share sheet can present the freshly-written export file.
    fileprivate struct DataExportPayload: Identifiable {
        let id = UUID()
        let url: URL
    }

    /// Wraps the system share sheet so the export file can be saved/shared.
    private struct ActivityShareView: UIViewControllerRepresentable {
        let items: [Any]
        func makeUIViewController(context: Context) -> UIActivityViewController {
            UIActivityViewController(activityItems: items, applicationActivities: nil)
        }
        func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
    }

    private var iCloudCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("iCloud")
            Toggle(isOn: iCloudBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync to iCloud")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text("Private database sync for daily logs across your Fernlet devices.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            .accessibilityIdentifier("privacy.icloud.toggle")

            Button(role: .destructive) {
                prepareDisableICloudFlow()
            } label: {
                Label("Delete iCloud data", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("privacy.icloud.delete")

            Toggle("Sealed backup for sensitive notes", isOn: sealedSensitiveNotesBinding)
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            Toggle("Sealed backup for period data", isOn: sealedPeriodBinding)
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// True when an iCloud account is signed in on this device. A DEBUG launch override lets UI tests
    /// exercise the "another device has data" path without a real iCloud account (mirrors the
    /// `iCloudAvailabilityOverride` seam in `Persistence`).
    private var iCloudAccountPresent: Bool {
        #if DEBUG
        if let forced = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_ICLOUD_ACCOUNT"] {
            return forced == "1"
        }
        #endif
        return FileManager.default.ubiquityIdentityToken != nil
    }

    private var multiDeviceWarning: MultiDeviceSyncWarning? {
        MultiDeviceSyncWarning.classify(
            iCloudAccountPresent: iCloudAccountPresent,
            syncEnabled: storagePreferencesStore.preferences.iCloudSyncEnabled,
            otherDeviceHasData: existingDataSummary?.hasData ?? false
        )
    }

    /// Non-silent multi-device divergence warning (Phase 1): when sync is off, the user's devices can't
    /// merge. Hidden entirely while sync is on. Reuses the loaded `existingDataSummary` to name the
    /// other device's data when present.
    @ViewBuilder
    private var multiDeviceWarningBanner: some View {
        if let warning = multiDeviceWarning {
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel("Multiple devices")
                Text(warning.message)
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                if warning == .anotherDeviceHasData, let summary = existingDataSummary {
                    Text("Found \(summary.mealLogCount) meal logs, \(summary.journalEntryCount) journal entries, \(summary.workoutCount) workouts in this iCloud account.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("privacy.multiDevice.warning")
        }
    }

    /// Non-silent surface for sealed-backup restore problems (WS-4) and cross-device escrow-key
    /// conflicts (WS-3). Hidden entirely when there is nothing to report. Reads the store's observable
    /// status so a deferred/failed restore is visible and retryable instead of silently swallowed.
    @ViewBuilder
    private var sealedBackupStatusBanner: some View {
        if let store {
            let attentionItems: [SealedBackupAttention] =
                SealedBackupPayloadType.allCases.compactMap { payload in
                    guard let outcome = store.sealedBackupRestoreStatus[payload], outcome.needsAttention else { return nil }
                    return SealedBackupAttention(payload: payload, outcome: outcome)
                }
            if store.sealedBackupEscrowConflict || !attentionItems.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel("Encrypted backup status")

                    if store.sealedBackupEscrowConflict {
                        Text("We found the backup key from your other device. To keep your encrypted backups in sync across devices, this device can switch to it. Backups made only on this device may need to be re-uploaded.")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                        Button { resolveEscrowConflict() } label: {
                            Label(isResolvingEscrowConflict ? "Switching…" : "Use my other device's key",
                                  systemImage: "key.horizontal")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .font(.fernlet(.label))
                        .foregroundStyle(.white)
                        .padding(.vertical, 11)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                        .disabled(isResolvingEscrowConflict)
                        .accessibilityIdentifier("privacy.sealedBackup.resolveConflict")
                    }

                    ForEach(attentionItems) { item in
                        Text(restoreStatusMessage(item.outcome, payload: item.payload))
                            .font(.fernlet(.bodySmall))
                            .foregroundStyle(Color.slate)
                            .fernletWrappingText()
                    }

                    if attentionItems.contains(where: { $0.outcome.isRetryable }) {
                        Button { retrySealedRestore() } label: {
                            Label("Retry restore", systemImage: "arrow.clockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                        .font(.fernlet(.label))
                        .foregroundStyle(.white)
                        .padding(.vertical, 11)
                        .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("privacy.sealedBackup.retryRestore")
                    }
                }
                .padding(14)
                .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
                .accessibilityIdentifier("privacy.sealedBackup.statusBanner")
            }
        }
    }

    private func restoreStatusMessage(_ outcome: SealedBackupRestoreOutcome, payload: SealedBackupPayloadType) -> String {
        let noun = payload == .periodData ? "period" : "private notes"
        switch outcome {
        case .deferredKeyNotSynced:
            return "Couldn't restore your \(noun) backup on this device yet — iCloud Keychain may still be syncing. We'll keep trying, or tap Retry."
        case .deferredLocked:
            return "Your \(noun) backup is ready to restore, but Fernlet is locked. Unlock, then tap Retry."
        case .deferredTransient:
            return "Couldn't reach your \(noun) backup just now. We'll keep trying, or tap Retry."
        case .notRecognized:
            return "A \(noun) backup was found in iCloud, but it isn't encrypted with this account's key, so it can't be restored on this device."
        case .restored, .nothingToRestore, .skippedStoreNotEmpty:
            return ""
        }
    }

    private func retrySealedRestore() {
        guard let store else { return }
        FernletAuditLog.log("privacy.sealedBackup.retryRestore")
        Task { await store.restoreSealedBackupsIfNeeded() }
    }

    private func resolveEscrowConflict() {
        guard let store else { return }
        FernletAuditLog.log("privacy.sealedBackup.resolveEscrowConflict")
        isResolvingEscrowConflict = true
        Task {
            _ = await store.resolveSealedBackupEscrowConflict()
            await MainActor.run { isResolvingEscrowConflict = false }
        }
    }

    private var healthKitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("HealthKit")
            Toggle(isOn: healthKitMasterBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Health integration")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text("Turns Fernlet's Health access on or off. Disabling clears locally cached Health data.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            .accessibilityIdentifier("privacy.health.master")

            VStack(spacing: 8) {
                ForEach(HealthCapability.allCases) { capability in
                    Toggle(capability.title, isOn: capabilityBinding(capability))
                        .toggleStyle(SwitchToggleStyle(tint: Color.moss))
                        .disabled(!storagePreferencesStore.preferences.healthKitMasterEnabled)
                        .accessibilityIdentifier("privacy.health.capability.\(capability.rawValue)")
                }
            }

            Button {
                Task { await makeHealthKitService().openHealthPrivacySettings() }
            } label: {
                Label("Open Health Privacy Settings", systemImage: "arrow.up.forward.app")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Color.moss, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("privacy.health.openSettings")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var localBackupCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Local backup")
            Toggle(isOn: localBackupIncludedBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Include local data in iOS backup")
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.bark)
                    Text("When off, your local Fernlet data is excluded from iOS and iCloud device backups.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            .accessibilityIdentifier("privacy.localBackup.toggle")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private var lockDataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("App lock data")
            Text("Fernlet protects your data with its own passcode, separate from your device passcode. Removing your device passcode will not affect your Fernlet app lock or erase your protected data.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button(role: .destructive) {
                isShowingDeleteProtectedDataAlert = true
            } label: {
                Label("Delete all protected data", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(.white)
            .padding(.vertical, 11)
            .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("privacy.lock.deleteProtectedData")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .alert("Delete all protected data?", isPresented: $isShowingDeleteProtectedDataAlert) {
            Button("Cancel", role: .cancel) { }
            Button("Delete", role: .destructive) {
                try? lockService.reset()
            }
        } message: {
            Text("This permanently deletes your app lock, sealed journal entries, and all other protected Fernlet data. This cannot be undone.")
        }
    }

    private var storageSpinner: some View {
        ZStack {
            Color.black.opacity(0.20).ignoresSafeArea()
            VStack(spacing: 12) {
                ProgressView()
                    .tint(Color.moss)
                Text("Updating storage settings…")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
            }
            .padding(20)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("privacy.storage.spinner")
        }
    }

    private var disableICloudConfirmationSheet: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if isUpdatingStorage {
                    VStack(spacing: 12) {
                        Spacer()
                        ProgressView()
                            .tint(Color.moss)
                        Text("Updating storage settings…")
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("privacy.storage.spinner")
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            ScreenHeader(
                                title: "Turn off iCloud sync?",
                                subtitle: "Stop syncing now, or also delete iCloud data."
                            )

                            cloudCountsCard

                            Text("Stopping sync keeps your data on this device but disconnects it from iCloud: changes you make here will no longer reach your other Fernlet devices, and theirs won't reach you. The two will drift apart until you turn sync back on.")
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                                .padding(14)
                                .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                                .accessibilityIdentifier("privacy.icloud.divergenceWarning")

                            Text("This will delete data from iCloud, which may also remove it from other Fernlet devices signed into the same Apple ID. Your encrypted (sealed) backups in iCloud are deleted too — if you lose this device, that data can't be recovered. This device keeps a local copy of everything else.")
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()
                                .padding(14)
                                .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))

                            SheetField("Type DELETE to confirm") {
                                TextField("DELETE", text: $deleteConfirmationText)
                                    .autocorrectionDisabled()
                                    .textInputAutocapitalization(.characters)
                                    .sheetTextInput()
                                    .accessibilityIdentifier("privacy.icloud.confirmText")
                            }
                        }
                        .padding(20)
                    }

                    VStack(spacing: 12) {
                        Button("Stop syncing, keep iCloud data") {
                            stopSyncingKeepCloudData()
                        }
                        .buttonStyle(.plain)
                        .font(.fernlet(.label))
                        .foregroundStyle(Color.moss)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(Color.moss.opacity(0.1), in: RoundedRectangle(cornerRadius: 16))
                        .accessibilityIdentifier("privacy.icloud.stopSync")

                        HStack {
                            Spacer()
                            Button("Delete iCloud data") {
                                disableICloudSyncAndDeleteCloudData()
                            }
                            .buttonStyle(.plain)
                            .font(.fernlet(.label))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 28)
                            .padding(.vertical, 16)
                            .background(
                                deleteConfirmationText.uppercased() == "DELETE" ? Color.moss : Color.moss.opacity(0.4),
                                in: RoundedRectangle(cornerRadius: 16)
                            )
                            .disabled(deleteConfirmationText.uppercased() != "DELETE")
                            .accessibilityIdentifier("privacy.icloud.confirmDelete")
                        }
                    }
                    .padding(20)
                    .background(Color.parchment)
                }
            }
            .background(Color.parchment)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { isShowingDisableConfirmation = false }
                        .foregroundStyle(Color.slate)
                }
            }
        }
    }

    private var cloudCountsCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel("Cloud records")
            if isDetectingCloudData {
                HStack(spacing: 8) {
                    ProgressView()
                    Text("Checking iCloud")
                        .font(.fernlet(.labelSmall))
                        .foregroundStyle(Color.slate)
                }
            } else if let summary = existingDataSummary {
                Text("\(summary.mealLogCount) meal logs, \(summary.journalEntryCount) journal entries, \(summary.workoutCount) workouts")
                    .font(.fernlet(.stat))
                    .foregroundStyle(Color.bark)
                    .accessibilityIdentifier("privacy.icloud.counts")
                Text("Also found \(summary.hygieneLogCount) hygiene logs, \(summary.hydrationLogCount) hydration logs, and \(summary.sleepRecordCount) sleep records.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            } else {
                Text("No Fernlet iCloud records were found.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
            }
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
    }

    private var isLockConfigured: Bool {
        if let uiTestOverride = uiTestLockConfiguredOverride {
            return uiTestOverride
        }
        return lockService.state != .notConfigured
    }

    private var uiTestLockConfiguredOverride: Bool? {
        guard ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1",
              let value = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_LOCK_CONFIGURED"] else {
            return nil
        }
        return value == "1"
    }

    private var iCloudBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.iCloudSyncEnabled },
            set: { newValue in
                guard newValue != storagePreferencesStore.preferences.iCloudSyncEnabled else { return }
                if newValue {
                    isShowingEnableConfirmation = true
                } else {
                    prepareDisableICloudFlow()
                }
            }
        )
    }

    private var sealedSensitiveNotesBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.sealedBackupSensitiveNotesEnabled },
            set: { newValue in handleSealedBackupToggle(.sensitiveNotes, enabled: newValue) }
        )
    }

    private var sealedPeriodBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.sealedBackupPeriodEnabled },
            set: { newValue in handleSealedBackupToggle(.periodData, enabled: newValue) }
        )
    }

    private func handleSealedBackupToggle(_ payload: SealedBackupPayloadType, enabled: Bool) {
        FernletAuditLog.log(
            payload == .periodData ? "privacy.sealedBackup.periodChanged" : "privacy.sealedBackup.sensitiveNotesChanged",
            context: ["enabled": enabled ? "true" : "false"]
        )
        if enabled {
            // Require explicit, informed confirmation before any data leaves the device.
            pendingSealedBackupEnable = payload
        } else {
            // Turning a sealed backup OFF permanently deletes that encrypted backup from iCloud — a
            // destructive, irreversible action that must be confirmed first (WS-5).
            let noun = payload == .periodData ? "period" : "sensitive-notes"
            pendingDestructiveAction = DestructiveConfirmation(
                title: "Turn off encrypted \(noun) backup?",
                message: "This permanently deletes your encrypted \(noun) backup from iCloud. "
                    + "If you lose or replace this device, that data can't be recovered. Turn off anyway?",
                confirmLabel: "Turn off",
                auditEvent: payload == .periodData
                    ? "privacy.sealedBackup.periodDisableConfirmed"
                    : "privacy.sealedBackup.sensitiveNotesDisableConfirmed"
            ) {
                applySealedBackup(payload, enabled: false)
            }
        }
    }

    private func applySealedBackup(_ payload: SealedBackupPayloadType, enabled: Bool) {
        guard let store else {
            // No store (UI-test harness): just reflect the preference.
            setSealedBackupPreference(payload, enabled)
            return
        }
        Task {
            let ok = await store.setSealedBackupEnabled(enabled, payloadType: payload)
            await MainActor.run {
                if enabled {
                    if ok { setSealedBackupPreference(payload, true) }
                } else {
                    // Honor the user's "off" intent regardless of the delete outcome.
                    setSealedBackupPreference(payload, false)
                }
            }
        }
    }

    private func setSealedBackupPreference(_ payload: SealedBackupPayloadType, _ value: Bool) {
        storagePreferencesStore.update {
            switch payload {
            case .periodData: $0.sealedBackupPeriodEnabled = value
            case .sensitiveNotes: $0.sealedBackupSensitiveNotesEnabled = value
            }
        }
    }

    private func sealedBackupDisclosure(for payload: SealedBackupPayloadType?) -> String {
        var lines = [
            "Your data leaves this device only in encrypted form.",
            "Apple can't read it.",
            "If iCloud Keychain is ever permanently lost, this backup can't be recovered on a new device."
        ]
        if payload == .periodData {
            lines.append("Period data is sensitive; it is uploaded only in this encrypted form.")
        }
        return lines.joined(separator: "\n\n")
    }

    private var localBackupIncludedBinding: Binding<Bool> {
        // "Include local data in iOS backup". With the default `localBackupExcludedFromiOSBackup = false`,
        // this derives to true → the toggle defaults ON (data included/recoverable), and the user must
        // opt OUT to exclude. The label stays accurate; only the default position flipped.
        Binding(
            get: { !storagePreferencesStore.preferences.localBackupExcludedFromiOSBackup },
            set: { newValue in
                if newValue {
                    // Re-including local data in device backups is non-destructive (it restores a
                    // recovery path) — commit directly.
                    FernletAuditLog.log("privacy.localBackup.included")
                    storagePreferencesStore.update { $0.localBackupExcludedFromiOSBackup = false }
                } else {
                    // EXCLUDING drops the sealed store (journals, intimate logs, cycle notes — encrypted
                    // with a ThisDeviceOnly key, so NO cloud recovery) from every device backup. Warn
                    // before committing (WS-5).
                    pendingDestructiveAction = DestructiveConfirmation(
                        title: "Exclude Fernlet data from device backups?",
                        message: "Excluding from device backup means your journals, intimate logs, and "
                            + "cycle notes won't be in any iPhone backup. Because they're encrypted with a "
                            + "key that never leaves this device, erasing or losing this device would lose "
                            + "them permanently. Exclude anyway?",
                        confirmLabel: "Exclude",
                        auditEvent: "privacy.localBackup.excludeConfirmed"
                    ) {
                        storagePreferencesStore.update { $0.localBackupExcludedFromiOSBackup = true }
                    }
                }
            }
        )
    }

    private var healthKitMasterBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.healthKitMasterEnabled },
            set: { newValue in
                if newValue {
                    // Enabling is constructive — proceed directly.
                    Task { await setHealthKitMasterEnabled(true) }
                } else {
                    // Disabling fail-closed PURGES the cached HealthKit-derived clinical values from this
                    // device (the data itself stays in Apple Health). Warn before committing (WS-5).
                    pendingDestructiveAction = DestructiveConfirmation(
                        title: "Turn off Health integration?",
                        message: "Turning this off removes the activity, cycle, and other Health data "
                            + "Fernlet has cached on this device. Your data stays in Apple Health. Turn off?",
                        confirmLabel: "Turn off",
                        auditEvent: "privacy.healthKit.masterDisableConfirmed"
                    ) {
                        Task { await setHealthKitMasterEnabled(false) }
                    }
                }
            }
        )
    }

    private func capabilityBinding(_ capability: HealthCapability) -> Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.healthKitCapabilityEnabled[capability.rawValue] ?? false },
            set: { newValue in
                FernletAuditLog.log(
                    newValue ? "privacy.healthKit.capabilityEnabled" : "privacy.healthKit.capabilityDisabled",
                    context: ["capability": capability.rawValue]
                )
                storagePreferencesStore.update { preferences in
                    preferences.healthKitCapabilityEnabled[capability.rawValue] = newValue
                }
            }
        )
    }

    private func seedUITestPreferencesIfNeeded() {
        #if DEBUG
        guard !didSeedUITestPreferences,
              ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" else { return }
        didSeedUITestPreferences = true
        storagePreferencesStore.update { preferences in
            preferences.iCloudSyncEnabled = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_ICLOUD_ENABLED"] == "1"
            preferences.healthKitMasterEnabled = ProcessInfo.processInfo.environment["FERNLET_UI_TEST_HEALTH_ENABLED"] == "1"
            if preferences.healthKitMasterEnabled {
                preferences.healthKitCapabilityEnabled = Dictionary(
                    uniqueKeysWithValues: HealthCapability.allCases.map { ($0.rawValue, true) }
                )
            }
        }
        #endif
    }

    private func verifyFreshAccess() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_AUTH"] == "1" {
            hasFreshVerification = true
            return
        }
        #endif

        isVerifying = true
        verificationError = nil
        Task { @MainActor in
            let context = LAContext()
            context.localizedReason = "Verify to access Privacy & Data settings."
            do {
                let success = try await context.evaluatePolicy(
                    .deviceOwnerAuthentication,
                    localizedReason: "Verify to access Privacy & Data settings."
                )
                hasFreshVerification = success
            } catch {
                verificationError = error.localizedDescription
            }
            isVerifying = false
        }
    }

    private func prepareDisableICloudFlow() {
        deleteConfirmationText = ""
        isShowingDisableConfirmation = true
        Task { await loadCloudCountsIfNeeded(force: true) }
    }

    private func enableICloudSync() {
        FernletAuditLog.log("privacy.icloud.syncEnabled")
        var updated = storagePreferencesStore.preferences
        updated.iCloudSyncEnabled = true
        applyStoragePreferences(updated)
    }

    private func stopSyncingKeepCloudData() {
        FernletAuditLog.log("privacy.icloud.syncDisabled.keepData")
        var updated = storagePreferencesStore.preferences
        updated.iCloudSyncEnabled = false
        applyStoragePreferences(updated)
        isShowingDisableConfirmation = false
    }

    private func disableICloudSyncAndDeleteCloudData() {
        guard deleteConfirmationText.uppercased() == "DELETE" else { return }
        FernletAuditLog.log("privacy.icloud.deletionInitiated")
        isUpdatingStorage = true
        operationError = nil
        Task { @MainActor in
            do {
                var updated = storagePreferencesStore.preferences
                updated.iCloudSyncEnabled = false
                try await reloadPersistence(with: updated)
                storagePreferencesStore.update { $0 = updated }
                FernletAuditLog.log("privacy.icloud.syncDisabled")

                _ = try await cloudDataService.deleteAllCloudKitData(
                    confirmation: DeletionConfirmation(userTypedConfirmation: deleteConfirmationText.uppercased())
                )
                // The cloud records were just deleted, so the previously-detected summary is stale. Clear it
                // so the "Cloud records" card and the always-on multi-device warning banner immediately
                // reflect the now-empty cloud instead of continuing to report data that no longer exists.
                existingDataSummary = nil
                isShowingDisableConfirmation = false
            } catch {
                operationError = error.localizedDescription
                isShowingDisableConfirmation = false
            }
            isUpdatingStorage = false
        }
    }

    private func applyStoragePreferences(_ preferences: StoragePreferences) {
        isUpdatingStorage = true
        operationError = nil
        Task { @MainActor in
            do {
                try await reloadPersistence(with: preferences)
                storagePreferencesStore.update { $0 = preferences }
            } catch {
                operationError = error.localizedDescription
            }
            isUpdatingStorage = false
        }
    }

    private func reloadPersistence(with preferences: StoragePreferences) async throws {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_SLOW_RELOAD"] == "1" {
            try? await Task.sleep(for: .milliseconds(1500))
        }
        do {
            try await persistenceController.reload(with: preferences)
        } catch {
            FernletAuditLog.log("persistence.reload.failed", context: [
                "trigger": "privacySettings",
                "errorType": "\(type(of: error))"
            ])
            throw error
        }
    }

    private func loadCloudCountsIfNeeded(force: Bool = false) async {
        guard force || existingDataSummary == nil else { return }
        isDetectingCloudData = true
        defer { isDetectingCloudData = false }
        do {
            existingDataSummary = try await cloudDataService.detectExistingData()
        } catch {
            existingDataSummary = nil
        }
    }

    private func setHealthKitMasterEnabled(_ enabled: Bool) async {
        operationError = nil
        FernletAuditLog.log(enabled ? "privacy.healthKit.masterEnabled" : "privacy.healthKit.masterDisabled")
        do {
            let service = makeHealthKitService()
            if enabled {
                try await service.enableIntegration()
                storagePreferencesStore.update { $0.healthKitMasterEnabled = true }
            } else {
                try await service.disableIntegration()
                storagePreferencesStore.update { preferences in
                    preferences.healthKitMasterEnabled = false
                    preferences.healthKitCapabilityEnabled = StoragePreferences.defaultHealthKitCapabilityEnabled
                }
            }
        } catch {
            operationError = error.localizedDescription
        }
    }

    private func makeHealthKitService() -> any PrivacyHealthKitServicing {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" {
            return MockPrivacyHealthKitService(preferencesStore: storagePreferencesStore)
        }
        return HealthKitService(preferencesStore: storagePreferencesStore)
    }
}

@MainActor
private enum PrivacyDataServiceFactory {
    static func makeCloudDataService() -> any PrivacyCloudDataManaging {
        let environment = ProcessInfo.processInfo.environment
        if environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" {
            return MockPrivacyCloudDataService(summary: ExistingDataSummary(
                mealLogCount: Int(environment["FERNLET_UI_TEST_MEAL_LOGS"] ?? "7") ?? 7,
                journalEntryCount: Int(environment["FERNLET_UI_TEST_JOURNAL_ENTRIES"] ?? "3") ?? 3,
                workoutCount: Int(environment["FERNLET_UI_TEST_WORKOUTS"] ?? "2") ?? 2,
                hygieneLogCount: 1,
                hydrationLogCount: 1,
                sleepRecordCount: 1
            ))
        }
        return CloudKitDataService()
    }

    static func makePersistenceReloader() -> any PrivacyPersistenceReloading {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" {
            return MockPrivacyPersistenceReloader()
        }
        return PersistenceController.shared
    }
}

@MainActor
private struct MockPrivacyCloudDataService: PrivacyCloudDataManaging {
    var summary: ExistingDataSummary

    func detectExistingData() async throws -> ExistingDataSummary? {
        summary
    }

    func deleteAllCloudKitData(confirmation: DeletionConfirmation) async throws -> DeletionResult {
        guard confirmation.userTypedConfirmation == "DELETE" else {
            throw CloudKitDataServiceError.confirmationRequired
        }
        return DeletionResult(deletedRecordCount: 12, mayAffectOtherDevices: true)
    }
}

@MainActor
private struct MockPrivacyPersistenceReloader: PrivacyPersistenceReloading {
    func reload(with preferences: StoragePreferences) async throws {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_SLOW_RELOAD"] == "1" {
            try await Task.sleep(for: .milliseconds(1500))
        }
    }
}

@MainActor
private struct MockPrivacyHealthKitService: PrivacyHealthKitServicing {
    let preferencesStore: StoragePreferencesStore

    func disableIntegration() async throws {
        preferencesStore.update { preferences in
            preferences.healthKitMasterEnabled = false
            preferences.healthKitCapabilityEnabled = StoragePreferences.defaultHealthKitCapabilityEnabled
        }
    }

    func enableIntegration() async throws {
        preferencesStore.update { $0.healthKitMasterEnabled = true }
    }

    func openHealthPrivacySettings() async { }
}
