import CryptoKit
import Foundation
import JavaScriptCore
import Testing
@testable import Fernlet

/// The Swift renderer draws exactly the pixels the approved JavaScript renderer draws.
///
/// A test JavaScriptCore context loads the app bundle's approved `movements.js` and `motion-engine.js`
/// and the approved reference `renderer.js` (Tests/ExerciseAnimationReference, byte-identical to the r12
/// package), with a two-method canvas stand-in like the package's `jsc-bench.js`. Every one of the 199
/// exercises is drawn by both characters at the default camera at loop phases 0 and 0.5, and by one
/// character (alternating with the exercise number) at a third phase spread across the loop by the
/// number: 995 frames, each drawn once in JavaScript and once in Swift, and the RGBA buffers must be
/// identical byte for byte: no tolerance.
struct ExerciseAnimationRendererEquivalenceTests {
    /// The exercises in groups of 25, one test case each, so the cases can run side by side.
    static let groups: [ClosedRange<Int>] = stride(from: 1, through: 199, by: 25).map { $0...min($0 + 24, 199) }

    /// The phases drawn for exercise `number` by `character`: the loop's start and middle, plus (for the
    /// male character on odd numbers and the female on even ones) a phase spread across the loop by the
    /// number.
    static func phases(for number: Int, character: ExerciseAnimationCharacter) -> [Double] {
        let third = (number % 2 == 1) == (character == .male)
        return third ? [0, 0.5, Double((number * 61) % 97) / 97] : [0, 0.5]
    }

    @Test(arguments: groups)
    func everyFrameMatchesTheReferenceRendererByteForByte(numbers: ClosedRange<Int>) throws {
        let reference = try #require(ExerciseAnimationReferenceRenderer())
        let renderer = try #require(ExerciseAnimationRenderer(bundle: .main))
        let clock = ContinuousClock()
        var javaScriptTime = Duration.zero, swiftTime = Duration.zero, frames = 0
        for number in numbers {
            let id = String(format: "exercise-%03d", number)
            for character in ExerciseAnimationCharacter.allCases {
                for phase in Self.phases(for: number, character: character) {
                    let start = clock.now
                    let expected = try #require(reference.render(id: id, progress: phase, person: character.rawValue))
                    let middle = clock.now
                    let raster = try #require(renderer.framePixels(exerciseID: id, progress: phase, character: character))
                    let actual = raster.rgbaData()
                    javaScriptTime += middle - start
                    swiftTime += clock.now - middle
                    frames += 1
                    #expect(actual == expected, "\(id) \(character.rawValue) @\(phase): \(Self.differingPixels(expected, actual)) pixels differ")
                }
            }
        }
        print("ExerciseAnimationRendererEquivalence \(numbers): \(frames) frames, JS \(javaScriptTime / frames) / frame, Swift \(swiftTime / frames) / frame")
    }

    /// How many RGBA pixels differ between two canvases (all of them when the sizes differ).
    static func differingPixels(_ expected: Data, _ actual: Data) -> Int {
        guard expected.count == actual.count else { return max(expected.count, actual.count) / 4 }
        let left = [UInt8](expected), right = [UInt8](actual)
        return stride(from: 0, to: left.count, by: 4).filter { left[$0..<$0 + 4] != right[$0..<$0 + 4] }.count
    }

    /// The comparison is only meaningful against the approved bytes: the app bundle's engine files and
    /// the reference renderer hash to the package manifest's SHA-256 values.
    @Test func theEngineAndReferenceAreTheApprovedPackageBytes() throws {
        let manifest = try JSONSerialization.jsonObject(
            with: Data(contentsOf: RepoRoot.url("Tests/ExerciseAnimationReference/manifest.json"))) as? [String: Any]
        let hashes = try #require(manifest?["files"] as? [String: String])
        let engine = try #require(Bundle.main.url(forResource: "ExerciseAnimations", withExtension: "bundle"))
        let files: [(String, URL)] = [
            ("Resources/FernletAnimations/movements.js", engine.appendingPathComponent("movements.js")),
            ("Resources/FernletAnimations/motion-engine.js", engine.appendingPathComponent("motion-engine.js")),
            ("Resources/FernletAnimations/renderer.js", RepoRoot.url("Tests/ExerciseAnimationReference/renderer.js")),
        ]
        for (key, url) in files {
            let digest = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
            #expect(digest == hashes[key], "\(url.lastPathComponent) is not the approved \(key)")
        }
    }
}

/// The approved JavaScript renderer in its own JavaScriptCore context, drawing into a canvas stand-in
/// (`createImageData` returns `{width, height, data: Uint8ClampedArray}`, `putImageData` keeps it).
final class ExerciseAnimationReferenceRenderer {
    /// The context holding the engine, the reference renderer and the canvas stand-in.
    let context: JSContext
    /// `__fernletRender(id, t, person)`: draws a frame and returns its `ImageData.data`.
    let entryPoint: JSValue

    /// The canvas stand-in and the render entry point, after the approved scripts.
    static let harness = """
    const __canvas = { width: 640, height: 480 };
    const __ctx = { canvas: __canvas,
                    createImageData: (w, h) => ({ width: w, height: h, data: new Uint8ClampedArray(w * h * 4) }),
                    putImageData: (image) => { __ctx.last = image; } };
    function __fernletRender(id, t, person) {
      const e = movements.find(m => m.id === id);
      if (!e) return null;
      renderExercise(__ctx, e, t, person, 'exercise');
      return __ctx.last.data;
    }
    """

    /// Loads the app bundle's engine files and the repository's reference renderer; nil if any is
    /// missing or throws.
    init?() {
        guard let context = JSContext(),
              let engine = Bundle.main.url(forResource: "ExerciseAnimations", withExtension: "bundle") else { return nil }
        let sources = [engine.appendingPathComponent("movements.js"), engine.appendingPathComponent("motion-engine.js"),
                       RepoRoot.url("Tests/ExerciseAnimationReference/renderer.js")]
        for url in sources {
            guard let source = try? String(contentsOf: url, encoding: .utf8) else { return nil }
            context.evaluateScript(source)
        }
        context.evaluateScript(Self.harness)
        guard context.exception == nil, let entryPoint = context.objectForKeyedSubscript("__fernletRender") else { return nil }
        self.context = context
        self.entryPoint = entryPoint
    }

    /// The RGBA bytes the reference renderer draws for `id` at `progress`, or nil on a JavaScript error.
    func render(id: String, progress: Double, person: String) -> Data? {
        guard let data = entryPoint.call(withArguments: [id, progress, person]), context.exception == nil,
              let reference = data.jsValueRef else { return nil }
        let global = context.jsGlobalContextRef
        var exception: JSValueRef?
        guard let bytes = JSObjectGetTypedArrayBytesPtr(global, reference, &exception), exception == nil else { return nil }
        let count = JSObjectGetTypedArrayByteLength(global, reference, &exception)
        return Data(bytes: bytes, count: count)
    }
}
