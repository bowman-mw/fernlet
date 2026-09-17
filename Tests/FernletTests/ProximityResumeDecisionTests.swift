// ProximityResumeDecisionTests.swift
// FernletTests
//
// Network migration P7 item 5, pass 1 (plan §24.1, prompt §5c): the launch restore's DECISION half,
// as a table.
//
// `ProximityResumeDecision.decide(_:)` is a pure function over three enumerable facts, so this
// suite enumerates the WHOLE product — every `MeshSessionRestoreOutcome` case with every payload
// variant that can be constructed (29 outcome values, nil included) × both offer flags × every
// rejoin-bar-hit reason plus nil = 522 rows — and holds each row against an INDEPENDENT oracle.
//
// The oracle is not a second spelling of the policy. It takes the RAW outcome and answers from
// ProximityKit's own vocabulary — the `quarantineCorruptFile` case itself and
// `MeshSessionRestoreOutcome.isRetryable` — rather than from the app's flattened
// `ProximityRestoreOutcomeKind`, and it is written as the decisions table's ordered clauses: the
// bar HIT first (a door refused this device an entry this run, which is the one thing the reader is
// owed a sentence about), then the corrupt file, then the retryable silence, then the offer.
//
// **The bar axis is the HIT, since pass 2's fix review (P1-3).** It was the bar as the launch
// derived it, which is durable, is cleared nowhere and is re-derived from a `terminated` context
// nothing reaps — so "That session has ended." re-appeared on every cold start for the rest of the
// install. The cells that name it say HIT now, and two of them say what a launch onto an ended
// context does instead: nothing at all, until the user tries.
//
// **The flattening's mapping is pinned here because the app target cannot spell it yet.**
// `MeshSessionRestoreOutcome`, `MeshSessionRejoinBar` and `MeshSessionTerminationReason` are
// internal to ProximityKit and so are the four manager properties the restore publishes, so pass 2
// owes a public projection; the test bundle can `@testable import ProximityKit`, so ``kind(for:)``
// below is the mapping that projection must implement, enumerated through the whole product rather
// than left to be invented.
//
// Three claims beyond the table:
//
//   * **A restore arms no radio.** Neither new file names `startJoin`, `applyRunState` or
//     `pushNow` — the affordance's action is pass 2's, through `ProximityRunPolicyHost`, which
//     P7 item 3's zero wall already makes the only app-target writer of a radio.
//   * **No display copy is typed `String`.** `-> String`, `: String =` and `String(localized:` are
//     all absent from both files, each needle fixtured against a planted line, because a `String`
//     sentence compiles, renders correctly in English and silently leaves every string catalog.
//   * **The ended vocabulary is the sealed context's.** `ProximityMeshEndedReason`'s `rawValue`s
//     are `MeshSessionTerminationReason`'s, one for one, so a ninth reason in the sealed context
//     reddens here and fails the build in `ProximityResumeCopy` until it has a sentence.

import Foundation
import SwiftUI
import Testing
@testable import FernletCrypto
import FernletFoundation
@testable import ProximityKit
@testable import Fernlet

/// One row of the launch-restore product: the RAW facts, beside the inputs the decision is handed.
///
/// The raw outcome and the raw bar reason are carried because the ORACLE reads them — asking the
/// app's flattened `ProximityRestoreOutcomeKind` for the answer the flattening produced is the
/// tautology `ProximityRunPolicyTests` had to fix once already.
private struct ProximityResumeProductRow {

    /// The outcome as ProximityKit spells it, or nil for a launch whose restore has not concluded.
    let outcome: MeshSessionRestoreOutcome?

    /// The reason of a rejoin bar HIT this run, as the sealed context spells it, or nil for no hit.
    let barHitReason: MeshSessionTerminationReason?

    /// `MeshNetworkManager.offersForegroundResume`.
    let offersForegroundResume: Bool

    /// The flattened facts the app-side decision actually takes.
    let inputs: ProximityResumeInputs
}

/// One (facts → presentation) shape a real launch can produce.
///
/// A struct rather than a tuple so each row of the list below is type-checked on its own — a nine
/// element array of four-tuples carrying optionals and implicit members is the shape that makes the
/// type checker give up.
private struct ProximityResumeReachableRow {

    /// The flattened restore outcome.
    let outcome: ProximityRestoreOutcomeKind

    /// `MeshNetworkManager.offersForegroundResume`.
    let offers: Bool

    /// The reason of a bar hit this run, or nil for no hit.
    let bar: ProximityMeshEndedReason?

    /// What the decisions table must answer for this row.
    let shows: ProximityResumePresentation
}

/// One frozen ended sentence, pinned to the reason it belongs to.
private struct ProximityEndedSentencePin {

    /// The reason the rejoin bar carries.
    let reason: ProximityMeshEndedReason

    /// The sentence the copy fork must answer, verbatim — the key the catalog sync harvests.
    let sentence: LocalizedStringKey
}

/// Plan §24.1's launch-restore presentation, over its whole input product.
@MainActor
@Suite struct ProximityResumeDecisionTests {

    // MARK: - The product

    /// A live context, well inside its ceiling. Nothing here reads it — the decision is blind to
    /// the context on purpose — but the three outcome cases that carry one need one to exist.
    static let context = MeshSessionContext(
        meshID: MeshMembershipFixtures.meshID,
        protocolVersion: 3,
        createdAt: MeshMembershipFixtures.base,
        hardDeadline: MeshMembershipFixtures.base.addingTimeInterval(6 * 3_600)
    )

    /// The four corruption details, listed rather than iterated: `MeshSessionCorruption.Detail`
    /// carries payloads and so is not `CaseIterable`.
    static let corruptions: [MeshSessionCorruption.Detail] = [
        .emptyFile, .undecodableJSON("fixture"), .unsupportedSchemaVersion(1), .authenticationFailed
    ]

    /// Every `MeshSessionRestoreOutcome` the product runs over, plus nil: 1 + 1 resumable +
    /// 8 terminated (one per reason) + 1 expired + 1 noSession + 3 deferrals + 10 refusals
    /// (2 operations × 5 causes) + 4 corruptions = 29.
    ///
    /// - Returns: the outcome values, nil first.
    static func allOutcomes() -> [MeshSessionRestoreOutcome?] {
        var built: [MeshSessionRestoreOutcome?] = [nil, .resumable(context), .expired(context), .noSession]
        built += MeshSessionTerminationReason.allCases.map { reason -> MeshSessionRestoreOutcome? in
            .terminated(context, reason)
        }
        built += MeshSessionDeferral.Reason.allCases.map { reason -> MeshSessionRestoreOutcome? in
            .retryAfterUnlock(MeshSessionDeferral(reason: reason, detail: "fixture"))
        }
        for operation in MeshSessionSealRefusal.Operation.allCases {
            built += MeshSessionSealRefusal.Cause.allCases.map { cause -> MeshSessionRestoreOutcome? in
                .retryAfterRefusal(MeshSessionSealRefusal(operation: operation, cause: cause))
            }
        }
        built += corruptions.map { detail -> MeshSessionRestoreOutcome? in
            .quarantineCorruptFile(MeshSessionCorruption(detail: detail))
        }
        return built
    }

    /// Every rejoin-bar-hit reason the product runs over, nil first.
    ///
    /// A sealed reason with no app twin is DROPPED here rather than carried as nil, so the row
    /// count pin in ``everyRowOfTheLaunchRestoreProductMatchesTheDecisionsTable()`` fails loudly
    /// beside ``theEndedReasonVocabularyIsTheSealedContextsOwn()`` instead of thinning the product
    /// silently.
    ///
    /// - Returns: nil plus every reason that maps.
    static func barReasons() -> [MeshSessionTerminationReason?] {
        let mapped = MeshSessionTerminationReason.allCases.filter {
            ProximityMeshEndedReason(rawValue: $0.rawValue) != nil
        }
        var reasons: [MeshSessionTerminationReason?] = [nil]
        reasons += mapped.map { reason -> MeshSessionTerminationReason? in reason }
        return reasons
    }

    /// The mapping pass 2's public projection owes, pinned here because the app target cannot name
    /// `MeshSessionRestoreOutcome` at all today.
    ///
    /// - Parameter outcome: What the restore concluded, or nil before it has.
    /// - Returns: the app-side kind.
    static func kind(for outcome: MeshSessionRestoreOutcome?) -> ProximityRestoreOutcomeKind {
        guard let outcome else { return .notAttempted }
        switch outcome {
        case .resumable: return .resumable
        case .terminated: return .terminated
        case .expired: return .expired
        case .noSession: return .noSession
        case .retryAfterUnlock: return .deferred
        case .retryAfterRefusal: return .refused
        case .quarantineCorruptFile: return .corrupt
        }
    }

    /// Builds one row.
    ///
    /// `private`, like every member below whose signature names ``ProximityResumeProductRow``: that
    /// type is `private` at file scope (so, fileprivate), and an internal member of an internal
    /// suite cannot expose it — "method must be declared fileprivate because its result uses a
    /// fileprivate type" (pass 2 fix review, P1-2). Every caller is inside the suite.
    ///
    /// - Parameters:
    ///   - outcome: The raw outcome.
    ///   - offers: `offersForegroundResume`.
    ///   - barHitReason: The raw reason of a bar hit this run, or nil.
    /// - Returns: the row, raw facts and flattened inputs together.
    private static func row(
        outcome: MeshSessionRestoreOutcome?,
        offers: Bool,
        barHitReason: MeshSessionTerminationReason?
    ) -> ProximityResumeProductRow {
        let inputs = ProximityResumeInputs(
            outcome: kind(for: outcome),
            offersForegroundResume: offers,
            rejoinBarHit: barHitReason.flatMap { ProximityMeshEndedReason(rawValue: $0.rawValue) }
        )
        return ProximityResumeProductRow(
            outcome: outcome, barHitReason: barHitReason, offersForegroundResume: offers, inputs: inputs
        )
    }

    /// The whole product: 29 outcomes × 2 offer flags × 9 bar-hit reasons = 522 rows.
    ///
    /// - Returns: every row, enumerated.
    private static func productRows() -> [ProximityResumeProductRow] {
        var rows: [ProximityResumeProductRow] = []
        for outcome in allOutcomes() {
            for offers in [false, true] {
                for barHitReason in barReasons() {
                    rows.append(row(outcome: outcome, offers: offers, barHitReason: barHitReason))
                }
            }
        }
        return rows
    }

    // MARK: - The oracle

    /// The decisions table, written as ordered clauses over the RAW facts.
    ///
    /// Independent of the code under test by construction: it never reads
    /// `ProximityRestoreOutcomeKind`, and its "is this retried?" leg is
    /// `MeshSessionRestoreOutcome.isRetryable` — ProximityKit's own answer, which is also the reason
    /// the deferral and the refusal present alike.
    ///
    /// `private` for the same reason ``row(outcome:offers:barHitReason:)`` is: its parameter names a
    /// file-scope `private` type (P1-2).
    ///
    /// - Parameter row: One row of the product.
    /// - Returns: what the decisions table says that row presents.
    private static func oracle(_ row: ProximityResumeProductRow) -> ProximityResumePresentation {
        if let reason = row.barHitReason, let ended = ProximityMeshEndedReason(rawValue: reason.rawValue) {
            return .ended(ended)
        }
        // Pass 2's correction: a launch whose restore has not CONCLUDED is silent by rule, not by
        // the circumstance that the restore raises no offer before it runs. The oracle states it on
        // the raw fact — a nil outcome — one clause before the offer is consulted at all.
        guard let outcome = row.outcome else { return .nothing }
        if case .quarantineCorruptFile = outcome { return .couldNotReopen }
        if outcome.isRetryable { return .nothing }
        return row.offersForegroundResume ? .offerResume : .nothing
    }

    /// A one-word label for a presentation, so a coverage claim can be stated as a set.
    ///
    /// - Parameter presentation: The decided presentation.
    /// - Returns: its case name.
    static func label(_ presentation: ProximityResumePresentation) -> String {
        switch presentation {
        case .nothing: return "nothing"
        case .offerResume: return "offerResume"
        case .couldNotReopen: return "couldNotReopen"
        case .ended: return "ended"
        }
    }

    /// The two new app files, comment-stripped, for the source-scan cells.
    ///
    /// - Returns: the decision file first, the copy fork second.
    static func newFileSources() throws -> [String] {
        let decision = try RepoRoot.source("App/Fernlet/ProximityResumeDecision.swift")
        let copy = try RepoRoot.source("App/Fernlet/ProximityResumeCopy.swift")
        return [MeshRoutedSourceScan.codeOnly(decision), MeshRoutedSourceScan.codeOnly(copy)]
    }

    // MARK: - The table

    /// Every row of the product presents what the decisions table says it presents.
    ///
    /// The count is pinned as a literal so a shrunken product cannot pass vacuously, and the set of
    /// presentations actually observed is pinned too — a table that answered `.nothing` everywhere
    /// would otherwise agree with an oracle that had the same bug.
    @Test func everyRowOfTheLaunchRestoreProductMatchesTheDecisionsTable() {
        let rows = Self.productRows()
        #expect(Self.allOutcomes().count == 29,
                "every MeshSessionRestoreOutcome case, payload variants included: 1 nil + 1 + 8 + 1 + 1 + 3 + 10 + 4")
        #expect(Self.barReasons().count == 9, "eight sealed reasons that map, plus no hit at all")
        #expect(rows.count == 522, "29 outcome values × 2 offer flags × 9 bar-hit reasons — the whole product")
        var mismatch: String?
        var seen: Set<String> = []
        // R2: bounded by the enumerated product above.
        for row in rows {
            let decided = ProximityResumeDecision.decide(row.inputs)
            seen.insert(Self.label(decided))
            if decided != Self.oracle(row), mismatch == nil {
                mismatch = "\(row.inputs) decided \(Self.label(decided)), table says \(Self.label(Self.oracle(row)))"
            }
        }
        #expect(mismatch == nil,
                "a row disagreed with the decisions table: the hit, then corrupt, then the retryable silence, then the offer")
        #expect(seen == ["nothing", "offerResume", "couldNotReopen", "ended"],
                "and all four presentations are reached, so the agreement is not one answer everywhere")
    }

    /// The nine (outcome, offer, hit) shapes a real launch can produce, each with a literal.
    ///
    /// Read off the shipping restore's own arms rather than off the policy:
    /// `MeshSessionStateMachine.restored(_:)` raises `offerForegroundResume` for `.resumable` and
    /// nothing at all for `.none`; the `terminated` and `expired` arms raise the durable bar and no
    /// offer, so at LAUNCH they carry no hit — nobody has tried anything — and the table answers
    /// them with silence (pass 2 fix review, P1-3). The two `ended` rows below are therefore rows a
    /// launch cannot produce by itself: they are a launch plus a refused TRY, which is the only way
    /// `lastRejoinBarHit` is ever set, and they are here because that pair is what the user sees.
    @Test func theReachableLaunchOutcomesArePresentedAsTheRestoreArmsThem() {
        let rows = [
            ProximityResumeReachableRow(outcome: .notAttempted, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .noSession, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .deferred, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .refused, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .corrupt, offers: false, bar: nil, shows: .couldNotReopen),
            ProximityResumeReachableRow(outcome: .resumable, offers: true, bar: nil, shows: .offerResume),
            ProximityResumeReachableRow(outcome: .terminated, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .expired, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .terminated, offers: false, bar: .verifiedTerminationRecord,
                                        shows: .ended(.verifiedTerminationRecord))
        ]
        #expect(rows.count == 9, """
            the five state-machine arms, the two ended launches that are now SILENT, the quarantine \
            and the one refused try that earns the sentence
            """)
        var wrong: String?
        // R2: bounded by the list above.
        for row in rows {
            let inputs = ProximityResumeInputs(
                outcome: row.outcome, offersForegroundResume: row.offers, rejoinBarHit: row.bar
            )
            let decided = ProximityResumeDecision.decide(inputs)
            if decided != row.shows, wrong == nil {
                wrong = "\(row.outcome.rawValue) decided \(Self.label(decided))"
            }
        }
        #expect(wrong == nil, "a launch the shipping restore can really produce was presented wrongly")
        let silent = rows.filter { $0.shows == .nothing }
        #expect(silent.count == 6, """
            and six of the nine say nothing at all, which is what a launch mostly owes a reader: \
            two of them are ENDED contexts, the rows the fix made quiet
            """)
    }

    // MARK: - The four presentations, one at a time

    /// A deferral says nothing, and that silence is a positive claim.
    ///
    /// `retryAfterUnlock` and `retryAfterRefusal` are both retried by the routed re-entry's job 1
    /// at the next protected-data rise, bounded by `MeshSessionRestoreBounds.maxAttempts`, so a
    /// sentence about either would be a cold-start apology for something about to succeed.
    @Test func aDeferredRestoreSaysNothingAtAll() {
        let deferred = ProximityResumeInputs(
            outcome: .deferred, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(deferred) == .nothing,
                "a deferral retries at the next protected-data rise and is never read as emptiness OR as news")
        let refused = ProximityResumeInputs(
            outcome: .refused, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(refused) == .nothing,
                "custody's refusal is retried the same way and says the same nothing")
        let staleOffer = ProximityResumeInputs(
            outcome: .deferred, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(staleOffer) == .nothing,
                "and a restore that read nothing this launch offers nothing, whatever an earlier idle lapse left set")
        let notAttempted = ProximityResumeInputs(
            outcome: .notAttempted, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(notAttempted) == .nothing,
                "and the window before the launch mount has run is silent too")
        let notAttemptedOffered = ProximityResumeInputs(
            outcome: .notAttempted, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(notAttemptedOffered) == .nothing, """
            and it is silent WITH the offer flag set, which is pass 2's correction: pass 1 left \
            `notAttempted` out of clause 3 and relied on the restore not raising an offer before it \
            runs, so "not attempted is silent" was true by circumstance rather than by rule
            """)
        #expect(ProximityRestoreOutcomeKind.notAttempted.saysNothingWhateverTheOffer,
                "and the rule is named, so a future reader cannot mistake it for a coincidence")
        #expect(!ProximityRestoreOutcomeKind.notAttempted.isRetryable,
                "while `isRetryable` stays ProximityKit's own mirror — the two answer different questions")
        #expect(ProximityResumeCopy.title(.nothing) == nil, "silence has no headline")
        #expect(ProximityResumeCopy.body(.nothing) == nil, "and no second line")
    }

    /// A corrupt file says it could not be reopened, and that nothing sealed was lost.
    ///
    /// The second sentence is the load-bearing one: `quarantineCorruptFile` sets the bytes aside
    /// deliberately rather than overwriting them, and every routed item the user shared is still
    /// sealed on this device.
    @Test func aCorruptFileSaysItCouldNotBeReopenedAndThatNothingWasLost() {
        let inputs = ProximityResumeInputs(
            outcome: .corrupt, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(inputs) == .couldNotReopen,
                "the one outcome that owes the user a sentence")
        let offered = ProximityResumeInputs(
            outcome: .corrupt, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(offered) == .couldNotReopen,
                "and a file that did not decode is never offered as a resume")
        let title: LocalizedStringKey? = "Your last session couldn't be reopened."
        #expect(ProximityResumeCopy.title(.couldNotReopen) == title, "frozen key; the catalog sync harvests it")
        let body: LocalizedStringKey? = "Nothing you shared was lost — it stays sealed on this device."
        #expect(ProximityResumeCopy.body(.couldNotReopen) == body,
                "the reassurance is half the decision, not decoration")
    }

    /// A rejoin bar HIT names the mesh as ENDED, never as failed, and it outranks everything.
    ///
    /// Clause 1 of the table, and the clause worth a cell of its own: the user has just tried to get
    /// back into a mesh a door refused them (`rejoinRefusal(for:)`, enforced at both admission doors
    /// and at the accept), so an offer standing beside the hit is an offer about a question they are
    /// no longer asking. The HIT is the input, never the standing bar — see
    /// ``aTerminatedOrExpiredContextIsSilentAtLaunchUntilTheUserTries()`` for the other half.
    @Test func aRejoinBarHitNamesTheMeshAsEndedAndOutranksTheOffer() {
        var wrong: String?
        // R2: bounded by the enum's cases.
        for reason in ProximityMeshEndedReason.allCases {
            let inputs = ProximityResumeInputs(
                outcome: .resumable, offersForegroundResume: true, rejoinBarHit: reason
            )
            if ProximityResumeDecision.decide(inputs) != .ended(reason), wrong == nil {
                wrong = reason.rawValue
            }
        }
        #expect(wrong == nil, "a refused try is ENDED even where the manager still offers a resume")
        let title: LocalizedStringKey? = "That session has ended."
        #expect(ProximityResumeCopy.title(.ended(.ownDeparture)) == title, "ended — never failed; nothing failed")
        let sentences = [
            ProximityEndedSentencePin(reason: .ownDeparture, sentence: "You left it."),
            ProximityEndedSentencePin(reason: .removedFromRoster, sentence: "The group removed you from it."),
            ProximityEndedSentencePin(reason: .verifiedTerminationRecord, sentence: "It was ended by the group."),
            ProximityEndedSentencePin(reason: .finalPairTermination,
                                      sentence: "You and the last person in it ended it together."),
            ProximityEndedSentencePin(reason: .hardDeadlineSigned, sentence: "It reached its six-hour limit."),
            ProximityEndedSentencePin(reason: .hardDeadlineMonotonic, sentence: "It reached its six-hour limit."),
            ProximityEndedSentencePin(reason: .epochCounterExhausted,
                                      sentence: "It ran out of new keys, so it closed."),
            ProximityEndedSentencePin(reason: .developed, sentence: "You finished it and developed the photos.")
        ]
        var wrongSentence: String?
        // R2: bounded by the list above.
        for pin in sentences where ProximityResumeCopy.endedBecause(pin.reason) != pin.sentence {
            if wrongSentence == nil { wrongSentence = pin.reason.rawValue }
        }
        #expect(wrongSentence == nil, "the ended sentences are frozen keys; the close-out syncs them into the catalog")
        #expect(sentences.count == ProximityMeshEndedReason.allCases.count, "one pin per reason, no reason unpinned")
    }

    /// **A launch onto an ended context says nothing at all** — the other half of clause 1.
    ///
    /// The defect this closes shipped for one pass (pass 2 fix review, P1-3): the bar was read as a
    /// launch-derived fact, a `terminated` context is never reaped, an `expired` one is written back
    /// AS terminated, and the card's dismissal is per-launch `@State` — so "That session has ended."
    /// was re-presented on every cold start, for the rest of the install, to a reader who had done
    /// nothing but open the app. Plan §24.1 asks for the sentence when the user TRIES; both kinds
    /// are enumerated here against both offer flags, and every row is a literal.
    @Test func aTerminatedOrExpiredContextIsSilentAtLaunchUntilTheUserTries() {
        let terminated = ProximityResumeInputs(
            outcome: .terminated, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(terminated) == .nothing,
                "a relaunch onto an ended session is not news, and it is not the user's doing")
        let terminatedOffered = ProximityResumeInputs(
            outcome: .terminated, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(terminatedOffered) == .offerResume, """
            and with an offer beside it the OFFER is what shows — an impossible row at launch (an \
            ended context raises no offer), stated so the table's order is exercised either way
            """)
        let expired = ProximityResumeInputs(
            outcome: .expired, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(expired) == .nothing,
                "a ceiling that passed while the process was gone is silent on the same rule")
        let expiredOffered = ProximityResumeInputs(
            outcome: .expired, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(expiredOffered) == .offerResume,
                "and the same impossible row, answered the same way")
        let tried = ProximityResumeInputs(
            outcome: .terminated, offersForegroundResume: false, rejoinBarHit: .finalPairTermination
        )
        #expect(ProximityResumeDecision.decide(tried) == .ended(.finalPairTermination),
                "and THEN the sentence is owed: a door refused this device an entry this run")
        #expect(ProximityResumeCopy.title(.nothing) == nil,
                "so the silent launch draws no headline at all, whatever the sealed file records")
    }

    /// The offer offers, and promises no reconnection.
    ///
    /// A restore arms no radio (invariant 5), so the second line says what is true: Fernlet is not
    /// looking for anyone until the user says so. The action behind the button is pass 2's.
    @Test func anOfferedResumeIsAnOfferAndPromisesNoReconnection() {
        let inputs = ProximityResumeInputs(
            outcome: .resumable, offersForegroundResume: true, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(inputs) == .offerResume, "the one affordance the restore earns")
        let noOffer = ProximityResumeInputs(
            outcome: .resumable, offersForegroundResume: false, rejoinBarHit: nil
        )
        #expect(ProximityResumeDecision.decide(noOffer) == .nothing,
                "the flag IS the offer: a resumable context the machine did not offer says nothing")
        let title: LocalizedStringKey? = "Pick up where you left off?"
        #expect(ProximityResumeCopy.title(.offerResume) == title, "frozen key")
        let body: LocalizedStringKey? = "Fernlet still has your last session. It isn't looking for anyone until you say so."
        #expect(ProximityResumeCopy.body(.offerResume) == body, "and it promises no reconnection, because none is armed")
        let button: LocalizedStringKey = "Resume session"
        #expect(ProximityResumeCopy.resumeButton == button,
                "its own key: the headline is a question and a button is an instruction")
    }

    // MARK: - The copy fork

    /// Every presentation that speaks has both sentences, and silence has neither.
    ///
    /// Exhaustive over `ProximityResumePresentation.allCases`, which is hand-written because
    /// `.ended(_:)` carries a reason — so a ninth `ProximityMeshEndedReason` enters this sweep
    /// without anyone remembering to add it, and fails the build in `ProximityResumeCopy` first.
    @Test func everyPresentationThatSpeaksHasItsOwnSentence() {
        var silenceSpoke = false
        var speakerWasSilent = false
        // R2: bounded by the enum's cases.
        for presentation in ProximityResumePresentation.allCases {
            let title = ProximityResumeCopy.title(presentation)
            let body = ProximityResumeCopy.body(presentation)
            if presentation == .nothing {
                // `||`, not `=`: a plain assignment is a LATCH the loop can clear on a later
                // iteration, and `.nothing` is not the last case in `allCases`. It happens to be
                // the only silent one today, so the bug is latent — which is exactly the shape a
                // second silent presentation would make live, silently.
                silenceSpoke = silenceSpoke || (title != nil || body != nil)
            } else if title == nil || body == nil {
                speakerWasSilent = true
            }
        }
        #expect(!silenceSpoke, "`.nothing` is silence: no headline and no second line")
        #expect(!speakerWasSilent, "and every other presentation has both, so a new case has nowhere to hide")
        #expect(ProximityResumePresentation.allCases.count == 11, "three plain cases plus one per ended reason")
        #expect(ProximityResumeCopy.title(.offerResume) != ProximityResumeCopy.title(.couldNotReopen),
                "an offer and a file that would not open are different facts")
        #expect(ProximityResumeCopy.title(.ended(.developed)) != ProximityResumeCopy.title(.offerResume),
                "and an ended mesh is not an offer")
        #expect(ProximityResumeCopy.body(.ended(.ownDeparture)) != ProximityResumeCopy.body(.ended(.developed)),
                "leaving a mesh and developing one are different endings the user can tell apart")
    }

    /// The app's ended-reason vocabulary IS the sealed context's, one token for one token.
    ///
    /// This is what makes pass 2's mapping a one-liner
    /// (`ProximityMeshEndedReason(rawValue: reason.rawValue)`) and what makes a ninth
    /// `MeshSessionTerminationReason` impossible to ship copyless: it reddens here and fails the
    /// exhaustive `switch` in `ProximityResumeCopy.endedBecause(_:)`.
    @Test func theEndedReasonVocabularyIsTheSealedContextsOwn() {
        let appTokens = ProximityMeshEndedReason.allCases.map(\.rawValue)
        let sealedTokens = MeshSessionTerminationReason.allCases.map(\.rawValue)
        #expect(appTokens == sealedTokens, "a reason the sealed context knows and the app does not has no sentence")
        #expect(appTokens.count == 8, "eight reasons; a ninth must fail here before it can ship")
        #expect(appTokens == ["own-departure", "removed-from-roster", "verified-termination", "final-pair",
                              "hard-deadline-signed", "hard-deadline-monotonic", "epoch-counter-exhausted",
                              "developed"],
                "at-rest vocabulary, frozen English — these tokens are read back out of sealed files")
        let mapped = sealedTokens.allSatisfy { ProximityMeshEndedReason(rawValue: $0) != nil }
        #expect(mapped, "and every one of them maps, which is what keeps the product's 522 rows at 522")
    }

    // MARK: - The two walls

    /// Neither new file carries display copy typed `String`.
    ///
    /// `Text(String)` selects the `StringProtocol` overload and renders verbatim, so a `String`
    /// sentence compiles, reads correctly in English and silently leaves every string catalog —
    /// the hole `SessionHeartStatusCopy` was forked out of one phase ago, invisible to both halves
    /// of `LocalizationBoundaryTests`. Each needle is fixtured against a planted line, so a needle
    /// that cannot match what it forbids fails here.
    @Test func neitherNewFileCarriesStringTypedDisplayCopy() throws {
        let sources = try Self.newFileSources()
        #expect(sources.count == 2, "both new app files are in the sweep")
        let typed = sources.contains { $0.contains("-> String") || $0.contains(": String =") }
        #expect(!typed, "display copy is LocalizedStringKey, never String")
        let resolved = sources.contains { $0.contains("String(localized:") }
        #expect(!resolved, "and the app bundle IS Bundle.main, so a bare key literal is the correct form")
        let plantedTyped = "    static func title() -> String { \"That session has ended.\" }"
        #expect(plantedTyped.contains("-> String"), "the needle matches the shape it forbids")
        let plantedResolved = "    static let title = String(localized: \"x\")"
        #expect(plantedResolved.contains("String(localized:"), "and so does the resolved-copy needle")
        let copy = sources.count == 2 ? sources[1] : ""
        #expect(copy.contains("-> LocalizedStringKey"), "non-vacuity: the copy fork really is being scanned")
        #expect(copy.contains("static let resumeButton: LocalizedStringKey ="), "and its held members are keys")
        try Self.expectEveryCopyMemberNamesTheKeyType()
    }

    /// The hole the three needles above cannot see: a HELD member with no type annotation at all.
    ///
    /// `-> String`, `: String =` and `String(localized:` are all spellings that SAY `String`.
    /// `static let notNow = "Not now"` says nothing — Swift infers `String`, `Text(String)` selects
    /// the `StringProtocol` overload, the sentence renders correctly in English and leaves every
    /// string catalog — and pass 1's wall was blind to it, which is the same class of miss
    /// `SessionHeartStatusCopy` was forked out of one phase ago.
    ///
    /// So this half is a POSITIVE claim over the copy fork's whole surface: every `static let` and
    /// every `static func` declared in it names `LocalizedStringKey` on its own declaration line.
    /// That is stronger than a needle list, because it cannot be evaded by a spelling nobody
    /// predicted — an un-annotated literal, a `Substring`, a `StaticString`, an interpolation helper
    /// — and it is why the two frozen accessibility IDENTIFIERS live in `ProximityResumeCard.swift`
    /// and not here: an identifier is a `String` forever, and this file may not hold one.
    private static func expectEveryCopyMemberNamesTheKeyType() throws {
        let copy = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityResumeCopy.swift")
        )
        var members = 0
        var untyped: [String] = []
        // R2: bounded by one file's own lines.
        for line in copy.split(separator: "\n") {
            let code = line.trimmingCharacters(in: .whitespaces)
            guard code.hasPrefix("static let ") || code.hasPrefix("static func ") else { continue }
            members += 1
            if !code.contains("LocalizedStringKey") { untyped.append(code) }
        }
        #expect(members == 6, """
            the copy fork's member count moved without this pin moving — four from pass 1 \
            (resumeButton, title, body, endedBecause) plus pass 2's two dismissal labels
            """)
        #expect(untyped.isEmpty, "a member of the copy fork does not name LocalizedStringKey")
        let planted = "    static let notNow = \"Not now\"".trimmingCharacters(in: .whitespaces)
        #expect(planted.hasPrefix("static let ") && !planted.contains("LocalizedStringKey"),
                "the rule matches the un-annotated shape it forbids")
    }

    /// Neither new file names a radio door: a restore arms nothing.
    ///
    /// `startJoin`, `applyRunState` and `pushNow` are the three spellings that would move a radio
    /// from here. The affordance's action belongs to `ProximityRunPolicyHost` — P7 item 3's zero
    /// wall requires every one of these to live inside `FernletApp.mountRoutedRunPolicy(_:)`, and a
    /// copy file or a decision table reaching around it would be the second writer that wall exists
    /// to forbid.
    @Test func neitherNewFileNamesARadioDoor() throws {
        let sources = try Self.newFileSources()
        let doors = ["startJoin", "applyRunState", "pushNow"]
        let named = doors.contains { door in sources.contains { $0.contains(door) } }
        #expect(!named, "a restore arms no radio (invariant 5); the offer is presented and nothing else")
        let planted = "        store.meshNetworkManager.startJoin()"
        let caught = doors.contains { planted.contains($0) }
        #expect(caught, "the needle list matches the shape it forbids")
        let decision = sources.first ?? ""
        #expect(decision.contains("static func decide(_ inputs: ProximityResumeInputs)"),
                "non-vacuity: the decision file really is being scanned")
    }

    // MARK: - The public projection (pass 2)

    /// The projection's frozen tokens ARE this target's, one for one.
    ///
    /// Pass 1 could only pin the mapping it wished for, because nothing about the restore was
    /// `public`. Pass 2's `MeshSessionResumeProjection.Outcome` is the module's half of that wish,
    /// and this holds the two vocabularies equal in the same shape
    /// ``theEndedReasonVocabularyIsTheSealedContextsOwn()`` holds the ended reasons: a ninth kind
    /// added on either side reddens here, and the exhaustive `switch` in
    /// ``ProximityResumeInputs/kind(of:)`` fails the build beside it.
    @Test func theProjectionsOutcomeVocabularyIsTheAppsOwn() {
        let projected = MeshSessionResumeProjection.Outcome.allCases.map(\.rawValue)
        let app = ProximityRestoreOutcomeKind.allCases.map(\.rawValue)
        #expect(projected == app, "a kind the module knows and this target does not has no clause")
        #expect(projected.count == 8, "eight kinds; a ninth must fail here before it can ship")
        #expect(projected == ["notAttempted", "resumable", "terminated", "expired", "noSession",
                              "deferred", "refused", "corrupt"],
                "frozen diagnostic vocabulary — never display copy, which is ProximityResumeCopy's")
        let mapped = MeshSessionResumeProjection.Outcome.allCases.allSatisfy { token in
            ProximityResumeInputs.kind(of: token).rawValue == token.rawValue
        }
        #expect(mapped, "and every token maps to the app kind of the same name, with none left over")
    }

    /// The module's flattening IS the mapping this suite pinned at pass 1, over all 29 outcomes.
    ///
    /// ``kind(for:)`` was written before `MeshSessionResumeProjection` existed, precisely so pass 2
    /// would implement a mapping that was already enumerated rather than write a second opinion
    /// about it. This is the cell that says it did.
    @Test func theProjectionsFlatteningIsTheMappingThisSuiteAlreadyPinned() {
        var wrong: String?
        // R2: bounded by the enumerated outcome list.
        for outcome in Self.allOutcomes() {
            let flattened = MeshSessionResumeProjection.Outcome(restoring: outcome)
            if flattened.rawValue != Self.kind(for: outcome).rawValue, wrong == nil {
                wrong = outcome?.logToken ?? "nil"
            }
        }
        #expect(wrong == nil, "the module flattened an outcome differently from the pinned mapping")
        #expect(Self.allOutcomes().count == 29,
                "over every outcome value, payload variants included — not a spot check")
    }

    /// **The module boundary loses no row of the product.**
    ///
    /// The strongest form of "the projection is enough": every one of the 522 rows is decided twice
    /// — once from the hand-built ``ProximityResumeInputs`` this suite has always used, and once
    /// through a real `MeshSessionResumeProjection` and `ProximityResumeInputs(projection:)` — and
    /// the two agree. A field dropped or mis-mapped at the boundary shows up as a disagreement here
    /// rather than as a presentation nobody notices.
    @Test func everyRowDecidedThroughTheProjectionMatchesTheRowDecidedByHand() {
        var mismatch: String?
        var rows = 0
        // R2: bounded by the enumerated product.
        for row in Self.productRows() {
            rows += 1
            let projection = MeshSessionResumeProjection(
                outcome: MeshSessionResumeProjection.Outcome(restoring: row.outcome),
                offersForegroundResume: row.offersForegroundResume,
                rejoinBarHit: row.barHitReason
            )
            let crossed = ProximityResumeDecision.decide(ProximityResumeInputs(projection: projection))
            if crossed != ProximityResumeDecision.decide(row.inputs), mismatch == nil {
                mismatch = "\(row.inputs)"
            }
        }
        #expect(rows == 522, "the whole product, not a thinned one")
        #expect(mismatch == nil, "a row decided differently once it crossed the module boundary")
    }

    // MARK: - The manager's own doors (pass 2)

    /// A live context restores into an offer, no bar hit, and no radio.
    @Test func aRestoredLiveContextProjectsAnOfferAndNoBar() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let context = MeshSessionContext(
            meshID: UUID(), protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let launch = try ProximityResumeLaunch(sealing: context, at: created.addingTimeInterval(60))
        let projection = launch.manager.sessionResumeProjection
        #expect(projection.outcome == .resumable, "a live context well inside its ceiling")
        #expect(projection.offersForegroundResume, "the one restore arm that raises the offer")
        #expect(projection.rejoinBarHit == nil, "nothing ended, so no door has refused anything")
        #expect(ProximityResumeDecision.decide(ProximityResumeInputs(projection: projection))
                == .offerResume, "which is the one presentation with an action behind it")
        #expect(launch.manager.currentMesh == nil, "and the restore itself adopted nothing")
        #expect(!launch.manager.isSearching, "and armed no radio — invariant 5")
    }

    /// **The stale-bar negative.** A launch onto an ended context says NOTHING, and the standing bar
    /// never reaches the surface — not for the mesh it names, and not for the next one either.
    ///
    /// The bar is durable and is cleared **nowhere** — `resetSessionStateMachine(keepingTerminalState:)`
    /// says so by name — a `terminated` context is never reaped, and an `expired` one is written back
    /// AS terminated. So a projection that exported it, however it was matched, told the Friends
    /// surface "that session has ended" on every cold start for the rest of the install (pass 2 fix
    /// review, P1-3). Three legs: the ended launch is silent, the standing bar still refuses at the
    /// door where it belongs, and a FRESH mesh in hand is never named ended by the old bar.
    @Test func aTerminatedContextProjectsItsOwnMeshsBarAndNeverAnothers() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let meshID = UUID()
        let context = MeshSessionContext(
            meshID: meshID, protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            localTermination: MeshSessionLocalTermination(reason: .finalPairTermination, at: created)
        )
        let launch = try ProximityResumeLaunch(sealing: context, at: created.addingTimeInterval(60))
        let projection = launch.manager.sessionResumeProjection
        #expect(projection.outcome == .terminated, "the file already records an ending")
        #expect(!projection.offersForegroundResume, "an ended mesh is never offered")
        #expect(projection.rejoinBarHit == nil, "and nothing was HIT: the reader has only opened the app")
        #expect(ProximityResumeDecision.decide(ProximityResumeInputs(projection: projection))
                == .nothing, "so the launch is SILENT — the sentence waits for a try")
        #expect(launch.manager.rejoinBar?.meshID == meshID, "the durable bar names exactly one mesh")
        #expect(launch.manager.rejoinRefusal(for: meshID) == .finalPairTermination,
                "and still refuses at the door, which is where a bar is enforced")
        #expect(launch.manager.rejoinRefusal(for: UUID()) == nil,
                "and refuses nothing for a mesh it was never raised for")
        launch.manager.leaveMesh()
        #expect(launch.manager.rejoinBar?.reason == .finalPairTermination,
                "leaving keeps the durable half: the bar is cleared nowhere")
        #expect(launch.manager.restoredSessionContext == nil, "the restored context is run-scoped and went")
        #expect(launch.manager.sessionResumeProjection.rejoinBarHit == nil,
                "and the projection still names no bar, because none has been hit")
        launch.manager.currentMesh = MeshP3Acceptance.mesh(for: launch.manager)
        #expect(launch.manager.sessionResumeProjection.rejoinBarHit == nil, """
            and a mesh held AFTER the ending is never named ended by the old bar — the defect a \
            global `rejoinBar?.reason` read shipped, with mesh A's reason, about mesh B
            """)
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection)) == .nothing,
            "which the surface reads as silence, beside the session it is actually in")
        launch.manager.leaveMesh()
    }

    /// **Accepting adopts the restored context, clears the offer, and arms nothing.**
    ///
    /// The adoption is the whole point: without it `isInSession` stays false after a relaunch, the
    /// Friends three-way resolves `.fresh`, and the first visit to the tab calls `startJoin()` —
    /// which resets the session state machine and founds a SECOND mesh beside the one on the disk.
    /// The cell states the three-way's answer directly, so the claim is about the shipping decision
    /// and not about a flag.
    @Test func acceptingTheResumeAdoptsTheRestoredContextAndArmsNoRadio() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let meshID = UUID()
        let context = MeshSessionContext(
            meshID: meshID, protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let launch = try ProximityResumeLaunch(sealing: context, at: created.addingTimeInterval(60))
        let audit = ProximityResumeAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        #expect(launch.manager.acceptForegroundResume(now: created.addingTimeInterval(120)) == .accepted,
                "the offer was standing and the context was there")
        #expect(launch.manager.currentMesh?.meshID == meshID, "the restored context IS the mesh now")
        #expect(launch.manager.currentMesh?.createdAt == created,
                "and its creation instant came off the sealed file, so the ceiling still agrees with the mesh")
        #expect(!launch.manager.offersForegroundResume, "the offer is spent")
        #expect(!launch.manager.isSearching, "and NO radio was armed — that push is the run policy's")
        #expect(launch.manager.slots.isEmpty, "nothing was invited and nothing committed")
        #expect(audit.count("mesh.sessionResume.accepted") == 1, "audited exactly once")
        #expect(FriendsDiscoveryEntry.entry(isInSession: launch.manager.isInSession,
                                            hasCommittedPeer: launch.manager.hasCommittedPeer) == .resume,
                "the same three-way every other entry to the Friends surface uses now answers `.resume`")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection)) == .nothing,
            "and the card goes quiet on its own, with no second state to keep in step")
        #expect(launch.manager.acceptForegroundResume(now: created.addingTimeInterval(180))
                == .refused(.noOffer), """
            a second accept is refused rather than re-adopting, and the refusal NAMES its guard — \
            the spent offer, which is the first one it meets
            """)
        #expect(audit.count("mesh.sessionResume.accepted") == 1, "so nothing is audited twice")
        #expect(audit.count("mesh.sessionResume.refused") == 1, "the refusal says so in its own line")
        #expect(audit.reasons(of: "mesh.sessionResume.refused") == ["noOffer"],
                "with the frozen token it has always logged, unchanged by the outcome type")
        launch.manager.leaveMesh()
    }

    /// **Declining clears the offer and adopts nothing** — and a second decline is silent.
    ///
    /// The silence is load-bearing for the app: one `onDismiss` closure serves the offer AND the two
    /// notices, so it calls this for a `couldNotReopen` card too, where there was never an offer to
    /// decline. Nothing durable moves either way: the restored context stays, which is what still
    /// lets an expiry found at launch be written back and a custodied routed item drain.
    @Test func decliningTheResumeClearsTheOfferAndAdoptsNothing() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let meshID = UUID()
        let context = MeshSessionContext(
            meshID: meshID, protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let launch = try ProximityResumeLaunch(sealing: context, at: created.addingTimeInterval(60))
        let audit = ProximityResumeAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        launch.manager.declineForegroundResume()
        #expect(!launch.manager.offersForegroundResume, "the offer is spent")
        #expect(launch.manager.currentMesh == nil, "a decline adopts nothing")
        #expect(launch.manager.restoredSessionContext?.meshID == meshID,
                "and keeps the restored context, which is still the writer's identity for a launch expiry")
        #expect(!launch.manager.isSearching, "and arms nothing, exactly like the restore before it")
        #expect(audit.count("mesh.sessionResume.declined") == 1, "audited exactly once")
        launch.manager.declineForegroundResume()
        #expect(audit.count("mesh.sessionResume.declined") == 1,
                "a decline with no offer standing is silent, so one dismissal closure can serve the notices too")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection)) == .nothing,
            "and the offer is not re-presented on the next visit to the tab")
    }

    /// **The hit is raised by a refused TRY and cleared by the next founding** (pass 2 fix review,
    /// P1-3f) — the whole life of the fact the `ended` clause now reads.
    ///
    /// Three phases on real managers: an ended context restored at launch publishes NO hit (the
    /// silence the fix exists for); an offer answered after the session ended underneath it is
    /// refused at the bar, which is the user trying, and the refusal names the reason; and founding
    /// the next mesh takes the notice down, because the hit is run-scoped and
    /// `resetSessionStateMachine(keepingTerminalState:)` — which every founding runs — clears it.
    ///
    /// The try is driven through `acceptForegroundResume(now:)`, the one barred door a cell can
    /// reach: the descriptor and admission-grant doors are `private` and need a committed slot and a
    /// sealed envelope to enter, while this one is public and takes the same `rejoinRefusal(for:)`
    /// answer. The departure raises the bar for the RESTORED mesh (`barRejoin(reason:)` coalesces
    /// `currentMesh` then `restoredSessionContext`) and resets nothing, so the offer is still
    /// standing when the user taps — which is exactly the race the sentence exists for.
    @Test func aRejoinBarHitIsRaisedByARefusedTryAndClearedByTheNextFounding() throws {
        let created = Date(timeIntervalSince1970: 1_800_000_000)
        let ended = MeshSessionContext(
            meshID: UUID(), protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds),
            localTermination: MeshSessionLocalTermination(reason: .verifiedTerminationRecord, at: created)
        )
        let atLaunch = try ProximityResumeLaunch(sealing: ended, at: created.addingTimeInterval(60))
        #expect(atLaunch.manager.lastRejoinBarHit == nil, "a launch refuses nothing: nobody has tried")
        #expect(atLaunch.manager.sessionResumeProjection.rejoinBarHit == nil,
                "so the projection carries no hit, and the card says nothing on this cold start")
        let live = MeshSessionContext(
            meshID: UUID(), protocolVersion: 3, createdAt: created,
            hardDeadline: created.addingTimeInterval(MeshSessionCeiling.ceilingSeconds)
        )
        let launch = try ProximityResumeLaunch(sealing: live, at: created.addingTimeInterval(60))
        _ = DeviceBindingID.$testOverride.withValue(.identifier(ProximityResumeLaunch.install)) {
            launch.manager.applySessionEvent(.departureRequested)
        }
        #expect(launch.manager.rejoinRefusal(for: live.meshID) == .ownDeparture, "the bar is up for that mesh")
        #expect(launch.manager.offersForegroundResume, "and the offer the card is showing still stands")
        #expect(launch.manager.acceptForegroundResume(now: created.addingTimeInterval(120))
                == .refused(.rejoinBarred(.ownDeparture)), "so the tap is refused, and the refusal says why")
        #expect(launch.manager.lastRejoinBarHit == .ownDeparture, "which is the HIT this run")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection))
            == .ended(.ownDeparture), "and the card answers in the same turn: that session has ended")
        #expect(launch.manager.currentMesh == nil, "the refused try adopted nothing")
        _ = DeviceBindingID.$testOverride.withValue(.identifier(ProximityResumeLaunch.install)) {
            launch.manager.promoteToMeshForTesting()
        }
        #expect(launch.manager.lastRejoinBarHit == nil, "founding the next mesh takes the notice down with it")
        #expect(ProximityResumeDecision.decide(
            ProximityResumeInputs(projection: launch.manager.sessionResumeProjection)) == .nothing,
            "so a session that really started is never captioned with the last one's ending")
        launch.manager.leaveMesh()
    }

    /// **An unanswered offer HOLDS the fresh search**, and answering it releases the hold.
    ///
    /// The collision this closes is not hypothetical and it is what makes the whole affordance
    /// reachable: the run policy's discovery directive is `foregroundOnly` for the Friends tab, so
    /// the first visit after a relaunch pushes `run` at
    /// `MeshNetworkManager.applyRunState(links:discovery:)`, `armFriendRadios()` resolves `.fresh`
    /// (nothing is adopted yet), and `startJoin()` ends in
    /// `resetSessionStateMachine(keepingTerminalState: false)` — which clears
    /// `offersForegroundResume`, `restoredSessionContext` and the ceiling. The offer would be gone
    /// before the card could be drawn, and the sentence the card shows ("It isn't looking for anyone
    /// until you say so") would be false at the instant it appeared.
    ///
    /// The restore is driven through the state machine's own arm rather than a sealed file: the
    /// `.resumable` disposition is the one that raises `offerForegroundResume`, which is the flag
    /// under test, and nothing else about the launch matters to this row.
    @Test func aStandingResumeOfferHoldsTheFreshSearchUntilItIsAnswered() {
        let audit = ProximityResumeAuditCapture()
        audit.install()
        defer { audit.uninstall() }
        // The host is held for the manager's whole life (rule ML5): `store` is `unowned`.
        let host = makeTestStore()
        let manager = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        defer { manager.stopJoin() }
        manager.applySessionEvent(.contextRestored(.resumable))
        #expect(manager.offersForegroundResume, "the restore raised the offer")
        #expect(!manager.isInSession, "and adopted nothing, so the three-way reads `.fresh`")

        manager.applyRunState(links: .run, discovery: .run)

        #expect(!manager.isSearching,
                "a fresh search would have wiped the offer and the restored context before the card was drawn")
        #expect(audit.reasons(of: ProximityRunStateSeam.held) == [ProximityRunStateSeam.resumeOffered],
                "and the hold has a name rather than being a silence")
        manager.declineForegroundResume()

        manager.applyRunState(links: .run, discovery: .run)

        #expect(manager.isSearching, "once the offer is answered the ordinary fresh search arms")
        #expect(audit.count(ProximityRunStateSeam.applied) == 1, "and says so exactly once")
    }

    // MARK: - The third wall (pass 2)

    /// **The resume is accepted in ONE place, and that place hands the radios straight back.**
    ///
    /// `acceptForegroundResume(` arms no radio, so it is not a needle for P7 item 3's zero wall and
    /// deliberately does not join the receiver-agnostic listener sweep either — adding it there
    /// would say something false about what it does. It owes its own wall for a different reason:
    /// adopting a mesh without re-deciding the policy leaves a device holding a session with the
    /// radios still standing where the last push left them, and adopting it from two places would be
    /// two owners of one act.
    ///
    /// Four claims, each counted rather than asserted: exactly one occurrence of each door across
    /// the whole app target; each inside the brace-matched body of its own action
    /// (`resumeLastSession()`, `dismissResumeCard()`), with `runPolicyHost.pushNow()` AFTER it; and
    /// the card itself naming no radio, no door and no manager, because it is a pure view over a
    /// decided value.
    ///
    /// **The decline is walled beside the accept** (pass 2 fix review, P2-1). It is the other half of
    /// one answer and it has the same two-owner failure mode: the offer HOLDS the fresh search
    /// (`ProximityRunStateSeam.resumeOffered`), so a decline that did not re-decide the policy would
    /// leave the radios held for a hold nobody is under any more, and a second call site would be a
    /// second owner of the user's "not now".
    @Test func theResumeAcceptanceHasOneAppCallSiteAndHandsTheRadiosBack() throws {
        let sources = try ProximityRunPolicyHostTests.appSources()
        #expect(!sources.isEmpty, "the App/ sweep found no Swift files at all")
        #expect(sources.contains(where: { $0.name == "ProximityResumeCard.swift" }),
                "the sweep no longer reaches the card, so every count below is vacuous")
        var sites: [String] = []
        var declineSites: [String] = []
        var calls = 0
        var declines = 0
        // R2: bounded by the app target's own file list.
        for source in sources {
            let hits = ProximityRunPolicyHostTests.occurrences(of: "acceptForegroundResume(", in: source.code)
            let declined = ProximityRunPolicyHostTests.occurrences(of: "declineForegroundResume(", in: source.code)
            calls += hits
            declines += declined
            if hits > 0 { sites.append(source.name) }
            if declined > 0 { declineSites.append(source.name) }
        }
        #expect(sites == ["ConnectView.swift"], "the resume is accepted from exactly one file")
        #expect(calls == 1, "and from exactly one call site inside it")
        #expect(declineSites == ["ConnectView.swift"], "and declined from exactly one file")
        #expect(declines == 1, "and from exactly one call site inside it")
        try Self.expectTheAcceptanceHandsTheRadiosBack()
        try Self.expectTheDeclineHandsTheRadiosBack()
    }

    /// The decline's half of the third wall: one action, and the policy re-decided after it.
    private static func expectTheDeclineHandsTheRadiosBack() throws {
        let connect = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ConnectView.swift")
        )
        let action = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func dismissResumeCard(", in: connect),
            "the dismissal action was renamed, or its brace-matched body does not close"
        )
        let decline = try #require(action.range(of: "declineForegroundResume("),
                                   "the one decline no longer sits inside the dismissal action")
        let push = try #require(action.range(of: "runPolicyHost.pushNow()"), """
            the dismissal no longer hands the radios back, so the fresh search would stay held for \
            an offer the user has already answered
            """)
        #expect(decline.lowerBound < push.lowerBound,
                "the policy is re-decided AFTER the offer is cleared, or the hold is still standing")
    }

    /// **An accepted resume raises the session surface the tab chrome already assumes** (pass 2 fix
    /// review, P1-1).
    ///
    /// The strand is a two-predicate disagreement, so it is stated over both: the accept sets
    /// `currentMesh`, `ContentView.isDisposableCameraSessionActive` reads `isInSession` alone and
    /// dresses the Social tab in camera chrome (no tab bar, no bottom clearance, dark background),
    /// while `FriendsView.body` swaps to the camera on `isInSession && sessionReady` — and nothing
    /// on the resume path wrote `sessionReady`. The album would have been drawn in camera chrome
    /// with no tab bar to leave by. A source cell rather than a behaviour one because the flag is
    /// `@State` on a `View`: the two spellings that must agree are both in source, and the tap
    /// itself is `ProximityResumeCardUITests`'s.
    @Test func theAcceptedResumeRaisesTheSessionSurfaceTheTabChromeAssumes() throws {
        let connect = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ConnectView.swift")
        )
        let action = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func resumeLastSession(", in: connect),
            "the resume action was renamed, or its brace-matched body does not close"
        )
        #expect(action.contains("sessionReady = true"), """
            an accepted resume no longer raises the session surface: `isInSession` flips, the tab \
            loses its bar to the camera chrome, and `body` keeps drawing the album underneath it
            """)
        #expect(action.contains("== .accepted"),
                "and it raises it for an ACCEPT alone — a refused try adopts nothing and shows a notice")
        #expect(connect.contains("if manager.isInSession && sessionReady {"),
                "non-vacuity: the swap the flag exists for is still the predicate it is read by")
        let content = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ContentView.swift")
        )
        let chrome = try #require(
            MeshRoutedSourceScan.bracedBody(
                after: "private var isDisposableCameraSessionActive: Bool", in: content
            ),
            "the camera-chrome predicate was renamed, so the disagreement below is unmeasured"
        )
        #expect(chrome.contains("meshNetworkManager.isInSession"),
                "the chrome half still reads `isInSession` — which is why the accept must raise the flag")
        #expect(!chrome.contains("sessionReady"),
                "and it cannot read a view's `@State`, which is exactly why the two can disagree")
    }

    /// **A SILENT presentation never leaves the Friends search held** (P7 post-close review, P2-1).
    ///
    /// Two rules that can disagree, and the disagreement is a device that cannot search. The hold is
    /// the mesh seam's: `MeshNetworkManager.armFriendRadios()`'s `.fresh` row refuses to call
    /// `startJoin()` while `offersForegroundResume` stands, and records
    /// `ProximityRunStateSeam.resumeOffered`. The affordance is this table's: clause 3 runs BEFORE
    /// clause 4, so `notAttempted`, `deferred` and `refused` answer ``ProximityResumePresentation/nothing``
    /// **whatever the offer says**, and `ProximityResumeCard` draws that as an `EmptyView`. A
    /// standing offer behind a silent presentation is therefore a held search with no accept and no
    /// decline anywhere on screen — a Friends tab that can never look for anyone, for the rest of
    /// the launch.
    ///
    /// Shipping cannot reach the pair today (the restore writes the outcome and the offer in one
    /// breath, and the second raiser needs a `.foregrounded` nothing raises until P8), but the
    /// walled `FERNLET_MESH_RESUME_PRESENTATION=nothing` override substitutes the whole decision, so
    /// a simulator holding a sealed context inside its ceiling launches straight into it under
    /// `ProximityResumeCardUITests.testNothingPresentsNoCardAtAll`.
    ///
    /// **A source cell, and it pins the ROUTE as well as the rule.** The release must go through
    /// `dismissResumeCard()` — the card's own dismissal — rather than call the manager again,
    /// because ``theResumeAcceptanceHasOneAppCallSiteAndHandsTheRadiosBack()`` counts
    /// `declineForegroundResume(` across the whole app target and requires exactly one. One door,
    /// two reasons to walk through it.
    @Test func theSilentPresentationReleasesTheHeldSearchThroughTheDismissPath() throws {
        let connect = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ConnectView.swift")
        )
        let release = try #require(
            MeshRoutedSourceScan.bracedBody(
                after: "private func releaseTheHeldSearchIfTheCardSaysNothing(", in: connect
            ),
            "the silent-presentation release was renamed, or its brace-matched body does not close"
        )
        #expect(release.contains("resumePresentation == .nothing"),
                "the release no longer keys on the SILENT presentation, so it releases the wrong thing")
        #expect(release.contains("sessionResumeProjection.offersForegroundResume"), """
            the release no longer keys on a STANDING offer: it is idempotent only because the \
            decline spends the flag the guard reads
            """)
        #expect(release.contains("dismissResumeCard()"), """
            the release no longer routes through the card's one dismiss path, so either the offer is \
            never spent or the decline has a second app call site
            """)
        #expect(!release.contains("declineForegroundResume("),
                "the release calls the manager itself, which is the second call site the third wall forbids")
        #expect(!release.contains("runPolicyHost.pushNow()"),
                "the release pushes the policy itself instead of leaving that to the dismissal it calls")
        try Self.expectTheSilentReleaseIsWiredOnAppearAndOnChange(connect)
    }

    /// The wiring half of the silent-presentation release: on appear, and on every rise of the offer.
    ///
    /// Split from the cell above only to stay inside the 60-line rule; the two are one claim. The
    /// watched fact is the OFFER rather than the presentation, because the presentation does not
    /// move when the offer rises behind a silent outcome — `.nothing` before and `.nothing` after —
    /// so an `onChange` over it would never fire for the one transition this exists to catch.
    ///
    /// - Parameter connect: `ConnectView.swift`, comments stripped.
    private static func expectTheSilentReleaseIsWiredOnAppearAndOnChange(_ connect: String) throws {
        let calls = ProximityRunPolicyHostTests.occurrences(
            of: "releaseTheHeldSearchIfTheCardSaysNothing()", in: connect
        )
        #expect(calls == 3, """
            the release is declared once and called twice — from onAppear and from the offer's \
            onChange — so three occurrences is the whole wiring
            """)
        let appear = try #require(MeshRoutedSourceScan.bracedBody(after: ".onAppear", in: connect),
                                  "the Friends surface's first onAppear does not close")
        #expect(appear.contains("releaseTheHeldSearchIfTheCardSaysNothing()"), """
            a launch that lands on the Friends tab with the offer already standing never releases \
            the hold, because nothing after it changes
            """)
        #expect(appear.contains("presentDisconnectReviewIfNeeded()"),
                "non-vacuity: the matched body really is FriendsView's own onAppear")
        #expect(connect.contains("onChange(of: manager.sessionResumeProjection.offersForegroundResume)"),
                "an offer that rises after this surface appeared would hold the search unreleased")
    }

    /// The containment half of the third wall, split out only to stay inside the 60-line rule.
    private static func expectTheAcceptanceHandsTheRadiosBack() throws {
        let connect = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ConnectView.swift")
        )
        let action = try #require(
            MeshRoutedSourceScan.bracedBody(after: "private func resumeLastSession(", in: connect),
            "the resume action was renamed, or its brace-matched body does not close"
        )
        let accept = try #require(action.range(of: "acceptForegroundResume("),
                                  "the one acceptance no longer sits inside the resume action")
        let push = try #require(action.range(of: "runPolicyHost.pushNow()"), """
            the resume action no longer hands the radios back, so a resumed mesh would sit with the \
            radios wherever the last policy push left them
            """)
        #expect(accept.lowerBound < push.lowerBound,
                "the policy is re-decided AFTER the adoption, or it re-decides against the old facts")
        let card = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/ProximityResumeCard.swift")
        )
        #expect(card.contains("let presentation: ProximityResumePresentation"),
                "non-vacuity: the card really is being scanned")
        let forbidden = ["startJoin", "applyRunState", "pushNow", "acceptForegroundResume",
                         "meshNetworkManager", "MeshNetworkManager"]
        let named = forbidden.first { card.contains($0) }
        #expect(named == nil, "the card is a pure view: it names no radio, no door and no manager")
    }
}

// MARK: - Fixtures for the manager's doors

/// One launch whose restore has already run, with the host kept alive beside the manager.
///
/// `MeshNetworkManager` holds its `ProximityHost` **`unowned`**, so a cell that dropped the store
/// would be reading a dangling reference the moment the manager touched `displayName`. Binding one
/// of these for the whole cell is what keeps the pair together.
@MainActor
private final class ProximityResumeLaunch {

    /// A pinned install identity, so every seal here is deterministic rather than whatever the
    /// simulator's real device-binding row happens to be.
    static let install = Data(repeating: 0x52, count: 16)

    /// The host the manager is `unowned` on.
    let store: FernletStore

    /// The manager, with its one launch restore already taken.
    let manager: MeshNetworkManager

    /// Seals `context` into a fresh, per-test session scope and runs the launch mount over it.
    ///
    /// **The radio is the in-memory fake**, not this build's. Every cell here asserts that nothing
    /// arms a radio, and one of them founds the next mesh (`promoteToMeshForTesting()`), whose
    /// success ends in `updateDiscoveryInfo()` — a real `MeshMultipeerSession` would start a live
    /// advertiser out of a unit test. The fake changes nothing else: `isSearching` is the manager's
    /// own flag either way.
    ///
    /// `_ =` on the binding because the closure YIELDS: `restoreSessionContextOncePerLaunch(now:)`
    /// answers a `Bool`, so a single-expression closure makes `withValue` return one (pass 2 fix
    /// review, P2-5).
    ///
    /// - Parameters:
    ///   - context: The sealed context this launch finds on the disk.
    ///   - now: The instant the restore judges the ceiling against.
    init(sealing context: MeshSessionContext, at now: Date) throws {
        let host = makeTestStore()
        let sessionStore = MeshSessionStore(scope: host.meshSessionStorage)
        try MeshSessionStoreFixtures.save(context, into: sessionStore, install: Self.install)
        let restored = MeshNetworkManager(store: host, transport: FakeMeshTransportSession())
        _ = DeviceBindingID.$testOverride.withValue(.identifier(Self.install)) {
            restored.restoreSessionContextOncePerLaunch(now: now)
        }
        store = host
        manager = restored
    }
}

/// Counts audit events for one cell, installed on entry and removed by token before the cell ends.
///
/// `FernletAuditLog`'s registry is process-wide and unscoped, so the filter is the exact frozen
/// event name — and the three names counted here (`mesh.sessionResume.accepted` / `.refused` /
/// `.declined`) are emitted by nothing else in the tree.
private final class ProximityResumeAuditCapture {

    /// Guards ``storedEvents`` — the handler is invoked from whatever executor logged.
    private let lock = NSLock()

    /// Every (event name, `reason` context value) pair seen since ``install()``.
    private var storedEvents: [(event: String, reason: String?)] = []

    /// The registry token, so the handler does not outlive the cell that installed it.
    private var token: UUID?

    /// Starts capturing.
    func install() {
        token = FernletAuditLog.addCaptureHandler { [weak self] event, context in
            guard let self else { return }
            self.lock.lock()
            self.storedEvents.append((event, context["reason"]))
            self.lock.unlock()
        }
    }

    /// Stops capturing.
    func uninstall() {
        if let token {
            FernletAuditLog.removeCaptureHandler(token)
            self.token = nil
        }
    }

    /// How many times `event` was logged.
    ///
    /// - Parameter event: The frozen event name.
    /// - Returns: its count.
    func count(_ event: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents.filter { $0.event == event }.count
    }

    /// The `reason` context value of every `event` line, in order.
    ///
    /// - Parameter event: The frozen event name.
    /// - Returns: one entry per line, with a missing reason spelled `"—"` so a reasonless line is
    ///   visible in a failure rather than dropped.
    func reasons(of event: String) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents.filter { $0.event == event }.map { $0.reason ?? "—" }
    }
}
