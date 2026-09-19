// MeshContinuationCardPresentation.swift
// Fernlet
//
// Network migration P8 item 7 (plan §14, launcher §3 item 7): what a refusal, an expiry and a
// system end PRESENT. The decision is a pure TABLE over item 4's claim — six
// `MeshContinuationState`s × the ten `MeshContinuationAudit` tokens (nine plus "nothing yet") → one
// card or none — and the sentences beside it are `LocalizedStringKey` from the first line.
// `SessionResumeCopy` is the precedent and the shape: one place, so a test can enumerate it (a
// view's private computed property cannot be), and exhaustive `switch`es so a new state, a new
// token or a new ending is a build error here until it has a sentence.
//
// **Why the state alone cannot decide.** `MeshContinuationState.completed` is the terminal after
// ANY session end, whether or not a task ever ran (its own doc says so): the moment the 6-hour
// ceiling raises `sessionEnded`, a refusal that happened ten minutes earlier would lose the only
// thing it had to tell the person. So the card is decided by the claim's state AND the frozen token
// that named its last MOVE — `refused` / `expired` / `cancelled` survive the ending and keep the
// sentence honest, and every other token (and no token at all) shows nothing.
//
// **`absorbed` is not a move.** `FernletStore.meshContinuationLastAudit` holds the token of a row
// that MOVED the claim; item 6 leaves an absorbed row alone. That matters here because the card is
// read in the FOREGROUND and a foreground return is absorbed by a spent claim — a projection that
// recorded absorbed rows would overwrite `cancelled` with `absorbed` on the very edge that brings
// the person to the card. The table is total anyway: handed `absorbed`, it falls back to the state's
// own meaning (`expired` ⇒ "background time ran out") rather than going silent.
//
// **Three sentences, no blame, no dismissal.** A refusal is not an error and an expiry is not a
// failure — iOS grants background time or it does not, and either way the session is still there
// while Fernlet is on screen and nothing that was sealed was lost. The card carries no dismiss
// button: it says what is true of the session running right now, and it goes when the claim does.
//
// **Once the session itself is over, the tense folds.** `completed` is item 4's terminal after ANY
// session end, so a card shown for it is about a session that no longer exists: "this session keeps
// going while Fernlet is open" would be false in exactly the window the person reads it. The ending
// keeps its own TITLE — that is the news the token carried through the ending — and the message
// folds to one shared past-tense sentence for all three. `ConnectView`'s slot yields to P7's resume
// card in that window whenever there is one (``slotDecision(continuation:resume:)``): a session the
// person can pick back up is the more useful truth than one that has ended.
//
// **Two obligations this file states for item 6's driver**, because item 6 is the only thing that
// will ever write the projection and neither rule is visible from where it writes. It must not
// record `MeshContinuationAudit.cancelled` for a delivery the app itself could not serve — an
// ownerless task ends back at `.idle` with no card, because there is no session to explain — and it
// resets the projection (`meshContinuationState` to `.idle`, `meshContinuationLastAudit` to nil) on
// the proximity hard stop (delete-all, leg 7b) as well as on a new mesh start, so a card never
// outlives the claim that earned it. The third, ``projectedAudit(previous:outcome:)``, is code here
// rather than prose anywhere.
//
// **Tokens vs sentences.** `MeshContinuationCardKind`'s `rawValue` is frozen English three times
// over — it is the accessibility identifier's suffix (the UI suite matches on it), the DEBUG launch
// hook's vocabulary (`FERNLET_MESH_CONTINUATION=refused|expired|endedBySystem`), and a test pin.
// The three titles and the three messages (one per refusal, one shared by the two foreground-return
// endings, one shared by all three once the session has ended) are display text and localize; the
// app bundle IS `Bundle.main`, so bare `LocalizedStringKey` literals are correct here and the
// catalog sync harvests them (`SessionResumeCopy`'s rule). Six keys, owed to the close-out's sync.

import SwiftUI

// MARK: - MeshContinuationCardKind

/// Which of the three endings a continuation card names.
///
/// The `rawValue` is a frozen English token, never display text: it is the suffix of
/// ``accessibilityIdentifier``, the vocabulary of the DEBUG launch hook
/// (`FERNLET_MESH_CONTINUATION`), and what tests pin.
nonisolated enum MeshContinuationCardKind: String, Equatable, Sendable, CaseIterable {

    /// iOS refused the request, or ended it before it ever ran: the session lives on the screen.
    case refused

    /// A delivered task ran out of the background time it was given.
    case expired

    /// iOS cancelled a delivered task before its time was up.
    case endedBySystem

    /// The card's accessibility identifier — a frozen token the UI suite matches on.
    var accessibilityIdentifier: String { "friends.meshContinuation.\(rawValue)" }

    /// The claim state that presents this card — the table's inverse.
    ///
    /// Used by the DEBUG launch hook (there is no other way to reach a refusal on a Simulator,
    /// where `BGTaskScheduler` refuses with error 1) and by the round-trip test, so the hook can
    /// never ask for a cell ``MeshContinuationCardPresentation`` does not present.
    var presentingState: MeshContinuationState {
        switch self {
        case .refused: return .refused
        case .expired, .endedBySystem: return .expired
        }
    }

    /// The audit token that presents this card, beside ``presentingState``.
    var presentingAudit: MeshContinuationAudit {
        switch self {
        case .refused: return .refused
        case .expired: return .expired
        case .endedBySystem: return .cancelled
        }
    }
}

// MARK: - MeshContinuationCard

/// One card's worth of copy for a continuation ending.
nonisolated struct MeshContinuationCard: Equatable {

    /// Which ending this card names.
    let kind: MeshContinuationCardKind

    /// The card's headline.
    let title: LocalizedStringKey

    /// The card's one explanatory sentence.
    let message: LocalizedStringKey

    /// The SF Symbol beside it. A name, never display text.
    let symbolName: String

    /// Whether the session this ending happened in has itself ended.
    ///
    /// True only for a `completed` claim, which is where ``message`` is the past-tense fold rather
    /// than the ending's own live sentence. ``MeshContinuationCardPresentation/slotDecision(continuation:resume:)``
    /// reads it to decide whether P7's resume card is the better thing to show.
    let sessionHasEnded: Bool

    /// The frozen identifier the Friends surface hangs on the card.
    var accessibilityIdentifier: String { kind.accessibilityIdentifier }
}

// MARK: - MeshContinuationSlotDecision

/// Which card the Friends tab's one banner slot shows when P7's resume card and P8's continuation
/// card both have something to say.
///
/// A value rather than an `if` chain in the view, so the precedence is a table a test can read:
/// ``MeshContinuationCardPresentation/slotDecision(continuation:resume:)`` is its whole definition.
nonisolated enum MeshContinuationSlotDecision: Equatable, Sendable, CaseIterable {

    /// P8's continuation card — the session running right now was refused background time, or had
    /// the time it was given ended.
    case continuation

    /// P7's launch-restore card — there is a previous session to say something about, and no live
    /// claim that outranks it.
    case resume

    /// Neither has anything to say.
    case nothing
}

// MARK: - MeshContinuationCardPresentation

/// The Friends card for a background-continuation claim: a pure table over the claim's state and
/// the token that named its last move.
nonisolated enum MeshContinuationCardPresentation {

    /// The card for a claim, or nil when there is nothing to say.
    ///
    /// - Parameters:
    ///   - state: Where the claim stands (`FernletStore.meshContinuationState`).
    ///   - lastAudit: The frozen token that named the claim's last MOVE, or nil before any
    ///     (`FernletStore.meshContinuationLastAudit`). Never `absorbed` in practice; handled
    ///     anyway, as "no information".
    /// - Returns: The card, or nil for a claim that is idle, asked for, or running happily — and
    ///   for a session that simply ended.
    static func card(
        state: MeshContinuationState,
        lastAudit: MeshContinuationAudit?
    ) -> MeshContinuationCard? {
        guard let kind = kind(state: state, lastAudit: lastAudit) else { return nil }
        // `completed` is the terminal after any session end: the ending still has a title, but every
        // present-tense sentence about "this session" is false there.
        return card(for: kind, sessionHasEnded: state == .completed)
    }

    /// The token the projection KEEPS after a move — the driver's obligation, spelled here rather
    /// than left to item 6 to rediscover.
    ///
    /// Item 6's driver assigns `meshContinuationLastAudit` through this, never through
    /// `outcome.audit`. An ending (`refused` / `expired` / `cancelled`) must survive the claim's own
    /// `sessionEnded`, whose row carries the token `completed` — recording that blindly erases a
    /// refusal the person was never shown, which is the exact erasure the card's second input exists
    /// to prevent. An `absorbed` row moved nothing and so records nothing.
    ///
    /// - Parameters:
    ///   - previous: The token the projection carries now, or nil before any move.
    ///   - outcome: The row ``MeshContinuationCoordinator/transition(from:on:)`` just took.
    /// - Returns: `previous` for an absorbed row and for the move INTO `completed`; the row's own
    ///   token for every other move.
    static func projectedAudit(
        previous: MeshContinuationAudit?,
        outcome: MeshContinuationOutcome
    ) -> MeshContinuationAudit? {
        switch outcome.audit {
        case .absorbed:
            return previous
        case .completed where outcome.next == .completed:
            return previous
        case .registered, .submitted, .started, .refused, .expired, .cancelled, .completed,
             .meshChanged:
            return outcome.audit
        }
    }

    /// Which card owns the Friends tab's one banner slot.
    ///
    /// The continuation card describes the session running RIGHT NOW, so a live spent claim
    /// (`refused` / `expired`) outranks P7's card about the last session. Once the claim's own
    /// session has ENDED the ordering inverts: a session the person can pick back up is the useful
    /// truth, and the past-tense continuation card shows only when there is no resume card at all.
    ///
    /// - Parameters:
    ///   - continuation: ``card(state:lastAudit:)``'s answer, or nil.
    ///   - resume: P7's `SessionResumeCopy` card, or nil — including when the person dismissed it
    ///     for this instance.
    /// - Returns: Which arm the surface renders.
    static func slotDecision(
        continuation: MeshContinuationCard?,
        resume: SessionResumeCard?
    ) -> MeshContinuationSlotDecision {
        // Matched as `.none` / `.some` rather than compared to nil: `SessionResumeCard` is
        // MainActor-isolated, and so is its `Equatable` conformance, which this nonisolated value
        // may not use.
        switch (continuation, resume) {
        case (.none, .none):
            return .nothing
        case (.none, .some):
            return .resume
        case (.some(let card), .some) where card.sessionHasEnded:
            return .resume
        case (.some, _):
            return .continuation
        }
    }

    /// Which ending, if any, this claim is at.
    ///
    /// A live or fresh claim says nothing: `idle` never asked, `requested` has not been answered,
    /// and `running` is the case where everything is working. `refused` and `expired` are the two
    /// spent claims, and `completed` — the terminal after any session end — keeps whichever of them
    /// it came from, carried by the token.
    ///
    /// - Parameters:
    ///   - state: The claim's state.
    ///   - lastAudit: The token that named its last move, or nil.
    /// - Returns: The ending to name, or nil for silence.
    static func kind(
        state: MeshContinuationState,
        lastAudit: MeshContinuationAudit?
    ) -> MeshContinuationCardKind? {
        switch state {
        case .idle, .requested, .running:
            return nil
        case .refused:
            // Reached only by a refusal or by a request that expired before it ran; both say the
            // same true thing, so the state decides and the token cannot contradict it.
            return .refused
        case .expired:
            return lastAudit == .cancelled ? .endedBySystem : .expired
        case .completed:
            return spentKind(lastAudit)
        }
    }

    /// The ending a session that has ENDED still owes the person, read off its last move.
    ///
    /// - Parameter audit: The token, or nil.
    /// - Returns: The ending, or nil — a session whose last move was its own ending, a running
    ///   task, a submission, a registration, a mesh change or an absorbed row has nothing to
    ///   explain.
    private static func spentKind(_ audit: MeshContinuationAudit?) -> MeshContinuationCardKind? {
        switch audit {
        case .refused: return .refused
        case .expired: return .expired
        case .cancelled: return .endedBySystem
        case .registered, .submitted, .started, .completed, .meshChanged, .absorbed, nil: return nil
        }
    }

    /// The copy for an ending, in the tense the session it happened in deserves.
    ///
    /// The title is the ending's own either way — it is the news the token carried. The sentence is
    /// the ending's live one while the session is still on screen, and the one shared past-tense
    /// sentence once the session itself is over.
    ///
    /// - Parameters:
    ///   - kind: The ending to name.
    ///   - sessionHasEnded: Whether the session this ending happened in has itself ended — true for
    ///     a `completed` claim, and only there.
    /// - Returns: Its title, sentence and symbol.
    static func card(
        for kind: MeshContinuationCardKind,
        sessionHasEnded: Bool = false
    ) -> MeshContinuationCard {
        let live = liveCard(for: kind)
        guard sessionHasEnded else { return live }
        return MeshContinuationCard(
            kind: kind,
            title: live.title,
            message: Self.sessionHasSinceEnded,
            symbolName: live.symbolName,
            sessionHasEnded: true
        )
    }

    /// The copy for an ending inside the session it happened in — present tense, because that
    /// session is still on the screen the person is reading.
    ///
    /// - Parameter kind: The ending to name.
    /// - Returns: Its title, live sentence and symbol.
    private static func liveCard(for kind: MeshContinuationCardKind) -> MeshContinuationCard {
        switch kind {
        case .refused:
            return MeshContinuationCard(
                kind: kind,
                title: "This session stays on screen",
                message: "iOS didn't give Fernlet time in the background, so this session keeps going while Fernlet is open. Nothing you've kept is affected.",
                symbolName: "iphone",
                sessionHasEnded: false
            )
        case .expired:
            return MeshContinuationCard(
                kind: kind,
                title: "Background time ran out",
                message: Self.continuesOnScreen,
                symbolName: "clock",
                sessionHasEnded: false
            )
        case .endedBySystem:
            return MeshContinuationCard(
                kind: kind,
                title: "iOS ended the background session",
                message: Self.continuesOnScreen,
                symbolName: "moon.zzz",
                sessionHasEnded: false
            )
        }
    }

    /// The sentence both foreground-return endings share, deliberately: an expiry and a system end
    /// differ in what happened and in nothing the person has to do about it, so they are one key.
    private static let continuesOnScreen: LocalizedStringKey =
        "The session is carrying on now that Fernlet is open again. Nothing that was already saved was lost."

    /// The sentence all three endings share once the session they happened in is over: the news is
    /// still which ending it was, and the reassurance is still the only thing the person needs.
    private static let sessionHasSinceEnded: LocalizedStringKey =
        "That session has since ended. Nothing that was already saved was lost."
}
