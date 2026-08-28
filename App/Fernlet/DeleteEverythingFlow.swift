import SwiftUI
import FernletFoundation
import FernletUI
import HealthKitGateway

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

    /// Builds the shared confirm dialog (``DeleteAllDataConfirmation``) wired to this flow's state.
    ///
    /// Since the 2026-08-21 redesign the shipping entry points present the typed-gate
    /// ``DeleteEverythingSheet`` and call ``runWipe(store:includingHealthSamples:onWipeFinished:)``
    /// instead; this alert-shaped builder remains because `DeleteHealthOfferTests` pins the offer
    /// derivation and dialog copy through it, and because the copy it carries is the reconciled
    /// record the sheet's lists must keep agreeing with.
    ///
    /// On confirm, ``isDeleting`` goes up before the multi-second `FernletStore.deleteAllData` wipe so
    /// the busy overlay covers all of it; on finish it comes down, `onWipeFinished` runs, and the
    /// outcome lands in ``showSuccess`` or ``failure``.
    ///
    /// `onWipeFinished` is a post-wipe hook, called AFTER the wipe completes and before the outcome is
    /// surfaced — ``PrivacyDataSettingsView`` uses it to drop its reference to the exported plaintext
    /// URL, which the wipe has just swept off disk. The timing is load-bearing: nilling it before the
    /// wipe would let a re-presented share sheet hand out a URL mid-deletion.
    ///
    /// `everRequestedWritableHealthCapability` is a TEST SEAM: production passes nil and the answer
    /// comes from the persisted ledger, which the shipping app must consult rather than a fixture.
    func makeConfirmation(
        preferences: StoragePreferences,
        store: FernletStore,
        everRequestedWritableHealthCapability: Bool? = nil,
        onWipeFinished: (() -> Void)? = nil
    ) -> DestructiveConfirmation {
        DeleteAllDataConfirmation.make(
            healthSamples: healthSampleOffer(
                masterEnabled: preferences.healthKitMasterEnabled,
                everRequestedWritableCapability: everRequestedWritableHealthCapability
            ),
            hasICloudDayCopy: preferences.hasICloudDayCopy,
            hasSealedBackup: preferences.hasSealedBackup,
            delete: { includeHealth in
                // Set here (the first thing after the user confirms) so the busy overlay is up for the
                // whole multi-second wipe, disabling the entry point's buttons and swallowing a second tap.
                self.isDeleting = true
                Self.clearDebugDiagnostics(store)
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

    /// Runs the wipe directly, for the typed-gate ``DeleteEverythingSheet`` (2026-08-21 redesign,
    /// artboard 5e) — the sheet renders its own confirm surface, so unlike ``makeConfirmation(preferences:store:everRequestedWritableHealthCapability:onWipeFinished:)``
    /// there is no `DestructiveConfirmation` in the middle. The state contract is identical:
    /// ``isDeleting`` goes up before the multi-second `FernletStore.deleteAllData` wipe (busy
    /// overlay, disabled buttons, blocked dismissal at the entry screen), comes down when it
    /// finishes, `onWipeFinished` runs, and the outcome lands in ``showSuccess`` or ``failure``.
    ///
    /// The caller is responsible for the audit event — the sheet logs the same
    /// `settings.deleteAll.confirmed` / `settings.deleteAll.withHealthSamplesConfirmed` tokens the
    /// alert path's `commitDestructive` logged, so the trail is unchanged.
    func runWipe(
        store: FernletStore,
        includingHealthSamples: Bool,
        onWipeFinished: (() -> Void)? = nil
    ) {
        isDeleting = true
        Self.clearDebugDiagnostics(store)
        Task {
            let outcome = await store.deleteAllData(includingHealthKitSamples: includingHealthSamples)
            self.isDeleting = false
            onWipeFinished?()
            if outcome.isComplete {
                self.showSuccess = true
            } else {
                self.failure = outcome
            }
        }
    }

    /// Drops the DEBUG Phase 3 gate readout's in-memory readings before a wipe starts.
    ///
    /// It persists nothing, so `Docs/PrivacyWipeCoverage.md` owes it no disposition row — but a
    /// "gate discharged" reading left standing over corpora this wipe is about to destroy would be
    /// the same lie a persisted one would be.
    ///
    /// Called from HERE rather than from inside `FernletStore.deleteAllData`, and that placement is
    /// forced: `PersistedSurfaceWipeBoundaryTests` throws on ANY preprocessor conditional inside the
    /// scanned wipe path, because a clear behind a compile-time condition cannot certify a promise
    /// the dialog makes unconditionally. This file is not part of that path.
    ///
    /// It clears through `FernletStore.clearPhase3Evidence()` rather than the session directly,
    /// because the ONE reading that reaches a verdict — the sealed-column keyed witness — lives on
    /// the store, not the session. That is also why the duress engage routes through the same call:
    /// the duress silent wipe reaches `deleteAllData` directly through `installDuressPurgeHook` and
    /// never through this flow, so the `duressSessionActive` didSet is the only clear it gets.
    private static func clearDebugDiagnostics(_ store: FernletStore) {
        #if DEBUG
        store.clearPhase3Evidence()
        #endif
    }

    /// Which Apple Health outcome the dialog offers, from the two signals that outlive each other.
    ///
    /// The master toggle answers "is Fernlet integrated with Health right now"; the persisted
    /// ``HealthCapabilityRequestLedger`` answers "was Fernlet ever prompted for a capability that
    /// WRITES samples", which is the question that decides whether Fernlet-authored samples can exist.
    /// Only the first was consulted before, so the user who turned Health off — the one most likely to
    /// want the samples gone — was the one never offered their deletion. The ledger is read from the
    /// keychain with no service instance and no live authorization, so the toggle-off path works.
    ///
    /// The ledger is only consulted when the toggle is off: with it on the offer is already made, and
    /// a keychain read the answer cannot change is wasted work on a dialog build.
    ///
    /// Internal (not private) so the ``DeleteEverythingSheet`` entry points can build the same
    /// offer the alert path builds — one derivation, two presentations.
    func healthSampleOffer(
        masterEnabled: Bool,
        everRequestedWritableCapability: Bool?
    ) -> DeleteAllDataConfirmation.HealthSampleOffer {
        if masterEnabled { return .integrationOn }
        let everRequested = everRequestedWritableCapability
            ?? HealthCapabilityRequestLedger.hasEverRequestedWritableCapability()
        return everRequested ? .integrationOff : .nothingAuthored
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
