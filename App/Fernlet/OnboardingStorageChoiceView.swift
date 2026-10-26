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
/// the delete-everything funnel. Continue stays disabled until a card is picked. When the account
/// holds a Sealed backup or a photo backup, a note says so and how to restore it — every backup switch
/// is device-only, so a new iPhone starts with all of them off and nothing else would mention it (bug
/// confirmation 2026-10-15 §2).
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
                            .accessibilityHidden(true)
                        Text("Checking iCloud for Fernlet data")
                            .font(.fernlet(.labelSmall))
                            .foregroundStyle(WorldPalette.dim)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(WorldPalette.paper, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldPalette.ink, lineWidth: 2))
                    .accessibilityIdentifier("onboarding.storage.detecting")
                } else {
                    VStack(spacing: 12) {
                        storageCard(
                            choice: .icloud,
                            title: existingDataSummary?.hasData == true ? "Restore from iCloud" : "Sync to iCloud",
                            copy: iCloudCopy,
                            sprite: WorldSprites.cloud,
                            tileFill: WorldPalette.rgb(0xA9C6DA)
                        )
                        .accessibilityIdentifier("onboarding.storage.icloud")

                        storageCard(
                            choice: .localOnly,
                            title: "Just on this device",
                            copy: localOnlyCopy,
                            sprite: WorldSprites.diary,
                            tileFill: nil
                        )
                        .accessibilityIdentifier("onboarding.storage.local")

                        if selectedStorage == .localOnly, existingDataSummary?.hasData == true {
                            localOnlyDataWarning
                        }
                        if existingDataSummary?.sealedBackups.offersRestore == true {
                            sealedBackupFoundNote
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

    /// `Text`, not `String`: `storageCard` draws its copy, and a `String` reached `Text` through the
    /// verbatim overload. The three counts use automatic grammar agreement, so one restored meal no
    /// longer reads "1 meal logs".
    private var iCloudCopy: Text {
        guard let existingDataSummary, existingDataSummary.hasData else {
            return Text("Your daily logs are saved to iCloud and appear on your other Fernlet devices.")
        }
        let meals = existingDataSummary.mealLogCount
        let entries = existingDataSummary.journalEntryCount
        let workouts = existingDataSummary.workoutCount
        return Text("Restore from iCloud — we found ^[\(meals) meal log](inflect: true), ^[\(entries) journal entry](inflect: true), ^[\(workouts) workout](inflect: true) from a previous device.",
                    comment: "Onboarding storage card when this iCloud account already holds Fernlet data. Arguments: the meal-log, journal-entry and workout counts found.")
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
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(WorldPalette.warn, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(WorldPalette.ink, lineWidth: 2))
        .accessibilityIdentifier("onboarding.storage.localWarning")
    }

    /// Shown when the account holds an encrypted backup a switch would restore — journal text, cycle
    /// notes, intimate logs or photos. Those restore only through their own switches, all of which
    /// start off on a new iPhone, so without this a returning user's "Restore from iCloud" brings the
    /// day logs back and never mentions the rest.
    private var sealedBackupFoundNote: some View {
        Text("This iCloud account also holds an encrypted backup of your journal, cycle, intimate logs or photos. To restore it to this iPhone, turn on its backup in Settings › Privacy & Data after setup.")
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.bark)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("onboarding.storage.sealedBackupFound")
    }

    /// Shown when the iCloud probe failed: the choices below are being offered without knowing
    /// whether this account already holds Fernlet data, and the user is told so rather than being
    /// quietly handed the fresh-install copy.
    private var detectionFailedNote: some View {
        Text("Couldn't check this iCloud account for existing Fernlet data — if you used Fernlet before, choose Sync to iCloud to restore it.")
            .font(.fernlet(.bodySmall))
            .foregroundStyle(WorldPalette.dim)
            .fernletWrappingText()
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier("onboarding.storage.detectFailed")
    }

    /// `Text` for the same reason as ``iCloudCopy``.
    private var localOnlyCopy: Text {
        if existingDataSummary?.hasData == true {
            return Text("Nothing leaves this phone. The data already in this iCloud account won't be merged in, and logs here won't sync to your other devices. You can turn on iCloud later in Settings.")
        }
        return Text("Nothing leaves this phone — logs here won't sync to your other devices. You can turn on iCloud later in Settings.")
    }

    /// One storage choice. `title` is a `LocalizedStringKey` and `copy` a `Text`: both were `String`,
    /// so "Restore from iCloud", "Just on this device" and every explanation under them rendered in
    /// English in every language.
    private func storageCard(choice: OnboardingStorageChoice, title: LocalizedStringKey, copy: Text, sprite: WorldSprite, tileFill: Color?) -> some View {
        Button {
            FernletFeedback.system.select(choice, in: &selectedStorage)
            storagePreferencesStore.update { preferences in
                preferences.iCloudSyncEnabled = choice == .icloud
                preferences.cloudCopyKept = choice == .localOnly && existingDataSummary?.hasData == true
            }
            FernletAuditLog.log("onboarding.storage.chosen", context: [
                "choice": choice == .icloud ? "icloud" : "localOnly"
            ])
        } label: {
            // Design `b2-onb-3`: a framed card per place; the chosen one wears the moss ring.
            OnboardingCard(sprite: sprite, title: Text(title), detail: copy, isSelected: selectedStorage == choice,
                           tileFill: tileFill)
        }
        .buttonStyle(.plain)
        .accessibilityInputLabels([Text(title)])
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
