import CoreGraphics
import Foundation
import JavaScriptCore
import Testing
@testable import Fernlet

/// The exercise-animation renderer's seams: the approved engine ships inside the app as
/// ExerciseAnimations.bundle and loads, frames are 640 × 480, unknown IDs draw nothing, and the
/// JavaScript arithmetic the port leans on (`Math.hypot`, `Math.cos`/`Math.sin`, `Math.min`/`Math.max`,
/// `Math.round`, `parseInt`-based `pixelColor`, `tint`) behaves as JavaScriptCore's does.
struct ExerciseAnimationRendererTests {
    @Test func theAppCarriesTheEngineBundleWithBothApprovedScripts() throws {
        let engine = try #require(Bundle.main.url(forResource: "ExerciseAnimations", withExtension: "bundle"))
        #expect(engine.deletingLastPathComponent().resolvingSymlinksInPath().path
                == Bundle.main.bundleURL.resolvingSymlinksInPath().path, "the engine bundle sits at the app's top level")
        for name in ["motion-engine.js", "movements.js"] {
            #expect(FileManager.default.fileExists(atPath: engine.appendingPathComponent(name).path), "\(name) missing")
        }
    }

    @Test func aFrameIsTheApprovedCanvasSize() throws {
        let renderer = try #require(ExerciseAnimationRenderer())
        let image = try #require(renderer.frame(exerciseID: "exercise-001", progress: 0.25, character: .male))
        #expect(image.width == ExerciseAnimationRenderer.pixelWidth)
        #expect(image.height == ExerciseAnimationRenderer.pixelHeight)
        #expect(image.bitsPerPixel == 32)
    }

    @Test func anUnknownExerciseDrawsNothing() throws {
        let renderer = try #require(ExerciseAnimationRenderer())
        #expect(renderer.frame(exerciseID: "exercise-200", progress: 0, character: .female) == nil)
        #expect(renderer.frame(exerciseID: "", progress: 0.5, character: .male) == nil)
    }

    @Test func aBundleWithoutTheEngineLoadsNothing() {
        #expect(ExerciseAnimationRenderer(bundle: Bundle(for: BundleToken.self)) == nil)
    }

    @Test func aHeldPoseDrawsTheSameFrameAtEveryProgress() throws {
        let renderer = try #require(ExerciseAnimationRenderer())
        let ids = (1...199).map { String(format: "exercise-%03d", $0) }
        let reference = try #require(ExerciseAnimationReferenceRenderer())
        let held = try #require(ids.first { id in
            reference.context.evaluateScript("movements.find(m => m.id === '\(id)').hold")?.toBool() == true
        })
        let start = try #require(renderer.framePixels(exerciseID: held, progress: 0, character: .male))
        let later = try #require(renderer.framePixels(exerciseID: held, progress: 0.7, character: .male))
        #expect(start.rgbaData() == later.rgbaData())
    }

    @Test func theCharactersDifferOnlyInLook() throws {
        let renderer = try #require(ExerciseAnimationRenderer())
        let male = try #require(renderer.framePixels(exerciseID: "exercise-005", progress: 0.5, character: .male))
        let female = try #require(renderer.framePixels(exerciseID: "exercise-005", progress: 0.5, character: .female))
        #expect(male.rgbaData() != female.rgbaData())
        let shirt = ExerciseAnimationPalette.pixelColor("#71815B"), femaleShirt = ExerciseAnimationPalette.pixelColor("#B16F59")
        #expect(male.pixels.contains(shirt) && !male.pixels.contains(femaleShirt))
        #expect(female.pixels.contains(femaleShirt) && !female.pixels.contains(shirt))
    }

    @Test func hypotMatchesJavaScriptCoreBitForBit() throws {
        let context = try #require(JSContext())
        var generator = ExerciseAnimationTestRandom(seed: 0x5EED)
        let vectors = (0..<4_000).map { _ in
            let scale = pow(10, generator.unit() * 6 - 3)
            return [generator.unit() * 2 - 1, generator.unit() * 2 - 1, generator.unit() * 2 - 1].map { $0 * scale }
        }
        context.setObject(vectors, forKeyedSubscript: "vectors" as NSString)
        let lengths = try #require(context.evaluateScript("vectors.map(v => Math.hypot(...v))")?.toArray() as? [Double])
        for (vector, length) in zip(vectors, lengths) {
            let swift = ExerciseAnimationMath.hypot3(ExerciseAnimationVector(x: vector[0], y: vector[1], z: vector[2]))
            #expect(swift.bitPattern == length.bitPattern, "hypot\(vector)")
        }
    }

    @Test func theRenderersAnglesMatchJavaScriptCoreTrigonometry() throws {
        let context = try #require(JSContext())
        var angles: [Double] = [45, 135, 0, 15, 90, 14, 18, 25, 55].map { $0 * ExerciseAnimationMath.rad }
        for segments in [8, 12, 16, 40] {
            for index in 0...segments {
                angles.append(Double(index) / Double(segments) * Double.pi * 2)
                angles.append((Double(index) + 0.5) / Double(segments) * Double.pi * 2)
            }
        }
        context.setObject(angles, forKeyedSubscript: "angles" as NSString)
        let cosines = try #require(context.evaluateScript("angles.map(Math.cos)")?.toArray() as? [Double])
        let sines = try #require(context.evaluateScript("angles.map(Math.sin)")?.toArray() as? [Double])
        for (index, angle) in angles.enumerated() {
            #expect(cos(angle).bitPattern == cosines[index].bitPattern, "cos(\(angle))")
            #expect(sin(angle).bitPattern == sines[index].bitPattern, "sin(\(angle))")
        }
    }

    @Test func minMaxAndRoundFollowJavaScript() {
        #expect(ExerciseAnimationMath.jsMin(0, -0.0).sign == .minus)
        #expect(ExerciseAnimationMath.jsMax(-0.0, 0).sign == .plus)
        #expect(ExerciseAnimationMath.jsMin(.nan, 1).isNaN && ExerciseAnimationMath.jsMax(1, .nan).isNaN)
        #expect(ExerciseAnimationMath.jsRound(0.49999999999999994) == 0)
        #expect(ExerciseAnimationMath.jsRound(2.5) == 3 && ExerciseAnimationMath.jsRound(-2.5) == -2)
    }

    @Test func pixelColorAndTintMatchTheReferenceRenderer() throws {
        let reference = try #require(ExerciseAnimationReferenceRenderer())
        let samples: [(String, Double)] = [("#392F26", 1), ("#F7EEDC", 0.86), ("#71815B", 1.08), ("#e8ddc6", 0.8),
                                           ("weight", 0.88), ("", 1), ("#12345", 0.96), ("#ABCDEF", 1.2)]
        for (color, shade) in samples {
            let script = "pixelColor(tint('\(color)', \(shade)))"
            let expected = try #require(reference.context.evaluateScript(script)?.toUInt32())
            let ink = ExerciseAnimationInk(colorString: color).tinted(shade)
            #expect(ink.pixel == expected, "\(script)")
        }
        #expect(ExerciseAnimationPalette.pixelColor("weight") == 0xFF0E_0000)
    }

    @Test func thePaletteIsTheReferenceRenderersColors() throws {
        let reference = try #require(ExerciseAnimationReferenceRenderer())
        let colors = try #require(reference.context.evaluateScript("COLORS")?.toDictionary() as? [String: String])
        #expect(colors == ExerciseAnimationPalette.colors)
    }
}

/// A class whose bundle is the test bundle, which carries no engine files.
private final class BundleToken {}

/// A small deterministic generator (ExerciseAnimationTestRandom64) for reproducible test vectors.
struct ExerciseAnimationTestRandom {
    /// The running state.
    var state: UInt64

    /// A generator seeded with `seed`.
    init(seed: UInt64) {
        state = seed
    }

    /// The next value in [0, 1).
    mutating func unit() -> Double {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }
}
