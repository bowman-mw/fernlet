// ProximityResumeDecision.swift
// Fernlet
//
// Network migration P7 item 5, PASS 1 (plan §24.1, prompt §5c): the DECISION half of the resume
// surface — what a launch restore's outcome presents to the user, as a pure value.
//
// P6 item 7 wired `MeshNetworkManager.restoreSessionContextOncePerLaunch(now:)` and left its
// user-facing half hollow: `lastSessionRestoreOutcome`, `offersForegroundResume`,
// `restoredSessionContext` and `rejoinBar` have no app reader at all, which `FernletApp`'s own doc
// comment on `restoreMeshSessionContextIfNeeded(_:)` states in as many words. This file is the
// first half of the answer, and deliberately the half that can be a TABLE: five ordered clauses
// over three enumerable facts, so the Friends-surface affordance that follows in pass 2 has
// nothing left to decide and is placement and wiring only.
//
// Three facts it is built against, none of them negotiable here:
//
//   * **A restore ARMS NO RADIO** (invariant 5, and `restoreSessionContextOncePerLaunch`'s own doc
//     comment). Every case below PRESENTS; none of them starts a transport. The affordance's
//     ACTION is pass 2's, and it goes through `ProximityRunPolicyHost` like every other radio
//     move, because P7 item 3's zero wall leaves `FernletApp.mountRoutedRunPolicy(_:)` as the only
//     app-target body that may name a radio door. `ProximityResumeDecisionTests` scans this file
//     and `ProximityResumeCopy.swift` for `startJoin`, `applyRunState` and `pushNow` and requires
//     zero of each.
//   * **A deferred restore is SILENT, as a positive claim.** It is retried at the next
//     protected-data rise (`retrySessionRestoreIfPending(now:)`, the routed re-entry's job 1,
//     bounded by `MeshSessionRestoreBounds.maxAttempts`), so a sentence about it would be a
//     cold-start apology for something that is about to succeed. Silence is a row of the table
//     with a named test, not an omission.
//   * **A rejoin bar names the mesh ENDED, never "failed".** Nothing failed: a mesh that was left,
//     developed, terminated by the group or that reached its ceiling ended exactly as designed.
//
// ## Why this file names no ProximityKit type
//
// `MeshSessionRestoreOutcome`, `MeshSessionRejoinBar` and `MeshSessionTerminationReason` are
// INTERNAL to ProximityKit, and so are all four of the manager properties above. Measured at this
// commit: the module exports `currentMesh`, `isInSession`, `hasCommittedPeer`, `isSessionLive` and
// `restoreSessionContextOncePerLaunch(now:)` as `public` and stops there — which is the mechanical
// reason "no app surface reads its outcome" was true, not merely an oversight. So the decision is
// written over the app-side flattening below, and **pass 2 owes exactly one public projection** on
// the manager (the outcome kind, the offer flag and the bar's reason) plus the one mapping into
// ``ProximityRestoreOutcomeKind``. That mapping is not left to be invented: the test bundle can
// `@testable import ProximityKit`, so `ProximityResumeDecisionTests` enumerates every real
// `MeshSessionRestoreOutcome` case — payload variants included — through it and holds the whole
// product against the decisions table. Pass 2 implements a mapping that is already pinned rather
// than writing a second opinion about it.
//
// `ProximityAppLockState.resolve(_:isDuressSessionActive:)` is the precedent for the flattening
// itself: an app-side `CaseIterable` enum standing in for a payload-carrying package enum, with one
// documented mapping and the payloads dropped because no payload changes the answer.
//
// ## What is deliberately NOT an input
//
// The restored context's member count. A count in a sentence needs a hand-authored
// `variations.plural` block in `App/Fernlet/Localizable.xcstrings` — a bare `%lld` in a
// `defaultValue` offers a translator exactly one form, which is the defect
// `LocalizationBoundaryTests.pluralRuledKeys` exists to forbid — and this pass must not touch the
// catalog (it is held by another session and synced at close-out from `HEAD`'s blob). A resume
// affordance is a button, not a census; if the owner later wants "3 people were here", it arrives
// as its own key with its own plural rule, and this file gains one field.

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
    /// everyone or took this device out of one that carries on. The reason rides the rejoin bar.
    case terminated

    /// A live context whose ceiling passed while the process was gone (`expired`). The restore
    /// writes the termination mark, which raises the bar with `hardDeadlineSigned`.
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
/// `lastSessionRestoreOutcome` (flattened), `offersForegroundResume`, and `rejoinBar?.reason`.
/// `restoredSessionContext` is deliberately absent — see the file header on the member count.
nonisolated struct ProximityResumeInputs: Equatable, Hashable, Sendable {

    /// `MeshNetworkManager.lastSessionRestoreOutcome`, flattened, with nil spelled
    /// ``ProximityRestoreOutcomeKind/notAttempted``.
    let outcome: ProximityRestoreOutcomeKind

    /// `MeshNetworkManager.offersForegroundResume`.
    ///
    /// Not derivable from ``outcome``: the state machine also raises it for an idle-lapsed session
    /// inside a running process (`MeshSessionEffect.offerForegroundResume`), which is a second,
    /// live source this surface will meet the moment P7's poller lapses a window.
    let offersForegroundResume: Bool

    /// `MeshNetworkManager.rejoinBar?.reason`, the permanent bar against re-entering one mesh —
    /// re-derived from the sealed context at every launch, which is the half that makes it
    /// survive a force-quit.
    ///
    /// The mesh's id is not carried: the user is not shown a UUID, and "which mesh" is answered by
    /// the bar itself at the two doors that enforce it (`rejoinRefusal(for:)`).
    let rejoinBarReason: ProximityMeshEndedReason?
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
/// | 1 | a rejoin bar is up | ``ProximityResumePresentation/ended(_:)`` with its reason |
/// | 2 | the outcome is ``ProximityRestoreOutcomeKind/corrupt`` | ``ProximityResumePresentation/couldNotReopen`` |
/// | 3 | the outcome is retryable (`deferred`, `refused`) | ``ProximityResumePresentation/nothing`` — silent |
/// | 4 | `offersForegroundResume` | ``ProximityResumePresentation/offerResume`` |
/// | 5 | anything else | ``ProximityResumePresentation/nothing`` |
///
/// **Clause 1 is first because the bar outranks the offer**, and that is the clause worth stating
/// out loud: offering to resume a mesh this device may never re-enter would be an offer the user
/// would act on and the admission door would then refuse (`rejoinRefusal(for:)`, enforced at both
/// doors). It also outranks `corrupt`, which cannot co-occur at launch — the bar is re-derived from
/// the sealed context, and a file that did not decode produced no context to derive it from — so
/// the order is stated rather than exercised, and the test says which rows are reachable.
///
/// **Clause 3 before clause 4** keeps the deferred silence unconditional on anything but the bar: a
/// restore that read nothing this launch has nothing to offer, whatever a flag left over from an
/// earlier idle lapse says.
///
/// **Clause 5 is where `resumable`, `terminated` and `expired` land when their partner fact is
/// missing.** At launch that cannot happen — the restore sets the offer and the bar in the same
/// breath as the outcome (see the test's reachable-rows cell) — and the fail-safe for the
/// impossible row is silence, never an offer and never a reasonless "ended": the Friends three-way
/// resolves `.fresh`, the user starts a new session, and the rejoin bar (if there really is one)
/// still refuses at the door.
nonisolated enum ProximityResumeDecision {

    /// Decides what one launch restore presents.
    ///
    /// - Parameter inputs: What the manager holds once `restoreSessionContextOncePerLaunch(now:)`
    ///   has run.
    /// - Returns: the presentation, which shows text for three of its four cases and arms nothing
    ///   in any of them.
    static func decide(_ inputs: ProximityResumeInputs) -> ProximityResumePresentation {
        if let reason = inputs.rejoinBarReason { return .ended(reason) }
        guard inputs.outcome != .corrupt else { return .couldNotReopen }
        if inputs.outcome.isRetryable { return .nothing }
        return inputs.offersForegroundResume ? .offerResume : .nothing
    }
}
