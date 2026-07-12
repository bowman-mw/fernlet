import ProximityKit
import SwiftUI
import FernletDomainModel

/// The host's "someone wants to join" confirmation for Group Activities (Phase 6). A clone of
/// `MeshAdmissionPromptSheet`: pure presentation, zero manager reference. It shows the first pending
/// join request (with the joiner's transport-VERIFIED fingerprint) + an "N more waiting" pill, and calls
/// the two closures. Swipe-to-dismiss declines all (fail-closed) — wired at the presentation site.
struct ActivityJoinPromptSheet: View {
    let requests: [ProximityActivityManager.PendingActivityJoin]
    let activityTitle: String
    let allow: (ProximityActivityManager.PendingActivityJoin) -> Void
    let decline: (ProximityActivityManager.PendingActivityJoin) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Someone wants to join")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    if let request = requests.first {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("\(Text(request.displayName).bold()) wants to join \(Text(activityTitle).bold())")
                                .font(.fernlet(.body))
                                .foregroundStyle(Color.bark)
                                .fernletWrappingText()

                            Text(request.verifiedFingerprint)
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
                                .accessibilityIdentifier("activity.join.allow")

                                Button("Decline") {
                                    decline(request)
                                }
                                .buttonStyle(ChipButtonStyle(selected: false))
                                .accessibilityIdentifier("activity.join.decline")
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
