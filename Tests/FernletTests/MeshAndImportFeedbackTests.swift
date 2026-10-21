// MeshAndImportFeedbackTests.swift
// FernletTests
//
// Tier B haptics for the in-person mesh, friends, imports and the Messages extension (sounds-and-haptics
// pass, 2026-10-20; `Docs/Handoff/Sounds-Haptics-Investigation.md` B18–B23 and B25). Every decision is
// checked through the player's injected `perform` seam (and the announcer's `post`), because UIKit
// never reports back what it played and two phones are not a unit test:
//
//  - B19: the 15 cm approach ticks once per approach, re-armed only past 30 cm;
//  - B20: a session's first commit plays `friendHere` and a link that heals plays nothing;
//  - B22: an import plays `done` only after the import itself returned, `failed` when it threw, and a
//    landed import's line is shown, then the sheet closes, then the line is spoken;
//  - the smaller mappings (hearts, the friend shop, "Send in Messages");
//  - and source pins for what has no seam: the shutter after the capture (B18), the connect latch's
//    wiring (B20), and the Messages extension's copied feels (B23), whose target FernletTests does not
//    link.

import Foundation
import Testing
import FernletUI
import FernletDomainModel
import FernletSocial
@testable import Fernlet

/// One ordered record of everything a cue path did: cues played, sentences spoken, pauses, closes.
@MainActor
private final class Timeline {
    var entries: [String] = []

    /// A player that writes each cue it is handed as `cue:<event>`, with every switch on.
    lazy var feedback = FernletFeedback(perform: { [unowned self] in entries.append("cue:\($0.event.rawValue)") })
    /// An announcer that writes each sentence as `say:<kind>:<text>`.
    lazy var announcer = FernletAnnouncer(post: { [unowned self] in entries.append("say:\($0.kind.rawValue):\($0.message)") })

    /// A landing on this timeline whose pauses return at once, logged as `pause:<seconds>`.
    func landing(failingPauses: Bool = false) -> ImportReviewLanding {
        ImportReviewLanding(feedback: feedback, announcer: announcer, pause: { [unowned self] duration in
            entries.append("pause:\(duration.components.seconds)")
            if failingPauses { throw CancellationError() }
        })
    }

    /// The cues alone, in order.
    var cues: [String] { entries.filter { $0.hasPrefix("cue:") } }
}

/// Every switch on, at the All level: what plays is decided by the code under test alone.
private let allOn = FernletFeedbackPreferences(hapticsEnabled: true, soundsEnabled: false)

@MainActor
@Suite struct MeshAndImportFeedbackTests {

    // MARK: B19 — the 15 cm approach

    /// One tick when the phones come inside 15 cm; jitter at the line, a lost reading and a drift to
    /// 25 cm never tick again; only moving back past 30 cm re-arms the next approach.
    @Test func theApproachTicksOncePerApproachWithHysteresis() {
        let timeline = Timeline()
        var cue = ProximityApproachCue()
        let readings: [Double?] = [
            0.60, 0.22, 0.14,              // first approach: tick at 14 cm
            0.10, 0.16, 0.13, nil, 0.12,   // held at the line, ranging lost and back: nothing
            0.25, 0.15,                    // drifted to 25 cm, never past 30: still nothing
            0.31,                          // moved back past 30 cm: re-armed
            0.29, 0.15,                    // second approach: tick exactly at the commit distance
            .nan, -.infinity, 0.11         // nonsense readings change nothing
        ]
        for meters in readings {
            if let event = cue.observe(meters) { timeline.feedback.play(event, preferences: allOn) }
        }
        #expect(timeline.cues == ["cue:tick", "cue:tick"])
        #expect(!cue.isArmed)
        #expect(FernletFeedbackCue(event: .tick, preferences: allOn)?.haptic == .selection)
        #expect(FernletFeedbackCue(event: .tick, preferences: allOn)?.sound == nil, "the mesh never sounds")
        #expect(ProximityApproachCue.commitMeters == 0.15, "ProximityKit's friend-mode commit distance")
        #expect(ProximityApproachCue.rearmMeters == 0.30)
    }

    /// The "Hold still…" line — the tick's visual twin — reads the same distance.
    @Test func theHoldStillLineReadsTheCommitDistance() {
        #expect(ProximityApproachCue.isWithinCommitDistance(0.15))
        #expect(ProximityApproachCue.isWithinCommitDistance(0.02))
        #expect(!ProximityApproachCue.isWithinCommitDistance(0.151))
        #expect(!ProximityApproachCue.isWithinCommitDistance(.nan))
    }

    // MARK: B20 — the connect, not the heal

    /// A session's first commit plays `friendHere`; a blip that heals plays nothing, however often;
    /// a new session after the old one ended is felt again.
    @Test func aHealPlaysNothing() {
        let timeline = Timeline()
        var cue = SessionConnectCue()
        func commit() { if let event = cue.committed() { timeline.feedback.play(event, preferences: allOn) } }

        commit()            // the session's first commit
        commit()            // a blip, healed
        commit()            // and again
        cue.sessionEnded()  // End Session, the timeout, a termination
        commit()            // a new session's first commit
        #expect(timeline.cues == ["cue:friendHere", "cue:friendHere"])

        // A Friends surface that opens on a session already running starts greeted — the overlay's
        // own "already in session, skip the animation" rule — so its first heal is a heal.
        var reopened = SessionConnectCue()
        reopened.surfaceAppeared(inSession: true)
        #expect(reopened.committed() == nil)
        reopened.surfaceAppeared(inSession: false)
        #expect(reopened.committed() == .friendHere)
    }

    /// The commit edge plays only through the latch, and both session-end edges reset it.
    @Test func connectViewPlaysTheConnectOnlyThroughTheLatch() throws {
        let source = try RepoRoot.source("App/Fernlet/ConnectView.swift")
        let handler = try #require(source.range(of: "private func handleCommittedPeerChange(hadPeer: Bool, hasPeer: Bool) {"))
        let end = try #require(source.range(of: "\n    }\n", range: handler.upperBound..<source.endIndex))
        let body = source[handler.lowerBound..<end.upperBound]
        #expect(body.contains("if let cue = connectCue.committed() { FernletFeedback.system.play(cue) }"))
        #expect(!body.contains("play(.friendHere)"), "the commit edge plays friendHere around the latch — a heal would buzz")
        #expect(source.contains("connectCue.surfaceAppeared(inSession: manager.isInSession)"))
        #expect(source.components(separatedBy: "connectCue.sessionEnded()").count == 3,
                "the latch must reset when the session stops being live AND when the session surface goes")
    }

    // MARK: B18 — the shutter after the capture

    /// The shutter haptic plays only once `capturePhoto()` has returned, never while the camera
    /// captures; a capture error plays `failed` beside its alert.
    @Test func theShutterIsFeltAfterTheCaptureReturns() throws {
        let source = try RepoRoot.source("App/Fernlet/DisposableCameraView.swift")
        let start = try #require(source.range(of: "private func takePhoto() async {"))
        let end = try #require(source.range(of: "\n    }\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.lowerBound..<end.upperBound])
        let capture = try #require(body.range(of: "try await camera.capturePhoto()"))
        let shutter = try #require(body.range(of: "FernletFeedback.system.play(.shutter)"))
        #expect(capture.upperBound <= shutter.lowerBound, "the shutter plays before the capture returned (B18)")
        #expect(body.components(separatedBy: "play(.shutter)").count == 2, "one shutter per photo")
        let failure = try #require(body.range(of: "catch {"))
        #expect(body[failure.upperBound...].contains("FernletFeedback.system.play(.failed)"))
    }

    // MARK: B22 — imports that confirm themselves

    /// A landed import: `done` at once, the beat, the close, the settle, then the line is spoken —
    /// and nothing at all played while the import itself was running.
    @Test func aNearbyImportPlaysDoneOnlyAfterItLanded() async {
        let timeline = Timeline()
        let outcome = ProximityRecipeShareReviewSheet.outcome {
            timeline.entries.append("import")
            return .imported(name: "Lentil soup")
        }
        guard case .added(let line) = outcome else {
            Issue.record("a landed import is not .added: \(outcome)")
            return
        }
        #expect(line.contains("Lentil soup"))
        await timeline.landing().answer(outcome) { timeline.entries.append("close") }
        #expect(timeline.entries == [
            "import", "cue:done", "pause:1", "close", "pause:0", "say:success:\(line)"
        ], "done before the beat, the close after it, the line spoken once the close has settled")

        let kept = ProximityRecipeShareReviewSheet.outcome { .alreadySaved(name: "Lentil soup") }
        #expect(kept.event == .done, "the existing copy is in the book — the import is answered")
    }

    /// An import that threw plays `failed` and speaks the error now; it never closes the sheet and
    /// never plays `done`.
    @Test func aFailedNearbyImportPlaysFailedAndStaysOpen() async {
        let timeline = Timeline()
        let outcome = ProximityRecipeShareReviewSheet.outcome { throw RecipeImportError.emptyRecipe }
        #expect(outcome == .failed(RecipeImportError.emptyRecipe.message))
        await timeline.landing().answer(outcome) { timeline.entries.append("close") }
        #expect(timeline.entries == ["cue:failed", "say:error:\(RecipeImportError.emptyRecipe.message)"])

        let unknown = ProximityRecipeShareReviewSheet.outcome { throw CocoaError(.fileReadCorruptFile) }
        #expect(unknown == .failed(RecipeImportError.invalidPayload.message))
    }

    /// The Messages recipe import: `failed` when it threw, a `caveat` when it saved but the review
    /// could not be cleared, and the "added" line otherwise — each decided after the import returned.
    @Test func aMessagesRecipeImportIsAnsweredFromWhatTheImportDid() async {
        let recipe = RecipeDefinition(
            name: "Green salad", servings: 2, ingredients: [], notes: "",
            source: MealLogSource.manual, createdAt: Date(), updatedAt: Date(), steps: nil
        )
        let timeline = Timeline()
        let added = await MessagesRecipeImportReviewSheet.outcome(
            importing: {
                #expect(timeline.cues.isEmpty, "a cue played before the import returned")
                return RecipeEntity(recipe: recipe)
            },
            consume: { true }
        )
        #expect(added.event == .done && added.line.contains("Green salad"))
        await timeline.landing().answer(added) { timeline.entries.append("close") }
        #expect(timeline.cues == ["cue:done"])
        #expect(timeline.entries.firstIndex(of: "close") ?? 0 > timeline.entries.firstIndex(of: "cue:done") ?? 0)

        let notCleared = await MessagesRecipeImportReviewSheet.outcome(importing: { RecipeEntity(recipe: recipe) }, consume: { false })
        #expect(notCleared.event == .caveat)
        var consumed = false
        let threw = await MessagesRecipeImportReviewSheet.outcome(
            importing: { throw ExchangeIntentServiceError.persistenceFailed },
            consume: { consumed = true; return true }
        )
        #expect(threw.event == .failed && !consumed, "a failed import never clears its review")
    }

    /// The workout plan: the calendar changing under the review is a `caveat`, anything else `failed`.
    @Test func aWorkoutPlanRefusalIsACaveat() async {
        let changed = MessagesWorkoutPlanImportReviewSheet.outcome(for: ExchangeIntentServiceError.reviewChanged)
        #expect(changed.event == .caveat && !changed.line.isEmpty)
        #expect(MessagesWorkoutPlanImportReviewSheet.outcome(for: ExchangeIntentServiceError.invalidPacket).event == .failed)

        let timeline = Timeline()
        await timeline.landing().answer(changed) { timeline.entries.append("close") }
        #expect(timeline.entries == ["cue:caveat", "say:status:\(changed.line)"], "a caveat keeps the sheet up")
    }

    /// A landing whose beat is cancelled (the app going away) closes nothing and says nothing.
    @Test func aCancelledBeatClosesNothing() async {
        let timeline = Timeline()
        await timeline.landing(failingPauses: true).answer(.added("Saved.")) { timeline.entries.append("close") }
        #expect(timeline.entries == ["cue:done", "pause:1"])
    }

    // MARK: Friends, the shop, "Send in Messages"

    /// B21: a heart tucked away feels like the in-session heart; a limit is a limit; a refusal fails.
    @Test func awayHeartsFeelLikeTheInSessionHeart() {
        #expect(FriendListView.awayHeartEvent(for: .queued) == .logged)
        for limited in [HeartDropService.QueueOutcome.rateLimited, .dailyLimitReached, .backlogFull] {
            #expect(FriendListView.awayHeartEvent(for: limited) == .limit)
        }
        for refused in [HeartDropService.QueueOutcome.storageUnavailable, .disabled, .failed] {
            #expect(FriendListView.awayHeartEvent(for: refused) == .failed)
        }
    }

    /// B25: bought is `done`; not enough coins, already owned or gone is a `caveat`, never an error.
    @Test func aPurchaseIsDoneOrACaveat() {
        #expect(FriendShopView.purchaseEvent(for: .bought) == .done)
        for refused in [FernletStore.ClothingPurchaseResult.alreadyOwned, .insufficientCoins, .unavailable] {
            #expect(FriendShopView.purchaseEvent(for: refused) == .caveat)
        }
    }

    /// "Send in Messages": sent is `done`, failed is `failed`, and a cancelled draft plays nothing.
    @Test func sendInMessagesPlaysItsResultAndACancelStaysSilent() {
        #expect(RecipeShareElsewhereCard.feedbackEvent(for: .sent) == .done)
        #expect(RecipeShareElsewhereCard.feedbackEvent(for: .failed) == .failed)
        #expect(RecipeShareElsewhereCard.feedbackEvent(for: .cancelled) == nil)
    }

    // MARK: B23 — the Messages extension (source pins: FernletTests does not link the target)

    /// The extension's three feels are FernletUI's `tick`, `logged` and `failed`, copied; and the
    /// composer plays them at the pick, the insert that succeeded, and each failure.
    @Test func theMessagesExtensionCopiesFernletsFeels() throws {
        let haptic = try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesHaptic.swift")
        #expect(FernletFeedbackEvent.tick.haptic == .selection)
        #expect(haptic.contains("UISelectionFeedbackGenerator().selectionChanged()"))
        #expect(FernletFeedbackEvent.logged.haptic == .soft)
        #expect(haptic.contains("UIImpactFeedbackGenerator(style: .soft).impactOccurred(intensity: 0.5)"),
                "`logged` is a soft impact at 0.5 in FernletFeedback's tuning table; keep the copy in step")
        #expect(FernletFeedbackEvent.failed.haptic == .error)
        #expect(haptic.contains("UINotificationFeedbackGenerator().notificationOccurred(.error)"))

        let controller = try RepoRoot.source("App/FernletMessagesExtension/FernletMessagesViewController.swift")
        #expect(try MessagesExtensionBoundaryTests.body(of: "selectRecipe", in: controller)
            .contains("if selectedRecipeID != id { FernletMessagesHaptic.picked.play() }"))
        let insert = try MessagesExtensionBoundaryTests.body(of: "insert", in: controller)
        #expect(insert.contains("FernletMessagesHaptic.inserted.play()") && insert.contains("showComposerFailure(FernletMessagesCopy.insertFailed)"))
        for name in ["insertSelectedRecipe", "insertSelectedWorkout"] {
            let body = try MessagesExtensionBoundaryTests.body(of: name, in: controller)
            #expect(!body.contains("showComposerStatus("), "\(name) shows a refusal without its error haptic")
        }
    }
}
