import Foundation
import CoreGraphics
import Testing
import FernletDomainModel
@testable import Fernlet

/// The approved exercise animations' tile (package revision r12) in the how-to sheet.
///
/// Pinned here: the pure playback rules (when the tile moves and loops, Reduce Motion starting it
/// paused, where a loop starts so play never jumps, which progress a moment shows, at most 24 frames
/// a second with a slow frame dropping to the next tick, the 4:3 height); the one frame source's
/// claim and release, and that a loop the renderer cannot draw ends as a still and lets the renderer
/// go; and, from the source, that the slot draws the tile only for an exercise with an approved
/// animation, that the tile reuses the demonstration's spoken name, pause access and corner mark,
/// and that the animations run with no web view.
@MainActor
struct ExerciseAnimationTileTests {

    // MARK: - Geometry

    /// The tile is 4:3 like the approved 640 × 480 canvas; an unusable width draws nothing.
    @Test func theTileIsFourByThree() {
        #expect(abs(ExerciseAnimationPlayback.aspectRatio - 4.0 / 3.0) < 1e-12)
        #expect(ExerciseAnimationPlayback.height(forWidth: 320) == 240)
        #expect(ExerciseAnimationPlayback.height(forWidth: 160) == 120)
        #expect(ExerciseAnimationPlayback.height(forWidth: 0) == 0)
        #expect(ExerciseAnimationPlayback.height(forWidth: -40) == 0)
        #expect(ExerciseAnimationPlayback.height(forWidth: .infinity) == 0)
        #expect(ExerciseAnimationPlayback.height(forWidth: .nan) == 0)
        let canvas = CGFloat(ExerciseAnimationRenderer.pixelWidth) / CGFloat(ExerciseAnimationRenderer.pixelHeight)
        #expect(canvas == ExerciseAnimationPlayback.aspectRatio)
    }

    // MARK: - When it moves

    /// A held pose or a missing renderer is a still; only a moving pose with a renderer animates.
    @Test func aHeldPoseOrAMissingRendererIsAStill() {
        #expect(ExerciseAnimationPlayback.animates(hold: false, rendererAvailable: true))
        #expect(!ExerciseAnimationPlayback.animates(hold: true, rendererAvailable: true))
        #expect(!ExerciseAnimationPlayback.animates(hold: false, rendererAvailable: false))
        #expect(!ExerciseAnimationPlayback.animates(hold: true, rendererAvailable: false))
    }

    /// The loop runs only when the tile moves, is on screen, the scene is active and it is not
    /// paused; any one of those false holds the frame.
    @Test func theLoopRunsOnlyWhenMovingOnScreenActiveAndNotPaused() {
        var looping: [[Bool]] = []
        for animates in [false, true] {
            for isOnScreen in [false, true] {
                for isActive in [false, true] {
                    for isPaused in [false, true] where ExerciseAnimationPlayback.loops(
                        animates: animates, isOnScreen: isOnScreen, isActive: isActive, isPaused: isPaused) {
                        looping.append([animates, isOnScreen, isActive, isPaused])
                    }
                }
            }
        }
        #expect(looping == [[true, true, true, false]])
        let playing = ExerciseAnimationTilePlayback(exerciseID: "exercise-001", character: .male, loops: true)
        let paused = ExerciseAnimationTilePlayback(exerciseID: "exercise-001", character: .male, loops: false)
        #expect(playing != paused, "a pause must change the task identity, or the loop would keep running")
        #expect(playing != ExerciseAnimationTilePlayback(exerciseID: "exercise-001", character: .female, loops: true))
    }

    /// Reduce Motion starts the tile paused; the person's own tap decides from then on, either way.
    @Test func reduceMotionStartsPausedAndATapDecides() {
        #expect(!ExerciseAnimationPlayback.isPaused(choice: nil, reduceMotion: false))
        #expect(ExerciseAnimationPlayback.isPaused(choice: nil, reduceMotion: true))
        #expect(!ExerciseAnimationPlayback.isPaused(choice: false, reduceMotion: true), "a tap plays it under Reduce Motion")
        #expect(ExerciseAnimationPlayback.isPaused(choice: true, reduceMotion: false))
    }

    // MARK: - Progress

    @Test func progressWrapsIntoOneLoop() {
        #expect(ExerciseAnimationPlayback.wrapped(0) == 0)
        #expect(ExerciseAnimationPlayback.wrapped(0.25) == 0.25)
        #expect(ExerciseAnimationPlayback.wrapped(1) == 0)
        #expect(ExerciseAnimationPlayback.wrapped(1.25) == 0.25)
        #expect(ExerciseAnimationPlayback.wrapped(-0.25) == 0.75)
        #expect(ExerciseAnimationPlayback.wrapped(-1e-20) == 0, "a hair under zero must not wrap to 1")
        #expect(ExerciseAnimationPlayback.wrapped(.nan) == 0)
        #expect(ExerciseAnimationPlayback.wrapped(.infinity) == 0)
    }

    /// The first playback starts at the still's progress, so play does not jump; after a pause it
    /// carries on from the frame the pause held.
    @Test func playStartsAtTheStillAndResumesWhereItPaused() {
        #expect(ExerciseAnimationPlayback.startProgress(saved: nil, stillProgress: 0.4) == 0.4)
        #expect(ExerciseAnimationPlayback.startProgress(saved: 0.7, stillProgress: 0.4) == 0.7)
        #expect(abs(ExerciseAnimationPlayback.startProgress(saved: 1.7, stillProgress: 0.4) - 0.7) < 1e-12)
        #expect(ExerciseAnimationPlayback.progress(start: 0.4, elapsed: 0, duration: 3) == 0.4,
                "the first live frame is the still's moment")
    }

    /// Progress is `(start + elapsed / duration) mod 1`; an unusable duration or time holds `start`.
    @Test func progressAdvancesByElapsedOverDuration() {
        #expect(ExerciseAnimationPlayback.progress(start: 0.5, elapsed: 1, duration: 4) == 0.75)
        #expect(ExerciseAnimationPlayback.progress(start: 0.5, elapsed: 2, duration: 4) == 0)
        #expect(ExerciseAnimationPlayback.progress(start: 0.5, elapsed: 9, duration: 4) == 0.75)
        #expect(ExerciseAnimationPlayback.progress(start: 0.5, elapsed: 1, duration: 0) == 0.5)
        #expect(ExerciseAnimationPlayback.progress(start: 0.5, elapsed: 1, duration: .nan) == 0.5)
        #expect(ExerciseAnimationPlayback.progress(start: 0.5, elapsed: -1, duration: 4) == 0.5)
        #expect(ExerciseAnimationPlayback.progress(start: 1.5, elapsed: .infinity, duration: 4) == 0.5)
    }

    // MARK: - Ticks

    /// Ticks are whole 24ths of a second, the next one strictly after now, so the loop never draws
    /// more than 24 frames a second and a slow frame skips the ticks it missed instead of queueing.
    @Test func framesFollowA24PerSecondTickAndSkipMissedOnes() {
        let interval = 1.0 / 24.0
        #expect(ExerciseAnimationPlayback.frameInterval == interval)
        #expect(abs(ExerciseAnimationPlayback.nextTick(after: 0) - interval) < 1e-12)
        #expect(abs(ExerciseAnimationPlayback.nextTick(after: 0.03) - interval) < 1e-12)
        #expect(abs(ExerciseAnimationPlayback.nextTick(after: interval) - 2 * interval) < 1e-12, "on a tick, wait for the next")
        #expect(abs(ExerciseAnimationPlayback.nextTick(after: 1) - 25 * interval) < 1e-12)
        #expect(abs(ExerciseAnimationPlayback.nextTick(after: 0.2) - 5 * interval) < 1e-12, "a 200 ms frame drops to tick 5")
        #expect(ExerciseAnimationPlayback.nextTick(after: -1) == interval)
        #expect(ExerciseAnimationPlayback.nextTick(after: .nan) == interval)
        var elapsed = 0.0
        for _ in 0..<240 {
            let next = ExerciseAnimationPlayback.nextTick(after: elapsed)
            #expect(next - elapsed > 0 && next - elapsed <= interval + 1e-9)
            elapsed = next
        }
        #expect(abs(elapsed - 10) < 1e-6, "240 ticks are ten seconds at 24 a second")
        #expect(ExerciseAnimationPlayback.maxTicks == 24 * 60 * 30)
        #expect(ExerciseAnimationPlayback.seconds(.milliseconds(1500)) == 1.5)
        #expect(ExerciseAnimationPlayback.seconds(.zero) == 0)
    }

    // MARK: - The one frame source

    /// A newer claim takes the renderer; the older loop's release cannot end the newer one's turn.
    @Test func aNewerClaimTakesOverAndAnOldReleaseLeavesIt() {
        let source = ExerciseAnimationFrameSource()
        #expect(source.owner == nil)
        let first = source.claim()
        #expect(source.owner == first)
        let second = source.claim()
        #expect(second != first && source.owner == second)
        source.release(first)
        #expect(source.owner == second, "the superseded loop's release must not end the playing one")
        source.release(second)
        #expect(source.owner == nil)
    }

    /// A loop the renderer draws nothing for (an unknown ID, or no renderer in this build) ends as a
    /// still, shows no frame, and lets the renderer go.
    @Test func aLoopWithNothingToDrawEndsAsAStill() async {
        let source = ExerciseAnimationFrameSource()
        let entry = ExerciseAnimationEntry(id: "exercise-000", duration: 2, hold: false, stillProgress: 0.25)
        var shown = 0
        let end = await source.play(entry, character: .female, from: 0.25) { _, _ in shown += 1 }
        #expect(end == .unavailable)
        #expect(shown == 0)
        #expect(source.owner == nil, "the loop's claim must be released when it ends")
    }

    /// A cancelled loop stops before drawing and releases its claim.
    @Test func aCancelledLoopStopsAndReleases() async {
        let source = ExerciseAnimationFrameSource()
        let entry = ExerciseAnimationEntry(id: "exercise-001", duration: 2, hold: false, stillProgress: 0)
        // Both run on the main actor, so the task cannot start before this test suspends: it is
        // cancelled before its first frame.
        let task = Task { @MainActor in
            await source.play(entry, character: .male, from: 0) { _, _ in }
        }
        task.cancel()
        #expect(await task.value == .cancelled)
        #expect(source.owner == nil)
    }

    // MARK: - The source

    /// The slot draws the approved animation for an exercise that has one, by the profile's
    /// character, and today's path (the media or the placeholder) for any other.
    @Test func theSlotDrawsTheAnimationOnlyWhenTheExerciseHasOne() throws {
        let sheet = try RepoRoot.source("App/Fernlet/ExerciseHowToSheet.swift")
        let start = try #require(sheet.range(of: "struct ExerciseDemonstrationSlot"))
        let end = try #require(sheet.range(of: "struct ExerciseHowToFacts"))
        let slot = sheet[start.lowerBound..<end.lowerBound]
        let order = ["if let animation = ExerciseAnimationCatalog.entry(forExerciseName: exerciseName) {",
                     "character: ExerciseAnimationCharacter(sex: sex)", "} else {",
                     "ExerciseDemonstrationLibrary.demonstration(", "ExerciseDemonstrationMedia(",
                     "ExerciseDemonstrationPlaceholder("]
        let offsets = order.map { slot.range(of: $0)?.lowerBound }
        #expect(offsets.allSatisfy { $0 != nil }, "the slot lost \(zip(order, offsets).filter { $0.1 == nil }.map(\.0))")
        let found = offsets.compactMap { $0 }
        #expect(found == found.sorted(), "the slot's branches are out of order")
    }

    /// The tile reuses the demonstration's spoken name (one catalog key), pause access and corner
    /// mark; it ignores Smart Invert, stops off screen and in the background, and is 4:3 at the
    /// demonstration's width.
    @Test func theTileSharesTheDemonstrationsAccessAndStopsWhenUnseen() throws {
        let tile = try RepoRoot.source("App/Fernlet/ExerciseAnimationTile.swift")
        for needle in [".accessibilityLabel(ExerciseDemonstrationSpokenName.text(for: exerciseName))",
                       ".modifier(ExerciseDemonstrationPauseAccess(pausable: animates, isPaused: isPaused, toggle: togglePause))",
                       "ExerciseDemonstrationPauseBadge(isPaused: isPaused)", ".accessibilityElement(children: .ignore)",
                       ".accessibilityAddTraits(.isImage)", ".accessibilityIgnoresInvertColors()",
                       ".onTapGesture { togglePause() }", "guard animates else { return }",
                       "isActive: scenePhase == .active", ".onScrollVisibilityChange(", ".task(id: playback)",
                       ".aspectRatio(ExerciseAnimationPlayback.aspectRatio, contentMode: .fit)", ".frame(maxWidth: side)",
                       "ExerciseDemonstrationLayout.cornerRadius", "Color.cream",
                       "ExerciseAnimationCatalog.still(for: entry, character: character)",
                       "reduceMotion: reduceMotion"] {
            #expect(tile.contains(needle), "the animation tile lost `\(needle)`")
        }
        #expect(!tile.contains("Text(\""), "the tile adds no display string of its own")
        let view = try RepoRoot.source("App/Fernlet/ExerciseDemonstrationView.swift")
        #expect(view.components(separatedBy: "Text(\"Demonstration of ").count - 1 == 1,
                "the spoken name is written once, so its catalog key keeps one comment")
        #expect(view.contains("private var spokenName: Text {\n        ExerciseDemonstrationSpokenName.text(for: exerciseName)"))
    }

    /// One renderer on one serial queue, reached only through the frame source; no web view anywhere.
    @Test func oneRendererOnOneQueueAndNoWebView() throws {
        let player = try RepoRoot.source("App/Fernlet/ExerciseAnimationPlayer.swift")
        #expect(player.components(separatedBy: "DispatchQueue(label:").count - 1 == 1)
        #expect(player.components(separatedBy: "ExerciseAnimationRenderer()").count - 1 == 1)
        #expect(player.contains("dispatchPrecondition(condition: .onQueue(queue))"))
        #expect(player.contains("static let shared = ExerciseAnimationFrameSource()"))
        for path in ["App/Fernlet/ExerciseAnimationPlayer.swift", "App/Fernlet/ExerciseAnimationTile.swift",
                     "App/Fernlet/ExerciseHowToSheet.swift", "App/Fernlet/ExerciseDemonstrationView.swift"] {
            let source = try RepoRoot.source(path)
            for banned in ["WKWebView", "import WebKit"] {
                #expect(!source.contains(banned), "\(path) names \(banned): the animations never use a web view")
            }
        }
        let tile = try RepoRoot.source("App/Fernlet/ExerciseAnimationTile.swift")
        #expect(!tile.contains("ExerciseAnimationRenderer("), "the tile draws through the shared frame source only")
    }
}
