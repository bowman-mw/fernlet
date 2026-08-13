import Foundation
import Observation
import FernletDomainModel
import FernletFoundation

/// Owns Fernlet's age determination and the two gates that hang off it: intimacy tracking (16+) and
/// live-session mesh chat (13+).
///
/// **Device-local by construction.** The record is written to an injectable `UserDefaults` sidecar and
/// never to the synced settings blob — same reasoning as the sensitive-surface visibility resolution it
/// sits beside. The determination describes the Apple Account signed in on *this* device; syncing it
/// would carry one account's status onto a device signed in as someone else, and would put a minor's
/// status on the wire.
///
/// The store deliberately knows nothing about the `DeclaredAgeRange` framework. It takes primitives
/// (`lowerBound`/`upperBound`/provenance), so every rule in here is reachable from tests without the
/// entitlement, a signed-in Apple Account, or a system prompt. `AgeAssuranceRequest` is the only file
/// that imports the framework.
@MainActor
@Observable
final class AgeAssuranceStore {
    /// The current determination. Reading this inside a SwiftUI `body` is what registers the observation
    /// dependency, so the gate closures handed to `DiaryStore`/`MeshNetworkManager` must read it (rather
    /// than caching a `Bool`) for gated surfaces to re-render when the verdict changes.
    private(set) var record: AgeAssuranceRecord

    @ObservationIgnored private let defaults: UserDefaults

    /// The `UserDefaults` keys for the device-local sidecar record.
    ///
    /// Namespaced here so the persistence key can never drift between the load, save, and clear paths.
    private enum Keys {
        static let record = "ageAssuranceRecord"
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.record = Self.loadRecord(from: defaults)
    }

    // MARK: - The gates

    /// Whether a gated feature is open. Fail-closed for everything the system placed below the line,
    /// and for everything it never ruled on unless the user took the manual confirmation.
    func allows(_ gate: AgeGate) -> Bool { record.allows(gate) }

    /// Whether the manual confirmation may be offered for this gate. False once the system has ruled
    /// either way — a `.below` verdict is final, and a `.meets` verdict makes the offer pointless.
    func mayOfferSelfAttestation(for gate: AgeGate) -> Bool { record.mayOfferSelfAttestation(for: gate) }

    /// Whether the system has ever returned a usable bracket. Drives the UI's choice between offering
    /// "verify your age" and stating a requirement the user does not meet.
    var isDetermined: Bool { record.isDetermined }

    // MARK: - Mutation

    /// Records a bracket returned by the system, plus any guardian communication limits it reported.
    func applyDetermination(
        lowerBound: Int?,
        upperBound: Int?,
        provenance: AgeAssuranceProvenance?,
        hasCommunicationLimits: Bool = false,
        now: Date = .now
    ) {
        update(record.determining(
            lowerBound: lowerBound,
            upperBound: upperBound,
            provenance: provenance,
            hasCommunicationLimits: hasCommunicationLimits,
            now: now
        ))
        // Log the OUTCOME per gate, never the bracket: an audit line carrying "13–16" would put the
        // very fact the gate exists to protect into a log the user can export.
        FernletAuditLog.log("ageAssurance.determined", context: [
            "chat": String(record.allows(.chat)),
            "intimacy": String(record.allows(.intimacy)),
        ])
    }

    /// Records that the system gave us nothing usable — declined, or no age on the account.
    func applyUndetermined(now: Date = .now) {
        update(record.undetermined(now: now))
        FernletAuditLog.log("ageAssurance.undetermined")
    }

    /// Applies the manual confirmation for one gate, behind the caller's warning UI. A no-op when the
    /// system has already ruled, so this cannot reopen a gate the system closed.
    func selfAttest(_ gate: AgeGate) {
        let before = record
        update(record.selfAttesting(gate))
        guard record != before else { return }
        FernletAuditLog.log("ageAssurance.selfAttested", context: ["gate": String(gate.minimumAge)])
    }

    /// Clears the record back to a device that has never asked. Called by the "delete everything"
    /// funnel alongside the other device-local sidecars: the verdict is re-derivable from the Apple
    /// Account, so keeping it would leave a wiped device still carrying a determination about its user.
    func clear() {
        defaults.removeObject(forKey: Keys.record)
        record = .unknown
    }

    // MARK: - Persistence

    private func update(_ updated: AgeAssuranceRecord) {
        guard updated != record else { return }
        record = updated
        guard let data = try? JSONEncoder().encode(updated) else { return }
        defaults.set(data, forKey: Keys.record)
    }

    /// A record that fails to decode is treated as absent, i.e. fully locked. That is the safe
    /// direction: the user re-verifies, where the alternative would be honoring a half-read verdict.
    private static func loadRecord(from defaults: UserDefaults) -> AgeAssuranceRecord {
        guard let data = defaults.data(forKey: Keys.record),
              let decoded = try? JSONDecoder().decode(AgeAssuranceRecord.self, from: data) else {
            return .unknown
        }
        return decoded
    }
}
