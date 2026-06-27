import LocalAuthentication
import FernletFoundation
import SwiftUI
import FernletDomainModel

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
    @State private var pendingSealedBackupEnable: SealedBackupPayloadType?

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
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            if let verificationError {
                Text(verificationError)
                    .font(.caption.weight(.medium))
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
            .font(.headline.weight(.semibold))
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
                .font(.title3.weight(.semibold))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Text("Privacy controls include iCloud deletion, Health access, and backup behavior, so Fernlet requires a lock before showing them.")
                .font(.callout.italic())
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button("Set up app lock") { showLockSetup = true }
                .buttonStyle(.plain)
                .font(.headline.weight(.semibold))
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
            healthKitCard
            localBackupCard
            lockDataCard

            if let operationError {
                Text(operationError)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.terracotta)
                    .fernletWrappingText()
                    .padding(.horizontal, 4)
            }
        }
        .accessibilityIdentifier("privacy.controls")
    }

    private var iCloudCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("iCloud")
            Toggle(isOn: iCloudBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sync to iCloud")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("Private database sync for daily logs across your Fernlet devices.")
                        .font(.caption)
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
            .font(.subheadline.weight(.semibold))
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

    private var healthKitCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("HealthKit")
            Toggle(isOn: healthKitMasterBinding) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Health integration")
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("Turns Fernlet's Health access on or off. Disabling clears locally cached Health data.")
                        .font(.caption)
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
            .font(.subheadline.weight(.semibold))
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
                        .font(.headline.weight(.semibold))
                        .foregroundStyle(Color.bark)
                    Text("When off, your local Fernlet data is excluded from iOS and iCloud device backups.")
                        .font(.caption)
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
                .font(.caption)
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            Button(role: .destructive) {
                isShowingDeleteProtectedDataAlert = true
            } label: {
                Label("Delete all protected data", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
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
                    .font(.headline.weight(.semibold))
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
                            .font(.headline.weight(.semibold))
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

                            Text("This will delete data from iCloud, which may also remove it from other Fernlet devices signed into the same Apple ID. This device keeps a local copy.")
                                .font(.callout.weight(.medium))
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
                        .font(.headline)
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
                            .font(.headline)
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
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.slate)
                }
            } else if let summary = existingDataSummary {
                Text("\(summary.mealLogCount) meal logs, \(summary.journalEntryCount) journal entries, \(summary.workoutCount) workouts")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.bark)
                    .accessibilityIdentifier("privacy.icloud.counts")
                Text("Also found \(summary.hygieneLogCount) hygiene logs, \(summary.hydrationLogCount) hydration logs, and \(summary.sleepRecordCount) sleep records.")
                    .font(.caption)
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            } else {
                Text("No Fernlet iCloud records were found.")
                    .font(.headline.weight(.semibold))
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
            applySealedBackup(payload, enabled: false)
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
        Binding(
            get: { !storagePreferencesStore.preferences.localBackupExcludedFromiOSBackup },
            set: { newValue in
                storagePreferencesStore.update { $0.localBackupExcludedFromiOSBackup = !newValue }
            }
        )
    }

    private var healthKitMasterBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.healthKitMasterEnabled },
            set: { newValue in
                Task { await setHealthKitMasterEnabled(newValue) }
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
