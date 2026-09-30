import FernletUI
import ProximityKit
import SwiftUI

// MARK: - RecipeShareConfirmation

/// What the recipe share sheet says about one finished share: a pure mapping from the manager's
/// frozen ``RecipeShareOutcome`` to localized copy.
///
/// ## Honest by construction
///
/// The strongest thing the sender can truthfully know is that the recipe was **sent**: handed to the
/// transport over the private connection. Nothing comes back from the other device (its Import and
/// Decline send nothing), so no sentence here says delivered, received, accepted or saved, and the
/// success copy says outright that no notice will follow. Recipe sharing has no queued or held path,
/// so there is no "will be delivered later" either. `RecipeShareConfirmationTests` resolves every
/// sentence and pins both halves of that.
///
/// The failure copy keeps two facts apart that a single "didn't send" would merge:
/// ``RecipeShareFailure/sendIncomplete`` means the other person **may** have it, and every other
/// cause means nothing left this device.
///
/// Every sentence is a `LocalizedStringResource`, so the catalog sync harvests it, the view renders
/// it with `Text(_:)`, and the announcer's app overload speaks it. The switches are exhaustive, so a
/// new ``RecipeShareFailure`` case is a build error here until it has its own sentence.
struct RecipeShareConfirmation: Equatable, Identifiable {

    /// Which of the two panels this is.
    enum Tone: Equatable {
        /// The recipe was handed to the transport.
        case sent
        /// The recipe did not go out, or did not finish going out.
        case notSent
    }

    /// The outcome's publication id, so the view's haptic and transition key on each confirmation.
    let id: UUID

    /// The picker row the share was for; what "Try again" re-sends to.
    let recipientID: UUID

    /// Success or failure.
    let tone: Tone

    /// The panel's heading: who it went to, or which recipe did not go.
    let headline: LocalizedStringResource

    /// One or two plain sentences saying what happened and what the user can expect.
    let detail: LocalizedStringResource

    /// The sentence VoiceOver speaks when the panel appears.
    let announcement: LocalizedStringResource

    /// Whether the panel offers "Try again" — every failure does, a success does not.
    let offersRetry: Bool

    /// The announcement's kind: a success for `sent`, an error otherwise.
    var announcementKind: FernletAnnouncementKind {
        switch tone {
        case .sent: return .success
        case .notSent: return .error
        }
    }

    /// The confirmation for `outcome`.
    init(_ outcome: RecipeShareOutcome) {
        switch outcome.result {
        case .sent:
            self = Self.sent(outcome)
        case .notSent(let failure):
            self = Self.notSent(outcome, failure: failure)
        }
    }

    /// The memberwise form the two builders below share.
    private init(
        outcome: RecipeShareOutcome,
        tone: Tone,
        headline: LocalizedStringResource,
        detail: LocalizedStringResource,
        announcement: LocalizedStringResource
    ) {
        self.id = outcome.id
        self.recipientID = outcome.recipientID
        self.tone = tone
        self.headline = headline
        self.detail = detail
        self.announcement = announcement
        self.offersRetry = tone == .notSent
    }

    /// The success panel. Says "sent" and nothing stronger (see the type's discussion).
    private static func sent(_ outcome: RecipeShareOutcome) -> RecipeShareConfirmation {
        let name = outcome.recipientName
        let title = outcome.recipeTitle
        return RecipeShareConfirmation(
            outcome: outcome,
            tone: .sent,
            headline: LocalizedStringResource(
                "Sent to \(name)",
                comment: "Recipe share confirmation heading. %@ is the name of the nearby person the recipe was sent to."),
            detail: LocalizedStringResource(
                "Fernlet sent “\(title)” over your private connection. \(name) can look it over and choose whether to save it. You won't get a notice either way.",
                comment: "Recipe share confirmation. The first %@ is the recipe's name, the second is the person's name. The app only knows the recipe left this phone; never say it was received or saved."),
            announcement: LocalizedStringResource(
                "Sent “\(title)” to \(name).",
                comment: "Spoken by VoiceOver when a recipe share finishes. The first %@ is the recipe's name, the second is the person's name.")
        )
    }

    /// A failure panel: a heading naming the recipe and one sentence for the cause.
    private static func notSent(
        _ outcome: RecipeShareOutcome,
        failure: RecipeShareFailure
    ) -> RecipeShareConfirmation {
        let name = outcome.recipientName
        let title = outcome.recipeTitle
        guard !failure.mayHaveReachedRecipient else {
            return RecipeShareConfirmation(
                outcome: outcome,
                tone: .notSent,
                headline: LocalizedStringResource(
                    "Sending didn't finish",
                    comment: "Recipe share heading when the connection dropped partway through sending, so the other person may or may not have the recipe."),
                detail: detail(for: failure, outcome: outcome),
                announcement: LocalizedStringResource(
                    "Sending “\(title)” to \(name) didn't finish.",
                    comment: "Spoken by VoiceOver when a recipe share was cut off partway. The first %@ is the recipe's name, the second is the person's name.")
            )
        }
        return RecipeShareConfirmation(
            outcome: outcome,
            tone: .notSent,
            headline: LocalizedStringResource(
                "“\(title)” wasn't sent",
                comment: "Recipe share heading when nothing was sent. %@ is the recipe's name."),
            detail: detail(for: failure, outcome: outcome),
            announcement: LocalizedStringResource(
                "“\(title)” wasn't sent to \(name).",
                comment: "Spoken by VoiceOver when a recipe share did not go out. The first %@ is the recipe's name, the second is the person's name.")
        )
    }

    /// The one sentence that says why, per cause. Exhaustive on purpose.
    private static func detail(
        for failure: RecipeShareFailure,
        outcome: RecipeShareOutcome
    ) -> LocalizedStringResource {
        let name = outcome.recipientName
        switch failure {
        case .pairedWithAnother:
            return pairedWithAnotherDetail(outcome)
        case .connectingToAnother:
            return LocalizedStringResource(
                "Fernlet was still connecting to another Fernlet. Recipe sharing links two Fernlets at a time, so nothing went to \(name).",
                comment: "Why a recipe share did not go out: another connection attempt was already in progress. %@ is the person's name.")
        case .recipientUnavailable:
            return LocalizedStringResource(
                "\(name) isn't nearby anymore, so nothing was sent.",
                comment: "Why a recipe share did not go out: the other phone disappeared from the nearby list. %@ is the person's name.")
        case .noAnswer:
            return LocalizedStringResource(
                "\(name) didn't answer. Their Fernlet may be closed, locked, or busy sharing with someone else. Nothing was sent.",
                comment: "Why a recipe share did not go out: the other phone never answered. %@ is the person's name.")
        case .couldNotConnect:
            return LocalizedStringResource(
                "Fernlet couldn't set up a secure connection with \(name), so nothing was sent.",
                comment: "Why a recipe share did not go out: the secure connection could not be completed. %@ is the person's name.")
        case .interrupted:
            return LocalizedStringResource(
                "The share stopped before anything went out, so nothing was sent to \(name).",
                comment: "Why a recipe share did not go out: sharing was stopped (for example the app was locked or left) before sending began. %@ is the person's name.")
        case .sendIncomplete:
            return LocalizedStringResource(
                "The connection to \(name) dropped while sending, so they may not have it. You can try again.",
                comment: "Why a recipe share may not have arrived: the connection dropped partway through sending. %@ is the person's name.")
        }
    }

    /// The cap refusal's sentence, naming the Fernlet that holds the link when it is known.
    private static func pairedWithAnotherDetail(_ outcome: RecipeShareOutcome) -> LocalizedStringResource {
        let name = outcome.recipientName
        guard let other = outcome.otherPeerName, !other.isEmpty else {
            return LocalizedStringResource(
                "Fernlet is still connected to another Fernlet. Recipe sharing links two Fernlets at a time, so nothing went to \(name).",
                comment: "Why a recipe share did not go out: this phone is already connected to someone else. %@ is the name of the person the user tried to share with.")
        }
        return LocalizedStringResource(
            "Fernlet is still connected to \(other). Recipe sharing links two Fernlets at a time, so nothing went to \(name).",
            comment: "Why a recipe share did not go out: this phone is already connected to someone else. The first %@ is who it is connected to, the second is who the user tried to share with.")
    }
}

// MARK: - RecipeShareOutcomeLatch

/// Which share outcome the sheet is waiting for, and the confirmation it latched: the rule that
/// decides whether a published ``RecipeShareOutcome`` becomes a panel at all.
///
/// The manager publishes an outcome for EVERY share that ends, including the `interrupted` a sheet's
/// own teardown causes when it stops the radio on the way out. So the sheet must never derive its
/// confirmation from the manager's state directly. It latches an outcome only when it began that
/// share (``beganShare(to:)``, keyed by the tapped row), only once, and only for the row it began it
/// for. A cancelled share (Done, or a swipe down) resets the latch before the radio stops, so its
/// outcome is ignored and nothing pops up for it.
///
/// Pure value, no view, no clock, so every rule is a unit-test cell.
struct RecipeShareOutcomeLatch: Equatable {

    /// The row a share was begun for and whose outcome has not arrived yet.
    private(set) var awaitingRecipientID: UUID?

    /// The confirmation on screen, if any.
    private(set) var confirmation: RecipeShareConfirmation?

    /// The user tapped a row: wait for that share's outcome, clearing any panel.
    mutating func beganShare(to recipientID: UUID) {
        awaitingRecipientID = recipientID
        confirmation = nil
    }

    /// Latches `outcome` if it is the one being waited for, returning the new confirmation; nil
    /// (and no change) for an outcome nobody began here, for a different row, or after one latched.
    mutating func receive(_ outcome: RecipeShareOutcome) -> RecipeShareConfirmation? {
        guard confirmation == nil,
              let awaited = awaitingRecipientID,
              awaited == outcome.recipientID else { return nil }
        let made = RecipeShareConfirmation(outcome)
        awaitingRecipientID = nil
        confirmation = made
        return made
    }

    /// "Try again": clears a failure panel and returns the row to re-send to. Nil, with no change,
    /// when there is no panel or it offers no retry.
    mutating func retry() -> UUID? {
        guard let shown = confirmation, shown.offersRetry else { return nil }
        confirmation = nil
        awaitingRecipientID = nil
        return shown.recipientID
    }

    /// Forgets everything: the sheet appeared, or is going away.
    mutating func reset() {
        awaitingRecipientID = nil
        confirmation = nil
    }
}

// MARK: - RecipeShareConfirmationPanel

/// The panel the share sheet cross-fades to when a share ends: a decorative glyph, the heading,
/// what happened, and the actions (Done; "Try again" first on a failure).
///
/// Everything wraps and scrolls, so the panel reads at every Dynamic Type size up to AX5; the pills
/// are ``ActionPillButtonStyle``'s 44pt-tall targets. The glyph is hidden from VoiceOver (the heading
/// already says it) and the heading carries the header trait. The container keeps its children
/// (`.contain` BEFORE the identifier, since a container identifier otherwise overrides theirs).
struct RecipeShareConfirmationPanel: View {
    let confirmation: RecipeShareConfirmation
    let onDone: () -> Void
    let onRetry: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                FernletCard {
                    VStack(alignment: .leading, spacing: 12) {
                        Image(systemName: confirmation.tone == .sent
                              ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.largeTitle.weight(.semibold))
                            .foregroundStyle(confirmation.tone == .sent ? Color.moss : Color.terracottaInk)
                            .accessibilityHidden(true)
                        Text(confirmation.headline)
                            .font(.fernlet(.header))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                            .accessibilityAddTraits(.isHeader)
                        Text(confirmation.detail)
                            .font(.fernlet(.body))
                            .foregroundStyle(Color.bark)
                            .fernletWrappingText()
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                actions
            }
            .padding(20)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("recipeShare.outcome")
    }

    /// Done alone after a success; "Try again" then Done after a failure. Full width and stacked,
    /// so each label wraps rather than truncating at large text sizes.
    @ViewBuilder
    private var actions: some View {
        VStack(spacing: 10) {
            if confirmation.offersRetry {
                Button(action: onRetry) {
                    Text("Try again").frame(maxWidth: .infinity)
                }
                .buttonStyle(ActionPillButtonStyle(.primary))
                .accessibilityIdentifier("recipeShare.outcome.retry")
            }
            Button(action: onDone) {
                Text("Done").frame(maxWidth: .infinity)
            }
            .buttonStyle(ActionPillButtonStyle(confirmation.offersRetry ? .secondary : .primary))
            .accessibilityIdentifier("recipeShare.outcome.done")
        }
    }
}
