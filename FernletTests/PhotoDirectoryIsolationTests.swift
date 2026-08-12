import Foundation
import Testing
@testable import Fernlet

/// Grep-wall keeping every test `FernletStore` on its OWN own-photo root.
///
/// The own-photo corpora (meal, recipe, progress) are shared *on-disk* state: `resetAll`,
/// `deleteAllData` and the duress wipe all call `deleteAll()` on all three. XCTest and Swift Testing
/// suites run in parallel inside a single test process, so a store built on the process-wide
/// container root has its photos deleted out from under it the moment ANY concurrently-running test
/// wipes. That is not theoretical: `RecipeReimportTests.failedReimportLeavesTheRecipeUntouched`
/// failed three full-suite runs in a row (`store.recipePhotoData(for:)` came back nil) while passing
/// in isolation every time.
///
/// `FernletStore.photoDocumentsDirectory` is the per-instance seam that fixes it, and the test
/// helpers default it to `uniquePhotoDirectory()`. This wall covers the other half — a test that
/// constructs `FernletStore` DIRECTLY and forgets the argument silently rejoins the race, and the
/// symptom lands in somebody else's suite. Source-scanning is the only way to catch that: the
/// omission compiles, and the resulting flake is by definition not reproducible in isolation.
struct PhotoDirectoryIsolationTests {
    /// This file names the constructor in its own scanner literals, so exclude it from the sweep.
    private static let excludedFiles: Set<String> = ["PhotoDirectoryIsolationTests.swift"]

    @Test func everyDirectStoreConstructionInTestsPinsItsOwnPhotoDirectory() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        // Recursive: subdirectories (Mocks/, and anything added later) are covered too.
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("photoDocumentsDirectory"),
                    """
                    \(file.lastPathComponent) constructs FernletStore without `photoDocumentsDirectory:`, \
                    so it shares the process-wide own-photo root with every other live store — any \
                    concurrent test that wipes will delete its photos. Pass \
                    `photoDocumentsDirectory: uniquePhotoDirectory()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }

        // Never pass vacuously: a moved test root or a broken scanner must fail loudly, not quietly
        // stop covering anything.
        #expect(scanned > 20, "the FernletStore construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The friend photo wall is the same hazard one media key over: `MeshNetworkManager` loads
    /// `MeshPhotoCache.json` at init and re-saves the WHOLE index on `deletePhoto` /
    /// `deleteAllSessionPhotos`, so on a process-wide root one manager silently inherits — and then
    /// overwrites — another suite's album.
    ///
    /// The root now rides `ProximityHost.proximitySupportDirectory`, so a manager built from a
    /// helper-made store is isolated for free. What still needs walling is the other half: a file
    /// that reaches a mesh manager while building its store DIRECTLY gets the production root back,
    /// and the damage lands in whichever suite happens to be running beside it.
    @Test func everyMeshTouchingStoreConstructionPinsItsOwnProximityDirectory() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Only files that actually build or reach a mesh manager can trip the race; a store that
            // never touches `meshNetworkManager` never builds the wall (the property is `lazy`).
            guard source.contains("meshNetworkManager") || source.contains("MeshNetworkManager(") else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("proximitySupportDirectory"),
                    """
                    \(file.lastPathComponent) reaches a MeshNetworkManager but constructs FernletStore \
                    without `proximitySupportDirectory:`, so its friend photo wall lives on the \
                    process-wide root and races every concurrently-live manager. Pass \
                    `proximitySupportDirectory: uniqueProximityDirectory()`, or build the store \
                    through makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }

        // Unlike the sweep above this one legitimately covers few sites (mesh tests use the helpers),
        // so assert only that the scanner still resolves the tree — not a site count.
        #expect(files.count > 20, "the mesh-touching scan saw only \(files.count) test files — scanner broken?")
    }

    /// The argument list of every `FernletStore(...)` construction in `source`, paren-matched so a
    /// nested call (`LocalFernletRepository(fileURL:)`) or a multi-line call is captured whole.
    /// String literals are skipped so a paren inside one can't unbalance the scan.
    private static func storeConstructionArguments(in source: String) -> [String] {
        let characters = Array(source)
        let needle = Array("FernletStore(")
        var results: [String] = []
        var index = 0
        while index + needle.count <= characters.count {
            guard Array(characters[index..<(index + needle.count)]) == needle else {
                index += 1
                continue
            }
            // `.FernletStore(` / `MockFernletStore(` are different symbols — require a boundary.
            if index > 0, characters[index - 1].isLetter || characters[index - 1].isNumber
                || characters[index - 1] == "_" || characters[index - 1] == "." {
                index += 1
                continue
            }
            var depth = 0
            var inString = false
            var cursor = index + needle.count - 1
            var argumentStart = cursor + 1
            while cursor < characters.count {
                let character = characters[cursor]
                if inString {
                    if character == "\\" { cursor += 2; continue }
                    if character == "\"" { inString = false }
                } else if character == "\"" {
                    inString = true
                } else if character == "(" {
                    depth += 1
                    if depth == 1 { argumentStart = cursor + 1 }
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        results.append(String(characters[argumentStart..<cursor]))
                        break
                    }
                }
                cursor += 1
            }
            index = cursor + 1
        }
        return results
    }
}
