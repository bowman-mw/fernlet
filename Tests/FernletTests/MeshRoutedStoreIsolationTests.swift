// MeshRoutedStoreIsolationTests.swift
// FernletTests
//
// Grep-wall keeping every test `MeshRoutedStore` on its OWN scope — directory AND keychain service —
// in the idiom of `MeshSessionStoreIsolationTests` and `PhotoDirectoryIsolationTests`; plus the
// one-construction-site wall over `MeshCustodyDurabilityWitness`.
//
// The shared-disk-root flake family is a well-documented cross-suite hazard in this tree: XCTest and
// Swift Testing suites run in parallel inside ONE process, so anything rooted at a process-global
// path or a fixed keychain service is destroyed for every concurrently-running suite the moment one
// of them wipes. P5 item 3 adds a NEW persisted surface — `MeshRoutedIndex.sealed`, its `.corrupt`
// sibling, a whole directory of `MeshRoutedChunks/<uuid>.chunk` payload files, and the
// `com.fernlet.mesh-routed` key that seals all of them — and `MeshRoutedStore.wipeForDeleteAll`
// destroys every one of them by service and by path. The family must not gain a member.
//
// Source-scanning is the only way to catch the omission: `MeshRoutedStore(scope: .production)`
// compiles, passes in isolation every time, and lands its damage in somebody else's suite.
//
// The witness wall is a different kind of claim and lives here because it is the same tool. The
// compile-time gate on `MeshCustodyDurabilityWitness` is `fileprivate`, which is FILE scope — so it
// holds only while the type and its one minting verb share a file that holds nothing else. Moving
// the type would widen the gate silently, with no compile error and no failing behaviour test. This
// is the wall that notices.

import Foundation
import Testing
@testable import ProximityKit

/// Source-scan helpers shared by the routed walls. A free enum rather than a static on a suite,
/// because the suites that need it are not all main-actor isolated.
enum MeshRoutedSourceScan {

    /// `source` with every whole-line comment removed, so a grep-wall states something about CODE
    /// rather than about the prose that explains why the code does not do a thing.
    static func codeOnly(_ source: String) -> String {
        source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

struct MeshRoutedStoreIsolationTests {

    /// This file names the constructors in its own scanner literals, so exclude it from the sweep.
    private static let excludedFiles: Set<String> = ["MeshRoutedStoreIsolationTests.swift"]

    // MARK: - The store half

    /// Every `MeshRoutedStore(…)` in the test tree passes an explicit `scope:`.
    ///
    /// The initialiser has no default, so today this cannot even compile wrong — which is exactly why
    /// the wall is worth having: the cheapest "convenience" a future change could add is a defaulted
    /// `scope: .production`, and that change would be invisible to every other test.
    @Test func everyTestStoreConstructionNamesItsScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            for arguments in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedStore(", in: source
            ) {
                scanned += 1
                #expect(
                    arguments.contains("scope:"),
                    """
                    \(file) constructs MeshRoutedStore without `scope:`, so it shares the process-wide \
                    sealed index, the process-wide chunk directory and the process-wide \
                    `com.fernlet.mesh-routed` keychain row with every other live store — any concurrent \
                    test that runs "delete everything" destroys all three. Pass a per-test scope (see \
                    MeshRoutedStoreFixtures.scope()).
                    """
                )
            }
        }
        #expect(scanned >= 8, "the MeshRoutedStore construction scan found only \(scanned) sites — scanner broken?")
    }

    /// No test builds the PRODUCTION scope, by either spelling.
    ///
    /// The directory half alone is not enough and neither is the key half: files on a private root
    /// sealed by a shared key survive somebody else's wipe as ciphertext nothing can open, which is
    /// strictly worse than losing them outright.
    @Test func noTestReachesTheProductionScope() throws {
        var scanned = 0
        for (file, source) in try Self.testSources() {
            scanned += 1
            #expect(
                !source.contains("MeshRoutedStorageScope.production"),
                "\(file) uses the PRODUCTION routed scope — it shares the real index, the real chunk directory and the real keychain row with every concurrent suite."
            )
            for arguments in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedStorageScope(", in: source
            ) {
                #expect(
                    !arguments.contains("ProximitySupportLayout.defaultDirectory"),
                    "\(file) builds a routed scope on the production sidecar directory: \(arguments)"
                )
                #expect(
                    !arguments.contains("\"com.fernlet.mesh-routed\""),
                    "\(file) builds a routed scope on the production keychain service: \(arguments)"
                )
            }
        }
        #expect(scanned > 100, "the test-source sweep found only \(scanned) files — the test root moved?")
    }

    // MARK: - The app half

    /// `FernletStore.meshRoutedStorage` derives both halves from seams other walls already enforce.
    ///
    /// This is the load-bearing reason the store needs no fourth injectable seam on `FernletStore`:
    /// `PhotoDirectoryIsolationTests` already requires every test file that reaches `deleteAllData`
    /// and builds a store DIRECTLY to pass `proximitySupportDirectory:` **and**
    /// `heartDropKeychainService:`. Derive from those two and isolation is inherited; hard-code either
    /// one and it is silently lost — for the keychain half, with no file-level symptom at all.
    @Test func theAppScopeIsDerivedFromTheAlreadyWalledSeams() throws {
        let source = try RepoRoot.source("App/Fernlet/FernletStore.swift")
        guard let declaration = source.range(of: "var meshRoutedStorage: MeshRoutedStorageScope {") else {
            Issue.record("FernletStore.meshRoutedStorage is gone — the sealed routed store lost its app-side scope")
            return
        }
        let body = String(source[declaration.upperBound...].prefix(600))

        #expect(
            body.contains("directory: proximitySupportRoot"),
            "meshRoutedStorage no longer derives its directory from `proximitySupportRoot`, so a test store's routed custody is back on the production root."
        )
        #expect(
            body.contains("besideHeartDrop: heartDropKeychainService"),
            "meshRoutedStorage no longer derives its keychain service from `heartDropKeychainService`, so every live store shares one seal key and any wipe unopens the others' files."
        )
    }

    /// The derivation itself: production in, production out; anything else in, something else out.
    @Test func theDerivedKeychainServiceTracksItsHeartDropInput() {
        let production = MeshRoutedStorageScope.keychainService(besideHeartDrop: HeartPrekeyStore.keychainService)
        #expect(production == MeshRoutedStorageScope.productionKeychainService)

        let isolated = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        let derived = MeshRoutedStorageScope.keychainService(besideHeartDrop: isolated)
        #expect(derived != MeshRoutedStorageScope.productionKeychainService,
                "an isolated heart-drop service derived the PRODUCTION routed service — isolation lost")
        #expect(derived.hasPrefix(isolated), "the derived service must stay traceable to the scope it belongs to")

        let other = MeshRoutedStorageScope.keychainService(
            besideHeartDrop: "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        )
        #expect(derived != other, "two isolated stores derived the SAME routed service")
        // And the routed key does NOT lodge under the mesh-session service: one fate per service is
        // the only arrangement a service-wide delete can express honestly, so a session wipe must
        // not be able to orphan routed ciphertext. (Spelled as a literal rather than through the
        // session scope's own constant, which `MeshSessionStoreIsolationTests` bans by substring.)
        #expect(production != "com.fernlet.mesh-session")
        #expect(MeshRoutedSealKey.keychainAccount != MeshSessionSealKey.keychainAccount)
    }

    // MARK: - The durability gate

    /// `MeshCustodyDurabilityWitness` has exactly one construction site, and it is the file holding
    /// `committingCustody` and nothing else.
    ///
    /// The compile-time gate is `fileprivate`, so this wall is not redundant with it — it is what
    /// notices when someone MOVES the type, which widens the gate with no compile error. If the
    /// witness ever has to become `internal`, this wall is the replacement for the guarantee that is
    /// lost, and it must then be tightened rather than deleted.
    @Test func theDurabilityWitnessHasExactlyOneConstructionSite() throws {
        let root = RepoRoot.url("FernletKit/Sources/ProximityKit")
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        var scanned = 0
        var constructionSites: [String] = []
        for file in files.sorted(by: { $0.path < $1.path }) {
            scanned += 1
            let source = try String(contentsOf: file, encoding: .utf8)
            let code = MeshRoutedSourceScan.codeOnly(source)
            if code.contains("MeshCustodyDurabilityWitness(") {
                constructionSites.append(file.lastPathComponent)
            }
        }
        #expect(scanned >= 8, "the ProximityKit sweep found only \(scanned) files — scanner broken?")
        #expect(
            constructionSites == ["MeshRoutedCustodyCommit.swift"],
            """
            `MeshCustodyDurabilityWitness(` is constructed in \(constructionSites) — it must be built \
            in exactly one file, the one holding `committingCustody` and nothing else. A second site \
            means a receipt can be minted for bytes no durable write returned.
            """
        )
    }

    /// The file that holds the witness holds the commit verb and nothing else — the property that
    /// makes `fileprivate` a real gate rather than a comment.
    @Test func theCommitFileHoldsOnlyTheWitnessAndItsVerb() throws {
        let source = try RepoRoot.source(
            "FernletKit/Sources/ProximityKit/Mesh/MeshRoutedCustodyCommit.swift"
        )
        let code = MeshRoutedSourceScan.codeOnly(source)
        #expect(code.contains("struct MeshCustodyDurabilityWitness"))
        #expect(code.contains("fileprivate init("))
        #expect(code.contains("func committingCustody("))
        // The write token's own gate is in another file, so this one cannot mint one either.
        #expect(code.contains("LoadToken(fileURL:") == false,
                "the commit file must not be able to mint a write token")
        let store = try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedStore.swift")
        #expect(MeshRoutedSourceScan.codeOnly(store).contains("fileprivate init(fileURL:"))
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
}
