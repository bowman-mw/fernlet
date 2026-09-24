import Foundation
import FernletFoundation
import HealthKit
import HealthKitGateway

/// How the first-workout Health offer ended.
enum WorkoutHealthAccessOutcome: Equatable {
    /// No sheet was presented: HealthKit would have shown nothing (the user answered before), it
    /// could not say, or Fernlet's Health could not be switched on. Nothing was changed.
    case notOffered
    /// The user allowed workout writing: Fernlet's Health and workout sharing are on.
    case granted
    /// The user declined (or the prompt failed): every switch is back where it was.
    case declined
}

/// The one contextual Apple Health ask for workouts — making onboarding's promise true: "Asked the
/// first time you log a workout…" (`OnboardingPermissionsView`; tracker 09-14 §3.1, owner
/// 2026-09-23: "Those gaps should be addressed"). Until this existed nothing asked: Health could only
/// be enabled from Settings, and a workout log fell through `saveIfAuthorized` silently.
///
/// At the first workout the user logs or starts (`FernletStore.offerWorkoutHealthAccessOnFirstUse`),
/// if Fernlet has never asked about workouts, it asks then — mirroring Settings' "Give access":
/// Fernlet's master Health switch and the workout switch go on (audited), the system sheet runs, the
/// capability ledger records the ask, and a declined sheet puts every switch back.
///
/// The rules, each enforced here rather than by the callers:
/// - **Once.** ``claimFirstUse()`` records the durable "resolved" fact BEFORE anything is shown, so a
///   decline, a dismissal, a failure or a crash mid-prompt is never followed by a second ask.
/// - **Never after an explicit off.** Turning Fernlet's Health off in Settings — or stopping workout
///   sharing — records the same fact (``markResolved()``), so that user is never auto-prompted.
/// - **Never a silent re-enable.** The sheet is only presented when HealthKit says it WOULD show
///   (`.shouldRequest`). When every type was already decided — a user who answered before, including
///   before a "delete everything" — HealthKit would return at once without asking, and this would
///   have switched sharing back on without the user seeing a thing. Such a user is left alone.
/// - **Never blocks or loses the workout.** The caller logs first; the workout reaches Health only
///   through the ordinary gated save, after this resolves, and only if it was granted.
///
/// The durable fact is one `Bool` in the store's device-local sensitive-surface defaults suite (the
/// home of the other device-local consent records, never synced), keyed ``resolvedKey``; "delete
/// everything" clears it (`FernletStore.clearWorkoutHealthOfferResolution`). The ledger and the
/// preferences store are the app's own — the single `StoragePreferencesStore` instance, so the
/// switches the user sees are the switches this flips.
@MainActor
final class WorkoutHealthAccessOffer {
    /// The durable "Fernlet must not auto-ask about workout Health on this install" fact. A FROZEN
    /// persisted token.
    static let resolvedKey = "fernlet.healthkit.workoutAccessOfferResolved"

    /// How long the offer waits, once it knows a sheet would be shown, before presenting it. The
    /// first log usually comes from a sheet's Save — which is dismissing at that moment — and the
    /// system Health sheet should land on a settled screen, after the user has seen their workout
    /// logged, not race the dismissal. `nonisolated` because it is a default argument (the Swift 5
    /// MainActor-default rule: a default is evaluated outside the actor).
    nonisolated static let presentationSettleDelay: Duration = .milliseconds(800)

    private let service: any HealthKitServicing
    private let preferencesStore: StoragePreferencesStore
    private let ledgerKeychainService: String
    private let ledgerDefaults: UserDefaults
    private let markerDefaults: UserDefaults
    private let presentationDelay: Duration

    /// - Parameters:
    ///   - service: The authorization seam — the app's HealthKit gateway.
    ///   - preferencesStore: The app's single preferences store.
    ///   - ledgerKeychainService: Slot of the capability ledger. Test-isolation seam; production
    ///     uses the gateway's own.
    ///   - ledgerDefaults: The ledger's legacy defaults suite. Test-isolation seam.
    ///   - markerDefaults: Where ``resolvedKey`` lives — the store's sensitive-surface suite.
    ///   - presentationDelay: The settle wait before the sheet (``presentationSettleDelay`` in
    ///     production; tests pass `.zero`).
    init(
        service: any HealthKitServicing,
        preferencesStore: StoragePreferencesStore,
        ledgerKeychainService: String = HealthKitAnchorKeychain.service,
        ledgerDefaults: UserDefaults = .standard,
        markerDefaults: UserDefaults,
        presentationDelay: Duration = WorkoutHealthAccessOffer.presentationSettleDelay
    ) {
        self.service = service
        self.preferencesStore = preferencesStore
        self.ledgerKeychainService = ledgerKeychainService
        self.ledgerDefaults = ledgerDefaults
        self.markerDefaults = markerDefaults
        self.presentationDelay = presentationDelay
    }

    /// Whether the one ask has been used up (made, or ruled out by an explicit off in Settings).
    var isResolved: Bool {
        markerDefaults.bool(forKey: Self.resolvedKey)
    }

    /// Takes the one ask if it is still available, recording that it is taken BEFORE anything is
    /// shown. Available only while the device has Health, nothing has resolved it, and Fernlet has
    /// never asked about workouts (the capability ledger has no `workoutLogging`).
    ///
    /// Synchronous on purpose: two logs in the same turn (a batch "log the rest" tap) can never
    /// both claim it.
    ///
    /// - Returns: Whether the caller should now run ``present()``.
    func claimFirstUse() -> Bool {
        guard service.isHealthDataAvailable(), !isResolved else { return false }
        let requested = HealthCapabilityRequestLedger.requestedCapabilities(
            keychainService: ledgerKeychainService,
            legacyDefaults: ledgerDefaults
        )
        guard !requested.contains(.workoutLogging) else {
            // Asked before (Settings' card, or an older build's prompt): resolved for good.
            markResolved()
            return false
        }
        markResolved()
        return true
    }

    /// Runs the ask claimed by ``claimFirstUse()``: only when HealthKit would show the sheet, the
    /// switches go on, the sheet runs, and a decline restores them.
    func present() async -> WorkoutHealthAccessOutcome {
        let status = await service.authorizationRequestStatus(for: .workoutLogging)
        guard status == .shouldRequest else {
            FernletAuditLog.log("healthkit.workoutOffer.notOffered", context: ["requestStatus": "\(status.rawValue)"])
            return .notOffered
        }
        do {
            try await Task.sleep(for: presentationDelay)
        } catch {
            // Cancelled while settling: nothing was shown or changed; the ask stays used up.
            return .notOffered
        }
        let prior = preferencesStore.preferences
        guard await openSwitches(from: prior) else { return .notOffered }
        let outcome: AuthorizationOutcome
        do {
            outcome = try await service.requestAuthorization(for: .workoutLogging)
        } catch {
            FernletAuditLog.log("healthkit.workoutOffer.requestFailed", context: ["errorType": "\(type(of: error))"])
            restoreSwitches(to: prior)
            return .declined
        }
        HealthCapabilityRequestLedger.record(.workoutLogging, keychainService: ledgerKeychainService, legacyDefaults: ledgerDefaults)
        let granted = HealthAccessGrant.isWriteGranted(
            .workoutLogging,
            in: AuthorizationSnapshot(isAvailable: true, writeStatuses: outcome.writeStatuses)
        )
        guard granted else {
            restoreSwitches(to: prior)
            FernletAuditLog.log("healthkit.workoutOffer.declined")
            return .declined
        }
        FernletAuditLog.log("healthkit.workoutOffer.granted")
        return .granted
    }

    /// Records that this install must never auto-ask — ``claimFirstUse()``'s own "taken".
    func markResolved() {
        Self.markResolved(in: markerDefaults)
    }

    /// Records the fact in `defaults` — also the explicit-off path from Settings
    /// (`FernletStore.recordWorkoutHealthOfferResolvedBySettings`), which must hold even before an
    /// offer object is wired. The one writer of ``resolvedKey``.
    static func markResolved(in defaults: UserDefaults) {
        defaults.set(true, forKey: resolvedKey)
    }

    /// Removes the fact from `defaults` — "delete everything", which returns the install to a fresh
    /// start. Static so the wipe reaches the suite even when no offer object is wired.
    static func clearResolution(in defaults: UserDefaults) {
        defaults.removeObject(forKey: resolvedKey)
    }

    /// Switches Fernlet's Health (when it was off) and workout sharing on, audited like Settings'
    /// own switches. The master goes through the gateway's `enableIntegration()` first, exactly as
    /// the Settings master switch does, then the app's store so the switch the user sees moves too.
    ///
    /// - Returns: `false` when the gateway refused to enable (no Health store) — nothing changed.
    private func openSwitches(from prior: StoragePreferences) async -> Bool {
        if !prior.healthKitMasterEnabled {
            do {
                try await service.enableIntegration()
            } catch {
                FernletAuditLog.log("healthkit.workoutOffer.enableFailed", context: ["errorType": "\(type(of: error))"])
                return false
            }
            FernletAuditLog.log("privacy.healthKit.masterEnabled", context: ["source": "workoutFirstUse"])
        }
        FernletAuditLog.log(
            "privacy.healthKit.capabilityEnabled",
            context: ["capability": HealthCapability.workoutLogging.rawValue, "source": "workoutFirstUse"]
        )
        preferencesStore.update { preferences in
            preferences.healthKitMasterEnabled = true
            preferences.healthKitCapabilityEnabled[HealthCapability.workoutLogging.rawValue] = true
        }
        return true
    }

    /// Puts the master and workout switches back to what they were before the ask.
    private func restoreSwitches(to prior: StoragePreferences) {
        let key = HealthCapability.workoutLogging.rawValue
        FernletAuditLog.log("privacy.healthKit.capabilityDisabled", context: ["capability": key, "source": "workoutFirstUse"])
        preferencesStore.update { preferences in
            preferences.healthKitMasterEnabled = prior.healthKitMasterEnabled
            preferences.healthKitCapabilityEnabled[key] = prior.healthKitCapabilityEnabled[key] ?? false
        }
    }
}
