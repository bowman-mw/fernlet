import LocalAuthentication
import CloudKitSync
import FernletFoundation
import FernletLock
import SwiftUI
import UIKit
import FernletDomainModel
import HealthKitGateway
import FernletUI
import FernletLockUI
// Step 5c's own-photo device-binding consent surface reads `OwnPhotoKeyBindingOutcome`.
import PrivateMediaStore

/// The slice of CloudKit the Privacy & Data screen needs: count what's in the account, and delete it.
///
/// Conformers: `CloudKitDataService` (the real queries, via the retroactive conformance below) and
/// `MockPrivacyCloudDataService` (canned answers for UI tests). ``PrivacyDataSettingsView`` uses
/// detection to populate the "Cloud records" card and the multi-device warning, and the delete for
/// the type-DELETE-to-confirm iCloud wipe. Main-actor-bound like the view that owns it.
@MainActor
protocol PrivacyCloudDataManaging {
    /// - Returns: Counts of the account's existing Fernlet records, or nil when none were found.
    func detectExistingData() async throws -> ExistingDataSummary?
    /// Deletes every Fernlet record from the account's private database.
    /// - Parameter confirmation: Carries the user's typed "DELETE"; the service refuses without it.
    func deleteAllCloudKitData(confirmation: DeletionConfirmation) async throws -> DeletionResult
}

extension CloudKitDataService: PrivacyCloudDataManaging {}

/// Abstraction over swapping the persistence stack when storage preferences change.
///
/// Conformers: `PersistenceController` (the real Core Data reload) and
/// `MockPrivacyPersistenceReloader` (a no-op with an optional UI-test delay).
/// ``PrivacyDataSettingsView`` calls it whenever the iCloud sync toggle flips so the store starts
/// reading/writing the newly-selected home before the preference is persisted.
@MainActor
protocol PrivacyPersistenceReloading {
    func reload(with preferences: StoragePreferences) async throws
}

extension PersistenceController: PrivacyPersistenceReloading {}

/// The Health-integration switches the Privacy & Data screen drives: master enable/disable and a
/// jump to the system Health privacy settings.
///
/// Conformers: `HealthKitService` (the real integration — disabling purges the locally cached
/// HealthKit-derived values, fail-closed) and `MockPrivacyHealthKitService` (flips the preference
/// only, for UI tests). Selected per call by `makeHealthKitService()` based on the UI-test
/// environment.
@MainActor
protocol PrivacyHealthKitServicing {
    func disableIntegration() async throws
    func enableIntegration() async throws
    func openHealthPrivacySettings() async
}

extension HealthKitService: PrivacyHealthKitServicing {}

/// One sealed-backup payload whose most recent restore attempt needs the user's attention (WS-4).
///
/// Built on the fly by ``PrivacyDataSettingsView``'s encrypted-backup status banner from
/// `FernletStore.sealedBackupRestoreStatus`; identified by payload type so `ForEach` renders one
/// line per payload.
private struct SealedBackupAttention: Identifiable {
    let payload: SealedBackupPayloadType
    let outcome: SealedBackupRestoreOutcome
    var id: SealedBackupPayloadType { payload }
}

/// The Privacy & Data screen: iCloud sync and deletion, sealed encrypted backups, Health
/// integration, iOS-backup inclusion, data export, trainer sharing, and the "delete everything"
/// funnel.
///
/// Pushed from ``SettingsSheet`` via `SettingsRoute.privacyData`. Access is layered: with no app
/// lock configured the screen shows a setup interstitial (plus — deliberately — the delete card,
/// since erasing your own data must not require first handing Fernlet a passcode); with a lock, a
/// fresh `LocalAuthentication` device-owner check is required on every entry before the controls
/// appear. The lock gate protects *browsing* the privacy posture; the confirm dialogs protect the
/// destructive actions themselves.
///
/// Key collaborators: ``PrivacyCloudDataManaging`` and ``PrivacyPersistenceReloading`` (injected, or
/// chosen by `PrivacyDataServiceFactory`), ``PrivacyHealthKitServicing`` (chosen per call),
/// `StoragePreferencesStore` and `FernletLockService` from the environment, and an optional
/// ``FernletStore`` — export, trainer share, sealed-backup status, and the delete-everything button
/// render only when a store is present (the injected-nil case is previews and unit tests).
///
/// Invariants (WS-3/4/5 and the nothing-silent rule):
/// - Every destructive or recovery-path-removing toggle routes through ``DestructiveConfirmation``;
///   enabling a sealed backup shows an informed-consent disclosure before any upload.
/// - Turning sync off records `cloudCopyKept` *before* the cloud delete can throw, so a stranded
///   iCloud copy stays reachable by the delete-everything funnel.
/// - Restore problems and escrow-key conflicts surface in a visible banner with a retry, never a
///   silent swallow; an incomplete wipe raises a failure alert naming the surviving store.
/// - The plaintext JSON export is purged once the share sheet finishes, and a wipe also drops the
///   view's reference to the exported URL.
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
    /// True when the disable/delete sheet was opened by the "Delete iCloud data" button (sync
    /// already off) rather than by the sync switch — it changes the sheet's question.
    @State private var isCloudDeleteOnlyEntry = false
    @State private var isShowingEnableConfirmation = false
    /// This screen's own "delete everything" wipe state (busy / success / failure) plus the shared
    /// confirmation glue — deliberately per-screen, never shared with ``SettingsSheet``'s (the
    /// enclosing sheet's dismiss guard keys off ITS flag; see the mid-wipe comment on `body`).
    @State private var deleteFlow = DeleteEverythingFlow()
    @State private var isUpdatingStorage = false
    @State private var isDetectingCloudData = false
    @State private var operationError: String?
    /// Which card `operationError` belongs to. A single terracotta line at the very bottom of a long
    /// page — under "Delete everything" — is not feedback for a switch that snapped back near the
    /// top, so every failure now renders beneath the control that produced it.
    @State private var operationErrorScope: PrivacyErrorScope = .general
    @State private var didSeedUITestPreferences = false
    @State private var pendingSealedBackupEnable: SealedBackupPayloadType?
    /// The own-photo escrow backup's enable confirmation. Its own flag rather than a case on
    /// `pendingSealedBackupEnable`, because the photo route is deliberately NOT a
    /// `SealedBackupPayloadType` (see `SealedPhotoCorpus`).
    @State private var pendingOwnPhotoBackupEnable = false
    /// Set when turning the photo backup OFF failed to delete its iCloud records. The preference is
    /// left ON (so the records stay targetable) and the status banner explains why.
    @State private var ownPhotoBackupDisableFailed = false
    /// Set when the user confirmed "lock photos to this device" but the keychain could not complete
    /// the binding right then. Their consent IS recorded (it is a durable decision), so the copy
    /// says the choice is saved and will finish — never a silent no-op button.
    @State private var ownPhotoBindingDeferred = false
    /// Payloads whose "turn the backup off" CloudKit delete FAILED. Their preference is deliberately
    /// left ON (so the orphaned CKRecords stay targetable by a retry or by delete-all) and the status
    /// banner says so, instead of the failure being swallowed by an off-looking toggle.
    @State private var sealedBackupDisableFailures: Set<SealedBackupPayloadType> = []
    /// Drives the shared destructive-confirmation alert. Any OFF/destructive toggle assigns to this
    /// instead of mutating directly, so the warning (and only-on-confirm mutation) is guaranteed (WS-5).
    @State private var pendingDestructiveAction: DestructiveConfirmation?
    @State private var isResolvingEscrowConflict = false
    /// One "Retry restore" pass in flight at a time (R3): the coordinator it calls has no in-flight
    /// guard of its own, so repeated taps would overlap whole restore passes.
    @State private var isRetryingRestore = false
    /// Set when the iCloud record probe THREW. Without it a failed query is indistinguishable from
    /// "this account is empty", which suppresses the multi-device warning on a false premise.
    @State private var cloudCountsUnavailable = false
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
        consentAlerts(screenContent)
            .destructiveConfirmation($pendingDestructiveAction)
            // Success ("OK") just clears the flag — this is a pushed screen, so it stays put either way.
            .deleteEverythingAlerts(deleteFlow, successButtonTitle: "OK", successButtonRole: .cancel) {
                deleteFlow.showSuccess = false
            }
            .sheet(item: $exportPayload) { payload in
                ActivityShareView(items: [payload.url]) { purgeExportsAfterShare() }
            }
            .task { await onFirstAppear() }
    }

    /// The screen itself: the scrolling controls plus the two busy overlays, the navigation chrome,
    /// and the two sheets it presents. The consent alerts and the destructive/delete presentations
    /// are layered on by `body`.
    private var screenContent: some View {
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
            } else if deleteFlow.isDeleting {
                DeletingEverythingOverlay()
            }
        }
        .navigationTitle("Privacy & Data")
        // Mid-wipe escape hatches, mirroring the SettingsSheet entry point's guard set. The busy
        // overlay lives INSIDE this pushed view, so the nav bar's Back chevron stays tappable above
        // it — and the enclosing Settings sheet's own `interactiveDismissDisabled` keys off ITS
        // per-screen `DeleteEverythingFlow`, which is idle for a wipe started here. Either escape
        // tears down the @State-owned flow that presents the success/FAILURE alert (a silently
        // failed wipe) and re-enables the delete button mid-wipe. `interactiveDismissDisabled`
        // applies from a pushed child of the sheet.
        .navigationBarBackButtonHidden(deleteFlow.isDeleting)
        .interactiveDismissDisabled(deleteFlow.isDeleting)
        .sheet(isPresented: $showLockSetup) {
            // Set up from inside Settings → grants the settings scope only; the Private Hub still
            // asks for the passcode the first time it's opened.
            FernletLockSetupView(grantingScope: .appLockSettings)
                .environment(lockService)
        }
        .sheet(isPresented: $isShowingDisableConfirmation) {
            disableICloudConfirmationSheet
        }
    }

    /// The three informed-consent alerts that gate anything leaving the device: turning iCloud sync
    /// on, and turning on either kind of encrypted backup. Grouped here so `body` stays readable;
    /// they stay in the same order and position in the modifier chain as before.
    private func consentAlerts(_ content: some View) -> some View {
        content
            .alert("Turn on iCloud sync?", isPresented: $isShowingEnableConfirmation) {
                Button("Cancel", role: .cancel) { }
                Button("Turn on") { enableICloudSync() }
            } message: {
                Text("Your local data will upload to iCloud and sync to your other Fernlet devices.")
            }
            .alert("Turn on encrypted backup?", isPresented: $pendingSealedBackupEnable.isPresent()) {
                Button("Cancel", role: .cancel) { pendingSealedBackupEnable = nil }
                Button("Encrypt & back up") {
                    if let payload = pendingSealedBackupEnable { applySealedBackup(payload, enabled: true) }
                    pendingSealedBackupEnable = nil
                }
            } message: {
                Text(sealedBackupDisclosure(for: pendingSealedBackupEnable))
            }
            .alert("Back up your photos?", isPresented: $pendingOwnPhotoBackupEnable) {
                Button("Cancel", role: .cancel) { pendingOwnPhotoBackupEnable = false }
                Button("Encrypt & back up") { applyOwnPhotoBackup(enabled: true) }
            } message: {
                Text(Self.ownPhotoBackupSizeDisclosure + "\n\n" + sealedBackupDisclosure(for: nil)
                     + "\n\n" + Self.ownPhotoBackupBindingDisclosure)
            }
    }

    /// Share-sheet completion sweep. The export is a full, UNENCRYPTED JSON dump of the user's
    /// decrypted data. Once the share sheet is done reading it — whether the user shared it or
    /// cancelled — remove it rather than letting it linger in tmp/ until the next "delete
    /// everything". Sweeping the whole exports directory also clears any older exports from previous
    /// days at the same seam. Runs on completion (after `UIActivityViewController` has finished
    /// copying the file into whatever activity read it), not on dismissal, so the share can't race
    /// the delete. A failed sweep means that plaintext dump is STILL in tmp/, so it is recorded
    /// rather than dropped; "Delete everything" and the launch sweep remain the backstop.
    private func purgeExportsAfterShare() {
        guard let store else { return }
        guard store.purgeDataExports() else {
            FernletAuditLog.log("privacy.export.purgeFailed", context: ["trigger": "shareCompleted"])
            return
        }
    }

    /// First-appearance work: the DEBUG UI-test seeding, the entry verification, and the iCloud
    /// record count.
    private func onFirstAppear() async {
        #if DEBUG
        seedUITestPreferencesIfNeeded()
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_AUTH"] == "1" {
            hasFreshVerification = true
        }
        #endif
        // Ask for the check straight away rather than making every visit tap a button first: the
        // card stays as the RETRY state after a cancel or failure, which is when it has something
        // to say. Arriving here from a search result used to cost hub → result → Verify → Face ID.
        if shouldVerifyOnAppear { verifyFreshAccess() }
        await loadCloudCountsIfNeeded()
    }

    /// Whether the entry check should fire by itself: only with a lock configured, nothing verified
    /// yet, and no attempt already made. UI tests that assert the gate card drive the button
    /// themselves, so the automatic pass stands down under the mock-services environment.
    private var shouldVerifyOnAppear: Bool {
        guard isLockConfigured, !hasFreshVerification, !isVerifying, verificationError == nil else { return false }
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" { return false }
        return true
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
            Text(verificationError == nil
                 ? "Privacy & Data asks for a fresh Face ID or device passcode check every time you enter."
                 : "Privacy & Data needs a fresh Face ID or device passcode check before it can show you anything.")
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
                Label(verifyButtonTitle, systemImage: "lock.shield.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.onMoss)
            .padding(.vertical, 14)
            .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
            .disabled(isVerifying)
            .accessibilityIdentifier("privacy.verify")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("privacy.lock.gate")
    }

    /// "Try again" once an attempt has been made — the card is the retry state after the automatic
    /// check on entry was cancelled or failed.
    private var verifyButtonTitle: String {
        if isVerifying { return "Verifying" }
        return verificationError == nil ? "Verify to continue" : "Try again"
    }

    private var lockSetupInterstitial: some View {
        VStack(alignment: .leading, spacing: 16) {
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
                    .foregroundStyle(Color.onMoss)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 14))
                    .accessibilityIdentifier("privacy.lock.setup")
            }
            .padding(16)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("privacy.lock.interstitial")

            // Deletion is offered even with no lock configured. The lock gate exists so someone holding
            // an unlocked phone can't BROWSE the user's privacy posture — it reveals nothing to erase
            // your own data, and gating deletion behind lock setup produced the perverse result that the
            // only way to delete your cycle, intimate and journal notes was to first hand Fernlet a new
            // passcode. The confirm dialog, not the lock, is what stands between a tap and a wipe.
            noLockDeleteCard
        }
    }

    /// The delete affordance shown to a user with no app lock. Same funnel and same dialog as the card
    /// inside `privacyControls`; only the framing differs, because here it sits on a screen the user is
    /// otherwise being told they can't see.
    private var noLockDeleteCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Delete your data")
            Text("You don't need an app lock to delete what Fernlet has stored. This works for the entries Fernlet keeps encrypted too.")
                .font(.fernlet(.bubble))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            deleteEverythingButton
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("privacy.lock.noLockDeleteCard")
    }

    private var privacyControls: some View {
        VStack(alignment: .leading, spacing: 16) {
            iCloudCard
            multiDeviceWarningBanner
            sealedBackupStatusBanner
            healthKitCard
            localBackupCard
            if store != nil { exportDataCard }
            lockDataCard

            // Anything not claimed by a card still gets said.
            operationErrorLine(.general)
        }
        .accessibilityIdentifier("privacy.controls")
    }

    /// Which control an ``operationError`` came from, so it renders next to that control.
    private enum PrivacyErrorScope { case iCloud, backupStatus, health, export, general }

    /// The failure line for one card, or nothing when the current error belongs elsewhere.
    @ViewBuilder
    private func operationErrorLine(_ scope: PrivacyErrorScope) -> some View {
        if let operationError, operationErrorScope == scope {
            Text(operationError)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.terracotta)
                .fernletWrappingText()
                .accessibilityIdentifier("privacy.operationError")
        }
    }

    /// Records a failure against the card that raised it. One seam so a new failure path cannot
    /// ship without saying where it belongs.
    private func setOperationError(_ message: String?, scope: PrivacyErrorScope = .general) {
        operationError = message
        operationErrorScope = scope
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
            .foregroundStyle(isBuildingExport ? Color.bark : Color.onMoss)
            .padding(.vertical, 11)
            .background(
                Color.mossFill.opacity(isBuildingExport ? 0.55 : 1),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(isBuildingExport)
            .accessibilityIdentifier("privacy.export")

            operationErrorLine(.export)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    private func runExport() {
        guard let store else { return }
        isBuildingExport = true
        setOperationError(nil, scope: .export)
        do {
            let url = try store.writeDataExportFile()
            exportPayload = DataExportPayload(url: url)
        } catch {
            setOperationError("Couldn't prepare your export. Please try again.", scope: .export)
        }
        isBuildingExport = false
    }

    /// Identifiable wrapper so the share sheet can present the freshly-written export file.
    ///
    /// Driven through `.sheet(item:)` — assigning a new payload presents ``ActivityShareView`` with
    /// the file URL, and dismissal nils it out.
    fileprivate struct DataExportPayload: Identifiable {
        let id = UUID()
        let url: URL
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

            deleteCloudDataControl

            Toggle("Sealed backup for sensitive notes", isOn: sealedSensitiveNotesBinding)
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            // Withheld while cycle tracking is hidden. The backup reconcile honors the visibility gate
            // by design (skipping rather than disabling the pref, since disabling DELETES the iCloud
            // backup) — but that skip is silent, so leaving this toggle live would let the user switch
            // it on, confirm a disclosure promising an encrypted upload, and be told it succeeded while
            // nothing was ever uploaded. Don't offer a backup for a feature that is switched off.
            if store?.isPeriodTrackingVisible ?? true {
                Toggle("Sealed backup for period data", isOn: sealedPeriodBinding)
                    .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            } else {
                Text("Sealed backup for period data is unavailable while period tracking is turned off. Your existing backup is kept.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            Toggle("Sealed backup for journal entries", isOn: sealedJournalBinding)
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))

            // Withheld while intimacy tracking is hidden, for exactly the reason the period toggle is:
            // the reconcile honors the hard visibility gate by SKIPPING (disabling the pref would delete
            // the iCloud backup, making "hide" destructive), and that skip is silent — so a live toggle
            // here would promise an upload that never happens.
            if store?.isIntimacyTrackingVisible ?? true {
                Toggle("Sealed backup for intimate logs", isOn: sealedIntimacyBinding)
                    .toggleStyle(SwitchToggleStyle(tint: Color.moss))
            } else {
                Text("Sealed backup for intimate logs is unavailable while intimacy tracking is turned off. Your existing backup is kept.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
            }

            // ONE switch for all three own-photo corpora (meal, recipe, gym progress). They are
            // internal record namespaces, not three consent questions — "back up my photos" is a
            // single decision about the user's own pictures — and the size disclosure below is
            // attached to the switch rather than buried in the confirm dialog, because photos are
            // the one backup whose cost the user pays in iCloud storage.
            Toggle("Sealed backup for your photos", isOn: ownPhotoBackupBinding)
                .toggleStyle(SwitchToggleStyle(tint: Color.moss))
                .accessibilityIdentifier("privacy.sealedBackup.ownPhotos")
            Text(Self.ownPhotoBackupSizeDisclosure)
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            ownPhotoDeviceBindingRow

            // Beneath the switches themselves, not at the far bottom of the page.
            operationErrorLine(.iCloud)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The delete-the-iCloud-copy control, sized to what is actually up there.
    ///
    /// Full-width terracotta while iCloud holds (or may hold) Fernlet records; a quiet terracotta
    /// text link once the account is known to be empty — the loudest control on the card used to be
    /// an offer to delete nothing, directly under "No Fernlet iCloud records were found".
    @ViewBuilder
    private var deleteCloudDataControl: some View {
        if showsProminentCloudDelete {
            Button(role: .destructive) {
                prepareDisableICloudFlow(deleteOnly: true)
            } label: {
                Label("Delete iCloud data", systemImage: "trash")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(Color.onTerracotta)
            .padding(.vertical, 11)
            .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("privacy.icloud.delete")
        } else {
            Button(role: .destructive) {
                prepareDisableICloudFlow(deleteOnly: true)
            } label: {
                Text("Delete iCloud data")
                    .font(.fernlet(.label))
                    .foregroundStyle(Color.terracottaInk)
                    .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("privacy.icloud.delete")
        }
    }

    /// Whether iCloud is known — or merely believed — to hold something worth a primary button.
    private var showsProminentCloudDelete: Bool {
        existingDataSummary != nil
            || cloudCountsUnavailable
            || storagePreferencesStore.preferences.iCloudSyncEnabled
            || storagePreferencesStore.preferences.cloudCopyKept
    }

    /// Security-hardening Phase 5, step 5c: the consent surface for **device-binding** the user's
    /// own photos.
    ///
    /// Binding is the whole point of the split — a bound key makes a stolen container or a restored
    /// device backup worthless — but it costs the user their photos on a phone swap, so Fernlet will
    /// not do it silently. The switch above is one of the two things that unlocks it (it is the
    /// sanctioned cross-device route, so a backed-up library binds automatically); this row is the
    /// other, for users who want the binding without the iCloud cost and are willing to say so.
    ///
    /// Three honest states, and no fourth: already bound, still preparing (the eager re-seal pass
    /// has not proven completion, so the gate would refuse), or offerable. A deferred bind — the
    /// keychain was briefly unavailable — says so instead of leaving a button that looked like it
    /// did nothing.
    @ViewBuilder
    private var ownPhotoDeviceBindingRow: some View {
        if let store {
            if store.ownPhotoKeyDeviceBound {
                Text("These photos are locked to this device: their key never leaves it, so a copy of "
                    + "your device backup can't open them. They won't restore onto a new phone "
                    + (storagePreferencesStore.preferences.sealedBackupOwnPhotosEnabled
                        ? "from a device backup — the encrypted photo backup above is how they come back."
                        : "at all. Turn on the encrypted photo backup above if you want them to survive a phone swap."))
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .accessibilityIdentifier("privacy.ownPhotos.deviceBound")
            } else if !store.ownPhotoKeyMigrationComplete {
                Text("Fernlet is still moving your existing photos onto their own encryption key. "
                    + "Locking them to this device becomes available once that finishes.")
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()
                    .accessibilityIdentifier("privacy.ownPhotos.deviceBindingPreparing")
            } else {
                Button(role: .destructive) {
                    presentOwnPhotoDeviceBindingConfirmation()
                } label: {
                    Label("Lock photos to this device", systemImage: "lock.iphone")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                .foregroundStyle(Color.onTerracotta)
                .padding(.vertical, 11)
                .background(Color.terracotta, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityIdentifier("privacy.ownPhotos.lockToDevice")

                Text(ownPhotoDeviceBindingExplanation)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fernletWrappingText()

                if ownPhotoBindingDeferred {
                    Text("Couldn't lock the photos to this device just now. Your choice is saved — "
                        + "Fernlet will finish it the next time it can reach the keychain.")
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.terracotta)
                        .fernletWrappingText()
                        .accessibilityIdentifier("privacy.ownPhotos.deviceBindingDeferred")
                }
            }
        }
    }

    /// The trade, stated before the tap — and it differs by exactly one fact: whether the encrypted
    /// photo backup is already covering the phone-swap case.
    private var ownPhotoDeviceBindingExplanation: String {
        if storagePreferencesStore.preferences.sealedBackupOwnPhotosEnabled {
            return "Locks your meal, recipe and progress photos to a key that never leaves this device, "
                + "so a copy of your device backup can't open them. Your encrypted photo backup still "
                + "restores them onto a new phone."
        }
        return "Locks your meal, recipe and progress photos to a key that never leaves this device, so a "
            + "copy of your device backup can't open them. Because the encrypted photo backup above is "
            + "off, these photos then won't come back on a new or erased phone. This can't be undone."
    }

    private func presentOwnPhotoDeviceBindingConfirmation() {
        let backedUp = storagePreferencesStore.preferences.sealedBackupOwnPhotosEnabled
        pendingDestructiveAction = DestructiveConfirmation(
            title: "Lock photos to this device?",
            message: backedUp
                ? "Your meal, recipe and progress photos will be encrypted with a key that never leaves "
                    + "this device. They'll come back on a new phone only through your encrypted photo "
                    + "backup, never from a device backup. This can't be undone."
                : "Your meal, recipe and progress photos will be encrypted with a key that never leaves "
                    + "this device. They will NOT restore onto a new or erased phone, and a device backup "
                    + "won't bring them back. Turn on the encrypted photo backup first if you want them to "
                    + "survive a phone swap. This can't be undone.",
            confirmLabel: "Lock to this device",
            auditEvent: "privacy.ownPhotos.deviceBindingConfirmed"
        ) {
            lockOwnPhotosToThisDevice()
        }
    }

    private func lockOwnPhotosToThisDevice() {
        guard let store else { return }
        // Consent is recorded by the store even when the bind defers, so the flag below reports a
        // transient keychain failure rather than re-asking a question the user already answered.
        ownPhotoBindingDeferred = !store.lockOwnPhotosToThisDevice().isBound
    }

    /// The honest size disclosure for the own-photo backup. Fernlet puts no count cap on meal,
    /// recipe or progress photos, so a heavy user's library really can run to hundreds of megabytes
    /// — and it is the USER's iCloud quota, not the developer's. Said plainly next to the switch.
    private static let ownPhotoBackupSizeDisclosure =
        "Your meal, recipe and progress photos, encrypted. Fernlet doesn't limit how many photos you keep, "
        + "so this can use a lot of your iCloud storage — roughly 150–400 KB per photo, which is 100–250 MB "
        + "or more for a big library. Only photos that changed are uploaded."

    /// The one consequence of this switch that is NOT about iCloud, said before the tap rather than
    /// only afterwards in `ownPhotoDeviceBindingRow`: once the first backup actually lands, these
    /// photos' key is locked to this device, which is irreversible and changes how they come back on
    /// a new phone. Deliberately phrased "once your photos are safely in the backup" because that is
    /// exactly the gate — the binding follows a committed upload, never the switch alone.
    private static let ownPhotoBackupBindingDisclosure =
        "Once your photos are safely in the backup, Fernlet locks their encryption key to this device, "
        + "so a copy of your device backup can't open them. That can't be undone, and from then on this "
        + "encrypted backup is how they come back on a new phone."

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
        if showsSealedBackupStatusBanner {
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel("Encrypted backup status")
                ownPhotoStatusLines
                sealedBackupDisableFailureLines
                reuploadDeferredLines
                escrowConflictSection
                attentionLines
                if showsRetryRestore { retryRestoreButton }
                operationErrorLine(.backupStatus)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
            .accessibilityIdentifier("privacy.sealedBackup.statusBanner")
        }
    }

    /// The payload backups whose last restore attempt needs the user's attention, in `allCases` order.
    private var sealedBackupAttentionItems: [SealedBackupAttention] {
        guard let store else { return [] }
        return SealedBackupPayloadType.allCases.compactMap { payload in
            guard let outcome = store.sealedBackupRestoreStatus[payload], outcome.needsAttention else { return nil }
            return SealedBackupAttention(payload: payload, outcome: outcome)
        }
    }

    /// The own-photo route's restore outcome when it needs attention, else nil.
    private var ownPhotoAttention: SealedBackupRestoreOutcome? {
        store?.ownPhotoBackupStatus.flatMap { $0.needsAttention ? $0 : nil }
    }

    /// Whether anything at all is wrong with the encrypted backups. The banner is hidden entirely
    /// when this is false — there is no "everything is fine" state to report here.
    private var showsSealedBackupStatusBanner: Bool {
        guard let store else { return false }
        return store.sealedBackupEscrowConflict || store.sealedBackupPeriodReuploadDeferred
            || store.sealedBackupJournalReuploadDeferred || store.sealedBackupIntimacyReuploadDeferred
            || !sealedBackupAttentionItems.isEmpty || !sealedBackupDisableFailures.isEmpty
            || ownPhotoAttention != nil || ownPhotoBackupDisableFailed
            || store.ownPhotoBackupUploadFailed
    }

    /// The own-photo backup's three failure lines: a failed upload, a failed disable-delete, and a
    /// restore outcome that needs attention.
    @ViewBuilder
    private var ownPhotoStatusLines: some View {
        if let store, store.ownPhotoBackupUploadFailed {
            // An UPLOAD failure, which the restore vocabulary cannot express: a device that has
            // photos never takes the restore path at all, so without this line a pass in which
            // nothing reached iCloud is completely invisible — an ON switch, an accepted size
            // disclosure, and no backup.
            Text("Couldn't upload your photos to your encrypted backup just now, so some or "
                + "all of them may not be in iCloud yet. We'll keep trying, or tap Retry.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("privacy.sealedBackup.ownPhotosUploadFailed")
        }

        if ownPhotoBackupDisableFailed {
            Text("Couldn't delete your encrypted photo backup from iCloud just now, so it's still switched on — that way it can still be removed. Turn it off again to retry.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("privacy.sealedBackup.ownPhotosDisableFailed")
        }

        // The photo route reuses the same outcome vocabulary as the payload backups, so
        // it reads the same — only the noun differs.
        if let ownPhotoAttention {
            Text(restoreStatusMessage(ownPhotoAttention, noun: "photo"))
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("privacy.sealedBackup.ownPhotosStatus")
        }
    }

    /// A failed disable-delete, one line per payload. The pref stayed ON deliberately (see
    /// `applySealedBackup`), so the remedy is the toggle the user already has — say so rather than
    /// leaving an off-looking switch and a live backup.
    private var sealedBackupDisableFailureLines: some View {
        ForEach(SealedBackupPayloadType.allCases.filter(sealedBackupDisableFailures.contains), id: \.self) { payload in
            Text("Couldn't delete your encrypted \(payload.displayNoun) backup from iCloud just now, so it's still switched on — that way it can still be removed. Turn it off again to retry.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("privacy.sealedBackup.disableFailed")
        }
    }

    /// The period / journal / intimacy re-upload deferrals, each naming the remedy that works for
    /// the state it is actually in.
    @ViewBuilder
    private var reuploadDeferredLines: some View {
        if let store, store.sealedBackupPeriodReuploadDeferred {
            // Two states share the flag: period still hidden (the un-hide is the remedy — and
            // it now actually triggers the re-upload), or already visible but the re-upload
            // hasn't succeeded yet. The visible copy must NOT promise an unconditional
            // automatic retry: the launch follow-through re-uploads only from a NON-EMPTY
            // narrative store (an empty one would overwrite the good cloud backup), so a
            // visible device with no local history waits on "Retry restore" (shown below for
            // exactly this state) to pull the backup down first.
            Text(store.isPeriodTrackingVisible
                 ? "Your period backup still needs re-uploading with your other device's backup key. This device re-uploads it automatically once your cycle history is on it — if it isn't yet, tap Retry restore to pull it down first."
                 : "Your period backup still needs re-uploading with your other device's backup key. It's hidden right now — un-hide period tracking, then this device will re-upload it so it can be restored later.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }

        // The journal/intimacy equivalents. Their payloads are sealed under the Private
        // tab's key, so turning the backup on from here (Home → Settings, hub re-locked)
        // always defers. The copy names the ONE remedy that always works and deliberately
        // does not promise an unconditional automatic upload: the retry only runs from a
        // store that actually holds entries this device can seal, because exporting an
        // empty one would replace the cloud backup with nothing.
        if let store, store.sealedBackupJournalReuploadDeferred {
            Text("Your journal backup hasn't finished uploading yet. Open the Private tab to unlock, and this device will finish it as soon as your journal entries are on it.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("privacy.sealedBackup.journalDeferred")
        }

        if let store, store.sealedBackupIntimacyReuploadDeferred {
            Text(store.isIntimacyTrackingVisible
                 ? "Your intimate log backup hasn't finished uploading yet. Open the Private tab to unlock, and this device will finish it as soon as your logs are on it."
                 : "Your intimate log backup hasn't finished uploading yet. It's hidden right now — un-hide intimacy tracking, then this device will finish it.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
                .accessibilityIdentifier("privacy.sealedBackup.intimacyDeferred")
        }
    }

    /// The cross-device escrow-key conflict explanation and its adopt button.
    @ViewBuilder
    private var escrowConflictSection: some View {
        if let store, store.sealedBackupEscrowConflict {
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
            .foregroundStyle(isResolvingEscrowConflict ? Color.bark : Color.onMoss)
            .padding(.vertical, 11)
            .background(
                Color.mossFill.opacity(isResolvingEscrowConflict ? 0.55 : 1),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(isResolvingEscrowConflict)
            .accessibilityIdentifier("privacy.sealedBackup.resolveConflict")
        }
    }

    /// One line per payload backup whose restore needs attention.
    private var attentionLines: some View {
        ForEach(sealedBackupAttentionItems) { item in
            Text(restoreStatusMessage(item.outcome, payload: item.payload))
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
    }

    /// Whether "Retry restore" can actually do anything about the states on screen.
    ///
    /// Also offered for a stuck VISIBLE re-upload deferral: with an empty narrative store there is no
    /// retryable attention item (the ambient restore is fresh-install-only and records nothing), yet
    /// the remedy IS a retry — `userInitiated` takes the targeted restore, and the same pass's
    /// follow-through then re-uploads and clears the deferral.
    private var showsRetryRestore: Bool {
        guard let store else { return false }
        return sealedBackupAttentionItems.contains(where: { $0.outcome.isRetryable })
            // The photo route rides the same Retry: `restoreSealedBackupsIfNeeded` runs
            // its synchronize pass too, so one button covers both routes — for a failed
            // restore, for the ids a partial restore left owed (the repair pass), and
            // for a failed upload.
            || (ownPhotoAttention?.isRetryable ?? false)
            || store.ownPhotoBackupUploadFailed
            || (store.sealedBackupPeriodReuploadDeferred && store.isPeriodTrackingVisible)
            // Same reasoning for the two Phase-3 payloads: a deferral with an empty local
            // store records no retryable attention item, yet Retry IS the remedy —
            // `userInitiated` takes their targeted restores, and the same pass's
            // follow-through then re-uploads and clears the deferral.
            || store.sealedBackupJournalReuploadDeferred
            || (store.sealedBackupIntimacyReuploadDeferred && store.isIntimacyTrackingVisible)
    }

    /// The one retry for both routes. Disabled while a retry is in flight (R3: one pass per tap —
    /// `restoreSealedBackupsIfNeeded` has no in-flight guard of its own, so overlapping taps would
    /// run concurrent escrow-reconcile + restore + photo-verification passes).
    private var retryRestoreButton: some View {
        Button { retrySealedRestore() } label: {
            Label(isRetryingRestore ? "Retrying…" : "Retry restore", systemImage: "arrow.clockwise")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
        .font(.fernlet(.label))
        .foregroundStyle(isRetryingRestore ? Color.bark : Color.onMoss)
        .padding(.vertical, 11)
        .background(
            Color.mossFill.opacity(isRetryingRestore ? 0.55 : 1),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .disabled(isRetryingRestore)
        .accessibilityIdentifier("privacy.sealedBackup.retryRestore")
    }

    private func restoreStatusMessage(_ outcome: SealedBackupRestoreOutcome, payload: SealedBackupPayloadType) -> String {
        restoreStatusMessage(outcome, noun: payload.displayNoun)
    }

    /// The same copy, keyed by a bare noun so the own-photo route — which is not a
    /// `SealedBackupPayloadType` — reads identically to the payload backups.
    private func restoreStatusMessage(_ outcome: SealedBackupRestoreOutcome, noun: String) -> String {
        switch outcome {
        case .deferredKeyNotSynced:
            return "Couldn't restore your \(noun) backup on this device yet — iCloud Keychain may still be syncing. We'll keep trying, or tap Retry."
        case .deferredLocked:
            return "Your \(noun) backup is ready to restore, but Fernlet is locked. Unlock, then tap Retry."
        case .deferredTransient:
            return "Couldn't reach your \(noun) backup just now. We'll keep trying, or tap Retry."
        case .notRecognized:
            return "A \(noun) backup was found in iCloud, but it isn't encrypted with this account's key, so it can't be restored on this device."
        case .rolledBack:
            // No Retry hint: retrying re-fetches the same record. The honest ask is to re-upload
            // from a device that still holds the data, which is the only path that recovers.
            return "The \(noun) backup in iCloud is older than one this device already has, so Fernlet didn't restore it — that shouldn't happen on its own. Nothing was changed. If you still have this data on another device, back it up again from there."
        case .restored, .nothingToRestore, .skippedStoreNotEmpty:
            return ""
        }
    }

    private func retrySealedRestore() {
        guard let store else { return }
        // One pass in flight at a time (R3): `SealedBackupCoordinator.restoreSealedBackupsIfNeeded`
        // has no in-flight guard, so without this every tap would spawn another overlapping
        // escrow-reconcile + restore + photo-verification pass.
        guard !isRetryingRestore else { return }
        FernletAuditLog.log("privacy.sealedBackup.retryRestore")
        isRetryingRestore = true
        // `userInitiated` lets the period half fall back to the targeted restore. Without it, Retry on an
        // in-use device can only ever hit the fresh-install-only gate, so it would clear the banner
        // without having retried anything.
        Task {
            await store.restoreSealedBackupsIfNeeded(userInitiated: true)
            await MainActor.run { isRetryingRestore = false }
        }
    }

    private func resolveEscrowConflict() {
        guard let store else { return }
        FernletAuditLog.log("privacy.sealedBackup.resolveEscrowConflict")
        isResolvingEscrowConflict = true
        Task {
            let adopted = await store.resolveSealedBackupEscrowConflict()
            await MainActor.run {
                isResolvingEscrowConflict = false
                // Nothing silent: a failed adoption leaves the conflict banner exactly as it was,
                // which on its own reads as a button that does nothing.
                guard adopted else {
                    setOperationError(
                        "Couldn't switch to your other device's backup key. Check iCloud and try again.",
                        scope: .backupStatus
                    )
                    FernletAuditLog.log("privacy.sealedBackup.resolveEscrowConflict.failed")
                    return
                }
            }
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
            .foregroundStyle(Color.onMoss)
            .padding(.vertical, 11)
            .background(Color.mossFill, in: RoundedRectangle(cornerRadius: 12))
            .accessibilityIdentifier("privacy.health.openSettings")

            operationErrorLine(.health)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    /// The delete-everything card. Headed for what the button does — it used to sit under an "App
    /// lock data" header whose paragraph about the Fernlet passcode described neither the button nor
    /// its scope (that paragraph now lives on the App lock page, where it is about something).
    private var lockDataCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionLabel("Delete your data")
            Text("Erase everything Fernlet stores on this phone and in your iCloud.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()

            deleteEverythingButton
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
    }

    /// The second entry point into the shared delete funnel.
    ///
    /// It used to be "Delete all protected data" calling `lockService.reset()`, whose copy claimed to
    /// delete "all other protected Fernlet data" — false twice over. `reset()` clears exactly four sealed
    /// entities (cycle notes, journal, intimate logs, Worry Box) and left days, photos, coins, recipes
    /// and Fernlet's Health samples untouched; and the `try?` meant a FAILED delete looked identical to a
    /// successful one on a screen whose whole premise is that nothing destructive happens silently.
    /// Renders nothing without a store — the injected-nil case is previews and unit tests, and a delete
    /// button that silently does nothing would be worse than an absent one.
    @ViewBuilder
    private var deleteEverythingButton: some View {
        if let store {
            Button(role: .destructive) {
                pendingDestructiveAction = deleteFlow.makeConfirmation(
                    preferences: storagePreferencesStore.preferences,
                    store: store,
                    onWipeFinished: {
                        // The wipe has just swept the exported file off disk; drop the view's reference to
                        // it too, so re-presenting the share sheet can't hand a now-deleted plaintext URL
                        // to UIActivityViewController. `.sheet(item:)` already nils this on dismiss, so in
                        // practice it is nil here — this is belt-and-braces against a retained stale URL.
                        exportPayload = nil
                    }
                )
            } label: {
                Label("Delete everything", systemImage: "trash.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.plain)
            .font(.fernlet(.label))
            .foregroundStyle(deleteFlow.isDeleting ? Color.bark : Color.onTerracotta)
            .padding(.vertical, 11)
            .background(
                Color.terracotta.opacity(deleteFlow.isDeleting ? 0.55 : 1),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .disabled(deleteFlow.isDeleting)
            .accessibilityIdentifier("privacy.lock.deleteProtectedData")
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
                    disableSheetSpinner
                } else {
                    disableSheetExplanation
                    disableSheetActions
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

    /// The in-sheet busy state while the persistence stack is being swapped.
    private var disableSheetSpinner: some View {
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
    }

    /// What turning sync off actually costs — the record counts, the divergence warning, the
    /// deletion warning — and the type-DELETE confirmation field that arms the destructive button.
    private var disableSheetExplanation: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Titled by the door the user came through: from the Delete button (sync already
                // off) "Turn off iCloud sync?" described nothing they had asked for.
                ScreenHeader(
                    title: isCloudDeleteOnlyEntry ? "Delete iCloud data?" : "Turn off iCloud sync?",
                    subtitle: isCloudDeleteOnlyEntry
                        ? "This removes Fernlet's records from your iCloud account."
                        : "Stop syncing now, or also delete iCloud data."
                )

                cloudCountsCard

                if !isCloudDeleteOnlyEntry {
                    Text("Stopping sync keeps your data on this device but disconnects it from iCloud: changes you make here will no longer reach your other Fernlet devices, and theirs won't reach you. The two will drift apart until you turn sync back on.")
                        .font(.fernlet(.body))
                        .foregroundStyle(Color.bark)
                        .fernletWrappingText()
                        .padding(14)
                        .background(Color.terracotta.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                        .accessibilityIdentifier("privacy.icloud.divergenceWarning")
                }

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
    }

    /// The two ways out: keep the iCloud copy, or delete it (armed only by the typed DELETE).
    private var disableSheetActions: some View {
        let isArmed = deleteConfirmationText.uppercased() == "DELETE"
        return VStack(spacing: 12) {
            // "Stop syncing, keep iCloud data" is an answer to "do you want to turn sync off?".
            // Entered from the Delete button — with sync already off — it answers nothing.
            if !isCloudDeleteOnlyEntry {
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
            }

            HStack {
                Spacer()
                Button("Delete iCloud data") {
                    disableICloudSyncAndDeleteCloudData()
                }
                .buttonStyle(.plain)
                .font(.fernlet(.label))
                // Terracotta, not moss: this deletes, and moss is the app's affirmative colour.
                // Disabled fades the fill only, so the label stays readable while the user types.
                .foregroundStyle(isArmed ? Color.onTerracotta : Color.bark)
                .padding(.horizontal, 28)
                .padding(.vertical, 16)
                .background(
                    Color.terracotta.opacity(isArmed ? 1 : 0.55),
                    in: RoundedRectangle(cornerRadius: 16)
                )
                .disabled(!isArmed)
                .accessibilityIdentifier("privacy.icloud.confirmDelete")
            }
        }
        .padding(20)
        .background(Color.parchment)
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
            } else if cloudCountsUnavailable {
                // The probe threw. Saying "none found" here would report a check that never ran.
                Text("Couldn't check iCloud just now, so what's up there is unknown.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
                    .fernletWrappingText()
                    .accessibilityIdentifier("privacy.icloud.countsUnavailable")
            } else {
                Text("No Fernlet iCloud records were found.")
                    .font(.fernlet(.body))
                    .foregroundStyle(Color.bark)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private var sealedJournalBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.sealedBackupJournalEnabled },
            set: { newValue in handleSealedBackupToggle(.journalNarratives, enabled: newValue) }
        )
    }

    private var sealedIntimacyBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.sealedBackupIntimacyEnabled },
            set: { newValue in handleSealedBackupToggle(.intimacyLogs, enabled: newValue) }
        )
    }

    /// The own-photo escrow backup switch. Enabling asks for informed consent (the same
    /// "nothing leaves the device unencrypted" dialog the other payloads use, plus the size
    /// disclosure); disabling routes through the WS-5 destructive ceremony, because turning it off
    /// DELETES the photo backup from iCloud.
    private var ownPhotoBackupBinding: Binding<Bool> {
        Binding(
            get: { storagePreferencesStore.preferences.sealedBackupOwnPhotosEnabled },
            set: { newValue in handleOwnPhotoBackupToggle(enabled: newValue) }
        )
    }

    private func handleOwnPhotoBackupToggle(enabled: Bool) {
        FernletAuditLog.log(
            "privacy.sealedBackup.changed",
            context: ["payload": "ownPhotos", "enabled": enabled ? "true" : "false"]
        )
        if enabled {
            pendingOwnPhotoBackupEnable = true
        } else {
            pendingDestructiveAction = DestructiveConfirmation(
                title: "Turn off encrypted photo backup?",
                message: "This permanently deletes your encrypted meal, recipe and progress photo backup "
                    + "from iCloud. If you lose or replace this device, those photos can't be recovered. "
                    + "Turn off anyway?",
                confirmLabel: "Turn off",
                auditEvent: "privacy.sealedBackup.disableConfirmed.ownPhotos"
            ) {
                applyOwnPhotoBackup(enabled: false)
            }
        }
    }

    private func applyOwnPhotoBackup(enabled: Bool) {
        guard let store else {
            // No store (UI-test harness): just reflect the preference.
            storagePreferencesStore.update { $0.sealedBackupOwnPhotosEnabled = enabled }
            return
        }
        Task {
            let ok = await store.setOwnPhotoBackupEnabled(enabled)
            await MainActor.run {
                if ok {
                    storagePreferencesStore.update { $0.sealedBackupOwnPhotosEnabled = enabled }
                    ownPhotoBackupDisableFailed = false
                } else if !enabled {
                    // Same rule as the payload toggles: a failed delete keeps the preference ON so
                    // the surviving records stay targetable by a retry (and by "delete everything"),
                    // and the banner says so instead of the failure hiding behind an off switch.
                    ownPhotoBackupDisableFailed = true
                    FernletAuditLog.log("privacy.sealedBackup.disableFailed", context: ["payload": "ownPhotos"])
                } else {
                    // A FAILED enable. The preference stays off, so the switch the user just
                    // consented to (size + binding disclosures) snaps back — say why instead of
                    // letting it look like a switch that refuses to move.
                    setOperationError(
                        "Couldn't turn on the encrypted photo backup. Check that iCloud is available and try again.",
                        scope: .iCloud
                    )
                    FernletAuditLog.log("privacy.sealedBackup.enableFailed", context: ["payload": "ownPhotos"])
                }
            }
        }
    }

    private func handleSealedBackupToggle(_ payload: SealedBackupPayloadType, enabled: Bool) {
        FernletAuditLog.log(
            "privacy.sealedBackup.changed",
            context: ["payload": payload.rawValue, "enabled": enabled ? "true" : "false"]
        )
        if enabled {
            // Require explicit, informed confirmation before any data leaves the device.
            pendingSealedBackupEnable = payload
        } else {
            // Turning a sealed backup OFF permanently deletes that encrypted backup from iCloud — a
            // destructive, irreversible action that must be confirmed first (WS-5).
            let noun = payload.displayNoun
            pendingDestructiveAction = DestructiveConfirmation(
                title: "Turn off encrypted \(noun) backup?",
                message: "This permanently deletes your encrypted \(noun) backup from iCloud. "
                    + "If you lose or replace this device, that data can't be recovered. Turn off anyway?",
                confirmLabel: "Turn off",
                auditEvent: "privacy.sealedBackup.disableConfirmed.\(payload.rawValue)"
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
                    if ok {
                        setSealedBackupPreference(payload, true)
                        sealedBackupDisableFailures.remove(payload)
                    } else {
                        // A FAILED enable (escrow key not provisioned, or a reconcile failure). The
                        // preference stays off, so the toggle the user just confirmed through the
                        // "Encrypt & back up" consent alert snaps back — say why rather than leaving
                        // the screen whose invariant is "never a silent swallow" doing exactly that.
                        setOperationError(
                            "Couldn't turn on the encrypted \(payload.displayNoun) backup. Check that iCloud sync is on and try again.",
                            scope: .iCloud
                        )
                        FernletAuditLog.log(
                            "privacy.sealedBackup.enableFailed",
                            context: ["payload": payload.rawValue]
                        )
                    }
                } else if ok {
                    setSealedBackupPreference(payload, false)
                    sealedBackupDisableFailures.remove(payload)
                } else {
                    // The CloudKit delete FAILED. Clearing the pref here would "honor the off intent"
                    // by making the surviving CKRecords unreachable: `hasSealedBackup` reads false, so
                    // neither delete-all nor a re-toggle would ever target them again, and the backup
                    // outlives the user's decision to remove it. Keep the pref ON — mirroring
                    // delete-all's `keepSealedBackupFlags` — and surface the failure non-silently so
                    // the retry (toggling off again) still has something to point at.
                    sealedBackupDisableFailures.insert(payload)
                    FernletAuditLog.log(
                        "privacy.sealedBackup.disableFailed",
                        context: ["payload": payload.rawValue]
                    )
                }
            }
        }
    }

    private func setSealedBackupPreference(_ payload: SealedBackupPayloadType, _ value: Bool) {
        storagePreferencesStore.update {
            switch payload {
            case .periodData: $0.sealedBackupPeriodEnabled = value
            case .sensitiveNotes: $0.sealedBackupSensitiveNotesEnabled = value
            case .journalNarratives: $0.sealedBackupJournalEnabled = value
            case .intimacyLogs: $0.sealedBackupIntimacyEnabled = value
            }
        }
    }

    private func sealedBackupDisclosure(for payload: SealedBackupPayloadType?) -> String {
        var lines = [
            "Your data leaves this device only in encrypted form.",
            "Apple can't read it.",
            "If iCloud Keychain is ever permanently lost, this backup can't be recovered on a new device."
        ]
        switch payload {
        case .periodData:
            lines.append("Period data is sensitive; it is uploaded only in this encrypted form.")
        case .intimacyLogs:
            lines.append("Intimate logs are sensitive; they are uploaded only in this encrypted form.")
        case .journalNarratives:
            lines.append("Your journal text is uploaded only in this encrypted form.")
        case .sensitiveNotes, nil:
            break
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
                    // recovery path) — commit directly. Any explicit toggle IS a decision, so record
                    // `backupExclusionChoiceMade` too: without it, an existing install that re-includes
                    // here would be re-asked by the Phase-6 one-time launch prompt on the next launch.
                    FernletAuditLog.log("privacy.localBackup.included")
                    storagePreferencesStore.update {
                        $0.localBackupExcludedFromiOSBackup = false
                        $0.backupExclusionChoiceMade = true
                    }
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
                        // Same decision-recording as the include branch: a confirmed exclude settles
                        // the Phase-6 launch question too.
                        storagePreferencesStore.update {
                            $0.localBackupExcludedFromiOSBackup = true
                            $0.backupExclusionChoiceMade = true
                        }
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

    /// - Parameter deleteOnly: True when the sheet was opened by the "Delete iCloud data" button
    ///   rather than by turning the sync switch off, which is the whole difference between the two
    ///   questions the sheet can ask.
    ///
    /// The delete-only framing is withheld while sync is still ON, deliberately: this flow turns
    /// sync off as well, so with sync on the user must still see the divergence warning and the
    /// keep-the-copy alternative rather than a sheet that only mentions deletion.
    private func prepareDisableICloudFlow(deleteOnly: Bool = false) {
        deleteConfirmationText = ""
        isCloudDeleteOnlyEntry = deleteOnly && !storagePreferencesStore.preferences.iCloudSyncEnabled
        isShowingDisableConfirmation = true
        Task { await loadCloudCountsIfNeeded(force: true) }
    }

    private func enableICloudSync() {
        FernletAuditLog.log("privacy.icloud.syncEnabled")
        var updated = storagePreferencesStore.preferences
        updated.iCloudSyncEnabled = true
        // The live sync copy is now the cloud copy; the standalone "kept" marker no longer applies.
        updated.cloudCopyKept = false
        applyStoragePreferences(updated)
    }

    private func stopSyncingKeepCloudData() {
        FernletAuditLog.log("privacy.icloud.syncDisabled.keepData")
        var updated = storagePreferencesStore.preferences
        updated.iCloudSyncEnabled = false
        // Record that a full copy is being LEFT in iCloud with sync off. Nothing else remembers this, so
        // without it `hasAnyCloudCopy` reads false for this user — the delete dialog omits the iCloud
        // sentence and "delete everything" can't reach the stranded copy.
        updated.cloudCopyKept = true
        applyStoragePreferences(updated)
        isShowingDisableConfirmation = false
    }

    private func disableICloudSyncAndDeleteCloudData() {
        guard deleteConfirmationText.uppercased() == "DELETE" else { return }
        FernletAuditLog.log("privacy.icloud.deletionInitiated")
        isUpdatingStorage = true
        setOperationError(nil, scope: .iCloud)
        Task { @MainActor in
            do {
                var updated = storagePreferencesStore.preferences
                updated.iCloudSyncEnabled = false
                // Record the copy TOGETHER with turning sync off: `deleteAllCloudKitData` below can
                // throw, and by then sync-off has persisted — exactly the sync-off-with-cloud-copy
                // state `cloudCopyKept` exists to track. Without this, the catch shows a one-shot
                // error and the stranded copy becomes invisible forever: `hasAnyCloudCopy` reads
                // false, so the delete dialog never claims it and "delete everything" never reaches
                // it. The success path clears the marker below.
                updated.cloudCopyKept = true
                try await reloadPersistence(with: updated)
                storagePreferencesStore.update { $0 = updated }
                FernletAuditLog.log("privacy.icloud.syncDisabled")

                _ = try await cloudDataService.deleteAllCloudKitData(
                    confirmation: DeletionConfirmation(userTypedConfirmation: deleteConfirmationText.uppercased())
                )
                // The cloud copy is now gone, so clear the "kept a copy" marker — leaving it set would make
                // the delete dialog keep promising to remove an iCloud copy that no longer exists.
                storagePreferencesStore.update { $0.cloudCopyKept = false }
                // The cloud records were just deleted, so the previously-detected summary is stale. Clear it
                // so the "Cloud records" card and the always-on multi-device warning banner immediately
                // reflect the now-empty cloud instead of continuing to report data that no longer exists.
                existingDataSummary = nil
                isShowingDisableConfirmation = false
            } catch {
                setOperationError(error.localizedDescription, scope: .iCloud)
                isShowingDisableConfirmation = false
            }
            isUpdatingStorage = false
        }
    }

    private func applyStoragePreferences(_ preferences: StoragePreferences) {
        isUpdatingStorage = true
        setOperationError(nil, scope: .iCloud)
        Task { @MainActor in
            do {
                try await reloadPersistence(with: preferences)
                storagePreferencesStore.update { $0 = preferences }
            } catch {
                setOperationError(error.localizedDescription, scope: .iCloud)
            }
            isUpdatingStorage = false
        }
    }

    private func reloadPersistence(with preferences: StoragePreferences) async throws {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_SLOW_RELOAD"] == "1" {
            // Propagates: this function is `async throws` and both callers already surface the error,
            // so a cancelled reload ends the wait instead of vanishing into a `try?`.
            try await Task.sleep(for: .milliseconds(1500))
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
            cloudCountsUnavailable = false
        } catch {
            // "The query failed" is not "the account is empty": conflating them would claim no
            // iCloud records exist and suppress the multi-device warning on a check that never ran.
            existingDataSummary = nil
            cloudCountsUnavailable = true
            FernletAuditLog.log("privacy.icloud.detectFailed", context: [
                "errorType": "\(type(of: error))"
            ])
        }
    }

    private func setHealthKitMasterEnabled(_ enabled: Bool) async {
        setOperationError(nil, scope: .health)
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
            setOperationError(error.localizedDescription, scope: .health)
        }
    }

    private func makeHealthKitService() -> any PrivacyHealthKitServicing {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" {
            return MockPrivacyHealthKitService(preferencesStore: storagePreferencesStore)
        }
        return HealthKitService(preferencesStore: storagePreferencesStore)
    }
}

/// Chooses the cloud-data and persistence-reload implementations for this launch.
///
/// ``PrivacyDataSettingsView``'s initializer falls back to it when no service is injected: the
/// `FERNLET_UI_TEST_PRIVACY_SERVICES` launch environment selects the mocks (with env-supplied
/// counts); every normal launch gets `CloudKitDataService` and `PersistenceController.shared`.
@MainActor
private enum PrivacyDataServiceFactory {
    /// - Returns: A `MockPrivacyCloudDataService` under the UI-test environment, else the live service.
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

    /// - Returns: A `MockPrivacyPersistenceReloader` under the UI-test environment, else the shared controller.
    static func makePersistenceReloader() -> any PrivacyPersistenceReloading {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_PRIVACY_SERVICES"] == "1" {
            return MockPrivacyPersistenceReloader()
        }
        return PersistenceController.shared
    }
}

/// Test double for ``PrivacyCloudDataManaging`` that returns a canned summary and simulates the
/// type-DELETE-to-confirm contract without touching CloudKit.
///
/// Built by `PrivacyDataServiceFactory` when the UI-test launch environment asks for mock privacy
/// services; the delete still throws unless the confirmation text is exactly "DELETE", so the
/// confirm gate stays exercised in tests.
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

/// Test double for ``PrivacyPersistenceReloading`` that does nothing (optionally slowly).
///
/// Used under the UI-test privacy-services environment; `FERNLET_UI_TEST_SLOW_RELOAD` adds a delay
/// so tests can assert the "Updating storage settings…" spinner appears.
@MainActor
private struct MockPrivacyPersistenceReloader: PrivacyPersistenceReloading {
    func reload(with preferences: StoragePreferences) async throws {
        if ProcessInfo.processInfo.environment["FERNLET_UI_TEST_SLOW_RELOAD"] == "1" {
            try await Task.sleep(for: .milliseconds(1500))
        }
    }
}

/// Test double for ``PrivacyHealthKitServicing`` that flips the stored preferences without touching
/// HealthKit.
///
/// Used under the UI-test privacy-services environment so the master toggle's on/off flows (and the
/// capability reset on disable) can be exercised on simulators without Health authorization.
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
