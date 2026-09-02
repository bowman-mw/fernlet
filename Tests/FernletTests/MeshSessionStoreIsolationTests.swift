// MeshSessionStoreIsolationTests.swift
// FernletTests
//
// Grep-wall keeping every test `MeshSessionStore` on its OWN scope — directory AND keychain
// service — in the idiom of `PhotoDirectoryIsolationTests`.
//
// The shared-disk-root flake family is a well-documented cross-suite hazard in this tree: XCTest and
// Swift Testing suites run in parallel inside ONE process, so anything rooted at a process-global
// path or a fixed keychain service is destroyed for every concurrently-running suite the moment one
// of them wipes. P3 item 2 adds a NEW persisted surface — `MeshSessionContext.sealed` plus the
// `com.fernlet.mesh-session` key that seals it — and `MeshSessionStore.wipeForDeleteAll` destroys
// both by service and by path. The family must not gain a member.
//
// Source-scanning is the only way to catch the omission: `MeshSessionStore(scope: .production)`
// compiles, passes in isolation every time, and lands its damage in somebody else's suite.
//
// The wall has two halves, because this store's isolation has two:
//   • the STORE half — every construction in the test tree names a scope, and never the production
//     one;
//   • the APP half — `FernletStore.meshSessionStorage` derives BOTH pieces from seams that are
//     already walled (`proximitySupportRoot`, `heartDropKeychainService`), which is what makes a
//     test store that is isolated for hearts isolated for mesh-session state for free. If that
//     derivation is ever replaced by a production constant, this wall goes red rather than the
//     flake appearing three suites away.

import Foundation
import Testing
@testable import ProximityKit

struct MeshSessionStoreIsolationTests {

    /// This file names the constructors in its own scanner literals, so exclude it from the sweep.
    private static let excludedFiles: Set<String> = ["MeshSessionStoreIsolationTests.swift"]

    // MARK: - The store half

    /// Every `MeshSessionStore(…)` in the test tree passes an explicit `scope:`.
    ///
    /// The initialiser has no default, so today this cannot even compile wrong — which is exactly
    /// why the wall is worth having: the cheapest "convenience" a future change could add is a
    /// defaulted `scope: .production`, and that change would be invisible to every other test.
    @Test func everyTestStoreConstructionNamesItsScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            for arguments in Self.constructionArguments(of: "MeshSessionStore(", in: source) {
                scanned += 1
                #expect(
                    arguments.contains("scope:"),
                    """
                    \(file) constructs MeshSessionStore without `scope:`, so it shares the process-wide \
                    sealed-context file and the process-wide `com.fernlet.mesh-session` keychain row \
                    with every other live store — any concurrent test that runs "delete everything" \
                    destroys both. Pass a per-test scope (see MeshSessionStoreFixtures.scope()).
                    """
                )
            }
        }
        #expect(scanned >= 8, "the MeshSessionStore construction scan found only \(scanned) sites — scanner broken?")
    }

    /// No test builds the PRODUCTION scope, by either spelling.
    ///
    /// The directory half alone is not enough and neither is the key half: files on a private root
    /// sealed by a shared key survive somebody else's wipe as ciphertext nothing can open, which is
    /// strictly worse than losing them outright. So both spellings that resolve to production —
    /// `MeshSessionStorageScope.production` and a hand-built scope naming
    /// `ProximitySupportLayout.defaultDirectory` or the production service literal — are banned in
    /// the test tree.
    @Test func noTestReachesTheProductionScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            scanned += 1
            #expect(
                !source.contains("MeshSessionStorageScope.production"),
                "\(file) uses the PRODUCTION mesh-session scope — it shares the real file and the real keychain row with every concurrent suite."
            )
            for arguments in Self.constructionArguments(of: "MeshSessionStorageScope(", in: source) {
                #expect(
                    !arguments.contains("ProximitySupportLayout.defaultDirectory"),
                    "\(file) builds a mesh-session scope on the production sidecar directory: \(arguments)"
                )
                #expect(
                    !arguments.contains("\"com.fernlet.mesh-session\""),
                    "\(file) builds a mesh-session scope on the production keychain service: \(arguments)"
                )
            }
        }
        #expect(scanned > 100, "the test-source sweep found only \(scanned) files — the test root moved?")
    }

    // MARK: - The app half

    /// `FernletStore.meshSessionStorage` derives both halves from seams other walls already enforce.
    ///
    /// This is the load-bearing reason the store needs no fourth injectable seam on `FernletStore`:
    /// `PhotoDirectoryIsolationTests` already requires every test file that reaches `deleteAllData`
    /// and builds a store DIRECTLY to pass `proximitySupportDirectory:` **and**
    /// `heartDropKeychainService:`. Derive from those two and isolation is inherited; hard-code
    /// either one and it is silently lost — for the keychain half, with no file-level symptom at
    /// all. Scanned rather than exercised because the failure is a source change, not a behaviour.
    @Test func theAppScopeIsDerivedFromTheAlreadyWalledSeams() throws {
        let source = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        guard let declaration = source.range(of: "var meshSessionStorage: MeshSessionStorageScope {") else {
            Issue.record("FernletStore.meshSessionStorage is gone — the sealed mesh-session context lost its app-side scope")
            return
        }
        let tail = source[declaration.upperBound...]
        let body = String(tail.prefix(600))

        #expect(
            body.contains("directory: proximitySupportRoot"),
            "meshSessionStorage no longer derives its directory from `proximitySupportRoot`, so a test store's sealed context is back on the production root."
        )
        #expect(
            body.contains("besideHeartDrop: heartDropKeychainService"),
            "meshSessionStorage no longer derives its keychain service from `heartDropKeychainService`, so every live store shares one seal key and any wipe unopens the others' files."
        )
    }

    /// The derivation itself: production in, production out; anything else in, something else out.
    ///
    /// The behavioural half of the scan above — a derivation that returned the production service
    /// for an isolated input would pass the source scan and isolate nothing.
    @Test func theDerivedKeychainServiceTracksItsHeartDropInput() {
        let production = MeshSessionStorageScope.keychainService(besideHeartDrop: HeartPrekeyStore.keychainService)
        #expect(production == MeshSessionStorageScope.productionKeychainService)
        #expect(MeshSessionStorageScope.production.keychainService == production)

        let isolated = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        let derived = MeshSessionStorageScope.keychainService(besideHeartDrop: isolated)
        #expect(derived != MeshSessionStorageScope.productionKeychainService,
                "an isolated heart-drop service derived the PRODUCTION mesh-session service — isolation lost")
        #expect(derived.hasPrefix(isolated), "the derived service must stay traceable to the scope it belongs to")

        let other = MeshSessionStorageScope.keychainService(
            besideHeartDrop: "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        )
        #expect(derived != other, "two isolated stores derived the SAME mesh-session service")
    }

    // MARK: - Scanner

    /// Every `.swift` file under the test root, as `(filename, source)`, minus this file.
    private static func testSources() throws -> [(String, String)] {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !excludedFiles.contains($0.lastPathComponent) }
        var sources: [(String, String)] = []
        // R2: bounded by the file list.
        for file in files.sorted(by: { $0.path < $1.path }) {
            sources.append((file.lastPathComponent, try String(contentsOf: file, encoding: .utf8)))
        }
        return sources
    }

    /// The argument text of every `name…)` construction in `source`, matched by depth so nested
    /// parentheses do not truncate an argument list.
    static func constructionArguments(of name: String, in source: String) -> [String] {
        var found: [String] = []
        var searchStart = source.startIndex
        // R2: each pass consumes at least one character of a finite string.
        while let head = source.range(of: name, range: searchStart..<source.endIndex) {
            searchStart = head.upperBound
            guard let close = matchingParenthesis(in: source, after: head.upperBound) else { continue }
            found.append(String(source[head.upperBound..<close]))
        }
        return found
    }

    /// Index of the `)` closing the parenthesis that opened just before `start`, or nil.
    private static func matchingParenthesis(in source: String, after start: String.Index) -> String.Index? {
        var depth = 1
        var index = start
        // R2: bounded by the remaining characters.
        while index < source.endIndex {
            let character = source[index]
            if character == "(" { depth += 1 }
            if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = source.index(after: index)
        }
        return nil
    }
}
