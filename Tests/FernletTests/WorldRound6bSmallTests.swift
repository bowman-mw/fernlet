import Foundation
import SwiftUI
import Testing
import UIKit
import FernletDomainModel
import FernletScoring
@testable import Fernlet

/// The owner's form answers built in round 6b's small lane (2026-10-25): the close-up's one even veil
/// (question 27), and the rest of the lane's small changes as they land.
@MainActor
struct WorldRound6bSmallTests {

    // MARK: 27 · The close-up's veil

    /// One even veil, as drawn: 80 % over the light map, 84 % over the dark, from top to bottom (no
    /// thicker band behind the name and the footer).
    @Test func theCloseUpHasOneEvenVeil() {
        #expect(WorldCloseUpVeil.opacity(dark: false) == 0.8)
        #expect(WorldCloseUpVeil.opacity(dark: true) == 0.84)
    }

    // MARK: 41 · A received plan says "Notes included"

    /// The received workout plan's framed card adds "Notes included" when the sender's notes travel
    /// with it, as its bubble does; the note text itself is never shown. `FernletTests` cannot link
    /// the appex, so the controller's source holds the shape (as `MessagesExtensionBoundaryTests` does).
    @Test func aReceivedPlanSaysNotesIncluded() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesViewController.swift"))
        let body = try #require(MeshRoutedSourceScan.bracedBody(after: "private func showReceivedWorkout(", in: source))
        #expect(body.contains("record.packet.includesNotes"))
        #expect(body.contains("FernletMessagesCopy.workoutSubtitleWithNotes(summary:"))
        #expect(!body.contains(".notes"), "the note text never reaches the panel")
    }

    // MARK: 43 · Log meal's Import, always

    /// Import opens while lookup is on; with lookup off it asks first, even after an earlier "Not now"
    /// or a revocation (the tap is the person's own request); with AI features off no consent can open
    /// the lane, so Import opens and explains.
    @Test func importAsksForLookupConsentOnTheTap() {
        var settings = FernletSettings()
        settings.aiStatus = .ready
        #expect(FoodImportTap.resolve(for: settings) == .askFirst, "undecided")
        settings.webNutritionLookupEnabled = true
        settings.webNutritionLookupConsent = .accepted
        #expect(FoodImportTap.resolve(for: settings) == .open)
        settings.webNutritionLookupEnabled = false
        settings.webNutritionLookupConsent = .revoked
        #expect(FoodImportTap.resolve(for: settings) == .askFirst, "revoked")
        settings.webNutritionLookupConsent = .declined
        #expect(FoodImportTap.resolve(for: settings) == .askFirst, "declined before")
        settings.aiStatus = .off
        #expect(FoodImportTap.resolve(for: settings) == .openExplainingOff)
    }

    /// Log meal draws Import whatever the lookup setting, and its tap goes through ``FoodImportTap``.
    @Test func logMealAlwaysDrawsImport() throws {
        let source = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/Fernlet/FoodView.swift"))
        let row = try #require(MeshRoutedSourceScan.bracedBody(after: "private var helperButtons: some View", in: source))
        #expect(row.contains("FoodHelperButton(title: \"Import\", sprite: FoodSprites.link, action: tapImport)"))
        #expect(!row.contains("if store.allowsWebNutritionLookup"), "Import is no longer hidden while lookup is off")
        let tap = try #require(MeshRoutedSourceScan.bracedBody(after: "private func tapImport()", in: source))
        #expect(tap.contains("FoodImportTap.resolve(for: store.settings)"))
    }

    // MARK: 44 · The solo camera after bedtime

    /// The local calendar the camera reads the night in.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// 2026-10-`day` at `hour`:`minute`, local.
    private static func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute)) ?? .distantPast
    }

    /// Once the companion has fallen asleep the camera says "tomorrow night", exactly when the shot's
    /// reveal is the next night; in the wind-down and through the day it still says "tonight".
    @Test func theSoloCameraSaysTomorrowNightOnceTheCompanionSleeps() {
        let night = CompanionSleepWindow(bedtimeMinute: 22 * 60 + 30, wakeMinute: 7 * 60)
        let says = { (date: Date) in SoloCameraRules.waitsForTomorrowNight(at: date, window: night, calendar: Self.calendar) }
        #expect(!says(Self.at(24, 14)), "an afternoon: tonight")
        #expect(!says(Self.at(24, 22, 45)), "the wind-down: tonight")
        #expect(says(Self.at(24, 23)), "the minute it falls asleep: tomorrow night")
        #expect(says(Self.at(25, 2)), "after midnight, still asleep: tomorrow night")
        #expect(!says(Self.at(25, 7, 30)), "awake again: tonight")
        for (day, hour, minute) in [(24, 14, 0), (24, 22, 45), (24, 23, 0), (24, 23, 30), (25, 2, 0), (25, 7, 30)] {
            let date = Self.at(day, hour, minute)
            let reveal = SoloCameraRules.revealsAt(takenAt: date, window: night, calendar: Self.calendar)
            let tomorrowNight = reveal.timeIntervalSince(date) > 16 * 60 * 60
            #expect(says(date) == tomorrowNight, "the line and the reveal agree at \(hour):\(minute)")
        }
        let empty = CompanionSleepWindow(bedtimeMinute: 9 * 60, wakeMinute: 9 * 60)
        #expect(SoloCameraRules.waitsForTomorrowNight(at: Self.at(24, 23, 30), window: empty, calendar: Self.calendar),
                "no night set: the standard one")
    }

    // MARK: 42 · The Messages panel's icons grow with the text

    /// The panel's pixel icons step up one point a key at the accessibility sizes, as the app's sprites
    /// do, and every panel icon is drawn through the stepping view (no fixed 2-pt image left).
    @Test func thePanelsIconsGrowInSteps() throws {
        #expect(FernletMessagesSprite.pixel(2, accessibilitySize: false) == 2)
        #expect(FernletMessagesSprite.pixel(2, accessibilitySize: true) == 3)
        #expect(FernletMessagesSprite.pixel(3, accessibilitySize: true) == 4)
        for file in ["FernletMessagesPanelPieces.swift", "FernletMessagesFramedViews.swift", "FernletMessagesViewController.swift"] {
            let code = MeshRoutedSourceScan.codeOnly(try RepoRoot.source("App/FernletMessagesExtension/\(file)"))
            #expect(!code.contains(".image(pixel: 2") && !code.contains(".image(pixel: 3"),
                    "\(file) draws a pixel icon at a fixed size, which stays small at the largest text")
        }
    }

    // MARK: 47 · "Keep as friends?" as soon as the other sheet closes

    /// A sheet already up when a session ends (a panel's, which the root host can't see): the prompt
    /// waits under no retry budget, however long the sheet stays, and shows as soon as it closes.
    @Test func keepAsFriendsShowsAsSoonAsTheOtherSheetCloses() async throws {
        let store = makeTestStore()
        let scene = try OverlayTestSupport.scene()
        let other = KeepFriendsOtherSheet()
        other.isUp = true
        let (window, hosting) = OverlayTestSupport.window(on: scene, root: KeepFriendsBehindSheetHarness(store: store, other: other))
        defer { OverlayTestSupport.close(window, hosting) }
        try await Self.wait(seconds: 3) { holdsForeignCover(hosting.presentedViewController) }
        try #require(holdsForeignCover(hosting.presentedViewController), "precondition: the other sheet is up")

        let manager = store.meshNetworkManager
        HeldPhotos.openGate(on: manager)
        manager.recordSessionParticipant(displayName: "Bea", fingerprint: "bea-fp-0011223344",
                                         signingPublicKey: Data([7]), keyAgreementPublicKey: Data([8]))
        manager.leaveSession()
        try #require(store.meshFeatures.photos.pendingFriendReview?.entries.count == 1)
        // Past the check's delay, a landing grace and the four retries the old watchdog had.
        try await Task.sleep(for: .seconds(12))
        #expect(holdsForeignCover(hosting.presentedViewController), "the other sheet stays; nothing replaced it")

        other.isUp = false
        try await Self.wait(seconds: 8) { Self.promptIsUp(hosting) }
        #expect(Self.promptIsUp(hosting), "the prompt shows once the other sheet has closed")
    }

    /// The host's waits are read in its own window, and a covering sheet costs no retry.
    @Test func keepAsFriendsWaitsInItsOwnWindowWithoutGivingUp() throws {
        let source = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("App/Fernlet/World/Friends/KeepFriendsPromptHost.swift"))
        let deferred = try #require(MeshRoutedSourceScan.bracedBody(after: "private func runDeferredReviewCheck() async", in: source))
        let wait = try #require(deferred.range(of: "await waitUntilNothingIsPresented()"))
        let present = try #require(deferred.range(of: "presentDisconnectReviewIfNeeded()"))
        #expect(wait.lowerBound < present.lowerBound, "it waits for the other sheet before it asks")
        let watchdog = try #require(MeshRoutedSourceScan.bracedBody(after: "private func confirmSessionEndSheetLanded() async", in: source))
        #expect(watchdog.contains("if !windowAnchor.somethingIsPresented {"), "a covering sheet spends no retry")
        #expect(!source.contains("UIApplication.shared"), "only the host's own window counts, never another one")
    }

    /// The prompt (not the other sheet) is what `hosting` presents.
    private static func promptIsUp(_ hosting: UIViewController) -> Bool {
        hosting.presentedViewController != nil && !holdsForeignCover(hosting.presentedViewController)
    }

    /// Polls `condition` every 50 ms for at most `seconds` (R2: bounded).
    private static func wait(seconds: Int, until condition: () -> Bool) async throws {
        for _ in 0..<(seconds * 20) where !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}

/// The other sheet in ``KeepFriendsBehindSheetHarness``, raised and lowered by the test.
@MainActor
@Observable
final class KeepFriendsOtherSheet {
    /// Whether the other sheet is up.
    var isUp = false
}

/// The root's keep-as-friends host, as ContentView hangs it, with another sheet over the same window
/// that the host is not told about (a panel's sheet, such as Food's meal sheet).
struct KeepFriendsBehindSheetHarness: View {
    let store: FernletStore
    @Bindable var other: KeepFriendsOtherSheet
    @State private var isPromptUp = false

    var body: some View {
        Color.clear
            .sheet(isPresented: $other.isUp) { ForeignCoverMarker() }
            .modifier(KeepFriendsPromptHost(store: store, isRootSheetUp: false, launchComplete: true, isCoverUp: false,
                                            keepFriendsPromptPresented: $isPromptUp))
    }
}
