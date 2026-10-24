import SwiftUI
import UIKit
import FernletDomainModel
import FernletFoundation
import ProximityKit
import FernletConnections
import FernletSocial
import AppServices
import FernletUI
import FernletProximityUI

/// The session's interruptive prompts: the join requests (`b3-join-request`), the session alert (a
/// refused routed share, or the mesh's own notice), the removal-proposal alert, and the "End session?"
/// confirmation.
///
/// They used to hang off the disposable camera alone, which was the Friends tab's whole surface during
/// a session. The World build shows the album there and puts the camera behind a button, so the same
/// modifier now rides every surface a session can be seen from — Home's session button, the Friends
/// panel, the camera — each passing `isActive` only while it is the one on screen, so exactly one
/// presenter asks at a time and none asks from under a cover.
///
/// Applied as one modifier so the ordering of the admission sheet, the mesh-error alert, the removal
/// alert and the end-session confirmation is identical to the inline version it replaced. State stays
/// in the host; this only presents it.
struct SessionPromptsModifier: ViewModifier {
    let manager: MeshNetworkManager
    /// Whether this host is the surface on screen; a host that is not presents nothing.
    var isActive = true
    @Binding var activeRemovalProposal: MeshRemovalProposalPayload?
    @Binding var leaveSessionConfirm: Bool
    /// "End Session" in the confirmation: the host's leave (the camera develops first).
    let onConfirmEnd: () -> Void

    /// The session alert's sentence: a refused routed share forks its frozen cause into localized
    /// copy (P5 review finding 5); the legacy `meshError` `String` renders as it always has.
    private var sessionAlertMessage: Text {
        if let refusal = manager.routedShareRefusal {
            return Text(RoutedShareRefusalCopy.message(refusal))
        }
        return Text(manager.meshError ?? "")
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: Binding(
                get: { isActive && !manager.pendingAdmissionRequests.isEmpty && manager.currentMesh != nil },
                set: { isPresented in
                    if !isPresented {
                        manager.pendingAdmissionRequests.forEach { manager.declineAdmission($0) }
                    }
                }
            )) {
                admissionSheet
            }
            .alert(RoutedShareRefusalCopy.title, isPresented: Binding(
                get: { isActive && (manager.meshError != nil || manager.routedShareRefusal != nil) },
                set: { isPresented in
                    // Dismiss only the notice that was on screen (the refusal shows ahead of a
                    // legacy String), so a rotation notice written behind a refusal is re-presented
                    // rather than swallowed by one tap.
                    guard !isPresented else { return }
                    if manager.routedShareRefusal != nil {
                        manager.clearRoutedShareRefusal()
                    } else {
                        manager.meshError = nil
                    }
                }
            )) {
                Button("OK", role: .cancel) {}
            } message: {
                sessionAlertMessage
            }
            .modifier(SessionRemovalPromptsModifier(
                manager: manager,
                isActive: isActive,
                activeRemovalProposal: $activeRemovalProposal,
                leaveSessionConfirm: $leaveSessionConfirm,
                onConfirmEnd: onConfirmEnd
            ))
    }

    /// The pending join requests for the current mesh.
    @ViewBuilder
    private var admissionSheet: some View {
        if let mesh = manager.currentMesh {
            JoinPromptSheet(
                requests: manager.pendingAdmissionRequests,
                targetName: mesh.name,
                displayName: { PeerNameDisplay.shown($0.requesterDisplayName, fingerprint: $0.requesterFingerprint, in: .fernlet) },
                accessibilityPrefix: "mesh.admission",
                allow: { manager.allowAdmission($0) },
                decline: { manager.declineAdmission($0) }
            )
        }
    }
}

/// The two destructive session prompts: seconding a removal proposal, and ending the session.
struct SessionRemovalPromptsModifier: ViewModifier {
    let manager: MeshNetworkManager
    var isActive = true
    @Binding var activeRemovalProposal: MeshRemovalProposalPayload?
    @Binding var leaveSessionConfirm: Bool
    let onConfirmEnd: () -> Void

    func body(content: Content) -> some View {
        content
            .alert(
                activeRemovalProposal.map {
                    "Remove \(PeerNameDisplay.shown($0.targetDisplayName, fingerprint: $0.targetFingerprint, in: .fernlet))?"
                } ?? "Remove participant?",
                isPresented: Binding(get: { isActive && activeRemovalProposal != nil },
                                     set: { if !$0 { activeRemovalProposal = nil } }),
                presenting: activeRemovalProposal
            ) { proposal in
                if manager.canSecondRemoval(proposal) {
                    Button("Second Removal", role: .destructive) {
                        manager.secondRemoval(proposal)
                        activeRemovalProposal = nil
                    }
                }
                Button("Not Now", role: .cancel) {
                    activeRemovalProposal = nil
                }
            } message: { proposal in
                Text("\(PeerNameDisplay.shown(proposal.proposerDisplayName, fingerprint: proposal.proposerFingerprint, in: .fernlet)) asked to remove \(PeerNameDisplay.shown(proposal.targetDisplayName, fingerprint: proposal.targetFingerprint, in: .fernlet)) from this session. A different participant must second the decision.")
            }
            .alert("End session?", isPresented: $leaveSessionConfirm) {
                Button("End Session", role: .destructive) { onConfirmEnd() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("You will stop sharing with everyone in this session.")
            }
    }
}

/// The next removal proposal a host should ask about: the newest one somebody else made, or nil while
/// one is already up.
enum SessionRemovalQueue {
    /// - Parameters:
    ///   - current: The proposal the host is asking about now, if any.
    ///   - pending: The manager's pending proposals.
    ///   - localFingerprint: This device's fingerprint (its own proposals are never asked back).
    static func next(current: MeshRemovalProposalPayload?, pending: [MeshRemovalProposalPayload],
                     localFingerprint: String) -> MeshRemovalProposalPayload? {
        guard current == nil else { return current }
        return pending.last { $0.proposerFingerprint != localFingerprint }
    }
}
