import SwiftUI
import FernletUI
import ProximityKit

/// The shared "someone wants to join" confirmation sheet shown to the gatekeeper of a closed
/// in-person group — the existing members of a mesh session and the host of a Group Activity.
///
/// Pure presentation, zero manager reference: it renders the first pending request (the requester's
/// name) with an "N more waiting" pill, and forwards Allow/Decline through the closures. Callers
/// pass the name through `PeerNameDisplay`, so an identifier filed as a name reads "Someone nearby".
///
/// **No fingerprint, and what that costs (owner decision 2026-09-29).** An identifier string is not
/// part of the in-person experience, so the gatekeeper now decides on the requester's chosen name
/// ALONE. That name is peer-supplied: a stranger can take a kept friend's name, and nothing on this
/// sheet tells the two apart. No verification path is reachable from here either. The QR ceremony
/// (`VerifyQRViews`) is optional, runs only pre-commit from a Friends-tab lobby row, and does not
/// exist in-session, where the mesh prompt is presented. Nor does the request imply a ceremony
/// happened: a mesh admission request is accepted even from a slot this device never committed
/// (`MeshNetworkManager.handleAdmissionRequest`, the deliberate pre-commit exception), and the
/// requester's own commit may have been the plain Connect tap, which is unilateral. A display-only
/// cue for a requester whose verified signing key matches a kept friend is an open owner question,
/// not built. The `displayName` extractor closure keeps the sheet generic over the request payload
/// type without a retroactive protocol conformance, and `accessibilityPrefix`
/// namespaces the button identifiers (`<prefix>.allow`, `<prefix>.decline`, `<prefix>.error`,
/// `<prefix>.error.dismiss`) so each presentation surface keeps its own UI-test hooks.
/// Swipe-to-dismiss declines everything still pending (fail-closed) — wired at the presentation
/// sites: ``DisposableCameraView`` presents it for `MeshNetworkManager.pendingAdmissionRequests`
/// and ``ActivitiesView`` for `ProximityActivityManager.pendingJoinRequests`.
struct JoinPromptSheet<Request>: View {
    let requests: [Request]
    /// What the requester wants to join: the mesh's name, or the activity's title. Nil only from
    /// ``ActivitiesView``, for a request whose activity it can no longer find, and drawn as
    /// "wants to join an activity".
    let targetName: String?
    let displayName: (Request) -> String
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
                        .font(FernletFramedFont.sheetTitle)
                        .foregroundStyle(Color.bark)

                    if let errorMessage {
                        errorBanner(errorMessage)
                    }

                    if let request = requests.first {
                        requestCard(request)
                    }

                    dismissalFooter
                }
                .padding(.horizontal, 18)
                .padding(.top, 8)
                .padding(.bottom, 10)
            }
        }
        // Every sheet is full height on paper with the wooden grabber (b3-join-request; World
        // Review Batch 3). This view is always a sheet's root, so it carries the frame itself.
        .fernletSheet()
    }

    /// The way out, said out loud. Swiping this sheet away declines *everything* still pending
    /// (deliberately fail-closed) — which used to happen silently to a host who swiped down to peek
    /// at the camera.
    @ViewBuilder
    private var dismissalFooter: some View {
        VStack(alignment: .leading, spacing: 12) {
            if requests.count > 1 {
                Button {
                    requests.forEach(decline)
                } label: {
                    Text("Decline all").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.secondary))
                .accessibilityIdentifier("\(accessibilityPrefix).declineAll")
            }

            Text(requests.count > 1
                 ? "Swiping this away declines everyone waiting."
                 : "Swiping this away declines this request.")
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.dim)
                .fernletWrappingText()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The inline admit-time error banner, with its own Dismiss (a root-level alert cannot present
    /// over this sheet, so the error has to live inside it).
    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(message)
                .font(FernletFramedFont.body)
                .foregroundStyle(WorldPalette.bark)
                .fernletWrappingText()
            Spacer(minLength: 0)
            Button("Dismiss") { dismissError() }
                .buttonStyle(ActionPillButtonStyle(.secondary, size: .small))
                .accessibilityIdentifier("\(accessibilityPrefix).error.dismiss")
        }
        .padding(14)
        .background(WorldPalette.warn, in: RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius))
        .overlay(RoundedRectangle(cornerRadius: FernletFramedLook.cardRadius)
            .strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
        .accessibilityIdentifier("\(accessibilityPrefix).error")
    }

    /// "<name> wants to join <target>", both names bold — or, with no target name, the whole
    /// sentence for an activity whose title could not be found. A whole sentence rather than an
    /// English "an activity" spliced in as the target: a translator has to see the article and the
    /// preposition together.
    private func requestLine(_ request: Request) -> Text {
        let requester = Text(displayName(request)).bold()
        guard let targetName else { return Text("\(requester) wants to join an activity") }
        return Text("\(requester) wants to join \(Text(targetName).bold())")
    }

    /// The first pending request (b3-join-request): who is asking, the framed "N more waiting", and
    /// Allow and Decline side by side, in a framed card.
    private func requestCard(_ request: Request) -> some View {
        FernletCard {
            VStack(alignment: .leading, spacing: 14) {
                requestLine(request)
                    .font(FernletFramedFont.rowTitle)
                    .foregroundStyle(WorldPalette.bark)
                    .fernletWrappingText()

                if requests.count > 1 {
                    Text("\(requests.count - 1) more waiting")
                        .font(FernletFramedFont.buttonSmall)
                        .foregroundStyle(WorldPalette.bark)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(WorldPalette.paperLight, in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorldPalette.ink, lineWidth: FernletFramedLook.frameWidth))
                }

                // Admitting or refusing someone is the sheet's whole job — full action buttons, not
                // the chips used for picking options.
                AdaptiveStack(spacing: 10, horizontalAlignment: .leading) {
                    Button { allow(request) } label: { Text("Allow").frame(maxWidth: .infinity) }
                        .buttonStyle(ActionPillButtonStyle(.primary))
                        .accessibilityIdentifier("\(accessibilityPrefix).allow")

                    Button { decline(request) } label: { Text("Decline").frame(maxWidth: .infinity) }
                        .buttonStyle(ActionPillButtonStyle(.secondary))
                        .accessibilityIdentifier("\(accessibilityPrefix).decline")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
