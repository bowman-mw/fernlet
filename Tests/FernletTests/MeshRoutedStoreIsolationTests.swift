// MeshRoutedStoreIsolationTests.swift
// FernletTests
//
// Grep-wall keeping every test `MeshRoutedStore` on its OWN scope — directory AND keychain service —
// in the idiom of `MeshSessionStoreIsolationTests` and `PhotoDirectoryIsolationTests`; plus the
// one-construction-site wall over `MeshCustodyDurabilityWitness`. "Test" means both test targets' trees:
// the app's unit tests and, since ProximityKit plan step A1.1.6, ProximityKit's package tests.
//
// The shared-disk-root flake family is a well-documented cross-suite hazard in this tree: XCTest and
// Swift Testing suites run in parallel inside ONE process, so anything rooted at a process-global
// path or a fixed keychain service is destroyed for every concurrently-running suite the moment one
// of them wipes. P5 item 3 adds a NEW persisted surface — `MeshRoutedIndex.sealed`, its `.corrupt`
// sibling, a whole directory of `MeshRoutedChunks/<uuid>.chunk` payload files, and the
// `com.fernlet.mesh-routed` key that seals all of them — and `MeshRoutedStore.wipeForDeleteAll`
// destroys every one of them by service and by path. The family must not gain a member.
//
// Source-scanning is the only way to catch the omission:
// `MeshRoutedStore(scope: .production(for: namespace, directory: root, installBinding: binding))`
// compiles, passes in isolation every time, and lands its damage in somebody else's suite.
//
// The witness wall is a different kind of claim and lives here because it is the same tool. The
// compile-time gate on `MeshCustodyDurabilityWitness` is `fileprivate`, which is FILE scope — so it
// holds only while the type and its one minting verb share a file that holds nothing else. Moving
// the type would widen the gate silently, with no compile error and no failing behaviour test. This
// is the wall that notices.

import FernletConnections
import FernletSocial
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

    /// The brace-matched body of the declaration whose signature starts with `signature`, braces
    /// included — or nil when the signature is absent or its braces do not close.
    ///
    /// Added by P6 item 10's SET A for the two walls the item 7 fix review found measuring TEXT
    /// PROXIMITY rather than CONTAINMENT (its P2-A and P3-c): "the door's refusals" and "the
    /// statement inside that closure" are claims about a *body*, and `components(separatedBy:)`
    /// answers them with whatever happens to lie between two literals — which stays green when the
    /// thing moves out of the body into the next one. Pass `codeOnly(_:)` output: a whole-line
    /// comment mentioning a brace would otherwise be counted.
    ///
    /// - Parameters:
    ///   - signature: A declaration prefix unique in `source` (e.g. `"private func foo("`).
    ///   - source: Comment-stripped Swift.
    /// - Returns: `{ … }` for the first match, nil when there is none.
    static func bracedBody(after signature: String, in source: String) -> String? {
        guard let head = source.range(of: signature) else { return nil }
        guard let open = openingBrace(in: source, from: head.lowerBound) else { return nil }
        var depth = 0
        var index = open
        // R2: bounded by the remaining characters of a finite string.
        while index < source.endIndex {
            let character = source[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(source[open...index]) }
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// Index of the `{` that opens the declaration's body — the first one not inside the signature's
    /// own parentheses, so a defaulted closure argument does not steal it.
    private static func openingBrace(in source: String, from start: String.Index) -> String.Index? {
        var parens = 0
        var index = start
        // R2: bounded by the remaining characters.
        while index < source.endIndex {
            let character = source[index]
            if character == "(" { parens += 1 }
            if character == ")" { parens -= 1 }
            if character == "{" && parens == 0 { return index }
            index = source.index(after: index)
        }
        return nil
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
    /// strictly worse than losing them outright. Since ProximityKit plan step A0.2.8, when the
    /// production scope began reading the namespace, a hand-built scope naming a namespace's
    /// production directory or `installation.keychain.meshRoutedSealKey.service` is banned beside the
    /// two older spellings; since step A0.6.6, when ProximityKit stopped computing a directory, that
    /// directory is spelled `FernletProximityStorage.productionDirectory` or through
    /// `applicationSupportDirectory`, and both are banned. Since step A0.2.12 so are the two the
    /// substring needle never saw: the shorthand `.production(for:directory:installBinding:)` wherever
    /// a scope is expected (`MeshRoutedStore(scope: .production(…))`), and the type-prefixed one broken
    /// before its `.`, read by the session twin's two scanners
    /// (`MeshSessionStoreIsolationTests.shorthandProductionScopes(in:)` and
    /// `typePrefixedProductionScopes(of:in:)`, fixtured there).
    ///
    /// **The scratch-root needle** (plan step A0.6.6). A host double that spells no scope at all
    /// takes `ProximityHost`'s default scopes, which are the namespace's production rows on whatever
    /// root the host states: a double on a scratch root of its own would seal its files under the
    /// production keys, which any wipe in the process deletes, and spell neither a scope construction
    /// nor a `.production`, so no needle above sees it. So every file-scope test class conforming to
    /// `ProximityHost` or `FernletSocialHost` that declares `proximitySupportDirectory` at the top level
    /// of its body declares both `meshSessionStorage` and `meshRoutedStorage` there too, but
    /// ``scratchRootExemption``, which never opens a store and must still exist; at least
    /// ``minimumHostDoubles`` doubles must be read, so a broken reader cannot pass on an empty read.
    /// The reader and the rule are fixtured both ways in ``expectTheScratchRootReaderFixtured()``. Since
    /// ProximityKit plan step A1.1.6 the sweep reads ProximityKit's package tests too
    /// (`MeshSessionStoreIsolationTests.testRoots`, each root at its file floor), so their host double,
    /// `PackageTestHost`, and any store or scope a package suite builds are held here like Fernlet's.
    @Test func noTestReachesTheProductionScope() throws {
        var scanned = 0
        var doubles: [HostDouble] = []
        for (file, source) in try Self.testSources() {
            scanned += 1
            #expect(
                !source.contains("MeshRoutedStorageScope.production"),
                "\(file) uses the PRODUCTION routed scope — it shares the real index, the real chunk directory and the real keychain row with every concurrent suite."
            )
            let code = SwiftSourceLexer.lex(source).code
            doubles += try Self.hostDoubles(in: code)
            let reads = MeshSessionStoreIsolationTests.typePrefixedProductionScopes(
                of: "MeshRoutedStorageScope", in: code
            ) + MeshSessionStoreIsolationTests.shorthandProductionScopes(in: code)
            #expect(
                reads.isEmpty,
                """
                \(file) reaches a PRODUCTION storage scope through \(reads) — it shares the real index, \
                the real chunk directory and the real keychain row with every concurrent suite. A \
                shorthand `.production(for:directory:installBinding:)` does not say which scope it builds (only \
                the routed and mesh-session scopes declare it), so this wall and its session twin both \
                refuse it.
                """
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
                #expect(
                    !arguments.contains("FernletProximityStorage.productionDirectory"),
                    "\(file) builds a routed scope on Fernlet's production directory: \(arguments)"
                )
                #expect(
                    !arguments.contains("applicationSupportDirectory"),
                    "\(file) builds a routed scope under the process's Application Support: \(arguments)"
                )
                #expect(
                    !arguments.contains("installation.keychain.meshRoutedSealKey.service"),
                    "\(file) builds a routed scope on a namespace's production keychain service: \(arguments)"
                )
            }
        }
        #expect(scanned > 100, "the test-source sweep found only \(scanned) files — the test root moved?")
        Self.expectEveryDoubleOnItsOwnRootStatesBothScopes(doubles)
        try Self.expectTheScratchRootReaderFixtured()
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
    ///
    /// Since ProximityKit plan step A0.2.8 the derivation and the production scope read the host's
    /// namespace, so this pins them under `.fernlet`: its seal-key service, and the namespace itself
    /// carried on the scope — since step A0.2.9 the install binding it is handed, and since step
    /// A0.6.6, when the production scope began taking its root from its host, Fernlet's production
    /// root, `FernletProximityStorage.productionDirectory`, handed to it and carried.
    @Test func theDerivedKeychainServiceTracksItsHeartDropInput() {
        let namespace = ProximityNamespace.fernlet
        let keychain = namespace.installation.keychain
        let production = MeshRoutedStorageScope.keychainService(
            besideHeartDrop: HeartPrekeyStore.keychainService, in: namespace
        )
        #expect(production == keychain.meshRoutedSealKey.service)
        let productionScope = MeshRoutedStorageScope.production(
            for: namespace, directory: FernletProximityStorage.productionDirectory,
            installBinding: FernletDeviceBindingAdapter()
        )
        #expect(productionScope.keychainService == production)
        #expect(productionScope.directory == FernletProximityStorage.productionDirectory)
        #expect(productionScope.namespace == namespace)
        #expect(productionScope.installBinding is FernletDeviceBindingAdapter)

        let isolated = "com.fernlet.heartdrop.test.\(UUID().uuidString)"
        let derived = MeshRoutedStorageScope.keychainService(besideHeartDrop: isolated, in: namespace)
        #expect(derived != keychain.meshRoutedSealKey.service,
                "an isolated heart-drop service derived the PRODUCTION routed service — isolation lost")
        #expect(derived.hasPrefix(isolated), "the derived service must stay traceable to the scope it belongs to")

        let other = MeshRoutedStorageScope.keychainService(
            besideHeartDrop: "com.fernlet.heartdrop.test.\(UUID().uuidString)", in: namespace
        )
        #expect(derived != other, "two isolated stores derived the SAME routed service")
        // And the routed key does NOT lodge under the mesh-session service: one fate per service is
        // the only arrangement a service-wide delete can express honestly, so a session wipe must
        // not be able to orphan routed ciphertext. (Read off the namespace rather than through the
        // session scope's own production scope, which `MeshSessionStoreIsolationTests` bans by
        // substring.)
        #expect(production != keychain.meshSessionSealKey.service)
        #expect(keychain.meshRoutedSealKey.account != keychain.meshSessionSealKey.account)
    }

    // MARK: - The scratch-root needle (plan step A0.6.6)

    /// One `ProximityHost` or `FernletSocialHost` class the test tree declares at file scope: its name,
    /// and what the top level of its body declares.
    struct HostDouble: Equatable, Sendable {
        /// The class's name.
        let name: String
        /// Whether its body declares `proximitySupportDirectory` (a `var` or a `let`) at its top level.
        let statesRoot: Bool
        /// Whether its body declares both `meshSessionStorage` and `meshRoutedStorage` at its top level.
        let statesBothScopes: Bool
    }

    /// The one double that may state a root and no scope: `ProximityNamespaceGoldenTests`'
    /// `RootedNamespaceDefaultsHost`, whose cells only read its default scopes and never open a store.
    static let scratchRootExemption = "RootedNamespaceDefaultsHost"

    /// Fewer host doubles than this and the reader is broken, or a test root went dark, not the tree
    /// clean: the app's test target declares seventeen at plan step A0.6.6, and since ProximityKit plan
    /// step A1.1.6 (2026-10-14), when this needle began reading the package's tests too, their
    /// `PackageTestHost` is the eighteenth, MEASURED then at eighteen.
    static let minimumHostDoubles = 18

    /// The scratch-root needle over every double the sweep read: enough were read, the exempt one is
    /// among them, and every other one that states its root states both scopes.
    static func expectEveryDoubleOnItsOwnRootStatesBothScopes(_ doubles: [HostDouble]) {
        #expect(doubles.count >= minimumHostDoubles, "read only \(doubles.count) host doubles — scanner broken?")
        let exemptFound = doubles.contains(where: { $0.name == scratchRootExemption })
        #expect(exemptFound, "\(scratchRootExemption), the one exempt double, is gone: delete its exemption with it")
        let unscoped = unscopedRootedDoubles(doubles)
        #expect(unscoped.isEmpty, """
            \(unscoped) state a sidecar root of their own but not both storage scopes, so the manager a \
            test builds over one seals its files on that root under the namespace's PRODUCTION seal keys \
            (`ProximityHost`'s default scopes since ProximityKit plan step A0.6.6), which any \
            concurrently-running wipe deletes. State `meshSessionStorage` and `meshRoutedStorage` on that \
            root with `.test.` services of the double's own, as ScratchNamespaceHost does.
            """)
    }

    /// The doubles that state a root of their own without both scopes, but the exempt one.
    static func unscopedRootedDoubles(_ doubles: [HostDouble]) -> [String] {
        doubles.filter { $0.statesRoot && !$0.statesBothScopes && $0.name != scratchRootExemption }.map(\.name)
    }

    /// Every class declared at file scope in `code` (lexed: comments dropped, literals emptied) whose
    /// inheritance clause names `ProximityHost` or `FernletSocialHost`, with what the top level of its
    /// body declares. A class nested in another declaration is not read, and neither is a declaration
    /// inside a member: a local in `init` states nothing about the double.
    static func hostDoubles(in code: String) throws -> [HostDouble] {
        let opener = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])class\s+([A-Za-z_]\w*)\s*:([^{]*)\{"#)
        let conformance = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])(?:ProximityHost|FernletSocialHost)(?![A-Za-z0-9_])"#)
        var doubles: [HostDouble] = []
        // R2: bounded by the class declarations in one file.
        for match in opener.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let whole = Range(match.range, in: code), let name = Range(match.range(at: 1), in: code),
                  let inherited = Range(match.range(at: 2), in: code) else { continue }
            let clause = String(code[inherited])
            let conforms = conformance.firstMatch(in: clause, range: NSRange(clause.startIndex..., in: clause)) != nil
            guard conforms, braceDepth(before: whole.lowerBound, in: code) == 0 else { continue }
            let body = topLevelBody(openingAt: code.index(before: whole.upperBound), in: code)
            let root = try declares("proximitySupportDirectory", in: body)
            let session = try declares("meshSessionStorage", in: body)
            let routed = try declares("meshRoutedStorage", in: body)
            doubles.append(HostDouble(name: String(code[name]), statesRoot: root, statesBothScopes: session && routed))
        }
        return doubles
    }

    /// How many braces are open at `index` in `code`: 0 at file scope.
    static func braceDepth(before index: String.Index, in code: String) -> Int {
        code[..<index].reduce(0) { depth, character in
            character == "{" ? depth + 1 : (character == "}" ? depth - 1 : depth)
        }
    }

    /// The text directly inside the brace pair that opens at `open` in `code`, every nested pair's
    /// contents left out; whatever was read when the pair never closes.
    static func topLevelBody(openingAt open: String.Index, in code: String) -> String {
        var depth = 0
        var text = ""
        var index = open
        // R2: bounded by the remaining characters of a finite string.
        while index < code.endIndex {
            let character = code[index]
            if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return text }
            } else if depth == 1 {
                text.append(character)
            }
            index = code.index(after: index)
        }
        return text
    }

    /// Whether `body` declares `name` with `var` or `let`, as a whole identifier.
    static func declares(_ name: String, in body: String) throws -> Bool {
        let declaration = try NSRegularExpression(
            pattern: #"(?<![A-Za-z0-9_])(?:var|let)\s+"# + name + #"(?![A-Za-z0-9_])"#)
        return declaration.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
    }

    /// The scratch-root needle's reader and rule, fixtured both ways: a double stating a root and both
    /// scopes passes, and one stating a root alone is refused, its scopes declared only as locals in a
    /// member; a double stating no root is read and not refused; a class that is no host, a class
    /// nested in another declaration, and one in a comment or a string literal are not read; and the
    /// exempt double is never refused.
    static func expectTheScratchRootReaderFixtured() throws {
        let read = try hostDoubles(in: SwiftSourceLexer.lex("""
            private final class Scoped: FernletSocialHost {
                let proximitySupportDirectory: URL
                let meshSessionStorage: MeshSessionStorageScope
                var meshRoutedStorage: MeshRoutedStorageScope { routed }
            }
            final class Bare: ProximityHost {
                let proximitySupportDirectory = uniqueProximityDirectory()
                init() { let meshSessionStorage = 1; let meshRoutedStorage = 2 }
            }
            final class Unrooted: ProximityHost {
                var proximityDisplayName: String { "Golden" }
            }
            final class NotAHost: NSObject { let proximitySupportDirectory = root }
            struct Outer {
                final class Nested: ProximityHost { let proximitySupportDirectory = root }
            }
            // final class Commented: ProximityHost { let proximitySupportDirectory = root }
            let quoted = "final class Quoted: ProximityHost { let proximitySupportDirectory = root }"
            """).code)
        #expect(read == [
            HostDouble(name: "Scoped", statesRoot: true, statesBothScopes: true),
            HostDouble(name: "Bare", statesRoot: true, statesBothScopes: false),
            HostDouble(name: "Unrooted", statesRoot: false, statesBothScopes: false)
        ], "read the host doubles as \(read)")
        #expect(unscopedRootedDoubles(read) == ["Bare"], "the rule refused \(unscopedRootedDoubles(read))")
        let exempt = [HostDouble(name: scratchRootExemption, statesRoot: true, statesBothScopes: false)]
        #expect(unscopedRootedDoubles(exempt).isEmpty, "the exempt double was refused")
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

    // MARK: - The delivery gate (P5 item 4)

    /// `MeshRecipientDeliveryWitness` has exactly one construction site, and it is the file holding
    /// `committingDelivery` and nothing else.
    ///
    /// Same claim, same reason as the custody witness above: the compile-time gate is `fileprivate`,
    /// so this wall is what notices when someone MOVES the type, which widens the gate with no
    /// compile error.
    @Test func theRecipientWitnessCanOnlyBeMintedInItsOwnFile() throws {
        var constructionSites: [String] = []
        for (file, code) in try Self.proximitySources() where code.contains("MeshRecipientDeliveryWitness(") {
            constructionSites.append(file)
        }
        #expect(
            constructionSites == ["MeshRoutedDeliveryCommit.swift"],
            """
            `MeshRecipientDeliveryWitness(` is constructed in \(constructionSites) — it must be built \
            in exactly one file, the one holding `committingDelivery` and nothing else. A second site \
            means a recipient receipt can be minted for an acknowledgement no durable write returned.
            """
        )
    }

    /// The file that holds the delivery witness holds the commit verb and nothing else — the property
    /// that makes `fileprivate` a real gate rather than a comment.
    @Test func theDeliveryCommitFileHoldsTheWitnessAndTheVerbAndNothingElse() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedDeliveryCommit.swift")
        )
        #expect(code.contains("struct MeshRecipientDeliveryWitness"))
        #expect(code.contains("fileprivate init("))
        #expect(code.contains("func committingDelivery("))
        // The write token's own gate is in another file, so this one cannot mint one either.
        #expect(code.contains("LoadToken(fileURL:") == false,
                "the delivery commit file must not be able to mint a write token")
        // And it holds no OTHER store verb: the ingest door lives next door on purpose.
        #expect(code.contains("func recordingRecipientReceipt(") == false)
        #expect(code.contains("func committingCustody(") == false)
    }

    /// The commit verb writes no delivery rung — the source half of the invariant its behavioural
    /// twin asserts.
    ///
    /// Cheap, and it is what stops the split being quietly re-merged by a later edit: the
    /// `delivered` rung has exactly ONE writer, and it takes a signed receipt whose signer is that
    /// destination.
    @Test func theCommitVerbWritesNoDeliveryRung() throws {
        let code = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedDeliveryCommit.swift")
        )
        #expect(code.contains("advancing(") == false,
                "the delivery commit file advances a rung — only the receipt door may")
        #expect(code.contains("MeshRoutedDeliveryRecord(encoding:") == false,
                "the delivery commit file re-encodes a delivery map — only the receipt door may")
        let ingest = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/MeshRoutedDeliveryIngest.swift")
        )
        #expect(ingest.contains("advancing(receipt.recipientFingerprint, to: .delivered)"),
                "the receipt door is where a rung moves, on the SIGNER's own destination")
    }

    /// `MeshHeartLedgerProof` can only be built inside the ledger's own file — the heart half of
    /// durable-before-acknowledged, gated the same way. The ledger is FernletSocial's
    /// (`HeartSharing/ProximityHeartLedger.swift`), and the sweep reads both modules, so a
    /// construction in either is seen.
    @Test func theHeartLedgerProofCanOnlyBeMintedInTheLedgersOwnFile() throws {
        var constructionSites: [String] = []
        for (file, code) in try Self.proximitySources() where code.contains("MeshHeartLedgerProof(") {
            constructionSites.append(file)
        }
        #expect(
            constructionSites == ["ProximityHeartLedger.swift"],
            """
            `MeshHeartLedgerProof(` is constructed in \(constructionSites) — only the ledger may vend \
            one. A second site means a heart receipt can be minted for a gift the ledger never stored.
            """
        )
        let ledger = MeshRoutedSourceScan.codeOnly(
            try RepoRoot.source("FernletKit/Sources/FernletSocial/HeartSharing/ProximityHeartLedger.swift")
        )
        #expect(ledger.contains("public nonisolated struct MeshHeartLedgerProof"))
        #expect(ledger.contains("fileprivate init(giftID:"))
    }

    /// Shipping code names exactly ONE ack-stage table.
    ///
    /// Injection alone does not deliver "a recipient cannot claim a weaker rule" — the table is a
    /// door parameter, so a second shipping value would be a second policy. A fixture table is a
    /// test-only affordance, and this is what keeps it one.
    ///
    /// The construction half uses the same paren-matching scanner the store walls above use, not a
    /// `contains("MeshRoutedAckStageTable(rows:")`: the literal form is blind to a construction
    /// wrapped between the paren and the `rows:` label, and this wall is the ONLY thing standing
    /// between a caller and a table mapping `…routed-type.heart.v1` to `.durableRecipientStorage` —
    /// a heart reported delivered on ciphertext alone, with no foreground decrypt and no ledger
    /// commit. Unlike the witness and the ledger proof, the table has no `fileprivate` gate.
    ///
    /// **P5 item 11 moved the construction site, and the wall moved with it in the same commit.**
    /// The table is now a PROJECTION of `MeshRoutedTypeRegistry`'s rows, so the one place a table is
    /// built is the registry's own file — and the sentence above stays true word for word, with the
    /// registry standing where the ack file used to. **The member half has no exemption**: no
    /// shipping file — ProximityKit's or FernletSocial's, the registry's included — names any
    /// `MeshRoutedAckStageTable.` member at all (the `increment1` table is the test target's binding,
    /// over Fernlet's rows, for the suites); the one table a door is handed is the registry's
    /// `ackStages` (which is why the registry
    /// declares its own `maxEntries` rather than reading `maxRows` across — the equality is pinned
    /// from the test target by `theRegistrysCapEqualsTheAckTablesCap`).
    @Test func shippingCodeNamesOneAckStageTable() throws {
        var constructionSites: [String] = []
        var otherValues: [String] = []
        for (file, code) in try Self.proximitySources() {
            for _ in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedAckStageTable(", in: code
            ) {
                constructionSites.append(file)
            }
            for fragment in code.components(separatedBy: "MeshRoutedAckStageTable.").dropFirst() {
                otherValues.append("\(file): …MeshRoutedAckStageTable.\(fragment.prefix(24))")
            }
        }
        #expect(constructionSites == ["MeshRoutedTypeRegistry.swift"],
                "a second shipping `MeshRoutedAckStageTable(rows:)` is a second policy: \(constructionSites)")
        #expect(otherValues.isEmpty,
                "shipping code names an ack-stage table member, a second value beside the registry's: \(otherValues)")
    }

    /// Shipping code names exactly ONE routed type registry (P5 item 11).
    ///
    /// The ack-stage wall's exact shape, one level up. The registry is the single source of the
    /// verifier's accepted-token set, the ack-stage projection, the mint's per-type guards and the
    /// four forwarding gates — so a second shipping registry would be a second answer to "is this
    /// type known", and that is the one question plan §11 says must have one answer everywhere.
    ///
    /// The construction half is why `MeshNetworkManager`'s `init` spells the registry it builds out in
    /// full (`MeshRoutedTypeRegistry(entries: store.meshRoutedTypeEntries)`, its host's rows alone): a
    /// leading-dot `.init(entries:)` is invisible to this scanner. The member half admits no member at
    /// all: the registry has no builder, only that one construction from the host's rows. The sweep
    /// reads FernletSocial too, where Fernlet's rows are declared, so the host's rows cannot become a
    /// second registry there either. The mint takes its registry with no default, so the registry the
    /// manager builds is the one value position left.
    /// `theTypeRegistryScannersMatchAcrossLines` fixtures that blind spot from both sides, asserting
    /// the manager's file still names the type in full.
    @Test func shippingCodeNamesOneTypeRegistry() throws {
        var constructionSites: [String] = []
        var otherValues: [String] = []
        for (file, code) in try Self.proximitySources() {
            for _ in MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedTypeRegistry(", in: code
            ) {
                constructionSites.append(file)
            }
            for fragment in code.components(separatedBy: "MeshRoutedTypeRegistry.").dropFirst() {
                otherValues.append("\(file): …MeshRoutedTypeRegistry.\(fragment.prefix(24))")
            }
        }
        #expect(constructionSites == ["MeshNetworkManager.swift"],
                "a second shipping `MeshRoutedTypeRegistry(entries:)` is a second policy: \(constructionSites)")
        #expect(otherValues.isEmpty,
                "shipping code names a type registry other than the manager's one construction: \(otherValues)")
    }

    /// No shipping code branches on a routed type token — the registry IS the only per-type switch.
    ///
    /// The allowlist is **per substring**, not per file, because the spelling needles have different
    /// single-source rules. The tokens are the host's: a routed type may be read off the namespace's
    /// routed types (`routedTypes.photo` and its three siblings) only where rows are built from them —
    /// FernletSocial's host rows, every row the mesh registers — and in the namespace's own soundness
    /// rules, which name each field's path. No
    /// ProximityKit or FernletSocial file may spell one: the raw `fernlet.mesh.routed-type.` literal
    /// lives in FernletConnections, which spells Fernlet's, and the old `MeshRoutedTypeToken.`
    /// constants are gone (the test target's binding keeps that spelling for the suites), so typing a
    /// spelling straight into a row would give one token two sources that drift silently.
    ///
    /// Legal by construction, and it must stay legal: passing `manifest.typeToken` as a **lookup
    /// argument**, logging it as a context value, and branching on a **resolved** value
    /// (`entry.requiresForegroundDecryptBeforeFinal`, `switch stage`, a retention comparison) are the
    /// point of the registry, not violations of it.
    ///
    /// `MeshRoutedSourceScan.codeOnly` strips whole-line comments only, so string literals survive
    /// (which is what makes the literal needle work at all) and so do trailing comments on code
    /// lines — a `let x = y  // see fernlet.mesh.routed-type.photo.v1` would be a false positive
    /// here. Noted rather than designed around: it fails loudly and the fix is to move the comment.
    @Test func noShippingCodeBranchesOnARoutedTypeToken() throws {
        var violations: [String] = []
        for (file, code) in try Self.proximitySources() {
            for (needle, files) in Self.routedTokenNeedles
            where code.contains(needle) && !files.contains(file) {
                violations.append("\(file): \(needle)")
            }
        }
        #expect(violations.isEmpty,
                "a per-type branch or a second token spelling outside the registry: \(violations)")
    }

    /// Wall 3's needles and their per-substring allowlists — **the wall's data, hoisted so the wall
    /// and its fixture read the same dictionary.**
    ///
    /// Held here rather than inside `noShippingCodeBranchesOnARoutedTypeToken` because a fixture that
    /// re-typed the needles as literals could not fail: deleting `"typeToken =="` from a local
    /// dictionary would blind the wall while every `"…".contains("typeToken ==")` assertion stayed
    /// green. `theTypeRegistryScannersMatchAcrossLines` drives THIS value, so removing or widening a
    /// row is a test failure rather than a silent narrowing of what the wall catches.
    private static let routedTokenNeedles: [String: Set<String>] = [
        "MeshRoutedTypeToken.": [],
        "fernlet.mesh.routed-type.": [],
        "routedTypes.photo": routedTypeFieldHomes,
        "routedTypes.tempMessage": routedTypeFieldHomes,
        "routedTypes.heart": routedTypeFieldHomes,
        "routedTypes.control": routedTypeFieldHomes,
        "typeToken ==": [],
        "== manifest.typeToken": [],
        "switch manifest.typeToken": [],
        "typeToken.hasPrefix(": []
    ]

    /// The two files that may read a single routed type off the namespace's routed types: the
    /// namespace's soundness rules, whose field paths spell each one, and FernletSocial's host rows,
    /// which build every row Fernlet declares through its host (`ProximityHost.meshRoutedTypeEntries`).
    /// The registry builds no row of its own, so it is no home.
    private static let routedTypeFieldHomes: Set<String> = [
        "ProximityNamespace+Soundness.swift", "FernletRoutedTypes.swift"
    ]

    /// The four bare per-type branch forms, each written so that EXACTLY ONE needle catches it.
    ///
    /// The uniqueness is the point. `if manifest.typeToken == MeshRoutedTypeToken.heart {` is caught
    /// by `"MeshRoutedTypeToken."` as well, so a fixture built on it would stay green with all four
    /// branch needles deleted. Each form here names a local instead, so the only thing that can catch
    /// it is its own needle.
    private static let routedTokenBranchForms: [String: String] = [
        "typeToken ==": "if manifest.typeToken == token {",
        "== manifest.typeToken": "if token == manifest.typeToken {",
        "switch manifest.typeToken": "switch manifest.typeToken {",
        "typeToken.hasPrefix(": "if manifest.typeToken.hasPrefix(prefix) {"
    ]

    /// The registry scanners themselves, fixtured — the matcher is the wall.
    ///
    /// Every fixture here drives a **shared** value, never a literal re-typed beside its own
    /// assertion: the construction cases run `MeshSessionStoreIsolationTests.constructionArguments`,
    /// and the needle cases run `Self.routedTokenNeedles`, the dictionary
    /// `noShippingCodeBranchesOnARoutedTypeToken` scans with. So deleting `"typeToken =="` from that
    /// dictionary, or widening `"fernlet.mesh.routed-type."`'s empty allowlist to admit any file,
    /// fails HERE rather than silently narrowing what wall 3 catches.
    ///
    /// The scanners' blind spot is fixtured from both sides: a leading-dot `= .init(entries: …)` is
    /// invisible to both (the negative), and the one shipping file that holds a registry value in a
    /// **type-inferred position** is asserted to spell the type out in full (the positive) — which is
    /// the only thing keeping the blind spot documented rather than occupied.
    @Test func theTypeRegistryScannersMatchAcrossLines() throws {
        let oneLine = "static let x = MeshRoutedTypeRegistry(entries: [row])"
        let wrapped = """
            static let x = MeshRoutedTypeRegistry(
                entries: [row]
            )
            """
        for (label, source) in [("one line", oneLine), ("wrapped", wrapped)] {
            #expect(
                MeshSessionStoreIsolationTests.constructionArguments(
                    of: "MeshRoutedTypeRegistry(", in: source
                ).count == 1,
                "the registry scanner missed a \(label) construction"
            )
        }
        let dotRead = "let y = MeshRoutedTypeRegistry.maxEntries"
        #expect(
            MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedTypeRegistry(", in: dotRead
            ).isEmpty,
            "the registry scanner counted a dot-member read as a construction"
        )
        try Self.expectTheMemberScannersBlindSpotIsStillEmpty()
        Self.expectTheWallsNeedlesStillDiscriminate()
    }

    /// The blind spot, both ways: the inferred form is invisible to both scanners, and no shipping
    /// value-position read has moved into it.
    ///
    /// `MeshNetworkManager.swift` (the registry its `init` builds) is the one place a registry value
    /// stands where a leading dot would compile — and where `shippingCodeNamesOneTypeRegistry` would
    /// then see nothing at all. The manifest mint's `types:` takes no default, so it holds none.
    ///
    /// The positive needle is the construction spelled in full, `MeshRoutedTypeRegistry(entries:`: the
    /// manager builds its registry from its host's rows directly, with no builder between them.
    private static func expectTheMemberScannersBlindSpotIsStillEmpty() throws {
        let inferred = "self.hostRoutedTypeRegistry = .init(entries: store.meshRoutedTypeEntries)"
        #expect(inferred.components(separatedBy: "MeshRoutedTypeRegistry.").count == 1,
                "the member scanner's blind spot moved: an inferred member is now visible to it")
        #expect(MeshSessionStoreIsolationTests.constructionArguments(
                    of: "MeshRoutedTypeRegistry(", in: inferred
                ).isEmpty,
                "the construction scanner's blind spot moved: an inferred construction is now visible to it")
        let sources = try proximitySources()
        for name in ["MeshNetworkManager.swift"] {
            let code = try #require(sources.first { $0.0 == name }?.1,
                                    "the sweep no longer reaches a file that holds a registry value")
            #expect(code.contains("MeshRoutedTypeRegistry(entries:"),
                    "\(name) shortened its registry value to a form the one-registry wall cannot see")
        }
    }

    /// Wall 3's needles, driven as data: each bare branch form is caught by exactly its own needle, a
    /// registry lookup and the manager's registry read are caught by none, a sender reading one
    /// routed type off its namespace is caught by that type's needle, and the raw literal's allowlist
    /// is still empty.
    private static func expectTheWallsNeedlesStillDiscriminate() {
        for (needle, form) in routedTokenBranchForms {
            #expect(routedTokenNeedles[needle]?.isEmpty == true,
                    "the wall dropped the per-type branch needle \(needle), or allowlisted a file for it")
            #expect(routedTokenNeedles.keys.filter { form.contains($0) } == [needle],
                    "the wall's needles no longer catch exactly one per-type branch form: \(form)")
        }
        let lookup = "routedTypes.entry(for: manifest.typeToken)"
        #expect(routedTokenNeedles.keys.contains { lookup.contains($0) } == false,
                "a registry lookup is being read as a per-type branch")
        let registryRead = "MeshRoutedTypeRegistry(entries: store.meshRoutedTypeEntries)"
        #expect(routedTokenNeedles.keys.contains { registryRead.contains($0) } == false,
                "the manager's registry read is being read as a per-type read")
        let senderRead = "let token = namespace.family.vocabulary.routedTypes.heart"
        #expect(routedTokenNeedles.keys.filter { senderRead.contains($0) } == ["routedTypes.heart"],
                "the field needles no longer catch a sender reading a routed type off its namespace")
        let rawInRegistry = "let token = \"fernlet.mesh.routed-type.photo.v1\""
        #expect(routedTokenNeedles.keys.contains { rawInRegistry.contains($0) },
                "the raw-literal needle stopped matching a spelling written into a row")
        #expect(routedTokenNeedles["fernlet.mesh.routed-type."] == [],
                "the raw literal may now be typed into a ProximityKit file")
    }

    /// The ack-table scanner itself, fixtured BOTH ways — the wall's matcher is the wall.
    ///
    /// The wrapped form is the one the old `contains("MeshRoutedAckStageTable(rows:")` missed: a
    /// second policy written across two lines would have been invisible, and nothing else in the
    /// tree would have noticed.
    @Test func theAckStageTableScannerMatchesAcrossLines() {
        let oneLine = "static let x = MeshRoutedAckStageTable(rows: [row])"
        let wrapped = """
            static let x = MeshRoutedAckStageTable(
                rows: [row]
            )
            """
        let unrelated = "let y = MeshRoutedAckStageTable.increment1.stage(for: token)"
        for (label, source) in [("one line", oneLine), ("wrapped", wrapped)] {
            #expect(
                MeshSessionStoreIsolationTests.constructionArguments(
                    of: "MeshRoutedAckStageTable(", in: source
                ).count == 1,
                "the ack-table scanner missed a \(label) construction"
            )
        }
        #expect(
            MeshSessionStoreIsolationTests.constructionArguments(
                of: "MeshRoutedAckStageTable(", in: unrelated
            ).isEmpty,
            "the ack-table scanner counted a dot-member read as a construction"
        )
    }

    /// The ack path calls no decryption seam: a photo or a text is final on durable CIPHERTEXT, and
    /// the store never unwraps a content key.
    @Test func theAckPathNamesNoDecryptSeam() throws {
        let files = [
            "MeshRoutedAck.swift", "MeshRecipientReceipt.swift", "MeshRecipientReceiptVerifier.swift",
            "MeshRoutedDeliveryCommit.swift", "MeshRoutedDeliveryIngest.swift"
        ]
        for name in files {
            let code = MeshRoutedSourceScan.codeOnly(
                try RepoRoot.source("FernletKit/Sources/ProximityKit/Mesh/\(name)")
            )
            #expect(code.contains("MeshRoutedContentKeyWrapper") == false, "\(name)")
            #expect(code.contains(".unwrap(") == false, "\(name)")
            #expect(code.contains("openKey()") == false, "\(name)")
        }
    }

    // MARK: - Scanner

    /// Every `.swift` file under ProximityKit and FernletSocial, as `(filename, code-only source)`,
    /// ProximityKit's first. FernletSocial is swept because the routed-type rows come from it
    /// (`FernletRoutedTypes.swift`) and so do the projection handlers and the ledger judge the engine
    /// calls by token, so a feature that built a second registry or table, or branched on a token, is
    /// seen in the module it lives in.
    private static func proximitySources() throws -> [(String, String)] {
        var sources: [(String, String)] = []
        let roots = [
            RepoRoot.url("FernletKit/Sources/ProximityKit"),
            RepoRoot.url("FernletKit/Sources/FernletSocial")
        ]
        // R2: bounded by the two module roots and each one's file list.
        for root in roots {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
            let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
            for file in files.sorted(by: { $0.path < $1.path }) {
                sources.append((
                    file.lastPathComponent,
                    MeshRoutedSourceScan.codeOnly(try String(contentsOf: file, encoding: .utf8))
                ))
            }
        }
        #expect(sources.count >= 8, "the ProximityKit sweep found only \(sources.count) files")
        return sources
    }

    // MARK: - Scanner

    /// Every `.swift` file under both test roots, the app's unit tests and ProximityKit's package tests
    /// (`MeshSessionStoreIsolationTests.testRoots`, each held to its floor), as `(filename, source)`,
    /// minus this file.
    private static func testSources() throws -> [(String, String)] {
        try MeshSessionStoreIsolationTests.testTreeSources(excluding: excludedFiles)
    }
}
