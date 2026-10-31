import FernletConnections
import FernletDomainModel
import Foundation
import Observation
import ProximityKit

// MARK: - TapToConnectQuestion

/// "Start a hangout with Rae?": who the other phone revealed at the tap (World Friends §1.3, screen 2).
struct TapToConnectQuestion: Equatable {
    /// The name they appear as, sanitized for display; empty when they set none.
    let displayName: String
    /// Their companion's look, or `nil` when it did not decode (drawn as the standard look).
    let appearance: CompanionAppearance?
}

// MARK: - TapToConnectPresentation

/// What Home draws for meeting someone new by tapping phones (§1.2–1.3), read straight off ProximityKit's
/// tap rendezvous (its observable state), so views never hold the radio and nothing is mirrored by hand.
@MainActor
@Observable
final class TapToConnectPresentation {
    @ObservationIgnored private let rendezvous: ProximityTapRendezvous
    /// Counts taps this phone measured, so a view plays the firm haptic once per tap.
    var tapCount = 0
    /// Counts the other person's Not now, so a view can show its gentle line once.
    var declinedThereCount = 0
    /// The person's answer; the controller routes it to the rendezvous.
    @ObservationIgnored var answer: (Bool) -> Void = { _ in }

    init(rendezvous: ProximityTapRendezvous) {
        self.rendezvous = rendezvous
    }

    /// Strength (0 far … 1 touching) of another Fernlet on Home within about 3 m, or `nil`: the rings
    /// and the plate. Never a name, a companion or a direction.
    var closeness: Double? { rendezvous.closeness }
    /// The question, once both phones tapped.
    var question: TapToConnectQuestion? { rendezvous.question.map(TapToConnectController.question(from:)) }
    /// This person said Start hangout and the other has not answered yet.
    var isWaitingForPeer: Bool { rendezvous.isWaitingForPeer }
}

// MARK: - PendingTapHangout

/// A hangout both people said yes to, waiting for the mesh to link the two phones.
struct PendingTapHangout: Equatable {
    /// The other person's long-term signing key, the one key the narrowed doors add.
    let signingPublicKey: Data
    /// Its fingerprint, which the slot this hand-off commits must show.
    let fingerprint: String
    /// When the hand-off gives up.
    let expiresAt: Date
}

// MARK: - TapToConnectController

/// Runs the tap rendezvous for the store and hands a match to the hangout mesh (World Friends §1).
///
/// **Privacy (spec §1.5).** The rendezvous sends nothing identifying until both people say yes; this
/// controller adds the mesh half: ``meshDoorKeys(friends:)`` narrows the mesh's join doors to kept
/// friends plus the people a tap matched this launch, so no other stranger is admitted, sent an
/// identity introduction or a ranging token. The radio starts and stops only through ``apply(_:)``,
/// which the run-policy seams call (`ProximityRunSeams`).
///
/// **The hand-off.** On a match both phones start the hangout search (the run policy's discovery row
/// runs on Home while ``pendingHangout`` is set), the narrowed doors admit the matched key, and
/// ``commitPendingSlot(in:)`` commits the slot whose fingerprint matches — the tap already happened, so
/// nobody taps twice. The pending hand-off ends when a peer commits or after ``handOffSeconds``.
@MainActor
final class TapToConnectController {

    /// How long a matched pair has to link on the mesh.
    static let handOffSeconds: TimeInterval = 60
    /// Cap on the keys and fingerprints remembered from taps this launch (Power of 10 rule 3).
    static let maxRemembered = 32

    /// What Home draws.
    let presentation: TapToConnectPresentation
    /// The hand-off in progress, if any.
    private(set) var pendingHangout: PendingTapHangout?
    /// Fingerprints met by tapping phones this launch: Keep as friends? says so under the name.
    private(set) var metByTappingFingerprints: Set<String> = []
    /// Signing keys matched by a tap this launch, which the mesh's narrowed doors admit.
    private(set) var matchedSigningKeys: Set<Data> = []
    /// Runs when a match or a hand-off ending should re-run the run policy.
    var onPolicyInputsChanged: (() -> Void)?

    private let rendezvous: ProximityTapRendezvous
    private let now: () -> Date

    /// A controller over `rendezvous`, which the store builds on itself as the host.
    init(rendezvous: ProximityTapRendezvous, now: @escaping () -> Date = Date.init) {
        self.rendezvous = rendezvous
        self.now = now
        self.presentation = TapToConnectPresentation(rendezvous: rendezvous)
        presentation.answer = { [weak self] yes in self?.rendezvous.answer(yes) }
        rendezvous.onTap = { [weak self] in self?.presentation.tapCount += 1 }
        rendezvous.onMatched = { [weak self] match in self?.matched(match) }
        rendezvous.onEnded = { [weak self] end in
            if end == .declinedThere { self?.presentation.declinedThereCount += 1 }
        }
    }

    /// Whether the rendezvous radio is up (the seams reconcile a listener that says otherwise).
    var isListening: Bool { rendezvous.isRunning }

    /// Whether a matched pair is still waiting for the mesh to link them, as of now.
    var isHangoutPending: Bool {
        guard let pendingHangout else { return false }
        return pendingHangout.expiresAt > now()
    }

    /// Starts or stops the rendezvous — the run-policy seams' one verb for it.
    func apply(_ state: ProximityRunState) {
        if state.isRunning { rendezvous.start() } else { rendezvous.stop() }
    }

    /// The keys the mesh's join doors admit: kept friends (neither blocked nor removed) and the people a
    /// tap matched this launch. Never `nil`: every stranger outside it is refused.
    func meshDoorKeys(friends: [ProximityTrustedPeerRecord]) -> Set<Data> {
        let kept = friends.filter { $0.blockedAt == nil && $0.revokedAt == nil }.map(\.signingPublicKey)
        return Set(kept.prefix(Self.maxRemembered)).union(matchedSigningKeys)
    }

    /// Commits the slot the pending hand-off is waiting for, once its identity introduction arrived.
    /// Returns whether it committed one.
    @discardableResult
    func commitPendingSlot(in manager: MeshNetworkManager) -> Bool {
        guard let pendingHangout, isHangoutPending else { return false }
        // R2: bounded by the mesh's slot cap.
        for slot in manager.slots {
            guard let identity = NearbyPersonCard.identity(in: slot.coordinator.state),
                  IdentityService.fingerprintsMatch(identity.fingerprint, pendingHangout.fingerprint) else { continue }
            manager.commitManualProximity(slotID: slot.id)
            return true
        }
        return false
    }

    /// Ends the hand-off: the peer committed, or the time ran out.
    func endHandOff() {
        guard pendingHangout != nil else { return }
        pendingHangout = nil
        onPolicyInputsChanged?()
    }

    private func matched(_ match: ProximityTapRendezvousMatch) {
        recordMatch(signingPublicKey: match.signingPublicKey, fingerprint: match.fingerprint)
    }

    /// Both people said yes to `signingPublicKey`'s owner: remember them for the doors and for Keep as
    /// friends?, and open the hand-off window (also the seam a unit test drives a match through).
    func recordMatch(signingPublicKey: Data, fingerprint: String) {
        if matchedSigningKeys.count < Self.maxRemembered { matchedSigningKeys.insert(signingPublicKey) }
        if metByTappingFingerprints.count < Self.maxRemembered { metByTappingFingerprints.insert(fingerprint) }
        pendingHangout = PendingTapHangout(
            signingPublicKey: signingPublicKey, fingerprint: fingerprint,
            expiresAt: now().addingTimeInterval(Self.handOffSeconds)
        )
        onPolicyInputsChanged?()
    }

    /// The question as Home draws it: the name sanitized, the look decoded within its bound.
    static func question(from question: ProximityTapRendezvousQuestion) -> TapToConnectQuestion {
        let name = ProximityDisplayName.sanitized(question.displayName, maxLength: 32)
        let appearance = try? JSONDecoder().decode(CompanionAppearance.self, from: question.look)
        return TapToConnectQuestion(displayName: name, appearance: appearance)
    }

    /// This person's companion look for the reveal: the standard look in a decoy session.
    static func look(of appearance: CompanionAppearance, decoy: Bool) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(decoy ? CompanionAppearance.standard : appearance)
        } catch {
            return Data()
        }
    }
}
