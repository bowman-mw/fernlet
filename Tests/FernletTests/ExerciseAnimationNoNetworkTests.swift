import Foundation
import Testing

/// The exercise-animation runtime has no way to the network (Docs/No-Tracking-Wall.md).
///
/// The approved engine runs in a bare JavaScriptCore `JSContext`: no DOM, no `fetch`, no
/// `XMLHttpRequest`, no `WebSocket`, no web view. Pinned here: the approved JavaScript files (the two
/// in the app bundle and the reference renderer the Swift port is proven against) name none of the
/// browser's network or module-loading APIs, and a `JSContext` (or any JavaScriptCore import) in
/// shipping Swift lives only in the exercise-animation files, so a second script runtime cannot
/// appear elsewhere unnoticed.
struct ExerciseAnimationNoNetworkTests {

    /// The approved JavaScript the app or its tests evaluate.
    static let approvedScripts = [
        "App/Fernlet/ExerciseAnimations.bundle/motion-engine.js",
        "App/Fernlet/ExerciseAnimations.bundle/movements.js",
        "Tests/ExerciseAnimationReference/renderer.js",
    ]

    /// Every spelling of a way out (or a way to load more code) a script could use. Matched as raw,
    /// case-sensitive substrings, so even a comment naming one fails the wall.
    static let networkTokens = [
        "fetch", "XMLHttpRequest", "WebSocket", "URL", "http:", "https:", "importScripts",
        "sendBeacon", "EventSource", "import(",
    ]

    /// The shipping source roots scanned for a script runtime.
    static let shippingRoots = ["App", "FernletKit/Sources"]

    /// The one place a script runtime may live: the animation renderer and its siblings.
    static let runtimeFilePrefix = "App/Fernlet/ExerciseAnimation"

    /// The script-runtime spellings, matched as raw substrings.
    static let runtimeTokens = ["JSContext", "JavaScriptCore", "JSVirtualMachine"]

    /// Far fewer Swift files than this means the scan is broken, not the tree clean.
    static let swiftFileFloor = 300

    /// A generous bound on the files one root walk visits.
    static let maxFilesPerRoot = 50_000

    @Test func theApprovedScriptsNameNoNetworkAPI() throws {
        for path in Self.approvedScripts {
            let source = try RepoRoot.source(path)
            #expect(source.count > 1_000, "\(path) is too short to be the approved file")
            let hits = Self.networkTokens.filter { source.contains($0) }
            #expect(hits.isEmpty, "\(path) names \(hits)")
        }
    }

    @Test func aScriptRuntimeAppearsOnlyInTheAnimationFiles() throws {
        let files = try Self.shippingSwiftFiles()
        #expect(files.count >= Self.swiftFileFloor, "only \(files.count) shipping Swift files were scanned")
        var runtimeFiles: [String] = []
        for path in files {
            let source = try RepoRoot.source(path)
            guard Self.runtimeTokens.contains(where: { source.contains($0) }) else { continue }
            runtimeFiles.append(path)
            #expect(path.hasPrefix(Self.runtimeFilePrefix), "\(path) uses JavaScriptCore outside the animation files")
        }
        #expect(runtimeFiles.contains("App/Fernlet/ExerciseAnimationRenderer.swift"),
                "the renderer no longer names its runtime: the scan is broken")
    }

    @Test func theMatchersFlagPlantedUsesOnly() {
        let planted = "const r = await fetch('x'); new WebSocket(u)"
        #expect(Self.networkTokens.filter { planted.contains($0) } == ["fetch", "WebSocket"])
        #expect(Self.runtimeTokens.contains { "import JavaScriptCore".contains($0) })
        #expect(!Self.runtimeTokens.contains { "import Foundation".contains($0) })
    }

    /// Repository-relative paths of every `.swift` file under the shipping roots.
    static func shippingSwiftFiles() throws -> [String] {
        let rootPath = RepoRoot.url.standardizedFileURL.path + "/"
        var paths: [String] = []
        for root in shippingRoots {
            let walker = try #require(FileManager.default.enumerator(at: RepoRoot.url(root), includingPropertiesForKeys: nil))
            for _ in 0..<maxFilesPerRoot {
                guard let url = walker.nextObject() as? URL else { break }
                guard url.pathExtension == "swift" else { continue }
                paths.append(String(url.standardizedFileURL.path.dropFirst(rootPath.count)))
            }
        }
        return paths
    }
}
