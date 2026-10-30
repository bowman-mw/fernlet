//
//  ExerciseAnimationPlayer.swift
//  Fernlet
//
//  Plays the owner's approved exercise animations (package revision r12) for the how-to sheet's
//  demonstration tile (`ExerciseAnimationTile.swift`). One frame source serves the whole app: it owns
//  the single `ExerciseAnimationRenderer` (the approved motion engine sampling each pose in
//  JavaScriptCore, a Swift port of the approved `renderer.js` drawing it) on one serial background
//  queue, so at most one loop renders at a time and a tile that starts playing ends the loop before
//  it. Frames come back to the main actor on a fixed tick, at most 24 a second; a slow frame skips
//  to the next tick instead of queueing frames up. No web view is involved, ever.
//

import Foundation
import CoreGraphics

/// The animation tile's pure rules: when it moves, where a loop starts, which progress a moment
/// shows, when the next frame is due and how tall the 4:3 tile is. Kept out of the view so each is
/// unit-tested (`ExerciseAnimationTileTests`).
nonisolated enum ExerciseAnimationPlayback {
    /// The most frames a second a loop draws.
    static let framesPerSecond = 24.0
    /// The time between two ticks, in seconds.
    static let frameInterval = 1.0 / framesPerSecond
    /// Ticks one playback draws before it rests on its frame: half an hour at 24 a second (Power of
    /// 10 rule 2). Cancellation ends a loop far sooner in practice.
    static let maxTicks = 43_200
    /// Width over height of the approved 640 × 480 canvas.
    static let aspectRatio: CGFloat = 4.0 / 3.0
    /// Slack when counting whole ticks, so a moment exactly on a tick counts as reached.
    private static let tickSlack = 1e-9

    /// The tile's height for `width`: three quarters of it, or zero for an unusable width.
    static func height(forWidth width: CGFloat) -> CGFloat {
        guard width.isFinite, width > 0 else { return 0 }
        return width / aspectRatio
    }

    /// Whether the tile moves at all: not a held pose, and the renderer is there. Anything else is
    /// a still, with nothing to pause.
    static func animates(hold: Bool, rendererAvailable: Bool) -> Bool {
        !hold && rendererAvailable
    }

    /// Whether the tile's loop runs: it moves, is on screen, the scene is active and it is not
    /// paused. Anything else holds the frame on screen.
    static func loops(animates: Bool, isOnScreen: Bool, isActive: Bool, isPaused: Bool) -> Bool {
        animates && isOnScreen && isActive && !isPaused
    }

    /// Whether the tile is paused: the person's own choice once they made one (a tap, or the Pause
    /// or Play action), else Reduce Motion, so with it on the tile starts paused on its still.
    static func isPaused(choice: Bool?, reduceMotion: Bool) -> Bool {
        choice ?? reduceMotion
    }

    /// `progress` wrapped into `0..<1`; anything not finite gives 0.
    static func wrapped(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        let remainder = progress.truncatingRemainder(dividingBy: 1)
        guard remainder < 0 else { return remainder }
        let lifted = remainder + 1
        return lifted < 1 ? lifted : 0
    }

    /// Where a playback starts: where the last one stopped (`saved`, so a pause holds its frame and
    /// play carries on from it), else the progress the still shows, so play never jumps.
    static func startProgress(saved: Double?, stillProgress: Double) -> Double {
        wrapped(saved ?? stillProgress)
    }

    /// The progress `elapsed` seconds into a loop of `duration` seconds that started at `start`:
    /// `(start + elapsed / duration) mod 1`. No time yet, or an unusable duration, shows `start`.
    static func progress(start: Double, elapsed: Double, duration: Double) -> Double {
        guard duration.isFinite, duration > 0, elapsed.isFinite, elapsed > 0 else { return wrapped(start) }
        return wrapped(start + elapsed / duration)
    }

    /// The first tick strictly after `elapsed` seconds, in seconds since the loop started. Ticks are
    /// whole multiples of ``frameInterval``, so a frame that took longer than one tick drops to the
    /// next free tick rather than queueing the ones it missed.
    static func nextTick(after elapsed: Double) -> Double {
        guard elapsed.isFinite, elapsed >= 0 else { return frameInterval }
        let reached = (elapsed / frameInterval + tickSlack).rounded(.down)
        return (reached + 1) * frameInterval
    }

    /// `duration` in seconds.
    static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// How a playback loop ended.
nonisolated enum ExerciseAnimationLoopEnd: Equatable, Sendable {
    /// Its task was cancelled: a pause, the tile leaving the screen, the scene leaving `.active`, or
    /// the sheet closing.
    case cancelled
    /// Another tile started playing and took the renderer.
    case superseded
    /// The renderer could not load, or drew nothing for this exercise: the tile becomes a still.
    case unavailable
    /// It drew ``ExerciseAnimationPlayback/maxTicks`` frames and rests on the last.
    case finished
}

/// The app's one source of live animation frames.
///
/// It owns one ``ExerciseAnimationRenderWorker``, made on the first play and kept for the app's
/// life (an idle serial queue costs nothing), and lets one loop play at a time: ``play(_:character:from:show:)``
/// claims it, and a newer claim ends the older loop before its next frame. When the playing loop
/// ends, nothing plays, so the worker lets its renderer (and the JavaScriptCore context in it) go;
/// the next play loads it again.
final class ExerciseAnimationFrameSource {
    /// The one source every tile plays through.
    static let shared = ExerciseAnimationFrameSource()

    /// Made on the first play; holds the renderer only while a loop plays.
    private var worker: ExerciseAnimationRenderWorker?
    /// The latest claim's token.
    private var generation = 0
    /// The token of the loop playing now, or nil when none plays.
    private(set) var owner: Int?
    /// The renderer failed to load in this run, so every tile is a still.
    private(set) var isUnavailable = false

    /// Makes the caller the one playing loop; any other loop ends before its next frame.
    func claim() -> Int {
        generation &+= 1
        owner = generation
        return generation
    }

    /// Ends `token`'s turn. When it was the playing loop, nothing plays now, so the renderer is let go.
    func release(_ token: Int) {
        guard owner == token else { return }
        owner = nil
        worker?.dropRenderer()
    }

    /// Plays `entry` drawn by `character` from `startProgress`, handing each frame and its progress
    /// to `show` on the main actor, until the task is cancelled, another tile claims the renderer,
    /// the renderer draws nothing, or ``ExerciseAnimationPlayback/maxTicks`` frames have shown.
    func play(_ entry: ExerciseAnimationEntry, character: ExerciseAnimationCharacter, from startProgress: Double,
              show: (CGImage, Double) -> Void) async -> ExerciseAnimationLoopEnd {
        let token = claim()
        defer { release(token) }
        let worker = currentWorker()
        let start = ContinuousClock.now
        for _ in 1...ExerciseAnimationPlayback.maxTicks {
            if let end = stop(token) { return end }
            let progress = ExerciseAnimationPlayback.progress(
                start: startProgress, elapsed: Self.elapsed(since: start), duration: entry.duration)
            let outcome = await worker.frame(
                ExerciseAnimationFrameRequest(exerciseID: entry.id, progress: progress, character: character))
            if let end = stop(token) { return end }
            switch outcome {
            case .frame(let image):
                show(image, progress)
            case .noRenderer:
                isUnavailable = true
                return .unavailable
            case .noFrame:
                return .unavailable
            }
            let next = ExerciseAnimationPlayback.nextTick(after: Self.elapsed(since: start))
            do {
                try await Task.sleep(until: start.advanced(by: .seconds(next)), clock: .continuous)
            } catch {
                // Cancelled while waiting for the tick: the frame on screen stays.
                return .cancelled
            }
        }
        return .finished
    }

    /// Why `token`'s loop must stop now, or nil to carry on.
    private func stop(_ token: Int) -> ExerciseAnimationLoopEnd? {
        guard !Task.isCancelled else { return .cancelled }
        return owner == token ? nil : .superseded
    }

    /// The worker, made on first use.
    private func currentWorker() -> ExerciseAnimationRenderWorker {
        if let worker { return worker }
        let made = ExerciseAnimationRenderWorker()
        worker = made
        return made
    }

    /// Seconds since `start` on the continuous clock.
    private static func elapsed(since start: ContinuousClock.Instant) -> Double {
        ExerciseAnimationPlayback.seconds(start.duration(to: .now))
    }
}

/// One frame a loop asks for.
nonisolated struct ExerciseAnimationFrameRequest: Equatable, Sendable {
    /// The package's stable ID, `exercise-NNN`.
    let exerciseID: String
    /// Normalized loop progress, `0..<1`.
    let progress: Double
    let character: ExerciseAnimationCharacter
}

/// What the worker drew for one request.
///
/// `@unchecked Sendable` for one payload: a `CGImage` is immutable once made, so handing it from
/// the render queue to the main actor shares nothing that changes.
nonisolated enum ExerciseAnimationRenderOutcome: @unchecked Sendable {
    /// The frame, 640 × 480.
    case frame(CGImage)
    /// The renderer could not load in this run.
    case noRenderer
    /// The renderer loaded but drew nothing for this request (an unknown ID).
    case noFrame
}

/// The renderer's home: one serial background queue and, while a loop plays, the one
/// ``ExerciseAnimationRenderer`` on it.
///
/// `@unchecked Sendable` because ``renderer`` and ``failed`` are read and written only inside
/// blocks on ``queue`` (checked with `dispatchPrecondition`), and the renderer is made, used and
/// let go there too, as its own contract asks.
nonisolated final class ExerciseAnimationRenderWorker: @unchecked Sendable {
    /// Every renderer call, and every touch of the state below, happens here.
    private let queue = DispatchQueue(label: "MBO.Fernlet.exercise-animation", qos: .userInitiated)
    /// Loaded on the first frame after a drop; nil while no loop plays.
    private var renderer: ExerciseAnimationRenderer?
    /// The renderer failed to load once; this run does not try again.
    private var failed = false

    /// Draws `request` on the queue and hands the outcome back to the caller.
    func frame(_ request: ExerciseAnimationFrameRequest) async -> ExerciseAnimationRenderOutcome {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.render(request))
            }
        }
    }

    /// Lets the renderer go once the frames already asked for are drawn.
    func dropRenderer() {
        queue.async {
            self.renderer = nil
        }
    }

    /// Loads the renderer if needed and draws one frame. Runs on ``queue`` only.
    private func render(_ request: ExerciseAnimationFrameRequest) -> ExerciseAnimationRenderOutcome {
        dispatchPrecondition(condition: .onQueue(queue))
        if renderer == nil, !failed {
            renderer = ExerciseAnimationRenderer()
            failed = renderer == nil
        }
        guard let renderer else { return .noRenderer }
        guard let image = renderer.frame(
            exerciseID: request.exerciseID, progress: request.progress, character: request.character) else {
            return .noFrame
        }
        return .frame(image)
    }
}
