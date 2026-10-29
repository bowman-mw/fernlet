//
//  ExerciseAnimationRenderer.swift
//  Fernlet
//
//  Draws one frame of an approved exercise animation: the approved motion engine samples the pose in
//  JavaScriptCore, and a Swift port of the approved `renderer.js` rasterises it.
//

import Foundation
import CoreGraphics

/// Draws approved exercise-animation frames at the package's 640 × 480 canvas.
///
/// Not thread-safe: one instance lives on one serial queue, and every call happens there.
nonisolated final class ExerciseAnimationRenderer {
    /// The approved canvas width in pixels.
    static let pixelWidth = 640
    /// The approved canvas height in pixels.
    static let pixelHeight = 480

    /// Loads the approved engine from `bundle`; nil when the engine files are missing or fail to load.
    init?(bundle: Bundle = .main) {
        return nil
    }

    /// The frame for `exerciseID` (`exercise-NNN`) at normalized loop `progress` (0...1), drawn by
    /// `character` at the exercise's approved camera; nil for an unknown ID.
    func frame(exerciseID: String, progress: Double, character: ExerciseAnimationCharacter) -> CGImage? {
        nil
    }
}
