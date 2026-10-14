// ProximityKitSources.swift
// FernletTests
//
// Fernlet's reader of ProximityKit's sources, while they are in this repository. Two FernletTests suites
// read ProximityKit's Swift files: the platform wall (`ProximityPlatformBoundaryTests`) and the feature
// golden's recipe-copy scan (`FernletFeatureGoldenTests`). They read them here, through one walker, so
// they can never read two different trees. ProximityKit's namespace wall, which reads the same files,
// is one of ProximityKit's own package tests and reads them through the package's `PackageRoot`, so it
// travels with the package. Plan step A1.3, which takes ProximityKit's sources out of this repository,
// deletes this file with them.

import Foundation

/// ProximityKit's Swift files as FernletTests reads them: each by its path under the module root and
/// lexed with `SwiftSourceLexer`, sorted by path (since plan step A1.1.7, when the namespace wall that
/// held this walker joined ProximityKit's package tests). Plan step A1.3 deletes it with the sources.
enum ProximityKitSources {

    /// The module, from the repository root.
    private static let moduleRoot = "FernletKit/Sources/ProximityKit"

    /// ProximityKit's Swift files, each by its path under the module root and lexed, sorted by path.
    ///
    /// The walk holds no floor of its own; each caller floors the files it read, so a walk that found
    /// nothing fails there: the platform wall at `minimumFilesWalked` in each cell that reads it, the
    /// feature golden's recipe-copy scan at 50.
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
    /// the file is somehow outside it, which then matches no row and fails loudly. The platform wall's
    /// rows name files by this path.
    static func relativePath(of file: URL) -> String {
        let path = file.path
        guard let range = path.range(of: "/" + moduleRoot + "/", options: .backwards) else { return path }
        return String(path[range.upperBound...])
    }
}
