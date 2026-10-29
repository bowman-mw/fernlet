//
//  ExerciseAnimationTile.swift
//  Fernlet
//
//  The how-to sheet's demonstration for a bundled catalog exercise: the owner's approved animation
//  (package revision r12, approved 2026-10-29), drawn as a 4:3 tile. It rests on the generated still
//  until a loop plays; live frames come from `ExerciseAnimationFrameSource` (the approved motion
//  engine samples each pose in JavaScriptCore, a Swift port of the approved renderer rasterises it)
//  and carry on from the still's own moment, so play never jumps. Playback stops when the tile
//  scrolls out of view, the app leaves the foreground, the sheet closes or the person taps it (WCAG
//  2.2.2); with Reduce Motion on it starts paused on the still. Custom exercises have no animation
//  and keep the tile in `ExerciseDemonstrationView.swift`.
//

import SwiftUI
import CoreGraphics
import FernletUI

/// One approved exercise animation as a 4:3 tile, the width rules of today's demonstration
/// (``ExerciseDemonstrationLayout/side(forVisibleHeight:)`` at most, centred, the same corners).
///
/// It draws the generated still (``ExerciseAnimationCatalog/still(for:character:)``) until a live
/// frame arrives, and a cream tile when the build has neither. VoiceOver reads it as one image,
/// "Demonstration of <display name>", like ``ExerciseDemonstrationMedia``; it ignores Smart Invert.
///
/// **Pausing.** A moving tile has the same tap, corner mark (``ExerciseDemonstrationPauseBadge``)
/// and VoiceOver / Voice Control pause access (``ExerciseDemonstrationPauseAccess``) as a looping
/// demonstration: a pause holds the frame on screen and play carries on from its progress. Reduce
/// Motion starts it paused; a tap still plays it. A held pose, or a build whose renderer cannot load,
/// is a still: no mark, no pause access.
///
/// **Playback.** `.task(id:)` runs the loop through the app's one frame source, so it is cancelled
/// when the sheet closes and restarted when the key changes: on and off screen, the scene's phase,
/// a pause. Another tile that starts playing ends this one's loop and leaves it paused.
struct ExerciseAnimationTile: View {
    let entry: ExerciseAnimationEntry
    /// The approved character, from the profile's Sex.
    let character: ExerciseAnimationCharacter
    /// The frozen catalog name; the spoken label draws its display name.
    let exerciseName: String
    /// The tile's widest width, from ``ExerciseDemonstrationLayout/side(forVisibleHeight:)``.
    let side: CGFloat

    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The generated still, loaded once the tile first shows.
    @State private var still: CGImage?
    /// The last live frame; it stays on screen through a pause.
    @State private var liveFrame: CGImage?
    /// The progress ``liveFrame`` shows, so the next playback carries on from it.
    @State private var savedProgress: Double?
    @State private var isOnScreen = true
    /// The person's own pause choice; nil until they make one (Reduce Motion decides until then).
    @State private var pauseChoice: Bool?
    /// The renderer drew nothing for this tile, so it is a still.
    @State private var rendererMissing = false

    private var animates: Bool {
        ExerciseAnimationPlayback.animates(
            hold: entry.hold,
            rendererAvailable: !rendererMissing && !ExerciseAnimationFrameSource.shared.isUnavailable)
    }

    private var isPaused: Bool {
        ExerciseAnimationPlayback.isPaused(choice: pauseChoice, reduceMotion: reduceMotion)
    }

    private var playback: ExerciseAnimationTilePlayback {
        ExerciseAnimationTilePlayback(
            exerciseID: entry.id, character: character,
            loops: ExerciseAnimationPlayback.loops(
                animates: animates, isOnScreen: isOnScreen, isActive: scenePhase == .active, isPaused: isPaused))
    }

    var body: some View {
        ZStack {
            Color.cream
            if let frame = liveFrame ?? still {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
            }
        }
        .aspectRatio(ExerciseAnimationPlayback.aspectRatio, contentMode: .fit)
        .overlay(alignment: .bottomTrailing) {
            if animates {
                ExerciseDemonstrationPauseBadge(isPaused: isPaused)
            }
        }
        .frame(maxWidth: side)
        .clipShape(RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius))
        .contentShape(RoundedRectangle(cornerRadius: ExerciseDemonstrationLayout.cornerRadius))
        .onTapGesture { togglePause() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(ExerciseDemonstrationSpokenName.text(for: exerciseName))
        .accessibilityAddTraits(.isImage)
        .modifier(ExerciseDemonstrationPauseAccess(pausable: animates, isPaused: isPaused, toggle: togglePause))
        .accessibilityIgnoresInvertColors()
        .frame(maxWidth: .infinity)
        .onScrollVisibilityChange(threshold: 0.1) { isOnScreen = $0 }
        .task(id: playback) { await play(playback) }
    }

    /// Pauses a moving tile, or plays it again. A still has nothing to pause.
    private func togglePause() {
        guard animates else { return }
        pauseChoice = !isPaused
    }

    /// Shows the still, then, for a looping playback, live frames from where the last playback
    /// stopped (or from the still's progress) until the loop ends. A loop that loses the renderer
    /// turns the tile into a still; one another tile took over is left paused.
    private func play(_ playback: ExerciseAnimationTilePlayback) async {
        if still == nil {
            still = ExerciseAnimationCatalog.still(for: entry, character: character)
        }
        guard playback.loops else { return }
        let start = ExerciseAnimationPlayback.startProgress(saved: savedProgress, stillProgress: entry.stillProgress)
        let end = await ExerciseAnimationFrameSource.shared.play(entry, character: character, from: start) { frame, progress in
            liveFrame = frame
            savedProgress = progress
        }
        switch end {
        case .unavailable:
            rendererMissing = true
        case .superseded where !Task.isCancelled:
            pauseChoice = true
        case .superseded, .cancelled, .finished:
            break
        }
    }
}

/// What an animation tile is playing, as its `.task` identity: a change restarts playback.
struct ExerciseAnimationTilePlayback: Equatable {
    /// The package's stable ID, `exercise-NNN`.
    let exerciseID: String
    let character: ExerciseAnimationCharacter
    /// Loop live frames; false holds the frame on screen (a still, paused, off screen, inactive).
    let loops: Bool
}
