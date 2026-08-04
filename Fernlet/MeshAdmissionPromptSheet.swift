import ProximityKit
import SwiftUI
import FernletDomainModel
import FernletUI

/// The in-session "someone wants to join" prompt shown to existing members of a closed mesh.
///
/// Pure presentation, zero manager reference: it renders the first pending
/// `MeshAdmissionRequestPayload` (name + requester fingerprint for eyeball verification) with an
/// "N more waiting" pill, and forwards Allow/Decline through the closures.
/// ``DisposableCameraView`` presents it whenever `MeshNetworkManager.pendingAdmissionRequests` is
/// non-empty and wires swipe-to-dismiss to decline everything still pending (fail-closed).
struct MeshAdmissionPromptSheet: View {
    let requests: [MeshAdmissionRequestPayload]
    let meshName: String
    let allow: (MeshAdmissionRequestPayload) -> Void
    let decline: (MeshAdmissionRequestPayload) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Someone wants to join")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    if let request = requests.first {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("\(Text(request.requesterDisplayName).bold()) wants to join \(Text(meshName).bold())")
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()

                            Text(request.requesterFingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.slate)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)

                            if requests.count > 1 {
                                Text("\(requests.count - 1) more waiting")
                                    .font(.fernlet(.labelSmall))
                                    .foregroundStyle(Color.slate)
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 5)
                                    .background(Color.cream, in: RoundedRectangle(cornerRadius: 10))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 10)
                                            .stroke(Color.bark.opacity(0.10), lineWidth: 1)
                                    )
                            }

                            HStack(spacing: 10) {
                                Button("Allow") {
                                    allow(request)
                                }
                                .buttonStyle(ChipButtonStyle(selected: true))
                                .accessibilityIdentifier("mesh.admission.allow")

                                Button("Decline") {
                                    decline(request)
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .accessibilityIdentifier("mesh.admission.decline")
                            }
                        }
                        .padding(16)
                        .background(Color.cream, in: RoundedRectangle(cornerRadius: 16))
                        .overlay(
                            RoundedRectangle(cornerRadius: 16)
                                .stroke(Color.bark.opacity(0.08), lineWidth: 1)
                        )
                    }
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
    }
}
