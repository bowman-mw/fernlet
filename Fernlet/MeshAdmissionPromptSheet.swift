import SwiftUI
import FernletDomainModel

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
                        .font(.system(size: 28, weight: .bold, design: .serif))
                        .foregroundStyle(Color.bark)

                    if let request = requests.first {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("\(Text(request.requesterDisplayName).bold()) wants to join \(Text(meshName).bold())")
                                .font(.body)
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()

                            Text(request.requesterFingerprint)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(Color.slate)
                                .lineLimit(2)
                                .minimumScaleFactor(0.75)

                            if requests.count > 1 {
                                Text("\(requests.count - 1) more waiting")
                                    .font(.caption.weight(.medium))
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
