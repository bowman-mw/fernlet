// MeshContinuationCardPresentationTests.swift
// FernletTests
//
// Network migration P8 item 7: the card table, whole. Every pair of (claim state × the token that
// named its last move) is answered — the 23 that show a card are DATA below, and the other 37 must
// show none — so a row that changes its mind has to change this table too, rather than a helper
// that re-derives the same `switch` and proves nothing.
//
// `SessionResumeCopyTests` is the idiom: the copy table, then the surface wall. The claims this
// file adds beyond that one are P8's own — the card survives the session ENDING (item 4's
// `completed` is the terminal after any end, task or no task), and the store's projection is
// OBSERVED, because a derived or `@ObservationIgnored` read would never repaint the refusal onto
// the screen.
//
// Three of them are driven through item 4's REAL table rather than by hand, because that is where
// the fix review found the table's `completed` rows dead: `transition(from: .refused, on:
// .sessionEnded)` carries the token `completed`, so a driver recording `outcome.audit` blindly would
// erase the refusal — `projectedAudit` is the rule that does not, the ended cards speak in the past
// tense, and `slotDecision` yields the shared banner slot to P7's resume card in exactly the window
// where a resumable session is the more useful truth.

import Foundation
import SwiftUI
import Testing
@testable import Fernlet

/// The presentation table, the sentences, and the Friends surface's one read of the projection.
@Suite struct MeshContinuationCardPresentationTests {

    /// Every audit the projection can carry, plus "nothing yet".
    private static let audits: [MeshContinuationAudit?] =
        [nil] + MeshContinuationAudit.allCases.map { Optional($0) }

    /// **The table.** Every (state, audit) pair that shows a card, and which one. Any pair absent
    /// from this list must show none.
    ///
    /// `refused` says the same true thing whatever token brought it there, so the state decides.
    /// `expired` parts on one token only — `cancelled`, which is iOS ending a task before its time
    /// rather than the time running out. `completed` is the terminal after ANY session end, so it
    /// shows a card only when the token it was handed still names a spent claim.
    private static let presenting: [(MeshContinuationState, MeshContinuationAudit?, MeshContinuationCardKind)] = [
        (.refused, nil, .refused),
        (.refused, .registered, .refused),
        (.refused, .submitted, .refused),
        (.refused, .started, .refused),
        (.refused, .refused, .refused),
        (.refused, .expired, .refused),
        (.refused, .cancelled, .refused),
        (.refused, .completed, .refused),
        (.refused, .meshChanged, .refused),
        (.refused, .absorbed, .refused),
        (.expired, nil, .expired),
        (.expired, .registered, .expired),
        (.expired, .submitted, .expired),
        (.expired, .started, .expired),
        (.expired, .refused, .expired),
        (.expired, .expired, .expired),
        (.expired, .cancelled, .endedBySystem),
        (.expired, .completed, .expired),
        (.expired, .meshChanged, .expired),
        (.expired, .absorbed, .expired),
        (.completed, .refused, .refused),
        (.completed, .expired, .expired),
        (.completed, .cancelled, .endedBySystem)
    ]

    /// The whole product is answered, and exactly the table's pairs show a card.
    @Test func everyClaimIsAnsweredAndOnlyTheTableShowsACard() {
        #expect(Self.audits.count == 10, "nine tokens plus no token at all")
        #expect(MeshContinuationState.allCases.count == 6, "item 4's six states")
        #expect(Self.presenting.count == 23, "the table's rows — change the table, not the count")
        // R2: bounded by 6 × 10.
        for state in MeshContinuationState.allCases {
            for audit in Self.audits {
                let expected = Self.presenting.first { $0.0 == state && $0.1 == audit }?.2
                let shown = MeshContinuationCardPresentation.card(state: state, lastAudit: audit)
                #expect(shown?.kind == expected, """
                    claim \(state.rawValue) × \(audit?.rawValue ?? "no token") should present \
                    \(expected?.rawValue ?? "no card"), presented \(shown?.kind.rawValue ?? "no card")
                    """)
            }
        }
    }

    /// A claim that is idle, asked for, or running says nothing at all: the card is for endings.
    @Test func aLiveOrFreshClaimSaysNothing() {
        // R2: bounded by 3 × 10.
        for state in [MeshContinuationState.idle, .requested, .running] {
            for audit in Self.audits {
                #expect(MeshContinuationCardPresentation.card(state: state, lastAudit: audit) == nil,
                        "\(state.rawValue) is not an ending — it has nothing to explain")
            }
        }
    }

    /// The ending survives the session's own ending — item 4's `completed` keeps the token's news.
    @Test func anEndedSessionStillSaysWhichEndingItWas() {
        // R2: bounded by the kind list.
        for kind in MeshContinuationCardKind.allCases {
            let duringSession = MeshContinuationCardPresentation.card(
                state: kind.presentingState, lastAudit: kind.presentingAudit
            )
            let afterEnding = MeshContinuationCardPresentation.card(
                state: .completed, lastAudit: kind.presentingAudit
            )
            #expect(duringSession?.kind == kind, "the claim that presents \(kind.rawValue) presents it")
            #expect(afterEnding?.kind == kind, "and the 6-hour ceiling ending the session does not erase it")
        }
        #expect(MeshContinuationCardPresentation.card(state: .completed, lastAudit: .completed) == nil,
                "but a session that simply ended shows no card")
    }

    /// **The ending must survive the claim's own session end.** Item 4's `sessionEnded` row carries
    /// the token `completed`, so a driver that records `outcome.audit` blindly erases the refusal
    /// exactly as the six-hour ceiling fires — which is why `projectedAudit` exists and why item 6
    /// writes the projection through it.
    @Test func theEndingTokenMustSurviveTheSessionEnd() {
        // R2: bounded by the two spent states.
        for (state, ending) in [(MeshContinuationState.refused, MeshContinuationCardKind.refused),
                                (.expired, .expired)] {
            let ended = MeshContinuationCoordinator.transition(from: state, on: .sessionEnded)
            #expect(ended.next == .completed && ended.audit == .completed,
                    "item 4's session-end row lands on the terminal carrying its own token")
            #expect(MeshContinuationCardPresentation.card(state: ended.next, lastAudit: ended.audit) == nil,
                    "so recording that token blindly shows nothing at all")
            let kept = MeshContinuationCardPresentation.projectedAudit(previous: ending.presentingAudit,
                                                                      outcome: ended)
            #expect(kept == ending.presentingAudit, "the ending's own token is what the projection keeps")
            #expect(MeshContinuationCardPresentation.card(state: ended.next, lastAudit: kept)?.kind == ending,
                    "and the card still says \(ending.rawValue) after the session ended")
        }
    }

    /// An absorbed row changed nothing, so it records nothing; every row that MOVED the claim
    /// replaces the token, including one that lands somewhere other than the terminal.
    @Test func theProjectionKeepsAbsorbedRowsAndTakesEveryMove() {
        let absorbed = MeshContinuationCoordinator.transition(from: .completed, on: .firstPeerCommitted)
        #expect(absorbed.audit == .absorbed && absorbed.next == .completed, "item 4's absorbed row")
        #expect(MeshContinuationCardPresentation.projectedAudit(previous: .refused, outcome: absorbed) == .refused,
                "an absorbed row leaves the ending in place — the foreground return is one of these")
        #expect(MeshContinuationCardPresentation.projectedAudit(previous: nil, outcome: absorbed) == nil,
                "and leaves no token as no token")
        let moved = MeshContinuationCoordinator.transition(from: .requested, on: .taskRefused)
        #expect(moved.next == .refused && moved.audit == .refused, "item 4's refusal row")
        #expect(MeshContinuationCardPresentation.projectedAudit(previous: .started, outcome: moved) == .refused,
                "a move replaces the token it moved from")
        let restarted = MeshContinuationCoordinator.transition(from: .completed, on: .meshStarted)
        #expect(MeshContinuationCardPresentation.projectedAudit(previous: .refused, outcome: restarted) == .meshChanged,
                "a new mesh moves the claim, so its token replaces the old ending")
    }

    /// A card about a session that is OVER speaks in the past tense: the ending keeps its headline —
    /// that is the news the token carried through the end — and all three fold to one sentence.
    @Test func anEndedSessionSpeaksInThePastTense() {
        let past: LocalizedStringKey = "That session has since ended. Nothing that was already saved was lost."
        // R2: bounded by the three kinds.
        for kind in MeshContinuationCardKind.allCases {
            let live = MeshContinuationCardPresentation.card(for: kind)
            let ended = MeshContinuationCardPresentation.card(for: kind, sessionHasEnded: true)
            #expect(!live.sessionHasEnded && ended.sessionHasEnded, "the card knows which session it is about")
            #expect(ended.title == live.title, "the ending keeps its headline")
            #expect(ended.symbolName == live.symbolName, "and its symbol")
            #expect(ended.message == past, "and folds to the one past-tense sentence")
            #expect(live.message != past, "while the live card keeps the present tense")
            let throughTheTable = MeshContinuationCardPresentation.card(state: .completed,
                                                                       lastAudit: kind.presentingAudit)
            #expect(throughTheTable == ended, "the table itself folds on `completed`, not the caller")
        }
        #expect(MeshContinuationCardPresentation.card(state: .refused, lastAudit: .refused)?.sessionHasEnded == false,
                "a spent claim in a live session is not an ended one")
    }

    /// The slot's precedence, as a table over every combination: a LIVE spent claim outranks P7's
    /// resume card, an ENDED one yields to it and takes the slot only when there is none.
    @Test func theSlotYieldsToTheResumeCardOnlyForAnEndedSession() {
        let live = MeshContinuationCardPresentation.card(state: .refused, lastAudit: .refused)
        let ended = MeshContinuationCardPresentation.card(state: .completed, lastAudit: .refused)
        let resume = SessionResumeCard(title: "t", message: "m", symbolName: "s")
        let table: [(MeshContinuationCard?, SessionResumeCard?, MeshContinuationSlotDecision, String)] = [
            (nil, nil, .nothing, "no claim and no restore says nothing"),
            (nil, resume, .resume, "no claim leaves P7's card exactly as it was"),
            (live, nil, .continuation, "a live spent claim is the only card"),
            (live, resume, .continuation, "and outranks a card about the last session"),
            (ended, nil, .continuation, "an ended claim still says which ending it was"),
            (ended, resume, .resume, "but yields to a session the person can pick back up")
        ]
        #expect(live?.kind == .refused && ended?.kind == .refused, "the same ending, two sessions")
        // R2: bounded by the table.
        for (continuation, card, expected, why) in table {
            let decided = MeshContinuationCardPresentation.slotDecision(continuation: continuation, resume: card)
            #expect(decided == expected, "\(why) — expected \(expected), decided \(decided)")
        }
    }

    /// Every ending has its own headline; the two foreground-return endings share their sentence.
    @Test func everyEndingHasItsOwnSentences() {
        let cards = MeshContinuationCardKind.allCases.map { MeshContinuationCardPresentation.card(for: $0) }
        #expect(cards.count == 3, "refused, expired, ended by iOS")
        #expect(Self.allDistinct(cards.map(\.title)), "no two cards share a headline")
        #expect(cards.allSatisfy { !$0.symbolName.isEmpty }, "every card has a symbol")
        let refused = MeshContinuationCardPresentation.card(for: .refused)
        let expired = MeshContinuationCardPresentation.card(for: .expired)
        let endedBySystem = MeshContinuationCardPresentation.card(for: .endedBySystem)
        #expect(refused.message != expired.message, "a refusal is a different sentence: nothing ran")
        #expect(expired.message == endedBySystem.message,
                "an expiry and a system end differ in what happened and in nothing the person must do")
    }

    /// Pairwise distinctness over `Equatable` values — `LocalizedStringKey` is not `Hashable`, so a
    /// `Set` cannot answer this.
    private static func allDistinct<Value: Equatable>(_ values: [Value]) -> Bool {
        // R2: bounded by values.count squared — three cards here.
        for (index, value) in values.enumerated() where values.dropFirst(index + 1).contains(value) {
            return false
        }
        return true
    }

    /// The kind's `rawValue` is frozen: the identifier the UI suite matches, and the launch hook's
    /// vocabulary, are both spelled from it.
    @Test func theKindTokensAreFrozen() {
        #expect(MeshContinuationCardKind.allCases.map(\.rawValue) == ["refused", "expired", "endedBySystem"])
        #expect(MeshContinuationCardKind.refused.accessibilityIdentifier == "friends.meshContinuation.refused")
        #expect(MeshContinuationCardKind.expired.accessibilityIdentifier == "friends.meshContinuation.expired")
        #expect(MeshContinuationCardKind.endedBySystem.accessibilityIdentifier == "friends.meshContinuation.endedBySystem")
        let identifiers = MeshContinuationCardKind.allCases.map(\.accessibilityIdentifier)
        #expect(Set(identifiers).count == 3, "one identifier per ending")
    }

    /// No sentence blames anyone or calls anything a failure — the app's voice, and the same rule
    /// `SessionResumeCopyTests` holds over the resume cards.
    @Test func noSentenceNamesAFailure() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/MeshContinuationCardPresentation.swift")
        )
        #expect(!source.isEmpty, "the copy table is readable")
        // R2: bounded by the word list.
        for word in ["failed", "failure", "error", "sorry", "problem"] {
            #expect(!source.lowercased().contains(word), "no sentence calls a refusal or an expiry a \(word)")
        }
        #expect(!source.contains("String("), "no sentence is composed as a String — display text is a key")
    }

    /// The Friends surface reads the projection exactly once, through the table, and hangs the
    /// card's frozen identifier on it — while P7's resume card keeps its own single read.
    @Test func theFriendsSurfaceReadsTheProjectionThroughTheTable() throws {
        let view = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        let reads = view.components(separatedBy: "store.meshContinuationState").count - 1
        #expect(reads == 1, "the surface samples the claim exactly once, inside the card")
        #expect(view.contains("MeshContinuationCardPresentation.card("),
                "and only through the table — no sentence is composed in the view")
        #expect(view.contains(".accessibilityIdentifier(card.accessibilityIdentifier)"),
                "the card carries its own frozen identifier for the UI suite")
        #expect(view.contains("SessionResumeCopy.card(for: manager.sessionResumePresentation)"),
                "P7's resume card still reads its own presentation through its own table")
        #expect(view.contains("MeshContinuationCardPresentation.slotDecision(continuation:"),
                "and which of the two owns the shared slot is the value's decision, not an if chain here")
    }

    /// The projection is an OBSERVED stored property: `@ObservationIgnored` here would mean a
    /// refusal that never repaints the Friends tab, which is the whole point of the card.
    @Test func theStoreProjectionIsObservedAndSetsNoPolicy() throws {
        let store = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        let lines = store.components(separatedBy: "\n")
        let declarations = ["var meshContinuationState", "var meshContinuationLastAudit"]
        // R2: bounded by the declaration list.
        for declaration in declarations {
            let index = try #require(lines.firstIndex { $0.contains(declaration) },
                                     "\(declaration) is the projection item 6 feeds")
            #expect(!lines[index].contains("@ObservationIgnored"),
                    "\(declaration) must repaint the Friends tab")
            let previous = index > 0 ? lines[index - 1].trimmingCharacters(in: .whitespaces) : ""
            #expect(previous != "@ObservationIgnored", "\(declaration) must repaint the Friends tab")
        }
        let code = MeshRoutedSourceScan.codeOnly(store)
        #expect(code.components(separatedBy: "meshContinuationState").count - 1 == 1,
                "the projection is declared once and written by nothing in the store — item 6 owns the setter that feeds the policy")
    }

    /// The DEBUG launch hook seeds the projection through the table's own inverse, so it can never
    /// ask for a cell the table does not present.
    @Test func theLaunchHookSeedsThroughTheTablesInverse() throws {
        let support = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/UITestSupport.swift"))
        #expect(support.contains("FERNLET_MESH_CONTINUATION"), "the hook reads one variable")
        #expect(support.components(separatedBy: "seededMeshContinuationCard").count - 1 == 2,
                "declared in both halves — DEBUG and the Release no-op")
        let content = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ContentView.swift"))
        #expect(content.contains("UITestSupport.seededMeshContinuationCard"), "and is consumed once, at launch")
        #expect(content.contains("presentingState") && content.contains("presentingAudit"),
                "seeding the claim the card is the answer to, never a hand-written pair")
    }
}
