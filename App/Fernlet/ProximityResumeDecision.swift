// ProximityResumeDecision.swift
// Fernlet
//
// Network migration P7 item 5 (plan §24.1, prompt §5c): the DECISION half of the resume surface —
// what a launch restore's outcome presents to the user, as a pure value.
//
// PASS 1 built the table. **PASS 2 added the one boundary crossing at the foot of this file**
// (``ProximityResumeInputs/init(projection:)``) and folded `notAttempted` into the silent clause;
// everything else here is pass 1's and unchanged.
//
// P6 item 7 wired `MeshNetworkManager.restoreSessionContextOncePerLaunch(now:)` and left its
// user-facing half hollow: `lastSessionRestoreOutcome`, `offersForegroundResume`,
// `restoredSessionContext` and `rejoinBar` have no app reader at all, which `FernletApp`'s own doc
// comment on `restoreMeshSessionContextIfNeeded(_:)` states in as many words. This file is the
// first half of the answer, and deliberately the half that can be a TABLE: five ordered clauses
// over three enumerable facts, so `ProximityResumeCard` — pass 2's Friends-surface affordance — has
// nothing left to decide and is placement and wiring only.
//
// Three facts it is built against, none of them negotiable here:
//
//   * **A restore ARMS NO RADIO** (invariant 5, and `restoreSessionContextOncePerLaunch`'s own doc
//     comment). Every case below PRESENTS; none of them starts a transport. The affordance's
//     ACTION is the card's, and it goes through `ProximityRunPolicyHost` like every other radio
//     move, because P7 item 3's zero wall leaves `FernletApp.mountRoutedRunPolicy(_:)` as the only
//     app-target body that may name a radio door. `ProximityResumeDecisionTests` scans this file
//     and `ProximityResumeCopy.swift` for `startJoin`, `applyRunState` and `pushNow` and requires
//     zero of each — and pass 2 kept that true: the accept door lives on the MANAGER, its one app
//     call site is `ConnectView.resumeLastSession()`, and the push beside it is the policy's.
//   * **A deferred restore is SILENT, as a positive claim.** It is retried at the next
//     protected-data rise (`retrySessionRestoreIfPending(now:)`, the routed re-entry's job 1,
//     bounded by `MeshSessionRestoreBounds.maxAttempts`), so a sentence about it would be a
//     cold-start apology for something that is about to succeed. Silence is a row of the table
//     with a named test, not an omission.
//   * **A rejoin bar names the mesh ENDED, never "failed".** Nothing failed: a mesh that was left,
//     developed, terminated by the group or that reached its ceiling ended exactly as designed.
//   * **And it speaks only when the user TRIES** (pass 2 fix review, P1-3). The bar is durable and
//     is cleared nowhere, a `terminated` context is never reaped, and an `expired` one is written
//     back as terminated — so a clause written over the bar as a LAUNCH-derived fact said "That
//     session has ended." on every cold start for the rest of the install. The input is the HIT:
//     the reason carried by the last entry `rejoinRefusal(for:)` actually refused this run, at the
//     descriptor door, the admission-grant door or `acceptForegroundResume(now:)`. A `terminated`
//     or `expired` launch is silent until then, which is plan §24.1's own framing — "what a rejoin
//     bar looks like when the user tries anyway".
//
// ## Why the decision is written over an app-side flattening
//
// Measured at pass 1's commit (`841abc8`): **none of the four restore properties, nor any of the
// three types they are made of (`MeshSessionRestoreOutcome`, `MeshSessionRejoinBar`,
// `MeshSessionTerminationReason`), was `public`** — which is the mechanical reason "no app surface
// reads its outcome" was true, not merely an oversight. So the decision is written over the
// app-side flattening below, and pass 1 recorded that pass 2 owed exactly one public projection.
//
// **Pass 2 built it**: `MeshNetworkManager.sessionResumeProjection` answers a
// `MeshSessionResumeProjection` — the outcome kind, the offer flag, and the bar's reason **as a hit
// this run** — and ``ProximityResumeInputs/init(projection:)`` at the foot of this file
// is the one mapping into the vocabulary below. The mapping was not invented there: the test bundle
// can `@testable import ProximityKit`, so `ProximityResumeDecisionTests` had already enumerated
// every real `MeshSessionRestoreOutcome` case — payload variants included — through it and held the
// whole product against the decisions table. Only one of the three types crossed the wall
// (`MeshSessionTerminationReason`, so the reason arrives as a case and not as a `String` to
// re-parse); the outcome is flattened by the projection's own frozen `Outcome` tokens, and
// `MeshSessionRejoinBar` never crosses at all, because a surface has no business holding a mesh id.
//
// `ProximityAppLockState.resolve(_:isDuressSessionActive:)` is the precedent for the flattening
// itself: an app-side `CaseIterable` enum standing in for a payload-carrying package enum, with one
// documented mapping and the payloads dropped because no payload changes the answer.
//
// ## What is deliberately NOT an input
//
// **The restored context's member count.** A count in a sentence needs a hand-authored
// `variations.plural` block in `App/Fernlet/Localizable.xcstrings` — a bare `%lld` in a
// `defaultValue` offers a translator exactly one form, which is the defect
// `LocalizationBoundaryTests.pluralRuledKeys` exists to forbid — and this pass must not touch the
// catalog (it is held by another session and synced at close-out from `HEAD`'s blob). A resume
// affordance is a button, not a census; if the owner later wants "3 people were here", it arrives
// as its own key with its own plural rule, and this file gains one field.
//
// **`hasCommittedPeer`.** It is the launcher's named predicate for "the radio guards and the resume
// ARM", and this is not the arm: what to OFFER is decided by what the restore concluded, and
// whether the device then goes looking for anyone is `ProximityRunPolicy`'s and the Friends
// three-way's. Reading it here would make the offer flicker with every link — a peer appearing or
// going away would change a sentence about a file that was read once at launch — and it would put a
// second opinion about the radios in the one place P7 item 3 spent a whole pass emptying.

import ProximityKit

// MARK: - The restore outcome, flattened

/// What the launch restore concluded, in the eight kinds an app surface can act on.
///
/// The app-side twin of ProximityKit's `MeshSessionRestoreOutcome`, which is internal to that
/// module and carries a `MeshSessionContext` on three of its cases. Neither the context nor the
/// deferral/refusal/corruption payloads change what is presented — only the KIND does — so the
/// flattening loses nothing the user could see, and it buys `CaseIterable`, which is what makes the
/// decision a table over a finite product instead of a spot check.
///
/// One case has no counterpart in the package: ``notAttempted`` is the `nil` outcome — the window
/// before the launch mount runs, and a second mount that `restoreSessionContextOncePerLaunch(now:)`
/// refused and audited. It presents nothing, exactly like a green field.
nonisolated enum ProximityRestoreOutcomeKind: String, CaseIterable, Hashable, Sendable {

    /// No restore has concluded yet: `lastSessionRestoreOutcome` is nil.
    case notAttempted

    /// A live context inside its ceiling (`resumable`). The one kind that raises the offer, via the
    /// state machine's `offerForegroundResume` effect.
    case resumable

    /// A context that already records an ending (`terminated`), whether it ended the mesh for
    /// everyone or took this device out of one that carries on. It raises the durable rejoin bar
    /// and, on its own, presents NOTHING: the reason reaches the user when a door refuses a try.
    case terminated

    /// A live context whose ceiling passed while the process was gone (`expired`). The restore
    /// writes the termination mark, which raises the bar with `hardDeadlineSigned` — and is written
    /// back as `terminated`, which is why a launch derived from the bar never went quiet again.
    case expired

    /// No file at all (`noSession`): genuinely a green field.
    case noSession

    /// The load deferred — a locked device, a transient keychain, an unreadable file
    /// (`retryAfterUnlock`). Retried, never read as emptiness, and never spoken about.
    case deferred

    /// Custody refused (`retryAfterRefusal`). Retried like a deferral, logged apart, and — until
    /// the bounded attempts are spent — presented exactly like one: silence.
    case refused

    /// A file exists and does not decode (`quarantineCorruptFile`). Set aside deliberately, never
    /// overwritten, and the one outcome that owes the user a sentence.
    case corrupt

    /// Whether ProximityKit will try this load again on its own.
    ///
    /// Mirrors `MeshSessionRestoreOutcome.isRetryable`, and the mirror is the point: the two kinds
    /// that answer `true` are the two the module retries at the next protected-data rise, which is
    /// precisely why this surface says nothing about them.
    var isRetryable: Bool {
        switch self {
        case .deferred, .refused:
            return true
        case .notAttempted, .resumable, .terminated, .expired, .noSession, .corrupt:
            return false
        }
    }

    /// Whether this kind says nothing **whatever the offer flag says** — clause 3 of the decisions
    /// table.
    ///
    /// Deliberately NOT ``isRetryable``, and deliberately not defined as it plus one case: the two
    /// answer different questions and only one of them is a mirror. ``isRetryable`` is ProximityKit's
    /// own vocabulary and must keep tracking it; this is the app's rule about SILENCE, and
    /// ``notAttempted`` belongs to it for a reason of its own — a launch whose restore has not
    /// concluded has read nothing, so a `true` offer flag beside it can only be one an earlier idle
    /// lapse left set, and offering to resume off it would be an offer about a file nobody has
    /// opened. Pass 1 left `notAttempted` out of the clause and leaned on the fact that the restore
    /// raises no offer before it runs; that made "not attempted is silent" true by circumstance
    /// rather than by rule, and this is the rule.
    var saysNothingWhateverTheOffer: Bool {
        switch self {
        case .notAttempted, .deferred, .refused:
            return true
        case .resumable, .terminated, .expired, .noSession, .corrupt:
            return false
        }
    }
}

// MARK: - Why a mesh ended

/// Why a mesh this device may never re-enter ended.
///
/// **The same eight cases as ProximityKit's `MeshSessionTerminationReason`, with the same
/// `rawValue`s**, so the mapping pass 2 writes is one-to-one and cannot be argued about —
/// `ProximityMeshEndedReason(rawValue: reason.rawValue)` is the whole of it.
/// `ProximityResumeDecisionTests.theEndedReasonVocabularyIsTheSealedContextsOwn` holds the two
/// lists equal, so a ninth reason added to the sealed context fails a test here and a build in
/// ``ProximityResumeCopy`` until it has a sentence.
///
/// The `rawValue`s are the sealed context's at-rest tokens and are **frozen English**: they are
/// diagnostic vocabulary, never display copy. The sentence a user reads is
/// ``ProximityResumeCopy/endedBecause(_:)``'s and lives nowhere else.
nonisolated enum ProximityMeshEndedReason: String, CaseIterable, Hashable, Sendable {

    /// This device sent its own signed departure record.
    case ownDeparture = "own-departure"

    /// A verified removal record named this device.
    case removedFromRoster = "removed-from-roster"

    /// A peer's `terminated.v1`, verified against the merged roster.
    case verifiedTerminationRecord = "verified-termination"

    /// This device signed the termination as a member of the final pair.
    case finalPairTermination = "final-pair"

    /// The signed absolute deadline was reached.
    case hardDeadlineSigned = "hard-deadline-signed"

    /// The local monotonic guard reached the ceiling first.
    case hardDeadlineMonotonic = "hard-deadline-monotonic"

    /// The epoch counter cap was reached, so no further key can be minted.
    case epochCounterExhausted = "epoch-counter-exhausted"

    /// The user developed the mesh.
    case developed = "developed"
}

// MARK: - The inputs

/// Everything the decision reads, and nothing else: the three facts `MeshNetworkManager` holds once
/// the launch restore has run.
///
/// Each field names its source, so pass 2's projection has one honest shape to expose:
/// `lastSessionRestoreOutcome` (flattened), `offersForegroundResume`, and `lastRejoinBarHit`.
/// `restoredSessionContext` is deliberately absent — see the file header on the member count.
nonisolated struct ProximityResumeInputs: Equatable, Hashable, Sendable {

    /// `MeshNetworkManager.lastSessionRestoreOutcome`, flattened, with nil spelled
    /// ``ProximityRestoreOutcomeKind/notAttempted``.
    let outcome: ProximityRestoreOutcomeKind

    /// `MeshNetworkManager.offersForegroundResume`.
    ///
    /// Not derivable from ``outcome``, and the second raiser is worth naming precisely: the state
    /// machine's other `offerForegroundResume` effect sits on a **local idle stop followed by
    /// `.foregrounded`** (`MeshSessionStateMachine.swift:446`), and **nothing in shipping raises
    /// `.foregrounded`** — the launcher forbids P7 from raising it at all, because doing so asserts
    /// a continued-processing task is running, which is P8's claim. So today this flag has exactly
    /// one live source, the restore's `.resumable` arm; the second raiser is P8's, and when it
    /// arrives this surface already reads it.
    let offersForegroundResume: Bool

    /// `MeshNetworkManager.lastRejoinBarHit`: the reason carried by the last entry the permanent
    /// rejoin bar actually REFUSED this run, or nil while nothing has been refused.
    ///
    /// **A hit, not the standing bar** (pass 2 fix review, P1-3). The bar itself is durable and
    /// cleared nowhere, so reading it at launch re-presented an ended session on every cold start;
    /// the hit is run-scoped, raised at the three doors that enforce the bar against this device
    /// (`rejoinRefusal(for:)`'s callers) and cleared by the next founding or a successful accept.
    ///
    /// The mesh's id is not carried: the user is not shown a UUID, and "which mesh" is answered by
    /// the door that refused.
    let rejoinBarHit: ProximityMeshEndedReason?
}

// MARK: - The presentation

/// What the Friends surface shows for one restore. Nothing modal, and nothing that arms a radio.
///
/// `CaseIterable` by hand because ``ended(_:)`` carries a reason: the list is the three plain cases
/// plus one per ``ProximityMeshEndedReason``, which is what lets
/// ``ProximityResumeCopy`` be swept exhaustively in a test the way `RoutedShareRefusalCopy` and
/// `SessionHeartStatusCopy` are.
nonisolated enum ProximityResumePresentation: Equatable, Hashable, Sendable, CaseIterable {

    /// Say nothing at all. A deferred or refused restore (it retries), a green field, a restore
    /// that has not run, and any restored context that offers nothing.
    case nothing

    /// Offer to pick the last session back up. An OFFER only: the restore armed no radio, and the
    /// action behind the affordance is pass 2's, through `ProximityRunPolicyHost`.
    case offerResume

    /// The previous session could not be reopened, and nothing sealed was lost.
    case couldNotReopen

    /// That mesh has ended, and why. **Ended, never "failed"** — every reason here is a designed
    /// ending, and three of them are something the user or the group chose.
    case ended(ProximityMeshEndedReason)

    /// Every presentation, for an exhaustive copy sweep.
    ///
    /// Computed rather than stored: a stored `static var` is a mutable global (Power of 10 rule 6),
    /// and the list is a two-line derivation of ``ProximityMeshEndedReason/allCases`` anyway, so a
    /// new reason joins it without anybody remembering to.
    static var allCases: [ProximityResumePresentation] {
        let plain: [ProximityResumePresentation] = [.nothing, .offerResume, .couldNotReopen]
        return plain + ProximityMeshEndedReason.allCases.map { ProximityResumePresentation.ended($0) }
    }
}

// MARK: - The decision

/// The launch restore's presentation, as a pure function of what the manager holds afterwards.
///
/// ## The decision table
///
/// Applied in this order, and the order is the decision:
///
/// | # | clause | presentation |
/// | --- | --- | --- |
/// | 1 | a rejoin bar was HIT this run | ``ProximityResumePresentation/ended(_:)`` with its reason |
/// | 2 | the outcome is ``ProximityRestoreOutcomeKind/corrupt`` | ``ProximityResumePresentation/couldNotReopen`` |
/// | 3 | the outcome says nothing whatever the offer says (`deferred`, `refused`, `notAttempted`) | ``ProximityResumePresentation/nothing`` — silent |
/// | 4 | `offersForegroundResume` | ``ProximityResumePresentation/offerResume`` |
/// | 5 | anything else | ``ProximityResumePresentation/nothing`` |
///
/// **Clause 1 is first because a HIT outranks everything**, and that is the clause worth stating
/// out loud: the user has just tried to get back into a mesh that ended and a door refused them, so
/// an offer, a file that would not decode and a silence are all answers to a question they are no
/// longer asking. A hit also cannot co-occur with `corrupt` at launch — a file that did not decode
/// produced no context, no offer and no door to walk into — so that half of the order is stated
/// rather than exercised, and the test says which rows are reachable.
///
/// **What clause 1 is NOT** (pass 2 fix review, P1-3): the standing `rejoinBar`, and not that bar
/// matched to the mesh in hand either. Both are launch-derived, both survive every session, and a
/// `terminated` context is never reaped — so either spelling re-presented "That session has ended."
/// on every cold start, with a per-launch `@State` dismissal that resets each time. A `terminated`
/// or `expired` launch with no hit falls through clause 1 to clause 5's silence (both carry
/// `offersForegroundResume == false`), and the sentence waits for the try.
///
/// **Clause 3 before clause 4** keeps that silence unconditional on anything but the hit: a restore
/// that read nothing this launch has nothing to offer, whatever a flag left over from an earlier
/// idle lapse says. Pass 2 folded ``ProximityRestoreOutcomeKind/notAttempted`` into the same clause
/// (see ``ProximityRestoreOutcomeKind/saysNothingWhateverTheOffer``), so "a restore that has not
/// concluded is silent" is true by RULE rather than by the circumstance that the restore happens to
/// raise no offer before it runs.
///
/// **Clause 5 is where `resumable`, `terminated` and `expired` land with no offer and no hit** —
/// and for the latter two that is the ORDINARY launch, not an impossible row: an ended context
/// raises no offer, and no door has been walked into yet. `resumable` reaches it only if the offer
/// flag is missing, which the restore cannot produce (it sets the two in the same breath; see the
/// test's reachable-rows cell). The fail-safe is silence, never an offer and never a reasonless
/// "ended": the Friends three-way resolves `.fresh`, the user starts a new session, and the rejoin
/// bar (if there really is one) still refuses at the door — which is where the sentence comes from.
nonisolated enum ProximityResumeDecision {

    /// Decides what one launch restore presents.
    ///
    /// - Parameter inputs: What the manager holds once `restoreSessionContextOncePerLaunch(now:)`
    ///   has run.
    /// - Returns: the presentation, which shows text for three of its four cases and arms nothing
    ///   in any of them.
    static func decide(_ inputs: ProximityResumeInputs) -> ProximityResumePresentation {
        if let reason = inputs.rejoinBarHit { return .ended(reason) }
        guard inputs.outcome != .corrupt else { return .couldNotReopen }
        if inputs.outcome.saysNothingWhateverTheOffer { return .nothing }
        return inputs.offersForegroundResume ? .offerResume : .nothing
    }
}

// MARK: - The projection, mapped

extension ProximityResumeInputs {

    /// Flattens ProximityKit's one public projection of the launch restore.
    ///
    /// **The whole of the module boundary is this initialiser.** `MeshNetworkManager` exports
    /// `sessionResumeProjection` and nothing else about the restore, and every clause of the table
    /// above reads what comes out of here — so a surface cannot reach around the decision to the
    /// manager, because there is nothing left on the manager to reach for.
    ///
    /// **An exhaustive `switch`, never `init?(rawValue:)` with a fallback.** The two vocabularies
    /// are the same eight tokens and `ProximityResumeDecisionTests` holds their `rawValue` sets
    /// equal; the reason the switch is written out anyway is what happens when a ninth arrives.
    /// A `rawValue` round-trip would answer `nil` and need a non-optional fallback — some kind
    /// chosen in advance to stand in for a kind nobody has thought about — and a new restore outcome
    /// would ship silently as whatever that fallback says. The switch is a build error instead.
    ///
    /// The bar hit's reason is the one field that DOES round-trip, because
    /// `MeshSessionTerminationReason` crossed the wall whole:
    /// ``ProximityMeshEndedReason`` carries its eight `rawValue`s one for one and
    /// `theEndedReasonVocabularyIsTheSealedContextsOwn` fails before a ninth can reach a user. Were
    /// one ever to slip through, the `flatMap` reads it as "no hit" — which presents whatever the
    /// outcome alone says (silence, for every launch that is not an offer) and leaves
    /// `rejoinRefusal(for:)` refusing at both admission doors regardless, which is where the bar is
    /// actually enforced.
    ///
    /// - Parameter projection: `MeshNetworkManager.sessionResumeProjection`.
    nonisolated init(projection: MeshSessionResumeProjection) {
        self.init(
            outcome: Self.kind(of: projection.outcome),
            offersForegroundResume: projection.offersForegroundResume,
            rejoinBarHit: projection.rejoinBarHit
                .flatMap { ProximityMeshEndedReason(rawValue: $0.rawValue) }
        )
    }

    /// The projection's outcome token in this target's vocabulary.
    ///
    /// - Parameter outcome: The projection's frozen kind.
    /// - Returns: the app-side kind, one for one.
    nonisolated static func kind(of outcome: MeshSessionResumeProjection.Outcome) -> ProximityRestoreOutcomeKind {
        switch outcome {
        case .notAttempted: return .notAttempted
        case .resumable: return .resumable
        case .terminated: return .terminated
        case .expired: return .expired
        case .noSession: return .noSession
        case .deferred: return .deferred
        case .refused: return .refused
        case .corrupt: return .corrupt
        }
    }
}
