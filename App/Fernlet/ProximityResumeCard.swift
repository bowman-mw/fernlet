// ProximityResumeCard.swift
// Fernlet
//
// Network migration P7 item 5, PASS 2 (plan §24.1, prompt §5c): the SURFACE half of the launch
// restore — the affordance pass 1's decision table was written for.
//
// **Nothing modal.** The launcher's decision is a resume affordance ON THE FRIENDS SURFACE, because
// a modal on launch fires on every cold start and the thing it would interrupt is a person opening
// an app. So this is a card at the top of the Friends tab, above the discovery content, in the
// register `ConnectView.cacheWarningBanner` and `RoutedDeliveryHoldBanner` already established: one
// icon, one headline, one explanatory line, and either two pills or one close control.
//
// **A pure view over ``ProximityResumePresentation`` and two closures.** It reads no manager, holds
// no dismissal state and makes no decision — `ProximityResumeDecision.decide(_:)` answered all of
// that one layer up, from `MeshNetworkManager.sessionResumeProjection`, and there is exactly one
// such call in the app. That is what keeps the `#Preview`s below honest: every shape this card can
// take is reachable by handing it a value, with no mesh, no sealed context and no second device.
//
// **It calls no radio door**, which is P7 item 3's zero wall and is checked by
// `ProximityRunPolicyHostTests` over the whole app target. The resume's ACTION is its `onResume`
// closure's, and the one call site — `ConnectView.resumeLastSession()` — accepts the offer at the
// manager and then hands the radios back to `ProximityRunPolicyHost.pushNow()`, which re-decides
// and lets `armFriendRadios()` resolve the SAME `FriendsDiscoveryEntry` three-way every other entry
// to this surface uses. `ProximityResumeDecisionTests` pins that pairing.
//
// **Nothing is persisted.** The dismissal is the parent's `@State` for one launch — the phase's
// decision is that P7 adds no persisted surface, so no `UserDefaults` key and no
// `Docs/PrivacyWipeCoverage.md` row is owed, exactly as `RoutedDeliveryHoldBanner` records for its
// own dismissal.

import SwiftUI
import FernletUI

// MARK: - ProximityResumeCardIdentifiers

/// The card's frozen accessibility identifiers, in the `friends.*` screen prefix this surface
/// already uses (`friends.deliveryHold`, `friends.discoveryFailure`, `friends.friendShops`).
///
/// **Identifiers, never labels.** These are automation tokens and stay English forever — which is
/// exactly why the accessibility wall exempts `.accessibilityIdentifier` from its
/// spoken-`rawValue` rule and why they live here rather than in ``ProximityResumeCopy``, whose every
/// member must be a `LocalizedStringKey` and is swept for it.
nonisolated enum ProximityResumeCardIdentifiers {

    /// The card itself, whichever shape it took.
    static let card = "friends.resume"

    /// The headline.
    static let title = "friends.resume.title"

    /// The second line.
    static let body = "friends.resume.body"

    /// The accept pill. Present only on the offer.
    static let resume = "friends.resume.accept"

    /// The decline pill (offer) or the close control (the two notices).
    static let dismiss = "friends.resume.dismiss"
}

// MARK: - ProximityResumePresentationToken

/// The frozen token vocabulary a DEBUG launch uses to force one presentation
/// (`FERNLET_MESH_RESUME_PRESENTATION`), and the parser for it.
///
/// It exists so a tier-1b UI test can see every shape of the card without a sealed context, a second
/// device or a six-hour ceiling — the three things that make this surface otherwise unreachable
/// single-device. The parser itself is ordinary code: it reads no environment, so it is safe in
/// release and testable at tier 1, and `MeshMatrixDebugOptions` — the app's one walled `FERNLET_MESH`
/// family — is the only thing that hands it a launch variable.
///
/// The tokens are the presentation's own case names, with `ended` taking a reason: `nothing`,
/// `offerResume`, `couldNotReopen`, and `ended:<reason>` where `<reason>` is one of
/// ``ProximityMeshEndedReason``'s eight at-rest `rawValue`s.
nonisolated enum ProximityResumePresentationToken {

    /// The prefix that marks an ended presentation and separates it from its reason.
    static let endedPrefix = "ended:"

    /// Parses one launch token.
    ///
    /// - Parameter token: The variable's value, or nil when the launch did not set it.
    /// - Returns: the presentation to force, or nil for "no override" — which is also the answer for
    ///   a token nobody recognises, because a mistyped variable must leave the shipping decision in
    ///   place rather than silently pick a shape.
    static func presentation(_ token: String?) -> ProximityResumePresentation? {
        guard let token, !token.isEmpty else { return nil }
        if token.hasPrefix(endedPrefix) {
            let reason = String(token.dropFirst(endedPrefix.count))
            return ProximityMeshEndedReason(rawValue: reason).map { ProximityResumePresentation.ended($0) }
        }
        switch token {
        case "nothing": return .nothing
        case "offerResume": return .offerResume
        case "couldNotReopen": return .couldNotReopen
        default: return nil
        }
    }
}

// MARK: - ProximityResumeCard

/// The Friends-tab card for whatever the launch restore concluded.
///
/// Three shapes and one silence:
///
/// | presentation | shape |
/// | --- | --- |
/// | ``ProximityResumePresentation/nothing`` | `EmptyView` — no frame, no element, nothing announced |
/// | ``ProximityResumePresentation/offerResume`` | headline, second line, and two pills |
/// | ``ProximityResumePresentation/couldNotReopen`` | a notice with a close control |
/// | ``ProximityResumePresentation/ended(_:)`` | the same notice, with the reason as its second line |
///
/// The two notices are tinted `goldenrod` like every other "something you should know" card on this
/// surface; the offer is tinted `moss`, because it is an invitation and the shop-window card is the
/// precedent for that tint here.
///
/// **No `.accessibilityElement(children: .combine)`**, for the reason `RoutedDeliveryHoldBanner`
/// records: every shape of this card contains a `Button`, and combining would strip its `.isButton`
/// trait, its direct VoiceOver focus and its label. The headline and the second line carry
/// identifiers of their own instead, which is what the UI suite anchors on.
struct ProximityResumeCard: View {

    /// What `ProximityResumeDecision.decide(_:)` answered for this launch.
    let presentation: ProximityResumePresentation

    /// Accept the offer. Called only from the offer's primary pill.
    let onResume: () -> Void

    /// Decline the offer, or put one of the two notices away for this launch.
    let onDismiss: () -> Void

    var body: some View {
        switch presentation {
        case .nothing:
            EmptyView()
        case .offerResume:
            offerCard
        case .couldNotReopen, .ended:
            noticeCard
        }
    }

    // MARK: - The offer

    /// "Pick up where you left off?" — the one presentation with an action behind it.
    private var offerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.clockwise.circle")
                    .foregroundStyle(Color.moss)
                sentences
                Spacer(minLength: 4)
            }
            HStack(spacing: 10) {
                Button(ProximityResumeCopy.resumeButton, action: onResume)
                    .buttonStyle(ActionPillButtonStyle(.primary))
                    .accessibilityIdentifier(ProximityResumeCardIdentifiers.resume)
                Button(ProximityResumeCopy.notNowButton, action: onDismiss)
                    .buttonStyle(ActionPillButtonStyle(.secondary))
                    .accessibilityIdentifier(ProximityResumeCardIdentifiers.dismiss)
                Spacer(minLength: 0)
            }
        }
        .modifier(ProximityResumeCardChrome(tint: Color.moss.opacity(0.25)))
    }

    // MARK: - The two notices

    /// A corrupt file or an ended mesh: something to read, and nothing to do about it.
    private var noticeCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(Color.goldenrod)
            sentences
            Spacer(minLength: 4)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Color.slate)
            }
            .buttonStyle(.plain)
            .fernletIconButton(ProximityResumeCopy.dismissNoticeLabel)
            .accessibilityIdentifier(ProximityResumeCardIdentifiers.dismiss)
        }
        .modifier(ProximityResumeCardChrome(tint: Color.goldenrod.opacity(0.35)))
    }

    // MARK: - The sentences

    /// The headline and the second line, from ``ProximityResumeCopy`` and from nowhere else.
    ///
    /// Both are optional at the copy fork, and both are nil for exactly one presentation —
    /// ``ProximityResumePresentation/nothing``, which `body` renders as an `EmptyView` before ever
    /// reaching here. The `if let`s are the honest spelling of that rather than a force-unwrap.
    private var sentences: some View {
        VStack(alignment: .leading, spacing: 3) {
            if let title = ProximityResumeCopy.title(presentation) {
                Text(title)
                    .font(.fernlet(.headerMedium))
                    .foregroundStyle(Color.bark)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(ProximityResumeCardIdentifiers.title)
            }
            if let detail = ProximityResumeCopy.body(presentation) {
                Text(detail)
                    .font(.fernlet(.bodySmall))
                    .foregroundStyle(Color.slate)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(ProximityResumeCardIdentifiers.body)
            }
        }
    }
}

// MARK: - ProximityResumeCardChrome

/// The card's shared frame: `ConnectView.cacheWarningBanner`'s padding, fill and corner, with the
/// hairline tinted per shape.
///
/// A `ViewModifier` rather than a third copy of four modifier lines, and rather than a helper
/// returning `some View` — the two shapes differ in their CONTENT, not their chrome, and a modifier
/// is what lets the offer be a `VStack` and the notice an `HStack` under one frame. It also carries
/// the card's identifier, so the two shapes cannot drift apart on the token the UI suite anchors on.
private struct ProximityResumeCardChrome: ViewModifier {

    /// The hairline colour, already at its opacity: `moss` for the offer, `goldenrod` for a notice.
    let tint: Color

    func body(content: Content) -> some View {
        content
            .padding(14)
            .background(Color.cream, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(tint, lineWidth: 1))
            // `.contain`, never `.combine` or `.ignore`. The card is a GROUP: `.contain` makes it a
            // real element the identifier can land on — so the UI suite can ask whether the card is
            // there at all — while every child keeps its own element, its own label and, for the
            // buttons, its `.isButton` trait and its direct VoiceOver focus. `.combine` would
            // flatten the two pills into the card's own announcement and `.ignore` would mint a
            // traitless twin beside them (the accessibility wall's A7).
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(ProximityResumeCardIdentifiers.card)
    }
}

// MARK: - Previews

#Preview("Offer") {
    ProximityResumeCard(presentation: .offerResume, onResume: {}, onDismiss: {})
        .padding(20)
        .background(Color.parchment)
}

#Preview("Could not reopen") {
    ProximityResumeCard(presentation: .couldNotReopen, onResume: {}, onDismiss: {})
        .padding(20)
        .background(Color.parchment)
}

#Preview("Ended — you left it") {
    ProximityResumeCard(presentation: .ended(.ownDeparture), onResume: {}, onDismiss: {})
        .padding(20)
        .background(Color.parchment)
}

#Preview("Ended — the six-hour limit") {
    ProximityResumeCard(presentation: .ended(.hardDeadlineSigned), onResume: {}, onDismiss: {})
        .padding(20)
        .background(Color.parchment)
}

#Preview("Nothing") {
    ProximityResumeCard(presentation: .nothing, onResume: {}, onDismiss: {})
        .padding(20)
        .background(Color.parchment)
}
