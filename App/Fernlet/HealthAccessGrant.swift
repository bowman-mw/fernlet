import FernletFoundation
import HealthKit
import HealthKitGateway

/// Turning one kind of Apple Health data on IN CONTEXT — the first time a feature needs it — with
/// the same effect Settings › Health's "Give access" has: the kind's Fernlet switch goes on
/// (audited), the system prompt runs, and the capability ledger records the ask.
///
/// Why it exists (2026-09-23): the gateway now refuses every write whose kind's Fernlet switch is
/// off ("with Fernlet's Health switch off, or this kind's switch off, Fernlet writes nothing"). The
/// period sheets used to present the system prompt WITHOUT turning the switch on, so a user who
/// allowed cycle tracking there — never visiting Settings — would have every period log refused
/// by the switch the prompt never flipped. Asking in context now also opens the switch, and puts it
/// back when the prompt came back without a write grant, so Settings never says "Shared" for a kind
/// the user just declined.
///
/// Never turns the MASTER switch on: every caller here asks only while Fernlet's Health is already
/// on (the system prompt is master-gated), and a user who switched Health off is not second-guessed.
/// The first-workout offer, which is allowed to, is `WorkoutHealthAccessOffer`.
@MainActor
enum HealthAccessGrant {
    /// Flips `capability`'s Fernlet switch on, presents the prompt through `authorization`, and
    /// restores the switch's previous value when no write grant came back.
    ///
    /// - Parameters:
    ///   - capability: The kind to ask for. A read-only kind (no share types) cannot report a
    ///     decline — HealthKit hides read status — so its switch stays on, as "Give access" leaves it.
    ///   - source: Audit tag naming the surface that asked.
    ///   - authorization: The surface's view model; its ledger write and snapshot refresh are reused.
    ///   - preferences: The app's single `StoragePreferencesStore` (a second instance would leave the
    ///     observable copy stale and clobber the switch on its next write).
    static func requestInContext(
        _ capability: HealthCapability,
        source: String,
        authorization: HealthKitAuthorizationViewModel,
        preferences: StoragePreferencesStore
    ) async {
        guard preferences.preferences.healthKitMasterEnabled else { return }
        let wasOn = preferences.preferences.healthKitCapabilityEnabled[capability.rawValue] == true
        if !wasOn {
            setSwitch(capability, on: true, source: source, preferences: preferences)
        }
        await authorization.request(capability)
        guard !wasOn, !isWriteGranted(capability, in: authorization.snapshot) else { return }
        setSwitch(capability, on: false, source: source, preferences: preferences)
    }

    /// Whether the prompt left a write grant for `capability`: any of its write types authorized —
    /// or, for a kind that writes nothing, always (there is no decline to detect).
    static func isWriteGranted(_ capability: HealthCapability, in snapshot: AuthorizationSnapshot) -> Bool {
        var identifiers = HealthAuthorizationPresentation.writeTypeIdentifiers(for: capability)
        if capability == .workoutLogging {
            // The presentation list shows the energy/distance types; the workout itself decides.
            identifiers = [HKObjectType.workoutType().identifier]
        }
        guard !identifiers.isEmpty else { return true }
        return identifiers.contains { snapshot.status(for: $0) == .sharingAuthorized }
    }

    /// Writes one capability switch through the app's preferences store, with the same audit event
    /// Settings' cards emit.
    private static func setSwitch(_ capability: HealthCapability, on: Bool, source: String, preferences: StoragePreferencesStore) {
        FernletAuditLog.log(
            on ? "privacy.healthKit.capabilityEnabled" : "privacy.healthKit.capabilityDisabled",
            context: ["capability": capability.rawValue, "source": source]
        )
        preferences.update { $0.healthKitCapabilityEnabled[capability.rawValue] = on }
    }
}
