import SwiftUI
import CloudKitSync
import FernletFoundation
import FernletDomainModel
import FernletUI

/// Onboarding step where the user chooses where their logs live: iCloud sync or this device only.
///
/// First probes the account through the injected ``ExistingCloudDataDetecting`` — the choices stay
/// hidden behind a spinner until detection finishes, so a returning user always sees "Restore from
/// iCloud" and the local-only warning rather than the fresh-install copy. Unlike the other steps,
/// a tap here writes `StoragePreferences` immediately (via the environment's
/// `StoragePreferencesStore`): `iCloudSyncEnabled`, and `cloudCopyKept` when local-only is chosen
/// while the account already holds data — the marker that keeps a stranded cloud copy reachable by
/// the delete-everything funnel. Continue stays disabled until a card is picked.
struct OnboardingStorageChoiceView: View {
    var stepText: String
    let detector: any ExistingCloudDataDetecting
    var backAction: (() -> Void)?
    var continueAction: () -> Void

    @Environment(StoragePreferencesStore.self) private var storagePreferencesStore
    @State private var selectedStorage: OnboardingStorageChoice?
    @State private var existingDataSummary: ExistingDataSummary?
    @State private var isDetecting = true
    /// Set when the iCloud probe threw. Distinguishes "this account has no Fernlet data" from
    /// "we couldn't check", so the fresh-install copy is never shown on the strength of a failure.
    @State private var detectionFailed = false

    var body: some View {
        VStack(spacing: 0) {
            OnboardingScreenContainer(
                stepText: stepText,
                title: "Choose where logs live",
                subtitle: "You can change this later in Settings.",
                backAction: backAction
            ) {
                // Show ONLY the spinner while detecting, then reveal the choices — so the user can't pick
                // "just on this device" (and see the softer copy) before detection has had a chance to find
                // existing iCloud data and surface the stronger warning below.
                if isDetecting {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Checking iCloud for Fernlet data")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(Color.slate)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .accessibilityIdentifier("onboarding.storage.detecting")
                } else {
                    VStack(spacing: 12) {
                        storageCard(
                            choice: .icloud,
                            title: existingDataSummary == nil ? "Sync to iCloud" : "Restore from iCloud",
                            copy: iCloudCopy,
                            systemImage: "icloud.fill"
                        )
                        .accessibilityIdentifier("onboarding.storage.icloud")

                        storageCard(
                            choice: .localOnly,
                            title: "Just on this device",
                            copy: localOnlyCopy,
                            systemImage: "iphone"
                        )
                        .accessibilityIdentifier("onboarding.storage.local")

                        if selectedStorage == .localOnly, existingDataSummary?.hasData == true {
                            localOnlyDataWarning
                        }
                        if detectionFailed {
                            detectionFailedNote
                        }
                    }
                }
            }
            SheetSaveBar(label: "Continue", disabled: selectedStorage == nil) { continueAction() }
        }
        .accessibilityIdentifier("onboarding.storage")
        .task { await detectExistingCloudData() }
    }

    private var iCloudCopy: String {
        guard let existingDataSummary else {
            return "Your daily logs are saved to iCloud and appear on your other Fernlet devices."
        }
        return "Restore from iCloud — we found \(existingDataSummary.mealLogCount) meal logs, \(existingDataSummary.journalEntryCount) journal entries, \(existingDataSummary.workoutCount) workouts from a previous device."
    }

    /// Emphasized when the user picks local-only but iCloud already holds their Fernlet data — that data
    /// won't be merged in and logs here won't sync, so it's an easy choice to make by mistake.
    private var localOnlyDataWarning: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Color.sun)
            Text("Heads up: this iCloud account already has Fernlet data. Choosing “Just on this device” won’t bring it in, and anything you log here won’t reach your other devices.")
                .font(.fernlet(.bodySmall))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sun.opacity(0.12), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityIdentifier("onboarding.storage.localWarning")
    }

    /// Shown when the iCloud probe failed: the choices below are being offered without knowing
    /// whether this account already holds Fernlet data, and the user is told so rather than being
    /// quietly handed the fresh-install copy.
    private var detectionFailedNote: some View {
        Text("Couldn't check this iCloud account for existing Fernlet data — if you used Fernlet before, choose Sync to iCloud to restore it.")
            .font(.fernlet(.bodySmall))
            .foregroundStyle(Color.slate)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("onboarding.storage.detectFailed")
    }

    private var localOnlyCopy: String {
        if existingDataSummary?.hasData == true {
            return "Nothing leaves this phone. The data already in this iCloud account won't be merged in, and logs here won't sync to your other devices. You can turn on iCloud later in Settings."
        }
        return "Nothing leaves this phone — logs here won't sync to your other devices. You can turn on iCloud later in Settings."
    }

    private func storageCard(choice: OnboardingStorageChoice, title: String, copy: String, systemImage: String) -> some View {
        Button {
            selectedStorage = choice
            storagePreferencesStore.update { preferences in
                preferences.iCloudSyncEnabled = choice == .icloud
                // "Just on this device" while this iCloud account already holds Fernlet data leaves
                // that copy in the cloud with sync off — record it, or `hasAnyCloudCopy` reads false
                // and the delete dialog never claims (nor "delete everything" ever reaches) the
                // stranded copy. Recomputed on every tap, so switching back to iCloud clears it (a
                // live sync copy is tracked by `iCloudSyncEnabled` itself).
                preferences.cloudCopyKept = choice == .localOnly && existingDataSummary?.hasData == true
            }
            FernletAuditLog.log("onboarding.storage.chosen", context: [
                "choice": choice == .icloud ? "icloud" : "localOnly"
            ])
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selectedStorage == choice ? "checkmark.circle.fill" : systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(selectedStorage == choice ? Color.moss : Color.slate)
                    .frame(width: 32, height: 32)
                    .background(Color.moss.opacity(selectedStorage == choice ? 0.12 : 0.06), in: Circle())
                VStack(alignment: .leading, spacing: 6) {
                    Text(title)
                        .font(.fernlet(.header))
                        .foregroundStyle(Color.bark)
                    Text(copy)
                        .font(.fernlet(.bodySmall))
                        .foregroundStyle(Color.slate)
                        .fernletWrappingText()
                }
                Spacer(minLength: 8)
            }
            .padding(16)
            .background(selectedStorage == choice ? Color.moss.opacity(0.07) : Color.cream, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(selectedStorage == choice ? Color.moss.opacity(0.42) : Color.bark.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        // T1-5: a hand-rolled selection card — the glyph swap and tint are otherwise the only
        // signal, on the choice that decides where the user's data lives.
        .accessibilityAddTraits(selectedStorage == choice ? .isSelected : [])
    }

    private func detectExistingCloudData() async {
        isDetecting = true
        defer { isDetecting = false }
        do {
            existingDataSummary = try await detector.detectExistingData()
            detectionFailed = false
        } catch {
            // A failed probe is NOT "no data": treating it as such would show a returning user the
            // fresh-install copy and no local-only warning — the exact mistake the spinner gate
            // above exists to prevent. Say so, and log it.
            existingDataSummary = nil
            detectionFailed = true
            FernletAuditLog.log(
                "onboarding.storage.detectFailed",
                context: ["errorType": "\(type(of: error))"]
            )
        }
    }
}

/// The two storage homes offered during onboarding: the user's own iCloud private database, or
/// this device alone.
///
/// Selection state for ``OnboardingStorageChoiceView`` only — the durable record is the
/// `StoragePreferences` write the card tap performs.
private enum OnboardingStorageChoice {
    case icloud
    case localOnly
}
