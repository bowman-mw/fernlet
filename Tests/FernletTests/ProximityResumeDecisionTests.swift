// ProximityResumeDecisionTests.swift
// FernletTests
//
// Network migration P7 item 5, pass 1 (plan §24.1, prompt §5c): the launch restore's DECISION half,
// as a table.
//
// `ProximityResumeDecision.decide(_:)` is a pure function over three enumerable facts, so this
// suite enumerates the WHOLE product — every `MeshSessionRestoreOutcome` case with every payload
// variant that can be constructed (29 outcome values, nil included) × both offer flags × every
// rejoin-bar reason plus nil = 522 rows — and holds each row against an INDEPENDENT oracle.
//
// The oracle is not a second spelling of the policy. It takes the RAW outcome and answers from
// ProximityKit's own vocabulary — the `quarantineCorruptFile` case itself and
// `MeshSessionRestoreOutcome.isRetryable` — rather than from the app's flattened
// `ProximityRestoreOutcomeKind`, and it is written as the decisions table's ordered clauses: the
// bar first (an offer to resume a barred mesh is an offer the admission door would refuse), then
// the corrupt file, then the retryable silence, then the offer.
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

    /// The rejoin bar's reason as the sealed context spells it, or nil for no bar.
    let barReason: MeshSessionTerminationReason?

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

    /// The rejoin bar's reason, or nil for no bar.
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

    /// Every rejoin-bar reason the product runs over, nil first.
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
    /// - Parameters:
    ///   - outcome: The raw outcome.
    ///   - offers: `offersForegroundResume`.
    ///   - barReason: The raw bar reason, or nil.
    /// - Returns: the row, raw facts and flattened inputs together.
    static func row(
        outcome: MeshSessionRestoreOutcome?,
        offers: Bool,
        barReason: MeshSessionTerminationReason?
    ) -> ProximityResumeProductRow {
        let inputs = ProximityResumeInputs(
            outcome: kind(for: outcome),
            offersForegroundResume: offers,
            rejoinBarReason: barReason.flatMap { ProximityMeshEndedReason(rawValue: $0.rawValue) }
        )
        return ProximityResumeProductRow(
            outcome: outcome, barReason: barReason, offersForegroundResume: offers, inputs: inputs
        )
    }

    /// The whole product: 29 outcomes × 2 offer flags × 9 bar reasons = 522 rows.
    ///
    /// - Returns: every row, enumerated.
    static func productRows() -> [ProximityResumeProductRow] {
        var rows: [ProximityResumeProductRow] = []
        for outcome in allOutcomes() {
            for offers in [false, true] {
                for barReason in barReasons() {
                    rows.append(row(outcome: outcome, offers: offers, barReason: barReason))
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
    /// - Parameter row: One row of the product.
    /// - Returns: what the decisions table says that row presents.
    static func oracle(_ row: ProximityResumeProductRow) -> ProximityResumePresentation {
        if let reason = row.barReason, let ended = ProximityMeshEndedReason(rawValue: reason.rawValue) {
            return .ended(ended)
        }
        if let outcome = row.outcome, case .quarantineCorruptFile = outcome { return .couldNotReopen }
        if row.outcome?.isRetryable == true { return .nothing }
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
        #expect(Self.barReasons().count == 9, "eight sealed reasons that map, plus no bar at all")
        #expect(rows.count == 522, "29 outcome values × 2 offer flags × 9 bar reasons — the whole product")
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
                "a row disagreed with the decisions table: bar, then corrupt, then the retryable silence, then the offer")
        #expect(seen == ["nothing", "offerResume", "couldNotReopen", "ended"],
                "and all four presentations are reached, so the agreement is not one answer everywhere")
    }

    /// The nine (outcome, offer, bar) shapes a real launch can produce, each with a literal.
    ///
    /// Read off the shipping restore's own arms rather than off the policy:
    /// `MeshSessionStateMachine.restored(_:)` raises `offerForegroundResume` for `.resumable` and
    /// nothing at all for `.none`; `restoreSessionContextAtLaunch(now:)` sets the bar directly on the
    /// `terminated` arm; and the `.expired` arm's `markTerminated` reaches `barRejoin(reason:)` with
    /// `hardDeadlineSigned`, because `MeshSessionEvent.contextRestored(.expired)` is the one
    /// disposition that writes a reason.
    @Test func theReachableLaunchOutcomesArePresentedAsTheRestoreArmsThem() {
        let rows = [
            ProximityResumeReachableRow(outcome: .notAttempted, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .noSession, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .deferred, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .refused, offers: false, bar: nil, shows: .nothing),
            ProximityResumeReachableRow(outcome: .corrupt, offers: false, bar: nil, shows: .couldNotReopen),
            ProximityResumeReachableRow(outcome: .resumable, offers: true, bar: nil, shows: .offerResume),
            ProximityResumeReachableRow(outcome: .terminated, offers: false, bar: .ownDeparture,
                                        shows: .ended(.ownDeparture)),
            ProximityResumeReachableRow(outcome: .terminated, offers: false, bar: .verifiedTerminationRecord,
                                        shows: .ended(.verifiedTerminationRecord)),
            ProximityResumeReachableRow(outcome: .expired, offers: false, bar: .hardDeadlineSigned,
                                        shows: .ended(.hardDeadlineSigned))
        ]
        #expect(rows.count == 9,
                "the five state-machine arms, the terminated arm's two flavours, the quarantine and the nil outcome")
        var wrong: String?
        // R2: bounded by the list above.
        for row in rows {
            let inputs = ProximityResumeInputs(
                outcome: row.outcome, offersForegroundResume: row.offers, rejoinBarReason: row.bar
            )
            let decided = ProximityResumeDecision.decide(inputs)
            if decided != row.shows, wrong == nil {
                wrong = "\(row.outcome.rawValue) decided \(Self.label(decided))"
            }
        }
        #expect(wrong == nil, "a launch the shipping restore can really produce was presented wrongly")
    }

    // MARK: - The four presentations, one at a time

    /// A deferral says nothing, and that silence is a positive claim.
    ///
    /// `retryAfterUnlock` and `retryAfterRefusal` are both retried by the routed re-entry's job 1
    /// at the next protected-data rise, bounded by `MeshSessionRestoreBounds.maxAttempts`, so a
    /// sentence about either would be a cold-start apology for something about to succeed.
    @Test func aDeferredRestoreSaysNothingAtAll() {
        let deferred = ProximityResumeInputs(
            outcome: .deferred, offersForegroundResume: false, rejoinBarReason: nil
        )
        #expect(ProximityResumeDecision.decide(deferred) == .nothing,
                "a deferral retries at the next protected-data rise and is never read as emptiness OR as news")
        let refused = ProximityResumeInputs(
            outcome: .refused, offersForegroundResume: false, rejoinBarReason: nil
        )
        #expect(ProximityResumeDecision.decide(refused) == .nothing,
                "custody's refusal is retried the same way and says the same nothing")
        let staleOffer = ProximityResumeInputs(
            outcome: .deferred, offersForegroundResume: true, rejoinBarReason: nil
        )
        #expect(ProximityResumeDecision.decide(staleOffer) == .nothing,
                "and a restore that read nothing this launch offers nothing, whatever an earlier idle lapse left set")
        let notAttempted = ProximityResumeInputs(
            outcome: .notAttempted, offersForegroundResume: false, rejoinBarReason: nil
        )
        #expect(ProximityResumeDecision.decide(notAttempted) == .nothing,
                "and the window before the launch mount has run is silent too")
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
            outcome: .corrupt, offersForegroundResume: false, rejoinBarReason: nil
        )
        #expect(ProximityResumeDecision.decide(inputs) == .couldNotReopen,
                "the one outcome that owes the user a sentence")
        let offered = ProximityResumeInputs(
            outcome: .corrupt, offersForegroundResume: true, rejoinBarReason: nil
        )
        #expect(ProximityResumeDecision.decide(offered) == .couldNotReopen,
                "and a file that did not decode is never offered as a resume")
        let title: LocalizedStringKey? = "Your last session couldn't be reopened."
        #expect(ProximityResumeCopy.title(.couldNotReopen) == title, "frozen key; the catalog sync harvests it")
        let body: LocalizedStringKey? = "Nothing you shared was lost — it stays sealed on this device."
        #expect(ProximityResumeCopy.body(.couldNotReopen) == body,
                "the reassurance is half the decision, not decoration")
    }

    /// A rejoin bar names the mesh as ENDED, never as failed, and it outranks the offer.
    ///
    /// Clause 1 of the table, and the clause worth a cell of its own: offering to resume a mesh this
    /// device may never re-enter is an offer `rejoinRefusal(for:)` would refuse at both doors.
    @Test func aRejoinBarNamesTheMeshAsEndedAndOutranksTheOffer() {
        var wrong: String?
        // R2: bounded by the enum's cases.
        for reason in ProximityMeshEndedReason.allCases {
            let inputs = ProximityResumeInputs(
                outcome: .resumable, offersForegroundResume: true, rejoinBarReason: reason
            )
            if ProximityResumeDecision.decide(inputs) != .ended(reason), wrong == nil {
                wrong = reason.rawValue
            }
        }
        #expect(wrong == nil, "a barred mesh is ENDED even where the manager still offers a resume")
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

    /// The offer offers, and promises no reconnection.
    ///
    /// A restore arms no radio (invariant 5), so the second line says what is true: Fernlet is not
    /// looking for anyone until the user says so. The action behind the button is pass 2's.
    @Test func anOfferedResumeIsAnOfferAndPromisesNoReconnection() {
        let inputs = ProximityResumeInputs(
            outcome: .resumable, offersForegroundResume: true, rejoinBarReason: nil
        )
        #expect(ProximityResumeDecision.decide(inputs) == .offerResume, "the one affordance the restore earns")
        let noOffer = ProximityResumeInputs(
            outcome: .resumable, offersForegroundResume: false, rejoinBarReason: nil
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
                silenceSpoke = title != nil || body != nil
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
        #expect(copy.contains("static let resumeButton: LocalizedStringKey ="), "and its one held member is a key")
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
}
