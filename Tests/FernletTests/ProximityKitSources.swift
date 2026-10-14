// ProximityKitSources.swift
// FernletTests
//
// Fernlet's reader of ProximityKit's sources, while they are in this repository. One FernletTests suite
// reads ProximityKit's Swift files: the feature golden's recipe-copy scan (`FernletFeatureGoldenTests`).
// It reads them here, through the walk the namespace wall held while it was in FernletTests.
// ProximityKit's namespace wall and the platform wall's rules over ProximityKit's code, which read the
// same files, are ProximityKit's own package tests (`ProximityNamespaceBoundaryTests` and
// `ProximityPlatformNeutralityTests`) and read them through the package's `PackageRoot`, so they travel
// with the package. Plan step A1.3, which takes ProximityKit's sources out of this repository, deletes
// this file with them.

import Foundation

/// ProximityKit's Swift files as FernletTests reads them: each by its path under the module root and
/// lexed with `SwiftSourceLexer`, sorted by path (since plan step A1.1.7, when the namespace wall that
/// held this walker joined ProximityKit's package tests). Plan step A1.3 deletes it with the sources.
enum ProximityKitSources {

    /// The module, from the repository root.
    private static let moduleRoot = "FernletKit/Sources/ProximityKit"

    /// ProximityKit's Swift files, each by its path under the module root and lexed, sorted by path.
    ///
    /// The walk holds no floor of its own; its caller floors the files it read, so a walk that found
    /// nothing fails there: the feature golden's recipe-copy scan at 50.
    static func proximitySources() throws -> [(path: String, lexed: SwiftSourceLexer.Lexed)] {
        let root = RepoRoot.url(moduleRoot)
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (walker?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var sources: [(path: String, lexed: SwiftSourceLexer.Lexed)] = []
        // R2: bounded by the module's file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            sources.append((path: relativePath(of: file), lexed: SwiftSourceLexer.lex(source)))
        }
        return sources
    }

    /// `file`'s path under the module root, read off the path's own `FernletKit/Sources/ProximityKit/`
    /// component so a symlinked checkout (`/tmp` and `/private/tmp`) resolves alike; the full path if
    /// the file is somehow outside it. The feature golden's recipe-copy scan names a stray literal's file
    /// by this path.
    static func relativePath(of file: URL) -> String {
        let path = file.path
        guard let range = path.range(of: "/" + moduleRoot + "/", options: .backwards) else { return path }
        return String(path[range.upperBound...])
    }
}
