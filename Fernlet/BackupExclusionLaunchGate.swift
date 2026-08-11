//
//  BackupExclusionLaunchGate.swift
//  Fernlet
//
//  Security-hardening Phase 6 (Hardening #6): default-on iOS-backup exclusion for the sealed
//  FernletPrivate store + the local JSON day blob, gated on a correct fresh-vs-existing split.
//
//  Fresh installs default to EXCLUDED silently (there is nothing to lose yet, and post-#1 an
//  included FernletPrivate file leaks only plaintext metadata columns). Existing installs get a
//  ONE-TIME honest trade-off prompt instead — the flip must never ride a decode default or a
//  silent migration, because it removes the sealed store's device-backup recovery path.
//

import Foundation
import FernletFoundation

/// Device-local "Fernlet has run on this install before" latch — the dedicated first-run marker
/// behind ``BackupExclusionLaunchGate``'s fresh-vs-existing split.
///
/// A dedicated marker rather than the install-binding-ID heuristic on purpose (Phase-6 owner
/// decision): the `com.fernlet.device-binding` row is minted lazily, so its presence would
/// misclassify some genuinely-fresh installs as "existing" and prompt people who have nothing to
/// lose. This marker is written by the gate at the end of every launch resolution, so from this
/// build onward "has the app run before?" has an exact answer; the one generation it cannot cover
/// — installs that predate the marker — is bridged by the gate's legacy-evidence check
/// (onboarding completed).
///
/// Device-local by construction (`UserDefaults`, never the synced prefs blob or iCloud): "this
/// install has been used" is a fact about THIS device, and riding a synced channel would make a
/// second device inherit "already used/already chose" — the exact misclassification the marker
/// exists to prevent. Same pattern as `OwnPhotoMigrationLatch` (Phase 5). Deliberately NOT
/// cleared by "delete everything": the prefs reset clears `backupExclusionChoiceMade`, so the
/// next launch re-runs the gate — and a wiped-but-reused device should get the honest one-time
/// prompt again, never a silent exclusion flip.
struct FernletPriorUseMarker {
    /// The `UserDefaults` key holding the latch.
    static let defaultsKey = "com.fernlet.launch.priorUseRecorded"

    private let defaults: UserDefaults

    /// Creates a marker over `defaults`; tests inject an isolated suite so they never touch the
    /// device's real first-run state.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Whether a previous launch has already recorded prior use. Absent (never set) reads as
    /// false — which alone does NOT mean "fresh": pre-marker installs also read false, so callers
    /// must OR this with the legacy evidence (see ``BackupExclusionLaunchGate``).
    var hasPriorUse: Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    /// Latches prior use. Called by the gate on every launch resolution — one-way by design.
    func markUsed() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Clears the latch. For tests only; no production path un-records prior use.
    func reset() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }
}

/// The launch-time resolver for the Phase-6 default-on backup exclusion: classifies this install
/// as fresh or existing, applies the excluded default to fresh installs (no prompt), and tells
/// the caller when an existing install needs the one-time honest trade-off prompt.
///
/// Runs once per launch from `FernletApp.readyContent`, after `StoragePreferencesStore` has
/// loaded, and is inert forever once `StoragePreferences.backupExclusionChoiceMade` is true.
/// Fresh-vs-existing is decided by ``FernletPriorUseMarker`` OR'd with the legacy prior-use
/// evidence (`OnboardingDefaults.hasCompletedOnboardingKey`): the marker is exact from this build
/// onward, and the onboarding key covers installs that predate it — a genuinely fresh install has
/// neither at the moment the gate runs (onboarding is still on screen), so it can never be
/// mis-prompted, and an upgrading install always has the onboarding key, so it can never be
/// silently flipped.
///
/// Nothing-silent contract: every path that CHANGES the exclusion value is either the fresh
/// default (nothing recoverable exists yet, audit-logged) or an explicit prompt answer; existing
/// users who already excluded via the toggle just get their choice recorded. The decision table
/// is the pure, test-pinned core (``decision(preferences:priorUse:)``).
///
/// Concurrency: `@MainActor` — it mutates the `@MainActor` `StoragePreferencesStore` and is
/// driven from SwiftUI launch tasks.
@MainActor
struct BackupExclusionLaunchGate {
    /// What the gate should do this launch — the pure classification over (choice made, prior
    /// use, currently excluded), pinned by `BackupExclusionLaunchGateTests`.
    enum Decision: Equatable {
        /// `backupExclusionChoiceMade` is already true: the question is settled, do nothing.
        case alreadyChosen
        /// No prior use: a genuinely fresh install. Adopt `excluded = true` + `choiceMade = true`
        /// silently — there is no sealed data yet, so no recovery path is being traded away.
        case adoptExcludedDefault
        /// Prior use and ALREADY excluded (the user opted in via the toggle before this build):
        /// record `choiceMade = true` without prompting — their decision already exists.
        case recordExistingExclusion
        /// Prior use, no recorded choice, currently included: the one cohort whose recovery
        /// expectations the flip would change. Show the one-time honest trade-off prompt.
        case promptExistingInstall
    }

    private let marker: FernletPriorUseMarker
    private let legacyPriorUseEvidence: () -> Bool

    /// Creates the gate. Both parameters are test seams; `nil` selects production behavior
    /// (the standard-defaults marker, and "onboarding completed" as the legacy evidence).
    init(marker: FernletPriorUseMarker? = nil, legacyPriorUseEvidence: (() -> Bool)? = nil) {
        self.marker = marker ?? FernletPriorUseMarker()
        self.legacyPriorUseEvidence = legacyPriorUseEvidence
            ?? { UserDefaults.standard.bool(forKey: OnboardingDefaults.hasCompletedOnboardingKey) }
    }

    /// The pure decision table — see ``Decision`` for what each case means and why.
    static func decision(preferences: StoragePreferences, priorUse: Bool) -> Decision {
        if preferences.backupExclusionChoiceMade { return .alreadyChosen }
        if !priorUse { return .adoptExcludedDefault }
        return preferences.localBackupExcludedFromiOSBackup ? .recordExistingExclusion : .promptExistingInstall
    }

    /// Resolves the gate for this launch: classifies the install, applies/records the
    /// no-prompt outcomes, latches the prior-use marker, and returns whether the caller must
    /// present the one-time prompt (whose answers go through ``recordPromptChoice``).
    ///
    /// - Parameters:
    ///   - store: The loaded preferences store this launch runs against.
    ///   - applyExclusionNow: Called with the new exclusion value the moment the fresh default is
    ///     adopted, so the sealed store and the local day blob are flagged immediately instead of
    ///     waiting for the next preference-change reload.
    /// - Returns: `true` when the existing-install prompt must be shown; the gate itself never
    ///   presents UI.
    @discardableResult
    func resolveAtLaunch(store: StoragePreferencesStore, applyExclusionNow: (Bool) -> Void = { _ in }) -> Bool {
        let priorUse = marker.hasPriorUse || legacyPriorUseEvidence()
        let decision = Self.decision(preferences: store.preferences, priorUse: priorUse)
        // Latch AFTER classification (the pre-latch value is the input) but unconditionally: from
        // this launch on, "has run before" is exact regardless of which branch ran — including the
        // prompt branch, where the answer may not come until a later launch.
        marker.markUsed()
        switch decision {
        case .alreadyChosen:
            return false
        case .adoptExcludedDefault:
            store.update {
                $0.localBackupExcludedFromiOSBackup = true
                $0.backupExclusionChoiceMade = true
            }
            FernletAuditLog.log("privacy.localBackup.freshInstallDefaultExcluded")
            applyExclusionNow(true)
            return false
        case .recordExistingExclusion:
            store.update { $0.backupExclusionChoiceMade = true }
            return false
        case .promptExistingInstall:
            return true
        }
    }

    /// Records the existing-install prompt's answer: either pick settles the question forever
    /// (`choiceMade = true`), so the prompt can never be shown again.
    ///
    /// - Parameters:
    ///   - excludeFromBackups: `true` excludes the local stores from device backups (and calls
    ///     `applyExclusionNow` so the files are flagged immediately); `false` keeps them included
    ///     and changes nothing but the recorded choice.
    ///   - store: The preferences store to record the answer in.
    ///   - applyExclusionNow: Immediate-application seam, same as ``resolveAtLaunch``'s.
    func recordPromptChoice(excludeFromBackups: Bool, store: StoragePreferencesStore, applyExclusionNow: (Bool) -> Void = { _ in }) {
        if excludeFromBackups {
            FernletAuditLog.log("privacy.localBackup.launchPromptExcludeChosen")
            store.update {
                $0.localBackupExcludedFromiOSBackup = true
                $0.backupExclusionChoiceMade = true
            }
            applyExclusionNow(true)
        } else {
            FernletAuditLog.log("privacy.localBackup.launchPromptKeepChosen")
            store.update { $0.backupExclusionChoiceMade = true }
        }
    }
}
