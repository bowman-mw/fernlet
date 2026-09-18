// SessionResumeCopyTests.swift
// FernletTests
//
// Network migration P7 item 5: every presented restore outcome has its own card, `.nothing` has
// none, no two cards say the same thing, and the Friends surface reads the manager's one public
// value through the copy table — with the card and its dismissal reachable by identifier for the
// UI suite this session could not run.

import Foundation
import SwiftUI
import Testing
import ProximityKit
@testable import Fernlet

/// The copy table and the surface wall.
@Suite struct SessionResumeCopyTests {

    /// Every presented case, `.nothing` excluded — the four endings plus the offer and the set-aside.
    private static let presented: [MeshSessionResumePresentation] =
        [.offerResume, .previousSessionCouldNotBeReopened]
        + MeshSessionEndingPresentation.allCases.map { .previousSessionEnded($0) }

    /// Every presented case has a card, `.nothing` has none, and no two cards repeat a title.
    @Test func everyPresentedCaseHasItsOwnCard() {
        #expect(SessionResumeCopy.card(for: .nothing) == nil, "nothing to say shows no card")
        let cards = Self.presented.compactMap { SessionResumeCopy.card(for: $0) }
        #expect(cards.count == 6, "the offer, the set-aside, and the four endings each have a card")
        #expect(Set(cards.map(\.title)).count == cards.count, "no two cards share a headline")
        #expect(Set(cards.map(\.message)).count == cards.count, "nor a sentence")
        let symbolsNamed = cards.allSatisfy { !$0.symbolName.isEmpty }
        #expect(symbolsNamed, "every card has a symbol")
    }

    /// The four endings fold the eight frozen reasons and are named as ended, never as failed.
    @Test func anEndingIsNamedAsEndedNeverAsFailed() {
        #expect(MeshSessionEndingPresentation.allCases.count == 4, "ended, expired, you left, you were removed")
        let source = try? RepoRoot.source("App/Fernlet/SessionResumeCopy.swift")
        let copy = MeshRoutedSourceScan.codeOnly(source ?? "")
        #expect(!copy.isEmpty, "the copy table is readable")
        #expect(!copy.lowercased().contains("failed"), "no sentence calls a previous session failed")
        #expect(copy.contains("\"Got it\""), "the dismiss label is one shared key")
    }

    /// The surface reads the manager's one public value through the copy table, presents nothing
    /// modal, and exposes the card and its dismissal by identifier.
    @Test func theFriendsSurfaceReadsThePresentationThroughTheCopyTable() throws {
        let view = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/ConnectView.swift"))
        let reads = view.components(separatedBy: "manager.sessionResumePresentation").count - 1
        #expect(reads == 1, "the surface samples the presentation exactly once, inside the card")
        #expect(view.contains("SessionResumeCopy.card(for: manager.sessionResumePresentation)"),
                "and only through the copy table — no sentence is composed in the view")
        #expect(view.contains(".accessibilityIdentifier(\"friends.sessionResume\")"),
                "the card is reachable by identifier for the UI suite")
        #expect(view.contains(".accessibilityIdentifier(\"friends.sessionResume.dismiss\")"),
                "and so is its dismissal")
        #expect(!view.contains("lastSessionRestoreOutcome") && !view.contains("restoredSessionContext"),
                "the app reads none of the manager's internal restore surfaces directly")
    }
}
