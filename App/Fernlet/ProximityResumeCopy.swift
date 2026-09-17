// ProximityResumeCopy.swift
// Fernlet
//
// Network migration P7 item 5, pass 1: the sentences the launch restore's presentation shows.
// `ProximityResumeDecision` answers a `ProximityResumePresentation`; this file, in the APP target,
// forks it into copy — the app bundle *is* `Bundle.main`, so a bare `LocalizedStringKey` literal is
// the correct form and `Scripts/sync-string-catalogs.sh` harvests it into
// `App/Fernlet/Localizable.xcstrings`.
//
// `SessionHeartStatusCopy` and `RoutedShareRefusalCopy` are the two patterns and this is a third of
// the same shape, for the same two reasons: one place, so it can be TESTED (a view's private
// computed property cannot be), and an exhaustive `switch`, so a new presentation — or a ninth
// `MeshSessionTerminationReason` flowing through `ProximityMeshEndedReason` — is a build error here
// until it has a sentence. Wording is the owner's to change; the shape is not.
//
// **Written as `LocalizedStringKey` from the first line, deliberately.** The phase that had to fork
// `SessionHeartStatusCopy` out of a `String`-composed failure message is one phase old, and that
// hole was invisible to both halves of `LocalizationBoundaryTests`: one half scans
// `String(localized:)` call sites and the other scans SwiftUI display-literal call heads, and a
// bare `String` matches neither. `ProximityResumeDecisionTests` scans this file for `-> String`,
// `: String =` and `String(localized:` and requires none of them.
//
// **The new keys are listed verbatim in the handoff** and the catalog is synced at close-out from
// `HEAD`'s blob (`f4a69f1`'s method) — never from a held working copy, which is why this pass adds
// no `.xcstrings` diff of its own. Pass 1 owed thirteen; pass 2 adds **two** — the offer's decline
// label and the notices' close-control label — for fifteen in all.
//
// Three wording rules the decisions table fixes and this file may not relax:
//
//   * A corrupt file says the previous session could not be reopened AND that nothing sealed was
//     lost. The second half is the load-bearing one: the quarantine sets the bytes aside rather
//     than overwriting them, and every routed item the user shared is still sealed on this device.
//   * An ended mesh is **ENDED, never "failed"**. Nothing failed.
//   * Nothing here promises a reconnection. A restore arms no radio, so the offer's second line
//     says what is true — Fernlet is not looking for anyone until the user says so.

import SwiftUI

/// The copy for a launch restore, one sentence per presentation that speaks.
///
/// Three of the four presentations show a headline and a second line; ``ProximityResumePresentation/nothing``
/// shows neither, and the two `nil`s are the silence the decisions table asks for — a deferred
/// restore retries at the next protected-data rise, and apologising for it on every cold start is
/// the noise the "nothing modal" decision exists to avoid.
enum ProximityResumeCopy {

    /// The resume affordance's button label.
    ///
    /// Its own key rather than a reuse of the headline: the headline is a question
    /// ("Pick up where you left off?") and a button is an instruction, and the two decline
    /// differently in most languages.
    static let resumeButton: LocalizedStringKey = "Resume session"

    /// The offer's decline label (P7 item 5, pass 2).
    ///
    /// **"Not now", never "No" or "Dismiss".** Declining the offer clears
    /// `MeshNetworkManager.offersForegroundResume` for this launch and nothing else — the sealed
    /// context stays on the disk, the restored ledger stays addressable, and a later launch inside
    /// the six-hour ceiling offers again. A label that said "No" would promise a permanence the door
    /// behind it does not have.
    static let notNowButton: LocalizedStringKey = "Not now"

    /// The VoiceOver label for the close control on the two NOTICES (`couldNotReopen`, `ended`).
    ///
    /// Its own key rather than `RoutedDeliveryHoldBanner`'s "Dismiss storage notice": VoiceOver
    /// reads these labels with no card around them, and the Friends surface can show both notices at
    /// once, so two controls called the same thing would be two identical announcements for two
    /// different acts. Names the ACT and not the glyph, which is `fernletIconButton`'s whole rule.
    static let dismissNoticeLabel: LocalizedStringKey = "Dismiss session notice"

    /// The headline for one presentation, or nil when there is nothing to say.
    ///
    /// - Parameter presentation: What ``ProximityResumeDecision/decide(_:)`` answered.
    /// - Returns: a `LocalizedStringKey`, never a `String` — `Text(String)` selects the
    ///   `StringProtocol` overload and renders verbatim in every language.
    static func title(_ presentation: ProximityResumePresentation) -> LocalizedStringKey? {
        switch presentation {
        case .nothing:
            return nil
        case .offerResume:
            return "Pick up where you left off?"
        case .couldNotReopen:
            return "Your last session couldn't be reopened."
        case .ended:
            return "That session has ended."
        }
    }

    /// The second line for one presentation, or nil when there is nothing to say.
    ///
    /// The ended case delegates to ``endedBecause(_:)`` rather than interpolating it into the
    /// headline: a localized fragment interpolated into another key harvests as `%@` and leaves the
    /// fragment with no row of its own, which is the same hole a `String`-typed sentence leaves.
    ///
    /// - Parameter presentation: What ``ProximityResumeDecision/decide(_:)`` answered.
    /// - Returns: a `LocalizedStringKey`, never a `String`.
    static func body(_ presentation: ProximityResumePresentation) -> LocalizedStringKey? {
        switch presentation {
        case .nothing:
            return nil
        case .offerResume:
            return "Fernlet still has your last session. It isn't looking for anyone until you say so."
        case .couldNotReopen:
            return "Nothing you shared was lost — it stays sealed on this device."
        case .ended(let reason):
            return endedBecause(reason)
        }
    }

    /// Why an ended mesh ended, one sentence per reason.
    ///
    /// The two ceiling bounds share a sentence on purpose: `hardDeadlineSigned` and
    /// `hardDeadlineMonotonic` are one fact to the user (the six-hour limit was reached) and differ
    /// only in which guard noticed first — a distinction that belongs in the audit token, not in a
    /// sentence. Every other reason is something the user can tell apart and act on differently,
    /// exactly as `RoutedShareRefusalCopy` pairs `.sealFailed` with `.mintFailed` and separates the
    /// rest.
    ///
    /// - Parameter reason: The frozen reason the rejoin bar carries.
    /// - Returns: a `LocalizedStringKey`, never a `String`.
    static func endedBecause(_ reason: ProximityMeshEndedReason) -> LocalizedStringKey {
        switch reason {
        case .ownDeparture:
            return "You left it."
        case .removedFromRoster:
            return "The group removed you from it."
        case .verifiedTerminationRecord:
            return "It was ended by the group."
        case .finalPairTermination:
            return "You and the last person in it ended it together."
        case .hardDeadlineSigned, .hardDeadlineMonotonic:
            return "It reached its six-hour limit."
        case .epochCounterExhausted:
            return "It ran out of new keys, so it closed."
        case .developed:
            return "You finished it and developed the photos."
        }
    }
}
