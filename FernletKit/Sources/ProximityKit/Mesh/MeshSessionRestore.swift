// MeshSessionRestore.swift
// ProximityKit/Mesh
//
// P3 item 6 (plan §8.1, §8.2, §20.2): the durable half of the state machine — what a launch does
// with whatever `MeshSessionStore.load()` answered.
//
// The five load states map onto seven outcomes, and the split that matters is which of them may
// WRITE. `loaded` and `absent` carry a `LoadToken`; `deferred`, `refused` and `corrupt` do not, and
// this file preserves that at the outcome level rather than re-deciding it: a deferral and a
// refusal both retry (distinctly logged, because "ask again after unlock" and "custody refuses" are
// different situations), and a corrupt file is quarantined deliberately before anything is written.
// None of the three starts a session, and none of them lets a writer run.

import Foundation

// MARK: - MeshSessionRestoredDisposition

/// The shape a restored context has, as the state machine sees it (plan §8.2).
///
/// Deliberately smaller than ``MeshSessionRestoreOutcome``: the machine does not care whether the
/// file was absent or unreadable, only whether there is a session to resume, one that already
/// ended, or nothing.
nonisolated enum MeshSessionRestoredDisposition: String, Equatable, Sendable, CaseIterable {

    /// Nothing to restore — no file, or one that could not be read this time.
    case none

    /// A live context inside its ceiling: membership intact, participation stopped, resumable from
    /// the foreground through the merge path.
    case resumable

    /// The mesh itself ended (a verified termination, a final-pair termination, the epoch cap, or
    /// this device developed it).
    case terminated

    /// This device left, or was removed. The mesh may well continue without it.
    case departed

    /// The ceiling passed while the process was not running.
    case expired
}

// MARK: - MeshSessionRestoreOutcome

/// What a launch-time load means, one case per thing a launch can honestly do (plan §20.2).
///
/// | outcome | session started? | writer allowed? |
/// | --- | --- | --- |
/// | ``resumable(_:)`` | not yet — the foreground offers a resume | yes |
/// | ``terminated(_:_:)`` | never again | not needed; the file already says so |
/// | ``expired(_:)`` | never again | **yes, and it must** — the mark is written now |
/// | ``noSession`` | no | yes (a green field) |
/// | ``retryAfterUnlock(_:)`` | no | **no** |
/// | ``retryAfterRefusal(_:)`` | no | **no** |
/// | ``quarantineCorruptFile(_:)`` | no | only after the quarantine |
nonisolated enum MeshSessionRestoreOutcome: Equatable, Sendable {

    /// A live context inside its ceiling.
    case resumable(MeshSessionContext)

    /// A context that already records an ending, with the reason it records.
    case terminated(MeshSessionContext, MeshSessionTerminationReason)

    /// A live context whose ceiling passed while the process was gone. The termination mark has to
    /// be written before this device may treat it as ended by anyone else's reckoning.
    case expired(MeshSessionContext)

    /// No file: genuinely a green field.
    case noSession

    /// The load deferred (locked device, transient keychain, unreadable file). Retry later; never
    /// read as emptiness.
    case retryAfterUnlock(MeshSessionDeferral)

    /// Custody refused (plan §20.2's fifth state). Retried like a deferral and logged distinctly,
    /// because the field may well be full.
    case retryAfterRefusal(MeshSessionSealRefusal)

    /// A file exists and does not decode. Set it aside deliberately; do not overwrite it.
    case quarantineCorruptFile(MeshSessionCorruption)

    /// How the state machine should read this outcome.
    var disposition: MeshSessionRestoredDisposition {
        switch self {
        case .resumable: return .resumable
        case .expired: return .expired
        case .terminated(_, let reason): return reason.endsTheMeshForEveryone ? .terminated : .departed
        case .noSession, .retryAfterUnlock, .retryAfterRefusal, .quarantineCorruptFile: return .none
        }
    }

    /// Whether this outcome should be retried on the next unlock or foreground. Bounded by the
    /// caller — ``MeshSessionRestoreBounds/maxAttempts``.
    var isRetryable: Bool {
        switch self {
        case .retryAfterUnlock, .retryAfterRefusal: return true
        case .resumable, .terminated, .expired, .noSession, .quarantineCorruptFile: return false
        }
    }

    /// The restored context, when one was opened.
    var context: MeshSessionContext? {
        switch self {
        case .resumable(let context), .expired(let context), .terminated(let context, _): return context
        case .noSession, .retryAfterUnlock, .retryAfterRefusal, .quarantineCorruptFile: return nil
        }
    }

    /// A frozen-English log token naming the outcome. Never user copy.
    var logToken: String {
        switch self {
        case .resumable: return "resumable"
        case .terminated(_, let reason): return "terminated:\(reason.rawValue)"
        case .expired: return "expired"
        case .noSession: return "absent"
        case .retryAfterUnlock(let deferral): return "deferred:\(deferral.reason.rawValue)"
        case .retryAfterRefusal(let refusal): return "refused:\(refusal.cause.rawValue)"
        case .quarantineCorruptFile: return "corrupt"
        }
    }
}

// MARK: - MeshSessionRestoreBounds

/// Bounds on the launch restore (Power of 10 rule 2/3).
nonisolated enum MeshSessionRestoreBounds {

    /// How many times a retryable outcome is re-attempted before the device stops asking. A
    /// deferral is meant to be retried on the next unlock, not spun on — three attempts is enough
    /// to cross a first-unlock boundary and small enough that a permanently refusing custody costs
    /// three keychain reads, not a loop.
    static let maxAttempts = 3
}

// MARK: - MeshSessionRejoinBar

/// The permanent bar against re-entering one mesh (plan §8.2).
///
/// Held in memory by the session manager and **re-derived from the sealed context at every
/// launch**, which is the half that matters: a bar that lived only in memory would be lifted by a
/// force-quit, and "a developed or terminated mesh can never be rejoined" would mean "until the
/// user relaunches".
nonisolated struct MeshSessionRejoinBar: Equatable, Sendable {

    /// The mesh that may never be re-entered.
    let meshID: UUID

    /// Why. A frozen token.
    let reason: MeshSessionTerminationReason
}

// MARK: - MeshSessionResumeProjection

/// **The launch restore, as the app may see it** (network migration P7 item 5 pass 2, plan §24.1).
///
/// P6 item 7 wired ``MeshNetworkManager/restoreSessionContextOncePerLaunch(now:)`` and left its
/// user-facing half with no reader at all, for a mechanical reason: `MeshSessionRestoreOutcome`,
/// ``MeshSessionRejoinBar`` and the four manager properties the restore publishes are INTERNAL to
/// this module, so `App/Fernlet` could not name any of them. This value is the whole of what crosses
/// that wall — three facts, no context, no payloads, nothing to re-derive — and
/// `MeshNetworkManager.sessionResumeProjection` is its one producer.
///
/// ## The bar crosses as a HIT, never as a standing fact
///
/// ``rejoinBarHit`` is the reason carried by the last entry ``MeshNetworkManager/rejoinRefusal(for:)``
/// actually REFUSED this run, and **not** `rejoinBar?.reason`, nor that bar matched to the mesh in
/// hand. The difference is a real defect the app shipped for one pass: the bar is durable by design
/// and is cleared **nowhere** — `resetSessionStateMachine(keepingTerminalState:)` says so in as many
/// words — a `terminated` context is never reaped, and an `expired` one is written back AS
/// terminated, so a launch-derived bar re-presented "that session has ended" on every cold start
/// until some new session overwrote the sealed file. Matching it to the mesh in hand did not close
/// that, because at launch the mesh in hand IS the mesh the bar names. Plan §24.1 asks for what a
/// rejoin bar looks like **when the user tries anyway**, so that is what crosses: a `terminated` or
/// `expired` launch is silent (both carry `offersForegroundResume == false`) until a door refuses.
///
/// ## Why the payloads are dropped
///
/// A deferral's reason, a refusal's cause and a corruption's detail change what is LOGGED and never
/// what is presented — all three are silence or one sentence — so the projection carries the kind
/// and stops. `ProximityResumeDecisionTests` enumerates every payload variant through the mapping
/// and holds the whole product against the app's decision table, which is what makes "the payload
/// changes nothing" a tested claim rather than an assumption.
public nonisolated struct MeshSessionResumeProjection: Equatable, Sendable {

    /// What a launch restore concluded, in the eight kinds an app surface can act on.
    ///
    /// **Frozen tokens, and they are the app's `ProximityRestoreOutcomeKind` spellings one for
    /// one** — `ProximityResumeDecisionTests` holds the two `rawValue` sets equal, so a ninth kind
    /// added here reddens there before it can reach a surface with no sentence. They are diagnostic
    /// vocabulary and never display copy: the sentence a user reads is the app's
    /// `ProximityResumeCopy`'s and lives nowhere else.
    ///
    /// ``notAttempted`` has no counterpart in ``MeshSessionRestoreOutcome``: it is the `nil` outcome
    /// — the window before the launch mount runs, and a second mount the per-process latch refused.
    public nonisolated enum Outcome: String, CaseIterable, Sendable {

        /// No restore has concluded yet.
        case notAttempted

        /// A live context inside its ceiling. The one kind that raises the offer.
        case resumable

        /// A context that already records an ending. It raises no offer and, on its own, says
        /// nothing: the reason reaches the surface only if a door later refuses an entry
        /// (``rejoinBarHit``).
        case terminated

        /// A live context whose ceiling passed while the process was gone.
        case expired

        /// No file at all: a green field.
        case noSession

        /// The load deferred — a locked device, a transient keychain. Retried, never spoken about.
        case deferred

        /// Custody refused. Retried like a deferral and logged apart.
        case refused

        /// A file exists and does not decode; it has been quarantined beside itself.
        case corrupt

        /// Flattens one restore outcome, with `nil` spelled ``notAttempted``.
        ///
        /// Internal because its argument is: `MeshSessionRestoreOutcome` does not cross the module
        /// wall and this is the door instead of it. Exhaustive rather than defaulted, so an eighth
        /// outcome case is a build error here.
        ///
        /// - Parameter outcome: `MeshNetworkManager.lastSessionRestoreOutcome`.
        nonisolated init(restoring outcome: MeshSessionRestoreOutcome?) {
            guard let outcome else {
                self = .notAttempted
                return
            }
            switch outcome {
            case .resumable: self = .resumable
            case .terminated: self = .terminated
            case .expired: self = .expired
            case .noSession: self = .noSession
            case .retryAfterUnlock: self = .deferred
            case .retryAfterRefusal: self = .refused
            case .quarantineCorruptFile: self = .corrupt
            }
        }
    }

    /// What the last restore attempt concluded, flattened.
    public let outcome: Outcome

    /// `MeshNetworkManager.offersForegroundResume` — whether the foreground may offer to pick the
    /// last session back up.
    ///
    /// Not derivable from ``outcome``: the state machine raises the same effect for a local idle
    /// stop inside a running process, so this is a second source the surface must read rather than
    /// infer.
    public let offersForegroundResume: Bool

    /// Why an entry this run was REFUSED, or nil while nothing has been refused.
    ///
    /// See the type's discussion: this is `MeshNetworkManager.lastRejoinBarHit`, the run-scoped
    /// record of a door closing, never the durable bar — which outlives every session it was raised
    /// for and would therefore speak on every launch forever.
    public let rejoinBarHit: MeshSessionTerminationReason?

    /// Builds a projection.
    ///
    /// - Parameters:
    ///   - outcome: The flattened restore outcome.
    ///   - offersForegroundResume: Whether a resume is on offer.
    ///   - rejoinBarHit: The reason of a bar HIT this run, or nil.
    public init(
        outcome: Outcome,
        offersForegroundResume: Bool,
        rejoinBarHit: MeshSessionTerminationReason?
    ) {
        self.outcome = outcome
        self.offersForegroundResume = offersForegroundResume
        self.rejoinBarHit = rejoinBarHit
    }
}

// MARK: - MeshForegroundResumeOutcome

/// What ``MeshNetworkManager/acceptForegroundResume(now:)`` did — and, when it adopted nothing, which
/// guard closed (network migration P7 item 5 pass 2 fix review, P1-3d).
///
/// The door used to answer `Bool`, and one of its five refusals is not like the others:
/// ``Reason/rejoinBarred(_:)`` is the user TRYING to re-enter a mesh that ended, which is the one
/// moment plan §24.1 owes them a sentence about it. A caller that only knows "false" cannot tell
/// that from an idempotent second tap, so the reason crosses the module wall with the outcome and
/// the surface presents it. Nothing else about the refusal does: the audit line is the manager's.
public nonisolated enum MeshForegroundResumeOutcome: Equatable, Sendable {

    /// The restored context was adopted: ``MeshNetworkManager/currentMesh`` now names it, the offer
    /// is spent, and **no radio was armed** — that push is the run policy's.
    case accepted

    /// Nothing was adopted, and this is why. Idempotent and fail-closed: every one of the five
    /// leaves the manager exactly as it found it.
    case refused(Reason)

    /// The five frozen refusals of ``MeshNetworkManager/acceptForegroundResume(now:)``, in the
    /// order its guards run.
    public nonisolated enum Reason: Equatable, Sendable {

        /// No offer was standing.
        case noOffer

        /// An offer with no restored context behind it.
        case noContext

        /// A mesh is already held, so there is nothing to adopt into.
        case meshHeld

        /// The restored mesh carries the permanent rejoin bar (plan §8.2), with its reason. **The
        /// one refusal a surface presents**: the mesh ended, and the user just tried to go back.
        case rejoinBarred(MeshSessionTerminationReason)

        /// This device's participation has already ended.
        case sessionEnded

        /// The frozen audit token for this refusal. English forever, never display copy — the
        /// sentence a user reads is the app's `ProximityResumeCopy`'s.
        ///
        /// The five spellings are the ones `mesh.sessionResume.refused` has always logged, so the
        /// transcripts of every earlier round still read the same.
        public var token: String {
            switch self {
            case .noOffer: return "noOffer"
            case .noContext: return "noContext"
            case .meshHeld: return "meshHeld"
            case .rejoinBarred: return "rejoinBarred"
            case .sessionEnded: return "sessionEnded"
            }
        }
    }
}

// MARK: - MeshSessionRestore

/// The pure classifier from a five-state load to a seven-way launch outcome.
///
/// No I/O, no clock of its own, no store: `now` and the local fingerprint are arguments, so every
/// branch is stated as a value in a test.
nonisolated enum MeshSessionRestore {

    /// Classifies one load.
    ///
    /// The ordering inside `loaded` is deliberate: an ending that is already RECORDED wins over the
    /// ceiling, so a context that says "this device departed" is reported as departed rather than
    /// as an expiry that happens to have passed since. Only a context with no recorded ending is
    /// measured against the deadline.
    ///
    /// - Parameters:
    ///   - load: What ``MeshSessionStore/load()`` answered.
    ///   - selfFingerprint: This device's fingerprint, for the own-departure check.
    ///   - now: The current instant, for the ceiling check.
    /// - Returns: The outcome the launch must act on.
    static func outcome(
        for load: MeshSessionLoad,
        selfFingerprint: String,
        now: Date
    ) -> MeshSessionRestoreOutcome {
        switch load {
        case .absent:
            return .noSession
        case .deferred(let deferral):
            return .retryAfterUnlock(deferral)
        case .refused(let refusal):
            return .retryAfterRefusal(refusal)
        case .corrupt(let corruption):
            return .quarantineCorruptFile(corruption)
        case .loaded(let context, _):
            return outcome(forLoaded: context, selfFingerprint: selfFingerprint, now: now)
        }
    }

    /// The `loaded` half: a recorded ending first, then the ceiling, then "resumable".
    private static func outcome(
        forLoaded context: MeshSessionContext,
        selfFingerprint: String,
        now: Date
    ) -> MeshSessionRestoreOutcome {
        if let reason = context.recordedEndingReason(selfFingerprint: selfFingerprint) {
            return .terminated(context, reason)
        }
        let ceiling = MeshSessionCeiling(hardDeadline: context.hardDeadline, startedAt: context.createdAt)
        // A restore has consumed no local runtime yet, so only the signed bound can have been
        // reached while the process was gone; the monotonic bound starts counting from here.
        if ceiling.verdict(now: now, monotonicElapsed: 0).isReached {
            return .expired(context)
        }
        return .resumable(context)
    }
}
