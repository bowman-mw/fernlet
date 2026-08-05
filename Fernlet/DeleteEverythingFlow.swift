import SwiftUI
import FernletFoundation
import FernletUI

/// Per-screen state and closure glue for the "delete everything" wipe, shared by both Settings entry
/// points (``SettingsSheet`` and ``PrivacyDataSettingsView``).
///
/// ``DeleteAllDataConfirmation`` already funnels both entry points into one dialog and one
/// `FernletStore.deleteAllData` call; this type is the same consolidation one layer up — the state trio
/// (busy flag, success flag, failure outcome) and the confirm/finish closures used to be hand-copied in
/// each view and would drift the first time someone edited one copy.
///
/// Each screen owns its OWN instance (`@State private var deleteFlow = DeleteEverythingFlow()`) —
/// never a shared one. The per-screen ``isDeleting`` seam is load-bearing: the enclosing Settings
/// sheet's `interactiveDismissDisabled` keys off ITS flow's flag, which is deliberately false for a
/// wipe started from the pushed Privacy & Data screen (whose busy overlay leaves the nav bar's Back
/// chevron tappable as an escape hatch). The buttons, overlays, and dismiss guards stay per-screen
/// in the views; only the state and the outcome alerts (the shared `.deleteEverythingAlerts`
/// modifier) are shared.
@MainActor
@Observable
final class DeleteEverythingFlow {
    /// Non-nil when a wipe came back incomplete — drives the failure alert. A silently half-finished
    /// delete is the exact failure mode the delete-everything rework exists to end, so it gets a surface.
    var failure: FernletStore.DeleteAllOutcome?
    /// True while a "delete everything" wipe runs — the owning screen keys its busy overlay, delete /
    /// Done button disabling, and dismissal blocking off this, so a second confirm can't interleave a wipe.
    var isDeleting = false
    /// True after a clean wipe, so success is affirmed rather than the screen just looking empty. The
    /// owning screen decides what its success alert's button does (dismiss the sheet, or just clear this).
    var showSuccess = false

    /// Builds the shared confirm dialog (``DeleteAllDataConfirmation``) wired to this flow's state:
    /// on confirm, ``isDeleting`` goes up before the multi-second `FernletStore.deleteAllData` wipe so
    /// the busy overlay covers all of it; on finish it comes down, `onWipeFinished` runs, and the
    /// outcome lands in ``showSuccess`` or ``failure``.
    ///
    /// `onWipeFinished` is a post-wipe hook, called AFTER the wipe completes and before the outcome is
    /// surfaced — ``PrivacyDataSettingsView`` uses it to drop its reference to the exported plaintext
    /// URL, which the wipe has just swept off disk. The timing is load-bearing: nilling it before the
    /// wipe would let a re-presented share sheet hand out a URL mid-deletion.
    func makeConfirmation(
        preferences: StoragePreferences,
        store: FernletStore,
        onWipeFinished: (() -> Void)? = nil
    ) -> DestructiveConfirmation {
        DeleteAllDataConfirmation.make(
            canDeleteHealthSamples: preferences.healthKitMasterEnabled,
            hasICloudDayCopy: preferences.hasICloudDayCopy,
            hasSealedBackup: preferences.hasSealedBackup,
            delete: { includeHealth in
                // Set here (the first thing after the user confirms) so the busy overlay is up for the
                // whole multi-second wipe, disabling the entry point's buttons and swallowing a second tap.
                self.isDeleting = true
                return await store.deleteAllData(includingHealthKitSamples: includeHealth)
            },
            onFinished: { outcome in
                self.isDeleting = false
                onWipeFinished?()
                // Affirm success only on a clean wipe. On failure the screen stays put behind the
                // failure alert so the user can read which store survived and retry — dismissing
                // regardless would hide the failure behind an app that merely looks empty.
                if outcome.isComplete {
                    self.showSuccess = true
                } else {
                    self.failure = outcome
                }
            }
        )
    }
}

extension View {
    /// Applies the two "delete everything" outcome alerts, driven by a screen's ``DeleteEverythingFlow``:
    /// the "Couldn't delete everything" alert naming the surviving stores
    /// (``DeleteAllDataConfirmation/failureMessage(for:)``), and the "Everything deleted" success alert.
    ///
    /// The success button is the one per-screen difference, so it is parameterized: ``SettingsSheet``
    /// passes ("Done", no role, dismiss the sheet) because success ends the visit; the pushed
    /// ``PrivacyDataSettingsView`` passes ("OK", `.cancel`, clear ``DeleteEverythingFlow/showSuccess``)
    /// and stays put.
    @MainActor
    func deleteEverythingAlerts(
        _ flow: DeleteEverythingFlow,
        successButtonTitle: String,
        successButtonRole: ButtonRole?,
        onSuccess: @escaping () -> Void
    ) -> some View {
        let bindable = Bindable(flow)
        return alert(
            "Couldn't delete everything",
            isPresented: bindable.failure.isPresent(),
            presenting: flow.failure
        ) { _ in
            Button("OK", role: .cancel) { flow.failure = nil }
        } message: { outcome in
            Text(DeleteAllDataConfirmation.failureMessage(for: outcome))
        }
        .alert("Everything deleted", isPresented: bindable.showSuccess) {
            Button(successButtonTitle, role: successButtonRole) { onSuccess() }
        } message: {
            Text("Fernlet removed everything it stored on this device.")
        }
    }
}
