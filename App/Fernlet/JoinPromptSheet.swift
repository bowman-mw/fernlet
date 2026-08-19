import SwiftUI
import FernletUI
import ProximityKit

/// The shared "someone wants to join" confirmation sheet shown to the gatekeeper of a closed
/// in-person group — the existing members of a mesh session and the host of a Group Activity.
///
/// Pure presentation, zero manager reference: it renders the first pending request (display name +
/// fingerprint for eyeball verification) with an "N more waiting" pill, and forwards Allow/Decline
/// through the closures. The `displayName`/`fingerprint` extractor closures keep it generic over the
/// request payload type without a retroactive protocol conformance, and `accessibilityPrefix`
/// namespaces the button identifiers (`<prefix>.allow`, `<prefix>.decline`, `<prefix>.error`,
/// `<prefix>.error.dismiss`) so each presentation surface keeps its own UI-test hooks.
/// Swipe-to-dismiss declines everything still pending (fail-closed) — wired at the presentation
/// sites: ``DisposableCameraView`` presents it for `MeshNetworkManager.pendingAdmissionRequests`
/// and ``ActivitiesView`` for `ProximityActivityManager.pendingJoinRequests`.
struct JoinPromptSheet<Request>: View {
    let requests: [Request]
    let targetName: String
    let displayName: (Request) -> String
    let fingerprint: (Request) -> String
    let accessibilityPrefix: String
    /// An admit-time error (e.g. "This activity is full.") to show INLINE here. A root-level `.alert`
    /// can't present over this sheet while other requests keep it open, so the host would never see it;
    /// rendering it in the sheet — and clearing it via `dismissError` — is what actually surfaces it.
    /// Presentation sites without an inline error (the mesh admission flow) leave it `nil`.
    var errorMessage: String? = nil
    var dismissError: () -> Void = {}
    let allow: (Request) -> Void
    let decline: (Request) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Text("Someone wants to join")
                        .font(.fernlet(.displayMedium))
                        .foregroundStyle(Color.bark)

                    if let errorMessage {
                        errorBanner(errorMessage)
                    }

                    if let request = requests.first {
                        requestCard(request)
                    }

                    dismissalFooter
                }
                .padding(20)
                .padding(.bottom, 10)
            }
        }
        .background(Color.parchment)
        // One small card doesn't need a full-height sheet — and at half height the host can still
        // see what they were doing while deciding.
        .presentationDetents([.medium])
    }

    /// The way out, said out loud. Swiping this sheet away declines *everything* still pending
    /// (deliberately fail-closed) — which used to happen silently to a host who swiped down to peek
    /// at the camera.
    @ViewBuilder
    private var dismissalFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if requests.count > 1 {
                Button("Decline all") {
                    requests.forEach(decline)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("\(accessibilityPrefix).declineAll")
            }

            Text(requests.count > 1
                 ? "Swiping this away declines everyone waiting."
                 : "Swiping this away declines this request.")
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The inline admit-time error banner, with its own Dismiss (a root-level alert cannot present
    /// over this sheet, so the error has to live inside it).
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.goldenrod)
            Text(message)
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()
            Spacer(minLength: 0)
            Button("Dismiss") { dismissError() }
                .font(.fernlet(.labelSmall))
                .foregroundStyle(Color.slate)
                .accessibilityIdentifier("\(accessibilityPrefix).error.dismiss")
        }
        .padding(14)
        .background(Color.cream, in: RoundedRectangle(cornerRadius: 14))
        .overlay(
            RoundedRectangle(cornerRadius: 14).stroke(Color.goldenrod.opacity(0.35), lineWidth: 1)
        )
        .accessibilityIdentifier("\(accessibilityPrefix).error")
    }

    /// The first pending request: who is asking, their fingerprint for eyeball verification, the
    /// "N more waiting" pill, and Allow/Decline.
    private func requestCard(_ request: Request) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("\(Text(displayName(request)).bold()) wants to join \(Text(targetName).bold())")
                .font(.fernlet(.body))
                .foregroundStyle(Color.bark)
                .fernletWrappingText()

            FingerprintText(fingerprint(request), lineLimit: 2)

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

            // Admitting or refusing someone is the sheet's whole job — 44pt action pills, not the
            // 34pt chips used for picking options.
            AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                Button("Allow") {
                    allow(request)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("\(accessibilityPrefix).allow")

                Button("Decline") {
                    decline(request)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("\(accessibilityPrefix).decline")
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
