import Foundation
import Testing
@testable import Fernlet

/// How long the Swift renderer takes per frame, on the package benchmark's set (`jsc-bench.js`:
/// exercise-001, -086, -150 and -199, 24 frames each, male, default camera), split into the engine's
/// pose sample (JavaScriptCore), the Swift raster, and the CGImage hand-off. The numbers are printed for
/// the record; the bound only catches a pathological regression, since a Debug simulator build on a
/// shared Mac is far slower than a Release build on a phone.
@Suite(.serialized)
struct ExerciseAnimationRendererPerformanceTests {
    /// The benchmark's exercises.
    static let benchmarkIDs = ["exercise-001", "exercise-086", "exercise-150", "exercise-199"]
    /// Frames per exercise, as the benchmark draws.
    static let framesPerExercise = 24

    @Test func framesStayWellInsideTheBudget() throws {
        let clock = ContinuousClock()
        let loadStart = clock.now
        let renderer = try #require(ExerciseAnimationRenderer())
        print("ExerciseAnimationRendererPerformance engine load \(clock.now - loadStart)")
        for id in Self.benchmarkIDs {
            _ = try #require(renderer.framePixels(exerciseID: id, progress: 0, character: .male))
            var sampling = Duration.zero, raster = Duration.zero, image = Duration.zero
            for frame in 0..<Self.framesPerExercise {
                let start = clock.now
                let pose = try #require(renderer.pose(exerciseID: id, progress: Double(frame) / Double(Self.framesPerExercise)))
                let sampled = clock.now
                let pixels = try #require(renderer.rasterize(pose, exerciseID: id, character: .male))
                let drawn = clock.now
                _ = try #require(pixels.makeImage())
                sampling += sampled - start
                raster += drawn - sampled
                image += clock.now - drawn
            }
            let count = Self.framesPerExercise
            print("ExerciseAnimationRendererPerformance \(id): pose \(sampling / count), raster \(raster / count), image \(image / count) per frame")
            #expect((sampling + raster + image) / count < .milliseconds(250), "\(id) takes \((sampling + raster + image) / count) per frame")
        }
    }
}
