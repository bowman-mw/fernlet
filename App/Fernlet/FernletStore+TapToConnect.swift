import FernletConnections
import FernletDomainModel
import Foundation
import ProximityKit

/// The store's half of meeting someone new by tapping phones (World Friends §1): it builds the tap
/// rendezvous on itself as the host, tells the run policy when Home comes to the front or leaves it,
/// and runs the hand-off that commits the matched person's hangout slot without a second tap.
extension FernletStore {

    /// The controller, built once (``tapToConnect``): Fernlet's tap profile, the companion look a
    /// decoy session hides, and the name this person appears as. The controller itself watches Low
    /// Power Mode and reports it through ``tapToConnectInputsChanged()``.
    func makeTapToConnect() -> TapToConnectController {
        let rendezvous = ProximityTapRendezvous(host: self, profile: .tapToConnect(in: proximityNamespace))
        rendezvous.companionLook = { [weak self] in
            guard let self else { return Data() }
            return TapToConnectController.look(of: settings.companionAppearance, decoy: duressSessionActive)
        }
        rendezvous.revealedName = { [weak self] in self?.resolvedProximityDisplayName ?? "" }
        let controller = TapToConnectController(rendezvous: rendezvous)
        controller.onPolicyInputsChanged = { [weak self] in self?.tapToConnectInputsChanged() }
        return controller
    }

    /// Home came to the front, or went behind a panel, sheet, passport or tab (§1.4: the rendezvous
    /// stops within a second of any of those).
    func setHomeFrontmost(_ frontmost: Bool) {
        guard frontmost != homeIsFrontmost else { return }
        homeIsFrontmost = frontmost
        _ = reapplyProximityRunPolicy()
    }

    /// A match or the hand-off's end moved a run-policy input: re-run it, and while a hand-off is
    /// pending, run its check loop.
    func tapToConnectInputsChanged() {
        _ = reapplyProximityRunPolicy()
        guard tapToConnect.isHangoutPending else { return }
        runTapHandOff()
    }

    /// Four times a second for the hand-off window: commit the matched person's slot once its identity
    /// introduction arrives, and end the hand-off once a peer committed or the window ran out.
    func runTapHandOff() {
        tapHandOffTask?.cancel()
        tapHandOffTask = Task { @MainActor [weak self] in
            // R2: bounded by the hand-off window at four checks a second.
            for _ in 0..<Int(TapToConnectController.handOffSeconds * 4) {
                do {
                    try await Task.sleep(for: .milliseconds(250))
                } catch {
                    return   // cancelled: a newer hand-off owns the loop
                }
                guard let self else { return }
                if meshNetworkManager.hasCommittedPeer { break }
                tapToConnect.commitPendingSlot(in: meshNetworkManager)
            }
            self?.tapToConnect.endHandOff()
        }
    }
}
