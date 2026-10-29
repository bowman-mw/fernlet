//
//  ExerciseAnimationRenderer.swift
//  Fernlet
//
//  Draws one frame of an approved exercise animation: the approved motion engine samples the pose in
//  JavaScriptCore, and a Swift port of the approved `renderer.js` rasterises it, pixel for pixel.
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

    /// The approved engine, sampling poses.
    private let engine: ExerciseAnimationEngine
    /// Exercise catalog fields by ID (fetched once each).
    private var exercises: [String: ExerciseAnimationExerciseInfo] = [:]
    /// Framed cameras by `id|view`, as `frameCamera` caches them.
    private var cameras: [String: ExerciseAnimationCamera] = [:]
    /// The packed outline ink (`COLORS.ink`).
    private let outlineInk: UInt32

    /// Loads the approved engine from `bundle`; nil when the engine files are missing or fail to load.
    init?(bundle: Bundle = .main) {
        guard let engine = ExerciseAnimationEngine(bundle: bundle) else { return nil }
        self.engine = engine
        let outline = ExerciseAnimationPalette.colors["ink"] ?? ""
        outlineInk = ExerciseAnimationPalette.pixelColor(outline)
    }

    /// The frame for `exerciseID` (`exercise-NNN`) at normalized loop `progress` (0...1), drawn by
    /// `character` at the exercise's approved camera; nil for an unknown ID.
    func frame(exerciseID: String, progress: Double, character: ExerciseAnimationCharacter) -> CGImage? {
        guard let pixels = framePixels(exerciseID: exerciseID, progress: progress, character: character) else {
            return nil
        }
        assert(pixels.pixels.count == Self.pixelWidth * Self.pixelHeight, "a frame fills the whole canvas")
        return pixels.makeImage()
    }

    /// The frame's raster (packed `0xAABBGGRR` pixels): `renderExercise(ctx, e, progress, person)`.
    func framePixels(exerciseID: String, progress: Double,
                     character: ExerciseAnimationCharacter) -> ExerciseAnimationRaster? {
        guard let pose = pose(exerciseID: exerciseID, progress: progress) else { return nil }
        return rasterize(pose, exerciseID: exerciseID, character: character)
    }

    /// `sampleExercise(e, progress)`: the pose the engine samples for this frame.
    func pose(exerciseID: String, progress: Double) -> ExerciseAnimationPose? {
        guard exercise(exerciseID) != nil else { return nil }
        return engine.pose(exerciseID, progress: progress)
    }

    /// `drawExercise(ctx, e, pose, person)`: frames the camera (once per exercise, after the first
    /// pose is sampled, as the JavaScript does) and draws `pose`.
    func rasterize(_ pose: ExerciseAnimationPose, exerciseID: String,
                   character: ExerciseAnimationCharacter) -> ExerciseAnimationRaster? {
        guard let info = exercise(exerciseID), let camera = camera(for: info) else { return nil }
        var painter = ExerciseAnimationPainter(raster: ExerciseAnimationRaster(outlineInk: outlineInk), pose: pose,
                                               camera: camera, character: character)
        painter.draw()
        return painter.raster
    }

    /// The exercise's catalog fields, cached.
    private func exercise(_ exerciseID: String) -> ExerciseAnimationExerciseInfo? {
        if let cached = exercises[exerciseID] { return cached }
        guard let info = engine.exercise(exerciseID) else { return nil }
        exercises[exerciseID] = info
        return info
    }

    /// `frameCamera(e, 'exercise')`, cached by `id|exercise`.
    private func camera(for info: ExerciseAnimationExerciseInfo) -> ExerciseAnimationCamera? {
        let key = info.id + "|" + ExerciseAnimationCameraRig.exerciseView
        if let cached = cameras[key] { return cached }
        guard let poses = engine.framingPoses(info.id),
              let camera = ExerciseAnimationCameraRig.frame(info, poses: poses) else { return nil }
        cameras[key] = camera
        return camera
    }
}
