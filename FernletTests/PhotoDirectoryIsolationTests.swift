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

    /// The heart-drop sidecars are the same hazard again, with a keychain half the other two do not
    /// have. `deleteAllData` calls `heartDropService.wipeForDeleteAll()`, which deletes the outbox,
    /// peer-bundle and dedup files AND every row under the heart-drop keychain service — where the
    /// key those files are SEALED with lives — while `resetAll` removes the heart ledger's sidecar.
    ///
    /// So isolation takes BOTH arguments, and the directory alone is worse than neither: files on a
    /// private root sealed by a shared key survive another suite's wipe as ciphertext nothing can
    /// open, which the outbox quarantines and latches as sticky data loss. `makeTestStore` and
    /// friends pass the pair; this wall covers the direct constructions, where the omission compiles
    /// and the damage lands in somebody else's suite.
    @Test func everyHeartTouchingStoreConstructionPinsItsOwnHeartDropScope() throws {
        let testsRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let enumerator = FileManager.default.enumerator(at: testsRoot, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? [])
            .filter { $0.pathExtension == "swift" && !Self.excludedFiles.contains($0.lastPathComponent) }

        var scanned = 0
        for file in files.sorted(by: { $0.path < $1.path }) {
            let source = try String(contentsOf: file, encoding: .utf8)
            // Everything that can BUILD this store's heart state, directly or transitively. Both
            // stored properties are `lazy`, so a store reaching none of these never constructs a
            // sidecar and never joins the race — but "reaching" is not only naming them: the wipe
            // funnels get there (`deleteAllData` → `resetAll` → `heartLedger.clearAll()`), and so do
            // the two managers, whose builders read `heartLedger` (`PresenceManager(store:ledger:)`,
            // and `manager.heartLedger = heartLedger` in the mesh builder), as do the Home-surface
            // reads derived from it. Missing one of those is a silent false NEGATIVE, so the list is
            // deliberately over-broad — a spurious hit only demands an argument the file could pass
            // anyway.
            let reachesHeartState = [
                "heartDropService", "heartLedger", "deleteAllData", "resetAll(",
                "presenceManager", "meshNetworkManager", "heartGlow", "pendingHeartBubble",
                "queueHeart", "heartsAway",
            ].contains { source.contains($0) }
            guard reachesHeartState else { continue }
            for arguments in Self.storeConstructionArguments(in: source) {
                scanned += 1
                #expect(
                    arguments.contains("proximitySupportDirectory")
                        && arguments.contains("heartDropKeychainService"),
                    """
                    \(file.lastPathComponent) reaches this store's heart-drop state but constructs \
                    FernletStore without BOTH `proximitySupportDirectory:` and \
                    `heartDropKeychainService:`, so its outbox / dedup / peer-bundle sidecars, its \
                    heart ledger, or the key sealing them stay on the process-wide scope that every \
                    concurrent delete-all wipes. Pass `proximitySupportDirectory: \
                    uniqueProximityDirectory()` and `heartDropKeychainService: \
                    uniqueHeartDropKeychainService()`, or build the store through \
                    makeTestStore/makeTestStoreWithRepositories/makeStoreSharingStores.
                    """
                )
            }
        }

        // A real site floor, unlike the mesh scan above — the wipe suites construct stores directly
        // in bulk (14 sites today). Well under that count means the paren-matcher broke or the test
        // root moved, not that the codebase got tidier.
        #expect(scanned > 10, "the heart-state store-construction scan found only \(scanned) sites — scanner broken?")
    }

    /// The comment stripper is what stops all three walls above from being satisfied by prose, so it
    /// gets its own coverage rather than being trusted — including the two cases that would quietly
    /// break it: a `//` inside a string literal (a URL), and an escaped quote.
    @Test func theCommentStripperKeepsCodeAndDropsProse() {
        let strip = Self.strippingComments
        #expect(!strip("a, // photoDocumentsDirectory: x\n b").contains("photoDocumentsDirectory"))
        #expect(!strip("a, /* proximitySupportDirectory: y */ b").contains("proximitySupportDirectory"))
        #expect(strip("photoDocumentsDirectory: x // note").contains("photoDocumentsDirectory: x"))
        // A `//` inside a string must NOT start a comment, or the rest of a real argument list is eaten.
        #expect(strip("url: \"https://e.com\", heartDropKeychainService: s")
            .contains("heartDropKeychainService: s"))
        #expect(strip("a: \"\\\"//\", proximitySupportDirectory: d").contains("proximitySupportDirectory: d"))
        // An unterminated block comment must not run off the end and drop everything after it.
        #expect(strip("a, /* unterminated").contains("a,"))
    }

    /// `text` with `//` and `/* */` comments removed, string literals preserved.
    ///
    /// Applied to every extracted argument list before the walls look for an argument NAME in it.
    /// Without this the scan is satisfied by prose: a construction carrying the comment
    /// "see `photoDocumentsDirectory`" and not the argument passes all three walls, which is
    /// precisely backwards — these files comment their isolation arguments heavily, so the token is
    /// likelier to appear in a comment than anywhere else.
    static func strippingComments(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        var index = 0
        var inString = false
        while index < characters.count {
            let character = characters[index]
            if inString {
                output.append(character)
                if character == "\\", index + 1 < characters.count {
                    output.append(characters[index + 1])
                    index += 2
                    continue
                }
                if character == "\"" { inString = false }
                index += 1
            } else if character == "\"" {
                inString = true
                output.append(character)
                index += 1
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "/" {
                while index < characters.count, characters[index] != "\n" { index += 1 }
            } else if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                index += 2
                while index + 1 < characters.count,
                      !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
                index = min(index + 2, characters.count)
            } else {
                output.append(character)
                index += 1
            }
        }
        return output
    }

    /// The argument list of every `FernletStore(...)` construction in `source`, paren-matched so a
    /// nested call (`LocalFernletRepository(fileURL:)`) or a multi-line call is captured whole.
    /// String literals are skipped so a paren inside one can't unbalance the scan. Comments are
    /// stripped from the result — see ``strippingComments(_:)``.
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
                        results.append(strippingComments(String(characters[argumentStart..<cursor])))
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
